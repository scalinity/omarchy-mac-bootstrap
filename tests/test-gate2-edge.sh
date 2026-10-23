#!/usr/bin/env bash
# Missing identity and opaque upstream whitespace use existing read owners.
# shellcheck disable=SC2030,SC2031,SC2317,SC2329 # isolated projections and presentation sinks
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-edge
T=$(t_tmp)
c_session
C_FIX=$(t_variant linux-omarchy-installed)
: >"$C_FIX/root/proc/device-tree/model"
c_run snapshot "scope	name=journey"
assert_eq "$(c_admits snapshot)" ok 'unknown identity has a schema-valid representation'
assert_contains "$C_OUT" 'key=machine.model	label=Model	value=unknown	state=unknown' 'missing model remains explicitly unknown'
assert_eq "$C_ERR" '' 'unknown identity clean stderr'
# The fixture's root identity selects the upstream status read, never sudo.
printf '0\n' >"$C_FIX/cmd/id_u"
printf 'first\n\nlast\n\n' >"$C_FIX/cmd/setup_status"
mkdir -p "$T/base" "$T/tmp"
git -C "$REPO" archive 2edb76a7de3f78ec90927ac93d5eec3a84636253 | tar -x -C "$T/base" || exit 1
for mode in base dataset; do
  tree=$REPO
  [ "$mode" != base ] || tree=$T/base
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$T/home" TMPDIR="$T/tmp" \
    OMB_STATE_DIR="$T/state" OMB_FIXTURE="$C_FIX" G2_CANDIDATE="$REPO" G2_PROBES="$T/$mode.probes" \
    "$T_BASH" "$TESTS_DIR/gate2-oracle.sh" "$tree" "$mode" >"$T/$mode.out" 2>"$T/$mode.err"
  assert_rc "$?" 0 "$mode upstream read succeeds"
  assert_empty_file "$T/$mode.err" "$mode upstream clean stderr"
done
actual=$(awk -F '\t' '$1 == "guide" || $1 == "code" || ($1 == "row" && $2 == "kind=status")' "$T/dataset.out")
assert_eq "$actual" "$(cat "$T/base.out")" 'upstream internal and trailing blank lines preserved'
# M16-stage-reads: BASE owns the exact status prefix. The added stage reads
# are fixed below, in order: Linux classification, Shared/restore discovery,
# then qualification identity. Verify is not due, so no Doctor read belongs.
cat >"$T/stage.probes" <<'STAGES'
sys_cmd uname_m uname -m
sys_cmd uname_r uname -r
sys_path /proc/device-tree/compatible
sys_path /proc/device-tree/model
sys_path /etc/os-release
sys_cmd findmnt_root findmnt -no SOURCE /
sys_cmd findmnt_root_fstype findmnt -no FSTYPE /
sys_cmd findmnt_boot findmnt -no SOURCE /boot
sys_cmd findmnt_boot_fstype findmnt -no FSTYPE /boot
sys_cmd lsblk_root_type lsblk -no TYPE /dev/mapper/root
sys_cmd ip_route ip route
sys_cmd id_un id -un
sys_path /var/lib/omarchy-mac-setup/installed
sys_path /usr/share/omarchy/version
sys_path /etc/systemd/system/display-manager.service
sys_path /usr/share/omarchy/version
sys_path /etc/omarchy-mac-setup.conf
sys_path /usr/local/bin/omarchy-mac-setup
sys_cmd unit_active systemctl is-active omarchy-mac-setup.service
sys_path /etc/omarchy-btrfs-migrate.conf
sys_path /var/lib/omarchy/btrfs-migrate-done
sys_cmd lsblk_root_backing lsblk -nsplo NAME,TYPE /dev/mapper/root
sys_cmd luks_dump cryptsetup luksDump /dev/nvme0n1p6
sys_cmd pagesize getconf PAGESIZE
sys_path /etc/vconsole.conf
sys_cmd timezone timedatectl show -p Timezone --value
sys_path /etc/locale.conf
sys_path /etc/fstab
sys_cmd uname_m uname -m
sys_cmd uname_r uname -r
sys_path /proc/device-tree/compatible
sys_path /proc/device-tree/model
sys_path /etc/os-release
sys_cmd findmnt_root findmnt -no SOURCE /
sys_cmd findmnt_root_fstype findmnt -no FSTYPE /
sys_cmd findmnt_boot findmnt -no SOURCE /boot
sys_cmd findmnt_boot_fstype findmnt -no FSTYPE /boot
sys_cmd lsblk_root_type lsblk -no TYPE /dev/mapper/root
sys_cmd ip_route ip route
sys_cmd id_un id -un
sys_path /var/lib/omarchy-mac-setup/installed
sys_path /usr/share/omarchy/version
sys_path /etc/systemd/system/display-manager.service
sys_path /usr/share/omarchy/version
sys_path /etc/omarchy-mac-setup.conf
sys_path /usr/local/bin/omarchy-mac-setup
sys_cmd unit_active systemctl is-active omarchy-mac-setup.service
sys_path /etc/omarchy-btrfs-migrate.conf
sys_path /var/lib/omarchy/btrfs-migrate-done
sys_cmd lsblk_root_backing lsblk -nsplo NAME,TYPE /dev/mapper/root
sys_cmd luks_dump cryptsetup luksDump /dev/nvme0n1p6
sys_cmd pagesize getconf PAGESIZE
sys_path /etc/vconsole.conf
sys_cmd timezone timedatectl show -p Timezone --value
sys_path /etc/locale.conf
sys_path /etc/fstab
STAGES
cat "$T/base.probes" "$T/stage.probes" >"$T/expected.probes"
assert_eq "$(cat "$T/dataset.probes")" "$(cat "$T/expected.probes")" 'M16-stage-reads: BASE probes then exactly the listed offline stage reads'

