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
- **Both shells, both systems.** Every Bash test runs under stock `/bin/bash`
  3.2 on macOS and Bash 5 on Linux, with strict skips; a macOS-fixture
  section on Linux is gated on `plutil` as today.
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
| `OMB_TEST_HANDOFF_CHILD` | a test program in place of an upstream one during a handoff | fixture mode only; refused as root |
| `OMB_TEST_STOP_AT` | the core kills itself (`kill -9 $$`) right after the named persistence boundary | fixture mode only; refused as root |
| `OMB_TEST_FAIL_AT` | the checked writer fails at the named boundary as a full disk would | fixture mode only; refused as root |
| `OMB_TEST_PAUSE_AT` | the core waits at the named boundary until a flag file beside it exists, so a test can change the machine in between | fixture mode only; refused as root; runs nothing |
| `OMB_FRONTEND_DEV` | an unreleased frontend build | fixture mode only; refused as root |

Test-only hooks in the frontend (a stalled channel, a reader-thread panic)
exist only in builds with the `test-hooks` feature, which a release build
never enables (a CI check on the release workflow).

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
| `proto-admit-io` | `head`, `tr`, `tail` or `awk` failing during admission (a fixture that makes one exit non-zero): refused `io`, never an empty or valid document |

## Processes, descriptors and the terminal

### `sup-*`: supervision and backpressure

| Id | Case | Expected |
| --- | --- | --- |
| `sup-fd-child` | a managed and a handoff test child list their open descriptors (`/proc/self/fd` on Linux, `fcntl` probing on macOS) | exactly 0, 1, 2 |
| `sup-fd-grandchild` | the child starts a grandchild that sleeps 30 s and lists its descriptors; the child and C exit | the grandchild holds only 0, 1, 2; F completes the request as soon as C exits and the `result` is read, without waiting for the grandchild |
| `sup-fd3-closed` | C lists its descriptors right after admission | fd 3 is closed before any other code runs |
| `sup-spool-handoff` | during a handoff child that runs 5 s, C appends 10 000 `progress` records | F's reader keeps them in order; nothing blocks; the child reads its input untouched |
| `sup-slow-frontend` | F's channel held full by a test hook while C runs a managed act | C finishes and exits without waiting; F then reads every record |
| `sup-overflow` | C produces more than 8 MiB − 64 KiB of `progress` | one `overflow`, then the `result`; the spool stays under 8 MiB |
| `sup-epipe` | F writes a 1 MiB request | EPIPE in F, a refusal shown; C exits 2 |
| `sup-frontend-death-core-live` | F is killed during a managed act | C completes and removes its operation record; L waits for `req-*.core` to end, then restores the terminal and cleans up as the owner |
| `sup-completion-controllers-live` | L, F and C alive in one process group; C's mutating child exits and leaves nothing behind | no worker present (every process in the group was in C's snapshot, L, F and C among them, and the `ps` taking the reading is not counted); the postcondition checked; the operation completes and its record is removed |
| `sup-completion-worker-lingers` | the child exits but a descendant it started stays in the group past the action's time limit | not completed: the operation marked unsupervised, the outcome reported unknown |
| `sup-identity-unknown` | `ps` fails, or the boot session cannot be read, during completion, owner cleanup or stale reclaim | nothing completed, nothing deleted, no barrier cleared: every unknown identity counts as alive |
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
| `sup-reader-death` | the reader thread panics (test hook) | the outcome is unknown; a fresh snapshot is asked for |
| `sup-eintr` | a signal during a read or wait | the call is retried (Rust unit test; a Bash `wait` loop test) |
| `sup-no-setsid` | static: F and C never call `setsid` or `setpgid`; L, F, C never ignore SIGINT, SIGQUIT, SIGTSTP or block them across a spawn | — |
| `sup-one-spawner` | static: F opens descriptors and spawns only on its main thread; C writes the spool only from its main shell | — |
| `sup-shared-critical` | the Shared creation over fixtures, with the spool and the recorded commands time-ordered | between the final topology read and `sudo -n diskutil addPartition`: no spool write, no process-table snapshot, no other recorded command; statically, the code between those two points is byte-identical to the accepted baseline's |

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
| `pty-exit`, `pty-panic` | normal exit; an injected panic | alternate screen left, cursor shown, settings equal to the original |
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
| `frontend-input-cargo-lock` | a commit changing only `frontend/Cargo.lock` | the same |
| `frontend-input-toolchain` | a commit changing only `frontend/rust-toolchain.toml` | the same |
| `frontend-input-test-asset` | production code with `include_bytes!("../tests/schema.bin")`; a commit changing only that file | `inputs_digest` changes (tests are inputs); the closure check passes |
| `frontend-input-include-outside` | `include_bytes!` or `include_str!` of a file outside `frontend/`, and of an untracked file inside it | the closure check fails: the path is in rustc's dependency file and not a tracked input |
| `frontend-input-build-rs` | a `build.rs` in the frontend's own package, with and without reading an asset | refused by the `cargo metadata` check |
| `frontend-input-local-path-dependency` | a `path` dependency outside `frontend/`; a `git` dependency; a `[patch]` section | refused |
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

