# shellcheck shell=bash
# Persistent, non-secret progress: state.env (key=value, parsed, never sourced)
# and the resume token that carries Phase 1 choices across the reboot.

state_init() {
  if [ -z "${OMB_STATE_DIR:-}" ]; then
    if [ "$OMB_PLATFORM" = linux ] && [ "$OMB_UID" = 0 ]; then
      OMB_STATE_DIR=/var/lib/omarchy-mac-bootstrap
    else
      OMB_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-mac-bootstrap"
    fi
  fi
  STATE_FILE="$OMB_STATE_DIR/state.env"
  # The record a root run of Phase 2 leaves for the later non-root run.
  STATE_SYSTEM_FILE=$(sys_path /var/lib/omarchy-mac-bootstrap/state.env)
  mkdir -p "$OMB_STATE_DIR" 2>/dev/null
}

# state_get KEY [DEFAULT] [FILE]
state_get() {
  local file=${3:-$STATE_FILE} v
  if [ -f "$file" ]; then
    v=$(grep "^$1=" "$file" 2>/dev/null | tail -1)
    if [ -n "$v" ]; then
      printf '%s' "${v#*=}"
      return 0
    fi
  fi
  printf '%s' "${2:-}"
  [ -n "${2:-}" ]
}

# Keys that could ever hold a secret are refused outright; nothing in this
# tool collects one, and this keeps it that way.
state_key_allowed() {
  case "$1" in
    *[!a-z0-9_]* | '') return 1 ;;
    *pass* | *secret* | *token* | *credential* | *recovery* | *key_material*) return 1 ;;
  esac
  return 0
}

# state_set KEY VALUE — atomic rewrite; skipped (and logged) in dry-run.
state_set() {
  local key=$1 value=$2 tmp
  if ! state_key_allowed "$key"; then
    log_event refuse "state key '$key' is not allowed"
    return 1
  fi
  value=$(printf '%s' "$value" | tr -d '\r\n')
  if [ "$OMB_DRY_RUN" = 1 ]; then
    log_event dryrun "would record $key=$value"
    return 0
  fi
  mkdir -p "$OMB_STATE_DIR" || return 1
  tmp="$STATE_FILE.tmp.$$"
  { [ -f "$STATE_FILE" ] && grep -v "^$key=" "$STATE_FILE"; printf '%s=%s\n' "$key" "$value"; } >"$tmp" &&
    mv "$tmp" "$STATE_FILE"
  log_event record "$key=$value"
}

state_stamp() { state_set "$1" "$(now_utc)"; }

state_unset() {
  [ -f "$STATE_FILE" ] || return 0
  [ "$OMB_DRY_RUN" = 1 ] && return 0
  local tmp="$STATE_FILE.tmp.$$"
  grep -v "^$1=" "$STATE_FILE" >"$tmp"
  mv "$tmp" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Choices — the non-secret answers that shape both phases. Held in CFG_*
# globals during a run; persisted with cfg_save.
# ---------------------------------------------------------------------------

CFG_KEYS="enc user host kmap tz loc ssh gh linux shared dev"

# cfg_load [FILE] — loads saved choices (default: this run's state file). A
# value is applied only if it passes cfg_field_ok: state is data, and values
# such as cfg_shared later reach shell arithmetic, which evaluates subscripts.
cfg_load() {
  local file=${1:-$STATE_FILE} k v
  for k in $CFG_KEYS; do
    v=$(state_get "cfg_$k" "" "$file")
    [ -n "$v" ] || continue
    if cfg_field_ok "$k" "$v"; then
      eval "CFG_$k=\$v"
    else
      log_event refuse "ignored invalid saved value cfg_$k in $file"
    fi
  done
}

cfg_save() {
  local k v
  for k in $CFG_KEYS; do
    eval "v=\${CFG_$k:-}"
    # An emptied choice is removed, so a cleared optional answer stays cleared.
    if [ -n "$v" ]; then state_set "cfg_$k" "$v"; else state_unset "cfg_$k"; fi
  done
  return 0
}

# Validators print the reason and return non-zero, for ui_ask. They match the
# whole string ([[ =~ ]]), not line by line as `grep` would: a value holding
# a newline must never pass because one of its lines does.
_whole() { [[ $1 =~ $2 ]]; }

# Accounts an Arch / Asahi Alarm system already has; the everyday login must
# be a new user.
RESERVED_USERS="root bin daemon sys adm mail ftp http nobody dbus alarm sddm polkitd rtkit avahi uuidd colord git"

valid_username() {
  case " $RESERVED_USERS " in
    *" $1 "*)
      printf '   %s\n' "'$1' is a system account on Arch; choose your everyday login."
      return 1
      ;;
  esac
  case "$1" in
    systemd-*)
      printf '   %s\n' "'$1' is a system account on Arch; choose your everyday login."
      return 1
      ;;
  esac
  _whole "$1" '^[a-z_][a-z0-9_-]{0,31}$' && return 0
  printf '   %s\n' "Lowercase letters, digits, - and _, starting with a letter (Linux username rules)."
  return 1
}

