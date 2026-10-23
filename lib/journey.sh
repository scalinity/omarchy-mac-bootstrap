# shellcheck shell=bash
# Ten stages and the final report. All observations reuse the baseline readers;
# the baseline codes and a checked bundle establish recorded remote progress.

# shellcheck source=/dev/null # avoid recursively linting the core through its read adapter
if ! declare -F core_mod_load >/dev/null; then
  . "${BASH_SOURCE[0]%/*}/core.sh" || _omb_unloaded core
fi

J_NAMES='survey profile resolve plan asahi omarchy shared restore verify done'

journey_init() {
  local n=0 name
  J_STATE=() J_BASIS=() J_BY=() J_DETAIL=()
  for name in $J_NAMES; do
    J_STATE[n]=todo J_BASIS[n]=machine J_BY[n]='' J_DETAIL[n]=''
    n=$((n + 1))
  done
}

journey_set() {
  J_STATE[$1]=$2 J_BASIS[$1]=${3:-machine} J_BY[$1]=${4:-} J_DETAIL[$1]=${5:-}
}

# The check does not survey either system or read records. These stages say
# exactly why progress is unavailable, without turning identity into progress.
journey_check_records() {
  local name
  for name in $J_NAMES; do
    rec_line stage name "$name" state blocked basis machine by '' at '' detail 'not checked: startup check reads identity only' || return 1
  done
}

journey_doctor_counts() (
  # shellcheck disable=SC2317,SC2329 # cmd_doctor calls its presentation sink
  ui_tag() { :; }
  DOC_PASS=0 DOC_WARN=0 DOC_FAIL=0
  # Only Doctor's closed counters feed stages/report. Its text and diagnostic
  # stderr are not protocol data (an unreadable macOS resize limit already
  # produces the owner's warning finding).
  cmd_doctor >/dev/null 2>/dev/null
  case $? in 0 | 1) ;; *) return 1 ;; esac
  printf '%s %s %s\n' "$DOC_PASS" "$DOC_WARN" "$DOC_FAIL"
)

# qfy owns admission and identity. Never inspect its files or infer its state.
journey_qualification() {
  J_QFY=unavailable J_QWHY='not checked: qualification is not available'
  if declare -F qfy_status_read >/dev/null; then
    QFY_STATE=blocked QFY_WHY='qualification could not be read'
    # The interface promises these two values, not an exit-status meaning.
    qfy_status_read || :
    case "$QFY_STATE" in
      not-started | waiting-for-linux | waiting-for-macos | passed | failed | blocked)
        J_QFY=$QFY_STATE J_QWHY=$QFY_WHY ;;
      *) J_QFY=blocked J_QWHY='qualification returned an unknown state' ;;
    esac
  fi
}

# Before installation the saved plan must still fit. After installation its
# record establishes completion; the report separately checks the current disk.
journey_mac_plan() {
  J_PLAN=todo J_PLAN_WHY='no saved plan'
  [ -n "$(state_get cfg_linux)" ] || return 0
  J_PLAN=blocked J_PLAN_WHY='the saved plan does not match the disk'
  cfg_field_ok linux "${CFG_linux:-}" || return 0
  if [ "$GEO_OK" != 1 ]; then J_PLAN_WHY=${GEO_ERR:-the partition layout could not be read}; return 0; fi
  if [ "$MAC_ASAHI_PRESENT" = 0 ]; then
    mac_plan_compute "${CFG_shared:-0}"
    plan_layout $((CFG_linux * GB))
    if [ "$PLAN_OK" = 1 ]; then
      if [ "${CFG_shared:-0}" = 0 ]; then
        J_PLAN='done' J_PLAN_WHY='saved plan invariants hold on the current disk'
      elif shared_intent_load && [ "$INT_macos_after" = "$PLAN_MACOS_NEW" ] &&
        [ "$INT_linux_answer" = "$PLAN_ANSWER_OS" ] && [ "$INT_shared_request" = "$PLAN_SHARED" ] &&
        [ "$INT_region_start" = "$PLAN_GAP_START" ] && [ "$INT_region_end" = "$PLAN_GAP_END" ] &&
        [ "$INT_disk_size" = "$GEO_DISK_SIZE" ]; then
        J_PLAN='done' J_PLAN_WHY='saved plan invariants and Shared extents hold on the current disk'
      fi
    else J_PLAN_WHY=$PLAN_ERR; fi
  else
    if [ "$ASAHI_STATE" = installed ]; then
      J_PLAN='done' J_PLAN_WHY='saved plan; Asahi installation is installed'
    fi
  fi
}

