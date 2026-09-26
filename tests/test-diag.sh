#!/usr/bin/env bash
# Diagnostics by child class (docs/PROTOCOL.md → *Diagnostics, by child
# class*) and the spool's bound (*Backpressure and bounds*): every retained
# byte — headers, payload, summaries — within 65 536 a child, 262 144 a
# request, 4 194 304 a session, reserved before anything is appended; a
# saturated request or session adds nothing; the drain never blocks the child.
# diag-* and sup-overflow, over the fake read child in fixture mode.
# shellcheck disable=SC2010,SC2015,SC2016 # ls|grep over the core's own file names; ok/fail always return 0; literal $ in patterns
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-diag"
T=$(t_tmp)
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"

c_session
c_fixture
# The block header's length for test.read (fixed width: exit and kept are
# zero-padded), counted in every limit.
H=$(printf 'child\ttest.read\texit=000\tkept=00000\tdiscarded=0\n' | wc -c | tr -d ' ')
diag() { printf '%s/req-%s.diag' "$SESS" "$C_N"; }
summ() { printf '%s/req-%s.diag-summary' "$SESS" "$C_N"; }
session_total() {
  c_size "$SESS"/req-*.diag "$SESS"/req-*.diag-summary "$SESS/session.diag-summary"
}
# The launcher writes the session's summary with the scratch.
printf '%-127s\n' "diagnostics truncated: children not kept 0000000000, bytes discarded at least 0000000000" >"$SESS/session.diag-summary"

# --- diag-overflow-discard: 65 280 bytes kept whole; 65 281, the last 65 280 ---------
c_conf read stderr_bytes=65280
c_exec test.read ""
assert_eq "$(c_result)" "done ok" "a read child writing 65 280 bytes"
assert_eq "$(c_size "$(diag)")" $((H + 65280)) "kept whole: header and 65 280 bytes"
assert_contains "$(head -1 "$(diag)")" "kept=65280	discarded=0" "and not marked"
c_conf read stderr_bytes=65281
c_exec test.read ""
assert_eq "$(c_size "$(diag)")" $((H + 65280)) "65 281 bytes: the last 65 280 kept"
assert_contains "$(head -1 "$(diag)")" "kept=65280	discarded=1" "and marked discarded"
assert_eq "$(c_size "$(summ)")" 128 "the request's summary is exactly 128 bytes"

# --- diag-functional-not-budgeted: functional output is outside the limits --------------
# Gate 1's functional output is a read child's stdout, under its own 64 KiB
# file limit; qualification's stream and an export's objects come with the
# gates that build them.
c_conf read stderr_bytes=100 stdout_bytes=60000
c_exec test.read ""
assert_eq "$(c_result)" "done ok" "diag-functional-not-budgeted: a read child writing 60 000 bytes of functional output"
assert_eq "$(c_size "$(diag)")" $((H + 100)) "diag-functional-not-budgeted: its block holds only its 100 bytes of diagnostics"
assert_contains "$(head -1 "$(diag)")" "kept=00100	discarded=0" "diag-functional-not-budgeted: none of the functional output counted"

# --- diag-bound-read: 10 MiB of stderr, unblocked, one bounded block --------------------
c_conf read stderr_bytes=10485760
t0=$SECONDS
c_exec test.read ""
assert_eq "$(c_result)" "done ok" "diag-bound-read: a read child writing 10 MiB runs to its end"
[ $((SECONDS - t0)) -lt 60 ] && ok || fail "diag-bound-read: unblocked"
n=$(c_size "$(diag)")
[ "$n" -le 65536 ] && ok || fail "diag-bound-read: the block, header included, is at most 65 536 bytes ($n)"
assert_contains "$(head -1 "$(diag)")" "discarded=1" "diag-bound-read: earlier output marked discarded"

