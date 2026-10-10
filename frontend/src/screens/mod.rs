//! The screens (docs/UX.md → *Screens*): one module per family, inside one
//! frame (docs/UX.md → *Layout*). Rendering reads the model and nothing else.

mod dashboard;
mod gate;
mod notes;
mod plan;
mod table;
mod welcome;

use crate::app::{Blocker, Level, Model, Region, Screen};
use crate::keys;
use crate::theme::{Theme, Token};
use crate::widgets::{self, BANNER_H, MIN_H, MIN_W, Tier, tier};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;

/// Draw the whole frame for the model: the title rule, the banner, the body
/// (the navigation rail, the workspace and the context sidebar, as the width
/// allows), the status line when there is something to say, and the footer.
pub fn draw(f: &mut Frame, m: &Model, t: &Theme, tick_ms: u32) {
    let area = f.area();
    if area.width < MIN_W || area.height < MIN_H {
        widgets::too_small(f, area, t);
        return;
    }
    widgets::backdrop(f, area, t);
    let tier = tier(area.width);
    let banner_h = if tier == Tier::Wide && area.height >= 36 && t.caps.unicode {
        BANNER_H
    } else if area.height >= 24 {
        1
    } else {
        0
    };
    let with_status = m.pending.is_some() || m.status.is_some();
    let [title, banner, navl, body, status, footer] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(banner_h),
        Constraint::Length(u16::from(tier == Tier::Narrow)),
        Constraint::Min(1),
        Constraint::Length(u16::from(with_status)),
        Constraint::Length(1),
    ])
    .areas(area);
    widgets::title_rule(f, title, m, t);
    if banner_h > 0 {
        widgets::banner(f, banner, t);
    }
    let (work, side) = match tier {
        // Welcome is the one page that already holds everything the sidebar
        // would: it takes the sidebar's columns too.
        Tier::Wide if matches!(m.screen, Screen::Welcome) => {
            let [nav, work] =
                Layout::horizontal([Constraint::Length(24), Constraint::Min(1)]).areas(body);
            widgets::nav_rail(f, nav, m, t, false);
            (work, None)
        }
        Tier::Wide => {
            let [nav, work, side] = Layout::horizontal([
                Constraint::Length(24),
                Constraint::Min(1),
                Constraint::Length(32),
            ])
            .areas(body);
            widgets::nav_rail(f, nav, m, t, false);
            (work, Some(side))
        }
        Tier::Standard => {
            let [nav, work] =
                Layout::horizontal([Constraint::Length(16), Constraint::Min(1)]).areas(body);
            widgets::nav_rail(f, nav, m, t, true);
            (work, None)
        }
        Tier::Narrow => {
            widgets::nav_line(f, navl, m, t);
            (body, None)
        }
    };
    if let Some(side) = side {
        sidebar(f, side, m, t);
    }
    if tier == Tier::Narrow && m.side && !matches!(m.screen, Screen::Gate | Screen::Help) {
        sidebar(f, work, m, t);
    } else {
        workspace(f, work, body, m, t, tier);
    }
    if with_status {
        widgets::status(f, status, m, t, tick_ms);
    }
    let place = if m.region == Region::Work && crate::app::value_open(m, m.screen) {
        keys::Place::Value
    } else {
        keys::place(m.screen, m.region, m.logs_tab)
    };
    widgets::footer(f, footer, m, place, t);
}

fn workspace(f: &mut Frame, work: Rect, body: Rect, m: &Model, t: &Theme, tier: Tier) {
    match m.screen {
        Screen::Connecting => notes::connecting(f, work, t),
        Screen::Welcome => welcome::draw(f, work, m, t),
        Screen::Dashboard => dashboard::draw(f, work, m, t, tier),
        Screen::Machine | Screen::Status | Screen::Health | Screen::Logs | Screen::Operation => {
            table::draw(f, work, m, t, tier)
        }
        Screen::Plan => plan::draw(f, work, m, t),
        Screen::Help => notes::help(f, work, m, t),
        Screen::Fatal => notes::fatal(f, work, m, t),
        Screen::Gate => {
            if tier == Tier::Wide {
                dashboard::draw(f, work, m, t, tier);
            }
            gate::draw(f, body, m, t);
        }
    }
}

