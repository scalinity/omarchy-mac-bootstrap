# shellcheck shell=bash
# Persistent, non-secret progress: state.env (key=value, parsed, never sourced)
# and the resume token that carries Phase 1 choices across the reboot.

STATE_SYSTEM_DIR=/var/lib/omarchy-mac-bootstrap

# state_init — works out where state lives; creates nothing. The directory is
# made on the first write (state_dir_ready), so a read-only command or a dry
# run never leaves one behind.
state_init() {
  if [ -z "${OMB_STATE_DIR:-}" ]; then
    if [ "$OMB_PLATFORM" = linux ] && [ "$OMB_UID" = 0 ]; then
      OMB_STATE_DIR=$STATE_SYSTEM_DIR
    else
      OMB_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-mac-bootstrap"
    fi
  fi
  case "$OMB_STATE_DIR" in
    /*) ;;
    *)
      _state_refuse "OMB_STATE_DIR must be an absolute path, not '$OMB_STATE_DIR'."
      return 1
      ;;
  esac
  case "$OMB_STATE_DIR/" in
    */../* | */./*)
      _state_refuse "OMB_STATE_DIR must not contain . or .. components."
      return 1
      ;;
  esac
  STATE_FILE="$OMB_STATE_DIR/state.env"
  # The record a root run of Phase 2 leaves for the later non-root run.
  STATE_SYSTEM_FILE=$(sys_path "$STATE_SYSTEM_DIR/state.env")
  # Root's Phase 2 record must stay readable by the everyday user's later
  # run; everything else is private.
  if [ "$OMB_STATE_DIR" = "$STATE_SYSTEM_DIR" ]; then
    STATE_DIR_MODE=755 STATE_FILE_MODE=644
  else
    STATE_DIR_MODE=700 STATE_FILE_MODE=600
  fi
  STATE_DIR_OK="" STATE_DIR_WARNED=""
  return 0
}

_state_refuse() {
  if [ -z "${STATE_DIR_WARNED:-}" ]; then
    ui_fail "$1"
    STATE_DIR_WARNED=1
  fi
}

# _state_owned_safe PATH — owned by us or by root, and writable by nobody
# else. What a state file or directory must be before it is trusted.
_state_owned_safe() {
  [ -n "$(find "$1" -maxdepth 0 \( -user "$(id -u)" -o -user 0 \) ! -perm -020 ! -perm -002 2>/dev/null)" ]
}

# state_dir_ready — the state directory exists (created here, private), is a
# real directory rather than a symlink, is owned by this user and is not
# writable by anyone else. Checked once per run, before the first write.
state_dir_ready() {
  [ "$STATE_DIR_OK" = 1 ] && return 0
  [ "$OMB_PERSIST" = 1 ] || return 1
  local d=$OMB_STATE_DIR why=""
  if [ -L "$d" ]; then
    why="is a symbolic link"
  elif [ ! -e "$d" ]; then
    if (umask 077 && mkdir -p "$d") 2>/dev/null; then
      chmod "$STATE_DIR_MODE" "$d"
    else
      why="cannot be created"
    fi
  fi
  if [ -z "$why" ]; then
    if [ ! -d "$d" ]; then
      why="is not a directory"
    elif [ ! -O "$d" ]; then
      why="is owned by another user"
    elif ! _state_owned_safe "$d"; then
      why="is writable by other users"
    fi
  fi
  if [ -n "$why" ]; then
    _state_refuse "The state directory $(tildify "$d") $why; nothing will be recorded there, and nothing that needs a record will run."
    return 1
  fi
  STATE_DIR_OK=1
}

# _state_file_ok FILE — a state file is read only when it is a regular file
# (not a symlink) owned by this user or root and writable by no one else.
_state_file_ok() {
  [ -f "$1" ] && [ ! -L "$1" ] && _state_owned_safe "$1"
}

# state_get KEY [DEFAULT] [FILE]
state_get() {
  local file=${3:-$STATE_FILE} v
  if _state_file_ok "$file"; then
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

# _state_rewrite KEY [VALUE] — the one writer: every line except KEY's, plus
# KEY=VALUE when a value is given, into a unique temporary file beside
# state.env, then renamed over it. Returns non-zero, leaving state.env as it
# was, if any step fails (full disk, permissions, a swapped file).
_state_rewrite() {
  local key=$1 tmp
  state_dir_ready || return 1
  if [ -e "$STATE_FILE" ] && ! _state_file_ok "$STATE_FILE"; then
    _state_refuse "$(tildify "$STATE_FILE") is not a plain file owned by you; refusing to rewrite it."
    return 1
  fi
  tmp=$(mktemp "$OMB_STATE_DIR/.state.env.XXXXXX") || return 1
  if {
    if [ -f "$STATE_FILE" ]; then
      grep -v "^$key=" "$STATE_FILE" || [ $? = 1 ]
    fi &&
      if [ $# -gt 1 ]; then printf '%s=%s\n' "$key" "$2"; fi
  } >"$tmp" && chmod "$STATE_FILE_MODE" "$tmp" && mv -f "$tmp" "$STATE_FILE"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# state_put_file NAME CONTENT — a whole file in the state directory, written
# the same way as state.env: a unique temporary file, renamed into place.
# Returns non-zero, leaving any old file untouched, when that fails. A
# non-recording run writes nothing (0).
state_put_file() {
  local path="$OMB_STATE_DIR/$1" tmp
  [ "$OMB_PERSIST" = 1 ] || return 0
  state_dir_ready || return 1
  if [ -e "$path" ] && ! _state_file_ok "$path"; then
    _state_refuse "$(tildify "$path") is not a plain file owned by you; refusing to rewrite it."
    return 1
  fi
  tmp=$(mktemp "$OMB_STATE_DIR/.$1.XXXXXX") || return 1
  if printf '%s\n' "$2" >"$tmp" && chmod "$STATE_FILE_MODE" "$tmp" && mv -f "$tmp" "$path"; then
    log_event record "wrote $1"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# state_remove_file NAME — remove a file of our own from the state directory.
state_remove_file() {
  local path="$OMB_STATE_DIR/$1"
  [ "$OMB_PERSIST" = 1 ] || return 0
  [ -e "$path" ] || return 0
  _state_file_ok "$path" || return 1
  rm -f "$path" && log_event record "removed $1"
}

# state_set KEY VALUE — atomic, checked rewrite. Returns non-zero when the
# value could not be recorded; a caller about to do something irreversible
# must stop on that. Read-only commands and dry runs record nothing (0).
state_set() {
  local key=$1 value=$2
  if ! state_key_allowed "$key"; then
    log_event refuse "state key '$key' is not allowed"
    return 1
  fi
  value=$(printf '%s' "$value" | tr -d '\r\n')
  [ "$OMB_PERSIST" = 1 ] || return 0
  if ! _state_rewrite "$key" "$value"; then
    log_event refuse "could not record $key"
    return 1
  fi
  log_event record "$key=$value"
}

state_stamp() { state_set "$1" "$(now_utc)"; }

# state_must_set KEY VALUE — for the record written just before something
# irreversible. If it cannot be written, say so and return 1: the caller
# stops, because a change the tool cannot record is one it cannot reconcile
# afterwards. (A dry run records nothing and succeeds.)
state_must_set() {
  state_set "$1" "$2" && return 0
  ui_fail "Could not record $1 in $(tildify "$OMB_STATE_DIR"); stopping before anything changes."
  return 1
}

state_unset() {
  [ "$OMB_PERSIST" = 1 ] || return 0
  [ -f "$STATE_FILE" ] || return 0
  _state_rewrite "$1"
}

# ---------------------------------------------------------------------------
# One run at a time. Any run that records state takes the lock for its whole
# life; a second run stops instead of interleaving writes or launching an
# installer twice. A lock left by a run that no longer exists is cleared.
# ---------------------------------------------------------------------------

STATE_LOCK_HELD=0

# _proc_started PID — when that process started, whitespace squeezed so the
# recorded and the live value compare exactly.
_proc_started() { ps -p "$1" -o lstart= 2>/dev/null | awk '{$1 = $1; print}'; }

state_lock() {
  local l="$OMB_STATE_DIR/lock" pid since started live=0 junk p2 s2
  state_dir_ready || return 1
  if ! mkdir "$l" 2>/dev/null; then
    [ -L "$l" ] && {
      _state_refuse "$(tildify "$l") is a symbolic link; refusing to continue."
      return 1
    }
    read -r pid since started 2>/dev/null <"$l/owner"
    case "${pid:-}" in '' | *[!0-9]*) pid="" ;; esac
    # The owner is alive only if that pid is still the process that took the
    # lock: same start time, or (an owner recorded without one) still this tool.
    if [ -n "$pid" ] && [ -n "${started:-}" ]; then
      [ "$(_proc_started "$pid")" = "$started" ] && live=1
    elif [ -n "$pid" ]; then
      case "$(ps -p "$pid" -o command= 2>/dev/null)" in *omarchy-bootstrap*) live=1 ;; esac
    fi
    if [ "$live" = 1 ]; then
      ui_fail "Another omarchy-bootstrap run (pid $pid, since ${since:-?}) is using $(tildify "$OMB_STATE_DIR"). Let it finish first."
      return 1
    fi
    # An owner that never got recorded may be a run starting right now: only
    # a lock older than a minute counts as abandoned then.
    if [ -z "$pid" ] && [ -z "$(find "$l" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      ui_fail "Another omarchy-bootstrap run is starting. Try again in a minute."
      return 1
    fi
    # Move it aside before removing it, and remove it only if it is still the
    # abandoned lock judged above; a run that took the lock meanwhile keeps it.
    junk="$l.stale.$$"
    if mv "$l" "$junk" 2>/dev/null; then
      p2="" s2=""
      read -r p2 s2 _ 2>/dev/null <"$junk/owner"
      if [ "${p2:-}" != "${pid:-}" ] || [ "${s2:-}" != "${since:-}" ] ||
        { [ -z "$pid" ] && [ -z "$(find "$junk" -maxdepth 0 -mmin +1 2>/dev/null)" ]; }; then
        mv "$junk" "$l" 2>/dev/null
        ui_fail "Another omarchy-bootstrap run just took the lock in $(tildify "$OMB_STATE_DIR"). Let it finish first."
        return 1
      fi
      log_event lock "cleared a lock left by a run that is no longer running (pid ${pid:-unknown})"
      rm -rf "$junk"
    fi
    mkdir "$l" 2>/dev/null || {
      ui_fail "Could not take the lock in $(tildify "$OMB_STATE_DIR")."
      return 1
    }
  fi
  printf '%s %s %s\n' "$$" "$(now_utc)" "$(_proc_started "$$")" >"$l/owner" || return 1
  STATE_LOCK_HELD=1
}

state_unlock() {
  [ "$STATE_LOCK_HELD" = 1 ] || return 0
  local pid=""
  read -r pid _ 2>/dev/null <"$OMB_STATE_DIR/lock/owner"
  [ "$pid" = "$$" ] && rm -rf "$OMB_STATE_DIR/lock"
  STATE_LOCK_HELD=0
}

# ---------------------------------------------------------------------------
# Choices — the non-secret answers that shape both phases. Held in CFG_*
# globals during a run; persisted with cfg_save.
# ---------------------------------------------------------------------------

CFG_KEYS="enc user host kmap tz loc ssh gh linux shared dev plan"

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

valid_bool() {
  case "$1" in 0 | 1) return 0 ;; esac
  printf '   %s\n' "0 or 1."
  return 1
}
# valid_gb — a whole number of GB in canonical form: digits, no leading zero,
# at most seven digits. Saved and token values reach shell arithmetic, where
# a leading zero means octal.
valid_gb() {
  _whole "$1" '^(0|[1-9][0-9]{0,6})$' && return 0
  printf '   %s\n' "A whole number of GB, such as 32."
  return 1
}

# valid_digest8 — the short plan digest a Shared plan is known by.
valid_digest8() {
  _whole "$1" '^[0-9a-f]{8}$' && return 0
  printf '   %s\n' "Eight lowercase hex digits."
  return 1
}

# ask_encrypt — the encryption question both phases ask. 0 answered, 3 quit.
ask_encrypt() {
  printf '   %sEncrypt Linux root?%s\n' "$C_BOLD" "$C_RESET"
  ui_note "Recommended for a laptop. You will enter a disk passphrase during the Omarchy Mac migration flow. The bootstrap never stores this passphrase."
  ui_yesno "Encrypt" "$([ "${CFG_enc:-1}" = 0 ] && echo n || echo y)"
  case $? in
    0) CFG_enc=1 ;;
    3) return 3 ;;
    *) CFG_enc=0 ;;
  esac
  return 0
}

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
    plan) valid_digest8 "$2" ;;
    *) return 2 ;;
  esac >/dev/null
}

# ---------------------------------------------------------------------------
# Resume token — readable, hand-typeable, whitelisted fields only.
#   omb2:enc=1,user=alex,host=m1pro,kmap=us,tz=America/New_York,...,shared=150,dev=1,plan=1a2b3c4d
# Version 1 tokens (omb1:, without shared/dev/plan) are still read.
# ---------------------------------------------------------------------------

TOKEN_FIELDS="enc user host kmap tz loc ssh gh linux shared dev plan"

token_encode() {
  local out="omb2:" k v sep=""
  for k in $TOKEN_FIELDS; do
    eval "v=\${CFG_$k:-}"
    [ -n "$v" ] || continue
    # Typed by hand after the reboot: a default of no Shared storage is left out.
    [ "$k" = shared ] && [ "$v" = 0 ] && continue
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
    omb2:*) body=${token#omb2:} ;;
    omb1:*) body=${token#omb1:} ;;
    *)
      _tw "not an omarchy-bootstrap token (expected it to start with omb2:)"
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
