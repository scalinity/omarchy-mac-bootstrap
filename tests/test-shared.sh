#!/usr/bin/env bash
# Shared storage: the plan record, the codes between the systems, the one
# guarded partition creation on macOS, and the persistent mount on Linux.
# Every rerun must reconcile, never create or format a second time; every
# surprise must stop, never be "repaired".
# shellcheck disable=SC2015,SC2016 # ok/fail always return 0; literal $ in single quotes
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load
echo "test-shared"

U_ROOT=4A7B1C2D-0006-4E5F-8A9B-000000000006
U_SHARED=4A7B1C2D-0007-4E5F-8A9B-000000000007
choices='\n\n\n\n\n\n\n\n\n\n'

# --- The codes ------------------------------------------------------------------------
c=$(code_make ombdone 1a2b3c4d "$U_ROOT")
code_parse ombdone "$c"
assert_rc $? 0 "a completion code parses"
assert_eq "$CODE_PLAN $CODE_ID12" "1a2b3c4d 4a7b1c2d0006" "it carries the plan and root's GUID prefix"
code_parse ombdone "$(printf '%s' "$c" | tr 6 7)" 2>/dev/null
assert_rc $? 1 "a mistyped code fails its check digits"
code_parse ombshare "$c"
assert_rc $? 1 "a completion code is not a Shared code"
code_parse ombdone "$(printf '%s' "$c" | tr 'a-f' 'A-F')"
assert_rc $? 0 "codes are read case-insensitively"
for bad in '' 'ombdone-1a2b3c4d' 'ombdone-1a2b3c4d-4a7b1c2d0006-zzzz' 'ombdone-1a2b3c4d-4a7b1c2d0006-9acb;reboot' '$(reboot)'; do
  code_parse ombdone "$bad"
  assert_rc $? 1 "rejected code: '$bad'"
done

# --- The resume token carries Shared, the developer choice and the plan -------------------
CFG_enc=1 CFG_user=alex CFG_host=m1pro CFG_kmap=us CFG_tz=UTC CFG_loc=en_US.UTF-8 CFG_ssh=0 CFG_gh="" CFG_linux=250 CFG_shared=150 CFG_dev=1 CFG_plan=1a2b3c4d
tok=$(token_encode)
assert_eq "$tok" "omb2:enc=1,user=alex,host=m1pro,kmap=us,tz=UTC,loc=en_US.UTF-8,ssh=0,linux=250,shared=150,dev=1,plan=1a2b3c4d" "an omb2 token"
unset CFG_shared CFG_plan CFG_dev
token_decode "$tok"
assert_eq "$CFG_shared $CFG_dev $CFG_plan" "150 1 1a2b3c4d" "Shared, dev and plan cross the reboot"
unset CFG_shared
token_decode "omb1:enc=1,user=alex,host=m1pro,kmap=us,linux=250"
assert_rc $? 0 "an omb1 token is still read"
token_decode "omb2:user=alex,plan=NOTHEX00,shared=010"
assert_contains "$TOKEN_WARNINGS" "ignored plan" "a malformed plan digest is ignored"
assert_contains "$TOKEN_WARNINGS" "ignored shared" "a leading-zero size is ignored"

