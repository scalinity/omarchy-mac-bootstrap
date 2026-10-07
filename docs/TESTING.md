# Testing the product expansion

**Status: the test design for M14–M16, written before the code; not
implemented.** Every id below is a planned test, not evidence: a guarantee
counts as proved only when its test exists and passes. The baseline's suite
(docs/ARCHITECTURE.md → *Tests*) stays as it is and keeps running on every
push.

## Principles

- **No machine is changed in CI.** Every Bash test runs over recorded
  fixtures, with `run` recording argv instead of running, as the baseline's
  suite does. The frontend's PTY tests drive a core in fixture mode. The
  persistence tests write only inside temporary folders.
- **The startup check is its own class.** The `frontend-check-*` tests
  drive the production route, with no fixture and no development override,
  because that route is what they prove; they do it only inside the
  hermetic boundary their own section defines (*Frontend*, below), and
  they relax nothing for the other PTY tests, which keep driving a core in
  fixture mode.
- **Both shells, both systems.** Every Bash test runs under stock `/bin/bash`
  3.2 on macOS and Bash 5 on Linux, with strict skips; a macOS-fixture
  section on Linux is gated on `plutil` as today.
- **Tests signal only what they own.** A test signals a PID it recorded when
  the process started, held to that process's start time, or a process group
  it made — never a process found by its name or command line, which matches
  the developer's own programs too (`test-owned-signal-only`, static). Each
  suite that once matched by name keeps an unrelated process with such a
  command line alive throughout, and fails if it was touched
  (`test-unrelated-matching-process-survives`).
- **The cheapest layer first.** Pure functions and state transitions carry
  most of the weight; rendered frames next; a few PTY runs last.
- **Adversarial cases are first-class.** Every protection in docs/SECURITY.md
  names the ids below that would fail if it did not hold.
- **Fixtures are generated.** `tests/fixtures/generate.sh` grows the new
  families; CI checks they are what the generator writes, as today.
- **Honest scope.** The secret tests prove what the supported adapters do
  and that opaque content needs consent. They do not prove that an arbitrary
  file holds no secret, and nothing here says so.

## New seams

| Seam | Purpose | Limits |
| --- | --- | --- |
| `sys_walk DIR` | lists a tree (type, size, mode, link text) without following links; reads `fixture/root/…` in fixture mode | read-only; in the probe allowlist |
| fixture homes | `fixture/root/Users/alex/…` synthetic macOS homes, `fixture/root/home/alex/…` Omarchy homes | generated, synthetic values only |
| `fixture/net/…` | the availability check's downloads | as `sys_net` today |
| `OMB_TEST_QUAL_BYTES` | a small size for qualification data | fixture mode only; refused as root |
| `OMB_TEST_FOUNDATION` | exactly `1` selects the fake-action foundation contract | requires a nonempty fixture and a real, non-symlink `test-children` directory; fixture data alone grants no authority; rejected by frontend-check |
| `OMB_TEST_HANDOFF_CHILD` | a test program in place of an upstream one during a handoff | fixture mode only; refused as root |
| `OMB_TEST_STOP_AT` | the core kills itself (`kill -9 $$`) right after the named persistence boundary | fixture mode only; refused as root |
| `OMB_TEST_FAIL_AT` | the checked writer fails at the named boundary as a full disk would | fixture mode only; refused as root |
| `OMB_TEST_PAUSE_AT` | the core waits at the named boundary until a flag file beside it exists, so a test can change the machine in between | fixture mode only; refused as root; runs nothing |
| `OMB_FRONTEND_DEV` | an unreleased frontend build | fixture mode only; refused as root |

Test-only hooks in the frontend (a stalled channel, a reader-thread panic on
every request or on request N, a descriptor that cannot be sealed) exist
only in builds with the `test-hooks` feature, which a release build never
enables (a CI check on the release workflow).

## Protocol and admission

### `proto-diff-*`: Bash and Rust agree, byte for byte

Every case is one document. Bash admission (docs/PROTOCOL.md → §2) and the
frontend's Rust admission must both admit it or both refuse it, with the
same reason code. The Rust side also reads every case split at **every
byte boundary** into two chunks, and one byte at a time, with the same
result (`proto-diff-chunks`).

| Id | Case | Expected |
| --- | --- | --- |
| `proto-diff-canonical` | a valid request of every operation | admitted |
| `proto-diff-nul` | NUL as the first byte, inside a value, inside a key, as the last byte | `byte` |
| `proto-diff-tab-double`, `proto-diff-tab-lead`, `proto-diff-tab-trail` | two TABs between fields; a TAB before the type; a TAB before LF | `tab` |
| `proto-diff-byte-cr`, `proto-diff-byte-ctrl`, `proto-diff-byte-del`, `proto-diff-byte-high`, `proto-diff-byte-esc` | CR before LF; 0x01; 0x7F; 0xC3 0xA9; 0x1B | `byte` |
| `proto-diff-escape-valid` | `%20`, `%25`, `%0A`, `%09` | admitted; decoded exactly |
| `proto-diff-escape-lower` | `%2f` | `value` |
| `proto-diff-escape-short` | `%4` at the end of a value; `%G1` | `value` |
| `proto-diff-escape-unneeded` | `%41`, `%2D` | `non-canonical` |
| `proto-diff-escape-nul` | `%00` | `nul-escape` |
| `proto-diff-raw-space`, `proto-diff-raw-equals` | a raw space; a second raw `=` in a value | `value` |
| `proto-diff-eof` | no LF after the last line | `eof` |
| `proto-diff-empty` | a zero-byte document | `eof` |
| `proto-diff-blank` | an empty line | `blank` |
| `proto-diff-line-long` | a line of 16 KiB + 1 | `line` |
| `proto-diff-value-long` | a value of 4 KiB + 1 as written | `value` |
| `proto-diff-request-large` | 64 KiB + 1 bytes; 513 records | `too-large` |
| `proto-diff-response-large` | a spool of 8 MiB + 1; 65 537 records | `too-large` |
| `proto-diff-header` | a wrong name; a wrong version; a missing header | `header` |
| `proto-diff-key` | an upper-case key; a key of 33 bytes; a key starting with a digit | `key` |
| `proto-diff-dup-key` | a non-list key twice | `schema` |
| `proto-diff-list` | a list key three times, in order | admitted; order kept |
| `proto-diff-unknown-key`, `proto-diff-unknown-record` | a key or record type the schema lacks | `schema` |
| `proto-diff-order` | two known keys swapped | `schema` |
| `proto-diff-missing`, `proto-diff-empty-required` | a required key absent; `key=` on a required key | `schema` |
| `proto-diff-optional-absent` | an optional key left out instead of written `key=` | `schema` |
| `proto-diff-list-empty` | `arg=` in a `bytes` list; `choice=` in an `id` list | admitted as the empty string; `type` |
| `proto-diff-dup-record` | a record the schema says is unique, twice | `schema` |
| `proto-diff-uint` | `01`, `-1`, `+1`, 19 digits | `type` |
| `proto-diff-bool`, `proto-diff-hex` | `2`; upper-case hex; hex of the wrong length | `type` |
| `proto-diff-id` | `A`, `-x`, 129 bytes, `%` inside | `type` |
| `proto-diff-text-control` | `%1B[2J` in a `text` value | `type`; the same bytes in a `bytes` value are admitted and render as `\x1b[2J` |
| `proto-diff-text-utf8` | `%C3` alone, `%C0%AF`, `%ED%A0%80` in `text` | `type` |
| `proto-diff-after-result` | a complete, canonical record after `result` | `after-result` |
| `proto-diff-after-result-partial` | bytes after the result's LF with no final LF (`result⇥…` LF then `X`) | `eof` — termination is checked before record order |
| `proto-diff-no-result`, `proto-diff-two-results` | a spool ending without `result`; two `result`s | `result` |
| `proto-diff-seal` | a stored document with a wrong seal; with bytes after the seal | `seal` |
| `proto-diff-chunks` | every case above, split at every boundary | as the case |

### `proto-*`: the core's refusals

| Id | Case |
| --- | --- |
| `proto-version` | a protocol or frontend version other than the lock's: refused, exit 3 |
| `proto-env` | each of `OMB_HOME`, `OMB_SESSION_INTENT`, `OMB_SESSION_SCOPES`, `OMB_DRY_RUN`, `OMB_SESSION_DIR` missing or malformed; `OMB_EVENTS` outside the session folder: `code=environment` |
| `proto-ceiling`, `proto-scope` | an act action in a plan session; an action outside the session's scopes |
| `proto-unavailable` | an action the fresh read does not list |
| `proto-word` | a wrong, empty, or differently-cased typed word; a word for an action with no gate |
| `proto-arg` | an argument the action does not declare; one given twice; one of the wrong type |
| `proto-handoff` | a handoff action without a terminal on 0 and 1 |
| `proto-managed-prompt` | static: every `sudo` on a managed path is `sudo -n`; stdin of a managed child is `/dev/null` |
| `proto-no-shell-text` | static: no response field and no record value reaches `eval`, `source`, `$(( ))` unchecked, or a command string |
| `proto-exit` | exit 0 with a `result`, 2 for an inadmissible request, 3 for a version refusal |
| `proto-golden-hello`, `proto-golden-snapshot`, `proto-golden-detail`, `proto-golden-validate`, `proto-golden-validate-refused`, `proto-golden-execute`, `proto-golden-approve`, `proto-golden-cancelled` | the golden requests of docs/PROTOCOL.md → *Golden examples*, against the core in fixture mode: the responses byte for byte, and the frontend's decoding of each |
| `proto-golden-codes` | each code kind as written there: `token`, `ombdone`, `ombshare`, `ombbundle` round-trip through encode, admission and the kind's semantic check unchanged |
| `proto-code-kind` | a token with an unknown field, a repeated field or 513 bytes; a code with wrong check digits; a `token` value under `kind=ombdone`; an `ombbundle` value with upper-case hex in a response: refused `type` |
| `proto-code-typed` | an approval code typed with upper-case hex and spaces: normalised as `code_parse` does, then accepted |
| `proto-invalid-schemas` | each row of the invalid-examples table there: validate without `select`, `exec` without `basis`, a code of the wrong kind, an extra field, a duplicate field, a `#` line, a record after `result`, a byte after the result's LF: the reason code shown there, in Bash and in Rust |
| `proto-op-records` | every request record placed in an operation that forbids it (a `page` in `validate`, an `arg` in `snapshot`, a `select` in `execute`): refused `schema` |
| `proto-admit-io` | `head`, `wc`, `tr`, `tail`, `od` or `awk` failing during admission — printing nothing, printing what the real tool would, or part of it, then exiting non-zero — and the last-byte check's `tr` printing exactly `0a`, then failing: refused `io`, never an empty or valid document (a tool's status is judged apart from its output) |

## Processes, descriptors and the terminal

### `sup-*`: supervision and backpressure

