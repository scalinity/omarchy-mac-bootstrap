#!/usr/bin/env bash
# Gate 2 Validate evidence: BASE planning equivalence (owners, probes and
# answers), one planning capture per request, exact admitted-byte
# publication, the basis bound to the plan, distinct failure classes through
# real core machinery with hit witnesses, and zero persistence for every
# outcome family.
# shellcheck disable=SC2016,SC2030,SC2031,SC2317,SC2329 # child scripts, scoped environments, test-only taps
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-validate-proof
T=$(t_tmp)
BASELINE=2edb76a7de3f78ec90927ac93d5eec3a84636253
GB=1000000000
mkdir -p "$T/base" "$T/home" "$T/tmp" "$T/tool"
git -C "$REPO" archive "$BASELINE" | tar -x -C "$T/base" || exit 1
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$REPO/release" "$T/tool/"
printf '\n. %q\n' "$TESTS_DIR/gate2-probe-taps.sh" >>"$T/tool/lib/common.sh"
# Test-only seams in the copied tool, each selected by P_FAULT and leaving a
# hit witness in $P_TAPS. The core constructs every response itself.
cat >>"$T/tool/lib/core.sh" <<'TAPS'
p_hit() { printf 'hit %s\n' "$1" >>"$P_TAPS"; }
eval "$(declare -f mac_detect | sed '1s/mac_detect/p_original_detect/')"
mac_detect() {
  printf 'detect %s %s\n' "$OMB_INTENT" "$OMB_PERSIST" >>"$P_TAPS"
  p_original_detect "$@"
  # The machine changes right after the one capture.
  if [ -n "${P_MUTATE:-}" ]; then cp "$P_MUTATE" "$OMB_FIXTURE/cmd/diskutil_info_root"; p_hit mutate; fi
  # A scratch path the producer writes after the capture cannot be written.
  if [ -n "${P_DIR:-}" ]; then mkdir "$OMB_TMP/$P_DIR"; p_hit "dir $P_DIR"; fi
}
eval "$(declare -f sys_cmd | sed '1s/sys_cmd/p_original_sys_cmd/')"
sys_cmd() {
  if [ "${P_FAULT:-}" = hide-list ] && [ "$1" = diskutil_list_disk0 ]; then p_hit hide-list; return 127; fi
  p_original_sys_cmd "$@"
}
eval "$(declare -f parse_size | sed '1s/parse_size/p_original_parse_size/')"
parse_size() {
  if [ "${P_FAULT:-}" = size-outcome ]; then p_hit size-outcome; printf 'an outcome no code names'; return 1; fi
  p_original_parse_size "$@"
}
eval "$(declare -f plan_validate | sed '1s/plan_validate/p_original_plan_validate/')"
plan_validate() {
  if [ "${P_FAULT:-}" = verdict ]; then p_hit verdict; printf 'error|a refusal neither bound explains'; return 0; fi
  p_original_plan_validate "$@"
}
eval "$(declare -f plan_layout | sed '1s/plan_layout/p_original_plan_layout/')"
plan_layout() {
  local st
  p_original_plan_layout "$@"
  st=$?
  case "${P_FAULT:-}" in
    answer-move) PLAN_ANSWER_OS=$((${PLAN_ANSWER_OS%MiB} + 1))MiB; p_hit answer-move ;;
    extent-move) PLAN_LIN_START=$((PLAN_LIN_START + MIB)) PLAN_LIN_END=$((PLAN_LIN_END + MIB)); p_hit extent-move ;;
  esac
  return "$st"
}
eval "$(declare -f plan_verify | sed '1s/plan_verify/p_original_plan_verify/')"
plan_verify() {
  # The planner's own check finds a root below Omarchy Mac's minimum.
  if [ "${P_FAULT:-}" = verify ]; then PLAN_ROOT=$((OMARCHY_ROOT_MIN_BYTES - MIB)); p_hit verify; fi
  p_original_plan_verify
}
eval "$(declare -f rec_admit_file | sed '1s/rec_admit_file/p_original_admit/')"
rec_admit_file() {
  local st
  if [ "$1:$2" = res:validate ]; then
    # Only the header and hello are live while the response is preflighted.
    [ "$(wc -l <"$CORE_EVENTS")" -eq 2 ] || p_hit leaked
    # The basis preimages, kept for an independent rebuild.
    if [ -n "${P_KEEP:-}" ]; then command cp "$OMB_TMP/validate.geometry" "$OMB_TMP/validate.plan" "$OMB_TMP/validate.basis" "$P_KEEP/"; fi
    if [ "${P_FAULT:-}" = admit-exec ]; then p_hit admit-exec; return 127; fi
  fi
  p_original_admit "$@"
  st=$?
  if [ "$1:$2:$st" = res:validate:0 ]; then
    cp "$REC_TMP/doc" "$P_TAPS.admitted"
    if [ "${P_STAGE:-0}" = 1 ]; then printf 'unadmitted bytes\n' >"$3"; p_hit stage; fi
  fi
  return "$st"
}
shasum() {
  case "${P_FAULT:-}:$*" in hash:*validate.basis* | geometry-hash:*validate.geometry*) p_hit "${P_FAULT:-}"; return 1 ;; esac
  command shasum "$@"
}
sha256sum() {
  case "${P_FAULT:-}:$*" in hash:*validate.basis* | geometry-hash:*validate.geometry*) p_hit "${P_FAULT:-}"; return 1 ;; esac
  command sha256sum "$@"
}
cp() {
  case "${P_FAULT:-}:${2:-}" in retained-copy:*/journey.admitted) p_hit retained-copy; return 2 ;; esac
  command cp "$@"
}
tail() {
  case "${P_FAULT:-}:${1:-}:${2:-}:${3:-}" in publish-prep:-n:+3:*/journey.admitted) p_hit publish-prep; return 1 ;; esac
  command tail "$@"
}
cat() {
  case "${P_FAULT:-}:${1:-}" in
    prefix-read:*/journey.prefix) p_hit prefix-read; return 1 ;;
    transport:*/validate.suffix) p_hit transport; head -n 1 "$1"; return 1 ;;
  esac
  command cat "$@"
}
log_event() { printf 'effect log\n' >>"$P_TAPS"; return 99; }
core_action_info() { printf 'effect action\n' >>"$P_TAPS"; return 99; }
state_lock() { printf 'effect lock\n' >>"$P_TAPS"; return 99; }
state_set() { printf 'effect state\n' >>"$P_TAPS"; return 99; }
state_must_set() { printf 'effect state\n' >>"$P_TAPS"; return 99; }
cfg_load() { printf 'effect config\n' >>"$P_TAPS"; return 99; }
cfg_save() { printf 'effect config\n' >>"$P_TAPS"; return 99; }
run() { printf 'effect run\n' >>"$P_TAPS"; return 99; }
fetch_upstream() { printf 'effect download\n' >>"$P_TAPS"; return 99; }
core_op_write() { printf 'effect operation\n' >>"$P_TAPS"; return 99; }
TAPS
shims=$(t_shims "$T")
P_PATH="$shims:/usr/bin:/bin:/usr/sbin:/sbin"
c_session
C_HOME=$T/tool C_PATH=$P_PATH
p_reset() { : >"$T/taps"; : >"$T/probes"; : >"$T/shims.log"; rm -f "$T/taps.admitted"; }
p_env() { printf 'OMB_SESSION_SCOPES=plan P_TAPS=%s G2_PROBES=%s SHIM_LOG=%s OMB_TEST_RECORD=%s %s' "$T/taps" "$T/probes" "$T/shims.log" "$T/record" "${P_EXTRA:-}"; }
p_run() { p_reset; C_ENV=$(p_env) c_run validate "select	action=plan.save" "$@"; }
p_enc() { (. "$REPO/lib/records.sh" && rec_enc "$1"); }
p_l() { printf 'arg\tname=linux_size\tvalue=%s' "$(p_enc "$1")"; }
p_s() { printf 'arg\tname=shared_size\tvalue=%s' "$(p_enc "$1")"; }
p_basis() { sed -n 's/^review	action=plan\.save	basis=\([0-9a-f]*\)$/\1/p' "$C_EV"; }
p_types() { cut -f1 "$C_EV" | tr '\n' ' '; }
p_effects() { grep '^effect' "$T/taps"; }
p_captures() { grep -c '^detect read 0$' "$T/taps"; }
p_result_line() { printf 'result\tstatus=error\tcode=%s\ttext=%s\tnext=' "$1" "$(p_enc "$2")"; }
IO_TEXT='The validation response could not be prepared.'
INVARIANT_TEXT="The planner's internal checks did not hold."
REPRESENTATION_TEXT='The required validation response cannot be represented in Protocol 1.'

