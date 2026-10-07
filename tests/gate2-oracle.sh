#!/usr/bin/env bash
# Test-only semantic taps on the independently extracted baseline's text sinks.
# Production never uses this adapter or parses a rendered resume command.
# shellcheck disable=SC1090,SC2034,SC2329
set -u
TREE=$1 MODE=$2
for module in common ui state sources storage macos asahi linux shared doctor dev; do
  . "$TREE/lib/$module.sh"
done
. "$G2_CANDIDATE/lib/records.sh"
OMB_INTENT=read OMB_PERSIST=0 OMB_ASCII=1 OMB_COLOR=never
# Trace the existing probe seams; keep each original implementation intact.
# shellcheck source=tests/gate2-probe-taps.sh
. "$G2_CANDIDATE/tests/gate2-probe-taps.sh"
platform_init
state_init
ui_init
trap omb_cleanup EXIT
if [ "$MODE" = dataset ]; then
  . "$G2_CANDIDATE/lib/read.sh"
  core_journey_dataset
else
  section='' rows='' guide='' token='' n=0
  ui_header() { :; }
  mac_rail() { :; }
  lx_rail() { :; }
  ui_section() {
    section=$1
    case "$section" in Next | 'Resume token') return 0 ;; esac
    n=$((n + 1))
    rec_line_v row kind status key "$n" col "$section" col '' col '' col "${2:-}"
    rows="$rows$REC_LINE
"
  }
  ui_kv() {
    n=$((n + 1))
    rec_line_v row kind status key "$n" col "$section" col "$1" col "$2" col "${3:-}"
    rows="$rows$REC_LINE
"
  }
  ui_para() {
    if [ "$section" = Next ]; then
      rec_line_v guide id next step 1 text "$*"
      guide=$REC_LINE
    else ui_kv '' "$*"; fi
  }
  ui_note() { ui_kv '' "$*"; }
  ui_cmd() {
    case "$section" in
      'Resume token') rec_line_v code kind token value "${1#./omarchy-bootstrap resume }"; token=$REC_LINE ;;
      *) ui_kv '' "$*" ;;
    esac
  }
  # Only the upstream payload bypasses the baseline's structured UI sinks.
  eval "$(declare -f lx_upstream_status | sed '1s/lx_upstream_status/g2_upstream_status/')"
  lx_upstream_status() {
    if [ "$OMB_UID" != 0 ]; then g2_upstream_status; return; fi
    while IFS= read -r line || [ -n "$line" ]; do
      ui_kv '' "${line#   }"
    done < <(g2_upstream_status)
  }
  cmd_status >/dev/null
  # Independent identity oracle: values supplied by the baseline's detector,
  # not by the candidate's facts or generation implementation.
  {
    rec_line row kind machine key machine.platform col Platform col "$OMB_PLATFORM"
    if [ "$OMB_PLATFORM" = macos ]; then
      rec_line row kind machine key machine.arch col Architecture col "${MAC_ARCH:-unknown}"
      rec_line row kind machine key machine.model col Model col "${MAC_MODEL_ID:-unknown}"
      rec_line row kind machine key machine.chip col Chip col "${MAC_CHIP:-unknown}"
      rec_line row kind machine key machine.memory col Memory col "${MAC_MEM_BYTES:-unknown}"
      rec_line row kind machine key machine.os col macOS col "${MAC_OS_VERSION:-unknown}"
    else
      rec_line row kind machine key machine.arch col Architecture col "${LX_ARCH:-unknown}"
      rec_line row kind machine key machine.model col Model col "${LX_DT_MODEL:-unknown}"
      rec_line row kind machine key machine.chip col Chip col "${DEV_CHIP:-unknown}"
      rec_line row kind machine key machine.os col System col "${LX_OS_NAME:-unknown}"
      rec_line row kind machine key machine.kernel col Kernel col "${LX_KERNEL:-unknown}"
    fi
  } >"$G2_PROBES.machine"
  [ -z "$guide" ] || printf '%s\n' "$guide"
  [ -z "$token" ] || printf '%s\n' "$token"
  printf '%s' "$rows"
fi
[ "$OMB_INTENT:$OMB_PERSIST" = read:0 ] || exit 88
