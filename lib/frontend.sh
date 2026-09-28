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

FE_STATE="" FE_WHY="" FE_BIN="" FE_SHA="" FE_FPID="" FE_FSTART="" FE_PAUSE=""
# An acquisition's own download file, until it is promoted or removed; one
# whose removal failed; the download's writer while it runs (frontend-check
# waits for it in the background); a copy moved aside after a yes.
FE_ATTEMPT="" FE_RESIDUAL="" FE_WRITER="" FE_WRITER_START="" FE_ASIDE="" FE_CHECK=""
# The frontend's own status; the core that answered a check; a scratch a
# check could not remove.
FE_ST="" FE_CORE="" FE_LEFT=""
# How long (seconds) the launcher waits for a session's cores and workers
# before it stops waiting — never concluding they have ended.
FE_WAIT_LIMIT=3600

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
  local lock=$OMB_HOME/release/frontend.lock i target
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
  rec_get_into FE_VERSION "$REC_AT_I" version
  rec_get_into FE_PROTO "$REC_AT_I" proto
  i=0
  while [ "$i" -lt "$REC_N" ]; do
    rec_get_into target "$i" target
    if [ "${REC_T[i]}" = artifact ] && [ "$target" = "$FE_TARGET" ]; then
      rec_get_into FE_URL "$i" url
      rec_get_into FE_SIZE "$i" size
      rec_get_into FE_SHA "$i" sha256
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
  elif [ -n "$FE_CHECK" ]; then
    # frontend-check waits for its writer in the background, so SIGTERM or
    # SIGHUP to the launcher is handled at once: _fe_check_stop ends the
    # writer, waits for it, then removes this attempt's file.
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 -o "$dest" "$FE_URL" 2>/dev/null &
    FE_WRITER=$!
    FE_WRITER_START=$(LC_ALL=C _proc_started "$FE_WRITER")
    _core_wait "$FE_WRITER"
    st=$?
    FE_WRITER="" FE_WRITER_START=""
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
  tmp=$(mktemp "$dir/.omb-tui.XXXXXX") || {
    FE_WHY="no download file could be made in $(tildify "$dir")"
    return 1
  }
  FE_ATTEMPT=$tmp
  if ! fe_fetch "$tmp"; then
    _fe_attempt_remove
    return 1
  fi
  if ! mv -f "$tmp" "$dir/omb-tui"; then
    FE_WHY="the verified download could not be placed at $(tildify "$dir/omb-tui")"
    _fe_attempt_remove
    return 1
  fi
  FE_ATTEMPT=""
  FE_BIN=$dir/omb-tui
  log_event frontend "acquired $FE_URL sha256=$FE_SHA"
}

# _fe_attempt_remove — remove this acquisition's own download file, once its
# writer has ended. A removal that does not take leaves FE_RESIDUAL naming
# the file; nothing else is ever removed.
_fe_attempt_remove() {
  [ -n "$FE_ATTEMPT" ] || return 0
  rm -f "$FE_ATTEMPT" 2>/dev/null
  if [ -e "$FE_ATTEMPT" ] || [ -L "$FE_ATTEMPT" ]; then FE_RESIDUAL=$FE_ATTEMPT; fi
  FE_ATTEMPT=""
}

