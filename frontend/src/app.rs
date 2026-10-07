//! The model, its messages and `update` (docs/FRONTEND.md → *Event loop and
//! state*). `update` is a pure function of the model and one message: it
//! performs no I/O and returns the commands the event loop carries out. The
//! model keeps the last snapshot to draw from — a view, never the truth —
//! and asks again after every action, on `r`, and after a handoff or a
//! suspend. An action is always submitted with the basis it was shown.
//!
//! The read surface (docs/PROTOCOL.md → *The Gate 2 read surface*): each
//! screen asks for what it shows the first time it is opened, one request at
//! a time; a detail is always opened from its scope's last snapshot and names
//! that generation; moving, scrolling and filtering what is loaded never ask
//! the core anything (docs/DECISIONS.md → *Resolved review questions*, O1).

use crate::read::{Checked, Detail, Fault, Kind, LIMIT, Land, Page, Scope};
use crate::record::Record;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

/// What the core said about itself and the session (the hello record).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Hello {
    pub core: String,
    pub commit: String,
    pub proto: String,
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

/// A snapshot of one scope, as the model keeps it to draw from.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    pub facts: Vec<Fact>,
    pub blockers: Vec<Blocker>,
    pub actions: Vec<Action>,
    pub stages: Vec<(String, String)>,
    /// The data set this snapshot read: compared for equality, nothing else.
    pub generation: String,
    /// The core's guide: the next step, in its own words.
    pub guides: Vec<String>,
    /// Codes (kind, value), such as the resume token.
    pub codes: Vec<(String, String)>,
    pub warnings: Vec<Blocker>,
    pub messages: Vec<(Level, String)>,
}

/// A request the event loop sends to a fresh core.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Req {
    Hello,
    /// The journey scope's snapshot.
    Snapshot,
    /// The snapshot of another read scope (health or logs).
    Read(Scope),
    /// One page of a detail kind, from the generation it was opened from.
    Detail(Page),
    /// `validate select action=plan.save`: the sizes are sent as typed and
    /// judged by the core alone; an empty field is not sent at all.
    Validate {
        linux_size: String,
        shared_size: String,
    },
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
    /// The core's state could not be read: it may still be running, and
    /// nothing will say when it ends.
    Lost(String),
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
    /// Screen 1: this machine, the tool and the core, the session.
    Welcome,
    /// Screen 2: the journey dashboard.
    Dashboard,
    /// The journey's machine detail.
    Machine,
    /// The journey's status detail.
    Status,
    /// Screen 22, as Gate 2 has it: the doctor's counts and findings.
    Health,
    /// Screen 24: the tool's log and the core's diagnostics.
    Logs,
    /// A read-only check of the plan's sizes.
    Plan,
    Gate,
    Help,
    /// The core could not be reached or answered with an error.
    Fatal,
}

/// The navigation rail's screens, in order.
pub const NAV: [Screen; 7] = [
    Screen::Welcome,
    Screen::Dashboard,
    Screen::Machine,
    Screen::Status,
    Screen::Health,
    Screen::Logs,
    Screen::Plan,
];

impl Screen {
    /// The screen's name, as the title rule and the rail show it.
    pub fn title(self) -> &'static str {
        match self {
            Screen::Connecting => "Connecting",
            Screen::Welcome => "Welcome",
            Screen::Dashboard => "Journey",
            Screen::Machine => "Machine",
            Screen::Status => "Status",
            Screen::Health => "Health",
            Screen::Logs => "Logs",
            Screen::Plan => "Plan check",
            Screen::Gate => "Gate",
            Screen::Help => "Keys",
            Screen::Fatal => "No answer",
        }
    }

    /// The detail kind a screen pages, if any.
    pub fn kind(self) -> Option<Kind> {
        match self {
            Screen::Machine => Some(Kind::Machine),
            Screen::Status => Some(Kind::Status),
            Screen::Health => Some(Kind::Doctor),
            Screen::Logs => Some(Kind::Log),
            _ => None,
        }
    }
}

/// Which part of the frame has the keys.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Region {
    Nav,
    Work,
}

/// The two sources the Logs screen shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogsTab {
    /// The tool's log, as `logs` selects it.
    Tool,
    /// The core's diagnostics kept in this session.
    Diagnostics,
}

/// One scope's read (health, logs): its last snapshot and why there is no
/// current one.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ScopeRead {
    pub snap: Option<Snapshot>,
    /// The earlier snapshot the rows shown came from, kept when a newer one
    /// arrived before any of its rows. The frame draws the facts of whichever
    /// of the two has the rows' generation, so a newer snapshot's facts never
    /// head an earlier read's rows.
    pub held: Option<Snapshot>,
    pub fault: Option<Fault>,
    /// Asked for at least once: it is read again only on `r`.
    pub asked: bool,
}

