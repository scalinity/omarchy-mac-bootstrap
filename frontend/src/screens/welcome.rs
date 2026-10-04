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

/// The first 12 characters of an identifier, which the detail views show
/// whole.
fn short(id: &str) -> &str {
    id.get(..12).unwrap_or(id)
}

pub fn items(m: &Model) -> Vec<Item<'_>> {
    let mut v = vec![Item::Heading("This machine")];
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
            label: f.label.clone(),
            value: f.value.clone(),
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
            let mut core = format!("core {}", h.core);
            if !h.commit.is_empty() {
                core.push_str(&format!("{dot}commit {}", short(&h.commit)));
            }
            v.push(pair("Core", core));
            v.push(pair(
                "System",
                format!("{}{dot}{}{dot}{}", h.platform, h.arch, h.user),
            ));
            let mut session = format!("{} ceiling", h.ceiling);
            if h.fixture {
                session.push_str(&format!("{dot}fixture"));
            }
            if h.dry_run {
                session.push_str(&format!("{dot}dry run"));
            }
            if m.check {
                session.push_str(&format!("{dot}the startup check"));
            }
            v.push(pair("Session", session));
        }
        None => v.push(Item::Text(
            "The core has not said who it is yet.".into(),
            Token::Muted,
        )),
    }
    if let Some(g) = m.generation(crate::read::Scope::Journey) {
        v.push(pair("Read", format!("journey generation {}", short(g))));
    }
    v.push(Item::Blank);
    v.push(Item::Heading("Where the journey stands"));
    v.push(Item::Rail);
    for g in m.snap.as_ref().map(|s| s.guides.as_slice()).unwrap_or(&[]) {
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
                value: f.value.clone(),
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
