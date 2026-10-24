# shellcheck shell=bash
# The Shared round trip. Records are input; only the baseline identifies the
# mount. All Shared writes are run calls, confined to the fixed qualify tree.
# shellcheck disable=SC2034,SC2153,SC2154,SC2317,SC2329 # row hooks and run's filesystem helpers
QFY_STREAM_BYTES=4296015889

_qfy_schema() {
  case "$1" in
    family) REC_HDR='omb-qualify 1' REC_MAX_BYTES=65536 REC_MAX_RECS=2 REC_SEALED=1 REC_ORDER=$3 ;;
    spec)
      [ "$2" = "$3" ] || return 1
      case "$3" in
        macos) REC_SPEC='schema:uint plan:hex64 shared_guid:bytes os:enum(macos) commit:hex40? at:utc bytes:uint sha256:hex64 name:bytes*' ;;
        linux) REC_SPEC='schema:uint previous:hex64 partuuid:bytes majmin:id os:enum(linux) commit:hex40? at:utc read_sha256:hex64? bytes:uint sha256:hex64 name_seen:bytes* name_written:bytes* name_collision:bytes* kernel:bytes dirty:enum(0|1|unknown)' ;;
        result) REC_SPEC='schema:uint previous:hex64 os:enum(macos) commit:hex40? at:utc data_ok:bool return_ok:bool names_ok:bool verdict:enum(passed|failed) reason:id?' ;;
      esac ;;
    card) REC_CARD=1 ;;
    unique) REC_UKEYS='' ;;
    *) return 1 ;;
  esac
}
_recx_qmac() { _qfy_schema "$1" "${2:-}" macos; }
_recx_qlinux() { _qfy_schema "$1" "${2:-}" linux; }
_recx_qresult() { _qfy_schema "$1" "${2:-}" result; }
_qfy_block() { QFY_STATE=blocked QFY_WHY=$1 QFY_CAN_RUN=0; return 1; }
# What a refused, foreign or torn file needs: that one file gone, by hand.
_qfy_clear() { printf 'Delete %s from omarchy-mac-bootstrap/qualify on Shared, then run qualify again.' "$1"; }
_qfy_get() {
  _rec_field_raw "$2" "$3" || return 1
  _rec_dec_into "$1" "$REC_RAW"
}
# Lists stay canonically encoded, so even a newline in a name is data.
_qfy_list() {
  local field
  local -a fields=()
  IFS=$'\t' read -r -a fields <<<"$1"
  for field in "${fields[@]}"; do
    [ "${field%%=*}" != "$2" ] || printf '%s\n' "${field#*=}"
  done
}
# Every name in $1 is among those in $2, byte for byte (case and normalisation
# included): the names a step created must be there. Entries it did not
# create are not part of the verdict.
_qfy_names_present() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $'\n'"$2"$'\n' in *$'\n'"$line"$'\n'*) ;; *) return 1 ;; esac
  done <<<"$1"
}
_qfy_fixed_names() {
  QFY_NAMES=(ascii.txt $'\303\251' $'e\314\201' Case case "$(printf '%0255d' 0 | tr 0 n)" 'with space')
}
_qfy_hash() {
  if [ "$OMB_PLATFORM" = linux ]; then sha256sum; else shasum -a 256; fi
}
_qfy_sha() {
  local out
  if [ ! -f "$1" ] || [ -L "$1" ]; then return 1; fi
  out=$(_qfy_hash <"$1") || return 1
  QFY_SHA=${out%% *}
  _whole "$QFY_SHA" '^[0-9a-f]{64}$'
}
_qfy_bytes() {
  QFY_BYTES=$QFY_STREAM_BYTES
  if [ -n "${OMB_TEST_QUAL_BYTES:-}" ]; then
    if [ "$EUID" = 0 ] || [ -z "${OMB_FIXTURE:-}" ]; then return 1; fi
    _whole "$OMB_TEST_QUAL_BYTES" '^[1-9][0-9]{0,6}$' || return 1
    QFY_BYTES=$OMB_TEST_QUAL_BYTES
  fi
}
_qfy_identity() {
  local mp body
  QFY_SHARED='' QFY_DIR='' QFY_GUID='' QFY_PLAN='' QFY_SIZE=0
  cfg_load
  case "$OMB_PLATFORM" in
    macos)
      mac_detect
      shared_mac_state
      if [ "$SHARED_STATE" != created ] || [ -z "$SHARED_MOUNT" ]; then _qfy_block "Shared is not mounted and verified: ${SHARED_WHY:-$SHARED_STATE}"; return 1; fi
      mp=$SHARED_MOUNT QFY_GUID=$SHARED_UUID QFY_SIZE=$SHARED_SIZE
      # The baseline stores 16 digits of SHA-256 over its canonical body,
      # without the final LF. Keep that identity and retain all 64 here.
      body=$(sed '/^digest=/d' "$OMB_STATE_DIR/$SHARED_INTENT_FILE") || { _qfy_block 'The plan body could not be read.'; return 1; }
      QFY_PLAN=$(sha256_str "$body")
      if ! _whole "$QFY_PLAN" '^[0-9a-f]{64}$' || [ "${QFY_PLAN:0:16}" != "$INT_digest" ]; then
        _qfy_block 'The full plan digest could not be read.'; return 1
      fi ;;

    linux)
      if [ -z "${CFG_user:-}" ] && [ -f "$STATE_SYSTEM_FILE" ]; then cfg_load "$STATE_SYSTEM_FILE"; fi
      lx_detect
      shared_lx_state
      [ "$SHARED_STATE" = ready ] || { _qfy_block "Shared is not ready: ${SHARED_WHY:-$SHARED_STATE}"; return 1; }
      shared_lx_access
      [ "$SH_MOUNT" = verified ] || { _qfy_block "Shared mount is not verified: ${SH_MOUNT_WHY:-$SH_MOUNT}"; return 1; }
      mp=$SHARED_MNT QFY_GUID=$SH_PARTUUID QFY_PLAN=${CFG_plan:-} QFY_SIZE=$SH_SIZE ;;
    *) _qfy_block 'Qualification needs macOS or Linux.'; return 1 ;;
  esac
  QFY_SHARED="$QFY_GUID at $mp"
  QFY_MOUNT=$(sys_path "$mp")
  QFY_DIR=$QFY_MOUNT/omarchy-mac-bootstrap/qualify
  if [ ! -d "$QFY_MOUNT" ] || [ -L "$QFY_MOUNT" ]; then
    _qfy_block 'The verified Shared mount is not accessible.'; return 1
  fi
}
_qfy_paths() {
  local path side name
  for path in "$QFY_MOUNT/omarchy-mac-bootstrap" "$QFY_DIR" "$QFY_DIR/names-macos" "$QFY_DIR/names-linux"; do
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then _qfy_block "${path#"$QFY_MOUNT"/} is a link or not a folder. Delete it from Shared, then run qualify again."; return 1; fi
  done
  for name in macos.omb linux.omb result.omb macos.omb.tmp linux.omb.tmp result.omb.tmp data.macos.bin data.linux.bin; do
    path=$QFY_DIR/$name
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then _qfy_block "$name is a link or not a plain file. $(_qfy_clear "$name")"; return 1; fi
  done
  _qfy_fixed_names
  for side in macos linux; do
    for name in "${QFY_NAMES[@]}"; do
      path=$QFY_DIR/names-$side/$name
      if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then _qfy_block "names-$side/$name is a link or not a plain file. $(_qfy_clear "names-$side/$name")"; return 1; fi
    done
  done
}
# Current shell interface for journey/report. Never opens Shared until the
# baseline's mount check passes. Admission uses only the private run scratch.
# The state is what the files on Shared say; whether the due step fits is a
# separate read of free space, left out of the judge's (qfy_action_judge).
qfy_status_read() {
  local OMB_PERSIST=0 verdict why
  _qfy_state_read
  if [ "$QFY_CAN_RUN" = 1 ] && [ "$QFY_DUE" != 3 ]; then
    _qfy_bytes || { _qfy_block 'The qualification stream seam is invalid.'; return 0; }
    verdict=$QFY_STATE why=$QFY_WHY
    if ! _qfy_space preview; then
      [ "$QFY_STATE" = blocked ] || _qfy_block 'The old stream allocation could not be read.'
      # A recorded verdict stays whatever space is left later; only the
      # offer to run again carries the refusal.
      case "$verdict" in
        passed | failed) QFY_RERUN_WHY=$QFY_WHY QFY_STATE=$verdict QFY_WHY=$why ;;
      esac
      return 0
    fi
  fi
  return 0
}
_qfy_state_read() {
  local OMB_PERSIST=0
  local family file var schema plan guid previous size part verdict rec
  QFY_STATE=not-started QFY_WHY='' QFY_DUE=1 QFY_CAN_RUN=0 QFY_RERUN_WHY=''
  QFY_M='' QFY_L='' QFY_R='' QFY_M_SHA='' QFY_L_SHA='' QFY_R_SHA=''
  _qfy_identity || return 0
  _qfy_paths || return 0
  if [ "$OMB_PLATFORM" = linux ]; then
    sys_has sha256sum || { _qfy_block 'sha256sum is required.'; return 0; }
  else
    sys_has shasum || { _qfy_block 'shasum is required.'; return 0; }
  fi
  # Admit every existing document before binding any of its fields.
  for file in macos linux result; do
    case "$file" in macos) family=qmac var=M ;; linux) family=qlinux var=L ;; result) family=qresult var=R ;; esac
    if [ -e "$QFY_DIR/$file.omb" ]; then
      if ! rec_admit_file "$family" - "$QFY_DIR/$file.omb"; then _qfy_block "$file.omb refused: $REC_REASON. $(_qfy_clear "$file.omb")"; return 0; fi
      printf -v "QFY_$var" '%s' "${REC_L[0]}"
      _qfy_sha "$REC_TMP/doc" || { _qfy_block 'A record digest could not be read.'; return 0; }
      printf -v "QFY_${var}_SHA" '%s' "$QFY_SHA"
    fi
  done
  for file in macos linux result; do
    case "$file" in macos) rec=$QFY_M ;; linux) rec=$QFY_L ;; result) rec=$QFY_R ;; esac
    [ -n "$rec" ] || continue
    _qfy_get schema "$rec" schema
    [ "$schema" = 1 ] || { _qfy_block "$file.omb has a schema this tool does not read. $(_qfy_clear "$file.omb")"; return 0; }
  done
  if [ -n "$QFY_M" ]; then
    _qfy_get plan "$QFY_M" plan
    _qfy_get guid "$QFY_M" shared_guid
    guid=$(printf '%s' "$guid" | tr 'A-F' 'a-f')
    if [ "$guid" != "$(printf '%s' "$QFY_GUID" | tr 'A-F' 'a-f')" ]; then _qfy_block "macos.omb belongs to another Shared partition. $(_qfy_clear macos.omb)"; return 0; fi
    if [ "$OMB_PLATFORM" = macos ]; then
      [ "$plan" = "$QFY_PLAN" ] || { _qfy_block "macos.omb belongs to another plan. $(_qfy_clear macos.omb)"; return 0; }
    else
      if ! _whole "$QFY_PLAN" '^[0-9a-f]{8}$' || [ "${plan:0:8}" != "$QFY_PLAN" ]; then
        _qfy_block "macos.omb does not begin with the token plan id. $(_qfy_clear macos.omb)"; return 0
      fi
    fi
    _qfy_bytes || { _qfy_block 'The qualification stream seam is invalid.'; return 0; }
    _qfy_get size "$QFY_M" bytes
    [ "$size" = "$QFY_BYTES" ] || { _qfy_block "macos.omb records a stream size this run does not use. $(_qfy_clear macos.omb)"; return 0; }
  fi
  if [ -n "$QFY_L" ]; then
    _qfy_get previous "$QFY_L" previous
    if [ -z "$QFY_M" ] || [ "$previous" != "$QFY_M_SHA" ]; then _qfy_block "linux.omb does not continue macos.omb. $(_qfy_clear linux.omb)"; return 0; fi
    _qfy_get part "$QFY_L" partuuid
    part=$(printf '%s' "$part" | tr 'A-F' 'a-f')
    [ "$part" = "$guid" ] || { _qfy_block "linux.omb names another Shared partition. $(_qfy_clear linux.omb)"; return 0; }
    _qfy_get size "$QFY_L" bytes
    [ "$size" = "$QFY_BYTES" ] || { _qfy_block "linux.omb records a stream size this run does not use. $(_qfy_clear linux.omb)"; return 0; }
  fi
  if [ -n "$QFY_R" ]; then
    _qfy_get previous "$QFY_R" previous
    if [ -z "$QFY_L" ] || [ "$previous" != "$QFY_L_SHA" ]; then _qfy_block "result.omb does not continue linux.omb. $(_qfy_clear result.omb)"; return 0; fi
    _qfy_get verdict "$QFY_R" verdict
    if [ "$verdict" = passed ]; then
      for file in data_ok return_ok names_ok; do
        _qfy_get size "$QFY_R" "$file"
        [ "$size" = 1 ] || { _qfy_block "result.omb says passed but records a failed check. $(_qfy_clear result.omb)"; return 0; }
      done
    fi
    QFY_STATE=$verdict QFY_DUE=none
    _qfy_get QFY_WHY "$QFY_R" reason
  elif [ -n "$QFY_L" ]; then QFY_STATE=waiting-for-macos QFY_DUE=3
  elif [ -n "$QFY_M" ]; then QFY_STATE=waiting-for-linux QFY_DUE=2
  fi
  if [ "$OMB_PLATFORM" = macos ]; then
    [ "$QFY_DUE" = 3 ] || QFY_DUE=1
    QFY_CAN_RUN=1
  elif [ "$QFY_DUE" = 2 ] && [ "$EUID" != 0 ] && [ "$OMB_UID" != 0 ]; then QFY_CAN_RUN=1
  fi
  return 0
}
_qfy_space() {
  local df free reserve streams=1 file blocks reclaimed=0
  df=$(sys_cmd qualify_space df -Pk "$QFY_MOUNT") || { _qfy_block 'Shared free space could not be read.'; return 1; }
  free=$(printf '%s\n' "$df" | awk 'NR == 2 {print $4}')
  if ! _whole "$free" '^(0|[1-9][0-9]{0,14})$' || ! _whole "$QFY_SIZE" '^[1-9][0-9]{0,17}$'; then
    _qfy_block 'Shared free space or size is not exact.'; return 1
  fi
  free=$((free * 1024)) reserve=$(((QFY_SIZE + 49) / 50))
  # Read-only previews include only allocation occupied by our own fixed data
  # files, which the due writer removes before the final free-space check.
  if [ "${1:-}" = preview ]; then
    file=$QFY_DIR/data.$OMB_PLATFORM.bin
    if [ "$QFY_DUE" = 1 ]; then
      file=$QFY_DIR/data.macos.bin
      if [ -f "$QFY_DIR/data.linux.bin" ]; then
        blocks=$(du -k "$QFY_DIR/data.linux.bin") || return 1
        blocks=${blocks%%[[:space:]]*}
        _uint "$blocks" || return 1
        reclaimed=$((reclaimed + blocks * 1024))
      fi
    fi
    if [ -f "$file" ]; then
      blocks=$(du -k "$file") || return 1
      blocks=${blocks%%[[:space:]]*}
      _uint "$blocks" || return 1
      reclaimed=$((reclaimed + blocks * 1024))
    fi
    free=$((free + reclaimed))
  fi
  [ "$reserve" -ge 1073741824 ] || reserve=1073741824
  [ "$OMB_PLATFORM" != macos ] || streams=2
  QFY_REQUIRED=$((streams * QFY_BYTES + 1048576 + reserve)) QFY_FREE=$free
  [ "$free" -ge "$QFY_REQUIRED" ] || { _qfy_block "Shared needs $QFY_REQUIRED bytes; $free bytes free (reserve $reserve bytes)."; return 1; }
}
_qfy_flush() {
  if [ "$OMB_PLATFORM" = linux ]; then run sync "$1"; else run sync; fi
}
# Invoked only through run. Exclusive open is inside the helper, never a
# redirection around run (which would write even in a dry run).
qfy_copy_exclusive() ( set -C; cat "$1" >"$2" )
qfy_stream() (
  local -a status=()
  set -C
  : >"$1" || exit 1
  head -c "$QFY_BYTES" /dev/urandom | tee -a "$1" | _qfy_hash >|"$QFY_W/stream.hash"
  status=( "${PIPESTATUS[@]}" )
  [ "${status[*]}" = '0 0 0' ] || exit 1
  local size
  size=$(wc -c <"$1") || exit 1
  [ "$size" -eq "$QFY_BYTES" ]
)
_qfy_stream_write() {
  omb_fail_at qualify.stream && return 1
  run qfy_stream "$QFY_DIR/data.$1.bin" || return 1
  omb_stop_at qualify.stream
  _qfy_flush "$QFY_DIR/data.$1.bin" || return 1
  local out
  out=$(cat "$QFY_W/stream.hash") || return 1
  QFY_SHA=${out%% *}
  _whole "$QFY_SHA" '^[0-9a-f]{64}$'
}
# QFY_SEEN: which of the fixed test names the folder lists, spelled exactly
# as written (the directory entry's bytes, not a lookup that exFAT folds);
# QFY_OTHERS: how many other entries it holds, counted to 64 for display.
# Foreign entries (a .DS_Store, a file the owner dropped there) are never
# recorded and never fail anything.
_qfy_scan_names() {
  local path name entry
  QFY_SEEN='' QFY_OTHERS=0
  [ -d "$1" ] || return 0
  for path in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    entry=0
    for name in "${QFY_NAMES[@]}"; do
      if [ "${path##*/}" = "$name" ]; then
        rec_enc_v "$name"
        QFY_SEEN="$QFY_SEEN$REC_ENC
"
        entry=1
        break
      fi
    done
    if [ "$entry" = 0 ] && [ "$QFY_OTHERS" -lt 64 ]; then QFY_OTHERS=$((QFY_OTHERS + 1)); fi
  done
  QFY_SEEN=${QFY_SEEN%$'\n'}
}
# The others, said once per folder.
_qfy_others() {
  local n=$QFY_OTHERS
  [ "$n" != 0 ] || return 0
  [ "$n" -lt 64 ] || n='64 or more'
  ui_info "$1 also holds $n entries this test did not write; they are left alone and do not count."
}
_qfy_write_names() {
  local name path
  QFY_WRITTEN='' QFY_COLLISIONS=''
  run mkdir -p "$QFY_DIR/names-$1" || return 1
  : >"$QFY_W/empty" || return 1
  for name in "${QFY_NAMES[@]}"; do
    path=$QFY_DIR/names-$1/$name
    if run qfy_copy_exclusive "$QFY_W/empty" "$path" 2>/dev/null; then
      rec_enc_v "$name"; QFY_WRITTEN="$QFY_WRITTEN$REC_ENC
"
    elif [ -f "$path" ] && [ ! -L "$path" ]; then
      rec_enc_v "$name"; QFY_COLLISIONS="$QFY_COLLISIONS$REC_ENC
"
      ui_info "Name collision: $REC_ENC"
    else return 1; fi
  done
  QFY_WRITTEN=${QFY_WRITTEN%$'\n'} QFY_COLLISIONS=${QFY_COLLISIONS%$'\n'}
  _qfy_flush "$QFY_DIR/names-$1"
}
_qfy_foreign() { rec_enc_v "$1"; ui_info "Left foreign entry: $REC_ENC"; }
# Match the directory entry's bytes, not a case-insensitive lookup of a
# fixed spelling. A foreign CASE or data.MACOS.bin must survive cleanup.
_qfy_remove_file() {
  local path
  for path in "$QFY_DIR"/* "$QFY_DIR"/.[!.]* "$QFY_DIR"/..?*; do
    [ "${path##*/}" = "$1" ] || continue
    if [ -e "$path" ] || [ -L "$path" ]; then
      omb_fail_at "qualify.rm.$1" && return 1
      run rm -f "$path" || return 1
      omb_stop_at "qualify.rm.$1"
    fi
  done
}
_qfy_clean_side() {
  local side=$1 name path fixed own
  ui_info "Remove fixed test names: data.$side.bin, names-$side/ and its seven test names."
  _qfy_remove_file "data.$side.bin" || return 1
  for name in "${QFY_NAMES[@]}"; do
    rec_enc_v "$name"
    ui_info "Remove fixed name: names-$side/$REC_ENC"
  done
  if [ -d "$QFY_DIR/names-$side" ]; then
    for path in "$QFY_DIR/names-$side"/* "$QFY_DIR/names-$side"/.[!.]* "$QFY_DIR/names-$side"/..?*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      own=0
      for name in "${QFY_NAMES[@]}"; do
        if [ "${path##*/}" = "$name" ]; then own=1; break; fi
      done
      if [ "$own" = 1 ]; then run rm -f "$path" || return 1
      else _qfy_foreign "$path"; fi
    done
    fixed=$(ls -A "$QFY_DIR/names-$side") || return 1
    if [ -z "$fixed" ]; then run rmdir "$QFY_DIR/names-$side" || return 1; fi
  fi
}
_qfy_clean_start() {
  local name path
  ui_info 'Remove fixed records: result.omb, linux.omb, macos.omb and their .tmp names.'
  # Last link first: a stop or a failed removal between two of them leaves a
  # prefix of the chain, a state some step is offered from, never a record
  # whose predecessor is gone.
  for name in result linux macos; do
    _qfy_remove_file "$name.omb.tmp" || return 1
    _qfy_remove_file "$name.omb" || return 1
  done
  _qfy_clean_side macos || return 1
  _qfy_clean_side linux || return 1
  for path in "$QFY_DIR"/* "$QFY_DIR"/.[!.]* "$QFY_DIR"/..?*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    case "${path##*/}" in names-macos | names-linux) ;; *) _qfy_foreign "$path" ;; esac
  done
}
_qfy_add_list() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf '\t%s=%s' "$1" "$name" >>"$QFY_W/record" || return 1
  done <<<"$2"
}
_qfy_save() {
  local sha
  printf '\n' >>"$QFY_W/record" || return 1
  _qfy_sha "$QFY_W/record" || return 1; sha=$QFY_SHA
  printf 'seal\tsha256=%s\n' "$sha" >>"$QFY_W/record" || return 1
  omb_fail_at "qualify.$1" && return 1
  run qfy_copy_exclusive "$QFY_W/record" "$QFY_DIR/$1.omb.tmp" || return 1
  omb_stop_at "qualify.$1"
  _qfy_flush "$QFY_DIR/$1.omb.tmp" || return 1
  run mv -f "$QFY_DIR/$1.omb.tmp" "$QFY_DIR/$1.omb" || return 1
  _qfy_flush "$QFY_DIR/$1.omb"
}
_qfy_record_start() {
  QFY_COMMIT=$(sys_cmd qualify_commit git -C "$OMB_HOME" rev-parse HEAD) || QFY_COMMIT=''
  _whole "$QFY_COMMIT" '^[0-9a-f]{40}$' || QFY_COMMIT=''
  QFY_AT=$(now_utc)
}
qfy_run() {
  local step review mac_hash read_hash linux_hash got data_ok=1 return_ok=1 names_ok=1 verdict=passed reason='' seen written collisions dirty=0 kernel logs
  qfy_status_read
  QFY_FROM_M=$QFY_M_SHA
  if [ "$QFY_STATE" = blocked ]; then ui_fail "$QFY_WHY"; return 1; fi
  if [ "$QFY_CAN_RUN" != 1 ]; then
    if [ -n "$QFY_RERUN_WHY" ]; then ui_fail "Qualification is $QFY_STATE; a new run cannot start. $QFY_RERUN_WHY"
    else ui_fail "Step $QFY_DUE is due; Linux qualification runs as the everyday user, after macOS step 1."; fi
    return 1
  fi
  step=$QFY_DUE QFY_ACTION_STEP=$QFY_DUE review="$QFY_SHARED:$QFY_PLAN:$QFY_M_SHA:$QFY_L_SHA:$QFY_R_SHA"
  ui_info "Qualification step $step on $QFY_SHARED."
  ui_confirm_word test 'Run the due qualification step on Shared.' || return 1
  # Recheck identity/admission/binding after waiting for the typed word.
  qfy_status_read
  if [ "$QFY_STATE" = blocked ] || [ "$QFY_CAN_RUN" != 1 ] || [ "$step" != "$QFY_DUE" ] ||
    [ "$review" != "$QFY_SHARED:$QFY_PLAN:$QFY_M_SHA:$QFY_L_SHA:$QFY_R_SHA" ]; then
    ui_fail "Qualification changed: $QFY_WHY"; return 1
  fi
  _qfy_bytes || return 1
  if [ "$OMB_PLATFORM" = linux ]; then sys_has sha256sum || { ui_fail 'sha256sum is required.'; return 1; }
  else sys_has shasum || { ui_fail 'shasum is required.'; return 1; }; fi
  if [ "$OMB_DRY_RUN" = 1 ] || [ -n "${OMB_TEST_RECORD:-}" ]; then ui_info 'Qualification was only shown; no stream or Shared write ran.'; return 0; fi
  omb_tmp_init || return 1
  QFY_W=$OMB_TMP/qualify
  mkdir -p "$QFY_W" || return 1
  _qfy_record_start
  case "$step" in
    1)
      _qfy_clean_start || return 1
      _qfy_space final || { ui_fail "$QFY_WHY"; return 1; }
      run mkdir -p "$QFY_DIR" || return 1
      _qfy_stream_write macos || return 1; mac_hash=$QFY_SHA
      _qfy_write_names macos || return 1; written=$QFY_WRITTEN
      rec_line_v macos schema 1 plan "$QFY_PLAN" shared_guid "$QFY_GUID" os macos commit "$QFY_COMMIT" at "$QFY_AT" bytes "$QFY_BYTES" sha256 "$mac_hash"
      printf 'omb-qualify 1\n%s' "$REC_LINE" >"$QFY_W/record" || return 1
      _qfy_add_list name "$written" || return 1
      _qfy_save macos || return 1 ;;
    2)
      if logs=$(sys_cmd qualify_journal journalctl -k -b 0 --no-pager -q); then :
      elif logs=$(sys_cmd qualify_dirty dmesg); then :
      else
        dirty=unknown
        ui_warn 'The kernel log could not be read, so an exFAT dirty flag could not be checked. Shut down cleanly before switching systems next time.'
      fi
      # Literal driver text and the complete device delimiter: another
      # partition, including one with this name as a prefix, cannot match.
      if [ "$dirty" != unknown ]; then
        if printf '%s\n' "$logs" | awk -v device="$SH_NAME" '
          BEGIN { warning = "exFAT-fs (" device "): Volume was not properly unmounted. Some data may be corrupt. Please run fsck." }
          {
            at = index($0, warning)
            if (at && substr($0, at) == warning && (at == 1 || substr($0, at - 1, 1) ~ /[[:space:]]/)) found = 1
          }
          END { exit !found }'; then dirty=1; fi
      fi
      # A release names itself (6.16.8-asahi-1-1-ARCH): capitals, and whatever
      # else a distribution puts in it, which the lower-case id type refuses.
      # It is recorded as bytes, shown and never compared.
      kernel=$(sys_cmd qualify_kernel uname -r) || { ui_fail 'The kernel release could not be read.'; return 1; }
      _whole "$kernel" '^[[:graph:]]{1,128}$' || { ui_fail 'The kernel release is not a word of 1 to 128 printable characters.'; return 1; }
      _qfy_clean_side linux || return 1
      _qfy_remove_file linux.omb.tmp || return 1
      _qfy_space final || { ui_fail "$QFY_WHY"; return 1; }
      # A file that cannot be read back is recorded as such (an empty digest):
      # the round trip goes on, and step 3 says failed.
      if _qfy_sha "$QFY_DIR/data.macos.bin"; then read_hash=$QFY_SHA
      else
        read_hash=''
        ui_warn 'data.macos.bin could not be read back. The step goes on and records that; the result will say failed.'
      fi
      _qfy_scan_names "$QFY_DIR/names-macos"
      seen=$QFY_SEEN
      _qfy_others names-macos
      _qfy_stream_write linux || return 1; linux_hash=$QFY_SHA
      _qfy_write_names linux || return 1; written=$QFY_WRITTEN collisions=$QFY_COLLISIONS
      rec_line_v linux schema 1 previous "$QFY_M_SHA" partuuid "$QFY_GUID" majmin "$SH_MAJMIN" os linux commit "$QFY_COMMIT" at "$QFY_AT" read_sha256 "$read_hash" bytes "$QFY_BYTES" sha256 "$linux_hash"
      printf 'omb-qualify 1\n%s' "$REC_LINE" >"$QFY_W/record" || return 1
      _qfy_add_list name_seen "$seen" || return 1
      _qfy_add_list name_written "$written" || return 1
      _qfy_add_list name_collision "$collisions" || return 1
      rec_enc_v "$kernel"
      printf '\tkernel=%s\tdirty=%s' "$REC_ENC" "$dirty" >>"$QFY_W/record" || return 1
      _qfy_save linux || return 1
      ui_info "Linux exFAT dirty flag: $dirty" ;;
    3)
      _qfy_remove_file result.omb.tmp || return 1
      _qfy_get mac_hash "$QFY_M" sha256
      read_hash=''
      _qfy_get read_hash "$QFY_L" read_sha256
      [ "$mac_hash" = "$read_hash" ] || data_ok=0
      _qfy_get linux_hash "$QFY_L" sha256
      # What cannot be read back is a failed check, recorded with its reason
      # (the next step is then step 1, never a step 3 that cannot finish).
      # Names are compared exactly, and only those the test created.
      if [ -z "$read_hash" ]; then data_ok=0 reason=macos-data-unreadable; fi
      if _qfy_sha "$QFY_DIR/data.linux.bin"; then
        got=$QFY_SHA
        [ "$linux_hash" = "$got" ] || return_ok=0
      else return_ok=0 reason=${reason:-data-unreadable}; fi
      _qfy_scan_names "$QFY_DIR/names-linux"
      _qfy_others names-linux
      _qfy_names_present "$(_qfy_list "$QFY_L" name_written)" "$QFY_SEEN" || names_ok=0
      _qfy_names_present "$(_qfy_list "$QFY_M" name)" "$(_qfy_list "$QFY_L" name_seen)" || names_ok=0
      _qfy_scan_names "$QFY_DIR/names-macos"
      _qfy_others names-macos
      _qfy_names_present "$(_qfy_list "$QFY_M" name)" "$QFY_SEEN" || names_ok=0
      if [ "$data_ok$return_ok$names_ok" != 111 ]; then verdict=failed reason=${reason:-mismatch}; fi
      _qfy_get dirty "$QFY_L" dirty
      rec_line_v result schema 1 previous "$QFY_L_SHA" os macos commit "$QFY_COMMIT" at "$QFY_AT" data_ok "$data_ok" return_ok "$return_ok" names_ok "$names_ok" verdict "$verdict" reason "$reason"
      printf 'omb-qualify 1\n%s' "$REC_LINE" >"$QFY_W/record" || return 1
      _qfy_save result || return 1
      ui_info "Qualification $verdict${reason:+ ($reason)}; Linux exFAT dirty flag: $dirty."
      if [ "$verdict" = passed ]; then
        _qfy_clean_side macos || return 1
        _qfy_clean_side linux || return 1
      fi ;;
  esac
  ui_info 'Shut down fully before booting the other system; do not sleep or hibernate.'
  [ "$step" != 3 ] || [ "$verdict" = passed ]
}
qfy_cmd() {
  if [ "${1:-}" = status ]; then
    qfy_status_read
    ui_kv Qualification "$QFY_STATE" "$QFY_WHY"
    [ "$QFY_STATE" != blocked ]
  else qfy_run; fi
}
qfy_row() {
  [ "$1" = qualify.run ] || return 1
  CA_SCOPE=qualify CA_INTENT=act CA_TERMINAL=handoff CA_CANCEL=0 CA_GATE=test CA_PARAMS='' CA_FN=qfy_action CA_PHASE=qualify CA_LIMIT=3
  CA_PLATFORM=$OMB_PLATFORM CA_LABEL='Run qualification step' CA_EXPLAIN='Write only the fixed qualification files on verified Shared.'
}
qfy_action_offer() {
  qfy_status_read
  CA_WHY=${QFY_RERUN_WHY:-$QFY_WHY} CA_LABEL="Run step $QFY_DUE" QFY_ACTION_STEP=$QFY_DUE
  [ "$QFY_STATE" != blocked ] && [ "$QFY_CAN_RUN" = 1 ]
}
qfy_action_facts() {
  rec_line fact scope qualify key gate.qualify.run.shared label Shared value "$QFY_SHARED" state ok
  rec_line fact scope qualify key gate.qualify.run.step label Step value "$QFY_DUE" state info
  rec_line fact scope qualify key gate.qualify.run.plan label Plan value "$QFY_PLAN" state info
  rec_line fact scope qualify key gate.qualify.run.records label Records value "$QFY_M_SHA:$QFY_L_SHA:$QFY_R_SHA" state info
}
qfy_action_params() { :; }
qfy_action_run() { qfy_run; }
# What the step left on Shared, in the core's words (docs/QUALIFICATION.md →
# Judging a step). The exit status is never read: a step's record is written
# last, so the record being there is the effect, and a step that stopped or
# failed earlier left the chain at a state its own offer starts from again
# (no-effect: the record goes, the step can be run again). Only a chain no
# step can leave or read (blocked) needs the person. The free-space preview is
# not part of this read: it asks whether the next run fits, not what this one
# left. A sealed mismatch result is step 3's effect too: qualification stays
# failed, and the next macOS run starts step 1 again. After a new boot
# (reconcile) the step is not known, so the platform's own effect states
# stand for it.
qfy_action_judge() {
  local step=${QFY_ACTION_STEP:-} effect=0
  _qfy_state_read
  CORE_FINDING=unexpected CORE_JUDGE_TEXT="Qualification is $QFY_STATE${QFY_WHY:+: $QFY_WHY}."
  [ "$QFY_STATE" != blocked ] || return 0
  if [ "$1" = reconcile ]; then
    case "$OMB_PLATFORM:$QFY_STATE" in
      macos:waiting-for-linux | linux:waiting-for-macos | *:passed | *:failed) effect=1 ;;
    esac
  else
    case "$step:$QFY_STATE" in
      1:waiting-for-linux) [ "$QFY_M_SHA" = "${QFY_FROM_M:-}" ] || effect=1 ;;
      2:waiting-for-macos | 3:passed | 3:failed) effect=1 ;;
    esac
  fi
  if [ "$effect" = 1 ]; then CORE_FINDING=completed
  else
    CORE_FINDING=no-effect
    CORE_JUDGE_TEXT="The step stopped before it saved its record. Qualification is $QFY_STATE${QFY_WHY:+: $QFY_WHY}; the next run repeats the step that is due, from its first check."
  fi
}
# Stored times describe each writer; display them in Eastern time, never
# compare clocks across the two systems. date here formats admitted data.
_qfy_metadata() {
  local commit at epoch when
  _qfy_get commit "$1" commit
  _qfy_get at "$1" at
  when='time unreadable'
  if epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$at" +%s 2>/dev/null) ||
    epoch=$(date -d "$at" +%s 2>/dev/null); then
    if when=$(TZ=America/New_York date -r "$epoch" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null); then :
    elif when=$(TZ=America/New_York date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null); then :
    else when='time unreadable'; fi
  fi
  QFY_METADATA="commit ${commit:-unknown}; $when"
}
qfy_core_op() {
  local tone=info shared=warn body rows='' n label state detail sha read_sha rshow mac_sha dirty record st
  qfy_status_read
  omb_tmp_init || { core_read_failure 1; return; }
  body=$OMB_TMP/qualify.body
  for n in 1 2 3; do
    state=todo detail='' sha=''
    case "$n" in
      1) label='macOS writes'; record=$QFY_M; [ -z "$QFY_M" ] || _qfy_get sha "$QFY_M" sha256 ;;
      2) label='Linux checks and writes'; record=$QFY_L; [ -z "$QFY_L" ] || _qfy_get sha "$QFY_L" sha256 ;;
      3) label='macOS checks'; record=$QFY_R; sha=$QFY_R_SHA ;;
    esac
    [ -z "$sha" ] || { state='done'; detail=${sha:0:12}; }
    if [ "$n" = 2 ] && [ -n "$QFY_L" ]; then
      read_sha=''
      _qfy_get read_sha "$QFY_L" read_sha256
      _qfy_get mac_sha "$QFY_M" sha256
      _qfy_get dirty "$QFY_L" dirty
      if [ -n "$read_sha" ]; then rshow=${read_sha:0:12}; else rshow=unreadable; fi
      detail="read $rshow; wrote ${sha:0:12}; dirty $dirty"
      if [ "$read_sha" != "$mac_sha" ]; then state=failed; detail="$detail; macOS digest mismatch"; fi
    fi
    if [ "$n" = 3 ] && [ -n "$QFY_L" ]; then
      _qfy_get dirty "$QFY_L" dirty
      detail="$detail; Linux dirty $dirty"
    fi
    if [ "$QFY_STATE" = blocked ]; then state=blocked detail=$QFY_WHY
    elif [ "$n" = 3 ] && [ "$QFY_STATE" = failed ]; then state=failed detail="$detail; $QFY_WHY"; fi
    if [ -n "$record" ]; then _qfy_metadata "$record"; detail="$detail; $QFY_METADATA"; fi
    rec_line_v row kind step key "$n" col "$state" col "$label" col "$detail"
    rows="$rows$REC_LINE
