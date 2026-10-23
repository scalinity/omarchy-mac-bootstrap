#!/usr/bin/env bash
# S4 Health evidence: BASE Doctor equivalence (findings, counters, status,
# probes, rendered text) and one capture with exact admitted-byte publication.
# shellcheck disable=SC2030,SC2031,SC2162,SC2317,SC2329 # scoped environments and callbacks; read taps forward the caller's own flags
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-health-proof
T=$(t_tmp)
BASELINE=2edb76a7de3f78ec90927ac93d5eec3a84636253
mkdir -p "$T/base" "$T/home" "$T/tmp" "$T/tool"
git -C "$REPO" archive "$BASELINE" | tar -x -C "$T/base" || exit 1
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$REPO/release" "$T/tool/"
printf '\n. %q\n' "$TESTS_DIR/gate2-probe-taps.sh" >>"$T/tool/lib/common.sh"
cat >>"$T/tool/lib/doctor.sh" <<'DOCTOR'
eval "$(declare -f cmd_doctor | sed '1s/cmd_doctor/p_actual_doctor/')"
cmd_doctor() { printf 'doctor\n' >>"$G2_PROBES.doctor"; p_actual_doctor; }
DOCTOR
shims=$(t_shims "$T")
P_PATH="$shims:/usr/bin:/bin:/usr/sbin:/sbin"
mac=0
t_plutil 'Health BASE Doctor equivalence' && mac=1
c_session
p_gen() { sed -n 's/^generation	id=\([^	]*\).*/\1/p' "$C_EV"; }
p_tags() { grep -E '^   \[(PASS|WARN|FAIL|INFO)\] ' "$1"; }
p_fact() { sed -n "s/^fact	scope=health	key=doctor\\.$1	label=[A-Za-z]*	value=\\([0-9]*\\)	state=info\$/\\1/p" "$C_EV"; }

# Supporting evidence only (behaviour is proved below): the owner functions
# the producer invokes are BASE's, byte for byte.
p_owner() {
  # shellcheck disable=SC2016 # expanded by the child bash
  "$T_BASH" -c 'for m in common ui state sources storage macos asahi linux shared doctor dev; do . "$1/lib/$m.sh"; done
    declare -f cmd_doctor mac_doctor doc doc_summary shared_doctor ui_tag _ui_status_style' _ "$1"
}
assert_eq "$(p_owner "$REPO")" "$(p_owner "$T/base")" 'supporting: the Doctor owner and its presentation seam are BASE byte for byte'

# doctor-ssh-findings: lx_doctor adds exactly one call, after the disk
# findings and before the existing SSH service facts. All its other bytes
# and every unchanged owner function remain the accepted baseline's.
p_linux_owner() {
  # shellcheck disable=SC2016 # expanded by the child bash
  "$T_BASH" -c '. "$1/lib/doctor.sh"; declare -f lx_doctor' _ "$1"
}
p_linux_owner "$REPO" >"$T/lx.current"
p_linux_owner "$T/base" >"$T/lx.base"
assert_eq "$(grep -c '^    doc_ssh;$' "$T/lx.current")" 1 'doctor-ssh-findings: exactly one added owner call'
sed '/^    doc_ssh;$/d' "$T/lx.current" >"$T/lx.less"
# M16-system-names: BASE's header draws the protocol value, the candidate's the
# name a person reads. That one word of that one line is the only other byte.
# shellcheck disable=SC2016 # BASE's source text, not an expansion
assert_eq "$(grep -c '^    ui_header "linux \$G_DOT doctor";$' "$T/lx.base")" 1 'M16-system-names: BASE draws the Linux Doctor header with the protocol value'
# shellcheck disable=SC2016 # BASE's source text, not an expansion
assert_eq "$(grep -c '^    ui_header "Linux \$G_DOT doctor";$' "$T/lx.less")" 1 'M16-system-names: the candidate draws it as Linux'
# shellcheck disable=SC2016 # BASE's source text, not an expansion
sed 's/^    ui_header "linux \$G_DOT doctor";$/    ui_header "Linux $G_DOT doctor";/' "$T/lx.base" >"$T/lx.base.names"
if cmp -s "$T/lx.less" "$T/lx.base.names"; then ok; else fail 'doctor-ssh-findings: all other lx_doctor bytes equal BASE'; fi

