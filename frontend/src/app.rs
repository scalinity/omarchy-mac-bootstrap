//! The model, its messages and `update` (docs/FRONTEND.md → *Event loop and
//! state*). `update` is a pure function of the model and one message: it
//! performs no I/O and returns the commands the event loop carries out. The
//! model keeps the last snapshot to draw from — a view, never the truth —
//! and asks again after every action, on `r`, and after a handoff or a
//! suspend. An action is always submitted with the basis it was shown.

use crate::record::Record;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

/// What the core said about itself and the session (the hello record).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Hello {
    pub core: String,
    pub platform: String,
    pub arch: String,
    pub user: String,
    pub ceiling: String,
    pub dry_run: bool,
    pub fixture: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Fact {
    pub key: String,
    pub label: String,
    pub value: String,
    pub state: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Blocker {
    pub text: String,
    pub fix: String,
}

/// An action the core listed as available now, with the basis it was shown.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Action {
    pub id: String,
    pub label: String,
    pub intent: String,
    pub gate: String,
    pub handoff: bool,
    pub cancel: bool,
    pub basis: String,
    pub explain: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    pub facts: Vec<Fact>,
    pub blockers: Vec<Blocker>,
    pub actions: Vec<Action>,
    pub stages: Vec<(String, String)>,
}

/// A request the event loop sends to a fresh core.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Req {
    Hello,
    Snapshot,
    Execute {
        action: String,
        basis: String,
        word: String,
        handoff: bool,
        cancel: bool,
    },
}

/// How a request ended, as the event loop observed it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// The core exited and its spool was admitted, ending in one result.
    Answer(Vec<Record>),
    /// No result, or a spool that failed admission: the outcome is unknown.
    Unknown(String),
    /// The request could not be delivered (EPIPE, no core): nothing ran.
    NotSent(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Ok,
    Info,
    Warn,
    Fail,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Screen {
    Connecting,
    Dashboard,
    Gate,
    Logs,
    Help,
    /// The core could not be reached or answered with an error.
    Fatal,
}

/// A request in flight.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pending {
    pub req: Req,
    pub cancellable: bool,
    pub label: String,
    /// Ticks (of the event loop) since it started, for the spinner.
    pub ticks: u32,
}

#[derive(Debug)]
pub struct Model {
    pub screen: Screen,
    /// Where help or logs return to.
    pub back: Screen,
    pub hello: Option<Hello>,
    pub snap: Option<Snapshot>,
    pub focus: usize,
    pub gate_input: String,
    pub gate_note: Option<String>,
    pub status: Option<(Level, String)>,
    pub pending: Option<Pending>,
    pub progress: Option<(String, u64, u64)>,
    pub messages: Vec<(Level, String)>,
    pub fatal: String,
    pub logs: Vec<String>,
    pub scroll: usize,
    pub quit_after: bool,
    pub asked_quit: bool,
}

/// What the event loop does next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Cmd {
    Send(Req),
    /// SIGTERM to the core of a cancellable request.
    Cancel,
    Suspend,
    ReadLogs,
    /// Exit: 0 finished, 10 fall back to text (with the reason on stderr).
    Quit(i32, String),
}

pub enum Msg {
    Key(KeyEvent),
    /// A record admitted from the spool while the request runs.
    Live(Record),
    Done(Req, Outcome),
    Logs(Vec<String>),
    Tick,
    /// SIGTERM or SIGHUP: finish what is running, then exit.
    Terminate,
}

/// Messages kept per request (docs/PROTOCOL.md → *Backpressure and bounds*).
pub const MESSAGES_MAX: usize = 500;

impl Default for Model {
    fn default() -> Model {
        Model {
            screen: Screen::Connecting,
            back: Screen::Dashboard,
            hello: None,
            snap: None,
            focus: 0,
            gate_input: String::new(),
            gate_note: None,
            status: None,
            pending: None,
            progress: None,
            messages: Vec::new(),
            fatal: String::new(),
            logs: Vec::new(),
            scroll: 0,
            quit_after: false,
            asked_quit: false,
        }
    }
}

