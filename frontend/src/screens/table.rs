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
        Fault::Said {
            status,
            code: _,
            text,
        } if status == "refused" => (
            format!("{} Needs attention", t.g.warn),
            Token::Warn,
            text.clone(),
            "r asks again; D debugging brief".to_string(),
        ),
        Fault::Said {
            status: _,
            code: _,
            text,
        } => (
            format!("{} The check could not finish", t.g.fail),
            Token::Danger,
            text.clone(),
            format!("r tries again {dot} L shows the log {dot} D brief"),
        ),
        Fault::NoAnswer(why) => (
            format!("{} no answer", t.g.fail),
            Token::Danger,
            format!("The core stopped without answering ({why})."),
            "L then Tab diagnostics; r retry; D debug brief".to_string(),
        ),
        Fault::NotSent(why) => (
            format!("{} not sent", t.g.fail),
            Token::Danger,
            format!("The request was not delivered ({why}); nothing ran."),
            "r tries again; D debugging brief".to_string(),
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
        Req::Snapshot(s) => *s == kind.scope(),
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
            if newest.is_some() {
                let shown = format!(
                    "{} This is an earlier read; {}",
                    t.g.warn,
                    if reading {
                        "reading the latest now"
                    } else {
                        "r reads the latest"
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
                    Kind::Items
                    | Kind::Choices
                    | Kind::Review
                    | Kind::Opaque
                    | Kind::Bundles
                    | Kind::RestoreReview
                    | Kind::Conflicts
                    | Kind::Diff
                    | Kind::RestoreStatus
                    | Kind::Brief
                    | Kind::Step
                    | Kind::Report => "The core sent no rows.",
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
    if !d.is_some_and(|d| d.open) {
        if let Some(d) = d.filter(|d| d.loaded) {
            let tail_h = u16::from(d.total > 0) + u16::from(d.editing);
            let [body, tail] =
                Layout::vertical([Constraint::Min(0), Constraint::Length(tail_h)]).areas(inner);
            rows(f, body, d, newest.is_some(), m, t, tier, head);
            let mut lines = Vec::new();
            if d.total > 0 {
                lines.push(foot(d, None, t, m));
            }
            if d.editing {
                lines.push(Line::styled(
                    format!(" / {}_", d.filter),
                    t.style(Token::Gate),
                ));
            }
            f.render_widget(Paragraph::new(lines), tail);
        } else {
            super::draw_lines(f, inner, head, Vec::new(), None, 0, m, t);
        }
        return;
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
        .and_then(|d| rows(f, body, d, held, m, t, tier, Vec::new()));
    let mut tl = Vec::new();
    tl.extend(footed.map(|d| foot(d, seen, t, m)));
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
fn foot<'a>(d: &Detail, _seen: Option<(usize, usize, usize)>, t: &Theme, m: &Model) -> Line<'a> {
    let v = m.viewport.borrow();
    if !d.open && (v.total > v.height || d.offset > 0 || (d.rows.len() as u64) < d.total) {
        let shown = d.shown();
        let visible: Vec<_> = v
            .rows
            .iter()
            .filter(|r| r.1 < v.top + v.height && r.2 > v.top)
            .collect();
        if let (Some(a), Some(b)) = (visible.first(), visible.last()) {
            let first = d.offset + a.0 as u64 + 1;
            let last = d.offset + b.0 as u64 + 1;
            let _ = shown;
            return Line::styled(
                format!(
                    " rows {first}{}{last} of {}",
                    if t.caps.unicode { "–" } else { "-" },
                    d.total
                ),
                t.style(Token::Muted),
            );
        }
    }
    Line::raw("")
}

/// A home prefix is presentation, never an input to the core.
pub fn home_path(path: &str) -> String {
    if let Ok(home) = std::env::var("HOME")
        && let Some(rest) = path.strip_prefix(&home)
        && (rest.is_empty() || rest.starts_with('/'))
    {
        return format!("~{rest}");
    }
    path.into()
}

fn saved_path(m: &Model) -> Option<String> {
    m.detail(Kind::Status)?
        .rows
        .iter()
        .find(|r| r.col(0) == "Recorded" && !r.focusable(Kind::Status) && !r.col(3).is_empty())
        .map(|r| home_path(r.col(3)))
}

fn source(m: &Model, kind: Kind, r: &Row) -> Option<String> {
    let mac = m.hello.as_ref().is_some_and(|h| h.platform == "macos");
    match kind {
        Kind::Machine => Some(
            if mac {
                "read from this Mac just now"
            } else {
                "read from Linux just now"
            }
            .into(),
        ),
        Kind::Status if r.col(0) == "Recorded" => Some(saved_path(m).map_or_else(
            || "from the saved record".into(),
            |p| format!("from the saved record ({p})"),
        )),
        Kind::Status if r.col(0) == "omarchy-mac-setup --status" => {
            Some("reported by Omarchy setup on Linux".into())
        }
        Kind::Status => Some(
            if mac {
                "read from this Mac just now"
            } else {
                "read from Linux just now"
            }
            .into(),
        ),
        Kind::Doctor => Some("reported by the system health check".into()),
        Kind::Log => {
            let generation = m.detail(Kind::Log).map(|d| d.generation.as_str());
            let file = [&m.logread.snap, &m.logread.held]
                .into_iter()
                .flatten()
                .find(|s| Some(s.generation.as_str()) == generation)
                .and_then(|s| s.facts.iter().find(|f| f.key == "logs.source"))
                .map(|f| f.value.as_str());
            file.map(|file| format!("from the {} log", home_path(file)))
                .or_else(|| (!r.col(2).is_empty()).then(|| format!("from the {} log", r.col(2))))
        }
        Kind::Operation => Some(
            if r.key.starts_with("recorded.") {
                "from the saved operation record"
            } else {
                "read from the current operation check"
            }
            .into(),
        ),
        _ => None,
    }
}

fn value(kind: Kind, r: &Row) -> &str {
    r.col(match kind {
        Kind::Status | Kind::Doctor => 2,
        Kind::Log => 3,
        _ => 1,
    })
}

pub fn expandable(m: &Model, kind: Kind, r: &Row) -> bool {
    r.focusable(kind) && source(m, kind, r).is_some()
}

fn expansion(m: &Model, kind: Kind, r: &Row, t: &Theme, width: usize) -> Vec<String> {
    let mut out = Vec::new();
    // The full value is useful where a table condensed it, or where display
    // units hide its exact bytes. The row's column headings are not repeated.
    if value(kind, r).chars().count() > 32 || value(kind, r).contains('\n') {
        let full = if kind == Kind::Machine {
            widgets::fact_value(&r.key, r.col(0), value(kind, r))
        } else {
            value(kind, r).into()
        };
        out.extend(wrap(&t.say(&full), width));
    }
    if kind == Kind::Operation && !r.col(2).is_empty() && value(kind, r).chars().count() > 32 {
        out.extend(wrap(&t.say(r.col(2)), width));
    }
    if let Some(s) = source(m, kind, r) {
        out.extend(wrap(&t.say(&s), width));
    }
    if out.is_empty() && expandable(m, kind, r) {
        out.extend(wrap(&t.say(value(kind, r)), width));
    }
    out
}

fn row_lines<'a>(
    m: &Model,
    kind: Kind,
    r: &Row,
    here: bool,
    t: &Theme,
    width: usize,
) -> Vec<Line<'a>> {
    if kind == Kind::Status && !r.focusable(kind) {
        let mac = m.hello.as_ref().is_some_and(|h| h.platform == "macos");
        let title = match r.col(0) {
            "Detected now" if mac => "Read from this Mac now",
            "Detected now" => "Read from Linux now",
            "omarchy-mac-setup --status" => "Omarchy setup status",
            "Recorded" => "Saved progress",
            s => s,
        };
        let mut out = vec![Line::styled(
            format!(" {} {title}", t.g.bar),
            t.style(Token::Heading),
        )];
        let note = if r.col(0) == "Recorded" {
            format!("Saved in {}", home_path(r.col(3)))
        } else if r.col(0) == "Detected now" && mac {
            format!("Model ID {}", r.col(3))
        } else if r.col(3) == "upstream" {
            "Reported by Omarchy setup".into()
        } else {
            r.col(3).into()
        };
        if !r.col(3).is_empty() {
            out.extend(
                wrap(&t.say(&note), width.saturating_sub(6))
                    .into_iter()
                    .map(|l| Line::styled(format!("     {l}"), t.style(Token::Muted))),
            );
        }
        return out;
    }
    let label = match kind {
        Kind::Status | Kind::Doctor => r.col(1),
        Kind::Log => r.col(1),
        _ => r.col(0),
    };
    let log_label = if kind == Kind::Log && !r.col(2).is_empty() {
        format!("{} {}", r.col(1), r.col(2))
    } else {
        label.into()
    };
    let label = log_label.as_str();
    let label = if kind == Kind::Machine && r.key == "machine.model" {
        widgets::model_label(value(kind, r))
    } else {
        label
    };
    let val = if kind == Kind::Machine {
        widgets::fact_value(&r.key, label, value(kind, r))
    } else {
        value(kind, r).into()
    };
    let label = t.say(label);
    let stacked = cells(&label) > width / 2;
    let prefix = if stacked {
        String::from("     ")
    } else if label.is_empty() {
        format!(" {} ", if here { t.g.pointer } else { " " })
    } else {
        format!(" {} {label}: ", if here { t.g.pointer } else { " " })
    };
    let mut out = Vec::new();
    if stacked {
        for (i, l) in wrap(&label, width.saturating_sub(4))
            .into_iter()
            .enumerate()
        {
            out.push(Line::styled(
                format!(" {} {l}", if i == 0 && here { t.g.pointer } else { " " }),
                t.style(if here && i == 0 {
                    Token::Focus
                } else {
                    Token::Muted
                }),
            ));
        }
    }
    let parts = wrap(&t.say(&val), width.saturating_sub(cells(&prefix)).max(8));
    let parts = if parts.is_empty() {
        vec![String::new()]
    } else {
        parts
    };
    for (i, l) in parts.into_iter().enumerate() {
        out.push(Line::from(vec![
            Span::styled(
                if i == 0 {
                    prefix.clone()
                } else {
                    " ".repeat(cells(&prefix).min(width.saturating_sub(8)))
                },
                t.style(if here && i == 0 && !stacked {
                    Token::Focus
                } else {
                    Token::Muted
                }),
            ),
            Span::styled(l, t.style(Token::Text)),
        ]));
    }
    if kind == Kind::Status && !r.col(3).is_empty() {
        let ok = r.col(3) == "supported";
        out.extend(
            wrap(&t.say(r.col(3)), width.saturating_sub(6))
                .into_iter()
                .map(|l| {
                    Line::styled(
                        format!(
                            "     {}{l}",
                            if ok {
                                format!("{} ", t.g.ok)
                            } else {
                                String::new()
                            }
                        ),
                        t.style(if ok { Token::Ok } else { Token::Muted }),
                    )
                }),
        );
    }
    if kind == Kind::Operation && !r.col(2).is_empty() {
        out.extend(
            wrap(&t.say(r.col(2)), width.saturating_sub(6))
                .into_iter()
                .map(|l| Line::styled(format!("     {l}"), t.style(Token::Muted))),
        );
    }
    if kind == Kind::Doctor {
        out.push(Line::styled(
            format!(
                "     {} {}",
                match r.col(0) {
                    "pass" => t.g.ok,
                    "warn" => t.g.warn,
                    "fail" => t.g.fail,
                    _ => t.g.info,
                },
                r.col(0)
            ),
            t.style(match r.col(0) {
                "pass" => Token::Ok,
                "fail" => Token::Danger,
                "warn" => Token::Warn,
                _ => Token::Muted,
            }),
        ));
    }
    out
}

/// The rows shown, the focused one's values under it when open; HELD when
/// they are an earlier read's. Returns, for an open value, the lines of it
/// drawn (first, last) and how many it has.
#[allow(clippy::too_many_arguments)]
fn rows(
    f: &mut Frame,
    area: Rect,
    d: &Detail,
    _held: bool,
    m: &Model,
    t: &Theme,
    _tier: Tier,
    mut prefix: Vec<Line<'_>>,
) -> Option<(usize, usize, usize)> {
    let width = area.width as usize;
    let height = area.height as usize;
    let shown = d.shown();
    if shown.is_empty() || height == 0 {
        if !d.rows.is_empty() {
            prefix.push(Line::styled(
                "   No row on this page matches.",
                t.style(Token::Muted),
            ));
        }
        super::draw_lines(f, area, prefix, Vec::new(), None, 0, m, t);
        return None;
    }
    let cursor = d.cursor.min(shown.len() - 1);
    if d.open {
        let r = shown[cursor];
        let value_lines = expansion(m, d.kind, r, t, width.saturating_sub(8));
        let label = match d.kind {
            Kind::Status | Kind::Doctor | Kind::Log => r.col(1),
            _ => r.col(0),
        };
        let mut lines = prefix;
        if value(d.kind, r).chars().count() > 32 || value(d.kind, r).contains('\n') {
            lines.push(Line::styled(
                format!(" {} {}", t.g.pointer, t.say(label)),
                t.style(Token::Focus),
            ));
        } else {
            lines.extend(row_lines(m, d.kind, r, true, t, width));
        }
        let window = height.saturating_sub(lines.len());
        let top = d
            .value_top
            .get()
            .min(value_lines.len().saturating_sub(window));
        d.value_top.set(top);
        lines.extend(
            value_lines
                .iter()
                .skip(top)
                .take(window)
                .map(|l| Line::styled(format!("       {l}"), t.style(Token::Text))),
        );
        f.render_widget(Paragraph::new(lines), area);
        return Some((
            top + 1,
            (top + window).min(value_lines.len()),
            value_lines.len(),
        ));
    }
    let mut lines = prefix;
    let mut anchors = Vec::new();
    for (i, r) in shown.iter().enumerate() {
        let here =
            i == cursor && m.region == Region::Work && m.focus_visible() && r.focusable(d.kind);
        let block = row_lines(m, d.kind, r, here, t, width);
        if r.focusable(d.kind) {
            anchors.push((i, lines.len(), lines.len() + block.len()));
        }
        lines.extend(block);
    }
    super::draw_lines(f, area, lines, anchors, Some(cursor), 0, m, t);
    None
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
    for l in &m.logs {
        lines.push(Line::styled(
            format!(
                "   {}",
                fit(l, (area.width as usize).saturating_sub(4), t.caps.unicode)
            ),
            t.style(Token::Text),
        ));
    }
    super::draw_lines(f, area, lines, Vec::new(), None, m.scroll, m, t);
}
