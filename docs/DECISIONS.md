# Decisions

The product expansion's decisions, each with why and what was set aside,
then the questions left open for review. Numbers are stable; a decision
that changes keeps its number and is rewritten as its new state. The
accepted installer and storage baseline (MILESTONES.md → *Accepted
baseline*) is not reopened here.

## Product

**D1. The source is this Mac's own macOS.** The M1, restored from the
everyday Mac's Time Machine backup and brought up to date, is scanned where
it stands, before Linux exists. *Why:* it is the machine being migrated, its
paths are the paths being rewritten, and nothing has to leave it. *Set
aside:* exporting from the everyday Mac as the normal path; that remains
possible as a portable export, imported as foreign (D21).

**D2. The target shell stays Bash.** The Mac is meant to be a Linux and
Bash learning environment. Zsh files are read as text; portable aliases,
exports and settings carry into one tool-owned file sourced from
`~/.bashrc`; frameworks and Zsh-only syntax do not. *Set aside:* switching
the target to Zsh; translating Zsh functions automatically.

**D3. The Ratatui frontend is the product's interface, and the Bash core
stays the authority.** The frontend presents and collects; the core reads
the machine, decides what is legal, and runs everything. The baseline's text
interface remains as the recovery and automation surface: its installer
flows keep their behaviour, and its read commands (`status`, `doctor`,
`sources --check`) gain the new facts. *Set
aside:* rewriting the core in Rust (it would discard the accepted,
independently reviewed baseline); an optional frontend with the text
interface as the normal path.

**D4. The product is complete before the first real install.** M17 is the
first install on the target Mac, run with the finished tool, and it is the
hardware qualification. *Why:* the first real install should be the
product's own journey, not a separate procedure; everything that can be
proven without hardware is proven first (the journey simulation,
docs/TESTING.md).

## The frontend and the protocol

**D5. The frontend decides nothing and runs nothing but the core.** It
never computes a plan, never judges safety, never reads records or user
files, and spawns only the core. *Why:* a second implementation of the
safety logic would be a second authority to keep in agreement with the
reviewed one.

**D6. One short-lived core process per request.** No server. *Why:* the
baseline's model is a one-shot run that re-derives everything from the
machine; a long-lived process would hold state that can drift, and a crash
would lose more than one request. *Cost:* Bash start-up and probes per
request, measured at the M14 gate (open question O1).

**D7. One record format for every file and message.** ASCII,
tab-separated, percent-encoded, schema-ordered, sealed where stored
(docs/PROTOCOL.md). *Why:* Bash 3.2 reads and writes it with builtins on
both systems; JSON would need a parser the core does not have on fresh Asahi.
*Set aside:* JSON (fine for the frontend, not for the core), property lists
(no Linux reader), NUL-separated streams (not reviewable).

**D8. The core says what is legal; `execute` is judged afresh.** Actions
come only from the core's list; each execute is checked for the session's
ceiling and scopes (set by the launcher; the core refuses when either is
missing), availability now, the basis
(what was reviewed), parameters, and the typed word, before the baseline's
own flow runs with all its checks.

**D9. Typed words are collected by the frontend and checked by the core.**
The gate stays a typed word, never a button. The Asahi launch also passes the
installer's own questions, and Shared's creation runs `sudo -k` before
`sudo -v` so the password is always asked — both read from the real terminal
during a handoff, where the frontend is not reading. (The `-k` changes the
baseline's creation in both interfaces, in M16, reviewed as a safety
change.) Omarchy Mac's setup without encryption and Shared's activation have
no second prompt; there the frontend's gate is the only human step, defended
by the pinned binary and by tests that only the gate field produces a
confirmation. (Open question O2.)

**D10. Binaries from releases, pinned by a lock in the repository.**
`frontend/frontend.lock` names the version, protocol, source commit and
tree, and each target's URL, size and SHA-256; the launcher checks the digest
at download and at every launch; CI fails if the lock's source tree is not
the checkout's `frontend/`. No updater. *Set aside:* building on the target
(no Rust toolchain on a fresh system); committing binaries to Git.

**D11. On fresh Asahi, the frontend is downloaded once the network is up.**
The chain of trust is the full commit the person typed, the lock in that
commit, and the digest; the guide's fetch command also writes that commit
to `.omb-commit`, so the tool knows what it runs. When the Phase 1 commit was
not on GitHub, the guide falls back to the branch's tip and the chain starts
at HTTPS from GitHub; M17 requires the pinned form. *Set aside:* carrying it before Linux (only
removable media could, for seconds saved); a release bundle instead of the
repository (not bound to the typed commit, and replaceable).

