//! The terminal's lifecycle (docs/FRONTEND.md → *The terminal*, *Handing the
//! terminal to a child*).
//!
//! Start: the frontend's own panic hook first; the terminal's settings saved
//! once (`tcgetattr`); then Ratatui's `try_init()` (raw mode, the alternate
//! screen, its restoring hook chained in front of ours); then the gate
//! around that whole chain, which runs it only for a panic on the thread
//! that owns the terminal. Mouse capture, bracketed paste and
//! keyboard-enhancement modes are never turned on. Every way out — normal
//! exit, error, panic, a signal, a handoff, a suspend — leaves the alternate
//! screen, shows the cursor (restore does not) and puts the saved settings
//! back, because a child that left the terminal odd must never become the
//! new baseline.

use ratatui::DefaultTerminal;
use ratatui::crossterm::{
    cursor::Show,
    event, execute,
    terminal::{Clear, ClearType, EnterAlternateScreen, enable_raw_mode},
};
use rustix::termios::{OptionalActions, Termios, tcgetattr, tcsetattr};
use std::io::{self, IsTerminal, Write};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::ThreadId;
use std::time::Duration;

// Panic hooks are process-wide, and Ratatui 0.30's `try_init` chains an
// unconditional restore in front of every earlier hook (its `set_panic_hook`
// is private). A panic on another thread — the spool reader — would then
// restore the terminal under a main thread still drawing on it, or take it
// from a child during a handoff. So the whole chain runs only for a panic on
// the thread that owns the terminal; another thread's panic is kept here,
// untouched by the screen, for the owner to report once it has restored.
static WORKER_PANIC: Mutex<Option<String>> = Mutex::new(None);

/// Gate the panic hook now installed to OWNER: its panics run it, any other
/// thread's are only kept (the first one).
pub fn own_panics(owner: ThreadId) {
    let chain = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if std::thread::current().id() == owner {
            chain(info);
        } else {
            let mut kept = WORKER_PANIC.lock().unwrap_or_else(|e| e.into_inner());
            if kept.is_none() {
                *kept = Some(info.to_string());
            }
        }
    }));
}

