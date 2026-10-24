# Testing the product expansion

The suites below run in CI (*CI*), and each case is named by its id in its
test source. A family any of whose tests is still unwritten is marked
planned in *Test families*, with the phase of MILESTONES.md → *The finish*
that writes it; a guarantee holds once its test exists and passes. The
baseline's own suite (docs/ARCHITECTURE.md → *Tests*) runs beside them.

## Principles

- **No machine is changed in CI.** Bash tests run over generated fixtures,
  with `run` recording argv instead of running; PTY tests drive a core in
  fixture mode; tests that save data write only inside temporary folders.
- **The startup check is its own class.** The `frontend-check-*` tests
  drive the production route, with no fixture or development override,
  only inside the hermetic boundary of *Frontend*, below.
- **Both shells, both systems.** Every Bash test runs under stock
  `/bin/bash` 3.2 on macOS and Bash 5 on Linux, with strict skips; a
  macOS-fixture section on Linux is gated on `plutil`.
- **Tests signal only what they own:** a PID recorded at its start and held
  to its start time, or a process group the test made, never a process
  found by its name (`test-owned-signal-only`); unrelated processes with
  matching command lines stay alive throughout (`t_decoy`,
  `test-unrelated-matching-process-survives`).
- **The cheapest layer first.** Pure functions and state transitions carry
  most of the weight; rendered frames next; a few PTY runs last.
- **Every protection names its tests.** Each claim in docs/SECURITY.md cites
  the ids or families that fail if it does not hold; `docs-test-ids` holds
  each cited id to a test that names it, or to a family planned below.
- **Fixtures are generated.** `tests/fixtures/generate.sh` writes every
  fixture and CI checks they are what it writes; a worker's fixtures go in
  a generator file of its own, which `generate.sh` sources.
- **Honest scope.** The secret tests prove what the supported adapters do
  and that opaque content needs consent, never that an arbitrary file holds
  no secret.

**What every new subsystem has:** one `tests/test-<name>.sh` and its row in
`tests/ci-manifest.tsv`, in the same commit, over generated fixtures with
`run` recording commands, passing under `/bin/bash` 3.2 and Bash 5. In it:
the success path and one case per refusal or failure the code tells apart;
the invariants (reads write nothing; every new probe, `run` or `sudo` joins
`tests/test-safety.sh` on purpose; a planted secret never reaches state,
log, profile or bundle; success comes only from a fresh read); per place it
saves data, one stop case and one write-failure case; per baseline action it
moves, one equivalence case against `2edb76a`. In the frontend: state and
frame tests and a frame per screen, a contract case per new request, and PTY
tests only for a new way of taking the terminal.

**What no one spends effort on:** case matrices, test-id catalogs or
contract prose before the code; re-proving shared machinery for each
producer; comparisons against intermediate commits; new "-proof" suites;
scale beyond what shows the invariant; new CI lanes.

## Test families

A family is the prefix of its ids. Each row names the files that hold it;
*planned* marks a family any of whose tests is still unwritten, with the
phase that writes them. `docs-test-ids` reads this table.

