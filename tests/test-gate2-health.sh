#!/usr/bin/env bash
# S4 Health: one cmd_doctor capture per request, typed counts and rows,
# whole-dataset admission, generations, paging, routing and read purity.
# shellcheck disable=SC2030,SC2031 # intentionally scoped core environments
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-health
T=$(t_tmp)
c_session
zero=$(printf '%064d' 0)
empty=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
mkdir "$T/tool"
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$REPO/release" "$T/tool/"
# Test-only taps in a copied tool. The Doctor owner and log_event still run;
# effects a read must never reach are recorded and refused.
cat >>"$T/tool/lib/core.sh" <<'TAPS'
eval "$(declare -f cmd_doctor | sed '1s/cmd_doctor/h_original_doctor/')"
cmd_doctor() {
  local h_st
  printf '%s %s\n' "$OMB_INTENT" "$OMB_PERSIST" >>"$H_DOCTOR"
  h_original_doctor "$@"
  h_st=$?
  printf '%s\n' "$h_st" >>"$H_STATUS"
  return "$h_st"
}
eval "$(declare -f log_event | sed '1s/log_event/h_original_log_event/')"
log_event() { printf '%s %s %s\n' "$OMB_INTENT" "$OMB_PERSIST" "$1" >>"$H_LOG"; h_original_log_event "$@"; }
core_action_info() { printf 'action\n' >>"$H_EFFECTS"; return 99; }
state_lock() { printf 'lock\n' >>"$H_EFFECTS"; return 99; }
state_set() { printf 'state\n' >>"$H_EFFECTS"; return 99; }
run() { printf 'run\n' >>"$H_EFFECTS"; return 99; }
fetch_upstream() { printf 'download\n' >>"$H_EFFECTS"; return 99; }
core_op_write() { printf 'operation\n' >>"$H_EFFECTS"; return 99; }
TAPS
shims=$(t_shims "$T")
C_HOME=$T/tool C_PATH="$shims:/usr/bin:/bin:/usr/sbin:/sbin"
H_TAPS="H_DOCTOR=$T/doctor H_STATUS=$T/status H_LOG=$T/log H_EFFECTS=$T/effects SHIM_LOG=$T/shims.log"
h_reset() { : >"$T/doctor"; : >"$T/status"; : >"$T/log"; : >"$T/effects"; : >"$T/shims.log"; }
h_env() { printf 'OMB_SESSION_SCOPES=%s %s %s' "${H_SCOPES:-health}" "$H_TAPS" "${H_EXTRA:-}"; }
h_snapshot() { C_ENV=$(h_env) c_run snapshot "scope	name=health"; }
h_page() { C_ENV=$(h_env) c_run detail "page	scope=health	kind=${4:-doctor}	generation=$1	offset=${2:-0}	limit=${3:-500}"; }
h_gen() { sed -n 's/^generation	id=\([^	]*\).*/\1/p' "$C_EV"; }
h_total() { sed -n 's/^generation	id=[^	]*	total=\([0-9]*\)$/\1/p' "$C_EV"; }
h_rows() { sed -n '/^row	/p' "$C_EV"; }
h_types() { cut -f1 "$C_EV" | tr '\n' ' '; }
h_fact() { sed -n "s/^fact	scope=health	key=doctor\\.$1	label=[A-Za-z]*	value=\\([0-9]*\\)	state=info\$/\\1/p" "$C_EV"; }
h_count() { awk -F '\t' -v s="col=$1" '$1 == "row" && $4 == s { n++ } END { print n + 0 }' "$C_EV"; }
h_lines() { wc -l <"$1" | tr -d ' '; }
h_good() {
  assert_eq "$(c_result) $C_RC" 'done ok 0' "$1 success"
  assert_eq "$(c_admits "$2")" ok "$1 admitted"
  assert_eq "$C_ERR" '' "$1 clean stderr"
}
h_fail() {
  assert_eq "$(c_result) $C_RC" "error $2 0" "$1 result"
  assert_eq "$(c_admits "$3")" ok "$1 admitted"
  assert_eq "$(h_types)" 'omb-res 1 hello generation result ' "$1 no candidate facts, rows or messages"
  assert_eq "$(h_gen) $(h_total)" "$empty 0" "$1 no usable dataset"
}
h_refused() {
  assert_eq "$(c_result) $C_RC" "refused $2 0" "$1 result"
  assert_eq "$(c_admits detail)" ok "$1 admitted"
  assert_eq "$(h_rows)" '' "$1 no rows"
}
h_name() {
  awk -v n="$2" '/^PRETTY_NAME=/ { print "PRETTY_NAME=\"" n "\""; next } { print }' \
    "$FIX/linux-alarm-fresh/root/etc/os-release" >"$1/root/etc/os-release"
}
h_df() {
  printf 'Filesystem     1024-blocks      Used Available Capacity Mounted on\n/dev/nvme0n1p6   240000000  12000000 %s       5%% /\n' "$2" >"$1/cmd/df_root"
}

