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
CMDPOS='(^[[:space:]]*|[;&|({][[:space:]]*|![[:space:]]+|\$\([[:space:]]*|(then|do|else|if|while|until|run|sudo|exec|command|env|time|xargs|nohup)[[:space:]]+|run_withheld[[:space:]]+[0-9]+[[:space:]]+|ui_spin[[:space:]]+"[^"]*"[[:space:]]+)'

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
ADDPART='run sudo -n diskutil addPartition "$SHARED_PRED_ID" "$SHARED_FS_MAC" "$SHARED_LABEL" "$SH_SIZE"'
hits=$(grep -n 'diskutil' $CODE | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' |
  grep -E 'diskutil[[:space:]]+(erase|partition|resize|split|merge|add|zero|random|secure|reformat|unmount|mount|apfs[[:space:]]+(delete|add|create|erase|convert|unlock|encrypt|decrypt|change|resizeContainer))' |
  grep -v 'resizeContainer "\$1" limits -plist' | grep -vF "$ADDPART" | grep -v 'ui_cmd "sudo -n diskutil addPartition' |
  grep -v 'act_fact shared.create command "Command" "sudo -n diskutil addPartition')
# The text shown before the creation (the text flow's ui_cmd, and the same
# command as shared.create's gate fact) only displays it; the one run is ADDPART.
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
seq=$(printf '%s\n' "$body" | grep -oE 'ui_confirm_word yes|ui_confirm_word create|run sudo -v|mac_detect_geometry|shared_txn_save|run sudo -n diskutil addPartition' | tr '\n' '|')
assert_eq "$seq" "ui_confirm_word yes|ui_confirm_word create|run sudo -v|mac_detect_geometry|shared_txn_save|run sudo -n diskutil addPartition|" \
  "addPartition runs only after both typed gates, sudo's authentication, a fresh read of the disk, and the creation record"
assert_eq "$(grep -ho 'run sudo -[a-z]*' $CODE | LC_ALL=C sort | tr '\n' ';')" "run sudo -n;run sudo -v;" \
  "sudo takes an option only twice: -v to authenticate before the Shared creation's last read, -n for the creation itself"
# The partition change never prompts after the disk was checked: its only
# form is sudo -n, and -n fronts nothing else.
assert_eq "$(grep -h 'run sudo -n' $CODE | sed 's/^[[:space:]]*//')" "$ADDPART" "sudo -n runs exactly the one Shared creation, and nothing else"
assert_eq "$(grep -c 'run sudo diskutil' $CODE | awk -F: '{s += $NF} END {print s}')" 0 "no diskutil through an interactive sudo"
# Nothing reaches the device argument from a file: it is the fresh read's id.
assert_eq "$(printf '%s\n' "$body" | grep -c 'SHARED_PRED_ID=')" 0 "the creation never sets the device itself"
assert_eq "$(grep -c 'SHARED_PRED_ID=\$GP_ID' "$REPO/lib/shared.sh")" 1 "the device is the partition found on the disk right before the region"

# --- Static: every probe is read-only ----------------------------------------------
probes=$(grep -h 'sys_cmd ' $CODE | grep -v '^[[:space:]]*#' | grep -o 'sys_cmd [^|)]*' | sed 's/^sys_cmd [^ ]* //' | sort -u)
bad=$(printf '%s\n' "$probes" | grep -vE '^("\$@"|uname -[smr]|id -(u|un|Gn|g)|sysctl -n |sw_vers -productVersion|system_profiler -xml SPHardwareDataType|diskutil (info|list) -plist |diskutil apfs list -plist|diskutil apfs resizeContainer "\$1" limits -plist|fdesetup isactive|readlink /etc/localtime|defaults read |tmutil (destinationinfo|latestbackup)|git -C "\$OMB_HOME" (remote get-url origin|rev-parse --abbrev-ref HEAD|rev-parse HEAD|branch -r --contains HEAD)|git config --global user\.(name|email)|findmnt -no |lsblk -no TYPE |lsblk -nsplo NAME,TYPE |lsblk -bPno NAME,PKNAME,TYPE,START,SIZE,PARTUUID,PARTTYPE,FSTYPE,LABEL,UUID,MAJ:MIN|cryptsetup luksDump |pmset -g batt|ip route|systemctl is-active |ss -Htln|getconf PAGESIZE|timedatectl show |snapper --no-headers list-configs|pacman -(Qq|Dk)|pacman -Q "\$(RST_TARGET|p)" >/dev/null ;;$|pacman -Si "\$RST_TARGET" >/dev/null $|git config --file "\$f" --no-includes --get "\$name" >"\$RST_W/git.value"$|command -v "\$AG_BINARY"$|systemctl is-enabled sshd$|sshd -T$|passwd -S alarm$|df -Pk /|df -Pk "\$(SHARED_MOUNT|SHARED_MNT|BNDL_DEST)"|localectl list-locales|"\$OMS_SELF" --status|gh auth status|dscl \. -read "/Users/\$SCAN_USER" NFSHomeDirectory UserShell)')
assert_eq "$bad" "" "every sys_cmd probe is on the read-only list"

