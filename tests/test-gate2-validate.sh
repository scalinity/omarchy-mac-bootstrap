#!/usr/bin/env bash
# Gate 2 Validate: the ordinary fixture-only plan validation producer
# (docs/PROTOCOL.md → *Future plan validation contract*). Routing and refusal
# precedence, the finite invalid vocabulary with its fixed texts, Shared-first
# evaluation, whole-GB normalization, the planner's exact answers, unplannable
# machines, Q4-plan-validation-basis-v1 equivalences and read purity.
# shellcheck disable=SC2030,SC2031 # intentionally scoped core environments
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-validate
T=$(t_tmp)
c_session
zero=$(printf '%064d' 0)
GB=1000000000
mkdir "$T/tool"
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$REPO/release" "$T/tool/"
# Test-only taps in a copied tool. Every planning capture is counted with the
# intent it ran under; effects a read must never reach are recorded and refused.
cat >>"$T/tool/lib/core.sh" <<'TAPS'
eval "$(declare -f mac_detect | sed '1s/mac_detect/v_original_detect/')"
mac_detect() { printf '%s %s\n' "$OMB_INTENT" "$OMB_PERSIST" >>"$V_DETECT"; v_original_detect "$@"; }
log_event() { printf 'log\n' >>"$V_EFFECTS"; return 99; }
core_action_info() { printf 'action\n' >>"$V_EFFECTS"; return 99; }
core_barrier() { printf 'barrier\n' >>"$V_EFFECTS"; return 99; }
state_lock() { printf 'lock\n' >>"$V_EFFECTS"; return 99; }
state_set() { printf 'state\n' >>"$V_EFFECTS"; return 99; }
state_must_set() { printf 'state\n' >>"$V_EFFECTS"; return 99; }
state_stamp() { printf 'state\n' >>"$V_EFFECTS"; return 99; }
cfg_load() { printf 'config\n' >>"$V_EFFECTS"; return 99; }
cfg_save() { printf 'config\n' >>"$V_EFFECTS"; return 99; }
shared_intent_save() { printf 'plan\n' >>"$V_EFFECTS"; return 99; }
run() { printf 'run\n' >>"$V_EFFECTS"; return 99; }
fetch_upstream() { printf 'download\n' >>"$V_EFFECTS"; return 99; }
core_op_write() { printf 'operation\n' >>"$V_EFFECTS"; return 99; }
TAPS
shims=$(t_shims "$T")
C_HOME=$T/tool C_PATH="$shims:/usr/bin:/bin:/usr/sbin:/sbin"
v_reset() { : >"$T/detect"; : >"$T/effects"; : >"$T/shims.log"; }
v_env() { printf 'OMB_SESSION_SCOPES=%s V_DETECT=%s V_EFFECTS=%s SHIM_LOG=%s %s' "${V_SCOPES:-plan}" "$T/detect" "$T/effects" "$T/shims.log" "${V_EXTRA:-}"; }
# v_run RECORD... — validate, select action=${V_ACTION:-plan.save}, with RECORDs.
v_run() { v_reset; C_ENV=$(v_env) c_run validate "select	action=${V_ACTION:-plan.save}" "$@"; }
v_enc() { (. "$REPO/lib/records.sh" && rec_enc "$1"); }
v_l() { printf 'arg\tname=linux_size\tvalue=%s' "$(v_enc "$1")"; }
v_s() { printf 'arg\tname=shared_size\tvalue=%s' "$(v_enc "$1")"; }
v_types() { cut -f1 "$C_EV" | tr '\n' ' '; }
v_basis() { sed -n 's/^review	action=plan\.save	basis=\([0-9a-f]*\)$/\1/p' "$C_EV"; }
v_body_of() { sed '1,2d;$d' "$C_EV"; }
v_fixed() {
  case "$1" in
    unknown-parameter) printf '%s' 'This parameter is not accepted by plan validation.' ;;
    required) printf '%s' 'This size parameter is required.' ;;
    empty) printf '%s' 'Enter a size such as 250GB or 30%.' ;;
    syntax) printf '%s' 'Use a number with GB, TB, or %.' ;;
    leading-zero) printf '%s' 'Sizes cannot have a leading zero.' ;;
    too-large) printf '%s' 'The numeric size is too large.' ;;
    precision) printf '%s' 'Use at most three decimals for GB/TB or one for %.' ;;
    percentage-range) printf '%s' 'A percentage cannot exceed 100%.' ;;
    zero) printf '%s' 'The numeric size must be greater than zero.' ;;
    whole-disk) printf '%s' 'The size must be smaller than the whole internal disk.' ;;
    max-unavailable) printf '%s' 'max is not available for this parameter.' ;;
    below-minimum) printf '%s' 'The size is below the minimum for this parameter.' ;;
    above-maximum) printf '%s' 'The size exceeds the current maximum for this parameter.' ;;
  esac
}
v_inv() { printf 'invalid\tname=%s\tcode=%s\ttext=%s' "$1" "$2" "$(v_enc "$(v_fixed "$2")")"; }
v_norm() { printf 'normal\tname=%s\tvalue=%s' "$1" "$2"; }
v_msg() { printf 'message\tlevel=%s\ttext=%s' "$1" "$(v_enc "$2")"; }
R_DONE=$(printf 'result\tstatus=done\tcode=ok\ttext=\tnext=')
R_INVALID=$(printf 'result\tstatus=refused\tcode=invalid\ttext=\tnext=')
R_UNPLANNABLE=$(printf 'result\tstatus=refused\tcode=unplannable\ttext=%s\tnext=' "$(v_enc 'A trustworthy plan cannot be computed for this machine state.')")

