//! The detail screens over the read surface (docs/PROTOCOL.md → *The Gate 2
//! read surface*): the journey's machine and status details, Health (the
//! doctor's counts and findings) and Logs (the tool's selected log window,
//! and the core's diagnostics kept in this session). Each shows one page,
//! from the generation it was opened from, and says which; every state keeps
//! its own words — loading, empty, partial, error, changed, no answer.

use crate::app::{LogsTab, Model, Region, Req, Screen};
use crate::read::{Detail, Fault, Kind, Row, Scope};
use crate::theme::{Theme, Token};
use crate::widgets::{self, Tier, cells, fit, fit_start, wrap};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

/// The fewest lines an open value is read in under its row; given fewer, it
/// takes the panel (see `draw`).
const VALUE_ROOM: usize = 3;

/// The lines a fault is shown as: the core's own words for a refusal or an
/// error, and "no answer" kept apart from both.
pub fn fault_lines<'a>(f: &Fault, t: &Theme, width: usize) -> Vec<Line<'a>> {
    let room = width.saturating_sub(6).max(12);
    let mut out = Vec::new();
    let dot = t.g.dot;
    let (head, tok, body, next): (String, Token, String, String) = match f {
        Fault::Said { status, code, text } if status == "refused" => (
            format!("{} refused {} {code}", t.g.warn, t.g.dot),
            Token::Warn,
            text.clone(),
            "r asks again".to_string(),
        ),
        Fault::Said { status, code, text } => (
            format!("{} {status} {} {code}", t.g.fail, t.g.dot),
            Token::Danger,
            text.clone(),
            format!("r tries again {dot} L shows the log"),
        ),
        Fault::NoAnswer(why) => (
            format!("{} no answer", t.g.fail),
            Token::Danger,
            format!("The core stopped without answering ({why})."),
            format!("L, then Tab, shows its diagnostics {dot} r asks again"),
        ),
        Fault::NotSent(why) => (
            format!("{} not sent", t.g.fail),
            Token::Danger,
            format!("The request was not delivered ({why}); nothing ran."),
            "r tries again".to_string(),
        ),
    };
    out.push(Line::styled(format!(" {head}"), t.style(tok)));
    for l in wrap(&t.say(&body), room) {
        out.push(Line::styled(format!("   {l}"), t.style(Token::Text)));
    }
    out.push(Line::styled(format!("   {next}"), t.style(Token::Muted)));
    out
}

fn is_reading(m: &Model, kind: Kind) -> bool {
    m.reading(|r| match r {
        Req::Detail(p) => p.kind == kind,
        Req::Read(s) => *s == kind.scope(),
        Req::Snapshot => kind.scope() == Scope::Journey,
        _ => false,
    })
}

