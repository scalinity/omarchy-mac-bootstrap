#!/usr/bin/env bash
# Ordinary Gate 2 authority; the existing core harness and filesystem oracle.
# shellcheck disable=SC2030,SC2031,SC2086,SC2162,SC2317,SC2329 # scoped environments, word-split case tables, test callbacks; read taps forward the caller's own flags
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-read
T=$(t_tmp)
c_session
C_FIX=$FIX/mac-m1pro-1tb-roomy
before=$(t_snapshot "$T/state")
for ceiling in read plan act; do
  C_ENV="OMB_SESSION_INTENT=$ceiling" c_run hello
  assert_eq "$(c_result) $C_RC" 'done ok 0' "ordinary fixture hello at $ceiling ceiling, purpose unset"
  for action in test.read test.mutate test.handoff plan.save asahi.launch resume; do
    C_ENV="OMB_SESSION_INTENT=$ceiling" c_run execute "exec	action=$action	basis=$(printf '%064d' 0)	confirm=test"
    assert_eq "$(c_result)" 'refused unavailable' "ordinary $ceiling refuses $action before lookup"
  done
done
for purpose in '' frontend-read wrong frontend-check; do
  C_ENV="OMB_SESSION_PURPOSE=$purpose" c_run hello
  assert_eq "$(c_result) $C_RC" 'error environment 2' "fixture purpose '$purpose' refused"
done
C_ENV=OMB_SESSION_INTENT=wrong c_run hello
assert_eq "$(c_result) $C_RC" 'error environment 2' 'malformed intent refused'
C_ENV=OMB_SESSION_SCOPES=disk c_run snapshot "scope	name=journey"
assert_eq "$(c_result)" 'refused scope' 'wrong scope refused'
c_uname_arm "$T/native"
C_PATH="$T/native:/usr/bin:/bin:/usr/sbin:/sbin" C_ENV='OMB_FIXTURE= OMB_FRONTEND_DEV=' c_run snapshot "scope	name=journey"
assert_eq "$(c_result)" 'refused unavailable' 'production read unavailable'
c_run hello "arg	name=future	value=x"
assert_eq "$C_RC" 2 'unknown request content refused'
c_run future
assert_eq "$C_RC" 2 'future operation refused by entrypoint'
assert_eq "$(t_snapshot "$T/state")" "$before" 'no state, log, plan or operation record written'
assert_eq "$(find "$SESS" -name '*.core' -o -name '*.worker-*')" '' 'no worker or core identity residue'
assert_eq "$(sed -n '/^core_read_op()/,/^}/p' "$REPO/lib/core.sh" | grep -Ec 'core_op_execute|core_action_info|sudo|fetch_upstream|run ')" 0 'read dispatcher reaches no action, installer, sudo or fetch'

# HEALTH-H01: core_read_rows succeeds only after every retained row was read
# and staged for admission. The real helper loop meets a real builtin read
# failure (stdin closed at read call FAIL_AT), not a substituted helper.
C_FIX=$FIX/linux-alarm-fresh
c_run hello
hello=$(sed -n 2p "$C_EV")
# r_rows ROWS FAIL_AT [tail] — "status staged-rows" of core_read_rows.
r_rows() {
  local rows=$1 fail_at=$2 tail=${3:-}
  : >"$T/staged"; : >"$T/hit"
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    # shellcheck source=lib/core.sh
    . "$REPO/lib/core.sh"
    # shellcheck source=lib/read.sh
    . "$REPO/lib/read.sh"
    omb_tmp_init
    printf 'omb-res 1\n%s\n' "$hello" >"$OMB_TMP/journey.prefix"
    i=0
    while [ "$i" -lt "$rows" ]; do
      i=$((i + 1))
      rec_line row kind status key "$i" col Section col Label col value col ''
    done >"$OMB_TMP/rows"
    if [ "$tail" = tail ]; then printf 'row\tkind=status\tkey=tail' >>"$OMB_TMP/rows"; fi
    eval "$(declare -f core_read_stage | sed '1s/core_read_stage/r_stage_original/')"
    core_read_stage() { grep '^row	' "$4" >>"$T/staged"; r_stage_original "$@"; }
    r_reads=0
    read() {
      if [ "${FUNCNAME[1]:-}" = core_read_rows ]; then
        r_reads=$((r_reads + 1))
        if [ "$r_reads" = "$fail_at" ]; then
          printf hit >"$T/hit"
          exec 0<&-
        fi
      fi
      builtin read "$@"
    }
    core_read_rows "$OMB_TMP/rows" "$(printf '%064d' 0)"
    st=$?
    printf '%s %s\n' "$st" "$(wc -l <"$T/staged" | tr -d ' ')"
    omb_cleanup
  ) 2>"$T/rows.err"
}
for case in 'normal-0 0 0 0 0' 'normal-2 2 0 0 2' 'normal-500 500 0 0 500' 'normal-501 501 0 0 501' \
  'fail-before-row-1 2 1 1 0' 'fail-after-row-1 2 2 1 0' 'fail-after-batch-500 600 501 1 500'; do
  set -- $case
  assert_eq "$(r_rows "$2" "$3")" "$4 $5" "core_read_rows $1"
  if [ "$3" = 0 ]; then
    assert_empty_file "$T/hit" "$1 reads normally"
    assert_empty_file "$T/rows.err" "$1 clean stderr"
  else
    assert_eq "$(cat "$T/hit")" hit "$1 the failing read is inside core_read_rows"
    assert_contains "$(cat "$T/rows.err")" 'Bad file descriptor' "$1 is a real non-EOF read failure"
  fi
done
assert_eq "$(r_rows 2 0 tail)" '1 0' 'core_read_rows rejects an unterminated retained tail'
t_done test-gate2-read
