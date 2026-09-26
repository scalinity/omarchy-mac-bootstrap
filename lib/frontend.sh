# shellcheck shell=bash
# The launcher's side of the frontend (docs/FRONTEND.md → *Distribution and
# provenance*, *Intent and persistence*; docs/PROTOCOL.md → §3, *The session
# scratch*): the reviewed lock, the cache, the digest checked on every launch,
# acquisition in act sessions only, the development override (fixture mode
# only), the session scratch with its owner cleanup and its stale reclaim, and
# the fall back to the text interface for every failure.
#
# The frontend is started only from here. Nothing in this file decides what
# the machine is or what may be done to it; that is the core's.
#
# Needs lib/common.sh, lib/state.sh, lib/ui.sh, lib/records.sh, lib/core.sh.

FE_STATE="" FE_WHY="" FE_BIN="" FE_SHA="" FE_FPID="" FE_PAUSE=""

# The scopes a default-command session carries (SPEC.md → Commands).
FE_ALL_SCOPES="journey,disk,plan,profile,resolve,asahi,network,omarchy,shared,export,restore,rescue,qualify,debug"

# fe_target — FE_TARGET: this host's frontend build. The binary runs here,
# whatever machine a fixture describes, so the host itself is asked.
fe_target() {
  FE_TARGET=""
  case "$(uname -s 2>/dev/null):$(uname -m 2>/dev/null)" in
    Darwin:arm64) FE_TARGET=aarch64-apple-darwin ;;
    Linux:aarch64) FE_TARGET=aarch64-unknown-linux-gnu ;;
  esac
  [ -n "$FE_TARGET" ]
}

# fe_lock_read — the reviewed lock's pins for this host: FE_VERSION,
# FE_PROTO, FE_URL, FE_SIZE, FE_SHA. 1 with FE_WHY when there is none.
fe_lock_read() {
  local lock=$OMB_HOME/release/frontend.lock i
  FE_VERSION="" FE_PROTO="" FE_URL="" FE_SIZE="" FE_SHA=""
  if ! fe_target; then
    FE_WHY="no frontend is built for this system ($(uname -s 2>/dev/null) $(uname -m 2>/dev/null))"
    return 1
  fi
  if [ ! -f "$lock" ]; then
    FE_WHY="this checkout pins no frontend release (release/frontend.lock is absent)"
    return 1
  fi
  if ! rec_admit_file lock - "$lock"; then
    FE_WHY="release/frontend.lock is not admissible ($REC_REASON)"
    return 1
  fi
  rec_find frontend
  FE_VERSION=$(rec_get "$REC_AT_I" version) FE_PROTO=$(rec_get "$REC_AT_I" proto)
  i=0
  while [ "$i" -lt "$REC_N" ]; do
    if [ "${REC_T[i]}" = artifact ] && [ "$(rec_get "$i" target)" = "$FE_TARGET" ]; then
      FE_URL=$(rec_get "$i" url) FE_SIZE=$(rec_get "$i" size) FE_SHA=$(rec_get "$i" sha256)
    fi
    i=$((i + 1))
  done
  if [ -z "$FE_SHA" ]; then
    FE_WHY="the lock pins no frontend for $FE_TARGET"
    return 1
  fi
  if [ "$FE_PROTO" != "$REC_PROTO" ]; then
    FE_WHY="the lock's frontend speaks protocol $FE_PROTO, this core $REC_PROTO"
    return 1
  fi
}

# fe_cache_root — FE_CACHE: this user's frontend cache (root's on Linux as
# root), and FE_ROOT_CACHE: root's, which an everyday user may start from.
fe_cache_root() {
  FE_ROOT_CACHE=$(sys_path /var/cache/omarchy-mac-bootstrap/frontend)
  if [ "$OMB_PLATFORM" = linux ] && [ "$OMB_UID" = 0 ]; then
    FE_CACHE=$FE_ROOT_CACHE
  else
    FE_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-mac-bootstrap/frontend
  fi
}

# _fe_safe PATH — a real (not linked) path owned by this user or root and
# writable by no one else: checked like the state directory.
_fe_safe() {
  [ -e "$1" ] && [ ! -L "$1" ] && _state_owned_safe "$1"
}

# fe_digest FILE — FE_GOT_SHA and FE_GOT_SIZE of FILE.
fe_digest() {
  FE_GOT_SHA="" FE_GOT_SIZE=""
  _core_size "$1" || return 1
  FE_GOT_SIZE=$CORE_SIZE
  FE_GOT_SHA=$(sha256_of "$1") || return 1
  _whole "$FE_GOT_SHA" '^[0-9a-f]{64}$'
}