impl Model {
    /// The start: the handshake.
    pub fn start(&mut self) -> Vec<Cmd> {
        self.send(Req::Hello, false, "connecting")
    }

    pub fn focused(&self) -> Option<&Action> {
        self.snap.as_ref().and_then(|s| s.actions.get(self.focus))
    }

    fn send(&mut self, req: Req, cancellable: bool, label: &str) -> Vec<Cmd> {
        self.pending = Some(Pending {
            req: req.clone(),
            cancellable,
            label: label.into(),
            ticks: 0,
        });
        self.progress = None;
        self.messages.clear();
        vec![Cmd::Send(req)]
    }

    fn refresh(&mut self) -> Vec<Cmd> {
        self.send(Req::Snapshot, true, "reading")
    }
}

fn text(r: &Record, k: &str) -> String {
    r.text(k).unwrap_or("").to_string()
}

/// The records of a snapshot answer, as the model keeps them.
pub fn snapshot_of(records: &[Record]) -> Snapshot {
    let mut s = Snapshot::default();
    for r in records {
        match r.ty.as_str() {
            "fact" => s.facts.push(Fact {
                key: text(r, "key"),
                label: text(r, "label"),
                value: text(r, "value"),
                state: text(r, "state"),
            }),
            "blocker" => s.blockers.push(Blocker {
                text: text(r, "text"),
                fix: text(r, "fix"),
            }),
            "stage" => s.stages.push((text(r, "name"), text(r, "state"))),
            "action" => s.actions.push(Action {
                id: text(r, "id"),
                label: text(r, "label"),
                intent: text(r, "intent"),
                gate: text(r, "gate"),
                handoff: r.text("terminal") == Some("handoff"),
                cancel: r.text("cancel") == Some("1"),
                basis: text(r, "basis"),
                explain: text(r, "explain"),
            }),
            _ => {}
        }
    }
    s
}

fn hello_of(records: &[Record]) -> Option<Hello> {
    let r = records.iter().find(|r| r.ty == "hello")?;
    Some(Hello {
        core: text(r, "core"),
        platform: text(r, "platform"),
        arch: text(r, "arch"),
        user: text(r, "user"),
        ceiling: text(r, "ceiling"),
        dry_run: r.text("dry_run") == Some("1"),
        fixture: r.text("fixture") == Some("1"),
    })
}

/// The result record: status, code, text, next.
fn result_of(records: &[Record]) -> Option<(String, String, String, String)> {
    let r = records.last().filter(|r| r.ty == "result")?;
    Some((
        text(r, "status"),
        text(r, "code"),
        text(r, "text"),
        text(r, "next"),
    ))
}

fn level_of(s: &str) -> Level {
    match s {
        "ok" => Level::Ok,
        "warn" => Level::Warn,
        "fail" => Level::Fail,
        _ => Level::Info,
    }
}

/// The one update function.
pub fn update(m: &mut Model, msg: Msg) -> Vec<Cmd> {
    match msg {
        Msg::Tick => {
            if let Some(p) = m.pending.as_mut() {
                p.ticks = p.ticks.saturating_add(1);
            }
            Vec::new()
        }
        Msg::Terminate => {
            if m.pending.is_none() {
                return vec![Cmd::Quit(0, String::new())];
            }
            m.quit_after = true;
            let cancel = m.pending.as_ref().is_some_and(|p| p.cancellable);
            if cancel {
                vec![Cmd::Cancel]
            } else {
                Vec::new()
            }
        }
        Msg::Logs(lines) => {
            m.logs = lines;
            m.scroll = 0;
            if m.screen != Screen::Logs {
                m.back = m.screen;
                m.screen = Screen::Logs;
            }
            Vec::new()
        }
        Msg::Live(r) => {
            match r.ty.as_str() {
                "progress" => {
                    let n = |k| r.text(k).and_then(|v| v.parse().ok()).unwrap_or(0);
                    m.progress = Some((text(&r, "action"), n("done"), n("total")));
                }
                "message" if m.messages.len() < MESSAGES_MAX => {
                    m.messages
                        .push((level_of(r.text("level").unwrap_or("")), text(&r, "text")));
                }
                _ => {}
            }
            Vec::new()
        }
        Msg::Done(req, outcome) => done(m, req, outcome),
        Msg::Key(k) => key(m, k),
    }
}

