# shellcheck shell=bash
# Shared macOS <-> Linux storage: one exFAT partition, planned on macOS with
# the rest of the disk, created from macOS once Linux is completely
# installed, and mounted persistently on Linux by its GPT partition GUID.
#
# This is the one disk change this tool makes itself, and it is narrow:
#   sudo diskutil addPartition <the Linux root> ExFAT Shared <bytes>
# with the planned size in whole MiB, at the start of the free region
# reserved for it, only after the whole disk has been
# read again and matched against the plan, and the person has typed
# "create". The plan file and the codes typed between the systems are input
# to that check, never a substitute for it. Nothing here deletes, resizes,
# moves or formats an existing partition.
#
# State, derived from the machine on every run:
#   off                         no Shared storage planned
#   reserved                    planned; Asahi not installed yet
#   awaiting-linux-completion   Asahi installed; Linux not finished (or its code not entered)
#   awaiting-macos-creation     ready to create: Linux finished, region verified
#   created                     the Shared partition exists as planned
#   awaiting-linux-activation   (Linux) the partition is there; not mounted yet
#   ready                       (Linux) mounted persistently at /mnt/shared
#   blocked                     something does not match; stop and explain

SHARED_LABEL="Shared"
SHARED_FS_MAC="ExFAT"
SHARED_PARTTYPE="ebd0a0a2-b9e5-4433-87c0-68b6b72699c7" # GPT Basic Data
SHARED_MNT=/mnt/shared
SHARED_UNIT=mnt-shared.automount
SHARED_FSTAB_MARK="# omarchy-bootstrap: Shared storage (managed; see ./omarchy-bootstrap shared)"
SHARED_INTENT_FILE=shared-intent.env
SHARED_INTENT_SCHEMA="omb-shared-intent/1"
SHARED_INTENT_KEYS="schema contract planned_at disk_size disk_block disk_media isc macos recovery parts_before mode macos_after linux_request linux_answer shared_request region_pred region_succ region_start region_end shared_start shared_end"
SHARED_UUID_RE='^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$'
# The creation record, written before addPartition runs: what the one
# creation was allowed to produce, judged the same way right after it and on
# every later run until its result is recorded.
SHARED_TXN_FILE=shared-create.env
SHARED_TXN_SCHEMA="omb-shared-create/1"
SHARED_TXN_KEYS="schema txn started_at plan disk_size disk_block disk_media store root succ gap_start gap_end shared_start shared_end shared_min"

# ---------------------------------------------------------------------------
# The plan record (macOS). Versioned, digested, parsed field by field.
# ---------------------------------------------------------------------------

# _part_rec UUID — "uuid:offset:size" from the current geometry.
_part_rec() {
  geo_part "$1" && printf '%s:%s:%s' "$1" "$GP_OFFSET" "$GP_SIZE"
}

# shared_intent_body — the record for the current plan (after plan_layout).
shared_intent_body() {
  local parts="" off size uuid content id role
  while IFS='|' read -r off size uuid content id role; do
    [ -n "$off" ] && parts="$parts${parts:+;}$uuid:$off:$size"
  done <<EOF
$GEO_PARTS
EOF
  printf 'schema=%s\n' "$SHARED_INTENT_SCHEMA"
  printf 'contract=%s\n' "$STORAGE_CONTRACT"
  printf 'planned_at=%s\n' "$(now_utc)"
  printf 'disk_size=%s\ndisk_block=%s\n' "$GEO_DISK_SIZE" "$GEO_BLOCK"
  printf 'disk_media=%s\n' "$(shared_media)"
  printf 'isc=%s\n' "$(_part_rec "$(geo_role_uuids isc | head -1)")"
  printf 'macos=%s\n' "$(_part_rec "$PLAN_MACOS_UUID")"
  printf 'recovery=%s\n' "$(_part_rec "$(geo_role_uuids recovery | head -1)")"
  printf 'parts_before=%s\n' "$parts"
  printf 'mode=%s\nmacos_after=%s\n' "$PLAN_MODE" "$PLAN_MACOS_NEW"
  printf 'linux_request=%s\nlinux_answer=%s\n' "$PLAN_LINUX" "$PLAN_ANSWER_OS"
  printf 'shared_request=%s\n' "$PLAN_SHARED"
  printf 'region_pred=%s\nregion_succ=%s\n' "$PLAN_GAP_PRED" "$PLAN_GAP_SUCC"
  printf 'region_start=%s\nregion_end=%s\n' "$PLAN_GAP_START" "$PLAN_GAP_END"
  printf 'shared_start=%s\nshared_end=%s\n' "$PLAN_SHARED_START" "$PLAN_SHARED_END"
}

# shared_media — the disk's own name (IORegistryEntryName), as recorded.
shared_media() { printf '%s' "${MAC_DISK_MEDIA:-}" | tr -cd '[:alnum:] ._()-'; }

# shared_intent_save — write the record for the current plan, or remove it
# when no Shared storage is planned. Returns non-zero when it cannot.
shared_intent_save() {
  local body
  if [ "${PLAN_SHARED:-0}" = 0 ] || [ "$PLAN_OK" != 1 ]; then
    state_remove_file "$SHARED_INTENT_FILE"
    return
  fi
  body=$(shared_intent_body)
  state_put_file "$SHARED_INTENT_FILE" "$body
digest=$(sha256_str "$body" | cut -c1-16)"
}

# shared_plan_digest — the 8-hex name of the saved plan ("" without one).
shared_plan_digest() {
  shared_intent_load >/dev/null 2>&1 && printf '%s' "${INT_digest:0:8}"
}

# _intent_rec_ok VALUE — "UUID:offset:size".
_intent_rec_ok() {
  local u=${1%%:*} rest=${1#*:}
  _whole "$u" "$SHARED_UUID_RE" && _uint "${rest%%:*}" && _uint "${rest#*:}" && [ "$rest" != "${rest#*:}" ]
}

# intent_parts — the recorded partitions, one "uuid:offset:size" per line.
intent_parts() { printf '%s\n' "$INT_parts_before" | tr ';' '\n' | sed '/^$/d'; }

# shared_intent_load — read and check the record; sets INT_<key>. Returns 1
# with INT_ERR when it is missing, unreadable, edited, or from another
# version of this tool.
shared_intent_load() {
  local file="$OMB_STATE_DIR/$SHARED_INTENT_FILE" line k v body="" rec ok=1
  INT_ERR=""
  for k in $SHARED_INTENT_KEYS digest; do eval "INT_$k="; done
  if [ ! -e "$file" ]; then
    INT_ERR="no Shared plan is recorded"
    return 1
  fi
  if ! _state_file_ok "$file"; then
    INT_ERR="the Shared plan record is not a plain file owned by you"
    return 1
  fi
  while IFS= read -r line; do
    k=${line%%=*} v=${line#*=}
    [ "$line" = "$k" ] && { ok=0; break; }
    case $k in "" | *[!a-z_]*) ok=0; break ;; esac
    if [ "$k" = digest ]; then
      INT_digest=$v
      continue
    fi
    case " $SHARED_INTENT_KEYS " in *" $k "*) ;; *) ok=0; break ;; esac
    body="$body$line
"
    eval "INT_$k=\$v"
  done <"$file"
  if [ "$ok" != 1 ]; then
    INT_ERR="the Shared plan record has a line this tool did not write"
    return 1
  fi
  if [ "$INT_schema" != "$SHARED_INTENT_SCHEMA" ]; then
    INT_ERR="the Shared plan record is from another version of this tool (${INT_schema:-none})"
    return 1
  fi
  if [ "$(sha256_str "${body%
}" | cut -c1-16)" != "$INT_digest" ]; then
    INT_ERR="the Shared plan record was changed after it was written"
    return 1
  fi
  for k in disk_size disk_block macos_after linux_request shared_request region_start region_end shared_start shared_end; do
    eval "v=\$INT_$k"
    _uint "$v" || { INT_ERR="the Shared plan record has an unreadable $k"; return 1; }
  done
  for k in isc macos recovery; do
    eval "v=\$INT_$k"
    _intent_rec_ok "$v" || { INT_ERR="the Shared plan record has an unreadable $k partition"; return 1; }
  done
  while IFS= read -r rec; do
    _intent_rec_ok "$rec" || { INT_ERR="the Shared plan record lists an unreadable partition"; return 1; }
  done <<EOF
