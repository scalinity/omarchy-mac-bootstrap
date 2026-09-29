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
subsystem documents each gate names. Every gate is a delta reviewed against
the accepted baseline above; a change to a baseline file is reviewed as a
safety change, on its own. Work proceeds through the gates in order; a gate
is done only when its exit holds, judged from the tests and CI logs, and
no gate's work starts before the one before it is done.

Screen numbers are those of docs/UX.md → *Every screen*; test ids are those
of docs/TESTING.md.

## Gate 0 — Specification remediation

- **Objective:** turn the reviewed architecture (independent review of
  `6600fff`: approved with required specification fixes) into a precise
  implementation contract.
- **Work:** close findings H1–H10 and M1–M4 in the documents; record the
  review's answers to O1–O9 (docs/DECISIONS.md); remove the rejected
  `sudo`-cache change; resolve every fact source or package metadata can
  answer (docs/UPSTREAM.md); define the gates below. Then close the delta
  review's findings on `9119502` (DV1–DV8, the TOML test oracle, the
  section references): the build-input closure, per-operation protocol
  schemas and code kinds, diagnostics bounded by child class, session
  ownership and the boot-session mutation barrier, a dedicated rescue SSH
  server, honest last-instant write limits, provisional Linux qualification
  rounds, and the secret criterion by kind of content.
- **Exit:** every finding closed in the documents; O1–O9 recorded; the
  documentation checks of docs/TESTING.md → *Documentation checks* pass
  when run by hand; an independent review of the remediated documents
  passes. No code, workflow, test or fixture changes.
- **Status:** done. The independent verification of
  `21904d699e0b55fc75c16054a8c83bccbdc25249` (CI run 36243099184) accepted
  the Gate 1 contract and authorized Gate 1.

## M14 — Frontend, protocol, scanner, profile, resolver and bundle

### Gate 1 — Frontend and transport foundation

- **Work:** the Rust crate: terminal lifecycle, theme and glyph sets, the
  too-small state, a read-only journey dashboard (screen 2) and the gate
  component (13) driven by a test action; protocol `hello`; the record
  format and admission in both languages (`lib/records.sh`, `record.rs`);
  the process model (`lib/core.sh`, `core.rs`): descriptors, the spool,
  session ownership, supervision, operation records and the boot-session
  barrier, diagnostics by child class; the launcher's side
  (`lib/frontend.sh`): the lock, acquisition, cache, intent rules,
  fallback; one fake read, one fake mutating and one fake handoff child
  (`OMB_TEST_HANDOFF_CHILD`); `release/frontend.lock`, the build-input
  closure checks and the release workflow; the frontend CI jobs;
  `tests/test-docs.sh`; and the production startup check,
  `./omarchy-bootstrap frontend-check` (docs/FRONTEND.md → *The startup
  check*): its own route, which leaves every other command's routing as it
  is; the launcher's cache authority held apart from the core session's
  read ceiling and `journey` scope; the session purpose the core validates;
  the action-free production foundation snapshot (docs/PROTOCOL.md → *The
  startup-check session*); and its own failure path, which ends the check
  and never continues into another command. The entrypoint's routing change
  gets its own focused safety review (docs/DECISIONS.md, D18). **No
  baseline action is exposed.**
- **Verification:** `proto-diff-*`, `proto-golden-hello`,
  `proto-invalid-schemas`, `proto-code-kind`, `proto-admit-io`,
  `proto-env`, `proto-version`, `proto-exit`, `sup-*`, `diag-*`, `pty-*`,
  `frontend-*` (the `frontend-check-*` class included), `docs-*`; frontend
  layers A–H for the two screens.
