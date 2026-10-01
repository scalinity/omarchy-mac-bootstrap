#!/usr/bin/env bash
# S4: exact owner selection, raw bytes, whole-window admission and read purity.
# shellcheck disable=SC2030,SC2031,SC2317,SC2329 # scoped environments and test callbacks
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-logs
T=$(t_tmp)
c_session
C_FIX=$FIX/linux-alarm-fresh
C_ENV=OMB_SESSION_SCOPES=logs
zero=$(printf '%064d' 0)
empty=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
l_gen() { sed -n 's/^generation	id=\([^	]*\).*/\1/p' "$C_EV"; }
l_snapshot() { c_run snapshot "scope	name=logs"; }
l_page() { c_run detail "page	scope=logs	kind=${4:-log}	generation=$1	offset=${2:-0}	limit=${3:-500}"; }
l_good() {
  assert_eq "$(c_result) $C_RC" 'done ok 0' "$1 success"
  assert_eq "$(c_admits "$2")" ok "$1 admitted"
  assert_eq "$C_ERR" '' "$1 clean stderr"
}
l_fail() {
  assert_eq "$(c_result) $C_RC" "$2 $3 0" "$1 result"
  assert_eq "$(c_admits "$4")" ok "$1 admitted"
  assert_eq "$(cut -f1 "$C_EV" | tr '\n' ' ')" 'omb-res 1 hello generation result ' "$1 no partial data"
  assert_eq "$(l_gen)" "$empty" "$1 no usable generation"
}
l_rows() { sed -n '/^row	/p' "$C_EV"; }
l_raw() {
  tail -n 40 "$file" >"$T/expected-raw"
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/logs.sh
    . "$REPO/lib/logs.sh"
    omb_tmp_init
    core_logs_window "$file"
    st=$?
    cp "$OMB_TMP/logs.raw" "$T/captured-raw"
    omb_cleanup
    exit "$st"
  )
  assert_rc "$?" "${1:-0}" 'raw window capture status'
  if cmp -s "$T/expected-raw" "$T/captured-raw"; then ok; else fail 'raw capture differs from BASE tail bytes'; fi
}
l_snapshot
l_good absent snapshot
absent=$(l_gen)
assert_not_contains "$absent" "$empty" 'absence is a normal dataset'
assert_contains "$C_OUT" 'key=logs.lines	label=Lines	value=0	state=info' 'absent lines unconditional'
assert_contains "$C_OUT" 'message	level=info	text=No%20log%20yet.' 'absence message'
assert_not_contains "$C_OUT" 'key=logs.source' 'absence source omitted'
assert_eq "$(t_snapshot "$T/state")" '(absent)' 'no state creation'
C_ENV="OMB_SESSION_SCOPES=logs OMB_STATE_DIR=$T/missing/parents/state" l_snapshot
l_good nested-absence snapshot
assert_contains "$C_OUT" 'message	level=info	text=No%20log%20yet.' 'missing ancestors retain normal absence'
assert_eq "$(t_snapshot "$T/missing")" '(absent)' 'missing ancestors are not created'