# fe_select INTENT — decide which frontend binary may start for a session of
# INTENT (act, plan or dry-run; check for frontend-check's launcher, which
# acquires as act does), following docs/FRONTEND.md → *Intent and
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
    # Only an act session, or frontend-check, moves it aside, after a yes.
    case "$intent" in act | check) ;; *) return 1 ;; esac
    ui_warn "$FE_WHY"
    if ! ui_yesno "Move it aside and download the pinned one again?" y; then return 1; fi
    aside="$FE_BAD.mismatch-$(now_stamp)"
    mv -f "$FE_BAD" "$aside" || return 1
    FE_ASIDE=$aside
    log_event frontend "moved a mismatching cached frontend aside: $aside"
    FE_STATE=""
  fi
  case "$intent" in
    act | check | dry-run)
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
# 0 yes, 1 no, 2 unknown (a record that cannot be read counts as naming it,
# a link or other non-plain entry included, as core_op_read counts it).
fe_ops_name() {
  local f session
  [ -d "$OMB_STATE_DIR/ops" ] || return 1
  for f in "$OMB_STATE_DIR"/ops/*.omb; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    _state_file_ok "$f" || return 2
    rec_admit_file op - "$f" || return 2
    rec_get_into session 0 session
    [ "$session" = "$1" ] && return 0
  done
  return 1
}

# fe_scratch_idle DIR — every recorded core and worker of the session DIR is
# dead: 0 yes, 1 a live one, 2 one whose identity cannot be established.
# Every entry a pattern matches is an identity to judge — a link, dangling or
# not, a folder or a FIFO is one that cannot be established. Only a pattern
# that matched nothing (left as it is, which neither -e nor -L finds) is no
# entry: -e alone follows a link and would take a dangling one for none.
fe_scratch_idle() {
  local f
  for f in "$1"/req-*.core "$1"/req-*.worker-*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
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
    if [ -e "$d/frontend.omb" ] || [ -L "$d/frontend.omb" ]; then
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

# fe_wait_cores DIR [LIMIT] — whether the session DIR is over: every core and
# worker it recorded has ended and nothing that joined the group since
# launcher.omb remains. 0 quiescent, the only answer that lets the launcher
# take the terminal back; 1 still active when LIMIT seconds (FE_WAIT_LIMIT)
# have passed; 2 unknown — an identity or the process table that cannot be
# read. Neither 1 nor 2 is ever taken for 0.
#
# First, while a recorded PID still answers kill -0, it waits starting no
# process: the launcher shares the group, and a process joining it while a
# core supervises a child is that core's worker (docs/PROTOCOL.md → worker
# quiescence). PIDs are read with builtins; each pause is `read -t` on
# FE_PAUSE, which fe_run made before any core could exist. An identity file
# with no readable PID may be one being written: it is read again, and one
# still unreadable after 5 s is unknown. A reused PID only makes the wait
# longer. Once no recorded PID answers, no core of the session is left to
# count a process, and the identities are judged in full (PID, start, boot)
# with the group read against the launcher's snapshot.
fe_wait_cores() {
  local limit=${2:-$FE_WAIT_LIMIT} f line pid live torn n=0 odd=0 rc ret
  if [ -z "$FE_PAUSE" ] || [ ! -p "$FE_PAUSE" ]; then
    FE_WHY="the launcher has no way to wait without starting a process"
    return 2
  fi
  exec 9<>"$FE_PAUSE"
  while :; do
    live=0 torn=0
    for f in "$1"/req-*.core "$1"/req-*.worker-*; do
      # Every entry, as fe_scratch_idle counts them: a link or anything
      # but a plain file has no PID to read, and so is torn.
      [ -e "$f" ] || [ -L "$f" ] || continue
      pid=""
      if [ -f "$f" ] && [ ! -L "$f" ]; then
        while IFS= read -r line; do
          case "$line" in
            "proc	"*"	pid="*)
              pid=${line#*	pid=}
              pid=${pid%%	*}
              ;;
          esac
        done <"$f"
      fi
      case "$pid" in
        '' | *[!0-9]* | 0*) torn=1 ;;
        *) kill -0 "$pid" 2>/dev/null && live=1 ;;
      esac
    done
    rc=1
    if [ "$live" = 0 ] && [ "$torn" = 0 ]; then
      # No recorded process answers: the identities in full, then the group.
      fe_scratch_idle "$1"
      rc=$?
      if [ "$rc" = 0 ]; then
        CORE_SNAP=$FE_SNAP CORE_PGID=$FE_PGID
        if ! core_workers_present; then
          rc=3
        elif [ -n "$CORE_PRESENT" ]; then
          rc=1
        else
          break
        fi
      fi
    fi
    odd=$((torn == 1 && live == 0 ? odd + 1 : 0))
    ret=""
    if [ "$odd" -ge 5 ] || [ "$rc" = 2 ]; then
      FE_WHY="an identity the session recorded cannot be read" ret=2
    elif [ "$rc" = 3 ]; then
      FE_WHY="the process table cannot be read" ret=2
    elif [ "$n" -ge "$limit" ]; then
      FE_WHY="a process of the session was still running after $limit s" ret=1
    fi
    if [ -n "$ret" ]; then
      exec 9<&-
      return "$ret"
    fi
    read -r -t 1 -u 9 _
    n=$((n + 1))
  done
  exec 9<&-
  return 0
}

# fe_forward SIGNAL — SIGTERM and SIGHUP reach the frontend, which cancels
# or waits, restores and exits (docs/PROTOCOL.md → Signals). A launcher that
# leads its session, as over SSH, is the only process a hangup signals. Only
# while the process is still the frontend this launcher started — its PID
# with its start time: once the frontend has ended, its PID may be another
# process's. A frontend whose start was never read is not signalled.
fe_forward() {
  [ -n "${FE_FPID:-}" ] && [ -n "${FE_FSTART:-}" ] || return 0
  [ "$(LC_ALL=C _proc_started "$FE_FPID")" = "$FE_FSTART" ] || return 0
  kill -"$1" "$FE_FPID" 2>/dev/null
  return 0
}

# fe_run INTENT SCOPES — start the verified frontend for a session of INTENT
# (act, plan or dry-run) and SCOPES, wait for it, restore the terminal and
# clean up. 0 when the frontend finished; 10 to continue in the text
# interface (FE_STATE, FE_WHY say why); any other status is a failure that
# has been reported.
fe_run() {
  local intent=$1 scopes=$2 saved="" rc
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
  # by every core. The trace file only in an act session; a session purpose
  # only in frontend-check's (fe_check_run), whatever this launcher inherited.
  export OMB_HOME OMB_SESSION_DIR=$FE_SESSION OMB_SESSION_SCOPES=$scopes
  OMB_SESSION_INTENT=$intent OMB_DRY_RUN=0
  [ "$intent" = dry-run ] && OMB_SESSION_INTENT=act OMB_DRY_RUN=1
  export OMB_SESSION_INTENT OMB_DRY_RUN
  unset OMB_SESSION_PURPOSE
  if [ "$intent" != act ] && [ -n "${OMB_TUI_LOG:-}" ]; then
    [ "$intent" = plan ] && ui_note "OMB_TUI_LOG is ignored outside an act session."
    unset OMB_TUI_LOG
  fi
  fe_session_run
  rc=$?
  if [ "$rc" = 3 ]; then
    fe_report
    return 10
  fi
  if [ "$rc" != 0 ]; then
    FE_STATE=unsettled
    fe_report
    return 1
  fi
  [ -n "$saved" ] && stty "$saved" </dev/tty 2>/dev/null
  fe_session_state
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

# fe_session_run — start the verified frontend FE_BIN for the session
# FE_SESSION, whose values are exported: the pause, the signals, the
# frontend waited for, then the session waited for. FE_ST: the frontend's own
# status. 0 when the session is over; 1 still running at the wait's limit, 2
# not knowable (fe_wait_cores); 3 when no frontend was started, the scratch
# removed and FE_STATE and FE_WHY saying why.
fe_session_run() {
  local fpid rc
  FE_ST=""
  # The pause fe_wait_cores uses: a FIFO held open for reading and writing
  # never has data, so `read -t` on it waits without starting a process. It
  # is made now, before any core can be supervising a child; without it the
  # launcher could not wait for one safely, so no frontend starts.
  FE_PAUSE=$OMB_TMP/pause
  if ! mkfifo -m 600 "$FE_PAUSE" 2>/dev/null; then
    FE_PAUSE=""
    rm -rf "$FE_SESSION"
    FE_STATE=fallback FE_WHY="the launcher could not make its pause"
    return 3
  fi
  # Ctrl-C and Ctrl-\ are caught (never ignored), so a child after exec has
  # the default disposition; SIGTERM and SIGHUP are passed to the frontend,
  # and the launcher waits for it.
  trap fe_on_signal INT QUIT
  trap 'fe_forward TERM' TERM
  trap 'fe_forward HUP' HUP
  "$FE_BIN" --session "$FE_SESSION" <&0 &
  fpid=$!
  # The launcher's own handle on its child is the PID it started, which
  # stays its child until waited for; its start time, read now, is what a
  # forwarded signal is held to. A frontend that ended before it could be
  # read is waited for all the same, and never signalled.
  FE_FSTART=$(LC_ALL=C _proc_started "$fpid")
  FE_FPID=$fpid
  core_proc_write "$FE_SESSION/frontend.omb" frontend "$fpid" || true
  # The frontend's own status, however many caught signals end the wait early.
  _core_wait "$fpid"
  FE_ST=$?
  FE_FPID="" FE_FSTART=""
  # A core of this session may still be supervising a child, and a handoff
  # child may own the terminal: the terminal is taken back only once the
  # session is known to be over. Still running after the limit, or not
  # knowable: the terminal and the scratch are left as they are.
  fe_wait_cores "$FE_SESSION"
  rc=$?
  trap - INT QUIT TERM HUP
  return "$rc"
}

# fe_session_state — FE_STATE and FE_WHY from the frontend's own status,
# FE_ST, once the session is over.
fe_session_state() {
  case "$FE_ST" in
    0) FE_STATE=verified ;;
    10) FE_STATE=fallback ;;
    126 | 127) FE_STATE=unrunnable FE_WHY="$(tildify "$FE_BIN") would not execute (status $FE_ST; SHA-256 ${FE_SHA:-unpinned}, $FE_TARGET)" ;;
    *)
      # The frontend did not restore the terminal itself. In a subshell: a
      # terminal that has gone keeps a builtin's unwritten bytes in bash's
      # buffer, and the next builtin output, to any file, would carry them.
      (printf '\033[?1049l\033[?25h') >/dev/tty 2>/dev/null
      FE_STATE=crashed FE_WHY="the interface stopped (status $FE_ST)"
      ;;
  esac
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
    unsettled)
      ui_fail "Interface: the session is not known to be over — ${FE_WHY}."
      ui_note "The terminal and the session's files were left as they are, in case a program still uses them. ./omarchy-bootstrap status shows where the machine is."
      ;;
  esac
  log_event frontend "state=$FE_STATE ${FE_WHY:-}"
}

# ---------------------------------------------------------------------------
# frontend-check (docs/FRONTEND.md → *The startup check*)
# ---------------------------------------------------------------------------

# fe_check — the startup check, once the entrypoint has refused any argument
# and every production seam: the target, the terminal, the dry run, then the
# check. Its launcher alone holds the cache authority (FE_CHECK: acquisition
# after [Y/n], a mismatching copy moved aside after a yes); its cores get a
# read session, the journey scope alone and the purpose frontend-check.
# 0 completed; 1 not completed or not performed; 130 Ctrl-C before the
# frontend started. Every outcome ends here, never in another command.
fe_check() {
  local why=""
  platform_init
  ui_header "frontend-check"
  if ! fe_target; then
    _fe_check_say "frontend-check: not performed — no frontend is built for this system ($(uname -s 2>/dev/null) $(uname -m 2>/dev/null)); the interactive check was not performed."
    return 1
  fi
  if [ -n "${OMB_NO_TUI:-}" ]; then
    why="--no-tui was given"
  elif [ ! -t 0 ]; then
    why="stdin is not a terminal"
  elif [ ! -t 1 ]; then
    why="stdout is not a terminal"
  elif [ -z "${TERM:-}" ] || ! printenv TERM >/dev/null 2>&1; then
    # Bash gives TERM the value dumb when the environment has none, without
    # exporting it: only the environment says whether it was set.
    why="TERM is not set"
  elif [ "$TERM" = dumb ]; then
    why="TERM is dumb"
  fi
  if [ -n "$why" ]; then
    _fe_check_say "frontend-check: not performed — $why; the interactive check was not performed."
    return 1
  fi
  if ! state_init; then
    _fe_check_say "frontend-check: not completed — the state folder's location is not usable; nothing was started."
    return 1
  fi
  trap omb_cleanup EXIT
  if [ "$OMB_DRY_RUN" = 1 ]; then
    fe_check_dry
    return 1
  fi
  FE_CHECK=1
  trap '_fe_check_stop INT' INT
  trap '_fe_check_stop TERM' TERM
  trap '_fe_check_stop HUP' HUP
  if fe_select check && fe_check_run; then
    _fe_check_say "frontend-check: completed — omb-tui $FE_VERSION ($FE_TARGET), SHA-256 $FE_SHA, from $(tildify "$FE_BIN"). The core (${FE_CORE}) answered hello and the journey snapshot, every exchange of the session ended done, the terminal's settings read back as saved, and the session ended with its files removed."
    return 0
  fi
  _fe_check_failed
  return 1
}

# fe_check_dry — frontend-check --dry-run on an eligible terminal: the lock
# admitted and the cache inspected, neither changed; what the check would
# do, as would run. Nothing is downloaded, moved or started.
fe_check_dry() {
  if ! fe_lock_read; then
    _fe_check_say "frontend-check: not performed — a dry run, and this checkout's lock pins nothing to start: $FE_WHY."
    return 1
  fi
  fe_find_cached
  ui_section "The interface" "what frontend-check would do"
  ui_kv "URL" "$FE_URL"
  ui_kv "Version" "$FE_VERSION ($FE_TARGET)"
  ui_kv "Size" "$FE_SIZE bytes"
  ui_kv "SHA-256" "$FE_SHA"
  if [ -n "$FE_BIN" ]; then
    ui_kv "Cached" "$(tildify "$FE_BIN"), verified"
  else
    if [ -n "$FE_BAD" ]; then
      ui_kv "Cached" "$(tildify "$FE_BAD"), not the pinned bytes"
      ui_would "ask to move $(tildify "$FE_BAD") aside"
    else
      ui_kv "Cached" "no verified copy"
    fi
    FE_BIN=$FE_CACHE/$FE_SHA/omb-tui
    ui_would "ask [Y/n], then download $FE_URL into $(tildify "$FE_BIN")"
  fi
  ui_would "start $(tildify "$FE_BIN") for a read-only session with the journey scope"
  _fe_check_say "frontend-check: not performed — a dry run: nothing was downloaded, moved or started."
}

# fe_check_run — the check's session, then its result in the order of
# docs/FRONTEND.md → *The command's result*: the frontend's end, quiescence,
# the exchanges judged while the scratch exists, the terminal's settings put
# back and read again, owner cleanup, the scratch confirmed gone. 0 only when
# every step held; otherwise 1, after the steps that still apply, FE_STATE and
# FE_WHY saying why and FE_LEFT naming a scratch that remains.
fe_check_run() {
  local saved now rc xwhy="" twhy=""
  FE_WHY="" FE_LEFT="" FE_CORE=""
  if ! omb_tmp_init; then
    FE_WHY="the per-run scratch could not be made, so the interface was not started"
    return 1
  fi
  saved=$(stty -g </dev/tty 2>/dev/null)
  if [ -z "$saved" ]; then
    FE_WHY="the terminal's settings could not be saved, so the interface was not started"
    return 1
  fi
  fe_reclaim
  if ! fe_session_create; then
    FE_STATE=fallback FE_WHY="the session scratch could not be made"
    return 1
  fi
  # The session's values: the core's authority comes from these alone, never
  # from this launcher's cache authority.
  export OMB_HOME OMB_SESSION_DIR=$FE_SESSION OMB_SESSION_SCOPES=journey OMB_SESSION_INTENT=read OMB_DRY_RUN=0 OMB_SESSION_PURPOSE=frontend-check
  if [ -n "${OMB_TUI_LOG:-}" ]; then
    ui_note "OMB_TUI_LOG is ignored: frontend-check writes no trace."
    unset OMB_TUI_LOG
  fi
  # 1 and 2: the frontend's end, and the session quiescent.
  fe_session_run
  rc=$?
  [ "$rc" = 3 ] && return 1
  if [ "$rc" != 0 ]; then
    FE_STATE=unsettled
    return 1
  fi
  # 3: every exchange, judged while the scratch still exists.
  fe_check_exchanges "$FE_SESSION" || xwhy=$FE_WHY
  # 4: the terminal's settings put back, read again, and equal.
  if ! stty "$saved" </dev/tty 2>/dev/null; then
    twhy="the terminal's saved settings could not be put back"
  else
    now=$(stty -g </dev/tty 2>/dev/null)
    if [ -z "$now" ]; then
      twhy="the terminal's settings could not be read again"
    elif [ "$now" != "$saved" ]; then
      twhy="the terminal's settings read back other than they were saved"
    fi
  fi
  FE_WHY=""
  fe_session_state
  [ "$FE_ST" = 10 ] && FE_WHY="the interface refused the session (status 10)"
  # 5 and 6: owner cleanup, then the scratch confirmed gone; nothing in it
  # is read after this.
  fe_owner_cleanup
  if [ -e "$FE_SESSION" ] || [ -L "$FE_SESSION" ]; then FE_LEFT=$FE_SESSION; fi
  [ "$FE_STATE" = verified ] || return 1
  if [ -n "$xwhy" ]; then
    FE_WHY=$xwhy
  elif [ -n "$twhy" ]; then
    FE_WHY=$twhy
  elif [ -n "$FE_LEFT" ]; then
    FE_WHY="the session's files could not be removed"
  else
    return 0
  fi
  return 1
}

# fe_check_exchanges DIR — every request spool of the session DIR admitted as
# a response and judged (docs/FRONTEND.md → *The command's result*, step 3).
# 0 when every exchange ended done, each answered for a read session with no
# fixture and not a dry run, at least one without a generation (a hello)
# and at least one with a generation and no action (the journey snapshot);
# 1 otherwise, FE_WHY saying which and why. A spool that is not a plain
# file, cannot be read, or is not a whole response to any operation fails.
# FE_CORE: the answering core, from the first hello record.
fe_check_exchanges() {
  local f op n=0 hello=0 snap=0 v got
  for f in "$1"/req-*.events; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    n=$((n + 1))
    if [ ! -f "$f" ] || [ -L "$f" ]; then
      FE_WHY="the exchange ${f##*/} is not a plain file"
      return 1
    fi
    for op in hello snapshot detail validate execute ""; do
      [ -n "$op" ] || break
      rec_admit_file res "$op" "$f" && break
    done
    if [ -z "$op" ]; then
      FE_WHY="the exchange ${f##*/} is not a whole answer ($REC_REASON at line $REC_AT)"
      return 1
    fi
    rec_find result
    rec_get_into got "$REC_AT_I" status
    if [ "$got" != "done" ]; then
      FE_WHY="the exchange ${f##*/} ended $got"
      return 1
    fi
    for v in ceiling=read dry_run=0 fixture=0; do
      rec_get_into got 0 "${v%%=*}"
      if [ "$got" != "${v#*=}" ]; then
        FE_WHY="the exchange ${f##*/} was answered with ${v%%=*}=$got"
        return 1
      fi
    done
    if [ -z "$FE_CORE" ]; then
      rec_get_into FE_CORE 0 core
      rec_get_into got 0 commit
      FE_CORE="$FE_CORE at ${got:-an unknown commit}"
    fi
    if rec_find generation; then
      if rec_find action; then
        FE_WHY="the exchange ${f##*/} listed an action"
        return 1
      fi
      snap=1
    else
      hello=1
    fi
  done
  if [ "$n" = 0 ]; then
    FE_WHY="the interface asked the core nothing"
  elif [ "$hello" = 0 ]; then
    FE_WHY="no hello was answered"
  elif [ "$snap" = 0 ]; then
    FE_WHY="no journey snapshot was answered"
  else
    return 0
  fi
  return 1
}