- **Exit:** the macOS arm64 artifact built, verified and started by the
  launcher on CI and on this Mac's macOS — on this Mac, the published
  macOS artifact the committed production lock pins, acquired or verified
  and started through `./omarchy-bootstrap frontend-check` with no fixture,
  development or test override; `hello` and the production foundation
  snapshot answered; the action-free dashboard visibly drawn and seen; a
  normal quit restoring the terminal and removing the session; no baseline
  state written and no baseline action reached
  (`frontend-check-production-mac`) — the command's status 0 alone is not
  this evidence, because it cannot show that the dashboard was drawn;
  the Linux aarch64 artifact passing `frontend-compat-linux` and starting
  on the aarch64 runner; every
  `frontend-input-*` case behaving as written; start and every cleanup path
  verified; every descriptor, diagnostics and process-death test passing
  on the real topology — a supervised completion with L, F and C alive
  (`sup-completion-controllers-live`), the owner launcher cleaning its own
  scratch (`sup-owner-cleanup`), no reclaim under a live old frontend
  (`sup-reclaim-live-controller`), the boot-session barrier after lost
  supervision, and every retained diagnostic byte within its limit
  (`diag-*`); Bash and Rust admission agreeing on the whole differential
  corpus and the golden examples; `frontend-lock-not-input` passing; no
  path that changes the machine.
- **Status:** accepted and closed, 2026-09-28, by the final independent
  review: Gate 1 accepted, Gate 2 authorized to begin, M17 not started.
  - **Accepted implementation:** `548de43db2d395b19db0f69cbb550814984f3523`
    (R2) on branch `m14-gate1-frontend-foundation`. CI run 36469184904 on
    that exact commit: all six required jobs succeeded.
  - **Identity chain:** frontend source `54c3770` (S), which
    `frontend-v0.1.0` and its release carry; production lock commit
    `569d67e` (L); accepted `frontend-check` contract `480a744` (B); first
    implementation `ad10453` (R); accepted implementation `548de43` (R2).
    The `frontend/` tree and `release/frontend.lock` are the ones of S and
    L. Production `inputs_digest`
    `3accc9ce9fd188cb599cbe7d805ac3eda7c29205fead5df0beb015f8dfa41aaa`;
    lock seal
    `5cb358224f7defb8ebe47c78eb3967321278aa5c39633302b242e299d87d278e`.
  - **Production acceptance (`frontend-check-production-mac`):**
    `./omarchy-bootstrap frontend-check` on this Mac, with no fixture,
    development or test override, started the published `frontend-v0.1.0`
    macOS artifact (SHA-256
    `c651bdfe0271e2c8217741213a42de21a0164d0e7cfdc4716f6b4720ab1ee871`)
    and exited 0. On the screen: the Foundation dashboard with the Check,
    Interface, Session and Actions facts and zero available actions; the
    Help and Logs screens; keyboard navigation; a normal `q` exit. From
    the core and the launcher: core 0.2.0 identified R2; `hello` and the
    journey snapshot answered; every exchange ended `done`; the terminal's
    settings read back as saved; the session's files removed. The check
    stayed read-only and action-free: no baseline action or installer flow
    was exposed or exercised.
  - **Next:** Gate 2 may begin. M17 is not started.
  - **History (each statement as of its own checkpoint, kept as written).**
    The independent review of
  `3a1561e` required remediation (H01–H07, M01–M03, L01–L02); its re-review
  at `38ed2f1` closed nine and left H06, H07 and M03 partial, and the review
  at `aa08ee0` closed H06 and M03 and left H07 partial: the storm's
  exemption did not hold the spool to its bytes. Its remediation is on
  branch `m14-gate1-frontend-foundation` from `21904d6`. CI runs every job
  on each push (Linux x86_64 Bash 5.2.21 with ShellCheck 0.9.0, macOS
  `/bin/bash` 3.2.57, the frontend on Linux x86_64, `ubuntu-24.04-arm` and
  `macos-15` arm64, and the Linux target shell — GNU Bash 5.3.15 built from
  pinned sources on `ubuntu-24.04-arm`), and the remediation report names
  the runs. Staging followed: tag `frontend-v0.1.0` on `54c3770`, release
  run 36362043228 (both artifacts, `SHA256SUMS`, attestations), and the
  production `release/frontend.lock` committed at `569d67e`
  (`source_commit` `54c3770`, `inputs_digest`
  `3accc9ce9fd188cb599cbe7d805ac3eda7c29205fead5df0beb015f8dfa41aaa`, the
  `frontend/` tree unchanged from `54c3770`). The independent review of the
  local-launch preflight at `569d67e` kept the release and the lock valid,
  and found that no production route reached the frontend there: the
  entrypoint started it only with `OMB_FIXTURE` set, and the core refused
  every snapshot outside fixture mode, so this exit's production start
  could not be met without the contract amendment that defines
  `frontend-check`. The amendment needs no new release, tag, build or
  artifact: `frontend-v0.1.0` and the lock stay as they are, and only a
  change under `frontend/`, or Rust behaviour the released artifact cannot
  give, would need a new release, under a new version. The amendment is
  `786a726`; its independent review accepted the architecture — the
  explicit command, the split authorities, the session purpose, the
  action-free snapshot, protocol 1 and `frontend-v0.1.0` as released — and
  required four documentation corrections: FC01, what the command's result
  can prove, apart from what only the drawn dashboard shows; FC02, the
  cache's effects phase by phase; FC03, one `OMB_TEST_` prefix rule for the
  launcher and the core; FC04, the terminal's eligibility before the dry
  run. Their remediation, the documentation commit after `786a726`, is
  written and awaits independent review; implementation is not authorized.
  Blocked on, in order: that review; the bounded `frontend-check`
  implementation; its focused safety review (D18); CI on the exact
  remediation commit; the production start on this Mac, as this exit
  states it. Gate 2 is not authorized. Open:
  - **Bash 5.2 (not a target):** Ubuntu's runners have 5.2.21, which loses
    a trap inside a command holding two command substitutions (upstream,
    fixed for 5.3; docs/UPSTREAM.md → *Experiments*). The core's own code
    holds no such command; the baseline's `log_event` and run lock do, and
    stay byte for byte. The signal-storm test names that one failure as a
    skip on 5.2, counted apart from the plutil skips, only when the state
    it left is one such a death leaves (`sup-eintr-exemption`); the
    target's 5.3.15 runs the same storm in CI with no skip.

