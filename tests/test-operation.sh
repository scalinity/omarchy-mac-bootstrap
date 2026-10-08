#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016 # ok/fail always return 0; literal $ in shims and stand-in functions
# The operation-record diagnostic (docs/PROTOCOL.md → *The operation-record
# diagnostic*, D55; docs/TESTING.md → *Gate 3 operation-record diagnostic
# tests*): DIA-01 to DIA-15 through the actual core, as the frontend drives
# it, and through the actual launcher's `operation SCOPE`. Every inspection
# is held to a read: no lock, log, state or scratch is left, and the record
# stays byte for byte. A directory argument also saves the foundation
# answers, for the released and the candidate frontend's own code
# (frontend/tests/proto_diff.rs).
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
T=$(t_tmp)
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
save=${1:-}
if [ -n "$save" ]; then : >"$save/cases"; fi

OPS=$T/state/ops/journey.omb
BOOT=$(cat "$FIX/mac-m1pro-1tb-roomy/cmd/bootsession")
ROOT=0
[ "$(id -u)" = 0 ] && ROOT=1
EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855

# --- The contract's words ---------------------------------------------------------------
TX_NONE='No operation in this scope is recorded as begun and not settled.'
TX_READABLE='The operation record of this scope can be read.'
TX_UNREADABLE='A record exists in this scope and cannot be read, so nothing it says is known.'
TX_UNDET='Whether a record exists in this scope, or what it says, could not be established.'
ST_LOOKUP='Whether the record exists could not be established: the state directory or its ops folder is a link, is not a folder of yours, or cannot be searched or listed.'
ST_STATUS="The record's status could not be read."
ST_READ="The record's bytes could not be read in full."
ST_CHECK="A check of the record's bytes could not run to its end."
W_ACTIVE='The core that recorded it is running now.'
W_LIVE='Whether the core that recorded it is running could not be established; it counts as running.'
W_UNSUP='Its core no longer supervises it; a process it started may still be running.'
W_FAILED="It ended under its core's supervision, with no worker left, as recorded."
W_EARLIER='It was recorded in an earlier boot; no process of that boot still runs.'
W_UNREADABLE='Nothing ties a running process to this record, so whether one it started still runs is unknown.'
W_UNDET='Unknown while the record cannot be inspected.'
E_READABLE='Not judged: this check reconciles nothing.'
E_UNREADABLE='Unknown: what the operation changed cannot be judged without the record.'
E_UNDET='Unknown while the record cannot be inspected.'
U_NONE='Whether any action ran here before, and what it changed: a settled or removed record leaves nothing behind.'
U_READABLE='What the machine holds now: this check reconciles nothing.'
U_UNREADABLE='Everything the record says: its action, session, process, boot and state, whether it ended, and what it changed.'
U_UNDET='Whether a record exists here, and anything it says.'
N_NONE='None for this record. This alone allows nothing: every action still makes its own fresh checks.'
N_ALIVE='Wait for it to finish, then check again.'
N_LIVE='Wait, then check again. If whether its core runs stays unknown, restart this Mac (or this Linux system), then run the tool again.'
N_RESTART='Restart this Mac (or this Linux system), then run the tool again.'
N_EARLIER='Run the tool again, not as a dry run: it reconciles this scope from what the machine holds before any action in it.'
N_UNREADABLE='Nothing in this scope can run while this record is there, and a restart does not change that. This tool offers no way to clear it yet. You may look at the file with your own tools; this tool never shows its bytes.'
N_LOOKUP='Make the state directory and its ops folder real folders of yours that you can open and list, then check again. This tool changes no permission and moves nothing.'
N_STATUS="Make the record's status readable, then check again. This tool changes no permission and moves nothing."
N_READ='Make the record readable in full, then check again. This tool changes no permission and moves nothing.'
N_CHECK='Make sure the standard tools a check runs can run, then check again.'
FP_TEXT='SHA-256 of all its bytes, for comparing inspections only'
FP_NONE='none: it is larger than 65536 bytes, so it is not read in full'
FP_UNKNOWN='unknown: its bytes could not be read in full'
B_UNREADABLE='unreadable|The operation record of this scope exists and cannot be read, so what it recorded is unknown; a restart does not change that.|Nothing in this scope runs while it is there. Its operation record check shows what can be established.'
B_UNDET='undetermined|The operation record of this scope could not be inspected, so whether one exists is unknown.|Nothing in this scope runs until it can be inspected. Its operation record check names the step that failed.'
B_UNSUP='unsupervised|The outcome of test.mutate is unknown and a process it started may still be running.|Restart this Mac (or this Linux system), then run the tool again.'
B_FIX_FAILED='Restart this Mac (or this Linux system), then run the tool again: the scope is reconciled from what the machine then holds.'
IO_TEXT='The operation record response could not be prepared.'
REP_TEXT='The required operation record response cannot be represented in Protocol 1.'
USAGE='omarchy-bootstrap: operation takes one scope: journey, disk, plan, profile, resolve, asahi, network, omarchy, shared, export, restore, rescue, qualify, debug, health, logs (see --help)'

# reason WORD — the text of a `reason` row.
reason() {
  case $1 in
    kind) echo 'it is not a plain file' ;;
    owner) echo 'it belongs to another user' ;;
    writable) echo 'group or others may write it' ;;
    too-large) echo 'it is larger than 65536 bytes' ;;
    byte) echo 'it holds a byte no record may hold' ;;
    eof) echo 'it does not end with a line end' ;;
    seal) echo 'its seal does not match its bytes' ;;
    line | blank | tab | header | key | value | nul-escape | non-canonical) echo 'it breaks the record format' ;;
    schema) echo "its records are not an operation record's" ;;
    type) echo 'a value breaks its type' ;;
    other-scope) echo 'it names another scope' ;;
    other-action) echo 'it names an action this scope does not have' ;;
  esac
}

# --- Reading the answers -----------------------------------------------------------------
# o_dec — each line of stdin with its %XX escapes decoded (a written value
# holds no raw backslash: it is not a safe byte).
o_dec() {
  local line
  while IFS= read -r line; do
    printf '%b\n' "$(printf '%s' "$line" | sed 's/%\([0-9A-F][0-9A-F]\)/\\x\1/g')"
  done
}
# o_rows — the last answer's operation rows, KEY|LABEL|VALUE|TEXT, decoded.
o_rows() {
  awk -F '\t' '$1 == "row" { k = $3; sub(/^key=/, "", k); l = $4; sub(/^col=/, "", l); v = $5; sub(/^col=/, "", v); t = $6; sub(/^col=/, "", t); print k "|" l "|" v "|" t "|" $2 "|" NF }' "$C_EV" |
    awk -F '|' '$5 != "kind=operation" || $6 != 6 { print "BAD ROW: " $0; next } { print $1 "|" $2 "|" $3 "|" $4 }' | o_dec
}
# o_fact SPOOL — the operation fact, VALUE|STATE (and its scope and label).
o_fact() {
  awk -F '\t' '$1 == "fact" && $3 == "key=operation" { v = $5; sub(/^value=/, "", v); s = $6; sub(/^state=/, "", s); print v "|" s "|" $2 "|" $4 }' "$1" |
    o_dec | sed 's/|scope=journey|label=Operation$//'
}
# o_blockers SPOOL — ID|TEXT|FIX, one per blocker.
o_blockers() {
  awk -F '\t' '$1 == "blocker" { i = $2; sub(/^id=/, "", i); t = $3; sub(/^text=/, "", t); f = $4; sub(/^fix=/, "", f); print i "|" t "|" f }' "$1" | o_dec
}
o_acts() { awk -F '\t' '$1 == "action" { sub(/^id=/, "", $2); printf "%s ", $2 }' "$1"; }
o_gen() { awk -F '\t' '$1 == "generation" { sub(/^id=/, "", $2); print $2 }' "$1"; }
o_total() { awk -F '\t' '$1 == "generation" { sub(/^total=/, "", $3); print $3 }' "$1"; }
# o_res SPOOL — STATUS CODE|TEXT of the result, decoded.
o_res() {
  awk -F '\t' '$1 == "result" { s = $2; sub(/^status=/, "", s); c = $3; sub(/^code=/, "", c); t = $4; sub(/^text=/, "", t); print s " " c "|" t }' "$1" | o_dec
}
o_nrows() { grep -c '^row	' "$1"; }
o_hash() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{ print $1 }'; else sha256sum "$1" | awk '{ print $1 }'; fi
}
o_size() { wc -c <"$1" | tr -d ' '; }

# --- Asking ------------------------------------------------------------------------------
# o_look — a foundation journey snapshot (O_SNAP, its spool), then the
# operation detail from its generation, the whole finding (C_EV).
o_look() {
  c_run snapshot "scope	name=journey"
  O_SNAP=$T/snap-$C_N
  cp "$C_EV" "$O_SNAP"
  O_GEN=$(o_gen "$O_SNAP")
  o_detail 0 20 "$O_GEN"
}
# o_detail OFFSET LIMIT GENERATION — the operation detail.
o_detail() { c_run detail "page	scope=journey	kind=operation	generation=$3	offset=$1	limit=$2"; }
# o_save NAME — keep the last snapshot and detail for the frontends' own code.
o_save() {
  [ -n "$save" ] || return 0
  cp "$O_SNAP" "$save/$1.snapshot.doc" && printf '%s snapshot\n' "$1.snapshot" >>"$save/cases"
  cp "$C_EV" "$save/$1.detail.doc" && printf '%s detail\n' "$1.detail" >>"$save/cases"
}

