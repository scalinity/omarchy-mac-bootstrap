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
trailing TABs and drops or truncates NULs (reproduced on Bash 3.2 and 5.3);
a tool that fails refuses the document. The Rust side applies the same
rules; a differential corpus and golden examples hold them together. Every
protocol operation has its own record set; codes (the resume token, the
completion, Shared and approval codes) are a `code` type checked by kind,
never a widened `id`; there are no comment lines, and a family that wants
notes has a `note` record. *Set aside:* JSON (no parser in the core on fresh
Asahi, and a Bash JSON parser would be a larger trusted surface), plists,
NUL-separated streams.

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

**D18. The expansion cannot reach the installer's paths, and the accepted
baseline is the oracle.** New modules load only for the commands that need
them; the installer's act paths load none; new functions carry prefixes and
never redefine baseline functions. Each baseline action exposed through the
protocol is compared with the **accepted baseline, `2edb76a`**, through
recorded commands and records over fixtures — not only with the new text
path, which could share a regression. Every change to a baseline file is its
own reviewed safety delta. A change to the entrypoint's routing is one even
when it adds no privileged command: adding `frontend-check` (D48) gets its
own focused safety review, which holds that no existing action becomes
newly reachable, that every other command routes as before, and that no
`sudo`, child-registry action or disk, package or boot authority is added.

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

**D54. An operation record that cannot be read stays a barrier until an
explicit, evidenced clear** (the Gate 3 prerequisite; a contract accepted at
`152c8f68854368025816b926494dbec0e94bc903`, not implemented:
docs/PROTOCOL.md → *An operation record that cannot be read*). Failing to decode a record is never
evidence that nothing runs, that the operation ended or that it left no
effect, because every judgement of D47 starts from the record's fields and
none is available. Looking and reading are judged apart, so an inspection
that failed is told from bytes that were read and refused, and neither
becomes no record. Unreadable rests only on an inspection whose every step
completed, never on a reason code alone, since the current seal check
reports a tool that failed as `seal`; what could not be established stays
undetermined. No record itself means only that nothing is recorded as
begun and unsettled, since each act's fresh read and rebuilt basis, not the
record's absence, make it safe; and a readable record whose core's liveness
is unknown stays excluded without being called supervised. Read commands
keep working, and a read-only
diagnostic reports what can be established without trusting the bytes —
the entry's kind, owner, size and fingerprint, admission's reason code,
worker evidence and effect certainty — and nothing taken from them. No
boot, age, count, read or reconciliation clears the record: a reboot ends
the old boot's processes but cannot say the record came from that boot,
because its boot session is part of what cannot be read. A clear is an
action the core lists, with a typed word, bound by its basis to the
inspected bytes, recorded before it changes anything, and taken by rename
and confirmed as an abandoned run lock is cleared; it is offered only when
no recorded process is alive or unknown, the processes that could have
written those bytes are proven gone, and the scope's reconciliation finds
nothing unexpected; it proves nothing about the past and resumes nothing.
Those conditions make a clear eligible, an authorized attempt, never a
completed one. Its record is its own, so the ordinary operation record's
pre-write never overwrites the entry it is for; it is complete only when
verified complete, and one that began and is not — interrupted, or stopped
by an entry that is not the one inspected — keeps the scope barred as the
unreadable record did, even with `ops/<scope>.omb` gone, and preserves what
it took. A completed clear gives a later request nothing to rely on: each
act inspects afresh. The frontend presents and never decides (D5). The
mechanisms this leaves open are UR-Q1 to UR-Q9 (*Open review questions*).
*Set aside:* treating corruption as no record; a reason code as proof that
its check ran; the record's path being empty as proof that a clear
finished; clearing on a reboot; file times as proof of which
boot wrote the bytes (a process of the person can set them, and the clock
can move); the person's word in place of the boot-change proof; showing an
unadmitted record's fields, even marked as unverified; a frontend that
reads `ops/`; an automatic clear after reconciliation, which a readable
record gets only because its action and basis are known.

**D55. The operation-record diagnostic is a detail of the record's own
scope** (accepted at `2840fe2`; its core and text implementation is
independently accepted at `a3beb3cba82681fc949ac35d4edf0c132d2cb0fd`:
docs/PROTOCOL.md → *The operation-record diagnostic*). The
scope that keeps `ops/<scope>.omb` must already show its barrier and
withhold its act actions, so its snapshot already inspects the record; the
diagnostic publishes that inspection whole, as `detail kind=operation`, a
projection of the snapshot's own data set under its generation, so a
finding and the barrier beside it never describe two moments. The snapshot
keeps one `operation` fact and a blocker of the state's own — `unreadable`,
`undetermined`, `unsettled-clear` — and no path, so a value the record
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
claimed that the open UR-Q3, UR-Q4 and UR-Q5 have not supplied. *Set
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
only to show it. When `0.2.0` becomes a release is a later gate's decision.
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

**Gate2-read-representation-failure (accepted independent ruling).** For
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
reported separately. A workload that returns no work is invalid, not fast,
and each one proves its work before it is timed. Timing is never taken
beside the test suite. *Set aside:* deferring the 400-entry workload until
profiles exist; a 2 000-line production log to reach 2 000 items.

