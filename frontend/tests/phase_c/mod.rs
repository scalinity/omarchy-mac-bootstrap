//! Phase C uses the shared records, admitted through the real protocol parser.
use super::actions::{
    BASIS, DONE, GEN, action, answer, bytes, enc, go, press, ready_on, render, requests, sent,
    text_of, theme, typed,
};
use omb_tui::app::{Cmd, Model, Msg, Outcome, Req, Screen, update};
use omb_tui::read::{Kind, Page, Scope};
use omb_tui::record::{Family, admit};
use ratatui::crossterm::event::KeyCode;

fn stages(current: &str) -> String {
    let mut out = format!("generation\tid={GEN}\ttotal=0\n");
    for name in omb_tui::widgets::STATIONS {
        let (state, basis, by, detail) = match name {
            "survey" => ("done", "machine", "", ""),
            "asahi" => ("done", "recorded", "macos", ""),
            "restore" => ("skipped", "machine", "", "No bundle selected"),
            "shared" if current != "done" => ("blocked", "machine", "", "Activate Shared first"),
            n if n == current => ("current", "machine", "", ""),
            "done" if current != "done" => ("todo", "machine", "", ""),
            _ => ("done", "machine", "", ""),
        };
        out.push_str(&format!(
            "stage\tname={name}\tstate={state}\tbasis={basis}\tby={by}\tat=\tdetail={}\n",
            enc(detail)
        ));
    }
    out.push_str(DONE);
    out
}

