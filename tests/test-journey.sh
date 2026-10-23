#!/usr/bin/env bash
# Machine stages and the final report across macOS -> Linux -> macOS, using
# real qualification records and tiny fixture-only streams.
# shellcheck disable=SC2030,SC2031,SC2317,SC2329
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
t_load
# shellcheck source=lib/records.sh
. "$REPO/lib/records.sh"
echo test-journey
T=$(t_tmp)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tool"
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$REPO/release" "$T/tool/"
# Model the kernel mounting exFAT on first directory access. The real
# shared_lx_access then re-reads mountinfo before opening qualification files.
cat >>"$T/tool/lib/common.sh" <<'ACCESS'
sha256sum() { shasum -a 256; }
ls() {
  case "$*" in
    "-A $OMB_FIXTURE/root/mnt/shared")
      if [ -f "$OMB_FIXTURE/cmd/mountinfo_after_access" ]; then
        cp "$OMB_FIXTURE/cmd/mountinfo_after_access" "$OMB_FIXTURE/root/proc/self/mountinfo"
        printf 'access\n' >>"$OMB_FIXTURE/accesses"
      fi ;;
  esac
  command ls "$@"
}
ACCESS
C_HOME=$T/tool
c_session
C_STATE=$T/mac-state
C_ENV='OMB_SESSION_SCOPES=journey,health,qualify OMB_TEST_QUAL_BYTES=4097'

