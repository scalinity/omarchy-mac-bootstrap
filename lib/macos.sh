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
  local hw root store list lim i content size id

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

  # Follow / to its APFS container, physical store and whole disk.
  root=$(sys_cmd diskutil_info_root diskutil info -plist /)
  MAC_ROOT_VOLUME=$(plist_get "$root" VolumeName)
  MAC_CONTAINER=$(plist_get "$root" APFSContainerReference)
  MAC_CONTAINER_SIZE=$(plist_get "$root" APFSContainerSize)
  MAC_CONTAINER_FREE=$(plist_get "$root" APFSContainerFree)
  MAC_STORE=$(plist_get "$root" APFSPhysicalStores.0.APFSPhysicalStore)
  MAC_DISK="" MAC_DISK_INTERNAL=false MAC_DISK_SIZE=0
  if [ -n "$MAC_STORE" ]; then
    store=$(sys_cmd "diskutil_info_$MAC_STORE" diskutil info -plist "$MAC_STORE")
    MAC_DISK=$(plist_get "$store" ParentWholeDisk)
    MAC_DISK_INTERNAL=$(plist_get "$store" Internal)
  fi

  MAC_PARTS="" MAC_APPLE_SYS=0 MAC_PART_SUM=0 MAC_ASAHI_PRESENT=0 MAC_OTHER_BYTES=0
  if [ -n "$MAC_DISK" ]; then
    list=$(sys_cmd "diskutil_list_$MAC_DISK" diskutil list -plist "$MAC_DISK")
    MAC_DISK_SIZE=$(plist_get "$list" AllDisksAndPartitions.0.Size)
    i=0
    while content=$(plist_get "$list" "AllDisksAndPartitions.0.Partitions.$i.Content"); do
      size=$(plist_get "$list" "AllDisksAndPartitions.0.Partitions.$i.Size")
      id=$(plist_get "$list" "AllDisksAndPartitions.0.Partitions.$i.DeviceIdentifier")
      MAC_PART_SUM=$((MAC_PART_SUM + size))
      mac_classify_partition "$id" "$content" "$size"
      MAC_PARTS="$MAC_PARTS$id|$content|$size|$MAC_PART_ROLE
"
      i=$((i + 1))
    done
  fi
  MAC_DISK_SIZE=${MAC_DISK_SIZE:-0}
  MAC_EXISTING_FREE=$((MAC_DISK_SIZE - MAC_PART_SUM))
  [ "$MAC_EXISTING_FREE" -lt "$GB" ] && MAC_EXISTING_FREE=0

  MAC_LIMIT_PREF=0
  if [ -n "$MAC_CONTAINER" ] && lim=$(mac_resize_limits "$MAC_CONTAINER"); then
    MAC_LIMIT_PREF=$(plist_get "$lim" MinimumSizePreferred)
    MAC_LIMIT_PREF=${MAC_LIMIT_PREF:-0}
  fi

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

# mac_classify_partition ID CONTENT SIZE — sets MAC_PART_ROLE and tallies.
# Stock Apple Silicon disks have three: iBoot system container, the macOS
# container, and the recovery container. Anything else is an extra OS.
mac_classify_partition() {
  local id=$1 content=$2 size=$3
  case "$content" in
    Apple_APFS_ISC | Apple_APFS_Recovery)
      MAC_PART_ROLE=system
      MAC_APPLE_SYS=$((MAC_APPLE_SYS + size))
      ;;
    Apple_APFS)
      if [ "$id" = "$MAC_STORE" ]; then
        MAC_PART_ROLE=macos
      elif [ "$size" -lt 5000000000 ]; then
        MAC_PART_ROLE="asahi-stub"
        MAC_ASAHI_PRESENT=1
        MAC_OTHER_BYTES=$((MAC_OTHER_BYTES + size))
      else
        MAC_PART_ROLE="other-apfs"
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
  # Space is a blocker only before an install; after one, the partitions exist.
  if [ "$MAC_ASAHI_PRESENT" != 1 ] && [ "${PLAN_LINUX_MAX:-0}" -lt "${PLAN_LINUX_MIN:-1}" ]; then
    printf 'Not enough free space for Linux yet: free about %s in macOS (Omarchy Mac needs %s GB).' \
      "$(fmt_gb "$PLAN_SHORTFALL")" "$OMARCHY_LINUX_MIN_GB"
    [ "$PLAN_OVERHEAD_WARN" = 1 ] && printf ' APFS snapshots hold %s; see %s.' "$(fmt_gb "$PLAN_OVERHEAD")" "$ASAHI_TM_CLEANUP"
    printf '\n'
  fi
  return 0
}

