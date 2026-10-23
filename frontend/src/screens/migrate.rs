//! The migration's screens over scope `profile` (docs/MIGRATION.md → *On
//! the wire*; docs/UX.md → *Every screen*): 3 the environment scan (its
//! adapters' states, and `profile.scan`'s progress as the core reports it);
//! 4 the selection by category; 5–9 and 11, one list and detail with a tab
//! per category, decisions first, as the core orders them; and the Migration
//! Review with the profile's actions. Every count, size, state and reason is
//! the core's; the person's choices made here are marked as theirs and
//! travel only when saved.

use super::{Item, draw_items, table};
use crate::app::{Model, Req, review_actions};
use crate::read::{Detail, Kind, Row, Scope};
use crate::select::{self, COL_BY};
use crate::theme::{Theme, Token};
use crate::widgets::{self, cells, fit, wrap};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

fn text(s: impl Into<String>, tok: Token) -> Item<'static> {
    Item::Text(s.into(), tok)
}

/// What the profile scope says about why there is nothing to show yet.
fn waiting<'a>(m: &'a Model, v: &mut Vec<Item<'a>>) -> bool {
    if m.check {
        v.push(text(
            "The startup check answers hello and the journey snapshot only, so this view reads nothing in this session.",
            Token::Muted,
        ));
        return true;
    }
    if let Some(f) = &m.profile.fault {
        v.push(Item::Fault(f));
    }
    if m.profile.snap.is_none() {
        if m.reading(|r| *r == Req::Snapshot(Scope::Profile)) {
            v.push(text("Reading the profile.", Token::Muted));
        } else if m.profile.fault.is_none() {
            v.push(text("Not read yet: r reads it.", Token::Muted));
        }
        return true;
    }
    false
}

/// Screen 3's blocks: the profile's own facts, each source's state, and what
/// the last scan reported while it ran.
pub fn scan_items(m: &Model) -> Vec<Item<'_>> {
    let mut v = Vec::new();
    if waiting(m, &mut v) {
        return v;
    }
    let s = m.profile.snap.as_ref().expect("read");
    for f in s.facts.iter().filter(|f| f.key.starts_with("profile.")) {
        v.push(Item::Pair {
            label: f.label.clone(),
            value: f.value.clone(),
            token: Token::Text,
            state: &f.state,
            recorded: false,
        });
    }
    v.extend(s.blockers.iter().map(Item::Blocker));
    v.push(Item::Blank);
    v.push(Item::Heading("Sources"));
    let adapters: Vec<_> = s
        .facts
        .iter()
        .filter(|f| f.key.starts_with("adapter."))
        .collect();
    if adapters.is_empty() {
        v.push(text("The profile reports no source yet.", Token::Muted));
    }
    v.extend(adapters.into_iter().map(Item::Check));
    let scanning =
        m.reading(|r| matches!(r, Req::Execute { action, .. } if action == "profile.scan"));
    if scanning || !m.steps.is_empty() || !m.notes.is_empty() {
        v.push(Item::Blank);
        v.push(Item::Heading(if scanning {
            "Reading now"
        } else {
            "The last action reported"
        }));
        let n = m.steps.len();
        for (i, (label, done, total)) in m.steps.iter().enumerate() {
            let now = scanning && i + 1 == n;
            let mut value = if *total > 0 {
                format!("{done} of {total}")
            } else {
                String::new()
            };
            if now {
                value = format!("reading now {value}");
            }
            v.push(Item::Pair {
                label: label.clone(),
                value,
                token: if now { Token::Accent } else { Token::Text },
                state: "info",
                recorded: false,
            });
        }
        v.extend(m.notes.iter().map(|(l, t)| Item::Message(*l, t)));
    }
    v.push(Item::Blank);
    match s.action("profile.scan") {
        Some(a) => {
            if !a.explain.is_empty() {
                v.push(Item::Explain(&a.explain));
            }
            v.push(text(format!("⏎ {}", a.label), Token::Accent));
        }
        None => v.push(text("The core does not offer a scan now.", Token::Muted)),
    }
    v
}

pub fn scan(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let inner = widgets::panel(f, area, "Environment scan", t);
    draw_items(f, inner, &scan_items(m), m.page_scroll, None, m, t);
}