**D12. The Linux build is `aarch64-unknown-linux-gnu`, built on
`ubuntu-24.04-arm`.** The target systems are glibc (Arch Linux ARM 2.43;
the build's floor 2.39), the gnu target is Rust's tier 1, and the frontend
has no network, TLS or terminfo dependency for static linking to simplify.
Linked for 64 KiB alignment and checked with `readelf`; no 4 KiB-page
allocator. *Set aside:* static musl, kept as the fallback.

**D13. A synchronous event loop with one thread reading the terminal.** No
async runtime. *Why:* while the main thread waits for a handoff, nothing reads
the terminal, so a child program cannot lose input to the frontend by
construction.

**D14. No mouse capture.** The terminal's own selection keeps working, which
matters because codes and tokens are meant to be copied.

**D15. The theme owns colour and emphasis.** Semantic tokens mapped to the
baseline's palette; `NO_COLOR` handled by the theme (Crossterm 0.29.0's own
handling clears bold and reverse); emphasis by reverse and underline, not
bold with colour (the Linux console cancels it); ASCII on the console; no
wide characters (Ratatui 0.30.2's fix for them is unreleased).

**D16. An unreleased frontend runs only against fixtures.** The development
override is refused outside fixture mode and as root.

**D17. All Bash stays 3.2-compatible, Linux-only code included.** The
entrypoint loads its libraries on both systems, and the macOS CI job runs
every Linux path under `/bin/bash` 3.2; a Bash 5 construct anywhere would
break macOS start-up or lose that coverage.

**D18. The product expansion cannot reach the installer's paths.** New
modules are loaded only by the commands that use them; the installer's act
paths load none of them; new functions carry their own prefixes and may not
redefine a baseline function; equivalence tests prove that protocol-driven
baseline actions record exactly what the text flow records. A change to a
baseline file is reviewed as a safety change (MILESTONES.md → *Accepted
baseline*).

## Migration

**D19. The scanner reads files; it runs no program.** `brew bundle dump` is
an auto-update command that runs eight other programs; `cargo install
--list` and `uv tool list` write files; `npm ls` checks the registry. Receipts
and metadata files are read instead, tolerantly, because Homebrew's receipts
are internal files; Homebrew's prefix is found by its folders, and a Go
tool's module by the build information inside the binary.

**D20. The Migration Profile is a sealed record of choices, bound to this
Mac.** Its id travels in the resume token (`prof=`). It comes before the
plan, so the plan can show the migration's size. *Set aside:* binding it to
a plan (the profile is made first; its host binding is what stops a profile
restored from another Mac).

**D21. The bundle is a content-addressed folder, not an archive.** Files are
stored by digest and placed only by the manifest's validated `dest`. *Why:*
it makes extraction attacks impossible by construction and fits exFAT (no
modes, no links, case-insensitive names). A bundle from another Mac is
imported only with `import`.

**D22. Before Shared, only the token, the repository and the frontend need
to cross; after it, the bundle.** Linux never reads APFS. Removable media
can carry a bundle at any time, if the person chooses, and is the way when
there is no Shared. *Set aside:* network transfer (the
systems are never up together), a Git remote (personal configuration would
live in its history).

**D23. No secret travels, with one exception.** Sign-ins are redone on Linux.
The exception is an OpenSSH private key already encrypted with a passphrase,
after typed `carry`. *Set aside:* an encrypted secrets bundle (no concrete
need beyond keys; tokens are cheaper to renew).

**D24. Resolution is deterministic and reviewable.** A pure function of the
registry (versioned, in the repository), the person's local registry, and
their decisions. No model decides; suggestions become local registry
entries.

**D25. Where software comes from, in order:** already there, pacman through
`omarchy-pkg-add`, Omarchy's helpers, mise runtimes, mise's aqua and GitHub
backends, Flathub, uv, cargo-binstall, Go, npm; never the AUR automatically;
never Linuxbrew by default. Nothing compiles by surprise; no exit status is
taken as a result.

**D26. Two resolutions.** Planned on macOS, with an optional, advisory
availability check (the aarch64 package databases, Flathub, `mise lock`,
`uv pip compile`);
checked on the target, read-only, before anything installs.

**D27. Installation in fixed layers, not a general graph solver.** Edges
may point only to earlier layers, so there are no cycles; an item whose
dependency failed is blocked, never attempted.

**D28. Paths are rewritten only inside fields an adapter parses.** A file
carried whole is reviewed with a suggested diff, never rewritten by search
and replace.

**D29. Restore through owners' interfaces; place files otherwise.** `git
config`, the AI tools' own commands, `omarchy-pkg-add`, mise,
`omarchy-default-agent`; file placement beside and rename, conflicts
defaulting to Keep, backups, a journal, reconciliation on rerun, and undo for
files and settings. Packages are not uninstalled by undo.

**D30. AI tools are providers, one file each.** MCP servers are re-created
through the tools' interfaces or their configuration's structure, with
secret values turned into each tool's own variable references; the tools
install through Omarchy's lazy stubs and mise, not the vendors' installers,
which would replace those stubs.

**D31. Omarchy's default agent is chosen through Omarchy.** `restore`
offers `omarchy-default-agent <name>`; the permissive modes Omarchy starts
agents in are shown, not changed.

## Rescue and debugging

**D32. Rescue is optional, lives in `/root`, and never crosses to the
user.** Local agents install as root with the vendors' verified installers;
remote rescue over key-only SSH is offered; `rescue remove` deletes exactly
what rescue recorded and leaves SSH as upstream set it. (Open questions O3,
O4.)

**D33. The debug report is read-only text from an allowlist, then
scrubbed.** `debug` prints to stdout, so an agent can run it itself; the
agent brief is a vendor-neutral `AGENTS.md` from a template in the
repository.

## Journey and qualification

**D34. Ten stages, derived from the machine.** The other system's progress
arrives only as typed codes before Shared and as journey notes on Shared
after, both shown as recorded, never used as permission. Nothing starts by
itself after a reboot.

**D35. Qualification checks identity first.** Then seals, plan binding,
Shared GUID and round, before reading or writing; the data is a
deterministic AES-CTR stream both sides can compute; clocks are never
compared; the test files are removed automatically only after a pass,
and otherwise only by typed `clean`.

**D36. Hardware validation is per commit, per stage, per model.** A later
commit keeps a stage's validation only if it touches none of that stage's
files; validation names the model and chip it ran on. `frontend-v*` tags
mark frontend releases and `hw-*` tags mark validated commits; there are no
other tags.

**D37. M14 opens with the frontend's foundation as its gate.** The
artifacts, the handshake, the lifecycle, the handoff, the floor sizes and the
failure paths are proven before any migration screen is built on them.

## Open questions for review

These are genuinely undecided; the design names a default for each.

- **O1. Request latency.** A core process per request pays Bash start-up and
  its probes (the macOS survey takes seconds). Default: accept, with
  snapshot scopes and the frontend keeping the last snapshot; the M14 gate
  measures it on the real Mac's macOS. Alternative: a core kept alive for a
  session, with a fresh read per request.
- **O2. Typed words and a broken or compromised frontend.** Default (D9):
  the frontend collects the word and the core checks it; the Asahi launch and
  Shared's creation also pass prompts read from the real terminal (the
  installer's questions; `sudo -k` then `sudo -v`), while Omarchy Mac's
  setup without encryption and Shared's activation rely on the frontend's
  gate alone. Alternative: for those two, or for every action that changes
  a disk or the boot chain, the core reads the word itself from the terminal
  during the handoff — the person then types it in the terminal instead of
  (or as well as) in the frontend.
- **O3. A stronger guardrail for a root agent.** Claude Code's managed
  settings (`/etc/claude-code/managed-settings.json`) cannot be overridden
  from a project, but they would also constrain the everyday user's Claude
  Code until removed. Default: project settings in the workspace only.
- **O4. SSH after rescue.** Default: `rescue remove` restores SSH exactly as
  upstream set it (which may allow password logins until Omarchy's firewall
  or SSH module changes that) and `doctor` warns. Alternative: leave the
  key-only drop-in in place.
- **O5. The developer module's Claude Code install.** The baseline's `dev`
  module installs Claude Code with the vendor's installer into
  `~/.local/bin/claude`, the path of Omarchy 4's lazy stub. Default: M15
  moves that module to Omarchy's mechanism, as a reviewed change to a
  baseline file.
- **O6. `dev` beside `restore`.** Default: keep `dev` for a machine without
  a profile, sharing the installers. Alternative: fold it into `restore` as
  a profile-less mode.
- **O7. Codex's `config.toml`.** Default: a strict line transformer for the
  subset Codex writes, refusing anything else. Alternative: carry it
  untransformed and tell the person which `env_vars` to add.
- **O8. Agent sessions.** Default: offered, opt-in, labelled as the tools'
  internal formats that may not resume. Alternative: not offered at all.
- **O9. Unverified upstream facts that decide behaviour**, checked live in
  M14 or on the Mac in M17: the single list is docs/UPSTREAM.md → *Not
  verified yet*.

## Where each design question is answered

| # | Question | Answer |
| --- | --- | --- |
| 1 | What is a Migration Profile? | docs/MIGRATION.md → *The Migration Profile*; D20 |
| 2 | Where does it live before Linux exists? | the macOS state directory, `profile.omb` (same section; SPEC.md → *Persistent state*) |
| 3 | How does the minimum profile reach fresh Asahi? | it does not need to: only its id, in the typed token (docs/MIGRATION.md → *Moving between the systems*; D22) |
| 4 | When does the full payload reach Linux? | as a bundle on Shared, exported in the boot that creates Shared, or on removable media (docs/MIGRATION.md → *Moving between the systems*, *The bundle*) |
| 5 | Homebrew formulae → target methods | docs/RESOLVER.md → *The registry*, *Where software comes from* |
| 6 | Casks | docs/RESOLVER.md → *Casks and applications* |
| 7 | Functional equivalents | dispositions `NATIVE_EQUIVALENT` and `ALTERNATIVE`; `cap` and `choice` records (docs/RESOLVER.md) |
| 8 | Omarchy-provided or missing | capabilities checked on the machine (docs/RESOLVER.md → *Omarchy-provided or missing*) |
| 9 | aarch64 availability | a check per source, advisory on macOS, authoritative on Linux (docs/RESOLVER.md; D26) |
| 10 | Dependency order | fixed layers (docs/RESOLVER.md → *The dependency graph*; D27) |
| 11 | macOS paths | path rules applied inside parsed fields only (docs/RESOLVER.md → *Paths*; D28) |
| 12 | MCP configuration without executing it | docs/AI-TOOLS.md, per provider, and *Things that execute* |
| 13 | AI configuration safe to copy | docs/AI-TOOLS.md → *What travels* |
| 14 | AI state needing a new sign-in | the same section |
| 15 | Claude Code and Codex sessions | opt-in, `SENSITIVE`, the tools' own files (docs/AI-TOOLS.md; O8) |
| 16 | Arbitrary dotfolders | docs/MIGRATION.md → *The dotfolder picker*, *The bundle* |
| 17 | Symlinks | docs/MIGRATION.md → *The bundle*; docs/RESTORE.md → *Placing a file* |
| 18 | Existing target files | docs/RESTORE.md → *Conflicts* |
| 19 | An interrupted restore | docs/RESTORE.md → *Interrupted, and run again* |
| 20 | Rerunning a restore | the same section |
| 21 | Agents before Omarchy finishes | docs/RESCUE.md → *Agents on this machine, as root* |
| 22 | Rescue state after the user exists | docs/RESCUE.md → *Root and the everyday user*, *`rescue remove`* |
| 23 | The debug report's contents | docs/RESCUE.md → *The debug report* |
| 24 | Secrets kept out of it | the same section; D33 |
| 25 | Continuing across reboots | docs/QUALIFICATION.md → *Across reboots* |
| 26 | Authoritative versus recorded | docs/QUALIFICATION.md → *What each system can see*; SPEC.md → *States* |
| 27 | What moves before Shared | docs/MIGRATION.md → *Moving between the systems* |
| 28 | What moves after Shared | the same section |
| 29 | Automated cross-system qualification | docs/QUALIFICATION.md → *Qualification* |
| 30 | Over 4 GB without copying digests by hand | docs/QUALIFICATION.md → *The round trip* |
| 31 | Binding to the right Shared and plan | docs/QUALIFICATION.md → *Binding and freshness* |
| 32 | The first install as M17 | docs/QUALIFICATION.md → *Real-hardware qualification*; MILESTONES.md → M17 |
| 33 | What makes an M18 release | docs/QUALIFICATION.md → *Hardware-validated release*; D36 |
| 34 | Protecting the frozen baseline | D18; docs/ARCHITECTURE.md → *The product expansion*; docs/TESTING.md → *Equivalence*, `test-safety.sh`; MILESTONES.md → *Accepted baseline* |
| 35 | Bash as the target shell | docs/RESOLVER.md → *From Zsh to Bash*; D2 |
| — | The frontend: distribution, start-up on each system, the split, the protocol, handoff, lifecycle, the security boundary, working without it | docs/FRONTEND.md, docs/PROTOCOL.md; D5–D16 |
| — | The interface: screens, sizes, keys, tokens, degraded modes | docs/UX.md |
