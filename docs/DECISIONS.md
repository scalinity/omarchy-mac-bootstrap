# Decisions

The product expansion's decisions, each with why and what was set aside.
Numbers are stable; a decision that changes keeps its number and states its
new form. The accepted installer and storage baseline (MILESTONES.md →
*Accepted baseline*) is not reopened here. The architecture was reviewed
independently (result: approved with required specification fixes); the
decisions below include that review's resolutions.

## Product

**D1. The source is this Mac's own macOS.** The M1, restored from the
everyday Mac's Time Machine backup and brought up to date, is scanned where
it stands, before Linux exists. *Set aside:* exporting from the everyday Mac
as the normal path; it remains possible as a foreign bundle (D21).

**D2. The target shell stays Bash.** The Mac is meant to be a Linux and Bash
learning environment. Two literal forms (aliases, allowlisted exports) are
imported automatically; everything else is reviewed; functions travel only as
reviewed code (docs/RESOLVER.md → *From Zsh to Bash*). *Set aside:* Zsh on the
target; converting Zsh automatically.

**D3. Ratatui is the product's interface; the Bash core is the authority.**
The frontend presents and collects; the core reads the machine, decides what
is legal, and runs everything. The text interface remains complete, as the
recovery and non-interactive surface; the installer's text flows keep their
behaviour and the read commands gain the new facts. *Set aside:* rewriting
the accepted core in Rust; an optional frontend.

**D4. The product is complete before the first real install**, which is
M17's qualification.

## The frontend and the protocol

**D5. The frontend decides nothing and runs nothing but the core.** It never
computes a plan, judges safety, reads records or user files, or spawns
anything else.

**D6. One short-lived core process per request** (review question O1).
Local navigation, focus, scrolling, search and filtering stay in the
frontend with no core call. Snapshots, validation and actions each start a
fresh core. The M14 gate 2 benchmark measures it (cold and warm, macOS arm64
and Linux aarch64, small and representative inventories), against these
budgets: navigation p95 under 50 ms and search p95 under 100 ms with no core
call; a small non-disk snapshot p95 under 500 ms; plan validation after
inputs are loaded p95 under 300 ms; a full disk refresh shows progress at
once and is investigated above 2 s. Only if start-up dominates and misses
these would a long-lived, bounded **read-only** session be considered;
mutation authority never becomes persistent for speed.

**D7. One record format, with admission before parsing.** ASCII,
tab-separated, percent-encoded, one canonical encoding per value, typed and
schema-ordered, sealed where stored. Every document passes a bounded,
byte-level admission (`head -c`, `wc`, `tr`, `tail`, `od`, C-locale `awk`)
before Bash splits it, because Bash's `read` normalises doubled, leading and
trailing TABs and drops or truncates NULs (reproduced on Bash 3.2 and 5.3).
The Rust side applies the same rules; a differential corpus holds them
together. *Set aside:* JSON (no parser in the core on fresh Asahi, and a Bash
JSON parser would be a larger trusted surface), plists, NUL-separated
streams.

**D8. The core says what is legal and judges every execute afresh.** In
order: admission; the session's ceiling and scopes from the launcher; the
scope's exclusion; a fresh read; availability now; the canonical basis
rebuilt and compared; the typed word; then the baseline's own flow with all
its checks. Each action family has a normative basis schema (docs/PROTOCOL.md
→ §5); restore re-checks each item before it is applied.

**D9. Typed words are intent, validated by the core** (review question O2).
Every existing gate stays exactly an intentional-action gate, `start` and
`mount` included, collected by the frontend or the text flow and validated by
the core. Authentication is a separate matter, left to upstream programs and
`sudo` under their own policies. The baseline's Shared sequence is unchanged.

**D10. Release binaries, pinned by a lock outside the build inputs.**
`release/frontend.lock` pins each artifact's SHA-256 and size, and records
`source_commit` and `inputs_digest` (the SHA-256 of every file under
`frontend/` except `frontend/tests/`, listed canonically). The lock is not a
build input, so updating it cannot change what it records. At run time only
the artifact digest counts; CI checks the checkout's `inputs_digest` against
the lock's; GitHub attestations link the artifact to its commit as optional
evidence. No updater, no signing infrastructure.

