//! The plain screens: connecting, the core's failure, help (generated from
//! the keymap), and the session's logs and diagnostics.

use crate::app::{Model, Screen};
use crate::keys::{self, Place};
use crate::theme::{Theme, Token};
use crate::widgets;
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

pub fn connecting(f: &mut Frame, area: Rect, _m: &Model, t: &Theme) {
    let lines = vec![
        Line::raw(""),
        Line::styled(
            "   Asking the core who it is and what this session may do.",
            t.style(Token::Muted),
        ),
    ];
    f.render_widget(Paragraph::new(lines), area);
}

pub fn fatal(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let lines = vec![
        widgets::heading(t, "No answer"),
        Line::raw(""),
        Line::from(vec![
            Span::raw("   "),
            Span::styled(format!("{} ", t.g.fail), t.style(Token::Danger)),
            Span::styled(m.fatal.clone(), t.style(Token::Text)),
        ]),
        Line::raw(""),
        Line::styled(
            "   r try again   q continue in the text interface",
            t.style(Token::Muted),
        ),
        Line::styled(
            "   ./omarchy-bootstrap status shows where the machine is.",
            t.style(Token::Muted),
        ),
    ];
    f.render_widget(Paragraph::new(lines), area);
}

pub fn help(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let place = match m.back {
        Screen::Gate => Place::Gate,
        Screen::Logs => Place::Logs,
        _ => Place::Dashboard,
    };
    let mut lines = vec![widgets::heading(t, "Keys"), Line::raw("")];
    for (k, d) in keys::help(place, t.caps.unicode) {
        lines.push(Line::from(vec![
            Span::styled(format!("   {k:<10}"), t.style(Token::Accent)),
            Span::styled(d, t.style(Token::Text)),
        ]));
    }
    lines.push(Line::raw(""));
    lines.push(Line::styled(
        "   The mouse is not captured: select text as usual.",
        t.style(Token::Muted),
    ));
    f.render_widget(Paragraph::new(lines), area);
}

pub fn logs(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let mut lines = vec![widgets::heading(t, "Logs and diagnostics"), Line::raw("")];
    if m.logs.is_empty() {
        lines.push(Line::styled(
            "   No diagnostics were kept in this session.",
            t.style(Token::Muted),
        ));
    }
    let room = (area.height as usize).saturating_sub(2);
    for l in m.logs.iter().skip(m.scroll).take(room) {
        lines.push(Line::styled(format!("   {l}"), t.style(Token::Text)));
    }
    f.render_widget(Paragraph::new(lines), area);
}
