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
MIB=1048576
# A stock 1 TB Apple SSD, as `diskutil info -plist` reports it: 4096-byte
# blocks, the GPT's first usable block at 24576, its backup in the last 20480
# bytes, and ISC, the macOS container and Recovery back to back between.
ISC=576716800
RECOVERY=5368664064
GPT_FRONT=24576
GPT_BACK=20480

# Synthetic GPT GUIDs, one per role.
U_ISC=4A7B1C2D-0001-4E5F-8A9B-000000000001
U_MAC=4A7B1C2D-0002-4E5F-8A9B-000000000002
U_REC=4A7B1C2D-0003-4E5F-8A9B-000000000003
U_STUB=4A7B1C2D-0004-4E5F-8A9B-000000000004
U_EFI=4A7B1C2D-0005-4E5F-8A9B-000000000005
U_ROOT=4A7B1C2D-0006-4E5F-8A9B-000000000006
U_SHARED=4A7B1C2D-0007-4E5F-8A9B-000000000007
U_OTHER=4A7B1C2D-0008-4E5F-8A9B-000000000008

plist() {
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  printf '<plist version="1.0">\n%s\n</plist>\n' "$1"
}
put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }
lines() { printf '%s\n' "$@"; }
# gbm N — N GB rounded down to whole MiB, the way sizes land on disk.
gbm() { printf '%s' $(($1 * GB / MIB * MIB)); }

# disk FIXTURE DISK_BYTES BLOCK ENTRIES — the internal disk: diskutil list,
# diskutil info for the whole disk and for every partition, laid out in the
# order given from the GPT's first usable block. Every value is consistent:
# partitions + gaps + GPT structures add up to DISK_BYTES exactly.
#   ENTRIES, one per line:  id:content:size:guid[:volume name[:filesystem]]  or  gap:bytes
disk() {
  local d=$1 total=$2 block=$3 entries=$4 off list="" e id content size uuid vol fs
  off=$((2 * block + 16384))
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in gap:*)
      off=$((off + ${e#gap:}))
      continue
      ;;
    esac
    IFS=: read -r id content size uuid vol fs <<EOF
$e
EOF
    list="$list<dict><key>Content</key><string>$content</string><key>DeviceIdentifier</key><string>$id</string><key>DiskUUID</key><string>$uuid</string><key>Size</key><integer>$size</integer>${vol:+<key>VolumeName</key><string>$vol</string>}</dict>"
    plist "<dict><key>Content</key><string>$content</string><key>DeviceIdentifier</key><string>$id</string><key>DeviceBlockSize</key><integer>$block</integer><key>DiskUUID</key><string>$uuid</string><key>Internal</key><true/><key>MountPoint</key><string>${vol:+/Volumes/$vol}</string><key>ParentWholeDisk</key><string>disk0</string><key>PartitionMapPartition</key><true/><key>PartitionMapPartitionOffset</key><integer>$off</integer><key>Size</key><integer>$size</integer><key>VolumeName</key><string>$vol</string>${fs:+<key>FilesystemType</key><string>$fs</string>}<key>WholeDisk</key><false/></dict>" >"$d/cmd/diskutil_info_$id"
    off=$((off + size))
  done <<EOF
$entries
EOF
  plist "<dict><key>AllDisksAndPartitions</key><array><dict><key>Content</key><string>GUID_partition_scheme</string><key>DeviceIdentifier</key><string>disk0</string><key>Size</key><integer>$total</integer><key>Partitions</key><array>$list</array></dict></array></dict>" >"$d/cmd/diskutil_list_disk0"
  plist "<dict><key>Content</key><string>GUID_partition_scheme</string><key>DeviceBlockSize</key><integer>$block</integer><key>DeviceIdentifier</key><string>disk0</string><key>IORegistryEntryName</key><string>APPLE SSD FIXTURE Media</string><key>Internal</key><true/><key>SMARTStatus</key><string>Verified</string><key>Size</key><integer>$total</integer><key>WholeDisk</key><true/></dict>" >"$d/cmd/diskutil_info_disk0"
}

INSTALLER_DATA='{"os_list": [
  {"name": "Asahi Alarm Minimal", "partitions": [{"name": "EFI", "type": "EFI", "size": "524288000B"}, {"name": "Root", "type": "Linux", "size": "2209614225B", "expand": true}]},
  {"name": "Asahi Alarm Minimal (BTRFS)", "package": "https://asahi-alarm.org/asahi-base-btrfs.zip",
   "partitions": [{"name": "EFI", "type": "EFI", "size": "524288000B", "format": "fat"}, {"name": "Root", "type": "Linux", "size": "2209614225B", "expand": true}]}
]}'