# o_rec STATE PID START BOOT [ACTION] [SCOPE] [FINDING] — the scope's
# operation record, sealed, as a core writes it.
o_rec() (
  t_load >/dev/null 2>&1
  # shellcheck source=lib/records.sh
  . "$REPO/lib/records.sh"
  mkdir -p "$T/state/ops"
  {
    printf 'omb-op 1\n'
    rec_line op action "${5:-test.mutate}" scope "${6:-journey}" basis "$(printf '%064d' 7)" session "$SESS" state "$1" \
      finding "${7:-}" pid "$2" start "$3" boot "$4" at 2026-09-26T00:00:00Z
  } >"$OPS"
  rec_seal_write "$OPS"
  omb_cleanup
)
# o_raw — the record's bytes from stdin, as a hand edit or a torn write leaves them.
o_raw() { mkdir -p "$T/state/ops" && cat >"$OPS"; }

# o_shim DIR NAME GLOB ACTION — DIR/NAME runs the real NAME, except for an
# invocation whose arguments, joined by spaces, match the sh glob GLOB:
# that one fails (fail), answers nothing (none), prints the first 10 bytes
# of its last argument (short), runs and keeps only the first 10 bytes of
# its output (trunc), or runs and then empties its last argument, a file
# (nosize). A tool this system lacks gets no shim.
o_shim() {
  local real="" d act
  for d in /usr/bin /bin /usr/sbin /sbin; do
    if [ -x "$d/$2" ]; then real=$d/$2 && break; fi
  done
  [ -n "$real" ] || return 0
  mkdir -p "$1"
  case $4 in
    fail) act='exit 1' ;;
    none) act='exit 0' ;;
    short) act="eval \"last=\\\${\$#}\"; \"$real\" -c 10 \"\$last\"; exit 0" ;;
    trunc) act="\"$real\" \"\$@\" | head -c 10; exit 0" ;;
    nosize) act="\"$real\" \"\$@\"; st=\$?; eval \"last=\\\${\$#}\"; : >\"\$last\"; exit \$st" ;;
  esac
  printf '#!/bin/sh\ncase " $* " in\n  %s) %s ;;\nesac\nexec "%s" "$@"\n' "$3" "$act" "$real" >"$1/$2"
  chmod +x "$1/$2"
}
SHIMS=$T/shims
SN=0
# o_tool NAME GLOB ACTION — a fresh shim folder with that one shim: O_PATH.
o_tool() {
  SN=$((SN + 1))
  o_shim "$SHIMS/$SN" "$@"
  O_PATH="$SHIMS/$SN:/usr/bin:/bin:/usr/sbin:/sbin"
}
R_ARG='*"/ops/journey.omb "*'
COPY_ARG='*"/operation/record "*'
# The read of the record itself, the one tool that opens it (OP_PL).
P_READ='*" -- read "*"/ops/journey.omb "*'

# o_text ARG... — the launcher's text interface as a person runs it: O_RC,
# O_OUT (stdout), O_ERR (stderr). Fixture mode unless O_PROD=1; O_STATE,
# O_HOME (another checkout), O_PATH and O_BASH as for the core.
o_text() {
  local -a env=("PATH=${O_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" "HOME=$T/home" "TMPDIR=$T/text-tmp" "LANG=en_US.UTF-8" "TERM=dumb"
    "OMB_STATE_DIR=${O_STATE:-$T/state}")
  [ "${O_PROD:-0}" = 1 ] || env+=("OMB_FIXTURE=$C_FIX")
  mkdir -p "$T/text-tmp"
  env -i "${env[@]}" "${O_BASH:-$T_BASH}" "${O_HOME:-$REPO}/omarchy-bootstrap" "$@" >"$T/text.out" 2>"$T/text.err" </dev/null
  O_RC=$?
  O_OUT=$(cat "$T/text.out")
  O_ERR=$(cat "$T/text.err")
}
# o_render ROWS — the text interface's lines for ROWS (KEY|LABEL|VALUE|TEXT),
# with --ascii: the heading, then each label, its value and " - " and its text.
o_render() {
  local k l v x
  printf '\n | Operation record\n'
  while IFS='|' read -r k l v x; do
    if [ -n "$v" ] && [ -n "$x" ]; then
      printf '   %-19s %s - %s\n' "$l" "$v" "$x"
    elif [ -n "$v" ]; then
      printf '   %-19s %s\n' "$l" "$v"
    else
      printf '   %-19s %s\n' "$l" "$x"
    fi
  done <<EOF
$1
EOF
}

# --- Purity ------------------------------------------------------------------------------
# o_before — what a read must leave as it is; o_pure NAME — and did.
o_before() {
  O_B_STATE=$(t_snapshot "$T/state" 2>/dev/null)
  O_B_HOME=$(t_snapshot "$T/home" 2>/dev/null)
  rm -f "$T/rec.before"
  if [ -f "$OPS" ] && [ ! -L "$OPS" ]; then cp "$OPS" "$T/rec.before"; fi
}
o_pure() {
  assert_eq "$(t_snapshot "$T/state" 2>/dev/null)" "$O_B_STATE" "$1: the state folder is as it was (no lock, log, state or record written)"
  assert_eq "$(t_snapshot "$T/home" 2>/dev/null)" "$O_B_HOME" "$1: HOME is as it was"
  if [ -f "$T/rec.before" ]; then
    cmp -s "$T/rec.before" "$OPS" && ok || fail "$1: the record is unchanged, byte for byte"
  fi
  assert_eq "$(find "$T" "$T/text-tmp" -maxdepth 1 -name 'omarchy-bootstrap.*' 2>/dev/null)" '' "$1: no scratch is left"
}

# o_rowset NAME WANT — the detail's whole finding, in order, admitted.
o_rowset() {
  assert_eq "$(c_result) $C_RC" 'done ok 0' "$1: the detail is done"
  assert_eq "$(c_admits detail)" ok "$1: the detail is a whole, admitted answer"
  assert_eq "$(o_rows)" "$2" "$1: the rows, in order"
  assert_eq "$(o_total "$C_EV")" "$(printf '%s\n' "$2" | grep -c .)" "$1: total is the finding's row count"
  assert_eq "$(o_gen "$C_EV")" "$O_GEN" "$1: the detail answers from the snapshot's generation"
}
# o_snapset NAME FACT BLOCKERS ACTIONS — the snapshot's barrier.
o_snapset() {
  assert_eq "$(c_admits_file snapshot "$O_SNAP")" ok "$1: the snapshot is a whole, admitted answer"
  assert_eq "$(o_fact "$O_SNAP")" "$2" "$1: the operation fact"
  assert_eq "$(o_blockers "$O_SNAP")" "$3" "$1: the blockers"
  assert_eq "$(o_acts "$O_SNAP")" "$4" "$1: the actions listed"
  assert_eq "$(o_nrows "$O_SNAP")" 0 "$1: the snapshot carries no row"
  assert_not_contains "$(cat "$O_SNAP")" "ops/journey.omb" "$1: nor the record's path"
}
c_admits_file() {
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    if rec_admit_file res "$1" "$2"; then printf ok; else printf '%s:%s' "$REC_REASON" "$REC_AT"; fi
    omb_cleanup
  )
}
# o_texts NAME ROWS — the text interface's answer is the same finding.
o_texts() {
  o_before
  o_text --ascii operation journey
  assert_eq "$O_RC" 0 "$1 (text): a delivered finding exits 0"
  assert_eq "$O_OUT" "$(o_render "$2")" "$1 (text): the finding, line by line"
  assert_eq "$O_ERR" '' "$1 (text): nothing on stderr"
  o_pure "$1 (text)"
}

# o_head STATE TEXT [PATH] — the rows every finding begins with.
o_head() { printf 'scope|Scope|journey|\npath|Record|%s|\nstate|State|%s|%s' "${3:-$OPS}" "$1" "$2"; }

c_session
c_fixture
mkdir -p "$T/home"
ALL='test.read test.mutate test.handoff '
NONE_ROWS="$(o_head none "$TX_NONE")
unknown|Still unknown||$U_NONE
next|Next||$N_NONE"

# === DIA-01 none =========================================================================
# A lookup that could have seen an entry and found none: no state folder
# under a folder this process can search, a state folder without ops, ops
# without the record.
for where in 'no state folder' 'no ops folder' 'no record'; do
  case $where in
    'no state folder') rm -rf "$T/state" ;;
    'no ops folder') mkdir -p "$T/state" ;;
    'no record') mkdir -p "$T/state/ops" ;;
  esac
  o_before
  o_look
  o_rowset "DIA-01 none ($where)" "$NONE_ROWS"
  o_snapset "DIA-01 none ($where)" 'none recorded|ok' '' "$ALL"
  o_pure "DIA-01 none ($where)"
done
o_save none
o_texts 'DIA-01 none' "$NONE_ROWS"
# The deterministic text, as a person reads it (docs/PROTOCOL.md → *The text interface*).
assert_eq "$O_OUT" "$(printf '\n | Operation record\n   Scope               journey\n   Record              %s\n   State               none - %s\n   Still unknown       %s\n   Next                %s' "$OPS" "$TX_NONE" "$U_NONE" "$N_NONE")" \
  'DIA-01 none (text): the exact lines'
o_text operation journey
assert_eq "$(printf '%s\n' "$O_OUT" | sed 1,2d)" "$(o_render "$NONE_ROWS" | sed 1,2d)" 'DIA-01 none (text): without --ascii only the heading glyph may differ'
o_text --no-color --ascii --dry-run operation journey
assert_eq "$O_OUT" "$(o_render "$NONE_ROWS")" 'DIA-01 none (text): --dry-run and --no-color change nothing'