# p_oracle TREE MODE NAME [ARGS] — tests/gate2-doctor-oracle.sh over $fixture.
p_oracle() {
  local tree=$1 mode=$2 name=$3
  shift 3
  env -i PATH="$P_PATH" HOME="$T/home" TMPDIR="$T/tmp" LANG=en_US.UTF-8 TERM=dumb \
    OMB_STATE_DIR="$T/state" OMB_FIXTURE="$fixture" SHIM_LOG="$T/shims.log" OMB_TEST_RECORD="$T/record" \
    G2_CANDIDATE="$REPO" G2_PROBES="$T/$name.probes" G2_NO_SSH="${P_NO_SSH:-0}" G2_EXTENSIONS="${P_EXTENSIONS:-0}" \
    "$T_BASH" "$TESTS_DIR/gate2-doctor-oracle.sh" "$tree" "$mode" "$@" >"$T/$name.out" 2>"$T/$name.err"
}
p_norm() { sed "s|$2|TREE|g" "$1"; }

# p_fixture NAME — BASE's Doctor over $fixture against the current owner, the
# BASE text command and the actual typed snapshot and detail.
p_fixture() {
  local name=$1 before bst bpass bwarn bfail want trc arch gen
  before=$(t_snapshot "$fixture")
  saved=$(t_snapshot "$T/state")
  : >"$T/shims.log"; : >"$T/record"
  p_oracle "$T/base" findings base
  assert_rc "$?" 0 "$name BASE Doctor oracle runs"
  P_NO_SSH=1 p_oracle "$REPO" findings current
  assert_rc "$?" 0 "$name current Doctor oracle runs"
  assert_eq "$(cat "$T/current.out")" "$(cat "$T/base.out")" "$name current owner findings equal BASE"
  assert_eq "$(cat "$T/current.probes.summary")" "$(cat "$T/base.probes.summary")" "$name current owner status and counters equal BASE"
  assert_eq "$(cat "$T/current.probes")" "$(cat "$T/base.probes")" "$name current owner probes equal BASE"
  assert_eq "$(p_norm "$T/current.err" "$REPO")" "$(p_norm "$T/base.err" "$T/base")" "$name current owner diagnostics equal BASE"
  read -r bst bpass bwarn bfail <"$T/base.probes.summary"
  want=0
  [ "$bfail" = 0 ] || want=1
  assert_eq "$bst" "$want" "$name BASE cmd_doctor status summarizes $bfail failure(s)"
  assert_eq "$(awk -F '\t' '{ c[$4]++ } END { printf "%d %d %d", c["col=pass"], c["col=warn"], c["col=fail"] }' "$T/base.out")" \
    "$bpass $bwarn $bfail" "$name BASE findings agree with BASE counters"
  env -i PATH="$P_PATH" HOME="$T/home" TMPDIR="$T/tmp" LANG=en_US.UTF-8 TERM=dumb \
    OMB_STATE_DIR="$T/state" OMB_FIXTURE="$fixture" SHIM_LOG="$T/shims.log" OMB_TEST_RECORD="$T/record" \
    "$T_BASH" "$T/base/omarchy-bootstrap" --ascii --no-color doctor >"$T/base.text" 2>/dev/null
  trc=$?
  assert_eq "$trc" "$bst" "$name BASE text doctor exits with the summary status"
  # Independently capture the complete current owner, then the explicit
  # AI/restore extension interfaces and action reads. BASE equivalence above
  # excludes only the tested SSH call; these are the new Health dataset.
  P_EXTENSIONS=1 p_oracle "$REPO" findings complete
  assert_rc "$?" 0 "$name complete current findings run"
  if [ "$(cat "$fixture/cmd/uname_s")" = Linux ]; then
    assert_eq "$(grep -c $'col=SSH%20policy\t' "$T/complete.out")" 1 "$name doctor-ssh-findings policy"
    assert_eq "$(grep -c $'col=Image%20alarm%20account\t' "$T/complete.out")" 1 "$name doctor-ssh-findings image account"
  fi
  awk 'BEGIN { FS=OFS="\t" } { $3="key=" NR; print }' "$T/complete.out" >"$T/expected.rows"
  read -r bpass bwarn bfail <<EOF_COUNTS
$(awk -F '\t' '{ c[$4]++ } END { printf "%d %d %d", c["col=pass"], c["col=warn"], c["col=fail"] }' "$T/expected.rows")
EOF_COUNTS
  arch=$(cat "$fixture/cmd/uname_m" 2>/dev/null)
  C_FIX=$fixture C_HOME=$T/tool C_PATH=$P_PATH
  if [ "$arch" != arm64 ] && [ "$arch" != aarch64 ]; then
    C_ENV="OMB_SESSION_SCOPES=health G2_PROBES=$T/hello.probes SHIM_LOG=$T/shims.log" c_run snapshot "scope	name=health"
    assert_rc "$C_RC" 2 "$name outside Protocol 1's ARM hello: no read"
  else
    : >"$T/hello.probes"
    C_ENV="OMB_SESSION_SCOPES=health G2_PROBES=$T/hello.probes SHIM_LOG=$T/shims.log" c_run hello
    assert_eq "$(c_result) $C_RC" 'done ok 0' "$name hello"
    cat "$T/hello.probes" "$T/complete.probes" >"$T/doctor.probes"
    cat "$T/doctor.probes" "$T/complete.probes.report" >"$T/want.probes"
    # M16-report-reads: these observations belong to the report, separately
    # from the BASE-equivalent Doctor reads checked above.
    assert_eq "$(awk -F '\t' '$1=="row" {sub(/^key=/,"",$3); printf "%s%s",sep,$3; sep=" "}' "$T/complete.probes.report.rows")" \
      'mac disk shared linux qualification restore doctor recovery' "$name M16-report-reads: eight report observations"
    : >"$T/typed.probes.doctor"
    : >"$T/typed.probes"; : >"$T/typed.probes.doctor"
    C_ENV="OMB_SESSION_SCOPES=health G2_PROBES=$T/typed.probes SHIM_LOG=$T/shims.log" c_run snapshot "scope	name=health"
    assert_eq "$(c_result) $C_RC $(c_admits snapshot)" 'done ok 0 ok' "$name typed snapshot done, even with $bfail failure(s)"
    if cmp -s "$T/typed.probes" "$T/want.probes"; then ok; else fail "$name M16-report-reads: snapshot probes are hello, one Doctor, extensions, report"; fi
    assert_eq "$(cat "$T/typed.probes.doctor")" doctor "$name M16-report-reads: exactly one Doctor invocation"
    tpass=$(p_fact pass) twarn=$(p_fact warn) tfail=$(p_fact fail)
    assert_eq "$tpass $twarn $tfail" "$bpass $bwarn $bfail" "$name snapshot facts equal BASE counters"
    assert_eq "$(printf '%s\n' "$C_ERR" | sed "s|$T/tool|TREE|g")" "$(p_norm "$T/base.err" "$T/base")" "$name typed diagnostics are BASE Doctor's alone"
    gen=$(p_gen)
    : >"$T/typed.probes"; : >"$T/typed.probes.doctor"
    C_ENV="OMB_SESSION_SCOPES=health G2_PROBES=$T/typed.probes SHIM_LOG=$T/shims.log" c_run detail "page	scope=health	kind=doctor	generation=$gen	offset=0	limit=500"
    assert_eq "$(c_result) $C_RC $(c_admits detail) $(p_gen)" "done ok 0 ok $gen" "$name typed detail shares the generation"
    if cmp -s "$T/typed.probes" "$T/want.probes"; then ok; else fail "$name M16-report-reads: Doctor detail has the same complete dataset reads"; fi
    assert_eq "$(cat "$T/typed.probes.doctor")" doctor "$name M16-report-reads: Doctor detail invokes Doctor once"
    grep '^row	' "$C_EV" >"$T/typed.rows"
    if cmp -s "$T/typed.rows" "$T/expected.rows"; then ok; else fail "$name typed rows equal the complete owner capture and named extensions: count, order, status, label, detail"; fi
    sed '1,2d' "$C_EV" >"$T/typed.body"
    C_HOME=$REPO C_ENV=OMB_SESSION_SCOPES=health c_run detail "page	scope=health	kind=doctor	generation=$gen	offset=0	limit=500"
    sed '1,2d' "$C_EV" >"$T/actual.body"
    if cmp -s "$T/typed.body" "$T/actual.body"; then ok; else fail "$name the untapped core answers the same bytes"; fi
    : >"$T/typed.probes"; : >"$T/typed.probes.doctor"
    C_HOME=$T/tool C_ENV="OMB_SESSION_SCOPES=health G2_PROBES=$T/typed.probes SHIM_LOG=$T/shims.log" \
      c_run detail "$(printf 'page\tscope=health\tkind=report\tgeneration=%s\toffset=0\tlimit=500' "$gen")"
    assert_eq "$(c_result) $C_RC $(c_admits detail) $(p_gen)" "done ok 0 ok $gen" "$name M16-report-reads: report shares the generation"
    if cmp -s "$T/typed.probes" "$T/want.probes"; then ok; else fail "$name M16-report-reads: report detail has the same complete dataset reads"; fi
    assert_eq "$(cat "$T/typed.probes.doctor")" doctor "$name M16-report-reads: report invokes Doctor once"
    assert_eq "$(grep '^row' "$C_EV")" "$(cat "$T/complete.probes.report.rows")" "$name M16-report-reads: all report rows equal separate observations"
    # Supplementary: typed rows and counts through BASE's own presentation
    # reproduce BASE's doctor lines, summary and exit status.
    if [ "$(cat "$fixture/cmd/uname_s")" = Linux ]; then
      # Only the two named SSH findings and four extension rows are new.
      awk 'BEGIN { FS=OFS="\t" }
        $5 ~ /^col=(SSH%20policy|Image%20alarm%20account|Claude%20Code|Codex|OpenCode|Restore)$/ { next }
        { $3="key=" ++n; print }' "$T/typed.rows" >"$T/typed.base.rows"
    else cp "$T/typed.rows" "$T/typed.base.rows"; fi
    if cmp -s "$T/typed.base.rows" "$T/base.out"; then ok; else fail "$name doctor-ssh-findings and extensions: all other typed findings equal BASE"; fi
    read -r bst bpass bwarn bfail <"$T/base.probes.summary"
    p_oracle "$T/base" render render "$T/typed.base.rows" "$bpass" "$bwarn" "$bfail"
    assert_eq "$?" "$trc" "$name typed counts summarize to BASE's exit status"
    assert_eq "$(p_tags "$T/render.out")" "$(p_tags "$T/base.text")" "$name typed rows render as BASE's doctor lines"
    assert_eq "$(grep ' passed ' "$T/render.out")" "$(grep ' passed ' "$T/base.text")" "$name typed counts render as BASE's summary"
  fi
  assert_eq "$(t_snapshot "$fixture")" "$before" "$name fixture unchanged"
  assert_eq "$(t_snapshot "$T/state")" "$saved" "$name no state, log, plan or profile written"
  assert_empty_file "$T/shims.log" "$name no sudo, installer, package, boot or network command"
  assert_empty_file "$T/record" "$name no action recorded"
  assert_eq "$(ls -A "$T/tmp")" '' "$name no temporary residue"
}

