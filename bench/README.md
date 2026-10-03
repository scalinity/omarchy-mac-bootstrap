# M14 Gate 2 measurement preparation

Harness candidate, pending independent review. Q5 = RESOLVED FOR MEASUREMENT;
O1 SIGNOFF = PENDING. No authoritative O1 run was accepted or claimed. Every
result is NON-AUTHORITATIVE; budgets are ungraded.

```bash
bench/run --list /absolute/external/plan.jsonl
bench/run --smoke /absolute/external/smoke.jsonl
# Future capability only; this slice does not authorize execution:
bench/run --full --ack-o1-preparation /absolute/external/full.jsonl
```

There is no default measurement. Output must be external and nonexistent.
Finish all tests before smoke. Timing refuses existing tests/.tmp; this is a
conservative scratch interlock, not general process discovery. No other jobs
are inspected or killed. `OMB_BENCH_BASH` selects the controller's interpreter;
`OMB_BENCH_MACHINE_LABEL` supplies a machine label. Core children receive a
cleared environment, including no inherited OMB_TEST_* variables.
Timing requires committed, clean benchmark/source inputs; unrelated reference
images remain outside that check. A Git-head or input change during a case stops output
publication for that case, preserving earlier records without misattribution.
Cargo target output defaults outside the repository. Release-profile test compilation is
excluded from measured intervals. Benchmark release tests use the explicit
`CARGO_PROFILE_RELEASE_STRIP=none` override and retain symbols: stock stripped
proc-macro compilation returned E0463 on this Mac, including in a fresh target;
unstripped compilation passed. Production Cargo configuration is unchanged.
Result metadata records this test-only override. No dependencies were added.

## Future matrix

List mode generates 102 cases without latency samples: macOS arm64 has 26
cases per phase, Linux aarch64 has 25. Every case has cold/warm phases and 200
requested repetitions. For each platform/phase:

| Family | Operations/workload | Cases | Budget |
| --- | --- | ---: | --- |
| bench-snapshot | frontend-check.snapshot, exactly four facts | 1 | hard p95 < 500 ms |
| bench-nav | 50 items/0 profiles; 2,000 items/400 profiles | 2 | hard p95 < 50 ms |
| bench-search | same two loaded models | 2 | hard p95 < 100 ms |
| bench-validate | loaded macOS capture, 250GB Linux/10GB Shared | 1 | hard p95 < 300 ms |
| bench-disk (macOS) / bench-journey-linux | Journey snapshot; machine/status details: offsets 0/1 x limits 1/500 | 9 | macOS investigate > 2 s; Linux hard < 500 ms |
| bench-disk (macOS only) | complete Validate, label validate | 1 | investigate > 2 s |
| bench-health | snapshot; Doctor details: offsets 0/1 x limits 1/500 | 5 | investigate > 2 s |
| bench-logs | snapshot; log details: offsets 0/1 x limits 1/500 | 5 | hard p95 < 500 ms |

The four-fact startup snapshot does not substitute for the loaded models.
Smoke runs host-eligible cases with three repetitions, listing unavailable
cases as NOT RUN. Full execution requires explicit acknowledgement and native
arm64, but its output still confers no signoff authority.

## Real work and boundaries

Complete core requests invoke the actual entrypoint. Rust Instant starts
immediately before spawn and ends after exit observation and reap. Preparation
of session/request/header-spool and independent response verification are
excluded. The 1 ms exit-status polling interval adds controller overhead inside
the interval. Deadline enforcement is 30 seconds. Only the process group this
controller creates is terminated on timeout, then reaped and its reader joined.

bench-snapshot follows the independent ruling in docs/TESTING.md: fixture-free
frontend-check, read/journey, dry=0, request frontend=0.1.0, no frontend executable.
Cold's first core request is the measured snapshot. Warm has one verified
untimed snapshot then fresh Bash requests in the same session. Require exact
native hello identity, four ordered facts, generation total=0 with SHA-256 of
canonical fact lines joined with LF without trailing LF, and final done/ok.
Filesystem/source-hash/lock I/O remains included; no storage survey is requested.