# v_route LABEL STATUS CODE — a routing refusal: hello and the result alone,
# admitted, and no planning capture.
v_route() {
  assert_eq "$(c_result) $C_RC $(c_admits "${V_OP:-validate}")" "$2 $3 0 ok" "$1"
  assert_eq "$(v_types)" 'omb-res 1 hello result ' "$1: hello and result alone"
  assert_empty_file "$T/detect" "$1: no planning capture"
  assert_empty_file "$T/effects" "$1: no effect reached"
}
# v_refused LABEL BODY — refused invalid with exactly BODY between hello and
# the result: no review, no answer, no generation.
v_refused() {
  assert_eq "$(c_result) $C_RC" 'refused invalid 0' "$1: refused invalid"
  assert_eq "$(c_admits validate)" ok "$1: admitted"
  assert_eq "$C_ERR" '' "$1: clean stderr"
  assert_eq "$(v_body_of)" "$2" "$1: exact records"
  assert_eq "$(sed -n '$p' "$C_EV")" "$R_INVALID" "$1: exact result"
  assert_empty_file "$T/effects" "$1: no effect reached"
}
# v_unplannable LABEL BODY — the owner's explanation as warn messages, then
# refused unplannable: no normal, answer, invalid, review or generation.
v_unplannable() {
  assert_eq "$(c_result) $C_RC" 'refused unplannable 0' "$1: refused unplannable"
  assert_eq "$(c_admits validate)" ok "$1: admitted"
  assert_eq "$C_ERR" '' "$1: clean stderr"
  assert_eq "$(v_body_of)" "$2" "$1: exactly the owner's explanation"
  assert_eq "$(sed -n '$p' "$C_EV")" "$R_UNPLANNABLE" "$1: exact result"
  assert_eq "$(awk -F '\t' '$1 ~ /^(normal|answer|invalid|review|generation)$/' "$C_EV")" '' "$1: no normal, answer, invalid, review or generation"
  assert_empty_file "$T/effects" "$1: no effect reached"
}
# v_done LABEL BODY — done ok, admitted, clean, one read-only capture, no
# generation, and exactly BODY between hello and the result (the review's
# basis written as BASIS).
v_done() {
  local b
  b=$(v_basis)
  assert_eq "$(c_result) $C_RC" 'done ok 0' "$1: done"
  assert_eq "$(c_admits validate)" ok "$1: admitted"
  assert_eq "$C_ERR" '' "$1: clean stderr"
  case "$b" in ????????????????????????????????????????????????????????????????) ok ;; *) fail "$1: one 64-digit review basis, got [$b]" ;; esac
  assert_eq "$(v_body_of | sed "s/	basis=$b\$/	basis=BASIS/")" "$2" "$1: exact records"
  assert_eq "$(sed -n '$p' "$C_EV")" "$R_DONE" "$1: exact result"
  assert_eq "$(cat "$T/detect")" 'read 0' "$1: one capture under read intent and zero persistence"
  assert_empty_file "$T/effects" "$1: no effect reached"
}

# Oracles: the baseline's own owners over the same fixture, in a subshell.
# v_plan FIXTURE LINUX_BYTES SHARED_GB — "MODE RESIZE OS" as the planner lays it out.
v_plan() {
  (
    t_load >/dev/null 2>&1
    OMB_FIXTURE=$1
    mac_detect
    mac_plan_compute "$3"
    plan_layout "$2"
    [ "$PLAN_OK" = 1 ] || printf 'NOPLAN '
    printf '%s %s %s' "$PLAN_MODE" "${PLAN_ANSWER_RESIZE:--}" "$PLAN_ANSWER_OS"
  )
}
# v_owner FIXTURE WHAT [ARGS] — one owner-produced text: the blocker lines as
# warn messages, the Asahi state's reason, plan_validate's verdict, a layout's
# PLAN_ERR, or the Shared-adjusted Linux maximum.
v_owner() {
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    OMB_FIXTURE=$1
    mac_detect
    mac_plan_compute 0
    case "$2" in
      blockers)
        mac_blockers | while IFS= read -r line; do [ -z "$line" ] || rec_line message level warn text "$line"; done
        ;;
      asahi) asahi_classify && rec_line message level warn text "$ASAHI_WHY" ;;
      verdict) mac_plan_compute "$4" && plan_validate "$3" ;;
      layout) mac_plan_compute "$4"; plan_layout "$3"; rec_line message level warn text "$PLAN_ERR" ;;
      max) mac_plan_compute "$3"; printf '%s' "$PLAN_LINUX_MAX" ;;
    esac
  )
}
# v_body FIXTURE LINUX_BYTES SHARED_GB WARN [MESSAGE...] — the success records
# the planner's own layout implies: answers in order, the warning, both
# normals (Linux first), the review, the informational notices.
v_body() {
  local fx=$1 l=$2 s=$3 warn=$4 mode r os n=0 m
  shift 4
  read -r mode r os <<EOF
$(v_plan "$fx" "$l" "$s")
EOF
  if [ "$mode" = resize ]; then
    n=1
    printf 'answer\tn=1\tprompt=New%%20size%%20for%%20macOS\tvalue=%s\tbytes=%s\n' "$r" $((${r%MiB} * 1048576))
  fi
  n=$((n + 1))
  if [ "$os" = max ]; then
    printf 'answer\tn=%s\tprompt=New%%20OS%%20size\tvalue=max\tbytes=\n' "$n"
  else
    printf 'answer\tn=%s\tprompt=New%%20OS%%20size\tvalue=%s\tbytes=%s\n' "$n" "$os" $((${os%MiB} * 1048576))
  fi
  [ -z "$warn" ] || printf 'warning\tid=linux-below-recommended\ttext=%s\tfix=\n' "$(v_enc "$warn")"
  printf 'normal\tname=linux_size\tvalue=%s\nnormal\tname=shared_size\tvalue=%s\nreview\taction=plan.save\tbasis=BASIS\n' "$l" $((s * GB))
  for m in "$@"; do printf 'message\tlevel=info\ttext=%s\n' "$(v_enc "$m")"; done
}

