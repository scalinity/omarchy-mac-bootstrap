# shellcheck shell=bash
# The core's protocol entry: `omarchy-bootstrap core OP` (docs/PROTOCOL.md → §3–§5).
#
# One short-lived core per request. The entrypoint has already copied the
# request from fd 3 (bounded) and closed fd 3 before any library loaded;
# core_main admits that copy, answers on the event spool ($OMB_EVENTS, a file
# appended one record at a time from the main shell, never a pipe), and ends
# with exactly one result record. It holds no protocol descriptor, so none can
# reach a child.
#
# M14 gate 1 exposes no baseline action. Its only actions are three test
# actions over fixtures (test.read, test.mutate, test.handoff), which run the
# fake children of data/children.omb and exist only in fixture mode, never as
# root: they prove the transport, the supervision and the diagnostics without
# any path that changes a real machine.
#
# Needs lib/common.sh, lib/state.sh, lib/ui.sh and lib/records.sh.

CORE_SPOOL_MAX=8388608
CORE_SPOOL_RECS=65536
# Past this, no more progress or message records: room for overflow and result.
CORE_SPOOL_SOFT=$((CORE_SPOOL_MAX - 65536))
CORE_DIAG_CHILD=65536
CORE_DIAG_REQUEST=262016
CORE_DIAG_SESSION=4194304
CORE_DIAG_SUMMARY=128
CORE_DIAG_TAIL=65281
CORE_DIAG_KEEP=65280
CORE_COUNTER_MAX=9999999999
# Programs known to leave something running after they exit: a managed entry
# naming one must be detaches=owned with its owner and check.
CORE_KNOWN_DETACHING="setsid nohup daemon systemd-run start-stop-daemon sshd dockerd"

CORE_BYTES=0 CORE_RECS=0 CORE_SUPPRESSED=0 CORE_RESULT=0
CORE_CANCEL=0 CORE_INTERRUPTED=0 CORE_WORKERS=0
CORE_N="" CORE_SESSION="" CORE_EVENTS="" CORE_BOOT="" CORE_ENV_WHY=""

# ---------------------------------------------------------------------------
# The environment (docs/PROTOCOL.md → §4, Environment)
# ---------------------------------------------------------------------------