pub fn draw(f: &mut Frame, area: Rect, m: &Model, t: &Theme, tier: Tier) {
    let Some(kind) = m.screen.kind() else { return };
    let reading =
        is_reading(m, kind) && !(m.screen == Screen::Logs && m.logs_tab == LogsTab::Diagnostics);
    let title = if reading {
        format!("{} {} reading", m.screen.title(), t.g.dot)
    } else {
        m.screen.title().to_string()
    };
    let inner = widgets::panel(f, area, &title, t);
    let width = inner.width as usize;
    let mut head: Vec<Line> = Vec::new();
    // What the head must still say while an open value takes the panel:
    // which read is shown and what failed, each fault by its first line.
    let mut notes: Vec<Line> = Vec::new();
    if m.screen == Screen::Logs {
        head.push(tabs(m, t));
        if m.logs_tab == LogsTab::Diagnostics {
            return diagnostics(f, inner, head, m, t);
        }
    }
    if m.check {
        for l in wrap(
            "The startup check answers hello and the journey snapshot only, so this view reads nothing in this session.",
            width.saturating_sub(4),
        ) {
            head.push(Line::styled(format!("   {l}"), t.style(Token::Muted)));
        }
        f.render_widget(Paragraph::new(head), inner);
        return;
    }
    let scope = kind.scope();
    let d = m.detail(kind);
    // The newest snapshot's generation, when the rows shown are an earlier
    // read's: never admitted, its rows are not those shown.
    let newest = d
        .filter(|d| d.loaded)
        .and_then(|d| m.generation(scope).filter(|g| *g != d.generation));
    // The facts drawn above the rows are those of the snapshot the rows came
    // from: a newer snapshot's counts or source never head an older read's.
    let facts = if scope == Scope::Journey {
        None
    } else {
        let r = m.scope(scope);
        match d.filter(|d| d.loaded) {
            Some(d) => [&r.snap, &r.held]
                .into_iter()
                .flatten()
                .find(|s| s.generation == d.generation),
            None => r.snap.as_ref(),
        }
    };
    if scope != Scope::Journey {
        if let Some(s) = facts {
            head.extend(scope_head(scope, s, t, width));
        }
        if let Some(fault) = &m.scope(scope).fault {
            let lines = fault_lines(fault, t, width);
            notes.extend(lines.first().cloned());
            head.extend(lines);
        }
    }
    match d {
        None if reading => head.push(Line::styled(
            "   Reading the core's answer.",
            t.style(Token::Muted),
        )),
        None if scope != Scope::Journey && m.scope(scope).fault.is_some() => {}
        None if m.pending.is_some() => head.push(Line::styled(
            "   This opens once the running request ends.",
            t.style(Token::Muted),
        )),
        None => head.push(Line::styled(
            "   Not read yet: r reads it.",
            t.style(Token::Muted),
        )),
        Some(d) => {
            if let Some(g) = newest {
                let short = |g: &str| g.get(..12).unwrap_or(g).to_string();
                let shown = format!(
                    "{} shown: an earlier read, generation {}; the newest read is {}{}",
                    t.g.warn,
                    short(&d.generation),
                    short(g),
                    if reading {
                        ", reading now"
                    } else {
                        ", not shown"
                    }
                );
                for (i, l) in wrap(&shown, width.saturating_sub(4)).iter().enumerate() {
                    let pad = if i == 0 { " " } else { "   " };
                    let line = Line::styled(format!("{pad}{l}"), t.style(Token::Warn));
                    notes.push(line.clone());
                    head.push(line);
                }
            }
            if d.changed && !reading {
                let line = Line::styled(
                    format!(
                        " {} changed since you looked {} r",
                        t.g.warn,
                        if t.caps.unicode { "—" } else { "-" }
                    ),
                    t.style(Token::Warn),
                );
                notes.push(line.clone());
                head.push(line);
            }
            if let Some(fault) = &d.fault {
                let lines = if kind == Kind::Operation {
                    operation_fault_lines(fault, t, width)
                } else {
                    fault_lines(fault, t, width)
                };
                notes.extend(lines.first().cloned());
                head.extend(lines);
            }
            if !d.loaded && reading {
                head.push(Line::styled(
                    "   Reading the core's answer.",
                    t.style(Token::Muted),
                ));
            }
            if d.loaded && d.total == 0 {
                let empty = match kind {
                    Kind::Machine => "The journey's read holds no machine rows.",
                    Kind::Status => "The journey's read holds no status lines.",
                    Kind::Doctor => "The doctor reported no findings.",
                    Kind::Operation => "No operation finding was supplied.",
                    Kind::Log => {
                        let said = facts.is_some_and(|s| !s.messages.is_empty());
                        if said {
                            ""
                        } else {
                            "The selected log has no lines."
                        }
                    }
                };
                if !empty.is_empty() {
                    head.push(Line::styled(format!("   {empty}"), t.style(Token::Muted)));
                }
            }
        }
    }
    let footed = d.filter(|d| d.loaded && d.total > 0);
    let edit = d.filter(|d| d.editing).map(|d| {
        Line::from(vec![
            Span::styled(" / ", t.style(Token::Accent)),
            Span::styled(d.filter.clone(), t.style(Token::Gate)),
            Span::styled(if t.caps.unicode { "▏" } else { "_" }, t.style(Token::Gate)),
        ])
    });
    let tail_h = u16::from(footed.is_some()) + u16::from(edit.is_some());
    // An open value the head would leave fewer than VALUE_ROOM lines under
    // its row takes the panel: only the notes stay above it, and closing it
    // brings back the rest — the scope's facts and each fault's words.
    let room = (inner.height as usize).saturating_sub(head.len() + usize::from(tail_h) + 1);
    if d.is_some_and(|d| d.loaded && d.open) && room < VALUE_ROOM {
        head = notes;
    }
    let head_h = (head.len() as u16).min(inner.height);
    let [h, body, tail] = Layout::vertical([
        Constraint::Length(head_h),
        Constraint::Min(0),
        Constraint::Length(tail_h),
    ])
    .areas(inner);
    f.render_widget(Paragraph::new(head), h);
    let held = newest.is_some();
    let seen = d
        .filter(|d| d.loaded)
        .and_then(|d| rows(f, body, d, held, m, t, tier));
    let mut tl = Vec::new();
    tl.extend(footed.map(|d| foot(d, seen, t)));
    tl.extend(edit);
    f.render_widget(Paragraph::new(tl), tail);
}

