#!/usr/bin/env bash
# CP1 compatibility, with S4's authorized fixture-only Logs and Health producers.
# shellcheck disable=SC2030,SC2031 # intentionally scoped core environments
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-cp1
T=$(t_tmp)
c_session
C_FIX=$FIX/linux-alarm-fresh
zero=$(printf '%064d' 0)
mkdir "$T/tool" "$T/closeout"
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$REPO/release" "$T/tool/"
git -C "$REPO" archive deaa62c62348ecd4274b74b6b3a00f506c9f243d | tar -x -C "$T/closeout" || exit 1
printf '\n. %q\n' "$TESTS_DIR/gate2-probe-taps.sh" >>"$T/tool/lib/common.sh"
cat >>"$T/tool/lib/core.sh" <<'TAPS'
eval "$(declare -f core_action_info | sed '1s/core_action_info/cp1_original_action_info/')"
core_action_info() { printf 'lookup\n' >>"$CP1_LOOKUPS"; cp1_original_action_info "$@"; }
eval "$(declare -f cmd_doctor | sed '1s/cmd_doctor/cp1_original_doctor/')"
cmd_doctor() { printf 'doctor %s %s\n' "$OMB_INTENT" "$OMB_PERSIST" >>"$CP1_OWNERS"; cp1_original_doctor; }
cmd_logs() { printf 'logs\n' >>"$CP1_OWNERS"; return 99; }
TAPS
cat >>"$T/tool/lib/logs.sh" <<'TAPS'
eval "$(declare -f core_logs_capture | sed '1s/core_logs_capture/cp1_original_logs_capture/')"
core_logs_capture() {
  printf 'logs %s %s\n' "$OMB_INTENT" "$OMB_PERSIST" >>"$CP1_OWNERS"
  cp1_original_logs_capture "$@"
}
TAPS
C_HOME=$T/tool
c_uname_arm "$T/native"
C_PATH=$T/native:/usr/bin:/bin:/usr/sbin:/sbin
before=$(t_snapshot "$T/state")

held() {
  # Match the existing identity/state/boot setup exactly, with no added probe.
  # An authorized Doctor capture adds only its own reads after that setup;
  # tests/test-gate2-health-proof.sh holds them to one BASE Doctor's sequence.
  local n
  n=$(wc -l <"$T/hello.probes" | tr -d ' ')
  if [ "${2:-}" = 'doctor read 0' ]; then
    if head -n "$n" "$T/probes" | cmp -s - "$T/hello.probes" && [ "$(wc -l <"$T/probes" | tr -d ' ')" -gt "$n" ]; then
      ok
    else
      fail "$1: probes are not the existing hello setup followed by Doctor's reads"
    fi
  elif cmp -s "$T/probes" "$T/hello.probes"; then ok; else fail "$1: probes differ from existing hello setup"; fi
  assert_eq "$(cat "$T/owners")" "${2:-}" "$1: only authorized producer, read intent, zero persistence"
  assert_empty_file "$T/lookups" "$1: no action lookup"
  assert_eq "$(t_snapshot "$T/state")" "$before" "$1: no state/log/lock/operation/effect"
  assert_eq "$(find "$SESS" -name '*.core' -o -name '*.worker-*')" '' "$1: no child residue"
  assert_eq "$(grep -c '^action	' "$C_EV")" 0 "$1: no advertised action"
  assert_eq "$C_ERR" '' "$1: clean stderr"
}

hello_probes() {
  : >"$T/probes"; : >"$T/lookups"; : >"$T/owners"
  C_ENV="$1" c_run hello
  assert_eq "$(c_result) $C_RC" 'done ok 0' 'session scopes admitted by actual core hello'
  cp "$T/probes" "$T/hello.probes"
  : >"$T/probes"; : >"$T/lookups"; : >"$T/owners"
}

