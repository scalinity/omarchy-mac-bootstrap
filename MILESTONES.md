# Milestones

Each milestone lists its objective, the work, how it is verified, and what must
hold before it counts as done. Status lives at the end of each entry.

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
- **Status:** done (model verified against upstream source; see M14).

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
  qualification is M14.

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
- **Acceptance:** both jobs green on GitHub.
- **Status:** first run on GitHub (run 36198289764, commit 5ce30ae): the
  macOS job passed with no skips; the Linux job failed on macOS sections not
  gated on plutil, a locale-dependent conflict order, and ShellCheck 0.9.0
  findings. Not yet green on both jobs.

## M14 — Real-hardware qualification

- **Objective:** evidence from the target Mac (2021 16-inch M1 Pro) that the
  modelled behaviour is the real behaviour.
- **Work, in order:** full current backup; `./omarchy-bootstrap doctor` and the
  survey compared with `diskutil list`; Asahi and Omarchy installed with the
  planned answers, and the resulting layout compared with the plan record;
  macOS, Recovery and Linux each boot; encryption confirmed finished; back on
  macOS, `shared` shows `awaiting-macos-creation`; Shared created; the
  partition checked with `diskutil info` against the size and start the
  command showed, and written to from macOS; back on Linux, `shared activate`;
  a file over 4 GB copied and hashed macOS → Linux and back; clean reboots
  between the systems; the mount persists; `./omarchy-bootstrap` rerun on both
  systems changes nothing.
- **Acceptance:** every step above holds on the real machine, and the planned
  and actual extents match.
- **Status:** not started.