/// D55 refusals and failures never stand in for an operation finding. Keep
/// the core's status, code and text without generic log or recovery hints.
fn operation_fault_lines<'a>(fault: &Fault, t: &Theme, width: usize) -> Vec<Line<'a>> {
    if let Fault::NoAnswer(why) = fault {
        let mut lines = vec![Line::styled(
            format!(" {} no complete answer", t.g.fail),
            t.style(Token::Danger),
        )];
        lines.extend(
            wrap(&t.say(why), width.saturating_sub(4))
                .into_iter()
                .map(|l| Line::styled(format!("   {l}"), t.style(Token::Text))),
        );
        lines.push(Line::styled(
            "   No current operation finding.",
            t.style(Token::Muted),
        ));
        return lines;
    }
    let mut lines = fault_lines(fault, t, width);
    lines.pop();
    let unavailable = matches!(fault, Fault::Said { status, code, .. }
        if status == "refused" && code == "unavailable");
    let text = if unavailable {
        "This operation detail is not available from this core."
    } else {
        "No current operation finding."
    };
    lines.extend(
        wrap(text, width.saturating_sub(4))
            .into_iter()
            .map(|l| Line::styled(format!("   {l}"), t.style(Token::Muted))),
    );
    lines
}

/// The Logs screen's two sources, the current one marked.
fn tabs<'a>(m: &Model, t: &Theme) -> Line<'a> {
    let mut spans = vec![Span::raw(" ")];
    for (tab, name) in [
        (LogsTab::Tool, "Tool log"),
        (LogsTab::Diagnostics, "Diagnostics"),
    ] {
        if tab == m.logs_tab {
            spans.push(Span::styled(t.g.here, t.style(Token::Accent)));
            spans.push(Span::styled(name, t.style(Token::Accent)));
        } else {
            spans.push(Span::raw(" "));
            spans.push(Span::styled(name, t.style(Token::Muted)));
        }
        spans.push(Span::raw("   "));
    }
    Line::from(spans)
}

/// The scope's snapshot above its rows: Health's counts; the log's source,
/// its window and where the logs are.
fn scope_head<'a>(
    scope: Scope,
    s: &crate::app::Snapshot,
    t: &Theme,
    width: usize,
) -> Vec<Line<'a>> {
    let mut out = Vec::new();
    match scope {
        Scope::Health => {
            let mut spans = vec![Span::raw("   ")];
            for fact in &s.facts {
                spans.push(Span::styled(
                    format!("{} ", t.say(&fact.label)),
                    t.style(Token::Muted),
                ));
                spans.push(Span::styled(t.say(&fact.value), t.style(Token::Text)));
                spans.push(Span::raw("    "));
            }
            out.push(Line::from(spans));
        }
        _ => {
            let w = s
                .facts
                .iter()
                .map(|f| cells(&f.label))
                .max()
                .unwrap_or(0)
                .min(10);
            for fact in &s.facts {
                let room = width.saturating_sub(w + 6);
                // Paths keep their end: the file and the folder that hold it.
                let value = if fact.key.ends_with("_dir") || fact.key.ends_with(".directory") {
                    fit_start(&t.say(&fact.value), room, t.caps.unicode)
                } else {
                    fit(&t.say(&fact.value), room, t.caps.unicode)
                };
                out.push(Line::from(vec![
                    Span::styled(
                        format!("   {:<w$}  ", t.say(&fact.label)),
                        t.style(Token::Muted),
                    ),
                    Span::styled(value, t.style(Token::Text)),
                ]));
            }
            out.push(Line::styled(
                "   the selected log's last lines, as `logs` shows them",
                t.style(Token::Muted),
            ));
        }
    }
    for (l, text) in &s.messages {
        out.push(Line::from(vec![
            Span::styled(
                format!("   {} ", widgets::level_glyph(*l, t)),
                t.style(widgets::level_token(*l)),
            ),
            Span::styled(t.say(text), t.style(Token::Text)),
        ]));
    }
    out
}

