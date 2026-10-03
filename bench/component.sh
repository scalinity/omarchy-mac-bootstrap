#!/usr/bin/env bash
# Benchmark-only loaded-input boundary, not an entrypoint/product producer.
# Uses core_validate_op unchanged. Its detector callback returns the already
# loaded capture; no algorithm, parser, planner or response is duplicated.
# shellcheck disable=SC2034,SC2154,SC2317,SC2329,SC2016
set -eu
repo=$1
capture=$2
spool=$3
request=$4
for name in common ui state sources storage macos asahi shared linux doctor dev records core read validate; do
  # shellcheck source=/dev/null
  . "$repo/lib/$name.sh"
done
OMB_HOME=$repo OMB_INTENT=read OMB_PERSIST=0 OMB_COLOR=never OMB_ASCII=1
OMB_DRY_RUN=0 OMB_SESSION_INTENT=read OMB_CORE_ENV_DRY=0
# The fixed capture is committed benchmark data generated from the ordinary
# mac-m1pro-1tb-roomy fixture. No Linux plutil emulation or native Mac probe.
# shellcheck source=bench/macos-capture.env
. "$capture"
OMB_PLATFORM=macos
ui_init
platform_init
state_init
omb_tmp_init
trap omb_cleanup EXIT
core_source
CORE_EVENTS=$spool CORE_OP=validate
core_hello
rec_admit_file req validate "$request"
CORE_REQ_ARGS=0 CORE_REQ_ARG_NAME=() CORE_REQ_ARG_VALUE=()
i=0
while [ "$i" -lt "$REC_N" ]; do
  if [ "${REC_T[i]}" = arg ]; then
    rec_get_into name "$i" name
    rec_get_into value "$i" value
    CORE_REQ_ARG_NAME[CORE_REQ_ARGS]=$name
    CORE_REQ_ARG_VALUE[CORE_REQ_ARGS]=$value
    CORE_REQ_ARGS=$((CORE_REQ_ARGS + 1))
  fi
  i=$((i + 1))
done
mac_detect() { :; }
# Witness callbacks, without timers or changes to in-tree production source.
# Preserve the actual accepted function bodies and status/output verbatim.
BENCH_TRACE=$spool.trace
: >"$BENCH_TRACE"
for name in parse_size core_validate_trim plan_init plan_compute plan_validate plan_layout plan_verify core_validate_basis core_validate_stage core_read_admit; do
  eval "$(declare -f "$name" | sed "1s/$name/bench_original_$name/")"
  eval "$name() { printf '%s\\n' '$name' >>\"\$BENCH_TRACE\"; bench_original_$name \"\$@\"; }"
done
for name in sys_cmd sys_path sys_has sys_net sys_reachable; do
  eval "$name() { printf '%s\\n' 'FORBIDDEN-PROBE-$name' >>\"\$BENCH_TRACE\"; return 99; }"
done
# Observable lifecycle: everything before ready is outside the component.
printf 'ready\n'
IFS= read -r command
[ "$command" = go ]
core_validate_op
printf 'complete\n'
