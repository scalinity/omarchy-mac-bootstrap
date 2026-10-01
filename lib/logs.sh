# shellcheck shell=bash
# Ordinary fixture-only Logs, owned by BASE cmd_logs' selection/window rule.
# Private scratch only; the text command and log writer remain unchanged.

# Bounded retained output, with separate producer and consumer statuses. Drain
# excess output so the owner can finish and report a real read error, without
# SIGPIPE or trap-sensitive PIPESTATUS. No raw bytes enter a shell variable.
core_logs_window() {
  (
    tail -n 40 "$1" 2>/dev/null
    printf '%s\n' "$?" >"$OMB_TMP/logs.tail-status"
  ) | (
    head -c 655401 >"$OMB_TMP/logs.raw" || exit 1
    cat >/dev/null
  ) || return 1
  local st bytes
  IFS= read -r st <"$OMB_TMP/logs.tail-status" || return 1
  [ "$st" = 0 ] || return 1
  bytes=$(wc -c <"$OMB_TMP/logs.raw") || return 1
  # Every legal row is <=16384 written bytes, excluding LF. Encoding cannot
  # shrink its columns; the row envelope more than replaces the writer's
  # three separators and at most five padding spaces. Opaque rows retain
  # the entire line. Thus 40*(16384+1) bounds every legal raw window. The extra byte
  # proves impossibility; this is a retention bound, never truncation success.
  [ "$bytes" -le 655400 ] || return 3
  LC_ALL=C tr -d '\000' <"$OMB_TMP/logs.raw" >"$OMB_TMP/logs.nonul" || return 1
  cmp -s "$OMB_TMP/logs.raw" "$OMB_TMP/logs.nonul"
  st=$?
  case "$st" in 0) ;; 1) return 3 ;; *) return 1 ;; esac
}

