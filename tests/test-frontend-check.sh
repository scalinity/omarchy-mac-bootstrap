#!/usr/bin/env bash
# frontend-check-* (docs/TESTING.md → Frontend; docs/FRONTEND.md → The
# startup check): the check's launcher driven through its production route —
# no fixture, no development override, curl on its normal path — inside the
# hermetic boundary of tests/frontend-check-lib.sh, with stand-in frontends
# (shell scripts that speak the protocol to the real core) pinned by a test
# lock. The cases that need the released frontend itself on a real terminal
# are tests/frontend-check.sh's, run where CI builds it; the core's side of
# the session is tests/test-core.sh's; the route's static half is
# tests/test-static.sh's; routing against 569d67e is tests/test-baseline.sh's.
# shellcheck disable=SC2010,SC2012,SC2015,SC2016 # ls over names the test made; ok/fail always return 0; literal $ in steps
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-frontend-check"
T=$(t_tmp)
# shellcheck source=tests/frontend-check-lib.sh
. "$TESTS_DIR/frontend-check-lib.sh"

if ! fc_openssl; then
  fail "frontend-check-*: no OpenSSL openssl (3 or later) for the loopback HTTPS server"
  t_done test-frontend-check
  exit
fi
command -v script >/dev/null 2>&1 && ok || fail "frontend-check-*: no script(1) to give the launcher a terminal"
fc_setup && ok || fail "the hermetic boundary could not be made"
fc_guard
fc_serve && ok || fail "the loopback server did not start"
SA=$T/standin
fc_standin "$SA"
fc_pin "$SA"
SA_SHA=$FC_SHA SA_SIZE=$FC_SIZE
D=$FC_CACHE/$SA_SHA

# The confirmation the check asks before it downloads, and the one before it
# moves a mismatching copy aside.
Q_DOWNLOAD="Download and check it now?"
Q_MOVE="Move it aside and download the pinned one again?"
YES_DOWNLOAD=("wait:$Q_DOWNLOAD" "key:y\r")

# fc_reset — an empty cache, TMPDIR and logs, the pinned stand-in, a plan
# that completes.
fc_reset() {
  chmod -R u+w "$T/cache" 2>/dev/null
  rm -rf "$T/cache" "$T/tmp" "$T/standin-env" "$T/kept" "$T/order.log" "$T/lock-reads.log" "$T"/stty-* "$T/rm-refuse"
  mkdir -p "$T/cache" "$T/tmp"
  # One mode, whatever the runner's umask: the cache's own folder, as the
  # cases compare it.
  chmod 755 "$T/cache"
  : >"$T/forbid.log"
  FC_KEYS=()
  fc_plan hello "snapshot journey"
}

# fc_warm — the pinned stand-in in the cache, as a check that acquired it
# leaves it (folders and file 0700).
fc_warm() { (umask 077 && mkdir -p "$D") && cp "$SA" "$D/omb-tui" && chmod 700 "$D/omb-tui"; }

# fc_held NAME — what every case holds: no installer probe or action ran,
# no state folder was made, no text interface followed, and the run ended
# on its own.
fc_held() {
  assert_empty_file "$T/forbid.log" "$1: no installer probe or action ran (frontend-check-no-install-fallback)"
  if [ ! -e "$T/xstate/omarchy-mac-bootstrap" ] && [ ! -e "$T/home/.local" ]; then ok; else fail "$1: a state folder was made (frontend-check-no-state)"; fi
  assert_not_contains "$FC_TEXT" "Continuing in text" "$1: nothing continues in text"
  assert_not_contains "$FC_TEXT" "Stopped. Nothing destructive ran." "$1: nothing of the installer's interrupt either"
  [ ! -e "$T/pty/forced" ] && ok || fail "$1: the run did not end on its own"
}

# fc_tmp_empty NAME — nothing of the run is left in TMPDIR.
fc_tmp_empty() { assert_eq "$(ls -A "$T/tmp" | tr '\n' ' ')" "" "$1: nothing is left in TMPDIR"; }

# fc_untouched NAME — nothing was read, fetched, cached or started.
fc_untouched() {
  [ ! -s "$T/lock-reads.log" ] && ok || fail "$1: no lock read"
  assert_eq "$(fc_requests)" "$n0" "$1: no request made"
  assert_eq "$(fc_snap "$T/cache")" '. drwxr-xr-x' "$1: no cache inspected into existence"
  [ ! -e "$T/standin-env" ] && ok || fail "$1: no frontend started"
  fc_tmp_empty "$1"
}

# --- frontend-check-overrides-refused -------------------------------------------------------
fc_reset
fc_plan env hello "snapshot journey"
n0=$(fc_requests)
for e in "OMB_FIXTURE=$FIX/linux-alarm-fresh" "OMB_FRONTEND_DEV=$SA" "OMB_TEST_ARTIFACT=x" "OMB_TEST_HOOK=x" \
  "OMB_TEST_HANDOFF_CHILD=x" "OMB_TEST_RECORD=x" "OMB_TEST_AFTER=x" "OMB_TEST_RC=0" "OMB_TEST_QUAL_BYTES=1" \
  "OMB_TEST_STOP_AT=x" "OMB_TEST_FAIL_AT=x" "OMB_TEST_PAUSE_AT=x" "OMB_TEST_FUTURE=x"; do
  fc_run "$e"
  assert_eq "$FC_RC" 2 "frontend-check-overrides-refused: $e: status 2"
  assert_contains "$FC_TEXT" "frontend-check runs with no OMB_FIXTURE, OMB_FRONTEND_DEV or non-empty OMB_TEST_ variable set" "and says why ($e)"
  fc_untouched "frontend-check-overrides-refused ($e)"
  # With stdin not a terminal as well: the refusal, never the terminal's
  # verdict.
  fc_direct "$e"
  assert_eq "$FC_RC" 2 "frontend-check-overrides-refused: $e with stdin not a terminal: still status 2, the terminal not consulted"
  fc_held "frontend-check-overrides-refused ($e)"
