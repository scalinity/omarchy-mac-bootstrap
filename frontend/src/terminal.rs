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
use std::sync::{Arc, Mutex};
use std::time::Duration;

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
        while event::poll(Duration::from_millis(0))? {
            let _ = event::read()?;
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
    fn the_epilogue_shows_the_cursor_and_clears_the_console() {
        let mut v = Vec::new();
        epilogue(&mut v, false).unwrap();
        assert_eq!(v, b"\x1b[?25h");
        let mut v = Vec::new();
        epilogue(&mut v, true).unwrap();
        assert_eq!(v, b"\x1b[?25h\x1b[H\x1b[2J");
    }
}