# The snapshot is three count facts and a done result; the detail is every
# ordered finding. A report with failed checks is still a successful read.
fixtures='linux-alarm-fresh linux-alarm-offline linux-omarchy-installed linux-shared-ready linux-encrypt-staged linux-shared-conflict'
if t_plutil 'Health macOS snapshot/detail contract'; then
  fixtures="$fixtures mac-m1pro-1tb-roomy mac-m1pro-1tb-tight mac-asahi-pending mac-shared-created"
fi
for fx in $fixtures; do
  C_FIX=$FIX/$fx
  h_reset
  h_snapshot
  h_good "$fx snapshot" snapshot
  gen=$(h_gen) pass=$(h_fact pass) warn=$(h_fact warn) failed=$(h_fact fail)
  case "$pass:$warn:$failed" in *::* | :* | *: | *[!0-9:]*) fail "$fx counts are whole numbers: $pass:$warn:$failed" ;; *) ok ;; esac
  assert_eq "$(h_types)" 'omb-res 1 hello generation fact fact fact result ' "$fx snapshot is generation, three facts, result"
  assert_eq "$(h_total)" 0 "$fx snapshot total is zero"
  assert_eq "$(sed -n '4,6p' "$C_EV")" "fact	scope=health	key=doctor.pass	label=Passed	value=$pass	state=info
fact	scope=health	key=doctor.warn	label=Warnings	value=$warn	state=info
fact	scope=health	key=doctor.fail	label=Failures	value=$failed	state=info" "$fx exact count facts"
  assert_eq "$(sed -n 7p "$C_EV")" 'result	status=done	code=ok	text=	next=' "$fx exact done result"
  assert_eq "$(cat "$T/doctor")" 'read 0' "$fx snapshot: one Doctor capture, read intent, zero persistence"
  want=0
  [ "$failed" = 0 ] || want=1
  assert_eq "$(cat "$T/status")" "$want" "$fx cmd_doctor status is the baseline summary of $failed failure(s)"
  h_reset
  h_page "$gen"
  h_good "$fx detail" detail
  total=$(h_total)
  assert_eq "$(h_gen)" "$gen" "$fx detail shares the snapshot generation"
  assert_eq "$(h_rows | wc -l | tr -d ' ')" "$total" "$fx detail total is every finding"
  assert_eq "$(h_types)" "omb-res 1 hello generation $(awk -v n="$total" 'BEGIN { for (i = 0; i < n; i++) printf "row " }')result " "$fx detail is generation, rows, result"
  assert_eq "$(awk -F '\t' '$1 == "row" { printf "%s %s;", $2, $3 }' "$C_EV")" \
    "$(awk -v n="$total" 'BEGIN { for (i = 1; i <= n; i++) printf "kind=doctor key=%d;", i }')" "$fx one-based keys in owner order"
  assert_eq "$(awk -F '\t' '$1 == "row" && NF != 6' "$C_EV")" '' "$fx each row is status, label, detail"
  assert_eq "$(h_count pass) $(h_count warn) $(h_count fail)" "$pass $warn $failed" "$fx pass/warn/fail rows equal the owner's counters"
  info=$(h_count info)
  assert_eq "$((pass + warn + failed + info))" "$total" "$fx every row is pass, warn, fail or info"
  if [ "$info" -gt 0 ] && [ "$total" -gt $((pass + warn + failed)) ]; then ok; else fail "$fx info rows are shown, never counted"; fi
  assert_eq "$(sed -n '$p' "$C_EV")" 'result	status=done	code=ok	text=	next=' "$fx detail done result"
  assert_eq "$(cat "$T/doctor")" 'read 0' "$fx detail: one Doctor capture"