done
fc_run -- extra
assert_eq "$FC_RC" 2 "frontend-check-overrides-refused: an extra argument is a usage error"
assert_contains "$FC_TEXT" "frontend-check takes no argument" "and says so"
fc_run -- --check
assert_eq "$FC_RC" 2 "frontend-check-overrides-refused: --check is not the check's"
fc_untouched "frontend-check-overrides-refused (arguments)"
# The seams keep their meaning for the commands and tests that own them.
t_cli linux-alarm-fresh "" status
assert_rc "$T_RC" 0 "frontend-check-overrides-refused: OMB_FIXTURE and OMB_TEST_RECORD still work for status"

# --- frontend-check-seam-controls: the classifier does not over-match ---------------------
for e in "OMB_TEST_FUTURE=" "OMB_TESTING=x" "OMB_TEST=x" "SOME_OMB_TEST_X=x"; do
  fc_run "$e" -- --dry-run
  assert_eq "$FC_RC" 1 "frontend-check-seam-controls: $e is not refused (the dry run answers, status 1)"
  assert_contains "$FC_TEXT" "frontend-check: not performed — a dry run" "frontend-check-seam-controls: $e reaches the dry run"
done
fc_held "frontend-check-seam-controls"

# --- frontend-check-ineligible-terminal, frontend-check-dry-run-ineligible ---------------------
for dry in "" --dry-run; do
  id=frontend-check-ineligible-terminal
  [ -n "$dry" ] && id=frontend-check-dry-run-ineligible
  fc_reset
  fc_plan env
  n0=$(fc_requests)
  fc_run -- --no-tui $dry
  assert_eq "$FC_RC" 1 "$id: --no-tui: status 1"
  assert_contains "$FC_TEXT" "frontend-check: not performed — --no-tui was given; the interactive check was not performed." "$id: --no-tui: not performed, and why"
  fc_untouched "$id (--no-tui)"
  fc_direct -- $dry
  assert_eq "$FC_RC" 1 "$id: stdin not a terminal: status 1"
  assert_contains "$FC_TEXT" "not performed — stdin is not a terminal" "$id: stdin not a terminal: not performed"
  fc_untouched "$id (stdin)"
  FC_STDOUT=1 fc_run -- $dry
  assert_eq "$FC_RC" 1 "$id: stdout not a terminal: status 1"
  assert_contains "$FC_TEXT" "not performed — stdout is not a terminal" "$id: stdout not a terminal: not performed"
  fc_untouched "$id (stdout)"
  FC_TERM="" fc_run -- $dry
  assert_eq "$FC_RC" 1 "$id: TERM unset: status 1"
  assert_contains "$FC_TEXT" "not performed — TERM is not set" "$id: TERM unset: not performed"
  fc_untouched "$id (TERM unset)"
  FC_TERM=dumb fc_run -- $dry
  assert_eq "$FC_RC" 1 "$id: TERM=dumb: status 1"
  assert_contains "$FC_TEXT" "not performed — TERM is dumb" "$id: TERM=dumb: not performed"
  fc_untouched "$id (TERM=dumb)"
  fc_held "$id"
done

# --- frontend-check-dry-run: cold, then warm --------------------------------------------------
fc_reset
fc_plan env
n0=$(fc_requests)
fc_run -- --dry-run
assert_eq "$FC_RC" 1 "frontend-check-dry-run: cold: status 1"
assert_contains "$FC_TEXT" "would run" "frontend-check-dry-run: what would happen, as would run"
assert_contains "$FC_TEXT" "ask [Y/n], then download https://127.0.0.1:$FC_PORT/omb-tui" "frontend-check-dry-run: cold: a download would be asked for"
assert_contains "$FC_TEXT" "no verified copy" "frontend-check-dry-run: cold: the cache's state"
assert_contains "$FC_TEXT" "SHA-256 $SA_SHA" "frontend-check-dry-run: the artifact"
assert_contains "$FC_TEXT" "frontend-check: not performed — a dry run: nothing was downloaded, moved or started." "frontend-check-dry-run: not performed"
[ -s "$T/lock-reads.log" ] && ok || fail "frontend-check-dry-run: the lock may be read"
assert_eq "$(fc_requests)" "$n0" "frontend-check-dry-run: cold: no request made"
assert_eq "$(fc_snap "$T/cache")" '. drwxr-xr-x' "frontend-check-dry-run: cold: nothing in the cache, not even a folder"
[ ! -e "$T/standin-env" ] && ok || fail "frontend-check-dry-run: no frontend or core started"
fc_tmp_empty "frontend-check-dry-run (cold): no session scratch, and the admission's per-run scratch removed"
fc_held "frontend-check-dry-run (cold)"
FC_KEYS=("${YES_DOWNLOAD[@]}")
fc_plan hello "snapshot journey"
fc_run
assert_eq "$FC_RC" 0 "frontend-check-dry-run: the cache filled by a check first"
warm=$(fc_snap "$T/cache")
n0=$(fc_requests)
FC_KEYS=()
fc_plan env
fc_run -- --dry-run
assert_eq "$FC_RC" 1 "frontend-check-dry-run: warm: status 1"
assert_contains "$FC_TEXT" "$D/omb-tui, verified" "frontend-check-dry-run: warm: the verified copy named"
assert_contains "$FC_TEXT" "would run start $D/omb-tui" "frontend-check-dry-run: warm: what would start"
assert_eq "$(fc_requests)" "$n0" "frontend-check-dry-run: warm: no request made"
assert_eq "$(fc_snap "$T/cache")" "$warm" "frontend-check-dry-run: warm: the cache byte-identical"
[ ! -e "$T/standin-env" ] && ok || fail "frontend-check-dry-run: warm: nothing started"
fc_tmp_empty "frontend-check-dry-run (warm)"