# fe_verified FILE — FILE is the pinned bytes: its size and SHA-256 are the
# lock's. Checked on every launch, never trusted from a name.
fe_verified() {
  [ -f "$1" ] && [ ! -L "$1" ] && _state_owned_safe "$1" || return 1
  fe_digest "$1" || return 1
  [ "$FE_GOT_SIZE" = "$FE_SIZE" ] && [ "$FE_GOT_SHA" = "$FE_SHA" ]
}

# fe_find_cached — FE_BIN: a cached binary with the pinned digest (this
# user's cache, then root's); FE_BAD: a cached file under that digest's name
# whose bytes are not the pinned ones.
fe_find_cached() {
  local d f
  FE_BIN="" FE_BAD=""
  fe_cache_root
  for d in "$FE_CACHE" "$FE_ROOT_CACHE"; do
    f=$d/$FE_SHA/omb-tui
    [ -e "$f" ] || [ -L "$f" ] || continue
    if _fe_safe "$d" && _fe_safe "$d/$FE_SHA" && fe_verified "$f"; then
      FE_BIN=$f
      return 0
    fi
    [ "$d" = "$FE_CACHE" ] && FE_BAD=$f
  done
  return 1
}

# fe_fetch DEST — download the pinned artifact into DEST (in fixture mode,
# the fixture's net/frontend-TARGET), then hold it to the lock's size and
# SHA-256. Nothing is kept from a download that fails any of it.
fe_fetch() {
  local dest=$1 st
  if [ -n "${OMB_FIXTURE:-}" ]; then
    if [ ! -f "$OMB_FIXTURE/net/frontend-$FE_TARGET" ]; then
      FE_WHY="the download failed (no network): $FE_URL"
      return 1
    fi
    cp "$OMB_FIXTURE/net/frontend-$FE_TARGET" "$dest" 2>/dev/null
    st=$?
  else
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 -o "$dest" "$FE_URL" 2>/dev/null
    st=$?
  fi
  if [ "$st" != 0 ]; then
    rm -f "$dest"
    FE_WHY="the download failed (status $st): $FE_URL"
    return 1
  fi
  if ! fe_digest "$dest"; then
    rm -f "$dest"
    FE_WHY="the download could not be read back"
    return 1
  fi
  if [ "$FE_GOT_SIZE" != "$FE_SIZE" ]; then
    rm -f "$dest"
    FE_WHY="the download is $FE_GOT_SIZE bytes, not the $FE_SIZE the lock pins (partial or replaced): $FE_URL"
    return 1
  fi
  if [ "$FE_GOT_SHA" != "$FE_SHA" ]; then
    rm -f "$dest"
    FE_STATE=mismatch
    FE_WHY="the download's SHA-256 is $FE_GOT_SHA, not the $FE_SHA the lock pins: $FE_URL"
    return 1
  fi
  chmod 700 "$dest"
}

# fe_acquire INTENT — make a verified binary available for INTENT (act:
# into the cache, after [Y/n]; dry-run: into the per-run scratch, kept
# nowhere). FE_BIN on success.
fe_acquire() {
  local intent=$1 dir tmp
  ui_section "The interface" "a one-time download, checked against this checkout's lock"
  ui_kv "URL" "$FE_URL"
  ui_kv "Version" "$FE_VERSION ($FE_TARGET)"
  ui_kv "Size" "$FE_SIZE bytes"
  ui_kv "SHA-256" "$FE_SHA"
  ui_yesno "Download and check it now?" y
  case $? in
    0) ;;
    *)
      FE_WHY="the interface was not downloaded"
      return 1
      ;;
  esac
  if [ "$intent" = dry-run ]; then
    omb_tmp_init || return 1
    dir=$OMB_TMP/frontend
    (umask 077 && mkdir -p "$dir") || return 1
    fe_fetch "$dir/omb-tui" || return 1
    FE_BIN=$dir/omb-tui
    return 0
  fi
  fe_cache_root
  dir=$FE_CACHE/$FE_SHA
  if [ -L "$FE_CACHE" ] || [ -L "$dir" ]; then
    FE_WHY="the frontend cache is a symbolic link; nothing was downloaded"
    return 1
  fi
  (umask 077 && mkdir -p "$dir") || {
    FE_WHY="the frontend cache $(tildify "$FE_CACHE") cannot be created"
    return 1
  }
  if ! _fe_safe "$FE_CACHE" || ! _fe_safe "$dir"; then
    FE_WHY="the frontend cache $(tildify "$FE_CACHE") is not private to this user"
    return 1
  fi
  tmp=$(mktemp "$dir/.omb-tui.XXXXXX") || return 1
  fe_fetch "$tmp" || return 1
  mv -f "$tmp" "$dir/omb-tui" || { rm -f "$tmp"; return 1; }
  FE_BIN=$dir/omb-tui
  log_event frontend "acquired $FE_URL sha256=$FE_SHA"
}

