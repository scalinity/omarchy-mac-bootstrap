//! The drawing pieces shared by the screens (docs/UX.md → *Layout*): the
//! title rule, the banner, panels, the navigation rail, the traverse, the
//! status line, the footer's hints and authority, the gate field, and the
//! too-small state. Every width is measured in terminal cells.

use crate::app::{Level, Model, NAV, Region, Screen};
use crate::keys::{self, Place};
use crate::theme::{Theme, Token};
use ratatui::Frame;
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::symbols::border;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Paragraph};

/// The smallest terminal the interface draws in.
pub const MIN_W: u16 = 60;
pub const MIN_H: u16 = 20;

/// The big banner's height, outline included.
pub const BANNER_H: u16 = 8;

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

pub fn line<'a>(area: Rect, f: &mut Frame, l: Line<'a>) {
    f.render_widget(Paragraph::new(l), area);
}

/// The width of S in terminal cells.
pub fn cells(s: &str) -> usize {
    Span::raw(s).width()
}

/// S cut at the end to ROOM cells, with an ellipsis when it does not fit
/// (names and prose; the full value stays one Enter away).
pub fn fit(s: &str, room: usize, unicode: bool) -> String {
    if cells(s) <= room {
        return s.to_string();
    }
    let mark = if unicode { "…" } else { "." };
    let mut out = String::new();
    for c in s.chars() {
        let next = format!("{out}{c}");
        if cells(&next) + 1 > room {
            break;
        }
        out = next;
    }
    if room > 0 {
        out.push_str(mark);
    }
    out
}

/// S cut at the start to ROOM cells (paths: `…/state/logs`).
pub fn fit_start(s: &str, room: usize, unicode: bool) -> String {
    if cells(s) <= room {
        return s.to_string();
    }
    let mark = if unicode { "…" } else { "." };
    let mut tail: Vec<char> = Vec::new();
    for c in s.chars().rev() {
        tail.insert(0, c);
        if cells(&tail.iter().collect::<String>()) + 1 > room {
            tail.remove(0);
            break;
        }
    }
    format!("{mark}{}", tail.into_iter().collect::<String>())
}

