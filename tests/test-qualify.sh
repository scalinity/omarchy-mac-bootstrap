#!/usr/bin/env bash
# The round trip over generated machines and tiny streams. The run stand-in
# executes only qualification filesystem helpers beneath this test's fixture;
# no partition command, sudo, real mount or whole-system sync can run here.
# shellcheck disable=SC2030,SC2031,SC2034,SC2317,SC2329
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load
# shellcheck source=lib/records.sh
. "$REPO/lib/records.sh"
# shellcheck source=lib/core.sh
. "$REPO/lib/core.sh"
# shellcheck source=lib/read.sh
. "$REPO/lib/read.sh"
# shellcheck source=lib/qualify.sh
. "$REPO/lib/qualify.sh"
OMB_HOME=$REPO
# Used by fixture-mode Linux hashing on hosts without GNU coreutils.
sha256sum() { shasum -a 256; }
run() {
  local cmd=$1 arg
  shift
  if [ "$OMB_INTENT" != act ] || [ "$OMB_DRY_RUN" != 0 ] || [ -z "$OMB_FIXTURE" ]; then return 97; fi
  printf '%s\n' "$(quote_argv "$cmd" "$@")" >>"$F/writes"
  for arg in "$@"; do
    case "$arg" in /*) case "$arg" in "$F/root/"* | "$OMB_TMP/"*) ;; *) return 98 ;; esac ;; esac
  done
  case "$cmd" in
    sync) return 0 ;;
    qfy_copy_exclusive)
      if [ "${Q_COLLIDE:-0}" = 1 ] && [ "${2##*/}" = case ]; then
        : >"$2"; return 1
      fi
      qfy_copy_exclusive "$@" ;;
    qfy_stream)
      (
        case "${Q_BROKEN:-}" in
          producer) head() { command head "$@"; return 1; } ;;
          tee) tee() { command tee "$@"; return 1; } ;;
          hash) _qfy_hash() { shasum -a 256; return 1; } ;;
          short) head() { command head -c 17 /dev/urandom; } ;;
        esac
        qfy_stream "$@"
      ) ;;
    mkdir | rm | mv | rmdir) command "$cmd" "$@" ;;
    *) return 99 ;;
  esac
}
q_setup() {
  F=$(t_variant "qualify-$1")
  OMB_FIXTURE=$F OMB_STATE_DIR=$F/state OMB_TMP=$F/omarchy-bootstrap.scratch REC_TMP=''
  mkdir -p "$OMB_TMP" "$OMB_STATE_DIR"
  OMB_INTENT=act OMB_PERSIST=1 OMB_DRY_RUN=0 OMB_TEST_QUAL_BYTES=4097
  unset OMB_TEST_RECORD OMB_TEST_FAIL_AT OMB_TEST_STOP_AT
  Q_COLLIDE=0 Q_BROKEN=''
  platform_init
  state_init
  if [ "$1" = linux ]; then
    cp "$F/root/var/lib/omarchy-mac-bootstrap/state.env" "$STATE_FILE"
    Q=$F/root/mnt/shared/omarchy-mac-bootstrap/qualify
  else
    cp "$MAC_SEED/state.env" "$MAC_SEED/shared-intent.env" "$OMB_STATE_DIR/"
    Q=$F/root/Volumes/Shared/omarchy-mac-bootstrap/qualify
  fi
  mkdir -p "$Q"
  : >"$F/writes"
}
q_import() {
  cp "$FIX/qualify-records/macos.omb" "$FIX/qualify-records/data.macos.bin" "$Q/"
  mkdir -p "$Q/names-macos"
  : >"$Q/names-macos/ascii.txt"
}
q_go() {
  qfy_run <<<"${1:-test}" >"$F/output" 2>&1
  QRC=$? QOUT=$(cat "$F/output")
}
q_status() { qfy_status_read; assert_eq "$QFY_STATE" "$1" "$2"; }
q_refuse() {
  local before
  before=$(t_snapshot "$Q")
  q_go
  assert_rc "$QRC" 1 "$1: refusal"
  assert_eq "$(t_snapshot "$Q")" "$before" "$1: no Shared write"
  assert_empty_file "$F/writes" "$1: never reaches run"
}
q_reseal() {
  sed '$d' "$1" >"$F/body"
  cp "$F/body" "$1"
  rec_seal_write "$1"
}
q_change() {
  sed "$2" "$1" >"$F/body"
  cp "$F/body" "$1"
  q_reseal "$1"
}
# Child for real stop-at-boundary cases: no parent PID or unrelated process
# is signalled. The seam kills only the fresh shell executing this script.
if [ "${1:-}" = child ]; then
  F=$Q_CHILD_F OMB_FIXTURE=$Q_CHILD_F OMB_STATE_DIR=$Q_CHILD_STATE
  OMB_TMP=$F/omarchy-bootstrap.child REC_TMP=''
  mkdir -p "$OMB_TMP"
  OMB_TEST_QUAL_BYTES=4097 OMB_INTENT=act OMB_PERSIST=1 OMB_DRY_RUN=0
  unset OMB_TEST_RECORD
  platform_init; state_init
  qfy_run <<<test
  exit $?
