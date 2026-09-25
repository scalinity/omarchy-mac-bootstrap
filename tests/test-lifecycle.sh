#!/usr/bin/env bash
# Where an install stands, read from the machine: every interruption point
# of the Asahi installer on macOS, what the tool says after the installer
# returns (whatever its exit status), and Omarchy Mac's setup and encryption
# states on Linux. Unknown must stop, never read as "probably done".
# shellcheck disable=SC2015,SC2016,SC2086 # ok/fail always return 0; literal $ in single quotes; rows split on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-lifecycle"
t_load
LC_STATE=$(t_tmp)

# --- macOS: classification of every interruption point -----------------------------
if t_plutil "Asahi interruption classification"; then
  OMB_STATE_DIR=$LC_STATE
  state_init
  state_set asahi_prelaunch_macos_size 994610155520
  for pair in \
    mac-m1pro-1tb-roomy:none \
    mac-asahi-resized-only:resized-only \
    mac-asahi-stub-only:early-partial \
    mac-asahi-no-root:partitioned-incomplete \
    mac-asahi-unprepared:first-stage-incomplete \
    mac-asahi-files-missing:first-stage-incomplete \
    mac-asahi-pending:pending-first-boot \
    mac-asahi-complete:installed \
    mac-asahi-installed:installed-unverified \
    mac-asahi-two-stubs:unknown \
    mac-geo-multi-apfs:none \
    mac-geo-missing-offset:unknown; do
    OMB_FIXTURE="$FIX/${pair%%:*}"
    mac_detect
    asahi_classify
    assert_eq "$ASAHI_STATE" "${pair#*:}" "classify ${pair%%:*}"
  done
  # Without a recorded launch, a free gap is just free space.
  state_unset asahi_prelaunch_macos_size
  for fx in mac-asahi-resized-only mac-m1-free-space; do
    OMB_FIXTURE="$FIX/$fx"
    mac_detect
    asahi_classify
    assert_eq "$ASAHI_STATE" none "with no recorded launch, $fx is ordinary free space"
  done
  unset OMB_FIXTURE
fi

# --- macOS: the guided flow in each state --------------------------------------------
if t_plutil "the guided flow in each Asahi state"; then
  for fx in mac-asahi-stub-only mac-asahi-no-root mac-asahi-unprepared mac-asahi-files-missing; do
    t_cli "$fx" '\n\n\n\n\n\n\n\n\n\n\n\n\nyes\n\nlaunch\n'
    flat=$(t_flat "$T_OUT")
    assert_rc "$T_RC" 1 "$fx: an interrupted first stage stops"
    assert_contains "$flat" "stopped before finishing its first stage" "$fx: says so"
    assert_contains "$flat" "repair option ('p') refuses this case" "$fx: does not recommend 'p'"
    assert_contains "$flat" "never deletes partitions" "$fx: removes nothing"
    assert_not_contains "$T_OUT" "How much storage" "$fx: no second install is planned"
    assert_empty_file "$T_DIR/record" "$fx: nothing runs"
  done
  t_cli mac-asahi-pending ''
  assert_rc "$T_RC" 0 "pending first boot: a clear next step"
  assert_contains "$(t_flat "$T_OUT")" "first stage is complete" "pending: says the first stage finished"
  assert_contains "$T_OUT" "Press and HOLD the power button" "pending: shows the boot steps"
  t_cli mac-asahi-complete ''
  assert_contains "$(t_flat "$T_OUT")" "Phase 1 is complete" "installed: Phase 1 is complete"
  t_cli mac-asahi-installed ''
  assert_contains "$(t_flat "$T_OUT")" "cannot tell whether the new OS has finished its first boot" "unverified: says what cannot be read"
  assert_contains "$(t_flat "$T_OUT")" "offers 'p' (repair) only when its first stage finished" "unverified: repair is conditional"
  t_cli mac-asahi-two-stubs ''
  assert_rc "$T_RC" 1 "unknown: stops"
  assert_contains "$(t_flat "$T_OUT")" "cannot tell what state the Asahi install is in" "unknown: explains, and stops"
  assert_empty_file "$T_DIR/record" "unknown: nothing runs"

  # Resized, then quit: the resize stays, and the plan installs into the gap.
  pre=$(t_tmp)
  printf 'asahi_prelaunch_macos_size=994610155520\nasahi_launched_at=2026-09-25T00:00:00Z\n' >"$pre/state.env"
  chmod 600 "$pre/state.env"
  T_ENV="OMB_STATE_DIR=$pre" t_cli mac-asahi-resized-only '\n\n\n\n\n\n\n\n\n\n\n\n\nyes\n\nlaunch\n'
  flat=$(t_flat "$T_OUT")
  assert_contains "$flat" "Quitting the installer does not undo a resize" "resized-only: the resize is not undone by quitting"
  assert_not_contains "$T_OUT" "Resize an existing partition" "resized-only: no second resize"
  assert_contains "$T_OUT" "Install an OS into free space" "resized-only: installs into the freed space"
fi

