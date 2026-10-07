//! The Gate 2 read surface in the frontend (layers A–C, docs/TESTING.md →
//! *Layers*): the Welcome screen, the Journey dashboard, machine and status
//! details, Health, Logs and the read-only plan check, driven only through
//! the model's boundary — keys in, request bytes and frames out — with every
//! answer written as protocol text and admitted by the frontend's own
//! admission. The records are shaped like the core's over the
//! `mac-m1pro-1tb-roomy` fixture; the contract target's `gate2_read` runs
//! the same flows against the real core.

use omb_tui::app::{Cmd, Model, Msg, Outcome, Req, update};
use omb_tui::core::{Session, op_of};
use omb_tui::record::{Family, admit};
use omb_tui::screens;
use omb_tui::theme::{Caps, Depth, Theme};
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

const GEN: &str = "78b203ec6845e7be6ca963cca2619b346bfa5905ace54bcaf82a5a1aa35b0ee6";
const GEN2: &str = "2a55bbbd91dbc0f61476283c47e62260d0934f283ec0ef7c0368538a9f1ec108";
const HGEN: &str = "2620e023028384d030ab3285a1480ee30d8be268ccf3bbc23e372510160a72e1";
const LGEN: &str = "545e054a974234046daf322d39ba9f9e96f773fcc41d524815e99e52a025584a";
const EMPTY: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

fn hello_line(ceiling: &str) -> String {
    format!(
        "hello\tcore=0.2.0\tcommit=0123456789abcdef0123456789abcdef01234567\tsource={}\tproto=1\tplatform=macos\tarch=arm64\tuser=user\tceiling={ceiling}\tdry_run=0\tfixture=1\n",
        "a4e5".repeat(16)
    )
}

const DONE: &str = "result\tstatus=done\tcode=ok\ttext=\tnext=\n";

fn journey(generation: &str) -> String {
    format!(
        "generation\tid={generation}\ttotal=0
fact\tscope=journey\tkey=machine.platform\tlabel=Platform\tvalue=macos\tstate=info
fact\tscope=journey\tkey=machine.arch\tlabel=Architecture\tvalue=arm64\tstate=info
fact\tscope=journey\tkey=machine.model\tlabel=Model\tvalue=MacBookPro18,1\tstate=info
fact\tscope=journey\tkey=machine.chip\tlabel=Chip\tvalue=Apple%20M1%20Pro\tstate=info
fact\tscope=journey\tkey=machine.memory\tlabel=Memory\tvalue=17179869184\tstate=info
fact\tscope=journey\tkey=machine.os\tlabel=macOS\tvalue=14.6\tstate=info
fact\tscope=journey\tkey=status.2\tlabel=Machine\tvalue=MacBook%20Pro%20%2816-inch,%20M1%20Pro,%202021%29\tstate=info
fact\tscope=journey\tkey=status.3\tlabel=Asahi%20install\tvalue=none\tstate=info
fact\tscope=journey\tkey=status.4\tlabel=Safe%20Linux%20max\tvalue=654%20GB\tstate=info
fact\tscope=journey\tkey=recorded.6\tlabel=Surveyed\tvalue=not%20yet\tstate=info
fact\tscope=journey\tkey=recorded.7\tlabel=Plan\tvalue=not%20yet\tstate=info
guide\tid=next\tstep=1\ttext=Run%20./omarchy-bootstrap%20to%20survey%20this%20Mac%20and%20plan%20storage.
{DONE}"
    )
}

const MACHINE_ROWS: &str = "row\tkind=machine\tkey=machine.platform\tcol=Platform\tcol=macos
row\tkind=machine\tkey=machine.arch\tcol=Architecture\tcol=arm64
row\tkind=machine\tkey=machine.model\tcol=Model\tcol=MacBookPro18,1
row\tkind=machine\tkey=machine.chip\tcol=Chip\tcol=Apple%20M1%20Pro
row\tkind=machine\tkey=machine.memory\tcol=Memory\tcol=17179869184
row\tkind=machine\tkey=machine.os\tcol=macOS\tcol=14.6
";

const HEALTH: &str =
    "generation\tid=2620e023028384d030ab3285a1480ee30d8be268ccf3bbc23e372510160a72e1\ttotal=0
fact\tscope=health\tkey=doctor.pass\tlabel=Passed\tvalue=10\tstate=info
fact\tscope=health\tkey=doctor.warn\tlabel=Warnings\tvalue=1\tstate=info
fact\tscope=health\tkey=doctor.fail\tlabel=Failures\tvalue=0\tstate=info
";

const DOCTOR_ROWS: &str = "row\tkind=doctor\tkey=1\tcol=pass\tcol=Apple%20Silicon\tcol=arm64
row\tkind=doctor\tkey=2\tcol=pass\tcol=Supported%20model\tcol=MacBook%20Pro%20%2816-inch,%20M1%20Pro,%202021%29
row\tkind=doctor\tkey=10\tcol=info\tcol=FileVault\tcol=on%20%E2%80%94%20the%20installer%20asks%20for%20your%20password
row\tkind=doctor\tkey=11\tcol=warn\tcol=Backup%20confirmed\tcol=not%20yet%3B%20asked%20before%20the%20installer%20runs
";

const LOGS: &str = "generation\tid=545e054a974234046daf322d39ba9f9e96f773fcc41d524815e99e52a025584a\ttotal=0
fact\tscope=logs\tkey=logs.state_dir\tlabel=State\tvalue=/Users/alex/.local/state/omarchy-mac-bootstrap\tstate=info
fact\tscope=logs\tkey=logs.directory\tlabel=Logs\tvalue=/Users/alex/.local/state/omarchy-mac-bootstrap/logs\tstate=info
fact\tscope=logs\tkey=logs.source\tlabel=Source\tvalue=omarchy-bootstrap-20261004.log\tstate=info
fact\tscope=logs\tkey=logs.lines\tlabel=Lines\tvalue=3\tstate=info
";

const LOG_ROWS: &str = "row\tkind=log\tkey=1\tcol=2026-10-04T10:00:00Z\tcol=info\tcol=%5BSURVEY%5D\tcol=reading%20the%20disk
row\tkind=log\tkey=2\tcol=2026-10-04T10:00:01Z\tcol=warn\tcol=%5BPLAN%5D\tcol=Linux%20below%20recommended
row\tkind=log\tkey=3\tcol=\tcol=\tcol=\tcol=not%20a%20log-shaped%20line
";

fn key(c: KeyCode) -> Msg {
    Msg::Key(KeyEvent::new(c, KeyModifiers::NONE))
}

fn press(m: &mut Model, c: KeyCode) -> Vec<Cmd> {
    update(m, key(c))
}

fn typed(m: &mut Model, s: &str) -> Vec<Cmd> {
    let mut out = Vec::new();
    for c in s.chars() {
        out.extend(press(m, KeyCode::Char(c)));
    }
    out
}

/// The one request among CMDS.
fn sent(cmds: &[Cmd]) -> Req {
    let reqs: Vec<&Req> = cmds
        .iter()
        .filter_map(|c| match c {
            Cmd::Send(r) => Some(r),
            _ => None,
        })
        .collect();
    assert_eq!(reqs.len(), 1, "one request: {cmds:?}");
    reqs[0].clone()
}

fn requests(cmds: &[Cmd]) -> usize {
    cmds.iter().filter(|c| matches!(c, Cmd::Send(_))).count()
}

/// The request's bytes, as the frontend would write them to the core.
fn bytes(req: &Req) -> String {
    let s = Session::new(
        "/nonexistent/omb-session.t".into(),
        "/nonexistent".into(),
        true,
    );
    String::from_utf8(s.request(req)).unwrap()
}

/// Answer REQ with BODY (the records after hello), admitted as the core's
/// response would be.
fn answer(m: &mut Model, req: Req, body: &str) -> Vec<Cmd> {
    let text = format!("omb-res 1\n{}{body}", hello_line("read"));
    let doc = admit(Family::Res, Some(op_of(&req)), text.as_bytes())
        .unwrap_or_else(|e| panic!("the test's answer is admissible: {e:?}\n{text}"));
    update(m, Msg::Done(req, Outcome::Answer(doc.records)))
}

/// An ordinary fixture session after hello and its journey snapshot.
fn ready() -> Model {
    let mut m = Model::default();
    let c = m.start();
    let c = answer(&mut m, sent(&c), DONE);
    let req = sent(&c);
    assert!(bytes(&req).contains("scope\tname=journey\n"));
    let c = answer(&mut m, req, &journey(GEN));
    assert_eq!(requests(&c), 0, "nothing more is read by itself");
    m
}

/// Open the screen at position N of the navigation rail: Welcome, Journey,
/// Machine, Status, Health, Logs, Plan check.
fn go(m: &mut Model, n: usize) -> Vec<Cmd> {
    let mut out = press(m, KeyCode::Left);
    for _ in 0..8 {
        out.extend(press(m, KeyCode::Up));
    }
    for _ in 0..n {
        out.extend(press(m, KeyCode::Down));
    }
    assert_eq!(requests(&out), 0, "moving in the rail is local");
    press(m, KeyCode::Enter)
}

