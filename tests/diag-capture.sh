#!/usr/bin/env bash
# One unit of the diagnostics tests, run by tests/test-diag.sh and on its own:
# the drain killed or unwritable, a planted token, a handoff's terminal, and the spool's bound.
# It starts from a fresh session (tests/diag-lib.sh).
# shellcheck disable=SC2010,SC2015,SC2016,SC2031 # ls|grep over the core's own file names; ok/fail always return 0; literal $ in patterns; $! read after a job started in this shell
echo "test-diag-capture"
# shellcheck source=tests/diag-lib.sh
. "$(dirname "$0")/diag-lib.sh"

# --- diag-capture-failure: the drain killed mid-run ------------------------------------
c_session
c_fixture
printf '%-127s\n' "diagnostics truncated: children not kept 0000000000, bytes discarded at least 0000000000" >"$SESS/session.diag-summary"
c_conf read stderr_bytes=2000000000
c_conf core children=1
c_prepare execute "exec	action=test.read	basis=$(c_basis test.read)	confirm="
n=$C_N
(c_run_raw execute "$T/request-$n") &
bg=$!
c_wait_file "$SESS/req-$n.capture"
sleep 0.3
# The drain is the core's own child: found among that core's children, and
# signalled as the process it was when found.
drain=$(t_child "$(c_core_pid "$n")" "tail -c 65281")
t_signal TERM "${drain%% *}" "${drain#* }" && ok || fail "diag-capture-failure: the core's drain, among its own children ($drain)"
wait "$bg"
out=$(cat "$SESS/req-$n.events")
assert_contains "$out" "diagnostics%20not%20available" "diag-capture-failure: the diagnostics are shown as not available"
# The broken pipe ends the child's own writer (its head), not the child:
# the read is judged by the child's own status, which is 0.
assert_contains "$out" "result	status=done	code=ok" "diag-capture-failure: the read is judged by its own status and functional output"
assert_not_contains "$out" "status=error" "and nothing else is made of it"
# The scratch full when the drain writes: the drain cannot keep its tail.
c_conf read stderr_bytes=1000
c_prepare execute "exec	action=test.read	basis=$(c_basis test.read)	confirm="
n=$C_N
mkdir "$SESS/req-$n.capture"
c_run_raw execute "$T/request-$n"
assert_contains "$C_OUT" "diagnostics%20not%20available" "diag-capture-failure: a capture that cannot be written: not available"
assert_contains "$C_OUT" "result	status=done	code=ok" "diag-capture-failure: the read still judged by its own status"
rmdir "$SESS/req-$n.capture"

# --- diag-raw-sensitive: a planted token stays in the scratch --------------------------
token=ghp_PLANTEDTOKEN0123456789abcdefghijklmnop
c_conf read "stderr_text=$token"
c_exec test.read ""
grep -q "$token" "$(diag)" && ok || fail "diag-raw-sensitive: the token is on the log screen's file"
assert_not_contains "$C_OUT" "$token" "diag-raw-sensitive: never in a record"
assert_eq "$(grep -rl "$token" "$T/state" 2>/dev/null)" "" "diag-raw-sensitive: never in the state directory or its log"

# --- diag-handoff-not-captured (static): a handoff child's output is the terminal ------
code=$(awk '/^core_child\(\) \{/ {f = 1} f {print} f && /^}/ {exit}' "$REPO/lib/core.sh")
assert_contains "$code" '    handoff)
      # The terminal, never captured.
      (_core_worker_exec "$CORE_WORKERS" "$cmd" "$@")' "diag-handoff-not-captured: no redirection of a handoff child"

# --- sup-overflow: more than 8 MiB − 64 KiB of progress ------------------------------------
c_conf core progress=150000 children=1
c_conf read stderr_bytes=0
c_exec test.read ""
size=$(c_size "$C_EV")
[ "$size" -le 8388608 ] && ok || fail "sup-overflow: the spool stays under 8 MiB ($size)"
assert_eq "$(tail -2 "$C_EV" | cut -f1 | tr '\n' ' ')" "overflow result " "sup-overflow: one overflow, then the result"
assert_eq "$(grep -c '^overflow	' "$C_EV")" 1 "sup-overflow: exactly one overflow record"
assert_eq "$(c_admits execute)" ok "sup-overflow: the whole spool is admissible"

t_decoys_survive test-diag-capture
t_done test-diag-capture
