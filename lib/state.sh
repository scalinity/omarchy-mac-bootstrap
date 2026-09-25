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
  STATE_SYSTEM_FILE=/var/lib/omarchy-mac-bootstrap/state.env
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

cfg_load() {
  local k
  for k in $CFG_KEYS; do
    eval "CFG_$k=\$(state_get cfg_$k \"\${CFG_$k:-}\")"
  done
}

cfg_save() {
  local k v
  for k in $CFG_KEYS; do
    eval "v=\${CFG_$k:-}"
    [ -n "$v" ] && state_set "cfg_$k" "$v"
  done
  return 0
}

# Validators print the reason and return non-zero, for ui_ask.
valid_username() {
  case "$1" in
    root | '') printf '   %s\n' "Choose an everyday login other than root." ;;
    *) printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' && return 0
      printf '   %s\n' "Lowercase letters, digits, - and _, starting with a letter (Linux username rules)." ;;
  esac
  return 1
}

valid_hostname() {
  printf '%s' "$1" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$' && return 0
  printf '   %s\n' "Letters, digits and hyphens; not starting or ending with a hyphen; up to 63 characters."
  return 1
}

valid_keymap() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]{1,32}$' && return 0
  printf '   %s\n' "A console keymap name such as us, uk, de, fr, or dvorak."
  return 1
}

valid_tz() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$' && return 0
  printf '   %s\n' "An IANA timezone such as America/New_York or Europe/Berlin."
  return 1
}

valid_locale() {
  printf '%s' "$1" | grep -Eq '^[a-z]{2,3}(_[A-Z]{2})?\.UTF-8$' && return 0
  printf '   %s\n' "A UTF-8 locale such as en_US.UTF-8."
  return 1
}

valid_ghuser() {
  [ -z "$1" ] && return 0
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$' && return 0
  printf '   %s\n' "A GitHub username (letters, digits, hyphens), or leave empty."
  return 1
}

valid_bool() { case "$1" in 0 | 1) return 0 ;; esac; return 1; }
valid_gb() { case "$1" in '' | *[!0-9]*) return 1 ;; esac; return 0; }

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
  local IFS=,
  for pair in $body; do
    k=${pair%%=*}
    v=${pair#*=}
    [ "$pair" = "$k" ] && v=""
    case "$k" in
      enc | ssh) valid_bool "$v" >/dev/null || { _tw "ignored $k: expected 0 or 1"; continue; } ;;
      user) valid_username "$v" >/dev/null || { _tw "ignored user: '$v' is not a valid username"; continue; } ;;
      host) valid_hostname "$v" >/dev/null || { _tw "ignored host: '$v' is not a valid hostname"; continue; } ;;
      kmap) valid_keymap "$v" >/dev/null || { _tw "ignored kmap: '$v'"; continue; } ;;
      tz) valid_tz "$v" >/dev/null || { _tw "ignored tz: '$v'"; continue; } ;;
      loc) valid_locale "$v" >/dev/null || { _tw "ignored loc: '$v'"; continue; } ;;
      gh) valid_ghuser "$v" >/dev/null || { _tw "ignored gh: '$v'"; continue; } ;;
      linux) valid_gb "$v" || { _tw "ignored linux: '$v'"; continue; } ;;
      *)
        _tw "ignored unknown field '$k'"
        continue
        ;;
    esac
    eval "CFG_$k=\$v"
    ok=$((ok + 1))
  done
  [ "$ok" -gt 0 ]
}
