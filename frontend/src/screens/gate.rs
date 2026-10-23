//! Screen 13, the gate (docs/UX.md → *Confirmation*): what will happen, on
//! what, what it does not touch, what will ask next — each in the core's own
//! words, its `gate.<action>.*` facts — then one field, and no button. Enter
//! with anything but the exact word only says so. At wide sizes it is the one
//! bordered overlay; otherwise it takes the whole body.

use crate::app::Model;
use crate::read::Kind;
use crate::theme::{Theme, Token};
use crate::widgets::{self, Tier, cells, fit, tier, wrap};
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
    let Some(g) = &m.gate else { return };
    let a = &g.action;
    let wide = tier(area.width) == Tier::Wide;
    let width = if wide {
        84usize.min(area.width as usize).saturating_sub(6)
    } else {
        area.width as usize
    };
    let facts = m
        .snap_of(g.scope)
        .map(|s| s.gate_facts(&a.id))
        .unwrap_or_default();
    let lw = facts
        .iter()
        .map(|f| cells(&f.label))
        .chain([8])
        .max()
        .unwrap_or(8)
        .min(16);
    let row = |k: &str, v: &str, style, glyph: &str| {
        let room = width.saturating_sub(lw + 8).max(8);
        let mut out = Vec::new();
        for (i, l) in wrap(&t.say(v), room).into_iter().enumerate() {
            let (k, g) = if i == 0 {
                (fit(&t.say(k), lw, t.caps.unicode), glyph)
            } else {
                (String::new(), " ")
            };
            out.push(Line::from(vec![
                Span::styled(format!("   {k:<lw$}  "), t.style(Token::Muted)),
                Span::styled(format!("{g} "), style),
                Span::styled(l, t.style(Token::Text)),
            ]));
        }
        out
    };
    // What stays: the action's label and what it does, the field and its
    // note. Between them, what the gate says scrolls (↑↓ PgUp PgDn).
    let mut head = vec![
        Line::from(vec![
            Span::styled(format!(" {}", t.g.bar), t.style(Token::Accent)),
            Span::styled(t.say(&a.label), t.style(Token::Text)),
        ]),
        Line::raw(""),
    ];
    if !a.explain.is_empty() {
        head.extend(row("Does", &a.explain, t.style(Token::Info), " "));
    }
    let mut body = Vec::new();
    for fact in &facts {
        let (style, glyph) = widgets::style_of(t, &fact.state);
        let glyph = if matches!(fact.state.as_str(), "info" | "") {
            " "
        } else {
            glyph
        };
        body.extend(row(&fact.label, &fact.value, style, glyph));
    }
    body.extend(row(
        "Terminal",
        if a.handoff {
            "the program owns it until it exits; this interface steps aside"
        } else {
            "not needed: it runs with no terminal"
        },
        t.style(Token::Info),
        " ",
    ));
    // What a typed opaque covers, as the core listed it, read whole.
    if let Some(d) = m.detail(Kind::Opaque).filter(|_| a.id == "profile.opaque") {
        body.push(Line::raw(""));
        body.push(Line::styled(
            if m.whole(Kind::Opaque) {
                format!(
                    "   It covers {} path{}:",
                    d.total,
                    if d.total == 1 { "" } else { "s" }
                )
            } else if d.loaded {
                format!(
                    "   Reading what this covers: {} of {} paths.",
                    d.rows.len(),
                    d.total
                )
            } else {
                "   Reading what this covers.".to_string()
            },
            t.style(Token::Muted),
        ));
        for r in &d.rows {
            let size = r.col(1).parse::<u64>().ok().map(widgets::gb);
            body.push(Line::styled(
                format!(
                    "   {}  {}",
                    fit(&t.say(r.col(0)), width.saturating_sub(16), t.caps.unicode),
                    size.unwrap_or_default()
                ),
                t.style(Token::Text),
            ));
        }
        if let Some(fault) = &d.fault {
            body.extend(super::table::fault_lines(fault, t, width));
        }
    }
    let mut tail = vec![
        Line::raw(""),
        widgets::gate_field(t, &a.gate, &m.gate_input),
    ];
    if let Some(n) = &m.gate_note {
        tail.push(Line::raw(""));
        tail.push(Line::styled(format!("   {n}"), t.style(Token::Warn)));
    }
    let room = if wide {
        (area.height as usize).saturating_sub(2)
    } else {
        area.height as usize
    };
    let mid = room.saturating_sub(head.len() + tail.len());
    let said = body.len();
    if said > mid {
        // A window of what it says, kept within it, with a mark where more is.
        let top = m.gate_scroll.get().min(said - mid);
        m.gate_scroll.set(top);
        let mut shown: Vec<Line> = body.into_iter().skip(top).take(mid).collect();
        let more = |s: &str| Line::styled(format!("   {s}"), t.style(Token::Muted));
        if top > 0 && !shown.is_empty() {
            shown[0] = more(if t.caps.unicode {
                "↑ more above"
            } else {
                "^ more above"
            });
        }
        if top + mid < said && shown.len() > 1 {
            let last = shown.len() - 1;
            shown[last] = more(if t.caps.unicode {
                "↓ more below: ↑↓ PgUp PgDn"
            } else {
                "v more below: up/down PgUp PgDn"
            });
        }
        body = shown;
    }
    let mut lines = head;
    lines.extend(body);
    lines.extend(tail);
    if wide {
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
        widgets::backdrop(f, r, t);
        f.render_widget(
            Paragraph::new(lines).block(
                Block::bordered()
                    .border_set(set)
                    .border_style(t.style(Token::Frame)),
            ),
            r,
        );
    } else {
        f.render_widget(Clear, area);
        widgets::backdrop(f, area, t);
        f.render_widget(Paragraph::new(lines), area);
    }
}