# --- frontend-check-cold-cache, frontend-check-warm-cache -------------------------------------
fc_reset
before=$(fc_snap "$T/cache")
n0=$(fc_requests)
FC_KEYS=("${YES_DOWNLOAD[@]}")
fc_run
assert_eq "$FC_RC" 0 "frontend-check-cold-cache: status 0"
for kv in "URL https://127.0.0.1:$FC_PORT/omb-tui" "Version 0.1.0 ($FC_TARGET)" "Size $SA_SIZE bytes" "SHA-256 $SA_SHA"; do
  assert_contains "$FC_TEXT" "$kv" "frontend-check-cold-cache: the provenance shown before [Y/n]"
done
assert_eq "$(fc_requests)" "$((n0 + 1))" "frontend-check-cold-cache: one HTTPS request"
assert_contains "$FC_TEXT" "frontend-check: completed — omb-tui 0.1.0 ($FC_TARGET), SHA-256 $SA_SHA, from $D/omb-tui." "frontend-check-cold-cache: completed, naming what it started"
cmp -s "$SA" "$D/omb-tui" && ok || fail "frontend-check-cold-cache: the promoted file is the pinned bytes"
after=$(fc_snap "$T/cache")
assert_eq "$(printf '%s\n' "$after" | grep -vxF -- "$before")" "./omarchy-mac-bootstrap drwx------
./omarchy-mac-bootstrap/frontend drwx------
./omarchy-mac-bootstrap/frontend/$SA_SHA drwx------
./omarchy-mac-bootstrap/frontend/$SA_SHA/omb-tui -rwx------ $(cksum <"$SA")" \
  "frontend-check-cold-cache: the only effect is <sha256>/omb-tui (0700), with its folders (0700)"
fc_tmp_empty "frontend-check-cold-cache"
fc_held "frontend-check-cold-cache"
COMPLETED=$FC_TEXT
# Warm: no request, the file hashed before it starts, the cache unchanged.
n0=$(fc_requests)
FC_KEYS=()
rm -f "$T/order.log"
fc_plan "note started" hello "snapshot journey"
fc_run
assert_eq "$FC_RC" 0 "frontend-check-warm-cache: status 0"
assert_not_contains "$FC_TEXT" "$Q_DOWNLOAD" "frontend-check-warm-cache: nothing asked"
assert_eq "$(fc_requests)" "$n0" "frontend-check-warm-cache: no request made"
assert_eq "$(tail -n 2 "$T/order.log" | sed 's/ .*//' | tr '\n' ' ')" "hash started " "frontend-check-warm-cache: the cached file hashed, then started"
assert_eq "$(fc_snap "$T/cache")" "$after" "frontend-check-warm-cache: the cache byte-identical"
fc_tmp_empty "frontend-check-warm-cache"
fc_held "frontend-check-warm-cache"
COMPLETED="$COMPLETED
$FC_TEXT"

# --- frontend-check-decline ------------------------------------------------------------------
fc_reset
fc_plan env
n0=$(fc_requests)
FC_KEYS=("wait:$Q_DOWNLOAD" "key:n\r")
fc_run
assert_eq "$FC_RC" 1 "frontend-check-decline: status 1"
assert_contains "$FC_TEXT" "frontend-check: not completed — missing: the interface was not downloaded." "frontend-check-decline: not completed, and why"
assert_eq "$(fc_requests)" "$n0" "frontend-check-decline: no request made"
assert_eq "$(fc_snap "$T/cache")" '. drwxr-xr-x' "frontend-check-decline: no cache folder made"
[ ! -e "$T/standin-env" ] && ok || fail "frontend-check-decline: nothing started"
fc_tmp_empty "frontend-check-decline"
fc_held "frontend-check-decline"

# --- frontend-check-bad-cache ------------------------------------------------------------------
# bad_copy — a user-cache file under the digest's name with other bytes: a
# program that leaves a mark if it is ever run.
bad_copy() {
  (umask 077 && mkdir -p "$D")
  printf '#!/bin/sh\n: >"%s"\n' "$T/bad-ran" >"$D/omb-tui"
  chmod 700 "$D/omb-tui"
  BAD_SUM=$(cksum <"$D/omb-tui")
}
fc_reset
bad_copy
before=$(fc_snap "$T/cache")
FC_KEYS=("wait:$Q_MOVE" "key:n\r")
fc_run
assert_eq "$FC_RC" 1 "frontend-check-bad-cache: the move declined: status 1"
assert_contains "$FC_TEXT" "is not the pinned bytes" "frontend-check-bad-cache: the mismatch named"
assert_contains "$FC_TEXT" "frontend-check: not completed — mismatch:" "frontend-check-bad-cache: declined: not completed"
assert_eq "$(fc_snap "$T/cache")" "$before" "frontend-check-bad-cache: declined: the file untouched"
[ ! -e "$T/bad-ran" ] && ok || fail "frontend-check-bad-cache: the mismatching file is never executed"
fc_held "frontend-check-bad-cache (declined)"
FC_KEYS=("wait:$Q_MOVE" "key:y\r" "wait:$Q_DOWNLOAD" "key:y\r")
fc_run
assert_eq "$FC_RC" 0 "frontend-check-bad-cache: the move accepted: completed"
aside=$(ls "$D" | grep '^omb-tui\.mismatch-')
assert_eq "$(printf '%s\n' "$aside" | grep -c .)" 1 "frontend-check-bad-cache: renamed omb-tui.mismatch-<stamp>"
assert_eq "$(cksum <"$D/$aside")" "$BAD_SUM" "frontend-check-bad-cache: the backup holds the old bytes"
cmp -s "$SA" "$D/omb-tui" && ok || fail "frontend-check-bad-cache: the pinned file downloaded and promoted"
[ ! -e "$T/bad-ran" ] && ok || fail "frontend-check-bad-cache: never executed"
assert_eq "$(ls -A "$D" | grep -c .)" 2 "frontend-check-bad-cache: the backup and the promoted file, nothing else"
fc_held "frontend-check-bad-cache (accepted)"
COMPLETED="$COMPLETED
$FC_TEXT"

