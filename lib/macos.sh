# shellcheck shell=bash
# Phase 1 — macOS: survey, storage plan, choices, backup gate, and the
# provenance-first handoff to the Asahi Alarm installer.

# plist_get PLIST_TEXT KEYPATH — structured extraction via plutil.
plist_get() {
  [ -n "$1" ] || return 1
  printf '%s' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null
}

# The only resizeContainer invocation in this repository: the read-only
# "limits" query the Asahi installer itself uses. The container must look like
# a disk identifier, and "limits -plist" is literal — no size is ever passed.
mac_resize_limits() {
  case "$1" in
    disk[0-9]*) ;;
    *) return 1 ;;
  esac
  case "$1" in *[!a-z0-9]*) return 1 ;; esac
  sys_cmd "diskutil_limits_$1" diskutil apfs resizeContainer "$1" limits -plist
}

mac_detect() {
  local hw lim

  MAC_ARCH=$(sys_cmd uname_m uname -m)
  MAC_ARM64=$(sys_cmd sysctl_arm64 sysctl -n hw.optional.arm64)
  MAC_MODEL_ID=$(sys_cmd sysctl_hw_model sysctl -n hw.model)
  MAC_MEM_BYTES=$(sys_cmd sysctl_memsize sysctl -n hw.memsize)
  MAC_CPU=$(sys_cmd sysctl_cpu_brand sysctl -n machdep.cpu.brand_string)
  MAC_OS_VERSION=$(sys_cmd sw_vers sw_vers -productVersion)
  hw=$(sys_cmd hardware_plist system_profiler -xml SPHardwareDataType)
  MAC_MACHINE_NAME=$(plist_get "$hw" 0._items.0.machine_name)
  MAC_CHIP=$(plist_get "$hw" 0._items.0.chip_type)
  [ -n "$MAC_CHIP" ] || MAC_CHIP=$MAC_CPU

  if [ "$MAC_ARCH" = arm64 ] && [ "${MAC_ARM64:-0}" = 1 ]; then
    MAC_APPLE_SILICON=1
  else
    MAC_APPLE_SILICON=0
  fi
  device_by_model "$MAC_MODEL_ID"
  [ "$MAC_APPLE_SILICON" = 1 ] || DEV_TIER=unsupported

  mac_read_container
  mac_detect_geometry

  MAC_LIMIT_PREF=""
  if [ -n "$MAC_CONTAINER" ] && lim=$(mac_resize_limits "$MAC_CONTAINER"); then
    MAC_LIMIT_PREF=$(plist_get "$lim" MinimumSizePreferred)
  fi
  _uint "${MAC_LIMIT_PREF:-}" || MAC_LIMIT_PREF=""

  MAC_FILEVAULT=$(sys_cmd fdesetup_isactive fdesetup isactive)
  case " $(sys_cmd id_groups id -Gn) " in *" admin "*) MAC_ADMIN=1 ;; *) MAC_ADMIN=0 ;; esac
  MAC_USER=$(sys_cmd id_un id -un)
  MAC_TZ=$(sys_cmd localtime readlink /etc/localtime | sed 's#.*/zoneinfo/##')
  MAC_LOCALE=$(sys_cmd apple_locale defaults read -g AppleLocale)
  MAC_KEYBOARD=$(sys_cmd keyboard_layout defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID)
  MAC_TM_INFO=$(sys_cmd tmutil_destinations tmutil destinationinfo | sed -n 's/^Kind *: *//p' | head -1)
  MAC_TM_LATEST=$(sys_cmd tmutil_latest tmutil latestbackup | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' | tail -1 |
    sed -E 's/^([0-9-]{10})-([0-9]{2})([0-9]{2})[0-9]{2}$/\1 \2:\3/')
}

# mac_read_container — follow / to its APFS container, physical store and
# whole disk. A second physical store (a Fusion-style container) is not
# something this tool plans around.
mac_read_container() {
  local root store
  root=$(sys_cmd diskutil_info_root diskutil info -plist /)
  MAC_ROOT_VOLUME=$(plist_get "$root" VolumeName)
  MAC_CONTAINER=$(plist_get "$root" APFSContainerReference)
  MAC_CONTAINER_SIZE=$(plist_get "$root" APFSContainerSize)
  MAC_CONTAINER_FREE=$(plist_get "$root" APFSContainerFree)
  MAC_STORE=$(plist_get "$root" APFSPhysicalStores.0.APFSPhysicalStore)
  MAC_STORES_EXTRA=$(plist_get "$root" APFSPhysicalStores.1.APFSPhysicalStore)
  MAC_DISK="" MAC_DISK_INTERNAL=false
  if [ -n "$MAC_STORE" ]; then
    store=$(sys_cmd "diskutil_info_$MAC_STORE" diskutil info -plist "$MAC_STORE")
    MAC_DISK=$(plist_get "$store" ParentWholeDisk)
    MAC_DISK_INTERNAL=$(plist_get "$store" Internal)
  fi
}

# mac_recheck_plan — right before the launch: read the disk again, and hold
# the answers on the card to what the fresh reading gives. Any difference
# stops the launch; the plan shown is the plan that runs, or nothing does.
mac_recheck_plan() {
  local canon ans_r=$PLAN_ANSWER_RESIZE ans_os=$PLAN_ANSWER_OS
  canon=$(geo_canon)
  mac_read_container
  mac_detect_geometry
  if [ "$GEO_OK" != 1 ] || [ "$(geo_canon)" != "$canon" ]; then
    ui_fail "The internal disk's partition layout changed since it was surveyed. Nothing was launched; run ./omarchy-bootstrap again."
    return 1
  fi
  mac_plan_compute "${CFG_shared:-0}"
  plan_layout $((CFG_linux * GB))
  if [ "$PLAN_OK" != 1 ] || [ "$PLAN_ANSWER_RESIZE" != "$ans_r" ] || [ "$PLAN_ANSWER_OS" != "$ans_os" ]; then
    ui_fail "macOS's free space changed since the plan was made, and the answers shown no longer hold${PLAN_ERR:+ ($PLAN_ERR)}. Nothing was launched; run ./omarchy-bootstrap again."
    return 1
  fi
  return 0
}

