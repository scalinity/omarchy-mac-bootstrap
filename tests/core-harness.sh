# shellcheck shell=bash
# Drives the core (`omarchy-bootstrap core OP`) as the frontend drives it: a
# private session folder, a spool holding only its header, the request on
# fd 3, a sealed environment. Sourced by tests/test-core.sh and
# tests/test-diag.sh after tests/lib.sh; set T (a temporary folder) first.

S=0123456789abcdef

# c_session — a fresh session folder, 0700, as the launcher makes it.
c_session() {
  SESS=$(mktemp -d "$T/omb-session.XXXXXX") && chmod 700 "$SESS"
  C_N=0
}

# c_fixture — a throwaway copy of the roomy M1 Pro fixture (the fake children read
# their behaviour from it; nothing writes into the committed ones).
c_fixture() { C_FIX=$(t_variant mac-m1pro-1tb-roomy); mkdir -p "$C_FIX/test-children"; }

# c_conf CHILD KEY=VALUE... — a fake child's behaviour in the fixture ("core"
# for the core's own side: progress, children).
c_conf() {
  local child=$1
  shift
  printf '%s\n' "$@" >"$C_FIX/test-children/$child"
}

# c_prepare OP RECORD... — the next request's spool (created with its header,
# as the frontend does) and its request file, $T/request-N.
c_prepare() {
  local op=$1 r
  shift
  C_N=$((C_N + 1))
  C_EV=$SESS/req-$C_N.events
  printf 'omb-res 1\n' >"$C_EV"
  chmod 600 "$C_EV"
  {
    printf 'omb-req 1\nreq\top=%s\tproto=1\tfrontend=%s\tsession=%s\n' "$op" "${C_FE:-0.1.0}" "$S"
    for r in "$@"; do printf '%s\n' "$r"; done
  } >"$T/request-$C_N"
}

# c_run OP RECORD... — one request, run to its end. Sets C_RC, C_OUT (the
# spool), C_ERR (stderr), C_EV (the spool's path).
c_run() {
  local op=$1
  shift
  c_prepare "$op" "$@"
  c_run_raw "$op" "$T/request-$C_N"
}

# c_run_raw OP FILE — the core under $C_BASH (default: the bash under test)
# with the request FILE on fd 3 and only the environment below. C_ENV adds
# assignments; C_UNSET drops names; C_PATH replaces PATH; C_HOME runs
# another copy of the tool (one with a lock of its own); C_WRAP is a command
# the core is started by (its parent).
c_run_raw() {
  local op=$1 req=$2 v name
  local -a envs=(
    "PATH=${C_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" "HOME=$T/home" "TMPDIR=$T" "LANG=en_US.UTF-8" "TERM=dumb"
    "OMB_HOME=${C_HOME:-$REPO}" "OMB_SESSION_INTENT=act" "OMB_SESSION_SCOPES=journey" "OMB_DRY_RUN=0"
    "OMB_SESSION_DIR=$SESS" "OMB_EVENTS=${C_EVENTS:-$C_EV}" "OMB_FIXTURE=$C_FIX" "OMB_STATE_DIR=$T/state"
    "OMB_FRONTEND_DEV=1"
  )
  local -a final=()
  # shellcheck disable=SC2086 # C_ENV is a list of assignments by design
  for v in "${envs[@]}" ${C_ENV:-}; do
    name=${v%%=*}
    case " ${C_UNSET:-} " in *" $name "*) continue ;; esac
    final+=("$v")
  done
  # shellcheck disable=SC2086 # C_WRAP is a command and its arguments
  ${C_WRAP:-} env -i "${final[@]}" "${C_BASH:-$T_BASH}" "${C_HOME:-$REPO}/omarchy-bootstrap" core "$op" 3<"$req" >/dev/null 2>"$T/stderr" </dev/null
  C_RC=$?
  C_ERR=$(cat "$T/stderr")
  C_OUT=$(cat "${C_EVENTS:-$C_EV}" 2>/dev/null)
}

# c_result — the result record's status and code, "status code".
c_result() {
  printf '%s\n' "$C_OUT" | awk -F'\t' '$1 == "result" { s = $2; c = $3; sub(/^status=/, "", s); sub(/^code=/, "", c); print s " " c }'
}

# c_admits OP — the spool is a whole, admissible response to OP.
c_admits() {
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    if rec_admit_file res "$1" "$C_EV"; then printf ok; else printf '%s:%s' "$REC_REASON" "$REC_AT"; fi
    omb_cleanup
  )
}

# c_basis ACTION — the basis a fresh snapshot shows for ACTION (empty when
# the snapshot does not list it).
c_basis() {
  c_run snapshot "scope	name=journey"
  printf '%s\n' "$C_OUT" | awk -F'\t' -v a="id=$1" '$1 == "action" && $2 == a { for (i = 2; i <= NF; i++) if ($i ~ /^basis=/) { sub(/^basis=/, "", $i); print $i } }'
}

