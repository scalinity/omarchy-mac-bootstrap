//! Screen 1, Welcome and machine identity (docs/UX.md → *Every screen*):
//! one page of facts — this machine, the tool and the core, the session and
//! the read it shows, where the journey stands. A fact read from a record
//! carries the word *recorded*; nothing the core has not derived is shown as
//! done.

use super::{Item, draw_items};
use crate::app::Model;
use crate::core::VERSION;
use crate::theme::{Theme, Token};
use crate::widgets;
use ratatui::Frame;
use ratatui::layout::Rect;

fn pair(label: &str, value: String) -> Item<'static> {
    Item::Pair {
        label: label.into(),
        value,
        token: Token::Text,
        state: "info",
        recorded: false,
    }
}

pub fn items(m: &Model) -> Vec<Item<'_>> {
    let mut v = vec![Item::Heading("Welcome to Omarchy Mac Bootstrap")];
    // What this session may do, from hello's ceiling and the snapshot's
    // actions (docs/UX.md → *Layout*: the core says it).
    if let Some(h) = &m.hello {
        let actions = m.snap.as_ref().map_or(0, |s| s.actions.len());
        v.push(Item::Text(
            if h.ceiling == "read" && actions == 0 {
                "This session is read-only: nothing on this machine changes.".into()
            } else {
                "A step runs only when it is chosen; its conditions are checked again first.".into()
            },
            Token::Muted,
        ));
    }
    v.push(Item::Blank);
    v.push(Item::Heading("This machine"));
    let facts: Vec<_> = m
        .snap
        .as_ref()
        .map(|s| s.facts.iter().collect())
        .unwrap_or_default();
    let machine: Vec<_> = facts
        .iter()
        .filter(|f| f.key.starts_with("machine."))
        .collect();
    if machine.is_empty() {
        v.push(Item::Text(
            "This session's snapshot holds no machine facts.".into(),
            Token::Muted,
        ));
    }
    for f in machine {
        v.push(Item::Pair {
            label: if f.key == "machine.model" {
                widgets::model_label(&f.value).into()
            } else {
                f.label.clone()
            },
            value: widgets::fact_value(&f.key, &f.label, &f.value),
            token: Token::Text,
            state: &f.state,
            recorded: false,
        });
    }
    v.push(Item::Blank);
    v.push(Item::Heading("The tool and the core"));
    let dot = ", ";
    match &m.hello {
        Some(h) => {
            v.push(pair(
                "Interface",
                format!("frontend {VERSION}{dot}protocol {}", h.proto),
            ));
            v.push(pair("Bootstrap", format!("version {}", h.core)));
            v.push(pair(
                "System",
                format!("{}{dot}{}{dot}{}", h.platform, h.arch, h.user),
            ));
            v.push(pair(
                "Session",
                crate::widgets::authority(
                    m,
                    &crate::theme::Theme::new(crate::theme::Caps {
                        depth: crate::theme::Depth::None,
                        truecolor: false,
                        unicode: true,
                        console: false,
                    }),
                    false,
                ),
            ));
        }
        None => v.push(Item::Text(
            "The core has not said who it is yet.".into(),
            Token::Muted,
        )),
    }
    // The frontend's release as the core reads it (`frontend.*`): the
    // verified version, target and digest, when the core sends them.
    for f in facts.iter().filter(|f| f.key.starts_with("frontend.")) {
        v.push(Item::Pair {
            label: f.label.clone(),
            value: widgets::fact_value(&f.key, &f.label, &f.value),
            token: Token::Text,
            state: &f.state,
            recorded: false,
        });
    }
    v.push(Item::Blank);
    v.push(Item::Heading("Where the journey stands"));
    v.push(Item::Rail);
    for g in m.guides() {
        v.push(pair("Next", g.clone()));
    }
    let blocked = m.snap.as_ref().map_or(0, |s| s.blockers.len());
    if blocked > 0 {
        v.push(Item::Text(
            format!("{blocked} blocker(s): the Journey screen shows each with its fix."),
            Token::Warn,
        ));
    }
    let recorded: Vec<_> = facts
        .iter()
        .filter(|f| f.key.starts_with("recorded."))
        .collect();
    if !recorded.is_empty() {
        v.push(Item::Blank);
        v.push(Item::Heading("Recorded"));
        for f in recorded {
            v.push(Item::Pair {
                label: f.label.clone(),
                value: widgets::fact_value(&f.key, &f.label, &f.value),
                token: Token::Text,
                state: &f.state,
                recorded: true,
            });
        }
    }
    v
}

pub fn draw(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let inner = widgets::panel(f, area, "Welcome", t);
    draw_items(f, inner, &items(m), m.welcome_scroll, None, m, t);
}
