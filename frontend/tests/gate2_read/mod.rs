//! Layer H for the Gate 2 read surface (docs/TESTING.md → *Layers*): the
//! frontend's model, driven by keys, against the real Bash core in fixture
//! mode on the real descriptors — the frontend's own spawn, pipe and spool
//! reader. The core is the only judge: every answer the model holds is one
//! the core wrote, and every refusal shown is one the core made (`changed`,
//! `invalid`, `scope`, `overflow`, `unplannable`). The reads persist nothing;
//! the frontend sends no execute. Over every fixture, what the core says
//! reaches the screen. On macOS the core runs under stock `/bin/bash` 3.2.
//!
//! Every macOS fixture is read through Apple's `plutil`, which Linux lacks:
//! there the same flows run over a Linux fixture, and the plan check shows
//! the core's own refusal for that platform. Nothing is skipped.
//!
//! One test function, in a process of its own: the session's environment is
//! set for the whole process and changed only between its parts, with
//! nothing running beside it (the contract target's other tests run in
//! theirs).

use omb_tui::app::{Cmd, Model, Msg, Outcome, Req, Screen, update};
use omb_tui::core::{Running, Session, seal_inherited_descriptors};
use omb_tui::read::{Fault, Kind, Page};
use omb_tui::screens;
use omb_tui::theme::{Caps, Depth, Theme};
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn wait(r: &mut Running) -> Outcome {
    let t0 = Instant::now();
    loop {
        if let Some(o) = r.poll(&mut |_| {}, false) {
            return o;
        }
        assert!(
            t0.elapsed() < Duration::from_secs(120),
            "the core did not answer in two minutes"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Carry out CMDS as the event loop does — each request to a fresh core, its
/// outcome back into the model — until nothing more is asked. Returns every
/// request sent.
fn drive(m: &mut Model, s: &mut Session, cmds: Vec<Cmd>) -> Vec<Req> {
    let mut sent = Vec::new();
    let mut todo = cmds;
    while !todo.is_empty() {
        let mut next = Vec::new();
        for c in todo {
            match c {
                Cmd::Send(req) => {
                    sent.push(req.clone());
                    let o = wait(&mut s.start(&req).expect("start the core"));
                    next.extend(update(m, Msg::Done(req, o)));
                }
                Cmd::ReadLogs => next.extend(update(m, Msg::Logs(s.diagnostics()))),
                Cmd::Quit(..) => {}
                c => panic!("a read never asks for {c:?}"),
            }
        }
        todo = next;
    }
    sent
}

fn key(m: &mut Model, c: KeyCode) -> Vec<Cmd> {
    update(m, Msg::Key(KeyEvent::new(c, KeyModifiers::NONE)))
}

fn ctrl(m: &mut Model, c: char) -> Vec<Cmd> {
    update(
        m,
        Msg::Key(KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)),
    )
}

fn typed(m: &mut Model, text: &str) {
    for c in text.chars() {
        assert!(key(m, KeyCode::Char(c)).is_empty(), "typing is local");
    }
}

/// Open the rail's screen at N (Welcome, Journey, Machine, Status, Health,
/// Logs, Plan check).
fn go(m: &mut Model, n: usize) -> Vec<Cmd> {
    let mut c = key(m, KeyCode::Left);
    for _ in 0..8 {
        c.extend(key(m, KeyCode::Up));
    }
    for _ in 0..n {
        c.extend(key(m, KeyCode::Down));
    }
    assert!(c.is_empty(), "moving in the rail is local: {c:?}");
    key(m, KeyCode::Enter)
}

fn frame(m: &Model, w: u16, h: u16) -> String {
    let theme = Theme::new(Caps {
        depth: Depth::Full,
        unicode: true,
        console: false,
    });
    let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
    t.draw(|f| screens::draw(f, m, &theme, 50)).unwrap();
    let b = t.backend().buffer().clone();
    let mut out = String::new();
    for y in 0..h {
        for x in 0..w {
            out.push_str(b[(x, y)].symbol());
        }
        out.push('\n');
    }
    out
}

/// Every file under DIR with its size: what a read must leave as it was.
fn listing(dir: &Path) -> Vec<(PathBuf, u64)> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in rd.flatten() {
            let p = e.path();
            let md = std::fs::symlink_metadata(&p).unwrap();
            if md.is_dir() {
                stack.push(p.clone());
            }
            out.push((p, md.len()));
        }
    }
    out.sort();
    out
}

