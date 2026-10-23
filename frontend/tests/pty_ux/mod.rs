//! Planner acceptance on a real PTY. Both host capability outcomes are
//! asserted; the process-table refusal never substitutes for a planner run.
use super::*;

#[test]
fn pty_opens_welcome_then_journey_at_80x24() {
    let readable = Command::new("ps")
        .args(["-p", &std::process::id().to_string(), "-o", "lstart="])
        .output()
        .is_ok_and(|o| o.status.success() && !o.stdout.is_empty());
    assert!(
        readable,
        "UNRUN: the launcher PTY requires ps to own its session"
    );
    let mac = Path::new("/usr/bin/plutil").exists();
    let mut p = Pty::start(
        "welcome",
        Opts {
            rows: 24,
            cols: 80,
            env: vec![("OMB_TEST_FOUNDATION", String::new())],
            fixture: if mac {
                "mac-m1pro-1tb-roomy"
            } else {
                "linux-omarchy-installed"
            },
            ..Opts::default()
        },
    );
    p.wait_for("Welcome to Omarchy Mac Bootstrap");
    p.idle();
    let first = p.contents();
    assert!(first.contains("▍ Welcome"), "{first}");
    assert!(first.lines().next().unwrap().contains("Welcome"), "{first}");
    p.send(b"\r");
    p.wait_for("What you can do now");
    p.wait_for(if mac {
        "Save the plan"
    } else {
        "Developer setup"
    });
    let f = p.contents();
    for want in ["Current stage", "Where it stands", "Survey", "▍ Journey"] {
        assert!(f.contains(want), "{want}: {f}");
    }
    // The rail and current stage were not hidden by following the action.
    assert!(!f.lines().nth(3).unwrap().contains('↑'), "{f}");
    if mac {
        p.send(b"\r");
        p.wait_for("Storage planner");
        p.idle();
        p.send(b"\x1b");
        p.wait_for("What you can do now");
    }
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
    assert!(p.restored());
    assert!(p.sessions().is_empty());
}

#[test]
fn pty_storage_presets_custom_200gb_review_and_save() {
    let readable = Command::new("ps")
        .args(["-p", &std::process::id().to_string(), "-o", "pid="])
        .output()
        .is_ok_and(|o| o.status.success() && !o.stdout.is_empty());
    let mac = Path::new("/usr/bin/plutil").exists();
    let mut p = Pty::start(
        "ux-planner",
        Opts {
            rows: 40,
            cols: 120,
            env: vec![("OMB_TEST_FOUNDATION", String::new())],
            fixture: if mac {
                "mac-m1pro-1tb-roomy"
            } else {
                "linux-omarchy-installed"
            },
            ..Opts::default()
        },
    );
    if !readable {
        p.wait_for("the session scratch could not be made");
        if mac {
            p.wait_for("Plan storage");
        }
        assert!(
            !p.dir.join("trace").exists(),
            "no frontend request was submitted"
        );
        eprintln!("UNRUN planner PTY path: ps is denied; verified the launcher's text fallback.");
        p.send(b"q\r");
        assert_eq!(p.wait_exit(), 0);
        return;
    }
    p.wait_for("Welcome to Omarchy Mac Bootstrap");
    p.send(b"\r");
    p.wait_for(if mac {
        "Save the plan"
    } else {
        "Developer setup"
    });
    p.idle();
    if !mac {
        // Linux has no plan.save; it must not manufacture a macOS planner.
        let trace = std::fs::read_to_string(p.dir.join("trace")).unwrap();
        assert!(!trace.contains("id: \"plan.save\""));
        p.keys("q");
        assert_eq!(p.wait_exit(), 0);
        eprintln!(
            "UNRUN macOS planner path: host lacks Apple's plutil; verified Linux does not offer plan.save."
        );
        return;
    }
    p.send(b"\r");
    p.wait_for("Storage planner");
    p.idle();
    p.send(b"\x1b[C"); // Balanced -> Linux-heavy: one request.
    p.wait_until("500GB validation", |p| {
        std::fs::read_to_string(p.dir.join("trace"))
            .unwrap()
            .lines()
            .any(|l| l.starts_with("send Validate") && l.contains("53, 48, 48, 71, 66"))
    });
    p.idle();
    let before = std::fs::read_to_string(p.dir.join("trace")).unwrap().len();
    p.send(b"\x1b[C"); // Custom.
    // Custom starts empty, and an empty size is not sent.
    p.wait_until("Custom validation", |p| {
        std::fs::read_to_string(p.dir.join("trace"))
            .unwrap()
            .get(before..)
            .is_some_and(|t| {
                t.lines()
                    .any(|l| l.starts_with("send Validate") && !l.contains("linux_size"))
            })
    });
    p.idle();
    p.wait_for("◉ Custom");
    p.keys("200");
    p.send(b"\r");
    p.wait_until("200GB validation", |p| {
        std::fs::read_to_string(p.dir.join("trace"))
            .unwrap()
            .lines()
            .any(|l| l.starts_with("send Validate") && l.contains("50, 48, 48, 71, 66"))
    });
    p.idle();
    let trace = std::fs::read_to_string(p.dir.join("trace")).unwrap();
    assert!(
        trace.contains("50, 48, 48, 71, 66"),
        "the core received 200GB: {trace}"
    );
    assert!(
        trace.contains("ty: \"answer\""),
        "core supplied installer answers"
    );
    p.wait_for("The installer asks");
    assert!(p.contents().contains("MiB"), "{}", p.contents());
    p.send(b"\r");
    p.wait_for("Save this plan?");
    p.keys("y");
    p.wait_until("the chosen sizes saved", |p| {
        let state = std::fs::read_to_string(p.dir.join("state/state.env")).unwrap_or_default();
        state.lines().any(|l| l == "cfg_linux=200") && state.lines().any(|l| l == "cfg_shared=150")
    });
    p.idle();
    let trace = std::fs::read_to_string(p.dir.join("trace")).unwrap();
    let execute = trace
        .lines()
        .position(|l| l.starts_with("send Execute") && l.contains("plan.save"))
        .expect("save submitted");
    let saved = trace
        .lines()
        .skip(execute + 1)
        .find(|l| l.starts_with("outcome "))
        .expect("save answered");
    assert!(
        saved.contains("[100, 111, 110, 101]") && saved.contains("[111, 107]"),
        "done ok: {saved}"
    );
    // A lone Esc: the next key would otherwise join it as Alt-key.
    p.send(b"\x1b");
    p.wait_for("Where it stands");
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
    assert_eq!(p.termios(), p.initial);
}