$(intent_parts)
EOF
  case "$INT_mode" in resize | free) ;; *) INT_ERR="the Shared plan record has no mode"; return 1 ;; esac
  _whole "$INT_region_pred" "$SHARED_UUID_RE" || { INT_ERR="the Shared plan record has no region"; return 1; }
  [ -z "$INT_region_succ" ] || _whole "$INT_region_succ" "$SHARED_UUID_RE" || { INT_ERR="the Shared plan record has an unreadable region"; return 1; }
  [ "$INT_shared_request" -gt 0 ] || { INT_ERR="the Shared plan record reserves nothing"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# The creation record (macOS). Written once, before the one addPartition;
# sealed like the plan record; removed once the result is recorded.
# ---------------------------------------------------------------------------

# shared_txn_body — the record, from the read that authorized the creation
# (after shared_region): the disk, every partition on it as it was, the free
# region the creation may use, the Linux root before it, the partition
# after it, and the interval and minimum size of what it creates.
shared_txn_body() {
  printf 'schema=%s\n' "$SHARED_TXN_SCHEMA"
  printf 'txn=%s-%s\n' "$(now_stamp)" "$$"
  printf 'started_at=%s\n' "$(now_utc)"
  printf 'plan=%s\n' "$INT_digest"
  printf 'disk_size=%s\ndisk_block=%s\ndisk_media=%s\n' "$GEO_DISK_SIZE" "$GEO_BLOCK" "$(shared_media)"
  printf 'store=%s\n' "$MAC_STORE_UUID"
  printf 'root=%s\n' "$(_part_rec "$SHARED_PRED_UUID")"
  printf 'succ=%s\n' "$INT_region_succ"
  printf 'gap_start=%s\ngap_end=%s\n' "$SHARED_GAP_START" "$SHARED_GAP_END"
  printf 'shared_start=%s\nshared_end=%s\nshared_min=%s\n' "$SH_START" "$SH_END" "$INT_shared_request"
  geo_canon | sed 's/^/part=/'
}

# shared_txn_save — write the record; non-zero when it cannot be written.
shared_txn_save() {
  local body
  body=$(shared_txn_body)
  state_put_file "$SHARED_TXN_FILE" "$body
digest=$(sha256_str "$body" | cut -c1-16)"
}

# shared_txn_load — read and check the record; sets TXN_<key> and TXN_PARTS
# (one "offset|size|guid|content" per line). Returns 1 with TXN_ERR when it
# is unreadable, edited, from another version or for another plan.
shared_txn_load() {
  local file="$OMB_STATE_DIR/$SHARED_TXN_FILE" line k v body="" ok=1 off size u rest
  TXN_ERR="" TXN_PARTS=""
  for k in $SHARED_TXN_KEYS digest; do eval "TXN_$k="; done
  if ! _state_file_ok "$file"; then
    TXN_ERR="the Shared creation record is not a plain file owned by you"
    return 1
  fi
  while IFS= read -r line; do
    k=${line%%=*} v=${line#*=}
    [ "$line" = "$k" ] && { ok=0; break; }
    case $k in "" | *[!a-z_]*) ok=0; break ;; esac
    if [ "$k" = digest ]; then
      TXN_digest=$v
      continue
    fi
    body="$body$line
"
    if [ "$k" = part ]; then
      TXN_PARTS="$TXN_PARTS$v
"
      continue
    fi
    case " $SHARED_TXN_KEYS " in *" $k "*) ;; *) ok=0; break ;; esac
    eval "TXN_$k=\$v"
  done <"$file"
  if [ "$ok" != 1 ]; then
    TXN_ERR="the Shared creation record has a line this tool did not write"
    return 1
  fi
  if [ "$TXN_schema" != "$SHARED_TXN_SCHEMA" ]; then
    TXN_ERR="the Shared creation record is from another version of this tool (${TXN_schema:-none})"
    return 1
  fi
  if [ "$(sha256_str "${body%
}" | cut -c1-16)" != "$TXN_digest" ]; then
    TXN_ERR="the Shared creation record was changed after it was written"
    return 1
  fi
  for k in disk_size disk_block gap_start gap_end shared_start shared_end shared_min; do
    eval "v=\$TXN_$k"
    _uint "$v" || { TXN_ERR="the Shared creation record has an unreadable $k"; return 1; }
  done
  if [ -z "$TXN_PARTS" ] || ! _intent_rec_ok "$TXN_root"; then
    TXN_ERR="the Shared creation record does not describe the disk"
    return 1
  fi
  while IFS='|' read -r off size u rest; do
    [ -n "$off" ] || continue
    if ! _uint "$off" || ! _uint "$size" || ! _whole "$u" "$SHARED_UUID_RE" || [ -z "$rest" ]; then
      TXN_ERR="the Shared creation record lists an unreadable partition"
      return 1
    fi
  done <<EOF
$TXN_PARTS
EOF
  if [ "$TXN_plan" != "$INT_digest" ]; then
    TXN_ERR="the Shared creation record belongs to another plan"
    return 1
  fi
  return 0
}

# shared_txn_check — after a fresh read of the disk: is it exactly what the
# recorded creation was allowed to produce? Every partition from before it
# byte for byte, and exactly one new partition, inside the free region the
# creation was given, Microsoft Basic Data, formatted exFAT, at least the
# planned size. Sets TXN_RESULT: done (with TXN_NEW_UUID, _ID, _SIZE,
# _MOUNT), none (nothing new is on the disk) or broken (TXN_WHY). The same
# check decides right after the creation and on every run after it.
shared_txn_check() {
  local canon line new n off size uuid content info fs
  TXN_RESULT=broken TXN_WHY="" TXN_NEW_UUID="" TXN_NEW_ID="" TXN_NEW_SIZE=0 TXN_NEW_MOUNT=""
  if [ "$GEO_OK" != 1 ]; then
    TXN_WHY="the disk could not be read exactly ($GEO_ERR)"
    return 1
  fi
  if [ "$GEO_DISK_SIZE" != "$TXN_disk_size" ] || [ "$GEO_BLOCK" != "$TXN_disk_block" ]; then
    TXN_WHY="this is not the disk the creation was started on"
    return 1
  fi
  canon=$(geo_canon)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if ! printf '%s\n' "$canon" | grep -qxF "$line"; then
      TXN_WHY="a partition that was there before the creation changed: $line"
      return 1
    fi
  done <<EOF
$TXN_PARTS
EOF
  new=$(printf '%s\n' "$canon" | grep -vxF "${TXN_PARTS%
}")
  n=$(printf '%s' "$new" | grep -c .)
  if [ "$n" = 0 ]; then
    TXN_RESULT=none TXN_WHY="no new partition is on the disk"
    return 1
  fi
  if [ "$n" != 1 ]; then
    TXN_WHY="$n new partitions appeared; exactly one was expected"
    return 1
  fi
  IFS='|' read -r off size uuid content <<EOF
$new
EOF
  if [ "$off" -lt "$TXN_gap_start" ] || [ $((off + size)) -gt "$TXN_gap_end" ]; then
    TXN_WHY="the new partition ($uuid) is outside the free region the creation was given"
    return 1
  fi
  case "$content" in
    Microsoft\ Basic\ Data | EBD0A0A2-B9E5-4433-87C0-68B6B72699C7) ;;
    *)
      TXN_WHY="the new partition ($uuid) is $content, not Microsoft Basic Data"
      return 1
      ;;
  esac
  geo_part "$uuid"
  info=$(sys_cmd "diskutil_info_$GP_ID" diskutil info -plist "$GP_ID")
  fs=$(plist_get "$info" FilesystemType)
  if [ "$fs" != exfat ]; then
    TXN_WHY="the new partition ($GP_ID) is not the exFAT volume planned (filesystem: ${fs:-none}); this tool never formats a partition that exists"
    return 1
  fi
  if [ "$size" -lt "$TXN_shared_min" ]; then
    TXN_WHY="the new partition ($GP_ID) is $(fmt_gb "$size"), smaller than the $(fmt_gb "$TXN_shared_min") planned"
    return 1
  fi
  TXN_RESULT="done" TXN_NEW_UUID=$uuid TXN_NEW_ID=$GP_ID TXN_NEW_SIZE=$size TXN_NEW_MOUNT=$(plist_get "$info" MountPoint)
  return 0
}

# ---------------------------------------------------------------------------
# Codes typed between the two systems: PREFIX-plan8-id12-check4, hex. They
# bind a partition GUID to the plan; the receiving side checks the disk.
#   ombdone   Linux -> macOS: Linux is completely installed (root's GUID)
#   ombshare  macOS -> Linux: the Shared partition exists (its GUID)
# ---------------------------------------------------------------------------

guid12() { printf '%s' "$1" | tr -d '-' | tr 'A-F' 'a-f' | cut -c1-12; }

code_make() {
  local body
  body="$1-$2-$(guid12 "$3")"
  printf '%s-%s' "$body" "$(sha256_str "$body" | cut -c1-4)"
}

# code_parse PREFIX CODE — sets CODE_PLAN and CODE_ID12; 1 when malformed
# or mistyped (the check digits catch a slip).
code_parse() {
  local c chk
  c=$(printf '%s' "$2" | tr 'A-F' 'a-f' | tr -d ' ')
  _whole "$c" "^$1-[0-9a-f]{8}-[0-9a-f]{12}-[0-9a-f]{4}\$" || return 1
  CODE_PLAN=$(printf '%s' "$c" | cut -d- -f2)
  CODE_ID12=$(printf '%s' "$c" | cut -d- -f3)
  chk=$(printf '%s' "$c" | cut -d- -f4)
  [ "$(sha256_str "$1-$CODE_PLAN-$CODE_ID12" | cut -c1-4)" = "$chk" ]
}

# ---------------------------------------------------------------------------
# macOS: where Shared stands, read from the disk
# ---------------------------------------------------------------------------

_blocked() {
  SHARED_STATE=blocked
  SHARED_WHY=$1
}

