# shellcheck shell=bash
# Where an Asahi install stands, read from macOS. The installer exits 0
# whether it finished, was quit, or hit an error, so the disk is the only
# evidence (asahi-installer v0.9.2):
#   - it creates the stub APFS container and fills it first, then the EFI
#     partition, then the Linux root, then writes boot.bin into the stub
#     (main.py action_install_into_free, osinstall.py partition_disk);
#   - its repair option needs the stub's system volume to hold step2.sh,
#     boot.bin, .IAPhysicalMedia (or IAPhysicalMedia-disabled.plist) and
#     SystemVersion.plist (or SystemVersion-disabled.plist) (stub.py
#     check_existing_install), and refuses otherwise;
#   - the first boot's step 2 renames .IAPhysicalMedia to
#     IAPhysicalMedia-disabled.plist and restores SystemVersion.plist.
# Nothing here mounts, repairs or deletes anything: the stub's files are read
# only when macOS already has its system volume mounted.

ASAHI_STUB_APP="Finish Installation.app/Contents/Resources"

# asahi_classify — after mac_detect. Sets ASAHI_STATE, ASAHI_WHY and the
# GUIDs ASAHI_STUB_UUID / ASAHI_EFI_UUID / ASAHI_ROOT_UUID:
#   none                    no Asahi partitions
#   resized-only            macOS smaller than before the recorded launch, no stub
#   early-partial           a stub container, nothing after it
#   partitioned-incomplete  stub and EFI, no Linux root
#   first-stage-incomplete  all three, but the stub lacks what repair needs
#   pending-first-boot      first stage complete; step 2 has not run
#   installed               step 2 has run
#   installed-unverified    all three, in order; the stub is not readable here
#   unknown                 anything else
asahi_classify() {
  local stubs efis roots n_stub n_efi n_root before
  ASAHI_STATE=unknown ASAHI_WHY="" ASAHI_STUB_UUID="" ASAHI_EFI_UUID="" ASAHI_ROOT_UUID="" ASAHI_STUB_ID=""
  if [ "$GEO_OK" != 1 ]; then
    ASAHI_WHY="the partition layout could not be read exactly (${GEO_ERR:-unknown})"
    return 0
  fi
  stubs=$(geo_role_uuids asahi-stub)
  efis=$(geo_role_uuids efi)
  roots=$(geo_role_uuids linux)
  n_stub=$(printf '%s' "$stubs" | grep -c .)
  n_efi=$(printf '%s' "$efis" | grep -c .)
  n_root=$(printf '%s' "$roots" | grep -c .)
  if [ "$n_stub$n_efi$n_root" = 000 ]; then
    before=$(state_get asahi_prelaunch_macos_size)
    # A resize, and only a resize: the container shrank and what it gave up
    # is free space right after it.
    if _uint "$before" && geo_part "$MAC_STORE_UUID" && [ "$GP_SIZE" -lt "$before" ] &&
      geo_gap_after "$MAC_STORE_UUID" && [ "$GG_SIZE" -ge $((before - GP_SIZE)) ]; then
      geo_part "$MAC_STORE_UUID"
      ASAHI_STATE=resized-only
      ASAHI_WHY="macOS is $(fmt_gb "$GP_SIZE") now; it was $(fmt_gb "$before") before the installer ran"
    else
      ASAHI_STATE=none
    fi
    return 0
  fi
  if [ "$n_stub" != 1 ] || [ "$n_efi" -gt 1 ] || [ "$n_root" -gt 1 ]; then
    ASAHI_WHY="the disk has $n_stub stub container(s), $n_efi EFI partition(s) and $n_root Linux partition(s); one install has exactly one of each"
    return 0
  fi
  ASAHI_STUB_UUID=$stubs
  geo_part "$ASAHI_STUB_UUID"
  ASAHI_STUB_ID=$GP_ID
  if ! geo_next "$ASAHI_STUB_UUID" || [ "$GN_ROLE" != efi ]; then
    if [ "$n_efi$n_root" = 00 ]; then
      ASAHI_STATE=early-partial
      ASAHI_WHY="a stub container ($ASAHI_STUB_ID) exists, but no EFI or Linux partition was created"
    else
      ASAHI_WHY="the partition after the stub container is not its EFI partition"
    fi
    return 0
  fi
  ASAHI_EFI_UUID=$GN_UUID
  if ! geo_next "$ASAHI_EFI_UUID" || [ "$GN_ROLE" != linux ]; then
    if [ "$n_root" = 0 ]; then
      ASAHI_STATE=partitioned-incomplete
      ASAHI_WHY="the stub and EFI partitions exist, but no Linux partition was created"
    else
      ASAHI_WHY="the partition after the EFI partition is not the Linux root"
    fi
    return 0
  fi
  ASAHI_ROOT_UUID=$GN_UUID
  asahi_stub_evidence
}

