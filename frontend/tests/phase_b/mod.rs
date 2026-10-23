//! Phase B screens and wire requests, over admitted synthetic responses.
use super::actions::{
    BASIS, DONE, GEN, REVIEW, action, answer, bytes, enc, frame, go, press, ready_on, render,
    requests, sent, text_of, theme, typed,
};
use omb_tui::app::{Cmd, Model, Msg, Outcome, Req, Screen, update};
use omb_tui::read::{Kind, Page, Scope};
use omb_tui::record::Record;
use ratatui::crossterm::event::KeyCode;
use ratatui::style::Color;

const RGEN: &str = "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd";
const DEST: &str = ".config/starship.toml";

fn row(kind: &str, key: &str, cols: &[&str]) -> String {
    let mut s = format!("row\tkind={kind}\tkey={}", enc(key));
    for c in cols {
        s.push_str(&format!("\tcol={}", enc(c)));
    }
    s.push('\n');
    s
}
fn page(kind: Kind) -> Req {
    Req::Detail(Page {
        kind,
        generation: RGEN.into(),
        offset: 0,
        limit: 500,
    })
}
fn snap() -> String {
    let mut s = format!("generation\tid={RGEN}\ttotal=0\n");
    for (key, label, value) in [
        ("restore.state", "State", "not-started"),
        ("restore.bundle", "Bundle", "20261022T120000Z from M1 Pro"),
        ("restore.counts", "Items", "4 reviewed; 2 conflicts"),
        ("restore.backups", "Backups", "0 bytes"),
        (
            "gate.restore.apply.does",
            "Does",
            "Install packages and place the reviewed files",
        ),
        (
            "gate.restore.apply.keeps",
            "Keeps",
            "Keep every conflict unless Replace was chosen",
        ),
        (
            "gate.restore.undo.does",
            "Does",
            "Restore original files where the destination has not changed",
        ),
    ] {
        s.push_str(&format!(
            "fact\tscope=restore\tkey={key}\tlabel={}\tvalue={}\tstate=info\n",
            enc(label),
            enc(value)
        ));
    }
    s.push_str(&action(
        "restore.apply",
        "restore",
        "Restore the bundle",
        "restore",
        true,
        "",
    ));
    s.push_str(&action(
        "restore.undo",
        "restore",
        "Undo restored files",
        "undo",
        false,
        BASIS,
    ));
    s.push_str("param\taction=restore.apply\tname=bundle\ttype=bytes\tkind=\trequired=0\n");
    for i in 1..=14 {
        s.push_str(&format!(
            "param\taction=restore.apply\tname=replace.{i}\ttype=bytes\tkind=\trequired=0\n"
        ));
    }
    s.push_str(DONE);
    s
}
fn body(kind: Kind) -> String {
    let rows = match kind {
        Kind::RestoreReview => vec![
            row(
                "review",
                "pkg:ripgrep",
                &["packages", "pacman", "ripgrep", "", "install", "pending"],
            ),
            row(
                "review",
                "file:starship",
                &[
                    "files",
                    "file",
                    "starship.toml",
                    DEST,
                    "conflict",
                    "pending",
                ],
            ),
            row(
                "review",
                "file:codex",
                &[
                    "files",
                    "file",
                    "Codex config",
                    ".codex/config.toml",
                    "conflict",
                    "pending",
                ],
            ),
            row(
                "review",
                "agent:claude",
                &[
                    "AI tools",
                    "agent",
                    "Claude Code",
                    "",
                    "needs-sign-in",
                    "needs-sign-in",
                ],
            ),
        ],
        Kind::Conflicts => vec![
            row(
                "conflicts",
                DEST,
                &[
                    "file:starship",
                    "starship.toml",
                    "Omarchy's default",
                    "120",
                    "140",
                ],
            ),
            row(
                "conflicts",
                ".codex/config.toml",
                &["file:codex", "Codex config", "other", "55", "90"],
            ),
        ],
        Kind::Diff => vec![
            row(
                "diff",
                &format!("{DEST}#1"),
                &[DEST, "-", "format = \"$directory\""],
            ),
            row(
                "diff",
                &format!("{DEST}#2"),
                &[DEST, "+", "format = \"$all\""],
            ),
            row("diff", &format!("{DEST}#3"), &[DEST, " ", "[directory]"]),
            row(
                "diff",
                ".codex/config.toml#1",
                &[".codex/config.toml", "+", "model = \"example\""],
            ),
        ],
        Kind::Bundles => vec![row(
            "bundles",
            "20261022T120000Z",
            &["M1 Pro", "2026-10-22", "4", "320", "ok"],
        )],
        Kind::RestoreStatus => vec![row("status", "pkg:ripgrep", &["pending", "not started"])],
        _ => panic!("{kind:?}"),
    };
    format!(
        "generation\tid={RGEN}\ttotal={}\n{}{DONE}",
        rows.len(),
        rows.concat()
    )
}
fn finish(m: &mut Model, mut cmds: Vec<Cmd>) {
    for _ in 0..12 {
        if requests(&cmds) == 0 {
            return;
        }
        let req = sent(&cmds);
        // Every new detail and snapshot is a request admitted on the wire.
        let wire = bytes(&req);
        match &req {
            Req::Snapshot(Scope::Restore) => {
                assert!(wire.contains("scope\tname=restore\n"));
                cmds = answer(m, req, &snap());
            }
            Req::Detail(p) => {
                assert!(wire.contains(&format!(
                    "page\tscope=restore\tkind={}\tgeneration={RGEN}",
                    p.kind.name()
                )));
                let b = body(p.kind);
                cmds = answer(m, req, &b);
            }
            _ => panic!("{req:?}"),
        }
    }
    panic!("a read did not settle: {cmds:?}");
}
fn on() -> Model {
    let mut m = ready_on("linux", &format!("generation\tid={GEN}\ttotal=0\n{DONE}"));
    let cmds = go(&mut m, Screen::Restore);
    finish(&mut m, cmds);
    m
}
fn conflicts(m: &mut Model) {
    let cmds = press(m, KeyCode::Char('d'));
    finish(m, cmds);
    assert_eq!(m.screen, Screen::Conflicts);
}
fn sizes(m: &Model, name: &str) {
    for (w, h) in [(80, 24), (60, 20)] {
        for profile in ["color", "ascii"] {
            let b = render(m, &theme(profile), w, h);
            let text = text_of(&b);
            insta::assert_snapshot!(format!("{name}_{profile}_{w}x{h}"), text);
            if profile == "ascii" {
                for cell in b.content() {
                    assert!(cell.symbol().is_ascii(), "{name}: {:?}", cell.symbol());
                    assert_eq!((cell.fg, cell.bg), (Color::Reset, Color::Reset));
                }
            }
        }
    }
}