# shared_mac_state — after mac_detect. Sets SHARED_STATE and SHARED_WHY, and
# for the region after the Linux root: SHARED_GAP_START/END, SHARED_PRED_ID,
# SHARED_PRED_UUID, SHARED_SUCC_ID; for an existing Shared partition
# SHARED_UUID, SHARED_ID, SHARED_SIZE, SHARED_MOUNT.
shared_mac_state() {
  local u off size rec
  SHARED_STATE=off SHARED_WHY="" SHARED_GAP_START=0 SHARED_GAP_END=0 SHARED_PRED_ID="" SHARED_PRED_UUID=""
  SHARED_SUCC_ID="" SHARED_UUID="" SHARED_ID="" SHARED_SIZE=0 SHARED_MOUNT="" SHARED_DIGEST="" TXN_RESULT=""
  [ -e "$OMB_STATE_DIR/$SHARED_INTENT_FILE" ] || return 0
  if ! shared_intent_load; then
    _blocked "$INT_ERR"
    return 0
  fi
  SHARED_DIGEST=${INT_digest:0:8}
  if [ "$GEO_OK" != 1 ]; then
    _blocked "the partition layout could not be read exactly ($GEO_ERR)"
    return 0
  fi
  shared_mac_target || return 0
  if [ "$INT_disk_size" != "$MAC_DISK_SIZE" ] || [ "$INT_disk_block" != "$MAC_DISK_BLOCK" ]; then
    _blocked "this is not the disk the Shared plan was made for"
    return 0
  fi
  # Apple's own partitions never move; the container only as planned.
  for rec in "$INT_isc" "$INT_recovery"; do
    u=${rec%%:*} off=${rec#*:} size=${off#*:} off=${off%%:*}
    if ! geo_part "$u" || [ "$GP_OFFSET" != "$off" ] || [ "$GP_SIZE" != "$size" ]; then
      _blocked "an Apple system partition is not where the plan found it ($u)"
      return 0
    fi
  done
  u=${INT_macos%%:*} off=${INT_macos#*:} off=${off%%:*}
  if ! geo_part "$u" || [ "$GP_OFFSET" != "$off" ]; then
    _blocked "the macOS container is not where the plan found it"
    return 0
  fi
  asahi_classify
  case "$ASAHI_STATE" in
    none | resized-only)
      SHARED_STATE=reserved
      SHARED_WHY="$(fmt_gb "$INT_shared_request") is set aside; it is created after Linux is installed"
      return 0
      ;;
    installed | pending-first-boot | installed-unverified) ;;
    *)
      _blocked "the Asahi install is not complete ($ASAHI_STATE)"
      return 0
      ;;
  esac
  geo_part "$u"
  if [ "$GP_SIZE" != "$INT_macos_after" ]; then
    _blocked "the macOS container is $(fmt_bytes "$GP_SIZE"), not the $(fmt_bytes "$INT_macos_after") the plan left it"
    return 0
  fi
  # Every partition from before is still there, unchanged (the container
  # aside), and nothing is on the disk that neither the plan nor Asahi put there.
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    u=${rec%%:*} off=${rec#*:} size=${off#*:} off=${off%%:*}
    [ "$u" = "${INT_macos%%:*}" ] && continue
    if ! geo_part "$u" || [ "$GP_OFFSET" != "$off" ] || [ "$GP_SIZE" != "$size" ]; then
      _blocked "partition $u changed since the plan was made"
      return 0
    fi
  done <<EOF
$(intent_parts)
EOF
  # A creation that reached diskutil is judged by what it was allowed to
  # produce, never by reading the disk afresh.
  if [ -e "$OMB_STATE_DIR/$SHARED_TXN_FILE" ] && ! shared_mac_txn_state; then
    return 0
  fi
  geo_part "$ASAHI_ROOT_UUID"
  SHARED_PRED_UUID=$ASAHI_ROOT_UUID SHARED_PRED_ID=$GP_ID
  SHARED_GAP_START=$GP_END
  if geo_next "$ASAHI_ROOT_UUID"; then
    if [ "$GN_UUID" != "$INT_region_succ" ]; then
      # Something sits right after the Linux root: the Shared partition, or
      # something this tool will not touch.
      shared_mac_existing
      return 0
    fi
    SHARED_GAP_END=$GN_OFFSET SHARED_SUCC_ID=$GN_ID
  else
    [ -z "$INT_region_succ" ] || {
      _blocked "the partition the plan expected after the Shared region is gone"
      return 0
    }
    SHARED_GAP_END=$GEO_USABLE_END
  fi
  _shared_other_partitions || return 0
  _shared_other_gaps || return 0
  if [ $(( SHARED_GAP_END / MIB * MIB - (SHARED_GAP_START + MIB - 1) / MIB * MIB )) -lt $(( (INT_shared_request + MIB - 1) / MIB * MIB )) ]; then
    _blocked "the free region after Linux is $(fmt_gb $((SHARED_GAP_END - SHARED_GAP_START))), smaller than the $(fmt_gb "$INT_shared_request") reserved"
    return 0
  fi
  if [ -n "$(state_get shared_uuid)" ]; then
    _blocked "the recorded Shared partition $(state_get shared_uuid) is no longer on the disk"
    return 0
  fi
  # A code typed this run counts too: a dry run records nothing.
  if shared_receipt_ok "${SHARED_TYPED_RECEIPT:-$(state_get shared_linux_done)}"; then
    SHARED_STATE=awaiting-macos-creation
    SHARED_WHY="Linux is completely installed; $(fmt_gb $((SHARED_GAP_END - SHARED_GAP_START))) is free after it"
  else
    SHARED_STATE=awaiting-linux-completion
    SHARED_WHY="the region is reserved; Shared is created once Linux (Omarchy and its encryption) has finished"
  fi
}

# shared_mac_target — the physical disk is this Mac's internal disk, the one
# macOS runs from, and the one the plan was made on. A copy of the disk in
# an enclosure can carry the same size, GUIDs and extents, so a layout that
# matches does not by itself say which disk this is. Run on every read of
# the disk, including the one after the typed gates.
shared_mac_target() {
  if [ "$MAC_DISK_INTERNAL" != true ] || [ "$MAC_WHOLE_INTERNAL" != true ]; then
    _blocked "the disk macOS runs from (${MAC_DISK:-unknown}) is not reported as internal; Shared is created only on this Mac's internal disk"
    return 1
  fi
  if [ -n "${MAC_STORES_EXTRA:-}" ]; then
    _blocked "the macOS container spans more than one physical store ($MAC_STORE, $MAC_STORES_EXTRA)"
    return 1
  fi
  if [ -z "$MAC_STORE_UUID" ] || [ "$MAC_STORE_UUID" != "${INT_macos%%:*}" ]; then
    _blocked "macOS is not running from the container the plan was made on (${MAC_STORE:-none found})"
    return 1
  fi
  if [ -n "$INT_disk_media" ] && [ "$(shared_media)" != "$INT_disk_media" ]; then
    _blocked "this is not the disk the plan was made on (it reports itself as ${MAC_DISK_MEDIA:-nothing}, the plan's as $INT_disk_media)"
    return 1
  fi
  return 0
}

# shared_mac_txn_state — Shared's state while a creation record exists.
# Returns 1 when the record decides it: created (what the recorded creation
# was allowed to produce is on the disk) or blocked (anything else, or a stop
# already recorded for it); 0 when the creation left nothing and no stop was
# recorded, so the disk reads as if it had not been started. A recorded stop
# clears only when the creation's own check passes, or when the record is
# removed by hand (docs/SHARED.md).
shared_mac_txn_state() {
  local stopped
  if ! shared_txn_load; then
    _blocked "$TXN_ERR"
    return 1
  fi
  shared_txn_check
  case "$TXN_RESULT" in
    "done")
      SHARED_UUID=$TXN_NEW_UUID SHARED_ID=$TXN_NEW_ID SHARED_SIZE=$TXN_NEW_SIZE SHARED_MOUNT=$TXN_NEW_MOUNT
      SHARED_STATE=created
      SHARED_WHY="$SHARED_ID, $(fmt_gb "$SHARED_SIZE") exFAT, made by the creation started $TXN_started_at$([ "$(state_get shared_uuid)" = "$SHARED_UUID" ] || printf ' (not recorded yet)')"
      return 1
      ;;
    none)
      stopped=$(state_get shared_blocked_reason)
      [ -n "$stopped" ] || return 0
      _blocked "the Shared creation started $TXN_started_at stopped ($stopped); the disk does not show what it was allowed to produce"
      return 1
      ;;
  esac
  _blocked "the Shared creation started $TXN_started_at did not leave the disk as planned: $TXN_WHY"
  return 1
}

# shared_mac_existing — a partition follows the Linux root, and no creation
# record is left. It is Shared only if it is the exFAT Basic Data partition
# in the planned region, at least the size planned, followed by what the
# plan expected, after the Linux root Linux's completion code names.
shared_mac_existing() {
  local info fs content mp
  info=$(sys_cmd "diskutil_info_$GN_ID" diskutil info -plist "$GN_ID")
  fs=$(plist_get "$info" FilesystemType)
  mp=$(plist_get "$info" MountPoint)
  content=$GN_CONTENT
  case "$content" in
    Microsoft\ Basic\ Data | EBD0A0A2-B9E5-4433-87C0-68B6B72699C7) ;;
    *)
      _blocked "an unexpected partition ($GN_ID, $content) follows the Linux root; this tool will not touch it"
      return 1
      ;;
  esac
  if [ "$fs" != exfat ]; then
    _blocked "the partition after the Linux root ($GN_ID) is not the exFAT volume planned (filesystem: ${fs:-none}); this tool never formats a partition that exists"
    return 1
  fi
  if [ "$GN_SIZE" -lt "$INT_shared_request" ]; then
    _blocked "the exFAT partition after the Linux root ($GN_ID) is $(fmt_gb "$GN_SIZE"), smaller than the $(fmt_gb "$INT_shared_request") planned"
    return 1
  fi
  local recorded
  recorded=$(state_get shared_uuid)
  if [ -n "$recorded" ] && [ "$recorded" != "$GN_UUID" ]; then
    _blocked "the exFAT partition after the Linux root is not the one recorded ($recorded)"
    return 1
  fi
  # Taken on only after the root Linux vouched for: a partition after some
  # other root is not one this tool made.
  if ! shared_receipt_ok "${SHARED_TYPED_RECEIPT:-$(state_get shared_linux_done)}"; then
    _blocked "an exFAT partition ($GN_ID) follows the Linux root, but Linux's completion code for this root is not recorded here, so it is not taken for Shared"
    return 1
  fi
  SHARED_UUID=$GN_UUID SHARED_ID=$GN_ID SHARED_SIZE=$GN_SIZE SHARED_MOUNT=$mp
  local sid=$GN_ID
  if geo_next "$GN_UUID"; then
    if [ "$GN_UUID" != "$INT_region_succ" ]; then
      _blocked "another partition follows the Shared partition ($GN_ID)"
      return 1
    fi
    SHARED_SUCC_ID=$GN_ID
  fi
  _shared_other_partitions "$SHARED_UUID" || return 1
  SHARED_STATE=created
  SHARED_WHY="$sid, $(fmt_gb "$SHARED_SIZE") exFAT$([ -n "$recorded" ] || printf ' (found on the disk; not recorded yet)')"
  return 0
}