# The root cache, at the cache-selection helper (never the runner's own): a
# fixture's root stands in for /, so sys_path gives the helper a temporary
# folder for /var/cache/omarchy-mac-bootstrap/frontend.
# helper INPUT CODE — CODE run in a shell holding the launcher's libraries,
# over that root, with INPUT on stdin: "FE_STATE|FE_BIN|FE_BAD".
RFIX=$(t_variant linux-omarchy-installed)
mkdir -p "$RFIX/net"
RD=$RFIX/root/var/cache/omarchy-mac-bootstrap/frontend/$SA_SHA
helper() {
  printf '%b' "$1" | env -i PATH="$T/shim:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$T/home" XDG_CACHE_HOME="$T/cache" TMPDIR="$T/tmp" \
    LANG=en_US.UTF-8 TERM=dumb OMB_FIXTURE="$RFIX" "$T_BASH" -c '
      . "$1/lib/common.sh"; . "$1/lib/ui.sh"; . "$1/lib/state.sh"; . "$1/lib/records.sh"; . "$1/lib/core.sh"; . "$1/lib/frontend.sh"
      OMB_HOME=$1
      OMB_COLOR=never; ui_init; platform_init; OMB_INTENT=read OMB_PERSIST=0; state_init; FE_CHECK=1
      eval "$2" >/dev/null 2>&1
      printf "%s|%s|%s\n" "${FE_STATE:-}" "${FE_BIN:-}" "${FE_BAD:-}"
      omb_cleanup
    ' bash "$TOOL" "$2"
}
fc_reset
(umask 022 && mkdir -p "$RD")
printf 'not the pinned bytes\n' >"$RD/omb-tui"
chmod 755 "$RD/omb-tui"
rsum=$(cksum <"$RD/omb-tui")
r=$(helper 'n\n' 'fe_select check')
assert_eq "$r" "missing||" "frontend-check-bad-cache: a failing root copy, none of the user's: never selected, never offered for moving; acquisition offered"
cp "$SA" "$RFIX/net/frontend-$FC_TARGET"
r=$(helper 'y\n' 'fe_select check')
assert_eq "$r" "verified|$D/omb-tui|" "frontend-check-bad-cache: the user's own copy acquired instead"
assert_eq "$(cksum <"$RD/omb-tui")" "$rsum" "frontend-check-bad-cache: the root copy never moved or changed"
assert_eq "$(ls -A "$RD" | tr '\n' ' ')" "omb-tui " "frontend-check-bad-cache: and nothing added beside it"
rm -rf "$T/cache"/*
cp "$SA" "$RD/omb-tui"
r=$(helper '' 'fe_select check')
assert_eq "$r" "verified|$RD/omb-tui|" "frontend-check-bad-cache: a verified root copy is started from where it is"
rm -rf "$RFIX"

# --- frontend-check-mismatch-then-download-fails ----------------------------------------------
# each: the move accepted, then the download fails; the backup stays, the
# attempt file is gone, nothing is promoted or run.
dl_fails() { # NAME REASON
  assert_eq "$FC_RC" 1 "frontend-check-mismatch-then-download-fails: $1: status 1"
  assert_contains "$FC_TEXT" "$2" "frontend-check-mismatch-then-download-fails: $1: why"
  assert_contains "$FC_TEXT" "frontend-check: not completed — " "frontend-check-mismatch-then-download-fails: $1: not completed"
  assert_contains "$FC_TEXT" "was moved aside to $D/omb-tui.mismatch-" "frontend-check-mismatch-then-download-fails: $1: the backup named"
  assert_eq "$(ls -A "$D" | sed 's/mismatch-.*/mismatch-/' | tr '\n' ' ')" "omb-tui.mismatch- " \
    "frontend-check-mismatch-then-download-fails: $1: the backup stays; no attempt file, no omb-tui"
  [ ! -e "$T/bad-ran" ] && [ ! -e "$T/standin-env" ] && ok || fail "frontend-check-mismatch-then-download-fails: $1: nothing run"
  fc_tmp_empty "frontend-check-mismatch-then-download-fails ($1)"
  fc_held "frontend-check-mismatch-then-download-fails ($1)"
}
MOVE_THEN_DOWNLOAD=("wait:$Q_MOVE" "key:y\r" "wait:$Q_DOWNLOAD" "key:y\r")
fc_reset
fc_plan env
bad_copy
fc_unserve
FC_KEYS=("${MOVE_THEN_DOWNLOAD[@]}")
fc_run
dl_fails "the server refuses" "the download failed (status 7): https://127.0.0.1:$FC_PORT/omb-tui"
fc_serve && fc_lock "$SA_SIZE" "$SA_SHA" || fail "the server could not be restarted"
fc_reset
fc_plan env
bad_copy
head -c "$((SA_SIZE - 1))" "$SA" >"$T/www/omb-tui"
FC_KEYS=("${MOVE_THEN_DOWNLOAD[@]}")
fc_run
dl_fails "the file cut short" "the download is $((SA_SIZE - 1)) bytes, not the $SA_SIZE the lock pins"
fc_reset
fc_plan env
bad_copy
{ head -c "$((SA_SIZE - 1))" "$SA"; printf X; } >"$T/www/omb-tui"
FC_KEYS=("${MOVE_THEN_DOWNLOAD[@]}")
fc_run
dl_fails "other bytes" "the download's SHA-256 is"
cp "$SA" "$T/www/omb-tui"

