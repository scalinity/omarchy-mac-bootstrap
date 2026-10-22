# Milestones

The plan to the finish and where it stands. Each milestone's *Work* is its
whole scope and its *Exit* says when it is done, judged from its tests and
CI. Where a design document describes more than a milestone's *Work*, the
milestone wins, and the document is brought down to the built design when
the milestone closes. How the rest is built is docs/DECISIONS.md → D37 and
CLAUDE.md → *How the rest is built*. The record of every checkpoint before
2026-10-22 is in Git.

## Accepted baseline

Commit `2edb76a7de3f78ec90927ac93d5eec3a84636253` is the installer and
storage safety baseline (M0–M13), accepted on 2026-09-26 with CI run
36220127446: the storage planner, the Asahi and Omarchy Mac handoffs,
install classification, the one Shared creation and its activation, state,
routing and the launcher. It is the equivalence oracle. An action the
frontend drives makes the same decisions, runs the same commands in the same
order and leaves the same state as this commit's text interface, unless the
difference is a named, tested delta (docs/TESTING.md → *Equivalence with the
accepted baseline*). No real hardware has run it; that is M17.

## The installer: M0–M13

All done, and accepted with the baseline above.

| Milestone | What it delivered |
| --- | --- |
| M0 | upstream read and cited from source: the Asahi Alarm installer and `installer_data.json`, Omarchy Mac (docs/UPSTREAM.md) |
| M1 | one entrypoint that routes by system, the degradable interface, `--dry-run` |
| M2 | the macOS survey and the storage planner |
| M3 | the gated, provenance-first Asahi handoff and persistent state |
| M4 | Linux detection and the Omarchy Mac handoff |
| M5 | `doctor`, `status`, `resume`, `logs` |
| M6 | the optional developer setup |
| M7 | tests, recovery documents, polish |
| M8 | intent from the command, trustworthy state |
| M9 | storage plans on exact extents, with the installer's own alignment |
| M10 | where an interrupted Asahi install stands, from the disk |
| M11 | Shared storage (tested on recorded layouts; real hardware is M17) |
| M12 | developer outcomes that are true |
| M13 | CI on stock bash 3.2 and bash 5 |

## The product expansion: M14–M17

The tool becomes a Mac → Omarchy migration and bootstrap assistant: a
required Ratatui interface over the Bash core, which alone reads the machine,
decides what is legal and runs everything (D3, D5). It is finished before the
first real install (D4), which is M17. Screen numbers are those of
docs/UX.md → *Every screen*; the owner's reference designs, with the screen
each one serves (several file names do not match what they show), are in
docs/UX.md → *Reference designs*.

### The finish