# --- Static: every mutating command goes through run, and is expected -------------
# Lists compared against a literal are sorted in byte order (LC_ALL=C), so the
# comparison holds under any host locale.
run_commands() {
  code_lines | grep -oE '(^|[[:space:];&|(])run(_withheld[[:space:]]+[0-9]+)?[[:space:]]+[^;|&]*' | sed -E 's/^[[:space:];&|(]*run(_withheld[[:space:]]+[0-9]+)?[[:space:]]+//' | awk '{print $1}' | sort -u | tr '\n' ' '
}
# A literal position keeps withheld argv readable to every static scan.
invalid_withheld() {
  code_lines | sed 's/^[^:]*:[0-9]*: //' |
    grep -oE '(^|[[:space:];&|(])run_withheld[[:space:]]+[^;|&]*' |
    grep -vE 'run_withheld[[:space:]]+[0-9]+([[:space:]]|$)'
}
assert_eq "$(invalid_withheld)" "" safety-withheld-literal-position
# Normalize the wrapper before the sudo-specific allowlists, just as for run.
sudo_lines() {
  raw_lines | sed -E 's/^[^:]*:[0-9]*: //; s/run_withheld[[:space:]]+[0-9]+[[:space:]]+/run /g'
}
direct_sudos() {
  code_lines | sed -E 's/^[^:]*:[0-9]*: //; s/run_withheld[[:space:]]+[0-9]+[[:space:]]+/run /g' |
    grep -E '(^[[:space:]]*|[;&|({!][[:space:]]*|\$\([[:space:]]*|(then|do|else|if|exec|command|env|xargs)[[:space:]]+)sudo[[:space:]]'
}
# Setting values are the only reason for withholding argv; no such command
# needs sudo, regardless of which sudo options precede its executable.
withheld_sudos() {
  code_lines | sed 's/^[^:]*:[0-9]*: //' |
    grep -E '(^|[[:space:];&|(])run_withheld[[:space:]]+[0-9]+[[:space:]]+sudo([[:space:]]|$)'
}
assert_eq "$(withheld_sudos)" "" safety-withheld-sudo-forbidden
quoted_commands() {
  raw_lines | sed 's/^[^:]*:[0-9]*: //' |
    grep -oE '(^|[[:space:];&|(])run(_withheld[[:space:]]+[0-9]+)?[[:space:]]+"[^"]*"[^;|&]*' |
    sed -E 's/^[[:space:];&|(]*//; s/run_withheld[[:space:]]+[0-9]+[[:space:]]+/run /; s/^run[[:space:]]+/run /; s/[[:space:]]+$//' | sort -u
}
runs=$(run_commands)
for cmd in $runs; do
  case "$cmd" in
    sh | bash | nmtui | sudo | git | gh | ssh-keygen | npm | cp | sync | rm | \
      chmod | claude | env | ln | mkdir | mv | rst_log_write | rst_stage_write | uv | \
      mise | timeout | systemctl | \
      omarchy-pkg-add | omarchy-install-dev-env | omarchy-install-editor-vscode | \
      omarchy-setup-security-sshd | omarchy-setup-security-sudoless-docker) ok ;;
    '""') ;; # a quoted first argument: checked exactly below
    *) fail "unexpected command through run: $cmd" ;;
  esac