fn theme(unicode: bool) -> Theme {
    Theme::new(Caps {
        depth: Depth::Full,
        unicode,
        console: false,
    })
}

fn frame(m: &Model, w: u16, h: u16) -> String {
    let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
    t.draw(|f| screens::draw(f, m, &theme(true), 50)).unwrap();
    let b = t.backend().buffer().clone();
    let mut out = String::new();
    for y in 0..h {
        let mut line = String::new();
        for x in 0..w {
            line.push_str(b[(x, y)].symbol());
        }
        out.push_str(line.trim_end());
        out.push('\n');
    }
    out
}

#[test]
fn welcome_presents_the_machine_the_tool_and_the_session() {
    let mut m = ready();
    assert_eq!(requests(&go(&mut m, 0)), 0, "Welcome reads nothing new");
    let f = frame(&m, 120, 40);
    for want in [
        "Welcome",
        "MacBookPro18,1",
        "Apple M1 Pro",
        "frontend 0.2.0",
        "protocol 1",
        "core 0.2.0",
        "78b203ec6845",
        "later",
        "recorded",
    ] {
        assert!(f.contains(want), "{want:?} on the Welcome screen:\n{f}");
    }
}

#[test]
fn the_dashboard_draws_ten_later_stations_and_the_next_step() {
    let m = ready();
    let f = frame(&m, 120, 40);
    assert!(!f.contains("not derived in this build"), "{f}");
    assert!(f.contains("survey") && f.contains("done"), "{f}");
    assert!(f.contains("later"), "{f}");
    assert!(
        f.contains("Run ./omarchy-bootstrap to survey this Mac"),
        "{f}"
    );
    assert!(f.contains("Nothing is available now."), "{f}");
}

#[test]
fn machine_detail_opens_from_the_snapshot_generation() {
    let mut m = ready();
    let req = sent(&go(&mut m, 2));
    let b = bytes(&req);
    assert!(b.contains("req\top=detail\t"), "{b}");
    assert!(
        b.contains(&format!(
            "page\tscope=journey\tkind=machine\tgeneration={GEN}\toffset=0\tlimit=500\n"
        )),
        "{b}"
    );
    let c = answer(
        &mut m,
        req,
        &format!("generation\tid={GEN}\ttotal=6\n{MACHINE_ROWS}{DONE}"),
    );
    assert_eq!(requests(&c), 0);
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("Architecture") && f.contains("17179869184"),
        "{f}"
    );
    assert!(f.contains("1–6 of 6"), "{f}");
}

#[test]
fn status_detail_pages_by_offset_and_limit() {
    let mut m = ready();
    let req = sent(&go(&mut m, 3));
    assert!(bytes(&req).contains(&format!(
        "page\tscope=journey\tkind=status\tgeneration={GEN}\toffset=0\tlimit=500\n"
    )));
    let mut rows = String::new();
    for i in 1..=500 {
        rows.push_str(&format!(
            "row\tkind=status\tkey={i}\tcol=Detected%20now\tcol=Line%20{i}\tcol=v\tcol=\n"
        ));
    }
    answer(
        &mut m,
        req,
        &format!("generation\tid={GEN}\ttotal=812\n{rows}{DONE}"),
    );
    assert!(frame(&m, 120, 40).contains("1–500 of 812"));
    // Past the loaded page: the next page, from the same generation.
    let c = press(&mut m, KeyCode::End);
    let c = if requests(&c) == 0 {
        press(&mut m, KeyCode::PageDown)
    } else {
        c
    };
    let next = sent(&c);
    assert!(
        bytes(&next).contains(&format!(
            "page\tscope=journey\tkind=status\tgeneration={GEN}\toffset=500\tlimit=500\n"
        )),
        "{}",
        bytes(&next)
    );
}

#[test]
fn a_changed_generation_is_never_mixed_into_the_open_detail() {
    let mut m = ready();
    let req = sent(&go(&mut m, 2));
    answer(
        &mut m,
        req,
        &format!("generation\tid={GEN}\ttotal=6\n{MACHINE_ROWS}{DONE}"),
    );
    // The dashboard is refreshed and the journey changed meanwhile.
    press(&mut m, KeyCode::Esc);
    let snap = sent(&press(&mut m, KeyCode::Char('r')));
    answer(&mut m, snap, &journey(GEN2));
    let c = go(&mut m, 2);
    assert_eq!(
        requests(&c),
        0,
        "the stale detail is not reopened by itself"
    );
    let f = frame(&m, 120, 40);
    assert!(f.contains("changed since you looked"), "{f}");
    assert!(
        f.contains("MacBookPro18,1"),
        "the old rows stay, marked:\n{f}"
    );
}

