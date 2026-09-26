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
| `proto-diff-after-result` | a record after `result`; a partial line after it | `after-result` |
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
| `sup-frontend-death` | F is killed during a managed act | C completes, its operation record is resolved; L waits for `req-*.core` to end, then restores the terminal |
| `sup-core-death` | C is killed while its child runs | F reports an unknown outcome and waits for the group before taking the terminal back; a new act in that scope is refused as busy while the child lives, and reconciles after it ends |
| `sup-launcher-death` | L is killed | F runs on and restores its terminal; the next launcher removes the stale session folder only when its launcher and cores are dead |
| `sup-mutator-survives` | C is killed; its mutating child runs 3 s more | every new act in the scope is refused as busy, naming the child; nothing reclaims the operation |
| `sup-no-reclaim-pid` | an operation record whose PID is dead, with a live process from its group | busy, not reclaimed |
| `sup-reclaim-empty` | an operation record whose group has no live process | the scope's reconciliation runs, then the record is removed |
| `sup-reader-death` | the reader thread panics (test hook) | the outcome is unknown; a fresh snapshot is asked for |
| `sup-eintr` | a signal during a read or wait | the call is retried (Rust unit test; a Bash `wait` loop test) |
| `sup-no-setsid` | static: F and C never call `setsid` or `setpgid`; L, F, C never ignore SIGINT, SIGQUIT, SIGTSTP or block them across a spawn | — |
| `sup-one-spawner` | static: F opens descriptors and spawns only on its main thread; C writes the spool only from its main shell | — |
| `sup-shared-critical` | the Shared creation over fixtures, with the spool and the recorded commands time-ordered | between the final topology read and `sudo -n diskutil addPartition`: no spool write, no other recorded command; statically, the code between those two points is byte-identical to the accepted baseline's |

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
| `stale-last-instant` | with `OMB_TEST_PAUSE_AT` after the re-check, the test creates a file at an absent destination; in a second run, changes a destination being replaced | `ln` refuses and the new file is untouched; the moved file is not the reviewed one, so it is renamed back; both stop as conflicts |
| `stale-setting-instant` | a Git setting changed between the re-read and the write | the read-back reports a conflict with both values |
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
| `toml-dotted` | `a.b.c = 1` beside `[a.b]` | accepted as one key path |
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
| `secret-whole-file` | a Neovim Lua file with a credential in a shape the scan does not know | carried, and marked "carried whole" in the review; nothing states it holds no secret |
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
| `rescue-remove-exact` | `rescue remove` | exactly the recorded files and lines removed; everything else untouched |
| `ssh-fresh-image` | the image's shape: enabled, password on, `alarm` | `exposed`, shown before any rescue |
| `ssh-earlier-setting` | a drop-in sorting before ours with `PasswordAuthentication yes` | the effective check fails; changes undone; not open |
| `ssh-match` | `Match User alarm` with passwords on; `Match LocalPort 22` | caught for that context |
| `ssh-no-include` | `sshd_config` without the `Include` | caught; not open |
| `ssh-case` | `sshd -T` output in mixed case | read correctly |
| `ssh-invalid` | `sshd -t` fails | the drop-in removed; nothing reloaded |
| `ssh-reload-fails`, `ssh-key-test-fails`, `ssh-password-offered` | each | undone; not open |
| `ssh-starts-stopped` | `sshd` stopped before | `start`, never `enable`; recorded |
| `ssh-cleanup-started` | rescue started it | stopped, and verified not running |
| `ssh-cleanup-exposed` | exposed before rescue | ends retained key-only or stopped; never password access |
| `ssh-cleanup-verify-fails` | the final check fails | "not clean", no success reported |
| `ssh-cleanup-predict` | the policy without rescue's drop-in would allow passwords | the drop-in kept (released) or `sshd` stopped; never removed and reloaded |
| `ssh-cleanup-putback` | the prediction says key-only, the real check after reload does not | the drop-in restored and `sshd` reloaded at once; "not clean" |
| `ssh-cleanup-stop-first` | cleanup ending in *stopped* | `sshd` stopped before the drop-in or keys are removed (recorded order) |

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
| `qual-replay-cleaned` | a copy of a cleaned round put back on Shared | never current on either side |
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
| `frontend-inputs-changed` | a commit changing `frontend/src/` without a new release | the CI check fails |
| `frontend-inputs-link` | a symbolic link under `frontend/` | the listing refuses |
| `frontend-inputs-order` | the listing under `LC_ALL=C` and a UTF-8 locale | byte-identical |
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
| frontend | `cargo fmt --check`, `clippy -D warnings`, layers A–F and H against the Bash 5 core, `proto-diff-*`, no pending snapshots, `frontend-inputs-*` and `frontend-lock-not-input`, the lock's protocol equals the core's |
| frontend on Linux aarch64 | `ubuntu-24.04-arm`: build, layer G, `sup-*`, `frontend-compat-linux` |
| frontend on macOS arm64 | build, layers G and H with the `/bin/bash` 3.2 core, `sup-*`, `frontend-compat-macos` |
| release | on a `frontend-v*` tag: native builds, the checks above, `SHA256SUMS`, artifact attestations, no `test-hooks` feature |
| benchmark | by hand (`workflow_dispatch`) on both arm64 runners: `bench-*`; its numbers are recorded in MILESTONES.md → M14 gate 2 |

## What only the real Mac can show

The hardware-only facts in docs/UPSTREAM.md → *Not verified yet*, and every
check in docs/QUALIFICATION.md → *Real-hardware qualification (M17)*: the
installers' real behaviour, the disk's real extents, 16 KiB pages under the
frontend and the agent tools, the console's glyphs, the round trip over
4 GiB, and a rerun that changes nothing.