done
# safety-withheld-command-scans: planted wrappers must be visible to the
# same forbidden-command and run allowlist scans used above.
scan_tmp=$(t_tmp)
saved_code=$CODE
printf '%s\n' 'run_withheld 2 dd if=input of=output' 'run_withheld 2 restore-unlisted-command value' >"$scan_tmp/planted.sh"
CODE=$scan_tmp/planted.sh
hits=$(raw_lines | sed 's/^[^:]*:[0-9]*: //' | grep -E "${CMDPOS}${FORBIDDEN_RE}([[:space:]]|\$)")
assert_contains "$hits" 'run_withheld 2 dd' safety-withheld-forbidden-visible
assert_contains "$(run_commands)" 'restore-unlisted-command' safety-withheld-unlisted-visible
printf '%s\n' 'run_withheld 4 sudo rm -- "$HOME/.bashrc"' >"$scan_tmp/planted.sh"
assert_contains "$(sudo_lines | grep -o 'run sudo [a-z]* [^ ]*')" 'run sudo rm --' safety-withheld-sudo-allowlist-visible
assert_eq "$(direct_sudos)" "" safety-withheld-sudo-through-run
assert_contains "$(withheld_sudos)" sudo safety-withheld-sudo-plain-refused
printf '%s\n' 'run_withheld 3 sudo -n rm -- "$HOME/.bashrc"' >"$scan_tmp/planted.sh"
assert_contains "$(withheld_sudos)" 'sudo -n' safety-withheld-sudo-options-refused
for spacing in '  ' $'\t'; do
  printf 'run_withheld%s5%sunlisted-cmd x\n' "$spacing" "$spacing" >"$scan_tmp/planted.sh"
  assert_contains "$(run_commands)" unlisted-cmd safety-withheld-whitespace-command-visible
  printf 'run_withheld%s5%s"$UNLISTED_CMD" x\n' "$spacing" "$spacing" >"$scan_tmp/planted.sh"
  assert_contains "$(quoted_commands)" '$UNLISTED_CMD' safety-withheld-whitespace-quoted-visible
done
printf '%s\n' 'run_withheld "$n" git config x y' >"$scan_tmp/planted.sh"
assert_contains "$(invalid_withheld)" run_withheld safety-withheld-variable-position-refused
printf '%s\n' 'sudo rm -- "$HOME/.bashrc"' >"$scan_tmp/planted.sh"
assert_contains "$(direct_sudos)" 'sudo rm' safety-direct-sudo-refused
CODE=$saved_code
rm -rf "$scan_tmp"
quoted=$(quoted_commands)
assert_eq "$quoted" 'run "$@"
run "$AG_PATH" "$@"
run "$OMS_SELF" --resume' "indirect commands are the observed agent handoff and omarchy-mac-setup --resume"
assert_eq "$(grep -hE 'run systemctl ' $CODE | sed 's/^[[:space:]]*//; s/[[:space:]]*>.*$//')" \
  'run systemctl disable --now sshd' "the direct systemctl mutation only stops and disables image SSH"
# Restore removes only its matched staging names, and every rename/link has
# exact-destination semantics. Plain mv/ln must fail these restore pins.
restore=$REPO/lib/migrate_restore.sh
assert_eq "$(grep -oE 'run rm [^;|&>]*' "$restore" | sed 's/[[:space:]]*$//' | LC_ALL=C sort)" \
  'run rm -- "$check/linked" "$check/symlink"
run rm -- "$src"
run rm -- "$src"
run rm -r -- "$check"
run rm -r -- "$stage"' 'restore removes only completed or read-back-matched stages'
assert_eq "$(grep -E '^[[:space:]]*(path=.* stage=|stage=)' "$restore" | sed 's/^[[:space:]]*//')" \
  'path=$RST_HOME/$dest stage=$RST_HOME/$dest.omb-new-$RST_RUN
stage=$RST_HOME/${RST_DEST[n]}.omb-new-$RST_RUN
stage=$path.omb-undo-$RST_RUN
stage=$path.omb-undo-$RST_RUN
stage=$path.omb-new-$RST_RUN' 'restore stage names are the destination plus omb-new/omb-undo and the manifest SHA'
assert_eq "$(grep -E '_rst_transfer ' "$restore" | sed 's/^[[:space:]]*//')" \
  'if ! _rst_parents "$dest" 0 || ! _rst_checkpoint restore.place || ! _rst_transfer "$stage" "$path" "$new"; then