# mac_detect_geometry — the internal disk as exact extents. Offsets and GPT
# GUIDs come from `diskutil info -plist` for each partition (the list view
# has neither), cross-checked against `diskutil list -plist`; anything
# missing or disagreeing leaves GEO_OK=0 and planning blocked, never guessed.
# Sets MAC_PARTS ("id|content|size|role|uuid" per partition, disk order),
# MAC_DISK_SIZE, MAC_DISK_BLOCK, MAC_APPLE_SYS, MAC_OTHER_BYTES,
# MAC_ASAHI_PRESENT, MAC_OTHER_APFS, MAC_EXISTING_FREE (display only).
mac_detect_geometry() {
  local list dinfo info i content size id uuid off lsize luuid label fstype count
  geo_reset
  MAC_PARTS="" MAC_APPLE_SYS=0 MAC_OTHER_BYTES=0 MAC_ASAHI_PRESENT=0 MAC_OTHER_APFS=""
  MAC_DISK_SIZE=0 MAC_DISK_BLOCK="" MAC_EXISTING_FREE=0 MAC_STORE_UUID="" MAC_WHOLE_INTERNAL=""
  if [ -z "$MAC_DISK" ]; then
    GEO_ERR="the boot volume's physical disk was not found"
    return 1
  fi
  list=$(sys_cmd "diskutil_list_$MAC_DISK" diskutil list -plist "$MAC_DISK")
  dinfo=$(sys_cmd "diskutil_info_$MAC_DISK" diskutil info -plist "$MAC_DISK")
  MAC_DISK_SIZE=$(plist_get "$dinfo" Size)
  MAC_DISK_BLOCK=$(plist_get "$dinfo" DeviceBlockSize)
  MAC_DISK_MEDIA=$(plist_get "$dinfo" IORegistryEntryName)
  MAC_WHOLE_INTERNAL=$(plist_get "$dinfo" Internal)
  if ! _uint "${MAC_DISK_SIZE:-}" || [ "$MAC_DISK_SIZE" != "$(plist_get "$list" AllDisksAndPartitions.0.Size)" ]; then
    GEO_ERR="diskutil list and diskutil info disagree about the size of $MAC_DISK"
    MAC_DISK_SIZE=0
  fi
  i=0
  while content=$(plist_get "$list" "AllDisksAndPartitions.0.Partitions.$i.Content"); do
    id=$(plist_get "$list" "AllDisksAndPartitions.0.Partitions.$i.DeviceIdentifier")
    lsize=$(plist_get "$list" "AllDisksAndPartitions.0.Partitions.$i.Size")
    luuid=$(plist_get "$list" "AllDisksAndPartitions.0.Partitions.$i.DiskUUID")
    i=$((i + 1))
    case "$id" in
      disk[0-9]*s[0-9]*) ;;
      *)
        GEO_ERR=${GEO_ERR:-"partition $((i - 1)) has no device identifier"}
        continue
        ;;
    esac
    case "$id" in *[!a-z0-9]*) GEO_ERR=${GEO_ERR:-"unexpected device identifier"} && continue ;; esac
    info=$(sys_cmd "diskutil_info_$id" diskutil info -plist "$id")
    off=$(plist_get "$info" PartitionMapPartitionOffset)
    size=$(plist_get "$info" Size)
    uuid=$(plist_get "$info" DiskUUID)
    label=$(plist_get "$info" VolumeName)
    fstype=$(plist_get "$info" FilesystemType)
    # Sizes reach shell arithmetic, which evaluates array subscripts: only a
    # canonical number goes further.
    if ! _uint "$off" || ! _uint "$size"; then
      GEO_ERR=${GEO_ERR:-"diskutil gave no usable offset or size for $id"}
      continue
    fi
    if [ "$size" != "$lsize" ] || [ "$uuid" != "$luuid" ]; then
      GEO_ERR=${GEO_ERR:-"diskutil list and diskutil info disagree about $id"}
    fi
    case "$uuid" in
      [0-9A-F]*-*-*-*-*) ;;
      *) GEO_ERR=${GEO_ERR:-"$id has no partition GUID"} ;;
    esac
    [ "$id" = "$MAC_STORE" ] && MAC_STORE_UUID=$uuid
    mac_classify_partition "$id" "$content" "$size" "$uuid" "$fstype"
    geo_add "$off" "$size" "$uuid" "$content" "$id" "$MAC_PART_ROLE"
    MAC_PARTS="$MAC_PARTS$id|$content|$size|$MAC_PART_ROLE|$uuid|$label
"
  done
  [ "$i" -gt 0 ] || GEO_ERR=${GEO_ERR:-"no partitions were listed on $MAC_DISK"}
  # The loop stops at the first entry without Content; the array length says
  # whether that was the end.
  count=$(plist_get "$list" AllDisksAndPartitions.0.Partitions)
  if [ "$i" -gt 0 ] && [ "$count" != "$i" ]; then
    GEO_ERR=${GEO_ERR:-"diskutil lists ${count:-an unknown number of} partitions on $MAC_DISK, and $i could be read"}
  fi
  geo_finalize "$MAC_DISK_SIZE" "${MAC_DISK_BLOCK:-0}" || return 1
  local start gsize pred succ
  while IFS='|' read -r start gsize pred succ; do
    [ -n "$start" ] && MAC_EXISTING_FREE=$((MAC_EXISTING_FREE + gsize))
  done <<EOF
$GEO_GAPS
EOF
  return 0
}

# mac_classify_partition ID CONTENT SIZE UUID FSTYPE — sets MAC_PART_ROLE and
# tallies. Stock Apple Silicon disks have three partitions: the iBoot system
# container, the macOS container, and the recovery container. Asahi adds a
# stub APFS container, an EFI partition and a Linux partition. Shared is a
# Basic Data partition (data-exfat); lib/shared.sh decides whether it is ours.
mac_classify_partition() {
  local id=$1 content=$2 size=$3 uuid=$4 fstype=${5:-}
  case "$content" in
    Apple_APFS_ISC)
      MAC_PART_ROLE=isc
      MAC_APPLE_SYS=$((MAC_APPLE_SYS + size))
      ;;
    Apple_APFS_Recovery)
      MAC_PART_ROLE=recovery
      MAC_APPLE_SYS=$((MAC_APPLE_SYS + size))
      ;;
    Apple_APFS)
      if [ "$id" = "$MAC_STORE" ]; then
        MAC_PART_ROLE=macos
      elif [ "$size" -lt $((ASAHI_STUB_BYTES * 2)) ]; then
        MAC_PART_ROLE="asahi-stub"
        MAC_ASAHI_PRESENT=1
        MAC_OTHER_BYTES=$((MAC_OTHER_BYTES + size))
      else
        MAC_PART_ROLE="other-apfs"
        MAC_OTHER_APFS="$MAC_OTHER_APFS $id"
        MAC_OTHER_BYTES=$((MAC_OTHER_BYTES + size))
      fi
      ;;
    EFI | *[Ee][Ff][Ii]*)
      MAC_PART_ROLE=efi
      MAC_ASAHI_PRESENT=1
      MAC_OTHER_BYTES=$((MAC_OTHER_BYTES + size))
      ;;
    *[Ll]inux* | 0FC63DAF-8483-4772-8E79-3D69D8477DE4)
      MAC_PART_ROLE=linux
      MAC_ASAHI_PRESENT=1
      MAC_OTHER_BYTES=$((MAC_OTHER_BYTES + size))
      ;;
    Microsoft\ Basic\ Data | EBD0A0A2-B9E5-4433-87C0-68B6B72699C7)
      MAC_PART_ROLE="data${fstype:+-$fstype}"
      MAC_OTHER_BYTES=$((MAC_OTHER_BYTES + size))
      ;;
    *)
      MAC_PART_ROLE=other
      MAC_OTHER_BYTES=$((MAC_OTHER_BYTES + size))
      ;;
  esac
}

# mac_blockers — prints one reason per line; empty means planning may proceed.
mac_blockers() {
  [ "$MAC_APPLE_SILICON" = 1 ] || echo "This Mac is not Apple Silicon ($MAC_ARCH). Asahi Linux runs only on Apple Silicon."
  if [ "$MAC_APPLE_SILICON" = 1 ] && [ "$DEV_TIER" = unsupported ]; then
    if [ -n "$DEV_NAME" ]; then
      echo "$DEV_NAME ($DEV_CHIP) is not supported by the Asahi installer yet."
    else
      echo "$MAC_MODEL_ID is not in the Asahi device list."
    fi
  fi
  ver_ge "${MAC_OS_VERSION:-0}" "$ASAHI_MIN_MACOS" || echo "macOS $MAC_OS_VERSION is older than $ASAHI_MIN_MACOS, which the Asahi Alarm installer requires."
  [ "$MAC_DISK_INTERNAL" = true ] || echo "The boot volume is not on an internal disk (disk ${MAC_DISK:-unknown})."
  [ "$MAC_ADMIN" = 1 ] || echo "$MAC_USER is not an administrator; the installer needs a machine admin."
  [ -n "${MAC_STORES_EXTRA:-}" ] && echo "The macOS container spans more than one physical store ($MAC_STORE, $MAC_STORES_EXTRA); the installer resizes only single-store containers."
  # The layout must be known exactly before anything is planned on it.
  if [ "$GEO_OK" != 1 ]; then
    echo "The internal disk's partition layout could not be read exactly: $GEO_ERR. Planning needs the position of every partition, so nothing is guessed."
    return 0
  fi
  if [ -n "$MAC_OTHER_APFS" ]; then
    echo "Another APFS container is on the internal disk ($(printf '%s' "$MAC_OTHER_APFS" | sed 's/^ //')). This tool plans only for a disk with one macOS container; the installer would ask which one to resize."
  fi
  [ -n "$PLAN_TOPO_ERR" ] && echo "The macOS container cannot be planned around: $PLAN_TOPO_ERR."
  # Space is a blocker only before an install; after one, the partitions exist.
  if [ "$MAC_ASAHI_PRESENT" != 1 ] && [ -z "$PLAN_TOPO_ERR" ] && [ "${PLAN_LINUX_MAX:-0}" -lt "${PLAN_LINUX_MIN:-1}" ]; then
    if [ "$PLAN_LIMITS_KNOWN" != 1 ]; then
      printf 'diskutil did not report the resize limits of %s, so the installer'"'"'s own minimum for macOS cannot be predicted and no resize is planned on a guess. Restart macOS and try again; if it persists, run First Aid on the container from Recovery.' "${MAC_CONTAINER:-the container}"
    else
      printf 'Not enough space for Linux yet: free about %s more in macOS (Linux needs %s in one region).' \
        "$(fmt_gb "$PLAN_SHORTFALL")" "$(fmt_gb "$PLAN_LINUX_MIN")"
      [ "$PLAN_OVERHEAD_WARN" = 1 ] && printf ' APFS snapshots hold %s; see %s.' "$(fmt_gb "$PLAN_OVERHEAD")" "$ASAHI_TM_CLEANUP"
    fi
    printf '\n'
  fi
  return 0
}