# mac NAME MODEL CHIP ARCH ARM64 MACOS FREE PREF DISK_BYTES BLOCK ENTRIES
# The macOS container is the disk0s2 entry; FREE is its APFS free space and
# PREF diskutil's MinimumSizePreferred (0: the limits query does not answer).
# MEM (bytes) may be set in the environment.
mac() {
  local d=$1 model=$2 chip=$3 arch=$4 arm64=$5 macos=$6 free=$7 pref=$8 total=$9 block=${10} entries=${11} mem=${MEM:-17179869184} container
  rm -rf "$d"
  mkdir -p "$d/cmd" "$d/net"
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    case "$e" in disk0s2:*) container=$(printf '%s' "$e" | cut -d: -f3) ;; esac
  done <<EOF
$entries
EOF
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
  put "$d/cmd/git_head" 0123456789abcdef0123456789abcdef01234567
  put "$d/cmd/git_pushed" "  origin/main"
  put "$d/cmd/pmset_batt" "Now drawing from 'AC Power'
 -InternalBattery-0 (id=1234567)	96%; charged; 0:00 remaining present: true"
  local chipkey=chip_type
  [ "$arm64" = 1 ] || chipkey=cpu_type
  plist "<array><dict><key>_items</key><array><dict><key>machine_name</key><string>MacBook Pro</string><key>machine_model</key><string>$model</string><key>$chipkey</key><string>$chip</string><key>physical_memory</key><string>$((mem / 1073741824)) GB</string></dict></array></dict></array>" >"$d/cmd/hardware_plist"
  plist "<dict><key>VolumeName</key><string>Macintosh HD</string><key>APFSContainerReference</key><string>disk3</string><key>APFSContainerSize</key><integer>$container</integer><key>APFSContainerFree</key><integer>$free</integer><key>APFSPhysicalStores</key><array><dict><key>APFSPhysicalStore</key><string>disk0s2</string></dict></array><key>Internal</key><true/></dict>" >"$d/cmd/diskutil_info_root"
  disk "$d" "$total" "$block" "$entries"
  if [ "$pref" -gt 0 ]; then
    plist "<dict><key>ContainerCurrentSize</key><integer>$container</integer><key>CurrentSize</key><integer>$container</integer><key>MaximumSize</key><integer>$container</integer><key>MinimumSizePreferred</key><integer>$pref</integer><key>Type</key><string>APFSContainerReference</string></dict>" >"$d/cmd/diskutil_limits_disk3"
  fi
  printf 'pbcopy\nplutil\n' >"$d/commands"
  put "$d/net/asahi_home.reachable" ""
  put "$d/net/asahi_version" v0.9.2
  put "$d/net/asahi_data" "$INSTALLER_DATA"
  put "$d/net/repo_public.reachable" ""
  cat >"$d/net/asahi-alarm-bootstrap.sh" <<'EOF'
#!/bin/sh
# FIXTURE — a stand-in for the Asahi Alarm bootstrap. Never executed by tests.
    export INSTALLER_DATA="https://asahi-alarm.org/installer_data.json"
echo "fixture: would exec ./install.sh"
exit 0
EOF
}

# stock DISK_BYTES — the three stock partitions, container filling the rest.
stock() {
  local c=$(($1 - GPT_FRONT - GPT_BACK - ISC - RECOVERY))
  printf '%s\n' "disk0s1:Apple_APFS_ISC:$ISC:$U_ISC" "disk0s2:Apple_APFS:$c:$U_MAC" "disk0s3:Apple_APFS_Recovery:$RECOVERY:$U_REC"
}

D1T=1000555581440
C1T=$((D1T - GPT_FRONT - GPT_BACK - ISC - RECOVERY))   # 994610155520
D512=500277792768
C512=$((D512 - GPT_FRONT - GPT_BACK - ISC - RECOVERY)) # 494332366848