for scope in health logs; do
  kind=doctor
  [ "$scope" = logs ] && kind=log
  for fixture in yes no; do
    fixture_env=""
    [ "$fixture" = no ] && fixture_env='OMB_FIXTURE= OMB_FRONTEND_DEV='
    for scopes in "$scope" journey journey,health,logs; do
      expected='refused unavailable'
      [ "$scopes" = journey ] && expected='refused scope'
      for op in snapshot detail; do
        owner=''
        if [ "$fixture" = yes ] && [ "$scopes" != journey ]; then
          owner='logs read 0'
          [ "$scope" = logs ] || owner='doctor read 0'
          expected='done ok'
          [ "$op" != detail ] || expected='refused changed'
        fi
        request_env="OMB_SESSION_SCOPES=$scopes $fixture_env G2_PROBES=$T/probes CP1_LOOKUPS=$T/lookups CP1_OWNERS=$T/owners"
        hello_probes "$request_env"
        record="scope	name=$scope"
        [ "$op" = detail ] && record="page	scope=$scope	kind=$kind	generation=$zero	offset=0	limit=1"
        C_ENV="$request_env" c_run "$op" "$record"
        assert_eq "$(c_result) $C_RC" "$expected 0" "$op/$scope/$scopes/$fixture"
        assert_eq "$(c_admits "$op")" ok 'new-scope response canonically admitted'
        held "$op/$scope/$scopes/$fixture" "$owner"
      done
    done
  done
  request_env="OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_SESSION_INTENT=read OMB_SESSION_PURPOSE=frontend-check G2_PROBES=$T/probes CP1_LOOKUPS=$T/lookups CP1_OWNERS=$T/owners"
  hello_probes "$request_env"
  C_ENV="$request_env" c_run snapshot "scope	name=$scope"
  assert_eq "$(c_result) $C_RC" 'refused scope 0' 'startup-check scope isolation'
  assert_eq "$(c_admits snapshot)" ok 'startup-check new-scope refusal admitted'
  held "startup-check/$scope"
  for op in snapshot detail; do
    record="scope	name=$scope"
    [ "$op" = detail ] && record="page	scope=$scope	kind=$kind	generation=$zero	offset=0	limit=1"
    C_HOME=$T/closeout c_run "$op" "$record"
    assert_eq "$(c_result) $C_RC" 'error type 2' 'new request against actual old core fails closed without fallback'
  done
done

# S4's kind checks also precede capture. Startup-check routing is unchanged.
for scope in logs health; do
  request_env="OMB_SESSION_SCOPES=$scope G2_PROBES=$T/probes CP1_LOOKUPS=$T/lookups CP1_OWNERS=$T/owners"
  hello_probes "$request_env"
  C_ENV="$request_env" c_run detail "page	scope=$scope	kind=future	generation=$zero	offset=0	limit=1"
  assert_eq "$(c_result) $C_RC" 'refused unavailable 0' "S4 unsupported $scope kind before capture"
  held "unsupported-$scope-kind"
done

# Even explicitly owned fake actions are journey-scoped, not new-scope actions.
C_HOME=$REPO
c_fixture
for scopes in health logs health,logs; do
  for action in test.read test.mutate test.handoff; do
    C_ENV="OMB_SESSION_SCOPES=$scopes" c_run execute "exec	action=$action	basis=$zero	confirm=test"
    assert_eq "$(c_result) $C_RC" 'refused scope 0' 'foundation action remains journey-scoped'
    assert_eq "$(c_admits execute)" ok 'foundation scope refusal admitted'
    assert_eq "$(t_snapshot "$T/state")" "$before" 'new scopes confer no fake action persistence'
  done
done
c_session

