#!/usr/bin/env bash
# frontend-check-* with the released frontend itself (docs/TESTING.md →
# frontend-check-*): the native release build CI makes for the PTY tests (no
# test-hooks feature), pinned by a test lock, served over the loopback and
# started by the check's launcher on a real terminal. frontend-check-terminal
# is rendering evidence, read from the screen a terminal would hold — never
# from the spools — and no run whose screen never showed the dashboard
# counts, whatever its report said. Run by the arm64 frontend jobs, which
# build that artifact:
#
#   OMB_TEST_ARTIFACT=path/to/release/omb-tui tests/frontend-check.sh
#
# The artifact's path is this script's alone: the launcher runs with a
# sealed environment (tests/frontend-check-lib.sh) that holds no OMB_TEST_
# variable. The stand-in cases, which need no build, are
# tests/test-frontend-check.sh's.
# shellcheck disable=SC2010,SC2012,SC2015,SC2119 # ls over names the test made; ok/fail always return 0; fc_run takes its arguments only where a case sets one
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "frontend-check (the native frontend)"
T=$(t_tmp)
# shellcheck source=tests/frontend-check-lib.sh
. "$TESTS_DIR/frontend-check-lib.sh"

ART=${OMB_TEST_ARTIFACT:-}
if [ -z "$ART" ] || [ ! -x "$ART" ]; then
  fail "OMB_TEST_ARTIFACT names no executable native build (got '$ART'); these cases need it and are never skipped"
  t_done frontend-check
  exit 1
fi
if ! fc_openssl; then
  fail "no OpenSSL openssl (3 or later) for the loopback HTTPS server"
  t_done frontend-check
  exit 1
fi
fc_setup && ok || fail "the hermetic boundary could not be made"
fc_guard
guard_path=$FC_PATH
fc_serve && ok || fail "the loopback server did not start"
# The native build's own version: the crate's. The check's core refuses a
# frontend whose version is not the lock's, so the lock pinned for this build
# names the version the build carries (an unreleased candidate is not 0.1.0).
# CP1's published-artifact driver supplies the admitted production lock's
# version. This override belongs only to this test driver, never fc_run's
# sealed launcher environment.
FC_VERSION=${OMB_TEST_ARTIFACT_VERSION:-$(sed -n 's/^version = "\(.*\)"$/\1/p' "$REPO/frontend/Cargo.toml" | sed -n 1p)}
[ -n "$FC_VERSION" ] && ok || fail "the crate's version cannot be read from frontend/Cargo.toml"
fc_pin "$ART" "$FC_VERSION"
D=$FC_CACHE/$FC_SHA
Q_DOWNLOAD="Download and check it now?"
Q_MOVE="Move it aside and download the pinned one again?"
DASH="Nothing is available now."

# held NAME — no installer probe or action, no state folder, nothing left
# in TMPDIR, the run ended on its own.
held() {
  assert_empty_file "$T/forbid.log" "$1: no installer probe or action ran"
  if [ ! -e "$T/xstate/omarchy-mac-bootstrap" ] && [ ! -e "$T/home/.local" ]; then ok; else fail "$1: a state folder was made"; fi
  assert_eq "$(ls -A "$T/tmp" | tr '\n' ' ')" "" "$1: nothing is left in TMPDIR"
  [ ! -e "$T/pty/forced" ] && ok || fail "$1: the run did not end on its own"
}
COMPLETED=""

# --- frontend-check-terminal, frontend-check-cold-cache, frontend-check-no-fixture ---------------
# The command, the cache cold then filled on the normal path; on the real
# terminal: the connecting screen, then the dashboard; ? opens the keys,
# Esc goes back (the released frontend closes help with Esc, ? or q:
# frontend/src/app.rs); q leaves.
n0=$(fc_requests)
FC_KEYS=("wait:$Q_DOWNLOAD" "key:y\r" "wait:$DASH" "mark:dashboard" "key:?" "wait:The mouse is not captured" "mark:help"
  "key:\033" "wait:$DASH" "mark:back" "key:q")
fc_run
assert_eq "$FC_RC" 0 "frontend-check-terminal: status 0"
assert_eq "$(fc_requests)" "$((n0 + 1))" "frontend-check-cold-cache: one HTTPS request"
cmp -s "$ART" "$D/omb-tui" && ok || fail "frontend-check-cold-cache: the promoted file is the pinned build"
dash=$(fc_frame "$(fc_mark dashboard)")
fc_dashboard "$dash" && ok || fail "frontend-check-terminal: the dashboard, with the check's four facts and \"$DASH\", on the screen"
stream=$(fc_text <"$T/pty/out")
case "$stream" in
  *"Asking the core who it is"*"$DASH"*) ok ;;
  *) fail "frontend-check-terminal: the connecting screen gave way to the dashboard (the frontend consumed the snapshot)" ;;
esac
assert_eq "$(printf '%s\n' "$dash" | sed -n 1p | grep -ciE 'fixture|dry run')" 0 "frontend-check-no-fixture: the header shows neither a fixture nor a dry-run tag"
help=$(fc_frame "$(fc_mark help)")
assert_contains "$help" "The mouse is not captured" "frontend-check-terminal: ? answered with the keys"
assert_not_contains "$help" "$DASH" "frontend-check-terminal: in place of the dashboard"
fc_dashboard "$(fc_frame "$(fc_mark back)")" && ok || fail "frontend-check-terminal: and back to the dashboard"
assert_eq "$(fc_frame "" | tail -n 1)" "@alt=0 cursor=1" "frontend-check-terminal: q left: the alternate screen left, the cursor shown"
cmp -s "$T/pty/before" "$T/pty/after" && ok || fail "frontend-check-terminal: the terminal's settings equal the ones before"
assert_contains "$FC_TEXT" "frontend-check: completed — omb-tui $FC_VERSION ($FC_TARGET), SHA-256 $FC_SHA, from $D/omb-tui." "frontend-check-terminal: the report completed"
held "frontend-check-terminal"
COMPLETED="$COMPLETED
$FC_TEXT"
cold=$(fc_snap "$T/cache")