# 1 TB M1 Pro, plenty free: used 294.61 GB, 2 GB snapshot overhead.
mac mac-m1pro-1tb-roomy MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((700 * GB)) $((C1T - 700 * GB + 40 * GB)) $D1T 4096 "$(stock $D1T)"
# 1 TB, 60 GB free: below what Linux needs.
mac mac-m1pro-1tb-tight MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((60 * GB)) $((C1T - 60 * GB + 39 * GB)) $D1T 4096 "$(stock $D1T)"
# 512 GB M2 Air with 20 GB of snapshot overhead.
MEM=8589934592 mac mac-m2-512 Mac14,2 "Apple M2" arm64 1 15.1 $((250 * GB)) $((C512 - 250 * GB + 58 * GB)) $D512 4096 "$(stock $D512)"
# Intel: unsupported.
mac mac-intel MacBookPro16,1 "8-Core Intel Core i9" x86_64 0 14.6 $((200 * GB)) 0 $D512 4096 "$(stock $D512)"
# M3 Pro: experimental tier.
MEM=19327352832 mac mac-m3pro-experimental Mac15,6 "Apple M3 Pro" arm64 1 15.1 $((600 * GB)) $((C1T - 600 * GB + 40 * GB)) $D1T 4096 "$(stock $D1T)"
# 300 GB left unpartitioned right after the container (e.g. a removed install).
CFREE=$((C1T - $(gbm 300)))
mac mac-m1-free-space MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((400 * GB)) $((CFREE - 400 * GB + 40 * GB)) $D1T 4096 \
  "$(lines "disk0s1:Apple_APFS_ISC:$ISC:$U_ISC" "disk0s2:Apple_APFS:$CFREE:$U_MAC" "gap:$(gbm 300)" "disk0s3:Apple_APFS_Recovery:$RECOVERY:$U_REC")"
# Two separate 75 GB gaps around a 20 GB data partition, and a nearly full
# macOS that cannot give anything up: 150 GB free in total, 75 GB usable.
C2G=$((C1T - 2 * $(gbm 75) - $(gbm 20)))
mac mac-geo-two-gaps MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((40 * GB)) $((C2G - 40 * GB + 39 * GB)) $D1T 4096 \
  "$(lines "disk0s1:Apple_APFS_ISC:$ISC:$U_ISC" "disk0s2:Apple_APFS:$C2G:$U_MAC" "gap:$(gbm 75)" \
  "disk0s4:Microsoft Basic Data:$(gbm 20):$U_OTHER:DATA:exfat" "gap:$(gbm 75)" "disk0s3:Apple_APFS_Recovery:$RECOVERY:$U_REC")"
# A 512-byte-sector disk: the GPT's first usable block is 34, not 6.
D5=500107862016
C5=$((D5 - 1024 - 16384 - 512 - 16384 - ISC - RECOVERY))
mac mac-geo-512-sectors MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((300 * GB)) $((C5 - 300 * GB + 40 * GB)) $D5 512 \
  "$(lines "disk0s1:Apple_APFS_ISC:$ISC:$U_ISC" "disk0s2:Apple_APFS:$C5:$U_MAC" "disk0s3:Apple_APFS_Recovery:$RECOVERY:$U_REC")"
# A second, large APFS container: not a layout this tool plans around.
CMA=$((C1T - $(gbm 100)))
mac mac-geo-multi-apfs MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((500 * GB)) $((CMA - 500 * GB + 40 * GB)) $D1T 4096 \
  "$(lines "disk0s1:Apple_APFS_ISC:$ISC:$U_ISC" "disk0s2:Apple_APFS:$CMA:$U_MAC" "disk0s4:Apple_APFS:$(gbm 100):$U_OTHER" "disk0s3:Apple_APFS_Recovery:$RECOVERY:$U_REC")"