# S4-H01: false -e/-L is not proof of ENOENT. Derive the BYTE component
# limit on this real filesystem, then drive admitted ordinary core requests.
mkdir "$T/path-parent" "$T/path-tool"
name_max=$(getconf NAME_MAX "$T/path-parent") || exit 1
case "$name_max" in '' | *[!0-9]* | 0*) fail 'NAME_MAX must be a positive decimal limit'; exit 1 ;; esac
if [ "${#name_max}" -gt 4 ] || [ "$name_max" -gt 2000 ]; then fail 'NAME_MAX control must fit Protocol metadata'; exit 1; fi
legal_component=$(LC_ALL=C awk -v n="$name_max" 'BEGIN {for(i=0;i<n;i++)printf "a"}')
legal_path=$T/path-parent/$legal_component
invalid_path=${legal_path}a
path_bytes=$(printf '%s' "$invalid_path/logs" | wc -c | tr -d ' ')
[ "$path_bytes" -lt 4096 ] || { fail 'H01 path must be representable metadata'; exit 1; }
printf '  S4-H01 NAME_MAX=%s over-limit=%s logs-path-bytes=%s\n' "$name_max" "$((name_max + 1))" "$path_bytes"
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$REPO/release" "$T/path-tool/"
cat >>"$T/path-tool/lib/core.sh" <<'TAPS'
core_action_info() { printf 'action\n' >>"$H01_EFFECTS"; return 99; }
state_lock() { printf 'lock\n' >>"$H01_EFFECTS"; return 99; }
state_set() { printf 'state\n' >>"$H01_EFFECTS"; return 99; }
log_event() { printf 'log\n' >>"$H01_EFFECTS"; return 99; }
run() { printf 'run\n' >>"$H01_EFFECTS"; return 99; }
fetch_upstream() { printf 'download\n' >>"$H01_EFFECTS"; return 99; }
core_op_write() { printf 'operation\n' >>"$H01_EFFECTS"; return 99; }
TAPS
cat >>"$T/path-tool/lib/logs.sh" <<'TAPS'
eval "$(declare -f core_logs_capture | sed '1s/core_logs_capture/h01_original_capture/')"
core_logs_capture() {
  printf '%s %s\n' "$OMB_INTENT" "$OMB_PERSIST" >>"$H01_AUTHORITY"
  h01_original_capture "$@"
}
TAPS
C_HOME=$T/path-tool
C_ENV="OMB_SESSION_SCOPES=logs OMB_STATE_DIR=$legal_path H01_EFFECTS=$T/path-effects H01_AUTHORITY=$T/path-authority"
: >"$T/path-effects"; : >"$T/path-authority"
l_snapshot; l_good NAME_MAX-absence snapshot
legal_absent=$(l_gen)
assert_not_contains "$legal_absent" "$empty" 'NAME_MAX absence has normal generation'
assert_contains "$C_OUT" 'key=logs.lines	label=Lines	value=0	state=info' 'NAME_MAX missing lines zero'
assert_contains "$C_OUT" 'message	level=info	text=No%20log%20yet.' 'NAME_MAX missing absence message'
assert_not_contains "$C_OUT" 'key=logs.source' 'NAME_MAX missing source omitted'
l_page "$legal_absent" 0 1; l_good NAME_MAX-empty-page detail
assert_eq "$(l_rows)" '' 'NAME_MAX offset zero equals empty total'
C_ENV="OMB_SESSION_SCOPES=logs OMB_STATE_DIR=$invalid_path H01_EFFECTS=$T/path-effects H01_AUTHORITY=$T/path-authority"
for request in snapshot stale empty-page large-offset; do
  case "$request" in
    snapshot) l_snapshot; h01_snapshot_gen=$(l_gen); op=snapshot ;;
    stale) l_page "$zero" 0 1; op=detail ;;
    empty-page) l_page "$h01_snapshot_gen" 0 1; op=detail ;;
    large-offset) l_page "$legal_absent" 999999999999999999 1; op=detail ;;
  esac
  l_fail "S4-H01 $request" error io "$op"
  assert_contains "$C_OUT" "generation	id=$empty	total=0" "S4-H01 $request zero total"
  assert_contains "$C_OUT" 'result	status=error	code=io	text=The%20logs%20response%20could%20not%20be%20prepared.	next=' "S4-H01 $request exact safe result"
  assert_not_contains "$C_OUT" "$invalid_path" "S4-H01 $request no path echo"
  assert_eq "$C_ERR" '' "S4-H01 $request clean stderr"
done
assert_eq "$(cat "$T/path-authority")" "$(printf 'read 0\nread 0\nread 0\nread 0\nread 0\nread 0')" 'H01 and legal control only read intent / zero persistence'
assert_empty_file "$T/path-effects" 'H01 no action, lock, state, log, run, download or operation record'
assert_eq "$(ls -A "$T/path-parent")" '' 'H01 and NAME_MAX control create no state/log/operation record'
assert_eq "$(find "$T" -maxdepth 1 -name 'omarchy-bootstrap.*')" '' 'H01 private request scratch cleaned'
assert_eq "$(find "$SESS" -name '*.core' -o -name '*.worker-*')" '' 'H01 no child identity residue'

