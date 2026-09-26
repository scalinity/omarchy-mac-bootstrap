# Milestones

Each milestone lists its objective, the work, how it is verified, and what must
hold before it counts as done. Status lives at the end of each entry.

## Accepted baseline

Commit `2edb76a7de3f78ec90927ac93d5eec3a84636253` is the installer and
storage safety baseline, accepted by an independent review on 2026-09-26
before any product-expansion work: the storage planner, the Asahi and Omarchy
Mac handoffs, install classification, the one Shared creation and its
activation, state, routing and the launcher, as tested by CI run 36220127446
(M13). No real hardware has run it; that is M17.

`main` carries it at `e33714195c767f94de41cbea2a51d7c04d8e3fe0`, a
fast-forward (no merge commit) to the reviewed commit plus one
documentation-only commit that accepts M13 and records this baseline. CI
run 36224896159 passed on that commit, logs read: Linux 1,809 passed, 0
failed, 27 skips, every one a plutil-gated section, ShellCheck 0.9.0 clean;
macOS 2,971 passed, 0 failed, no skips, the launcher step clean on stderr,
fixtures fresh. That commit had no independent review of its own; it adds
no code to the reviewed one.

Later work does not inherit this acceptance. Each change is reviewed as a
delta against this commit, and a change that touches disk authority, `sudo`,
the storage planner, the Shared creation or activation, or the allowlists in
`tests/test-safety.sh` is reviewed as a safety change, whichever milestone
carries it.

## M0 — Upstream validation + architecture

- **Objective:** ground every assumption in current upstream source.
- **Work:** read the Asahi Alarm bootstrap, `installer_data.json`, the
  asahi-installer `main.py`/`osinstall.py`/`util.py`, Asahi FAQ, partitioning
  cheatsheet and device list, Omarchy Mac `README.md` and
  `bin/omarchy-mac-setup`; write `SPEC.md`, `docs/UPSTREAM.md`.
- **Verification:** every constant in `SPEC.md` cites its upstream file.
- **Acceptance:** OS choice name, resize prompts, 38 GB rule, setup flags and
  Omarchy 4 branch confirmed from source, not from documentation alone.
- **Status:** done.

## M1 — CLI shell + environment detection

- **Objective:** one entrypoint that routes by OS with a polished, degradable UI.
- **Work:** `omarchy-bootstrap`, `lib/common.sh` (platform, `sys_cmd` seam,
  `run`, logging, fetch), `lib/ui.sh` (palette, glyph sets, rail, menus),
  `lib/state.sh`, `lib/sources.sh`; `--help`, `--version`, `--dry-run`,
  `--no-color`, `--ascii`.
- **Verification:** `tests/test-cli.sh`; manual run under `NO_COLOR=1`,
  `TERM=dumb`, `TERM=linux`.
- **Acceptance:** runs on `/bin/bash` 3.2 with no dependencies.
- **Status:** done.

## M2 — macOS preflight + storage planner

- **Objective:** a truthful survey and a planner that mirrors the installer's math.
- **Work:** `lib/macos.sh` detection via plist parsing; `lib/storage.sh` pure
  arithmetic; presets, custom parsing, validation, layout strip, shared plan.
- **Verification:** `tests/test-storage.sh`, `tests/test-detection.sh` over the
  macOS fixtures.
- **Acceptance:** presets and limits match `SPEC.md` for every fixture; unsafe
  input is rejected with its reason.
- **Status:** done.

## M3 — Asahi handoff + persistent state

- **Objective:** a gated, provenance-first launch of the official installer.
- **Work:** backup gate, download + fingerprint + inspect, answer card,
  clipboard, typed `launch`, foreground execution, exit-code recording, reboot
  guide, resume token.
- **Verification:** `tests/test-state.sh`, `tests/test-safety.sh` (recorded
  argv, no forbidden commands, dry-run executes nothing).
