#!/usr/bin/env bash
# BENCH-M01 companion only. The Rust controller owns the monotonic clock.
# This channel never enters the response spool or the ordinary measured core.
# shellcheck disable=SC2154
exec 4>&1 5<&0
exec 1>/dev/null
bench_phase_mark() {
  local __bench_ack
  printf '%s\t%s\n' "$OMB_BENCH_BINDING" "$1" >&4 || exit 97
  IFS= read -r __bench_ack <&5 || exit 97
  [ "$__bench_ack" = observed ] || exit 97
}