if t_plutil "the macOS Shared plan and creation"; then
  # --- The plan record ---------------------------------------------------------------------
  sd=$(t_tmp)
  T_ENV="OMB_STATE_DIR=$sd" t_cli mac-m1pro-1tb-roomy "\n4\n\n$choices" plan
  assert_contains "$T_OUT" "Plan saved" "a plan with 150 GB Shared saves"
  intent=$(cat "$sd/shared-intent.env")
  assert_contains "$intent" "schema=omb-shared-intent/1" "the record is versioned"
  assert_contains "$intent" "shared_request=150000000000" "it holds the Shared request in bytes"
  assert_contains "$intent" "region_succ=4A7B1C2D-0003-4E5F-8A9B-000000000003" "and the partition after the region"
  digest=$(sed -n 's/^digest=//p' "$sd/shared-intent.env" | cut -c1-8)
  assert_contains "$(cat "$sd/state.env")" "cfg_plan=$digest" "the plan digest is saved for the token"
  # The post-install fixture is exactly what the plan's answers produce.
  VS=$(plist_get "$(cat "$FIX/mac-shared-reserved/cmd/diskutil_info_disk0s2")" Size)
  assert_contains "$intent" "macos_after=$VS" "the planner and the installed fixture agree on macOS's new size"
  T_ENV="OMB_STATE_DIR=$sd" t_cli mac-m1pro-1tb-roomy "" status
  assert_contains "$T_OUT" "plan=$digest" "the resume token names the plan"
  assert_contains "$T_OUT" "reserved" "before Asahi, Shared is reserved"
  T_ENV="OMB_STATE_DIR=$sd" t_cli mac-shared-reserved "" shared
  assert_contains "$T_OUT" "awaiting-linux-completion" "after Asahi, Shared waits for Linux"
  assert_eq "$(t_snapshot "$sd")" "$(t_snapshot "$sd")" "shared status reads only"

  # fresh_state — a state directory holding the plan above.
  fresh_state() {
    local d
    d=$(t_tmp)
    cp -p "$sd/state.env" "$sd/shared-intent.env" "$d/"
    printf '%s' "$d"
  }
  done_code=$(code_make ombdone "$digest" "$U_ROOT")
  share_code=$(code_make ombshare "$digest" "$U_SHARED")

  # A record that was edited, or from another version, is not a plan.
  d=$(fresh_state)
  sed -i.bak 's/^shared_request=150000000000$/shared_request=15000000000/' "$d/shared-intent.env" && rm -f "$d/shared-intent.env.bak"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "" shared
  assert_contains "$T_OUT" "blocked" "an edited record blocks"
  assert_contains "$T_OUT" "changed after it was written" "and says why"
  d=$(fresh_state)
  printf 'extra=1\n' >>"$d/shared-intent.env"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "" shared
  assert_contains "$T_OUT" "line this tool did not write" "an unknown field blocks"

  # --- Creating it: the codes, the gates, the command, the check afterwards -----------------
  d=$(fresh_state)
  T_ENV="OMB_STATE_DIR=$d OMB_TEST_AFTER=$FIX/mac-shared-created" t_cli mac-shared-reserved "nope\n$(code_make ombdone deadbeef "$U_ROOT")\n$(code_make ombdone "$digest" 4A7B1C2D-0009-4E5F-8A9B-000000000009)\n$done_code\nyes\ncreate\n" shared create
  flat=$(t_flat "$T_OUT")
  assert_contains "$flat" "not a completion code, or a character was mistyped" "a wrong code is refused"
  assert_contains "$flat" "belongs to a different plan" "a code from another plan is refused"
  assert_contains "$flat" "made on a different Linux partition" "a code from another root is refused"
  assert_contains "$flat" "completion code matches this disk" "the right code is accepted"
  assert_contains "$T_OUT" "Partition before    disk0s6" "the partition before is shown"
  assert_contains "$T_OUT" "Partition after     disk0s3" "the partition after is shown"
  assert_eq "$(cat "$T_DIR/record")" "sudo diskutil addPartition disk0s6 ExFAT Shared $(( (150000000000 + 1048575) / 1048576 * 1048576 ))" \
    "exactly one command: addPartition after the Linux root, the planned size in whole MiB"
  assert_contains "$flat" "Shared storage created: disk0s7" "the result is checked and reported"
  st=$(cat "$d/state.env")
  assert_contains "$st" "shared_uuid=$U_SHARED" "its GUID is recorded"
  assert_contains "$st" "shared_mount=/Volumes/Shared" "and where macOS mounted it"
  assert_contains "$T_OUT" "$share_code" "Linux's code is shown"
  assert_empty_file "$T_DIR/shims.log" "no real disk command"

  # Rerun on the created disk: nothing is created again.
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-created "yes\ncreate\n" shared create
  assert_empty_file "$T_DIR/record" "a rerun creates nothing"
  assert_contains "$(t_flat "$T_OUT")" "Shared storage is in place" "a rerun reports what is there"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-created "yes\ncreate\n"
  assert_empty_file "$T_DIR/record" "the guided flow on the created disk creates nothing"
  # Created, but the state write was lost: reconciled, not recreated.
  d=$(fresh_state)
  printf 'shared_linux_done=%s\n' "$done_code" >>"$d/state.env"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-created "yes\ncreate\n" shared create
  assert_empty_file "$T_DIR/record" "a partition that exists but was not recorded is not created again"
  assert_contains "$(t_flat "$T_OUT")" "was not recorded" "it is found and recorded"
  assert_contains "$(cat "$d/state.env")" "shared_uuid=$U_SHARED" "and its GUID recorded"

  # with_receipt — a state directory with Linux's completion code accepted.
  with_receipt() {
    local r
    r=$(fresh_state)
    printf 'shared_linux_done=%s\n' "$done_code" >>"$r/state.env"
    printf '%s' "$r"
  }
  # The typed gates hold, and a failed command leaves a retryable state.
  d=$(with_receipt)
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "\n\n\n" shared create
  assert_empty_file "$T_DIR/record" "Enter at the gates creates nothing"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "yes\nCREATE\nn\n" shared create
  assert_empty_file "$T_DIR/record" "the wrong word creates nothing"
  T_ENV="OMB_STATE_DIR=$d OMB_TEST_RC=1" t_cli mac-shared-reserved "yes\ncreate\n" shared create
  assert_rc "$T_RC" 1 "a failed diskutil stops"
  assert_contains "$(t_flat "$T_OUT")" "no partition was created. The disk is as it was; it is safe to try again" "and says it is safe to retry"
  assert_not_contains "$(cat "$d/state.env")" "shared_uuid=" "nothing is recorded as created"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "yes\ncreate\n" shared create --dry-run
  assert_contains "$T_OUT" "would run  sudo diskutil addPartition disk0s6 ExFAT Shared" "a dry run shows the command"
  assert_empty_file "$T_DIR/record" "a dry run creates nothing"
  # On battery below half: stop before the gates.
  fx=$(t_variant mac-shared-reserved)
  printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t21%%; discharging; 2:10 remaining present: true\n" >"$fx/cmd/pmset_batt"
  T_ENV="OMB_STATE_DIR=$d" t_cli "$fx" "yes\ncreate\n" shared create
  assert_contains "$T_OUT" "on battery at 21%" "low battery stops the change"
  assert_empty_file "$T_DIR/record" "nothing runs on low battery"
  # The record that must precede the change cannot be written: fail closed.
  d=$(with_receipt)
  chmod 500 "$d"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "yes\ncreate\n" shared create
  chmod 700 "$d"
  assert_empty_file "$T_DIR/record" "an unrecordable change does not happen"

  # --- What the disk may look like, and what stops -----------------------------------------
  # variant CHANGE... — a copy of the reserved disk changed by sed scripts on
  # "FILE:SCRIPT" pairs; prints its path.
  variant() {
    local base=$1 fx pair
    shift
    fx=$(t_variant "$base")
    for pair in "$@"; do
      sed -i.bak "${pair#*:}" "$fx/cmd/${pair%%:*}" && rm -f "$fx/cmd/${pair%%:*}.bak"
    done
    printf '%s' "$fx"
  }
  expect_blocked() { # LABEL FIXTURE PHRASE [AFTER]
    local d
    d=$(with_receipt)
    T_ENV="OMB_STATE_DIR=$d${4:+ OMB_TEST_AFTER=$4}" t_cli "$2" "yes\ncreate\n" shared create
    assert_contains "$(t_flat "$T_OUT")" "$3" "$1"
    [ -n "${4:-}" ] || assert_empty_file "$T_DIR/record" "$1: nothing runs"
    assert_not_contains "$(cat "$d/state.env")" "shared_uuid=" "$1: nothing recorded as created"
  }
  ROOTS=$(plist_get "$(cat "$FIX/mac-shared-reserved/cmd/diskutil_info_disk0s6")" Size)
  # The region smaller than reserved: the Linux root grew into it.
  fx=$(variant mac-shared-reserved "diskutil_info_disk0s6:s#<integer>$ROOTS</integer>#<integer>$((ROOTS + 60000000000 / 4096 * 4096))</integer>#" \
    "diskutil_list_disk0:s#<integer>$ROOTS</integer>#<integer>$((ROOTS + 60000000000 / 4096 * 4096))</integer>#")
  expect_blocked "undersized region" "$fx" "smaller than the 150 GB reserved"
  # A partition inserted in the region.
  fx=$(t_variant mac-shared-created)
  sed -i.bak 's#Microsoft Basic Data#Apple_HFS#g' "$fx/cmd/diskutil_list_disk0" "$fx/cmd/diskutil_info_disk0s7" && rm -f "$fx/cmd/"*.bak
  expect_blocked "a foreign partition where Shared goes" "$fx" "unexpected partition (disk0s7, Apple_HFS) follows the Linux root"
  # The partition there is exFAT's type but not formatted (an interrupted create).
  fx=$(t_variant mac-shared-created)
  sed -i.bak 's#<key>FilesystemType</key><string>exfat</string>##' "$fx/cmd/diskutil_info_disk0s7" && rm -f "$fx/cmd/"*.bak
  expect_blocked "an unformatted partition in the region" "$fx" "never formats a partition that exists"
  # Wrong filesystem.
  fx=$(variant mac-shared-created "diskutil_info_disk0s7:s#<string>exfat</string>#<string>msdos</string>#")
  expect_blocked "wrong filesystem" "$fx" "filesystem: msdos"
  # The Linux root is a different partition from the one Linux vouched for.
  fx=$(variant mac-shared-reserved "diskutil_info_disk0s6:s#4A7B1C2D-0006#4A7B1C2D-000A#" "diskutil_list_disk0:s#4A7B1C2D-0006#4A7B1C2D-000A#")
  d=$(with_receipt)
  T_ENV="OMB_STATE_DIR=$d" t_cli "$fx" "$done_code\n\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "made on a different Linux partition" "a replaced Linux root voids the completion code"
  assert_empty_file "$T_DIR/record" "a replaced Linux root: nothing runs"
  # An Apple partition moved.
  fx=$(variant mac-shared-reserved "diskutil_info_disk0s3:s#000000000003#00000000000B#" "diskutil_list_disk0:s#000000000003#00000000000B#")
  expect_blocked "Apple's recovery replaced" "$fx" "Apple system partition is not where the plan found it"
  # diskutil list and info disagree.
  fx=$(variant mac-shared-reserved "diskutil_list_disk0:s#<integer>$ROOTS</integer>#<integer>$((ROOTS - 4096))</integer>#")
  expect_blocked "the two views of the partition map disagree" "$fx" "could not be read exactly"

  # After addPartition: anything but one new exFAT partition in the region stops.
  fx=$(variant mac-shared-created "diskutil_info_disk0s7:s#<string>exfat</string>#<string>msdos</string>#")
  expect_blocked "the new partition has the wrong filesystem" mac-shared-reserved "not the exFAT volume planned" "$fx"
  fx=$(variant mac-shared-created "diskutil_info_disk0s3:s#000000000003#00000000000B#" "diskutil_list_disk0:s#000000000003#00000000000B#")
  expect_blocked "an existing partition changed during the create" mac-shared-reserved "an existing partition changed" "$fx"
  d=$(with_receipt)
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "yes\ncreate\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "reported success, but no new partition is on the disk" "success with no new partition is not believed"

  # A partition entry diskutil lists but this tool cannot read: the rest of
  # the map is never taken for free space.
  fx=$(variant mac-shared-reserved "diskutil_list_disk0:s#<key>Content</key><string>EFI</string>##")
  expect_blocked "a partition entry without Content" "$fx" "diskutil lists 6 partitions on disk0, and 3 could be read"
  # A key the parser would otherwise hand to eval is not a field.
  d=$(fresh_state)
  sed -i.bak 's/^mode=/mode macos_after=/' "$d/shared-intent.env" && rm -f "$d/shared-intent.env.bak"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "" shared
  assert_contains "$T_OUT" "line this tool did not write" "a key with a space is refused"
  assert_not_contains "$T_OUT" "command not found" "and never evaluated"
  # A dry run with the completion code typed in shows the exact command: the
  # code counts for the run although nothing is recorded.
  d=$(fresh_state)
  before=$(t_snapshot "$d")
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "$done_code\nyes\ncreate\n" shared create --dry-run
  assert_contains "$T_OUT" "would run  sudo diskutil addPartition disk0s6 ExFAT Shared $(( (150000000000 + 1048575) / 1048576 * 1048576 ))" "a dry run with a typed code shows the command"
  assert_not_contains "$(t_flat "$T_OUT")" "The disk changed since it was shown" "the typed code survives the re-read"
  assert_empty_file "$T_DIR/record" "a dry run with a typed code creates nothing"
  assert_eq "$(t_snapshot "$d")" "$before" "and records nothing"
  # The free region is larger than planned (Linux was made smaller): Shared
  # keeps its planned size, and the difference is pointed out.
  fx=$(variant mac-shared-reserved "diskutil_info_disk0s6:s#<integer>$ROOTS</integer>#<integer>$((ROOTS - 10000000000 / 4096 * 4096))</integer>#" \
    "diskutil_list_disk0:s#<integer>$ROOTS</integer>#<integer>$((ROOTS - 10000000000 / 4096 * 4096))</integer>#")
  d=$(with_receipt)
  T_ENV="OMB_STATE_DIR=$d" t_cli "$fx" "\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "earlier than planned" "a smaller Linux root is pointed out"
  assert_contains "$T_OUT" "sudo diskutil addPartition disk0s6 ExFAT Shared $(( (150000000000 + 1048575) / 1048576 * 1048576 ))" "and Shared keeps its planned size"
