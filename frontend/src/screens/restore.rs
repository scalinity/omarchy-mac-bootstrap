//! Screens 20 and 21: the core's layered review, progress and conflict diff.
use super::{Item, draw_items};
use crate::app::Model;
use crate::read::{Kind, Scope};
use crate::restore;
use crate::theme::{Theme, Token};
use crate::widgets;
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

fn text(s: impl Into<String>, token: Token) -> Item<'static> {
    Item::Text(s.into(), token)
}

/// Shared read states; a failed page supplies no whole review.
fn detail<'a>(m: &'a Model, kind: Kind, v: &mut Vec<Item<'a>>) -> bool {
    let Some(d) = m.detail(kind) else {
        v.push(text(
            format!("{}; r reads again.", kind.reading()),
            Token::Muted,
        ));
        return false;
    };
    if d.changed || m.generation(kind.scope()) != Some(d.generation.as_str()) {
        v.push(text(
            "Changed since you looked - r reads again.",
            Token::Warn,
        ));
        return false;
    }
    if let Some(f) = &d.fault {
        v.push(Item::Fault(f));
    }
    if !m.whole(kind) {
        v.push(text(
            format!(
                "Read {} of {} rows; choices wait for the whole review.",
                d.rows.len(),
                d.total
            ),
            Token::Muted,
        ));
        return false;
    }
    true
}

pub fn items(m: &Model) -> Vec<Item<'_>> {
    let mut v = Vec::new();
    if m.check {
        v.push(text(
            "The startup check reads only the journey.",
            Token::Muted,
        ));
        return v;
    }
    if let Some(f) = &m.restore.fault {
        v.push(Item::Fault(f));
    }
    if let Some(s) = m.snap_of(Scope::Restore) {
        v.extend(
            s.facts
                .iter()
                .filter(|f| f.key.starts_with("restore."))
                .map(Item::Check),
        );
        v.extend(s.blockers.iter().map(Item::Blocker));
        v.extend(s.warnings.iter().map(Item::Warning));
        let actions: Vec<_> = s
            .actions
            .iter()
            .filter(|a| matches!(a.id.as_str(), "restore.apply" | "restore.undo"))
            .collect();
        for (i, a) in actions.into_iter().enumerate() {
            v.push(text(
                format!(
                    "{} {} - type {}{}",
                    if i == m.rest.action { ">" } else { " " },
                    a.label,
                    a.gate,
                    if a.handoff { "; terminal handoff" } else { "" }
                ),
                Token::Accent,
            ));
        }
        v.push(text(
            "n/p choose an action; Enter reviews it. d opens conflicts (Keep by default).",
            Token::Muted,
        ));
    }
    if let Some(c) = &m.rest.checked {
        if c.status != "done" {
            v.push(text(
                format!("{} - {}: {}", c.status, c.code, c.text),
                Token::Warn,
            ));
        }
        for (name, code, reason) in &c.invalid {
            v.push(text(format!("{name}: {code} - {reason}"), Token::Warn));
        }
        for (_, reason, fix) in &c.warnings {
            v.push(text(format!("{reason} {fix}"), Token::Warn));
        }
    }
    if m.exec_scope == Scope::Restore && !m.steps.is_empty() {
        v.push(Item::Heading("Item progress"));
        for (label, done, total) in &m.steps {
            v.push(text(format!("{label} - {done} of {total}"), Token::Text));
        }
        v.extend(m.notes.iter().map(|(l, s)| Item::Message(*l, s)));
    }
    v.push(Item::Blank);
    v.push(Item::Heading("Review by layer"));
    if detail(m, Kind::RestoreReview, &mut v) {
        let rows = &m.detail(Kind::RestoreReview).expect("whole").rows;
        let mut layers: Vec<&str> = Vec::new();
        for r in rows {
            if !layers.contains(&r.col(0)) {
                layers.push(r.col(0));
            }
        }
        if rows.is_empty() {
            v.push(text("The core sent no restore items.", Token::Muted));
        }
        for layer in layers {
            v.push(text(layer, Token::Heading));
            for r in rows.iter().filter(|r| r.col(0) == layer) {
                v.push(text(
                    format!("{} [{}] - {} - {}", r.col(2), r.col(1), r.col(4), r.col(5)),
                    Token::Text,
                ));
                if !r.col(3).is_empty() {
                    v.push(text(format!("Destination: {}", r.col(3)), Token::Muted));
                }
            }
        }
    }
    v.push(Item::Heading("Restore status"));
    if detail(m, Kind::RestoreStatus, &mut v) {
        for r in &m.detail(Kind::RestoreStatus).expect("whole").rows {
            v.push(text(
                format!("{}: {} - {}", r.key, r.col(0), r.col(1)),
                Token::Text,
            ));
        }
    }
    v.push(Item::Heading("Bundles found"));
    if detail(m, Kind::Bundles, &mut v) {
        for r in &m.detail(Kind::Bundles).expect("whole").rows {
            v.push(text(
                format!("{} - {} - {}", r.key, r.col(0), r.col(1)),
                Token::Text,
            ));
            v.push(text(
                format!(
                    "{} items; {}; {}",
                    r.col(2),
                    crate::widgets::byte_text(r.col(3)),
                    r.col(4)
                ),
                Token::Muted,
            ));
        }
    }
    v
}

