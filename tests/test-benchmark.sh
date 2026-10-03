#!/usr/bin/env bash
# Harness contract checks only. Never starts a measurement.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo test-benchmark
for f in bench/run bench/component.sh frontend/tests/benchmark/mod.rs bench/macos-capture.env; do
  if [ -f "$REPO/$f" ]; then ok; else fail "missing benchmark artifact: $f"; fi
done
for f in bench/run bench/component.sh bench/macos-capture.env; do
  "$T_BASH" -n "$REPO/$f"
  assert_rc "$?" 0 "benchmark syntax: $f"
done
sc=${SHELLCHECK:-$(command -v shellcheck || true)}
if [ -n "$sc" ]; then
  "$sc" -S style "$REPO/bench/run" "$REPO/bench/component.sh"
  assert_rc "$?" 0 'benchmark ShellCheck'
fi
if [ -x "$REPO/bench/run" ]; then
  "$REPO/bench/run" >/dev/null 2>&1
  assert_rc "$?" 2 'no implicit measurement'
  "$REPO/bench/run" --full >/dev/null 2>&1
  assert_rc "$?" 2 'full requires acknowledgement and output'
fi
t_done test-benchmark
