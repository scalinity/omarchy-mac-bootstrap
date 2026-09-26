#!/usr/bin/env bash
# Developer setup outcomes: each module reports success, failed, skipped,
# cancelled or already-satisfied from what the machine shows afterwards; only
# success is timestamped, and any failure makes the run exit non-zero.
# Failures are forced with OMB_TEST_RC (every recorded command "fails");
# OMB_TEST_AFTER supplies the machine as it looks once commands have "run".
# shellcheck disable=SC2015,SC2016 # ok/fail always return 0; literal $ in single quotes
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-dev"

# Menu: 1 core, 2 languages, 3 containers, 4 editor, 5 git, 6 github, 7 ssh, 8 ai, 9 time.
row() { printf '%s\n' "$T_OUT" | grep -E "^ +$1 " | tail -1; }
expect_failed() { # LABEL MODULE-LABEL DETAIL
  assert_rc "$T_RC" 1 "$1: the run exits non-zero"
  assert_contains "$(row "$2")" "failed" "$1: the summary says failed"
  assert_contains "$(row "$2")" "$3" "$1: and why"
  assert_contains "$T_OUT" "requested operation" "$1: attention is called for"
  assert_not_contains "$(cat "$T_DIR/state/state.env" 2>/dev/null)" "dev_last_run_at" "$1: the run is not stamped done"
}

# --- Forced failures, one module at a time ---------------------------------------------------
T_ENV="OMB_TEST_RC=1" t_cli linux-omarchy-installed '1\n' dev
expect_failed "package install" "Core tools" "package install failed"
assert_not_contains "$(cat "$T_DIR/state/state.env")" "dev_core_at" "a failed module is not timestamped"
assert_contains "$(cat "$T_DIR/state/state.env")" "dev_failed=core" "the failure is recorded"

T_ENV="OMB_TEST_RC=1" t_cli linux-omarchy-installed '2\n1 3\n' dev
expect_failed "language installation" "Languages" "rust: the installer failed"
assert_contains "$(row Languages)" "node: the installer failed" "the second language's failure is kept too"

T_ENV="OMB_TEST_RC=1" t_cli linux-omarchy-installed '3\n1\n' dev
expect_failed "Omarchy helper" "Containers" "sudoless-docker helper failed"

T_ENV="OMB_TEST_RC=1" t_cli linux-omarchy-installed '6\n' dev
expect_failed "gh auth" "GitHub CLI" "authentication failed"

T_ENV="OMB_TEST_RC=1" t_cli linux-omarchy-installed '7\n\ny\n' dev
expect_failed "SSH helper" "SSH" "the SSH helper failed"
assert_contains "$(row SSH)" "ssh-keygen failed" "the key generation failure is kept too"

T_ENV="OMB_TEST_RC=1" t_cli linux-omarchy-installed '8\n1\n\ny\n' dev
expect_failed "Claude Code install" "AI coding CLIs" "Claude Code install failed"

fx=$(t_variant linux-omarchy-installed)
printf 'npm\n' >>"$fx/commands"
T_ENV="OMB_TEST_RC=1" t_cli "$fx" '8\n2\n' dev
expect_failed "Codex install" "AI coding CLIs" "Codex install failed"
t_cli linux-omarchy-installed '8\n2\n' dev
expect_failed "Codex without npm" "AI coding CLIs" "npm not found"

pre=$(t_tmp)
printf 'cfg_tz=Europe/Berlin\ncfg_loc=en_US.UTF-8\n' >"$pre/state.env"
chmod 600 "$pre/state.env"
T_ENV="OMB_STATE_DIR=$pre OMB_TEST_RC=1" t_cli linux-omarchy-installed '9\ny\n' dev
expect_failed "timezone" "Time & locale" "timedatectl failed"

# --- A failure stands when the rest of the module is stopped -----------------------------------
# ssh-keygen fails, then q at "Set up SSH access?": the module stopped, and it
# failed; the run exits non-zero and is not stamped done.
T_ENV="OMB_TEST_RC=1" t_cli linux-omarchy-installed '7\n\nq\n' dev
expect_failed "ssh-keygen, then stopped" "SSH" "ssh-keygen failed"
assert_contains "$(row SSH)" "the rest was stopped at your request" "the stop is reported beside the failure"
assert_not_contains "$(row SSH)" "cancelled" "the failure is not reported as a cancellation"
# gh ssh-key add fails, then q at the same prompt.
home=$(t_tmp)
mkdir -p "$home/.ssh"
: >"$home/.ssh/id_ed25519"
printf 'ssh-ed25519 AAAAC3Nza fixture\n' >"$home/.ssh/id_ed25519.pub"
fx=$(t_variant linux-omarchy-installed)
printf 'github.com: logged in as alex\n' >"$fx/cmd/gh_status"
rm -f "$fx/cmd/gh_status.rc"
T_ENV="HOME=$home OMB_TEST_RC=1" t_cli "$fx" '7\ny\nq\n' dev
expect_failed "gh ssh-key add, then stopped" "SSH" "gh ssh-key add failed"
assert_contains "$(row SSH)" "the rest was stopped at your request" "and the stop is reported"
# The rule behind it, for every module with parts: in the languages and AI
# modules the only place to stop comes before any part runs, so the same
# rule is checked on the outcome directly.
t_load
for part in "rust: the installer failed" "Claude Code install failed"; do
  dev_begin
  dev_part_fail "$part"
  dev_cancel
  dev_outcome_final
  assert_eq "$DEV_OUTCOME" failed "a failed part ($part), then stopped: failed"
  assert_contains "$DEV_DETAIL" "$part; the rest was stopped at your request" "and both are reported"
