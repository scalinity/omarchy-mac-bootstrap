//! omb-tui: the omarchy-mac-bootstrap frontend (docs/FRONTEND.md).
//!
//! Presentation and input only. The Bash core reads the machine, decides what
//! is legal and runs everything; this crate draws what the core says, collects
//! choices and typed words, and hands the terminal to a child when the core
//! declares a handoff. It runs no program but the core.

pub mod app;
pub mod core;
pub mod keys;
pub mod record;
pub mod screens;
pub mod terminal;
pub mod theme;
pub mod widgets;

use app::{Cmd, Model, Msg, Outcome, Req, update};
use ratatui::crossterm::event::{self, Event};
use std::fs::OpenOptions;
use std::io::{self, IsTerminal, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// The event loop's tick: the longest it waits for a key before looking at
/// the spool and the core again.
pub const TICK_MS: u32 = 50;

/// Exit statuses (docs/FRONTEND.md → *The crate*): 0 finished; 10 fall back
/// to the text interface, with the reason on stderr after the terminal is
/// restored; anything else is a failure the launcher reports.
pub const EXIT_FALLBACK: i32 = 10;

/// The signals the frontend catches (never ignores): a flag each.
struct Signals {
    stop: Arc<AtomicBool>,
    interrupt: Arc<AtomicBool>,
    cont: Arc<AtomicBool>,
}

fn signals() -> io::Result<Signals> {
    use signal_hook::consts::{SIGCONT, SIGHUP, SIGINT, SIGQUIT, SIGTERM};
    let s = Signals {
        stop: Arc::default(),
        interrupt: Arc::default(),
        cont: Arc::default(),
    };
    signal_hook::flag::register(SIGTERM, s.stop.clone())?;
    signal_hook::flag::register(SIGHUP, s.stop.clone())?;
    // Ctrl-C and Ctrl-\ reach the whole group during a handoff: caught, so
    // the core and the child act on them; the frontend carries on.
    signal_hook::flag::register(SIGINT, s.interrupt.clone())?;
    signal_hook::flag::register(SIGQUIT, s.interrupt.clone())?;
    signal_hook::flag::register(SIGCONT, s.cont.clone())?;
    Ok(s)
}

/// The launcher contract: `omb-tui --session DIR`, with the session's values
/// in the environment. Returns the exit status.
pub fn run(args: &[String]) -> i32 {
    let fallback = |why: &str| {
        eprintln!("omb-tui: {why}; continuing in the text interface.");
        EXIT_FALLBACK
    };
    let dir = match args {
        [flag, dir] if flag == "--session" => PathBuf::from(dir),
        _ => return fallback("started without --session DIR (the launcher starts it)"),
    };
    if std::env::var_os("OMB_SESSION_DIR")
        .map(PathBuf::from)
        .as_ref()
        != Some(&dir)
    {
        return fallback("the session folder and OMB_SESSION_DIR differ");
    }
    let Some(home) = std::env::var_os("OMB_HOME").map(PathBuf::from) else {
        return fallback("OMB_HOME is not set");
    };
    // Nothing a caller left open reaches the core or a child.
    core::seal_inherited_descriptors();
    let env = |k: &str| std::env::var(k).ok();
    let tty = io::stdout().is_terminal();
    let caps = theme::detect(&env, tty);
    if !io::stdin().is_terminal()
        || !tty
        || matches!(
            std::env::var("TERM").as_deref(),
            Err(_) | Ok("") | Ok("dumb")
        )
    {
        return fallback("this is not a terminal the interface can draw on");
    }
    let sig = match signals() {
        Ok(s) => s,
        Err(e) => return fallback(&format!("signal handlers could not be installed ({e})")),
    };
    let fixture = std::env::var_os("OMB_FIXTURE").is_some_and(|v| !v.is_empty());
    let mut session = core::Session::new(dir, home, fixture);
    let theme = theme::Theme::new(caps);
    let mut term = match terminal::start(caps.console) {
        Ok(t) => t,
        Err(e) => return fallback(&format!("the terminal could not be prepared ({e})")),
    };
    let mut trace = Trace::open();
    let mut model = Model::default();
    let mut cmds = model.start();
    let mut running: Option<(core::Running, Req, Instant)> = None;
    let mut dirty = true;
    loop {
        for c in std::mem::take(&mut cmds) {
            match c {
                Cmd::Send(req) => {
                    trace.line(&format!("send {req:?}"));
                    if matches!(req, Req::Execute { handoff: true, .. }) {
                        let outcome =
                            handoff(&mut term, &mut session, &req, &mut model, &sig, &mut trace);
                        // A stop and continue during the child was the
                        // child's; the handoff has re-entered already.
                        sig.cont.store(false, Ordering::SeqCst);
                        trace.line(&format!("outcome {outcome:?}"));
                        cmds.extend(update(&mut model, Msg::Done(req, outcome)));
                        dirty = true;
                        continue;
                    }
                    match session.start(&req) {
                        Ok(r) => running = Some((r, req, Instant::now())),
                        Err(e) => cmds.extend(update(
                            &mut model,
                            Msg::Done(req, Outcome::NotSent(e.to_string())),
                        )),
                    }
                }
                Cmd::Cancel => {
                    if let Some((r, _, _)) = &running {
                        r.cancel();
                    }
                }
                Cmd::Suspend => {
                    term.leave();
                    sig.cont.store(false, Ordering::SeqCst);
                    // Everything in the group stops together; this returns
                    // after SIGCONT.
                    core::stop_group();
                    let _ = term.reenter();
                    // This re-entry answers the SIGCONT that woke us.
                    sig.cont.store(false, Ordering::SeqCst);
                    // The machine may have changed meanwhile.
                    if model.pending.is_none() {
                        cmds.extend(update(&mut model, Msg::Key(refresh_key())));
                    }
                    dirty = true;
                }
                Cmd::ReadLogs => {
                    cmds.extend(update(&mut model, Msg::Logs(session.diagnostics())));
                    dirty = true;
                }
                Cmd::Quit(code, why) => {
                    term.restore();
                    trace.line(&format!("exit {code}"));
                    if !why.is_empty() {
                        eprintln!("omb-tui: {why}");
                    }
                    return code;
                }
            }
        }
        if !cmds.is_empty() {
            continue;
        }
        if sig.stop.swap(false, Ordering::SeqCst) {
            cmds.extend(update(&mut model, Msg::Terminate));
            dirty = true;
        }
        if sig.cont.swap(false, Ordering::SeqCst) {
            // Continued from outside (the shell's fg): take the terminal back.
            let _ = term.reenter();
            dirty = true;
        }
        if let Some((r, req, started)) = running.as_mut() {
            let hold = test_hook_hold(*started);
            let mut live = Vec::new();
            let end = r.poll(&mut |rec| live.push(rec), hold);
            for rec in live {
                cmds.extend(update(&mut model, Msg::Live(rec)));
                dirty = true;
            }
            if let Some(outcome) = end {
                trace.line(&format!("outcome {outcome:?}"));
                let req = req.clone();
                running = None;
                cmds.extend(update(&mut model, Msg::Done(req, outcome)));
                dirty = true;
            }
        }
        if !cmds.is_empty() {
            continue;
        }
        if dirty {
            if term
                .terminal
                .draw(|f| screens::draw(f, &model, &theme, TICK_MS))
                .is_err()
            {
                term.restore();
                return 1;
            }
            dirty = false;
            // A test hook (never in a release): a panic once the dashboard
            // is on the screen (docs/TESTING.md → pty-panic).
            #[cfg(feature = "test-hooks")]
            if model.screen == app::Screen::Dashboard
                && std::env::var("OMB_TEST_HOOK").as_deref() == Ok("panic")
            {
                panic!("test hook: an injected panic");
            }
        }
        // One thread reads the terminal: this one, and never during a handoff.
        match event::poll(Duration::from_millis(TICK_MS as u64)) {
            Ok(true) => match event::read() {
                Ok(Event::Key(k)) => {
                    cmds.extend(update(&mut model, Msg::Key(k)));
                    dirty = true;
                }
                Ok(Event::Resize(_, _)) => dirty = true,
                Ok(_) => {}
                // A signal interrupting the read: retried on the next pass.
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => {
                    term.restore();
                    return 1;
                }
            },
            Ok(false) => {
                // Motion only while something is happening.
                if model.pending.is_some() {
                    cmds.extend(update(&mut model, Msg::Tick));
                    dirty = true;
                }
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => {
                term.restore();
                return 1;
            }
        }
    }
}

fn refresh_key() -> event::KeyEvent {
    event::KeyEvent::new(event::KeyCode::Char('r'), event::KeyModifiers::NONE)
}

/// A handoff (docs/FRONTEND.md → *Handing the terminal to a child*): stop
/// drawing and reading keys, step aside, start the core with the terminal,
/// follow its spool until it has exited and answered, wait until no process
/// that joined the group during the request remains, then take the terminal
/// back. The caller asks for a fresh snapshot.
fn handoff(
    term: &mut terminal::Term,
    session: &mut core::Session,
    req: &Req,
    model: &mut Model,
    sig: &Signals,
    trace: &mut Trace,
) -> Outcome {
    use core::proctable;
    let pg = proctable::my_group();
    // The frontend's own snapshot, from its own reading, before the handoff.
    let snap = match proctable::group(pg) {
        Ok(s) => s,
        Err(e) => {
            return Outcome::NotSent(format!(
                "the process table could not be read ({e}); the terminal was not handed over"
            ));
        }
    };
    term.leave();
    let mut running = match session.start(req) {
        Ok(r) => r,
        Err(e) => {
            let _ = term.reenter();
            return Outcome::NotSent(e.to_string());
        }
    };
    let mut followed = 0usize;
    let outcome = loop {
        let mut live = Vec::new();
        let end = running.poll(&mut |r| live.push(r), false);
        followed += live.len();
        for r in live {
            update(model, Msg::Live(r));
        }
        if let Some(o) = end {
            break o;
        }
        // Ctrl-C belongs to the child now.
        sig.interrupt.store(false, Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(20));
    };
    trace.line(&format!("handoff followed {followed} records"));
    // Not back while any worker is still present.
    let waited = Instant::now();
    let mut said = false;
    loop {
        match proctable::present(pg, &snap) {
            Ok(p) if p.is_empty() => break,
            Ok(p) => {
                if !said && waited.elapsed() > Duration::from_secs(3) {
                    eprintln!(
                        "omb-tui: waiting for {} process(es) the program left running ({:?})",
                        p.len(),
                        p
                    );
                    trace.line(&format!("waiting for workers {p:?}"));
                    said = true;
                }
            }
            Err(_) => {}
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    let _ = term.reenter();
    outcome
}

/// A test hook (the `test-hooks` feature, never in a release): hold the
/// channel full for the first seconds of each request, as a slow frontend
/// would (docs/TESTING.md → sup-slow-frontend).
fn test_hook_hold(_started: Instant) -> bool {
    #[cfg(feature = "test-hooks")]
    if std::env::var("OMB_TEST_HOOK").as_deref() == Ok("stall-channel") {
        return _started.elapsed() < Duration::from_secs(3);
    }
    false
}

/// The optional trace file: only when OMB_TUI_LOG names a path (the launcher
/// passes it only in an act session), created 0600. Never the screen.
struct Trace(Option<std::fs::File>);

impl Trace {
    fn open() -> Trace {
        let f = std::env::var_os("OMB_TUI_LOG")
            .filter(|p| !p.is_empty())
            .and_then(|p| {
                OpenOptions::new()
                    .append(true)
                    .create(true)
                    .mode(0o600)
                    .open(p)
                    .ok()
            });
        Trace(f)
    }
    fn line(&mut self, s: &str) {
        if let Some(f) = self.0.as_mut() {
            let _ = writeln!(f, "{s}");
        }
    }
}
