# omarchy-mac-bootstrap

A Bash orchestrator that plans storage and launches the official Asahi Alarm
installer on macOS, continues into Omarchy Mac on the new Arch system, and
carries an optional Shared macOS/Linux exFAT partition through both. It
plans, explains, downloads with provenance, launches, verifies the machine
afterwards, and records.

## Read first

- `SPEC.md` — goals, boundaries, storage algorithm, state machines, acceptance criteria.
- `docs/UPSTREAM.md` — what upstream was read and where; read before changing any upstream assumption.
- `docs/ARCHITECTURE.md` — the seams, module map, bash 3.2 conventions.
- `docs/SHARED.md` — the Shared lifecycle and its one partition creation; read before touching `lib/shared.sh`.
- `MILESTONES.md` — mark a milestone done only when its acceptance criteria hold.

## Rules

- **Disk authority, exactly.** Asahi exclusively owns APFS resizing and
  creation of the Linux/boot layout. Omarchy Mac exclusively owns its boot
  migration and encryption. This bootstrap has only one additional
  disk-mutation authority: after positive topology validation and explicit
  user confirmation, it may create the one planned Shared cross-OS partition
  inside the previously reserved free region. It never deletes, resizes,
  reformats, or generically edits arbitrary partitions. That creation is the
  single `run sudo diskutil addPartition` in `lib/shared.sh`;
  `tests/test-safety.sh` pins it behind both typed gates, a fresh read of the
  disk and the fail-closed record.
- **Stock bash 3.2 everywhere**, because the entrypoint must start on a fresh
  Mac. Write with indexed arrays, `case`, and `eval` into `CFG_*`-style globals;
  verify with `/bin/bash` (bash 5 as an extra run, never instead).
- **Read the machine through `sys_cmd` / `sys_path` / `sys_has` / `sys_net` /
  `sys_reachable`; change it only through `run`.** That is what makes
  `--dry-run`, fixtures, and the recording test harness work. New probes must
  be read-only; `tests/test-safety.sh` holds every probe, every `run` command
  and every `sudo` line to an allowlist — extend it deliberately, with the
  reason in the commit.
- **Intent comes from the command, before the machine's state.** The
  entrypoint sets `OMB_INTENT` (act | plan | read) and `OMB_PERSIST`; `run`
  and downloads refuse outside act. Read-only commands and `--dry-run` write
  nothing: no state directory, no log, no kept download.
- **Plans are bytes over exact extents.** Geometry comes from
  `diskutil info -plist` per partition, cross-checked with `diskutil list`;
  each allocation uses one region, never a sum of gaps; installer answers are
  typed as whole MiB; `plan_verify` proves the invariants on the resulting
  layout. A layout that cannot be read exactly blocks.
- **Every upstream fact lives in `lib/sources.sh`** (URLs, branch, verified
  versions, installer constants, device table, `STORAGE_CONTRACT`). Change a
  target only after reading upstream source, then update `docs/UPSTREAM.md`
  and `SOURCES_VERIFIED_ON` in the same commit. A storage-contract drift
  (installer version, EFI size) blocks the handoff; a display-string drift
  warns.
- **Upstream exit statuses are not evidence.** The Asahi installer exits 0 on
  quit, error and success; Omarchy's helpers exit 0 without installing. Read
  the machine afterwards and report what it shows.
- **Records are input, never authority.** `state.env`, `shared-intent.env`,
  the resume token and the `ombdone`/`ombshare` codes feed checks against the
  machine; device identifiers and commands come from a fresh read, never from
  a record. Every choice passes `cfg_field_ok`: saved values reach shell
  arithmetic, which evaluates array subscripts.
- **Record before the irreversible step** with `state_must_set`; a record that
  cannot be written stops the step.
- **Destructive steps sit behind typed words** (`yes`, `launch`, `start`,
  `resume`, `experimental`, `create`, `mount`, `test`); defaults only ever
  lead to safe outcomes.
- **Print user-visible text through the `ui_*` helpers or `_p`**, so the Linux
  VT console, where Phase 2 runs, stays pure ASCII.
- **State and logs stay non-secret.** `state_set` refuses secret-shaped keys;
  `run` logs argv and exit code, never output. Nothing in this tool reads a
  password — upstream programs prompt for their own.

## Gotchas

- No `set -o pipefail`: `producer | grep -q` can SIGPIPE the producer on an
  early match and flip a true result to false.
- A function that assigns a caller-named variable with `eval` uses
  `__`-prefixed locals (see `ui_ask`); bash's dynamic scoping otherwise lets a
  local shadow the caller's variable.
- Decoders that set globals (`token_decode`) run in the current shell; command
  substitution would discard what they set, and so does a pipeline stage. A
  warning printed inside `$(…)` is captured, not shown.
- Read a prompt's 0/2/3 status with `case $?` right after the call: after an
  `if …; fi` with no `else`, `$?` is 0.
- Unit tests load the libraries without `set -u`; an unset-variable crash
  shows only through the entrypoint, so drive every refusal path with `t_cli`.
- The safety scanner reads a multi-line string's continuation lines as code;
  build multi-line messages with `printf '%s\n' …`.
- `shellcheck -x omarchy-bootstrap` resolves cross-file variables but reports
  only the entrypoint's findings — lint each file as well.
- Linux CI runs ShellCheck 0.9.0 (Ubuntu 24.04), which flags what 0.11 lets
  pass: an optional argument no caller passes (SC2119/SC2120) and
  `A && B || continue` (SC2015). Write for both: explicit `if`, and no
  parameter a function never receives.
- Every macOS fixture is read through Apple's `plutil`, which Linux CI lacks:
  a test section that drives one goes inside `if t_plutil "<section>"; then`.
  Ungated, it fails on Linux, or passes there for the wrong reason.
- Never let `sort` decide the order of text that is shown or compared: glibc's
  UTF-8 collation ignores punctuation where macOS compares bytes. Keep
  insertion order and drop duplicates with `awk '!seen[$0]++'`.
- The Asahi installer ends with a shutdown, so anything the user needs after it
  must be shown before the launch.
- Linux progress is re-derived from the machine (Omarchy Mac's marker, runtime
  version, display manager, setup conf, migration conf and marker); recorded
  state is history only.
- Test seams `OMB_FIXTURE`, `OMB_TEST_RECORD`, `OMB_TEST_AFTER` (the machine
  after a recorded command) and `OMB_TEST_RC` (that command's exit status) are
  refused as root and never execute anything. A recorded `sudo -v` changes
  nothing and succeeds; both belong to the command after it.

## Verify

```bash
tests/run.sh                         # syntax, shellcheck (SHELLCHECK=path if not on PATH), all tests; ~15 min
OMB_STRICT_SKIPS=1 tests/run.sh      # as CI: any skip fails (Linux CI allows only "(no plutil)")
OMB_TEST_BASH=/path/to/bash5 tests/run.sh
tests/fixtures/generate.sh           # after changing fixture shapes; commit the output
OMB_FIXTURE=$PWD/tests/fixtures/<name> ./omarchy-bootstrap --dry-run
```

Report an unrun check as unrun. `.github/workflows/ci.yml` runs Linux (bash
5, ShellCheck) and macOS (`/bin/bash` 3.2) jobs.
