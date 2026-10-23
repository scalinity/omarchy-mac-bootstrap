//! Screen 12, the storage planner, and the parameter form of any other
//! action (docs/UX.md → *Every screen*; docs/PROTOCOL.md → *plan.save*).
//! The fields are the parameters the core declares for the action, as typed
//! or chosen; an empty one is not sent, and the core answers it with its
//! default. The core's answer is shown as it came — the layout on the disk
//! strip, the installer's questions and what to type, each value as the core
//! normalised it, warnings, refusals and the review's basis. The frontend
//! presents preset inputs; the core computes and judges the plan: a review it holds for exactly what
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

/// What a parameter is called on the screen: the two sizes by the meaning
/// the plan's validation contract gives them, the nine plan choices by their
/// readable names, and other parameters by the core's declared name.
pub fn field_label(p: &str) -> String {
    match p {
        "linux_size" => "Linux size",
        "shared_size" => "Shared size",
        "enc" => "Encrypt Linux",
        "user" => "User name",
        "host" => "Host name",
        "kmap" => "Keyboard layout",
        "tz" => "Time zone",
        "loc" => "Locale",
        "ssh" => "SSH server",
        "gh" => "GitHub user",
        "dev" => "Developer tools",
        p => p,
    }
    .to_string()
}

pub fn field_order(p: &Form) -> Vec<usize> {
    if !p.storage {
        return (0..p.fields.len()).collect();
    }
    crate::app::PLAN_SIZES
        .iter()
        .filter_map(|name| p.fields.iter().position(|f| f.name == *name))
        .chain(
            p.fields
                .iter()
                .enumerate()
                .filter(|(_, f)| !crate::app::PLAN_SIZES.contains(&f.name.as_str()))
                .map(|(i, _)| i),
        )
        .collect()
}

pub const UNITS: [&str; 3] = ["GB", "TB", "%"];

pub fn presets(size: usize) -> &'static [(&'static str, &'static str)] {
    if size == 0 {
        &[
            ("Minimal 100", "100GB"),
            ("Balanced 250", "250GB"),
            ("Linux-heavy 500", "500GB"),
            ("Custom", ""),
        ]
    } else {
        &[
            ("none", "0"),
            ("50", "50GB"),
            ("100", "100GB"),
            ("150", "150GB"),
            ("250", "250GB"),
            ("Custom", ""),
        ]
    }
}

/// Only the snapshot's displayed capacity supplies availability hints. The
/// core alone accepts the selected sizes and computes the actual layout.
fn safe_max(m: &Model) -> Option<u64> {
    let fact = m
        .snap
        .as_ref()?
        .facts
        .iter()
        .find(|f| f.label.starts_with("Safe Linux max"))?;
    let mut parts = fact.value.split_whitespace();
    let n = parts.next()?.parse::<f64>().ok()?;
    match parts.next()? {
        "GB" => Some((n * 1e9) as u64),
        "TB" => Some((n * 1e12) as u64),
        _ => None,
    }
}

pub fn unavailable(m: &Model, size: usize, preset: usize) -> Option<String> {
    let value = presets(size)
        .get(preset)?
        .1
        .strip_suffix("GB")?
        .parse::<u64>()
        .ok()?
        * 1_000_000_000;
    let max = safe_max(m)?;
    (value > max).then(|| {
        format!(
            "{} unavailable: above the snapshot's safe Linux maximum ({}).",
            presets(size)[preset].0,
            widgets::gb(max)
        )
    })
}

/// Start with the saved layout when the snapshot supplies one, otherwise
/// the brief's Balanced/150 presets when the snapshot says they fit.
pub fn defaults(m: &mut Model) {
    let max = safe_max(m);
    let saved = m
        .snap
        .as_ref()
        .and_then(|s| {
            s.facts
                .iter()
                .find(|f| f.key.starts_with("recorded.") && f.label == "Plan")
        })
        .and_then(|f| {
            let words: Vec<&str> = f.value.split_whitespace().collect();
            if words.len() != 3 && words.len() != 7 {
                return None;
            }
            if words[0] != "Linux" || words[2] != "GB" {
                return None;
            }
            let linux = words[1].parse::<u64>().ok()?.checked_mul(1_000_000_000)?;
            let shared = if words.len() == 7
                && words[3] == "+"
                && words[5] == "GB"
                && words[6] == "shared"
            {
                words[4].parse::<u64>().ok()?.checked_mul(1_000_000_000)?
            } else if words.len() == 3 {
                0
            } else {
                return None;
            };
            Some((linux, shared))
        });
    let shared = saved.map(|s| s.1).unwrap_or_else(|| {
        if max.is_none_or(|v| v >= 400_000_000_000) {
            150_000_000_000
        } else {
            0
        }
    });
    let linux = saved.map(|s| s.0).unwrap_or_else(|| {
        if max.is_none_or(|v| v >= 250_000_000_000 + shared) {
            250_000_000_000
        } else {
            100_000_000_000
        }
    });
    m.plan.storage = true;
    for (si, (name, bytes)) in [("linux_size", linux), ("shared_size", shared)]
        .into_iter()
        .enumerate()
    {
        if let Some(field) = m.plan.fields.iter_mut().find(|f| f.name == name)
            && field.value.is_empty()
        {
            field.value = if bytes == 0 {
                "0".into()
            } else {
                format!("{}GB", bytes as f64 / 1e9)
            };
            m.plan.custom[si] = !presets(si).iter().any(|(_, v)| *v == field.value);
        }
    }
    m.plan.field = m
        .plan
        .fields
        .iter()
        .position(|f| f.name == "linux_size")
        .unwrap_or(0);
}

