# shellcheck shell=bash
# Phase 2 — Asahi Alarm: survey, network, choices, and the provenance-first
# handoff to Omarchy Mac's omarchy-mac-setup. Where the machine has got to is
# always read from the machine; recorded state is context, never authority.

lx_detect() {
  local f compat="" marker=0 runtime=0 display=0

  LX_ARCH=$(sys_cmd uname_m uname -m)
  LX_KERNEL=$(sys_cmd uname_r uname -r)
  f=$(sys_path /proc/device-tree/compatible)
  [ -r "$f" ] && compat=$(tr '\0' ' ' <"$f")
  f=$(sys_path /proc/device-tree/model)
  LX_DT_MODEL=""
  [ -r "$f" ] && LX_DT_MODEL=$(tr -d '\0' <"$f")
  case " $compat " in *" apple,"*) LX_APPLE=1 ;; *) LX_APPLE=0 ;; esac
  LX_BOARD=$(printf '%s' "$compat" | tr ' ' '\n' | sed -n 's/^apple,\(j[0-9a-z]*\)$/\1/p' | head -1)
  LX_SOC=$(printf '%s' "$compat" | tr ' ' '\n' | sed -n 's/^apple,\(t[0-9]*\)$/\1/p' | head -1)
  if ! device_by_board "$LX_BOARD"; then
    DEV_SOC=$LX_SOC DEV_CHIP=$(soc_chip "$LX_SOC") DEV_TIER=$(soc_tier "$LX_SOC")
  fi

  f=$(sys_path /etc/os-release)
  LX_OS_NAME=$(sed -n 's/^PRETTY_NAME=//p' "$f" 2>/dev/null | tr -d '"' | head -1)
  LX_OS_ID=$(sed -n 's/^ID=//p' "$f" 2>/dev/null | tr -d '"' | head -1)
  LX_OS_LIKE=$(sed -n 's/^ID_LIKE=//p' "$f" 2>/dev/null | tr -d '"' | head -1)

  LX_ROOT_SRC=$(sys_cmd findmnt_root findmnt -no SOURCE / | sed 's/\[.*\]//')
  LX_ROOT_FS=$(sys_cmd findmnt_root_fstype findmnt -no FSTYPE /)
  LX_BOOT_SRC=$(sys_cmd findmnt_boot findmnt -no SOURCE /boot | sed 's/\[.*\]//')
  LX_BOOT_FS=$(sys_cmd findmnt_boot_fstype findmnt -no FSTYPE /boot)
  LX_ROOT_CRYPT=0
  [ "$(sys_cmd lsblk_root_type lsblk -no TYPE "$LX_ROOT_SRC" | head -1)" = crypt ] && LX_ROOT_CRYPT=1
  LX_ROUTE=0
  sys_cmd ip_route ip route | grep -q '^default ' && LX_ROUTE=1
  LX_USER=$(sys_cmd id_un id -un)

  # Omarchy Mac's own signals (bin/omarchy-mac-setup install_complete: the
  # marker, or Omarchy's version file with display-manager.service as a
  # symlink; upstream also wants the @factory subvolume, which only root's
  # btrfs tooling can see).
  [ -f "$(sys_path "$OMS_MARKER")" ] && marker=1
  [ -f "$(sys_path "$OMARCHY_RUNTIME_VERSION")" ] && runtime=1
  [ -L "$(sys_path "$OMARCHY_DISPLAY_MANAGER")" ] && display=1
  LX_OMARCHY_VERSION=""
  [ "$runtime" = 1 ] && LX_OMARCHY_VERSION=$(head -1 "$(sys_path "$OMARCHY_RUNTIME_VERSION")")
  LX_SETUP_CONF=0
  [ -f "$(sys_path "$OMS_CONF")" ] && LX_SETUP_CONF=1
  LX_SETUP_BIN=0
  [ -f "$(sys_path "$OMS_SELF")" ] && LX_SETUP_BIN=1
  LX_UNIT_STATE=$(sys_cmd unit_active systemctl is-active "$OMS_UNIT")
  if [ "$marker" = 1 ] || { [ "$runtime" = 1 ] && [ "$display" = 1 ]; }; then
    LX_OMARCHY_STATE=installed
  elif [ "$LX_SETUP_CONF" = 1 ]; then
    LX_OMARCHY_STATE=in-progress
  elif [ "$runtime" = 1 ]; then
    LX_OMARCHY_STATE=partial
  else
    LX_OMARCHY_STATE=absent
  fi
  # Upstream writes the marker, then removes its conf and unit on the next
  # boot (step_done): both present means "installed, finishing".
  LX_SETUP_FINISHING=0
  [ "$LX_OMARCHY_STATE" = installed ] && [ "$LX_SETUP_CONF" = 1 ] && LX_SETUP_FINISHING=1
  lx_detect_encryption

  LX_PAGESIZE=$(sys_cmd pagesize getconf PAGESIZE)
  LX_KEYMAP=$(sed -n 's/^KEYMAP=//p' "$(sys_path /etc/vconsole.conf)" 2>/dev/null | tr -d '"' | head -1)
  LX_TZ=$(sys_cmd timezone timedatectl show -p Timezone --value)
  LX_LANG=$(sed -n 's/^LANG=//p' "$(sys_path /etc/locale.conf)" 2>/dev/null | head -1)
}