pub fn draw(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let inner = widgets::panel(f, area, "Restore progress", t);
    let counts = (m.exec_scope == Scope::Restore)
        .then(|| m.steps.last())
        .flatten();
    let [bar, body] = Layout::vertical([
        Constraint::Length(if counts.is_some() { 2 } else { 0 }),
        Constraint::Min(0),
    ])
    .areas(inner);
    if let Some((label, done, total)) = counts {
        let width = bar.width.saturating_sub(20) as usize;
        let filled = if *total > 0 {
            ((*done).min(*total) as u128 * width as u128 / *total as u128) as usize
        } else {
            0
        };
        let progress = format!(
            " [{}{}] {done} of {total}",
            "=".repeat(filled),
            " ".repeat(width - filled)
        );
        f.render_widget(
            Paragraph::new(vec![
                Line::styled(progress, t.style(Token::Accent)),
                Line::styled(
                    widgets::fit(&t.say(label), bar.width as usize, t.caps.unicode),
                    t.style(Token::Text),
                ),
            ]),
            bar,
        );
    }
    draw_items(f, body, &items(m), m.page_scroll, None, m, t);
}

pub fn conflict_items(m: &Model) -> Vec<Item<'_>> {
    let mut v = Vec::new();
    if let Some(f) = &m.restore.fault {
        v.push(Item::Fault(f));
    }
    if !detail(m, Kind::Conflicts, &mut v) {
        return v;
    }
    let d = m.detail(Kind::Conflicts).expect("whole");
    let Some(r) = d.rows.get(m.rest.conflict) else {
        v.push(text(
            "The review has no conflicts. Esc returns to restore.",
            Token::Muted,
        ));
        return v;
    };
    v.push(text(
        format!(
            "{} - conflict {} of {}",
            r.col(1),
            m.rest.conflict + 1,
            d.total
        ),
        Token::Heading,
    ));
    v.push(text(format!("{} - {}", r.key, r.col(2)), Token::Text));
    v.push(text(
        format!(
            "Now: {}; bundle: {}",
            crate::widgets::byte_text(r.col(3)),
            crate::widgets::byte_text(r.col(4))
        ),
        Token::Muted,
    ));
    v.push(text(
        if restore::replacing(&m.rest.replacements, &r.id) {
            "Replace chosen; the core will check and back up the original."
        } else {
            "Keep (default); this destination stays as it is."
        },
        Token::Accent,
    ));
    v.push(text(
        "k keep; R replace; K keep the rest; n/p conflict; v layout; Esc back",
        Token::Muted,
    ));
    v.push(Item::Blank);
    if !detail(m, Kind::Diff, &mut v) {
        return v;
    }
    let rows = diff_rows(m);
    if rows.is_empty() {
        v.push(text(
            "The core supplied no text diff for this conflict.",
            Token::Muted,
        ));
    }
    for row in rows {
        v.push(text(
            format!("{} {}", row.col(1), row.col(2)),
            diff_token(row.col(1)),
        ));
    }
    v
}