# _shared_other_partitions [SHARED_UUID] — nothing on the disk but what the
# plan listed, Asahi's three partitions, and Shared.
_shared_other_partitions() {
  local off size uuid content id role
  while IFS='|' read -r off size uuid content id role; do
    [ -n "$off" ] || continue
    case "$uuid" in "$ASAHI_STUB_UUID" | "$ASAHI_EFI_UUID" | "$ASAHI_ROOT_UUID" | "${1:-none}") continue ;; esac
    case ";$INT_parts_before;" in *";$uuid:"*) continue ;; esac
    _blocked "an unexpected partition is on the disk ($id, $content)"
    return 1
  done <<EOF
$GEO_PARTS
EOF
  return 0
}

# _shared_other_gaps — any other free region must have been free before the
# plan too; a new one would make "the reserved region" ambiguous.
_shared_other_gaps() {
  local before="" rec u off size start gsize pred succ ostart osize op os inside
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    u=${rec%%:*} off=${rec#*:} size=${off#*:} off=${off%%:*}
    before="$before$off|$size|$u|||
"
  done <<EOF
$(intent_parts)
EOF
  if ! _geo_walk "$before" "$GEO_DISK_SIZE" "$GEO_BLOCK"; then
    _blocked "the layout the plan recorded cannot be read back ($W_ERR)"
    return 1
  fi
  while IFS='|' read -r start gsize pred succ; do
    [ -n "$start" ] || continue
    [ "$start" = "$SHARED_GAP_START" ] && continue
    inside=0
    while IFS='|' read -r ostart osize op os; do
      [ -n "$ostart" ] || continue
      [ "$start" -ge "$ostart" ] && [ $((start + gsize)) -le $((ostart + osize)) ] && inside=1
    done <<EOF
$W_GAPS
EOF
    if [ "$inside" != 1 ]; then
      _blocked "a free region the plan did not leave is on the disk ($(fmt_gb "$gsize") at $(fmt_bytes "$start")); which one is Shared's would be a guess"
      return 1
    fi
  done <<EOF
$GEO_GAPS
EOF
  return 0
}

# shared_receipt_ok CODE — a completion code from Linux for this plan and
# this disk's Linux root.
shared_receipt_ok() {
  [ -n "$1" ] || return 1
  code_parse ombdone "$1" || return 1
  [ "$CODE_PLAN" = "$SHARED_DIGEST" ] && [ "$CODE_ID12" = "$(guid12 "$ASAHI_ROOT_UUID")" ]
}

# shared_linux_code — the code Linux types in to find its Shared partition.
shared_linux_code() { code_make ombshare "$SHARED_DIGEST" "$SHARED_UUID"; }

# ---------------------------------------------------------------------------
# macOS: creating it
# ---------------------------------------------------------------------------

# shared_power_ok — on AC power, or a battery that will not run out.
shared_power_ok() {
  local batt pctv
  batt=$(sys_cmd pmset_batt pmset -g batt)
  case "$batt" in
    *"AC Power"*) return 0 ;;
    '')
      ui_info "Power state not reported; make sure the Mac will not run out of power."
      return 0
      ;;
  esac
  pctv=$(printf '%s' "$batt" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
  if _uint "$pctv" && [ "$pctv" -ge 50 ]; then
    return 0
  fi
  ui_fail "The Mac is on battery at ${pctv:-an unknown}%. Connect power before changing the partition table."
  return 1
}

# shared_region — the exact bytes to create: the planned size in whole MiB,
# from the region's first MiB boundary. The rest of the region stays free,
# which leaves diskutil room for its own alignment. Sets SH_START, SH_SIZE,
# SH_END (where it should end) and SH_ROOM (the region's last MiB boundary).
shared_region() {
  SH_START=$(( (SHARED_GAP_START + MIB - 1) / MIB * MIB ))
  SH_SIZE=$(( (INT_shared_request + MIB - 1) / MIB * MIB ))
  SH_END=$((SH_START + SH_SIZE))
  SH_ROOM=$(( SHARED_GAP_END / MIB * MIB ))
}

# shared_succ_label — what the partition after the region is, from the disk.
shared_succ_label() {
  [ -n "$SHARED_SUCC_ID" ] || return 0
  geo_part "$INT_region_succ" || return 0
  case "$GP_ROLE" in
    recovery) printf 'Apple recovery, untouched' ;;
    *) printf '%s, untouched' "$GP_CONTENT" ;;
  esac
}

shared_mac_summary() {
  ui_kv "Physical disk" "$MAC_DISK" "$(fmt_gb "$MAC_DISK_SIZE")${MAC_DISK_MEDIA:+ $G_DOT $MAC_DISK_MEDIA}"
  ui_kv "Shared interval" "$(fmt_bytes "$SH_START")" "to $(fmt_bytes "$SH_END"); $(fmt_gb $((SHARED_GAP_END - SH_END))) after it stays free"
  ui_kv "Shared size" "$(fmt_gb "$SH_SIZE")" "$(fmt_bytes "$SH_SIZE"); the $(fmt_gb "$INT_shared_request") planned, in whole MiB"
  ui_kv "Partition before" "$SHARED_PRED_ID" "Linux root $(guid12 "$SHARED_PRED_UUID")"
  ui_kv "Partition after" "${SHARED_SUCC_ID:-end of disk}" "$(shared_succ_label)"
  ui_kv "Filesystem" "$SHARED_FS_MAC, named $SHARED_LABEL" "empty; not encrypted"
}

# shared_create [COMPLETION_CODE] — the guarded creation, on macOS.
shared_create() {
  OMB_PHASE=macos
  mac_survey
  ui_header "macOS $G_DOT shared storage$([ "$OMB_DRY_RUN" = 1 ] && printf ' %s dry run' "$G_DOT")"
  shared_mac_state
  shared_status_rows
  shared_create_flow "${1:-}"
}

# shared_create_flow [COMPLETION_CODE] — after shared_mac_state; used by
# `shared create` and by the guided flow.
shared_create_flow() {
  local code=${1:-} canon rc
  case "$SHARED_STATE" in
    off | reserved)
      printf '\n'
      return 0
      ;;
    blocked)
      ui_blockers "Shared storage cannot be created." "$(printf "%s\n" "$SHARED_WHY" "Nothing was changed. Nothing will be repaired automatically; docs/SHARED.md explains each case.")"
      return 1
      ;;
    created)
      shared_mac_reconcile
      return
      ;;
    awaiting-linux-completion)
      shared_take_receipt "$code" || return 1
      ;;
    awaiting-macos-creation) ;;
    *)
      ui_fail "Shared storage is $SHARED_STATE here; nothing to create."
      return 1
      ;;
  esac
  # Only a verified region with Linux's code accepted goes further.
  [ "$SHARED_STATE" = awaiting-macos-creation ] || return 1
  shared_region
  if [ "$SH_END" -gt "$SH_ROOM" ]; then
    ui_fail "The region has room for $(fmt_bytes $((SH_ROOM - SH_START))), less than the $(fmt_bytes "$SH_SIZE") planned. Nothing was created."
    return 1
  fi
  shared_power_ok || return 1
  ui_section "Create Shared storage" "the one disk change this tool makes"
  shared_mac_summary
  if [ "$SHARED_GAP_START" -lt "$INT_shared_start" ]; then
    ui_warn "Linux ends $(fmt_gb $((INT_shared_start - SHARED_GAP_START))) earlier than planned (the installer was given a smaller size). Shared is created at its planned size; the difference stays free."
  fi
  ui_section "Command" "sudo asks for your password; diskutil needs it for the internal disk"
  ui_cmd "sudo diskutil addPartition $SHARED_PRED_ID $SHARED_FS_MAC $SHARED_LABEL $SH_SIZE"
  ui_callout warn "This adds one partition in free space, right after the Linux root." \
    "It does not resize, move, erase or reformat anything else. Before it runs, the whole disk is read again and must match what is shown here exactly." \
    "Shared is plain exFAT: FileVault and LUKS do not cover it, and it is not a backup."
  if ! ui_confirm_word yes "A current backup of this Mac exists."; then
    printf '\n'
    ui_info "Stopped. Nothing changed."
    return 1
  fi
  if ! ui_confirm_word create "Create the Shared partition now."; then
    printf '\n'
    ui_info "Stopped. Nothing changed."
    return 1
  fi
  # Read everything again; only an identical disk goes ahead.
  canon=$(geo_canon)
  local s0=$SH_START s1=$SH_END pred=$SHARED_PRED_ID
  mac_read_container
  mac_detect_geometry
  shared_mac_state
  shared_region
  if [ "$(geo_canon)" != "$canon" ] || [ "$SHARED_STATE" != awaiting-macos-creation ] ||
    [ "$SH_START" != "$s0" ] || [ "$SH_END" != "$s1" ] || [ "$SHARED_PRED_ID" != "$pred" ]; then
    ui_fail "The disk changed since it was shown${SHARED_WHY:+ ($SHARED_WHY)}. Nothing was created."
    return 1
  fi
  case "$SHARED_PRED_ID" in disk[0-9]*s[0-9]*) ;; *) ui_fail "Unexpected device identifier."; return 1 ;; esac
  case "$SHARED_PRED_ID$SH_SIZE" in *[!a-z0-9]*) ui_fail "Unexpected device identifier."; return 1 ;; esac
  # What this creation may produce is recorded before it runs; a stop left
  # from a record removed by hand does not carry over to this one.
  state_unset shared_blocked_reason
  if ! shared_txn_save; then
    ui_fail "Could not record the creation in $(tildify "$OMB_STATE_DIR"); stopping before anything changes."
    return 1
  fi
  printf '\n'
  run sudo diskutil addPartition "$SHARED_PRED_ID" "$SHARED_FS_MAC" "$SHARED_LABEL" "$SH_SIZE"
  rc=$?
  if [ "$OMB_DRY_RUN" = 1 ]; then
    printf '\n'
    ui_info "Dry run: nothing was created."
    return 0
  fi
  shared_mac_after "$rc"
}

