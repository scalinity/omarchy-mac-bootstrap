# shellcheck shell=bash
# Ordinary fixture-only plan validation (docs/PROTOCOL.md → *Future plan
# validation contract*): `validate select action=plan.save` with linux_size
# and shared_size. A typed adapter over the baseline's planning owners, which
# stay unchanged: one capture by the macOS survey owner, the gates the
# baseline holds before its storage questions, then parse_size,
# mac_shared_max, mac_plan_compute, plan_validate and plan_layout (with
# plan_verify) — Shared first, then Linux. The response and its
# Q4-plan-validation-basis-v1 basis come from that one capture and that one
# computation. Nothing is persisted, and no generation is carried.

VALIDATE_RULE=Q4-plan-validation-basis-v1

# core_validate_op — after core_read_op admitted the family, the platform,
# the fixture and the scope. Evaluator statuses: 0 go on, 1 the machinery
# failed, 2 a parameter is invalid, 3 no trustworthy plan for this machine,
# 4 an owner outcome the contract does not name.
core_validate_op() {
  local st
  VAL_ANSWERS='' VAL_WARNING='' VAL_LINUX='' VAL_SHARED='' VAL_INVALID='' VAL_REVIEW='' VAL_MESSAGES=''
  VAL_SHARED_GB='' VAL_LINUX_BYTES='' VAL_EXPLAIN=''
  omb_tmp_init || { core_validate_error io; return; }
  # Unknown names, before any machine read.
  core_validate_unknown
  if [ -n "$VAL_UNKNOWN" ]; then
    core_validate_invalid "$VAL_UNKNOWN" unknown-parameter
    core_validate_respond refused invalid
    return
  fi
  core_validate_context
  st=$?
  if [ "$st" = 0 ]; then
    core_validate_shared
    st=$?
  fi
  if [ "$st" = 0 ]; then
    rec_line_v normal name shared_size value $((VAL_SHARED_GB * GB))
    VAL_SHARED="$REC_LINE
"
    core_validate_linux
    st=$?
  fi
  if [ "$st" = 0 ]; then
    # Every refusal the planner can make was settled above.
    plan_layout "$VAL_LINUX_BYTES"
    [ "$PLAN_OK" = 1 ] || st=4
  fi
  case "$st" in
    0) ;;
    2) core_validate_respond refused invalid; return ;;
    3) core_validate_unplannable; return ;;
    4) core_validate_error invariant; return ;;
    *) core_validate_error io; return ;;
  esac
  core_validate_answers || { core_validate_error invariant; return; }
  rec_line_v normal name linux_size value "$VAL_LINUX_BYTES"
  VAL_LINUX="$REC_LINE
"
  if [ -n "$VAL_WARNING" ]; then
    rec_line_v warning id linux-below-recommended text "$VAL_WARNING" fix ''
    VAL_WARNING="$REC_LINE
"
  fi
  core_validate_basis || { core_validate_error io; return; }
  rec_line_v review action plan.save basis "$VAL_BASIS"
  VAL_REVIEW="$REC_LINE
"
  core_validate_respond "done" ok
}

# core_validate_unknown — VAL_UNKNOWN: the first argument name outside the
# family in byte order, whatever the request's order; empty when none is.
core_validate_unknown() {
  local LC_ALL=C i=0 n
  VAL_UNKNOWN=''
  while [ "$i" -lt "$CORE_REQ_ARGS" ]; do
    n=${CORE_REQ_ARG_NAME[i]}
    case "$n" in
      linux_size | shared_size) ;;
      *) if [ -z "$VAL_UNKNOWN" ] || [[ $n < $VAL_UNKNOWN ]]; then VAL_UNKNOWN=$n; fi ;;
    esac
    i=$((i + 1))
  done
}