# core_env_check — CORE_ENV_WHY is empty when the session values are sound;
# CORE_EVENTS is set only when the spool can be written at all.
core_env_check() {
  local home=${OMB_CORE_ENV_HOME:-} scopes=${OMB_SESSION_SCOPES:-} s seen=","
  CORE_ENV_WHY="" CORE_EVENTS="" CORE_SESSION="" CORE_N=""
  local IFS
  # The session folder and the spool first: without them nothing can answer.
  case "${OMB_SESSION_DIR:-}" in
    /*/omb-session.*) ;;
    *) CORE_ENV_WHY="OMB_SESSION_DIR is missing or not a session folder" && return 1 ;;
  esac
  if [ ! -d "$OMB_SESSION_DIR" ] || [ -L "$OMB_SESSION_DIR" ] || [ ! -O "$OMB_SESSION_DIR" ] ||
    [ -z "$(find "$OMB_SESSION_DIR" -maxdepth 0 -perm 700 2>/dev/null)" ]; then
    CORE_ENV_WHY="OMB_SESSION_DIR is not a private folder of this user"
    return 1
  fi
  case "${OMB_EVENTS:-}" in
    "$OMB_SESSION_DIR"/req-[1-9]*.events) CORE_N=${OMB_EVENTS#"$OMB_SESSION_DIR"/req-} CORE_N=${CORE_N%.events} ;;
    *) CORE_ENV_WHY="OMB_EVENTS is not a request spool inside OMB_SESSION_DIR" && return 1 ;;
  esac
  case "$CORE_N" in '' | *[!0-9]* | ?????????*) CORE_ENV_WHY="OMB_EVENTS names no request" && return 1 ;; esac
  if [ ! -f "$OMB_EVENTS" ] || [ -L "$OMB_EVENTS" ]; then
    CORE_ENV_WHY="OMB_EVENTS is not a plain file"
    return 1
  fi
  # The frontend creates the spool holding only its header; anything else
  # there would splice two answers into one.
  if [ "$(head -c 11 "$OMB_EVENTS" 2>/dev/null; printf x)" != "omb-res 1
x" ]; then
    CORE_ENV_WHY="OMB_EVENTS does not hold just the response header"
    return 1
  fi
  CORE_SESSION=$OMB_SESSION_DIR CORE_EVENTS=$OMB_EVENTS
  # Then the values every answer depends on.
  case "$home" in
    /*) [ "$home" = "$OMB_HOME" ] || CORE_ENV_WHY="OMB_HOME is not this core's folder" ;;
    *) CORE_ENV_WHY="OMB_HOME is missing or not absolute" ;;
  esac
  case "${OMB_SESSION_INTENT:-}" in read | plan | act) ;; *) CORE_ENV_WHY=${CORE_ENV_WHY:-"OMB_SESSION_INTENT is missing or malformed"} ;; esac
  case "${OMB_CORE_ENV_DRY:-}" in 0 | 1) ;; *) CORE_ENV_WHY=${CORE_ENV_WHY:-"OMB_DRY_RUN is missing or malformed"} ;; esac
  [ -n "$scopes" ] || CORE_ENV_WHY=${CORE_ENV_WHY:-"OMB_SESSION_SCOPES is missing"}
  IFS=,
  set -f
  for s in $scopes; do
    case "|$REC_SCOPES|" in *"|$s|"*) ;; *) CORE_ENV_WHY=${CORE_ENV_WHY:-"OMB_SESSION_SCOPES names an unknown scope"} ;; esac
    case "$seen" in *",$s,"*) CORE_ENV_WHY=${CORE_ENV_WHY:-"OMB_SESSION_SCOPES repeats a scope"} ;; esac
    seen="$seen$s,"
  done
  set +f
  case "$scopes" in ,* | *, | *,,*) CORE_ENV_WHY=${CORE_ENV_WHY:-"OMB_SESSION_SCOPES is malformed"} ;; esac
  [ -z "$CORE_ENV_WHY" ]
}

# core_in_scopes SCOPE — is SCOPE among the session's scopes?
core_in_scopes() {
  case ",${OMB_SESSION_SCOPES:-}," in *",$1,"*) return 0 ;; esac
  return 1
}

# core_intent_allows INTENT — is INTENT within the session's ceiling?
core_intent_allows() {
  case "$OMB_SESSION_INTENT:$1" in
    act:* | plan:plan | plan:read | read:read) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# The spool
# ---------------------------------------------------------------------------

# core_emit TYPE KEY VALUE ... — append one record from the main shell. Past
# the soft limit, progress and message records are counted, not written.
core_emit() {
  local line n
  rec_line_v "$@"
  line=$REC_LINE
  n=$((${#line} + 1))
  case "$1" in
    progress | message)
      if [ $((CORE_BYTES + n)) -gt "$CORE_SPOOL_SOFT" ] || [ $((CORE_RECS + 3)) -ge "$CORE_SPOOL_RECS" ]; then
        CORE_SUPPRESSED=$((CORE_SUPPRESSED + 1))
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$line" >>"$CORE_EVENTS" || return 1
  CORE_BYTES=$((CORE_BYTES + n)) CORE_RECS=$((CORE_RECS + 1))
}

# core_result STATUS CODE [TEXT] [NEXT] — the one final record (after an
# overflow record when anything was suppressed).
core_result() {
  [ "$CORE_RESULT" = 0 ] || return 0
  if [ "$CORE_SUPPRESSED" -gt 0 ]; then
    core_emit overflow suppressed "$CORE_SUPPRESSED"
  fi
  core_emit result status "$1" code "$2" text "${3:-}" next "${4:-}"
  CORE_RESULT=1
}

core_message() { core_emit message level "$1" text "$2"; }

# ---------------------------------------------------------------------------
# Identity: PID, start time and boot session (docs/PROTOCOL.md → §3)
# ---------------------------------------------------------------------------

# core_boot_read — CORE_BOOT: this boot session's identity, or empty when it
# cannot be read (then no identity can be established, and every process
# counts as possibly alive).
core_boot_read() {
  local b=""
  case "$OMB_PLATFORM" in
    macos) b=$(sys_cmd bootsession sysctl -n kern.bootsessionuuid) ;;
    linux) b=$(cat "$(sys_path /proc/sys/kernel/random/boot_id)" 2>/dev/null) ;;
  esac
  case "$b" in '' | *[!0-9A-Fa-f-]*) b="" ;; esac
  CORE_BOOT=$b
}

# core_alive PID START BOOT — 0 alive, 1 not alive, 2 unknown. A process is
# alive only if that PID exists now, with that start time, in this boot
# session; a reused PID is never the recorded process. ps is first held to
# a process known to be alive (this one): a ps that cannot report it cannot
# vouch for any other.
core_alive() {
  local pid=$1 start=$2 boot=$3 now
  case "$pid" in '' | *[!0-9]*) return 2 ;; esac
  [ -n "$CORE_BOOT" ] || return 2
  [ "$boot" = "$CORE_BOOT" ] || return 1
  [ -n "$(_proc_started "$$")" ] || return 2
  now=$(_proc_started "$pid")
  [ -n "$now" ] || return 1
  [ "$now" = "$start" ] || return 1
  return 0
}

# core_proc_write FILE ROLE PID — a process identity file, created exclusively
# (0600), sealed.
core_proc_write() {
  local f=$1 start
  start=$(_proc_started "$3")
  [ -n "$start" ] && [ -n "$CORE_BOOT" ] || return 1
  (
    umask 077
    set -C
    { printf 'omb-proc 1\n' && rec_line proc role "$2" pid "$3" start "$start" boot "$CORE_BOOT"; } >"$f"
  ) 2>/dev/null || return 1
  rec_seal_write "$f"
}

# core_proc_read FILE — CP_PID, CP_START, CP_BOOT from an identity file; 1
# when it cannot be admitted.
core_proc_read() {
  CP_PID="" CP_START="" CP_BOOT=""
  rec_admit_file proc - "$1" || return 1
  CP_PID=$(rec_get 0 pid) && CP_START=$(rec_get 0 start) && CP_BOOT=$(rec_get 0 boot)
}

# core_file_alive FILE — 0 alive, 1 not alive, 2 unknown (an unreadable
# identity counts as unknown: possibly alive).
core_file_alive() {
  core_proc_read "$1" || return 2
  core_alive "$CP_PID" "$CP_START" "$CP_BOOT"
}

# ---------------------------------------------------------------------------
# The process group: the snapshot and the workers still present
# ---------------------------------------------------------------------------

# _core_ps FILE — read the process table (pid, pgid, start) into FILE. The
# reading's own process is its PID, CORE_READER, never a worker.
_core_ps() {
  ps -axo pid=,pgid=,lstart= >"$1" 2>/dev/null &
  CORE_READER=$!
  wait "$CORE_READER"
}

# core_group_snapshot — CORE_SNAP: "pid start" of every process now in this
# job's process group. 1 when the table cannot be read.
core_group_snapshot() {
  local f=$OMB_TMP/ps-snap
  CORE_PGID=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
  case "$CORE_PGID" in '' | *[!0-9]*) return 1 ;; esac
  _core_ps "$f" || return 1
  CORE_SNAP=$(awk -v g="$CORE_PGID" -v r="$CORE_READER" '$2 == g && $1 != r { pid = $1; $1 = ""; $2 = ""; sub(/^ +/, ""); print pid " " $0 }' "$f") || return 1
  [ -n "$CORE_SNAP" ]
}

# core_workers_present — CORE_PRESENT: the processes in the group now that
# were not in the snapshot, the reading's own excepted. 2 when the table
# cannot be read.
core_workers_present() {
  local f=$OMB_TMP/ps-now
  _core_ps "$f" || return 2
  printf '%s\n' "$CORE_SNAP" >"$OMB_TMP/ps-snap-list"
  CORE_PRESENT=$(awk -v g="$CORE_PGID" -v r="$CORE_READER" '
    FNR == NR { seen[$0] = 1; next }
    $2 == g && $1 != r { pid = $1; $1 = ""; $2 = ""; sub(/^ +/, ""); if (!((pid " " $0) in seen)) print pid }' \
    "$OMB_TMP/ps-snap-list" "$f") || return 2
  return 0
}

# core_quiescent SECONDS — wait up to SECONDS for no worker to be present.
# 0 quiescent, 1 workers still present, 2 the table could not be read.
core_quiescent() {
  local tries=$(($1 * 10)) i=0 rc
  while :; do
    core_workers_present
    rc=$?
    [ "$rc" = 0 ] || return 2
    [ -z "$CORE_PRESENT" ] && return 0
    [ "$i" -ge "$tries" ] && return 1
    sleep 0.1
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# The child registry (docs/PROTOCOL.md → *Children*)
# ---------------------------------------------------------------------------

CORE_REGISTRY=""

# core_registry_check FILE — the registry's static rules; CORE_REG_WHY on
# failure. Adding or changing an entry is a reviewed change.
core_registry_check() {
  local i=0 action cmd class out err tty det owner check base
  CORE_REG_WHY=""
  if ! rec_admit_file children - "$1"; then
    CORE_REG_WHY="the child registry is not admissible ($REC_REASON)"
    return 1
  fi
  while [ "$i" -lt "$REC_N" ]; do
    action=$(rec_get "$i" action) cmd=$(rec_get "$i" cmd) class=$(rec_get "$i" class)
    out=$(rec_get "$i" stdout) err=$(rec_get "$i" stderr) tty=$(rec_get "$i" tty)
    det=$(rec_get "$i" detaches) owner=$(rec_get "$i" owner) check=$(rec_get "$i" check)
    base=${cmd##*/}
    case "$cmd" in
      '' | /* | ../* | */../* | */.. | *//*) CORE_REG_WHY="$action: its command is not a path inside the tool" ;;
    esac
    if [ "$tty" = needs ] && [ "$class" != handoff ]; then
      CORE_REG_WHY="$action: a child that needs a terminal is a handoff"
    elif [ "$class" = mutating ] && [ "$tty" != none ]; then
      CORE_REG_WHY="$action: a mutating child must run with no terminal"
    elif [ "$class" != read ] && { [ "$out" = diagnostics ] || [ "$err" = diagnostics ]; }; then
      CORE_REG_WHY="$action: only a read child has diagnostics streams"
    elif [ "$class" = handoff ] && { [ "$out" != functional ] || [ "$err" != functional ]; }; then
      CORE_REG_WHY="$action: a handoff child's output is the terminal, never captured or discarded"
    elif [ "$det" = owned ] && { [ -z "$owner" ] || [ -z "$check" ]; }; then
      CORE_REG_WHY="$action: a detaching child needs its owner and completion check"
    elif [ "$det" = no ] && { [ -n "$owner" ] || [ -n "$check" ]; }; then
      CORE_REG_WHY="$action: an owner and check belong only to a detaching child"
    elif [ "$class" != handoff ] && [ "$det" = no ]; then
      case " $CORE_KNOWN_DETACHING " in
        *" $base "*) CORE_REG_WHY="$action: $base leaves something running; it cannot be registered as detaches=no" ;;
      esac
    fi
    [ -n "$CORE_REG_WHY" ] && return 1
    i=$((i + 1))
  done
  return 0
}

