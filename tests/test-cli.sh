#!/usr/bin/env bash
# The command surface, output degradation, doctor/status/sources/logs.
# shellcheck disable=SC2015,SC2016 # ok/fail always return 0; literal $ in single quotes
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
t_cli mac-m1pro-1tb-roomy "yes\nlaunch\n" install --dryrun
assert_rc "$T_RC" 2 "a mistyped --dry-run stops"
assert_contains "$T_OUT" "unknown flag: --dryrun" "the typo is named"
assert_empty_file "$T_DIR/record" "a mistyped --dry-run runs nothing"
T_ENV="OMB_DRY_RUN=yes" t_cli mac-m1pro-1tb-roomy "" status
assert_rc "$T_RC" 2 "OMB_DRY_RUN accepts only 0 or 1"
t_cli mac-m1pro-1tb-roomy "" status extra
assert_rc "$T_RC" 2 "stray arguments are refused"
t_cli linux-alarm-fresh "" resume omb1:user=alex omb1:host=x
assert_rc "$T_RC" 2 "resume takes one token"

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
  assert_not_contains "$st" "plan_macos_new_gb" "no write-only plan keys"
  assert_contains "$st" "cfg_host=m1pro" "plan recorded the hostname"
  state_dir=$T_DIR/state
  T_ENV="OMB_STATE_DIR=$state_dir" t_cli mac-m1pro-1tb-roomy "" status
  assert_contains "$T_OUT" "Linux 250 GB" "status shows the plan"
  assert_contains "$T_OUT" "confirm the backup" "status names the next action"
  assert_contains "$T_OUT" "resume omb1:enc=1,user=alex,host=m1pro" "status shows the token"
  T_ENV="OMB_STATE_DIR=$state_dir" t_cli mac-asahi-installed "" resume
  assert_contains "$T_OUT" "Phase 1 is done" "resume on macOS after install"
  assert_contains "$T_OUT" "https://github.com/example/omarchy-mac-bootstrap/archive/0123456789abcdef0123456789abcdef01234567.tar.gz" "public continuation pinned to the commit"
  assert_contains "$T_OUT" "./omarchy-bootstrap resume omb1:" "token printed after reboot guide"
  # Private repository, commit not pushed: branch tip with a warning, and sign out.
  fx=$(t_variant mac-asahi-installed)
  : >"$fx/cmd/git_pushed"
  rm -f "$fx/net/repo_public.reachable"
  T_ENV="OMB_STATE_DIR=$state_dir" t_cli "$fx" "" resume
  assert_contains "$T_OUT" "not on the remote yet" "an unpushed commit is called out"
  assert_contains "$T_OUT" "gh repo clone example/omarchy-mac-bootstrap /opt/omarchy-mac-bootstrap -- --branch main" "private clone printed"
  assert_contains "$T_OUT" "gh auth logout" "root's GitHub sign-in is removed afterwards"
  assert_not_contains "$T_OUT" "checkout -q" "no pin when the commit is not on the remote"
fi

if command -v plutil >/dev/null 2>&1; then
  t_cli mac-intel "" status
  assert_contains "$T_OUT" "This Mac cannot continue: This Mac is not Apple Silicon" "status names the blocker"
fi

# --- Saved answers are the defaults; a saved reservation never shrinks the survey ------
if command -v plutil >/dev/null 2>&1; then
  t_cli mac-m1pro-1tb-roomy '\n5\n300\n\ny\n40\n\n\n\n\n\n\n\n\n\n\n' plan
  st=$(cat "$T_DIR/state/state.env")
  assert_contains "$st" "cfg_linux=300" "custom size saved"
  assert_contains "$st" "cfg_shared=40" "shared reservation saved"
  state_dir=$T_DIR/state
  T_ENV="OMB_STATE_DIR=$state_dir" t_cli mac-m1pro-1tb-roomy '\n\n\n\n\n\n\n\n\n\n\n\n\n\n' plan
  assert_contains "$T_OUT" "Safe Linux maximum  655 GB" "the saved reservation does not shrink the survey"
  assert_contains "$T_OUT" "Saved plan       300 GB" "the saved size is offered"
  assert_contains "$T_OUT" "Plan a shared area? [Y/n]" "the shared question defaults to the saved answer"
  st=$(cat "$state_dir/state.env")
  assert_contains "$st" "cfg_linux=300" "Enter keeps the saved size"
  assert_contains "$st" "cfg_shared=40" "Enter keeps the saved reservation"