# Roomy, but diskutil's resize-limits query does not answer.
mac mac-geo-no-limits MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((700 * GB)) 0 $D1T 4096 "$(stock $D1T)"
# Roomy, but one partition's offset is missing from diskutil info.
mac mac-geo-missing-offset MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((700 * GB)) $((C1T - 700 * GB + 40 * GB)) $D1T 4096 "$(stock $D1T)"
sed -i.bak 's#<key>PartitionMapPartitionOffset</key><integer>[0-9]*</integer>##' mac-geo-missing-offset/cmd/diskutil_info_disk0s3 && rm -f mac-geo-missing-offset/cmd/*.bak
# Roomy, but diskutil list and diskutil info disagree about the container.
mac mac-geo-disagree MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((700 * GB)) $((C1T - 700 * GB + 40 * GB)) $D1T 4096 "$(stock $D1T)"
sed -i.bak "s#<integer>$C1T</integer></dict><dict><key>Content</key><string>Apple_APFS_Recovery#<integer>$((C1T - 4096))</integer></dict><dict><key>Content</key><string>Apple_APFS_Recovery#" mac-geo-disagree/cmd/diskutil_list_disk0 && rm -f mac-geo-disagree/cmd/*.bak

# After the Asahi installer: macOS resized to V for a 250 GB Linux request
# (what the planner answers for this disk), then stub, EFI and root created
# from "max", leaving the sub-MiB remainder of the region free.
V250=744608497664
OS250=$(((C1T - V250) / MIB * MIB))
ROOT250=$((OS250 - 2499805184 - 524288000))
asahi_layout() { # extra entries after the Linux root (e.g. a Shared gap)
  printf '%s\n' "disk0s1:Apple_APFS_ISC:$ISC:$U_ISC" "disk0s2:Apple_APFS:$V250:$U_MAC" \
    "disk0s4:Apple_APFS:2499805184:$U_STUB" "disk0s5:EFI:524288000:$U_EFI" "disk0s6:Linux Filesystem:$ROOT250:$U_ROOT" \
    "gap:$((C1T - V250 - OS250))" "disk0s3:Apple_APFS_Recovery:$RECOVERY:$U_REC"
}
mac mac-asahi-installed MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((450 * GB)) $((V250 - 450 * GB + 40 * GB)) $D1T 4096 "$(asahi_layout)"

# The stub container's volumes, as `diskutil apfs list -plist` shows them,
# and its system volume's mount point (empty: not mounted).
# apfs_list FIXTURE STUB_ID NVOL [MOUNTPOINT]
apfs_list() {
  local d=$1 stub=$2 n=$3 mp=${4:-} vols="" i role name
  i=0
  for role in System Data Preboot Recovery; do
    i=$((i + 1))
    [ "$i" -le "$n" ] || break
    if [ "$n" = 1 ]; then
      vols="$vols<dict><key>DeviceIdentifier</key><string>disk4s$i</string><key>Name</key><string>Omarchy</string><key>Roles</key><array/></dict>"
    else
      name=Omarchy
      [ "$role" = Data ] && name="Omarchy - Data"
      vols="$vols<dict><key>DeviceIdentifier</key><string>disk4s$i</string><key>Name</key><string>$name</string><key>Roles</key><array><string>$role</string></array></dict>"
    fi
  done
  plist "<dict><key>Containers</key><array><dict><key>ContainerReference</key><string>disk3</string><key>DesignatedPhysicalStore</key><string>disk0s2</string><key>Volumes</key><array><dict><key>DeviceIdentifier</key><string>disk3s1</string><key>Name</key><string>Macintosh HD</string><key>Roles</key><array><string>System</string></array></dict></array></dict><dict><key>ContainerReference</key><string>disk4</string><key>DesignatedPhysicalStore</key><string>$stub</string><key>Volumes</key><array>$vols</array></dict></array></dict>" >"$d/cmd/diskutil_apfs_list"
  plist "<dict><key>DeviceIdentifier</key><string>disk4s1</string><key>MountPoint</key><string>$mp</string><key>VolumeName</key><string>Omarchy</string></dict>" >"$d/cmd/diskutil_info_disk4s1"
}
# stub_files FIXTURE MOUNTPOINT pending|complete [missing-file]
stub_files() {
  local r="$1/root$2" app="$1/root$2/Finish Installation.app/Contents/Resources"
  mkdir -p "$app" "$r/System/Library/CoreServices"
  : >"$app/step2.sh"
  : >"$app/boot.bin"
  if [ "$3" = pending ]; then
    : >"$r/.IAPhysicalMedia"
    : >"$r/System/Library/CoreServices/SystemVersion-disabled.plist"
  else
    : >"$r/IAPhysicalMedia-disabled.plist"
    : >"$r/System/Library/CoreServices/SystemVersion.plist"
  fi
  [ -n "${4:-}" ] && rm -f "$app/$4"
  return 0
}
apfs_list mac-asahi-installed disk0s4 4
# Resized, then the installer quit: the freed space is free, no stub.
mac mac-asahi-resized-only MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((450 * GB)) $((V250 - 450 * GB + 40 * GB)) $D1T 4096 \
  "$(lines "disk0s1:Apple_APFS_ISC:$ISC:$U_ISC" "disk0s2:Apple_APFS:$V250:$U_MAC" "gap:$((C1T - V250))" "disk0s3:Apple_APFS_Recovery:$RECOVERY:$U_REC")"
# Stopped after creating the stub.
mac mac-asahi-stub-only MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((450 * GB)) $((V250 - 450 * GB + 40 * GB)) $D1T 4096 \
  "$(lines "disk0s1:Apple_APFS_ISC:$ISC:$U_ISC" "disk0s2:Apple_APFS:$V250:$U_MAC" "disk0s4:Apple_APFS:2499805184:$U_STUB" "gap:$((C1T - V250 - 2499805184))" "disk0s3:Apple_APFS_Recovery:$RECOVERY:$U_REC")"
apfs_list mac-asahi-stub-only disk0s4 4
# Stopped after the EFI partition.
mac mac-asahi-no-root MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((450 * GB)) $((V250 - 450 * GB + 40 * GB)) $D1T 4096 \
  "$(lines "disk0s1:Apple_APFS_ISC:$ISC:$U_ISC" "disk0s2:Apple_APFS:$V250:$U_MAC" "disk0s4:Apple_APFS:2499805184:$U_STUB" "disk0s5:EFI:524288000:$U_EFI" "gap:$((C1T - V250 - 2499805184 - 524288000))" "disk0s3:Apple_APFS_Recovery:$RECOVERY:$U_REC")"
apfs_list mac-asahi-no-root disk0s4 4
# All three partitions; the stub was created but never prepared (one volume).
mac mac-asahi-unprepared MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((450 * GB)) $((V250 - 450 * GB + 40 * GB)) $D1T 4096 "$(asahi_layout)"
apfs_list mac-asahi-unprepared disk0s4 1
# First stage complete, first boot not yet run; the stub's volume is mounted.
mac mac-asahi-pending MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((450 * GB)) $((V250 - 450 * GB + 40 * GB)) $D1T 4096 "$(asahi_layout)"
apfs_list mac-asahi-pending disk0s4 4 /Volumes/Omarchy
stub_files mac-asahi-pending /Volumes/Omarchy pending
# Step 2 has run.
mac mac-asahi-complete MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((450 * GB)) $((V250 - 450 * GB + 40 * GB)) $D1T 4096 "$(asahi_layout)"
apfs_list mac-asahi-complete disk0s4 4 /Volumes/Omarchy
stub_files mac-asahi-complete /Volumes/Omarchy complete
# Interrupted before boot.bin: the installer's repair refuses this.
mac mac-asahi-files-missing MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((450 * GB)) $((V250 - 450 * GB + 40 * GB)) $D1T 4096 "$(asahi_layout)"
apfs_list mac-asahi-files-missing disk0s4 4 /Volumes/Omarchy
stub_files mac-asahi-files-missing /Volumes/Omarchy pending boot.bin
# Two stub containers: not one install.
mac mac-asahi-two-stubs MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((450 * GB)) $((V250 - 450 * GB + 40 * GB)) $D1T 4096 \
  "$(lines "disk0s1:Apple_APFS_ISC:$ISC:$U_ISC" "disk0s2:Apple_APFS:$V250:$U_MAC" "disk0s4:Apple_APFS:2499805184:$U_STUB" "disk0s7:Apple_APFS:2499805184:$U_OTHER" "gap:$((C1T - V250 - 2 * 2499805184))" "disk0s3:Apple_APFS_Recovery:$RECOVERY:$U_REC")"

# Shared storage, planned on the roomy disk as 250 GB Linux + 150 GB Shared,
# after the installer ran with the planner's exact answers: macOS resized to
# VS, stub/EFI/root from the region's start, the reserved region after root.
C0=$((GPT_FRONT + ISC))
RZ_END=$((C0 + C1T))
T250=$(( (250 * GB + MIB - 1) / MIB * MIB ))
S150=$(( (150 * GB + MIB - 1) / MIB * MIB ))
VS=$(( ( (RZ_END / MIB * MIB - T250 - S150 - 16777216) - C0 ) / MIB * MIB ))
ROOTS=$((T250 - 2499805184 - 524288000))
ROOT_END=$((C0 + VS + T250))
SH0=$(( (ROOT_END + MIB - 1) / MIB * MIB ))
SH1=$(( RZ_END / MIB * MIB ))
shared_layout() { # [created]
  lines "disk0s1:Apple_APFS_ISC:$ISC:$U_ISC" "disk0s2:Apple_APFS:$VS:$U_MAC" \
    "disk0s4:Apple_APFS:2499805184:$U_STUB" "disk0s5:EFI:524288000:$U_EFI" "disk0s6:Linux Filesystem:$ROOTS:$U_ROOT"
  if [ "${1:-}" = created ]; then
    lines "gap:$((SH0 - ROOT_END))" "disk0s7:Microsoft Basic Data:$((SH1 - SH0)):$U_SHARED:Shared:exfat" "gap:$((RZ_END - SH1))"
  else
    lines "gap:$((RZ_END - ROOT_END))"
  fi
  lines "disk0s3:Apple_APFS_Recovery:$RECOVERY:$U_REC"
}
mac mac-shared-reserved MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((300 * GB)) $((VS - 300 * GB + 40 * GB)) $D1T 4096 "$(shared_layout)"
apfs_list mac-shared-reserved disk0s4 4
mac mac-shared-created MacBookPro18,1 "Apple M1 Pro" arm64 1 14.6 $((300 * GB)) $((VS - 300 * GB + 40 * GB)) $D1T 4096 "$(shared_layout created)"
apfs_list mac-shared-created disk0s4 4

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
  put "$d/cmd/id_g" "$uid"
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
  if [ "$crypt" = 1 ]; then
    put "$d/cmd/lsblk_root_backing" "$rootsrc crypt
/dev/nvme0n1p6 part
/dev/nvme0n1 disk"
    put "$d/cmd/luks_dump" "LUKS header information
Version:       	2
Requirements:	(no flags)"
  else
    put "$d/cmd/lsblk_root_backing" "$rootsrc part
/dev/nvme0n1 disk"
  fi
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
      put "$d/root/var/lib/omarchy/btrfs-migrate-done" ""
      put "$d/root/usr/local/bin/omarchy-mac-setup" "#!/bin/bash"
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
      printf 'pacman\nnmtui\ncurl\nsnapper\ndocker\nomarchy-pkg-add\nomarchy-install-dev-env\nomarchy-install-editor-vscode\nomarchy-setup-security-sshd\nomarchy-setup-security-sudoless-docker\ngit\ngh\n' >"$d/commands" && cat >"$d/net/claude-code-install.sh" <<'CEOF'
#!/bin/bash
# FIXTURE — a stand-in for the Claude Code installer. Never executed by tests.
echo fixture
CEOF
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

# Lifecycle states the base fixtures do not cover.
# omarchy-mac-setup running right now on tty1 (a oneshot unit is "activating").
linux linux-setup-active 0 root btrfs /dev/mapper/root /dev/nvme0n1p5 vfat 1 1 progress
put linux-setup-active/cmd/unit_active activating
rm -f linux-setup-active/cmd/unit_active.rc
# Omarchy's package present, install unfinished, no setup conf.
linux linux-omarchy-partial 0 root btrfs /dev/nvme0n1p6 "" "" 0 1 absent
put linux-omarchy-partial/root/usr/share/omarchy/version 4.0.3rc4
# Installed, and the conf still present until the next boot finishes it.
linux linux-omarchy-finishing 1000 alex btrfs /dev/mapper/root /dev/nvme0n1p5 vfat 1 1 installed
put linux-omarchy-finishing/root/etc/omarchy-mac-setup.conf "WANT_ENCRYPT=1
SETUP_USER=alex"
# Encryption staged for the next boot: root still plain, migrate conf present.
linux linux-encrypt-staged 0 root btrfs /dev/nvme0n1p6 /dev/nvme0n1p5 vfat 0 1 progress
put linux-encrypt-staged/root/etc/omarchy-btrfs-migrate.conf "MODE=encrypt
PARTUUID=4a7b1c2d-0006-4e5f-8a9b-000000000006"
# Booted with the re-encryption still pending (after a failed worker run).
linux linux-encrypt-reencrypting 0 root btrfs /dev/mapper/root /dev/nvme0n1p5 vfat 1 1 progress
put linux-encrypt-reencrypting/cmd/luks_dump "LUKS header information
Version:       	2
Requirements:	online-reencrypt"

# Shared storage on Linux, on the disk above (same offsets, in 512-byte
# sectors as lsblk reports them), root on LUKS as Omarchy leaves it.
lower() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
lsblk_row() { # NAME PKNAME TYPE START_BYTES SIZE PARTUUID PARTTYPE FSTYPE LABEL UUID
  local start=""
  [ -n "$4" ] && start=$(($4 / 512))
  printf 'NAME="%s" PKNAME="%s" TYPE="%s" START="%s" SIZE="%s" PARTUUID="%s" PARTTYPE="%s" FSTYPE="%s" LABEL="%s" UUID="%s"\n' \
    "$1" "$2" "$3" "$start" "$5" "$(lower "$6")" "$7" "$8" "$9" "${10}"
}
lsblk_disk() { # with-shared|no-shared [SHARED_FSTYPE]
  local fs=${2:-exfat}
  lsblk_row nvme0n1 "" disk "" $D1T "" "" "" "" ""
  lsblk_row nvme0n1p1 nvme0n1 part $GPT_FRONT $ISC $U_ISC 69646961-6700-11aa-aa11-00306543ecac apfs "" ""
  lsblk_row nvme0n1p2 nvme0n1 part $C0 $VS $U_MAC 7c3457ef-0000-11aa-aa11-00306543ecac apfs "" ""
  lsblk_row nvme0n1p3 nvme0n1 part $RZ_END $RECOVERY $U_REC 52637672-7900-11aa-aa11-00306543ecac apfs "" ""
  lsblk_row nvme0n1p4 nvme0n1 part $((C0 + VS)) 2499805184 $U_STUB 7c3457ef-0000-11aa-aa11-00306543ecac apfs "" ""
  lsblk_row nvme0n1p5 nvme0n1 part $((C0 + VS + 2499805184)) 524288000 $U_EFI c12a7328-f81f-11d2-ba4b-00a0c93ec93b vfat "" 2ABF-9F91
  lsblk_row nvme0n1p6 nvme0n1 part $((C0 + VS + 3024093184)) $ROOTS $U_ROOT 0fc63daf-8483-4772-8e79-3d69d8477de4 crypto_LUKS "" 5f3e2d1c-0000-4000-8000-00000000c0de
  if [ "$1" = with-shared ]; then
    lsblk_row nvme0n1p7 nvme0n1 part $SH0 $((SH1 - SH0)) $U_SHARED ebd0a0a2-b9e5-4433-87c0-68b6b72699c7 "$fs" Shared 1234-ABCD
  fi
  lsblk_row root nvme0n1p6 crypt "" $((ROOTS - 33554432)) "" "" btrfs "" 9f2c0000-0000-4000-8000-000000000b7f
}
FSTAB_BASE='# /etc/fstab: static file system information.
UUID=9f2c0000-0000-4000-8000-000000000b7f / btrfs rw,noatime,compress=zstd:1,subvol=/@ 0 0
UUID=9f2c0000-0000-4000-8000-000000000b7f /var/log btrfs rw,noatime,compress=zstd:1,subvol=@log 0 0
UUID=2ABF-9F91 /boot vfat rw,relatime,fmask=0022,dmask=0022 0 2'
MOUNTS_BASE='/dev/mapper/root / btrfs rw,noatime,compress=zstd:1,subvol=/@ 0 0
/dev/nvme0n1p5 /boot vfat rw,relatime 0 0'
lx_shared() { # NAME with-shared|no-shared [SHARED_FSTYPE]
  linux "$1" 1000 alex btrfs /dev/mapper/root /dev/nvme0n1p5 vfat 1 1 installed
  lsblk_disk "$2" "${3:-exfat}" >"$1/cmd/lsblk_all"
  put "$1/root/etc/fstab" "$FSTAB_BASE"
  put "$1/root/proc/self/mounts" "$MOUNTS_BASE"
  put "$1/root/var/lib/omarchy-mac-bootstrap/state.env" "cfg_user=alex
cfg_host=m1pro
cfg_enc=1
cfg_linux=250
cfg_shared=150
cfg_plan=1a2b3c4d"
}
# Omarchy installed; Shared not created yet.
lx_shared linux-shared-absent no-shared
# Created on macOS; not mounted on Linux yet.
lx_shared linux-shared-present with-shared
# Mounted on every boot by the managed fstab entry, automount armed.
lx_shared linux-shared-ready with-shared
put linux-shared-ready/root/etc/fstab "$FSTAB_BASE
# omarchy-bootstrap: Shared storage (managed; see ./omarchy-bootstrap shared)
PARTUUID=$(lower $U_SHARED) /mnt/shared exfat rw,nofail,x-systemd.automount,x-systemd.device-timeout=10s,uid=1000,gid=1000,fmask=0177,dmask=0077,nodev,nosuid,noexec 0 0"
put linux-shared-ready/root/proc/self/mounts "$MOUNTS_BASE
systemd-1 /mnt/shared autofs rw,relatime,fd=52,pgrp=1,timeout=0,minproto=5,maxproto=5,direct 0 0"
# Someone else's fstab line already claims the partition's mount point.
lx_shared linux-shared-conflict with-shared
put linux-shared-conflict/root/etc/fstab "$FSTAB_BASE
LABEL=Shared /mnt/shared exfat defaults 0 0"
# The partition after root is not exFAT (an interrupted format, say).
lx_shared linux-shared-wrong-fs with-shared vfat
# An everyday user who is not uid 1000.
lx_shared linux-shared-uid1001 with-shared
put linux-shared-uid1001/cmd/id_u 1001
put linux-shared-uid1001/cmd/id_g 1001
put linux-shared-uid1001/cmd/id_un bob

# The machine after every developer module has done its job: the checks
# that follow a recorded command read this (OMB_TEST_AFTER).
linux linux-dev-complete 1000 alex btrfs /dev/mapper/root /dev/nvme0n1p5 vfat 1 1 installed
put linux-dev-complete/cmd/pacman_qq "$(printf '%s\n' base bash git github-cli base-devel curl wget jq ripgrep fd fzf tmux btop tree unzip rsync docker podman podman-compose)"
printf '%s\n' pacman nmtui curl snapper docker podman code cargo uv node go npm claude codex sshd git gh \
  omarchy-pkg-add omarchy-install-dev-env omarchy-install-editor-vscode omarchy-setup-security-sshd omarchy-setup-security-sudoless-docker >linux-dev-complete/commands
put linux-dev-complete/cmd/gh_status "github.com: logged in as alex"
rm -f linux-dev-complete/cmd/gh_status.rc
put linux-dev-complete/cmd/git_name Alex
put linux-dev-complete/cmd/git_email alex@example.com
put linux-dev-complete/cmd/sshd_active active
rm -f linux-dev-complete/cmd/sshd_active.rc
put linux-dev-complete/cmd/ss_listen "LISTEN 0      128          0.0.0.0:22        0.0.0.0:*
LISTEN 0      128             [::]:22           [::]:*"

# ---------------------------------------------------------------------------
# `sources --check` responses: current, and drifted.

net_sources() { # DIR ASAHI_VERSION OS_NAME OMARCHY_VERSION BRANCH FAQ README [EFI_BYTES]
  local d=$1
  mkdir -p "$d/net" "$d/cmd"
  put "$d/cmd/uname_s" Darwin
  put "$d/cmd/id_u" 501
  put "$d/net/asahi_version" "$2"
  put "$d/net/asahi_data" "{\"os_list\": [{\"name\": \"$3\", \"partitions\": [{\"name\": \"EFI\", \"type\": \"EFI\", \"size\": \"${8:-524288000}B\"}, {\"name\": \"Root\", \"type\": \"Linux\", \"size\": \"2209614225B\", \"expand\": true}]}]}"
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
# Current in every way but the EFI size in the OS template: a storage-contract drift.
rm -rf net-efi-drift
net_sources net-efi-drift v0.9.2 "Asahi Alarm Minimal (BTRFS)" 4.0.3rc4 quattro "The installer always leaves 38GB of disk space free" "- At least 50 GB free on the internal SSD (100 GB recommended)." 1073741824
setup_fixture_script net-efi-drift/net/omarchy_setup

echo "fixtures regenerated"