done

# Mandatory: a completed report with failed checks is `done ok`, not an error.
C_FIX=$FIX/linux-alarm-offline
h_reset
h_snapshot
h_good 'failed-health snapshot' snapshot
assert_eq "$(h_fact fail) $(cat "$T/status")" '1 1' 'a failed check: counted, and cmd_doctor returns 1'
gen=$(h_gen)
h_page "$gen"
h_good 'failed-health detail' detail
assert_contains "$(h_rows)" 'row	kind=doctor	key=5	col=fail	col=Network	col=no%20default%20route%20%E2%80%94%20run%20nmtui' 'the failed check is a row'
C_FIX=$FIX/linux-alarm-fresh
h_reset
h_snapshot
h_good 'healthy snapshot' snapshot
assert_eq "$(h_fact fail) $(cat "$T/status")" '0 0' 'no failed check: cmd_doctor returns 0'

# Generation: the whole scope dataset, stable for an identical capture and
# changed by any finding's detail, severity or presence, on page or off it.
V=$(t_variant linux-alarm-fresh)
C_FIX=$V
h_snapshot
h_good 'generation control' snapshot
g0=$(h_gen)
h_snapshot
assert_eq "$(h_gen)" "$g0" 'repeated identical capture: same generation'
h_page "$g0" 0 1
h_good 'first page' detail
assert_eq "$(h_gen)" "$g0" 'snapshot then detail: one generation'
assert_eq "$(h_rows)" 'row	kind=doctor	key=1	col=pass	col=aarch64	col=6.16.8-asahi-1-1-ARCH' 'first owner finding'
h_name "$V" 'Arch Linux ARM (renamed)'
h_snapshot
assert_eq "$(h_fact pass) $(h_fact warn) $(h_fact fail)" '8 0 0' 'a changed detail leaves every counter'
g1=$(h_gen)
assert_not_contains "$g1" "$g0" 'a changed finding detail changes the generation'
h_page "$g0" 0 1
h_refused 'old generation after a detail change' changed
assert_eq "$(h_gen) $(h_total)" "$g1 16" 'changed carries the fresh generation and total'
cp "$FIX/linux-alarm-fresh/root/etc/os-release" "$V/root/etc/os-release"
h_snapshot
assert_eq "$(h_gen)" "$g0" 'the restored finding restores the generation'
h_df "$V" 9000000
h_page "$g0" 0 1
h_refused 'off-page severity change (row 13)' changed
g2=$(h_gen)
assert_not_contains "$g2" "$g0" 'an off-page severity change changes the generation'
h_snapshot
assert_eq "$(h_fact pass) $(h_fact warn) $(h_fact fail) $(h_gen)" "7 1 0 $g2" 'severity moves the counters'
h_page "$g2" 12 1
assert_eq "$(h_rows)" 'row	kind=doctor	key=13	col=warn	col=Disk%20space	col=9%20GB%20free%20on%20/' 'the owner warning row'
h_df "$V" 1000000
h_reset
h_snapshot
h_good 'failed disk snapshot' snapshot
assert_eq "$(h_fact pass) $(h_fact warn) $(h_fact fail) $(cat "$T/status")" '7 0 1 1' 'failure counted, owner status 1, read done'
h_page "$(h_gen)" 12 1
h_good 'failed disk detail' detail
assert_eq "$(h_rows)" 'row	kind=doctor	key=13	col=fail	col=Disk%20space	col=1%20GB%20free%20on%20/' 'the owner failure row'
cp "$FIX/linux-alarm-fresh/cmd/df_root" "$V/cmd/df_root"
mv "$V/cmd/pagesize" "$T/pagesize"
h_snapshot
assert_eq "$(h_fact pass) $(h_fact warn) $(h_fact fail)" '8 0 0' 'removing an info finding leaves every counter'
g3=$(h_gen)
assert_not_contains "$g3" "$g0" 'a removed finding changes the generation'
h_page "$g3"
assert_eq "$(h_total)" 15 'one finding fewer'
mv "$T/pagesize" "$V/cmd/pagesize"
h_snapshot
assert_eq "$(h_gen)" "$g0" 'the restored fixture restores the generation'