/// How many of the person's choices made here fall in category CAT.
fn changed_in(m: &Model, cat: &str) -> usize {
    let Some(d) = m.detail(Kind::Items) else {
        return 0;
    };
    m.picks
        .iter()
        .filter(|p| d.rows.iter().any(|r| r.id == p.id && r.col(0) == cat))
        .count()
}

/// Screen 4: the categories, each with the core's count and size, a mark
/// where a decision is open, and the choices made here.
pub fn selection(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let inner = widgets::panel(f, area, "Migration selection", t);
    let width = inner.width as usize;
    let mut head: Vec<Item> = Vec::new();
    if waiting(m, &mut head) {
        return draw_items(f, inner, &head, 0, None, m, t);
    }
    let mut lines: Vec<Line> = Vec::new();
    let s = m.profile.snap.as_ref().expect("read");
    if let Some(c) = s.facts.iter().find(|f| f.key == "profile.counts") {
        lines.push(Line::from(vec![
            Span::styled(format!("   {}  ", t.say(&c.label)), t.style(Token::Muted)),
            Span::styled(t.say(&c.value), t.style(Token::Text)),
        ]));
        lines.push(Line::raw(""));
    }
    let cats = m.categories();
    if cats.is_empty() {
        lines.push(Line::styled(
            "   The profile lists no category yet: a scan makes them.",
            t.style(Token::Muted),
        ));
    }
    let lw = cats
        .iter()
        .map(|(_, f)| cells(&f.label))
        .max()
        .unwrap_or(0)
        .clamp(8, 20);
    let mut anchors = Vec::new();
    for (i, (cat, fact)) in cats.iter().enumerate() {
        anchors.push((i, lines.len(), lines.len() + 1));
        let here = i == m.sel && m.region == crate::app::Region::Work && m.focus_visible();
        let (style, glyph) = widgets::style_of(t, &fact.state);
        let g = if matches!(fact.state.as_str(), "info" | "ok" | "") {
            " "
        } else {
            glyph
        };
        let mut spans = vec![
            Span::styled(
                format!(" {} ", if here { t.g.pointer } else { " " }),
                t.style(Token::Accent),
            ),
            Span::styled(
                format!("{:<lw$}", fit(&t.say(&fact.label), lw, t.caps.unicode)),
                if here {
                    t.style(Token::Focus)
                } else {
                    t.style(Token::Text)
                },
            ),
            Span::raw("  "),
            Span::styled(format!("{g} "), style),
        ];
        let changed = changed_in(m, cat);
        let note = if changed > 0 {
            format!("  {} {changed} chosen here", t.g.dot)
        } else {
            String::new()
        };
        let room = width.saturating_sub(lw + 8 + cells(&note));
        spans.push(Span::styled(
            fit(&t.say(&fact.value), room, t.caps.unicode),
            t.style(Token::Text),
        ));
        spans.push(Span::styled(note, t.style(Token::Accent)));
        lines.push(Line::from(spans));
    }
    lines.push(Line::raw(""));
    let d = m.detail(Kind::Items);
    if d.is_some_and(|d| d.changed) {
        lines.push(changed_line(t));
    }
    if let Some(fault) = d.and_then(|d| d.fault.as_ref()) {
        lines.extend(table::fault_lines(fault, t, width));
    }
    for l in wrap(
        &t.say("⏎ opens a category's items; space puts all of them in or out."),
        width.saturating_sub(4),
    ) {
        lines.push(Line::styled(format!("   {l}"), t.style(Token::Muted)));
    }
    super::draw_lines(f, inner, lines, anchors, Some(m.sel), 0, m, t);
}

fn changed_line<'a>(t: &Theme) -> Line<'a> {
    Line::styled(
        format!(
            " {} changed since you looked {} r",
            t.g.warn,
            if t.caps.unicode { "—" } else { "-" }
        ),
        t.style(Token::Warn),
    )
}

/// An item's state as a mark (docs/UX.md → *Glyphs*): included, not
/// included, waiting for a decision; `never` keeps its word.
fn mark(state: &str, t: &Theme) -> (&'static str, Token) {
    let u = t.caps.unicode;
    match state {
        "include" => (if u { "◉" } else { "[x]" }, Token::Selected),
        "exclude" => (if u { "○" } else { "[ ]" }, Token::Text),
        "decide" => (if u { "◌" } else { "[?]" }, Token::Warn),
        _ => (if u { "–" } else { "[-]" }, Token::Muted),
    }
}