core_logs_capture() {
  local directory latest ancestor st source='' presence=absent line time level phase message expected
  local unresolved_max=0 component_bytes name_max path_invalid=0
  local -a unresolved=()
  local pattern='^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) (\[[^][]+\]) ([a-z]+)( +)(.*)$'
  CORE_LOGS_LINES=0
  omb_tmp_init || return 1
  directory=$(log_dir) || return 1
  latest=''
  if [ -e "$directory" ] || [ -L "$directory" ]; then
    # Exactly BASE's find | sort | tail -1, including its ambient ordering.
    # Record each stage's status outside the pipeline; never let a failed
    # discovery masquerade as no log. Only the selected path is retained.
    (
      find "$directory" -name 'omarchy-bootstrap-*.log' 2>/dev/null
      printf '%s\n' "$?" >"$OMB_TMP/logs.find-status"
    ) | (
      sort
      printf '%s\n' "$?" >"$OMB_TMP/logs.sort-status"
    ) | (
      tail -1
      printf '%s\n' "$?" >"$OMB_TMP/logs.selection-status"
    ) | (
      head -c 16385 >"$OMB_TMP/logs.selected" || exit 1
      cat >/dev/null
    ) || return 1
    IFS= read -r st <"$OMB_TMP/logs.find-status" || return 1
    [ "$st" = 0 ] || return 1
    IFS= read -r st <"$OMB_TMP/logs.sort-status" || return 1
    [ "$st" = 0 ] || return 1
    IFS= read -r st <"$OMB_TMP/logs.selection-status" || return 1
    [ "$st" = 0 ] || return 1
    st=$(wc -c <"$OMB_TMP/logs.selected") || return 1
    [ "$st" -lt 16385 ] || return 2
    latest=$(cat "$OMB_TMP/logs.selected") || return 1
  else
    # False -e/-L can mean resolution failure, not ENOENT. Establish a
    # searchable ancestor and retain unresolved components without rewriting
    # their bytes. NAME_MAX is a byte limit on Linux, but not on every Mac FS.
    ancestor=$directory
    while [ ! -e "$ancestor" ] && [ ! -L "$ancestor" ]; do
      [ "$ancestor" != / ] || return 1
      component_bytes=$(printf '%s' "${ancestor##*/}" | wc -c) || return 1
      unresolved+=("${ancestor##*/}")
      if [ "$component_bytes" -gt "$unresolved_max" ]; then unresolved_max=$component_bytes; fi
      ancestor=${ancestor%/*}
      [ -n "$ancestor" ] || ancestor=/
    done
    [ -d "$ancestor" ] && [ -x "$ancestor" ] || return 1
    name_max=$(getconf NAME_MAX "$ancestor" 2>/dev/null) || return 1
    if ! _uint "$name_max" || [ "$name_max" = 0 ]; then return 1; fi
    if [ "$unresolved_max" -gt "$name_max" ]; then path_invalid=1; fi
    case "$(uname -s)" in
        Darwin)
          # Ask the actual mounted filesystem, rather than guessing a Unicode
          # length/normalization rule from NAME_MAX. Read-only F_OK with
          # AT_SYMLINK_NOFOLLOW requires the original full path to be missing,
          # then tests each component at the searchable ancestor; a missing
          # intermediate component cannot mask ENAMETOOLONG. Darwin
          # fcntl.h defines AT_FDCWD=-2 and AT_SYMLINK_NOFOLLOW=0x0020; errno 2
          # is ENOENT. Existing entries (including symlinks) also prove that the
          # component resolves. JXA has shipped since OS X 10.10; argv is data.
          st=$(osascript -l JavaScript -e '
ObjC.import("stdlib");
ObjC.bindFunction("faccessat", ["int", ["int", "char *", "int", "int"]]);
ObjC.bindFunction("__error", ["int *", []]);
function run(a) {
    var full = $.faccessat(-2, a[0], 0, 0x0020);
    var fullErr = full === 0 ? 0 : $.__error()[0];
    if (full === 0 || fullErr !== 2) return "invalid";
    for (var i = 2; i < a.length; i++) {
        var r = $.faccessat(-2, a[1] + "/" + a[i], 0, 0x0020);
        var e = r === 0 ? 0 : $.__error()[0];
        if (e !== 0 && e !== 2) return "invalid";
    }
    return "valid";
}' "$directory" "$ancestor" "${unresolved[@]}" 2>/dev/null) || return 1
          case "$st" in valid) path_invalid=0 ;; invalid) path_invalid=1 ;; *) return 1 ;; esac
          ;;
        Linux) ;;
        *) return 1 ;;
    esac
    if [ "$path_invalid" = 1 ]; then
      # Preserve established metadata invalidity even for a path which also
      # cannot resolve. Canonical admission owns that distinction; these
      # private facts are never published as an absence dataset.
      core_read_prefix || return 1
      {
        rec_line fact scope logs key logs.state_dir label State value "$(tildify "$OMB_STATE_DIR")" state info &&
          rec_line fact scope logs key logs.directory label Logs value "$(tildify "$directory")" state info
      } >"$OMB_TMP/logs.path-metadata" || return 1
      core_read_stage snapshot e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 0 "$OMB_TMP/logs.path-metadata"
      st=$?
      [ "$st" != 2 ] || return 2
      return 1
    fi
  fi
  : >"$OMB_TMP/logs.raw" || return 1
  if [ -n "$latest" ]; then
    presence=present
    source=$(basename "$latest") || return 1
    core_logs_window "$latest" || return "$?"
  fi
  : >"$OMB_TMP/logs.rows" || return 1
  : >"$OMB_TMP/logs.parsed" || return 1
  while :; do
    line=''
    IFS= read -r line
    st=$?
    case "$st" in 0 | 1) ;; *) return 1 ;; esac
    if [ "$st" = 1 ] && [ -z "$line" ]; then break; fi
    printf '%s' "$line" >>"$OMB_TMP/logs.parsed" || return 1
    if [ "$st" = 0 ]; then printf '\n' >>"$OMB_TMP/logs.parsed" || return 1; fi
    CORE_LOGS_LINES=$((CORE_LOGS_LINES + 1))
    time='' level='' phase='' message=$line
    if _whole "$line" "$pattern"; then
      time=${BASH_REMATCH[1]} phase=${BASH_REMATCH[2]} level=${BASH_REMATCH[3]}
      message=${BASH_REMATCH[5]}
      # Match the writer's %-6s padding and single separator exactly. Extra
      # spaces belong to the message, rather than being stripped by the regex.
      printf -v expected '%s %s %-6s ' "$time" "$phase" "$level"
      case "$line" in
        "$expected"*) message=${line#"$expected"} ;;
        *) time='' level='' phase='' message=$line ;;
      esac
    fi
    rec_line row kind log key "$CORE_LOGS_LINES" col "$time" col "$level" col "$phase" col "$message" >>"$OMB_TMP/logs.rows" || return 1
    [ "$st" = 0 ] || break
  done <"$OMB_TMP/logs.raw" || return 1
  # read returns 1 for both EOF and I/O failure. Prove the parser consumed
  # every ORIGINAL byte, including termination, before publishing any rows.
  cmp -s "$OMB_TMP/logs.raw" "$OMB_TMP/logs.parsed" || return 1
  core_read_prefix || return 1
  # Whole-window row admission precedes metadata, hashing and paging.
  core_read_stage detail "$(printf '%064d' 0)" "$CORE_LOGS_LINES" "$OMB_TMP/logs.rows"
  st=$?
  case "$st" in 0) ;; 2) return 3 ;; *) return 1 ;; esac
  {
    rec_line fact scope logs key logs.state_dir label State value "$(tildify "$OMB_STATE_DIR")" state info &&
      rec_line fact scope logs key logs.directory label Logs value "$(tildify "$directory")" state info || return 1
    if [ "$presence" = present ]; then
      rec_line fact scope logs key logs.source label Source value "$source" state info || return 1
    fi
    rec_line fact scope logs key logs.lines label Lines value "$CORE_LOGS_LINES" state info || return 1
    if [ "$presence" = absent ]; then
      rec_line message level info text 'No log yet.' || return 1
    fi
  } >"$OMB_TMP/logs.snapshot" || return 1
  core_read_stage snapshot "$(printf '%064d' 0)" 0 "$OMB_TMP/logs.snapshot" || return "$?"
  # Canonical metadata frames raw identity unambiguously. The remaining bytes
  # are the ORIGINAL capture, including its exact LF termination. Never hash
  # a parsed/terminated work copy or just the requested page.
  {
    rec_line scope name logs &&
      rec_line context state "$OMB_STATE_DIR" directory "$directory" presence "$presence" path "$latest" &&
      cat "$OMB_TMP/logs.snapshot" &&
      printf 'window\n' && cat "$OMB_TMP/logs.raw"
  } >"$OMB_TMP/logs.identity" || return 1
  local sum
  if command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 "$OMB_TMP/logs.identity") || return 1
  else
    sum=$(sha256sum "$OMB_TMP/logs.identity") || return 1
  fi
  CORE_LOGS_GEN=${sum%% *}
  _whole "$CORE_LOGS_GEN" '^[0-9a-f]{64}$' || return 1
}

core_logs_failure() {
  local status=error code=io text='The logs response could not be prepared.' st
  case "$1" in
    2) code=representation text='The required logs metadata cannot be represented in Protocol 1.' ;;
    3) status=refused code=overflow text='The selected log window cannot be represented in Protocol 1.' ;;
  esac
  # Preflight the safe response too, if machinery remains usable. If the
  # machinery itself failed, fixed emergency records need no offending data
  # or hash tool. Tests independently canonical-admit every failure response.
  if core_read_prefix && : >"$OMB_TMP/logs.failure" &&
    core_read_stage "$CORE_OP" e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 0 "$OMB_TMP/logs.failure" "$status" "$code" "$text"; then
    core_logs_publish
    st=$?
    [ "$st" = 2 ] || return "$st"
  fi
  core_emit generation id e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 total 0 || return 1
  core_result "$status" "$code" "$text"
}

core_logs_publish() {
  local bytes records
  tail -n +3 "$OMB_TMP/journey.admitted" >"$OMB_TMP/logs.suffix" || return 2
  bytes=$(wc -c <"$OMB_TMP/logs.suffix") || return 2
  records=$(wc -l <"$OMB_TMP/logs.suffix") || return 2
  # A failed append is an incomplete transport; never append a second result.
  cat "$OMB_TMP/logs.suffix" >>"$CORE_EVENTS" || return 1
  CORE_BYTES=$((CORE_BYTES + bytes)) CORE_RECS=$((CORE_RECS + records)) CORE_RESULT=1
}

core_logs_op() {
  local op=$1 st status='done' code=ok text='' total=0
  if [ "$op" = detail ] && [ "$CORE_REQ_KIND" != log ]; then
    core_result refused unavailable 'This logs detail kind is not available.'
    return
  fi
  core_logs_capture
  st=$?
  if [ "$st" != 0 ]; then core_logs_failure "$st"; return; fi
  local body=$OMB_TMP/logs.snapshot
  if [ "$op" = detail ]; then
    total=$CORE_LOGS_LINES body=$OMB_TMP/logs.page
    : >"$body" || { core_logs_failure 1; return; }
    if [ "$CORE_REQ_GENERATION" != "$CORE_LOGS_GEN" ]; then
      status=refused code=changed text='The logs dataset changed; open this detail from a fresh snapshot.'
    elif [ "$CORE_REQ_OFFSET" -gt "$total" ]; then
      status=refused code=invalid text="The offset is beyond this projection's total."
    else
      awk -v offset="$CORE_REQ_OFFSET" -v limit="$CORE_REQ_LIMIT" 'NR > offset && NR <= offset + limit' "$OMB_TMP/logs.rows" >"$body" || { core_logs_failure 1; return; }
    fi
  fi
  core_read_stage "$op" "$CORE_LOGS_GEN" "$total" "$body" "$status" "$code" "$text"
  st=$?
  if [ "$st" != 0 ]; then core_logs_failure "$st"; return; fi
  core_logs_publish
  st=$?
  if [ "$st" = 2 ]; then core_logs_failure 1; else return "$st"; fi
}
