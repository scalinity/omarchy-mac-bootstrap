#!/usr/bin/env bash
# Regenerates every fixture directory. All values are synthetic; the plist
# shapes match `system_profiler -xml` and `diskutil ... -plist` output.
#
#   fixture/cmd/NAME        stdout of a probe (NAME.rc: its exit code)
#   fixture/root/PATH       a file the Linux detectors read
#   fixture/net/KEY         a download or text resource (KEY.reachable: HEAD ok)
#   fixture/commands        commands that "exist" on the machine
set -eu
cd "$(dirname "$0")"

GB=1000000000
ISC=524288000
RECOVERY=5368709120

plist() {
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  printf '<plist version="1.0">\n%s\n</plist>\n' "$1"
}
part() { printf '<dict><key>Content</key><string>%s</string><key>DeviceIdentifier</key><string>%s</string><key>Size</key><integer>%s</integer></dict>' "$1" "$2" "$3"; }
put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }

# mac NAME MODEL CHIP ARCH ARM64 MACOS DISK CONTAINER FREE PREF PARTS [MEM]
mac() {
  local d=$1 model=$2 chip=$3 arch=$4 arm64=$5 macos=$6 disk=$7 container=$8 free=$9 pref=${10} parts=${11} mem=${12:-17179869184}
  rm -rf "$d"
  mkdir -p "$d/cmd" "$d/net"
  put "$d/cmd/uname_s" Darwin
  put "$d/cmd/uname_m" "$arch"
  put "$d/cmd/id_u" 501
  put "$d/cmd/id_un" alex
  put "$d/cmd/id_groups" "staff everyone localaccounts admin"
  if [ "$arm64" = 1 ]; then put "$d/cmd/sysctl_arm64" 1; else put "$d/cmd/sysctl_arm64" ""; put "$d/cmd/sysctl_arm64.rc" 1; fi
  put "$d/cmd/sysctl_hw_model" "$model"
  put "$d/cmd/sysctl_memsize" "$mem"
  put "$d/cmd/sysctl_cpu_brand" "$chip"
  put "$d/cmd/sw_vers" "$macos"
  put "$d/cmd/fdesetup_isactive" true
  put "$d/cmd/localtime" /var/db/timezone/zoneinfo/America/New_York
  put "$d/cmd/apple_locale" en_US
  put "$d/cmd/keyboard_layout" com.apple.keylayout.US
  put "$d/cmd/tmutil_destinations" "Name          : Backup Disk
Kind          : Local"
  put "$d/cmd/tmutil_latest" "/Volumes/Backup Disk/Backups.backupdb/Mac/2026-09-20-101500"
  put "$d/cmd/git_origin" "https://github.com/example/omarchy-mac-bootstrap.git"
  put "$d/cmd/git_branch" main
  local chipkey=chip_type
  [ "$arm64" = 1 ] || chipkey=cpu_type
  plist "<array><dict><key>_items</key><array><dict><key>machine_name</key><string>MacBook Pro</string><key>machine_model</key><string>$model</string><key>$chipkey</key><string>$chip</string><key>physical_memory</key><string>$((mem / 1073741824)) GB</string></dict></array></dict></array>" >"$d/cmd/hardware_plist"
  plist "<dict><key>VolumeName</key><string>Macintosh HD</string><key>APFSContainerReference</key><string>disk3</string><key>APFSContainerSize</key><integer>$container</integer><key>APFSContainerFree</key><integer>$free</integer><key>APFSPhysicalStores</key><array><dict><key>APFSPhysicalStore</key><string>disk0s2</string></dict></array><key>Internal</key><true/></dict>" >"$d/cmd/diskutil_info_root"
  plist "<dict><key>DeviceIdentifier</key><string>disk0s2</string><key>ParentWholeDisk</key><string>disk0</string><key>Internal</key><true/></dict>" >"$d/cmd/diskutil_info_disk0s2"
  plist "<dict><key>DeviceIdentifier</key><string>disk0</string><key>SMARTStatus</key><string>Verified</string><key>Internal</key><true/></dict>" >"$d/cmd/diskutil_info_disk0"
  plist "<dict><key>AllDisksAndPartitions</key><array><dict><key>Content</key><string>GUID_partition_scheme</string><key>DeviceIdentifier</key><string>disk0</string><key>Size</key><integer>$disk</integer><key>Partitions</key><array>$parts</array></dict></array></dict>" >"$d/cmd/diskutil_list_disk0"
  if [ "$pref" -gt 0 ]; then
    plist "<dict><key>ContainerCurrentSize</key><integer>$container</integer><key>CurrentSize</key><integer>$container</integer><key>MaximumSize</key><integer>$container</integer><key>MinimumSizePreferred</key><integer>$pref</integer><key>Type</key><string>APFSContainerReference</string></dict>" >"$d/cmd/diskutil_limits_disk3"
  fi
  printf 'pbcopy\nplutil\n' >"$d/commands"
  put "$d/net/asahi_home.reachable" ""
  put "$d/net/asahi_version" v0.9.2
  put "$d/net/repo_public.reachable" ""
  cat >"$d/net/asahi-alarm-bootstrap.sh" <<'EOF'
#!/bin/sh
# FIXTURE — a stand-in for the Asahi Alarm bootstrap. Never executed by tests.
    export INSTALLER_DATA="https://asahi-alarm.org/installer_data.json"
echo "fixture: would exec ./install.sh"
exit 0
EOF
}