# c_exec ACTION WORD [RECORD...] — execute ACTION with the basis it was shown.
c_exec() {
  local a=$1 w=$2 b
  shift 2
  b=$(c_basis "$a")
  [ -n "$b" ] || b=$(printf '%064d' 0)
  c_run execute "exec	action=$a	basis=$b	confirm=$w" "$@"
}

# c_wait_file FILE — wait up to 10 s for FILE to exist.
c_wait_file() {
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt 200 ]; do sleep 0.05 && i=$((i + 1)); done
  [ -e "$1" ]
}

# c_core_pid N — the PID request N's core recorded for itself.
c_core_pid() { sed -n 's/.*	pid=\([0-9]*\)	.*/\1/p' "$SESS/req-$1.core" 2>/dev/null; }

# c_rec KIND FILE KEY... — the KEYs of the sealed record FILE, a plain file
# admitted as the core admits one, "KEY=VALUE" to a line; 1 when it is not.
c_rec() {
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    kind=$1 file=$2
    shift 2
    if [ ! -f "$file" ] || [ -L "$file" ] || ! rec_admit_file "$kind" - "$file"; then
      omb_cleanup
      exit 1
    fi
    for k in "$@"; do
      rec_get_into v 0 "$k"
      printf '%s=%s\n' "$k" "$v"
    done
    omb_cleanup
  )
}

# c_ended PID START — the process recorded as PID and START has ended: the
# PID answers no signal, or is now a process started at another time. A PID
# that answers and whose start cannot be read has not.
c_ended() {
  local now
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ -n "$2" ] || return 1
  kill -0 "$1" 2>/dev/null || return 0
  now=$(t_started "$1")
  [ -n "$now" ] && [ "$now" != "$2" ]
}