Ordinary families use mac-m1pro-1tb-roomy or linux-alarm-fresh in read-only
development fixture sessions. Paging obtains a snapshot generation and full
projection in a separate preparation session, then creates a fresh measured
session whose first request is detail. Both setup requests are counted and
excluded. Each page must match the requested generation and the exact ordered
slice of all prepared row fields, including keys and column values. The
reference is an untimed real-producer projection, not an independent product
oracle. Warm uses one
verified untimed equivalent request. Machine/status totals are 6/9 on macOS,
6/5 on Linux; Doctor totals are 14/16. Pages must have exact nonzero counts.
Health uses the real Doctor owner including fixture network checks. Logs uses
synthetic writer-format files outside the checkout: 47 lines in selected 001
and a decoy 000. Real selection/tail-40 and exact line-008..047 subwindows are
required. Persistent state and source logs must remain unchanged.

bench-validate calls unchanged core_validate_op over authoritative loaded
globals. macos-capture.env is frozen mac_detect output over the ordinary
mac-m1pro-1tb-roomy fixture under stock Mac Bash: MAC_*, GEO_* and DEV_* only,
never precomputed PLAN_*. Regenerate in a subshell by sourcing
common/ui/state/sources/storage/macos/asahi/shared/linux/doctor/dev, setting
OMB_FIXTURE to that fixture, OMB_INTENT=read and OMB_PERSIST=0, running
mac_detect, then emitting declare -p for those prefixes from compgen -v in C
byte order. These are synthetic fixture values, not native machine evidence.

Only this benchmark shell replaces mac_detect with the loaded capture callback
and wraps actual accepted function bodies with call-witness recording. All
probe helpers refuse after setup. Parsing, trimming, plan_init/compute/validate/
layout/verify, Q4 basis, response preparation and producer admission remain
real calls, not duplicated algorithms. The component interval is send-go
through completion-marker receipt, including IPC/call-witness overhead.
Library startup, request admission, hello and probe acquisition are excluded;
cleanup/reap and independent canonical response check follow the interval.
Complete macOS bench-disk/validate separately includes startup and probes.
Linux component metadata says native_probe=false; unavailable refusal is invalid.

Frontend workers use public Model/Snapshot/Action/update/screens APIs. Distinct
synthetic items and profiles become Action entries in a combined render model,
without a new product schema. Navigation uses real update with alternating
Down/Up at visible focus 0/1. Benchmark-only search filters all original inputs
to 5 or 240 matches. Both include real draw/diff/flush through fixed 120x40
ASCII/no-color TestBackend. Witness: exact loaded counts/digest, visible focused
item, resulting frame hash and zero core commands/requests. Physical terminal
transport is excluded. Cold recreates worker/model; warm uses one verified
untimed operation then the same loaded worker/model, never a cached response.

## Accounting and tests

JSON Lines schema: omb-benchmark-1. Successful samples are integer nanoseconds
in collection order, including slow samples. Percentiles sort a copy and use
nearest rank ceil(p*N/100)-1; maximum is the largest sample. Empty populations
have null statistics. Failures, refusals, invalid witnesses and timeouts carry
separate outcomes and no latency. Warm-ups are separate. Counts distinguish
setup requests, complete core requests and component launches. The explicitly
marked fake-accounting witness is not real latency.

Provenance includes Git SHA, independently checked executed source digest,
production lock/release, unreleased frontend candidate input digest, fixture/
capture/workload digests, harness digest, exact test executable digest,
profile/toolchain config, OS/native arch/system, machine label and Bash version.
Frontend request version is separate from frontend_executable_run=false.
Canonical and semantic response verification follows timing. No budgets are
graded, and investigation thresholds are not hard failure gates.

Normal CI discovers Bash contracts and non-ignored benchmark::* tests through
the existing frontend contract target. measurement and frontend_worker are
ignored explicit entry points. Normal tests collect no latency samples;
monotonic deadlines in transport tests enforce liveness only.
The pre-existing contract runs in its own single-test child process because
it mutates process-wide environment variables and descriptor flags. This
preserves its original isolation while benchmark tests run concurrently.
Invalid completed results retain status/code/text in the failure diagnostic;
refusals remain excluded from successful samples.