# lx_detect_encryption — LX_ENC_STATE, from Omarchy Mac's own signals
# (bin/omarchy-mac-setup root_is_encrypted, bin/omarchy-system-btrfs-migrate),
# and LX_ENC_WHY when a LUKS root's header could not be read:
#   none          root is not a LUKS device and no migration is staged
#   migrating     a migration is staged (/etc/omarchy-btrfs-migrate.conf), or
#                 root's LUKS header records the online-reencrypt requirement
#   complete      root is LUKS, and either its header, read as root, is a
#                 LUKS2 header without that requirement, or (as a user, who
#                 cannot read the header) the migration's finish marker exists
#   unverified    root is LUKS, read as a user, and there is no finish marker
#   probe-failed  root is LUKS, read as root, and the header could not be
#                 read as one: no single partition under root, cryptsetup
#                 missing or failing, no output, or output that is not a
#                 LUKS2 header
# A header that could not be read is never taken for one without the flag,
# and as root the finish marker does not stand in for it: the marker is
# upstream's word, the header is the thing itself. (Upstream's own
# root_is_encrypted reads a failed luksDump as finished; this does not.)
lx_detect_encryption() {
  local staged=0 done_marker=0 parts dump rc
  [ -f "$(sys_path "$OMS_MIGRATE_CONF")" ] && staged=1
  [ -f "$(sys_path "$OMS_MIGRATE_DONE")" ] && done_marker=1
  # The partition under root: exactly one, or none is named.
  parts=$(sys_cmd lsblk_root_backing lsblk -nsplo NAME,TYPE "$LX_ROOT_SRC" | awk '$2 == "part" {print $1}')
  LX_ROOT_BACKING=""
  case "$parts" in
    *"
"*) ;;
    /dev/[a-z]*) LX_ROOT_BACKING=$parts ;;
  esac
  LX_REENCRYPT="" LX_ENC_WHY=""
  if [ "$LX_ROOT_CRYPT" = 1 ] && [ "$OMB_UID" = 0 ]; then
    if [ -z "$LX_ROOT_BACKING" ]; then
      LX_ENC_WHY="the partition under the encrypted root could not be identified"
    else
      dump=$(sys_cmd luks_dump cryptsetup luksDump "$LX_ROOT_BACKING")
      rc=$?
      if [ "$rc" = 127 ]; then
        LX_ENC_WHY="cryptsetup is not available to read the LUKS header of $LX_ROOT_BACKING"
      elif [ "$rc" != 0 ]; then
        LX_ENC_WHY="cryptsetup luksDump $LX_ROOT_BACKING failed (exit $rc)"
      elif [ -z "$dump" ]; then
        LX_ENC_WHY="cryptsetup luksDump $LX_ROOT_BACKING printed nothing"
      elif ! luks2_header_ok "$dump"; then
        LX_ENC_WHY="cryptsetup luksDump $LX_ROOT_BACKING did not print a LUKS2 header"
      elif printf '%s\n' "$dump" | grep -q 'online-reencrypt'; then
        LX_REENCRYPT=1
      else
        LX_REENCRYPT=0
      fi
    fi
  fi
  if [ "$staged" = 1 ] || [ "$LX_REENCRYPT" = 1 ]; then
    LX_ENC_STATE=migrating
  elif [ "$LX_ROOT_CRYPT" != 1 ]; then
    LX_ENC_STATE=none
  elif [ -n "$LX_ENC_WHY" ]; then
    LX_ENC_STATE=probe-failed
  elif [ "$LX_REENCRYPT" = 0 ] || [ "$done_marker" = 1 ]; then
    LX_ENC_STATE=complete
  else
    LX_ENC_STATE=unverified
  fi
}

