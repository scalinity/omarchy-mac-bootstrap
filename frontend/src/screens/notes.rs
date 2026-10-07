//! The plain screens: connecting, the core's failure, and help (generated
//! from the keymap).

use crate::app::Model;
use crate::keys;
use crate::theme::{Theme, Token};
use crate::widgets;
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

pub fn connecting(f: &mut Frame, area: Rect, t: &Theme) {
    let inner = widgets::panel(f, area, "Connecting", t);
    let lines = vec![
        Line::raw(""),
        Line::styled(
            "   Asking the core who it is and what this session may do.",
            t.style(Token::Muted),
        ),
    ];
    f.render_widget(Paragraph::new(lines), inner);
}

pub fn fatal(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let inner = widgets::panel(f, area, "No answer", t);
    let width = (inner.width as usize).saturating_sub(6).max(12);
    let mut lines = vec![Line::raw("")];
    for (i, l) in widgets::wrap(&t.say(&m.fatal), width)
        .into_iter()
        .enumerate()
    {
        let g = if i == 0 { t.g.fail } else { " " };
        lines.push(Line::from(vec![
            Span::styled(format!("   {g} "), t.style(Token::Danger)),
            Span::styled(l, t.style(Token::Text)),
        ]));
    }
    lines.push(Line::raw(""));
    lines.push(Line::styled(
        "   r try again   q continue in the text interface",
        t.style(Token::Muted),
    ));
    lines.push(Line::styled(
        "   ./omarchy-bootstrap status shows where the machine is.",
        t.style(Token::Muted),
    ));
    f.render_widget(Paragraph::new(lines), inner);
}

pub fn help(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let inner = widgets::panel(f, area, "Keys", t);
    let mut lines = Vec::new();
    for (k, d) in keys::help_for(
        m.back,
        m.region,
        m.logs_tab,
        crate::app::value_open(m, m.back),
        t.caps.unicode,
    )
    .into_iter()
    .skip(m.help_scroll)
    {
        lines.push(Line::from(vec![
            Span::styled(format!("   {k:<12}"), t.style(Token::Accent)),
            Span::styled(d, t.style(Token::Text)),
        ]));
    }
    lines.push(Line::raw(""));
    lines.push(Line::styled(
        "   The mouse is not captured: select text as usual.",
        t.style(Token::Muted),
    ));
    // The mouse line stays on the screen however far the list scrolls.
    let room = inner.height as usize;
    if lines.len() > room && room >= 2 {
        let tail: Vec<Line> = lines.split_off(lines.len() - 2);
        lines.truncate(room - 2);
        lines.extend(tail);
    }
    f.render_widget(Paragraph::new(lines), inner);
}
