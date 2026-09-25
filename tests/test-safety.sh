#!/usr/bin/env bash
# Safety boundaries: what the code can invoke, what dry-run and the typed gates
# allow, and that nothing destructive runs during tests.
# shellcheck disable=SC2015,SC2016,SC2086 # ok/fail always return 0; literal $ in single quotes; file lists split on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-safety"

# Every module, so a new one is scanned without anyone remembering to add it.
CODE="$REPO/omarchy-bootstrap $(printf '%s ' "$REPO"/lib/*.sh)"

# Code lines: no comments, no heredoc bodies. raw_lines keeps quoted text,
# because a command substitution inside quotes still executes; code_lines
# blanks quoted text, for scans where quoted text is only data.
_lines() {
  # shellcheck disable=SC2086 # CODE is a file list
  awk -v blank="$1" '
    FNR == 1 { heredoc = "" }
    heredoc != "" { if ($0 ~ "^[[:space:]]*" heredoc "$") heredoc = ""; next }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      if (match(line, /<<-?[[:space:]]*.?EOF.?/)) heredoc = "EOF"
      if (blank == 1) {
        gsub(/"[^"]*"/, "\"\"", line)
        gsub(/\047[^\047]*\047/, "\047\047", line)
      }
      print FILENAME ":" FNR ": " line
    }' $CODE
}
raw_lines() { _lines 0; }
code_lines() { _lines 1; }

FORBIDDEN_RE='(dd|gpt|fdisk|sfdisk|gdisk|sgdisk|parted|bless|nvram|csrutil|shutdown|reboot|halt|poweroff|wipefs|blkdiscard|btrfs|hdiutil|asr|mkfs(\.[a-z0-9]+)?|cryptsetup|expect)'
# Where a word is executed: line start, after ; & | ( { ! or $(, or after a
# keyword or wrapper that runs its argument.
CMDPOS='(^[[:space:]]*|[;&|({][[:space:]]*|![[:space:]]+|\$\([[:space:]]*|(then|do|else|if|while|until|run|sudo|exec|command|env|time|xargs|nohup)[[:space:]]+|ui_spin[[:space:]]+"[^"]*"[[:space:]]+)'

# --- Static: forbidden commands -----------------------------------------------
hits=$(raw_lines | sed 's/^[^:]*:[0-9]*: //' | grep -E "${CMDPOS}${FORBIDDEN_RE}([[:space:]]|\$)")
assert_eq "$hits" "" "no forbidden command at any command position"
# PATH shims only intercept PATH lookups, so no shimmed command may be named by
# an absolute path (a "#!" shebang pattern in a string is not a call).
shimmed=$(printf '%s\n' $FORBIDDEN_CMDS | sed 's/\./\\./g' | paste -sd'|' -)
hits=$({
  code_lines | grep -E "(^|[^A-Za-z0-9_.!-])/(usr/)?s?bin/($shimmed)([^A-Za-z0-9_.-]|\$)"
  raw_lines | sed 's/^[^:]*:[0-9]*: //' | grep -E "${CMDPOS}/(usr/)?s?bin/($shimmed)([^A-Za-z0-9_.-]|\$)"
})
assert_eq "$hits" "" "no absolute-path call to a shimmed command (PATH shims would miss it)"

# Any diskutil verb other than info / list, the literal limits query, and the
# one guarded Shared creation (checked on its own below).
ADDPART='run diskutil addPartition "$SHARED_PRED_ID" "$SHARED_FS_MAC" "$SHARED_LABEL" "$SH_SIZE"'
hits=$(grep -n 'diskutil' $CODE | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' |
  grep -E 'diskutil[[:space:]]+(erase|partition|resize|split|merge|add|zero|random|secure|reformat|unmount|mount|apfs[[:space:]]+(delete|add|create|erase|convert|unlock|encrypt|decrypt|change|resizeContainer))' |
  grep -v 'resizeContainer "\$1" limits -plist' | grep -vF "$ADDPART" | grep -v 'ui_cmd "diskutil addPartition')
