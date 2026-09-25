#!/usr/bin/env bash
# Persistent state, the resume token, and log hygiene.
# shellcheck disable=SC2015,SC2016,SC2086 # ok/fail always return 0; literal $ in single quotes; file lists split on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load
echo "test-state"
OMB_PLATFORM=macos OMB_UID=501
OMB_STATE_DIR=$(t_tmp)
state_init

# --- Round trip ---------------------------------------------------------------
state_set cfg_linux 250
assert_eq "$(state_get cfg_linux)" 250 "set/get"
state_set cfg_linux 300
assert_eq "$(state_get cfg_linux)" 300 "overwrite"
assert_eq "$(grep -c '^cfg_linux=' "$STATE_FILE")" 1 "one line per key"
state_set note 'a=b=c'
assert_eq "$(state_get note)" 'a=b=c' "values may contain ="
state_set multi "line1
line2"
assert_eq "$(state_get multi)" line1line2 "newlines are stripped"
assert_eq "$(state_get missing fallback)" fallback "default for a missing key"
state_unset note
assert_eq "$(state_get note)" "" "unset"

# Values are data: the file is parsed, never sourced.
state_set probe '$(touch "'"$OMB_STATE_DIR"'/pwned")'
state_get probe >/dev/null
cfg_load
[ ! -e "$OMB_STATE_DIR/pwned" ] && ok || fail "a stored value was executed"

# Saved values reach shell arithmetic; an invalid one must never be applied.
state_set cfg_shared 'a[$(touch "'"$OMB_STATE_DIR"'/pwned-arith")]'
state_set cfg_linux 'x[$(touch "'"$OMB_STATE_DIR"'/pwned-arith")]'
CFG_shared=0 CFG_linux=250
cfg_load
: $(( ${CFG_shared:-0} * 2 )) $(( ${CFG_linux:-0} * 2 ))
[ ! -e "$OMB_STATE_DIR/pwned-arith" ] && ok || fail "a saved value executed through arithmetic"
assert_eq "$CFG_shared $CFG_linux" "0 250" "invalid saved values are dropped, not applied"
assert_contains "$(cat "$(log_file)")" "ignored invalid saved value cfg_shared" "the refusal is logged"
state_unset cfg_shared
state_unset cfg_linux
assert_eq "$(cfg_field_ok nonsense x; echo $?)" 2 "unknown choice keys are reported as unknown"

# --- Keys that could hold secrets are refused --------------------------------
for k in wifi_password sudo_pass gh_token luks_passphrase recovery_key api_secret github_credential Bad-Key ''; do
  state_set "$k" x 2>/dev/null
  assert_rc $? 1 "refuses key '$k'"
done
assert_not_contains "$(cat "$STATE_FILE")" "wifi_password" "refused key not written"

# --- Dry run records nothing ---------------------------------------------------
OMB_DRY_RUN=1
state_set dry_key 1
OMB_DRY_RUN=0
assert_eq "$(state_get dry_key)" "" "dry-run does not write state"

# --- Choices -------------------------------------------------------------------
CFG_enc=1 CFG_user=alex CFG_host=m1pro CFG_kmap=us CFG_tz=Europe/Berlin CFG_loc=de_DE.UTF-8 CFG_ssh=1 CFG_gh=octocat CFG_linux=250 CFG_shared=0 CFG_dev=1
cfg_save
unset CFG_user CFG_host CFG_tz
cfg_load
assert_eq "$CFG_user@$CFG_host $CFG_tz" "alex@m1pro Europe/Berlin" "choices round trip"

# --- Resume token ---------------------------------------------------------------
tok=$(token_encode)
assert_eq "$tok" "omb1:enc=1,user=alex,host=m1pro,kmap=us,tz=Europe/Berlin,loc=de_DE.UTF-8,ssh=1,gh=octocat,linux=250" "token encoding"
assert_not_contains "$tok" "shared" "token carries only whitelisted fields"
unset CFG_enc CFG_user CFG_host CFG_kmap CFG_tz CFG_loc CFG_ssh CFG_gh CFG_linux
token_decode "$tok"
assert_rc $? 0 "token decodes"
assert_eq "$CFG_enc $CFG_user $CFG_host $CFG_kmap $CFG_tz $CFG_loc $CFG_ssh $CFG_gh $CFG_linux" \
  "1 alex m1pro us Europe/Berlin de_DE.UTF-8 1 octocat 250" "token fields restored in the current shell"
assert_eq "$TOKEN_WARNINGS" "" "clean token has no warnings"

unset CFG_user CFG_host
token_decode "omb1:user=Root!,host=-bad-,enc=1,colour=blue"
assert_rc $? 0 "partially valid token still usable"
assert_eq "${CFG_user:-} ${CFG_host:-} $CFG_enc" "  1" "invalid fields are not applied"
assert_contains "$TOKEN_WARNINGS" "ignored user" "invalid user reported"
assert_contains "$TOKEN_WARNINGS" "ignored host" "invalid host reported"
assert_contains "$TOKEN_WARNINGS" "unknown field 'colour'" "unknown field reported"