/// Who chose ROW's state: the person, now or at an earlier save; nothing for
/// the core's default.
fn by(row: &Row, m: &Model) -> &'static str {
    let mine = m.picks.iter().any(|p| p.id == row.id && p.state.is_some());
    if mine {
        "you, not saved"
    } else if row.col(COL_BY) == "person" {
        "you"
    } else {
        ""
    }
}

/// The category tabs: the profile's categories, the current one marked.
fn tabs<'a>(m: &Model, t: &Theme, width: usize) -> Line<'a> {
    let cats = m.categories();
    let mut spans = vec![Span::raw(" ")];
    let mut used = 1;
    // From the tab before the current one, when they do not all fit.
    let total: usize = cats.iter().map(|(_, f)| cells(&f.label) + 3).sum();
    let start = if total > width {
        m.inv.tab.saturating_sub(1)
    } else {
        0
    };
    for (i, (_, f)) in cats.iter().enumerate().skip(start) {
        let label = t.say(&f.label);
        if used + cells(&label) + 3 > width {
            break;
        }
        used += cells(&label) + 3;
        if i == m.inv.tab {
            spans.push(Span::styled(t.g.here, t.style(Token::Accent)));
            spans.push(Span::styled(label, t.style(Token::Accent)));
        } else {
            spans.push(Span::raw(" "));
            spans.push(Span::styled(label, t.style(Token::Muted)));
        }
        spans.push(Span::raw("  "));
    }
    Line::from(spans)
}

/// Screens 5–9 and 11: the category's items, decisions first, each with its
/// mark, what it becomes on Linux and who chose; an item's choices on Enter.
pub fn inventory(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let reading = m.reading(|r| matches!(r, Req::Detail(p) if p.kind.scope() == Scope::Profile));
    let title = if reading {
        format!("Inventory {} reading", t.g.dot)
    } else {
        "Inventory".to_string()
    };
    let inner = widgets::panel(f, area, &title, t);
    let width = inner.width as usize;
    let mut head: Vec<Item> = Vec::new();
    if waiting(m, &mut head) {
        return draw_items(f, inner, &head, 0, None, m, t);
    }
    let mut lines = vec![tabs(m, t, width)];
    let d = m.detail(Kind::Items);
    let (list, side) = if m.inv.open && width >= 100 {
        let [a, b] = Layout::horizontal([Constraint::Min(40), Constraint::Length(46)]).areas(inner);
        (a, Some(b))
    } else {
        (inner, None)
    };
    match d {
        None => lines.push(Line::styled(
            if reading {
                "   Reading the inventory."
            } else {
                "   Not read yet: r reads it."
            },
            t.style(Token::Muted),
        )),
        Some(d) => {
            if d.changed {
                lines.push(changed_line(t));
            }
            if let Some(fault) = &d.fault {
                lines.extend(table::fault_lines(fault, t, width));
            }
            if d.loaded && d.rows.is_empty() {
                lines.push(Line::styled(
                    "   The inventory holds no item.",
                    t.style(Token::Muted),
                ));
            }
        }
    }
    if m.inv.open && side.is_none() {
        draw_item(f, inner, lines, m, t);
        return;
    }
    if let Some(d) = d.filter(|d| d.loaded) {
        let [body, tail] =
            Layout::vertical([Constraint::Min(0), Constraint::Length(1)]).areas(list);
        rows(f, body, d, m, t, lines);
        f.render_widget(Paragraph::new(foot(d, t)), tail);
    } else {
        super::draw_lines(f, list, lines, Vec::new(), None, 0, m, t);
    }
    if let Some(side) = side {
        let inner = widgets::panel(f, side, "Item", t);
        draw_item(f, inner, Vec::new(), m, t);
    }
}

fn foot<'a>(d: &Detail, t: &Theme) -> Line<'a> {
    if d.editing {
        return Line::from(vec![
            Span::styled(" / ", t.style(Token::Accent)),
            Span::styled(d.filter.clone(), t.style(Token::Gate)),
            Span::styled(if t.caps.unicode { "▏" } else { "_" }, t.style(Token::Gate)),
        ]);
    }
    let dash = if t.caps.unicode { "–" } else { "-" };
    let shown = d.shown().len();
    let mut s = if d.rows.is_empty() {
        format!(" no rows past {} of {}", d.offset, d.total)
    } else {
        format!(
            " rows {}{dash}{} of {} {} {shown} in this category",
            d.offset + 1,
            d.offset + d.rows.len() as u64,
            d.total,
            t.g.dot
        )
    };
    if !d.filter.is_empty() {
        s.push_str(&format!(" {} filter {}", t.g.dot, d.filter));
    }
    Line::styled(s, t.style(Token::Muted))
}