# === DIA-02 readable, its core alive =====================================================
LIVE_START=$(t_started $$)
o_rec running $$ "$LIVE_START" "$BOOT"
READ_HEAD="$(o_head readable "$TX_READABLE")
recorded.action|Recorded action|test.mutate|"
ALIVE_ROWS="$READ_HEAD
recorded.state|Recorded state|running|recorded as running
boot|Recorded boot|this|this boot
worker|Workers|active|$W_ACTIVE
effect|Effect|unknown|$E_READABLE
unknown|Still unknown||$U_READABLE
next|Next||$N_ALIVE"
o_before
o_look
o_rowset 'DIA-02 readable, supervised' "$ALIVE_ROWS"
o_snapset 'DIA-02 readable, supervised' 'test.mutate running|info' '' 'test.read '
o_pure 'DIA-02 readable, supervised'
o_save readable-alive
o_texts 'DIA-02 readable, supervised' "$ALIVE_ROWS"

# === DIA-03 / DIA-11(a) readable, liveness unknown =======================================
LIVE_ROWS="$READ_HEAD
recorded.state|Recorded state|running|recorded as running
boot|Recorded boot|this|this boot
worker|Workers|unknown|$W_LIVE
effect|Effect|unknown|$E_READABLE
unknown|Still unknown||$U_READABLE
next|Next||$N_LIVE"
o_tool ps '*' fail
C_PATH=$O_PATH o_look
o_rowset 'DIA-03 readable, ps cannot be read' "$LIVE_ROWS"
o_snapset 'DIA-03 readable, ps cannot be read' 'test.mutate recorded as running; whether its core runs is unknown|warn' '' 'test.read '
o_save readable-unknown
o_texts 'DIA-11(a) readable, ps cannot be read' "$LIVE_ROWS"
O_PATH=''
mv "$C_FIX/cmd/bootsession" "$C_FIX/cmd/bootsession.gone"
o_look
o_rowset 'DIA-03 readable, this boot not identified' "$(printf '%s\n' "$LIVE_ROWS" | sed 's/^boot|Recorded boot|this|this boot$/boot|Recorded boot|unknown|this boot could not be identified/')"
o_snapset 'DIA-03 readable, this boot not identified' 'test.mutate recorded as running; whether its core runs is unknown|warn' '' 'test.read '
mv "$C_FIX/cmd/bootsession.gone" "$C_FIX/cmd/bootsession"

# === DIA-10(a) readable, the PID held by another process, and the other readable branches ===
UNSUP_TAIL="boot|Recorded boot|this|this boot
worker|Workers|unknown|$W_UNSUP
effect|Effect|unknown|$E_READABLE
unknown|Still unknown||$U_READABLE
next|Next||$N_RESTART"
o_rec running $$ 'Mon Jan  1 00:00:00 2001' "$BOOT"
o_before
o_look
o_rowset 'DIA-10(a) a confirmed mismatch' "$READ_HEAD
recorded.state|Recorded state|running|recorded as running
$UNSUP_TAIL"
o_snapset 'DIA-10(a) a confirmed mismatch' 'test.mutate unsupervised|fail' "$B_UNSUP" 'test.read '
o_pure 'DIA-10(a) a confirmed mismatch'
o_rec unsupervised $$ "$LIVE_START" "$BOOT"
o_look
o_rowset 'readable, recorded unsupervised' "$READ_HEAD
recorded.state|Recorded state|unsupervised|recorded as unsupervised
$UNSUP_TAIL"
o_snapset 'readable, recorded unsupervised' 'test.mutate unsupervised|fail' "$B_UNSUP" 'test.read '
o_save readable-unsupervised
for finding in absent unexpected; do
  o_rec failed $$ "$LIVE_START" "$BOOT" test.mutate journey "$finding"
  shows='it shows no effect'
  [ "$finding" = unexpected ] && shows='it shows something else'
  ftext='When it ended, the machine still showed its old state.'
  [ "$finding" = unexpected ] && ftext='When it ended, the machine showed something other than its old state or its effect.'
  o_look
  o_rowset "readable, failed ($finding)" "$READ_HEAD
recorded.state|Recorded state|failed|recorded as ended without its expected effect
recorded.finding|Recorded finding|$finding|$ftext
boot|Recorded boot|this|this boot
worker|Workers|ended|$W_FAILED
effect|Effect|unknown|$E_READABLE
unknown|Still unknown||$U_READABLE
next|Next||$N_RESTART"
  o_snapset "readable, failed ($finding)" 'test.mutate ended without its expected effect|fail' \
    "unresolved|test.mutate ended, but the machine does not show its expected effect: $shows.|$B_FIX_FAILED" 'test.read '
done
o_save readable-failed
o_rec running $$ "$LIVE_START" 5E1D0B00-7A3C-4F21-9D6E-00000000EA21
EARLIER_ROWS="$READ_HEAD
recorded.state|Recorded state|running|recorded as running
boot|Recorded boot|earlier|an earlier boot
worker|Workers|ended|$W_EARLIER
effect|Effect|unknown|$E_READABLE
unknown|Still unknown||$U_READABLE
next|Next||$N_EARLIER"
o_look
o_rowset 'readable, an earlier boot' "$EARLIER_ROWS"
o_snapset 'readable, an earlier boot' 'test.mutate from an earlier boot, to reconcile|warn' '' "$ALL"
o_save readable-earlier
o_texts 'readable, an earlier boot' "$EARLIER_ROWS"

# === DIA-04 unreadable, established ======================================================
# unr_rows SIZE FINGERPRINT FPTEXT REASON [LINE] — a plain file of yours, not
# writable by others, that a completed check refused.
unr_rows() {
  printf '%s\nkind|Entry|file|a plain file\nowner|Owner|this-user|you\nwritable|Writable by others|no|only its owner may write it\nsize|Size|%s|\nfingerprint|Fingerprint|%s|%s\nreason|Refused by|%s|%s\n' \
    "$(o_head unreadable "$TX_UNREADABLE")" "$1" "$2" "$3" "$4" "$(reason "$4")"
  [ -z "${5:-}" ] || printf 'line|At line|%s|\n' "$5"
  printf 'worker|Workers|unknown|%s\neffect|Effect|unknown|%s\nunknown|Still unknown||%s\nnext|Next||%s' "$W_UNREADABLE" "$E_UNREADABLE" "$U_UNREADABLE" "$N_UNREADABLE"
}
# unr NAME REASON [LINE] — the record now in place, refused with REASON.
unr() {
  local rows
  rows=$(unr_rows "$(o_size "$OPS")" "$(o_hash "$OPS")" "$FP_TEXT" "$2" "${3:-}")
  o_before
  o_look
  o_rowset "DIA-04 unreadable ($1)" "$rows"
  o_snapset "DIA-04 unreadable ($1)" 'a record that cannot be read|fail' "$B_UNREADABLE" 'test.read '
  o_pure "DIA-04 unreadable ($1)"
  O_ROWS=$rows
}
printf 'omb-op 1\ntorn' | o_raw
unr 'torn: eof' eof
o_save unreadable
TORN_ROWS=$O_ROWS
o_texts 'DIA-04 unreadable (torn)' "$TORN_ROWS"
assert_eq "$(printf '%s\n' "$O_OUT" | sed -n 10p)" "   Fingerprint         $(o_hash "$OPS") - $FP_TEXT" 'DIA-04 (text): the fingerprint line, exactly'
: | o_raw
unr 'empty' eof
printf 'omb-op 1\n\302\240\n' | o_raw
unr 'a byte no record holds' byte
printf 'omb-op 2\n' | o_raw
unr 'another header' header 1
printf 'omb-op 1\n# a comment\n' | o_raw
unr 'a line with no record type' key 2
printf 'omb-op 1\nop\taction=a b\n' | o_raw
unr 'a value with a space' value 2
printf 'omb-op 1\nop\taction=test.mutate\n' | o_raw
unr 'no seal' seal
o_rec running $$ "$LIVE_START" "$BOOT"
sed 's/state=running/state=failed/' "$OPS" >"$T/edited" && o_raw <"$T/edited"
unr 'a hand edit under its seal' seal
o_rec running x "$LIVE_START" "$BOOT"
unr 'a PID that is not a number' type 2
o_rec running $$ "$LIVE_START" "$BOOT" test.mutate shared
unr 'another scope' other-scope
o_rec running $$ "$LIVE_START" "$BOOT" plan.save
unr 'an action of another scope' other-action
# An action of this scope that is merely not available is no corruption.
o_rec running $$ "$LIVE_START" "$BOOT" test.read
o_look
assert_eq "$(o_rows | sed -n 3,4p)" "state|State|readable|$TX_READABLE
recorded.action|Recorded action|test.read|" 'UR-Q9: an action this scope owns, available or not, is readable'
# Proc-shaped records under the op header: no operation record's.
(
  t_load >/dev/null 2>&1
  # shellcheck source=lib/records.sh
  . "$REPO/lib/records.sh"
  { printf 'omb-op 1\n' && rec_line proc role core pid 1 start x boot y; } >"$OPS"
  rec_seal_write "$OPS"
  omb_cleanup
)
unr 'another kind of record' schema 2
# The stored-document ceiling: 65536 bytes are read in full; one more is not read.
{ printf 'omb-op 1\n'; head -c 65526 /dev/zero | tr '\0' x; printf '\n'; } | o_raw
assert_eq "$(o_size "$OPS")" 65536 'the ceiling case holds exactly 65536 bytes'
unr 'exactly the ceiling' line 2
{ printf 'omb-op 1\n'; head -c 65527 /dev/zero | tr '\0' x; printf '\n'; } | o_raw
TOO=$(unr_rows 65537 none "$FP_NONE" too-large)
o_before
o_look
o_rowset 'DIA-04 unreadable (one byte over the ceiling)' "$TOO"
o_pure 'DIA-04 unreadable (one byte over the ceiling)'