fn done(m: &mut Model, req: Req, outcome: Outcome) -> Vec<Cmd> {
    m.pending = None;
    m.progress = None;
    let after = |m: &mut Model, mut cmds: Vec<Cmd>| {
        if m.quit_after {
            return vec![Cmd::Quit(0, String::new())];
        }
        if cmds.is_empty() {
            cmds = Vec::new();
        }
        cmds
    };
    let records = match outcome {
        Outcome::Answer(r) => r,
        Outcome::Unknown(why) => {
            // Never "failed", never "nothing happened": the machine is read again.
            if req == Req::Hello {
                m.screen = Screen::Fatal;
                m.fatal = format!("The core stopped without a complete answer ({why}).");
                return after(m, Vec::new());
            }
            m.status = Some((
                Level::Warn,
                format!(
                    "The core stopped without a complete answer ({why}); reading the machine again."
                ),
            ));
            let c = m.refresh();
            return after(m, c);
        }
        Outcome::NotSent(why) => {
            if req == Req::Hello {
                m.screen = Screen::Fatal;
                m.fatal = format!("The core could not be started ({why}).");
                return after(m, Vec::new());
            }
            m.status = Some((
                Level::Fail,
                format!("The request was not delivered ({why}); nothing ran."),
            ));
            return after(m, Vec::new());
        }
    };
    let Some((status, code, text, next)) = result_of(&records) else {
        m.status = Some((
            Level::Warn,
            "The core stopped without a complete answer; reading the machine again.".into(),
        ));
        let c = m.refresh();
        return after(m, c);
    };
    match req {
        Req::Hello => {
            if status == "done" {
                m.hello = hello_of(&records);
                let c = m.refresh();
                return after(m, c);
            }
            // A version refusal, or a session the core will not serve: back
            // to the text interface, with the core's reason.
            let why = if text.is_empty() {
                format!("the core refused the session ({code})")
            } else {
                text
            };
            vec![Cmd::Quit(10, why)]
        }
        Req::Snapshot => {
            if status == "done" {
                let s = snapshot_of(&records);
                if m.focus >= s.actions.len() {
                    m.focus = s.actions.len().saturating_sub(1);
                }
                m.snap = Some(s);
                if matches!(m.screen, Screen::Connecting | Screen::Fatal) {
                    m.screen = Screen::Dashboard;
                }
                return after(m, Vec::new());
            }
            if m.snap.is_none() {
                // Nothing to show at all: say why, and let the person leave.
                let why = if text.is_empty() { code } else { text };
                return vec![Cmd::Quit(10, why)];
            }
            m.status = Some((Level::Warn, if text.is_empty() { code } else { text }));
            after(m, Vec::new())
        }
        Req::Execute { action, .. } => {
            let (lvl, word) = match status.as_str() {
                "done" => (Level::Ok, "done"),
                "cancelled" => (Level::Info, "cancelled"),
                "refused" => (Level::Warn, "refused"),
                "stopped" if code == "unsupervised" => (Level::Fail, "outcome unknown"),
                "stopped" => (Level::Warn, "stopped"),
                _ => (Level::Fail, "failed"),
            };
            let detail = if !text.is_empty() {
                text
            } else if let Some((l, t)) = m.messages.last() {
                if *l == Level::Info {
                    t.clone()
                } else {
                    String::new()
                }
            } else {
                String::new()
            };
            let mut line = format!("{action}: {word}");
            if !detail.is_empty() {
                line.push_str(" — ");
                line.push_str(&detail);
            }
            if code == "changed" {
                line.push_str(" (changed since you looked)");
            }
            if !next.is_empty() {
                line.push_str(" · ");
                line.push_str(&next);
            }
            m.status = Some((lvl, line));
            // Every action is followed by a fresh read.
            let c = m.refresh();
            after(m, c)
        }
    }
}

