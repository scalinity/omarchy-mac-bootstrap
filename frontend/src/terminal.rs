//! The terminal's lifecycle (docs/FRONTEND.md → *The terminal*, *Handing the
//! terminal to a child*).
//!
//! Start: the frontend's own panic hook first; the terminal's settings saved
//! once (`tcgetattr`); then Ratatui's `try_init()` (raw mode, the alternate
//! screen, its restoring hook chained in front of ours). Mouse capture,
//! bracketed paste and keyboard-enhancement modes are never turned on.
//! Every way out — normal exit, error, panic, a signal, a handoff, a suspend
//! — leaves the alternate screen, shows the cursor (restore does not) and
//! puts the saved settings back, because a child that left the terminal odd
//! must never become the new baseline.

use ratatui::DefaultTerminal;
use ratatui::crossterm::{
    cursor::Show,
    event, execute,
    terminal::{Clear, ClearType, EnterAlternateScreen, enable_raw_mode},
};
use rustix::termios::{OptionalActions, Termios, tcgetattr, tcsetattr};
use std::io::{self, Write};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

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
pub fn watch_reads() {
    std::thread::spawn(|| {
        let mut w = Watch::default();
        loop {
            std::thread::sleep(Duration::from_millis(250));
            if w.stuck(READING.load(Ordering::SeqCst), READS.load(Ordering::SeqCst)) {
                eprintln!("omb-tui: the terminal went away; the interface stops.");
                std::process::exit(1);
            }
        }
    });
}

/// The settings saved at start, shared with the panic hook.
type Saved = Arc<Mutex<Option<Termios>>>;

pub struct Term {
    pub terminal: DefaultTerminal,
    saved: Saved,
    console: bool,
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
    let hook_saved = saved.clone();
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = ratatui::try_restore();
        let _ = epilogue(&mut io::stdout(), console);
        put_back(&hook_saved);
        eprintln!(
            "omb-tui: the interface stopped unexpectedly. ./omarchy-bootstrap status shows where the machine is."
        );
        previous(info);
    }));
    match ratatui::try_init() {
        Ok(terminal) => Ok(Term {
            terminal,
            saved,
            console,
        }),
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
    /// The final restore: every step attempted, whatever fails first.
    pub fn restore(&mut self) {
        let _ = ratatui::try_restore();
        let _ = epilogue(&mut io::stdout(), self.console);
        put_back(&self.saved);
    }

    /// Step aside for a child or a suspend: the alternate screen left, the
    /// cursor shown, raw mode off, the saved settings back. The caller has
    /// already stopped reading the terminal (one thread reads it, and it
    /// reads nothing while a child runs).
    pub fn leave(&mut self) {
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
        Ok(())
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
