# Decisions

The product expansion's decisions, each with why and what was set aside.
Numbers are stable; a decision that changes keeps its number and states its
new form. The accepted installer and storage baseline (MILESTONES.md →
*Accepted baseline*) is not reopened here.

## Product

**D1. The source is this Mac's own macOS.** The M1, restored from the
everyday Mac's Time Machine backup and brought up to date, is scanned where
it stands, before Linux exists. *Set aside:* exporting from the everyday Mac.

**D2. The target shell stays Bash.** The Mac is meant to be a Linux and Bash
learning environment. Two literal forms (aliases, allowlisted exports) become
Bash automatically; the Zsh rc files travel as reference copies, never
sourced, and functions are not carried as code (docs/RESOLVER.md → *From Zsh
to Bash*). *Set aside:* Zsh on the target; converting Zsh automatically.

**D3. Ratatui is the product's interface; the Bash core is the authority.**
The frontend presents and collects; the core reads the machine, decides what
is legal, and runs everything. The text interface stays complete for the
install journey and every read, as the recovery and non-interactive surface:
the installer's text flows keep their behaviour and the read commands gain
the new facts. Migration choices are made in the frontend; without it,
`profile` saves the defaults and `restore` keeps every conflict, each after
its typed word, so the text path always lands on the safe choice. *Set
aside:* rewriting the accepted core in Rust; an optional frontend; record
files that stand in for the frontend's choices (`--select FILE`,
`--plan FILE`).

**D4. The product is complete before the first real install**, which is
M17's qualification.

## The frontend and the protocol

**D5. The frontend decides nothing and runs nothing but the core.** It never
computes a plan, judges safety, reads records or user files, or spawns
anything else.

**D6. One short-lived core process per request** (review question O1).
Local navigation, focus, scrolling, search and filtering stay in the
frontend with no core call. Snapshots, validation and actions each start a
fresh core. The budgets: navigation p95 under 50 ms and search p95 under
100 ms with no core call; a small non-disk snapshot p95 under 500 ms; plan
validation after inputs are loaded p95 under 300 ms; a full disk refresh
shows progress at once and is investigated above 2 s. The Gate 2 benchmark
measured them, cold and warm, on the physical M1 and on Linux aarch64, over
small and representative workloads (D53), and O1 is closed with one
limitation recorded, O1-LOGS-P01: on the M1, the full-window Logs detail has
p95 between 540 and 545 ms against its 500 ms target. A later screen is
measured only if it feels slow, and only if start-up then dominates would a
long-lived, bounded **read-only** session be considered; mutation authority
never becomes persistent for speed.

**D7. One record format, with admission before parsing.** ASCII,
tab-separated, percent-encoded, one canonical encoding per value, typed and
schema-ordered, sealed where stored. Every document passes a bounded,
byte-level admission (`head -c`, `wc`, `tr`, `tail`, `od`, C-locale `awk`)
before Bash splits it, because Bash's `read` normalises doubled, leading and
trailing TABs and drops or truncates NULs (reproduced on Bash 3.2 and 5.3);
a tool that fails refuses the document. The Rust side applies the same
rules; a differential corpus and golden examples hold them together. Every
protocol operation has its own record set; codes (the resume token, the
completion and Shared codes) are a `code` type checked by kind, never a
widened `id`; there are no comment lines, and a family that wants notes has
a `note` record. Screens add data, not schema: detail and row kinds,
columns, fact keys, action ids, parameters, and blocker and refusal ids are
values of existing `id` and `text` fields, so a new screen needs no
admission change, corpus case or compatibility ruling. Core and frontend
always ship together — the core refuses any frontend but the one the lock
pins — so an old client never meets a new value. The frontend's requests
are generic: `Validate{action, args}`, `Execute{action, args, word}` and
`Detail{scope, kind}`. *Set aside:* JSON (no parser in the core on fresh
Asahi, and a Bash JSON parser would be a larger trusted surface), plists,
NUL-separated streams.

**D8. The core says what is legal and judges every execute afresh.** An
action is one row of the core's action table: its scope, the text flow's own
functions in the text flow's order, `managed` or `handoff`, and its
interface word or none. The rows are `plan.save` (D56), `asahi.launch`, the
Shared codes, `shared.create`, `network.connect`, `omarchy.start`,
`omarchy.resume`, `shared.activate`, `shared.test` and `dev`, and a snapshot
lists only what the text flow would offer now. In order, the core admits the
request; checks the session's ceiling and scope; takes the run lock and the
scope's operation record (a record from an earlier boot is first reconciled
by the scope's classifier, and a `busy`, `unsupervised`, `failed` or
unreadable one refuses); re-reads the machine; compares the basis, the
SHA-256 of the action id and the gate facts shown; and checks the typed
word. The step runs with the text flow's environment — `umask 022`, never
the core's own 077, and the flow's `OMB_PHASE` — and the scope's classifier
decides the outcome on a fresh read: the expected effect, or a proven
"nothing changed" (an installer quit), removes the record; an unexpected
state keeps it `failed`; lost supervision leaves it `unsupervised`
(docs/PROTOCOL.md → *Executing*). Restore re-checks each item before it is
applied. *Set aside:* free space, battery or a time in the basis, which
drift on a live Mac and would refuse every attempt; a basis schema per
action family.

**D9. Typed words are intent, validated by the core** (review question O2).
Every existing gate stays exactly an intentional-action gate, `start` and
`mount` included, collected by the frontend or the text flow and validated by
the core. The interface word answers the step's first typed-word prompt
once, from a variable the core never exports; every later prompt — `launch`
and `start` after their downloads, `create`, `sudo`, the installers — is
asked on the terminal, which the frontend has handed over, so no word given
for one gate answers another. Nothing that changes the machine is
cancellable, and Ctrl-C in a handoff belongs to the program. Authentication
is a separate matter, left to upstream programs and `sudo` under their own
policies. The baseline's Shared sequence is unchanged. *Set aside:*
answering a flow's later prompts from the frontend; cancelling a step that
changes the machine, which could stop it half-done.