# mac_plan_compute [SHARED_GB] — no reservation unless one is passed: a saved
# shared area must not shrink the survey, presets or status before the
# shared question has been answered again in this run.
mac_plan_compute() {
  plan_compute "$MAC_DISK_SIZE" "$MAC_CONTAINER_SIZE" "$MAC_CONTAINER_FREE" "$MAC_LIMIT_PREF" "$MAC_EXISTING_FREE" "$(( ${1:-0} * GB ))"
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
  ui_kv "Internal SSD" "$(fmt_gb "$MAC_DISK_SIZE")" "$( [ "$MAC_DISK_INTERNAL" = true ] && echo "internal, boot disk" || echo "NOT internal")"
  ui_kv "macOS container" "$(fmt_gb "$MAC_CONTAINER_SIZE")" "$MAC_ROOT_VOLUME"
  ui_kv "Used by macOS" "$(fmt_gb "$PLAN_USED")"
  ui_kv "Free in macOS" "$(fmt_gb "$MAC_CONTAINER_FREE")" "purgeable space not counted"
  [ "$MAC_EXISTING_FREE" -gt 0 ] && ui_kv "Unpartitioned" "$(fmt_gb "$MAC_EXISTING_FREE")"
  ui_kv "Required reserve" "$(fmt_gb "$PLAN_RESERVE")" "38 GB for updates$([ "$PLAN_OVERHEAD" -gt 0 ] && printf ' + %s overhead' "$(fmt_gb "$PLAN_OVERHEAD")") + 5 GB margin"
  if [ "$PLAN_LINUX_MAX" -ge "$PLAN_LINUX_MIN" ]; then
    ui_kv "Safe Linux maximum" "${C_BOLD}$(fmt_gb "$PLAN_LINUX_MAX")${C_RESET}"
  else
    ui_kv "Safe Linux maximum" "${C_FAIL}$(fmt_gb "$PLAN_LINUX_MAX")${C_RESET}" "below the ${OMARCHY_LINUX_MIN_GB} GB minimum"
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

# ui_next LABEL — Enter continues, b goes back, q quits. 0/2/3.
ui_next() {
  local ans
  printf '\n   %s⏎%s %s  %s· b back · q quit%s ' "$C_ACCENT" "$C_RESET" "$1" "$C_FAINT" "$C_RESET" | _ui_ascii_hint_line
  IFS= read -r ans || return 3
  _ui_echo "$ans"
  case "$ans" in
    b | B) return 2 ;;
    q | Q) return 3 ;;
  esac
  return 0
}
_ui_ascii_hint_line() { if [ "$UI_UNICODE" = 1 ]; then cat; else sed 's/⏎/>/; s/·/-/g'; fi; }

# ---------------------------------------------------------------------------
# Storage planning
# ---------------------------------------------------------------------------

mac_plan_storage() {
  local opts="" line key label bytes desc badge n=0 def=1 rc saved=0
  mac_screen plan
  mac_plan_compute
  plan_presets
  # A saved size that still fits is the default: Enter keeps the plan.
  if [ -n "${CFG_linux:-}" ] && [ $((CFG_linux * GB)) -ge "$PLAN_LINUX_MIN" ] && [ $((CFG_linux * GB)) -le "$PLAN_LINUX_MAX" ]; then
    saved=$((CFG_linux * GB))
  fi
  ui_section "Storage" "Linux can have $(fmt_gb "$PLAN_LINUX_MIN")–$(fmt_gb "$PLAN_LINUX_MAX")"
  ui_note "Sizes are the Linux allocation the installer calls \"New OS size\": the Btrfs root plus 3 GB of boot data. macOS keeps everything else."
  set --
  if [ "$saved" -gt 0 ] && ! printf '%s' "$PRESETS" | cut -d'|' -f3 | grep -qx "$saved"; then
    n=1
    def=1
    set -- "Saved plan|$(fmt_gb "$saved")|Your previous choice.|saved"
    opts=" $saved"
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    key=$(printf '%s' "$line" | cut -d'|' -f1)
    label=$(printf '%s' "$line" | cut -d'|' -f2)
    bytes=$(printf '%s' "$line" | cut -d'|' -f3)
    desc=$(printf '%s' "$line" | cut -d'|' -f4)
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
      break
    fi
    # "b" in the custom prompt returns to this menu, not to the survey.
    mac_custom_size
    rc=$?
    case "$rc" in
      0) break ;;
      2) continue ;;
      *) return "$rc" ;;
    esac
  done
  CFG_linux=$(gb_floor "$CHOSEN_BYTES")
  return 0
}