fi
echo test-qualify
assert_eq "$QFY_STREAM_BYTES" 4296015889 qualify-production-size
assert_eq "$(awk '/^QFY_STREAM_BYTES=/ {print $0}' "$REPO/lib/qualify.sh")" 'QFY_STREAM_BYTES=4296015889' qualify-production-size-literal
OMB_TEST_QUAL_BYTES=4097 OMB_FIXTURE=''
_qfy_bytes
assert_rc $? 1 qualify-seam-outside-fixture
for seam in 0 01 -1 10000000 bad; do
  OMB_TEST_QUAL_BYTES=$seam OMB_FIXTURE=$FIX/qualify-linux
  _qfy_bytes
  assert_rc $? 1 "qualify-seam-invalid-$seam"
done
T_ENV='OMB_TEST_QUAL_BYTES=4097' t_cli '' '' qualify status
assert_rc "$T_RC" 2 qualify-seam-cli-outside-fixture
root_shim=$(t_tmp)
printf '#!/bin/sh\necho 0\n' >"$root_shim/id"; chmod +x "$root_shim/id"
env -i PATH="$root_shim:/usr/bin:/bin" OMB_FIXTURE="$FIX/qualify-linux" OMB_TEST_QUAL_BYTES=4097 \
  "$T_BASH" "$REPO/omarchy-bootstrap" qualify status >"$root_shim/out" 2>&1
assert_rc $? 2 qualify-seam-cli-root

# Identity first: an unreadable document on a wrong/unresolved mount cannot
# supply even a refusal reason. In particular, source text cannot prove GUID.
for mount in wrong missing duplicate unresolved filesystem; do
  q_setup linux; q_import
  printf torn >"$Q/macos.omb"
  case "$mount" in
    wrong) sed 's/259:7 /259:6 /' "$F/root/proc/self/mountinfo" >"$F/info" ;;
    missing) printf '' >"$F/info" ;;
    duplicate) cat "$F/root/proc/self/mountinfo" "$F/root/proc/self/mountinfo" >"$F/info" ;;
    unresolved) sed 's/259:7 /254:0 /' "$F/root/proc/self/mountinfo" >"$F/info" ;;
    filesystem) sed 's/ - exfat / - vfat /' "$F/root/proc/self/mountinfo" >"$F/info" ;;
  esac
  cp "$F/info" "$F/root/proc/self/mountinfo"
  q_refuse "qualify-identity-$mount"
  assert_contains "$QOUT" 'mount is not verified' "qualify-identity-$mount-first"
done
q_setup linux; q_import
sed 's/FSTYPE="exfat"/FSTYPE="vfat"/' "$F/cmd/lsblk_all" >"$F/rows"; cp "$F/rows" "$F/cmd/lsblk_all"
q_refuse qualify-identity-baseline
q_setup linux; q_import
for bad in schema plan guid bytes seal admission; do
  cp "$FIX/qualify-records/macos.omb" "$Q/macos.omb"
  case "$bad" in
    schema) q_change "$Q/macos.omb" 's/schema=1/schema=2/' ;;
    plan) q_change "$Q/macos.omb" 's/plan=1a2b3c4d/plan=aaaaaaaa/' ;;
    guid) q_change "$Q/macos.omb" 's/0007-4E5F/0008-4E5F/' ;;
    bytes) q_change "$Q/macos.omb" 's/bytes=4097/bytes=4098/' ;;
    seal) printf x >>"$Q/macos.omb" ;;
    admission) printf '\000' >>"$Q/macos.omb" ;;
  esac
  q_refuse "qualify-$bad"