- **Acceptance:** Enter alone never launches; dry-run prints `would run`.
- **Status:** done.

## M4 — Linux detection + Omarchy handoff

- **Objective:** continue on Asahi Alarm without re-deriving knowledge.
- **Work:** `lib/linux.sh` detection, `nmtui` launch, token decode, branch
  version gate, flag check, typed `start`, upstream setup launch.
- **Verification:** detection tests over the Linux fixtures; command
  construction test for the setup flags.
- **Acceptance:** Omarchy 3 and missing-flag branches are refused; installed and
  in-progress machines are routed away from the handoff.
- **Status:** done.

## M5 — doctor / status / resume

- **Objective:** make any interruption legible.
- **Work:** `lib/doctor.sh` for both OSes; `status` with journey rail; `resume`
  on both OSes; `logs`.
- **Verification:** doctor over every fixture; exit status non-zero only on FAIL.
- **Acceptance:** `status` names the next action in every recorded state.
- **Status:** done.

## M6 — Developer bootstrap

- **Objective:** optional, rerunnable developer setup that defers to Omarchy.
- **Work:** `lib/dev.sh` modules: core, languages, containers, editor, git,
  GitHub, SSH, AI CLIs, time/locale.
- **Verification:** dry-run over the Omarchy-installed fixture; recorded argv.
- **Acceptance:** nothing installs without selection; installed tools are skipped.
- **Status:** done.

## M7 — Tests, recovery docs, polish

- **Objective:** documentation that stands without the original brief.
- **Work:** `README.md`, `docs/*.md`, `AGENTS.md`/`CLAUDE.md`, shellcheck-clean
  sources, final upstream re-verification.
- **Verification:** `tests/run.sh` passes on `/bin/bash` 3.2; README commands
  exercised.
- **Acceptance:** every command in the README behaves as documented.
- **Status:** done.

## M8 — Command intent and trustworthy state

- **Objective:** read-only commands and previews that provably change nothing,
  and a local record that cannot be redirected or silently lost.
- **Work:** `OMB_INTENT`/`OMB_PERSIST` set from the command before routing;
  `run` and downloads refuse outside act; Linux `plan` ahead of state routing;
  lazy, checked state directory (ownership, mode, no symlinks); one checked
  atomic writer; the run lock; `state_must_set` before irreversible steps.
- **Verification:** `tests/test-routing.sh` (filesystem snapshots around every
  read-only command, preview and plan in every lifecycle state),
  `tests/test-state.sh`, `tests/test-safety.sh`.
- **Acceptance:** plan never reaches an action in any state; read-only commands
  and `--dry-run` leave no state, log or download; unsafe state paths and
  unwritable records stop the step that needs them.
- **Status:** done.

## M9 — Storage geometry

- **Objective:** plans made on exact extents, with the installer's own
  alignment, that provably hold.
- **Work:** `lib/storage.sh` geometry walk and planner; offsets and GUIDs from
  `diskutil info`; one region per allocation; whole-MiB answers; the eight
  invariants; checked size input; storage contract at the handoff; re-read
  before the launch.
- **Verification:** `tests/test-storage.sh` replays every plan through an
  independent model of the installer; geometry fixtures shaped on a real disk.
- **Acceptance:** separate gaps are never summed; Linux and Shared get at least
  what was asked; the root keeps 50 GB; overflow and leading zeros are
  refused; an unreadable layout blocks.
- **Status:** done (model verified against upstream source; see M17).

## M10 — Install classification and recovery

- **Objective:** say truthfully where an interrupted Asahi install stands.
- **Work:** `lib/asahi.sh`; the re-read after the installer; Omarchy Mac
  encryption and finishing states; recovery docs corrected.
- **Verification:** `tests/test-lifecycle.sh` over a fixture per interruption
  point and per setup/encryption state.
- **Acceptance:** exit status is never evidence; incomplete and unknown states
  stop; repair is mentioned only where upstream offers it.