/// The plan check's form: the two sizes as typed, which field has the keys,
/// and the core's last answer.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PlanForm {
    pub linux: String,
    pub shared: String,
    /// 0 the Linux size, 1 the Shared size.
    pub field: usize,
    pub checked: Option<Checked>,
    pub fault: Option<Fault>,
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
    /// Where help or the gate returns to.
    pub back: Screen,
    pub hello: Option<Hello>,
    /// The journey snapshot.
    pub snap: Option<Snapshot>,
    /// The focused action of the journey snapshot.
    pub focus: usize,
    pub gate_input: String,
    pub gate_note: Option<String>,
    pub status: Option<(Level, String)>,
    pub pending: Option<Pending>,
    pub progress: Option<(String, u64, u64)>,
    pub messages: Vec<(Level, String)>,
    pub fatal: String,
    /// The core's diagnostics kept in this session (read locally).
    pub logs: Vec<String>,
    /// The diagnostics' scroll.
    pub scroll: usize,
    pub quit_after: bool,
    pub asked_quit: bool,
    /// The interface lost track of a core: it starts nothing more.
    pub lost: bool,
    /// A startup-check session (`OMB_SESSION_PURPOSE=frontend-check`, which
    /// the frontend passes through and never sets): its contract answers
    /// `hello` and the journey snapshot alone (docs/PROTOCOL.md → *The
    /// startup-check session*), so nothing else is ever asked of it.
    pub check: bool,
    pub region: Region,
    /// The rail's cursor.
    pub nav: usize,
    /// The sidebar's panels shown in place of the workspace (narrow widths).
    pub side: bool,
    /// The details opened, by kind.
    pub details: [Option<Detail>; 4],
    pub health: ScopeRead,
    pub logread: ScopeRead,
    pub logs_tab: LogsTab,
    pub plan: PlanForm,
    /// A detail to reopen once its scope's fresh snapshot is in (`r`).
    pub reopen: Option<Kind>,
    /// The rows asked for per page.
    pub limit: u64,
    /// The first block shown of the dashboard, the Welcome screen and help.
    pub dash_scroll: usize,
    pub welcome_scroll: usize,
    pub help_scroll: usize,
    pub plan_scroll: usize,
}

/// What the event loop does next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Cmd {
    Send(Req),
    /// SIGTERM to the core of a cancellable request.
    Cancel,
    Suspend,
    /// Read the session's kept diagnostics (local files, never a core).
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