for fixture in "$T/base/tests/fixtures/"*; do
  [ -d "$fixture/cmd" ] || continue
  case "$(cat "$fixture/cmd/uname_s" 2>/dev/null)" in
    Darwin) [ "$mac" = 1 ] || continue ;;
    Linux) ;;
    *) continue ;;
  esac
  p_fixture "${fixture##*/}"
done
# Findings read from saved state: the backup and saved plan rows, read-only.
mkdir -p "$T/state"
chmod 700 "$T/state"
for choices in 'cfg_linux=120 planned_at=2026-09-01T00:00:00Z' 'backup_confirmed_at=2026-09-02T00:00:00Z cfg_linux=96 planned_at=2026-09-01T00:00:00Z'; do
  # shellcheck disable=SC2086 # fixed synthetic key=value test values
  printf '%s\n' $choices >"$T/state/state.env"
  chmod 600 "$T/state/state.env"
  for fx in linux-omarchy-installed mac-m1pro-1tb-roomy mac-asahi-installed; do
    case "$fx" in mac-*) [ "$mac" = 1 ] || continue ;; esac
    fixture=$T/base/tests/fixtures/$fx
    p_fixture "$fx state ($choices)"
  done
  if [ "$mac" = 1 ]; then
    assert_contains "$(cat "$T/typed.rows")" 'col=Saved%20plan' 'saved state reaches the typed rows'
  fi