# luks2_header_ok DUMP — does it read as `cryptsetup luksDump` of a LUKS2
# header: the title, version 2, a UUID and the data segments? Omarchy Mac
# encrypts with --type luks2.
luks2_header_ok() {
  case "$(printf '%s\n' "$1" | head -1)" in "LUKS header information"*) ;; *) return 1 ;; esac
  printf '%s\n' "$1" | grep -Eq '^Version:[[:space:]]+2[[:space:]]*$' &&
    printf '%s\n' "$1" | grep -Eq '^UUID:[[:space:]]+[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}[[:space:]]*$' &&
    printf '%s\n' "$1" | grep -q '^Data segments:'
}

# lx_setup_complete — is Omarchy Mac's work entirely finished, so nothing of
# its own is still changing the disk? Installed, its conf and unit gone,
# nothing running, no migration staged, and encryption finished if it was
# asked for. LX_INCOMPLETE_WHY says what is still outstanding.
lx_setup_complete() {
  LX_INCOMPLETE_WHY=""
  if [ "$LX_OMARCHY_STATE" != installed ]; then
    LX_INCOMPLETE_WHY="Omarchy is not installed yet ($LX_OMARCHY_STATE)"
  elif [ "$LX_SETUP_CONF" = 1 ]; then
    LX_INCOMPLETE_WHY="omarchy-mac-setup is finishing; one more boot removes its setup files"
  else
    case "$LX_UNIT_STATE" in
      active | activating) LX_INCOMPLETE_WHY="omarchy-mac-setup is running now on tty1" ;;
    esac
  fi
  if [ -z "$LX_INCOMPLETE_WHY" ]; then
    case "$LX_ENC_STATE" in
      migrating) LX_INCOMPLETE_WHY="the in-place encryption has not finished" ;;
      unverified) LX_INCOMPLETE_WHY="root is encrypted, but whether re-encryption finished can only be read as root" ;;
      probe-failed) LX_INCOMPLETE_WHY="root is encrypted, and whether re-encryption finished is not known: $LX_ENC_WHY" ;;
      none) [ "${CFG_enc:-0}" = 1 ] && LX_INCOMPLETE_WHY="encryption was chosen, but root is not encrypted" ;;
    esac
  fi
  [ -z "$LX_INCOMPLETE_WHY" ]
}

lx_is_arch() {
  case " $LX_OS_ID $LX_OS_LIKE " in *" arch "* | *" archarm "*) return 0 ;; esac
  return 1
}

lx_online() {
  LX_ONLINE=0
  ui_spin "Checking GitHub" sys_reachable github "https://github.com" && LX_ONLINE=1
  return 0
}

lx_rail() {
  local active=$1 out="" s st
  for s in $RAIL_STAGES; do
    case "$s" in
      survey | plan | asahi | reboot) st="done" ;;
      omarchy) [ "$LX_OMARCHY_STATE" = installed ] && st="done" || st=todo ;;
      dev) [ -n "$(state_get dev_last_run_at)" ] && st="done" || st=todo ;;
    esac
    [ "$s" = "$active" ] && st=current
    out="$out $st"
  done
  ui_rail "${out# }"
}

lx_screen() {
  ui_header "linux $G_DOT phase 2$([ "$OMB_DRY_RUN" = 1 ] && printf ' %s dry run' "$G_DOT")"
  lx_rail "$1"
}