pub fn field_lines<'a>(
    m: &Model,
    t: &Theme,
    width: usize,
    index: usize,
) -> Vec<ratatui::text::Line<'a>> {
    use ratatui::text::{Line, Span};
    let over = matches!(m.screen, Screen::Gate | Screen::Help) && m.back == Screen::Form;
    let p = if m.screen == Screen::Form || over {
        &m.form
    } else {
        &m.plan
    };
    let Some(field) = p.fields.get(index) else {
        return Vec::new();
    };
    let here = m.region == crate::app::Region::Work && p.field == index && m.focus_visible();
    let pointer = if here { t.g.pointer } else { " " };
    let label = field_label(&field.name);
    let mut lines = Vec::new();
    if p.storage
        && let Some(si) = crate::app::PLAN_SIZES.iter().position(|n| *n == field.name)
    {
        let mut spans = vec![Span::styled(
            format!(" {pointer} {label}  "),
            t.style(if here { Token::Focus } else { Token::Muted }),
        )];
        let mut used = 4 + widgets::cells(&label);
        for (i, (label, value)) in presets(si).iter().enumerate() {
            let selected = if value.is_empty() {
                p.custom[si]
            } else {
                !p.custom[si] && field.value == *value
            };
            let blocked = unavailable(m, si, i);
            let mark = match (selected, t.caps.unicode) {
                (true, true) => "◉",
                (false, true) => "○",
                (true, false) => "(x)",
                _ => "( )",
            };
            let word = format!(
                "{mark} {label}{}  ",
                if blocked.is_some() {
                    " unavailable"
                } else {
                    ""
                }
            );
            if used + widgets::cells(&word) > width && spans.len() > 1 {
                lines.push(Line::from(spans));
                spans = vec![Span::raw("   ")];
                used = 3;
            }
            used += widgets::cells(&word);
            spans.push(Span::styled(
                word,
                t.style(if blocked.is_some() {
                    Token::Muted
                } else if selected {
                    Token::Selected
                } else {
                    Token::Text
                }),
            ));
        }
        lines.push(Line::from(spans));
        if p.custom[si] {
            let unit = UNITS[p.units[si]];
            let number = field.value.strip_suffix(unit).unwrap_or(&field.value);
            let mut spans = vec![
                Span::raw("     "),
                Span::styled(
                    widgets::fit(number, width.saturating_sub(22), t.caps.unicode),
                    t.style(if here && !p.unit_focus {
                        Token::Gate
                    } else {
                        Token::Text
                    }),
                ),
            ];
            if here && !p.unit_focus {
                spans.push(Span::styled(
                    if t.caps.unicode { "▏" } else { "_" },
                    t.style(Token::Gate),
                ));
            }
            for (i, u) in UNITS.iter().enumerate() {
                spans.push(Span::styled(
                    format!(" {u} "),
                    t.style(if here && p.unit_focus && i == p.units[si] {
                        Token::Focus
                    } else if i == p.units[si] {
                        Token::Selected
                    } else {
                        Token::Muted
                    }),
                ));
            }
            lines.push(Line::from(spans));
        }
        for i in 0..presets(si).len() {
            if let Some(why) = unavailable(m, si, i) {
                lines.extend(
                    widgets::wrap(&t.say(&why), width.saturating_sub(6))
                        .into_iter()
                        .map(|s| Line::styled(format!("     {s}"), t.style(Token::Muted))),
                );
            }
        }
    } else {
        let lw = p
            .fields
            .iter()
            .map(|f| widgets::cells(&field_label(&f.name)))
            .max()
            .unwrap_or(12)
            .clamp(12, 18);
        let mut spans = vec![Span::styled(
            format!(" {pointer} {label:<lw$} "),
            t.style(Token::Muted),
        )];
        let boolean = field.ty == "bool"
            || (p.storage && matches!(field.name.as_str(), "enc" | "ssh" | "dev"));
        let choices: Vec<&str> = if boolean {
            vec!["0", "1"]
        } else {
            field.choices.iter().map(String::as_str).collect()
        };
        if !choices.is_empty() {
            for c in choices {
                let on = c == field.value;
                let mark = match (on, t.caps.unicode) {
                    (true, true) => "◉",
                    (false, true) => "○",
                    (true, false) => "(x)",
                    _ => "( )",
                };
                let word = if boolean {
                    if c == "1" { "on" } else { "off" }
                } else {
                    c
                };
                spans.push(Span::styled(
                    format!("{mark} {word}  "),
                    t.style(if on { Token::Selected } else { Token::Text }),
                ));
            }
        } else {
            let value = if field.value == "-" {
                "none"
            } else {
                &field.value
            };
            spans.push(Span::styled(
                widgets::fit(value, width.saturating_sub(lw + 6), t.caps.unicode),
                t.style(if here { Token::Gate } else { Token::Text }),
            ));
            if here {
                spans.push(Span::styled(
                    if t.caps.unicode { "▏" } else { "_" },
                    t.style(Token::Gate),
                ));
            }
        }
        lines.push(Line::from(spans));
    }
    // Old answers never paint a field red while it is being edited.
    if p.storage
        && p.current()
        && let Some(c) = &p.checked
    {
        if let Some((_, _, text)) = c.invalid.iter().find(|(n, _, _)| *n == field.name) {
            lines.extend(
                widgets::wrap(&t.say(text), width.saturating_sub(6))
                    .into_iter()
                    .map(|s| Line::styled(format!("     {s}"), t.style(Token::Danger))),
            );
        } else if field.name.ends_with("_size")
            && let Some((_, normal)) = c.normals.iter().find(|(n, _)| *n == field.name)
        {
            let normal = normal
                .parse::<u64>()
                .ok()
                .map(widgets::gb)
                .unwrap_or_else(|| normal.clone());
            lines.push(Line::styled(
                format!("     {normal}"),
                t.style(Token::Muted),
            ));
        }
    }
    lines
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
    if f.storage {
        for name in crate::app::PLAN_SIZES {
            if let Some(i) = f.fields.iter().position(|f| f.name == name) {
                v.push(Item::Field(i));
            }
        }
        if f.current()
            && let Some(c) = &f.checked
            && !c.answers.is_empty()
        {
            v.push(Item::Heading("The installer asks                 you type"));
            for (prompt, value, _) in &c.answers {
                v.push(pair(prompt, value.clone(), Token::Accent));
            }
        }
        for (i, _) in f
            .fields
            .iter()
            .enumerate()
            .filter(|(_, f)| !crate::app::PLAN_SIZES.contains(&f.name.as_str()))
        {
            v.push(Item::Field(i));
        }
    } else {
        for i in 0..f.fields.len() {
            v.push(Item::Field(i));
        }
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
        ("refused", _) => Item::Verdict(Level::Warn, "Check the input above".into()),
        (_, _) => Item::Verdict(Level::Fail, "The check could not finish".into()),
    });
    if !c.text.is_empty() {
        v.push(text(c.text.clone(), Token::Text));
    }
    for (p, _code, t) in c.invalid.iter().filter(|_| !f.storage) {
        v.push(Item::Verdict(Level::Fail, field_label(p)));
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
    if !f.storage && !c.answers.is_empty() {
        v.push(Item::Blank);
        v.push(Item::Heading("The installer asks"));
        for (prompt, value, _) in &c.answers {
            v.push(pair(prompt, format!("you type {value}"), Token::Accent));
        }
    }
    if !f.storage && !c.normals.is_empty() {
        v.push(Item::Blank);
        v.push(Item::Heading("As the core reads them"));
        for (p, value) in &c.normals {
            let shown = if p.ends_with("_size") {
                value
                    .parse::<u64>()
                    .ok()
                    .map(widgets::gb)
                    .unwrap_or_else(|| value.clone())
            } else {
                value.clone()
            };
            v.push(pair(&field_label(p), shown, Token::Text));
        }
    }
    if let Some(_basis) = &c.basis {
        v.push(Item::Blank);
        v.push(Item::Heading("Review ready"));
        match &offered {
            Some(a) => {
                v.push(text("a check only: nothing was saved", Token::Muted));
                if f.current() && c.status == "done" {
                    v.push(text(
                        if a.gate.is_empty() {
                            format!(
                                "⏎ {}: asked first, then the core checks this basis again.",
                                a.label
                            )
                        } else {
                            format!("⏎ opens the gate: type {} to run {}.", a.gate, a.label)
                        },
                        Token::Accent,
                    ));
                }
            }
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
    let items = items(m, s);
    let focus = items
        .iter()
        .position(|i| matches!(i, Item::Field(i) if *i == fm.field));
    draw_items(f, inner, &items, m.plan_scroll, focus, m, t);
}