j_stages() {
  awk -F '\t' '$1 == "stage" { sub(/^name=/,"",$2); sub(/^state=/,"",$3); sub(/^basis=/,"",$4); sub(/^by=/,"",$5); print $2 " " $3 " " $4 " " $5 }' "$C_EV"
}
j_states() { j_stages | awk '{ printf "%s%s", sep, $2; sep=" " }'; }
j_snapshot() {
  c_run snapshot $'scope\tname=journey'
  assert_eq "$(c_result) $C_RC $(c_admits snapshot)" 'done ok 0 ok' "$1: real entrypoint snapshot"
  assert_eq "$C_ERR" '' "$1: stderr"
  assert_eq "$(j_stages | awk '{ printf "%s%s", sep, $1; sep=" " }')" 'survey profile resolve plan asahi omarchy shared restore verify done' "$1: exactly ten, rail order"
  assert_eq "$(j_states)" "$2" "$1: every stage state"
  assert_eq "$(j_stages | awk '$2 == "current" { n++ } END { print n+0 }')" "${3:-1}" "$1: current count"
  assert_eq "$(j_stages | awk '$3 == "recorded" { print $1 " " $4 }')" "${J_EXPECT_REC:-}" "$1: every recorded stage and its system"
  assert_eq "$(j_stages | awk -v os="$(cat "$C_FIX/cmd/uname_s" 2>/dev/null)" '
    { due=(os=="Darwin" ? NR!=6 : NR>=6 && NR<=9)
      if ($2=="current" && unfinished) bad=1
      if (due && $2!="done" && $2!="skipped") unfinished=1 }
    END {print bad+0}')" 0 "$1: no current stage bypasses unfinished local work"
  # All other stages are derived here.

  assert_eq "$(j_stages | awk '($3 == "recorded" && $4 !~ /^(macos|linux)$/) || ($3 == "machine" && NF != 3) { n++ } END { print n+0 }')" 0 "$1: every stage basis and by agree"
  assert_eq "$(awk -F '\t' '$1 == "stage" && $3 !~ /^state=(skipped|blocked)$/ && $7 != "detail=" && $7 != "detail=chosen%20on%20macOS" { n++ } END { print n+0 }' "$C_EV")" 0 "$1: detail only on skips, blockers and remote choices"
}
j_gen() { awk -F '\t' '$1 == "generation" { sub(/^id=/,"",$2); print $2 }' "$C_EV"; }
j_profile() {
  local host
  host=$(sha256_str 'omarchy-mac-bootstrap host 1
5A1E0000-0000-4000-8000-0000000000A1')
  # Existing ordinary mac fixtures have no platform_UUID; the simulation adds
  # the same synthetic identity the profile fixtures use.
  {
    printf 'omb-profile 1\n'
    rec_line mac host "${host:0:16}" model MacBookPro18,2 os 27.2 user alex home /Users/alex shell /bin/zsh at 2026-10-22T00:00:00Z
    rec_line item id config:journey adapter shell kind file category terminal name journey version '' source '' requested yes evidence observed class config path /Users/alex/.config/journey.conf size 22 note ''
    rec_line select id config:journey state include
    rec_line resolution id config:journey layer files method place target .config/journey.conf version '' guess 0 state "$1" note ''
  } >"$C_STATE/profile.omb"
  rec_seal_write "$C_STATE/profile.omb"
  chmod 600 "$C_STATE/profile.omb"
}
# Exercise qualify's actual pipeline and sealed records. Only run's boundary
# is replaced: it can write this fixture and scratch, and never calls sync.
j_qualify() {
  (
    OMB_HOME=$T/tool OMB_FIXTURE=$C_FIX OMB_STATE_DIR=$C_STATE
    OMB_INTENT=act OMB_PERSIST=1 OMB_DRY_RUN=0 OMB_TEST_QUAL_BYTES=4097
    unset OMB_TEST_RECORD
    # shellcheck source=lib/qualify.sh
    . "$REPO/lib/qualify.sh"
    # shellcheck source=/dev/null
    . "$T/tool/lib/common.sh"
    sha256sum() { shasum -a 256; }
    run() {
      local cmd=$1 arg
      shift
      if [ "$OMB_INTENT:$OMB_DRY_RUN" != act:0 ] || [ -z "$OMB_FIXTURE" ]; then return 97; fi
      for arg in "$@"; do
        case "$arg" in /*) case "$arg" in "$C_FIX/root/"* | "$OMB_TMP/"*) ;; *) return 98 ;; esac ;; esac
      done
      case "$cmd" in
        sync) return 0 ;;
        qfy_stream | qfy_copy_exclusive) "$cmd" "$@" ;;
        mkdir | rm | mv | rmdir) command "$cmd" "$@" ;;
        *) return 99 ;;
      esac
    }
    platform_init; state_init
    qfy_run <<<test
    rc=$?
    omb_cleanup
    exit "$rc"
  ) >"$T/qualify.out" 2>&1
  assert_rc "$?" 0 "$1: real qualification step ($(cat "$T/qualify.out"))"
}
j_qualification_fixture() {
  cp "$FIX/qualify-macos/cmd/qualify_space" "$C_FIX/cmd/qualify_space"
  cp "$FIX/qualify-linux/cmd/qualify_journal" "$C_FIX/cmd/qualify_journal"
  cp "$FIX/qualify-linux/cmd/qualify_kernel" "$C_FIX/cmd/qualify_kernel"
  printf '%s\n' shasum sha256sum >>"$C_FIX/commands"
  mkdir -p "$C_FIX/root/Volumes/Shared" "$C_FIX/root/home/alex/.config"
}
j_result() {
  c_run snapshot $'scope\tname=qualify'
  assert_contains "$C_OUT" "value=$1" "$2: real qualification state"
}
j_report() {
  c_run snapshot $'scope\tname=health'
  assert_eq "$(c_result) $(c_admits snapshot)" 'done ok ok' "$1: health snapshot"
  local gen
  gen=$(j_gen)
  if [ "${2:-}" = automount ]; then
    c_run detail "$(printf 'page\tscope=health\tkind=report\tgeneration=%s\toffset=0\tlimit=500' "$gen")"
    assert_eq "$(c_result)" 'refused changed' "$1: mounting changes Doctor observations, invalidating the first generation"
    assert_eq "$(awk -F '\t' '$1=="row" {n++} END {print n+0}' "$C_EV")" 0 "$1: no mixed report rows"
    c_run snapshot $'scope\tname=health'
    assert_eq "$(c_result) $(c_admits snapshot)" 'done ok ok' "$1: explicit snapshot after mount"
    gen=$(j_gen)
  fi
  c_run detail "$(printf 'page\tscope=health\tkind=report\tgeneration=%s\toffset=0\tlimit=500' "$gen")"
  assert_eq "$(c_result) $(c_admits detail)" 'done ok ok' "$1: report projection"
  assert_eq "$(awk -F '\t' '$1 == "row" { sub(/^key=/,"",$3); printf "%s%s",sep,$3; sep=" " }' "$C_EV")" 'mac disk shared linux qualification restore doctor recovery' "$1: all eight report rows in order"
  assert_contains "$C_OUT" $'key=recovery\tcol=not-checked' "$1: Recovery and backup are never claimed"
}

if t_plutil 'journey across macOS and Linux'; then
  C_FIX=$(t_variant mac-m1pro-1tb-roomy)
  # Hardware identity is an existing read-only probe, already in the allowlist.
  cp "$FIX/mig-mac-home/cmd/hardware_plist" "$C_FIX/cmd/hardware_plist"
  j_snapshot J-FRESH 'done skipped skipped current todo todo skipped skipped done todo'
  assert_eq "$(j_stages | awk '$3 == "recorded"')" '' 'J-FRESH: no code, no recorded progress'
  mkdir -p "$C_STATE"; chmod 700 "$C_STATE"
  j_profile unresolved
  j_snapshot J-PROFILE-BEFORE-PLAN 'done done blocked todo todo todo skipped todo done todo' 0
  rm -f "$C_STATE/profile.omb"
  # The real planner saves the plan and Shared intent; no disk mutation runs.
  choices='\n\n\n\n\n\n\n\n\n\n'
  T_ENV="OMB_STATE_DIR=$C_STATE" t_cli "$C_FIX" "\n4\n\n$choices" plan
  assert_contains "$T_OUT" 'Plan saved' 'J-PLAN: actual text plan'
  j_snapshot J-PLAN 'done skipped skipped done current todo todo skipped blocked todo'
  token=$(awk -F '\t' '$1 == "code" { sub(/^value=/,"",$3); print $3 }' "$C_EV")
  _rec_dec_into token "$token"
  assert_contains "$token" 'plan=' 'J-PLAN: real canonical token'
  digest=$(sed -n 's/^cfg_plan=//p' "$C_STATE/state.env")
  printf 'asahi_launched_at=2026-10-22T12:00:00Z\n' >>"$C_STATE/state.env"
  j_snapshot J-LAUNCHED 'done skipped skipped done current todo todo skipped blocked todo'
  assert_not_contains "$(j_stages)" 'asahi done' 'J-LAUNCHED: a launch receipt never proves installation'

  # Profile and resolver each own their existing classifier; corrupt state is
  # blocked, an unfinished scan is not a saved selection.
  j_profile unresolved
  j_snapshot J-UNRESOLVED 'done done blocked done todo todo todo todo blocked todo' 0
  j_profile resolved
  j_snapshot J-PROFILE 'done done done done current todo todo todo blocked todo'
  printf 'corrupt\n' >>"$C_STATE/profile.omb"
  j_snapshot J-BAD-PROFILE 'done blocked blocked done todo todo todo todo blocked todo' 0
  j_profile resolved

  # Linux boots, receives the real token through baseline token_decode/cfg_save,
  # then finishes Omarchy. No invented token fields carry migration progress.
  macstate=$C_STATE
  C_FIX=$(t_variant linux-alarm-fresh)
  C_STATE=$C_FIX/root/home/alex/.local/state/omarchy-bootstrap
  mkdir -p "$C_STATE"; chmod 700 "$C_STATE"
  (
    OMB_STATE_DIR=$C_STATE OMB_INTENT=act OMB_PERSIST=1 OMB_DRY_RUN=0
    state_init
    token_decode "$token" && cfg_save && state_stamp phase1_choices_loaded_at
  )
  C_ENV='OMB_SESSION_SCOPES=journey,health,qualify HOME=/home/alex OMB_TEST_QUAL_BYTES=4097'
  J_EXPECT_REC=$(printf 'survey macos\nplan macos')
  j_snapshot J-BOOTED 'done todo todo done done current todo todo blocked todo'
  assert_eq "$(j_stages | awk '$3 == "recorded"')" "$(printf 'survey done recorded macos\nplan done recorded macos')" 'J-TOKEN: survey and plan are recorded before any checked bundle'
  linuxstate=$C_STATE
  C_FIX=$(t_variant linux-shared-absent)
  C_STATE=$linuxstate
  j_snapshot J-OMARCHY 'done todo todo done done done current todo blocked todo'
  # The baseline completion code is checked against macOS's current root.
  donecode=$(code_make ombdone "$digest" 4A7B1C2D-0006-4E5F-8A9B-000000000006)
  sharecode=$(code_make ombshare "$digest" 4A7B1C2D-0007-4E5F-8A9B-000000000007)
  # Return to macOS to create Shared, check the exported bundle, and write
  # step 1. This is the actual qualification implementation, not a state stub.
  C_FIX=$(t_variant journey-mac-created)
  j_qualification_fixture
  cp "$FIX/mig-mac-home/cmd/hardware_plist" "$C_FIX/cmd/hardware_plist"
  C_STATE=$macstate
  printf 'shared_linux_done=%s\n' "$donecode" >>"$C_STATE/state.env"
  bundle=$FIX/journey-linux-restored/root/mnt/shared/omarchy-mac-bootstrap/bundles/20261022T120000Z
  printf 'export_last=%s\n' "$bundle" >>"$C_STATE/state.env"
  C_ENV='OMB_SESSION_SCOPES=journey,health,qualify OMB_TEST_QUAL_BYTES=4097'
  J_EXPECT_REC='omarchy linux'
  j_snapshot J-MAC-CREATED 'done done done done done done done done current todo'
  j_qualify J-MAC-WRITES
  j_result waiting-for-linux J-MAC-WRITES
  j_snapshot J-MAC-WAITING 'done done done done done done done done todo todo' 0
  macfixture=$C_FIX
  macqualify=$C_FIX/root/Volumes/Shared/omarchy-mac-bootstrap/qualify

  C_FIX=$(t_variant journey-linux-pending)
  C_STATE=$C_FIX/root/home/alex/.local/state/omarchy-bootstrap
  mkdir -p "$C_STATE"; chmod 700 "$C_STATE"; cp "$linuxstate/state.env" "$C_STATE/"
  (
    token_decode "$token"
    OMB_STATE_DIR=$C_STATE OMB_INTENT=act OMB_PERSIST=1 OMB_DRY_RUN=0
    state_init
    OMB_FIXTURE=$C_FIX; platform_init; lx_detect
    shared_take_share_code "$sharecode" >/dev/null
  )
  j_qualification_fixture
  mkdir -p "$C_FIX/root/mnt/shared/omarchy-mac-bootstrap/qualify"
  cp -R "$macqualify/." "$C_FIX/root/mnt/shared/omarchy-mac-bootstrap/qualify/"
  C_ENV='OMB_SESSION_SCOPES=journey,health,qualify HOME=/home/alex OMB_TEST_QUAL_BYTES=4097'
  J_EXPECT_REC=$(printf 'survey macos\nprofile macos\nresolve macos\nplan macos')
  # Start from linux-shared-ready's armed mount and model the kernel response
  # to directory access. Both the shared stage and qualification must recheck.
  cp "$C_FIX/root/proc/self/mountinfo" "$C_FIX/cmd/mountinfo_after_access"
  cp "$FIX/linux-shared-ready/root/proc/self/mountinfo" "$C_FIX/root/proc/self/mountinfo"
  j_snapshot J-SHARED 'done done done done done done done current todo todo'
  assert_eq "$(cat "$C_FIX/accesses")" access 'J-ARMED: configured automount accessed once'
  cp "$FIX/linux-shared-ready/root/proc/self/mountinfo" "$C_FIX/root/proc/self/mountinfo"
  j_result waiting-for-linux J-ARMED-QUALIFY
  cp "$FIX/linux-shared-ready/root/proc/self/mountinfo" "$C_FIX/root/proc/self/mountinfo"
  REPO=$T/tool T_ENV="OMB_STATE_DIR=$C_STATE HOME=/home/alex OMB_TEST_QUAL_BYTES=4097" t_cli "$C_FIX" '' qualify status
  assert_rc "$T_RC" 0 'J-ARMED-STATUS: real qualify status sees waiting qualification'
  assert_contains "$T_OUT" waiting-for-linux 'J-ARMED-STATUS: actual state'
  cp "$FIX/linux-shared-ready/root/proc/self/mountinfo" "$C_FIX/root/proc/self/mountinfo"
  REPO=$T/tool T_ENV="OMB_STATE_DIR=$C_STATE HOME=/home/alex OMB_TEST_QUAL_BYTES=4097" t_cli "$C_FIX" 'test\n' qualify
  assert_rc "$T_RC" 0 'J-ARMED-RUN: due step reaches the fixture recording boundary'
  assert_contains "$T_OUT" 'no stream or Shared write ran' 'J-ARMED-RUN: test records no real act command'

  cp "$FIX/linux-shared-ready/root/proc/self/mountinfo" "$C_FIX/root/proc/self/mountinfo"
  j_report J-ARMED-REPORT automount
  assert_contains "$C_OUT" $'key=shared\tcol=pass' 'J-ARMED-REPORT: armed Shared is not a failure'
  assert_contains "$C_OUT" $'key=qualification\tcol=warn' 'J-ARMED-REPORT: real qualification is waiting, not blocked'
  cp "$FIX/linux-shared-ready/root/proc/self/mountinfo" "$C_FIX/root/proc/self/mountinfo"
  REPO=$T/tool T_ENV="OMB_STATE_DIR=$C_STATE HOME=/home/alex OMB_TEST_QUAL_BYTES=4097" t_cli "$C_FIX" '' report
  assert_rc "$T_RC" 0 'J-ARMED-TEXT-REPORT: completed read'
  assert_not_contains "$T_OUT" 'Shared mount is not verified' 'J-ARMED-TEXT-REPORT: armed alone never fails qualification'


  cp "$C_FIX/root/mnt/shared/omarchy-mac-bootstrap/bundles/20261022T120000Z/objects/"* "$C_FIX/root/home/alex/.config/journey.conf"
  chmod 0644 "$C_FIX/root/home/alex/.config/journey.conf"
  j_snapshot J-RESTORED 'done done done done done done done done current todo'
  j_qualify J-LINUX-WRITES
  j_result waiting-for-macos J-LINUX-WRITES
  j_snapshot J-LINUX-QUALIFIED 'done done done done done done done done todo todo' 0
  j_report J-LINUX-REPORT
  linuxqualify=$C_FIX/root/mnt/shared/omarchy-mac-bootstrap/qualify
  linuxfixture=$C_FIX linuxreststate=$C_STATE

  C_FIX=$macfixture C_STATE=$macstate
  cp -R "$linuxqualify/." "$macqualify/"
  C_ENV='OMB_SESSION_SCOPES=journey,health,qualify OMB_TEST_QUAL_BYTES=4097'
  J_EXPECT_REC='omarchy linux'
  j_snapshot J-MAC-SHARED 'done done done done done done done done current todo'
  assert_eq "$(j_stages | awk '$3 == "recorded"')" 'omarchy done recorded linux' 'J-DONE-CODE: only Linux completion is recorded'
  j_qualify J-MAC-CHECKS
  j_result passed J-MAC-CHECKS
  j_snapshot J-DONE 'done done done done done done done done done done' 0
  before=$(t_snapshot "$C_STATE")
  body=$(j_stages)
  j_snapshot J-RERUN 'done done done done done done done done done done' 0
  assert_eq "$(j_stages)" "$body" 'J-RERUN: stage states and provenance unchanged'
  assert_eq "$(t_snapshot "$C_STATE")" "$before" 'J-RERUN: no writes'
  j_report J-MAC-REPORT
  assert_contains "$C_OUT" $'key=linux\tcol=not-checked' 'J-REPORT: a completion code never claims readable Linux health'
  # A passing result read on Linux still cannot end the journey there.
  cp "$macqualify/result.omb" "$linuxqualify/"
  C_FIX=$linuxfixture C_STATE=$linuxreststate
  C_ENV='OMB_SESSION_SCOPES=journey,health,qualify HOME=/home/alex OMB_TEST_QUAL_BYTES=4097'
  J_EXPECT_REC=$(printf 'survey macos\nprofile macos\nresolve macos\nplan macos')
  j_snapshot J-LINUX-PASSED 'done done done done done done done done done todo' 0
  C_FIX=$macfixture C_STATE=$macstate
  C_ENV='OMB_SESSION_SCOPES=journey,health,qualify OMB_TEST_QUAL_BYTES=4097'
  J_EXPECT_REC='omarchy linux'
  j_report J-MAC-REPORT-AFTER-LINUX
  # J-REPORT-GENERATION: qualification is part of the whole Health dataset,
  # so even a one-row page cannot mix results from two qualification reads.
  reportgen=$(j_gen)
  cp "$macqualify/result.omb" "$T/passed.omb"
  sed '$d' "$macqualify/result.omb" | sed 's/names_ok=1/names_ok=0/; s/verdict=passed/verdict=failed/; s/reason=$/reason=digest-mismatch/' >"$T/result.body"
  cp "$T/result.body" "$macqualify/result.omb"
  rec_seal_write "$macqualify/result.omb"
  c_run detail "$(printf 'page\tscope=health\tkind=report\tgeneration=%s\toffset=0\tlimit=1' "$reportgen")"
  assert_eq "$(c_result)" 'refused changed' 'J-REPORT-GENERATION: off-page qualification change invalidates page'
  assert_eq "$(awk -F '\t' '$1 == "row" { n++ } END { print n+0 }' "$C_EV")" 0 'J-REPORT-GENERATION: no mixed row'
  j_report J-REPORT-FAILED
  assert_contains "$C_OUT" $'key=qualification\tcol=fail' 'J-REPORT-FAILED: failed qualification fails its row'
  printf 'corrupt\n' >>"$macqualify/result.omb"
  j_snapshot J-QFY-BLOCKED 'done done done done done done done done blocked todo' 0
  cp "$T/passed.omb" "$macqualify/result.omb"
  # J-REPORT-VERDICT: not-checked rows are counted but neutral. The existing
  # backup receipt removes Doctor's warning; Recovery/backup remain unverified
  # in the report itself. The passing result comes from the real round trip.
  printf 'backup_confirmed_at=2026-10-22T12:00:00Z\n' >>"$C_STATE/state.env"
  T_ENV="OMB_STATE_DIR=$C_STATE OMB_TEST_QUAL_BYTES=4097" t_cli "$C_FIX" '' report
  assert_contains "$T_OUT" 'Verdict             pass' 'J-REPORT-PASS: not-checked rows are neutral'
  assert_contains "$T_OUT" 'pass=5 warn=0 fail=0 not-checked=3' 'J-REPORT-PASS: all eight row counts'
  # Wrong-plan completion codes cannot fill in the other system's progress.
  sed 's/^shared_linux_done=.*/shared_linux_done=invalid/' "$C_STATE/state.env" >"$T/changed"
  cp "$T/changed" "$C_STATE/state.env"
  J_EXPECT_REC=''
  j_snapshot J-BAD-CODE 'done done done done done todo blocked done blocked todo' 0
  assert_eq "$(j_stages | awk '$3 == "recorded"')" '' 'J-BAD-CODE: invalid code establishes nothing'
  # The saved-plan completion rule also holds without Shared after Asahi.
  C_FIX=$(t_variant mac-asahi-complete)
  C_STATE=$T/no-shared-state
  mkdir -p "$C_STATE"; chmod 700 "$C_STATE"
  printf 'cfg_linux=250\ncfg_shared=0\n' >"$C_STATE/state.env"
  chmod 600 "$C_STATE/state.env"
  C_ENV='OMB_SESSION_SCOPES=journey,health,qualify OMB_TEST_QUAL_BYTES=4097'
  J_EXPECT_REC=''
  j_snapshot J-INSTALLED-NO-SHARED 'done skipped skipped done done todo skipped skipped done todo' 0
  j_report J-NO-SHARED-REPORT
  assert_contains "$C_OUT" $'key=disk\tcol=not-checked' 'J-NO-SHARED: plan completion does not invent saved disk extents'
fi

# J-STARTUP: the actual production check route keeps its identity-only
# boundary, fixed generation, no token/actions and read-only persistence.
c_session
c_uname_arm "$T/native"
C_PATH=$T/native:/usr/bin:/bin:/usr/sbin:/sbin
C_STATE=$T/check-state
C_ENV='OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_SESSION_INTENT=read OMB_SESSION_SCOPES=journey OMB_SESSION_PURPOSE=frontend-check'
c_run snapshot $'scope\tname=journey'
assert_eq "$(c_result) $C_RC $(c_admits snapshot)" 'done ok 0 ok' 'J-STARTUP: production route admits'
assert_eq "$(j_states)" 'blocked blocked blocked blocked blocked blocked blocked blocked blocked blocked' 'J-STARTUP: ten unavailable stages'
assert_eq "$(j_stages | awk '$3 != "machine" || NF != 3 { n++ } END { print n+0 }')" 0 'J-STARTUP: all bases machine, no by'
assert_eq "$(awk -F '\t' '$1 ~ /^(action|param|code|row)$/ { n++ } END { print n+0 }' "$C_EV")" 0 'J-STARTUP: no added authority or data'
startup=$(sed '1,2d' "$C_EV")
c_run snapshot $'scope\tname=journey'
assert_eq "$(sed '1,2d' "$C_EV")" "$startup" 'J-STARTUP: same body and generation on refresh'
assert_eq "$(t_snapshot "$C_STATE")" '(absent)' 'J-STARTUP: no operation/state/log write'
C_PATH='' C_ENV=''

# Reads through the unmodified entrypoint exercise qualification loading
# and both explicit skips, with no persistent output, even at the act ceiling.
if t_plutil 'status skip lines'; then
  t_cli mac-m1pro-1tb-roomy '' status
  assert_contains "$T_OUT" 'profile: skipped: no migration' 'J-SKIP-MIGRATION'
  assert_contains "$T_OUT" 'shared: skipped: Shared is not planned' 'J-SKIP-SHARED'
fi
for fixture in linux-alarm-fresh linux-alarm-offline; do
  t_cli "$fixture" '' report
  assert_rc "$T_RC" 0 'J-REPORT: read completes even with failing checks'
  assert_contains "$T_OUT" 'not-checked=' 'J-REPORT: four counts'
  if [ "$fixture" = linux-alarm-offline ]; then
    assert_contains "$T_OUT" 'Verdict             fail' 'J-REPORT-FAIL: failures dominate warnings'
  else
    assert_contains "$T_OUT" 'Verdict             warn' 'J-REPORT-WARN: warnings dominate pass'
  fi
  assert_eq "$(t_snapshot "$T_DIR/state")" '(absent)' 'J-REPORT: writes no state/log'
  assert_empty_file "$T_DIR/record" 'J-REPORT: no command execution'
  assert_empty_file "$T_DIR/shims.log" 'J-REPORT: no mutating tools'
done
# Verdict precedence and counts are pure reductions of the same report rows.
(
  # shellcheck source=lib/journey.sh
  . "$REPO/lib/journey.sh"
  journey_init
  J_REPORT_KEY=() J_REPORT_STATE=() J_REPORT_LABEL=() J_REPORT_WHY=()
  J_PASS=0 J_WARN=0 J_FAIL=0 J_NOT_CHECKED=0
  journey_report_row recovery not-checked Recovery unavailable
  journey_report_row doctor fail doctor failed
  printf '%s %s %s %s\n' "$J_PASS" "$J_WARN" "$J_FAIL" "$J_NOT_CHECKED"
) >"$T/counts"
assert_eq "$(cat "$T/counts")" '0 0 1 1' 'J-COUNTS: each row counts exactly once'
t_done test-journey
