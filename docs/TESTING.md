# Testing the product expansion

**Status: the test design for M14–M16, written before the code. Not
implemented.** The baseline's suite (docs/ARCHITECTURE.md → *Tests*) stays
as it is and keeps running on every push.

## Principles

- **No machine is changed in CI.** Every test runs over recorded fixtures,
  with `run` recording argv instead of running, exactly as the baseline's
  suite does. The frontend's PTY tests drive a core in fixture mode.
- **Both shells, both systems.** Every Bash test runs under stock `/bin/bash`
  3.2 on macOS and Bash 5 on Linux, with strict skips; a macOS-fixture
  section on Linux is gated on `plutil` as today.
- **The cheapest layer first.** Pure functions and state transitions carry
  most of the weight; rendered frames next; a few PTY runs last.
- **Adversarial fixtures are first-class.** Every threat in docs/SECURITY.md
  names the fixture family that proves its protection.
- **Fixtures are generated.** `tests/fixtures/generate.sh` grows the new
  families; CI checks they are what the generator writes, as today.

## New seams

| Seam | Purpose | Limits |
| --- | --- | --- |
| `sys_walk DIR` | lists a tree (type, size, mode, link text) without following links; reads `fixture/root/…` in fixture mode | read-only; in the probe allowlist |
| fixture homes | `fixture/root/Users/alex/…` synthetic macOS homes, `fixture/root/home/alex/…` Omarchy homes | generated, synthetic values only |
| `fixture/net/…` | the availability check's downloads (package databases, Flathub answers, `mise lock` output) | as `sys_net` today |
| `OMB_TEST_QUAL_BYTES` | a small size for qualification data | fixture mode only; refused as root |
| `OMB_TEST_HANDOFF_CHILD` | a test program in place of an upstream one during a handoff | fixture mode only; refused as root |
| `OMB_FRONTEND_DEV` | an unreleased frontend build | fixture mode only; refused as root |

## Bash tests

| File | Covers |
| --- | --- |
| `test-records.sh` | the record format: encoding every byte, schema order, unknown keys and types, limits, seals, version refusal |
| `test-scan.sh` | every adapter over the fixture homes; dependencies not offered; duplicates merged by software id and not by name; denied and partial adapters; nothing executed |
| `test-profile.sh` | selection defaults and `by=`, sealing rules, every profile state, the host binding |
| `test-resolve.sh` | dispositions, registry layering, decisions, availability parsing, the dependency layers and blocked chains, path rules, the Zsh adapter; **determinism**: byte-identical output under Bash 3.2 and 5, under `LC_ALL=C` and a UTF-8 locale |
| `test-bundle.sh` | export and import: layout, the manifest, `dest` and link confinement, digests, exFAT clutter ignored, partial exports, foreign bundles, token binding |
| `test-restore.sh` | placement, conflicts and their choices, backups, the journal, interruption at every step then rerun, undo, root refusal, package outcomes judged by `pacman -Q` |
| `test-agents.sh` | each provider: components, capture, transforms (paths, secrets to references), restore commands as recorded argv, health |
| `test-rescue.sh` | availability, installs and start failures, the workspace files, remote rescue's recorded changes and their exact removal |
| `test-debug.sh` | every section on every lifecycle fixture, redaction, size bounds, read-only (filesystem snapshot as in `test-routing.sh`) |
| `test-qualify.sh` | every step and state, binding checks in order, cleanup rules, the deterministic stream |
| `test-journey.sh` | stage derivation on every fixture; the journey simulation (below) |
| `test-protocol.sh` | the core's side of every operation, and every refusal (below) |
| `test-equivalence.sh` | text flow and protocol flow give the same recorded commands and records (below) |

`test-safety.sh` grows with the product:

- every new probe and every new `run` command joins the allowlists, each
  with its reason; any `sudo` in a managed path must be `sudo -n`;
- no new module defines a function whose name a baseline module defines, and
  new modules use their own prefixes;
- no value read from a record, profile, bundle or registry reaches `eval`,
  `source`, `$(( ))` unchecked, or a command string;
- the installer's act paths load no migration module: `install`, `resume`,
  `shared create`, `shared activate`, `shared test`, the default run's
  installer steps, and `core execute` for each of those actions;
- static health checks (`doctor`, `restore status`, the rescue screen's
  snapshot) execute nothing: over fixtures with Omarchy's lazy stubs on
  `PATH`, they record no command and run no probe that is a program;
- the frontend's Rust source has exactly one process spawn (the core, in
  `core.rs`), no file access except its optional trace file, never sets the
  session variables, never enables mouse capture, and no wide characters in
  its glyph tables.