#[test]
fn restore_review_is_layered_and_progress_uses_core_counts() {
    let mut m = on();
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("Restore progress") && f.contains("Review by layer"),
        "{f}"
    );
    sizes(&m, "restore_review");
    let mut seen = String::new();
    for _ in 0..40 {
        seen.push_str(&frame(&m, 120, 40));
        press(&mut m, KeyCode::Down);
    }
    assert!(seen.contains("Bundles found") && seen.contains("M1 Pro"));
    press(&mut m, KeyCode::Home);
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert!(matches!(req, Req::Validate { ref action, .. } if action == "restore.apply"));
    answer(
        &mut m,
        req,
        &format!("review\taction=restore.apply\tbasis={REVIEW}\n{DONE}"),
    );
    typed(&mut m, "restore");
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert!(matches!(req, Req::Execute { handoff: true, .. }));
    update(
        &mut m,
        Msg::Live(Record {
            ty: "progress".into(),
            fields: [
                ("action", "restore.apply"),
                ("done", "1"),
                ("total", "4"),
                ("unit", "item"),
                ("label", "pkg:ripgrep"),
            ]
            .into_iter()
            .map(|(k, v)| (k.into(), v.as_bytes().to_vec()))
            .collect(),
        }),
    );
    let f = frame(&m, 120, 40);
    assert!(f.contains("1 of 4") && f.contains("pkg:ripgrep"), "{f}");
    sizes(&m, "restore_progress");
    let c = answer(&mut m, req, DONE);
    assert_eq!(
        sent(&c),
        Req::Snapshot(Scope::Restore),
        "read the machine after a handoff"
    );
}

