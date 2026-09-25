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
# Each row: the command and its own description on one line, so a word that
# also appears in the prose ("plan", "install") cannot satisfy it.
while IFS='|' read -r cmd desc; do
  if printf '%s\n' "$T_OUT" | grep -Eq "^ +$cmd +$desc"; then ok; else fail "help row for $cmd"; fi
done <<'EOF'
plan|survey \+ storage plan \+ choices; saves them, runs nothing
install|run the current phase end to end
resume \[token\]|continue after a reboot
status|where this machine is, and what comes next
doctor|read-only health checks
dev|optional developer setup
sources \[--check\]|upstream URLs and versions
logs|log location and recent entries
--dry-run|show every step; change nothing, keep nothing
--no-color|plain output
--ascii|ASCII glyphs only
EOF
t_cli mac-m1pro-1tb-roomy "" --version
assert_eq "$T_OUT" "omarchy-bootstrap 0.2.0" "--version"
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
t_cli mac-m1pro-1tb-roomy "" --help
assert_contains "$T_OUT" "◒  omarchy·mac bootstrap" "Unicode terminals keep the glyphs"
if command -v plutil >/dev/null 2>&1; then
  t_cli mac-m1pro-1tb-roomy '\n\n\n\n\n\n\n\n\n\n\n\n\nyes\n\nlaunch\n' --ascii --dry-run
  assert_eq "$(non_ascii "$T_OUT")" 0 "the whole macOS flow is pure ASCII with --ascii"
fi
T_ENV="TERM=linux" t_cli linux-alarm-fresh '\n\nstart\n' resume 'omb1:enc=1,user=alex,host=omarchy,kmap=us' --dry-run
assert_eq "$(non_ascii "$T_OUT")" 0 "the Omarchy handoff on the Linux console is pure ASCII"
T_ENV="TERM=linux" t_cli linux-omarchy-installed '1 2 3 4 5 6 7 8 9\nq\n' dev --dry-run
assert_eq "$(non_ascii "$T_OUT")" 0 "the developer menu on the Linux console is pure ASCII"
for f in linux-omarchy-installed linux-setup-in-progress; do
  T_ENV="TERM=linux" t_cli "$f" "" doctor
  assert_eq "$(non_ascii "$T_OUT")" 0 "doctor on the Linux console is pure ASCII ($f)"
  T_ENV="TERM=linux" t_cli "$f" "" status
  assert_eq "$(non_ascii "$T_OUT")" 0 "status on the Linux console is pure ASCII ($f)"
done
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
  assert_contains "$T_OUT" "[INFO] Asahi install" "an existing install is reported with its state"
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
  assert_contains "$T_OUT" "resume omb2:enc=1,user=alex,host=m1pro" "status shows the token"
  T_ENV="OMB_STATE_DIR=$state_dir" t_cli mac-asahi-installed "" resume
  assert_contains "$(t_flat "$T_OUT")" "partitions are all in place" "resume on macOS after install reports what the disk shows"
  assert_contains "$T_OUT" "https://github.com/example/omarchy-mac-bootstrap/archive/0123456789abcdef0123456789abcdef01234567.tar.gz" "public continuation pinned to the commit"
  assert_contains "$T_OUT" "./omarchy-bootstrap resume omb2:" "token printed after reboot guide"
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
  t_cli mac-m1pro-1tb-tight "" status
  assert_contains "$T_OUT" "This Mac cannot continue: Not enough space for Linux" "status names a space shortfall"
  t_cli mac-m1pro-1tb-tight '\n\n' --dry-run
  assert_rc "$T_RC" 1 "a Mac short of space stops"
  assert_contains "$T_OUT" "free about 39 GB more in macOS" "the shortfall is explained in the guided flow"
  assert_not_contains "$T_OUT" "How much storage" "a Mac short of space never reaches the planner"
  t_cli mac-geo-two-gaps "" status
  assert_contains "$T_OUT" "Safe Linux max      74 GB" "two separate gaps are never added together"
fi