**Review-resolved benchmark-target clarification at accepted V
`b01610e69a2eef6e5a52f5ede18236210699704e`:** `bench-snapshot` measures the
already accepted fixture-free `frontend-check` journey snapshot, as a core-only
complete request. This narrow exception to ordinary fixture-backed core
benchmark workloads resolves the pre-implementation semantic STOP; the mapping
was not previously explicit. It changes no production session or Protocol
semantics, and runs no frontend executable. The startup-check's four facts are
not padded or substituted for D53's separate loaded-model obligations. Every
other workload, platform, repetition, meaningful-work and timing obligation
above remains binding. Exact timing and work-witness rules are in the
benchmark section of docs/TESTING.md.

**PLIST-M01 production prerequisite (historical Class A candidate record).** Independent
review confirmed a MEDIUM, prerequisite-blocking compatibility defect: failed
Apple plist extraction can emit stdout that callers consume as structured data.
The bounded remediation on diagnostic head
`6a191f46ece7d9fceeb2b8538b0cb05b0599d154` changes only `plist_get` in
`lib/macos.sh` and its contract comment. Success publishes the extracted bytes;
failure publishes nothing and retains the extraction's nonzero status. Empty,
false, zero and multiline successful values retain their semantics. This is a
candidate awaiting independent confirmation, not finding closure.
Historical BASE remains `2edb76a7de3f78ec90927ac93d5eec3a84636253`.
The static Shared safety pin permits only the explicit candidate helper/comment
replacement in the whole BASE `macos.sh`; other pinned files and the critical
interval remain unchanged. The seven benchmark commits through diagnostic H
remain UNACCEPTED; the harness is FROZEN pending prerequisite review.
Benchmark completion has not resumed, Q5 is RESOLVED FOR MEASUREMENT, O1 is
PENDING, and Gate 2 remains IN PROGRESS.

**CP1-PLIST-M01 preservation ruling (historical Class D candidate record).** Independent review selected
"CP1 PRESERVATION EXCEPTION REQUIRED — BOUNDED TEST/DOC REMEDIATION AUTHORIZED"
on PLIST candidate P `86b8c02aff9938bace32d05a464e2086d6ee3465`.
The Class A production helper correction alone was insufficient to reconcile
the frozen response oracle: removing its known-false blocker also corrects the
owner-derived next guide and changes the whole-Journey generation. Class D
permits only the exact witnessed blocker/derived-guide/generation exception,
with independent dataset hashes, own-generation complete details and explicit
cross-generation changed refusals. The known-false C observation is not desired
truth. Default byte preservation, language/parser and runtime authority remain
unchanged; this grants no general owner-delta permission. Only the CP1 test and
three status/contract docs may change on P; production, Rust and benchmark bytes
remain frozen. PLIST-M01 remains REMEDIATED IN CANDIDATE — AWAITING INDEPENDENT
CONFIRMATION. Benchmark is FROZEN/UNACCEPTED, Q5 RESOLVED FOR MEASUREMENT,
O1 PENDING and Gate 2 IN PROGRESS.

**Prerequisite acceptance and benchmark resume authorization (before B review).**
Independent review returned **PLIST-M01 PRODUCTION PREREQUISITE ACCEPTED**:
**PLIST-M01 CLOSED** at P2 `f91c19574cb8b0c8d3d0e1a16181c374476d7dd3`,
prerequisite-only. The accepted H-to-P2 carve-out includes the Class A helper,
historical Shared safety pin and CP1-PLIST-M01 Class D exception, exact-P2 CI
and release/Protocol integrity. The preceding candidate records remain
historical facts. The prerequisite freeze is lifted:
**BENCHMARK HARNESS / GATE 2 MEASUREMENT PREPARATION ONLY MAY RESUME**.
The seven V-to-H benchmark commits remain UNACCEPTED; the harness is a candidate
awaiting focused independent review of V through the final benchmark candidate,
with H-to-P2 carved out as the accepted prerequisite. Reviewing only the resumed
P2 delta is insufficient. Q5 remains RESOLVED FOR MEASUREMENT, O1 PENDING,
Gate 2 IN PROGRESS and frontend 0.2.0 UNRELEASED. Accepted prerequisite files
remain frozen; no authoritative O1 campaign, optimization or product work is
authorized by this preparation slice.

**BENCH-M01 bounded remediation authorization.** Independent review at B
`6129d07bd6cf04a4fd9a98773231677fb1473375` returned **BENCHMARK HARNESS
REMEDIATION REQUIRED** for the single blocker **BENCH-M01 — Required core
timing decomposition is absent**; other V-to-B methodology was credited.
This candidate adds benchmark-private acknowledged-boundary companions with
explicit startup/admission/owner-probe observations and separate complete
Validate acquisition/computation. The real complete-request stopwatch/budgets
and loaded bench-validate stay unchanged. Exact definitions, applicability,
non-additive populations, transformation identities, equivalence proofs and
overhead limitations are in bench/README.md. PLIST-M01 remains CLOSED at P2;
accepted proofs/product files stay frozen. BENCH-M01 is **REMEDIATED IN
CANDIDATE — AWAITING INDEPENDENT CONFIRMATION**, harness UNACCEPTED, O1 PENDING.
The next checkpoint is **BENCH-M01 CLOSURE / FINAL BENCHMARK-INSTRUMENT
ACCEPTANCE REVIEW** of B through the final remediation candidate, using the
completed V-to-B assessment as integration base. If closed with no new concrete
blocker, proceed directly to **O1 AUTHORITATIVE MEASUREMENT CAMPAIGN /
SIGNOFF-EVIDENCE COLLECTION ONLY**, under that separate authorization. No
generic preparation milestone, optimization, frontend source, product UI or
release is authorized.

