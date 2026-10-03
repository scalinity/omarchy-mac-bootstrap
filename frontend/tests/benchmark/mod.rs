//! Benchmark-only controller. Normal tests exercise fixed data, never latency.
//! The sole timing entry is ignored and requires bench/run's explicit mode.
use omb_tui::app::{Action, Cmd, Model, Msg, Screen, Snapshot, update};
use omb_tui::record::{self, Document, Family, Op, Record};
use omb_tui::screens;
use omb_tui::theme::{Caps, Depth, Theme};
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const SCHEMA: &str = "omb-benchmark-1";
const COLD: &str = "first eligible request in a fresh controller/session; no cache flush";
const WARM: &str =
    "subsequent equivalent request in the same session after one verified untimed request";
const TIMEOUT: Duration = Duration::from_secs(30);
const SESSION: &str = "0123456789abcdef";

type Fallible<T> = Result<T, String>;
fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}
fn host() -> (&'static str, &'static str) {
    let os = if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    };
    let arch = if os == "macos" && cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        std::env::consts::ARCH
    };
    (os, arch)
}
fn bash() -> PathBuf {
    // Controller selection. This variable never reaches a core environment.
    std::env::var_os("OMB_BENCH_BASH")
        .or_else(|| std::env::var_os("OMB_TEST_BASH"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/bin/bash"))
}
fn output(cmd: &mut Command) -> Fallible<String> {
    let o = cmd.output().map_err(|e| e.to_string())?;
    if !o.status.success() {
        return Err(String::from_utf8_lossy(&o.stderr).into());
    }
    Ok(String::from_utf8_lossy(&o.stdout).trim().into())
}
fn git(args: &[&str]) -> String {
    output(Command::new("git").arg("-C").arg(root()).args(args)).expect("Git provenance")
}
fn digest_file(p: &Path) -> String {
    record::sha256_hex(&fs::read(p).expect("digest input"))
}
fn executed_source_digest() -> String {
    fn files(dir: &Path, paths: &mut Vec<PathBuf>) {
        for entry in fs::read_dir(dir).unwrap() {
            let entry = entry.unwrap();
            let kind = entry.file_type().unwrap();
            if kind.is_dir() {
                files(&entry.path(), paths);
            } else if kind.is_file() {
                paths.push(entry.path());
            }
        }
    }
    let root = root();
    let mut paths = vec![
        root.join("omarchy-bootstrap"),
        root.join("release/frontend.lock"),
    ];
    files(&root.join("lib"), &mut paths);
    files(&root.join("data"), &mut paths);
    paths.sort();
    let mut body = String::from("omb-source 1\n");
    for p in paths {
        body.push_str(&format!(
            "{}\t{}\n",
            p.strip_prefix(&root).unwrap().display(),
            digest_file(&p)
        ));
    }
    record::sha256_hex(body.as_bytes())
}
fn json(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if c.is_control() => o.push_str(&format!("\\u{:04x}", c as u32)),
            _ => o.push(c),
        }
    }
    o.push('"');
    o
}

#[derive(Clone, Debug)]
struct Case {
    platform: &'static str,
    arch: &'static str,
    id: &'static str,
    label: String,
    scope: &'static str,
    kind: &'static str,
    offset: usize,
    limit: usize,
    items: usize,
    profiles: usize,
    cold: bool,
    budget_ms: usize,
    budget_type: &'static str,
}
impl Case {
    fn op(&self) -> Op {
        if self.id == "bench-validate" || self.label == "validate" {
            Op::Validate
        } else if self.kind.is_empty() {
            Op::Snapshot
        } else {
            Op::Detail
        }
    }
    fn fixture(&self) -> &'static str {
        if self.id == "bench-snapshot" || self.items > 0 {
            "none"
        } else if self.id == "bench-validate" || self.platform == "macos" {
            "mac-m1pro-1tb-roomy"
        } else {
            "linux-alarm-fresh"
        }
    }
    fn witness_name(&self) -> &'static str {
        match self.id {
            "bench-snapshot" => {
                "exact-four-facts-and-body-generation; truthful-native-hello; no-effects"
            }
            "bench-nav" | "bench-search" => {
                "exact-loaded-counts-and-digest; local-operation; resulting-frame; zero-core-requests"
            }
            "bench-validate" => {
                "real-validator; normals; installer-answers; Q4-review-basis; canonical-admission; no-probes"
            }
            "bench-disk" if self.label == "validate" => {
                "complete-request-validator; macOS-fixture-capture; normals; installer-answers; Q4-review-basis; canonical-admission"
            }
            "bench-logs" => "selected-last-log; lines=40; exact-tail-rows/page; unchanged-source",
            "bench-health" => {
                "real-Doctor-counts; nonempty-findings; fixture-network-checks; exact-page"
            }
            _ => {
                "authoritative-journey-machine/status-facts; exact-total/page; canonical-admission"
            }
        }
    }
    fn plan(&self) -> String {
        format!(
            "{{\"schema\":{},\"platform\":{},\"architecture\":{},\"benchmark_id\":{},\"operation_label\":{},\"phase\":{},\"items\":{},\"profile_entries\":{},\"fixture\":{},\"offset\":{},\"limit\":{},\"requested_repetitions\":200,\"warm_up_count\":{},\"witness\":{},\"budget_ms\":{},\"budget_type\":{},\"o1_signoff\":false}}",
            json(SCHEMA),
            json(self.platform),
            json(self.arch),
            json(self.id),
            json(&self.label),
            json(if self.cold { "cold" } else { "warm" }),
            self.items,
            self.profiles,
            json(self.fixture()),
            self.offset,
            self.limit,
            usize::from(!self.cold),
            json(self.witness_name()),
            self.budget_ms,
            json(self.budget_type)
        )
    }
}
fn cases() -> Vec<Case> {
    let mut v = Vec::new();
    for (platform, arch) in [("macos", "arm64"), ("linux", "aarch64")] {
        for cold in [true, false] {
            let base = Case {
                platform,
                arch,
                id: "bench-snapshot",
                label: "frontend-check.snapshot".into(),
                scope: "journey",
                kind: "",
                offset: 0,
                limit: 0,
                items: 0,
                profiles: 0,
                cold,
                budget_ms: 500,
                budget_type: "hard",
            };
            v.push(base.clone());
            for (items, profiles) in [(50, 0), (2000, 400)] {
                for (id, budget) in [("bench-nav", 50), ("bench-search", 100)] {
                    v.push(Case {
                        id,
                        label: format!("loaded-{items}-profiles-{profiles}-operation-and-render"),
                        items,
                        profiles,
                        budget_ms: budget,
                        ..base.clone()
                    });
                }
            }
            v.push(Case {
                id: "bench-validate",
                label: "loaded-macos-capture.compute-and-response".into(),
                scope: "plan",
                budget_ms: 300,
                ..base.clone()
            });
            let (id, budget, bt) = if platform == "macos" {
                ("bench-disk", 2000, "investigate")
            } else {
                ("bench-journey-linux", 500, "hard")
            };
            v.push(Case {
                id,
                label: "journey.snapshot".into(),
                budget_ms: budget,
                budget_type: bt,
                ..base.clone()
            });
            for kind in ["machine", "status"] {
                for (offset, limit) in [(0, 1), (1, 1), (0, 500), (1, 500)] {
                    v.push(Case {
                        id,
                        kind,
                        offset,
                        limit,
                        label: format!("journey.{kind}.offset-{offset}.limit-{limit}"),
                        budget_ms: budget,
                        budget_type: bt,
                        ..base.clone()
                    });
                }
            }
            if platform == "macos" {
                v.push(Case {
                    id: "bench-disk",
                    label: "validate".into(),
                    scope: "plan",
                    budget_ms: 2000,
                    budget_type: "investigate",
                    ..base.clone()
                });
            }
            for (id, scope, kind, budget, bt) in [
                ("bench-health", "health", "doctor", 2000, "investigate"),
                ("bench-logs", "logs", "log", 500, "hard"),
            ] {
                v.push(Case {
                    id,
                    scope,
                    label: format!("{scope}.snapshot"),
                    budget_ms: budget,
                    budget_type: bt,
                    ..base.clone()
                });
                for (offset, limit) in [(0, 1), (1, 1), (0, 500), (1, 500)] {
                    v.push(Case {
                        id,
                        scope,
                        kind,
                        offset,
                        limit,
                        label: format!("{scope}.{kind}.offset-{offset}.limit-{limit}"),
                        budget_ms: budget,
                        budget_type: bt,
                        ..base.clone()
                    });
                }
            }
        }
    }
    v
}
fn nearest(values: &[u64], percent: usize) -> Option<u64> {
    if values.is_empty() {
        return None;
    }
    let mut sorted = values.to_vec();
    sorted.sort_unstable();
    Some(sorted[(percent * sorted.len()).div_ceil(100) - 1])
}
#[derive(Default, Debug)]
struct Samples {
    raw: Vec<u64>,
    failed: usize,
    timeouts: usize,
    outcomes: Vec<String>,
    witnesses: Vec<String>,
    core_requests: usize,
    component_launches: usize,
    setup_requests: usize,
    warm_up_outcome: String,
    profile: Option<Box<PhaseProfile>>,
}
impl Samples {
    fn record(&mut self, outcome: Fallible<u64>) {
        match outcome {
            Ok(n) => {
                self.raw.push(n);
                self.outcomes.push("success".into());
            }
            Err(s) if s == "timeout" => {
                self.timeouts += 1;
                self.outcomes.push(s);
            }
            Err(s) => {
                self.failed += 1;
                self.outcomes.push(s);
            }
        }
    }
    fn fields(&self) -> String {
        let stat = |p| nearest(&self.raw, p).map_or("null".into(), |n| n.to_string());
        format!(
            "\"successful_sample_count\":{},\"failed_sample_count\":{},\"timeout_count\":{},\"raw_duration_samples\":{:?},\"outcomes\":[{}],\"work_witnesses\":[{}],\"actual_core_request_count\":{},\"component_launch_count\":{},\"setup_request_count\":{},\"warm_up_outcome\":{},\"units\":\"ns\",\"p50\":{},\"p95\":{},\"p99\":{},\"maximum\":{}",
            self.raw.len(),
            self.failed,
            self.timeouts,
            self.raw,
            self.outcomes
                .iter()
                .map(|s| json(s))
                .collect::<Vec<_>>()
                .join(","),
            self.witnesses
                .iter()
                .map(|s| json(s))
                .collect::<Vec<_>>()
                .join(","),
            self.core_requests,
            self.component_launches,
            self.setup_requests,
            json(&self.warm_up_outcome),
            stat(50),
            stat(95),
            stat(99),
            self.raw
                .iter()
                .max()
                .map_or("null".into(), |n| n.to_string())
        )
    }
}