**D11. On fresh Asahi, the frontend is downloaded once the network is up**,
checked against the lock of the checkout the Phase 1 guide pinned.

**D12. The Linux build is `aarch64-unknown-linux-gnu` from
`ubuntu-24.04-arm`, with a compatibility contract checked from the
artifact**: interpreter, the `DT_NEEDED` set, the highest glibc symbol
version, `LOAD` alignment, no allocator crate; the macOS build targets 13.5
and is checked for its minimum OS and signature. Alignment is evidence, not
proof: the 16 KiB-page run is proven on the Mac in M17.

**D13. A synchronous frontend with one terminal-reading thread.** The spool
reader never touches the terminal; the main thread reads nothing while a
child runs.

**D14. No mouse capture**, so the terminal's own selection copies codes.

**D15. The theme owns colour and emphasis**: semantic tokens on the
baseline's palette; `NO_COLOR` handled by the theme; reverse and underline
for emphasis; ASCII on the console; no wide characters.

**D16. An unreleased frontend runs only against fixtures.**

**D17. All Bash stays 3.2-compatible**, Linux-only modules included.

**D18. The expansion cannot reach the installer's paths, and the accepted
baseline is the oracle.** New modules load only for the commands that need
them; the installer's act paths load none; new functions carry prefixes and
never redefine baseline functions. Each baseline action exposed through the
protocol is compared with the **accepted baseline, `2edb76a`**, through
recorded commands and records over fixtures — not only with the new text
path, which could share a regression. Every change to a baseline file is its
own reviewed safety delta.

**D38. One process model, with a spool instead of a response pipe.** The
request travels on fd 3, which the core reads (bounded) and closes before
anything else; responses are appended to a per-request spool file the core
opens and closes per record, so no protocol descriptor ever reaches a child
and the core never waits on the frontend. The end of a response is the
core's exit plus exactly one final `result`; anything else is an unknown
outcome, re-derived from the machine. Mutating actions keep an operation
record that survives the death of the process that wrote it; a new mutation
in that scope reconciles first and waits while any process of the old
operation's group remains. Nothing is added between the final Shared
topology validation and `sudo -n diskutil addPartition`.

**D43. The frontend's own persistence follows intent.** Only an act
session downloads and caches the frontend, moves aside a bad cached binary,
or writes a trace file; read, plan, dry-run and `--no-tui` sessions report
and change nothing persistent (docs/FRONTEND.md → *Intent and persistence*).

## Migration

**D19. The scanner runs no inventoried tool.** It reads the package
managers' own records with fixed read-only utilities (`find`, `plutil`,
`wc`, `od`, `awk`); it never runs `brew`, `npm`, `cargo`, `uv`, `go`, `mise`
or an AI tool, whose listing commands update, write, fetch or execute
configuration. Each adapter has a versioned contract, and every item carries
its evidence (`observed`, `inferred`, `unknown`); a missing field is never
turned into certainty. `brew bundle dump` is not used; an enrichment command
may come later, with consent and its own effect tests.

**D20. The Migration Profile is a sealed record of choices, bound to this
Mac.** A draft while it is being made, a finished profile when every choice
is settled. It comes before the plan. Its id rides in the token for journey
matching only.

**D21. The bundle is a content-addressed folder of plain objects placed
only by a validated destination graph.** No archive; no link, special or
hard-link objects; symlinks only inside their own item, lexically; the whole
bundle's destinations validated together; removal only by a record that
owns what it removes.

**D22. Before Shared, only the token, the repository and the frontend need
to cross; after it, the bundle and its approval code.** Removable media can
carry a bundle at any time.

**D39. Integrity, approval and journey are three different mechanisms.**
Seals and object digests detect corruption; the token's `prof=` matches the
journey; **approval** is a code macOS shows after export — 64 bits of
SHA-256 over the manifest's full digest, the profile, the plan id and the
host, with separate check digits — that Linux recomputes and requires before
restoring anything. *Set aside:* treating a recomputable seal as approval;
signing infrastructure.