fn ctrl(k: &KeyEvent, c: char) -> bool {
    k.modifiers.contains(KeyModifiers::CONTROL) && k.code == KeyCode::Char(c)
}

fn key(m: &mut Model, k: KeyEvent) -> Vec<Cmd> {
    if k.kind != KeyEventKind::Press {
        return Vec::new();
    }
    // Ctrl-C: quit when idle, cancel a cancellable request, clear a field.
    if ctrl(&k, 'c') {
        if m.screen == Screen::Gate && !m.gate_input.is_empty() {
            m.gate_input.clear();
            m.gate_note = None;
            return Vec::new();
        }
        return match &m.pending {
            None => vec![Cmd::Quit(0, String::new())],
            Some(p) if p.cancellable => {
                m.status = Some((Level::Info, "Cancelling at the next safe boundary…".into()));
                vec![Cmd::Cancel]
            }
            Some(_) => {
                m.status = Some((
                    Level::Info,
                    "This request cannot be cancelled safely; it will finish first.".into(),
                ));
                Vec::new()
            }
        };
    }
    if ctrl(&k, 'z') {
        if m.pending.is_some() {
            m.status = Some((
                Level::Info,
                "Suspending waits until the running request ends.".into(),
            ));
            return Vec::new();
        }
        return vec![Cmd::Suspend];
    }
    match m.screen {
        Screen::Gate => gate_key(m, k),
        Screen::Logs => match k.code {
            KeyCode::Esc | KeyCode::Char('q') => {
                m.screen = m.back;
                Vec::new()
            }
            KeyCode::Down | KeyCode::Char('j') => {
                m.scroll = m
                    .scroll
                    .saturating_add(1)
                    .min(m.logs.len().saturating_sub(1));
                Vec::new()
            }
            KeyCode::Up | KeyCode::Char('k') => {
                m.scroll = m.scroll.saturating_sub(1);
                Vec::new()
            }
            _ => Vec::new(),
        },
        Screen::Help => {
            if matches!(
                k.code,
                KeyCode::Esc | KeyCode::Char('q') | KeyCode::Char('?')
            ) {
                m.screen = m.back;
            }
            Vec::new()
        }
        Screen::Fatal => match k.code {
            KeyCode::Char('q') | KeyCode::Esc => vec![Cmd::Quit(10, m.fatal.clone())],
            KeyCode::Char('r') if m.pending.is_none() => m.start(),
            _ => Vec::new(),
        },
        Screen::Connecting => match k.code {
            KeyCode::Char('q') => vec![Cmd::Quit(0, String::new())],
            _ => Vec::new(),
        },
        Screen::Dashboard => dashboard_key(m, k),
    }
}

fn dashboard_key(m: &mut Model, k: KeyEvent) -> Vec<Cmd> {
    let n = m.snap.as_ref().map_or(0, |s| s.actions.len());
    if m.asked_quit {
        m.asked_quit = false;
        if matches!(k.code, KeyCode::Char('y') | KeyCode::Char('q')) {
            m.quit_after = true;
            m.status = Some((
                Level::Info,
                "Quitting when the running request ends.".into(),
            ));
        } else {
            m.status = None;
        }
        return Vec::new();
    }
    match k.code {
        KeyCode::Down | KeyCode::Char('j') if n > 0 => {
            m.focus = (m.focus + 1).min(n - 1);
            Vec::new()
        }
        KeyCode::Up | KeyCode::Char('k') => {
            m.focus = m.focus.saturating_sub(1);
            Vec::new()
        }
        KeyCode::Home | KeyCode::Char('g') => {
            m.focus = 0;
            Vec::new()
        }
        KeyCode::End | KeyCode::Char('G') => {
            m.focus = n.saturating_sub(1);
            Vec::new()
        }
        KeyCode::Char('r') if m.pending.is_none() => m.refresh(),
        KeyCode::Char('L') => vec![Cmd::ReadLogs],
        KeyCode::Char('?') => {
            m.back = m.screen;
            m.screen = Screen::Help;
            Vec::new()
        }
        KeyCode::Char('q') => {
            if m.pending.is_none() {
                return vec![Cmd::Quit(0, String::new())];
            }
            m.asked_quit = true;
            m.status = Some((
                Level::Info,
                "A request is running. Quit when it ends? (y/n)".into(),
            ));
            Vec::new()
        }
        KeyCode::Enter if m.pending.is_some() => {
            // One request at a time: say so rather than do nothing.
            m.status = Some((
                Level::Info,
                "One thing at a time: this runs once the current request ends.".into(),
            ));
            Vec::new()
        }
        KeyCode::Enter => {
            let Some(a) = m.focused().cloned() else {
                return Vec::new();
            };
            if a.gate.is_empty() {
                let label = a.label.clone();
                m.send(
                    Req::Execute {
                        action: a.id,
                        basis: a.basis,
                        word: String::new(),
                        handoff: a.handoff,
                        cancel: a.cancel,
                    },
                    a.cancel,
                    &label,
                )
            } else {
                // A typed-word gate: the gate screen, one field, no button.
                m.gate_input.clear();
                m.gate_note = None;
                m.screen = Screen::Gate;
                Vec::new()
            }
        }
        _ => Vec::new(),
    }
}

