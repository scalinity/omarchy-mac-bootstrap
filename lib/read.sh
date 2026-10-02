# shellcheck shell=bash
# shellcheck disable=SC2317,SC2329 # callbacks invoked by the baseline status owners
# The ordinary journey dataset. Status owns the reads and presentation values;
# only this isolated subshell replaces its sinks. No bootstrap text is parsed.
# Both snapshot and detail consume this exact canonical dataset.

core_journey_dataset() (
  local section='' facts='' rows='' machine='' guide='' token='' blockers='' messages=''
  local n=0 b=0 line key state value raw
  # Stable ASCII punctuation, independent of terminal presentation preferences.
  OMB_ASCII=1 OMB_COLOR=never
  ui_init
  ui_header() { :; }
  mac_rail() { :; }
  lx_rail() { :; }
  ui_section() {
    section=$1
    case "$section" in Next | 'Resume token') return 0 ;; esac
    # Preserve section annotations (including which recorded file is shown).
    n=$((n + 1))
    rec_line_v row kind status key "$n" col "$section" col '' col '' col "${2:-}"
    rows="$rows$REC_LINE
"
  }
  ui_kv() {
    n=$((n + 1))
    key=status.$n
    [ "$section" != Recorded ] || key=recorded.$n
    rec_line_v row kind status key "$n" col "$section" col "$1" col "$2" col "${3:-}"
    rows="$rows$REC_LINE
"
    if [ -z "$1" ]; then
      if [ -n "$2" ]; then
        rec_line_v message level info text "$2"
        messages="$messages$REC_LINE
"
      fi
      return 0
    fi
    state=info
    case "$2" in '' | unknown | '?') state=unknown ;; esac
    rec_line_v fact scope journey key "$key" label "$1" value "${2:-unknown}" state "$state"
    facts="$facts$REC_LINE
"
  }
  ui_para() {
    if [ "$section" = Next ]; then
      rec_line_v guide id next step 1 text "$*"
      guide=$REC_LINE
    else
      ui_kv '' "$*"
    fi
  }
  ui_note() { ui_kv '' "$*"; }
  ui_cmd() { ui_kv '' "$*"; }
  status_token() {
    value=$(token_encode)
    rec_line_v code kind token value "$value"
    token=$REC_LINE
  }
  lx_upstream_status_lines() {
    # Opaque upstream lines, not the bootstrap's human-formatted status.
    while IFS= read -r line || [ -n "$line" ]; do
      ui_kv '' "$line"
    done < <(lx_upstream_status_text)
  }
  cmd_status >/dev/null || return 1
  # Identity observations already produced by status's detector; no new probe.
  core_machine_fact() {
    state=info
    case "$3" in '' | unknown | '?') state=unknown ;; esac
    rec_line_v fact scope journey key "machine.$1" label "$2" value "${3:-unknown}" state "$state"
    machine="$machine$REC_LINE
"
    rec_line_v row kind machine key "machine.$1" col "$2" col "${3:-unknown}"
    rows="$rows$REC_LINE
"
  }
  core_machine_fact platform Platform "$OMB_PLATFORM"
  case "$OMB_PLATFORM" in
    macos)
      core_machine_fact arch Architecture "$MAC_ARCH"
      core_machine_fact model Model "$MAC_MODEL_ID"
      core_machine_fact chip Chip "$MAC_CHIP"
      core_machine_fact memory Memory "$MAC_MEM_BYTES"
      core_machine_fact os macOS "$MAC_OS_VERSION"
      raw=$(mac_blockers)
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        b=$((b + 1))
        rec_line_v blocker id "mac.$b" text "$line" fix ''
        blockers="$blockers$REC_LINE
"
      done <<END_BLOCKERS
$raw
END_BLOCKERS
      ;;
    linux)
      core_machine_fact arch Architecture "$LX_ARCH"
      core_machine_fact model Model "$LX_DT_MODEL"
      core_machine_fact chip Chip "$DEV_CHIP"
      core_machine_fact os System "$LX_OS_NAME"
      core_machine_fact kernel Kernel "$LX_KERNEL"
      ;;
    *) return 1 ;;
  esac
  # Every value used by either projection, including notes and the token,
  # occurs in the encoding. Scope is bound even for equal-looking datasets.
  printf 'scope\tname=journey\n%s%s' "$machine" "$facts"
  [ -z "$guide" ] || printf '%s\n' "$guide"
  [ -z "$token" ] || printf '%s\n' "$token"
  printf '%s%s%s' "$blockers" "$messages" "$rows"
)

