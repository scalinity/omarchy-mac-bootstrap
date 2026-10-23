#!/usr/bin/env bash
# Machine stages, code provenance and the read-only final report. The simulation
# drives the real entrypoint. Only the qualification interface is a stand-in:
# the parallel qualification unit owns the round trip and its file admission.
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
# qfy_status_read's exact interface, loaded in the current shell. No fake
# qualification records are admitted as proof of the real round trip.
cat >>"$T/tool/lib/read.sh" <<'QFY'
qfy_status_read() {
  QFY_STATE=${J_TEST_QFY:-not-started}
  QFY_WHY=${J_TEST_QWHY:-}
  return "${J_TEST_QRC:-0}"
}
QFY
C_HOME=$T/tool
c_session
C_STATE=$T/mac-state
C_ENV='OMB_SESSION_SCOPES=journey,health'

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
  # All other stages are derived here.

  assert_eq "$(j_stages | awk '($3 == "recorded" && $4 !~ /^(macos|linux)$/) || ($3 == "machine" && NF != 3) { n++ } END { print n+0 }')" 0 "$1: every stage basis and by agree"
  assert_eq "$(awk -F '\t' '$1 == "stage" && $3 !~ /^state=(skipped|blocked)$/ && $7 != "detail=" { n++ } END { print n+0 }' "$C_EV")" 0 "$1: detail only on skips and blockers"
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
j_report() {
  c_run snapshot $'scope\tname=health'
  assert_eq "$(c_result) $(c_admits snapshot)" 'done ok ok' "$1: health snapshot"
  local gen
  gen=$(j_gen)
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
  # The real planner saves the plan and Shared intent; no disk mutation runs.
  choices='\n\n\n\n\n\n\n\n\n\n'
  T_ENV="OMB_STATE_DIR=$C_STATE" t_cli "$C_FIX" "\n4\n\n$choices" plan
  assert_contains "$T_OUT" 'Plan saved' 'J-PLAN: actual text plan'
  j_snapshot J-PLAN 'done skipped skipped done current todo todo skipped todo todo'
  token=$(awk -F '\t' '$1 == "code" { sub(/^value=/,"",$3); print $3 }' "$C_EV")
  _rec_dec_into token "$token"
  assert_contains "$token" 'plan=' 'J-PLAN: real canonical token'
  digest=$(sed -n 's/^cfg_plan=//p' "$C_STATE/state.env")
  printf 'asahi_launched_at=2026-10-22T12:00:00Z\n' >>"$C_STATE/state.env"
  j_snapshot J-LAUNCHED 'done skipped skipped done current todo todo skipped todo todo'
  assert_not_contains "$(j_stages)" 'asahi done' 'J-LAUNCHED: a launch receipt never proves installation'

  # Profile and resolver each own their existing classifier; corrupt state is
  # blocked, an unfinished scan is not a saved selection.
  j_profile unresolved
  j_snapshot J-UNRESOLVED 'done done blocked done current todo todo todo todo todo'
  j_profile resolved
  j_snapshot J-PROFILE 'done done done done current todo todo todo todo todo'
  printf 'corrupt\n' >>"$C_STATE/profile.omb"
  j_snapshot J-BAD-PROFILE 'done blocked blocked done current todo todo todo todo todo'
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
  C_ENV='OMB_SESSION_SCOPES=journey,health HOME=/home/alex'
  J_EXPECT_REC=$(printf 'survey macos\nplan macos')
  j_snapshot J-BOOTED 'done blocked blocked done done current todo todo todo todo'
  assert_eq "$(j_stages | awk '$3 == "recorded"')" "$(printf 'survey done recorded macos\nplan done recorded macos')" 'J-TOKEN: only survey and plan are recorded by macOS'
  linuxstate=$C_STATE
  C_FIX=$(t_variant linux-shared-absent)
  C_STATE=$linuxstate
  j_snapshot J-OMARCHY 'done blocked blocked done done done current todo todo todo'
  # The baseline completion code is checked against macOS's current root.
  donecode=$(code_make ombdone "$digest" 4A7B1C2D-0006-4E5F-8A9B-000000000006)
  sharecode=$(code_make ombshare "$digest" 4A7B1C2D-0007-4E5F-8A9B-000000000007)
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
  j_snapshot J-SHARED 'done blocked blocked done done done done current todo todo'
  cp "$C_FIX/root/mnt/shared/omarchy-mac-bootstrap/bundles/20261022T120000Z/objects/"* "$C_FIX/root/home/alex/.config/journey.conf"
  chmod 0644 "$C_FIX/root/home/alex/.config/journey.conf"
  j_snapshot J-RESTORED 'done blocked blocked done done done done done current todo'
  C_ENV="$C_ENV J_TEST_QFY=passed"
  j_snapshot J-LINUX-QUALIFIED 'done blocked blocked done done done done done done todo' 0
  j_report J-LINUX-REPORT

  C_FIX=$(t_variant journey-mac-created)
  cp "$FIX/mig-mac-home/cmd/hardware_plist" "$C_FIX/cmd/hardware_plist"
  C_STATE=$macstate
  printf 'shared_linux_done=%s\n' "$donecode" >>"$C_STATE/state.env"
  # A read-back bundle, not export_last by itself, establishes export.
  bundle=$FIX/journey-linux-restored/root/mnt/shared/omarchy-mac-bootstrap/bundles/20261022T120000Z
  printf 'export_last=%s\n' "$bundle" >>"$C_STATE/state.env"
  C_ENV='OMB_SESSION_SCOPES=journey,health'
  J_EXPECT_REC='omarchy linux'
  j_snapshot J-MAC-SHARED 'done done done done done done done done current todo'
  assert_eq "$(j_stages | awk '$3 == "recorded"')" 'omarchy done recorded linux' 'J-DONE-CODE: only Linux completion is recorded'
  C_ENV="$C_ENV J_TEST_QFY=passed"
  j_snapshot J-DONE 'done done done done done done done done done done' 0
  before=$(t_snapshot "$C_STATE")
  body=$(j_stages)
  j_snapshot J-RERUN 'done done done done done done done done done done' 0
  assert_eq "$(j_stages)" "$body" 'J-RERUN: stage states and provenance unchanged'
  assert_eq "$(t_snapshot "$C_STATE")" "$before" 'J-RERUN: no writes'
  j_report J-MAC-REPORT
  assert_contains "$C_OUT" $'key=linux\tcol=not-checked' 'J-REPORT: a completion code never claims readable Linux health'
  # J-REPORT-GENERATION: qualification is part of the whole Health dataset,
  # so even a one-row page cannot mix results from two qualification reads.
  reportgen=$(j_gen)
  C_ENV='OMB_SESSION_SCOPES=journey,health J_TEST_QFY=failed J_TEST_QWHY=digest-mismatch J_TEST_QRC=1'
  c_run detail "$(printf 'page\tscope=health\tkind=report\tgeneration=%s\toffset=0\tlimit=1' "$reportgen")"
  assert_eq "$(c_result)" 'refused changed' 'J-REPORT-GENERATION: off-page qualification change invalidates page'
  assert_eq "$(awk -F '\t' '$1 == "row" { n++ } END { print n+0 }' "$C_EV")" 0 'J-REPORT-GENERATION: no mixed row'
  j_report J-REPORT-FAILED
  assert_contains "$C_OUT" $'key=qualification\tcol=fail' 'J-REPORT-FAILED: failed qualification fails its row'
  C_ENV='OMB_SESSION_SCOPES=journey,health J_TEST_QFY=blocked J_TEST_QWHY=identity'
  j_snapshot J-QFY-BLOCKED 'done done done done done done done done blocked todo' 0
  for waiting in waiting-for-linux waiting-for-macos; do
    C_ENV="OMB_SESSION_SCOPES=journey,health J_TEST_QFY=$waiting"
    j_snapshot J-QFY-WAITING 'done done done done done done done done current todo'
  done
  C_HOME=$REPO
  j_snapshot J-QFY-UNAVAILABLE 'done done done done done done done done blocked todo' 0
  assert_contains "$C_OUT" 'not%20checked:%20qualification%20is%20not%20available' 'J-QFY-UNAVAILABLE: exact contract reason'
  C_HOME=$T/tool
  C_ENV='OMB_SESSION_SCOPES=journey,health J_TEST_QFY=unknown'
  j_snapshot J-QFY-UNKNOWN 'done done done done done done done done blocked todo' 0
  C_ENV='OMB_SESSION_SCOPES=journey,health J_TEST_QFY=passed'
  # J-REPORT-VERDICT: not-checked rows are counted but neutral. The existing
  # backup receipt removes Doctor's warning; Recovery/backup remain unverified
  # in the report itself. Qualification is unavailable in the unmodified tree.
  printf 'backup_confirmed_at=2026-10-22T12:00:00Z\n' >>"$C_STATE/state.env"
  T_ENV="OMB_STATE_DIR=$C_STATE" t_cli "$C_FIX" '' report
  assert_contains "$T_OUT" 'Verdict             pass' 'J-REPORT-PASS: not-checked rows are neutral'
  assert_contains "$T_OUT" 'pass=4 warn=0 fail=0 not-checked=4' 'J-REPORT-PASS: all eight row counts'
  # Wrong-plan completion codes cannot fill in the other system's progress.
  sed 's/^shared_linux_done=.*/shared_linux_done=invalid/' "$C_STATE/state.env" >"$T/changed"
  cp "$T/changed" "$C_STATE/state.env"
  J_EXPECT_REC=''
  j_snapshot J-BAD-CODE 'done done done blocked done current blocked done blocked todo'
  assert_eq "$(j_stages | awk '$3 == "recorded"')" '' 'J-BAD-CODE: invalid code establishes nothing'
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

# Reads through the unmodified entrypoint also exercise unavailable qualification
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