# p_base FIXTURE PROBES SCRIPT — BASE's owners over FIXTURE, its probes recorded.
p_base() {
  env -i PATH="$P_PATH" HOME="$T/home" TMPDIR="$T/tmp" LANG=en_US.UTF-8 TERM=dumb \
    OMB_FIXTURE="$1" G2_PROBES="$2" SHIM_LOG="$T/shims.log" \
    "$T_BASH" -c 'for m in common ui state sources storage macos asahi; do . "$0/lib/$m.sh"; done
      . "$1"
      eval "$2"' "$T/base" "$TESTS_DIR/gate2-probe-taps.sh" "$3"
}

# Supporting evidence only (behaviour is proved below): every planning owner
# the producer invokes is BASE's, byte for byte.
p_owner() {
  "$T_BASH" -c 'for m in common ui state sources storage macos asahi; do . "$1/lib/$m.sh"; done
    declare -f parse_size plan_init plan_compute plan_validate plan_layout plan_verify _fit _geo_walk geo_finalize \
      mac_detect mac_read_container mac_detect_geometry mac_classify_partition mac_resize_limits mac_blockers \
      mac_plan_compute mac_shared_max asahi_classify asahi_stub_evidence fmt_gb mib_answer
    printf "%s\n" "$STORAGE_CONTRACT" "$ASAHI_ALARM_OS_CHOICE" "$SHARED_MIN_GB"' _ "$1"
}
assert_eq "$(p_owner "$REPO")" "$(p_owner "$T/base")" 'supporting: the planning owners and their constants are BASE byte for byte'