/// The list: a mark, the name, its source and version where there is room,
/// what it becomes, and who chose.
fn rows(f: &mut Frame, area: Rect, d: &Detail, m: &Model, t: &Theme, mut prefix: Vec<Line<'_>>) {
    let width = area.width as usize;
    let height = area.height as usize;
    let shown = d.shown();
    if shown.is_empty() || height == 0 {
        if !d.rows.is_empty() {
            prefix.push(Line::styled(
                "   No item of this category on this page matches.",
                t.style(Token::Muted),
            ));
        }
        super::draw_lines(f, area, prefix, Vec::new(), None, 0, m, t);
        return;
    }
    let wide = width >= 70;
    let cursor = d.cursor.min(shown.len() - 1);
    let mark_w = if t.caps.unicode { 1 } else { 3 };
    let name_w = (width / 4).clamp(10, 24);
    let mut lines = prefix;
    let mut anchors = Vec::new();
    for (i, r) in shown.iter().enumerate() {
        anchors.push((i, lines.len(), lines.len() + 1));
        let here = i == cursor && m.region == crate::app::Region::Work && m.focus_visible();
        let state = select::state(r, &m.picks);
        let (g, tok) = mark(state, t);
        let who = by(r, m);
        let mut spans = vec![
            Span::styled(
                format!(" {} ", if here { t.g.pointer } else { " " }),
                t.style(Token::Accent),
            ),
            Span::styled(format!("{g:<mark_w$} "), t.style(tok)),
            Span::styled(
                format!("{:<name_w$}", fit(&t.say(r.col(1)), name_w, t.caps.unicode)),
                if here {
                    t.style(Token::Focus)
                } else {
                    t.style(Token::Text)
                },
            ),
            Span::raw("  "),
        ];
        let mut used = 3 + mark_w + 1 + name_w + 2;
        let mut cell = |s: String, w: usize, style: Style, spans: &mut Vec<Span>| {
            spans.push(Span::styled(
                format!("{:<w$}", fit(&t.say(&s), w, t.caps.unicode)),
                style,
            ));
            spans.push(Span::raw("  "));
            used += w + 2;
        };
        if wide {
            cell(r.col(2).into(), 10, t.style(Token::Muted), &mut spans);
            cell(r.col(3).into(), 9, t.style(Token::Muted), &mut spans);
        }
        let tail = if state == "decide" || state == "never" {
            format!("{state} {who}")
        } else {
            who.to_string()
        };
        let tail_w = cells(&tail).min(16);
        let rest = width.saturating_sub(used + tail_w + 2);
        spans.push(Span::styled(
            format!("{:<rest$}", fit(&t.say(r.col(4)), rest, t.caps.unicode)),
            t.style(Token::Text),
        ));
        spans.push(Span::raw("  "));
        spans.push(Span::styled(
            fit(&tail, tail_w, t.caps.unicode),
            if state == "decide" {
                t.style(Token::Warn)
            } else {
                t.style(Token::Muted)
            },
        ));
        lines.push(Line::from(spans));
    }
    super::draw_lines(f, area, lines, anchors, Some(cursor), 0, m, t);
}

fn draw_item(f: &mut Frame, area: Rect, mut prefix: Vec<Line<'_>>, m: &Model, t: &Theme) {
    let (lines, at) = item_lines(m, t, area.width as usize);
    let anchors = at
        .map(|line| {
            let first = prefix.len() + line.saturating_sub(m.inv.choice);
            (0..m.item_choices().len())
                .map(|i| (i, first + i, first + i + 1))
                .collect()
        })
        .unwrap_or_default();
    prefix.extend(lines);
    super::draw_lines(f, area, prefix, anchors, at.map(|_| m.inv.choice), 0, m, t);
}