_rst_transfer "$stage" "$path" "$old" || return 1
if [ "$old" != absent ]; then _rst_transfer "$stage" "$path" "$old" || return 1; fi' 'restore transfer removes only those stages'
restore_no_clobber() {
  local moves links copies
  moves=$(grep -v '^[[:space:]]*#' "$1" | grep -oE '(^|[[:space:]])mv [^;|&>]*' | sed 's/^[[:space:]]*//')
  links=$(grep -v '^[[:space:]]*#' "$1" | grep -oE '(^|[[:space:]])ln [^;|&>]*' | sed 's/^[[:space:]]*//')
  copies=$(grep -v '^[[:space:]]*#' "$1" | grep -oE 'run cp [^;|&>]*' | sed 's/^run //')
  [ -n "$moves" ] && [ -n "$links" ] && [ -n "$copies" ] || return 1
  ! printf '%s\n' "$moves" | grep -qv '^mv -T --update=none-fail -- ' &&
    ! printf '%s\n' "$links" | grep -qvE '^ln (-s )?-T -- ' &&
    ! printf '%s\n' "$copies" | grep -qv '^cp -a -T -- '
}
restore_no_clobber "$restore"
assert_eq "$?" 0 restore-all-moves-and-links-no-clobber
pin_tmp=$(t_tmp)
for primitive in mv ln cp; do
  cp "$restore" "$pin_tmp/restore.sh"
  printf 'run %s "$source" "$destination"\n' "$primitive" >>"$pin_tmp/restore.sh"
  restore_no_clobber "$pin_tmp/restore.sh"
  assert_eq "$?" 1 "restore-plain-$primitive-refused"
done
rm -rf "$pin_tmp"
assert_eq "$(grep -E '^[[:space:]]*RST_RUN=\$' "$restore" | sed 's/^[[:space:]]*//')" \
  'RST_RUN=$BNDL_SHA' 'the stage suffix comes from the checked manifest SHA'
# Restore's setting value positions are deliberately withheld at the existing
# run boundary; no unmasked Git write or MCP add-json can bypass this pin.
assert_eq "$(grep -E 'run(_withheld [0-9]+)? (git config|claude mcp add-json)' "$restore" | sed 's/^[[:space:]]*//')" \
  'run_withheld 8 git config --file "$RST_HOME/.gitconfig" --no-includes -- "$name" "$value" >/dev/null 2>&1 || :
run_withheld 5 claude mcp add-json "$name" "$value" --scope user >/dev/null 2>&1 || :
run_withheld 8 git config --file "$RST_HOME/.gitconfig" --no-includes -- "$name" "$RST_SAVED_VALUE" >/dev/null 2>&1 || :
else run git config --file "$RST_HOME/.gitconfig" --no-includes --unset-all -- "$name" >/dev/null 2>&1 || :; fi
run_withheld 5 claude mcp add-json "$name" "$RST_SAVED_VALUE" --scope user >/dev/null 2>&1 || :' 'restore withholds every setting value'
sudos=$(sudo_lines | grep -o 'run sudo [a-z]* [^ ]*' | LC_ALL=C sort -u | tr '\n' ';')
assert_eq "$sudos" "run sudo cp -p;run sudo install -d;run sudo install -m;run sudo localectl set-locale;run sudo mv -f;run sudo pacman -S;run sudo systemctl daemon-reload;run sudo systemctl start;run sudo timedatectl set-timezone;" "sudo is used only for packages, timezone, locale, the Shared mount, and the one Shared creation"
assert_eq "$(sudo_lines | grep -oE 'run sudo (cp|mv|install) [^&]*' | sed 's/ *$//' | LC_ALL=C sort -u | tr '\n' ';')" \
  'run sudo cp -p /etc/fstab /etc/fstab.omarchy-bootstrap.bak;run sudo install -d -m 0755 -o root -g root "$SHARED_MNT";run sudo install -m 0644 -o root -g root "$tmp" /etc/fstab.omarchy-bootstrap.new;run sudo mv -f /etc/fstab.omarchy-bootstrap.new /etc/fstab;' \
  "privileged file changes are exactly the Shared mount point and the managed fstab"
assert_eq "$(sudo_lines | grep -oE 'run sudo systemctl [^&]*' | sed 's/ *$//' | LC_ALL=C sort -u | tr '\n' ';')" \
  'run sudo systemctl daemon-reload;run sudo systemctl start "$SHARED_UNIT";' "systemctl only reloads and starts the Shared automount"
hits=$(direct_sudos)
assert_eq "$hits" "" "sudo only ever runs through run"

