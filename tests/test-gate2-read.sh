#!/usr/bin/env bash
# Ordinary Gate 2 authority; the existing core harness and filesystem oracle.
# shellcheck disable=SC2030,SC2031 # test environments intentionally scoped
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
t_done test-gate2-read
