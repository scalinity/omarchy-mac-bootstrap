//! Layer H (docs/TESTING.md → *Layers*): the Rust client against the real
//! Bash core in fixture mode, on the real descriptors — the frontend's own
//! spawn, pipe and spool reader. On macOS the core runs under stock
//! `/bin/bash` 3.2 (PATH holds no other bash); on Linux under Bash 5.
//!
//! proto-golden-hello (the request byte for byte, the answer decoded),
//! sup-fd-child from the frontend's own spawn, sup-epipe, sup-slow-frontend,
//! sup-reader-death (with the test-hooks feature), and the foundation's
//! actions end to end.
//!
//! One test function: the session's environment is set once for the whole
//! file, and nothing runs beside it.

use omb_tui::app::{Outcome, Req};
use omb_tui::core::{Session, seal_inherited_descriptors};
use omb_tui::record::{self, Op, Record};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn scratch() -> PathBuf {
    let d = std::env::temp_dir().join(format!("omb-contract-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Run a request to its end, collecting live records.
fn run(s: &mut Session, req: &Req) -> (Outcome, Vec<Record>) {
    let mut r = s.start(req).expect("start the core");
    wait(&mut r)
}

fn wait(r: &mut omb_tui::core::Running) -> (Outcome, Vec<Record>) {
    let mut live = Vec::new();
    let t0 = Instant::now();
    loop {
        if let Some(o) = r.poll(&mut |rec| live.push(rec), false) {
            return (o, live);
        }
        assert!(
            t0.elapsed() < Duration::from_secs(120),
            "the core did not answer in two minutes"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn result(o: &Outcome) -> (String, String) {
    let Outcome::Answer(recs) = o else {
        panic!("no answer: {o:?}")
    };
    let r = recs.last().unwrap();
    (
        r.text("status").unwrap().to_string(),
        r.text("code").unwrap().to_string(),
    )
}

fn basis(snapshot: &Outcome, action: &str) -> String {
    let Outcome::Answer(recs) = snapshot else {
        panic!("{snapshot:?}")
    };
    recs.iter()
        .find(|r| r.ty == "action" && r.text("id") == Some(action))
        .and_then(|r| r.text("basis"))
        .unwrap()
        .to_string()
}

fn exec(s: &mut Session, action: &str, word: &str, handoff: bool) -> Outcome {
    let (snap, _) = run(s, &Req::Snapshot);
    let b = basis(&snap, action);
    run(
        s,
        &Req::Execute {
            action: action.into(),
            basis: b,
            word: word.into(),
            handoff,
            cancel: false,
        },
    )
    .0
}

#[test]
fn the_rust_client_against_the_real_core() {
    // Nothing this test process inherited reaches the core.
    seal_inherited_descriptors();
    let t = scratch();
    let fix = t.join("fixture");
    assert!(
        Command::new("cp")
            .arg("-R")
            .arg(repo().join("tests/fixtures/mac-m1pro-1tb-roomy"))
            .arg(&fix)
            .status()
            .unwrap()
            .success()
    );
    std::fs::create_dir_all(fix.join("test-children")).unwrap();
    let sess = t.join("omb-session.contract");
    std::fs::create_dir(&sess).unwrap();
    Command::new("chmod")
        .arg("700")
        .arg(&sess)
        .status()
        .unwrap();
    let path = match std::env::var("OMB_TEST_BASH") {
        Ok(b) => format!(
            "{}:/usr/bin:/bin:/usr/sbin:/sbin",
            Path::new(&b).parent().unwrap().display()
        ),
        Err(_) => "/usr/bin:/bin:/usr/sbin:/sbin".into(),
    };
    // SAFETY: this is the only test in this binary, so no other thread reads
    // or writes the environment while it is set.
    unsafe {
        for (k, _) in std::env::vars() {
            if k.starts_with("OMB_") || k == "NO_COLOR" {
                std::env::remove_var(k);
            }
        }
        for (k, v) in [
            ("OMB_HOME", repo().display().to_string()),
            ("OMB_SESSION_INTENT", "act".into()),
            ("OMB_SESSION_SCOPES", "journey".into()),
            ("OMB_DRY_RUN", "0".into()),
            ("OMB_SESSION_DIR", sess.display().to_string()),
            ("OMB_FIXTURE", fix.display().to_string()),
            ("OMB_STATE_DIR", t.join("state").display().to_string()),
            ("OMB_FRONTEND_DEV", "1".into()),
            ("TMPDIR", t.display().to_string()),
            ("HOME", t.join("home").display().to_string()),
            ("PATH", path),
            ("LANG", "en_US.UTF-8".into()),
            ("TERM", "dumb".into()),
        ] {
            std::env::set_var(k, v);
        }
    }
    let mut s = Session::new(sess.clone(), repo(), true);

    // --- proto-golden-hello: the request byte for byte ---------------------
    s.id = "0123456789abcdef".into();
    assert_eq!(
        s.request(&Req::Hello),
        b"omb-req 1\nreq\top=hello\tproto=1\tfrontend=0.1.0\tsession=0123456789abcdef\n"
    );
    let (hello, _) = run(&mut s, &Req::Hello);
    assert_eq!(result(&hello), ("done".into(), "ok".into()));
    let Outcome::Answer(recs) = &hello else {
        unreachable!()
    };
    let h = &recs[0];
    assert_eq!(h.ty, "hello");
    let keys: Vec<&str> = h.fields.iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(
        keys,
        [
            "core", "commit", "source", "proto", "platform", "arch", "user", "ceiling", "dry_run",
            "fixture"
        ]
    );
    assert_eq!(
        (h.text("platform"), h.text("arch"), h.text("fixture")),
        (Some("macos"), Some("arm64"), Some("1"))
    );

    // --- the dashboard's snapshot ------------------------------------------
    let (snap, _) = run(&mut s, &Req::Snapshot);
    let Outcome::Answer(recs) = &snap else {
        panic!("{snap:?}")
    };
    let ids: Vec<&str> = recs
        .iter()
        .filter(|r| r.ty == "action")
        .filter_map(|r| r.text("id"))
        .collect();
    assert_eq!(ids, ["test.read", "test.mutate", "test.handoff"]);

    // --- sup-fd-child, from the frontend's own spawn: exactly 0, 1, 2 --------
    let fds = t.join("fds-mutate");
    std::fs::write(
        fix.join("test-children/mutate"),
        format!("fds={}\n", fds.display()),
    )
    .unwrap();
    let o = exec(&mut s, "test.mutate", "test", false);
    assert_eq!(result(&o), ("done".into(), "ok".into()), "{o:?}");
    assert_eq!(
        std::fs::read_to_string(&fds).unwrap().trim(),
        "0 1 2",
        "the mutating child holds only 0, 1 and 2"
    );
    std::fs::remove_file(t.join("state/test/effect-mutate")).unwrap();
    std::fs::remove_file(fix.join("test-children/mutate")).unwrap();
    let fds = t.join("fds-read");
    std::fs::write(
        fix.join("test-children/read"),
        format!("fds={}\n", fds.display()),
    )
    .unwrap();
    let o = exec(&mut s, "test.read", "", false);
    assert_eq!(result(&o), ("done".into(), "ok".into()));
    assert_eq!(
        std::fs::read_to_string(&fds).unwrap().trim(),
        "0 1 2",
        "the read child holds only 0, 1 and 2"
    );
    std::fs::remove_file(fix.join("test-children/read")).unwrap();

    // --- refusals the core decides, seen through the client -----------------
    let (snap, _) = run(&mut s, &Req::Snapshot);
    let b = basis(&snap, "test.mutate");
    let (o, _) = run(
        &mut s,
        &Req::Execute {
            action: "test.mutate".into(),
            basis: b.clone(),
            word: "tes".into(),
            handoff: false,
            cancel: false,
        },
    );
    assert_eq!(result(&o), ("refused".into(), "word".into()));
    let stale = format!("{}0", &b[..63]);
    let (o, _) = run(
        &mut s,
        &Req::Execute {
            action: "test.mutate".into(),
            basis: stale,
            word: "test".into(),
            handoff: false,
            cancel: false,
        },
    );
    assert_eq!(
        result(&o),
        ("refused".into(), "changed".into()),
        "a stale basis"
    );

    // --- sup-epipe: a 1 MiB request -----------------------------------------
    let mut body = b"omb-req 1\n".to_vec();
    body.extend(std::iter::repeat_n(b'a', 1024 * 1024));
    let mut r = s.start_raw(Op::Hello, false, &body).unwrap();
    let (o, _) = wait(&mut r);
    assert!(
        matches!(o, Outcome::NotSent(ref w) if w.contains("could not be written")),
        "EPIPE in the frontend, a refusal: {o:?}"
    );
    assert_eq!(r.child.wait().unwrap().code(), Some(2), "the core exits 2");

    // --- sup-slow-frontend: the channel held full, the core never waits ------
    std::fs::write(fix.join("test-children/core"), "progress=5000\n").unwrap();
    let (snap, _) = run(&mut s, &Req::Snapshot);
    let b = basis(&snap, "test.mutate");
    let mut r = s
        .start(&Req::Execute {
            action: "test.mutate".into(),
            basis: b,
            word: "test".into(),
            handoff: false,
            cancel: false,
        })
        .unwrap();
    let t0 = Instant::now();
    let mut live = Vec::new();
    // Hold: nothing is taken from the channel until the core has exited.
    while !r.exited() {
        assert!(r.poll(&mut |rec| live.push(rec), true).is_none());
        assert!(
            t0.elapsed() < Duration::from_secs(120),
            "the core waited on the frontend"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(live.is_empty(), "nothing was read while held");
    let (o, mut rest) = wait(&mut r);
    live.append(&mut rest);
    assert_eq!(result(&o), ("done".into(), "ok".into()));
    let progress: Vec<u64> = live
        .iter()
        .filter(|r| r.ty == "progress")
        .map(|r| r.text("done").unwrap().parse().unwrap())
        .collect();
    assert_eq!(progress.len(), 5000, "every record read afterwards");
    assert!(progress.windows(2).all(|w| w[1] == w[0] + 1), "in order");
    std::fs::remove_file(fix.join("test-children/core")).unwrap();
    std::fs::remove_file(t.join("state/test/effect-mutate")).unwrap();

    // --- the spool is exactly what was admitted --------------------------------
    let spool = std::fs::read(sess.join(format!("req-{}.events", r.n))).unwrap();
    assert!(record::admit(record::Family::Res, Some(Op::Execute), &spool).is_ok());

    // --- sup-reader-death: the reader thread dies ------------------------------
    #[cfg(feature = "test-hooks")]
    {
        // SAFETY: the only test in this binary.
        unsafe { std::env::set_var("OMB_TEST_HOOK", "reader-panic") };
        let (o, _) = run(&mut s, &Req::Hello);
        unsafe { std::env::remove_var("OMB_TEST_HOOK") };
        assert!(
            matches!(o, Outcome::Unknown(ref w) if w.contains("reader")),
            "the outcome is unknown: {o:?}"
        );
    }

    let _ = std::fs::remove_dir_all(&t);
}