# Read producer status: 0 admitted, 1 infrastructure failure, 2 established
# representation invalidity. Canonical admission owns every wire/schema rule.
core_read_admit() (
  local st
  REC_REASON=''
  rec_admit_file res "$1" "$2"
  st=$?
  if [ "$st" = 0 ]; then
    # Admission holds its bounded copy to the contract, not the source file.
    # Retain exactly that copy for publication, even if the source changes.
    cp "$REC_TMP/doc" "$OMB_TMP/journey.admitted" || return 1
    return 0
  fi
  [ "$st" = 1 ] || return 1
  case "$REC_REASON" in
    byte | eof | line | blank | tab | header | key | value | nul-escape | non-canonical | too-large | schema | type | result | after-result) return 2 ;;
    *) return 1 ;;
  esac
)

# The live prefix is copied, never reconstructed from another machine read.
core_read_prefix() {
  omb_tmp_init && cp "$CORE_EVENTS" "$OMB_TMP/journey.prefix"
}

# Stage a legal response document, not the internal mixed dataset. Each write
# has its own checked status; failed machinery must not become representation.
core_read_stage() {
  local op=$1 generation=$2 total=$3 body=$4 status=${5:-done} code=${6:-ok} text=${7:-}
  {
    cat "$OMB_TMP/journey.prefix" &&
      rec_line generation id "$generation" total "$total" &&
      cat "$body" &&
      rec_line result status "$status" code "$code" text "$text" next ''
  } >"$OMB_TMP/journey.response" || return 1
  core_read_admit "$op" "$OMB_TMP/journey.response"
}

# Canonically admit all rows in batches of at most 500. No row has a uniqueness
# rule across pages. Admission proves each line <=16384 bytes (plus LF).
# Any overlapping legal page therefore uses <=500*16385 bytes for rows;
# header + even a maximum-length hello + generation + this fixed result add
# <17000 bytes: <8210000 total, below 8388608. At most 503 records, below
# 65536. This universal bound rejects no legal page and does not require all
# pageable rows to fit one response. Snapshot's complete envelope is admitted
# separately, including all required non-row records and the conditional code.
core_read_rows() {
  local file=$1 line batch='' n=0 st total consumed=0
  total=$(wc -l <"$file") || return 1
  _whole "$total" '^ *[0-9]+$' || return 1
  total=$((total + 0))
  while IFS= read -r line; do
    consumed=$((consumed + 1))
    batch="$batch$line
"
    n=$((n + 1))
    if [ "$n" = 500 ]; then
      printf '%s' "$batch" >"$OMB_TMP/journey.batch" || return 1
      core_read_stage detail "$2" "$total" "$OMB_TMP/journey.batch"
      st=$?
      [ "$st" = 0 ] || return "$st"
      batch='' n=0
    fi
  done <"$file" || return 1
  # `read` ends the loop on EOF and on a read error alike, and the loop's own
  # status is 0 either way. Every caller's file is whole LF-terminated rows
  # (rec_line output, or awk records), so preflight is complete only when
  # every counted row was read and no unterminated bytes remain.
  if [ "$consumed" != "$total" ] || [ -n "$line" ]; then return 1; fi
  printf '%s' "$batch" >"$OMB_TMP/journey.batch" || return 1
  core_read_stage detail "$2" "$total" "$OMB_TMP/journey.batch"
}

