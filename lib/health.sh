# shellcheck shell=bash
# shellcheck disable=SC2317,SC2329 # a callback invoked by the baseline Doctor owner
# Ordinary fixture-only Health. One cmd_doctor invocation owns every finding
# and count; only its presentation sinks are replaced, in a subshell. AI and
# restore observations add rows after that complete baseline capture.

# Both producers are read-only. AI emits doctor-shaped wire rows. Restore
# counts are four whole numbers: verified, kept, failed, pending. Raw text
# from a failed count read is never passed through as a finding.
core_health_extensions() (
  local counts verified kept failed pending extra
  [ "$OMB_PLATFORM" = linux ] || return 0
  core_mod_load agents || return 1
  core_mod_load restore || return 1
  if declare -F agent_health_rows >/dev/null; then agent_health_rows || return 1; fi
  if declare -F rst_status_counts >/dev/null; then
    if counts=$(rst_status_counts); then
      case "$counts" in *$'\n'*) counts='' ;; esac
      IFS=' ' read -r verified kept failed pending extra <<EOF
$counts
EOF
      if [ -z "$extra" ] && _uint "$verified" && _uint "$kept" && _uint "$failed" && _uint "$pending"; then
        local status=info
        if [ "$failed" != 0 ]; then status=warn; fi
        rec_line row kind doctor key 0 col "$status" col Restore \
          col "verified=$verified kept=$kept failed=$failed pending=$pending"
        return
      fi
    fi
    rec_line row kind doctor key 0 col warn col Restore col 'Restore counts could not be read.'
  fi
)

# The one authoritative capture. doc() still decides, counts and logs each
# finding; ui_tag receives exactly the status, label and detail it renders.
# The counters start from zero here, never in the text command's shell.
core_health_doctor() (
  local __n=0 __st
  # Stable ASCII punctuation, independent of terminal presentation preferences.
  OMB_ASCII=1 OMB_COLOR=never
  ui_init
  DOC_PASS=0 DOC_WARN=0 DOC_FAIL=0
  ui_tag() {
    # Doctor's statuses are closed: a fifth is never invented or passed on.
    case "$1" in pass | warn | fail | info) ;; *) exit 1 ;; esac
    __n=$((__n + 1))
    rec_line row kind doctor key "$__n" col "$1" col "$2" col "${3:-}" >>"$OMB_TMP/health.rows" || exit 1
  }
  cmd_doctor >/dev/null
  __st=$?
  printf '%s %s %s %s %s\n' "$__st" "$__n" "$DOC_PASS" "$DOC_WARN" "$DOC_FAIL" >"$OMB_TMP/health.counts"
)

# Report observations share Health's dataset, after the one Doctor capture.
core_health_report() {
  journey_read "$1" >/dev/null || return 1
  journey_report_build || return 1
  journey_report_records >"$OMB_TMP/health.report"
}

# Health producer status: 0 usable, 1 infrastructure failure, 2 established
# representation invalidity. Canonical admission owns every wire/schema rule.
core_health_capture() {
  local st n pass warn fail extra rows tally sum v doc_counts
  omb_tmp_init || return 1
  : >"$OMB_TMP/health.rows" || return 1
  rm -f "$OMB_TMP/health.counts" || return 1
  core_health_doctor || return 1
  IFS=' ' read -r st n pass warn fail extra <"$OMB_TMP/health.counts" || return 1
  [ -z "$extra" ] || return 1
  for v in "$st" "$n" "$pass" "$warn" "$fail"; do
    _uint "$v" || return 1
  done
  # doc_summary's baseline status: 0 when no check failed, 1 otherwise. A
  # failed check is a completed report, so a successful read; any other
  # status means the owner did not complete, and no dataset was established.
  if [ "$fail" = 0 ]; then
    [ "$st" = 0 ] || return 1
  else
    [ "$st" = 1 ] || return 1
  fi
  # Every finding reached this capture, and the published rows agree with the
  # owner's own counters; info rows count toward none of them.
  rows=$(wc -l <"$OMB_TMP/health.rows") || return 1
  _whole "$rows" '^ *[0-9]+$' || return 1
  [ "$((rows + 0))" = "$n" ] || return 1
  awk -F '\t' '{ c[$4]++ } END { printf "%d %d %d\n", c["col=pass"], c["col=warn"], c["col=fail"] }' \
    "$OMB_TMP/health.rows" >"$OMB_TMP/health.tally" || return 1
  IFS= read -r tally <"$OMB_TMP/health.tally" || return 1
  [ "$tally" = "$pass $warn $fail" ] || return 1
  doc_counts="$pass $warn $fail"
  core_health_extensions >"$OMB_TMP/health.extra" || return 1
  cat "$OMB_TMP/health.rows" "$OMB_TMP/health.extra" >"$OMB_TMP/health.all" || return 1
  awk -F '\t' 'NF != 6 || $1 != "row" || $2 != "kind=doctor" || $4 !~ /^col=(pass|warn|fail|info)$/ { exit 1 }' \
    "$OMB_TMP/health.all" || return 2
  # Extension keys need not share a counter with Doctor. The combined
  # dataset owns a single consecutive position and its own complete counts.
  awk 'BEGIN { FS=OFS="\t" } { $3="key=" NR; print }' "$OMB_TMP/health.all" >"$OMB_TMP/health.rows" || return 1
  n=$(wc -l <"$OMB_TMP/health.rows") || return 1
  n=$((n + 0))
  awk -F '\t' '{ c[$4]++ } END { printf "%d %d %d\n", c["col=pass"], c["col=warn"], c["col=fail"] }' \
    "$OMB_TMP/health.rows" >"$OMB_TMP/health.tally" || return 1
  IFS=' ' read -r pass warn fail <"$OMB_TMP/health.tally" || return 1
  CORE_HEALTH_ROWS=$n
  # Whole-dataset admission, every row and fact, precedes hashing and paging.
  core_read_prefix || return 1
  core_read_rows "$OMB_TMP/health.rows" "$(printf '%064d' 0)"
  st=$?
  [ "$st" = 0 ] || return "$st"
  core_rows_snapshot 'agents.mcp' >/dev/null || return 1
  {
    rec_line fact scope health key doctor.pass label Passed value "$pass" state info &&
      rec_line fact scope health key doctor.warn label Warnings value "$warn" state info &&
      rec_line fact scope health key doctor.fail label Failures value "$fail" state info &&
      cat "$OMB_TMP/rows.facts" "$OMB_TMP/rows.blockers" \
        "$OMB_TMP/rows.actions" "$OMB_TMP/rows.params"
  } >"$OMB_TMP/health.snapshot" || return 1
  core_read_stage snapshot "$(printf '%064d' 0)" 0 "$OMB_TMP/health.snapshot"
  st=$?
  [ "$st" = 0 ] || return "$st"
  # Report joins this dataset, including off-page rows. Reuse the one
  # authoritative Doctor capture; do not invoke cmd_doctor a second time.
  core_health_report "$doc_counts" || return 1
  core_read_rows "$OMB_TMP/health.report" "$(printf '%064d' 0)"
  st=$?
  [ "$st" = 0 ] || return "$st"
  # The scope, the three counters and every ordered row: never just a page.
  {
    rec_line scope name health &&
      cat "$OMB_TMP/health.snapshot" &&
      cat "$OMB_TMP/health.rows" "$OMB_TMP/health.report"
  } >"$OMB_TMP/health.identity" || return 1
  if command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 "$OMB_TMP/health.identity") || return 1
  else
    sum=$(sha256sum "$OMB_TMP/health.identity") || return 1
  fi
  CORE_HEALTH_GEN=${sum%% *}
  _whole "$CORE_HEALTH_GEN" '^[0-9a-f]{64}$' || return 1
}

