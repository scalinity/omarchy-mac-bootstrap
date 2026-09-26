#!/usr/bin/env bash
# The launcher's side of the frontend (docs/FRONTEND.md → Distribution and
# provenance, Intent and persistence; docs/PROTOCOL.md → The session
# scratch): frontend-digest, frontend-offline, frontend-unrunnable,
# frontend-dev, frontend-intent-*, and the session scratch's owner cleanup
# and stale reclaim (sup-owner-cleanup-refused, sup-reclaim-*, sup-pid-reuse,
# sup-identity-unknown, sup-eintr's wait loop).
#
# The frontend here is a small fake — a shell script whose behaviour a file
# decides — pinned by a test lock in a copy of the tool, so the distribution
# logic is proved without a release. frontend/tests/pty.rs runs the real one.
# shellcheck disable=SC2010,SC2015,SC2016 # ls|grep over known names; ok/fail always return 0; literal $ in scripts
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-frontend"
T=$(t_tmp)

# A copy of the tool: its lock is the test's (the checkout's is not touched).
TOOL=$T/tool
mkdir -p "$TOOL/release" "$TOOL/tests"
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$TOOL/"
cp -R "$REPO/tests/children" "$TOOL/tests/"

# This host's frontend target, as the launcher sees it; a uname shim gives
# every runner an aarch64 answer, so no runner skips these checks.
SHIM=$T/uname-shim
mkdir -p "$SHIM"
case "$(uname -s)" in
  Darwin) TARGET=aarch64-apple-darwin && printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) /usr/bin/uname "$@" ;; esac\n' >"$SHIM/uname" ;;
  *) TARGET=aarch64-unknown-linux-gnu && printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo aarch64 ;; *) /bin/uname "$@" ;; esac\n' >"$SHIM/uname" ;;
esac
chmod +x "$SHIM/uname"
BASE_PATH="$SHIM:/usr/bin:/bin:/usr/sbin:/sbin"

# The fake frontend: exits as $dir/../fake-behaviour says (first word), and
# may first leave a process behind, write an operation record naming its
# session, or record the environment it was given.
FAKE=$T/fake-omb-tui
cat >"$FAKE" <<'EOF'
#!/bin/bash
# A stand-in for omb-tui in the launcher's tests.
dir=$2
b=$(cat "$(dirname "$0")/fake-behaviour" 2>/dev/null)
env >"$(dirname "$0")/fake-env"
case "$b" in
  *linger*) sleep 3 & ;;
esac
case "$b" in
  *trace*) [ -n "${OMB_TUI_LOG:-}" ] && (umask 077 && echo "fake trace" >>"$OMB_TUI_LOG") ;;
esac
case "$b" in
  *sleep*) sleep 2 ;;
esac
code=${b%% *}
exit "${code:-0}"
EOF
chmod +x "$FAKE"
sha_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -c1-64; else sha256sum "$1" | cut -c1-64; fi; }
FAKE_SHA=$(sha_of "$FAKE")
FAKE_SIZE=$(wc -c <"$FAKE" | tr -d ' ')

# lock TARGET SHA SIZE — the test lock, sealed.
lock() {
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    f=$TOOL/release/frontend.lock
    {
      printf 'omb-frontend-lock 1\n'
      rec_line frontend version 0.1.0 proto 1 source_commit "$(printf '%040d' 0)" inputs_digest "$(printf '%064d' 0)" rust 1.88.0
      rec_line artifact target "$1" url "https://example.invalid/omb-tui-0.1.0-$1" size "$3" sha256 "$2" minos "" glibc_max "" interp "" align_min ""
    } >"$f"
    rec_seal_write "$f"
    omb_cleanup
  )
}
lock "$TARGET" "$FAKE_SHA" "$FAKE_SIZE"

# A fixture whose network serves the frontend.
FIXB=$(t_variant mac-m1pro-1tb-roomy)
mkdir -p "$FIXB/net"
CACHE=$T/home/.cache/omarchy-mac-bootstrap/frontend

