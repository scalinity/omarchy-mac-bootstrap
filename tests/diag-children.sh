#!/usr/bin/env bash
# One unit of the diagnostics tests, run by tests/test-diag.sh and on its own:
# 10 004 children in one request, which saturates, and its one summary.
# It starts from a fresh session (tests/diag-lib.sh).
# shellcheck disable=SC2010,SC2015,SC2016,SC2031 # ls|grep over the core's own file names; ok/fail always return 0; literal $ in patterns; $! read after a job started in this shell
echo "test-diag-children"
# shellcheck source=tests/diag-lib.sh
. "$(dirname "$0")/diag-lib.sh"

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

t_decoys_survive test-diag-children
t_done test-diag-children