valid_hostname() {
  _whole "$1" '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$' && return 0
  printf '   %s\n' "Letters, digits and hyphens; not starting or ending with a hyphen; up to 63 characters."
  return 1
}

valid_keymap() {
  _whole "$1" '^[A-Za-z0-9_.-]{1,32}$' && return 0
  printf '   %s\n' "A console keymap name such as us, uk, de, fr, or dvorak."
  return 1
}

valid_tz() {
  _whole "$1" '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$' && return 0
  printf '   %s\n' "An IANA timezone such as America/New_York or Europe/Berlin."
  return 1
}

valid_locale() {
  _whole "$1" '^[a-z]{2,3}(_[A-Z]{2})?\.UTF-8$' && return 0
  printf '   %s\n' "A UTF-8 locale such as en_US.UTF-8."
  return 1
}

valid_ghuser() {
  case "$1" in "" | -) return 0 ;; esac
  _whole "$1" '^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$' && return 0
  printf '   %s\n' "A GitHub username (letters, digits, hyphens); empty to skip, - to clear."
  return 1
}

valid_bool() { case "$1" in 0 | 1) return 0 ;; esac; return 1; }
valid_gb() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; return 0; }

# cfg_field_ok KEY VALUE — the one rule for every choice, whichever way it
# arrives (answers, state.env, a resume token). 0 valid, 1 invalid, 2 unknown.
cfg_field_ok() {
  case "$1" in
    enc | ssh | dev) valid_bool "$2" ;;
    user) valid_username "$2" ;;
    host) valid_hostname "$2" ;;
    kmap) valid_keymap "$2" ;;
    tz) valid_tz "$2" ;;
    loc) valid_locale "$2" ;;
    gh) [ "$2" != "-" ] && valid_ghuser "$2" ;;
    linux | shared) valid_gb "$2" ;;
    *) return 2 ;;
  esac >/dev/null
}

# ---------------------------------------------------------------------------
# Resume token — readable, hand-typeable, whitelisted fields only.
#   omb1:enc=1,user=alex,host=m1pro,kmap=us,tz=America/New_York,...
# ---------------------------------------------------------------------------

TOKEN_FIELDS="enc user host kmap tz loc ssh gh linux"

token_encode() {
  local out="omb1:" k v sep=""
  for k in $TOKEN_FIELDS; do
    eval "v=\${CFG_$k:-}"
    [ -n "$v" ] || continue
    out="$out$sep$k=$v"
    sep=","
  done
  printf '%s' "$out"
}

# token_decode TOKEN — fills CFG_* from a token (in the current shell, so no
# command substitution). One line per ignored field goes to TOKEN_WARNINGS;
# returns non-zero when the token is unusable.
_tw() {
  TOKEN_WARNINGS="$TOKEN_WARNINGS$1
"
}

token_decode() {
  local token=$1 body pair k v ok=0
  TOKEN_WARNINGS=""
  case "$token" in
    omb1:*) body=${token#omb1:} ;;
    *)
      _tw "not an omarchy-bootstrap token (expected it to start with omb1:)"
      return 1
      ;;
  esac
  # Split on commas only: no filename expansion of a field such as '*'.
  local IFS=, glob_was_on=0
  case $- in *f*) ;; *) glob_was_on=1 && set -f ;; esac
  for pair in $body; do
    k=${pair%%=*}
    v=${pair#*=}
    [ "$pair" = "$k" ] && v=""
    case " $TOKEN_FIELDS " in
      *" $k "*) ;;
      *)
        _tw "ignored unknown field '$k'"
        continue
        ;;
    esac
    if ! cfg_field_ok "$k" "$v"; then
      _tw "ignored $k: '$v' is not a valid value"
      continue
    fi
    eval "CFG_$k=\$v"
    ok=$((ok + 1))
  done
  [ "$glob_was_on" = 1 ] && set +f
  [ "$ok" -gt 0 ]
}
