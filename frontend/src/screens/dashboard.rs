//! Screen 2, the Journey dashboard (docs/UX.md → *Journey dashboard*): the
//! traverse, where the journey stands — the core's next step, its blockers
//! and warnings — the snapshot's facts, its codes, and the actions available
//! now. No action is offered that the core did not list; a station the core
//! derived no stage for is drawn as *later*.

use super::{Item, draw_items, machine_lines};
use crate::app::{Model, Region};
use crate::theme::{Theme, Token};
use crate::widgets::{self, Tier};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::widgets::Paragraph;

/// What a code's kind is called on the screen.
fn code_label(kind: &str) -> String {
    match kind {
        "token" => "Resume token".into(),
        k => k.to_string(),
    }
}

pub fn items(m: &Model) -> Vec<Item<'_>> {
    let mut v = vec![Item::Rail, Item::Blank, Item::Heading("Where it stands")];
    let Some(s) = &m.snap else {
        v.push(Item::Text(
            "No snapshot has been read yet.".into(),
            Token::Muted,
        ));
        return v;
    };
    if s.guides.is_empty() {
        v.push(Item::Text(
            "The core gave no next step for this session.".into(),
            Token::Muted,
        ));
    }
    for g in &s.guides {
        v.push(Item::Text(g.clone(), Token::Text));
    }
    v.extend(s.blockers.iter().map(Item::Blocker));
    v.extend(s.warnings.iter().map(Item::Warning));
    v.extend(s.messages.iter().map(|(l, t)| Item::Message(*l, t)));
    let facts: Vec<_> = s
        .facts
        .iter()
        .filter(|f| !f.key.starts_with("machine."))
        .collect();
    if !facts.is_empty() {
        v.push(Item::Blank);
        v.push(Item::Heading("Facts"));
        for f in facts {
            v.push(Item::Pair {
                label: f.label.clone(),
                value: f.value.clone(),
                token: Token::Text,
                state: &f.state,
                recorded: f.key.starts_with("recorded."),
            });
        }
    }
    if !s.codes.is_empty() {
        v.push(Item::Blank);
        v.push(Item::Heading("Codes"));
        for (kind, value) in &s.codes {
            v.push(Item::Pair {
                label: code_label(kind),
                value: value.clone(),
                token: Token::Text,
                state: "info",
                recorded: false,
            });
        }
    }
    v.push(Item::Blank);
    v.push(Item::Heading("Actions"));
    if s.actions.is_empty() {
        v.push(Item::Text("Nothing is available now.".into(), Token::Muted));
    }
    v.extend((0..s.actions.len()).map(Item::Action));
    if let Some(a) = m.focused()
        && !a.explain.is_empty()
    {
        v.push(Item::Explain(&a.explain));
    }
    v
}

pub fn draw(f: &mut Frame, area: Rect, m: &Model, t: &Theme, tier: Tier) {
    // At the standard width the sidebar's machine panel moves under the
    // workspace's own, when there is room for both.
    let width = area.width.saturating_sub(2) as usize;
    let machine = machine_lines(m, t, width);
    let side_h = machine.len() as u16 + 2;
    let has_machine = m
        .snap
        .as_ref()
        .is_some_and(|s| s.facts.iter().any(|f| f.key.starts_with("machine.")));
    let (main, side) = if tier == Tier::Standard && has_machine && area.height >= side_h + 12 {
        let [a, b] =
            Layout::vertical([Constraint::Min(10), Constraint::Length(side_h)]).areas(area);
        (a, Some(b))
    } else {
        (area, None)
    };
    let reading = m.reading(|r| matches!(r, crate::app::Req::Snapshot));
    let title = if reading {
        format!("Journey {} reading", t.g.dot)
    } else {
        "Journey".to_string()
    };
    let inner = widgets::panel(f, main, &title, t);
    let items = items(m);
    let focus = (m.region == Region::Work && m.focused().is_some())
        .then(|| {
            items
                .iter()
                .position(|i| matches!(i, Item::Action(n) if *n == m.focus))
        })
        .flatten();
    draw_items(f, inner, &items, m.dash_scroll, focus, m, t);
    if let Some(side) = side {
        let inner = widgets::panel(f, side, "This machine", t);
        f.render_widget(Paragraph::new(machine), inner);
    }
}