# fe_call INPUT FN ARGS... — load the libraries from the copy and call a
# launcher function with the fake's world, answering prompts with INPUT;
# prints "FE_STATE|FE_BIN|FE_WHY".
fe_call() {
  local input=$1
  shift
  printf '%b' "$input" | env -i PATH="${FE_PATH:-$BASE_PATH}" HOME="$T/home" TMPDIR="$T/tmp" LANG=en_US.UTF-8 TERM=dumb \
    OMB_FIXTURE="${FE_FIX-$FIXB}" OMB_STATE_DIR="$T/state" ${FE_ENV:-} "$T_BASH" -c '
      . "$1/lib/common.sh"; . "$1/lib/ui.sh"; . "$1/lib/state.sh"; . "$1/lib/records.sh"; . "$1/lib/core.sh"; . "$1/lib/frontend.sh"
      OMB_HOME=$1; shift
      OMB_COLOR=never; ui_init; platform_init; state_init
      "$@" >"$TMPDIR/fe-out" 2>&1
      rc=$?
      printf "%s|%s|%s|%s\n" "$rc" "${FE_STATE:-}" "${FE_BIN:-}" "${FE_WHY:-}"
      omb_cleanup
    ' bash "$TOOL" "$@"
}
mkdir -p "$T/tmp"

# --- Acquisition: the right target and digest ---------------------------------------
cp "$FAKE" "$FIXB/net/frontend-$TARGET"
r=$(fe_call 'y\n' fe_select act)
assert_eq "${r%%|*}" 0 "act: acquired after [Y/n]"
assert_contains "$r" "|verified|$CACHE/$FAKE_SHA/omb-tui|" "the pinned artifact, cached under its digest"
cmp -s "$FAKE" "$CACHE/$FAKE_SHA/omb-tui" && ok || fail "the cached bytes are the pinned bytes"
[ -x "$CACHE/$FAKE_SHA/omb-tui" ] && ok || fail "executable"
assert_eq "$(find "$CACHE" -maxdepth 1 -perm 700 -type d | grep -c "$FAKE_SHA")" 1 "the cache folder is private"
# A cached, verified binary: no download needed at all.
rm -f "$FIXB/net/frontend-$TARGET"
r=$(fe_call '' fe_select act)
assert_contains "$r" "0|verified|$CACHE/$FAKE_SHA/omb-tui|" "a cached valid artifact is started, its digest checked, nothing fetched"

# --- frontend-digest: a corrupted cache ---------------------------------------------------
printf 'tampered' >>"$CACHE/$FAKE_SHA/omb-tui"
cp "$FAKE" "$FIXB/net/frontend-$TARGET"
r=$(fe_call 'n\n' fe_select act)
assert_contains "$r" "|mismatch||" "frontend-digest: a cached binary with another digest is never run"
[ -f "$CACHE/$FAKE_SHA/omb-tui" ] && ok || fail "declined: the bad copy is left where it is"
r=$(fe_call 'y\ny\n' fe_select act)
assert_contains "$r" "0|verified|" "act: after a yes, moved aside and acquired again"
ls "$CACHE/$FAKE_SHA" | grep -q 'omb-tui.mismatch-' && ok || fail "the mismatching copy moved aside, not deleted"
cmp -s "$FAKE" "$CACHE/$FAKE_SHA/omb-tui" && ok || fail "the pinned bytes are back"
rm -rf "$CACHE"

# --- frontend-digest: a replaced release asset, a partial download ----------------------
{ head -c $((FAKE_SIZE - 1)) "$FAKE"; printf X; } >"$FIXB/net/frontend-$TARGET"
r=$(fe_call 'y\n' fe_select act)
assert_contains "$r" "|mismatch||" "frontend-digest: a download with the right size and another digest is refused"
[ ! -e "$CACHE/$FAKE_SHA/omb-tui" ] && ok || fail "nothing is cached from it"
head -c 100 "$FAKE" >"$FIXB/net/frontend-$TARGET"
r=$(fe_call 'y\n' fe_select act)
assert_contains "$r" "|missing||" "a partial download is refused"
assert_contains "$r" "not the $FAKE_SIZE the lock pins" "and says so"
[ ! -e "$CACHE/$FAKE_SHA/omb-tui" ] && ok || fail "nothing is cached from a partial download"
[ -z "$(ls -A "$CACHE/$FAKE_SHA" 2>/dev/null)" ] && ok || fail "no temporary is left behind"