**D23. Secrets: allowlist first; heuristics only reject.** Supported
adapters carry allowlisted fields, drop credential fields and regenerate the
target configuration; files an adapter carries whole (instructions, skills,
a Neovim tree) are covered only by the scan; credential shapes are scanned
over whole files and exclude on a hit, and a miss proves nothing;
classification and export use the same captured bytes. The one exception is an OpenSSH private key whose
parsed envelope shows a supported cipher and KDF, carried after typed
`carry`, with its limits stated. *Set aside:* a blanket "no secrets travel"
guarantee over arbitrary files; an encrypted secrets bundle.

**D40. Custom paths are selectable, as opaque content.** A path no
supported adapter understands is `OPAQUE`: excluded by default, included
only after typed `opaque` for that path, outside the secret guarantee, with
known credential files still refused inside it and the scan still applied.
This keeps the arbitrary dotfolder picker without pretending to vouch for
what it carries.

**D41. No sessions or histories in v1** (review question O8). Agent sessions,
transcripts, prompt histories, agent memory and shell history do not
travel; history settings do.

**D24. Resolution is deterministic and reviewable.** A pure function of the
registry, the person's local registry and their decisions. No model decides
an installation.

**D25. Where software comes from, in order**: already there, pacman through
`omarchy-pkg-add`, Omarchy's helpers, mise runtimes, mise's aqua and GitHub
backends, Flathub, uv, cargo-binstall, Go, npm; the AUR never automatically;
Linuxbrew never by default. No implicit source build; a build happens only
when the chosen method is one (`go install`) and the review says so.

**D26. Two resolutions**: planned on macOS with an optional, advisory
availability check (the aarch64 package databases, Flathub, `mise lock` in
an isolated folder, `uv pip compile`); checked on the target, read-only,
before anything installs.

**D27. A bounded, deterministic DAG orders the work.** Needs, capabilities,
versioned provider instances, configuration and verification are separate
nodes; Kahn's order with a fixed tie-break; cycles, conflicting instances
and incompatible version constraints become decisions; failures block and
optional edges degrade;
at most 5 000 nodes. The seven layers remain as screen groups. *Set aside:*
layer-only ordering (it could not express a tool needing a tool, or two
versions of one runtime); a solver.

**D28. Paths are rewritten only inside fields an adapter parses.**

**D29. Restore is journaled, resumable and conditionally reversible.** One
immutable, sealed record per step and phase, committed (flush, rename,
directory flush) before the step it announces; after any crash the next run
judges each unfinished step from its records and the filesystem; undo
re-reads the destination and refuses when anything changed; packages,
sign-ins and external effects are never claimed to roll back.

**D30. AI tools are providers shared by `dev` and `restore`** (review
questions O5 and O6). One provider per tool, used by both commands, over one
installer implementation per method. Observation keeps six states apart —
wrapper present, artifact installed, selected version, runnable, configured,
authenticated — read from files; nothing static ever invokes Omarchy's lazy
wrapper, its mise shim or mise, because the wrapper runs `mise use -g` each
time, which installs, rewrites mise's global configuration and resets a pin
to `latest`. Installing runs the same `mise use -g` the wrapper would, so
there is one copy of each tool; no agent version is promised, because the
wrapper selects its own. `dev` keeps its place for a machine without a
profile; the baseline's `dev` module stops installing Claude Code over
Omarchy's wrapper, as a reviewed change to a baseline file.

**D44. Codex's `config.toml` is read by a strict subset reader** (review
question O7). The core parses the subset of TOML that Codex writes and
documents, and refuses the whole file on anything else — no opaque copy, no
pattern-matching that skips valid TOML (docs/AI-TOOLS.md → *Codex's
configuration*). *Set aside:* a full TOML parser in the frontend, which is
not the authority and whose output the core would have to trust.