- **Status:** done.

## M11 — Shared storage

- **Objective:** one exFAT partition both systems read and write, as a
  first-class part of the plan.
- **Work:** `lib/shared.sh`: the plan record, the codes, the guarded creation
  on macOS, the managed mount on Linux, status, doctor and the write test;
  `docs/SHARED.md`.
- **Verification:** `tests/test-shared.sh` (every creation gate and failure,
  reconciliation, activation cases); the static pin of the single
  `addPartition` in `tests/test-safety.sh`.
- **Acceptance:** created at most once, only in the verified reserved region,
  only after both typed gates and a matching re-read; nothing ever formatted,
  deleted or repaired; mounted by PARTUUID for the everyday user.
- **Status:** implemented and tested against recorded layouts; real-hardware
  qualification is M17.

## M12 — Developer outcomes

- **Objective:** a developer setup whose report and exit status are true.
- **Work:** per-module outcomes checked on the machine afterwards; SSH as
  separate facts; only success timestamped.
- **Verification:** `tests/test-dev.sh` with forced failures in every module.
- **Acceptance:** any failure is reported and exits non-zero.
- **Status:** done.

## M13 — Continuous integration

- **Objective:** every push checked on stock bash 3.2 and on bash 5.
- **Work:** `.github/workflows/ci.yml` (Linux with ShellCheck, macOS with
  `/bin/bash`), fixture freshness, strict skips.
- **Verification:** the suite passes locally under `/bin/bash` 3.2 and bash 5
  with `OMB_STRICT_SKIPS=1`.
- **Acceptance:** both jobs green on GitHub, the Linux job skipping only
  the plutil-gated sections, the macOS job skipping nothing, and the macOS
  launcher step clean on stderr — judged from the job logs, not the
  workflow's conclusion alone.
- **Status:** accepted on 2026-09-26 for commit
  `2edb76a7de3f78ec90927ac93d5eec3a84636253`, run 36220127446, logs read:
  Linux (bash 5.2.21, ShellCheck 0.9.0 clean) 1,809 passed, 0 failed, 27
  skips, every one a plutil-gated section; macOS (`/bin/bash` 3.2.57) 2,971
  passed, 0 failed, no skips, the launcher step clean on stderr under `sh`
  and `/bin/bash`, fixtures what the generator writes. The independent
  review of the two later findings, DV1 and DV2 — the mounted Shared
  identity (154db40) and the noninteractive creation after the last read
  (4f37810) — closed both and found no new code-level blocker. This is
  acceptance of the code and CI only: it is not evidence that any real
  hardware has run the tool (M17).
  - Run 36198289764 (commit 5ce30ae): the macOS job passed with no skips;
    the Linux job failed on macOS sections not gated on plutil, a
    locale-dependent conflict order, and ShellCheck 0.9.0 findings.
  - Run 36200868856 (commit 92b07c0): both jobs green (Linux 1,675 passed
    with 24 plutil-gated section skips; macOS 2,705 passed, no skips), but a
    review of the logs found the macOS smoke step printing
    `lib/shared.sh: line 1004: syntax error near unexpected token '('` under
    `sh` and passing anyway, because it checked only the exit status. The
    launcher and that step were fixed after it: the step now fails on any
    stderr, checks the exact version, and runs a command that needs every
    library loaded.
  - Run 36212062095 (commit 0697d1a): the macOS job passed with no skips
    and a clean launcher step; the Linux job failed on ShellCheck 0.9.0
    SC2002 in `tests/test-shared.sh`, which 0.11 no longer reports by
    default.
  - Run 36212657832 (commit adcd325): both jobs green, logs read (Linux
    1,793 passed, 27 skips, all plutil-gated sections, ShellCheck 0.9.0
    clean; macOS 2,946 passed, no skips, launcher step clean under `sh` and
    `/bin/bash`). A later review then found the mounted-identity and
    creation-timing gaps fixed after it.