**O1 performance signoff and O1-LOGS-P01.** The independent review returned
**GATE 2 PERFORMANCE SIGNOFF ACCEPTED — LOGS FINDING RECORDED**. Official
populations: the final physical M1 Pro macOS population, 52 of 52 cases and
10,400 of 10,400 ordinary repetitions, and the retained complete Linux ARM64
population, 50 of 50 cases and 10,000 of 10,000 ordinary repetitions — 102 of
102 cases and 20,400 successful ordinary repetitions, with zero ordinary
failures, timeouts and missing samples. The historical hosted-Mac population
and the interrupted first physical-Mac attempt are excluded from the official
macOS population. The physical-Mac results were supplied measurement
evidence; the retained Linux raw evidence was inspected independently. Raw
artifacts and historical result bytes stay outside the repository and are
not modified. **O1-LOGS-P01** — physical-macOS full-window Logs detail
exceeds the strict target p95 < 500 ms: cold offset-0 limit-500 p95
544.667 ms, cold offset-1 limit-500 p95 541.182 ms, warm offset-0 limit-500
p95 540.411 ms, warm offset-1 limit-500 p95 543.766 ms. The four stay true
**MISS** results; the target is not raised and they are not relabelled.
Disposition: **ACCEPTED LIMITATION — NON-BLOCKING FOR GATE 2 PERFORMANCE
SIGNOFF**. No optimization was performed and none is authorized; the finding
stays visible until a later measurement establishes compliance. The
frontend's own pending feedback while Logs is read is presentation, never a
workaround for this finding or evidence about the core's target. Gate 2 as a
whole remains IN PROGRESS until the frontend's read-only integration and
equivalence are accepted. The same authorization admits that integration:
the Welcome screen, the Journey dashboard, machine and status details,
Health, Logs, and a read-only presentation of plan validation, over the
accepted core reads and Protocol 1, with no action, save or execute
authority.

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
judges each unfinished step from its records and the filesystem. A
replacement moves the destination aside whole and compares it with what
was reviewed; placing uses primitives that fail if anything appeared
(`link`, `symlink`, `renameat2` with `RENAME_NOREPLACE`); a cross-device
replacement is refused rather than copied. The residual race is stated: a
program holding the old file open writes into the backup, and a structured
setting's owner command has no compare-and-set, so a write by another
program just before it is overwritten and not detected. Undo re-reads the
destination and refuses when anything changed; packages, sign-ins and
external effects are never claimed to roll back.

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
configuration*). It has size and nesting bounds and is held to the
`toml-test` conformance corpus before M14 gate 4 closes; it is a real
parser to maintain, accepted for that. *Set aside:* a full TOML parser in
the frontend, which is not the authority and whose output the core would
have to trust.

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

**D42. Remote rescue runs its own SSH server and ends in a verified safe
state** (review question O4). A rescue-owned `sshd` with a configuration
this tool writes whole — no `Include`, no `Match`, so one effective policy
for every connection — is validated and inspected offline (`sshd -t -f`,
`sshd -T -f`) before it listens, runs as a transient systemd unit, and is
open only after a real key login. The system's own server is classified;
an exposed one, or one whose `Match` blocks make it unprovable, is stopped
for this boot before remote rescue opens, and never restarted by cleanup.
Cleanup stops the rescue server and removes its files. Hardening the
system's server is a separate choice, only for `Match`-free
configurations, checked offline first and released to the person. *Set
aside:* changing the system's configuration for rescue and sampling
connection contexts, which cannot cover every `Match`; a failed-password
probe as evidence.

**D33. The default debug report is field-allowlisted**; raw diagnostics are
a separate command, `debug raw`, marked potentially sensitive and never put
into an agent's context automatically. The brief separates fixed
instructions from untrusted observed data.

## Journey and qualification

**D34. Ten stages, derived from the machine**; the other system's progress
arrives as typed codes or journey notes and is shown as recorded. Nothing
starts by itself after a reboot.

**D35. Qualification is bound to an active round, and macOS decides it.**
Identity first; then admission, plan, Shared GUID and schema; then the
round macOS's own `active.omb` names, from immutable `created`, `finished`
and `cleaned` records, one round awaiting Linux at a time, and the step
order. Linux, which cannot know what macOS cleaned, accepts at most one
candidate, provisionally; only macOS's active round can pass. The stream is
a normative AES-256-CTR construction with reference vectors; exclusive
creation for names; removal only of what the round's own records name.
*Set aside:* a cross-boot freshness proof for Linux, which would buy only
the avoidance of provisional work.

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

## Open review questions

