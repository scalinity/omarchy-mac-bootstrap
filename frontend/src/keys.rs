//! The keymap (docs/UX.md → *Keys*). The footer's hints and the help screen
//! are generated from this one table, so they can never disagree with what
//! the keys do. The keyboard reaches everything; the mouse is never captured.

use crate::app::{LogsTab, Region, Screen};

/// Where a binding applies.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Place {
    /// Every screen, fields included.
    Always,
    /// Every main screen while no text field has the keys.
    Everywhere,
    Dashboard,
    Welcome,
    /// The navigation rail.
    Nav,
    /// A detail table: machine, status, health.
    Table,
    /// The tool's log.
    Logs,
    /// The core's diagnostics.
    Diagnostics,
    /// The plan check's size fields.
    Plan,
    Gate,
    Help,
    Connecting,
    Fatal,
}

pub struct Binding {
    pub place: Place,
    /// The keys as shown, Unicode form.
    pub keys: &'static str,
    /// The keys as shown on an ASCII terminal.
    pub ascii: &'static str,
    pub does: &'static str,
    /// Shown in the footer at this priority (lower first), or never (0).
    pub hint: u8,
}

const fn b(
    place: Place,
    keys: &'static str,
    ascii: &'static str,
    does: &'static str,
    hint: u8,
) -> Binding {
    Binding {
        place,
        keys,
        ascii,
        does,
        hint,
    }
}

pub static KEYMAP: &[Binding] = &[
    b(Place::Dashboard, "⏎", "enter", "select", 1),
    b(Place::Dashboard, "↑↓", "up/down", "move", 2),
    b(Place::Dashboard, "k j", "k j", "move (vim)", 0),
    b(Place::Dashboard, "PgUp PgDn", "PgUp PgDn", "scroll", 0),
    b(Place::Welcome, "⏎", "enter", "the journey", 1),
    b(Place::Welcome, "↑↓", "up/down", "scroll", 2),
    b(Place::Welcome, "PgUp PgDn", "PgUp PgDn", "scroll a page", 0),
    b(Place::Nav, "↑↓", "up/down", "choose", 1),
    b(Place::Nav, "⏎ →", "enter ->", "open", 2),
    b(Place::Nav, "k j", "k j", "choose (vim)", 0),
    b(Place::Table, "↑↓", "up/down", "move", 1),
    b(Place::Table, "/", "/", "filter", 2),
    b(Place::Table, "⏎", "enter", "the full row", 0),
    b(Place::Table, "k j", "k j", "move (vim)", 0),
    b(
        Place::Table,
        "PgUp PgDn",
        "PgUp PgDn",
        "a page; past the rows read, the next page",
        0,
    ),
    b(
        Place::Table,
        "Home End",
        "Home End",
        "first and last (and g G)",
        0,
    ),
    b(Place::Logs, "↑↓", "up/down", "move", 1),
    b(Place::Logs, "/", "/", "filter", 2),
    b(Place::Logs, "f", "f", "next level", 3),
    b(Place::Logs, "Tab", "Tab", "diagnostics", 0),
    b(Place::Logs, "⏎", "enter", "the full line", 0),
    b(Place::Logs, "PgUp PgDn", "PgUp PgDn", "a page", 0),
    b(
        Place::Logs,
        "Home End",
        "Home End",
        "first and last (and g G)",
        0,
    ),
    b(Place::Diagnostics, "↑↓", "up/down", "scroll", 1),
    b(Place::Diagnostics, "Tab", "Tab", "the tool's log", 2),
    b(Place::Plan, "⏎", "enter", "check", 1),
    b(Place::Plan, "Tab", "Tab", "next field", 2),
    b(Place::Plan, "esc", "esc", "back", 3),
    b(
        Place::Plan,
        "the size",
        "the size",
        "type it, as 250GB, 1.5TB or 30%",
        0,
    ),
    b(Place::Plan, "Ctrl-U", "Ctrl-U", "clear", 0),
    b(
        Place::Plan,
        "PgUp PgDn",
        "PgUp PgDn",
        "scroll the answer",
        0,
    ),
    b(Place::Gate, "the word", "the word", "type it exactly", 0),
    b(Place::Gate, "⏎", "enter", "continue (exact word)", 1),
    b(Place::Gate, "Ctrl-U", "Ctrl-U", "clear", 0),
    b(Place::Gate, "esc", "esc", "cancel", 2),
    b(Place::Help, "esc", "esc", "back", 1),
    b(Place::Help, "↑↓", "up/down", "scroll", 2),
    b(Place::Connecting, "q", "q", "quit", 1),
    b(Place::Fatal, "r", "r", "try again", 1),
    b(Place::Fatal, "q", "q", "leave", 2),
    b(Place::Everywhere, "r", "r", "refresh", 3),
    b(Place::Everywhere, "L", "L", "logs", 4),
    b(Place::Everywhere, "?", "?", "help", 5),
    b(Place::Everywhere, "q", "q", "quit", 6),
    b(
        Place::Everywhere,
        "← →",
        "<- ->",
        "the rail or the workspace",
        0,
    ),
    b(Place::Everywhere, "Tab", "Tab", "move focus", 0),
    b(Place::Everywhere, "esc", "esc", "back", 0),
    b(
        Place::Everywhere,
        "s",
        "s",
        "the sidebar, at narrow widths",
        0,
    ),
    b(
        Place::Always,
        "Ctrl-C",
        "Ctrl-C",
        "quit when idle, cancel a request that can be",
        0,
    ),
    b(
        Place::Always,
        "Ctrl-Z",
        "Ctrl-Z",
        "suspend (not while a request runs)",
        0,
    ),
];