assert_eq "$hits" "" "only read-only diskutil verbs, plus the one Shared creation"
assert_eq "$(grep 'resizeContainer' $CODE | grep -v '^[^:]*:[[:space:]]*#' | grep -c 'limits -plist')" \
  "$(grep 'resizeContainer' $CODE | grep -vc '^[^:]*:[[:space:]]*#')" "every resizeContainer use is the limits query"
n=$(grep -v '^[[:space:]]*#' "$REPO/lib/macos.sh" | grep -c 'resizeContainer "\$1" limits -plist')
assert_eq "$n" 1 "the limits query is present in code, not only in a comment"

# --- Static: the one partition this tool creates ------------------------------------
# Exactly one addPartition, in lib/shared.sh, with a fixed filesystem and
# name, after the backup and "create" gates, the re-read of the disk, and the
# record that must exist before it — in that order, in one function.
assert_eq "$(grep -hF "$ADDPART" $CODE | grep -c .)" 1 "exactly one addPartition in the code"
assert_eq "$(grep -lF "$ADDPART" $CODE)" "$REPO/lib/shared.sh" "and it lives in lib/shared.sh"
assert_eq "$(grep -c '^SHARED_FS_MAC="ExFAT"$' "$REPO/lib/shared.sh") $(grep -c '^SHARED_LABEL="Shared"$' "$REPO/lib/shared.sh")" "1 1" "its filesystem and name are constants"
body=$(awk '/^shared_create_flow\(\) \{/ {f = 1} f {print} f && /^}/ {exit}' "$REPO/lib/shared.sh")
seq=$(printf '%s\n' "$body" | grep -oE 'ui_confirm_word yes|ui_confirm_word create|mac_detect_geometry|state_must_set shared_create_started_at|run diskutil addPartition' | tr '\n' '|')
assert_eq "$seq" "ui_confirm_word yes|ui_confirm_word create|mac_detect_geometry|state_must_set shared_create_started_at|run diskutil addPartition|" \
  "addPartition runs only after both typed gates, a fresh read of the disk, and the record"
# Nothing reaches the device argument from a file: it is the fresh read's id.
assert_eq "$(printf '%s\n' "$body" | grep -c 'SHARED_PRED_ID=')" 0 "the creation never sets the device itself"
assert_eq "$(grep -c 'SHARED_PRED_ID=\$GP_ID' "$REPO/lib/shared.sh")" 1 "the device is the partition found on the disk right before the region"

# --- Static: every probe is read-only ----------------------------------------------
probes=$(grep -h 'sys_cmd ' $CODE | grep -v '^[[:space:]]*#' | grep -o 'sys_cmd [^|)]*' | sed 's/^sys_cmd [^ ]* //' | sort -u)
bad=$(printf '%s\n' "$probes" | grep -vE '^("\$@"|uname -[smr]|id -(u|un|Gn|g)|sysctl -n |sw_vers -productVersion|system_profiler -xml SPHardwareDataType|diskutil (info|list) -plist |diskutil apfs list -plist|diskutil apfs resizeContainer "\$1" limits -plist|fdesetup isactive|readlink /etc/localtime|defaults read |tmutil (destinationinfo|latestbackup)|git -C "\$OMB_HOME" (remote get-url origin|rev-parse --abbrev-ref HEAD|rev-parse HEAD|branch -r --contains HEAD)|git config --global user\.(name|email)|findmnt -no |lsblk -no TYPE |lsblk -nsplo NAME,TYPE |lsblk -bPno NAME,PKNAME,TYPE,START,SIZE,PARTUUID,PARTTYPE,FSTYPE,LABEL,UUID|cryptsetup luksDump |pmset -g batt|ip route|systemctl is-active |getconf PAGESIZE|timedatectl show |snapper --no-headers list-configs|pacman -(Qq|Dk)|df -Pk /|df -Pk "\$(SHARED_MOUNT|SHARED_MNT)"|localectl list-locales|"\$OMS_SELF" --status|gh auth status)')
assert_eq "$bad" "" "every sys_cmd probe is on the read-only list"

