#!/usr/bin/env bash
# The core's protocol entry (docs/PROTOCOL.md → §3–§5), driven as the frontend
# drives it: a private session folder, a spool holding only its header, the
# request on fd 3, a sealed environment. Covers proto-golden-hello, proto-env,
# proto-version, proto-exit, proto-op-records, proto-handoff, the foundation's
# test actions, and the supervision (sup-*) and diagnostics (diag-*) cases
# that the core decides. frontend/tests/ drives the same core from Rust, on the
# real process topology.
# shellcheck disable=SC2010,SC2015,SC2016,SC2030,SC2031 # ls|grep over the core's own file names; ok/fail always return 0; literal $ in patterns; subshell locals on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-core"

T=$(t_tmp)
t_decoy "sleep 30 (a program of the developer's)"
t_decoy "sleep 20 (a program of the developer's)"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"

c_session
c_fixture

# --- proto-golden-hello: the golden request, and an answer shaped as the golden one --
printf 'omb-req 1\nreq\top=hello\tproto=1\tfrontend=0.1.0\tsession=0123456789abcdef\n' >"$T/golden"
C_N=$((C_N + 1)) C_EV=$SESS/req-$C_N.events
printf 'omb-res 1\n' >"$C_EV"
c_run_raw hello "$T/golden"
assert_rc "$C_RC" 0 "hello: exit 0 with a result"
assert_eq "$(c_admits hello)" ok "hello: the spool is an admissible response"
assert_eq "$(printf '%s\n' "$C_OUT" | cut -f1 | tr '\n' ' ')" "omb-res 1 hello result " "hello: exactly hello, then result"
hello=$(printf '%s\n' "$C_OUT" | sed -n 2p)
keys=$(printf '%s\n' "$hello" | tr '\t' '\n' | sed -n 's/=.*//p' | tr '\n' ' ')
assert_eq "$keys" "core commit source proto platform arch user ceiling dry_run fixture " "hello: the golden hello's keys, in order"
assert_contains "$hello" "core=$(sed -n 's/^OMB_VERSION="\(.*\)"$/\1/p' "$REPO/lib/common.sh")	" "hello: core is this core's version"
assert_contains "$hello" "commit=$(cat "$C_FIX/cmd/git_head")	" "hello: commit as the machine reads it (the fixture's)"
assert_contains "$hello" "	proto=1	platform=macos	arch=arm64	user=user	ceiling=act	dry_run=0	fixture=1" "hello: session values as the launcher set them"
assert_eq "$(sed -n 3p "$C_EV")" "result	status=done	code=ok	text=	next=" "hello: the golden result, byte for byte"
assert_eq "$(ls "$SESS" | grep -c '\.core$')" 0 "hello: the core removed its identity file at exit"
# The executed source digest is the listing of docs/QUALIFICATION.md.
want=$(
  cd "$REPO" && {
    printf 'omarchy-bootstrap\n'
    find lib data -type f
    [ -f release/frontend.lock ] && printf 'release/frontend.lock\n'
  } | LC_ALL=C sort | while read -r p; do printf '%s\t%s\n' "$p" "$(shasum -a 256 "$p" 2>/dev/null | cut -c1-64 || sha256sum "$p" | cut -c1-64)"; done
)
want=$( (printf 'omb-source 1\n%s\n' "$want") | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-64)
assert_contains "$hello" "source=$want	" "hello: source is the SHA-256 of the omb-source listing"

# --- proto-exit and proto-version --------------------------------------------------------
# An unreleased tool: a copy with no release/ folder, whatever lock this
# checkout itself holds. The released tool's cases use LT, below.
UT=$T/unreleased-tool
mkdir -p "$UT"
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$UT/"
if [ -e "$UT/release/frontend.lock" ] || [ -L "$UT/release/frontend.lock" ]; then fail "the unreleased tool holds a release lock"; else ok; fi
C_HOME=$UT C_FE=0.2.0 C_ENV="OMB_FRONTEND_DEV=" c_run hello
assert_rc "$C_RC" 3 "a frontend version the lock does not name: exit 3"
assert_eq "$(c_result)" "refused frontend" "and refused frontend"
assert_eq "$(c_admits hello)" ok "the refusal is itself an admissible response"
C_HOME=$UT C_ENV="OMB_FRONTEND_DEV=" c_run hello
assert_eq "$(c_result) $C_RC" "refused frontend 3" "with no release lock, only the fixture-mode development override is accepted"
assert_contains "$C_OUT" "text=No%20frontend%20release%20is%20pinned" "refused because no release is pinned, not for another version"
C_HOME=$UT c_run hello
assert_eq "$(c_result) $C_RC" "done ok 0" "the fixture-mode development override is accepted by the unreleased tool"
printf 'omb-req 1\nreq\top=hello\tproto=2\tfrontend=0.1.0\tsession=%s\n' "$S" >"$T/p2"
C_N=$((C_N + 1)) C_EV=$SESS/req-$C_N.events
printf 'omb-res 1\n' >"$C_EV"
c_run_raw hello "$T/p2"
assert_rc "$C_RC" 3 "another protocol version: exit 3"
assert_eq "$(c_result)" "refused protocol" "and refused protocol"
printf 'omb-req 1\nreq\top=hello\tproto=1\tfrontend=0.1.0\tsession=%s\t\n' "$S" >"$T/bad"
C_N=$((C_N + 1)) C_EV=$SESS/req-$C_N.events
printf 'omb-res 1\n' >"$C_EV"
c_run_raw hello "$T/bad"
assert_rc "$C_RC" 2 "an inadmissible request: exit 2"
assert_eq "$(c_result)" "error tab" "the admission reason is the result's code"
assert_eq "$(c_admits hello)" ok "an error answer is an admissible response"
c_run snapshot "scope	name=journey"
assert_eq "$C_RC" 0 "a request answered: exit 0"
# The started operation and the request's must be the same.
printf 'omb-req 1\nreq\top=snapshot\tproto=1\tfrontend=0.1.0\tsession=%s\nscope\tname=journey\n' "$S" >"$T/snap"
C_N=$((C_N + 1)) C_EV=$SESS/req-$C_N.events
printf 'omb-res 1\n' >"$C_EV"
c_run_raw hello "$T/snap"
assert_eq "$(c_result)" "error schema" "a request for another operation than the core was started for is refused"

# --- proto-env ------------------------------------------------------------------------------
for v in OMB_HOME OMB_SESSION_INTENT OMB_SESSION_SCOPES OMB_DRY_RUN; do
  C_UNSET=$v c_run hello
  assert_eq "$(c_result) $C_RC" "error environment 2" "proto-env: $v missing"
  assert_eq "$(c_admits hello)" ok "proto-env: the $v refusal is an admissible response"
done
for v in OMB_SESSION_INTENT=acts OMB_SESSION_SCOPES=journey,nowhere OMB_SESSION_SCOPES=journey,journey \
  OMB_SESSION_SCOPES=,journey OMB_DRY_RUN=2 OMB_HOME=relative/path "OMB_HOME=$T"; do
  C_ENV=$v c_run hello
  assert_eq "$(c_result) $C_RC" "error environment 2" "proto-env: $v"
done
hello=$(printf '%s\n' "$C_OUT" | sed -n 2p)
C_ENV="OMB_SESSION_INTENT=acts OMB_DRY_RUN=x" c_run hello
assert_contains "$C_OUT" "ceiling=read	dry_run=1" "a malformed session is described by its safest reading while it is refused"
# The session folder and the spool: without them no answer can be written.
C_UNSET=OMB_SESSION_DIR c_run hello
assert_eq "$C_RC:$(c_result)" "2:" "proto-env: OMB_SESSION_DIR missing: no answer, exit 2"
assert_contains "$C_ERR" "no answer can be written" "and it says so on stderr"
outside=$T/req-1.events
printf 'omb-res 1\n' >"$outside"
C_EVENTS=$outside c_run hello
assert_eq "$C_RC" 2 "proto-env: OMB_EVENTS outside the session folder: exit 2"
assert_eq "$(cat "$outside")" "omb-res 1" "and nothing is written there"
C_EVENTS=$SESS/req-x.events c_run hello
assert_eq "$C_RC" 2 "proto-env: OMB_EVENTS that names no request"
chmod 755 "$SESS"
c_run hello
assert_eq "$C_RC:$(c_result)" "2:" "proto-env: a session folder others can read is refused"
chmod 700 "$SESS"
C_N=$((C_N + 1))
printf 'omb-res 1\nhello\tcore=x\n' >"$SESS/req-$C_N.events"
C_EVENTS=$SESS/req-$C_N.events c_run_raw hello "$T/golden"
assert_eq "$C_RC" 2 "a spool already holding records is never appended to"
C_EVENTS=""