#[test]
fn conflict_choices_default_to_keep_and_the_gate_sends_the_reviewed_bytes() {
    let mut m = on();
    conflicts(&mut m);
    assert!(m.rest.replacements.is_empty());
    let f = frame(&m, 120, 40);
    for want in ["Keep (default)", "format =", "Omarchy's default"] {
        assert!(f.contains(want), "{want}:\n{f}");
    }
    assert!(
        !f.contains("model ="),
        "another destination's diff is not mixed in"
    );
    sizes(&m, "conflict");
    assert_eq!(requests(&press(&mut m, KeyCode::Char('R'))), 0);
    press(&mut m, KeyCode::Char('n'));
    press(&mut m, KeyCode::Char('R'));
    press(&mut m, KeyCode::Char('p'));
    press(&mut m, KeyCode::Char('K'));
    assert_eq!(m.rest.replacements, [DEST.as_bytes().to_vec()]);
    press(&mut m, KeyCode::Char('k'));
    assert!(m.rest.replacements.is_empty());
    press(&mut m, KeyCode::Char('R'));
    press(&mut m, KeyCode::Char('v'));
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("Current") && f.contains("From the bundle"),
        "{f}"
    );
    insta::assert_snapshot!("conflict_side_by_side_120x40", f);
    assert!(
        !frame(&m, 119, 40).contains("From the bundle"),
        "narrow is unified"
    );
    press(&mut m, KeyCode::Esc);
    assert_eq!(m.screen, Screen::Restore);
    let req = sent(&press(&mut m, KeyCode::Enter));
    let Req::Validate { action, args } = &req else {
        panic!("{req:?}")
    };
    assert_eq!(action, "restore.apply");
    assert_eq!(
        args,
        &vec![
            ("bundle".into(), b"20261022T120000Z".to_vec()),
            (
                "replace.1".into(),
                format!("omb-replace 1\nreplace\tdest={DEST}\n").into_bytes()
            )
        ]
    );
    assert!(bytes(&req).contains("select\taction=restore.apply\n"));
    let expected = args.clone();
    answer(
        &mut m,
        req,
        &format!("review\taction=restore.apply\tbasis={REVIEW}\n{DONE}"),
    );
    assert_eq!(m.screen, Screen::Gate);
    typed(&mut m, "Restore");
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    press(&mut m, KeyCode::Esc);
    // A fresh review, then exact word.
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(
        &mut m,
        req,
        &format!("review\taction=restore.apply\tbasis={REVIEW}\n{DONE}"),
    );
    typed(&mut m, "restore");
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert_eq!(
        req,
        Req::Execute {
            action: "restore.apply".into(),
            args: expected,
            basis: REVIEW.into(),
            word: "restore".into(),
            handoff: true,
            cancel: false
        }
    );
    assert!(bytes(&req).contains(&format!(
        "exec\taction=restore.apply\tbasis={REVIEW}\tconfirm=restore\n"
    )));
}

#[test]
fn changed_or_incomplete_conflicts_cannot_authorize_replacement() {
    let mut m = on();
    conflicts(&mut m);
    press(&mut m, KeyCode::Char('R'));
    press(&mut m, KeyCode::Esc);
    let cmds = press(&mut m, KeyCode::Char('r'));
    let req = sent(&cmds);
    let moved = snap().replace(RGEN, &"dcba".repeat(16));
    let c = answer(&mut m, req, &moved);
    assert!(m.rest.replacements.is_empty());
    assert!(m.rest.checked.is_none());
    assert_eq!(
        sent(&c),
        Req::Detail(Page {
            generation: "dcba".repeat(16),
            ..match page(Kind::RestoreReview) {
                Req::Detail(p) => p,
                _ => unreachable!(),
            }
        })
    );
    assert_eq!(
        requests(&press(&mut m, KeyCode::Enter)),
        0,
        "busy does not submit"
    );
    m.pending = None;
    assert_eq!(
        requests(&press(&mut m, KeyCode::Enter)),
        0,
        "partial review cannot validate"
    );
}

