#!/usr/bin/env bash
# Scoped generation matrix and paging boundaries, through real admission.
# shellcheck disable=SC2030,SC2031
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-paging
T=$(t_tmp)
c_session
C_FIX=$(t_variant linux-alarm-fresh)
g_gen() { printf '%s\n' "$C_OUT" | sed -n 's/^generation	id=\([^	]*\).*/\1/p'; }
g_rows() { printf '%s\n' "$C_OUT" | grep '^row	' || true; }
g_page() { c_run detail "page	scope=journey	kind=$1	generation=$2	offset=$3	limit=$4"; }
g_ok() {
  assert_eq "$(c_result) $C_RC" 'done ok 0' "$1 succeeds"
  assert_eq "$(c_admits detail)" ok "$1 schema valid"
  assert_eq "$C_ERR" '' "$1 clean stderr"
}
c_run snapshot "scope	name=journey"
gen=$(g_gen)
hello=$(sed -n 2p "$C_EV")
assert_contains "$C_OUT" "generation	id=$gen	total=0" 'snapshot total remains zero'
for kind in machine status; do
  g_page "$kind" "$gen" 0 500
  g_ok "$kind current generation, limit max"
  all=$(g_rows)
  total=$(printf '%s\n' "$all" | wc -l | tr -d ' ')
  assert_contains "$C_OUT" "generation	id=$gen	total=$total" "$kind total is projection count"
  for limit in 1 2 500; do
    got=''
    offset=0
    while [ "$offset" -lt "$total" ]; do
      g_page "$kind" "$gen" "$offset" "$limit"
      g_ok "$kind traversal offset $offset limit $limit"
      rows=$(g_rows)
      got="$got$rows
"
      offset=$((offset + limit))
    done
    assert_eq "$got" "$all
" "$kind every row exactly once, producer order, no gap or duplicate"
  done
  g_page "$kind" "$gen" "$total" 1
  g_ok "$kind offset equals total"
  assert_eq "$(g_rows)" '' "$kind offset at total is empty success"
  g_page "$kind" "$gen" "$((total + 1))" 1
  assert_eq "$(c_result)" 'refused invalid' "$kind offset beyond total refused"
  assert_eq "$(g_rows)" '' 'invalid offset emits no rows'
  g_page "$kind" "$gen" 999999999999999999 500
  assert_eq "$(c_result)" 'refused invalid' 'maximum admitted offset cannot wrap'
done
c_run snapshot "scope	name=journey"
assert_eq "$(g_gen)" "$gen" 'gen-refresh-same'
# Unknown and foreign-scope ids are well formed, but cannot authorize rows.
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$T/home" TMPDIR="$T" OMB_STATE_DIR="$T/state" \
  OMB_FIXTURE="$C_FIX" G2_CANDIDATE="$REPO" G2_PROBES="$T/probes" \
  "$T_BASH" "$TESTS_DIR/gate2-oracle.sh" "$REPO" dataset >"$T/dataset"
foreign=$(
  . "$REPO/lib/common.sh"
  dataset=$(sed '1s/journey/disk/' "$T/dataset")
  sha256_str "$dataset"
)
assert_not_contains "$foreign" "$gen" 'equal-looking dataset in another scope has a different generation'
for other in "$(printf '%064d' 0)" "$foreign"; do
  g_page machine "$other" 0 2
  assert_eq "$(c_result)" 'refused changed' 'gen-unknown / gen-foreign-scope'
  assert_eq "$(g_gen)" "$gen" 'changed returns fresh whole-dataset generation'
  assert_eq "$(g_rows)" '' 'changed emits no rows'
  assert_eq "$(c_admits detail)" ok 'changed response schema valid'