# _fe_check_stop SIGNAL — Ctrl-C, SIGTERM or SIGHUP before the frontend
# started. The download's writer, if one runs, is ended — only while it is
# still the process started, its PID with its start time — and waited for;
# then this attempt's own file is removed, and a session scratch made for a
# frontend that never started. 130 for Ctrl-C, otherwise 1.
_fe_check_stop() {
  if [ -n "$FE_WRITER" ]; then
    if [ -n "$FE_WRITER_START" ] && [ "$(LC_ALL=C _proc_started "$FE_WRITER")" = "$FE_WRITER_START" ]; then
      kill -TERM "$FE_WRITER" 2>/dev/null
    fi
    _core_wait "$FE_WRITER"
    FE_WRITER="" FE_WRITER_START=""
  fi
  _fe_attempt_remove
  if [ -n "${FE_SESSION:-}" ]; then fe_owner_cleanup; fi
  _p '\n'
  _fe_check_say "frontend-check: not completed — stopped by SIG$1 before the interface started."
  _fe_check_left
  [ "$1" = INT ] && exit 130
  exit 1
}

# _fe_check_failed — the not-completed report: the launcher's state and its
# reason, then whatever the check leaves behind.
_fe_check_failed() {
  case "$FE_STATE" in
    missing) FE_WHY=${FE_WHY:-the interface is not downloaded} ;;
    fallback) FE_WHY=${FE_WHY:-it refused the session} ;;
    unsettled) FE_WHY="the session is not known to be over (${FE_WHY:-its state cannot be read})" ;;
  esac
  _fe_check_say "frontend-check: not completed — ${FE_STATE:-verified}: ${FE_WHY:-a step did not hold}."
  if [ "$FE_STATE" = unsettled ]; then
    _fe_check_say "The terminal and the session's files were left as they are, in case a program still uses them."
  fi
  _fe_check_left
}

# _fe_check_left — the files a check that did not complete leaves: a copy
# moved aside after a yes, this attempt's download file that could not be
# removed, a session scratch that could not be.
_fe_check_left() {
  [ -n "$FE_ASIDE" ] && _fe_check_say "The cached copy that did not match was moved aside to $(tildify "$FE_ASIDE"), where it stays."
  [ -n "$FE_RESIDUAL" ] && _fe_check_say "This attempt's download file could not be removed and remains: $(tildify "$FE_RESIDUAL"). It is never started; nothing else was removed."
  [ -n "${FE_LEFT:-}" ] && _fe_check_say "The session's files remain: $(tildify "$FE_LEFT")."
  return 0
}

_fe_check_say() { _p '   %s\n' "$*"; }