lx_show_survey() {
  ui_section "Machine" "${LX_BOARD:-?} $G_DOT ${DEV_SOC:-?}"
  ui_kv "Model" "${LX_DT_MODEL:-${DEV_NAME:-unknown}}"
  ui_kv "System" "${LX_OS_NAME:-unknown}" "kernel ${LX_KERNEL:-?}"
  ui_kv "Root" "${LX_ROOT_SRC:-?}" "${LX_ROOT_FS:-?}$([ "$LX_ROOT_CRYPT" = 1 ] && printf ' on LUKS')"
  ui_kv "/boot" "${LX_BOOT_SRC:-on the root filesystem}" "${LX_BOOT_FS:-}"
  ui_kv "User" "${LX_USER:-?}" "$([ "$OMB_UID" = 0 ] && echo "uid 0" || echo "uid $OMB_UID, not root")"
  ui_section "Checks"
  if [ "$LX_ARCH" = aarch64 ]; then ui_check pass "aarch64" "$LX_ARCH"; else ui_check fail "aarch64" "${LX_ARCH:-unknown}"; fi
  if [ "$LX_APPLE" = 1 ]; then ui_check pass "Apple Silicon" "${DEV_CHIP:-?} $G_DOT Asahi device tree"; else ui_check fail "Apple Silicon" "no apple, device tree"; fi
  if lx_is_arch; then ui_check pass "Arch Linux ARM" "${LX_OS_ID}"; else ui_check warn "Arch Linux ARM" "${LX_OS_ID:-unknown} — Omarchy Mac expects Asahi Alarm"; fi
  if [ "$LX_ROOT_FS" = btrfs ]; then ui_check pass "Btrfs root" "$LX_ROOT_SRC"; else ui_check warn "Btrfs root" "${LX_ROOT_FS:-?} — Omarchy Mac converts it"; fi
  if [ "$LX_ROUTE" = 1 ] && [ "$LX_ONLINE" = 1 ]; then
    ui_check pass "Network" "github.com reachable"
  elif [ "$LX_ROUTE" = 1 ]; then
    ui_check warn "Network" "default route, but github.com unreachable"
  else
    ui_check fail "Network" "no default route"
  fi
  case "$LX_OMARCHY_STATE" in
    installed) ui_check pass "Omarchy" "${LX_OMARCHY_VERSION:-installed}" ;;
    in-progress) ui_check info "Omarchy" "guided setup in progress" ;;
    partial) ui_check warn "Omarchy" "${LX_OMARCHY_VERSION} package present, install unfinished" ;;
    *) ui_check info "Omarchy" "not installed yet" ;;
  esac
}

lx_blockers() {
  [ "$LX_ARCH" = aarch64 ] || echo "This is ${LX_ARCH:-an unknown architecture}, not aarch64."
  [ "$LX_APPLE" = 1 ] || echo "No Apple device tree: this does not look like Asahi on Apple Silicon."
  return 0
}

# ---------------------------------------------------------------------------

lx_network() {
  local tries=0
  while [ "$LX_ROUTE" = 0 ] && [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    ui_section "Network" "needed for everything from here"
    ui_note "Choose 'Activate a connection', pick your Wi-Fi, enter its password (typed into nmtui, never seen by this tool), then Quit. If nmtui reports an error right after connecting, reboot and try again — Omarchy Mac documents this."
    if sys_has nmtui; then
      ui_yesno "Open nmtui now?" y || return 1
      run nmtui
    else
      ui_cmd "nmcli device wifi connect <SSID> --ask"
      ui_pause "Connect, then press Enter"
    fi
    [ "$OMB_DRY_RUN" = 1 ] && return 0
    LX_ROUTE=0
    sys_cmd ip_route ip route | grep -q '^default ' && LX_ROUTE=1
  done
  lx_online
  [ "$LX_ROUTE" = 1 ] && [ "$LX_ONLINE" = 1 ]
}

lx_choices() {
  local have=1 k
  for k in enc user host kmap; do
    eval "[ -n \"\${CFG_$k:-}\" ]" || have=0
  done
  ui_section "Omarchy Mac choices" "passed as flags"
  if [ "$have" = 1 ]; then
    ui_kv "Encryption" "$([ "$CFG_enc" = 1 ] && echo yes || echo no)"
    ui_kv "Username" "$CFG_user"
    ui_kv "Hostname" "$CFG_host"
    ui_kv "Keymap" "$CFG_kmap" "the disk passphrase is typed with this layout"
    printf '\n'
    # Read the status directly: after `if …; fi` with no else, $? is 0.
    ui_yesno "Use these?" y
    case $? in
      0) return 0 ;;
      3) return 3 ;;
    esac
  fi
  printf '\n'
  ask_encrypt || return 3
  ui_ask CFG_user "Username" "${CFG_user:-}" valid_username || return 3
  ui_ask CFG_host "Hostname" "${CFG_host:-omarchy}" valid_hostname || return 3
  ui_ask CFG_kmap "Console keymap" "${CFG_kmap:-${LX_KEYMAP:-us}}" valid_keymap || return 3
  return 0
}