/// Prose wrapped at word boundaries into lines of at most WIDTH cells; a
/// word longer than a line is cut into pieces.
pub fn wrap(s: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut out = Vec::new();
    let mut cur = String::new();
    for w in s.split(' ') {
        let mut w = w.to_string();
        while cells(&w) > width {
            if !cur.is_empty() {
                out.push(std::mem::take(&mut cur));
            }
            let mut head = String::new();
            let mut rest = String::new();
            for c in w.chars() {
                if rest.is_empty() && cells(&format!("{head}{c}")) <= width {
                    head.push(c);
                } else {
                    rest.push(c);
                }
            }
            out.push(head);
            w = rest;
        }
        let n = cells(&cur);
        if n > 0 && n + 1 + cells(&w) > width {
            out.push(std::mem::take(&mut cur));
        }
        if !cur.is_empty() {
            cur.push(' ');
        }
        cur.push_str(&w);
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// Paint the page behind everything: the navy backdrop at 256 colours, the
/// terminal's own background otherwise (the style is then empty).
pub fn backdrop(f: &mut Frame, area: Rect, t: &Theme) {
    f.render_widget(Block::new().style(t.style(Token::Backdrop)), area);
}

/// A panel: a single-line outline in the frame token with its title set into
/// the top border in the heading token. Returns the area inside it.
pub fn panel(f: &mut Frame, area: Rect, title: &str, t: &Theme) -> Rect {
    let set = if t.caps.unicode {
        border::PLAIN
    } else {
        ASCII_BORDER
    };
    let block = Block::bordered()
        .border_set(set)
        .border_style(t.style(Token::Frame))
        .title(Line::from(Span::styled(
            format!(" {title} "),
            t.style(Token::Heading),
        )));
    let inner = block.inner(area);
    f.render_widget(block, area);
    inner
}

/// The title rule: the mark, the screen's name, a rule, and the frontend's
/// version.
pub fn title_rule(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let name = match m.screen {
        Screen::Help | Screen::Gate => {
            format!("{} {} {}", m.back.title(), t.g.dot, m.screen.title())
        }
        s => s.title().to_string(),
    };
    let left = format!(" {} ", t.g.mark);
    let right = format!(" v{} ", crate::core::VERSION);
    let used = cells(&left) + cells(&name) + 1 + cells(&right);
    let rule = t.g.rule.repeat((area.width as usize).saturating_sub(used));
    line(
        area,
        f,
        Line::from(vec![
            Span::styled(left, t.style(Token::Accent)),
            Span::styled(name, t.style(Token::Heading)),
            Span::raw(" "),
            Span::styled(rule, t.style(Token::Frame)),
            Span::styled(right, t.style(Token::Muted)),
        ]),
    );
}

/// The block letters of the wordmark, five rows, one cell per character.
const LETTERS: [[&str; 5]; 7] = [
    [" ███ ", "█   █", "█   █", "█   █", " ███ "],
    ["█   █", "██ ██", "█ █ █", "█   █", "█   █"],
    [" ███ ", "█   █", "█████", "█   █", "█   █"],
    ["████ ", "█   █", "████ ", "█  █ ", "█   █"],
    [" ████", "█    ", "█    ", "█    ", " ████"],
    ["█   █", "█   █", "█████", "█   █", "█   █"],
    ["█   █", " █ █ ", "  █  ", "  █  ", "  █  "],
];

/// The laptop under the mountains, in ASCII characters only.
const ART: [&str; 6] = [
    "   /\\      /\\   ",
    "  /  \\ /\\ /  \\  ",
    " /    V  V    \\ ",
    " .------------. ",
    " |            | ",
    "/______________\\",
];

/// The banner: the block wordmark with its art where the terminal has room
/// (120 by 36 and up, Unicode), one line below that, plain spaced letters in
/// ASCII.
pub fn banner(f: &mut Frame, area: Rect, t: &Theme) {
    if area.height >= BANNER_H {
        let inner = panel(f, area, "omarchy mac bootstrap", t);
        // The composition — 2 + 7 letters of 7 cells, 3, and the art's 16 —
        // centred in the panel.
        let margin = (inner.width as usize).saturating_sub(2 + 7 * 7 + 3 + 16) / 2;
        let lead = " ".repeat(margin);
        let mut lines: Vec<Line> = Vec::new();
        for row in 0..5 {
            let mut spans = vec![Span::raw(format!("{lead}  "))];
            for (i, l) in LETTERS.iter().enumerate() {
                spans.push(Span::styled(l[row], t.wordmark(i)));
                spans.push(Span::raw("  "));
            }
            spans.push(Span::raw("   "));
            spans.push(Span::styled(ART[row], t.style(Token::Frame)));
            lines.push(Line::from(spans));
        }
        let sub = "M A C   B O O T S T R A P";
        let pad = 2 + (7 * 7 - 2 - sub.len()) / 2;
        lines.push(Line::from(vec![
            Span::raw(format!("{lead}{}", " ".repeat(pad))),
            Span::styled(sub, t.style(Token::Heading)),
            Span::raw(" ".repeat(7 * 7 + 2 - pad - sub.len() + 3)),
            Span::styled(ART[5], t.style(Token::Frame)),
        ]));
        f.render_widget(Paragraph::new(lines), inner);
        return;
    }
    let word = if t.caps.unicode {
        "OMARCHY"
    } else {
        "O M A R C H Y"
    };
    line(
        area,
        f,
        Line::from(vec![
            Span::styled(format!(" {} ", t.g.mark), t.style(Token::Accent)),
            Span::styled(word, t.wordmark(0)),
            Span::styled("  mac bootstrap", t.style(Token::Muted)),
        ]),
    );
}

/// A rail entry's label: short at the standard width.
fn nav_label(s: Screen, short: bool) -> &'static str {
    match s {
        Screen::Plan if short => "Plan",
        s => s.title(),
    }
}

/// The navigation rail as a column (wide and standard widths): the current
/// screen marked, the cursor shown only while the rail has the keys.
pub fn nav_rail(f: &mut Frame, area: Rect, m: &Model, t: &Theme, short: bool) {
    let inner = panel(f, area, "Screens", t);
    let mut lines = Vec::new();
    for (i, s) in NAV.iter().enumerate() {
        let label = nav_label(*s, short);
        if m.region == Region::Nav && i == m.nav {
            lines.push(Line::from(vec![
                Span::styled(format!("{} ", t.g.pointer), t.style(Token::Accent)),
                Span::styled(label, t.style(Token::Focus)),
            ]));
        } else if *s == m.screen
            || (m.back == *s && matches!(m.screen, Screen::Help | Screen::Gate))
        {
            lines.push(Line::from(vec![
                Span::styled(format!("{} ", t.g.here), t.style(Token::Accent)),
                Span::styled(label, t.style(Token::Accent)),
            ]));
        } else {
            lines.push(Line::styled(format!("  {label}"), t.style(Token::Text)));
        }
    }
    f.render_widget(Paragraph::new(lines), inner);
}

/// The navigation as one line (narrow widths).
pub fn nav_line(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let mut spans = vec![Span::raw(" ")];
    for (i, s) in NAV.iter().enumerate() {
        let label = nav_label(*s, true);
        let (mark, style) = if m.region == Region::Nav && i == m.nav {
            (t.g.pointer, t.style(Token::Focus))
        } else if *s == m.screen
            || (m.back == *s && matches!(m.screen, Screen::Help | Screen::Gate))
        {
            (t.g.here, t.style(Token::Accent))
        } else {
            (" ", t.style(Token::Muted))
        };
        spans.push(Span::styled(mark, t.style(Token::Accent)));
        spans.push(Span::styled(label, style));
        spans.push(Span::raw(" "));
    }
    line(area, f, Line::from(spans));
}

/// The ten stations of the journey (docs/UX.md → *The rail*).
pub const STATIONS: [&str; 10] = [
    "survey", "profile", "resolve", "plan", "asahi", "omarchy", "shared", "restore", "verify",
    "done",
];

/// The traverse: a glyph per station joined by a line, each station's name
/// beneath it where the width allows (two staggered rows when it is
/// tighter), the glyphs alone below that. A station the core sent no `stage`
/// record for is drawn as later, never as to do: the frontend derives none.
pub fn traverse<'a>(m: &Model, t: &Theme, width: usize) -> Vec<Line<'a>> {
    let stages = m.snap.as_ref().map(|s| s.stages.as_slice()).unwrap_or(&[]);
    let mut current = None;
    let marks: Vec<(&'static str, Token)> = STATIONS
        .iter()
        .enumerate()
        .map(|(i, name)| {
            match stages
                .iter()
                .find(|(n, _)| n == name)
                .map(|(_, s)| s.as_str())
            {
                Some("done") => (t.g.done, Token::Ok),
                Some("current") => {
                    current = Some(i);
                    (t.g.current, Token::Accent)
                }
                Some("todo") => (t.g.todo, Token::Pending),
                Some("skipped") => (t.g.skipped, Token::Muted),
                Some("blocked") => (t.g.blocked, Token::Blocked),
                _ => (t.g.later, Token::Muted),
            }
        })
        .collect();
    let summary = match current {
        Some(i) => format!("{} {} {} of 10", STATIONS[i], t.g.dot, i + 1),
        None if stages.is_empty() => "No stage is derived yet: every station is later.".into(),
        None => format!("{} of 10 stations reported", stages.len()),
    };
    let step = if width >= 81 {
        8
    } else if width >= 60 {
        6
    } else {
        0
    };
    let mut out = Vec::new();
    if step == 0 {
        let mut spans = vec![Span::raw(" ")];
        for (g, tok) in &marks {
            spans.push(Span::styled(*g, t.style(*tok)));
            spans.push(Span::raw(" "));
        }
        out.push(Line::from(spans));
        out.push(Line::styled(format!(" {summary}"), t.style(Token::Muted)));
        return out;
    }
    let mut spans = vec![Span::raw(" ")];
    for (i, (g, tok)) in marks.iter().enumerate() {
        spans.push(Span::styled(*g, t.style(*tok)));
        if i + 1 < marks.len() {
            spans.push(Span::styled(
                t.g.rule.repeat(step - 1),
                t.style(Token::Rule),
            ));
        }
    }
    out.push(Line::from(spans));
    let rows: Vec<Vec<usize>> = if step == 8 {
        vec![(0..10).collect()]
    } else {
        vec![(0..10).step_by(2).collect(), (1..10).step_by(2).collect()]
    };
    for row in rows {
        let mut s = String::from(" ");
        for i in row {
            let at = 1 + i * step;
            while cells(&s) < at {
                s.push(' ');
            }
            s.push_str(STATIONS[i]);
        }
        out.push(Line::styled(s, t.style(Token::Muted)));
    }
    out.push(Line::styled(format!(" {summary}"), t.style(Token::Muted)));
    out
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

/// The status line: a request in flight — its words at once, a spinner only
/// after 150 ms, elapsed time after 2 s, counts when the core reports them —
/// or the last thing worth saying. Nothing moves while idle.
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
        let s = fit(&t.say(s), room, t.caps.unicode);
        used += 2 + cells(&s);
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

/// What the session can do, in the core's terms: *read-only* and *no system
/// changes* only when `hello` shows a read ceiling and the snapshot lists no
/// action; otherwise the ceiling in words (docs/UX.md → *Layout*).
pub fn authority(m: &Model, t: &Theme, short: bool) -> String {
    let Some(h) = &m.hello else {
        return String::new();
    };
    let dot = format!(" {} ", t.g.dot);
    let actions = m.snap.as_ref().map(|s| s.actions.len());
    let mut out = match actions {
        Some(0) if h.ceiling == "read" => {
            if short {
                "read-only".to_string()
            } else {
                format!("read-only{dot}no system changes")
            }
        }
        Some(n) if n > 0 && !short => format!(
            "may {}{dot}{n} action{}",
            h.ceiling,
            if n == 1 { "" } else { "s" }
        ),
        _ => format!("may {}", h.ceiling),
    };
    if h.fixture {
        out.push_str(&format!("{dot}fixture"));
    }
    if h.dry_run {
        out.push_str(&format!("{dot}dry run"));
    }
    out
}

/// The footer: hints generated from the keymap — as many as fit beside the
/// authority, help always kept — then the authority.
pub fn footer(f: &mut Frame, area: Rect, m: &Model, place: Place, t: &Theme) {
    let narrow = tier(area.width) == Tier::Narrow;
    let auth = authority(m, t, narrow);
    let width = area.width as usize;
    let render = |hs: &[(&str, &str)]| -> usize {
        1 + hs
            .iter()
            .map(|(k, d)| cells(k) + 1 + cells(d))
            .sum::<usize>()
            + 2 * hs.len().saturating_sub(1)
    };
    let mut max = if narrow { 4 } else { 6 };
    let mut hs = keys::hints(place, t.caps.unicode, max);
    while max > 1 && render(&hs) + cells(&auth) + 3 > width {
        max -= 1;
        hs = keys::hints(place, t.caps.unicode, max);
    }
    let mut spans = vec![Span::raw(" ")];
    for (i, (k, d)) in hs.iter().enumerate() {
        if i > 0 {
            spans.push(Span::raw("  "));
        }
        spans.push(Span::styled(*k, t.style(Token::Accent)));
        spans.push(Span::raw(" "));
        spans.push(Span::styled(*d, t.style(Token::Muted)));
    }
    let used = render(&hs);
    let room = width.saturating_sub(used + 2);
    let auth = fit(&auth, room, t.caps.unicode);
    spans.push(Span::raw(
        " ".repeat(width.saturating_sub(used + cells(&auth) + 1)),
    ));
    spans.push(Span::styled(auth, t.style(Token::Info)));
    line(area, f, Line::from(spans));
}

/// A label and its value, the value wrapped under itself when it is long.
pub fn pair<'a>(
    t: &Theme,
    label: &str,
    value: &str,
    w: usize,
    width: usize,
    value_style: Style,
) -> Vec<Line<'a>> {
    let room = width.saturating_sub(w + 5).max(8);
    let mut out = Vec::new();
    for (i, l) in wrap(value, room).into_iter().enumerate() {
        let lab = if i == 0 {
            format!("   {}", fit(label, w, t.caps.unicode))
        } else {
            "   ".to_string()
        };
        let pad = (w + 5).saturating_sub(cells(&lab));
        out.push(Line::from(vec![
            Span::styled(lab, t.style(Token::Muted)),
            Span::raw(" ".repeat(pad)),
            Span::styled(l, value_style),
        ]));
    }
    if out.is_empty() {
        out.push(Line::styled(
            format!("   {}", fit(label, w, t.caps.unicode)),
            t.style(Token::Muted),
        ));
    }
    out
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
    let x = (area.width as usize).saturating_sub(cells(&msg)) / 2;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn widths_are_cells() {
        assert_eq!(fit("abcdef", 4, true), "abc…");
        assert_eq!(fit("abcdef", 4, false), "abc.");
        assert_eq!(fit("abc", 4, true), "abc");
        assert_eq!(fit_start("/a/b/c/logs", 7, true), "…c/logs");
        // A wide character counts as two cells.
        assert_eq!(cells("日本"), 4);
        assert!(cells(&fit("日本語のログ", 5, true)) <= 5);
        assert_eq!(wrap("aaaa bbbb", 4), vec!["aaaa", "bbbb"]);
        assert_eq!(wrap("abcdefghij", 4), vec!["abcd", "efgh", "ij"]);
    }
}
