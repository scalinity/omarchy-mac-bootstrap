//! A scrollable page of the core's fixed brief and machine facts.
use super::{Item, draw_items};
use crate::app::Model;
use crate::read::Kind;
use crate::theme::{Theme, Token};
use crate::widgets;
use ratatui::Frame;
use ratatui::layout::Rect;

pub fn items(m: &Model) -> Vec<Item<'_>> {
    let mut v = vec![Item::Text(
        "./omarchy-bootstrap debug > file keeps a copy. Esc returns to the error.".into(),
        Token::Accent,
    )];
    if let Some(f) = &m.debug.fault {
        v.push(Item::Fault(f));
    }
    let Some(d) = m.detail(Kind::Brief) else {
        v.push(Item::Text(
            "Reading the core's debugging brief; r asks again.".into(),
            Token::Muted,
        ));
        return v;
    };
    if let Some(f) = &d.fault {
        v.push(Item::Fault(f));
    }
    if d.changed || m.generation(Kind::Brief.scope()) != Some(d.generation.as_str()) {
        v.push(Item::Text(
            "Changed since you looked - r.".into(),
            Token::Warn,
        ));
    }
    if d.loaded && !m.whole(Kind::Brief) {
        v.push(Item::Text(
            format!("{} of {} brief lines read.", d.rows.len(), d.total),
            Token::Muted,
        ));
    }
    let mut section = "";
    for r in &d.rows {
        if r.col(0) != section {
            section = r.col(0);
            v.push(Item::Text(section.into(), Token::Heading));
        }
        v.push(Item::Text(r.col(1).into(), Token::Text));
    }
    if m.whole(Kind::Brief) && d.rows.is_empty() {
        v.push(Item::Text(
            "The core supplied no brief lines.".into(),
            Token::Muted,
        ));
    }
    v
}

pub fn draw(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let inner = widgets::panel(f, area, "Debugging brief", t);
    draw_items(f, inner, &items(m), m.page_scroll, None, m, t);
}