#[test]
fn refused_restore_stays_on_the_review_and_undo_requires_its_own_word() {
    let mut m = on();
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(
        &mut m,
        req,
        "invalid\tname=bundle\tcode=changed\ttext=Bundle%20changed\nresult\tstatus=refused\tcode=invalid\ttext=Review%20again\tnext=\n",
    );
    assert_eq!(m.screen, Screen::Restore);
    assert!(frame(&m, 120, 40).contains("Bundle changed"));
    press(&mut m, KeyCode::Char('n'));
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    assert_eq!(m.screen, Screen::Gate);
    typed(&mut m, "restore");
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    press(&mut m, KeyCode::Esc);
    press(&mut m, KeyCode::Enter);
    typed(&mut m, "undo");
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert!(
        matches!(&req, Req::Execute { action, word, .. } if action == "restore.undo" && word == "undo")
    );
    assert!(bytes(&req).contains("confirm=undo"));
}

fn health() -> Model {
    let mut m = ready_on("linux", &format!("generation\tid={GEN}\ttotal=0\n{DONE}"));
    let req = sent(&go(&mut m, Screen::Health));
    let snap = format!(
        "generation\tid={RGEN}\ttotal=0\n{}param\taction=agents.mcp\tname=tool\ttype=id\tkind=\trequired=1\tchoice=claude-code\tchoice=codex\tchoice=opencode\n{DONE}",
        action(
            "agents.mcp",
            "health",
            "List this tool's MCP servers (may start servers)",
            "",
            true,
            ""
        )
    );
    let snap = snap.replacen("action\tid=agents.mcp", "fact\tscope=health\tkey=doctor.pass\tlabel=Passed\tvalue=2\tstate=info\nfact\tscope=health\tkey=doctor.warn\tlabel=Warnings\tvalue=3\tstate=info\nfact\tscope=health\tkey=doctor.fail\tlabel=Failures\tvalue=0\tstate=info\naction\tid=agents.mcp", 1);
    let c = answer(&mut m, req, &snap);
    let req = sent(&c);
    let rows = [
        row("doctor", "system.disk", &["pass", "Disk space", "Enough space"]),
        row("doctor", "agents.claude-code", &["pass", "Claude Code", "installed (mise); wrapper present; ran at restore; configured; sign-in file present"]),
        row("doctor", "agents.codex", &["warn", "Codex", "installed (mise); configured; needs GITHUB_TOKEN"]),
        row("doctor", "agents.opencode", &["info", "OpenCode", "not installed"]),
        row("doctor", "restore.state", &["warn", "Restore", "partial; 1 placed; 2 kept; 1 needs sign-in"]),
        row("doctor", "6", &["warn", "SSH policy", "cannot-tell: run doctor as root"]),
    ].concat();
    answer(
        &mut m,
        req,
        &format!("generation\tid={RGEN}\ttotal=6\n{rows}{DONE}"),
    );
    m
}

#[test]
fn health_groups_observed_facts_and_mcp_is_confirmed_default_no() {
    let mut m = health();
    let f = frame(&m, 120, 40);
    for want in [
        "AI tools",
        "Claude Code",
        "sign-in file",
        "Restore",
        "SSH",
        "Passed 2; Warnings 3; Failures 0",
    ] {
        assert!(f.contains(want), "{want}:\n{f}");
    }
    sizes(&m, "health");
    let req = sent(&press(&mut m, KeyCode::Char('c')));
    assert_eq!(
        req,
        Req::Validate {
            action: "agents.mcp".into(),
            args: vec![("tool".into(), b"claude-code".to_vec())]
        }
    );
    assert!(bytes(&req).contains("arg\tname=tool\tvalue=claude-code"));
    answer(
        &mut m,
        req,
        &format!("review\taction=agents.mcp\tbasis={REVIEW}\n{DONE}"),
    );
    assert!(m.status.as_ref().unwrap().1.contains("may start servers"));
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    assert!(m.ask.is_none());
    let req = sent(&press(&mut m, KeyCode::Char('c')));
    answer(
        &mut m,
        req,
        &format!("review\taction=agents.mcp\tbasis={REVIEW}\n{DONE}"),
    );
    let req = sent(&press(&mut m, KeyCode::Char('y')));
    assert_eq!(
        req,
        Req::Execute {
            action: "agents.mcp".into(),
            args: vec![("tool".into(), b"claude-code".to_vec())],
            basis: REVIEW.into(),
            word: "".into(),
            handoff: true,
            cancel: false
        }
    );
    assert!(bytes(&req).contains("exec\taction=agents.mcp"));
    let c = answer(&mut m, req, DONE);
    assert_eq!(sent(&c), Req::Snapshot(Scope::Health));
}