# fe_select INTENT — decide which frontend binary may start for a session of
# INTENT (act, plan or dry-run), following docs/FRONTEND.md → *Intent and
# persistence*. FE_BIN and FE_STATE on success; FE_STATE and FE_WHY otherwise.
fe_select() {
  local intent=$1 aside
  FE_BIN="" FE_STATE="" FE_WHY="" FE_DEV=0
  # The development override: an unreleased build, only against fixtures,
  # never as root (the entrypoint refuses it otherwise; checked again here).
  if [ -n "${OMB_FRONTEND_DEV:-}" ]; then
    if [ -z "${OMB_FIXTURE:-}" ] || [ "$(id -u)" = 0 ]; then
      FE_STATE=missing FE_WHY="OMB_FRONTEND_DEV works only in fixture mode, never as root"
      return 1
    fi
    if [ ! -f "$OMB_FRONTEND_DEV" ] || [ ! -x "$OMB_FRONTEND_DEV" ]; then
      FE_STATE=unrunnable FE_WHY="OMB_FRONTEND_DEV does not name an executable file"
      return 1
    fi
    FE_BIN=$OMB_FRONTEND_DEV FE_STATE=verified FE_DEV=1
    return 0
  fi
  if ! fe_lock_read; then
    FE_STATE=missing
    return 1
  fi
  if fe_find_cached; then
    FE_STATE=verified
    return 0
  fi
  if [ -n "$FE_BAD" ]; then
    FE_STATE=mismatch
    FE_WHY="the cached frontend $(tildify "$FE_BAD") is not the pinned bytes (SHA-256 ${FE_GOT_SHA:-unreadable}, expected $FE_SHA)"
    [ "$intent" = act ] || return 1
    # Only an act session moves it aside, after a yes.
    ui_warn "$FE_WHY"
    if ! ui_yesno "Move it aside and download the pinned one again?" y; then return 1; fi
    aside="$FE_BAD.mismatch-$(now_stamp)"
    mv -f "$FE_BAD" "$aside" || return 1
    log_event frontend "moved a mismatching cached frontend aside: $aside"
    FE_STATE=""
  fi
  case "$intent" in
    act | dry-run)
      if fe_acquire "$intent"; then
        FE_STATE=verified
        return 0
      fi
      FE_STATE=${FE_STATE:-missing}
      [ "$FE_STATE" = verified ] && FE_STATE=missing
      return 1
      ;;
    *)
      FE_STATE=missing
      FE_WHY="the interface is not downloaded yet; the default run (./omarchy-bootstrap) sets it up"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# The session scratch (docs/PROTOCOL.md → *The session scratch*)
# ---------------------------------------------------------------------------

# fe_ops_name DIR — does an unresolved operation record name the session DIR?
# 0 yes, 1 no, 2 unknown (a record that cannot be read counts as naming it).
fe_ops_name() {
  local f
  [ -d "$OMB_STATE_DIR/ops" ] || return 1
  for f in "$OMB_STATE_DIR"/ops/*.omb; do
    [ -e "$f" ] || continue
    rec_admit_file op - "$f" || return 2
    [ "$(rec_get 0 session)" = "$1" ] && return 0
  done
  return 1
}

# fe_scratch_idle DIR — every recorded core and worker of the session DIR is
# dead: 0 yes, 1 a live one, 2 one whose identity cannot be established.
fe_scratch_idle() {
  local f
  for f in "$1"/req-*.core "$1"/req-*.worker-*; do
    [ -e "$f" ] || continue
    # core_file_alive: 0 alive, 1 not alive, 2 cannot be established.
    core_file_alive "$f"
    case $? in
      1) ;;
      0) return 1 ;;
      *) return 2 ;;
    esac
  done
  return 0
}

# fe_session_create — the session's private scratch, launcher.omb (with the
# group snapshot L's own cleanup is judged against) and session.diag-summary.
fe_session_create() {
  local d
  core_boot_read
  d=$(mktemp -d "${TMPDIR:-/tmp}/omb-session.XXXXXX") || return 1
  chmod 700 "$d" || return 1
  if ! core_group_snapshot || ! core_proc_write "$d/launcher.omb" launcher "$$"; then
    rm -rf "$d"
    return 1
  fi
  FE_SNAP=$CORE_SNAP FE_PGID=$CORE_PGID
  (umask 077 && printf '%-127s\n' "diagnostics truncated: children not kept 0000000000, bytes discarded at least 0000000000" >"$d/session.diag-summary") || {
    rm -rf "$d"
    return 1
  }
  FE_SESSION=$d
}

# fe_owner_cleanup — the launcher, alive and exempt from its own check,
# removes its own scratch only when its frontend is gone (waited for), no
# core or worker it recorded is alive, no process that joined the group after
# launcher.omb remains (other than itself and the reading's own), and no
# unresolved operation names the session. Otherwise the scratch stays for a
# later launcher. Every identity that cannot be established counts as alive.
fe_owner_cleanup() {
  local d=$FE_SESSION
  case "$d" in */omb-session.*) ;; *) return 1 ;; esac
  [ -d "$d" ] || return 0
  fe_scratch_idle "$d" || return 1
  CORE_SNAP=$FE_SNAP CORE_PGID=$FE_PGID
  core_workers_present || return 1
  [ -z "$CORE_PRESENT" ] || return 1
  fe_ops_name "$d"
  [ $? = 1 ] || return 1
  rm -rf "$d"
}