# --- frontend-offline --------------------------------------------------------------------
rm -f "$FIXB/net/frontend-$TARGET"
r=$(fe_call 'y\n' fe_select act)
assert_contains "$r" "|missing||the download failed (no network): https://example.invalid/omb-tui-0.1.0-$TARGET" "frontend-offline: the reason and the URL"
r=$(fe_call '' fe_select plan)
assert_contains "$r" "|missing||the interface is not downloaded yet" "plan: nothing acquired; the default run sets it up"

# --- The lock itself ---------------------------------------------------------------------
lock x86_64-apple-darwin "$FAKE_SHA" "$FAKE_SIZE"
r=$(fe_call 'y\n' fe_select act)
assert_contains "$r" "|missing||the lock pins no frontend for $TARGET" "a lock with no artifact for this host: missing, with the reason"
mv "$TOOL/release/frontend.lock" "$T/lock.aside"
r=$(fe_call 'y\n' fe_select act)
assert_contains "$r" "|missing||this checkout pins no frontend release" "no lock: missing, never a guess"
mv "$T/lock.aside" "$TOOL/release/frontend.lock"
printf 'x' >>"$TOOL/release/frontend.lock"
r=$(fe_call 'y\n' fe_select act)
assert_contains "$r" "is not admissible" "a lock that fails admission is refused"
lock "$TARGET" "$FAKE_SHA" "$FAKE_SIZE"

# --- frontend-unrunnable -------------------------------------------------------------------
printf '\177ELF\002\001\001\000\000\000garbage' >"$T/not-a-binary"
BAD_SHA=$(sha_of "$T/not-a-binary")
lock "$TARGET" "$BAD_SHA" "$(wc -c <"$T/not-a-binary" | tr -d ' ')"
cp "$T/not-a-binary" "$FIXB/net/frontend-$TARGET"
r=$(fe_call 'y\n' fe_run act journey)
assert_eq "${r%%|*}" 10 "frontend-unrunnable: back to text (status 10)"
assert_contains "$r" "|unrunnable|" "reported as unrunnable"
assert_contains "$r" "would not execute (status 126; SHA-256 $BAD_SHA, $TARGET)" "with its digest and target"
rm -rf "$CACHE"
lock "$TARGET" "$FAKE_SHA" "$FAKE_SIZE"
cp "$FAKE" "$FIXB/net/frontend-$TARGET"

# --- A handshake refused: fallback ----------------------------------------------------------
# Acquire once; the fake then reads its behaviour beside the cached binary.
r=$(fe_call 'y\n' fe_select act)
assert_contains "$r" "0|verified|" "the pinned fake is cached"
printf '10' >"$CACHE/$FAKE_SHA/fake-behaviour"
r=$(fe_call '' fe_run act journey)
assert_eq "${r%%|*}" 10 "a frontend that refuses the handshake (exit 10): text"
assert_contains "$r" "|fallback|" "reported as fallback"
printf '0' >"$CACHE/$FAKE_SHA/fake-behaviour"
r=$(fe_call '' fe_run act journey)
assert_eq "${r%%|*}" 0 "a frontend that finishes: 0"
e=$(cat "$CACHE/$FAKE_SHA/fake-env")
for v in "OMB_HOME=$TOOL" OMB_SESSION_INTENT=act OMB_SESSION_SCOPES=journey OMB_DRY_RUN=0 "OMB_SESSION_DIR=$T/tmp/omb-session."; do
  assert_contains "$e" "$v" "the launcher sets $v for the frontend"
done
assert_eq "$(ls "$T/tmp" | grep -c '^omb-session\.')" 0 "sup-owner-cleanup: the launcher removed its own scratch"
printf '1' >"$CACHE/$FAKE_SHA/fake-behaviour"
r=$(fe_call '' fe_run act journey)
assert_eq "${r%%|*}" 1 "a frontend that fails: a failure the launcher reports"
assert_contains "$r" "|crashed|" "reported"
assert_contains "$(cat "$T/tmp/fe-out")" "the interface stopped" "with what happened"
assert_contains "$(tr '\n' ' ' <"$T/tmp/fe-out" | tr -s ' ')" "status shows where the machine is" "and what to run"