/// The focused item: its name, its choices (the one picked here marked,
/// read whole before "none" is said), then its fields as the core sent them.
/// Returns the lines and the place of the focused choice among them.
fn item_lines<'a>(m: &Model, t: &Theme, width: usize) -> (Vec<Line<'a>>, Option<usize>) {
    let mut out = Vec::new();
    let mut at = None;
    let Some(r) = m.item() else {
        return (out, at);
    };
    out.push(Line::from(vec![
        Span::styled(format!(" {}", t.g.bar), t.style(Token::Accent)),
        Span::styled(t.say(r.col(1)), t.style(Token::Heading)),
    ]));
    let size = r.col(9).parse::<u64>().ok().map(widgets::gb);
    let state = select::state(r, &m.picks);
    let who = by(r, m);
    let state = if who.is_empty() {
        state.to_string()
    } else {
        format!("{state} {} {who}", t.g.dot)
    };
    let mut fields = vec![Line::raw("")];
    for (label, value) in [
        ("Source", r.col(2).to_string()),
        ("Version", r.col(3).to_string()),
        ("Becomes", r.col(4).to_string()),
        ("State", state),
        ("Class", r.col(6).to_string()),
        ("Why", r.col(8).to_string()),
        ("Size", size.unwrap_or_default()),
        ("Evidence", r.col(10).to_string()),
        ("Requested", r.col(11).to_string()),
    ] {
        if value.is_empty() {
            continue;
        }
        fields.extend(widgets::pair(
            t,
            label,
            &t.say(&value),
            9,
            width,
            t.style(Token::Text),
        ));
    }
    let picked = m
        .picks
        .iter()
        .find(|p| p.id == r.id)
        .and_then(|p| p.decision.as_ref())
        .map(|(c, _)| c.clone());
    match m.detail(Kind::Choices) {
        Some(d) if d.loaded && !m.whole(Kind::Choices) && d.fault.is_none() => {
            out.push(Line::styled(
                format!("   Reading the choices ({} of {}).", d.rows.len(), d.total),
                t.style(Token::Muted),
            ));
        }
        Some(d) if d.loaded => {
            let choices = m.item_choices();
            if choices.is_empty() {
                out.push(Line::styled(
                    "   This item offers no choice.",
                    t.style(Token::Muted),
                ));
            }
            for (i, c) in choices.iter().enumerate() {
                let here = i == m.inv.choice && m.focus_visible();
                if i == m.inv.choice {
                    at = Some(out.len());
                }
                let on = picked.as_deref() == Some(c.col(0));
                let g = match (on, t.caps.unicode) {
                    (true, true) => "◉",
                    (false, true) => "○",
                    (true, false) => "(x)",
                    (false, false) => "( )",
                };
                let guess = if c.col(2) == "1" { " (a guess)" } else { "" };
                out.push(Line::from(vec![
                    Span::styled(
                        format!(" {} ", if here { t.g.pointer } else { " " }),
                        t.style(Token::Accent),
                    ),
                    Span::styled(format!("{g} "), t.style(Token::Selected)),
                    Span::styled(
                        fit(
                            &format!("{}{guess}", t.say(c.col(1))),
                            width.saturating_sub(8),
                            t.caps.unicode,
                        ),
                        if here {
                            t.style(Token::Focus)
                        } else {
                            t.style(Token::Text)
                        },
                    ),
                ]));
            }
        }
        Some(d) => {
            if let Some(f) = &d.fault {
                out.extend(table::fault_lines(f, t, width));
            } else {
                out.push(Line::styled(
                    "   Reading the choices.",
                    t.style(Token::Muted),
                ));
            }
        }
        None => out.push(Line::styled(
            "   The choices are read when the item opens.",
            t.style(Token::Muted),
        )),
    }
    out.extend(fields);
    (out, at)
}

