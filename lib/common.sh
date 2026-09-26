# shellcheck shell=bash
# Platform, the system seam, command execution, logging, and downloads.
#
# Every read of the machine goes through sys_cmd/sys_path so tests can replay a
# fixture instead; every command that changes the machine goes through run so
# dry-run and the test recorder can intercept it. Nothing else touches either.

OMB_VERSION="0.2.0"
OMB_DRY_RUN=${OMB_DRY_RUN:-0}
OMB_PHASE=${OMB_PHASE:-init}
# What this invocation may do, set once by the entrypoint from the command:
#   OMB_INTENT  act | plan | read — only "act" may reach run or a download.
#   OMB_PERSIST 1 | 0 — 0 for read-only commands and --dry-run: no state
#               directory, no state, no log, no retained download.
# Never read from the environment: a caller cannot widen what a command does.
OMB_INTENT=act
OMB_PERSIST=1
OMB_CMD=""

# ---------------------------------------------------------------------------
# The system seam
# ---------------------------------------------------------------------------

# sys_cmd NAME CMD [ARGS...]
# Runs a read-only probe and prints its stdout. With OMB_FIXTURE set, prints
# $OMB_FIXTURE/cmd/NAME instead and returns the code stored in NAME.rc
# (0 when absent); a missing fixture behaves like a missing command (127).
sys_cmd() {
  local name=$1
  shift
  if [ -n "${OMB_FIXTURE:-}" ]; then
    local f="$OMB_FIXTURE/cmd/$name"
    [ -f "$f" ] || return 127
    cat "$f"
    if [ -f "$f.rc" ]; then
      return "$(cat "$f.rc")"
    fi
    return 0
  fi
  "$@" 2>/dev/null
}

# sys_path /abs/path — where to read a system file (fixture root in tests).
sys_path() {
  if [ -n "${OMB_FIXTURE:-}" ]; then
    printf '%s/root%s' "$OMB_FIXTURE" "$1"
  else
    printf '%s' "$1"
  fi
}

# sys_has COMMAND — is a command available on this machine?
sys_has() {
  if [ -n "${OMB_FIXTURE:-}" ]; then
    grep -qx "$1" "$OMB_FIXTURE/commands" 2>/dev/null
    return
  fi
  command -v "$1" >/dev/null 2>&1
}

# sys_net KEY URL — fetch a small text resource and print it.
sys_net() {
  local key=$1 url=$2
  if [ -n "${OMB_FIXTURE:-}" ]; then
    [ -f "$OMB_FIXTURE/net/$key" ] || return 7
    cat "$OMB_FIXTURE/net/$key"
    return 0
  fi
  curl -fsSL --proto '=https' --tlsv1.2 --max-time 20 "$url" 2>/dev/null
}

# sys_reachable KEY URL — can we reach an HTTPS endpoint?
sys_reachable() {
  local key=$1 url=$2
  if [ -n "${OMB_FIXTURE:-}" ]; then
    [ -f "$OMB_FIXTURE/net/$key" ] || [ -f "$OMB_FIXTURE/net/$key.reachable" ]
    return
  fi
  curl -fsSI --proto '=https' --tlsv1.2 --max-time 8 "$url" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Platform
# ---------------------------------------------------------------------------

platform_init() {
  OMB_OS=$(sys_cmd uname_s uname -s)
  OMB_UID=$(sys_cmd id_u id -u)
  case "$OMB_OS" in
    Darwin) OMB_PLATFORM=macos ;;
    Linux) OMB_PLATFORM=linux ;;
    *) OMB_PLATFORM=other ;;
  esac
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_stamp() { date -u +%Y%m%dT%H%M%SZ; }