( cd "$OMB_STATE_DIR" && touch glob-a glob-b && token_decode "omb1:user=alex,*" && printf '%s' "$TOKEN_WARNINGS" >"$OMB_STATE_DIR/tw" )
assert_not_contains "$(cat "$OMB_STATE_DIR/tw")" "glob-a" "token fields are not filename-expanded"
assert_contains "$(cat "$OMB_STATE_DIR/tw")" "unknown field '*'" "a literal * is reported as itself"
case $- in *f*) fail "token_decode left noglob on" ;; *) ok ;; esac

token_decode "hello"
assert_rc $? 1 "non-token rejected"
token_decode "omb1:"
assert_rc $? 1 "empty token rejected"
token_decode 'omb1:user=$(reboot)'
assert_rc $? 1 "command text is not a valid value"

# --- Validators -----------------------------------------------------------------
valid_username alex >/dev/null && ok || fail "alex is valid"
valid_username root >/dev/null && fail "root is refused" || ok
valid_username 9lives >/dev/null && fail "leading digit refused" || ok
valid_hostname omarchy-m1 >/dev/null && ok || fail "hostname valid"
valid_hostname -bad >/dev/null && fail "leading hyphen refused" || ok
valid_tz America/Argentina/Buenos_Aires >/dev/null && ok || fail "three-part tz"
valid_locale en_US.UTF-8 >/dev/null && ok || fail "locale valid"
valid_locale en_US >/dev/null && fail "non-UTF-8 locale refused" || ok
nl='
'
for v in "alex${nl}\$(reboot)" "omarchy${nl}X=1"; do
  valid_username "$v" >/dev/null && fail "multi-line username accepted: $v" || ok
  valid_hostname "$v" >/dev/null && fail "multi-line hostname accepted: $v" || ok
done
valid_tz "Europe/Berlin${nl}evil" >/dev/null && fail "multi-line timezone accepted" || ok
for u in alarm nobody bin systemd-network sddm; do
  valid_username "$u" >/dev/null && fail "system account accepted: $u" || ok
done
assert_contains "$(valid_username alarm)" "system account" "reserved names explain themselves"

# --- Logs mask anything credential-shaped ----------------------------------------
OMB_PHASE="test"
log_event exec "helper --password=hunter2 --token: abc123 passphrase=opensesame"
log=$(cat "$(log_file)")
assert_not_contains "$log" hunter2 "password value masked"
assert_not_contains "$log" abc123 "token value masked"
assert_not_contains "$log" opensesame "passphrase value masked"
assert_contains "$log" "[redacted]" "mask marker present"
log_event exec "tool PASSWORD pw-space --password pw-flag api_key=k-eq API-KEY: k-colon Authorization: Bearer t-bearer"
log=$(cat "$(log_file)")
for s in pw-space pw-flag k-eq k-colon t-bearer; do
  assert_not_contains "$log" "$s" "masked: $s"
done
log_event record "cfg_user=alex"
assert_contains "$(cat "$(log_file)")" "cfg_user=alex" "ordinary values are not masked"

# --- run marks what is executing, for an honest Ctrl-C message ------------------
probe() { printf '%s' "${OMB_RUNNING:-}" >"$OMB_STATE_DIR/running"; }
OMB_DRY_RUN=0
run probe --flag
assert_eq "$(cat "$OMB_STATE_DIR/running")" "probe --flag" "run exposes the executing command"
assert_eq "${OMB_RUNNING:-}" "" "the marker clears when the command returns"

# --- Downloads: private directory, re-hashed before execution --------------------------
OMB_FIXTURE="$FIX/linux-alarm-fresh"
fetch_upstream omarchy-mac-setup "https://example.invalid/setup"
assert_eq "$(find "$OMB_STATE_DIR/downloads" -maxdepth 0 -perm 700)" "$OMB_STATE_DIR/downloads" "downloads directory is private"
fetch_unchanged
assert_rc $? 0 "untouched download passes the re-hash"
printf '\n# edited\n' >>"$FETCH_PATH"
fetch_unchanged >/dev/null
assert_rc $? 1 "a download edited after fingerprinting is refused"
unset OMB_FIXTURE

# --- Inspection shows control characters; versions carry none ------------------------
printf 'echo visible\n\033[8mrm -rf hidden\033[0m\n' >"$OMB_STATE_DIR/esc-probe"
shown=$(PAGER="cat" view_file "$OMB_STATE_DIR/esc-probe")
assert_contains "$shown" '^[[8mrm -rf hidden' "escape codes are shown, not interpreted"
assert_not_contains "$shown" "$(printf '\033')" "no raw escape reaches the terminal"
assert_eq "$(printf 'v0.9.2\033[31m\r\nsecond line\n' | clean_version)" "v0.9.231m" "versions lose control codes and extra lines"

# --- Fixture mode never executes ---------------------------------------------------
OMB_FIXTURE="$FIX/linux-alarm-fresh"
run probe --from-fixture >/dev/null
assert_rc $? 1 "fixture mode refuses to execute without the recorder"
assert_eq "$(cat "$OMB_STATE_DIR/running")" "probe --flag" "the refused command did not run"
unset OMB_FIXTURE

t_done test-state
