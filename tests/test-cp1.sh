#!/usr/bin/env bash
# CP1 compatibility, with S4's authorized fixture-only Logs producer.
# shellcheck disable=SC2030,SC2031 # intentionally scoped core environments
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-cp1
T=$(t_tmp)
c_session
C_FIX=$FIX/linux-alarm-fresh
zero=$(printf '%064d' 0)
mkdir "$T/tool" "$T/closeout"
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$REPO/release" "$T/tool/"
git -C "$REPO" archive deaa62c62348ecd4274b74b6b3a00f506c9f243d | tar -x -C "$T/closeout" || exit 1
printf '\n. %q\n' "$TESTS_DIR/gate2-probe-taps.sh" >>"$T/tool/lib/common.sh"
cat >>"$T/tool/lib/core.sh" <<'TAPS'
eval "$(declare -f core_action_info | sed '1s/core_action_info/cp1_original_action_info/')"
core_action_info() { printf 'lookup\n' >>"$CP1_LOOKUPS"; cp1_original_action_info "$@"; }
cmd_doctor() { printf 'doctor\n' >>"$CP1_OWNERS"; return 99; }
cmd_logs() { printf 'logs\n' >>"$CP1_OWNERS"; return 99; }
TAPS
cat >>"$T/tool/lib/logs.sh" <<'TAPS'
eval "$(declare -f core_logs_capture | sed '1s/core_logs_capture/cp1_original_logs_capture/')"
core_logs_capture() {
  printf 'logs %s %s\n' "$OMB_INTENT" "$OMB_PERSIST" >>"$CP1_OWNERS"
  cp1_original_logs_capture "$@"
}
TAPS
C_HOME=$T/tool
c_uname_arm "$T/native"
C_PATH=$T/native:/usr/bin:/bin:/usr/sbin:/sbin
before=$(t_snapshot "$T/state")

held() {
  # Match the existing identity/state/boot setup exactly, with no added probe.
  if cmp -s "$T/probes" "$T/hello.probes"; then ok; else fail "$1: probes differ from existing hello setup"; fi
  assert_eq "$(cat "$T/owners")" "${2:-}" "$1: only authorized producer, read intent, zero persistence"
  assert_empty_file "$T/lookups" "$1: no action lookup"
  assert_eq "$(t_snapshot "$T/state")" "$before" "$1: no state/log/lock/operation/effect"
  assert_eq "$(find "$SESS" -name '*.core' -o -name '*.worker-*')" '' "$1: no child residue"
  assert_eq "$(grep -c '^action	' "$C_EV")" 0 "$1: no advertised action"
  assert_eq "$C_ERR" '' "$1: clean stderr"
}

hello_probes() {
  : >"$T/probes"; : >"$T/lookups"; : >"$T/owners"
  C_ENV="$1" c_run hello
  assert_eq "$(c_result) $C_RC" 'done ok 0' 'session scopes admitted by actual core hello'
  cp "$T/probes" "$T/hello.probes"
  : >"$T/probes"; : >"$T/lookups"; : >"$T/owners"
}

for scope in health logs; do
  kind=doctor
  [ "$scope" = logs ] && kind=log
  for fixture in yes no; do
    fixture_env=""
    [ "$fixture" = no ] && fixture_env='OMB_FIXTURE= OMB_FRONTEND_DEV='
    for scopes in "$scope" journey journey,health,logs; do
      expected='refused unavailable'
      [ "$scopes" = journey ] && expected='refused scope'
      for op in snapshot detail; do
        owner=''
        if [ "$scope:$fixture" = logs:yes ] && [ "$scopes" != journey ]; then
          owner='logs read 0'
          expected='done ok'
          [ "$op" != detail ] || expected='refused changed'
        fi
        request_env="OMB_SESSION_SCOPES=$scopes $fixture_env G2_PROBES=$T/probes CP1_LOOKUPS=$T/lookups CP1_OWNERS=$T/owners"
        hello_probes "$request_env"
        record="scope	name=$scope"
        [ "$op" = detail ] && record="page	scope=$scope	kind=$kind	generation=$zero	offset=0	limit=1"
        C_ENV="$request_env" c_run "$op" "$record"
        assert_eq "$(c_result) $C_RC" "$expected 0" "$op/$scope/$scopes/$fixture"
        assert_eq "$(c_admits "$op")" ok 'new-scope response canonically admitted'
        held "$op/$scope/$scopes/$fixture" "$owner"
      done
    done
  done
  request_env="OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_SESSION_INTENT=read OMB_SESSION_PURPOSE=frontend-check G2_PROBES=$T/probes CP1_LOOKUPS=$T/lookups CP1_OWNERS=$T/owners"
  hello_probes "$request_env"
  C_ENV="$request_env" c_run snapshot "scope	name=$scope"
  assert_eq "$(c_result) $C_RC" 'refused scope 0' 'startup-check scope isolation'
  assert_eq "$(c_admits snapshot)" ok 'startup-check new-scope refusal admitted'
  held "startup-check/$scope"
  for op in snapshot detail; do
    record="scope	name=$scope"
    [ "$op" = detail ] && record="page	scope=$scope	kind=$kind	generation=$zero	offset=0	limit=1"
    C_HOME=$T/closeout c_run "$op" "$record"
    assert_eq "$(c_result) $C_RC" 'error type 2' 'new request against actual old core fails closed without fallback'
  done
