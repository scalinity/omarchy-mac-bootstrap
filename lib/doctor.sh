# shellcheck shell=bash
# `doctor` and `status` for both operating systems. Read-only throughout.

DOC_PASS=0 DOC_WARN=0 DOC_FAIL=0

doc() {
  ui_tag "$@"
  case "$1" in
    pass) DOC_PASS=$((DOC_PASS + 1)) ;;
    warn) DOC_WARN=$((DOC_WARN + 1)) ;;
    fail) DOC_FAIL=$((DOC_FAIL + 1)) ;;
  esac
  log_event doctor "$1 $2 — ${3:-}"
}

doc_summary() {
  local ws=s fs=s
  [ "$DOC_WARN" = 1 ] && ws=""
  [ "$DOC_FAIL" = 1 ] && fs=""
  printf '\n   %s%s passed%s  %s  %s%s warning%s%s  %s  %s%s failure%s%s\n\n' \
    "$C_PASS" "$DOC_PASS" "$C_RESET" "$G_DOT" "$C_WARN" "$DOC_WARN" "$ws" "$C_RESET" "$G_DOT" "$C_FAIL" "$DOC_FAIL" "$fs" "$C_RESET"
  [ "$DOC_FAIL" = 0 ]
}

cmd_doctor() {
  case "$OMB_PLATFORM" in
    macos) mac_doctor ;;
    linux) lx_doctor ;;
    *)
      ui_fail "Unsupported system: $OMB_OS"
      return 1
      ;;
  esac
}

cmd_status() {
  case "$OMB_PLATFORM" in
    macos) mac_status ;;
    linux) lx_status ;;
    *)
      ui_fail "Unsupported system: $OMB_OS"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# macOS
# ---------------------------------------------------------------------------