**D31. Omarchy's default agent is the person's choice, made through
Omarchy.** The restore never runs `omarchy-default-agent` (which opens a
graphical install terminal for a missing agent and always ends by launching
the agent) and never writes its defaults file; the summary says how to
choose. Omarchy's permissive launch modes are shown, not changed, and
authorise nothing in this tool.

## Rescue and debugging

**D32. Rescue is optional, lives in `/root`, and never crosses to the
user.** No global agent policy is installed (review question O3): isolated
workspace rules, a plain statement of root's risk, no claim of a sandbox.

**D42. Remote rescue ends in a verified safe state** (review question O4).
SSH changes are validated (`sshd -t`), the effective policy is checked per
context (`sshd -T -C`), the listener is read, and a real key login and a
refused password login are tested on loopback before rescue is open.
Cleanup ends stopped, key-only retained and handed to the person, or key-only
as before: it stops before removing, predicts the policy without its
drop-in before a running service reloads, and puts the drop-in back if the
real check disagrees. It never reopens password access on a running
service and calls that clean.

**D33. The default debug report is field-allowlisted**; raw diagnostics are
a separate command, `debug raw`, marked potentially sensitive and never put
into an agent's context automatically. The brief separates fixed
instructions from untrusted observed data.

## Journey and qualification

**D34. Ten stages, derived from the machine**; the other system's progress
arrives as typed codes or journey notes and is shown as recorded. Nothing
starts by itself after a reboot.

**D35. Qualification is bound to an active round.** Identity first; then
admission, plan, Shared GUID and schema; then the round this system's own
`active.omb` names, one round awaiting Linux at a time, a cleaned round
never current again, and the step order. The stream is a normative
AES-256-CTR construction with reference vectors; exclusive creation for
names; removal only of what the round's own records name.

**D36. Hardware validation is per model, and evidence is scoped by
behaviour.** Every stage records the claimed commit, the executed source
digest (recomputable from that commit) and the frontend artifact's digest;
a change invalidates only the evidence of the behaviours its files touch.
`frontend-v*` and `hw-*` are the only tags.

## Delivery

**D37. Implementation proceeds through gates** (MILESTONES.md): the
specification first, then the frontend and transport foundation, read-only
equivalence, the action contract under fixtures, the scanner and profile,
the resolver and bundle, then restore and debug, providers, rescue, the
journey and qualification.

**D45. The documents are checked mechanically.** A documentation validator
runs in CI (docs/TESTING.md → *Documentation checks*): cited sections exist,
test ids resolve, states and commands are declared, read commands never
write, and a small set of fixed facts (Bash as the target shell; the
Shared sequence as accepted; `debug save` as the one writing debug command)
hold.

## Rejected

**`sudo -k` before `sudo -v` in Shared's creation.** Proposed earlier and
rejected by the architecture review: the typed word is the intent gate and
`sudo` authorisation is privilege; `sudo -k` does not guarantee a prompt
under every policy, adds credential-cache side effects, does nothing for
target binding, and would be a baseline change with no demonstrated safety
benefit. The accepted sequence stands: typed gates, `sudo -v`, final
topology validation, the creation record, `sudo -n diskutil addPartition`,
the postcondition.

## Resolved review questions

| # | Question | Decision |
| --- | --- | --- |
| O1 | one Bash process per request | keep; local work in the frontend; the gate 2 benchmark (D6) |
| O2 | typed gates where no upstream prompt follows | keep core-validated typed words; authentication is separate (D9) |
| O3 | Claude Code managed settings for a root agent | not installed by default (D32) |
| O4 | SSH after rescue | never restore active password exposure; verified safe final states (D42) |
| O5 | the developer module's Claude Code installer | align with Omarchy through a shared provider; never overwrite the lazy wrapper (D30) |
| O6 | `dev` beside `restore` | keep both commands, sharing providers and verification (D30) |
| O7 | Codex's TOML | a strict subset reader, whole-file refusal (D44) |
| O8 | agent sessions | not in v1 (D41) |
| O9 | unverified upstream facts | split into facts to verify from source before a feature's gate, and facts only the Mac can show in M17 (docs/UPSTREAM.md → *Not verified yet*) |