# --- frontend-check-mismatch-then-interrupted, frontend-check-cleanup-fails --------------------
# The server completes the handshake and never answers: the download stalls,
# its attempt file made, until the launcher is interrupted.
fc_serve stall && fc_lock "$SA_SIZE" "$SA_SHA" || fail "the stalling server did not start"
for sig in INT TERM; do
  fc_reset
  fc_plan env
  bad_copy
  if [ "$sig" = INT ]; then stop="key:\003"; else stop="signal:TERM"; fi
  FC_KEYS=("${MOVE_THEN_DOWNLOAD[@]}" "file:$D/.omb-tui.*" "sleep:0.5" "$stop")
  fc_run
  if [ "$sig" = INT ]; then want=130; else want=1; fi
  assert_eq "$FC_RC" "$want" "frontend-check-mismatch-then-interrupted: SIG$sig: status $want"
  assert_contains "$FC_TEXT" "frontend-check: not completed — stopped by SIG$sig before the interface started." "frontend-check-mismatch-then-interrupted: SIG$sig: said"
  assert_eq "$(ls -A "$D" | sed 's/mismatch-.*/mismatch-/' | tr '\n' ' ')" "omb-tui.mismatch- " \
    "frontend-check-mismatch-then-interrupted: SIG$sig: the backup stays; the attempt file removed once its writer ended; nothing promoted"
  [ ! -e "$T/bad-ran" ] && [ ! -e "$T/standin-env" ] && ok || fail "frontend-check-mismatch-then-interrupted: SIG$sig: nothing run"
  fc_tmp_empty "frontend-check-mismatch-then-interrupted (SIG$sig)"
  fc_held "frontend-check-mismatch-then-interrupted (SIG$sig)"
done
# frontend-check-cleanup-fails: the digest's folder made unwritable while
# the download stalls, then SIGTERM.
fc_reset
fc_plan env
FC_KEYS=("${YES_DOWNLOAD[@]}" "file:$D/.omb-tui.*" "sleep:0.5" "do:chmod 500 '$D'" "signal:TERM")
fc_run
chmod 700 "$D"
assert_eq "$FC_RC" 1 "frontend-check-cleanup-fails: status 1"
left=$(ls -A "$D")
assert_eq "$(printf '%s\n' "$left" | grep -c '^\.omb-tui\.')" 1 "frontend-check-cleanup-fails: the attempt file stays"
assert_contains "$FC_TEXT" "This attempt's download file could not be removed and remains: $D/$left." "frontend-check-cleanup-fails: and the report names it"
assert_eq "$(printf '%s\n' "$left" | grep -c .)" 1 "frontend-check-cleanup-fails: nothing else is in the folder, nothing else removed"
assert_not_contains "$FC_TEXT" "frontend-check: completed —" "frontend-check-cleanup-fails: no success reported"
fc_held "frontend-check-cleanup-fails"

# --- frontend-check-uncatchable-residue --------------------------------------------------------
# The launcher killed (SIGKILL) while the download stalls: no cleanup is
# promised, and no success reported. A following run never selects, runs
# or promotes what was left: it acquires the verified file itself.
fc_reset
fc_plan env hello "snapshot journey"
FC_KEYS=("${YES_DOWNLOAD[@]}" "file:$D/.omb-tui.*" "sleep:0.5" "signal:KILL")
fc_run
assert_eq "$FC_RC" 137 "frontend-check-uncatchable-residue: the launcher died of SIGKILL"
assert_not_contains "$FC_TEXT" "completed" "frontend-check-uncatchable-residue: no success reported"
# A new server: the old one's end also ends the orphaned download's writer.
fc_serve && fc_lock "$SA_SIZE" "$SA_SHA" || fail "the server could not be restarted"
residue=$(ls -A "$D" | grep '^\.omb-tui\.')
[ -n "$residue" ] && rsum=$(cksum <"$D/$residue")
FC_KEYS=("${YES_DOWNLOAD[@]}")
fc_run
assert_eq "$FC_RC" 0 "frontend-check-uncatchable-residue: the following run completes"
cmp -s "$SA" "$D/omb-tui" && ok || fail "frontend-check-uncatchable-residue: from a verified omb-tui it acquired"
if [ -n "$residue" ]; then
  assert_eq "$(cksum <"$D/$residue")" "$rsum" "frontend-check-uncatchable-residue: the residue neither selected, promoted nor changed"
else
  ok
fi
fc_held "frontend-check-uncatchable-residue"
COMPLETED="$COMPLETED
$FC_TEXT"
rm -rf "$T/tmp"/omarchy-bootstrap.*

# --- frontend-check-residue-never-selected -----------------------------------------------------
fc_reset
fc_plan env
(umask 077 && mkdir -p "$D")
cp "$SA" "$D/.omb-tui.AbC123"
cp "$SA" "$D/omb-tui.mismatch-20260101T000000Z"
before=$(fc_snap "$T/cache")
FC_KEYS=("wait:$Q_DOWNLOAD" "key:n\r")
fc_run
assert_eq "$FC_RC" 1 "frontend-check-residue-never-selected: acquisition offered as for an empty cache, declined"
assert_eq "$(fc_snap "$T/cache")" "$before" "frontend-check-residue-never-selected: neither selected, promoted nor removed"
[ ! -e "$T/standin-env" ] && ok || fail "frontend-check-residue-never-selected: neither run"
fc_held "frontend-check-residue-never-selected"

# --- frontend-check-promoted-then-exec-fails -----------------------------------------------------
fc_reset
printf '\177ELF\002\001\001\000\000\000garbage' >"$T/not-a-binary"
fc_pin "$T/not-a-binary"
FC_KEYS=("${YES_DOWNLOAD[@]}")
fc_run
assert_eq "$FC_RC" 1 "frontend-check-promoted-then-exec-fails: status 1"
assert_contains "$FC_TEXT" "frontend-check: not completed — unrunnable:" "frontend-check-promoted-then-exec-fails: unrunnable"
assert_contains "$FC_TEXT" "would not execute (status 126; SHA-256 $FC_SHA, $FC_TARGET)" "frontend-check-promoted-then-exec-fails: with its digest and target"
cmp -s "$T/not-a-binary" "$FC_CACHE/$FC_SHA/omb-tui" && ok || fail "frontend-check-promoted-then-exec-fails: the promoted file stays cached"
fc_tmp_empty "frontend-check-promoted-then-exec-fails"
fc_held "frontend-check-promoted-then-exec-fails"
fc_pin "$SA"