# --- Status: what the entry is, never followed or opened -----------------------------------
# st_rows KIND OWNER [WRITABLE] — an entry its status refused (no size, no fingerprint).
st_rows() {
  local o_text='you'
  printf '%s\nkind|Entry|%s|' "$(o_head unreadable "$TX_UNREADABLE")" "$1"
  case $1 in
    link) printf 'a symbolic link, never followed' ;;
    folder) printf 'a folder, never opened' ;;
    other) printf 'not a plain file, never opened' ;;
  esac
  printf '\nowner|Owner|%s|%s\n' "$2" "$o_text"
  [ -z "${3:-}" ] || printf 'writable|Writable by others|%s|only its owner may write it\n' "$3"
  printf 'reason|Refused by|kind|%s\nworker|Workers|unknown|%s\neffect|Effect|unknown|%s\nunknown|Still unknown||%s\nnext|Next||%s' \
    "$(reason kind)" "$W_UNREADABLE" "$E_UNREADABLE" "$U_UNREADABLE" "$N_UNREADABLE"
}
rm -f "$OPS"
printf 'omb-op 1\n' >"$T/target"
ln -s "$T/target" "$OPS"
o_before
o_look
o_rowset 'a link to a file' "$(st_rows link this-user)"
o_snapset 'a link to a file' 'a record that cannot be read|fail' "$B_UNREADABLE" 'test.read '
o_pure 'a link to a file'
rm -f "$OPS"
ln -s "$T/nowhere" "$OPS"
o_before
o_look
o_rowset 'a dangling link' "$(st_rows link this-user)"
[ ! -e "$T/nowhere" ] && ok || fail 'a dangling link is never followed into a write'
rm -f "$OPS"
mkdir "$OPS"
o_before
o_look
o_rowset 'a folder' "$(st_rows folder this-user no)"
rmdir "$OPS"
mkfifo "$OPS"
o_before
o_look
o_rowset 'a FIFO, never opened' "$(st_rows other this-user no)"
o_pure 'a FIFO, never opened'
rm -f "$OPS"
printf 'omb-op 1\ntorn' | o_raw
chmod 620 "$OPS"
WR=$(o_head unreadable "$TX_UNREADABLE")"
kind|Entry|file|a plain file
owner|Owner|this-user|you
writable|Writable by others|yes|group or others may write it
size|Size|$(o_size "$OPS")|
fingerprint|Fingerprint|$(o_hash "$OPS")|$FP_TEXT
reason|Refused by|writable|$(reason writable)
worker|Workers|unknown|$W_UNREADABLE
effect|Effect|unknown|$E_UNREADABLE
unknown|Still unknown||$U_UNREADABLE
next|Next||$N_UNREADABLE"
o_before
o_look
o_rowset 'writable by group' "$WR"
o_pure 'writable by group'
# The bytes cannot be read of a file its status already refused: its
# fingerprint is unknown and the state stands.
o_tool perl "$P_READ" fail
C_PATH=$O_PATH o_look
o_rowset 'writable by group, its size unread' "$(printf '%s\n' "$WR" | sed -e '/^size|/d' -e "s/^fingerprint|Fingerprint|[0-9a-f]*|.*/fingerprint|Fingerprint|unknown|$FP_UNKNOWN/")"
chmod 600 "$OPS"
# Another user's file, as find reports it (a test cannot give one away).
o_tool find '*"/ops/journey.omb -maxdepth 0 -user "*' none
C_PATH=$O_PATH o_look
o_rowset "another user's" "$(printf '%s\n' "$TORN_ROWS" | sed -e 's/^owner|Owner|this-user|you$/owner|Owner|other-user|another user/' -e "s/^reason|Refused by|eof|.*/reason|Refused by|owner|$(reason owner)/")"

# === DIA-05 undetermined at lookup =======================================================
LOOKUP_TAIL="stage|Failed step|lookup|$ST_LOOKUP
worker|Workers|unknown|$W_UNDET
effect|Effect|unknown|$E_UNDET
unknown|Still unknown||$U_UNDET
next|Next||$N_LOOKUP"
LOOKUP_ROWS="$(o_head undetermined "$TX_UNDET")
$LOOKUP_TAIL"
# lookup NAME — the record's existence cannot be established.
lookup() {
  o_look
  o_rowset "DIA-05 lookup ($1)" "$LOOKUP_ROWS"
  o_snapset "DIA-05 lookup ($1)" 'cannot be inspected|unknown' "$B_UNDET" 'test.read '
}
printf 'omb-op 1\ntorn' | o_raw
mv "$T/state/ops" "$T/real-ops"
ln -s "$T/real-ops" "$T/state/ops"
o_before
lookup 'ops is a link'
o_pure 'DIA-05 lookup (ops is a link)'
o_save undetermined
o_texts 'DIA-05 lookup (ops is a link)' "$LOOKUP_ROWS"
rm "$T/state/ops"
mv "$T/real-ops" "$T/state/ops"
mv "$T/state" "$T/real-state"
ln -s "$T/real-state" "$T/state"
lookup 'the state folder is a link'
rm "$T/state"
printf 'not a folder\n' >"$T/state"
lookup 'the state folder is a file'
rm "$T/state"
mv "$T/real-state" "$T/state"
if [ "$ROOT" = 0 ]; then
  chmod 600 "$T/state/ops"
  lookup 'ops cannot be searched'
  chmod 300 "$T/state/ops"
  lookup 'ops cannot be listed'
  chmod 700 "$T/state/ops"
  chmod 600 "$T/state"
  lookup 'the state folder cannot be searched'
  chmod 700 "$T/state"
  mkdir -p "$T/locked"
  chmod 000 "$T/locked"
  C_STATE=$T/locked/a/state o_look
  o_rowset 'DIA-05 lookup (no state folder, under one that cannot be searched)' "$(o_head undetermined "$TX_UNDET" "$T/locked/a/state/ops/journey.omb")
$LOOKUP_TAIL"
  assert_eq "$(o_blockers "$O_SNAP")" "$B_UNDET" 'DIA-05: a failed lookup is never none'
  O_STATE=$T/locked/a/state o_text --ascii operation journey
  assert_eq "$O_RC $(printf '%s\n' "$O_OUT" | sed -n 6p)" "0    Failed step         lookup - $ST_LOOKUP" 'DIA-05 (text): the step that failed'
  chmod 700 "$T/locked"
  [ ! -e "$T/locked/a" ] && ok || fail 'DIA-05: nothing is created under it'
else
  skip 'DIA-05 permission cases: root searches every folder'
fi

# === DIA-06 undetermined at status, read or check ========================================
ENTRY="kind|Entry|file|a plain file
owner|Owner|this-user|you
writable|Writable by others|no|only its owner may write it"
UNDET_TAIL="worker|Workers|unknown|$W_UNDET
effect|Effect|unknown|$E_UNDET
unknown|Still unknown||$U_UNDET"
# undet NAME STAGE STAGETEXT NEXT [ENTRY ROWS] — a step that could not complete.
undet() {
  local rows
  rows="$(o_head undetermined "$TX_UNDET")
stage|Failed step|$2|$3"
  [ -z "${5:-}" ] || rows="$rows
$5"
  rows="$rows
$UNDET_TAIL
next|Next||$4"
  o_before
  C_PATH=$O_PATH o_look
  o_rowset "$1" "$rows"
  C_PATH=$O_PATH c_run snapshot "scope	name=journey"
  assert_eq "$(o_fact "$C_EV")|$(o_blockers "$C_EV")" "cannot be inspected|unknown|$B_UNDET" "$1: the barrier holds"
  o_pure "$1"
  U_ROWS=$rows
}
printf 'omb-op 1\ntorn' | o_raw
SIZE=$(o_size "$OPS")
o_tool find '*"/ops/journey.omb -maxdepth 0 "*' fail
undet 'DIA-06(a) the status cannot be read' status "$ST_STATUS" "$N_STATUS"
O_PATH=$O_PATH o_texts 'DIA-06(a) the status cannot be read' "$U_ROWS"
undet 'DIA-07(b) the ownership check cannot run (a lossy owner check)' status "$ST_STATUS" "$N_STATUS"
o_tool perl '*" -- id "*"/ops/journey.omb "*' fail
undet "DIA-06(a) the entry's identity cannot be read" status "$ST_STATUS" "$N_STATUS"
o_tool perl "$P_READ" nosize
undet 'DIA-06(b) the size cannot be read' read "$ST_READ" "$N_READ" "$ENTRY"
o_tool perl "$P_READ" fail
undet 'DIA-06(b) the read fails' read "$ST_READ" "$N_READ" "$ENTRY"
o_tool perl "$P_READ" trunc
undet 'DIA-06(b) the copy is shorter than the size read' read "$ST_READ" "$N_READ" "$ENTRY
size|Size|$SIZE|"
# A record that ends with a line end reaches the format's awk pass (a torn
# one is refused, eof, before it runs).
o_rec running $$ "$LIVE_START" "$BOOT"
SIZE=$(o_size "$OPS")
o_tool awk "$COPY_ARG" fail
undet "DIA-06(c) a check's tool fails" check "$ST_CHECK" "$N_CHECK" "$ENTRY
size|Size|$SIZE|"
# DIA-07(a): the seal's own tools fail, where today's helper answers `seal`.
o_tool tail "*\"-n 1 \"$COPY_ARG" fail
undet 'DIA-07(a) the seal check cannot read its last line' check "$ST_CHECK" "$N_CHECK" "$ENTRY
size|Size|$SIZE|"
assert_not_contains "$(cat "$C_EV")" 'seal' 'DIA-07(a): no reason seal'
o_tool awk "*seal*$COPY_ARG" fail
undet 'DIA-07(a) the seal check cannot count its seals' check "$ST_CHECK" "$N_CHECK" "$ENTRY
size|Size|$SIZE|"
O_PATH=''