# core_registry_entry ACTION — CC_CMD, CC_CLASS, CC_OUT, CC_ERR, CC_TTY,
# CC_DETACHES, CC_CHECK from the registry, admitted and checked once per
# request; 1 when there is no entry. A request never chooses any of it.
core_registry_entry() {
  local i=0 line
  if [ -z "${CORE_REG_N:-}" ]; then
    CORE_REGISTRY=${CORE_REGISTRY:-$OMB_HOME/data/children.omb}
    core_registry_check "$CORE_REGISTRY" || return 1
    CORE_REG_N=$REC_N
    while [ "$i" -lt "$REC_N" ]; do
      CORE_REG_L[i]=${REC_L[i]}
      i=$((i + 1))
    done
    i=0
  fi
  while [ "$i" -lt "$CORE_REG_N" ]; do
    line=${CORE_REG_L[i]}
    _rec_field_raw "$line" action
    if [ "$REC_RAW" = "$1" ]; then
      _rec_field_raw "$line" cmd && CC_CMD=$(rec_dec "$REC_RAW")
      _rec_field_raw "$line" class && CC_CLASS=$REC_RAW
      _rec_field_raw "$line" stdout && CC_OUT=$REC_RAW
      _rec_field_raw "$line" stderr && CC_ERR=$REC_RAW
      _rec_field_raw "$line" tty && CC_TTY=$REC_RAW
      _rec_field_raw "$line" detaches && CC_DETACHES=$REC_RAW
      _rec_field_raw "$line" check
      CC_CHECK=$REC_RAW
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Diagnostics (docs/PROTOCOL.md → *Diagnostics, by child class*)
# ---------------------------------------------------------------------------

# _core_size FILE... — CORE_SIZE: the total size of the files that exist,
# read by one wc for all of them.
_core_size() {
  local f n total=0 st
  local -a have=()
  for f in "$@"; do [ -f "$f" ] && have+=("$f"); done
  CORE_SIZE=0
  [ "${#have[@]}" -gt 0 ] || return 0
  wc -c "${have[@]}" >"$OMB_TMP/sizes" 2>/dev/null
  st=$?
  [ "$st" = 0 ] || return 1
  # One line per file (and a total line when there are several).
  while read -r n f; do
    case "$n" in '' | *[!0-9]*) return 1 ;; esac
    [ "${#have[@]}" -gt 1 ] && [ "$f" = total ] && continue
    total=$((total + n))
  done <"$OMB_TMP/sizes"
  CORE_SIZE=$total
}

# _core_until TEST ARG — wait for a condition that is usually met at once:
# checked without sleeping first, then every 10 ms, up to about 5 seconds.
# TEST is ready (ARG exists) or gone (process ARG has ended).
_core_until() {
  local i=0
  while [ "$i" -lt 600 ]; do
    case "$1" in
      ready) [ -e "$2" ] && return 0 ;;
      gone) kill -0 "$2" 2>/dev/null || return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -gt 100 ] && sleep 0.01
  done
  return 1
}

# core_diag_room HEADER — CORE_ROOM: the most a new block may hold, header
# included: the child's, the request's and the session's room, each less
# what is already retained, and less the fixed summaries a new file needs.
# Every retained byte counts; nothing is appended and then trimmed.
core_diag_room() {
  local diag=$CORE_SESSION/req-$CORE_N.diag sum=$CORE_SESSION/req-$CORE_N.diag-summary
  local room=$CORE_DIAG_CHILD r s f
  _core_size "$diag" || return 1
  r=$((CORE_DIAG_REQUEST - CORE_SIZE))
  # shellcheck disable=SC2206 # glob over the session's own files
  local files=("$CORE_SESSION"/req-*.diag "$CORE_SESSION"/req-*.diag-summary "$CORE_SESSION"/session.diag-summary)
  _core_size "${files[@]}" || return 1
  s=$((CORE_DIAG_SESSION - CORE_SIZE))
  [ -f "$sum" ] || s=$((s - CORE_DIAG_SUMMARY))
  f=$CORE_SESSION/session.diag-summary
  [ -f "$f" ] || s=$((s - CORE_DIAG_SUMMARY))
  [ "$r" -lt "$room" ] && room=$r
  [ "$s" -lt "$room" ] && room=$s
  [ "$room" -lt 0 ] && room=0
  CORE_ROOM=$room
}