"
  done
  case "$QFY_STATE" in passed) tone=ok ;; failed) tone=fail ;; blocked) tone=warn ;; esac
  [ -z "$QFY_SHARED" ] || shared=ok
  core_rows_snapshot qualify.run || { core_read_failure 1; return; }
  {
    rec_line fact scope qualify key qualify.state label Qualification value "$QFY_STATE" state "$tone"
    rec_line fact scope qualify key qualify.due label Due value "$QFY_DUE" state info
    rec_line fact scope qualify key qualify.shared label Shared value "${QFY_SHARED:-$QFY_WHY}" state "$shared"
    cat "$OMB_TMP/rows.facts"
    if [ "$QFY_STATE" = blocked ]; then rec_line blocker id qualify.blocked text "$QFY_WHY" fix ''; fi
    cat "$OMB_TMP/rows.blockers" "$OMB_TMP/rows.actions" "$OMB_TMP/rows.params"
  } >"$body" || { core_read_failure 1; return; }
  QFY_GEN=$(sha256_str "$rows:$(cat "$body")")
  if [ "$1" = detail ]; then
    [ "$CORE_REQ_KIND" = step ] || { core_result refused unavailable 'Qualification pages steps only.'; return; }
    core_read_page "$QFY_GEN" "$rows"
    return
  fi
  core_read_prefix || { core_read_failure 1; return; }
  core_read_stage snapshot "$QFY_GEN" 0 "$body"
  st=$?
  if [ "$st" != 0 ]; then core_read_failure "$st"; return; fi
  core_read_publish
}
