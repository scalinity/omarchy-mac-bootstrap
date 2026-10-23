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
    /// A row's full values, open under it in a detail table or the log.
    Value,
    /// The core's diagnostics.
    Diagnostics,
    /// The planner's fields.
    Plan,
    /// Another action's parameters.
    Form,
    /// The Asahi handoff, the Linux continuation.
    Install,
    /// Omarchy Mac's progress.
    Progress,
    /// Shared creation.
    Shared,
    /// The environment scan.
    Scan,
    /// The migration selection's categories.
    Selection,
    /// The inventory's list.
    Inventory,
    /// An item's choices, open in the inventory.
    Item,
    /// The Migration Review and the profile's actions.
    Review,
    Restore,
    Conflicts,
    Health,
    Brief,
    Qualification,
    Completion,
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
    b(Place::Qualification, "⏎", "enter", "read again", 1),
    b(Place::Qualification, "t", "t", "test step (typed gate)", 2),
    b(Place::Qualification, "↑↓", "up/down", "scroll", 0),
    b(
        Place::Qualification,
        "PgUp PgDn",
        "PgUp PgDn",
        "scroll a page",
        0,
    ),
    b(Place::Completion, "↑↓", "up/down", "scroll", 1),
    b(
        Place::Completion,
        "PgUp PgDn",
        "PgUp PgDn",
        "scroll a page",
        0,
    ),
    b(
        Place::Dashboard,
        "[ ]",
        "[ ]",
        "choose station; enter opens",
        0,
    ),
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
    b(Place::Value, "↑↓", "up/down", "scroll", 1),
    b(Place::Value, "⏎ esc", "enter esc", "close", 2),
    b(Place::Value, "Home End", "Home End", "start, end", 3),
    b(Place::Value, "k j", "k j", "scroll (vim)", 0),
    b(Place::Value, "PgUp PgDn", "PgUp PgDn", "a page", 0),
    b(Place::Value, "g G", "g G", "start, end (vim)", 0),
    b(Place::Diagnostics, "↑↓", "up/down", "scroll", 1),
    b(Place::Diagnostics, "Tab", "Tab", "the tool's log", 2),
    b(Place::Plan, "⏎", "enter", "review", 1),
    b(
        Place::Plan,
        "⏎ again",
        "enter again",
        "save a review the core answered, where it offers plan.save",
        0,
    ),
    b(
        Place::Plan,
        "←→",
        "left/right",
        "preset or selected unit",
        0,
    ),
    b(Place::Plan, "↑↓", "up/down", "field, then scroll", 0),
    b(Place::Plan, "Home End", "Home End", "top, bottom", 0),
    b(Place::Plan, "Tab", "Tab", "next field", 2),
    b(Place::Plan, "esc", "esc", "back", 3),
    b(
        Place::Plan,
        "the size",
        "the size",
        "Custom: type a number; Tab selects GB, TB or %",
        0,
    ),
    b(
        Place::Plan,
        "space",
        "space",
        "the next choice, in a choice",
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
    b(Place::Form, "⏎", "enter", "check", 1),
    b(
        Place::Form,
        "⏎ again",
        "enter again",
        "go on with a review the core answered",
        0,
    ),
    b(Place::Form, "Tab", "Tab", "next field", 2),
    b(Place::Form, "esc", "esc", "back", 3),
    b(Place::Form, "the value", "the value", "type it", 0),
    b(
        Place::Form,
        "space",
        "space",
        "the next choice, in a choice",
        0,
    ),
    b(Place::Form, "Ctrl-U", "Ctrl-U", "clear", 0),
    b(
        Place::Form,
        "PgUp PgDn",
        "PgUp PgDn",
        "scroll the answer",
        0,
    ),
    b(Place::Install, "⏎", "enter", "continue", 1),
    b(Place::Install, "n", "n", "network, where offered", 2),
    b(Place::Install, "↑↓", "up/down", "scroll", 0),
    b(Place::Install, "PgUp PgDn", "PgUp PgDn", "scroll a page", 0),
    b(Place::Progress, "↑↓", "up/down", "scroll", 1),
    b(Place::Shared, "⏎", "enter", "continue", 1),
    b(Place::Shared, "↑↓", "up/down", "scroll", 2),
    b(Place::Scan, "⏎", "enter", "scan", 1),
    b(Place::Scan, "↑↓", "up/down", "scroll", 2),
    b(Place::Selection, "↑↓", "up/down", "move", 1),
    b(Place::Selection, "space", "space", "all in or out", 2),
    b(Place::Selection, "⏎", "enter", "its items", 3),
    b(Place::Inventory, "space", "space", "include", 1),
    b(Place::Inventory, "⏎", "enter", "details", 2),
    b(Place::Inventory, "f", "f", "category", 3),
    b(Place::Inventory, "/", "/", "filter", 4),
    b(Place::Inventory, "↑↓", "up/down", "move", 0),
    b(
        Place::Inventory,
        "PgUp PgDn",
        "PgUp PgDn",
        "a page; past the rows read, the next page",
        0,
    ),
    b(Place::Item, "↑↓", "up/down", "choose", 1),
    b(Place::Item, "⏎", "enter", "pick", 2),
    b(Place::Item, "esc", "esc", "close", 3),
    b(Place::Review, "↑↓", "up/down", "move", 1),
    b(Place::Review, "⏎", "enter", "go on", 2),
    b(Place::Restore, "enter", "enter", "review action", 1),
    b(Place::Restore, "d", "d", "conflicts", 2),
    b(Place::Restore, "n p", "n p", "choose action", 0),
    b(
        Place::Restore,
        "up/down PgUp PgDn Home End",
        "up/down PgUp PgDn Home End",
        "scroll (and j k g G)",
        0,
    ),
    b(
        Place::Conflicts,
        "k R K",
        "k R K",
        "keep, replace, keep rest",
        1,
    ),
    b(Place::Conflicts, "n p", "n p", "next, previous", 2),
    b(Place::Conflicts, "v", "v", "side by side at 120 columns", 0),
    b(
        Place::Conflicts,
        "up/down PgUp PgDn Home End",
        "up/down PgUp PgDn Home End",
        "scroll (and j g G)",
        0,
    ),
    b(Place::Health, "c", "c", "MCP list (asks first)", 1),
    b(
        Place::Health,
        "up/down",
        "up/down",
        "choose row (and j k)",
        2,
    ),
    b(Place::Health, "enter", "enter", "full row", 0),
    b(Place::Health, "/", "/", "filter", 0),
    b(
        Place::Health,
        "PgUp PgDn Home End",
        "PgUp PgDn Home End",
        "page, first, last",
        0,
    ),
    b(Place::Brief, "up/down", "up/down", "scroll (and j k)", 1),
    b(Place::Brief, "esc", "esc", "back", 2),
    b(
        Place::Brief,
        "PgUp PgDn Home End",
        "PgUp PgDn Home End",
        "page, start, end (and g G)",
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
    b(Place::Fatal, "D", "D", "debugging brief", 3),
    b(Place::Everywhere, "D", "D", "debugging brief", 0),
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
        Screen::Form => Place::Form,
        Screen::Logs if logs == LogsTab::Diagnostics => Place::Diagnostics,
        Screen::Logs => Place::Logs,
        Screen::Machine | Screen::Status | Screen::Operation => Place::Table,
        Screen::Health => Place::Health,
        Screen::Restore => Place::Restore,
        Screen::Conflicts => Place::Conflicts,
        Screen::Brief => Place::Brief,
        Screen::Qualification => Place::Qualification,
        Screen::Completion => Place::Completion,
        Screen::Install => Place::Install,
        Screen::Progress => Place::Progress,
        Screen::Shared => Place::Shared,
        Screen::Scan => Place::Scan,
        Screen::Selection => Place::Selection,
        Screen::Inventory => Place::Inventory,
        Screen::Review => Place::Review,
    }
}