# --- frontend-check-warm-cache ---------------------------------------------------------------------
n0=$(fc_requests)
FC_KEYS=("wait:$DASH" "mark:dashboard" "key:q")
fc_run
assert_eq "$FC_RC" 0 "frontend-check-warm-cache: status 0"
assert_eq "$(fc_requests)" "$n0" "frontend-check-warm-cache: no request made"
fc_dashboard "$(fc_frame "$(fc_mark dashboard)")" && ok || fail "frontend-check-warm-cache: the dashboard on the screen"
assert_eq "$(fc_snap "$T/cache")" "$cold" "frontend-check-warm-cache: the cache byte-identical"
held "frontend-check-warm-cache"
COMPLETED="$COMPLETED
$FC_TEXT"

# --- frontend-check-bad-cache: the move accepted --------------------------------------------------
printf '#!/bin/sh\n: >"%s"\n' "$T/bad-ran" >"$D/omb-tui"
FC_KEYS=("wait:$Q_MOVE" "key:y\r" "wait:$Q_DOWNLOAD" "key:y\r" "wait:$DASH" "key:q")
fc_run
assert_eq "$FC_RC" 0 "frontend-check-bad-cache: moved aside, acquired again: completed"
assert_eq "$(ls "$D" | grep -c '^omb-tui\.mismatch-')" 1 "frontend-check-bad-cache: the backup kept"
cmp -s "$ART" "$D/omb-tui" && ok || fail "frontend-check-bad-cache: the pinned build in its place"
[ ! -e "$T/bad-ran" ] && ok || fail "frontend-check-bad-cache: the mismatching file never executed"
held "frontend-check-bad-cache"
COMPLETED="$COMPLETED
$FC_TEXT"

# --- frontend-check-completion-order -----------------------------------------------------------------
fc_order
FC_PATH="$T/order-shim:$guard_path"
rm -f "$T/order.log"
FC_KEYS=("wait:$DASH" "key:q")
fc_run
FC_PATH=$guard_path
assert_eq "$FC_RC" 0 "frontend-check-completion-order: completed"
seq=$(fc_order_seq "$(cat "$T/pty/pid")")
printf '%s' "$seq" | grep -qE '^GP+H+SGPR$' && ok ||
  fail "frontend-check-completion-order: settings saved, quiescence, the spools, the settings back and read, owner cleanup, removal (got $seq)"
held "frontend-check-completion-order"
COMPLETED="$COMPLETED
$FC_TEXT"

# --- frontend-check-cleanup: the frontend killed while idle -----------------------------------------
kill_frontend() {
  local f id
  f=$(ls -d "$T"/tmp/omb-session.*/frontend.omb 2>/dev/null | head -1)
  id=$(sed -n 's/.*	pid=\([0-9]*\)	start=\([^	]*\)	.*/\1 \2/p' "$f" | sed 's/%20/ /g')
  t_signal KILL "${id%% *}" "${id#* }"
}
FC_KEYS=("wait:$DASH" "sleep:0.5" "do:kill_frontend")
fc_run
assert_eq "$FC_RC" 1 "frontend-check-cleanup: the frontend killed: status 1"
assert_contains "$FC_TEXT" "frontend-check: not completed — crashed: the interface stopped (status 137)." "frontend-check-cleanup: crashed"
assert_eq "$(fc_frame "" | tail -n 1)" "@alt=0 cursor=1" "frontend-check-cleanup: the launcher left the alternate screen and showed the cursor"
# (The settings are put back too, but not compared here: a frontend killed
# in raw mode can leave input unread, and the kernel then marks it pending
# — macOS's PENDIN — as the terminal returns to canonical mode.)
held "frontend-check-cleanup"

# --- frontend-check-early-quit-late-snapshot: never rendering evidence ------------------------------
# q on the connecting screen. Whatever the command's result, the recorded
# screen at q never showed the dashboard, and the PTY check rejects it.
FC_KEYS=("wait:Asking the core who it is" "mark:connecting" "key:q")
fc_run
fc_dashboard "$(fc_frame "$(fc_mark connecting)")" && fail "frontend-check-early-quit-late-snapshot: a connecting screen was taken for the dashboard" || ok
case "$FC_RC" in 0 | 1) ok ;; *) fail "frontend-check-early-quit-late-snapshot: status $FC_RC" ;; esac
[ "$FC_RC" = 0 ] && COMPLETED="$COMPLETED
$FC_TEXT"
held "frontend-check-early-quit-late-snapshot"

# --- frontend-check-no-render-claim ------------------------------------------------------------------
assert_eq "$(printf '%s\n' "$COMPLETED" | grep 'frontend-check: completed — ' | grep -ciE 'dashboard|drawn|draw|shown|display|render|receiv|seen|visible')" 0 \
  "frontend-check-no-render-claim: no completed report says what was drawn, shown or received"

fc_unserve
t_done "frontend-check (the native frontend)"
