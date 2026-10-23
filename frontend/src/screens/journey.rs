//! Screens 23 and 25: the core's cross-system check and final report.
use super::{Item, draw_items};
use crate::app::{Level, Model, Screen};
use crate::read::Kind;
use crate::theme::{Theme, Token};
use crate::widgets;
use ratatui::Frame;
use ratatui::layout::Rect;

pub fn stage_token(state: &str) -> Token {
    match state {
        "done" => Token::Ok,
        "current" => Token::Accent,
        "blocked" => Token::Blocked,
        "failed" => Token::Danger,
        "skipped" => Token::Muted,
        _ => Token::Pending,
    }
}

fn ready<'a>(m: &'a Model, kind: Kind, v: &mut Vec<Item<'a>>) -> bool {
    if let Some(f) = &m.scope(kind.scope()).fault {
        v.push(Item::Fault(f));
        return false;
    }
    if let Some(d) = m.detail(kind) {
        if let Some(f) = &d.fault {
            v.push(Item::Fault(f));
            return false;
        }
        if d.changed || m.generation(kind.scope()) != Some(d.generation.as_str()) {
            v.push(Item::Text(
                "Changed since you looked - r reads again.".into(),
                Token::Warn,
            ));
            return false;
        }
    }
    if !m.whole(kind) {
        v.push(Item::Text(
            format!("{}; r reads again.", kind.reading()),
            Token::Muted,
        ));
        return false;
    }
    true
}

pub fn items(m: &Model) -> Vec<Item<'_>> {
    let mut v = Vec::new();
    if m.check {
        v.push(Item::Text(
            "The startup check reads only the journey.".into(),
            Token::Muted,
        ));
        return v;
    }
    if m.screen == Screen::Qualification {
        if let Some(s) = m.snap_of(crate::read::Scope::Qualify) {
            v.extend(
                s.facts
                    .iter()
                    .filter(|f| !f.key.starts_with("gate."))
                    .map(Item::Check),
            );
            v.extend(s.blockers.iter().map(Item::Blocker));
            v.extend(s.warnings.iter().map(Item::Warning));
            if let Some(a) = s.action("qualify.run") {
                v.push(Item::Text(
                    format!("t {} - type {} - terminal handoff", a.label, a.gate),
                    Token::Accent,
                ));
            }
        }
        v.push(Item::Heading("Cross-system check"));
        if ready(m, Kind::Step, &mut v) {
            for r in &m.detail(Kind::Step).expect("whole").rows {
                v.push(Item::Text(
                    format!("{}  {} - {}", r.key, r.col(1), r.col(0)),
                    stage_token(r.col(0)),
                ));
                v.push(Item::Text(r.col(2).into(), Token::Text));
            }
        }
    } else {
        v.push(Item::Heading("Journey stages"));
        if let Some(s) = &m.snap {
            if s.stages.is_empty() {
                v.push(Item::Text(
                    "Every station is later; the core supplied no stages.".into(),
                    Token::Muted,
                ));
            }
            for stage in &s.stages {
                v.push(Item::Text(stage.description(), stage_token(&stage.state)));
            }
        }
        v.push(Item::Blank);
        v.push(Item::Heading("Report"));
        if ready(m, Kind::Report, &mut v) {
            let rows = &m.detail(Kind::Report).expect("whole").rows;
            let count = |s: &str| rows.iter().filter(|r| r.col(0) == s).count();
            let (pass, warn, fail, unchecked) = (
                count("pass"),
                count("warn"),
                count("fail"),
                count("not-checked"),
            );
            let (verdict, level) = if fail > 0 {
                ("fail", Level::Fail)
            } else if warn > 0 {
                ("warn", Level::Warn)
            } else {
                ("pass", Level::Ok)
            };
            v.push(Item::Verdict(level, format!("Report: {verdict}")));
            v.push(Item::Text(
                format!("{pass} pass - {warn} warn - {fail} fail - {unchecked} not-checked"),
                Token::Text,
            ));
            for r in rows {
                v.push(Item::Text(
                    format!("{} - {}: {}", r.col(1), r.col(0), r.col(2)),
                    match r.col(0) {
                        "pass" => Token::Ok,
                        "warn" => Token::Warn,
                        "fail" => Token::Danger,
                        _ => Token::Muted,
                    },
                ));
            }
        }
    }
    v
}

pub fn draw(f: &mut Frame, area: Rect, m: &Model, t: &Theme) {
    let inner = widgets::panel(f, area, m.screen.title(), t);
    draw_items(f, inner, &items(m), m.page_scroll, None, m, t);
}