# --- Dynamic: dry-run executes nothing ------------------------------------------------
mac_install_input='\n\n\n\n\n\n\n\n\n\n\n\n\nyes\n\nlaunch\n'
if t_plutil "the macOS dry run executes nothing"; then
  t_cli mac-m1pro-1tb-roomy "$mac_install_input" --dry-run
  assert_rc "$T_RC" 0 "mac dry-run completes"
  assert_contains "$T_OUT" "would run  sh " "mac dry-run shows the installer command"
  assert_contains "$T_OUT" "the installer was not launched" "mac dry-run says so"
  assert_empty_file "$T_DIR/shims.log" "mac dry-run invoked a forbidden command"
  assert_empty_file "$T_DIR/record" "mac dry-run recorded an execution"
  assert_eq "$(ls "$T_DIR/state/state.env" 2>/dev/null)" "" "mac dry-run wrote no state"
fi

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
# enable SSH y; AI CLIs 1 2 use the shared mise installer.
T_ENV='HOME=/home/alex' t_cli agt-wrappers '1 2 3 4 5 6 7 8 9\n1 2 3 4\n2\ny\nAlex\nalex@example.com\n\n\ny\n1 2\n\ny\n' dev --dry-run
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
  "mise use -g --quiet claude" "mise use -g --quiet codex"; do
  assert_contains "$T_OUT" "would run  $expected" "dev module ran: $expected"
done
assert_eq "$(ls -A "$T_DIR/tmp")" "" "a dry-run download is removed when the run ends"
assert_eq "$(ls "$T_DIR/state" 2>/dev/null)" "" "dev dry-run keeps no state, log or download"
assert_contains "$T_OUT" "Developer setup finished" "every previewed module completes"
assert_rc "$T_RC" 0 "the shared mise preview succeeds"
assert_empty_file "$T_DIR/shims.log" "dev dry-run invoked a forbidden command"
assert_empty_file "$T_DIR/record" "dev dry-run recorded an execution"

# --- Dynamic: the exact argv that would execute, recorded not run -----------------------
if t_plutil "the recorded macOS launch"; then
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
fi

t_cli linux-alarm-fresh '\n\nstart\n' resume 'omb1:enc=0,user=alex,host=omarchy,kmap=de'
rec=$(cat "$T_DIR/record")
assert_contains "$rec" "bash $T_DIR/state/downloads/omarchy-mac-setup-" "setup launched from the downloaded file"
assert_contains "$rec" "--no-encrypt --user alex --hostname omarchy --keymap de" "setup flags from the token"
assert_empty_file "$T_DIR/shims.log" "linux record mode invoked a forbidden command"

# --- Gates: Enter alone, or the wrong word, never launches --------------------------------
if t_plutil "the macOS backup and launch gates"; then
  t_cli mac-m1pro-1tb-roomy '\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n'
  rec=$(cat "$T_DIR/record")
  assert_eq "$rec" "" "Enter through every prompt launches nothing"
  assert_contains "$T_OUT" "Stopped before anything changed" "backup gate holds on Enter"
  assert_not_contains "$(cat "$T_DIR/state/state.env" 2>/dev/null)" "asahi_launched_at" "no launch recorded"

  t_cli mac-m1pro-1tb-roomy '\n\n\n\n\n\n\n\n\n\n\n\n\nyes\n\nyes\ny\nLAUNCH\nn\n'
  rec=$(cat "$T_DIR/record")
  assert_not_contains "$rec" "sh " "the wrong word at the launch gate launches nothing"
  assert_contains "$T_OUT" 'only the exact word "launch" continues' "launch gate explains itself"
fi

t_cli linux-alarm-fresh '\n\n\n' resume 'omb1:enc=1,user=alex,host=omarchy,kmap=us'
rec=$(cat "$T_DIR/record")
assert_eq "$rec" "" "Enter at the start gate starts nothing"

if t_plutil "q at the macOS inspection prompt"; then
  t_cli mac-m1pro-1tb-roomy '\n\n\n\n\n\n\n\n\n\n\n\n\nyes\nq\nlaunch\n'
  assert_contains "$T_OUT" "Not launched. Nothing changed." "q at the inspection prompt quits"
  assert_empty_file "$T_DIR/record" "q at the inspection prompt launches nothing"
fi