/// The Migration Review: what is selected by category with its size and
/// what comes next, as the core reviewed it; the choices made here; the core's
/// answer to the last check of them; and the profile's actions.
pub fn review(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let inner = widgets::panel(f, area, "Migration review", t);
    let width = inner.width as usize;
    let mut head: Vec<Item> = Vec::new();
    if waiting(m, &mut head) {
        return draw_items(f, inner, &head, 0, None, m, t);
    }
    let mut lines: Vec<Line> = Vec::new();
    match m.detail(Kind::Review) {
        None => lines.push(Line::styled(
            "   Not read yet: r reads it.",
            t.style(Token::Muted),
        )),
        Some(d) => {
            if d.changed {
                lines.push(changed_line(t));
            }
            if let Some(fault) = &d.fault {
                lines.extend(table::fault_lines(fault, t, width));
            }
            if d.loaded && d.rows.is_empty() {
                lines.push(Line::styled(
                    "   Nothing is selected yet.",
                    t.style(Token::Muted),
                ));
            }
            let lw = d
                .rows
                .iter()
                .map(|r| cells(r.col(0)))
                .max()
                .unwrap_or(0)
                .clamp(8, 18);
            for r in &d.rows {
                let size = r.col(2).parse::<u64>().ok().map(widgets::gb);
                let left = format!(
                    "   {:<lw$}  {:>5}  {:>8}  ",
                    fit(&t.say(r.col(0)), lw, t.caps.unicode),
                    r.col(1),
                    size.unwrap_or_default()
                );
                let room = width.saturating_sub(cells(&left));
                let notes = wrap(&t.say(r.col(3)), room);
                let notes = if notes.is_empty() {
                    vec![String::new()]
                } else {
                    notes
                };
                for (i, note) in notes.into_iter().enumerate() {
                    lines.push(Line::from(vec![
                        Span::styled(
                            if i == 0 {
                                left.clone()
                            } else {
                                " ".repeat(cells(&left))
                            },
                            t.style(Token::Text),
                        ),
                        Span::styled(note, t.style(Token::Muted)),
                    ]));
                }
            }
        }
    }
    if !m.picks.is_empty() {
        lines.push(Line::styled(
            format!(
                "   {} {} choice{} made here, not saved yet",
                t.g.warn,
                m.picks.len(),
                if m.picks.len() == 1 { "" } else { "s" }
            ),
            t.style(Token::Warn),
        ));
    }
    if let Some(c) = &m.save_check {
        let (g, tok, word) = match c.status.as_str() {
            "done" => (t.g.ok, Token::Ok, "Checked"),
            "refused" => (t.g.warn, Token::Warn, "Check the choices above"),
            _ => (t.g.fail, Token::Danger, "The check could not finish"),
        };
        lines.push(Line::styled(format!(" {g} {word}"), t.style(tok)));
        let mut said = |s: &str| {
            for l in wrap(&t.say(s), width.saturating_sub(4)) {
                lines.push(Line::styled(format!("   {l}"), t.style(Token::Text)));
            }
        };
        if !c.text.is_empty() {
            said(&c.text);
        }
        for (_, _, txt) in &c.invalid {
            said(txt);
        }
        for (_, txt) in &c.messages {
            said(txt);
        }
        // The core's warnings, each with its fix, before any question.
        for (_, txt, fix) in &c.warnings {
            said(&format!("{} {txt}", t.g.warn));
            if !fix.is_empty() {
                said(fix);
            }
        }
    }
    lines.push(Line::raw(""));
    lines.push(Line::from(vec![
        Span::styled(format!(" {}", t.g.bar), t.style(Token::Accent)),
        Span::styled("What you can do now", t.style(Token::Heading)),
    ]));
    let actions = review_actions(m);
    if actions.is_empty() {
        lines.push(Line::styled(
            "   The core lists no profile action now.",
            t.style(Token::Muted),
        ));
    }
    let mut anchors = Vec::new();
    for (i, a) in actions.iter().enumerate() {
        let here = i == m.rev && m.region == crate::app::Region::Work && m.focus_visible();
        anchors.push((i, lines.len(), lines.len() + 1));
        let name_w = width.saturating_sub(4);
        lines.push(Line::from(vec![
            Span::styled(
                format!(" {} ", if here { t.g.pointer } else { " " }),
                t.style(Token::Accent),
            ),
            Span::styled(
                format!("{:<name_w$}", fit(&t.say(&a.label), name_w, t.caps.unicode)),
                if here {
                    t.style(Token::Focus)
                } else {
                    t.style(Token::Text)
                },
            ),
        ]));
        for l in wrap(&t.say(&a.explain), width.saturating_sub(4))
            .into_iter()
            .filter(|l| !l.is_empty())
        {
            lines.push(Line::styled(format!("   {l}"), t.style(Token::Muted)));
        }
    }
    super::draw_lines(f, inner, lines, anchors, Some(m.rev), 0, m, t);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_mark_is_ascii_in_ascii() {
        let t = Theme::new(crate::theme::Caps {
            depth: crate::theme::Depth::None,
            unicode: false,
            console: false,
            truecolor: false,
        });
        for s in ["include", "exclude", "decide", "never"] {
            assert!(mark(s, &t).0.is_ascii());
        }
    }
}
