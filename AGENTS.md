# omarchy-mac-bootstrap

A Bash orchestrator that plans storage and launches the official Asahi Alarm
installer on macOS, then continues into Omarchy Mac on the new Arch system.
It plans, explains, downloads with provenance, launches, and records; the
upstream installers own every change to disks and the OS.

## Read first

- `SPEC.md` — goals, boundaries, storage algorithm, state machine, acceptance criteria.
- `docs/UPSTREAM.md` — what upstream was read and where; read before changing any upstream assumption.
- `docs/ARCHITECTURE.md` — the two seams, module map, bash 3.2 conventions.
- `MILESTONES.md` — mark a milestone done only when its acceptance criteria hold.

## Rules

- **Stock bash 3.2 everywhere**, because the entrypoint must start on a fresh
  Mac. Write with indexed arrays, `case`, and `eval` into `CFG_*`-style globals;
  verify with `/bin/bash`, never a Homebrew bash.
- **Read the machine through `sys_cmd` / `sys_path` / `sys_has` / `sys_net` /
  `sys_reachable`; change it only through `run`.** That is what makes
  `--dry-run`, fixtures, and the recording test harness work. New probes must
  be read-only; `tests/test-safety.sh` holds every probe and every `run`
  command to an allowlist — extend the allowlist deliberately, with the reason
  in the commit.
- **Upstream owns destruction.** Partition changes belong to the Asahi
  installer; user, encryption, `/boot`, and Omarchy belong to
  `omarchy-mac-setup`; developer tooling delegates to Omarchy's `omarchy-*`
  commands. Pass answers only through documented flags. The one disk query this
  repo makes is `diskutil apfs resizeContainer <c> limits -plist`.
- **Every upstream fact lives in `lib/sources.sh`** (URLs, branch, verified
  versions, installer constants, device table). Change a target only after
  reading upstream source, then update `docs/UPSTREAM.md` and
  `SOURCES_VERIFIED_ON` in the same commit. Drift is reported, never followed.
- **Destructive launches sit behind typed words** (`yes`, `launch`, `start`,
  `resume`, `experimental`); defaults only ever lead to safe outcomes.
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
  substitution would discard what they set.
- `shellcheck -x omarchy-bootstrap` resolves cross-file variables but reports
  only the entrypoint's findings — lint each file as well.
- The Asahi installer ends with a shutdown, so anything the user needs after it
  must be shown before the launch.
- Linux progress is re-derived from the machine (Omarchy Mac's marker, runtime
  version, display manager, setup conf); recorded state is history only.

## Verify

```bash
tests/run.sh                         # syntax, shellcheck (SHELLCHECK=path if not on PATH), all tests
tests/fixtures/generate.sh           # after changing fixture shapes; commit the output
OMB_FIXTURE=$PWD/tests/fixtures/<name> ./omarchy-bootstrap --dry-run
```

Report an unrun check as unrun. macOS plist tests skip on hosts without `plutil`.