# --- A. Routing and refusal precedence (no capture: runs on every platform) ---------
C_FIX=$FIX/mac-m1pro-1tb-roomy
for V_SCOPES in journey journey,health,logs disk shared; do
  v_run "$(v_l 250GB)" "$(v_s 0)"
  v_route "validate without the plan scope ($V_SCOPES)" refused scope
done
V_SCOPES=''
assert_eq "$(sed -n '$p' "$C_EV")" "$(printf 'result\tstatus=refused\tcode=scope\ttext=%s\tnext=' "$(v_enc 'This session does not include the plan scope.')")" 'scope refusal: exact result'
for V_ACTION in test.read shared.create plan.saved plan; do
  v_run "$(v_l 250GB)" "$(v_s 0)"
  v_route "another select family ($V_ACTION)" refused unavailable
  V_SCOPES=journey v_run "$(v_l 250GB)" "$(v_s 0)"
  v_route "another select family ($V_ACTION) precedes the scope" refused unavailable
done
V_ACTION=''
assert_eq "$(sed -n '$p' "$C_EV")" "$(printf 'result\tstatus=refused\tcode=unavailable\ttext=%s\tnext=' "$(v_enc 'Plan validation answers only plan.save, in macOS fixtures.')")" 'unavailable refusal: exact result'
for fx in linux-alarm-fresh linux-omarchy-installed; do
  C_FIX=$FIX/$fx
  v_run "$(v_l 250GB)" "$(v_s 0)"
  v_route "Linux fixture ($fx)" refused unavailable
  V_SCOPES=journey v_run "$(v_l 250GB)" "$(v_s 0)"
  v_route "Linux fixture ($fx): platform precedes the scope" refused unavailable
done
# Outside fixtures, on a machine describing itself as an arm64 Mac.
mkdir -p "$T/darwin"
# shellcheck disable=SC2016 # Arguments belong to the generated uname shim.
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) /usr/bin/uname "$@" ;; esac\n' >"$T/darwin/uname"
chmod +x "$T/darwin/uname"
C_PATH="$T/darwin:/usr/bin:/bin:/usr/sbin:/sbin" V_EXTRA='OMB_FIXTURE= OMB_FRONTEND_DEV='
v_run "$(v_l 250GB)" "$(v_s 0)"
v_route 'non-fixture macOS validate' refused unavailable
V_SCOPES=journey v_run "$(v_l 250GB)" "$(v_s 0)"
v_route 'non-fixture macOS validate: fixture precedes the scope' refused unavailable
# The startup check's closed table is unchanged: plan.save is refused there too.
V_SCOPES=journey V_EXTRA='OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_SESSION_INTENT=read OMB_SESSION_PURPOSE=frontend-check'
v_run "$(v_l 250GB)" "$(v_s 0)"
v_route 'startup-check validate plan.save' refused unavailable
assert_eq "$(sed -n '$p' "$C_EV")" "$(printf 'result\tstatus=refused\tcode=unavailable\ttext=%s\tnext=' "$(v_enc 'A frontend-check session answers only hello and the journey snapshot.')")" 'startup-check: its fixed refusal'
V_SCOPES='' V_EXTRA='' C_PATH="$shims:/usr/bin:/bin:/usr/sbin:/sbin"

# Malformed requests stay admission failures: exit status 2, no capture.
C_FIX=$FIX/mac-m1pro-1tb-roomy
for bad in 'nothing' 'dup' 'empty' 'page' 'type'; do
  v_reset
  case "$bad" in
    nothing) C_ENV=$(v_env) c_run validate "$(v_l 250GB)" ;;
    dup) C_ENV=$(v_env) c_run validate "select	action=plan.save" "$(v_l 250GB)" "$(v_l 251GB)" ;;
    empty) C_ENV=$(v_env) c_run validate "select	action=plan.save" "arg	name=linux_size	value=" ;;
    page) C_ENV=$(v_env) c_run validate "page	scope=plan	kind=x	generation=$zero	offset=0	limit=1" "select	action=plan.save" ;;
    type) C_ENV=$(v_env) c_run validate "select	action=plan.save" "arg	name=Linux	value=1" ;;
  esac
  assert_rc "$C_RC" 2 "malformed validate ($bad) fails admission"
  case "$(c_result)" in 'error schema' | 'error type') ok ;; *) fail "malformed validate ($bad): $(c_result)" ;; esac
  assert_empty_file "$T/detect" "malformed validate ($bad): no capture"
done

# Execute plan.save stays unavailable, whatever it is sent.
V_OP=execute
v_reset
C_ENV=$(v_env) c_run execute "exec	action=plan.save	basis=$zero	confirm="
v_route 'execute plan.save' refused unavailable
v_reset
C_ENV=$(v_env) c_run execute "exec	action=plan.save	basis=$zero	confirm=" "$(v_l 250GB)" "$(v_s 0)"
v_route 'execute plan.save with its sizes' refused unavailable
V_OP=''