stock_parts() { # CONTAINER
  printf '%s%s%s' "$(part Apple_APFS_ISC disk0s1 $ISC)" "$(part Apple_APFS disk0s2 "$1")" "$(part Apple_APFS_Recovery disk0s3 $RECOVERY)"
}

D1T=1000555581440
C1T=$((D1T - ISC - RECOVERY - 40960))          # 994662543360
D512=500277792768
C512=$((D512 - ISC - RECOVERY - 40960))        # 494384754688

# 1 TB, plenty free: used 294.66 GB, 2 GB snapshot overhead.
mac mac-m1pro-1tb-roomy MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $D1T $C1T $((700 * GB)) $((C1T - 700 * GB + 40 * GB)) "$(stock_parts $C1T)"
# 1 TB, 60 GB free: below the Omarchy minimum.
mac mac-m1pro-1tb-tight MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $D1T $C1T $((60 * GB)) $((C1T - 60 * GB + 39 * GB)) "$(stock_parts $C1T)"
# 512 GB M2 Air with 20 GB of snapshot overhead.
mac mac-m2-512 Mac14,2 "Apple M2" arm64 1 15.1 $D512 $C512 $((250 * GB)) $((C512 - 250 * GB + 58 * GB)) "$(stock_parts $C512)" 8589934592
# Intel: unsupported.
mac mac-intel MacBookPro16,1 "8-Core Intel Core i9" x86_64 0 14.6 $D512 $C512 $((200 * GB)) 0 "$(stock_parts $C512)"
# M3 Pro: experimental tier.
mac mac-m3pro-experimental Mac15,6 "Apple M3 Pro" arm64 1 15.1 $D1T $C1T $((600 * GB)) $((C1T - 600 * GB + 40 * GB)) "$(stock_parts $C1T)" 19327352832
# Asahi already installed after a 250 GB plan.
mac mac-asahi-installed MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $D1T $((745 * GB)) $((450 * GB)) $((295 * GB + 40 * GB)) \
  "$(part Apple_APFS_ISC disk0s1 $ISC)$(part Apple_APFS disk0s2 $((745 * GB)))$(part Apple_APFS disk0s4 2500000000)$(part EFI disk0s5 524288000)$(part 0FC63DAF-8483-4772-8E79-3D69D8477DE4 disk0s6 246637543360)$(part Apple_APFS_Recovery disk0s3 $RECOVERY)"

# ---------------------------------------------------------------------------

