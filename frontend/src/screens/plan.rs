//! The plan check: a read-only presentation of `validate select
//! action=plan.save` (docs/PROTOCOL.md → *Future plan validation contract*).
//! It collects two sizes as typed and shows the core's answer as it came —
//! the sizes as the core normalised them, the installer's questions and what
//! to type, warnings, refusals and the review basis. It never computes,
//! normalises or judges a size, saves nothing and offers no action: the
//! Storage Planner and the Safety Gate belong to the gate that exposes them.

use super::{Item, draw_items};
use crate::app::{Level, Model};
use crate::theme::{Theme, Token};
use crate::widgets;
use ratatui::Frame;
use ratatui::layout::Rect;

/// What a parameter is called on the screen.
fn name(p: &str) -> &str {
    match p {
        "linux_size" => "Linux size",
        "shared_size" => "Shared size",
        p => p,
    }
}

fn level(l: &str) -> Level {
    match l {
        "warn" => Level::Warn,
        "fail" => Level::Fail,
        "ok" => Level::Ok,
        _ => Level::Info,
    }
}

fn text(s: impl Into<String>, tok: Token) -> Item<'static> {
    Item::Text(s.into(), tok)
}

fn pair(label: &str, value: String, token: Token) -> Item<'static> {
    Item::Pair {
        label: label.into(),
        value,
        token,
        state: "info",
        recorded: false,
    }
}

pub fn items(m: &Model) -> Vec<Item<'_>> {
    if m.check {
        return vec![text(
            "The startup check answers hello and the journey snapshot only, so no plan is checked in this session.",
            Token::Muted,
        )];
    }
    let mut v = vec![
        text(
            "The core checks two sizes against this Mac's disk and answers what the installer would be told. Nothing is saved, and no action is offered.",
            Token::Muted,
        ),
        Item::Blank,
        Item::Field(0),
        Item::Field(1),
        text(
            "as 250GB, 1.5TB or 30%; a size left empty is not sent",
            Token::Muted,
        ),
        Item::Blank,
    ];
    if let Some(f) = &m.plan.fault {
        v.push(Item::Fault(f));
        return v;
    }
    let Some(c) = &m.plan.checked else {
        if !m.reading(|r| matches!(r, crate::app::Req::Validate { .. })) {
            v.push(text("Type the sizes, then ⏎ to check them.", Token::Muted));
        }
        return v;
    };
    if c.linux != m.plan.linux || c.shared != m.plan.shared {
        v.push(Item::Verdict(
            Level::Warn,
            "the sizes above changed since this answer; ⏎ checks them".into(),
        ));
    }
    let sent = |s: &str| {
        if s.is_empty() {
            "not sent".to_string()
        } else {
            s.to_string()
        }
    };
    v.push(text(
        format!("For Linux {} · Shared {}", sent(&c.linux), sent(&c.shared)),
        Token::Muted,
    ));
    v.push(match (c.status.as_str(), c.code.as_str()) {
        ("done", _) => Item::Verdict(Level::Ok, "checked".into()),
        ("refused", code) => Item::Verdict(Level::Warn, format!("refused · {code}")),
        (status, code) => Item::Verdict(Level::Fail, format!("{status} · {code}")),
    });
    if !c.text.is_empty() {
        v.push(text(c.text.clone(), Token::Text));
    }
    for (p, code, t) in &c.invalid {
        v.push(Item::Verdict(Level::Fail, format!("{} {code}", name(p))));
        v.push(text(t.clone(), Token::Text));
    }
    for (l, t) in &c.messages {
        v.push(Item::Verdict(level(l), t.clone()));
    }
    for (_, t, fix) in &c.warnings {
        v.push(Item::Verdict(Level::Warn, t.clone()));
        if !fix.is_empty() {
            v.push(text(fix.clone(), Token::Muted));
        }
    }
    if !c.answers.is_empty() {
        v.push(Item::Blank);
        v.push(Item::Heading("The installer asks"));
        for (prompt, value, _) in &c.answers {
            v.push(pair(prompt, format!("you type {value}"), Token::Accent));
        }
    }
    if !c.normals.is_empty() {
        v.push(Item::Blank);
        v.push(Item::Heading("Sizes as the core reads them"));
        for (p, value) in &c.normals {
            v.push(pair(name(p), format!("{value} bytes"), Token::Text));
        }
    }
    if let Some(basis) = &c.basis {
        v.push(Item::Blank);
        v.push(Item::Heading("Review basis"));
        v.push(text(basis.clone(), Token::Text));
        v.push(text(
            "a basis for review only: nothing was saved, and no action is offered",
            Token::Muted,
        ));
    }
    v
}

pub fn draw(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let reading = m.reading(|r| matches!(r, crate::app::Req::Validate { .. }));
    let title = if reading {
        format!("Plan check {} checking", t.g.dot)
    } else {
        "Plan check".to_string()
    };
    let inner = widgets::panel(f, area, &title, t);
    draw_items(f, inner, &items(m), m.plan_scroll, None, m, t);
}