journey_profile() {
  core_mod_load profile || return 1
  PROF_LOADED=''
  prof_load || return 1
  case "$PROF_STATE" in
    not-scanned)
      journey_set 1 skipped machine '' 'no migration'
      journey_set 2 skipped machine '' 'no migration'
      journey_set 7 skipped machine '' 'no migration' ;;
    invalid)
      journey_set 1 blocked machine '' "$PROF_WHY"
      journey_set 2 blocked machine '' 'a valid saved profile is required' ;;
    scanned) ;;
    selected | saved)
      journey_set 1 'done'
      # Evaluate included items only, using the profile owner's view. Excluded
      # items and explicit skips are not unresolved work.
      if LC_ALL=C awk -F '\t' '($19 == "include" || $25 == "include") && $13 !~ /^(resolved|unsupported)$/ { bad=1 } END { exit bad }' "$PROF_DIR/view"; then
        journey_set 2 'done'
      else journey_set 2 blocked machine '' 'an included item is not resolved or unsupported'; fi
      core_mod_load export || return 1
      local last
      last=$(state_get export_last)
      if [ -n "$last" ]; then
        if bndl_check "$last"; then journey_set 7 'done'
        else journey_set 7 blocked machine '' "$BNDL_WHY"; fi
      fi
      ;;
  esac
}

journey_read() {
  local counts=${1:-} p w f n=0 pending=0 current=0 receipt token_loaded due
  core_mod_load qualify || return 1
  journey_init
  cfg_load
  J_PLAN=todo J_PLAN_WHY='' J_RWHY='restore has not been checked'
  case "$OMB_PLATFORM" in
    macos)
      mac_detect
      asahi_classify
      shared_mac_state
      journey_set 0 'done'
      journey_profile || return 1
      journey_mac_plan
      journey_set 3 "$J_PLAN" machine '' "$J_PLAN_WHY"
      case "$ASAHI_STATE" in
        installed) journey_set 4 'done' ;;
        none | resized-only | pending-first-boot | installed-unverified) ;;
        *) journey_set 4 blocked machine '' "${ASAHI_WHY:-the Asahi installation cannot be classified}" ;;
      esac
      receipt=${SHARED_TYPED_RECEIPT:-$(state_get shared_linux_done)}
      if shared_receipt_ok "$receipt"; then journey_set 5 'done' recorded linux; fi
      if [ "$SHARED_STATE" = created ]; then journey_set 6 'done'; fi
      if [ "$SHARED_STATE" = blocked ]; then journey_set 6 blocked machine '' "$SHARED_WHY"; fi
      ;;
    linux)
      lx_detect
      [ -n "${CFG_user:-}" ] || cfg_load "$STATE_SYSTEM_FILE"
      # The token's saved choices are revalidated by cfg_load. Its plan id
      # establishes the macOS survey/plan only, never a profile or a restore.
      token_loaded=$(state_get phase1_choices_loaded_at)
      [ -n "$token_loaded" ] || token_loaded=$(state_get phase1_choices_loaded_at '' "$STATE_SYSTEM_FILE")
      if [ -n "$token_loaded" ] && [ -n "${CFG_plan:-}" ]; then
        journey_set 0 'done' recorded macos
        journey_set 3 'done' recorded macos
      else
        journey_set 0 blocked machine '' 'not checked: no resume token with a plan id'
        journey_set 3 blocked machine '' 'not checked: macOS plan is unavailable'
      fi
      journey_set 1 todo machine '' 'chosen on macOS'
      journey_set 2 todo machine '' 'chosen on macOS'
      if [ "$LX_APPLE" = 1 ] && lx_is_arch; then journey_set 4 'done'
      else journey_set 4 blocked machine '' 'Asahi Linux is not identified'; fi
      if lx_setup_complete; then journey_set 5 'done'; fi
      shared_lx_state
      if [ "$SHARED_STATE" = ready ]; then
        shared_lx_access
        if [ "$SH_MOUNT" = verified ]; then journey_set 6 'done'
        else journey_set 6 blocked machine '' "${SH_MOUNT_WHY:-Shared is not mounted and verified}"; fi
      elif [ "$SHARED_STATE" = blocked ]; then journey_set 6 blocked machine '' "$SHARED_WHY"; fi
      core_mod_load restore || return 1
      if _rst_load >/dev/null 2>&1; then
        if [ -n "$RST_BUNDLE" ]; then
          journey_set 1 'done' recorded macos
          journey_set 2 'done' recorded macos
          J_RWHY=${RST_WHY:-$RST_COUNTS}
          if [ "$RST_STATE" = complete ]; then journey_set 7 'done'
          elif [ "$RST_STATE" = blocked ]; then journey_set 7 blocked machine '' "${RST_WHY:-restore has blocked items}"; fi
        else J_RWHY=${RST_WHY:-no verified bundle is available}; fi
      fi
      ;;
    *) return 1 ;;
  esac
  if [ "$SHARED_STATE" = off ] && [ "${CFG_shared:-0}" = 0 ]; then
    journey_set 6 skipped machine '' 'Shared is not planned'
  fi
  if [ -z "$counts" ]; then counts=$(journey_doctor_counts) || return 1; fi
  IFS=' ' read -r p w f <<EOF_COUNTS