# lx_setup_flags — LX_FLAGS: the argv passed to omarchy-mac-setup.
lx_setup_flags() {
  LX_FLAGS=()
  if [ "${CFG_enc:-1}" = 1 ]; then LX_FLAGS+=(--encrypt); else LX_FLAGS+=(--no-encrypt); fi
  LX_FLAGS+=(--user "$CFG_user" --hostname "$CFG_host")
  [ -n "${CFG_kmap:-}" ] && LX_FLAGS+=(--keymap "$CFG_kmap")
  return 0
}

# setup_script_ok FILE — refuses a download that is not the setup script or
# no longer declares the flags this tool passes.
setup_script_ok() {
  head -1 "$1" | grep -Eq '^#![[:space:]]*(/usr)?/bin/(env[[:space:]]+)?bash([[:space:]]|$)' || {
    SETUP_REFUSAL="the download is not a bash script"
    return 1
  }
  local missing
  missing=$(setup_missing_flags "$(cat "$1")")
  [ -z "$missing" ] || {
    SETUP_REFUSAL="the setup script no longer declares:$missing"
    return 1
  }
}

lx_handoff() {
  local version rc
  lx_screen omarchy
  ui_section "Omarchy Mac" "$OMARCHY_MAC_REPO $G_DOT $OMARCHY_MAC_BRANCH"

  version=$(sys_net omarchy_version "$OMARCHY_MAC_VERSION_URL" | clean_version)
  case "$version" in
    "$OMARCHY_EXPECTED_MAJOR".*) ui_ok "Branch $OMARCHY_MAC_BRANCH carries Omarchy $version." ;;
    '')
      ui_fail "Could not read $OMARCHY_MAC_VERSION_URL — nothing launched."
      return 1
      ;;
    *)
      ui_fail "Branch $OMARCHY_MAC_BRANCH now carries Omarchy $version, not $OMARCHY_EXPECTED_MAJOR.x. Refusing; check 'omarchy-bootstrap sources --check' and upstream before changing lib/sources.sh."
      return 1
      ;;
  esac

  if ! fetch_upstream omarchy-mac-setup "$OMARCHY_MAC_SETUP_URL"; then
    ui_fail "Download failed: $OMARCHY_MAC_SETUP_URL"
    return 1
  fi
  if ! setup_script_ok "$FETCH_PATH"; then
    ui_fail "Refusing to run it: $SETUP_REFUSAL."
    return 1
  fi
  show_provenance
  ui_kv "Omarchy version" "$version" "verified against $OMARCHY_MAC_VERIFIED"
  state_set omarchy_setup_url "$FETCH_URL"
  state_set omarchy_setup_sha256 "$FETCH_SHA256"
  state_set omarchy_setup_fetched_at "$FETCH_AT"
  state_set omarchy_version_target "$version"

  offer_inspection || {
    printf '\n'
    ui_info "Not started. Nothing changed."
    return 1
  }

  lx_setup_flags
  ui_card_open "What omarchy-mac-setup does next"
  local n=0
  ui_card_row $((n += 1)) "Keymap, hostname, user" "$CFG_kmap, $CFG_host, $CFG_user" "you set the user's password"
  if [ "$CFG_enc" = 1 ]; then
    ui_card_row $((n += 1)) "Boot layout" "/boot → EFI" "then reboots"
    ui_card_row $((n += 1)) "Encryption" "in place" "choose the disk passphrase at the console; reboots"
  fi
  ui_card_row $((n += 1)) "Omarchy" "$version" "~15 minutes, then reboots into the desktop"
  ui_card_text "It asks 'Start? [Y/n]' first — answer y."
  ui_card_text "If a gum dialog offers to build packages with no aarch64 build, say no."
  ui_card_text "It resumes itself on tty1 after each reboot; you only type the passphrase."
  ui_card_close
  ui_section "Command"
  ui_cmd "bash $(tildify "$FETCH_PATH") $(quote_argv "${LX_FLAGS[@]}")"

  ui_callout fail "Last stop before the Linux disk changes." \
    "$([ "$CFG_enc" = 1 ] && echo "Encryption rewrites every block of the Linux root partition in place. Upstream documents it as safe to interrupt: the next boot resumes. macOS is not touched." || echo "Omarchy installs onto the existing root. macOS is not touched.")"
  if ! ui_confirm_word start "Run omarchy-mac-setup now."; then
    printf '\n'
    ui_info "Not started. Nothing changed. Run ./omarchy-bootstrap again when ready."
    return 1
  fi
  state_unset omarchy_setup_exit
  state_must_set omarchy_launched_at "$(now_utc)" || return 1
  printf '\n'
  fetch_unchanged || return 1
  run bash "$FETCH_PATH" "${LX_FLAGS[@]}"
  rc=$?
  if [ "$OMB_DRY_RUN" = 1 ]; then
    printf '\n'
    ui_info "Dry run: omarchy-mac-setup was not started."
    return 0
  fi
  state_set omarchy_setup_exit "$rc"
  if [ "$rc" != 0 ]; then
    ui_warn "omarchy-mac-setup exited with status $rc."
    ui_note "Its output is on tty1 (Ctrl+Alt+F1); upstream keeps no log file. './omarchy-bootstrap status' shows where the machine is; upstream resumes from the machine's state."
  fi
  return "$rc"
}