# --- Shared is chosen first, and changes what Linux can have ---------------------------
# Answers, in prompt order: survey Enter; Shared menu; Linux menu; then nine
# choices (encryption, user, host, keymap, timezone, locale, SSH, GitHub,
# developer setup) and the review.
choices='\n\n\n\n\n\n\n\n\n\n'
if command -v plutil >/dev/null 2>&1; then
  t_cli mac-m1pro-1tb-roomy "\n6\n40\n5\n300\n\n$choices" plan
  st=$(cat "$T_DIR/state/state.env")
  assert_contains "$st" "cfg_linux=300" "custom Linux size saved"
  assert_contains "$st" "cfg_shared=40" "custom Shared size saved"
  assert_contains "$T_OUT" "54 GB–614 GB beside 40 GB Shared" "the Linux range is computed beside the Shared size"
  assert_contains "$T_OUT" "Shared / exFAT      40 GB" "the layout shows the Shared reservation"
  state_dir=$T_DIR/state
  T_ENV="OMB_STATE_DIR=$state_dir" t_cli mac-m1pro-1tb-roomy "\n\n\n$choices" plan
  assert_contains "$T_OUT" "Safe Linux maximum  654 GB" "the saved reservation does not shrink the survey"
  printf "%s\n" "$T_OUT" | grep -Eq "^ +(. )?[0-9]  40 GB +saved$" && ok || fail "the saved Shared size is offered and marked"
  assert_contains "$T_OUT" "Saved plan       300 GB" "the saved Linux size is offered"
  st=$(cat "$state_dir/state.env")
  assert_contains "$st" "cfg_linux=300" "Enter keeps the saved Linux size"
  assert_contains "$st" "cfg_shared=40" "Enter keeps the saved Shared size"

  # 250 GB of Shared leaves Linux 250 GB less, and the maximum is still valid.
  t_cli mac-m1pro-1tb-roomy "\n5\n3\n$choices" plan
  assert_contains "$T_OUT" "54 GB–404 GB beside 250 GB Shared" "250 GB Shared: Linux can have up to 404 GB"
  st=$(cat "$T_DIR/state/state.env")
  assert_contains "$st" "cfg_shared=250" "250 GB Shared saved"
  assert_contains "$st" "cfg_linux=404" "Maximum safe beside Shared saved"
fi

# --- "b" goes back one step, and every prompt has a way out -------------------------------
if command -v plutil >/dev/null 2>&1; then
  t_cli mac-m1pro-1tb-roomy "\n\n5\nb\n1\n$choices" plan
  assert_eq "$(printf '%s' "$T_OUT" | grep -c 'How much storage should Linux receive?')" 2 "the size menu is shown again after b"
  assert_contains "$(cat "$T_DIR/state/state.env")" "cfg_linux=100" "a preset can be chosen after backing out of custom"
  t_cli mac-m1pro-1tb-roomy "\n\nb\n2\n\n$choices" plan
  assert_eq "$(printf '%s' "$T_OUT" | grep -c 'Shared macOS')" 2 "b at the Linux size returns to the Shared question"
  assert_contains "$(cat "$T_DIR/state/state.env")" "cfg_shared=50" "the Shared answer can be changed after going back"
  t_cli mac-m1pro-1tb-roomy "\n6\nabc\n08\n700\nb\n\n\n$choices" plan
  assert_contains "$T_OUT" "is not a size" "invalid Shared sizes explain themselves"
  assert_contains "$T_OUT" "leading zero" "a leading zero is refused, never read as octal"
  assert_contains "$T_OUT" "Between 1 and" "a Shared size that leaves Linux too little is refused"
  assert_contains "$(cat "$T_DIR/state/state.env")" "cfg_shared=0" "b then None: no Shared"
  t_cli mac-m1pro-1tb-roomy '\nq\n' plan
  assert_contains "$T_OUT" "Nothing on this Mac changed" "q at the Shared question quits"
  t_cli mac-m1pro-1tb-roomy "\n\n5\n1844674.5TB\n010\nq\n" plan
  assert_contains "$T_OUT" "is too large" "an overflowing Linux size is refused"
  assert_contains "$T_OUT" "leading zero" "010 is refused as a Linux size"
fi