## The product expansion: M14–M18

The tool becomes a Mac → Omarchy migration and bootstrap assistant with a
required Ratatui interface, and the product is finished **before** the first
real install, which is itself the hardware qualification. The design is on
branch `product-expansion-design`: SPEC.md, docs/DECISIONS.md, and the
subsystem documents each milestone names. Every milestone here is a delta
reviewed against the accepted baseline above; a change to a baseline file is
reviewed as a safety change. Implementation begins only after the design has
passed an independent architecture review, and the review's changes are
made to the design first.

## M14 — Frontend foundation, Migration Profile and macOS scanner

- **Objective:** the product's interface proven on both systems before
  anything is built on it; then a truthful, read-only inventory of this Mac
  and a sealed Migration Profile.
- **Work, in order:**
  1. **The frontend gate.** The record format (`lib/records.sh`); protocol
     v1 with `hello`, a read-only `snapshot`, one managed action and one
     handoff action (a test child in fixture mode); the launcher's side
     (`lib/frontend.sh`: lock, acquisition, cache, digest check, fallback);
     the Rust crate with the terminal lifecycle, the handoff, the theme and
     glyph sets, the too-small state and a read-only journey dashboard; the
     release workflow and the frontend CI jobs (docs/FRONTEND.md,
     docs/PROTOCOL.md, docs/TESTING.md).
  2. The scan adapters, the dotfolder picker, the AI tools' scan side,
     sensitivity, the registry v1 and planned resolution, the availability
     check, the profile and its seal, `prof=` in the resume token, export to
     a folder; screens 3–11 and the gate screen (13), which every typed
     word uses from here on (docs/MIGRATION.md, docs/RESOLVER.md,
     docs/AI-TOOLS.md, docs/UX.md). `profile` and `export` move to the
     frontend; every installer command stays in the text interface until
     M16 exposes its actions.
- **Verification:** `test-records.sh`, `test-protocol.sh`, the frontend's
  layers A–H; then `test-scan.sh`, `test-profile.sh`, `test-resolve.sh`,
  `test-bundle.sh` (export), `test-agents.sh` (scan side), over every
  `mac-home-*`, `profile-*`, `registry-*`, `avail-*` and `mcp-*` fixture.
- **Acceptance — the gate, before any migration screen:** the macOS arm64
  artifact is built, verified and started by the launcher, on CI and on this
  Mac's macOS; the Linux aarch64 artifact starts on the aarch64 runner, and
  its `LOAD` segments are aligned for 16 KiB pages; the handshake works and a
  version or digest mismatch falls back to text; the core stays the
  authority (the protocol's refusals, and equivalence for every action it
  exposes); the terminal is restored after exit, error, panic and SIGTERM;
  a handoff gives the child every key and returns to a fresh screen; 80×24
  and 60 columns render; acquisition shows provenance and every failure path
  in docs/FRONTEND.md behaves as written; request latency measured on this
  Mac's macOS and O1 answered. **Then:** the scanner runs no tool and reads
  nothing outside its allowlist; every adversarial fixture passes; the
  resolver is byte-identical across shells and locales; a profile seals
  only when complete and is stale on another Mac; an exported bundle
  verifies.
- **Status:** not started. Designed.

## M15 — Linux restore, AI environment, rescue and debugging

- **Objective:** the profile arrives on Omarchy truthfully, and the fresh
  system can be debugged with an agent from its first networked minute.
- **Work, in order:** the debug report and the agent brief (smallest, and
  useful for everything after); the rescue screen, local agents as root, the
  workspace, remote rescue, `rescue remove`; import and the target checks;
  the restore's layers, conflicts, journal, reconciliation and undo; the AI
  providers' restore and health; Omarchy's default agent; the developer
  module's alignment with Omarchy's agent stubs (O5, O6); screens 16, 17 and
  20–22; `restore` and `rescue` move to the frontend (docs/RESCUE.md,
  docs/RESTORE.md, docs/AI-TOOLS.md).