setup_fixture_script() { # PATH [ARGS-HEADER]
  local header=${2:-'[--encrypt|--no-encrypt] [--user <name>] [--hostname <name>] [--keymap <name>] [--repo <owner/repo>] [--ref <branch>] [--forge <host>] [--status] [--step <name>] [--fonts] [--autologin] [--resume] [--abort] [--allow-omarchy3] [--keep-root-password]'}
  cat >"$1" <<EOF
#!/bin/bash
# FIXTURE — a stand-in for omarchy-mac-setup. Never executed by tests.
# omarchy:summary=Guided end-to-end Omarchy Mac install
# omarchy:args=$header
echo "fixture"
exit 0
EOF
}

# linux NAME UID USER ROOTFS ROOTSRC BOOTSRC BOOTFS CRYPT ROUTE OMARCHY(absent|progress|installed)
linux() {
  local d=$1 uid=$2 user=$3 rootfs=$4 rootsrc=$5 bootsrc=$6 bootfs=$7 crypt=$8 route=$9 omarchy=${10}
  rm -rf "$d"
  mkdir -p "$d/cmd" "$d/net" "$d/root/proc/device-tree" "$d/root/etc"
  put "$d/cmd/uname_s" Linux
  put "$d/cmd/uname_m" aarch64
  put "$d/cmd/uname_r" 6.16.8-asahi-1-1-ARCH
  put "$d/cmd/id_u" "$uid"
  put "$d/cmd/id_un" "$user"
  printf 'apple,j316s\0apple,t6000\0apple,arm-platform\0' >"$d/root/proc/device-tree/compatible"
  printf 'Apple MacBook Pro (16-inch, M1 Pro, 2021)\0' >"$d/root/proc/device-tree/model"
  printf 'NAME="Arch Linux ARM"\nPRETTY_NAME="Arch Linux ARM"\nID=archarm\nID_LIKE=arch\n' >"$d/root/etc/os-release"
  put "$d/root/etc/vconsole.conf" "KEYMAP=us"
  put "$d/root/etc/locale.conf" "LANG=C.UTF-8"
  put "$d/cmd/findmnt_root" "${rootsrc}[/@]"
  put "$d/cmd/findmnt_root_fstype" "$rootfs"
  if [ -n "$bootsrc" ]; then
    put "$d/cmd/findmnt_boot" "$bootsrc"
    put "$d/cmd/findmnt_boot_fstype" "$bootfs"
  else
    put "$d/cmd/findmnt_boot" ""
    put "$d/cmd/findmnt_boot.rc" 1
  fi
  put "$d/cmd/lsblk_root_type" "$([ "$crypt" = 1 ] && echo crypt || echo part)"
  if [ "$route" = 1 ]; then
    put "$d/cmd/ip_route" "default via 192.168.1.1 dev wlan0 proto dhcp metric 600
192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.20"
    put "$d/net/github.reachable" ""
  else
    put "$d/cmd/ip_route" ""
  fi
  put "$d/cmd/pagesize" 16384
  put "$d/cmd/timezone" UTC
  put "$d/cmd/unit_active" inactive
  put "$d/cmd/unit_active.rc" 3
  put "$d/cmd/sshd_active" inactive
  put "$d/cmd/sshd_active.rc" 3
  put "$d/cmd/pacman_dk" "No database errors have been found!"
  put "$d/cmd/df_root" "Filesystem     1024-blocks      Used Available Capacity Mounted on
$rootsrc   240000000  12000000 228000000       5% /"
  put "$d/cmd/pacman_qq" "base
bash
curl
networkmanager"
  printf 'pacman\nnmtui\nnmcli\ncurl\n' >"$d/commands"
  put "$d/net/omarchy_version" 4.0.3rc4
  setup_fixture_script "$d/net/omarchy-mac-setup"

  case "$omarchy" in
    progress)
      put "$d/root/etc/omarchy-mac-setup.conf" "WANT_ENCRYPT=1
