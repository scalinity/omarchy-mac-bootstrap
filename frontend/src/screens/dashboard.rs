//! Screen 2, the journey dashboard, as this gate has it: the core's facts,
//! any blocker, and the actions available now (docs/UX.md → *Journey
//! dashboard*). Sparse, hairlines only, focus by reverse video.

use crate::app::Model;
use crate::theme::{Theme, Token};
use crate::widgets::{self, Tier, tier};
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

pub fn draw(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let Some(snap) = &m.snap else { return };
    let narrow = tier(area.width) == Tier::Narrow;
    let label_w = if narrow { 10 } else { 12 };
    let mut lines: Vec<Line> = Vec::new();
    lines.push(widgets::heading(t, "Foundation"));
    lines.push(Line::raw(""));
    for fact in &snap.facts {
        let (style, g) = widgets::style_of(t, &fact.state);
        lines.push(Line::from(vec![
            Span::styled(
                format!("   {:<label_w$}", fact.label),
                t.style(Token::Muted),
            ),
            Span::styled(g, style),
            Span::raw(" "),
            Span::styled(fact.value.clone(), t.style(Token::Text)),
        ]));
    }
    let prose = (area.width as usize).saturating_sub(6).max(20);
    for b in &snap.blockers {
        lines.push(Line::raw(""));
        lines.push(Line::from(vec![
            Span::raw("   "),
            Span::styled(format!("{} blocked", t.g.blocked), t.style(Token::Blocked)),
        ]));
        for l in widgets::wrap(&b.text, prose) {
            lines.push(Line::from(vec![
                Span::raw("     "),
                Span::styled(l, t.style(Token::Text)),
            ]));
        }
        for l in widgets::wrap(&b.fix, prose) {
            lines.push(Line::from(vec![
                Span::raw("     "),
                Span::styled(l, t.style(Token::Warn)),
            ]));
        }
    }
    lines.push(Line::raw(""));
    lines.push(widgets::heading(t, "Actions"));
    lines.push(Line::raw(""));
    if snap.actions.is_empty() {
        lines.push(Line::styled(
            "   Nothing is available now.",
            t.style(Token::Muted),
        ));
    }
    let name_w = snap
        .actions
        .iter()
        .map(|a| a.label.chars().count())
        .max()
        .unwrap_or(0)
        .min(34);
    for (i, a) in snap.actions.iter().enumerate() {
        let focused = i == m.focus;
        let pointer = if focused { t.g.pointer } else { " " };
        let mut badge = a.intent.clone();
        if a.handoff {
            badge.push_str(&format!(" {} handoff", t.g.dot));
        }
        if !a.gate.is_empty() && !narrow {
            badge.push_str(&format!(" {} type {}", t.g.dot, a.gate));
        }
        let name = format!("{:<name_w$}", a.label);
        let name_style = if focused {
            t.style(Token::Focus)
        } else {
            t.style(Token::Text)
        };
        lines.push(Line::from(vec![
            Span::styled(format!(" {pointer} "), t.style(Token::Accent)),
            Span::styled(name, name_style),
            Span::raw("   "),
            Span::styled(badge, t.style(Token::Muted)),
        ]));
    }
    if let Some(a) = m.focused()
        && !a.explain.is_empty()
    {
        lines.push(Line::raw(""));
        for l in widgets::wrap(&a.explain, prose) {
            lines.push(Line::styled(format!("   {l}"), t.style(Token::Muted)));
        }
    }
    f.render_widget(Paragraph::new(lines), area);
}
