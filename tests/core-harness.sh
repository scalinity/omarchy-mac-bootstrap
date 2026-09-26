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
# assignments; C_UNSET drops names; C_PATH replaces PATH.
c_run_raw() {
  local op=$1 req=$2 v name
  local -a envs=(
    "PATH=${C_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" "HOME=$T/home" "TMPDIR=$T" "LANG=en_US.UTF-8" "TERM=dumb"
    "OMB_HOME=$REPO" "OMB_SESSION_INTENT=act" "OMB_SESSION_SCOPES=journey" "OMB_DRY_RUN=0"
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
  env -i "${final[@]}" "${C_BASH:-$T_BASH}" "$REPO/omarchy-bootstrap" core "$op" 3<"$req" >/dev/null 2>"$T/stderr" </dev/null
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

# c_size FILE... — the total size of the files that exist.
c_size() {
  local f t=0
  for f in "$@"; do [ -f "$f" ] && t=$((t + $(wc -c <"$f"))); done
  printf '%s' "$t"
}