mac_doctor() {
  local smart winfo
  OMB_PHASE=macos
  mac_detect
  cfg_load
  mac_plan_compute
  ui_header "macOS $G_DOT doctor"
  ui_section "Omarchy Mac Doctor" "read-only"

  if [ "$MAC_APPLE_SILICON" = 1 ]; then doc pass "Apple Silicon" "$MAC_ARCH"; else doc fail "Apple Silicon" "${MAC_ARCH:-unknown}"; fi
  case "$DEV_TIER" in
    supported) doc pass "Supported model" "${DEV_NAME:-$MAC_MODEL_ID}" ;;
    experimental) doc warn "Supported model" "${DEV_NAME} — experimental upstream" ;;
    *) doc fail "Supported model" "${DEV_NAME:-$MAC_MODEL_ID} ($([ "$DEV_CHIP" = unknown ] && echo "$MAC_CHIP" || echo "$DEV_CHIP")) not supported by Asahi" ;;
  esac
  if ver_ge "${MAC_OS_VERSION:-0}" "$ASAHI_MIN_MACOS"; then doc pass "macOS version" "$MAC_OS_VERSION"; else doc fail "macOS version" "$MAC_OS_VERSION < $ASAHI_MIN_MACOS"; fi
  if [ "$MAC_DISK_INTERNAL" = true ]; then doc pass "Internal boot disk" "$MAC_DISK $G_DOT container $MAC_CONTAINER"; else doc fail "Internal boot disk" "${MAC_DISK:-unknown} is not internal"; fi

  smart=$(plist_get "$(sys_cmd "diskutil_info_$MAC_DISK" diskutil info -plist "$MAC_DISK")" SMARTStatus)
  case "$smart" in
    Verified) doc pass "SSD health (SMART)" "Verified" ;;
    '') doc info "SSD health (SMART)" "not reported" ;;
    *) doc fail "SSD health (SMART)" "$smart" ;;
  esac

  if [ "$MAC_ASAHI_PRESENT" = 1 ]; then
    doc info "Free space" "Linux partitions already present"
  elif [ "$PLAN_LINUX_MAX" -ge "$PLAN_LINUX_REC" ]; then
    doc pass "Free space" "Linux can have up to $(fmt_gb "$PLAN_LINUX_MAX")"
  elif [ "$PLAN_LINUX_MAX" -ge "$PLAN_LINUX_MIN" ]; then
    doc warn "Free space" "up to $(fmt_gb "$PLAN_LINUX_MAX"); ${OMARCHY_LINUX_RECOMMENDED_GB} GB recommended"
  else
    doc fail "Free space" "free $(fmt_gb "$PLAN_SHORTFALL") more for the ${OMARCHY_LINUX_MIN_GB} GB minimum"
  fi
  if [ "$PLAN_OVERHEAD_WARN" = 1 ]; then
    doc warn "APFS resize overhead" "$(fmt_gb "$PLAN_OVERHEAD") (snapshots / pending update); see $ASAHI_TM_CLEANUP"
  else
    doc pass "APFS resize overhead" "$(fmt_gb "$PLAN_OVERHEAD")"
  fi
  if [ "$MAC_LIMIT_PREF" -gt 0 ]; then
    doc pass "APFS resize limits" "diskutil reports a minimum of $(fmt_gb "$MAC_LIMIT_PREF")"
  else
    doc warn "APFS resize limits" "diskutil did not report limits for ${MAC_CONTAINER:-the container}"
  fi
  if [ "$MAC_ADMIN" = 1 ]; then doc pass "Administrator" "$MAC_USER"; else doc fail "Administrator" "$MAC_USER is not an admin"; fi
  doc info "FileVault" "$([ "$MAC_FILEVAULT" = true ] && echo "on — the installer asks for your password" || echo off)"
  if [ -n "$(state_get backup_confirmed_at)" ]; then
    doc pass "Backup confirmed" "$(state_get backup_confirmed_at)"
  else
    doc warn "Backup confirmed" "not yet; asked before the installer runs"
  fi
  if sys_reachable asahi_home "$ASAHI_ALARM_VERSION_URL"; then
    doc pass "Installer reachable" "asahi-alarm.org"
  else
    doc fail "Installer reachable" "asahi-alarm.org unreachable"
  fi
  if [ "$MAC_ASAHI_PRESENT" = 1 ]; then
    doc info "Existing install" "Linux partitions on $MAC_DISK"
    ver_ge "${MAC_OS_VERSION:-0}" 27 && doc info "macOS 27" "if Linux vanished from Startup Options, rerun the installer and choose 7"
  fi
  [ -n "$(state_get cfg_linux)" ] && doc info "Saved plan" "Linux $(state_get cfg_linux) GB $G_DOT $(state_get planned_at)"
  winfo="installer resize failures usually mean APFS damage: run First Aid from Recovery"
  doc info "If a resize fails" "$winfo"
  doc info "macOS" "remains installed and bootable; the installer never removes it"
  doc_summary
}

mac_next_action() {
  local blockers
  blockers=$(mac_blockers)
  if [ -n "$blockers" ]; then
    printf 'This Mac cannot continue: %s' "$(printf '%s' "$blockers" | head -1)"
  elif [ "$MAC_ASAHI_PRESENT" = 1 ]; then
    echo "Boot the new OS from Startup Options, then run ./omarchy-bootstrap resume <token> on Linux (./omarchy-bootstrap resume shows it)."
  elif [ -n "$(state_get asahi_launched_at)" ]; then
    echo "The installer was launched but no Linux partitions exist; run ./omarchy-bootstrap to try again."
  elif [ -n "$(state_get backup_confirmed_at)" ] && [ -n "$(state_get cfg_linux)" ]; then
    echo "Run ./omarchy-bootstrap to download and launch the Asahi Alarm installer."
  elif [ -n "$(state_get cfg_linux)" ]; then
    echo "Run ./omarchy-bootstrap to confirm the backup and continue."
  else
    echo "Run ./omarchy-bootstrap to survey this Mac and plan storage."
  fi
}