fn journey() -> Model {
    ready_on("macos", &stages("verify"))
}
fn page(kind: Kind, offset: u64) -> Req {
    Req::Detail(Page {
        kind,
        generation: GEN.into(),
        offset,
        limit: 500,
    })
}
fn row(kind: &str, key: &str, state: &str, label: &str, detail: &str) -> String {
    format!(
        "row\tkind={kind}\tkey={key}\tcol={}\tcol={}\tcol={}\n",
        enc(state),
        enc(label),
        enc(detail)
    )
}
fn qualify(state: &str) -> String {
    let status = match state {
        "passed" => "ok",
        "failed" => "fail",
        "blocked" => "warn",
        _ => "info",
    };
    let due = match state {
        "not-started" => "1",
        "waiting-for-linux" => "2",
        "waiting-for-macos" => "3",
        _ => "none",
    };
    let mut s = format!("generation\tid={GEN}\ttotal=0\n");
    for (key, label, value, state) in [
        ("state", "Qualification", state, status),
        ("due", "Due", due, "info"),
        (
            "shared",
            "Shared",
            "disk0s7 GUID 8F2A41C0 on this Mac",
            "ok",
        ),
    ] {
        s.push_str(&format!(
            "fact\tscope=qualify\tkey=qualify.{key}\tlabel={label}\tvalue={}\tstate={state}\n",
            enc(value)
        ));
    }
    if state == "blocked" {
        s.push_str("blocker\tid=qualify.blocked\ttext=Shared%20identity%20unavailable\tfix=Activate%20Shared\n");
    }
    if matches!(state, "not-started" | "waiting-for-macos") {
        s.push_str(&action(
            "qualify.run",
            "qualify",
            &format!("Run step {due}"),
            "test",
            true,
            BASIS,
        ));
    }
    s.push_str(DONE);
    s
}
fn steps(state: &str) -> String {
    let a = if state == "not-started" {
        "todo"
    } else {
        "done"
    };
    let b = if matches!(state, "not-started" | "waiting-for-linux") {
        "todo"
    } else {
        "done"
    };
    let c = match state {
        "passed" => "done",
        "failed" => "failed",
        "blocked" => "blocked",
        _ => "todo",
    };
    format!(
        "generation\tid={GEN}\ttotal=3\n{}{}{}{DONE}",
        row(
            "step",
            "1",
            a,
            "macOS writes",
            "SHA-256 5f2ec1a05f2e; file written"
        ),
        row(
            "step",
            "2",
            b,
            "Linux checks and writes",
            "SHA-256 8acb8acb8acb; digest matches"
        ),
        row(
            "step",
            "3",
            c,
            "macOS checks",
            "Read Linux's file and names"
        )
    )
}
pub(super) fn on_qualify(state: &str) -> Model {
    let mut m = journey();
    let c = go(&mut m, Screen::Qualification);
    assert_eq!(sent(&c), Req::Snapshot(Scope::Qualify));
    assert!(bytes(&sent(&c)).contains("scope\tname=qualify"));
    let c = answer(&mut m, sent(&c), &qualify(state));
    assert_eq!(sent(&c), page(Kind::Step, 0));
    assert!(bytes(&sent(&c)).contains("page\tscope=qualify\tkind=step"));
    let c = answer(&mut m, sent(&c), &steps(state));
    assert_eq!(requests(&c), 0);
    m
}
fn report(statuses: &[&str]) -> String {
    let keys = [
        "mac",
        "disk",
        "shared",
        "linux",
        "qualification",
        "restore",
        "doctor",
        "recovery",
    ];
    let rows = keys
        .iter()
        .zip(statuses)
        .map(|(k, s)| row("report", k, s, k, "Observed by the core"))
        .collect::<String>();
    format!(
        "generation\tid={GEN}\ttotal={}\n{rows}{DONE}",
        statuses.len()
    )
}
pub(super) fn on_completion(statuses: &[&str]) -> Model {
    let mut m = ready_on(
        "macos",
        &stages("done").replace("name=done\tstate=current", "name=done\tstate=done"),
    );
    let c = go(&mut m, Screen::Completion);
    assert_eq!(sent(&c), Req::Snapshot(Scope::Health));
    let c = answer(
        &mut m,
        sent(&c),
        &format!("generation\tid={GEN}\ttotal=0\n{DONE}"),
    );
    assert_eq!(sent(&c), page(Kind::Report, 0));
    assert!(bytes(&sent(&c)).contains("page\tscope=health\tkind=report"));
    let c = answer(&mut m, sent(&c), &report(statuses));
    assert_eq!(requests(&c), 0);
    m
}
fn frames(m: &Model, name: &str) {
    for (w, h) in [(80, 24), (60, 20)] {
        for profile in ["color", "ascii"] {
            let b = render(m, &theme(profile), w, h);
            if profile == "ascii" {
                assert!(b.content().iter().all(|c| c.symbol().is_ascii()));
            }
            insta::assert_snapshot!(format!("{name}_{profile}_{w}x{h}"), text_of(&b));
        }
    }
}

#[test]
fn rail_preserves_states_provenance_reasons_and_old_core_later() {
    let m = journey();
    let s = m.snap.as_ref().unwrap();
    assert_eq!(s.stages.len(), 10);
    assert_eq!(
        s.stages[4].description(),
        "Install Asahi: done - recorded by macOS"
    );
    assert_eq!(
        s.stages[6].description(),
        "Shared storage: blocked - Activate Shared first"
    );
    frames(&m, "rail");
    let old = ready_on("macos", &format!("generation\tid={GEN}\ttotal=0\n{DONE}"));
    let text = text_of(&render(&old, &theme("color"), 80, 24));
    assert!(text.contains("every station is later"));
}

#[test]
fn linux_remote_choices_keep_their_todo_reason() {
    let body = stages("omarchy")
        .replace(
            "name=profile\tstate=done\tbasis=machine\tby=\tat=\tdetail=",
            "name=profile\tstate=todo\tbasis=machine\tby=\tat=\tdetail=chosen%20on%20macOS",
        )
        .replace(
            "name=resolve\tstate=done\tbasis=machine\tby=\tat=\tdetail=",
            "name=resolve\tstate=todo\tbasis=machine\tby=\tat=\tdetail=chosen%20on%20macOS",
        );
    let m = ready_on("linux", &body);
    let snap = m.snap.as_ref().expect("remote choices are valid stages");
    for name in ["profile", "resolve"] {
        let stage = snap.stages.iter().find(|s| s.name == name).unwrap();
        assert_eq!(stage.state, "todo");
        assert_eq!(stage.detail, "chosen on macOS");
    }
}