/// Rows moved by PgUp and PgDn.
pub const PAGE_STEP: usize = 10;

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
            lost: false,
            check: false,
            region: Region::Work,
            nav: 1,
            side: false,
            details: [None, None, None, None],
            health: ScopeRead::default(),
            logread: ScopeRead::default(),
            logs_tab: LogsTab::Tool,
            plan: PlanForm::default(),
            reopen: None,
            limit: LIMIT,
            dash_scroll: 0,
            welcome_scroll: 0,
            help_scroll: 0,
            plan_scroll: 0,
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

    pub fn detail(&self, k: Kind) -> Option<&Detail> {
        self.details[k.index()].as_ref()
    }

    fn detail_mut(&mut self, k: Kind) -> Option<&mut Detail> {
        self.details[k.index()].as_mut()
    }

    /// The read of a scope other than the journey.
    pub fn scope(&self, s: Scope) -> &ScopeRead {
        match s {
            Scope::Logs => &self.logread,
            _ => &self.health,
        }
    }

    fn scope_mut(&mut self, s: Scope) -> &mut ScopeRead {
        match s {
            Scope::Logs => &mut self.logread,
            _ => &mut self.health,
        }
    }

    /// The generation of a scope's last snapshot.
    pub fn generation(&self, s: Scope) -> Option<&str> {
        let snap = match s {
            Scope::Journey => self.snap.as_ref(),
            _ => self.scope(s).snap.as_ref(),
        };
        snap.map(|s| s.generation.as_str())
            .filter(|g| !g.is_empty())
    }

    /// Whether the request in flight is REQ's kind of read for this view.
    pub fn reading(&self, f: impl Fn(&Req) -> bool) -> bool {
        self.pending.as_ref().is_some_and(|p| f(&p.req))
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
        self.send(Req::Snapshot, true, "reading the journey")
    }

    fn read(&mut self, s: Scope) -> Vec<Cmd> {
        self.scope_mut(s).asked = true;
        let label = match s {
            Scope::Logs => "reading the log",
            _ => "reading health",
        };
        self.send(Req::Read(s), true, label)
    }

    fn page(&mut self, p: Page, land: Land) -> Vec<Cmd> {
        let label = p.kind.reading();
        if let Some(d) = self.detail_mut(p.kind) {
            d.land = land;
        }
        self.send(Req::Detail(p), true, label)
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
            "generation" => s.generation = text(r, "id"),
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
            "warning" => s.warnings.push(Blocker {
                text: text(r, "text"),
                fix: text(r, "fix"),
            }),
            "guide" => s.guides.push(text(r, "text")),
            "code" => s.codes.push((text(r, "kind"), text(r, "value"))),
            "message" => s
                .messages
                .push((level_of(r.text("level").unwrap_or("")), text(r, "text"))),
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
        commit: text(r, "commit"),
        proto: text(r, "proto"),
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
                let code = if m.lost { 1 } else { 0 };
                return vec![Cmd::Quit(code, String::new())];
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

/// What the screen shown still needs read, when nothing runs: a screen asks
/// for its data the first time it is opened, and a failed read is not
/// repeated by itself — the person asks with `r`.
fn demand(m: &mut Model) -> Vec<Cmd> {
    if m.pending.is_some() || m.lost || m.check {
        return Vec::new();
    }
    let kind = match m.screen {
        Screen::Logs if m.logs_tab == LogsTab::Diagnostics => return Vec::new(),
        s => match s.kind() {
            Some(k) => k,
            None => return Vec::new(),
        },
    };
    let scope = kind.scope();
    if scope != Scope::Journey && !m.scope(scope).asked {
        return m.read(scope);
    }
    if m.detail(kind).is_some() {
        return Vec::new();
    }
    let Some(id) = m.generation(scope).map(str::to_string) else {
        return Vec::new();
    };
    let d = Detail::new(kind, &id);
    let p = d.page(0, m.limit);
    m.details[kind.index()] = Some(d);
    m.page(p, Land::First)
}

/// Quit if asked to; otherwise what the screen still needs.
fn settle(m: &mut Model, cmds: Vec<Cmd>) -> Vec<Cmd> {
    if m.quit_after {
        return vec![Cmd::Quit(0, String::new())];
    }
    if cmds.is_empty() {
        return demand(m);
    }
    cmds
}

/// A fresh snapshot of SCOPE arrived with generation ID: a detail opened
/// from another generation is changed — never silently replaced — unless the
/// person asked for it to be reopened, which happens now.
fn regenerated(m: &mut Model, scope: Scope, id: &str) -> Vec<Cmd> {
    let reopen = m.reopen.take();
    let limit = m.limit;
    let mut fresh = None;
    for k in Kind::ALL.into_iter().filter(|k| k.scope() == scope) {
        let Some(d) = m.detail_mut(k) else { continue };
        let moved = d.generation != id;
        if reopen == Some(k) && (moved || d.changed || d.fault.is_some() || !d.loaded) {
            // The rows shown stay, under their own generation, until a page
            // of the fresh one is admitted.
            fresh = Some(Page {
                kind: k,
                generation: id.to_string(),
                offset: 0,
                limit,
            });
        } else if moved {
            d.changed = true;
        }
    }
    match fresh {
        Some(p) => m.page(p, Land::First),
        None => Vec::new(),
    }
}

fn done(m: &mut Model, req: Req, outcome: Outcome) -> Vec<Cmd> {
    m.pending = None;
    m.progress = None;
    let records = match outcome {
        Outcome::Answer(r) => r,
        Outcome::Lost(why) => {
            // No request starts again in this session: the launcher, which
            // reads the recorded identities itself, decides what is safe.
            m.lost = true;
            m.screen = Screen::Fatal;
            m.fatal = format!(
                "The interface lost track of the core ({why}), so it starts nothing more. ./omarchy-bootstrap status shows where the machine is."
            );
            if m.quit_after {
                return vec![Cmd::Quit(1, m.fatal.clone())];
            }
            return Vec::new();
        }
        Outcome::Unknown(why) => return unknown(m, req, why),
        Outcome::NotSent(why) => return not_sent(m, req, why),
    };
    let Some((status, code, text, next)) = result_of(&records) else {
        return unknown(m, req, "no result".into());
    };
    match req {
        Req::Hello => {
            if status == "done" {
                m.hello = hello_of(&records);
                let c = m.refresh();
                return settle(m, c);
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
                let id = s.generation.clone();
                m.snap = Some(s);
                if matches!(m.screen, Screen::Connecting | Screen::Fatal) {
                    m.screen = Screen::Dashboard;
                }
                let c = regenerated(m, Scope::Journey, &id);
                return settle(m, c);
            }
            m.reopen = None;
            if m.snap.is_none() {
                // Nothing to show at all: say why, and let the person leave.
                let why = if text.is_empty() { code } else { text };
                return vec![Cmd::Quit(10, why)];
            }
            m.status = Some((Level::Warn, if text.is_empty() { code } else { text }));
            settle(m, Vec::new())
        }
        Req::Read(scope) => {
            let c = if status == "done" {
                let s = snapshot_of(&records);
                let id = s.generation.clone();
                // The rows shown keep the snapshot they came with until rows
                // of the new one are admitted.
                let shown = Kind::ALL
                    .into_iter()
                    .filter(|k| k.scope() == scope)
                    .find_map(|k| m.detail(k).filter(|d| d.loaded))
                    .map(|d| d.generation.clone());
                let r = m.scope_mut(scope);
                let old = r.snap.replace(s);
                r.held = [old, r.held.take()]
                    .into_iter()
                    .flatten()
                    .find(|o| o.generation != id && Some(&o.generation) == shown.as_ref());
                r.fault = None;
                regenerated(m, scope, &id)
            } else {
                // A refused or failed read supplies no data set: the last
                // one stays, with the core's words beside it.
                m.reopen = None;
                m.scope_mut(scope).fault = Some(Fault::Said { status, code, text });
                Vec::new()
            };
            settle(m, c)
        }
        Req::Detail(p) => {
            let kind = p.kind;
            if m.detail(kind).is_none() {
                m.details[kind.index()] = Some(Detail::new(kind, &p.generation));
            }
            let d = m.detail_mut(kind).expect("made above");
            match (status.as_str(), code.as_str()) {
                ("done", _) => match crate::read::generation(&records) {
                    Some((id, total)) if id == p.generation => {
                        d.rows = crate::read::rows(&records, kind);
                        d.total = total;
                        d.offset = p.offset;
                        d.generation = p.generation;
                        d.loaded = true;
                        d.changed = false;
                        d.fault = None;
                        close_value(d);
                        let n = d.shown().len();
                        d.cursor = match d.land {
                            Land::First => 0,
                            Land::Last => n.saturating_sub(1),
                        };
                    }
                    // Rows of another data set are never shown as this one's.
                    _ => d.changed = true,
                },
                ("refused", "changed") => {
                    d.changed = true;
                    d.fault = None;
                }
                _ => {
                    // The rows shown, if any, are still the older data set's.
                    if d.loaded && d.generation != p.generation {
                        d.changed = true;
                    }
                    d.fault = Some(Fault::Said { status, code, text });
                }
            }
            settle(m, Vec::new())
        }
        Req::Validate {
            linux_size,
            shared_size,
        } => {
            m.plan.checked = Some(Checked::of(&records, &linux_size, &shared_size));
            m.plan.fault = None;
            settle(m, Vec::new())
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
            settle(m, c)
        }
    }
}

/// A request ended without a complete answer: never "failed", never
/// "nothing happened". After an action the machine is read again; a read
/// that itself ended without an answer is not repeated by itself.
fn unknown(m: &mut Model, req: Req, why: String) -> Vec<Cmd> {
    let fault = Fault::NoAnswer(why.clone());
    match req {
        Req::Hello => {
            m.screen = Screen::Fatal;
            m.fatal = format!("The core stopped without a complete answer ({why}).");
            settle(m, Vec::new())
        }
        Req::Snapshot if m.snap.is_none() => {
            m.screen = Screen::Fatal;
            m.fatal = format!("The core stopped without a complete answer ({why}).");
            settle(m, Vec::new())
        }
        Req::Snapshot => {
            m.reopen = None;
            m.status = Some((
                Level::Warn,
                format!("The core stopped without a complete answer ({why}); r reads again."),
            ));
            settle(m, Vec::new())
        }
        Req::Read(s) => {
            m.reopen = None;
            m.scope_mut(s).fault = Some(fault);
            settle(m, Vec::new())
        }
        Req::Detail(p) => {
            if let Some(d) = m.detail_mut(p.kind) {
                d.fault = Some(fault);
            }
            settle(m, Vec::new())
        }
        Req::Validate { .. } => {
            m.plan.fault = Some(fault);
            settle(m, Vec::new())
        }
        Req::Execute { .. } => {
            m.status = Some((
                Level::Warn,
                format!(
                    "The core stopped without a complete answer ({why}); reading the machine again."
                ),
            ));
            let c = m.refresh();
            settle(m, c)
        }
    }
}

fn not_sent(m: &mut Model, req: Req, why: String) -> Vec<Cmd> {
    let fault = Fault::NotSent(why.clone());
    match req {
        Req::Hello => {
            m.screen = Screen::Fatal;
            m.fatal = format!("The core could not be started ({why}).");
        }
        Req::Read(s) => {
            m.reopen = None;
            m.scope_mut(s).fault = Some(fault);
        }
        Req::Detail(p) => {
            if let Some(d) = m.detail_mut(p.kind) {
                d.fault = Some(fault);
            }
        }
        Req::Validate { .. } => m.plan.fault = Some(fault),
        Req::Snapshot | Req::Execute { .. } => {
            m.reopen = None;
            m.status = Some((
                Level::Fail,
                format!("The request was not delivered ({why}); nothing ran."),
            ));
        }
    }
    settle(m, Vec::new())
}

fn ctrl(k: &KeyEvent, c: char) -> bool {
    k.modifiers.contains(KeyModifiers::CONTROL) && k.code == KeyCode::Char(c)
}

/// The detail shown on this screen, if its filter field has the keys.
fn editing(m: &Model) -> Option<Kind> {
    let k = m.screen.kind()?;
    (m.region == Region::Work
        && !(m.screen == Screen::Logs && m.logs_tab == LogsTab::Diagnostics)
        && m.detail(k).is_some_and(|d| d.editing))
    .then_some(k)
}

/// The detail shown on SCREEN, if any (the Logs screen's diagnostics show none).
fn shown_detail(m: &Model, s: Screen) -> Option<&Detail> {
    let k = s.kind()?;
    if s == Screen::Logs && m.logs_tab == LogsTab::Diagnostics {
        return None;
    }
    m.detail(k)
}

/// Whether the detail shown on SCREEN has its full values open: their keys
/// apply there (keys::Place::Value).
pub fn value_open(m: &Model, s: Screen) -> bool {
    shown_detail(m, s).is_some_and(|d| d.open)
}

fn close_value(d: &mut Detail) {
    d.open = false;
    d.value_top.set(0);
}

/// A text field has the keys: the plan's sizes or a filter.
fn typing(m: &Model) -> bool {
    (m.screen == Screen::Plan && m.region == Region::Work && !m.check) || editing(m).is_some()
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
            None if m.lost => vec![Cmd::Quit(1, m.fatal.clone())],
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
        Screen::Help => {
            match k.code {
                KeyCode::Esc | KeyCode::Char('q') | KeyCode::Char('?') => m.screen = m.back,
                KeyCode::Down | KeyCode::Char('j') => m.help_scroll += 1,
                KeyCode::Up | KeyCode::Char('k') => m.help_scroll = m.help_scroll.saturating_sub(1),
                _ => {}
            }
            let n =
                crate::keys::help_for(m.back, m.region, m.logs_tab, value_open(m, m.back), true)
                    .len();
            m.help_scroll = m.help_scroll.min(n.saturating_sub(1));
            Vec::new()
        }
        Screen::Fatal => match k.code {
            KeyCode::Char('q') | KeyCode::Esc if m.lost => vec![Cmd::Quit(1, m.fatal.clone())],
            KeyCode::Char('q') | KeyCode::Esc => vec![Cmd::Quit(10, m.fatal.clone())],
            KeyCode::Char('r') if m.pending.is_none() && !m.lost => m.start(),
            _ => Vec::new(),
        },
        Screen::Connecting => match k.code {
            KeyCode::Char('q') => vec![Cmd::Quit(0, String::new())],
            _ => Vec::new(),
        },
        _ => main_key(m, k),
    }
}