# --- macOS: after the installer returns, the disk is read again -------------------------
if t_plutil "reading the disk after the installer"; then
  t_cli mac-m1pro-1tb-roomy '\n\n\n\n\n\n\n\n\n\n\n\n\nyes\n\nlaunch\n'
  assert_contains "$T_OUT" "read from the disk, not its exit status" "the installer's exit status is not trusted"
  assert_contains "$(t_flat "$T_OUT")" "The disk is exactly as it was" "an unchanged disk is reported as unchanged"
  assert_contains "$(cat "$T_DIR/state/state.env")" "asahi_prelaunch_macos_size=994610155520" "the layout before the launch is recorded"
  assert_contains "$(cat "$T_DIR/state/state.env")" "asahi_state=none" "the state found afterwards is recorded"
  # after BEFORE_FIXTURE AFTER_FIXTURE — the re-read sees AFTER.
  after() {
    local before out
    OMB_STATE_DIR=$LC_STATE
    state_init
    state_set asahi_prelaunch_macos_size 994610155520
    OMB_FIXTURE="$FIX/$1"
    mac_detect
    before=$(geo_canon)
    OMB_FIXTURE="$FIX/$2"
    out=$(mac_after_installer "$before" 0 2>&1)
    printf 'rc=%s %s' $? "$(t_flat "$out")"
    unset OMB_FIXTURE
  }
  out=$(after mac-m1pro-1tb-roomy mac-asahi-resized-only)
  assert_contains "$out" "rc=0" "resized, then quit: a clear next step"
  assert_contains "$out" "does not undo a resize" "resized, then quit: said plainly"
  out=$(after mac-m1pro-1tb-roomy mac-asahi-stub-only)
  assert_contains "$out" "rc=1" "stopped after the stub: stops"
  assert_contains "$out" "stopped before finishing its first stage" "stopped after the stub: said plainly"
  out=$(after mac-m1pro-1tb-roomy mac-asahi-pending)
  assert_contains "$out" "partitions are in place" "partitions created: the boot steps follow"
  out=$(after mac-m1pro-1tb-roomy mac-geo-multi-apfs)
  assert_contains "$out" "rc=1" "a change the installer does not make: stops"
  assert_contains "$out" "cannot tell what state" "a change the installer does not make: explained"
fi

# --- Linux: Omarchy Mac's setup and encryption states ----------------------------------------
for row in \
  "linux-alarm-fresh absent none 0" \
  "linux-setup-in-progress in-progress complete 0" \
  "linux-setup-active in-progress complete 0" \
  "linux-omarchy-partial partial none 0" \
  "linux-omarchy-finishing installed complete 1" \
  "linux-encrypt-staged in-progress migrating 0" \
  "linux-encrypt-reencrypting in-progress migrating 0" \
  "linux-omarchy-installed installed complete 0"; do
  set -- $row
  OMB_FIXTURE="$FIX/$1"
  OMB_UID=$(cat "$OMB_FIXTURE/cmd/id_u")
  lx_detect
  assert_eq "$LX_OMARCHY_STATE $LX_ENC_STATE $LX_SETUP_FINISHING" "$2 $3 $4" "linux state of $1"
done
# Complete means nothing of Omarchy Mac's is still changing the disk.
for row in "linux-omarchy-installed 0" "linux-omarchy-finishing 1" "linux-encrypt-reencrypting 1" "linux-setup-active 1" "linux-alarm-fresh 1"; do
  set -- $row
  OMB_FIXTURE="$FIX/$1"
  OMB_UID=$(cat "$OMB_FIXTURE/cmd/id_u")
  CFG_enc=1
  lx_detect
  lx_setup_complete
  assert_rc $? "$2" "setup complete? $1"
done
# A LUKS root read by a user without the finish marker: unverified, not complete.
fx=$(t_variant linux-omarchy-installed)
rm -f "$fx/root/var/lib/omarchy/btrfs-migrate-done"
OMB_FIXTURE=$fx OMB_UID=1000
lx_detect
assert_eq "$LX_ENC_STATE" unverified "a user cannot confirm re-encryption without the marker"
lx_setup_complete
assert_rc $? 1 "unverified encryption is not complete"
assert_contains "$LX_INCOMPLETE_WHY" "only be read as root" "and it says why"
# The display-manager unit must be a symlink, as upstream requires.
fx=$(t_variant linux-omarchy-installed)
rm -f "$fx/root/var/lib/omarchy-mac-setup/installed" "$fx/root/etc/systemd/system/display-manager.service"
: >"$fx/root/etc/systemd/system/display-manager.service"
OMB_FIXTURE=$fx
lx_detect
assert_eq "$LX_OMARCHY_STATE" partial "a plain file where display-manager.service should be a link is not an install"
unset OMB_FIXTURE

t_cli linux-encrypt-staged "" doctor
assert_contains "$T_OUT" "[WARN] Encryption" "doctor: a staged encryption is a warning"
assert_contains "$T_OUT" "not finished yet" "doctor: and says the next boot continues it"
t_cli linux-omarchy-finishing "" doctor
assert_contains "$T_OUT" "[INFO] Setup finishing" "doctor: upstream's last boot is information, not a leftover"
assert_not_contains "$T_OUT" "Setup leftovers" "doctor: no false leftover warning"
t_cli linux-omarchy-installed "" status
assert_contains "$T_OUT" "sudo /usr/local/bin/omarchy-mac-setup --status" "status as a user points to upstream's root-only view"
t_cli linux-setup-in-progress "" status
assert_not_contains "$T_OUT" "$(printf '\033')" "upstream's colour codes are removed"
t_cli linux-setup-active 'resume\n' resume
assert_contains "$T_OUT" "running right now on tty1" "active setup: never offered a second run"
assert_empty_file "$T_DIR/record" "active setup: nothing runs"

t_done test-lifecycle