mac_custom_size() {
  local ans bytes verdict
  while :; do
    printf '\n'
    ui_ask ans "Linux size ${C_DIM}(GB, TB, % of disk, or max; b to go back)${C_RESET}" "" || return 3
    case "$ans" in b | B) return 2 ;; q | Q) return 3 ;; esac
    if ! bytes=$(parse_size "$ans"); then
      ui_fail "$bytes"
      continue
    fi
    bytes=$(($(gb_floor "$bytes") * GB))
    verdict=$(plan_validate "$bytes")
    case "$verdict" in
      error\|*)
        ui_fail "${verdict#error|}"
        continue
        ;;
      warn\|*) ui_warn "${verdict#warn|}" ;;
    esac
    plan_layout "$bytes"
    ui_kv "Linux" "$(fmt_gb "$bytes")" "$(pct "$bytes" "$PLAN_DISK")% of the disk"
    ui_kv "macOS keeps" "$(fmt_gb "$PLAN_MACOS_NEW")" "$(fmt_gb "$PLAN_MACOS_FREE_AFTER") free inside it"
    ui_kv "Free in macOS now" "$(fmt_gb "$PLAN_FREE")" "→ $(fmt_gb "$PLAN_MACOS_FREE_AFTER") after"
    if ui_yesno "Use $(fmt_gb "$bytes") for Linux?" y; then
      CHOSEN_BYTES=$bytes
      return 0
    fi
  done
}

# mac_shared_prompt — optional, default off. Never creates anything.
mac_shared_prompt() {
  local rc saved=${CFG_shared:-0} ans max def
  # Bound the area by what fits beside this Linux size with no reservation.
  mac_plan_compute
  max=$(( $(gb_floor $((PLAN_LINUX_MAX - CFG_linux * GB))) ))
  ui_section "Shared data area" "advanced $G_DOT off by default"
  if [ "$max" -lt 1 ]; then
    ui_note "No room for a shared area beside $CFG_linux GB of Linux. Choose a smaller Linux size to leave room for one."
    CFG_shared=0
    mac_plan_compute
    plan_layout "$((CFG_linux * GB))"
    return 0
  fi
  ui_note "A small exFAT partition both systems can read and write — handy for moving files, poor for code (no permissions, no symlinks, case-insensitive). Git or cloud sync is the better default. The Asahi installer has no shared-partition option, so this tool only leaves the space free and writes a post-install plan; it never creates the partition."
  ui_yesno "Plan a shared area?" "$([ "$saved" -gt 0 ] && echo y || echo n)"
  rc=$?
  [ "$rc" = 3 ] && return 3
  CFG_shared=0
  if [ "$rc" = 0 ]; then
    def=32
    [ "$saved" -gt 0 ] && def=$saved
    [ "$def" -gt "$max" ] && def=$max
    while :; do
      ui_ask ans "Shared size in GB ${C_DIM}(1–$max; b to skip)${C_RESET}" "$def" || return 3
      case "$ans" in
        b | B) break ;;
        q | Q) return 3 ;;
      esac
      valid_gb "$ans" || continue
      if [ "$ans" -lt 1 ] || [ "$ans" -gt "$max" ]; then
        ui_fail "Between 1 and $max GB fits beside $CFG_linux GB of Linux."
        continue
      fi
      CFG_shared=$ans
      break
    done
  fi
  mac_plan_compute "$CFG_shared"
  plan_layout "$((CFG_linux * GB))"
}