# core_validate_arg NAME — VAL_ARG: the value the request gives NAME; 1 when
# it gives none (admission allows each name at most once).
core_validate_arg() {
  local i=0
  VAL_ARG=''
  while [ "$i" -lt "$CORE_REQ_ARGS" ]; do
    if [ "${CORE_REQ_ARG_NAME[i]}" = "$1" ]; then
      VAL_ARG=${CORE_REQ_ARG_VALUE[i]}
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# core_validate_context — the one fresh planning context: the survey owner's
# reads (no reachability, saved choice or state), the planner with no
# reservation, and the baseline's gates before its storage questions:
# mac_blockers, then an install already on the disk (mac_main). 0 plannable;
# 3 not, VAL_EXPLAIN holding the owner's reasons, one per line.
core_validate_context() {
  mac_detect
  mac_plan_compute 0
  VAL_EXPLAIN=$(mac_blockers)
  [ -z "$VAL_EXPLAIN" ] || return 3
  [ "$MAC_ASAHI_PRESENT" = 1 ] || return 0
  # The baseline starts no second install: the install's state says why.
  asahi_classify
  VAL_EXPLAIN=$ASAHI_WHY
  [ -n "$VAL_EXPLAIN" ] || return 4
  return 3
}

# core_validate_trim VALUE — VAL_TRIMMED: VALUE without the surrounding blanks
# parse_size trims, read in the C locale parse_size runs in here.
core_validate_trim() {
  local LC_ALL=C v=$1
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  VAL_TRIMMED=$v
}

# core_validate_size NAME VALUE [MAX] — parse_size in the C locale: identical
# for every ASCII value, and a byte the grammar cannot hold is refused rather
# than cut off by a multibyte-locale tr. 0 VAL_SIZE set; 2 invalid; 4 a
# refusal no code names.
core_validate_size() {
  local out st
  out=$(export LC_ALL=C && parse_size "$2" "$MAC_DISK_SIZE" "${3:-}")
  st=$?
  if [ "$st" = 0 ]; then
    _uint "$out" || return 4
    VAL_SIZE=$out
    return 0
  fi
  core_validate_size_code "$2" "$out" || return 4
  core_validate_invalid "$1" "$VAL_CODE"
  return 2
}

# core_validate_size_code VALUE REFUSAL — VAL_CODE: the finite code for
# parse_size's REFUSAL of VALUE. A refusal that echoes the value is matched
# after removing exactly that echo, so the value's own bytes never decide a
# code; 1 for a refusal parse_size does not make.
core_validate_size_code() {
  local rest=''
  case "$2" in
    'enter a size such as 250GB or 30%') VAL_CODE='empty' ;;
    'max is not available here') VAL_CODE='max-unavailable' ;;
    'a percentage cannot exceed 100%') VAL_CODE='percentage-range' ;;
    "'$1' "*) rest=${2#"'$1' "} ;;
    *) return 1 ;;
  esac
  [ -n "$rest" ] || return 0
  case "$rest" in
    'is not a size; use a number with GB, TB, or %') VAL_CODE='syntax' ;;
    'has a leading zero; write '*' if that is what you mean') VAL_CODE='leading-zero' ;;
    'is too large') VAL_CODE='too-large' ;;
    'has more decimals than a size needs') VAL_CODE='precision' ;;
    'is zero') VAL_CODE='zero' ;;
    'is not smaller than the whole internal disk ('*')') VAL_CODE='whole-disk' ;;
    *) return 1 ;;
  esac
}

