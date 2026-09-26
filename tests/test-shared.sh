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
  assert_eq "$(cat "$T_DIR/record")" "sudo -v
sudo -n diskutil addPartition disk0s6 ExFAT Shared $(( (150000000000 + 1048575) / 1048576 * 1048576 ))" \
    "sudo authenticates first; then exactly one change: addPartition after the Linux root, the planned size in whole MiB"
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
  # sudo -v succeeds, and by the time of the change sudo's authorization has
  # run out: sudo -n refuses (exit 1) without running diskutil, and never
  # asks again after the disk was checked. OMB_TEST_RC belongs to the command
  # after sudo -v, which is the one recorded as sudo -n.
  T_ENV="OMB_STATE_DIR=$d OMB_TEST_RC=1" t_cli mac-shared-reserved "yes\ncreate\n" shared create
  assert_rc "$T_RC" 1 "sudo -n refusing stops the creation"
  assert_eq "$(cat "$T_DIR/record")" "sudo -v
sudo -n diskutil addPartition disk0s6 ExFAT Shared $(( (150000000000 + 1048575) / 1048576 * 1048576 ))" "the change is only ever asked of sudo -n, which cannot prompt"
  assert_contains "$(t_flat "$T_OUT")" "no partition was created; the disk is as it was. Either diskutil reported an error, or sudo's authorization had run out and sudo -n refused" "it says what may have happened"
  assert_contains "$(t_flat "$T_OUT")" "Run ./omarchy-bootstrap shared create again: it asks sudo first, reads the disk again and checks everything before creating" "and that a retry starts from the gates"
  assert_not_contains "$(cat "$d/state.env")" "shared_uuid=" "nothing is recorded as created"
  [ ! -e "$d/shared-create.env" ] && ok || fail "a creation that did not run leaves no creation record"
  assert_empty_file "$T_DIR/shims.log" "no real sudo or diskutil ran"
  # The retry goes through the whole guarded path again, then creates.
  T_ENV="OMB_STATE_DIR=$d OMB_TEST_AFTER=$FIX/mac-shared-created" t_cli mac-shared-reserved "yes\ncreate\n" shared create
  assert_eq "$(cat "$T_DIR/record")" "sudo -v
