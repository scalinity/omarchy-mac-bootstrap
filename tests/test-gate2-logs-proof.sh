#!/usr/bin/env bash
# Exact capture/publication evidence and BASE/P preservation, without new seams.
# shellcheck disable=SC2030,SC2031,SC2317,SC2329 # scoped environments and callbacks
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-logs-proof
T=$(t_tmp)
c_session
C_FIX=$FIX/linux-alarm-fresh
C_ENV=OMB_SESSION_SCOPES=logs
mkdir -p "$T/state/logs"
file=$T/state/logs/omarchy-bootstrap-20260902.log
printf 'one\n\nlast' >"$file"
p_gen() { sed -n 's/^generation	id=\([^	]*\).*/\1/p' "$C_EV"; }
p_snapshot() { c_run snapshot "scope	name=logs"; }
p_snapshot
gen=$(p_gen)
hello=$(sed -n 2p "$C_EV")

helper() {
  local op=$1 offset=${2:-0}
  c_prepare "$op"
  printf '%s\n' "$hello" >>"$C_EV"
  cp "$C_EV" "$T/prefix"
  cp "$file" "$T/original"
  : >"$T/captures"; : >"$T/leaks"
  rm -f "$T/admitted" "$T/raw"
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    # shellcheck source=lib/core.sh
    . "$REPO/lib/core.sh"
    # shellcheck source=lib/read.sh
    . "$REPO/lib/read.sh"
    # shellcheck source=lib/logs.sh
    . "$REPO/lib/logs.sh"
    HOME=$T/home OMB_INTENT=read OMB_PERSIST=0 OMB_FIXTURE=$C_FIX OMB_STATE_DIR=$T/state
    platform_init; state_init; omb_tmp_init
    CORE_EVENTS=$C_EV CORE_OP=$op CORE_RECS=1 CORE_RESULT=0 CORE_BYTES=0 CORE_SUPPRESSED=0
    CORE_REQ_KIND=log CORE_REQ_GENERATION=$gen CORE_REQ_OFFSET=$offset CORE_REQ_LIMIT=1
    eval "$(declare -f core_logs_window | sed '1s/core_logs_window/p_window_original/')"
    core_logs_window() {
      printf x >>"$T/captures"
      p_window_original "$@" || return "$?"
      cp "$OMB_TMP/logs.raw" "$T/raw" || return 1
      case "${P_FAULT:-}" in scratch-read) rm "$OMB_TMP/logs.raw" ;; esac
      if [ "${P_MUTATE:-0}" = 1 ]; then
        printf 'later input\n' >"$file"
        printf 'different selected file\n' >"$T/state/logs/omarchy-bootstrap-20260903.log"
      fi
    }
    eval "$(declare -f core_read_admit | sed '1s/core_read_admit/p_admit_original/')"
    core_read_admit() {
      local st
      cmp -s "$C_EV" "$T/prefix" || printf leaked >>"$T/leaks"
      case "${P_FAULT:-}" in admit-execute) return 127 ;; admit-read) rm -f "$2" ;; esac
      p_admit_original "$@"
      st=$?
      if [ "$st" = 0 ]; then
        cp "$OMB_TMP/journey.admitted" "$T/admitted" || return 1
        if [ "${P_STAGE:-0}" = 1 ]; then printf 'unadmitted bytes\n' >"$2"; fi
      fi
      return "$st"
    }
    case "${P_FAULT:-}" in
      discovery) find() { return 1; } ;;
      sort) sort() { return 1; } ;;
      vanished) basename() { command basename "$@"; rm -f "$file"; } ;;
      selected-read) tail() { case "$1" in -n) [ "$2" != 40 ] || return 1 ;; esac; command tail "$@"; } ;;
      scratch-write) head() { case "$1:$2" in -c:655401) return 1 ;; esac; command head "$@"; } ;;
      parse-read) read() { if [ "${FUNCNAME[1]:-}" = core_logs_capture ] && [ "${2:-}" = line ]; then return 1; fi; builtin read -r "$@"; } ;;
      parse-partial) read() { if [ "${FUNCNAME[1]:-}" = core_logs_capture ] && [ "${2:-}" = line ]; then line=partial; return 1; fi; builtin read -r "$@"; } ;;
      stage-write) mkdir "$OMB_TMP/journey.response" ;;
      stage-read) cat() { case "$1" in */journey.prefix) return 1 ;; esac; command cat "$@"; } ;;
      retained-copy) cp() { case "$2" in */journey.admitted) return 2 ;; esac; command cp "$@"; } ;;
      admit-awk) awk() { case "$*" in *'hdr=omb-res 1'*) return 127 ;; esac; command awk "$@"; } ;;
      hash) shasum() { case "$*" in */logs.identity) return 1 ;; esac; command shasum "$@"; } ;;
      publish-prep) tail() { case "$1:$2" in -n:+3) return 1 ;; esac; command tail "$@"; } ;;
      transport) cat() { case "$1" in */logs.suffix) head -n 1 "$1"; return 1 ;; esac; command cat "$@"; } ;;
    esac
    core_logs_op "$op"
    st=$?
    omb_cleanup
    exit "$st"
  ) >"$T/out" 2>"$T/err"
  C_RC=$? C_OUT=$(cat "$C_EV") C_ERR=$(cat "$T/err")
  cp "$T/original" "$file"
  rm -f "$T/state/logs/omarchy-bootstrap-20260903.log"
  assert_empty_file "$T/leaks" 'header/hello only during every preflight'
}
for op in snapshot detail; do
  for mutation in none capture stage both; do
    P_MUTATE=0 P_STAGE=0
    case "$mutation" in capture) P_MUTATE=1 ;; stage) P_STAGE=1 ;; both) P_MUTATE=1 P_STAGE=1 ;; esac
    helper "$op"
    assert_eq "$(c_result) $C_RC $(c_admits "$op")" 'done ok 0 ok' "$op/$mutation admitted success"
    assert_eq "$(cat "$T/captures")" x 'one selected-window read'
    assert_eq "$(p_gen)" "$gen" 'captured identity retained after source/selection mutation'
    assert_eq "$C_ERR" '' 'success stderr clean'
    if cmp -s "$T/admitted" "$C_EV"; then ok; else fail 'published != exact retained admitted response'; fi
    if cmp -s "$T/raw" "$T/original"; then ok; else fail 'raw bytes changed'; fi
  done
  P_MUTATE=0 P_STAGE=0
  helper "$op" 3
  assert_eq "$(c_result) $C_RC $(c_admits "$op")" 'done ok 0 ok' 'offset total/preflight success'
  for fault in discovery sort vanished selected-read scratch-write scratch-read parse-read parse-partial stage-write stage-read retained-copy admit-execute admit-read admit-awk hash publish-prep; do
    P_FAULT=$fault helper "$op"
    assert_eq "$(c_result) $C_RC" 'error io 0' "$op/$fault infrastructure is io"
    assert_eq "$(c_admits "$op")" ok "$op/$fault safe response admitted"
    assert_eq "$(cut -f1 "$C_EV" | tr '\n' ' ')" 'omb-res 1 hello generation result ' "$op/$fault no partial data"
    assert_eq "$(p_gen)" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 'io unusable dataset'
  done
  P_FAULT=transport helper "$op"
  assert_rc "$C_RC" 1 'failed transport stays incomplete'
  assert_eq "$(grep -c '^result	' "$C_EV")" 0 'no second safe result after partial append'
