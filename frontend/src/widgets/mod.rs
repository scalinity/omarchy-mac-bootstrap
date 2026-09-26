//! Small drawing pieces shared by the screens: the hairline rule, the header,
//! the traverse rail, the footer's status line and hints, the gate field, and
//! the too-small state (docs/UX.md → *Layout*).

use crate::app::{Level, Model};
use crate::keys::{self, Place};
use crate::theme::{Theme, Token};
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

/// The smallest terminal the interface draws in.
pub const MIN_W: u16 = 60;
pub const MIN_H: u16 = 20;

/// Width tiers (docs/UX.md → *Layout*).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tier {
    Wide,
    Standard,
    Narrow,
}

pub fn tier(w: u16) -> Tier {
    if w >= 120 {
        Tier::Wide
    } else if w >= 80 {
        Tier::Standard
    } else {
        Tier::Narrow
    }
}

pub fn line<'a>(area: Rect, f: &mut Frame, l: Line<'a>) {
    f.render_widget(Paragraph::new(l), area);
}

/// One thin rule across the area: the only separator (no boxes).
pub fn rule(f: &mut Frame, area: Rect, t: &Theme) {
    let s = t.g.rule.repeat(area.width as usize);
    line(area, f, Line::from(Span::styled(s, t.style(Token::Rule))));
}

/// The header: the mark and the name, and where this is.
pub fn header(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let left = format!(" {} omarchy mac bootstrap", t.g.mark);
    let right = match &m.hello {
        Some(h) => {
            let place = if h.platform == "macos" {
                "macOS"
            } else {
                "Linux"
            };
            let mut r = format!("{place} {} {}", t.g.dot, h.user);
            if h.fixture {
                r.push_str(&format!(" {} fixture", t.g.dot));
            }
            if h.dry_run {
                r.push_str(&format!(" {} dry run", t.g.dot));
            }
            r.push(' ');
            r
        }
        None => String::new(),
    };
    let pad = (area.width as usize).saturating_sub(left.chars().count() + right.chars().count());
    line(
        area,
        f,
        Line::from(vec![
            Span::styled(format!(" {}", t.g.mark), t.style(Token::Accent)),
            Span::styled(" omarchy mac bootstrap", t.style(Token::Text)),
            Span::raw(" ".repeat(pad)),
            Span::styled(right, t.style(Token::Muted)),
        ]),
    );
}

/// The ten stations of the journey (docs/UX.md → *The rail*).
pub const STATIONS: [&str; 10] = [
    "survey", "profile", "resolve", "plan", "asahi", "omarchy", "shared", "restore", "verify",
    "done",
];

/// The rail, one line. With no stage records from the core (this build does
/// not derive the journey yet), it says so instead of drawing stations it
/// cannot vouch for.
pub fn rail(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let stages = m.snap.as_ref().map(|s| s.stages.as_slice()).unwrap_or(&[]);
    if stages.is_empty() {
        line(
            area,
            f,
            Line::from(vec![
                Span::styled(" journey ", t.style(Token::Muted)),
                Span::styled("not derived in this build", t.style(Token::Pending)),
            ]),
        );
        return;
    }
    let mut spans = vec![Span::raw(" ")];
    let mut current = None;
    for (i, name) in STATIONS.iter().enumerate() {
        let state = stages
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, s)| s.as_str())
            .unwrap_or("todo");
        let (g, tok) = match state {
            "done" => (t.g.done, Token::Ok),
            "current" => {
                current = Some(i);
                (t.g.current, Token::Accent)
            }
            "skipped" => (t.g.skipped, Token::Muted),
            "blocked" => (t.g.blocked, Token::Blocked),
            _ => (t.g.todo, Token::Pending),
        };
        spans.push(Span::styled(g, t.style(tok)));
        spans.push(Span::raw(" "));
    }
    if let Some(i) = current {
        spans.push(Span::styled(
            format!("  {} {} {} of 10", STATIONS[i], t.g.dot, i + 1),
            t.style(Token::Muted),
        ));
    }
    line(area, f, Line::from(spans));
}

pub fn level_token(l: Level) -> Token {
    match l {
        Level::Ok => Token::Ok,
        Level::Info => Token::Info,
        Level::Warn => Token::Warn,
        Level::Fail => Token::Danger,
    }
}

pub fn level_glyph(l: Level, t: &Theme) -> &'static str {
    match l {
        Level::Ok => t.g.ok,
        Level::Info => t.g.info,
        Level::Warn => t.g.warn,
        Level::Fail => t.g.fail,
    }
}