t_cli linux-alarm-fresh 'q\n' resume 'omb1:enc=1,user=alex,host=omarchy,kmap=us'
assert_contains "$T_OUT" "Stopped. Nothing changed." "q at 'Use these?' quits"
assert_not_contains "$T_OUT" "Encrypt [Y/n]" "q at 'Use these?' does not re-ask every choice"
assert_empty_file "$T_DIR/record" "q at 'Use these?' starts nothing"

# agents-mise-install: the selection itself authorizes the shared installer.
T_ENV='HOME=/home/alex' t_cli agt-wrappers '8\n1 2 3\n' dev --dry-run
for package in claude codex opencode; do
  assert_contains "$T_OUT" "would run  mise use -g --quiet $package" "mise previews $package"
done
assert_not_contains "$T_OUT" 'Run the Claude Code installer?' 'no downloaded-installer prompt remains'
assert_not_contains "$T_OUT" 'would run  npm' 'AI installs use mise'
assert_empty_file "$T_DIR/record" 'the AI preview executes nothing'

# --- A change the tool cannot record does not happen -------------------------------------
# state.env replaced by something that is not a plain file: every record
# fails, and the backup gate, which must be recorded, stops the run.
if t_plutil "an unrecordable macOS run"; then
  pre=$(t_tmp)
  mkdir "$pre/state.env"
  T_ENV="OMB_STATE_DIR=$pre" t_cli mac-m1pro-1tb-roomy "$mac_install_input"
  assert_rc "$T_RC" 1 "an unrecordable run stops"
  assert_contains "$T_OUT" "stopping before anything changes" "and says why"
  assert_empty_file "$T_DIR/record" "an unrecordable run launches nothing"
fi

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
if t_plutil "the free-space install flow"; then
  t_cli mac-m1-free-space "$mac_install_input"
  assert_rc "$T_RC" 0 "free-space install flow completes"
  assert_not_contains "$T_OUT" "Resize an existing partition" "no resize step when the space already exists"
  assert_contains "$T_OUT" "macOS is not resized" "the last-stop warning describes free-space mode"
  assert_not_contains "$T_OUT" "its current size" "no nonsense resize wording"
  read -r ans_r ans_os <<<"$(t_plan_answers mac-m1-free-space 250 0)"
  assert_eq "$ans_r" - "free space: no resize answer"
  assert_contains "$(cat "$T_DIR/record")" "pbcopy <<< $ans_os" "the clipboard gets the exact Linux size ($ans_os)"
fi

# --- A changed storage contract blocks the launch; a stale display string does not -------
if t_plutil "storage-contract drift"; then
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
fi

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
if t_plutil "the pre-launch recheck"; then
  assert_eq "$(recheck_after "" "")" 0 "an unchanged disk passes the pre-launch recheck"
  assert_eq "$(recheck_after diskutil_info_disk0s3 's#000000000003#000000000009#')" 1 "a changed partition identity stops the launch"
  assert_eq "$(recheck_after diskutil_info_root 's#<integer>700000000000</integer>#<integer>100000000000</integer>#')" 1 "macOS filling up since the plan stops the launch"
fi

# --- A download that is not the expected bootstrap is refused -----------------------------
if t_plutil "a wrong-shape bootstrap"; then
  fx=$(t_variant mac-m1pro-1tb-roomy)
  printf '<html><body>Please sign in to the Wi-Fi</body></html>\n' >"$fx/net/asahi-alarm-bootstrap.sh"
  t_cli "$fx" "$mac_install_input"
  assert_rc "$T_RC" 1 "wrong-shape bootstrap stops the handoff"
  assert_contains "$T_OUT" "Refusing: this is not the Asahi Alarm bootstrap" "refusal explains itself"
  assert_not_contains "$T_OUT" "When the Asahi Alarm installer asks" "no answer card after a refusal"
  assert_empty_file "$T_DIR/record" "nothing launched from a wrong-shape download"
fi

# --- Blocked machines stop before planning ------------------------------------------------
if t_plutil "blocked Macs"; then
  t_cli mac-intel '\n\n\n' --dry-run
  assert_rc "$T_RC" 1 "Intel stops"
  assert_not_contains "$T_OUT" "How much storage" "Intel never reaches the planner"
  t_cli mac-asahi-installed '\n\n\n'
  assert_contains "$T_OUT" "will not start a second install" "existing install is not reinstalled"
  assert_not_contains "$T_OUT" "How much storage" "existing install never reaches the planner"
fi
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