| Id | Case | Expected |
| --- | --- | --- |
| `sup-fd-child` | a managed and a handoff test child list their open descriptors — every one the kernel lists (`/dev/fd`: `/proc/self/fd` on Linux, the process's own table on macOS), with no range — while F holds inheritable descriptors seeded at 255, 1023, 1024, 1500 and one under its raised descriptor limit | exactly 0, 1, 2 |
| `sup-fd-grandchild` | the child starts a grandchild that sleeps 30 s and lists its descriptors the same way; the child and C exit | the grandchild holds only 0, 1, 2; F completes the request as soon as C exits and the `result` is read, without waiting for the grandchild |
| `sup-seal-failure` | a descriptor F cannot seal (test hook) | F starts no core: the text interface, with the reason |
| `sup-fd3-closed` | C lists its descriptors right after admission | fd 3 is closed before any other code runs |
| `sup-spool-handoff` | during a handoff child that runs 5 s, C appends 10 000 `progress` records | F's reader keeps them in order; nothing blocks; the child reads its input untouched |
| `sup-slow-frontend` | F's channel held full by a test hook while C runs a managed act | C finishes and exits without waiting; F then reads every record |
| `sup-overflow` | C produces more than 8 MiB − 64 KiB of `progress` | one `overflow`, then the `result`; the spool stays under 8 MiB |
| `sup-epipe` | F writes a 1 MiB request | EPIPE in F, a refusal shown; C exits 2 |
| `sup-frontend-death-core-live` | F is killed during a managed act | C completes and removes its operation record; L waits for `req-*.core` to end, then restores the terminal and cleans up as the owner |
| `sup-completion-controllers-live` | L, F and C alive in one process group; C's mutating child exits and leaves nothing behind | no worker present (every process in the group was in C's snapshot, L, F and C among them, and the `ps` taking the reading is not counted); the postcondition checked; the operation completes and its record is removed |
| `sup-completion-worker-lingers` | the child exits but a descendant it started stays in the group past the action's time limit | not completed: the operation marked unsupervised, the outcome reported unknown |
| `sup-completion-failed`, `sup-completion-unexpected` | supervised, quiescent, and the machine shows no effect; shows something else | `failed`; the record kept as `state=failed` with `finding=absent`, `finding=unexpected`; the result recorded |
| `sup-failed-blocks` | the next act in that scope; a read; a snapshot | refused `unresolved`: the operation ended but the machine does not show its expected effect — never "may still be running"; reads work; the snapshot shows the barrier and no act action in its scope |
| `sup-failed-same-boot` | in the same boot, the machine then showing the expected effect | still refused: nothing in the boot clears it |
| `sup-failed-reconcile` | a new boot, the machine showing no effect; showing something else | reconciled as no effect and the action proceeds; blocked, needing the person |
| `sup-failed-result-unrecorded` | the result cannot be recorded | `failed`, saying so; the failed record stays |
| `sup-failed-record-unwritten` | the failed record cannot be written | `failed`, saying so; the running record stays and, its core gone, refuses as unsupervised — never no record |
| `sup-identity-unknown` | `ps` fails, or the boot session cannot be read, during completion, owner cleanup or stale reclaim | nothing completed, nothing deleted, no barrier cleared: every unknown identity counts as alive |
| `sup-identity-link` | owner cleanup and stale reclaim with a core's, a worker's, `frontend.omb`'s or `launcher.omb`'s identity a link — dangling, or to an ended process's sealed identity — or a FIFO; a link in place of an operation record | nothing deleted: an identity or record is a plain file, and anything else in its place cannot be established; the same identity as a plain file lets the scratch go |
| `sup-owner-cleanup` | L exiting normally after F has exited; no core, no worker, no unresolved operation | L, itself alive, removes its own scratch |
| `sup-owner-cleanup-refused` | the same, with in turn a live core, a live recorded worker, a process that entered the group after `launcher.omb`, and an unresolved operation naming the session | L leaves the scratch each time |
| `sup-reclaim-live-controller` | L is killed while F lives between requests; a second launcher starts | the second launcher leaves the old scratch alone while `frontend.omb` — or, before that file exists, a process's arguments — names a live frontend; F keeps working |
| `sup-reclaim-live-core` | an old scratch whose launcher and frontend are dead but whose `req-<n>.core` names a live core | not reclaimed |
| `sup-reclaim-live-worker` | an old scratch whose `req-<n>.worker-<k>` names a live process | not reclaimed |
| `sup-reclaim-operation-barrier` | an old scratch named by an unresolved operation record | not reclaimed |
| `sup-reclaim-quiescent` | an old scratch whose launcher, frontend, cores and workers are dead and that no operation names | reclaimed; a launcher PID that is merely gone, with the rest alive, never is |
| `sup-pid-reuse` | session files and an operation record whose PIDs now belong to other processes (same PID, different start time), and ones from a previous boot | none of them taken as alive |
| `sup-mutating-daemon-classification` | static: a registry entry for a managed mutating child marked as detaching without an owner and check; a program known to daemonise registered as `detaches=no` in the fixture registry | refused by the check |
| `sup-core-death-mutator-live` | C is killed while its mutating child runs | outcome unknown; the operation becomes unsupervised; every act in the scope refused `unsupervised`, naming it; read commands still work |
| `sup-mutator-escaped-pgid` | C is killed; its child has started a descendant with `setsid` that keeps writing, and exits | only L and F remain in the group and no worker is present in it, and the barrier stays for the rest of the boot |
| `sup-unsupervised-blocks` | the next act in the scope, from the frontend and from `--no-tui` | refused `unsupervised` in both interfaces |
| `sup-boot-clears` | the fixture's boot session changes | the old processes can no longer hold the barrier; reconciliation is now allowed |
| `sup-post-reboot-reconcile` | after the boot change, the next act in the scope, with the machine showing no effect, and then the expected effect completed | the scope's reconciliation records that finding, removes the record, and the action proceeds |
| `sup-post-reboot-unexpected` | after the boot change, the machine shows something neither the old state nor the expected effect | the scope stays blocked with what the machine holds; the reboot is not counted as success |
| `sup-read-orphan-no-barrier` | C of a read request is killed while its read child runs on | no operation record, no barrier; the next act proceeds |
| `sup-no-reclaim-pid` | an operation record whose core's PID is dead | unsupervised, never reclaimed |
| `sup-reader-death` | the reader thread panics (test hook) | the panic hook restores nothing from the reader's thread; the outcome is unknown once C has exited, never before; a fresh snapshot is asked for |
| `sup-reader-io` | the spool's read fails (EIO) before the header, in it, in a record, after `hello`, after a whole valid `result`, before trailing bytes; the reader ends, with or without a word, while C runs on (injected readers and a live stand-in core) | never an answer from a failed read; no outcome, and so no next request, until C has exited |
| `sup-core-state-unknown` | `waitpid` on C fails (C collected by another) | the request is lost at once, not polled for ever: no further request in the session, and leaving is a failure, not the text interface |
| `sup-proctable` | a live process of the group whose command is not UTF-8, or holds `)` and spaces; a stat that cannot be read or parsed; a process gone while it is read; a macOS record refused, with and without its short record; members whose start cannot be read | read by bytes after the last `)`; a process that cannot be read is possibly present — no quiescence, no handoff snapshot — and one that has gone is absent; an unknown start never equals any start, another unknown one included |
| `sup-eintr` | a signal during a read or wait; SIGHUP every 30 ms at C through a managed act, from C's own parent | the call is retried (Rust unit test; a Bash `wait` loop test); the act completes supervised, with no barrier. On Bash 5.2 alone, a core that dies of the upstream trap loss is a skip, counted apart, only when `sup-eintr-exemption`'s rule finds the state such a death leaves; 3.2 and 5.3.15 never skip |
| `sup-eintr-exemption` | the storm's exemption, decided on made states on every shell: each of the four states a Bash 5.2 death at `lib/state.sh:269` or `lib/common.sh:155` leaves (the lock an empty folder made during the run; this request's running record, its core ended, with no worker or effect, or with its worker ended and the expected effect; the worker ended and the effect, the record removed); then a lock whose owner is alive, ended or unreadable, or an empty one from before the run; an unsupervised, failed, live-core, other-session, unreadable or too-early operation record; a live or unreadable worker; a core identity left; another effect; a result recorded; Bash 5.3 or 3.2; another exit status; any other stderr | the four exempt, removing only what that death left — the empty lock by `rmdir`, this request's own running record — and nothing outside the run's own folder; every other case judged, with nothing removed |
| `sup-eintr-exemption-prefix` | the spool such a death leaves, held to its bytes: exactly `omb-res 1`, LF, the hello this core writes in this environment (its whole answer to a hello request, admitted), LF, and the end — checked by the protocol's own admission, which may refuse it only for its missing result, then byte for byte. Made spools: a wrong or request header, one without its LF, a failed result as the header; a hello missing fields, with `%00`, a lowercase, non-canonical or raw byte, a leading or doubled TAB, a field repeated, unknown, out of order or mistyped, or another session's values; no final LF; a result, blank line, byte, partial, incomplete or whole record after the hello; the header alone; nothing | the exact prefix over either state a death leaves is exempt; every other spool is judged by the check that refuses it, over the empty lock and over the running record, and leaves each folder exactly as it was, byte for byte |
| `sup-eintr-one-substitution` | static: a command of C's own holding two command substitutions side by side | none (Bash 5.2 loses a trap that runs while one is expanded: `tests/bash-trap-comsub.sh`); the baseline's own such commands, which stay byte for byte, are the only ones the storm may name on Bash 5.2 |
| `sup-no-setsid` | static: F and C never call `setsid` or `setpgid`; L, F, C never ignore SIGINT, SIGQUIT, SIGTSTP or block them across a spawn | — |
| `sup-one-spawner` | static: F opens descriptors and spawns only on its main thread; C writes the spool only from its main shell | — |
| `sup-shared-critical` | the Shared creation over fixtures, with the spool and the recorded commands time-ordered | between the final topology read and `sudo -n diskutil addPartition`: no spool write, no process-table snapshot, no other recorded command; statically, the code between those two points is byte-identical to the accepted baseline's |

### `launcher-*`: the terminal comes back only once the session is over

L takes the terminal back — restores its settings, reports, or continues in
text — only when its wait says the session is quiescent; still running at
the wait's limit, or not knowable, it leaves the terminal and the scratch as
they are and says so.

| Id | Case | Expected |
| --- | --- | --- |
| `launcher-quiescent` | nothing recorded and nothing late in the group; a recorded core that ends within the limit | quiescent |
| `launcher-identity-corrupt` | a core's or a worker's identity file that cannot be read (torn, a folder) | unknown after 5 s, never quiescent |
| `launcher-identity-link` | a core's or a worker's identity a dangling link, or a link to an ended core's sealed identity, or a FIFO; a frontend that ends leaving a dangling core identity; a session with no `req-*` entry at all | unknown, never quiescent — a dangling link is an entry, not the absence of one; L then keeps the scratch with the link in it, says the session is not known to be over, and no text interface follows; the session with no entry is quiescent |
| `launcher-identity-unknown`, `launcher-table-unknown` | `ps` failing once no recorded PID answers: a recorded identity cannot be established; the group cannot be read | unknown |
| `launcher-identity-missing` | a process that joined the group and was never recorded | waited for as a worker: quiescent once it has gone, still active at the limit if not |
| `launcher-timeout-live` | a recorded core alive at the limit; a live PID recorded with another start | still active: the wait ends, never as quiescent |
| `launcher-no-pause`, `launcher-pause-failure` | no pause to wait on; the pause cannot be made | the wait never calls the session over; no frontend is started, the text interface instead |
| `launcher-forward-identity` | SIGTERM or SIGHUP forwarded to a PID now another process's, or to a frontend whose start was never read | not signalled; the frontend itself is |
| `launcher-frontend-death-handoff` | F killed while a handoff child owns the terminal in raw mode | L writes nothing and changes no setting until the child and C have ended; then it restores and reports |
| `launcher-identity-corrupt-handoff` | the same, with the child's identity made unreadable | L leaves the terminal as the child left it, keeps the scratch, exits 1 and says so |
| `launcher-identity-link-handoff` | the same, with the child's worker identity a dangling link, or a dangling core identity beside it | the same: the terminal as the child left it, the scratch kept with the link, exit 1, no text interface |

### `diag-*`: diagnostics by child class

| Id | Case | Expected |
| --- | --- | --- |
| `diag-bound-read` | a read child writes 10 MiB to stderr | it runs to its end unblocked; its block — header included — is at most 65 536 bytes and marks earlier output discarded |
| `diag-temp-bounded` | a read child writes 10 GiB to stderr | the temporary capture file never exceeds 65 281 bytes at any moment (sampled while the child runs), and is removed after merging |
| `diag-overflow-discard` | a read child writes exactly 65 280, then 65 281 bytes | kept whole and not marked; then the last 65 280 kept and marked discarded |
| `diag-header-counted` | read children that print nothing | each block is its header alone, and those headers count towards the request and session limits |
| `diag-request-bound` | a read request whose children together produce far more than 256 KiB | `req-<n>.diag` and `req-<n>.diag-summary` together are at most 262 144 bytes — every retained byte counted |
| `diag-budget-near-edge` | `req-<n>.diag` at 262 015 bytes (one byte of room), then a child producing 65 537 bytes | nothing appended beyond the limit (not even a header); the child counted in the summary |
| `diag-request-saturated-many-children` | a saturated request, then 10 000 more read children | the request's files do not grow by a single byte; the summary's counters change within its 128 bytes |
| `diag-session-bound` | many requests in one session produce far more than 4 MiB | every diagnostic file of the session together is at most 4 194 304 bytes |
| `diag-session-saturated-many-requests` | a saturated session, then 1 000 more requests with read children | no new diagnostic file is created; the session's total does not grow; `session.diag-summary` stays 128 bytes |
| `diag-overflow-one-summary` | overflow repeated in one request and across the session | one fixed-size summary per request file and one for the session, rewritten in place; no sequence of markers |
| `diag-capture-failure` | the drain killed mid-run; the scratch filesystem full when the drain writes | diagnostics shown as "not available"; the read judged by its own status and functional output; nothing retried because of it |
| `diag-mutator-no-backpressure` | a mutating child writes 1 GiB to stdout and stderr | nothing reaches disk or a pipe; the child is never blocked or signalled; its outcome is its exit status and the postcondition; the command is shown for running by hand |
| `diag-mutator-tty-class` | static: a registry entry with `class=mutating` and `tty=needs`; a mutating entry with `diagnostics` streams | refused by the check: a child that needs a terminal is a handoff |
| `diag-functional-not-budgeted` | a qualification step writing its 4 296 015 889-byte stream, an export writing its objects | untouched by the diagnostic limits: they are functional output with their own bounds |
| `diag-handoff-not-captured` | a handoff child prints to the terminal | nothing of it in the scratch |
| `diag-raw-sensitive` | a read child prints a planted token | it appears only on the log screen from `req-<n>.diag`; never in `debug`, `debug context`, a record, the log file or the state directory |
| `diag-class-static` | static: every child the core runs has a registry entry; no mutating child has a pipe on 1 or 2 | — |

### `pty-*`: the real terminal

Run with `portable-pty` and `vt100` on real macOS arm64 and Linux aarch64
runners.