- **Verification:** `test-debug.sh`, `test-rescue.sh`, `test-bundle.sh`
  (import), `test-restore.sh`, `test-agents.sh`, over every `bundle-*`,
  `linux-restore-*`, `rescue-*` and `debug-*` fixture; the frontend's layers
  for the new screens.
- **Acceptance:** every restore fixture ends `complete` or says exactly why
  not; an interruption at every step reconciles; a rerun changes nothing;
  undo is exact; no bundle or report fixture contains a planted secret;
  `rescue remove` leaves nothing it made; nothing runs as the wrong user.
- **Status:** not started. Designed.

## M16 — Cross-boot journey through the frontend, and qualification

- **Objective:** one continuous journey across both systems in the
  frontend, and the cross-system check automated.
- **Work:** the ten stages on both systems and journey notes on Shared; the
  baseline's actions exposed through the protocol (plan, the backup gate, the
  Asahi fetch and launch, network, Omarchy start and resume, Shared creation,
  activation and the write test), each with an equivalence test; Shared's
  creation gains `sudo -k` before `sudo -v` in both interfaces (a change to
  a baseline file); screens 1, 2, 12, 14, 15, 18, 19 and 23–25; the default
  run and the installer commands move to the frontend; the qualification
  steps, the round trip and the names test; stage records and `report`; the
  journey simulation (docs/QUALIFICATION.md).
- **Verification:** `test-journey.sh`, `test-qualify.sh`,
  `test-equivalence.sh`, the simulation, and the frontend's layers, on both
  CI systems.
- **Acceptance:** equivalence holds for every exposed baseline action; the
  simulation passes on both systems; every `qual-*` fixture passes, the wrong
  partition among them; the deterministic stream matches on both systems;
  every stage's screen holds at 80×24 and 60 columns; the changes to baseline
  files have their own independent review as safety changes.
- **Status:** not started. Designed.

## M17 — Real-hardware qualification: the first real install

- **Objective:** evidence from the target Mac (2021 16-inch MacBook Pro, M1
  Pro, 16 GB, 1 TB) that the modelled behaviour is the real behaviour,
  obtained by running the finished product.
- **Work:** the whole journey, from the Mac's macOS restored from Time
  Machine to `done`, with the tool; every check in docs/QUALIFICATION.md →
  *What the tool checks and what only the person can*, which includes the
  earlier hardware list (the survey against `diskutil list`; planned and
  actual extents; macOS, Recovery and Linux booting; encryption finished,
  with the LUKS header read as root before the completion code shows;
  `awaiting-macos-creation`; no other disk tool during creation; `sudo -n`
  running the creation without asking again under this Mac's sudo policy;
  the partition against the size and start shown; Shared matched through
  `MAJ:MIN`; a file over 4 GB both ways; clean reboots; a persisting mount; a
  rerun that changes nothing); the open facts in docs/DECISIONS.md → O9.
- **Verification:** `report` on both systems, from the stage records and a
  fresh read.
- **Acceptance:** every automatic check passes on the real machine; the
  attested steps are confirmed; planned and actual extents match; restore
  is `complete`; qualification passed; a rerun changes nothing; every way
  the machine differed from the fixtures has become a fixture and a fix
  before M18, under the stage rule.
- **Status:** not started. Not before M14–M16 are accepted.

## M18 — Hardware-validated release

- **Objective:** a commit that is known to work on this Mac model.
- **Work:** the M17 report committed as `docs/hardware/<model>-<date>.md`;
  the README's tested-on row; the `hw-<model>-<date>` tag on the validated
  commit (docs/QUALIFICATION.md → *Hardware-validated release*).
- **Acceptance:** the report shows every check passing and every warning
  explained; each stage's commit satisfies the stage rule; the validation
  names `MacBookPro18,2` and the M1 Pro, and nothing else.
- **Status:** not started.