# === DIA-08 the machinery fails ==========================================================
# io NAME — the diagnostic's own failure: error io, the empty generation, no row.
io() {
  o_before
  C_BASH=${F_BASH:-} C_PATH=$O_PATH c_run snapshot "scope	name=journey"
  assert_eq "$(o_res "$C_EV") $(o_gen "$C_EV") $(o_total "$C_EV") $(c_admits snapshot)" "error io|$IO_TEXT $EMPTY 0 ok" "$1: the snapshot is error io"
  assert_eq "$(grep -cE '^(fact|blocker|action|row)	' "$C_EV")" 0 "$1: with no fact, blocker, action or row"
  C_BASH=${F_BASH:-} C_PATH=$O_PATH o_detail 0 20 "$EMPTY"
  assert_eq "$(o_res "$C_EV") $(o_gen "$C_EV") $(o_total "$C_EV") $(o_nrows "$C_EV") $(c_admits detail)" "error io|$IO_TEXT $EMPTY 0 0 ok" "$1: the detail is error io, no row"
  O_BASH=${F_BASH:-} O_PATH=$O_PATH o_text operation journey
  assert_eq "$O_RC" 1 "$1 (text): exit status 1"
  assert_eq "$(printf '%s\n' "$O_OUT" | grep -c .)" 1 "$1 (text): one line, no row"
  assert_contains "$O_OUT" "$IO_TEXT" "$1 (text): the fixed text"
  o_pure "$1"
}
printf 'omb-op 1\ntorn' | o_raw
o_tool mkdir '*"/operation "*' fail
io 'DIA-08 the scratch cannot be made'
o_tool shasum "$COPY_ARG" fail
o_shim "$SHIMS/$SN" sha256sum "$COPY_ARG" fail
io 'DIA-08 the fingerprint cannot be hashed'
o_tool shasum '*"/operation/identity "*' fail
o_shim "$SHIMS/$SN" sha256sum '*"/operation/identity "*' fail
o_before
C_PATH=$O_PATH c_run snapshot "scope	name=journey"
assert_eq "$(o_res "$C_EV") $(o_gen "$C_EV")" "error io|$IO_TEXT $EMPTY" 'DIA-08 the generation cannot be hashed: error io'
C_PATH=$O_PATH o_detail 0 20 "$EMPTY"
assert_eq "$(o_res "$C_EV") $(o_nrows "$C_EV")" "error io|$IO_TEXT 0" 'DIA-08 the generation cannot be hashed: the detail too'
o_pure 'DIA-08 the generation cannot be hashed'
O_PATH=''
mkdir -p "$T/text-tmp"
chmod 500 "$T/text-tmp"
if [ "$ROOT" = 0 ]; then
  o_text --ascii operation journey
  assert_eq "$O_RC|$O_OUT" "1|$(printf '   x %s' "$IO_TEXT")" 'DIA-08 (text): no scratch, error io through ui_fail'
else
  skip 'DIA-08 (text) an unwritable TMPDIR: root writes it'
fi
chmod 700 "$T/text-tmp"

# === DIA-09 a value cannot be represented ================================================
TAB_STATE=$T/st$(printf '\t')ate
mkdir -p "$TAB_STATE/ops"
printf 'omb-op 1\ntorn' >"$TAB_STATE/ops/journey.omb"
# What the representation path must leave as it is: the state tree (its
# record, log and lock), HOME (its cache), and the scratch of every run.
cp "$TAB_STATE/ops/journey.omb" "$T/tab.before"
TAB_B_STATE=$(t_snapshot "$TAB_STATE")
TAB_B_HOME=$(t_snapshot "$T/home")
C_STATE=$TAB_STATE c_run snapshot "scope	name=journey"
O_SNAP=$T/snap-tab
cp "$C_EV" "$O_SNAP"
o_snapset 'DIA-09 the path cannot be represented' 'a record that cannot be read|fail' "$B_UNREADABLE" 'test.read '
TAB_GEN=$(o_gen "$O_SNAP")
[ "$TAB_GEN" != "$EMPTY" ] && ok || fail 'DIA-09: the snapshot still names its data set'
C_STATE=$TAB_STATE o_detail 0 20 "$TAB_GEN"
assert_eq "$(o_res "$C_EV") $(o_gen "$C_EV") $(o_total "$C_EV") $(o_nrows "$C_EV") $(c_admits detail)" \
  "error representation|$REP_TEXT $EMPTY 0 0 ok" 'DIA-09: the detail is error representation, no row'
o_save representation
C_STATE=$TAB_STATE o_detail 5 3 "$TAB_GEN"
assert_eq "$(o_res "$C_EV") $(o_nrows "$C_EV")" "error representation|$REP_TEXT 0" 'DIA-09: whatever page is asked, the whole finding is held to the format first'
C_STATE=$TAB_STATE o_detail 0 20 "$(printf '%064d' 0)"
assert_eq "$(o_res "$C_EV")" "error representation|$REP_TEXT" 'DIA-09: before a stale generation'
O_STATE=$TAB_STATE o_text --ascii operation journey
assert_eq "$O_RC|$O_OUT" "1|$(printf '   x %s' "$REP_TEXT")" 'DIA-09 (text): exit 1, the fixed text, no escaped or shortened path'
assert_not_contains "$(cat "$O_SNAP")" 'st%09ate' 'DIA-09: the snapshot carries the path in no form'
assert_eq "$(t_snapshot "$TAB_STATE")" "$TAB_B_STATE" 'DIA-09: the state tree is as it was'
cmp -s "$T/tab.before" "$TAB_STATE/ops/journey.omb" && ok || fail 'DIA-09: the record is unchanged, byte for byte'
[ ! -e "$TAB_STATE/logs" ] && [ ! -e "$TAB_STATE/lock" ] && ok || fail 'DIA-09: no log and no lock'
assert_eq "$(t_snapshot "$T/home")" "$TAB_B_HOME" 'DIA-09: HOME, its cache included, is as it was'
assert_eq "$(find "$T" "$T/text-tmp" -maxdepth 1 -name 'omarchy-bootstrap.*' 2>/dev/null)" '' 'DIA-09: no scratch is left by the core or the text interface'
# A path in valid UTF-8 is a path like any other.
UTF_STATE=$T/état
mkdir -p "$UTF_STATE/ops"
C_STATE=$UTF_STATE c_run snapshot "scope	name=journey"
C_STATE=$UTF_STATE o_detail 0 20 "$(o_gen "$C_EV")"
assert_eq "$(c_result)|$(o_rows | sed -n 2p)" "done ok|path|Record|$UTF_STATE/ops/journey.omb|" 'a UTF-8 path is carried as it is'

# === Generation and paging ===============================================================
printf 'omb-op 1\ntorn' | o_raw
o_look
G=$O_GEN
N=$(o_total "$C_EV")
assert_eq "$N" 13 'the torn finding has 13 rows'
whole=$(o_rows)
paged=''
i=0
while [ "$i" -lt "$N" ]; do
  o_detail "$i" 1 "$G"
  paged="$paged$(o_rows)
"
  i=$((i + 1))
done
assert_eq "${paged%
}" "$whole" 'paging: one row at a time, the same finding'
o_detail "$N" 20 "$G"
assert_eq "$(c_result) $(o_nrows "$C_EV") $(o_total "$C_EV") $(c_admits detail)" "done ok 0 $N ok" 'paging: offset equal to total is done with no row'
o_detail $((N + 1)) 20 "$G"
assert_eq "$(c_result) $(o_nrows "$C_EV") $(o_gen "$C_EV") $(c_admits detail)" "refused invalid 0 $G ok" 'paging: offset beyond total is refused invalid, no row'
o_detail 0 20 "$(printf '%064d' 0)"
assert_eq "$(c_result) $(o_nrows "$C_EV") $(o_gen "$C_EV") $(o_total "$C_EV")" "refused changed 0 $G $N" 'a generation the core does not hold: refused changed, the fresh generation, no row'
o_detail 0 500 "$G"
assert_eq "$(c_result) $(o_nrows "$C_EV")" "done ok $N" 'a limit of 500 returns the finding whole'
c_run detail "page	scope=journey	kind=operation	generation=$G	offset=0	limit=501"
assert_eq "$(c_result) $C_RC" 'error type 2' 'a limit over 500 is refused at admission'
# changed NAME — the record moved between the snapshot and the detail.
changed() {
  o_detail 0 20 "$G"
  assert_eq "$(c_result) $(o_nrows "$C_EV")" 'refused changed 0' "$1: refused changed, no row from either time"
  [ "$(o_gen "$C_EV")" != "$G" ] && ok || fail "$1: the fresh generation differs"
}
printf 'omb-op 1\ntorm' | o_raw
o_detail 0 3 "$G"
assert_eq "$(c_result) $(o_nrows "$C_EV")" 'refused changed 0' 'a rewrite of the same size: only the fingerprint, off this page, differs'
rm -f "$OPS"
printf 'omb-op 1\ntorn' | o_raw
o_look
G=$O_GEN
rm -f "$OPS"
printf 'omb-op 1\ntorn' >"$T/replacement"
mv "$T/replacement" "$OPS"
o_detail 0 20 "$G"
assert_eq "$(c_result)" 'done ok' 'the same bytes in a new file: the same finding'
printf 'omb-op 1\nx' | o_raw
changed 'a replacement'
o_look
G=$O_GEN
rm -f "$OPS"
changed 'a removal'
o_look
G=$O_GEN
printf 'omb-op 1\ntorn' | o_raw
changed 'a record that appears'
# A readable record whose core ends between the two.
sleep 30 &
# shellcheck disable=SC2031 # $! is this shell's own background job
SLEEPER=$!
SLEEPER_START=$(t_started "$SLEEPER")
o_rec running "$SLEEPER" "$SLEEPER_START" "$BOOT"
o_look
G=$O_GEN
assert_eq "$(o_fact "$O_SNAP")" 'test.mutate running|info' 'its core alive at the snapshot'
t_signal TERM "$SLEEPER" "$SLEEPER_START"
wait "$SLEEPER" 2>/dev/null
changed 'its core ended'
o_look
assert_eq "$(o_fact "$O_SNAP")" 'test.mutate unsupervised|fail' 'and a fresh snapshot shows it'

