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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::ThreadId;
use std::time::{Duration, Instant};

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

/// Terminal input never waits longer than a tick. Crossterm's `use-dev-tty`
/// backend bounds EOF retries; the default Mio backend can loop inside one
/// read forever. Native hang-up flags are checked on both sides of that poll.
#[derive(Debug)]
pub(crate) enum Input {
    Event(event::Event),
    Idle,
    Terminate,
    Gone(String),
}

trait EventSource {
    fn poll(&mut self, timeout: Duration) -> io::Result<bool>;
    fn read(&mut self) -> io::Result<Option<event::Event>>;
}

#[derive(Default)]
struct TerminalEvents {
    parsed: bool,
}
impl EventSource for TerminalEvents {
    fn poll(&mut self, timeout: Duration) -> io::Result<bool> {
        if empty_readiness()? {
            self.parsed = false;
            return Ok(true);
        }
        let ready = {
            let _input = NonblockingInput::new()?;
            event::poll(timeout)
        }?;
        self.parsed = ready;
        Ok(empty_readiness()? || ready)
    }
    fn read(&mut self) -> io::Result<Option<event::Event>> {
        // poll(true) has already queued a parsed event: read cannot block.
        if self.parsed {
            event::read().map(Some)
        } else {
            Ok(None)
        }
    }
}

/// Only polling borrows non-blocking stdin: output, the shell and handed-off
/// programs keep the original descriptor flags, including on an error/unwind.
struct NonblockingInput(rustix::fs::OFlags);
impl NonblockingInput {
    fn new() -> io::Result<Self> {
        let flags = rustix::fs::fcntl_getfl(io::stdin())?;
        rustix::fs::fcntl_setfl(io::stdin(), flags | rustix::fs::OFlags::NONBLOCK)?;
        Ok(Self(flags))
    }
}
impl Drop for NonblockingInput {
    fn drop(&mut self) {
        let _ = rustix::fs::fcntl_setfl(io::stdin(), self.0);
    }
}

fn empty_readiness() -> io::Result<bool> {
    use rustix::event::{PollFd, PollFlags, Timespec, poll};
    let stdin = io::stdin();
    let mut fds = [PollFd::new(&stdin, PollFlags::IN)];
    poll(&mut fds, Some(&Timespec::default()))?;
    if fds[0]
        .revents()
        .intersects(PollFlags::HUP | PollFlags::ERR | PollFlags::NVAL)
    {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "terminal hung up",
        ));
    }
    // Readable with no bytes is distinct from bytes consumed into an
    // incomplete escape sequence: only the former counts as empty readiness.
    Ok(fds[0].revents().contains(PollFlags::IN) && rustix::io::ioctl_fionread(&stdin)? == 0)
}

#[derive(Default)]
struct InputReader {
    empty: Option<(Instant, u8)>,
}
impl InputReader {
    fn next(
        &mut self,
        source: &mut impl EventSource,
        stop: &AtomicBool,
        timeout: Duration,
    ) -> Input {
        if stop.load(Ordering::SeqCst) {
            return Input::Terminate;
        }
        let since = Instant::now();
        let ready = source.poll(timeout);
        // A signal must be seen here even if poll repeatedly returns at once.
        if stop.load(Ordering::SeqCst) {
            return Input::Terminate;
        }
        let readable = matches!(ready, Ok(true));
        let got = match ready {
            Ok(true) => source.read(),
            Ok(false) => {
                self.empty = None;
                Ok(None)
            }
            Err(e) => Err(e),
        };
        if stop.load(Ordering::SeqCst) {
            return Input::Terminate;
        }
        let got = match got {
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => Ok(None),
            other => other,
        };
        match got {
            Ok(Some(event)) => {
                self.empty = None;
                return Input::Event(event);
            }
            Ok(None) if readable => {
                let now = Instant::now();
                let (first, count) = self
                    .empty
                    .filter(|(first, _)| now.duration_since(*first) <= Duration::from_millis(250))
                    .unwrap_or((now, 0));
                self.empty = Some((first, count + 1));
                if count + 1 >= 4 {
                    return Input::Gone("terminal repeatedly ready without input".into());
                }
            }
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                ) => {}
            Err(e) => return Input::Gone(e.to_string()),
            Ok(None) => {}
        }
        // Empty readiness and interrupted polls must not turn into a busy loop.
        std::thread::sleep(
            timeout
                .max(Duration::from_millis(1))
                .saturating_sub(since.elapsed()),
        );
        Input::Idle
    }
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
    input: InputReader,
}

