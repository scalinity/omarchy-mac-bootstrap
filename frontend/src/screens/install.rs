//! Screens 14, 15, 18 and 19 (docs/UX.md → *Every screen*): the journey
//! snapshot's pages for the actions that hand this terminal over — the Asahi
//! handoff (macOS), the Linux continuation and Omarchy Mac's progress
//! (Linux), and Shared creation. A stepper names a page's sections and marks
//! the one in view; it never shows a step as done, which only the core could
//! know. Each check list is the core's own facts with their states — a gate's
//! `gate.<action>.*`, the plan's `recorded.*`, Omarchy Mac's `omarchy.*` —
//! and the installer's answers, the guide and the token are the snapshot's
//! records. No installer percentage, time or log is shown: the installers run
//! on this terminal, which the interface hands over.

use super::{Item, draw_items};
use crate::app::{Model, Screen};
use crate::theme::{Theme, Token};
use crate::widgets;
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::widgets::Paragraph;

/// The Asahi handoff's sections.
pub const ASAHI: [&str; 4] = ["Check", "Answers", "Boot", "Token"];
/// The Linux continuation's sections, which Omarchy Mac's progress follows.
pub const LINUX: [&str; 4] = ["Token", "Network", "Omarchy Mac", "Start"];

/// The actions the Linux continuation starts with its gate, in order.
const STARTS: [&str; 2] = ["omarchy.start", "omarchy.resume"];

fn text(s: impl Into<String>, tok: Token) -> Item<'static> {
    Item::Text(s.into(), tok)
}

/// The session's system, as `hello` says; none before `hello`.
fn platform(m: &Model) -> Option<&str> {
    m.hello.as_ref().map(|h| h.platform.as_str())
}

fn macos(m: &Model) -> bool {
    platform(m) == Some("macos")
}

/// The console Omarchy Mac's setup writes to, as the core names it.
const CONSOLE: &str = "omarchy.console";

/// The sentence of the core's console fact; nothing without it.
fn console(snap: &crate::app::Snapshot) -> Option<Item<'static>> {
    let f = snap.facts.iter().find(|f| f.key == CONSOLE)?;
    Some(text(
        format!("Omarchy Mac's setup writes to {}.", f.value),
        Token::Text,
    ))
}

/// The page's title and its stepper's sections (none for Shared creation,
/// nor for an Install page before `hello` names the system).
fn page(m: &Model, s: Screen) -> (&'static str, &'static [&'static str]) {
    match s {
        Screen::Install if macos(m) => ("Asahi handoff", &ASAHI),
        Screen::Install if platform(m) == Some("linux") => ("Linux continuation", &LINUX),
        Screen::Install => ("Install", &[]),
        Screen::Progress => ("Omarchy progress", &LINUX),
        _ => ("Shared creation", &[]),
    }
}

/// What a page says of action ID: its explanation and gate facts when the
/// core lists it, and that it does not when it does not.
fn action_items<'a>(m: &'a Model, id: &str, v: &mut Vec<(usize, Item<'a>)>, sec: usize) {
    let Some(s) = m.snap.as_ref() else { return };
    match s.action(id) {
        Some(a) => {
            if !a.explain.is_empty() {
                v.push((sec, Item::Explain(&a.explain)));
            }
            v.extend(s.gate_facts(id).into_iter().map(|f| (sec, Item::Check(f))));
        }
        None => v.push((
            sec,
            text(
                format!("The core does not offer {} now.", named(id)),
                Token::Muted,
            ),
        )),
    }
}

/// An action the page may find unlisted, in the words a person uses.
fn named(id: &str) -> &str {
    match id {
        "asahi.launch" => "the Asahi installer",
        "network.connect" => "the network step",
        "shared.create" => "Shared creation",
        id => id,
    }
}

/// The words under a page's offered action: what Enter does, and that the
/// terminal is handed over.
fn go_items<'a>(m: &Model, ids: &[&str], key: &str, v: &mut Vec<(usize, Item<'a>)>, sec: usize) {
    let Some(a) = ids.iter().find_map(|id| m.snap.as_ref()?.action(id)) else {
        return;
    };
    let word = if a.gate.is_empty() {
        format!("{key} runs {}", a.label)
    } else {
        format!("{key} opens the gate: type {} to run {}", a.gate, a.label)
    };
    let terminal = if a.handoff {
        "; this terminal is the program's until it exits."
    } else {
        "."
    };
    v.push((sec, text(format!("{word}{terminal}"), Token::Accent)));
}