Fail-first at accepted V: its Git tree had no benchmark artifacts; the new
artifact test reported 0 passed, 4 failed, 0 skipped, exit 1. This missing-harness
evidence is distinct from the earlier semantic STOP and independent resolution.
Neither was a product regression.

## BENCH-M01 diagnostic internal observations

Independent review of B `6129d07bd6cf04a4fd9a98773231677fb1473375`
returned **BENCHMARK HARNESS REMEDIATION REQUIRED** for exactly one blocker:
**BENCH-M01 — Required core timing decomposition is absent**. Its other
methodology was credited. This forward remediation is a candidate awaiting
**BENCH-M01 CLOSURE / FINAL BENCHMARK-INSTRUMENT ACCEPTANCE REVIEW** of B through
the final candidate, using the completed V-to-B assessment as integration base.
BENCH-M01 is not self-closed; the harness remains UNACCEPTED and O1 PENDING.
If independently closed with no new concrete blocker, the expected next action
is directly **O1 AUTHORITATIVE MEASUREMENT CAMPAIGN / SIGNOFF-EVIDENCE COLLECTION
ONLY**, under its own authorization. This slice runs only a fresh bounded,
NON-AUTHORITATIVE smoke after commit/clean tree and final validation.

The whole-request stopwatch and all existing budgets are unchanged: ordinary
requests execute the real checkout, from immediately before fresh Bash spawn
through observed exit/reap. Only after that case's entire ordinary population
is collected does a separate companion population run. It shares fixture,
inputs and prepared projection, with its own fresh cold session or warm session
following one verified untimed ordinary request. Each observed response must
be exactly equal to its ordinary reference, including hello/source, generation,
rows, result, Validate answers and Q4 basis. These are independent executions;
phase values cannot be added to reconstruct an ordinary total or correlated as
the same execution. No total/component subtraction, overhead correction or
phase budget exists.

Rust generates six temporary files in controller-owned external scratch from
exact candidate entry/core/read/health/logs/validate bytes. Each declared anchor
must occur its exact expected number of times; missing/duplicated anchors fail.
Reversing only the declared replacements must reproduce the complete original
bytes. Path shims keep OMB_HOME pointing at the real checkout and redirect only
the copied libraries; all other libraries/data/lock/fixtures remain ordinary.
The copy manifest hashes relative names and full copied bytes. The driver
`bench/phases.sh` has a separate SHA-256. No product file or Protocol schema is
edited. The companion hello names the base executed-source identity, while the
benchmark record separately identifies the transformation and copy digest.

The driver sends `<request-binding> TAB <boundary> LF` on private fd 4 and waits
for an `observed` acknowledgement on fd 5. Rust records monotonic **receipt**
timestamps before acknowledging. This synchronizes each boundary; it is not a
Bash timestamp or an estimated residual. Ordinary stdout stays discarded,
observation output never enters the response spool, and fd 3 still carries the
production request and closes through the ordinary entrypoint. Required marker
order, binding and completeness are checked before response/effect admission.
Extra, missing, reordered, wrong-case/request, nonmonotonic, incomplete or
semantically unequal observations fail. Only the owned process group is killed
on a deadline, then reaped and its reader joined. The companion has a 30-second
boundary/reap deadline; setup and post-reap verification are outside it.