fn gate_key(m: &mut Model, k: KeyEvent) -> Vec<Cmd> {
    match k.code {
        KeyCode::Esc => {
            m.screen = Screen::Dashboard;
            m.gate_input.clear();
            m.gate_note = None;
            Vec::new()
        }
        KeyCode::Backspace => {
            m.gate_input.pop();
            m.gate_note = None;
            Vec::new()
        }
        KeyCode::Char('u') if k.modifiers.contains(KeyModifiers::CONTROL) => {
            m.gate_input.clear();
            m.gate_note = None;
            Vec::new()
        }
        KeyCode::Char(c) if !k.modifiers.contains(KeyModifiers::CONTROL) => {
            if m.gate_input.chars().count() < 64 {
                m.gate_input.push(c);
            }
            m.gate_note = None;
            Vec::new()
        }
        KeyCode::Enter => {
            let Some(a) = m.focused().cloned() else {
                m.screen = Screen::Dashboard;
                return Vec::new();
            };
            // Only the exact word continues; anything else says so and
            // does nothing (the core checks the word again).
            if m.gate_input != a.gate {
                m.gate_note = Some(format!("Only the exact word \"{}\" continues.", a.gate));
                return Vec::new();
            }
            let word = std::mem::take(&mut m.gate_input);
            m.screen = Screen::Dashboard;
            let label = a.label.clone();
            m.send(
                Req::Execute {
                    action: a.id,
                    basis: a.basis,
                    word,
                    handoff: a.handoff,
                    cancel: a.cancel,
                },
                a.cancel,
                &label,
            )
        }
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::crossterm::event::KeyEventState;

    fn press(c: KeyCode) -> Msg {
        Msg::Key(KeyEvent {
            code: c,
            modifiers: KeyModifiers::NONE,
            kind: KeyEventKind::Press,
            state: KeyEventState::NONE,
        })
    }
    fn ctrlk(c: char) -> Msg {
        Msg::Key(KeyEvent {
            code: KeyCode::Char(c),
            modifiers: KeyModifiers::CONTROL,
            kind: KeyEventKind::Press,
            state: KeyEventState::NONE,
        })
    }
    fn rec(ty: &str, f: &[(&str, &str)]) -> Record {
        Record {
            ty: ty.into(),
            fields: f
                .iter()
                .map(|(k, v)| (k.to_string(), v.as_bytes().to_vec()))
                .collect(),
        }
    }
    fn result(status: &str, code: &str) -> Record {
        rec(
            "result",
            &[
                ("status", status),
                ("code", code),
                ("text", ""),
                ("next", ""),
            ],
        )
    }
    fn action(id: &str, gate: &str, handoff: bool) -> Record {
        rec(
            "action",
            &[
                ("id", id),
                ("scope", "journey"),
                ("label", id),
                ("intent", if gate.is_empty() { "read" } else { "act" }),
                ("gate", gate),
                ("terminal", if handoff { "handoff" } else { "managed" }),
                ("cancel", if gate.is_empty() { "1" } else { "0" }),
                ("basis", &"ab".repeat(32)),
                ("explain", ""),
            ],
        )
    }
    fn ready() -> Model {
        let mut m = Model::default();
        assert_eq!(m.start(), vec![Cmd::Send(Req::Hello)]);
        let hello = rec(
            "hello",
            &[("core", "0.2.0"), ("platform", "macos"), ("fixture", "1")],
        );
        let c = update(
            &mut m,
            Msg::Done(
                Req::Hello,
                Outcome::Answer(vec![hello, result("done", "ok")]),
            ),
        );
        assert_eq!(c, vec![Cmd::Send(Req::Snapshot)]);
        let snap = vec![
            action("test.read", "", false),
            action("test.mutate", "test", false),
            action("test.handoff", "test", true),
            result("done", "ok"),
        ];
        update(&mut m, Msg::Done(Req::Snapshot, Outcome::Answer(snap)));
        assert_eq!(m.screen, Screen::Dashboard);
        m
    }

    #[test]
    fn handshake_then_snapshot() {
        let m = ready();
        assert_eq!(m.snap.as_ref().unwrap().actions.len(), 3);
        assert!(m.hello.as_ref().unwrap().fixture);
    }

    #[test]
    fn a_version_refusal_falls_back_to_text() {
        let mut m = Model::default();
        m.start();
        let res = rec(
            "result",
            &[
                ("status", "refused"),
                ("code", "frontend"),
                ("text", "lock names 0.2.0"),
                ("next", ""),
            ],
        );
        let c = update(&mut m, Msg::Done(Req::Hello, Outcome::Answer(vec![res])));
        assert_eq!(c, vec![Cmd::Quit(10, "lock names 0.2.0".into())]);
    }

    #[test]
    fn an_inexact_word_never_submits() {
        let mut m = ready();
        update(&mut m, press(KeyCode::Down));
        assert_eq!(update(&mut m, press(KeyCode::Enter)), vec![]);
        assert_eq!(m.screen, Screen::Gate);
        for w in ["TEST", "tes", "test ", "testt"] {
            m.gate_input = w.into();
            assert_eq!(update(&mut m, press(KeyCode::Enter)), vec![], "{w}");
            assert!(m.gate_note.as_ref().unwrap().contains("exact word"));
            assert_eq!(m.screen, Screen::Gate);
        }
        m.gate_input.clear();
        for c in "test".chars() {
            update(&mut m, press(KeyCode::Char(c)));
        }
        let c = update(&mut m, press(KeyCode::Enter));
        assert_eq!(
            c,
            vec![Cmd::Send(Req::Execute {
                action: "test.mutate".into(),
                basis: "ab".repeat(32),
                word: "test".into(),
                handoff: false,
                cancel: false
            })]
        );
    }

    #[test]
    fn letters_in_the_gate_field_are_text_not_commands() {
        let mut m = ready();
        update(&mut m, press(KeyCode::Down));
        update(&mut m, press(KeyCode::Enter));
        for c in ['q', 'r', 'L', '?', 'j'] {
            assert_eq!(update(&mut m, press(KeyCode::Char(c))), vec![]);
        }
        assert_eq!(m.gate_input, "qrL?j");
        assert_eq!(m.screen, Screen::Gate);
        update(&mut m, ctrlk('u'));
        assert_eq!(m.gate_input, "");
        update(&mut m, press(KeyCode::Esc));
        assert_eq!(m.screen, Screen::Dashboard);
    }

    #[test]
    fn handoff_is_requested_only_for_handoff_actions() {
        let mut m = ready();
        let c = update(&mut m, press(KeyCode::Enter));
        assert!(matches!(
            &c[..],
            [Cmd::Send(Req::Execute { handoff: false, .. })]
        ));
        let mut m = ready();
        m.focus = 2;
        update(&mut m, press(KeyCode::Enter));
        m.gate_input = "test".into();
        let c = update(&mut m, press(KeyCode::Enter));
        assert!(matches!(
            &c[..],
            [Cmd::Send(Req::Execute { handoff: true, .. })]
        ));
    }

    #[test]
    fn the_basis_shown_is_the_basis_sent() {
        let mut m = ready();
        let c = update(&mut m, press(KeyCode::Enter));
        let Cmd::Send(Req::Execute { basis, .. }) = &c[0] else {
            panic!()
        };
        assert_eq!(basis, &m.snap.as_ref().unwrap().actions[0].basis);
    }

    #[test]
    fn every_action_is_followed_by_a_fresh_read() {
        let mut m = ready();
        let req = match update(&mut m, press(KeyCode::Enter)).remove(0) {
            Cmd::Send(r) => r,
            _ => panic!(),
        };
        let c = update(
            &mut m,
            Msg::Done(req, Outcome::Answer(vec![result("done", "ok")])),
        );
        assert_eq!(c, vec![Cmd::Send(Req::Snapshot)]);
        assert_eq!(m.status.as_ref().unwrap().0, Level::Ok);
    }

    #[test]
    fn a_missing_result_is_unknown_never_failed() {
        let mut m = ready();
        let req = match update(&mut m, press(KeyCode::Enter)).remove(0) {
            Cmd::Send(r) => r,
            _ => panic!(),
        };
        let c = update(&mut m, Msg::Done(req, Outcome::Unknown("no result".into())));
        assert_eq!(c, vec![Cmd::Send(Req::Snapshot)]);
        let (lvl, s) = m.status.clone().unwrap();
        assert_eq!(lvl, Level::Warn);
        assert!(s.contains("without a complete answer"));
        assert!(!s.contains("failed"));
    }

    #[test]
    fn unsupervised_is_shown_as_unknown() {
        let mut m = ready();
        let req = Req::Execute {
            action: "test.mutate".into(),
            basis: String::new(),
            word: "test".into(),
            handoff: false,
            cancel: false,
        };
        m.pending = Some(Pending {
            req: req.clone(),
            cancellable: false,
            label: String::new(),
            ticks: 0,
        });
        update(
            &mut m,
            Msg::Done(
                req,
                Outcome::Answer(vec![result("stopped", "unsupervised")]),
            ),
        );
        assert!(m.status.as_ref().unwrap().1.contains("outcome unknown"));
    }

    #[test]
    fn ctrl_c_quits_idle_cancels_what_it_may() {
        let mut m = ready();
        assert_eq!(
            update(&mut m, ctrlk('c')),
            vec![Cmd::Quit(0, String::new())]
        );
        let mut m = ready();
        update(&mut m, press(KeyCode::Enter));
        assert_eq!(update(&mut m, ctrlk('c')), vec![Cmd::Cancel]);
        let mut m = ready();
        m.pending = Some(Pending {
            req: Req::Snapshot,
            cancellable: false,
            label: String::new(),
            ticks: 0,
        });
        assert_eq!(update(&mut m, ctrlk('c')), vec![]);
    }

    #[test]
    fn ctrl_z_is_refused_while_a_request_runs() {
        let mut m = ready();
        assert_eq!(update(&mut m, ctrlk('z')), vec![Cmd::Suspend]);
        update(&mut m, press(KeyCode::Enter));
        assert_eq!(update(&mut m, ctrlk('z')), vec![]);
    }

    #[test]
    fn terminate_waits_for_a_non_cancellable_request() {
        let mut m = ready();
        m.pending = Some(Pending {
            req: Req::Snapshot,
            cancellable: false,
            label: String::new(),
            ticks: 0,
        });
        assert_eq!(update(&mut m, Msg::Terminate), vec![]);
        let c = update(
            &mut m,
            Msg::Done(Req::Snapshot, Outcome::Answer(vec![result("done", "ok")])),
        );
        assert_eq!(c, vec![Cmd::Quit(0, String::new())]);
    }

    #[test]
    fn messages_are_bounded() {
        let mut m = ready();
        for _ in 0..(MESSAGES_MAX + 20) {
            update(
                &mut m,
                Msg::Live(rec("message", &[("level", "info"), ("text", "x")])),
            );
        }
        assert_eq!(m.messages.len(), MESSAGES_MAX);
    }
}
