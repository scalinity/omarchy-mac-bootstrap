//! Planner acceptance on a real PTY. Both host capability outcomes are
//! asserted; the process-table refusal never substitutes for a planner run.
use super::*;

#[test]
fn pty_storage_presets_custom_200gb_and_review() {
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
    p.idle();
    p.wait_until("500GB validation", |p| {
        std::fs::read_to_string(p.dir.join("trace"))
            .unwrap()
            .contains("53, 48, 48, 71, 66")
    });
    p.send(b"\x1b[C"); // Custom.
    p.idle();
    p.keys("200");
    p.send(b"\r");
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
    p.send(b"\x1b");
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
    assert_eq!(p.termios(), p.initial);
}