### Layers

| Layer | What | How |
| --- | --- | --- |
| A. state | every screen's `update` over synthetic messages: selection, filtering, focus, gates (an inexact word never submits), basis carried, handoff requested only for `terminal=handoff` actions | plain unit tests, no terminal |
| B. frames | each screen at 120×40, 100×30, 80×24, 60×24, and 59×20 (the too-small state) | `TestBackend`, `assert_buffer_lines` |
| C. snapshots | loading, empty, partial, error, blocked, changed, handoff notice, gate | `insta` text snapshots; CI fails on a pending snapshot |
| D. colour and emphasis | focus is reversed, danger is danger, monochrome keeps reverse | `Buffer` comparisons with styles |
| E. degraded modes | 16 colours, no colour, ASCII: every state keeps its word and glyph; every glyph is one cell | frames under each profile |
| F. lifecycle | start, exit, error and panic write the expected sequence | a recording writer in place of stdout |
| G. PTY | `pty-*` | real runners |
| H. contract | the Rust client against the real Bash core in fixture mode: every operation's golden request and response, every refusal | both CI systems; on macOS under `/bin/bash` 3.2 |

### `bench-*`: the O1 benchmark (M14 gate 2)

Run on macOS arm64 and Linux aarch64, cold (first request after start) and
warm, with a small inventory (50 items) and a representative one (2 000
items, 400 profile entries), 200 repetitions each; the time is split into
core start-up, admission, and probes.

| Id | Operation | Budget |
| --- | --- | --- |
| `bench-nav` | navigation and focus | p95 < 50 ms, no core request |
| `bench-search` | search and filter over loaded data | p95 < 100 ms, no core request |
| `bench-snapshot` | a small snapshot that reads no disk | p95 < 500 ms |
| `bench-validate` | plan validation after inputs are loaded | p95 < 300 ms |
| `bench-disk` | a full disk refresh | progress within 100 ms; investigated above p95 2 s |

## Equivalence with the accepted baseline

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
| `docs-commands` | every `omarchy-bootstrap` command the documents name is in SPEC.md → *Commands*, with an intent |
| `docs-read-writes` | no read command is described as writing anything |
| `docs-milestones` | each gate and milestone is defined once; M17 and M18 are not started |
| `docs-shell` | the target shell is Bash wherever a target shell is named |
| `docs-windows` | Windows appears only as a non-goal |
| `docs-debug-names` | the commands are `debug`, `debug context`, `debug raw`, `debug save`; no other `debug` subcommand is named |
| `docs-sudo-k` | `sudo -k` appears only in docs/DECISIONS.md → *Rejected* |
| `docs-sessions` | agent sessions and histories appear only as not carried in v1 |
| `docs-agents-claude` | `AGENTS.md` and `CLAUDE.md` are byte-identical |

## CI

| Job | Runs |
| --- | --- |
| Linux (existing) | Bash 5, ShellCheck 0.9.0, every Bash test, fixture freshness, `docs-*`, `persist-full-real` |
| macOS (existing) | `/bin/bash` 3.2, every Bash test, the launcher step, fixture freshness |
| equivalence | both systems: the baseline worktree and `equiv-*` |
| frontend | `cargo fmt --check`, `clippy -D warnings`, layers A–F and H against the Bash 5 core, `proto-diff-*`, no pending snapshots, `frontend-input-*` and `frontend-lock-not-input`, the lock's protocol equals the core's |
| frontend on Linux aarch64 | `ubuntu-24.04-arm`: build, layer G, `sup-*`, `frontend-compat-linux` |
| frontend on macOS arm64 | build, layers G and H with the `/bin/bash` 3.2 core, `sup-*`, `frontend-compat-macos` |
| release | on a `frontend-v*` tag: native builds, the checks above, `SHA256SUMS`, artifact attestations, no `test-hooks` feature |
| benchmark | by hand (`workflow_dispatch`) on both arm64 runners: `bench-*`; its numbers are recorded in MILESTONES.md → *Gate 2 — Read-only equivalence* |

## What only the real Mac can show

The hardware-only facts in docs/UPSTREAM.md → *Not verified yet*, and every
check in docs/QUALIFICATION.md → *Real-hardware qualification (M17)*: the
installers' real behaviour, the disk's real extents, 16 KiB pages under the
frontend and the agent tools, the console's glyphs, the round trip over
4 GiB, and a rerun that changes nothing.