fn diff_token(op: &str) -> Token {
    match op {
        "+" => Token::Ok,
        "-" => Token::Danger,
        _ => Token::Text,
    }
}

fn diff_rows(m: &Model) -> Vec<&crate::read::Row> {
    let Some(r) = m
        .detail(Kind::Conflicts)
        .and_then(|d| d.rows.get(m.rest.conflict))
    else {
        return Vec::new();
    };
    m.detail(Kind::Diff)
        .filter(|_| m.whole(Kind::Diff))
        .map(|d| crate::restore::diff_rows(&d.rows, &r.id))
        .unwrap_or_default()
}

pub fn conflicts(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let inner = widgets::panel(f, area, "Conflict and diff", t);
    let all = conflict_items(m);
    let side = m.rest.side_by_side
        && f.area().width >= 120
        && m.whole(Kind::Diff)
        && m.whole(Kind::Conflicts)
        && !diff_rows(m).is_empty();
    m.rest.side_visible.set(side);
    if !side {
        // Scroll wrapped lines, so even one row taller than the body can
        // be read through to its last character at the supported floor.
        let widths = super::Widths { label: 0 };
        let lines: Vec<Line> = all
            .iter()
            .flat_map(|i| super::item_lines(i, m, t, inner.width as usize, &widths))
            .collect();
        let top = m.rest.line_scroll.get().min(lines.len().saturating_sub(1));
        m.rest.line_scroll.set(top);
        let end = lines.len().min(top + inner.height as usize);
        f.render_widget(Paragraph::new(lines[top..end].to_vec()), inner);
        for (shown, y, glyph) in [
            (top > 0, inner.y, if t.caps.unicode { "↑" } else { "^" }),
            (
                end < lines.len(),
                inner.y + inner.height.saturating_sub(1),
                if t.caps.unicode { "↓" } else { "v" },
            ),
        ] {
            if shown && inner.width > 0 && inner.height > 0 {
                widgets::line(
                    Rect::new(inner.right() - 1, y, 1, 1),
                    f,
                    Line::styled(glyph, t.style(Token::Muted)),
                );
            }
        }
        return;
    }
    // The fixed header and the side-by-side rows have separate offsets.
    let [head, body] = Layout::vertical([Constraint::Length(7), Constraint::Min(0)]).areas(inner);
    draw_items(f, head, &all[..all.len().min(6)], 0, None, m, t);
    let [left, right] =
        Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)]).areas(body);
    let rows = diff_rows(m);
    for (area, name, omitted) in [(left, "Current", "+"), (right, "From the bundle", "-")] {
        let inner = widgets::panel(f, area, name, t);
        let mut lines = Vec::new();
        // Keep one slot per unified row, so deletions and additions never
        // pretend to correspond to unrelated lines on the other side.
        let column_width = left.width.min(right.width).saturating_sub(2) as usize;
        for r in rows.iter().skip(m.rest.side_scroll) {
            let value = format!("{} {}", r.col(1), r.col(2));
            let wrapped = widgets::wrap(&t.say(&value), column_width);
            let n = wrapped.len().max(1);
            if r.col(1) == omitted {
                lines.extend((0..n).map(|_| Line::raw("")));
            } else {
                lines.extend(
                    wrapped
                        .into_iter()
                        .map(|s| Line::from(Span::styled(s, t.style(diff_token(r.col(1)))))),
                );
            }
        }
        f.render_widget(Paragraph::new(lines), inner);
    }
}
