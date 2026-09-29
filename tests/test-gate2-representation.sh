#!/usr/bin/env bash
# Reviewed containment: canonical bounds, whole capture, and exact publication.
# shellcheck disable=SC2030,SC2031,SC2317,SC2329 # scoped environments and test-only callbacks
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-representation
T=$(t_tmp)
c_session
C_FIX=$(t_variant linux-alarm-fresh)
zero=$(printf '%064d' 0)
empty=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
safe='The%20required%20journey%20response%20cannot%20be%20represented%20in%20Protocol%201.'
r_gen() { sed -n 's/^generation	id=\([^	]*\).*/\1/p' "$C_EV"; }
r_page() { c_run detail "page	scope=journey	kind=$1	generation=$2	offset=${3:-0}	limit=${4:-1}"; }
r_error() {
  assert_eq "$(c_result) $C_RC" 'error representation 0' "$1: delivered representation error"
  assert_eq "$(c_admits "$2")" ok "$1: whole error admitted"
  assert_eq "$(cut -f1 "$C_EV" | tr '\n' ' ')" 'omb-res 1 hello generation result ' "$1: no partial candidate records"
  assert_eq "$(sed -n 3p "$C_EV")" "generation	id=$empty	total=0" "$1: no unusable generation"
  assert_eq "$(tail -n 1 "$C_EV")" "result	status=error	code=representation	text=$safe	next=" "$1: fixed safe result"
}
r_all_errors() {
  c_run snapshot "scope	name=journey"
  r_error "$1 snapshot" snapshot
  assert_eq "$C_ERR" '' "$1 snapshot: clean stderr"
  for kind in machine status; do
    for offset in 0 999999999999999999; do
      r_page "$kind" "$zero" "$offset"
      r_error "$1 $kind offset $offset" detail
      assert_eq "$C_ERR" '' "$1 $kind: clean stderr"
    done
  done
}

# Independently retained value owners; neither invalid input is repaired.
if t_plutil 'reviewed token counterexamples'; then
  C_FIX=$FIX/mac-m1pro-1tb-roomy
  mkdir -p "$T/state"
  tz=$(printf '%0513d' 0 | tr 0 A)
  assert_eq "$( (t_load; valid_tz "$tz" && printf accepted) )" accepted 'baseline timezone syntax admits 513 ASCII bytes'
  printf 'cfg_user=alex\ncfg_tz=%s\n' "$tz" >"$T/state/state.env"
  r_all_errors oversized-timezone
  assert_not_contains "$C_OUT" "$tz" 'oversized owner value not echoed'
  # 14-byte omb2:user=alex + 4-byte ,tz= + 494-byte tz = 512.
  for n in 494 495; do
    tz=$(printf "%0${n}d" 0 | tr 0 A)
    printf 'cfg_user=alex\ncfg_tz=%s\n' "$tz" >"$T/state/state.env"
    c_run snapshot "scope	name=journey"
    if [ "$n" = 494 ]; then
      assert_eq "$(c_result)" 'done ok' 'exact decoded code bound 512 accepted'
      assert_eq "$(c_admits snapshot)" ok '512 decoded bytes canonically admitted'
    else r_error 'decoded code 513' snapshot; fi
  done
  printf 'cfg_user=root\n' >"$T/state/state.env"
  token=$( (t_load; OMB_STATE_DIR=$T/state; state_init; cfg_load; token_encode) )
  assert_eq "$token" 'omb2:' 'canonical owner rejects loaded root and yields empty-body token'
  assert_eq "$( (t_load; OMB_STATE_DIR=$T/state; state_init; state_get cfg_user) )" root 'raw user presence remains nonempty'
  r_all_errors raw-root
  assert_not_contains "$C_OUT" 'omb2:' 'invalid owner token not echoed'
  rm -rf "$T/state"
fi

# Existing opaque upstream owner permits printable spaces: encoding, not its
# baseline semantics, makes this value exceed 4096 written bytes.
C_FIX=$(t_variant linux-omarchy-installed)
printf '0\n' >"$C_FIX/cmd/id_u"
spaces=$(printf '%1365s' '')
printf '%sA\n' "$spaces" >"$C_FIX/cmd/setup_status"
c_run snapshot "scope	name=journey"
assert_eq "$(c_result) $(c_admits snapshot)" 'done ok ok' '4096 written-byte owner value succeeds'
g1=$(r_gen)
printf 'changed but representable\n' >"$C_FIX/cmd/setup_status"
r_page machine "$g1"
assert_eq "$(c_result)" 'refused changed' 'representable G1 to G2 still changed'
assert_not_contains "$(r_gen)" "$g1" 'changed supplies usable G2'
assert_eq "$(grep -c '^row	' "$C_EV")" 0 'changed has no rows'
printf '%sAB\n' "$spaces" >"$C_FIX/cmd/setup_status"
r_all_errors written-value-4097
r_page machine "$g1"
r_error 'old G1 to unrepresentable current dataset' detail