# --- proto-op-records and proto-invalid-schemas, through the core --------------------
c_run validate "page	scope=profile	kind=inventory	generation=$(printf '%064d' 0)	offset=0	limit=2" "select	action=x"
assert_eq "$(c_result)" "error schema" "proto-op-records: a page in validate"
c_run snapshot "scope	name=journey" "arg	name=v	value=1"
assert_eq "$(c_result)" "error schema" "proto-op-records: an arg in snapshot"
c_run execute "select	action=x" "exec	action=test.read	basis=$(printf '%064d' 0)	confirm="
assert_eq "$(c_result)" "error schema" "proto-op-records: a select in execute"
c_run validate
assert_eq "$(c_result)" "error schema" "proto-invalid-schemas: validate without select"
c_run execute "exec	action=test.read	confirm="
assert_eq "$(c_result)" "error schema" "proto-invalid-schemas: exec without basis"
c_run snapshot "scope	name=journey	extra=1"
assert_eq "$(c_result)" "error schema" "proto-invalid-schemas: a field the schema does not list"
c_run snapshot "scope	name=journey	name=disk"
assert_eq "$(c_result)" "error schema" "proto-invalid-schemas: a duplicate field"
c_run hello "# a note"
assert_eq "$(c_result)" "error key" "proto-invalid-schemas: a comment line"

# --- sup-fd3-closed: nothing the core starts can hold the request pipe -----------------
c_run hello
assert_eq "$(c_result)" "done ok" "the request is read from fd 3"
# The entrypoint copies fd 3 and closes it before any library loads.
code=$(sed -n '/^if \[ "${1:-}" = core \]; then$/,/^fi$/p' "$REPO/omarchy-bootstrap")
assert_contains "$code" 'head -c 65537 2>/dev/null <&3 >"$OMB_CORE_COPY" 3<&-' "fd 3 is copied with a bound (64 KiB + 1)"
assert_contains "$code" 'exec 3<&-' "and closed"
before=$(grep -n '^if \[ "${1:-}" = core \]; then$' "$REPO/omarchy-bootstrap" | cut -d: -f1)
first_lib=$(grep -n '^\. "\$OMB_HOME/lib/' "$REPO/omarchy-bootstrap" | head -1 | cut -d: -f1)
[ "$before" -lt "$first_lib" ] && ok || fail "fd 3 is closed before the first library is sourced"

OPS=$T/state/ops/journey.omb
EFFECT=$T/state/test/effect-mutate

# --- The foundation's snapshot ------------------------------------------------------------
c_run snapshot "scope	name=journey"
assert_eq "$(c_result)" "done ok" "snapshot of the journey scope in fixture mode"
assert_eq "$(c_admits snapshot)" ok "the snapshot is an admissible response"
assert_eq "$(printf '%s\n' "$C_OUT" | awk -F'\t' '$1 == "action" { sub(/^id=/, "", $2); printf "%s ", $2 }')" \
  "test.read test.mutate test.handoff " "it lists the three test actions, and nothing of the baseline"
assert_contains "$C_OUT" "action	id=test.mutate	scope=journey	label=Change%20the%20fixture%20%28test%29	intent=act	gate=test	terminal=managed	cancel=0	basis=" "test.mutate: act, gated by the word test, managed"
assert_contains "$C_OUT" "action	id=test.handoff	scope=journey	label=Hand%20over%20the%20terminal%20%28test%29	intent=act	gate=test	terminal=handoff" "test.handoff: a handoff"
# With a real lock (no development override): the lock is admitted too, and
# the request's own values must survive it.
LT=$T/locked-tool
mkdir -p "$LT/release" "$LT/tests"
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$LT/"
cp -R "$REPO/tests/children" "$LT/tests/"
(
  t_load >/dev/null 2>&1
  # shellcheck source=lib/records.sh
  . "$REPO/lib/records.sh"
  f=$LT/release/frontend.lock
  {
    printf 'omb-frontend-lock 1\n'
    rec_line frontend version 0.1.0 proto 1 source_commit "$(printf '%040d' 0)" inputs_digest "$(printf '%064d' 0)" rust 1.88.0
    rec_line artifact target aarch64-apple-darwin url https://example.invalid/omb-tui size 1 sha256 "$(printf '%064d' 0)" minos 13.5 glibc_max "" interp "" align_min ""
  } >"$f"
  rec_seal_write "$f"
  omb_cleanup
)
C_HOME=$LT C_ENV="OMB_FRONTEND_DEV=" c_run snapshot "scope	name=journey"
assert_eq "$(c_result)" "done ok" "with a real lock admitted, the snapshot still reads its own request"
assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^action	')" 3 "and lists the test actions"
C_HOME=$LT C_ENV="OMB_FRONTEND_DEV=" C_FE=0.2.0 c_run hello
assert_eq "$(c_result) $C_RC" "refused frontend 3" "proto-version: a frontend version other than the real lock's"
C_ENV=OMB_SESSION_INTENT=plan c_run snapshot "scope	name=journey"
assert_eq "$(printf '%s\n' "$C_OUT" | awk -F'\t' '$1 == "action" { sub(/^id=/, "", $2); printf "%s ", $2 }')" "test.read " \
  "a plan session is shown only what it may run"
c_run snapshot "scope	name=shared"
assert_eq "$(c_result)" "refused scope" "a scope outside the session is refused"
assert_eq "$(c_admits snapshot)" ok "a refused snapshot is an admissible response (its one generation names the empty data set)"
C_ENV=OMB_SESSION_SCOPES=journey,shared c_run snapshot "scope	name=shared"
assert_eq "$(c_result)" "refused unavailable" "no baseline scope is served in this gate"
c_run detail "page	scope=journey	kind=inventory	generation=$(printf '%064d' 0)	offset=0	limit=2"
assert_eq "$(c_result)" "refused unavailable" "detail pages nothing in this gate"
assert_eq "$(c_admits detail)" ok "a refused detail is an admissible response (its one generation names the empty data set)"
c_run validate "select	action=test.read"
assert_eq "$(c_result)" "refused unavailable" "validate has nothing to validate in this gate"

# --- execute: the refusals, in the order of docs/PROTOCOL.md → Executing ---------------
c_exec test.nothing ""
assert_eq "$(c_result)" "refused unavailable" "an action the core does not have"
c_exec test.read "" "arg	name=x	value=1"
assert_eq "$(c_result)" "refused invalid" "proto-arg: an argument the action does not declare"
C_ENV=OMB_SESSION_INTENT=plan c_exec test.mutate test
assert_eq "$(c_result)" "refused ceiling" "proto-ceiling: an act action in a plan session"
C_ENV=OMB_SESSION_INTENT=read c_exec test.mutate test
assert_eq "$(c_result)" "refused ceiling" "proto-ceiling: an act action in a read session"
C_ENV=OMB_SESSION_SCOPES=shared c_exec test.mutate test
assert_eq "$(c_result)" "refused scope" "proto-scope: an action outside the session's scopes"
for w in "" tes tset testing; do
  c_exec test.mutate "$w"
  assert_eq "$(c_result)" "refused word" "proto-word: [$w] is not the word"
done
# A differently-cased word, or one with a space, is not even an id (confirm's
# type): refused at admission, before the word is compared.
for w in TEST Test test%20; do
  c_exec test.mutate "$w"
  assert_eq "$(c_result)" "error type" "proto-word: [$w] is refused at admission"
done
c_exec test.read test
assert_eq "$(c_result)" "refused word" "proto-word: a word for an action with no gate"
[ ! -e "$OPS" ] && [ ! -e "$EFFECT" ] && ok || fail "a refused act leaves no operation record and no effect"
c_run execute "exec	action=test.mutate	basis=$(printf '%064d' 1)	confirm=test"
assert_eq "$(c_result)" "refused changed" "a basis that is not the fresh one"
b=$(c_basis test.mutate)
mkdir -p "$T/state/test" && printf 'appeared' >"$EFFECT"
c_run execute "exec	action=test.mutate	basis=$b	confirm=test"
assert_eq "$(c_result)" "refused changed" "the machine changed after the review: refused changed"
assert_eq "$(cat "$EFFECT")" "appeared" "and what appeared is untouched"
rm -f "$EFFECT"
C_ENV=OMB_DRY_RUN=1 c_exec test.mutate test
assert_eq "$(c_result)" "done dry-run" "a dry run runs nothing"
[ ! -e "$EFFECT" ] && [ ! -e "$OPS" ] && ok || fail "a dry run leaves no effect and no operation record"
c_exec test.handoff test
assert_eq "$(c_result)" "refused unavailable" "proto-handoff: a handoff without a terminal on 0 and 1"
[ ! -e "$OPS" ] && ok || fail "the refused handoff's operation record is removed"

# --- test.read: a managed read, its output kept within bounds ----------------------------
c_exec test.read ""
assert_eq "$(c_result)" "done ok" "test.read runs its child"
assert_eq "$(c_admits execute)" ok "an execute answer is an admissible response"
assert_contains "$C_OUT" "message	level=info	text=fixture%20read:%20ok" "its functional output is shown"
diag=$SESS/req-$C_N.diag
assert_contains "$(head -1 "$diag")" "child	test.read	exit=000	kept=" "its diagnostics are kept as one block with its header"
assert_contains "$(cat "$diag")" "fake read child: a line of diagnostics" "the child's stderr is in the block"
assert_eq "$(wc -c <"$SESS/req-$C_N.diag-summary" | tr -d ' ')" 128 "the request's summary is 128 bytes"
[ ! -e "$OPS" ] && ok || fail "sup-read-orphan-no-barrier: a read request holds no operation record"
[ ! -e "$SESS/req-$C_N.capture" ] && ok || fail "the temporary capture is removed once merged"