# S4-H02: the filesystem, not the production classifier, proves legality.
# This native block deliberately has no Linux emulation or counted skip.
if [ "$(uname -s)" = Darwin ]; then
  device=$(df -P "$T/path-parent" | awk 'NR==2 {print $1}')
  /usr/sbin/diskutil info -plist "$device" >"$T/path-volume.plist" || exit 1
  filesystem=$(plutil -extract FilesystemType raw -o - "$T/path-volume.plist") || exit 1
  if [ "$filesystem" = apfs ]; then
    decomposed=''; encoded=''; unit=$(printf 'e\314\201'); i=0
    while [ "$i" -lt 100 ]; do decomposed=$decomposed$unit; encoded=${encoded}e%CC%81; i=$((i + 1)); done
    decomposed_path=$T/path-parent/$decomposed
    assert_eq "$(printf '%s' "$decomposed" | wc -c | tr -d ' ')" 300 'H02 exact decomposed UTF-8 bytes'
    mkdir "$decomposed_path" || exit 1
    assert_eq "$(test -d "$decomposed_path" && printf observable)" observable 'H02 native APFS positive creation witness'
    rmdir "$decomposed_path" || exit 1
    assert_eq "$(t_snapshot "$decomposed_path")" '(absent)' 'H02 exact decomposed spelling removed'
    # Supplementary-plane boundary: 127 emoji + ASCII = 255 UTF-16 units;
    # 128 emoji = 256. Raw bytes and scalar count would choose wrong limits.
    emoji=''; unit=$(printf '\360\237\230\200'); i=0
    while [ "$i" -lt 127 ]; do emoji=$emoji$unit; i=$((i + 1)); done
    mkdir "$T/path-parent/${emoji}a" || exit 1
    assert_eq "$(test -d "$T/path-parent/${emoji}a" && printf observable)" observable 'H02 supplementary-plane legal boundary witness'
    rmdir "$T/path-parent/${emoji}a" || exit 1
    if mkdir "$T/path-parent/$emoji$unit" 2>/dev/null; then
      rmdir "$T/path-parent/$emoji$unit"; fail 'H02 supplementary-plane over-limit unexpectedly created'
    else ok; fi
    printf '  S4-H02 native APFS witness: NAME_MAX=%s raw=300; supplementary boundary created/removed\n' "$name_max"
    : >"$T/path-effects"; : >"$T/path-authority"
    C_ENV="OMB_SESSION_SCOPES=logs OMB_STATE_DIR=$decomposed_path H01_EFFECTS=$T/path-effects H01_AUTHORITY=$T/path-authority"
    l_snapshot; l_good APFS-decomposed-absence snapshot
    decomposed_gen=$(l_gen)
    assert_not_contains "$decomposed_gen" "$empty" 'H02 absence has usable generation'
    assert_eq "$(cut -f1 "$C_EV" | tr '\n' ' ')" 'omb-res 1 hello generation fact fact fact message result ' 'H02 snapshot exact record sequence'
    assert_contains "$C_OUT" "key=logs.state_dir	label=State	value=$T/path-parent/$encoded	state=info" 'H02 State retains exact decomposed bytes'
    assert_contains "$C_OUT" "key=logs.directory	label=Logs	value=$T/path-parent/$encoded/logs	state=info" 'H02 Logs retains exact decomposed bytes'
    assert_contains "$C_OUT" 'key=logs.lines	label=Lines	value=0	state=info' 'H02 lines zero'
    assert_contains "$C_OUT" 'message	level=info	text=No%20log%20yet.' 'H02 absence message'
    assert_not_contains "$C_OUT" 'key=logs.source' 'H02 no selected source'
    l_page "$decomposed_gen" 0 1; l_good APFS-decomposed-empty-page detail
    assert_eq "$(l_gen)" "$decomposed_gen" 'H02 detail same raw-location generation'
    assert_contains "$C_OUT" "generation	id=$decomposed_gen	total=0" 'H02 detail empty total'
    assert_eq "$(l_rows)" '' 'H02 detail no rows'
    l_snapshot; l_good APFS-decomposed-repeat snapshot
    assert_eq "$(l_gen)" "$decomposed_gen" 'H02 exact raw spelling stable generation'
    # Actual core must fail closed if the native classifier cannot execute or
    # emits an unusable answer. The shim changes machinery, never FS semantics.
    cat >>"$T/path-tool/lib/logs.sh" <<'QUERY'