| Id | Case | Expected |
| --- | --- | --- |
| `pty-pgid` | during a handoff, the terminal's foreground process group (`tcgetpgrp`) | the job's group, holding L, F, C and the child |
| `pty-ctrlc-idle` | Ctrl-C on the dashboard | F quits, terminal restored |
| `pty-ctrlc-child` | Ctrl-C during a handoff to a child that prints and exits on SIGINT | the child gets it; F and L survive and redraw after a fresh snapshot |
| `pty-sigterm`, `pty-sighup` | each sent to F, idle and during a handoff | the terminal restored; a non-cancellable request finished first |
| `pty-tstp` | Ctrl-Z idle; SIGTSTP to the group during a child; then SIGCONT | everything stops together and continues; F re-enters and re-derives |
| `pty-dispositions` | the handoff child reports its SIGINT, SIGQUIT, SIGTSTP dispositions and its signal mask | default dispositions, empty mask |
| `pty-termios` | the child leaves the terminal without echo and in raw mode | F restores its saved settings on re-entry; on exit the settings equal the ones before start |
| `pty-no-steal` | the child reads 100 keys and a cursor-position reply | the child receives all of them; F consumed none |
| `pty-exit`, `pty-panic` | normal exit; an injected panic on the main thread | alternate screen left, cursor shown, settings equal to the original |
| `pty-reader-panic` | the reader thread panics (test hook) on an idle refresh, during a managed act whose core runs on, and while a handoff child owns the terminal | the owner keeps the terminal: no restore sequence, raw mode and the alternate screen as they were (during the handoff, the child's foreground group and settings, nothing written); the outcome only after C exits; the panic reported after the final restore; nothing left running |
| `pty-hangup` | the terminal closes idle, during a managed act and during a handoff | F, L, C and the child end; a supervised act still completes; the scratch is removed |
| `pty-resize` | resize to 60×20 and below | the layout follows; below the minimum, the too-small state |

## Actions and bases

### `stale-*`: what was reviewed is what runs

| Id | Case | Expected |
| --- | --- | --- |
| `stale-dest-changed` | a restore item reviewed with destination A; another process writes B; execute | refused `changed`; nothing written; B untouched |
| `stale-dest-absent` | reviewed as absent; a file appears; execute | refused `changed` |
| `stale-param-changed` | validate with size X; execute with the basis for X and the argument Y | refused `changed` |
| `stale-generation` | paging a detail across a new inventory generation | refused `changed`; no mixed rows |
| `stale-between-items` | a three-item restore; item 2's destination changes after item 1 is placed | item 2 stops as a conflict; items 1 and 3 complete |
| `stale-last-instant` | with `OMB_TEST_PAUSE_AT` after the re-check, the test creates a file at an absent destination; in a second run, changes a destination being replaced; in a third, creates a folder where a folder unit goes | `ln` refuses and the new file is untouched; the moved file is not the reviewed one, so it is renamed back; `mv --update=none-fail` refuses; all stop as conflicts |
| `stale-setting-before-recheck` | a Git setting changed after the review and before the re-read | the item stops as a conflict; nothing written |
| `restore-setting-verified` | a Git setting and a Claude Code MCP server written by their owners' commands | each read back with the intended value; a different value is reported as a failure |
| `stale-lock-order` | two executes of one scope at once | the second is refused busy; the basis comparison happens after the operation record exists (checked by the recorded order) |
| `stale-plan-geometry` | the disk changes between the plan review and `plan.save` | refused `changed` |
| `stale-shared-final` | the partition table changes after the basis check but before the final read (`OMB_TEST_AFTER`) | the baseline's final revalidation refuses; nothing created |
| `stale-display-id` | two bases sharing their first 8 hex digits | the 64-digit comparison tells them apart |

### `equiv-*`: the accepted baseline is the oracle

Docs: *Equivalence with the accepted baseline*, below. One id per exposed
baseline action: `equiv-plan-save`, `equiv-backup-gate`,
`equiv-asahi-fetch`, `equiv-asahi-launch`, `equiv-network`,
`equiv-omarchy-start`, `equiv-omarchy-resume`, `equiv-shared-create`,
`equiv-shared-activate`, `equiv-shared-test`.

## Migration

### `scan-*`: the scanner

| Id | Case |
| --- | --- |
| `scan-no-tool` | over `mac-home-typical`, the recorded probes include no package manager or inventoried tool, and no path under a tool's own `bin/` |
| `scan-requested-unknown` | a receipt without `installed_on_request`; a formula without a receipt: `requested=unknown` |
| `scan-contradiction` | a receipt naming an absent tap; two linked versions: the disputed field `unknown`, the item kept |
| `scan-service-configured` | a LaunchAgent plist: `configured`, running `unknown` |
| `scan-partial` | an adapter over its budget: `partial`, never a short complete list |
| `scan-denied` | a protected folder that denies: `denied`, never empty |
| `scan-go-buildinfo` | a Go binary with and without embedded build information |
| `scan-contract-unknown` | a Homebrew layout outside the adapter's contract: `unknown` |
| `scan-duplicates` | node from Homebrew, nvm and mise: one software id, instances per version |

### `zsh-*`: the Bash extraction

| Id | Case | Expected |
| --- | --- | --- |
| `zsh-alias-literal`, `zsh-export-literal` | `alias ll='ls -l'`; `export EDITOR=nvim` | imported |
| `zsh-alias-dollar`, `zsh-alias-backquote`, `zsh-alias-bang` | `$`, a backquote or `!` in the value | review-only |
| `zsh-heredoc` | `alias x='y'` inside a here-document | not imported |
| `zsh-function-body` | an alias line inside a function | not imported; the function is review-only code |
| `zsh-multiline-string` | an alias line inside a multi-line quoted string | not imported |
| `zsh-continuation` | a line ending in `\` before an alias line | the joined line is judged; not imported |
| `zsh-cmdsubst`, `zsh-conditional` | an alias inside `$( … )`; an export inside `if` | review-only |
| `zsh-source` | `source ~/.aliases` | review-only; the sourced file is not read |
| `zsh-untrackable` | an unterminated quote at line 10 | every line from 10 on is review-only |
| `zsh-export-other`, `zsh-path` | an export not on the allowlist; `PATH` | review-only; `PATH` never |
| `zsh-global-alias` | `alias -g` | review-only |
| `zsh-shadow` | an alias named `ls` | shown beside Omarchy's |

### `toml-*`: the strict subset reader (Codex, mise)

| Id | Case | Expected |
| --- | --- | --- |
| `toml-codex-written` | files shaped exactly as Codex 0.157.1 writes them: quoted server names, `[mcp_servers.x.env]`, single-line arrays, float timeouts, `[[skills.config]]`, `[projects."/p"]` | accepted; every value exact |
| `toml-docs-shapes` | the documentation's inline `env = { … }`, multi-line arrays with comments and a trailing comma, literal strings, quoted dotted keys | accepted |
| `toml-dotted` | `a.b.c = 1` and `a.b.d = 2` in one table | accepted; both under the table `a.b` |
| `toml-dotted-redefine` | `a.b.c = 1` followed by `[a.b]` (the dotted key already defined the table `a.b`) | the whole file refused |
| `toml-dotted-subtable` | `a.b.c = 1` followed by `[a.b.x]` (a sub-table of a table defined by dotted keys) | accepted |
| `toml-bounds` | a file of 1 MiB + 1; nesting of arrays and inline tables 17 deep; a line of 16 KiB + 1 | the whole file refused |
| `toml-conformance` | every case of the `toml-test` corpus (pinned by digest): each invalid case | refused; each valid case either refused as outside the subset, or accepted with exactly the corpus's decoded values |
| `toml-multiline` | `"""…"""` with a line-ending backslash; `'''…'''` with a first newline | accepted; decoded as TOML does |
| `toml-duplicate`, `toml-table-twice`, `toml-key-and-table` | a key twice; a table twice; a key used as both | the whole file refused |
| `toml-datetime`, `toml-hex`, `toml-underscore`, `toml-inf` | each | the whole file refused |
| `toml-inline-multiline`, `toml-inline-trailing` | TOML 1.1 inline-table forms | the whole file refused |
| `toml-crlf`, `toml-bad-utf8`, `toml-control` | each | the whole file refused |
| `toml-refused-carries-nothing` | a refused `config.toml` | nothing from it in the bundle; the review names line and construct |
| `toml-paths` | `/opt/homebrew/bin/x` in `command`, in `args`, in `cwd`, and in a comment | rewritten in the three fields only |
| `toml-mcp-env` | `[mcp_servers.gh.env] GITHUB_TOKEN = "ghp_…"` | the value absent from the bundle; `env_vars = ["GITHUB_TOKEN"]`; `needs-secret` |
| `toml-secret-fields` | `bearer_token`, `http_headers` values, credential-named query parameters | absent from the bundle, listed |
| `toml-profile` | a top-level `profile`, `[profiles.x]` | not carried |
| `toml-merge` | a Linux `config.toml` with other servers | new keys before the first table, new tables after the end, nothing existing edited; the result re-read by the reader |
| `toml-target-refused` | a Linux file the reader refuses | Keep or Replace only |

### `dag-*`: the graph

| Id | Case | Expected |
| --- | --- | --- |
| `dag-deterministic` | one selection in 20 shuffled inventory orders, under Bash 3.2 and 5, `LC_ALL=C` and a UTF-8 locale | byte-identical order |
| `dag-tie-break` | nodes ready together | layer, then kind, then id bytes |
| `dag-same-layer` | tool B requires tool A, both layer 3, B first in the inventory | A before B |
| `dag-shared-provider` | three consumers of `cap:node` major 22 | one instance |
| `dag-versions-conflict` | consumers needing node 22 and 24 | a decision; side by side offered because mise supports it |
| `dag-versions-unsupported` | a provider without side-by-side support and no common version | the consumers `unsupported` |
| `dag-cycle` | A requires B requires A | both and their dependants `needs-decision`; the cycle shown |
| `dag-optional` | an optional edge to a failed node | the consumer `degraded`, not blocked |
| `dag-alternative` | an `ALTERNATIVE` and two equal-rank providers | decisions, never a silent pick |
| `dag-conflicts` | pacman `nodejs` and `mise node` both first on `PATH`; a registry conflict | a decision; never ordered, never both |
| `dag-failure` | a failed instance | every `requires` dependant `blocked` with the chain |
| `dag-skip` | a need whose provider the person left out | its consumers blocked, unless the capability is already satisfied |
| `dag-rerun` | a rerun after a failure | failed and blocked nodes retried; verified ones untouched |
| `dag-bounds` | 5 001 nodes; 20 001 edges | refused |
| `dag-mcp-chain` | the two examples in docs/RESOLVER.md | exactly those nodes and edges |

### `bundle-*`: export, approval and import

| Id | Case | Expected |
| --- | --- | --- |
| `bundle-valid` | a complete bundle | imported after the right code |
| `bundle-recomputed` | an object changed, its digest, the manifest and the seal recomputed | integrity passes; the approval code does not match; refused |
| `bundle-active-config` | `init.lua` replaced the same way | refused |
| `bundle-code-typo`, `bundle-code-other` | one character wrong; the code of another export of the same profile | caught by the check digits; refused as a mismatch |
| `bundle-code-required` | any restore action before a code is entered | refused |
| `bundle-approval-rerun` | a restore approved and interrupted; the bundle then changed and recomputed | the next run asks for the code again, and the old code does not match |
| `bundle-object-link`, `bundle-object-special`, `bundle-object-hardlink`, `bundle-object-name` | an object that is a link, a FIFO or folder, has two links, or a name that is not 64 lower-case hex digits | refused |
| `bundle-object-mismatch`, `bundle-seal-bad` | a changed object; an edited manifest | refused |
| `bundle-incomplete` | a missing object; a truncated object; a `.partial-` folder | refused |
| `bundle-cross-item` | two items with one `dest`; a file where another item needs a folder; a `dest` beneath a `link` entry | refused before anything is placed |
| `bundle-traversal` | `dest` of `../x`, `/etc/x`, `a/../../b`, `%2E%2E/x`, an empty component, a control character, outside its item | refused |
| `bundle-link-escape`, `bundle-link-chain` | link text leaving the item's root; a link through another link | skipped at export; refused at import |
| `bundle-case-distinct`, `bundle-unicode-distinct` | two `dest`s differing only in case; in normalisation | both placed (Linux keeps them apart); a warning |
| `bundle-modes` | setuid, world-writable, private classes | capped as docs/RESTORE.md says |
| `bundle-extra-files` | `._*`, `.DS_Store`, unreferenced objects | ignored and counted |
| `bundle-foreign`, `bundle-token-mismatch` | another host's bundle; a profile id the token does not name | typed `import`, and still its own code |
| `bundle-forged-cleanup` | a folder that looks like a bundle, with a README, and no export record | never removed |
| `bundle-size` | a 65 MiB file; a 2 GiB + 1 selection | skipped `too-large`; refused until raised |

### `secret-*`: what the adapters guarantee

| Id | Case | Expected |
| --- | --- | --- |
| `secret-unknown-key` | a supported adapter's file with a credential under an ordinary key (`sessionKey`) | not carried: not on the allowlist |
| `secret-whole-file-caught` | a Neovim Lua file with a planted `ghp_…` token (a shape the scan knows) | the scan catches this planted example and the file is excluded — which shows the scan works on it, not that whole files are free of secrets it cannot recognise |
| `secret-whole-file-marked` | a whole file carried | marked "carried whole" in the review and the manifest's item; no output says it holds no secret |
| `secret-opaque-default` | the same file in a custom path | excluded until typed `opaque`; the warning shown; then carried and marked outside the guarantee |
| `secret-opaque-hard` | `.env`, `id_ed25519`, `credentials` inside an opaque folder | refused even with consent |
| `secret-url` | `https://user:pass@host`, `?token=…` in a supported field | dropped, flagged |
| `secret-git-remote` | a remote with a token in it | dropped, shown for re-entry |
| `secret-args` | MCP `args` with `--api-key sk-…` | the value dropped; `needs-secret` |
| `secret-env` | MCP `env` values in each tool's format | never in the bundle; references instead |
| `secret-deep` | a token at 5 MiB into a carried text file | found by the whole-length scan; the file excluded |
| `secret-toctou` | a file changed between selection and export | the captured bytes are classified; a file now failing is left behind |
| `secret-keychain` | `credential.helper osxkeychain`, a `security` command in `apiKeyHelper` | dropped, flagged |
| `secret-ssh-encrypted` | an `openssh-key-v1` key with `aes256-ctr` and bcrypt 16 rounds | carried only after typed `carry`; 0600; never in a preview, log or report |
| `secret-ssh-refused` | an unencrypted key; a PEM key; bcrypt 8 rounds; an unknown cipher; a malformed envelope; over 16 KiB | refused |
| `secret-provenance` | every record and log written by export | no value of any planted secret |

### Profiles, registry, availability, MCP

| Family | Cases |
| --- | --- |
| `profile-*` | `profile-sealed`, `profile-held` (a held decision blocks finishing), `profile-stale` (another host), `profile-invalid` (a bad seal), `profile-old-schema` (read for display only), `profile-select-file` (an unknown id refuses the file) |
| `registry-*` | `registry-exact`, `registry-provided`, `registry-alternative`, `registry-unknown`, `registry-x86`, `registry-sync-repo` (a target only in a `Usage = Sync` repository), `registry-bad16k`, `registry-local-override`, `registry-malformed` |
| `avail-*` | `avail-alarm-db` (separate `depends` files), `avail-omarchy-db` (zstd, provides in `desc`), `avail-flathub`, `avail-mise-lock` (the person's mise configuration never loaded), `avail-hostile-db` (`..` and absolute member names) |
| `mcp-*` | `mcp-brew-path`, `mcp-secret-env`, `mcp-oauth` (an HTTP server with OAuth, never `codex mcp add --url`), `mcp-metachar` (arguments with `;` and `$(…)` kept as one argument each), `mcp-macos-only` |

## Restore

### `restore-*`: placement and review

| Id | Case | Expected |
| --- | --- | --- |
| `restore-root` | `restore` with `EUID` 0 | refused |
| `restore-link-parent` | a link on the way to a destination | the item stops; nothing followed |
| `restore-conflict-keep` | every kind of conflict with no choice made | Keep; nothing written |
| `restore-replace` | Replace | the old file in `backups/<run>/`, the new one placed |
| `restore-merge` | a Git ignore file, Git settings, MCP servers, JSON settings | exactly the merge docs/RESTORE.md defines, `jq` filters constant |
| `restore-modes` | setuid, group- and world-writable modes in the manifest | capped; private classes 0600/0700 |
| `restore-seeded` | Omarchy's seeded `starship.toml` | a conflict labelled "Omarchy's default" |
| `restore-untouched` | `/usr/share/omarchy`, `~/.local/state/omarchy`, the skill links, the wrappers, `defaults/agent` | byte-identical after the restore |
| `restore-backup-cross-device` | a Replace whose destination is on another device than the backups | the item refused (Keep or Skip); nothing copied or overwritten |
| `restore-place-exact` | with `OMB_TEST_PAUSE_AT` before placing, the destination becomes in turn a directory, a symbolic link to a directory, a file and a FIFO | `ln -T`, `ln -s -T` and `mv -T --update=none-fail` each fail; nothing is created inside the directory or through the link; the item stops as a conflict |
| `restore-folder-fs` | a folder unit on a filesystem outside btrfs, ext4, xfs, tmpfs | the folder unit refused; files still placed |
| `restore-open-writer` | a program holds the reviewed file open and writes after it was moved aside | its bytes end in the backup, not the destination; the summary names the backup (the stated residual, shown, not detected) |
| `restore-consent` | `restore verify` with and without consent | no MCP server or application started without it |
| `restore-accept` | `restore accept NAME` | an `accepted` step; shown as accepted, never verified |

### `persist-*`: every boundary, then the next run

For each boundary *B* — `intent`, stage partial, stage complete, `staged`,
backup renamed, backup copy partial, `backed-up`, placed, `placed`,
`verified`, `failed`, `undo-intent`, undo applied, `undone` — two tests run
on the runner's real filesystem (APFS on macOS, ext4 on Linux):

| Id | Case | Expected |
| --- | --- | --- |
| `persist-death-<B>` | `OMB_TEST_STOP_AT=<B>` kills the core right after *B* | the next run's judgement matches docs/RESTORE.md → *After a crash*; the final home equals an uninterrupted run's |
| `persist-full-<B>` | `OMB_TEST_FAIL_AT=<B>` fails the write as a full disk would | the item `failed`; only names an intent records remain; the next run completes |

And:

| Id | Case | Expected |
| --- | --- | --- |
| `persist-full-real` | the Linux job mounts a 1 MiB tmpfs (the runner's `sudo`) as the home and restores a 2 MiB file | as `persist-full-*`, from the real error |
| `persist-torn-record` | a record temporary cut short | ignored; removed inside `steps/` |
| `persist-name-taken` | a record's final name already exists | the rename refused; nothing overwritten |
| `persist-fifo` | a FIFO at a stage name before creation | refused before opening |
| `persist-cleanup-fails` | the stage file cannot be removed | reported; removed by the next run |
| `persist-foreign-temp` | a similar name that no intent records | reported, left |
| `persist-undo-changed` | the file edited after the restore | undo refused, the file untouched |
| `persist-undo-git`, `persist-undo-mcp`, `persist-undo-shell` | a Git setting, an MCP definition, the marked line changed after the restore | refused |
| `persist-undo-folder` | a created folder that now holds a new file | refused |
| `persist-rerun` | a second restore after `complete` | no write, every item already in place |

### `omarchy-*`: Omarchy's ownership

| Id | Case | Expected |
| --- | --- | --- |
| `omarchy-lazy-probe` | `doctor`, `restore status` and the rescue screen over a fixture with Omarchy's wrappers and shims on `PATH` | no command recorded; static: no probe names `~/.local/bin`, a shim, `mise` or an agent |
| `omarchy-pin-kept` | mise configuration pinning `claude = "2.1.0"` | shown as selected; the file's digest unchanged |
| `omarchy-wrapper-only` | wrapper present, no install folder | `wrapper_present`, not `artifact_installed` |
| `omarchy-artifact-only` | an install folder, no wrapper | `artifact_installed`; the wrapper's absence reported |
| `omarchy-foreign-binary` | `~/.local/bin/claude` a link into `~/.local/share/claude/versions` | left alone; not overwritten by `restore` or `dev` |
| `omarchy-duplicate` | a vendor install and a mise install | both reported; nothing removed |
| `omarchy-install-cmd` | `install` for Claude Code | the recorded argv is the wrapper's own `mise use -g --quiet claude`, with `MISE_MINIMUM_RELEASE_AGE=0` |
| `omarchy-helper-lies` | `omarchy-pkg-add` exits 0; `pacman -Q` finds nothing | `failed`, "skipped by the helper" |
| `omarchy-explicit-build` | an approved `go install` | runs; recorded as a build |
| `omarchy-no-implicit-build` | mise, cargo-binstall, uv and pipx installs | the recorded argv disables source builds; an unsupported package never becomes a build |
| `omarchy-default-agent` | a restore with three tools | `omarchy-default-agent` never run; `~/.config/omarchy/defaults/agent` unchanged |
| `omarchy-dev-shared` | `dev`'s AI module and `restore` installing Claude Code | the same recorded argv |

### `debug-*`: the report

| Id | Case | Expected |
| --- | --- | --- |
| `debug-fields-only` | `debug` on every lifecycle fixture | every line admits against the `omb-debug 1` schema; every value an enum, version, bounded id, count or size |
| `debug-planted` | tokens, URLs with passwords and host names planted in the journal, the log and the state | none in `debug` or `debug context` |
| `debug-root` | `debug context` as root and as the user | "this session runs as root" only as root |
| `debug-brief-split` | `debug context` | the fixed text byte-identical to `data/agent-brief.md`; observed data only inside the data block |
| `debug-raw` | `debug raw` | headed POTENTIALLY SENSITIVE; never written into the rescue workspace |
| `debug-intent` | `debug`, `debug context`, `debug raw` | the filesystem unchanged (snapshot as in `test-routing.sh`); `debug save` writes only its two files, 0600 |

### `rescue-*` and `ssh-*`

| Id | Case | Expected |
| --- | --- | --- |
| `rescue-offline`, `rescue-not-aarch64`, `rescue-lowmem`, `rescue-nospace` | each | `unavailable` with the reason |
| `rescue-installer-cwd` | the Claude Code install | run as real root from an empty workspace folder, never under `sudo` |
| `rescue-workspace` | the workspace after a start | `AGENTS.md` is the brief, `CLAUDE.md` imports it, `report.omb` is the safe report, each tool's rules file denies the disk, boot and encryption commands; nothing under `/etc` written |
| `rescue-start-fails` | `--version` fails | `failed`; the next tool offered |
| `rescue-leftovers` | seen by the everyday user | listed from rescue's record |
| `rescue-remove-exact` | `rescue remove` | exactly what rescue's record lists as rescue's is removed; a released harden drop-in stays and is named; everything else untouched |
| `ssh-fresh-image` | the image's shape: enabled, running, no `Match`, password on, `alarm` | `exposed`, shown before any rescue |
| `ssh-match-unproven` | a `Match Address 10.0.0.9` block with passwords on, in `sshd_config`; in an included drop-in; in a file included by an included file; written `match=…` in lower case | `unproven` in every case; harden refused |
| `ssh-keyonly-proven` | no `Match`, `sshd -T` key-only | `key-only` |
| `ssh-other-listener` | a second `sshd` listening outside the system unit | `unproven`; stopped with the typed word before remote rescue opens |
| `ssh-case` | `sshd -T` output in mixed case | read correctly |
| `ssh-close` | close on an exposed server | stopped for this boot, never disabled; the screen says it starts at the next boot |
| `ssh-harden-offline` | harden on a `Match`-free exposed server | the drop-in checked with `sshd -t -f` and `sshd -T -f` on a private copy before it is installed; installed; reloaded; `sshd -T` key-only; released and recorded as released |
| `ssh-harden-disagree` | the check after the reload disagrees with the offline one; and, separately, the reload fails or `sshd -T` cannot be read | `sshd` stopped for this boot and checked stopped; the unverified drop-in removed while it is stopped; never left or restarted running with the old exposed configuration; reported |
| `ssh-harden-no-include` | `sshd_config` without the `Include` first | harden refused |
| `rescue-sshd-config-exact` | the rescue configuration | its bytes equal what the tool wrote; `sshd -t -f` passes; `sshd -T -f` shows exactly the listed values |
| `rescue-sshd-invalid` | `sshd -t -f` fails | nothing started, nothing listens, the system's server unchanged |
| `rescue-sshd-port` | 2222 in use; every port 2222–2229 in use | the next free port; refused |
| `rescue-sshd-address` | the chosen address gone before start | refused before start |
| `rescue-sshd-exposed-first` | the system's server exposed, and unproven | stopped (typed `ssh` covered it) and checked stopped before the rescue unit starts (recorded order); remote rescue never open while it listens |
| `rescue-sshd-keyonly-untouched` | the system's server key-only | left running and untouched |
| `rescue-sshd-key-login` | the generated configuration run by a real `sshd` in a container on the Linux runner, with the throwaway key | login succeeds with strict host-key checking against the rescue key; the throwaway line removed afterwards |
| `rescue-sshd-wrong-key` | the same server, with a key not in the rescue file, and with no key | refused |
| `rescue-sshd-start-fails` | the unit fails, or the listener or the key login check fails | the unit stopped; nothing listens on its port; not open |
| `rescue-sshd-dies` | the rescue unit's process dies while open | the screen shows it stopped; nothing restarts it |
| `rescue-sshd-cleanup` | `rescue remove` | the unit stopped and inactive, its port free, `/root/omarchy-rescue/ssh/` gone |
| `rescue-sshd-no-restart` | the system's server was stopped by rescue | still stopped after cleanup; the screen says it starts at the next boot and offers harden |
| `rescue-sshd-cleanup-verify-fails` | a check at the end of cleanup fails | "not clean", no success reported |

## Qualification

| Id | Case | Expected |
| --- | --- | --- |
| `qual-vector-key`, `qual-vector-17`, `qual-vector-mib` | the reference key, first 17 bytes, first MiB (docs/QUALIFICATION.md → *The stream*) | equal, on LibreSSL (macOS) and OpenSSL (Linux) |
| `qual-vector-2to32` | the MiB at offset 2³², generated from its counter and cut from a stream | both equal the reference |
| `qual-vector-full` | the full 4 296 015 889-byte stream | the reference digest (once per job) |
| `qual-counter-wide` | chunks starting at 2³², 2³⁶ and the last block | equal to the same slices of the whole stream |
| `qual-producer-fails` | `openssl` missing or failing | the step fails; `PIPESTATUS` shows it |
| `qual-writer-fails` | the writer fails part-way | the step fails; files kept; the expected digest unchanged |
| `qual-short` | a file one byte short | failed |
| `qual-interrupted-source` | step 1 killed before `round.omb` | nothing awaits Linux |
| `qual-interrupted-dest` | step 2 killed | `in-progress`; restarts from its first check |
| `qual-stale-round` | an old, valid, passed round on Shared, not named by `active.omb` | never current |
| `qual-two-rounds` | two rounds awaiting Linux | Linux `blocked`, both named |
| `qual-new-round-refused` | macOS starts a round while one it created is unfinished | refused until `qualify clean` |
| `qual-replay-cleaned` | macOS creates and cleans a round before Linux sees it; a copy of its step-one files is put back on Shared | Linux accepts it as a provisional candidate and runs step 2, saying *provisional*; macOS refuses step 3 for it (not its active round); the round never passes |
| `qual-linux-provisional` | Linux after step 2 | its state and records say provisional until macOS reads the round back; never "current" or "qualified" |
| `qual-round-records` | a round's life on macOS | `created.omb`, then `finished.omb`, then (after `qualify clean`) `cleaned.omb`, three files each written once; `active.omb` never names the round after `finished` or `cleaned` |
| `qual-round-invalid` | `finished.omb` without `created.omb` | invalid: treated as cleaned, reported |
| `qual-finished-after-cleaned` | a cleaned round, then step 3 or anything else asking to write its `finished.omb` (which does not exist yet) | refused by the state machine — no transition leaves `cleaned` — before any file is opened |
| `qual-round-rewrite` | an attempt to write a state file of a round that already exists (`created.omb` twice) | refused by exclusive creation; the existing file unchanged |
| `qual-artifact-mismatch` | a stage whose recorded frontend artifact digest is not the one the lock of its commit pins | the terminal evidence of that stage does not count towards M18 |
| `qual-wrong-partition` | a USB volume named Shared with a valid copy of the manifest | never opened |
| `qual-other-plan`, `qual-wrong-guid`, `qual-bad-seal` | each | `blocked` before any write |
| `qual-names` | the case pair on exFAT | the second recorded as a collision; the first untouched |
| `qual-no-space` | free space one byte under the formula | `blocked` with the numbers |
| `qual-clean-foreign` | a file the schema does not name in a round folder | left, reported |
| `qual-cleanup-fails` | a file that cannot be removed | reported; no success |
| `qual-source-mismatch` | a stage whose executed-source digest differs from its commit's | not counted towards M18 |
| `qual-evidence-scope` | a change to `lib/frontend.sh` only | the terminal evidence invalid; geometry and Shared creation evidence still valid |

## Frontend

### `frontend-*`: distribution and intent

| Id | Case | Expected |
| --- | --- | --- |
| `frontend-lock-not-input` | a commit changing only `release/frontend.lock` | `inputs_digest` unchanged |
| `frontend-input-source-change` | a commit changing a file under `frontend/src/` without a new release | `inputs_digest` changes; the CI comparison with the lock fails |
| `frontend-input-candidate-released` | the released inputs, and the lock check and `candidate` on them | `lock` passes and the launcher's reader admits the lock; no candidate is named by an unchanged release, and the release's own version is never one |
| `frontend-input-candidate-same-version` | changed inputs with the crate still at the release's version | `lock` fails; `candidate` fails for that version and for any newer one the crate does not hold |
| `frontend-input-candidate-classified` | the next version in both `Cargo` files with changed inputs | `lock` still fails; `candidate` passes for exactly that version, says *unreleased* and claims no equality, and leaves the release's lock untouched |
| `frontend-input-candidate-version-expected` | a candidate version the crate does not hold, an older one, and `0.2`, `v0.2.0`, `0.2.0-rc1`, `01.2.0` and the empty string | refused |
| `frontend-input-candidate-cargo-lock` | `Cargo.toml` at the candidate version and `Cargo.lock` at another | refused |
| `frontend-input-candidate-protocol` | a core whose protocol the pinned release does not speak | refused, naming both |
| `frontend-input-candidate-lock-admission` | the production lock; then locks changed and **resealed**, so only the schema can refuse them: a duplicated artifact target, an artifact missing a field or with a non-numeric size or a short digest, two frontend records, an artifact before the frontend record, an unknown field on either record, no artifact, an unknown record type, another header, a comment line, a blank line, a lower-case percent escape, a raw space, carriage returns, a seal with no final line feed; and one lock edited after sealing | `candidate` stops at admission exactly when `rec_admit_file lock` of that commit refuses the bytes, and names the same reason; a resealed lock is never refused for its seal, the stale one only for its seal; an admitted lock that fails later (a protocol, a digest) is refused for that reason and never as an admission failure |
| `frontend-input-candidate-malformed-lock` | no `release/frontend.lock` at the commit | refused: there is no release to differ from |
| `frontend-input-candidate-release-intact` | a lock whose digest its source commit does not hold; a source commit absent from the checkout; a release tag naming another commit; no tag at all; then the tag naming the source commit | the first four refused, the last passing and its report naming the tag |
| `frontend-input-candidate-identical` | inputs equal to the lock's under an older lock version | refused: it is the released frontend, and the lock check applies |
| `frontend-input-candidate-ci-version` | the workflow's named candidate version and the crate's | equal; CI runs the exact lock check first |
| `frontend-input-release-strict` | the release workflow | never runs `candidate` |
| `frontend-input-cargo-lock` | a commit changing only `frontend/Cargo.lock` | the same |
| `frontend-input-toolchain` | a commit changing only `frontend/rust-toolchain.toml` | the same |
| `frontend-input-test-asset` | production code with `include_bytes!("../tests/schema.bin")`; a commit changing only that file | `inputs_digest` changes (tests are inputs); the closure check passes |
| `frontend-input-include-outside` | `include_bytes!` or `include_str!` of a file outside `frontend/`, and of an untracked file inside it | the closure check fails: the path is in rustc's dependency file and not a tracked input |
| `frontend-input-build-rs` | a `build.rs` in the frontend's own package, with and without reading an asset | refused by the `cargo metadata` check |
| `frontend-input-local-path-dependency` | a `path` dependency outside `frontend/`; a `git` dependency; a `[patch]` section | refused |
| `frontend-input-local-crate` | a path package under `frontend/` whose crate includes a file outside it; its library, which the build compiled, with no dependency file in the folder checked | the closure check fails, naming the target and its package |
| `frontend-input-env-dep` | production code reading `env!()` of an unapproved variable; `option_env!()` of an unset one; `CARGO_PKG_REVIEW_INPUT` set, and unset through `option_env!()`; `CARGO_PKG_FAKE`; `CARGO_MANIFEST_DIR`; `CARGO_PKG_VERSION`; `CARGO_PKG_NAME` and `CARGO_PKG_AUTHORS` | all but the last two fail the closure check (the environment is an input the listing does not hold); the approved set is the fourteen names Cargo 1.88.0 sets from the tracked `Cargo.toml` (docs/FRONTEND.md → *Four identities*), never a prefix |
| `frontend-input-target-evidence` | a library `omb_tui` and a binary `omb-tui` in one package, and a binary `omb-tui` beside another local package's library `omb_tui`; each one's dependency file taken away alone; the library's file in the binary's place; another build's file of the same crate name beside them; another build's messages, or ones without the build's end | each target the build compiled is bound to a dependency file of its own, and every removal, substitution or foreign message set fails naming the target and its package; a file no target is bound to is not read |
| `frontend-input-generated-target-excluded` | a `target/` folder and an untracked file under `frontend/` present when the digest is computed | the digest unchanged (computed from the commit); the release build refuses to start on an unclean tree |
| `frontend-input-cargo-config` | a `.cargo/config.toml` at the repository root; `RUSTFLAGS` set in the release workflow | refused (the repository check; the static check of the workflow) |
| `frontend-input-link` | a tracked symbolic link under `frontend/` | the listing refuses |
| `frontend-input-order` | the listing under `LC_ALL=C` and a UTF-8 locale | byte-identical |
| `frontend-digest` | a mismatch on download and in the cache | never run |
| `frontend-offline`, `frontend-unrunnable` | no cache and no network; wrong architecture, exit 126/127 | text, with the reason |
| `frontend-dev` | the override outside fixture mode, or as root | refused |
| `frontend-compat-linux` | the Linux artifact | interpreter `/lib/ld-linux-aarch64.so.1`; `DT_NEEDED` within the allowed set; highest `GLIBC_` ≤ 2.39; every `LOAD` aligned ≥ 0x4000; no allocator crate in `Cargo.lock` |
| `frontend-compat-macos` | the macOS artifact | arm64 only; `minos` 13.5; `codesign -v` passes |
| `frontend-intent-read`, `frontend-intent-plan`, `frontend-intent-dry-run`, `frontend-intent-no-tui` | a corrupted cache and `OMB_TUI_LOG` set, for each | the filesystem outside the scratch folders unchanged: nothing moved, no trace |
| `frontend-intent-act` | the same in an act session | the move offered and done after a yes; the trace written 0600 |

### `frontend-check-*`: the startup check

docs/FRONTEND.md → *The startup check*; docs/PROTOCOL.md → *The
startup-check session*.

**The boundary.** Each case runs a copy of the tool's checkout in a
temporary folder, with a temporary `HOME`, `XDG_CACHE_HOME`,
`XDG_STATE_HOME` and `TMPDIR`; with `OMB_STATE_DIR` unset, and no
`OMB_FIXTURE`, `OMB_FRONTEND_DEV` or `OMB_TEST_`-prefixed variable set
except where a case sets one on purpose; and with curl's own configuration
file and proxy variables cleared. The copy's `release/frontend.lock` is a
test lock: it pins the native release build CI already makes for the PTY
tests (no `test-hooks` feature), or for a failure case a stand-in program
built for that case, each by its size and SHA-256, at an
`https://127.0.0.1:<port>/…` URL served by a loopback HTTPS server the test
owns, with a certificate valid for that address. The server's throwaway
certificate authority is trusted only through curl's own `CURL_CA_BUNDLE`
in the test's environment, because the launcher accepts only HTTPS; the
implementation confirms that both runners' `curl` honours it before a case
counts, and a runner whose `curl` does not is reported for review, never
worked around with a launcher seam. So acquisition runs its normal path —
`curl`, the size, the digest, the promotion into the cache — and nothing
bypasses it. Every persistent write lands in the temporary cache; nothing
is fetched from outside the loopback; no baseline probe or action runs; the
runner's real root cache is never seeded or changed (a root-cache case is
covered at the cache-selection helper, over a temporary folder standing in
for it); and the actual release is proved only by
`frontend-check-production-mac`.

**Two kinds of evidence** (docs/FRONTEND.md → *The command's result*): the
cases below that expect `completed` hold the command's result — exchanges,
lifecycle, measured terminal settings. Only `frontend-check-terminal` and
`frontend-check-production-mac` are rendering evidence, and neither counts
a run whose dashboard was not seen.

| Id | Case | Expected |
| --- | --- | --- |
| `frontend-check-route` | the command, on a terminal, warm cache; statically, its route | the frontend starts with the session values of the check; the route calls none of the installer's routing (`mac_main`, `lx_main`), `resume`, the command handlers, the run lock or the log's start line, and its snapshot path calls no barrier read, reconciliation or operation-record function |
| `frontend-check-default-unchanged` | the bare command over every baseline fixture, as text and on a terminal | recorded commands, records, output and status equal those of `569d67e` (the commit before the route) |
| `frontend-check-install-unchanged` | `install`, and every other command of SPEC.md → *Commands*, the same way | equal to `569d67e`'s |
| `frontend-check-no-fixture` | a completed check | the core's `hello` says `fixture=0`, `ceiling=read`, `dry_run=0`; the cores' environment held no fixture, development or `OMB_TEST_`-prefixed variable; the frontend's header shows neither fixture nor dry-run tag |
| `frontend-check-overrides-refused` | each of `OMB_FIXTURE`, `OMB_FRONTEND_DEV`, `OMB_TEST_ARTIFACT`, `OMB_TEST_HOOK`, `OMB_TEST_HANDOFF_CHILD`, `OMB_TEST_RECORD`, `OMB_TEST_AFTER`, `OMB_TEST_RC`, `OMB_TEST_QUAL_BYTES`, `OMB_TEST_STOP_AT`, `OMB_TEST_FAIL_AT`, `OMB_TEST_PAUSE_AT` and the invented `OMB_TEST_FUTURE=x` set non-empty; an extra argument; each of them with stdin not a terminal as well | status 2 before anything else, the terminal's eligibility not consulted: no connection to the server, no lock read, no cache, no scratch, no frontend; the same variables still work for the commands and tests that own them |
| `frontend-check-seam-controls` | `OMB_TEST_FUTURE=` (empty), `OMB_TESTING=x`, `OMB_TEST=x`, `SOME_OMB_TEST_X=x` | not refused by the seam rule: the classifier does not over-match. The run goes on to whatever the rest of the flow decides; this case proves only the classifier |
| `frontend-check-cold-cache` | empty cache; yes to `[Y/n]` | the provenance shown; one HTTPS request; the attempt file held to size and digest, then promoted to `<sha256>/omb-tui` (0700); the frontend started from there; `completed` |
| `frontend-check-decline` | empty cache; no to `[Y/n]` | no request made; no cache folder made; `not-completed`, status 1 |
| `frontend-check-warm-cache` | the pinned file already cached | no request made; the file hashed before it starts; `completed`; the cache byte-identical |
| `frontend-check-bad-cache` | a user-cache file of the right name with other bytes; the move declined; then accepted; at the cache-selection helper, a failing root-cache copy with none of the user's | never executed in any case; declined: `not-completed`, the file untouched; accepted: renamed `omb-tui.mismatch-<stamp>`, the pinned file downloaded and promoted, `completed`; the root copy never moved, the user's own acquired |
| `frontend-check-mismatch-then-download-fails` | the move accepted, then the server refuses, cuts the file short, or serves other bytes | the backup stays; this attempt's file removed once its writer ended; nothing promoted or run; `not-completed` |
| `frontend-check-mismatch-then-interrupted` | the move accepted, then Ctrl-C, and separately SIGTERM, while the server stalls the download | the backup stays; the attempt file removed once the writer ended; Ctrl-C status 130, SIGTERM `not-completed`; nothing promoted or run |
| `frontend-check-promoted-then-exec-fails` | cold cache, the verified stand-in promoted, and it will not execute | the promoted binary stays cached; `unrunnable`, `not-completed` |
| `frontend-check-promoted-then-startup-fails` | cold cache, promoted, then in turn the core refusing `hello` (the lock naming another frontend version) and a stand-in whose snapshot is refused | the promoted binary stays cached; `not-completed` |
| `frontend-check-cleanup-fails` | a stalled download interrupted after the test has made the digest's folder unwritable | the attempt file stays and the report names it; the folder is not called empty; nothing else removed; `not-completed`, no installer routing |
| `frontend-check-uncatchable-residue` | the launcher, recorded at its start, sent SIGKILL during a stalled download | a `.omb-tui.*` attempt file may remain; no success is reported. A following run never selects, runs or promotes it: it starts only a verified `<sha256>/omb-tui`, acquiring one first when there is none |
| `frontend-check-residue-never-selected` | an attempt file and a mismatch backup, each holding exactly the pinned bytes, beside a missing `omb-tui` | neither is selected, run or promoted; acquisition is offered as for an empty cache; neither is removed |
| `frontend-check-read-session` | a stand-in frontend that records its environment and each core's `hello` | `OMB_SESSION_INTENT=read`, `OMB_SESSION_SCOPES=journey`, `OMB_DRY_RUN=0`, `OMB_SESSION_PURPOSE=frontend-check`; every `hello` `ceiling=read`, `dry_run=0`; an inherited `OMB_SESSION_PURPOSE` of any value is replaced; in every other session the launcher starts, it is absent |
| `frontend-check-purpose-env` | the core with the purpose and, in turn, another intent, other scopes, `OMB_DRY_RUN=1`, `OMB_FIXTURE`, `OMB_FRONTEND_DEV`, `OMB_TEST_HOOK` or `OMB_TEST_FUTURE` non-empty; the purpose empty; an unknown purpose. Controls: `OMB_TEST_FUTURE=`, `OMB_TESTING=x`, `OMB_TEST=x` | every operation `result status=error code=environment`; the controls are not refused by the seam rule |
| `frontend-check-snapshot` | `snapshot scope name=journey` in a check session | admitted by both admissions; exactly the records of docs/PROTOCOL.md → *The startup-check session*, in order; the records after `hello` byte-identical on refresh and across runs of one checkout |
| `frontend-check-zero-actions` | the same, with an unsupervised and a failed operation record placed in the temporary state folder's `ops/` | no `action`, `param` or `stage` record; no operation state shown; both records byte-identical before and after |
| `frontend-check-forbidden-scope` | `snapshot` of each other scope | `refused`, `code=scope`, with the `generation` of the empty data set |
| `frontend-check-execute-refused` | `execute` of `test.read`, `test.mutate`, `test.handoff`, an unknown action, a valid-looking basis and word, with arguments | `refused`, `code=unavailable`, before any lock, operation record, basis or child: nothing recorded, nothing written, no child started |
| `frontend-check-detail-refused`, `frontend-check-validate-refused` | `detail` with a page; `validate` with a `select` | `refused`, `code=unavailable`; the `detail` refusal with the `generation` of the empty data set |
| `frontend-check-no-state` | every case above | the temporary state folder never created, or byte-identical where it was placed: no state, log, lock, plan, operation record or download |
| `frontend-check-no-install-fallback` | each failure: an inadmissible lock, no artifact for the target, a declined download or move, a refused connection, a wrong size, a wrong digest, a stand-in that will not execute, the core refusing `hello`, a stand-in that asks for another scope's snapshot and exits 10, a stand-in that prints the released frontend's "continuing in the text interface" and exits 10, a stand-in that exits 0 before asking for any snapshot, a crash, a session left unsettled | each `not-completed` or `unsettled` with its reason, status 1; no installer routing, prompt, probe, lock or log reached — nothing of `mac_main` or `lx_main` in the output or the recorded order |
| `frontend-check-early-quit-late-snapshot` | a stand-in that sends `hello`, asks for the snapshot, and exits 0 without reading the answer, while its core finishes afterwards with a valid action-free snapshot | the command's result follows only *The command's result*, here `completed`; its report claims no drawing. The same run offered as rendering evidence fails: the PTY harness's own check, run over a recorded screen that never left the connecting screen, rejects it |
| `frontend-check-refresh-failure` | a stand-in whose first snapshot answers `done`, then asks again and gets a refusal, and separately an incomplete answer (its core killed), then exits 0 | `not-completed`, status 1: any exchange not ending `done` forbids `completed` |
| `frontend-check-no-render-claim` | the report of every `completed` case; statically, the launcher's report text | no word saying the dashboard was drawn, shown or received; it names the exchanges and the session's end |
| `frontend-check-termios` | the saved settings unreadable; the restore failing; a stand-in that changes the terminal's settings in a way the restore does not return (the readback differs) | `not-completed`, status 1, each: `completed` needs saved, restored and read-back-equal settings |
| `frontend-check-completion-order` | the recorded order of a completed check; a scratch that cannot be removed | spools admitted after quiescence and before owner cleanup; the settings restored and read back before cleanup; `completed` only after the scratch is confirmed gone; nothing read after it; a scratch left behind gives `not-completed` |
| `frontend-check-ineligible-terminal` | `--no-tui`; stdin not a terminal; stdout not a terminal; `TERM` unset; `TERM=dumb` | `not-performed`, status 1: no lock read, no cache inspected, no request made, no scratch, no frontend or core |
| `frontend-check-dry-run-ineligible` | `--dry-run --no-tui`; `--dry-run` with stdin piped; with stdout not a terminal; with `TERM=dumb` | the ineligible branch wins: `not-performed`, status 1, no lock read, no cache inspected |
| `frontend-check-dry-run` | `--dry-run` on an eligible terminal, cold and warm | the lock may be read and the cache inspected; the artifact and the cache state reported as `would run`; `not-performed`, status 1; no request made, nothing moved, no file in the cache, no session scratch, no frontend or core started |
| `frontend-check-cleanup` | a completed check; the frontend killed while idle | the per-run and session scratch removed only once the session is quiescent, under docs/PROTOCOL.md → *The session scratch*; the killed case reports `crashed` and `not-completed` |
| `frontend-check-terminal` | real PTY on both arm64 runners: the command, warm cache, the native build | rendering evidence, from the screen, never from the spools: the connecting screen gives way to the dashboard, so the frontend consumed the snapshot; the four facts and "Nothing is available now." visible; a key (`?` then back) answered; `q` exits; the alternate screen left, the cursor shown, the settings equal to the ones before; the report `completed`, status 0. A run whose screen never showed the dashboard fails, whatever the report said |
| `frontend-check-lock` | the copy's lock changed: another digest, another size, another version, no artifact for the target, a broken seal | never a binary the lock does not pin; each `not-completed` with its reason; a version other than the frontend's refused by the core as `frontend` |
| `frontend-check-production-mac` | acceptance only, by hand on this Mac: the reviewed remediation checkout, its committed production lock and the published `frontend-v0.1.0` macOS artifact, acquired on the normal path or found verified in the cache, no fixture, development or `OMB_TEST_` seam set | the `hello` and snapshot exchanges answered; the dashboard seen with its four facts and "Nothing is available now."; `q` leaves; the terminal visibly normal and its settings as before; no process of the session left and its scratch gone; no baseline state or action (MILESTONES.md → *Gate 1 — Frontend and transport foundation*, Exit); recorded with the cache path and digest, the core's `hello`, and the terminal before and after. Status 0 alone is not this evidence |

**Effects.** Around each case below the test snapshots the temporary
`HOME`, cache, state folder and `TMPDIR` (type, mode, size and digest of
every entry) before and after, and judges the difference relative to the
phase the case reached (docs/FRONTEND.md → *Effects*): a consented earlier
phase legitimately stays, so a case is never expected to leave the cache as
it found it once such a phase ran. Only the listed paths may differ; in
every case the state folder is unchanged or absent and no installer routing
is reached:

| Case | May differ from before |
| --- | --- |
| cold cache, completed | `<cache>/<sha256>/omb-tui` added (0700), with any folder of its path made for it (0700) |
| warm cache, completed | nothing |
| download declined | nothing |
| move declined | nothing |
| move accepted, then completed | `omb-tui.mismatch-<stamp>` added, and `omb-tui` replaced by the verified file |
| download fails, wrong size or wrong digest | the folders made for the attempt; no attempt file; no `omb-tui` |
| move accepted, then the download fails | `omb-tui.mismatch-<stamp>` in place of the old file; no attempt file; no `omb-tui` |
| a handled interruption before promotion | as the download failing, including a backup already made |
| move accepted, then a handled interruption | the backup stays; no attempt file; no `omb-tui` |
| the attempt file's removal failing | as the interruption, plus the named attempt file |
| an uncatchable death before promotion | as the interruption, plus possibly one `.omb-tui.*` attempt file |
| promoted, then the frontend will not execute | as cold cache: the verified file stays |
| promoted, then `hello` or the snapshot refused, or a refresh failing | the same |
| normal quit | the same as completed, cold or warm |

In `TMPDIR`, nothing may remain after any case except a session scratch the
launcher reported as not known to be over, and whatever an uncatchable
death left.

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

### `bench-*`: the O1 benchmark (M14 gate 2)

BENCH-M01 is the sole blocker from the independent V-to-B instrument review.
The bounded timing-decomposition remediation is a candidate awaiting closure,
with the harness UNACCEPTED and O1 PENDING. `bench/README.md` → *BENCH-M01
diagnostic internal observations* defines every source boundary, applicability,
copy transformation, receipt/ack overhead limitation, supplementary schema and
permanent phase proof. Complete totals keep their original stopwatch/budgets;
separate companions provide startup/admission/owner-probe populations and
complete macOS Validate probe/computation populations. No subtraction, additive
claim, phase budget, product timing in normal tests or full O1 campaign is
authorized. The matrix remains 102 workload cases across cold/warm lifecycles.
Multi-sample cold collector regression tests keep each ordinary sample's exact
private state/log paths and prepared projection for its own companion, using
separate fresh sessions and no product latency clock. Equality remains exact.

The benchmark-only candidate is documented in `bench/README.md`. Its explicit
runner separates list mode, three-repetition NON-AUTHORITATIVE smoke and future
200-repetition capability. Ordinary Bash tests and the existing frontend
`contract` integration target discover deterministic methodology/work tests;
the timing entry is ignored and never runs beside those suites. Harness tests
and smoke do not establish budget satisfaction or O1 signoff.

The resumed candidate strengthens detail-page witnesses: an untimed snapshot
and full projection are acquired in a separate preparation session. Each
measured Journey, Doctor or Logs page must match the requested generation and
the exact ordered slice of every prepared row field. Both preparation requests
are counted outside timing; the cold benchmark session remains unused until
its measured detail request. This reference proves paging equivalence against
the real producer, rather than serving as an independent product oracle.

Run on macOS arm64 and Linux aarch64, cold (first request after start) and
warm, with a small inventory (50 items) and a representative one (2 000
items, 400 profile entries), 200 repetitions each; the time is split into
core start-up, admission, and probes.

Two families are reported apart. The core's are measured over the ordinary
fixture-backed read operations gate 2 implements (`snapshot`, `detail` and its
paging, `validate`), with one review-resolved exception at accepted V
`b01610e69a2eef6e5a52f5ede18236210699704e`: `bench-snapshot` measures the
already accepted fixture-free `frontend-check` startup-check snapshot.
The frontend's — navigation, search, and render — run over
fixed synthetic loaded data of both sizes wherever the real dataset does
not exist yet; neither family is measured over a smaller workload for want
of a later feature. A workload proves its work before it is timed (the rows
and records it returns are at least the expected count), and one that
returns none is invalid, not fast. The benchmark never runs beside the test
suite. Each result records the source commit, the system and runner, the
Bash version, the frontend build, the workload and fixture, the iterations,
warm-ups and samples, p50, p95, p99, the maximum, and the failures and
timeouts.

| Id | Operation | Budget |
| --- | --- | --- |
| `bench-nav` | navigation/focus plus resulting render | p95 < 50 ms, zero core requests |
| `bench-search` | search/filter over loaded data plus resulting render | p95 < 100 ms, zero core requests |
| `bench-snapshot` | a small snapshot that reads no disk | p95 < 500 ms |
| `bench-validate` | production validation computation after authoritative inputs are loaded | p95 < 300 ms |
| `bench-disk` | full current internal-disk planning refresh plus status work; macOS journey snapshot and machine/status detail | investigate p95 > 2 s; not a hard pass/fail threshold |
| `bench-journey-linux` | Linux journey snapshot and machine/status detail | p95 < 500 ms |
| `bench-health` | future health snapshot/detail, full Doctor owner including fixture-backed network checks | investigate p95 > 2 s |
| `bench-logs` | future logs snapshot/detail, real source selection plus bounded 40-line window | p95 < 500 ms |

**Review-resolved `bench-snapshot` target at V.** This is the core-only complete
`omarchy-bootstrap core snapshot` request, dispatched through `core_main` →
`core_check_op` → `core_check_snapshot` / `_core_check_body`. The session has
purpose `frontend-check`, intent `read`, scopes `journey`, and dry-run `0`.
`OMB_FIXTURE` and `OMB_FRONTEND_DEV` are unset or empty, and no nonempty exported
`OMB_TEST_*` variable is present. Protocol is 1; the request frontend version
is the unchanged production lock's `0.1.0`. No frontend executable runs.

The monotonic interval starts immediately before launching the fresh Bash core
process and ends immediately after observing and reaping its exit. It includes
startup, library loading, request copying/admission, session/identity/source
and lock checks, hello, snapshot/generation construction, spool publication,
result, and request-private cleanup before exit. Controller session/request/
header-spool preparation and finished-response verification are outside it;
so are statistics, frontend cache/acquisition/startup, terminal setup and render.
The existing p95 < 500 ms budget applies to this whole interval. "No disk"
means no storage/disk survey, not zero filesystem I/O.

Each cold repetition starts a fresh controller/session whose first core
request is this snapshot; no standalone hello precedes it. A warm group starts
a fresh controller/session, verifies one untimed snapshot, then measures later
snapshots in that same session, each in a fresh Bash process. No OS caches are
flushed and no response/admission is bypassed. Future full mode uses 200 cold
repetitions in fresh sessions and 200 warm repetitions after that one warm-up
on each required arm64 platform.

After reaping, canonical admission and an exact semantic witness are required:
truthful hello (source/commit, native platform/architecture, protocol 1,
read ceiling, dry-run 0, fixture 0); one generation with total 0 and the SHA-256
of the four canonical fact lines joined by LF without a trailing LF; exactly
the accepted `check`, `interface`, `session`, `actions` facts in that order;
and one final `done ok` result with empty text/next. No other records qualify.
The four facts prove work even though total is 0; refusals do not. This one
exception changes neither ordinary producer fixture rules nor D53's separate
50/2,000-item and 400-profile-entry frontend obligations. The foundation's
`core_op_snapshot` is not this target. The mapping was clarified by independent
review after the pre-implementation semantic STOP; it was not previously explicit.

Q5 is **RESOLVED FOR MEASUREMENT**; actual O1 signoff is pending. These are
normative future measurement contracts only: CP1 implements no benchmark
harness. Journey detail recomputes the whole dataset, so both kinds use their
platform's journey workload with detail labels, including limits 1/500 and
representative offsets. A one-row detail is not local navigation.

`bench-validate` includes parsing, normalization, `plan_init`, `plan_compute`,
`plan_validate`, `plan_layout`, `plan_verify`, basis construction and response
preparation/admission. It excludes preceding machine-probe acquisition and
request startup/admission. `plan_init` is arithmetic over loaded facts and
belongs inside the component. The future complete macOS Validate request is
also `bench-disk` with a validate label, investigating p95 > 2 s, with probe
and computation components reported separately. On Linux arm64 the future
loaded-input component uses a fixed documented macOS planning capture and is
labelled platform execution of that component, not a native Linux macOS-disk
probe. An unavailable Linux Validate request is not a sample.

Frontend-local navigation/search timing includes the resulting visible render;
a separate render diagnostic does not replace those budgets. For synchronous
reads, progress within 100 ms is a future frontend-local initiation-feedback
requirement: pending/running within 100 ms of accepting refresh. It is not a
snapshot/detail progress record or proof from receiving hello; it needs no
percentage and claims no partial/new dataset. Core-only measurements mark it
not applicable rather than passed. Response cardinality is unchanged.

D53's both arm64 systems, cold/warm, 200 repetitions per specified case,
50/2,000-item models, 400 profile entries and all source/build/work witnesses
remain binding. No-work or refused results are invalid samples. Cold is the
documented first request after start, not a claim of privileged OS cache flush.

### CP1 scope compatibility tests

CP1 is admission compatibility only. The shared corpus keeps every pre-CP1
document and adds scope cases across request scope/page, response fact/action
and sealed operation records. No second schema parser is an oracle.

| Id | Case | Must hold |
| --- | --- | --- |
| `cp1-scope-*` | journey, health, logs and unknown/punctuation/case controls across every shared scope schema | Bash/candidate Rust agree; only health/logs are added |
| `cp1-old-language` | corpus generated by accepted closeout C, compared with CP1; actual C Bash/Rust admission | unchanged document bytes and verdict/reason/line for every old case |
| `cp1-frozen-parser` | actual record implementation extracted from C and released source S, executed by temporary integration tests in owned scratch | old journey controls admit; health/logs requests and fact responses reject; the test must run |
| `cp1-runtime` | actual core, fixture/non-fixture, included/missing/mixed session scopes, both snapshot/detail kinds | S4 Logs and Health only in ordinary fixtures with included scope, missing scope refused first; probes identical to existing hello setup (Health: followed only by one Doctor capture's reads), producer read intent/zero persistence, no effect/action/operation record |
| `cp1-old-responses` | C vs current hello, settled journey snapshot, both details and startup-check snapshot | exact byte preservation after truthful hello commit/source normalization is the default; the ONE reviewed CP1-PLIST-M01 exception below permits only its proven blocker, derived guide and whole-generation correction; released parser admits actual current responses |
| `cp1-released-frontend` | exact native production-lock 0.1.0 artifact, downloaded into owned scratch and verified by size/SHA-256, then existing frontend-check harness | both arm64 CI jobs execute it against CP1 core; candidate native check also stays green |

**CP1-PLIST-M01 (Class D) is the one reviewed preservation exception.**
It applies only to the existing roomy macOS fixture in controlled no-saved-
progress state after proving its single disk0s2 store, the reached failed
optional second-store extraction and its fixed known missing-key stdout, the
exact frozen mac.1 blocker/empty fix, the exact derived cannot-continue guide,
and valid admitted done/ok snapshots. Current correctness is unconditional:
no blocker and exactly "Run `./omarchy-bootstrap` to survey this Mac and plan
storage." The general hello-only normalizer is unchanged. An independently
verified generation replaces only that field; exactly one witnessed blocker
is removed and exactly one witnessed guide corrected. All other snapshot bytes,
encoding/order/result and total=0 remain exact.

Both full datasets are rebuilt independently from snapshot payload and full
status then machine projections, with read.sh's final-LF stripping semantics;
each emitted SHA-256 must equal its rebuilt hash, and the defect hashes differ.
Each core receives its own snapshot generation for both complete offset=0,
limit=500 detail requests. Totals/rows/order/results/next remain exact after
only verified generation and hello identity normalization. Both cross-
generation directions for both kinds must admit refused/changed, no rows,
the receiving fresh generation/total and the exact existing changed text.

A supplementary real C/current causal control changes only the target failed
extraction's stdout (fixed diagnostic vs empty), keeping status 31 and all
other native extractions unchanged, with target hit witnesses. C changes only
the blocker/guide/generation; current ignores that failed stdout. The same
exception comparator rejects scratch mutations of signatures, witness, facts,
messages/code/rows, results, order, totals and either emitted generation.
Native non-leaking C, Linux and startup-check keep ordinary exact comparison.
Historical language/parser and runtime-authority controls remain unchanged.
Exports are the actual unnormalized current snapshot/detail bytes, including
the corrected guide and real generation; unchanged Rust executes the released
frozen parser over them. No future owner delta inherits this exception.

The frontend-check harness's explicit artifact-version test input belongs only
to the test driver. Its default is the current crate version; no OMB_TEST_
input reaches the launcher's sealed environment. Published-artifact runs
reuse the same native PTY/dashboard/lifecycle evidence and no-probe/action,
no-fixture, no-production-seam and cleanup assertions. The admitted production
lock owns download URL, size and digest; neither it nor published artifacts
are modified.

### Gate 2 read tests

S4's `test-gate2-logs.sh` covers baseline sorted-path selection despite mtime,
absence/selected-empty, writer parsing and opaque rows, raw blank/unterminated
windows, value/byte boundaries, whole-window off-page overflow precedence,
generation changes and paging, metadata failures and read effects.
S4-H01 derives `getconf NAME_MAX` from the real test filesystem: a missing
NAME_MAX-byte ASCII component stays ordinary absence, while NAME_MAX+1 returns
the canonically admitted empty-generation `error io` response for snapshot
and detail, before stale-generation or empty-page handling. The complete
ASCII path fits Protocol metadata; actual-core taps prove read intent, zero
persistence and no action/lock/state/log/run/download/operation effect.
S4-H02's native macOS block independently identifies the scratch volume using
`df` and `diskutil` and runs only on verified APFS. It creates, observes and
removes the exact `e` + U+0301 component repeated 100 times (300 UTF-8 bytes),
then drives ordinary core snapshot, matching empty detail and repeat snapshot
against that now-missing raw spelling. A supplementary-plane create/remove
boundary witness distinguishes UTF-16 units from byte/scalar approximations.
The stock macOS CI job supplies this APFS evidence; Linux and target Bash
continue the ASCII H01 and generic Logs tests without an APFS emulation or
additional counted skip. Native-query execution and unusable-output faults
also drive real core and must produce the admitted empty-generation I/O result.
Production uses Darwin's read-only `faccessat(F_OK, AT_SYMLINK_NOFOLLOW)` through
system JXA for missing Darwin paths, letting the actual filesystem resolve
the original complete Logs pathname and each unresolved component at the
existing searchable ancestor. Ordinary absence requires full-path ENOENT and
success/ENOENT for every component; full-path success in the missing branch
fails closed as inconsistent. It selects no Unicode metric and normalizes no
pathname. Linux retains its byte-limit guard.
S4-H03 characterizes a Protocol-representable path with four independently
legal decomposed components. If full native lookup returns ENAMETOOLONG,
the real-core failure is labeled NATIVE; a host without that boundary uses
an explicitly labeled INJECTED CLASSIFIER BOUNDARY. Snapshot and stale,
legal-absence and large-offset details must return the admitted empty-generation
I/O result. A separate injected full-lookup success tests the inconsistent
missing branch; a native early-missing/later-invalid component control proves
component probes remain necessary. Read-effect taps and scratch cleanup apply
to all these requests. The macOS job supplies this classification evidence.
`test-gate2-logs-proof.sh` holds the unchanged text owner to BASE byte for byte,
journey snapshot/details to accepted CP1 P (only hello commit/source differ),
and proves one capture, exact original bytes, source/selection mutation
isolation, private preflight and retained-admitted-copy publication. It injects
discovery (including real State-parent and higher-ancestor search-permission
failures), sort, vanished source, selected read, scratch write/read, staging,
admission, retained-copy, hash and publication-preparation faults: `error io`,
no candidate records, independently admitted fixed safe responses. A partial
or empty failed Bash line read must not masquerade as EOF: reconstruction
must equal the original raw bytes before row admission. A partial
transport append remains incomplete. Both suites match `gate2-*`, so Linux,
stock macOS Bash 3.2 and pinned target Bash 5.3.15 run them without new skips.

S4's `test-gate2-health.sh` drives the actual core through a copied tool whose
taps count `cmd_doctor` invocations and record its status while it still runs.
Each snapshot is exactly generation (`total=0`), the three `doctor.*` facts
and `result done ok`; each detail is every finding, one-based, in owner
order, sharing that generation. `pass`/`warn`/`fail` rows equal the facts,
`info` rows count toward none, and every request captures Doctor exactly
once under read intent and zero persistence. `doc_summary` ends a completed
owner with status 0 exactly when no check failed and 1 otherwise, so a
report with failures (`linux-alarm-offline`'s Network, a copied fixture's
Disk space) is `done ok` with status 1, and a passing one has status 0.
Copied fixtures change an owner-observed detail, an off-page severity and
an info finding's presence: each changes the generation, an old one is
`refused changed` with the fresh one and no rows, and restoring the fixture
restores it. Paging traverses limits 1, 7 and 500, `offset` at and beyond
`total`, stale and other-scope generations, malformed pages (admission, no
capture) and an unknown kind (no capture). An owner-produced Distribution
detail of 5000 bytes, or with a control byte, at row 4 makes snapshot, an
early page, a stale generation and `offset` at or beyond the otherwise
current total all `error representation`, with no candidate record or
echo. Scope missing, non-fixture and startup-check requests capture
nothing. At every ceiling, with and without saved state, `log_event` is
reached only by `doc`, under read/0; no action, lock, state, run, download,
operation record, forbidden command or state byte appears.
`test-gate2-health-proof.sh` runs the extracted BASE `cmd_doctor` over every
baseline fixture through `tests/gate2-doctor-oracle.sh`, a test-side tap on
BASE's `ui_tag`, and holds the current owner, BASE's text command and the
typed reads to it: findings, counters, status, probes and diagnostics; typed
rows equal BASE's byte for byte, both reads' probes are the hello setup then
exactly one BASE Doctor's, and typed rows and counts rendered through BASE's
own `ui_tag` and `doc_summary` reproduce BASE's doctor lines, summary and
exit status. Saved-state findings (backup, saved plan) are compared too.
It proves one capture, isolation from source mutation after capture and
from staging mutation after admission, retained-admitted-copy publication
and no cross-request cache. Owner faults (row and count retention, a fifth
status, a finding emitted where its count is lost, status 1 without a
failure, 0 with one, or 2, counter drift, an aborted owner, an unsupported
platform) and machinery faults (tally, staging, admission, retained copy,
hash, publication preparation) are each `error io` with the fixed safe
response, also ahead of a stale generation and an offset beyond the total;
a partial append stays incomplete. Counters left in the calling shell
neither reach a capture nor are changed by one. Synthetic `doc` sequences
prove the generation binds finding order and label. Both suites match
`gate2-*`; macOS fixture sections are the existing `t_plutil` skips on Linux.

HEALTH-H01: `core_read_rows`, which preflights Journey's machine and status
rows and Health's rows (Logs stages its window directly), succeeds only when
every retained row was read. A `while read` loop ends on EOF and on a read
error alike with status 0, so the helper counts the rows it read and
requires that count to equal the file's `wc -l` count, with no unterminated
bytes left. Every caller's file is whole LF-terminated canonical rows
(`rec_line` output or `awk` records), so equal counts prove every byte was
read. `test-gate2-read.sh` drives the real helper loop into a real builtin
read failure (stdin closed at read N): 0, 2, 500 and 501 rows succeed with
every row staged for admission; a failure before row 1, after row 1 or
after one complete 500-row batch, and an unterminated tail, return 1.
`test-gate2-health.sh` injects that failure only at `core_read_rows` over
`health.rows` in the actual core, with a hit witness: before any row, after
one row, and before the owner's unrepresentable row 4, the snapshot, a
stale generation, the last valid generation's first page and `offset` at
and beyond the otherwise current total are each `error io` with one Doctor
capture; the same owner data read completely remains `error
representation`. The proof suite adds the failure to its in-process fault
table and its stale-generation and offset precedence loop.

Validate's `test-gate2-validate.sh` drives the actual core through a copied
tool whose taps count `mac_detect` captures with their intent and refuse
every effect a read must not reach. Routing: another `select` family, a
Linux fixture and a non-fixture macOS session are `refused unavailable`
before the scope, a session without `plan` is `refused scope`, all with no
capture; malformed requests stay admission failures; `execute plan.save`
stays unavailable; no journey or logs snapshot lists an action, and the
foundation harness and the startup check keep their own refusals. Unknown
names are reported first in byte order (`a-c` before `a_c` and `ab`) with no
capture, even on a machine nothing can be planned on. Every finite code is
driven with its fixed text, Shared first (Linux never evaluated after a
Shared refusal, Shared's normal kept when Linux fails), including the bare-0
sentinel under every surrounding blank, `0GB`/`0%`/`00`, invalid bytes and
whitespace-only values. Spellings that floor to one whole-GB size bind one
basis, with the baseline's notices; `max` is the Shared-adjusted maximum.
Answers, warnings and blocker/install/`PLAN_ERR` explanations are compared
with the planner's own output over the same fixture: free space, resizes,
Shared lowering Linux's maximum, minimum and maximum boundaries, the
below-recommendation warning, two separate gaps, 512-byte sectors, every
blocker fixture, every install fixture, and the unknown resize limit split
(a copied `mac-m1-free-space` without its limits answer). The owner's
`plan_verify` band on `mac-m1-free-space` is `error invariant`. Geometry,
input and answer changes change the basis; restoring a fixture restores it.
At every ceiling, with saved choices present (which never reach a
validation), nothing is written and no generation appears.
`test-gate2-validate-proof.sh` holds the planning owners to BASE byte for
byte, the probes to hello's then BASE's planning entry's (the Asahi state
only where an install is on the disk; none for an unknown name), and the
answers to BASE's planner over a request matrix. It rebuilds the
`omb-validate-geometry 1`, `omb-validate-plan 1` and `omb-basis 1` preimages
independently and holds the core's to them byte for byte and the review
basis to their SHA-256. A machine changing right after the capture changes
neither response nor basis while a later request sees it; a capture that
went wrong is not re-read. The spool is the admitted document byte for byte,
also when the staging file changes after admission, with only header and
hello live meanwhile. Answer and extent seams change the basis alone. Hash,
scratch, staging, prefix, admission, retained-copy and publication faults
are `error io`; a `plan_verify` violation, an unknown `parse_size` refusal
and a contradictory `plan_validate` verdict are `error invariant`; an
over-long or control-byte explanation is `error representation`, and `error
io` when admission itself fails first. Each has its hit witness, one
capture, the fixed result after hello alone and no effect; a failed append
leaves an incomplete transport. Success, invalid, unplannable, io,
invariant and representation each leave state, fixture, home and scratch
untouched at every ceiling. Both suites match `gate2-*`; their macOS
planning sections are `t_plutil` skips on Linux.

| Id | Case | Expected |
| --- | --- | --- |
| `read-effect-*` | every gate 2 read — `hello`, `snapshot`, each `detail` kind and page, `validate` — over every baseline fixture, under the purity checks of `tests/test-routing.sh` (`expect_pure`, `t_snapshot`) | nothing recorded but read probes; no state, log, plan or record file; nothing outside the session scratch; no `sudo`, installer or forbidden command; nothing left in `TMPDIR` |
| `equiv-read-*` | each gate 2 surface over every baseline fixture, against the oracle `2edb76a` | the typed fields equal the baseline's, in order; the probes recorded equal the baseline command's; only listed, reviewed deltas differ |
| `page-*` | an empty kind, one page, many pages, the last page, `offset` at and beyond `total`, `limit` 1 and 500, a kind the scope does not have | the answers docs/PROTOCOL.md → *The Gate 2 read surface* gives; every row once, in order, none missing |
| `gen-current` | a page requested with the scope's current generation | the page: its rows in the producer's order, the generation, and `total` |
| `gen-old` | a well-formed generation the scope once had | `result status=refused code=changed`, the fresh `generation`, no `row` |
| `gen-unknown` | a well-formed generation the scope never had | the same as `gen-old` |
| `gen-foreign-scope` | another scope's current generation named in this scope's `page` | the same as `gen-old`: a generation binds its scope, so no page of one scope is served under another's |
| `gen-malformed` | a generation that is not 64 lower-case hex digits, or missing | refused at admission: `result status=error` with the admission's reason and exit status 2, never `changed` and never a page |
| `gen-refresh-same` | a refresh while a detail is open, the new snapshot's generation equal to the open detail's | the detail stays valid and pageable |
| `gen-refresh-changed` | the same refresh with a different generation | the detail becomes stale: shown as changed, not pageable, and the frontend never adopts the new generation |
| `gen-between-pages` | the machine changes between two pages of one traversal | the second page is `changed` with no `row`; no page mixes two data sets |
| `gen-traversal` | every page of a generation that does not change | each row once, none missing, in the producer's order |

### PLIST-M01 production prerequisite tests

**Current independent result:** **PLIST-M01 PRODUCTION PREREQUISITE ACCEPTED**,
**PLIST-M01 CLOSED** at P2 `f91c19574cb8b0c8d3d0e1a16181c374476d7dd3`.
This is prerequisite-only acceptance of the Class A correction, historical
Shared safety-pin exception, CP1-PLIST-M01 Class D exception, exact-P2 six-job
CI and release/Protocol integrity. Those implementation/proof files are frozen
and may run as regressions. The benchmark prerequisite freeze is lifted;
benchmark preparation may resume, while the harness remains a candidate
awaiting focused independent review and O1 remains PENDING. Q5 is RESOLVED FOR
MEASUREMENT, Gate 2 IN PROGRESS and frontend 0.2.0 UNRELEASED.

**Historical remediation record, before P2 acceptance:**
Independent review confirmed MEDIUM, prerequisite-blocking failed-extraction
stdout consumed as data on supported macOS 15. The Class A candidate changes
only `lib/macos.sh::plist_get` and its comment. It remains awaiting independent
confirmation. Diagnostic H's benchmark harness is UNACCEPTED and FROZEN;
benchmark completion has not resumed. Q5 is RESOLVED FOR MEASUREMENT; O1 is
PENDING; Gate 2 is IN PROGRESS. No timing smoke belongs to this remediation.

`tests/test-detection.sh --plist-helper-only` enters the real helper through an
isolated PATH stand-in on every platform, without the native-plutil gate. It
checks one invocation, exact arguments/input/status and stdout bytes: failed
diagnostic/device/integer/filesystem output, success ordinary/false/zero/empty,
spaces/quotes/backslashes/Unicode/multiline/trailing whitespace, success then
failure, and empty input without an invocation. The pre-fix run against H
reported 63 passed, 5 failed, 0 skipped: failed stdout leaked while statuses and
hit witnesses were intact. Remediation buffers once, observes status and
publishes only success; a sentinel preserves trailing newlines.

Detection also pins the absent second physical store and true second-store
identity directly; required size/block/partition/offset/GUID data fail closed,
enumeration end/interior gaps retain count checks, and unknown resize limits
remain distinct from usable existing gaps. Lifecycle holds Asahi container and
volume enumeration, roles, mounted evidence and first-boot classifications.
CLI holds Doctor SMART unavailable/good/adverse outcomes and Sources' required
template fields and status-sensitive EFI expand presence (including false).
Shared holds its positive exFAT postcondition, optional mount path and unchanged
identity/extent/receipt/internal-disk gates. Retained Validate, Health, Journey,
Logs and their proof suites remain the owners of their existing contracts.

`tests/test-static.sh` keeps BASE
`2edb76a7de3f78ec90927ac93d5eec3a84636253`, the other whole-file pins and the
Shared critical interval fixed. It reconstructs the entire expected `macos.sh`
from BASE with exactly one historical helper/comment replaced by an explicit
fixed candidate literal; it never takes that literal from current production.
The entire candidate file must match, with its tracked mode/type preserved.
Temporary negative controls reject outside/neighboring changes, alternative,
duplicate, deleted or byte-different helpers, a changed BASE, missing/duplicate
historical anchors and ambiguous replacements. Static also invokes the helper
contract cases, so the unchanged pinned Bash 5.3.15 CI job executes them.
Native-only plist/owner cases retain the existing no-plutil gate on Linux.

### Gate 3 operation-record diagnostic tests

`tests/test-operation.sh` holds docs/PROTOCOL.md → *The operation-record
diagnostic* (D55) to the actual core, driven as the frontend drives it
(`tests/core-harness.sh`), and to the actual launcher's `operation SCOPE`.
Each case checks the foundation journey snapshot (its `operation` fact,
blockers and listed actions, no row and no path), the `detail
kind=operation` rows in order with their total and generation, both
answers whole and admitted, and the text interface's lines, exit status
and empty stderr. Every case is also held to a read: the state folder and
HOME as they were, the record byte for byte, no lock, log or scratch left.
A tool fails only where a test puts a shim on `PATH` that fails for that
one invocation (the record's path, or the private copy's, among its
arguments). Its directory argument saves the nine foundation findings for
DIA-14.

| Case | Permanent test | What it depends on |
| --- | --- | --- |
| DIA-01 none | no state folder under a searchable one, no `ops`, no record; the deterministic text | `_op_lookup` |
| DIA-02 readable, supervised | a running record whose PID and start are the test shell's | `rec_admit_copied`, `core_alive` (0) |
| DIA-03 readable, liveness unknown | `ps` failing; the boot session unreadable | `core_alive` (2), `core_boot_read` |
| DIA-04 unreadable | torn, empty, a non-ASCII byte, a header, a key, a value, no seal, a hand edit under the seal, a type, another kind of record, another scope, another scope's action, exactly 65536 bytes, 65537; a link, a dangling link, a folder, a FIFO (never opened), group-writable, another user's (a `find` that matches no owner) | `_op_status`, `_op_read`, `_op_check`, `_op_owns` |
| DIA-05 undetermined at lookup | `ops` or the state folder a link or a file; `ops` not searchable or not listable; the state folder not searchable; no state folder under one that cannot be searched | `_op_lookup` |
| DIA-06 undetermined at status, read or check | `find` failing on the entry; `wc` on it; `head` failing or short; `awk` failing on the copy | `_op_status`, `_op_read`, `_op_check` |
| DIA-07 a lossy `seal` or owner check | the seal's `tail` or `awk` failing where `_rec_seal_ok` answers `seal`; the owner `find` failing | `_op_seal`, `_op_status` |
| DIA-08 the machinery fails | the scratch folder not made; the fingerprint's hash; the generation's hash; an unwritable `TMPDIR` for the text | `op_inspect` step 0, `_op_hash`, `op_failure` |
| DIA-09 a value cannot be represented | a state folder whose path holds a TAB: the snapshot keeps its fact and blocker, the detail is `error representation` whatever its page or generation; a UTF-8 path is carried | `core_read_stage` over every row before any page |
| DIA-10(a) a confirmed mismatch | the test shell's PID with another start time; recorded `unsupervised` and `failed` | `core_alive` (1), `op_barrier` |
| DIA-11(a) an identity unconfirmed | as DIA-03 | as DIA-03 |
| DIA-13 a new client, an old core | the accepted prerequisite `152c8f6`, extracted with `git archive`: its foundation, ordinary journey and production cores refuse `kind=operation` with their own texts and no row; its launcher stops `operation journey` at `unexpected argument` and writes nothing, and takes the bare word for an act command | the old checkout alone |
| DIA-14 an old client, a new core | `frontend/tests/proto_diff.rs` builds the released `0.1.0` from its own sources at `54c3770` and runs its parser, `snapshot_of`, model and request builder over the saved answers; the candidate's parser, `snapshot_of` and closed detail kinds over the same | the saved answers |
| DIA-15 hostile bytes | escape sequences, NUL, UTF-8, TABs, record-shaped lines and instructions: none reaches an answer or the terminal | `_op_check`, `op_rows` |
| DIA-10(b), DIA-11(b), DIA-12 | **deferred**: no core implements a clear, so none writes or reads its evidence or a `clear` row | an accepted clear (UR-Q1) |

The same suite pins paging (one row at a time, `offset` equal to and
beyond `total`, a stale generation, a `limit` over 500); `refused changed`
after a rewrite of the same size off the requested page, a replacement, a
removal, a record that appears and a recorded core that ends between the
snapshot and the detail; the unchanged act refusal of an unreadable
record, the foundation's refusal of every other kind and of `validate`, the
ordinary journey and the startup check; and the command's argument check
for every scope name, none, two, another case, a path and a flag.

## Equivalence with the accepted baseline

The focused Gate 2 remediation also tests the accepted decision
`Gate2-read-representation-failure`: oversized decoded tokens (512 bytes), the
raw-present but unloaded `cfg_user=root` token `omb2:`, canonical written values
(4096 bytes), record lines (16384 bytes excluding LF), and complete responses
(8388608 bytes and 65536 records). Existing opaque upstream status is the owner
for encoded expansion; synthetic captured material reaches record/envelope
limits without inventing production fields. Off-page bad status and bad machine
rows fail snapshot and both detail projections with the fixed safe error,
empty generation and no partial content. Representable changes still return
`refused changed`; unrepresentable changes return `error representation` before
changed/offset handling. Machinery and hash faults are `error io`.

Instrumented test-only capture/admission wrappers prove one capture, a clean
live header/hello prefix during every preflight, complete canonical admission,
and staged/published byte equality for snapshot and both detail kinds at offset
0/limit 1, multirow pages and offset equal to total. Changing the original
staging file after admission must
leave publication byte-identical to the retained canonical admission copy;
failure to retain that copy is `error io`, including a copy tool's status 2.
No baseline validator or value owner changes, no Protocol-1 schema change,
and no change to the deferred
`CP0-Q3b-overflow` policy is permitted. `test-gate2-foundation.sh` separately
proves that real/symlink fixture marker directories alone cannot select actions,
the explicit owned harness retains them, fresh sessions reset authority, and
frontend-check refuses the seam.

The oracle is the **accepted baseline, commit
`2edb76a7de3f78ec90927ac93d5eec3a84636253`**, not the new text flow: two new
paths could agree with each other and share a regression.

- CI checks the baseline out into its own worktree (`git worktree add
  --detach … 2edb76a`) and runs its text flow over each baseline fixture
  with the typed words piped in, collecting the recorded commands
  (`OMB_TEST_RECORD`) and every file in the state directory.
- The candidate runs the same fixture twice: its text flow, and `core
  execute` with the same words.
- A fixed normaliser replaces only what varies from run to run in the
  baseline's own formats — `now_utc` and `now_stamp` values, `$$`, and
  `mktemp` suffixes — and the three results must be equal byte for byte.
- A difference fails unless it is a listed, reviewed delta; the list lives in
  the test with the review that accepted each entry (the `dev` module's
  Claude Code change, M15-B, is the only planned one). Operation records
  are removed when their action ends, so the final state directory is
  compared whole.

## Documentation checks

A validator, `tests/test-docs.sh` (M14 gate 1), runs in CI over `SPEC.md`,
`MILESTONES.md`, `README.md`, `AGENTS.md`, `CLAUDE.md` and `docs/`:

| Id | Check |
| --- | --- |
| `docs-refs` | every `FILE → *Section*` reference names an existing heading in that file |
| `docs-test-ids` | every test id docs/SECURITY.md cites is defined in this document |
| `docs-states` | every state in SPEC.md → *States* is defined in the document that owns its subsystem |
| `docs-commands` | every `omarchy-bootstrap` command the documents name is in SPEC.md → *Commands*, with an intent. The intents are `read`, `plan`, `act`, `act, scoped` and `per operation`, plus the human-facing `read, frontend cache` for `frontend-check` alone — that exact command and label paired, no other string admitted; the validator gains that one pairing with the command's implementation |
| `docs-read-writes` | no read command is described as writing anything |
| `docs-milestones` | each gate and milestone is defined once; M17 and M18 are not started |
| `docs-shell` | the target shell is Bash wherever a target shell is named |
| `docs-windows` | Windows appears only as a non-goal |
| `docs-debug-names` | the commands are `debug`, `debug context`, `debug raw`, `debug save`; no other `debug` subcommand is named |
| `docs-sudo-k` | `sudo -k` appears only in docs/DECISIONS.md → *Rejected* |
| `docs-sessions` | agent sessions and histories appear only as not carried in v1 |
| `docs-agents-claude` | `AGENTS.md` and `CLAUDE.md` are byte-identical |
| `docs-backdrop` | the backdrop token's 256-colour value in docs/UX.md → *Tokens* is from the colour cube's blue column (17 to 21), never a grey or black |

## CI

| Job | Runs |
| --- | --- |
| Linux (existing) | Bash 5, ShellCheck 0.9.0, every Bash test, fixture freshness, `docs-*`, `persist-full-real` |
| macOS (existing) | `/bin/bash` 3.2, every Bash test, the launcher step, fixture freshness |
| equivalence | both systems: the baseline worktree and `equiv-*` |
| frontend | `cargo fmt --check`, `clippy -D warnings`, layers A–F and H against the Bash 5 core, the panic gate, `proto-diff-*`, no pending snapshots, the closure over a release build, `frontend-input-*` and `frontend-lock-not-input`, the lock's protocol equals the core's, and either the exact lock check or the named unreleased candidate's (the job checks out the full history for it) |
| frontend on Linux aarch64 | `ubuntu-24.04-arm`: build, layer G, the unit tests (the process table included), H, the panic gate, `sup-*`, `frontend-check-*` but the production case, `frontend-compat-linux` |
| frontend on macOS arm64 | build, layers G and H with the `/bin/bash` 3.2 core, the unit tests, the panic gate, `sup-*`, `frontend-check-*` but the production case, `frontend-compat-macos` |
| Linux target shell | `ubuntu-24.04-arm`: GNU Bash 5.3.15, the Linux root's, built from GNU's sources held to `tests/bash-5.3.15.sha256`; `tests/bash-trap-comsub.sh` under it; the records, core (the signal storm with no skip), diagnostics, launcher and static suites, layer H and layer G under it |
| release | on a `frontend-v*` tag: native builds, the checks above, `SHA256SUMS`, artifact attestations, no `test-hooks` feature |
| benchmark | by hand (`workflow_dispatch`) on both arm64 runners: `bench-*`; its numbers are recorded in MILESTONES.md → *Gate 2 — Read-only equivalence* |

## What only the real Mac can show

The hardware-only facts in docs/UPSTREAM.md → *Not verified yet*, and every
check in docs/QUALIFICATION.md → *Real-hardware qualification (M17)*: the
installers' real behaviour, the disk's real extents, 16 KiB pages under the
frontend and the agent tools, the console's glyphs, the round trip over
4 GiB, and a rerun that changes nothing.
