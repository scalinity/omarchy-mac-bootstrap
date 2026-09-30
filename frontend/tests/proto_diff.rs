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