# shared_take_receipt [CODE] — the completion code Linux shows once it has
# finished; recorded only when it names this plan and this Linux root.
shared_take_receipt() {
  local code=$1
  ui_section "Linux first" "Shared is created once Linux has completely finished"
  ui_note "When Omarchy is installed and its encryption has finished, ./omarchy-bootstrap on Linux shows a completion code (ombdone-...). Type it here."
  while :; do
    if [ -z "$code" ]; then
      ui_ask code "Completion code ${C_DIM}(Enter to stop)${C_RESET}" "" || return 1
      [ -n "$code" ] || {
        printf '\n'
        ui_info "Stopped. Nothing changed."
        return 1
      }
    fi
    if ! code_parse ombdone "$code"; then
      ui_fail "That is not a completion code, or a character was mistyped."
    elif [ "$CODE_PLAN" != "$SHARED_DIGEST" ]; then
      ui_fail "That code belongs to a different plan ($CODE_PLAN, this one is $SHARED_DIGEST)."
    elif [ "$CODE_ID12" != "$(guid12 "$ASAHI_ROOT_UUID")" ]; then
      ui_fail "That code was made on a different Linux partition than the one on this disk."
    else
      state_must_set shared_linux_done "$code" || return 1
      SHARED_TYPED_RECEIPT=$code
      SHARED_STATE=awaiting-macos-creation
      ui_ok "Linux's completion code matches this disk."
      return 0
    fi
    code=""
  done
}

# shared_mac_after EXIT — what the disk looks like after addPartition, judged
# by the creation record exactly as every later run judges it (shared_mac_state
# → shared_txn_check). Anything but exactly one new exFAT partition in the
# region it was given, with every other partition unchanged, stops, and the
# stop is recorded: nothing is repaired automatically.
shared_mac_after() {
  local rc=$1
  mac_read_container
  mac_detect_geometry
  ui_section "After diskutil" "the disk, read again"
  shared_mac_state
  if [ "$SHARED_STATE" = created ]; then
    [ "$rc" = 0 ] || ui_warn "diskutil exited with status $rc, but the partition it was asked for is there and checks out."
    shared_mac_record
    return
  fi
  if [ "$TXN_RESULT" = none ] && [ "$SHARED_STATE" != blocked ]; then
    if [ "$rc" != 0 ]; then
      ui_fail "diskutil reported an error (exit $rc) and no partition was created. The disk is as it was; it is safe to try again."
    else
      ui_fail "diskutil reported success, but no new partition is on the disk. Nothing else changed; check diskutil list before trying again."
    fi
    # Nothing happened, so there is nothing for the record to vouch for.
    state_remove_file "$SHARED_TXN_FILE"
    return 1
  fi
  shared_after_stop "$SHARED_WHY"
  return 1
}

# shared_after_stop REASON — the creation's result is not what it may be. The
# creation record stays, so every later run is held to the same check.
shared_after_stop() {
  state_set shared_blocked_reason "$1"
  ui_blockers "Stopped: the result is not what was planned." "$(printf "%s\n" "$1" "Nothing will be repaired automatically. Before running any installer or this command again, read docs/SHARED.md; diskutil list shows the disk as it is now.")"
}

# shared_mac_record — the identity Linux will look for, recorded and shown.
# Once it is recorded, the creation record has done its job.
shared_mac_record() {
  state_must_set shared_uuid "$SHARED_UUID" || return 1
  state_set shared_size "$SHARED_SIZE"
  state_set shared_mount "$SHARED_MOUNT"
  state_set shared_created_at "$(now_utc)"
  state_unset shared_blocked_reason
  state_remove_file "$SHARED_TXN_FILE"
  ui_ok "Shared storage created: $SHARED_ID, $(fmt_gb "$SHARED_SIZE") exFAT${SHARED_MOUNT:+, mounted at $SHARED_MOUNT}."
  shared_linux_next
}

# shared_mac_reconcile — the partition exists: record it if that did not
# happen (a lost state write), and show what Linux needs. Never recreated.
shared_mac_reconcile() {
  if [ "$(state_get shared_uuid)" != "$SHARED_UUID" ]; then
    ui_info "The Shared partition is on the disk but was not recorded (the run that created it may have been interrupted). Recording it now; nothing is created again."
    shared_mac_record
    return
  fi
  ui_ok "Shared storage is in place: $SHARED_ID, $(fmt_gb "$SHARED_SIZE")${SHARED_MOUNT:+, at $SHARED_MOUNT}."
  shared_linux_next
}

shared_linux_next() {
  ui_callout linux "Next, on Linux" \
    "Boot Linux, open a terminal as your everyday user, and run ./omarchy-bootstrap shared activate. When it asks, type this code:"
  ui_cmd "$(shared_linux_code)"
  printf '\n'
}

# ---------------------------------------------------------------------------
# Linux: where Shared stands
# ---------------------------------------------------------------------------