done
rm -rf "$T/state"

# One request, one capture: mutation of the source after capture, or of the
# staged response after admission, cannot change what is published.
V=$(t_variant linux-alarm-fresh)
F=$(t_variant linux-alarm-offline)
C_FIX=$V C_HOME=$REPO C_PATH='' C_ENV=OMB_SESSION_SCOPES=health
c_run snapshot "scope	name=health"
g0=$(p_gen)
c_run detail "page	scope=health	kind=doctor	generation=$g0	offset=0	limit=500"
total0=$(grep -c $'^row\t' "$C_EV")
hello=$(sed -n 2p "$C_EV")
helper() {
  local op=$1 offset=${2:-0}
  c_prepare "$op"
  printf '%s\n' "$hello" >>"$C_EV"
  cp "$C_EV" "$T/prefix"
  : >"$T/captures"; : >"$T/leaks"
  rm -f "$T/admitted"
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    # shellcheck source=lib/core.sh
    . "$REPO/lib/core.sh"
    # shellcheck source=lib/read.sh
    . "$REPO/lib/read.sh"
    # shellcheck source=lib/health.sh
    . "$REPO/lib/health.sh"
    HOME=$T/home OMB_INTENT=read OMB_PERSIST=0 OMB_FIXTURE=${P_FIX:-$V} OMB_STATE_DIR=$T/state
    platform_init; state_init; omb_tmp_init
    CORE_EVENTS=$C_EV CORE_OP=$op CORE_RECS=1 CORE_RESULT=0 CORE_BYTES=0 CORE_SUPPRESSED=0
    CORE_REQ_KIND=doctor CORE_REQ_GENERATION=${P_GEN:-$g0} CORE_REQ_OFFSET=$offset CORE_REQ_LIMIT=1
    # Counters left in the calling shell neither reach nor survive a capture.
    DOC_PASS=5 DOC_WARN=5 DOC_FAIL=5
    eval "$(declare -f cmd_doctor | sed '1s/cmd_doctor/p_doctor_original/')"
    cmd_doctor() {
      local st
      printf x >>"$T/captures"
      case "${P_FAULT:-}" in
        rows-write) rm -f "$OMB_TMP/health.rows"; mkdir "$OMB_TMP/health.rows" ;;
        fifth-status) doc unknown Injected 'a status the owner never emits' ;;
        inner-subshell) (doc info Injected 'a finding whose position is lost') ;;
      esac
      p_doctor_original
      st=$?
      if [ "${P_MUTATE:-0}" = 1 ]; then
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/nvme0n1p6 1 1 1000000 99%% /\n' >"$V/cmd/df_root"
      fi
      case "${P_FAULT:-}" in
        counts-write) mkdir "$OMB_TMP/health.counts" ;;
        status-zero) return 0 ;;
        status-one) return 1 ;;
        status-other) return 2 ;;
        counter-drift) DOC_PASS=$((DOC_PASS + 1)) ;;
        owner-abort) exit 0 ;;
      esac
      return "$st"
    }
    eval "$(declare -f core_read_admit | sed '1s/core_read_admit/p_admit_original/')"
    core_read_admit() {
      local st
      cmp -s "$C_EV" "$T/prefix" || printf leaked >>"$T/leaks"
      case "${P_FAULT:-}" in admit-execute) return 127 ;; admit-read) rm -f "$2" ;; esac
      p_admit_original "$@"
      st=$?
      if [ "$st" = 0 ]; then
        cp "$OMB_TMP/journey.admitted" "$T/admitted" || return 1
        if [ "${P_STAGE:-0}" = 1 ]; then printf 'unadmitted bytes\n' >"$2"; fi
      fi
      return "$st"
    }
    case "${P_FAULT:-}" in
      platform) OMB_PLATFORM=other ;;
      tally) awk() { case "$*" in *'col=pass'*) return 1 ;; esac; command awk "$@"; } ;;
      stage-write) mkdir "$OMB_TMP/journey.response" ;;
      stage-read) cat() { case "$1" in */journey.prefix) return 1 ;; esac; command cat "$@"; } ;;
      retained-copy) cp() { case "$2" in */journey.admitted) return 2 ;; esac; command cp "$@"; } ;;
      admit-awk) awk() { case "$*" in *'hdr=omb-res 1'*) return 127 ;; esac; command awk "$@"; } ;;
      hash)
        shasum() { case "$*" in */health.identity) return 1 ;; esac; command shasum "$@"; }
        sha256sum() { case "$*" in */health.identity) return 1 ;; esac; command sha256sum "$@"; }
        ;;
      publish-prep) tail() { case "$1:$2" in -n:+3) return 1 ;; esac; command tail "$@"; } ;;
      # HEALTH-H01: the row preflight's first read meets a closed stdin.
      rows-read) read() { if [ "${FUNCNAME[1]:-}" = core_read_rows ]; then exec 0<&-; fi; builtin read "$@"; } ;;
      transport) cat() { case "$1" in */health.suffix) head -n 1 "$1"; return 1 ;; esac; command cat "$@"; } ;;
    esac
    core_health_op "$op"
    st=$?
    printf '%s %s %s\n' "$DOC_PASS" "$DOC_WARN" "$DOC_FAIL" >"$T/caller-counters"
    omb_cleanup
    exit "$st"
  ) >"$T/out" 2>"$T/err"
  C_RC=$? C_OUT=$(cat "$C_EV") C_ERR=$(cat "$T/err")
  cp "$FIX/linux-alarm-fresh/cmd/df_root" "$V/cmd/df_root"
  assert_empty_file "$T/leaks" 'header/hello only during every preflight'
}
for op in snapshot detail; do
  for mutation in none capture stage both; do
    P_MUTATE=0 P_STAGE=0
    case "$mutation" in capture) P_MUTATE=1 ;; stage) P_STAGE=1 ;; both) P_MUTATE=1 P_STAGE=1 ;; esac
    helper "$op"
    assert_eq "$(c_result) $C_RC $(c_admits "$op")" 'done ok 0 ok' "$op/$mutation admitted success"
    assert_eq "$(cat "$T/captures")" x "$op/$mutation one Doctor invocation"
    assert_eq "$(p_gen)" "$g0" "$op/$mutation the retained capture's generation"
    assert_eq "$C_ERR" '' "$op/$mutation clean stderr"
    if cmp -s "$T/admitted" "$C_EV"; then ok; else fail "$op/$mutation published != exact retained admitted response"; fi
    assert_eq "$(cat "$T/caller-counters")" '5 5 5' "$op/$mutation the caller's counters are untouched"
    if [ "$op" = snapshot ]; then
      assert_contains "$C_OUT" 'key=doctor.fail	label=Failures	value=0	state=info' "$op/$mutation counts from the capture"
    else
      assert_eq "$(grep '^row	' "$C_EV")" 'row	kind=doctor	key=1	col=pass	col=aarch64	col=6.16.8-asahi-1-1-ARCH' "$op/$mutation page from the capture"
    fi
  done
  P_MUTATE=0 P_STAGE=0
  helper "$op" "$total0"
  assert_eq "$(c_result) $C_RC $(c_admits "$op")" 'done ok 0 ok' "$op offset total after preflight"
  for fault in rows-write counts-write fifth-status inner-subshell status-one status-other counter-drift owner-abort platform \
    tally rows-read stage-write stage-read retained-copy admit-execute admit-read admit-awk hash publish-prep; do
    P_FAULT=$fault helper "$op"
    assert_eq "$(c_result) $C_RC" 'error io 0' "$op/$fault is io"
    assert_eq "$(c_admits "$op")" ok "$op/$fault safe response admitted"
    assert_eq "$(cut -f1 "$C_EV" | tr '\n' ' ')" 'omb-res 1 hello generation result ' "$op/$fault no candidate facts or rows"
    assert_eq "$(p_gen)" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 "$op/$fault no usable dataset"
    assert_contains "$C_OUT" 'text=The%20health%20response%20could%20not%20be%20prepared.	next=' "$op/$fault fixed safe text"
    assert_eq "$(cat "$T/captures")" x "$op/$fault one Doctor invocation"
  done
  # Unusable current data is io, never changed or invalid: it precedes a
  # stale generation and an offset beyond the otherwise current total.
  for fault in rows-write rows-read owner-abort hash; do
    P_GEN=$(printf '%064d' 0) P_FAULT=$fault helper "$op" 99
    assert_eq "$(c_result) $C_RC $(c_admits "$op") $(p_gen)" 'error io 0 ok e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' "$op/$fault io before stale generation and offset"
  done
  # A completed report with a failure is cmd_doctor status 1: success. The
  # same report claiming status 0 is not the baseline summary: io.
  P_FIX=$F helper "$op"
  assert_eq "$(c_result) $C_RC $(c_admits "$op")" "$([ "$op" = snapshot ] && echo 'done ok 0 ok' || echo 'refused changed 0 ok')" "$op failed report is a successful read"
  P_FIX=$F P_FAULT=status-zero helper "$op"
  assert_eq "$(c_result) $C_RC $(c_admits "$op")" 'error io 0 ok' "$op failed report with status 0 is io"
  P_FAULT=transport helper "$op"
  assert_rc "$C_RC" 1 "$op failed transport stays incomplete"
  assert_eq "$(grep -c '^result	' "$C_EV")" 0 "$op no second safe result after a partial append"
