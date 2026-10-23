//! `actions-*` in the frontend (docs/TESTING.md → *Layers* A–C and E): the
//! generic requests and the installer's screens — 12 the storage planner, 13
//! the gate over the core's `gate.<action>.*` facts, 14 the Asahi handoff,
//! 15 the Linux continuation, 18 Omarchy Mac's progress, 19 Shared creation,
//! and the parameter form of any other action — driven only through the
//! model's boundary, keys in, request bytes and frames out. Every answer is
//! protocol text admitted by the frontend's own admission, shaped as the
//! action table's rows will answer; the frontend shows only what the
//! snapshot lists, asks only for the parameters it declares, and sends back
//! the basis it was shown.

use omb_tui::app::{Cmd, Model, Msg, Outcome, Req, Screen, update};
use omb_tui::core::{Session, op_of};
use omb_tui::read::{Kind, Page, Scope};
use omb_tui::record::{Family, admit};
use omb_tui::screens;
use omb_tui::theme::{Caps, Depth, Theme};
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::buffer::Buffer;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::style::Color;

pub const GEN: &str = "c0dec0dec0dec0dec0dec0dec0dec0dec0dec0dec0dec0dec0dec0dec0dec0de";
pub const BASIS: &str = "5f2ec1a05f2ec1a05f2ec1a05f2ec1a05f2ec1a05f2ec1a05f2ec1a05f2ec1a0";
pub const REVIEW: &str = "8acb8acb8acb8acb8acb8acb8acb8acb8acb8acb8acb8acb8acb8acb8acb8acb";
pub const DONE: &str = "result\tstatus=done\tcode=ok\ttext=\tnext=\n";
const TOKEN: &str = "omb2:enc%3D1,user%3Dalex,host%3Dm1pro,kmap%3Dus,tz%3DAmerica/New_York,loc%3Den_US.UTF-8,ssh%3D0,gh%3Doctocat,linux%3D250,shared%3D150,dev%3D1,plan%3D1a2b3c4d";

pub fn hello_line(platform: &str) -> String {
    format!(
        "hello\tcore=0.2.0\tcommit=0123456789abcdef0123456789abcdef01234567\tsource={}\tproto=1\tplatform={platform}\tarch={}\tuser=user\tceiling=act\tdry_run=0\tfixture=1\n",
        "a4e5".repeat(16),
        if platform == "linux" {
            "aarch64"
        } else {
            "arm64"
        }
    )
}

pub fn press(m: &mut Model, c: KeyCode) -> Vec<Cmd> {
    update(m, Msg::Key(KeyEvent::new(c, KeyModifiers::NONE)))
}

pub fn typed(m: &mut Model, s: &str) -> Vec<Cmd> {
    let mut out = Vec::new();
    for c in s.chars() {
        out.extend(press(m, KeyCode::Char(c)));
    }
    out
}

