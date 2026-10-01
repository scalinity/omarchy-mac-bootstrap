# shellcheck shell=bash
# shellcheck disable=SC2317,SC2329 # a callback invoked by the baseline Doctor owner
# Ordinary fixture-only Health. One cmd_doctor invocation owns every finding
# and count; only its presentation sinks are replaced, in a subshell. No
# painted Doctor text is parsed, and lib/doctor.sh is unchanged.

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

# Health producer status: 0 usable, 1 infrastructure failure, 2 established
# representation invalidity. Canonical admission owns every wire/schema rule.
core_health_capture() {
  local st n pass warn fail extra rows tally sum v
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
  CORE_HEALTH_ROWS=$n
  # Whole-dataset admission, every row and fact, precedes hashing and paging.
  core_read_prefix || return 1
  core_read_rows "$OMB_TMP/health.rows" "$(printf '%064d' 0)"
  st=$?
  [ "$st" = 0 ] || return "$st"
  {
    rec_line fact scope health key doctor.pass label Passed value "$pass" state info &&
      rec_line fact scope health key doctor.warn label Warnings value "$warn" state info &&
      rec_line fact scope health key doctor.fail label Failures value "$fail" state info
  } >"$OMB_TMP/health.snapshot" || return 1
  core_read_stage snapshot "$(printf '%064d' 0)" 0 "$OMB_TMP/health.snapshot"
  st=$?
  [ "$st" = 0 ] || return "$st"
  # The scope, the three counters and every ordered row: never just a page.
  {
    rec_line scope name health &&
      cat "$OMB_TMP/health.snapshot" &&
      cat "$OMB_TMP/health.rows"
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
  local op=$1 st status='done' code=ok text='' total=0 body
  if [ "$op" = detail ] && [ "$CORE_REQ_KIND" != doctor ]; then
    core_result refused unavailable 'This health detail kind is not available.'
    return
  fi
  core_health_capture
  st=$?
  if [ "$st" != 0 ]; then core_health_failure "$st"; return; fi
  body=$OMB_TMP/health.snapshot
  if [ "$op" = detail ]; then
    total=$CORE_HEALTH_ROWS body=$OMB_TMP/health.page
    : >"$body" || { core_health_failure 1; return; }
    if [ "$CORE_REQ_GENERATION" != "$CORE_HEALTH_GEN" ]; then
      status=refused code=changed text='The health dataset changed; open this detail from a fresh snapshot.'
    elif [ "$CORE_REQ_OFFSET" -gt "$total" ]; then
      status=refused code=invalid text="The offset is beyond this projection's total."
    else
      awk -v offset="$CORE_REQ_OFFSET" -v limit="$CORE_REQ_LIMIT" 'NR > offset && NR <= offset + limit' "$OMB_TMP/health.rows" >"$body" || { core_health_failure 1; return; }
    fi
  fi
  core_read_stage "$op" "$CORE_HEALTH_GEN" "$total" "$body" "$status" "$code" "$text"
  st=$?
  if [ "$st" != 0 ]; then core_health_failure "$st"; return; fi
  core_health_publish
  st=$?
  if [ "$st" = 2 ]; then core_health_failure 1; else return "$st"; fi
}