# Unknown names: the first in byte order, before any machine read — even on a
# machine nothing can be planned on.
for fx in mac-m1pro-1tb-roomy mac-m1pro-1tb-tight; do
  C_FIX=$FIX/$fx
  v_run "arg	name=ab	value=1" "$(v_l 250GB)" "arg	name=a_c	value=1" "$(v_s 0)" "arg	name=b	value=1" "arg	name=a-c	value=1"
  v_refused "unknown names on $fx: the first in byte order" "$(v_inv a-c unknown-parameter)"
  assert_empty_file "$T/detect" "unknown names on $fx: no planning capture"
  v_run "arg	name=linux.size	value=250GB"
  v_refused "one unknown name on $fx" "$(v_inv linux.size unknown-parameter)"
  assert_empty_file "$T/detect" "one unknown name on $fx: no planning capture"
done
v_run "arg	name=zeta	value=1" "arg	name=x_	value=1" "arg	name=0x	value=1"
v_refused 'digits before letters, whatever the request order' "$(v_inv 0x unknown-parameter)"

# Plan.save is never advertised: no Gate 2 snapshot lists an action, and the
# foundation harness keeps exactly its test actions.
C_HOME=$REPO
fixtures=linux-alarm-fresh
t_plutil 'Validate: macOS journey snapshot lists no action' && fixtures="$fixtures mac-m1pro-1tb-roomy"
for fx in $fixtures; do
  C_FIX=$FIX/$fx
  C_ENV='OMB_SESSION_SCOPES=journey,plan,logs' c_run snapshot "scope	name=journey"
  assert_eq "$(c_result)" 'done ok' "$fx journey snapshot with the plan scope"
  assert_eq "$(grep -c '^action	' "$C_EV") $(grep -c 'plan\.save' "$C_EV")" '0 0' "$fx journey snapshot: no action, plan.save nowhere"
  C_ENV='OMB_SESSION_SCOPES=journey,plan,logs' c_run snapshot "scope	name=logs"
  assert_eq "$(c_result) $(grep -c '^action	' "$C_EV")" 'done ok 0' "$fx logs snapshot: no action"
  C_ENV='OMB_SESSION_SCOPES=journey,plan' c_run snapshot "scope	name=plan"
  assert_eq "$(c_result) $(grep -c '^action	' "$C_EV")" 'refused unavailable 0' "$fx: no plan snapshot dataset exists"
done
c_fixture
C_ENV='OMB_SESSION_SCOPES=journey,plan' c_run validate "select	action=plan.save" "$(v_l 250GB)" "$(v_s 0)"
assert_eq "$(c_result) $C_RC $(c_admits validate)" 'refused unavailable 0 ok' 'foundation harness: validate stays its own refusal'
assert_eq "$(sed -n '$p' "$C_EV")" "$(printf 'result\tstatus=refused\tcode=unavailable\ttext=%s\tnext=' "$(v_enc 'Nothing in this gate pages details or validates parameters.')")" 'foundation harness: its fixed text'
C_ENV='OMB_SESSION_SCOPES=journey,plan' c_run snapshot "scope	name=journey"
assert_eq "$(awk -F '\t' '$1 == "action" { sub(/^id=/, "", $2); printf "%s ", $2 }' "$C_EV")" 'test.read test.mutate test.handoff ' \
  'foundation harness: exactly its test actions, no plan.save'
C_FOUNDATION=0
C_HOME=$T/tool

# --- B–M. Planning over macOS fixtures (read through plutil) -------------------------
if t_plutil 'Validate macOS planning contract'; then
  R=$FIX/mac-m1pro-1tb-roomy
  F=$FIX/mac-m1-free-space
  C_FIX=$R

  # B. Presence. Both present succeed; an absent one is `required` when its
  # turn comes (Shared first), after the planning capture.
  v_run "$(v_l 250GB)" "$(v_s 0)"
  v_done 'both sizes' "$(v_body "$R" $((250 * GB)) 0 '')"
  first=$(v_basis)
  v_run "$(v_s 0)" "$(v_l 250GB)"
  assert_eq "$(v_basis)" "$first" 'argument order in the request changes nothing'
  v_run "$(v_l 250GB)"
  v_refused 'Shared absent' "$(v_inv shared_size required)"
  assert_eq "$(cat "$T/detect")" 'read 0' 'Shared absent: its turn comes after the one capture'
  v_run "$(v_s 50GB)"
  v_refused 'Linux absent' "$(v_norm shared_size 50000000000)
$(v_inv linux_size required)"
  v_run
  v_refused 'both absent: only Shared is reported' "$(v_inv shared_size required)"

  # C. The Shared None sentinel: only a trimmed bare 0, and only for Shared.
  for zero_spelling in 0 ' 0' "$(printf '0\t')" "$(printf '\n0 ')" "$(printf ' \r0\f ')" '  0  '; do
    v_run "$(v_l 250GB)" "$(v_s "$zero_spelling")"
    v_done "Shared sentinel [$zero_spelling]" "$(v_body "$R" $((250 * GB)) 0 '')"
    assert_eq "$(v_basis)" "$first" "Shared sentinel [$zero_spelling]: the same basis as 0"
  done
  for spelling in 0GB 0% 0.0 0TB '0 GB' 0.000GB; do
    v_run "$(v_l 250GB)" "$(v_s "$spelling")"
    v_refused "Shared $spelling is numeric zero" "$(v_inv shared_size zero)"
  done
  v_run "$(v_l 250GB)" "$(v_s 00)"
  v_refused 'Shared 00 is not the sentinel' "$(v_inv shared_size leading-zero)"
  for spelling in 0 ' 0 ' 0GB 0%; do
    v_run "$(v_l "$spelling")" "$(v_s 0)"
    v_refused "Linux $spelling has no sentinel" "$(v_norm shared_size 0)