# --- Static: every mutating command goes through run, and is expected -------------
runs=$(code_lines | grep -oE '(^|[[:space:];&|(])run [^;|&]*' | sed -E 's/^[[:space:];&|(]*run //' | awk '{print $1}' | sort -u | tr '\n' ' ')
for cmd in $runs; do
  case "$cmd" in
    sh | bash | nmtui | sudo | git | gh | ssh-keygen | npm | cp | sync | rm | diskutil | \
      omarchy-pkg-add | omarchy-install-dev-env | omarchy-install-editor-vscode | \
      omarchy-setup-security-sshd | omarchy-setup-security-sudoless-docker) ok ;;
    '""') ;; # a quoted first argument: checked exactly below
    *) fail "unexpected command through run: $cmd" ;;
  esac
done
quoted=$(raw_lines | sed 's/^[^:]*:[0-9]*: //' | grep -oE '(^|[[:space:];&|(])run "[^"]*"[^;|&]*' | sed -E 's/^[[:space:];&|(]*//; s/[[:space:]]+$//' | sort -u)
assert_eq "$quoted" 'run "$OMS_SELF" --resume' "the only indirect command through run is omarchy-mac-setup --resume"
sudos=$(grep -ho 'run sudo [a-z]* [^ ]*' $CODE | sort -u | tr '\n' ';')
assert_eq "$sudos" "run sudo cp -p;run sudo install -d;run sudo install -m;run sudo localectl set-locale;run sudo mv -f;run sudo pacman -S;run sudo systemctl daemon-reload;run sudo systemctl start;run sudo timedatectl set-timezone;" "sudo is used only for packages, timezone, locale, and the Shared mount"
assert_eq "$(grep -hoE 'run sudo (cp|mv|install) [^&]*' $CODE | sed 's/ *$//' | sort -u | tr '\n' ';')" \
  'run sudo cp -p /etc/fstab /etc/fstab.omarchy-bootstrap.bak;run sudo install -d -m 0755 -o root -g root "$SHARED_MNT";run sudo install -m 0644 -o root -g root "$tmp" /etc/fstab.omarchy-bootstrap.new;run sudo mv -f /etc/fstab.omarchy-bootstrap.new /etc/fstab;' \
  "privileged file changes are exactly the Shared mount point and the managed fstab"
assert_eq "$(grep -hoE 'run sudo systemctl [^&]*' $CODE | sed 's/ *$//' | sort -u | tr '\n' ';')" \
  'run sudo systemctl daemon-reload;run sudo systemctl start "$SHARED_UNIT";' "systemctl only reloads and starts the Shared automount"
hits=$(code_lines | sed 's/^[^:]*:[0-9]*: //' | grep -E '(^[[:space:]]*|[;&|({!][[:space:]]*|\$\([[:space:]]*|(then|do|else|if|exec|command|env|xargs)[[:space:]]+)sudo[[:space:]]')
assert_eq "$hits" "" "sudo only ever runs through run"

# --- Dynamic: dry-run executes nothing ------------------------------------------------
mac_install_input='\n\n\n\n\n\n\n\n\n\n\n\n\nyes\n\nlaunch\n'
t_cli mac-m1pro-1tb-roomy "$mac_install_input" --dry-run
assert_rc "$T_RC" 0 "mac dry-run completes"
assert_contains "$T_OUT" "would run  sh " "mac dry-run shows the installer command"
assert_contains "$T_OUT" "the installer was not launched" "mac dry-run says so"
assert_empty_file "$T_DIR/shims.log" "mac dry-run invoked a forbidden command"
assert_empty_file "$T_DIR/record" "mac dry-run recorded an execution"
assert_eq "$(ls "$T_DIR/state/state.env" 2>/dev/null)" "" "mac dry-run wrote no state"