done
dev_begin
dev_cancel
dev_outcome_final
assert_eq "$DEV_OUTCOME|$DEV_DETAIL" "cancelled|" "stopped with nothing failed: cancelled"
dev_begin
dev_part_fail "one part"
dev_ok "all done"
dev_outcome_final
assert_eq "$DEV_OUTCOME" failed "a failed part never ends as success, whatever the module reported"

# --- A helper that exits 0 without doing the job is not success -------------------------------
T_ENV="OMB_TEST_AFTER=$FIX/linux-omarchy-installed" t_cli linux-omarchy-installed '1\n' dev
expect_failed "packages skipped silently" "Core tools" "still missing: github-cli wget tree rsync"
T_ENV="OMB_TEST_AFTER=$FIX/linux-omarchy-installed" t_cli linux-omarchy-installed '2\n1\n' dev
expect_failed "a language that did not install" "Languages" "rust: finished, but cargo is not installed"
T_ENV="OMB_TEST_AFTER=$FIX/linux-omarchy-installed" t_cli linux-omarchy-installed '6\n' dev
expect_failed "gh not signed in afterwards" "GitHub CLI" "gh is not signed in"

# --- Success is checked, then timestamped ----------------------------------------------------
home=$(t_tmp)
mkdir -p "$home/.ssh"
printf 'ssh-ed25519 AAAAC3Nza fixture\n' >"$home/.ssh/authorized_keys"
: >"$home/.ssh/id_ed25519"
T_ENV="HOME=$home OMB_TEST_AFTER=$FIX/linux-dev-complete" t_cli linux-omarchy-installed '1 2 7\n1\ny\n' dev
assert_rc "$T_RC" 0 "a run where every module succeeded exits 0"
for m in "Core tools" "Languages" "SSH"; do
  assert_contains "$(row "$m")" "complete" "success reported: $m"
done
st=$(cat "$T_DIR/state/state.env")
for m in core languages ssh; do
  assert_contains "$st" "dev_${m}_at=" "success timestamped: $m"
done
assert_contains "$st" "dev_last_run_at=" "the whole run is stamped done"
assert_contains "$T_OUT" "Developer setup finished" "and says so"
# gh signs in, and the check afterwards sees it.
T_ENV="OMB_TEST_AFTER=$FIX/linux-dev-complete" t_cli linux-omarchy-installed "6\n\n" dev
assert_contains "$(row "GitHub CLI")" "complete" "gh auth login checked, then complete"
assert_contains "$(cat "$T_DIR/record")" "gh auth setup-git" "git is set up to use gh"

# --- An active sshd no longer counts as SSH access ---------------------------------------------
fx=$(t_variant linux-omarchy-installed)
printf 'active\n' >"$fx/cmd/sshd_active"
rm -f "$fx/cmd/sshd_active.rc"
T_ENV="HOME=$home" t_cli "$fx" '7\ny\n' dev
assert_contains "$(cat "$T_DIR/record")" "omarchy-setup-security-sshd" "the SSH helper runs even with sshd already active"
assert_contains "$T_OUT" "Port 22             not listening" "the listener is reported separately"
t_cli "$fx" "" doctor
assert_contains "$T_OUT" "[PASS] SSH service" "doctor: the service"
assert_contains "$T_OUT" "[WARN] SSH port" "doctor: running but not listening is a warning"
assert_contains "$T_OUT" "[INFO] SSH firewall" "doctor: the firewall is not claimed"

# --- Skipped, cancelled, already satisfied ----------------------------------------------------
t_cli linux-omarchy-installed '3\n3\n' dev
assert_rc "$T_RC" 0 "a skipped module is not a failure"
assert_contains "$(row Containers)" "skipped" "left as is: skipped"
t_cli linux-omarchy-installed '2\nq\n' dev
assert_rc "$T_RC" 0 "a cancelled module is not a failure"
assert_contains "$(row Languages)" "cancelled" "q in a module: cancelled"
assert_not_contains "$(cat "$T_DIR/state/state.env")" "dev_languages_at" "a cancelled module is not timestamped"
t_cli linux-dev-complete '4\n' dev
assert_contains "$(row Editor)" "already set up" "VS Code present: already satisfied"
assert_empty_file "$T_DIR/record" "already satisfied: nothing runs"

# --- A dry run previews; it never claims completion ---------------------------------------------
t_cli linux-omarchy-installed '1 2\n1\n' dev --dry-run
assert_contains "$(row "Core tools")" "previewed" "dry run: previewed, not complete"
assert_not_contains "$T_OUT" " complete " "dry run: nothing reported complete"
assert_eq "$(ls -A "$T_DIR/state" 2>/dev/null)" "" "dry run: nothing recorded"

t_done test-dev