fi

# --- The shared-area prompt always has a way out ------------------------------------------
if command -v plutil >/dev/null 2>&1; then
  t_cli mac-m1pro-1tb-roomy '\n4\n\n\n\n\n\n\n\n\n\n\n\n' plan
  assert_contains "$T_OUT" "No room for a shared area beside 655 GB" "Maximum safe skips the shared question"
  assert_contains "$T_OUT" "Plan saved" "the plan completes"
  t_cli mac-m1pro-1tb-roomy '\n\ny\nabc\nb\n\n\n\n\n\n\n\n\n\n\n' plan
  assert_contains "$T_OUT" "A whole number of GB" "invalid shared sizes explain themselves"
  assert_contains "$(cat "$T_DIR/state/state.env")" "cfg_shared=0" "b skips the shared area"
  t_cli mac-m1pro-1tb-roomy '\n\ny\nq\n' plan
  assert_contains "$T_OUT" "Nothing on this Mac changed" "q at the shared size quits"
fi

# --- An optional choice can be cleared ----------------------------------------------------
if command -v plutil >/dev/null 2>&1; then
  t_cli mac-m1pro-1tb-roomy '\n\n\n\n\nm1pro\n\n\n\n\noctocat\n\n\n' plan
  assert_contains "$(cat "$T_DIR/state/state.env")" "cfg_gh=octocat" "GitHub user saved"
  state_dir=$T_DIR/state
  T_ENV="OMB_STATE_DIR=$state_dir" t_cli mac-m1pro-1tb-roomy '\n\n\n\n\n\n\n\n\n\n-\n\n\n' plan
  assert_not_contains "$(cat "$state_dir/state.env")" "cfg_gh=" "'-' clears the saved GitHub user"
  assert_contains "$(cat "$state_dir/state.env")" "cfg_host=m1pro" "other choices are kept"
fi

# --- Linux status and plan -------------------------------------------------------------
t_cli linux-setup-in-progress "" status
assert_contains "$T_OUT" "omarchy-mac-setup --status" "status includes upstream status"
assert_contains "$T_OUT" "next step       omarchy" "upstream status body"
t_cli linux-alarm-fresh '\nalex\nm1pro\n\n' plan
assert_contains "$(cat "$T_DIR/state/state.env")" "cfg_user=alex" "linux plan saves choices"
assert_empty_file "$T_DIR/record" "linux plan runs nothing"

# --- A resume token is recorded as used (the key must pass the secret-name filter) -------
t_cli linux-alarm-fresh '\n\n' resume 'omb1:enc=1,user=alex,host=omarchy,kmap=us'
st=$(cat "$T_DIR/state/state.env")
assert_contains "$st" "phase1_choices_loaded_at=" "token use is recorded"
assert_not_contains "$(cat "$T_DIR"/state/logs/*.log)" "refuse" "no state key was refused"
T_ENV="OMB_STATE_DIR=$T_DIR/state" t_cli linux-alarm-fresh "" status
assert_not_contains "$T_OUT" "Token loaded        not used" "status reports the token as used"

# --- Root → user hand-off through the system state file --------------------------------
fx=$(t_variant linux-omarchy-installed)
mkdir -p "$fx/root/var/lib/omarchy-mac-bootstrap"
printf 'cfg_user=alex\ncfg_host=m1pro\ncfg_enc=1\ncfg_ssh=1\ncfg_tz=Europe/Berlin\ncfg_shared=a[$(touch pwned)]\n' \
  >"$fx/root/var/lib/omarchy-mac-bootstrap/state.env"
t_cli "$fx" 'q\n' dev --dry-run
assert_contains "$T_OUT" "◉ 7  SSH" "the root run's SSH choice preselects the SSH module"
assert_contains "$T_OUT" "planned Europe/Berlin" "the root run's timezone reaches the user run"
[ ! -e pwned ] && [ ! -e "$fx/pwned" ] && ok || fail "an invalid system-state value was executed"
t_cli "$fx" "" status
assert_contains "$T_OUT" "alex@m1pro" "status shows the root run's record"

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
