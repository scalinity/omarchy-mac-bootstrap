#!/usr/bin/env bash
# The command surface, output degradation, doctor/status/sources/logs.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-cli"
ESC=$(printf '\033')

non_ascii() { printf '%s' "$1" | LC_ALL=C tr -d '\11\12\15\40-\176' | wc -c | tr -d ' '; }

# --- Help, version, unknown ---------------------------------------------------
t_cli mac-m1pro-1tb-roomy "" --help
assert_rc "$T_RC" 0 "--help exits 0"
for w in plan install resume status doctor dev sources logs --dry-run --no-color --ascii; do
  assert_contains "$T_OUT" "$w" "help lists $w"
done
t_cli mac-m1pro-1tb-roomy "" --version
assert_eq "$T_OUT" "omarchy-bootstrap 0.1.0" "--version"
t_cli mac-m1pro-1tb-roomy "" frobnicate
assert_rc "$T_RC" 2 "unknown command exits 2"
assert_contains "$T_OUT" "Unknown command: frobnicate" "unknown command named"

# --- Degradation ----------------------------------------------------------------
t_cli mac-m1pro-1tb-roomy "" --help
assert_not_contains "$T_OUT" "$ESC" "no escape codes when stdout is not a terminal"
T_ENV="OMB_COLOR=always" t_cli mac-m1pro-1tb-roomy "" --help --no-color
assert_not_contains "$T_OUT" "${ESC}[38" "--no-color wins over forced colour"
T_ENV="OMB_COLOR=always" t_cli mac-m1pro-1tb-roomy "" --help
assert_contains "$T_OUT" "${ESC}[38;5;209m" "256-colour palette when forced"
t_cli mac-m1pro-1tb-roomy "" --help --ascii
assert_eq "$(non_ascii "$T_OUT")" 0 "--ascii output is pure ASCII"
T_ENV="TERM=linux" t_cli linux-alarm-fresh "" doctor
assert_eq "$(non_ascii "$T_OUT")" 0 "the Linux console gets ASCII"
T_ENV="LANG=C" t_cli mac-m1pro-1tb-roomy "" --help
assert_eq "$(non_ascii "$T_OUT")" 0 "a non-UTF-8 locale gets ASCII"

# --- Doctor ----------------------------------------------------------------------
if command -v plutil >/dev/null 2>&1; then
  t_cli mac-m1pro-1tb-roomy "" doctor
  assert_rc "$T_RC" 0 "doctor passes on a supported Mac"
  assert_contains "$T_OUT" "[PASS] Apple Silicon" "doctor PASS line"
  assert_contains "$T_OUT" "[WARN] Backup confirmed" "backup is a warning until confirmed"
  assert_contains "$T_OUT" "[INFO] macOS" "macOS stays"
  t_cli mac-intel "" doctor
  assert_rc "$T_RC" 1 "doctor fails on Intel"
  assert_contains "$T_OUT" "[FAIL] Apple Silicon" "Intel FAIL line"
  t_cli mac-m2-512 "" doctor
  assert_contains "$T_OUT" "[WARN] APFS resize overhead" "snapshot overhead warns"
  t_cli mac-asahi-installed "" doctor
  assert_contains "$T_OUT" "[INFO] Existing install" "existing install noted"
else
  skip "macOS doctor (no plutil)"
fi
t_cli linux-omarchy-installed "" doctor
assert_rc "$T_RC" 0 "doctor passes on an installed machine"
for w in "[PASS] Btrfs root" "[PASS] Omarchy 4" "[PASS] Snapper" "[PASS] Encryption" "[INFO] SSH"; do
  assert_contains "$T_OUT" "$w" "installed doctor: $w"
done
t_cli linux-alarm-offline "" doctor
assert_rc "$T_RC" 1 "doctor fails offline"
assert_contains "$T_OUT" "[FAIL] Network" "offline FAIL line"
t_cli linux-setup-in-progress "" doctor
assert_contains "$T_OUT" "guided setup paused" "paused upstream setup surfaced"