/// Whether the frame's own letters (r, L, ?, q) work in PLACE: not where a
/// text field or a gate has the keys, and not where only a few keys work.
fn frame_keys(place: Place) -> bool {
    !matches!(
        place,
        Place::Plan | Place::Form | Place::Gate | Place::Help | Place::Connecting | Place::Fatal
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
/// screen's own keys (an open VALUE's, when one is open there), the rail's
/// while the rail has the keys, and the frame's.
pub fn help_for(
    back: Screen,
    region: Region,
    logs: LogsTab,
    value: bool,
    unicode: bool,
) -> Vec<(&'static str, &'static str)> {
    let own = if value {
        Place::Value
    } else {
        place(back, Region::Work, logs)
    };
    let mut out = help(own, unicode);
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

    const ALL: [Place; 27] = [
        Place::Dashboard,
        Place::Welcome,
        Place::Nav,
        Place::Table,
        Place::Logs,
        Place::Value,
        Place::Diagnostics,
        Place::Plan,
        Place::Form,
        Place::Install,
        Place::Progress,
        Place::Shared,
        Place::Scan,
        Place::Selection,
        Place::Inventory,
        Place::Item,
        Place::Review,
        Place::Restore,
        Place::Conflicts,
        Place::Health,
        Place::Brief,
        Place::Qualification,
        Place::Completion,
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
        for place in [Place::Plan, Place::Form, Place::Gate] {
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