### Gate 2 — Read-only equivalence

- **Work:** `snapshot`, `detail` with generations and paging, `validate` for
  the plan; `status`, `doctor` and details presented in the frontend; the
  welcome screen (1); the dashboard (2) and the logs screen (24) over real
  reads.
- **Verification:** contract tests (layer H) against the baseline's read
  commands over every baseline fixture; `debug-intent`-style filesystem
  snapshots around every read; `frontend-intent-*`; `bench-*`.
- **Exit:** read paths have no persistent effect; what the frontend shows
  means what the accepted core's read commands say, fixture by fixture; the
  O1 benchmark run on both arm64 systems, cold and warm, small and
  representative, with its numbers recorded here, and either within its
  budgets or with the finding and its decision recorded in
  docs/DECISIONS.md.
- **Status:** in progress, begun 2026-09-28 on branch
  `m14-gate2-readonly-equivalence` from the Gate 1 closeout commit
  `07b57583ec85ca7a606c1db0c1afe9857490463d`. The contract is written in
  docs/PROTOCOL.md → *The Gate 2 read surface*, docs/UX.md's amended
  direction, and D49–D53 with the open questions the first independent
  review ruled on (docs/DECISIONS.md → *Open review questions*: the doctor's
  and the log's scopes and the validation semantics stay deferred, each
  blocking only its own work). That review required, and this status
  records, three corrections: the candidate check applies the commit's own
  lock admission, the generation test matrix separates a changed generation
  from a malformed one, and the backdrop is the dark navy of the reference.
  The authorized S1–S3 ordinary fixture-only journey snapshot and machine/status
  detail reads are implemented. The focused review of
  `5a7c659c29b32a4de94f07aa938dc084b3585ed6` required G2-H01/G2-H02
  remediation: explicit owned foundation authority and the accepted
  `Gate2-read-representation-failure` rule. Both are implemented and require
  focused independent remediation re-review; Gate 2 is not accepted. S4+
  remains unauthorized; Doctor Q2, Logs Q3a and Validate Q4 remain blocked.
  No Gate 2 screen or benchmark exists. The published frontend remains
  `0.1.0`; candidate `0.2.0` is unreleased (D49). Gate 3 and M17 are not started.