# core_validate_shared — Shared's turn: VAL_SHARED_GB, the effective whole GB
# (0 for the None sentinel, a trimmed bare 0 alone). Below its minimum or
# above the largest size that leaves Linux its minimum is the person's; when
# that maximum stops at a resize whose limit is unknown, it is the machine's.
core_validate_shared() {
  local g max st
  if ! core_validate_arg shared_size; then
    core_validate_invalid shared_size required
    return 2
  fi
  core_validate_trim "$VAL_ARG"
  if [ "$VAL_TRIMMED" = 0 ]; then
    VAL_SHARED_GB=0
    return 0
  fi
  core_validate_size shared_size "$VAL_ARG"
  st=$?
  [ "$st" = 0 ] || return "$st"
  g=$((VAL_SIZE / GB))
  if [ "$g" -lt "$SHARED_MIN_GB" ]; then
    core_validate_invalid shared_size below-minimum
    return 2
  fi
  max=$(mac_shared_max)
  _uint "$max" || return 4
  if [ "$g" -gt "$max" ]; then
    if [ "$PLAN_LIMITS_KNOWN" = 1 ]; then
      core_validate_invalid shared_size above-maximum
      return 2
    fi
    # The least Linux beside this Shared: the planner's own reason it cannot
    # be laid out without that resize.
    mac_plan_compute "$g"
    plan_layout "$PLAN_LINUX_MIN"
    core_validate_no_region
    return
  fi
  [ $((g * GB)) = "$VAL_SIZE" ] || core_validate_message info "Shared sizes are whole GB: using $g GB."
  VAL_SHARED_GB=$g
}

# core_validate_linux — Linux's turn, beside the effective Shared, with the
# maximum established after it: VAL_LINUX_BYTES, floored to whole GB (with
# the baseline's notice) before plan_validate's range checks.
core_validate_linux() {
  local b verdict st
  mac_plan_compute "$VAL_SHARED_GB"
  if ! core_validate_arg linux_size; then
    core_validate_invalid linux_size required
    return 2
  fi
  core_validate_size linux_size "$VAL_ARG" "$PLAN_LINUX_MAX"
  st=$?
  [ "$st" = 0 ] || return "$st"
  b=$VAL_SIZE
  if [ $((b / GB * GB)) != "$b" ]; then
    b=$((b / GB * GB))
    core_validate_message info "Linux sizes are whole GB: using $(fmt_gb "$b")."
  fi
  verdict=$(plan_validate "$b")
  case "$verdict" in
    ok) ;;
    warn\|*) VAL_WARNING=${verdict#warn|} ;;
    error\|*)
      if [ "$b" -lt "$PLAN_LINUX_MIN" ]; then
        core_validate_invalid linux_size below-minimum
        return 2
      fi
      [ "$b" -gt "$PLAN_LINUX_MAX" ] || return 4
      if [ "$PLAN_LIMITS_KNOWN" = 1 ]; then
        core_validate_invalid linux_size above-maximum
        return 2
      fi
      plan_layout "$b"
      core_validate_no_region
      return
      ;;
    *) return 4 ;;
  esac
  VAL_LINUX_BYTES=$b
}

# core_validate_no_region — after plan_layout of an allocation past the
# established maximum with the resize limit unknown: 3 with the planner's
# reason when it found no region (no mode chosen); 4 for anything else.
core_validate_no_region() {
  if [ "$PLAN_OK" != 1 ] && [ -z "$PLAN_MODE" ] && [ -n "$PLAN_ERR" ]; then
    VAL_EXPLAIN=$PLAN_ERR
    return 3
  fi
  return 4
}

core_validate_invalid() {
  local text
  case "$2" in
    unknown-parameter) text='This parameter is not accepted by plan validation.' ;;
    required) text='This size parameter is required.' ;;
    empty) text='Enter a size such as 250GB or 30%.' ;;
    syntax) text='Use a number with GB, TB, or %.' ;;
    leading-zero) text='Sizes cannot have a leading zero.' ;;
    too-large) text='The numeric size is too large.' ;;
    precision) text='Use at most three decimals for GB/TB or one for %.' ;;
    percentage-range) text='A percentage cannot exceed 100%.' ;;
    zero) text='The numeric size must be greater than zero.' ;;
    whole-disk) text='The size must be smaller than the whole internal disk.' ;;
    max-unavailable) text='max is not available for this parameter.' ;;
    below-minimum) text='The size is below the minimum for this parameter.' ;;
    above-maximum) text='The size exceeds the current maximum for this parameter.' ;;
  esac
  rec_line_v invalid name "$1" code "$2" text "$text"
  VAL_INVALID="$REC_LINE
"
}

core_validate_message() {
  rec_line_v message level "$1" text "$2"
  VAL_MESSAGES="$VAL_MESSAGES$REC_LINE
"
}