if t_plutil 'Validate BASE planning equivalence and proof'; then
  # --- Probes: hello's, then exactly BASE's planning entry (its survey, the
  # blockers, and the Asahi state only where an install is on the disk). No
  # network reachability, state, saved choices or log are read.
  C_FIX=$FIX/mac-m1pro-1tb-roomy
  : >"$T/hello.probes"
  C_ENV="OMB_SESSION_SCOPES=plan G2_PROBES=$T/hello.probes" c_run hello
  assert_eq "$(c_result) $C_RC" 'done ok 0' 'hello'
  for fx in mac-m1pro-1tb-roomy mac-m1-free-space mac-m1pro-1tb-tight mac-geo-no-limits mac-asahi-installed mac-shared-reserved mac-asahi-complete; do
    C_FIX=$FIX/$fx
    : >"$T/base.probes"
    p_base "$C_FIX" "$T/base.probes" 'mac_detect; mac_plan_compute 0; [ -n "$(mac_blockers)" ] || [ "$MAC_ASAHI_PRESENT" != 1 ] || asahi_classify'
    cat "$T/hello.probes" "$T/base.probes" >"$T/want.probes"
    p_run "$(p_l 120GB)" "$(p_s 10GB)"
    case "$(c_result)" in 'done ok' | 'refused unplannable') ok ;; *) fail "$fx: an answer, $(c_result)" ;; esac
    if cmp -s "$T/probes" "$T/want.probes"; then ok; else fail "$fx: probes are hello's then BASE's planning entry's"; fi
    assert_eq "$(p_captures)" 1 "$fx: one capture"
    assert_eq "$(grep -c 'net\|reachable' "$T/probes")" 0 "$fx: no network probe"
  done
  C_FIX=$FIX/mac-m1pro-1tb-roomy
  p_run "arg	name=size	value=1" "$(p_l 250GB)"
  assert_eq "$(c_result)" 'refused invalid' 'an unknown name'
  if cmp -s "$T/probes" "$T/hello.probes"; then ok; else fail "an unknown name: hello's probes alone"; fi
  assert_eq "$(p_captures)" 0 'an unknown name: no capture'

  # --- Answers: BASE's planner, request by request, in the planner's order.
  while read -r fx linux shared; do
    [ -n "$fx" ] || continue
    C_FIX=$FIX/$fx
    : >"$T/base.probes"
    want=$(p_base "$C_FIX" "$T/base.probes" "mac_detect; mac_plan_compute $shared; plan_layout $((linux * GB)); [ \"\$PLAN_OK\" = 1 ] && printf '%s %s' \"\${PLAN_ANSWER_RESIZE:--}\" \"\$PLAN_ANSWER_OS\"")
    sv=${shared}GB
    [ "$shared" != 0 ] || sv=0
    p_run "$(p_l "${linux}GB")" "$(p_s "$sv")"
    assert_eq "$(c_result)" 'done ok' "$fx $linux/$shared: done"
    got=$(awk -F '\t' '$1 == "answer" { sub(/^value=/, "", $4); v = v sep $4; sep = " " } END { print v }' "$C_EV")
    case "$want" in "- "*) want=${want#- } ;; esac
    assert_eq "$got" "$want" "$fx $linux/$shared: BASE's answers"
    assert_eq "$(awk -F '\t' '$1 == "answer" { printf "%s;", $2 }' "$C_EV")" "$(printf '%s' "$want" | awk '{ for (i = 1; i <= NF; i++) printf "n=%d;", i }')" "$fx $linux/$shared: numbered from 1"
    awk -F '\t' '$1 == "answer" { v = $4; b = $5; sub(/^value=/, "", v); sub(/^bytes=/, "", b); if (v == "max") { if (b != "") print "max with bytes" } else if (v !~ /^[1-9][0-9]*MiB$/ || b != substr(v, 1, length(v) - 3) * 1048576) print "bytes " v " " b }' "$C_EV" >"$T/bad"
    assert_empty_file "$T/bad" "$fx $linux/$shared: bytes are the MiB answer exactly; max has none"
  done <<'EOF'
mac-m1pro-1tb-roomy 250 0
mac-m1pro-1tb-roomy 250 150
mac-m1pro-1tb-roomy 654 0
mac-m1pro-1tb-roomy 54 600
mac-m1-free-space 250 0
mac-m1-free-space 299 0
mac-m1-free-space 400 0
mac-m1-free-space 200 50
mac-m1-free-space 260 50
mac-geo-two-gaps 74 0
mac-geo-two-gaps 54 20
mac-geo-512-sectors 200 50
mac-m2-512 186 0
mac-m2-512 100 80
mac-asahi-resized-only 200 40
EOF

  # --- Q4-plan-validation-basis-v1, rebuilt independently: the documented
  # preimages from BASE's planning owners and the record encoder, byte for
  # byte, and the review basis the SHA-256 of that omb-basis 1 document.
  p_sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{ print $1 }'; }
  while read -r fx linux shared sv; do
    [ -n "$fx" ] || continue
    C_FIX=$FIX/$fx
    rm -rf "$T/kept" "$T/rebuilt"
    mkdir "$T/kept" "$T/rebuilt"
    P_EXTRA="P_KEEP=$T/kept"
    p_run "$(p_l "${linux}GB")" "$(p_s "$sv")"
    P_EXTRA=''
    assert_eq "$(c_result)" 'done ok' "$fx $linux/$shared basis: done"
    grep '^answer	' "$C_EV" >"$T/answers"
    src=$(sed -n '2s/.*	source=\([0-9a-f]*\)	.*/\1/p' "$C_EV")
    env -i PATH="$P_PATH" HOME="$T/home" TMPDIR="$T/tmp" LANG=en_US.UTF-8 TERM=dumb OMB_FIXTURE="$C_FIX" \
      "$T_BASH" -c 'for m in common ui state sources storage macos asahi; do . "$0/lib/$m.sh"; done
        . "$1/lib/records.sh"
        d=$2 linux=$3 shared=$4
        mac_detect
        mac_plan_compute "$shared"
        plan_layout $((linux * GB))
        {
          printf "omb-validate-geometry 1\n"
          rec_line disk size "$GEO_DISK_SIZE" block "$GEO_BLOCK" start "$GEO_USABLE_START" end "$GEO_USABLE_END"
          printf "%s\n" "$GEO_PARTS" | while IFS="|" read -r off size uuid content id role; do
            [ -z "$off" ] || rec_line part guid "$uuid" offset "$off" size "$size" content "$content" role "$role"
          done
          rec_line store guid "$MAC_STORE_UUID"
          rec_line container size "$MAC_CONTAINER_SIZE" free "$MAC_CONTAINER_FREE" floor "$PLAN_MACOS_FLOOR"
          rec_line limits known "$PLAN_LIMITS_KNOWN" value "$MAC_LIMIT_PREF"
          rec_line resize available "$PLAN_RESIZE_OK" end "$PLAN_RZ_END"
          printf "%s\n" "$GEO_GAPS" | while IFS="|" read -r start size pred succ; do
            [ -z "$start" ] || rec_line gap start "$start" size "$size"
          done
        } >"$d/validate.geometry"
        {
          printf "omb-validate-plan 1\n"
          rec_line mode value "$PLAN_MODE"
          rec_line region start "$PLAN_GAP_START" end "$PLAN_GAP_END" pred "$PLAN_GAP_PRED" succ "$PLAN_GAP_SUCC"
          rec_line macos size "$PLAN_MACOS_NEW"
          rec_line linux start "$PLAN_LIN_START" end "$PLAN_LIN_END" root "$PLAN_ROOT"
          rec_line shared start "$PLAN_SHARED_START" end "$PLAN_SHARED_END"
          cat "$5"
        } >"$d/validate.plan"' "$T/base" "$REPO" "$T/rebuilt" "$linux" "$shared" "$T/answers"
    {
      printf 'omb-basis 1\n'
      printf 'basis\taction=plan.save\tproto=1\tactor_uid=%s\thome=%s\tsource=%s\n' "$(cat "$C_FIX/cmd/id_u")" "$(p_enc "$T/tool")" "$src"
      printf 'input\tname=shared_size\tvalue=%s\ninput\tname=linux_size\tvalue=%s\n' $((shared * GB)) $((linux * GB))
      printf 'seen\tkey=geometry\tstate=value\tvalue=\tsha256=%s\tmode=\tlink=\n' "$(p_sha "$T/rebuilt/validate.geometry")"
      printf 'seen\tkey=plan\tstate=value\tvalue=\tsha256=%s\tmode=\tlink=\n' "$(p_sha "$T/rebuilt/validate.plan")"
      printf 'version\tkey=storage_contract\tvalue=%s\n' "$(p_enc "$(sed -n 's/^STORAGE_CONTRACT="\(.*\)"$/\1/p' "$T/base/lib/sources.sh")")"
      printf 'version\tkey=template\tvalue=%s\n' "$(p_enc 'Asahi Alarm Minimal (BTRFS)')"
      printf 'version\tkey=rule\tvalue=Q4-plan-validation-basis-v1\n'
    } >"$T/rebuilt/validate.basis"
    for doc in geometry plan basis; do
      if cmp -s "$T/kept/validate.$doc" "$T/rebuilt/validate.$doc"; then ok; else fail "$fx $linux/$shared: the $doc preimage is the documented one, byte for byte"; fi
    done
    assert_eq "$(p_basis)" "$(p_sha "$T/rebuilt/validate.basis")" "$fx $linux/$shared: the review basis is the SHA-256 of the rebuilt omb-basis 1 document"
    regions='0 3'
    [ "$fx" != mac-m1-free-space ] || regions='1 3'
    assert_eq "$(grep -c '^gap	' "$T/kept/validate.geometry") $(grep -c '^part	' "$T/kept/validate.geometry")" "$regions" "$fx: every partition and free region bound"
  done <<'EOF'
mac-m1pro-1tb-roomy 250 50 50GB
mac-m1-free-space 250 0 0
mac-m1-free-space 400 0 0
EOF

  # --- One capture owns response and basis: the machine changing right after
  # it changes neither; a later request sees the change; nothing re-reads.
  V=$(t_variant mac-m1pro-1tb-roomy)
  cp "$V/cmd/diskutil_info_root" "$T/root.original"
  sed 's#<key>APFSContainerFree</key><integer>700000000000</integer>#<key>APFSContainerFree</key><integer>600000000000</integer>#' "$T/root.original" >"$T/root.less"
  cp "$FIX/mac-m1pro-1tb-tight/cmd/diskutil_info_root" "$T/root.tight"
  C_FIX=$V
  p_run "$(p_l 250GB)" "$(p_s 50GB)"
  control=$(sed '1,2d' "$C_EV") cb=$(p_basis)
  for alt in less tight; do
    P_EXTRA="P_MUTATE=$T/root.$alt"
    p_run "$(p_l 250GB)" "$(p_s 50GB)"
    P_EXTRA=''
    assert_eq "$(grep -c '^hit mutate$' "$T/taps") $(p_captures)" '1 1' "$alt: the machine changed after the one capture"
    assert_eq "$(sed '1,2d' "$C_EV")" "$control" "$alt: response and basis from the capture, not the changed machine"
    if cmp -s "$V/cmd/diskutil_info_root" "$T/root.$alt"; then ok; else fail "$alt: the fixture holds the change"; fi
    p_run "$(p_l 250GB)" "$(p_s 50GB)"
    if [ "$alt" = tight ]; then
      assert_eq "$(c_result)" 'refused unplannable' 'a later request: the changed machine cannot be planned on'
    elif [ "$(c_result)" = 'done ok' ] && [ -n "$(p_basis)" ] && [ "$(p_basis)" != "$cb" ]; then
      ok
    else
      fail 'a later request: the changed geometry, another basis'
    fi
    cp "$T/root.original" "$V/cmd/diskutil_info_root"
    p_run "$(p_l 250GB)" "$(p_s 50GB)"
    assert_eq "$(sed '1,2d' "$C_EV")" "$control" "$alt restored: the control response again"
  done
  # A capture that went wrong is not repaired by a second read.
  P_EXTRA='P_FAULT=hide-list'
  p_run "$(p_l 250GB)" "$(p_s 50GB)"
  P_EXTRA=''
  assert_eq "$(c_result) $C_RC $(c_admits validate)" 'refused unplannable 0 ok' 'a hidden partition list: unplannable, not a repaired plan'
  assert_eq "$(grep -c '^hit hide-list$' "$T/taps") $(p_captures)" '1 1' 'the list was asked for once, in the one capture'
  assert_contains "$(cat "$C_EV")" 'message	level=warn' "the owner's explanation"
  p_run "$(p_l 250GB)" "$(p_s 50GB)"
  assert_eq "$(sed '1,2d' "$C_EV")" "$control" 'the next request reads the machine afresh'

  # --- Publication: exactly the bytes canonical admission validated, from its
  # retained copy, never re-encoded; only header and hello live meanwhile.
  for stage in 0 1; do
    for req in success invalid unplannable; do
      case "$req" in
        success) C_FIX=$V args="$(p_l 250GB)|$(p_s 50.5GB)" ;;
        invalid) C_FIX=$V args="$(p_l 999GB)|$(p_s 50GB)" ;;
        unplannable) C_FIX=$FIX/mac-m1pro-1tb-tight args="$(p_l 250GB)|$(p_s 0)" ;;
      esac
      P_EXTRA="P_STAGE=$stage"
      p_run "${args%%|*}" "${args#*|}"
      P_EXTRA=''
      if cmp -s "$C_EV" "$T/taps.admitted"; then ok; else fail "$req/stage $stage: the spool is the admitted document, byte for byte"; fi
      assert_eq "$(grep -c '^hit leaked$' "$T/taps")" 0 "$req/stage $stage: header and hello alone during the preflight"
      assert_eq "$(grep -c '^hit stage$' "$T/taps")" "$stage" "$req/stage $stage: the staging file was changed after admission"
      assert_eq "$(c_admits validate)" ok "$req/stage $stage: admitted"
    done
  done

  # --- The basis binds the resulting plan: an answer or an extent alone
  # changes it, with geometry and input unchanged.
  C_FIX=$FIX/mac-m1-free-space
  p_run "$(p_l 250GB)" "$(p_s 0)"
  fb=$(p_basis) fa=$(grep '^answer' "$C_EV")
  P_EXTRA='P_FAULT=answer-move'
  p_run "$(p_l 250GB)" "$(p_s 0)"
  assert_eq "$(grep -c '^hit answer-move$' "$T/taps") $(c_result)" '1 done ok' 'answer moved after layout'
  if [ "$(grep '^answer' "$C_EV")" != "$fa" ] && [ -n "$(p_basis)" ] && [ "$(p_basis)" != "$fb" ]; then ok; else fail 'another answer: another basis'; fi
  P_EXTRA='P_FAULT=extent-move'
  p_run "$(p_l 250GB)" "$(p_s 0)"
  assert_eq "$(grep -c '^hit extent-move$' "$T/taps") $(c_result)" '1 done ok' 'extent moved after layout'
  if [ "$(grep '^answer' "$C_EV")" = "$fa" ] && [ -n "$(p_basis)" ] && [ "$(p_basis)" != "$fb" ]; then ok; else fail 'the same answers, another Linux extent: another basis'; fi
  P_EXTRA=''

  # --- Distinct failure classes through the real core, each with its witness:
  # the fixed safe result after hello, no candidate record, no generation.
  L=$(t_variant mac-m1pro-1tb-roomy)
  awk 'BEGIN { s = ""; for (i = 0; i < 5000; i++) s = s "a"; print s }' >"$L/cmd/id_un"
  printf 'staff everyone\n' >"$L/cmd/id_groups"
  K=$(t_variant mac-m1pro-1tb-roomy)
  printf 'al\001ex\n' >"$K/cmd/id_un"
  printf 'staff everyone\n' >"$K/cmd/id_groups"
  while read -r name fixture fault class hit; do
    [ -n "$name" ] || continue
    case "$fixture" in long) C_FIX=$L ;; control) C_FIX=$K ;; *) C_FIX=$FIX/$fixture ;; esac
    case "$fault" in
      -) P_EXTRA='' ;;
      dir:*) P_EXTRA="P_DIR=${fault#dir:}" ;;
      *) P_EXTRA="P_FAULT=$fault" ;;
    esac
    p_run "$(p_l 250GB)" "$(p_s 50GB)"
    P_EXTRA=''
    case "$class" in
      io) text=$IO_TEXT ;;
      invariant) text=$INVARIANT_TEXT ;;
      representation) text=$REPRESENTATION_TEXT ;;
    esac
    assert_eq "$(c_result) $C_RC" "error $class 0" "$name: error $class"
    assert_eq "$(c_admits validate)" ok "$name: an admissible response"
    assert_eq "$(p_types)" 'omb-res 1 hello result ' "$name: hello and the result alone"
    assert_eq "$(sed -n '$p' "$C_EV")" "$(p_result_line "$class" "$text")" "$name: the fixed safe result"
    if [ "$hit" = - ]; then
      assert_eq "$(grep -c '^hit' "$T/taps")" 0 "$name: no seam, the owner's own data"
    else
      assert_eq "$(grep -c "^hit $hit\$" "$T/taps")" 1 "$name: the seam was hit once"
    fi
    assert_eq "$(p_captures)" 1 "$name: one capture, no retry"
    assert_eq "$(p_effects)" '' "$name: no effect reached"
    assert_not_contains "$C_OUT" aaaaaaaa "$name: no candidate value echoed"
  done <<'EOF'