/// The page's blocks, each with the section it belongs to.
pub fn sections(m: &Model, s: Screen) -> Vec<(usize, Item<'_>)> {
    let mut v: Vec<(usize, Item)> = Vec::new();
    let Some(snap) = m.snap.as_ref() else {
        v.push((0, text("No snapshot has been read yet.", Token::Muted)));
        return v;
    };
    fn blockers<'a>(snap: &'a crate::app::Snapshot, v: &mut Vec<(usize, Item<'a>)>, sec: usize) {
        v.extend(snap.blockers.iter().map(|b| (sec, Item::Blocker(b))));
    }
    match s {
        Screen::Install if macos(m) => {
            v.push((0, Item::Heading("Before the installer")));
            action_items(m, "asahi.launch", &mut v, 0);
            if snap.action("asahi.launch").is_none() {
                blockers(snap, &mut v, 0);
            }
            v.push((1, Item::Blank));
            v.push((1, Item::Heading("What the installer asks")));
            if snap.answers.is_empty() {
                v.push((
                    1,
                    text("This snapshot holds no installer answers.", Token::Muted),
                ));
            }
            for (prompt, value) in &snap.answers {
                v.push((
                    1,
                    Item::Pair {
                        label: prompt.clone(),
                        value: format!("you type {value}"),
                        token: Token::Accent,
                        state: "info",
                        recorded: false,
                    },
                ));
            }
            v.push((2, Item::Blank));
            v.push((2, Item::Heading("After the installer")));
            // The boot guide: the core's guides other than its next step,
            // which the sidebar shows.
            let boot: Vec<_> = snap
                .guides
                .iter()
                .zip(&snap.guide_ids)
                .filter(|(_, id)| *id != "next")
                .map(|(g, _)| g)
                .collect();
            if boot.is_empty() {
                v.push((
                    2,
                    text(
                        "The core gave no boot guide in this snapshot.",
                        Token::Muted,
                    ),
                ));
            }
            v.extend(boot.into_iter().map(|g| (2, text(g.clone(), Token::Text))));
            v.push((3, Item::Blank));
            v.push((3, Item::Heading("Resume token")));
            tokens(snap, &mut v, 3);
            v.push((3, Item::Blank));
            go_items(m, &["asahi.launch"], "⏎", &mut v, 3);
        }
        Screen::Install if platform(m) == Some("linux") => {
            v.push((0, Item::Heading("The plan this system was given")));
            if snap.codes.iter().any(|(k, _)| k == "token") {
                tokens(snap, &mut v, 0);
            }
            let recorded: Vec<_> = snap
                .facts
                .iter()
                .filter(|f| f.key.starts_with("recorded."))
                .collect();
            if recorded.is_empty() {
                v.push((
                    0,
                    text("This snapshot holds no recorded facts.", Token::Muted),
                ));
            }
            v.extend(recorded.into_iter().map(|f| {
                (
                    0,
                    Item::Pair {
                        label: f.label.clone(),
                        value: f.value.clone(),
                        token: Token::Text,
                        state: &f.state,
                        recorded: true,
                    },
                )
            }));
            v.push((1, Item::Blank));
            v.push((1, Item::Heading("Network")));
            action_items(m, "network.connect", &mut v, 1);
            go_items(m, &["network.connect"], "n", &mut v, 1);
            v.push((2, Item::Blank));
            v.push((2, Item::Heading("Omarchy Mac")));
            for id in STARTS {
                if snap.action(id).is_some() {
                    action_items(m, id, &mut v, 2);
                }
            }
            if STARTS.iter().all(|id| snap.action(id).is_none()) {
                v.push((
                    2,
                    text(
                        "The core does not offer Omarchy Mac's start now.",
                        Token::Muted,
                    ),
                ));
                blockers(snap, &mut v, 2);
            }
            v.push((3, Item::Blank));
            v.push((3, Item::Heading("Start")));
            go_items(m, &STARTS, "⏎", &mut v, 3);
            if STARTS.iter().all(|id| snap.action(id).is_none()) {
                v.push((3, text("Nothing to start here now.", Token::Muted)));
            }
            if let Some(c) = console(snap) {
                v.push((3, c));
            }
        }
        Screen::Install => {
            v.push((
                0,
                text(
                    "The core has not said which system this is, so this page shows nothing to run.",
                    Token::Muted,
                ),
            ));
        }
        Screen::Progress => {
            v.push((3, Item::Heading("Omarchy Mac's setup")));
            if let Some(c) = console(snap) {
                v.push((3, c));
            }
            v.push((
                3,
                text(
                    "This page shows what the core read; r reads it again.",
                    Token::Muted,
                ),
            ));
            let signals: Vec<_> = snap
                .facts
                .iter()
                .filter(|f| f.key.starts_with("omarchy.") && f.key != CONSOLE)
                .collect();
            if signals.is_empty() {
                v.push((
                    3,
                    text(
                        "The core reported no Omarchy Mac signals in this snapshot.",
                        Token::Muted,
                    ),
                ));
            }
            v.extend(signals.into_iter().map(|f| (3, Item::Check(f))));
            v.extend(snap.messages.iter().map(|(l, t)| (3, Item::Message(*l, t))));
        }
        _ => {
            v.push((0, Item::Heading("The disk")));
            if snap.regions.is_empty() {
                v.push((0, text("This snapshot holds no disk layout.", Token::Muted)));
            } else {
                v.push((0, Item::Strip(&snap.regions)));
            }
            v.push((0, Item::Blank));
            v.push((0, Item::Heading("Before Shared is created")));
            action_items(m, "shared.create", &mut v, 0);
            if snap.action("shared.create").is_none() {
                blockers(snap, &mut v, 0);
            }
            v.push((0, Item::Blank));
            go_items(m, &["shared.create"], "⏎", &mut v, 0);
        }
    }
    v
}