done
cp "$FIX/qualify-records/macos.omb" "$Q/macos.omb"
printf 'torn\n' >>"$Q/macos.omb"
q_status blocked qualify-torn-seal
# Order and predecessor digest, not merely the presence of a Linux file.
q_setup linux
cp "$FIX/qualify-records/linux.omb" "$Q/"
q_refuse qualify-order-no-macos
q_setup linux; q_import
cp "$FIX/qualify-records/linux.omb" "$Q/"
q_change "$Q/linux.omb" 's/previous=./previous=f/'
q_refuse qualify-order-previous
q_setup linux; q_import
cp "$FIX/qualify-records/linux.omb" "$Q/"
q_change "$Q/linux.omb" 's/majmin=259:7/majmin=259:8/'
q_status waiting-for-macos qualify-recorded-device-is-history
assert_empty_file "$F/writes" qualify-recorded-device-never-authority
q_setup linux; q_import
ln -s "$F" "$Q/names-linux"
q_refuse qualify-linked-folder
q_setup linux
q_refuse qualify-linux-order-step1
q_setup linux; q_import
OMB_UID=0
q_go
assert_rc "$QRC" 1 qualify-linux-root
assert_empty_file "$F/writes" qualify-linux-root-no-write
q_setup linux; q_import
q_go stop
assert_rc "$QRC" 1 qualify-typed-test
assert_empty_file "$F/writes" qualify-typed-test-no-write
q_setup linux; q_import
printf 'Filesystem blocks used avail cap mount\nx 999999 0 1 0%% /mnt/shared\n' >"$F/cmd/qualify_space"
q_refuse qualify-linux-space
assert_contains "$QOUT" 'bytes free' qualify-linux-space-numbers
q_setup linux; q_import
q_go
assert_rc "$QRC" 0 qualify-linux-success
q_status waiting-for-macos qualify-step2-state
rec_admit_file qlinux - "$Q/linux.omb"
assert_rc $? 0 qualify-step2-sealed
assert_contains "$(cat "$F/writes")" 'sync ' qualify-linux-file-flush
before=$(t_snapshot "$Q")
q_go
assert_rc "$QRC" 1 qualify-linux-step2-not-repeated
assert_eq "$(t_snapshot "$Q")" "$before" qualify-linux-step2-order-no-write

# The everyday user's first run can read the token root left, as the
# baseline's Shared command does; no copy of that state is written here.
q_setup linux; q_import
rm "$STATE_FILE"
unset CFG_user CFG_plan CFG_shared
q_go
assert_rc "$QRC" 0 qualify-linux-system-plan
assert_eq "$(t_snapshot "$STATE_FILE")" '(absent)' qualify-linux-system-plan-no-copy

# A changed record while the typed gate waits cannot steer the reviewed step.
q_setup linux; q_import
(
  ui_confirm_word() {
    q_change "$Q/macos.omb" 's/commit=/commit=0123456789012345678901234567890123456789/'
    return 0
  }
  q_go
  assert_rc "$QRC" 1 qualify-fresh-after-gate
  assert_contains "$QOUT" 'Qualification changed' qualify-fresh-after-gate-reason
  assert_empty_file "$F/writes" qualify-fresh-after-gate-no-run
  printf '%s %s\n' "$T_PASS" "$T_FAIL" >"$F/counts"
)
read -r T_PASS T_FAIL <"$F/counts"
q_setup linux
mkdir -p "$OMB_TMP/qualify"
printf precious >"$Q/existing"
printf replacement >"$OMB_TMP/qualify/input"
run qfy_copy_exclusive "$OMB_TMP/qualify/input" "$Q/existing" 2>/dev/null
assert_rc $? 1 qualify-exclusive-create-refuses-existing
assert_eq "$(cat "$Q/existing")" precious qualify-exclusive-create-keeps-content