# ver_ge A B — is dotted version A >= B?
ver_ge() {
  local a=$1 b=$2 x y
  while [ -n "$a" ] || [ -n "$b" ]; do
    x=${a%%.*}
    y=${b%%.*}
    x=${x:-0}
    y=${y:-0}
    case "$x$y" in *[!0-9]*) return 1 ;; esac
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
    [ "$a" = "${a#*.}" ] && a="" || a=${a#*.}
    [ "$b" = "${b#*.}" ] && b="" || b=${b#*.}
  done
  return 0
}

quote_argv() {
  local out="" arg
  for arg in "$@"; do
    out="$out $(printf '%q' "$arg")"
  done
  printf '%s' "${out# }"
}

# Shorten $HOME to ~ for display.
tildify() {
  case "$1" in
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Logging — readable, timestamped, never given secrets. Values that look like
# credentials are masked anyway, as a last line of defence.
# ---------------------------------------------------------------------------

log_dir() { printf '%s/logs' "$OMB_STATE_DIR"; }
log_file() { printf '%s/omarchy-bootstrap-%s.log' "$(log_dir)" "$(date -u +%Y%m%d)"; }

# log_event LEVEL MESSAGE — appends to today's log. Read-only commands and
# dry runs keep no log: a preview leaves nothing behind.
log_event() {
  local level=$1 dir
  shift
  local msg="$*"
  [ "$OMB_PERSIST" = 1 ] && [ -n "${OMB_STATE_DIR:-}" ] || return 0
  state_dir_ready 2>/dev/null || return 0
  dir=$(log_dir)
  [ -L "$dir" ] && return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  [ -L "$(log_file)" ] && return 0
  msg=$(printf '%s' "$msg" | tr '\n' ' ' |
    sed -E -e 's/(bearer[[:space:]]+)[^[:space:]]+/\1[redacted]/Ig' \
      -e 's/((pass(word|phrase)?|secret|token|credential|api[_-]?key|authorization)[A-Za-z_-]*([=:]|[[:space:]])+)[^[:space:]]+/\1[redacted]/Ig')
  printf '%s [%s] %-6s %s\n' "$(now_utc)" "$OMB_PHASE" "$level" "$msg" >>"$(log_file)" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Execution — the only path to a command that changes the machine.
# ---------------------------------------------------------------------------

# run CMD [ARGS...]
#   dry-run         → print "would run", execute nothing
#   OMB_TEST_RECORD → append argv to that file, execute nothing
#   otherwise       → execute in the foreground on the user's terminal
# Upstream output is never captured, so nothing typed into it can be logged.
run() {
  local argv
  argv=$(quote_argv "$@")
  # plan, status, doctor, sources and logs never change the machine. Reaching
  # here from one of them is a routing mistake; refuse instead of trusting it.
  if [ "$OMB_INTENT" != act ]; then
    log_event refuse "'${OMB_CMD:-this command}' does not execute: $argv"
    ui_fail "Refused: '${OMB_CMD:-this command}' never changes the machine (it reached: $argv)."
    return 1
  fi
  if [ "$OMB_DRY_RUN" = 1 ]; then
    log_event dryrun "$argv"
    ui_would "$argv"
    return 0
  fi
  log_event exec "$argv"
  if [ -n "${OMB_TEST_RECORD:-}" ]; then
    printf '%s\n' "$argv" >>"$OMB_TEST_RECORD"
    log_event exit "0 (recorded by test harness, not executed)"
    # sudo -v only refreshes sudo's credentials: the machine after it is the
    # machine before it, so a test's changed machine and exit status belong
    # to the command that follows.
    [ "$argv" = "sudo -v" ] && return 0
    # A test may say what the machine looks like once a recorded command
    # "ran", so the checks that follow it read a changed machine.
    [ -n "${OMB_TEST_AFTER:-}" ] && OMB_FIXTURE=$OMB_TEST_AFTER
    return "${OMB_TEST_RC:-0}"
  fi
  # A fixture describes some other machine; executing for real against it is
  # never right.
  if [ -n "${OMB_FIXTURE:-}" ]; then
    log_event refuse "fixture mode does not execute: $argv"
    ui_fail "Fixture mode never executes commands; use --dry-run."
    return 1
  fi
  OMB_RUNNING=$argv
  "$@"
  local rc=$?
  OMB_RUNNING=""
  log_event exit "$rc"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Downloads with provenance
# ---------------------------------------------------------------------------

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# sha256_str TEXT — the SHA-256 of a string, lowercase hex.
sha256_str() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

# omb_tmp_init — this run's private scratch directory ($OMB_TMP), created on
# first use in the current shell and removed by omb_cleanup when the run ends.
omb_tmp_init() {
  [ -n "${OMB_TMP:-}" ] && [ -d "$OMB_TMP" ] && return 0
  OMB_TMP=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-bootstrap.XXXXXX") || return 1
}

# omb_cleanup — on exit: drop the scratch directory and release our lock.
omb_cleanup() {
  case "${OMB_TMP:-}" in
    */omarchy-bootstrap.*) rm -rf "$OMB_TMP" ;;
  esac
  state_unlock
}

# fetch_upstream KEY URL
# Downloads URL and sets FETCH_PATH, FETCH_URL, FETCH_AT, FETCH_SIZE,
# FETCH_SHA256. A real run keeps the file in the state directory's downloads/
# for provenance; a dry run downloads into the scratch directory, which is
# removed on exit — seeing the fingerprint is the point, keeping it is not.
fetch_upstream() {
  local key=$1 url=$2 dir
  [ "$OMB_INTENT" = act ] || return 1
  if [ "$OMB_PERSIST" = 1 ]; then
    state_dir_ready || return 1
    dir="$OMB_STATE_DIR/downloads"
    [ -L "$dir" ] && return 1
    # Private: nothing else on the machine may swap a script between its
    # fingerprint and its execution.
    (umask 077 && mkdir -p "$dir") || return 1
    chmod 700 "$dir" 2>/dev/null
  else
    omb_tmp_init || return 1
    dir=$OMB_TMP
  fi
  FETCH_URL=$url
  FETCH_AT=$(now_utc)
  FETCH_PATH=$(mktemp "$dir/$key-$(now_stamp).XXXXXX") || return 1
  if [ -n "${OMB_FIXTURE:-}" ]; then
    [ -f "$OMB_FIXTURE/net/$key" ] || {
      rm -f "$FETCH_PATH"
      return 7
    }
    cp "$OMB_FIXTURE/net/$key" "$FETCH_PATH" || return 1
  else
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 -o "$FETCH_PATH" "$url" || {
      rm -f "$FETCH_PATH"
      return 7
    }
  fi
  FETCH_SIZE=$(wc -c <"$FETCH_PATH" | tr -d ' ')
  FETCH_SHA256=$(sha256_of "$FETCH_PATH")
  log_event fetch "$url → $(tildify "$FETCH_PATH") size=$FETCH_SIZE sha256=$FETCH_SHA256"
  return 0
}

# fetch_unchanged — is FETCH_PATH still the file that was fingerprinted? The
# inspection pager can open an editor, so the check runs right before execution.
fetch_unchanged() {
  [ "$(sha256_of "$FETCH_PATH")" = "$FETCH_SHA256" ] && return 0
  log_event refuse "$FETCH_PATH changed after download (expected sha256 $FETCH_SHA256)"
  ui_fail "$(tildify "$FETCH_PATH") changed after it was fingerprinted; nothing was run."
  return 1
}

# show_provenance — where the last download came from, and what it is.
show_provenance() {
  ui_kv "URL" "$FETCH_URL"
  ui_kv "Downloaded" "$FETCH_AT"
  ui_kv "Size" "$FETCH_SIZE bytes"
  ui_kv "SHA-256" "$FETCH_SHA256"
  ui_kv "Saved to" "$(tildify "$FETCH_PATH")"
}

# view_file PATH — page a file for inspection. Control characters are made
# visible (cat -v), so a script cannot hide lines with terminal escapes, and
# the pager reads a pipe, so its edit command cannot change the file on disk.
view_file() {
  if [ -n "${PAGER:-}" ]; then
    cat -v "$1" | $PAGER
  elif command -v less >/dev/null 2>&1; then
    cat -v "$1" | less
  elif command -v more >/dev/null 2>&1; then
    cat -v "$1" | more
  else
    cat -v "$1"
  fi
}

# offer_inspection — offer to read FETCH_PATH before it runs. Returns 0 to
# continue, 3 when the user quits.
offer_inspection() {
  ui_yesno "Inspect the script before running it?" n
  case $? in
    0) view_file "$FETCH_PATH" ;;
    3) return 3 ;;
  esac
  return 0
}

# clean_version — first line of stdin reduced to version characters, so text
# from the network never carries control codes to the terminal or state.
clean_version() { head -1 | tr -cd '[:alnum:]._-'; }