/// The context sidebar: the machine's identity and what comes next — each
/// only where the workspace does not already say it (docs/UX.md → *Clutter
/// audit of this design*). The narrow view of its own (`s`) shows both.
fn sidebar(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let own_view = tier(f.area().width) == Tier::Narrow;
    // At wide widths the gate is drawn over the dashboard it came from.
    let shown = if m.screen == Screen::Gate {
        m.back
    } else {
        m.screen
    };
    let show = |s: &[Screen]| own_view || !s.contains(&shown);
    let width = area.width.saturating_sub(2) as usize;
    let mut rest = area;
    if show(&[Screen::Welcome, Screen::Machine]) {
        let machine = machine_lines(m, t, width);
        let h = (machine.len() as u16 + 2).min(area.height);
        let [top, below] =
            Layout::vertical([Constraint::Length(h), Constraint::Min(0)]).areas(area);
        let inner = widgets::panel(f, top, "This machine", t);
        f.render_widget(Paragraph::new(machine), inner);
        rest = below;
    }
    if rest.height >= 3 && show(&[Screen::Dashboard, Screen::Welcome]) {
        let inner = widgets::panel(f, rest, "Next", t);
        let mut lines = Vec::new();
        match m.snap.as_ref().map(|s| s.guides.as_slice()).unwrap_or(&[]) {
            [] => lines.push(Line::styled(
                " The core gave no next step.",
                t.style(Token::Muted),
            )),
            gs => {
                for g in gs {
                    for l in widgets::wrap(&t.say(g), width.saturating_sub(2)) {
                        lines.push(Line::styled(format!(" {l}"), t.style(Token::Text)));
                    }
                }
            }
        }
        let blocked = m.snap.as_ref().map_or(0, |s| s.blockers.len());
        if blocked > 0 {
            lines.push(Line::raw(""));
            lines.push(Line::from(vec![
                Span::styled(format!(" {} blocked", t.g.blocked), t.style(Token::Blocked)),
                Span::styled(
                    format!(" {blocked} on the Journey screen"),
                    t.style(Token::Muted),
                ),
            ]));
        }
        f.render_widget(Paragraph::new(lines), inner);
    }
}

/// The machine's identity: the journey snapshot's `machine.*` facts, as the
/// core labels them.
pub fn machine_lines<'a>(m: &Model, t: &Theme, width: usize) -> Vec<Line<'a>> {
    let facts: Vec<_> = m
        .snap
        .as_ref()
        .map(|s| {
            s.facts
                .iter()
                .filter(|f| f.key.starts_with("machine."))
                .collect()
        })
        .unwrap_or_default();
    if facts.is_empty() {
        return widgets::wrap(
            "This session's snapshot holds no machine facts.",
            width.saturating_sub(2),
        )
        .into_iter()
        .map(|l| Line::styled(format!(" {l}"), t.style(Token::Muted)))
        .collect();
    }
    let w = facts
        .iter()
        .map(|f| widgets::cells(&f.label))
        .max()
        .unwrap_or(0)
        .min(12);
    let mut out = Vec::new();
    for fact in facts {
        let value = widgets::fit(
            &t.say(&fact.value),
            width.saturating_sub(w + 3),
            t.caps.unicode,
        );
        out.push(Line::from(vec![
            Span::styled(
                format!(
                    " {:<w$}  ",
                    widgets::fit(&t.say(&fact.label), w, t.caps.unicode)
                ),
                t.style(Token::Muted),
            ),
            Span::styled(value, t.style(Token::Text)),
        ]));
    }
    out
}