# core_summary_write FILE CHILDREN BYTES — add to a fixed 128-byte summary,
# rewritten whole (a temporary file, then a rename). The counters stop at
# 9 999 999 999.
core_summary_write() {
  local f=$1 c=0 b=0 tmp line=""
  if [ -f "$f" ]; then
    IFS= read -r line <"$f"
    c=${line#*children not kept } c=${c:0:10}
    b=${line#*bytes discarded at least } b=${b:0:10}
    case "$c$b" in *[!0-9]* | ?????????????????????*) c=0 b=0 ;; esac
    [ "${#c}" = 10 ] && [ "${#b}" = 10 ] || c=0 b=0
    c=$((10#$c)) b=$((10#$b))
  fi
  c=$((c + $2)) b=$((b + $3))
  [ "$c" -gt "$CORE_COUNTER_MAX" ] && c=$CORE_COUNTER_MAX
  [ "$b" -gt "$CORE_COUNTER_MAX" ] && b=$CORE_COUNTER_MAX
  printf -v line 'diagnostics truncated: children not kept %010d, bytes discarded at least %010d' "$c" "$b"
  tmp=$f.tmp.$$
  if printf '%-127s\n' "$line" >"$tmp" && mv -f "$tmp" "$f"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# core_diag_header ACTION RC KEPT DISCARDED — CORE_HDR: the fixed-width block
# header, its LF included.
core_diag_header() {
  printf -v CORE_HDR 'child\t%s\texit=%03d\tkept=%05d\tdiscarded=%d\n' "$1" "$2" "$3" "$4"
}

# ---------------------------------------------------------------------------
# Children, by class
# ---------------------------------------------------------------------------

# _core_worker_exec K CMD ARGS... — runs in the child's own (foreground)
# subshell: records its identity as req-N.worker-K, then becomes the child.
# In the foreground, the child keeps default signal dispositions (a
# background job would ignore SIGINT and SIGQUIT, with no way back).
_core_worker_exec() {
  local k=$1 pid
  shift
  # Bash 3.2 has no BASHPID: this subshell's PID is the PPID of a process
  # it execs in place of a command substitution.
  # shellcheck disable=SC2016 # expanded by the child shell
  pid=$(exec "$BASH" -c 'echo $PPID')
  core_proc_write "$CORE_SESSION/req-$CORE_N.worker-$k" worker "$pid" || exit 125
  exec "$@"
}

# core_child ACTION ARGS... — runs ACTION's registered child as its class
# says. CORE_CHILD_RC: its exit status. Gate 1 runs only the test children,
# only in fixture mode.
core_child() {
  local action=$1 cmd
  shift
  core_registry_entry "$action" || { CORE_CHILD_WHY="no reviewed registry entry for $action${CORE_REG_WHY:+: $CORE_REG_WHY}"; return 1; }
  case "$action" in
    test.*) [ -n "${OMB_FIXTURE:-}" ] || { CORE_CHILD_WHY="test children run only in fixture mode"; return 1; } ;;
    *) CORE_CHILD_WHY="no baseline child is exposed in this gate"; return 1 ;;
  esac
  cmd=$OMB_HOME/$CC_CMD
  if [ "$CC_CLASS" = handoff ] && [ -n "${OMB_TEST_HANDOFF_CHILD:-}" ]; then
    cmd=$OMB_TEST_HANDOFF_CHILD
  fi
  [ -x "$cmd" ] || { CORE_CHILD_WHY="the child program is not executable"; return 1; }
  CORE_WORKERS=$((CORE_WORKERS + 1))
  CORE_CHILD_CMD=$(quote_argv "$cmd" "$@")
  case "$CC_CLASS" in
    read) core_child_read "$action" "$cmd" "$@" ;;
    mutating)
      # No pipe and no file that can fill: nothing can block or end it.
      (_core_worker_exec "$CORE_WORKERS" "$cmd" "$@") </dev/null >/dev/null 2>&1
      CORE_CHILD_RC=$?
      ;;
    handoff)
      # The terminal, never captured.
      (_core_worker_exec "$CORE_WORKERS" "$cmd" "$@")
      CORE_CHILD_RC=$?
      ;;
  esac
  return 0
}

# core_child_read ACTION CMD ARGS... — a read child: stdout functional, into
# a file bounded by RLIMIT_FSIZE (64 KiB); stderr drained continuously by
# tail -c 65281 (or counted and discarded when there is no room), then one
# block of at most the room reserved before it started.
core_child_read() {
  local action=$1 cmd=$2 fifo cap cnt ready drain room kept discarded=0 n st
  shift 2
  fifo=$OMB_TMP/diag-fifo
  cap=$CORE_SESSION/req-$CORE_N.capture
  cnt=$OMB_TMP/diag-count
  ready=$OMB_TMP/diag-ready
  CORE_FUNC=$OMB_TMP/functional
  CORE_DIAG_NOTE=""
  rm -f "$fifo" "$ready" "$cap" "$cnt"
  core_diag_header "$action" 0 0 0
  n=${#CORE_HDR}
  CORE_SAT=0
  if ! core_diag_room; then
    CORE_SAT=1
  elif [ "$CORE_ROOM" -lt $((n + 1)) ]; then
    CORE_SAT=1
  fi
  room=${CORE_ROOM:-0}
  # The drain runs beside the child. It is the core's own tool, not a
  # worker, so it may run as a background job.
  if mkfifo -m 600 "$fifo" 2>/dev/null; then
    exec 7<>"$fifo"
    if [ "$CORE_SAT" = 1 ]; then
      { : >"$ready" && exec wc -c; } <"$fifo" >"$cnt" 7<&- &
    else
      { : >"$ready" && exec tail -c "$CORE_DIAG_TAIL"; } <"$fifo" >"$cap" 7<&- &
    fi
    drain=$!
    # The drain has opened its end once it made the ready file; only then
    # does the core give up its own read end, so a drain that dies leaves the
    # child a closed pipe (SIGPIPE), never a full one.
    _core_until ready "$ready"
    exec 8>"$fifo"
    exec 7<&-
    (
      ulimit -f 64
      _core_worker_exec "$CORE_WORKERS" "$cmd" "$@"
    ) </dev/null >"$CORE_FUNC" 2>&8 8>&-
    CORE_CHILD_RC=$?
    exec 8>&-
    # The output ends when the child and anything holding its stderr close
    # it. A descendant that keeps it open is not waited for.
    _core_until gone "$drain"
    if kill -0 "$drain" 2>/dev/null; then
      kill "$drain" 2>/dev/null
      wait "$drain" 2>/dev/null
      CORE_DIAG_NOTE="diagnostics not available: a process the child started still holds its output"
      rm -f "$cap"
    else
      wait "$drain"
      st=$?
      [ "$st" = 0 ] || CORE_DIAG_NOTE="diagnostics not available: the drain failed"
    fi
    rm -f "$fifo" "$ready"
  else
    # No drain could be made: the child's diagnostics are discarded.
    (
      ulimit -f 64
      _core_worker_exec "$CORE_WORKERS" "$cmd" "$@"
    ) </dev/null >"$CORE_FUNC" 2>/dev/null
    CORE_CHILD_RC=$?
    CORE_DIAG_NOTE="diagnostics not available: no drain"
  fi
  [ -n "$CORE_DIAG_NOTE" ] && return 0
  if [ "$CORE_SAT" = 1 ]; then
    n=0
    read -r n <"$cnt" 2>/dev/null
    case "$n" in '' | *[!0-9]*) n=0 ;; esac
    core_diag_saturated "$n"
    return 0
  fi
  _core_size "$cap" || { CORE_DIAG_NOTE="diagnostics not available" && rm -f "$cap" && return 0; }
  kept=$CORE_SIZE
  local lost=0
  if [ "$kept" -gt "$CORE_DIAG_KEEP" ]; then
    discarded=1 lost=$((kept - CORE_DIAG_KEEP)) kept=$CORE_DIAG_KEEP
  fi
  core_diag_header "$action" "$CORE_CHILD_RC" 0 0
  n=${#CORE_HDR}
  if [ $((n + kept)) -gt "$room" ]; then
    lost=$((lost + kept - (room - n))) kept=$((room - n)) discarded=1
  fi
  local diag=$CORE_SESSION/req-$CORE_N.diag sum=$CORE_SESSION/req-$CORE_N.diag-summary
  # The request's summary exists from its first kept block (its 128 bytes
  # were reserved with it).
  if [ ! -f "$sum" ]; then
    core_summary_write "$sum" 0 0 || CORE_DIAG_NOTE="diagnostics not available: the summary could not be written"
  fi
  if [ -z "$CORE_DIAG_NOTE" ]; then
    core_diag_header "$action" "$CORE_CHILD_RC" "$kept" "$discarded"
    {
      printf '%s' "$CORE_HDR"
      tail -c "$kept" "$cap"
    } >>"$diag" 2>/dev/null || CORE_DIAG_NOTE="diagnostics not available: the block could not be written"
    [ "$lost" -gt 0 ] && core_summary_write "$sum" 0 "$lost"
  fi
  rm -f "$cap"
  CORE_DIAG_KEPT=$kept
}

# core_diag_saturated BYTES — the child kept nothing: counted in the request's
# summary when it has one, else in the session's. A request whose file would
# need room the session lacks creates no file at all.
core_diag_saturated() {
  local sum=$CORE_SESSION/req-$CORE_N.diag-summary
  if [ -f "$sum" ]; then
    core_summary_write "$sum" 1 "$1"
  else
    core_summary_write "$CORE_SESSION/session.diag-summary" 1 "$1"
  fi
  CORE_DIAG_KEPT=0
  CORE_DIAG_NOTE="diagnostics not kept: the limit is reached"
}

# ---------------------------------------------------------------------------
# Operation records and the barrier (docs/PROTOCOL.md → *Operations and exclusion*)
# ---------------------------------------------------------------------------

core_op_path() { printf '%s/ops/%s.omb' "$OMB_STATE_DIR" "$1"; }

# core_op_write SCOPE ACTION BASIS STATE — the scope's operation record,
# checked and sealed, renamed into place; 1 when it cannot be written (the
# action then stops, as state_must_set does).
core_op_write() {
  local f tmp
  state_dir_ready || return 1
  [ -L "$OMB_STATE_DIR/ops" ] && return 1
  (umask 077 && mkdir -p "$OMB_STATE_DIR/ops") || return 1
  f=$(core_op_path "$1")
  tmp=$(mktemp "$OMB_STATE_DIR/ops/.$1.XXXXXX") || return 1
  if {
    printf 'omb-op 1\n' &&
      rec_line op action "$2" scope "$1" basis "$3" session "$CORE_SESSION" state "$4" pid "$$" \
        start "$(_proc_started "$$")" boot "$CORE_BOOT" at "$(now_utc)"
  } >"$tmp" && rec_seal_write "$tmp" && mv -f "$tmp" "$f"; then
    log_event record "operation $2 ($4) in scope $1"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# core_op_read SCOPE — 0 none; 1 a record (CO_* set); 2 a record that cannot
# be admitted (a barrier: nothing can be established from it).
core_op_read() {
  local f
  f=$(core_op_path "$1")
  CO_ACTION="" CO_BASIS="" CO_SESSION="" CO_STATE="" CO_PID="" CO_START="" CO_BOOT=""
  [ -e "$f" ] || [ -L "$f" ] || return 0
  _state_file_ok "$f" || return 2
  rec_admit_file op - "$f" || return 2
  CO_ACTION=$(rec_get 0 action) CO_BASIS=$(rec_get 0 basis) CO_SESSION=$(rec_get 0 session)
  CO_STATE=$(rec_get 0 state) CO_PID=$(rec_get 0 pid) CO_START=$(rec_get 0 start) CO_BOOT=$(rec_get 0 boot)
  return 1
}

core_op_remove() { state_remove_file "ops/$1.omb"; }

# core_barrier SCOPE — CORE_BAR: none, busy (a live core supervises it),
# unsupervised (a barrier for this boot), stale (from an earlier boot:
# reconciliation may run), or corrupt; CORE_BAR_ACTION names the operation.
core_barrier() {
  local rc
  CORE_BAR=none CORE_BAR_ACTION=""
  core_op_read "$1"
  rc=$?
  [ "$rc" = 0 ] && return 0
  if [ "$rc" = 2 ]; then
    CORE_BAR=corrupt
    return 0
  fi
  CORE_BAR_ACTION=$CO_ACTION
  if [ -z "$CORE_BOOT" ]; then
    # This boot cannot be identified: nothing is cleared on its strength.
    CORE_BAR=unsupervised
    [ "$CO_STATE" = running ] && CORE_BAR=busy
    return 0
  fi
  if [ "$CO_BOOT" != "$CORE_BOOT" ]; then
    CORE_BAR=stale
    return 0
  fi
  if [ "$CO_STATE" = running ]; then
    core_alive "$CO_PID" "$CO_START" "$CO_BOOT"
    case $? in
      0 | 2) CORE_BAR=busy ;;
      *) CORE_BAR=unsupervised ;;
    esac
    return 0
  fi
  CORE_BAR=unsupervised
}