# lx_upstream_status — omarchy-mac-setup --status, as root only: its conf is
# readable only by root and, as another user, it cannot read the LUKS header
# either. Its colour codes are removed so the Linux console stays plain.
lx_upstream_status() {
  [ "$LX_SETUP_BIN" = 1 ] || return 0
  if [ "$OMB_UID" != 0 ]; then
    ui_note "Upstream's own view needs root:"
    ui_cmd "sudo $OMS_SELF --status"
    return 0
  fi
  sys_cmd setup_status "$OMS_SELF" --status | sed "s/$ESC\[[0-9;]*m//g" | tr -cd '[:print:]\n' | sed 's/^/   /'
}

lx_in_progress() {
  ui_section "Omarchy Mac setup in progress" "$OMS_CONF"
  lx_upstream_status
  case "$LX_UNIT_STATE" in
    active | activating)
      ui_info "It is running right now on tty1 — press Ctrl+Alt+F1 to watch it. Nothing to do here."
      return 0
      ;;
  esac
  ui_note "Upstream resumes on its own at the next boot. It can also continue now."
  if [ "$OMB_UID" != 0 ] && [ "$OMB_DRY_RUN" != 1 ]; then
    ui_cmd "sudo $OMS_SELF --resume"
    return 0
  fi
  if ui_confirm_word resume "Continue omarchy-mac-setup now."; then
    state_must_set omarchy_resumed_at "$(now_utc)" || return 1
    run "$OMS_SELF" --resume
  fi
}

lx_installed() {
  ui_section "Omarchy is installed" "${LX_OMARCHY_VERSION:-}"
  ui_note "Omarchy Mac's install is complete on this machine. Nothing will be reinstalled."
  lx_shared_step
  if [ "$OMB_UID" = 0 ]; then
    ui_note "Log in as ${CFG_user:-your user} in the desktop, open a terminal, and run the developer setup from there:"
    ui_cmd "$OMB_HOME/omarchy-bootstrap dev"
    printf '\n'
    return 0
  fi
  if [ "${CFG_dev:-1}" != 0 ] && ui_yesno "Open the developer setup?" y; then
    dev_main
    return
  fi
  ui_note "Run './omarchy-bootstrap dev' any time."
  printf '\n'
}

# lx_shared_step — once Omarchy is installed: Shared storage's next step.
lx_shared_step() {
  shared_lx_state
  [ "$SHARED_STATE" = off ] && return 0
  shared_status_rows
  case "$SHARED_STATE" in
    awaiting-macos-creation) shared_lx_macos_next ;;
    awaiting-linux-activation)
      if [ "$OMB_UID" = 0 ]; then
        ui_note "As your everyday user, in a terminal:"
        ui_cmd "$OMB_HOME/omarchy-bootstrap shared activate"
      elif ui_yesno "Set up Shared storage now?" y; then
        shared_activate_flow
      fi
      ;;
    blocked)
      ui_blockers "Shared storage needs attention." "$(printf "%s\n" "$SHARED_WHY" "Nothing was changed; docs/SHARED.md explains each case.")"
      ;;
  esac
  return 0
}

