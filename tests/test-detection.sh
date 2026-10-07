#!/usr/bin/env bash
# Detection over fixtures: macOS (plist parsing needs plutil, so those cases
# run on macOS only) and Linux (runs anywhere).
# shellcheck disable=SC2015 # ok/fail always return 0
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load
echo "test-detection"
OMB_STATE_DIR=$(t_tmp)
state_init

# --- PLIST-M01: real helper, deterministic plutil transport on every platform ---
plist_test_dir=$(t_tmp)
mkdir "$plist_test_dir/bin"
cat >"$plist_test_dir/bin/plutil" <<'PLUTIL'
#!/bin/sh
printf x >>"$PLIST_HITS"
printf '%s\n' "$@" >"$PLIST_ARGS"
cat >"$PLIST_INPUT"
cat "$PLIST_VALUE"
exit "$PLIST_STATUS"
PLUTIL
chmod +x "$plist_test_dir/bin/plutil"
export PLIST_HITS=$plist_test_dir/hits PLIST_ARGS=$plist_test_dir/args
export PLIST_INPUT=$plist_test_dir/input PLIST_VALUE=$plist_test_dir/value PLIST_STATUS
printf '%s\n' -extract Test.key raw -o - - >"$plist_test_dir/want.args"
printf '%s' plist-input >"$plist_test_dir/want.input"
plist_case() {
  local name=$1 st
  PLIST_STATUS=$2
  printf '%s' "$3" >"$PLIST_VALUE"
  : >"$PLIST_HITS"
  PATH="$plist_test_dir/bin:$PATH" plist_get plist-input Test.key >"$plist_test_dir/out"
  st=$?
  assert_rc "$st" "$PLIST_STATUS" "PLIST-M01 $name: exact process status"
  assert_eq "$(cat "$PLIST_HITS")" x "PLIST-M01 $name: exactly one extraction"
  if cmp -s "$PLIST_ARGS" "$plist_test_dir/want.args"; then ok; else fail "PLIST-M01 $name: extraction arguments"; fi
  if cmp -s "$PLIST_INPUT" "$plist_test_dir/want.input"; then ok; else fail "PLIST-M01 $name: original input"; fi
  if [ "$PLIST_STATUS" = 0 ]; then
    if cmp -s "$plist_test_dir/out" "$PLIST_VALUE"; then ok; else fail "PLIST-M01 $name: successful bytes preserved"; fi
  else
    assert_empty_file "$plist_test_dir/out" "PLIST-M01 $name: no failed stdout"
  fi
  printf 'PLIST-M01 %s: status=%s hits=%s stdout-hex=' "$name" "$st" "$(cat "$PLIST_HITS")"
  od -An -tx1 "$plist_test_dir/out" | tr -d '\n'
  printf '\n'
}
plist_case diagnostic 7 '<stdin>: Could not extract value, error: no value at key path'
plist_case device-failure 9 disk9s2
plist_case integer-failure 23 12345
plist_case filesystem-failure 65 exfat
plist_case ordinary 0 disk0s2
plist_case false 0 false
plist_case zero 0 0
plist_case empty-success 0 ''
plist_case spaces-quotes-backslashes 0 '  "quoted" \\path\file  '
plist_case unicode 0 'café 雪'
plist_case multiline 0 $'first\nsecond\n\n  \t\n\n'
plist_case success-before-failure 0 $'previous value\n\n'
plist_case failure-after-success 17 $'new failure diagnostic\n'
: >"$PLIST_HITS"
PATH="$plist_test_dir/bin:$PATH" plist_get '' Test.key >"$plist_test_dir/out"
assert_rc "$?" 1 'PLIST-M01 empty input: existing failure status'
assert_empty_file "$plist_test_dir/out" 'PLIST-M01 empty input: no stdout'
assert_empty_file "$PLIST_HITS" 'PLIST-M01 empty input: no extraction'
unset PLIST_HITS PLIST_ARGS PLIST_INPUT PLIST_VALUE PLIST_STATUS
if [ "${1:-}" = --plist-helper-only ]; then
  t_done test-detection-plist
  exit "$?"
fi

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