// BENCH-M01: supplementary companion observations, never total arithmetic.
const PHASE_NAMES: [&str; 4] = ["startup", "admission", "probes", "validation_computation"];
const PHASE_METHOD: &str = "exact-anchor-copy / acknowledged-boundary-receipt / Rust-Instant";
fn phase_applicable(c: &Case) -> [bool; 4] {
    let complete = c.items == 0 && c.id != "bench-validate";
    [
        complete,
        complete,
        complete && c.id != "bench-snapshot",
        complete && c.op() == Op::Validate,
    ]
}
fn phase_markers(c: &Case) -> Vec<&'static str> {
    let mut markers = vec!["launch", "admission_start", "admission_end"];
    if phase_applicable(c)[2] {
        markers.extend(["probes_start", "probes_end"]);
    }
    if phase_applicable(c)[3] {
        markers.extend(["computation_start", "computation_end"]);
    }
    markers.push("complete");
    markers
}
#[derive(Clone, Debug)]
struct Boundary {
    name: String,
    ns: Option<u64>,
}
fn phase_durations(c: &Case, boundaries: &[Boundary]) -> Fallible<Option<[u64; 4]>> {
    let expected = phase_markers(c);
    if boundaries.len() != expected.len()
        || boundaries
            .iter()
            .zip(&expected)
            .any(|(b, name)| b.name != *name)
    {
        return Err("missing/duplicate/out-of-order phase boundary".into());
    }
    if boundaries.iter().any(|b| b.ns.is_some()) && boundaries.iter().any(|b| b.ns.is_none()) {
        return Err("mixed phase clocks".into());
    }
    if boundaries.iter().all(|b| b.ns.is_none()) {
        return Ok(None);
    }
    let ns = boundaries.iter().map(|b| b.ns.unwrap()).collect::<Vec<_>>();
    if ns.windows(2).any(|pair| pair[1] < pair[0]) {
        return Err("phase end before start / nonmonotonic observations".into());
    }
    let mut durations = [ns[1] - ns[0], ns[2] - ns[1], 0, 0];
    if phase_applicable(c)[2] {
        durations[2] = ns[4] - ns[3];
    }
    if phase_applicable(c)[3] {
        durations[3] = ns[6] - ns[5];
    }
    Ok(Some(durations))
}
fn replace_anchor(
    source: &mut String,
    anchor: &str,
    replacement: &str,
    count: usize,
) -> Fallible<()> {
    if source.matches(anchor).count() != count {
        return Err(format!(
            "instrumentation anchor absent/duplicated: {anchor:?}"
        ));
    }
    *source = source.replace(anchor, replacement);
    Ok(())
}
// Exact base bytes; only observations and source-path shims change. OMB_HOME
// remains the real checkout so identity, lock, fixtures and basis stay real.
fn phase_sources() -> Fallible<Vec<(String, String)>> {
    let mut sources = Vec::new();
    for (path, name) in [
        ("omarchy-bootstrap", "entry"),
        ("lib/core.sh", "core.sh"),
        ("lib/read.sh", "read.sh"),
        ("lib/health.sh", "health.sh"),
        ("lib/logs.sh", "logs.sh"),
        ("lib/validate.sh", "validate.sh"),
    ] {
        let mut source = fs::read_to_string(root().join(path)).map_err(|e| e.to_string())?;
        let changes: Vec<(&str, &str, usize)> = match name {
            "entry" => vec![
                ("set -u\n", "set -u\n. \"$OMB_BENCH_DRIVER\"\n", 1),
                (
                    "_self=${BASH_SOURCE[0]}\n",
                    "_self=${BASH_SOURCE[0]}\n_self=$OMB_BENCH_BASE/omarchy-bootstrap\n",
                    1,
                ),
                (
                    ". \"$OMB_HOME/lib/core.sh\"",
                    ". \"$OMB_BENCH_COPY/core.sh\"",
                    3,
                ),
                (
                    "\nmain \"$@\"\n",
                    "\nmain \"$@\"\nBENCH_PHASE_EXIT=$?\nbench_phase_mark complete\nexit \"$BENCH_PHASE_EXIT\"\n",
                    1,
                ),
            ],
            "core.sh" => vec![
                (
                    "  # 1. Admission, byte by byte, before anything splits the request.\n",
                    "  # 1. Admission, byte by byte, before anything splits the request.\n  bench_phase_mark admission_start\n",
                    1,
                ),
                (
                    ". \"$OMB_HOME/lib/read.sh\"",
                    ". \"$OMB_BENCH_COPY/read.sh\"",
                    4,
                ),
                (
                    ". \"$OMB_HOME/lib/health.sh\"",
                    ". \"$OMB_BENCH_COPY/health.sh\"",
                    1,
                ),
                (
                    ". \"$OMB_HOME/lib/logs.sh\"",
                    ". \"$OMB_BENCH_COPY/logs.sh\"",
                    1,
                ),
                (
                    ". \"$OMB_HOME/lib/validate.sh\"",
                    ". \"$OMB_BENCH_COPY/validate.sh\"",
                    1,
                ),
                (
                    "        case \"$1\" in\n          snapshot) core_journey_snapshot",
                    "        bench_phase_mark admission_end\n        case \"$1\" in\n          snapshot) core_journey_snapshot",
                    1,
                ),
                (
                    "        core_logs_op \"$1\"\n",
                    "        bench_phase_mark admission_end\n        core_logs_op \"$1\"\n",
                    1,
                ),
                (
                    "        core_health_op \"$1\"\n",
                    "        bench_phase_mark admission_end\n        core_health_op \"$1\"\n",
                    1,
                ),
                (
                    "        core_validate_op\n",
                    "        bench_phase_mark admission_end\n        core_validate_op\n        BENCH_PHASE_STATUS=$?\n        bench_phase_mark computation_end\n        (exit \"$BENCH_PHASE_STATUS\")\n",
                    1,
                ),
                (
                    "        core_check_snapshot \"$2\" \"$3\"\n",
                    "        bench_phase_mark admission_end\n        core_check_snapshot \"$2\" \"$3\"\n",
                    1,
                ),
            ],
            "read.sh" => vec![(
                "  cmd_status >/dev/null || return 1\n",
                "  bench_phase_mark probes_start\n  cmd_status >/dev/null || return 1\n  bench_phase_mark probes_end\n",
                1,
            )],
            "health.sh" => vec![(
                "  cmd_doctor >/dev/null\n  __st=$?\n",
                "  bench_phase_mark probes_start\n  cmd_doctor >/dev/null\n  __st=$?\n  bench_phase_mark probes_end\n",
                1,
            )],
            "logs.sh" => vec![
                (
                    "  directory=$(log_dir) || return 1\n",
                    "  bench_phase_mark probes_start\n  directory=$(log_dir) || return 1\n",
                    1,
                ),
                (
                    "  : >\"$OMB_TMP/logs.rows\" || return 1\n",
                    "  bench_phase_mark probes_end\n  : >\"$OMB_TMP/logs.rows\" || return 1\n",
                    1,
                ),
            ],
            "validate.sh" => vec![(
                "  mac_detect\n  mac_plan_compute 0\n",
                "  bench_phase_mark probes_start\n  mac_detect\n  bench_phase_mark probes_end\n  bench_phase_mark computation_start\n  mac_plan_compute 0\n",
                1,
            )],
            _ => unreachable!(),
        };
        for (anchor, replacement, count) in &changes {
            replace_anchor(&mut source, anchor, replacement, *count)?;
        }
        // Permanent transformation invariant: reverse ONLY the declared edits.
        let mut reversed = source.clone();
        for (anchor, replacement, count) in changes.iter().rev() {
            replace_anchor(&mut reversed, replacement, anchor, *count)?;
        }
        if reversed != fs::read_to_string(root().join(path)).map_err(|e| e.to_string())? {
            return Err("instrumentation changed production semantics".into());
        }
        sources.push((name.into(), source));
    }
    Ok(sources)
}
fn phase_copy_digest(sources: &[(String, String)]) -> String {
    let mut manifest = String::from("omb-phase-copy 1\n");
    for (name, source) in sources {
        manifest.push_str(&format!(
            "{name}\t{}\n",
            record::sha256_hex(source.as_bytes())
        ));
    }
    record::sha256_hex(manifest.as_bytes())
}
fn same_response(ordinary: &Document, observed: &Document) -> Fallible<()> {
    if ordinary.records != observed.records {
        return Err("companion semantic equivalence failed".into());
    }
    Ok(())
}
#[derive(Debug)]
struct PhaseObservation {
    boundaries: Vec<Boundary>,
    binding: String,
    response_digest: String,
    copy_digest: String,
    driver_digest: String,
    request_identity: String,
    request_digest: String,
}
#[derive(Default, Debug)]
struct PhaseProfile {
    phases: [Samples; 4],
    observations: Vec<String>,
    core_requests: usize,
    warm_up_requests: usize,
    copy_digest: String,
    driver_digest: String,
}
impl PhaseProfile {
    fn record(&mut self, c: &Case, observation: Fallible<PhaseObservation>) {
        match observation {
            Ok(o) => match phase_durations(c, &o.boundaries) {
                Ok(Some(ns)) => {
                    for (i, applicable) in phase_applicable(c).iter().enumerate() {
                        if *applicable {
                            self.phases[i].record(Ok(ns[i]));
                        }
                    }
                    self.copy_digest = o.copy_digest;
                    self.driver_digest = o.driver_digest;
                    self.observations.push(format!(
                        "{{\"binding\":{},\"request_identity\":{},\"request_sha256\":{},\"response_sha256\":{},\"boundaries\":[{}]}}",
                        json(&o.binding),
                        json(&o.request_identity),
                        json(&o.request_digest),
                        json(&o.response_digest),
                        o.boundaries
                            .iter()
                            .map(|b| format!(
                                "{{\"name\":{},\"observed_ns_from_launch\":{}}}",
                                json(&b.name),
                                b.ns.unwrap()
                            ))
                            .collect::<Vec<_>>()
                            .join(",")
                    ));
                }
                Ok(None) => self.failure(c, "no latency clock in deterministic proof".into()),
                Err(e) => self.failure(c, e),
            },
            Err(e) => self.failure(c, e),
        }
    }
    fn failure(&mut self, c: &Case, error: String) {
        for (i, applicable) in phase_applicable(c).iter().enumerate() {
            if *applicable {
                self.phases[i].record(Err(error.clone()));
            }
        }
    }
    fn fields(&self, c: &Case, requested: usize) -> String {
        let applicable = phase_applicable(c);
        let complete = (0..4).all(|i| {
            !applicable[i]
                || (self.phases[i].raw.len() == requested
                    && self.phases[i].failed == 0
                    && self.phases[i].timeouts == 0)
        });
        let phases = (0..4)
            .map(|i| {
                let state = if !applicable[i] {
                    "not_applicable"
                } else if self.phases[i].raw.is_empty() {
                    if self.phases[i].failed + self.phases[i].timeouts > 0 {
                        "failed"
                    } else {
                        "unavailable"
                    }
                } else {
                    "measured"
                };
                format!(
                    "{}:{{\"applicability\":{},\"state\":{},\"budget_verdict\":\"not_graded\",{}}}",
                    json(PHASE_NAMES[i]),
                    json(if applicable[i] {
                        "required"
                    } else {
                        "not_applicable"
                    }),
                    json(state),
                    self.phases[i].fields()
                )
            })
            .collect::<Vec<_>>()
            .join(",");
        format!(
            "\"diagnostic_phase_profile\":{{\"record_class\":\"companion-instrumentation\",\"observation_mode\":\"separate-companion\",\"instrumentation_method\":{},\"correlation\":\"same-case-and-exact-response; independent executions; no additive or sample-index decomposition\",\"overhead\":\"raw controller receipt times include hook/pipe/ack/scheduling overhead; no correction or subtraction; gaps and cleanup excluded\",\"required_evidence_complete\":{},\"requested_observations\":{},\"instrumented_copy_digest\":{},\"phase_driver_digest\":{},\"companion_core_request_count\":{},\"companion_warm_up_request_count\":{},\"observations\":[{}],\"phases\":{{{}}}}}",
            json(PHASE_METHOD),
            complete,
            if applicable[0] { requested } else { 0 },
            json(&self.copy_digest),
            json(&self.driver_digest),
            self.core_requests,
            self.warm_up_requests,
            self.observations.join(","),
            phases
        )
    }
}

