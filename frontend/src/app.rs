//! The model, its messages and `update` (docs/FRONTEND.md → *Event loop and
//! state*). `update` is a pure function of the model and one message: it
//! performs no I/O and returns the commands the event loop carries out. The
//! model keeps the last snapshot of each scope to draw from — a view, never
//! the truth — and asks again after every action, on `r`, and after a
//! handoff or a suspend. An action is always submitted with the basis it was
//! shown.
//!
//! The requests are generic (docs/PROTOCOL.md → *Request schemas*): a
//! scope's snapshot, `Detail{scope, kind}`, `Validate{action, args}` and
//! `Execute{action, args, word}`. Each screen asks for what it shows the first
//! time it is opened, one request at a time; a detail is always opened from
//! its scope's last snapshot and names that generation; moving, scrolling,
//! filtering and choosing what is loaded never ask the core anything
//! (docs/DECISIONS.md → *Resolved review questions*, O1). Only the actions a
//! snapshot lists are offered, only the parameters they declare are asked
//! for, and a typed word is compared here only so that an inexact one is
//! never sent: the core checks it again.

use crate::read::{Args, Checked, Detail, Fault, Kind, LIMIT, Land, Page, Row, Scope};
use crate::record::Record;
use crate::select::{self, Pick};
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
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Action {
    pub id: String,
    pub scope: String,
    pub label: String,
    pub intent: String,
    pub gate: String,
    pub handoff: bool,
    pub cancel: bool,
    pub basis: String,
    pub explain: String,
}

/// A parameter an action declares (`param`): only these are asked for.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Param {
    pub action: String,
    pub name: String,
    pub ty: String,
    pub kind: String,
    pub required: bool,
    pub choices: Vec<String>,
}

/// A snapshot of one scope, as the model keeps it to draw from.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    pub facts: Vec<Fact>,
    pub blockers: Vec<Blocker>,
    pub actions: Vec<Action>,
    pub params: Vec<Param>,
    /// A disk layout the core read (`region` records).
    pub regions: Vec<crate::read::DiskRegion>,
    /// The installer's questions and what to type (prompt, value).
    pub answers: Vec<(String, String)>,
    pub stages: Vec<(String, String)>,
    /// The data set this snapshot read: compared for equality, nothing else.
    pub generation: String,
    /// The core's guide: the next step, in its own words.
    pub guides: Vec<String>,
    /// Each guide's id, in the same order (`next` is the next step).
    pub guide_ids: Vec<String>,
    /// Codes (kind, value), such as the resume token.
    pub codes: Vec<(String, String)>,
    pub warnings: Vec<Blocker>,
    pub messages: Vec<(Level, String)>,
}

impl Snapshot {
    /// The listed action ID.
    pub fn action(&self, id: &str) -> Option<&Action> {
        self.actions.iter().find(|a| a.id == id)
    }

    /// The parameters action ID declares, in the core's order.
    pub fn params_of(&self, id: &str) -> Vec<&Param> {
        self.params.iter().filter(|p| p.action == id).collect()
    }

    /// The facts a gate for action ID shows: `gate.<id>.*`, in the core's
    /// order.
    pub fn gate_facts(&self, id: &str) -> Vec<&Fact> {
        let prefix = format!("gate.{id}.");
        self.facts
            .iter()
            .filter(|f| f.key.starts_with(&prefix))
            .collect()
    }
}

/// A request the event loop sends to a fresh core.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Req {
    Hello,
    /// A scope's snapshot.
    Snapshot(Scope),
    /// `Detail{scope, kind}`: one page of a detail kind, from the generation
    /// of its scope's last snapshot.
    Detail(Page),
    /// `Validate{action, args}`: the arguments are sent as given and judged by
    /// the core alone.
    Validate {
        action: String,
        args: Args,
    },
    /// `Execute{action, args, word}`, with the basis the action was shown.
    Execute {
        action: String,
        args: Args,
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
    /// Screen 12: the storage planner, over `plan.save`'s parameters (or,
    /// where the core lists no `plan.save`, a check of the two sizes).
    Plan,
    /// The Bash-owned operation-record diagnostic of the foundation journey.
    Operation,
    /// Screen 3: the environment scan.
    Scan,
    /// Screen 4: the migration selection, by category.
    Selection,
    /// Screens 5–9 and 11: one list and detail, a tab per category.
    Inventory,
    /// The Migration Review, and the profile's actions.
    Review,
    /// Screen 14 on macOS (the Asahi handoff), 15 on Linux (the continuation).
    Install,
    /// Screen 18: Omarchy Mac's progress, as the machine shows it.
    Progress,
    /// Screen 19: Shared creation.
    Shared,
    /// The parameters of an action other than `plan.save`.
    Form,
    /// Screen 20: layered restore review and the core's item progress.
    Restore,
    /// Screen 21: Keep/Replace choices over the core's conflicts and diffs.
    Conflicts,
    /// The read-only agent brief opened from an error.
    Brief,
    Gate,
    Help,
    /// The core could not be reached or answered with an error.
    Fatal,
}

/// The navigation rail's screens, in order.
pub const NAV: [Screen; 15] = [
    Screen::Welcome,
    Screen::Dashboard,
    Screen::Machine,
    Screen::Status,
    Screen::Health,
    Screen::Logs,
    Screen::Plan,
    Screen::Operation,
    Screen::Scan,
    Screen::Selection,
    Screen::Inventory,
    Screen::Review,
    Screen::Install,
    Screen::Progress,
    Screen::Restore,
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
            Screen::Plan => "Plan",
            Screen::Operation => "Operation",
            Screen::Scan => "Scan",
            Screen::Selection => "Selection",
            Screen::Inventory => "Inventory",
            Screen::Review => "Review",
            Screen::Install => "Install",
            Screen::Progress => "Progress",
            Screen::Shared => "Shared",
            Screen::Form => "Parameters",
            Screen::Restore => "Restore",
            Screen::Conflicts => "Conflict and diff",
            Screen::Brief => "Debugging brief",
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
            Screen::Operation => Some(Kind::Operation),
            Screen::Inventory => Some(Kind::Items),
            Screen::Review => Some(Kind::Review),
            Screen::Restore => Some(Kind::RestoreReview),
            Screen::Conflicts => Some(Kind::Conflicts),
            Screen::Brief => Some(Kind::Brief),
            _ => None,
        }
    }

    /// The scope whose snapshot a screen presents.
    pub fn scope(self) -> Option<Scope> {
        match self {
            Screen::Scan | Screen::Selection => Some(Scope::Profile),
            Screen::Dashboard
            | Screen::Welcome
            | Screen::Plan
            | Screen::Install
            | Screen::Progress
            | Screen::Shared => Some(Scope::Journey),
            s => s.kind().map(Kind::scope),
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

/// One scope's read (health, logs, the profile): its last snapshot and why
/// there is no current one.
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

/// One field of an action's parameter form: a parameter the action declares,
/// and what the person typed or chose for it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Field {
    pub name: String,
    pub ty: String,
    pub choices: Vec<String>,
    pub required: bool,
    pub value: String,
}

/// An action's parameters as typed, which field has the keys, and the core's
/// last answer to them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Form {
    pub action: String,
    pub fields: Vec<Field>,
    pub field: usize,
    pub checked: Option<Checked>,
    pub fault: Option<Fault>,
    /// The scope that listed the action, and the screen the form came from.
    pub scope: Scope,
    pub back: Screen,
}

impl Default for Form {
    fn default() -> Form {
        Form {
            action: String::new(),
            fields: Vec::new(),
            field: 0,
            checked: None,
            fault: None,
            scope: Scope::Journey,
            back: Screen::Dashboard,
        }
    }
}

/// The two sizes the plan check sends where the core lists no `plan.save`
/// (docs/PROTOCOL.md → *Future plan validation contract*).
pub const PLAN_SIZES: [&str; 2] = ["linux_size", "shared_size"];

impl Form {
    /// The planner's form before the core has declared anything: the sizes.
    pub fn sizes() -> Form {
        Form {
            action: "plan.save".into(),
            fields: PLAN_SIZES
                .iter()
                .map(|n| Field {
                    name: n.to_string(),
                    ty: "text".into(),
                    ..Field::default()
                })
                .collect(),
            ..Form::default()
        }
    }

    /// The arguments as typed: each field that holds anything.
    pub fn args(&self) -> Args {
        self.fields
            .iter()
            .filter(|f| !f.value.is_empty())
            .map(|f| (f.name.clone(), f.value.clone().into_bytes()))
            .collect()
    }

    /// The last answer is for exactly what the fields hold now.
    pub fn current(&self) -> bool {
        self.checked.as_ref().is_some_and(|c| c.args == self.args())
    }

    /// Take PARAMS as the fields, as the core now declares them, keeping
    /// what was typed for a name that stays; a review of other fields is
    /// dropped.
    fn declare(&mut self, params: &[(String, String, Vec<String>, bool)]) {
        let same = self.fields.len() == params.len()
            && self.fields.iter().zip(params).all(|(f, p)| f.name == p.0);
        if same {
            for (f, (_, ty, choices, required)) in self.fields.iter_mut().zip(params) {
                f.ty = ty.clone();
                f.choices = choices.clone();
                f.required = *required;
            }
            return;
        }
        self.checked = None;
        let old = std::mem::take(&mut self.fields);
        self.fields = params
            .iter()
            .map(|(name, ty, choices, required)| Field {
                name: name.clone(),
                ty: ty.clone(),
                choices: choices.clone(),
                required: *required,
                value: old
                    .iter()
                    .find(|f| &f.name == name)
                    .map(|f| f.value.clone())
                    .unwrap_or_default(),
            })
            .collect();
        self.field = 0;
    }
}

