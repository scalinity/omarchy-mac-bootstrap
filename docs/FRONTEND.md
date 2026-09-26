# The frontend

**Status: designed; its foundation is the first gate of M14 (MILESTONES.md),
the screens arrive with M14–M16. Not implemented.** Library facts were
verified on 2026-09-26 (docs/UPSTREAM.md → *Ratatui and distribution*).

The product's interface is a compiled Rust program built with Ratatui,
`omb-tui`. It is required: the guided journey on both systems runs in it.
The Bash core stays the authority for everything the machine is and
everything done to it; the frontend presents, asks and shows.

| The frontend | The core (Bash, the accepted baseline and its extensions) |
| --- | --- |
| layout, rendering, focus, keys, scrolling, filtering, search | reading the machine: detection, geometry, the plan, Asahi and Linux states, Shared identity |
| collecting choices and typed words | validating every parameter and word, deciding what is available |
| showing provenance, diffs, logs, codes | downloads, digests, records, transactions |
| suspending itself while a program needs the terminal | running every command that changes anything, and `sudo` |
| — | the debug report, the journey's stages, every judgement of success |

It never computes a storage plan, never decides that anything is safe, never
reads a file or a record itself, never runs a program other than the core,
and never interprets human-formatted text: everything it shows arrived as
records through the protocol (docs/PROTOCOL.md).

## When the frontend runs

The launcher decides before loading anything else:

| Situation | Interface |
| --- | --- |
| an interactive command (none, `plan`, `install`, `resume`, `profile`, `export`, `restore`, `rescue`, `qualify`, `shared create`, `shared activate`) on a terminal | the frontend |
| a one-shot command (`status`, `doctor`, `shared`, `logs`, `sources`, `scan`, `profile show`, `restore status`, `restore why`, `qualify status`, `debug`, `report`, `--help`, `--version`) | text on stdout: its output is a contract for scripts and for agents |
| `--no-tui`, stdin or stdout not a terminal, `TERM=dumb` | text (below) |
| the frontend cannot be verified or cannot start | the text recovery surface, saying why |

A command moves to the frontend only in the milestone that exposes every
action its flow needs through the protocol: `profile` and `export` in M14;
`restore` and `rescue` in M15; the default run, `plan`, `install`,
`resume`, `qualify`, `shared create` and `shared activate` in M16. Until
then that command stays in the text interface, so no command ever opens a
frontend that cannot finish it.

## Starting

### On macOS

```text
./omarchy-bootstrap
  → Bash launcher: bash 3.2 startup, libraries load (baseline)
  → platform and architecture: macOS, arm64
  → frontend lock: the version and SHA-256 for aarch64-apple-darwin
  → cached binary with that digest?     yes → start it
                                        no  → acquire (below), then start it
  → omb-tui: hello → snapshot journey → the journey dashboard
```

### On the fresh Asahi system

The minimal image boots to a root console with no network and no copy of
this repository. The earliest the frontend can draw is the first run of
this tool, and that run needs the repository, which needs the network:

```text
boot → log in as root → nmtui (upstream's own interface)
     → the curl command from the Phase 1 boot guide, with the full commit;
       the same command writes that commit to .omb-commit beside the code
     → ./omarchy-bootstrap resume <token>
     → launcher (text): network present, frontend not cached
     → acquire: URL, version, expected SHA-256 from this commit's lock,
       size; "Download the interface (3 MB)? [Y/n]"
     → verified → omb-tui on the console (TERM=linux: ASCII, 16 colours)
     → everything after this point is the frontend
```

Three ways to have the binary there were compared:

| Option | For | Against | Chosen |
| --- | --- | --- | --- |
| **A. download after the network is up** | one extra download of a few megabytes; the chain of trust is the commit the person typed, the lock inside it, and the digest | the text launcher must handle the moments before the download; when the Phase 1 commit was not on GitHub, the guide falls back to the branch's tip and the chain starts at HTTPS from GitHub instead (the guide says so, and M17 requires the pinned form) | **yes** |
| B. carry it in a pre-Linux payload | available before the network | the only pre-Shared carrier is removable media, an extra step to save seconds; the network is required anyway, for Omarchy | no |
| C. fetch a release bundle containing the binaries instead of the repository | one download | a release asset is not bound to the commit the person typed and can be replaced; every commit would need a release | no |

If the network is lost after the repository arrived, the baseline's text
flow continues: it launches `nmtui` itself and completes Phase 2 without the
frontend if it must.

### The everyday user on Omarchy

The root download lives in root's cache; the user's first interactive run
finds the same digest there (root-owned, not writable by the user, checked
like any cache) or acquires its own copy into the user's cache.

## Distribution and provenance