#[test]
fn debug_from_an_error_is_a_scrollable_core_brief_and_returns_to_the_error() {
    let mut m = Model {
        screen: Screen::Fatal,
        fatal: "The core stopped without answering.".into(),
        ..Model::default()
    };
    let req = sent(&press(&mut m, KeyCode::Char('D')));
    assert_eq!(req, Req::Snapshot(Scope::Debug));
    assert!(bytes(&req).contains("scope\tname=debug"));
    let c = answer(
        &mut m,
        req,
        &format!("generation\tid={RGEN}\ttotal=0\n{DONE}"),
    );
    let req = sent(&c);
    assert_eq!(req, page(Kind::Brief));
    assert!(bytes(&req).contains("page\tscope=debug\tkind=brief"));
    let rows: String = (0..30)
        .map(|i| {
            row(
                "brief",
                &i.to_string(),
                &[
                    if i < 2 { "Brief" } else { "Machine facts" },
                    &format!("Core brief line {i}"),
                ],
            )
        })
        .collect();
    answer(
        &mut m,
        req,
        &format!("generation\tid={RGEN}\ttotal=30\n{rows}{DONE}"),
    );
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("./omarchy-bootstrap debug > file") && f.contains("Core brief line 0"),
        "{f}"
    );
    sizes(&m, "debug_brief");
    assert_eq!(requests(&press(&mut m, KeyCode::PageDown)), 0);
    assert!(m.page_scroll > 0);
    press(&mut m, KeyCode::End);
    assert!(frame(&m, 80, 24).contains("Core brief line 29"));
    press(&mut m, KeyCode::Esc);
    assert_eq!(m.screen, Screen::Fatal);
    assert!(m.fatal.contains("stopped without answering"));
    // A lost process cannot be bypassed with another read.
    m.lost = true;
    assert_eq!(requests(&press(&mut m, KeyCode::Char('D'))), 0);
    assert!(m.status.as_ref().unwrap().1.contains("debug > file"));
}

#[test]
fn failed_reads_are_distinct_and_do_not_retry_or_offer_actions() {
    for outcome in [
        Outcome::Unknown("closed".into()),
        Outcome::NotSent("EPIPE".into()),
    ] {
        let mut m = ready_on("linux", &format!("generation\tid={GEN}\ttotal=0\n{DONE}"));
        let req = sent(&go(&mut m, Screen::Restore));
        assert_eq!(requests(&update(&mut m, Msg::Done(req, outcome))), 0);
        assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
        let f = frame(&m, 120, 40);
        assert!(f.contains("no answer") || f.contains("not sent"), "{f}");
    }
}

#[test]
fn a_nonadvancing_whole_page_does_not_loop() {
    let mut m = ready_on("linux", &format!("generation\tid={GEN}\ttotal=0\n{DONE}"));
    let req = sent(&go(&mut m, Screen::Restore));
    let c = answer(&mut m, req, &snap());
    let req = sent(&c);
    let c = answer(
        &mut m,
        req,
        &format!("generation\tid={RGEN}\ttotal=5\n{DONE}"),
    );
    assert!(!m.whole(Kind::RestoreReview));
    assert!(m.detail(Kind::RestoreReview).unwrap().fault.is_some());
    assert!(!matches!(c.first(), Some(Cmd::Send(Req::Detail(p))) if p.kind == Kind::RestoreReview));
}

#[test]
fn health_keeps_full_row_filter_and_non_tool_refusals() {
    let mut m = health();
    press(&mut m, KeyCode::Enter);
    assert!(m.detail(Kind::Doctor).unwrap().open);
    assert!(frame(&m, 120, 40).contains("wrapper present"));
    press(&mut m, KeyCode::Esc);
    press(&mut m, KeyCode::Char('/'));
    typed(&mut m, "SSH");
    press(&mut m, KeyCode::Enter);
    assert_eq!(requests(&press(&mut m, KeyCode::Char('c'))), 0);
    assert!(m.status.as_ref().unwrap().1.contains("Select an AI tool"));
    assert!(frame(&m, 80, 24).contains("cannot-tell"));
}