/// The status line: a request in flight (a spinner only after 150 ms,
/// elapsed time after 2 s, counts when the core reports them), or the last
/// thing worth saying. Nothing moves while idle.
pub fn status(f: &mut Frame, area: Rect, m: &Model, t: &Theme, tick_ms: u32) {
    // What is running, at the right; the last thing worth saying, at the
    // left — a warning is never hidden by the fresh read it asked for.
    let mut right: Vec<Span> = Vec::new();
    if let Some(p) = &m.pending {
        let ms = p.ticks.saturating_mul(tick_ms);
        if ms >= 150 {
            let g = t.g.spin[(p.ticks as usize) % t.g.spin.len()];
            right.push(Span::styled(g, t.style(Token::Accent)));
            right.push(Span::raw(" "));
        }
        right.push(Span::styled(p.label.clone(), t.style(Token::Muted)));
        if let Some((_, done, total)) = &m.progress
            && *total > 0
        {
            right.push(Span::styled(
                format!("  {done} of {total}"),
                t.style(Token::Muted),
            ));
        }
        if ms >= 2000 {
            right.push(Span::styled(
                format!("  {}s", ms / 1000),
                t.style(Token::Muted),
            ));
        }
        right.push(Span::raw(" "));
    }
    let rw: usize = right.iter().map(|s| s.width()).sum();
    let mut spans = vec![Span::raw(" ")];
    let mut used = 1;
    if let Some((l, s)) = &m.status {
        let room = (area.width as usize).saturating_sub(rw + 4 + 2);
        let s = clip(s, room, t.caps.unicode);
        used += 2 + s.chars().count();
        spans.push(Span::styled(level_glyph(*l, t), t.style(level_token(*l))));
        spans.push(Span::raw(" "));
        spans.push(Span::styled(s, t.style(Token::Text)));
    }
    if !right.is_empty() {
        spans.push(Span::raw(
            " ".repeat((area.width as usize).saturating_sub(used + rw)),
        ));
        spans.extend(right);
    }
    line(area, f, Line::from(spans));
}

/// Prose cut at the end with an ellipsis when it cannot fit (the full value
/// stays one Enter away).
pub fn clip(s: &str, room: usize, unicode: bool) -> String {
    if s.chars().count() <= room {
        return s.to_string();
    }
    let mut out: String = s.chars().take(room.saturating_sub(1)).collect();
    out.push_str(if unicode { "…" } else { "." });
    out
}

/// Prose wrapped at word boundaries into lines of at most WIDTH characters.
pub fn wrap(s: &str, width: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for w in s.split(' ') {
        let n = cur.chars().count();
        if n > 0 && n + 1 + w.chars().count() > width {
            out.push(std::mem::take(&mut cur));
        }
        if !cur.is_empty() {
            cur.push(' ');
        }
        cur.push_str(w);
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// The key hints, generated from the keymap: three plus help when narrow.
pub fn hints(f: &mut Frame, area: Rect, place: Place, t: &Theme) {
    let max = if tier(area.width) == Tier::Narrow {
        4
    } else {
        6
    };
    let mut spans = vec![Span::raw(" ")];
    for (i, (k, d)) in keys::hints(place, t.caps.unicode, max)
        .into_iter()
        .enumerate()
    {
        if i > 0 {
            spans.push(Span::raw("   "));
        }
        spans.push(Span::styled(k, t.style(Token::Accent)));
        spans.push(Span::raw(" "));
        spans.push(Span::styled(d, t.style(Token::Muted)));
    }
    line(area, f, Line::from(spans));
}

/// A section heading: the bar and the title.
pub fn heading<'a>(t: &Theme, title: &'a str) -> Line<'a> {
    Line::from(vec![
        Span::styled(format!(" {}", t.g.bar), t.style(Token::Accent)),
        Span::styled(title, t.style(Token::Text)),
    ])
}

/// The truthful stop below the minimum: the size needed and the size now.
pub fn too_small(f: &mut Frame, area: Rect, t: &Theme) {
    let msg = format!(
        "terminal too small {} needs {MIN_W}x{MIN_H}, this is {}x{}",
        if t.caps.unicode { "—" } else { "-" },
        area.width,
        area.height
    );
    let y = area.height / 2;
    let x = (area.width as usize).saturating_sub(msg.chars().count()) / 2;
    let row = Rect {
        x: area.x,
        y: area.y + y,
        width: area.width,
        height: 1,
    };
    line(
        row,
        f,
        Line::from(vec![
            Span::raw(" ".repeat(x)),
            Span::styled(msg, t.style(Token::Warn)),
        ]),
    );
}

/// The typed-word field: the word typed so far, underlined, and a cursor bar.
pub fn gate_field<'a>(t: &Theme, word: &str, typed: &'a str) -> Line<'a> {
    let cursor = if t.caps.unicode { "▏" } else { "_" };
    Line::from(vec![
        Span::styled(
            format!("   Type {word} to continue    "),
            t.style(Token::Text),
        ),
        Span::styled(typed, t.style(Token::Gate)),
        Span::styled(cursor, t.style(Token::Gate)),
    ])
}

pub fn style_of(t: &Theme, state: &str) -> (Style, &'static str) {
    match state {
        "ok" => (t.style(Token::Ok), t.g.ok),
        "warn" => (t.style(Token::Warn), t.g.warn),
        "fail" => (t.style(Token::Danger), t.g.fail),
        "unknown" => (t.style(Token::Muted), "?"),
        _ => (t.style(Token::Info), t.g.info),
    }
}