// Temporary controller storage is owned by this process and removed on Drop.
// No user/home contents are read. Every session and file is private.
struct Context {
    dir: PathBuf,
    session: PathBuf,
    n: usize,
    before: String,
    generation: String,
    projection: Option<Vec<Record>>,
    setup_error: Option<String>,
    setup_requests: usize,
    core_requests: usize,
    component_launches: usize,
    proof_trace: bool,
    phase_launches: usize,
    phase_timeout: Duration,
}
fn tree_digest(path: &Path) -> String {
    fn walk(p: &Path, base: &Path, buf: &mut Vec<u8>) {
        if !p.exists() {
            buf.extend_from_slice(b"absent");
            return;
        }
        let meta = fs::symlink_metadata(p).unwrap();
        buf.extend_from_slice(p.strip_prefix(base).unwrap().as_os_str().as_encoded_bytes());
        buf.extend_from_slice(&meta.permissions().mode().to_be_bytes());
        if meta.is_dir() {
            let mut entries = fs::read_dir(p)
                .unwrap()
                .map(|e| e.unwrap().path())
                .collect::<Vec<_>>();
            entries.sort();
            for e in entries {
                walk(&e, base, buf);
            }
        } else if meta.is_file() {
            buf.extend_from_slice(&fs::read(p).unwrap());
        } else {
            panic!("unexpected benchmark storage entry");
        }
    }
    let mut buf = Vec::new();
    walk(path, path, &mut buf);
    record::sha256_hex(&buf)
}
impl Context {
    fn new(case: &Case) -> Self {
        let dir = PathBuf::from(
            output(Command::new("mktemp").args(["-d", "/tmp/omb-benchmark.XXXXXXXX"])).unwrap(),
        );
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let session = dir.join(if case.kind.is_empty() {
            "omb-session.benchmark"
        } else {
            "omb-session.preparation"
        });
        fs::create_dir(&session).unwrap();
        fs::set_permissions(&session, fs::Permissions::from_mode(0o700)).unwrap();
        fs::create_dir(dir.join("tmp")).unwrap();
        fs::create_dir(dir.join("home")).unwrap();
        if case.scope == "logs" {
            let logs = dir.join("state/logs");
            fs::create_dir_all(&logs).unwrap();
            fs::set_permissions(dir.join("state"), fs::Permissions::from_mode(0o700)).unwrap();
            fs::set_permissions(&logs, fs::Permissions::from_mode(0o700)).unwrap();
            private(
                &logs.join("omarchy-bootstrap-000.log"),
                b"older selected-source decoy\n",
            );
            private(
                &logs.join("omarchy-bootstrap-001.log"),
                log_data().as_bytes(),
            );
        }
        let before = tree_digest(&dir.join("state"));
        let mut context = Self {
            dir,
            session,
            n: 0,
            before,
            generation: String::new(),
            projection: None,
            setup_error: None,
            setup_requests: 0,
            core_requests: 0,
            component_launches: 0,
            proof_trace: false,
            phase_launches: 0,
            phase_timeout: TIMEOUT,
        };
        if !case.kind.is_empty() {
            let snapshot_case = Case {
                kind: "",
                ..case.clone()
            };
            match context.request(&snapshot_case, false) {
                Ok((_, snapshot)) => {
                    context.generation = txt(records(&snapshot, "generation")[0], "id").into()
                }
                Err(e) => context.setup_error = Some(e),
            }
            if context.setup_error.is_none() {
                let full_page = Case {
                    offset: 0,
                    limit: 500,
                    ..case.clone()
                };
                match context.request(&full_page, false) {
                    Ok((_, page)) => {
                        context.projection =
                            Some(records(&page, "row").into_iter().cloned().collect())
                    }
                    Err(e) => context.setup_error = Some(e),
                }
            }
            context.setup_requests = context.core_requests;
            context.session = context.dir.join("omb-session.benchmark");
            fs::create_dir(&context.session).unwrap();
            fs::set_permissions(&context.session, fs::Permissions::from_mode(0o700)).unwrap();
            context.n = 0;
        }
        context
    }
    fn prepare(&mut self, c: &Case, kind: &str, offset: usize, limit: usize) -> (PathBuf, PathBuf) {
        self.n += 1;
        let spool = self.session.join(format!("req-{}.events", self.n));
        let req = self.session.join(format!("request-{}", self.n));
        private(&spool, b"omb-res 1\n");
        let op = if c.op() == Op::Validate {
            "validate"
        } else if kind.is_empty() {
            "snapshot"
        } else {
            "detail"
        };
        let version = if c.id == "bench-snapshot" {
            "0.1.0"
        } else {
            "0.2.0"
        };
        let mut bytes =
            format!("omb-req 1\nreq\top={op}\tproto=1\tfrontend={version}\tsession={SESSION}\n");
        if op == "validate" {
            bytes.push_str("select\taction=plan.save\narg\tname=linux_size\tvalue=250GB\narg\tname=shared_size\tvalue=10GB\n");
        } else if kind.is_empty() {
            bytes.push_str(&format!("scope\tname={}\n", c.scope));
        } else {
            bytes.push_str(&format!(
                "page\tscope={}\tkind={kind}\tgeneration={}\toffset={offset}\tlimit={limit}\n",
                c.scope,
                "0".repeat(64)
            ));
        }
        private(&req, bytes.as_bytes());
        (req, spool)
    }
    fn command(&self, c: &Case, req: &Path, spool: &Path, component: bool) -> Command {
        let mut cmd = Command::new(bash());
        cmd.env_clear().process_group(0);
        cmd.env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("HOME", self.dir.join("home"))
            .env("TMPDIR", self.dir.join("tmp"))
            .env("LANG", "C")
            .env("TERM", "dumb")
            .env("OMB_HOME", root())
            .env("OMB_SESSION_INTENT", "read")
            .env("OMB_SESSION_SCOPES", c.scope)
            .env("OMB_DRY_RUN", "0")
            .env("OMB_SESSION_DIR", &self.session)
            .env("OMB_EVENTS", spool)
            .env("OMB_STATE_DIR", self.dir.join("state"));
        if c.id == "bench-snapshot" {
            cmd.env("OMB_SESSION_PURPOSE", "frontend-check");
        } else {
            cmd.env(
                "OMB_FIXTURE",
                root().join("tests/fixtures").join(c.fixture()),
            )
            .env("OMB_FRONTEND_DEV", "1");
        }
        if self.proof_trace {
            cmd.arg("-x");
        }
        if component {
            cmd.arg(root().join("bench/component.sh"))
                .arg(root())
                .arg(root().join("bench/macos-capture.env"))
                .arg(spool)
                .arg(req)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped());
        } else {
            cmd.arg(root().join("omarchy-bootstrap"))
                .arg("core")
                .arg(if c.op() == Op::Validate {
                    "validate"
                } else if c.kind.is_empty() {
                    "snapshot"
                } else {
                    "detail"
                });
            cmd.stdin(Stdio::null()).stdout(Stdio::null());
            let f = File::open(req).unwrap();
            // The captured descriptor stays owned by the closure until fork.
            unsafe {
                cmd.pre_exec(move || {
                    let status = if f.as_raw_fd() == 3 {
                        super::fcntl(3, 2, 0)
                    } else {
                        super::dup2(f.as_raw_fd(), 3)
                    };
                    if status == -1 {
                        Err(std::io::Error::last_os_error())
                    } else {
                        Ok(())
                    }
                });
            }
        }
        cmd.stderr(Stdio::from(File::create(self.dir.join("stderr")).unwrap()));
        cmd
    }
    fn request(&mut self, c: &Case, timed: bool) -> Fallible<(u64, Document)> {
        let (req, spool) = self.prepare(c, c.kind, c.offset, c.limit);
        if !c.kind.is_empty() {
            if let Some(e) = &self.setup_error {
                return Err(format!("generation preparation: {e}"));
            }
            let bytes = fs::read_to_string(&req).map_err(|e| e.to_string())?;
            private(
                &req,
                bytes.replace(&"0".repeat(64), &self.generation).as_bytes(),
            );
        }
        let component = c.id == "bench-validate";
        let mut cmd = self.command(c, &req, &spool, component);
        // No timing clock is called by correctness-level integration requests.
        let started = if timed && !component {
            Some(Instant::now())
        } else {
            None
        };
        let mut child = cmd.spawn().map_err(|e| e.to_string())?;
        if component {
            self.component_launches += 1;
        } else {
            self.core_requests += 1;
        }
        let elapsed;
        if component {
            let stdout = child.stdout.take().unwrap();
            // Reader thread cannot leave a timed-out child holding the controller.
            let (tx, rx) = std::sync::mpsc::channel();
            let reader = std::thread::spawn(move || {
                for l in BufReader::new(stdout).lines() {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
            });
            let ready = rx.recv_timeout(TIMEOUT);
            if !matches!(ready, Ok(Ok(ref s)) if s == "ready") {
                terminate(&mut child);
                reader.join().unwrap();
                return Err(
                    if matches!(ready, Err(std::sync::mpsc::RecvTimeoutError::Timeout)) {
                        "timeout"
                    } else {
                        "component setup failed"
                    }
                    .into(),
                );
            }
            let start = timed.then(Instant::now);
            if let Err(e) = child.stdin.take().unwrap().write_all(b"go\n") {
                terminate(&mut child);
                reader.join().unwrap();
                return Err(e.to_string());
            }
            let completed = rx.recv_timeout(TIMEOUT);
            // End component at its completion marker; cleanup/reap are excluded.
            elapsed = start.map_or(0, |t| t.elapsed().as_nanos() as u64);
            if !matches!(completed, Ok(Ok(ref s)) if s == "complete") {
                terminate(&mut child);
                reader.join().unwrap();
                return Err(
                    if matches!(completed, Err(std::sync::mpsc::RecvTimeoutError::Timeout)) {
                        "timeout"
                    } else {
                        "component incomplete"
                    }
                    .into(),
                );
            }
            let status = wait(&mut child);
            reader.join().unwrap();
            let status = status?;
            if !status {
                return Err("component process failed".into());
            }
        } else {
            let status = wait(&mut child)?;
            // wait observes AND reaps the process before this endpoint.
            elapsed = started.map_or(0, |t| t.elapsed().as_nanos() as u64);
            if !status {
                return Err("core process failed".into());
            }
        }
        if !self.proof_trace && !fs::read(self.dir.join("stderr")).unwrap().is_empty() {
            return Err("nonempty core stderr".into());
        }
        if tree_digest(&self.dir.join("state")) != self.before {
            return Err("persistent effect".into());
        }
        if fs::read_dir(self.dir.join("tmp")).unwrap().next().is_some() {
            return Err("request scratch not cleaned".into());
        }
        let bytes = fs::read(&spool).map_err(|e| e.to_string())?;
        if component {
            let trace = fs::read_to_string(spool.with_extension("events.trace"))
                .map_err(|e| e.to_string())?;
            for name in [
                "parse_size",
                "core_validate_trim",
                "plan_init",
                "plan_compute",
                "plan_validate",
                "plan_layout",
                "plan_verify",
                "core_validate_basis",
                "core_validate_stage",
                "core_read_admit",
            ] {
                if !trace.lines().any(|line| line == name) {
                    return Err(format!("missing production function witness: {name}"));
                }
            }
            if trace.contains("FORBIDDEN-PROBE") {
                return Err("probe acquired inside component".into());
            }
        }
        let doc = record::admit(Family::Res, Some(c.op()), &bytes)
            .map_err(|e| format!("admission {e:?}"))?;
        witness(c, &doc, &bytes)?;
        if !c.kind.is_empty() {
            if txt(records(&doc, "generation")[0], "id") != self.generation {
                return Err("invalid-work: requested page generation".into());
            }
            if let Some(projection) = &self.projection {
                page_witness(c, &doc, &self.generation, projection)?;
            } else if self.session != self.dir.join("omb-session.preparation") {
                return Err("invalid-work: missing prepared projection".into());
            }
        }
        Ok((elapsed, doc))
    }
    fn phase_request(
        &mut self,
        c: &Case,
        ordinary: &Document,
        timed: bool,
    ) -> Fallible<PhaseObservation> {
        self.phase_request_using(c, ordinary, timed, phase_sources()?)
    }
    fn phase_request_using(
        &mut self,
        c: &Case,
        ordinary: &Document,
        timed: bool,
        sources: Vec<(String, String)>,
    ) -> Fallible<PhaseObservation> {
        let copy_digest = phase_copy_digest(&sources);
        let copy = self.dir.join("phase-copy");
        fs::create_dir_all(&copy).map_err(|e| e.to_string())?;
        for (name, source) in &sources {
            private(&copy.join(name), source.as_bytes());
        }
        let driver_digest = digest_file(&root().join("bench/phases.sh"));
        let (req, spool) = self.prepare(c, c.kind, c.offset, c.limit);
        if !c.kind.is_empty() {
            private(
                &req,
                fs::read_to_string(&req)
                    .unwrap()
                    .replace(&"0".repeat(64), &self.generation)
                    .as_bytes(),
            );
        }
        let base_sha = git(&["rev-parse", "HEAD"]);
        let base_source = executed_source_digest();
        let fixture_digest = tree_digest(&root().join("tests/fixtures").join(c.fixture()));
        let request_digest = digest_file(&req);
        let binding = record::sha256_hex(
            format!(
                "{}\n{}\n{}\n{}\n{}\n{}\n{}\n{}",
                base_sha,
                base_source,
                c.plan(),
                fixture_digest,
                copy_digest,
                driver_digest,
                req.display(),
                request_digest
            )
            .as_bytes(),
        );
        let cmd = self.command(c, &req, &spool, false);
        // Preserve the ordinary environment/fd-3 setup, changing only script
        // path and benchmark-private observation transport/identity.
        let args = cmd.get_args().map(|a| a.to_os_string()).collect::<Vec<_>>();
        let env = cmd
            .get_envs()
            .map(|(k, v)| (k.to_os_string(), v.map(|v| v.to_os_string())))
            .collect::<Vec<_>>();
        let mut observed = Command::new(bash());
        observed.env_clear().process_group(0);
        for (k, v) in env {
            if let Some(v) = v {
                observed.env(k, v);
            }
        }
        if self.proof_trace {
            observed.arg("-x");
        }
        observed
            .arg(copy.join("entry"))
            .args(&args[if self.proof_trace { 2 } else { 1 }..]);
        observed
            .env("OMB_BENCH_BASE", root())
            .env("OMB_BENCH_COPY", &copy)
            .env("OMB_BENCH_DRIVER", root().join("bench/phases.sh"))
            .env("OMB_BENCH_BINDING", &binding)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(
                File::create(self.dir.join("phase-stderr")).unwrap(),
            ));
        let f = File::open(&req).map_err(|e| e.to_string())?;
        unsafe {
            observed.pre_exec(move || {
                let status = if f.as_raw_fd() == 3 {
                    super::fcntl(3, 2, 0)
                } else {
                    super::dup2(f.as_raw_fd(), 3)
                };
                if status == -1 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(())
                }
            });
        }
        // This clock is disabled for ordinary deterministic tests. The other
        // Instant below enforces liveness only and supplies no phase samples.
        let launch = timed.then(Instant::now);
        let mut child = observed.spawn().map_err(|e| e.to_string())?;
        self.phase_launches += 1;
        let (tx, rx) = std::sync::mpsc::channel();
        let stdout = child.stdout.take().unwrap();
        let reader = std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let deadline = Instant::now() + self.phase_timeout;
        let mut boundaries = vec![Boundary {
            name: "launch".into(),
            ns: timed.then_some(0),
        }];
        let collect = (|| {
            for expected in phase_markers(c).iter().skip(1) {
                let remaining = deadline.saturating_duration_since(Instant::now());
                let line = rx
                    .recv_timeout(remaining)
                    .map_err(|e| match e {
                        std::sync::mpsc::RecvTimeoutError::Timeout => String::from("timeout"),
                        _ => String::from("companion exited before complete boundary evidence"),
                    })?
                    .map_err(|e| e.to_string())?;
                let ns = launch.map(|t| t.elapsed().as_nanos() as u64);
                if line != format!("{binding}\t{expected}") {
                    return Err(
                        "wrong binding / malformed / duplicate / out-of-order marker".into(),
                    );
                }
                boundaries.push(Boundary {
                    name: (*expected).into(),
                    ns,
                });
                child
                    .stdin
                    .as_mut()
                    .unwrap()
                    .write_all(b"observed\n")
                    .map_err(|e| e.to_string())?;
            }
            Ok(())
        })();
        child.stdin.take();
        let completed = collect.and_then(|()| {
            wait_phase(&mut child, deadline).and_then(|ok| {
                if ok {
                    Ok(())
                } else {
                    Err("companion process failed".into())
                }
            })
        });
        if completed.is_err() {
            terminate(&mut child);
        }
        reader.join().map_err(|_| "phase reader failed")?;
        completed?;
        if rx.try_recv().is_ok() {
            return Err("extra phase boundary".into());
        }
        phase_durations(c, &boundaries)?;
        if !self.proof_trace && !fs::read(self.dir.join("phase-stderr")).unwrap().is_empty() {
            return Err("nonempty companion stderr".into());
        }
        if tree_digest(&self.dir.join("state")) != self.before
            || fs::read_dir(self.dir.join("home"))
                .unwrap()
                .next()
                .is_some()
            || fs::read_dir(self.dir.join("tmp")).unwrap().next().is_some()
        {
            return Err("companion persistent effect or scratch leak".into());
        }
        let bytes = fs::read(&spool).map_err(|e| e.to_string())?;
        let doc = record::admit(Family::Res, Some(c.op()), &bytes)
            .map_err(|e| format!("companion admission {e:?}"))?;
        witness(c, &doc, &bytes)?;
        if !c.kind.is_empty() {
            page_witness(
                c,
                &doc,
                &self.generation,
                self.projection.as_ref().ok_or("missing page projection")?,
            )?;
        }
        same_response(ordinary, &doc)?;
        // The retained copy, driver, fixture and ordinary source must still be
        // the ones bound before launch; tampering is not valid phase evidence.
        if git(&["rev-parse", "HEAD"]) != base_sha
            || executed_source_digest() != base_source
            || tree_digest(&root().join("tests/fixtures").join(c.fixture())) != fixture_digest
            || digest_file(&req) != request_digest
            || phase_sources()? != sources
            || digest_file(&root().join("bench/phases.sh")) != driver_digest
            || sources
                .iter()
                .any(|(n, s)| fs::read(copy.join(n)).unwrap() != s.as_bytes())
        {
            return Err("phase instrumentation identity changed".into());
        }
        Ok(PhaseObservation {
            boundaries,
            binding,
            response_digest: record::sha256_hex(&bytes),
            copy_digest,
            driver_digest,
            request_identity: req.display().to_string(),
            request_digest,
        })
    }
}
impl Drop for Context {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.dir).expect("owned benchmark cleanup");
    }
}
fn private(path: &Path, bytes: &[u8]) {
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}
fn log_data() -> String {
    (1..=47)
        .map(|i| format!("2026-01-01T00:00:00Z [macos] info   line-{i:03}\n"))
        .collect()
}
fn terminate(child: &mut Child) {
    // Group is created by this spawn, exclusively owned; never discover by name.
    let pid = rustix::process::Pid::from_raw(child.id() as i32).unwrap();
    let _ = rustix::process::kill_process_group(pid, rustix::process::Signal::KILL);
    let _ = child.wait();
}
fn wait(child: &mut Child) -> Fallible<bool> {
    // Timeout clock enforces the deadline; correctness integration never
    // turns it into a performance sample or statistic.
    let deadline = Instant::now() + TIMEOUT;
    while Instant::now() < deadline {
        if let Some(s) = child.try_wait().map_err(|e| e.to_string())? {
            return Ok(s.success());
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    terminate(child);
    Err("timeout".into())
}
fn wait_phase(child: &mut Child, deadline: Instant) -> Fallible<bool> {
    while Instant::now() < deadline {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            return Ok(status.success());
        }
        std::thread::sleep(Duration::from_millis(1));
    }
    Err("timeout".into())
}
fn txt<'a>(r: &'a Record, k: &str) -> &'a str {
    r.text(k).unwrap_or("")
}
fn records<'a>(d: &'a Document, ty: &str) -> Vec<&'a Record> {
    d.records.iter().filter(|r| r.ty == ty).collect()
}
fn page_witness(c: &Case, d: &Document, generation: &str, projection: &[Record]) -> Fallible<()> {
    if txt(records(d, "generation")[0], "id") != generation {
        return Err("invalid-work: requested page generation".into());
    }
    let expected = projection
        .iter()
        .skip(c.offset)
        .take(c.limit)
        .collect::<Vec<_>>();
    if records(d, "row") != expected {
        return Err("invalid-work: exact prepared page".into());
    }
    Ok(())
}
fn witness(c: &Case, d: &Document, bytes: &[u8]) -> Fallible<()> {
    let bad = |s: &str| Err(format!("invalid-work: {s}"));
    let results = records(d, "result");
    if results.len() != 1 || txt(results[0], "status") != "done" || txt(results[0], "code") != "ok"
    {
        return bad(&format!(
            "not done ok: {:?}; messages: {:?}",
            results
                .iter()
                .map(|r| (txt(r, "status"), txt(r, "code"), txt(r, "text")))
                .collect::<Vec<_>>(),
            records(d, "message")
                .iter()
                .map(|r| (txt(r, "level"), txt(r, "text")))
                .collect::<Vec<_>>()
        ));
    }
    let hellos = records(d, "hello");
    if hellos.len() != 1
        || txt(hellos[0], "proto") != "1"
        || txt(hellos[0], "ceiling") != "read"
        || txt(hellos[0], "dry_run") != "0"
        || txt(hellos[0], "source").len() != 64
    {
        return bad("hello");
    }
    if txt(hellos[0], "source") != executed_source_digest() {
        return bad("executed source identity");
    }
    if c.id == "bench-snapshot" {
        let (os, arch) = host();
        let arch = if arch == "aarch64" && os == "macos" {
            "arm64"
        } else {
            arch
        };
        if txt(hellos[0], "platform") != os
            || txt(hellos[0], "arch") != arch
            || txt(hellos[0], "fixture") != "0"
            || txt(hellos[0], "commit") != git(&["rev-parse", "HEAD"])
        {
            return bad("native snapshot identity");
        }
        let types = d.records.iter().map(|r| r.ty.as_str()).collect::<Vec<_>>();
        if types
            != [
                "hello",
                "generation",
                "fact",
                "fact",
                "fact",
                "fact",
                "result",
            ]
        {
            return bad("snapshot shape");
        }
        let expected = [
            (
                "check",
                "Check",
                "frontend startup check (frontend-check)",
                "info",
            ),
            (
                "interface",
                "Interface",
                "frontend 0.1.0 as the lock pins, protocol 1",
                "ok",
            ),
            (
                "session",
                "Session",
                "read-only, journey scope only, not a dry run",
                "info",
            ),
            ("actions", "Actions", "none in this session", "info"),
        ];
        for (r, (key, label, value, state)) in records(d, "fact").iter().zip(expected) {
            if txt(r, "scope") != "journey"
                || txt(r, "key") != key
                || txt(r, "label") != label
                || txt(r, "value") != value
                || txt(r, "state") != state
            {
                return bad("four-fact witness");
            }
        }
        let generation = records(d, "generation")[0];
        let fact_lines = String::from_utf8_lossy(bytes)
            .lines()
            .filter(|l| l.starts_with("fact\t"))
            .map(str::to_owned)
            .collect::<Vec<_>>()
            .join("\n");
        if txt(generation, "total") != "0"
            || txt(generation, "id") != record::sha256_hex(fact_lines.as_bytes())
            || !txt(results[0], "text").is_empty()
            || !txt(results[0], "next").is_empty()
        {
            return bad("body hash or result");
        }
    } else if c.op() == Op::Validate {
        if !records(d, "invalid").is_empty()
            || records(d, "answer").is_empty()
            || records(d, "review").len() != 1
            || txt(records(d, "review")[0], "action") != "plan.save"
            || txt(records(d, "review")[0], "basis").len() != 64
        {
            return bad("validation basis/answers");
        }
        let normal = records(d, "normal");
        if normal.len() != 2
            || !normal
                .iter()
                .any(|r| txt(r, "name") == "linux_size" && txt(r, "value") == "250000000000")
            || !normal
                .iter()
                .any(|r| txt(r, "name") == "shared_size" && txt(r, "value") == "10000000000")
        {
            return bad("normalized sizes");
        }
    } else if c.kind.is_empty() {
        let facts = records(d, "fact");
        match c.scope {
            "journey" => {
                let platform = facts.iter().find(|r| txt(r, "key") == "machine.platform");
                if platform.is_none_or(|r| txt(r, "value") != c.platform) || facts.len() < 8 {
                    return bad("journey facts");
                }
            }
            "health" => {
                if facts.len() != 3
                    || !["doctor.pass", "doctor.warn", "doctor.fail"]
                        .iter()
                        .all(|k| facts.iter().any(|r| txt(r, "key") == *k))
                    || facts
                        .iter()
                        .map(|r| txt(r, "value").parse::<usize>().unwrap_or(0))
                        .sum::<usize>()
                        == 0
                {
                    return bad("Doctor counts");
                }
            }
            "logs" => {
                if !facts
                    .iter()
                    .any(|r| txt(r, "key") == "logs.lines" && txt(r, "value") == "40")
                    || !facts.iter().any(|r| {
                        txt(r, "key") == "logs.source"
                            && txt(r, "value").ends_with("omarchy-bootstrap-001.log")
                    })
                {
                    return bad("source/window");
                }
            }
            _ => return bad("scope"),
        }
    } else {
        let generation = records(d, "generation");
        let rows = records(d, "row");
        if generation.len() != 1 {
            return bad("page generation");
        }
        let total = txt(generation[0], "total")
            .parse::<usize>()
            .map_err(|_| "invalid total".to_string())?;
        let expected = total.saturating_sub(c.offset).min(c.limit);
        if expected == 0 || rows.len() != expected || rows.iter().any(|r| txt(r, "kind") != c.kind)
        {
            return bad("page work/count");
        }
        if c.scope == "logs"
            && (total != 40
                || rows.iter().enumerate().any(|(i, r)| {
                    let cols = r.list("col");
                    cols.len() != 4 || cols[3] != format!("line-{:03}", c.offset + i + 8).as_bytes()
                }))
        {
            return bad("exact last-40 window");
        }
        let required_total = match c.kind {
            "machine" => 6,
            "status" if c.platform == "macos" => 9,
            "status" => 5,
            "doctor" if c.platform == "macos" => 14,
            "doctor" => 16,
            "log" => 40,
            _ => return bad("unknown projection"),
        };
        if total != required_total {
            return bad("fixture projection total");
        }
    }
    Ok(())
}