# lx_plan — the Linux side of `plan`: review and save the Omarchy Mac
# choices. Never resumes, launches, or configures anything; once Omarchy's
# setup has started, its choices are fixed and there is nothing to plan.
lx_plan() {
  case "$LX_OMARCHY_STATE" in
    installed)
      ui_info "Omarchy is installed; there is nothing left to plan on this side."
      ui_note "Developer setup: ./omarchy-bootstrap dev. Where things stand: ./omarchy-bootstrap status."
      printf '\n'
      return 0
      ;;
    in-progress)
      ui_info "omarchy-mac-setup is part-way through with the choices it started with; plan changes nothing now."
      ui_note "./omarchy-bootstrap status shows its progress; ./omarchy-bootstrap resume continues it."
      printf '\n'
      return 0
      ;;
  esac
  lx_choices || return 0
  cfg_save
  printf '\n'
  ui_ok "Choices saved$([ "$OMB_DRY_RUN" = 1 ] && printf ' (dry run: not written)'). Run ./omarchy-bootstrap to continue."
  printf '\n'
  return 0
}

# lx_main MODE [TOKEN]
lx_main() {
  local mode=$1 token=${2:-} blockers line
  OMB_PHASE=linux
  lx_detect
  lx_online
  cfg_load
  # A root run of Phase 2 leaves its record where a later user run can read it.
  if [ "$OMB_UID" != 0 ] && [ -f "$STATE_SYSTEM_FILE" ] && [ -z "$(state_get cfg_user)" ]; then
    cfg_load "$STATE_SYSTEM_FILE"
  fi
  log_event survey "board=$LX_BOARD soc=$LX_SOC os=$LX_OS_ID root=$LX_ROOT_FS crypt=$LX_ROOT_CRYPT route=$LX_ROUTE online=$LX_ONLINE omarchy=$LX_OMARCHY_STATE version=$LX_OMARCHY_VERSION"

  lx_screen "$([ "$LX_OMARCHY_STATE" = installed ] && echo dev || echo omarchy)"
  if [ -n "$token" ]; then
    ui_section "Resume token"
    token_decode "$token"
    local ok=$?
    while IFS= read -r line; do
      [ -n "$line" ] && ui_warn "$line"
    done <<EOF
$TOKEN_WARNINGS
EOF
    if [ "$ok" = 0 ]; then
      ui_ok "Phase 1 choices loaded: ${CFG_user:-?}@${CFG_host:-?}, encryption $([ "${CFG_enc:-1}" = 1 ] && echo on || echo off), Linux ${CFG_linux:-?} GB$([ "${CFG_shared:-0}" -gt 0 ] && printf ', Shared %s GB' "$CFG_shared")."
      cfg_save
      state_stamp phase1_choices_loaded_at
    else
      ui_warn "Token not usable; you will be asked instead."
    fi
  fi
  lx_show_survey

  blockers=$(lx_blockers)
  if [ -n "$blockers" ]; then
    ui_blockers "This machine cannot continue." "$blockers"
    return 1
  fi

  # Planning is decided before the machine's state picks an action: plan only
  # ever reviews and saves choices, whatever state the install is in.
  if [ "$mode" = plan ]; then
    lx_plan
    return
  fi

  case "$LX_OMARCHY_STATE" in
    installed)
      lx_installed
      return
      ;;
    in-progress)
      lx_in_progress
      return
      ;;
    partial)
      ui_callout warn "Omarchy's package is present but the install did not finish." \
        "omarchy-mac-setup reads the machine and redoes only the unfinished steps; running it again is the upstream-supported path."
      ;;
  esac

  if [ "$OMB_UID" != 0 ]; then
    if [ "$OMB_DRY_RUN" = 1 ]; then
      ui_warn "Not root: a real run must be started as root (Asahi Alarm: $ASAHI_ALARM_FIRST_LOGIN). Continuing the preview."
    else
      ui_fail "omarchy-mac-setup must run as root. On a fresh Asahi Alarm system, log in as $ASAHI_ALARM_FIRST_LOGIN and run this again."
      return 1
    fi
  fi

  if [ "$LX_ROUTE" = 0 ] || [ "$LX_ONLINE" = 0 ]; then
    lx_network || {
      ui_fail "Still offline. Connect, then run ./omarchy-bootstrap again."
      return 1
    }
  fi

  lx_choices || {
    printf '\n'
    ui_info "Stopped. Nothing changed."
    return 0
  }
  cfg_save
  lx_handoff
}