# shared_lx_scan — the partitions on the disk holding root, from lsblk.
# SH_ROWS: "name|start_bytes|size|partuuid|parttype|fstype|label|uuid".
shared_lx_scan() {
  local all root
  SH_ROWS="" SH_DISK="" SH_ROOT_PARTUUID="" SH_ROOT_END=0
  root=${LX_ROOT_BACKING#/dev/}
  [ -n "$root" ] || return 1
  all=$(sys_cmd lsblk_all lsblk -bPno NAME,PKNAME,TYPE,START,SIZE,PARTUUID,PARTTYPE,FSTYPE,LABEL,UUID |
    awk '
      function f(k,   re, v) {
        re = "(^| )" k "=\"[^\"]*\""
        if (!match($0, re)) return ""
        v = substr($0, RSTART, RLENGTH)
        sub(/^ /, "", v)
        v = substr(v, length(k) + 3, length(v) - length(k) - 3)
        gsub(/\|/, "", v)
        return v
      }
      { print f("NAME") "|" f("PKNAME") "|" f("TYPE") "|" f("START") "|" f("SIZE") "|" tolower(f("PARTUUID")) "|" tolower(f("PARTTYPE")) "|" f("FSTYPE") "|" f("LABEL") "|" f("UUID") }')
  SH_DISK=$(printf '%s\n' "$all" | awk -F'|' -v r="$root" '$1 == r {print $2; exit}')
  [ -n "$SH_DISK" ] || return 1
  SH_ROWS=$(printf '%s\n' "$all" | awk -F'|' -v d="$SH_DISK" '$2 == d && $3 == "part" && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ {print $1 "|" $4 * 512 "|" $5 "|" $6 "|" $7 "|" $8 "|" $9 "|" $10}')
  local line name start size puuid
  while IFS='|' read -r name start size puuid _; do
    if [ "$name" = "$root" ]; then
      SH_ROOT_PARTUUID=$puuid SH_ROOT_END=$((start + size))
    fi
  done <<EOF
$SH_ROWS
EOF
  [ -n "$SH_ROOT_PARTUUID" ]
}

# shared_lx_state — after lx_detect and cfg_load. Sets SHARED_STATE,
# SHARED_WHY, SH_NEED_CODE, and for the partition found: SH_NAME,
# SH_PARTUUID, SH_SIZE, SH_FSUUID, SH_LABEL.
shared_lx_state() {
  local want=${CFG_shared:-0} id12 name start size puuid ptype fs label fsuuid n=0 near=0
  SHARED_STATE=off SHARED_WHY="" SH_NEED_CODE=0 SH_NAME="" SH_PARTUUID="" SH_SIZE=0 SH_FSUUID="" SH_LABEL=""
  local from=state
  id12=$(state_get shared_id12)
  # With the record lost, the entry this tool wrote in /etc/fstab still names
  # the partition it set up; it is checked like any other identity.
  if [ -z "$id12" ]; then
    id12=$(shared_fstab_managed_id12)
    from=fstab
  fi
  if [ "$want" = 0 ] && [ -z "$id12" ]; then
    return 0
  fi
  if ! lx_setup_complete; then
    SHARED_STATE=awaiting-linux-completion
    SHARED_WHY=$LX_INCOMPLETE_WHY
    return 0
  fi
  if ! shared_lx_scan; then
    _blocked "the disk holding the Linux root could not be read"
    return 0
  fi
  # Another definition of /mnt/shared (or of a volume named Shared) blocks
  # before anything else: the tool edits only the entry it wrote.
  shared_fstab_scan
  if [ "$FS_UNREADABLE" = 1 ]; then
    _blocked "/etc/fstab cannot be read here, so this tool cannot tell what it would be changing"
    return 0
  fi
  if [ -n "$FS_CONFLICTS" ]; then
    _blocked "/etc/fstab already has an entry for $SHARED_MNT or this partition that this tool did not write: $(printf '%s' "$FS_CONFLICTS" | head -1)"
    return 0
  fi
  while IFS='|' read -r name start size puuid ptype fs label fsuuid; do
    [ -n "$name" ] || continue
    [ "$ptype" = "$SHARED_PARTTYPE" ] || continue
    # Shared is the Basic Data partition right after the Linux root.
    [ "$start" -ge "$SH_ROOT_END" ] && [ $((start - SH_ROOT_END)) -lt "$ASAHI_GAP_MIN_BYTES" ] && near=$((near + 1))
    if [ -n "$id12" ] && [ "$(guid12 "$puuid")" = "$id12" ]; then
      n=$((n + 1))
      SH_NAME=$name SH_PARTUUID=$puuid SH_SIZE=$size SH_FSUUID=$fsuuid SH_LABEL=$label SH_FS=$fs SH_START=$start
    fi
  done <<EOF
$SH_ROWS
EOF
  if [ -z "$id12" ]; then
    if [ "$near" = 0 ]; then
      SHARED_STATE=awaiting-macos-creation
      SHARED_WHY="Linux has finished; Shared is created next, from macOS"
    else
      SHARED_STATE=awaiting-linux-activation SH_NEED_CODE=1
      SHARED_WHY="a partition is right after the Linux root; the code macOS showed identifies it"
    fi
    return 0
  fi
  if [ "$n" != 1 ] && [ "$from" = state ] && [ "$near" -gt 0 ]; then
    # A saved code that names nothing here (a stale or mistyped one): ask
    # for the code again rather than stay stuck on it.
    SHARED_STATE=awaiting-linux-activation SH_NEED_CODE=1
    SHARED_WHY="the saved Shared code ($id12...) names no partition here; type the code macOS showed"
    return 0
  fi
  if [ "$n" != 1 ]; then
    _blocked "the partition macOS created ($id12...) is not on this disk ($n match)"
    return 0
  fi
  if [ "$SH_FS" != exfat ]; then
    _blocked "$SH_NAME is not exFAT (filesystem: ${SH_FS:-none}); this tool never formats a partition that exists"
    return 0
  fi
  if [ "$SH_START" -lt "$SH_ROOT_END" ] || [ $((SH_START - SH_ROOT_END)) -ge "$ASAHI_GAP_MIN_BYTES" ]; then
    _blocked "$SH_NAME is not right after the Linux root"
    return 0
  fi
  if [ "$want" -gt 0 ] && [ "$SH_SIZE" -lt $((want * GB)) ]; then
    _blocked "$SH_NAME is $(fmt_gb "$SH_SIZE"), smaller than the $want GB planned"
    return 0
  fi
  shared_fstab_scan
  if [ "$FS_UNREADABLE" = 1 ]; then
    _blocked "/etc/fstab cannot be read here, so this tool cannot tell what it would be changing"
    return 0
  fi
  if [ -n "$FS_CONFLICTS" ]; then
    _blocked "/etc/fstab already has an entry for this partition or for $SHARED_MNT that this tool did not write: $(printf '%s' "$FS_CONFLICTS" | head -1)"
    return 0
  fi
  if [ -n "$FS_MANAGED" ]; then
    # Checked against the ids written in it, so root's doctor reads it too;
    # the everyday user must be the one it was written for.
    local mu mg
    mu=$(printf '%s' "$FS_MANAGED" | sed -n 's/.*,uid=\([0-9]*\),.*/\1/p')
    mg=$(printf '%s' "$FS_MANAGED" | sed -n 's/.*,gid=\([0-9]*\),.*/\1/p')
    if ! _uint "$mu" || ! _uint "$mg" || [ "$FS_MANAGED" != "$(SH_UID=$mu SH_GID=$mg shared_fstab_line)" ]; then
      _blocked "the entry this tool wrote in /etc/fstab no longer matches this partition"
    elif [ "$OMB_UID" != 0 ] && [ "$mu" != "$SH_UID" ]; then
      _blocked "Shared is mounted for uid $mu, not for you (uid $SH_UID)"
    else
      SH_UID=$mu SH_GID=$mg
      SHARED_STATE=ready
      SHARED_WHY="$SH_NAME mounts at $SHARED_MNT on every boot"
    fi
    return 0
  fi
  SHARED_STATE=awaiting-linux-activation
  SHARED_WHY="$SH_NAME is there; it is not mounted on boot yet"
}

# shared_mount_options — for the everyday user: exFAT has no owners or
# permissions, so they are presented from the mount; nothing on it runs.
shared_mount_options() {
  printf 'rw,nofail,x-systemd.automount,x-systemd.device-timeout=10s,uid=%s,gid=%s,fmask=0177,dmask=0077,nodev,nosuid,noexec' "$SH_UID" "$SH_GID"
}
shared_fstab_line() {
  printf 'PARTUUID=%s %s exfat %s 0 0' "$SH_PARTUUID" "$SHARED_MNT" "$(shared_mount_options)"
}

# shared_fstab_scan — FS_MANAGED: the line under our marker; FS_CONFLICTS:
# other active lines about this partition or /mnt/shared, one per line.
# Problems inside the block this tool claims come first (a foreign line under
# its marker, a second marker), then the rest in file order; the first line
# is the one shown. Duplicates are dropped by exact bytes, never by the
# locale's collation, so every platform reports the same first conflict.
shared_fstab_scan() {
  local f line prev="" dev mp marks=0 lower own=""
  FS_MANAGED="" FS_CONFLICTS="" FS_UNREADABLE=0
  SH_UID=${SH_UID:-$(sys_cmd id_u id -u)} SH_GID=${SH_GID:-$(sys_cmd id_g id -g)}
  f=$(sys_path /etc/fstab)
  [ -e "$f" ] || return 0
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    FS_UNREADABLE=1
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$prev" = "$SHARED_FSTAB_MARK" ]; then
      prev=""
      # The line under the marker is ours only if it has our shape.
      if printf '%s' "$line" | grep -Eq "^PARTUUID=[0-9a-f-]+ $SHARED_MNT exfat "; then
        FS_MANAGED=$line
        continue
      fi
      own="$own(under this tool's marker) $line
"
    fi
    if [ "$line" = "$SHARED_FSTAB_MARK" ]; then
      marks=$((marks + 1))
      prev=$line
      continue
    fi
    prev=$line
    case "$line" in '#'* | '') continue ;; esac
    set -f
    # shellcheck disable=SC2086 # fstab fields are whitespace-separated
    set -- $line
    set +f
    dev=${1:-} mp=${2:-}
    lower=$(printf '%s' "$dev" | tr -d "\"'" | tr '[:upper:]' '[:lower:]')
    mp=${mp%/}
    case "$lower" in
      "label=$(printf '%s' "$SHARED_LABEL" | tr '[:upper:]' '[:lower:]')" | "partlabel=shared" | "/dev/disk/by-label/shared" | "/dev/disk/by-partlabel/shared")
        FS_CONFLICTS="$FS_CONFLICTS$line
"
        continue
        ;;
    esac
    if [ -n "$SH_PARTUUID" ]; then
      case "$lower" in
        "partuuid=$SH_PARTUUID" | "/dev/disk/by-partuuid/$SH_PARTUUID" | "/dev/$SH_NAME")
          FS_CONFLICTS="$FS_CONFLICTS$line
"
          continue
          ;;
      esac
    fi
    if [ -n "$SH_FSUUID" ]; then
      case "$lower" in
        "uuid=$(printf '%s' "$SH_FSUUID" | tr '[:upper:]' '[:lower:]')" | "/dev/disk/by-uuid/$(printf '%s' "$SH_FSUUID" | tr '[:upper:]' '[:lower:]')")
          FS_CONFLICTS="$FS_CONFLICTS$line
"
          continue
          ;;
      esac
    fi
    [ "$mp" = "$SHARED_MNT" ] && FS_CONFLICTS="$FS_CONFLICTS$line
"
  done <"$f"
  [ "$marks" -gt 1 ] && own="$own$marks copies of this tool's marker
"
  FS_CONFLICTS=$(printf '%s%s' "$own" "$FS_CONFLICTS" | awk '!seen[$0]++')
}

# shared_completion_code — what macOS needs to know Linux has finished.
# Needs the plan's digest from the resume token (CFG_plan).
shared_completion_code() {
  code_make ombdone "$CFG_plan" "$SH_ROOT_PARTUUID"
}

# ---------------------------------------------------------------------------
# Linux: activating it
# ---------------------------------------------------------------------------

# shared_activate [SHARE_CODE] — mount Shared at /mnt/shared on every boot.
shared_activate() {
  OMB_PHASE=linux
  [ -n "${LX_ARCH:-}" ] || lx_detect
  cfg_load
  if [ -z "${CFG_user:-}" ] && [ -f "$STATE_SYSTEM_FILE" ]; then
    cfg_load "$STATE_SYSTEM_FILE"
  fi
  ui_header "linux $G_DOT shared storage$([ "$OMB_DRY_RUN" = 1 ] && printf ' %s dry run' "$G_DOT")"
  shared_activate_flow "${1:-}"
}