#[test]
fn invalid_stage_snapshots_are_never_partly_adopted() {
    let valid = stages("verify");
    let lines: Vec<_> = valid.lines().collect();
    let missing = format!(
        "{}\n",
        lines
            .iter()
            .filter(|s| !s.starts_with("stage\tname=survey\t"))
            .copied()
            .collect::<Vec<_>>()
            .join("\n")
    );
    let reversed = valid
        .replace("name=survey", "name=TEMP")
        .replace("name=profile", "name=survey")
        .replace("name=TEMP", "name=profile");
    let two_current = valid.replace("name=survey\tstate=done", "name=survey\tstate=current");
    let by_machine = valid.replacen("basis=machine\tby=", "basis=machine\tby=linux", 1);
    let missing_by = valid.replace("basis=recorded\tby=macos", "basis=recorded\tby=");
    let detail = valid.replace("Activate%20Shared%20first", "");
    let extra = valid.replace(
        DONE,
        &format!("stage\tname=done\tstate=todo\tbasis=machine\tby=\tat=\tdetail=\n{DONE}"),
    );
    for bad in [
        missing,
        reversed,
        two_current,
        by_machine,
        missing_by,
        detail,
        extra,
    ] {
        // Duplicate names may be rejected by wire admission before the model.
        let wire = format!("omb-res 1\n{}{bad}", super::actions::hello_line("macos"));
        if let Ok(doc) = admit(
            Family::Res,
            Some(omb_tui::record::Op::Snapshot),
            wire.as_bytes(),
        ) {
            let mut m = Model::default();
            m.start();
            let c = update(
                &mut m,
                Msg::Done(Req::Snapshot(Scope::Journey), Outcome::Answer(doc.records)),
            );
            assert!(m.snap.is_none());
            assert_eq!(m.screen, Screen::Fatal);
            assert!(m.fatal.contains("cannot be represented"));
            assert_eq!(requests(&c), 0);
            let mut m = journey();
            let old = m.snap.clone();
            let c = press(&mut m, KeyCode::Char('r'));
            let c = answer(&mut m, sent(&c), &bad);
            assert_eq!(m.snap, old);
            assert_eq!(requests(&c), 0);
        }
    }
}

#[test]
fn verify_station_opens_qualification_and_done_opens_completion() {
    let mut m = journey();
    press(&mut m, KeyCode::Char(']')); // from current verify to done
    assert_eq!(m.station, Some(9));
    press(&mut m, KeyCode::Char('['));
    let c = press(&mut m, KeyCode::Enter);
    assert_eq!(m.screen, Screen::Qualification);
    assert_eq!(sent(&c), Req::Snapshot(Scope::Qualify));
    let mut m = journey();
    press(&mut m, KeyCode::Char(']'));
    let c = press(&mut m, KeyCode::Enter);
    assert_eq!(m.screen, Screen::Completion);
    assert_eq!(sent(&c), Req::Snapshot(Scope::Health));
}

#[test]
fn qualification_states_and_ascii_frames() {
    for state in [
        "not-started",
        "waiting-for-linux",
        "waiting-for-macos",
        "passed",
        "failed",
        "blocked",
    ] {
        let m = on_qualify(state);
        assert!(m.whole(Kind::Step));
        frames(&m, &format!("qualification_{state}"));
    }
}