# --- Field splitting used by menus and the device table --------------------------
_split4 "Balanced|250 GB|desc|recommended"
assert_eq "$F1/$F2/$F3/$F4" "Balanced/250 GB/desc/recommended" "four fields"
_split4 "Custom|GB or %|Any size.|"
assert_eq "$F1/$F2/$F3/$F4" "Custom/GB or %/Any size./" "empty last field"
_split4 "rust|installed"
assert_eq "$F1/$F2/$F3/$F4" "rust/installed//" "missing fields are empty"

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
mac_case() { case "$1" in /*) OMB_FIXTURE=$1 ;; *) OMB_FIXTURE="$FIX/$1" ;; esac; mac_detect; CFG_shared=0; mac_plan_compute; }

if t_plutil "macOS detection and planning"; then
  mac_case mac-m1pro-1tb-roomy
  assert_eq "$MAC_APPLE_SILICON" 1 "roomy apple silicon"
  assert_eq "$MAC_MODEL_ID $DEV_TIER" "MacBookPro18,1 supported" "roomy model"
  assert_eq "$MAC_CHIP" "Apple M1 Pro" "chip from system_profiler"
  assert_eq "$MAC_DISK $MAC_DISK_INTERNAL $MAC_STORE $MAC_CONTAINER" "disk0 true disk0s2 disk3" "boot disk derived from /"
  assert_eq "$MAC_STORE" disk0s2 'PLIST-M01 single-store: primary identity'
  assert_eq "$MAC_STORES_EXTRA" '' 'PLIST-M01 single-store: optional second store is absent'
  assert_eq "$MAC_DISK_SIZE" 1000555581440 "disk size"
  assert_eq "$MAC_CONTAINER_SIZE $MAC_CONTAINER_FREE" "994610155520 700000000000" "container size/free"
  assert_eq "$MAC_APPLE_SYS" $((576716800 + 5368664064)) "Apple system partitions"
  assert_eq "$MAC_EXISTING_FREE" 0 "no unpartitioned space"
  assert_eq "$MAC_ASAHI_PRESENT" 0 "no existing install"
  assert_eq "$MAC_LIMIT_PREF" $((994610155520 - 700000000000 + 40000000000)) "limits parsed"
  assert_eq "$MAC_FILEVAULT $MAC_ADMIN $MAC_USER" "true 1 alex" "security facts"
  assert_eq "$MAC_TZ" America/New_York "timezone from /etc/localtime"
  assert_eq "$MAC_TM_LATEST" "2026-09-20 10:15" "latest backup date"
  assert_eq "$(mac_blockers)" "" "roomy has no blockers"
  assert_eq "$PLAN_LINUX_MAX" $((654 * GB)) "roomy plan: whole GB of the one region a resize frees"
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
  assert_contains "$(mac_blockers)" "Not enough space for Linux yet: free about 39 GB more" "tight is blocked on space"
  assert_eq "$PLAN_SHORTFALL" $((39 * GB)) "tight is short of space: 54 GB needed, 15 GB possible"

  mac_case mac-m2-512
  assert_eq "$DEV_CHIP $PLAN_OVERHEAD_WARN" "M2 1" "512 GB: overhead warning"

  mac_case mac-m3pro-experimental
  assert_eq "$DEV_TIER" experimental "M3 Pro tier"
  assert_eq "$(mac_blockers)" "" "experimental is not a hard blocker"

  mac_case mac-asahi-installed
  assert_eq "$MAC_ASAHI_PRESENT" 1 "existing Asahi detected"
  roles=$(printf '%s' "$MAC_PARTS" | cut -d'|' -f4 | tr '\n' ' ')
  assert_eq "$roles" "isc macos asahi-stub efi linux recovery " "partition roles"

  # --- Geometry: exact extents from diskutil info, cross-checked -----------------
  mac_case mac-m1pro-1tb-roomy
  assert_eq "$GEO_OK $MAC_DISK_BLOCK" "1 4096" "roomy: layout read exactly, 4096-byte blocks"
  assert_eq "$(printf '%s' "$GEO_PARTS" | cut -d'|' -f1,2,5 | tr '\n' ' ')" \
    "24576|576716800|disk0s1 576741376|994610155520|disk0s2 995186896896|5368664064|disk0s3 " "roomy: offsets and sizes from diskutil info"
  assert_eq "$MAC_STORE_UUID" 4A7B1C2D-0002-4E5F-8A9B-000000000002 "the macOS store is known by its GPT GUID"
  assert_eq "$GEO_GAPS" "" "roomy: no free gap"
  mac_case mac-m1-free-space
  assert_eq "$(printf '%s' "$GEO_GAPS" | grep -c .)" 1 "free-space: one gap"
  assert_eq "$(printf '%s' "$GEO_GAPS" | cut -d'|' -f2,3)" "299999690752|4A7B1C2D-0002-4E5F-8A9B-000000000002" "free-space: 300 GB right after the container"
  mac_case mac-geo-two-gaps
  assert_eq "$(printf '%s' "$GEO_GAPS" | grep -c .)" 2 "two gaps: seen as two regions"
  [ "$PLAN_LINUX_MAX" -lt $((75 * GB)) ] && ok || fail "two gaps: Linux can have one region's worth, not 150 GB"
  assert_eq "$(mac_blockers)" "" "two gaps: 74 GB in one region is enough to plan"
  mac_case mac-geo-512-sectors
  assert_eq "$GEO_OK $MAC_DISK_BLOCK $GEO_USABLE_START" "1 512 17408" "512-byte sectors: first usable block 34"
  mac_case mac-geo-missing-offset
  assert_eq "$GEO_OK" 0 "a missing offset leaves the layout unknown"
  assert_contains "$(mac_blockers)" "could not be read exactly" "a missing offset blocks planning"
  mac_case mac-geo-disagree
  assert_contains "$(mac_blockers)" "diskutil list and diskutil info disagree" "disagreeing views block planning"
  mac_case mac-geo-multi-apfs
  assert_contains "$(mac_blockers)" "Another APFS container is on the internal disk (disk0s4)" "a second APFS container blocks planning"
  mac_case mac-geo-no-limits
  assert_eq "$MAC_LIMIT_PREF" '' 'PLIST-M01 absent limits remain unknown'
  assert_eq "$PLAN_LIMITS_KNOWN" 0 'PLIST-M01 unknown limits are not zero/usable limits'
  assert_contains "$(mac_blockers)" "did not report the resize limits of disk3" "unknown resize limits block a resize, with the reason"
  fx=$(t_variant mac-m1pro-1tb-roomy)
  sed -i.bak 's#<key>Internal</key><true/>#<key>Internal</key><false/>#' "$fx/cmd/diskutil_info_disk0s2" && rm -f "$fx/cmd/"*.bak
  mac_case "$fx"
  assert_contains "$(mac_blockers)" "not on an internal disk" "an external boot volume blocks planning"
  fx=$(t_variant mac-m1pro-1tb-roomy)
  sed -i.bak 's#</array><key>Internal</key>#<dict><key>APFSPhysicalStore</key><string>disk4s2</string></dict></array><key>Internal</key>#' "$fx/cmd/diskutil_info_root" && rm -f "$fx/cmd/"*.bak
  mac_case "$fx"
  assert_eq "$MAC_STORE" disk0s2 'PLIST-M01 true two-store: primary identity'
  assert_eq "$MAC_STORES_EXTRA" disk4s2 'PLIST-M01 true two-store: actual second identity'
  assert_contains "$(mac_blockers)" "more than one physical store" "a multi-store container blocks planning"

  # Native extraction except one status-controlled failure, through the real
  # helper. Plausible stdout must never satisfy required downstream fields.
  plist_native_dir=$(t_tmp)
  mkdir "$plist_native_dir/bin"
  export PLIST_NATIVE
  PLIST_NATIVE=$(command -v plutil)
  cat >"$plist_native_dir/bin/plutil" <<'PLUTIL'
#!/bin/sh
if [ "$2" = "$PLIST_FAIL_KEY" ]; then
  cat >/dev/null
  printf '%s' "$PLIST_FAIL_VALUE"
  exit 31
fi
exec "$PLIST_NATIVE" "$@"
PLUTIL
  chmod +x "$plist_native_dir/bin/plutil"
  export PLIST_FAIL_KEY PLIST_FAIL_VALUE
  PLIST_FAIL_KEY=APFSPhysicalStores.0.APFSPhysicalStore PLIST_FAIL_VALUE=disk9s2
  PATH="$plist_native_dir/bin:$PATH" mac_case mac-m1pro-1tb-roomy
  assert_eq "$MAC_STORE" '' 'PLIST-M01 required first store failure is not device data'
  assert_eq "$GEO_OK" 0 'PLIST-M01 missing first store blocks exact geometry'
  for key in Size DeviceBlockSize AllDisksAndPartitions.0.Partitions.0.DeviceIdentifier \
    PartitionMapPartitionOffset AllDisksAndPartitions.0.Partitions.0.Size \
    AllDisksAndPartitions.0.Partitions.0.DiskUUID; do
    PLIST_FAIL_KEY=$key PLIST_FAIL_VALUE=12345
    PATH="$plist_native_dir/bin:$PATH" mac_case mac-m1pro-1tb-roomy
    assert_eq "$GEO_OK" 0 "PLIST-M01 required $key failure blocks geometry"
    assert_contains "$(mac_blockers)" 'could not be read exactly' "PLIST-M01 required $key: existing owner blocks"
  done
  PLIST_FAIL_KEY=AllDisksAndPartitions.0.Partitions.3.Content PLIST_FAIL_VALUE='phantom partition'
  PATH="$plist_native_dir/bin:$PATH" mac_case mac-m1pro-1tb-roomy
  assert_eq "$GEO_OK" 1 'PLIST-M01 failed terminal enumeration stays at the true boundary'
  assert_eq "$(printf '%s' "$MAC_PARTS" | grep -c .)" 3 'PLIST-M01 no phantom partition from failed stdout'
  PLIST_FAIL_KEY=AllDisksAndPartitions.0.Partitions.1.Content
  PATH="$plist_native_dir/bin:$PATH" mac_case mac-m1pro-1tb-roomy
  assert_eq "$GEO_OK" 0 'PLIST-M01 missing interior Content fails completeness'
  assert_contains "$GEO_ERR" '3 partitions' 'PLIST-M01 real count catches an early enumeration end'
  PLIST_FAIL_KEY=MinimumSizePreferred PLIST_FAIL_VALUE=0
  PATH="$plist_native_dir/bin:$PATH" mac_case mac-m1pro-1tb-roomy
  assert_eq "$MAC_LIMIT_PREF/$PLAN_LIMITS_KNOWN" '/0' 'PLIST-M01 failed limit does not become known zero'
  assert_contains "$(mac_blockers)" 'did not report the resize limits' 'PLIST-M01 resize requiring unknown authority is blocked'
  PATH="$plist_native_dir/bin:$PATH" mac_case mac-m1-free-space
  assert_eq "$MAC_LIMIT_PREF/$PLAN_LIMITS_KNOWN" '/0' 'PLIST-M01 verified gap keeps resize unknown'
  assert_eq "$(mac_blockers)" '' 'PLIST-M01 verified existing gap remains usable'
  [ "$PLAN_LINUX_MAX" -gt 0 ] && ok || fail 'PLIST-M01 existing gap is still planned'
  unset PLIST_NATIVE PLIST_FAIL_KEY PLIST_FAIL_VALUE

  # Through the real entrypoint (set -u): an unreadable layout stops with
  # its reason instead of failing on an unset variable.
  for fx in mac-geo-missing-offset mac-geo-disagree; do
    t_cli "$fx" "\n\n"
    assert_rc "$T_RC" 1 "$fx stops"
    assert_contains "$T_OUT" "could not be read exactly" "$fx says why"
    assert_not_contains "$T_OUT" "unbound variable" "$fx does not crash"
  done

  # The resize-limits query refuses anything that is not a disk identifier.
  mac_resize_limits 'disk3; rm -rf /' >/dev/null
  assert_rc $? 1 "limits query rejects injected text"
  mac_resize_limits '' >/dev/null
  assert_rc $? 1 "limits query rejects empty"
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

# --- Developer core tools: one package query per check --------------------------------
OMB_FIXTURE="$FIX/linux-omarchy-installed"
probe_count=0
eval "orig_$(declare -f sys_cmd)"
sys_cmd() {
  [ "$1" = pacman_qq ] && printf 'x\n' >>"$OMB_STATE_DIR/qq-calls"
  orig_sys_cmd "$@"
}
: >"$OMB_STATE_DIR/qq-calls"
assert_eq "$(dev_core_missing)" "github-cli wget tree rsync" "missing core packages"
probe_count=$(wc -l <"$OMB_STATE_DIR/qq-calls" | tr -d ' ')
assert_eq "$probe_count" 1 "pacman -Qq runs once per check, not once per package"
eval "$(declare -f orig_sys_cmd | sed '1s/orig_sys_cmd/sys_cmd/')"

# --- Command construction for the Omarchy handoff ------------------------------
CFG_enc=1 CFG_user=alex CFG_host=m1pro CFG_kmap=uk
lx_setup_flags
assert_eq "${LX_FLAGS[*]}" "--encrypt --user alex --hostname m1pro --keymap uk" "setup flags, encrypted"
CFG_enc=0
lx_setup_flags
assert_eq "${LX_FLAGS[*]}" "--no-encrypt --user alex --hostname m1pro --keymap uk" "setup flags, not encrypted"

t_done test-detection