# core_reconcile SCOPE — after a new boot: the scope's own judgement of what
# the unsupervised operation left. CORE_FINDING: no-effect, completed or
# unexpected. The first two remove the record; the third keeps the scope
# blocked. A reboot is never itself counted as success.
core_reconcile() {
  local scope=$1 effect want
  CORE_FINDING=unexpected
  case "$CO_ACTION" in
    test.mutate | test.handoff)
      effect=$(core_test_effect "$CO_ACTION")
      want=${CO_BASIS:0:16}
      if [ ! -e "$effect" ] && [ ! -L "$effect" ]; then
        CORE_FINDING=no-effect
      elif [ -f "$effect" ] && [ ! -L "$effect" ] && [ "$(cat "$effect")" = "$want" ]; then
        CORE_FINDING=completed
      fi
      ;;
  esac
  log_event reconcile "$CO_ACTION in scope $scope: $CORE_FINDING"
  case "$CORE_FINDING" in
    no-effect | completed)
      state_must_set "op_${scope}_finding" "$CO_ACTION $CORE_FINDING $(now_utc)" || return 1
      core_op_remove "$scope" || return 1
      return 0
      ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# The foundation's test actions (fixture mode only)
# ---------------------------------------------------------------------------

# core_action_info ACTION — CA_SCOPE CA_INTENT CA_TERMINAL CA_CANCEL CA_GATE
# CA_LABEL CA_EXPLAIN CA_LIMIT; 1 for an action this core does not have.
core_action_info() {
  CA_SCOPE=journey CA_GATE="" CA_CANCEL=0 CA_LIMIT=3
  case "$1" in
    test.read)
      CA_INTENT=read CA_TERMINAL=managed CA_CANCEL=1 CA_LABEL="Read the fixture (test)"
      CA_EXPLAIN="Runs the fake read child: its output is shown, its diagnostics kept within their limits."
      ;;
    test.mutate)
      CA_INTENT=act CA_TERMINAL=managed CA_GATE=test CA_LABEL="Change the fixture (test)"
      CA_EXPLAIN="Runs the fake mutating child under supervision; it writes one file in the test state folder."
      ;;
    test.handoff)
      CA_INTENT=act CA_TERMINAL=handoff CA_GATE=test CA_LABEL="Hand over the terminal (test)"
      CA_EXPLAIN="Runs the fake handoff child in the foreground on the real terminal, then reads the result."
      ;;
    *) return 1 ;;
  esac
  # Test actions exist only in fixture mode.
  [ -n "${OMB_FIXTURE:-}" ]
}

CORE_TEST_ACTIONS="test.read test.mutate test.handoff"

core_test_effect() {
  case "$1" in
    test.mutate) printf '%s/test/effect-mutate' "$OMB_STATE_DIR" ;;
    test.handoff) printf '%s/test/effect-handoff' "$OMB_STATE_DIR" ;;
  esac
}