# fe_reclaim — remove abandoned sessions of this user. A later launcher has
# no exemption: every recorded identity must be established and dead, no
# live process may name the folder in its arguments (a frontend started
# before frontend.omb existed), and no unresolved operation may name it.
fe_reclaim() {
  local d args
  omb_tmp_init || return 0
  # Every identity is judged in this boot session (none can be established
  # without it, and then nothing is removed).
  core_boot_read
  args=$OMB_TMP/ps-args
  ps -axo args= >"$args" 2>/dev/null || return 0
  [ -s "$args" ] || return 0
  for d in "${TMPDIR:-/tmp}"/omb-session.*; do
    if [ ! -d "$d" ] || [ -L "$d" ] || [ ! -O "$d" ]; then continue; fi
    [ "$d" = "${FE_SESSION:-}" ] && continue
    # The launcher: recorded, readable and dead. A missing identity cannot be
    # established, and so counts as alive.
    [ -f "$d/launcher.omb" ] || continue
    core_file_alive "$d/launcher.omb"
    [ $? = 1 ] || continue
    if [ -e "$d/frontend.omb" ]; then
      core_file_alive "$d/frontend.omb"
      [ $? = 1 ] || continue
    fi
    grep -qF -- "--session $d" "$args" && continue
    fe_scratch_idle "$d" || continue
    fe_ops_name "$d"
    [ $? = 1 ] || continue
    rm -rf "$d"
    log_event frontend "reclaimed an abandoned session scratch"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Starting the frontend
# ---------------------------------------------------------------------------

fe_on_signal() { :; }

# fe_wait_cores DIR — wait while a core or worker recorded in the session DIR
# still runs, for up to an hour, starting no process: the launcher shares the
# group, and a process joining it while a core supervises a child is counted
# by that core as a worker (docs/PROTOCOL.md → worker quiescence). So the
# PIDs are read with builtins and asked with kill -0, and each pause is
# `read -t` on FE_PAUSE. A reused PID only makes the wait longer; the
# identities are judged in full afterwards (fe_owner_cleanup).
fe_wait_cores() {
  local f line pid live n=0
  if [ -n "$FE_PAUSE" ] && [ -p "$FE_PAUSE" ]; then
    exec 9<>"$FE_PAUSE"
  else
    FE_PAUSE=""
  fi
  while [ "$n" -lt 3600 ]; do
    live=0
    for f in "$1"/req-*.core "$1"/req-*.worker-*; do
      [ -f "$f" ] || continue
      pid=""
      while IFS= read -r line; do
        case "$line" in
          "proc	"*)
            pid=${line#*	pid=}
            pid=${pid%%	*}
            ;;
        esac
      done <"$f"
      case "$pid" in '' | *[!0-9]*) ;; *) kill -0 "$pid" 2>/dev/null && live=1 ;; esac
    done
    [ "$live" = 0 ] && break
    if [ -n "$FE_PAUSE" ]; then
      read -r -t 1 -u 9 _
    else
      sleep 1
    fi
    n=$((n + 1))
  done
  if [ -n "$FE_PAUSE" ]; then exec 9<&-; fi
  return 0
}

# fe_forward SIGNAL — SIGTERM and SIGHUP reach the frontend, which cancels
# or waits, restores and exits (docs/PROTOCOL.md → Signals). A launcher that
# leads its session, as over SSH, is the only process a hangup signals.
fe_forward() {
  [ -n "${FE_FPID:-}" ] && kill -"$1" "$FE_FPID" 2>/dev/null
  return 0
}