#[test]
fn health_reads_its_scope_then_the_doctor_rows() {
    let mut m = ready();
    let req = sent(&go(&mut m, 4));
    assert!(
        bytes(&req).contains("req\top=snapshot\t") && bytes(&req).contains("scope\tname=health\n")
    );
    let c = answer(&mut m, req, &format!("{HEALTH}{DONE}"));
    let det = sent(&c);
    assert!(bytes(&det).contains(&format!(
        "page\tscope=health\tkind=doctor\tgeneration={HGEN}\toffset=0\tlimit=500\n"
    )));
    answer(
        &mut m,
        det,
        &format!("generation\tid={HGEN}\ttotal=4\n{DOCTOR_ROWS}{DONE}"),
    );
    let f = frame(&m, 120, 40);
    for want in [
        "Passed",
        "10",
        "Warnings",
        "Failures",
        "Apple Silicon",
        "Backup confirmed",
        "pass",
        "warn",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
}

#[test]
fn logs_read_the_selected_source_and_its_window() {
    let mut m = ready();
    let req = sent(&press(&mut m, KeyCode::Char('L')));
    assert!(
        bytes(&req).contains("scope\tname=logs\n"),
        "{}",
        bytes(&req)
    );
    let det = sent(&answer(&mut m, req, &format!("{LOGS}{DONE}")));
    assert!(bytes(&det).contains(&format!(
        "page\tscope=logs\tkind=log\tgeneration={LGEN}\toffset=0\tlimit=500\n"
    )));
    answer(
        &mut m,
        det,
        &format!("generation\tid={LGEN}\ttotal=3\n{LOG_ROWS}{DONE}"),
    );
    let f = frame(&m, 120, 40);
    for want in [
        "omarchy-bootstrap-20261004.log",
        "reading the disk",
        "[PLAN]",
        "not a log-shaped line",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
}

#[test]
fn logs_failures_keep_their_meaning() {
    for (body, head, words) in [
        (
            format!(
                "generation\tid={EMPTY}\ttotal=0\nresult\tstatus=error\tcode=representation\ttext=The%20required%20logs%20metadata%20cannot%20be%20represented%20in%20Protocol%201.\tnext=\n"
            ),
            "error · representation",
            "The required logs metadata cannot be represented",
        ),
        (
            format!(
                "generation\tid={EMPTY}\ttotal=0\nresult\tstatus=error\tcode=io\ttext=The%20logs%20response%20could%20not%20be%20prepared.\tnext=\n"
            ),
            "error · io",
            "The logs response could not be prepared.",
        ),
        (
            format!(
                "generation\tid={EMPTY}\ttotal=0\nresult\tstatus=refused\tcode=overflow\ttext=The%20selected%20log%20window%20cannot%20be%20represented%20in%20Protocol%201.\tnext=\n"
            ),
            "refused · overflow",
            "The selected log window cannot be represented",
        ),
    ] {
        let mut m = ready();
        let req = sent(&press(&mut m, KeyCode::Char('L')));
        let c = answer(&mut m, req, &body);
        assert_eq!(requests(&c), 0, "no detail without a dataset");
        let f = frame(&m, 120, 40);
        assert!(f.contains(head), "{head:?}:\n{f}");
        assert!(f.contains(words), "{words:?}:\n{f}");
        assert!(!f.contains("rows 1"), "no rows are presented:\n{f}");
    }
}

#[test]
fn the_plan_check_validates_and_saves_nothing() {
    let mut m = ready();
    assert_eq!(
        requests(&go(&mut m, 6)),
        0,
        "opening the form reads nothing"
    );
    assert_eq!(requests(&typed(&mut m, "250GB")), 0, "letters are text");
    press(&mut m, KeyCode::Tab);
    assert_eq!(requests(&typed(&mut m, "100GB")), 0);
    let req = sent(&press(&mut m, KeyCode::Enter));
    let b = bytes(&req);
    for want in [
        "req\top=validate\t",
        "select\taction=plan.save\n",
        "arg\tname=linux_size\tvalue=250GB\n",
        "arg\tname=shared_size\tvalue=100GB\n",
    ] {
        assert!(b.contains(want), "{want:?} in {b}");
    }
    assert!(!b.contains("exec\t"), "never an execute");
    answer(
        &mut m,
        req,
        &format!(
            "answer\tn=1\tprompt=New%20size%20for%20macOS\tvalue=614730MiB\tbytes=644591124480
answer\tn=2\tprompt=New%20OS%20size\tvalue=238419MiB\tbytes=250000441344
normal\tname=linux_size\tvalue=250000000000
normal\tname=shared_size\tvalue=100000000000
review\taction=plan.save\tbasis={}
{DONE}",
            "8acb".repeat(16)
        ),
    );
    let f = frame(&m, 120, 40);
    for want in [
        "New size for macOS",
        "614730MiB",
        "238419MiB",
        "250000000000",
        "8acb8acb",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
}

#[test]
fn a_refresh_shows_that_it_is_running_at_once() {
    let mut m = ready();
    let req = sent(&go(&mut m, 4));
    let det = sent(&answer(&mut m, req, &format!("{HEALTH}{DONE}")));
    answer(
        &mut m,
        det,
        &format!("generation\tid={HGEN}\ttotal=4\n{DOCTOR_ROWS}{DONE}"),
    );
    let c = press(&mut m, KeyCode::Char('r'));
    assert!(bytes(&sent(&c)).contains("scope\tname=health\n"));
    // No tick has passed: the very next frame says the read is running, and
    // the rows already shown stay on the screen.
    let f = frame(&m, 120, 40);
    assert!(f.contains("reading health"), "{f}");
    assert!(f.contains("Apple Silicon"), "{f}");
}

#[test]
fn moving_and_filtering_loaded_rows_ask_the_core_nothing() {
    let mut m = ready();
    let req = sent(&press(&mut m, KeyCode::Char('L')));
    let det = sent(&answer(&mut m, req, &format!("{LOGS}{DONE}")));
    answer(
        &mut m,
        det,
        &format!("generation\tid={LGEN}\ttotal=3\n{LOG_ROWS}{DONE}"),
    );
    let mut cmds = Vec::new();
    for c in [
        KeyCode::Down,
        KeyCode::Down,
        KeyCode::Up,
        KeyCode::End,
        KeyCode::Home,
        KeyCode::PageDown,
    ] {
        cmds.extend(press(&mut m, c));
    }
    cmds.extend(press(&mut m, KeyCode::Char('/')));
    cmds.extend(typed(&mut m, "plan"));
    assert_eq!(requests(&cmds), 0, "{cmds:?}");
    let f = frame(&m, 120, 40);
    assert!(f.contains("Linux below recommended"), "{f}");
    assert!(
        !f.contains("reading the disk"),
        "the filter hides the other lines:\n{f}"
    );
}

// --- Beyond the fail-first set: sessions, states, sizes and profiles ------

use omb_tui::app::{NAV, Screen};
use ratatui::buffer::Buffer;
use ratatui::style::Color;

fn render(m: &Model, t: &Theme, w: u16, h: u16) -> Buffer {
    let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
    term.draw(|f| screens::draw(f, m, t, 50)).unwrap();
    term.backend().buffer().clone()
}

fn text_of(b: &Buffer) -> String {
    let mut out = String::new();
    for y in 0..b.area.height {
        let mut line = String::new();
        for x in 0..b.area.width {
            line.push_str(b[(x, y)].symbol());
        }
        out.push_str(line.trim_end());
        out.push('\n');
    }
    out
}

fn profile(name: &str) -> Theme {
    let (depth, unicode, console) = match name {
        "color" => (Depth::Full, true, false),
        "sixteen" => (Depth::Sixteen, true, false),
        "nocolor" => (Depth::None, true, false),
        "ascii" => (Depth::Sixteen, false, true),
        _ => unreachable!(),
    };
    Theme::new(Caps {
        depth,
        unicode,
        console,
    })
}

/// A session's journey, then the screen at N opened and answered with BODY
/// when it reads anything.
fn opened(n: usize, bodies: &[&str]) -> Model {
    let mut m = ready();
    let mut c = go(&mut m, n);
    for b in bodies {
        let req = sent(&c);
        c = answer(&mut m, req, b);
    }
    assert_eq!(requests(&c), 0, "{c:?}");
    m
}

fn health_model() -> Model {
    opened(
        4,
        &[
            &format!("{HEALTH}{DONE}"),
            &format!("generation\tid={HGEN}\ttotal=4\n{DOCTOR_ROWS}{DONE}"),
        ],
    )
}

fn logs_model() -> Model {
    opened(
        5,
        &[
            &format!("{LOGS}{DONE}"),
            &format!("generation\tid={LGEN}\ttotal=3\n{LOG_ROWS}{DONE}"),
        ],
    )
}

fn machine_model() -> Model {
    opened(
        2,
        &[&format!(
            "generation\tid={GEN}\ttotal=6\n{MACHINE_ROWS}{DONE}"
        )],
    )
}

fn plan_model() -> Model {
    let mut m = ready();
    go(&mut m, 6);
    typed(&mut m, "250GB");
    press(&mut m, KeyCode::Tab);
    typed(&mut m, "100GB");
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(
        &mut m,
        req,
        &format!(
            "answer\tn=1\tprompt=New%20size%20for%20macOS\tvalue=614730MiB\tbytes=644591124480
answer\tn=2\tprompt=New%20OS%20size\tvalue=238419MiB\tbytes=250000441344
normal\tname=linux_size\tvalue=250000000000
normal\tname=shared_size\tvalue=100000000000
review\taction=plan.save\tbasis={}
{DONE}",
            "8acb".repeat(16)
        ),
    );
    m
}

/// The startup check (docs/PROTOCOL.md → *The startup-check session*)
/// answers hello and the journey snapshot only; any other exchange would make
/// `frontend-check` not completed. Whatever the person presses, nothing else
/// is asked, and each view says why it reads nothing.
#[test]
fn the_startup_check_is_asked_nothing_but_its_snapshot() {
    let mut m = Model {
        check: true,
        ..Model::default()
    };
    let c = m.start();
    let c = answer(&mut m, sent(&c), DONE);
    let req = sent(&c);
    answer(
        &mut m,
        req,
        &format!(
            "generation\tid={GEN}\ttotal=0
fact\tscope=journey\tkey=check\tlabel=Check\tvalue=frontend%20startup%20check%20%28frontend-check%29\tstate=info
fact\tscope=journey\tkey=interface\tlabel=Interface\tvalue=frontend%200.2.0%20as%20the%20lock%20pins,%20protocol%201\tstate=ok
fact\tscope=journey\tkey=session\tlabel=Session\tvalue=read-only,%20journey%20scope%20only,%20not%20a%20dry%20run\tstate=info
fact\tscope=journey\tkey=actions\tlabel=Actions\tvalue=none%20in%20this%20session\tstate=info
{DONE}"
        ),
    );
    // The dashboard as frontend-check-terminal reads it, at its 120×40.
    let f = frame(&m, 120, 40);
    for want in [
        "frontend startup check (frontend-check)",
        "frontend 0.2.0 as the lock pins, protocol 1",
        "read-only, journey scope only, not a dry run",
        "none in this session",
        "Nothing is available now.",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    let mut all = Vec::new();
    for n in 0..NAV.len() {
        all.extend(go(&mut m, n));
        for k in [
            KeyCode::Char('r'),
            KeyCode::Char('L'),
            KeyCode::Down,
            KeyCode::End,
            KeyCode::Enter,
            KeyCode::Tab,
            KeyCode::Char('/'),
            KeyCode::Esc,
        ] {
            all.extend(press(&mut m, k));
            // Every journey refresh the person asks for is answered.
            if let Some(Cmd::Send(r)) = all.last().cloned() {
                answer(&mut m, r, &journey(GEN));
            }
        }
    }
    for c in &all {
        match c {
            Cmd::Send(Req::Snapshot) | Cmd::ReadLogs => {}
            c => panic!("a startup check is never asked {c:?}"),
        }
    }
    m.logs_tab = omb_tui::app::LogsTab::Tool;
    for n in [2, 4, 5, 6] {
        go(&mut m, n);
        let f = frame(&m, 120, 40);
        assert!(
            f.contains("The startup check answers hello and"),
            "{n}:\n{f}"
        );
    }
}

/// Every state keeps its own words (docs/UX.md → *States every screen has*).
#[test]
fn every_state_keeps_its_words() {
    // Loading: the view and the status line say so at once.
    let mut m = ready();
    let c = go(&mut m, 2);
    assert_eq!(requests(&c), 1);
    let f = frame(&m, 120, 40);
    assert!(f.contains("Machine · reading"), "{f}");
    assert!(f.contains("Reading the core's answer."), "{f}");
    assert!(f.contains("reading machine details"), "{f}");
    // Empty: what would appear, and why there is none.
    let empty = opened(2, &[&format!("generation\tid={GEN}\ttotal=0\n{DONE}")]);
    assert!(frame(&empty, 120, 40).contains("The journey's read holds no machine rows."));
    let nolog = opened(
        5,
        &[
            &format!(
                "generation\tid={LGEN}\ttotal=0
fact\tscope=logs\tkey=logs.state_dir\tlabel=State\tvalue=/s\tstate=info
fact\tscope=logs\tkey=logs.directory\tlabel=Logs\tvalue=/s/logs\tstate=info
fact\tscope=logs\tkey=logs.lines\tlabel=Lines\tvalue=0\tstate=info
message\tlevel=info\ttext=No%20log%20yet.
{DONE}"
            ),
            &format!("generation\tid={LGEN}\ttotal=0\n{DONE}"),
        ],
    );
    let f = frame(&nolog, 120, 40);
    assert!(f.contains("No log yet."), "{f}");
    assert!(
        !f.contains("The selected log has no lines."),
        "no log is not an empty log:\n{f}"
    );
    let mut plan = ready();
    go(&mut plan, 6);
    assert!(frame(&plan, 120, 40).contains("Type the sizes, then ⏎ to check them."));
    // Partial: the counts the core gave, and the rows it did not, with why.
    let partial = opened(
        4,
        &[
            &format!("{HEALTH}{DONE}"),
            &format!(
                "generation\tid={EMPTY}\ttotal=0\nresult\tstatus=error\tcode=io\ttext=The%20health%20response%20could%20not%20be%20prepared.\tnext=\n"
            ),
        ],
    );
    let f = frame(&partial, 120, 40);
    assert!(f.contains("Passed 10") && f.contains("error · io"), "{f}");
    assert!(
        f.contains("The health response could not be prepared."),
        "{f}"
    );
    // Error: the core's code and words, and how to retry.
    let err = opened(
        3,
        &[&format!(
            "generation\tid={EMPTY}\ttotal=0\nresult\tstatus=error\tcode=representation\ttext=The%20required%20journey%20response%20cannot%20be%20represented%20in%20Protocol%201.\tnext=\n"
        )],
    );
    let f = frame(&err, 120, 40);
    assert!(
        f.contains("error · representation") && f.contains("r tries again · L shows the log"),
        "{f}"
    );
    // Blocked: the core's blocker and its fix, in the blocked token.
    let mut b = Model::default();
    let c = b.start();
    let c = answer(&mut b, sent(&c), DONE);
    answer(
        &mut b,
        sent(&c),
        &format!(
            "generation\tid={GEN}\ttotal=0\nguide\tid=next\tstep=1\ttext=This%20Mac%20cannot%20continue.\nblocker\tid=mac.1\ttext=The%20internal%20disk%27s%20layout%20could%20not%20be%20read%20exactly.\tfix=Run%20First%20Aid.\n{DONE}"
        ),
    );
    let t = profile("color");
    let buf = render(&b, &t, 120, 40);
    let f = text_of(&buf);
    assert!(
        f.contains("✗ blocked") && f.contains("Run First Aid."),
        "{f}"
    );
    let y = f.lines().position(|l| l.contains("✗ blocked")).unwrap() as u16;
    let x = (0..120).find(|&x| buf[(x, y)].symbol() == "✗").unwrap();
    assert!(
        buf[(x, y)]
            .modifier
            .contains(ratatui::style::Modifier::REVERSED)
    );
    // Changed: refused by the core for its generation.
    let mut ch = machine_model();
    let req = sent(
        &press(&mut ch, KeyCode::End)
            .into_iter()
            .chain(press(&mut ch, KeyCode::Char('r')))
            .collect::<Vec<_>>(),
    );
    let c = answer(&mut ch, req, &journey(GEN2));
    let page = sent(&c);
    assert!(
        bytes(&page).contains(&format!("generation={GEN2}")),
        "r reopens from the fresh snapshot"
    );
    answer(
        &mut ch,
        page,
        &format!(
            "generation\tid={GEN}\ttotal=6\nresult\tstatus=refused\tcode=changed\ttext=The%20journey%20dataset%20changed.\tnext=\n"
        ),
    );
    assert!(frame(&ch, 120, 40).contains("changed since you looked — r"));
    // No answer: never a negative finding, never "failed".
    let mut na = ready();
    let req = sent(&go(&mut na, 3));
    update(
        &mut na,
        Msg::Done(req, Outcome::Unknown("no result".into())),
    );
    let f = frame(&na, 120, 40);
    assert!(
        f.contains("no answer") && f.contains("The core stopped without answering (no result)."),
        "{f}"
    );
    assert!(!f.contains("failed"), "{f}");
    let mut ns = ready();
    let req = sent(&go(&mut ns, 3));
    update(&mut ns, Msg::Done(req, Outcome::NotSent("no core".into())));
    assert!(frame(&ns, 120, 40).contains("nothing ran"));
    // Too small: the size needed and the size now, nothing else.
    let f = frame(&health_model(), 59, 20);
    assert_eq!(f.lines().filter(|l| !l.trim().is_empty()).count(), 1, "{f}");
    assert!(f.contains("terminal too small — needs 60x20, this is 59x20"));
}

#[test]
fn the_plan_checks_refusals_keep_their_meaning() {
    for (body, want) in [
        (
            "normal\tname=shared_size\tvalue=0\ninvalid\tname=linux_size\tcode=leading-zero\ttext=Sizes%20cannot%20have%20a%20leading%20zero.\nresult\tstatus=refused\tcode=invalid\ttext=\tnext=\n".to_string(),
            ["refused · invalid", "✗ Linux size leading-zero", "Sizes cannot have a leading zero."],
        ),
        (
            "message\tlevel=warn\ttext=the%20stub%27s%20system%20volume%20is%20not%20mounted\nresult\tstatus=refused\tcode=unplannable\ttext=A%20trustworthy%20plan%20cannot%20be%20computed%20for%20this%20machine%20state.\tnext=\n".to_string(),
            ["refused · unplannable", "the stub's system volume is not mounted", "A trustworthy plan cannot be computed"],
        ),
        (
            "result\tstatus=error\tcode=invariant\ttext=The%20planner%27s%20internal%20checks%20did%20not%20hold.\tnext=\n".to_string(),
            ["error · invariant", "The planner's internal checks did not hold.", "For Linux 05GB"],
        ),
    ] {
        let mut m = ready();
        go(&mut m, 6);
        typed(&mut m, "05GB");
        let req = sent(&press(&mut m, KeyCode::Enter));
        let b = bytes(&req);
        assert!(b.contains("arg\tname=linux_size\tvalue=05GB\n") && !b.contains("shared_size"), "an empty field is not sent: {b}");
        answer(&mut m, req, &body);
        let f = frame(&m, 120, 40);
        for w in want {
            assert!(f.contains(w), "{w:?}:\n{f}");
        }
        assert!(!f.contains("Review basis"), "no basis without a valid answer");
    }
    // A size changed after the answer: the answer says it is for the old one.
    let mut m = plan_model();
    press(&mut m, KeyCode::Char('0'));
    assert!(frame(&m, 120, 40).contains("the sizes above changed since this answer"));
}

/// No action, save or execute anywhere on the read surface: the snapshot
/// lists none, and no key turns a read into one.
#[test]
fn the_read_surface_offers_no_action() {
    let mut m = ready();
    let mut all = Vec::new();
    for n in 0..NAV.len() {
        let c = go(&mut m, n);
        all.extend(c.clone());
        for k in [KeyCode::Enter, KeyCode::Down, KeyCode::Enter] {
            all.extend(press(&mut m, k));
        }
    }
    for c in &all {
        if let Cmd::Send(r) = c {
            assert!(!matches!(r, Req::Execute { .. }), "{r:?}");
            assert!(!bytes(r).contains("exec\t"));
        }
    }
    let f = frame(&ready(), 120, 40);
    assert!(f.contains("Nothing is available now."));
    assert!(f.contains("read-only · no system changes · fixture"), "{f}");
    let f = frame(&plan_model(), 120, 40);
    assert!(f.contains("saved, and no action is offered."), "{f}");
    assert!(!f.contains("Save"), "{f}");
}

#[test]
fn paging_lands_the_cursor_and_never_crosses_a_generation() {
    let mut m = ready();
    let req = sent(&go(&mut m, 3));
    let rows = |from: usize, n: usize| -> String {
        (from..from + n)
            .map(|i| format!("row\tkind=status\tkey={i}\tcol=Detected%20now\tcol=Line%20{i}\tcol=v{i}\tcol=\n"))
            .collect()
    };
    answer(
        &mut m,
        req,
        &format!("generation\tid={GEN}\ttotal=812\n{}{DONE}", rows(1, 500)),
    );
    let next = sent(&press(&mut m, KeyCode::End));
    assert!(bytes(&next).contains("offset=500\tlimit=500"));
    answer(
        &mut m,
        next,
        &format!("generation\tid={GEN}\ttotal=812\n{}{DONE}", rows(501, 312)),
    );
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("501–812 of 812") && f.contains("Line 812"),
        "the last row, focused:\n{f}"
    );
    let first = sent(&press(&mut m, KeyCode::Home));
    assert!(bytes(&first).contains("offset=0\tlimit=500"));
    answer(
        &mut m,
        first,
        &format!("generation\tid={GEN}\ttotal=812\n{}{DONE}", rows(1, 500)),
    );
    assert_eq!(
        requests(&press(&mut m, KeyCode::Up)),
        0,
        "the first page has nothing before it"
    );
    // A filter applies to the loaded page only: it never fetches.
    press(&mut m, KeyCode::Char('/'));
    typed(&mut m, "Line 49");
    press(&mut m, KeyCode::Enter);
    assert_eq!(requests(&press(&mut m, KeyCode::End)), 0);
    assert_eq!(requests(&press(&mut m, KeyCode::PageDown)), 0);
    // A page from another generation is never shown as this one's.
    press(&mut m, KeyCode::Char('/'));
    press(&mut m, KeyCode::Esc);
    let next = sent(&press(&mut m, KeyCode::End));
    answer(
        &mut m,
        next,
        &format!("generation\tid={GEN2}\ttotal=812\n{}{DONE}", rows(501, 312)),
    );
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("changed since you looked") && f.contains("1–500 of 812"),
        "{f}"
    );
    assert_eq!(
        requests(&press(&mut m, KeyCode::End)),
        0,
        "a changed view is reopened with r, not paged"
    );
}

#[test]
fn the_keyboard_reaches_every_screen_and_back() {
    let mut m = ready();
    for (n, s) in NAV.iter().enumerate() {
        go(&mut m, n);
        assert_eq!(m.screen, *s);
        let f = frame(&m, 100, 30);
        assert!(f.lines().next().unwrap().contains(s.title()), "{f}");
        // Esc is back, from every screen and from the size fields.
        press(&mut m, KeyCode::Esc);
        assert_eq!(m.screen, Screen::Dashboard, "{s:?}");
    }
    // Tab and the arrows move between the rail and the workspace; the rail's
    // pointer is the only focus marker while it has the keys.
    press(&mut m, KeyCode::Tab);
    let f = frame(&m, 100, 30);
    assert_eq!(f.matches('❯').count(), 1, "{f}");
    press(&mut m, KeyCode::Right);
    assert_eq!(m.screen, Screen::Dashboard);
    // L reaches the logs from anywhere a field does not have the keys.
    let mut h = health_model();
    assert!(requests(&press(&mut h, KeyCode::Char('L'))) == 1);
    assert_eq!(h.screen, Screen::Logs);
    // At narrow widths the sidebar is a view of its own, on s.
    let mut n = ready();
    press(&mut n, KeyCode::Char('s'));
    let f = frame(&n, 60, 24);
    assert!(
        f.contains("This machine")
            && f.contains("MacBookPro18,1")
            && !f.contains("Where it stands"),
        "{f}"
    );
    press(&mut n, KeyCode::Esc);
    assert!(frame(&n, 60, 24).contains("Where it stands"));
}

#[test]
fn help_lists_the_keys_of_the_screen_it_was_opened_from() {
    let mut m = logs_model();
    press(&mut m, KeyCode::Char('?'));
    let f = frame(&m, 100, 30);
    for want in [
        "next level",
        "diagnostics",
        "filter",
        "The mouse is not captured",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    press(&mut m, KeyCode::Esc);
    assert_eq!(m.screen, Screen::Logs);
    let mut p = ready();
    go(&mut p, 6);
    // In the size field ? is text: the rail first, then help, which lists the
    // field's keys beside the rail's.
    press(&mut p, KeyCode::Char('?'));
    assert_eq!(p.plan.linux, "?");
    press(&mut p, KeyCode::Backspace);
    press(&mut p, KeyCode::Left);
    press(&mut p, KeyCode::Char('?'));
    let f = frame(&p, 100, 30);
    assert!(
        f.contains("type it, as 250GB, 1.5TB or 30%") && f.contains("next field"),
        "{f}"
    );
}

/// Each read screen at each contract size: the text snapshot where it
/// matters, and everywhere that every line stays inside the terminal.
#[test]
fn read_screens_at_every_size() {
    let screens = [
        ("dashboard", ready()),
        ("welcome", opened(0, &[])),
        ("machine", machine_model()),
        ("health", health_model()),
        ("logs", logs_model()),
        ("plan", plan_model()),
    ];
    for (name, m) in &screens {
        for (w, h) in [(120, 40), (100, 30), (80, 24), (60, 24), (60, 20)] {
            let b = render(m, &profile("color"), w, h);
            let f = text_of(&b);
            assert!(
                f.lines().all(|l| widgets_width(l) <= w as usize),
                "{name} {w}x{h}"
            );
            assert!(
                f.lines().next().unwrap().contains("v0.2.0"),
                "{name} {w}x{h}:\n{f}"
            );
            let snap = matches!(
                (*name, w, h),
                ("dashboard", _, _)
                    | ("welcome", 120, 40)
                    | ("welcome", 60, 24)
                    | ("machine", 80, 24)
                    | ("health", 120, 40)
                    | ("health", 60, 24)
                    | ("logs", 80, 24)
                    | ("logs", 60, 20)
                    | ("plan", 80, 24)
            );
            if snap {
                insta::assert_snapshot!(format!("read_{name}_{w}x{h}"), f);
            }
        }
    }
    // Below the floor: the truthful stop.
    let f = frame(&ready(), 59, 20);
    assert!(f.contains("terminal too small — needs 60x20, this is 59x20"));
}

fn widgets_width(s: &str) -> usize {
    ratatui::text::Span::raw(s).width()
}

/// Every read screen in every profile: ASCII draws only ASCII and no
/// 256-colour; sixteen colours name colours only; no colour means none at
/// all; the navy backdrop only at 256. The words survive each.
#[test]
fn read_screens_keep_meaning_in_every_profile() {
    let models = [
        ready(),
        opened(0, &[]),
        machine_model(),
        health_model(),
        logs_model(),
        plan_model(),
    ];
    for m in &models {
        for (w, h) in [(120, 40), (80, 24), (60, 20)] {
            let a = render(m, &profile("ascii"), w, h);
            for c in a.content() {
                assert!(
                    c.symbol().is_ascii(),
                    "ASCII only at {w}x{h}: {:?} on {:?}",
                    c.symbol(),
                    m.screen
                );
                assert!(
                    !matches!(c.fg, Color::Indexed(_) | Color::Rgb(..)),
                    "{w}x{h}"
                );
            }
            for c in render(m, &profile("nocolor"), w, h).content() {
                assert_eq!(
                    (c.fg, c.bg),
                    (Color::Reset, Color::Reset),
                    "no colour at {w}x{h}"
                );
            }
            for c in render(m, &profile("sixteen"), w, h).content() {
                assert!(!matches!(c.fg, Color::Indexed(_) | Color::Rgb(..)));
                assert_eq!(c.bg, Color::Reset, "the terminal's own background");
            }
            for c in render(m, &profile("color"), w, h).content() {
                assert!(
                    c.bg == Color::Indexed(17)
                        || c.modifier.contains(ratatui::style::Modifier::REVERSED),
                    "the backdrop at 256 colours"
                );
            }
        }
    }
    let a = text_of(&render(&health_model(), &profile("ascii"), 120, 40));
    assert!(
        a.contains("+ pass") && a.contains("! warn") && a.contains("- info"),
        "{a}"
    );
    let n = text_of(&render(&health_model(), &profile("nocolor"), 120, 40));
    assert!(n.contains("✓ pass") && n.contains("! warn"), "{n}");
    let a = text_of(&render(&ready(), &profile("ascii"), 120, 40));
    assert!(
        a.contains("_-----_") && a.contains("every station is later"),
        "{a}"
    );
}

/// Wide characters and long values stay inside their panel.
#[test]
fn wide_and_long_values_stay_inside_the_panel() {
    let mut m = ready();
    let req = sent(&go(&mut m, 2));
    answer(
        &mut m,
        req,
        &format!(
            "generation\tid={GEN}\ttotal=2
row\tkind=machine\tkey=machine.model\tcol=Model\tcol=%E6%97%A5%E6%9C%AC%E8%AA%9E%E3%81%AE%E3%83%9E%E3%82%B7%E3%83%B3{}
row\tkind=machine\tkey=machine.long\tcol=A%20label%20much%20longer%20than%20the%20column\tcol={}
{DONE}",
            "x".repeat(80),
            "y".repeat(300)
        ),
    );
    for (w, h) in [(120, 40), (80, 24), (60, 20)] {
        let b = render(&m, &profile("color"), w, h);
        let f = text_of(&b);
        assert!(f.contains('日') && f.contains('語'), "{f}");
        // The workspace's right edge is intact on every row of its panel.
        let right = match w {
            120 => 24 + 64 - 1,
            80 => 16 + 64 - 1,
            _ => w - 1,
        };
        let top = (0..h).find(|&y| b[(right, y)].symbol() == "┐").unwrap();
        let bottom = (top + 1..h)
            .find(|&y| b[(right, y)].symbol() == "┘")
            .unwrap();
        for y in top + 1..bottom {
            assert_eq!(b[(right, y)].symbol(), "│", "{w}x{h} row {y}:\n{f}");
        }
    }
    // Enter shows the focused row's full values.
    press(&mut m, KeyCode::Down);
    press(&mut m, KeyCode::Enter);
    let f = frame(&m, 120, 40);
    assert!(f.contains(&"y".repeat(50)), "{f}");
}

/// The plan's answer scrolls while the size fields keep the typing keys: at
/// 80×24 the review basis is a page down, never cut away.
#[test]
fn the_plan_answer_scrolls_to_its_basis() {
    let mut m = plan_model();
    let f = frame(&m, 80, 24);
    assert!(!f.contains("Review basis"), "{f}");
    assert_eq!(requests(&press(&mut m, KeyCode::PageDown)), 0);
    let f = frame(&m, 80, 24);
    assert!(f.contains("Review basis") && f.contains("8acb8acb"), "{f}");
    // Typing goes to the field and brings it back into view.
    press(&mut m, KeyCode::Char('0'));
    assert!(frame(&m, 80, 24).contains("Shared size  100GB0"));
}

// --- A refresh never pairs one generation's facts with another's rows -------

use omb_tui::read::{Kind, Scope};

/// A generation id made of one repeated byte pair, so its first twelve
/// characters (what the frame shows) say which read it is.
fn id_of(pair: &str) -> String {
    pair.repeat(32)
}

/// The line of F that holds NEEDLE.
fn line_with<'a>(f: &'a str, needle: &str) -> &'a str {
    f.lines()
        .find(|l| l.contains(needle))
        .unwrap_or_else(|| panic!("{needle:?} in:\n{f}"))
}

fn logs_snap(g: &str, source: &str) -> String {
    format!(
        "generation\tid={g}\ttotal=0
fact\tscope=logs\tkey=logs.state_dir\tlabel=State\tvalue=/s\tstate=info
fact\tscope=logs\tkey=logs.directory\tlabel=Logs\tvalue=/s/logs\tstate=info
fact\tscope=logs\tkey=logs.source\tlabel=Source\tvalue={source}\tstate=info
fact\tscope=logs\tkey=logs.lines\tlabel=Lines\tvalue=1\tstate=info
{DONE}"
    )
}

fn log_page(g: &str, message: &str) -> String {
    format!(
        "generation\tid={g}\ttotal=1\nrow\tkind=log\tkey=1\tcol=2026-10-04T10:00:00Z\tcol=info\tcol=%5BSURVEY%5D\tcol={message}\n{DONE}"
    )
}

fn health_snap(g: &str, pass: u32, warn: u32, fail: u32) -> String {
    format!(
        "generation\tid={g}\ttotal=0
fact\tscope=health\tkey=doctor.pass\tlabel=Passed\tvalue={pass}\tstate=info
fact\tscope=health\tkey=doctor.warn\tlabel=Warnings\tvalue={warn}\tstate=info
fact\tscope=health\tkey=doctor.fail\tlabel=Failures\tvalue={fail}\tstate=info
{DONE}"
    )
}

fn doctor_page(g: &str, label: &str) -> String {
    format!(
        "generation\tid={g}\ttotal=1\nrow\tkind=doctor\tkey=1\tcol=warn\tcol={label}\tcol=a%20finding\n{DONE}"
    )
}

/// The ways a replacement page can end without its rows: no answer, never
/// sent, refused (the core holds yet another generation) and an error.
fn unanswered(m: &mut Model, page: Req, how: &str) {
    match how {
        "no answer" => {
            update(m, Msg::Done(page, Outcome::Unknown("no result".into())));
        }
        "not sent" => {
            update(m, Msg::Done(page, Outcome::NotSent("no core".into())));
        }
        "refused" => {
            answer(
                m,
                page,
                &format!(
                    "generation\tid={}\ttotal=0\nresult\tstatus=refused\tcode=changed\ttext=The%20dataset%20changed.\tnext=\n",
                    id_of("c3")
                ),
            );
        }
        _ => {
            answer(
                m,
                page,
                &format!(
                    "generation\tid={EMPTY}\ttotal=0\nresult\tstatus=error\tcode=io\ttext=The%20response%20could%20not%20be%20prepared.\tnext=\n"
                ),
            );
        }
    }
}

const ENDINGS: [(&str, &str); 4] = [
    ("no answer", "no answer"),
    ("not sent", "not sent"),
    ("refused", "changed since you looked"),
    ("error", "error · io"),
];

/// G2-FE-002, Logs: lines of A.log (g1), then a refresh whose snapshot
/// selects B.log (g2). Until B's lines are admitted, the frame shows A.log
/// above A's lines and names both generations; B.log never heads ONLY_A,
/// whether the replacement is pending, unanswered, unsent, refused or failed.
/// Admitted, B.log, ONLY_B and g2 are shown together and A is gone.
#[test]
fn logs_source_and_lines_are_always_one_generation() {
    let (ga, gb) = (id_of("a1"), id_of("b2"));
    let stale = || {
        let mut m = ready();
        let req = sent(&press(&mut m, KeyCode::Char('L')));
        let det = sent(&answer(&mut m, req, &logs_snap(&ga, "A.log")));
        answer(&mut m, det, &log_page(&ga, "ONLY_A"));
        let f = frame(&m, 120, 40);
        assert!(line_with(&f, "Source ").contains("A.log"), "{f}");
        assert!(line_with(&f, "ONLY_A").contains("[SURVEY]"), "{f}");
        assert!(line_with(&f, "rows 1").contains(&ga[..12]), "{f}");
        let req = sent(&press(&mut m, KeyCode::Char('r')));
        assert_eq!(req, Req::Read(Scope::Logs));
        let page = sent(&answer(&mut m, req, &logs_snap(&gb, "B.log")));
        assert!(
            bytes(&page).contains(&format!("kind=log\tgeneration={gb}\toffset=0")),
            "the replacement is asked of the new generation: {}",
            bytes(&page)
        );
        (m, page)
    };
    let held = |m: &Model, what: &str| {
        for (w, h) in [(120, 40), (80, 24), (60, 20)] {
            let f = frame(m, w, h);
            assert!(
                !f.contains("B.log"),
                "{what} {w}x{h}: B.log never heads A's lines:\n{f}"
            );
        }
        let f = frame(m, 120, 40);
        assert!(line_with(&f, "Source ").contains("A.log"), "{what}:\n{f}");
        assert!(f.contains("ONLY_A"), "{what}:\n{f}");
        assert!(
            line_with(&f, "rows 1").contains(&ga[..12]),
            "{what}: the lines' own generation:\n{f}"
        );
        assert!(
            line_with(&f, "shown:").contains(&ga[..12]) && f.contains(&gb[..12]),
            "{what}: the frame names the read shown and the newest:\n{f}"
        );
        f
    };
    let (m, _) = stale();
    let f = held(&m, "pending");
    assert!(f.contains("Logs · reading"), "{f}");
    for (how, words) in ENDINGS {
        let (mut m, page) = stale();
        unanswered(&mut m, page, how);
        let f = held(&m, how);
        assert!(f.contains(words), "{how}: {words:?}:\n{f}");
        assert!(!f.contains("Logs · reading"), "{how}:\n{f}");
    }
    let (mut m, page) = stale();
    let c = answer(&mut m, page, &log_page(&gb, "ONLY_B"));
    assert_eq!(requests(&c), 0);
    for (w, h) in [(120, 40), (60, 20)] {
        let f = frame(&m, w, h);
        assert!(line_with(&f, "Source ").contains("B.log"), "{w}x{h}:\n{f}");
        assert!(
            line_with(&f, "ONLY_B").contains("[SURVEY]"),
            "{w}x{h}:\n{f}"
        );
        assert!(line_with(&f, "rows 1").contains(&gb[..12]), "{w}x{h}:\n{f}");
        for gone in ["A.log", "ONLY_A", &ga[..12], "shown:", "changed since"] {
            assert!(!f.contains(gone), "{w}x{h}: {gone:?}:\n{f}");
        }
    }
}

/// G2-FE-002, Health: counts A over finding ONLY_A (g1), then a refresh to
/// counts B (g2). Counts B are never drawn over ONLY_A, whatever becomes of
/// the replacement; admitted, counts B and finding ONLY_B are shown together.
#[test]
fn health_counts_summarise_only_the_findings_shown() {
    let (ga, gb) = (id_of("d4"), id_of("e5"));
    let stale = || {
        let mut m = ready();
        let req = sent(&go(&mut m, 4));
        let det = sent(&answer(&mut m, req, &health_snap(&ga, 10, 1, 0)));
        answer(&mut m, det, &doctor_page(&ga, "ONLY_A"));
        let f = frame(&m, 120, 40);
        assert!(
            line_with(&f, "Passed ").contains("Passed 10    Warnings 1    Failures 0"),
            "{f}"
        );
        let req = sent(&press(&mut m, KeyCode::Char('r')));
        assert_eq!(req, Req::Read(Scope::Health));
        let page = sent(&answer(&mut m, req, &health_snap(&gb, 21, 4, 2)));
        assert!(bytes(&page).contains(&format!("kind=doctor\tgeneration={gb}\toffset=0")));
        (m, page)
    };
    let held = |m: &Model, what: &str| {
        for (w, h) in [(120, 40), (80, 24), (60, 20)] {
            let f = frame(m, w, h);
            for b in ["Passed 21", "Warnings 4", "Failures 2"] {
                assert!(
                    !f.contains(b),
                    "{what} {w}x{h}: {b:?} never summarises ONLY_A:\n{f}"
                );
            }
        }
        let f = frame(m, 120, 40);
        assert!(
            line_with(&f, "Passed ").contains("Passed 10    Warnings 1    Failures 0"),
            "{what}:\n{f}"
        );
        assert!(f.contains("ONLY_A"), "{what}:\n{f}");
        assert!(line_with(&f, "rows 1").contains(&ga[..12]), "{what}:\n{f}");
        assert!(
            line_with(&f, "shown:").contains(&ga[..12]) && f.contains(&gb[..12]),
            "{what}:\n{f}"
        );
        f
    };
    let (m, _) = stale();
    assert!(held(&m, "pending").contains("Health · reading"));
    for (how, words) in ENDINGS {
        let (mut m, page) = stale();
        unanswered(&mut m, page, how);
        assert!(held(&m, how).contains(words), "{how}: {words:?}");
    }
    let (mut m, page) = stale();
    answer(&mut m, page, &doctor_page(&gb, "ONLY_B"));
    let f = frame(&m, 120, 40);
    assert!(
        line_with(&f, "Passed ").contains("Passed 21    Warnings 4    Failures 2"),
        "{f}"
    );
    assert!(line_with(&f, "ONLY_B").contains("warn"), "{f}");
    assert!(line_with(&f, "rows 1").contains(&gb[..12]), "{f}");
    for gone in ["Passed 10", "ONLY_A", &ga[..12], "shown:"] {
        assert!(!f.contains(gone), "{gone:?}:\n{f}");
    }
}

// --- An open value is read to its last character -----------------------------

const MARK: &str = "UNIQUE_TRAILING_MARKER";
/// The open value's first line, as drawn under its row (the row's own cell, cut
/// short, begins with the same word).
const START: &str = "       word000 ";

/// About 1,500 characters of words, the marker last: legal in every column
/// (a value may be 4 KiB), and longer than a 60×20 view can show at once.
fn long_value() -> String {
    let words: Vec<String> = (0..180).map(|i| format!("word{i:03}")).collect();
    format!("{} {MARK}", words.join(" "))
}

fn encoded(s: &str) -> String {
    s.replace(' ', "%20")
}

/// The keys while a value is open, each drawn at W×H before the next, as the
/// event loop draws between keys; the commands they made.
fn keys_drawn(m: &mut Model, keys: &[KeyCode], w: u16, h: u16) -> Vec<Cmd> {
    let mut out = Vec::new();
    for k in keys {
        out.extend(press(m, *k));
        frame(m, w, h);
    }
    out
}

/// G2-FE-003: at 60×20 a long log line's suffix is reached from the
/// keyboard. Opened, the value shows its start; the arrows (and j k) scroll
/// it, PgUp PgDn by a page, Home End (and g G) to either end, with no key
/// that does nothing at an end; Esc or Enter close it and the arrows move
/// rows again. None of it asks the core anything or changes what was loaded.
#[test]
fn an_open_value_scrolls_to_its_last_character() {
    let (w, h) = (60, 20);
    let mut m = opened(
        5,
        &[
            &logs_snap(LGEN, "omarchy-bootstrap-20261004.log"),
            &format!(
                "generation\tid={LGEN}\ttotal=2\nrow\tkind=log\tkey=1\tcol=2026-10-04T10:00:00Z\tcol=info\tcol=%5BPLAN%5D\tcol={}\nrow\tkind=log\tkey=2\tcol=\tcol=\tcol=\tcol=SECOND_ROW\n{DONE}",
                encoded(&long_value())
            ),
        ],
    );
    let before = m.detail(Kind::Log).unwrap().clone();
    let snap = m.logread.snap.clone();
    let mut cmds = Vec::new();
    let f = frame(&m, w, h);
    assert!(!f.contains(MARK), "collapsed:\n{f}");
    cmds.extend(keys_drawn(&mut m, &[KeyCode::Enter], w, h));
    let f = frame(&m, w, h);
    assert!(
        f.contains(START) && !f.contains(MARK),
        "opened at its start:\n{f}"
    );
    assert!(line_with(&f, "value lines 1–").contains(&LGEN[..12]), "{f}");
    // Down, one line at a time, until the suffix is drawn.
    let mut presses = 0;
    while !frame(&m, w, h).contains(MARK) {
        presses += 1;
        assert!(
            presses <= 200,
            "the suffix is never reached:\n{}",
            frame(&m, w, h)
        );
        let k = if presses % 2 == 0 {
            KeyCode::Down
        } else {
            KeyCode::Char('j')
        };
        cmds.extend(keys_drawn(&mut m, &[k], w, h));
    }
    let f = frame(&m, w, h);
    assert!(presses > 5, "the value overflowed the view: {presses}");
    assert!(!f.contains(START), "the start scrolled away:\n{f}");
    assert_eq!(m.detail(Kind::Log).unwrap().cursor, 0, "the row stays");
    // Past the end nothing moves, and one step back moves at once.
    cmds.extend(keys_drawn(
        &mut m,
        &[KeyCode::Down, KeyCode::PageDown],
        w,
        h,
    ));
    assert!(frame(&m, w, h).contains(MARK));
    cmds.extend(keys_drawn(&mut m, &[KeyCode::Up], w, h));
    assert!(!frame(&m, w, h).contains(MARK), "Up leaves the end at once");
    // The ends, both ways, and a page.
    for (k, start, end) in [
        (KeyCode::Home, true, false),
        (KeyCode::End, false, true),
        (KeyCode::PageUp, false, false),
        (KeyCode::PageDown, false, true),
        (KeyCode::Char('g'), true, false),
        (KeyCode::Char('G'), false, true),
        (KeyCode::Char('k'), false, false),
    ] {
        cmds.extend(keys_drawn(&mut m, &[k], w, h));
        let f = frame(&m, w, h);
        assert_eq!(
            (f.contains(START), f.contains(MARK)),
            (start, end),
            "{k:?}:\n{f}"
        );
    }
    assert_eq!(requests(&cmds), 0, "scrolling asks nothing: {cmds:?}");
    // Esc closes it: the screen, the rows and their keys come back.
    assert_eq!(requests(&press(&mut m, KeyCode::Esc)), 0);
    assert_eq!(m.screen, Screen::Logs);
    let f = frame(&m, w, h);
    assert!(!f.contains(MARK) && f.contains("rows 1–2 of 2"), "{f}");
    assert_eq!(requests(&press(&mut m, KeyCode::Down)), 0);
    assert_eq!(
        m.detail(Kind::Log).unwrap().cursor,
        1,
        "the arrows move rows"
    );
    // Enter closes it too, and it opens again at its start.
    press(&mut m, KeyCode::Up);
    keys_drawn(
        &mut m,
        &[KeyCode::Enter, KeyCode::End, KeyCode::Enter],
        w,
        h,
    );
    assert!(!frame(&m, w, h).contains(MARK), "Enter closed it");
    keys_drawn(&mut m, &[KeyCode::Enter], w, h);
    assert!(frame(&m, w, h).contains(START), "reopened at its start");
    press(&mut m, KeyCode::Esc);
    // What was loaded, from which generation, at which offset: unchanged.
    let after = m.detail(Kind::Log).unwrap();
    assert_eq!(
        (
            &after.generation,
            after.offset,
            after.total,
            &after.rows,
            after.loaded,
            after.changed,
            &after.fault
        ),
        (
            &before.generation,
            before.offset,
            before.total,
            &before.rows,
            before.loaded,
            before.changed,
            &before.fault
        )
    );
    assert_eq!(m.logread.snap, snap);
    assert!(m.pending.is_none());
}

/// The same reach on every detail kind (machine, status, health, log) at the
/// floor and at a larger layout, and the next page still read on request
/// once the value is closed.
#[test]
fn every_detail_kinds_open_value_reaches_its_end() {
    let v = encoded(&long_value());
    let machine = format!(
        "generation\tid={GEN}\ttotal=1\nrow\tkind=machine\tkey=machine.long\tcol=Long\tcol={v}\n{DONE}"
    );
    // One row of a status read longer than the page asked for.
    let status = format!(
        "generation\tid={GEN}\ttotal=812\nrow\tkind=status\tkey=1\tcol=Detected%20now\tcol=Long\tcol={v}\tcol=\n{DONE}"
    );
    let doctor = format!(
        "generation\tid={HGEN}\ttotal=1\nrow\tkind=doctor\tkey=1\tcol=warn\tcol=Long\tcol={v}\n{DONE}"
    );
    let log = format!(
        "generation\tid={LGEN}\ttotal=1\nrow\tkind=log\tkey=1\tcol=\tcol=\tcol=\tcol={v}\n{DONE}"
    );
    for kind in Kind::ALL {
        for (w, h) in [(60, 20), (100, 30), (120, 40)] {
            let mut m = match kind {
                Kind::Machine => opened(2, &[&machine]),
                Kind::Status => opened(3, &[&status]),
                Kind::Doctor => opened(4, &[&format!("{HEALTH}{DONE}"), &doctor]),
                Kind::Log => opened(5, &[&format!("{LOGS}{DONE}"), &log]),
            };
            let mut cmds = keys_drawn(&mut m, &[KeyCode::Enter], w, h);
            assert!(frame(&m, w, h).contains(START), "{kind:?} {w}x{h}");
            cmds.extend(keys_drawn(&mut m, &[KeyCode::End], w, h));
            let f = frame(&m, w, h);
            assert!(f.contains(MARK), "{kind:?} {w}x{h}:\n{f}");
            cmds.extend(keys_drawn(&mut m, &[KeyCode::Home, KeyCode::Esc], w, h));
            assert_eq!(requests(&cmds), 0, "{kind:?} {w}x{h}");
            assert!(!frame(&m, w, h).contains(MARK), "{kind:?} {w}x{h}");
            assert_eq!(m.screen.kind(), Some(kind));
            if kind == Kind::Status {
                // Closed, the rows' keys are back: past the loaded page, the
                // next page of the same generation is read on request.
                let next = sent(&press(&mut m, KeyCode::Down));
                assert!(
                    bytes(&next).contains(&format!(
                        "kind=status\tgeneration={GEN}\toffset=1\tlimit=500"
                    )),
                    "{}",
                    bytes(&next)
                );
            }
        }
    }
}

/// The core's refusal of a log window it cannot represent (docs/PROTOCOL.md
/// → *CP0-Q3b-overflow*): empty generation, fixed words.
const OVERFLOW: &str = "generation\tid=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\ttotal=0\nresult\tstatus=refused\tcode=overflow\ttext=The%20selected%20log%20window%20cannot%20be%20represented%20in%20Protocol%201.\tnext=\n";

/// G2-FE-003 at the floor: a long line of A.log (g1) is shown; a refresh
/// admits B.log's snapshot (g2) and its lines are refused as overflow. At
/// 60×20 the frame keeps A's line under A's facts and names both reads and
/// the refusal, which leaves the rows one line. Opened, the value is still
/// read to its last character from the keyboard while the frame says it is
/// g1's and that g2's lines were refused; closed, the detail is drawn as it
/// was, its rows move again, and nothing was asked of the core or changed.
#[test]
fn a_retained_value_is_read_to_its_end_beside_a_newer_reads_refusal() {
    let (w, h) = (60, 20);
    let (ga, gb) = (id_of("a1"), id_of("b2"));
    let mut m = ready();
    // A page of two lines of a three-line window, so one more is A's to read.
    m.limit = 2;
    let req = sent(&press(&mut m, KeyCode::Char('L')));
    let det = sent(&answer(&mut m, req, &logs_snap(&ga, "A.log")));
    assert!(bytes(&det).contains(&format!("generation={ga}\toffset=0\tlimit=2")));
    answer(
        &mut m,
        det,
        &format!(
            "generation\tid={ga}\ttotal=3\nrow\tkind=log\tkey=1\tcol=2026-10-04T10:00:00Z\tcol=info\tcol=%5BPLAN%5D\tcol={}\nrow\tkind=log\tkey=2\tcol=\tcol=\tcol=\tcol=SECOND_ROW\n{DONE}",
            encoded(&long_value())
        ),
    );
    let req = sent(&press(&mut m, KeyCode::Char('r')));
    assert_eq!(req, Req::Read(Scope::Logs));
    let page = sent(&answer(&mut m, req, &logs_snap(&gb, "B.log")));
    assert!(bytes(&page).contains(&format!("kind=log\tgeneration={gb}\toffset=0")));
    assert_eq!(requests(&answer(&mut m, page, OVERFLOW)), 0);
    // Whose lines these are, and what became of the newer read's.
    let truthful = |f: &str, what: &str| {
        assert!(
            !f.contains("B.log"),
            "{what}: B.log never heads A's line:\n{f}"
        );
        assert!(
            line_with(f, "shown:").contains(&ga[..12]) && f.contains(&gb[..12]),
            "{what}: the read shown and the newest:\n{f}"
        );
        assert!(f.contains("refused · overflow"), "{what}:\n{f}");
    };
    let closed = frame(&m, w, h);
    truthful(&closed, "closed");
    assert!(line_with(&closed, "Source ").contains("A.log"), "{closed}");
    assert!(
        closed.contains("The selected log window cannot be"),
        "{closed}"
    );
    assert!(
        line_with(&closed, "rows 1–2 of 3").contains(&ga[..12]),
        "{closed}"
    );
    let before = m.detail(Kind::Log).unwrap().clone();
    let read = m.logread.clone();
    // Opened: the start, then Down until the suffix is drawn.
    let mut cmds = keys_drawn(&mut m, &[KeyCode::Enter], w, h);
    let f = frame(&m, w, h);
    assert!(!f.contains(MARK), "opened at its start:\n{f}");
    insta::assert_snapshot!("read_logs_value_held_60x20", f);
    let mut presses = 0;
    while !frame(&m, w, h).contains(MARK) {
        presses += 1;
        assert!(
            presses <= 200,
            "the suffix is never reached at {w}x{h}:\n{}",
            frame(&m, w, h)
        );
        cmds.extend(keys_drawn(&mut m, &[KeyCode::Down], w, h));
    }
    let f = frame(&m, w, h);
    assert!(presses > 1, "the value overflowed the view: {presses}");
    truthful(&f, "open");
    assert!(
        line_with(&f, "value lines").contains(&ga[..12])
            && !line_with(&f, "value lines").contains(&gb[..12]),
        "the value is g1's:\n{f}"
    );
    // Either end, and no key that does nothing short of one.
    for (k, start, end) in [
        (KeyCode::Down, false, true),
        (KeyCode::PageDown, false, true),
        (KeyCode::Home, true, false),
        (KeyCode::Up, true, false),
        (KeyCode::End, false, true),
        (KeyCode::Up, false, false),
        (KeyCode::Char('g'), true, false),
        (KeyCode::Char('G'), false, true),
    ] {
        cmds.extend(keys_drawn(&mut m, &[k], w, h));
        let f = frame(&m, w, h);
        assert_eq!(
            (f.contains(START), f.contains(MARK)),
            (start, end),
            "{k:?}:\n{f}"
        );
        truthful(&f, &format!("{k:?}"));
    }
    assert_eq!(
        requests(&cmds),
        0,
        "reading the value asks nothing: {cmds:?}"
    );
    // Closed: the detail as it was, nothing loaded or read changed.
    assert_eq!(requests(&press(&mut m, KeyCode::Esc)), 0);
    assert_eq!(frame(&m, w, h), closed);
    assert_eq!(m.detail(Kind::Log).unwrap(), &before);
    assert_eq!(m.logread, read);
    assert!(m.pending.is_none());
    // The rows' keys are back; past the loaded page nothing is asked, as a
    // changed view is reopened with r, and A's next page is still g1's.
    assert_eq!(requests(&press(&mut m, KeyCode::Down)), 0);
    assert_eq!(
        m.detail(Kind::Log).unwrap().cursor,
        1,
        "the arrows move rows"
    );
    assert_eq!(requests(&press(&mut m, KeyCode::Down)), 0);
    let d = m.detail(Kind::Log).unwrap();
    assert_eq!(
        d.next(m.limit).map(|p| (p.generation, p.offset)),
        Some((ga.clone(), 2))
    );
    // Enter closes it too.
    press(&mut m, KeyCode::Up);
    keys_drawn(
        &mut m,
        &[KeyCode::Enter, KeyCode::End, KeyCode::Enter],
        w,
        h,
    );
    assert_eq!(frame(&m, w, h), closed);
}