# Save actual CP1 responses for execution by S's frozen Rust parser, when asked.
save=${1:-}
if [ -n "$save" ]; then : >"$save/cases"; fi
normalized() {
  awk -F '\t' 'BEGIN {OFS="\t"} $1=="hello" {for(i=2;i<=NF;i++) if($i~/^(commit|source)=/) sub(/=.*/,"=",$i)} {print}' "$1"
}
# CP1-PLIST-M01: Class D, one proven blocker/derived-guide correction only.
# normalized() above remains the original hello-only normalizer.
cp1_key=APFSPhysicalStores.1.APFSPhysicalStore
cp1_diag='<stdin>: Could not extract value, error: No value at that key path or invalid key path: APFSPhysicalStores.1.APFSPhysicalStore'
cp1_false='The macOS container spans more than one physical store (disk0s2, <stdin>: Could not extract value, error: No value at that key path or invalid key path: APFSPhysicalStores.1.APFSPhysicalStore); the installer resizes only single-store containers.'
# Use the unchanged Protocol 1 encoder for fixed literal values; never use
# response-derived text as the expected defect signature.
cp1_wire() (
  t_load >/dev/null 2>&1
  . "$REPO/lib/records.sh"
  rec_line "$@"
)
cp1_blocker=$(cp1_wire blocker id mac.1 text "$cp1_false" fix '')
cp1_bad_guide=$(cp1_wire guide id next step 1 text "This Mac cannot continue: $cp1_false")
cp1_good_guide=$(cp1_wire guide id next step 1 text 'Run ./omarchy-bootstrap to survey this Mac and plan storage.')
cp1_done=$(cp1_wire result status 'done' code ok text '' next '')