# asahi_stub_evidence — all three partitions are in place; what does the stub
# hold? Uses `diskutil apfs list -plist` for its volumes and reads files only
# from a system volume macOS has already mounted.
asahi_stub_evidence() {
  local list i store j role vol nvol=0 sysvol="" mp info
  list=$(sys_cmd diskutil_apfs_list diskutil apfs list -plist)
  i=0
  while store=$(plist_get "$list" "Containers.$i.DesignatedPhysicalStore"); do
    if [ "$store" = "$ASAHI_STUB_ID" ]; then
      j=0
      while vol=$(plist_get "$list" "Containers.$i.Volumes.$j.DeviceIdentifier"); do
        nvol=$((nvol + 1))
        role=$(plist_get "$list" "Containers.$i.Volumes.$j.Roles.0")
        [ "$role" = System ] && sysvol=$vol
        j=$((j + 1))
      done
      break
    fi
    i=$((i + 1))
  done
  if [ -n "$list" ] && [ "$nvol" -gt 0 ] && [ "$nvol" -lt 4 ]; then
    ASAHI_STATE=first-stage-incomplete
    ASAHI_WHY="the stub container holds $nvol volume(s); a prepared stub has four (System, Data, Preboot, Recovery)"
    return 0
  fi
  mp=""
  case "$sysvol" in
    disk[0-9]*s[0-9]*)
      case "$sysvol" in *[!a-z0-9]*) ;; *)
        info=$(sys_cmd "diskutil_info_$sysvol" diskutil info -plist "$sysvol")
        mp=$(plist_get "$info" MountPoint)
        ;;
      esac
      ;;
  esac
  if [ -z "$mp" ] || [ ! -d "$(sys_path "$mp")" ]; then
    ASAHI_STATE=installed-unverified
    ASAHI_WHY="the stub's system volume is not mounted, so whether the first boot finished cannot be read from macOS"
    return 0
  fi
  local root step2=0 bootbin=0 iap_pending=0 iap_done=0 sv_done=0 sv_pending=0
  root=$(sys_path "$mp")
  [ -f "$root/$ASAHI_STUB_APP/step2.sh" ] && step2=1
  [ -f "$root/$ASAHI_STUB_APP/boot.bin" ] && bootbin=1
  [ -e "$root/.IAPhysicalMedia" ] && iap_pending=1
  [ -e "$root/IAPhysicalMedia-disabled.plist" ] && iap_done=1
  [ -f "$root/System/Library/CoreServices/SystemVersion.plist" ] && sv_done=1
  [ -f "$root/System/Library/CoreServices/SystemVersion-disabled.plist" ] && sv_pending=1
  if [ "$step2$bootbin" != 11 ] || [ "$iap_pending$iap_done" = 00 ] || [ "$sv_done$sv_pending" = 00 ]; then
    local missing=""
    [ "$bootbin" = 0 ] && missing="$missing, boot.bin"
    [ "$step2" = 0 ] && missing="$missing, step2.sh"
    [ "$iap_pending$iap_done" = 00 ] && missing="$missing, the install-media marker"
    [ "$sv_done$sv_pending" = 00 ] && missing="$missing, SystemVersion.plist"
    ASAHI_STATE=first-stage-incomplete
    ASAHI_WHY="the stub lacks files the installer's first stage writes: ${missing#, }"
  elif [ "$iap_done" = 1 ] && [ "$sv_done" = 1 ]; then
    ASAHI_STATE=installed
    ASAHI_WHY="the first boot's step 2 has run"
  elif [ "$iap_pending" = 1 ] && [ "$sv_pending" = 1 ]; then
    ASAHI_STATE=pending-first-boot
    ASAHI_WHY="the first stage is complete; the first boot (step 2 in macOS Recovery) has not run yet"
  else
    ASAHI_WHY="the stub's files are half way between the first stage and step 2"
  fi
  return 0
}

