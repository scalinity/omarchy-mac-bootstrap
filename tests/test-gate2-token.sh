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
  other_before=$(printf '%s\n' "$C_OUT" | grep -vE $'^(generation|code)\t')
  for kind in machine status; do
    c_run detail "page	scope=journey	kind=$kind	generation=$added	offset=0	limit=1"
    assert_eq "$(c_result)" 'done ok' "$kind first page before token-only change"
  done
  # gh is carried in the token and is absent from status rows/identity facts.
  printf 'cfg_gh=octocat\n' >>"$T/state/state.env"
  c_run snapshot "scope	name=journey"
  changed=$(printf '%s\n' "$C_OUT" | sed -n 's/^generation	id=\([^	]*\).*/\1/p')
  assert_not_contains "$changed" "$added" 'token-only value change changes generation'
  assert_eq "$(printf '%s\n' "$C_OUT" | grep -vE $'^(generation|code)\t')" "$other_before" 'only token and generation changed in snapshot'
  for kind in machine status; do
    c_run detail "page	scope=journey	kind=$kind	generation=$added	offset=1	limit=1"
    assert_eq "$(c_result)" 'refused changed' "$kind token-only change between pages refuses old generation"
    assert_contains "$C_OUT" "generation	id=$changed" "$kind refusal returns fresh whole-dataset generation"
    assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^row	')" 0 "$kind stale page contains no rows"
    assert_eq "$(c_admits detail)" ok "$kind token-only changed response admitted"
    c_run detail "page	scope=journey	kind=$kind	generation=$changed	offset=0	limit=500"
    assert_eq "$(c_result)" 'done ok' "$kind fresh page succeeds"
    assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^code	')" 0 "$kind detail contains no token code"
    assert_not_contains "$C_OUT" 'omb2:' "$kind detail does not duplicate token as command-text row"
  done
  c_run snapshot "scope	name=journey"
  same=$(printf '%s\n' "$C_OUT" | sed -n 's/^generation	id=\([^	]*\).*/\1/p')
  assert_eq "$same" "$changed" 'unchanged token and dataset give stable generation'
  printf 'cfg_host=solo\n' >"$T/state/state.env"
  c_run snapshot "scope	name=journey"
  assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^code	')" 0 'host alone does not expose token'
  removed=$(printf '%s\n' "$C_OUT" | sed -n 's/^generation	id=\([^	]*\).*/\1/p')
  assert_eq "$removed" "$absent" 'removing token returns to the unchanged token-absent dataset'
fi
t_done test-gate2-token