c_run snapshot "scope	name=journey"
assert_eq "$(c_admits snapshot)" ok 'root fixture upstream snapshot admitted'
assert_eq "$C_ERR" '' 'root fixture upstream stderr empty'
# A hash tool printing a digest and then failing must not produce a success.
mkdir -p "$T/hash-bin"
cat >"$T/hash-bin/shasum" <<'HASH'
#!/bin/sh
case "${3:-}" in */journey) printf '%064d  %s\n' 0 "$3"; exit 1 ;; esac
if [ -x /usr/bin/shasum ]; then exec /usr/bin/shasum "$@"; fi
shift 2
exec sha256sum "$@"
HASH
chmod +x "$T/hash-bin/shasum"
C_PATH="$T/hash-bin:/usr/bin:/bin:/usr/sbin:/sbin" c_run snapshot "scope	name=journey"
assert_eq "$(c_result)" 'error io' 'hash failure refuses even after printing a digest'
assert_eq "$(c_admits snapshot)" ok 'hash failure has an admissible refusal'
assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^fact	')" 0 'hash failure exposes no partial facts'
# Both a small read session and the launcher's action scopes must remain
# offline. The simulation covers the same boundary at the real verify stages.
mkdir -p "$T/tool"
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$REPO/release" "$T/tool/"
printf '\n. %q\n' "$TESTS_DIR/gate2-probe-taps.sh" >>"$T/tool/lib/common.sh"
for fixture in linux-alarm-fresh linux-alarm-offline linux-omarchy-installed linux-shared-ready mac-m1pro-1tb-roomy mac-asahi-complete; do
  case "$fixture" in mac-*) if ! t_plutil 'M16-stage-reads macOS'; then continue; fi ;; esac
  C_FIX=$FIX/$fixture C_HOME=$T/tool C_PATH=''
  for scopes in journey journey,plan,asahi,shared,network,omarchy; do
    : >"$T/snapshot.probes"
    C_ENV="OMB_SESSION_SCOPES=$scopes G2_PROBES=$T/snapshot.probes" c_run snapshot $'scope\tname=journey'
    assert_eq "$(c_result) $C_RC $(c_admits snapshot)" 'done ok 0 ok' "M16-stage-reads: $fixture/$scopes snapshot"
    assert_eq "$(awk '$1=="sys_reachable" || $1=="sys_net" {n++} END {print n+0}' "$T/snapshot.probes")" 0 "M16-stage-reads: $fixture/$scopes has no network probes"
    assert_eq "$(awk -F '\t' '$1=="stage" && $2=="name=verify" {print $3}' "$C_EV")" state=todo "M16-stage-reads: $fixture verify waits for every predecessor"
  done
done
C_HOME=$REPO C_ENV=''

# The minimal machine projection must agree with Doctor's failure-capable
# machine checks, including failures that do not occur in the happy journey.
# The full Doctor's own behaviour and probes remain independently BASE-tested
# by test-gate2-health-proof; no network override or fake success is used.
for fixture in "$T/base/tests/fixtures/"*; do
  [ -d "$fixture/cmd" ] || continue
  case "$(cat "$fixture/cmd/uname_s" 2>/dev/null)" in
    Darwin) if ! t_plutil 'machine projection macOS'; then continue; fi ;;
    Linux) ;;
    *) continue ;;
  esac
  (
    t_load
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    OMB_HOME=$REPO
    # shellcheck source=lib/read.sh
    . "$REPO/lib/read.sh"
    OMB_FIXTURE=$fixture OMB_STATE_DIR=$T/projection-state OMB_INTENT=read OMB_PERSIST=0
    platform_init; state_init
    trap omb_cleanup EXIT
    expected=0
    ui_tag() {
      case "$1:$2" in fail:Network | 'fail:Installer reachable') ;; fail:*) expected=$((expected + 1)) ;; esac
    }
    cmd_doctor >/dev/null 2>/dev/null
    actual=$(journey_verify_failures) || exit 1
    printf '%s %s\n' "$expected" "$actual"
  ) >"$T/projection" 2>"$T/projection.err"
  assert_rc "$?" 0 "M16-stage-reads: ${fixture##*/} machine projection completed"
  read -r expected actual <"$T/projection"
  assert_eq "$actual" "$expected" "M16-stage-reads: ${fixture##*/} matches Doctor's non-network FAILs"
  assert_empty_file "$T/projection.err" "M16-stage-reads: ${fixture##*/} projection stderr"
done
t_done test-gate2-edge
