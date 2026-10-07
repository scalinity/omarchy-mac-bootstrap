# shellcheck shell=bash
# The operation-record diagnostic (docs/PROTOCOL.md → *The operation-record
# diagnostic*, D55): one inspection of a scope's operation record, in the
# contract's order, whose finding the foundation's journey snapshot, `detail
# kind=operation` and the text command `operation SCOPE` all carry. It is a
# read: no lock, no record, nothing written outside this run's scratch, and
# nothing opened but a plain file. Each step keeps its own outcome: a tool
# that fails is a step that could not complete, never a finding about the
# record, and no byte of a record that did not admit reaches an answer.
#
# Needs lib/common.sh, lib/state.sh, lib/ui.sh, lib/records.sh, lib/core.sh
# and lib/read.sh.

OP_DOC_MAX=65536
OP_EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
OP_IO_TEXT='The operation record response could not be prepared.'
OP_REP_TEXT='The required operation record response cannot be represented in Protocol 1.'

# ---------------------------------------------------------------------------
# Tools, each status counted
# ---------------------------------------------------------------------------

# _op_find PATH PREDICATE... — OP_HIT 1 when find, given PATH alone and never
# following it, matches PREDICATE, else 0; 1 when find fails.
_op_find() {
  local p=$1 st
  shift
  find "$p" -maxdepth 0 "$@" -print 2>/dev/null >"$OP_DIR/find"
  st=$?
  [ "$st" = 0 ] || return 1
  OP_HIT=0
  if [ -s "$OP_DIR/find" ]; then OP_HIT=1; fi
}

# _op_size FILE — OP_N: FILE's size in bytes, by wc -c; 1 when it cannot be read.
_op_size() {
  local st
  OP_N=""
  wc -c "$1" 2>/dev/null >"$OP_DIR/size"
  st=$?
  [ "$st" = 0 ] || return 1
  read -r OP_N _ <"$OP_DIR/size" || return 1
  _whole "$OP_N" '^[0-9]+$'
}

# _op_hash FILE — OP_HASH: the SHA-256 of FILE's bytes; 1 when it cannot be
# computed.
_op_hash() {
  local st
  OP_HASH=""
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null >"$OP_DIR/hash"
  else
    sha256sum "$1" 2>/dev/null >"$OP_DIR/hash"
  fi
  st=$?
  [ "$st" = 0 ] || return 1
  read -r OP_HASH _ <"$OP_DIR/hash" || return 1
  _whole "$OP_HASH" '^[0-9a-f]{64}$'
}

# ---------------------------------------------------------------------------
# The inspection (*The inspection*, steps 0 to 7)
# ---------------------------------------------------------------------------