# c_storm_exempt VERSION STATUS ROOT SESSION N MARKER — whether request N
# of a storm that did not complete died of Bash 5.2's upstream trap loss;
# only then is the fixture state that death left removed. 0 exempt (and
# cleared); 1 not, with nothing touched and C_WHY saying why. It reads the
# run as c_run_raw leaves it: ROOT/stderr, ROOT/request-N, the state in
# ROOT/state, the spool and identities in SESSION. VERSION is the
# major.minor of the shell that ran the core, STATUS its exit status, MARKER
# a file made just before the run.
#
# Bash 5.2 loses a trap that runs while a command holding two command
# substitutions is expanded, and the core dies of it with status 1 at that
# command (tests/bash-trap-comsub.sh; docs/TESTING.md → sup-eintr). In what
# the core runs, two commands hold two, both in the baseline's pinned files:
# lib/state.sh:269, the run lock's owner line, and lib/common.sh:155,
# log_event's. Each death leaves one of four states — every failure of 60
# storms on GNU Bash 5.2.21 left one, and no other:
#   state.sh:269   the lock taken, its owner not yet written: an empty
#                  folder made during the run, by the one core running; no
#                  record, worker or effect.
#   common.sh:155  the lock released by the core's EXIT trap; then either
#                  the running record just written (no worker, no effect),
#                  or the child ended (its worker dead, its effect the
#                  expected one) with that record still there or removed.
# A running record counts only as this request's own: admitted, this
# session, this basis, no finding, its core ended. Anything else — another
# shell, status or message, a result, a live or unreadable identity, another
# record or effect, a lock with an owner or from before the run — is the
# test's to judge, never skipped.
c_storm_exempt() {
  local ver=$1 st=$2 root=$3 sess=$4 n=$5 marker=$6 home=${C_HOME:-$REPO}
  local e1 e2 site f l basis rec pid start ops=none lock=none core=none workers=none effect=none w
  local lk=$root/state/lock opsf=$root/state/ops/journey.omb eff=$root/state/test/effect-mutate
  C_WHY=""
  if [ "$ver" != 5.2 ]; then
    C_WHY="the core ran under Bash $ver, not 5.2"
    return 1
  fi
  if [ "$st" != 1 ]; then
    C_WHY="the core exited $st, not 1"
    return 1
  fi
  if [ "$(awk 'END { print NR }' "$sess/req-$n.events" 2>/dev/null)" != 2 ] ||
    [ "$(awk -F'\t' 'NR == 2 { print $1 }' "$sess/req-$n.events")" != hello ]; then
    C_WHY="the spool holds more than its header and hello"
    return 1
  fi
  e1=$(sed -n 1p "$root/stderr")
  e2=$(sed -n 2p "$root/stderr")
  site=""
  if [ "$(awk 'END { print NR }' "$root/stderr")" = 2 ]; then
    for f in common:155 state:269; do
      l=${f#*:} f=${f%:*}
      if [ "$e1" = "$home/lib/$f.sh: trap: line 2: unexpected EOF while looking for matching \`)'" ] &&
        [ "$e2" = "$home/lib/$f.sh: $home/omarchy-bootstrap: line $l: unexpected EOF while looking for matching \`)'" ]; then
        # The command named is, in that pinned file, one holding two.
        # shellcheck disable=SC2016 # a literal $( looked for
        case "$(sed -n "${l}p" "$home/lib/$f.sh")" in *'$('*'$('*) site=$f:$l ;; esac
      fi
    done
  fi
  if [ -z "$site" ]; then
    C_WHY="stderr is not the trap loss at lib/common.sh:155 or lib/state.sh:269"
    return 1
  fi
  basis=$(awk -F'\t' '$1 == "exec" { for (i = 2; i <= NF; i++) if ($i ~ /^basis=/) { sub(/^basis=/, "", $i); print $i } }' "$root/request-$n")
  # The operation record.
  if [ -e "$opsf" ] || [ -L "$opsf" ]; then
    ops=other
    if rec=$(c_rec op "$opsf" action scope session basis state finding pid start); then
      pid=$(printf '%s\n' "$rec" | sed -n 's/^pid=//p')
      start=$(printf '%s\n' "$rec" | sed -n 's/^start=//p')
      if [ "$(printf '%s\n' "$rec" | sed -e '/^pid=/d' -e '/^start=/d')" = "$(printf 'action=test.mutate\nscope=journey\nsession=%s\nbasis=%s\nstate=running\nfinding=' "$sess" "$basis")" ] &&
        c_ended "$pid" "$start"; then
        ops=running
      fi
    fi
  fi
  # The run lock: none, or an empty folder (no owner written) made after
  # MARKER — during this run.
  if [ -d "$lk" ] && [ ! -L "$lk" ]; then
    lock=other
    if [ -z "$(ls -A "$lk")" ] && [ -f "$marker" ] && [ -n "$(find "$lk" -maxdepth 0 -newer "$marker")" ]; then lock=empty; fi
  elif [ -e "$lk" ] || [ -L "$lk" ]; then
    lock=other
  fi
  # The core's identity (its EXIT trap removes it) and its workers'.
  if [ -e "$sess/req-$n.core" ] || [ -L "$sess/req-$n.core" ]; then core=other; fi
  for w in "$sess/req-$n".worker-*; do
    [ -e "$w" ] || [ -L "$w" ] || continue
    [ "$workers" = other ] && continue
    workers=other
    if rec=$(c_rec proc "$w" pid start); then
      pid=$(printf '%s\n' "$rec" | sed -n 's/^pid=//p')
      start=$(printf '%s\n' "$rec" | sed -n 's/^start=//p')
      if c_ended "$pid" "$start"; then workers=dead; fi
    fi
  done
  if [ -e "$eff" ] || [ -L "$eff" ]; then
    effect=other
    if [ -f "$eff" ] && [ ! -L "$eff" ] && [ -n "$basis" ] && [ "$(cat "$eff")" = "${basis:0:16}" ]; then effect=expected; fi
  fi
  case "$site ops=$ops lock=$lock core=$core workers=$workers effect=$effect" in
    "state:269 ops=none lock=empty core=none workers=none effect=none") ;;
    "common:155 ops=running lock=none core=none workers=none effect=none") ;;
    "common:155 ops=running lock=none core=none workers=dead effect=expected") ;;
    "common:155 ops=none lock=none core=none workers=dead effect=expected") ;;
    *)
      C_WHY="the trap loss at $site, but a state no such death leaves: ops=$ops lock=$lock core=$core workers=$workers effect=$effect"
      return 1
      ;;
  esac
  if [ "$lock" = empty ] && ! rmdir "$lk"; then
    C_WHY="the empty lock could not be removed"
    return 1
  fi
  if [ "$ops" = running ] && ! rm -f "$opsf"; then
    C_WHY="the running record could not be removed"
    return 1
  fi
  return 0
}

# c_size FILE... — the total size of the files that exist.
c_size() {
  local f t=0
  for f in "$@"; do [ -f "$f" ] && t=$((t + $(wc -c <"$f"))); done
  printf '%s' "$t"
}

# c_core_signal SIG N — signal request N's core by the identity it recorded:
# its PID, held to its start time.
c_core_signal() {
  local id
  id=$(sed -n 's/.*	pid=\([0-9]*\)	start=\([^	]*\)	.*/\1 \2/p' "$SESS/req-$2.core" 2>/dev/null | sed 's/%20/ /g')
  t_signal "$1" "${id%% *}" "${id#* }"
}
