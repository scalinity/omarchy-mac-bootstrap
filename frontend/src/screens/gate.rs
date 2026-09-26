//! Screen 13, the gate (docs/UX.md → *Confirmation*): what will happen, on
//! what, what it does not touch, what will ask next — then one field, and no
//! button. Enter with anything but the exact word only says so. At wide sizes
//! it is the one bordered overlay; otherwise it takes the whole body.

use crate::app::Model;
use crate::theme::{Theme, Token};
use crate::widgets::{self, Tier, tier};
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::symbols::border;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Clear, Paragraph};

const ASCII_BORDER: border::Set = border::Set {
    top_left: "+",
    top_right: "+",
    bottom_left: "+",
    bottom_right: "+",
    vertical_left: "|",
    vertical_right: "|",
    horizontal_top: "-",
    horizontal_bottom: "-",
};

pub fn draw(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let Some(a) = m.focused() else { return };
    let row = |k: &str, v: String| {
        Line::from(vec![
            Span::styled(format!("   {k:<10}"), t.style(Token::Muted)),
            Span::styled(v, t.style(Token::Text)),
        ])
    };
    let mut lines = vec![
        Line::from(vec![
            Span::styled(format!(" {}", t.g.bar), t.style(Token::Accent)),
            Span::styled(a.label.clone(), t.style(Token::Text)),
        ]),
        Line::raw(""),
        row("Does", a.explain.clone()),
        row("Touches", "the fixture's test state folder only".into()),
        row(
            "Terminal",
            if a.handoff {
                "the program owns it until it exits; this interface steps aside".into()
            } else {
                "not needed: it runs with no terminal".into()
            },
        ),
        row(
            "Next",
            if a.handoff {
                "the program asks on the terminal".into()
            } else {
                "nothing asks after this".into()
            },
        ),
        Line::raw(""),
        widgets::gate_field(t, &a.gate, &m.gate_input),
    ];
    if let Some(n) = &m.gate_note {
        lines.push(Line::raw(""));
        lines.push(Line::styled(format!("   {n}"), t.style(Token::Warn)));
    }
    if tier(area.width) == Tier::Wide {
        let w = 84u16.min(area.width.saturating_sub(4));
        let h = (lines.len() as u16 + 2).min(area.height);
        let r = Rect {
            x: area.x + (area.width - w) / 2,
            y: area.y + (area.height - h) / 2,
            width: w,
            height: h,
        };
        let set = if t.caps.unicode {
            border::PLAIN
        } else {
            ASCII_BORDER
        };
        f.render_widget(Clear, r);
        f.render_widget(
            Paragraph::new(lines).block(
                Block::bordered()
                    .border_set(set)
                    .border_style(t.style(Token::Rule)),
            ),
            r,
        );
    } else {
        f.render_widget(Clear, area);
        f.render_widget(Paragraph::new(lines), area);
    }
}