SETUP_USER=alex"
      put "$d/root/usr/local/bin/omarchy-mac-setup" "#!/bin/bash"
      put "$d/cmd/setup_status" "
=== Omarchy Mac setup status ===

  root            /dev/mapper/root (encrypted)
  /boot           /dev/nvme0n1p5
  omarchy         not installed
  encryption      done
  hostname        omarchy
  next step       omarchy"
      ;;
    installed)
      put "$d/root/var/lib/omarchy-mac-setup/installed" 2026-09-22T10:00:00Z
      put "$d/root/usr/share/omarchy/version" 4.0.3rc4
      mkdir -p "$d/root/etc/systemd/system"
      ln -sf /usr/lib/systemd/system/sddm.service "$d/root/etc/systemd/system/display-manager.service"
      put "$d/cmd/snapper_configs" "root | /"
      put "$d/cmd/timezone" America/New_York
      put "$d/root/etc/locale.conf" "LANG=en_US.UTF-8"
      put "$d/cmd/git_name" ""
      put "$d/cmd/gh_status" ""
      put "$d/cmd/gh_status.rc" 1
      put "$d/cmd/pacman_qq" "base
base-devel
bash
btop
curl
docker
fd
fzf
git
jq
ripgrep
tmux
unzip"
      printf 'pacman\nnmtui\ncurl\nsnapper\ndocker\nomarchy-pkg-add\nomarchy-install-dev-env\nomarchy-install-editor-vscode\nomarchy-setup-security-sshd\nomarchy-setup-security-sudoless-docker\ngit\ngh\n' >"$d/commands"
      ;;
  esac
}

linux linux-alarm-fresh 0 root btrfs /dev/nvme0n1p6 "" "" 0 1 absent
linux linux-alarm-offline 0 root btrfs /dev/nvme0n1p6 "" "" 0 0 absent
linux linux-setup-in-progress 0 root btrfs /dev/mapper/root /dev/nvme0n1p5 vfat 1 1 progress
linux linux-omarchy-installed 1000 alex btrfs /dev/mapper/root /dev/nvme0n1p5 vfat 1 1 installed

# Upstream drift: Omarchy 3 on the branch, and a setup script without --keymap.
linux linux-upstream-drift 0 root btrfs /dev/nvme0n1p6 "" "" 0 1 absent
put linux-upstream-drift/net/omarchy_version 3.8.2
setup_fixture_script linux-upstream-drift/net/omarchy-mac-setup '[--encrypt|--no-encrypt] [--user <name>] [--hostname <name>] [--status] [--resume]'

# ---------------------------------------------------------------------------
# `sources --check` responses: current, and drifted.

net_sources() { # DIR ASAHI_VERSION OS_NAME OMARCHY_VERSION BRANCH FAQ README
  local d=$1
  mkdir -p "$d/net" "$d/cmd"
  put "$d/cmd/uname_s" Darwin
  put "$d/cmd/id_u" 501
  put "$d/net/asahi_version" "$2"
  put "$d/net/asahi_data" "{\"os_list\": [{\"name\": \"$3\"}]}"
  put "$d/net/omarchy_version" "$4"
  put "$d/net/omarchy_api" "{\"full_name\": \"omacom/omarchy-mac\", \"default_branch\": \"$5\"}"
  put "$d/net/asahi_faq" "$6"
  put "$d/net/omarchy_readme" "$7"
}
rm -rf net-current net-drifted
net_sources net-current v0.9.2 "Asahi Alarm Minimal (BTRFS)" 4.0.3rc4 quattro "The installer always leaves 38GB of disk space free" "- At least 50 GB free on the internal SSD (100 GB recommended)."
setup_fixture_script net-current/net/omarchy_setup
net_sources net-drifted v0.10.0 "Asahi Alarm Minimal" 3.9.0 main "The installer leaves 45GB free" "- At least 60 GB free."
setup_fixture_script net-drifted/net/omarchy_setup '[--encrypt|--no-encrypt] [--user <name>] [--status]'

echo "fixtures regenerated"