mac_show_layout() {
  local linux=$((CFG_linux * GB)) shared=$(( ${CFG_shared:-0} * GB )) boot rest
  mac_plan_compute "${CFG_shared:-0}"
  plan_layout "$linux"
  boot=$((PLAN_BOOT + MAC_APPLE_SYS + MAC_OTHER_BYTES))
  rest=$((PLAN_DISK - PLAN_MACOS_NEW - PLAN_ROOT - boot - shared))
  [ "$rest" -lt 0 ] && rest=0
  [ "$rest" -lt "$GB" ] && rest=0
  ui_section "Proposed layout" "estimate"
  ui_strip "$PLAN_DISK" \
    "mac_used:$PLAN_USED:macOS used" \
    "mac_free:$PLAN_MACOS_FREE_AFTER:macOS free" \
    "linux:$PLAN_ROOT:Linux" \
    "boot:$boot:boot+system" \
    "shared:$shared:shared" \
    "unalloc:$rest:unpartitioned"
  printf '\n'
  ui_kv "macOS / APFS" "$G_APPROX $(fmt_gb "$PLAN_MACOS_NEW")" "used $(fmt_gb "$PLAN_USED") $G_DOT free $(fmt_gb "$PLAN_MACOS_FREE_AFTER")"
  ui_kv "Linux / Btrfs" "$G_APPROX $(fmt_gb "$PLAN_ROOT")" "root filesystem"
  ui_kv "Asahi boot data" "$G_APPROX $(fmt_gb "$PLAN_BOOT")" "2.5 GB stub container + 0.5 GB EFI"
  ui_kv "Apple system" "$(fmt_gb "$MAC_APPLE_SYS")" "iBoot + recovery, untouched"
  [ "$shared" -gt 0 ] && ui_kv "Shared (left free)" "$(fmt_gb "$shared")" "exFAT, created later by you"
  printf '\n   %sLinux receives %s%%%s  %s  macOS retains %s%%  %s  boot/system %s%%\n' \
    "$C_LINUX$C_BOLD" "$(pct "$PLAN_LINUX_ACTUAL" "$PLAN_DISK")" "$C_RESET" "$G_DOT" \
    "$(pct "$PLAN_MACOS_NEW" "$PLAN_DISK")" "$G_DOT" "$(pct "$boot" "$PLAN_DISK")"
  ui_section "Three different numbers"
  ui_kv "You request" "Linux $(fmt_gb "$linux")" "the installer's New OS size"
  ui_kv "Estimated result" "shown above" "rounded; boot data and alignment vary slightly"
  if [ "$PLAN_MODE" = resize ]; then
    ui_kv "Installer creates" "exact sizes" "you type ${PLAN_MACOS_NEW_GB}GB, then $PLAN_OS_SIZE_ANSWER; it aligns to 1 MiB"
  else
    ui_kv "Installer creates" "exact sizes" "no resize; you type $PLAN_OS_SIZE_ANSWER into existing free space"
  fi
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
  d=$([ "${CFG_enc:-1}" = 0 ] && echo n || echo y)
  printf '   %sEncrypt Linux root?%s\n' "$C_BOLD" "$C_RESET"
  ui_note "Recommended for a laptop. You will enter a disk passphrase during the Omarchy Mac migration flow. The bootstrap never stores this passphrase."
  if ui_yesno "Encrypt" "$d"; then CFG_enc=1; else [ $? = 3 ] && return 3; CFG_enc=0; fi
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

mac_save_plan() {
  cfg_save
  state_stamp planned_at
  [ "${CFG_shared:-0}" -gt 0 ] && mac_write_shared_plan
  return 0
}

mac_write_shared_plan() {
  local f="$OMB_STATE_DIR/shared-storage-plan.txt"
  if [ "$OMB_DRY_RUN" = 1 ]; then
    ui_would "write the shared-storage plan to $(tildify "$f")"
    return 0
  fi
  cat >"$f" <<EOF
Shared data area — post-install plan (not executed by omarchy-bootstrap)
Planned $(now_utc) for $MAC_MODEL_ID, disk $MAC_DISK.

What was reserved
  The Asahi installer was told to give Linux ${CFG_linux}GB instead of "max",
  leaving about ${CFG_shared} GB of unpartitioned space after the Linux partitions.

Why this is manual
  Asahi documents no installer workflow for a shared partition, and a wrong
  partition-table edit can make macOS unbootable. Read first:
  $ASAHI_DOCS_PARTITIONING

Trade-offs of exFAT
  Readable and writable from both systems; no Unix permissions, no symlinks,
  case-insensitive, no journaling. Good for media and hand-offs, poor for Git
  checkouts and build trees.

Steps, from Linux (exfatprogs ships with Omarchy)
  1. Identify the free region:   lsblk -o NAME,SIZE,TYPE,PARTLABEL /dev/nvme0n1
                                 sudo parted /dev/nvme0n1 unit GB print free
  2. Create one partition in that region only, with parted's mkpart, using the
     start and end printed as "Free Space". Do not touch any other partition,
     and never Apple_APFS_Recovery (the last partition).
  3. Restore GPT ordering, as the cheatsheet requires after Linux-side edits:
     sudo fdisk /dev/nvme0n1   then  x  f  r  w
  4. Format:  sudo mkfs.exfat -L SHARED /dev/nvme0n1pN
  5. Verify from macOS:  diskutil list   (the volume appears as SHARED)
EOF
  log_event record "shared-storage plan written to $(tildify "$f")"
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
    state_stamp backup_confirmed_at
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
    printf '   %s%s%s\n' "$C_DIM" "public repository — no git needed:" "$C_RESET"
    ui_cmd "mkdir -p $dest"
    ui_cmd "curl -fsSL https://github.com/$slug/archive/$ref.tar.gz | tar xz --strip-components=1 -C $dest"
  fi
  if [ "$vis" != public ]; then
    printf '   %s%s%s\n' "$C_DIM" "private repository — sign in with a device code, then sign out again:" "$C_RESET"
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

mac_reboot_guide() {
  local name=${1:-$ASAHI_ALARM_OS_CHOICE}
  ui_section "After the installer" "it ends by shutting the Mac down"
  _guide 1 "Wait 25 seconds after the Mac powers off."
  _guide 2 "Press and HOLD the power button once, until \"Loading startup options…\" appears."
  _guide 3 "Choose \"$name\" (the OS name you gave the installer)."
  _guide 4 "A macOS Recovery dialog appears briefly. If asked to \"Select a volume to recover\", choose your normal macOS volume and authenticate."
  _guide 5 "Follow the prompts on the \"Asahi Linux installer\" screen. The Mac then boots Arch."
  _guide 6 "Log in as $ASAHI_ALARM_FIRST_LOGIN."
  _guide 7 "Connect to Wi-Fi: run nmtui, choose Activate a connection, then Quit."
  _guide 8 "Fetch this repository and continue:"
  continuation_commands
  printf '\n'
  ui_note "macOS stays installed: hold the power button at startup to choose it, or set the default in System Settings > General > Startup Disk. Photograph this screen — no clipboard survives the reboot. './omarchy-bootstrap resume' on macOS shows it again."
}

_guide() {
  local n=$1 text=$2 first=1
  printf '%s\n' "$text" | fold -s -w $((UI_W - 9)) | while IFS= read -r l; do
    if [ "$first" = 1 ]; then
      printf '   %s%2s%s  %s\n' "$C_ACCENT$C_BOLD" "$n" "$C_RESET" "$l"
      first=0
    else
      printf '       %s\n' "$l"
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

  ui_kv "URL" "$FETCH_URL"
  ui_kv "Downloaded" "$FETCH_AT"
  ui_kv "Size" "$FETCH_SIZE bytes"
  ui_kv "SHA-256" "$FETCH_SHA256"
  ui_kv "Saved to" "$(tildify "$FETCH_PATH")"
  if [ "$version" = "$ASAHI_INSTALLER_VERIFIED" ]; then
    ui_kv "Fetches installer" "$version" "matches the version this tool was checked against"
  else
    ui_kv "Fetches installer" "${version:-unknown}" "${C_WARN}checked against $ASAHI_INSTALLER_VERIFIED — prompts may differ${C_RESET}"
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
  offer_inspection || {
    printf '\n'
    ui_info "Not launched. Nothing changed."
    return 1
  }

  # The answer card.
  if [ "$PLAN_MODE" = resize ]; then first_answer="${PLAN_MACOS_NEW_GB}GB"; else first_answer=$PLAN_OS_SIZE_ANSWER; fi
  local n=0
  ui_card_open "When the Asahi Alarm installer asks"
  ui_card_row $((n += 1)) "Press enter to continue" "Enter" "and your macOS password when asked"
  if [ "$PLAN_MODE" = resize ]; then
    ui_card_row $((n += 1)) "Choose what to do" "r" "Resize an existing partition"
    ui_card_row $((n += 1)) "New size  (macOS keeps)" "${PLAN_MACOS_NEW_GB}GB" "on your clipboard"
    ui_card_row $((n += 1)) "Continue?" "y" "the Mac may seem frozen; wait"
  fi
  ui_card_row $((n += 1)) "Choose what to do" "f" "Install an OS into free space"
  ui_card_row $((n += 1)) "Choose an OS to install" "$ASAHI_ALARM_OS_CHOICE" "type its number"
  ui_card_row $((n += 1)) "New OS size  (Linux gets)" "$PLAN_OS_SIZE_ANSWER" "$G_APPROX $(fmt_gb "$PLAN_LINUX_ACTUAL") incl. 3 GB boot data"
  ui_card_row $((n += 1)) "OS name" "Enter" "or e.g. Omarchy; shown in Startup Options"
  ui_card_text "Everything else: read it, and follow the installer's own instructions."
  ui_card_close
  if clipboard_copy "$first_answer" && [ "$OMB_DRY_RUN" != 1 ]; then
    ui_info "Copied $first_answer to the clipboard."
  fi

  mac_reboot_guide

  ui_callout fail "Last stop before your disk changes." \
    "The installer will ask for your macOS password, resize the macOS container to ${PLAN_MACOS_NEW_GB:-its current size} GB, create the Linux partitions, then shut the Mac down." \
    "Its warnings are its own — read them. Quitting at its menu with q changes nothing."
  if ! ui_confirm_word launch "Run the official Asahi Alarm installer now."; then
    printf '\n'
    ui_info "Not launched. Nothing changed. Run ./omarchy-bootstrap again when ready."
    return 1
  fi

  state_unset asahi_exit
  state_stamp asahi_launched_at
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
  if [ "$rc" = 0 ]; then
    ui_ok "The installer finished."
    mac_reboot_guide
  else
    ui_warn "The installer exited with status $rc. Nothing is assumed to have happened."
    ui_note "Rerunning is safe: ./omarchy-bootstrap will re-survey the disk, and the installer offers 'p' to repair an incomplete install."
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

mac_survey() {
  if ui_interactive; then
    printf '\n'
    ui_spin "Surveying this Mac (read-only)" true
  fi
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
    ui_callout fail "This Mac cannot continue."
    while IFS= read -r line; do
      [ -n "$line" ] && ui_callout_body fail "$line"
    done <<EOF
$blockers
EOF
    printf '\n'
    return 1
  fi
  if [ "$MAC_ASAHI_PRESENT" = 1 ]; then
    mac_existing_install
    return 0
  fi
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
        mac_plan_compute
        plan_layout "$((CFG_linux * GB))"
        mac_shared_prompt || { _mac_quit; return 0; }
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
            mac_save_plan
            printf '\n'
            ui_ok "Plan saved. Run ./omarchy-bootstrap to continue; your saved answers are the defaults."
            printf '\n'
            return 0
            ;;
        esac
        mac_save_plan
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
  ui_callout info "Linux partitions already exist on $MAC_DISK." \
    "This tool will not start a second install. If the new OS is not in Startup Options yet, finish the boot steps below." \
    "If an install stopped halfway, rerun the Asahi Alarm installer yourself and choose 'p' (repair). On macOS 27, if the Linux entry disappeared from Startup Options, the installer's '7' option fixes it."
  printf '\n   %sPartitions%s\n' "$C_DIM" "$C_RESET"
  printf '%s' "$MAC_PARTS" | while IFS='|' read -r id content size role; do
    [ -n "$id" ] || continue
    printf '     %-10s %-22s %10s  %s%s%s\n' "$id" "$content" "$(fmt_gb "$size")" "$C_DIM" "$role" "$C_RESET"
  done
  mac_reboot_guide
  printf '\n'
}

mac_resume() {
  OMB_PHASE=macos
  mac_survey
  mac_screen reboot
  if [ "$MAC_ASAHI_PRESENT" = 1 ]; then
    ui_ok "Linux partitions found on $MAC_DISK — Phase 1 is done on this Mac."
    mac_reboot_guide
  elif [ -n "$(state_get asahi_launched_at)" ]; then
    ui_warn "The installer was launched at $(state_get asahi_launched_at), but no Linux partitions are on $MAC_DISK."
    ui_note "Run ./omarchy-bootstrap to start again; the plan is kept."
  else
    ui_info "Phase 1 has not reached the installer yet. Run ./omarchy-bootstrap to continue."
  fi
  printf '\n'
}

mac_dev_note() {
  ui_header "macOS $G_DOT developer setup"
  ui_note "The developer setup runs on the Linux side, after Omarchy is installed: ./omarchy-bootstrap dev"
  printf '\n'
}