# core_validate_unplannable — the owner's reasons as warn messages, and
# nothing that would describe a plan.
core_validate_unplannable() {
  local line
  VAL_ANSWERS='' VAL_WARNING='' VAL_LINUX='' VAL_SHARED='' VAL_INVALID='' VAL_REVIEW='' VAL_MESSAGES=''
  while IFS= read -r line; do
    [ -z "$line" ] || core_validate_message warn "$line"
  done <<EOF
$VAL_EXPLAIN
EOF
  core_validate_respond refused unplannable 'A trustworthy plan cannot be computed for this machine state.'
}

# core_validate_answers — VAL_ANSWERS: the planner's installer answers, in
# its order (SPEC.md → *One region per allocation*): a resize's macOS size,
# then the New OS size. A MiB answer carries its exact bytes; max has none.
core_validate_answers() {
  local n=0
  VAL_ANSWERS=''
  if [ "$PLAN_MODE" = resize ]; then
    n=1
    core_validate_answer_line 1 'New size for macOS' "$PLAN_ANSWER_RESIZE" || return 1
  fi
  core_validate_answer_line $((n + 1)) 'New OS size' "$PLAN_ANSWER_OS"
}

core_validate_answer_line() {
  local bytes=''
  case "$3" in
    max) ;;
    [1-9]*MiB)
      _uint "${3%MiB}" || return 1
      bytes=$((${3%MiB} * MIB))
      ;;
    *) return 1 ;;
  esac
  rec_line_v answer n "$1" prompt "$2" value "$3" bytes "$bytes"
  VAL_ANSWERS="$VAL_ANSWERS$REC_LINE
"
}

# core_validate_sha FILE — VAL_SHA: the file's SHA-256, the hash tool's own
# status checked.
core_validate_sha() {
  local sum
  if command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 "$1") || return 1
  else
    sum=$(sha256sum "$1") || return 1
  fi
  VAL_SHA=${sum%% *}
  _whole "$VAL_SHA" '^[0-9a-f]{64}$'
}

# core_validate_basis — VAL_BASIS: Q4-plan-validation-basis-v1, the SHA-256 of
# an omb-basis 1 document over this capture and computation: the envelope,
# the effective Shared then Linux sizes, the digests of the consumed
# geometry and of the resulting plan, and the versions. Unsealed record
# lines, hashed and never sent (docs/PROTOCOL.md → *Q4-plan-validation-basis-v1*).
core_validate_basis() {
  local f=$OMB_TMP/validate off size uuid content id role start pred succ geometry
  # The consumed planning geometry, partitions and free regions in disk order.
  {
    printf 'omb-validate-geometry 1\n' &&
      rec_line disk size "$GEO_DISK_SIZE" block "$GEO_BLOCK" start "$GEO_USABLE_START" end "$GEO_USABLE_END"
  } >"$f.geometry" || return 1
  while IFS='|' read -r off size uuid content id role; do
    [ -n "$off" ] || continue
    rec_line part guid "$uuid" offset "$off" size "$size" content "$content" role "$role" >>"$f.geometry" || return 1
  done <<EOF
$GEO_PARTS
EOF
  {
    rec_line store guid "$MAC_STORE_UUID" &&
      rec_line container size "$MAC_CONTAINER_SIZE" free "$MAC_CONTAINER_FREE" floor "$PLAN_MACOS_FLOOR" &&
      rec_line limits known "$PLAN_LIMITS_KNOWN" value "$MAC_LIMIT_PREF" &&
      rec_line resize available "$PLAN_RESIZE_OK" end "$PLAN_RZ_END"
  } >>"$f.geometry" || return 1
  while IFS='|' read -r start size pred succ; do
    [ -n "$start" ] || continue
    rec_line gap start "$start" size "$size" >>"$f.geometry" || return 1
  done <<EOF
$GEO_GAPS
EOF
  core_validate_sha "$f.geometry" || return 1
  geometry=$VAL_SHA
  # The resulting plan: mode, region, extents and the exact answers.
  {
    printf 'omb-validate-plan 1\n' &&
      rec_line mode value "$PLAN_MODE" &&
      rec_line region start "$PLAN_GAP_START" end "$PLAN_GAP_END" pred "$PLAN_GAP_PRED" succ "$PLAN_GAP_SUCC" &&
      rec_line macos size "$PLAN_MACOS_NEW" &&
      rec_line linux start "$PLAN_LIN_START" end "$PLAN_LIN_END" root "$PLAN_ROOT" &&
      rec_line shared start "$PLAN_SHARED_START" end "$PLAN_SHARED_END" &&
      printf '%s' "$VAL_ANSWERS"
  } >"$f.plan" || return 1
  core_validate_sha "$f.plan" || return 1
  {
    printf 'omb-basis 1\n' &&
      rec_line basis action plan.save proto "$REC_PROTO" actor_uid "$OMB_UID" home "$OMB_HOME" source "$CORE_SOURCE" &&
      rec_line input name shared_size value $((VAL_SHARED_GB * GB)) &&
      rec_line input name linux_size value "$VAL_LINUX_BYTES" &&
      rec_line seen key geometry state value value '' sha256 "$geometry" mode '' link '' &&
      rec_line seen key plan state value value '' sha256 "$VAL_SHA" mode '' link '' &&
      rec_line version key storage_contract value "$STORAGE_CONTRACT" &&
      rec_line version key template value "$ASAHI_ALARM_OS_CHOICE" &&
      rec_line version key rule value "$VALIDATE_RULE"
  } >"$f.basis" || return 1
  core_validate_sha "$f.basis" || return 1
  VAL_BASIS=$VAL_SHA
}