# --- Whole macOS flows: Shared through the launch, quit, back, save-and-stop -------------
if command -v plutil >/dev/null 2>&1; then
  # 50 GB of Shared through to the launch: macOS shrinks by Linux + Shared,
  # Linux gets an exact size (never max), and the card says so.
  read -r ans_r ans_os <<<"$(t_plan_answers mac-m1pro-1tb-roomy 250 50)"
  t_cli mac-m1pro-1tb-roomy "\n2\n\n${choices}yes\n\nlaunch\n"
  assert_contains "$(cat "$T_DIR/record")" "pbcopy <<< $ans_r" "Shared: the clipboard gets the exact macOS size ($ans_r)"
  assert_contains "$T_OUT" "New OS size  (Linux gets)      $ans_os" "Shared: the Linux size is exact ($ans_os), not max"
  assert_contains "$T_OUT" "Never type max here" "Shared: the card warns against max"
  case "$ans_r$ans_os" in *MiB*MiB) ok ;; *) fail "Shared: both answers are exact MiB ($ans_r $ans_os)" ;; esac

  t_cli mac-m1pro-1tb-roomy 'q\n'
  assert_rc "$T_RC" 0 "q at the first prompt exits cleanly"
  assert_contains "$T_OUT" "Nothing on this Mac changed" "q at the first prompt says nothing changed"

  t_cli mac-m1pro-1tb-roomy '\nb\nq\n'
  assert_eq "$(printf '%s' "$T_OUT" | grep -c '▍Machine')" 2 "b at the Shared question returns to the survey"

  t_cli mac-m1pro-1tb-roomy "\n\n\n\n\n\n\n\n\n\n\n\n4\n"
  assert_contains "$T_OUT" "Plan saved" "Save and stop saves"
  assert_contains "$(cat "$T_DIR/state/state.env")" "cfg_linux=250" "Save and stop records the plan"
  assert_not_contains "$T_OUT" "Type yes" "Save and stop never reaches the backup gate"
  assert_empty_file "$T_DIR/record" "Save and stop runs nothing"

  fx=$(t_variant mac-m1pro-1tb-roomy)
  printf '13.4\n' >"$fx/cmd/sw_vers"
  t_cli "$fx" '\n' --dry-run
  assert_rc "$T_RC" 1 "macOS older than 13.5 stops"
  assert_contains "$T_OUT" "older than 13.5" "the macOS version blocker is named"
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
assert_contains "$T_OUT" "[PASS] EFI partition" "the storage contract is checked when current"
t_cli net-efi-drift "" sources --check
assert_rc "$T_RC" 1 "sources --check fails when the storage contract drifts"
assert_contains "$T_OUT" "[FAIL] EFI partition" "EFI drift is a failure, not a warning"
assert_contains "$T_OUT" "[PASS] Asahi installer" "the version still matches in that case"
t_cli net-drifted "" sources --check
assert_rc "$T_RC" 1 "sources --check fails on drift"
assert_contains "$T_OUT" "[FAIL] Asahi installer" "installer version drift is a failure: it blocks the handoff"
assert_contains "$T_OUT" "v0.10.0, verified v0.9.2" "installer drift"
assert_contains "$T_OUT" "no longer in installer_data.json" "OS choice drift"
assert_contains "$T_OUT" "not Omarchy 4" "Omarchy 3 drift"
assert_contains "$T_OUT" "upstream default is now 'main'" "branch drift, not followed"
assert_contains "$T_OUT" "missing: --hostname --keymap --resume" "flag drift"
assert_contains "$T_OUT" "FAQ no longer mentions 38GB" "reserve drift"

# --- Logs ------------------------------------------------------------------------------------
# A recording run leaves a log; logs itself is read-only and adds nothing.
t_cli linux-alarm-fresh '\nalex\nm1pro\n\n' plan
state_dir=$T_DIR/state
T_ENV="OMB_STATE_DIR=$state_dir" t_cli linux-alarm-fresh "" logs
assert_contains "$T_OUT" "omarchy-bootstrap-" "logs names the log file"
assert_contains "$T_OUT" "cmd=plan" "logs shows the earlier recording run"
assert_not_contains "$(cat "$state_dir"/logs/*.log)" "cmd=logs" "logs does not log itself"

t_done test-cli