# --- test.mutate: supervised completion ----------------------------------------------------
# sup-completion-controllers-live: processes started before the core (this
# test's shell, and a long-lived one standing in for the frontend) are in the
# group snapshot, stay alive, and do not hold completion back.
sleep 60 &
standin=$!
c_exec test.mutate test
assert_eq "$(c_result)" "done ok" "sup-completion-controllers-live: completed with the controllers alive"
assert_eq "$(wc -c <"$EFFECT" 2>/dev/null | tr -d ' ')" 16 "the child's effect is on the machine"
[ ! -e "$OPS" ] && ok || fail "the operation record is removed after the result is recorded"
assert_contains "$(cat "$T/state/state.env")" "test_last_result=test.mutate done" "the result is recorded where the scope keeps results"
kill -0 "$standin" 2>/dev/null && ok || fail "the controller stand-in was left alone"
kill "$standin" 2>/dev/null
wait "$standin" 2>/dev/null
assert_contains "$(cat "$SESS"/req-*.worker-* 2>/dev/null | grep -c 'role=worker')" "" "worker identities are recorded"
ls "$SESS"/req-$C_N.worker-1 >/dev/null 2>&1 && ok || fail "the mutating child's identity is req-N.worker-1"
rm -f "$EFFECT"

# A child that leaves nothing, whose effect is not there: failed, not
# unknown — and the operation record stays, as failed, a barrier until a new
# boot and reconciliation (docs/PROTOCOL.md → Operations and exclusion).
bs0=$(cat "$C_FIX/cmd/bootsession")
c_conf mutate effect=none
c_exec test.mutate test
assert_eq "$(c_result)" "failed postcondition" "sup-completion-failed: no effect on the machine: failed, judged by the postcondition"
assert_contains "$C_OUT" "next=Run%20by%20hand" "the command is shown for running by hand"
assert_contains "$(cat "$OPS" 2>/dev/null)" "	state=failed	finding=absent	" "sup-completion-failed: the operation record stays, failed, with what the machine showed"
assert_contains "$(cat "$T/state/state.env")" "test_last_result=test.mutate failed" "and the result is recorded where the scope keeps results"
c_conf mutate
c_exec test.mutate test
assert_eq "$(c_result)" "refused unresolved" "sup-failed-blocks: the next act in the scope is refused"
assert_contains "$C_OUT" "test.mutate%20ended,%20but%20the%20machine%20does%20not%20show%20its%20expected%20effect:%20it%20shows%20no%20effect" "saying the action ended without its effect"
assert_not_contains "$C_OUT" "may%20still%20be%20running" "never that it may still be running"
[ ! -e "$EFFECT" ] && ok || fail "and nothing ran"
c_exec test.read ""
assert_eq "$(c_result)" "done ok" "sup-failed-blocks: read requests still work behind it"
c_run snapshot "scope	name=journey"
assert_contains "$C_OUT" "blocker	id=unresolved	text=test.mutate%20ended" "the snapshot shows the barrier"
assert_eq "$(printf '%s\n' "$C_OUT" | awk -F'\t' '$1 == "action" { sub(/^id=/, "", $2); printf "%s ", $2 }')" "test.read " \
  "and lists no act action in its scope"
# In the same boot, the machine showing the expected effect after all: still blocked.
printf '%s' "$(sed -n 's/.*	basis=\([0-9a-f]\{16\}\).*/\1/p' "$OPS")" >"$EFFECT"
c_exec test.mutate test
assert_eq "$(c_result)" "refused unresolved" "sup-failed-same-boot: a matching postcondition does not clear it within the boot"
rm -f "$EFFECT"
# A new boot: reconciled from what the machine then holds — here, no effect.
printf '5E1D0B00-7A3C-4F21-9D6E-00000000F001\n' >"$C_FIX/cmd/bootsession"
c_exec test.mutate test
assert_eq "$(c_result)" "done ok" "sup-failed-reconcile: after a new boot, no effect: reconciled, and the action proceeds"
assert_contains "$C_OUT" "reconciled:%20no-effect" "the finding is no effect"
[ ! -e "$OPS" ] && ok || fail "and its own completion removed the record"
rm -f "$EFFECT"
# Something else on the machine: failed, unexpected; after a new boot too.
c_conf mutate effect=unexpected
c_exec test.mutate test
assert_eq "$(c_result)" "failed postcondition" "sup-completion-unexpected: something else on the machine: failed"
assert_contains "$(cat "$OPS")" "	state=failed	finding=unexpected	" "and the record says what it showed"
c_conf mutate
c_exec test.mutate test
assert_eq "$(c_result)" "refused unresolved" "the next act is refused"
assert_contains "$C_OUT" "it%20shows%20something%20else" "saying the machine shows something else"
printf '5E1D0B00-7A3C-4F21-9D6E-00000000F002\n' >"$C_FIX/cmd/bootsession"
c_exec test.mutate test
assert_eq "$(c_result)" "refused unsupervised" "sup-failed-reconcile: after a new boot, something unexpected: the scope stays blocked"
assert_contains "$C_OUT" "It%20needs%20you" "and needs the person"
[ -e "$OPS" ] && ok || fail "the reboot is not counted as success: the record stays"
rm -f "$OPS" "$EFFECT"
printf '%s\n' "$bs0" >"$C_FIX/cmd/bootsession"
# failed_run WHAT — a failed test.mutate while the child runs, with WHAT done
# to the state folder meanwhile (and undone after); sets r and ev.
failed_run() {
  c_conf mutate effect=none sleep=2
  c_prepare execute "exec	action=test.mutate	basis=$(c_basis test.mutate)	confirm=test"
  n=$C_N
  (c_run_raw execute "$T/request-$n") &
  bg=$!
  c_wait_file "$SESS/req-$n.worker-1"
  case "$1" in
    result) mv "$T/state/state.env" "$T/state.env.kept" && ln -s /dev/null "$T/state/state.env" ;;
    record) chmod 500 "$T/state/ops" ;;
  esac
  wait "$bg"
  case "$1" in
    result) rm -f "$T/state/state.env" && mv "$T/state.env.kept" "$T/state/state.env" ;;
    record) chmod 700 "$T/state/ops" ;;
  esac
  ev=$(cat "$SESS/req-$n.events")
  r=$(printf '%s\n' "$ev" | awk -F'\t' '$1 == "result" { print $2 " " $3 }')
  c_conf mutate
}
# The result cannot be recorded: the failed record is already in place.
failed_run result
assert_eq "$r" "status=failed code=postcondition" "sup-failed-result-unrecorded: failed"
assert_contains "$ev" "the%20result%20could%20not%20be%20recorded" "and says the result could not be recorded"
assert_contains "$(cat "$OPS")" "	state=failed	" "the failed record stays: the barrier holds"
rm -f "$OPS"
# The record cannot be rewritten: the running one stays, unsupervised once
# its core has ended — never no record.
failed_run record
assert_eq "$r" "status=failed code=postcondition" "sup-failed-record-unwritten: failed"
assert_contains "$ev" "could%20not%20be%20updated" "and says the record could not be updated"
assert_contains "$(cat "$OPS")" "	state=running	" "the running record stays"
c_exec test.mutate test
assert_eq "$(c_result)" "refused unsupervised" "sup-failed-record-unwritten: the next act is refused, as unsupervised"
rm -f "$OPS" "$EFFECT"

# diag-mutator-no-backpressure: 1 GiB on stdout and stderr goes nowhere.
c_conf mutate out_bytes=1073741824
t0=$SECONDS
c_exec test.mutate test
assert_eq "$(c_result)" "done ok" "a mutating child writing 1 GiB to stdout and stderr completes"
[ $((SECONDS - t0)) -lt 60 ] && ok || fail "it was never blocked on its output"
assert_eq "$(ls "$SESS" | grep -c "^req-$C_N\.diag")" 0 "nothing of a mutating child's output is kept"
rm -f "$EFFECT"