$(v_inv linux_size zero)"
  done

  # D. Every finite code, with its fixed text. Shared first; then Linux with a
  # valid Shared retained.
  # Whitespace-only values (admission refuses an empty one) trim to empty.
  for value in '   ' "$(printf '\t')" "$(printf ' \t\r ')"; do
    v_run "$(v_l 250GB)" "$(v_s "$value")"
    v_refused "Shared [$(v_enc "$value")] is empty" "$(v_inv shared_size empty)"
    v_run "$(v_l "$value")" "$(v_s 0)"
    v_refused "Linux [$(v_enc "$value")] is empty" "$(v_norm shared_size 0)
$(v_inv linux_size empty)"
  done
  for value in max ' MAX ' Max; do
    v_run "$(v_l 250GB)" "$(v_s "$value")"
    v_refused "Shared [$value] has no maximum to take" "$(v_inv shared_size max-unavailable)"
  done
  shared_cases='syntax|abc
syntax|250XB
syntax|-5GB
syntax|1e3
syntax|250GB extra
syntax|1,5GB
leading-zero|010GB
leading-zero|007%
too-large|99999999GB
too-large|10000TB
too-large|1000%
precision|1.2345GB
precision|0.0001TB
precision|10.55%
percentage-range|150%
percentage-range|100.5%
zero|0GB
whole-disk|100%
whole-disk|2TB
whole-disk|1001GB
below-minimum|0.5GB
below-minimum|0.999GB
above-maximum|601GB
above-maximum|99.9%'
  while IFS='|' read -r code value; do
    [ -n "$code" ] || continue
    v_run "$(v_l 250GB)" "$(v_s "$value")"
    v_refused "Shared [$value] is $code" "$(v_inv shared_size "$code")"
  done <<EOF
$shared_cases
EOF
  linux_cases='syntax|abc
syntax|250 G B
leading-zero|0250GB
too-large|12345678GB
precision|250.0001GB
percentage-range|101%
zero|0%
whole-disk|100%
whole-disk|1.1TB
below-minimum|53GB
below-minimum|53.999GB
below-minimum|5%
above-maximum|655GB
above-maximum|0.7TB'
  while IFS='|' read -r code value; do
    [ -n "$code" ] || continue
    v_run "$(v_l "$value")" "$(v_s 0)"
    want="$(v_norm shared_size 0)
$(v_inv linux_size "$code")"
    # Linux's whole-GB notice comes before its range check, as the baseline's.
    case "$value" in 53.999GB) want="$want
$(v_msg info 'Linux sizes are whole GB: using 53 GB.')" ;; 5%) want="$want
$(v_msg info 'Linux sizes are whole GB: using 50 GB.')" ;; esac
    v_refused "Linux [$value] is $code" "$want"
  done <<EOF
$linux_cases
EOF
  # Invalid bytes are a size the grammar refuses, never a truncated size.
  for value in "$(printf '\377')" "$(printf '25\3770GB')" "$(printf '250GB\302\240')"; do
    v_run "$(v_l 250GB)" "$(v_s "$value")"
    v_refused "Shared [$(v_enc "$value")] is syntax" "$(v_inv shared_size syntax)"
    v_run "$(v_l "$value")" "$(v_s 0)"
    v_refused "Linux [$(v_enc "$value")] is syntax" "$(v_norm shared_size 0)
$(v_inv linux_size syntax)"
  done

  # E. Order: an invalid Shared stops evaluation; Linux's turn never comes.
  v_run "$(v_l abc)" "$(v_s abc)"
  v_refused 'Shared and Linux both invalid: Shared alone' "$(v_inv shared_size syntax)"
  v_run "$(v_s 0GB)"
  v_refused 'Shared invalid, Linux absent: no required for Linux' "$(v_inv shared_size zero)"
  v_run "$(v_l 2000GB)" "$(v_s 50.5GB)"
  v_refused 'Shared valid, Linux invalid: Shared normal and notice retained' "$(v_norm shared_size 50000000000)