### Adversarial fixtures

| Family | Cases |
| --- | --- |
| `mac-home-typical` | Homebrew formulae, casks, taps and services; npm, cargo, uv, pipx, Go and mise tools; apps; Zsh; Ghostty, tmux, Starship; Neovim; Claude Code, Codex and OpenCode; Git, GitHub CLI, SSH |
| `mac-home-brew-old-receipts` | receipts without `installed_on_request`; a cask with no receipt; a receipt that does not parse |
| `mac-home-duplicates` | node from Homebrew, nvm and mise; Codex as a cask and an npm global; two unknown items with one name |
| `mac-home-secrets` | tokens in MCP `env`, `.env` files, `gh` `hosts.yml`, cloud credentials, a JWT in a configuration file, an unencrypted and an encrypted SSH key, Codex's `auth.json` |
| `mac-home-links` | a link out of the selected folder, an absolute link into `/opt/homebrew`, a link loop, a stow-style dotfiles checkout |
| `mac-home-hostile-names` | names with newline, tab, `%`, spaces, `$(…)`, backticks, a leading `-`, decomposed and precomposed accents, 255-byte components |
| `mac-home-mach-o` | a macOS binary inside a configuration folder |
| `mac-home-tcc` | protected folders that deny, silently |
| `mac-home-restored-from-other` | a state directory from another Mac: a plan for another disk, a profile with another host id |
| `mac-home-zsh` | portable aliases, Zsh-only aliases, macOS-only commands, aliases shadowing Omarchy's, functions, exports including a secret and `PATH`, Oh My Zsh |
| `bundle-valid`, `bundle-modes` | a complete bundle; modes with setuid, world-writable, private classes |
| `bundle-traversal` | `dest` of `../x`, `/etc/x`, `a/../../b`, `%2E%2E/x`, an empty component, a control character, a `dest` outside its item's root |
| `bundle-link-escape` | link text leaving the item's root |
| `bundle-object-mismatch`, `bundle-seal-bad` | a changed object; an edited manifest |
| `bundle-extra-files` | `._*`, `.DS_Store`, unreferenced objects |
| `bundle-foreign`, `bundle-token-mismatch` | another host's bundle; a profile id the token does not name |
| `bundle-case-collision`, `bundle-partial` | two `dest`s equal but for case; a `.partial-` folder |
| `linux-restore-fresh`, `linux-restore-conflicts` | a new Omarchy home with seeded files; every kind of conflict |
| `linux-restore-partial` | a journal with steps begun and not ended, at every step kind |
| `linux-restore-symlinked-parent`, `linux-restore-root` | a link on the way to a destination; `EUID` 0 |
| `registry-*` | `registry-exact`, `registry-provided`, `registry-alternative`, `registry-unknown` (an unknown cask), `registry-x86` (no aarch64 build), `registry-sync-repo` (a target only in a `Usage = Sync` repository), `registry-bad16k`, `registry-local-override`, `registry-malformed` |
| `avail-*` | `avail-alarm-db` (separate `depends` files), `avail-omarchy-db` (zstd, provides in `desc`), `avail-flathub`, `avail-mise-lock` (a URL, skipped, musl-only; the person's mise configuration never loaded), `avail-hostile-db` (`..` and absolute member names) |
| `mcp-*` | `mcp-brew-path` (an `/opt/homebrew/bin/npx` command), `mcp-secret-env`, `mcp-oauth` (an HTTP server with OAuth), `mcp-metachar` (arguments with `;` and `$(…)`), `mcp-macos-only` |
| `rescue-*` | `rescue-offline`, `rescue-not-aarch64`, `rescue-lowmem`, `rescue-installed`, `rescue-start-fails`, `rescue-sshd-password`, `rescue-leftovers` (seen by the everyday user through rescue's record) |
| `debug-secrets`, `debug-incomplete`, `debug-mac` | tokens planted in the journal, the log and the state; a fresh Asahi system; macOS |
| `qual-*` | `qual-valid` (each step), **`qual-wrong-partition` (a USB volume named Shared holding a valid copy of the manifest)**, `qual-bad-seal`, `qual-other-plan`, `qual-stale-round`, `qual-two-rounds`, `qual-digest-mismatch`, `qual-no-space`, `qual-names` (collisions and decomposed names) |
| `profile-*` | sealed; unsealed with held decisions; sealed on another host (stale); a bad seal (invalid); an older schema read for display only |
| `proto-*` | `proto-invalid` (malformed, unknown key, oversized), `proto-version` (wrong protocol or frontend version), `proto-ceiling` (over the ceiling, or outside the session's scopes), `proto-stale` (basis changed), `proto-word` (wrong typed word), `proto-unavailable`, `proto-handoff` (a handoff without a terminal; a managed action that would prompt) |
| `frontend-*` | `frontend-lock` (lock and source tree differ), `frontend-digest` (mismatch on download and in the cache), `frontend-offline` (no cache, no network), `frontend-unrunnable` (wrong architecture, exit 126/127), `frontend-dev` (the override outside fixture mode, or as root) |

### Equivalence: the core stays the authority

For every baseline action the protocol can reach (saving the plan, the
backup gate, the Asahi fetch and launch, the network handoff, Omarchy's
start and resume, Shared's creation and activation, the write test), the
same fixture is driven twice: through the baseline's
text flow with the typed words piped in, and through `core execute` with the
same words. The recorded commands (`OMB_TEST_RECORD`) and every record file
written must be identical, byte for byte. A difference means the protocol
path changed behaviour, and it fails.

### The journey simulation

One test walks a whole install over fixtures in order — macOS survey,
profile, plan, launch; Linux first boot, Omarchy; macOS Shared creation,
export, qualify step 1; Linux activation, restore, step 2; macOS step 3 —
using `OMB_TEST_AFTER` to move between machine states and a fixture Shared
folder shared by both sides, and asserts every stage's state, the next
action, and the records at each point. It is the product's rehearsal
before M17.

## Frontend tests (Rust)

| Layer | What | How |
| --- | --- | --- |
| A. state | every screen's `update` over synthetic messages: selection, filtering, focus, gates (an inexact word never submits), basis carried, handoff requested only for `terminal=handoff` actions | plain unit tests, no terminal |
| B. frames | each screen rendered at 120×40, 100×30, 80×24, 60×24, and 59×20 (the too-small state) | `TestBackend`, `assert_buffer_lines` |
| C. snapshots | major states of each screen: loading, empty, partial, error, blocked, changed, handoff notice, gate | `insta` text snapshots; CI fails on a pending snapshot |
| D. colour and emphasis | focus is reversed, danger is danger, monochrome keeps reverse | `Buffer` comparisons with styles set (snapshots do not carry colour) |
| E. degraded modes | 16 colours, no colour, ASCII: every state still has its word and glyph; the ASCII set is ASCII; every glyph is one cell | frames under each profile |
| F. lifecycle | start, exit, error and panic write the expected sequence: alternate screen left, cursor shown, settings put back | a recording writer in place of stdout |
| G. PTY | start to the dashboard; keys; resize; clean exit leaves the terminal as it was (settings compared, alternate screen off, cursor visible); a handoff to a test child that reads a line — the child receives the typed input, and the frontend returns and redraws; Ctrl-C when idle quits; Ctrl-C during a handoff reaches the child and the frontend survives; an injected panic restores; SIGTERM restores | `portable-pty` and `vt100` on real macOS arm64 and Linux aarch64 runners |
| H. contract | the Rust client against the real Bash core in fixture mode: every operation's golden request and response, version negotiation, every refusal | runs on both CI systems; on macOS the core runs under `/bin/bash` 3.2 |

Visual captures for review — VHS tapes at pinned sizes, both glyph sets —
come with the implementation (the `vhs-cli-demos` skill); they illustrate,
they do not gate.

## CI

| Job | Runs |
| --- | --- |
| Linux (existing) | Bash 5, ShellCheck 0.9.0, every Bash test, fixture freshness |
| macOS (existing) | `/bin/bash` 3.2, every Bash test, the launcher step, fixture freshness |
| frontend | x86_64 Linux: `cargo fmt --check`, `clippy -D warnings`, layers A–F and H against the Bash 5 core, no pending snapshots, the lock's source tree equals `frontend/`, the lock's protocol equals the core's |
| frontend on Linux aarch64 | `ubuntu-24.04-arm`: build, layer G, the `readelf -lW` alignment check |
| frontend on macOS arm64 | build, layers G and H with the `/bin/bash` 3.2 core, `codesign -v` |
| release | on a `frontend-v*` tag: native builds, the checks above, `SHA256SUMS`, artifact attestations |

The deterministic AES-CTR stream of docs/QUALIFICATION.md is asserted on
both Bash jobs against one pinned digest, which proves LibreSSL (macOS) and
OpenSSL (Linux) produce the same bytes.

## What only the real Mac can show

Everything listed under M17 in MILESTONES.md: the installers' real
behaviour, the disk's real extents, the 16 KiB-page behaviour of the agent
tools, the console's glyphs, the round trip over 4 GiB, and a rerun that
changes nothing.