# A collision is recorded without replacing the existing entry.
q_setup linux; q_import
Q_COLLIDE=1
q_go
assert_rc "$QRC" 0 qualify-collision-continues
assert_contains "$(cat "$Q/linux.omb")" 'name_collision=case' qualify-name-collision-recorded
# Stops and write failures at each record save, plus the stream save, leave
# no final record and the same step due on the next invocation.
for boundary in qualify.stream qualify.linux; do
  q_setup linux; q_import
  env Q_CHILD_F="$F" Q_CHILD_STATE="$OMB_STATE_DIR" OMB_TEST_STOP_AT="$boundary" \
    "$T_BASH" "$0" child >"$F/child.out" 2>&1
  assert_rc $? 137 "qualify-stop-$boundary"
  if [ ! -e "$Q/linux.omb" ]; then ok; else fail "qualify-stop-$boundary-no-record"; fi
  q_go
  assert_rc "$QRC" 0 "qualify-resume-$boundary"
  q_status waiting-for-macos "qualify-resume-$boundary-state"
done
for boundary in qualify.stream qualify.linux; do
  q_setup linux; q_import
  OMB_TEST_FAIL_AT=$boundary
  q_go
  assert_rc "$QRC" 1 "qualify-write-failure-$boundary"
  if [ ! -e "$Q/linux.omb" ]; then ok; else fail "qualify-write-failure-$boundary-no-record"; fi
  unset OMB_TEST_FAIL_AT
  q_go
  assert_rc "$QRC" 0 "qualify-write-failure-$boundary-retry"
done
q_setup linux; q_import
printf 'exfat (nvme0n1p7): volume was not properly unmounted\n' >"$F/cmd/qualify_dirty"
q_go
assert_contains "$(cat "$Q/linux.omb")" 'dirty=1' qualify-linux-dirty-recorded

# Every writer stage counts, even when the final hash command succeeds.
for broken in producer tee hash short; do
  q_setup linux; q_import
  Q_BROKEN=$broken
  q_go
  assert_rc "$QRC" 1 "qualify-stream-$broken"
  if [ ! -e "$Q/linux.omb" ]; then ok; else fail "qualify-stream-$broken-no-record"; fi
  assert_contains "$(cat "$F/writes")" 'qfy_stream' "qualify-stream-$broken-reached-writer"
done
q_setup linux; q_import
printf changed >>"$Q/data.macos.bin"
q_go
assert_rc "$QRC" 0 qualify-mismatch-step2-continues
rec_admit_file qlinux - "$Q/linux.omb"
_qfy_get read_hash "${REC_L[0]}" read_sha256
assert_not_contains "$read_hash" 22408e42a1590b66ec35d317281cd4858907752051ae16996a1c33cc08776cf4 qualify-mismatch-step2-recorded
for unavailable in space dirty kernel hash; do
  q_setup linux; q_import
  case "$unavailable" in
    space) printf 'bad\n' >"$F/cmd/qualify_space" ;;
    dirty) rm "$F/cmd/qualify_dirty" ;;
    kernel) printf 'not an id\n' >"$F/cmd/qualify_kernel" ;;
    hash) sed '/^sha256sum$/d' "$F/commands" >"$F/newcommands"; cp "$F/newcommands" "$F/commands" ;;
  esac
  q_refuse "qualify-unavailable-$unavailable"
done

# The current-shell read interface is pure even in an act caller with an
# invalid saved choice (cfg_load would otherwise log its refusal).
q_setup linux; q_import
sed 's/cfg_host=.*/cfg_host=bad host/' "$STATE_FILE" >"$F/changed-state"
cp "$F/changed-state" "$STATE_FILE"
local_before=$(t_snapshot "$OMB_STATE_DIR")
qfy_status_read
assert_eq "$(t_snapshot "$OMB_STATE_DIR")" "$local_before" qualify-read-interface-no-log