# mac_plan_compute [SHARED_GB] — the planner for this disk. No reservation
# unless one is passed: a saved Shared size must not shrink the survey,
# presets or status before the Shared question has been answered again.
mac_plan_compute() {
  plan_init "$MAC_STORE_UUID" "$MAC_CONTAINER_SIZE" "$MAC_CONTAINER_FREE" "$MAC_LIMIT_PREF"
  plan_compute $(( ${1:-0} * GB ))
}

# mac_gap_label START — how the installer names a free region: after the
# partition before it. "the free space after disk0s2".
mac_gap_label() {
  local start size pred succ
  while IFS='|' read -r start size pred succ; do
    if [ "$start" = "$1" ] && [ -n "$pred" ] && geo_part "$pred"; then
      printf 'the free space after %s' "$GP_ID"
      return 0
    fi
  done <<EOF
$GEO_ALLGAPS
EOF
  printf 'the free space at %s' "$(fmt_gb "$1")"
}

# mac_gap_count — MAC_GAP_COUNT: how many free regions the installer will
# offer at "Install an OS into free space" once any planned resize is done
# (the region after the container then includes what the resize frees).
mac_gap_count() {
  local start size pred succ
  MAC_GAP_COUNT=1
  while IFS='|' read -r start size pred succ; do
    [ -n "$start" ] || continue
    [ "$start" = "$PLAN_GAP_START" ] && continue
    [ "$PLAN_MODE" = resize ] && [ "$pred" = "$PLAN_MACOS_UUID" ] && continue
    [ $((size / MIB * MIB)) -ge "$ASAHI_INSTALL_MIN_BYTES" ] && MAC_GAP_COUNT=$((MAC_GAP_COUNT + 1))
  done <<EOF
$GEO_GAPS
EOF
}

# mac_gap_label_planned — the planned region as the installer names it.
mac_gap_label_planned() {
  if geo_part "$PLAN_GAP_PRED"; then printf 'after %s' "$GP_ID"; else printf 'first'; fi
}

# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

# mac_rail ACTIVE — stages derive from facts, the active one is highlighted.
mac_rail() {
  local active=$1 out="" s st
  for s in $RAIL_STAGES; do
    if [ "$s" = "$active" ]; then
      st=current
    else
      case "$s" in
        survey) st="done" ;;
        plan) [ -n "${CFG_linux:-}" ] && st="done" || st=todo ;;
        asahi) [ "$MAC_ASAHI_PRESENT" = 1 ] && st="done" || st=todo ;;
        *) st=todo ;;
      esac
    fi
    out="$out $st"
  done
  ui_rail "${out# }"
}

mac_screen() {
  ui_header "macOS $G_DOT phase 1$([ "$OMB_DRY_RUN" = 1 ] && printf ' %s dry run' "$G_DOT")"
  mac_rail "$1"
}

mac_show_survey() {
  mac_screen survey
  ui_section "Machine" "$MAC_MODEL_ID"
  ui_kv "Model" "${DEV_NAME:-${MAC_MACHINE_NAME:-unknown}}"
  ui_kv "Chip" "$MAC_CHIP" "${DEV_SOC:+$DEV_SOC $G_DOT board $DEV_BOARD}"
  ui_kv "Memory" "$(( ${MAC_MEM_BYTES:-0} / 1073741824 )) GB"
  ui_kv "macOS" "$MAC_OS_VERSION" "FileVault $([ "$MAC_FILEVAULT" = true ] && echo on || echo off)"

  ui_section "Storage" "${MAC_DISK:-?} $G_DOT container ${MAC_CONTAINER:-?} on ${MAC_STORE:-?}"
  ui_kv "Internal SSD" "$(fmt_gb "$MAC_DISK_SIZE")" "$( [ "$MAC_DISK_INTERNAL" = true ] && echo "internal, boot disk" || echo "NOT internal")${MAC_DISK_BLOCK:+ $G_DOT $MAC_DISK_BLOCK-byte blocks}"
  ui_kv "macOS container" "$(fmt_gb "$MAC_CONTAINER_SIZE")" "$MAC_ROOT_VOLUME"
  ui_kv "Used by macOS" "$(fmt_gb "$PLAN_USED")"
  ui_kv "Free in macOS" "$(fmt_gb "$MAC_CONTAINER_FREE")" "purgeable space not counted"
  # Each free region separately: the installer can use only one of them.
  local gstart gsize gpred gsucc
  while IFS='|' read -r gstart gsize gpred gsucc; do
    [ -n "$gstart" ] && ui_kv "Unpartitioned" "$(fmt_gb "$gsize")" "$(mac_gap_label "$gstart")"
  done <<EOF
$GEO_GAPS
EOF
  ui_kv "Required reserve" "$(fmt_gb "$PLAN_RESERVE")" "$(fmt_gb "$ASAHI_MIN_FREE_OS_BYTES") for updates$([ "$PLAN_OVERHEAD" -gt 0 ] && printf ' + %s overhead' "$(fmt_gb "$PLAN_OVERHEAD")") + $(fmt_gb "$PLAN_DRIFT_MARGIN_BYTES") margin"
  if [ "$PLAN_LINUX_MAX" -ge "$PLAN_LINUX_MIN" ]; then
    ui_kv "Safe Linux maximum" "${C_BOLD}$(fmt_gb "$PLAN_LINUX_MAX")${C_RESET}"
  else
    ui_kv "Safe Linux maximum" "${C_FAIL}$(fmt_gb "$PLAN_LINUX_MAX")${C_RESET}" "below the $(fmt_gb "$PLAN_LINUX_MIN") minimum"
  fi
  ui_strip "$MAC_DISK_SIZE" \
    "mac_used:$PLAN_USED:macOS used $(fmt_gb "$PLAN_USED")" \
    "mac_free:$MAC_CONTAINER_FREE:free $(fmt_gb "$MAC_CONTAINER_FREE")" \
    "boot:$((MAC_APPLE_SYS + MAC_OTHER_BYTES)):system $(fmt_gb $((MAC_APPLE_SYS + MAC_OTHER_BYTES)))" \
    "unalloc:$MAC_EXISTING_FREE:unpartitioned"

  ui_section "Compatibility"
  if [ "$MAC_APPLE_SILICON" = 1 ]; then ui_check pass "Apple Silicon" "$MAC_ARCH"; else ui_check fail "Apple Silicon" "$MAC_ARCH"; fi
  case "$DEV_TIER" in
    supported) ui_check pass "Asahi supported" "$DEV_CHIP $G_DOT installer and Omarchy Mac" ;;
    experimental) ui_check warn "Asahi supported" "$DEV_CHIP is experimental: display/USB work in progress upstream" ;;
    *) ui_check fail "Asahi supported" "$([ "$DEV_CHIP" = unknown ] && echo "$MAC_CHIP" || echo "$DEV_CHIP") $G_DOT not in the installer's device table" ;;
  esac
  if ver_ge "${MAC_OS_VERSION:-0}" "$ASAHI_MIN_MACOS"; then ui_check pass "macOS version" "$MAC_OS_VERSION ≥ $ASAHI_MIN_MACOS"; else ui_check fail "macOS version" "$MAC_OS_VERSION < $ASAHI_MIN_MACOS"; fi
  if [ "$MAC_ADMIN" = 1 ]; then ui_check pass "Admin account" "$MAC_USER"; else ui_check fail "Admin account" "$MAC_USER is not an admin"; fi
  if [ "$MAC_ONLINE" = 1 ]; then ui_check pass "Internet" "asahi-alarm.org reachable"; else ui_check warn "Internet" "asahi-alarm.org not reachable (needed at handoff)"; fi
  if [ "$PLAN_LINUX_MAX" -ge "$PLAN_LINUX_MIN" ]; then
    ui_check pass "Space for Linux" "up to $(fmt_gb "$PLAN_LINUX_MAX")"
  else
    ui_check fail "Space for Linux" "free $(fmt_gb "$PLAN_SHORTFALL") more in macOS"
  fi
  [ "$PLAN_OVERHEAD_WARN" = 1 ] && ui_check warn "Snapshot overhead" "$(fmt_gb "$PLAN_OVERHEAD") held by APFS snapshots or a pending update"
  if [ -n "$(state_get backup_confirmed_at)" ]; then
    ui_check pass "Backup confirmed" "$(state_get backup_confirmed_at)"
  else
    ui_check unknown "Backup confirmed" "asked before anything changes"
  fi
  [ "$MAC_ASAHI_PRESENT" = 1 ] && ui_check info "Existing install" "extra OS partitions found on ${MAC_DISK}"
  return 0
}