# fe_run INTENT SCOPES — start the verified frontend for a session of INTENT
# (act, plan or dry-run) and SCOPES, wait for it, restore the terminal and
# clean up. 0 when the frontend finished; 10 to continue in the text
# interface (FE_STATE, FE_WHY say why); any other status is a failure that
# has been reported.
fe_run() {
  local intent=$1 scopes=$2 saved="" fpid st rc
  fe_select "$intent"
  rc=$?
  if [ "$rc" != 0 ]; then
    fe_report
    return 10
  fi
  omb_tmp_init || return 10
  fe_reclaim
  if ! fe_session_create; then
    FE_STATE=fallback FE_WHY="the session scratch could not be made"
    fe_report
    return 10
  fi
  saved=$(stty -g </dev/tty 2>/dev/null)
  # The session's values: set here, passed unchanged by the frontend, checked
  # by every core. The trace file only in an act session.
  export OMB_HOME OMB_SESSION_DIR=$FE_SESSION OMB_SESSION_SCOPES=$scopes
  OMB_SESSION_INTENT=$intent OMB_DRY_RUN=0
  [ "$intent" = dry-run ] && OMB_SESSION_INTENT=act OMB_DRY_RUN=1
  export OMB_SESSION_INTENT OMB_DRY_RUN
  if [ "$intent" != act ] && [ -n "${OMB_TUI_LOG:-}" ]; then
    [ "$intent" = plan ] && ui_note "OMB_TUI_LOG is ignored outside an act session."
    unset OMB_TUI_LOG
  fi
  # The pause fe_wait_cores uses: a FIFO held open for reading and writing
  # never has data, so `read -t` on it waits without starting a process. It
  # is made now, before any core can be supervising a child.
  FE_PAUSE=$OMB_TMP/pause
  mkfifo -m 600 "$FE_PAUSE" 2>/dev/null || FE_PAUSE=""
  # Ctrl-C and Ctrl-\ are caught (never ignored), so a child after exec has
  # the default disposition; SIGTERM and SIGHUP are passed to the frontend,
  # and the launcher waits for it.
  trap fe_on_signal INT QUIT
  trap 'fe_forward TERM' TERM
  trap 'fe_forward HUP' HUP
  "$FE_BIN" --session "$FE_SESSION" <&0 &
  fpid=$!
  FE_FPID=$fpid
  core_proc_write "$FE_SESSION/frontend.omb" frontend "$fpid" || true
  # The frontend's own status, however many caught signals end the wait early.
  _core_wait "$fpid"
  st=$?
  FE_FPID=""
  # A core of this session may still be supervising a child, and a handoff
  # child may own the terminal: wait while any recorded one runs.
  fe_wait_cores "$FE_SESSION"
  [ -n "$saved" ] && stty "$saved" </dev/tty 2>/dev/null
  trap - INT QUIT TERM HUP
  case "$st" in
    0) FE_STATE=verified ;;
    10) FE_STATE=fallback ;;
    126 | 127) FE_STATE=unrunnable FE_WHY="$(tildify "$FE_BIN") would not execute (status $st; SHA-256 ${FE_SHA:-unpinned}, $FE_TARGET)" ;;
    *)
      # The frontend did not restore the terminal itself. In a subshell: a
      # terminal that has gone keeps a builtin's unwritten bytes in bash's
      # buffer, and the next builtin output, to any file, would carry them.
      (printf '\033[?1049l\033[?25h') >/dev/tty 2>/dev/null
      FE_STATE=crashed FE_WHY="the interface stopped (status $st)"
      ;;
  esac
  fe_owner_cleanup
  case "$FE_STATE" in
    verified) return 0 ;;
    crashed)
      fe_report
      ui_note "Nothing was left half-done by the interface itself: the core records every action. ./omarchy-bootstrap status shows where the machine is; --no-tui runs this command in text."
      return 1
      ;;
  esac
  fe_report
  return 10
}

# fe_report — one line on the frontend's state, for the text interface.
fe_report() {
  case "$FE_STATE" in
    verified) ;;
    missing) ui_info "Interface: missing — ${FE_WHY:-not downloaded}. Continuing in text." ;;
    mismatch) ui_warn "Interface: mismatch — ${FE_WHY}. It was not started. Continuing in text." ;;
    unrunnable) ui_warn "Interface: unrunnable — ${FE_WHY}. Continuing in text." ;;
    fallback) ui_info "Interface: fallback — ${FE_WHY:-it refused the session}. Continuing in text." ;;
    crashed) ui_fail "Interface: ${FE_WHY}." ;;
  esac
  log_event frontend "state=$FE_STATE ${FE_WHY:-}"
}