# Read commands must leave both Shared and local records exactly alone.
q_setup linux; q_import
before=$(t_snapshot "$Q")
local_before=$(t_snapshot "$OMB_STATE_DIR")
T_ENV="OMB_STATE_DIR=$OMB_STATE_DIR OMB_TEST_QUAL_BYTES=4097" t_cli "$F" '' qualify status
assert_rc "$T_RC" 0 qualify-status-cli
assert_contains "$T_OUT" waiting-for-linux qualify-status-cli-state
T_ENV="OMB_STATE_DIR=$OMB_STATE_DIR OMB_TEST_QUAL_BYTES=4097" t_cli "$F" '' qualify status
assert_eq "$(t_snapshot "$Q")" "$before" qualify-status-idempotent
assert_eq "$(t_snapshot "$OMB_STATE_DIR")" "$local_before" qualify-status-local-state-unchanged
assert_empty_file "$T_DIR/record" qualify-status-no-run
T_ENV="OMB_STATE_DIR=$OMB_STATE_DIR OMB_TEST_QUAL_BYTES=4097" t_cli "$F" 'test\n' qualify --dry-run
assert_rc "$T_RC" 0 qualify-dry-run
assert_eq "$(t_snapshot "$Q")" "$before" qualify-dry-run-no-write
T_ENV="OMB_STATE_DIR=$OMB_STATE_DIR OMB_TEST_QUAL_BYTES=4097" t_cli "$F" '' qualify garbage
assert_rc "$T_RC" 2 qualify-command-admission