# ---------------------------------------------------------------------------
# Storage planning. Shared first, because it changes how much Linux can have;
# then Linux. Both go through the same planner on this disk's layout.
# ---------------------------------------------------------------------------

SHARED_PRESETS_GB="50 100 150 250"
SHARED_MIN_GB=1

# mac_plan_storage — 0 done, 2 back to the survey, 3 quit.
mac_plan_storage() {
  local rc
  while :; do
    mac_shared_choice
    rc=$?
    [ "$rc" = 0 ] || return "$rc"
    mac_linux_size
    rc=$?
    # b at the Linux size returns to the Shared question.
    [ "$rc" = 2 ] && continue
    return "$rc"
  done
}

# mac_shared_max — the largest Shared size (whole GB) that still leaves Linux
# its minimum in one region; 0 when none does.
mac_shared_max() {
  local g
  mac_plan_compute 0 || {
    printf 0
    return 0
  }
  g=$(( (PLAN_LINUX_MAX_BYTES - PLAN_LINUX_MIN - PLAN_PLACEMENT_SLACK_BYTES - MIB) / GB ))
  while [ "$g" -ge "$SHARED_MIN_GB" ] && ! mac_plan_compute "$g"; do
    g=$((g - 1))
  done
  [ "$g" -ge "$SHARED_MIN_GB" ] || g=0
  printf '%s' "$g"
}

# mac_shared_choice — sets CFG_shared (0 = none). 0 chosen, 2 back, 3 quit.
mac_shared_choice() {
  local saved=${CFG_shared:-0} max g n=1 def=1 rc opts=" 0" skipped=""
  mac_screen plan
  ui_section "Shared storage" "macOS $G_ARROW Linux $G_DOT optional"
  ui_note "One exFAT partition that both systems can read and write. Its space is set aside now; after Linux is fully installed, this tool creates it from macOS, with its own checks and confirmation."
  ui_kv "Good for" "datasets, PDFs, media, model files, archives, downloads"
  ui_kv "Not for" "a Linux home, package databases, Docker storage,"
  ui_kv "" "Git checkouts that need Unix permissions, symlinks"
  ui_note "Not encrypted: FileVault and LUKS do not cover it. Not a backup."
  max=$(mac_shared_max)
  set -- "None||No Shared partition; move files with Git or cloud sync.|$([ "${CFG_shared:-}" = 0 ] && echo saved)"
  for g in $SHARED_PRESETS_GB; do
    if [ "$g" -gt "$max" ]; then
      skipped="$skipped $g GB"
      continue
    fi
    n=$((n + 1))
    opts="$opts $g"
    set -- "$@" "$g GB||$(mac_shared_blurb "$g")|$([ "$g" = "$saved" ] && echo saved)"
    [ "$g" = "$saved" ] && def=$n
  done
  if [ "$saved" -gt 0 ] && [ "$saved" -le "$max" ] && ! printf '%s' " $opts " | grep -q " $saved "; then
    n=$((n + 1))
    opts="$opts $saved"
    set -- "$@" "$saved GB||Your previous choice.|saved"
    def=$n
  fi
  if [ "$max" -ge "$SHARED_MIN_GB" ]; then
    set -- "$@" "Custom|GB or %|Any size from $SHARED_MIN_GB GB to $max GB.|"
  fi
  [ -n "$skipped" ] && ui_note "Not offered:$skipped (Linux would fall below its $(fmt_gb "$PLAN_LINUX_MIN") minimum)."
  while :; do
    ui_select "Shared macOS $G_ARROW Linux storage?" "$def" "$@"
    rc=$?
    [ "$rc" = 0 ] || return "$rc"
    if [ "$UI_CHOICE" -le "$n" ]; then
      # shellcheck disable=SC2086 # $opts is a space-separated list by design
      CFG_shared=$(printf '%s\n' $opts | sed -n "${UI_CHOICE}p")
      return 0
    fi
    mac_custom_shared "$max"
    rc=$?
    case "$rc" in 0) return 0 ;; 2) continue ;; *) return "$rc" ;; esac
  done
}

mac_shared_blurb() {
  case "$1" in
    50) echo "Documents, PDFs, a few datasets." ;;
    100) echo "Room for media and model files." ;;
    150) echo "Datasets, models and archives." ;;
    *) echo "Large datasets, media libraries, archives." ;;
  esac
}

# mac_custom_shared MAX_GB — 0 chosen (CFG_shared set), 2 back, 3 quit.
mac_custom_shared() {
  local ans bytes g
  while :; do
    printf '\n'
    ui_ask ans "Shared size ${C_DIM}(GB, TB or % of disk; b to go back)${C_RESET}" "" || return 3
    case "$ans" in b | B) return 2 ;; q | Q) return 3 ;; esac
    if ! bytes=$(parse_size "$ans" "$MAC_DISK_SIZE"); then
      ui_fail "$bytes"
      continue
    fi
    g=$((bytes / GB))
    if [ "$g" -lt "$SHARED_MIN_GB" ] || [ "$g" -gt "$1" ]; then
      ui_fail "Between $SHARED_MIN_GB and $1 GB fits beside Linux's $(fmt_gb "$PLAN_LINUX_MIN") minimum."
      continue
    fi
    [ $((g * GB)) != "$bytes" ] && ui_info "Shared sizes are whole GB: using $g GB."
    CFG_shared=$g
    return 0
  done
}

# mac_linux_size — sets CFG_linux beside the chosen Shared size.
# 0 chosen, 2 back (to the Shared question), 3 quit.
mac_linux_size() {
  local line key label bytes desc badge n=0 def=1 rc saved=0 opts=""
  mac_plan_compute "${CFG_shared:-0}"
  plan_presets
  # A saved size that still fits is the default: Enter keeps the plan.
  if [ -n "${CFG_linux:-}" ] && [ $((CFG_linux * GB)) -ge "$PLAN_LINUX_MIN" ] && [ $((CFG_linux * GB)) -le "$PLAN_LINUX_MAX" ]; then
    saved=$((CFG_linux * GB))
  fi
  ui_section "Linux" "$(fmt_gb "$PLAN_LINUX_MIN")–$(fmt_gb "$PLAN_LINUX_MAX")$([ "${CFG_shared:-0}" -gt 0 ] && printf ' beside %s GB Shared' "$CFG_shared")"
  ui_note "Sizes are the Linux allocation the installer calls \"New OS size\": the Btrfs root plus $(fmt_gb "$PLAN_BOOT") of Asahi boot data. macOS keeps everything else$([ "${CFG_shared:-0}" -gt 0 ] && printf ' that Shared does not need')."
  set --
  if [ "$saved" -gt 0 ] && ! printf '%s' "$PRESETS" | cut -d'|' -f3 | grep -qx "$saved"; then
    n=1
    set -- "Saved plan|$(fmt_gb "$saved")|Your previous choice.|saved"
    opts=" $saved"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    _split4 "$line"
    key=$F1 label=$F2 bytes=$F3 desc=$F4
    badge=""
    if [ "$key" = "$PRESET_DEFAULT" ]; then
      badge="recommended"
      [ "$saved" = 0 ] && def=$n
    fi
    if [ "$saved" -gt 0 ] && [ "$bytes" = "$saved" ]; then
      badge="${badge:+$badge, }saved"
      def=$n
    fi
    set -- "$@" "$label|$(fmt_gb "$bytes")|$desc|$badge"
    opts="$opts $bytes"
  done <<EOF
$PRESETS
EOF
  n=$((n + 1))
  set -- "$@" "Custom|GB or %|Any size from $(fmt_gb "$PLAN_LINUX_MIN") to $(fmt_gb "$PLAN_LINUX_MAX"), e.g. 300GB or 35%.|"
  while :; do
    ui_select "How much storage should Linux receive?" "$def" "$@"
    rc=$?
    [ "$rc" = 0 ] || return "$rc"
    if [ "$UI_CHOICE" != "$n" ]; then
      # shellcheck disable=SC2086 # $opts is a space-separated list by design
      CHOSEN_BYTES=$(printf '%s\n' $opts | sed -n "${UI_CHOICE}p")
    else
      # "b" in the custom prompt returns to this menu.
      mac_custom_size
      rc=$?
      case "$rc" in
        0) ;;
        2) continue ;;
        *) return "$rc" ;;
      esac
    fi
    plan_layout "$CHOSEN_BYTES"
    if [ "$PLAN_OK" = 1 ]; then
      CFG_linux=$((CHOSEN_BYTES / GB))
      return 0
    fi
    ui_fail "That plan does not hold: $PLAN_ERR."
  done
}