# sup-fd-child and sup-fd-grandchild: only 0, 1 and 2 reach a child and its
# descendants — never fd 3 or the spool. The harness's own inheritable
# descriptors are the baseline (a caller may hold some; the core adds none).
base=$("$REPO/tests/children/probe-fds" 3<&-)
c_conf mutate "fds=$T/fds-mutate"
c_exec test.mutate test
assert_eq "$(cat "$T/fds-mutate")" "$base" "sup-fd-child: the mutating child holds only what its caller held ($base)"
rm -f "$EFFECT"
c_conf read "fds=$T/fds-read" "grandchild=30" "grandchild_fds=$T/fds-grand" "pids=$T/owned"
t0=$SECONDS
c_exec test.read ""
assert_eq "$(c_result)" "done ok" "sup-fd-grandchild: the read completes"
[ $((SECONDS - t0)) -lt 15 ] && ok || fail "sup-fd-grandchild: the core ended without waiting for the grandchild"
c_wait_file "$T/fds-grand"
assert_eq "$(cat "$T/fds-read")" "$base" "sup-fd-child: the read child holds only what its caller held"
assert_eq "$(cat "$T/fds-grand")" "$base" "sup-fd-grandchild: the grandchild holds only what its caller held"
assert_contains "$C_OUT" "diagnostics%20not%20available" "the grandchild holding stderr leaves the diagnostics not available, not the core waiting"
t_signal_owned TERM "$T/owned" && rm -f "$T/owned"
# The grace the drain gets is wall time: where every fork is slow (each
# `sleep` here costs 50 ms more), the core still gives up on the held stderr
# after about 5 seconds, not after hundreds of slow tries.
mkdir -p "$T/slowbin"
printf '#!/bin/sh\n/bin/sleep 0.05\nexec /bin/sleep "$@"\n' >"$T/slowbin/sleep"
chmod +x "$T/slowbin/sleep"
c_conf read "grandchild=30" "pids=$T/owned"
t0=$SECONDS
C_PATH="$T/slowbin:/usr/bin:/bin:/usr/sbin:/sbin" c_exec test.read ""
assert_eq "$(c_result)" "done ok" "sup-fd-grandchild on a slow host: the read completes"
[ $((SECONDS - t0)) -lt 12 ] && ok || fail "sup-fd-grandchild on a slow host: the drain's grace is wall time ($((SECONDS - t0)) s)"
t_signal_owned TERM "$T/owned" && rm -f "$T/owned"
case " $base " in *" 3 "*) fail "the harness itself held fd 3" ;; *) ok ;; esac
rm -f "$T/test-children-none"
rm -f "$C_FIX/test-children/read"

# sup-eintr-exemption: the storm below is skipped only for Bash 5.2's
# upstream trap loss, and only once the state it left is one such a death
# leaves (c_storm_exempt). The real storm strikes only now and then, and only
# under 5.2, so each state is made here and judged the same on every shell.
X_BASIS=$(printf '%064d' 7)
sleep 30 &
xlive=$!
xlive_start=$(t_started "$xlive")
sleep 0.01 &
xdead=$!
wait "$xdead"
xold="Mon Jan  1 00:00:00 2001"
# The hello this core writes in this environment, from its whole answer to a
# hello request: what a death after the hello leaves behind the header.
c_run hello
cp "$C_EV" "$T/hello-ref"
assert_eq "$(c_admits hello)" ok "sup-eintr-exemption: the hello the made states hold is this core's, whole and admitted"
# x_rec FILE HEADER FAMILY KEY VALUE... — a sealed record.
x_rec() {
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    f=$1 h=$2
    shift 2
    { printf '%s\n' "$h" && rec_line "$@"; } >"$f"
    rec_seal_write "$f"
    omb_cleanup
  )
}
# x_run NAME SITE — X=$T/x-NAME: request 1 of a run that ended with status 1,
# its spool its header and this core's hello (the first two lines of its
# answer to a hello request, byte for byte), its stderr the trap loss at
# SITE (common:155, state:269) or else the text SITE, and a marker from
# before it.
x_run() {
  local f l
  X=$T/x-$1
  mkdir -p "$X/sess" "$X/state/ops" "$X/state/test"
  : >"$X/marker"
  touch -t 200001010000 "$X/marker"
  head -n 2 "$T/hello-ref" >"$X/sess/req-1.events"
  printf 'omb-req 1\nexec\taction=test.mutate\tbasis=%s\tconfirm=test\n' "$X_BASIS" >"$X/request-1"
  case $2 in
    common:155 | state:269)
      f=${2%:*} l=${2#*:}
      printf '%s\n' "$REPO/lib/$f.sh: trap: line 2: unexpected EOF while looking for matching \`)'" \
        "$REPO/lib/$f.sh: $REPO/omarchy-bootstrap: line $l: unexpected EOF while looking for matching \`)'" >"$X/stderr"
      ;;
    *) printf '%s' "$2" >"$X/stderr" ;;
  esac
}
# x_op STATE PID START [FINDING] [SESSION] — the scope's operation record.
x_op() {
  x_rec "$X/state/ops/journey.omb" 'omb-op 1' op action test.mutate scope journey basis "$X_BASIS" \
    session "${5:-$X/sess}" state "$1" finding "${4:-}" pid "$2" start "$3" boot x at 2026-09-27T00:00:00Z
}
# x_worker PID START — request 1's worker identity.
x_worker() { x_rec "$X/sess/req-1.worker-1" 'omb-proc 1' proc role worker pid "$1" start "$2" boot x; }
# x_judge [VERSION] [STATUS] — "exempt", or "judged: why".
x_judge() {
  if c_storm_exempt "${1:-5.2}" "${2:-1}" "$X" "$X/sess" 1 "$X/marker" "$T/hello-ref"; then echo exempt; else echo "judged: $C_WHY"; fi
}
# The four states the two deaths leave: exempt, and only what the death left
# is removed — never anything outside the run's own folder.
mkdir -p "$T/x-other/state/lock" "$T/x-other/state/ops"
printf 'x\n' >"$T/x-other/state/ops/journey.omb"
x_run lock state:269
mkdir "$X/state/lock"
assert_eq "$(x_judge)" exempt "sup-eintr-exemption: a death at the lock's owner line, its lock an empty folder made during the run"
[ ! -e "$X/state/lock" ] && ok || fail "sup-eintr-exemption: that ownerless lock is removed"
[ -f "$X/marker" ] && [ -f "$X/stderr" ] && [ -d "$X/state/ops" ] && ok || fail "sup-eintr-exemption: and nothing else of the run"
[ -d "$T/x-other/state/lock" ] && [ -f "$T/x-other/state/ops/journey.omb" ] && ok || fail "sup-eintr-exemption: a lock and a record outside the run's folder are untouched"
x_run running common:155
x_op running "$xdead" "$xold"
assert_eq "$(x_judge)" exempt "sup-eintr-exemption: a death in log_event just after the running record, its core ended"
[ ! -e "$X/state/ops/journey.omb" ] && ok || fail "sup-eintr-exemption: that record is removed"
x_run done-kept common:155
x_op running "$xdead" "$xold"
x_worker "$xdead" "$xold"
printf '%s' "${X_BASIS:0:16}" >"$X/state/test/effect-mutate"
assert_eq "$(x_judge)" exempt "sup-eintr-exemption: a death once the child ended, the record not yet removed"
[ ! -e "$X/state/ops/journey.omb" ] && [ -f "$X/state/test/effect-mutate" ] && [ -f "$X/sess/req-1.worker-1" ] && ok ||
  fail "sup-eintr-exemption: the record is removed, and only it"
x_run ended common:155
x_worker "$xdead" "$xold"
printf '%s' "${X_BASIS:0:16}" >"$X/state/test/effect-mutate"
assert_eq "$(x_judge)" exempt "sup-eintr-exemption: a death once the record was removed"
# A lock with an owner — alive, dead or unreadable — or from before the run:
# judged, and kept.
for owner in "$xlive 2026-09-27T00:00:00Z $xlive_start" "$xdead 2026-09-27T00:00:00Z $xold" "x y" "-"; do
  x_run owner state:269
  mkdir -p "$X/state/lock"
  [ "$owner" = - ] || printf '%s\n' "$owner" >"$X/state/lock/owner"
  [ "$owner" = - ] && touch -t 199901010000 "$X/state/lock"
  assert_contains "$(x_judge)" "judged: " "sup-eintr-exemption: a lock whose owner is [$owner] is not left by such a death"
  { [ "$owner" = - ] || [ "$(cat "$X/state/lock/owner")" = "$owner" ]; } && [ -d "$X/state/lock" ] && ok ||
    fail "sup-eintr-exemption: and it is kept, its owner as it was ([$owner])"
  rm -rf "$X"
done
# An operation record other than this request's own running one, its core
# ended: judged, and kept.
for rec in "unsupervised $xdead" "failed $xdead" "running $xlive" "running $xdead other-session" "torn"; do
  x_run record common:155
  read -r rstate rpid rsess <<<"$rec"
  case $rstate in
    torn) printf 'omb-op 1\ntorn' >"$X/state/ops/journey.omb" ;;
    failed) x_op failed "$rpid" "$xold" absent ;;
    *)
      s=$xold
      [ "$rpid" = "$xlive" ] && s=$xlive_start
      x_op "$rstate" "$rpid" "$s" "" "${rsess:+$X/$rsess}"
      ;;
  esac
  cp "$X/state/ops/journey.omb" "$X/record-before"
  assert_contains "$(x_judge)" "judged: " "sup-eintr-exemption: an operation record [$rec] is not left by such a death"
  cmp -s "$X/state/ops/journey.omb" "$X/record-before" && ok || fail "sup-eintr-exemption: and it is kept ([$rec])"
  rm -rf "$X"