# core_basis ACTION — CORE_BASIS: the SHA-256 of the action's canonical
# omb-basis document, built from a fresh read (docs/PROTOCOL.md → *The basis*).
core_basis() {
  local doc
  # A function, not a case inside $( ): /bin/bash 3.2 cannot parse that.
  doc=$(_core_basis_doc "$1")
  CORE_BASIS=$(sha256_str "omb-basis 1
$doc
")
}

_core_basis_doc() {
  local effect sha="" state=absent
  rec_line basis action "$1" proto "$REC_PROTO" actor_uid "$OMB_UID" home "$OMB_HOME" source "$CORE_SOURCE"
  case "$1" in
    test.mutate | test.handoff)
      effect=$(core_test_effect "$1")
      if [ -L "$effect" ]; then
        state='link'
      elif [ -f "$effect" ]; then
        state=file sha=$(sha256_of "$effect")
      elif [ -e "$effect" ]; then
        state=present
      fi
      rec_line seen key effect state "$state" value "" sha256 "$sha" mode "" link ""
      ;;
  esac
}

# core_available ACTION [held] — 0 when the fresh read lists ACTION now:
# within the ceiling and the scopes, and not behind a barrier in its scope.
# "held": the caller already holds the scope (its own operation record is
# written), so the barrier was settled at exclusion.
core_available() {
  core_action_info "$1" || return 1
  core_in_scopes "$CA_SCOPE" || return 1
  core_intent_allows "$CA_INTENT" || return 1
  [ "$CA_INTENT" = act ] || return 0
  [ "${2:-}" = held ] && return 0
  core_barrier "$CA_SCOPE"
  case "$CORE_BAR" in none | stale) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------
# The executed source (docs/QUALIFICATION.md → *What ran*)
# ---------------------------------------------------------------------------

# core_source — CORE_SOURCE: the SHA-256 of the omb-source listing of the
# tool's own files (the entrypoint, lib/, data/, release/frontend.lock).
core_source() {
  local list sums st
  list=$OMB_TMP/source-files
  sums=$OMB_TMP/source-sums
  (
    cd "$OMB_HOME" || exit 1
    {
      printf 'omarchy-bootstrap\n'
      find lib data -type f 2>/dev/null
      [ -f release/frontend.lock ] && printf 'release/frontend.lock\n'
    } | LC_ALL=C sort
  ) >"$list" || return 1
  (
    cd "$OMB_HOME" || exit 1
    # One hashing process for every file, in the listing's order.
    # shellcheck disable=SC2046 # the listing holds plain relative paths
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 $(cat "$list")
    else
      sha256sum $(cat "$list")
    fi
  ) >"$sums"
  st=$?
  [ "$st" = 0 ] || return 1
  CORE_SOURCE=$(
    printf 'omb-source 1\n'
    awk '{ printf "%s\t%s\n", $2, $1 }' "$sums"
  )
  CORE_SOURCE=$(sha256_str "$CORE_SOURCE
")
  _whole "$CORE_SOURCE" '^[0-9a-f]{64}$'
}

# ---------------------------------------------------------------------------
# The request's life
# ---------------------------------------------------------------------------

core_on_term() { CORE_CANCEL=1; }
# Ctrl-C reaches the whole group during a handoff: the child acts on it as
# its author intended; the core notes it and still judges the outcome from
# the machine, as the baseline does after a launched command.
core_on_int() { CORE_INTERRUPTED=1; }

core_exit() {
  [ -n "$CORE_SESSION" ] && [ -n "$CORE_N" ] && rm -f "$CORE_SESSION/req-$CORE_N.core"
  omb_cleanup
}

# core_hello — the hello record: who answers, for which session.
core_hello() {
  local commit arch ceiling=${OMB_SESSION_INTENT:-} dry=${OMB_CORE_ENV_DRY:-} user=user fixture=0
  commit=$(sys_cmd git_head git -C "$OMB_HOME" rev-parse HEAD)
  _whole "$commit" '^[0-9a-f]{40}$' || commit=""
  case "$OMB_PLATFORM" in
    macos) arch=$(sys_cmd uname_m uname -m) ;;
    linux) arch=$(sys_cmd uname_m uname -m) ;;
    *) return 1 ;;
  esac
  case "$OMB_PLATFORM:$arch" in macos:arm64 | linux:aarch64) ;; *) return 1 ;; esac
  # A malformed session value is refused; the hello shows the safest reading.
  case "$ceiling" in read | plan | act) ;; *) ceiling='read' ;; esac
  case "$dry" in 0 | 1) ;; *) dry=1 ;; esac
  [ "$OMB_UID" = 0 ] && user=root
  [ -n "${OMB_FIXTURE:-}" ] && fixture=1
  core_emit hello core "$OMB_VERSION" commit "$commit" source "$CORE_SOURCE" proto "$REC_PROTO" \
    platform "$OMB_PLATFORM" arch "$arch" user "$user" ceiling "$ceiling" dry_run "$dry" fixture "$fixture"
}

# core_lock_version — CORE_LOCK_VERSION: the frontend version the reviewed
# lock names, or empty when there is no admissible lock.
core_lock_version() {
  CORE_LOCK_VERSION=""
  [ -f "$OMB_HOME/release/frontend.lock" ] || return 1
  rec_admit_file lock - "$OMB_HOME/release/frontend.lock" || return 1
  rec_find frontend || return 1
  CORE_LOCK_VERSION=$(rec_get "$REC_AT_I" version)
}

# core_main OP REQUEST_COPY HEAD_STATUS — one request, one answer.
core_main() {
  local op=$1 copy=$2 hst=$3 rop fe proto
  OMB_INTENT=read OMB_PERSIST=0
  umask 077
  platform_init
  if ! core_env_check && [ -z "$CORE_EVENTS" ]; then
    printf 'omarchy-bootstrap core: %s; no answer can be written.\n' "$CORE_ENV_WHY" >&2
    return 2
  fi
  OMB_DRY_RUN=${OMB_CORE_ENV_DRY:-1}
  case "$OMB_DRY_RUN" in 0 | 1) ;; *) OMB_DRY_RUN=1 ;; esac
  trap core_exit EXIT
  trap core_on_int INT QUIT
  trap core_on_term TERM HUP
  state_init || return 2
  core_boot_read
  if [ -n "$CORE_BOOT" ] && [ -n "$CORE_N" ]; then
    core_proc_write "$CORE_SESSION/req-$CORE_N.core" core "$$" || true
  fi
  if ! core_source; then
    printf 'omarchy-bootstrap core: the executed source cannot be read; no answer can be written.\n' >&2
    return 2
  fi
  if ! core_hello; then
    printf 'omarchy-bootstrap core: this system (%s) cannot be described; no answer can be written.\n' "${OMB_OS:-unknown}" >&2
    return 2
  fi
  if [ -n "$CORE_ENV_WHY" ]; then
    core_result error environment "$CORE_ENV_WHY"
    return 2
  fi
  # 1. Admission, byte by byte, before anything splits the request.
  if [ "$hst" != 0 ] || [ ! -f "$copy" ]; then
    core_result error io "The request could not be read."
    return 2
  fi
  if ! rec_admit_copied req - "$copy"; then
    core_result error "$REC_REASON" "The request was refused at line $REC_AT ($REC_REASON)."
    return 2
  fi
  rop=$(rec_get 0 op)
  if [ "$rop" != "$op" ]; then
    core_result error schema "The request's operation is not the one the core was started for."
    return 2
  fi
  proto=$(rec_get 0 proto)
  if [ "$proto" != "$REC_PROTO" ]; then
    core_result refused protocol "This core speaks protocol $REC_PROTO, not $proto."
    return 3
  fi
  fe=$(rec_get 0 frontend)
  core_lock_version
  if [ "$fe" != "$CORE_LOCK_VERSION" ] && ! { [ -n "${OMB_FIXTURE:-}" ] && [ -n "${OMB_FRONTEND_DEV:-}" ]; }; then
    if [ -n "$CORE_LOCK_VERSION" ]; then
      core_result refused frontend "The reviewed lock names frontend $CORE_LOCK_VERSION, not $fe."
    else
      core_result refused frontend "No frontend release is pinned by this checkout; an unreleased frontend runs only against fixtures."
    fi
    return 3
  fi
  case "$op" in
    hello) core_result "done" ok ;;
    snapshot) core_op_snapshot ;;
    detail | validate) core_result refused unavailable "Nothing in this gate pages details or validates parameters." ;;
    execute) core_op_execute ;;
  esac
  return 0
}

