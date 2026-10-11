# shellcheck shell=bash
# The setup every diagnostics unit starts from (tests/test-diag.sh runs the
# units; each runs on its own as tests/diag-UNIT.sh): the harness, a decoy,
# a fresh session over a throwaway copy of the roomy M1 Pro fixture, and the
# helpers the diag-* sections share. Diagnostics by child class
# (docs/PROTOCOL.md → *Diagnostics, by child class*) and the spool's bound
# (*Backpressure and bounds*): every retained byte — headers, payload,
# summaries — within 65 536 a child, 262 144 a request, 4 194 304 a session,
# reserved before anything is appended; a saturated request or session adds
# nothing; the drain never blocks the child.
# shellcheck disable=SC2034 # H and the helpers are the units' own
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(t_tmp)
t_decoy "tail -c 65281 (a program of the developer's)"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"

c_session
c_fixture
# The block header's length for test.read (fixed width: exit and kept are
# zero-padded), counted in every limit.
H=$(printf 'child\ttest.read\texit=000\tkept=00000\tdiscarded=0\n' | wc -c | tr -d ' ')
diag() { printf '%s/req-%s.diag' "$SESS" "$C_N"; }
summ() { printf '%s/req-%s.diag-summary' "$SESS" "$C_N"; }
session_total() {
  c_size "$SESS"/req-*.diag "$SESS"/req-*.diag-summary "$SESS/session.diag-summary"
}
# The launcher writes the session's summary with the scratch.
printf '%-127s\n' "diagnostics truncated: children not kept 0000000000, bytes discarded at least 0000000000" >"$SESS/session.diag-summary"
