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

core_journey_read() {
  local sum
  CORE_JOURNEY=$(core_journey_dataset) || return 1
  # Capture the hash tool's own status (not the status of a trailing awk).
  printf '%s' "$CORE_JOURNEY" >"$OMB_TMP/journey" || return 1
  if command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 "$OMB_TMP/journey") || return 1
  else
    sum=$(sha256sum "$OMB_TMP/journey") || return 1
  fi
  CORE_JOURNEY_GEN=${sum%% *}
  _whole "$CORE_JOURNEY_GEN" '^[0-9a-f]{64}$'
}

core_journey_snapshot() {
  local body='' line
  if ! core_journey_read; then
    core_result error io "The journey dataset could not be read."
    return
  fi
  while IFS= read -r line; do
    case "$line" in $'scope\t'* | $'row\t'*) continue ;; esac
    body="$body$line
"
  done <<END_DATASET
$CORE_JOURNEY
END_DATASET
  core_emit generation id "$CORE_JOURNEY_GEN" total 0
  _core_emit_body "$body" || return 1
  core_result "done" ok
}

# Both authorized detail kinds are projections of exactly the snapshot read.
core_journey_detail() {
  local rows='' line prefix
  case "$CORE_REQ_KIND" in
    machine | status) ;;
    *) core_result refused unavailable "This journey detail kind is not available."; return ;;
  esac
  if ! core_journey_read; then
    core_result error io "The journey dataset could not be read."
    return
  fi
  prefix=$(printf 'row\tkind=%s\t' "$CORE_REQ_KIND")
  while IFS= read -r line; do
    case "$line" in "$prefix"*) rows="$rows$line
" ;; esac
  done <<END_DATASET
$CORE_JOURNEY
END_DATASET
  core_read_page "$CORE_JOURNEY_GEN" "$rows"
}

# A page over already encoded, ordered projection rows. Admission has checked
# generation and bounded offset/limit before this function can be reached.
# The generation belongs to the whole scope; total belongs to this projection.
core_read_page() {
  local generation=$1 rows=$2 total=0 i=0 line page=''
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
  core_emit generation id "$generation" total "$total"
  if [ "$generation" != "$CORE_REQ_GENERATION" ]; then
    core_result refused changed "The journey dataset changed; open this detail from a fresh snapshot."
  elif [ "$CORE_REQ_OFFSET" -gt "$total" ]; then
    core_result refused invalid "The offset is beyond this projection's total."
  else
    _core_emit_body "$page" || return 1
    core_result "done" ok
  fi
}
