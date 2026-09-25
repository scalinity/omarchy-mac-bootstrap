#!/usr/bin/env bash
# Command intent before machine state: read-only commands, previews and plan
# never reach an action, whatever the machine looks like, and leave nothing
# behind — checked by snapshotting the filesystem around each run.
# shellcheck disable=SC2015,SC2016 # ok/fail always return 0; literal $ in single quotes
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-routing"

# Variants for lifecycle states the base fixtures do not cover.
fx_active=$(t_variant linux-setup-in-progress)
printf 'activating\n' >"$fx_active/cmd/unit_active"
rm -f "$fx_active/cmd/unit_active.rc"
fx_partial=$(t_variant linux-alarm-fresh)
mkdir -p "$fx_partial/root/usr/share/omarchy"
printf '4.0.3rc4\n' >"$fx_partial/root/usr/share/omarchy/version"

LINUX_STATES="linux-alarm-fresh linux-alarm-offline linux-setup-in-progress $fx_active $fx_partial linux-omarchy-installed"
MAC_STATES=""
command -v plutil >/dev/null 2>&1 && MAC_STATES="mac-m1pro-1tb-roomy mac-m1pro-1tb-tight mac-asahi-installed mac-m1-free-space"

_fx_path() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$FIX" "$1" ;; esac; }
_name() { basename "$1"; }

# expect_pure LABEL FIXTURE — after the last t_cli: nothing executed, nothing
# recorded, no state directory, an empty scratch area, fixture unchanged.
expect_pure() {
  assert_empty_file "$T_DIR/record" "$1: nothing recorded"
  assert_empty_file "$T_DIR/shims.log" "$1: no forbidden command"
  assert_eq "$(ls -A "$T_DIR/state" 2>/dev/null)" "" "$1: no state, log or download kept"
  assert_eq "$(ls -A "$T_DIR/tmp")" "" "$1: scratch files removed at exit"
  assert_eq "$(t_snapshot "$(_fx_path "$2")")" "$3" "$1: the fixture machine is unchanged"
}

# --- Help and version touch nothing ---------------------------------------------
for args in --help --version "--help --dry-run"; do
  before=$(t_snapshot "$FIX/linux-alarm-fresh")
  # shellcheck disable=SC2086 # args is a flag list
  t_cli linux-alarm-fresh "" $args
  expect_pure "$args" linux-alarm-fresh "$before"
done

# --- Read-only commands, in every lifecycle state ----------------------------------
for fx in $LINUX_STATES $MAC_STATES; do
  for cmd in status doctor sources logs; do
    before=$(t_snapshot "$(_fx_path "$fx")")
    t_cli "$fx" 'resume\nstart\nyes\nlaunch\ny\n' "$cmd"
    expect_pure "$cmd on $(_name "$fx")" "$fx" "$before"
    assert_not_contains "$T_OUT" "would run" "$cmd on $(_name "$fx"): no action previewed"
  done
done

# --- Dry runs keep nothing, in every lifecycle state ---------------------------------
for fx in $LINUX_STATES; do
  before=$(t_snapshot "$(_fx_path "$fx")")
  t_cli "$fx" '\n\nstart\nresume\nq\n' resume 'omb1:enc=1,user=alex,host=omarchy,kmap=us' --dry-run
  expect_pure "resume --dry-run on $(_name "$fx")" "$fx" "$before"
done
for fx in $MAC_STATES; do
  before=$(t_snapshot "$(_fx_path "$fx")")
  t_cli "$fx" '\n\n\n\n\n\n\n\n\n\n\n\n\nyes\n\nlaunch\n' --dry-run
  expect_pure "--dry-run on $(_name "$fx")" "$fx" "$before"
done

# --- plan never reaches an action, in every lifecycle state ----------------------------
# The answers offered would continue a resume, start setup or open the
# developer menu if plan were ever routed there.
for fx in $LINUX_STATES; do
  t_cli "$fx" 'resume\nstart\ny\n1 2 3 4 5 6 7 8 9\n' plan
  n=$(_name "$fx")
  assert_empty_file "$T_DIR/record" "plan on $n: nothing recorded"
  assert_empty_file "$T_DIR/shims.log" "plan on $n: no forbidden command"
  assert_not_contains "$T_OUT" "would run" "plan on $n: no action previewed"
  assert_not_contains "$T_OUT" "Type resume" "plan on $n: never offers to resume setup"
  assert_not_contains "$T_OUT" "Type start" "plan on $n: never offers to start setup"
  assert_not_contains "$T_OUT" "Choose what to set up" "plan on $n: never opens the developer menu"
  assert_not_contains "$T_OUT" "Refused:" "plan on $n: routing never reaches run at all"
done
t_cli "$fx_active" '' plan
assert_contains "$T_OUT" "plan changes nothing now" "plan while setup runs explains itself"
t_cli linux-omarchy-installed '' plan
assert_contains "$T_OUT" "nothing left to plan" "plan on an installed machine explains itself"
for fx in linux-alarm-fresh $MAC_STATES; do
  before=$(t_snapshot "$(_fx_path "$fx")")
  t_cli "$fx" '\nalex\nm1pro\n\n\n\n\n\n\n\n\n\n\n\n' plan --dry-run
  expect_pure "plan --dry-run on $(_name "$fx")" "$fx" "$before"
done

# --- The guard itself: run and downloads refuse outside an action command ---------------
t_load
OMB_STATE_DIR=$(t_tmp)
state_init
unset OMB_TEST_RECORD OMB_FIXTURE
probe() { : >"$OMB_STATE_DIR/probe-ran"; }
for intent in read plan; do
  OMB_INTENT=$intent OMB_CMD=$intent
  out=$(run probe 2>&1)
  assert_rc $? 1 "run refuses under $intent intent"
  assert_contains "$out" "never changes the machine" "the refusal says why ($intent)"
  [ ! -e "$OMB_STATE_DIR/probe-ran" ] && ok || fail "a $intent command executed through run"
  fetch_upstream probe-download https://example.invalid/x
  assert_rc $? 1 "downloads refuse under $intent intent"
done
OMB_INTENT=act

t_done test-routing