done
# A running record at the lock's line, which comes before any record.
x_run lock-record state:269
mkdir "$X/state/lock"
x_op running "$xdead" "$xold"
assert_contains "$(x_judge)" "judged: " "sup-eintr-exemption: a record where the death came before any"
[ -d "$X/state/lock" ] && [ -f "$X/state/ops/journey.omb" ] && ok || fail "sup-eintr-exemption: and nothing is removed"
# A worker still alive, or its identity unreadable, or a core identity left.
x_run worker common:155
x_op running "$xdead" "$xold"
x_worker "$xlive" "$xlive_start"
printf '%s' "${X_BASIS:0:16}" >"$X/state/test/effect-mutate"
assert_contains "$(x_judge)" "judged: " "sup-eintr-exemption: a live worker (a mutation that may still be running)"
[ -f "$X/state/ops/journey.omb" ] && ok || fail "sup-eintr-exemption: and its record is kept"
printf 'omb-proc 1\ntorn' >"$X/sess/req-1.worker-1"
assert_contains "$(x_judge)" "judged: " "sup-eintr-exemption: a worker identity that cannot be read"
x_worker "$xdead" "$xold"
ln -s "$X/gone" "$X/sess/req-1.core"
assert_contains "$(x_judge)" "judged: " "sup-eintr-exemption: a core identity left"
# The effect other than the expected one; a result recorded; another shell,
# status or message.
x_run effect common:155
x_worker "$xdead" "$xold"
printf 'something else' >"$X/state/test/effect-mutate"
assert_contains "$(x_judge)" "judged: " "sup-eintr-exemption: an effect other than the expected one"
x_run result state:269
mkdir "$X/state/lock"
printf 'result\tstatus=done\tcode=ok\tmessage=\tnext=\n' >>"$X/sess/req-1.events"
assert_contains "$(x_judge)" "judged: " "sup-eintr-exemption: a result recorded (a success contradicting the death)"
[ -d "$X/state/lock" ] && ok || fail "sup-eintr-exemption: and the lock is kept"
x_run version state:269
mkdir "$X/state/lock"
assert_eq "$(x_judge 5.3)" "judged: the core ran under Bash 5.3, not 5.2" "sup-eintr-exemption: Bash 5.3 is never exempt"
assert_eq "$(x_judge 3.2)" "judged: the core ran under Bash 3.2, not 5.2" "sup-eintr-exemption: nor 3.2"
assert_eq "$(x_judge 5.2 2)" "judged: the core exited 2, not 1" "sup-eintr-exemption: nor another exit status"
[ -d "$X/state/lock" ] && ok || fail "sup-eintr-exemption: and the lock is kept"
for msg in "" "$REPO/lib/core.sh: trap: line 2: unexpected EOF while looking for matching \`)'" \
  "$(sed -n 1p "$T/x-lock/stderr")" "$(sed 's#/lib/common\.sh:#/lib/xcommon.sh:#' "$T/x-ended/stderr")" \
  "$(sed 's/line 155:/line 138:/' "$T/x-ended/stderr")" "$(sed "s#$REPO#/elsewhere#g" "$T/x-ended/stderr")" \
  "$(cat "$T/x-ended/stderr"; printf '\nsomething more')"; do
  x_run message "$msg"
  mkdir "$X/state/lock"
  assert_eq "$(x_judge)" "judged: stderr is not the trap loss at lib/common.sh:155 or lib/state.sh:269" "sup-eintr-exemption: stderr [$(printf '%s' "$msg" | tr '\n' '|' | cut -c1-60)] is not the trap loss"
  [ -d "$X/state/lock" ] && ok || fail "sup-eintr-exemption: and the lock is kept"
  rm -rf "$X"