# Paging over one whole capture; the generation does not depend on the page.
for limit in 1 7 500; do
  : >"$T/traversal"
  offset=0
  while [ "$offset" -lt 16 ]; do
    h_page "$g0" "$offset" "$limit"
    h_good "page $offset/$limit" detail
    assert_eq "$(h_gen) $(h_total)" "$g0 16" "page $offset/$limit generation and total"
    h_rows >>"$T/traversal"
    offset=$((offset + limit))
  done
  h_page "$g0" 0 500
  h_rows >"$T/all"
  if cmp -s "$T/traversal" "$T/all"; then ok; else fail "limit $limit traversal returns each row once, in order"; fi
done
h_page "$g0" 16 1
h_good 'offset equal to total' detail
assert_eq "$(h_rows)" '' 'offset equal to total: no rows'
h_page "$g0" 17 1
h_refused 'offset beyond total' invalid
assert_eq "$(h_gen) $(h_total)" "$g0 16" 'invalid offset: current generation and total'
C_ENV="OMB_SESSION_SCOPES=journey $H_TAPS" c_run snapshot "scope	name=journey"
journey=$(h_gen)
assert_not_contains "$journey" "$g0" 'scope-bound generations differ'
for other in "$zero" "$journey"; do
  h_reset
  h_page "$other" 999999999999999999 1
  h_refused 'stale or unknown generation precedes offset' changed
  assert_eq "$(h_gen) $(h_total)" "$g0 16" 'changed supplies the current dataset'
  assert_eq "$(cat "$T/doctor")" 'read 0' 'changed: one Doctor capture'
done
for fields in "generation=x	offset=0	limit=1" "generation=$g0	offset=0	limit=0" "generation=$g0	offset=0	limit=501" "offset=0	limit=1"; do
  h_reset
  C_ENV=$(h_env) c_run detail "page	scope=health	kind=doctor	$fields"
  assert_rc "$C_RC" 2 'malformed page refused at admission'
  assert_empty_file "$T/doctor" 'admission precedes any Doctor capture'
done
h_reset
h_page "$g0" 0 1 future
h_refused 'unsupported health kind' unavailable
assert_empty_file "$T/doctor" 'the kind refusal precedes any Doctor capture'

# Gate2-health-representation-failure: an owner-produced Distribution detail
# (row 4) that Protocol 1 cannot carry fails the whole dataset, before the
# requested page, a stale generation or offset handling is considered.
R=$(t_variant linux-alarm-fresh)
C_FIX=$R
h_snapshot
h_good 'representable control' snapshot
rg=$(h_gen)
long=$(awk 'BEGIN { for (i = 0; i < 5000; i++) printf "A" }')
for bad in long control; do
  case "$bad" in
    long) h_name "$R" "$long" ;;
    control) h_name "$R" "$(printf 'Arch\001Linux')" ;;
  esac
  for request in snapshot early-page stale offset-total beyond; do
    h_reset
    case "$request" in
      snapshot) h_snapshot; op=snapshot ;;
      early-page) h_page "$rg" 0 1; op=detail ;;
      stale) h_page "$zero" 0 1; op=detail ;;
      offset-total) h_page "$rg" 16 1; op=detail ;;
      beyond) h_page "$rg" 17 1; op=detail ;;
    esac
    h_fail "$bad $request" representation "$op"
    assert_eq "$(sed -n '$p' "$C_EV")" 'result	status=error	code=representation	text=The%20required%20health%20response%20cannot%20be%20represented%20in%20Protocol%201.	next=' "$bad $request exact response"
    assert_not_contains "$C_OUT" AAAAAAAA "$bad $request echoes no offending value"
    assert_not_contains "$C_OUT" '%01' "$bad $request echoes no offending byte"
    assert_eq "$(cat "$T/doctor")" 'read 0' "$bad $request one Doctor capture"
    assert_eq "$C_ERR" '' "$bad $request clean stderr"
  done
done
cp "$FIX/linux-alarm-fresh/root/etc/os-release" "$R/root/etc/os-release"
h_snapshot
assert_eq "$(h_gen)" "$rg" 'representable again: its generation'