### Gate 3 — The action contract under fixtures

- **Work:** `execute` for the baseline's actions (plan save, the backup gate,
  the Asahi fetch and launch, network, Omarchy start and resume, Shared
  creation, activation and the write test), with their basis families,
  typed gates, exclusion, handoff and cancellation, **in fixture mode
  only**: no installer command moves to the frontend yet.
- **Verification:** `proto-ceiling`, `proto-scope`, `proto-unavailable`,
  `proto-word`, `proto-arg`, `proto-handoff`, `proto-managed-prompt`,
  `proto-no-shell-text`, `stale-*`, `sup-shared-critical`,
  `sup-mutator-survives`, `equiv-*` against the accepted baseline.
- **Exit:** every refusal and fault test passes; three-way equivalence with
  `2edb76a` holds for every exposed action; nothing enters the Shared
  critical interval; no real hardware is touched.
- **Prerequisite, before any real mutating action is exposed:** a recovery
  and diagnostic contract for an operation record that cannot be read.
  Today such a record blocks every act in its scope for good — fail closed:
  a reboot does not make it readable — while read commands keep working
  (Gate 1). The contract says how a person inspects the record, what tells
  "the record cannot be decoded" apart from "no worker and no unexpected
  effect remains", and how the record is cleared: never automatically,
  never by a reboot alone, never by treating corruption as no operation.
- **Status:** not started.

### Gate 4 — Scanner and profile

- **Work:** the versioned scan adapters, the Zsh tracker, sensitivity and
  the opaque path consent, the dotfolder picker, the AI tools' scan side,
  the TOML subset reader, the host binding, selection and profile states;
  screens 3, 4, 5, 8, 9 and 11.
- **Verification:** `scan-*`, `zsh-*`, `toml-*`, `secret-*` (capture side),
  `profile-*`, over every `mac-home-*` fixture.
- **Exit:** adversarial inventories are reported truthfully, uncertainty
  kept; unsupported formats refuse; no tool is run and no configuration
  executed; every planted credential stays out of the profile.
- **Status:** not started.

### Gate 5 — Resolver and bundle

- **Work:** the registry v1, the graph, providers and version instances,
  decisions, the availability check; `prof=` in the resume token; export:
  capture, classification of the captured bytes, objects, the manifest,
  the approval code; screens 6, 7 and 10; `profile` and `export` move to
  the frontend.
- **Verification:** `dag-*`, `registry-*`, `avail-*`, `mcp-*`,
  `secret-toctou`, `secret-deep`, `bundle-*` (export side),
  `bundle-forged-cleanup`.
- **Exit:** the graph is byte-identical across shells, locales and inventory
  orders; no implicit build is ever planned; an exported bundle's objects
  are exactly the classified captured bytes, and its approval code is shown
  and kept.
- **Status:** not started.

## M15 — Linux restore, AI environment, rescue and debugging

### M15-A — Restore and safe debugging

- **Work:** import, admission and the approval code; the destination graph;
  the journal, placement, backups, conflicts, conditional undo; the target
  checks; the field-allowlisted `debug`, `debug context`, `debug raw`,
  `debug save`; screens 17, 20, 21, and the journal in 24; `restore` moves
  to the frontend.
- **Verification:** `bundle-*` (import side), `restore-*`, `persist-*`,
  `stale-dest-*`, `stale-between-items`, `stale-last-instant`,
  `stale-setting-before-recheck`, `secret-whole-file-marked`, `debug-*`,
  over every `linux-restore-*` fixture.