$counts
EOF_COUNTS
  J_DOC_PASS=$p J_DOC_WARN=$w J_DOC_FAIL=$f
  journey_qualification
  if [ "$f" != 0 ]; then journey_set 8 blocked machine '' 'doctor has FAIL findings'
  elif [ "${J_STATE[6]}" = skipped ]; then journey_set 8 'done'
  else
    case "$J_QFY" in
      passed) journey_set 8 'done' ;;
      failed | blocked | unavailable) journey_set 8 blocked machine '' "${J_QWHY:-$J_QFY}" ;;
    esac
  fi
  # The first unfinished stage due here owns current. A blocker keeps its
  # state and stops later stages becoming current. Remote work stays todo.
  while [ "$n" -lt 9 ]; do
    case "${J_STATE[n]}" in
      done | skipped) ;;
      *)
        due=0
        case "$OMB_PLATFORM:$n" in
          macos:0 | macos:1 | macos:2 | macos:3 | macos:4 | macos:6 | macos:7 | macos:8 | linux:5 | linux:6 | linux:7 | linux:8) due=1 ;;
        esac
        case "$OMB_PLATFORM:$n:$J_QFY" in macos:8:waiting-for-linux | linux:8:waiting-for-macos | linux:8:not-started) due=0 ;; esac
        if [ "$current" = 0 ] && [ "$due" = 1 ]; then
          if [ "${J_STATE[n]}" = todo ]; then J_STATE[n]=current; fi
          current=1
        fi
        pending=$((pending + 1)) ;;
    esac
    case "${J_STATE[n]}:$OMB_PLATFORM:$n" in
      blocked:* | skipped:* | todo:linux:1 | todo:linux:2) ;;
      *) J_DETAIL[n]='' ;;
    esac
    n=$((n + 1))
  done
  if [ "$pending" = 0 ] && [ "$OMB_PLATFORM" = macos ]; then journey_set 9 'done'; fi
}

journey_records() {
  local n=0 name
  for name in $J_NAMES; do
    rec_line stage name "$name" state "${J_STATE[n]}" basis "${J_BASIS[n]}" by "${J_BY[n]}" at '' detail "${J_DETAIL[n]}" || return 1
    n=$((n + 1))
  done
}

