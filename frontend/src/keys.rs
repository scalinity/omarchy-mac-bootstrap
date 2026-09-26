//! The keymap (docs/UX.md → *Keys*). The footer's hints and the help screen
//! are generated from this one table, so they can never disagree with what
//! the keys do. The keyboard reaches everything; the mouse is never captured.

/// Where a binding applies.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Place {
    Everywhere,
    Dashboard,
    Gate,
    Logs,
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

pub static KEYMAP: &[Binding] = &[
    Binding {
        place: Place::Dashboard,
        keys: "⏎",
        ascii: "enter",
        does: "run",
        hint: 1,
    },
    Binding {
        place: Place::Dashboard,
        keys: "↑↓",
        ascii: "up/down",
        does: "move",
        hint: 2,
    },
    Binding {
        place: Place::Dashboard,
        keys: "k j",
        ascii: "k j",
        does: "move (vim)",
        hint: 0,
    },
    Binding {
        place: Place::Dashboard,
        keys: "r",
        ascii: "r",
        does: "refresh",
        hint: 3,
    },
    Binding {
        place: Place::Dashboard,
        keys: "L",
        ascii: "L",
        does: "logs",
        hint: 4,
    },
    Binding {
        place: Place::Everywhere,
        keys: "?",
        ascii: "?",
        does: "help",
        hint: 5,
    },
    Binding {
        place: Place::Everywhere,
        keys: "q",
        ascii: "q",
        does: "quit",
        hint: 6,
    },
    Binding {
        place: Place::Everywhere,
        keys: "Ctrl-C",
        ascii: "Ctrl-C",
        does: "quit when idle, cancel a request that can be",
        hint: 0,
    },
    Binding {
        place: Place::Everywhere,
        keys: "Ctrl-Z",
        ascii: "Ctrl-Z",
        does: "suspend (not while a request runs)",
        hint: 0,
    },
    Binding {
        place: Place::Gate,
        keys: "the word",
        ascii: "the word",
        does: "type it exactly",
        hint: 0,
    },
    Binding {
        place: Place::Gate,
        keys: "⏎",
        ascii: "enter",
        does: "continue (only the exact word)",
        hint: 1,
    },
    Binding {
        place: Place::Gate,
        keys: "Ctrl-U",
        ascii: "Ctrl-U",
        does: "clear",
        hint: 0,
    },
    Binding {
        place: Place::Gate,
        keys: "esc",
        ascii: "esc",
        does: "cancel",
        hint: 2,
    },
    Binding {
        place: Place::Logs,
        keys: "esc",
        ascii: "esc",
        does: "back",
        hint: 1,
    },
    Binding {
        place: Place::Logs,
        keys: "↑↓",
        ascii: "up/down",
        does: "scroll",
        hint: 2,
    },
];

/// The footer's hints for PLACE: at most MAX, by priority.
pub fn hints(place: Place, unicode: bool, max: usize) -> Vec<(&'static str, &'static str)> {
    let mut v: Vec<&Binding> = KEYMAP
        .iter()
        .filter(|b| {
            b.hint > 0
                && (b.place == place || (b.place == Place::Everywhere && place != Place::Gate))
        })
        .collect();
    v.sort_by_key(|b| b.hint);
    let mut out: Vec<(&str, &str)> = v
        .iter()
        .map(|b| (if unicode { b.keys } else { b.ascii }, b.does))
        .collect();
    if out.len() > max {
        // Help stays reachable when hints shrink.
        out.truncate(max.saturating_sub(1));
        out.push(("?", "help"));
    }
    out
}

/// Every binding the help screen lists for PLACE.
pub fn help(place: Place, unicode: bool) -> Vec<(&'static str, &'static str)> {
    KEYMAP
        .iter()
        .filter(|b| b.place == place || b.place == Place::Everywhere)
        .map(|b| (if unicode { b.keys } else { b.ascii }, b.does))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hints_shrink_but_keep_help() {
        let all = hints(Place::Dashboard, true, 10);
        assert_eq!(all.first().unwrap().1, "run");
        let three = hints(Place::Dashboard, true, 3);
        assert_eq!(three.len(), 3);
        assert_eq!(three.last().unwrap(), &("?", "help"));
    }

    #[test]
    fn the_gate_has_no_single_letter_commands() {
        for (k, _) in hints(Place::Gate, true, 9) {
            assert!(k.chars().count() != 1 || k == "⏎", "{k}");
        }
    }

    #[test]
    fn ascii_hints_are_ascii() {
        for place in [Place::Dashboard, Place::Gate, Place::Logs] {
            for (k, d) in help(place, false) {
                assert!(k.is_ascii() && d.is_ascii(), "{k} {d}");
            }
        }
    }
}