#[test]
fn qualification_refresh_is_one_read_and_test_gate_hands_off() {
    let mut m = on_qualify("waiting-for-macos");
    let c = press(&mut m, KeyCode::Enter);
    assert_eq!(sent(&c), Req::Snapshot(Scope::Qualify));
    let c = answer(&mut m, sent(&c), &qualify("waiting-for-macos"));
    assert_eq!(requests(&c), 0, "unchanged rows remain current");
    assert!(typed(&mut m, "t").is_empty());
    assert_eq!(m.screen, Screen::Gate);
    assert!(press(&mut m, KeyCode::Enter).is_empty());
    typed(&mut m, "tes");
    assert!(press(&mut m, KeyCode::Enter).is_empty());
    typed(&mut m, "t");
    let c = press(&mut m, KeyCode::Enter);
    let req = sent(&c);
    assert_eq!(
        req,
        Req::Execute {
            action: "qualify.run".into(),
            args: Vec::new(),
            basis: BASIS.into(),
            word: "test".into(),
            handoff: true,
            cancel: false
        }
    );
    assert!(bytes(&req).contains("confirm=test"));
    let c = answer(&mut m, req, DONE);
    assert_eq!(sent(&c), Req::Snapshot(Scope::Qualify));
    let c = answer(&mut m, sent(&c), &qualify("passed"));
    assert_eq!(sent(&c), Req::Snapshot(Scope::Journey));
    let c = answer(&mut m, sent(&c), &stages("done"));
    assert_eq!(requests(&c), 0);
    for state in ["waiting-for-linux", "passed", "failed", "blocked"] {
        let mut m = on_qualify(state);
        assert!(press(&mut m, KeyCode::Char('t')).is_empty());
        assert_eq!(m.screen, Screen::Qualification);
    }
}

#[test]
fn completion_verdict_counts_and_receipt_use_only_core_records() {
    for (name, statuses, counts) in [
        (
            "pass",
            [
                "pass",
                "pass",
                "pass",
                "pass",
                "pass",
                "pass",
                "pass",
                "not-checked",
            ],
            "7 pass - 0 warn - 0 fail - 1 not-checked",
        ),
        (
            "warn",
            [
                "pass",
                "warn",
                "pass",
                "pass",
                "pass",
                "pass",
                "pass",
                "not-checked",
            ],
            "6 pass - 1 warn - 0 fail - 1 not-checked",
        ),
        (
            "fail",
            [
                "pass",
                "warn",
                "fail",
                "pass",
                "pass",
                "pass",
                "pass",
                "not-checked",
            ],
            "5 pass - 1 warn - 1 fail - 1 not-checked",
        ),
    ] {
        let mut m = on_completion(&statuses);
        frames(&m, &format!("completion_{name}_stages"));
        m.page_scroll = 13;
        let text = text_of(&render(&m, &theme("color"), 80, 24));
        assert!(text.contains(&format!("Report: {name}")), "{text}");
        // Full count line at 120 columns; narrow frames wrap it.
        let text = text_of(&render(&m, &theme("color"), 120, 40));
        assert!(
            text.contains(&counts.replace("not-checked", "not checked")),
            "{text}"
        );
        frames(&m, &format!("completion_{name}_report"));
        assert!(m.completion_receipt(&theme("color")).is_none());
        assert!(matches!(
            &press(&mut m, KeyCode::Char('q'))[..],
            [Cmd::Quit(0, _)]
        ));
        assert_eq!(
            m.completion_receipt(&theme("color")).unwrap(),
            "✓ journey complete · ./omarchy-bootstrap report"
        );
        assert_eq!(
            m.completion_receipt(&theme("ascii")).unwrap(),
            "+ journey complete - ./omarchy-bootstrap report"
        );
        m.snap.as_mut().unwrap().stages[9].state = "current".into();
        assert!(m.completion_receipt(&theme("color")).is_none());
    }
}