$(v_inv linux_size whole-disk)
$(v_msg info 'Shared sizes are whole GB: using 50 GB.')"

  # F. Normalization: positive sizes floor to whole decimal GB before the
  # range checks; spellings of one effective size bind one basis.
  for spelling in 250GB '250 GB' ' 250gb ' 250 250G 0.25TB 0.25t 250.000GB; do
    v_run "$(v_l "$spelling")" "$(v_s 0)"
    v_done "Linux [$spelling]" "$(v_body "$R" $((250 * GB)) 0 '')"
    assert_eq "$(v_basis)" "$first" "Linux [$spelling]: the basis of 250GB"
  done
  for spelling in 250.9GB 250.001GB 250.5 25% 25.0%; do
    v_run "$(v_l "$spelling")" "$(v_s 0)"
    v_done "Linux [$spelling] floors to 250 GB" "$(v_body "$R" $((250 * GB)) 0 '' 'Linux sizes are whole GB: using 250 GB.')"
    assert_eq "$(v_basis)" "$first" "Linux [$spelling]: the basis of 250GB"
  done
  v_run "$(v_l 250GB)" "$(v_s 50GB)"
  v_done 'Shared 50GB' "$(v_body "$R" $((250 * GB)) 50 '')"
  s50=$(v_basis)
  for spelling in 50.5GB 50.999GB 50.5 5% 5.0%; do
    v_run "$(v_l 250GB)" "$(v_s "$spelling")"
    v_done "Shared [$spelling] floors to 50 GB" "$(v_body "$R" $((250 * GB)) 50 '' 'Shared sizes are whole GB: using 50 GB.')"
    assert_eq "$(v_basis)" "$s50" "Shared [$spelling]: the basis of 50GB"
  done
  v_run "$(v_l 250.5GB)" "$(v_s 50.5GB)"
  v_done 'both floor: Shared notice, then Linux notice' "$(v_body "$R" $((250 * GB)) 50 '' 'Shared sizes are whole GB: using 50 GB.' 'Linux sizes are whole GB: using 250 GB.')"
  assert_eq "$(v_basis)" "$s50" 'both floored: the basis of 250GB beside 50GB'
  # Linux max is the established maximum after Shared, never before it.
  max0=$(v_owner "$R" max 0)
  max300=$(v_owner "$R" max 300)
  assert_eq "$max0 $max300" '654000000000 354000000000' 'roomy: Shared 300 GB lowers the Linux maximum'
  v_run "$(v_l max)" "$(v_s 0)"
  v_done 'Linux max without Shared' "$(v_body "$R" "$max0" 0 '')"
  v_run "$(v_l MAX)" "$(v_s 300GB)"
  v_done 'Linux max beside 300 GB of Shared' "$(v_body "$R" "$max300" 300 '')"
  v_run "$(v_l max)" "$(v_s 0)"
  bmax=$(v_basis)
  v_run "$(v_l 654GB)" "$(v_s 0)"
  assert_eq "$(v_basis)" "$bmax" 'max and its value bind one basis'

  # G. Planner semantics: the answers are the planner's own, in its order.
  v_run "$(v_l 600GB)" "$(v_s 0)"
  v_done 'roomy Linux 600 GB without Shared' "$(v_body "$R" $((600 * GB)) 0 '')"
  v_run "$(v_l 600GB)" "$(v_s 300GB)"
  v_refused 'roomy Linux 600 GB beside 300 GB of Shared' "$(v_norm shared_size 300000000000)
$(v_inv linux_size above-maximum)"
  v_run "$(v_l 354GB)" "$(v_s 300GB)"
  v_done 'roomy Linux at its Shared-adjusted maximum' "$(v_body "$R" $((354 * GB)) 300 '')"
  v_run "$(v_l 355GB)" "$(v_s 300GB)"
  v_refused 'roomy Linux one GB past it' "$(v_norm shared_size 300000000000)
$(v_inv linux_size above-maximum)"
  v_run "$(v_l 654GB)" "$(v_s 0)"
  v_done 'roomy Linux maximum' "$(v_body "$R" $((654 * GB)) 0 '')"
  v_run "$(v_l 600GB)" "$(v_s 600GB)"
  v_refused 'roomy Shared at its maximum leaves Linux its minimum only' "$(v_norm shared_size 600000000000)