#[derive(Clone, Debug)]
struct Loaded {
    items: Vec<Action>,
    profiles: Vec<Action>,
}
impl Loaded {
    fn new(count: usize, profile_count: usize) -> Self {
        let make = |prefix: &str, n| {
            (0..n)
                .map(|i| Action {
                    id: format!("{prefix}-{i:04}"),
                    label: format!(
                        "{prefix}-{i:04}-{}",
                        if i % 10 == 0 { "match" } else { "other" }
                    ),
                    intent: "read".into(),
                    gate: String::new(),
                    handoff: false,
                    cancel: false,
                    basis: "0".repeat(64),
                    explain: "synthetic benchmark data".into(),
                })
                .collect()
        };
        Self {
            items: make("item", count),
            profiles: make("profile", profile_count),
        }
    }
    fn digest(&self) -> String {
        let bytes = self
            .items
            .iter()
            .chain(&self.profiles)
            .map(|a| format!("{}\t{}\n", a.id, a.label))
            .collect::<String>();
        record::sha256_hex(bytes.as_bytes())
    }
    fn model(&self) -> Model {
        Model {
            screen: Screen::Dashboard,
            snap: Some(Snapshot {
                actions: self.items.iter().chain(&self.profiles).cloned().collect(),
                ..Snapshot::default()
            }),
            ..Model::default()
        }
    }
}
fn frontend_work(
    c: &Case,
    loaded: &Loaded,
    m: &mut Model,
    term: &mut Terminal<TestBackend>,
) -> Fallible<()> {
    if loaded.items.len() != c.items || loaded.profiles.len() != c.profiles {
        return Err("invalid loaded counts".into());
    }
    let cmds: Vec<Cmd>;
    if c.id == "bench-nav" {
        cmds = update(
            m,
            Msg::Key(KeyEvent::new(
                if m.focus == 0 {
                    KeyCode::Down
                } else {
                    KeyCode::Up
                },
                KeyModifiers::NONE,
            )),
        );
    } else {
        // Benchmark-only filter; no product search UI or request type is added.
        let actions = loaded
            .items
            .iter()
            .chain(&loaded.profiles)
            .filter(|a| a.label.ends_with("match"))
            .cloned()
            .collect::<Vec<_>>();
        if actions.len() != (c.items + c.profiles).div_ceil(10) {
            return Err("filter count".into());
        }
        m.snap.as_mut().unwrap().actions = actions;
        m.focus = 1;
        cmds = Vec::new();
    }
    if !cmds.is_empty() {
        return Err("local operation emitted commands".into());
    }
    let theme = Theme::new(Caps {
        depth: Depth::None,
        unicode: false,
        console: false,
    });
    term.draw(|f| screens::draw(f, m, &theme, 50))
        .map_err(|e| e.to_string())?;
    // The operation plus the resulting real frontend draw (including backend
    // diff/flush) precedes the timing endpoint. Fixed terminal viewport.
    let visible = term
        .backend()
        .buffer()
        .content
        .iter()
        .map(|c| c.symbol())
        .collect::<String>();
    if m.focused().is_none_or(|a| !visible.contains(&a.label)) {
        return Err("resulting visible frame/focus".into());
    }
    Ok(())
}