- **Exit:** a stop or a full disk at every persistence boundary reconciles
  correctly on real temporary filesystems; a recomputed bundle is refused;
  undo refuses after later edits; the debug report holds only allowlisted
  fields.
- **Status:** not started.

### M15-B — Packages and AI providers

- **Work:** the providers shared by `dev` and `restore` (the change to the
  baseline's `dev` module is its own reviewed safety delta); installation
  the way Omarchy's wrappers do; Claude Code, Codex and OpenCode
  configuration transforms and writers; explicit live checks and sign-in
  handoffs; the health screen (22).
- **Verification:** `omarchy-*`, `toml-merge`, `toml-target-refused`,
  `restore-consent`, `test-agents.sh` over the `mcp-*` fixtures; the
  equivalence list's `dev` delta reviewed.
- **Exit:** no static path runs a wrapper, shim, mise or agent; no second
  copy of any tool is installed and no wrapper overwritten; every outcome
  reflects the machine; the M15-B facts in docs/UPSTREAM.md → *Not verified
  yet* verified first.
- **Status:** not started.

### M15-C — Optional rescue

- **Work:** the rescue screen (16), the root workspace, the agents as root,
  closing and hardening the system's SSH, the rescue-owned SSH server and
  its checks, `rescue remove`
  and the safe final states.
- **Verification:** `rescue-*`, `ssh-*`.
- **Exit:** remote rescue opens only through its own server, never beside an
  exposed or unproven system server; no failure leaves a newly opened
  password path; cleanup reports
  success only in a verified safe state; nothing crosses from root to the
  everyday user; the M15-C facts in docs/UPSTREAM.md → *Not verified yet*
  verified first.
- **Status:** not started.

## M16 — The full journey through the frontend, and qualification

- **Work:** the baseline's actions move to the frontend on real machines,
  one family at a time (plan and survey; the Asahi handoff; network and the
  Omarchy handoff; Shared creation, activation and test), each with its
  equivalence; screens 12, 14, 15, 18, 19, 23 and 25; the ten stages on
  both systems and journey notes on Shared; qualification: the stream, the
  round trip, the names test, active rounds, stage records with the
  executed source's digest, `report`; the journey simulation.
- **Verification:** `equiv-*` for each family as it moves, `qual-*`,
  `test-journey.sh`, the simulation, and the frontend's layers, on both CI
  systems.
- **Exit:** each family's move reviewed as a separate safety delta against
  the accepted baseline; the simulation passes on both systems; every
  `qual-*` passes, the wrong partition and the stale round among them; the
  stream matches the reference vectors on both systems; every stage's
  screen holds at 80×24 and 60 columns.
- **Status:** not started.

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
  rerun that changes nothing); the hardware-only facts in docs/UPSTREAM.md
  → *Not verified yet*.
- **Verification:** `report` on both systems, from the stage records and a
  fresh read.
- **Acceptance:** every automatic check passes on the real machine; the
  attested steps are confirmed; planned and actual extents match; restore
  is `complete`; qualification passed; a rerun changes nothing; every stage
  record's executed source matches its commit; every way the machine
  differed from the fixtures has become a fixture and a fix before M18,
  with the evidence it invalidates run again.
- **Status:** not started. Not before M14–M16 are done.

## M18 — Hardware-validated release

- **Objective:** a commit that is known to work on this Mac model.
- **Work:** the M17 report committed as `docs/hardware/<model>-<date>.md`;
  the README's tested-on row; the `hw-<model>-<date>` tag on the validated
  commit (docs/QUALIFICATION.md → *Hardware-validated release (M18)*).
- **Acceptance:** the report shows every check passing and every warning
  explained; every stage's evidence is valid for the tagged commit under
  the behaviour rule; the validation names `MacBookPro18,2` and the M1 Pro,
  and nothing else.
- **Status:** not started.