### Building

A release workflow runs on a tag `frontend-v<version>`:

- **Native builds**, no cross-compiling: `aarch64-apple-darwin` on GitHub's
  arm64 macOS runner, `aarch64-unknown-linux-gnu` on `ubuntu-24.04-arm`
  (pinned, so the glibc floor stays at 2.39; Arch Linux ARM ships 2.43).
- **Pinned inputs**: the toolchain in `frontend/rust-toolchain.toml`
  (at least Ratatui's MSRV, 1.88), `Cargo.lock` committed, `cargo build
  --release --locked`, `--remap-path-prefix` for the build paths.
- **16 KiB pages**: linked with `-z max-page-size=0x10000` (the aarch64
  default already, pinned so it cannot drift); the workflow fails unless
  `readelf -lW` shows every `LOAD` segment aligned to at least `0x4000`. No
  jemalloc or other allocator built for 4 KiB pages is linked.
- **macOS signing**: the arm64 linker signs ad hoc; the workflow runs
  `codesign -v` on the stripped binary and fails if the signature did not
  survive. The binary is downloaded with `curl`, which sets no quarantine
  attribute, so Gatekeeper does not stop it; a copy downloaded through a
  browser would be stopped, and the troubleshooting guide says so.
- **Outputs**: `omb-tui-<version>-<target>` for each target, `SHA256SUMS`,
  and a GitHub artifact attestation (repository, workflow, commit) for each
  binary. The attestation is extra evidence for anyone with `gh`; the tool
  itself relies only on the digest pinned in the lock.

### The lock

`frontend/frontend.lock`, an `omb-frontend 1` record file in the repository:

```text
omb-frontend 1
frontend	version=0.1.0	proto=1	source_commit=4d2a…	source_tree=9c81…
artifact	target=aarch64-apple-darwin	url=https://github.com/scalinity/omarchy-mac-bootstrap/releases/download/frontend-v0.1.0/omb-tui-0.1.0-aarch64-apple-darwin	size=3145728	sha256=…
artifact	target=aarch64-unknown-linux-gnu	url=…/omb-tui-0.1.0-aarch64-unknown-linux-gnu	size=3407872	sha256=…
```

- The lock is changed only by a reviewed commit, after a release.
- **CI keeps it honest**: it fails if `source_tree` is not the Git tree of
  `frontend/` at this commit (the frontend's source changed since the
  release), or if the protocol version the core speaks is not the lock's.
  So a checkout's pinned binary is always the build of the source beside it.
- A person who changes the frontend and runs it on a real machine without
  releasing it cannot: see *Development* below.

### Acquiring

- The URL, size and digest come from the lock; the launcher downloads with
  the baseline's download path (a private 0700 directory, never piped
  anywhere), checks size and SHA-256, and shows provenance as it does for the
  upstream installers: URL, time, size, digest, version, target.
- It needs act intent and a yes (`[Y/n]`: the default is yes, because it
  only fetches a pinned file whose digest is checked); `--dry-run` downloads to the per-run
  scratch directory and keeps nothing (the frontend then runs from there).
- A verified binary moves into the cache, named by its digest:
  `$XDG_CACHE_HOME/omarchy-mac-bootstrap/frontend/<sha256>/omb-tui` (root:
  `/var/cache/omarchy-mac-bootstrap/…`). The cache directory passes the same
  checks as the state directory (owned by this user or root, not writable by
  others, no links), and the download is recorded in the log. The launcher
  then releases the run lock before starting the frontend
  (docs/PROTOCOL.md → *The run lock*).

### Every launch

The launcher hashes the cached binary (a few milliseconds) and starts it only
if the digest is the lock's. A binary that does not match is never started:
it is moved aside, reported, and acquired again with the person's yes.

### Upgrades and downgrades

There is no updater. The lock in the checkout decides the version: `git
pull` to a commit with a new lock means the next interactive run acquires
that version, showing its provenance; checking out an older commit uses the
older version, which may still be cached. Nothing is replaced silently, and
nothing is fetched to look for newer versions.

### When things go wrong

| Failure | What happens |
| --- | --- |
| no network, binary not cached | text recovery surface; it says the interface needs a one-time download and what it would be |
| download fails, is partial, or has the wrong size | nothing is cached; text surface; the error and URL are shown |
| digest mismatch (a replaced release asset, a corrupted cache) | the binary is never run; it is named, and acquiring again is offered |
| the binary exists but will not execute (wrong architecture, a missing loader, exit 126/127) | the launcher reports it with the file's digest and target and continues in text |
| the frontend and core disagree on version or protocol | the core refuses the handshake; the frontend exits with the fallback status; the launcher explains and continues in text |
| the frontend crashes | its panic hook restores the terminal; the launcher also restores the terminal settings it saved and leaves the alternate screen, then reports the crash, where the log is, and `debug` |

The text surface is always a complete, correct way to finish the install
(the baseline flows are text first); it is not the intended experience.

### Development

`OMB_FRONTEND_DEV=<path>` runs an unreleased build, and only in fixture
mode (`OMB_FIXTURE` set), where the core reads recorded machines and runs
nothing. It is refused as root, like the other test seams. An unverified
frontend therefore never drives a real machine.

## The artifacts

| Target | Why |
| --- | --- |
| `aarch64-apple-darwin` | stock macOS on Apple Silicon; no Intel Macs (a baseline non-goal) |
| `aarch64-unknown-linux-gnu` | the Asahi Alarm image and Omarchy are glibc systems; the gnu target is Rust's tier 1 for aarch64 Linux, and a build on glibc 2.39 runs on Arch Linux ARM's 2.43 |

The frontend has no network code, no TLS, no DNS and no terminfo (Crossterm
emits escape codes directly), so a static musl build would buy nothing the
glibc build lacks. musl remains the fallback if a glibc floor ever becomes a
problem. No Linux x86_64 artifact exists; CI builds the frontend on x86_64
only to test it.

## The terminal

Library facts are Ratatui 0.30.2 with Crossterm 0.29.0 (docs/UPSTREAM.md).

| Moment | Handling |
| --- | --- |
| start | the frontend's own panic hook first; the terminal's settings saved once (`tcgetattr`); then Ratatui's `try_init()` (raw mode, alternate screen, its restoring panic hook chained); mouse capture, bracketed paste and keyboard-enhancement modes stay off |
| normal exit | `try_restore()`, the cursor shown explicitly (restore does not), the saved settings put back; on the Linux console the screen is also cleared, because a kernel older than August 2025 has no alternate screen there |
| error | the same, then the error is printed on the normal screen |
| panic | the chained hook restores, then the report prints; the launcher repeats the restore from its own saved `stty` state |
| Ctrl-C | raw mode makes it a key: when idle, quit; in a text field, clear it; during a cancellable managed action, cancel (docs/PROTOCOL.md); otherwise say it cannot stop safely now |
| SIGTERM, SIGHUP | flags set by `signal-hook`; the loop ends through the normal restore |
| Ctrl-Z | when idle: restore, stop the whole process group (the launcher too), and on continue re-enter and redraw with a fresh snapshot; not offered during an action |
| resize | Crossterm's resize event; layout is recomputed from the new size; below the minimum, the too-small state (docs/UX.md) |
| logs | nothing is ever printed to the screen the frontend owns; a managed request's output goes to the diagnostics file when the request records, and otherwise into the frontend's memory for the session's log screen; the frontend's own trace goes to a file only when `OMB_TUI_LOG` names one |

## Handing the terminal to a child

The Asahi installer, Omarchy Mac's setup, `nmtui`, `sudo`, `pacman`, a
sign-in, a rescue agent: each needs the real terminal. The core runs them
(it is the only thing that runs anything); the frontend steps aside first
and comes back after.

```mermaid
sequenceDiagram
    participant P as person
    participant F as omb-tui
    participant C as core (handoff request)
    participant X as child (e.g. the Asahi installer)
    P->>F: types the gate word, Enter
    F->>F: stop drawing; no input is read (one thread)
    F->>F: leave alternate screen, show cursor, raw mode off, put back saved settings
    F->>F: SIGINT caught by a flag (not ignored)
    F->>C: spawn with the real terminal as fds 0-2, request on fd 3
    C->>C: every check of the execute rules, then the baseline flow
    C->>X: runs it in the foreground
    X-->>P: the child owns the terminal
    X->>C: exits
    C->>C: reads the machine afterwards, records
    C-->>F: result on fd 4, exits
    F->>F: put back saved settings, raw mode, alternate screen, drain pending input, clear
    F->>C: new snapshot request (the machine may have changed)
    F->>P: redraw from the fresh state
```

- **One thread reads the terminal.** Only the main thread ever calls
  Crossterm; while it waits for the handoff request, nothing reads input, so
  the child receives every key and every reply the terminal sends it.
  Threads that read the core's pipes never touch the terminal.
- **Caught, not ignored.** Ctrl-C during a handoff is the terminal's
  interrupt again, delivered to the whole foreground process group. The
  frontend and the launcher catch SIGINT with a handler, which `exec` resets
  to the default in the child, so the child still receives Ctrl-C as its own
  author intended. An ignored signal would stay ignored in the child.
- **The saved settings are put back** before and after the child: Crossterm
  saves whatever settings it finds when raw mode is enabled, so a child that
  left the terminal odd would otherwise become the new baseline.
- **The exit status is not the result.** The frontend shows what the core's
  fresh read says afterwards, as the baseline always has.
- **The frontend asks for handoff only when the core declared it**
  (`terminal=handoff` in the action); the core refuses a handoff action
  without a terminal and a managed one that would prompt.

## Event loop and state

- **Synchronous.** No async runtime: the main loop drains messages from
  the core's pipe readers (`std::sync::mpsc`), draws if anything changed,
  then polls Crossterm with a short timeout. It draws on input, on data and
  on resize; it has no ticking redraw except a spinner while a request runs.
- **Model, messages, update, view.** Screens hold state; keys and core
  records become messages; `update` is a pure function of state and message;
  rendering reads state only. This is what the tests drive directly
  (docs/TESTING.md).
- **Snapshots are views, not truth.** The frontend keeps the last snapshot
  to draw from and asks again after every action, on `r`, and when it
  returns from a handoff or a suspend. An action is always submitted with
  the basis it was shown with (docs/PROTOCOL.md).

## The security boundary

The frontend ships with the core and is still treated, by the core, as
untrusted input:

- **It gains no authority by being the interface.** Every execute passes
  the checks in docs/PROTOCOL.md; the session ceiling, scopes and dry run are
  set by the launcher and pass through the frontend unchanged, and the core
  refuses to work when any is missing; schemas have no field through which a
  state, a plan or a verdict could be asserted.
- **Where a human gate sits outside it, and where it does not.** The Asahi
  installer always asks its own questions (the sizes, the OS) and for the
  macOS password; Shared's creation runs `sudo -k` and then `sudo -v`, so the
  password is asked every time (the `-k` is a change to the baseline's
  creation, made in M16 for both interfaces and reviewed as a safety
  change); Omarchy Mac asks for the disk passphrase when encrypting. These
  are read by those programs from the real terminal during a handoff, where
  the frontend is not reading. Omarchy Mac's setup without encryption, and
  Shared's activation on Linux, ask nothing more than the typed word: there,
  the gate the frontend collects is the only human step.
- **Its bytes are pinned.** A modified binary is not started; the defence
  against a malicious or broken frontend is the digest in the reviewed lock
  and tests showing that only the gate field produces a confirmation,
  because a malicious program running as the person could do what the person
  can do regardless of any protocol (docs/DECISIONS.md → O2).
- **Its reach is small by construction**, checked statically: it spawns
  only the core, reads no files other than its own optional trace, writes
  none, and never sets the session variables (docs/TESTING.md).

## Without the frontend

- **`--no-tui`** gives the text interface for every command, for scripts,
  CI, screen readers, SSH sessions without a capable terminal, and
  recovery. It never skips a gate: the typed word must still be given, on
  stdin, as the baseline's text flow reads it.
- **Interactive installer flows in text** are the baseline's own screens;
  they remain the recovery path for the whole install.
- **Migration in text**: `profile --select FILE` takes a selection file
  (docs/MIGRATION.md → *Choices in a file*) and `restore --plan FILE` a
  decisions file (docs/RESTORE.md → *Decisions in a file*), each validated
  like the frontend's requests; the gate words (`restore`, `carry`,
  `import`) are then asked for as in any text flow. The one-shot commands
  show everything the screens show.

## The crate

```text
frontend/
  Cargo.toml  Cargo.lock  rust-toolchain.toml  frontend.lock
  src/
    main.rs        start, exit, the launcher contract (exit statuses)
    terminal.rs    init, restore, saved settings, suspend, handoff
    protocol.rs    the record format and the protocol client (docs/PROTOCOL.md)
    core.rs        the only process spawn: the core, with its fds
    app.rs         model, messages, update
    theme.rs       semantic tokens, capability detection, glyph sets (docs/UX.md)
    keys.rs        the keymap, from which footer hints and help are generated
    screens/       one module per screen family
    widgets/       disk strip, traverse rail, gate field, diff, table helpers
  tests/           state, frame and PTY tests (docs/TESTING.md)
```

Dependencies: `ratatui` 0.30.2 with default features (Crossterm through its
re-export, so exactly one Crossterm), `signal-hook` 0.3 (the version
Crossterm uses), `rustix` for the terminal settings; for tests `insta`,
`portable-pty` and `vt100`. Nothing else without a reason recorded in
docs/DECISIONS.md.

**Exit statuses** (the launcher's contract): 0 finished; 10 fall back to
text (handshake refused, version mismatch, terminal unsupported), with the
reason on stderr after the terminal is restored; anything else is a failure
the launcher reports.