if t_plutil 'qualification macOS steps'; then
  MAC_SEED=$(t_tmp)
  T_ENV="OMB_STATE_DIR=$MAC_SEED" t_cli mac-m1pro-1tb-roomy '\n4\n\n\n\n\n\n\n\n\n\n\n\n\n\n' plan
  assert_rc "$T_RC" 0 qualify-macos-plan-seed
  OMB_STATE_DIR=$MAC_SEED
  state_init; cfg_load
  state_set shared_linux_done "$(code_make ombdone "$CFG_plan" 4A7B1C2D-0006-4E5F-8A9B-000000000006)"
  q_setup macos
  printf torn >"$Q/macos.omb"
  sed 's#<key>Internal</key><true/>#<key>Internal</key><false/>#' "$F/cmd/diskutil_info_disk0" >"$F/info"
  cp "$F/info" "$F/cmd/diskutil_info_disk0"
  q_refuse qualify-macos-identity
  assert_contains "$QOUT" 'not reported as internal' qualify-macos-identity-first
  q_setup macos
  q_go
  assert_rc "$QRC" 0 qualify-step1-success
  assert_contains "$QOUT" 'Shut down fully' qualify-shutdown-guide
  q_status waiting-for-linux qualify-step1-state
  rec_admit_file qmac - "$Q/macos.omb"
  assert_rc $? 0 qualify-step1-sealed
  full_plan=''
  _qfy_get full_plan "${REC_L[0]}" plan
  assert_eq "${#full_plan}" 64 qualify-full-plan-digest
  assert_eq "${full_plan:0:16}" "$INT_digest" qualify-baseline-plan-digest-prefix
  _qfy_get bytes "${REC_L[0]}" bytes
  assert_eq "$bytes" 4097 qualify-fixture-stream-size
  MAC_RUN=$F MAC_Q=$Q MAC_STATE=$OMB_STATE_DIR
  mac_plan=$QFY_PLAN
  q_setup linux
  cp -R "$MAC_Q/." "$Q/"
  state_set cfg_plan "${mac_plan:0:8}"
  q_go
  assert_rc "$QRC" 0 qualify-round-trip-step2
  LINUX_Q=$Q
  # Finish on the original Mac and plan; no manually copied digest.
  F=$MAC_RUN Q=$MAC_Q OMB_FIXTURE=$MAC_RUN OMB_STATE_DIR=$MAC_STATE REC_TMP=''
  OMB_TMP=$F/omarchy-bootstrap.scratch
  platform_init; state_init
  cp -R "$LINUX_Q/." "$Q/"
  q_go
  assert_rc "$QRC" 0 qualify-step3-success
  q_status passed qualify-passed
  for file in macos.omb linux.omb result.omb; do if [ -f "$Q/$file" ]; then ok; else fail "qualify-keeps-$file"; fi; done
  for file in data.macos.bin data.linux.bin names-macos names-linux; do if [ ! -e "$Q/$file" ]; then ok; else fail "qualify-pass-removes-$file"; fi; done
  # Passed step 1 rerun preserves foreign entries, including inside names.
  mkdir -p "$Q/names-macos"; printf precious >"$Q/foreign"; printf inner >"$Q/names-macos/foreign"
  q_go
  assert_rc "$QRC" 0 qualify-rerun-passed
  assert_eq "$(cat "$Q/foreign")" precious qualify-rerun-keeps-foreign
  assert_eq "$(cat "$Q/names-macos/foreign")" inner qualify-rerun-keeps-inner-foreign
  assert_contains "$QOUT" 'Left foreign entry' qualify-rerun-reports-foreign
  assert_contains "$QOUT" 'names-macos/ascii.txt' qualify-cleanup-shows-fixed-names
  q_setup macos
  mkdir -p "$Q/names-macos"
  printf foreign-case >"$Q/names-macos/CASE"
  printf foreign-data >"$Q/data.MACOS.bin"
  q_go
  assert_eq "$(cat "$Q/names-macos/CASE")" foreign-case qualify-cleanup-keeps-case-alias
  assert_eq "$(cat "$Q/data.MACOS.bin")" foreign-data qualify-cleanup-keeps-data-alias
  assert_contains "$QOUT" 'Left foreign entry' qualify-cleanup-reports-aliases
  # Synthetic round trip binds its macOS record to this actual plan.
  q_setup macos
  cp -R "$FIX/qualify-records/." "$Q/"
  qfy_status_read
  # Rewrite only the fixture plan and its predecessor chain.
  q_change "$Q/macos.omb" "s/plan=[a-f0-9]*/plan=$QFY_PLAN/"
  _qfy_sha "$Q/macos.omb"; msha=$QFY_SHA
  q_change "$Q/linux.omb" "s/previous=[a-f0-9]*/previous=$msha/"
  printf corrupt >>"$Q/data.linux.bin"
  q_go
  assert_rc "$QRC" 1 qualify-digest-mismatch
  q_status failed qualify-failed-state
  QFY_ACTION_STEP=3
  qfy_action_judge 1
  assert_eq "$CORE_FINDING" completed qualify-failed-result-finishes-action
  assert_contains "$CORE_JUDGE_TEXT" failed qualify-failed-result-stays-failed
  qfy_action_judge reconcile
  assert_eq "$CORE_FINDING" completed qualify-failed-result-reconciles
  if [ -f "$Q/data.linux.bin" ]; then ok; else fail qualify-failed-keeps-data; fi
  printf keep >"$Q/foreign"
  q_go
  assert_rc "$QRC" 0 qualify-rerun-failed
  assert_eq "$(cat "$Q/foreign")" keep qualify-rerun-failed-keeps-foreign
  q_setup macos
  cp -R "$FIX/qualify-records/." "$Q/"
  qfy_status_read
  plan_tail=0
  [ "${QFY_PLAN:63:1}" != 0 ] || plan_tail=1
  q_change "$Q/macos.omb" "s/plan=[a-f0-9]*/plan=${QFY_PLAN:0:63}$plan_tail/"
  q_refuse qualify-macos-full-plan-binding
  # A name that changes is a failed result, not an interrupted step.
  q_setup macos
  cp -R "$FIX/qualify-records/." "$Q/"
  qfy_status_read
  q_change "$Q/macos.omb" "s/plan=[a-f0-9]*/plan=$QFY_PLAN/"
  _qfy_sha "$Q/macos.omb"; msha=$QFY_SHA
  q_change "$Q/linux.omb" "s/previous=[a-f0-9]*/previous=$msha/"
  mv "$Q/names-linux/ascii.txt" "$Q/names-linux/changed.txt"
  q_go
  assert_rc "$QRC" 1 qualify-name-mismatch
  q_status failed qualify-name-mismatch-result
  assert_contains "$(cat "$Q/result.omb")" 'names_ok=0' qualify-name-mismatch-recorded
  # Both macOS record boundaries: actual stop and write failure, then resume.
  for record in macos result; do
    for mode in stop fail; do
      q_setup macos
      if [ "$record" = result ]; then
        cp -R "$FIX/qualify-records/." "$Q/"
        qfy_status_read
        q_change "$Q/macos.omb" "s/plan=[a-f0-9]*/plan=$QFY_PLAN/"
        _qfy_sha "$Q/macos.omb"; msha=$QFY_SHA
        q_change "$Q/linux.omb" "s/previous=[a-f0-9]*/previous=$msha/"
      fi
      if [ "$mode" = stop ]; then
        env Q_CHILD_F="$F" Q_CHILD_STATE="$OMB_STATE_DIR" OMB_TEST_STOP_AT="qualify.$record" \
          "$T_BASH" "$0" child >"$F/child.out" 2>&1
        assert_rc $? 137 "qualify-stop-$record"
      else
        OMB_TEST_FAIL_AT=qualify.$record
        q_go
        assert_rc "$QRC" 1 "qualify-fail-$record"
        unset OMB_TEST_FAIL_AT
      fi
      if [ ! -e "$Q/$record.omb" ]; then ok; else fail "qualify-$mode-$record-no-record"; fi
      q_go
      assert_rc "$QRC" 0 "qualify-$mode-$record-resume"
    done
  done
  q_setup macos
  printf 'Filesystem blocks used avail cap mount\nx 999999 0 1 0%% /Volumes/Shared\n' >"$F/cmd/qualify_space"
  q_go
  assert_rc "$QRC" 1 qualify-macos-space
  assert_contains "$QOUT" 'bytes free' qualify-macos-space-numbers
  if [ ! -e "$Q/macos.omb" ]; then ok; else fail qualify-macos-space-no-record; fi