t_cli linux-alarm-fresh '\n\nstart\n' resume 'omb1:enc=1,user=alex,host=omarchy,kmap=us' --dry-run
assert_rc "$T_RC" 0 "linux dry-run completes"
assert_contains "$T_OUT" "would run  bash " "linux dry-run shows the setup command"
assert_contains "$T_OUT" "--encrypt --user alex --hostname omarchy --keymap us" "linux dry-run shows the flags"
assert_empty_file "$T_DIR/shims.log" "linux dry-run invoked a forbidden command"
assert_empty_file "$T_DIR/record" "linux dry-run recorded an execution"

t_cli linux-alarm-offline '\n\n' --dry-run
assert_contains "$T_OUT" "would run  nmtui" "offline dry-run offers nmtui without running it"
assert_empty_file "$T_DIR/shims.log" "offline dry-run invoked a forbidden command"

t_cli linux-setup-in-progress 'resume\n' --dry-run
assert_contains "$T_OUT" "would run  /usr/local/bin/omarchy-mac-setup --resume" "in-progress dry-run shows upstream resume"
assert_empty_file "$T_DIR/shims.log" "in-progress dry-run invoked a forbidden command"

# Answers, in prompt order: modules 1-9; languages 1-4; containers 2 (Podman);
# VS Code y; git name and email; gh setup-git Enter; key generation Enter;
# enable SSH y; AI CLIs 1 2; inspect Enter; run the Claude installer y.
t_cli linux-omarchy-installed '1 2 3 4 5 6 7 8 9\n1 2 3 4\n2\ny\nAlex\nalex@example.com\n\n\ny\n1 2\n\ny\n' dev --dry-run
for expected in \
  "omarchy-pkg-add github-cli wget tree rsync" \
  "omarchy-install-dev-env rust" "omarchy-install-dev-env python" \
  "omarchy-install-dev-env node" "omarchy-install-dev-env go" \
  "omarchy-pkg-add podman podman-compose" \
  "omarchy-install-editor-vscode" \
  "git config --global user.name Alex" \
  "gh auth login" "gh auth setup-git" \
  "ssh-keygen -t ed25519" \
  "omarchy-setup-security-sshd" \
  "bash $T_DIR/tmp/omarchy-bootstrap."; do
  assert_contains "$T_OUT" "would run  $expected" "dev module ran: $expected"
done
assert_eq "$(ls -A "$T_DIR/tmp")" "" "a dry-run download is removed when the run ends"
assert_eq "$(ls "$T_DIR/state" 2>/dev/null)" "" "dev dry-run keeps no state, log or download"
assert_contains "$T_OUT" "npm not found" "Codex explains that it needs node first"
assert_contains "$T_OUT" "Developer setup finished" "every module ran to the end"
assert_empty_file "$T_DIR/shims.log" "dev dry-run invoked a forbidden command"
assert_empty_file "$T_DIR/record" "dev dry-run recorded an execution"

# --- Dynamic: the exact argv that would execute, recorded not run -----------------------
t_cli mac-m1pro-1tb-roomy "$mac_install_input"
rec=$(cat "$T_DIR/record")
read -r ans_r ans_os <<<"$(t_plan_answers mac-m1pro-1tb-roomy 250 0)"
assert_contains "$rec" "pbcopy <<< $ans_r" "clipboard gets the exact macOS size ($ans_r)"
assert_contains "$T_OUT" "New OS size  (Linux gets)      max" "no Shared: Linux takes the freed region"
assert_contains "$rec" "sh $T_DIR/state/downloads/asahi-alarm-bootstrap.sh-" "installer launched from the downloaded file"
assert_eq "$(printf '%s\n' "$rec" | grep -c .)" 2 "exactly two recorded actions"
assert_contains "$(cat "$T_DIR/state/state.env")" "asahi_launched_at=" "launch recorded in state"
assert_contains "$(cat "$T_DIR/state/state.env")" "asahi_bootstrap_sha256=" "checksum recorded in state"
assert_empty_file "$T_DIR/shims.log" "record mode invoked a forbidden command"