mac_custom_size() {
  local ans bytes verdict
  while :; do
    printf '\n'
    ui_ask ans "Linux size ${C_DIM}(GB, TB, % of disk, or max; b to go back)${C_RESET}" "" || return 3
    case "$ans" in b | B) return 2 ;; q | Q) return 3 ;; esac
    if ! bytes=$(parse_size "$ans" "$MAC_DISK_SIZE" "$PLAN_LINUX_MAX"); then
      ui_fail "$bytes"
      continue
    fi
    if [ $((bytes / GB * GB)) != "$bytes" ]; then
      bytes=$((bytes / GB * GB))
      ui_info "Linux sizes are whole GB: using $(fmt_gb "$bytes")."
    fi
    verdict=$(plan_validate "$bytes")
    case "$verdict" in
      error\|*)
        ui_fail "${verdict#error|}"
        continue
        ;;
      warn\|*) ui_warn "${verdict#warn|}" ;;
    esac
    plan_layout "$bytes"
    if [ "$PLAN_OK" != 1 ]; then
      ui_fail "That plan does not hold: $PLAN_ERR."
      continue
    fi
    ui_kv "Linux" "$(fmt_gb "$PLAN_LINUX_ACTUAL")" "$(pct "$PLAN_LINUX_ACTUAL" "$PLAN_DISK")% of the disk"
    ui_kv "macOS keeps" "$(fmt_gb "$PLAN_MACOS_NEW")" "$(fmt_gb "$PLAN_MACOS_FREE_AFTER") free inside it"
    [ "${PLAN_SHARED:-0}" -gt 0 ] && ui_kv "Shared" "$(fmt_gb $(( (PLAN_SHARED + MIB - 1) / MIB * MIB )))" "reserved after Linux"
    if ui_yesno "Use $(fmt_gb "$bytes") for Linux?" y; then
      CHOSEN_BYTES=$bytes
      return 0
    fi
  done
}

# mac_show_layout — the plan, exactly: every region of the disk afterwards,
# and the answers that produce it.
mac_show_layout() {
  local linux=$((CFG_linux * GB)) shared sys unalloc
  mac_plan_compute "${CFG_shared:-0}"
  plan_layout "$linux"
  # Shared is created at the size asked for, in whole MiB; the rest of the
  # region after Linux stays free.
  shared=0
  [ "${PLAN_SHARED:-0}" -gt 0 ] && shared=$(( (PLAN_SHARED + MIB - 1) / MIB * MIB ))
  sys=$((MAC_APPLE_SYS + MAC_OTHER_BYTES + PLAN_BOOT))
  unalloc=$((PLAN_DISK - PLAN_MACOS_NEW - PLAN_ROOT - shared - sys))
  ui_section "Proposed layout" "from this disk's partition map"
  if [ "$PLAN_OK" != 1 ]; then
    ui_fail "The saved sizes no longer fit this disk: $PLAN_ERR."
    return 1
  fi
  ui_strip "$PLAN_DISK" \
    "mac_used:$PLAN_USED:macOS used" \
    "mac_free:$PLAN_MACOS_FREE_AFTER:macOS free" \
    "linux:$PLAN_ROOT:Linux" \
    "shared:$shared:Shared" \
    "boot:$sys:system" \
    "unalloc:$unalloc:unallocated"
  printf '\n'
  ui_kv "macOS / APFS" "$(fmt_gb "$PLAN_MACOS_NEW")" "used $(fmt_gb "$PLAN_USED") $G_DOT free $(fmt_gb "$PLAN_MACOS_FREE_AFTER")$([ "$PLAN_MODE" = free ] && printf ' %s not resized' "$G_DOT")"
  ui_kv "Linux" "$(fmt_gb "$PLAN_LINUX_ACTUAL")" "Btrfs root $(fmt_gb "$PLAN_ROOT") + $(fmt_gb "$PLAN_BOOT") Asahi boot data"
  [ "$shared" -gt 0 ] && ui_kv "Shared / exFAT" "$(fmt_gb "$shared")" "set aside now, created after Linux is installed"
  ui_kv "System" "$(fmt_gb "$sys")" "Apple iBoot + recovery (untouched), Asahi stub + EFI"
  ui_kv "Unallocated" "$(fmt_gb "$unalloc")" "partition-table space, alignment$([ "$shared" -gt 0 ] && printf ', the spare after Shared')$([ "$MAC_EXISTING_FREE" -gt 0 ] && printf ', free space left as it is')"
  printf '\n   %sLinux %s%%%s  %s  macOS %s%%%s  %s  system %s%%\n' \
    "$C_LINUX$C_BOLD" "$(pct "$PLAN_LINUX_ACTUAL" "$PLAN_DISK")" "$C_RESET" "$G_DOT" \
    "$(pct "$PLAN_MACOS_NEW" "$PLAN_DISK")" "$([ "$shared" -gt 0 ] && printf '  %s  Shared %s%%' "$G_DOT" "$(pct "$shared" "$PLAN_DISK")")" "$G_DOT" "$(pct "$sys" "$PLAN_DISK")"
  ui_section "Exact installer answers" "checked against the layout above"
  if [ "$PLAN_MODE" = resize ]; then
    ui_kv "New size (macOS)" "$PLAN_ANSWER_RESIZE" "$(fmt_bytes "$PLAN_MACOS_NEW")"
  fi
  if [ "$PLAN_ANSWER_OS" = max ]; then
    ui_kv "New OS size" "max" "the freed region, at least $(fmt_bytes "$PLAN_LINUX_ACTUAL")"
  else
    ui_kv "New OS size" "$PLAN_ANSWER_OS" "$(fmt_bytes "$PLAN_LINUX_ACTUAL"), at least the $(fmt_gb "$PLAN_LINUX") asked for"
  fi
  [ "$shared" -gt 0 ] && ui_kv "Left after Linux" "$(fmt_gb $((PLAN_SHARED_END - PLAN_SHARED_START)))" "Shared takes $(fmt_bytes "$shared") of it; the rest stays free"
  return 0
}

# ---------------------------------------------------------------------------
# Choices for Phase 2 (passed to omarchy-mac-setup as flags where it accepts them)
# ---------------------------------------------------------------------------

mac_default_keymap() {
  case "${MAC_KEYBOARD##*.}" in
    US | ABC | USInternational-PC) echo us ;;
    British | British-PC) echo uk ;;
    German) echo de ;;
    French | French-PC) echo fr ;;
    Spanish | Spanish-ISO) echo es ;;
    Italian | Italian-Pro) echo it ;;
    Dvorak) echo dvorak ;;
    Colemak) echo colemak ;;
    *) echo us ;;
  esac
}

