#!/usr/bin/env bash
# Runs every check: syntax, shellcheck (when available), and the test files.
# On macOS the suite runs under /bin/bash (3.2) to prove stock compatibility;
# set OMB_TEST_BASH to use another bash.
#
#   tests/run.sh            everything
#   tests/run.sh storage    one file (tests/test-storage.sh)
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
. tests/lib.sh

status=0
# shellcheck disable=SC2016 # expanded by the child bash
printf 'bash under test: %s (%s)\n\n' "$T_BASH" "$("$T_BASH" -c 'echo $BASH_VERSION')"

if [ -z "${1:-}" ]; then
  echo "syntax"
  for f in omarchy-bootstrap lib/*.sh tests/*.sh tests/fixtures/generate.sh tests/proto/corpus.sh tests/children/*; do
    "$T_BASH" -n "$f" || {
      echo "  syntax error: $f"
      status=1
    }
  done
  echo "  ok"

  sc=${SHELLCHECK:-$(command -v shellcheck || true)}
  if [ -n "$sc" ]; then
    echo "shellcheck"
    # Per file for each file's own findings; cross-file "unused"/"unassigned"
    # codes are checked through the entrypoint, which sources everything.
    "$sc" -S style -e SC2034,SC2154,SC2153 omarchy-bootstrap lib/*.sh tests/*.sh tests/fixtures/generate.sh tests/proto/corpus.sh tests/children/* || status=1
    "$sc" -x omarchy-bootstrap || status=1
    [ "$status" = 0 ] && echo "  ok"
  elif [ "${OMB_REQUIRE_SHELLCHECK:-0}" = 1 ]; then
    echo "shellcheck: required (OMB_REQUIRE_SHELLCHECK=1) but not installed"
    status=1
  else
    echo "shellcheck: not installed, skipped (set SHELLCHECK=/path/to/shellcheck)"
  fi
  echo
fi

for t in tests/test-${1:-*}.sh; do
  "$T_BASH" "$t" || status=1
done

rm -rf tests/.tmp
echo
if [ "$status" = 0 ]; then echo "ALL PASSED"; else echo "FAILURES"; fi
exit "$status"
