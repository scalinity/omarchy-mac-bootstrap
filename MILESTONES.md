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
- **Status:** planned.

## M2 — macOS preflight + storage planner

- **Objective:** a truthful survey and a planner that mirrors the installer's math.
- **Work:** `lib/macos.sh` detection via plist parsing; `lib/storage.sh` pure
  arithmetic; presets, custom parsing, validation, layout strip, shared plan.
- **Verification:** `tests/test-storage.sh`, `tests/test-detection.sh` over the
  macOS fixtures.
- **Acceptance:** presets and limits match `SPEC.md` for every fixture; unsafe
  input is rejected with its reason.
- **Status:** planned.

## M3 — Asahi handoff + persistent state

- **Objective:** a gated, provenance-first launch of the official installer.
- **Work:** backup gate, download + fingerprint + inspect, answer card,
  clipboard, typed `launch`, foreground execution, exit-code recording, reboot
  guide, resume token.
- **Verification:** `tests/test-state.sh`, `tests/test-safety.sh` (recorded
  argv, no forbidden commands, dry-run executes nothing).
- **Acceptance:** Enter alone never launches; dry-run prints `would run`.
- **Status:** planned.

## M4 — Linux detection + Omarchy handoff

- **Objective:** continue on Asahi Alarm without re-deriving knowledge.
- **Work:** `lib/linux.sh` detection, `nmtui` launch, token decode, branch
  version gate, flag check, typed `start`, upstream setup launch.
- **Verification:** detection tests over the Linux fixtures; command
  construction test for the setup flags.
- **Acceptance:** Omarchy 3 and missing-flag branches are refused; installed and
  in-progress machines are routed away from the handoff.
- **Status:** planned.

## M5 — doctor / status / resume

- **Objective:** make any interruption legible.
- **Work:** `lib/doctor.sh` for both OSes; `status` with journey rail; `resume`
  on both OSes; `logs`.
- **Verification:** doctor over every fixture; exit status non-zero only on FAIL.
- **Acceptance:** `status` names the next action in every recorded state.
- **Status:** planned.

## M6 — Developer bootstrap

- **Objective:** optional, rerunnable developer setup that defers to Omarchy.
- **Work:** `lib/dev.sh` modules: core, languages, containers, editor, git,
  GitHub, SSH, AI CLIs, time/locale.
- **Verification:** dry-run over the Omarchy-installed fixture; recorded argv.
- **Acceptance:** nothing installs without selection; installed tools are skipped.
- **Status:** planned.

## M7 — Tests, recovery docs, polish

- **Objective:** documentation that stands without the original brief.
- **Work:** `README.md`, `docs/*.md`, `AGENTS.md`/`CLAUDE.md`, shellcheck-clean
  sources, final upstream re-verification.
- **Verification:** `tests/run.sh` passes on `/bin/bash` 3.2; README commands
  exercised.
- **Acceptance:** every command in the README behaves as documented.
- **Status:** planned.