cmd_journey_status() {
  local n=0 name by detail
  cmd_status || return 1
  journey_read || return 1
  ui_section Journey
  for name in $J_NAMES; do
    by='' detail=''
    if [ "${J_BASIS[n]}" = recorded ]; then
      by=${J_BY[n]}
      [ "$by" != macos ] || by=macOS
      by=" (recorded by $by)"
    fi
    [ -z "${J_DETAIL[n]}" ] || detail=": ${J_DETAIL[n]}"
    _p '   %s: %s%s%s\n' "$name" "${J_STATE[n]}" "$by" "$detail"
    n=$((n + 1))
  done
}

journey_report_row() {
  J_REPORT_KEY+=("$1") J_REPORT_STATE+=("$2") J_REPORT_LABEL+=("$3") J_REPORT_WHY+=("$4")
  case "$2" in
    pass) J_PASS=$((J_PASS + 1)) ;;
    warn) J_WARN=$((J_WARN + 1)) ;;
    fail) J_FAIL=$((J_FAIL + 1)) ;;
    not-checked) J_NOT_CHECKED=$((J_NOT_CHECKED + 1)) ;;
  esac
}

# Called after journey_read, or by Health with the one captured Doctor's
# counters. Health's doctor projection keeps its original capture and counts.
journey_report_build() {
  local st why counts v k f p extra rows
  J_REPORT_KEY=() J_REPORT_STATE=() J_REPORT_LABEL=() J_REPORT_WHY=()
  J_PASS=0 J_WARN=0 J_FAIL=0 J_NOT_CHECKED=0
  if [ "$OMB_PLATFORM" = macos ]; then
    st=pass
    if [ "$DEV_TIER" != supported ]; then st=warn; fi
    if [ "$MAC_APPLE_SILICON" != 1 ] || [ "$MAC_DISK_INTERNAL" != true ] || ! ver_ge "$MAC_OS_VERSION" "$ASAHI_MIN_MACOS"; then st=fail; fi
    journey_report_row mac "$st" 'the Mac' "$MAC_MODEL_ID; $MAC_CHIP; memory=$MAC_MEM_BYTES bytes; disk=$MAC_DISK_SIZE bytes; macOS $MAC_OS_VERSION"
    st=warn
    case "$J_PLAN" in done) st=pass ;; blocked) st=fail ;; esac
    case "$J_PLAN_WHY" in "not checked:"*) st=not-checked ;; esac
    why=$J_PLAN_WHY
    if [ "$ASAHI_STATE" = installed ] && [ "$J_PLAN" = 'done' ]; then
      if [ "${CFG_shared:-0}" = 0 ]; then
        st=not-checked why='the pre-install extents are not saved without Shared'
      else
        case "$SHARED_STATE" in
          awaiting-linux-completion | awaiting-macos-creation | created) st=pass why='installed layout matches the saved Shared extents' ;;
          *) st=fail why=$SHARED_WHY ;;
        esac
      fi
    fi
    journey_report_row disk "$st" disk "$why"
  else
    journey_report_row mac not-checked 'the Mac' 'macOS and its hardware survey cannot be read from Linux'
    journey_report_row disk not-checked disk 'the saved APFS plan and its exact extents cannot be read from Linux'
  fi
  case "$SHARED_STATE" in
    off) st=not-checked why='Shared is not planned' ;;
    created | ready)
      st=pass why=$SHARED_WHY
      if [ "$OMB_PLATFORM" = linux ]; then
        shared_lx_access
        if [ "$SH_MOUNT" != verified ]; then st=fail why=${SH_MOUNT_WHY:-Shared is not mounted and verified}; fi
      fi ;;
    blocked) st=fail why=$SHARED_WHY ;;
    *) st=warn why=$SHARED_WHY ;;
  esac
  journey_report_row shared "$st" Shared "$why"
  if [ "$OMB_PLATFORM" = linux ]; then
    st=warn why="Omarchy $LX_OMARCHY_STATE; version=${LX_OMARCHY_VERSION:-unknown}; encryption=$LX_ENC_STATE"
    if lx_setup_complete && [ "$LX_ENC_STATE" = complete ]; then st=pass; fi
    if [ "$LX_ENC_STATE" = probe-failed ]; then st=fail; fi
    journey_report_row linux "$st" Linux "$why"
  else journey_report_row linux not-checked Linux 'the encrypted Linux root and Omarchy completion signals cannot be read from macOS'; fi
  st=warn why=${J_QWHY:-$J_QFY}
  if [ "${J_STATE[6]}" = skipped ]; then st=not-checked why='Shared is not planned; the round trip is not run'
  else
    case "$J_QFY" in passed) st=pass ;; failed) st=fail ;; unavailable) st=not-checked ;; esac
  fi
  journey_report_row qualification "$st" qualification "$why"
  if [ "$OMB_PLATFORM" = macos ]; then
    journey_report_row restore not-checked 'restore and AI tools' 'Linux restore destinations and AI tools cannot be read from macOS'
  else
    st=not-checked why=$J_RWHY
    if counts=$(rst_status_counts); then
      IFS=' ' read -r v k f p extra <<EOF_RESTORE
