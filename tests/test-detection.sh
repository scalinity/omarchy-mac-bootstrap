#!/usr/bin/env bash
# Detection over fixtures: macOS (plist parsing needs plutil, so those cases
# run on macOS only) and Linux (runs anywhere).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load
echo "test-detection"
OMB_STATE_DIR=$(t_tmp)
state_init

# --- Device table ------------------------------------------------------------
device_by_model MacBookPro18,1
assert_eq "$DEV_BOARD $DEV_SOC $DEV_CHIP $DEV_TIER" "j316s t6000 M1 Pro supported" "M1 Pro 16-inch"
assert_eq "$DEV_NAME" "MacBook Pro (16-inch, M1 Pro, 2021)" "marketing name"
device_by_model Mac14,2
assert_eq "$DEV_CHIP $DEV_TIER" "M2 supported" "M2 Air"
device_by_model Mac15,6
assert_eq "$DEV_CHIP $DEV_TIER" "M3 Pro experimental" "M3 Pro is experimental"
device_by_model Mac16,1
assert_eq "$DEV_CHIP $DEV_TIER" "M4 unsupported" "M4 unsupported"
device_by_model Mac17,8
assert_rc $? 1 "unknown model"
assert_eq "$DEV_TIER" unsupported "unknown model is unsupported"
device_by_board j414c
assert_eq "$DEV_MODEL $DEV_CHIP" "Mac14,5 M2 Max" "board lookup"

# --- Setup flag check -----------------------------------------------------------
hdr='# omarchy:args=[--encrypt|--no-encrypt] [--user <name>] [--hostname <name>] [--keymap <name>] [--repo <owner/repo>] [--status] [--resume] [--abort]'
assert_eq "$(setup_missing_flags "$hdr")" "" "all flags declared"
assert_eq "$(setup_missing_flags '# omarchy:args=[--encrypt|--no-encrypt] [--user <name>] [--hostname <name>] [--status] [--resume]')" " --keymap" "missing --keymap detected"
assert_eq "$(setup_missing_flags 'nothing here')" " --encrypt --no-encrypt --user --hostname --keymap --status --resume" "no header: everything missing"
script=$OMB_STATE_DIR/setup-probe
for shebang in '#!/bin/bash' '#!/usr/bin/env bash'; do
  printf '%s\n%s\n' "$shebang" "$hdr" >"$script"
  setup_script_ok "$script"
  assert_rc $? 0 "setup script accepted with $shebang"
done
printf '#!/bin/sh\n%s\n' "$hdr" >"$script"
setup_script_ok "$script"
assert_rc $? 1 "a non-bash setup script is refused"
printf '<html>404</html>\n' >"$script"
setup_script_ok "$script"
assert_rc $? 1 "an HTML page is refused"
renamed='# omarchy:args=[--encrypt|--no-encrypt] [--username <name>] [--hostname <name>] [--keymap-layout <name>] [--status] [--resume-from <x>]'
assert_eq "$(setup_missing_flags "$renamed")" " --user --keymap --resume" "renamed flags do not satisfy the originals"

# --- macOS -------------------------------------------------------------------
mac_case() { OMB_FIXTURE="$FIX/$1"; mac_detect; CFG_shared=0; mac_plan_compute; }