osascript() {
  case "${H02_QUERY:-}" in
    fail) return 127 ;;
    unusable) printf 'unexpected\n' ;;
    *) command osascript "$@" ;;
  esac
}
QUERY
    for query in fail unusable; do
      C_ENV="OMB_SESSION_SCOPES=logs OMB_STATE_DIR=$invalid_path H01_EFFECTS=$T/path-effects H01_AUTHORITY=$T/path-authority H02_QUERY=$query"
      l_snapshot; l_fail "H02 native query $query snapshot" error io snapshot
      l_page "$legal_absent" 0 1; l_fail "H02 native query $query detail" error io detail
    done
    assert_eq "$(cat "$T/path-authority")" "$(printf 'read 0\nread 0\nread 0\nread 0\nread 0\nread 0\nread 0')" 'H02 read intent / zero persistence'
    assert_empty_file "$T/path-effects" 'H02 no action, lock, state, log, run, download or operation record'
    assert_eq "$(ls -A "$T/path-parent")" '' 'H02 parent empty after setup and requests'
    assert_eq "$(find "$T" -maxdepth 1 -name 'omarchy-bootstrap.*')" '' 'H02 private request scratch cleaned'
    assert_eq "$(find "$SESS" -name '*.core' -o -name '*.worker-*')" '' 'H02 no child identity residue'
    printf '  S4-H02 native APFS real-core snapshot/detail/repeat completed\n'

    # H03: full original lookup and relocated components prove different
    # properties. Native characterization is independent of the classifier.
    l_native_errno() {
      command osascript -l JavaScript -e 'ObjC.import("stdlib"); ObjC.bindFunction("faccessat", ["int", ["int", "char *", "int", "int"]]); ObjC.bindFunction("__error", ["int *", []]); function run(a) { var r=$.faccessat(-2,a[0],0,0x0020); return r===0 ? 0 : $.__error()[0]; }' "$1"
    }
    aggregate_path=$decomposed_path/$decomposed/$decomposed/$decomposed
    (
      t_load >/dev/null 2>&1
      # shellcheck source=lib/records.sh
      . "$REPO/lib/records.sh"
      rec_enc "$aggregate_path/logs"
      omb_cleanup
    ) >"$T/h03-encoded-path"
    encoded_bytes=$(wc -c <"$T/h03-encoded-path" | tr -d ' ')
    if [ "$encoded_bytes" -lt 4096 ]; then ok; else fail 'H03 full Logs metadata must be representable'; fi
    printf '  S4-H03 full Logs raw=%s encoded=%s bytes\n' "$(printf '%s' "$aggregate_path/logs" | wc -c | tr -d ' ')" "$encoded_bytes"
    assert_eq "$(l_native_errno "$decomposed_path")" 2 'H03 relocated decomposed component native ENOENT'
    assert_eq "$(l_native_errno "$T/path-parent/logs")" 2 'H03 relocated logs component native ENOENT'
    full_errno=$(l_native_errno "$aggregate_path/logs") || exit 1
    if [ "$full_errno" = 63 ]; then
      h03_boundary=native
      printf '  S4-H03 NATIVE full-path ENAMETOOLONG; all relocated components ENOENT\n'
    else
      assert_eq "$full_errno" 2 'H03 host without aggregate bound must report missing'
      h03_boundary=full-invalid
      printf '  S4-H03 INJECTED CLASSIFIER BOUNDARY (host full lookup errno=%s)\n' "$full_errno"
    fi
    # Inject only the full native call's outcome into the unchanged fixed
    # classifier source; run its aggregation and all ordinary core machinery.
    cat >>"$T/path-tool/lib/logs.sh" <<'H03_QUERY'