Raised by M14 gate 2's source reads and ruled on by the independent review at
its first checkpoint. A question that is deferred blocks only the work named
beside it, and no code depends on another question's answer.

| # | Question | Why it was open | Ruling of the independent review | What it blocks |
| --- | --- | --- | --- | --- |
| Q1 | Which provenance and derivation do a stage's records carry? | SPEC.md → *States* and the `stage` schema give two provenances, `machine` and `recorded`; docs/QUALIFICATION.md → *The journey* names three (`machine`, derived on this system this run, `recorded`) and defines each stage's *done when* for M16. The baseline's rail has six stations and defaults some of their states (on macOS `omarchy` and `dev` are always *to do*; on Linux `survey`, `plan`, `asahi` and `reboot` are always *done*; `plan` is *done* when a plan is recorded, not when a fresh read of the disk agrees). No stage's baseline derivation equals its M16 rule. | **Accepted for Gate 2.** The frontend shows the canonical ten stations as *later* and no `stage` record is emitted. No stage completion, progress or provenance is inferred before the milestone that owns its derivation. A new provenance value, or an M16 derivation before M16, would be a protocol decision and is not made. | Nothing further in Gate 2. |
| Q2 | Which scope owns the doctor's data set? | Doctor's reads are a superset of `status`'s and include network probes (`sys_reachable`, `sys_net`), so it cannot share the `journey` generation without making every journey snapshot as slow and as networked as a doctor run. No scope in the enum names health, and adding one changes an existing enum. | **RESOLVED: `health` / `doctor`.** One future authoritative `cmd_doctor` invocation owns counts and rows; `Gate2-health-representation-failure` governs required unrepresentable content (docs/PROTOCOL.md → *Future health and logs producers*). | CP1 scope compatibility is the prerequisite. Producer, client, screen, equivalence and benchmark implementation remain unauthorized. |
| Q3a | Which scope owns the log's data set? | `debug` is the scope of the M15 report; `journey` would couple the log's changes to the journey's generation. | **RESOLVED: `logs` / `log`.** The baseline's last sorted matching path and exact last-40-line window own the dataset; full path, context, presence and exact window bytes/order bind its generation (docs/PROTOCOL.md → *Future health and logs producers*). | CP1 scope compatibility is the prerequisite. Producer, client, screen, equivalence and benchmark implementation remain unauthorized. |
| Q3b | How is a line the record format cannot carry answered? | `logs` prints a whole line, the record format bounds a value (4 KiB), and `log_event` does not bound a line. | **Resolved, named `CP0-Q3b-overflow` (D52).** Any unrepresentable line in the complete selected 40-line window makes snapshot/detail `refused overflow` with empty generation and fixed safe text before changed/offset handling. No partial metadata/rows, truncation or larger window. Required location metadata instead uses `error representation`; operational discovery/read/capture failure uses `error io` (docs/PROTOCOL.md → *Future health and logs producers*). | No semantic question remains; the future log producer implements it. |
| Q4 | How is a plan the disk cannot support answered, and what are `invalid`'s codes? | `blocker` is forbidden in `validate`'s answer; `parse_size` and `plan_validate` return prose, not codes; the baseline's planner file is a safety-reviewed file. | **RESOLVED.** Shared-first validation, effective whole-decimal-GB sizes, deterministic first parameter error, finite invalid vocabulary, `refused unplannable`, distinct infrastructure/invariant/representation errors and `Q4-plan-validation-basis-v1` are accepted (docs/PROTOCOL.md → *Future plan validation contract*). | Nothing further: the separately authorized ordinary fixture-only Validate producer implements it (accepted at `b01610e69a2eef6e5a52f5ede18236210699704e`), and no planner/parser owner changed. |
| Q5 | Which benchmark id does a macOS journey snapshot belong to? | It runs the detection `status` runs, which reads the disk, while `bench-snapshot` is *a small snapshot that reads no disk* and `bench-disk` is a full disk refresh. | **RESOLVED FOR MEASUREMENT.** macOS journey/detail are `bench-disk`; Linux journey/detail are `bench-journey-linux`; future health/logs/validation classifications, component boundaries and local initiation feedback are recorded in the benchmark section of docs/TESTING.md. D53 remains binding. | O1 signoff is accepted, with O1-LOGS-P01 recorded and open (the O1 performance signoff record above). |
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
future enum additions are compatible. CP1 adds no producer, UI or action
authority; Doctor, Logs, Validate, benchmarks and S4+ remain unauthorized.

Current authorization after CP1: S4's ordinary fixture-only Logs producer
was separately authorized and is accepted at `a0ba61c`; S4's ordinary
fixture-only Health (Doctor) producer is accepted at `27f79d6`. The ordinary
fixture-only Validate producer is accepted at
`b01610e69a2eef6e5a52f5ede18236210699704e`. O1 signoff is accepted with
O1-LOGS-P01 recorded; the frontend read-surface integration is authorized
(the O1 performance signoff record above), implemented in the unreleased
0.2.0 candidate, and accepted at `c855f6197be86e90f5fb833f7faec0d0f6372794`,
which closes Gate 2; S5+ remain unauthorized (MILESTONES.md → *Gate 2 —
Read-only equivalence*).