done
# No cross-request cache: the next request captures the changed source.
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/nvme0n1p6 1 1 1000000 99%% /\n' >"$V/cmd/df_root"
C_FIX=$V C_HOME=$REPO C_ENV=OMB_SESSION_SCOPES=health c_run snapshot "scope	name=health"
assert_contains "$C_OUT" 'key=doctor.fail	label=Failures	value=1	state=info' 'a later request captures again'
assert_not_contains "$(p_gen)" "$g0" 'a later request has the changed generation'
cp "$FIX/linux-alarm-fresh/cmd/df_root" "$V/cmd/df_root"

# Generation framing binds order and label, using the real doc() owner over
# synthetic sequences (no fixture can reorder the owner's checks).
order() {
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    # shellcheck source=lib/core.sh
    . "$REPO/lib/core.sh"
    # shellcheck source=lib/read.sh
    . "$REPO/lib/read.sh"
    # shellcheck source=lib/health.sh
    . "$REPO/lib/health.sh"
    OMB_INTENT=read OMB_PERSIST=0 OMB_STATE_DIR=$T/state
    omb_tmp_init
    printf 'omb-res 1\n%s\n' "$hello" >"$OMB_TMP/order.events"
    CORE_EVENTS=$OMB_TMP/order.events
    case "$1" in
      ab) cmd_doctor() { doc pass First one; doc info Second two; doc_summary; } ;;
      ba) cmd_doctor() { doc info Second two; doc pass First one; doc_summary; } ;;
      label) cmd_doctor() { doc pass Renamed one; doc info Second two; doc_summary; } ;;
    esac
    core_health_extensions() { :; }
    # M16-report-reads: isolate the synthetic Doctor's two rows from report
    # observations, which require a real platform and fixture.
    core_health_report() { : >"$OMB_TMP/health.report"; }
    core_rows_snapshot() { for f in facts blockers actions params; do : >"$OMB_TMP/rows.$f"; done; }
    core_health_capture || exit 1
    printf '%s %s\n' "$CORE_HEALTH_ROWS" "$CORE_HEALTH_GEN"
    omb_cleanup
  )
}
ab=$(order ab)
assert_eq "$(order ab)" "$ab" 'the same ordered findings: the same generation'
assert_eq "${ab%% *}" 2 'two findings captured'
assert_not_contains "$(order ba)" "${ab#* }" 'reordered findings change the generation'
assert_not_contains "$(order label)" "${ab#* }" 'a changed label changes the generation'
assert_eq "$(find "$T" -maxdepth 1 -name 'omarchy-bootstrap.*')" '' 'request scratch cleaned'
t_done test-gate2-health-proof
