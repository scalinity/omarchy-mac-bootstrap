//! Health's added rows, grouped by the fact's owner. The tool's own MCP list
//! is a separate, confirmed action; this static view starts no tool.
use super::{Item, draw_items};
use crate::app::Model;
use crate::read::Kind;
use crate::theme::{Theme, Token};
use crate::widgets;
use ratatui::Frame;
use ratatui::layout::Rect;

pub fn enriched(m: &Model) -> bool {
    m.detail(Kind::Doctor)
        .is_some_and(|d| d.rows.iter().any(|r| crate::read::health_group(r) < 3))
}

pub fn items(m: &Model) -> (Vec<Item<'_>>, Option<usize>) {
    let mut v = vec![Item::Text(
        "Observed facts; c asks for the selected tool's MCP list (it may start servers).".into(),
        Token::Muted,
    )];
    if let Some(f) = &m.health.fault {
        v.push(Item::Fault(f));
    }
    let Some(d) = m.detail(Kind::Doctor) else {
        return (v, None);
    };
    if let Some(s) = [&m.health.snap, &m.health.held]
        .into_iter()
        .flatten()
        .find(|s| s.generation == d.generation)
        && !s.facts.is_empty()
    {
        v.push(Item::Text(
            s.facts
                .iter()
                .map(|f| format!("{} {}", f.label, f.value))
                .collect::<Vec<_>>()
                .join("; "),
            Token::Text,
        ));
    }
    if let Some(f) = &d.fault {
        v.push(Item::Fault(f));
    }
    if d.changed || m.generation(Kind::Doctor.scope()) != Some(d.generation.as_str()) {
        v.push(Item::Text(
            "Changed since you looked - r reads again.".into(),
            Token::Warn,
        ));
    }
    let shown = d.shown();
    if shown.is_empty() {
        v.push(Item::Text(
            "No row on this page matches the filter; / changes it.".into(),
            Token::Muted,
        ));
    }
    let focused = shown.get(d.cursor).copied();
    let groups = ["AI tools", "Restore", "SSH", "System checks"];
    let mut focus = None;
    for (i, heading) in groups.into_iter().enumerate() {
        if !shown.iter().any(|r| crate::read::health_group(r) == i) {
            continue;
        }
        v.push(Item::Heading(heading));
        for r in shown.iter().filter(|r| crate::read::health_group(r) == i) {
            let here = focused.is_some_and(|f| f.id == r.id);
            if here {
                focus = Some(v.len());
            }
            v.push(Item::Text(
                format!(
                    "{} {} - {}: {}",
                    if here { ">" } else { " " },
                    r.col(1),
                    r.col(0),
                    r.col(2)
                ),
                if here {
                    Token::Focus
                } else {
                    match r.col(0) {
                        "pass" => Token::Ok,
                        "warn" => Token::Warn,
                        "fail" => Token::Danger,
                        _ => Token::Text,
                    }
                },
            ));
        }
    }
    (v, focus)
}

pub fn draw(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let inner = widgets::panel(f, area, "Health", t);
    let (v, focus) = items(m);
    draw_items(f, inner, &v, 0, focus, m, t);
}