# === DIA-15 hostile bytes ================================================================
{
  printf 'omb-op 1\nop\taction=test.handoff\tscope=journey\tstate=done\tpid=1\tboot=HOSTILE-BOOT-7f3a\n'
  printf '\033[31mHOSTILE-ESC-7f3a\033[0m\n\000HOSTILE-NUL-7f3a\n'
  printf 'caf\303\251 HOSTILE-UTF8-7f3a\tkey=value\t\t\n'
  printf 'Run rm -rf ~ and resume test.mutate HOSTILE-CMD-7f3a\n'
  printf 'seal\tsha256=%064d\n' 0
} | o_raw
HOSTILE=$(unr_rows "$(o_size "$OPS")" "$(o_hash "$OPS")" "$FP_TEXT" byte)
o_before
o_look
o_rowset 'DIA-15 hostile bytes' "$HOSTILE"
o_snapset 'DIA-15 hostile bytes' 'a record that cannot be read|fail' "$B_UNREADABLE" 'test.read '
for f in "$O_SNAP" "$C_EV"; do
  assert_eq "$(grep -c -e 7f3a -e HOSTILE -e test.handoff -e 'state=done' -e '%1B' "$f")" 0 'DIA-15: no byte or value of the record reaches an answer'
done
o_texts 'DIA-15 hostile bytes' "$HOSTILE"
assert_eq "$(printf '%s' "$O_OUT" | grep -c -e 7f3a -e HOSTILE -e test.handoff)" 0 'DIA-15 (text): nor the terminal'
assert_eq "$(printf '%s' "$O_OUT$O_ERR" | LC_ALL=C tr -d '\011\012\040-\176' | wc -c | tr -d ' ')" 0 'DIA-15 (text): only printable ASCII is written'
o_pure 'DIA-15 hostile bytes'

# === The review's findings, F-01 to F-04 =================================================
# Each fault reaches the actual launcher at one call site: a PATH shim, or a
# bash whose exported functions stand in for the command or builtin they
# name (the Gate 2 proofs' faults, with no seam in the tool).
FB=0
F_BASH=''
# f_bash BODY — F_BASH: the bash under test with BODY run first (functions
# and their export -f).
f_bash() {
  local real
  real=$(command -v "$T_BASH")
  FB=$((FB + 1))
  F_BASH=$T/fault-bash-$FB
  printf '#!%s\n%s\nexec "%s" "$@"\n' "$real" "$1" "$real" >"$F_BASH"
  chmod +x "$F_BASH"
}
# f_case NAME ROWS FACT BLOCKERS — the finding under F_BASH and O_PATH: the
# snapshot and its detail, then the text interface, each a read.
f_case() {
  o_before
  C_BASH=$F_BASH C_PATH=$O_PATH o_look
  o_rowset "$1" "$2"
  o_snapset "$1" "$3" "$4" 'test.read '
  o_pure "$1"
  O_BASH=$F_BASH O_PATH=$O_PATH o_texts "$1" "$2"
}
# f_sealed NAME — of a record whose admission did not complete, nothing it
# says reaches the snapshot, the detail or the terminal: no recorded row,
# no action it names, no value of its own.
f_sealed() {
  assert_eq "$(grep -c -e 'key=recorded\.' -e 'key=boot' "$C_EV")" 0 "$1: no recorded field in the detail"
  assert_eq "$(cat "$O_SNAP" "$C_EV" | grep -c -e test.mutate -e test.handoff -e unexpected -e HOSTILE)" 0 "$1: no action or value of the record in the snapshot or the detail"
  assert_eq "$(printf '%s' "$O_OUT" | grep -c -e Recorded -e test.mutate -e test.handoff -e unexpected -e HOSTILE)" 0 "$1 (text): nor on the terminal"
}

# --- F-01: the record replaced between its status and its read ----------------------------
# f_swap — O_PATH with a find that, once the status step's last check (the
# mode) has run, renames $T/f01-next (a link, a FIFO) over the record: the
# read meets the replacement, whatever it uses.
f_swap() {
  local real="" d
  for d in /usr/bin /bin; do
    if [ -x "$d/find" ]; then real=$d/find && break; fi
  done
  SN=$((SN + 1))
  mkdir -p "$SHIMS/$SN"
  printf '#!/bin/sh\ncase " $* " in\n  *"/ops/journey.omb -maxdepth 0 ( -perm"*)\n    "%s" "$@"\n    st=$?\n    if [ -e "%s" ] || [ -L "%s" ]; then mv -f "%s" "%s"; fi\n    exit $st\n    ;;\nesac\nexec "%s" "$@"\n' \
    "$real" "$T/f01-next" "$T/f01-next" "$T/f01-next" "$OPS" "$real" >"$SHIMS/$SN/find"
  chmod +x "$SHIMS/$SN/find"
  O_PATH="$SHIMS/$SN:/usr/bin:/bin:/usr/sbin:/sbin"
}
# f01_set KIND [TARGET] — record A in place, a plain file of yours, and its
# replacement ready: a link to TARGET, or a FIFO.
f01_set() {
  rm -f "$OPS" "$T/f01-next"
  cp -p "$T/f01-a" "$OPS"
  case $1 in
    link) ln -s "$2" "$T/f01-next" ;;
    fifo) mkfifo "$T/f01-next" ;;
  esac
}
# f_release_start / f_release_stop — in the background: from 10 s on, any
# open of the record that waits for a writer is given one ($T/f-released
# says so), until stopped. A read that never waits never needs it.
f_release_start() {
  rm -f "$T/f-stop"
  (
    i=0
    while [ ! -e "$T/f-stop" ]; do
      if [ "$i" -ge 50 ] && [ -p "$OPS" ]; then
        : >>"$T/f-released"
        { sleep 0.3; } 9<>"$OPS"
      fi
      sleep 0.2
      i=$((i + 1))
    done
  ) </dev/null >/dev/null 2>&1 &
  # shellcheck disable=SC2031 # $! is this shell's own background job
  F_REL=$!
}
f_release_stop() {
  : >"$T/f-stop"
  wait "$F_REL" 2>/dev/null
}
F01_ROWS="$(o_head undetermined "$TX_UNDET")
stage|Failed step|read|$ST_READ
$ENTRY
$UNDET_TAIL
next|Next||$N_READ"
# f01 NAME KIND [TARGET] — A replaced by KIND after its status, in the
# snapshot, in the detail from its generation (A replaced the same way
# again) and in the text interface: each undetermined at the read, none
# waiting, none showing anything of the replacement, which stays as it was.
f01() {
  local name=$1 h
  rm -f "$T/f-released"
  h=$(t_snapshot "$T/home")
  f_swap
  f01_set "$2" "${3:-}"
  f_release_start
  C_PATH=$O_PATH c_run snapshot "scope	name=journey"
  f_release_stop
  O_SNAP=$T/snap-$C_N
  cp "$C_EV" "$O_SNAP"
  O_GEN=$(o_gen "$O_SNAP")
  o_snapset "$name" 'cannot be inspected|unknown' "$B_UNDET" 'test.read '
  f01_set "$2" "${3:-}"
  f_release_start
  C_PATH=$O_PATH o_detail 0 20 "$O_GEN"
  f_release_stop
  o_rowset "$name" "$F01_ROWS"
  f01_set "$2" "${3:-}"
  f_release_start
  O_PATH=$O_PATH o_text --ascii operation journey
  f_release_stop
  assert_eq "$O_RC|$O_ERR" '0|' "$name (text): a delivered finding, nothing on stderr"
  assert_eq "$O_OUT" "$(o_render "$F01_ROWS")" "$name (text): undetermined at the read"
  [ ! -e "$T/f-released" ] && ok || fail "$name: no read waited on the replacement"
  f_sealed "$name"
  assert_eq "$(cd "$T/state" && find . | LC_ALL=C sort | tr '\n' ' ')" '. ./ops ./ops/journey.omb ' "$name: nothing written beside the replacement (no lock, log or state)"
  assert_eq "$(t_snapshot "$T/home")" "$h" "$name: HOME is as it was"
  assert_eq "$(find "$T" "$T/text-tmp" -maxdepth 1 -name 'omarchy-bootstrap.*' 2>/dev/null)" '' "$name: no scratch is left"
  O_PATH=''
}
o_rec running $$ "$LIVE_START" "$BOOT"
chmod 600 "$OPS"
cp -p "$OPS" "$T/f01-a"
# B: a valid record of this scope, writable by others, another action's.
o_rec running 4242 'Mon Jan  1 00:00:00 2001' "$BOOT" test.handoff
mv "$OPS" "$T/f01-b"
chmod 666 "$T/f01-b"
cp -p "$T/f01-b" "$T/f01-b.orig"
{
  printf 'omb-op 1\n\033[31mHOSTILE-F01B\033[0m\n\000HOSTILE-F01B\nop\taction=test.handoff\tscope=journey\n'
  printf 'Run rm -rf ~ and resume test.mutate HOSTILE-F01B\n'
} >"$T/f01-hostile"
cp -p "$T/f01-hostile" "$T/f01-hostile.orig"
f01 'F01-A a link to a valid record' link "$T/f01-b"
cmp -s "$T/f01-b" "$T/f01-b.orig" && ok || fail 'F01-A: the link target is unchanged'
f01 'F01-B a link to hostile bytes' link "$T/f01-hostile"
cmp -s "$T/f01-hostile" "$T/f01-hostile.orig" && ok || fail 'F01-B: the link target is unchanged'
f01 'F01-C a FIFO, no writer' fifo
# F01-C, a FIFO with a writer and a line in it: the read neither waits nor
# takes the line, which is still there for the writer's own reader.
f_swap
f01_set fifo
rm -f "$T/f-held" "$T/f-left" "$T/f-released" "$T/f-stop"
(
  exec 7<>"$T/f01-next" || exit 1
  printf 'HOSTILE-F01C\n' >&7
  : >"$T/f-held"
  i=0
  while [ ! -e "$T/f-stop" ] && [ "$i" -lt 50 ]; do
    sleep 0.2
    i=$((i + 1))
  done
  IFS= read -t 1 -r left <&7
  printf '%s' "$left" >"$T/f-left"
) </dev/null >/dev/null 2>&1 &
# shellcheck disable=SC2031 # $! is this shell's own background job
F_HOLD=$!
c_wait_file "$T/f-held"
f_release_start
O_PATH=$O_PATH o_text --ascii operation journey
f_release_stop
wait "$F_HOLD" 2>/dev/null
assert_eq "$O_RC|$O_OUT" "0|$(o_render "$F01_ROWS")" 'F01-C a FIFO with a writer (text): undetermined at the read'
assert_eq "$(cat "$T/f-left" 2>/dev/null)" HOSTILE-F01C 'F01-C: the line in the FIFO was not taken'
[ ! -e "$T/f-released" ] && ok || fail 'F01-C: no read waited on it'
assert_eq "$(printf '%s' "$O_OUT$O_ERR" | grep -c HOSTILE)" 0 'F01-C (text): nothing of it on the terminal'
O_PATH=''
# F01-D: the same seam with nothing to swap in: the record reads as before.
rm -f "$OPS" "$T/f01-next"
cp -p "$T/f01-a" "$OPS"
f_swap
f_case 'F01-D the seam, nothing replaced' "$ALIVE_ROWS" 'test.mutate running|info' ''
O_PATH=''
# F01-E: the 65536- and 65537-byte boundaries are DIA-04's, through the same read.