| Family | What it holds | Test files | Status |
| --- | --- | --- | --- |
| `proto-*` | the record format and admission, the same in Bash and Rust; the golden examples; the core's refusals | `tests/test-records.sh`, `tests/proto/corpus.sh`, `tests/test-core.sh`, `tests/test-static.sh`, `frontend/tests/proto_diff.rs`, `frontend/tests/contract.rs` | in CI |
| `sup-*` | supervision, descriptors, completion and barriers, the scratch's cleanup and reclaim, the Shared critical interval | `tests/test-core.sh`, `tests/test-frontend.sh`, `tests/test-diag.sh`, `tests/test-static.sh`, `frontend/tests/contract.rs`, `frontend/tests/pty.rs` | in CI |
| `launcher-*` | when the launcher takes the terminal back | `tests/test-frontend.sh` | in CI |
| `diag-*` | diagnostics by child class, and their byte limits | `tests/test-diag.sh` with its units `tests/diag-*.sh`, `tests/test-core.sh`, `tests/test-static.sh` | in CI |
| `pty-*` | the real terminal | `frontend/tests/pty.rs` | in CI |
| `frontend-*` | the lock, acquisition and cache, intent, the build's inputs and closure, the artifact checks | `tests/test-frontend.sh`, `tests/test-frontend-inputs.sh`, `tests/frontend-inputs.sh`; the artifact checks are steps of the frontend jobs in `tests/ci-manifest.tsv` | in CI |
| `frontend-check-*` | the startup check, through its production route | `tests/test-frontend-check.sh`, `tests/frontend-check.sh`, `tests/frontend-check-lib.sh`, `tests/test-core.sh`, `frontend/tests/pty.rs` | in CI |
| `gen-*` | the Gate 2 reads' generations and paging | `tests/test-gate2-paging.sh`, beside the other Gate 2 read suites (*Gate 2 read tests*) | in CI |
| `cp1-*` | the health and logs scopes in the record language, every older document unchanged | `tests/test-cp1.sh`, `tests/cp1-released-frontend.sh`, `tests/proto/corpus.sh` | in CI |
| `bench-*` | the O1 benchmark's harness; timing runs only by hand | `tests/test-benchmark.sh`, `frontend/tests/benchmark/` | in CI |
| `docs-*` | the documentation checks | `tests/test-docs.sh` | in CI |
| `actions-*` | the core's action table through `execute`, and `operation clear` | `tests/test-actions.sh`, `tests/test-operation.sh`; frames and contract cases for screens 1, 2, 12–15 and 18 in `frontend/tests/` | planned: Phase A |
| `equiv-*` | each exposed baseline action against `2edb76a` | `tests/test-actions.sh` | planned: Phase A |
| `scan-*` | the scanner, and Zsh's aliases and exports | `tests/test-scan.sh`; frames for screens 3 and 4, the category tabs and Review | planned: Phase A |
| `toml-*` | the strict TOML subset reader | `tests/test-toml.sh` | planned: Phase A |
| `secret-*` | classification, the hard refusals and the credential scan, in the profile and in the bundle | `tests/test-secrets.sh` | planned: Phase A |
| `resolve-*` | resolution in fixed layers | `tests/test-resolve.sh` | planned: Phase A |
| `profile-*` | selection and the sealed profile | `tests/test-profile.sh` | planned: Phase A |
| `bundle-*` | export and the bundle check | `tests/test-bundle.sh` | planned: Phase A |
| `restore-*` | restore and its run log | `tests/test-restore.sh`; frames for screens 20 and 21 | built: Phase B |
| `agents-*` | the AI tool table that `dev` and `restore` share | `tests/test-agents.sh`, `tests/test-dev.sh`; screen 22's new rows | built: Phase B |
| `debug-*` | the `debug` report | `tests/test-debug.sh`; the error state's `D` key | built: Phase B |
| `ssh-*` | SSH's classification, and `start` turning off the image's password SSH | `tests/test-detection.sh` | built: Phase B |
| `journey-*` | the ten stages, the journey simulation, `report` | `tests/test-journey.sh`, the PTY journey in `frontend/tests/pty.rs`; screen 25 | planned: Phase C |
| `qualify-*` | the three qualification steps | `tests/test-qualify.sh`; screen 23 | planned: Phase C |

Outside these families: the baseline's own suites; `tests/test-baseline.sh`
(*Equivalence with the accepted baseline*); the operation-record
diagnostic's cases (*Gate 3 operation-record diagnostic tests*);
`tests/test-ci.sh` (*CI*); `tests/test-fake-children.sh`.

## New seams

| Seam | Purpose | Limits |
| --- | --- | --- |
| `OMB_TEST_FOUNDATION` | exactly `1` selects the fake-action foundation contract | requires a nonempty fixture and a real, non-symlink `test-children` directory; fixture data alone grants no authority; rejected by `frontend-check` |
| `OMB_TEST_HANDOFF_CHILD` | a test program in place of an upstream one during a handoff | fixture mode only; refused as root |
| `OMB_FRONTEND_DEV` | an unreleased frontend build | fixture mode only; refused as root |
| `sys_walk DIR` (phase A) | lists a tree (type, size, mode, link text) without following links; reads `fixture/root/…` in fixture mode | read-only; in the probe allowlist |
| fixture homes (phases A and B) | synthetic macOS homes under `fixture/root/Users/alex/…`, Omarchy homes under `fixture/root/home/alex/…` | generated, synthetic values only |
| `OMB_TEST_STOP_AT` (phase A) | the core kills itself (`kill -9 $$`) right after the named save boundary: a stop case | fixture mode only; refused as root |
| `OMB_TEST_FAIL_AT` (phase A) | the checked writer fails at the named boundary as a full disk would: a write-failure case | fixture mode only; refused as root |
| `OMB_TEST_PAUSE_AT` (phase B) | the core waits at the named boundary until a flag file beside it exists, so a test can change the machine in between | fixture mode only; refused as root; runs nothing |
| `OMB_TEST_QUAL_BYTES` (phase C) | a small size for qualification data | fixture mode only; refused as root |

Test-only hooks in the frontend (a stalled channel, a reader-thread panic on
every request or on request N, a descriptor that cannot be sealed) exist
only in builds with the `test-hooks` feature, which a release build never
enables (a CI check on the release workflow).

## Protocol and processes

### `proto-*`: admission and the core's refusals

Bash admission (`lib/records.sh`) and the frontend's Rust admission judge
one corpus, `tests/proto/corpus.sh`, with the same verdict, reason code and
line, the Rust side also reading every case split at every byte boundary
(`proto-diff-*`, `proto-diff-chunks`); the golden examples also run against
the core in fixture mode and through the frontend's decoding
(`proto-golden-*`). `tests/test-core.sh` holds the core's refusals: another
version than the lock's, a malformed session, the ceiling, the scope, the
typed word, an argument, a handoff without a terminal. `tests/test-static.sh`
holds that a managed path's `sudo` is `sudo -n` and that no value reaches
`eval`, `source`, unchecked arithmetic or a command string.

