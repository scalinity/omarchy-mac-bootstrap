//! proto-diff-*, proto-diff-chunks, proto-invalid-schemas, proto-code-kind,
//! proto-op-records and the golden examples' admission (docs/TESTING.md):
//! the Rust admission and the Bash admission (`lib/records.sh`) judge the
//! same corpus (`tests/proto/corpus.sh`) with the same reason code and line,
//! and the Rust tables are the Bash tables.
//!
//! The Bash under test is `OMB_TEST_BASH`, else `/bin/bash` on macOS (stock
//! 3.2) and `bash` elsewhere.

use omb_tui::record::{self, Family, Op};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn bash() -> String {
    if let Ok(b) = std::env::var("OMB_TEST_BASH") {
        return b;
    }
    if cfg!(target_os = "macos") {
        "/bin/bash".into()
    } else {
        "bash".into()
    }
}

fn scratch(name: &str) -> PathBuf {
    // Tests run on parallel threads of one process: one folder per call.
    static N: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("omb-proto-{name}-{}-{n}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

struct Case {
    name: String,
    family: Family,
    op: Option<Op>,
    want: String,
    doc: Vec<u8>,
}

fn corpus() -> Vec<Case> {
    corpus_at(&repo())
}

fn corpus_at(root: &Path) -> Vec<Case> {
    let dir = scratch("corpus");
    let st = Command::new(bash())
        .arg(root.join("tests/proto/corpus.sh"))
        .arg(&dir)
        .status()
        .expect("run the corpus generator");
    assert!(st.success(), "the corpus generator failed");
    let list = fs::read_to_string(dir.join("cases")).unwrap();
    let cases: Vec<Case> = list
        .lines()
        .map(|l| {
            let f: Vec<&str> = l.split(' ').collect();
            Case {
                name: f[0].to_string(),
                family: Family::parse(f[1]).unwrap(),
                op: Op::parse(f[2]),
                want: f[3].to_string(),
                doc: fs::read(dir.join(format!("{}.doc", f[0]))).unwrap(),
            }
        })
        .collect();
    assert!(
        cases.len() > 100,
        "the corpus has only {} cases",
        cases.len()
    );
    cases
}

fn verdict(r: &Result<record::Document, record::Refusal>) -> (String, usize) {
    match r {
        Ok(_) => ("ok".into(), 0),
        Err(f) => (f.reason.code().into(), f.at),
    }
}

/// The Bash admission of every case, as "NAME REASON AT" lines.
fn bash_verdicts(cases: &[Case], dir: &Path) -> Vec<(String, usize)> {
    bash_verdicts_at(cases, dir, &repo())
}

fn bash_verdicts_at(cases: &[Case], dir: &Path, root: &Path) -> Vec<(String, usize)> {
    for c in cases {
        fs::write(dir.join(format!("{}.doc", c.name)), &c.doc).unwrap();
    }
    let list: String = cases
        .iter()
        .map(|c| {
            format!(
                "{} {} {}\n",
                c.name,
                c.family.name(),
                c.op.map(|o| o.name()).unwrap_or("-")
            )
        })
        .collect();
    fs::write(dir.join("list"), list).unwrap();
    let script = r#"
      R=$1 D=$2
      . "$R/lib/common.sh"; . "$R/lib/state.sh"; . "$R/lib/records.sh"
      while read -r name family op; do
        rec_admit_file "$family" "$op" "$D/$name.doc"
        printf '%s %s %s\n' "$name" "${REC_REASON:-ok}" "$REC_AT"
      done <"$D/list"
      omb_cleanup
    "#;
    let out = Command::new(bash())
        .arg("-c")
        .arg(script)
        .arg("bash")
        .arg(root)
        .arg(dir)
        .env("TMPDIR", dir)
        .output()
        .expect("run the Bash admission");
    assert!(
        out.status.success(),
        "the Bash admission failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8(out.stdout).unwrap();
    text.lines()
        .map(|l| {
            let f: Vec<&str> = l.split(' ').collect();
            (f[1].to_string(), f[2].parse().unwrap())
        })
        .collect()
}

// Execute the historical implementation itself in an isolated, dependency-free
// test crate. Only the temporary harness is generated; record.rs is untouched.
fn frozen_verdicts(root: &Path, source: &Path, cases: &[Case]) -> Vec<(String, usize)> {
    fs::create_dir_all(root.join("src")).unwrap();
    fs::create_dir_all(root.join("tests")).unwrap();
    fs::write(root.join("Cargo.toml"), "[package]\nname = \"omb-cp1-frozen\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n").unwrap();
    fs::write(
        root.join("src/lib.rs"),
        format!("#[path = {source:?}]\npub mod record;\n"),
    )
    .unwrap();
    let mut list = String::new();
    for (i, c) in cases.iter().enumerate() {
        fs::write(root.join(format!("{i}.doc")), &c.doc).unwrap();
        list.push_str(&format!(
            "{i} {} {}\n",
            c.family.name(),
            c.op.map(|o| o.name()).unwrap_or("-")
        ));
    }
    fs::write(root.join("cases"), list).unwrap();
    fs::write(
        root.join("tests/admission.rs"),
        r#"
use omb_cp1_frozen::record::{self, Family, Op};
#[test]
fn actual_frozen_admission() {
    let root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let mut output = String::new();
    for line in std::fs::read_to_string(root.join("cases")).unwrap().lines() {
        let fields: Vec<_> = line.split(' ').collect();
        let bytes = std::fs::read(root.join(format!("{}.doc", fields[0]))).unwrap();
        let v = record::admit(Family::parse(fields[1]).unwrap(), Op::parse(fields[2]), &bytes);
        let (reason, at) = match v { Ok(_) => ("ok", 0), Err(r) => (r.reason.code(), r.at) };
        output.push_str(&format!("{reason} {at}\n"));
    }
    std::fs::write(root.join("verdicts"), output).unwrap();
}
"#,
    )
    .unwrap();
    let out = Command::new(env!("CARGO"))
        .current_dir(repo().join("frontend"))
        .args(["test", "--offline", "--manifest-path"])
        .arg(root.join("Cargo.toml"))
        .args(["--test", "admission"])
        .env("CARGO_TARGET_DIR", root.join("target"))
        .output()
        .expect("execute the actual frozen parser test");
    assert!(
        out.status.success(),
        "frozen test did not execute successfully: {}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(String::from_utf8_lossy(&out.stdout).contains("1 passed; 0 failed"));
    fs::read_to_string(root.join("verdicts"))
        .unwrap()
        .lines()
        .map(|l| {
            let (reason, at) = l.split_once(' ').unwrap();
            (reason.to_string(), at.parse().unwrap())
        })
        .collect()
}

fn extract(commit: &str, dir: &Path, files: &[&str]) {
    fs::create_dir_all(dir).unwrap();
    let archive = dir.join("source.tar");
    assert!(
        Command::new("git")
            .current_dir(repo())
            .args(["archive", "--format=tar", "-o"])
            .arg(&archive)
            .arg(commit)
            .args(files)
            .status()
            .unwrap()
            .success()
    );
    assert!(
        Command::new("tar")
            .args(["-xf"])
            .arg(&archive)
            .arg("-C")
            .arg(dir)
            .status()
            .unwrap()
            .success()
    );
    fs::remove_file(archive).unwrap();
}

#[test]
fn cp1_compatibility_against_actual_frozen_admission() {
    const C: &str = "deaa62c62348ecd4274b74b6b3a00f506c9f243d";
    const S: &str = "54c3770f99c2affdf63ceaf2d46990cb3d9fd94b";
    let dir = scratch("cp1");
    let old = dir.join("closeout");
    let released = dir.join("released");
    extract(
        C,
        &old,
        &[
            "lib/common.sh",
            "lib/state.sh",
            "lib/records.sh",
            "tests/proto/corpus.sh",
            "frontend/src/record.rs",
        ],
    );
    extract(S, &released, &["frontend/src/record.rs"]);
    let cases = corpus();
    let old_cases = corpus_at(&old);
    assert_eq!(cases.len(), old_cases.len() + 50);
    for c in &old_cases {
        let current = cases.iter().find(|n| n.name == c.name).unwrap();
        assert_eq!(
            (&current.doc, current.family, current.op, &current.want),
            (&c.doc, c.family, c.op, &c.want),
            "old corpus changed: {}",
            c.name
        );
    }
    let current_dir = dir.join("bash-current");
    let old_dir = dir.join("bash-closeout");
    fs::create_dir_all(&current_dir).unwrap();
    fs::create_dir_all(&old_dir).unwrap();
    let current_bash = bash_verdicts_at(&cases, &current_dir, &repo());
    let old_bash = bash_verdicts_at(&cases, &old_dir, &old);
    let old_rust = frozen_verdicts(
        &dir.join("c-parser"),
        &old.join("frontend/src/record.rs"),
        &cases,
    );
    let released_rust = frozen_verdicts(
        &dir.join("s-parser"),
        &released.join("frontend/src/record.rs"),
        &cases,
    );
    assert_eq!(current_bash.len(), cases.len());
    assert_eq!(old_bash.len(), cases.len());
    assert_eq!(old_rust.len(), cases.len());
    assert_eq!(released_rust.len(), cases.len());
    for (i, c) in cases.iter().enumerate() {
        let current_rust = verdict(&record::admit(c.family, c.op, &c.doc));
        assert_eq!(
            current_rust, current_bash[i],
            "current agreement: {}",
            c.name
        );
        assert_eq!(current_rust.0, c.want, "current verdict: {}", c.name);
        assert_eq!(old_bash[i], old_rust[i], "C agreement: {}", c.name);
        assert_eq!(
            old_rust[i], released_rust[i],
            "released actual parser: {}",
            c.name
        );
        if c.name.starts_with("cp1-scope-health.") || c.name.starts_with("cp1-scope-logs.") {
            assert_eq!(old_bash[i].0, "type", "old parser must reject {}", c.name);
            assert_eq!(current_rust.0, "ok");
        } else {
            assert_eq!(
                old_bash[i], current_bash[i],
                "old language preserved: {}",
                c.name
            );
        }
    }
    eprintln!(
        "CP1: {} historical corpus documents byte/verdict/reason/line preserved; 50 scope cases executed by C Bash, CP1 Bash, C Rust, CP1 Rust and actual released S Rust",
        old_cases.len()
    );
    let responses = dir.join("responses");
    fs::create_dir_all(&responses).unwrap();
    let out = Command::new(bash())
        .arg(repo().join("tests/test-cp1.sh"))
        .arg(&responses)
        .env("OMB_TEST_BASH", bash())
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "CP1 runtime/preservation suite: {}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    eprintln!("{}", String::from_utf8_lossy(&out.stdout));
    let response_cases: Vec<Case> = fs::read_to_string(responses.join("cases"))
        .unwrap()
        .lines()
        .map(|l| {
            let (name, op) = l.split_once(' ').unwrap();
            Case {
                name: name.into(),
                family: Family::Res,
                op: Op::parse(op),
                want: "ok".into(),
                doc: fs::read(responses.join(format!("{name}.doc"))).unwrap(),
            }
        })
        .collect();
    assert!(response_cases.len() >= 5);
    let released_responses = frozen_verdicts(
        &dir.join("s-responses"),
        &released.join("frontend/src/record.rs"),
        &response_cases,
    );
    for (c, v) in response_cases.iter().zip(released_responses) {
        assert_eq!(
            v,
            ("ok".into(), 0),
            "released parser must admit actual CP1 response: {}",
            c.name
        );
    }
    eprintln!(
        "CP1: actual released parser admitted {} current-core old-language responses",
        response_cases.len()
    );
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn rust_and_bash_agree_on_the_corpus() {
    let cases = corpus();
    let dir = scratch("bash");
    let bash = bash_verdicts(&cases, &dir);
    assert_eq!(bash.len(), cases.len());
    let mut failures = Vec::new();
    for (c, b) in cases.iter().zip(&bash) {
        let rust = verdict(&record::admit(c.family, c.op, &c.doc));
        if rust.0 != c.want {
            failures.push(format!(
                "{}: Rust says {} (line {}), expected {}",
                c.name, rust.0, rust.1, c.want
            ));
        }
        if rust != *b {
            failures.push(format!("{}: Rust {:?} but Bash {:?}", c.name, rust, b));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// proto-diff-chunks: the same verdict however the bytes arrive. Every
/// boundary for each case up to 64 KiB. For the three cases over 64 KiB
/// (up to 8 MiB + 1, where every boundary would mean admitting 8 MiB eight
/// million times), every boundary in the first and last 64 bytes and within
/// 8 bytes of each byte limit — and, for every case, one byte at a time.
#[test]
fn every_split_gives_the_same_verdict() {
    let cases = corpus();
    for c in &cases {
        let whole = verdict(&record::admit(c.family, c.op, &c.doc));
        let n = c.doc.len();
        let mut cuts: Vec<usize> = if n <= 65536 {
            (0..=n).collect()
        } else {
            let mut v: Vec<usize> = (0..64).chain(n - 64..=n).collect();
            for lim in [65536usize, 8 * 1024 * 1024] {
                v.extend(lim.saturating_sub(8)..=(lim + 8).min(n));
            }
            v
        };
        cuts.sort_unstable();
        cuts.dedup();
        for cut in cuts {
            let mut a = record::Admitter::new(c.family, c.op);
            a.push(&c.doc[..cut]);
            a.push(&c.doc[cut..]);
            assert_eq!(verdict(&a.finish()), whole, "{} split at {cut}", c.name);
        }
        let mut a = record::Admitter::new(c.family, c.op);
        for b in c.doc.chunks(1) {
            a.push(b);
        }
        assert_eq!(verdict(&a.finish()), whole, "{} one byte at a time", c.name);
    }
}

/// The records a streaming reader hands on are the admitted document's.
#[test]
fn provisional_records_are_the_documents() {
    for c in corpus()
        .iter()
        .filter(|c| c.want == "ok" && !c.family.sealed())
    {
        let whole = record::admit(c.family, c.op, &c.doc).unwrap();
        let mut a = record::Admitter::new(c.family, c.op);
        let mut got = Vec::new();
        for b in c.doc.chunks(7) {
            got.extend(a.push(b));
        }
        assert_eq!(got, whole.records, "{}", c.name);
    }
}

#[test]
fn escapes_decode_exactly() {
    let c = corpus()
        .into_iter()
        .find(|c| c.name == "proto-diff-escape-valid")
        .unwrap();
    let d = record::admit(c.family, c.op, &c.doc).unwrap();
    let arg = d.records.iter().find(|r| r.ty == "arg").unwrap();
    assert_eq!(arg.get("value").unwrap(), b" %\n\t");
    let c = corpus()
        .into_iter()
        .find(|c| c.name == "proto-diff-text-control.bytes")
        .unwrap();
    let d = record::admit(c.family, c.op, &c.doc).unwrap();
    let arg = d.records.iter().find(|r| r.ty == "arg").unwrap();
    assert_eq!(
        record::display(arg.get("value").unwrap(), 40),
        "\\x1b[2J",
        "bytes render escaped, never raw"
    );
    let c = corpus()
        .into_iter()
        .find(|c| c.name == "proto-diff-list")
        .unwrap();
    let d = record::admit(c.family, c.op, &c.doc).unwrap();
    let p = d.records.iter().find(|r| r.ty == "param").unwrap();
    assert_eq!(
        p.list("choice"),
        vec![&b"c1"[..], b"c2", b"c3"],
        "list order kept"
    );
}

/// The golden examples decode to what docs/PROTOCOL.md says they mean.
#[test]
fn golden_responses_decode() {
    let cases = corpus();
    let get = |n: &str| cases.iter().find(|c| c.name == n).unwrap();
    let c = get("proto-golden-snapshot.res");
    let d = record::admit(c.family, c.op, &c.doc).unwrap();
    let code = d.records.iter().find(|r| r.ty == "code").unwrap();
    assert_eq!(
        code.text("value").unwrap(),
        "omb2:enc=1,user=alex,host=m1pro,kmap=us,tz=America/New_York,loc=en_US.UTF-8,ssh=0,gh=octocat,linux=250,shared=150,dev=1,plan=1a2b3c4d,prof=3f09c2a1"
    );
    let act = d.records.iter().find(|r| r.ty == "action").unwrap();
    assert_eq!(act.text("label"), Some("Create Shared"));
    assert_eq!(act.text("gate"), Some("create"));
    assert_eq!(act.text("terminal"), Some("handoff"));
    let c = get("proto-golden-cancelled.res");
    let d = record::admit(c.family, c.op, &c.doc).unwrap();
    let r = d.records.last().unwrap();
    assert_eq!(
        (r.text("status"), r.text("text")),
        (Some("cancelled"), Some("2 of 5 items done"))
    );
    let c = get("proto-golden-hello.req");
    let d = record::admit(c.family, c.op, &c.doc).unwrap();
    assert_eq!(d.op, Some(Op::Hello));
}

/// The Rust schema tables are the Bash tables: every REC_SPEC and every
/// cardinality column in lib/records.sh, read out of the file.
#[test]
fn tables_match_lib_records_sh() {
    let src = fs::read_to_string(repo().join("lib/records.sh")).unwrap();
    let mut specs = 0;
    let mut cols = 0;
    for line in src.lines() {
        let l = line.trim();
        let Some((labels, rest)) = l.split_once(") ") else {
            continue;
        };
        let labels: Vec<&str> = labels.split(" | ").collect();
        if !labels.iter().all(|x| x.contains('.') && !x.contains(' ')) {
            continue;
        }
        for label in labels {
            let (fam, ty) = label.split_once('.').unwrap();
            let Some(family) = Family::parse(fam) else {
                continue;
            };
            if let Some(s) = rest
                .strip_prefix("REC_SPEC=\"")
                .and_then(|r| r.split_once("\" ;;"))
            {
                assert_eq!(record::spec(family, ty), Some(s.0), "REC_SPEC of {label}");
                specs += 1;
            }
            if let Some(s) = rest
                .strip_prefix("col=\"")
                .and_then(|r| r.split_once("\" ;;"))
            {
                assert_eq!(
                    record::card_column(family, ty),
                    Some(s.0),
                    "cardinality of {label}"
                );
                cols += 1;
            }
        }
    }
    assert!(
        specs >= 30 && cols >= 25,
        "read {specs} specs and {cols} columns"
    );
    assert!(src.contains(&format!("REC_SCOPES=\"{}\"", record::SCOPES)));
    assert!(src.contains(&format!("REC_STAGES=\"{}\"", record::STAGES)));
    for f in [
        Family::Req,
        Family::Res,
        Family::Lock,
        Family::Children,
        Family::Proc,
        Family::Op,
    ] {
        let order = f.order().join(" ");
        assert!(
            src.contains(&format!("REC_ORDER=\"{order}\"")),
            "order of {}",
            f.name()
        );
        assert!(
            src.contains(&format!("REC_HDR=\"{}\"", f.header())),
            "header of {}",
            f.name()
        );
    }
}

/// The current status in the protocol documents says what review settled
/// (G2-FE-004): the Validate producer accepted at `b01610e`, and the
/// frontend's Health, Logs and plan-check screens implemented in the
/// unreleased candidate, their integration not yet accepted. A paragraph or
/// table row naming the Validate producer never says it still awaits review,
/// and none says the frontend presents no validation, that its read screens
/// are unimplemented, or (as CP1 did before the producers existed) that
/// Health and Logs are refused in fixtures.
#[test]
fn the_protocol_status_names_the_accepted_work() {
    let accepted = "b01610e69a2eef6e5a52f5ede18236210699704e";
    for doc in ["docs/PROTOCOL.md", "docs/DECISIONS.md"] {
        let text = fs::read_to_string(repo().join(doc)).unwrap();
        assert!(text.contains(accepted), "{doc} names the accepted producer");
        for unit in text.split("\n\n").flat_map(|p| p.split("\n|")) {
            let u = unit.split_whitespace().collect::<Vec<_>>().join(" ");
            if u.contains("Validate producer") {
                for stale in [
                    "awaiting focused independent review",
                    "awaits focused independent review",
                    "it is not accepted",
                ] {
                    assert!(!u.contains(stale), "{doc}: {stale:?} in: {u}");
                }
            }
            for stale in [
                "The frontend presents no validation",
                "navigation and screens remain unimplemented",
                "their snapshot/detail are `refused unavailable`, in and outside fixtures",
            ] {
                assert!(!u.contains(stale), "{doc}: {stale:?} in: {u}");
            }
        }
    }
}

/// The frozen 0.1.0 client's own code, run against the answers DIA-14 saves.
/// Only this harness is generated; the extracted sources are untouched.
const DIA14_FROZEN: &str = r#"
use omb_tui::app::{self, Model, Msg, Outcome, Req, update};
use omb_tui::core::Session;
use omb_tui::record::{self, Family, Op, Record};
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

fn texts(recs: &[Record], ty: &str, keys: &[&str]) -> Vec<Vec<String>> {
    recs.iter()
        .filter(|r| r.ty == ty)
        .map(|r| keys.iter().map(|k| r.text(k).unwrap_or("").to_string()).collect())
        .collect()
}

#[test]
fn dia14_frozen_client() {
    let dir = std::path::PathBuf::from(std::env::var("DIA14_DIR").unwrap());
    let mut out = String::new();
    // Every request it can build: hello, the journey snapshot, execute.
    let s = Session::new(dir.clone(), dir.clone(), true);
    let execute = Req::Execute {
        action: "test.mutate".into(),
        basis: "0".repeat(64),
        word: "test".into(),
        handoff: false,
        cancel: false,
    };
    for req in [Req::Hello, Req::Snapshot, execute] {
        let b = String::from_utf8(s.request(&req)).unwrap();
        assert!(!b.contains("op=detail") && !b.contains("kind=operation"), "{b}");
        let op = b.lines().nth(1).unwrap().split('\t').nth(1).unwrap().to_string();
        out.push_str(&format!("request {op}\n"));
    }
    for line in std::fs::read_to_string(dir.join("cases")).unwrap().lines() {
        let (name, op) = line.split_once(' ').unwrap();
        let bytes = std::fs::read(dir.join(format!("{name}.doc"))).unwrap();
        let recs = match record::admit(Family::Res, Op::parse(op), &bytes) {
            Ok(d) => d.records,
            Err(r) => {
                out.push_str(&format!("{name} refused {}\n", r.reason.code()));
                continue;
            }
        };
        if op != "snapshot" {
            out.push_str(&format!("{name} admitted\n"));
            continue;
        }
        let snap = app::snapshot_of(&recs);
        let facts: Vec<Vec<String>> = snap
            .facts
            .iter()
            .map(|f| vec![f.key.clone(), f.label.clone(), f.value.clone(), f.state.clone()])
            .collect();
        assert_eq!(facts, texts(&recs, "fact", &["key", "label", "value", "state"]), "{name}: facts as sent");
        let blockers: Vec<Vec<String>> = snap.blockers.iter().map(|b| vec![b.text.clone(), b.fix.clone()]).collect();
        assert_eq!(blockers, texts(&recs, "blocker", &["text", "fix"]), "{name}: blockers by text and fix");
        let listed: Vec<String> = texts(&recs, "action", &["id"]).into_iter().map(|v| v[0].clone()).collect();
        // The model as its event loop drives it: hello, then this snapshot.
        let mut m = Model::default();
        m.start();
        let hello = recs.iter().find(|r| r.ty == "hello").unwrap().clone();
        let done = recs.last().unwrap().clone();
        update(&mut m, Msg::Done(Req::Hello, Outcome::Answer(vec![hello, done])));
        update(&mut m, Msg::Done(Req::Snapshot, Outcome::Answer(recs.clone())));
        let held: Vec<String> = m.snap.as_ref().unwrap().actions.iter().map(|a| a.id.clone()).collect();
        assert_eq!(held, listed, "{name}: actions only from action records");
        for _ in 0..8 {
            if let Some(a) = m.focused() {
                assert!(listed.contains(&a.id), "{name}: focus on an action the core did not list");
            }
            update(&mut m, Msg::Key(KeyEvent::new(KeyCode::Down, KeyModifiers::NONE)));
        }
        let fact = facts.iter().find(|f| f[0] == "operation").map(|f| format!("{}|{}", f[2], f[3])).unwrap_or_default();
        let ids = texts(&recs, "blocker", &["id"]).into_iter().map(|v| v[0].clone()).collect::<Vec<_>>().join(",");
        out.push_str(&format!("{name} fact={fact} blockers={ids} actions={}\n", held.join(",")));
    }
    std::fs::write(dir.join("verdicts"), out).unwrap();
}
"#;

/// DIA-14 (docs/PROTOCOL.md → *The operation-record diagnostic*,
/// *Compatibility*): the foundation snapshots and operation details the
/// current core answers with (saved by tests/test-operation.sh), run through
/// the released 0.1.0's own parser, snapshot decoder, model and request
/// builder at its tag, built from its own sources, and through this
/// candidate's. Both admit the new fact values and the blocker ids
/// `unreadable` and `undetermined` as words, keep a blocker's text and fix,
/// take actions only from `action` records, and never ask for
/// `kind=operation`; the candidate's four legacy kinds keep no operation row,
/// while its Operation kind retains the producer's ordered columns.
#[test]
fn dia14_released_and_candidate_clients_against_the_operation_vocabulary() {
    const S: &str = "54c3770f99c2affdf63ceaf2d46990cb3d9fd94b";
    let dir = scratch("dia14");
    let responses = dir.join("responses");
    fs::create_dir_all(&responses).unwrap();
    let out = Command::new(bash())
        .arg(repo().join("tests/test-operation.sh"))
        .arg(&responses)
        .env("OMB_TEST_BASH", bash())
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "the operation-record suite: {}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let cases: Vec<(String, String)> = fs::read_to_string(responses.join("cases"))
        .unwrap()
        .lines()
        .map(|l| {
            let (n, o) = l.split_once(' ').unwrap();
            (n.to_string(), o.to_string())
        })
        .collect();
    assert_eq!(
        cases.len(),
        18,
        "nine saved findings, a snapshot and a detail each"
    );

    // The candidate, 0.2.0.
    for (name, op) in &cases {
        let bytes = fs::read(responses.join(format!("{name}.doc"))).unwrap();
        let recs = record::admit(Family::Res, Op::parse(op), &bytes)
            .unwrap_or_else(|r| panic!("candidate refuses {name}: {r:?}"))
            .records;
        if op == "snapshot" {
            let snap = omb_tui::app::snapshot_of(&recs);
            let sent = |ty: &str| recs.iter().filter(|r| r.ty == ty).count();
            assert_eq!(snap.facts.len(), sent("fact"), "{name}");
            assert_eq!(snap.blockers.len(), sent("blocker"), "{name}");
            assert_eq!(snap.actions.len(), sent("action"), "{name}");
        } else {
            for kind in [
                omb_tui::read::Kind::Machine,
                omb_tui::read::Kind::Status,
                omb_tui::read::Kind::Doctor,
                omb_tui::read::Kind::Log,
            ] {
                assert!(
                    omb_tui::read::rows(&recs, kind).is_empty(),
                    "{name}: an operation row read as {}",
                    kind.name()
                );
            }
            let rows = omb_tui::read::rows(&recs, omb_tui::read::Kind::Operation);
            let sent: Vec<_> = recs.iter().filter(|r| r.ty == "row").collect();
            assert_eq!(rows.len(), sent.len(), "{name}: complete operation rows");
            for (row, original) in rows.iter().zip(sent) {
                assert_eq!(row.cols.len(), 3);
                assert_eq!(row.key, record::display(original.get("key").unwrap(), 8192));
                for (col, bytes) in row.cols.iter().zip(original.list("col")) {
                    assert_eq!(col, &record::display(bytes, 8192), "{name}: row fidelity");
                }
            }
        }
    }

    // The released client, built from its own sources at its tag.
    let released = dir.join("released");
    extract(
        S,
        &released,
        &[
            "frontend/.cargo",
            "frontend/Cargo.toml",
            "frontend/Cargo.lock",
            "frontend/src",
        ],
    );
    let crate_dir = released.join("frontend");
    fs::create_dir_all(crate_dir.join("tests")).unwrap();
    fs::write(crate_dir.join("tests/dia14.rs"), DIA14_FROZEN).unwrap();
    let out = Command::new(env!("CARGO"))
        .current_dir(&crate_dir)
        .args(["test", "--locked", "--offline", "--test", "dia14"])
        .env("CARGO_TARGET_DIR", dir.join("target"))
        .env("DIA14_DIR", &responses)
        .output()
        .expect("build and run the released client's own code");
    assert!(
        out.status.success() && String::from_utf8_lossy(&out.stdout).contains("1 passed; 0 failed"),
        "the released client's own code: {}\n{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let verdicts = fs::read_to_string(responses.join("verdicts")).unwrap();
    let want = "\
request op=hello
request op=snapshot
request op=execute
none.snapshot fact=none recorded|ok blockers= actions=test.read,test.mutate,test.handoff
none.detail admitted
readable-alive.snapshot fact=test.mutate running|info blockers= actions=test.read
readable-alive.detail admitted
readable-unknown.snapshot fact=test.mutate recorded as running; whether its core runs is unknown|warn blockers= actions=test.read
readable-unknown.detail admitted
readable-unsupervised.snapshot fact=test.mutate unsupervised|fail blockers=unsupervised actions=test.read
readable-unsupervised.detail admitted
readable-failed.snapshot fact=test.mutate ended without its expected effect|fail blockers=unresolved actions=test.read
readable-failed.detail admitted
readable-earlier.snapshot fact=test.mutate from an earlier boot, to reconcile|warn blockers= actions=test.read,test.mutate,test.handoff
readable-earlier.detail admitted
unreadable.snapshot fact=a record that cannot be read|fail blockers=unreadable actions=test.read
unreadable.detail admitted
undetermined.snapshot fact=cannot be inspected|unknown blockers=undetermined actions=test.read
undetermined.detail admitted
representation.snapshot fact=a record that cannot be read|fail blockers=unreadable actions=test.read
representation.detail admitted
";
    assert_eq!(verdicts, want);
    eprintln!("DIA-14: the released 0.1.0's own code at {S}:\n{verdicts}");
    fs::remove_dir_all(dir).unwrap();
}