sudo -n diskutil addPartition disk0s6 ExFAT Shared $(( (150000000000 + 1048575) / 1048576 * 1048576 ))" "the retry authenticates again before the change"
  assert_contains "$(t_flat "$T_OUT")" "Shared storage created: disk0s7" "and completes"
  # The disk changes after sudo -v, before the last read: nothing is created.
  d=$(with_receipt)
  rec=$(t_tmp)/record
  : >"$rec"
  moved=$(t_variant mac-shared-reserved)
  sed -i.bak 's#000000000003#00000000000B#' "$moved/cmd/diskutil_info_disk0s3" "$moved/cmd/diskutil_list_disk0" && rm -f "$moved/cmd/"*.bak
  out=$(
    OMB_FIXTURE=$FIX/mac-shared-reserved OMB_STATE_DIR=$d
    state_init
    mac_survey
    shared_mac_state
    # shellcheck disable=SC2317,SC2329 # called by shared_create_flow
    run() { printf '%s\n' "$*" >>"$rec"; [ "$*" = "sudo -v" ] && OMB_FIXTURE=$moved; return 0; }
    printf 'yes\ncreate\n' | shared_create_flow
  )
  assert_eq "$(cat "$rec")" "sudo -v" "a disk that changes after sudo -v: nothing runs after it"
  assert_contains "$(t_flat "$out")" "The disk changed since it was shown" "and it says so"
  [ ! -e "$d/shared-create.env" ] && ok || fail "and no creation is recorded"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "yes\ncreate\n" shared create --dry-run
  assert_contains "$T_OUT" "would run  sudo -n diskutil addPartition disk0s6 ExFAT Shared" "a dry run shows the command"
  assert_empty_file "$T_DIR/record" "a dry run creates nothing"
  # On battery below half: stop before the gates.
  fx=$(t_variant mac-shared-reserved)
  printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t21%%; discharging; 2:10 remaining present: true\n" >"$fx/cmd/pmset_batt"
  T_ENV="OMB_STATE_DIR=$d" t_cli "$fx" "yes\ncreate\n" shared create
  assert_contains "$T_OUT" "on battery at 21%" "low battery stops the change"
  assert_empty_file "$T_DIR/record" "nothing runs on low battery"
  # No power report at all: said to be unverified, never passed off as checked.
  fx=$(t_variant mac-shared-reserved)
  : >"$fx/cmd/pmset_batt"
  T_ENV="OMB_STATE_DIR=$d" t_cli "$fx" "yes\ncreate\n" shared create --dry-run
  assert_contains "$T_OUT" "Power state unverified: pmset reported nothing" "an empty power report is unverified"
  assert_contains "$T_OUT" "would run  sudo -n diskutil addPartition" "and is left to the person, not blocked"
  # The record that must precede the change cannot be written: fail closed.
  d=$(with_receipt)
  chmod 500 "$d"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "yes\ncreate\n" shared create
  chmod 700 "$d"
  assert_eq "$(grep -c addPartition "$T_DIR/record")" 0 "an unrecordable change does not happen"
  # The creation record itself cannot be written: nothing is created.
  d=$(with_receipt)
  rec=$(t_tmp)/record
  : >"$rec"
  out=$(
    OMB_FIXTURE=$FIX/mac-shared-reserved OMB_STATE_DIR=$d OMB_TEST_RECORD=$rec
    state_init
    mac_survey
    shared_mac_state
    # shellcheck disable=SC2317,SC2329 # called by shared_txn_save
    state_put_file() { return 1; }
    printf 'yes\ncreate\n' | shared_create_flow
  )
  assert_contains "$(t_flat "$out")" "Could not record the creation" "an unwritable creation record stops the creation"
  assert_eq "$(grep -c addPartition "$rec")" 0 "and nothing is created"
  # sudo authenticates after the gates and before the last read of the disk;
  # when it does not, nothing is read, recorded or created.
  d=$(with_receipt)
  rec=$(t_tmp)/record
  out=$(
    OMB_FIXTURE=$FIX/mac-shared-reserved OMB_STATE_DIR=$d
    state_init
    mac_survey
    shared_mac_state
    # shellcheck disable=SC2317,SC2329 # called by shared_create_flow
    run() { printf '%s\n' "$*" >>"$rec"; [ "$*" != "sudo -v" ]; }
    # shellcheck disable=SC2317,SC2329 # called by shared_create_flow
    mac_detect_geometry() { printf 'READ AGAIN\n'; }
    printf 'yes\ncreate\n' | shared_create_flow
  )
  assert_eq "$(cat "$rec")" "sudo -v" "a failed sudo -v: nothing runs after it"
  assert_contains "$(t_flat "$out")" "sudo did not authenticate; nothing was created" "and it says so"
  assert_not_contains "$out" "READ AGAIN" "the disk is not read again for a creation that cannot run"
  [ ! -e "$d/shared-create.env" ] && ok || fail "and no creation is recorded"

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

  # The physical target: this Mac's internal disk, the one macOS runs from,
  # the one planned on. An external copy keeps every size, GUID and extent,
  # and Linux's code for its root still matches, so only the target check
  # tells them apart.
  internal_off() {
    local f
    for f in "$1"/cmd/diskutil_info_*; do
      sed -i.bak 's#<key>Internal</key><true/>#<key>Internal</key><false/>#' "$f" && rm -f "$f.bak"
    done
  }
  fx=$(t_variant mac-shared-reserved)
  internal_off "$fx"
  expect_blocked "an external copy of the disk, identical but for Internal" "$fx" "is not reported as internal"
  fx=$(variant mac-shared-reserved 'diskutil_info_root:s#<string>disk0s2</string></dict></array>#<string>disk0s2</string></dict><dict><key>APFSPhysicalStore</key><string>disk5s2</string></dict></array>#')
  expect_blocked "a container on two physical stores" "$fx" "more than one physical store"
  fx=$(variant mac-shared-reserved 'diskutil_info_root:s#<key>APFSPhysicalStores</key><array>.*</array>##')
  expect_blocked "no physical store for macOS" "$fx" "physical disk was not found"
  fx=$(variant mac-shared-reserved 'diskutil_info_root:s#<string>disk0s2</string>#<string>disk0s4</string>#')
  expect_blocked "macOS running from another container" "$fx" "not running from the container the plan was made on"
  fx=$(variant mac-shared-reserved 'diskutil_info_disk0:s#APPLE SSD FIXTURE Media#Portable SSD Media#')
  expect_blocked "another disk with the same layout" "$fx" "not the disk the plan was made on"
  fx=$(variant mac-shared-reserved 'diskutil_info_disk0:s#<key>Internal</key><true/>#<key>Internal</key><false/>#')
  expect_blocked "the whole disk reported external, its store internal" "$fx" "is not reported as internal"
  # A physical store that exists but is not one of this disk's partitions.
  fx=$(variant mac-shared-reserved 'diskutil_info_root:s#<string>disk0s2</string>#<string>disk0s9</string>#')
  cp "$fx/cmd/diskutil_info_disk0s2" "$fx/cmd/diskutil_info_disk0s9"
  expect_blocked "macOS on a store not listed on the disk" "$fx" "not running from the container the plan was made on (disk0s9)"
  # Checked again on the read after the typed gates: a disk that stops
  # reading as internal while they were answered gets nothing created.
  d=$(with_receipt)
  ext=$(t_variant mac-shared-reserved)
  internal_off "$ext"
  rec=$(t_tmp)/record
  : >"$rec"
  out=$(
    OMB_FIXTURE=$FIX/mac-shared-reserved OMB_STATE_DIR=$d OMB_TEST_RECORD=$rec
    state_init
    mac_survey
    shared_mac_state
    # shellcheck disable=SC2317,SC2329 # called by shared_create_flow
    ui_confirm_word() { [ "$1" = create ] && OMB_FIXTURE=$ext; return 0; }
    shared_create_flow </dev/null
  )
  assert_contains "$(t_flat "$out")" "The disk changed since it was shown (the disk macOS runs from (disk0) is not reported as internal" "the target is checked again after the gates"
  assert_eq "$(grep -c addPartition "$rec")" 0 "a target that changed during the gates: nothing created"

  # After addPartition: anything but one new exFAT partition in the region stops.
  fx=$(variant mac-shared-created "diskutil_info_disk0s7:s#<string>exfat</string>#<string>msdos</string>#")
  expect_blocked "the new partition has the wrong filesystem" mac-shared-reserved "not the exFAT volume planned" "$fx"
  fx=$(variant mac-shared-created "diskutil_info_disk0s3:s#000000000003#00000000000B#" "diskutil_list_disk0:s#000000000003#00000000000B#")
  expect_blocked "an existing partition changed during the create" mac-shared-reserved "the result is not what was planned. an Apple system partition is not where the plan found it" "$fx"
  d=$(with_receipt)
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "yes\ncreate\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "reported success, but no new partition is on the disk" "success with no new partition is not believed"
  [ ! -e "$d/shared-create.env" ] && ok || fail "a creation that left nothing leaves no creation record"

  # --- The creation record: every run judges the disk against what the one
  # creation was allowed to produce, until its result is recorded -----------------------
  # Two runs on a disk where the Linux root's identity changed during the
  # create. The first stops; the second, on the same disk, must not read it
  # afresh and take the new partition after the changed root for Shared.
  swapped=$(variant mac-shared-created "diskutil_info_disk0s6:s#4A7B1C2D-0006#4A7B1C2D-000A#" "diskutil_list_disk0:s#4A7B1C2D-0006#4A7B1C2D-000A#")
  d=$(with_receipt)
  T_ENV="OMB_STATE_DIR=$d OMB_TEST_AFTER=$swapped" t_cli mac-shared-reserved "yes\ncreate\n" shared create
  assert_rc "$T_RC" 1 "run 1: a Linux root that changed during the create stops it"
  assert_contains "$(t_flat "$T_OUT")" "a partition that was there before the creation changed: 598191661056|246976348160|$U_ROOT" "run 1: and names what changed"
  [ -f "$d/shared-create.env" ] && ok || fail "run 1: the creation record is kept"
  T_ENV="OMB_STATE_DIR=$d" t_cli "$swapped" "yes\ncreate\n" shared create
  assert_rc "$T_RC" 1 "run 2: still stopped"
  assert_empty_file "$T_DIR/record" "run 2: nothing is created again"
  assert_contains "$(t_flat "$T_OUT")" "did not leave the disk as planned: a partition that was there before the creation changed" "run 2: judged against the creation, not read afresh"
  st=$(cat "$d/state.env")
  assert_not_contains "$st" "shared_uuid=" "run 2: the new partition is not taken for Shared"
  assert_contains "$st" "shared_blocked_reason=" "run 2: the recorded stop stays"
  [ -f "$d/shared-create.env" ] && ok || fail "run 2: the creation record stays"
  T_ENV="OMB_STATE_DIR=$d" t_cli "$swapped" "yes\ncreate\n"
  assert_empty_file "$T_DIR/record" "the guided flow on that disk creates nothing"
  assert_not_contains "$(cat "$d/state.env")" "shared_uuid=" "and records nothing as created"
  T_ENV="OMB_STATE_DIR=$d" t_cli "$swapped" "" shared
  assert_contains "$T_OUT" "blocked" "shared status shows the stop"
  # Without the record (removed by hand), the partition after a root Linux
  # did not vouch for is still not taken for Shared.
  rm -f "$d/shared-create.env"
  T_ENV="OMB_STATE_DIR=$d" t_cli "$swapped" "yes\ncreate\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "completion code for this root is not recorded here" "a partition after an unvouched root is not taken for Shared"
  assert_empty_file "$T_DIR/record" "and nothing is created"
  assert_not_contains "$(cat "$d/state.env")" "shared_uuid=" "and nothing recorded"

  # txn_state — a state directory holding the record a creation writes just
  # before addPartition on the reserved disk, as if the run ended right after.
  txn_state() {
    local r
    r=$(with_receipt)
    (
      OMB_FIXTURE=$FIX/mac-shared-reserved OMB_STATE_DIR=$r
      state_init
      mac_survey
      shared_mac_state
      shared_region
      shared_txn_save
    ) >/dev/null 2>&1
    printf '%s' "$r"
  }
  # Created, and the run stopped before recording it: the record's own check
  # passes, so it is recorded; nothing is created again.
  d=$(txn_state)
  [ -f "$d/shared-create.env" ] && ok || fail "the creation record is written"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-created "yes\ncreate\n" shared create
  assert_empty_file "$T_DIR/record" "a created partition whose success was not recorded is not created again"
  assert_contains "$(t_flat "$T_OUT")" "Recording it now" "it is recorded from the creation's own check"
  assert_contains "$(cat "$d/state.env")" "shared_uuid=$U_SHARED" "with its GUID"
  [ ! -e "$d/shared-create.env" ] && ok || fail "the creation record is removed once the result is recorded"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-created "yes\ncreate\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "Shared storage is in place" "and later runs find it in place"
  assert_empty_file "$T_DIR/record" "creating nothing"
  # Recorded, but the run stopped before removing the creation record: the
  # next run, whose check passes again, removes it.
  d=$(txn_state)
  printf 'shared_uuid=%s\n' "$U_SHARED" >>"$d/state.env"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-created "yes\ncreate\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "Shared storage is in place" "a recorded Shared with its creation record left behind is in place"
  [ ! -e "$d/shared-create.env" ] && ok || fail "and the leftover creation record is removed"
  assert_empty_file "$T_DIR/record" "and nothing is created"
  # Linux's code was lost with state.env, the plan record kept: the code
  # typed again for this root lets the partition be recorded, never created.
  d=$(fresh_state)
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-created "$done_code\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "Recording it now" "a lost completion code, typed again, records the existing Shared partition"
  assert_empty_file "$T_DIR/record" "and nothing is created"
  st=$(cat "$d/state.env")
  assert_contains "$st" "shared_uuid=$U_SHARED" "its GUID is recorded"
  assert_contains "$st" "shared_linux_done=$done_code" "and the code with it"
  d=$(fresh_state)
  T_ENV="OMB_STATE_DIR=$d" t_cli "$swapped" "$done_code\n\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "made on a different Linux partition" "a code for another root does not record the partition after this one"
  assert_empty_file "$T_DIR/record" "and nothing is created"
  assert_not_contains "$(cat "$d/state.env")" "shared_uuid=" "and nothing recorded"
  # The run stopped before diskutil changed anything: nothing to reconcile,
  # and the creation can run again.
  d=$(txn_state)
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "yes\ncreate\n" shared create --dry-run
  assert_contains "$T_OUT" "would run  sudo -n diskutil addPartition disk0s6 ExFAT Shared" "a creation that never ran can run again"
  # The result was not the exFAT volume (a stop is recorded); once it is, by
  # hand, the creation's own check passes and the stop clears.
  unformatted=$(t_variant mac-shared-created)
  sed -i.bak 's#<key>FilesystemType</key><string>exfat</string>##' "$unformatted/cmd/diskutil_info_disk0s7" && rm -f "$unformatted/cmd/"*.bak
  d=$(with_receipt)
  T_ENV="OMB_STATE_DIR=$d OMB_TEST_AFTER=$unformatted" t_cli mac-shared-reserved "yes\ncreate\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "not the exFAT volume planned (filesystem: none)" "an unformatted result stops"
  T_ENV="OMB_STATE_DIR=$d" t_cli "$unformatted" "yes\ncreate\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "did not leave the disk as planned" "and stays stopped while it is unformatted"
  assert_empty_file "$T_DIR/record" "and is never formatted by this tool"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-created "yes\ncreate\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "Recording it now" "formatted by hand, it passes the creation's check and is recorded"
  assert_not_contains "$(cat "$d/state.env")" "shared_blocked_reason=" "and the stop clears"
  # A stop recorded for a creation whose partition is gone again stays a stop
  # until the record is removed by hand.
  d=$(with_receipt)
  T_ENV="OMB_STATE_DIR=$d OMB_TEST_AFTER=$unformatted" t_cli mac-shared-reserved "yes\ncreate\n" shared create
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "yes\ncreate\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "stopped (" "a recorded stop is not cleared by the partition disappearing"
  assert_empty_file "$T_DIR/record" "nothing is created while it stands"
  rm -f "$d/shared-create.env"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-reserved "yes\ncreate\n" shared create --dry-run
  assert_contains "$T_OUT" "would run  sudo -n diskutil addPartition" "with the record removed by hand, it can be created again"
  # A record that was edited is not a creation record.
  d=$(txn_state)
  sed -i.bak 's/^gap_end=\([0-9]*\)$/gap_end=9\1/' "$d/shared-create.env" && rm -f "$d/shared-create.env.bak"
  T_ENV="OMB_STATE_DIR=$d" t_cli mac-shared-created "yes\ncreate\n" shared create
  assert_contains "$(t_flat "$T_OUT")" "creation record was changed after it was written" "an edited creation record blocks"
  assert_empty_file "$T_DIR/record" "an edited creation record: nothing runs"

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
  assert_contains "$T_OUT" "would run  sudo -n diskutil addPartition disk0s6 ExFAT Shared $(( (150000000000 + 1048575) / 1048576 * 1048576 ))" "a dry run with a typed code shows the command"
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
  assert_contains "$T_OUT" "sudo -n diskutil addPartition disk0s6 ExFAT Shared $(( (150000000000 + 1048575) / 1048576 * 1048576 ))" "and Shared keeps its planned size"
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
for w in "[PASS] Shared storage" "[PASS] Shared identity" "[PASS] Shared on boot" "[INFO] Shared writing"; do
  assert_contains "$T_OUT" "$w" "doctor: $w"
done
assert_contains "$(t_flat "$T_OUT")" "[INFO] Shared mounted automount armed, nothing mounted yet" "doctor: an armed automount is not reported as the partition mounted"
G=4a7b1c2d-0007-4e5f-8a9b-000000000007
BY=/dev/disk/by-partuuid
# mi MAJ:MIN TYPE SOURCE [ID] — the kernel's mountinfo line for a filesystem
# mounted at /mnt/shared, over the automount (mount 120).
mi() { printf '%s 120 %s / /mnt/shared rw,nosuid,nodev,noexec,relatime shared:61 - %s %s rw,uid=1000,gid=1000,fmask=0177,dmask=0077' "${4:-130}" "$1" "$2" "$3"; }
# mounted LINE... — the ready machine (automount armed) with LINEs added to
# its mountinfo. Its lsblk also lists a copy of the disk in an enclosure
# (sda: sda1 carries Shared's PARTUUID, sda2 another exFAT volume) and a
# device-mapper device stacked on Shared; /dev/disk/by-partuuid/<Shared's
# GUID> links to Shared itself, as udev would have it on a good day.
mounted() {
  local fx
  fx=$(t_variant linux-shared-ready)
  printf '%s\n' "$@" >>"$fx/root/proc/self/mountinfo"
  printf '%s\n' 'NAME="sda" PKNAME="" TYPE="disk" START="" SIZE="1000204886016" PARTUUID="" PARTTYPE="" FSTYPE="" LABEL="" UUID="" MAJ:MIN="8:0"' \
    "NAME=\"sda1\" PKNAME=\"sda\" TYPE=\"part\" START=\"2048\" SIZE=\"150000893952\" PARTUUID=\"$G\" PARTTYPE=\"ebd0a0a2-b9e5-4433-87c0-68b6b72699c7\" FSTYPE=\"exfat\" LABEL=\"Shared\" UUID=\"1234-ABCD\" MAJ:MIN=\"8:1\"" \
    'NAME="sda2" PKNAME="sda" TYPE="part" START="292970496" SIZE="64000000000" PARTUUID="4a7b1c2d-0009-4e5f-8a9b-000000000009" PARTTYPE="ebd0a0a2-b9e5-4433-87c0-68b6b72699c7" FSTYPE="exfat" LABEL="Stick" UUID="5678-EF01" MAJ:MIN="8:2"' \
    'NAME="shared" PKNAME="nvme0n1p7" TYPE="crypt" START="" SIZE="150000000000" PARTUUID="" PARTTYPE="" FSTYPE="exfat" LABEL="" UUID="" MAJ:MIN="254:5"' >>"$fx/cmd/lsblk_all"
  mkdir -p "$fx/root/dev/disk/by-partuuid"
  ln -s ../../nvme0n1p7 "$fx/root/dev/disk/by-partuuid/$G"
  printf '%s' "$fx"
}
# Read-only after an error, and mounted a second time under another spelling:
# the second mount is found by the kernel's device number, not by its name.
fx=$(mounted "130 120 259:7 / /mnt/shared ro,nosuid,nodev,noexec,relatime shared:61 - exfat /dev/nvme0n1p7 ro,uid=1000,gid=1000" \
  "140 23 259:7 / /run/media/alex/Shared rw,nosuid,nodev,relatime shared:70 - exfat $BY/$G rw,uid=1000,gid=1000")
t_cli "$fx" "" doctor
assert_contains "$T_OUT" "[WARN] Shared mounted" "doctor: a read-only remount after an error warns"
assert_contains "$T_OUT" "[WARN] Shared mounted twice" "doctor: a second mount of the same partition warns"
t_cli linux-shared-conflict "" doctor
assert_contains "$T_OUT" "[FAIL] Shared storage" "doctor: a conflict fails"

# What is mounted at /mnt/shared is bound to the partition chosen by PARTUUID
# by the kernel's device number for it, before doctor vouches for it or the
# write test writes a byte. The mount's source text decides nothing.
for c in \
  "Shared by its kernel name|$(mi 259:7 exfat /dev/nvme0n1p7)|[PASS] Shared mounted|/dev/nvme0n1p7 at /mnt/shared: the kernel's device 259:7, PARTUUID matches|1" \
  "Shared by its PARTUUID path, the kernel's device Shared|$(mi 259:7 exfat "$BY/$G")|[PASS] Shared mounted|the kernel's device 259:7, PARTUUID matches|1" \
  "another disk's exFAT volume by its kernel name|$(mi 8:2 exfat /dev/sda2)|[FAIL] Shared mounted|(/dev/sda2) is on /dev/sda2, on /dev/sda, not on the disk holding the Linux root|0" \
  "a copy of the disk with Shared's PARTUUID, by that PARTUUID path|$(mi 8:1 exfat "$BY/$G")|[FAIL] Shared mounted|($BY/$G) is on /dev/sda1, on /dev/sda, not on the disk holding the Linux root|0" \
  "Shared's PARTUUID path, whose link names Shared, the kernel's device another partition|$(mi 259:5 exfat "$BY/$G")|[FAIL] Shared mounted|($BY/$G) is on /dev/nvme0n1p5 (PARTUUID=4a7b1c2d-0005-4e5f-8a9b-000000000005), not on Shared|0" \
  "another partition on root's disk|$(mi 259:5 exfat /dev/nvme0n1p5)|[FAIL] Shared mounted|is on /dev/nvme0n1p5 (PARTUUID=4a7b1c2d-0005-4e5f-8a9b-000000000005), not on Shared|0" \
  "Shared, but not as exFAT|$(mi 259:7 vfat /dev/nvme0n1p7)|[FAIL] Shared mounted|Shared (/dev/nvme0n1p7) is mounted at /mnt/shared as vfat, not exFAT|0" \
  "a device number no listed device has|$(mi 8:99 exfat /dev/sdz1)|[WARN] Shared mounted|is on device 8:99, which is not exactly one device listed here|0" \
  "a device number that is not one|$(mi bogus exfat /dev/nvme0n1p7)|[WARN] Shared mounted|is on device bogus, which is not exactly one device listed here|0" \
  "a device-mapper device stacked on Shared|$(mi 254:5 exfat /dev/mapper/shared)|[WARN] Shared mounted|is on /dev/shared, a crypt device, which is not traced to one partition here|0"; do
  IFS='|' read -r label line doc why write <<EOF
$c
EOF
  fx=$(mounted "$line")
  t_cli "$fx" "" doctor
  assert_contains "$T_OUT" "$doc" "doctor, $label: $doc"
  assert_contains "$(t_flat "$T_OUT")" "$why" "doctor, $label: the reason"
  t_cli "$fx" "test\n" shared test
  if [ "$write" = 1 ]; then
    assert_contains "$(cat "$T_DIR/record")" "cp $T_DIR/tmp/omarchy-bootstrap." "write test, $label: writes"
  else
    assert_empty_file "$T_DIR/record" "write test, $label: writes nothing"
    assert_contains "$(t_flat "$T_OUT")" "Nothing was written" "write test, $label: and says so"
  fi
done
fx=$(mounted "$(mi 259:7 exfat /dev/nvme0n1p7)" "$(mi 8:1 exfat "$BY/$G" 131)")
t_cli "$fx" "" doctor
assert_contains "$(t_flat "$T_OUT")" "[FAIL] Shared mounted 2 filesystems are mounted at /mnt/shared (/dev/nvme0n1p7,$BY/$G)" "doctor: two filesystems stacked at /mnt/shared fail"
t_cli "$fx" "test\n" shared test
assert_empty_file "$T_DIR/record" "write test: nothing written on a doubled mount"
fx=$(mounted "$(mi 259:7 exfat /dev/nvme0n1p7)")
rm -f "$fx/root/proc/self/mountinfo"
t_cli "$fx" "" doctor
assert_contains "$(t_flat "$T_OUT")" "[WARN] Shared mounted the kernel's mount table (/proc/self/mountinfo) could not be read" "doctor: an unreadable mount table is not a pass"
t_cli "$fx" "test\n" shared test
assert_empty_file "$T_DIR/record" "write test: nothing written without the kernel's mount table"
fx=$(t_variant linux-shared-ready)
grep -v ' - autofs ' "$FIX/linux-shared-ready/root/proc/self/mountinfo" >"$fx/root/proc/self/mountinfo"
t_cli "$fx" "" doctor
assert_contains "$(t_flat "$T_OUT")" "[WARN] Shared mounted not mounted and no automount active" "doctor: neither mounted nor armed warns"
# An armed automount is asked to mount by listing the directory (which
# writes nothing); when nothing is mounted then, nothing is written.
t_cli linux-shared-ready "test\n" shared test
assert_empty_file "$T_DIR/record" "write test: nothing written while nothing is mounted"
assert_contains "$(t_flat "$T_OUT")" "Nothing is mounted at /mnt/shared, even after asking the automount" "and it says so"
# A dry run does not ask the automount to mount (mounting changes the volume).
t_cli linux-shared-ready "test\n" shared test --dry-run
assert_contains "$(t_flat "$T_OUT")" "Dry run: nothing is mounted at /mnt/shared yet; a real run asks the automount to mount it" "a dry run leaves the automount alone"
assert_contains "$T_OUT" "would run  cp " "and shows what would run"
fx=$(mounted "$(mi 259:7 exfat /dev/nvme0n1p7)")
t_cli "$fx" "\n" shared test
assert_empty_file "$T_DIR/record" "the write test needs consent"
t_cli "$fx" "test\n" shared test
rec=$(cat "$T_DIR/record")
assert_contains "$rec" "cp $T_DIR/tmp/omarchy-bootstrap." "the write test copies one file"
assert_contains "$rec" "/mnt/shared/.omarchy-bootstrap-test-" "to a uniquely named file on Shared"
assert_contains "$rec" "rm -f /mnt/shared/.omarchy-bootstrap-test-" "and removes only that file"
# The I/O itself, on a real directory: success only when the bytes read back
# match and the file is removed again; a removal that fails is a failure,
# with the file it left named.
io=$(t_tmp)
awk 'BEGIN { for (i = 0; i < 64; i++) print i }' >"$io/src"
out=$(
  # shellcheck disable=SC2317,SC2329 # called by shared_test_io
  run() { "$@"; }
  shared_test_io "$io/src" "$io/dst" "$(sha256_of "$io/src")" && printf 'RC=0\n'
)
assert_contains "$out" "read back identical, and removed" "the write test reports success when every step worked"
assert_contains "$out" "RC=0" "and exits 0"
[ ! -e "$io/dst" ] && ok || fail "and the test file is gone"
out=$(
  # shellcheck disable=SC2317,SC2329 # called by shared_test_io
  run() { [ "$1" = rm ] && return 1; "$@"; }
  shared_test_io "$io/src" "$io/dst2" "$(sha256_of "$io/src")" || printf 'RC=1\n'
)
assert_contains "$(t_flat "$out")" "The test file could not be removed: $io/dst2 is still on Shared" "a failed removal is reported with the path left behind"
assert_not_contains "$out" "read back identical" "and success is not claimed"
assert_contains "$out" "RC=1" "and it exits non-zero"
out=$(
  # shellcheck disable=SC2317,SC2329 # called by shared_test_io
  run() { [ "$1" = cp ] && { printf 'other\n' >"$3"; return 0; }; "$@"; }
  shared_test_io "$io/src" "$io/dst3" "$(sha256_of "$io/src")" || printf 'RC=1\n'
)
assert_contains "$(t_flat "$out")" "the bytes read back were not the bytes written" "different bytes read back fail"
assert_contains "$out" "RC=1" "and exit non-zero"
[ ! -e "$io/dst3" ] && ok || fail "and the file is still removed"
t_cli linux-shared-present "" shared test
assert_contains "$T_OUT" "nothing to test yet" "no test before Shared is mounted"
t_cli linux-shared-ready "" shared
assert_contains "$T_OUT" "ready" "shared status on Linux"
assert_eq "$(ls -A "$T_DIR/state" 2>/dev/null)" "" "shared status records nothing"

t_done test-shared
