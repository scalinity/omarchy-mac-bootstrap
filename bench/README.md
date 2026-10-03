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
images remain outside that check. A Git-head change during a case stops output
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
development fixture sessions. Paging obtains generation in a separate
preparation session, then creates a fresh measured session whose first request
is detail. These setup requests are counted and excluded. Warm uses one
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

Fail-first at accepted V: its Git tree had no benchmark artifacts; the new
artifact test reported 0 passed, 4 failed, 0 skipped, exit 1. This missing-harness
evidence is distinct from the earlier semantic STOP and independent resolution.
Neither was a product regression.