### `sup-*`: supervision and the scratch

| Ids | Case | Expected |
| --- | --- | --- |
| `sup-fd-child`, `sup-fd-grandchild`, `sup-fd3-closed` | a managed and a handoff child, and a grandchild, list every open descriptor while F holds inheritable ones up to its limit; C lists its own right after admission | exactly 0, 1, 2; fd 3 closed before any other code runs; F completes without waiting for the grandchild |
| `sup-early-signal` | SIGTERM, then SIGHUP, reaches C while it waits at the copy of its request, its scratch made | C ends, the scratch folder and the request's copy removed, nothing on stderr |
| `sup-spool-handoff`, `sup-slow-frontend`, `sup-overflow`, `sup-epipe` | 10 000 `progress` records during a handoff; F's channel held full; more than 8 MiB − 64 KiB of `progress`; a 1 MiB request | nothing blocks and order is kept; C finishes without waiting; one `overflow`, then the `result`, the spool under 8 MiB; EPIPE shown, C exits 2 |
| `sup-completion-controllers-live`, `sup-completion-worker-lingers`, `sup-completion-failed`, `sup-completion-unexpected` | the child exits and nothing is left but L, F and C; a descendant outlives the time limit; the machine shows no effect, or something else | completed, the record removed; unsupervised, the outcome unknown; `failed`, the record kept with its finding |
| `sup-failed-blocks`, `sup-failed-same-boot`, `sup-failed-reconcile`, `sup-failed-result-unrecorded`, `sup-failed-record-unwritten` | the next act after a failed operation, in the same boot and after a reboot; a result or a failed record that cannot be written | refused `unresolved` while reads work; nothing in the boot clears it; reconciled after a reboot; `failed`, saying so, never no record |
| `sup-core-death-mutator-live`, `sup-mutator-escaped-pgid`, `sup-unsupervised-blocks`, `sup-no-reclaim-pid`, `sup-read-orphan-no-barrier` | C killed while its mutating child runs, or after the child escaped with `setsid`; the next act from either interface; a dead core's record; a killed read | every act in the scope refused `unsupervised` for the rest of the boot, reads working; never reclaimed; a read leaves no barrier |
| `sup-boot-clears`, `sup-post-reboot-reconcile`, `sup-post-reboot-unexpected` | a new boot session, the machine showing no effect, the expected effect, or something else | reconciled and the action proceeds; something else stays blocked |
| `sup-identity-unknown`, `sup-identity-link`, `sup-pid-reuse` | `ps` or the boot session unreadable; an identity or record that is a link or a FIFO; a PID reused with another start, or from a previous boot | nothing completed, deleted or cleared; nothing deleted; none taken as alive |
| `sup-owner-cleanup`, `sup-owner-cleanup-refused`, `sup-reclaim-*`, `sup-frontend-death-core-live` | L exiting with nothing left, or with a live core, worker, late process or unresolved operation; a later launcher finding an old scratch; F killed during a managed act | L removes its own scratch only when nothing lives; reclaimed only when every recorded identity is dead and nothing names it; C completes and L cleans up as the owner |
| `sup-reader-death`, `sup-mutating-daemon-classification` | the reader thread panics; a registry entry for a mutator that daemonises | the outcome unknown until C exits, then a fresh snapshot; refused by the check |
| `sup-eintr`, `sup-eintr-exemption`, `sup-eintr-exemption-prefix`, `sup-eintr-one-substitution` | a signal during a read or wait; SIGHUP every 30 ms at C through a managed act | retried; the act completes supervised. On Bash 5.2 alone, a core that dies of the upstream trap loss is a skip, counted apart, only in one of the four states such a death leaves, its spool held to the exact prefix, and only what it left is removed; 3.2 and 5.3.15 never skip; no command of C's own holds two command substitutions side by side (`tests/bash-trap-comsub.sh`) |
| `sup-no-setsid`, `sup-one-spawner`, `sup-shared-critical` | static | F and C never call `setsid` or `setpgid`, nor ignore or block job-control signals across a spawn; F spawns only on its main thread and C writes the spool only from its main shell; between the final topology read and `sudo -n diskutil addPartition` nothing is added, and that code is the baseline's |

### `launcher-*`: the terminal comes back only once the session is over

L takes the terminal back — restores its settings, reports, or continues in
text — only when its wait says the session is quiescent; otherwise it leaves
the terminal and the scratch as they are and says so. `tests/test-frontend.sh`
holds this over late processes, corrupt or dangling identities, an
unreadable process table, a live core at the limit and a reused PID.

### `diag-*`: diagnostics by child class