Historical questions, options and recommendations raised by the Gate 3
prerequisite contract (D54; docs/PROTOCOL.md → *An operation record that
cannot be read*), for its independent review. They were not settled by that
contract; each blocked only the work named beside it. The subsequent
dispositions below govern continuation; the historical UR-Q4 sighting
recommendation is not accepted writer-end authority.

| # | Question | Why it matters, and the evidence | Options | Recommendation | What it blocks |
| --- | --- | --- | --- | --- | --- |
| UR-Q1 | Does a clear delete the entry, or keep it aside? | Deleting destroys the only trace of an unknown operation; keeping it needs a place no reader takes for a record (the launcher lists `ops/*.omb`) and a rule for how long. The precedents differ: an abandoned run lock is moved aside, confirmed and deleted (`lib/state.sh`); a mismatching frontend binary is moved aside and kept (D43). | (a) delete once renamed and confirmed; (b) keep aside, private, under a name no reader takes for a record; (c) keep aside, then delete by a later explicit step | (b): an entry a clear may take is at most 64 KiB (UR-Q2) and is the evidence of what could not be read, and a kept copy changes no barrier | the clear's last step; not the barrier or the diagnostic |
| UR-Q2 | Exactly what must hold before a clear is offered? | D54 fixes P1 to P5. Not settled: an entry that is not a plain file (a link is never followed), a plain file over the 64 KiB limit (no fingerprint without an unbounded read, which §2 forbids), and D (nothing to bind a clear to). | (a) P1 to P5, plain files within the limit only, every other entry left to the person; (b) also other entries, bound by kind and a link's own text, never followed; (c) over-limit files bound by size and a bounded prefix | (a) first, (b) as a reviewed extension; never (c), since a prefix is not the file | the clear |
| UR-Q3 | Who reconciles a scope when the record's action is unknown? | Only the fixture's `core_reconcile` exists; it chooses by `CO_ACTION` and needs `CO_BASIS`. The scope's own records stay the authority for what happened (docs/PROTOCOL.md → *Operations and exclusion*). Gate 3 brings the real actions, and the way out of *something unexpected* is defined nowhere, readable record or not. | (a) each scope's owner judges every action of the scope against the machine, an action it cannot judge without a basis counting as unexpected; (b) one generic judgement in the core; (c) no reconciliation, the clear after the person acknowledges it | (a), owned per scope as Gate 3 exposes each action; reject (c), which puts the clear in reconciliation's place | P5, and so the clear |
| UR-Q4 | How does the tool know that the processes that wrote unreadable bytes are gone, and which identities may a diagnosis read? | D47 makes a new boot session the one proof, taken from the record's `boot` field, which C cannot read. Session scratches can show a live process but cannot tie it to the record, a later session reads them today only to decide removal (docs/PROTOCOL.md → *The session scratch*), and a handoff program may detach. | (a) the tool records a sighting of the unreadable entry — its fingerprint and the boot session — when an act session first meets it, and a later boot with the same fingerprint discharges P4; (b) file times against the boot time; (c) the person's word; (d) none: never clear | (a), written only by an act request with the checked writer, as a record of its own: one restart, the same as for an unsupervised record; reject (b) and (c) (D54); reading scratches for P3 reviewed with it as a new use of an existing record | P3 and P4, and so the clear; not the barrier or the rest of the diagnostic |
| UR-Q5 | What can reconciliation prove without the record? | A readable record's reconciliation knows the action and basis: `completed` compares the effect with the basis (the fixture's effect file holds the basis prefix). Without them, a completed effect cannot be told from an unexpected one wherever its content depends on the basis. | (a) per action: *no effect* where it can be shown, *completed* only where the scope's own records prove it (a creation record, a journal, a classification), otherwise unexpected; (b) an effect consistent with some basis counts as completed; (c) the person decides | (a) | P5 |
| UR-Q6 | Which wire vocabulary? | C is refused `unsupervised` and shown as `blocker id=unsupervised` (Gate 1), whose documented meaning includes clearing by a new boot, which does not hold for C. D has no answer of its own (it falls into no record or C). The clear's action id, word and answer texts, and the diagnostic's texts, do not exist. §4 lists the refusal codes, and the CP1 ruling covers only its own two additions. | (a) keep `unsupervised` with distinct texts and fix; (b) a refusal code and blocker id of C's own, and `unavailable` for D (its existing use when supervision cannot be established: an unidentified boot, an unwritable record); (c) a new protocol version | (b), reviewed as a vocabulary addition to protocol 1 with the released client's handling of an unknown code checked, as CP1 was; until then (a) | the implementation's answers; not the contract |
| UR-Q7 | Is a separate diagnostic operation or scope needed? | §4 answers per scope with `snapshot` and `detail`, whose kinds are added by review (`doctor`, `log`); D50 set aside a new purpose for reads; the text interface must say the same (D3); the documentation checks fix the command names, and the contract names none. | (a) facts and the barrier in the scope's snapshot, the whole finding as a `detail` kind; (b) a new operation; (c) a new scope; (d) a text-only command | (a), under the record's own scope, with the text interface's form decided with UR-Q8 | the diagnostic's implementation |
| UR-Q8 | Can the existing surfaces carry it safely? | The foundation's journey snapshot shows C today, fixture only. The ordinary Gate 2 reads, `status` and `doctor` read no operation record and are held to the baseline (D52); the startup check must not read one; the debug report's fields are allowlisted (docs/RESCUE.md → *Safe fields*) and include no operation; the launcher reads records only to keep a scratch. Today's fix text advises removal by hand once the operation is known to have ended, which no one can learn from the record. | (a) each surface gains fixed facts, as its own reviewed change; (b) only the scope's snapshot and the diagnostic carry it | (a): the scope's snapshot and a journey summary of barriers; the text interface in the reviewed baseline change Gate 3 already names; the debug report an operation-state enum and admission's reason code per scope; the startup check unchanged; the fix text naming the diagnostic instead of removal | each surface's change, separately |
| UR-Q9 | Is admission enough to call a record readable? | `core_op_read` reads no `scope` field, so a record whose scope differs from its path is read as the path's; one naming an action this core does not have is read, and reconciles to `unexpected`. | (a) as today; (b) a record whose scope differs from its path, or whose action is not one of its scope's, is C | (b): it is not this scope's record, and C keeps it blocked with the same diagnostic | the classification's implementation |