# core_op_snapshot — the journey scope of the foundation: its facts, the
# barrier if any, and the actions available now.
core_op_snapshot() {
  local scope body a gen
  rec_find scope && scope=$(rec_get "$REC_AT_I" name)
  if ! core_in_scopes "$scope"; then
    core_result refused scope "This session does not include the $scope scope."
    return
  fi
  if [ -z "${OMB_FIXTURE:-}" ] || [ "$scope" != journey ]; then
    core_result refused unavailable "This gate's frontend reads only the foundation's fixtures; use the text interface (--no-tui)."
    return
  fi
  core_barrier journey
  body=$(_core_snapshot_body)
  gen=$(sha256_str "$body")
  core_emit generation id "$gen" total 0
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    printf '%s\n' "$a" >>"$CORE_EVENTS" || return 1
    CORE_BYTES=$((CORE_BYTES + ${#a} + 1)) CORE_RECS=$((CORE_RECS + 1))
  done <<EOF
$body
EOF
  core_result "done" ok
}

# _core_snapshot_body — the journey snapshot's records after its generation,
# in the response schema's order (a function: /bin/bash 3.2 cannot parse a
# case inside $( )).
_core_snapshot_body() {
  local a
  rec_line fact scope journey key foundation label "Interface" value "the foundation: test actions over fixtures" state info
  rec_line fact scope journey key fixture label "Fixture" value "${OMB_FIXTURE##*/}" state info
  case "$CORE_BAR" in
    none) rec_line fact scope journey key operation label "Operation" value "none" state ok ;;
    busy) rec_line fact scope journey key operation label "Operation" value "$CORE_BAR_ACTION running" state info ;;
    stale) rec_line fact scope journey key operation label "Operation" value "$CORE_BAR_ACTION from an earlier boot, to reconcile" state warn ;;
    *) rec_line fact scope journey key operation label "Operation" value "${CORE_BAR_ACTION:-unknown} unsupervised" state fail ;;
  esac
  case "$CORE_BAR" in
    unsupervised | corrupt)
      rec_line blocker id unsupervised text "The outcome of ${CORE_BAR_ACTION:-an operation} is unknown and a process it started may still be running." \
        fix "Restart this Mac (or this Linux system), then run the tool again."
      ;;
  esac
  for a in $CORE_TEST_ACTIONS; do
    core_available "$a" || continue
    core_action_info "$a"
    core_basis "$a"
    rec_line action id "$a" scope "$CA_SCOPE" label "$CA_LABEL" intent "$CA_INTENT" gate "$CA_GATE" \
      terminal "$CA_TERMINAL" cancel "$CA_CANCEL" basis "$CORE_BASIS" explain "$CA_EXPLAIN"
  done
}

# core_op_execute — docs/PROTOCOL.md → §5, *Executing*, in its order,
# stopping at the first refusal.
core_op_execute() {
  local action basis confirm i
  rec_find exec || { core_result error schema; return; }
  action=$(rec_get "$REC_AT_I" action) basis=$(rec_get "$REC_AT_I" basis) confirm=$(rec_get "$REC_AT_I" confirm)
  # 1. Every argument must be one the action declares; the test actions
  # declare none.
  i=0
  while [ "$i" -lt "$REC_N" ]; do
    if [ "${REC_T[i]}" = arg ]; then
      core_result refused invalid "$action takes no parameters."
      return
    fi
    i=$((i + 1))
  done
  if ! core_action_info "$action"; then
    core_result refused unavailable "$action is not an action of this core."
    return
  fi
  # 2. The session allows it.
  if ! core_intent_allows "$CA_INTENT"; then
    core_result refused ceiling "$action changes the machine; this session may only $OMB_SESSION_INTENT."
    return
  fi
  if ! core_in_scopes "$CA_SCOPE"; then
    core_result refused scope "$action is outside this session's scopes."
    return
  fi
  if [ "$CA_INTENT" = act ]; then
    OMB_INTENT=act
    [ "$OMB_DRY_RUN" = 1 ] || OMB_PERSIST=1
    core_execute_act "$action" "$basis" "$confirm"
  else
    core_execute_read "$action" "$basis" "$confirm"
  fi
}

# core_check_word WORD — the typed word equals the gate word exactly; an
# action without a gate takes no word.
core_check_word() {
  if [ -z "$CA_GATE" ]; then
    [ -z "$1" ] && return 0
    core_result refused word "This action takes no typed word."
    return 1
  fi
  [ "$1" = "$CA_GATE" ] && return 0
  core_result refused word "Only the exact word \"$CA_GATE\" continues."
  return 1
}

# _core_test_knob NAME — a whole number the fixture sets for the core's own
# side of a test action ($OMB_FIXTURE/test-children/core: progress, children),
# or empty.
_core_test_knob() {
  local f=${OMB_FIXTURE:-}/test-children/core v
  [ -n "${OMB_FIXTURE:-}" ] && [ -f "$f" ] || return 0
  v=$(sed -n "s/^$1=//p" "$f" | tail -n 1)
  case "$v" in '' | *[!0-9]* | ????????*) return 0 ;; esac
  printf '%s' "$v"
}