# --- diag-temp-bounded: 10 GiB of stderr; the capture file sampled while it runs --------
c_conf read stderr_bytes=10737418240
c_prepare execute "exec	action=test.read	basis=$(c_basis test.read)	confirm="
n=$C_N
(c_run_raw execute "$T/request-$n") &
bg=$!
cap=$SESS/req-$n.capture
max=0 samples=0
while kill -0 "$bg" 2>/dev/null; do
  if [ -f "$cap" ]; then
    s=$(wc -c <"$cap" 2>/dev/null | tr -d ' ')
    case "$s" in '' | *[!0-9]*) s=0 ;; esac
    [ "$s" -gt "$max" ] && max=$s
    samples=$((samples + 1))
  fi
  sleep 0.05
done
wait "$bg"
[ "$samples" -gt 10 ] && ok || fail "diag-temp-bounded: the capture file was sampled while the child ran ($samples samples)"
[ "$max" -le 65281 ] && ok || fail "diag-temp-bounded: the capture file never exceeded 65 281 bytes ($max)"
[ ! -e "$cap" ] && ok || fail "diag-temp-bounded: the capture file is removed once merged"
assert_eq "$(awk -F'\t' '$1 == "result" { print $2 }' "$SESS/req-$n.events")" "status=done" "diag-temp-bounded: the read completes"
n=$(c_size "$SESS/req-$n.diag")
[ "$n" -le 65536 ] && ok || fail "diag-temp-bounded: its block is at most 65 536 bytes"

# --- diag-header-counted: children that print nothing ----------------------------------
c_conf read stderr_bytes=0
c_conf core children=3
c_exec test.read ""
assert_eq "$(c_size "$(diag)")" $((3 * H)) "diag-header-counted: three blocks, each its header alone"
assert_eq "$(grep -c '^child	test.read	exit=000	kept=00000	discarded=0$' "$(diag)")" 3 "each header says nothing was kept (headers alone: one per line)"

# --- diag-request-bound: children producing far more than 256 KiB ------------------------
c_conf read stderr_bytes=70000
c_conf core children=8
c_exec test.read ""
assert_eq "$(c_result)" "done ok" "diag-request-bound: eight noisy children in one request"
total=$(c_size "$(diag)" "$(summ)")
[ "$total" -le 262144 ] && ok || fail "diag-request-bound: the request's files hold at most 262 144 bytes ($total)"
assert_eq "$(c_size "$(summ)")" 128 "diag-request-bound: its summary is 128 bytes"
blocks=$(grep -ao "child	test.read	exit=" "$(diag)" | wc -l | tr -d " ")
kept_not=$(sed -n "s/.*children not kept \([0-9]*\).*/\1/p" "$(summ)")
assert_eq "$((blocks + 10#$kept_not))" 8 "diag-request-bound: every child is a block or counted in the summary ($blocks kept)"
[ "$(c_size "$(diag)")" -le 262016 ] && ok || fail "diag-request-bound: the child blocks hold at most 262 016 bytes"

# --- diag-budget-near-edge: one byte of room left ---------------------------------------
c_conf read stderr_bytes=65537
c_conf core children=1
b=$(c_basis test.read)
n=$((C_N + 1))
head -c 262015 /dev/zero >"$SESS/req-$n.diag"
printf '%-127s\n' "diagnostics truncated: children not kept 0000000000, bytes discarded at least 0000000000" >"$SESS/req-$n.diag-summary"
c_run execute "exec	action=test.read	basis=$b	confirm="
assert_eq "$C_N" "$n" "the request is the one prepared"
assert_eq "$(c_result)" "done ok" "diag-budget-near-edge: the read itself succeeds"
assert_eq "$(c_size "$(diag)")" 262015 "diag-budget-near-edge: nothing appended beyond the limit, not even a header"
assert_contains "$(cat "$(summ)")" "children not kept 0000000001, bytes discarded at least 0000065537" "diag-budget-near-edge: the child counted in the summary"
assert_eq "$(c_size "$(summ)")" 128 "and the summary still 128 bytes"

