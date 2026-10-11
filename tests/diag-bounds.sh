#!/usr/bin/env bash
# One unit of the diagnostics tests, run by tests/test-diag.sh and on its own:
# a child's, a request's and functional output's bounds, and a request with one byte of room.
# It starts from a fresh session (tests/diag-lib.sh).
# shellcheck disable=SC2010,SC2015,SC2016,SC2031 # ls|grep over the core's own file names; ok/fail always return 0; literal $ in patterns; $! read after a job started in this shell
echo "test-diag-bounds"
# shellcheck source=tests/diag-lib.sh
. "$(dirname "$0")/diag-lib.sh"

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

t_decoys_survive test-diag-bounds
t_done test-diag-bounds