# shared_activate_flow [SHARE_CODE] — used by `shared activate` and by the
# guided flow once Omarchy is installed.
shared_activate_flow() {
  local code=${1:-} tmp cur f rc
  if [ "$OMB_UID" = 0 ] && [ "$OMB_DRY_RUN" != 1 ]; then
    ui_fail "Run this as your everyday user: Shared is mounted for that user, and it uses sudo where needed."
    return 1
  fi
  SH_UID=$(sys_cmd id_u id -u) SH_GID=$(sys_cmd id_g id -g)
  if ! _uint "$SH_UID" || ! _uint "$SH_GID" || { [ "$SH_UID" = 0 ] && [ "$OMB_DRY_RUN" != 1 ]; }; then
    ui_fail "Could not read your user and group ids."
    return 1
  fi
  shared_lx_state
  shared_status_rows
  case "$SHARED_STATE" in
    off | awaiting-linux-completion)
      printf '\n'
      return 0
      ;;
    awaiting-macos-creation)
      shared_lx_macos_next
      return 0
      ;;
    blocked)
      ui_blockers "Shared storage cannot be set up." "$(printf "%s\n" "$SHARED_WHY" "Nothing was changed. docs/SHARED.md explains each case.")"
      return 1
      ;;
    ready)
      ui_ok "Shared storage is already set up: nothing to change."
      printf '\n'
      return 0
      ;;
  esac
  if [ "$SH_NEED_CODE" = 1 ]; then
    shared_take_share_code "$code" || return 1
    shared_lx_state
    [ "$SHARED_STATE" = awaiting-linux-activation ] || {
      ui_blockers "Shared storage cannot be set up." "$SHARED_WHY"
      return 1
    }
  fi
  ui_section "Mount Shared on every boot" "one managed line in /etc/fstab"
  ui_kv "Partition" "/dev/$SH_NAME" "$(fmt_gb "$SH_SIZE") exFAT${SH_LABEL:+, named $SH_LABEL}"
  ui_kv "Identity" "PARTUUID=$SH_PARTUUID"
  ui_kv "Mount point" "$SHARED_MNT" "mounted on first use; boot does not wait for it"
  ui_kv "Owner" "${LX_USER:-you} (uid $SH_UID, gid $SH_GID)" "files 0600, folders 0700 as shown by Linux"
  ui_kv "No programs run" "nodev,nosuid,noexec" "exFAT has no permissions to honour; scripts run with bash file"
  ui_note "exFAT: no Unix owners, permissions or symlinks, and names are case-insensitive. Keep a Linux home, package databases, containers and Git checkouts off it. It is not encrypted and not a backup."
  f=$(sys_path "$SHARED_MNT")
  if [ -e "$f" ] && ! grep -q " $SHARED_MNT " "$(sys_path /proc/self/mounts)" 2>/dev/null && [ -n "$(ls -A "$f" 2>/dev/null)" ]; then
    ui_blockers "Shared storage cannot be set up." "$SHARED_MNT already holds files; mounting over them would hide them. Move them away first."
    return 1
  fi
  if ! ui_confirm_word mount "Mount Shared at $SHARED_MNT on every boot."; then
    printf '\n'
    ui_info "Stopped. Nothing changed."
    return 1
  fi
  omb_tmp_init || return 1
  tmp="$OMB_TMP/fstab"
  cur=$(sys_path /etc/fstab)
  # The new file is the old one, every line kept, plus the managed pair —
  # built in two checked steps and proved before anything replaces it.
  if [ ! -f "$cur" ] || [ ! -r "$cur" ]; then
    ui_fail "/etc/fstab is missing or cannot be read; nothing was changed."
    return 1
  fi
  awk '{print}' "$cur" >"$tmp" || {
    ui_fail "Could not copy /etc/fstab; nothing was changed."
    return 1
  }
  printf '%s\n%s\n' "$SHARED_FSTAB_MARK" "$(shared_fstab_line)" >>"$tmp" || return 1
  local old_lines
  old_lines=$(awk 'END {print NR}' "$cur")
  if [ "$(awk 'END {print NR}' "$tmp")" != $((old_lines + 2)) ] ||
    ! head -n "$old_lines" "$tmp" | cmp -s - <(awk '{print}' "$cur"); then
    ui_fail "The new /etc/fstab would not keep every existing line; nothing was changed."
    return 1
  fi
  printf '\n'
  run sudo install -d -m 0755 -o root -g root "$SHARED_MNT" &&
    run sudo cp -p /etc/fstab /etc/fstab.omarchy-bootstrap.bak &&
    run sudo install -m 0644 -o root -g root "$tmp" /etc/fstab.omarchy-bootstrap.new &&
    run sudo mv -f /etc/fstab.omarchy-bootstrap.new /etc/fstab &&
    run sudo systemctl daemon-reload &&
    run sudo systemctl start "$SHARED_UNIT"
  rc=$?
  if [ "$OMB_DRY_RUN" = 1 ]; then
    printf '\n'
    ui_info "Dry run: /etc/fstab was not changed."
    return 0
  fi
  if [ "$rc" != 0 ]; then
    ui_fail "A step failed (exit $rc). /etc/fstab.omarchy-bootstrap.bak holds the previous file if it was replaced."
    return 1
  fi
  shared_lx_state
  if [ "$SHARED_STATE" != ready ]; then
    ui_fail "The mount is not configured as expected afterwards: ${SHARED_WHY:-$SHARED_STATE}."
    return 1
  fi
  state_set shared_partuuid "$SH_PARTUUID"
  state_set shared_activated_at "$(now_utc)"
  ui_ok "Shared storage mounts at $SHARED_MNT on every boot."
  ui_note "To prove it can be written: ./omarchy-bootstrap shared test"
  printf '\n'
}

# shared_take_share_code [CODE] — the code macOS showed after creating
# Shared; it names the partition by its GUID.
shared_take_share_code() {
  local code=$1
  ui_note "macOS showed a code (ombshare-...) when it created Shared. It tells this system which partition is Shared."
  while :; do
    if [ -z "$code" ]; then
      ui_ask code "Shared code ${C_DIM}(Enter to stop)${C_RESET}" "" || return 1
      [ -n "$code" ] || {
        printf '\n'
        ui_info "Stopped. Nothing changed."
        return 1
      }
    fi
    if ! code_parse ombshare "$code"; then
      ui_fail "That is not a Shared code, or a character was mistyped."
    elif [ -n "${CFG_plan:-}" ] && [ "$CODE_PLAN" != "$CFG_plan" ]; then
      ui_fail "That code belongs to a different plan ($CODE_PLAN, this one is $CFG_plan)."
    elif [ "$(shared_code_matches "$CODE_ID12")" != 1 ]; then
      ui_fail "No Basic Data partition right after the Linux root has that GUID; check the code macOS showed."
    else
      state_must_set shared_id12 "$CODE_ID12" || return 1
      return 0
    fi
    code=""
  done
}

# shared_code_matches ID12 — how many Basic Data partitions right after the
# Linux root carry that GUID prefix (after shared_lx_scan).
shared_code_matches() {
  local name start size puuid ptype n=0
  while IFS='|' read -r name start size puuid ptype _; do
    if [ -z "$name" ] || [ "$ptype" != "$SHARED_PARTTYPE" ]; then
      continue
    fi
    if [ "$start" -lt "$SH_ROOT_END" ] || [ $((start - SH_ROOT_END)) -ge "$ASAHI_GAP_MIN_BYTES" ]; then
      continue
    fi
    if [ "$(guid12 "$puuid")" = "$1" ]; then
      n=$((n + 1))
    fi
  done <<EOF
$SH_ROWS
EOF
  printf '%s' "$n"
}

shared_lx_macos_next() {
  if [ -z "${CFG_plan:-}" ]; then
    ui_warn "This system does not know the Shared plan's code. On macOS, ./omarchy-bootstrap resume shows the resume token; run ./omarchy-bootstrap resume <token> here once to load it."
    printf '\n'
    return 0
  fi
  state_set shared_linux_done_at "$(now_utc)"
  ui_callout linux "Next, on macOS" \
    "Linux has completely finished. Shut down, boot macOS (hold the power button, choose Macintosh HD), then run ./omarchy-bootstrap there. When it asks, type this code:"
  ui_cmd "$(shared_completion_code)"
  printf '\n'
}

# ---------------------------------------------------------------------------
# Both: a consented write test, and what status and doctor show
# ---------------------------------------------------------------------------

# shared_mountpoint — where Shared is mounted now, on this system.
shared_mountpoint() {
  case "$OMB_PLATFORM" in
    macos)
      [ "$SHARED_STATE" = created ] && printf '%s' "$SHARED_MOUNT"
      ;;
    linux)
      [ "$SHARED_STATE" = ready ] && printf '%s' "$SHARED_MNT"
      ;;
  esac
}