t_cli linux-alarm-fresh '\n\nstart\n' resume 'omb1:enc=0,user=alex,host=omarchy,kmap=de'
rec=$(cat "$T_DIR/record")
assert_contains "$rec" "bash $T_DIR/state/downloads/omarchy-mac-setup-" "setup launched from the downloaded file"
assert_contains "$rec" "--no-encrypt --user alex --hostname omarchy --keymap de" "setup flags from the token"
assert_empty_file "$T_DIR/shims.log" "linux record mode invoked a forbidden command"

# --- Gates: Enter alone, or the wrong word, never launches --------------------------------
t_cli mac-m1pro-1tb-roomy '\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n'
rec=$(cat "$T_DIR/record")
assert_eq "$rec" "" "Enter through every prompt launches nothing"
assert_contains "$T_OUT" "Stopped before anything changed" "backup gate holds on Enter"
assert_not_contains "$(cat "$T_DIR/state/state.env" 2>/dev/null)" "asahi_launched_at" "no launch recorded"

t_cli mac-m1pro-1tb-roomy '\n\n\n\n\n\n\n\n\n\n\n\n\nyes\n\nyes\ny\nLAUNCH\nn\n'
rec=$(cat "$T_DIR/record")
assert_not_contains "$rec" "sh " "the wrong word at the launch gate launches nothing"
assert_contains "$T_OUT" 'only the exact word "launch" continues' "launch gate explains itself"

t_cli linux-alarm-fresh '\n\n\n' resume 'omb1:enc=1,user=alex,host=omarchy,kmap=us'
rec=$(cat "$T_DIR/record")
assert_eq "$rec" "" "Enter at the start gate starts nothing"

t_cli mac-m1pro-1tb-roomy '\n\n\n\n\n\n\n\n\n\n\n\n\nyes\nq\nlaunch\n'
assert_contains "$T_OUT" "Not launched. Nothing changed." "q at the inspection prompt quits"
assert_empty_file "$T_DIR/record" "q at the inspection prompt launches nothing"

t_cli linux-alarm-fresh 'q\n' resume 'omb1:enc=1,user=alex,host=omarchy,kmap=us'
assert_contains "$T_OUT" "Stopped. Nothing changed." "q at 'Use these?' quits"
assert_not_contains "$T_OUT" "Encrypt [Y/n]" "q at 'Use these?' does not re-ask every choice"
assert_empty_file "$T_DIR/record" "q at 'Use these?' starts nothing"

# Enter at "Run the Claude Code installer?" must not run downloaded code.
t_cli linux-omarchy-installed '8\n1\n\n\n' dev --dry-run
assert_contains "$T_OUT" "Run the Claude Code installer? [y/N]" "the installer prompt defaults to no"
assert_not_contains "$T_OUT" "would run  bash" "Enter does not run the downloaded installer"

# --- A change the tool cannot record does not happen -------------------------------------
# state.env replaced by something that is not a plain file: every record
# fails, and the backup gate, which must be recorded, stops the run.
pre=$(t_tmp)
mkdir "$pre/state.env"
T_ENV="OMB_STATE_DIR=$pre" t_cli mac-m1pro-1tb-roomy "$mac_install_input"
assert_rc "$T_RC" 1 "an unrecordable run stops"
assert_contains "$T_OUT" "stopping before anything changes" "and says why"
assert_empty_file "$T_DIR/record" "an unrecordable run launches nothing"

# --- One recording run at a time -----------------------------------------------------------
pre=$(t_tmp)
(exec -a omarchy-bootstrap-lockholder sleep 30) &
holder=$!
mkdir "$pre/lock"
printf '%s 2026-09-25T00:00:00Z\n' "$holder" >"$pre/lock/owner"
T_ENV="OMB_STATE_DIR=$pre" t_cli linux-alarm-fresh '\n\nstart\n' resume 'omb1:enc=1,user=alex,host=omarchy,kmap=us'
assert_rc "$T_RC" 1 "a second recording run stops while one is running"
assert_contains "$T_OUT" "Another omarchy-bootstrap run" "the second run says why"
assert_empty_file "$T_DIR/record" "the second run launches nothing"
T_ENV="OMB_STATE_DIR=$pre" t_cli linux-alarm-fresh "" status
assert_rc "$T_RC" 0 "a read-only command still works while a run holds the lock"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
T_ENV="OMB_STATE_DIR=$pre" t_cli linux-alarm-fresh '\nalex\nm1pro\n\n' plan
assert_contains "$T_OUT" "Choices saved" "the lock of a run that has exited is cleared"
[ ! -e "$pre/lock" ] && ok || fail "a finished run releases its lock"