# --- frontend-intent-*: a corrupted cache and OMB_TUI_LOG, for each intent ----------------
# The filesystem outside the scratch folders stays as it was: nothing moved,
# no trace — except in an act session, where the move is offered and the trace
# written 0600.
printf 'tampered' >>"$CACHE/$FAKE_SHA/omb-tui"
before=$(t_snapshot "$T/home"; t_snapshot "$T/state")
r=$(FE_ENV="OMB_TUI_LOG=$T/trace" fe_call '' fe_select plan)
assert_contains "$r" "|mismatch|" "frontend-intent-plan: reported"
r=$(FE_ENV="OMB_TUI_LOG=$T/trace" fe_call 'y\n' fe_select dry-run)
assert_contains "$r" "|mismatch|" "frontend-intent-dry-run: reported, never moved"
assert_eq "$(t_snapshot "$T/home"; t_snapshot "$T/state")" "$before" "plan and dry-run change nothing persistent"
[ ! -e "$T/trace" ] && ok || fail "no trace outside an act session"
rm -rf "$CACHE"
r=$(FE_ENV="OMB_TUI_LOG=$T/trace" fe_call 'y\n' fe_select dry-run)
assert_contains "$r" "0|verified|$T/tmp/omarchy-bootstrap." "frontend-intent-dry-run: downloaded into the per-run scratch"
[ ! -e "$CACHE" ] && ok || fail "frontend-intent-dry-run: nothing cached"
[ -z "$(ls "$T/tmp" | grep 'omarchy-bootstrap\.')" ] && ok || fail "and the scratch copy is gone when the run ends"
r=$(fe_call 'y\n' fe_select act)
printf '0 trace' >"$CACHE/$FAKE_SHA/fake-behaviour"
r=$(FE_ENV="OMB_TUI_LOG=$T/trace" fe_call '' fe_run plan journey)
assert_contains "$(cat "$T/tmp/fe-out")" "OMB_TUI_LOG is ignored outside an act session" "frontend-intent-plan: a one-line notice"
[ ! -e "$T/trace" ] && ok || fail "frontend-intent-plan: no trace"
r=$(FE_ENV="OMB_TUI_LOG=$T/trace" fe_call '' fe_run act journey)
[ -f "$T/trace" ] && ok || fail "frontend-intent-act: the trace written"
assert_eq "$(find "$T/trace" -perm 600 | wc -l | tr -d ' ')" 1 "frontend-intent-act: 0600"
rm -f "$T/trace"
printf 'tampered' >>"$CACHE/$FAKE_SHA/omb-tui"
before=$(t_snapshot "$T/home")
T_ENV="XDG_CACHE_HOME=$T/home/.cache OMB_TUI_LOG=$T/trace" t_cli mac-m1pro-1tb-roomy "" status
assert_rc "$T_RC" 0 "frontend-intent-read: status runs"
assert_eq "$(t_snapshot "$T/home")" "$before" "frontend-intent-read: the cache untouched"
T_ENV="XDG_CACHE_HOME=$T/home/.cache OMB_TUI_LOG=$T/trace" t_cli mac-m1pro-1tb-roomy "q\n" --no-tui
assert_eq "$(t_snapshot "$T/home")" "$before" "frontend-intent-no-tui: the cache untouched"
[ ! -e "$T/trace" ] && ok || fail "frontend-intent-read and -no-tui: no trace"
rm -rf "$CACHE"

# --- frontend-dev: the override outside fixture mode, or as root ------------------------
T_ENV="OMB_FRONTEND_DEV=$FAKE" t_cli "" "" status
assert_rc "$T_RC" 2 "frontend-dev: refused outside fixture mode"
assert_contains "$T_OUT" "work only in fixture mode" "and says so"
idshim=$(t_tmp)
printf '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' >"$idshim/id"
chmod +x "$idshim/id"
T_ENV="PATH=$idshim:/usr/bin:/bin OMB_FRONTEND_DEV=$FAKE" t_cli mac-m1pro-1tb-roomy "" status
assert_rc "$T_RC" 2 "frontend-dev: refused as root"
r=$(FE_FIX="" FE_ENV="OMB_FRONTEND_DEV=$FAKE" fe_call '' fe_select act)
assert_contains "$r" "|missing||OMB_FRONTEND_DEV works only in fixture mode" "the launcher checks it again"
r=$(FE_ENV="OMB_FRONTEND_DEV=$FAKE" fe_call '' fe_select act)
assert_contains "$r" "0|verified|$FAKE|" "in fixture mode, the unreleased build is used"
T_ENV="OMB_TEST_HANDOFF_CHILD=$FAKE" t_cli "" "" status
assert_rc "$T_RC" 2 "OMB_TEST_HANDOFF_CHILD is refused outside fixture mode"