# --- Plan → status → token (macOS) ---------------------------------------------------
if command -v plutil >/dev/null 2>&1; then
  t_cli mac-m1pro-1tb-roomy '\n\n\n\n\nm1pro\n\n\n\n\n\n\n\n' plan
  assert_contains "$T_OUT" "Plan saved" "plan saves"
  assert_empty_file "$T_DIR/record" "plan runs nothing"
  st=$(cat "$T_DIR/state/state.env")
  assert_contains "$st" "cfg_linux=250" "plan recorded the Linux size"
  assert_contains "$st" "plan_macos_new_gb=745" "plan recorded the macOS size"
  assert_contains "$st" "cfg_host=m1pro" "plan recorded the hostname"
  state_dir=$T_DIR/state
  T_ENV="OMB_STATE_DIR=$state_dir" t_cli mac-m1pro-1tb-roomy "" status
  assert_contains "$T_OUT" "Linux 250 GB" "status shows the plan"
  assert_contains "$T_OUT" "confirm the backup" "status names the next action"
  assert_contains "$T_OUT" "resume omb1:enc=1,user=alex,host=m1pro" "status shows the token"
  T_ENV="OMB_STATE_DIR=$state_dir" t_cli mac-asahi-installed "" resume
  assert_contains "$T_OUT" "Phase 1 is done" "resume on macOS after install"
  assert_contains "$T_OUT" "https://github.com/example/omarchy-mac-bootstrap/archive/refs/heads/main.tar.gz" "public continuation printed"
  assert_contains "$T_OUT" "./omarchy-bootstrap resume omb1:" "token printed after reboot guide"
fi

if command -v plutil >/dev/null 2>&1; then
  t_cli mac-intel "" status
  assert_contains "$T_OUT" "This Mac cannot continue: This Mac is not Apple Silicon" "status names the blocker"
fi

# --- Linux status and plan -------------------------------------------------------------
t_cli linux-setup-in-progress "" status
assert_contains "$T_OUT" "omarchy-mac-setup --status" "status includes upstream status"
assert_contains "$T_OUT" "next step       omarchy" "upstream status body"
t_cli linux-alarm-fresh '\nalex\nm1pro\n\n' plan
assert_contains "$(cat "$T_DIR/state/state.env")" "cfg_user=alex" "linux plan saves choices"
assert_empty_file "$T_DIR/record" "linux plan runs nothing"

# --- Sources -------------------------------------------------------------------------------
t_cli "" "" sources
assert_rc "$T_RC" 0 "sources"
assert_contains "$T_OUT" "https://asahi-alarm.org/installer-bootstrap.sh" "sources lists the Asahi bootstrap"
assert_contains "$T_OUT" "quattro" "sources lists the branch"
t_cli net-current "" sources --check
assert_rc "$T_RC" 0 "sources --check passes when upstream matches"
assert_not_contains "$T_OUT" "[FAIL]" "no failures when current"
t_cli net-drifted "" sources --check
assert_rc "$T_RC" 1 "sources --check fails on drift"
assert_contains "$T_OUT" "v0.10.0, verified v0.9.2" "installer drift"
assert_contains "$T_OUT" "no longer in installer_data.json" "OS choice drift"
assert_contains "$T_OUT" "not Omarchy 4" "Omarchy 3 drift"
assert_contains "$T_OUT" "upstream default is now 'main'" "branch drift, not followed"
assert_contains "$T_OUT" "missing: --hostname --keymap --resume" "flag drift"
assert_contains "$T_OUT" "FAQ no longer mentions 38GB" "reserve drift"

# --- Logs ------------------------------------------------------------------------------------
t_cli linux-alarm-fresh "" logs
assert_contains "$T_OUT" "omarchy-bootstrap-" "logs names the log file"
assert_contains "$T_OUT" "cmd=logs" "logs shows the run just made"

t_done test-cli