done

# S4's kind check also precedes capture. Startup-check routing is unchanged.
request_env="OMB_SESSION_SCOPES=logs G2_PROBES=$T/probes CP1_LOOKUPS=$T/lookups CP1_OWNERS=$T/owners"
hello_probes "$request_env"
C_ENV="$request_env" c_run detail "page	scope=logs	kind=future	generation=$zero	offset=0	limit=1"
assert_eq "$(c_result) $C_RC" 'refused unavailable 0' 'S4 unsupported kind before capture'
held unsupported-logs-kind

# Even explicitly owned fake actions are journey-scoped, not new-scope actions.
C_HOME=$REPO
c_fixture
for scopes in health logs health,logs; do
  for action in test.read test.mutate test.handoff; do
    C_ENV="OMB_SESSION_SCOPES=$scopes" c_run execute "exec	action=$action	basis=$zero	confirm=test"
    assert_eq "$(c_result) $C_RC" 'refused scope 0' 'foundation action remains journey-scoped'
    assert_eq "$(c_admits execute)" ok 'foundation scope refusal admitted'
    assert_eq "$(t_snapshot "$T/state")" "$before" 'new scopes confer no fake action persistence'
  done
done
c_session

# Save actual CP1 responses for execution by S's frozen Rust parser, when asked.
save=${1:-}
if [ -n "$save" ]; then : >"$save/cases"; fi
normalized() {
  awk -F '\t' 'BEGIN {OFS="\t"} $1=="hello" {for(i=2;i<=NF;i++) if($i~/^(commit|source)=/) sub(/=.*/,"=",$i)} {print}' "$1"
}
compare() {
  local name=$1 op=$2
  shift 2
  c_run "$op" "$@"
  assert_eq "$(c_result) $C_RC" 'done ok 0' "$name: current response"
  assert_eq "$(c_admits "$op")" ok "$name: current admission"
  cp "$C_EV" "$T/current"
  if [ -n "$save" ]; then
    cp "$C_EV" "$save/$name.doc"
    printf '%s %s\n' "$name" "$op" >>"$save/cases"
  fi
  C_HOME=$T/closeout C_ENV="${C_ENV:-} OMB_SESSION_SCOPES=journey" c_run "$op" "$@"
  assert_eq "$(c_result) $C_RC" 'done ok 0' "$name: accepted C response"
  normalized "$T/current" >"$T/current.normalized"
  normalized "$C_EV" >"$T/old.normalized"
  if cmp -s "$T/current.normalized" "$T/old.normalized"; then ok; else fail "$name: changed beyond hello commit/source"; fi
}
C_FIX=$FIX/linux-alarm-fresh
compare hello hello
fixtures='linux-alarm-fresh linux-omarchy-installed'
if t_plutil 'CP1 old macOS journey responses'; then fixtures="$fixtures mac-m1pro-1tb-roomy"; fi
for fx in $fixtures; do
  C_FIX=$FIX/$fx
  C_ENV=OMB_SESSION_SCOPES=journey,health,logs compare "$fx.snapshot" snapshot "scope	name=journey"
  gen=$(sed -n 's/^generation	id=\([^	]*\).*/\1/p' "$T/current")
  for kind in machine status; do
    C_ENV=OMB_SESSION_SCOPES=journey,health,logs compare "$fx.$kind" detail "page	scope=journey	kind=$kind	generation=$gen	offset=0	limit=500"
  done
done
C_ENV='OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_SESSION_INTENT=read OMB_SESSION_PURPOSE=frontend-check' compare startup-check snapshot "scope	name=journey"
assert_eq "$(grep -c '^fact	' "$T/current")" 4 'startup-check retains four facts'
assert_eq "$(grep -Ec '^(action|code)	' "$T/current")" 0 'startup-check has no action/token'
t_done test-cp1
