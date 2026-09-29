#!/usr/bin/env bash
# Accepted baseline vs current text sinks vs typed dataset, over all baseline
# machine fixtures. Read-effect proof uses the existing snapshot/shim harness.
# shellcheck disable=SC2030,SC2031
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-journey
T=$(t_tmp)
BASELINE=2edb76a7de3f78ec90927ac93d5eec3a84636253
mkdir -p "$T/base" "$T/home" "$T/tmp"
git -C "$REPO" archive "$BASELINE" | tar -x -C "$T/base" || exit 1
shims=$(t_shims "$T")
mac=0
t_plutil 'Gate 2 journey equivalence' && mac=1
c_session
for fixture in "$T/base/tests/fixtures/"*; do
  [ -d "$fixture/cmd" ] || continue
  case "$(cat "$fixture/cmd/uname_s" 2>/dev/null)" in
    Darwin) [ "$mac" = 1 ] || continue ;;
    Linux) ;;
    *) continue ;;
  esac
  name=${fixture##*/}
  before=$(t_snapshot "$fixture")
  for mode in base text dataset; do
    tree=$REPO
    [ "$mode" != base ] || tree=$T/base
    env -i PATH="$shims:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T/home" TMPDIR="$T/tmp" \
      LANG=en_US.UTF-8 TERM=dumb OMB_STATE_DIR="$T/state" OMB_FIXTURE="$fixture" \
      OMB_TEST_RECORD="$T/record" SHIM_LOG="$T/shims.log" G2_CANDIDATE="$REPO" G2_PROBES="$T/$mode.probes" \
      "$T_BASH" "$TESTS_DIR/gate2-oracle.sh" "$tree" "$mode" >"$T/$mode.out" 2>"$T/$mode.err"
    assert_rc "$?" 0 "$name $mode read succeeds"
    assert_empty_file "$T/$mode.err" "$name $mode clean stderr"
  done
  awk -F '\t' '$1 == "guide" || $1 == "code" || ($1 == "row" && $2 == "kind=status")' "$T/dataset.out" >"$T/surface"
  assert_eq "$(cat "$T/text.out")" "$(cat "$T/base.out")" "$name current text equals independent baseline"
  assert_eq "$(cat "$T/surface")" "$(cat "$T/base.out")" "$name typed status and token equal baseline"
  machine=$(awk -F '\t' '$1 == "row" && $2 == "kind=machine"' "$T/dataset.out")
  assert_eq "$machine" "$(cat "$T/base.probes.machine")" "$name identity equals baseline detector values"
  assert_eq "$(cat "$T/dataset.probes")" "$(cat "$T/base.probes")" "$name dataset uses exactly baseline status probes"
  assert_eq "$(t_snapshot "$fixture")" "$before" "$name fixture unchanged"
  assert_eq "$(t_snapshot "$T/state")" '(absent)' "$name no state/log/plan/profile/operation"
  assert_empty_file "$T/record" "$name no action recorded"
  assert_empty_file "$T/shims.log" "$name no sudo/installer/fetch/package/boot mutation"
  assert_eq "$(ls -A "$T/tmp")" '' "$name no temporary residue"
  C_FIX=$fixture
  C_PATH="$shims:/usr/bin:/bin:/usr/sbin:/sbin" C_ENV="OMB_TEST_RECORD=$T/record SHIM_LOG=$T/shims.log" c_run snapshot "scope	name=journey"
  arch=$(cat "$fixture/cmd/uname_m" 2>/dev/null)
  if [ "$arch" != arm64 ] && [ "$arch" != aarch64 ]; then
    assert_rc "$C_RC" 2 "$name outside existing Protocol-1 ARM architecture schema"
  else
    assert_eq "$(c_result) $C_RC" 'done ok 0' "$name actual core snapshot succeeds"
    assert_eq "$C_ERR" '' "$name entrypoint stderr empty"
    assert_eq "$(c_admits snapshot)" ok "$name snapshot admitted"
    awk -F '\t' '$1 != "scope" && $1 != "row"' "$T/dataset.out" >"$T/body"
    assert_eq "$(sed '1,3d;$d' "$C_EV")" "$(cat "$T/body")" "$name actual snapshot equals dataset projection"
    if [ "$name" = linux-alarm-fresh ]; then
      assert_eq "$(cat "$T/body")" "$(cat "$TESTS_DIR/gate2/linux-alarm-fresh.snapshot")" 'settled producer golden'
    fi
    gen=$(printf '%s\n' "$C_OUT" | sed -n 's/^generation	id=\([^	]*\).*/\1/p')
    for kind in machine status; do
      C_PATH="$shims:/usr/bin:/bin:/usr/sbin:/sbin" C_ENV="OMB_TEST_RECORD=$T/record SHIM_LOG=$T/shims.log" \
        c_run detail "page	scope=journey	kind=$kind	generation=$gen	offset=0	limit=500"
      assert_eq "$(c_result) $C_RC" 'done ok 0' "$name $kind detail succeeds"
      assert_eq "$(c_admits detail)" ok "$name $kind detail admitted"
      assert_eq "$C_ERR" '' "$name $kind detail clean stderr"
      if [ "$kind" = machine ]; then
        want=$(cat "$T/base.probes.machine")
      else
        want=$(grep '^row	' "$T/base.out")
      fi
      assert_eq "$(printf '%s\n' "$C_OUT" | grep '^row	')" "$want" "$name $kind page equals accepted baseline projection"
      assert_contains "$C_OUT" "generation	id=$gen" "$name $kind shares snapshot generation"
    done
  fi
  assert_eq "$(t_snapshot "$T/state")" '(absent)' "$name actual snapshot persists nothing"
  assert_eq "$(t_snapshot "$fixture")" "$before" "$name actual snapshot leaves machine unchanged"
  assert_empty_file "$T/shims.log" "$name actual snapshot executes no forbidden command"
  assert_empty_file "$T/record" "$name actual snapshot records no action"
  assert_eq "$(find "$T" -maxdepth 1 -name 'omarchy-bootstrap.*')" '' "$name request scratch cleaned"
  : >"$T/base.probes"; : >"$T/text.probes"; : >"$T/dataset.probes"
done
# Saved choices: the token is compared independently to the baseline's
# command text, including its exact conditional presence.
if [ "$mac" = 1 ]; then
  mkdir -p "$T/state"
  for choices in 'cfg_host=solo' 'cfg_user=alex' 'cfg_user=alex cfg_host=omarchy cfg_enc=0'; do
    # shellcheck disable=SC2086 # fixed synthetic key=value test values
    printf '%s\n' $choices >"$T/state/state.env"
    saved=$(t_snapshot "$T/state")
    for mode in base text dataset; do
      tree=$REPO
      [ "$mode" != base ] || tree=$T/base
      env -i PATH="$shims:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T/home" TMPDIR="$T/tmp" \
        LANG=en_US.UTF-8 TERM=dumb OMB_STATE_DIR="$T/state" OMB_FIXTURE="$FIX/mac-m1pro-1tb-roomy" \
        SHIM_LOG="$T/shims.log" G2_CANDIDATE="$REPO" G2_PROBES="$T/$mode.probes" \
        "$T_BASH" "$TESTS_DIR/gate2-oracle.sh" "$tree" "$mode" >"$T/$mode.out" 2>"$T/$mode.err"
      assert_rc "$?" 0 "saved choices $mode succeeds"
      assert_empty_file "$T/$mode.err" "saved choices $mode stderr"
    done
    awk -F '\t' '$1 == "guide" || $1 == "code" || ($1 == "row" && $2 == "kind=status")' "$T/dataset.out" >"$T/surface"
    assert_eq "$(cat "$T/surface")" "$(cat "$T/base.out")" 'saved status and typed token equal accepted baseline'
    assert_eq "$(cat "$T/text.out")" "$(cat "$T/base.out")" 'saved current text equals accepted baseline'
    assert_eq "$(t_snapshot "$T/state")" "$saved" 'saved choices not rewritten'
    C_FIX=$FIX/mac-m1pro-1tb-roomy c_run snapshot "scope	name=journey"
    assert_eq "$(c_admits snapshot)" ok 'conditional token snapshot admitted'
  done
fi
# Drive the actual entrypoint to catch set -u and response-admission failures.
c_session
for C_FIX in "$FIX/linux-alarm-fresh" "$FIX/linux-omarchy-installed"; do
  c_run snapshot "scope	name=journey"
  assert_eq "$(c_result) $C_RC" 'done ok 0' 'ordinary journey snapshot succeeds'
  assert_eq "$(c_admits snapshot)" ok 'snapshot schema valid'
  assert_eq "$C_ERR" '' 'snapshot stderr empty'
  assert_eq "$(printf '%s\n' "$C_OUT" | grep -Ec '^(stage|action|param)	')" 0 'no stage or action authority'
  assert_contains "$C_OUT" 'key=machine.arch' 'typed machine identity exists'
done
t_done test-gate2-journey