/// Open SCREEN in the workspace, and read what it needs if this is its
/// first time.
fn open(m: &mut Model, s: Screen) -> Vec<Cmd> {
    m.screen = s;
    m.region = Region::Work;
    m.side = false;
    if let Some(i) = NAV.iter().position(|n| *n == s) {
        m.nav = i;
    }
    let mut cmds = Vec::new();
    if s == Screen::Logs && m.logs_tab == LogsTab::Diagnostics {
        cmds.push(Cmd::ReadLogs);
    }
    cmds.extend(demand(m));
    cmds
}

/// The keys of every main screen: a field first, then the frame's keys,
/// then the focused region's.
fn main_key(m: &mut Model, k: KeyEvent) -> Vec<Cmd> {
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
    if typing(m) {
        if let Some(c) = field_key(m, &k) {
            return c;
        }
    }
    match k.code {
        KeyCode::Char('?') => {
            m.back = m.screen;
            m.help_scroll = 0;
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
        KeyCode::Char('r') => refresh(m),
        KeyCode::Char('L') => {
            let mut c = vec![Cmd::ReadLogs];
            c.extend(open(m, Screen::Logs));
            c.dedup();
            c
        }
        KeyCode::Char('s') => {
            m.side = !m.side;
            Vec::new()
        }
        KeyCode::Left => {
            m.region = Region::Nav;
            m.nav = NAV.iter().position(|n| *n == m.screen).unwrap_or(m.nav);
            Vec::new()
        }
        KeyCode::Right if m.region == Region::Nav => open(m, NAV[m.nav]),
        KeyCode::Tab if m.screen == Screen::Logs && m.region == Region::Work => {
            m.logs_tab = match m.logs_tab {
                LogsTab::Tool => LogsTab::Diagnostics,
                LogsTab::Diagnostics => LogsTab::Tool,
            };
            if m.logs_tab == LogsTab::Diagnostics {
                return vec![Cmd::ReadLogs];
            }
            demand(m)
        }
        KeyCode::Tab | KeyCode::BackTab => {
            m.region = match m.region {
                Region::Nav => Region::Work,
                Region::Work => {
                    m.nav = NAV.iter().position(|n| *n == m.screen).unwrap_or(m.nav);
                    Region::Nav
                }
            };
            Vec::new()
        }
        KeyCode::Esc => {
            if m.side {
                m.side = false;
            } else if m.region == Region::Nav {
                m.region = Region::Work;
            } else if value_open(m, m.screen) {
                let k = m.screen.kind().expect("a detail is shown");
                close_value(m.detail_mut(k).expect("a detail is shown"));
            } else if m.screen != Screen::Dashboard {
                m.screen = Screen::Dashboard;
                m.nav = 1;
            }
            Vec::new()
        }
        _ => match m.region {
            Region::Nav => nav_key(m, k),
            Region::Work => match m.screen {
                Screen::Dashboard => dashboard_key(m, k),
                Screen::Welcome => {
                    if k.code == KeyCode::Enter {
                        return open(m, Screen::Dashboard);
                    }
                    let n = crate::screens::blocks(m, Screen::Welcome);
                    scroll_key(&mut m.welcome_scroll, n, &k);
                    Vec::new()
                }
                Screen::Logs if m.logs_tab == LogsTab::Diagnostics => {
                    let n = m.logs.len();
                    scroll_key(&mut m.scroll, n, &k);
                    Vec::new()
                }
                s => match s.kind() {
                    Some(kind) => table_key(m, kind, k),
                    None => Vec::new(),
                },
            },
        },
    }
}

/// Up, down, a page, the ends: over N blocks, bounded here.
fn scroll_key(at: &mut usize, n: usize, k: &KeyEvent) {
    let last = n.saturating_sub(1);
    *at = match k.code {
        KeyCode::Down | KeyCode::Char('j') => *at + 1,
        KeyCode::Up | KeyCode::Char('k') => at.saturating_sub(1),
        KeyCode::PageDown => *at + PAGE_STEP,
        KeyCode::PageUp => at.saturating_sub(PAGE_STEP),
        KeyCode::Home | KeyCode::Char('g') => 0,
        KeyCode::End | KeyCode::Char('G') => last,
        _ => *at,
    }
    .min(last);
}

fn nav_key(m: &mut Model, k: KeyEvent) -> Vec<Cmd> {
    let last = NAV.len() - 1;
    match k.code {
        KeyCode::Down | KeyCode::Char('j') => m.nav = (m.nav + 1).min(last),
        KeyCode::Up | KeyCode::Char('k') => m.nav = m.nav.saturating_sub(1),
        KeyCode::Home | KeyCode::Char('g') => m.nav = 0,
        KeyCode::End | KeyCode::Char('G') => m.nav = last,
        KeyCode::Enter => return open(m, NAV[m.nav]),
        _ => {}
    }
    Vec::new()
}

/// `r`: the read refresh of what this screen shows. A detail is reopened
/// from its scope's fresh snapshot, the rows shown staying until the fresh
/// page is admitted.
fn refresh(m: &mut Model) -> Vec<Cmd> {
    if m.pending.is_some() {
        m.status = Some((
            Level::Info,
            "One thing at a time: this runs once the current request ends.".into(),
        ));
        return Vec::new();
    }
    match m.screen {
        Screen::Logs if m.logs_tab == LogsTab::Diagnostics => vec![Cmd::ReadLogs],
        Screen::Plan => match &m.plan.checked {
            Some(c) if !m.check => {
                let (l, s) = (c.linux.clone(), c.shared.clone());
                validate(m, l, s)
            }
            _ => Vec::new(),
        },
        s => match s.kind() {
            Some(k) if !m.check => {
                m.reopen = Some(k);
                match k.scope() {
                    Scope::Journey => m.refresh(),
                    scope => m.read(scope),
                }
            }
            Some(_) => Vec::new(),
            None => m.refresh(),
        },
    }
}

fn validate(m: &mut Model, linux_size: String, shared_size: String) -> Vec<Cmd> {
    m.send(
        Req::Validate {
            linux_size,
            shared_size,
        },
        true,
        "checking the plan",
    )
}

/// A text field's keys: typed text, Backspace, Ctrl-U, Enter, Esc — and for
/// the plan's sizes, Tab between them. None: not a field key (the frame's
/// arrows and Tab keep their meaning).
fn field_key(m: &mut Model, k: &KeyEvent) -> Option<Vec<Cmd>> {
    if let Some(kind) = editing(m) {
        let d = m.detail_mut(kind).expect("editing");
        match k.code {
            KeyCode::Char('u') if k.modifiers.contains(KeyModifiers::CONTROL) => d.filter.clear(),
            KeyCode::Char(c) if !k.modifiers.contains(KeyModifiers::CONTROL) => {
                if d.filter.chars().count() < 64 {
                    d.filter.push(c);
                }
            }
            KeyCode::Backspace => {
                d.filter.pop();
            }
            KeyCode::Enter => d.editing = false,
            KeyCode::Esc => {
                d.filter.clear();
                d.editing = false;
            }
            _ => return None,
        }
        let n = d.shown().len();
        d.cursor = d.cursor.min(n.saturating_sub(1));
        return Some(Vec::new());
    }
    if matches!(
        k.code,
        KeyCode::PageUp | KeyCode::PageDown | KeyCode::Home | KeyCode::End
    ) {
        // The answer scrolls; the fields keep the typing keys.
        let n = crate::screens::blocks(m, Screen::Plan);
        scroll_key(&mut m.plan_scroll, n, k);
        return Some(Vec::new());
    }
    m.plan_scroll = 0;
    let p = &mut m.plan;
    let field = if p.field == 0 {
        &mut p.linux
    } else {
        &mut p.shared
    };
    match k.code {
        KeyCode::Char('u') if k.modifiers.contains(KeyModifiers::CONTROL) => field.clear(),
        KeyCode::Char(c) if !k.modifiers.contains(KeyModifiers::CONTROL) => {
            if field.chars().count() < 64 {
                field.push(c);
            }
        }
        KeyCode::Backspace => {
            field.pop();
        }
        KeyCode::Tab | KeyCode::Down => p.field = 1,
        KeyCode::BackTab | KeyCode::Up => p.field = 0,
        // Back, as everywhere; the sizes stay as typed.
        KeyCode::Esc => {
            m.screen = Screen::Dashboard;
            m.nav = 1;
        }
        KeyCode::Enter => {
            if m.pending.is_some() {
                m.status = Some((
                    Level::Info,
                    "One thing at a time: this runs once the current request ends.".into(),
                ));
                return Some(Vec::new());
            }
            let (l, s) = (p.linux.clone(), p.shared.clone());
            return Some(validate(m, l, s));
        }
        _ => return None,
    }
    Some(Vec::new())
}

/// The keys of a detail table: the cursor over the rows shown, a page past
/// either end of the loaded one, a filter, and the levels of the log.
fn table_key(m: &mut Model, kind: Kind, k: KeyEvent) -> Vec<Cmd> {
    let limit = m.limit;
    let Some(d) = m.detail_mut(kind) else {
        return Vec::new();
    };
    // An open value has the moving keys: they scroll it, and never a row, a
    // page or the core. Enter (or Esc) closes it.
    if d.open {
        let top = d.value_top.get_mut();
        match k.code {
            KeyCode::Down | KeyCode::Char('j') => *top = top.saturating_add(1),
            KeyCode::Up | KeyCode::Char('k') => *top = top.saturating_sub(1),
            KeyCode::PageDown => *top = top.saturating_add(PAGE_STEP),
            KeyCode::PageUp => *top = top.saturating_sub(PAGE_STEP),
            KeyCode::Home | KeyCode::Char('g') => *top = 0,
            KeyCode::End | KeyCode::Char('G') => *top = usize::MAX,
            KeyCode::Enter => close_value(d),
            _ => {}
        }
        return Vec::new();
    }
    let n = d.shown().len();
    let last = n.saturating_sub(1);
    // Paging asks the core only for a page this view does not hold, and only
    // from the generation it was opened from; a changed view is reopened
    // with r, never paged across generations.
    let fetch = |d: &Detail, p: Option<Page>| {
        p.filter(|_| !d.changed && d.fault.is_none() && d.filter.is_empty() && d.level.is_none())
    };
    let mut want: Option<(Page, Land)> = None;
    match k.code {
        KeyCode::Down | KeyCode::Char('j') => {
            if d.cursor < last {
                d.cursor += 1;
            } else {
                want = fetch(d, d.next(limit)).map(|p| (p, Land::First));
            }
        }
        KeyCode::Up | KeyCode::Char('k') => {
            if d.cursor > 0 {
                d.cursor -= 1;
            } else {
                want = fetch(d, d.prev(limit)).map(|p| (p, Land::Last));
            }
        }
        KeyCode::PageDown => {
            if d.cursor < last {
                d.cursor = (d.cursor + PAGE_STEP).min(last);
            } else {
                want = fetch(d, d.next(limit)).map(|p| (p, Land::First));
            }
        }
        KeyCode::PageUp => {
            if d.cursor > 0 {
                d.cursor = d.cursor.saturating_sub(PAGE_STEP);
            } else {
                want = fetch(d, d.prev(limit)).map(|p| (p, Land::Last));
            }
        }
        KeyCode::Home | KeyCode::Char('g') => {
            d.cursor = 0;
            want = fetch(d, d.first(limit)).map(|p| (p, Land::First));
        }
        KeyCode::End | KeyCode::Char('G') => {
            d.cursor = last;
            want = fetch(d, d.last(limit)).map(|p| (p, Land::Last));
        }
        KeyCode::Enter if n > 0 => d.open = true,
        KeyCode::Char('/') => d.editing = true,
        KeyCode::Char('f') if kind == Kind::Log => {
            let levels = d.levels();
            d.level = match &d.level {
                None => levels.first().cloned(),
                Some(l) => levels
                    .iter()
                    .position(|x| x == l)
                    .and_then(|i| levels.get(i + 1).cloned()),
            };
            d.cursor = 0;
        }
        _ => {}
    }
    match want {
        Some((p, land)) if m.pending.is_none() => m.page(p, land),
        Some(_) => {
            m.status = Some((
                Level::Info,
                "One thing at a time: this runs once the current request ends.".into(),
            ));
            Vec::new()
        }
        None => Vec::new(),
    }
}

fn dashboard_key(m: &mut Model, k: KeyEvent) -> Vec<Cmd> {
    let n = m.snap.as_ref().map_or(0, |s| s.actions.len());
    match k.code {
        KeyCode::Down | KeyCode::Char('j') if n > 0 => {
            m.focus = (m.focus + 1).min(n - 1);
            Vec::new()
        }
        KeyCode::Up | KeyCode::Char('k') if n > 0 => {
            m.focus = m.focus.saturating_sub(1);
            Vec::new()
        }
        KeyCode::Home | KeyCode::Char('g') if n > 0 => {
            m.focus = 0;
            Vec::new()
        }
        KeyCode::End | KeyCode::Char('G') if n > 0 => {
            m.focus = n.saturating_sub(1);
            Vec::new()
        }
        KeyCode::Enter if m.pending.is_some() && n > 0 => {
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
                m.back = Screen::Dashboard;
                m.screen = Screen::Gate;
                Vec::new()
            }
        }
        _ => {
            let n = crate::screens::blocks(m, Screen::Dashboard);
            scroll_key(&mut m.dash_scroll, n, &k);
            Vec::new()
        }
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

    /// H03: a core whose state cannot be read ends the session's requests:
    /// nothing starts again, and leaving is a failure, not the text interface.
    #[test]
    fn a_lost_core_starts_nothing_more() {
        let mut m = ready();
        let req = match update(&mut m, press(KeyCode::Enter)).remove(0) {
            Cmd::Send(r) => r,
            _ => panic!(),
        };
        let c = update(
            &mut m,
            Msg::Done(req, Outcome::Lost("waitpid failed".into())),
        );
        assert_eq!(c, vec![], "no snapshot after a lost core");
        assert_eq!(m.screen, Screen::Fatal);
        assert!(m.fatal.contains("starts nothing more"), "{}", m.fatal);
        assert_eq!(update(&mut m, press(KeyCode::Char('r'))), vec![]);
        assert!(matches!(
            &update(&mut m, press(KeyCode::Char('q')))[..],
            [Cmd::Quit(1, _)]
        ));
        assert!(matches!(&update(&mut m, ctrlk('c'))[..], [Cmd::Quit(1, _)]));
        assert!(matches!(
            &update(&mut m, Msg::Terminate)[..],
            [Cmd::Quit(1, _)]
        ));
    }

    #[test]
    fn a_read_without_an_answer_is_not_repeated_by_itself() {
        let mut m = ready();
        let c = update(
            &mut m,
            Msg::Done(Req::Snapshot, Outcome::Unknown("schema at line 0".into())),
        );
        assert_eq!(c, vec![], "no loop of reads");
        assert!(m.status.as_ref().unwrap().1.contains("r reads again"));
        let mut m = Model::default();
        m.start();
        let hello = rec("hello", &[("core", "0.2.0")]);
        update(
            &mut m,
            Msg::Done(
                Req::Hello,
                Outcome::Answer(vec![hello, result("done", "ok")]),
            ),
        );
        let c = update(
            &mut m,
            Msg::Done(Req::Snapshot, Outcome::Unknown("eof at line 0".into())),
        );
        assert_eq!(c, vec![]);
        assert_eq!(
            m.screen,
            Screen::Fatal,
            "nothing to show: the no-answer screen, with r and q"
        );
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