# Routing: only an ordinary fixture session holding `health` captures Doctor.
C_FIX=$FIX/linux-alarm-fresh
for H_SCOPES in journey logs journey,logs; do
  h_reset
  h_snapshot
  assert_eq "$(c_result) $C_RC $(c_admits snapshot)" 'refused scope 0 ok' "health missing from $H_SCOPES: snapshot"
  h_page "$zero"
  assert_eq "$(c_result) $C_RC $(c_admits detail)" 'refused scope 0 ok' "health missing from $H_SCOPES: detail"
  assert_empty_file "$T/doctor" "health missing from $H_SCOPES: no Doctor capture"
done
H_SCOPES=journey,health,logs
h_reset
h_snapshot
h_good 'mixed session scopes' snapshot
assert_eq "$(cat "$T/doctor")" 'read 0' 'mixed session scopes: one Doctor capture'
H_SCOPES=''
c_uname_arm "$T/native"
C_PATH=$T/native:/usr/bin:/bin:/usr/sbin:/sbin H_EXTRA='OMB_FIXTURE= OMB_FRONTEND_DEV='
h_reset
h_snapshot
assert_eq "$(c_result) $C_RC $(c_admits snapshot)" 'refused unavailable 0 ok' 'non-fixture health snapshot'
h_page "$zero"
assert_eq "$(c_result) $C_RC $(c_admits detail)" 'refused unavailable 0 ok' 'non-fixture health detail'
assert_empty_file "$T/doctor" 'non-fixture: no Doctor capture'
H_SCOPES=journey H_EXTRA='OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_SESSION_INTENT=read OMB_SESSION_PURPOSE=frontend-check'
h_reset
h_snapshot
assert_eq "$(c_result) $C_RC $(c_admits snapshot)" 'refused scope 0 ok' 'startup-check health snapshot'
h_page "$zero"
assert_eq "$(c_result) $C_RC $(c_admits detail)" 'refused unavailable 0 ok' 'startup-check detail'
assert_empty_file "$T/doctor" 'startup-check: no Doctor capture'
H_SCOPES='' H_EXTRA='' C_PATH="$shims:/usr/bin:/bin:/usr/sbin:/sbin"

# Read effects at every ceiling: the Doctor owner's log_event runs under read
# intent with zero persistence and writes nothing; no other effect is reached.
for state in absent present; do
  if [ "$state" = present ]; then
    mkdir -p "$T/state"
    chmod 700 "$T/state"
    printf '%s\n' cfg_user=alex cfg_host=omarchy cfg_enc=1 >"$T/state/state.env"
    chmod 600 "$T/state/state.env"
  fi
  before=$(t_snapshot "$T/state")
  for ceiling in read plan act; do
    H_EXTRA="OMB_SESSION_INTENT=$ceiling"
    h_reset
    h_snapshot
    h_good "$state/$ceiling snapshot" snapshot
    gen=$(h_gen)
    rows=0
    for offset in 0 1; do
      h_page "$gen" "$offset" 1
      h_good "$state/$ceiling page $offset" detail
      rows=$(h_total)
    done
    assert_eq "$(sort -u "$T/doctor") $(h_lines "$T/doctor")" 'read 0 3' "$state/$ceiling one read-only capture per request"
    assert_eq "$(sort -u "$T/log")" 'read 0 doctor' "$state/$ceiling log_event reached only by doc, under read/0"
    assert_eq "$(h_lines "$T/log")" "$((rows * 3))" "$state/$ceiling log_event once per finding per capture"
    assert_empty_file "$T/effects" "$state/$ceiling no action, lock, state, run, download or operation record"
    assert_empty_file "$T/shims.log" "$state/$ceiling no sudo, installer, package, boot or network command"
    assert_eq "$(t_snapshot "$T/state")" "$before" "$state/$ceiling no state, log, plan, profile or lock written"
    assert_eq "$(grep -c '^action	' "$C_EV")" 0 "$state/$ceiling no advertised action"
  done
done
H_EXTRA=''
assert_eq "$(find "$T" -maxdepth 1 -name 'omarchy-bootstrap.*')" '' 'request scratch cleaned'
assert_eq "$(find "$SESS" -name '*.core' -o -name '*.worker-*')" '' 'no child identity residue'
t_done test-gate2-health