cp1_generation() { awk -F '	' '$1=="generation" {sub(/^id=/,"",$2); print $2}' "$1"; }
cp1_admit() (
  t_load >/dev/null 2>&1
  # shellcheck source=lib/records.sh
  . "$REPO/lib/records.sh"
  rec_admit_file res "$1" "$2"
  st=$?
  omb_cleanup
  exit "$st"
)
cp1_snapshot_ok() {
  cp1_admit snapshot "$1" || return 1
  [ "$(grep -c '^generation	' "$1")" = 1 ] || return 1
  grep -Eq '^generation	id=[0-9a-f]{64}	total=0$' "$1" || return 1
  [ "$(tail -n 1 "$1")" = "$cp1_done" ]
}
cp1_healthy() {
  cp1_snapshot_ok "$1" || return 1
  [ "$(grep -c '^blocker	' "$1")" = 0 ] || return 1
  [ "$(grep -c '^guide	' "$1")" = 1 ] || return 1
  grep -Fxq "$cp1_good_guide" "$1"
}
cp1_projection_ok() {
  local file=$1 gen=$2 total rows
  cp1_admit detail "$file" || return 1
  [ "$(grep -c '^generation	' "$file")" = 1 ] || return 1
  [ "$(cp1_generation "$file")" = "$gen" ] || return 1
  total=$(sed -n 's/^generation	id=[0-9a-f]*	total=\([0-9]*\)$/\1/p' "$file")
  rows=$(grep -c '^row	' "$file")
  [ -n "$total" ] && [ "$total" -le 500 ] && [ "$rows" = "$total" ] || return 1
  [ "$(tail -n 1 "$file")" = "$cp1_done" ]
}
# Rebuild from admitted snapshot payload and FULL own-generation projections.
# read.sh prints machine facts, status facts/guide/code/blockers/messages, then
# status rows BEFORE machine rows. Its command substitution strips final LFs.
cp1_rebuild() {
  local dir=$1 side=$2 dataset sum
  dataset=$(
    printf 'scope	name=journey\n'
    awk -F '	' '$1!="omb-res 1" && $1!="hello" && $1!="generation" && $1!="result"' "$dir/$side.snapshot"
    awk -F '	' '$1=="row"' "$dir/$side.status"
    awk -F '	' '$1=="row"' "$dir/$side.machine"
  )
  printf '%s' "$dataset" >"$dir/$side.dataset" || return 1
  if command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 "$dir/$side.dataset") || return 1
  else
    sum=$(sha256sum "$dir/$side.dataset") || return 1
  fi
  [ "${sum%% *}" = "$(cp1_generation "$dir/$side.snapshot")" ]
}
cp1_replace_generation() {
  awk -F '	' -v g="$2" 'BEGIN {OFS="	"} $1=="generation" {$2="id="g} {print}' "$1"
}
# This is the real exception comparator; negative controls call it unchanged.
cp1_exception() {
  local dir=$1 oldgen newgen side kind
  [ "$(cat "$dir/fixture")" = "$FIX/mac-m1pro-1tb-roomy" ] || return 1
  [ "$(cat "$dir/state")" = '(absent)' ] || return 1
  [ ! -e "$T/state" ] || return 1
  [ "$(plutil -extract APFSPhysicalStores json -o - "$FIX/mac-m1pro-1tb-roomy/cmd/diskutil_info_root")" = '[{"APFSPhysicalStore":"disk0s2"}]' ] || return 1
  [ -s "$dir/old.witness/hits" ] || return 1
  [ "$(awk -v k="$cp1_key" '$0!=k {bad=1} END {print bad+0}' "$dir/old.witness/hits")" = 0 ] || return 1
  grep -Eq '^[1-9][0-9]*$' "$dir/old.witness/status" || return 1
  [ "$(cat "$dir/old.witness/value")" = "$cp1_diag" ] || return 1
  for side in old current; do
    [ "$(cat "$dir/$side.snapshot.rc")" = 0 ] || return 1
    cp1_snapshot_ok "$dir/$side.snapshot" || return 1
    for kind in machine status; do
      [ "$(cat "$dir/$side.$kind.rc")" = 0 ] || return 1
      cp1_projection_ok "$dir/$side.$kind" "$(cp1_generation "$dir/$side.snapshot")" || return 1
    done
    cp1_rebuild "$dir" "$side" || return 1
  done
  [ "$(grep -c '^blocker	' "$dir/old.snapshot")" = 1 ] || return 1
  grep -Fxq "$cp1_blocker" "$dir/old.snapshot" || return 1
  [ "$(grep -c '^guide	' "$dir/old.snapshot")" = 1 ] || return 1
  grep -Fxq "$cp1_bad_guide" "$dir/old.snapshot" || return 1
  cp1_healthy "$dir/current.snapshot" || return 1
  oldgen=$(cp1_generation "$dir/old.snapshot")
  newgen=$(cp1_generation "$dir/current.snapshot")
  [ "$oldgen" != "$newgen" ] || return 1
  # Transform ONLY the exact witnessed blocker, guide and verified generation.
  awk -F '	' -v b="$cp1_blocker" -v bad="$cp1_bad_guide" -v good="$cp1_good_guide" -v g="$newgen" '
    BEGIN {OFS="	"}
    $0==b {next}
    $0==bad {print good; next}
    $1=="generation" {$2="id="g}
    {print}' "$dir/old.snapshot" >"$dir/expected"
  normalized "$dir/expected" >"$dir/expected.norm"
  normalized "$dir/current.snapshot" >"$dir/current.norm"
  cmp -s "$dir/expected.norm" "$dir/current.norm" || return 1
  for kind in machine status; do
    cp1_replace_generation "$dir/old.$kind" "$newgen" >"$dir/expected"
    normalized "$dir/expected" >"$dir/expected.norm"
    normalized "$dir/current.$kind" >"$dir/current.norm"
    cmp -s "$dir/expected.norm" "$dir/current.norm" || return 1
  done
}
cp1_export() {
  if [ -n "$save" ]; then
    cp "$2" "$save/$1.doc"
    printf '%s %s\n' "$1" "$3" >>"$save/cases"
    if cmp -s "$2" "$save/$1.doc"; then ok; else fail "CP1-PLIST-M01 $1: raw current export"; fi
  fi
}
cp1_capture_pair() {
  local dir=$1 mode=$2 side kind gen op file
  mkdir -p "$dir"
  printf '%s' "$C_FIX" >"$dir/fixture"
  t_snapshot "$T/state" >"$dir/state"
  for side in old current; do
    mkdir "$dir/$side.witness"
    for op in snapshot machine status; do
      file=$dir/$side.$op
      kind=$op
      [ "$op" = snapshot ] || op=detail
      if [ "$side" = old ]; then
        C_HOME=$T/closeout C_ENV="OMB_SESSION_SCOPES=journey CP1_NATIVE=$cp1_native CP1_WITNESS=$dir/$side.witness CP1_MODE=$mode CP1_DIAGNOSTIC=$T/plist-diagnostic" \
          cp1_capture_request "$op" "$kind" "${gen:-}"
      else
        C_HOME=$REPO C_ENV="OMB_SESSION_SCOPES=journey,health,logs CP1_NATIVE=$cp1_native CP1_WITNESS=$dir/$side.witness CP1_MODE=$mode CP1_DIAGNOSTIC=$T/plist-diagnostic" \
          cp1_capture_request "$op" "$kind" "${gen:-}"
      fi
      assert_eq "$(c_result) $C_RC" 'done ok 0' "CP1-PLIST-M01 $mode $side $kind: own generation"
      assert_eq "$(c_admits "$op")" ok "CP1-PLIST-M01 $mode $side $kind: admission"
      cp "$C_EV" "$file"
      printf '%s' "$C_RC" >"$file.rc"
      if [ "$op" = snapshot ]; then gen=$(cp1_generation "$file"); fi
    done
  done
}
cp1_capture_request() {
  if [ "$1" = snapshot ]; then
    c_run snapshot "scope	name=journey"
  else
    c_run detail "page	scope=journey	kind=$2	generation=$3	offset=0	limit=500"
  fi
}
cp1_hash_report() {
  local dir=$1 label=$2 side sum
  for side in old current; do
    cp1_rebuild "$dir" "$side"
    assert_rc "$?" 0 "CP1-PLIST-M01 $label/$side: emitted hash equals independent reconstruction"
    if command -v shasum >/dev/null 2>&1; then
      sum=$(shasum -a 256 "$dir/$side.dataset")
    else
      sum=$(sha256sum "$dir/$side.dataset")
    fi
    printf 'CP1-PLIST-M01 rebuilt %s/%s: emitted=%s rebuilt=%s bytes=%s\n' "$label" "$side" "$(cp1_generation "$dir/$side.snapshot")" "${sum%% *}" "$(wc -c <"$dir/$side.dataset" | tr -d ' ')"
  done
}
cp1_pair_exact() {
  local dir=$1 kind
  for kind in snapshot machine status; do
    normalized "$dir/old.$kind" >"$dir/old.norm"
    normalized "$dir/current.$kind" >"$dir/current.norm"
    cmp -s "$dir/old.norm" "$dir/current.norm" || return 1
  done
}
cp1_stale() {
  local dir=$1 mode=$2 side kind own other gen supplied total changed
  changed=$(cp1_wire result status refused code changed text 'The journey dataset changed; open this detail from a fresh snapshot.' next '')
  for side in old current; do
    other=old
    [ "$side" != old ] || other=current
    gen=$(cp1_generation "$dir/$side.snapshot")
    supplied=$(cp1_generation "$dir/$other.snapshot")
    for kind in machine status; do
      own=$dir/$side.$kind
      total=$(sed -n 's/^generation	id=[0-9a-f]*	total=\([0-9]*\)$/\1/p' "$own")
      if [ "$side" = old ]; then
        C_HOME=$T/closeout C_ENV="OMB_SESSION_SCOPES=journey CP1_NATIVE=$cp1_native CP1_WITNESS=$dir/$side.witness CP1_MODE=$mode CP1_DIAGNOSTIC=$T/plist-diagnostic" \
          c_run detail "page	scope=journey	kind=$kind	generation=$supplied	offset=0	limit=500"
      else
        C_HOME=$REPO C_ENV="OMB_SESSION_SCOPES=journey,health,logs CP1_NATIVE=$cp1_native CP1_WITNESS=$dir/$side.witness CP1_MODE=$mode CP1_DIAGNOSTIC=$T/plist-diagnostic" \
          c_run detail "page	scope=journey	kind=$kind	generation=$supplied	offset=0	limit=500"
      fi
      assert_eq "$(c_result) $C_RC" 'refused changed 0' "CP1-PLIST-M01 $mode $side $kind cross generation"
      assert_eq "$(c_admits detail)" ok 'CP1-PLIST-M01 stale response admits'
      # Whole expected stale response: own fresh generation/total, no rows,
      # exact existing changed result, including empty next.
      awk -F '	' -v changed="$changed" '$1=="row" {next} $1=="result" {print changed; next} {print}' "$own" >"$dir/stale.expected"
      if cmp -s "$dir/stale.expected" "$C_EV"; then ok; else fail 'CP1-PLIST-M01 exact fresh-generation stale response'; fi
      printf 'CP1-PLIST-M01 stale %s/%s/%s: supplied=%s fresh=%s total=%s rows=0 refused changed\n' "$mode" "$side" "$kind" "$supplied" "$gen" "$total"
    done
  done
}
cp1_negative_controls() {
  local source=$1 mutation file
  for mutation in blocker-id blocker-text blocker-fix key-path first-store defective-guide corrected-guide fact message code row result-status result-code result-text result-next ordering generation-total old-generation current-generation additional-blocker retained-blocker no-witness; do
    rm -rf "$T/plist-negative"
    cp -R "$source" "$T/plist-negative"
    file=$T/plist-negative/old.snapshot
    case "$mutation" in
      blocker-id) sed 's/id=mac.1/id=mac.2/' "$file" >"$file.tmp" ;;
      blocker-text) sed 's/single-store%20containers/single-store%20disks/' "$file" >"$file.tmp" ;;
      blocker-fix) sed 's/	fix=$/	fix=changed/' "$file" >"$file.tmp" ;;
      key-path) sed 's/APFSPhysicalStores.1.APFSPhysicalStore/APFSPhysicalStores.2.APFSPhysicalStore/g' "$file" >"$file.tmp" ;;
      first-store) sed 's/disk0s2/disk9s2/g' "$file" >"$file.tmp" ;;
      defective-guide) sed 's/This%20Mac%20cannot%20continue:/This%20Mac%20cannot%20proceed:/' "$file" >"$file.tmp" ;;
      corrected-guide) file=$T/plist-negative/current.snapshot; sed 's/survey%20this%20Mac/survey%20another%20Mac/' "$file" >"$file.tmp" ;;
      fact) sed 's/label=Platform/label=Changed platform/' "$file" >"$file.tmp" ;;
      message) awk -F '	' '$1=="result" {print "message	level=info	text=extra"} {print}' "$file" >"$file.tmp" ;;
      code) awk -F '	' '$1=="result" {print "code	kind=token	value=extra"} {print}' "$file" >"$file.tmp" ;;
      row) file=$T/plist-negative/old.machine; sed 's/col=Platform/col=Changed platform/' "$file" >"$file.tmp" ;;
      result-status) sed 's/status=done/status=refused/' "$file" >"$file.tmp" ;;
      result-code) sed 's/code=ok/code=changed/' "$file" >"$file.tmp" ;;
      result-text) sed 's/	text=	next=$/	text=changed	next=/' "$file" >"$file.tmp" ;;
      result-next) sed 's/	next=$/	next=changed/' "$file" >"$file.tmp" ;;
      ordering) awk 'NR==4 {held=$0; next} NR==5 {print; print held; next} {print}' "$file" >"$file.tmp" ;;
      generation-total) sed 's/	total=0$/	total=1/' "$file" >"$file.tmp" ;;
      old-generation) cp1_replace_generation "$file" "$zero" >"$file.tmp" ;;
      current-generation) file=$T/plist-negative/current.snapshot; cp1_replace_generation "$file" "$zero" >"$file.tmp" ;;
      additional-blocker) awk -F '	' '$1=="result" {print "blocker	id=mac.2	text=extra	fix="} {print}' "$file" >"$file.tmp" ;;
      retained-blocker) file=$T/plist-negative/current.snapshot; cp "$T/plist-negative/old.snapshot" "$file.tmp" ;;
      no-witness) rm -f "$T/plist-negative/old.witness/hits" ;;
    esac
    if [ -f "$file.tmp" ]; then mv "$file.tmp" "$file"; fi
    if cp1_exception "$T/plist-negative" >/dev/null 2>&1; then
      fail "CP1-PLIST-M01 comparator accepted mutation $mutation"
    else
      ok
      printf 'CP1-PLIST-M01 rejected mutation: %s\n' "$mutation"
    fi
  done
}
cp1_roomy() {
  local original_path=$C_PATH dir=$T/plist-native side kind total mode
  cp1_native=$(command -v plutil)
  mkdir "$T/plist-bin"
  printf '%s\n' "$cp1_diag" >"$T/plist-diagnostic"
  cat >"$T/plist-bin/plutil" <<'PLUTIL'
#!/bin/sh
if [ "$2" = APFSPhysicalStores.1.APFSPhysicalStore ]; then
  printf '%s\n' "$2" >>"$CP1_WITNESS/hits"
  if [ "$CP1_MODE" = native ]; then
    "$CP1_NATIVE" "$@" >"$CP1_WITNESS/value"
    status=$?
  else
    cat >/dev/null
    : >"$CP1_WITNESS/value"
    if [ "$CP1_MODE" = diagnostic ]; then cat "$CP1_DIAGNOSTIC" >"$CP1_WITNESS/value"; fi
    status=31
  fi
  printf '%s\n' "$status" >"$CP1_WITNESS/status"
  cat "$CP1_WITNESS/value"
  exit "$status"
fi
exec "$CP1_NATIVE" "$@"
PLUTIL
  chmod +x "$T/plist-bin/plutil"
  C_PATH=$T/plist-bin:$original_path
  cp1_capture_pair "$dir" native
  cp1_healthy "$dir/current.snapshot"
  assert_rc "$?" 0 'CP1-PLIST-M01 current correctness is unconditional, even ordinary equality'
  if [ "$(cat "$dir/old.witness/value")" = "$cp1_diag" ]; then
    cp1_exception "$dir"
    assert_rc "$?" 0 'CP1-PLIST-M01 native witnessed exact Class D exception'
    cp1_stale "$dir" native
    printf 'CP1-PLIST-M01 native exception ACTIVE\n'
  else
    cp1_pair_exact "$dir"
    assert_rc "$?" 0 'CP1-PLIST-M01 non-leaking native C retains original exact equality'
    printf 'CP1-PLIST-M01 native exception INACTIVE: original exact preservation\n'
  fi
  cp1_hash_report "$dir" native
  for kind in snapshot machine status; do
    mode=detail
    [ "$kind" != snapshot ] || mode=snapshot
    cp1_export "mac-m1pro-1tb-roomy.$kind" "$dir/current.$kind" "$mode"
  done
  # Supplementary causal evidence, never substituted for the native pair.
  cp1_capture_pair "$T/plist-diagnostic-pair" diagnostic
  cp1_capture_pair "$T/plist-empty-pair" empty
  cp1_exception "$T/plist-diagnostic-pair"
  assert_rc "$?" 0 'CP1-PLIST-M01 causal diagnostic pair: exact exception and rebuilt hashes'
  cp1_pair_exact "$T/plist-empty-pair"
  assert_rc "$?" 0 'CP1-PLIST-M01 causal empty failure: original exact preservation'
  for side in old current; do
    assert_eq "$(cat "$T/plist-diagnostic-pair/$side.witness/status")" 31 'CP1-PLIST-M01 causal diagnostic failure status'
    assert_eq "$(cat "$T/plist-empty-pair/$side.witness/status")" 31 'CP1-PLIST-M01 causal empty failure has SAME status'
    assert_contains "$(cat "$T/plist-empty-pair/$side.witness/hits")" "$cp1_key" 'CP1-PLIST-M01 causal target reached'
    cp1_rebuild "$T/plist-empty-pair" "$side"
    assert_rc "$?" 0 'CP1-PLIST-M01 causal empty dataset independently rebuilt'
    printf 'CP1-PLIST-M01 generations %s: diagnostic=%s empty=%s\n' "$side" "$(cp1_generation "$T/plist-diagnostic-pair/$side.snapshot")" "$(cp1_generation "$T/plist-empty-pair/$side.snapshot")"
  done
  for kind in snapshot machine status; do
    if cmp -s "$T/plist-diagnostic-pair/current.$kind" "$T/plist-empty-pair/current.$kind"; then ok; else fail "CP1-PLIST-M01 current ignores failed stdout: $kind"; fi
  done
  if cmp -s "$T/plist-diagnostic-pair/current.dataset" "$T/plist-empty-pair/current.dataset"; then ok; else fail 'CP1-PLIST-M01 current causal dataset identical'; fi
  if cmp -s "$T/plist-diagnostic-pair/old.dataset" "$T/plist-empty-pair/old.dataset"; then fail 'CP1-PLIST-M01 frozen C causal dataset must differ'; else ok; fi
  cp1_hash_report "$T/plist-diagnostic-pair" diagnostic
  cp1_hash_report "$T/plist-empty-pair" empty
  cp1_stale "$T/plist-diagnostic-pair" diagnostic
  for side in old current; do
    for kind in machine status; do
      total=$(sed -n 's/^generation	id=[0-9a-f]*	total=\([0-9]*\)$/\1/p' "$T/plist-diagnostic-pair/$side.$kind")
      printf 'CP1-PLIST-M01 complete projection %s/%s: total=%s rows=%s limit=500\n' "$side" "$kind" "$total" "$(grep -c '^row	' "$T/plist-diagnostic-pair/$side.$kind")"
    done
  done
  cp1_negative_controls "$T/plist-diagnostic-pair"
  C_PATH=$original_path
}

