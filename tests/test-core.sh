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
C_FE=0.2.0 C_ENV="OMB_FRONTEND_DEV=" c_run hello
assert_rc "$C_RC" 3 "a frontend version the lock does not name: exit 3"
assert_eq "$(c_result)" "refused frontend" "and refused frontend"
assert_eq "$(c_admits hello)" ok "the refusal is itself an admissible response"
C_ENV="OMB_FRONTEND_DEV=" c_run hello
assert_eq "$(c_result)" "refused frontend" "with no release lock, only the fixture-mode development override is accepted"
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

# A child that leaves nothing, whose effect is not there: failed, not unknown.
c_conf mutate effect=none
c_exec test.mutate test
assert_eq "$(c_result)" "failed postcondition" "no effect on the machine: failed, judged by the postcondition"
assert_contains "$C_OUT" "next=Run%20by%20hand" "the command is shown for running by hand"
[ ! -e "$OPS" ] && ok || fail "a failed but supervised operation leaves no barrier"

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
c_conf read "fds=$T/fds-read" "grandchild=30" "grandchild_fds=$T/fds-grand"
t0=$SECONDS
c_exec test.read ""
assert_eq "$(c_result)" "done ok" "sup-fd-grandchild: the read completes"
[ $((SECONDS - t0)) -lt 15 ] && ok || fail "sup-fd-grandchild: the core ended without waiting for the grandchild"
c_wait_file "$T/fds-grand"
assert_eq "$(cat "$T/fds-read")" "$base" "sup-fd-child: the read child holds only what its caller held"
assert_eq "$(cat "$T/fds-grand")" "$base" "sup-fd-grandchild: the grandchild holds only what its caller held"
assert_contains "$C_OUT" "diagnostics%20not%20available" "the grandchild holding stderr leaves the diagnostics not available, not the core waiting"
pkill -f "sleep 30" 2>/dev/null
case " $base " in *" 3 "*) fail "the harness itself held fd 3" ;; *) ok ;; esac
rm -f "$T/test-children-none"
rm -f "$C_FIX/test-children/read"

# --- Lost supervision: the barrier ----------------------------------------------------------
# sup-completion-worker-lingers: a descendant stays in the group past the limit.
c_conf mutate linger=20
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
pkill -f "sleep 20" 2>/dev/null
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
c_conf mutate linger=20
c_exec test.mutate test
pkill -f "sleep 20" 2>/dev/null
rm -f "$EFFECT"
printf '5E1D0B00-7A3C-4F21-9D6E-0000000000B3\n' >"$C_FIX/cmd/bootsession"
c_conf mutate
c_exec test.mutate test
assert_eq "$(c_result)" "done ok" "sup-post-reboot-reconcile: no effect recorded, the action proceeds"
assert_contains "$C_OUT" "reconciled:%20no-effect" "the finding is no effect"
rm -f "$EFFECT"

# sup-post-reboot-unexpected: the machine shows neither.
c_conf mutate linger=20
c_exec test.mutate test
pkill -f "sleep 20" 2>/dev/null
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
kill -9 "$(c_core_pid "$n")" 2>/dev/null
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
  kill -9 "$(c_core_pid "$n")" 2>/dev/null
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
      rec_line op action test.mutate scope journey basis "$(printf '%064d' 7)" session "$SESS" state "$1" pid "$2" start "$3" boot "$4" at 2026-09-26T00:00:00Z
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
kill -9 "$(c_core_pid "$n")" 2>/dev/null
wait "$bg" 2>/dev/null
[ ! -e "$OPS" ] && ok || fail "sup-read-orphan-no-barrier: no operation record"
rm -f "$C_FIX/test-children/read"
c_exec test.mutate test
assert_eq "$(c_result)" "done ok" "sup-read-orphan-no-barrier: the next act proceeds"
rm -f "$EFFECT"
sleep 3

t_done test-core
