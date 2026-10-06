#!/usr/bin/env bash
# Diagnostics by child class (docs/PROTOCOL.md → *Diagnostics, by child
# class*) and the spool's bound (*Backpressure and bounds*): every retained
# byte — headers, payload, summaries — within 65 536 a child, 262 144 a
# request, 4 194 304 a session, reserved before anything is appended; a
# saturated request or session adds nothing; the drain never blocks the child.
# diag-* and sup-overflow, over the fake read child in fixture mode.
#
# The sections run as units, tests/diag-UNIT.sh, each a process of its own
# from a fresh session (tests/diag-lib.sh), so that they can also run side by
# side. This runs every unit, one after another, under the bash under test,
# and fails when one fails, when a listed unit has no file, or when a unit's
# file is not listed. OMB_DIAG_UNITS names the units to run instead of all of
# them (CI's shards, tests/ci-manifest.tsv); the listing checks run either way.
# shellcheck disable=SC2015 # ok/fail always return 0
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-diag"
UNITS="bounds temp children session capture"

for f in "$TESTS_DIR"/diag-*.sh; do
  u=${f##*/diag-}
  u=${u%.sh}
  [ "$u" = lib ] && continue
  case " $UNITS " in
    *" $u "*) ok ;;
    *) fail "tests/diag-$u.sh is a diagnostics unit this suite does not run" ;;
  esac
done
for u in ${OMB_DIAG_UNITS:-$UNITS}; do
  case " $UNITS " in
    *" $u "*) ;;
    *)
      fail "OMB_DIAG_UNITS names $u, which is not a diagnostics unit"
      continue
      ;;
  esac
  if [ ! -f "$TESTS_DIR/diag-$u.sh" ]; then
    fail "the diagnostics unit tests/diag-$u.sh is missing"
    continue
  fi
  "$T_BASH" "$TESTS_DIR/diag-$u.sh" && ok || fail "the diagnostics unit $u failed"
done

t_done test-diag