core_health_failure() {
  local code=io text='The health response could not be prepared.' st
  if [ "$1" = 2 ]; then
    code=representation text='The required health response cannot be represented in Protocol 1.'
  fi
  # Preflight the safe response too, if machinery remains usable. If the
  # machinery itself failed, fixed emergency records need no offending data
  # or hash tool. Tests independently canonical-admit every failure response.
  if core_read_prefix && : >"$OMB_TMP/health.failure" &&
    core_read_stage "$CORE_OP" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 0 "$OMB_TMP/health.failure" error "$code" "$text"; then
    core_health_publish
    st=$?
    [ "$st" = 2 ] || return "$st"
  fi
  core_emit generation id e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 total 0 || return 1
  core_result error "$code" "$text"
}

# Publish only the admitted bytes, without another Doctor read or encoding.
core_health_publish() {
  local bytes records
  tail -n +3 "$OMB_TMP/journey.admitted" >"$OMB_TMP/health.suffix" || return 2
  bytes=$(wc -c <"$OMB_TMP/health.suffix") || return 2
  records=$(wc -l <"$OMB_TMP/health.suffix") || return 2
  # A failed append is an incomplete transport; never append a second result.
  cat "$OMB_TMP/health.suffix" >>"$CORE_EVENTS" || return 1
  CORE_BYTES=$((CORE_BYTES + bytes)) CORE_RECS=$((CORE_RECS + records)) CORE_RESULT=1
}

core_health_op() {
  local kind=${CORE_REQ_KIND:-doctor} rows=''
  local op=$1 st status='done' code=ok text='' total=0 body
  if [ "$op" = detail ] && [ "$kind" != doctor ] && [ "$kind" != report ]; then
    core_result refused unavailable 'This health detail kind is not available.'
    return
  fi
  core_health_capture
  st=$?
  if [ "$st" != 0 ]; then core_health_failure "$st"; return; fi
  body=$OMB_TMP/health.snapshot rows=$OMB_TMP/health.rows
  if [ "$op" = detail ]; then
    if [ "$kind" = report ]; then rows=$OMB_TMP/health.report; fi
    total=$(wc -l <"$rows") || { core_health_failure 1; return; }
    total=$((total + 0)) body=$OMB_TMP/health.page
    : >"$body" || { core_health_failure 1; return; }
    if [ "$CORE_REQ_GENERATION" != "$CORE_HEALTH_GEN" ]; then
      status=refused code=changed text='The health dataset changed; open this detail from a fresh snapshot.'
    elif [ "$CORE_REQ_OFFSET" -gt "$total" ]; then
      status=refused code=invalid text="The offset is beyond this projection's total."
    else
      awk -v offset="$CORE_REQ_OFFSET" -v limit="$CORE_REQ_LIMIT" 'NR > offset && NR <= offset + limit' "$rows" >"$body" || { core_health_failure 1; return; }
    fi
  fi
  core_read_stage "$op" "$CORE_HEALTH_GEN" "$total" "$body" "$status" "$code" "$text"
  st=$?
  if [ "$st" != 0 ]; then core_health_failure "$st"; return; fi
  core_health_publish
  st=$?
  if [ "$st" = 2 ]; then core_health_failure 1; else return "$st"; fi
}