#[test]
fn new_reads_refuse_without_retry_and_never_invent_a_verdict() {
    for screen in [Screen::Qualification, Screen::Completion] {
        let mut m = journey();
        let c = go(&mut m, screen);
        let c = answer(
            &mut m,
            sent(&c),
            &format!(
                "generation\tid={}\ttotal=0\nresult\tstatus=refused\tcode=unavailable\ttext=Not%20available\tnext=\n",
                "0".repeat(64)
            ),
        );
        assert_eq!(requests(&c), 0);
        assert_eq!(requests(&update(&mut m, Msg::Tick)), 0);
        let text = text_of(&render(&m, &theme("color"), 80, 24));
        assert!(!text.contains("Report: pass"));
    }
}

#[test]
fn qualification_and_report_wait_for_complete_current_pages() {
    for (screen, kind, snapshot, detail) in [
        (
            Screen::Qualification,
            Kind::Step,
            qualify("waiting-for-macos"),
            steps("waiting-for-macos"),
        ),
        (
            Screen::Completion,
            Kind::Report,
            format!("generation\tid={GEN}\ttotal=0\n{DONE}"),
            report(&[
                "pass",
                "warn",
                "fail",
                "pass",
                "pass",
                "pass",
                "pass",
                "not-checked",
            ]),
        ),
    ] {
        let rows: Vec<_> = detail.lines().filter(|l| l.starts_with("row\t")).collect();
        let mut m = journey();
        m.limit = 1;
        let c = go(&mut m, screen);
        let mut c = answer(&mut m, sent(&c), &snapshot);
        for (i, row) in rows.iter().enumerate() {
            let req = sent(&c);
            assert!(
                matches!(&req,Req::Detail(p) if p.kind==kind && p.offset==i as u64 && p.limit==1)
            );
            c = answer(
                &mut m,
                req,
                &format!("generation\tid={GEN}\ttotal={}\n{row}\n{DONE}", rows.len()),
            );
            if i + 1 < rows.len() {
                assert!(!m.whole(kind));
                let text = text_of(&render(&m, &theme("color"), 80, 24));
                assert!(!text.contains("Report: "));
                assert_eq!(requests(&press(&mut m, KeyCode::Char('t'))), 0);
                assert_ne!(m.screen, Screen::Gate);
            }
        }
        assert!(m.whole(kind));
        assert_eq!(requests(&c), 0);
        // Refresh learns the new generation. A detail of the old generation
        // cannot produce a current verdict or enable a qualification action.
        let c = press(&mut m, KeyCode::Char('r'));
        let c = if screen == Screen::Completion {
            let c = answer(&mut m, sent(&c), &stages("verify"));
            assert_eq!(sent(&c), Req::Snapshot(Scope::Health));
            c
        } else {
            c
        };
        let new_gen = "b".repeat(64);
        let c = answer(&mut m, sent(&c), &snapshot.replace(GEN, &new_gen));
        assert!(matches!(&sent(&c),Req::Detail(p) if p.generation==new_gen));
        let req = sent(&c);
        let c = update(
            &mut m,
            Msg::Done(req, Outcome::Unknown("spool unreadable".into())),
        );
        assert_eq!(requests(&c), 0);
        assert_eq!(requests(&update(&mut m, Msg::Tick)), 0);
        assert!(!m.whole(kind));
        let text = text_of(&render(&m, &theme("color"), 80, 24));
        assert!(!text.contains("Report: pass") && !text.contains("Report: fail"));
        assert_eq!(requests(&press(&mut m, KeyCode::Char('t'))), 0);
        assert_ne!(m.screen, Screen::Gate);
    }
}

#[test]
fn station_focus_keeps_the_rail_visible_above_offered_actions() {
    let mut body = stages("verify");
    body = body.replace(
        DONE,
        &format!(
            "{}{DONE}",
            action("test.read", "journey", "Read fixture", "", false, BASIS)
        ),
    );
    let mut m = ready_on("macos", &body);
    press(&mut m, KeyCode::Char('['));
    let text = text_of(&render(&m, &theme("color"), 80, 24));
    assert!(
        text.contains("Restore: skipped - No bundle selected"),
        "{text}"
    );
    assert!(text.contains("recorded by macOS"));
    assert!(text.contains("●─────●"));
}