/// The page shown and its generation; while a value is open, SEEN — the
/// lines of it drawn (first, last) and how many it has — in place of the rows.
fn foot<'a>(d: &Detail, seen: Option<(usize, usize, usize)>, t: &Theme) -> Line<'a> {
    let dash = if t.caps.unicode { "–" } else { "-" };
    let dot = t.g.dot;
    let a = d.offset + 1;
    let b = d.offset + d.rows.len() as u64;
    let mut s = if let Some((first, last, n)) = seen {
        format!(" value lines {first}{dash}{last} of {n}")
    } else if d.rows.is_empty() {
        format!(" no rows past {} of {}", d.offset, d.total)
    } else {
        format!(" rows {a}{dash}{b} of {}", d.total)
    };
    s.push_str(&format!(
        " {dot} generation {}",
        d.generation.get(..12).unwrap_or(&d.generation)
    ));
    if seen.is_some() {
        return Line::styled(s, t.style(Token::Muted));
    }
    if b < d.total || d.offset > 0 {
        s.push_str(&format!(" {dot} pages past either end are read on request"));
    }
    let shown = d.shown().len();
    if !d.filter.is_empty() || d.level.is_some() {
        let (lq, rq) = if t.caps.unicode {
            ("“", "”")
        } else {
            ("\"", "\"")
        };
        s.push_str(&format!(" {dot} "));
        if let Some(l) = &d.level {
            s.push_str(&format!("level {l} "));
        }
        if !d.filter.is_empty() {
            s.push_str(&format!("filter {lq}{}{rq} ", d.filter));
        }
        s.push_str(&format!("{shown} of {} shown", d.rows.len()));
    }
    Line::styled(s, t.style(Token::Muted))
}

/// The columns a kind shows at WIDTH, by priority: the lowest drop first.
struct Cols {
    section: bool,
    note: bool,
    time: bool,
    source: bool,
}

fn cols(kind: Kind, width: usize) -> Cols {
    Cols {
        section: kind == Kind::Status && width >= 70,
        note: kind == Kind::Status && width >= 56,
        time: kind == Kind::Log && width >= 88,
        source: kind == Kind::Log && width >= 56,
    }
}

fn state_cell(word: &str, t: &Theme) -> (String, Style) {
    let (g, tok) = match word {
        "pass" => (t.g.ok, Token::Ok),
        "warn" => (t.g.warn, Token::Warn),
        "fail" => (t.g.fail, Token::Danger),
        _ => (t.g.info, Token::Info),
    };
    (format!("{g} {word:<4}"), t.style(tok))
}

fn level_style(level: &str, t: &Theme) -> Style {
    match level {
        "warn" => t.style(Token::Warn),
        "error" | "fail" => t.style(Token::Danger),
        "ok" => t.style(Token::Ok),
        _ => t.style(Token::Muted),
    }
}

/// One row as cells: (text, style, width or 0 for the rest).
fn cells_of(
    kind: Kind,
    r: &Row,
    c: &Cols,
    lw: usize,
    srcw: usize,
    t: &Theme,
) -> Vec<(String, Style, usize)> {
    let text = t.style(Token::Text);
    let muted = t.style(Token::Muted);
    match kind {
        Kind::Machine => vec![(r.col(0).into(), muted, lw), (r.col(1).into(), text, 0)],
        Kind::Operation => vec![
            (r.col(0).into(), muted, lw),
            (r.col(1).into(), text, 0),
            (r.col(2).into(), muted, usize::MAX),
        ],
        Kind::Status => {
            let mut v = Vec::new();
            if c.section {
                v.push((r.col(0).into(), t.style(Token::Heading), 14));
            }
            v.push((r.col(1).into(), muted, lw));
            v.push((r.col(2).into(), text, 0));
            if c.note && !r.col(3).is_empty() {
                v.push((r.col(3).into(), muted, usize::MAX));
            }
            v
        }
        Kind::Doctor => {
            let (s, st) = state_cell(r.col(0), t);
            vec![
                (s, st, 7),
                (r.col(1).into(), text, lw),
                (r.col(2).into(), muted, 0),
            ]
        }
        Kind::Log => {
            let mut v = Vec::new();
            if c.time {
                v.push((r.col(0).into(), muted, 20));
            }
            v.push((r.col(1).into(), level_style(r.col(1), t), 5));
            if c.source {
                v.push((r.col(2).into(), muted, srcw));
            }
            v.push((r.col(3).into(), text, 0));
            v
        }
    }
}