compare() {
  local name=$1 op=$2
  shift 2
  c_run "$op" "$@"
  assert_eq "$(c_result) $C_RC" 'done ok 0' "$name: current response"
  assert_eq "$(c_admits "$op")" ok "$name: current admission"
  cp "$C_EV" "$T/current"
  if [ -n "$save" ]; then
    cp "$C_EV" "$save/$name.doc"
    printf '%s %s\n' "$name" "$op" >>"$save/cases"
  fi
  C_HOME=$T/closeout C_ENV="${C_ENV:-} OMB_SESSION_SCOPES=journey" c_run "$op" "$@"
  assert_eq "$(c_result) $C_RC" 'done ok 0' "$name: accepted C response"
  normalized "$T/current" >"$T/current.normalized"
  normalized "$C_EV" >"$T/old.normalized"
  if cmp -s "$T/current.normalized" "$T/old.normalized"; then ok; else fail "$name: changed beyond hello commit/source"; fi
}
C_FIX=$FIX/linux-alarm-fresh
compare hello hello
fixtures='linux-alarm-fresh linux-omarchy-installed'
for fx in $fixtures; do
  C_FIX=$FIX/$fx
  C_ENV=OMB_SESSION_SCOPES=journey,health,logs compare "$fx.snapshot" snapshot "scope	name=journey"
  gen=$(sed -n 's/^generation	id=\([^	]*\).*/\1/p' "$T/current")
  for kind in machine status; do
    C_ENV=OMB_SESSION_SCOPES=journey,health,logs compare "$fx.$kind" detail "page	scope=journey	kind=$kind	generation=$gen	offset=0	limit=500"
  done
done
if t_plutil 'CP1 old macOS journey responses'; then
  C_FIX=$FIX/mac-m1pro-1tb-roomy
  cp1_roomy
fi
C_ENV='OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_SESSION_INTENT=read OMB_SESSION_PURPOSE=frontend-check' compare startup-check snapshot "scope	name=journey"
assert_eq "$(grep -c '^fact	' "$T/current")" 4 'startup-check retains four facts'
assert_eq "$(grep -Ec '^(action|code)	' "$T/current")" 0 'startup-check has no action/token'
t_done test-cp1