mac_status() {
  OMB_PHASE=macos
  mac_detect
  cfg_load
  mac_plan_compute
  local active=survey
  [ -n "$(state_get cfg_linux)" ] && active=asahi
  [ "$MAC_ASAHI_PRESENT" = 1 ] && active=reboot
  mac_screen "$active"
  ui_section "Detected now" "$MAC_MODEL_ID"
  ui_kv "Machine" "${DEV_NAME:-$MAC_CHIP}" "$DEV_TIER"
  ui_kv "Linux partitions" "$([ "$MAC_ASAHI_PRESENT" = 1 ] && echo "present on $MAC_DISK" || echo none)"
  ui_kv "Safe Linux max" "$(fmt_gb "$PLAN_LINUX_MAX")"
  ui_section "Recorded" "$(tildify "$STATE_FILE")"
  _status_row "Surveyed" surveyed_at
  if [ -n "$(state_get cfg_linux)" ]; then
    ui_kv "Plan" "Linux $(state_get cfg_linux) GB$([ "$(state_get cfg_shared 0)" -gt 0 ] && printf ' + %s GB shared' "$(state_get cfg_shared)")" "$(state_get planned_at)"
    ui_kv "Choices" "$(state_get cfg_user)@$(state_get cfg_host) $G_DOT encrypt $(state_get cfg_enc)"
  else
    ui_kv "Plan" "not yet"
  fi
  _status_row "Backup confirmed" backup_confirmed_at
  _status_row "Installer launched" asahi_launched_at
  [ -n "$(state_get asahi_bootstrap_sha256)" ] && ui_kv "Bootstrap SHA-256" "$(state_get asahi_bootstrap_sha256)" "$(state_get asahi_installer_version)"
  [ -n "$(state_get asahi_exit)" ] && ui_kv "Installer exit" "$(state_get asahi_exit)"
  ui_section "Next"
  ui_para "$(mac_next_action)"
  if [ -n "$(state_get cfg_user)" ]; then
    ui_section "Resume token" "type this on Linux"
    ui_cmd "./omarchy-bootstrap resume $(token_encode)"
  fi
  printf '\n'
}

_status_row() {
  local v
  v=$(state_get "$2")
  ui_kv "$1" "${v:-not yet}"
}

# ---------------------------------------------------------------------------
# Linux
# ---------------------------------------------------------------------------