/// One block of a free-form screen (Welcome, the Journey dashboard): what it
/// holds is decided from the model alone, so the count — and with it the
/// scroll's bound — does not depend on the terminal's size; how many lines
/// it takes does.
pub enum Item<'a> {
    Blank,
    Heading(&'static str),
    /// The traverse.
    Rail,
    /// Prose, wrapped, in a token.
    Text(String, Token),
    /// A label and its value; `recorded` adds the word.
    Pair {
        label: String,
        value: String,
        token: Token,
        state: &'a str,
        recorded: bool,
    },
    Blocker(&'a Blocker),
    Warning(&'a Blocker),
    Message(Level, &'a str),
    /// The journey snapshot's Nth action.
    Action(usize),
    Explain(&'a str),
    /// A level's glyph and its words: a verdict or a message the frontend
    /// composed from the core's records.
    Verdict(Level, String),
    /// A read's fault, in its own words.
    Fault(&'a crate::read::Fault),
    /// The plan check's Nth size field.
    Field(usize),
}

/// The number of blocks SCREEN holds: the scroll's bound.
pub fn blocks(m: &Model, s: Screen) -> usize {
    match s {
        Screen::Welcome => welcome::items(m).len(),
        Screen::Dashboard => dashboard::items(m).len(),
        Screen::Plan => plan::items(m).len(),
        _ => 0,
    }
}

fn label_width(items: &[Item]) -> usize {
    items
        .iter()
        .filter_map(|i| match i {
            Item::Pair { label, .. } => Some(widgets::cells(label)),
            _ => None,
        })
        .max()
        .unwrap_or(0)
        .min(18)
}

/// The widths a list of blocks aligns to: labels, and action names.
struct Widths {
    label: usize,
    action: usize,
}

fn item_lines<'a>(item: &Item, m: &Model, t: &Theme, width: usize, w: &Widths) -> Vec<Line<'a>> {
    let lw = w.label;
    let prose = width.saturating_sub(6).max(12);
    match item {
        Item::Blank => vec![Line::raw("")],
        Item::Heading(h) => vec![Line::from(vec![
            Span::styled(format!(" {}", t.g.bar), t.style(Token::Accent)),
            Span::styled(*h, t.style(Token::Heading)),
        ])],
        Item::Rail => widgets::traverse(m, t, width.saturating_sub(1)),
        Item::Text(s, tok) => widgets::wrap(&t.say(s), prose)
            .into_iter()
            .map(|l| Line::styled(format!("   {l}"), t.style(*tok)))
            .collect(),
        Item::Pair {
            label,
            value,
            token,
            state,
            recorded,
        } => {
            let (style, glyph) = widgets::style_of(t, state);
            let mut v = String::new();
            if !matches!(*state, "info" | "") {
                v.push_str(glyph);
                v.push(' ');
            }
            v.push_str(&t.say(value));
            if *recorded {
                v.push_str(&format!(" {} recorded", t.g.dot));
            }
            let value_style = if matches!(*state, "info" | "") {
                t.style(*token)
            } else {
                style
            };
            widgets::pair(t, &t.say(label), &v, lw, width, value_style)
        }
        Item::Blocker(b) => {
            let mut out = Vec::new();
            for (i, l) in widgets::wrap(&t.say(&b.text), prose.saturating_sub(10))
                .into_iter()
                .enumerate()
            {
                let head = if i == 0 {
                    Span::styled(
                        format!("   {} blocked ", t.g.blocked),
                        t.style(Token::Blocked),
                    )
                } else {
                    Span::raw(" ".repeat(13))
                };
                out.push(Line::from(vec![
                    head,
                    Span::raw(" "),
                    Span::styled(l, t.style(Token::Text)),
                ]));
            }
            for l in widgets::wrap(&t.say(&b.fix), prose.saturating_sub(10)) {
                out.push(Line::from(vec![
                    Span::raw(" ".repeat(14)),
                    Span::styled(l, t.style(Token::Warn)),
                ]));
            }
            out
        }
        Item::Warning(b) => {
            let mut out = Vec::new();
            for (i, l) in widgets::wrap(&t.say(&b.text), prose.saturating_sub(2))
                .into_iter()
                .enumerate()
            {
                let g = if i == 0 { t.g.warn } else { " " };
                out.push(Line::from(vec![
                    Span::styled(format!("   {g} "), t.style(Token::Warn)),
                    Span::styled(l, t.style(Token::Text)),
                ]));
            }
            for l in widgets::wrap(&t.say(&b.fix), prose.saturating_sub(2)) {
                out.push(Line::styled(format!("     {l}"), t.style(Token::Muted)));
            }
            out
        }
        Item::Message(l, s) => widgets::wrap(&t.say(s), prose.saturating_sub(2))
            .into_iter()
            .enumerate()
            .map(|(i, line)| {
                let g = if i == 0 {
                    widgets::level_glyph(*l, t)
                } else {
                    " "
                };
                Line::from(vec![
                    Span::styled(format!("   {g} "), t.style(widgets::level_token(*l))),
                    Span::styled(line, t.style(Token::Text)),
                ])
            })
            .collect(),
        Item::Action(i) => {
            let Some(a) = m.snap.as_ref().and_then(|s| s.actions.get(*i)) else {
                return Vec::new();
            };
            let focused = *i == m.focus && m.region == crate::app::Region::Work;
            let pointer = if focused { t.g.pointer } else { " " };
            let mut badge = a.intent.clone();
            if a.handoff {
                badge.push_str(&format!(" {} handoff", t.g.dot));
            }
            if !a.gate.is_empty() && width >= 60 {
                badge.push_str(&format!(" {} type {}", t.g.dot, a.gate));
            }
            let name_w = w
                .action
                .min(width.saturating_sub(widgets::cells(&badge) + 8))
                .max(8);
            let name = format!(
                "{:<name_w$}",
                widgets::fit(&t.say(&a.label), name_w, t.caps.unicode)
            );
            let name_style = if focused {
                t.style(Token::Focus)
            } else {
                t.style(Token::Text)
            };
            vec![Line::from(vec![
                Span::styled(format!(" {pointer} "), t.style(Token::Accent)),
                Span::styled(name, name_style),
                Span::raw("   "),
                Span::styled(badge, t.style(Token::Muted)),
            ])]
        }
        Item::Explain(s) => widgets::wrap(&t.say(s), prose)
            .into_iter()
            .map(|l| Line::styled(format!("   {l}"), t.style(Token::Muted)))
            .collect(),
        Item::Verdict(l, s) => widgets::wrap(&t.say(s), prose.saturating_sub(2))
            .into_iter()
            .enumerate()
            .map(|(i, line)| {
                let g = if i == 0 {
                    widgets::level_glyph(*l, t)
                } else {
                    " "
                };
                Line::from(vec![
                    Span::styled(format!(" {g} "), t.style(widgets::level_token(*l))),
                    Span::styled(line, t.style(widgets::level_token(*l))),
                ])
            })
            .collect(),
        Item::Fault(f) => table::fault_lines(f, t, width),
        Item::Field(i) => {
            let p = &m.plan;
            let (label, value) = if *i == 0 {
                ("Linux size", &p.linux)
            } else {
                ("Shared size", &p.shared)
            };
            let here = m.region == crate::app::Region::Work && p.field == *i;
            let pointer = if here { t.g.pointer } else { " " };
            let mut spans = vec![
                Span::styled(format!(" {pointer} "), t.style(Token::Accent)),
                Span::styled(format!("{label:<12} "), t.style(Token::Muted)),
            ];
            if value.is_empty() && !here {
                spans.push(Span::styled("not given", t.style(Token::Pending)));
            } else {
                spans.push(Span::styled(
                    widgets::fit(value, width.saturating_sub(20), t.caps.unicode),
                    if here {
                        t.style(Token::Gate)
                    } else {
                        t.style(Token::Text)
                    },
                ));
            }
            if here {
                spans.push(Span::styled(
                    if t.caps.unicode { "▏" } else { "_" },
                    t.style(Token::Gate),
                ));
            }
            vec![Line::from(spans)]
        }
    }
}

/// Draw ITEMS into AREA from the block SCROLL, moved so that the block FOCUS
/// (if any) is on the screen. Only the blocks that reach the screen are laid
/// out: a long list costs what is visible.
pub fn draw_items(
    f: &mut Frame,
    area: Rect,
    items: &[Item],
    scroll: usize,
    focus: Option<usize>,
    m: &Model,
    t: &Theme,
) {
    let width = area.width as usize;
    let height = area.height as usize;
    let w = Widths {
        label: label_width(items),
        action: m
            .snap
            .as_ref()
            .and_then(|s| s.actions.iter().map(|a| a.label.chars().count()).max())
            .unwrap_or(0)
            .min(34),
    };
    let mut start = scroll.min(items.len().saturating_sub(1));
    if let Some(fi) = focus {
        if fi < start {
            start = fi;
        } else {
            // Move down until the focused block ends inside the area.
            loop {
                let used: usize = items[start..=fi]
                    .iter()
                    .map(|i| item_lines(i, m, t, width, &w).len())
                    .sum();
                if used <= height || start == fi {
                    break;
                }
                start += 1;
            }
        }
    }
    let mut lines: Vec<Line> = Vec::new();
    let mut end = start.min(items.len());
    while end < items.len() && lines.len() < height {
        lines.extend(item_lines(&items[end], m, t, width, &w));
        end += 1;
    }
    let more_above = start > 0;
    let more_below = lines.len() > height || end < items.len();
    lines.truncate(height);
    f.render_widget(Paragraph::new(lines), area);
    // A quiet mark on the panel's edge says there is more.
    let at = |y: u16| Rect {
        x: area.x + area.width.saturating_sub(1),
        y,
        width: 1,
        height: 1,
    };
    if more_above && area.height > 0 {
        let g = if t.caps.unicode { "↑" } else { "^" };
        widgets::line(at(area.y), f, Line::styled(g, t.style(Token::Muted)));
    }
    if more_below && area.height > 0 {
        let g = if t.caps.unicode { "↓" } else { "v" };
        widgets::line(
            at(area.y + area.height - 1),
            f,
            Line::styled(g, t.style(Token::Muted)),
        );
    }
}