done
# sup-eintr-exemption-prefix: the spool, held to its bytes — the header,
# this core's hello, LF, and the end. Each case is written as bytes, judged
# by c_hello_prefix alone, then by c_storm_exempt over each state a death
# can leave (the empty lock; the running record), which a refusal leaves
# exactly as it was.
H=$(sed -n 2p "$T/hello-ref")
TAB=$(printf '\t')
# x_spool CASE — the case's bytes.
x_spool() {
  case $1 in
    good) printf 'omb-res 1\n%s\n' "$H" ;;
    wrong-header) printf 'omb-res 2\n%s\n' "$H" ;;
    request-header) printf 'omb-req 1\n%s\n' "$H" ;;
    header-no-lf) printf 'omb-res 1%s\n' "$H" ;;
    result-as-header) printf 'result\tstatus=failed\tcode=child\ttext=\tnext=\n%s\n' "$H" ;;
    incomplete-hello) printf 'omb-res 1\n%s\n' "${H%%"${TAB}commit="*}" ;;
    nul-escape) printf 'omb-res 1\n%s\n' "${H/"${TAB}user=user"/${TAB}user=us%00er}" ;;
    lowercase-escape) printf 'omb-res 1\n%s\n' "${H/"${TAB}core="/${TAB}core=a%2f}" ;;
    non-canonical-escape) printf 'omb-res 1\n%s\n' "${H/"${TAB}core="/${TAB}core=%41}" ;;
    raw-byte) printf 'omb-res 1\n%s\n' "${H/"${TAB}core="/${TAB}core=$(printf '\001')}" ;;
    leading-tab) printf 'omb-res 1\n\t%s\n' "$H" ;;
    doubled-tab) printf 'omb-res 1\n%s\n' "${H/"${TAB}core="/${TAB}${TAB}core=}" ;;
    duplicate-field) printf 'omb-res 1\n%s\tfixture=1\n' "$H" ;;
    unknown-field) printf 'omb-res 1\n%s\textra=1\n' "$H" ;;
    field-order) printf 'omb-res 1\n%s\n' "$H" | sed "s/${TAB}platform=\([^${TAB}]*\)${TAB}arch=\([^${TAB}]*\)/${TAB}arch=\2${TAB}platform=\1/" ;;
    typed-value) printf 'omb-res 1\n%s\n' "${H/"${TAB}proto=1"/${TAB}proto=x}" ;;
    other-hello) printf 'omb-res 1\n%s\n' "${H/"${TAB}ceiling=act"/${TAB}ceiling=read}" ;;
    no-final-lf) printf 'omb-res 1\n%s' "$H" ;;
    extra-result) printf 'omb-res 1\n%s\nresult\tstatus=done\tcode=ok\ttext=\tnext=\n' "$H" ;;
    extra-blank) printf 'omb-res 1\n%s\n\n' "$H" ;;
    trailing-byte) printf 'omb-res 1\n%s\nx' "$H" ;;
    partial-third) printf 'omb-res 1\n%s\nprogress\taction=test.mutate' "$H" ;;
    incomplete-third) printf 'omb-res 1\n%s\nprogress\taction=test.mutate\n' "$H" ;;
    valid-third) printf 'omb-res 1\n%s\nprogress\taction=test.mutate\tdone=1\ttotal=2\tunit=\tlabel=\n' "$H" ;;
    header-only) printf 'omb-res 1\n' ;;
    empty) : ;;
  esac
}
# x_snap — every path under X, and every file's bytes.
x_snap() { (cd "$X" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} \; | LC_ALL=C sort); }
x_spool good >"$T/prefix-good"
assert_eq "$(c_hello_prefix "$T/prefix-good" "$T/hello-ref")" ok "sup-eintr-exemption-prefix: the good prefix is the header and this core's hello, and nothing else"
cmp -s "$T/prefix-good" "$T/x-lock/sess/req-1.events" && ok || fail "sup-eintr-exemption-prefix: the made states above hold exactly it"
for c in "good|ok" \
  "wrong-header|header at line 1" "request-header|header at line 1" "header-no-lf|header at line 1" \
  "result-as-header|header at line 1" "incomplete-hello|schema at line 2" "nul-escape|nul-escape at line 2" \
  "lowercase-escape|value at line 2" "non-canonical-escape|non-canonical at line 2" "raw-byte|byte at line 0" \
  "leading-tab|tab at line 2" "doubled-tab|tab at line 2" "duplicate-field|schema at line 2" \
  "unknown-field|schema at line 2" "field-order|schema at line 2" "typed-value|type at line 2" \
  "other-hello|a hello other than the one this core writes here" "no-final-lf|eof at line 0" \
  "extra-result|a whole response, its result included" "extra-blank|blank at line 3" "trailing-byte|eof at line 0" \
  "partial-third|eof at line 0" "incomplete-third|schema at line 3" "valid-third|2 records, not one hello" \
  "header-only|0 records, not one hello" "empty|eof at line 0"; do
  case=${c%%|*} want=${c#*|}
  x_spool "$case" >"$T/prefix-$case"
  assert_contains "$(c_hello_prefix "$T/prefix-$case" "$T/hello-ref")" "$want" "sup-eintr-exemption-prefix: $case, judged alone"
  for state in lock record; do
    if [ "$state" = lock ]; then
      x_run "p-$case-lock" state:269
      mkdir "$X/state/lock"
    else
      x_run "p-$case-record" common:155
      x_op running "$xdead" "$xold"
    fi
    cp "$T/prefix-$case" "$X/sess/req-1.events"
    before=$(x_snap)
    r=$(x_judge)
    if [ "$case" = good ]; then
      assert_eq "$r" exempt "sup-eintr-exemption-prefix: the good prefix over the $state a death leaves is exempt"
    else
      assert_contains "$r" "judged: the spool is not exactly the header and this core's hello: " "sup-eintr-exemption-prefix: $case over the $state is judged"
      assert_contains "$r" "$want" "and for its bytes ($case)"
      assert_eq "$(x_snap)" "$before" "sup-eintr-exemption-prefix: and the $state's folder is exactly as it was ($case)"
    fi
    rm -rf "$X"
  done
done
t_signal TERM "$xlive" "$xlive_start"
wait "$xlive" 2>/dev/null

# sup-eintr in the core: a signal while the process table is read (a second
# Ctrl-C, a hangup) cuts a wait short, or ends the reading; the table is read
# again, never taken for one that cannot be read, which would be a barrier.
c_conf mutate linger=1
# The hello this core writes in this environment, for c_storm_exempt to hold
# the storm's spool to.
c_run hello
cp "$C_EV" "$T/storm-hello"
c_prepare execute "exec	action=test.mutate	basis=$(c_basis test.mutate)	confirm=test"
n=$C_N
# The signals come from the core's own parent, which made a process group of
# its own first: the core's group then holds the two of them, the sender there
# before any child. A PID is not reused before its parent collects it, so
# every signal reaches this core and nothing else. They start once the core
# has recorded itself, which it does once its handlers are in place.
cat >"$T/storm" <<'PERL'
#!/usr/bin/env perl
# storm READY SENT CMD... — run CMD as this process's child, in a new process
# group; from the moment READY exists until CMD ends, send it SIGHUP every
# 30 ms. The count sent goes to SENT; the exit status is CMD's.
use POSIX ":sys_wait_h";
my ($ready, $sent) = (shift, shift);
setpgrp(0, 0);
my $pid = fork() // exit 125;
if ($pid == 0) { exec @ARGV or exit 127 }
my ($n, $go, $done, $st) = (0, 0, 0, 0);
for (my $t = 0; $t < 1000; $t++) {
  if (-e $ready) { $go = 1; last }
  if (waitpid($pid, WNOHANG) == $pid) { ($done, $st) = (1, $?); last }
  select(undef, undef, undef, 0.01);
}
while ($go && !$done) {
  if (waitpid($pid, WNOHANG) == $pid) { ($done, $st) = (1, $?); last }
  kill("HUP", $pid) and $n++;
  select(undef, undef, undef, 0.03);
}
($done, $st) = (1, $?) if !$done && waitpid($pid, 0) == $pid;
open(my $f, ">", $sent) or exit 125;
print $f "$n\n";
close($f);
exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
PERL
chmod +x "$T/storm"
: >"$T/storm-start"
C_WRAP="$T/storm $SESS/req-$n.core $T/sent" c_run_raw execute "$T/request-$n"
st=$C_RC
# The result only from a whole response the protocol admits: a spool that is
# not one has no result to read.
r=""
if [ "$(c_admits execute)" = ok ]; then r=$(awk -F'\t' '$1 == "result" { print $2 " " $3 }' "$SESS/req-$n.events"); fi
# Bash 5.2 (not a target: macOS runs 3.2.57, the Linux root 5.3.15) loses a
# trap that runs while a command holding two command substitutions is
# expanded ("trap: line N: unexpected EOF while looking for matching `)'"),
# and the shell can die of it: bug-bash 2023-09 "Parse error in bash 5.2+
# with CHLD trap and 2 or more $() in a command", fixed for 5.3;
# tests/bash-trap-comsub.sh reproduces it without this tool. The core's own
# code holds no such command; lib/common.sh's log_event and lib/state.sh's
# run lock do, and stay byte for byte the accepted baseline's (test-static).
# Only that — the core's shell Bash 5.2, the death at one of those two
# commands, and the state such a death leaves (c_storm_exempt, tested above
# as sup-eintr-exemption) — is reported as what it is, and only what it left
# is removed; anything else is judged. CI runs this storm under the target's
# Bash 5.3.15 as well, where nothing is skipped.
C_WHY=""
if [ "$r" != "status=done code=ok" ] &&
  c_storm_exempt "$("${C_BASH:-$T_BASH}" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')" "$st" "$T" "$SESS" "$n" "$T/storm-start" "$T/storm-hello"; then
  skip "sup-eintr under a signal storm: Bash $BASH_VERSION loses a trap inside the baseline's two-substitution commands (Bash 5.2 upstream)"
else
  [ "$(cat "$T/sent")" -gt 10 ] && ok || fail "sup-eintr: signals reached the core while it ran ($(cat "$T/sent"))"
  assert_eq "$r" "status=done code=ok" "sup-eintr: signals during the reading leave a supervised completion"
  if [ "$r" != "status=done code=ok" ]; then
    printf '    the run: status %s; its spool:\n' "$st"
    sed 's/^/      /' "$SESS/req-$n.events" | cut -c1-200
    printf '    its stderr:\n'
    sed 's/^/      /' "$T/stderr" | head -20
    printf '    not exempt: %s\n' "$C_WHY"
  fi
  [ ! -e "$OPS" ] || ! grep -q 'state=unsupervised' "$OPS" && ok || fail "sup-eintr: no barrier from a signal"
fi
rm -f "$EFFECT"
c_conf mutate

# --- The registry decides how a child runs; an unchecked detaching child never runs --------
# tool_with_entry ACTION LINE — a copy of the tool whose registry has LINE for
# ACTION, resealed; its path.
tool_with_entry() {
  local d=$T/tool-$1
  rm -rf "$d"
  mkdir -p "$d/tests"
  cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$d/"
  cp -R "$REPO/tests/children" "$d/tests/"
  awk -F'\t' -v a="action=$1" -v l="$2" '$1 == "seal" { next } $1 == "child" && $2 == a { print l; next } { print }' \
    "$REPO/data/children.omb" >"$d/data/children.omb"
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    rec_seal_write "$d/data/children.omb"
  )
  printf '%s' "$d"
}
d=$(tool_with_entry test.mutate "child	action=test.mutate	cmd=tests/children/fake-mutate	class=mutating	stdout=null	stderr=null	tty=none	detaches=owned	owner=test%20owner	check=test.check")
C_HOME=$d c_exec test.mutate test
assert_eq "$(c_result)" "failed child" "a detaching child whose completion check this version does not run is refused"
assert_contains "$C_OUT" "detaches%20%28owned%29" "and says why"
[ ! -e "$EFFECT" ] && ok || fail "and nothing ran"
d=$(tool_with_entry test.read "child	action=test.read	cmd=tests/children/fake-read	class=handoff	stdout=functional	stderr=functional	tty=needs	detaches=no	owner=	check=")
C_HOME=$d c_exec test.read ""
assert_eq "$(c_result)" "failed child" "an action and its registry entry that disagree on the terminal run nothing"
assert_contains "$C_OUT" "a%20managed%20action%20but%20a%20handoff%20child" "and say how"

# An operation record that cannot be read: what it recorded is unknown, and
# a restart does not make it readable, so the text does not promise one.
mkdir -p "$T/state/ops"
printf 'omb-op 1\ntorn' >"$OPS"
c_exec test.mutate test
assert_eq "$(c_result)" "refused unsupervised" "an unreadable operation record refuses act in its scope"
assert_contains "$C_OUT" "cannot%20be%20read" "and says the record cannot be read"
c_run snapshot "scope	name=journey"
assert_contains "$C_OUT" "blocker	id=unsupervised	text=The%20operation%20record" "the snapshot names the record"
rm -f "$OPS"

# --- Lost supervision: the barrier ----------------------------------------------------------
# sup-completion-worker-lingers: a descendant stays in the group past the limit.
c_conf mutate linger=20 "pids=$T/owned"
c_exec test.mutate test
assert_eq "$(c_result)" "stopped unsupervised" "sup-completion-worker-lingers: not completed; the outcome unknown"
assert_contains "$(cat "$OPS")" "state=unsupervised" "the operation is marked unsupervised"
c_conf mutate
c_exec test.mutate test
assert_eq "$(c_result)" "refused unsupervised" "sup-unsupervised-blocks: the next act in the scope is refused"
assert_contains "$C_OUT" "restart%20this%20Mac" "naming the one way forward"
c_exec test.read ""
assert_eq "$(c_result)" "done ok" "read requests still work behind the barrier"
c_run snapshot "scope	name=journey"
assert_contains "$C_OUT" "blocker	id=unsupervised" "the snapshot shows the barrier"
assert_eq "$(printf '%s\n' "$C_OUT" | awk -F'\t' '$1 == "action" { sub(/^id=/, "", $2); printf "%s ", $2 }')" "test.read " \
  "and lists no act action in its scope"
t_signal_owned TERM "$T/owned" && rm -f "$T/owned"
sleep 0.5
c_exec test.mutate test
assert_eq "$(c_result)" "refused unsupervised" "an empty-looking group does not clear it within the boot"
printf '%s' "$(sed -n 's/.*	basis=\([0-9a-f]\{16\}\).*/\1/p' "$OPS")" >"$EFFECT"
c_exec test.mutate test
assert_eq "$(c_result)" "refused unsupervised" "nor does a matching postcondition"

