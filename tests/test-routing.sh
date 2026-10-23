#!/usr/bin/env bash
# Command intent before machine state: read-only commands, previews and plan
# never reach an action, whatever the machine looks like, and leave nothing
# behind — checked by snapshotting the filesystem around each run.
# shellcheck disable=SC2015,SC2016 # ok/fail always return 0; literal $ in single quotes
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-routing"

# Every lifecycle state the fixtures describe, on both systems.
LINUX_STATES="linux-alarm-fresh linux-alarm-offline linux-setup-in-progress linux-setup-active linux-omarchy-partial
linux-encrypt-staged linux-encrypt-reencrypting linux-omarchy-finishing linux-omarchy-installed
linux-shared-absent linux-shared-present linux-shared-ready linux-shared-conflict linux-shared-wrong-fs linux-shared-uid1001"
MAC_STATES=""
t_plutil "macOS states in the purity matrix" && MAC_STATES="mac-m1pro-1tb-roomy mac-m1pro-1tb-tight mac-m1-free-space mac-geo-two-gaps
mac-asahi-resized-only mac-asahi-stub-only mac-asahi-no-root mac-asahi-pending mac-asahi-installed mac-asahi-complete mac-asahi-two-stubs
mac-geo-512-sectors mac-geo-multi-apfs mac-geo-no-limits mac-geo-missing-offset mac-geo-disagree mac-shared-reserved mac-shared-created"

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
  for cmd in status doctor sources logs shared; do
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
t_cli linux-setup-active '' plan
assert_contains "$T_OUT" "plan changes nothing now" "plan while setup runs explains itself"
t_cli linux-omarchy-installed '' plan
assert_contains "$T_OUT" "nothing left to plan" "plan on an installed machine explains itself"
for fx in linux-alarm-fresh $MAC_STATES; do
  before=$(t_snapshot "$(_fx_path "$fx")")
  t_cli "$fx" '\nalex\nm1pro\n\n\n\n\n\n\n\n\n\n\n\n' plan --dry-run
  expect_pure "plan --dry-run on $(_name "$fx")" "$fx" "$before"
done

# --- Phase B command and scope routes ------------------------------------------
restore_dir=$(t_tmp)/"bundle folders"
mkdir -p "$restore_dir"
for arg in '' "$restore_dir" status undo; do
  if [ -n "$arg" ]; then
    t_cli linux-omarchy-installed '' restore "$arg"
  else
    t_cli linux-omarchy-installed '' restore
  fi
  assert_rc "$T_RC" 1 "restore $arg reaches the implementation and checks the home"
  assert_contains "$(t_flat "$T_OUT")" "The home is not a real folder owned by this user." "restore $arg reports the home refusal"
  assert_empty_file "$T_DIR/record" "restore $arg runs nothing"
  if [ "$arg" = status ]; then
    assert_eq "$(t_snapshot "$T_DIR/state")" '(absent)' 'restore status is read-only'
  fi
done
for arg in relative "$restore_dir/missing" "$restore_dir/../file" ''; do
  t_cli linux-omarchy-installed '' restore "$arg"
  assert_rc "$T_RC" 2 "restore refuses an invalid DIR ($arg)"
  assert_contains "$T_OUT" 'absolute path to an existing folder' 'restore explains the DIR requirement'
  assert_eq "$(t_snapshot "$T_DIR/state")" '(absent)' 'invalid restore DIR creates no state'
done
t_cli linux-omarchy-installed '' restore status extra
assert_rc "$T_RC" 2 'restore refuses a second argument'
t_cli linux-omarchy-installed '' debug extra
assert_rc "$T_RC" 2 'debug takes no argument'
if t_plutil 'restore and debug command routing on macOS'; then
  for arg in '' "$restore_dir" status undo; do
    if [ -n "$arg" ]; then
      t_cli mac-m1pro-1tb-roomy '' restore "$arg"
    else
      t_cli mac-m1pro-1tb-roomy '' restore
    fi
    assert_rc "$T_RC" 1 "restore $arg refuses macOS"
    assert_contains "$(t_flat "$T_OUT")" 'restore runs on the Linux system, after Omarchy is installed.' 'restore names its system'
    assert_empty_file "$T_DIR/record" 'restore on macOS runs nothing'
  done
  mac_debug=mac-m1pro-1tb-roomy
else
  mac_debug=""
fi
for fx in linux-omarchy-installed $mac_debug; do
  before=$(t_snapshot "$FIX/$fx")
  t_cli "$fx" '' debug
  assert_rc "$T_RC" 0 "debug on $fx reaches the implementation"
  assert_contains "$(t_flat "$T_OUT")" '# Brief: omarchy-mac-bootstrap' "debug on $fx prints the fixed brief"
  expect_pure "debug on $fx" "$fx" "$before"
done

# Both restore and undo respect the restore operation barrier; status reads
# through it without changing the record or creating a log.
bar_state=$(t_tmp)
mkdir -p "$bar_state/ops"
printf 'unreadable\n' >"$bar_state/ops/restore.omb"
for arg in "$restore_dir" undo; do
  T_ENV="OMB_STATE_DIR=$bar_state" t_cli linux-omarchy-installed '' restore "$arg"
  assert_rc "$T_RC" 1 'restore action is barred by its operation record'
  assert_not_contains "$T_OUT" 'The home is not a real folder owned by this user.' 'the operation barrier runs before restore'
done
before=$(t_snapshot "$bar_state")
T_ENV="OMB_STATE_DIR=$bar_state" t_cli linux-omarchy-installed '' restore status
assert_contains "$(t_flat "$T_OUT")" 'The home is not a real folder owned by this user.' 'restore status reads through the barrier and checks the home'
assert_eq "$(t_snapshot "$bar_state")" "$before" 'restore status changes no state or log'

T=$(t_tmp)
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
c_session
C_FIX=$FIX/linux-omarchy-installed
C_ENV='OMB_SESSION_SCOPES=restore,debug'
for scope in restore debug; do
  c_run snapshot "scope	name=$scope"
  assert_eq "$(c_answered snapshot 'done ok')" '' "$scope snapshot is admitted"
  case "$scope" in
    restore) assert_contains "$C_OUT" 'key=restore.state	label=Restore	value=blocked' 'restore snapshot exposes its home blocker' ;;
    debug) assert_contains "$C_OUT" 'generation	id=' 'debug snapshot exposes a generation' ;;
  esac
  c_run detail "page	scope=$scope	kind=brief	generation=$(printf '%064d' 0)	offset=0	limit=10"
  if [ "$scope" = restore ]; then
    assert_eq "$(c_answered detail 'refused unavailable')" '' 'restore refuses an unsupported detail kind'
  else
    assert_eq "$(c_answered detail 'refused changed')" '' 'debug requires the current generation'
  fi
  C_ENV='OMB_SESSION_SCOPES=journey' c_run snapshot "scope	name=$scope"
  assert_eq "$(c_answered snapshot 'refused scope')" '' "$scope admission is checked before loading its producer"
done
c_run validate 'select	action=restore.apply'
assert_eq "$(c_answered validate 'refused invalid')" '' 'restore validation refusal is admitted'
assert_contains "$C_OUT" 'invalid	name=bundle	code=invalid' 'restore validation requires a checked bundle'

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
