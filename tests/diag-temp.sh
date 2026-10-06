#!/usr/bin/env bash
# One unit of the diagnostics tests, run by tests/test-diag.sh and on its own:
# 10 GiB of stderr, the capture file sampled while the child runs.
# It starts from a fresh session (tests/diag-lib.sh).
# shellcheck disable=SC2010,SC2015,SC2016,SC2031 # ls|grep over the core's own file names; ok/fail always return 0; literal $ in patterns; $! read after a job started in this shell
echo "test-diag-temp"
# shellcheck source=tests/diag-lib.sh
. "$(dirname "$0")/diag-lib.sh"

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

t_decoys_survive test-diag-temp
t_done test-diag-temp