fn tokens<'a>(snap: &'a crate::app::Snapshot, v: &mut Vec<(usize, Item<'a>)>, sec: usize) {
    let mut any = false;
    for (kind, value) in snap.codes.iter().filter(|(k, _)| k == "token") {
        any = true;
        v.push((
            sec,
            Item::Pair {
                label: if kind == "token" {
                    "Resume token".into()
                } else {
                    kind.clone()
                },
                value: crate::theme::verbatim(value),
                token: Token::Text,
                state: "info",
                recorded: false,
            },
        ));
    }
    if !any {
        v.push((
            sec,
            text("This snapshot holds no resume token.", Token::Muted),
        ));
    }
}

pub fn items(m: &Model, s: Screen) -> Vec<Item<'_>> {
    sections(m, s).into_iter().map(|(_, i)| i).collect()
}

pub fn draw(f: &mut Frame, area: Rect, m: &Model, t: &Theme, s: Screen) {
    let (title, steps) = page(m, s);
    let reading = m.reading(|r| matches!(r, crate::app::Req::Snapshot(_)));
    let title = if reading {
        format!("{title} {} reading", t.g.dot)
    } else {
        title.to_string()
    };
    let inner = widgets::panel(f, area, &title, t);
    let all = sections(m, s);
    let scroll = m.page_scroll.min(all.len().saturating_sub(1));
    // The section in view is the one the first block shown belongs to; the
    // progress page follows the continuation and marks none of its steps.
    let at = match s {
        Screen::Progress => usize::MAX,
        _ => all.get(scroll).map_or(0, |(sec, _)| *sec),
    };
    let lines = if steps.is_empty() {
        Vec::new()
    } else {
        widgets::stepper(steps, at, t, inner.width as usize)
    };
    let [top, body] = Layout::vertical([
        Constraint::Length(lines.len() as u16 + u16::from(!lines.is_empty())),
        Constraint::Min(0),
    ])
    .areas(inner);
    f.render_widget(Paragraph::new(lines), top);
    let items: Vec<Item> = all.into_iter().map(|(_, i)| i).collect();
    draw_items(f, body, &items, scroll, None, m, t);
}