done
# A status-only change invalidates even an unchanged machine projection.
g_page machine "$gen" 0 1
first=$(g_rows)
printf '\n' >"$C_FIX/cmd/ip_route"
g_page machine "$gen" 1 1
assert_eq "$(c_result)" 'refused changed' 'gen-between-pages: no mixed generations'
assert_eq "$(g_rows)" '' 'gen-between-pages: no row'
fresh=$(g_gen)
assert_not_contains "$fresh" "$gen" 'gen-refresh-changed: new dataset has new id'
c_run snapshot "scope	name=journey"
assert_eq "$(g_gen)" "$fresh" 'fresh snapshot agrees with changed detail'
g_page machine "$gen" 0 1
assert_eq "$(c_result)" 'refused changed' 'gen-old remains stale; no silent adoption'
g_page machine "$fresh" 0 1
g_ok 'explicit reopen on fresh generation'
assert_eq "$(g_rows)" "$first" 'machine rows unchanged while whole dataset changed'
# Admission rejects malformed or absent page fields, never returns changed.
for fields in \
  "scope=journey	kind=machine	generation=x	offset=0	limit=1" \
  "scope=journey	kind=machine	offset=0	limit=1" \
  "scope=journey	kind=machine	generation=$fresh	offset=0	limit=0" \
  "scope=journey	kind=machine	generation=$fresh	offset=0	limit=501" \
  "scope=journey	kind=machine	generation=$fresh	offset=01	limit=1" \
  "scope=journey	kind=machine	generation=$fresh	limit=1" \
  "scope=journey	kind=machine	generation=$fresh	offset=0" \
  "scope=journey	generation=$fresh	offset=0	limit=1" \
  "kind=machine	generation=$fresh	offset=0	limit=1"; do
  c_run detail "page	$fields"
  assert_rc "$C_RC" 2 'malformed/missing page field fails admission'
  assert_not_contains "$(c_result)" changed 'malformed generation is not changed'
  assert_eq "$(g_rows)" '' 'malformed request emits no page rows'
done
c_run detail
assert_rc "$C_RC" 2 'missing page record fails admission'
assert_not_contains "$(c_result)" changed 'missing page is not changed'
for kind in doctor log validate future; do
  g_page "$kind" "$fresh" 0 1
  assert_eq "$(c_result)" 'refused unavailable' "$kind detail remains unavailable"
done
c_run validate "select	action=plan.save"
assert_eq "$(c_result)" 'refused unavailable' 'Validate remains blocked'
C_ENV=OMB_SESSION_SCOPES=disk g_page machine "$fresh" 0 1
assert_eq "$(c_result)" 'refused scope' 'detail outside session scope'
c_uname_arm "$T/native"
C_PATH="$T/native:/usr/bin:/bin:/usr/sbin:/sbin" C_ENV='OMB_FIXTURE= OMB_FRONTEND_DEV=' g_page machine "$fresh" 0 1
assert_eq "$(c_result)" 'refused unavailable' 'production detail unavailable'
for ceiling in read plan act; do
  C_ENV="OMB_SESSION_INTENT=$ceiling" g_page status "$fresh" 0 500
  g_ok "detail at $ceiling ceiling"
done
assert_eq "$(t_snapshot "$T/state")" '(absent)' 'paging creates no persistent records'
assert_eq "$(find "$T" -maxdepth 1 -name 'omarchy-bootstrap.*')" '' 'paging cleans request scratch'
# Generic page engine: empty, one-row, and >500-row projections without
# inventing a production kind or adding a synthetic producer to the core.
for count in 0 1 501; do
  rows=''
  i=0
  while [ "$i" -lt "$count" ]; do
    rows="$rows$(printf 'row\tkind=machine\tkey=%s\tcol=Value\tcol=%s' "$i" "$i")
"
    i=$((i + 1))
  done
  offsets="0 $count $((count + 1))"
  [ "$count" != 501 ] || offsets="$offsets 500"
  for offset in $offsets; do
    c_prepare detail
    printf '%s\n' "$hello" >>"$C_EV"
    (
      t_load >/dev/null 2>&1
      # shellcheck source=lib/records.sh
      . "$REPO/lib/records.sh"
      # shellcheck source=lib/core.sh
      . "$REPO/lib/core.sh"
      # shellcheck source=lib/read.sh
      . "$REPO/lib/read.sh"
      CORE_EVENTS=$C_EV CORE_OP=detail CORE_RECS=1
      CORE_REQ_GENERATION=$fresh CORE_REQ_OFFSET=$offset CORE_REQ_LIMIT=500
      core_read_page "$fresh" "$rows"
      omb_cleanup
    )
    C_OUT=$(cat "$C_EV")
    assert_eq "$(c_admits detail)" ok "generic count $count offset $offset admitted"
    assert_contains "$C_OUT" "generation	id=$fresh	total=$count" 'generic total'
    expected='done ok'
    [ "$offset" -le "$count" ] || expected='refused invalid'
    assert_eq "$(c_result)" "$expected" "generic count $count offset $offset result"
    want=0
    if [ "$offset" -lt "$count" ]; then
      want=$((count - offset)); [ "$want" -le 500 ] || want=500
    fi
    assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^row	')" "$want" 'generic page count respects limit'
  done
done
t_done test-gate2-paging
