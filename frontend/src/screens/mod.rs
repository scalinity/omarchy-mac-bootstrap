//! The screens (docs/UX.md → *Screens*): one module per family, inside one
//! frame (docs/UX.md → *Layout*). Rendering reads the model and nothing else.

mod brief;
mod dashboard;
mod gate;
mod health;
mod install;
mod journey;
mod migrate;
mod notes;
pub mod plan;
mod restore;
mod table;
mod welcome;

use crate::app::{Blocker, Fact, Level, Model, Region, Screen};
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
        Tier::Wide
            if matches!(
                m.screen,
                Screen::Welcome | Screen::Conflicts | Screen::Brief
            ) =>
        {
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
        workspace(f, work, body, m, t, tier, m.screen);
    }
    if with_status {
        widgets::status(f, status, m, t, tick_ms);
    }
    let place = if m.region == Region::Work && crate::app::value_open(m, m.screen) {
        keys::Place::Value
    } else if m.region == Region::Work && m.screen == Screen::Inventory && m.inv.open {
        keys::Place::Item
    } else {
        keys::place(m.screen, m.region, m.logs_tab)
    };
    widgets::footer(f, footer, m, place, t);
}

fn workspace(
    f: &mut Frame,
    work: Rect,
    body: Rect,
    m: &Model,
    t: &Theme,
    tier: Tier,
    screen: Screen,
) {
    match screen {
        Screen::Connecting => notes::connecting(f, work, t),
        Screen::Welcome => welcome::draw(f, work, m, t),
        Screen::Dashboard => dashboard::draw(f, work, m, t, tier),
        Screen::Inventory => migrate::inventory(f, work, m, t),
        Screen::Review => migrate::review(f, work, m, t),
        Screen::Scan => migrate::scan(f, work, m, t),
        Screen::Selection => migrate::selection(f, work, m, t),
        Screen::Restore => restore::draw(f, work, m, t),
        Screen::Conflicts => restore::conflicts(f, work, m, t),
        Screen::Brief => brief::draw(f, work, m, t),
        Screen::Qualification | Screen::Completion => journey::draw(f, work, m, t),
        Screen::Health
            if health::enriched(m)
                && !m
                    .detail(crate::read::Kind::Doctor)
                    .is_some_and(|d| d.open || d.editing) =>
        {
            health::draw(f, work, m, t)
        }
        Screen::Machine | Screen::Status | Screen::Health | Screen::Logs | Screen::Operation => {
            table::draw(f, work, m, t, tier)
        }
        Screen::Plan | Screen::Form => plan::draw(f, work, m, t, screen),
        Screen::Install | Screen::Progress | Screen::Shared => install::draw(f, work, m, t, screen),
        Screen::Help => notes::help(f, work, m, t),
        Screen::Fatal => notes::fatal(f, work, m, t),
        Screen::Gate => {
            // At wide sizes the gate is drawn over the screen it came from.
            if tier == Tier::Wide && m.back != Screen::Gate {
                workspace(f, work, body, m, t, tier, m.back);
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
        let inner = widgets::panel(f, top, "System Overview", t);
        f.render_widget(Paragraph::new(machine), inner);
        rest = below;
    }
    if rest.height >= 3 && show(&[Screen::Dashboard, Screen::Welcome]) {
        let inner = widgets::panel(f, rest, "Next steps", t);
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
            &t.say(&widgets::fact_value(&fact.key, &fact.label, &fact.value)),
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
    Row(usize, String, Token),
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
    /// The Nth field of the form shown.
    Field(usize),
    /// A check-list line: the core's fact, its state's glyph first.
    Check(&'a Fact),
    /// The disk strip over the core's regions.
    Strip(&'a [crate::read::DiskRegion]),
}

/// The number of blocks SCREEN holds: the scroll's bound.
pub fn blocks(m: &Model, s: Screen) -> usize {
    match s {
        Screen::Welcome => welcome::items(m).len(),
        Screen::Dashboard => dashboard::items(m).len(),
        Screen::Plan | Screen::Form => plan::items(m, s).len(),
        Screen::Install | Screen::Progress | Screen::Shared => install::items(m, s).len(),
        Screen::Scan => migrate::scan_items(m).len(),
        Screen::Restore => restore::items(m).len(),
        Screen::Conflicts => restore::conflict_items(m).len(),
        Screen::Brief => brief::items(m).len(),
        Screen::Qualification | Screen::Completion => journey::items(m).len(),
        _ => 0,
    }
}

fn label_width(items: &[Item]) -> usize {
    items
        .iter()
        .filter_map(|i| match i {
            Item::Pair { label, .. } => Some(widgets::cells(label)),
            Item::Check(f) => Some(widgets::cells(&f.label)),
            _ => None,
        })
        .max()
        .unwrap_or(0)
        .min(18)
}

/// The widths a list of blocks aligns to: labels, and action names.
struct Widths {
    label: usize,
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
        Item::Text(s, tok) | Item::Row(_, s, tok) => widgets::wrap(&t.say(s), prose)
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
                v.push_str(" (saved record)");
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
            let focused =
                *i == m.focus && m.focus_visible() && m.region == crate::app::Region::Work;
            let pointer = if focused { t.g.pointer } else { " " };
            let mut lines = vec![Line::from(vec![
                Span::styled(format!(" {pointer} "), t.style(Token::Accent)),
                Span::styled(
                    widgets::fit(&t.say(&a.label), width.saturating_sub(4), t.caps.unicode),
                    t.style(if focused { Token::Focus } else { Token::Text }),
                ),
            ])];
            lines.extend(
                widgets::wrap(&t.say(&a.explain), prose)
                    .into_iter()
                    .filter(|l| !l.is_empty())
                    .map(|l| Line::styled(format!("   {l}"), t.style(Token::Muted))),
            );
            lines
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
        Item::Field(i) => plan::field_lines(m, t, width, *i),
        Item::Check(fact) => {
            let (style, glyph) = widgets::style_of(t, &fact.state);
            let lw = w.label.max(8);
            let room = width.saturating_sub(lw + 8).max(8);
            let mut out = Vec::new();
            for (i, l) in widgets::wrap(&t.say(&fact.value), room)
                .into_iter()
                .enumerate()
            {
                let (g, label) = if i == 0 {
                    (glyph, widgets::fit(&t.say(&fact.label), lw, t.caps.unicode))
                } else {
                    (" ", String::new())
                };
                out.push(Line::from(vec![
                    Span::styled(format!("   {g} "), style),
                    Span::styled(format!("{label:<lw$}  "), t.style(Token::Muted)),
                    Span::styled(l, t.style(Token::Text)),
                ]));
            }
            out
        }
        Item::Strip(regions) => widgets::strip(regions, t, width),
    }
}

/// Draw ITEMS into AREA from the block SCROLL, moved so that the block FOCUS
/// (if any) is on the screen. Wrapped lines share the panel's scroll bounds.
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
    let w = Widths {
        label: label_width(items),
    };
    let mut lines = Vec::new();
    let mut rows = Vec::new();
    let mut initial = 0;
    for (i, item) in items.iter().enumerate() {
        if i == scroll {
            initial = lines.len();
        }
        let id = match item {
            Item::Action(id) | Item::Field(id) | Item::Row(id, _, _) => Some(*id),
            _ => (Some(i) == focus).then_some(i),
        };
        let block = item_lines(item, m, t, width, &w);
        if let Some(id) = id {
            rows.push((id, lines.len(), lines.len() + block.len()));
        }
        lines.extend(block);
    }
    let cursor = focus.map(|i| match items.get(i) {
        Some(Item::Action(id) | Item::Field(id) | Item::Row(id, _, _)) => *id,
        _ => i,
    });
    draw_lines(f, area, lines, rows, cursor, initial, m, t);
}

/// A window over laid-out lines, shared by prose, forms and tables.
#[allow(clippy::too_many_arguments)]
pub fn draw_lines(
    f: &mut Frame,
    area: Rect,
    lines: Vec<Line<'_>>,
    rows: Vec<(usize, usize, usize)>,
    cursor: Option<usize>,
    initial: usize,
    m: &Model,
    t: &Theme,
) {
    let total = lines.len();
    let height = area.height as usize;
    let top = m
        .viewport
        .borrow_mut()
        .layout(m.screen, height, total, rows, cursor, initial);
    f.render_widget(
        Paragraph::new(lines.into_iter().skip(top).take(height).collect::<Vec<_>>()),
        area,
    );
    if area.width == 0 || area.height == 0 {
        return;
    }
    let at = |y| Rect {
        x: area.right() - 1,
        y,
        width: 1,
        height: 1,
    };
    if top > 0 {
        widgets::line(
            at(area.y),
            f,
            Line::styled(
                if t.caps.unicode { "↑" } else { "^" },
                t.style(Token::Muted),
            ),
        );
    }
    if top + height < total {
        widgets::line(
            at(area.bottom() - 1),
            f,
            Line::styled(
                if t.caps.unicode { "↓" } else { "v" },
                t.style(Token::Muted),
            ),
        );
    }
}