if command -v plutil >/dev/null 2>&1; then
  mac_case mac-m1pro-1tb-roomy
  assert_eq "$MAC_APPLE_SILICON" 1 "roomy apple silicon"
  assert_eq "$MAC_MODEL_ID $DEV_TIER" "MacBookPro18,1 supported" "roomy model"
  assert_eq "$MAC_CHIP" "Apple M1 Pro" "chip from system_profiler"
  assert_eq "$MAC_DISK $MAC_DISK_INTERNAL $MAC_STORE $MAC_CONTAINER" "disk0 true disk0s2 disk3" "boot disk derived from /"
  assert_eq "$MAC_DISK_SIZE" 1000555581440 "disk size"
  assert_eq "$MAC_CONTAINER_SIZE $MAC_CONTAINER_FREE" "994662543360 700000000000" "container size/free"
  assert_eq "$MAC_APPLE_SYS" $((524288000 + 5368709120)) "Apple system partitions"
  assert_eq "$MAC_EXISTING_FREE" 0 "no unpartitioned space"
  assert_eq "$MAC_ASAHI_PRESENT" 0 "no existing install"
  assert_eq "$MAC_LIMIT_PREF" $((994662543360 - 700000000000 + 40000000000)) "limits parsed"
  assert_eq "$MAC_FILEVAULT $MAC_ADMIN $MAC_USER" "true 1 alex" "security facts"
  assert_eq "$MAC_TZ" America/New_York "timezone from /etc/localtime"
  assert_eq "$MAC_TM_LATEST" "2026-09-20 10:15" "latest backup date"
  assert_eq "$(mac_blockers)" "" "roomy has no blockers"
  assert_eq "$PLAN_LINUX_MAX" $((655 * GB)) "roomy plan"
  assert_eq "$(mac_default_keymap)" us "US layout → us"
  assert_eq "$(mac_default_locale)" en_US.UTF-8 "en_US → en_US.UTF-8"
  MAC_KEYBOARD=com.apple.keylayout.German
  assert_eq "$(mac_default_keymap)" de "German layout → de"
  MAC_LOCALE="de_DE@rg=chzzzz"
  assert_eq "$(mac_default_locale)" de_DE.UTF-8 "region suffix stripped"

  mac_case mac-intel
  assert_eq "$MAC_APPLE_SILICON" 0 "intel is not apple silicon"
  assert_contains "$(mac_blockers)" "not Apple Silicon" "intel blocked"

  mac_case mac-m1pro-1tb-tight
  assert_eq "$(mac_blockers)" "" "tight has no hardware blocker"
  assert_eq "$PLAN_SHORTFALL" $((34 * GB)) "tight is short of space"

  mac_case mac-m2-512
  assert_eq "$DEV_CHIP $PLAN_OVERHEAD_WARN" "M2 1" "512 GB: overhead warning"

  mac_case mac-m3pro-experimental
  assert_eq "$DEV_TIER" experimental "M3 Pro tier"
  assert_eq "$(mac_blockers)" "" "experimental is not a hard blocker"

  mac_case mac-asahi-installed
  assert_eq "$MAC_ASAHI_PRESENT" 1 "existing Asahi detected"
  roles=$(printf '%s' "$MAC_PARTS" | cut -d'|' -f4 | tr '\n' ' ')
  assert_eq "$roles" "system macos asahi-stub efi linux system " "partition roles"

  # The resize-limits query refuses anything that is not a disk identifier.
  mac_resize_limits 'disk3; rm -rf /' >/dev/null
  assert_rc $? 1 "limits query rejects injected text"
  mac_resize_limits '' >/dev/null
  assert_rc $? 1 "limits query rejects empty"
else
  skip "macOS detection (plutil not available on this host)"
fi

# --- Linux -------------------------------------------------------------------
lx_case() { OMB_FIXTURE="$FIX/$1"; lx_detect; }

lx_case linux-alarm-fresh
assert_eq "$LX_ARCH $LX_APPLE $LX_BOARD $LX_SOC" "aarch64 1 j316s t6000" "device tree"
assert_eq "$DEV_CHIP $DEV_TIER" "M1 Pro supported" "board → chip"
assert_eq "$LX_DT_MODEL" "Apple MacBook Pro (16-inch, M1 Pro, 2021)" "device-tree model without NUL"
assert_eq "$LX_OS_ID" archarm "os-release parsed, not sourced"
lx_is_arch
assert_rc $? 0 "Arch detected"
assert_eq "$LX_ROOT_SRC $LX_ROOT_FS" "/dev/nvme0n1p6 btrfs" "subvolume suffix stripped"
assert_eq "$LX_BOOT_SRC" "" "no separate /boot"
assert_eq "$LX_ROOT_CRYPT $LX_ROUTE" "0 1" "plain root, online"
assert_eq "$LX_OMARCHY_STATE" absent "fresh: no Omarchy"
assert_eq "$LX_KEYMAP" us "vconsole keymap"
assert_eq "$(lx_blockers)" "" "fresh has no blockers"

lx_case linux-alarm-offline
assert_eq "$LX_ROUTE" 0 "offline: no default route"

lx_case linux-setup-in-progress
assert_eq "$LX_OMARCHY_STATE $LX_SETUP_CONF $LX_SETUP_BIN" "in-progress 1 1" "in-progress detected from upstream conf"
assert_eq "$LX_ROOT_CRYPT $LX_BOOT_SRC" "1 /dev/nvme0n1p5" "encrypted with separate /boot"
assert_eq "$LX_UNIT_STATE" inactive "unit idle"

lx_case linux-omarchy-installed
assert_eq "$LX_OMARCHY_STATE $LX_OMARCHY_VERSION" "installed 4.0.3rc4" "installed from upstream marker"
assert_eq "$LX_PAGESIZE" 16384 "page size"

# --- Command construction for the Omarchy handoff ------------------------------
CFG_enc=1 CFG_user=alex CFG_host=m1pro CFG_kmap=uk
lx_setup_flags
assert_eq "${LX_FLAGS[*]}" "--encrypt --user alex --hostname m1pro --keymap uk" "setup flags, encrypted"
CFG_enc=0
lx_setup_flags
assert_eq "${LX_FLAGS[*]}" "--no-encrypt --user alex --hostname m1pro --keymap uk" "setup flags, not encrypted"

t_done test-detection