# The helper below uses the real producer for settled success cases and a
# test-only captured material file for unreachable record/envelope extremes.
# Admission wrappers observe the live prefix and retain the last admitted
# exact response; they never add a production record or test seam.
C_FIX=$(t_variant linux-alarm-fresh)
c_run snapshot "scope	name=journey"
hello=$(sed -n 2p "$C_EV")
normal=$(r_gen)
helper() {
  local op=$1 kind=${2:-machine} gen=${3:-$normal} offset=${4:-0} limit=${5:-1}
  c_prepare "$op"
  printf '%s\n' "$hello" >>"$C_EV"
  cp "$C_EV" "$T/live-prefix"
  : >"$T/captures"
  : >"$T/leaked"
  rm -f "$T/admitted"
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    # shellcheck source=lib/core.sh
    . "$REPO/lib/core.sh"
    # shellcheck source=lib/read.sh
    . "$REPO/lib/read.sh"
    OMB_INTENT=read OMB_PERSIST=0 OMB_FIXTURE=$C_FIX OMB_STATE_DIR=$T/state
    platform_init
    state_init
    omb_tmp_init
    CORE_EVENTS=$C_EV CORE_OP=$op CORE_RECS=1 CORE_RESULT=0
    CORE_REQ_KIND=$kind CORE_REQ_GENERATION=$gen CORE_REQ_OFFSET=$offset CORE_REQ_LIMIT=$limit
    eval "$(declare -f core_journey_dataset | sed '1s/core_journey_dataset/r_dataset_original/')"
    core_journey_dataset() {
      printf x >>"$T/captures"
      if [ "${R_MATERIAL:-0}" = 1 ]; then cat "$T/material"; else r_dataset_original; fi
    }
    eval "$(declare -f core_read_admit | sed '1s/core_read_admit/r_admit_original/')"
    core_read_admit() {
      local st
      cmp -s "$C_EV" "$T/live-prefix" || printf leaked >>"$T/leaked"
      case "${R_FAULT:-}" in
        admission-execute) return 127 ;;
        admission-read) rm -f "$2" ;;
      esac
      r_admit_original "$@"
      st=$?
      if [ "$st" = 0 ]; then cp "$2" "$T/admitted" || return 1; fi
      # Machine input can change after proof: the captured bytes still own
      # the requested response and generation, with no second capture.
      if [ "${R_MUTATE:-0}" = 1 ]; then printf 'invalid later input\n' >"$T/material"; fi
      return "$st"
    }
    case "${R_FAULT:-}" in
      staging-create) mkdir "$OMB_TMP/journey.response" ;;
      staging-read)
        cat() { case "$1" in */journey.prefix) return 1 ;; esac; command cat "$@"; }
        ;;
      admission-awk)
        awk() { case "$*" in *'hdr=omb-res 1'*) return 127 ;; esac; command awk "$@"; }
        ;;
      hash) shasum() { case "$*" in */journey) return 1 ;; esac; command shasum "$@"; } ;;
      publish-read) tail() { return 1; } ;;
    esac
    if [ "$op" = snapshot ]; then core_journey_snapshot; else core_journey_detail; fi
    omb_cleanup
  ) >"$T/helper.out" 2>"$T/helper.err"
  C_RC=$? C_OUT=$(cat "$C_EV") C_ERR=$(cat "$T/helper.err")
  assert_eq "$(cat "$T/captures")" x 'one authoritative capture'
  assert_empty_file "$T/leaked" 'only exact header/hello live during preflight'
}
success() {
  assert_eq "$(c_result) $C_RC" 'done ok 0' "$1: success"
  assert_eq "$(c_admits "$2")" ok "$1: whole response admitted"
  if cmp -s "$T/admitted" "$C_EV"; then ok; else fail "$1: published bytes differ from admitted bytes"; fi
  assert_eq "$C_ERR" '' "$1: clean stderr"
}
helper snapshot
success snapshot snapshot
for kind in machine status; do
  helper detail "$kind" "$normal" 0 1
  success "$kind offset 0 limit 1" detail
  helper detail "$kind" "$normal" 0 500
  success "$kind multirow" detail
  total=$(sed -n 's/^generation.*	total=//p' "$C_EV")
  helper detail "$kind" "$normal" "$total" 1
  success "$kind offset equals total" detail
  assert_eq "$(grep -c '^row	' "$C_EV")" 0 "$kind total page is empty"
done