mac_default_locale() {
  local l=${MAC_LOCALE%%@*}
  case "$l" in
    [a-z][a-z]_[A-Z][A-Z]) echo "$l.UTF-8" ;;
    *) echo "en_US.UTF-8" ;;
  esac
}

mac_choices() {
  mac_screen plan
  ui_section "Linux choices" "carried to the Linux phase"
  ui_note "Omarchy Mac accepts encryption, username, hostname and keymap as flags, so it will not ask for them again. It still asks for your new user's password and, when encrypting, the disk passphrase — typed into it directly, never seen by this tool."
  printf '\n'
  local d
  ask_encrypt || return 3
  d=${CFG_user:-}
  [ -n "$d" ] || { valid_username "$MAC_USER" >/dev/null 2>&1 && d=$MAC_USER; }
  ui_ask CFG_user "Username" "$d" valid_username || return 3
  ui_ask CFG_host "Hostname" "${CFG_host:-omarchy}" valid_hostname || return 3
  ui_ask CFG_kmap "Console keymap ${C_DIM}(the passphrase is typed with it)${C_RESET}" "${CFG_kmap:-$(mac_default_keymap)}" valid_keymap || return 3
  ui_ask CFG_tz "Timezone" "${CFG_tz:-${MAC_TZ:-UTC}}" valid_tz || return 3
  ui_ask CFG_loc "Locale" "${CFG_loc:-$(mac_default_locale)}" valid_locale || return 3
  d=$([ "${CFG_ssh:-0}" = 1 ] && echo y || echo n)
  if ui_yesno "Enable SSH after install?" "$d"; then CFG_ssh=1; else [ $? = 3 ] && return 3; CFG_ssh=0; fi
  ui_ask CFG_gh "GitHub user whose public SSH keys to offer later ${C_DIM}(optional; - clears it)${C_RESET}" "${CFG_gh:-}" valid_ghuser || return 3
  [ "$CFG_gh" = "-" ] && CFG_gh=""
  d=$([ "${CFG_dev:-1}" = 0 ] && echo n || echo y)
  if ui_yesno "Offer the developer setup once Omarchy is installed?" "$d"; then CFG_dev=1; else [ $? = 3 ] && return 3; CFG_dev=0; fi
  return 0
}

mac_review() {
  mac_screen plan
  mac_show_layout
  ui_section "Linux choices"
  ui_kv "Encryption" "$([ "$CFG_enc" = 1 ] && echo "yes — passphrase chosen at the console" || echo no)"
  ui_kv "User / host" "$CFG_user @ $CFG_host"
  ui_kv "Keymap" "$CFG_kmap"
  ui_kv "Time / locale" "$CFG_tz $G_DOT $CFG_loc" "applied in the developer phase if Omarchy differs"
  ui_kv "SSH after install" "$([ "$CFG_ssh" = 1 ] && echo yes || echo no)${CFG_gh:+ $G_DOT keys from github.com/$CFG_gh}"
  ui_kv "Developer setup" "$([ "$CFG_dev" = 1 ] && echo offered || echo skipped)"
  ui_select "Next" 1 \
    "Continue|||to the backup check" \
    "Change storage|||" \
    "Change choices|||" \
    "Save and stop|||resume any time"
}

# mac_save_plan — the choices, and with Shared storage the plan record its
# later creation is checked against. The record's digest goes into the
# resume token, so Linux's completion code can name this plan.
mac_save_plan() {
  mac_plan_compute "${CFG_shared:-0}"
  plan_layout $((CFG_linux * GB))
  if ! shared_intent_save; then
    ui_fail "Could not record the Shared plan in $(tildify "$OMB_STATE_DIR")."
    return 1
  fi
  CFG_plan=""
  [ "${CFG_shared:-0}" -gt 0 ] && CFG_plan=$(shared_plan_digest)
  cfg_save
  state_stamp planned_at
  return 0
}

# ---------------------------------------------------------------------------
# Backup gate
# ---------------------------------------------------------------------------

mac_backup_gate() {
  mac_screen asahi
  ui_section "Backup" "the one step where it matters"
  if [ -n "$MAC_TM_INFO" ]; then
    ui_kv "Time Machine" "destination configured" "$MAC_TM_INFO"
    ui_kv "Latest backup" "${MAC_TM_LATEST:-not reported}" "from tmutil; not a guarantee"
  else
    ui_kv "Time Machine" "no destination reported" "any recent full backup counts"
  fi
  ui_callout warn "The next step changes your disk's partition layout." \
    "The Asahi installer shrinks the macOS container and adds partitions. It is designed to be safe, but a partition change is exactly when a backup matters." \
    "This tool cannot tell whether a backup is good, so it asks you."
  if ui_confirm_word yes "A recent backup of this Mac exists."; then
    state_must_set backup_confirmed_at "$(now_utc)" || return 1
    return 0
  fi
  printf '\n'
  ui_info "Stopped before anything changed. Make a backup, then run ./omarchy-bootstrap again."
  return 1
}

# ---------------------------------------------------------------------------
# Continuation: how to get this repository onto the new Linux system
# ---------------------------------------------------------------------------

repo_slug() {
  local url
  url=$(sys_cmd git_origin git -C "$OMB_HOME" remote get-url origin)
  case "$url" in
    https://github.com/* | git@github.com:* | ssh://git@github.com/*)
      url=${url#https://github.com/}
      url=${url#git@github.com:}
      url=${url#ssh://git@github.com/}
      printf '%s' "${url%.git}"
      ;;
    *) return 1 ;;
  esac
}

repo_branch() {
  local b
  b=$(sys_cmd git_branch git -C "$OMB_HOME" rev-parse --abbrev-ref HEAD)
  case "$b" in '' | HEAD) b=main ;; esac
  printf '%s' "$b"
}

# continuation_commands — prints the numbered fetch + resume steps.
continuation_commands() {
  local slug branch vis=unknown dest=/opt/omarchy-mac-bootstrap token
  token=$(token_encode)
  branch=$(repo_branch)
  if slug=$(repo_slug); then
    if sys_reachable repo_public "https://github.com/$slug"; then vis=public; else vis=private; fi
  else
    slug="<owner>/omarchy-mac-bootstrap"
  fi
  # Phase 2 runs as root, so it should run the code that made this plan: pin
  # the commit when the remote has it, and say so when it does not.
  local sha ref
  sha=$(sys_cmd git_head git -C "$OMB_HOME" rev-parse HEAD)
  case "$sha" in *[!0-9a-f]* | '') sha="" ;; esac
  if [ -n "$sha" ] && [ -n "$(sys_cmd git_pushed git -C "$OMB_HOME" branch -r --contains HEAD)" ]; then
    ref=$sha
  else
    ref=refs/heads/$branch
    [ -n "$sha" ] && ui_warn "This commit is not on the remote yet; Linux will get the tip of $branch. Push first to pin it."
  fi
  if [ "$vis" != private ]; then
    _p '   %s%s%s\n' "$C_DIM" "public repository — no git needed:" "$C_RESET"
    ui_cmd "mkdir -p $dest"
    ui_cmd "curl -fsSL https://github.com/$slug/archive/$ref.tar.gz | tar xz --strip-components=1 -C $dest"
  fi
  if [ "$vis" != public ]; then
    _p '   %s%s%s\n' "$C_DIM" "private repository — sign in with a device code, then sign out again:" "$C_RESET"
    ui_cmd "pacman -Syu --needed git github-cli"
    ui_cmd "gh auth login"
    ui_cmd "gh repo clone $slug $dest -- --branch $branch"
    [ "$ref" = "$sha" ] && ui_cmd "git -C $dest checkout -q $sha"
    ui_cmd "gh auth logout"
  fi
  printf '   %s%s%s\n' "$C_DIM" "then continue:" "$C_RESET"
  if [ "$token" = "omb1:" ]; then
    ui_cmd "cd $dest && ./omarchy-bootstrap"
  else
    ui_cmd "cd $dest && ./omarchy-bootstrap resume $token"
  fi
}