pub fn sent(cmds: &[Cmd]) -> Req {
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

pub fn requests(cmds: &[Cmd]) -> usize {
    cmds.iter().filter(|c| matches!(c, Cmd::Send(_))).count()
}

/// The request's bytes, as the frontend writes them to the core; admitted
/// by the request admission the core's mirrors.
pub fn bytes(req: &Req) -> String {
    let mut s = Session::new("/nonexistent/s".into(), "/nonexistent".into(), true);
    s.id = "0123456789abcdef".into();
    let b = s.request(req);
    admit(Family::Req, None, &b).unwrap_or_else(|e| panic!("an admissible request: {e:?}"));
    String::from_utf8(b).unwrap()
}

/// Answer REQ with BODY (the records after hello) on PLATFORM.
pub fn answer_on(m: &mut Model, req: Req, body: &str, platform: &str) -> Vec<Cmd> {
    let text = format!("omb-res 1\n{}{body}", hello_line(platform));
    let doc = admit(Family::Res, Some(op_of(&req)), text.as_bytes())
        .unwrap_or_else(|e| panic!("the test's answer is admissible: {e:?}\n{text}"));
    update(m, Msg::Done(req, Outcome::Answer(doc.records)))
}

pub fn answer(m: &mut Model, req: Req, body: &str) -> Vec<Cmd> {
    answer_on(m, req, body, "macos")
}

/// A session on PLATFORM after hello and the journey snapshot BODY.
pub fn ready_on(platform: &str, body: &str) -> Model {
    let mut m = Model::default();
    let c = m.start();
    let c = answer_on(&mut m, sent(&c), DONE, platform);
    let req = sent(&c);
    assert_eq!(req, Req::Snapshot(Scope::Journey));
    let c = answer_on(&mut m, req, body, platform);
    assert_eq!(requests(&c), 0);
    m
}

/// A text value as the record format writes it.
pub fn enc(s: &str) -> String {
    omb_tui::record::encode(s.as_bytes())
}

pub fn action(
    id: &str,
    scope: &str,
    label: &str,
    gate: &str,
    handoff: bool,
    basis: &str,
) -> String {
    format!(
        "action\tid={id}\tscope={scope}\tlabel={}\tintent={}\tgate={gate}\tterminal={}\tcancel=0\tbasis={basis}\texplain={}\n",
        enc(label),
        if id == "plan.save" { "plan" } else { "act" },
        if handoff { "handoff" } else { "managed" },
        enc(&format!("The text flow's own {id}."))
    )
}

pub fn fact(key: &str, label: &str, value: &str, state: &str) -> String {
    format!(
        "fact\tscope=journey\tkey={key}\tlabel={}\tvalue={}\tstate={state}\n",
        enc(label),
        enc(value)
    )
}

const PARAMS: [&str; 11] = [
    "shared_size",
    "linux_size",
    "enc",
    "user",
    "host",
    "kmap",
    "tz",
    "loc",
    "ssh",
    "gh",
    "dev",
];

/// A macOS journey whose fresh read offers the plan's save, the Asahi launch
/// and Shared's creation, with their gate facts, the plan's eleven
/// parameters, the disk's regions, the installer's answers, a guide and the
/// token.
pub fn mac_journey() -> String {
    let mut s = format!("generation\tid={GEN}\ttotal=0\n");
    s.push_str(&fact("machine.model", "Model", "MacBookPro18,2", "info"));
    s.push_str(&fact("status.1", "Asahi install", "none", "info"));
    s.push_str(&fact(
        "gate.asahi.launch.source",
        "Installer",
        "https://alx.sh read just now, SHA-256 9e37 79b9",
        "ok",
    ));
    s.push_str(&fact(
        "gate.asahi.launch.backup",
        "Backup",
        "not confirmed: the installer asks you to confirm it",
        "warn",
    ));
    s.push_str(&fact(
        "gate.shared.create.where",
        "Where",
        "after disk0s6 (Linux), 150.0 GB free, read just now",
        "info",
    ));
    for (start, size, role) in [
        (0u64, 6_000_000_000u64, "apple"),
        (6_000_000_000, 520_000_000_000, "macos"),
        (526_000_000_000, 3_000_000_000, "stub"),
        (529_000_000_000, 250_000_000_000, "linux"),
        (779_000_000_000, 150_000_000_000, "free"),
    ] {
        s.push_str(&format!(
            "region\tstart={start}\tsize={size}\trole={role}\tlabel=\n"
        ));
    }
    s.push_str(
        "answer\tn=1\tprompt=New%20size%20for%20macOS\tvalue=532543MiB\tbytes=558411808768\n",
    );
    s.push_str("answer\tn=2\tprompt=New%20OS%20size\tvalue=244140MiB\tbytes=255999344640\n");
    s.push_str("guide\tid=boot\tstep=1\ttext=After%20the%20shutdown,%20hold%20the%20power%20button%20and%20choose%20Linux.\n");
    s.push_str(&format!("code\tkind=token\tvalue={TOKEN}\n"));
    s.push_str(&action("plan.save", "plan", "Save the plan", "", false, ""));
    s.push_str(&action(
        "asahi.launch",
        "asahi",
        "Launch the Asahi installer",
        "yes",
        true,
        BASIS,
    ));
    s.push_str(&action(
        "shared.create",
        "shared",
        "Create Shared",
        "yes",
        true,
        BASIS,
    ));
    for p in PARAMS {
        let ty = if p.ends_with("_size") { "text" } else { "id" };
        s.push_str(&format!(
            "param\taction=plan.save\tname={p}\ttype={ty}\tkind=\trequired=0\n"
        ));
    }
    s.push_str(DONE);
    s
}

/// The validation of the plan: the layout, the answers, every input as the
/// core normalised it, and its review.
pub fn plan_review() -> String {
    let mut s = String::new();
    for (start, size, role) in [
        (0u64, 6_000_000_000u64, "apple"),
        (6_000_000_000, 400_000_000_000, "macos"),
        (406_000_000_000, 3_000_000_000, "stub"),
        (409_000_000_000, 250_000_000_000, "linux"),
        (659_000_000_000, 100_000_000_000, "shared"),
        (759_000_000_000, 241_000_000_000, "free"),
    ] {
        s.push_str(&format!(
            "region\tstart={start}\tsize={size}\trole={role}\tlabel=\n"
        ));
    }
    s.push_str(
        "answer\tn=1\tprompt=New%20size%20for%20macOS\tvalue=381469MiB\tbytes=400000000000\n",
    );
    s.push_str("answer\tn=2\tprompt=New%20OS%20size\tvalue=238418MiB\tbytes=250000000000\n");
    for (n, v) in [
        ("shared_size", "100000000000"),
        ("linux_size", "250000000000"),
        ("enc", "1"),
        ("user", "alex"),
        ("host", "omarchy"),
        ("kmap", "us"),
        ("tz", "America/New_York"),
        ("loc", "en_US.UTF-8"),
        ("ssh", "0"),
        ("gh", "octocat"),
        ("dev", "1"),
    ] {
        s.push_str(&format!("normal\tname={n}\tvalue={v}\n"));
    }
    s.push_str(&format!("review\taction=plan.save\tbasis={REVIEW}\n{DONE}"));
    s
}

pub fn theme(name: &str) -> Theme {
    let (depth, unicode, console) = match name {
        "color" => (Depth::Full, true, false),
        "nocolor" => (Depth::None, true, false),
        "ascii" => (Depth::None, false, true),
        _ => unreachable!(),
    };
    Theme::new(Caps {
        depth,
        unicode,
        console,
        truecolor: false,
    })
}

pub fn render(m: &Model, t: &Theme, w: u16, h: u16) -> Buffer {
    let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
    term.draw(|f| screens::draw(f, m, t, 50)).unwrap();
    term.backend().buffer().clone()
}

pub fn text_of(b: &Buffer) -> String {
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

pub fn frame(m: &Model, w: u16, h: u16) -> String {
    text_of(&render(m, &theme("color"), w, h))
}

/// A screen at the two contract sizes, as a snapshot each, and in ASCII with
/// no colour: one-cell ASCII glyphs, no colour at all, every line inside the
/// terminal.
pub fn sizes(m: &Model, name: &str) {
    for (w, h) in [(80, 24), (60, 20)] {
        insta::assert_snapshot!(format!("{name}_{w}x{h}"), frame(m, w, h));
        let b = render(m, &theme("ascii"), w, h);
        for c in b.content() {
            assert!(c.symbol().is_ascii(), "{name} {w}x{h}: {:?}", c.symbol());
            assert_eq!((c.fg, c.bg), (Color::Reset, Color::Reset), "{name} {w}x{h}");
        }
        let f = text_of(&b);
        assert!(
            !f.contains("terminal too small"),
            "{name} holds at {w}x{h}:\n{f}"
        );
    }
}

/// Open the rail's screen S.
pub fn go(m: &mut Model, s: Screen) -> Vec<Cmd> {
    let n = omb_tui::app::NAV.iter().position(|x| *x == s).unwrap();
    let mut out = press(m, KeyCode::Left);
    for _ in 0..omb_tui::app::NAV.len() {
        out.extend(press(m, KeyCode::Up));
    }
    for _ in 0..n {
        out.extend(press(m, KeyCode::Down));
    }
    assert_eq!(requests(&out), 0, "moving in the rail is local");
    press(m, KeyCode::Enter)
}

/// Move the dashboard's focus to action ID.
fn focus(m: &mut Model, id: &str) {
    let i = m
        .snap
        .as_ref()
        .unwrap()
        .actions
        .iter()
        .position(|a| a.id == id)
        .unwrap();
    m.focus = i;
}

#[test]
fn the_generic_requests_are_data_in_the_one_schema() {
    let args = |v: &[(&str, &str)]| -> Vec<(String, Vec<u8>)> {
        v.iter()
            .map(|(n, v)| (n.to_string(), v.as_bytes().to_vec()))
            .collect()
    };
    let head = "omb-req 1\nreq\top=";
    let tail = "\tproto=1\tfrontend=0.2.0\tsession=0123456789abcdef\n";
    for (req, want) in [
        (
            Req::Snapshot(Scope::Profile),
            format!("{head}snapshot{tail}scope\tname=profile\n"),
        ),
        (
            Req::Detail(Page {
                kind: Kind::Items,
                generation: GEN.into(),
                offset: 0,
                limit: 500,
            }),
            format!(
                "{head}detail{tail}page\tscope=profile\tkind=items\tgeneration={GEN}\toffset=0\tlimit=500\n"
            ),
        ),
        (
            Req::Validate {
                action: "shared.code".into(),
                args: args(&[("code", "ombdone-1a2b3c4d-8f2a41c0e9b7-f5f0")]),
            },
            format!(
                "{head}validate{tail}select\taction=shared.code\narg\tname=code\tvalue=ombdone-1a2b3c4d-8f2a41c0e9b7-f5f0\n"
            ),
        ),
        (
            Req::Execute {
                action: "plan.save".into(),
                args: args(&[("tz", "America/New_York"), ("gh", "octocat")]),
                basis: REVIEW.into(),
                word: String::new(),
                handoff: false,
                cancel: false,
            },
            format!(
                "{head}execute{tail}exec\taction=plan.save\tbasis={REVIEW}\tconfirm=\narg\tname=tz\tvalue=America/New_York\narg\tname=gh\tvalue=octocat\n"
            ),
        ),
    ] {
        assert_eq!(bytes(&req), want.replace("0.2.0", omb_tui::core::VERSION));
    }
}

/// actions-planner: the fields are the parameters plan.save declares; only
/// what is typed is sent; the core's answer is shown as it came; Enter on that
/// review asks, and only y sends the validated size strings and other normals with the
/// review's basis.
#[test]
fn the_planner_validates_what_is_typed_and_saves_the_review() {
    let mut m = ready_on("macos", &mac_journey());
    focus(&mut m, "plan.save");
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert_eq!(m.screen, Screen::Plan);
    let names: Vec<&str> = m.plan.fields.iter().map(|f| f.name.as_str()).collect();
    assert_eq!(
        names, PARAMS,
        "the declared parameters, in the core's order"
    );
    let b = bytes(&req);
    assert!(
        b.contains("name=shared_size\tvalue=150GB") && b.contains("name=linux_size\tvalue=250GB")
    );
    answer(&mut m, req, &plan_review());
    let f = frame(&m, 120, 70);
    for want in [
        "Storage planner",
        "381469MiB",
        "America/New_York",
        "Review ready",
        "⏎ Save the plan",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    assert!(
        f.contains("macOS 400 GB") && f.contains("Shared 100 GB"),
        "the strip's legend:\n{f}"
    );
    // Enter on the review asks; any other key answers no and sends nothing.
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    assert!(m.ask.is_some());
    assert!(m.status.as_ref().unwrap().1.contains("Save this plan?"));
    assert_eq!(requests(&press(&mut m, KeyCode::Char('n'))), 0);
    assert!(m.ask.is_none());
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    let req = sent(&press(&mut m, KeyCode::Char('y')));
    let Req::Execute {
        action,
        args,
        basis,
        word,
        handoff,
        ..
    } = &req
    else {
        panic!("{req:?}")
    };
    assert_eq!(
        (action.as_str(), basis.as_str(), word.as_str(), handoff),
        ("plan.save", REVIEW, "", &false)
    );
    let names: Vec<&str> = args.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(names, PARAMS, "the eleven normalised inputs");
    assert_eq!(args[0].1, b"150GB");
    assert_eq!(args[1].1, b"250GB");
    assert_eq!(
        args[9].1, b"octocat",
        "a default the core answered is sent as it gave it"
    );
    // The core's answer, then the journey read again; the review is used.
    let c = answer(&mut m, req, DONE);
    assert_eq!(sent(&c), Req::Snapshot(Scope::Journey));
    assert!(m.plan.checked.is_none());
}

/// A field changed after the review: Enter checks it again, never saves.
#[test]
fn a_changed_field_is_checked_again_never_saved() {
    let mut m = ready_on("macos", &mac_journey());
    focus(&mut m, "plan.save");
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(&mut m, req, &plan_review());
    m.plan.field = m.plan.fields.iter().position(|f| f.name == "user").unwrap();
    typed(&mut m, "x");
    assert!(frame(&m, 120, 40).contains("the fields above changed since this answer"));
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert!(matches!(req, Req::Validate { .. }), "{req:?}");
    assert!(m.ask.is_none());
}

/// actions-gate: the Asahi handoff opens on its page, which shows the
/// core's gate facts, the installer's answers, the guide and the token; the
/// gate takes one word and no button; only the exact word sends the handoff
/// with the basis the snapshot showed.
#[test]
fn the_asahi_handoff_shows_its_page_then_its_gate() {
    let mut m = ready_on("macos", &mac_journey());
    focus(&mut m, "asahi.launch");
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    assert_eq!(m.screen, Screen::Install);
    let f = frame(&m, 120, 70);
    for want in [
        "Asahi handoff",
        "1 Check",
        "4 Token",
        "Installer",
        "https://alx.sh",
        "! Backup",
        "not confirmed",
        "532543MiB",
        "hold the power button",
        "omb2:enc=1",
        "type yes to run Launch the Asahi",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    sizes(&m, "asahi_handoff");
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    assert_eq!(m.screen, Screen::Gate);
    let f = frame(&m, 80, 24);
    assert!(
        f.contains("https://alx.sh") && f.contains("Type yes to continue"),
        "{f}"
    );
    sizes(&m, "gate_asahi");
    typed(&mut m, "Yes");
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    assert!(m.gate_note.as_ref().unwrap().contains("exact word"));
    press(&mut m, KeyCode::Backspace);
    press(&mut m, KeyCode::Backspace);
    press(&mut m, KeyCode::Backspace);
    typed(&mut m, "yes");
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert_eq!(
        req,
        Req::Execute {
            action: "asahi.launch".into(),
            args: vec![],
            basis: BASIS.into(),
            word: "yes".into(),
            handoff: true,
            cancel: false,
        }
    );
    assert_eq!(m.screen, Screen::Install, "back to the page it came from");
}

/// actions-shared-create: the region on the strip, the core's checks, then
/// the gate.
#[test]
fn shared_creation_shows_the_disk_and_its_checks() {
    let mut m = ready_on("macos", &mac_journey());
    focus(&mut m, "shared.create");
    press(&mut m, KeyCode::Enter);
    assert_eq!(m.screen, Screen::Shared);
    let f = frame(&m, 120, 70);
    for want in [
        "Shared creation",
        "macOS 520 GB",
        "free 150 GB",
        "after disk0s6",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    sizes(&m, "shared_creation");
    press(&mut m, KeyCode::Enter);
    assert_eq!(m.screen, Screen::Gate);
    assert_eq!(m.gate.as_ref().unwrap().action.id, "shared.create");
}

/// The Linux continuation: `n` runs the network handoff, which takes no
/// word; Enter opens the start's gate; Omarchy Mac's progress shows the
/// core's signals and says it runs on tty1.
#[test]
fn the_linux_continuation_and_omarchys_progress() {
    let mut body = format!("generation\tid={GEN}\ttotal=0\n");
    body.push_str(&fact("recorded.1", "Username", "alex", "info"));
    body.push_str(&fact(
        "gate.omarchy.start.source",
        "Omarchy Mac",
        "malik-na/omarchy-mac at 3f1c, read just now",
        "ok",
    ));
    body.push_str(&fact(
        "omarchy.console",
        "Console",
        "tty1 (Ctrl+Alt+F1)",
        "info",
    ));
    body.push_str(&fact("omarchy.marker", "Setup marker", "absent", "info"));
    body.push_str(&fact("omarchy.unit", "Setup unit", "activating", "warn"));
    body.push_str(&action(
        "network.connect",
        "network",
        "Connect to a network",
        "",
        true,
        BASIS,
    ));
    body.push_str(&action(
        "omarchy.start",
        "omarchy",
        "Start Omarchy Mac",
        "start",
        true,
        BASIS,
    ));
    body.push_str(DONE);
    let mut m = ready_on("linux", &body);
    go(&mut m, Screen::Install);
    let f = frame(&m, 120, 70);
    for want in [
        "Linux continuation",
        "2 Network",
        "alex",
        "n runs Connect to a network",
        "malik-na/omarchy-mac",
        "type start to run Start Omarchy Mac",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    sizes(&m, "linux_continuation");
    assert_eq!(
        requests(&press(&mut m, KeyCode::Char('n'))),
        0,
        "asked first"
    );
    let req = sent(&press(&mut m, KeyCode::Char('y')));
    assert!(
        matches!(&req, Req::Execute { action, word, handoff: true, .. } if action == "network.connect" && word.is_empty()),
        "{req:?}"
    );
    let c = answer_on(&mut m, req, DONE, "linux");
    assert_eq!(sent(&c), Req::Snapshot(Scope::Journey));
    answer_on(&mut m, Req::Snapshot(Scope::Journey), &body, "linux");
    press(&mut m, KeyCode::Enter);
    assert_eq!(m.screen, Screen::Gate);
    assert_eq!(m.gate.as_ref().unwrap().action.gate, "start");
    press(&mut m, KeyCode::Esc);
    assert_eq!(m.screen, Screen::Install);
    go(&mut m, Screen::Progress);
    let f = frame(&m, 120, 70);
    for want in [
        "Omarchy progress",
        "tty1",
        "Setup marker",
        "! Setup unit",
        "activating",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    for no in ["%", "Elapsed", "Remaining"] {
        assert!(!f.contains(no), "no {no:?} the core cannot observe:\n{f}");
    }
    sizes(&m, "omarchy_progress");
    // r reads the machine again.
    assert_eq!(
        sent(&press(&mut m, KeyCode::Char('r'))),
        Req::Snapshot(Scope::Journey)
    );
}

/// An action the core does not list is never offered: its page says so and
/// Enter sends nothing.
#[test]
fn only_listed_actions_are_offered() {
    let mut m = ready_on(
        "macos",
        &format!(
            "generation\tid={GEN}\ttotal=0\nblocker\tid=mac.1\ttext=FileVault%20is%20still%20encrypting.\tfix=\n{DONE}"
        ),
    );
    go(&mut m, Screen::Install);
    let f = frame(&m, 120, 70);
    assert!(
        f.contains("does not offer asahi.launch now")
            && f.contains("FileVault is still encrypting."),
        "{f}"
    );
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    assert_eq!(m.screen, Screen::Install);
}

/// The parameter form of another action: its declared parameter, the core's
/// review, a question (no word), then the normalised value and the basis.
#[test]
fn another_actions_parameters_are_checked_then_sent() {
    let mut body = format!("generation\tid={GEN}\ttotal=0\n");
    body.push_str(&action(
        "shared.code",
        "shared",
        "Take the Linux code",
        "",
        false,
        "",
    ));
    body.push_str("param\taction=shared.code\tname=code\ttype=code\tkind=ombdone\trequired=1\n");
    body.push_str(DONE);
    let mut m = ready_on("macos", &body);
    press(&mut m, KeyCode::Enter);
    assert_eq!(m.screen, Screen::Form);
    typed(&mut m, "OMBDONE-1A2B3C4D-8F2A41C0E9B7-F5F0");
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert!(bytes(&req).contains(
        "select\taction=shared.code\narg\tname=code\tvalue=OMBDONE-1A2B3C4D-8F2A41C0E9B7-F5F0\n"
    ));
    answer(
        &mut m,
        req,
        &format!(
            "normal\tname=code\tvalue=ombdone-1a2b3c4d-8f2a41c0e9b7-f5f0\nreview\taction=shared.code\tbasis={REVIEW}\n{DONE}"
        ),
    );
    let f = frame(&m, 80, 24);
    assert!(
        f.contains("Take the Linux code") && f.contains("ombdone-1a2b3c4d"),
        "{f}"
    );
    sizes(&m, "parameter_form");
    press(&mut m, KeyCode::Enter);
    let req = sent(&press(&mut m, KeyCode::Char('y')));
    assert_eq!(
        req,
        Req::Execute {
            action: "shared.code".into(),
            args: vec![(
                "code".into(),
                b"ombdone-1a2b3c4d-8f2a41c0e9b7-f5f0".to_vec()
            )],
            basis: REVIEW.into(),
            word: String::new(),
            handoff: false,
            cancel: false,
        }
    );
}

/// Screens 1, 2 and 12 at the contract sizes over the journey above.
#[test]
fn the_welcome_dashboard_and_planner_at_the_contract_sizes() {
    let mut m = ready_on("macos", &mac_journey());
    sizes(&m, "journey_dashboard");
    let f = frame(&m, 120, 70);
    assert!(
        !f.contains("https://alx.sh"),
        "a gate's facts are its gate's, not the dashboard's:\n{f}"
    );
    go(&mut m, Screen::Welcome);
    sizes(&m, "welcome");
    let req = sent(&go(&mut m, Screen::Plan));
    answer(&mut m, req, &plan_review());
    sizes(&m, "storage_planner");
}