# Test-only material reaches boundaries absent from today's baseline owners.
material_errors() {
  R_MATERIAL=1 helper snapshot
  r_error "$1 snapshot" snapshot
  for kind in machine status; do
    R_MATERIAL=1 helper detail "$kind" "$normal" 0 1
    r_error "$1 $kind page one" detail
  done
}
awk 'BEGIN { print "scope\tname=journey"; for (i=0; i<500; i++) printf "row\tkind=status\tkey=%d\tcol=safe\n",i; printf "row\tkind=status\tkey=500\tcol="; for(i=0;i<4097;i++)printf "A"; print "" }' >"$T/material"
material_errors off-page-status
awk 'BEGIN { print "scope\tname=journey"; printf "row\tkind=machine\tkey=x\tcol="; for(i=0;i<4097;i++)printf "A"; print "" }' >"$T/material"
material_errors bad-machine

for extra in 0 1; do
  awk -v extra="$extra" 'BEGIN { print "scope\tname=journey"; for(i=0;i<4096;i++)x=x "A"; s="row\tkind=machine\tkey=x\tcol=" x "\tcol=" x "\tcol=" x "\tcol="; print s substr(x,1,16384-length(s)+extra) }' >"$T/material"
  assert_eq "$(awk 'NR==2 {print length}' "$T/material")" "$((16384 + extra))" 'record boundary excludes LF'
  assert_eq "$(awk -F '\t' 'NR==2 {for(i=2;i<=NF;i++){sub(/^[^=]*=/,"",$i);if(length($i)>4096)bad=1} print bad+0}' "$T/material")" 0 'individual values remain legal at record boundary'
  if [ "$extra" = 0 ]; then
    R_MATERIAL=1 helper snapshot
    success '16384-byte row individually legal' snapshot
  else material_errors record-16385; fi
done

awk 'BEGIN { print "scope\tname=journey"; for(i=0;i<4096;i++)x=x "A"; for(i=0;i<2048;i++)print "message\tlevel=info\ttext=" x }' >"$T/material"
assert_eq "$(awk 'END {print NR-1}' "$T/material")" 2048 'byte envelope test remains below record count bound'
material_errors response-over-8MiB
awk 'BEGIN { print "scope\tname=journey"; for(i=0;i<65534;i++)print "message\tlevel=info\ttext=A" }' >"$T/material"
assert_eq "$(awk 'END {print NR-1+3}' "$T/material")" 65537 'record envelope includes hello, generation, result'
material_errors response-record-65537

# Rows are pageable, not a giant response: exceeding the global response's
# record count across the entire projection is legal. Each page is admitted.
awk 'BEGIN { print "scope\tname=journey"; for(i=0;i<65537;i++)print "row\tkind=machine\tkey=" i }' >"$T/material"
R_MATERIAL=1 helper snapshot
success '65537 pageable rows do not need one response' snapshot

printf 'scope\tname=journey\nrow\tkind=machine\tkey=x\tcol=original\n' >"$T/material"
R_MATERIAL=1 R_MUTATE=1 helper snapshot
success 'input changes after admission without recapture' snapshot
for fault in staging-create staging-read admission-execute admission-read admission-awk hash publish-read; do
  R_FAULT=$fault helper snapshot
  assert_eq "$(c_result) $C_RC" 'error io 0' "$fault: machinery failure is io"
  assert_eq "$(c_admits snapshot)" ok "$fault: complete safe io response admitted"
  assert_eq "$(cut -f1 "$C_EV" | tr '\n' ' ')" 'omb-res 1 hello generation result ' "$fault: no candidate leak"
  assert_eq "$(r_gen)" "$empty" "$fault: empty generation"
done

# Successful bytes after the truthful hello stay identical to the reviewed F
# producer, including the generation and both requested projections.
mkdir "$T/reviewed"
git -C "$REPO" archive 5a7c659c29b32a4de94f07aa938dc084b3585ed6 | tar -x -C "$T/reviewed" || exit 1
fixtures='linux-alarm-fresh linux-omarchy-installed'
if t_plutil 'reviewed successful response bytes'; then fixtures="$fixtures mac-m1pro-1tb-roomy"; fi
for fixture in $fixtures; do
  C_FIX=$FIX/$fixture
  c_run snapshot "scope	name=journey"
  gen=$(r_gen)
  sed -n '3,$p' "$C_EV" >"$T/candidate"
  C_HOME=$T/reviewed c_run snapshot "scope	name=journey"
  sed -n '3,$p' "$C_EV" >"$T/previous"
  if cmp -s "$T/candidate" "$T/previous"; then ok; else fail "$fixture: snapshot changed from reviewed F"; fi
  for kind in machine status; do
    r_page "$kind" "$gen" 0 500
    sed -n '3,$p' "$C_EV" >"$T/candidate"
    C_HOME=$T/reviewed r_page "$kind" "$gen" 0 500
    sed -n '3,$p' "$C_EV" >"$T/previous"
    if cmp -s "$T/candidate" "$T/previous"; then ok; else fail "$fixture/$kind: detail changed from reviewed F"; fi
  done
done
t_done test-gate2-representation