The prerequisite's review is concluded. Its first review required the
remediation of UR-C01 to UR-C03; the re-review of `806a879..ba21467` closed
them and raised UR-C04; the final re-review closed UR-C04 and accepted the
contract at `152c8f68854368025816b926494dbec0e94bc903` (**GATE 3
PREREQUISITE CONTRACT ACCEPTED**; MILESTONES.md → *Gate 3 — The action
contract under fixtures*). UR-Q2 and UR-Q9 are accepted as that review
ruled; UR-Q1 and UR-Q3 to UR-Q8 stay open, each blocking the work beside it,
and Gate 3's implementation is not started.

The read-only diagnostic interface contract (D55; docs/PROTOCOL.md → *The
operation-record diagnostic*) then took the dispositions below, and its
focused independent review accepted them at
`2840fe2efc0b240ccb9343f6013912d6fc941a6f` (**GATE 3 READ-ONLY DIAGNOSTIC
INTERFACE CONTRACT ACCEPTED**): UR-Q7, and the diagnostic's parts of UR-Q6
and UR-Q8. A question it touches stays open, blocking the implementation,
in every part the third column names.

| # | State after the prerequisite's acceptance | Disposition (D55), accepted | Stays open |
| --- | --- | --- | --- |
| UR-Q1 | open | none | all of it |
| UR-Q2 | accepted: a clear only for a plain file read in full within the stored-document limit, every other prerequisite still required | — | — |
| UR-Q3 | open | none: the diagnostic runs no reconciliation and reports the effect `unknown` | all of it |
| UR-Q4 | open | none: for C, D and an unsettled clear the diagnostic reads no recorded identity and reports workers `unknown` | all of it |
| UR-Q5 | open | none | all of it |
| UR-Q6 | open | the diagnostic's part, accepted: the `operation` detail and row kind, its keys, values, labels and texts; the `operation` fact's values; the blocker ids `unreadable`, `undetermined` and `unsettled-clear`; D as a delivered `done` finding naming its failed step; the fixed `error io` and `error representation` texts | the act refusals' codes and texts for C and D (C is refused `unsupervised` today, and D falls into A or C); the `busy` refusal's text for unknown liveness; the clear's action id, typed word and answers; a wire value for `unexpected`; every other Gate 3 action's vocabulary |
| UR-Q7 | open | accepted: recommendation (a), made precise: the record's own scope; its `snapshot` carries the barrier and `detail kind=operation` the finding, from one inspection under one generation; no new operation, scope, purpose or protocol version | nothing of the transport |
| UR-Q8 | open | the diagnostic's part, accepted: the record's scope snapshot (fact and blocker), the detail, the read command `operation SCOPE`, and the frontend's presentation rules; status, Doctor, Logs, the debug report, the startup check and the ordinary Gate 2 reads unchanged | a journey summary of barriers across scopes; operation fields in the debug report; act refusal texts that name the diagnostic; the act entry's check in the launcher (Gate 3's reviewed baseline change); any other surface |
| UR-Q9 | accepted: a record naming another scope, or an action its scope does not own, is C; a scope's own action merely unavailable now is not corruption | — | — |

### UR-Q4 owner disposition — conservative legacy-C policy

**DECISION RESOLVED — CONSERVATIVE LEGACY-C POLICY.** For unreadable
operation record C whose writer-end history cannot be independently
established, the existing refusal/barrier remains authoritative and no
automatic clear is permitted. Matching fingerprints, a reboot alone,
absent recorded processes, timestamps, inode equality, seals and
self-declared provenance cannot establish P4. No retrospective sighting,
privileged custody machinery, generalized process tracker or refused-act
persistence exception is introduced.

This resolves the policy decision, not **P3/P4 POSITIVE PROOF IMPLEMENTED**:
that capability is unsupported. P1–P5 have not been satisfied. D54's
conditional clear eligibility and U1–U33 remain intact; unknown writer-end
history cannot satisfy their prerequisites. The conditional writer-end
statements require independently established history for the current
unreadable generation, not equality of observations before and after a
restart. D55 still reports C's workers/effects as unknown, reads no recorded
identity or scratch for C, and writes no sighting.

The earlier UR-Q4 feasibility investigation and unaccepted local candidate
`b79bec92588a580f04c87fcdec2808344a058f87` remain historical; the candidate
is not inherited. The proof failure was that an earlier-boot sighting and
equal later bytes do not establish continuity/writer exclusion for the
current unreadable generation. This decision neither supplies that proof
nor prohibits every future independently evidenced recovery design.
Separately authorized manual recovery may occur outside this proposed
automatic-clear mechanism; no manual recovery implementation or execution
authority is granted here. UR-Q1 and the remaining UR-Q6/UR-Q8 stay open for
recovery/clear. Non-destructive D55 presentation does not depend on them
(MILESTONES.md → *Gate 3 critical path after the legacy-C decision*).

### Foundation journey effect-domain prerequisite — accepted

**UR-Q3 / UR-Q5 P5-20 PROOF BLOCKER — CONFIRMED** by independent review.
The source counterexample is fake-handoff's `keys_out` overwrite with
`effect=none`: both fixed effect files may be absent while meaningful
synthetic state changed. Other configured output destinations and the
handoff-child override are not independently covered by the current basis,
source digest or result records. Repeated mutable configuration reads also
mean a pre-action digest does not establish actual consumption. The
external source-only blocker package remains historical evidence; no
normative completion commit was made for that slice.

**FJ-ED-1 — ACCEPTED AS A DOCUMENTATION CONTRACT**, documentation only
(docs/PROTOCOL.md → *Foundation journey effect-domain contract*).
Independent GPT-6 Pro review accepted source tree
`29ac7b58502618a72295375ff68b9b326f765fd6` at the reported local checkpoint
`f27ee84a4b28fe5ee3a93df53f79598192932468`, compared with `a3beb3c` / tree
`8e483db6d078ad57cf0af7dac2c8a6e6a244a843`: no HIGH or MEDIUM findings,
all 24 FED cases adequate and both future witnesses accepted. Acceptance
attaches to source content; unpublished commit identity/parentage were
verified locally for this continuation, not authenticated by that reviewer.
The accepted branch remains an immutable historical checkpoint. This
acceptance implements no mechanism and accepts none of UR-Q3, UR-Q5 or UR-Q4.

The proposed boundary is the existing journey act pair `test.mutate` and
`test.handoff`, with `test.read` kept read-class. Relevant writes are bounded
synthetic effect files with independently retained prior and expected states.
Instrumentation may be excluded from meaningful payload comparison only
through exclusive generation-owned slots, object/parent identity and
non-alias enforcement, bounded output and verified lifecycle; neither its
name nor a temporary-directory location supplies those guarantees.

The proposed future mechanism is a reviewed adapter consuming latched
retained source/configuration, plus a narrow object-bound filesystem helper.
Arbitrary host destinations, unmanaged escape behavior and unidentified or
unreviewed handoff overrides cannot inherit positive coverage. An override's
digest alone supplies identity, not a complete effect-domain guarantee.
The ordinary legacy testing seam is preserved as uncovered; the accepted
code, fixtures and registry are unchanged by this candidate.

An original act core that passed its existing exclusion/preflight/basis/word
checks would commit an independently discoverable journey incarnation,
complete bounded generation/domain/source/prior-state evidence and launch
gate before the first child effect. It would later publish generation-bound
completion only from its own supervision and verified postconditions.
Complete discovery covers both act families and every retained generation;
it does not decode C or select the latest convenient result. The proposed
private stored-family constraints add no Protocol 1 response/request words.
Seals supply integrity; core-origin publication, issuer/write-site separation
and independently established incarnation/continuity must separately supply
provenance. Their absence, replay, conflict or unknown external writer blocks.

The contract gives concrete future no-effect and independently completed
controls and FED-01–FED-24. They are unexecuted contract proofs conditional
on the named **UNIMPLEMENTED** adapters, latched consumption/source closure,
object helper, exclusive durable publisher, stored admission/catalog,
original-core completion and instrument lifecycle. They are not current
capabilities or acceptance of P5-20. Legacy corrupted operations lacking
historical destinations/inputs stay unknown; new records cannot reconstruct
that missing history. The run lock is not external-writer exclusion.

The foundation UR-Q3/UR-Q5 documentation prerequisite is accepted as
FJ-P5-1 below. Runtime P4 still precedes P5; P1–P5 plus basis/word precede
a clear attempt; verified clear completion precedes reliance on that
transaction. UR-Q4's policy is resolved above; positive P3/P4 capability
remains unsupported for legacy C with unknown writer-end history. The
unaccepted local `b79bec9` candidate is not inherited. UR-Q1 and the
remaining UR-Q6/UR-Q8 stay open for recovery/clear.
No recovery, clear, sighting, new diagnostic evidence reader, action
implementation or later action-owner generalization is authorized here.
Shared creation's transaction remains creation-specific; later Gate 3
owners must supply their own independently reviewed domain/evidence rules.

### Foundation journey P5 reconciliation continuation — accepted

**FJ-P5-1 — ACCEPTED AS A DOCUMENTATION CONTRACT**, documentation only
(docs/PROTOCOL.md → *Foundation journey P5 reconciliation contract*).
Independent acceptance attaches to reconstructed source tree
`a84298a315e54edfe985a81e858f423839c1c007`, not authentication of its
unpublished commit object. The local association was verified separately:
`c85470b2c973001c9df692eb04e17628d5c7f7f0`, parent
`f27ee84a4b28fe5ee3a93df53f79598192932468`, on the clean unchanged
`m14-gate3-p5-reconciliation-contract` checkpoint. That parent's tree is
the independently accepted FJ-ED-1 tree
`29ac7b58502618a72295375ff68b9b326f765fd6`, directly after accepted
diagnostic `a3beb3cba82681fc949ac35d4edf0c132d2cb0fd` / tree
`8e483db6d078ad57cf0af7dac2c8a6e6a244a843`. Both FJ mechanisms remain
**UNIMPLEMENTED**; acceptance changes no normative rule, matrix, witness
or implementation limitation.
The semantic owner is the authoritative foundation Bash core under the
reviewed journey fixture contract. The generic coordinator requires its
complete positive finding; it cannot supply another scope's semantics.
The complete roster is the journey act pair, test.mutate and test.handoff,
with test.read preserved as read-class. Every applicable retained generation,
consumed source/input, domain, prior and original-core evidence is admitted
independently of C and checked against fresh scope-owned observations.

| Question | Accepted bounded rule | Disposition and remaining dependency |
| --- | --- | --- |
| UR-Q3 | foundation journey owner judges every applicable act family and generation under FJ-ED-1; legal future internal assessment after separate P4, no repair/persistence | foundation documentation ACCEPTED; overall PARTIAL / REMAINING OPEN; other scopes require their own reviewed owners and domains |
| UR-Q5 | each relevant item must be unchanged prior state or independently completed under authoritative original-core generation evidence, with complete fresh agreement and usable interval; otherwise retain observed and/or unknown reasons | foundation documentation ACCEPTED; overall PARTIAL / REMAINING OPEN; no plausible basis, missing lookup, partial coverage or old receipt can establish positive P5 |

P5-01–P5-20 and additional adversarial cases preserve the two accepted future
witnesses. G1's failed ordinary barrier is settled by separate readable
D47/new-boot reconciliation before G2 admission. G2's no-effect control
stops before ordinary failed-record replacement; its completion control stops
before ordinary removal/result. The independent step-3 object binding cannot
silently associate an unbound replacement or prove who wrote C. Known object
mismatch differs from an unavailable comparison. Source/configuration is the
retained consumed version, never today's mutable file as historical evidence.

Complete aggregation includes both-family history and justified latest state
for reused destinations, noninterference/lifecycle for every exclusion, and
independently established provenance/continuity. Known unexpected or
basis-dependent unjustified effects prevent positive P5; missing/failed
authority or coverage remains unknown. An observed fact beside unknown
coverage is retained without pretending the whole inspection completed.
D54's meanings and D55's current read-only answers remain unchanged.

Assessment findings exist only for their supported observation/use interval
and decision point. Rechecks reject changes but equal endpoints cannot prove
absence of intervening writes. The run lock is not external-writer exclusion.
Future clear use must re-establish all P1–P5, basis/word and a separately
reviewed continuity guard or equivalent atomic recheck-and-take over the
entry and relevant evidence/effects. This proposal grants none of that
authority and stores no durable reconciliation result. P4 precedes P5;
eligibility is not verified clear completion.

UR-Q4's conservative legacy-C policy is resolved; positive P3/P4 proof
remains unsupported, and `b79bec9` stays unaccepted and uninherited.
UR-Q1 and remaining UR-Q6/UR-Q8 stay open, including future assessment/clear
entry, act vocabulary and any additional surface. No accepted diagnostic,
read, refused act, reboot or frontend gains evaluator or write authority.
For plan save, installer/network/Omarchy, each Shared lifecycle operation
and backup, separate scope-owned domain/evidence/reconciliation contracts
remain necessary; creation's topology authority is not activation/write-test
coverage. No broader implementation, M15 restore or M16 qualification is
required or authorized. Gate 3 remains incomplete, frontend 0.2.0 unreleased,
and all FJ-ED-1/P5 mechanisms unimplemented. Foundation documentation
acceptance is recorded; execution and implementation require separate
authorization, tests, CI and independent review of the resulting slice.

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
| — | Gate 1's production start, and its authority | docs/FRONTEND.md → *The startup check*; docs/PROTOCOL.md → *The startup-check session*; D10, D18, D43, D48 |
| — | Gate 2's read surface, generations and paging | docs/PROTOCOL.md → *The Gate 2 read surface*; D50, D52, D53, and *Open review questions* |
| — | An operation record that cannot be read | docs/PROTOCOL.md → *An operation record that cannot be read*; D47, D54, and *Open review questions* (UR-Q1 to UR-Q9) |
| — | Its diagnostic's request, answer, words and interfaces (accepted; implemented in the core and the text interface, awaiting review) | docs/PROTOCOL.md → *The operation-record diagnostic*; D55 |
| — | An unreleased frontend candidate | D49; docs/FRONTEND.md |
| — | The interface | docs/UX.md; D51 |