/// An action about to be sent: what it is, its arguments and basis, the scope
/// that listed it, and the screen to return to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub action: Action,
    pub args: Args,
    pub basis: String,
    pub scope: Scope,
    pub back: Screen,
}

/// The inventory's place: the category tab, and an item's choices open.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Inv {
    pub tab: usize,
    pub open: bool,
    pub choice: usize,
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
    pub details: [Option<Detail>; 15],
    /// An action invalidated Operation; only an admitted Journey read clears it.
    pub operation_stale: bool,
    pub health: ScopeRead,
    pub logread: ScopeRead,
    pub profile: ScopeRead,
    pub restore: ScopeRead,
    pub debug: ScopeRead,
    pub rest: crate::restore::Restore,
    pub brief_back: Screen,
    pub logs_tab: LogsTab,
    /// The storage planner: `plan.save`'s parameters.
    pub plan: Form,
    /// Another action's parameters.
    pub form: Form,
    /// The action a gate's word would send.
    pub gate: Option<Target>,
    /// The action a yes/no question would send (default no).
    pub ask: Option<Target>,
    /// The person's migration choices made in this session.
    pub picks: Vec<Pick>,
    /// The choices a save in flight carries: only these are cleared when it
    /// is done, so a choice made meanwhile stays.
    pub sent_picks: Vec<Pick>,
    /// The core's answer to the last check of those choices.
    pub save_check: Option<Checked>,
    /// The journey is read once the action's own scope has been: after a
    /// profile action, the journey's stages and actions may have moved too.
    pub then_journey: bool,
    /// The first line shown of a gate's facts, which scroll between the
    /// action's label and its field.
    pub gate_scroll: std::cell::Cell<usize>,
    pub inv: Inv,
    /// The steps the running action reported (label, done, total), and its
    /// messages: kept until the next action.
    pub steps: Vec<(String, u64, u64)>,
    pub notes: Vec<(Level, String)>,
    /// The scope read again after the action in flight.
    pub exec_scope: Scope,
    /// A detail to reopen once its scope's fresh snapshot is in (`r`).
    pub reopen: Option<Kind>,
    /// The rows asked for per page.
    pub limit: u64,
    /// The first block shown of the dashboard, the Welcome screen and help.
    pub dash_scroll: usize,
    pub welcome_scroll: usize,
    pub help_scroll: usize,
    pub plan_scroll: usize,
    /// The first block shown of the other free-form screens.
    pub page_scroll: usize,
    /// The cursors of the Selection's categories and the Review's actions.
    pub sel: usize,
    pub rev: usize,
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