/// The first panic of a thread other than the terminal's owner, if any.
pub fn worker_panic() -> Option<String> {
    WORKER_PANIC
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

// Crossterm 0.29 retries a terminal read forever once the terminal answers
// end of file or an error — what a closed window or a dropped SSH link leaves
// — without returning from `event::poll`, so the event loop never runs again
// and no signal flag is read. On a live terminal every reading call returns
// within a tick. A watcher that finds the same call still running at four
// checks a quarter of a second apart knows the terminal is gone and ends the
// process: nothing is left to restore, and nobody is left to see it.
static READING: AtomicBool = AtomicBool::new(false);
static READS: AtomicUsize = AtomicUsize::new(0);

/// Run F, one call that reads the terminal, where the watcher can see it.
pub fn reading<T>(f: impl FnOnce() -> T) -> T {
    READS.fetch_add(1, Ordering::SeqCst);
    READING.store(true, Ordering::SeqCst);
    let r = f();
    READING.store(false, Ordering::SeqCst);
    r
}

/// The watcher's judgement, one check at a time.
pub struct Watch {
    last: usize,
    same: u32,
}

impl Default for Watch {
    fn default() -> Self {
        Watch {
            last: usize::MAX,
            same: 0,
        }
    }
}

impl Watch {
    /// One check of (a read in progress, reads started so far): true once
    /// the same read has been in progress at four checks in a row. The
    /// watcher's own time counts, so a stopped process, which stops the
    /// watcher too, is never taken for a stuck one.
    pub fn stuck(&mut self, reading: bool, reads: usize) -> bool {
        if reading && reads == self.last {
            self.same += 1;
        } else {
            self.same = 0;
        }
        self.last = reads;
        self.same >= 4
    }
}

/// Start the watcher: a quarter-second check for the whole process's life.
fn watch_reads(title: Arc<Mutex<Title>>) {
    std::thread::spawn(move || {
        let mut w = Watch::default();
        loop {
            std::thread::sleep(Duration::from_millis(250));
            if w.stuck(READING.load(Ordering::SeqCst), READS.load(Ordering::SeqCst)) {
                eprintln!("omb-tui: the terminal went away; the interface stops.");
                let _ = title
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .leave(&mut io::stdout());
                std::process::exit(1);
            }
        }
    });
}

/// One title stack entry belongs to the frontend while it owns the terminal.
/// Both ordinary restore and the owner panic hook close the same entry.
struct Title {
    enabled: bool,
    pushed: bool,
    label: String,
}
impl Title {
    fn new(enabled: bool) -> Self {
        Self {
            enabled,
            pushed: false,
            label: "Omarchy Installation".into(),
        }
    }
    fn enter(&mut self, w: &mut impl Write) -> io::Result<()> {
        if !self.enabled || self.pushed {
            return Ok(());
        }
        self.pushed = true;
        w.write_all(b"\x1b[22;2t")?;
        write!(w, "\x1b]2;{}\x07", self.label)?;
        w.flush()
    }
    fn set(&mut self, w: &mut impl Write, label: String) -> io::Result<()> {
        if self.label == label {
            return Ok(());
        }
        self.label = label;
        if !self.enabled || !self.pushed {
            return Ok(());
        }
        write!(w, "\x1b]2;{}\x07", self.label)?;
        w.flush()
    }
    fn leave(&mut self, w: &mut impl Write) -> io::Result<()> {
        if !self.pushed {
            return Ok(());
        }
        self.pushed = false;
        w.write_all(b"\x1b[23;2t")?;
        w.flush()
    }
}
fn title_label(model: &crate::app::Model) -> String {
    let stages = model
        .snap
        .as_ref()
        .map(|s| s.stages.as_slice())
        .unwrap_or(&[]);
    if stages.iter().any(|s| s.name == "done" && s.state == "done") {
        "Omarchy Installation | Done".into()
    } else if let Some(i) = stages.iter().position(|s| s.state == "current") {
        format!("Omarchy Installation | Step {}", i + 1)
    } else {
        "Omarchy Installation".into()
    }
}

/// The settings saved at start, shared with the panic hook.
type Saved = Arc<Mutex<Option<Termios>>>;

pub struct Term {
    pub terminal: DefaultTerminal,
    saved: Saved,
    console: bool,
    title: Arc<Mutex<Title>>,
}

fn put_back(saved: &Saved) {
    if let Ok(g) = saved.lock()
        && let Some(t) = g.as_ref()
    {
        let _ = tcsetattr(io::stdin(), OptionalActions::Now, t);
    }
}

/// The part of every restore the frontend writes itself: the cursor shown,
/// and on the Linux console the screen cleared (a kernel older than August
/// 2025 has no alternate screen there). Written to W so its bytes can be
/// checked.
pub fn epilogue<W: Write>(w: &mut W, console: bool) -> io::Result<()> {
    execute!(w, Show)?;
    if console {
        w.write_all(b"\x1b[H\x1b[2J")?;
    }
    w.flush()
}

/// Start the interface on this terminal. CONSOLE: the Linux console.
pub fn start(console: bool) -> io::Result<Term> {
    let saved: Saved = Arc::new(Mutex::new(Some(tcgetattr(io::stdin())?)));
    // Ours first: Ratatui's hook, installed by try_init, restores and then
    // calls this one, which puts the saved settings back, shows the cursor,
    // and reports on the normal screen.
    let title = Arc::new(Mutex::new(Title::new(
        !console && io::stdin().is_terminal() && io::stdout().is_terminal(),
    )));
    let hook_title = title.clone();
    let hook_saved = saved.clone();
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = hook_title
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .leave(&mut io::stdout());
        let _ = ratatui::try_restore();
        let _ = epilogue(&mut io::stdout(), console);
        put_back(&hook_saved);
        eprintln!(
            "omb-tui: the interface stopped unexpectedly. ./omarchy-bootstrap status shows where the machine is."
        );
        previous(info);
    }));
    match ratatui::try_init() {
        Ok(terminal) => {
            // No other thread exists yet: the gate is in place before one can.
            own_panics(std::thread::current().id());
            let _ = title
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .enter(&mut io::stdout());
            Ok(Term {
                terminal,
                saved,
                console,
                title,
            })
        }
        Err(e) => {
            // try_init is not transactional: undo whatever it managed.
            let _ = ratatui::try_restore();
            let _ = epilogue(&mut io::stdout(), console);
            put_back(&saved);
            Err(e)
        }
    }
}

impl Term {
    pub fn watch_reads(&self) {
        watch_reads(self.title.clone());
    }
    pub fn update_title(&self, model: &crate::app::Model) {
        let label = title_label(model);
        let _ = self
            .title
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .set(&mut io::stdout(), label);
    }

    /// The final restore: every step attempted, whatever fails first.
    pub fn restore(&mut self) {
        let _ = self
            .title
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .leave(&mut io::stdout());
        let _ = ratatui::try_restore();
        let _ = epilogue(&mut io::stdout(), self.console);
        put_back(&self.saved);
    }

    /// Step aside for a child or a suspend: the alternate screen left, the
    /// cursor shown, raw mode off, the saved settings back. The caller has
    /// already stopped reading the terminal (one thread reads it, and it
    /// reads nothing while a child runs).
    pub fn leave(&mut self) {
        let _ = self
            .title
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .leave(&mut io::stdout());
        let _ = ratatui::try_restore();
        let _ = execute!(io::stdout(), Show);
        put_back(&self.saved);
    }