# shared_test — write, flush, read back and remove one uniquely named file.
shared_test() {
  local mp dst src sum rc
  ui_header "$OMB_PLATFORM $G_DOT shared storage test"
  if [ "$OMB_PLATFORM" = macos ]; then
    mac_survey
    shared_mac_state
  else
    lx_detect
    cfg_load
    shared_lx_state
  fi
  shared_status_rows
  mp=$(shared_mountpoint)
  if [ -z "$mp" ]; then
    ui_info "Shared storage is not ready on this system (${SHARED_STATE}); there is nothing to test yet."
    printf '\n'
    return 1
  fi
  ui_section "Write test" "one temporary file, then removed"
  ui_note "Creates one file in $mp, writes known bytes, flushes them to disk, reads them back, compares, and removes that file only."
  ui_confirm_word test "Run the write test on $mp." || {
    printf '\n'
    ui_info "Stopped. Nothing written."
    return 1
  }
  omb_tmp_init || return 1
  src="$OMB_TMP/shared-test"
  dst="$mp/.omarchy-bootstrap-test-$(now_stamp)-$$"
  awk 'BEGIN { for (i = 0; i < 16384; i++) printf "omarchy-bootstrap shared test %08d\n", i }' >"$src"
  sum=$(sha256_of "$src")
  if run cp "$src" "$dst" && run sync; then rc=0; else rc=1; fi
  if [ "$OMB_PLATFORM" = linux ] && [ "$OMB_DRY_RUN" != 1 ] && [ -z "${OMB_TEST_RECORD:-}" ] &&
    ! awk -v m="$SHARED_MNT" '$2 == m && $3 == "exfat"' "$(sys_path /proc/self/mounts)" | grep -q .; then
    ui_fail "$SHARED_MNT is not an exFAT mount after the write; nothing was verified."
    rc=1
  fi
  if [ "$OMB_DRY_RUN" = 1 ] || [ -n "${OMB_TEST_RECORD:-}" ]; then
    run rm -f "$dst"
    ui_info "Not run for real: the write, flush and removal above were only shown."
    return 0
  fi
  if [ "$rc" = 0 ] && [ -f "$dst" ] && [ "$(sha256_of "$dst")" = "$sum" ]; then
    run rm -f "$dst"
    ui_ok "Shared storage is writable: $(wc -c <"$src" | tr -d ' ') bytes written, flushed, read back identical, and removed."
    return 0
  fi
  [ -f "$dst" ] && run rm -f "$dst"
  ui_fail "The write test failed on $mp: the bytes read back were not the bytes written. Nothing was repaired; see docs/SHARED.md."
  return 1
}

# shared_status_rows — Shared's state for status and the shared screens.
shared_status_rows() {
  ui_section "Shared storage" "macOS $G_ARROW Linux"
  ui_kv "State" "$SHARED_STATE" "$SHARED_WHY"
  case "$SHARED_STATE" in
    off) return 0 ;;
  esac
  if [ "$OMB_PLATFORM" = macos ]; then
    [ -n "${INT_shared_request:-}" ] && ui_kv "Planned" "$(fmt_gb "$INT_shared_request")" "plan $SHARED_DIGEST"
    [ -n "$SHARED_UUID" ] && ui_kv "Partition" "${SHARED_ID:-?}" "$SHARED_UUID"
    [ -n "$SHARED_MOUNT" ] && ui_kv "Mounted at" "$SHARED_MOUNT"
  else
    [ "${CFG_shared:-0}" -gt 0 ] && ui_kv "Planned" "${CFG_shared} GB" "${CFG_plan:+plan $CFG_plan}"
    [ -n "$SH_PARTUUID" ] && ui_kv "Partition" "/dev/$SH_NAME" "PARTUUID=$SH_PARTUUID"
  fi
  return 0
}

# shared_status — read-only: where Shared stands on this system.
shared_status() {
  ui_header "$OMB_PLATFORM $G_DOT shared storage"
  if [ "$OMB_PLATFORM" = macos ]; then
    mac_detect
    cfg_load
    shared_mac_state
  else
    lx_detect
    cfg_load
    if [ -z "${CFG_user:-}" ] && [ -f "$STATE_SYSTEM_FILE" ]; then cfg_load "$STATE_SYSTEM_FILE"; fi
    shared_lx_state
  fi
  shared_status_rows
  ui_section "Next"
  ui_para "$(shared_next_action)"
  printf '\n'
}

shared_next_action() {
  case "$OMB_PLATFORM:$SHARED_STATE" in
    *:off) echo "No Shared storage is planned." ;;
    macos:reserved) echo "Install Asahi and Omarchy first; Shared is created after that, from macOS." ;;
    macos:awaiting-linux-completion) echo "Finish Omarchy on Linux; it then shows a completion code to type into ./omarchy-bootstrap shared create here." ;;
    macos:awaiting-macos-creation) echo "Run ./omarchy-bootstrap shared create." ;;
    macos:created) echo "On Linux, run ./omarchy-bootstrap shared activate with the code: $(shared_linux_code)" ;;
    linux:awaiting-linux-completion) echo "Let Omarchy Mac finish; Shared follows." ;;
    linux:awaiting-macos-creation) echo "Run ./omarchy-bootstrap here to see the completion code, then create Shared from macOS." ;;
    linux:awaiting-linux-activation) echo "Run ./omarchy-bootstrap shared activate as your everyday user." ;;
    linux:ready) echo "Nothing to do. ./omarchy-bootstrap shared test proves it can be written." ;;
    *) echo "Stop here: $SHARED_WHY. docs/SHARED.md explains each case; nothing is repaired automatically." ;;
  esac
}

# cmd_shared [status|create|activate|test] [CODE]
cmd_shared() {
  local sub=${1:-status} code=${2:-}
  case "$OMB_PLATFORM:$sub" in
    *:status) shared_status ;;
    macos:create) shared_create "$code" ;;
    linux:activate) shared_activate "$code" ;;
    *:test) shared_test ;;
    macos:activate)
      ui_fail "activate runs on Linux, after Shared has been created from macOS."
      return 2
      ;;
    linux:create)
      ui_fail "create runs on macOS: Shared is created there once Linux has finished."
      return 2
      ;;
    *)
      ui_fail "Unknown shared command: $sub (status, create, activate, test)."
      return 2
      ;;
  esac
}

# shared_intent_matches_plan — before the Asahi launch: the saved record is
# the plan about to run (same answers, same region, same reservation).
shared_intent_matches_plan() {
  [ "${PLAN_SHARED:-0}" = 0 ] && return 0
  [ "$OMB_PERSIST" = 1 ] || return 0
  shared_intent_load || return 1
  [ "$INT_macos_after" = "$PLAN_MACOS_NEW" ] && [ "$INT_linux_answer" = "$PLAN_ANSWER_OS" ] &&
    [ "$INT_shared_request" = "$PLAN_SHARED" ] && [ "$INT_region_start" = "$PLAN_GAP_START" ] &&
    [ "$INT_region_end" = "$PLAN_GAP_END" ] && [ "$INT_disk_size" = "$GEO_DISK_SIZE" ]
}

# shared_doctor — read-only checks. Reading proves presence, identity and
# mount configuration; only `shared test` proves writing.
shared_doctor() {
  local mounts line dev mp fs opts others avail
  case "$OMB_PLATFORM" in macos) shared_mac_state ;; linux) shared_lx_state ;; esac
  case "$SHARED_STATE" in
    off) return 0 ;;
    blocked) doc fail "Shared storage" "$SHARED_WHY" ; return 0 ;;
    created | ready) doc pass "Shared storage" "$SHARED_WHY" ;;
    *) doc info "Shared storage" "$SHARED_STATE: $SHARED_WHY" ; return 0 ;;
  esac
  if [ "$OMB_PLATFORM" = macos ]; then
    doc pass "Shared identity" "$SHARED_ID $G_DOT GUID $SHARED_UUID $G_DOT exFAT, Basic Data"
    if [ -n "$SHARED_MOUNT" ]; then
      avail=$(sys_cmd df_shared df -Pk "$SHARED_MOUNT" | awk 'NR==2 {print $4}')
      doc pass "Shared mounted" "$SHARED_MOUNT${avail:+ $G_DOT $((avail / 1000000)) GB free}"
    else
      doc warn "Shared mounted" "not mounted in macOS (Disk Utility can mount it)"
    fi
    doc info "Shared writing" "not checked by doctor; ./omarchy-bootstrap shared test writes and removes one file"
    return 0
  fi
  doc pass "Shared identity" "/dev/$SH_NAME $G_DOT PARTUUID=$SH_PARTUUID $G_DOT exFAT $G_DOT $(fmt_gb "$SH_SIZE")"
  doc pass "Shared on boot" "/etc/fstab: $SHARED_MNT, uid $SH_UID, nofail, automount"
  mounts=$(cat "$(sys_path /proc/self/mounts)" 2>/dev/null)
  line=$(printf '%s\n' "$mounts" | awk -v m="$SHARED_MNT" '$2 == m && $3 == "exfat"' | head -1)
  if [ -n "$line" ]; then
    set -f
    # shellcheck disable=SC2086 # /proc/mounts fields are whitespace-separated
    set -- $line
    set +f
    opts=$4
    case ",$opts," in
      *,ro,*) doc warn "Shared mounted" "read-only: the kernel remounts exFAT read-only after an error; check it from macOS (First Aid)" ;;
      *) doc pass "Shared mounted" "$1 at $SHARED_MNT ($opts)" ;;
    esac
    avail=$(sys_cmd df_shared df -Pk "$SHARED_MNT" | awk 'NR==2 {print $4}')
    [ -n "$avail" ] && doc info "Shared free space" "$((avail / 1000000)) GB"
  elif printf '%s\n' "$mounts" | awk -v m="$SHARED_MNT" '$2 == m && $3 == "autofs"' | grep -q .; then
    doc pass "Shared mounted" "automount armed; mounts on first use"
  else
    doc warn "Shared mounted" "not mounted and no automount active: sudo systemctl start $SHARED_UNIT"
  fi
  others=$(printf '%s\n' "$mounts" | awk -v d="/dev/$SH_NAME" -v m="$SHARED_MNT" '$1 == d && $2 != m {print $2}' | head -1)
  [ -n "$others" ] && doc warn "Shared mounted twice" "also at $others; unmount that copy"
  doc info "Shared writing" "not checked by doctor; ./omarchy-bootstrap shared test writes and removes one file"
}

# shared_fstab_managed_id12 — the partition the managed fstab entry names.
shared_fstab_managed_id12() {
  local f
  f=$(sys_path /etc/fstab)
  [ -f "$f" ] || return 0
  awk -v m="$SHARED_FSTAB_MARK" 'hit {print; exit} $0 == m {hit = 1}' "$f" |
    sed -n 's/^PARTUUID=\([0-9a-f-]*\) .*/\1/p' | tr -d '-' | cut -c1-12
}