# --- frontend-check-promoted-then-startup-fails, frontend-check-lock (version) -----------------
# The lock naming another version: the core refuses the stand-in's hello
# (frontend 0.1.0) as `frontend`, and the stand-in leaves as the released
# frontend does, with status 10 and its words.
fc_reset
fc_pin "$SA" 0.2.0
fc_plan hello keep "say omb-tui: the core refused the session; continuing in the text interface." "exit 10"
FC_KEYS=("${YES_DOWNLOAD[@]}")
fc_run
assert_eq "$FC_RC" 1 "frontend-check-promoted-then-startup-fails: the core refusing hello: status 1"
assert_contains "$FC_TEXT" "frontend-check: not completed — fallback: the interface refused the session (status 10)." "frontend-check-promoted-then-startup-fails: fallback, never the installer's text flow"
assert_contains "$(cat "$T/kept/req-1.events")" "result	status=refused	code=frontend" "frontend-check-lock: a version other than the frontend's refused by the core as frontend"
cmp -s "$SA" "$D/omb-tui" && ok || fail "frontend-check-promoted-then-startup-fails: the promoted file stays cached"
fc_held "frontend-check-promoted-then-startup-fails (hello)"
fc_reset
fc_pin "$SA"
fc_plan hello "snapshot disk"
FC_KEYS=("${YES_DOWNLOAD[@]}")
fc_run
assert_eq "$FC_RC" 1 "frontend-check-promoted-then-startup-fails: the snapshot refused: status 1"
assert_contains "$FC_TEXT" "frontend-check: not completed — verified: the exchange req-2.events ended refused." "frontend-check-promoted-then-startup-fails: which exchange, and how it ended"
cmp -s "$SA" "$D/omb-tui" && ok || fail "frontend-check-promoted-then-startup-fails: the promoted file stays cached"
fc_tmp_empty "frontend-check-promoted-then-startup-fails (snapshot)"
fc_held "frontend-check-promoted-then-startup-fails (snapshot)"

# --- frontend-check-read-session, frontend-check-no-fixture ----------------------------------------
# An inherited purpose of any value is replaced; OMB_TUI_LOG is ignored.
fc_reset
fc_plan env hello "snapshot journey" keep
FC_KEYS=("${YES_DOWNLOAD[@]}")
fc_run "OMB_SESSION_PURPOSE=install" "OMB_TUI_LOG=$T/trace"
assert_eq "$FC_RC" 0 "frontend-check-read-session: completed"
for v in OMB_SESSION_INTENT=read OMB_SESSION_SCOPES=journey OMB_DRY_RUN=0 OMB_SESSION_PURPOSE=frontend-check "OMB_HOME=$TOOL"; do
  assert_eq "$(grep -c "^$v\$" "$T/standin-env")" 1 "frontend-check-read-session: the frontend gets $v"
done
assert_eq "$(grep -cE '^(OMB_FIXTURE|OMB_FRONTEND_DEV|OMB_TEST_[A-Z_]*|OMB_TUI_LOG)=' "$T/standin-env")" 0 \
  "frontend-check-no-fixture: no fixture, development, OMB_TEST_ or trace variable reaches the frontend or its cores"
for f in "$T"/kept/req-*.events; do
  assert_contains "$(sed -n 2p "$f")" "	ceiling=read	dry_run=0	fixture=0" "frontend-check-read-session: ${f##*/}'s hello: read, not a dry run, no fixture"
done
assert_contains "$FC_TEXT" "OMB_TUI_LOG is ignored: frontend-check writes no trace." "frontend-check-read-session: OMB_TUI_LOG ignored, with a notice"
[ ! -e "$T/trace" ] && ok || fail "frontend-check-read-session: no trace written"
fc_held "frontend-check-read-session"
COMPLETED="$COMPLETED
$FC_TEXT"