    /// Take the terminal back: the saved settings first (so raw mode is
    /// built on them, not on whatever the child left), raw mode, the
    /// alternate screen cleared, pending input drained, and a full redraw.
    ///
    /// The redraw comes from a fresh `Terminal`, whose empty buffers make the
    /// next draw paint every cell. `Terminal::clear` would do the same but
    /// first asks the terminal where its cursor is (a DSR round trip): a
    /// terminal that does not answer stalls it, and the screen stays blank.
    pub fn reenter(&mut self) -> io::Result<()> {
        put_back(&self.saved);
        enable_raw_mode()?;
        execute!(io::stdout(), EnterAlternateScreen, Clear(ClearType::All))?;
        while reading(|| event::poll(Duration::from_millis(0)))? {
            let _ = reading(event::read)?;
        }
        self.terminal =
            ratatui::Terminal::new(ratatui::backend::CrosstermBackend::new(io::stdout()))?;
        self.title
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .enter(&mut io::stdout())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_watcher_stops_only_on_a_read_that_never_returns() {
        let mut w = Watch::default();
        // Reads that keep returning: never stuck, however long.
        for n in 1..40 {
            assert!(!w.stuck(true, n));
        }
        // Not reading (a handoff, a suspend, drawing): never stuck.
        let mut w = Watch::default();
        for _ in 0..40 {
            assert!(!w.stuck(false, 7));
        }
        // One read still running at four checks after it was first seen.
        let mut w = Watch::default();
        assert!(!w.stuck(true, 9));
        for _ in 0..3 {
            assert!(!w.stuck(true, 9));
        }
        assert!(w.stuck(true, 9));
        // A read that returns just in time resets the count.
        let mut w = Watch::default();
        for _ in 0..4 {
            assert!(!w.stuck(true, 3));
        }
        assert!(!w.stuck(true, 4));
        assert!(!w.stuck(true, 4));
    }

    #[test]
    fn the_epilogue_shows_the_cursor_and_clears_the_console() {
        let mut v = Vec::new();
        epilogue(&mut v, false).unwrap();
        assert_eq!(v, b"\x1b[?25h");
        let mut v = Vec::new();
        epilogue(&mut v, true).unwrap();
        assert_eq!(v, b"\x1b[?25h\x1b[H\x1b[2J");
    }
}

#[cfg(test)]
mod title_tests {
    use super::*;
    #[test]
    fn title_stack_is_restored_at_exit_and_handoff() {
        let mut title = Title::new(true);
        let mut bytes = Vec::new();
        title.enter(&mut bytes).unwrap();
        for step in 1..=10 {
            title
                .set(&mut bytes, format!("Omarchy Installation | Step {step}"))
                .unwrap();
        }
        title.leave(&mut bytes).unwrap();
        title.enter(&mut bytes).unwrap();
        title
            .set(&mut bytes, "Omarchy Installation | Done".into())
            .unwrap();
        title.leave(&mut bytes).unwrap();
        title.leave(&mut bytes).unwrap(); // panic and ordinary restore share one guard
        let expected = format!(
            "\x1b[22;2t\x1b]2;Omarchy Installation\x07{}\x1b[23;2t\x1b[22;2t\x1b]2;Omarchy Installation | Step 10\x07\x1b]2;Omarchy Installation | Done\x07\x1b[23;2t",
            (1..=10)
                .map(|i| format!("\x1b]2;Omarchy Installation | Step {i}\x07"))
                .collect::<String>()
        );
        assert_eq!(bytes, expected.as_bytes());
        let console = crate::theme::detect(&|k| (k == "TERM").then(|| "linux".into()), true);
        let mut console = Title::new(!console.console);
        let mut bytes = Vec::new();
        console.enter(&mut bytes).unwrap();
        console
            .set(&mut bytes, "Omarchy Installation | Step 1".into())
            .unwrap();
        console.leave(&mut bytes).unwrap();
        assert!(bytes.is_empty());
    }
    #[test]
    fn title_uses_the_cores_current_station() {
        let mut m = crate::app::Model::default();
        assert_eq!(title_label(&m), "Omarchy Installation");
        m.snap = Some(crate::app::Snapshot::default());
        for i in 0..10 {
            m.snap.as_mut().unwrap().stages.push(crate::app::Stage {
                name: if i == 9 {
                    "done".into()
                } else {
                    format!("step{i}")
                },
                state: "later".into(),
                basis: "".into(),
                by: "".into(),
                detail: "".into(),
            });
        }
        for i in 0..10 {
            for s in &mut m.snap.as_mut().unwrap().stages {
                s.state = "done".into();
            }
            m.snap.as_mut().unwrap().stages[i].state = "current".into();
            if i < 9 {
                m.snap.as_mut().unwrap().stages[9].state = "later".into();
            }
            assert_eq!(
                title_label(&m),
                format!("Omarchy Installation | Step {}", i + 1)
            );
        }
        m.snap.as_mut().unwrap().stages[9].state = "done".into();
        assert_eq!(title_label(&m), "Omarchy Installation | Done");
    }
}