# mac_reboot_guide — after the installer shuts the Mac down. The boot picker
# lists the new OS by the name given at the installer's "OS name" prompt.
mac_reboot_guide() {
  ui_section "After the installer" "it ends by shutting the Mac down"
  _guide 1 "Wait 25 seconds after the Mac powers off."
  _guide 2 "Press and HOLD the power button once, until \"Loading startup options…\" appears."
  _guide 3 "Choose \"$ASAHI_ALARM_OS_CHOICE\" (the OS name you gave the installer)."
  _guide 4 "A macOS Recovery dialog appears briefly. If asked to \"Select a volume to recover\", choose your normal macOS volume and authenticate."
  _guide 5 "Follow the prompts on the \"Asahi Linux installer\" screen. The Mac then boots Arch."
  _guide 6 "Log in as $ASAHI_ALARM_FIRST_LOGIN."
  _guide 7 "Connect to Wi-Fi: run nmtui, choose Activate a connection, then Quit."
  _guide 8 "Fetch this repository and continue:"
  continuation_commands
  printf '\n'
  ui_note "The installer makes the new OS the default startup disk. macOS stays installed: hold the power button at startup to choose it, or set it back as the default in System Settings > General > Startup Disk. Photograph this screen — no clipboard survives the reboot. './omarchy-bootstrap resume' on macOS shows it again."
}

_guide() {
  local n=$1 text=$2 first=1
  printf '%s\n' "$text" | fold -s -w $((UI_W - 9)) | while IFS= read -r l; do
    if [ "$first" = 1 ]; then
      _p '   %s%2s%s  %s\n' "$C_ACCENT$C_BOLD" "$n" "$C_RESET" "$l"
      first=0
    else
      _p '       %s\n' "$l"
    fi
  done
}

# ---------------------------------------------------------------------------
# Handoff
# ---------------------------------------------------------------------------

clipboard_copy() {
  if [ "$OMB_DRY_RUN" = 1 ]; then
    ui_would "copy '$1' to the clipboard"
    return 0
  fi
  if [ -n "${OMB_TEST_RECORD:-}" ]; then
    printf 'pbcopy <<< %s\n' "$1" >>"$OMB_TEST_RECORD"
    return 0
  fi
  sys_has pbcopy || return 1
  printf '%s' "$1" | pbcopy
}

# asahi_bootstrap_expected FILE — does the download have the known shape?
asahi_bootstrap_expected() {
  head -1 "$1" | grep -q '^#!/bin/sh' &&
    grep -q "INSTALLER_DATA=\"$ASAHI_ALARM_DATA_URL\"" "$1" &&
    grep -q 'install.sh' "$1"
}

mac_handoff() {
  local version shape_ok=1 first_answer rc
  mac_screen asahi
  ui_section "Asahi Alarm installer" "download first, run second"

  if ! ui_spin "Reaching asahi-alarm.org" sys_reachable asahi_home "$ASAHI_ALARM_VERSION_URL"; then
    ui_fail "asahi-alarm.org is not reachable. Connect to the internet and run ./omarchy-bootstrap again."
    return 1
  fi
  if ! fetch_upstream asahi-alarm-bootstrap.sh "$ASAHI_ALARM_INSTALLER_URL"; then
    ui_fail "Download failed: $ASAHI_ALARM_INSTALLER_URL"
    return 1
  fi
  version=$(sys_net asahi_version "$ASAHI_ALARM_VERSION_URL" | clean_version)
  asahi_bootstrap_expected "$FETCH_PATH" || shape_ok=0

  show_provenance
  if [ "$version" = "$ASAHI_INSTALLER_VERIFIED" ]; then
    ui_kv "Fetches installer" "$version" "matches the version this tool was checked against"
  else
    ui_kv "Fetches installer" "${version:-unknown}" "${C_FAIL}checked against $ASAHI_INSTALLER_VERIFIED${C_RESET}"
  fi
  state_set asahi_bootstrap_url "$FETCH_URL"
  state_set asahi_bootstrap_sha256 "$FETCH_SHA256"
  state_set asahi_bootstrap_fetched_at "$FETCH_AT"
  state_set asahi_installer_version "${version:-unknown}"

  # Drift is reported, never followed: the same rule as the Linux handoff.
  if [ "$shape_ok" = 0 ]; then
    ui_callout fail "Refusing: this is not the Asahi Alarm bootstrap this tool was checked against." \
      "It should be a /bin/sh script that fetches the installer and $ASAHI_ALARM_DATA_URL (a captive-portal page or an upstream change would both land here)." \
      "Read $(tildify "$FETCH_PATH") and run 'omarchy-bootstrap sources --check' before changing lib/sources.sh."
    printf '\n'
    return 1
  fi
  # The answers below are computed from the installer's storage behaviour as
  # verified; a different installer or OS template is a different contract.
  if ! storage_contract_ok "$version" "$(sys_net asahi_data "$ASAHI_ALARM_DATA_URL")"; then
    ui_blockers "Refusing: the installer's storage behaviour may have changed." \
      "$CONTRACT_PROBLEMS
The sizes this tool would ask you to type were computed for asahi-installer $ASAHI_INSTALLER_VERIFIED. Re-verify upstream (docs/UPSTREAM.md), then update lib/sources.sh."
    return 1
  fi
  offer_inspection || {
    printf '\n'
    ui_info "Not launched. Nothing changed."
    return 1
  }
  mac_plan_compute "${CFG_shared:-0}"
  plan_layout $((CFG_linux * GB))
  if [ "$PLAN_OK" != 1 ]; then
    ui_fail "The saved plan no longer fits this disk: $PLAN_ERR. Nothing was launched; run ./omarchy-bootstrap to plan again."
    return 1
  fi

  # The answer card: exact values, each a whole number of MiB, which the
  # installer's own alignment leaves unchanged.
  if [ "$PLAN_MODE" = resize ]; then first_answer=$PLAN_ANSWER_RESIZE; else first_answer=$PLAN_ANSWER_OS; fi
  local n=0
  ui_card_open "When the Asahi Alarm installer asks"
  ui_card_row $((n += 1)) "Press enter to continue" "Enter" "and your macOS password when asked"
  if [ "$PLAN_MODE" = resize ]; then
    ui_card_row $((n += 1)) "Choose what to do" "r" "Resize an existing partition"
    ui_card_row $((n += 1)) "New size  (macOS keeps)" "$PLAN_ANSWER_RESIZE" "$(fmt_gb "$PLAN_MACOS_NEW"), on your clipboard"
    ui_card_row $((n += 1)) "Continue?" "y" "the Mac may seem frozen; wait"
  fi
  ui_card_row $((n += 1)) "Choose what to do" "f" "Install an OS into free space"
  mac_gap_count
  if [ "$MAC_GAP_COUNT" -gt 1 ]; then
    ui_card_row $((n += 1)) "Choose free space" "$(mac_gap_label_planned)" "the $(fmt_gb $((PLAN_GAP_END - PLAN_GAP_START))) one"
  fi
  ui_card_row $((n += 1)) "Choose an OS to install" "$ASAHI_ALARM_OS_CHOICE" "type its number"
  ui_card_row $((n += 1)) "New OS size  (Linux gets)" "$PLAN_ANSWER_OS" "$(fmt_gb "$PLAN_LINUX_ACTUAL") incl. $(fmt_gb "$PLAN_BOOT") boot data"
  ui_card_row $((n += 1)) "OS name" "Enter" "or e.g. Omarchy; shown in Startup Options"
  ui_card_text "Type each size exactly as shown; MiB values are exact."
  [ "${PLAN_SHARED:-0}" -gt 0 ] && ui_card_text "Never type max here: the space after Linux is Shared's."
  ui_card_text "Everything else: read it, and follow the installer's own instructions."
  ui_card_close
  if clipboard_copy "$first_answer" && [ "$OMB_DRY_RUN" != 1 ]; then
    ui_info "Copied $first_answer to the clipboard."
  fi

  mac_reboot_guide

  local what
  if [ "$PLAN_MODE" = resize ]; then
    what="resize the macOS container to $(fmt_gb "$PLAN_MACOS_NEW") ($PLAN_ANSWER_RESIZE), create the Linux partitions"
  else
    what="create the Linux partitions in the existing free space (macOS is not resized)"
  fi
  ui_callout fail "Last stop before your disk changes." \
    "The installer will ask for your macOS password, $what, then shut the Mac down." \
    "Its warnings are its own — read them. Quitting at its first menu changes nothing; once it has resized macOS, quitting keeps the resize. Either way, this tool reads the disk afterwards and says where things stand."
  if ! ui_confirm_word launch "Run the official Asahi Alarm installer now."; then
    printf '\n'
    ui_info "Not launched. Nothing changed. Run ./omarchy-bootstrap again when ready."
    return 1
  fi

  mac_recheck_plan || return 1
  # With Shared storage, its later creation is checked against the saved
  # record; the install must be exactly the plan that record describes.
  if ! shared_intent_matches_plan; then
    ui_fail "The saved Shared plan does not match the plan about to run${INT_ERR:+ ($INT_ERR)}. Nothing was launched; run ./omarchy-bootstrap to plan again."
    return 1
  fi
  # What the disk looked like before: the installer's exit status says
  # nothing (0 for quit, error and success), so the disk is compared instead.
  local before
  before=$(geo_canon)
  state_unset asahi_exit
  state_unset asahi_state
  state_must_set asahi_prelaunch_macos_size "$PLAN_C" || return 1
  state_must_set asahi_launched_at "$(now_utc)" || return 1
  printf '\n'
  fetch_unchanged || return 1
  run sh "$FETCH_PATH"
  rc=$?
  [ "$OMB_DRY_RUN" = 1 ] && {
    printf '\n'
    ui_info "Dry run: the installer was not launched and the disk was not touched."
    return 0
  }
  state_set asahi_exit "$rc"
  printf '\n'
  mac_after_installer "$before" "$rc"
}