# --- frontend-check-no-install-fallback: every failure ends the check ----------------------------
# nofall NAME — a failure's report: not completed or unsettled, status 1, no
# installer routing (fc_held).
nofall() {
  assert_eq "$FC_RC" 1 "frontend-check-no-install-fallback: $1: status 1"
  assert_contains "$FC_TEXT" "frontend-check: not completed — " "frontend-check-no-install-fallback: $1: not completed"
  fc_held "frontend-check-no-install-fallback ($1)"
}
fc_reset
fc_warm
fc_plan hello
fc_run
nofall "no journey snapshot asked for"
assert_contains "$FC_TEXT" "no journey snapshot was answered" "and why"
fc_plan "exit 0"
fc_run
nofall "exits 0 before asking anything"
assert_contains "$FC_TEXT" "the interface asked the core nothing" "and why"
fc_plan hello "snapshot disk" "say omb-tui: the core refused the session; continuing in the text interface." "exit 10"
fc_run
nofall "another scope's snapshot, then status 10 with the released frontend's words"
assert_contains "$FC_TEXT" "fallback:" "and the launcher's own state"
fc_plan hello "snapshot journey" "exit 3"
fc_run
nofall "a crash"
assert_contains "$FC_TEXT" "crashed: the interface stopped (status 3)" "and the launcher's own state"
fc_plan hello "snapshot journey" dangle
fc_run
assert_eq "$FC_RC" 1 "frontend-check-no-install-fallback: a session left unsettled: status 1"
assert_contains "$FC_TEXT" "frontend-check: not completed — unsettled: the session is not known to be over (an identity the session recorded cannot be read)." "frontend-check-no-install-fallback: unsettled, and why"
assert_contains "$FC_TEXT" "The terminal and the session's files were left as they are" "and what was left"
assert_eq "$(ls -A "$T/tmp" | grep -c '^omb-session\.')" 1 "frontend-check-no-install-fallback: the unsettled scratch kept"
fc_held "frontend-check-no-install-fallback (unsettled)"
rm -rf "$T/tmp"/omb-session.*
cp "$TOOL/release/frontend.lock" "$T/lock.good"
printf 'x' >>"$TOOL/release/frontend.lock"
fc_run
nofall "an inadmissible lock"
assert_contains "$FC_TEXT" "release/frontend.lock is not admissible (" "frontend-check-lock: a broken seal"
fc_lock "$SA_SIZE" "$SA_SHA" 0.1.0 x86_64-apple-darwin
fc_run
nofall "no artifact for the target"
assert_contains "$FC_TEXT" "the lock pins no frontend for $FC_TARGET" "frontend-check-lock: no artifact for the target"
fc_lock "$SA_SIZE" "$(printf '%064d' 1)"
FC_KEYS=("${YES_DOWNLOAD[@]}")
fc_run
nofall "a lock with another digest"
assert_contains "$FC_TEXT" "the download's SHA-256 is $SA_SHA, not the $(printf '%064d' 1) the lock pins" "frontend-check-lock: another digest: never the served binary"
fc_lock "$((SA_SIZE + 1))" "$SA_SHA"
rm -rf "${T:?}/cache/omarchy-mac-bootstrap"
fc_run
nofall "a lock with another size"
assert_contains "$FC_TEXT" "the download is $SA_SIZE bytes, not the $((SA_SIZE + 1)) the lock pins" "frontend-check-lock: another size"
[ ! -e "$T/standin-env" ] && ok || fail "frontend-check-lock: a binary the lock does not pin never runs"
cp "$T/lock.good" "$TOOL/release/frontend.lock"

# --- frontend-check-early-quit-late-snapshot, frontend-check-refresh-failure ----------------------
fc_reset
fc_pin "$SA"
FC_KEYS=("${YES_DOWNLOAD[@]}")
fc_run
fc_plan hello "late journey" "exit 0"
FC_KEYS=()
fc_run
assert_eq "$FC_RC" 0 "frontend-check-early-quit-late-snapshot: a snapshot answered after the frontend left: completed"
assert_contains "$FC_TEXT" "answered hello and the journey snapshot" "frontend-check-early-quit-late-snapshot: the exchanges named"
COMPLETED="$COMPLETED
$FC_TEXT"
fc_plan hello "snapshot journey" "snapshot disk"
fc_run
assert_eq "$FC_RC" 1 "frontend-check-refresh-failure: a refresh refused: status 1"
assert_contains "$FC_TEXT" "the exchange req-3.events ended refused" "frontend-check-refresh-failure: no recovery rule"
fc_plan hello "snapshot journey" "killed journey"
fc_run
assert_eq "$FC_RC" 1 "frontend-check-refresh-failure: a refresh left incomplete (its core killed): status 1"
assert_contains "$FC_TEXT" "the exchange req-3.events is not a whole answer" "frontend-check-refresh-failure: incomplete"
# What the killed core's own death left (its per-run scratch) may remain;
# nothing of the launcher's.
assert_eq "$(ls -A "$T/tmp" | sed 's/\..*//' | tr '\n' ' ')" "omarchy-bootstrap " "frontend-check-refresh-failure: only the killed core's own scratch is left"
rm -rf "$T/tmp"/omarchy-bootstrap.*
fc_held "frontend-check-refresh-failure"

# --- frontend-check-termios ----------------------------------------------------------------------
# The launcher's stty, through a shim: its saved settings unreadable; its
# settings printed by a stty -g that fails, and a stty -g that prints
# nothing; the restore failing; the settings read back other than saved.
# A flag made before the run meets the save, one the stand-in makes meets
# the readback.
mkdir -p "$T/termios-shim"
real=$(command -v stty)
printf '#!/bin/sh\nif [ "$1" = -g ]; then\n  [ -e "%s/stty-nosave" ] && exit 1\n  [ -e "%s/stty-g-empty" ] && exit 0\n  o=$(%s -g) || exit 1\n  [ -e "%s/stty-differ" ] && o="$o:1"\n  printf "%%s\\n" "$o"\n  [ -e "%s/stty-g-fails" ] && exit 1\n  exit 0\nfi\n[ -e "%s/stty-norestore" ] && exit 1\nexec %s "$@"\n' \
  "$T" "$T" "$real" "$T" "$T" "$T" "$real" >"$T/termios-shim/stty"
chmod +x "$T/termios-shim/stty"
guard_path=$FC_PATH
FC_PATH="$T/termios-shim:$guard_path"
fc_reset
fc_warm
fc_run
assert_eq "$FC_RC" 0 "frontend-check-termios: through the shim, saved and read back equal: completed"
fc_plan env hello "snapshot journey"
: >"$T/stty-nosave"
fc_run
assert_eq "$FC_RC" 1 "frontend-check-termios: the saved settings unreadable: status 1"
assert_contains "$FC_TEXT" "the terminal's settings could not be saved, so the interface was not started" "frontend-check-termios: and why"
[ ! -e "$T/standin-env" ] && ok || fail "frontend-check-termios: no frontend started without them"
rm -f "$T/stty-nosave"
for flag in stty-g-fails stty-g-empty; do
  : >"$T/$flag"
  fc_run
  assert_eq "$FC_RC" 1 "frontend-check-termios: the save by a $flag stty -g: status 1"
  assert_contains "$FC_TEXT" "the terminal's settings could not be saved, so the interface was not started" "frontend-check-termios: $flag, and why"
  [ ! -e "$T/standin-env" ] && ok || fail "frontend-check-termios: $flag, no frontend started"
  rm -f "$T/$flag" "$T/standin-env"
  fc_plan hello "snapshot journey" "touch $T/$flag"
  fc_run
  assert_eq "$FC_RC" 1 "frontend-check-termios: the readback by a $flag stty -g: status 1"
  assert_contains "$FC_TEXT" "the terminal's settings could not be read again" "frontend-check-termios: $flag readback, and why"
  rm -f "$T/$flag"
  fc_plan env hello "snapshot journey"