# _op_lookup — 0 an entry at OP_PATH; 1 none, established; 2 it cannot be
# established. Nothing is followed: the state folder and its ops folder must
# each be a folder of this user that this process can search, ops one it can
# list, as the launcher lists it.
_op_lookup() {
  local d=$OMB_STATE_DIR a
  if [ -L "$d" ]; then return 2; fi
  if [ ! -e "$d" ]; then
    # No state folder is no record when the nearest folder that exists above
    # it can be searched, as for Logs: beneath one that cannot, a false -e
    # says nothing.
    a=$d
    while [ ! -e "$a" ] && [ ! -L "$a" ]; do
      if [ "$a" = / ]; then return 2; fi
      a=${a%/*}
      [ -n "$a" ] || a=/
    done
    if [ -d "$a" ] && [ -x "$a" ]; then return 1; fi
    return 2
  fi
  if ! { [ -d "$d" ] && [ -O "$d" ] && [ -x "$d" ]; }; then return 2; fi
  if [ -L "$d/ops" ]; then return 2; fi
  if [ ! -e "$d/ops" ]; then return 1; fi
  if ! { [ -d "$d/ops" ] && [ -O "$d/ops" ] && [ -x "$d/ops" ] && [ -r "$d/ops" ]; }; then return 2; fi
  if [ -e "$OP_PATH" ] || [ -L "$OP_PATH" ]; then return 0; fi
  return 1
}

# _op_status — the entry's own status, never followed: OP_KIND, OP_OWNER and,
# but for a link, whose own mode means nothing, OP_WRITABLE. 1 when it cannot
# be read (the entry gone since the lookup included).
_op_status() {
  local f=$OP_PATH uid
  if [ -L "$f" ]; then
    OP_KIND='link'
  elif [ -f "$f" ]; then
    OP_KIND='file'
  elif [ -d "$f" ]; then
    OP_KIND='folder'
  elif [ -e "$f" ]; then
    OP_KIND='other'
  else
    return 1
  fi
  # The user this process runs as, from the machine, as _state_owned_safe
  # reads it: a fixture's own user id says nothing about these files.
  uid=$(id -u) || return 1
  _whole "$uid" '^[0-9]+$' || return 1
  _op_find "$f" -user "$uid" || return 1
  if [ "$OP_HIT" = 1 ]; then
    OP_OWNER=this-user
  else
    _op_find "$f" -user 0 || return 1
    OP_OWNER=other-user
    if [ "$OP_HIT" = 1 ]; then OP_OWNER=root; fi
  fi
  [ "$OP_KIND" != link ] || return 0
  _op_find "$f" \( -perm -020 -o -perm -002 \) || return 1
  OP_WRITABLE=no
  if [ "$OP_HIT" = 1 ]; then OP_WRITABLE=yes; fi
}

# _op_read — 0 the bounded copy ($OP_DIR/record) holds the whole file, of
# OP_SIZE bytes; 1 the size cannot be read; 2 over the stored-document limit,
# nothing read; 3 no copy, or a copy of another length.
_op_read() {
  local st
  _op_size "$OP_PATH" || return 1
  OP_SIZE=$OP_N
  [ "$OP_SIZE" -le "$OP_DOC_MAX" ] || return 2
  head -c "$((OP_DOC_MAX + 1))" "$OP_PATH" 2>/dev/null >"$OP_DIR/record"
  st=$?
  [ "$st" = 0 ] || return 3
  _op_size "$OP_DIR/record" || return 3
  [ "$OP_N" = "$OP_SIZE" ] || return 3
}

# _op_seal FILE — the seal comparison, run to its end: 0 it matches; 1 it
# does not (not one seal line, last, or another digest); 2 it could not be
# made. The admission's own answer, `seal`, cannot tell 1 from 2.
_op_seal() {
  local f=$1 st n at nr last want
  LC_ALL=C awk 'BEGIN { n = 0 } /^seal\t/ { n++; at = NR } END { printf "%d %d %d\n", n, at, NR }' "$f" 2>/dev/null >"$OP_DIR/seals"
  st=$?
  [ "$st" = 0 ] || return 2
  read -r n at nr <"$OP_DIR/seals" || return 2
  if [ "$n" != 1 ] || [ "$at" != "$nr" ]; then return 1; fi
  tail -n 1 "$f" 2>/dev/null >"$OP_DIR/seal-line"
  st=$?
  [ "$st" = 0 ] || return 2
  IFS= read -r last <"$OP_DIR/seal-line" || return 2
  case "$last" in "seal	sha256="*) ;; *) return 1 ;; esac
  want=${last#seal	sha256=}
  _whole "$want" '^[0-9a-f]{64}$' || return 1
  # The copy passed the byte class: one character is one byte.
  head -c "$((OP_SIZE - ${#last} - 1))" "$f" 2>/dev/null >"$OP_DIR/sealed"
  st=$?
  [ "$st" = 0 ] || return 2
  _op_hash "$OP_DIR/sealed" || return 2
  [ "$OP_HASH" = "$want" ] || return 1
}

# _op_owns SCOPE ACTION — ACTION is one of SCOPE's own actions in this core,
# whether or not it is available now: a scope's own action that is merely
# unavailable is no corruption (UR-Q9).
_op_owns() {
  local a
  for a in $CORE_TEST_ACTIONS; do
    [ "$a" = "$2" ] || continue
    # Its status says whether the foundation exposes it now; its scope is
    # set either way.
    core_action_info "$a" || :
    [ "$CA_SCOPE" = "$1" ] && return 0
  done
  return 1
}

# _op_same — the copy is still the size read: a check that read it to its
# end read all of it.
_op_same() {
  _op_size "$OP_DIR/record" || return 1
  [ "$OP_N" = "$OP_SIZE" ]
}

# _op_check SCOPE — §2's admission of the copy, then UR-Q9's: 0 every check
# passed (OP_R* from the admitted record); 1 a check ran to its end and
# refused (OP_REASON, and OP_LINE when it names one); 2 a check could not
# run to its end, whatever code it then left.
_op_check() {
  local copy=$OP_DIR/record v=""
  if ! rec_admit_copied op - "$copy"; then
    case "$REC_REASON" in
      seal)
        # The admission answers `seal` for a tool that failed too
        # (docs/PROTOCOL.md → §3, *Today*): only a comparison run to its
        # end establishes it.
        _op_seal "$copy"
        [ "$?" = 1 ] || return 2
        OP_REASON=seal
        ;;
      too-large | byte | eof | line | blank | tab | header | key | value | nul-escape | non-canonical | schema | type)
        OP_REASON=$REC_REASON
        if [ "${REC_AT:-0}" -gt 0 ]; then OP_LINE=$REC_AT; fi
        ;;
      *) return 2 ;;
    esac
    _op_same || return 2
    return 1
  fi
  rec_get_into v 0 scope || return 2
  if [ "$v" != "$1" ]; then
    _op_same || return 2
    OP_REASON=other-scope
    return 1
  fi
  rec_get_into v 0 action || return 2
  if ! _op_owns "$1" "$v"; then
    _op_same || return 2
    OP_REASON=other-action
    return 1
  fi
  OP_RACTION=$v
  rec_get_into OP_RSTATE 0 state || return 2
  rec_get_into OP_RFINDING 0 finding || return 2
  rec_get_into OP_RPID 0 pid || return 2
  rec_get_into OP_RSTART 0 start || return 2
  rec_get_into OP_RBOOT 0 boot || return 2
  _op_same || return 2
}

# _op_case — a readable record's case, as core_barrier decides it: OP_BOOT
# this, earlier or unknown; OP_CASE alive, unknown, unsupervised, failed or
# earlier.
_op_case() {
  if [ -z "$CORE_BOOT" ]; then
    OP_BOOT=unknown
  elif [ "$OP_RBOOT" = "$CORE_BOOT" ]; then
    OP_BOOT=this
  else
    OP_BOOT=earlier OP_CASE=earlier
    return 0
  fi
  case "$OP_RSTATE" in
    running)
      core_alive "$OP_RPID" "$OP_RSTART" "$OP_RBOOT"
      case $? in
        0) OP_CASE=alive ;;
        2) OP_CASE=unknown ;;
        *) OP_CASE=unsupervised ;;
      esac
      ;;
    failed) OP_CASE=failed ;;
    *) OP_CASE=unsupervised ;;
  esac
}

# op_inspect SCOPE — one inspection of SCOPE's operation record, in the
# contract's order: OP_STATE none, readable, unreadable or undetermined (and
# OP_STAGE), with the fields its steps established. 0 a finding, whatever it
# is; 1 the diagnostic's own machinery failed (error io). This core
# implements no clear, so it has no clear's evidence to inspect (step 5)
# and writes no clear row.
op_inspect() {
  local st=1
  OP_STATE="" OP_STAGE="" OP_KIND="" OP_OWNER="" OP_WRITABLE="" OP_SIZE="" OP_FP="" OP_REASON="" OP_LINE=""
  OP_RACTION="" OP_RSTATE="" OP_RFINDING="" OP_RPID="" OP_RSTART="" OP_RBOOT="" OP_BOOT="" OP_CASE=""
  OP_PATH=$(core_op_path "$1")
  # 0. The per-run scratch, made and shown writable before the record is
  # looked at.
  omb_tmp_init || return 1
  OP_DIR=$OMB_TMP/operation
  (umask 077 && mkdir -p "$OP_DIR") 2>/dev/null || return 1
  if [ -L "$OP_DIR" ] || [ ! -d "$OP_DIR" ]; then return 1; fi
  : 2>/dev/null >"$OP_DIR/probe" || return 1
  _rec_tmp || return 1
  # 1. Lookup.
  _op_lookup
  case $? in
    1) OP_STATE=none; return 0 ;;
    2) OP_STATE=undetermined OP_STAGE=lookup; return 0 ;;
  esac
  # 2. Status: anything but a plain file is never opened.
  if ! _op_status; then
    OP_STATE=undetermined OP_STAGE=status
    return 0
  fi
  if [ "$OP_KIND" != file ]; then
    OP_STATE=unreadable OP_REASON=kind
    return 0
  fi
  if [ "$OP_OWNER" = other-user ]; then
    OP_STATE=unreadable OP_REASON=owner
  elif [ "$OP_WRITABLE" = yes ]; then
    OP_STATE=unreadable OP_REASON=writable
  fi
  # 3. Read: the size, then the bounded copy of the whole file. For a file
  # its status refused, what cannot be read is only its fingerprint.
  _op_read
  st=$?
  case $st in
    0) ;;
    2)
      OP_FP=none
      if [ -z "$OP_STATE" ]; then OP_STATE=unreadable OP_REASON=too-large; fi
      ;;
    *)
      if [ -n "$OP_STATE" ]; then
        OP_FP=unknown
      else
        OP_STATE=undetermined OP_STAGE=read
      fi
      ;;
  esac
  # 4. Check, for a file its status admitted, read in full.
  if [ -z "$OP_STATE" ]; then
    _op_check "$1"
    case $? in
      0) OP_STATE=readable ;;
      1) OP_STATE=unreadable ;;
      *) OP_STATE=undetermined OP_STAGE=check ;;
    esac
  fi
  # 6. The fingerprint of every byte copied, for an unreadable plain file.
  if [ "$OP_STATE" = unreadable ] && [ "$st" = 0 ]; then
    _op_hash "$OP_DIR/record" || return 1
    OP_FP=$OP_HASH
  fi
  # 7. Workers: only a readable record's own evidence establishes any.
  if [ "$OP_STATE" = readable ]; then _op_case; fi
  return 0
}

# ---------------------------------------------------------------------------
# The finding's words (*The rows*, *Fixed texts*, *The next safe step*)
# ---------------------------------------------------------------------------

# _op_text KEY VALUE — OP_T: that row's fixed text (empty for none).
_op_text() {
  OP_T=''
  case "$1:$2" in
    state:none) OP_T='No operation in this scope is recorded as begun and not settled.' ;;
    state:readable) OP_T='The operation record of this scope can be read.' ;;
    state:unreadable) OP_T='A record exists in this scope and cannot be read, so nothing it says is known.' ;;
    state:undetermined) OP_T='Whether a record exists in this scope, or what it says, could not be established.' ;;
    stage:lookup) OP_T='Whether the record exists could not be established: the state directory or its ops folder is a link, is not a folder of yours, or cannot be searched or listed.' ;;
    stage:status) OP_T="The record's status could not be read." ;;
    stage:read) OP_T="The record's bytes could not be read in full." ;;
    stage:check) OP_T="A check of the record's bytes could not run to its end." ;;
    kind:file) OP_T='a plain file' ;;
    kind:link) OP_T='a symbolic link, never followed' ;;
    kind:folder) OP_T='a folder, never opened' ;;
    kind:other) OP_T='not a plain file, never opened' ;;
    owner:this-user) OP_T='you' ;;
    owner:root) OP_T='root' ;;
    owner:other-user) OP_T='another user' ;;
    writable:yes) OP_T='group or others may write it' ;;
    writable:no) OP_T='only its owner may write it' ;;
    fingerprint:none) OP_T='none: it is larger than 65536 bytes, so it is not read in full' ;;
    fingerprint:unknown) OP_T='unknown: its bytes could not be read in full' ;;
    fingerprint:*) OP_T='SHA-256 of all its bytes, for comparing inspections only' ;;
    reason:kind) OP_T='it is not a plain file' ;;
    reason:owner) OP_T='it belongs to another user' ;;
    reason:writable) OP_T='group or others may write it' ;;
    reason:too-large) OP_T='it is larger than 65536 bytes' ;;
    reason:byte) OP_T='it holds a byte no record may hold' ;;
    reason:eof) OP_T='it does not end with a line end' ;;
    reason:seal) OP_T='its seal does not match its bytes' ;;
    reason:line | reason:blank | reason:tab | reason:header | reason:key | reason:value | reason:nul-escape | reason:non-canonical)
      OP_T='it breaks the record format'
      ;;
    reason:schema) OP_T="its records are not an operation record's" ;;
    reason:type) OP_T='a value breaks its type' ;;
    reason:other-scope) OP_T='it names another scope' ;;
    reason:other-action) OP_T='it names an action this scope does not have' ;;
    recorded.state:running) OP_T='recorded as running' ;;
    recorded.state:unsupervised) OP_T='recorded as unsupervised' ;;
    recorded.state:failed) OP_T='recorded as ended without its expected effect' ;;
    recorded.finding:absent) OP_T='When it ended, the machine still showed its old state.' ;;
    recorded.finding:unexpected) OP_T='When it ended, the machine showed something other than its old state or its effect.' ;;
    boot:this) OP_T='this boot' ;;
    boot:earlier) OP_T='an earlier boot' ;;
    boot:unknown) OP_T='this boot could not be identified' ;;
  esac
}

# _op_tail — OP_WV and OP_WT, the workers' value and text; OP_ET, the
# effect's text; OP_UT, what stays unknown; OP_NT, the next safe step.
_op_tail() {
  OP_WV=unknown
  case "$OP_STATE:$OP_CASE" in
    none:)
      OP_UT='Whether any action ran here before, and what it changed: a settled or removed record leaves nothing behind.'
      OP_NT='None for this record. This alone allows nothing: every action still makes its own fresh checks.'
      return 0
      ;;
    readable:*)
      OP_ET='Not judged: this check reconciles nothing.'
      OP_UT='What the machine holds now: this check reconciles nothing.'
      OP_NT='Restart this Mac (or this Linux system), then run the tool again.'
      ;;
    unreadable:)
      OP_WT='Nothing ties a running process to this record, so whether one it started still runs is unknown.'
      OP_ET='Unknown: what the operation changed cannot be judged without the record.'
      OP_UT='Everything the record says: its action, session, process, boot and state, whether it ended, and what it changed.'
      OP_NT='Nothing in this scope can run while this record is there, and a restart does not change that. This tool offers no way to clear it yet. You may look at the file with your own tools; this tool never shows its bytes.'
      return 0
      ;;
    *)
      OP_WT='Unknown while the record cannot be inspected.'
      OP_ET='Unknown while the record cannot be inspected.'
      OP_UT='Whether a record exists here, and anything it says.'
      case "$OP_STAGE" in
        lookup) OP_NT='Make the state directory and its ops folder real folders of yours that you can open and list, then check again. This tool changes no permission and moves nothing.' ;;
        status) OP_NT="Make the record's status readable, then check again. This tool changes no permission and moves nothing." ;;
        read) OP_NT='Make the record readable in full, then check again. This tool changes no permission and moves nothing.' ;;
        *) OP_NT='Make sure the standard tools a check runs can run, then check again.' ;;
      esac
      return 0
      ;;
  esac
  case "$OP_CASE" in
    alive)
      OP_WV=active OP_WT='The core that recorded it is running now.'
      OP_NT='Wait for it to finish, then check again.'
      ;;
    unknown)
      OP_WT='Whether the core that recorded it is running could not be established; it counts as running.'
      OP_NT='Wait, then check again. If whether its core runs stays unknown, restart this Mac (or this Linux system), then run the tool again.'
      ;;
    unsupervised) OP_WT='Its core no longer supervises it; a process it started may still be running.' ;;
    failed) OP_WV=ended OP_WT="It ended under its core's supervision, with no worker left, as recorded." ;;
    earlier)
      OP_WV=ended OP_WT='It was recorded in an earlier boot; no process of that boot still runs.'
      OP_NT='Run the tool again, not as a dry run: it reconciles this scope from what the machine holds before any action in it.'
      ;;
  esac
}

# _op_row KEY LABEL VALUE [TEXT] — one row of the finding; with no TEXT,
# the fixed text of KEY and VALUE.
_op_row() {
  if [ "$#" = 4 ]; then OP_T=$4; else _op_text "$1" "$3"; fi
  rec_line row kind operation key "$1" col "$2" col "$3" col "$OP_T" >>"$OP_DIR/rows" || return 1
  OP_TOTAL=$((OP_TOTAL + 1))
}

# op_rows SCOPE — the finding as rows, in the contract's order, into
# $OP_DIR/rows: a row whose field does not apply is absent, one that applies
# and was not established says unknown. OP_TOTAL rows; 1 when they cannot
# be written.
op_rows() {
  local path entry=0
  OP_TOTAL=0
  : 2>/dev/null >"$OP_DIR/rows" || return 1
  path=$(tildify "$OP_PATH")
  _op_row scope Scope "$1" '' || return 1
  _op_row path Record "$path" '' || return 1
  _op_row state State "$OP_STATE" || return 1
  if [ "$OP_STATE" = undetermined ]; then
    _op_row stage 'Failed step' "$OP_STAGE" || return 1
    case "$OP_STAGE" in read | check) entry=1 ;; esac
  fi
  [ "$OP_STATE" != unreadable ] || entry=1
  if [ "$entry" = 1 ]; then
    _op_row kind Entry "$OP_KIND" || return 1
    _op_row owner Owner "$OP_OWNER" || return 1
    if [ "$OP_KIND" != link ]; then _op_row writable 'Writable by others' "$OP_WRITABLE" || return 1; fi
    if [ "$OP_KIND" = file ] && [ -n "$OP_SIZE" ]; then _op_row size Size "$OP_SIZE" '' || return 1; fi
  fi
  if [ "$OP_STATE" = unreadable ]; then
    if [ "$OP_KIND" = file ]; then _op_row fingerprint Fingerprint "$OP_FP" || return 1; fi
    _op_row reason 'Refused by' "$OP_REASON" || return 1
    if [ -n "$OP_LINE" ]; then _op_row line 'At line' "$OP_LINE" '' || return 1; fi
  fi
  if [ "$OP_STATE" = readable ]; then
    _op_row recorded.action 'Recorded action' "$OP_RACTION" '' || return 1
    _op_row recorded.state 'Recorded state' "$OP_RSTATE" || return 1
    if [ "$OP_RSTATE" = failed ]; then _op_row recorded.finding 'Recorded finding' "$OP_RFINDING" || return 1; fi
    _op_row boot 'Recorded boot' "$OP_BOOT" || return 1
  fi
  _op_tail
  if [ "$OP_STATE" != none ]; then
    _op_row worker Workers "$OP_WV" "$OP_WT" || return 1
    _op_row effect Effect unknown "$OP_ET" || return 1
  fi
  _op_row unknown 'Still unknown' '' "$OP_UT" || return 1
  _op_row next Next '' "$OP_NT"
}

# op_capture SCOPE — the inspection and its rows; 1 when the diagnostic's own
# machinery fails.
op_capture() {
  op_inspect "$1" || return 1
  op_rows "$1"
}

# op_barrier SCOPE — the snapshot's operation fact and blockers for the
# finding (*The states on the wire*), printed as records; OP_ACTS 1 when the
# scope's act actions may be listed. The readable cases keep today's
# words; a fact or blocker never carries the path.
op_barrier() {
  local a=$OP_RACTION
  OP_ACTS=0
  case "$OP_STATE:$OP_CASE" in
    none:)
      OP_ACTS=1
      rec_line fact scope "$1" key operation label Operation value 'none recorded' state ok
      ;;
    unreadable:)
      rec_line fact scope "$1" key operation label Operation value 'a record that cannot be read' state fail &&
        rec_line blocker id unreadable \
          text 'The operation record of this scope exists and cannot be read, so what it recorded is unknown; a restart does not change that.' \
          fix 'Nothing in this scope runs while it is there. Its operation record check shows what can be established.'
      ;;
    undetermined:)
      rec_line fact scope "$1" key operation label Operation value 'cannot be inspected' state unknown &&
        rec_line blocker id undetermined \
          text 'The operation record of this scope could not be inspected, so whether one exists is unknown.' \
          fix 'Nothing in this scope runs until it can be inspected. Its operation record check names the step that failed.'
      ;;
    readable:alive) rec_line fact scope "$1" key operation label Operation value "$a running" state info ;;
    readable:unknown)
      rec_line fact scope "$1" key operation label Operation value "$a recorded as running; whether its core runs is unknown" state warn
      ;;
    readable:unsupervised)
      rec_line fact scope "$1" key operation label Operation value "$a unsupervised" state fail &&
        rec_line blocker id unsupervised text "The outcome of $a is unknown and a process it started may still be running." \
          fix "Restart this Mac (or this Linux system), then run the tool again."
      ;;
    readable:failed)
      CO_ACTION=$a CO_FINDING=$OP_RFINDING
      core_failed_text
      rec_line fact scope "$1" key operation label Operation value "$a ended without its expected effect" state fail &&
        rec_line blocker id unresolved text "$CORE_FAILED_TEXT" \
          fix "Restart this Mac (or this Linux system), then run the tool again: the scope is reconciled from what the machine then holds."
      ;;
    readable:earlier)
      OP_ACTS=1
      rec_line fact scope "$1" key operation label Operation value "$a from an earlier boot, to reconcile" state warn
      ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# The protocol's answers: the foundation's journey snapshot and its detail
# ---------------------------------------------------------------------------

# core_op_dataset SCOPE — the snapshot's one data set: the inspection, its
# rows, the snapshot's records ($OP_DIR/body) and OP_GEN, the SHA-256 of the
# scope, those records and every row, off-page rows included. 1 when the
# diagnostic's own machinery fails.
core_op_dataset() {
  op_capture "$1" || return 1
  _core_snapshot_body 2>/dev/null >"$OP_DIR/body" || return 1
  {
    rec_line scope name "$1" && cat "$OP_DIR/body" "$OP_DIR/rows"
  } 2>/dev/null >"$OP_DIR/identity" || return 1
  _op_hash "$OP_DIR/identity" || return 1
  OP_GEN=$OP_HASH
}

# op_publish — the admitted answer's records after its header and hello,
# appended whole: 2 before anything is appended, 1 an append that failed.
op_publish() {
  local bytes records
  tail -n +3 "$OMB_TMP/journey.admitted" 2>/dev/null >"$OMB_TMP/operation.suffix" || return 2
  bytes=$(wc -c <"$OMB_TMP/operation.suffix") || return 2
  records=$(wc -l <"$OMB_TMP/operation.suffix") || return 2
  # A failed append is an incomplete transport; never append a second result.
  cat "$OMB_TMP/operation.suffix" >>"$CORE_EVENTS" || return 1
  CORE_BYTES=$((CORE_BYTES + bytes)) CORE_RECS=$((CORE_RECS + records)) CORE_RESULT=1
}

# op_failure 1|2 — error io, or error representation: its fixed text, the
# empty generation, no row. The safe answer is itself staged and admitted
# while the machinery allows; otherwise fixed emergency records, which need
# neither the failed data nor a hash tool.
op_failure() {
  local code=io text=$OP_IO_TEXT st
  if [ "$1" = 2 ]; then code=representation text=$OP_REP_TEXT; fi
  if core_read_prefix && : 2>/dev/null >"$OMB_TMP/operation.failure" &&
    core_read_stage "$CORE_OP" "$OP_EMPTY" 0 "$OMB_TMP/operation.failure" error "$code" "$text"; then
    op_publish
    st=$?
    [ "$st" = 2 ] || return "$st"
  fi
  core_emit generation id "$OP_EMPTY" total 0 || return 1
  core_result error "$code" "$text"
}

# core_op_detail — `detail kind=operation` (*The request*): the inspection
# again and its generation recomputed; the whole finding held to the record
# format before any page of it; then the page, or refused changed or invalid
# with the fresh generation and no row, so no answer mixes two inspections.
core_op_detail() {
  local st zero status='done' code=ok text=''
  if ! core_op_dataset "$CORE_REQ_SCOPE"; then
    op_failure 1
    return
  fi
  zero=$(printf '%064d' 0)
  core_read_prefix || { op_failure 1; return; }
  core_read_stage detail "$zero" "$OP_TOTAL" "$OP_DIR/rows"
  st=$?
  case $st in 0) ;; 2) op_failure 2; return ;; *) op_failure 1; return ;; esac
  : 2>/dev/null >"$OP_DIR/page" || { op_failure 1; return; }
  if [ "$CORE_REQ_GENERATION" != "$OP_GEN" ]; then
    status=refused code=changed text="The $CORE_REQ_SCOPE dataset changed; open this detail from a fresh snapshot."
  elif [ "$CORE_REQ_OFFSET" -gt "$OP_TOTAL" ]; then
    status=refused code=invalid text="The offset is beyond this projection's total."
  else
    awk -v offset="$CORE_REQ_OFFSET" -v limit="$CORE_REQ_LIMIT" 'NR > offset && NR <= offset + limit' "$OP_DIR/rows" 2>/dev/null >"$OP_DIR/page" ||
      { op_failure 1; return; }
  fi
  core_read_stage detail "$OP_GEN" "$OP_TOTAL" "$OP_DIR/page" "$status" "$code" "$text"
  st=$?
  case $st in 0) ;; 2) op_failure 2; return ;; *) op_failure 1; return ;; esac
  op_publish
  st=$?
  if [ "$st" = 2 ]; then op_failure 1; else return "$st"; fi
}

# ---------------------------------------------------------------------------
# The text interface: `operation SCOPE`
# ---------------------------------------------------------------------------

# _op_envelope — the fixed header and hello the rows are admitted inside, as
# a response would carry them. Never shown: only the rows are printed.
_op_envelope() {
  local zero
  zero=$(printf '%064d' 0)
  {
    printf 'omb-res 1\n' &&
      rec_line hello core 0.0.0 commit '' source "$zero" proto "$REC_PROTO" platform macos arch arm64 \
        user user ceiling read dry_run 1 fixture 0
  } 2>/dev/null >"$OMB_TMP/journey.prefix"
}

# _op_print FILE — the admitted rows of FILE, decoded, then printed in order:
# each label, its value, and " - " and its text when both are there. 1, with
# nothing printed, when they cannot all be read.
_op_print() {
  local line rest n=0 i=0 __l __v __x
  local -a lab=() val=() txt=()
  while IFS= read -r line; do
    case "$line" in "row	"*) ;; *) continue ;; esac
    # An admitted row: row, kind, key, then exactly three columns, each
    # canonical, so no column holds a TAB.
    rest=${line#*	col=}
    lab[n]=${rest%%	col=*}
    rest=${rest#*	col=}
    val[n]=${rest%%	col=*}
    txt[n]=${rest#*	col=}
    n=$((n + 1))
  done <"$1"
  [ "$n" = "$OP_TOTAL" ] || return 1
  ui_section "Operation record"
  while [ "$i" -lt "$n" ]; do
    _rec_dec_into __l "${lab[i]}" || return 1
    _rec_dec_into __v "${val[i]}" || return 1
    _rec_dec_into __x "${txt[i]}" || return 1
    if [ -n "$__v" ] && [ -n "$__x" ]; then
      ui_kv "$__l" "$__v - $__x"
    elif [ -n "$__v" ]; then
      ui_kv "$__l" "$__v"
    else
      ui_kv "$__l" "$__x"
    fi
    i=$((i + 1))
  done
}

# cmd_operation SCOPE — the inspection and rows the protocol answers with,
# held to the same admission, then printed. 0 a delivered finding, whatever
# it is (none to undetermined: the command succeeded, not the scope); 1
# error io or error representation, with its fixed text and no row.
cmd_operation() {
  local st zero
  core_boot_read
  if ! op_capture "$1"; then
    ui_fail "$OP_IO_TEXT"
    return 1
  fi
  zero=$(printf '%064d' 0)
  if ! _op_envelope; then
    ui_fail "$OP_IO_TEXT"
    return 1
  fi
  core_read_stage detail "$zero" "$OP_TOTAL" "$OP_DIR/rows"
  st=$?
  case $st in
    0) ;;
    2) ui_fail "$OP_REP_TEXT"; return 1 ;;
    *) ui_fail "$OP_IO_TEXT"; return 1 ;;
  esac
  if ! _op_print "$OMB_TMP/journey.admitted"; then
    ui_fail "$OP_IO_TEXT"
    return 1
  fi
}