# mac_after_installer LAYOUT_BEFORE EXIT — re-read the disk and say what the
# installer actually did. Returns 0 when the next step is clear and safe.
mac_after_installer() {
  mac_read_container
  mac_detect_geometry
  mac_plan_compute
  asahi_classify
  state_set asahi_state "$ASAHI_STATE"
  ui_section "After the installer" "read from the disk, not its exit status ($2)"
  case "$ASAHI_STATE" in
    none)
      if [ "$GEO_OK" = 1 ] && [ "$(geo_canon)" = "$1" ]; then
        ui_ok "The disk is exactly as it was: the installer changed nothing (it was quit, or stopped before resizing)."
        ui_note "Run ./omarchy-bootstrap again when ready; the plan is kept."
        return 0
      fi
      ASAHI_STATE=unknown
      ASAHI_WHY="the partition layout changed, but not in a way the Asahi installer leaves it"
      ;;
    installed | pending-first-boot | installed-unverified)
      ui_ok "Asahi's partitions are in place."
      ui_note "The installer ends by shutting the Mac down. If it does not within a minute, it stopped after creating them: run ./omarchy-bootstrap again to see where things stand."
      mac_reboot_guide
      return 0
      ;;
  esac
  asahi_guidance
}

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

mac_survey() {
  # mac_detect sets globals, so it cannot run under a spinner's background
  # subshell; say what is happening before the few seconds it takes.
  ui_interactive && _p '\n   %s%s%s\n' "$C_DIM" "Surveying this Mac (read-only)…" "$C_RESET"
  mac_detect
  MAC_ONLINE=0
  ui_spin "Checking internet" sys_reachable asahi_home "$ASAHI_ALARM_VERSION_URL" && MAC_ONLINE=1
  cfg_load
  mac_plan_compute
  state_set mac_model "$MAC_MODEL_ID"
  state_stamp surveyed_at
  log_event survey "model=$MAC_MODEL_ID tier=$DEV_TIER macos=$MAC_OS_VERSION disk=$MAC_DISK size=$MAC_DISK_SIZE container=$MAC_CONTAINER_SIZE free=$MAC_CONTAINER_FREE pref=$MAC_LIMIT_PREF linux_max=$PLAN_LINUX_MAX asahi_present=$MAC_ASAHI_PRESENT"
}

mac_main() {
  local mode=$1 step=survey rc blockers line
  OMB_PHASE=macos
  mac_survey
  mac_show_survey
  blockers=$(mac_blockers)
  if [ -n "$blockers" ]; then
    ui_blockers "This Mac cannot continue." "$blockers"
    return 1
  fi
  # Where any earlier install stands, from the disk alone.
  asahi_classify
  case "$ASAHI_STATE" in
    none) ;;
    resized-only) asahi_guidance ;;
    *)
      mac_existing_install || return 1
      mac_shared_step "$mode"
      return
      ;;
  esac
  if [ "$DEV_TIER" = experimental ]; then
    ui_callout warn "$DEV_CHIP support is experimental." \
      "The Asahi installer accepts this Mac, but Asahi lists display and USB support as work in progress, and Omarchy Mac documents M1/M2 only."
    ui_confirm_word experimental "Continue anyway." || return 1
  fi

  while :; do
    case "$step" in
      survey)
        ui_next "Plan storage"
        rc=$?
        [ "$rc" = 3 ] && { _mac_quit; return 0; }
        step=storage
        ;;
      storage)
        mac_plan_storage
        rc=$?
        case "$rc" in 2) mac_show_survey; step=survey; continue ;; 3) _mac_quit; return 0 ;; esac
        step=choices
        ;;
      choices)
        mac_choices || { _mac_quit; return 0; }
        step=review
        ;;
      review)
        mac_review
        rc=$?
        [ "$rc" = 3 ] && { _mac_quit; return 0; }
        [ "$rc" = 2 ] && { step=choices; continue; }
        case "$UI_CHOICE" in
          2) step=storage; continue ;;
          3) step=choices; continue ;;
          4)
            mac_save_plan || return 1
            printf '\n'
            ui_ok "Plan saved. Run ./omarchy-bootstrap to continue; your saved answers are the defaults."
            printf '\n'
            return 0
            ;;
        esac
        mac_save_plan || return 1
        if [ "$mode" = plan ]; then
          printf '\n'
          ui_ok "Plan saved$([ "$OMB_DRY_RUN" = 1 ] && printf ' (dry run: not written)'). Run ./omarchy-bootstrap to continue."
          printf '\n'
          return 0
        fi
        step=backup
        ;;
      backup)
        mac_backup_gate || return 1
        step=handoff
        ;;
      handoff)
        mac_handoff
        return $?
        ;;
    esac
  done
}

_mac_quit() {
  printf '\n'
  ui_info "Stopped. Nothing on this Mac changed."
  printf '\n'
}

mac_existing_install() {
  asahi_guidance
  local rc=$?
  printf '\n'
  return "$rc"
}

# mac_shared_step MODE — after an install, on macOS: Shared storage's next
# step. plan only shows it; the guided flow continues into it, through the
# same gates as `shared create`.
mac_shared_step() {
  [ -e "$OMB_STATE_DIR/$SHARED_INTENT_FILE" ] || return 0
  shared_mac_state
  shared_status_rows
  if [ "$1" = plan ] || [ "$SHARED_STATE" = reserved ] || [ "$SHARED_STATE" = off ]; then
    printf '\n'
    return 0
  fi
  if [ "$SHARED_STATE" = awaiting-linux-completion ] && [ "$ASAHI_STATE" = pending-first-boot ]; then
    ui_note "Shared is created after Linux: boot it, let Omarchy Mac finish, then come back here with the code it shows."
    printf '\n'
    return 0
  fi
  shared_create_flow
}

mac_resume() {
  OMB_PHASE=macos
  mac_survey
  mac_screen reboot
  asahi_classify
  case "$ASAHI_STATE" in
    none)
      if [ -n "$(state_get asahi_launched_at)" ]; then
        ui_warn "The installer was launched at $(state_get asahi_launched_at), but the disk shows no change from it."
        ui_note "Run ./omarchy-bootstrap to start again; the plan is kept."
      else
        ui_info "Phase 1 has not reached the installer yet. Run ./omarchy-bootstrap to continue."
      fi
      ;;
    installed)
      asahi_guidance
      ui_section "Continue on Linux" "boot it, log in, then"
      continuation_commands
      ;;
    *) asahi_guidance ;;
  esac
  if [ -e "$OMB_STATE_DIR/$SHARED_INTENT_FILE" ]; then
    shared_mac_state
    shared_status_rows
    ui_para "$(shared_next_action)"
  fi
  printf '\n'
}

mac_dev_note() {
  ui_header "macOS $G_DOT developer setup"
  ui_note "The developer setup runs on the Linux side, after Omarchy is installed: ./omarchy-bootstrap dev"
  printf '\n'
}
