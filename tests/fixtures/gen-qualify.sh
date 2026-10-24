# shellcheck shell=bash
# Small streams and sealed step records for the Shared qualification tests.
# generate.sh sources this after the baseline's machine fixtures.
qfy_fixture_seal() {
  local digest
  digest=$(shasum -a 256 "$1") || return 1
  printf 'seal\tsha256=%s\n' "${digest%% *}" >>"$1"
}
rm -rf qualify-linux qualify-macos qualify-records
cp -R linux-shared-ready qualify-linux
cp -R mac-shared-created qualify-macos
printf '%s\n' sha256sum >>qualify-linux/commands
printf '%s\n' shasum >>qualify-macos/commands
put qualify-linux/cmd/qualify_space 'Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/nvme0n1p7 146484375 1000 140000000 1% /mnt/shared'
cp qualify-linux/cmd/qualify_space qualify-macos/cmd/qualify_space
put qualify-linux/cmd/qualify_journal 'kernel: exFAT-fs (nvme0n1p7): mounted filesystem'
put qualify-linux/cmd/qualify_dirty 'exfat: mounted cleanly'
put qualify-linux/cmd/qualify_kernel 6.16.8-asahi-1-1-ARCH
put qualify-linux/cmd/qualify_commit 0123456789012345678901234567890123456789
cp qualify-linux/cmd/qualify_commit qualify-macos/cmd/qualify_commit
put qualify-linux/root/proc/self/mountinfo "$MOUNTINFO_BASE
120 23 259:7 / /mnt/shared rw,relatime - exfat /dev/disk/by-partuuid/$(lower "$U_SHARED") rw,uid=1000,gid=1000"
mkdir -p qualify-records
# /dev/urandom is used only by the production writer; deterministic fixture
# bytes keep generated documents reproducible, with a 4097-byte test seam.
awk 'BEGIN {for (i=0;i<4097;i++) printf "q"}' >qualify-records/data.macos.bin
cp qualify-records/data.macos.bin qualify-records/data.linux.bin
qfy_fixture_data=$(shasum -a 256 qualify-records/data.macos.bin)
qfy_fixture_data=${qfy_fixture_data%% *}
qfy_fixture_plan=1a2b3c4d00000000000000000000000000000000000000000000000000000000
printf 'omb-qualify 1\nmacos\tschema=1\tplan=%s\tshared_guid=%s\tos=macos\tcommit=\tat=2026-10-23T12:00:00Z\tbytes=4097\tsha256=%s\tname=ascii.txt\n' \
  "$qfy_fixture_plan" "$U_SHARED" "$qfy_fixture_data" >qualify-records/macos.omb
qfy_fixture_seal qualify-records/macos.omb
qfy_fixture_previous=$(shasum -a 256 qualify-records/macos.omb)
printf 'omb-qualify 1\nlinux\tschema=1\tprevious=%s\tpartuuid=%s\tmajmin=259:7\tos=linux\tcommit=\tat=2026-10-23T12:00:00Z\tread_sha256=%s\tbytes=4097\tsha256=%s\tname_seen=ascii.txt\tname_written=ascii.txt\tkernel=6.16.8-asahi-1-1-ARCH\tdirty=0\n' \
  "${qfy_fixture_previous%% *}" "$(lower "$U_SHARED")" "$qfy_fixture_data" "$qfy_fixture_data" >qualify-records/linux.omb
qfy_fixture_seal qualify-records/linux.omb
mkdir -p qualify-records/names-macos qualify-records/names-linux
: >qualify-records/names-macos/ascii.txt
: >qualify-records/names-linux/ascii.txt