done
fc_plan hello "snapshot journey" "touch $T/stty-norestore"
fc_run
assert_eq "$FC_RC" 1 "frontend-check-termios: the restore failing: status 1"
assert_contains "$FC_TEXT" "the terminal's saved settings could not be put back" "frontend-check-termios: and why"
rm -f "$T/stty-norestore"
fc_plan hello "snapshot journey" "touch $T/stty-differ"
fc_run
assert_eq "$FC_RC" 1 "frontend-check-termios: settings read back differently: status 1"
assert_contains "$FC_TEXT" "the terminal's settings read back other than they were saved" "frontend-check-termios: and why"
rm -f "$T/stty-differ"
fc_tmp_empty "frontend-check-termios"
fc_held "frontend-check-termios"
FC_PATH=$guard_path

# --- frontend-check-completion-order -------------------------------------------------------------
# The launcher's own head, stty, ps and rm, logged (fc_order): the settings
# saved, the spools admitted after the quiescence reading, the settings put
# back and read again, then owner cleanup's reading and the removal, and
# nothing read after it. A scratch that cannot be removed forbids completed.
fc_order
FC_PATH="$T/order-shim:$guard_path"
fc_reset
fc_warm
fc_run
assert_eq "$FC_RC" 0 "frontend-check-completion-order: completed"
seq=$(fc_order_seq "$(cat "$T/pty/pid")")
printf '%s' "$seq" | grep -qE '^GP+H+SGPR$' && ok ||
  fail "frontend-check-completion-order: settings saved, quiescence, the spools, the settings back and read, owner cleanup, removal — in that order, nothing after (got $seq)"
COMPLETED="$COMPLETED
$FC_TEXT"
: >"$T/rm-refuse"
fc_run
rm -f "$T/rm-refuse"
assert_eq "$FC_RC" 1 "frontend-check-completion-order: a scratch that cannot be removed: status 1"
assert_contains "$FC_TEXT" "frontend-check: not completed — verified: the session's files could not be removed." "frontend-check-completion-order: not completed, and why"
assert_contains "$FC_TEXT" "The session's files remain: $T/tmp/omb-session." "frontend-check-completion-order: the scratch named"
rm -rf "$T/tmp"/omb-session.*
# Owner cleanup's status and the scratch's absence each forbid completed:
# a cleanup that removed the scratch and still failed; one that succeeded
# and left it.
: >"$T/rm-fails-after"
fc_run
rm -f "$T/rm-fails-after"
assert_eq "$FC_RC" 1 "frontend-check-completion-order: a cleanup that failed with the scratch gone: status 1"
assert_contains "$FC_TEXT" "frontend-check: not completed — verified: the session's cleanup reported a failure." "frontend-check-completion-order: the failed cleanup, and why"
assert_not_contains "$FC_TEXT" "The session's files remain" "frontend-check-completion-order: no scratch claimed to remain"
fc_tmp_empty "frontend-check-completion-order: a cleanup that failed with the scratch gone"
: >"$T/rm-skip"
fc_run
rm -f "$T/rm-skip"
assert_eq "$FC_RC" 1 "frontend-check-completion-order: a cleanup that succeeded and left the scratch: status 1"
assert_contains "$FC_TEXT" "frontend-check: not completed — verified: the session's files could not be removed." "frontend-check-completion-order: the scratch left, and why"
assert_contains "$FC_TEXT" "The session's files remain: $T/tmp/omb-session." "frontend-check-completion-order: the scratch left, named"
rm -rf "$T/tmp"/omb-session.*
FC_PATH=$guard_path

# --- frontend-check-cleanup: the frontend killed while idle ---------------------------------------
fc_reset
fc_warm
fc_plan hello "snapshot journey" idle
# kill_idle — the stand-in, by the identity the launcher recorded for it.
kill_idle() {
  local f
  f=$(ls -d "$T"/tmp/omb-session.*/frontend.omb 2>/dev/null | head -1)
  id=$(sed -n 's/.*	pid=\([0-9]*\)	start=\([^	]*\)	.*/\1 \2/p' "$f" | sed 's/%20/ /g')
  t_signal KILL "${id%% *}" "${id#* }"
}
FC_KEYS=("file:$T/tmp/omb-session.*/req-2.events" "sleep:1" "do:kill_idle")
fc_run
assert_eq "$FC_RC" 1 "frontend-check-cleanup: the frontend killed: status 1"
assert_contains "$FC_TEXT" "frontend-check: not completed — crashed: the interface stopped (status 137)." "frontend-check-cleanup: crashed"
fc_tmp_empty "frontend-check-cleanup: the per-run and session scratch removed once the session was quiescent"
fc_held "frontend-check-cleanup"

# --- frontend-check-no-render-claim ---------------------------------------------------------------
n=$(printf '%s\n' "$COMPLETED" | grep -c 'frontend-check: completed — ')
[ "$n" -ge 7 ] && ok || fail "frontend-check-no-render-claim: only $n completed reports gathered"
assert_eq "$(printf '%s\n' "$COMPLETED" | grep 'frontend-check: completed — ' | grep -ciE 'dashboard|drawn|draw|shown|display|render|receiv|seen|visible')" 0 \
  "frontend-check-no-render-claim: no completed report says what was drawn, shown or received"
assert_eq "$(printf '%s\n' "$COMPLETED" | grep 'frontend-check: completed — ' | grep -c 'answered hello and the journey snapshot, every exchange of the session ended done')" "$n" \
  "frontend-check-no-render-claim: each names the exchanges and the session's end"

fc_unserve
t_done test-frontend-check