**D10. Release binaries, pinned by a lock outside the build inputs.**
`release/frontend.lock` pins each artifact's SHA-256 and size, and records
`source_commit` and `inputs_digest`: the SHA-256 of a canonical listing of
every Git-tracked file under `frontend/` at the commit, tests included, read
from the commit and never from the working tree, so build output and
untracked files cannot enter it. The build may read nothing outside that
closure, crates.io packages pinned by `Cargo.lock`, and the pinned
toolchain; CI enforces it from rustc's dependency files and `cargo
metadata`. The lock is not a build input, so updating it cannot change what
it records. At run time only the artifact digest counts; CI checks the
commit's `inputs_digest` against the lock's; GitHub attestations link the
artifact to its commit as optional evidence. No updater, no signing
infrastructure. The lock's `source_commit` names the artifact's source,
not the checkout that runs it: a later reviewed commit that changes nothing
under `frontend/` keeps the lock's bytes, its `inputs_digest` and the
artifact, while the core's `hello` names that later commit. Those are two
components' identities, never a mismatch, and the lock is never rewritten to
name the later commit. *Set aside:* excluding tests from the inputs, which
would need a proof that production code never reads them.

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

**D18. The expansion reaches the installer only through the core's action
table, and the accepted baseline is the oracle.** New modules load only for
the commands that need them; the installer's act paths load none; new
functions carry prefixes and never redefine baseline functions. An installer
step is reached only through a row of the core's action table that runs the
text flow's own functions (D8), the same in fixture and real mode, so there
is no second path. Every exposed action is equivalent with the **accepted
baseline, `2edb76a`**, in three ways — the same decisions, the same commands
with the same arguments in the same order, the same resulting state —
through recorded commands and records over fixtures, not only with the new
text path, which could share a regression; each difference is a named,
tested delta on one short list (docs/TESTING.md → *Equivalence with the
accepted baseline*). Every change to a baseline file is a named delta with
its own test. A change to the entrypoint's routing is one even when it adds
no privileged command: `frontend-check` (D48) holds that no existing action
becomes newly reachable, that every other command routes as before, and
that no `sudo`, child-registry action or disk, package or boot authority is
added.

**D38. One process model, with a spool instead of a response pipe.** The
request travels on fd 3, which the core reads (bounded) and closes before
anything else; responses are appended to a per-request spool file the core
opens and closes per record, so no protocol descriptor ever reaches a child
and the core never waits on the frontend. The end of a response is the
core's exit plus exactly one final `result`; anything else is an unknown
outcome, re-derived from the machine. Controllers (launcher, frontend,
cores) and workers (the children they start and their descendants) are
told apart; processes are known by PID, start time and boot session, and
an identity that cannot be established counts as alive. The live launcher
removes its own scratch once its frontend, cores and workers are gone and
no unresolved operation names the session; a later launcher reclaims an
abandoned scratch only when every recorded controller and worker is dead,
with no exemption for anyone. Mutating actions keep an operation record
that survives the death of the process that wrote it (D47). Children's
output follows their class (D46). Nothing is added between the final
Shared topology validation and `sudo -n diskutil addPartition`.

**D46. Children's output is bounded by class, and every retained byte
counts.** A reviewed child registry fixes each child's class, where its
output goes (functional or diagnostic), whether it needs a terminal, and
whether it detaches. A read child's diagnostics drain through `tail -c`,
which keeps draining and never writes more than the last 65 281 bytes; the
limits — 65 536 bytes a child, 262 144 a request, 4 194 304 a session —
cover every retained byte, headers and fixed-size summaries included, with
room reserved before anything is appended, and a saturated scope drains to
`/dev/null` and adds nothing. A mutating child needs no terminal and its
output goes to `/dev/null` or its functional destination, because any
diagnostic pipe or growing file would put a fallible consumer inside a
mutation; a child that needs a terminal is a handoff. Losing diagnostics
changes no outcome, and functional output is never held to diagnostic
limits. *Set aside:* capturing a mutator's output through a drain, which
could block or end it; limits that exclude headers.

**D47. A mutation that loses its supervisor waits for a new boot.** Only
the core that waited for its mutating child, found no worker still present
— no process in the shared group that was not there when the child started,
the controllers remaining as expected — and checked the postcondition
completes an operation. Escaped descendants are ruled out by the child
registry, not by inspection: a managed mutating child leaves nothing
running, or names an owner and completion check for what it leaves. If the
core is gone, or cannot establish quiescence, the operation is
unsupervised: a barrier for its scope, in both interfaces, for the rest of
the boot — a new boot session is the one proof that no old process can
still write — after which reconciliation finds no effect, the expected
effect, or something unexpected, which stays blocked. Read-only orphans
hold nothing. *Set aside:* treating an empty-looking process group as
proof (the controllers are always in it, and a daemonised descendant never
is); a general process tracker.

**D54. An operation record that cannot be read blocks its scope until the
person moves it aside** (docs/PROTOCOL.md → *An operation record that
cannot be read*). Every judgement of D47 starts from the record's fields,
so failing to decode one is never evidence that nothing runs, that the
operation ended or that it left no effect: every act in its scope is
refused, a reboot changes nothing, and reads keep working, `operation
SCOPE` among them (D55). The way out is `operation clear SCOPE`, an act
command of the text interface: under the run lock, on a fresh inspection
that finds the entry unreadable, after the tool says what it cannot know
and the person types `clear`, and only while the entry is the one shown,
it renames it inside `ops` to a kept name no reader takes for a record.
The tool cannot prove that whatever wrote those bytes has stopped — the
boot it ran in is part of what cannot be read — so on this one machine
the person's word, after a restart when in doubt, stands in for that
proof: a scope barred for good on a one-time install is the worse
failure. The move destroys nothing, and the next act's fresh read and
rebuilt basis, never the record's absence, make it safe. *Set aside:*
corruption as no record; clearing by a reboot, a read or time; deleting
or editing the entry; moving one that could not be inspected; sightings,
file times, process trackers, clear transactions and effect-domain
proofs, which serve no moment of one owner's single install.

**D55. The operation-record diagnostic is a detail of the record's own
scope** (built in the core and the text interface at `a3beb3c`, and in the
frontend at `02ffc3b`: docs/PROTOCOL.md → *The operation-record
diagnostic*). The
scope that keeps `ops/<scope>.omb` must already show its barrier and
withhold its act actions, so its snapshot already inspects the record; the
diagnostic publishes that inspection whole, as `detail kind=operation`, a
projection of the snapshot's own data set under its generation, so a
finding and the barrier beside it never describe two moments. The snapshot
keeps one `operation` fact and a blocker of the state's own — `unreadable`
or `undetermined` — and no path, so a value the record
format cannot carry never hides a barrier. Every addition is a value of an
`id`, `bytes` or `text` field: no enum, record type, key or cardinality
changes, so protocol 1 holds by the admission rules both implementations
already apply, not by a ruling for new enum words as CP1 needed. A finding
is delivered `done` whatever it is, D included; only the diagnostic's own
machinery answers `error io`, and only an unrepresentable required value
`error representation`, each with nothing partial. The text interface asks
with a read command of its own, `operation SCOPE`, whose required argument
makes an older checkout refuse it before it touches the state directory.
The contract states, field by field, whether a value is observed, recorded
by a record that admitted, or inferred by a fixed rule, and a `recorded.`
key marks the second on the wire; nothing is shown from a record that
did not admit, a failed lookup is never no record and a check that did not
finish is never an unreadable record, and no worker or effect evidence is
claimed that an existing mechanism has not supplied. *Set
aside:* a new operation (a `req` enum word an older core refuses at
admission, and a generic read made for one question); a new scope (an enum
word the released parser rejects, and a second generation over the
inspection the record's own snapshot already makes, so the two could
disagree); a text-only command (the frontend would have no core answer to
show, and would be left to infer one); protocol 2 (no existing record
changes meaning); the whole finding as snapshot facts (every refresh would
carry it, and an unrepresentable path would take the barrier with it);
keeping `unsupervised` as C's blocker, whose meaning includes clearing by a
new boot; a fingerprint for D, which would make a delivered D depend on the
hash tool that may be what failed.

**D56. plan.save is one managed act with a read-back.** It runs in scope
`plan`, managed, with no typed word, and is not cancellable.
`validate select action=plan.save` takes the eleven inputs — `shared_size`,
`linux_size`, `enc`, `user`, `host`, `kmap`, `tz`, `loc`, `ssh`, `gh` and
`dev` — each judged by the function that owns it in the text flow, and
answers the layout, the installer's answers and a basis over the normalised
inputs, every partition's GUID, offset and size, and the computed plan.
Free space, the resize limit and the floor are checked again at execute and
never bound into the basis, because they drift on a live Mac and would
refuse every save. Execute re-reads and recomputes; it refuses `unavailable` if the plan
has blockers and `changed` if the basis differs; then it sets `CFG_*` and
calls `mac_save_plan`, whose writes stop at the first failure. The outcome
is a read-back, as for every act (D8): `cfg_load` gives exactly the inputs;
with Shared, the intent admits and its digest matches `CFG_plan`, and
without Shared no intent file remains; `planned_at` is set. *Set aside:* a
receipt of the save; a separate review selector; documentary test cases
written before the code; binding free space or the resize limit into the
basis; a rollback.

**D43. The frontend's own persistence follows intent, with one named
exception.** For every ordinary command, only an act session downloads and
caches the frontend, moves aside a bad cached binary, or writes a trace
file; read, plan, dry-run and `--no-tui` sessions report and change nothing
persistent (docs/FRONTEND.md → *Intent and persistence*), and act flows keep
their acquisition as it is. The one exception is `frontend-check` (D48): its
launcher may establish the frontend cache — download after `[Y/n]`, move a
bad copy aside after a yes — while its core session has a read ceiling and
the `journey` scope alone, and it writes no trace. The cache write is the
object under check, not authority over the machine, so the two stay
apart: the launcher's cache authority comes from that command word alone and
is never passed to a core, and a core's authority comes from its session
values alone. No command inherits the exception by having a read session:
`status`, `doctor`, `scan` and every other read command never download or
cache the frontend, and `frontend-check --dry-run` does neither. The cache
changes phase by phase, and a consented phase stays when a later one fails:
a moved-aside mismatch and a promoted, verified binary remain; only this
attempt's own download file is removed, and only once its writer has ended
(docs/FRONTEND.md → *Effects*).

**D48. M14 gate 1's production start is a command of its own,
`frontend-check`.** Gate 1 exposes no baseline action, and every installer
command stays in text until its whole flow is exposed, yet the gate's exit
needs the published artifact started by the launcher on this Mac. A command
whose whole flow is starting the interface — acquire or verify the pinned
artifact, reach the core, show the foundation dashboard, leave — is
finished by a dashboard with no actions, so it keeps the rule instead of
bending it. Its session carries the purpose `frontend-check`, which the
core validates and answers with an action-free snapshot built from the
session alone; every other operation is refused by the core, and every
failure ends the check, never another command (docs/FRONTEND.md → *The
startup check*; docs/PROTOCOL.md → *The startup-check session*). Its exit
status reports what the launcher can observe — the verified frontend ran,
the required core exchanges ended `done`, the terminal's settings came
back, the session was cleaned up — and never that the dashboard was drawn:
the released frontend exits 0 when left on its connecting screen, and a
core it had already asked can answer afterwards, so spools cannot show
receipt. Drawing is shown by the PTY test and seen on this Mac, and gate
1's exit needs the latter. *Set aside:* opening the foundation dashboard
from the default run, which would put an unfinished flow in the
installer's place; counting a fixture launch, which takes another
acquisition path and another snapshot; deferring the production start,
which gives up the first end-to-end evidence of distribution; a new wire
operation, which `hello` and `snapshot` make unnecessary; an
acknowledgement record or a timing rule to prove receipt, which would need
a new frontend release and would still not prove drawing.

**D49. The frontend under development is an unreleased candidate,
`0.2.0`, and the release lock stays exact.** Gate 2 changes `frontend/`, so
its `inputs_digest` no longer equals the one in `release/frontend.lock`, and
it must not be made to: the lock names the published `frontend-v0.1.0`,
whose tag, assets and lock stay as they are (D10). The crate's version
becomes `0.2.0` before its first substantive change, so no changed build
identifies itself as 0.1.0. `tests/frontend-inputs.sh lock` keeps its one
meaning — the frontend's inputs equal the published release's — and still
fails on a difference. A separate command, `candidate VERSION [COMMIT]`,
classifies the other honest state: an unreleased frontend whose version is
the expected next one, whose digest differs from the pinned release's as
expected, whose lock that commit's own lock admission accepts (the
launcher's reader, run from the commit's `lib/`, never a second parser),
whose pinned release is intact and whose protocol still equals the core's;
it never says the candidate is released. CI accepts a commit when `lock` passes, when no lock exists, or
when `candidate` passes for the version the workflow names — a number edited
on purpose, never read from `Cargo.toml`. Every other difference stays a
failure, and the release workflow never runs `candidate` and stays exact.
Gate 2 publishes nothing: a manual look starts a build of the candidate as
`OMB_FRONTEND_DEV` over a fixture, as D16 requires, and no command exists
only to show it. `0.2.0` is that release: tag `frontend-v0.2.0`, source
`eea4076`.
*Set aside:* letting `lock` accept a larger version, which turns a failure of
the exact oracle into a success; changing the lock so CI passes; a preview
release; a production command for viewing an unfinished interface.

**D50. Gate 2's reads use the ordinary session contract; there is no new
purpose.** `snapshot`, `detail` and `validate` are read operations the
ordinary contract already names, constrained by the session's intent, scopes
and ceiling, and nothing on the read surface reaches `execute`: no baseline
action is listed, and `plan.save` is named by `validate` alone. A new
purpose would widen a reviewed authority table for the convenience of one
gate, and nothing needs it: the property the gate needs — a read that
persists nothing — belongs to the operations, which run with read intent and
no persistence. What the frontend says about its authority comes from the
core, from `hello`'s ceiling and the snapshot's action list, never from
fixed text. The startup-check session stays the one closed purpose, its
snapshot byte for byte. Gate 2's reads answer only in fixture mode (D16). If
a review finds a property the ordinary contract cannot express, a purpose is
proposed then, with that property named. *Set aside:* a `frontend-read`
purpose.

**D51. The interface's presentation follows the approved reference
design.** docs/UX.md's earlier direction is replaced for presentation by a
panelled one: a dark-navy backdrop (xterm index 17) at 256 colours and above, single-line panels
with cyan outlines and blue headings, green for what is current, focused or
ok, a branded banner, a navigation rail, a workspace, a context sidebar and
a footer of keys and authority. The references decide how the interface
looks; the core's records decide what it says, so no image supplies a fact,
a stage name, a version, a status or a capability. Kept as hard rules: no
true-colour requirement, no Nerd Font or emoji, one-cell glyphs, ASCII, the
Linux console, `NO_COLOR`, sixteen colours, reverse focus, no colour alone,
keyboard reach, no mouse capture, the 60×20 floor with its truthful stop, and
never bold with a colour. The backdrop is painted only at 256 colours and
above, and no state depends on it. Panel nesting stays at two. *Set aside:*
keeping hairlines; bold headings; a palette the console cannot show.

**D52. Gate 2's read surface keeps the accepted baseline's meaning.** The
oracle stays `2edb76a` (docs/TESTING.md → *Equivalence with the accepted
baseline*); tests may read the baseline's text and the frontend never does.
The `log` data set is what `logs` shows: the last 40 lines of the last sorted
matching path selected by `cmd_logs`, not the mtime-newest file;
a longer window would be a separate reviewed delta. Any difference from the
baseline — including one the record format forces, such as a value longer
than the format allows — is named, bound to the review that accepts it, and
tested on its own. **`CP0-Q3b-overflow`** settles the deferred log producer: when
any selected line cannot be represented within the canonical record and value
limits, measured after encoding, the whole answer is `refused` with code
`overflow` and presents no row — never a partial or truncated success, never
a larger window. The plan is validated and its answer shown, never saved:
Gate 2 has the operation, its contract, its equivalence, its read-effect
proof and its benchmark, and a read-only presentation that collects the two
sizes, sends `validate select action=plan.save`, and shows the core's
normalised sizes, installer answers, warnings, refusals and review basis —
no save, no action and no execute. The Storage Planner, its scale bar and
the Safety Gate belong to the gate that exposes their actions. *Set aside:*
a 2 000-line log window; an executable planner in this gate.

**Gate2-read-representation-failure.** For
ordinary journey `snapshot` and `detail kind=machine|status`, required
authoritative content that violates the frozen Protocol-1 representation
contract returns `error representation`, the fixed safe text
`The required journey response cannot be represented in Protocol 1.`, empty
`next`, and the SHA-256 of empty bytes with `total=0`. No candidate data or
unusable generation is published. This means the response supplies no dataset;
it says nothing about whether the actual journey is empty.

Whole-journey representability covers snapshot facts, guide, conditional token,
blockers and messages, and every machine/status row, including off-page rows.
After ordinary admission/authority/kind checks, capture once and establish
representability before computing the current generation or resolving changed
and offset behavior. Every legal contiguous page (limits 1..500) must fit;
pageable rows need not fit together in one response. Canonical admission of the
complete exact requested response precedes publication of its exact admitted
suffix after the existing truthful hello. Staging, admission machinery and hash
failures retain `error io`; only established wire invalidity is representation.

Baseline validators, configuration loading, raw saved-user token presence and
`token_encode` remain the owners. No required value is dropped, truncated,
sanitized or replaced. Representable data keeps its existing bytes, ordering,
whole-scope generation and paging semantics. Protocol 1, its schemas and
cardinality remain unchanged. This rule settles only the authorized journey
reads; `CP0-Q3b-overflow`, Doctor Q2, Logs Q3a and Validate Q4 remain unchanged.

**D53. The O1 workloads are not reduced.** The representative workload of
the `bench-*` benchmark (docs/TESTING.md) — 2 000 items and 400 profile
entries — is met with fixed synthetic loaded data where the real dataset
does not exist yet: the frontend's navigation, search and render
benchmarks run over deterministic loaded models of both sizes, and the core's
benchmarks run over the read families Gate 2 implements. The two are
reported separately. `bench-snapshot` measures the fixture-free
`frontend-check` journey snapshot as a core-only complete request, its four
facts neither padded nor substituted for the loaded models. A workload that
returns no work is invalid, not fast, and each one proves its work before it
is timed. Timing is never taken beside the test suite. O1 is closed (D6); a
later screen is measured, on these rules, only if it feels slow. *Set
aside:* deferring the 400-entry workload until profiles exist; a 2 000-line
production log to reach 2 000 items.

**PLIST-M01.** `plist_get` in `lib/macos.sh` publishes the extracted bytes
on success and nothing on failure, keeping the extraction's nonzero status;
empty, false, zero and multiline values keep their meaning. A failed
extraction could otherwise print text that its callers took for data. It is
a named change to a baseline file (D18), and **CP1-PLIST-M01** is the one
exception to CP1's byte preservation that it brings: removing the false
blocker the defect produced also corrects the derived guide and changes the
journey generation, and nothing else may differ.

## Migration

**D19. The scanner runs no inventoried tool.** It reads the package
managers' own records with fixed read-only utilities (`find`, `plutil`,
`wc`, `od`, `awk`); it never runs `brew`, `npm`, `cargo`, `uv`, `go`, `mise`
or an AI tool, whose listing commands update, write, fetch or execute
configuration. Each adapter has a versioned contract, and every item carries
its evidence (`observed`, `inferred`, `unknown`); a missing field is never
turned into certainty. `brew bundle dump` is not used.

**D20. The Migration Profile is one sealed record of choices, bound to this
Mac.** The frontend sends the selection, defaults included, as one
`omb-select` document; `profile` saves it as `profile.omb`, and a rescan
keeps choices by item id and reports what is gone and what is new. It comes
before the plan. *Set aside:* draft and finished profile files; a profile
id; `prof=` in the resume token, since restore lists the bundles it finds
with their origin and time (D39).

**D21. The bundle is a content-addressed folder of plain objects with one
sealed manifest.** No archive; no link, special or hard-link objects;
hash-named objects and one sealed `bundle.omb`, written as `.partial-*` and
then renamed; every destination checked against one grammar for the whole
bundle — no `..`, no absolute path, no control byte, nothing beneath a link,
no duplicates. Export never deletes anything, on Shared or in the folder the
person names, so no export can lose data there; a failure leaves only
`.partial-*`. *Set aside:* symlink objects; a destination graph; any
removal, even of export's own leftovers.

**D22. Before Shared, only the token, the repository and the frontend need
to cross; after it, the bundle.** Removable media can carry a bundle at any
time. *Set aside:* bundles made on another Mac (D1).

**D39. Integrity is the seal and the object digests; consent is the typed
`restore`.** Nobody but the owner's two systems writes Shared, so the seal
and the object digests are there to catch corruption. Restore lists the
bundles it finds, with their origin and time, and the typed `restore` after
the review is the consent. The `ombbundle` code kind stays in the record
admissions, unused. *Set aside:* an approval code shown on macOS and
recomputed on Linux, and a typed `import`: nobody else writes Shared, so
neither checks anything the seal and the review do not; signing
infrastructure.

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
supported adapter understands is `opaque`: excluded by default, included
only after one typed `opaque` per save, which covers the chosen folders
together (Shared is not encrypted), outside the secret guarantee, with known
credential files still refused inside it and the scan still applied. This
keeps the arbitrary dotfolder picker without pretending to vouch for what it
carries. *Set aside:* a typed word for each path.

**D41. No sessions or histories in v1** (review question O8). Agent sessions,
transcripts, prompt histories, agent memory and shell history do not
travel; history settings do.

**D24. Resolution is deterministic and reviewable.** A pure function of
this repository's migration map and the person's decisions (D26). No model
decides an installation. Package names are data, passed as argument arrays;
the AUR is never used automatically, and nothing is built implicitly.

**D25. Where software comes from, in order**: already there, pacman through
`omarchy-pkg-add`, Omarchy's helpers, mise runtimes, mise's aqua and GitHub
backends, Flathub, uv, cargo-binstall, Go, npm; the AUR never automatically;
Linuxbrew never by default. No implicit source build: cargo-binstall, Go and
Flathub installs are printed as commands to run by hand.

**D26. Resolution comes from this repository's migration map and is checked
on Linux.** `data/migration-map.omb` (`map`, `choice` and `note` records)
covers the owner's real inventory; an item it does not resolve becomes a
decision — skip it, or "try pacman NAME", shown as a guess. Linux decides
what is available, read-only, before anything installs (`pacman -Si`).
*Set aside:* registry versions; a local registry; an availability check on
macOS (the aarch64 package databases, Flathub, `mise lock`,
`uv pip compile`), which would fetch on the Mac only to guess what Linux
decides.

**D27. Fixed layers order the work**: packages, runtimes, ecosystem tools,
AI tools, files, settings, in that order, so a runtime is in place before
the tools that need it; one version per runtime. *Set aside:* a dependency
graph, provider instances and a solver, with what only they express: a tool
needing a tool of its own layer, and two versions of one runtime.

**D28. Paths are rewritten only inside fields an adapter parses**
(`p:home`, `p:brew-bin`, `p:shared`); in a file carried whole, macOS paths
are listed in the review, never rewritten.

**D29. Restore keeps one append-only run log, and backups.** Each run
appends to its own log (`restore/runs/<run>.log`), with `sync` after each
line and a torn last line ignored; a stop resumes, and a rerun re-judges
each item from the filesystem and changes nothing already in place. The
safety core stays: never as root; Keep by default; each item re-checked
before it is placed; after a device check, the original moved aside whole
into backups and compared before anything takes its place; files, folders
and links placed with no-clobber forms that fail if anything appeared; undo
only where the destination is unchanged. The residual race is stated: a program holding
the old file open writes into the backup, and a structured setting's owner
command has no compare-and-set, so a write by another program just before
it is overwritten and not detected. Packages, sign-ins and external effects
are never claimed to roll back. *Set aside:* a sealed record per step and
phase, a crash table, a generic merge and an automatic undo, which serve no
moment of one owner's single restore.

**D30. AI tools are one table shared by `dev` and `restore`** (review
questions O5 and O6). `lib/agents.sh` has one row each for Claude Code,
Codex and OpenCode. Observation keeps four facts apart, read from files:
installed (a mise install folder, or a binary from elsewhere), ran at
restore, configured, and a sign-in file present. Nothing static ever invokes
Omarchy's lazy wrapper, its mise shim or mise, because the wrapper runs
`mise use -g` each time, which installs, rewrites mise's global
configuration and resets a pin to `latest`; the one exception is
`mise x <tool> -- <tool> --version`, with a timeout, right after installing.
Installing runs the same `mise use -g` the wrapper would, so there is one
copy of each tool; no agent version is promised, because the wrapper
selects its own. Sign-in is a handoff to the tool; its own `mcp list` runs
on request and is shown unparsed; sign-in files are never read, and MCP
secrets travel as variable names. `dev` keeps its place for a machine
without a profile and stops counting Omarchy's lazy wrappers as installed
tools; the baseline's `dev` module stops installing Claude Code over
Omarchy's wrapper, as a change to a baseline file (D18). *Set aside:* six
observed states (wrapper, artifact, selected version, runnable, configured,
authenticated), which need checks that run the tools; a provider per tool
over one installer per method.

**D44. Codex's and mise's configuration are read by a strict TOML subset
reader, on macOS only** (review question O7). `lib/toml.sh` parses the
subset of TOML that Codex and mise write, and refuses the whole file on
anything else, listing it — no opaque copy, no pattern-matching that skips
valid TOML (docs/AI-TOOLS.md → *Codex's configuration*). It has size and
nesting bounds, and its tests use files as Codex and mise write them. On
Linux, Codex's file is kept or replaced whole, so no TOML is parsed there.
*Set aside:* a full TOML parser in the frontend, which is not the authority
and whose output the core would have to trust; the `toml-test` conformance
corpus as a gate, which tests far more TOML than the reader accepts.

**D31. Omarchy's default agent is the person's choice, made through
Omarchy.** The restore never runs `omarchy-default-agent` (which opens a
graphical install terminal for a missing agent and always ends by launching
the agent) and never writes its defaults file; the summary says how to
choose. Omarchy's permissive launch modes are shown, not changed, and
authorise nothing in this tool.

## Rescue and debugging

**D32. There is no rescue mode, and nothing crosses from root to the
everyday user.** No agent runs as root, there is no rescue workspace and no
rescue SSH server; recovery help is docs/TROUBLESHOOTING.md and the agent
brief that `debug` prints (D33). `restore` never runs as root, and the
everyday user's AI tools are installed through Omarchy's mechanism and
signed in as that user (D30). On one install, root agents and a listening
rescue server would add risk at the system's most fragile moment. *Set
aside:* agents as root, a rescue workspace and their removal; managed
settings for a root agent (review question O3).

**D42. Before Omarchy Mac's setup, `start` turns off the image's password
SSH** (review question O4). The Asahi Alarm image accepts SSH passwords
(`alarm` / `alarm`, `root` / `root`). `start` runs
`systemctl disable --now sshd`, checks `is-active` and `is-enabled`, and
reports a failure, so no password SSH is left listening once it has run.
`doctor` classifies SSH from `sshd -T` as root — `off`, `key-only`,
`passwords` or `cannot-tell` — names the `alarm` password and prints
`sudo passwd -l alarm`. SSH comes back only through `dev` → SSH. *Set
aside:* a rescue-owned SSH server; a failed-password probe as evidence.

**D33. `debug` is one read command, and it prints only fixed text and
facts**: the fixed agent brief, with the exact `journalctl` commands to run
by hand, and the status and doctor facts — never a log line, journal line,
command output or file content — with a root line only when run as root.
The brief's fixed instructions stay apart from the observed facts. It
writes nothing; `debug > file` keeps a copy. *Set aside:* raw diagnostics,
a context dump and a saved report, which would put what the tool cannot vet
into an agent's context; a debug schema.

## Journey and qualification

**D34. Ten stages, derived from the machine**; the other system's progress
arrives as checked typed codes or a checked exported bundle and is shown as
recorded. Nothing starts by
itself after a reboot. *Set aside:* journey notes.

**D35. Qualification is three steps in one folder on Shared, and the files
present say which is due.** `qualify` (typed `test`; on Linux as the
everyday user) runs only after the baseline's Shared identity check, in
`omarchy-mac-bootstrap/qualify/` on Shared. Step 1, on macOS, writes a file
of random bytes over 4 GiB and the fixed test names, with the SHA-256 the
writer computed; step 2, on Linux, checks them and writes its own; step 3,
on macOS, checks Linux's and writes the result. Rerunning step 1 starts
over, and a pass removes the data files. *Set aside:* rounds and an
`active.omb`, provisional candidates, replay protection, a specified
AES-CTR stream with reference vectors, and a separate clean-up command:
nobody but the owner's two systems writes that folder.

**D36. M17's `report` on the M1 is the hardware record; there is no
hardware-validated release.** Stage records hold only the commit and the
time, and `frontend-v*` is the only tag. *Set aside:* executed-source
digests, evidence scoped by behaviour, and `hw-*` tags, for a tool that
runs once on one Mac.

## Delivery

**D37. The rest is built in one session, in three phases** (MILESTONES.md
→ *The finish*): A is Gate 3, Gate 4 and Gate 5; B is M15-A, M15-B and
M15-C; C is M16 and the release. Within a phase, units that own different
files run in parallel on workers, and the session alone edits the shared
files and integrates. Code comes first, and a design document is brought to
the built design when its milestone closes. Each phase has one cross-vendor
review, read-only, through NativePeers — a Codex worker (`gpt-6.1-sol`,
`xhigh`) and a Claude worker — and every high and medium finding is fixed
before the phase merges; a phase that changes disk authority, `sudo`, the
Shared creation or activation, the storage planner, secret handling,
restore placement or the safety allowlists adds a third, adversarial Codex
worker. FAST runs on each push as feedback and focused suites run locally;
FULL runs at each phase's end and at the commit the owner installs from,
with one rerun of failed jobs allowed for a timing failure, noted in the
commit. Nothing waits for the owner. The tool is built for one install on
one Mac, so one review of a whole phase, which sees how its parts meet, is
worth more than a review of each slice, and the third worker goes where a
mistake cannot be undone. *Set aside:* documentation-only contracts and
documentary test cases written before the code; a review per slice; moving
the baseline's actions one family at a time, each with its own safety
review; authorising gate by gate.

**D45. The documents are checked mechanically.** A documentation validator
runs in CI (docs/TESTING.md → *Documentation checks*): cited sections exist,
test ids resolve, states and commands are declared, read commands never
write, and a small set of fixed facts (Bash as the target shell; the
Shared sequence as accepted; `debug` as the only debug command, which
writes nothing) hold.

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
| O1 | one Bash process per request | keep; local work in the frontend; signed off by the Gate 2 benchmark, with O1-LOGS-P01 recorded (D6) |
| O2 | typed gates where no upstream prompt follows | keep core-validated typed words; authentication is separate (D9) |
| O3 | Claude Code managed settings for a root agent | none: no agent runs as root (D32) |
| O4 | SSH on the fresh system | `start` turns off the image's password SSH and checks it; `doctor` classifies SSH (D42) |
| O5 | the developer module's Claude Code installer | align with Omarchy through the shared table; never overwrite the lazy wrapper (D30) |
| O6 | `dev` beside `restore` | keep both commands, sharing one table and its observation (D30) |
| O7 | Codex's TOML | a strict subset reader, whole-file refusal (D44) |
| O8 | agent sessions | not in v1 (D41) |
| O9 | unverified upstream facts | split into facts to verify from source before a feature's gate, and facts only the Mac can show in M17 (docs/UPSTREAM.md → *Not verified yet*) |

## Open review questions

Raised by M14 gate 2's source reads and ruled on by the independent review at
its first checkpoint. A question that is deferred blocks only the work named
beside it, and no code depends on another question's answer.

| # | Question | Why it was open | Ruling of the independent review | What it blocks |
| --- | --- | --- | --- | --- |
| Q1 | Which provenance and derivation do a stage's records carry? | Protocol 1 has `machine` and `recorded`, with `by=macos|linux` for recorded remote progress. | **Settled by M16-stage-records.** Ordinary journey snapshots emit ten ordered stages; startup-check snapshots emit ten blocked identity-only stages. A checked bundle establishes Linux's recorded profile and resolve progress. | The current derivation and current-stage rule live in docs/QUALIFICATION.md → *The journey*, implemented by `lib/journey.sh` and checked by `tests/test-journey.sh`; the read schema is in docs/PROTOCOL.md → *The Gate 2 read surface*. |
| Q2 | Which scope owns the doctor's data set? | Doctor's reads are a superset of `status`'s and include network probes (`sys_reachable`, `sys_net`), so it cannot share the `journey` generation without making every journey snapshot as slow and as networked as a doctor run. No scope in the enum names health, and adding one changes an existing enum. | **RESOLVED: `health` / `doctor`.** One authoritative `cmd_doctor` invocation owns counts and rows; `Gate2-health-representation-failure` governs required unrepresentable content (docs/PROTOCOL.md → *Future health and logs producers*). | Nothing: CP1 added the scope, and the Health producer is built (`27f79d6`). |
| Q3a | Which scope owns the log's data set? | `debug` is the scope of the M15 report; `journey` would couple the log's changes to the journey's generation. | **RESOLVED: `logs` / `log`.** The baseline's last sorted matching path and exact last-40-line window own the dataset; full path, context, presence and exact window bytes/order bind its generation (docs/PROTOCOL.md → *Future health and logs producers*). | Nothing: CP1 added the scope, and the Logs producer is built (`a0ba61c`). |
| Q3b | How is a line the record format cannot carry answered? | `logs` prints a whole line, the record format bounds a value (4 KiB), and `log_event` does not bound a line. | **Resolved, named `CP0-Q3b-overflow` (D52).** Any unrepresentable line in the complete selected 40-line window makes snapshot/detail `refused overflow` with empty generation and fixed safe text before changed/offset handling. No partial metadata/rows, truncation or larger window. Required location metadata instead uses `error representation`; operational discovery/read/capture failure uses `error io` (docs/PROTOCOL.md → *Future health and logs producers*). | No semantic question remains; the Logs producer implements it. |
| Q4 | How is a plan the disk cannot support answered, and what are `invalid`'s codes? | `blocker` is forbidden in `validate`'s answer; `parse_size` and `plan_validate` return prose, not codes; the baseline's planner file is a safety-reviewed file. | **RESOLVED.** Shared-first validation, effective whole-decimal-GB sizes, deterministic first parameter error, finite invalid vocabulary, `refused unplannable`, distinct infrastructure/invariant/representation errors and the plan's basis (D56) are accepted (docs/PROTOCOL.md → *Future plan validation contract*). | Nothing further: `lib/validate.sh` implements it, over fixtures and on a real Mac, and no planner/parser owner changed. |
| Q5 | Which benchmark id does a macOS journey snapshot belong to? | It runs the detection `status` runs, which reads the disk, while `bench-snapshot` is *a small snapshot that reads no disk* and `bench-disk` is a full disk refresh. | **RESOLVED FOR MEASUREMENT.** macOS journey/detail are `bench-disk`; Linux journey/detail are `bench-journey-linux`; future health/logs/validation classifications, component boundaries and local initiation feedback are recorded in the benchmark section of docs/TESTING.md. D53 remains binding. | Nothing: O1 is signed off, with O1-LOGS-P01 recorded (D6). |
| Q6 | May `validate` name `plan.save`, which `execute` refuses? | The golden and the basis family name `plan.save`; the action is not exposed until Gate 3. | **Accepted (Q6-A).** `validate` may name `plan.save` as the validation and basis family while `execute plan.save` stays unavailable and no Gate 2 snapshot lists it as an action. Naming it confers no authority, and validation saves nothing. | Nothing. |

**PROTOCOL 1 REMAINS SUFFICIENT — REVIEWED ADDITIVE SCOPE EXTENSION.**
The accepted semantic checkpoint resolves Q2, Q3a, Q4 and Q5 with CP1 as the
only authorized implementation prerequisite. CP1 appends exactly `health|logs`
to the synchronized Bash and candidate Rust scope enums. Existing names,
ordering, protocol version, framing, cardinality and product requests remain
unchanged. Compatibility is request-selected: every exchange the released
0.1.0 client requests remains in the old language; new scopes appear only
when an updated client explicitly requests them. That client against an old
core fails closed, with no fallback, retry under `journey`, alias or scope
substitution. The actual released parser continues rejecting new-scope
documents. This is a ruling for these two values, not a rule that arbitrary
future enum additions are compatible. CP1 itself adds no producer, UI or
action authority.

After CP1, the ordinary fixture-only producers are built: Logs at
`a0ba61c`, Health (Doctor) at `27f79d6` and Validate at
`b01610e69a2eef6e5a52f5ede18236210699704e`. O1 is signed off with
O1-LOGS-P01 recorded (D6), and the frontend's read-surface integration, in
the 0.2.0 frontend, is built at
`c855f6197be86e90f5fb833f7faec0d0f6372794`, which closes Gate 2
(MILESTONES.md → *Gate 2 — Read-only equivalence*).

### The unreadable-record questions, settled

| # | Question | Settled by D54 |
| --- | --- | --- |
| UR-Q1 | delete the entry or keep it? | kept, renamed inside `ops`, until the person deletes it |
| UR-Q2 | what holds before a clear? | the run lock, a fresh `unreadable` finding (any kind), the typed `clear`, the entry unchanged since shown |
| UR-Q3, UR-Q5 | who reconciles without the record, and what can that prove? | no one, nothing; the next act checks the machine afresh |
| UR-Q4 | how are the writers known to be gone? | they cannot be: the person's word, after a restart when in doubt |
| UR-Q6 | which wire words? | D55's; acts stay `refused unsupervised`, their text naming the clear |
| UR-Q7, UR-Q8 | which operation and surfaces? | D55's snapshot, detail and `operation SCOPE`, plus `operation clear SCOPE` |
| UR-Q9 | is admission enough? | no: another scope's record, or an action the scope lacks, is `unreadable` |

FJ-ED-1, FJ-P5-1 and the conservative legacy-C policy are withdrawn
unimplemented; their text stays in Git (`f27ee84`, `c85470b`, `1956f1b`).

## Where each design question is answered

| # | Question | Answer |
| --- | --- | --- |
| 1 | What is a Migration Profile? | docs/MIGRATION.md → *The Migration Profile*; D20 |
| 2 | Where does it live before Linux exists? | the macOS state directory (same section) |
| 3 | How does the minimum profile reach fresh Asahi? | it does not need to: before Shared, only the token, the repository and the frontend cross (docs/MIGRATION.md → *Moving between the systems*; D22) |
| 4 | When does the full payload reach Linux? | docs/MIGRATION.md → *Moving between the systems*, *The bundle* |
| 5 | Homebrew formulae → target methods | the migration map (D24, D26); docs/RESOLVER.md → *Where software comes from on the target* |
| 6 | Casks | docs/RESOLVER.md → *Casks and applications* |
| 7 | Functional equivalents | docs/RESOLVER.md → *Dispositions* |
| 8 | Omarchy-provided or missing | docs/RESOLVER.md → *Omarchy-provided or missing* |
| 9 | aarch64 availability | checked on Linux with `pacman -Si` (D26) |
| 10 | Dependency order | fixed layers (D27) |
| 11 | macOS paths | docs/RESOLVER.md → *Paths*; D28 |
| 12 | MCP configuration without executing it | docs/AI-TOOLS.md, per tool, and *Things that execute* |
| 13 | AI configuration safe to copy | docs/AI-TOOLS.md → *What travels* |
| 14 | AI state needing a new sign-in | the same section |
| 15 | Sessions | not in v1 (D41) |
| 16 | Arbitrary dotfolders | docs/MIGRATION.md → *Custom paths: opaque, by consent*, *The bundle*; D40 |
| 17 | Symlinks | a folder whose root is a link is followed once; the bundle holds no links (D21) and restore places none (D29) |
| 18 | Existing target files | docs/RESTORE.md → *Conflicts*; D29 |
| 19 | An interrupted restore | the run log: a stop resumes (D29) |
| 20 | Rerunning a restore | each item is judged again from the filesystem, and nothing already in place changes (D29) |
| 21 | Agents before Omarchy finishes | none as root: there is no rescue mode (D32); `debug` prints the fixed brief (D33) |
| 22 | Rescue state after the user exists | none: there is no rescue mode (D32) |
| 23 | The debug report's contents | D33; docs/TROUBLESHOOTING.md |
| 24 | Secrets kept out of it | fixed text and facts only, never a log line, command output or file content (D33) |
| 25 | Continuing across reboots | docs/QUALIFICATION.md → *Across reboots* |
| 26 | Authoritative versus recorded | docs/QUALIFICATION.md → *What each system can see*; SPEC.md → *States* |
| 27 | What moves before Shared | docs/MIGRATION.md → *Moving between the systems*; D22 |
| 28 | What moves after Shared | the same section; D22, D39 |
| 29 | Automated cross-system qualification | docs/QUALIFICATION.md → *Qualification*; D35 |
| 30 | Over 4 GB without copying digests by hand | the writer's SHA-256 travels beside the file on Shared (D35) |
| 31 | Binding to the right Shared and plan | the baseline's Shared identity check comes first (D35) |
| 32 | The first install as M17 | docs/QUALIFICATION.md → *Real-hardware qualification (M17)*; D36 |
| 34 | Protecting the frozen baseline | D18, D38; docs/TESTING.md → *Equivalence with the accepted baseline*; MILESTONES.md → *Accepted baseline* |
| 35 | Bash as the target shell | docs/RESOLVER.md → *From Zsh to Bash*; D2 |
| — | The frontend: distribution, start-up, the split, the protocol, handoff, lifecycle, the boundary, working without it | docs/FRONTEND.md, docs/PROTOCOL.md; D5–D16, D38, D43 |
| — | Gate 1's production start, and its authority | docs/FRONTEND.md → *The startup check*; docs/PROTOCOL.md → *The startup-check session*; D10, D18, D43, D48 |
| — | Gate 2's read surface, generations and paging | docs/PROTOCOL.md → *The Gate 2 read surface*; D50, D52, D53, and *Open review questions* |
| — | Executing an action, plan.save among them | docs/PROTOCOL.md → *Executing*; D8, D9, D18, D56 |
| — | An operation record that cannot be read | docs/PROTOCOL.md → *An operation record that cannot be read*; D47, D54 |
| — | Its diagnostic's request, answer, words and interfaces | docs/PROTOCOL.md → *The operation-record diagnostic*; D55 |
| — | An unreleased frontend candidate | D49; docs/FRONTEND.md |
| — | The interface | docs/UX.md; D51 |