struct World {
    t: PathBuf,
    sess: PathBuf,
}

impl World {
    /// A fresh fixture copy, state folder and home for NAME, with SCOPES.
    fn session(&self, name: &str, scopes: &str) -> Session {
        let dir = self.t.join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("home")).unwrap();
        let fix = dir.join("fixture");
        assert!(
            Command::new("cp")
                .arg("-R")
                .arg(repo().join("tests/fixtures").join(name))
                .arg(&fix)
                .status()
                .unwrap()
                .success()
        );
        // SAFETY: this process runs this test alone; nothing runs beside it.
        unsafe {
            std::env::set_var("OMB_FIXTURE", &fix);
            std::env::set_var("OMB_STATE_DIR", dir.join("state"));
            std::env::set_var("HOME", dir.join("home"));
            std::env::set_var("OMB_SESSION_SCOPES", scopes);
        }
        Session::new(self.sess.clone(), repo(), true)
    }

    fn state(&self, name: &str) -> PathBuf {
        self.t.join(name).join("state")
    }
}

/// hello and the journey snapshot, as the interface starts.
fn started(s: &mut Session) -> Model {
    let mut m = Model::default();
    let c = m.start();
    drive(&mut m, s, c);
    m
}

fn page(kind: Kind, generation: &str, offset: u64) -> Req {
    Req::Detail(Page {
        kind,
        generation: generation.into(),
        offset,
        limit: 500,
    })
}