# core_validate_respond STATUS CODE [TEXT] — stage the whole response after
# the live hello, admit it canonically, then publish exactly the admitted
# bytes. Only established wire invalidity is representation; any machinery
# failure before that proof is io.
core_validate_respond() {
  local st
  core_validate_stage "$@"
  st=$?
  case "$st" in
    0) ;;
    2)
      core_validate_error representation
      return
      ;;
    *)
      core_validate_error io
      return
      ;;
  esac
  core_validate_publish
  st=$?
  # A failed append is an incomplete transport: never a second result.
  if [ "$st" = 2 ]; then core_validate_error io; fi
}

core_validate_stage() {
  printf '%s' "$VAL_ANSWERS$VAL_WARNING$VAL_LINUX$VAL_SHARED$VAL_INVALID$VAL_REVIEW$VAL_MESSAGES" >"$OMB_TMP/validate.body" || return 1
  core_read_prefix || return 1
  {
    cat "$OMB_TMP/journey.prefix" &&
      cat "$OMB_TMP/validate.body" &&
      rec_line result status "$1" code "$2" text "${3:-}" next ''
  } >"$OMB_TMP/validate.response" || return 1
  core_read_admit validate "$OMB_TMP/validate.response"
}

# Publish only the admitted bytes, without another read or encoding.
core_validate_publish() {
  local bytes records
  tail -n +3 "$OMB_TMP/journey.admitted" >"$OMB_TMP/validate.suffix" || return 2
  bytes=$(wc -c <"$OMB_TMP/validate.suffix") || return 2
  records=$(wc -l <"$OMB_TMP/validate.suffix") || return 2
  cat "$OMB_TMP/validate.suffix" >>"$CORE_EVENTS" || return 1
  CORE_BYTES=$((CORE_BYTES + bytes)) CORE_RECS=$((CORE_RECS + records)) CORE_RESULT=1
}

# core_validate_error io|invariant|representation — the fixed safe result
# after hello: no candidate record, no generation.
core_validate_error() {
  case "$1" in
    io) core_result error io 'The validation response could not be prepared.' ;;
    invariant) core_result error invariant "The planner's internal checks did not hold." ;;
    representation) core_result error representation 'The required validation response cannot be represented in Protocol 1.' ;;
  esac
}