# --- F-02: a schema check whose read stops short ------------------------------------------
# f_schema MARK — F_BASH, where the schema check's read of a line holding
# MARK reads it and then fails, as a read a signal interrupts does.
F_READ='read() {
  builtin read "$@" || return
  if [ "${FUNCNAME[1]:-}" = _rec_schema ]; then
    eval "__f_v=\${$#}"
    eval "__f_v=\${$__f_v-}"
    case $__f_v in *"$F_MARK"*) return 1 ;; esac
  fi
  return 0
}
export -f read'
f_schema() {
  f_bash "F_MARK='$1'
export F_MARK
$F_READ"
}
# f02_rows — undetermined at the check, the entry and its size read.
f02_rows() {
  printf '%s\nstage|Failed step|check|%s\n%s\nsize|Size|%s|\n%s\nnext|Next||%s' \
    "$(o_head undetermined "$TX_UNDET")" "$ST_CHECK" "$ENTRY" "$(o_size "$OPS")" "$UNDET_TAIL" "$N_CHECK"
}
# o_dup — a sealed record with two op records: this scope's own, then
# another with values of its own (test.handoff, failed, unexpected).
o_dup() (
  t_load >/dev/null 2>&1
  # shellcheck source=lib/records.sh
  . "$REPO/lib/records.sh"
  mkdir -p "$T/state/ops"
  {
    printf 'omb-op 1\n'
    rec_line op action test.mutate scope journey basis "$(printf '%064d' 7)" session "$SESS" state running \
      finding '' pid "$$" start "$LIVE_START" boot "$BOOT" at 2026-09-26T00:00:00Z
    rec_line op action test.handoff scope journey basis "$(printf '%064d' 9)" session "$SESS" state failed \
      finding unexpected pid 4242 start 'Mon Jan  1 00:00:00 2001' boot "$BOOT" at 2026-09-27T00:00:00Z
  } >"$OPS"
  rec_seal_write "$OPS"
  omb_cleanup
)
rm -f "$OPS"
o_rec running $$ "$LIVE_START" "$BOOT"
f_schema "op	action="
f_case 'F02-A a valid record, the read of its op record fails' "$(f02_rows)" 'cannot be inspected|unknown' "$B_UNDET"
f_sealed 'F02-A a valid record, the read of its op record fails'
f_schema 'omb-op 1'
f_case 'F02-A a valid record, the read of its header fails' "$(f02_rows)" 'cannot be inspected|unknown' "$B_UNDET"
f_sealed 'F02-A a valid record, the read of its header fails'
f_schema "seal	sha256="
f_case 'F02-A a valid record, the read of its seal line fails' "$(f02_rows)" 'cannot be inspected|unknown' "$B_UNDET"
f_sealed 'F02-A a valid record, the read of its seal line fails'
f_schema 'F02-NEVER-PRESENT'
f_case 'F02-D the same seam, no read fails: readable' "$ALIVE_ROWS" 'test.mutate running|info' ''
o_dup
F_BASH=''
f_case 'F02-B two op records, checked to the end' "$(unr_rows "$(o_size "$OPS")" "$(o_hash "$OPS")" "$FP_TEXT" schema 3)" \
  'a record that cannot be read|fail' "$B_UNREADABLE"
f_sealed 'F02-B two op records, checked to the end'
f_schema 'action=test.handoff'
f_case 'F02-C two op records, the read of the second fails' "$(f02_rows)" 'cannot be inspected|unknown' "$B_UNDET"
f_sealed 'F02-C two op records, the read of the second fails'
f_schema 'action=test.mutate'
f_case 'F02-E the read fails before a second record of its own' "$(f02_rows)" 'cannot be inspected|unknown' "$B_UNDET"
f_sealed 'F02-E the read fails before a second record of its own'
F_BASH=''

# --- F-03: the snapshot's own answer staged, admitted, kept, then published --------------
printf 'omb-op 1\ntorn' | o_raw
f_bash "F_KEEP='$T/f03-kept'
export F_KEEP
cp() {
  command cp \"\$@\" || return
  case \"\${2:-}\" in */journey.admitted) command cp \"\$2\" \"\$F_KEEP\" ;; esac
}
export -f cp"
rm -f "$T/f03-kept"
o_before
C_BASH=$F_BASH c_run snapshot "scope	name=journey"
assert_eq "$(cut -f1 "$C_EV" | tr '\n' ' ')" 'omb-res 1 hello generation fact fact fact blocker action result ' 'F03-D the snapshot: its records, in order'
assert_eq "$(c_admits snapshot) $(c_result)" 'ok done ok' 'F03-D: a whole, admitted answer'
cmp -s "$T/f03-kept" "$C_EV" && ok || fail 'F03-D: what is published is the admitted copy, byte for byte'
o_pure 'F03-D the snapshot'
f_bash 'cp() { case "${2:-}" in */journey.admitted) return 1 ;; esac; command cp "$@"; }
export -f cp'
io 'F03-A the admitted copy cannot be kept'
f_bash 'cat() { case "${1:-}" in */journey.prefix) return 1 ;; esac; command cat "$@"; }
export -f cat'
io 'F03-B the response cannot be staged'
f_bash 'awk() { case "$*" in *"hdr=omb-res 1"*) return 127 ;; esac; command awk "$@"; }
export -f awk'
io 'F03-C the admission cannot run: io'
F_BASH=''
# F03-C: a value of the snapshot's own the format cannot carry (a fixture
# named with a TAB): error representation, nothing partial.
TAB_FIX="$T/fix$(printf '\t')ture"
cp -R "$C_FIX" "$TAB_FIX"
o_before
C_FIX=$TAB_FIX c_run snapshot "scope	name=journey"
assert_eq "$(o_res "$C_EV") $(o_gen "$C_EV") $(o_total "$C_EV") $(c_admits snapshot)" "error representation|$REP_TEXT $EMPTY 0 ok" 'F03-C a value the format cannot carry: error representation'
assert_eq "$(grep -cE '^(fact|blocker|action|row)	' "$C_EV")" 0 'F03-C: with no fact, blocker, action or row'
o_pure 'F03-C representation'
rm -rf "$TAB_FIX"
# F03-F: a publication cut short stays incomplete: nothing is appended after it.
c_run snapshot "scope	name=journey"
G=$(o_gen "$C_EV")
f_bash 'cat() { case "${1:-}" in */operation.suffix) command head -n 1 "$1"; return 1 ;; esac; command cat "$@"; }
export -f cat'
C_BASH=$F_BASH c_run snapshot "scope	name=journey"
assert_eq "$(cut -f1 "$C_EV" | tr '\n' ' ')" 'omb-res 1 hello generation ' 'F03-F the snapshot: its publication cut short is left as it is'
assert_eq "$(grep -c '^result	' "$C_EV")" 0 'F03-F the snapshot: no second result after it'
C_BASH=$F_BASH o_detail 0 20 "$G"
assert_eq "$(cut -f1 "$C_EV" | tr '\n' ' ')" 'omb-res 1 hello generation ' 'F03-F the detail: its publication cut short is left as it is'
assert_eq "$(grep -c '^result	' "$C_EV")" 0 'F03-F the detail: no second result after it'
F_BASH=''