$counts
EOF_RESTORE
      if [ -z "$extra" ] && _uint "$v" && _uint "$k" && _uint "$f" && _uint "$p"; then
        st=pass why="restore: verified=$v kept=$k failed=$f pending=$p"
        if [ "$f" != 0 ]; then st=fail
        elif [ "$p" != 0 ]; then st=warn; fi
      else st=warn why='Restore counts could not be read.'; fi
    fi
    rows=$(agent_health_rows) || return 1
    if printf '%s\n' "$rows" | awk -F '\t' '$4 == "col=fail" { found=1 } END { exit !found }'; then st=fail
    elif [ "$st" != fail ] && printf '%s\n' "$rows" | awk -F '\t' '$4 == "col=warn" { found=1 } END { exit !found }'; then st=warn; fi
    why="$why; AI health checked for Claude Code, Codex and OpenCode"
    journey_report_row restore "$st" 'restore and AI tools' "$why"
  fi
  st=pass
  if [ "$J_DOC_FAIL" != 0 ]; then st=fail
  elif [ "$J_DOC_WARN" != 0 ]; then st=warn; fi
  journey_report_row doctor "$st" doctor "$J_DOC_PASS passed; $J_DOC_WARN warnings; $J_DOC_FAIL failures"
  journey_report_row recovery not-checked 'Recovery boot, a current backup' 'this tool cannot see Recovery boot or verify a current backup'
  J_VERDICT=pass
  if [ "$J_FAIL" != 0 ]; then J_VERDICT=fail
  elif [ "$J_WARN" != 0 ]; then J_VERDICT=warn; fi
}

journey_report_records() {
  local n=0
  while [ "$n" -lt "${#J_REPORT_KEY[@]}" ]; do
    rec_line row kind report key "${J_REPORT_KEY[n]}" col "${J_REPORT_STATE[n]}" col "${J_REPORT_LABEL[n]}" col "${J_REPORT_WHY[n]}" || return 1
    n=$((n + 1))
  done
}

cmd_report() {
  local n=0
  journey_read || return 1
  journey_report_build || return 1
  ui_section Report 'fresh read; not-checked rows do not change the verdict'
  while [ "$n" -lt "${#J_REPORT_KEY[@]}" ]; do
    _p '   %-13s %-29s %s\n' "${J_REPORT_STATE[n]}" "${J_REPORT_LABEL[n]}" "${J_REPORT_WHY[n]}"
    n=$((n + 1))
  done
  ui_kv Verdict "$J_VERDICT"
  ui_kv Counts "pass=$J_PASS warn=$J_WARN fail=$J_FAIL not-checked=$J_NOT_CHECKED"
}