fi

# Real core route, whole response admission, scope-first refusal and paging.
T=$(t_tmp)
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
c_session
C_FIX=$(t_variant qualify-linux)
C_ENV='OMB_SESSION_SCOPES=journey,qualify OMB_TEST_QUAL_BYTES=4097'
c_run snapshot $'scope\tname=qualify'
assert_eq "$(c_answered snapshot 'done ok')" '' qualify-core-snapshot-admitted
assert_contains "$C_OUT" 'key=qualify.state' qualify-core-state-fact
qgen=$(printf '%s\n' "$C_OUT" | sed -n 's/^generation.id=\([a-f0-9]*\).*/\1/p')
c_run detail "$(rec_line page scope qualify kind step generation "$qgen" offset 0 limit 10)"
assert_eq "$(c_answered detail 'done ok')" '' qualify-core-page-admitted
assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^row')" 3 qualify-core-three-steps
mkdir -p "$C_FIX/root/mnt/shared/omarchy-mac-bootstrap/qualify"
cp "$FIX/qualify-records/macos.omb" "$C_FIX/root/mnt/shared/omarchy-mac-bootstrap/qualify/"
C_STATE=$T/state
mkdir -p "$C_STATE"
cp "$C_FIX/root/var/lib/omarchy-mac-bootstrap/state.env" "$C_STATE/state.env"
c_run snapshot $'scope\tname=qualify'
assert_eq "$(c_answered snapshot 'done ok')" '' qualify-core-due-admitted
assert_contains "$C_OUT" $'id=qualify.run\tscope=qualify\tlabel=Run%20step%202' qualify-core-due-action
fresh_gen=$(printf '%s\n' "$C_OUT" | sed -n 's/^generation.id=\([a-f0-9]*\).*/\1/p')
c_run detail "$(rec_line page scope qualify kind step generation "$fresh_gen" offset 0 limit 10)"
assert_eq "$(c_answered detail 'done ok')" '' qualify-core-recorded-step-page
assert_contains "$C_OUT" '08:00:00%20EDT' qualify-step-time-eastern
c_run detail "$(rec_line page scope qualify kind step generation "$qgen" offset 0 limit 10)"
assert_eq "$(c_answered detail 'refused changed')" '' qualify-core-generation-binds-records
C_ENV='OMB_SESSION_SCOPES=journey OMB_TEST_QUAL_BYTES=4097'
c_run snapshot $'scope\tname=qualify'
assert_eq "$(c_answered snapshot 'refused scope')" '' qualify-core-scope-before-producer
c_run execute "$(rec_line exec action qualify.run basis "$(printf '%064d' 0)" confirm test)"
assert_eq "$(c_answered execute 'refused scope')" '' qualify-action-scope
qfy_row qualify.run
assert_eq "$CA_SCOPE:$CA_TERMINAL:$CA_GATE:$CA_CANCEL" qualify:handoff:test:0 qualify-action-row
# Entry-point ownership keeps the launcher route here, with the exact scopes.
assert_contains "$(cat "$REPO/omarchy-bootstrap")" 'FE_SCOPES=journey,qualify FE_INTENT=act' qualify-launcher-scopes

t_done test-qualify