#[test]
fn the_read_surface_against_the_real_core() {
    if std::env::var_os("OMB_GATE2_READ_CHILD").is_none() {
        // In a process group of its own, as the benchmark's cores are: the
        // contract test beside it supervises its own group during its
        // executes, where a core of this test would be a process it does not
        // know (`stopped unsupervised`).
        let status = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "gate2_read::the_read_surface_against_the_real_core",
                "--nocapture",
                "--test-threads=1",
            ])
            .env("OMB_GATE2_READ_CHILD", "1")
            .process_group(0)
            .status()
            .unwrap();
        assert!(status.success(), "the read surface's own process: {status}");
        return;
    }
    seal_inherited_descriptors().unwrap();
    let t = std::env::temp_dir().join(format!("omb-gate2-contract-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&t);
    std::fs::create_dir_all(&t).unwrap();
    let sess = t.join("omb-session.gate2");
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
    // SAFETY: this process runs this test alone; nothing runs beside it.
    unsafe {
        for (k, _) in std::env::vars() {
            if k.starts_with("OMB_") || k == "NO_COLOR" {
                std::env::remove_var(k);
            }
        }
        for (k, v) in [
            ("OMB_HOME", repo().display().to_string()),
            ("OMB_SESSION_INTENT", "read".into()),
            ("OMB_DRY_RUN", "0".into()),
            ("OMB_SESSION_DIR", sess.display().to_string()),
            ("OMB_FRONTEND_DEV", "1".into()),
            ("TMPDIR", t.display().to_string()),
            ("PATH", path),
            ("LANG", "en_US.UTF-8".into()),
            ("TERM", "dumb".into()),
        ] {
            std::env::set_var(k, v);
        }
    }
    let w = World {
        t: t.clone(),
        sess: sess.clone(),
    };
    let all = "journey,health,logs,plan";
    let mac = Path::new("/usr/bin/plutil").exists();

    // --- The journey: snapshot, machine and status details, generations ----
    let name = if mac {
        "mac-m1pro-1tb-roomy"
    } else {
        "linux-omarchy-installed"
    };
    let mut s = w.session(name, all);
    let mut m = started(&mut s);
    assert_eq!(m.screen, Screen::Dashboard);
    let g = m.snap.as_ref().unwrap().generation.clone();
    assert_eq!(g.len(), 64, "the snapshot's generation");
    let before = listing(&w.state(name));
    let f = frame(&m, 120, 40);
    let snap = m.snap.clone().unwrap();
    let next: String = snap.guides[0].chars().take(40).collect();
    for want in [
        "Nothing is available now.",
        next.as_str(),
        "read-only · no system changes · fixture",
    ] {
        assert!(f.contains(want), "{want:?} on the dashboard:\n{f}");
    }
    for fact in snap.facts.iter().filter(|f| f.key.starts_with("machine.")) {
        let head: String = fact.value.chars().take(10).collect();
        assert!(f.contains(&head), "{fact:?} in the sidebar:\n{f}");
    }
    let mut sent = Vec::new();
    for (n, kind) in [(2, Kind::Machine), (3, Kind::Status)] {
        let c = go(&mut m, n);
        let reqs = drive(&mut m, &mut s, c);
        assert_eq!(
            reqs,
            vec![page(kind, &g, 0)],
            "opened from the snapshot's generation"
        );
        sent.extend(reqs);
        let d = m.detail(kind).unwrap();
        assert!(d.loaded && d.fault.is_none() && !d.changed, "{d:?}");
        assert_eq!(d.generation, g);
        assert_eq!(
            d.rows.len() as u64,
            d.total,
            "one page holds the whole projection"
        );
        let f = frame(&m, 120, 40);
        assert!(
            f.contains(&format!("rows 1–{} of {}", d.total, d.total)),
            "{f}"
        );
        for r in &d.rows {
            let label = r.col(if kind == Kind::Machine { 0 } else { 1 });
            assert!(f.contains(label), "{label:?}:\n{f}");
        }
    }
    // A generation the core does not hold: refused `changed` by the core,
    // shown as changed; the rows shown stay theirs.
    let stale = page(Kind::Status, &"a".repeat(64), 0);
    let o = wait(&mut s.start(&stale).unwrap());
    update(&mut m, Msg::Done(stale.clone(), o));
    sent.push(stale);
    let d = m.detail(Kind::Status).unwrap();
    assert!(d.changed && d.generation == g && d.loaded, "{d:?}");
    assert!(frame(&m, 120, 40).contains("changed since you looked — r"));
    // r reopens it from a fresh snapshot: the rows stay until the fresh page
    // is admitted.
    let c = key(&mut m, KeyCode::Char('r'));
    let reqs = drive(&mut m, &mut s, c);
    assert_eq!(reqs, vec![Req::Snapshot, page(Kind::Status, &g, 0)]);
    sent.extend(reqs);
    assert!(!m.detail(Kind::Status).unwrap().changed);
    // An offset past the end: refused `invalid`, its words kept.
    let past = page(Kind::Machine, &g, 99);
    let o = wait(&mut s.start(&past).unwrap());
    update(&mut m, Msg::Done(past.clone(), o));
    sent.push(past);
    match &m.detail(Kind::Machine).unwrap().fault {
        Some(Fault::Said { status, code, .. }) => {
            assert_eq!((status.as_str(), code.as_str()), ("refused", "invalid"))
        }
        f => panic!("{f:?}"),
    }

    // --- Health ------------------------------------------------------------
    let c = go(&mut m, 4);
    let reqs = drive(&mut m, &mut s, c);
    assert!(
        matches!(&reqs[..], [Req::Read(_), Req::Detail(p)] if p.kind == Kind::Doctor),
        "{reqs:?}"
    );
    sent.extend(reqs);
    let hs = m.health.snap.as_ref().unwrap();
    assert_eq!(hs.facts.len(), 3);
    let d = m.detail(Kind::Doctor).unwrap();
    assert_eq!(d.generation, hs.generation);
    assert!(d.total > 0 && d.rows.len() as u64 == d.total);
    let f = frame(&m, 120, 40);
    for fact in &hs.facts {
        assert!(
            f.contains(&format!("{} {}", fact.label, fact.value)),
            "{fact:?}:\n{f}"
        );
    }
    let first = d.rows[0].col(1).to_string();
    let f = frame(&m, 120, 40);
    assert!(f.contains(&first), "{first:?}:\n{f}");

    // --- Logs: no log yet, then a selected log, then an unrepresentable one -
    let c = key(&mut m, KeyCode::Char('L'));
    let reqs = drive(&mut m, &mut s, c);
    sent.extend(reqs);
    let f = frame(&m, 120, 40);
    assert!(f.contains("No log yet."), "{f}");
    assert_eq!(m.detail(Kind::Log).unwrap().total, 0);
    let logs = w.state(name).join("logs");
    std::fs::create_dir_all(&logs).unwrap();
    std::fs::write(
        logs.join("omarchy-bootstrap-20261004.log"),
        "2026-10-04T10:00:00Z [SURVEY] info   reading the disk\n2026-10-04T10:00:01Z [PLAN] warn   Linux below recommended\nnot a log-shaped line\n",
    )
    .unwrap();
    let c = key(&mut m, KeyCode::Char('r'));
    sent.extend(drive(&mut m, &mut s, c));
    let d = m.detail(Kind::Log).unwrap();
    assert_eq!((d.total, d.rows.len()), (3, 3), "the window, whole");
    assert_eq!(d.generation, m.logread.snap.as_ref().unwrap().generation);
    let f = frame(&m, 120, 40);
    for want in [
        "omarchy-bootstrap-20261004.log",
        "[PLAN]",
        "Linux below recommended",
        "not a log-shaped line",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    std::fs::write(
        logs.join("omarchy-bootstrap-20261005.log"),
        format!("2026-10-05T10:00:00Z [PLAN] info   {}\n", "x".repeat(5000)),
    )
    .unwrap();
    let c = key(&mut m, KeyCode::Char('r'));
    sent.extend(drive(&mut m, &mut s, c));
    let f = frame(&m, 120, 40);
    assert!(f.contains("refused · overflow"), "{f}");
    assert!(
        f.contains("The selected log window cannot be represented"),
        "{f}"
    );
    // The core supplied no data set: its refusal is shown above the rows
    // read before, which are not replaced.
    for l in std::fs::read_dir(&logs).unwrap() {
        std::fs::remove_file(l.unwrap().path()).unwrap();
    }
    std::fs::remove_dir(&logs).unwrap();

    // --- The plan check: valid, then invalid (macOS); refused (Linux) -------
    if !mac {
        go(&mut m, 6);
        typed(&mut m, "250GB");
        let c = key(&mut m, KeyCode::Enter);
        sent.extend(drive(&mut m, &mut s, c));
        let ch = m.plan.checked.clone().unwrap();
        assert_eq!(
            (ch.status.as_str(), ch.code.as_str()),
            ("refused", "unavailable"),
            "{ch:?}"
        );
        let f = frame(&m, 120, 40);
        assert!(
            f.contains("refused · unavailable")
                && f.contains("Plan validation answers only plan.save"),
            "{f}"
        );
    }
    if mac {
        let c = go(&mut m, 6);
        assert!(c.is_empty(), "opening the form reads nothing");
        typed(&mut m, "250GB");
        key(&mut m, KeyCode::Tab);
        typed(&mut m, "100GB");
        let c = key(&mut m, KeyCode::Enter);
        let reqs = drive(&mut m, &mut s, c);
        sent.extend(reqs);
        let ch = m.plan.checked.clone().unwrap();
        assert_eq!(
            (ch.status.as_str(), ch.code.as_str()),
            ("done", "ok"),
            "{ch:?}"
        );
        assert_eq!(ch.answers.len(), 2);
        assert!(ch.basis.as_ref().is_some_and(|b| b.len() == 64));
        let f = frame(&m, 120, 40);
        for (_, value, _) in &ch.answers {
            assert!(f.contains(value.as_str()), "{value}:\n{f}");
        }
        assert!(f.contains("nothing was saved"), "{f}");
        let b = ch.basis.as_ref().unwrap();
        assert!(f.contains(&b[..40]), "the basis, whole:\n{f}");
        key(&mut m, KeyCode::BackTab);
        assert!(ctrl(&mut m, 'u').is_empty(), "Ctrl-U clears the field");
        typed(&mut m, "05GB");
        let c = key(&mut m, KeyCode::Enter);
        sent.extend(drive(&mut m, &mut s, c));
        let ch = m.plan.checked.clone().unwrap();
        assert_eq!(
            (ch.status.as_str(), ch.code.as_str()),
            ("refused", "invalid"),
            "{ch:?}"
        );
        assert!(
            ch.invalid
                .iter()
                .any(|(n, c, _)| n == "linux_size" && c == "leading-zero"),
            "{ch:?}"
        );
        assert!(frame(&m, 120, 40).contains("leading-zero"));
    }

    // --- What the reads did, and did not do --------------------------------
    assert!(
        sent.iter().all(|r| !matches!(r, Req::Execute { .. })),
        "the read surface never executes"
    );
    assert_eq!(
        listing(&w.state(name)),
        before,
        "no read wrote anything under the state folder"
    );
    assert!(
        listing(&t.join(name).join("home")).is_empty(),
        "nor in the home folder"
    );

    // --- An unplannable machine; a blocked one (macOS fixtures) ------------
    if mac {
        let mut s = w.session("mac-asahi-installed", all);
        let mut m = started(&mut s);
        go(&mut m, 6);
        typed(&mut m, "250GB");
        let c = key(&mut m, KeyCode::Enter);
        drive(&mut m, &mut s, c);
        let ch = m.plan.checked.clone().unwrap();
        assert_eq!(
            (ch.status.as_str(), ch.code.as_str()),
            ("refused", "unplannable"),
            "{ch:?}"
        );
        assert!(ch.messages.iter().any(|(l, _)| l == "warn"), "{ch:?}");
        let f = frame(&m, 120, 40);
        assert!(f.contains("refused · unplannable"), "{f}");
        assert!(f.contains("A trustworthy plan cannot be computed"), "{f}");

        let mut s = w.session("mac-geo-disagree", all);
        let m = started(&mut s);
        let b = &m.snap.as_ref().unwrap().blockers;
        assert!(!b.is_empty());
        let f = frame(&m, 120, 40);
        assert!(f.contains("✗ blocked"), "{f}");
        assert!(f.contains("The internal disk's partition"), "{f}");
    }

    // --- A session without the scope: the core refuses, the screen says so -
    let mut s = w.session(name, "journey,plan");
    let mut m = started(&mut s);
    let c = go(&mut m, 4);
    let reqs = drive(&mut m, &mut s, c);
    assert_eq!(reqs.len(), 1, "no detail without a data set: {reqs:?}");
    let f = frame(&m, 120, 40);
    assert!(f.contains("refused · scope"), "{f}");
    assert!(
        f.contains("This session does not include the requested scope."),
        "{f}"
    );

    // --- Every fixture: what the core says reaches the screen ---------------
    let mut fixtures: Vec<String> = std::fs::read_dir(repo().join("tests/fixtures"))
        .unwrap()
        .flatten()
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| mac || n.starts_with("linux-"))
        .collect();
    fixtures.sort();
    let mut unanswered = Vec::new();
    for name in &fixtures {
        let mut s = w.session(name, all);
        let mut m = Model::default();
        let c = m.start();
        drive(&mut m, &mut s, c);
        let Some(snap) = m.snap.clone() else {
            // The core gave no answer at all: the interface says so — never a
            // negative finding — and starts nothing more by itself.
            assert_eq!(m.screen, Screen::Fatal, "{name}");
            assert!(
                m.fatal.contains("without a complete answer"),
                "{name}: {}",
                m.fatal
            );
            assert!(frame(&m, 120, 40).contains("No answer"), "{name}");
            unanswered.push(name.as_str());
            continue;
        };
        let dash = frame(&m, 250, 80);
        key(&mut m, KeyCode::Left);
        for _ in 0..8 {
            key(&mut m, KeyCode::Up);
        }
        key(&mut m, KeyCode::Enter);
        let welcome = frame(&m, 250, 80);
        for fact in &snap.facts {
            let shown = if fact.key.starts_with("machine.") {
                &welcome
            } else {
                &dash
            };
            let head: String = fact.value.chars().take(60).collect();
            assert!(shown.contains(&head), "{name}: {fact:?}");
            if fact.key.starts_with("recorded.") && fact.value.chars().count() < 60 {
                assert!(
                    dash.contains(&format!("{} · recorded", fact.value)),
                    "{name}: {fact:?}"
                );
            }
        }
        for g in &snap.guides {
            let head: String = g.chars().take(60).collect();
            assert!(dash.contains(&head), "{name}: {g}");
        }
        for (n, kind) in [(2, Kind::Machine), (3, Kind::Status)] {
            let c = go(&mut m, n);
            drive(&mut m, &mut s, c);
            let d = m.detail(kind).unwrap();
            assert!(d.loaded && d.fault.is_none(), "{name}: {d:?}");
            assert_eq!(d.generation, snap.generation, "{name}");
            assert_eq!(d.rows.len() as u64, d.total, "{name}");
            let f = frame(&m, 250, 80);
            for r in &d.rows {
                let v = r.col(if kind == Kind::Machine { 1 } else { 2 });
                let head: String = v.chars().take(40).collect();
                assert!(f.contains(&head), "{name} {kind:?}: {r:?}");
            }
        }
    }
    // An Intel Mac the core cannot describe, and the download fixtures,
    // which are not machines.
    let none: &[&str] = if mac {
        &["mac-intel", "net-current", "net-drifted", "net-efi-drift"]
    } else {
        &[]
    };
    assert_eq!(unanswered, none);
    let _ = std::fs::remove_dir_all(&t);
}