#[test]
fn new_wire_requests_pass_the_bash_core_admission() {
    use std::fs;
    use std::path::Path;
    use std::process::Command;
    let dir = std::env::temp_dir().join(format!("omb-interface-b-wire-{}", std::process::id()));
    fs::create_dir(&dir).unwrap();
    let mut reqs = vec![Req::Snapshot(Scope::Restore), Req::Snapshot(Scope::Debug)];
    reqs.extend(
        [
            Kind::Bundles,
            Kind::RestoreReview,
            Kind::Conflicts,
            Kind::Diff,
            Kind::RestoreStatus,
            Kind::Brief,
        ]
        .into_iter()
        .map(page),
    );
    let args = vec![
        ("bundle".into(), b"20261022T120000Z".to_vec()),
        (
            "replace.1".into(),
            format!("omb-replace 1\nreplace\tdest={DEST}\n").into_bytes(),
        ),
    ];
    reqs.push(Req::Validate {
        action: "restore.apply".into(),
        args: args.clone(),
    });
    reqs.push(Req::Execute {
        action: "restore.apply".into(),
        args,
        basis: REVIEW.into(),
        word: "restore".into(),
        handoff: true,
        cancel: false,
    });
    reqs.push(Req::Execute {
        action: "restore.undo".into(),
        args: vec![],
        basis: BASIS.into(),
        word: "undo".into(),
        handoff: false,
        cancel: false,
    });
    let args = vec![("tool".into(), b"codex".to_vec())];
    reqs.push(Req::Validate {
        action: "agents.mcp".into(),
        args: args.clone(),
    });
    reqs.push(Req::Execute {
        action: "agents.mcp".into(),
        args,
        basis: REVIEW.into(),
        word: "".into(),
        handoff: true,
        cancel: false,
    });
    for (i, req) in reqs.iter().enumerate() {
        fs::write(dir.join(format!("{i}.req")), bytes(req)).unwrap();
    }
    let bash = std::env::var("OMB_TEST_BASH").unwrap_or_else(|_| "/bin/bash".into());
    let out = Command::new(bash)
        .arg("-c")
        .arg(
            r#"
set -e
. "$1/lib/common.sh"
. "$1/lib/state.sh"
. "$1/lib/records.sh"
OMB_TMP=$2
for f in "$2"/*.req; do
  if ! rec_admit_file req - "$f"; then
    printf '%s: %s at %s\n' "$f" "$REC_REASON" "$REC_AT" >&2
    exit 1
  fi
done
"#,
        )
        .arg("interface-b-wire")
        .arg(Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap())
        .arg(&dir)
        .output()
        .unwrap();
    fs::remove_dir_all(&dir).unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(
        out.stderr.is_empty(),
        "a clean admission has no stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn bundle_keys_and_normal_values_are_used_without_parsing_display_text() {
    for change_after_review in [false, true] {
        let mut m = on();
        // The producer already ordered and checked these candidates. The
        // frontend neither parses the human fact nor sorts folder names.
        let rows = [
            row(
                "bundles",
                "first",
                &["Mac", "time", "4", "100", "digest mismatch"],
            ),
            row("bundles", "checked key", &["Mac", "time", "4", "100", "ok"]),
        ]
        .concat();
        answer(
            &mut m,
            page(Kind::Bundles),
            &format!("generation\tid={RGEN}\ttotal=2\n{rows}{DONE}"),
        );
        assert_eq!(m.rest.bundle, b"checked key");
        let req = sent(&press(&mut m, KeyCode::Enter));
        answer(
            &mut m,
            req,
            &format!(
                "normal\tname=bundle\tvalue=canonical-key\nreview\taction=restore.apply\tbasis={REVIEW}\n{DONE}"
            ),
        );
        if change_after_review {
            m.rest.replacements.push(DEST.as_bytes().to_vec());
        }
        typed(&mut m, "restore");
        let c = press(&mut m, KeyCode::Enter);
        if change_after_review {
            assert_eq!(requests(&c), 0);
            assert!(m.status.as_ref().unwrap().1.contains("choices changed"));
        } else {
            let Req::Execute { args, .. } = sent(&c) else {
                panic!("{c:?}")
            };
            assert_eq!(args[0], ("bundle".into(), b"canonical-key".to_vec()));
        }
    }
}
