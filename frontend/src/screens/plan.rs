//! Screen 12, the storage planner, and the parameter form of any other
//! action (docs/UX.md → *Every screen*; docs/PROTOCOL.md → *plan.save*).
//! The fields are the parameters the core declares for the action, as typed
//! or chosen; an empty one is not sent, and the core answers it with its
//! default. The core's answer is shown as it came — the layout on the disk
//! strip, the installer's questions and what to type, each value as the core
//! normalised it, warnings, refusals and the review's basis. The frontend
//! computes, normalises and judges nothing: a review it holds for exactly what
//! is typed, of an action the core lists, is what Enter sends on, with the
//! normalised values and that basis. Where the core lists no `plan.save`,
//! this is the plan check of the two sizes, which saves nothing.

use super::{Item, draw_items};
use crate::app::{Form, Level, Model, Screen};
use crate::read::Scope;
use crate::theme::{Theme, Token};
use crate::widgets;
use ratatui::Frame;
use ratatui::layout::Rect;

/// What a parameter is called on the screen: the eleven inputs of
/// `plan.save` by their meaning, any other by its name.
pub fn field_label(p: &str) -> String {
    match p {
        "linux_size" => "Linux size",
        "shared_size" => "Shared size",
        "enc" => "Encryption",
        "user" => "Username",
        "host" => "Hostname",
        "kmap" => "Keymap",
        "tz" => "Timezone",
        "loc" => "Locale",
        "ssh" => "SSH keys",
        "gh" => "GitHub user",
        "dev" => "Developer setup",
        p => p,
    }
    .to_string()
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

fn form(m: &Model, s: Screen) -> &Form {
    if s == Screen::Form { &m.form } else { &m.plan }
}

pub fn items(m: &Model, s: Screen) -> Vec<Item<'_>> {
    if m.check {
        return vec![text(
            "The startup check answers hello and the journey snapshot only, so no plan is checked in this session.",
            Token::Muted,
        )];
    }
    let f = form(m, s);
    let offered = m.offered(f.scope, &f.action);
    let plan = s == Screen::Plan;
    let mut v = Vec::new();
    match (&offered, plan) {
        (Some(a), _) if !a.explain.is_empty() => v.push(text(a.explain.clone(), Token::Muted)),
        (Some(_), true) => v.push(text(
            "The core checks what you give against this Mac's disk and answers what the installer will be told; Enter on a review it answered saves the plan.",
            Token::Muted,
        )),
        (None, true) => v.push(text(
            "The core checks two sizes against this Mac's disk and answers what the installer would be told. Nothing is saved, and no action is offered.",
            Token::Muted,
        )),
        _ => {}
    }
    // The disk as the core computed it for this answer, else as it read it.
    let regions = f
        .checked
        .as_ref()
        .map(|c| c.regions.as_slice())
        .filter(|r| !r.is_empty())
        .or_else(|| {
            plan.then(|| m.snap.as_ref().map(|s| s.regions.as_slice()))
                .flatten()
                .filter(|r| !r.is_empty())
        });
    if let Some(r) = regions {
        v.push(Item::Blank);
        v.push(Item::Strip(r));
    }
    v.push(Item::Blank);
    for i in 0..f.fields.len() {
        v.push(Item::Field(i));
    }
    if plan && offered.is_none() {
        v.push(text(
            "as 250GB, 1.5TB or 30%; a size left empty is not sent",
            Token::Muted,
        ));
    } else {
        v.push(text(
            "a field left empty is not sent: the core answers its default",
            Token::Muted,
        ));
    }
    v.push(Item::Blank);
    if let Some(fault) = &f.fault {
        v.push(Item::Fault(fault));
        return v;
    }
    let Some(c) = &f.checked else {
        if !m.reading(|r| matches!(r, crate::app::Req::Validate { .. })) {
            v.push(text(
                if plan && offered.is_none() {
                    "Type the sizes, then ⏎ to check them."
                } else {
                    "Type or choose, then ⏎: the core checks it."
                },
                Token::Muted,
            ));
        }
        return v;
    };
    // The plan check of the two sizes keeps its own words.
    let sizes = plan && offered.is_none();
    if !f.current() {
        v.push(Item::Verdict(
            Level::Warn,
            if sizes {
                "the sizes above changed since this answer; ⏎ checks them"
            } else {
                "the fields above changed since this answer; ⏎ checks them"
            }
            .into(),
        ));
    }
    let arg = |n: &str| {
        c.args
            .iter()
            .find(|(k, _)| k == n)
            .map(|(_, v)| String::from_utf8_lossy(v).into_owned())
    };
    let sent: Vec<String> = c
        .args
        .iter()
        .map(|(n, val)| format!("{} {}", field_label(n), String::from_utf8_lossy(val)))
        .collect();
    v.push(text(
        if sizes {
            let s = |n| arg(n).unwrap_or_else(|| "not sent".into());
            format!(
                "For Linux {} · Shared {}",
                s("linux_size"),
                s("shared_size")
            )
        } else if sent.is_empty() {
            "Sent: nothing typed".to_string()
        } else {
            format!("Sent: {}", sent.join(" · "))
        },
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
        v.push(Item::Verdict(
            Level::Fail,
            format!("{} {code}", field_label(p)),
        ));
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
        v.push(Item::Heading("As the core reads them"));
        for (p, value) in &c.normals {
            let shown = if p.ends_with("_size") {
                format!("{value} bytes")
            } else {
                value.clone()
            };
            v.push(pair(&field_label(p), shown, Token::Text));
        }
    }
    if let Some(basis) = &c.basis {
        v.push(Item::Blank);
        v.push(Item::Heading("Review basis"));
        v.push(text(basis.clone(), Token::Text));
        match &offered {
            Some(a) if f.current() && c.status == "done" => v.push(text(
                if a.gate.is_empty() {
                    format!(
                        "⏎ {}: the core asks this basis again, then runs it.",
                        a.label
                    )
                } else {
                    format!("⏎ opens the gate: type {} to run {}.", a.gate, a.label)
                },
                Token::Accent,
            )),
            Some(_) => {}
            None => v.push(text(
                "a basis for review only: nothing was saved, and no action is offered",
                Token::Muted,
            )),
        }
    }
    v
}

pub fn draw(f: &mut Frame, area: Rect, m: &Model, t: &Theme, s: Screen) {
    let reading = m.reading(|r| matches!(r, crate::app::Req::Validate { .. }));
    let fm = form(m, s);
    let mut title = match s {
        Screen::Plan if m.offered(Scope::Journey, "plan.save").is_some() => {
            "Storage planner".to_string()
        }
        Screen::Plan => "Plan check".to_string(),
        _ => m
            .offered(fm.scope, &fm.action)
            .map_or_else(|| fm.action.clone(), |a| a.label),
    };
    if reading {
        title.push_str(&format!(" {} checking", t.g.dot));
    }
    let inner = widgets::panel(f, area, &title, t);
    draw_items(f, inner, &items(m, s), m.plan_scroll, None, m, t);
}