lx_doctor() {
  local avail upstream snap
  OMB_PHASE=linux
  lx_detect
  lx_online
  cfg_load
  ui_header "linux $G_DOT doctor"
  ui_section "Omarchy Mac Doctor" "read-only"

  if [ "$LX_ARCH" = aarch64 ]; then doc pass "aarch64" "$LX_KERNEL"; else doc fail "aarch64" "${LX_ARCH:-unknown}"; fi
  if [ "$LX_APPLE" = 1 ]; then doc pass "Apple Silicon" "${LX_DT_MODEL:-$LX_BOARD}"; else doc fail "Apple Silicon" "no Apple device tree"; fi
  case "$DEV_TIER" in
    supported) doc pass "Supported model" "${DEV_CHIP}" ;;
    experimental) doc warn "Supported model" "${DEV_CHIP} — experimental upstream" ;;
    *) doc warn "Supported model" "${DEV_CHIP:-unknown} not in the device table" ;;
  esac
  if lx_is_arch; then doc pass "Distribution" "${LX_OS_NAME:-$LX_OS_ID}"; else doc warn "Distribution" "${LX_OS_NAME:-unknown}"; fi
  if [ "$LX_ROUTE" = 1 ] && [ "$LX_ONLINE" = 1 ]; then
    doc pass "Network" "github.com reachable"
  elif [ "$LX_ROUTE" = 1 ]; then
    doc warn "Network" "route present, github.com unreachable"
  else
    doc fail "Network" "no default route — run nmtui"
  fi
  if [ "$LX_ROOT_FS" = btrfs ]; then doc pass "Btrfs root" "$LX_ROOT_SRC"; else doc warn "Btrfs root" "${LX_ROOT_FS:-unknown}"; fi
  if [ -n "$LX_BOOT_SRC" ] && [ "$LX_BOOT_SRC" != "$LX_ROOT_SRC" ]; then
    doc pass "Boot mount" "/boot on $LX_BOOT_SRC ($LX_BOOT_FS)"
  elif [ "$LX_ROOT_CRYPT" = 1 ]; then
    doc fail "Boot mount" "/boot is on the encrypted root — GRUB cannot read it"
  else
    doc info "Boot mount" "/boot on the root filesystem (moved only when encrypting)"
  fi
  if [ "$LX_ROOT_CRYPT" = 1 ]; then
    doc pass "Encryption" "root is LUKS"
  elif [ "${CFG_enc:-1}" = 1 ] && [ "$LX_OMARCHY_STATE" != absent ]; then
    doc warn "Encryption" "requested, root is not encrypted"
  else
    doc info "Encryption" "root is not encrypted"
  fi

  case "$LX_OMARCHY_STATE" in
    installed)
      case "$LX_OMARCHY_VERSION" in
        "$OMARCHY_EXPECTED_MAJOR".*) doc pass "Omarchy $OMARCHY_EXPECTED_MAJOR" "$LX_OMARCHY_VERSION" ;;
        *) doc warn "Omarchy $OMARCHY_EXPECTED_MAJOR" "installed version ${LX_OMARCHY_VERSION:-unknown}" ;;
      esac
      ;;
    in-progress)
      case "$LX_UNIT_STATE" in
        active | activating) doc info "Omarchy $OMARCHY_EXPECTED_MAJOR" "guided setup running now on tty1" ;;
        *) doc warn "Omarchy $OMARCHY_EXPECTED_MAJOR" "guided setup paused — ./omarchy-bootstrap resume" ;;
      esac
      ;;
    partial) doc warn "Omarchy $OMARCHY_EXPECTED_MAJOR" "package present, install unfinished (stale partial state)" ;;
    *) doc info "Omarchy $OMARCHY_EXPECTED_MAJOR" "not installed" ;;
  esac
  if upstream=$(sys_net omarchy_version "$OMARCHY_MAC_VERSION_URL" | clean_version) && [ -n "$upstream" ]; then
    if [ -n "$LX_OMARCHY_VERSION" ] && [ "$upstream" != "$LX_OMARCHY_VERSION" ]; then
      doc info "Upstream Omarchy Mac" "$upstream on $OMARCHY_MAC_BRANCH (installed $LX_OMARCHY_VERSION) — 'omarchy update' when ready"
    else
      doc info "Upstream Omarchy Mac" "$upstream on $OMARCHY_MAC_BRANCH"
    fi
  else
    doc warn "Upstream Omarchy Mac" "could not read the version on $OMARCHY_MAC_BRANCH"
  fi

  if sys_has pacman; then
    if [ -e "$(sys_path /var/lib/pacman/db.lck)" ]; then
      doc warn "Package manager" "pacman lock present — stale if no pacman is running"
    elif sys_cmd pacman_dk pacman -Dk >/dev/null; then
      doc pass "Package manager" "pacman database consistent"
    else
      doc warn "Package manager" "pacman -Dk reported problems"
    fi
  else
    doc fail "Package manager" "pacman not found"
  fi
  if sys_has snapper; then
    snap=$(sys_cmd snapper_configs snapper --no-headers list-configs)
    case "$snap" in
      *root*) doc pass "Snapper" "root config present" ;;
      '') doc info "Snapper" "installed; configs need root to list" ;;
      *) doc warn "Snapper" "no root config" ;;
    esac
  elif [ "$LX_OMARCHY_STATE" = installed ]; then
    doc warn "Snapper" "not installed"
  else
    doc info "Snapper" "set up by Omarchy's install"
  fi
  avail=$(sys_cmd df_root df -Pk / | awk 'NR==2 {print $4}')
  if [ -n "$avail" ]; then
    if [ "$avail" -lt 2000000 ]; then
      doc fail "Disk space" "$((avail / 1000000)) GB free on /"
    elif [ "$avail" -lt 10000000 ]; then
      doc warn "Disk space" "$((avail / 1000000)) GB free on /"
    else
      doc pass "Disk space" "$((avail / 1000000)) GB free on /"
    fi
  fi
  if [ "$LX_SETUP_CONF" = 1 ] && [ "$LX_OMARCHY_STATE" = installed ]; then
    doc warn "Setup leftovers" "$OMS_CONF remains on an installed machine"
  fi
  case "$(sys_cmd sshd_active systemctl is-active sshd)" in
    active) doc pass "SSH" "sshd running" ;;
    *) if [ "${CFG_ssh:-0}" = 1 ]; then doc warn "SSH" "disabled — planned on; ./omarchy-bootstrap dev → ssh"; else doc info "SSH" "disabled"; fi ;;
  esac
  [ -n "$LX_PAGESIZE" ] && doc info "Page size" "$LX_PAGESIZE bytes$([ "$LX_PAGESIZE" = 16384 ] && printf ' (16K: some prebuilt binaries assume 4K)')"
  doc info "macOS" "remains available through the boot picker (hold power at startup)"
  doc_summary
}