fi

# --- Linux: the completion code, and activation ----------------------------------------------
t_cli linux-shared-absent "n\n"
code=$(printf '%s\n' "$T_OUT" | grep -oE 'ombdone-[0-9a-f]{8}-[0-9a-f]{12}-[0-9a-f]{4}' | head -1)
assert_eq "$code" "$(code_make ombdone 1a2b3c4d "$U_ROOT")" "Linux shows the completion code for its plan and root"
fx=$(t_variant linux-shared-absent)
sed -i.bak '/^cfg_plan=/d' "$fx/root/var/lib/omarchy-mac-bootstrap/state.env" && rm -f "$fx/root/var/lib/omarchy-mac-bootstrap/state.env.bak"
t_cli "$fx" "n\n"
assert_contains "$(t_flat "$T_OUT")" "does not know the Shared plan's code" "without the plan, no code is made up"
fx=$(t_variant linux-omarchy-installed)
mkdir -p "$fx/root/var/lib/omarchy-mac-bootstrap"
printf 'cfg_user=alex\ncfg_enc=1\ncfg_shared=150\ncfg_plan=1a2b3c4d\n' >"$fx/root/var/lib/omarchy-mac-bootstrap/state.env"
printf 'WANT_ENCRYPT=1\n' >"$fx/root/etc/omarchy-btrfs-migrate.conf"
t_cli "$fx" "n\n"
assert_not_contains "$T_OUT" "ombdone-" "no completion code while the encryption is still migrating"
# The completion code needs encryption positively finished. Read as root, the
# header decides; one that could not be read never counts as finished, even
# with the finish marker there. rc_case UID SETUP prints the code shown, if any.
rc_case() {
  local fx sd
  fx=$(t_variant linux-shared-absent)
  printf '%s\n' "$1" >"$fx/cmd/id_u"
  (cd "$fx" && eval "$2")
  sd=$(t_tmp)
  cp "$fx/root/var/lib/omarchy-mac-bootstrap/state.env" "$sd/"
  chmod 600 "$sd/state.env"
  T_ENV="OMB_STATE_DIR=$sd" t_cli "$fx" "n\n"
  printf '%s\n' "$T_OUT" | grep -oE 'ombdone-[0-9a-f]{8}-[0-9a-f]{12}-[0-9a-f]{4}' | head -1
}
assert_eq "$(rc_case 0 :)" "$(code_make ombdone 1a2b3c4d "$U_ROOT")" "as root, a clean LUKS2 header gives the completion code"
for c in "cryptsetup failing|echo 1 >cmd/luks_dump.rc" "cryptsetup missing|rm -f cmd/luks_dump" "no output|: >cmd/luks_dump" \
  "output that is not a header|printf 'Device is not a valid LUKS device.\\n' >cmd/luks_dump" \
  "no partition under root|printf '/dev/mapper/root crypt\\n' >cmd/lsblk_root_backing" \
  "still re-encrypting, marker present|printf 'Requirements:\\tonline-reencrypt-v2\\n' >>cmd/luks_dump"; do
  assert_eq "$(rc_case 0 "${c#*|}")" "" "as root, no completion code: ${c%%|*}"
done
assert_eq "$(rc_case 1000 'rm -f root/var/lib/omarchy/btrfs-migrate-done')" "" "as a user, no completion code without the finish marker"

share=$(code_make ombshare 1a2b3c4d "$U_SHARED")
T_ENV="OMB_TEST_AFTER=$FIX/linux-shared-ready" t_cli linux-shared-present "$share\nmount\n" shared activate
rec=$(cat "$T_DIR/record")
assert_eq "$(printf '%s\n' "$rec" | sed "s#$T_DIR/tmp/omarchy-bootstrap\.[A-Za-z0-9]*#TMP#")" "sudo install -d -m 0755 -o root -g root /mnt/shared
sudo cp -p /etc/fstab /etc/fstab.omarchy-bootstrap.bak
sudo install -m 0644 -o root -g root TMP/fstab /etc/fstab.omarchy-bootstrap.new
sudo mv -f /etc/fstab.omarchy-bootstrap.new /etc/fstab
sudo systemctl daemon-reload
sudo systemctl start mnt-shared.automount" "activation: exactly the mount point, the managed fstab, reload, automount"
assert_contains "$T_OUT" "Shared storage mounts at /mnt/shared on every boot" "activation checks the result"
assert_contains "$(cat "$T_DIR/state/state.env")" "shared_partuuid=4a7b1c2d-0007-4e5f-8a9b-000000000007" "the PARTUUID is recorded"
# The fstab it would install: the old lines kept, one managed entry by PARTUUID.
sd=$(t_tmp)
(
  OMB_FIXTURE=$FIX/linux-shared-present OMB_STATE_DIR=$sd OMB_UID=1000 OMB_PLATFORM=linux
  state_init
  lx_detect
  cfg_load "$(sys_path /var/lib/omarchy-mac-bootstrap/state.env)"
  state_set shared_id12 4a7b1c2d0007
  SH_UID=1000 SH_GID=1000
  shared_lx_state
  printf '%s\n%s\n' "$SHARED_STATE" "$(shared_fstab_line)"
) >"$sd/out" 2>&1
assert_eq "$(head -1 "$sd/out")" awaiting-linux-activation "with the code recorded, the partition is identified"
assert_eq "$(sed -n 2p "$sd/out")" "PARTUUID=4a7b1c2d-0007-4e5f-8a9b-000000000007 /mnt/shared exfat rw,nofail,x-systemd.automount,x-systemd.device-timeout=10s,uid=1000,gid=1000,fmask=0177,dmask=0077,nodev,nosuid,noexec 0 0" \
  "the managed entry: lowercase PARTUUID, nofail automount, the user's ids, nothing runs"
# uid 1001: the everyday user's ids, not a guess.
t_cli linux-shared-uid1001 "$share\nmount\n" shared activate
assert_contains "$T_OUT" "uid 1001, gid 1001" "the everyday user's ids are used"
assert_contains "$(cat "$T_DIR"/tmp/omarchy-bootstrap.*/fstab 2>/dev/null)" "" "the scratch file is removed at exit"
# Repeated: already set up, nothing runs.
t_cli linux-shared-ready "" shared activate
assert_contains "$T_OUT" "already set up" "activation is idempotent"
assert_empty_file "$T_DIR/record" "a repeated activation runs nothing"
# Conflicts, the wrong filesystem, the wrong code: stop.
t_cli linux-shared-conflict "$share\nmount\n" shared activate
assert_contains "$(t_flat "$T_OUT")" "already has an entry" "a conflicting fstab entry is refused"
assert_empty_file "$T_DIR/record" "a conflicting fstab entry: nothing runs"
t_cli linux-shared-wrong-fs "$share\nmount\n" shared activate
assert_contains "$(t_flat "$T_OUT")" "never formats a partition that exists" "the wrong filesystem is refused, never formatted"
assert_empty_file "$T_DIR/record" "the wrong filesystem: nothing runs"
t_cli linux-shared-present "$(code_make ombshare 1a2b3c4d 4A7B1C2D-0009-4E5F-8A9B-000000000009)\nmount\n" shared activate
assert_contains "$(t_flat "$T_OUT")" "No Basic Data partition right after the Linux root has that GUID" "a code naming another partition is refused"
assert_empty_file "$T_DIR/record" "the wrong PARTUUID: nothing runs"
assert_not_contains "$(cat "$T_DIR/state/state.env" 2>/dev/null)" "shared_id12=" "and a code naming nothing here is never saved"
t_cli linux-shared-present "$(code_make ombshare 99999999 "$U_SHARED")\n\n" shared activate
assert_contains "$T_OUT" "belongs to a different plan" "a code from another plan is refused"
# A saved code that names nothing on this disk asks again instead of locking
# activation out.
d=$(t_tmp)
printf 'shared_id12=4a7b1c2d0009\n' >"$d/state.env"
chmod 600 "$d/state.env"
T_ENV="OMB_STATE_DIR=$d" t_cli linux-shared-present "$share\nmount\n" shared activate
assert_contains "$(t_flat "$T_OUT")" "names no partition here" "a stale saved code is set aside"
assert_contains "$(cat "$T_DIR/record")" "sudo mv -f /etc/fstab.omarchy-bootstrap.new /etc/fstab" "and the right code typed then activates"
assert_contains "$(cat "$d/state.env")" "shared_id12=4a7b1c2d0007" "the right code replaces it"
# /etc/fstab this tool cannot read is never replaced.
fx=$(t_variant linux-shared-present)
chmod 000 "$fx/root/etc/fstab"
t_cli "$fx" "$share\nmount\n" shared activate
chmod 644 "$fx/root/etc/fstab"
assert_contains "$(t_flat "$T_OUT")" "/etc/fstab cannot be read here" "an unreadable fstab blocks"
assert_empty_file "$T_DIR/record" "an unreadable fstab: nothing runs"
# Entries for the same partition in other spellings are still conflicts.
fx=$(t_variant linux-shared-present)
printf 'PARTUUID=4A7B1C2D-0007-4E5F-8A9B-000000000007 /media/shared exfat defaults 0 0\n' >>"$fx/root/etc/fstab"
t_cli "$fx" "$share\nmount\n" shared activate
assert_contains "$(t_flat "$T_OUT")" "already has an entry" "an uppercase PARTUUID entry is a conflict"
assert_empty_file "$T_DIR/record" "an uppercase PARTUUID entry: nothing runs"
fx=$(t_variant linux-shared-present)
printf '/dev/nvme0n1p7 /mnt/shared/ exfat defaults 0 0\n' >>"$fx/root/etc/fstab"
t_cli "$fx" "$share\nmount\n" shared activate
assert_contains "$(t_flat "$T_OUT")" "already has an entry" "a device-path entry with a trailing slash is a conflict"
# The marker is ours only with our line under it, and only once.
fx=$(t_variant linux-shared-present)
printf '%s\nLABEL=Shared /mnt/shared exfat defaults 0 0\n' "# omarchy-bootstrap: Shared storage (managed; see ./omarchy-bootstrap shared)" >>"$fx/root/etc/fstab"
t_cli "$fx" "$share\nmount\n" shared activate
assert_contains "$(t_flat "$T_OUT")" "(under this tool's marker)" "a foreign line under the marker is a conflict"
assert_empty_file "$T_DIR/record" "a foreign line under the marker: nothing runs"
fx=$(t_variant linux-shared-ready)
managed=$(tail -2 "$fx/root/etc/fstab")
printf '%s\n' "$managed" >>"$fx/root/etc/fstab"
t_cli "$fx" "" shared
assert_contains "$(t_flat "$T_OUT")" "2 copies of this tool's marker" "a duplicated managed entry is a conflict"
# The conflict inside this tool's own block is reported first, then the rest
# in file order, each once, whatever the locale: glibc's en_US.UTF-8 collation
# ignores punctuation, so a sorted list led with "LABEL=..." on Linux only.
fx=$(t_variant linux-shared-present)
printf '%s\nLABEL=Shared /mnt/shared exfat defaults 0 0\nLABEL=Shared /mnt/shared exfat defaults 0 0\n' "$SHARED_FSTAB_MARK" >>"$fx/root/etc/fstab"
for loc in C C.UTF-8 en_US.UTF-8; do
  got=$(
    export LC_ALL=$loc
    OMB_FIXTURE=$fx SH_UID=1000 SH_GID=1000 SH_PARTUUID="" SH_FSUUID="" SH_NAME=""
    shared_fstab_scan
    printf '%s' "$FS_CONFLICTS"
  ) 2>/dev/null
  assert_eq "$got" "(under this tool's marker) LABEL=Shared /mnt/shared exfat defaults 0 0
LABEL=Shared /mnt/shared exfat defaults 0 0" "LC_ALL=$loc: this tool's block first, then file order, each once"
done
fx=$(t_variant linux-shared-present)
mkdir -p "$fx/root/mnt/shared"
printf 'x\n' >"$fx/root/mnt/shared/stray-file"
t_cli "$fx" "$share\nmount\n" shared activate
assert_contains "$(t_flat "$T_OUT")" "already holds files; mounting over them would hide them" "files under the mount point are never hidden"
assert_empty_file "$T_DIR/record" "files under the mount point: nothing runs"
fx=$(t_variant linux-shared-present)
printf '0\n' >"$fx/cmd/id_u"
T_ENV="" t_cli "$fx" "$share\nmount\n" shared activate
assert_contains "$T_OUT" "Run this as your everyday user" "root's ids are never used for the mount"
t_cli linux-shared-present "$share\nmount\n" shared activate --dry-run
assert_contains "$T_OUT" "would run  sudo mv -f /etc/fstab.omarchy-bootstrap.new /etc/fstab" "a dry run shows the fstab change"
assert_eq "$(ls -A "$T_DIR/state" 2>/dev/null)" "" "a dry run records nothing"
t_cli linux-shared-present "" shared create
assert_rc "$T_RC" 2 "create is macOS's"

# --- Linux: status, doctor and the write test ----------------------------------------------------
t_cli linux-shared-ready "" doctor
for w in "[PASS] Shared storage" "[PASS] Shared identity" "[PASS] Shared on boot" "[PASS] Shared mounted" "[INFO] Shared writing"; do
  assert_contains "$T_OUT" "$w" "doctor: $w"
done
fx=$(t_variant linux-shared-ready)
printf '/dev/mapper/root / btrfs rw 0 0\n/dev/nvme0n1p7 /mnt/shared exfat ro,nodev,nosuid,noexec,uid=1000 0 0\n/dev/nvme0n1p7 /run/media/alex/Shared exfat rw 0 0\n' >"$fx/root/proc/self/mounts"
t_cli "$fx" "" doctor
assert_contains "$T_OUT" "[WARN] Shared mounted" "doctor: a read-only remount after an error warns"
assert_contains "$T_OUT" "[WARN] Shared mounted twice" "doctor: a second mount of the same partition warns"
t_cli linux-shared-conflict "" doctor
assert_contains "$T_OUT" "[FAIL] Shared storage" "doctor: a conflict fails"
t_cli linux-shared-ready "\n" shared test
assert_empty_file "$T_DIR/record" "the write test needs consent"
t_cli linux-shared-ready "test\n" shared test
rec=$(cat "$T_DIR/record")
assert_contains "$rec" "cp $T_DIR/tmp/omarchy-bootstrap." "the write test copies one file"
assert_contains "$rec" "/mnt/shared/.omarchy-bootstrap-test-" "to a uniquely named file on Shared"
assert_contains "$rec" "rm -f /mnt/shared/.omarchy-bootstrap-test-" "and removes only that file"
t_cli linux-shared-present "" shared test
assert_contains "$T_OUT" "nothing to test yet" "no test before Shared is mounted"
t_cli linux-shared-ready "" shared
assert_contains "$T_OUT" "ready" "shared status on Linux"
assert_eq "$(ls -A "$T_DIR/state" 2>/dev/null)" "" "shared status records nothing"

t_done test-shared