# --- The Omarchy handoff refuses upstream drift (acceptance criterion 9) -----------------
token='omb1:enc=1,user=alex,host=omarchy,kmap=us'
t_cli linux-upstream-drift '\n\nstart\n' resume "$token"
assert_rc "$T_RC" 1 "the handoff refuses Omarchy 3 on the branch"
assert_contains "$T_OUT" "now carries Omarchy 3.8.2, not 4.x. Refusing" "the version drift is named"
assert_not_contains "$T_OUT" "Type start" "no start gate after a version refusal"
assert_empty_file "$T_DIR/record" "nothing launched on version drift"

fx=$(t_variant linux-upstream-drift)
printf '4.0.3rc4\n' >"$fx/net/omarchy_version"
t_cli "$fx" '\n\nstart\n' resume "$token"
assert_rc "$T_RC" 1 "the handoff refuses a setup script missing a flag"
assert_contains "$T_OUT" "no longer declares: --keymap" "the missing flag is named"
assert_empty_file "$T_DIR/record" "nothing launched on flag drift"

fx=$(t_variant linux-alarm-fresh)
printf '<html>404 Not Found</html>\n' >"$fx/net/omarchy-mac-setup"
t_cli "$fx" '\n\nstart\n' resume "$token"
assert_rc "$T_RC" 1 "the handoff refuses a download that is not a bash script"
assert_contains "$T_OUT" "the download is not a bash script" "the refusal names the reason"
assert_empty_file "$T_DIR/record" "nothing launched from a non-script"

# --- Existing free space: no resize, and the reviewed size is typed ----------------------
t_cli mac-m1-free-space "$mac_install_input"
assert_rc "$T_RC" 0 "free-space install flow completes"
assert_not_contains "$T_OUT" "Resize an existing partition" "no resize step when the space already exists"
assert_contains "$T_OUT" "macOS is not resized" "the last-stop warning describes free-space mode"
assert_not_contains "$T_OUT" "its current size" "no nonsense resize wording"
read -r ans_r ans_os <<<"$(t_plan_answers mac-m1-free-space 250 0)"
assert_eq "$ans_r" - "free space: no resize answer"
assert_contains "$(cat "$T_DIR/record")" "pbcopy <<< $ans_os" "the clipboard gets the exact Linux size ($ans_os)"

# --- A changed storage contract blocks the launch; a stale display string does not -------
fx=$(t_variant mac-m1pro-1tb-roomy)
printf 'v0.10.0\n' >"$fx/net/asahi_version"
t_cli "$fx" "$mac_install_input"
assert_rc "$T_RC" 1 "a different installer version stops the handoff"
assert_contains "$T_OUT" "storage behaviour may have changed" "the refusal names the contract"
assert_contains "$(t_flat "$T_OUT")" "not v0.9.2, whose resize and allocation rules" "and the version"
assert_not_contains "$T_OUT" "When the Asahi Alarm installer asks" "no answer card for an unverified installer"
assert_empty_file "$T_DIR/record" "nothing launched for an unverified installer"
fx=$(t_variant mac-m1pro-1tb-roomy)
sed -i.bak 's/"524288000B", "format"/"1073741824B", "format"/' "$fx/net/asahi_data" && rm -f "$fx/net/asahi_data.bak"
t_cli "$fx" "$mac_install_input"
assert_rc "$T_RC" 1 "a changed EFI size stops the handoff"
assert_contains "$(t_flat "$T_OUT")" "no longer has a 524288000-byte EFI partition" "the EFI drift is named"
assert_empty_file "$T_DIR/record" "nothing launched on EFI drift"
rm -f "$fx/net/asahi_data"
t_cli "$fx" "$mac_install_input"
assert_contains "$(t_flat "$T_OUT")" "installer_data.json could not be read" "an unreadable OS list stops the handoff"
assert_empty_file "$T_DIR/record" "nothing launched without the OS list"