core_execute_read() {
  local action=$1 basis=$2 confirm=$3 line n i=0 total failed=0 notes=0 kept=0
  # Read requests hold nothing: no lock, no operation record.
  core_basis "$action"
  if [ "$CORE_BASIS" != "$basis" ]; then
    core_result refused changed "What $action depends on changed since it was shown."
    return
  fi
  core_check_word "$confirm" || return
  # The fixture may ask for many progress records (the spool's bound) and
  # many children in one request (the request's diagnostic bound).
  n=$(_core_test_knob progress)
  while [ "$i" -lt "${n:-0}" ]; do
    i=$((i + 1))
    core_emit progress action "$action" "done" "$i" total "$n" unit record label ""
  done
  total=$(_core_test_knob children)
  total=${total:-1}
  i=0
  while [ "$i" -lt "$total" ]; do
    i=$((i + 1))
    if ! core_child "$action"; then
      core_result failed child "$CORE_CHILD_WHY"
      return
    fi
    [ "$CORE_CHILD_RC" = 0 ] || failed=$((failed + 1))
    [ -n "$CORE_DIAG_NOTE" ] && notes=$((notes + 1))
    kept=$((kept + ${CORE_DIAG_KEPT:-0}))
    [ "$CORE_CANCEL" = 1 ] && break
  done
  line=$(head -c 200 "$CORE_FUNC" 2>/dev/null | head -1 | tr -cd '[:alnum:] ._:/,+-')
  [ -n "$line" ] && core_message info "$line"
  if [ -n "$CORE_DIAG_NOTE" ]; then
    core_message warn "$CORE_DIAG_NOTE"
  else
    core_message info "diagnostics kept: $kept bytes from $i child(ren)"
  fi
  if [ "$CORE_CANCEL" = 1 ]; then
    core_result cancelled cancelled "$i of $total read children ran; nothing else was started."
  elif [ "$failed" = 0 ]; then
    core_result "done" ok
  else
    core_result failed child "The read child exited with status $CORE_CHILD_RC."
  fi
}

# core_execute_act ACTION BASIS WORD — steps 3 to 8 for an act action.
core_execute_act() {
  local action=$1 basis=$2 confirm=$3 scope=$CA_SCOPE effect want q
  # 3. Exclusion: the run lock, then the scope's operation record, then this
  # action's own record — before anything is read for the decision.
  if [ "$OMB_PERSIST" = 1 ]; then
    if ! state_lock >/dev/null 2>&1; then
      core_result refused busy "Another run holds the lock."
      return
    fi
  fi
  core_barrier "$scope"
  case "$CORE_BAR" in
    busy)
      core_result refused busy "$CORE_BAR_ACTION is still running under a live core."
      return
      ;;
    unsupervised | corrupt)
      core_result refused unsupervised "The outcome of ${CORE_BAR_ACTION:-an operation} is unknown and it may still be running: restart this Mac (or this Linux system), then run the tool again."
      return
      ;;
    stale)
      if [ "$OMB_PERSIST" != 1 ]; then
        core_result refused unsupervised "An earlier boot's ${CORE_BAR_ACTION:-operation} must be reconciled first, by a run that is not a dry run."
        return
      fi
      if ! core_reconcile "$scope"; then
        core_result refused unsupervised "After the restart, ${CORE_BAR_ACTION:-the operation} left something unexpected: the machine shows neither its old state nor its expected effect. It needs you."
        return
      fi
      core_message info "An earlier boot's $CO_ACTION was reconciled: $CORE_FINDING."
      ;;
  esac
  if [ "$OMB_PERSIST" = 1 ] && [ -z "$CORE_BOOT" ]; then
    core_result refused unavailable "This boot session cannot be identified, so no operation can be supervised."
    return
  fi
  if [ "$OMB_PERSIST" = 1 ] && ! core_op_write "$scope" "$action" "$basis" running; then
    core_result refused unavailable "The operation record could not be written; nothing ran."
    return
  fi
  # 4–7. A fresh read, available now, the basis rebuilt, the typed word.
  if ! core_available "$action" held; then
    core_op_remove "$scope"
    core_result refused unavailable "$action is not available now."
    return
  fi
  if [ "$CA_TERMINAL" = handoff ] && { [ ! -t 0 ] || [ ! -t 1 ]; }; then
    core_op_remove "$scope"
    core_result refused unavailable "A handoff needs the terminal on its input and output."
    return
  fi
  core_basis "$action"
  if [ "$CORE_BASIS" != "$basis" ]; then
    core_op_remove "$scope"
    core_result refused changed "What $action depends on changed since it was shown."
    return
  fi
  if ! core_check_word "$confirm"; then
    core_op_remove "$scope"
    return
  fi
  effect=$(core_test_effect "$action")
  want=${basis:0:16}
  # 8. The run itself, supervised.
  if [ "$OMB_DRY_RUN" = 1 ]; then
    core_message info "would run $OMB_HOME/$(core_registry_entry "$action" >/dev/null && printf '%s' "$CC_CMD") $effect $want"
    core_result "done" dry-run "Dry run: nothing was run."
    return
  fi
  (umask 077 && mkdir -p "$OMB_STATE_DIR/test") || {
    core_op_remove "$scope"
    core_result refused unavailable "The test state folder could not be made; nothing ran."
    return
  }
  if ! core_group_snapshot; then
    core_op_remove "$scope"
    core_result refused unavailable "The process table could not be read, so the child could not be supervised; nothing ran."
    return
  fi
  if [ "$CA_TERMINAL" = handoff ]; then
    ui_section "Test handoff" "the terminal is the child's until it exits"
  fi
  # The fixture may ask for many progress records while the frontend
  # follows the spool (for a handoff, while it has stepped aside).
  local p=0 np
  np=$(_core_test_knob progress)
  while [ "$p" -lt "${np:-0}" ]; do
    p=$((p + 1))
    core_emit progress action "$action" "done" "$p" total "$np" unit record label ""
  done
  if ! core_child "$action" "$effect" "$want"; then
    core_op_remove "$scope"
    core_result failed child "$CORE_CHILD_WHY"
    return
  fi
  [ "$CORE_INTERRUPTED" = 1 ] && core_message warn "Stopped while running $action: it may have made changes; the machine is read below."
  # Worker quiescence: every process in the group was in the snapshot (L, F
  # and C are there, and stay); the reading's own is not a worker.
  core_quiescent "$CA_LIMIT"
  q=$?
  if [ "$q" != 0 ]; then
    core_op_write "$scope" "$action" "$basis" unsupervised
    if [ "$q" = 1 ]; then
      core_result stopped unsupervised "The outcome of $action is unknown: a process it started is still running. Every act in its scope is refused until this Mac (or this Linux system) restarts." \
        "Restart, then run the tool again."
    else
      core_result stopped unsupervised "The outcome of $action is unknown: the process table could not be read." "Restart, then run the tool again."
    fi
    return
  fi
  # The postcondition, on a fresh read; then the result recorded; then the
  # record removed — in that order.
  if [ -f "$effect" ] && [ ! -L "$effect" ] && [ "$(cat "$effect")" = "$want" ]; then
    state_must_set test_last_result "$action done $(now_utc)" || {
      core_op_write "$scope" "$action" "$basis" unsupervised
      core_result stopped unsupervised "The result could not be recorded."
      return
    }
    core_op_remove "$scope"
    core_result "done" ok "" ""
  else
    state_must_set test_last_result "$action failed $(now_utc)" || {
      core_op_write "$scope" "$action" "$basis" unsupervised
      core_result stopped unsupervised "The result could not be recorded."
      return
    }
    core_op_remove "$scope"
    core_result failed postcondition "The machine does not show $action's effect (the child exited with status $CORE_CHILD_RC)." \
      "Run by hand to see its output: $CORE_CHILD_CMD"
  fi
}