core_journey_read() {
  local sum st placeholder
  CORE_JOURNEY=$(core_journey_dataset) || return 1
  core_read_prefix || return 1
  printf '%s' "$CORE_JOURNEY" >"$OMB_TMP/journey" || return 1
  # Split only this capture. Commands read private scratch, never the machine.
  awk -F '\t' '$1 != "scope" && $1 != "row"' "$OMB_TMP/journey" >"$OMB_TMP/journey.snapshot" || return 1
  awk -F '\t' '$1 == "row" && $2 == "kind=machine"' "$OMB_TMP/journey" >"$OMB_TMP/journey.machine" || return 1
  awk -F '\t' '$1 == "row" && $2 == "kind=status"' "$OMB_TMP/journey" >"$OMB_TMP/journey.status" || return 1
  # All SHA-256 ids have identical wire width; no unusable digest is computed
  # or exposed before whole-scope representability has been established.
  placeholder=$(printf '%064d' 0)
  core_read_stage snapshot "$placeholder" 0 "$OMB_TMP/journey.snapshot"
  st=$?
  [ "$st" = 0 ] || return "$st"
  core_read_rows "$OMB_TMP/journey.machine" "$placeholder"
  st=$?
  [ "$st" = 0 ] || return "$st"
  core_read_rows "$OMB_TMP/journey.status" "$placeholder"
  st=$?
  [ "$st" = 0 ] || return "$st"
  # Capture the hash tool's own status (not a trailing pipeline's status).
  if command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 "$OMB_TMP/journey") || return 1
  else
    sum=$(sha256sum "$OMB_TMP/journey") || return 1
  fi
  CORE_JOURNEY_GEN=${sum%% *}
  _whole "$CORE_JOURNEY_GEN" '^[0-9a-f]{64}$'
}

core_read_failure() {
  if [ "$1" = 2 ]; then
    core_result error representation "The required journey response cannot be represented in Protocol 1."
  else
    core_result error io "The journey response could not be prepared."
  fi
}

# Publish only the admitted bytes. Extract and count the suffix before touching
# the live spool; there is no core_emit suppression, re-encoding or new read.
core_read_publish() {
  local bytes records
  tail -n +3 "$OMB_TMP/journey.admitted" >"$OMB_TMP/journey.suffix" || { core_read_failure 1; return; }
  bytes=$(wc -c <"$OMB_TMP/journey.suffix") || { core_read_failure 1; return; }
  records=$(wc -l <"$OMB_TMP/journey.suffix") || { core_read_failure 1; return; }
  cat "$OMB_TMP/journey.suffix" >>"$CORE_EVENTS" || return 1
  CORE_BYTES=$((CORE_BYTES + bytes)) CORE_RECS=$((CORE_RECS + records)) CORE_RESULT=1
}

core_journey_snapshot() {
  local st
  core_journey_read
  st=$?
  if [ "$st" != 0 ]; then core_read_failure "$st"; return; fi
  core_read_stage snapshot "$CORE_JOURNEY_GEN" 0 "$OMB_TMP/journey.snapshot"
  st=$?
  if [ "$st" != 0 ]; then core_read_failure "$st"; return; fi
  core_read_publish
}

# Both authorized detail kinds are projections of exactly the snapshot read.
core_journey_detail() {
  local rows st
  case "$CORE_REQ_KIND" in
    machine | status) ;;
    *) core_result refused unavailable "This journey detail kind is not available."; return ;;
  esac
  core_journey_read
  st=$?
  if [ "$st" != 0 ]; then core_read_failure "$st"; return; fi
  rows=$(cat "$OMB_TMP/journey.$CORE_REQ_KIND") || { core_read_failure 1; return; }
  core_read_page "$CORE_JOURNEY_GEN" "$rows"
}

# A page over already encoded, ordered projection rows. Admission has checked
# generation and bounded offset/limit before this function can be reached.
# The generation belongs to the whole scope; total belongs to this projection.
core_read_page() {
  local generation=$1 rows=$2 total=0 i=0 line page='' status='done' code=ok text='' st
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$total" -ge "$CORE_REQ_OFFSET" ] && [ "$i" -lt "$CORE_REQ_LIMIT" ]; then
      page="$page$line
"
      i=$((i + 1))
    fi
    total=$((total + 1))
  done <<END_ROWS
$rows
END_ROWS
  if [ "$generation" != "$CORE_REQ_GENERATION" ]; then
    status=refused code=changed text='The journey dataset changed; open this detail from a fresh snapshot.' page=''
  elif [ "$CORE_REQ_OFFSET" -gt "$total" ]; then
    status=refused code=invalid text="The offset is beyond this projection's total." page=''
  fi
  core_read_prefix || { core_read_failure 1; return; }
  printf '%s' "$page" >"$OMB_TMP/journey.page" || { core_read_failure 1; return; }
  core_read_stage detail "$generation" "$total" "$OMB_TMP/journey.page" "$status" "$code" "$text"
  st=$?
  if [ "$st" != 0 ]; then core_read_failure "$st"; return; fi
  core_read_publish
}
