#!/usr/bin/env bash
# One unit of the diagnostics tests, run by tests/test-diag.sh and on its own:
# a session filled past 4 MiB, then 1 000 more requests that add nothing.
# It starts from a fresh session (tests/diag-lib.sh).
# shellcheck disable=SC2010,SC2015,SC2016,SC2031 # ls|grep over the core's own file names; ok/fail always return 0; literal $ in patterns; $! read after a job started in this shell
echo "test-diag-session"
# shellcheck source=tests/diag-lib.sh
. "$(dirname "$0")/diag-lib.sh"

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

# The requests below need a saturated session: the ones above saturate this
# unit's fresh session.
assert_not_contains "$(cat "$SESS/session.diag-summary")" "children not kept 0000000000" "diag-session-saturated-many-requests: the session is saturated before the 1 000 requests"

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

t_decoys_survive test-diag-session
t_done test-diag-session