Every child the core runs has a class in the child registry. A read child's
stderr drains through a bounded capture — 65 536 bytes a child, header
included, 262 144 a request, 4 194 304 a session, every retained byte
counted — and a capture failure changes no outcome. A mutating child's
output reaches no pipe or disk and never blocks it; a planted token from a
read child shows only on the log screen, never in `debug`, a record, the
log file or the state directory.

### Gate 2 read tests

Each Gate 2 read — `snapshot`, `detail` and `validate` — has its suites in
`tests/test-gate2-*.sh`: one capture under read intent with nothing
persisted, every row admitted whole before publication, a fixed `error io`,
`error representation` or `error invariant` per fault, and `changed` with
the fresh generation (`gen-*`); the proof suites hold owners, probes and
answers to `2edb76a` through `tests/gate2-oracle.sh` and
`tests/gate2-doctor-oracle.sh`. `tests/test-cp1.sh` (`cp1-*`) keeps every
older document's bytes and verdict. `tests/test-static.sh` holds the files
the Shared creation calls to `2edb76a`, and `lib/macos.sh` with its one
corrected helper, `plist_get` (`tests/test-detection.sh --plist-helper-only`).

### Gate 3 operation-record diagnostic tests

`tests/test-operation.sh` holds docs/PROTOCOL.md → *The operation-record
diagnostic* to the actual core, driven as the frontend drives it, and to
`operation SCOPE`: DIA-01 to DIA-15, from no record through every unreadable
or undetermined shape to hostile bytes and old and new clients, each held to
a read. The frontend's Operation view has its frame, contract, `proto_diff`
and PTY cases in `frontend/tests/`. The cases of `operation clear SCOPE`
join this suite in phase A (`actions-*`).

## Frontend

### `pty-*`: the real terminal

On real macOS arm64 and Linux aarch64 runners (`portable-pty`, `vt100`):
the handoff's foreground process group; Ctrl-C, SIGTERM, SIGHUP, Ctrl-Z and
SIGCONT, idle and during a child; the child's default dispositions and empty
mask; the settings restored around a raw-mode child and on exit; no key
taken from a child; exit and panics leaving the terminal as it was; a
hangup with a supervised act still completing; resizing to too small.

### `frontend-*`: distribution, intent and the build

`tests/test-frontend.sh` holds the launcher's side: a digest mismatch never
runs (`frontend-digest`); no cache and no network continues in text; the
development override works only in fixture mode, never as root
(`frontend-dev`); read, plan, dry-run and `--no-tui` sessions change nothing
outside the scratch (`frontend-intent-*`). `tests/test-frontend-inputs.sh`
holds `inputs_digest` over every tracked file under `frontend/`, the lock
outside it (`frontend-lock-not-input`), and a closure check refusing any
input the listing does not hold (`frontend-input-*`). The artifact checks
are CI steps: `frontend-compat-linux` (loader, `DT_NEEDED`, `GLIBC_` ≤ 2.39,
`LOAD` aligned ≥ 0x4000), `frontend-compat-macos` (arm64, `minos` 13.5,
`codesign -v`).

### `frontend-check-*`: the startup check

docs/FRONTEND.md → *The startup check*; docs/PROTOCOL.md → *The
startup-check session*.

**The boundary.** Each case runs a copy of the tool's checkout in a
temporary folder, with a temporary `HOME`, `XDG_CACHE_HOME`,
`XDG_STATE_HOME` and `TMPDIR`; `OMB_STATE_DIR` unset; no `OMB_FIXTURE`,
`OMB_FRONTEND_DEV` or `OMB_TEST_`-prefixed variable unless a case sets one
on purpose; curl's own configuration file and proxy variables cleared. The
copy's `release/frontend.lock` is a test lock pinning, by size and SHA-256,
the native release build CI makes for the PTY tests (no `test-hooks`
feature), or a failure case's stand-in, at an `https://127.0.0.1:<port>/…`
URL served by a loopback HTTPS server the test owns. Its throwaway
certificate authority is trusted only through curl's `CURL_CA_BUNDLE` in
the test's environment, because the launcher accepts only HTTPS; a runner
whose `curl` does not honour it is reported, never worked around with a
launcher seam. So acquisition runs its normal path — `curl`, the size, the
digest, the promotion into the cache — and nothing bypasses it. Every
persistent write lands in the temporary cache; nothing is fetched beyond
the loopback; no baseline probe or action runs; the runner's real root
cache is never touched (the root-cache case runs at the cache-selection
helper, over a temporary stand-in); and the actual release is proved only
by `frontend-check-production-mac`.

