#!/usr/bin/env bash
# Fixture data cannot select the foundation execution contract.
# shellcheck disable=SC2030,SC2031 # deliberately scoped request environments
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-foundation
T=$(t_tmp)
c_session
C_FIX=$(t_variant linux-alarm-fresh)
before=$(t_snapshot "$T/state")
zero=$(printf '%064d' 0)

# Linux makes the ordinary path observable on every runner: its machine rows
# and guide never appear in a foundation snapshot.
ordinary() {
  c_run snapshot "scope	name=journey"
  assert_eq "$(c_result) $C_RC" 'done ok 0' "$1: ordinary snapshot"
  assert_contains "$C_OUT" "key=machine.platform" "$1: ordinary dataset"
  assert_not_contains "$C_OUT" $'action\t' "$1: no foundation actions"
  assert_eq "$(c_admits snapshot)" ok "$1: admitted snapshot"
}
unavailable() {
  local ceiling action
  for ceiling in read plan act; do
    for action in test.read test.mutate test.handoff; do
      C_ENV="${FOUNDATION_ENV:-} OMB_SESSION_INTENT=$ceiling" c_run execute "exec	action=$action	basis=$zero	confirm=test"
      assert_eq "$(c_result) $C_RC" 'refused unavailable 0' "$1/$ceiling/$action: refused before lookup"
      assert_eq "$(c_admits execute)" ok "$1/$ceiling/$action: admitted refusal"
    done
  done
  assert_eq "$(t_snapshot "$T/state")" "$before" "$1: no lock, operation or effect"
  assert_eq "$(find "$SESS" -name '*.core' -o -name '*.worker-*')" '' "$1: no fake children"
}
ordinary absent
mkdir "$C_FIX/test-children"
ordinary real-directory
unavailable real-directory
rmdir "$C_FIX/test-children"
mkdir "$T/children"
ln -s "$T/children" "$C_FIX/test-children"
ordinary symlink
unavailable symlink
FOUNDATION_ENV=OMB_TEST_FOUNDATION=1 unavailable explicit-symlink
rm "$C_FIX/test-children"
FOUNDATION_ENV=OMB_TEST_FOUNDATION=1 unavailable explicit-absent
printf unusable >"$C_FIX/test-children"
FOUNDATION_ENV=OMB_TEST_FOUNDATION=1 unavailable explicit-file
rm "$C_FIX/test-children"
mkdir "$C_FIX/test-children"
FOUNDATION_ENV=OMB_TEST_FOUNDATION=2 unavailable wrong-seam-value
c_uname_arm "$T/native"
C_PATH="$T/native:/usr/bin:/bin:/usr/sbin:/sbin" FOUNDATION_ENV='OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_TEST_FOUNDATION=1' unavailable non-fixture
C_PATH="$T/native:/usr/bin:/bin:/usr/sbin:/sbin" C_ENV='OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_TEST_FOUNDATION=1' c_run snapshot "scope	name=journey"
assert_eq "$(c_result)" 'refused unavailable' 'non-fixture read unavailable'
C_PATH="$T/native:/usr/bin:/bin:/usr/sbin:/sbin" C_ENV='OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_TEST_FOUNDATION=1 OMB_SESSION_INTENT=read OMB_SESSION_PURPOSE=frontend-check' c_run hello
assert_eq "$(c_result) $C_RC" 'error environment 2' 'frontend-check rejects explicit foundation seam'

c_fixture
c_exec test.read ''
assert_eq "$(c_result) $C_RC" 'done ok 0' 'owned explicit foundation retains read action'
assert_eq "$(c_admits execute)" ok 'foundation action response admitted'
c_session
assert_eq "$C_FOUNDATION" 0 'fresh session resets foundation authority'
if t_plutil 'foundation reset'; then ordinary reset; fi
t_done test-gate2-foundation