done

# BASE text command is run as-is; exact stdout includes indentation and LF.
mkdir "$T/base" "$T/accepted"
git -C "$REPO" archive 2edb76a7de3f78ec90927ac93d5eec3a84636253 | tar -x -C "$T/base" || exit 1
git -C "$REPO" archive 7d3c4d1756c25d2acda9257c6d809107fd8171e6 | tar -x -C "$T/accepted" || exit 1
for sample in absent empty terminated unterminated blank forty fortieth-unterminated fortyone internal trailing multiple; do
  rm -f "$file"
  case "$sample" in
    absent) ;;
    empty) : >"$file" ;;
    terminated) printf 'line\n' >"$file" ;;
    unterminated) printf line >"$file" ;;
    blank) printf '\n' >"$file" ;;
    forty) awk 'BEGIN {for(i=1;i<=40;i++)print i}' >"$file" ;;
    fortieth-unterminated) awk 'BEGIN {for(i=1;i<40;i++)print i;printf "40"}' >"$file" ;;
    fortyone) awk 'BEGIN {for(i=1;i<=41;i++)print i}' >"$file" ;;
    internal) printf 'a\n\nb\n' >"$file" ;;
    trailing) printf 'a\n\n' >"$file" ;;
    multiple) printf 'a\n\n\n' >"$file" ;;
  esac
  for tool in "$T/base" "$REPO"; do
    label=base; [ "$tool" != "$REPO" ] || label=candidate
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$T/home" TMPDIR="$T" OMB_STATE_DIR="$T/state" OMB_FIXTURE="$C_FIX" \
      "$T_BASH" "$tool/omarchy-bootstrap" --ascii --no-color logs >"$T/$label.text" 2>"$T/$label.err"
    assert_rc "$?" 0 "$sample/$label text succeeds"
    assert_empty_file "$T/$label.err" "$sample/$label stderr clean"
  done
  if cmp -s "$T/base.text" "$T/candidate.text"; then ok; else fail "$sample BASE text changed"; fi
  p_snapshot
  assert_eq "$(c_result)" 'done ok' "$sample typed success agrees with BASE"
done

# Same basename/window under another full path/context must have a different id.
printf 'same\n' >"$file"
p_snapshot
pathgen=$(p_gen)
mkdir -p "$T/state/logs/z"
cp "$file" "$T/state/logs/z/omarchy-bootstrap-20260902.log"
p_snapshot
assert_not_contains "$(p_gen)" "$pathgen" 'full path identity changes with identical basename/rows'
rm -rf "$T/state/logs/z"
p_snapshot
assert_eq "$(p_gen)" "$pathgen" 'original full path restores generation'

# Current P journey output: allowed hello identity fields alone may differ.
normalized() {
  awk -F '\t' 'BEGIN {OFS="\t"} $1=="hello" {for(i=2;i<=NF;i++)if($i~/^(commit|source)=/)sub(/=.*/,"=",$i)} {print}' "$1"
}
fixtures='linux-alarm-fresh linux-omarchy-installed'
if t_plutil 'P journey preservation'; then fixtures="$fixtures mac-m1pro-1tb-roomy"; fi
for fx in $fixtures; do
  C_FIX=$FIX/$fx C_ENV=OMB_SESSION_SCOPES=journey
  c_run snapshot "scope	name=journey"
  jgen=$(p_gen)
  normalized "$C_EV" >"$T/current"
  C_HOME=$T/accepted c_run snapshot "scope	name=journey"
  normalized "$C_EV" >"$T/previous"
  if cmp -s "$T/current" "$T/previous"; then ok; else fail "$fx P snapshot differs"; fi
  for kind in machine status; do
    record="page	scope=journey	kind=$kind	generation=$jgen	offset=0	limit=500"
    c_run detail "$record"; normalized "$C_EV" >"$T/current"
    C_HOME=$T/accepted c_run detail "$record"; normalized "$C_EV" >"$T/previous"
    if cmp -s "$T/current" "$T/previous"; then ok; else fail "$fx/$kind P detail differs"; fi
  done
done
t_done test-gate2-logs-proof