#[derive(Debug)]
struct Provenance {
    sha: String,
    lock: String,
    frontend: String,
    harness: String,
    bash: String,
    machine: String,
    system: String,
    runner: String,
}
impl Provenance {
    fn matches_sources(&self, current_sha: &str, clean: bool) -> bool {
        self.sha == current_sha && clean
    }
    fn source_unchanged(&self) -> bool {
        self.matches_sources(
            &git(&["rev-parse", "HEAD"]),
            git(&[
                "status",
                "--porcelain",
                "--",
                "bench",
                "frontend",
                "lib",
                "data",
                "release",
                "omarchy-bootstrap",
                "tests/fixtures",
                "tests/frontend-inputs.sh",
            ])
            .is_empty(),
        )
    }
    fn validate(&self) -> Fallible<()> {
        if [
            &self.sha,
            &self.lock,
            &self.frontend,
            &self.harness,
            &self.bash,
            &self.machine,
            &self.system,
            &self.runner,
        ]
        .iter()
        .any(|s| s.trim().is_empty())
        {
            Err("missing benchmark provenance".into())
        } else {
            Ok(())
        }
    }
    fn new() -> Self {
        let root = root();
        let bash_version =
            output(Command::new(bash()).args(["-c", "printf '%s' \"$BASH_VERSION\""])).unwrap();
        Self {
            sha: git(&["rev-parse", "HEAD"]),
            lock: digest_file(&root.join("release/frontend.lock")),
            frontend: output(
                Command::new("bash")
                    .arg(root.join("tests/frontend-inputs.sh"))
                    .arg("digest"),
            )
            .unwrap(),
            harness: record::sha256_hex(
                format!(
                    "{}\n{}\n",
                    tree_digest(&root.join("bench")),
                    digest_file(&root.join("frontend/tests/benchmark/mod.rs"))
                )
                .as_bytes(),
            ),
            bash: bash_version,
            machine: std::env::var("OMB_BENCH_MACHINE_LABEL")
                .unwrap_or_else(|_| "local-unlabelled".into()),
            system: output(Command::new("uname").arg("-sr")).unwrap(),
            runner: digest_file(&std::env::current_exe().unwrap()),
        }
    }
    fn fields(&self) -> String {
        let (os, arch) = host();
        format!(
            "\"source_git_sha\":{},\"production_lock_digest\":{},\"production_release\":\"frontend-v0.1.0\",\"frontend_candidate_inputs_digest\":{},\"frontend_candidate_version\":\"0.2.0-unreleased\",\"harness_digest\":{},\"os\":{},\"architecture\":{},\"system\":{},\"machine_label\":{},\"bash_version\":{},\"benchmark_executable_sha256\":{},\"benchmark_profile\":{},\"release_strip_override\":{},\"toolchain_config_sha256\":{}",
            json(&self.sha),
            json(&self.lock),
            json(&self.frontend),
            json(&self.harness),
            json(os),
            json(arch),
            json(&self.system),
            json(&self.machine),
            json(&self.bash),
            json(&self.runner),
            json(if cfg!(debug_assertions) {
                "test-debug"
            } else {
                "test-release"
            }),
            json(
                &std::env::var("CARGO_PROFILE_RELEASE_STRIP")
                    .unwrap_or_else(|_| "repository_default".into())
            ),
            json(&digest_file(&root().join("frontend/rust-toolchain.toml")))
        )
    }
}
fn native_case(c: &Case) -> bool {
    let (os, arch) = host();
    c.platform == os && (c.id != "bench-snapshot" || c.arch == arch)
}
struct FrontWorker {
    child: Child,
    tx: std::process::ChildStdin,
    rx: std::sync::mpsc::Receiver<String>,
    reader: Option<std::thread::JoinHandle<()>>,
    expected: String,
    last_witness: String,
}
impl FrontWorker {
    fn new(c: &Case) -> Fallible<Self> {
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "benchmark::frontend_worker",
                "--ignored",
                "--nocapture",
            ])
            .env_clear()
            .env("OMB_BENCH_WORKER_CASE", &c.label)
            .env("OMB_BENCH_WORKER_ID", c.id)
            .process_group(0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| e.to_string())?;
        let tx = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (sender, rx) = std::sync::mpsc::channel();
        let reader = std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Some(at) = line.find("bench-worker ") {
                    if sender.send(line[at..].to_owned()).is_err() {
                        break;
                    }
                }
            }
        });
        let worker = Self {
            child,
            tx,
            rx,
            reader: Some(reader),
            expected: Loaded::new(c.items, c.profiles).digest(),
            last_witness: String::new(),
        };
        let ready = format!(
            "bench-worker ready {} {} {}",
            c.items, c.profiles, worker.expected
        );
        let response = worker.rx.recv_timeout(TIMEOUT);
        if response.as_deref() != Ok(ready.as_str()) {
            return Err(
                if matches!(response, Err(std::sync::mpsc::RecvTimeoutError::Timeout)) {
                    "timeout"
                } else {
                    "frontend worker setup failure"
                }
                .into(),
            );
        }
        Ok(worker)
    }
    fn request(&mut self, timed: bool) -> Fallible<u64> {
        let start = timed.then(Instant::now);
        self.tx.write_all(b"go\n").map_err(|e| e.to_string())?;
        let reply = self.rx.recv_timeout(TIMEOUT).map_err(|e| match e {
            std::sync::mpsc::RecvTimeoutError::Timeout => "timeout".to_string(),
            std::sync::mpsc::RecvTimeoutError::Disconnected => {
                "frontend worker incomplete".to_string()
            }
        })?;
        let duration = start.map_or(0, |s| s.elapsed().as_nanos() as u64);
        let parts = reply.split_whitespace().collect::<Vec<_>>();
        if parts.len() != 5
            || parts[0] != "bench-worker"
            || parts[1] != "complete"
            || parts[2] != self.expected
            || parts[3].len() != 64
            || parts[4] != "core-requests=0"
        {
            return Err(reply);
        }
        self.last_witness = reply;
        Ok(duration)
    }
}
impl Drop for FrontWorker {
    fn drop(&mut self) {
        terminate(&mut self.child);
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}
#[test]
#[ignore = "owned benchmark frontend worker only"]
fn frontend_worker() {
    let label = std::env::var("OMB_BENCH_WORKER_CASE").expect("benchmark worker");
    let id = std::env::var("OMB_BENCH_WORKER_ID").unwrap();
    let c = cases()
        .into_iter()
        .find(|c| c.label == label && c.id == id)
        .unwrap();
    let loaded = Loaded::new(c.items, c.profiles);
    let mut m = loaded.model();
    let mut term = Terminal::new(TestBackend::new(120, 40)).unwrap();
    println!(
        "bench-worker ready {} {} {}",
        loaded.items.len(),
        loaded.profiles.len(),
        loaded.digest()
    );
    std::io::stdout().flush().unwrap();
    for command in std::io::stdin().lock().lines() {
        if command.unwrap() != "go" {
            break;
        }
        match frontend_work(&c, &loaded, &mut m, &mut term) {
            Ok(()) => {
                let frame = term
                    .backend()
                    .buffer()
                    .content
                    .iter()
                    .map(|c| c.symbol())
                    .collect::<String>();
                println!(
                    "bench-worker complete {} {} core-requests=0",
                    loaded.digest(),
                    record::sha256_hex(frame.as_bytes())
                );
            }
            Err(e) => println!("bench-worker invalid-work {e}"),
        }
        std::io::stdout().flush().unwrap();
    }
}
fn run_case(c: &Case, repetitions: usize, timed: bool) -> (Samples, String) {
    run_case_observed(c, repetitions, timed, timed)
}
fn run_case_observed(
    c: &Case,
    repetitions: usize,
    timed: bool,
    observe_phases: bool,
) -> (Samples, String) {
    let mut samples = Samples::default();
    let mut source = String::new();
    if c.items > 0 {
        let loaded = Loaded::new(c.items, c.profiles);
        if timed {
            let mut worker = None;
            if !c.cold {
                match FrontWorker::new(c).and_then(|mut w| {
                    w.request(false)?;
                    Ok(w)
                }) {
                    Ok(w) => {
                        samples.warm_up_outcome = "verified".into();
                        worker = Some(w);
                    }
                    Err(e) => {
                        samples.warm_up_outcome = e.clone();
                        for _ in 0..repetitions {
                            samples.record(Err(format!("warm-up failed: {e}")));
                        }
                        return (samples, loaded.digest());
                    }
                }
            }
            for _ in 0..repetitions {
                if c.cold {
                    match FrontWorker::new(c) {
                        Ok(w) => worker = Some(w),
                        Err(e) => {
                            samples.record(Err(e));
                            continue;
                        }
                    }
                }
                let answer = worker.as_mut().unwrap().request(true);
                let stopped = answer.is_err();
                if !stopped {
                    samples
                        .witnesses
                        .push(worker.as_ref().unwrap().last_witness.clone());
                }
                samples.record(answer);
                if stopped {
                    worker.take();
                    for _ in samples.outcomes.len()..repetitions {
                        samples.record(Err("group stopped after worker failure".into()));
                    }
                    break;
                }
            }
            return (samples, loaded.digest());
        }
        let mut m = loaded.model();
        let mut term = Terminal::new(TestBackend::new(120, 40)).unwrap();
        if !c.cold
            && let Err(e) = frontend_work(c, &loaded, &mut m, &mut term)
        {
            samples.record(Err(format!("warm-up: {e}")));
            return (samples, loaded.digest());
        }
        for _ in 0..repetitions {
            if c.cold {
                m = loaded.model();
                term = Terminal::new(TestBackend::new(120, 40)).unwrap();
            }
            let start = timed.then(Instant::now);
            let work = frontend_work(c, &loaded, &mut m, &mut term);
            let duration = start.map_or(0, |s| s.elapsed().as_nanos() as u64);
            samples.record(work.map(|()| duration));
        }
        return (samples, loaded.digest());
    }
    let mut ordinary = Vec::new();
    let mut cold_contexts = Vec::new();
    let mut context = Context::new(c);
    samples.setup_requests += context.setup_requests;
    samples.core_requests += context.setup_requests;
    if !c.cold {
        let before = context.core_requests;
        let warm = context.request(c, false);
        samples.core_requests += context.core_requests - before;
        samples.component_launches += context.component_launches;
        match warm {
            Ok((_, d)) => {
                source = txt(records(&d, "hello")[0], "source").into();
                samples.warm_up_outcome = "verified".into();
            }
            Err(e) => {
                samples.warm_up_outcome = e.clone();
                for _ in 0..repetitions {
                    samples.record(Err(format!("warm-up failed: {e}")));
                }
                return (samples, source);
            }
        }
    }
    for index in 0..repetitions {
        if c.cold && index > 0 {
            // Returned records include private state/log paths. Keep each
            // sample's exact inputs alive for its later diagnostic companion.
            if observe_phases {
                cold_contexts.push(std::mem::replace(&mut context, Context::new(c)));
            } else {
                context = Context::new(c);
            }
            samples.setup_requests += context.setup_requests;
            samples.core_requests += context.setup_requests;
        }
        let requests_before = context.core_requests;
        let components_before = context.component_launches;
        let answer = context.request(c, timed);
        samples.core_requests += context.core_requests - requests_before;
        samples.component_launches += context.component_launches - components_before;
        match answer {
            Ok((n, d)) => {
                source = txt(records(&d, "hello")[0], "source").into();
                let bytes = d
                    .records
                    .iter()
                    .map(|r| {
                        let fields = r
                            .fields
                            .iter()
                            .map(|(k, v)| (k.as_str(), v.as_slice()))
                            .collect::<Vec<_>>();
                        record::line(&r.ty, &fields)
                    })
                    .collect::<String>();
                samples.witnesses.push(format!(
                    "admitted-response-sha256={}; records={}; source={}",
                    record::sha256_hex(bytes.as_bytes()),
                    d.records.len(),
                    source
                ));
                ordinary.push(Some(d));
                samples.record(Ok(n));
            }
            Err(e) => {
                ordinary.push(None);
                samples.record(Err(e));
            }
        }
    }
    if observe_phases && phase_applicable(c)[0] {
        let mut profile = PhaseProfile {
            copy_digest: phase_sources()
                .map(|s| phase_copy_digest(&s))
                .unwrap_or_default(),
            driver_digest: digest_file(&root().join("bench/phases.sh")),
            ..PhaseProfile::default()
        };
        let create_session = |ctx: &mut Context, index| {
            ctx.session = ctx.dir.join(format!("omb-session.phase-{index}"));
            fs::create_dir(&ctx.session).unwrap();
            fs::set_permissions(&ctx.session, fs::Permissions::from_mode(0o700)).unwrap();
            ctx.n = 0;
        };
        if !c.cold {
            create_session(&mut context, 0);
        }
        let warm = if !c.cold {
            profile.warm_up_requests = 1;
            context.request(c, false).map(|_| ())
        } else {
            Ok(())
        };
        for (index, reference) in ordinary.iter().enumerate() {
            let ctx = if index < cold_contexts.len() {
                &mut cold_contexts[index]
            } else {
                &mut context
            };
            if c.cold {
                create_session(ctx, index);
            }
            let before = ctx.phase_launches;
            let observation = match (&warm, reference) {
                (Ok(()), Some(doc)) => ctx.phase_request(c, doc, timed),
                (Err(e), _) => Err(format!("companion warm-up failed: {e}")),
                _ => Err("ordinary semantic witness unavailable".into()),
            };
            profile.core_requests += ctx.phase_launches - before;
            profile.record(c, observation);
        }
        samples.profile = Some(Box::new(profile));
    }
    (samples, source)
}
fn result(
    c: &Case,
    samples: &Samples,
    identity: &str,
    p: &Provenance,
    mode: &str,
    repetitions: usize,
) -> String {
    let workload_digest = if c.items > 0 {
        identity.into()
    } else if c.id == "bench-validate" {
        digest_file(&root().join("bench/macos-capture.env"))
    } else if c.scope == "logs" {
        record::sha256_hex(log_data().as_bytes())
    } else if c.id == "bench-snapshot" {
        record::sha256_hex(b"frontend-check-1-four-facts")
    } else {
        tree_digest(&root().join("tests/fixtures").join(c.fixture()))
    };
    let native_probe = false;
    let profile = samples.profile.as_deref().map_or_else(
        || PhaseProfile::default().fields(c, repetitions),
        |profile| profile.fields(c, repetitions),
    );
    format!(
        "{{\"schema\":{},\"benchmark_id\":{},\"operation_label\":{},\"mode\":{},\"smoke\":{},\"o1_signoff\":false,\"classification\":\"NON-AUTHORITATIVE\",{},\"executed_source_identity\":{},\"fixture\":{},\"fixture_digest\":{},\"workload_digest\":{},\"input_class\":{},\"native_probe\":{},\"frontend_request_version\":{},\"frontend_executable_run\":false,\"core_request_count\":{},\"items\":{},\"profile_entries\":{},\"phase\":{},\"lifecycle_definition\":{},\"warm_up_count\":{},\"requested_repetitions\":{}, {},\"work_witness\":{},\"budget_ms\":{},\"budget_type\":{},\"budget_verdict\":\"not_graded\",\"initiation_feedback\":\"not_applicable\",\"timeout_ms\":30000,{},\"notes\":{}}}",
        json(SCHEMA),
        json(c.id),
        json(&c.label),
        json(mode),
        mode == "smoke",
        p.fields(),
        json(if c.items > 0 {
            "not_applicable"
        } else {
            identity
        }),
        json(c.fixture()),
        json(
            if c.fixture() == "none" {
                "not_applicable".into()
            } else {
                tree_digest(&root().join("tests/fixtures").join(c.fixture()))
            }
            .as_str()
        ),
        json(&workload_digest),
        json(if c.items > 0 {
            "synthetic-frontend-loaded-model"
        } else if c.id == "bench-validate" {
            "loaded-macos-capture"
        } else if c.id == "bench-snapshot" {
            "native-startup-check"
        } else {
            "fixture-backed-core"
        }),
        native_probe,
        json(if c.items > 0 {
            "not_applicable"
        } else if c.id == "bench-snapshot" {
            "0.1.0"
        } else {
            "0.2.0"
        }),
        samples.core_requests,
        c.items,
        c.profiles,
        json(if c.cold { "cold" } else { "warm" }),
        json(if c.cold { COLD } else { WARM }),
        usize::from(!c.cold),
        repetitions,
        samples.fields(),
        json(c.witness_name()),
        c.budget_ms,
        json(c.budget_type),
        profile,
        json(
            "Fixtures describe machines; only startup-check hello is native. Frontend render uses a fixed 120x40 TestBackend, including draw/diff/flush, not a physical terminal. Controller poll/IPC overhead is retained. No budgets graded; no physical qualification."
        )
    )
}

#[test]
#[ignore = "explicit bench/run only; never timing alongside the ordinary suite"]
fn measurement() {
    let mode = std::env::var("OMB_BENCH_MODE").expect("use bench/run");
    assert!(["list", "smoke", "full"].contains(&mode.as_str()));
    let path = PathBuf::from(std::env::var_os("OMB_BENCH_OUTPUT").expect("output"));
    let canonical_parent = path.parent().unwrap().canonicalize().unwrap();
    assert!(
        !canonical_parent.starts_with(root()),
        "output must be outside repository"
    );
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .unwrap();
    if mode == "list" {
        for c in cases() {
            writeln!(file, "{}", c.plan()).unwrap();
        }
        return;
    }
    assert!(
        !root().join("tests/.tmp").exists(),
        "timing must run separately from tests"
    );
    let (_, arch) = host();
    if mode == "full" {
        assert!(
            arch == "aarch64" || arch == "arm64",
            "full mode requires native arm64/aarch64"
        );
        assert_eq!(
            std::env::var("OMB_BENCH_FULL_ACK").as_deref(),
            Ok("measurement-preparation-no-signoff")
        );
    }
    let p = Provenance::new();
    p.validate().expect("required provenance");
    let reps = if mode == "smoke" { 3 } else { 200 };
    for c in cases().iter().filter(|c| native_case(c)) {
        assert!(p.source_unchanged(), "source commit changed before case");
        let (samples, identity) = run_case(c, reps, true);
        assert!(p.source_unchanged(), "source commit changed during case");
        writeln!(file, "{}", result(c, &samples, &identity, &p, &mode, reps)).unwrap();
        file.flush().unwrap();
        println!(
            "NON-AUTHORITATIVE {} {} {}: {} success / {} failures / {} timeouts",
            c.id,
            c.label,
            if c.cold { "cold" } else { "warm" },
            samples.raw.len(),
            samples.failed,
            samples.timeouts
        );
    }
    // Deterministic accounting witness, never hang a production command.
    let mut fake = Samples::default();
    fake.record(Ok(10));
    fake.record(Err("fake-invalid-work".into()));
    fake.record(Err("timeout".into()));
    writeln!(file, "{{\"schema\":{},\"kind\":\"fake-accounting-witness\",\"smoke\":{},\"o1_signoff\":false,{}}}", json(SCHEMA), mode == "smoke", fake.fields()).unwrap();
    for c in cases().iter().filter(|c| !native_case(c)) {
        writeln!(file, "{{\"schema\":{},\"benchmark_id\":{},\"operation_label\":{},\"required_platform\":{},\"required_architecture\":{},\"phase\":{},\"status\":\"NOT RUN\",\"reason\":\"native platform unavailable on this host\",\"smoke\":{},\"o1_signoff\":false}}",
            json(SCHEMA), json(c.id), json(&c.label), json(c.platform), json(c.arch), json(if c.cold { "cold" } else { "warm" }), mode == "smoke").unwrap();
    }
}

#[test]
fn percentile_small() {
    assert_eq!(nearest(&[3, 1, 2], 50), Some(2));
    assert_eq!(nearest(&[3, 1, 2], 95), Some(3));
}
#[test]
fn percentile_200() {
    let v = (1..=200).collect::<Vec<_>>();
    assert_eq!(
        (nearest(&v, 50), nearest(&v, 95), nearest(&v, 99)),
        (Some(100), Some(190), Some(198))
    );
}
#[test]
fn percentile_empty() {
    assert_eq!(nearest(&[], 95), None);
}
#[test]
fn percentile_equal() {
    assert_eq!(nearest(&[7; 200], 99), Some(7));
}
#[test]
fn slow_sample_retained() {
    let mut s = Samples::default();
    s.record(Ok(1));
    s.record(Ok(999999));
    assert_eq!(nearest(&s.raw, 95), Some(999999));
}
#[test]
fn failure_accounting() {
    let mut s = Samples::default();
    s.record(Err("refused".into()));
    assert_eq!((s.raw.len(), s.failed), (0, 1));
}
#[test]
fn timeout_accounting() {
    let mut s = Samples::default();
    s.record(Err("timeout".into()));
    assert_eq!((s.raw.len(), s.timeouts), (0, 1));
}
#[test]
fn small_counts() {
    let m = Loaded::new(50, 0);
    assert_eq!((m.items.len(), m.profiles.len()), (50, 0));
}
#[test]
fn representative_counts() {
    let m = Loaded::new(2000, 400);
    assert_eq!((m.items.len(), m.profiles.len()), (2000, 400));
}
#[test]
fn stable_model_digest() {
    assert_eq!(
        Loaded::new(2000, 400).digest(),
        Loaded::new(2000, 400).digest()
    );
}
#[test]
fn model_order_and_terms() {
    let m = Loaded::new(50, 0);
    assert_eq!(m.items[0].id, "item-0000");
    assert_eq!(m.items[49].id, "item-0049");
    assert_eq!(
        m.items
            .iter()
            .filter(|a| a.label.ends_with("match"))
            .count(),
        5
    );
}
#[test]
fn frontend_nav_render_no_requests() {
    let c = cases()
        .into_iter()
        .find(|c| c.id == "bench-nav" && c.items == 2000)
        .unwrap();
    let (s, _) = run_case(&c, 1, false);
    assert_eq!((s.raw.len(), s.failed), (1, 0));
}
#[test]
fn frontend_search_render_no_requests() {
    let c = cases()
        .into_iter()
        .find(|c| c.id == "bench-search" && c.items == 2000)
        .unwrap();
    let (s, _) = run_case(&c, 1, false);
    assert_eq!((s.raw.len(), s.failed), (1, 0));
}
#[test]
fn wrong_loaded_count_rejected() {
    let c = cases().into_iter().find(|c| c.id == "bench-nav").unwrap();
    let l = Loaded::new(0, 0);
    let mut m = l.model();
    let mut t = Terminal::new(TestBackend::new(120, 40)).unwrap();
    assert!(frontend_work(&c, &l, &mut m, &mut t).is_err());
}
#[test]
fn full_plan_counts() {
    assert_eq!(cases().len(), 102);
    assert!(
        cases()
            .iter()
            .all(|c| c.plan().contains("\"requested_repetitions\":200"))
    );
}
#[test]
fn platforms_truthful() {
    let all = cases();
    assert!(
        all.iter()
            .any(|c| c.platform == "linux" && c.arch == "aarch64")
    );
    assert!(
        all.iter()
            .any(|c| c.platform == "macos" && c.arch == "arm64")
    );
}
#[test]
fn phases_present() {
    for id in [
        "bench-nav",
        "bench-search",
        "bench-snapshot",
        "bench-validate",
        "bench-disk",
        "bench-journey-linux",
        "bench-health",
        "bench-logs",
    ] {
        assert!(cases().iter().any(|c| c.id == id && c.cold));
        assert!(cases().iter().any(|c| c.id == id && !c.cold));
    }
}
#[test]
fn warm_up_separate() {
    let c = cases().into_iter().find(|c| !c.cold).unwrap();
    assert!(c.plan().contains("\"warm_up_count\":1"));
}
#[test]
fn cold_no_warm_up() {
    let c = cases().into_iter().find(|c| c.cold).unwrap();
    assert!(c.plan().contains("\"warm_up_count\":0"));
}
#[test]
fn validate_classification() {
    let all = cases();
    assert!(
        all.iter().any(|c| c.id == "bench-disk"
            && c.label == "validate"
            && c.budget_type == "investigate")
    );
    assert!(
        all.iter()
            .filter(|c| c.id == "bench-disk" && c.label == "validate")
            .all(|c| c.witness_name().starts_with("complete-request-validator"))
    );
    assert!(
        all.iter()
            .filter(|c| c.id == "bench-validate")
            .all(|c| c.budget_ms == 300 && c.fixture() == "mac-m1pro-1tb-roomy")
    );
}
#[test]
fn paging_labels() {
    for kind in ["machine", "status"] {
        for limit in [1, 500] {
            assert!(
                cases()
                    .iter()
                    .any(|c| c.kind == kind && c.limit == limit && c.offset == 1)
            );
        }
    }
}
#[test]
fn logs_not_inflated() {
    assert_eq!(log_data().lines().count(), 47);
    assert!(
        cases()
            .iter()
            .filter(|c| c.id == "bench-logs")
            .all(|c| c.items == 0 && c.profiles == 0)
    );
}
#[test]
fn json_escapes() {
    assert_eq!(json("a\n\"\\\t"), "\"a\\n\\\"\\\\\\t\"");
}
#[test]
fn no_latency_budget_assertions() {
    let mut s = Samples::default();
    s.record(Ok(900000000000));
    assert_eq!(s.raw.len(), 1);
}
#[test]
fn raw_not_aggregate_percentiles() {
    assert_eq!(nearest(&[1, 1, 1, 200], 50), Some(1));
}
#[test]
fn schema_accounting() {
    let mut s = Samples::default();
    s.record(Ok(1));
    s.record(Err("timeout".into()));
    s.record(Err("invalid".into()));
    assert!(
        s.fields()
            .contains("\"outcomes\":[\"success\",\"timeout\",\"invalid\"]")
    );
}
#[test]
fn snapshot_launch_environment() {
    let c = cases()
        .into_iter()
        .find(|c| c.id == "bench-snapshot")
        .unwrap();
    let mut ctx = Context::new(&c);
    let (r, s) = ctx.prepare(&c, "", 0, 0);
    let cmd = ctx.command(&c, &r, &s, false);
    let envs = cmd.get_envs().collect::<Vec<_>>();
    assert!(
        !envs
            .iter()
            .any(|(k, v)| k.to_string_lossy().starts_with("OMB_TEST_") && v.is_some())
    );
    assert!(
        !envs
            .iter()
            .any(|(k, _)| *k == "OMB_FIXTURE" || *k == "OMB_FRONTEND_DEV")
    );
    assert_eq!(ctx.n, 1);
    assert!(!fs::read_to_string(r).unwrap().contains("op=hello"));
}
#[test]
fn production_attachment_and_witnesses() {
    // Correctness integration: no monotonic timing, no latency assertions.
    for c in cases().into_iter().filter(|c| {
        native_case(c)
            && c.cold
            && c.items == 0
            && (c.kind.is_empty() || (c.offset == 1 && c.limit == 500))
    }) {
        let mut ctx = Context::new(&c);
        let answer = ctx.request(&c, false);
        assert!(answer.is_ok(), "{} {}: {answer:?}", c.id, c.label);
    }
}
#[test]
fn snapshot_invalid_shapes_rejected() {
    let c = cases()
        .into_iter()
        .find(|c| c.id == "bench-snapshot")
        .unwrap();
    // An empty/refused canonical result is never meaningful work.
    let d = Document {
        op: Some(Op::Snapshot),
        records: vec![],
    };
    assert!(witness(&c, &d, b"").is_err());
}

fn fake_snapshot() -> (Case, Document, Vec<u8>) {
    let c = cases()
        .into_iter()
        .find(|c| c.id == "bench-snapshot")
        .unwrap();
    let (os, arch) = host();
    let make = |ty: &str, fields: &[(&str, &str)]| Record {
        ty: ty.into(),
        fields: fields
            .iter()
            .map(|(k, v)| (k.to_string(), v.as_bytes().to_vec()))
            .collect(),
    };
    let commit = git(&["rev-parse", "HEAD"]);
    let hello = make(
        "hello",
        &[
            ("proto", "1"),
            ("platform", os),
            ("arch", arch),
            ("ceiling", "read"),
            ("dry_run", "0"),
            ("fixture", "0"),
            ("commit", &commit),
            ("source", &executed_source_digest()),
        ],
    );
    let facts = [
        (
            "check",
            "Check",
            "frontend startup check (frontend-check)",
            "info",
        ),
        (
            "interface",
            "Interface",
            "frontend 0.1.0 as the lock pins, protocol 1",
            "ok",
        ),
        (
            "session",
            "Session",
            "read-only, journey scope only, not a dry run",
            "info",
        ),
        ("actions", "Actions", "none in this session", "info"),
    ]
    .map(|(k, l, v, s)| {
        make(
            "fact",
            &[
                ("scope", "journey"),
                ("key", k),
                ("label", l),
                ("value", v),
                ("state", s),
            ],
        )
    });
    let body = facts
        .iter()
        .map(|r| {
            let fields = r
                .fields
                .iter()
                .map(|(k, v)| (k.as_str(), v.as_slice()))
                .collect::<Vec<_>>();
            record::line("fact", &fields)
                .trim_end_matches('\n')
                .to_string()
        })
        .collect::<Vec<_>>()
        .join("\n");
    let generation = make(
        "generation",
        &[("id", &record::sha256_hex(body.as_bytes())), ("total", "0")],
    );
    let result = make(
        "result",
        &[
            ("status", "done"),
            ("code", "ok"),
            ("text", ""),
            ("next", ""),
        ],
    );
    let mut rows = vec![hello, generation];
    rows.extend(facts);
    rows.push(result);
    (
        c,
        Document {
            op: Some(Op::Snapshot),
            records: rows,
        },
        format!("{body}\n").into_bytes(),
    )
}
#[test]
fn four_facts_total_zero_is_work() {
    let (c, d, b) = fake_snapshot();
    assert!(witness(&c, &d, &b).is_ok());
}
#[test]
fn refused_total_zero_is_not_work() {
    let (c, mut d, b) = fake_snapshot();
    d.records.last_mut().unwrap().fields[0].1 = b"refused".to_vec();
    assert!(witness(&c, &d, &b).is_err());
}
#[test]
fn wrong_fixture_flag_rejected() {
    let (c, mut d, b) = fake_snapshot();
    d.records[0]
        .fields
        .iter_mut()
        .find(|(k, _)| k == "fixture")
        .unwrap()
        .1 = b"1".to_vec();
    assert!(witness(&c, &d, &b).is_err());
}
#[test]
fn wrong_fact_count_rejected() {
    let (c, mut d, b) = fake_snapshot();
    d.records.remove(2);
    assert!(witness(&c, &d, &b).is_err());
}
#[test]
fn wrong_fact_order_rejected() {
    let (c, mut d, b) = fake_snapshot();
    d.records.swap(2, 3);
    assert!(witness(&c, &d, &b).is_err());
}
#[test]
fn wrong_generation_rejected() {
    let (c, mut d, b) = fake_snapshot();
    d.records[1].fields[0].1 = b"0".repeat(64);
    assert!(witness(&c, &d, &b).is_err());
}
#[test]
fn extra_record_rejected() {
    let (c, mut d, b) = fake_snapshot();
    d.records.insert(
        6,
        Record {
            ty: "row".into(),
            fields: vec![],
        },
    );
    assert!(witness(&c, &d, &b).is_err());
}
#[test]
fn malformed_transport_rejected() {
    assert!(record::admit(Family::Res, Some(Op::Snapshot), b"omb-res 1\nhello").is_err());
}
#[test]
fn complete_without_result_rejected() {
    let (c, mut d, b) = fake_snapshot();
    d.records.pop();
    assert!(witness(&c, &d, &b).is_err());
}
#[test]
fn double_result_rejected() {
    let (c, mut d, b) = fake_snapshot();
    d.records.push(d.records.last().unwrap().clone());
    assert!(witness(&c, &d, &b).is_err());
}
#[test]
fn bad_hello_rejected() {
    let (c, mut d, b) = fake_snapshot();
    d.records[0].fields[0].1 = b"2".to_vec();
    assert!(witness(&c, &d, &b).is_err());
}
#[test]
fn warm_navigation_keeps_visible_target() {
    let c = cases()
        .into_iter()
        .find(|c| c.id == "bench-nav" && c.items == 2000 && !c.cold)
        .unwrap();
    let (s, _) = run_case(&c, 201, false);
    assert_eq!((s.raw.len(), s.failed), (201, 0));
}
#[test]
fn no_sample_without_valid_work() {
    let (c, d, b) = fake_snapshot();
    let mut s = Samples::default();
    let mut bad = d;
    bad.records.clear();
    s.record(witness(&c, &bad, &b).map(|()| 1));
    assert_eq!((s.raw.len(), s.failed), (0, 1));
}
#[test]
fn provenance_fields_present() {
    let p = Provenance {
        sha: "s".into(),
        lock: "l".into(),
        frontend: "f".into(),
        harness: "h".into(),
        bash: "3.2".into(),
        machine: "test".into(),
        system: "fixed".into(),
        runner: "fake-fixed".into(),
    };
    let f = p.fields();
    for name in [
        "source_git_sha",
        "production_lock_digest",
        "frontend_candidate_inputs_digest",
        "harness_digest",
        "os",
        "architecture",
        "machine_label",
        "bash_version",
    ] {
        assert!(f.contains(name));
    }
}
#[test]
fn smoke_result_not_signoff() {
    let c = cases().into_iter().find(|c| c.id == "bench-nav").unwrap();
    let p = Provenance {
        sha: "s".into(),
        lock: "l".into(),
        frontend: "f".into(),
        harness: "h".into(),
        bash: "3.2".into(),
        machine: "test".into(),
        system: "fixed".into(),
        runner: "fake-fixed".into(),
    };
    let mut s = Samples::default();
    s.record(Ok(5));
    s.record(Err("timeout".into()));
    let j = result(&c, &s, "fixed", &p, "smoke", 3);
    assert!(j.contains("\"smoke\":true"));
    assert!(j.contains("\"o1_signoff\":false"));
    assert!(j.contains("\"budget_verdict\":\"not_graded\""));
}

#[test]
fn frontend_worker_transport_correctness() {
    let c = cases()
        .into_iter()
        .find(|c| c.id == "bench-nav" && c.items == 2000)
        .unwrap();
    let mut worker = FrontWorker::new(&c).unwrap();
    assert_eq!(worker.request(false).unwrap(), 0);
    assert!(worker.last_witness.contains("core-requests=0"));
}
#[test]
fn page_cold_session_has_no_prior_request() {
    let c = cases()
        .into_iter()
        .find(|c| native_case(c) && c.kind == "machine" && c.cold)
        .unwrap();
    let ctx = Context::new(&c);
    assert_eq!(ctx.n, 0);
    assert_eq!(ctx.setup_requests, 2);
    assert!(fs::read_dir(&ctx.session).unwrap().next().is_none());
    assert_eq!(ctx.generation.len(), 64);
    assert_eq!(ctx.projection.as_ref().unwrap().len(), 6);
}

#[test]
fn exact_pages_reject_changed_rows_and_generation() {
    for kind in ["machine", "status", "doctor", "log"] {
        let c = cases()
            .into_iter()
            .find(|c| native_case(c) && c.kind == kind && c.cold && c.offset == 1 && c.limit == 500)
            .unwrap();
        let mut ctx = Context::new(&c);
        let (_, page) = ctx.request(&c, false).unwrap();
        let projection = ctx.projection.as_ref().unwrap();
        assert!(page_witness(&c, &page, &ctx.generation, projection).is_ok());
        let mut changed = page.clone();
        let row = changed.records.iter_mut().find(|r| r.ty == "row").unwrap();
        row.fields.iter_mut().find(|(k, _)| k == "key").unwrap().1 = b"wrong-row".to_vec();
        assert!(page_witness(&c, &changed, &ctx.generation, projection).is_err());
        let mut changed = page.clone();
        let row = changed.records.iter_mut().find(|r| r.ty == "row").unwrap();
        row.fields.iter_mut().find(|(k, _)| k == "col").unwrap().1 = b"wrong-value".to_vec();
        assert!(page_witness(&c, &changed, &ctx.generation, projection).is_err());
        let mut changed = page.clone();
        let rows = changed
            .records
            .iter()
            .enumerate()
            .filter(|(_, r)| r.ty == "row")
            .map(|(i, _)| i)
            .collect::<Vec<_>>();
        changed.records.swap(rows[0], rows[1]);
        assert!(page_witness(&c, &changed, &ctx.generation, projection).is_err());
        let mut changed = page.clone();
        changed
            .records
            .iter_mut()
            .find(|r| r.ty == "generation")
            .unwrap()
            .fields
            .iter_mut()
            .find(|(k, _)| k == "id")
            .unwrap()
            .1 = b"0".repeat(64);
        assert!(page_witness(&c, &changed, &ctx.generation, projection).is_err());
        let wrong_offset = Case {
            offset: 0,
            ..c.clone()
        };
        assert!(page_witness(&wrong_offset, &page, &ctx.generation, projection).is_err());
    }
}
#[test]
fn persistent_effect_is_detectable() {
    let c = cases()[0].clone();
    let ctx = Context::new(&c);
    fs::create_dir(ctx.dir.join("state")).unwrap();
    private(&ctx.dir.join("state/changed"), b"synthetic test value");
    assert_ne!(ctx.before, tree_digest(&ctx.dir.join("state")));
}

#[test]
fn wrong_executed_source_rejected() {
    let (c, mut d, b) = fake_snapshot();
    d.records[0]
        .fields
        .iter_mut()
        .find(|(k, _)| k == "source")
        .unwrap()
        .1 = b"b".repeat(64);
    assert!(witness(&c, &d, &b).is_err());
}

#[test]
fn single_sample_percentiles_and_maximum() {
    let mut s = Samples::default();
    s.record(Ok(17));
    for p in [50, 95, 99] {
        assert_eq!(nearest(&s.raw, p), Some(17));
    }
    assert!(s.fields().contains("\"maximum\":17"));
}
#[test]
fn exact_budget_vocabulary() {
    for c in cases() {
        let expected = match c.id {
            "bench-nav" => (50, "hard"),
            "bench-search" => (100, "hard"),
            "bench-validate" => (300, "hard"),
            "bench-snapshot" | "bench-logs" | "bench-journey-linux" => (500, "hard"),
            "bench-disk" | "bench-health" => (2000, "investigate"),
            _ => panic!("unknown benchmark id"),
        };
        assert_eq!((c.budget_ms, c.budget_type), expected);
    }
}
#[test]
fn missing_provenance_refused() {
    let mut p = Provenance {
        sha: "s".into(),
        lock: "l".into(),
        frontend: "f".into(),
        harness: "h".into(),
        bash: "b".into(),
        machine: "m".into(),
        system: "o".into(),
        runner: "r".into(),
    };
    assert!(p.validate().is_ok());
    p.runner.clear();
    assert!(p.validate().is_err());
    p.runner = "r".into();
    p.sha.clear();
    assert!(p.validate().is_err());
}
#[test]
fn linux_unavailable_validate_is_invalid() {
    let mut c = cases()
        .into_iter()
        .find(|c| c.id == "bench-validate")
        .unwrap();
    c.platform = "linux";
    let (_, mut d, bytes) = fake_snapshot();
    let result = d.records.last_mut().unwrap();
    for (key, value) in &mut result.fields {
        if key == "status" {
            *value = b"refused".to_vec();
        }
        if key == "code" {
            *value = b"unavailable".to_vec();
        }
    }
    let mut s = Samples::default();
    s.record(witness(&c, &d, &bytes).map(|()| 1));
    assert_eq!((s.raw.len(), s.failed), (0, 1));
}

#[test]
fn owned_child_group_is_reaped() {
    let mut child = Command::new(bash())
        .args(["-c", "IFS= read -r command"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .unwrap();
    terminate(&mut child);
    assert!(!child.try_wait().unwrap().unwrap().success());
}

#[test]
fn changed_source_commit_refused() {
    let mut p = Provenance {
        sha: "1".repeat(40),
        lock: "l".into(),
        frontend: "f".into(),
        harness: "h".into(),
        bash: "b".into(),
        machine: "m".into(),
        system: "o".into(),
        runner: "r".into(),
    };
    let current = "1".repeat(40);
    assert!(p.matches_sources(&current, true));
    assert!(!p.matches_sources(&current, false));
    p.sha = "0".repeat(40);
    assert!(!p.matches_sources(&current, true));
}

// Fixed synthetic clock values below are not product latency.
fn synthetic_boundaries(c: &Case) -> Vec<Boundary> {
    phase_markers(c)
        .iter()
        .enumerate()
        .map(|(n, name)| Boundary {
            name: (*name).into(),
            ns: Some((n * 10) as u64),
        })
        .collect()
}
#[test]
fn phase_family_applicability() {
    let all = cases();
    for c in &all {
        let a = phase_applicable(c);
        assert_eq!(a[0], c.items == 0 && c.id != "bench-validate");
        assert_eq!(a[1], a[0]);
        assert_eq!(a[2], a[0] && c.id != "bench-snapshot");
        assert_eq!(a[3], c.id == "bench-disk" && c.label == "validate");
    }
    assert_eq!(all.len(), 102);
    assert_eq!(all.iter().filter(|c| c.platform == "macos").count(), 52);
    assert_eq!(all.iter().filter(|c| c.platform == "linux").count(), 50);
    assert_eq!(all.iter().filter(|c| c.cold).count(), 51);
}
#[test]
fn phase_boundaries_reject_missing_duplicate_reordered_and_backward() {
    for c in cases().into_iter().filter(|c| phase_applicable(c)[0]) {
        let good = synthetic_boundaries(&c);
        assert!(phase_durations(&c, &good).is_ok());
        for index in 0..good.len() {
            let mut bad = good.clone();
            bad.remove(index);
            assert!(phase_durations(&c, &bad).is_err());
            let mut bad = good.clone();
            bad.insert(index, good[index].clone());
            assert!(phase_durations(&c, &bad).is_err());
        }
        let mut bad = good.clone();
        bad.swap(1, 2);
        assert!(phase_durations(&c, &bad).is_err());
        let mut bad = good.clone();
        bad[2].ns = Some(1);
        assert!(phase_durations(&c, &bad).is_err());
        let mut bad = good.clone();
        bad[2].ns = None;
        assert!(phase_durations(&c, &bad).is_err());
    }
}
#[test]
fn phase_zero_na_empty_failure_timeout_and_statistics() {
    let c = cases()
        .into_iter()
        .find(|c| c.id == "bench-snapshot")
        .unwrap();
    let mut p = PhaseProfile::default();
    let empty = p.fields(&c, 3);
    assert!(empty.contains("\"state\":\"unavailable\""));
    assert!(empty.contains("\"state\":\"not_applicable\""));
    assert!(!empty.contains("\"p50\":0"));
    for duration in [200, 0, 1, 10] {
        let mut b = synthetic_boundaries(&c);
        b[1].ns = Some(duration);
        b[2].ns = Some(duration * 2);
        b[3].ns = Some(duration * 3);
        p.record(
            &c,
            Ok(PhaseObservation {
                boundaries: b,
                binding: format!("case-{duration}"),
                response_digest: "response".into(),
                copy_digest: "copy".into(),
                driver_digest: "driver".into(),
                request_identity: "synthetic-request".into(),
                request_digest: "synthetic-digest".into(),
            }),
        );
    }
    assert_eq!(p.phases[0].raw, vec![200, 0, 1, 10]);
    assert_eq!(nearest(&p.phases[0].raw, 50), Some(1));
    assert_eq!(nearest(&p.phases[0].raw, 95), Some(200));
    assert_eq!(nearest(&p.phases[0].raw, 99), Some(200));
    assert!(p.fields(&c, 4).contains("\"maximum\":200"));
    p.failure(&c, "invalid".into());
    p.failure(&c, "timeout".into());
    assert_eq!((p.phases[0].failed, p.phases[0].timeouts), (1, 1));
    assert!(p.phases[2].raw.is_empty());
    assert!(
        !p.fields(&c, 6)
            .contains("\"required_evidence_complete\":true")
    );
    let mut zero = synthetic_boundaries(&c);
    for b in &mut zero {
        b.ns = Some(0);
    }
    assert_eq!(phase_durations(&c, &zero).unwrap(), Some([0; 4]));
}
#[test]
fn phase_anchor_integrity_and_identity() {
    let mut missing = "".into();
    assert!(replace_anchor(&mut missing, "anchor", "hook", 1).is_err());
    let mut duplicate = "anchor anchor".into();
    assert!(replace_anchor(&mut duplicate, "anchor", "hook", 1).is_err());
    let sources = phase_sources().unwrap();
    let digest = phase_copy_digest(&sources);
    assert_eq!(sources.len(), 6);
    assert_eq!(digest.len(), 64);
    let mut changed = sources.clone();
    changed[0].1.push_str("\n# changed\n");
    assert_ne!(phase_copy_digest(&changed), digest);
    for (name, source) in sources {
        let child = Command::new(bash())
            .arg("-n")
            .stdin(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut child = child;
        child
            .stdin
            .take()
            .unwrap()
            .write_all(source.as_bytes())
            .unwrap();
        let result = child.wait_with_output().unwrap();
        assert!(result.status.success(), "{name}: {:?}", result.stderr);
    }
}
fn selected_probes(path: &Path) -> Vec<String> {
    String::from_utf8_lossy(&fs::read(path).unwrap())
        .lines()
        .filter_map(|line| {
            let call = line.trim_start_matches('+').trim_start();
            [
                "sys_cmd ",
                "sys_path ",
                "sys_has ",
                "sys_net ",
                "sys_reachable ",
            ]
            .iter()
            .any(|prefix| call.starts_with(prefix))
            .then(|| call.to_string())
        })
        .collect()
}
#[test]
fn phase_production_equivalence_boundaries_probes_and_no_latency() {
    // Native hosts cover every complete-core case. Other host architectures
    // execute their platform fixtures as correctness proof, never native latency.
    for c in cases().into_iter().filter(|c| {
        phase_applicable(c)[0]
            && (native_case(c) || (c.platform == host().0 && c.id != "bench-snapshot"))
    }) {
        let mut ctx = Context::new(&c);
        ctx.proof_trace = true;
        let (_, ordinary) = ctx.request(&c, false).unwrap();
        let probes = selected_probes(&ctx.dir.join("stderr"));
        assert!(!probes.is_empty()); // startup identity reads also count
        let o = ctx
            .phase_request(&c, &ordinary, false)
            .unwrap_or_else(|e| panic!("{}: {e}", c.label));
        assert_eq!(
            selected_probes(&ctx.dir.join("phase-stderr")),
            probes,
            "{}",
            c.label
        );
        assert_eq!(phase_durations(&c, &o.boundaries).unwrap(), None);
        assert!(o.boundaries.iter().all(|b| b.ns.is_none()));
        assert_eq!(
            o.boundaries
                .iter()
                .map(|b| b.name.as_str())
                .collect::<Vec<_>>(),
            phase_markers(&c)
        );
        assert_eq!(o.copy_digest, phase_copy_digest(&phase_sources().unwrap()));
        assert_eq!(
            o.driver_digest,
            digest_file(&root().join("bench/phases.sh"))
        );
        assert_eq!(tree_digest(&ctx.dir.join("state")), ctx.before);
    }
}
#[test]
fn phase_live_negative_controls() {
    let c = cases()
        .into_iter()
        .find(|c| {
            c.platform == host().0
                && phase_applicable(c)[2]
                && c.scope == "journey"
                && c.kind.is_empty()
                && c.id != "bench-snapshot"
        })
        .unwrap();
    let base = phase_sources().unwrap();
    for replacement in [
        "",
        "bench_phase_mark admission_start\n",
        "OMB_BENCH_BINDING=wrong\nbench_phase_mark admission_end\n",
        "exit 0\n",
    ] {
        let mut ctx = Context::new(&c);
        let (_, ordinary) = ctx.request(&c, false).unwrap();
        let mut bad = base.clone();
        let core = bad.iter_mut().find(|(n, _)| n == "core.sh").unwrap();
        core.1 = core
            .1
            .replace("        bench_phase_mark admission_end\n", replacement);
        assert!(ctx.phase_request_using(&c, &ordinary, false, bad).is_err());
    }
    let mut ctx = Context::new(&c);
    let (_, ordinary) = ctx.request(&c, false).unwrap();
    let mut wrong = ordinary.clone();
    wrong.records.last_mut().unwrap().fields[0].1 = b"refused".to_vec();
    assert!(same_response(&wrong, &ordinary).is_err());
    assert!(
        ctx.phase_request(&c, &wrong, false)
            .unwrap_err()
            .contains("equivalence")
    );
    // A copy mutation after the observed work cannot pass identity admission.
    let mut ctx = Context::new(&c);
    let (_, ordinary) = ctx.request(&c, false).unwrap();
    let mut bad = base.clone();
    bad[0].1 = bad[0].1.replace(
        "bench_phase_mark complete\n",
        "printf '# tampered\\n' >>\"$OMB_BENCH_COPY/core.sh\"\nbench_phase_mark complete\n",
    );
    assert!(
        ctx.phase_request_using(&c, &ordinary, false, bad)
            .unwrap_err()
            .contains("identity")
    );
}
#[test]
fn phase_total_population_stays_separate() {
    let c = cases()
        .into_iter()
        .find(|c| c.id == "bench-disk" && c.label == "validate")
        .unwrap();
    let mut total = Samples::default();
    total.record(Ok(999));
    let mut profile = PhaseProfile::default();
    profile.failure(&c, "timeout".into());
    total.profile = Some(Box::new(profile));
    assert_eq!(total.raw, vec![999]);
    assert_eq!(total.timeouts, 0);
    assert_eq!(total.profile.as_ref().unwrap().phases[3].timeouts, 1);
    assert_eq!(
        phase_durations(&c, &synthetic_boundaries(&c)).unwrap(),
        Some([10, 10, 10, 10])
    );
}

#[test]
fn phase_cold_companions_keep_matching_private_contexts() {
    let selected = cases()
        .into_iter()
        .filter(|c| {
            c.platform == host().0
                && c.cold
                && phase_applicable(c)[2]
                && (c.scope == "journey" || c.scope == "logs")
                && (c.kind.is_empty() || (c.offset == 0 && c.limit == 1))
        })
        .collect::<Vec<_>>();
    assert!(!selected.is_empty());
    for c in selected {
        // Exercise the actual multi-sample collector with all product clocks
        // disabled. Successful companions reach the explicit no-clock outcome;
        // an incorrect private input context instead fails semantic equality.
        let (samples, _) = run_case_observed(&c, 3, false, true);
        assert_eq!(samples.raw, vec![0; 3], "{}", c.label);
        assert_eq!((samples.failed, samples.timeouts), (0, 0));
        let profile = samples.profile.unwrap();
        assert_eq!(profile.core_requests, 3);
        assert_eq!(profile.warm_up_requests, 0);
        assert!(profile.observations.is_empty());
        for (phase, applicable) in profile.phases.iter().zip(phase_applicable(&c)) {
            assert!(phase.raw.is_empty());
            if applicable {
                assert_eq!(phase.failed, 3);
                assert_eq!(phase.timeouts, 0);
                assert_eq!(
                    phase.outcomes,
                    vec!["no latency clock in deterministic proof"; 3],
                    "{}",
                    c.label
                );
            } else {
                assert!(phase.outcomes.is_empty());
            }
        }
    }
}

#[test]
fn phase_live_timeout_is_accounted_and_reaped() {
    let c = cases()
        .into_iter()
        .find(|c| {
            c.platform == host().0
                && phase_applicable(c)[2]
                && c.scope == "journey"
                && c.kind.is_empty()
                && c.id != "bench-snapshot"
        })
        .unwrap();
    let mut ctx = Context::new(&c);
    let (_, ordinary) = ctx.request(&c, false).unwrap();
    ctx.phase_timeout = Duration::from_millis(20);
    let mut sources = phase_sources().unwrap();
    sources[0].1 = sources[0].1.replace("set -u\n", "set -u\nsleep 60\n");
    let e = ctx
        .phase_request_using(&c, &ordinary, false, sources)
        .unwrap_err();
    assert_eq!(e, "timeout");
    assert_eq!(ctx.phase_launches, 1);
    let mut profile = PhaseProfile::default();
    profile.failure(&c, e);
    assert_eq!(profile.phases[0].timeouts, 1);
    assert!(profile.phases[0].raw.is_empty());
}