**Two kinds of evidence** (docs/FRONTEND.md → *The command's result*): the
cases below that expect `completed` hold the command's result — exchanges,
lifecycle, measured terminal settings. Only `frontend-check-terminal` and
`frontend-check-production-mac` are rendering evidence, and neither counts
a run whose dashboard was not seen.

| Ids | Case and expectation |
| --- | --- |
| `frontend-check-route`, `frontend-check-default-unchanged`, `frontend-check-install-unchanged` | the route reaches none of the installer's routing, `resume`, the run lock or the log; the bare command and every other command behave as at `569d67e`, the commit before the route |
| `frontend-check-no-fixture`, `frontend-check-overrides-refused`, `frontend-check-seam-controls` | a completed check's `hello` says `fixture=0`, `ceiling=read`, `dry_run=0`; `OMB_FIXTURE`, `OMB_FRONTEND_DEV`, any non-empty `OMB_TEST_` variable or an extra argument is refused with status 2 before anything else; lookalike names are not |
| `frontend-check-cold-cache`, `frontend-check-decline`, `frontend-check-warm-cache`, `frontend-check-bad-cache`, `frontend-check-lock` | a cold cache downloads after a yes, holds the file to size and digest and promotes it; declined, nothing is made; warm, no request; a wrong cached file never runs, and moves aside only after a yes; a changed lock never runs a binary it does not pin |
| `frontend-check-mismatch-then-download-fails`, `frontend-check-mismatch-then-interrupted`, `frontend-check-promoted-then-exec-fails`, `frontend-check-promoted-then-startup-fails`, `frontend-check-cleanup-fails`, `frontend-check-uncatchable-residue`, `frontend-check-residue-never-selected`, `frontend-check-no-install-fallback` | each failure ends `not-completed` or `unsettled`, status 1, with nothing run that the lock does not pin and nothing of the installer reached; a promoted file stays; an attempt file that cannot be removed is named; no attempt file or backup is ever selected |
| `frontend-check-read-session`, `frontend-check-purpose-env`, `frontend-check-snapshot`, `frontend-check-zero-actions`, `frontend-check-forbidden-scope`, `frontend-check-execute-refused`, `frontend-check-detail-refused`, `frontend-check-validate-refused`, `frontend-check-no-state` | a read session with the check's purpose; its snapshot exact and action-free, operation records untouched; every other scope, `execute`, `detail` and `validate` refused before any lock, record or child; no state, log, lock, plan or download |
| `frontend-check-early-quit-late-snapshot`, `frontend-check-refresh-failure`, `frontend-check-no-render-claim`, `frontend-check-termios`, `frontend-check-completion-order`, `frontend-check-cleanup` | `completed` needs every exchange `done`, the settings restored and read back equal, and the scratch confirmed gone, and claims no drawing |
| `frontend-check-ineligible-terminal`, `frontend-check-dry-run-ineligible`, `frontend-check-dry-run` | `--no-tui`, a pipe, `TERM` unset or `dumb`: `not-performed`, with no lock read and no cache inspected; `--dry-run` reports what would run and starts nothing |
| `frontend-check-terminal` | rendering evidence, on a real PTY on both arm64 runners: the dashboard with its four facts and "Nothing is available now.", a key answered, `q` leaves, the terminal as before |
| `frontend-check-production-mac` | by hand on this Mac for each release: the committed production lock's macOS artifact, no seam set; what `frontend-check-terminal` shows, with nothing of the session left, recorded with the cache path and digest and the core's `hello` |

**Effects.** Around each case the test snapshots the temporary `HOME`,
cache, state folder and `TMPDIR` (type, mode, size and digest of every
entry) and judges the difference by the phase the case reached
(docs/FRONTEND.md → *Effects*): only that phase's paths may differ, the
state folder is unchanged or absent, and no installer routing is reached.
In `TMPDIR` nothing remains except a session scratch the launcher reported
as not known to be over, and whatever an uncatchable death left.

### Layers

| Layer | What | How |
| --- | --- | --- |
| A. state | every screen's `update` over synthetic messages: selection, filtering, focus, gates (an inexact word never submits), basis carried, handoff requested only for `terminal=handoff` actions | plain unit tests, no terminal |
| B. frames | each screen at 120×40, 100×30, 80×24, 60×24, and 59×20 (the too-small state) | `TestBackend`, `assert_buffer_lines` |
| C. snapshots | loading, empty, partial, error, blocked, changed, handoff notice, gate | `insta` text snapshots; CI fails on a pending snapshot |
| D. colour and emphasis | focus is reversed, danger is danger, monochrome keeps reverse | `Buffer` comparisons: each property a token sets — colour, background, reverse, never bold, one focus marker — compared on its own |
| E. degraded modes | 16 colours, no colour, ASCII: every state keeps its word and glyph; every glyph is one cell | frames under each profile |
| F. lifecycle | start, exit, error and panic write the expected sequence | a recording writer in place of stdout |
| G. PTY | `pty-*` | real runners |
| H. contract | the Rust client against the real Bash core in fixture mode: every operation's golden request and response, every refusal; at gate 2 also each read the frontend presents, over every baseline fixture, against the baseline's own read commands | both CI systems; on macOS under `/bin/bash` 3.2 |

### `bench-*`: the O1 benchmark

`bench/README.md` holds the method; `tests/test-benchmark.sh` and
`frontend/tests/benchmark/` check the harness and never time anything;
`.github/workflows/benchmark.yml` runs it by hand on both arm64 runners,
cold and warm, 200 repetitions per case. O1 is signed off with one
limitation recorded, O1-LOGS-P01 (MILESTONES.md → *Gate 2 — Read-only
equivalence*); a later screen is measured only if it feels slow.

| Id | Operation | Budget |
| --- | --- | --- |
| `bench-nav` | navigation/focus plus resulting render | p95 < 50 ms, zero core requests |
| `bench-search` | search/filter over loaded data plus resulting render | p95 < 100 ms, zero core requests |
| `bench-snapshot` | a small snapshot that reads no disk | p95 < 500 ms |
| `bench-validate` | production validation computation after authoritative inputs are loaded | p95 < 300 ms |
| `bench-disk` | full current internal-disk planning refresh plus status work; macOS journey snapshot and machine/status detail | investigate p95 > 2 s; not a hard pass/fail threshold |
| `bench-journey-linux` | Linux journey snapshot and machine/status detail | p95 < 500 ms |
| `bench-health` | health snapshot and detail: the whole Doctor owner, with fixture-backed network checks | investigate p95 > 2 s |
| `bench-logs` | logs snapshot and detail: real source selection plus the bounded 40-line window | p95 < 500 ms |

## Planned suites

Each joins `tests/ci-manifest.tsv` in the commit that adds it; its family
loses *planned* when its last test is written.

### Phase A

- `tests/test-actions.sh` (Gate 3): each row of the core's action table
  over the lifecycle fixtures — its success path; each refusal
  (`unavailable`, `changed`, the word, `busy`, an unsupervised, failed or
  unreadable record); the classifier's outcome on a fresh read; `umask 022`;
  the word answering only the first prompt; its `equiv-*` case. For
  `plan.save`, also the stop at the first failed write and one stop case,
  its only success a read-back of every saved value, the Shared intent and
  `planned_at`. With `tests/test-operation.sh`, `operation clear SCOPE`:
  only `unreadable`, typed `clear`, one rename inside `ops`, refused if the
  entry changed.
- `tests/test-scan.sh` (Gate 4): no inventoried tool runs, nothing sourced;
  unknown, `partial` and `denied` visible; only Zsh's literal aliases and
  allowlisted exports become Bash; a stow root followed once.
- `tests/test-toml.sh` (Gate 4): files as Codex and mise write them, read
  exactly; anything outside the subset refuses and lists the whole file.
- `tests/test-secrets.sh` (Gates 4 and 5): no planted secret in the profile,
  bundle, state or log; the kind named, never the value; `opaque` per save;
  an encrypted SSH key only after `carry`; `UseKeychain` dropped.
- `tests/test-resolve.sh` (Gate 4): the migration map and the person's
  decisions in fixed layers; one version per runtime; an unresolved item a
  decision, or a guess checked on Linux.
- `tests/test-profile.sh` (Gate 4): one `omb-select` document; the sealed
  profile bound to this Mac; a rescan keeping choices by item id.
- `tests/test-bundle.sh` (Gate 5): hash-named objects and one sealed
  `bundle.omb` written as `.partial-*` then renamed; a stop or write failure
  leaving only `.partial-*`; nothing deleted; size and free-space limits; a
  corrupt bundle refused by the bundle check.

### Phase B

- `tests/test-restore.sh` (M15-A): never as root; the bundle check first;
  Keep by default; originals moved whole into backups and compared;
  no-clobber placement, read back; a link on the path stops its item; a stop
  resumes and a rerun changes nothing; `restore undo` refused where the
  destination changed; packages judged by `pacman -Q`; interleaved AI
  receipts, `restore.agent` stop/write failures and the numeric Health count
  contract. `suite:restore` runs on macos-bash32 m1 and linux-bash5 l3.
- `tests/test-agents.sh`, `tests/test-dev.sh` (M15-B): observation from
  files only, nothing running a wrapper, shim, mise or agent; `mise use -g`,
  one copy each; lazy wrappers never counted as installed tools. Exact
  wrapper bytes, failed version checks, handoffs and fixture immutability
  are covered. `suite:agents` runs on macos-bash32 m3 and linux-bash5 l0.
- `tests/test-debug.sh` (M15-A): the brief and the status and doctor facts,
  no planted log line, journal line, command output or file content; the
  root line only as root; nothing written; brief paging and whole-response
  admission. `suite:debug` runs on macos-bash32 m4 and linux-bash5 l1.
- `tests/test-detection.sh` (M15-C): SSH from `sshd -T` as `off`,
  `key-only`, `passwords` or `cannot-tell`; `start` disabling `sshd` and
  checking it inactive and disabled before Omarchy Mac's setup.

### Phase C

- `tests/test-journey.sh` (M16): the ten stages from the machine on both
  systems; the journey simulation, macOS → reboot → Linux → back, with its
  PTY run; the report's check table.
- `tests/test-qualify.sh` (M16): the three steps over Shared at a small
  size; the due step from the files present; the Shared identity check
  first; a short or changed file failing; a pass removing the data files.

## Equivalence with the accepted baseline

The oracle is the **accepted baseline, commit
`2edb76a7de3f78ec90927ac93d5eec3a84636253`**, not the new text flow: two new
paths could agree with each other and share a regression.

- The baseline is extracted with `git archive` (CI checks out the full
  history); its text flow runs over each baseline fixture with the typed
  words piped in, collecting the recorded commands (`OMB_TEST_RECORD`) and
  every file in the state directory.
- The current tool runs the same fixture through its text flow
  (`tests/test-baseline.sh`) and, for every action the frontend drives,
  through `core execute` with the same words (`equiv-*`, phase A).
- A fixed normaliser replaces only `now_utc` and `now_stamp` values, `$$`
  and `mktemp` suffixes; the decisions, the argv and its order, and the
  resulting state must be equal byte for byte.
- A difference fails unless the test's short list names it, with its reason
  (`agents-lazy-wrapper`, `agents-mise-install`, `agents-opencode`:
  wrapper-only installations are absent, mise replaces Claude download and
  Codex npm flows including the Claude provenance record, and OpenCode is
  selectable; `start-disable-ssh`: one exact disable command and its active
  and enablement reads; `doctor-ssh-findings`: SSH policy and image-account
  findings; `debug-implemented`: the fixed brief is a read command;
  `M16-system-names`: a header line's first label word is `macOS` or `Linux`
  where the baseline's is the protocol value `macos` or `linux`, and no other
  byte of any line differs; `free-plan-id`: a token loaded with no Shared
  planned leaves one more state line, `phase1_plan_id=` and the first 8 hex
  digits of the SHA-256 of the token's canonical form, and the log's record of
  that write; it names the plan in the completion code Linux shows (docs/SHARED.md → *The codes*)).
  Operation records are removed when their action ends, so the final state
  directory is compared whole.

## Documentation checks

`tests/test-docs.sh` runs in CI over `SPEC.md`, `MILESTONES.md`,
`README.md`, `AGENTS.md`, `CLAUDE.md` and `docs/`:

| Id | Check |
| --- | --- |
| `docs-refs` | every `FILE → *Section*` reference names an existing heading in that file |
| `docs-test-ids` | every test id docs/SECURITY.md cites is named by a test in tests/ or frontend/tests/, or its family is planned in *Test families* |
| `docs-states` | every state in SPEC.md → *States* is defined in the document that owns its subsystem |
| `docs-commands` | every `omarchy-bootstrap` command the documents name is in SPEC.md → *Commands*, with an intent: `read`, `plan`, `act`, `act, scoped` or `per operation`, and `read, frontend cache` for `frontend-check` alone, that exact pairing and no other |
| `docs-read-writes` | no read command is described as writing anything |
| `docs-milestones` | each gate and milestone is defined once; M17 is not started |
| `docs-shell` | the target shell is Bash wherever a target shell is named |
| `docs-windows` | Windows appears only as a non-goal |
| `docs-debug-names` | `debug` is the only debug command |
| `docs-sudo-k` | `sudo -k` appears only in docs/DECISIONS.md → *Rejected* |
| `docs-sessions` | agent sessions and histories appear only as not carried in v1 |
| `docs-agents-claude` | `AGENTS.md` and `CLAUDE.md` are byte-identical |
| `docs-backdrop` | the backdrop token's 256-colour value in docs/UX.md → *Tokens* is from the colour cube's blue column (17 to 21), never a grey or black |

## CI

One workflow, `.github/workflows/ci.yml`, in two modes; `tests/ci.sh`
decides which, plans the run and keeps its evidence.

- **FULL** runs when the workflow is dispatched
  (`gh workflow run ci.yml --ref BRANCH -f candidate=SHA`, which stops when
  the branch is not at SHA) and on a push to main. It runs every shard of
  `tests/ci-manifest.tsv` at one SHA, then the completeness guard. A green
  FULL guard at the exact SHA is the acceptance evidence; nothing else is.
- **FAST** runs on any other push, and on a pull request from a fork. It
  runs what the changed paths call for: always syntax, fixture freshness,
  `docs-*`, the static and safety suites and `test-ci`; every `linux-bash5`
  shard for product code (with the `frontend` lane for `lib/` and the
  frontend's test scripts); a changed suite or diagnostics unit by itself,
  with ShellCheck; the `frontend` lane for `frontend/` and `release/`;
  every tier for a path none of these names. Its verdict and evidence say
  it is not acceptance evidence, and the guard refuses them.

FULL runs at each phase's end and on the commit the owner installs from; a
phase merges to `main` only on a green guard at its exact SHA. During a
phase the suites a change touches run locally, and FAST is feedback. A
documentation-only change needs FAST alone. A timing failure may be rerun
once, noted in the commit; a second failure is a finding.

| Lane or job | Runs |
| --- | --- |
| `macos-bash32` | `macos-latest`, `/bin/bash` 3.2, plutil and BSD tools, no skip: every Bash test, fixture freshness, syntax, and the entrypoint starting under `sh` and `/bin/bash` with nothing on stderr, recording nothing; four shards |
| `linux-bash5` | `ubuntu-24.04` x86_64, Bash 5, every Bash test, fixture freshness, syntax, ShellCheck 0.9.0 over every file and through the entrypoint (`-x`), `docs-*`; only the plutil-bound checks and the Bash 5.2 storm case skip; four shards, ShellCheck in `l0` |
| `target-bash53` | `ubuntu-24.04-arm`: GNU Bash 5.3.15, the Linux root's, built in every shard from GNU's sources held to `tests/bash-5.3.15.sha256`; `tests/bash-trap-comsub.sh` under it; the records, core (the signal storm with no skip), diagnostics, launcher, static, `cp1` and Gate 2 read suites, layer H and layer G under it; only the plutil-bound checks skip; four shards |
| `frontend` | `cargo fmt --check`, `clippy -D warnings`, layers A–F and H against the Bash 5 core, the panic gate, `proto-diff-*`, no pending snapshots, the closure over a release build, `frontend-input-*` and `frontend-lock-not-input`, the lock's protocol equals the core's, and either the exact lock check or the named unreleased version's (the job checks out the full history for it); only the plutil-bound checks skip |
| `frontend-linux-arm64` | `ubuntu-24.04-arm`: build, layer G, the unit tests (the process table included), H, the panic gate, `frontend-check-*` but the production case, `frontend-compat-linux`; one shard (the Bash suites and diagnostics units run on `linux-bash5` and `target-bash53`) |
| `frontend-macos-arm64` | build, layers G and H with the `/bin/bash` 3.2 core, the unit tests, the panic gate, `sup-*`, `frontend-check-*` but the production case, `frontend-compat-macos`; no skip |
| release | on a `frontend-v*` tag: native builds, the checks above, `SHA256SUMS`, artifact attestations, no `test-hooks` feature |
| benchmark | by hand (`workflow_dispatch`, `.github/workflows/benchmark.yml`) on both arm64 runners: `bench-*`; its sign-off and recorded limitation are in MILESTONES.md → *Gate 2 — Read-only equivalence* |

**The manifest.** `tests/ci-manifest.tsv` gives each lane its runner,
platform, the bash it must run under (an ERE on `$BASH_VERSION`), the skips
it allows and the suites it must run, and puts every unit in exactly one
shard: a suite, a diagnostics unit (`tests/test-diag.sh` with
`OMB_DIAG_UNITS`), a check `tests/ci.sh` runs, or a step of the lane's job.
Each lane is one job and its shards a matrix; a shard runs its units in
order in one checkout, under its lane's bash alone. `tests/ci.sh lint` holds
the manifest to the repository, so a new `tests/test-*.sh` fails `test-ci`
until a lane runs it, and `test-ci` holds the workflow to the manifest.

**The guard.** Every shard writes evidence, uploaded even when it fails: the
SHAs it checked out and ran for, its lane, shard, platform and mode, and
each unit's result, exit status, bash version, summary lines and skips. The
FULL guard (`tests/ci.sh guard`) runs after every shard, whatever became of
them, and is green only when every unit of the manifest executed and passed
exactly once, on its lane's platform and bash, at the run's SHA, with no
skip its lane does not allow and each unit's skipped count equal to its
skip rows. Otherwise it names each problem — a missing shard or unit, a
duplicate, another SHA, platform or bash, an undeclared or miscounted skip,
FAST evidence, an executed failure — and counts a runner never acquired and
an exhausted source download as infrastructure, apart from executed
failures.

**GNU Bash 5.3.15.** `tests/ci-bash.sh` fetches each file
`tests/bash-5.3.15.sha256` pins from GNU's mirror redirector
(`ftpmirror.gnu.org`), then `ftp.gnu.org`, then the kernel.org GNU mirror,
uses it only when its SHA-256 is the pinned one, and checks the whole set
strictly before any build; the built shell must report `5.3.15(1)-release`.
A cache holds only the pinned files, each held to its digest like a
download. When no origin delivers a file, the step exits 75, which the guard
reports as external infrastructure.

**One automatic retry.** When every job that went wrong in a run's first
attempt never acquired a runner, the verdict job dispatches a retry
controller that re-runs exactly those jobs once (`tests/ci.sh retry-signal`,
`tests/ci.sh retry`); nothing else is ever retried automatically.

**Caches.** Only the Bash source files. Cargo's registry and the Rust
toolchain are fetched each time, and no build output is cached.

## What only the real Mac can show

The hardware-only facts in docs/UPSTREAM.md → *Not verified yet*, and every
check in docs/QUALIFICATION.md → *Real-hardware qualification (M17)*: the
installers' real behaviour, the disk's real extents, 16 KiB pages under the
frontend and the agent tools, the console's glyphs, the round trip over
4 GiB, and a rerun that changes nothing.