# asahi_partitions_table — the partitions this tool would talk about.
asahi_partitions_table() {
  local id content size role uuid label
  printf '\n   %sPartitions on %s, in disk order%s\n' "$C_DIM" "$MAC_DISK" "$C_RESET"
  while IFS='|' read -r id content size role uuid label; do
    [ -n "$id" ] || continue
    _p '     %-10s %-22s %10s  %s%s%s\n' "$id" "$content" "$(fmt_gb "$size")" "$C_DIM" "$role" "$C_RESET"
  done <<EOF
$(printf '%s' "$GEO_PARTS" | awk -F'|' '{print $5 "|" $4 "|" $2 "|" $6}')
EOF
}

# asahi_guidance — what to do from here, for the current ASAHI_STATE. Returns
# 1 when the install cannot be continued without the person deciding.
asahi_guidance() {
  local fix7=""
  ver_ge "${MAC_OS_VERSION:-0}" 27 && fix7="If the new OS vanished from Startup Options after a macOS 27 upgrade, rerun the Asahi Alarm installer and choose 7, Fix macOS 27 boot picker compatibility."
  case "$ASAHI_STATE" in
    installed)
      ui_callout info "Phase 1 is complete on $MAC_DISK: the new OS has finished its first boot." \
        "Hold the power button at startup to choose it. This tool will not start a second install."
      [ -n "$fix7" ] && ui_callout_body info "$fix7"
      return 0
      ;;
    pending-first-boot)
      ui_callout info "The installer's first stage is complete on $MAC_DISK." \
        "The new OS has not finished its first boot yet. Shut down, then follow the boot steps below: the first boot completes the install in macOS Recovery (step 2)."
      [ -n "$fix7" ] && ui_callout_body info "$fix7"
      mac_reboot_guide
      return 0
      ;;
    installed-unverified)
      ui_callout info "Asahi's stub, EFI and Linux partitions are all in place on $MAC_DISK." \
        "From macOS this tool cannot tell whether the new OS has finished its first boot ($ASAHI_WHY). If it is not in Startup Options yet, follow the boot steps below." \
        "If choosing it does not reach the \"Asahi Linux installer\" screen, rerun the installer: it offers 'p' (repair) only when its first stage finished, and says \"The existing installation is missing files\" when it did not. docs/RECOVERY.md covers both. This tool will not start a second install beside them."
      [ -n "$fix7" ] && ui_callout_body info "$fix7"
      mac_reboot_guide
      return 0
      ;;
    early-partial | partitioned-incomplete | first-stage-incomplete)
      ui_callout fail "The Asahi installer stopped before finishing its first stage." \
        "$ASAHI_WHY." \
        "Its repair option ('p') refuses this case: it asks for the partitions it created to be removed by hand and the install started again. docs/RECOVERY.md lists the exact steps from the Asahi partitioning cheatsheet. This tool never deletes partitions, and will not start a second install beside these."
      asahi_partitions_table
      return 1
      ;;
    resized-only)
      ui_callout info "macOS was resized, but no Linux partitions exist yet." \
        "$ASAHI_WHY. Quitting the installer does not undo a resize: the freed space stays unpartitioned, and the plan below installs into it (the installer's 'f', no second resize)."
      return 0
      ;;
    none) return 0 ;;
    *)
      ui_callout fail "This tool cannot tell what state the Asahi install is in, so it stops." \
        "$ASAHI_WHY." \
        "Nothing was changed. Compare the partitions below with docs/RECOVERY.md before running any installer."
      asahi_partitions_table
      return 1
      ;;
  esac
}