# sup-boot-clears and sup-post-reboot-reconcile: a new boot session, then the
# expected effect completed.
printf '5E1D0B00-7A3C-4F21-9D6E-0000000000B2\n' >"$C_FIX/cmd/bootsession"
c_run snapshot "scope	name=journey"
assert_contains "$C_OUT" "from%20an%20earlier%20boot,%20to%20reconcile" "sup-boot-clears: the old boot's processes no longer hold it"
c_exec test.mutate test
assert_eq "$(c_result)" "done ok" "sup-post-reboot-reconcile: completed effect recorded, record removed, the action proceeds"
assert_contains "$C_OUT" "reconciled:%20completed" "the finding is completed"
assert_contains "$(cat "$T/state/state.env")" "op_journey_finding=test.mutate completed" "and recorded"
rm -f "$EFFECT"

# And with no effect: a new barrier, a new boot, nothing on the machine.
c_conf mutate linger=20 "pids=$T/owned"
c_exec test.mutate test
t_signal_owned TERM "$T/owned" && rm -f "$T/owned"
rm -f "$EFFECT"
printf '5E1D0B00-7A3C-4F21-9D6E-0000000000B3\n' >"$C_FIX/cmd/bootsession"
c_conf mutate
c_exec test.mutate test
assert_eq "$(c_result)" "done ok" "sup-post-reboot-reconcile: no effect recorded, the action proceeds"
assert_contains "$C_OUT" "reconciled:%20no-effect" "the finding is no effect"
rm -f "$EFFECT"

# sup-post-reboot-unexpected: the machine shows neither.
c_conf mutate linger=20 "pids=$T/owned"
c_exec test.mutate test
t_signal_owned TERM "$T/owned" && rm -f "$T/owned"
printf 'something else' >"$EFFECT"
printf '5E1D0B00-7A3C-4F21-9D6E-0000000000B4\n' >"$C_FIX/cmd/bootsession"
c_conf mutate
c_exec test.mutate test
assert_eq "$(c_result)" "refused unsupervised" "sup-post-reboot-unexpected: the scope stays blocked"
assert_contains "$C_OUT" "It%20needs%20you" "and needs the person"
[ -e "$OPS" ] && ok || fail "the reboot is not counted as success: the record stays"
rm -f "$OPS" "$EFFECT"

# sup-core-death-mutator-live: the core is killed while its child runs.
c_conf mutate sleep=4
c_prepare execute "exec	action=test.mutate	basis=$(c_basis test.mutate)	confirm=test"
n=$C_N
(c_run_raw execute "$T/request-$n") &
bg=$!
c_wait_file "$SESS/req-$n.worker-1"
c_core_signal KILL "$n"
wait "$bg" 2>/dev/null
assert_eq "$(awk -F'\t' '$1 == "result"' "$SESS/req-$n.events")" "" "the killed core wrote no result: the outcome is unknown"
c_conf mutate
c_exec test.mutate test
assert_eq "$(c_result)" "refused unsupervised" "sup-core-death-mutator-live: every act in the scope is refused unsupervised"
assert_contains "$C_OUT" "test.mutate" "naming the operation"
c_exec test.read ""
assert_eq "$(c_result)" "done ok" "read commands still work"
assert_contains "$(cat "$OPS")" "state=running" "sup-no-reclaim-pid: a record whose core's PID is dead is never reclaimed"
sleep 4
rm -f "$OPS" "$EFFECT"

# sup-mutator-escaped-pgid: the child starts a descendant in its own session
# that keeps writing, and the core is killed.
if command -v perl >/dev/null 2>&1; then
  c_conf mutate sleep=2 escape=4 "escape_out=$T/escaped"
  c_prepare execute "exec	action=test.mutate	basis=$(c_basis test.mutate)	confirm=test"
  n=$C_N
  (c_run_raw execute "$T/request-$n") &
  bg=$!
  c_wait_file "$SESS/req-$n.worker-1"
  c_core_signal KILL "$n"
  wait "$bg" 2>/dev/null
  c_wait_file "$T/escaped"
  pg=$(ps -o pgid= -p $$ | tr -d ' ')
  assert_eq "$(ps -axo pgid=,command= | awk -v g="$pg" '$1 == g' | grep -c '[p]erl -e')" 0 "the escaped descendant is not in the group"
  c_conf mutate
  c_exec test.mutate test
  assert_eq "$(c_result)" "refused unsupervised" "sup-mutator-escaped-pgid: the barrier stays for the rest of the boot"
  sleep 4
  rm -f "$OPS" "$EFFECT"
else
  skip "sup-mutator-escaped-pgid (no perl to make a new session)"
fi

# sup-pid-reuse: records whose PIDs now belong to other processes.
c_oprec() { # STATE PID START BOOT
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    mkdir -p "$T/state/ops"
    {
      printf 'omb-op 1\n'
      rec_line op action test.mutate scope journey basis "$(printf '%064d' 7)" session "$SESS" state "$1" finding "" pid "$2" start "$3" boot "$4" at 2026-09-26T00:00:00Z
    } >"$OPS"
    rec_seal_write "$OPS"
    omb_cleanup
  )
}
boot=$(cat "$C_FIX/cmd/bootsession")
live=$(ps -p $$ -o lstart= | awk '{$1 = $1; print}')
c_oprec running $$ "Mon Jan  1 00:00:00 2001" "$boot"
c_exec test.mutate test
assert_eq "$(c_result)" "refused unsupervised" "sup-pid-reuse: a live PID with another start time is not the recorded core"
c_oprec running $$ "$live" "$boot"
c_exec test.mutate test
assert_eq "$(c_result)" "refused busy" "the recorded core itself, alive: busy"
c_oprec running $$ "$live" "5E1D0B00-7A3C-4F21-9D6E-000000000000"
c_run snapshot "scope	name=journey"
assert_contains "$C_OUT" "from%20an%20earlier%20boot" "sup-pid-reuse: an identity from a previous boot is not alive"
rm -f "$OPS"

# sup-identity-unknown: ps fails, or the boot session cannot be read.
shim=$(t_tmp)
printf '#!/bin/sh\nexit 1\n' >"$shim/ps" && chmod +x "$shim/ps"
c_oprec running $$ "$live" "$boot"
C_PATH="$shim:/usr/bin:/bin:/usr/sbin:/sbin" c_exec test.mutate test
assert_eq "$(c_result)" "refused busy" "sup-identity-unknown: ps failing, the recorded core counts as possibly alive"
rm -f "$OPS"
C_PATH="$shim:/usr/bin:/bin:/usr/sbin:/sbin" c_exec test.mutate test
assert_eq "$(c_result)" "refused unavailable" "ps failing, no child is started without its group snapshot"
[ ! -e "$OPS" ] && [ ! -e "$EFFECT" ] && ok || fail "and nothing ran"
mv "$C_FIX/cmd/bootsession" "$C_FIX/cmd/bootsession.gone"
c_exec test.mutate test
assert_eq "$(c_result)" "refused unavailable" "sup-identity-unknown: the boot session unreadable, no act is supervised"
c_oprec unsupervised $$ "$live" "$boot"
c_exec test.mutate test
assert_eq "$(c_result)" "refused unsupervised" "and no barrier is cleared on its strength"
mv "$C_FIX/cmd/bootsession.gone" "$C_FIX/cmd/bootsession"
rm -f "$OPS"
printf 'omb-op 1\nop\taction=test.mutate\n' >"$OPS"
c_exec test.mutate test
assert_eq "$(c_result)" "refused unsupervised" "an operation record that cannot be admitted is a barrier, never ignored"
rm -f "$OPS"

# sup-read-orphan-no-barrier: the core of a read request is killed while its
# read child runs on.
c_conf read sleep=3
c_prepare execute "exec	action=test.read	basis=$(c_basis test.read)	confirm="
n=$C_N
(c_run_raw execute "$T/request-$n") &
bg=$!
c_wait_file "$SESS/req-$n.worker-1"
c_core_signal KILL "$n"
wait "$bg" 2>/dev/null
[ ! -e "$OPS" ] && ok || fail "sup-read-orphan-no-barrier: no operation record"
rm -f "$C_FIX/test-children/read"
c_exec test.mutate test
assert_eq "$(c_result)" "done ok" "sup-read-orphan-no-barrier: the next act proceeds"
rm -f "$EFFECT"
sleep 3

# --- frontend-check-*: the startup-check session ---------------------------------------
# (docs/PROTOCOL.md → The startup-check session.) No fixture: the core reads
# this machine as it answers hello, and a uname shim gives every runner the
# aarch64 answer a hello needs. Its state folder is its own and never made.
CK_SHIM=$(t_tmp)
c_uname_arm "$CK_SHIM"
CK_STATE=$T/ck-state
# ck OP RECORD... — one request in a check session. CK_ENV's assignments
# come last, and env -i keeps the last value a name is given; an empty
# OMB_FIXTURE or OMB_FRONTEND_DEV is off.
ck() {
  C_FOUNDATION=0 C_PATH="$CK_SHIM:/usr/bin:/bin:/usr/sbin:/sbin" \
    C_ENV="OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_SESSION_INTENT=read OMB_SESSION_PURPOSE=frontend-check OMB_STATE_DIR=$CK_STATE ${CK_ENV:-}" c_run "$@"
}
CK_H64=$(printf '%064d' 7)
# ck_every — every operation, one request each: "OP=status code" per line,
# and "OP=inadmissible" for an answer that is not a whole response to OP.
ck_every() {
  local op
  for op in hello snapshot detail validate execute; do
    case $op in
      hello) ck hello ;;
      snapshot) ck snapshot "scope	name=journey" ;;
      detail) ck detail "page	scope=journey	kind=inventory	generation=$CK_H64	offset=0	limit=2" ;;
      validate) ck validate "select	action=test.read" ;;
      execute) ck execute "exec	action=test.read	basis=$CK_H64	confirm=" ;;
    esac
    if [ "$(c_admits "$op")" = ok ]; then echo "$op=$(c_result)"; else echo "$op=inadmissible"; fi
  done
}
refused_all="hello=error environment
snapshot=error environment
detail=error environment
validate=error environment
execute=error environment"