fn put_back(saved: &Saved) {
    if let Ok(g) = saved.lock()
        && let Some(t) = g.as_ref()
    {
        // Flush, so keys typed ahead are discarded with the mode: queued input
        // at a switch back to canonical mode leaves the kernel's PENDIN bit
        // set, and the launcher compares the settings it saved with these.
        let _ = tcsetattr(io::stdin(), OptionalActions::Flush, t);
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
                input: InputReader::default(),
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
    pub(crate) fn poll(&mut self, stop: &AtomicBool, timeout: Duration) -> Input {
        self.input
            .next(&mut TerminalEvents::default(), stop, timeout)
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
    pub fn reenter(&mut self, stop: &AtomicBool) -> io::Result<()> {
        put_back(&self.saved);
        enable_raw_mode()?;
        execute!(io::stdout(), EnterAlternateScreen, Clear(ClearType::All))?;
        loop {
            match self.poll(stop, Duration::from_millis(1)) {
                Input::Event(_) => {}
                Input::Idle | Input::Terminate => break,
                Input::Gone(why) => return Err(io::Error::new(io::ErrorKind::UnexpectedEof, why)),
            }
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

    struct EmptyReady {
        polls: usize,
        reads: usize,
    }
    impl EventSource for EmptyReady {
        fn poll(&mut self, _: Duration) -> io::Result<bool> {
            self.polls += 1;
            Ok(true)
        }
        fn read(&mut self) -> io::Result<Option<event::Event>> {
            self.reads += 1;
            Ok(None)
        }
    }

    #[test]
    fn ready_without_input_ends_instead_of_spinning() {
        let stop = AtomicBool::new(false);
        let mut source = EmptyReady { polls: 0, reads: 0 };
        let mut input = InputReader::default();
        let before = Instant::now();
        for _ in 0..3 {
            assert!(matches!(
                input.next(&mut source, &stop, Duration::from_millis(10)),
                Input::Idle
            ));
        }
        assert!(
            before.elapsed() >= Duration::from_millis(30),
            "empty reads wait between polls"
        );
        assert!(matches!(
            input.next(&mut source, &stop, Duration::from_millis(10)),
            Input::Gone(_)
        ));
        assert_eq!((source.polls, source.reads), (4, 4));
    }

    #[test]
    fn terminate_is_checked_before_and_inside_polling() {
        struct Signalled<'a>(&'a AtomicBool);
        impl EventSource for Signalled<'_> {
            fn poll(&mut self, _: Duration) -> io::Result<bool> {
                self.0.store(true, Ordering::SeqCst);
                Ok(true)
            }
            fn read(&mut self) -> io::Result<Option<event::Event>> {
                panic!("signal precedes read")
            }
        }
        let stop = AtomicBool::new(false);
        let mut input = InputReader::default();
        assert!(matches!(
            input.next(&mut Signalled(&stop), &stop, Duration::from_secs(1)),
            Input::Terminate
        ));
        let mut source = EmptyReady { polls: 0, reads: 0 };
        assert!(matches!(
            input.next(&mut source, &stop, Duration::from_secs(1)),
            Input::Terminate
        ));
        assert_eq!(source.polls, 0);
    }

    #[test]
    fn eof_eio_and_disconnected_errors_end_input() {
        struct Failed(Option<io::Error>);
        impl EventSource for Failed {
            fn poll(&mut self, _: Duration) -> io::Result<bool> {
                Ok(true)
            }
            fn read(&mut self) -> io::Result<Option<event::Event>> {
                Err(self.0.take().unwrap())
            }
        }
        for error in [
            io::Error::from(io::ErrorKind::UnexpectedEof),
            io::Error::from_raw_os_error(rustix::io::Errno::IO.raw_os_error()),
            io::Error::from(io::ErrorKind::BrokenPipe),
            io::Error::from(io::ErrorKind::NotConnected),
        ] {
            assert!(matches!(
                InputReader::default().next(
                    &mut Failed(Some(error)),
                    &AtomicBool::new(false),
                    Duration::from_millis(10)
                ),
                Input::Gone(_)
            ));
        }
    }

    #[test]
    fn real_input_and_an_idle_poll_reset_empty_readiness() {
        struct Once(bool);
        impl EventSource for Once {
            fn poll(&mut self, _: Duration) -> io::Result<bool> {
                Ok(self.0)
            }
            fn read(&mut self) -> io::Result<Option<event::Event>> {
                Ok(Some(event::Event::Key(event::KeyEvent::from(
                    event::KeyCode::Char('j'),
                ))))
            }
        }
        let stop = AtomicBool::new(false);
        let mut input = InputReader::default();
        let mut source = EmptyReady { polls: 0, reads: 0 };
        for _ in 0..3 {
            input.next(&mut source, &stop, Duration::ZERO);
        }
        assert!(matches!(
            input.next(&mut Once(true), &stop, Duration::ZERO),
            Input::Event(_)
        ));
        assert!(input.empty.is_none());
        input.next(&mut source, &stop, Duration::ZERO);
        input.next(&mut Once(false), &stop, Duration::ZERO);
        assert!(input.empty.is_none());
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

#[cfg(test)]
#[path = "../tests/terminal_input/mod.rs"]
mod input_tests;