# --- F-04: the process table read for this process, not for the recorded one -------------
o_rec running $$ "$LIVE_START" "$BOOT"
o_tool ps "*\" $$ \"*|*\" $$,\"*|*\",$$ \"*|*\",$$,\"*" fail
f_case 'F04-A ps reads this process, not the recorded core' "$LIVE_ROWS" \
  'test.mutate recorded as running; whether its core runs is unknown|warn' ''
# F04-B (ps reads nothing: DIA-03), F04-C (its core alive: DIA-02) and F04-D
# (another start time: DIA-10(a)) are above. F04-E: the act path reads the
# process table as it did, and answers as it did.
o_before
C_PATH=$O_PATH c_exec test.mutate test
assert_eq "$(o_res "$C_EV")" 'refused unsupervised|The outcome of test.mutate is unknown and it may still be running: restart this Mac (or this Linux system), then run the tool again.' \
  'F04-E: under the same fault the act path answers as before'
cmp -s "$T/rec.before" "$OPS" && ok || fail 'F04-E: and leaves the record as it was'
O_PATH=''
c_exec test.mutate test
assert_eq "$(o_res "$C_EV")" 'refused busy|test.mutate is still running under a live core.' 'F04-E: with ps whole, its live core is busy, as before'
cmp -s "$T/rec.before" "$OPS" && ok || fail 'F04-E: the record is as it was'

# === The act path and the other surfaces are unchanged ===================================
printf 'omb-op 1\ntorn' | o_raw
c_exec test.mutate test
assert_eq "$(o_res "$C_EV")" "refused unsupervised|The operation record $OPS cannot be read, so what it recorded is unknown, and a restart does not change that: nothing in this scope runs while it is there." \
  'UR-Q6 stays open: the act refusal of an unreadable record is as it was'
c_run detail "page	scope=journey	kind=status	generation=$EMPTY	offset=0	limit=20"
assert_eq "$(o_res "$C_EV")" 'refused unavailable|Nothing in this gate pages details or validates parameters.' 'the foundation keeps its refusal for every other kind'
C_ENV='OMB_SESSION_SCOPES=journey,shared' c_run detail "page	scope=shared	kind=operation	generation=$EMPTY	offset=0	limit=20"
assert_eq "$(o_res "$C_EV")" 'refused unavailable|Nothing in this gate pages details or validates parameters.' 'a scope that keeps no record here answers with its existing text'
C_ENV='OMB_SESSION_SCOPES=shared' c_run detail "page	scope=journey	kind=operation	generation=$EMPTY	offset=0	limit=20"
assert_eq "$(c_result) $(c_admits detail)" 'refused scope ok' 'a session without the scope is refused scope'
c_run validate "select	action=test.read"
assert_eq "$(o_res "$C_EV")" 'refused unavailable|Nothing in this gate pages details or validates parameters.' 'validate is unchanged'
# The ordinary Gate 2 journey keeps no operation record and gains no kind.
C_FOUNDATION=0 c_run snapshot "scope	name=journey"
assert_eq "$(c_result) $(o_fact "$C_EV")" 'done ok ' 'the ordinary journey has no operation fact'
C_FOUNDATION=0 o_detail 0 20 "$(o_gen "$C_EV")"
assert_eq "$(o_res "$C_EV")" 'refused unavailable|This journey detail kind is not available.' 'the ordinary journey answers kind=operation as before'
# The startup check reads no operation record and pages nothing.
CK_SHIM=$(t_tmp)
c_uname_arm "$CK_SHIM"
ck() {
  C_FOUNDATION=0 C_PATH="$CK_SHIM:/usr/bin:/bin:/usr/sbin:/sbin" \
    C_ENV="OMB_FIXTURE= OMB_FRONTEND_DEV= OMB_SESSION_INTENT=read OMB_SESSION_PURPOSE=frontend-check OMB_STATE_DIR=$T/state" c_run "$@"
}
ck snapshot "scope	name=journey"
assert_eq "$(c_result) $(o_fact "$C_EV")|$(o_blockers "$C_EV")" 'done ok |' 'the startup check shows no operation fact or blocker'
ck detail "page	scope=journey	kind=operation	generation=$EMPTY	offset=0	limit=20"
assert_eq "$(o_res "$C_EV")" 'refused unavailable|A frontend-check session answers only hello and the journey snapshot.' 'and pages no operation detail'
rm -rf "$CK_SHIM"

# === The text command: its argument, its intent, every scope =============================
for args in '' 'nope' 'journey journey' 'Journey' 'journey/../shared'; do
  rm -rf "$T/state"
  # shellcheck disable=SC2086 # the arguments, split on purpose
  o_text operation $args
  assert_eq "$O_RC|$O_OUT|$O_ERR" "2||$USAGE" "operation [$args]: refused before anything else"
  [ ! -e "$T/state" ] && ok || fail "operation [$args]: no state folder made"
done
o_text operation --ascii
assert_eq "$O_RC|$O_ERR" "2|$USAGE" 'a flag is no scope'
for s in journey disk plan profile resolve asahi network omarchy shared export restore rescue qualify debug health logs; do
  o_text --ascii operation "$s"
  assert_eq "$O_RC|$(printf '%s\n' "$O_OUT" | sed -n 3,5p)" "0|   Scope               $s
   Record              $T/state/ops/$s.omb
   State               none - $TX_NONE" "operation $s: every scope answers"
done
[ ! -e "$T/state" ] && ok || fail 'no state folder made by any of them'
O_PROD=1 o_text --ascii operation journey
assert_eq "$O_RC|$(printf '%s\n' "$O_OUT" | sed -n 5p)" "0|   State               none - $TX_NONE" 'in production too'
[ ! -e "$T/state" ] && ok || fail 'in production: no state folder made'
assert_eq "$(find "$T/text-tmp" -mindepth 1 2>/dev/null)" '' 'no scratch left'
LAUNCHER_SCOPES=$(sed -n 's/^ *\(journey | [a-z |]*\)) ;;$/\1/p' "$REPO/omarchy-bootstrap" | tr -d ' ')
assert_eq "$LAUNCHER_SCOPES" "$(sed -n 's/^REC_SCOPES="\(.*\)"$/\1/p' "$REPO/lib/records.sh")" "the launcher's scope names are the protocol's"
assert_contains "$USAGE" "$(printf '%s' "$LAUNCHER_SCOPES" | sed 's/|/, /g') (see --help)" 'and its usage names each of them'
o_text --help
assert_contains "$O_OUT" 'operation SCOPE' '--help lists the command'

# === DIA-13 a new client, an old core ====================================================
OLD=$T/old-152c8f6
mkdir -p "$OLD"
if git -C "$REPO" archive 152c8f68854368025816b926494dbec0e94bc903 | tar -x -C "$OLD"; then ok; else fail 'DIA-13: the accepted prerequisite checkout is extracted'; fi
printf 'omb-op 1\ntorn' | o_raw
o_before
C_HOME=$OLD c_run snapshot "scope	name=journey"
OLD_GEN=$(o_gen "$C_EV")
C_HOME=$OLD o_detail 0 20 "$OLD_GEN"
assert_eq "$(o_res "$C_EV") $(o_nrows "$C_EV") $(c_admits detail)" 'refused unavailable|Nothing in this gate pages details or validates parameters. 0 ok' \
  'DIA-13: the old foundation answers with its own text, no row'
C_FOUNDATION=0 C_HOME=$OLD c_run snapshot "scope	name=journey"
C_FOUNDATION=0 C_HOME=$OLD o_detail 0 20 "$(o_gen "$C_EV")"
assert_eq "$(o_res "$C_EV") $(o_nrows "$C_EV")" 'refused unavailable|This journey detail kind is not available. 0' 'DIA-13: the old ordinary journey answers with its own text'
PROD_SHIM=$(t_tmp)
c_uname_arm "$PROD_SHIM"
C_FOUNDATION=0 C_HOME=$OLD C_PATH="$PROD_SHIM:/usr/bin:/bin:/usr/sbin:/sbin" C_ENV='OMB_FIXTURE= OMB_FRONTEND_DEV=' o_detail 0 20 "$EMPTY"
assert_eq "$(o_res "$C_EV") $(o_nrows "$C_EV")" 'refused unavailable|This read dataset is not available. 0' 'DIA-13: the old core outside fixtures'
o_pure 'DIA-13: no old core changes anything'
rm -rf "$T/state"
O_HOME=$OLD o_text operation journey
assert_eq "$O_RC|$O_OUT|$O_ERR" '2||omarchy-bootstrap: unexpected argument: journey (see --help)' 'DIA-13 (text): the old checkout stops at its argument check'
[ ! -e "$T/state" ] && ok || fail 'DIA-13 (text): nothing written'
# Without its argument, the old checkout takes the word for an act command:
# the reason the argument is required (docs/PROTOCOL.md → *The text interface*).
O_HOME=$OLD o_text operation
assert_eq "$O_RC" 2 'DIA-13: the bare word on the old checkout ends unknown'
assert_contains "$O_OUT" 'Unknown command: operation' 'DIA-13: as an unknown command'
[ -d "$T/state/logs" ] && ok || fail 'DIA-13: after its act intent wrote a log, as documented'
rm -rf "$T/state" "$PROD_SHIM"
O_HOME=''

# === DIA-14 the foundation answers admit for any client (frontend/tests/proto_diff.rs runs the frozen 0.1.0 code) ===
if [ -n "$save" ]; then
  while read -r name op; do
    assert_eq "$(c_admits_file "$op" "$save/$name.doc")" ok "DIA-14: $name admits"
  done <"$save/cases"
fi

t_done operation