/// The rows shown, the focused one's values under it when open; HELD when
/// they are an earlier read's. Returns, for an open value, the lines of it
/// drawn (first, last) and how many it has.
fn rows(
    f: &mut Frame,
    area: Rect,
    d: &Detail,
    held: bool,
    m: &Model,
    t: &Theme,
    _tier: Tier,
) -> Option<(usize, usize, usize)> {
    let width = area.width as usize;
    let height = area.height as usize;
    let shown = d.shown();
    if shown.is_empty() || height == 0 {
        if !d.rows.is_empty() {
            f.render_widget(
                Paragraph::new(Line::styled(
                    "   No row on this page matches.",
                    t.style(Token::Muted),
                )),
                area,
            );
        }
        return None;
    }
    let c = cols(d.kind, width);
    let label = |r: &Row| match d.kind {
        Kind::Machine | Kind::Operation => cells(r.col(0)),
        Kind::Status | Kind::Doctor => cells(r.col(1)),
        Kind::Log => 0,
    };
    let lw = shown
        .iter()
        .map(|r| label(r))
        .max()
        .unwrap_or(0)
        .clamp(4, if d.kind == Kind::Doctor { 26 } else { 20 });
    let srcw = shown
        .iter()
        .map(|r| cells(r.col(2)))
        .max()
        .unwrap_or(0)
        .min(12);
    let focused = m.region == Region::Work;
    let cursor = d.cursor.min(shown.len() - 1);
    // The focused row's full values, wrapped beneath it when it is open.
    let open: Vec<String> = if d.open {
        shown[cursor]
            .cols
            .iter()
            .filter(|v| !v.is_empty())
            .flat_map(|v| wrap(&t.say(v), width.saturating_sub(8)))
            .collect()
    } else {
        Vec::new()
    };
    // Values longer than the room under their row are drawn a window at a
    // time, from the line the keys reached, kept here within them: the last
    // window is the furthest, so every key short of an end moves it.
    let total = open.len();
    let window = height.saturating_sub(1);
    let top = d.value_top.get().min(total.saturating_sub(window));
    d.value_top.set(top);
    let open = &open[top..total.min(top + window)];
    let room = height.saturating_sub(open.len()).max(1);
    let start = (cursor + 1).saturating_sub(room);
    let mut lines: Vec<Line> = Vec::new();
    let mut last_section = String::new();
    for (i, r) in shown.iter().enumerate().skip(start).take(room) {
        let here = i == cursor && focused;
        let dim = d.changed || held;
        let pointer = if here { t.g.pointer } else { " " };
        let mut spans = vec![Span::styled(format!(" {pointer} "), t.style(Token::Accent))];
        let mut used = 3;
        let parts = cells_of(d.kind, r, &c, lw, srcw, t);
        let n = parts.len();
        // The cell that carries the focus: the row's name, or a line's text.
        let focus_at = match d.kind {
            Kind::Machine | Kind::Operation => 0,
            Kind::Status => usize::from(c.section),
            Kind::Doctor => 1,
            Kind::Log => n - 1,
        };
        for (j, (text, style, w)) in parts.into_iter().enumerate() {
            let rest = width.saturating_sub(used + 2);
            let w = match w {
                0 => {
                    // The rest, less what a trailing note keeps.
                    if j + 1 < n {
                        rest.saturating_sub((rest / 3).max(8))
                    } else {
                        rest
                    }
                }
                usize::MAX => rest,
                w => w.min(rest),
            };
            // A status section is named on its first row only.
            let text = if d.kind == Kind::Status && j == 0 && c.section {
                if text == last_section && i != start {
                    String::new()
                } else {
                    last_section = text.clone();
                    text
                }
            } else {
                text
            };
            let cell = format!("{:<w$}", fit(&t.say(&text), w, t.caps.unicode), w = w);
            let style = if dim {
                t.style(Token::Muted)
            } else if here && j == focus_at {
                t.style(Token::Focus)
            } else {
                style
            };
            used += cells(&cell) + 2;
            spans.push(Span::styled(cell, style));
            spans.push(Span::raw("  "));
        }
        lines.push(Line::from(spans));
        if i == cursor {
            for l in open {
                lines.push(Line::styled(format!("       {l}"), t.style(Token::Text)));
            }
        }
    }
    f.render_widget(Paragraph::new(lines), area);
    (d.open && !open.is_empty()).then(|| (top + 1, top + open.len(), total))
}

/// The core's diagnostics kept in this session: read from the session's own
/// files, never from a core.
fn diagnostics(f: &mut Frame, area: Rect, mut lines: Vec<Line>, m: &Model, t: &Theme) {
    lines.push(Line::raw(""));
    if m.logs.is_empty() {
        lines.push(Line::styled(
            "   No diagnostics were kept in this session.",
            t.style(Token::Muted),
        ));
    }
    let room = (area.height as usize).saturating_sub(lines.len());
    for l in m.logs.iter().skip(m.scroll).take(room) {
        lines.push(Line::styled(
            format!(
                "   {}",
                fit(l, (area.width as usize).saturating_sub(4), t.caps.unicode)
            ),
            t.style(Token::Text),
        ));
    }
    f.render_widget(Paragraph::new(lines), area);
}