The rest is built in one session, in three phases, A, B and C (D37; the
install's own Phase 1, 2 and 3 in README.md are a different thing). Within a phase,
units that own different files run in parallel on workers, and the session
integrates them; the session alone edits the shared files. A phase ends when
its milestones' exits hold, FULL is green at the phase's head, one
cross-vendor review of the phase finds no open high or medium finding, and
the phase is merged to `main`.

| Phase | Milestones | Units and the files each owns |
| --- | --- | --- |
| A | Gate 3, Gate 4, Gate 5 | **the session:** `omarchy-bootstrap`, `lib/core.sh`, `lib/records.sh`, `lib/state.sh`, `lib/common.sh`, `lib/ui.sh`, `lib/read.sh`, `lib/frontend.sh`, `lib/operation.sh`, `data/children.omb`, `tests/test-safety.sh`, `tests/test-static.sh`, `tests/ci-manifest.tsv`, `tests/fixtures/generate.sh`, the documents · **actions:** `lib/actions.sh`, `lib/macos.sh`, `lib/linux.sh`, `lib/asahi.sh`, `lib/validate.sh`, `lib/shared.sh` outside the critical interval, `tests/test-actions.sh` · **migration choices:** `lib/migrate_scan.sh`, `lib/migrate_profile.sh`, `lib/toml.sh`, their tests · **resolution and export:** `lib/migrate_resolve.sh`, `lib/migrate_bundle.sh`, `data/migration-map.omb`, their tests · **interface:** `frontend/` |
| B | M15-A, M15-B, M15-C | **restore:** `lib/migrate_restore.sh`, `tests/test-restore.sh` · **AI tools:** `lib/agents.sh`, `lib/dev.sh`, `tests/test-agents.sh`, `tests/test-dev.sh` · **debug and SSH:** `lib/debug.sh`, `lib/doctor.sh`, `lib/health.sh`, `lib/linux.sh`, `tests/test-debug.sh`, `tests/test-detection.sh` · **interface:** `frontend/` · the session as in phase A |
| C | M16 | **journey and report:** `lib/journey.sh`, `lib/qualify.sh`, `tests/test-journey.sh`, `tests/test-qualify.sh` · **interface:** `frontend/` · **the session:** the release, `README.md`, the documents, the final check of upstream |

A worker's fixtures go in its own generator file, which
`tests/fixtures/generate.sh` sources. M17 follows phase C: the owner's
install on the M1.

## Gate 0 — Specification remediation

- **Status:** done. The specification fixes and the gate plan were accepted
  at `21904d699e0b55fc75c16054a8c83bccbdc25249` (CI run 36243099184).

## M14 — Frontend, protocol, scanner, profile, resolver and bundle

### Gate 1 — Frontend and transport foundation

- **Built:** the Rust crate (terminal lifecycle, theme, glyph sets, the
  too-small state), protocol `hello`, the record format and admission in
  Bash and Rust, the process model and supervision, the launcher's side
  (lock, acquisition, cache, intent, fallback), `frontend-check`, the
  build-input closure and the release workflow.
- **Status:** done. Accepted implementation `548de43`; `frontend-v0.1.0`
  (source `54c3770`) is published, and `release/frontend.lock` (`569d67e`)
  pins it. `./omarchy-bootstrap frontend-check` started it on this Mac and
  drew the action-free dashboard.

### Gate 2 — Read-only equivalence

- **Built:** `snapshot`, `detail` with generations and paging, `validate`
  for the plan; machine, status, Health (doctor) and Logs details; the
  Welcome, Journey dashboard and Logs screens over real reads.
- **Status:** done at `c855f61`. The O1 benchmark is signed off; one
  limitation stays recorded, O1-LOGS-P01: on the physical M1 the full-window
  Logs detail has p95 540–545 ms against a 500 ms target.

### Gate 3 — The installer's actions through the frontend

- **Built:** the read-only operation-record diagnostic, core and text
  (`a3beb3c`), and its presentation in the frontend (`02ffc3b`); FAST/FULL
  CI on this line of work (`beba63c`).
- **Work:**
  - The generic request surface in the frontend: `Validate{action, args}`,
    `Execute{action, args, word}` and `Detail{scope, kind}` replace the
    requests hardwired to the journey scope and `plan.save`
    (`frontend/src/core.rs`). New screens add data — detail kinds, row
    kinds, fact keys, action ids, parameters, blocker ids — never a new
    schema (D7).
  - Real reads: the released frontend starts on a real machine for the
    interactive commands, and the core answers its reads there. Today three
    policy lines keep everything in fixtures — the launcher starts the
    frontend only under `OMB_FIXTURE`, the core answers reads and `validate`
    only in fixtures, and `core_child` runs only the test children. An
    unreleased frontend stays fixture-only (D16).
  - `execute` for every baseline action. An action is a row of the core's
    action table: its scope, the text flow's own functions in the text
    flow's order, managed or handoff, and its interface word if it has one.
    The rows: `plan.save`, the Asahi launch (survey, backup gate, handoff),
    the Shared codes, Shared creation, network, Omarchy start and resume,
    Shared activation and the write test, and `dev`. The same functions run
    in fixture and real mode, so there is no second code path. The core
    takes the run lock and the scope's operation record, re-reads, rebuilds
    the basis, checks the typed word, then runs the step with the text
    flow's environment — `umask 022`, never the core's own 077. The interface
    word answers the step's first typed-word prompt once, from a variable the
    core never exports; every later prompt (`launch` and `start` after their
    downloads, `create`, `sudo`, the installers) is asked on the terminal,
    which the frontend has handed over. The outcome comes from the scope's
    classifier on a fresh read: the expected effect, or a proven "nothing
    changed" (an installer quit at its first question), removes the record;
    anything else keeps it as `failed` (docs/PROTOCOL.md → *Executing*).
  - `plan.save`, managed, no word: `validate` takes all eleven inputs and
    answers the layout, the installer's answers and a basis over the
    inputs, the partitions and the computed plan. Free space, the resize
    limit and the floor are checked again at execute, never bound into the
    basis, because they drift on a live Mac and would refuse every save.
    `cfg_save` and `mac_save_plan` stop at the first write that fails (today
    they return success after one); the outcome is a read-back of every
    saved value, the Shared intent and `planned_at`.
  - `operation clear SCOPE`, the way out of an unreadable operation record
    (docs/PROTOCOL.md → *An operation record that cannot be read*).
  - The whole-file pins of baseline modules in `tests/test-static.sh` give
    way to behaviour checks; the pin of the Shared critical interval, from
    `sudo -v` to `sudo -n diskutil addPartition`, stays exactly as it is.
  - The spinner frames are left out of the baseline equivalence comparison,
    and nothing else is: the comparison failed on one extra
    `Checking GitHub` frame (run 38146161907).
  - CI that buys nothing goes: the Bash units on `frontend-linux-arm64`
    (shards a2 and a3, and a1's `suite:core`, `suite:frontend` and
    `suite:static`), which repeat `linux-bash5` and `target-bash53`;
    `diag:children` and `diag:session` run 1,004 children and 100 requests
    instead of 10,004 and 1,000 (together 36% of FULL's unit time); the two
    byte comparisons against frozen commits in
    `tests/test-gate2-representation.sh` and `tests/test-gate2-logs-proof.sh`.
    FAST gains a static scan for Bash 4 features.
  - Screens 1 and 2 brought to their reference designs, 12 (with Shared
    creation, 19), 13 (naming the core's real effects), 14, 15 and 18 —
    the designs' look, never a fact the core cannot observe: no installer
    percentage, time remaining or live log (docs/UX.md → *Reference
    designs*).
- **Verification:** `tests/test-actions.sh`; `tests/test-operation.sh` for
  the clear; frames and PTY runs for the new screens (docs/TESTING.md →
  *Principles*).
- **Exit:** every baseline action runs from a development frontend over the
  lifecycle fixtures, equivalent to the accepted baseline; the text
  interface still runs every flow; nothing enters the Shared critical
  interval; an unreadable record has its way out.
- **Status:** in progress.

### Gate 4 — Scanner and profile

- **Work:**
  - `scan`, read as text and never run: Homebrew (services as a flag),
    applications, language tools and runtimes, editors, terminal settings,
    Git, `gh` and SSH, AI tools (Claude Code, Codex and OpenCode in full,
    others recognised), chosen folders, and projects (remote and branch
    only, never copied). Unknown, `partial` and `denied` stay visible.
  - Zsh: literal aliases and allowlisted exports become Bash; the rc files
    travel as reference copies, never sourced. The strict TOML subset reader
    for Codex's configuration and mise.
  - Classification, the hard refusals and the credential scan; chosen
    folders with one typed `opaque` per save; an encrypted SSH key with
    typed `carry`; `UseKeychain` lines dropped from SSH's configuration; a
    folder whose root is a link (stow) followed once.
  - Selection with defaults, as one `omb-select` document; one sealed
    profile bound to this Mac; a rescan keeps choices by item id and reports
    what is gone and what is new.
  - Resolution from `data/migration-map.omb` and the person's decisions, in
    fixed layers (packages, runtimes, ecosystem tools, AI tools, files,
    settings); an unresolved item becomes a decision or a guess checked on
    Linux.
  - Screens: Scan (3), Selection (4), one list and detail per category (5–9
    and 11, as tabs), and Review.
- **Verification:** `tests/test-scan.sh`, `tests/test-toml.sh`,
  `tests/test-secrets.sh`, `tests/test-resolve.sh`, `tests/test-profile.sh`;
  frames for the four screens.
- **Exit:** nothing inventoried runs and no configuration executes;
  uncertainty is shown, never hidden; no planted secret reaches the profile.
- **Status:** not started.

### Gate 5 — Resolver and bundle

- **Work:** `export [DIR]` to verified Shared or a folder the person names:
  a fresh scan reconciled with the profile, the captured bytes classified
  and carried as exactly those bytes, hash-named objects and one sealed
  `bundle.omb`, written as `.partial-*` then renamed; size limits and a
  free-space check; nothing ever deleted. The bundle holds files ready for
  their place on Linux (Claude Code's settings, Codex's `config.toml`,
  `shell.bash`) and records for Git settings, MCP servers, plugins and
  packages. The bundle check that M15-A reuses: seal, digests, destination
  rules.
- **Verification:** `tests/test-bundle.sh`; the export side of
  `tests/test-secrets.sh`.
- **Exit:** no planted secret in any byte written; a corrupt bundle is
  refused; a failure leaves only `.partial-*`.
- **Status:** not started.

## M15 — Linux restore, AI environment, SSH safety and debugging

### M15-A — Restore and safe debugging

- **Work:** `restore [DIR]` as the everyday user, after Omarchy: the bundle
  check; a review of what installs, where each file lands and each conflict
  (Keep by default, diff on request); typed `restore`; packages through one
  `omarchy-pkg-add` handoff, then mise, npm and uv, judged by the machine
  (`pacman -Q`, not exit statuses), with cargo-binstall, go and Flathub
  printed as commands to run by hand; files placed by docs/RESTORE.md's
  placement steps, each original moved whole into backups first; an
  append-only run log, so a stop resumes and a rerun changes nothing; Git
  settings through `git config`, MCP servers through `claude mcp add-json`,
  OpenCode merged with `jq`, Codex's file kept or replaced whole;
  `restore status`; `restore undo` for files, folders and links, refused
  where the destination changed. `debug`: the fixed agent brief and the
  status and doctor facts, never a log line, command output or file content.
  Screens 20 and 21; `debug` from the error state's `D` key.
- **Verification:** `tests/test-restore.sh`, `tests/test-debug.sh`; frames.
- **Exit:** never as root; no replacement without a backup; no path escape;
  an interrupted run resumes and a finished one changes nothing on rerun.
- **Status:** not started.

### M15-B — Packages and AI providers

- **Work:** `lib/agents.sh`, one table for Claude Code, Codex and OpenCode,
  shared by `dev` and `restore`: observation from files only (installed,
  ran at restore, configured, sign-in file present); installation with
  `mise use -g`, one copy each; sign-in handoffs; the tool's own `mcp list`
  on request. `dev` stops counting Omarchy's lazy wrappers as installed
  tools (`dev_tool_present` today). Screen 22 gains restore and AI rows.
- **Verification:** `tests/test-agents.sh`, `tests/test-dev.sh`; frames.
- **Exit:** no check runs a wrapper, shim, mise or agent; every outcome is
  what the machine shows.
- **Status:** not started.

### M15-C — SSH safety and recovery help

- **Work:** before Omarchy Mac's setup, `start` disables the image's
  password-accepting `sshd` (`systemctl disable --now sshd`), checks it is
  inactive and disabled, and reports a failure. `doctor` reports SSH as
  off, key-only, accepting passwords, or cannot tell (`sshd -T` as root),
  and names the image's `alarm` password with the command that locks it.
  Recovery help lives in docs/TROUBLESHOOTING.md and the agent brief. There
  is no rescue mode: no agents as root, no rescue SSH server.
- **Verification:** `tests/test-detection.sh` (the SSH classification, and
  disable-then-check in `start`).
- **Exit:** no password SSH is left listening once `start` has run.
- **Status:** not started.

## M16 — The full journey through the frontend, and qualification

- **Work:** the ten stages derived from the machine on both systems;
  `qualify`, when Shared is planned: a file over 4 GiB and the test names
  with their SHA-256, written to a fresh folder on verified Shared and
  checked by the other system, both ways; small step records holding the
  commit and the time; `report`, the hardware, identities, planned against
  observed layout, encryption, Shared, restore and AI health and warnings,
  each check pass, warn, fail or not checked, with its reason. Screens 23 and 25. The
  journey simulation over fixtures, macOS → reboot → Linux → back. A new
  frontend release through `release.yml`, pinned in the production
  `release/frontend.lock`, acquired and verified by the launcher and
  started by `frontend-check` on this Mac; the checks that drive the old
  `0.1.0` retire with its pin. `README.md` → *Install, step by step* as the
  owner's guide for the one run on the M1.
- **Verification:** `tests/test-journey.sh`, `tests/test-qualify.sh`; the
  PTY journey; FULL on `main`.
- **Exit:** the simulation passes on both systems; FULL is green on `main`;
  the release is pinned and verified; `sources --check` passes.
- **Status:** not started.

## M17 — Real-hardware qualification: the first real install

- **Objective:** the finished tool, run once by the owner on the target Mac
  (2021 16-inch MacBook Pro, M1 Pro, 16 GB, 1 TB), from its macOS restored
  from Time Machine to `done`; then `report` on each system prints what
  the machine shows (docs/QUALIFICATION.md → *Real-hardware qualification
  (M17)*).
- **Status:** not started. It is the owner's run, after M16, never a
  session's.