osascript() {
  local script=$4 needle='var full = $.faccessat(-2, a[0], 0, 0x0020);'
  case "${H03_QUERY:-native}" in
    full-success | full-invalid)
      case "$script" in *"$needle"*) ;; *) return 127 ;; esac
      case "$H03_QUERY" in
        full-success) script=${script/"$needle"/'var full = 0;'} ;;
        full-invalid)
          script=${script/"$needle"/'var full = -1;'}
          needle='var fullErr = full === 0 ? 0 : $.__error()[0];'
          script=${script/"$needle"/'var fullErr = 63;'}
          ;;
      esac
      shift 4
      command osascript -l JavaScript -e "$script" "$@"
      ;;
    *) command osascript "$@" ;;
  esac
}
H03_QUERY
    : >"$T/path-effects"; : >"$T/path-authority"
    for boundary in "$h03_boundary" full-success; do
      if [ "$boundary" = full-success ]; then printf '  S4-H03 INJECTED CLASSIFIER BOUNDARY: full lookup success in missing branch\n'; fi
      C_ENV="OMB_SESSION_SCOPES=logs OMB_STATE_DIR=$aggregate_path H01_EFFECTS=$T/path-effects H01_AUTHORITY=$T/path-authority H03_QUERY=$boundary"
      for request in snapshot stale legal-absence large-offset; do
        case "$request" in
          snapshot) l_snapshot; op=snapshot ;;
          stale) l_page "$zero" 0 1; op=detail ;;
          legal-absence) l_page "$legal_absent" 0 1; op=detail ;;
          large-offset) l_page "$legal_absent" 999999999999999999 1; op=detail ;;
        esac
        l_fail "H03 $boundary/$request" error io "$op"
        assert_contains "$C_OUT" "generation	id=$empty	total=0" 'H03 empty generation and total'
        assert_contains "$C_OUT" 'result	status=error	code=io	text=The%20logs%20response%20could%20not%20be%20prepared.	next=' 'H03 exact safe result'
        assert_eq "$C_ERR" '' 'H03 clean stderr'
      done
    done
    hidden_invalid=$T/path-parent/missing/$legal_component/a$legal_component
    assert_eq "$(l_native_errno "$hidden_invalid/logs")" 2 'H03 full ENOENT at early missing component'
    assert_eq "$(l_native_errno "$T/path-parent/a$legal_component")" 63 'H03 later relocated ASCII component ENAMETOOLONG'
    C_ENV="OMB_SESSION_SCOPES=logs OMB_STATE_DIR=$hidden_invalid H01_EFFECTS=$T/path-effects H01_AUTHORITY=$T/path-authority"
    l_snapshot; l_fail H03-hidden-invalid-component error io snapshot
    l_page "$legal_absent" 0 1; l_fail H03-hidden-invalid-component-detail error io detail
    assert_eq "$(grep -c '^read 0$' "$T/path-authority")" 10 'H03 ten requests read intent / zero persistence'
    assert_eq "$(wc -l <"$T/path-authority" | tr -d ' ')" 10 'H03 no other authority'
    assert_empty_file "$T/path-effects" 'H03 no action, lock, state, log, run, download or operation record'
    assert_eq "$(ls -A "$T/path-parent")" '' 'H03 parent remains empty'
    assert_eq "$(find "$T" -maxdepth 1 -name 'omarchy-bootstrap.*')" '' 'H03 scratch cleaned'
    assert_eq "$(find "$SESS" -name '*.core' -o -name '*.worker-*')" '' 'H03 no child identity residue'
    printf '  S4-H03 real-core snapshot/detail precedence and component control completed\n'
  else
    printf '  S4-H02 native APFS evidence not provided by filesystem %s\n' "$filesystem"
  fi
fi
C_HOME='' C_ENV=OMB_SESSION_SCOPES=logs
mkdir -p "$T/state/logs"
file=$T/state/logs/omarchy-bootstrap-20260902.log
: >"$file"
l_raw
l_snapshot
l_good selected-empty snapshot
selected_empty=$(l_gen)
assert_not_contains "$selected_empty" "$absent" 'selected empty differs from absence'
assert_contains "$C_OUT" 'key=logs.source	label=Source	value=omarchy-bootstrap-20260902.log' 'empty selected source'
assert_contains "$C_OUT" 'key=logs.lines	label=Lines	value=0' 'empty lines zero'
assert_not_contains "$C_OUT" 'No%20log%20yet.' 'empty has no absence message'
l_page "$selected_empty"
l_good empty-page detail
assert_contains "$C_OUT" 'total=0' 'empty detail total'
rm "$file"
l_snapshot
assert_eq "$(l_gen)" "$absent" 'absent generation restored'

