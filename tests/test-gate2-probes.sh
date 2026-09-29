#!/usr/bin/env bash
# Actual snapshot and detail processes perform exactly the same reads.
# Instrumentation exists only in this test's copied tool, never production.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-probes
T=$(t_tmp)
c_session
mkdir -p "$T/tool"
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$REPO/release" "$T/tool/"
printf '\n. %q\n' "$TESTS_DIR/gate2-probe-taps.sh" >>"$T/tool/lib/common.sh"
C_HOME=$T/tool
shims=$(t_shims "$T")
C_PATH=$shims:/usr/bin:/bin:/usr/sbin:/sbin
fixtures='linux-alarm-fresh linux-omarchy-installed linux-shared-ready'
if t_plutil 'snapshot/detail probe equivalence'; then
  fixtures="$fixtures mac-m1pro-1tb-roomy mac-asahi-complete mac-shared-created"
fi
for fx in $fixtures; do
  C_FIX=$FIX/$fx
  C_ENV="G2_PROBES=$T/snapshot.probes OMB_TEST_RECORD=$T/record SHIM_LOG=$T/shims.log"
  : >"$T/snapshot.probes"
  c_run snapshot "scope	name=journey"
  assert_eq "$(c_result)" 'done ok' "$fx snapshot"
  gen=$(printf '%s\n' "$C_OUT" | sed -n 's/^generation	id=\([^	]*\).*/\1/p')
  for kind in machine status; do
    for offset in 0 1; do
      C_ENV="G2_PROBES=$T/detail.probes OMB_TEST_RECORD=$T/record SHIM_LOG=$T/shims.log"
      : >"$T/detail.probes"
      c_run detail "page	scope=journey	kind=$kind	generation=$gen	offset=$offset	limit=1"
      assert_eq "$(c_result)" 'done ok' "$fx $kind page $offset"
      assert_eq "$(cat "$T/detail.probes")" "$(cat "$T/snapshot.probes")" "$fx $kind page $offset same ordered probes as snapshot"
      assert_empty_file "$T/record" 'no action recorded'
      assert_empty_file "$T/shims.log" 'no forbidden command executed'
      assert_eq "$(t_snapshot "$T/state")" '(absent)' 'no persistent state'
      assert_eq "$(find "$T" -maxdepth 1 -name 'omarchy-bootstrap.*')" '' 'request scratch cleaned'
    done
  done
done
t_done test-gate2-probes
