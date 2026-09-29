#!/usr/bin/env bash
# Scope generation includes the conditional token, not just visible rows.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-token
T=$(t_tmp)
c_session
if t_plutil 'journey token generation'; then
  C_FIX=$FIX/mac-m1pro-1tb-roomy
  c_run snapshot "scope	name=journey"
  absent=$(printf '%s\n' "$C_OUT" | sed -n 's/^generation	id=\([^	]*\).*/\1/p')
  assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^code	')" 0 'token absent without recorded user'
  mkdir -p "$T/state"
  printf 'cfg_user=alex\n' >"$T/state/state.env"
  c_run snapshot "scope	name=journey"
  added=$(printf '%s\n' "$C_OUT" | sed -n 's/^generation	id=\([^	]*\).*/\1/p')
  assert_not_contains "$added" "$absent" 'adding token changes generation'
  assert_contains "$C_OUT" 'code	kind=token	value=omb2:user%3Dalex' 'canonical typed token present without invented defaults'
  assert_eq "$(c_admits snapshot)" ok 'typed token response admitted'
  # gh is carried in the token and is absent from status rows/identity facts.
  printf 'cfg_gh=octocat\n' >>"$T/state/state.env"
  c_run snapshot "scope	name=journey"
  changed=$(printf '%s\n' "$C_OUT" | sed -n 's/^generation	id=\([^	]*\).*/\1/p')
  assert_not_contains "$changed" "$added" 'token-only value change changes generation'
  c_run snapshot "scope	name=journey"
  same=$(printf '%s\n' "$C_OUT" | sed -n 's/^generation	id=\([^	]*\).*/\1/p')
  assert_eq "$same" "$changed" 'unchanged token and dataset give stable generation'
  printf 'cfg_host=solo\n' >"$T/state/state.env"
  c_run snapshot "scope	name=journey"
  assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^code	')" 0 'host alone does not expose token'
fi
t_done test-gate2-token