lx_next_action() {
  case "$LX_OMARCHY_STATE" in
    installed)
      if [ -n "$(state_get dev_last_run_at)" ]; then
        echo "Done. './omarchy-bootstrap dev' is rerunnable any time."
      else
        echo "Omarchy is installed. Optional: ./omarchy-bootstrap dev"
      fi
      ;;
    in-progress)
      case "$LX_UNIT_STATE" in
        active | activating) echo "omarchy-mac-setup is running on tty1 (Ctrl+Alt+F1). Let it finish." ;;
        *) echo "omarchy-mac-setup is paused; it resumes at the next boot, or run ./omarchy-bootstrap resume as root." ;;
      esac
      ;;
    *)
      if [ "$LX_ROUTE" = 0 ]; then
        echo "Connect to the network (nmtui), then run ./omarchy-bootstrap as root."
      else
        echo "Run ./omarchy-bootstrap as root to start Omarchy Mac."
      fi
      ;;
  esac
}

lx_status() {
  local f seen=0
  OMB_PHASE=linux
  lx_detect
  cfg_load
  lx_screen "$([ "$LX_OMARCHY_STATE" = installed ] && echo dev || echo omarchy)"
  ui_section "Detected now" "read from the machine"
  ui_kv "Omarchy" "$LX_OMARCHY_STATE" "${LX_OMARCHY_VERSION:-}"
  ui_kv "Root" "${LX_ROOT_FS:-?}$([ "$LX_ROOT_CRYPT" = 1 ] && printf ' on LUKS')" "$LX_ROOT_SRC"
  ui_kv "/boot" "${LX_BOOT_SRC:-on root}"
  ui_kv "Network" "$([ "$LX_ROUTE" = 1 ] && echo "default route" || echo offline)"
  if [ "$LX_SETUP_BIN" = 1 ]; then
    ui_section "omarchy-mac-setup --status" "upstream"
    sys_cmd setup_status "$OMS_SELF" --status | sed 's/^/   /'
  fi
  for f in "$STATE_FILE" "$STATE_SYSTEM_FILE"; do
    [ -f "$f" ] || continue
    [ "$f" = "$STATE_SYSTEM_FILE" ] && [ "$STATE_FILE" = "$STATE_SYSTEM_FILE" ] && [ "$seen" = 1 ] && continue
    seen=1
    ui_section "Recorded" "$(tildify "$f")"
    ui_kv "Choices" "$(state_get cfg_user '' "$f")@$(state_get cfg_host '' "$f") $G_DOT encrypt $(state_get cfg_enc '' "$f")"
    ui_kv "Token loaded" "$(state_get phase1_choices_loaded_at 'not used' "$f")"
    ui_kv "Setup launched" "$(state_get omarchy_launched_at 'not yet' "$f")"
    [ -n "$(state_get omarchy_setup_sha256 '' "$f")" ] && ui_kv "Setup SHA-256" "$(state_get omarchy_setup_sha256 '' "$f")"
    [ -n "$(state_get dev_last_run_at '' "$f")" ] && ui_kv "Developer setup" "$(state_get dev_modules '' "$f")" "$(state_get dev_last_run_at '' "$f")"
  done
  ui_section "Next"
  ui_para "$(lx_next_action)"
  printf '\n'
}