## Where each design question is answered

| # | Question | Answer |
| --- | --- | --- |
| 1 | What is a Migration Profile? | docs/MIGRATION.md → *The Migration Profile*; D20 |
| 2 | Where does it live before Linux exists? | the macOS state directory (same section) |
| 3 | How does the minimum profile reach fresh Asahi? | it does not need to; only its id, in the token (docs/MIGRATION.md → *Moving between the systems*) |
| 4 | When does the full payload reach Linux? | docs/MIGRATION.md → *Moving between the systems*, *The bundle* |
| 5 | Homebrew formulae → target methods | docs/RESOLVER.md → *The registry*, *Where software comes from on the target* |
| 6 | Casks | docs/RESOLVER.md → *Casks and applications* |
| 7 | Functional equivalents | docs/RESOLVER.md → *Dispositions*, *The graph* |
| 8 | Omarchy-provided or missing | docs/RESOLVER.md → *Omarchy-provided or missing* |
| 9 | aarch64 availability | docs/RESOLVER.md → *Two resolutions: planned and checked*; D26 |
| 10 | Dependency order | docs/RESOLVER.md → *The graph*; D27 |
| 11 | macOS paths | docs/RESOLVER.md → *Paths*; D28 |
| 12 | MCP configuration without executing it | docs/AI-TOOLS.md, per provider, and *Things that execute* |
| 13 | AI configuration safe to copy | docs/AI-TOOLS.md → *What travels* |
| 14 | AI state needing a new sign-in | the same section |
| 15 | Sessions | not in v1 (D41) |
| 16 | Arbitrary dotfolders | docs/MIGRATION.md → *Custom paths: opaque, by consent*, *The bundle*; D40 |
| 17 | Symlinks | docs/MIGRATION.md → *What is carried from each kind of source*; docs/RESTORE.md → *Placing a file* |
| 18 | Existing target files | docs/RESTORE.md → *Conflicts*, *Each item's basis* |
| 19 | An interrupted restore | docs/RESTORE.md → *After a crash* |
| 20 | Rerunning a restore | the same section; D29 |
| 21 | Agents before Omarchy finishes | docs/RESCUE.md → *Agents on this machine, as root* |
| 22 | Rescue state after the user exists | docs/RESCUE.md → *`rescue remove`*, *Root and the everyday user* |
| 23 | The debug report's contents | docs/RESCUE.md → *Safe fields* |
| 24 | Secrets kept out of it | docs/RESCUE.md → *The debug report*; D33 |
| 25 | Continuing across reboots | docs/QUALIFICATION.md → *Across reboots* |
| 26 | Authoritative versus recorded | docs/QUALIFICATION.md → *What each system can see*; SPEC.md → *States* |
| 27 | What moves before Shared | docs/MIGRATION.md → *Moving between the systems* |
| 28 | What moves after Shared | the same section; D39 |
| 29 | Automated cross-system qualification | docs/QUALIFICATION.md → *Qualification* |
| 30 | Over 4 GB without copying digests by hand | docs/QUALIFICATION.md → *The stream*, *The round trip* |
| 31 | Binding to the right Shared and plan | docs/QUALIFICATION.md → *Binding and freshness* |
| 32 | The first install as M17 | docs/QUALIFICATION.md → *Real-hardware qualification (M17)* |
| 33 | What makes an M18 release | docs/QUALIFICATION.md → *Hardware-validated release (M18)*; D36 |
| 34 | Protecting the frozen baseline | D18, D38; docs/TESTING.md → *Equivalence with the accepted baseline*; MILESTONES.md → *Accepted baseline* |
| 35 | Bash as the target shell | docs/RESOLVER.md → *From Zsh to Bash*; D2 |
| — | The frontend: distribution, start-up, the split, the protocol, handoff, lifecycle, the boundary, working without it | docs/FRONTEND.md, docs/PROTOCOL.md; D5–D16, D38, D43 |
| — | The interface | docs/UX.md |