const BUSY: &str = "One thing at a time: this runs once the current request ends.";

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
            details: Default::default(),
            operation_stale: false,
            health: ScopeRead::default(),
            logread: ScopeRead::default(),
            profile: ScopeRead::default(),
            restore: ScopeRead::default(),
            debug: ScopeRead::default(),
            rest: crate::restore::Restore::default(),
            brief_back: Screen::Dashboard,
            logs_tab: LogsTab::Tool,
            plan: Form::sizes(),
            form: Form::default(),
            gate: None,
            ask: None,
            picks: Vec::new(),
            sent_picks: Vec::new(),
            save_check: None,
            then_journey: false,
            gate_scroll: std::cell::Cell::new(0),
            inv: Inv::default(),
            steps: Vec::new(),
            notes: Vec::new(),
            exec_scope: Scope::Journey,
            reopen: None,
            limit: LIMIT,
            dash_scroll: 0,
            welcome_scroll: 0,
            help_scroll: 0,
            plan_scroll: 0,
            page_scroll: 0,
            sel: 0,
            rev: 0,
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
            Scope::Profile => &self.profile,
            Scope::Restore => &self.restore,
            Scope::Debug => &self.debug,
            _ => &self.health,
        }
    }

    fn scope_mut(&mut self, s: Scope) -> &mut ScopeRead {
        match s {
            Scope::Logs => &mut self.logread,
            Scope::Profile => &mut self.profile,
            Scope::Restore => &mut self.restore,
            Scope::Debug => &mut self.debug,
            _ => &mut self.health,
        }
    }

    /// The last snapshot of a scope.
    pub fn snap_of(&self, s: Scope) -> Option<&Snapshot> {
        match s {
            Scope::Journey => self.snap.as_ref(),
            _ => self.scope(s).snap.as_ref(),
        }
    }

    /// The generation of a scope's last snapshot.
    pub fn generation(&self, s: Scope) -> Option<&str> {
        self.snap_of(s)
            .map(|s| s.generation.as_str())
            .filter(|g| !g.is_empty())
    }

    /// The action ID as the last snapshot of SCOPE lists it.
    pub fn offered(&self, scope: Scope, id: &str) -> Option<Action> {
        self.snap_of(scope).and_then(|s| s.action(id)).cloned()
    }

    /// The profile's categories, from its `category.<id>` facts in the core's
    /// order: each id with its fact.
    pub fn categories(&self) -> Vec<(String, &Fact)> {
        self.profile
            .snap
            .as_ref()
            .map(|s| {
                s.facts
                    .iter()
                    .filter_map(|f| f.key.strip_prefix("category.").map(|c| (c.to_string(), f)))
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The inventory row the cursor is on.
    pub fn item(&self) -> Option<&Row> {
        let d = self.detail(Kind::Items).filter(|d| d.loaded)?;
        let shown = d.shown();
        shown
            .get(d.cursor.min(shown.len().saturating_sub(1)))
            .copied()
    }

    /// Every row of KIND's data set is held, from one generation: only then
    /// may a screen speak of all of them, or of none.
    pub fn whole(&self, k: Kind) -> bool {
        self.detail(k).is_some_and(|d| {
            d.loaded
                && !d.changed
                && d.fault.is_none()
                && d.offset == 0
                && d.rows.len() as u64 == d.total
                && self.generation(k.scope()) == Some(d.generation.as_str())
        })
    }

    /// The choices the focused item offers: (choice id, label, guess).
    pub fn item_choices(&self) -> Vec<&Row> {
        let Some(item) = self.item() else {
            return Vec::new();
        };
        self.detail(Kind::Choices)
            .filter(|d| d.loaded)
            .map(|d| d.rows.iter().filter(|r| r.id == item.id).collect())
            .unwrap_or_default()
    }

    /// Whether the request in flight is REQ's kind of read for this view.
    pub fn reading(&self, f: impl Fn(&Req) -> bool) -> bool {
        self.pending.as_ref().is_some_and(|p| f(&p.req))
    }

    fn send(&mut self, req: Req, cancellable: bool, label: &str) -> Vec<Cmd> {
        if matches!(req, Req::Execute { .. }) {
            self.invalidate_operation(Fault::NoAnswer(
                "An action was submitted; a fresh Journey snapshot is required.".into(),
            ));
            self.steps.clear();
            self.notes.clear();
        }
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

    fn invalidate_operation(&mut self, fault: Fault) {
        self.operation_stale = true;
        let id = self.generation(Scope::Journey).unwrap_or("").to_string();
        let d = self.details[Kind::Operation.index()]
            .get_or_insert_with(|| Detail::new(Kind::Operation, &id));
        discard_operation(d);
        d.fault = Some(fault);
    }

    fn refresh(&mut self) -> Vec<Cmd> {
        self.send(Req::Snapshot(Scope::Journey), true, "reading the journey")
    }

    fn read(&mut self, s: Scope) -> Vec<Cmd> {
        self.scope_mut(s).asked = true;
        let label = match s {
            Scope::Logs => "reading the log",
            Scope::Profile => "reading the profile",
            Scope::Restore => "reading restore",
            Scope::Debug => "reading debugging facts",
            _ => "reading health",
        };
        self.send(Req::Snapshot(s), true, label)
    }

    /// Read SCOPE again: the journey, or another scope's snapshot.
    fn reread(&mut self, s: Scope) -> Vec<Cmd> {
        match s {
            Scope::Journey => self.refresh(),
            s => self.read(s),
        }
    }

    fn page(&mut self, p: Page, land: Land) -> Vec<Cmd> {
        let label = p.kind.reading();
        if let Some(d) = self.detail_mut(p.kind) {
            d.land = land;
        }
        self.send(Req::Detail(p), true, label)
    }

    fn busy(&mut self) -> Vec<Cmd> {
        self.status = Some((Level::Info, BUSY.into()));
        Vec::new()
    }
}

fn text(r: &Record, k: &str) -> String {
    r.text(k).unwrap_or("").to_string()
}

/// The records of a snapshot answer, as the model keeps them.
pub fn snapshot_of(records: &[Record]) -> Snapshot {
    let mut s = Snapshot {
        regions: crate::read::regions(records),
        ..Snapshot::default()
    };
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
            "guide" => {
                s.guides.push(text(r, "text"));
                s.guide_ids.push(text(r, "id"));
            }
            "code" => s.codes.push((text(r, "kind"), text(r, "value"))),
            "answer" => s.answers.push((text(r, "prompt"), text(r, "value"))),
            "message" => s
                .messages
                .push((level_of(r.text("level").unwrap_or("")), text(r, "text"))),
            "stage" => s.stages.push((text(r, "name"), text(r, "state"))),
            "action" => s.actions.push(Action {
                id: text(r, "id"),
                scope: text(r, "scope"),
                label: text(r, "label"),
                intent: text(r, "intent"),
                gate: text(r, "gate"),
                handoff: r.text("terminal") == Some("handoff"),
                cancel: r.text("cancel") == Some("1"),
                basis: text(r, "basis"),
                explain: text(r, "explain"),
            }),
            "param" => s.params.push(Param {
                action: text(r, "action"),
                name: text(r, "name"),
                ty: text(r, "type"),
                kind: text(r, "kind"),
                required: r.text("required") == Some("1"),
                choices: r
                    .list("choice")
                    .into_iter()
                    .map(|c| String::from_utf8_lossy(c).into_owned())
                    .collect(),
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
    let cmds = step(m, msg);
    // The inventory's rows follow its tab, whatever moved either.
    let tab = m.categories().get(m.inv.tab).map(|(c, _)| c.clone());
    if let Some(d) = m.detail_mut(Kind::Items) {
        d.tab = tab;
    }
    cmds
}

fn step(m: &mut Model, msg: Msg) -> Vec<Cmd> {
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
            let acting = m.reading(|q| matches!(q, Req::Execute { .. }));
            match r.ty.as_str() {
                "progress" => {
                    let n = |k| r.text(k).and_then(|v| v.parse().ok()).unwrap_or(0);
                    let (done, total) = (n("done"), n("total"));
                    m.progress = Some((text(&r, "action"), done, total));
                    let label = text(&r, "label");
                    if m.steps.last().is_some_and(|s| s.0 == label) {
                        if let Some(s) = m.steps.last_mut() {
                            (s.1, s.2) = (done, total);
                        }
                    } else if m.steps.len() < MESSAGES_MAX {
                        m.steps.push((label, done, total));
                    }
                }
                "message" if m.messages.len() < MESSAGES_MAX => {
                    let msg = (level_of(r.text("level").unwrap_or("")), text(&r, "text"));
                    if acting {
                        m.notes.push(msg.clone());
                    }
                    m.messages.push(msg);
                }
                _ => {}
            }
            Vec::new()
        }
        Msg::Done(req, outcome) => done(m, req, outcome),
        Msg::Key(k) => key(m, k),
    }
}

/// The details a screen shows, in the order they are read.
fn wants(m: &Model) -> Vec<Kind> {
    match m.screen {
        Screen::Logs if m.logs_tab == LogsTab::Diagnostics => Vec::new(),
        Screen::Restore => vec![
            Kind::RestoreReview,
            Kind::Conflicts,
            Kind::Diff,
            Kind::Bundles,
            Kind::RestoreStatus,
        ],
        Screen::Conflicts => vec![Kind::Conflicts, Kind::Diff],
        Screen::Selection => vec![Kind::Items],
        Screen::Inventory if m.inv.open => vec![Kind::Items, Kind::Choices],
        // The review's rows, and the inventory a save's document is made of.
        Screen::Review => vec![Kind::Review, Kind::Items],
        Screen::Gate
            if m.gate
                .as_ref()
                .is_some_and(|g| g.action.id == "profile.opaque") =>
        {
            vec![Kind::Opaque]
        }
        s => s.kind().into_iter().collect(),
    }
}

/// What the screen shown still needs read, when nothing runs: a screen asks
/// for its scope's snapshot and its data the first time it is opened, and a
/// failed read is not repeated by itself — the person asks with `r`.
fn demand(m: &mut Model) -> Vec<Cmd> {
    if m.pending.is_some() || m.lost || m.check {
        return Vec::new();
    }
    if m.screen == Screen::Logs && m.logs_tab == LogsTab::Diagnostics {
        return Vec::new();
    }
    let scope = match m.screen {
        Screen::Gate => m.gate.as_ref().map(|g| g.scope),
        s => s.scope(),
    };
    if let Some(scope) = scope
        && scope != Scope::Journey
        && !m.scope(scope).asked
    {
        return m.read(scope);
    }
    for kind in wants(m) {
        if kind == Kind::Operation && m.operation_stale {
            return Vec::new();
        }
        if let Some(d) = m.detail(kind) {
            // A kind the screens speak of as a whole (every item of a
            // category, an item's choices, what opaque covers) is read to
            // its end, page after page of one generation.
            let more = read_whole(kind)
                && d.loaded
                && !d.changed
                && d.fault.is_none()
                && (d.rows.len() as u64) < d.total;
            if more {
                let p = d.page(d.rows.len() as u64, detail_limit(kind, m.limit));
                return m.page(p, Land::First);
            }
            continue;
        }
        let Some(id) = m.generation(kind.scope()).map(str::to_string) else {
            return Vec::new();
        };
        let d = Detail::new(kind, &id);
        let p = d.page(0, detail_limit(kind, m.limit));
        m.details[kind.index()] = Some(d);
        return m.page(p, Land::First);
    }
    Vec::new()
}

/// The kinds held whole: their pages are joined, never shown one at a time.
fn read_whole(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::Items
            | Kind::Choices
            | Kind::Opaque
            | Kind::Bundles
            | Kind::RestoreReview
            | Kind::Conflicts
            | Kind::Diff
            | Kind::RestoreStatus
            | Kind::Brief
    )
}

/// Quit if asked to; otherwise the journey after another scope's action,
/// then what the screen still needs.
fn settle(m: &mut Model, cmds: Vec<Cmd>) -> Vec<Cmd> {
    if m.quit_after {
        return vec![Cmd::Quit(0, String::new())];
    }
    if cmds.is_empty() && m.then_journey && m.pending.is_none() && !m.lost {
        m.then_journey = false;
        return m.refresh();
    }
    if cmds.is_empty() {
        return demand(m);
    }
    cmds
}

fn detail_limit(kind: Kind, limit: u64) -> u64 {
    if kind == Kind::Operation {
        limit.clamp(20, 500)
    } else {
        limit
    }
}

/// A failed or superseded operation read supplies no finding. Other detail
/// kinds keep their accepted retained-generation behavior.
fn discard_operation(d: &mut Detail) {
    if d.kind == Kind::Operation {
        d.rows.clear();
        d.total = 0;
        d.loaded = false;
        d.cursor = 0;
        close_value(d);
    }
}

/// A fresh snapshot of SCOPE arrived with generation ID: a detail opened
/// from another generation is changed — never silently replaced — unless the
/// person asked for it to be reopened, which happens now.
fn regenerated(m: &mut Model, scope: Scope, id: &str) -> Vec<Cmd> {
    let reopen = m.reopen.take();
    let limit = m.limit;
    let mut fresh = None;
    for k in Kind::ALL.into_iter().filter(|k| k.scope() == scope) {
        if k == Kind::Operation && m.operation_stale {
            continue;
        }
        let Some(d) = m.detail_mut(k) else { continue };
        let moved = d.generation != id;
        if reopen == Some(k) && (moved || d.changed || d.fault.is_some() || !d.loaded) {
            // The rows shown stay, under their own generation, until a page
            // of the fresh one is admitted.
            fresh = Some(Page {
                kind: k,
                generation: id.to_string(),
                offset: 0,
                limit: detail_limit(k, limit),
            });
        } else if moved && matches!(scope, Scope::Profile | Scope::Restore | Scope::Debug) {
            // The person's choices are made over these rows: they are read
            // again from the new generation, never shown under it.
            m.details[k.index()] = None;
            continue;
        } else if moved {
            d.changed = true;
        }
        if moved {
            discard_operation(d);
        }
    }
    match fresh {
        Some(p) => m.page(p, Land::First),
        None => Vec::new(),
    }
}

/// SCOPE's generation moved from OLD: what was checked or asked against the
/// old one is dropped, and said.
fn moved_on(m: &mut Model, scope: Scope, old: Option<String>) {
    if old.as_deref() == m.generation(scope) {
        return;
    }
    if scope == Scope::Profile {
        m.save_check = None;
    }
    if scope == Scope::Restore {
        m.rest.checked = None;
        m.rest.bundle.clear();
        m.rest.replacements.clear();
        m.rest.conflict = 0;
        m.rest.line_scroll.set(0);
        m.rest.side_scroll = 0;
        if m.gate.as_ref().is_some_and(|g| g.scope == scope) {
            m.gate = None;
            m.screen = Screen::Restore;
            m.status = Some((
                Level::Warn,
                "Restore changed since you looked; review it again.".into(),
            ));
        }
    }
    if m.ask.as_ref().is_some_and(|t| t.scope == scope) {
        m.ask = None;
        m.status = Some((
            Level::Info,
            "Not sent: what it was asked about changed since you looked.".into(),
        ));
    }
}

/// The person's choices over a whole inventory of a new read: a choice of
/// an item that is gone, or that never travels now, is dropped, and said.
fn recheck_picks(m: &mut Model) {
    let Some(d) = m.details[Kind::Items.index()].as_ref() else {
        return;
    };
    let before = m.picks.len();
    let rows = &d.rows;
    m.picks.retain(|p| {
        rows.iter()
            .any(|r| r.id == p.id && r.col(select::COL_STATE) != "never")
    });
    let gone = before - m.picks.len();
    if gone > 0 {
        m.status = Some((
            Level::Warn,
            format!(
                "{gone} choice{} no longer match{} an item of the inventory and {} dropped.",
                if gone == 1 { "" } else { "s" },
                if gone == 1 { "es" } else { "" },
                if gone == 1 { "was" } else { "were" }
            ),
        ));
    }
}

fn done(m: &mut Model, req: Req, outcome: Outcome) -> Vec<Cmd> {
    m.pending = None;
    m.progress = None;
    let records = match outcome {
        Outcome::Answer(r) => r,
        Outcome::Lost(why) => {
            if let Req::Detail(p) = &req {
                if let Some(d) = m.detail_mut(p.kind) {
                    discard_operation(d);
                }
            }
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
        Req::Snapshot(Scope::Journey) => {
            if m.operation_stale && (status != "done" || code != "ok") {
                m.invalidate_operation(Fault::Said {
                    status: status.clone(),
                    code: code.clone(),
                    text: text.clone(),
                });
            }
            if status == "done" {
                let s = snapshot_of(&records);
                if m.operation_stale && code == "ok" && !s.generation.is_empty() {
                    // This response is a new read even when its generation is
                    // unchanged. The previous finding is never resurrected.
                    m.operation_stale = false;
                    if m.reopen != Some(Kind::Operation) {
                        m.details[Kind::Operation.index()] = None;
                    }
                }
                if m.focus >= s.actions.len() {
                    m.focus = s.actions.len().saturating_sub(1);
                }
                let id = s.generation.clone();
                let old = m.generation(Scope::Journey).map(str::to_string);
                m.snap = Some(s);
                moved_on(m, Scope::Journey, old);
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
        Req::Snapshot(scope) => {
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
                let before = m.generation(scope).map(str::to_string);
                let r = m.scope_mut(scope);
                let old = r.snap.replace(s);
                r.held = [old, r.held.take()]
                    .into_iter()
                    .flatten()
                    .find(|o| o.generation != id && Some(&o.generation) == shown.as_ref());
                r.fault = None;
                moved_on(m, scope, before);
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
            if kind == Kind::Operation {
                if m.operation_stale {
                    // A retained pre-action generation cannot admit a finding.
                    return settle(m, Vec::new());
                }
                let generation = crate::read::generation(&records);
                let rows = crate::read::rows(&records, kind);
                let matches_snapshot = generation.as_ref().is_some_and(|(id, _)| {
                    id == &p.generation && m.generation(Scope::Journey) == Some(id.as_str())
                });
                // D55 is a whole finding, never a generic partial page. This
                // checks its shape only: keys and values remain Bash's words.
                let complete = p.offset == 0
                    && (20..=500).contains(&p.limit)
                    && matches_snapshot
                    && generation
                        .as_ref()
                        .is_some_and(|(_, total)| *total <= 20 && *total == rows.len() as u64)
                    && records.iter().filter(|r| r.ty == "row").count() == rows.len()
                    && rows.iter().all(|r| r.cols.len() == 3);
                let changed = status == "refused" && code == "changed";
                let d = m.detail_mut(kind).expect("made above");
                discard_operation(d);
                if status == "done" && code == "ok" && complete {
                    d.total = rows.len() as u64;
                    d.rows = rows;
                    d.offset = 0;
                    d.generation = p.generation;
                    d.loaded = true;
                    d.changed = false;
                    d.fault = None;
                } else if status == "done" {
                    d.changed = !matches_snapshot;
                    d.fault = Some(Fault::NoAnswer(if matches_snapshot {
                        "the operation detail did not supply a complete D55 finding".into()
                    } else {
                        "the operation detail generation does not match its snapshot".into()
                    }));
                } else {
                    d.changed = changed;
                    d.fault = Some(Fault::Said { status, code, text });
                }
                if changed {
                    // Learn the new generation once. A later explicit refresh
                    // reopens the detail; a moving record cannot cause a loop.
                    m.reopen = None;
                    let c = m.refresh();
                    return settle(m, c);
                }
                return settle(m, Vec::new());
            }
            let d = m.detail_mut(kind).expect("made above");
            match (status.as_str(), code.as_str()) {
                ("done", _) => match crate::read::generation(&records) {
                    // The next page of a kind held whole, from the same
                    // generation: joined to the rows already held.
                    Some((id, total))
                        if read_whole(kind)
                            && p.offset > 0
                            && d.loaded
                            && id == p.generation
                            && id == d.generation
                            && p.offset == d.rows.len() as u64 =>
                    {
                        d.rows.extend(crate::read::rows(&records, kind));
                        d.total = total;
                    }
                    Some((id, total))
                        if id == p.generation && (!read_whole(kind) || p.offset == 0) =>
                    {
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
            if read_whole(kind) {
                let d = m.detail_mut(kind).expect("made above");
                if d.loaded
                    && (d.rows.len() as u64 > d.total
                        || ((d.rows.len() as u64) < d.total && p.offset == d.rows.len() as u64))
                {
                    d.fault = Some(Fault::NoAnswer(
                        "The detail page did not advance within its total.".into(),
                    ));
                }
            }
            if kind == Kind::Bundles && m.whole(Kind::Bundles) {
                m.rest.bundle = m
                    .detail(kind)
                    .expect("whole")
                    .rows
                    .iter()
                    .find(|r| r.col(4) == "ok")
                    .map(|r| r.id.clone())
                    .unwrap_or_default();
            }
            if kind == Kind::Items && m.whole(Kind::Items) {
                recheck_picks(m);
            }
            if matches!(kind, Kind::Conflicts | Kind::Diff) {
                recheck_replacements(m);
            }
            settle(m, Vec::new())
        }
        Req::Validate { action, args } => {
            let c = Checked::of(&records, &action, &args);
            validated(m, c)
        }
        Req::Execute { action, .. } => {
            m.invalidate_operation(Fault::Said {
                status: status.clone(),
                code: code.clone(),
                text: text.clone(),
            });
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
            if status == "done" {
                // What was reviewed for it has been used.
                for f in [&mut m.plan, &mut m.form] {
                    if f.action == action {
                        f.checked = None;
                    }
                }
                if action == "profile.save" {
                    // The choices it carried are saved; one made meanwhile
                    // stays the person's.
                    let sent = std::mem::take(&mut m.sent_picks);
                    m.picks.retain(|p| !sent.contains(p));
                    m.save_check = None;
                }
            }
            m.sent_picks.clear();
            if action == "restore.apply" && status == "refused" && code == "changed" {
                return restore_changed(m);
            }
            // Every action is followed by a fresh read of its scope, and of
            // the journey after another scope's.
            m.then_journey = m.exec_scope != Scope::Journey;
            let c = m.reread(m.exec_scope);
            settle(m, c)
        }
    }
}

/// The core's answer to a validation: the planner's, another form's, or the
/// check of the migration choices — which, reviewed, is asked to be saved.
fn validated(m: &mut Model, c: Checked) -> Vec<Cmd> {
    if c.action == "restore.apply" {
        if c.status == "refused" && c.code == "changed" {
            return restore_changed(m);
        }
        let ready = c.status == "done" && c.code == "ok";
        m.rest.checked = Some(c);
        if ready && m.screen == Screen::Restore {
            return restore_go_on(m);
        }
        return settle(m, Vec::new());
    }
    if c.action == "agents.mcp" {
        if c.status == "done"
            && c.code == "ok"
            && m.screen == Screen::Health
            && let Some(basis) = c.basis.clone()
            && let Some(action) = m.offered(Scope::Health, "agents.mcp")
        {
            ask(
                m,
                Target {
                    action,
                    args: c.args,
                    basis,
                    scope: Scope::Health,
                    back: Screen::Health,
                },
            );
        } else {
            m.status = Some((
                Level::Warn,
                format!("MCP check: {} {} {}", c.status, c.code, c.text),
            ));
        }
        return settle(m, Vec::new());
    }
    if c.action == "profile.save" {
        m.save_check = Some(c);
        // Asked only where it was asked for, on the Review with no field
        // taking keys; elsewhere the check waits for Enter on the save.
        if m.screen == Screen::Review && !typing(m) {
            let c = save_go_on(m);
            return settle(m, c);
        }
        return settle(m, Vec::new());
    }
    let f = if c.action == m.plan.action {
        &mut m.plan
    } else {
        &mut m.form
    };
    f.checked = Some(c);
    f.fault = None;
    settle(m, Vec::new())
}

/// The form a validation of ACTION answers.
fn form_for<'a>(m: &'a mut Model, action: &str) -> &'a mut Form {
    if action == m.plan.action {
        &mut m.plan
    } else {
        &mut m.form
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
        Req::Snapshot(Scope::Journey) if m.snap.is_none() => {
            m.screen = Screen::Fatal;
            m.fatal = format!("The core stopped without a complete answer ({why}).");
            settle(m, Vec::new())
        }
        Req::Snapshot(Scope::Journey) => {
            if m.operation_stale {
                m.invalidate_operation(fault);
            }
            m.reopen = None;
            m.status = Some((
                Level::Warn,
                format!("The core stopped without a complete answer ({why}); r reads again."),
            ));
            settle(m, Vec::new())
        }
        Req::Snapshot(s) => {
            m.reopen = None;
            m.scope_mut(s).fault = Some(fault);
            settle(m, Vec::new())
        }
        Req::Detail(p) => {
            if let Some(d) = m.detail_mut(p.kind) {
                discard_operation(d);
                d.fault = Some(fault);
            }
            settle(m, Vec::new())
        }
        Req::Validate { action, .. } => {
            if matches!(
                action.as_str(),
                "profile.save" | "restore.apply" | "agents.mcp"
            ) {
                m.rest.checked = None;
                m.status = Some((
                    Level::Warn,
                    format!(
                        "The core stopped without a complete answer ({why}); nothing was saved."
                    ),
                ));
            } else {
                form_for(m, &action).fault = Some(fault);
            }
            settle(m, Vec::new())
        }
        Req::Execute { .. } => {
            m.invalidate_operation(fault);
            m.status = Some((
                Level::Warn,
                format!(
                    "The core stopped without a complete answer ({why}); reading the machine again."
                ),
            ));
            m.sent_picks.clear();
            m.then_journey = m.exec_scope != Scope::Journey;
            let c = m.reread(m.exec_scope);
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
        Req::Snapshot(Scope::Journey) | Req::Execute { .. } => {
            if m.operation_stale {
                m.invalidate_operation(fault);
            }
            m.sent_picks.clear();
            m.reopen = None;
            m.status = Some((
                Level::Fail,
                format!("The request was not delivered ({why}); nothing ran."),
            ));
        }
        Req::Snapshot(s) => {
            m.reopen = None;
            m.scope_mut(s).fault = Some(fault);
        }
        Req::Detail(p) => {
            if let Some(d) = m.detail_mut(p.kind) {
                discard_operation(d);
                d.fault = Some(fault);
            }
        }
        Req::Validate { action, .. } => {
            if matches!(
                action.as_str(),
                "profile.save" | "restore.apply" | "agents.mcp"
            ) {
                m.rest.checked = None;
                m.status = Some((
                    Level::Fail,
                    format!("The request was not delivered ({why}); nothing ran."),
                ));
            } else {
                form_for(m, &action).fault = Some(fault);
            }
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

/// A text field has the keys: a form's fields or a filter.
fn typing(m: &Model) -> bool {
    (matches!(m.screen, Screen::Plan | Screen::Form) && m.region == Region::Work && !m.check)
        || editing(m).is_some()
}

/// Ask whether to run T: one line, and only `y` goes on (docs/UX.md →
/// *Confirmation*: yes / no, default no).
fn ask(m: &mut Model, t: Target) {
    let q = match t.action.id.as_str() {
        "plan.save" => "Save this plan?".to_string(),
        "profile.save" => "Save these choices?".to_string(),
        "agents.mcp" => "Run this tool's MCP list (may start servers)?".to_string(),
        _ => format!("{}?", t.action.label),
    };
    m.status = Some((
        Level::Info,
        format!("{q} y goes on; any other key does not."),
    ));
    m.ask = Some(t);
}

/// Send T with WORD, and return to the screen it was chosen on. A save of
/// the choices goes only with the parts the core checked, and only while
/// they are still the person's choices.
fn execute(m: &mut Model, t: Target, word: String) -> Vec<Cmd> {
    m.screen = t.back;
    if t.action.id == "profile.save" {
        if choice_args(m).as_ref() != Some(&t.args) {
            m.status = Some((
                Level::Warn,
                "Not sent: the choices changed since the core checked them; ⏎ on the save checks them again."
                    .into(),
            ));
            return Vec::new();
        }
        m.sent_picks = m.picks.clone();
    }
    if t.action.id == "restore.apply" && restore_reviewed_args(m).as_ref() != Some(&t.args) {
        m.status = Some((
            Level::Warn,
            "Not sent: the restore choices changed; review them again.".into(),
        ));
        return Vec::new();
    }
    m.exec_scope = t.scope;
    let label = t.action.label.clone();
    m.send(
        Req::Execute {
            action: t.action.id,
            args: t.args,
            basis: t.basis,
            word,
            handoff: t.action.handoff,
            cancel: t.action.cancel,
        },
        t.action.cancel,
        &label,
    )
}

/// The gate for T: one field, no button.
fn open_gate(m: &mut Model, t: Target) -> Vec<Cmd> {
    m.gate_input.clear();
    m.gate_note = None;
    m.gate_scroll.set(0);
    m.back = t.back;
    m.gate = Some(t);
    m.screen = Screen::Gate;
    fresh(m, Kind::Opaque);
    demand(m)
}

/// Drop a detail of KIND opened from a generation its scope no longer
/// holds, so what it shows next is read from the current one.
fn fresh(m: &mut Model, kind: Kind) {
    let current = m.generation(kind.scope()).map(str::to_string);
    if m.detail(kind)
        .is_some_and(|d| Some(&d.generation) != current.as_ref() || d.changed)
    {
        m.details[kind.index()] = None;
    }
}

/// Choose action A, listed by SCOPE's snapshot: its parameters first, its
/// page where it has one, then its gate, a question, or the request itself.
fn choose(m: &mut Model, a: Action, scope: Scope) -> Vec<Cmd> {
    if m.pending.is_some() {
        return m.busy();
    }
    let back = m.screen;
    if a.id == "restore.apply" {
        if back != Screen::Restore {
            return open(m, Screen::Restore);
        }
        return restore_check(m);
    }
    if a.id == "profile.save" {
        return save_choices(m);
    }
    let params: Vec<(String, String, Vec<String>, bool)> = m
        .snap_of(scope)
        .map(|s| {
            s.params_of(&a.id)
                .into_iter()
                .map(|p| (p.name.clone(), p.ty.clone(), p.choices.clone(), p.required))
                .collect()
        })
        .unwrap_or_default();
    if a.id == "plan.save" {
        return open(m, Screen::Plan);
    }
    if !params.is_empty() {
        if m.form.action != a.id {
            m.form = Form {
                action: a.id.clone(),
                ..Form::default()
            };
        }
        m.form.declare(&params);
        m.form.scope = scope;
        m.form.back = back;
        m.screen = Screen::Form;
        m.region = Region::Work;
        return demand(m);
    }
    match a.id.as_str() {
        "asahi.launch" if back != Screen::Install => return open(m, Screen::Install),
        "shared.create" if back != Screen::Shared => {
            m.screen = Screen::Shared;
            m.page_scroll = 0;
            return Vec::new();
        }
        _ => {}
    }
    let t = Target {
        basis: a.basis.clone(),
        action: a,
        args: Vec::new(),
        scope,
        back,
    };
    if !t.action.gate.is_empty() {
        open_gate(m, t)
    } else if t.action.intent == "read" {
        // A read changes nothing: it is sent at once.
        execute(m, t, String::new())
    } else {
        // An act or a plan with no word: a question, default no.
        ask(m, t);
        Vec::new()
    }
}

/// The save's arguments for the choices as they are now: one `omb-select 1`
/// document over the whole inventory, split into `select.1` … `select.14`;
/// None while the inventory is not held whole, or when the document is more
/// than the parts carry.
fn choice_args(m: &Model) -> Option<Args> {
    if !m.whole(Kind::Items) {
        return None;
    }
    let rows = &m.detail(Kind::Items)?.rows;
    select::split(&select::document(rows, &m.picks))
}

/// The person's migration choices, checked by the core before any save; a
/// check of exactly these choices goes on to the question or the gate.
fn save_choices(m: &mut Model) -> Vec<Cmd> {
    if !m.whole(Kind::Items) {
        let d = m.detail(Kind::Items);
        let (held, total) = d.map_or((0, 0), |d| (d.rows.len(), d.total));
        m.status = Some((
            Level::Info,
            if d.is_some_and(|d| d.loaded) {
                format!(
                    "The inventory is not read whole yet ({held} of {total} items); the save waits for all of it."
                )
            } else {
                "The inventory is not read yet: the save is made of it.".to_string()
            },
        ));
        return Vec::new();
    }
    let Some(args) = choice_args(m) else {
        m.status = Some((
            Level::Warn,
            format!(
                "These choices are more than one save carries ({} parts of {} bytes); nothing was sent.",
                select::PARTS,
                select::PART_MAX
            ),
        ));
        return Vec::new();
    };
    if m.save_check.as_ref().is_some_and(|c| c.args == args) {
        let c = save_go_on(m);
        if !c.is_empty() || m.ask.is_some() || m.screen == Screen::Gate {
            return c;
        }
    }
    m.save_check = None;
    m.send(
        Req::Validate {
            action: "profile.save".into(),
            args,
        },
        true,
        "checking the choices",
    )
}

/// The save goes on from a check the core answered for exactly the choices
/// as they are now: to its gate where it has a word, else to a question.
fn save_go_on(m: &mut Model) -> Vec<Cmd> {
    let Some(c) = m.save_check.clone() else {
        return Vec::new();
    };
    let Some(basis) = c.basis.clone().filter(|_| c.status == "done") else {
        return Vec::new();
    };
    if choice_args(m).as_ref() != Some(&c.args) {
        return Vec::new();
    }
    let Some(action) = m.offered(Scope::Profile, "profile.save") else {
        return Vec::new();
    };
    let t = Target {
        action,
        args: c.args,
        basis,
        scope: Scope::Profile,
        back: Screen::Review,
    };
    if t.action.gate.is_empty() {
        ask(m, t);
        Vec::new()
    } else {
        open_gate(m, t)
    }
}

/// A stale review returns to the conflicts before another validation or gate.
fn restore_changed(m: &mut Model) -> Vec<Cmd> {
    m.rest.previous.clear();
    if m.whole(Kind::Conflicts) && m.whole(Kind::Diff) {
        let conflicts = &m.detail(Kind::Conflicts).expect("whole").rows;
        let diff = &m.detail(Kind::Diff).expect("whole").rows;
        m.rest.previous = conflicts
            .iter()
            .filter(|r| crate::restore::replacing(&m.rest.replacements, &r.id))
            .map(|r| {
                let rows = crate::restore::diff_rows(diff, &r.id)
                    .into_iter()
                    .cloned()
                    .collect();
                (r.clone(), rows)
            })
            .collect();
    }
    m.rest.checked = None;
    m.rest.replacements.clear();
    m.rest.bundle.clear();
    m.rest.conflict = 0;
    m.rest.line_scroll.set(0);
    m.rest.side_scroll = 0;
    m.gate = None;
    m.ask = None;
    for kind in Kind::ALL
        .into_iter()
        .filter(|k| k.scope() == Scope::Restore)
    {
        m.details[kind.index()] = None;
    }
    m.screen = Screen::Conflicts;
    m.status = Some((
        Level::Warn,
        "Restore changed since you looked; review the conflicts again.".into(),
    ));
    m.reread(Scope::Restore)
}

/// Retain a replacement only when its newly read conflict and diff match.
fn recheck_replacements(m: &mut Model) {
    if !m.whole(Kind::Conflicts) || !m.whole(Kind::Diff) {
        return;
    }
    let previous = std::mem::take(&mut m.rest.previous);
    for (before, diff) in previous {
        let unchanged = m
            .detail(Kind::Conflicts)
            .expect("whole")
            .rows
            .contains(&before)
            && !diff.is_empty()
            && crate::restore::diff_rows(&m.detail(Kind::Diff).expect("whole").rows, &before.id)
                == diff.iter().collect::<Vec<_>>();
        if unchanged {
            crate::restore::choose(&mut m.rest.replacements, &before.id, true);
        }
    }
}

/// The whole current review and conflicts form one replacement document.
fn restore_args(m: &Model) -> Option<Args> {
    if !m.whole(Kind::RestoreReview)
        || !m.whole(Kind::Conflicts)
        || !m.whole(Kind::Bundles)
        || !m.whole(Kind::Diff)
        || m.rest.bundle.is_empty()
    {
        return None;
    }
    let rows = &m.detail(Kind::Conflicts)?.rows;
    let doc = crate::restore::document(rows, &m.rest.replacements);
    let mut args = crate::restore::split(&doc)?;
    args.insert(0, ("bundle".into(), m.rest.bundle.clone()));
    args.insert(
        1,
        (
            "review".into(),
            m.detail(Kind::Conflicts)?.generation.as_bytes().to_vec(),
        ),
    );
    let snap = m.snap_of(Scope::Restore)?;
    let params = snap.params_of("restore.apply");
    args.iter()
        .all(|(n, _)| params.iter().any(|p| p.name == *n))
        .then_some(args)
}

fn restore_check(m: &mut Model) -> Vec<Cmd> {
    let Some(args) = restore_args(m) else {
        m.status = Some((Level::Warn,
            "Restore waits for the complete current review and conflicts, and choices that fit the declared parameters; r reads again.".into()));
        return Vec::new();
    };
    m.rest.checked = None;
    m.send(
        Req::Validate {
            action: "restore.apply".into(),
            args,
        },
        true,
        "checking restore choices",
    )
}

/// The exact reviewed choices, with the core's declared normal values.
fn restore_reviewed_args(m: &Model) -> Option<Args> {
    let c = m.rest.checked.as_ref()?;
    if c.status != "done" || c.code != "ok" || restore_args(m).as_ref() != Some(&c.args) {
        return None;
    }
    Some(
        c.args
            .iter()
            .map(|(name, value)| {
                if name == "review" {
                    return (name.clone(), value.clone());
                }
                c.normal_args
                    .iter()
                    .find(|(n, _)| n == name)
                    .cloned()
                    .unwrap_or_else(|| (name.clone(), value.clone()))
            })
            .collect(),
    )
}

fn restore_go_on(m: &mut Model) -> Vec<Cmd> {
    let Some(c) = &m.rest.checked else {
        return Vec::new();
    };
    let Some(basis) = c
        .basis
        .clone()
        .filter(|_| c.status == "done" && c.code == "ok")
    else {
        return Vec::new();
    };
    let Some(args) = restore_reviewed_args(m) else {
        return Vec::new();
    };
    let Some(action) = m.offered(Scope::Restore, "restore.apply") else {
        return Vec::new();
    };
    let t = Target {
        action,
        args,
        basis,
        scope: Scope::Restore,
        back: Screen::Restore,
    };
    if t.action.gate.is_empty() {
        // The core's declared confirmation always wins.
        ask(m, t);
        Vec::new()
    } else {
        open_gate(m, t)
    }
}

fn restore_key(m: &mut Model, k: KeyEvent) -> Vec<Cmd> {
    if k.code == KeyCode::Char('d') {
        return open(m, Screen::Conflicts);
    }
    let actions: Vec<_> = m
        .snap_of(Scope::Restore)
        .map(|s| {
            s.actions
                .iter()
                .filter(|a| matches!(a.id.as_str(), "restore.apply" | "restore.undo"))
                .cloned()
                .collect()
        })
        .unwrap_or_default();
    match k.code {
        KeyCode::Char('n') => {
            m.rest.action = (m.rest.action + 1).min(actions.len().saturating_sub(1))
        }
        KeyCode::Char('p') => m.rest.action = m.rest.action.saturating_sub(1),
        KeyCode::Enter => {
            if let Some(a) = actions.get(m.rest.action).cloned() {
                return choose(m, a, Scope::Restore);
            }
            m.status = Some((Level::Info, "The core offers no restore action now.".into()));
        }
        _ => {
            let n = crate::screens::blocks(m, Screen::Restore);
            scroll_key(&mut m.page_scroll, n, &k);
        }
    }
    Vec::new()
}

fn conflict_key(m: &mut Model, k: KeyEvent) -> Vec<Cmd> {
    match k.code {
        KeyCode::Char('v') => m.rest.side_by_side = !m.rest.side_by_side,
        KeyCode::Char('n') => {
            let n = m.detail(Kind::Conflicts).map_or(0, |d| d.rows.len());
            m.rest.conflict = (m.rest.conflict + 1).min(n.saturating_sub(1));
            m.page_scroll = 0;
            m.rest.line_scroll.set(0);
            m.rest.side_scroll = 0;
        }
        KeyCode::Char('p') => {
            m.rest.conflict = m.rest.conflict.saturating_sub(1);
            m.page_scroll = 0;
            m.rest.line_scroll.set(0);
            m.rest.side_scroll = 0;
        }
        KeyCode::Char('k' | 'R' | 'K') => {
            if !m.whole(Kind::Conflicts) || !m.whole(Kind::Diff) {
                m.status = Some((
                    Level::Warn,
                    "Choices wait for all conflicts of the current review; r reads again.".into(),
                ));
                return Vec::new();
            }
            let rows = &m.details[Kind::Conflicts.index()]
                .as_ref()
                .expect("whole")
                .rows;
            if let Some(row) = rows.get(m.rest.conflict) {
                if k.code == KeyCode::Char('K') {
                    for r in rows.iter().skip(m.rest.conflict + 1) {
                        crate::restore::choose(&mut m.rest.replacements, &r.id, false);
                    }
                } else {
                    crate::restore::choose(
                        &mut m.rest.replacements,
                        &row.id,
                        k.code == KeyCode::Char('R'),
                    );
                }
                m.rest.checked = None;
            }
        }
        _ => {
            if m.rest.side_visible.get() {
                let n = m
                    .detail(Kind::Conflicts)
                    .and_then(|d| d.rows.get(m.rest.conflict))
                    .and_then(|r| {
                        m.detail(Kind::Diff)
                            .map(|d| crate::restore::diff_rows(&d.rows, &r.id).len())
                    })
                    .unwrap_or(0);
                scroll_key(&mut m.rest.side_scroll, n, &k);
            } else {
                let mut at = m.rest.line_scroll.get();
                scroll_key(&mut at, usize::MAX, &k);
                m.rest.line_scroll.set(at);
            }
        }
    }
    Vec::new()
}

fn mcp_check(m: &mut Model) -> Vec<Cmd> {
    if m.pending.is_some() {
        return m.busy();
    }
    let Some(a) = m.offered(Scope::Health, "agents.mcp") else {
        m.status = Some((
            Level::Info,
            "The core does not offer an MCP check now.".into(),
        ));
        return Vec::new();
    };
    let tool = m
        .detail(Kind::Doctor)
        .filter(|d| {
            !d.changed
                && d.fault.is_none()
                && m.generation(Scope::Health) == Some(d.generation.as_str())
        })
        .and_then(|d| d.shown().get(d.cursor).and_then(|r| crate::read::tool(r)));
    let Some(tool) = tool else {
        m.status = Some((Level::Info, "Select an AI tool row first.".into()));
        return Vec::new();
    };
    let declared = m.snap_of(Scope::Health).is_some_and(|s| {
        s.params_of(&a.id).iter().any(|p| {
            p.name == "tool" && (p.choices.is_empty() || p.choices.iter().any(|c| c == tool))
        })
    });
    if !declared {
        return Vec::new();
    }
    validate(m, a.id, vec![("tool".into(), tool.as_bytes().to_vec())])
}

fn open_brief(m: &mut Model) -> Vec<Cmd> {
    if m.lost {
        m.status = Some((Level::Warn, "The core is no longer supervised. Run ./omarchy-bootstrap debug > file from the text interface.".into()));
        return Vec::new();
    }
    if m.check {
        m.status = Some((Level::Info, "The startup check serves the journey only. ./omarchy-bootstrap debug > file keeps a copy.".into()));
        return Vec::new();
    }
    if m.screen != Screen::Brief {
        m.brief_back = m.screen;
    }
    open(m, Screen::Brief)
}

/// The planner's fields: `plan.save`'s parameters where the core lists it,
/// the two sizes of the plan check where it does not.
fn plan_fields(m: &mut Model) {
    let mut params: Vec<(String, String, Vec<String>, bool)> = m
        .snap
        .as_ref()
        .map(|s| {
            s.params_of("plan.save")
                .into_iter()
                .map(|p| (p.name.clone(), p.ty.clone(), p.choices.clone(), p.required))
                .collect()
        })
        .unwrap_or_default();
    // The check of the two sizes only where the core lists no plan.save at
    // all: a listed one is asked only for what it declares.
    if m.offered(Scope::Journey, "plan.save").is_none() {
        params = PLAN_SIZES
            .iter()
            .map(|n| (n.to_string(), "text".to_string(), Vec::new(), false))
            .collect();
    }
    m.plan.declare(&params);
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
    // A yes/no question: only y goes on, and any other key answers no.
    if let Some(t) = m.ask.take() {
        if k.code == KeyCode::Char('y') && m.pending.is_none() {
            m.status = None;
            return execute(m, t, String::new());
        }
        m.status = Some((Level::Info, "Not sent: nothing changed.".into()));
        return Vec::new();
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
            KeyCode::Char('D') => open_brief(m),
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
    if m.screen != s {
        m.page_scroll = 0;
    }
    m.screen = s;
    m.region = Region::Work;
    m.side = false;
    if let Some(i) = NAV.iter().position(|n| *n == s) {
        m.nav = i;
    }
    if s == Screen::Plan {
        plan_fields(m);
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
        KeyCode::Char('D') => open_brief(m),
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
            } else if m.screen == Screen::Inventory && m.inv.open {
                m.inv.open = false;
            } else if value_open(m, m.screen) {
                let k = m.screen.kind().expect("a detail is shown");
                close_value(m.detail_mut(k).expect("a detail is shown"));
            } else if m.screen == Screen::Conflicts {
                return open(m, Screen::Restore);
            } else if m.screen == Screen::Brief {
                m.screen = m.brief_back;
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
                Screen::Install => {
                    let ids = install_actions(m);
                    page_key(m, k, Scope::Journey, ids)
                }
                Screen::Shared => page_key(m, k, Scope::Journey, &["shared.create"]),
                Screen::Scan => page_key(m, k, Scope::Profile, &["profile.scan"]),
                Screen::Progress => page_key(m, k, Scope::Journey, &[]),
                Screen::Restore => restore_key(m, k),
                Screen::Conflicts => conflict_key(m, k),
                Screen::Brief => {
                    let n = crate::screens::blocks(m, Screen::Brief);
                    scroll_key(&mut m.page_scroll, n, &k);
                    Vec::new()
                }
                Screen::Health if k.code == KeyCode::Char('c') => mcp_check(m),
                Screen::Selection => selection_key(m, k),
                Screen::Inventory => inventory_key(m, k),
                Screen::Review => review_key(m, k),
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
        KeyCode::Down | KeyCode::Char('j') => at.saturating_add(1),
        KeyCode::Up | KeyCode::Char('k') => at.saturating_sub(1),
        KeyCode::PageDown => at.saturating_add(PAGE_STEP),
        KeyCode::PageUp => at.saturating_sub(PAGE_STEP),
        KeyCode::Home | KeyCode::Char('g') => 0,
        KeyCode::End | KeyCode::Char('G') => last,
        _ => *at,
    }
    .min(last);
}

/// A cursor over N rows.
fn cursor_key(at: &mut usize, n: usize, k: &KeyEvent) {
    scroll_key(at, n, k);
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
        return m.busy();
    }
    if matches!(m.screen, Screen::Restore | Screen::Conflicts) {
        for kind in wants(m) {
            if m.detail(kind).is_some_and(|d| d.fault.is_some()) {
                m.details[kind.index()] = None;
            }
        }
    }
    match m.screen {
        Screen::Logs if m.logs_tab == LogsTab::Diagnostics => vec![Cmd::ReadLogs],
        Screen::Plan | Screen::Form => {
            let f = if m.screen == Screen::Plan {
                &m.plan
            } else {
                &m.form
            };
            match &f.checked {
                Some(c) if !m.check => {
                    let (action, args) = (c.action.clone(), c.args.clone());
                    validate(m, action, args)
                }
                _ => Vec::new(),
            }
        }
        s => match s.kind() {
            Some(k) if !m.check => {
                if let Some(d) = m.detail_mut(k) {
                    discard_operation(d);
                }
                m.reopen = Some(k);
                m.reread(k.scope())
            }
            Some(_) => Vec::new(),
            None => match s.scope() {
                Some(Scope::Profile) if !m.check => {
                    if s == Screen::Selection {
                        m.reopen = Some(Kind::Items);
                    }
                    m.read(Scope::Profile)
                }
                _ => m.refresh(),
            },
        },
    }
}

fn validate(m: &mut Model, action: String, args: Args) -> Vec<Cmd> {
    let label = if action == "plan.save" {
        "checking the plan"
    } else {
        "checking the parameters"
    };
    m.send(Req::Validate { action, args }, true, label)
}

/// A text field's keys: typed text, Backspace, Ctrl-U, Enter, Esc — and for
/// a form, Tab between its fields and Space through a choice. None: not a
/// field key (the frame's arrows and Tab keep their meaning).
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
    let plan = m.screen == Screen::Plan;
    if matches!(
        k.code,
        KeyCode::PageUp | KeyCode::PageDown | KeyCode::Home | KeyCode::End
    ) {
        // The answer scrolls; the fields keep the typing keys.
        let n = crate::screens::blocks(m, m.screen);
        scroll_key(&mut m.plan_scroll, n, k);
        return Some(Vec::new());
    }
    m.plan_scroll = 0;
    let p = if plan { &mut m.plan } else { &mut m.form };
    let last = p.fields.len().saturating_sub(1);
    let at = p.field.min(last);
    match k.code {
        KeyCode::Tab | KeyCode::Down => p.field = (at + 1).min(last),
        KeyCode::BackTab | KeyCode::Up => p.field = at.saturating_sub(1),
        // Back, as everywhere; the fields stay as typed.
        KeyCode::Esc => {
            if plan {
                m.screen = Screen::Dashboard;
                m.nav = 1;
            } else {
                m.screen = p.back;
            }
        }
        KeyCode::Enter => return Some(form_enter(m, plan)),
        _ => {
            let f = p.fields.get_mut(at)?;
            let mut full = false;
            match k.code {
                // A choice: Space steps through the core's choices.
                KeyCode::Char(' ') if !f.choices.is_empty() => {
                    let i = f.choices.iter().position(|c| *c == f.value);
                    f.value = match i {
                        Some(i) if i + 1 < f.choices.len() => f.choices[i + 1].clone(),
                        Some(_) => String::new(),
                        None => f.choices[0].clone(),
                    };
                }
                _ if !f.choices.is_empty() => return Some(Vec::new()),
                KeyCode::Char('u') if k.modifiers.contains(KeyModifiers::CONTROL) => {
                    f.value.clear()
                }
                KeyCode::Char(c) if !k.modifiers.contains(KeyModifiers::CONTROL) => {
                    // As much as one argument carries, as the request writes it.
                    let next = format!("{}{c}", f.value);
                    if crate::record::encode(next.as_bytes()).len() <= VALUE_MAX {
                        f.value = next;
                    } else {
                        full = true;
                    }
                }
                KeyCode::Backspace => {
                    f.value.pop();
                }
                _ => return None,
            }
            if full {
                m.status = Some((
                    Level::Warn,
                    format!(
                        "A value is at most {VALUE_MAX} bytes as the request writes it; the rest was not typed."
                    ),
                ));
            }
        }
    }
    Some(Vec::new())
}

/// The most one argument's value may be, as the request writes it.
const VALUE_MAX: usize = 4096;

/// Enter in a form: a review the core answered for exactly what is typed,
/// of an action it still lists, goes on — to its gate, or to a question —
/// with the arguments as the core normalised them and the review's basis;
/// otherwise the core checks what is typed.
fn form_enter(m: &mut Model, plan: bool) -> Vec<Cmd> {
    if m.pending.is_some() {
        return m.busy();
    }
    let f = if plan { &m.plan } else { &m.form };
    let (action, scope, args) = (f.action.clone(), f.scope, f.args());
    if let Some(c) = f.checked.as_ref().filter(|_| f.current())
        && c.status == "done"
        && let Some(basis) = c.basis.clone()
        && let Some(a) = m.offered(scope, &action)
    {
        // Each declared parameter, in the declared order: the core's normal
        // value where it gave one, else what was typed; a name the action
        // does not declare is never sent.
        let args: Args = f
            .fields
            .iter()
            .filter_map(|fl| {
                let normal = c.normal_args.iter().find(|(n, _)| *n == fl.name);
                let typed = c.args.iter().find(|(n, _)| *n == fl.name);
                normal.or(typed).cloned()
            })
            .collect();
        let t = Target {
            action: a,
            args,
            basis,
            scope,
            back: m.screen,
        };
        if t.action.gate.is_empty() {
            ask(m, t);
            return Vec::new();
        }
        return open_gate(m, t);
    }
    validate(m, action, args)
}

/// The keys of a detail table: the cursor over the rows shown, a page past
/// either end of the loaded one, a filter, and the levels of the log.
fn table_key(m: &mut Model, kind: Kind, k: KeyEvent) -> Vec<Cmd> {
    let limit = detail_limit(kind, m.limit);
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
        Some(_) => m.busy(),
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
        KeyCode::Enter => {
            let Some(a) = m.focused().cloned() else {
                return Vec::new();
            };
            choose(m, a, Scope::Journey)
        }
        _ => {
            let n = crate::screens::blocks(m, Screen::Dashboard);
            scroll_key(&mut m.dash_scroll, n, &k);
            Vec::new()
        }
    }
}

/// The keys of a page that offers one of IDS from SCOPE's snapshot (the
/// first listed): Enter chooses it; `n` chooses `network.connect` where it is
/// listed; the moving keys scroll.
/// The actions the Install page describes, by the system `hello` named: the
/// Asahi launch on macOS, Omarchy Mac's start on Linux, none before `hello`.
pub fn install_actions(m: &Model) -> &'static [&'static str] {
    match m.hello.as_ref().map(|h| h.platform.as_str()) {
        Some("macos") => &["asahi.launch"],
        Some("linux") => &["omarchy.start", "omarchy.resume"],
        _ => &[],
    }
}

fn page_key(m: &mut Model, k: KeyEvent, scope: Scope, ids: &[&str]) -> Vec<Cmd> {
    match k.code {
        KeyCode::Enter => match ids.iter().find_map(|id| m.offered(scope, id)) {
            Some(a) => choose(m, a, scope),
            None => {
                m.status = Some((
                    Level::Info,
                    if ids.is_empty() {
                        "This page offers no action: it shows what the core read."
                    } else {
                        "Nothing on this page is offered now: the core lists no such action."
                    }
                    .into(),
                ));
                Vec::new()
            }
        },
        KeyCode::Char('n')
            if m.screen == Screen::Install
                && m.hello.as_ref().is_some_and(|h| h.platform == "linux") =>
        {
            match m.offered(Scope::Journey, "network.connect") {
                Some(a) => choose(m, a, Scope::Journey),
                None => Vec::new(),
            }
        }
        _ => {
            let n = crate::screens::blocks(m, m.screen);
            scroll_key(&mut m.page_scroll, n, &k);
            Vec::new()
        }
    }
}

/// The Selection's keys: a category, all of its items in or out, its list.
fn selection_key(m: &mut Model, k: KeyEvent) -> Vec<Cmd> {
    let cats: Vec<String> = m.categories().into_iter().map(|(c, _)| c).collect();
    match k.code {
        KeyCode::Char(' ') => {
            let Some(cat) = cats.get(m.sel) else {
                return Vec::new();
            };
            // All of a category's items, only once every item is held.
            let d = m.detail(Kind::Items);
            if !m.whole(Kind::Items) {
                m.status = Some((
                    Level::Info,
                    match d.filter(|d| d.loaded) {
                        Some(d) => format!(
                            "The inventory is still being read ({} of {} items): a whole category is chosen once all of it is.",
                            d.rows.len(),
                            d.total
                        ),
                        None => "The inventory is not read yet: its items are chosen once it is."
                            .to_string(),
                    },
                ));
                return Vec::new();
            }
            let Some(d) = d else { return Vec::new() };
            let rows: Vec<Row> = d
                .rows
                .iter()
                .filter(|r| r.col(0) == cat && select::state(r, &m.picks) != "never")
                .cloned()
                .collect();
            let all_in = rows.iter().all(|r| select::state(r, &m.picks) == "include");
            let to = if all_in { "exclude" } else { "include" };
            for r in &rows {
                select::set_state(&mut m.picks, r, to);
            }
            Vec::new()
        }
        KeyCode::Enter if m.sel < cats.len() => {
            m.inv.tab = m.sel;
            m.inv.open = false;
            if let Some(d) = m.detail_mut(Kind::Items) {
                d.cursor = 0;
            }
            open(m, Screen::Inventory)
        }
        _ => {
            cursor_key(&mut m.sel, cats.len(), &k);
            Vec::new()
        }
    }
}

/// The inventory's keys: an item in or out, the next category, an item's
/// choices; the table's keys for moving and filtering.
fn inventory_key(m: &mut Model, k: KeyEvent) -> Vec<Cmd> {
    if m.inv.open {
        let n = m.item_choices().len();
        match k.code {
            KeyCode::Enter => {
                let pick = m.item().cloned().zip(
                    m.item_choices()
                        .get(m.inv.choice)
                        .map(|c| c.col(0).to_string()),
                );
                if let Some((row, choice)) = pick {
                    select::set_decision(&mut m.picks, &row, &choice);
                }
            }
            _ => cursor_key(&mut m.inv.choice, n, &k),
        }
        return Vec::new();
    }
    match k.code {
        KeyCode::Char(' ') => {
            if let Some(row) = m.item().cloned() {
                let to = match select::state(&row, &m.picks) {
                    "never" => {
                        m.status = Some((
                            Level::Info,
                            format!("{} never travels: {}", row.col(1), row.col(8)),
                        ));
                        return Vec::new();
                    }
                    "include" => "exclude",
                    _ => "include",
                };
                select::set_state(&mut m.picks, &row, to);
            }
            Vec::new()
        }
        KeyCode::Char('f') => {
            let n = m.categories().len();
            if n > 0 {
                m.inv.tab = (m.inv.tab + 1) % n;
            }
            if let Some(d) = m.detail_mut(Kind::Items) {
                d.cursor = 0;
            }
            Vec::new()
        }
        KeyCode::Enter if m.item().is_some() => {
            m.inv.open = true;
            m.inv.choice = 0;
            fresh(m, Kind::Choices);
            demand(m)
        }
        _ => table_key(m, Kind::Items, k),
    }
}

/// The profile's actions the Review offers: every one its snapshot lists but
/// the scan, which has its own screen.
pub fn review_actions(m: &Model) -> Vec<Action> {
    m.profile
        .snap
        .as_ref()
        .map(|s| {
            s.actions
                .iter()
                .filter(|a| a.id != "profile.scan")
                .cloned()
                .collect()
        })
        .unwrap_or_default()
}

fn review_key(m: &mut Model, k: KeyEvent) -> Vec<Cmd> {
    let actions = review_actions(m);
    match k.code {
        KeyCode::Enter => match actions.get(m.rev).cloned() {
            Some(a) => choose(m, a, Scope::Profile),
            None => Vec::new(),
        },
        _ => {
            cursor_key(&mut m.rev, actions.len(), &k);
            Vec::new()
        }
    }
}

fn gate_key(m: &mut Model, k: KeyEvent) -> Vec<Cmd> {
    // The moving keys scroll what the gate says between its label and its
    // field; they are never text. The frame keeps the line within the facts.
    let top = m.gate_scroll.get_mut();
    match k.code {
        KeyCode::Down => *top = top.saturating_add(1),
        KeyCode::Up => *top = top.saturating_sub(1),
        KeyCode::PageDown => *top = top.saturating_add(PAGE_STEP),
        KeyCode::PageUp => *top = top.saturating_sub(PAGE_STEP),
        KeyCode::Home => *top = 0,
        KeyCode::End => *top = usize::MAX,
        _ => {}
    }
    if matches!(
        k.code,
        KeyCode::Down
            | KeyCode::Up
            | KeyCode::PageDown
            | KeyCode::PageUp
            | KeyCode::Home
            | KeyCode::End
    ) {
        return Vec::new();
    }
    match k.code {
        KeyCode::Esc => {
            m.screen = m.gate.take().map_or(Screen::Dashboard, |g| g.back);
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
            let Some(t) = m.gate.clone() else {
                m.screen = Screen::Dashboard;
                return Vec::new();
            };
            if m.pending.is_some() {
                return m.busy();
            }
            // Only the exact word continues; anything else says so and
            // does nothing (the core checks the word again).
            if m.gate_input != t.action.gate {
                m.gate_note = Some(format!(
                    "Only the exact word \"{}\" continues.",
                    t.action.gate
                ));
                return Vec::new();
            }
            let word = std::mem::take(&mut m.gate_input);
            m.gate = None;
            execute(m, t, word)
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
        assert_eq!(c, vec![Cmd::Send(Req::Snapshot(Scope::Journey))]);
        let snap = vec![
            action("test.read", "", false),
            action("test.mutate", "test", false),
            action("test.handoff", "test", true),
            result("done", "ok"),
        ];
        update(
            &mut m,
            Msg::Done(Req::Snapshot(Scope::Journey), Outcome::Answer(snap)),
        );
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
                args: vec![],
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
        assert_eq!(c, vec![Cmd::Send(Req::Snapshot(Scope::Journey))]);
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
        assert_eq!(c, vec![Cmd::Send(Req::Snapshot(Scope::Journey))]);
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
            Msg::Done(
                Req::Snapshot(Scope::Journey),
                Outcome::Unknown("schema at line 0".into()),
            ),
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
            Msg::Done(
                Req::Snapshot(Scope::Journey),
                Outcome::Unknown("eof at line 0".into()),
            ),
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
            args: vec![],
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
            req: Req::Snapshot(Scope::Journey),
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
            req: Req::Snapshot(Scope::Journey),
            cancellable: false,
            label: String::new(),
            ticks: 0,
        });
        assert_eq!(update(&mut m, Msg::Terminate), vec![]);
        let c = update(
            &mut m,
            Msg::Done(
                Req::Snapshot(Scope::Journey),
                Outcome::Answer(vec![result("done", "ok")]),
            ),
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