# --- The disk is read again right before the launch ------------------------------------------
# recheck_after CHANGE — plan on a fresh copy of the roomy fixture, apply
# CHANGE (a sed script on one fixture file) as if the disk changed between
# the survey and the launch, and print mac_recheck_plan's status.
recheck_after() {
  (
    t_load
    OMB_FIXTURE=$(t_variant mac-m1pro-1tb-roomy)
    OMB_STATE_DIR=$(t_tmp)
    state_init
    mac_detect
    CFG_linux=250 CFG_shared=50
    mac_plan_compute 50
    plan_layout $((250 * GB))
    if [ -n "$1" ]; then
      sed -i.bak "$2" "$OMB_FIXTURE/cmd/$1" && rm -f "$OMB_FIXTURE/cmd/$1.bak"
    fi
    mac_recheck_plan >/dev/null 2>&1
    printf '%s' $?
  )
}
if command -v plutil >/dev/null 2>&1; then
  assert_eq "$(recheck_after "" "")" 0 "an unchanged disk passes the pre-launch recheck"
  assert_eq "$(recheck_after diskutil_info_disk0s3 's#000000000003#000000000009#')" 1 "a changed partition identity stops the launch"
  assert_eq "$(recheck_after diskutil_info_root 's#<integer>700000000000</integer>#<integer>100000000000</integer>#')" 1 "macOS filling up since the plan stops the launch"
fi

# --- A download that is not the expected bootstrap is refused -----------------------------
fx=$(t_variant mac-m1pro-1tb-roomy)
printf '<html><body>Please sign in to the Wi-Fi</body></html>\n' >"$fx/net/asahi-alarm-bootstrap.sh"
t_cli "$fx" "$mac_install_input"
assert_rc "$T_RC" 1 "wrong-shape bootstrap stops the handoff"
assert_contains "$T_OUT" "Refusing: this is not the Asahi Alarm bootstrap" "refusal explains itself"
assert_not_contains "$T_OUT" "When the Asahi Alarm installer asks" "no answer card after a refusal"
assert_empty_file "$T_DIR/record" "nothing launched from a wrong-shape download"

# --- Blocked machines stop before planning ------------------------------------------------
t_cli mac-intel '\n\n\n' --dry-run
assert_rc "$T_RC" 1 "Intel stops"
assert_not_contains "$T_OUT" "How much storage" "Intel never reaches the planner"
t_cli mac-asahi-installed '\n\n\n'
assert_contains "$T_OUT" "will not start a second install" "existing install is not reinstalled"
assert_not_contains "$T_OUT" "How much storage" "existing install never reaches the planner"
t_cli linux-omarchy-installed 'n\n'
assert_contains "$T_OUT" "Omarchy is installed" "installed Omarchy is recognised"
assert_empty_file "$T_DIR/record" "installed Omarchy triggers nothing"

# --- Upstream output never reaches the log -----------------------------------------------
t_load
OMB_STATE_DIR=$(t_tmp)
OMB_DRY_RUN=0
unset OMB_TEST_RECORD
printf 'PASSWORD-TYPED-INTO-UPSTREAM\n' >"$OMB_STATE_DIR/upstream-output"
run cat "$OMB_STATE_DIR/upstream-output" >/dev/null
log=$(cat "$(log_file)")
assert_not_contains "$log" "PASSWORD-TYPED-INTO-UPSTREAM" "command output is not logged"
assert_contains "$log" "exit   0" "exit code is logged"

t_done test-safety