geometry-hash mac-m1pro-1tb-roomy geometry-hash io geometry-hash
basis-hash mac-m1pro-1tb-roomy hash io hash
basis-write mac-m1pro-1tb-roomy dir:validate.basis io dir validate.basis
stage-write mac-m1pro-1tb-roomy dir:validate.response io dir validate.response
prefix-read mac-m1pro-1tb-roomy prefix-read io prefix-read
admission-machinery mac-m1pro-1tb-roomy admit-exec io admit-exec
retained-copy mac-m1pro-1tb-roomy retained-copy io retained-copy
publication-preparation mac-m1pro-1tb-roomy publish-prep io publish-prep
unplannable-stage-write mac-m1pro-1tb-tight dir:validate.response io dir validate.response
plan-verify mac-m1pro-1tb-roomy verify invariant verify
size-outcome mac-m1pro-1tb-roomy size-outcome invariant size-outcome
linux-verdict mac-m1pro-1tb-roomy verdict invariant verdict
long-explanation long - representation -
control-byte-explanation control - representation -
long-explanation-unproved long admit-exec io admit-exec
EOF
  # A failed append after publication began is an incomplete transport: no
  # second result is written.
  C_FIX=$FIX/mac-m1pro-1tb-roomy P_EXTRA='P_FAULT=transport'
  p_run "$(p_l 250GB)" "$(p_s 50GB)"
  P_EXTRA=''
  assert_eq "$(grep -c '^hit transport$' "$T/taps")" 1 'transport: the append failed part way'
  assert_eq "$(c_result)" '' 'transport: no result, so the answer is unknown'
  assert_eq "$(sed -n '3p' "$C_EV" | cut -f1)" answer 'transport: the first published record only'
  assert_eq "$(wc -l <"$C_EV" | tr -d ' ')" 3 'transport: header, hello and one record'

  # --- Zero persistence for every outcome family: no state, record, lock,
  # log, plan, saved choice, effect, installer or temporary residue.
  mkdir -p "$T/state"
  chmod 700 "$T/state"
  printf '%s\n' cfg_user=alex cfg_host=omarchy cfg_linux=600 cfg_shared=300 planned_at=2026-09-01T00:00:00Z >"$T/state/state.env"
  chmod 600 "$T/state/state.env"
  : >"$T/record"
  while read -r family fixture fault linux shared want; do
    [ -n "$family" ] || continue
    case "$fixture" in long) C_FIX=$L ;; variant) C_FIX=$V ;; *) C_FIX=$FIX/$fixture ;; esac
    before_state=$(t_snapshot "$T/state") before_fixture=$(t_snapshot "$C_FIX") before_home=$(t_snapshot "$T/home")
    P_EXTRA=''
    [ "$fault" = - ] || P_EXTRA="P_FAULT=$fault"
    for ceiling in read plan act; do
      P_EXTRA="$P_EXTRA OMB_SESSION_INTENT=$ceiling"
      p_run "$(p_l "$linux")" "$(p_s "$shared")"
      P_EXTRA=${P_EXTRA% OMB_SESSION_INTENT=*}
      assert_eq "$(c_result)" "$want" "$family/$ceiling: $want"
      assert_eq "$(grep -c '^generation' "$C_EV")" 0 "$family/$ceiling: no generation"
      assert_eq "$(p_effects)" '' "$family/$ceiling: no effect reached"
      assert_eq "$(t_snapshot "$T/state")" "$before_state" "$family/$ceiling: state unchanged"
      assert_eq "$(t_snapshot "$C_FIX")" "$before_fixture" "$family/$ceiling: the machine unchanged"
      assert_eq "$(t_snapshot "$T/home")" "$before_home" "$family/$ceiling: home unchanged"
      assert_empty_file "$T/record" "$family/$ceiling: nothing run"
      assert_empty_file "$T/shims.log" "$family/$ceiling: no sudo, installer, package, boot or network command"
      assert_eq "$(find "$T" -maxdepth 1 -name 'omarchy-bootstrap.*')" '' "$family/$ceiling: request scratch removed"
      assert_eq "$(find "$SESS" -name '*.core' -o -name '*.worker-*')" '' "$family/$ceiling: no identity residue"
    done
    P_EXTRA=''
  done <<'EOF'
success variant - 600GB 0 done ok
invalid variant - 600GB 300GB refused invalid
unplannable mac-m1pro-1tb-tight - 250GB 0 refused unplannable
io variant hash 250GB 50GB error io
invariant variant verify 250GB 50GB error invariant
representation long - 250GB 50GB error representation
EOF
  rm -rf "$T/state"
fi
t_done test-gate2-validate-proof
