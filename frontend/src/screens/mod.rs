//! The screens (docs/UX.md → *Screens*): one module per family. Rendering
//! reads the model and nothing else.

mod dashboard;
mod gate;
mod notes;

use crate::app::{Model, Screen};
use crate::keys::Place;
use crate::theme::Theme;
use crate::widgets::{self, MIN_H, MIN_W, Tier, tier};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};

/// The bands of the frame (docs/UX.md → *Layout*): header, rail, a rule, the
/// body (whose last row carries the status line when there is something to
/// say), a rule, the hints. At heights 20 to 23 the header merges into the
/// rail line. At 120 columns and more the rail becomes a column.
pub struct Bands {
    pub header: Option<Rect>,
    pub rail: Rect,
    pub body: Rect,
    pub status: Option<Rect>,
    pub hints: Rect,
    pub rules: [Rect; 2],
}

pub fn bands(area: Rect, with_status: bool) -> Bands {
    let merged = area.height < 24;
    let head = if merged { 0 } else { 1 };
    let [h, rail, r1, body, r2, hints] = Layout::vertical([
        Constraint::Length(head),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(1),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(area);
    let (body, status) = if with_status && body.height > 1 {
        let [b, s] = Layout::vertical([Constraint::Min(1), Constraint::Length(1)]).areas(body);
        (b, Some(s))
    } else {
        (body, None)
    };
    Bands {
        header: (!merged).then_some(h),
        rail,
        body,
        status,
        hints,
        rules: [r1, r2],
    }
}

/// Draw the whole frame for the model.
pub fn draw(f: &mut Frame, m: &Model, t: &Theme, tick_ms: u32) {
    let area = f.area();
    if area.width < MIN_W || area.height < MIN_H {
        widgets::too_small(f, area, t);
        return;
    }
    let with_status = m.pending.is_some() || m.status.is_some();
    let b = bands(area, with_status);
    if let Some(h) = b.header {
        widgets::header(f, h, m, t);
    }
    if b.header.is_none() {
        // Merged: the mark leads the rail line.
        let [mark, rest] =
            Layout::horizontal([Constraint::Length(4), Constraint::Min(1)]).areas(b.rail);
        widgets::line(
            mark,
            f,
            ratatui::text::Line::styled(
                format!(" {} ", t.g.mark),
                t.style(crate::theme::Token::Accent),
            ),
        );
        widgets::rail(f, rest, m, t);
    } else {
        widgets::rail(f, b.rail, m, t);
    }
    widgets::rule(f, b.rules[0], t);
    widgets::rule(f, b.rules[1], t);
    let place = match m.screen {
        Screen::Gate => Place::Gate,
        Screen::Logs => Place::Logs,
        _ => Place::Dashboard,
    };
    widgets::hints(f, b.hints, place, t);
    if let Some(s) = b.status {
        widgets::status(f, s, m, t, tick_ms);
    }
    match m.screen {
        Screen::Connecting => notes::connecting(f, b.body, m, t),
        Screen::Dashboard => dashboard::draw(f, b.body, m, t),
        Screen::Gate => {
            if tier(area.width) == Tier::Wide {
                dashboard::draw(f, b.body, m, t);
            }
            gate::draw(f, b.body, m, t);
        }
        Screen::Logs => notes::logs(f, b.body, m, t),
        Screen::Help => notes::help(f, b.body, m, t),
        Screen::Fatal => notes::fatal(f, b.body, m, t),
    }
}