# frontend-check-purpose-env: the purpose with anything but the check's own
# session, or with a production seam set, is refused for every operation.
for e in "OMB_SESSION_INTENT=act" "OMB_SESSION_INTENT=plan" "OMB_SESSION_SCOPES=journey,disk" "OMB_SESSION_SCOPES=disk" \
  "OMB_DRY_RUN=1" "OMB_FIXTURE=$C_FIX" "OMB_FIXTURE=$C_FIX OMB_FRONTEND_DEV=x" "OMB_TEST_HOOK=x" "OMB_TEST_FUTURE=x" \
  "OMB_SESSION_PURPOSE=" "OMB_SESSION_PURPOSE=frontend-checks" "OMB_SESSION_PURPOSE=install"; do
  r=$(CK_ENV="$e" ck_every)
  assert_eq "$r" "$refused_all" "frontend-check-purpose-env: $e: every operation refused as environment"
done
# OMB_FRONTEND_DEV outside fixture mode never reaches the core: the entrypoint
# refuses it first (status 2, no answer), as for every command.
CK_ENV="OMB_FRONTEND_DEV=x" ck hello
assert_rc "$C_RC" 2 "frontend-check-purpose-env: OMB_FRONTEND_DEV without a fixture is refused before the core"
assert_eq "$C_OUT" "omb-res 1" "and nothing is answered"
# The purpose unset: the ordinary contract, which refuses a snapshot outside
# fixture mode (the gate's foundation reads only fixtures).
C_PATH="$CK_SHIM:/usr/bin:/bin:/usr/sbin:/sbin" \
  C_ENV="OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_SESSION_INTENT=read OMB_STATE_DIR=$CK_STATE" c_run snapshot "scope	name=journey"
assert_eq "$(c_result)" "refused unavailable" "frontend-check-purpose-env: with no purpose, the ordinary contract answers"
# Controls: names the prefix rule does not match, and an empty OMB_TEST_ one.
for e in "OMB_TEST_FUTURE=" "OMB_TESTING=x" "OMB_TEST=x" "SOME_OMB_TEST_X=x"; do
  CK_ENV="$e" ck hello
  assert_eq "$(c_result)" "done ok" "frontend-check-purpose-env: $e is not a seam the rule refuses"
done

# frontend-check-snapshot: the check's journey snapshot, exactly.
ck hello
assert_eq "$(c_result)" "done ok" "frontend-check-read-session: hello answered"
hello=$(printf '%s\n' "$C_OUT" | sed -n 2p)
assert_contains "$hello" "	ceiling=read	dry_run=0	fixture=0" "frontend-check-no-fixture: the hello says read, not a dry run, no fixture"
ck snapshot "scope	name=journey"
assert_eq "$(c_admits snapshot)" ok "frontend-check-snapshot: admitted by the Bash admission"
assert_eq "$(printf '%s\n' "$C_OUT" | cut -f1 | tr '\n' ' ')" "omb-res 1 hello generation fact fact fact fact result " "frontend-check-snapshot: hello, generation, four facts, result"
ck_first=$(sed -n '3,$p' "$C_EV")
ck_corpus=$(t_tmp)
"$T_BASH" "$REPO/tests/proto/corpus.sh" "$ck_corpus" >/dev/null || fail "the corpus generator failed"
assert_eq "$ck_first" "$(sed -n '3,$p' "$ck_corpus/frontend-check-snapshot.doc")" \
  "frontend-check-snapshot: after hello, byte for byte the corpus case both admissions read (tests/proto/corpus.sh)"
facts=$(sed -n '4,7p' "$C_EV")
assert_eq "$(sed -n 3p "$C_EV")" "generation	id=$( (printf '%s' "$facts") | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-64)	total=0" \
  "frontend-check-snapshot: the generation is the SHA-256 of the records after it"
ck snapshot "scope	name=journey"
assert_eq "$(sed -n '3,$p' "$C_EV")" "$ck_first" "frontend-check-snapshot: a refresh is byte-identical after hello"
c_session
ck snapshot "scope	name=journey"
assert_eq "$(sed -n '3,$p' "$C_EV")" "$ck_first" "frontend-check-snapshot: and so is another session of the same checkout"

[ ! -e "$CK_STATE" ] && ok || fail "frontend-check-no-state: no check request made the state folder"

# frontend-check-zero-actions: an unsupervised and a failed operation record
# in the state folder are neither shown, reconciled nor touched.
mkdir -p "$CK_STATE/ops"
(
  t_load >/dev/null 2>&1
  # shellcheck source=lib/records.sh
  . "$REPO/lib/records.sh"
  for s in journey:unsupervised disk:failed; do
    f=$CK_STATE/ops/${s%%:*}.omb
    fd=""
    [ "${s#*:}" = failed ] && fd=absent
    { printf 'omb-op 1\n' && rec_line op action test.mutate scope "${s%%:*}" basis "$CK_H64" session "$SESS" state "${s#*:}" finding "$fd" pid 1 start x boot x at 2026-09-26T00:00:00Z; } >"$f"
    rec_seal_write "$f"
  done
  omb_cleanup
)
ck_before=$(t_snapshot "$CK_STATE")
ck snapshot "scope	name=journey"
assert_eq "$(sed -n '3,$p' "$C_EV")" "$ck_first" "frontend-check-zero-actions: the same snapshot whatever operation records exist"
assert_eq "$(printf '%s\n' "$C_OUT" | cut -f1 | grep -cE '^(action|param|stage|blocker|warning)$')" 0 "frontend-check-zero-actions: no action, param, stage, blocker or warning"
assert_eq "$(t_snapshot "$CK_STATE")" "$ck_before" "frontend-check-zero-actions: both records byte-identical after it"

# frontend-check-forbidden-scope: every other scope refused, with the
# generation of the empty data set.
empty_gen=$( (printf '') | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-64)
for s in disk plan profile resolve asahi network omarchy shared export restore rescue qualify debug; do
  ck snapshot "scope	name=$s"
  assert_eq "$(c_result) $(c_admits snapshot)" "refused scope ok" "frontend-check-forbidden-scope: $s refused scope"
  assert_eq "$(sed -n 3p "$C_EV")" "generation	id=$empty_gen	total=0" "frontend-check-forbidden-scope: $s answered with the empty data set's generation"
done

# frontend-check-execute-refused: every execute refused before anything is
# looked up, locked, recorded, re-read or started — whatever its action,
# basis, word or arguments.
# The last is the basis an explicitly owned foundation fixture shows.
vb=$(c_fixture; c_basis test.mutate)
[ -n "$vb" ] && ok || fail "a foundation session lists test.mutate, whose basis the check's execute then carries"
for x in "test.read	basis=$CK_H64	confirm=" "test.mutate	basis=$CK_H64	confirm=test" "test.handoff	basis=$CK_H64	confirm=start" \
  "no.such.action	basis=$CK_H64	confirm=" "test.mutate	basis=${vb:-$CK_H64}	confirm=test"; do
  ck execute "exec	action=$x" "arg	name=size	value=1" "arg	name=disk	value=disk0"
  assert_eq "$(c_result) $(c_admits execute)" "refused unavailable ok" "frontend-check-execute-refused: ${x%%	*}"
  assert_eq "$(ls "$SESS" | grep -c "^req-$C_N\.worker-")" 0 "frontend-check-execute-refused: ${x%%	*} started no child"
done
assert_eq "$(t_snapshot "$CK_STATE")" "$ck_before" "frontend-check-execute-refused: no lock, operation record or effect written"
# frontend-check-detail-refused, frontend-check-validate-refused.
ck detail "page	scope=journey	kind=inventory	generation=$CK_H64	offset=0	limit=2"
assert_eq "$(c_result) $(c_admits detail)" "refused unavailable ok" "frontend-check-detail-refused"
assert_eq "$(sed -n 3p "$C_EV")" "generation	id=$empty_gen	total=0" "frontend-check-detail-refused: with the empty data set's generation"
ck validate "select	action=test.read"
assert_eq "$(c_result) $(c_admits validate)" "refused unavailable ok" "frontend-check-validate-refused"
# frontend-check-no-state: the core's side wrote nothing into its state
# folder in any case above (the records placed there are the test's own).
rm -rf "$CK_STATE/ops"
assert_eq "$(find "$CK_STATE" | wc -l | tr -d ' ')" 1 "frontend-check-no-state: the check's cores wrote nothing into the state folder"
rm -rf "$CK_STATE"

t_decoys_survive test-core
t_done test-core