| Component | Start observation | End observation | Included work and applicability |
| --- | --- | --- | --- |
| startup | Rust immediately before companion Bash spawn | hook immediately after core_main's exact `# 1. Admission, byte by byte...` comment, before the hst/copy check | All complete core families: Bash/entry request copying, library loading, platform/session/environment/identity/source setup and hello; excludes controller preparation. |
| admission | same admission-start receipt | hook immediately before the selected producer: core_check_snapshot, Journey snapshot/detail dispatch, core_health_op, core_logs_op or core_validate_op | All complete core families: rec_admit_copied, field extraction, protocol/frontend checks, ordinary-session dispatch, selected family/platform/fixture/scope gates and needed read-library loading. Excludes operation-specific owner work and Rust response admission. |
| probes (Journey) | immediately before cmd_status in core_journey_dataset | immediately after its successful return | Complete Journey snapshot and machine/status pages: one authoritative status-owner call, including its detector, saved-state reads, calculations and presentation callbacks. This is an inclusive owner acquisition interval, not just subprocess time. Dataset projection/admission/hash/publication follows outside it. |
| probes (Health) | immediately before cmd_doctor in core_health_doctor | immediately after capturing its status in __st | Complete Health snapshot/Doctor pages: one authoritative Doctor-owner call, including detector, network checks, owner calculations and finding callbacks; excludes later tally/admission/hash/page work. |
| probes (Logs) | immediately before directory=log_dir in core_logs_capture | immediately before initializing logs.rows after source selection and core_logs_window | Complete Logs snapshot/pages: authoritative directory/path classification, find/sort/selection and selected bounded tail window, including window byte checks; excludes row parsing, response admission/hash/page/publication. |
| probes (Validate) | immediately before mac_detect in core_validate_context | immediately after its return | Complete macOS bench-disk/validate: actual survey owner, its accepted plist helper and geometry acquisition; excludes all following planning/computation. |
| validation_computation | next hook after Validate probe-end, before mac_plan_compute 0 | hook after core_validate_op returns, preserving that return status | Complete macOS Validate only: context/planning gates, parse_size/normalization, plan_init/compute/validate/layout/verify, answers, Q4 basis, response preparation/admission/publication. Cleanup follows outside it. |

startup/admission apply to all complete core cases. probes is explicitly
not_applicable for the four-fact bench-snapshot; its identity reads stay in
startup. validation_computation is not_applicable for other families: their
remaining projection/encoding work stays in the complete total. All four are
not_applicable for loaded bench-validate and frontend loaded-model cases; the
existing loaded Validate component is retained separately and unchanged.

These intervals are ordered and non-overlapping. Gaps (dispatch/preamble,
separate hook receipts and later producer/cleanup work) are not assigned to a
component. Every interval uses actual endpoint observations. Startup includes
driver/load-path overhead; owner intervals include start-ack, hook/pipe/receipt
and scheduling overhead and, for Journey/Health, real owner computations.
Sequential companion collection may change cache state. There is no measured
calibration or overhead bound and no correction; raw observations stay raw.

`omb-benchmark-1` gains a backward-compatible `diagnostic_phase_profile` object
on the existing workload record, never additional workload cases. The existing
top-level `phase` still means cold/warm lifecycle; internal components exist
only in `diagnostic_phase_profile.phases`. It records
method, separate-companion mode, non-additive relationship, copy/driver digests,
requested observations, actual companion launches and warm-up count, raw ordered
boundary evidence, unique request identity/hash/binding and admitted response
hash. The binding hashes base SHA, ordinary source digest, exact case-plan JSON,
fixture digest, copy/driver digests and unique request identity/hash in that
order with LF separators. Top-level source/shell/OS/arch/workload provenance
applies to both populations; request/copy/driver identities distinguish them.

Each of startup/admission/probes/validation_computation has applicability
required or not_applicable, state measured/unavailable/failed/not_applicable,
raw integer nanoseconds in collection order, success/failure/timeout counts,
outcomes and nearest-rank p50/p95/p99/maximum using the existing Samples rule.
N/A and missing/failed populations have empty samples and null statistics.
Measured zero is a successful raw 0 with numeric 0 statistics. Partial failures
retain successful raw samples and all failure outcomes;
required_evidence_complete is false unless every required population supplies
all requested observations without failure/timeout. A valid total cannot fill
missing phase evidence: full-mode evidence with false completeness is incomplete.
Values are always diagnostic and budget_verdict=not_graded.

Permanent deterministic tests cover every family/applicability, exact anchors
and copied-shell syntax, boundary omission/duplication/reordering/backward time,
zero/N/A/empty statistics, raw-order nearest ranks, independent total/failure/
timeout accounting, live malformed/wrong-bound/incomplete/tampered companions,
semantic/effect equivalence and identical ordered sys_* probe selection for all
applicable native cases and host-platform fixture families on x86_64. Live
negative controls use the host-platform Journey fixture, with no native-arm64
selection prerequisite. Fixture correctness on x86_64 is not native latency.
Correctness executions disable phase timestamps
entirely; synthetic clock fixtures test arithmetic, liveness clocks enforce
transport deadlines only. Existing exact-page, production attachment, loaded
Validate, CP1 and prerequisite proofs remain unchanged.