# --- sup-owner-cleanup-refused: the owner leaves its scratch ---------------------------------
# A process that joined the group after launcher.omb and outlives the frontend.
printf '0 linger' >"$T/fake-behaviour"
r=$(FE_ENV="OMB_FRONTEND_DEV=$FAKE" fe_call '' fe_run act journey)
n=$(ls "$T/tmp" | grep -c '^omb-session\.')
assert_eq "$n" 1 "sup-owner-cleanup-refused: a late process in the group keeps the scratch"
sleep 3
old=$(ls -d "$T/tmp"/omb-session.* | head -1)
# The same scratch, once everything is dead, is reclaimed by a later launcher.
r=$(fe_call '' fe_reclaim)
[ ! -e "$old" ] && ok || fail "sup-reclaim-quiescent: reclaimed once every recorded identity is dead"

# The other conditions, one by one, on a scratch built as a launcher leaves it.
# mk_scratch — a session folder whose launcher and frontend are dead.
mk_scratch() {
  (
    export TMPDIR=$T/tmp OMB_FIXTURE=$FIXB
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    # shellcheck source=lib/core.sh
    . "$REPO/lib/core.sh"
    platform_init
    core_boot_read
    d=$(mktemp -d "$T/tmp/omb-session.XXXXXX")
    chmod 700 "$d"
    sleep 0.1 &
    dead=$!
    core_proc_write "$d/launcher.omb" launcher "$dead"
    core_proc_write "$d/frontend.omb" frontend "$dead"
    wait "$dead"
    printf '%s' "$d"
    omb_cleanup
  )
}
# proc_file FILE ROLE PID [START] — an identity file for PID (a start time
# other than its own models a reused PID).
proc_file() {
  (
    export OMB_FIXTURE=$FIXB
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    # shellcheck source=lib/core.sh
    . "$REPO/lib/core.sh"
    platform_init
    core_boot_read
    start=${4:-$(_proc_started "$3")}
    { printf 'omb-proc 1\n' && rec_line proc role "$2" pid "$3" start "$start" boot "${BOOT:-$CORE_BOOT}"; } >"$1"
    rec_seal_write "$1"
    omb_cleanup
  )
}
sleep 30 &
live=$!
d=$(mk_scratch)
proc_file "$d/req-1.core" core "$live"
fe_call '' fe_reclaim >/dev/null
[ -d "$d" ] && ok || fail "sup-reclaim-live-core: an old scratch whose core is alive is not reclaimed"
r=$(fe_call '' eval "FE_SESSION=$d FE_SNAP='' FE_PGID=0; fe_owner_cleanup")
[ -d "$d" ] && ok || fail "sup-owner-cleanup-refused: a live core keeps the scratch"
rm -f "$d/req-1.core"
proc_file "$d/req-1.worker-1" worker "$live"
fe_call '' fe_reclaim >/dev/null
[ -d "$d" ] && ok || fail "sup-reclaim-live-worker: a live recorded worker keeps it"
r=$(fe_call '' eval "FE_SESSION=$d FE_SNAP='' FE_PGID=0; fe_owner_cleanup")
[ -d "$d" ] && ok || fail "sup-owner-cleanup-refused: a live recorded worker keeps the scratch"
rm -f "$d/req-1.worker-1"
# A reused PID: the live process, with another start time, is not the worker.
proc_file "$d/req-1.worker-1" worker "$live" "Mon Jan  1 00:00:00 2001"
fe_call '' fe_reclaim >/dev/null
[ ! -d "$d" ] && ok || fail "sup-pid-reuse: a PID now owned by another process is not the recorded worker"
# A frontend alive, recorded; then one not yet recorded, named by its arguments.
d=$(mk_scratch)
proc_file "$d/frontend.omb" frontend "$live"
fe_call '' fe_reclaim >/dev/null
[ -d "$d" ] && ok || fail "sup-reclaim-live-controller: a live frontend recorded in frontend.omb keeps the scratch"
d2=$(mk_scratch)
rm -f "$d2/frontend.omb"
(exec -a "omb-tui --session $d2" sleep 30) &
named=$!
sleep 0.3
fe_call '' fe_reclaim >/dev/null
[ -d "$d2" ] && ok || fail "sup-reclaim-live-controller: a frontend named only by its arguments keeps the scratch"
kill "$named" 2>/dev/null
wait "$named" 2>/dev/null
fe_call '' fe_reclaim >/dev/null
[ ! -d "$d2" ] && ok || fail "and once it is gone, the scratch is reclaimed"
# An operation record naming the session.
d3=$(mk_scratch)
mkdir -p "$T/state/ops"
(
  t_load >/dev/null 2>&1
  # shellcheck source=lib/records.sh
  . "$REPO/lib/records.sh"
  f=$T/state/ops/journey.omb
  { printf 'omb-op 1\n' && rec_line op action test.mutate scope journey basis "$(printf '%064d' 1)" session "$d3" state unsupervised pid 1 start x boot x at 2026-09-26T00:00:00Z; } >"$f"
  rec_seal_write "$f"
  omb_cleanup
)
fe_call '' fe_reclaim >/dev/null
[ -d "$d3" ] && ok || fail "sup-reclaim-operation-barrier: an unresolved operation naming the session keeps it"
r=$(fe_call '' eval "FE_SESSION=$d3 FE_SNAP='' FE_PGID=0; fe_owner_cleanup")
[ -d "$d3" ] && ok || fail "sup-owner-cleanup-refused: an unresolved operation keeps the scratch"
rm -f "$T/state/ops/journey.omb"
# sup-identity-unknown: ps failing, or the boot session unreadable — nothing
# is deleted on the strength of an identity that cannot be established.
psshim=$(t_tmp)
printf '#!/bin/sh\nexit 1\n' >"$psshim/ps"
chmod +x "$psshim/ps"
d4=$(mk_scratch)
FE_PATH="$psshim:$BASE_PATH" fe_call '' fe_reclaim >/dev/null
[ -d "$d4" ] && ok || fail "sup-identity-unknown: ps failing, nothing is reclaimed"
fix2=$(t_variant mac-m1pro-1tb-roomy)
rm -f "$fix2/cmd/bootsession"
FE_FIX=$fix2 fe_call '' fe_reclaim >/dev/null
[ -d "$d4" ] && ok || fail "sup-identity-unknown: the boot session unreadable, nothing is reclaimed"
mv "$d4/launcher.omb" "$d4/launcher.gone"
fe_call '' fe_reclaim >/dev/null
[ -d "$d4" ] && ok || fail "a scratch whose launcher identity is missing counts as alive"
mv "$d4/launcher.gone" "$d4/launcher.omb"
# A launcher PID that is merely gone, with the rest alive, is never enough.
proc_file "$d4/req-2.core" core "$live"
fe_call '' fe_reclaim >/dev/null
[ -d "$d4" ] && ok || fail "sup-reclaim-quiescent: a dead launcher alone is never enough"
rm -f "$d4/req-2.core"
fe_call '' fe_reclaim >/dev/null
[ ! -d "$d4" ] && ok || fail "and with everything dead, it is"
# From a previous boot: every identity dead.
d5=$(mk_scratch)
BOOT=5E1D0B00-0000-0000-0000-000000000000 proc_file "$d5/req-1.core" core "$live"
fe_call '' fe_reclaim >/dev/null
[ ! -d "$d5" ] && ok || fail "sup-pid-reuse: a live PID recorded in a previous boot is not the recorded core"
kill "$live" 2>/dev/null
wait "$live" 2>/dev/null
[ -d "$d" ] && ok || fail "the live frontend's scratch is still there"
kill "$(sed -n 's/.*	pid=\([0-9]*\)	.*/\1/p' "$d/frontend.omb")" 2>/dev/null

# --- sup-eintr: a signal during the launcher's wait -----------------------------------------
printf '0 sleep' >"$T/fake-behaviour"
(FE_ENV="OMB_FRONTEND_DEV=$FAKE" fe_call '' fe_run act journey >"$T/eintr") &
bg=$!
sleep 0.8
pkill -TERM -f "bash -c .*fe_run act journey" 2>/dev/null
wait "$bg"
assert_contains "$(cat "$T/eintr")" "0|verified|" "sup-eintr: the launcher's wait is retried after a signal, and the frontend's status kept"

t_done test-frontend