/// The place whose keys apply on SCREEN with REGION focused.
pub fn place(screen: Screen, region: Region, logs: LogsTab) -> Place {
    match screen {
        Screen::Gate => Place::Gate,
        Screen::Help => Place::Help,
        Screen::Connecting => Place::Connecting,
        Screen::Fatal => Place::Fatal,
        _ if region == Region::Nav => Place::Nav,
        Screen::Dashboard => Place::Dashboard,
        Screen::Welcome => Place::Welcome,
        Screen::Plan => Place::Plan,
        Screen::Logs if logs == LogsTab::Diagnostics => Place::Diagnostics,
        Screen::Logs => Place::Logs,
        Screen::Machine | Screen::Status | Screen::Health => Place::Table,
    }
}

/// Whether the frame's own letters (r, L, ?, q) work in PLACE: not where a
/// text field or a gate has the keys, and not where only a few keys work.
fn frame_keys(place: Place) -> bool {
    !matches!(
        place,
        Place::Plan | Place::Gate | Place::Help | Place::Connecting | Place::Fatal
    )
}

/// The footer's hints for PLACE: at most MAX, by priority.
pub fn hints(place: Place, unicode: bool, max: usize) -> Vec<(&'static str, &'static str)> {
    let mut v: Vec<&Binding> = KEYMAP
        .iter()
        .filter(|b| {
            b.hint > 0 && (b.place == place || (b.place == Place::Everywhere && frame_keys(place)))
        })
        .collect();
    v.sort_by_key(|b| b.hint);
    let mut out: Vec<(&str, &str)> = v
        .iter()
        .map(|b| (if unicode { b.keys } else { b.ascii }, b.does))
        .collect();
    if out.len() > max && frame_keys(place) {
        // Help stays reachable when hints shrink.
        out.truncate(max.saturating_sub(1));
        out.push(("?", "help"));
    } else {
        out.truncate(max);
    }
    out
}

/// The bindings help lists for the screen BACK it was opened from: that
/// screen's own keys, the rail's while the rail has the keys, and the frame's.
pub fn help_for(
    back: Screen,
    region: Region,
    logs: LogsTab,
    unicode: bool,
) -> Vec<(&'static str, &'static str)> {
    let mut out = help(place(back, Region::Work, logs), unicode);
    if region == Region::Nav {
        for b in help(Place::Nav, unicode) {
            if !out.contains(&b) {
                out.push(b);
            }
        }
    }
    out
}

/// Every binding the help screen lists for PLACE.
pub fn help(place: Place, unicode: bool) -> Vec<(&'static str, &'static str)> {
    KEYMAP
        .iter()
        .filter(|b| {
            b.place == place
                || b.place == Place::Always
                || (b.place == Place::Everywhere && frame_keys(place))
        })
        .map(|b| (if unicode { b.keys } else { b.ascii }, b.does))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [Place; 11] = [
        Place::Dashboard,
        Place::Welcome,
        Place::Nav,
        Place::Table,
        Place::Logs,
        Place::Diagnostics,
        Place::Plan,
        Place::Gate,
        Place::Help,
        Place::Connecting,
        Place::Fatal,
    ];

    #[test]
    fn hints_shrink_but_keep_help() {
        let all = hints(Place::Dashboard, true, 10);
        assert_eq!(all.first().unwrap().1, "select");
        let three = hints(Place::Dashboard, true, 3);
        assert_eq!(three.len(), 3);
        assert_eq!(three.last().unwrap(), &("?", "help"));
        // At narrow widths the logs hint gives way; help never does.
        let four = hints(Place::Dashboard, true, 4);
        assert!(!four.iter().any(|(k, _)| *k == "L"), "{four:?}");
        assert!(
            hints(Place::Dashboard, true, 6)
                .iter()
                .any(|(k, d)| *k == "L" && *d == "logs")
        );
    }

    #[test]
    fn the_gate_has_no_single_letter_commands() {
        for (k, _) in hints(Place::Gate, true, 9) {
            assert!(k.chars().count() != 1 || k == "⏎", "{k}");
        }
    }

    /// Where a field has the keys, no hint or help line offers a letter the
    /// field would take as text.
    #[test]
    fn fields_offer_no_letters() {
        for place in [Place::Plan, Place::Gate] {
            for (k, _) in hints(place, true, 9).into_iter().chain(help(place, true)) {
                assert!(
                    !(k.chars().count() == 1
                        && k.chars()
                            .all(|c| c.is_ascii_alphanumeric() || c == '?' || c == '/')),
                    "{place:?}: {k}"
                );
            }
        }
    }

    #[test]
    fn ascii_hints_are_ascii() {
        for place in ALL {
            for (k, d) in help(place, false) {
                assert!(k.is_ascii() && d.is_ascii(), "{k} {d}");
            }
        }
    }

    /// Every hint is a binding the help for the same place lists.
    #[test]
    fn hints_come_from_the_help_of_their_place() {
        for place in ALL {
            let h = help(place, true);
            for hint in hints(place, true, 9) {
                assert!(h.contains(&hint), "{place:?}: {hint:?}");
            }
        }
    }
}