# Actual canonical writer formats, padding, brackets, and exact message spaces.
(
  t_load >/dev/null 2>&1
  OMB_STATE_DIR=$T/state OMB_PERSIST=1 OMB_PHASE=phase
  now_utc() { printf '2026-09-30T12:34:56Z'; }
  log_file() { printf '%s' "$file"; }
  for level in start record refuse dryrun exec exit stop reconcile; do log_event "$level" '  message  '; done
  omb_cleanup
)
l_snapshot
l_good canonical snapshot
gen=$(l_gen)
l_page "$gen"
l_good canonical detail
n=0
for level in start record refuse dryrun exec exit stop reconcile; do
  n=$((n + 1))
  assert_contains "$C_OUT" "row	kind=log	key=$n	col=2026-09-30T12:34:56Z	col=$level	col=%5Bphase%5D	col=%20%20message%20%20" "$level writer parsed exactly"
done
# Unterminated/trailing/blank/percent/UTF-8 raw cases; generation uses raw bytes.
for sample in terminated unterminated blank internal trailing multiple leading spaces arbitrary malformed utf8 percent; do
  case "$sample" in
    terminated) printf 'line\n' >"$file"; want=1 ;;
    unterminated) printf line >"$file"; want=1 ;;
    blank) printf '\n' >"$file"; want=1 ;;
    internal) printf 'a\n\nb\n' >"$file"; want=3 ;;
    trailing) printf 'line\n\n' >"$file"; want=2 ;;
    multiple) printf 'line\n\n\n' >"$file"; want=3 ;;
    leading) printf '  leading\n' >"$file"; want=1 ;;
    spaces) printf 'trailing  \n' >"$file"; want=1 ;;
    arbitrary) printf '[phase] arbitrary\n' >"$file"; want=1 ;;
    malformed) printf '2026-09-30T12:34:56Z [p] exec x\n' >"$file"; want=1 ;;
    utf8) printf '\303\251\n' >"$file"; want=1 ;;
    percent) printf '%% =\n' >"$file"; want=1 ;;
  esac
  cp "$file" "$T/expected-raw"
  l_raw
  l_snapshot
  l_good "$sample snapshot" snapshot
  assert_contains "$C_OUT" "key=logs.lines	label=Lines	value=$want" "$sample count"
  current=$(l_gen)
  l_page "$current"
  l_good "$sample detail" detail
  assert_eq "$(grep -c '^row	' "$C_EV")" "$want" "$sample row count"
  assert_eq "$(l_gen)" "$current" "$sample generation stable between surfaces"
  # Independently construct the opaque row via canonical encoding.
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    i=0
    while IFS= read -r line || [ -n "$line" ]; do
      i=$((i + 1))
      rec_line row kind log key "$i" col '' col '' col '' col "$line"
    done <"$file"
    omb_cleanup
  ) >"$T/expected-rows"
  l_rows >"$T/actual-rows"
  if cmp -s "$T/expected-rows" "$T/actual-rows"; then ok; else fail "$sample exact opaque rows"; fi
  if [ "$sample" = terminated ]; then terminated_gen=$current; fi
  if [ "$sample" = unterminated ]; then assert_not_contains "$current" "$terminated_gen" 'final LF binds generation'; fi
done

# Window boundaries, selection, mtime disagreement, stable/outside generations.
for count in 40 41; do
  awk -v n="$count" 'BEGIN {for(i=1;i<=n;i++)print "line" i}' >"$file"
  l_raw
  l_snapshot; l_good "$count lines" snapshot
  gen=$(l_gen)
  l_page "$gen"; l_good "$count window" detail
  assert_eq "$(grep -c '^row	' "$C_EV")" 40 'window exactly forty rows'
  first=$((count - 39))
  assert_contains "$C_OUT" "row	kind=log	key=1	col=	col=	col=	col=line$first" 'first selected line'