$(v_inv linux_size above-maximum)"
  v_run "$(v_l 54GB)" "$(v_s 600GB)"
  w=$(v_owner "$R" verdict $((54 * GB)) 600)
  v_done 'roomy Shared maximum with minimum Linux' "$(v_body "$R" $((54 * GB)) 600 "${w#warn|}")"
  for b in 54 99; do
    w=$(v_owner "$R" verdict $((b * GB)) 0)
    assert_eq "${w%%|*}" warn "$b GB is below the recommendation"
    v_run "$(v_l "${b}GB")" "$(v_s 0)"
    v_done "Linux $b GB: a warning, not an invalidity" "$(v_body "$R" $((b * GB)) 0 "${w#warn|}")"
  done
  assert_contains "$(grep '^warning' "$C_EV")" "$(v_enc '99 GB works, but Omarchy Mac recommends 100 GB.')" "the baseline's own warning reason"
  v_run "$(v_l 100GB)" "$(v_s 0)"
  v_done 'Linux 100 GB: no warning' "$(v_body "$R" $((100 * GB)) 0 '')"
  # Free space after the container: no resize, one answer; past it, a resize.
  C_FIX=$F
  v_run "$(v_l 250GB)" "$(v_s 0)"
  v_done 'free space holds Linux' "$(v_body "$F" $((250 * GB)) 0 '')"
  assert_eq "$(grep -c '^answer' "$C_EV") $(v_plan "$F" $((250 * GB)) 0)" '1 free - 238419MiB' 'free space: New OS size alone, no resize answer'
  v_run "$(v_l 400GB)" "$(v_s 0)"
  v_done 'free space too small: a resize' "$(v_body "$F" $((400 * GB)) 0 '')"
  assert_eq "$(grep -c '^answer' "$C_EV") $(v_plan "$F" $((400 * GB)) 0)" '2 resize 567063MiB max' 'resize: the macOS size, then max'
  v_run "$(v_l 200GB)" "$(v_s 50GB)"
  v_done 'Shared on: Linux exact, never max' "$(v_body "$F" $((200 * GB)) 50 '')"
  assert_eq "$(grep -c 'value=max' "$C_EV")" 0 'Shared on: no max answer'
  # Within the maximum, the baseline planner's own plan_verify still refuses a
  # resize that frees too little for the installer (just past the gap). That
  # is the planner's invariant failing, never a plan and never the person's.
  for req in '250 50' '259 50' '300 0' '309 0'; do
    read -r l s <<EOF
$req
EOF
    case "$(v_plan "$F" $((l * GB)) "$s")" in 'NOPLAN resize '*) ok ;; *) fail "free space $l/$s: the owner's plan_verify refuses its resize" ;; esac
    assert_eq "$(v_owner "$F" verdict $((l * GB)) "$s")" ok "free space $l/$s: within plan_validate's range"
    sv=${s}GB
    [ "$s" != 0 ] || sv=0
    v_run "$(v_l "${l}GB")" "$(v_s "$sv")"
    assert_eq "$(c_result) $C_RC $(c_admits validate)" 'error invariant 0 ok' "free space $l/$s: error invariant"
    assert_eq "$(v_types)" 'omb-res 1 hello result ' "free space $l/$s: no candidate record"
    assert_eq "$(sed -n '$p' "$C_EV")" "$(printf 'result\tstatus=error\tcode=invariant\ttext=%s\tnext=' "$(v_enc "The planner's internal checks did not hold.")")" "free space $l/$s: the fixed text"
    assert_empty_file "$T/effects" "free space $l/$s: no effect"
  done
  v_run "$(v_l 260GB)" "$(v_s 50GB)"
  v_done 'free space past the band: a resize that frees enough' "$(v_body "$F" $((260 * GB)) 50 '')"
  # Limits known, nothing macOS can give up: the maximum is trustworthy.
  C_FIX=$FIX/mac-geo-two-gaps
  w=$(v_owner "$FIX/mac-geo-two-gaps" verdict $((74 * GB)) 0)
  v_run "$(v_l 74GB)" "$(v_s 0)"
  v_done 'two gaps: one gap, never two added' "$(v_body "$FIX/mac-geo-two-gaps" $((74 * GB)) 0 "${w#warn|}")"
  v_run "$(v_l 75GB)" "$(v_s 0)"
  v_refused 'two gaps: Linux past its trustworthy maximum' "$(v_norm shared_size 0)
$(v_inv linux_size above-maximum)"
  v_run "$(v_l 54GB)" "$(v_s 21GB)"
  v_refused 'two gaps: Shared past its trustworthy maximum' "$(v_inv shared_size above-maximum)"
  v_run "$(v_l 54GB)" "$(v_s 20GB)"
  assert_eq "$(c_result)" 'done ok' 'two gaps: Shared at its maximum'
  for fx in mac-geo-512-sectors mac-m2-512 mac-m3pro-experimental mac-asahi-resized-only; do
    C_FIX=$FIX/$fx
    v_run "$(v_l 120GB)" "$(v_s 10GB)"
    v_done "$fx plans" "$(v_body "$FIX/$fx" $((120 * GB)) 10 '')"
  done

  # H. An unknown resize limit: a verified gap still holds a plan; relying on
  # the resize it would need is the machine's, never the person's, limit.
  U=$(t_variant mac-m1-free-space)
  rm "$U/cmd/diskutil_limits_disk3"
  C_FIX=$U
  v_run "$(v_l 250GB)" "$(v_s 0)"
  v_done 'unknown limit, the gap holds it' "$(v_body "$U" $((250 * GB)) 0 '')"
  assert_eq "$(v_plan "$U" $((250 * GB)) 0)" 'free - 238419MiB' 'unknown limit: no resize answer'
  v_run "$(v_l max)" "$(v_s 0)"
  v_done 'unknown limit, max is the gap' "$(v_body "$U" $((299 * GB)) 0 '')"
  v_run "$(v_l 300GB)" "$(v_s 0)"
  v_unplannable 'unknown limit, Linux needs the resize' "$(v_owner "$U" layout $((300 * GB)) 0)"
  assert_contains "$C_OUT" "$(v_enc 'and macOS cannot be resized: diskutil did not report the container')" "the planner's own reason"
  v_run "$(v_l 53GB)" "$(v_s 0)"
  v_refused 'unknown limit: below the minimum is still the person' "$(v_norm shared_size 0)
$(v_inv linux_size below-minimum)"
  v_run "$(v_l 54GB)" "$(v_s 245GB)"
  assert_eq "$(c_result)" 'done ok' 'unknown limit: Shared at its gap maximum'
  v_run "$(v_l 54GB)" "$(v_s 246GB)"
  v_unplannable 'unknown limit, Shared needs the resize' "$(v_owner "$U" layout $((54 * GB)) 246)"
  v_run "$(v_l abc)" "$(v_s 246GB)"
  v_unplannable 'unknown limit, Shared unplannable before Linux is read' "$(v_owner "$U" layout $((54 * GB)) 246)"

  # I. Machines nothing can be planned on: the baseline's blockers, then an
  # existing install, each in the owner's words; parameters are not judged.
  for fx in mac-m1pro-1tb-tight mac-geo-no-limits mac-geo-multi-apfs mac-geo-disagree mac-geo-missing-offset; do
    C_FIX=$FIX/$fx
    want=$(v_owner "$FIX/$fx" blockers)
    if [ -n "$want" ]; then ok; else fail "$fx: the owner reports a blocker"; fi
    v_run "$(v_l 250GB)" "$(v_s 0)"
    v_unplannable "$fx with valid sizes" "$want"
    assert_eq "$(cat "$T/detect")" 'read 0' "$fx: one capture"
    v_run "$(v_l abc)" "$(v_s 00)"
    v_unplannable "$fx with invalid sizes" "$want"
    v_run
    v_unplannable "$fx with no sizes" "$want"
  done
  B=$(t_variant mac-m1pro-1tb-tight)
  printf 'staff everyone\n' >"$B/cmd/id_groups"
  C_FIX=$B
  want=$(v_owner "$B" blockers)
  assert_eq "$(printf '%s\n' "$want" | grep -c .)" 2 'two blockers: two lines'
  v_run "$(v_l 250GB)" "$(v_s 0)"
  v_unplannable 'two blockers, each a message, in owner order' "$want"
  for fx in mac-asahi-installed mac-asahi-pending mac-asahi-unprepared mac-asahi-stub-only mac-asahi-two-stubs mac-shared-reserved mac-shared-created; do
    C_FIX=$FIX/$fx
    assert_eq "$(v_owner "$FIX/$fx" blockers)" '' "$fx: no blocker, an install"
    want=$(v_owner "$FIX/$fx" asahi)
    v_run "$(v_l 120GB)" "$(v_s 10GB)"
    v_unplannable "$fx: no second install is planned" "$want"
  done
  A=$(t_variant mac-asahi-installed)
  printf 'staff everyone\n' >"$A/cmd/id_groups"
  C_FIX=$A
  v_run "$(v_l 120GB)" "$(v_s 0)"
  v_unplannable 'a blocker precedes the install state' "$(v_owner "$A" blockers)"

  # L. Q4-plan-validation-basis-v1: equivalent spellings bind one basis
  # (above); effective input, geometry and answers each change it.
  C_FIX=$R
  v_run "$(v_l 250GB)" "$(v_s 0)"
  assert_eq "$(v_basis)" "$first" 'the same request twice: the same basis'
  v_run "$(v_l 251GB)" "$(v_s 0)"
  b251=$(v_basis)
  v_run "$(v_l 250GB)" "$(v_s 1GB)"
  b1=$(v_basis)
  if [ -n "$b251" ] && [ "$b251" != "$first" ]; then ok; else fail 'a different Linux size: a different basis'; fi
  if [ -n "$b1" ] && [ "$b1" != "$first" ]; then ok; else fail 'a different Shared size: a different basis'; fi
  # Geometry alone: free-space Linux 250 GB stays in the gap, so its answer is
  # unchanged when macOS's own free space moves; the basis still changes.
  G=$(t_variant mac-m1-free-space)
  C_FIX=$G
  v_run "$(v_l 250GB)" "$(v_s 0)"
  g0=$(v_basis) a0=$(grep '^answer' "$C_EV")
  sed -i.bak 's#<key>APFSContainerFree</key><integer>400000000000</integer>#<key>APFSContainerFree</key><integer>399000000000</integer>#' "$G/cmd/diskutil_info_root" && rm -f "$G/cmd/diskutil_info_root.bak"
  assert_eq "$(grep -c '<integer>399000000000</integer>' "$G/cmd/diskutil_info_root")" 1 'the copied fixture holds 1 GB less APFS free space'
  v_run "$(v_l 250GB)" "$(v_s 0)"
  assert_eq "$(c_result) $(grep '^answer' "$C_EV")" "done ok $a0" 'APFS free space moved: the same free-space answer'
  if [ -n "$(v_basis)" ] && [ "$(v_basis)" != "$g0" ]; then ok; else fail 'APFS free space moved: a different basis'; fi
  cp "$FIX/mac-m1-free-space/cmd/diskutil_info_root" "$G/cmd/diskutil_info_root"
  v_run "$(v_l 250GB)" "$(v_s 0)"
  assert_eq "$(v_basis)" "$g0" 'the fixture restored: its basis again'
  # Another disk, the same request: other answers, another basis.
  C_FIX=$FIX/mac-m2-512
  v_run "$(v_l 120GB)" "$(v_s 0)"
  m2=$(v_basis) a2=$(grep '^answer' "$C_EV")
  C_FIX=$R
  v_run "$(v_l 120GB)" "$(v_s 0)"
  if [ "$(grep '^answer' "$C_EV")" != "$a2" ] && [ "$(v_basis)" != "$m2" ]; then ok; else fail 'other answers: another basis'; fi

  # M. Read purity at every ceiling, with and without saved choices: saved
  # Shared and Linux sizes never reach a validation.
  C_FIX=$R
  for state in absent present; do
    if [ "$state" = present ]; then
      mkdir -p "$T/state"
      chmod 700 "$T/state"
      printf '%s\n' cfg_user=alex cfg_host=omarchy cfg_enc=1 cfg_linux=600 cfg_shared=300 planned_at=2026-09-01T00:00:00Z >"$T/state/state.env"
      chmod 600 "$T/state/state.env"
    fi
    before=$(t_snapshot "$T/state")
    for ceiling in read plan act; do
      V_EXTRA="OMB_SESSION_INTENT=$ceiling"
      v_run "$(v_l 600GB)" "$(v_s 0)"
      v_done "$state/$ceiling success" "$(v_body "$R" $((600 * GB)) 0 '')"
      v_run "$(v_l 600GB)" "$(v_s 300GB)"
      assert_eq "$(c_result)" 'refused invalid' "$state/$ceiling invalid"
      assert_empty_file "$T/effects" "$state/$ceiling invalid: no effect"
      C_FIX=$FIX/mac-m1pro-1tb-tight v_run "$(v_l 250GB)" "$(v_s 0)"
      assert_eq "$(c_result)" 'refused unplannable' "$state/$ceiling unplannable"
      assert_empty_file "$T/effects" "$state/$ceiling unplannable: no effect"
      assert_empty_file "$T/shims.log" "$state/$ceiling no sudo, installer, package, boot or network command"
      assert_eq "$(t_snapshot "$T/state")" "$before" "$state/$ceiling no state, log, plan or lock written"
      assert_eq "$(grep -c '^generation' "$C_EV")" 0 "$state/$ceiling no generation"
    done
  done
  V_EXTRA=''
  rm -rf "$T/state"
fi
assert_eq "$(find "$T" -maxdepth 1 -name 'omarchy-bootstrap.*')" '' 'request scratch cleaned'
assert_eq "$(find "$SESS" -name '*.core' -o -name '*.worker-*')" '' 'no child identity residue'
t_done test-gate2-validate