# --- diag-request-saturated-many-children: 10 000 more children ------------------------
# Four noisy children fill the request; 10 000 more follow. From the moment
# the summary first counts a child it could not keep, the request's files
# must not grow by a single byte.
c_conf read stderr_bytes=70000
c_conf core children=10004
b=$(c_basis test.read)
c_prepare execute "exec	action=test.read	basis=$b	confirm="
n=$C_N
(c_run_raw execute "$T/request-$n") &
bg=$!
d=$SESS/req-$n.diag s=$SESS/req-$n.diag-summary
i=0
until grep -q 'children not kept 0000000001' "$s" 2>/dev/null || [ "$i" -ge 1200 ]; do sleep 0.05 && i=$((i + 1)); done
at_saturation=$(c_size "$d" "$s")
wait "$bg"
C_OUT=$(cat "$C_EV")
assert_eq "$(c_result)" "done ok" "diag-request-saturated-many-children: 10 004 children in one request"
assert_eq "$(c_size "$d" "$s")" "$at_saturation" "diag-request-saturated-many-children: not a byte added after saturation"
[ "$(c_size "$d")" -le 262016 ] && ok || fail "the request's blocks stay within 262 016 bytes"
assert_eq "$(c_size "$s")" 128 "diag-request-saturated-many-children: the summary is still 128 bytes"
blocks=$(grep -ao "child	test.read	exit=" "$d" | wc -l | tr -d " ")
kept_not=$(sed -n "s/.*children not kept \([0-9]*\).*/\1/p" "$s")
assert_eq "$((blocks + 10#$kept_not))" 10004 "every one of the 10 004 children is a kept block or counted ($blocks kept)"

# --- diag-overflow-one-summary: one fixed summary per request, rewritten in place ------
assert_eq "$(ls "$SESS" | grep -c "^req-$C_N\.diag-summary")" 1 "diag-overflow-one-summary: one summary for the request"
assert_eq "$(ls "$SESS" | grep -c 'summary\.')" 0 "diag-overflow-one-summary: no sequence of markers or leftovers"

# --- diag-session-bound: many requests producing far more than 4 MiB -------------------
c_conf read stderr_bytes=70000
c_conf core children=5
i=0
while [ "$i" -lt 18 ]; do
  c_exec test.read ""
  i=$((i + 1))
done
total=$(session_total)
[ "$total" -le 4194304 ] && ok || fail "diag-session-bound: the session's diagnostics hold at most 4 194 304 bytes ($total)"
assert_eq "$(c_size "$SESS/session.diag-summary")" 128 "diag-session-bound: the session's summary is 128 bytes"

# --- diag-session-saturated-many-requests: 1 000 more requests --------------------------
files=$(ls "$SESS" | grep -c 'diag')
c_conf core children=1
# One snapshot's basis serves every request: test.read's basis holds only
# what does not change between them.
b=$(c_basis test.read)
i=0
while [ "$i" -lt 1000 ]; do
  c_run execute "exec	action=test.read	basis=$b	confirm="
  [ "$(c_result)" = "done ok" ] || { fail "a request after saturation: $(c_result)" && break; }
  i=$((i + 1))
done
assert_eq "$(ls "$SESS" | grep -c 'diag')" "$files" "diag-session-saturated-many-requests: no new diagnostic file"
assert_eq "$(session_total)" "$total" "diag-session-saturated-many-requests: the session's total did not grow"
assert_eq "$(c_size "$SESS/session.diag-summary")" 128 "diag-session-saturated-many-requests: the session summary stays 128 bytes"
assert_contains "$(cat "$SESS/session.diag-summary")" "children not kept 0000001" "the saturated requests' children are counted in it"

# --- diag-capture-failure: the drain killed mid-run ------------------------------------
c_session
printf '%-127s\n' "diagnostics truncated: children not kept 0000000000, bytes discarded at least 0000000000" >"$SESS/session.diag-summary"
c_conf read stderr_bytes=2000000000
c_conf core children=1
c_prepare execute "exec	action=test.read	basis=$(c_basis test.read)	confirm="
n=$C_N
(c_run_raw execute "$T/request-$n") &
bg=$!
c_wait_file "$SESS/req-$n.capture"
sleep 0.3
pkill -f "tail -c 65281" 2>/dev/null
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

t_done test-diag