done
printf 'excluded changed\n' >"$T/changed"
tail -n 40 "$file" >>"$T/changed"
cp "$T/changed" "$file"
l_snapshot
assert_eq "$(l_gen)" "$gen" 'outside-window change does not change generation'
printf 'appended\n' >>"$file"
l_snapshot
assert_not_contains "$(l_gen)" "$gen" 'append changing window changes generation'
# 40th line without LF.
awk 'BEGIN {for(i=1;i<40;i++)print "line" i; printf "last"}' >"$file"
l_raw
l_snapshot; gen=$(l_gen); l_page "$gen"
l_good forty-unterminated detail
assert_contains "$C_OUT" 'total=40' 'unterminated fortieth counts'
assert_contains "$C_OUT" 'key=40	col=	col=	col=	col=last' 'unterminated last bytes'
printf '\n' >>"$file"
l_snapshot
assert_not_contains "$(l_gen)" "$gen" 'fortieth final LF changes generation'
for name in 20260901 20260831; do printf 'wrong\n' >"$T/state/logs/omarchy-bootstrap-$name.log"; done
printf 'ignore\n' >"$T/state/logs/unrelated.log"
touch -t 202001010000 "$file"
touch -t 202609301200 "$T/state/logs/omarchy-bootstrap-20260901.log"
l_snapshot
assert_contains "$C_OUT" 'value=omarchy-bootstrap-20260902.log' 'sort selection overrides mtime'
gen=$(l_gen)
cp "$file" "$T/state/logs/omarchy-bootstrap-20260903.log"
l_snapshot
assert_not_contains "$(l_gen)" "$gen" 'same rows different selected source changes generation'
rm "$T/state/logs/omarchy-bootstrap-20260903.log"
l_snapshot
assert_eq "$(l_gen)" "$gen" 'original selected source restores generation'

# Pages traverse one entire capture; maximum protocol limit remains legal.
for limit in 1 7 500; do
  : >"$T/traversal"
  offset=0
  while [ "$offset" -lt 40 ]; do
    l_page "$gen" "$offset" "$limit"; l_good "page $offset/$limit" detail
    l_rows >>"$T/traversal"
    offset=$((offset + limit))
  done
  l_page "$gen" 0 500
  l_rows >"$T/all"
  if cmp -s "$T/traversal" "$T/all"; then ok; else fail 'page traversal changed rows'; fi
done
l_page "$gen" 40 1; l_good offset-total detail
assert_eq "$(l_rows)" '' 'offset total empty'
l_page "$gen" 41 1
assert_eq "$(c_result)" 'refused invalid' 'offset beyond total'
for other in "$zero" "$absent"; do
  l_page "$other" 999999999999999999 1
  assert_eq "$(c_result)" 'refused changed' 'stale/unknown before offset'
  assert_eq "$(l_gen)" "$gen" 'changed supplies current dataset'
  assert_eq "$(l_rows)" '' 'changed no rows'
done
for fields in "generation=x	offset=0	limit=1" "generation=$gen	offset=0	limit=0" "generation=$gen	offset=0	limit=501" "offset=0	limit=1"; do
  c_run detail "page	scope=logs	kind=log	$fields"
  assert_rc "$C_RC" 2 'malformed page admission'
  assert_not_contains "$(c_result)" changed 'admission is not changed'
done
l_page "$gen" 0 1 future
assert_eq "$(c_result)" 'refused unavailable' 'unsupported logs kind'

# Whole-window overflow precedes stale/current and even offset-total requests.
for bad in encoded invalid-utf8 nul control long giant; do
  awk 'BEGIN {for(i=1;i<40;i++)print "safe"}' >"$file"
  case "$bad" in
    encoded) printf '%1366s\n' '' >>"$file" ;;
    invalid-utf8) printf '\377\n' >>"$file" ;;
    nul) printf 'a\000b\n' >>"$file" ;;
    control) printf 'a\001b\n' >>"$file" ;;
    long) printf '%04097d\n' 0 >>"$file" ;;
    giant) awk 'BEGIN {for(i=0;i<700000;i++)printf "A";print ""}' >>"$file" ;;
  esac
  if [ "$bad" = nul ]; then
    l_raw 3
  elif [ "$bad" = giant ]; then
    (
      t_load >/dev/null 2>&1
      # shellcheck source=lib/logs.sh
      . "$REPO/lib/logs.sh"
      omb_tmp_init
      core_logs_window "$file"
      st=$?
      wc -c <"$OMB_TMP/logs.raw" >"$T/retained-size"
      omb_cleanup
      exit "$st"
    )
    assert_rc "$?" 3 'giant selected window overflows'
    assert_eq "$(tr -d ' ' <"$T/retained-size")" 655401 'giant retained scratch capped at proof byte'
  else l_raw; fi
  l_snapshot; l_fail "$bad snapshot" refused overflow snapshot
  assert_contains "$C_OUT" 'text=The%20selected%20log%20window%20cannot%20be%20represented%20in%20Protocol%201.	next=' 'exact overflow text'
  for offset in 0 40; do
    l_page "$gen" "$offset" 1; l_fail "$bad off-page $offset" refused overflow detail
  done
  l_page "$zero" 0 1; l_fail "$bad stale" refused overflow detail
done
printf '%04096d\n' 0 >"$file"
l_snapshot; l_good exact-value-bound snapshot
l_page "$(l_gen)"; l_good exact-value-bound detail
# Giant excluded prefix is neither retained nor part of the generation.
cp "$file" "$T/window"
awk 'BEGIN {for(i=0;i<1000000;i++)printf "X"; print "";for(i=1;i<40;i++)print "safe"}' >"$file"
cat "$T/window" >>"$file"
l_snapshot; l_good giant-excluded-prefix snapshot
assert_contains "$C_OUT" 'key=logs.lines	label=Lines	value=40' 'giant excluded line ignored'

# Metadata errors are distinct, safely worded, and never echo bad paths.
printf 'safe\n' >"$file"
mkdir -p "$T/state/logs/omarchy-bootstrap-bad"
printf 'safe\n' >"$T/state/logs/omarchy-bootstrap-bad/omarchy-bootstrap-$(printf '\001').log"
l_snapshot; l_fail bad-source error representation snapshot
assert_not_contains "$C_OUT" '%01' 'offending basename not echoed'
l_page "$zero" 0 1; l_fail bad-source-detail error representation detail
rm -rf "$T/state/logs/omarchy-bootstrap-bad"
state_bad=$T/state-$(printf '\001')
mkdir -p "$state_bad/logs"
printf 'safe\n' >"$state_bad/logs/omarchy-bootstrap-safe.log"
C_ENV="OMB_SESSION_SCOPES=logs OMB_STATE_DIR=$state_bad" l_snapshot
l_fail bad-location error representation snapshot
assert_not_contains "$C_OUT" '%01' 'offending location not echoed'
C_ENV="OMB_SESSION_SCOPES=logs OMB_STATE_DIR=$state_bad" l_page "$zero" 0 1
l_fail bad-location-detail error representation detail
oversized=$T/$(printf '%04097d' 0)
C_ENV="OMB_SESSION_SCOPES=logs OMB_STATE_DIR=$oversized" l_snapshot
l_fail oversized-location error representation snapshot
assert_not_contains "$C_OUT" "$oversized" 'oversized location not echoed'

# Real core purity at every ceiling, pages and errors: only read probes, no
# action owner, source writes, persistent records, or request scratch residue.
before=$(t_snapshot "$T/state")
for ceiling in read plan act; do
  C_ENV="OMB_SESSION_SCOPES=logs OMB_SESSION_INTENT=$ceiling" l_snapshot
  l_good "$ceiling snapshot" snapshot
  gen=$(l_gen)
  for offset in 0 1; do
    C_ENV="OMB_SESSION_SCOPES=logs OMB_SESSION_INTENT=$ceiling" l_page "$gen" "$offset" 1
    l_good "$ceiling page $offset" detail
  done
  assert_eq "$(t_snapshot "$T/state")" "$before" "$ceiling no persistent effect/source modification"
done
assert_eq "$(find "$T" -maxdepth 1 -name 'omarchy-bootstrap.*')" '' 'request scratch cleaned'
assert_eq "$(find "$SESS" -name '*.core' -o -name '*.worker-*')" '' 'no child identity residue'
t_done test-gate2-logs
