# shellcheck shell=bash
# The record format and admission (docs/PROTOCOL.md → §1, §2).
#
# Every document the core reads passes admission before anything splits it,
# because Bash's read normalises doubled, leading and trailing TABs and drops
# or truncates NULs. Admission is six steps over bytes — a bounded copy, the
# size, the byte class, the final LF, one C-locale awk pass for framing and
# canonical form, then the schema — and each refusal carries the reason code
# of the first check that fails, in that order. frontend/src/record.rs applies
# the same rules; the differential corpus (tests/proto/corpus.sh) holds the
# two together.
#
# After an admission returns 0: REC_N records (header and seal excluded) in
# REC_T[i] (type) and REC_L[i] (the written line); rec_get I KEY decodes one
# value. On refusal: REC_REASON (the reason code) and REC_AT (the line, or 0).
# Needs lib/common.sh (sha256_str, sha256_of, omb_tmp_init) and lib/state.sh
# (cfg_field_ok, the token's fields, _whole).

REC_SCOPES="journey|disk|plan|profile|resolve|asahi|network|omarchy|shared|export|restore|rescue|qualify|debug"
REC_STAGES="survey|profile|resolve|plan|asahi|omarchy|shared|restore|verify|done"
REC_PROTO=1
# Set here, so admission copies go only where this library makes them.
REC_TMP=""

# _rec_family FAMILY — the family's header, limits, seal and the order of its
# record types. Stored families are sealed; protocol messages are not. A
# record limit of 0 means none beyond the byte limit.
_rec_family() {
  case "$1" in
    req) REC_HDR="omb-req 1" REC_MAX_BYTES=65536 REC_MAX_RECS=512 REC_SEALED=0 REC_ORDER="req scope page select exec arg" ;;
    res) REC_HDR="omb-res 1" REC_MAX_BYTES=8388608 REC_MAX_RECS=65536 REC_SEALED=0
      REC_ORDER="hello generation stage fact region answer guide code warning blocker action param normal invalid review row progress message overflow result" ;;
    lock) REC_HDR="omb-frontend-lock 1" REC_MAX_BYTES=65536 REC_MAX_RECS=0 REC_SEALED=1 REC_ORDER="frontend artifact" ;;
    children) REC_HDR="omb-children 1" REC_MAX_BYTES=65536 REC_MAX_RECS=0 REC_SEALED=1 REC_ORDER="child" ;;
    proc) REC_HDR="omb-proc 1" REC_MAX_BYTES=65536 REC_MAX_RECS=0 REC_SEALED=1 REC_ORDER="proc" ;;
    op) REC_HDR="omb-op 1" REC_MAX_BYTES=65536 REC_MAX_RECS=0 REC_SEALED=1 REC_ORDER="op" ;;
    *) return 1 ;;
  esac
}

# _rec_spec FAMILY TYPE — REC_SPEC: the record's fields in order, each
# name:type, with ? (optional: present, written empty for none), * (a list)
# or + (a list of at least one).
_rec_spec() {
  local s="enum($REC_SCOPES)"
  case "$1.$2" in
    req.req) REC_SPEC="op:enum(hello|snapshot|detail|validate|execute) proto:uint frontend:id session:hex16" ;;
    req.scope) REC_SPEC="name:$s" ;;
    req.page) REC_SPEC="scope:$s kind:id generation:hex64 offset:uint limit:uint" ;;
    req.select) REC_SPEC="action:id" ;;
    req.exec) REC_SPEC="action:id basis:hex64 confirm:id?" ;;
    req.arg) REC_SPEC="name:id value:bytes" ;;
    res.hello) REC_SPEC="core:id commit:hex40? source:hex64 proto:uint platform:enum(macos|linux) arch:enum(arm64|aarch64) user:enum(root|user) ceiling:enum(read|plan|act) dry_run:bool fixture:bool" ;;
    res.generation) REC_SPEC="id:hex64 total:uint" ;;
    res.stage) REC_SPEC="name:enum($REC_STAGES) state:enum(done|current|todo|skipped|blocked) basis:enum(machine|recorded) by:enum(macos|linux)? at:utc? detail:text?" ;;
    res.fact) REC_SPEC="scope:$s key:id label:text value:text state:enum(ok|info|warn|fail|unknown)" ;;
    res.region) REC_SPEC="start:uint size:uint role:enum(apple|macos|stub|efi|linux|shared|free|other) label:text?" ;;
    res.answer) REC_SPEC="n:uint prompt:text value:text bytes:uint?" ;;
    res.guide) REC_SPEC="id:id step:uint text:text" ;;
    res.code) REC_SPEC="kind:enum(token|ombdone|ombshare|ombbundle) value:code" ;;
    res.warning | res.blocker) REC_SPEC="id:id text:text fix:text?" ;;
    res.action) REC_SPEC="id:id scope:$s label:text intent:enum(read|plan|act) gate:id? terminal:enum(managed|handoff) cancel:bool basis:hex64? explain:text?" ;;
    res.param) REC_SPEC="action:id name:id type:enum(uint|bool|id|bytes|text|choice|code) kind:id? required:bool choice:id*" ;;
    res.normal) REC_SPEC="name:id value:bytes" ;;
    res.invalid) REC_SPEC="name:id code:id text:text" ;;
    res.review) REC_SPEC="action:id basis:hex64" ;;
    res.row) REC_SPEC="kind:id key:bytes col:text*" ;;
    res.progress) REC_SPEC="action:id done:uint total:uint unit:id? label:text?" ;;
    res.message) REC_SPEC="level:enum(info|ok|warn|fail) text:text" ;;
    res.overflow) REC_SPEC="suppressed:uint" ;;
    res.result) REC_SPEC="status:enum(done|refused|failed|cancelled|stopped|error) code:id text:text? next:text?" ;;
    lock.frontend) REC_SPEC="version:id proto:uint source_commit:hex40 inputs_digest:hex64 rust:id" ;;
    lock.artifact) REC_SPEC="target:id url:bytes size:uint sha256:hex64 minos:id? glibc_max:id? interp:bytes? needed:bytes* align_min:uint?" ;;
    children.child) REC_SPEC="action:id cmd:bytes class:enum(read|mutating|handoff) stdout:enum(functional|diagnostics|null) stderr:enum(functional|diagnostics|null) tty:enum(none|needs) detaches:enum(no|owned) owner:text? check:id?" ;;
    proc.proc) REC_SPEC="role:enum(launcher|frontend|core|worker) pid:uint start:text boot:bytes" ;;
    op.op) REC_SPEC="action:id scope:$s basis:hex64 session:bytes state:enum(running|unsupervised) pid:uint start:text boot:bytes at:utc" ;;
    *) return 1 ;;
  esac
}

# _rec_card FAMILY OP TYPE — REC_CARD: 1, ?, *, + or - (forbidden).
_rec_card() {
  local i=0 col
  case "$1" in
    req | res)
      case "$2" in hello) i=1 ;; snapshot) i=2 ;; detail) i=3 ;; validate) i=4 ;; execute) i=5 ;; *) return 1 ;; esac
      ;;
  esac
  case "$1.$3" in
    #                          hello snapshot detail validate execute
    req.req) col="1 1 1 1 1" ;;
    req.scope) col="- 1 - - -" ;;
    req.page) col="- - 1 - -" ;;
    req.select) col="- - - 1 -" ;;
    req.exec) col="- - - - 1" ;;
    req.arg) col="- - - * *" ;;
    res.hello | res.result) col="1 1 1 1 1" ;;
    res.generation) col="- 1 1 - -" ;;
    res.stage | res.fact | res.blocker | res.action | res.param) col="- * - - -" ;;
    res.region | res.answer) col="- * - * -" ;;
    res.guide | res.code) col="- * - - *" ;;
    res.warning) col="- * - * *" ;;
    res.normal | res.invalid) col="- - - * -" ;;
    res.review) col="- - - ? -" ;;
    res.row) col="- - * - -" ;;
    res.progress) col="- - - - *" ;;
    res.message) col="- * * * *" ;;
    res.overflow) col="- ? ? ? ?" ;;
    lock.frontend | proc.proc | op.op) REC_CARD=1 && return 0 ;;
    lock.artifact) REC_CARD=+ && return 0 ;;
    children.child) REC_CARD='*' && return 0 ;;
    *) return 1 ;;
  esac
  set -f
  # shellcheck disable=SC2086 # the column list is split on purpose
  set -- $col
  set +f
  eval "REC_CARD=\${$i}"
}

# _rec_unique FAMILY TYPE — REC_UKEYS: the keys whose values together must
# differ between records of that type (empty: no such rule).
_rec_unique() {
  case "$1.$2" in
    req.arg | res.normal | res.invalid | res.stage) REC_UKEYS="name" ;;
    res.action) REC_UKEYS="id" ;;
    res.param) REC_UKEYS="action name" ;;
    lock.artifact) REC_UKEYS="target" ;;
    children.child) REC_UKEYS="action" ;;
    *) REC_UKEYS="" ;;
  esac
}

# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

# _rec_ord CHAR — REC_ORD: the byte's value, 0–255. /bin/bash 3.2 reports a
# byte above 0x7F as negative (a signed char), hence the correction.
_rec_ord() {
  printf -v REC_ORD '%d' "'$1"
  [ "$REC_ORD" -lt 0 ] && REC_ORD=$((REC_ORD + 256))
  return 0
}

# rec_enc_v VALUE — REC_ENC: the one canonical written form, a safe byte as
# itself and every other byte as % and two upper-case hex digits. No
# subshell: the core writes records by the thousand.
rec_enc_v() {
  local LC_ALL=C s=$1 c n i=0 h
  REC_ENC=""
  case "$s" in
    *[!A-Za-z0-9._~/:@+,-]*) ;;
    *) REC_ENC=$s && return 0 ;;
  esac
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    case "$c" in
      [A-Za-z0-9._~/:@+,-]) REC_ENC="$REC_ENC$c" ;;
      *)
        _rec_ord "$c"
        printf -v h '%%%02X' "$REC_ORD"
        REC_ENC="$REC_ENC$h"
        ;;
    esac
    i=$((i + 1))
  done
}

# rec_enc VALUE — the canonical written form, printed.
rec_enc() {
  rec_enc_v "$1"
  printf '%s' "$REC_ENC"
}

# rec_dec VALUE — the decoded bytes of an admitted value. No NUL is possible:
# %00 is refused before any value is decoded; a backslash is never a safe
# byte, so %b meets only the \xHH escapes built here.
rec_dec() {
  local LC_ALL=C s=$1 out="" pre
  while :; do
    case "$s" in
      *%*)
        pre=${s%%\%*}
        out="$out$pre\\x${s:${#pre}+1:2}"
        s=${s:${#pre}+3}
        ;;
      *) out="$out$s" && break ;;
    esac
  done
  printf '%b' "$out"
}

# _rec_bytes VALUE — REC_BYTES: every decoded byte's value, read from the
# written form without building the decoded string.
_rec_bytes() {
  local LC_ALL=C s=$1 c out="" i=0 n
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}
    if [ "$c" = % ]; then
      out="$out $((16#${s:i+1:2}))"
      i=$((i + 3))
    else
      _rec_ord "$c"
      out="$out $REC_ORD"
      i=$((i + 1))
    fi
  done
  REC_BYTES=$out
}

# _rec_text_ok VALUE — valid UTF-8 (no overlong form, no surrogate, nothing
# above U+10FFFF) holding no C0 or C1 control and no DEL: safe to render.
_rec_text_ok() {
  local b need=0 lo=128 hi=191 cp=0
  _rec_bytes "$1"
  for b in $REC_BYTES; do
    if [ "$need" = 0 ]; then
      if [ "$b" -lt 128 ]; then
        if [ "$b" -lt 32 ] || [ "$b" = 127 ]; then return 1; fi
        continue
      fi
      lo=128 hi=191
      if [ "$b" -ge 194 ] && [ "$b" -le 223 ]; then
        need=1 cp=$((b & 31))
      elif [ "$b" -ge 224 ] && [ "$b" -le 239 ]; then
        need=2 cp=$((b & 15))
        [ "$b" = 224 ] && lo=160
        [ "$b" = 237 ] && hi=159
      elif [ "$b" -ge 240 ] && [ "$b" -le 244 ]; then
        need=3 cp=$((b & 7))
        [ "$b" = 240 ] && lo=144
        [ "$b" = 244 ] && hi=143
      else
        return 1
      fi
    else
      if [ "$b" -lt "$lo" ] || [ "$b" -gt "$hi" ]; then return 1; fi
      lo=128 hi=191
      cp=$(((cp << 6) | (b & 63)))
      need=$((need - 1))
      # C1 controls: U+0080 to U+009F.
      if [ "$need" = 0 ] && [ "$cp" -ge 128 ] && [ "$cp" -le 159 ]; then return 1; fi
    fi
  done
  [ "$need" = 0 ]
}

# _rec_check_digits BODY CHECK — the baseline's code rule (code_parse):
# CHECK is the first four hex digits of the SHA-256 of BODY.
_rec_check_digits() {
  local d
  d=$(sha256_str "$1") || return 1
  [ "${d:0:4}" = "$2" ]
}

# rec_code_ok KIND DECODED — a code of that kind: its grammar, then its
# semantic check (docs/PROTOCOL.md → *Value types*, Codes).
rec_code_ok() {
  local kind=$1 c=$2 body pair k v seen=" " IFS
  case "$kind" in
    token)
      case "$c" in omb2:?*) body=${c#omb2:} ;; *) return 1 ;; esac
      case "$body" in ,* | *, | *,,*) return 1 ;; esac
      IFS=,
      set -f
      for pair in $body; do
        k=${pair%%=*} v=${pair#*=}
        case "$pair" in *=*) ;; *) set +f && return 1 ;; esac
        case "$k" in '' | *[!a-z]*) set +f && return 1 ;; esac
        case "$v" in *=*) set +f && return 1 ;; esac
        case "$seen" in *" $k "*) set +f && return 1 ;; esac
        seen="$seen$k "
        case " $TOKEN_FIELDS prof " in *" $k "*) ;; *) set +f && return 1 ;; esac
        if [ "$k" = prof ]; then
          valid_digest8 "$v" >/dev/null || { set +f && return 1; }
        else
          cfg_field_ok "$k" "$v" || { set +f && return 1; }
        fi
      done
      set +f
      ;;
    ombdone | ombshare)
      _whole "$c" "^$kind-[0-9a-f]{8}-[0-9a-f]{12}-[0-9a-f]{4}\$" || return 1
      _rec_check_digits "${c%-*}" "${c##*-}"
      ;;
    ombbundle)
      _whole "$c" '^ombbundle-[0-9a-f]{16}-[0-9a-f]{4}$' || return 1
      _rec_check_digits "${c%-*}" "${c##*-}"
      ;;
    *) return 1 ;;
  esac
}

# _rec_type_ok TYPE VALUE [KIND] — a non-empty written value of that type.
_rec_type_ok() {
  local t=$1 v=$2 d b n=0
  case "$t" in
    uint) _whole "$v" '^(0|[1-9][0-9]{0,17})$' ;;
    bool) case "$v" in 0 | 1) return 0 ;; *) return 1 ;; esac ;;
    id) _whole "$v" '^[a-z0-9][a-z0-9._:@+-]{0,127}$' ;;
    hex8) _whole "$v" '^[0-9a-f]{8}$' ;;
    hex16) _whole "$v" '^[0-9a-f]{16}$' ;;
    hex40) _whole "$v" '^[0-9a-f]{40}$' ;;
    hex64) _whole "$v" '^[0-9a-f]{64}$' ;;
    utc) _whole "$v" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' ;;
    text) _rec_text_ok "$v" ;;
    bytes) return 0 ;;
    code)
      _rec_bytes "$v"
      for b in $REC_BYTES; do
        if [ "$b" -lt 32 ] || [ "$b" -gt 126 ]; then return 1; fi
        n=$((n + 1))
      done
      [ "$n" -le 512 ] || return 1
      d=$(rec_dec "$v"; printf x)
      rec_code_ok "${3:-}" "${d%x}"
      ;;
    enum\(*\))
      d=${t#enum(}
      d=${d%)}
      case "|$d|" in *"|$v|"*) return 0 ;; esac
      return 1
      ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Admission
# ---------------------------------------------------------------------------

_rec_refuse() {
  REC_REASON=$1
  REC_AT=${2:-0}
  return 1
}

# _rec_tmp — a private folder in the per-run scratch directory.
_rec_tmp() {
  if [ -n "${REC_TMP:-}" ] && [ -d "$REC_TMP" ]; then return 0; fi
  omb_tmp_init || return 1
  REC_TMP=$OMB_TMP/records
  (umask 077 && mkdir -p "$REC_TMP")
}

# _rec_num FILE — REC_NUM: the one number in FILE (wc's output), or failure.
_rec_num() {
  REC_NUM=$(tr -d ' \t\n' <"$1") || return 1
  case "$REC_NUM" in '' | *[!0-9]*) return 1 ;; esac
}

# rec_admit_file FAMILY OP PATH — a stored document: its size is read first
# and a document over its limit is refused unread; then a bounded private
# copy is admitted.
rec_admit_file() {
  local family=$1 op=$2 path=$3 st
  REC_REASON="" REC_AT=0 REC_N=0
  _rec_family "$family" || { _rec_refuse schema; return 1; }
  _rec_tmp || { _rec_refuse io; return 1; }
  [ -f "$path" ] || { _rec_refuse io; return 1; }
  wc -c <"$path" >"$REC_TMP/size"
  st=$?
  if [ "$st" != 0 ] || ! _rec_num "$REC_TMP/size"; then _rec_refuse io; return 1; fi
  [ "$REC_NUM" -le "$REC_MAX_BYTES" ] || { _rec_refuse too-large; return 1; }
  head -c "$((REC_MAX_BYTES + 1))" "$path" >"$REC_TMP/doc"
  st=$?
  [ "$st" = 0 ] || { _rec_refuse io; return 1; }
  rec_admit_copied "$family" "$op" "$REC_TMP/doc"
}

# rec_admit_copied FAMILY OP COPY — steps 2 to 6 over a copy made with
# `head -c LIMIT+1` (step 1), whose own status the caller has checked. OP is
# the operation a response answers, or - (a request names its own).
rec_admit_copied() {
  local family=$1 op=$2 f=$3 st out
  REC_REASON="" REC_AT=0 REC_N=0
  _rec_family "$family" || { _rec_refuse schema; return 1; }
  _rec_tmp || { _rec_refuse io; return 1; }
  out=$REC_TMP/out

  # 2. Size.
  wc -c <"$f" >"$out"
  st=$?
  if [ "$st" != 0 ] || ! _rec_num "$out"; then _rec_refuse io; return 1; fi
  [ "$REC_NUM" -le "$REC_MAX_BYTES" ] || { _rec_refuse too-large; return 1; }
  REC_SIZE=$REC_NUM

  # Every stage's status is its own $?, never PIPESTATUS: a trap handler that
  # runs after a pipeline (a caught cancel or hangup) replaces PIPESTATUS
  # before the next command can read it. The size is checked, so the files
  # between stages are bounded.

  # 3. Byte class: TAB, LF and 0x20–0x7E only.
  LC_ALL=C tr -d '\011\012\040-\176' <"$f" >"$out.bytes"
  st=$?
  [ "$st" = 0 ] || { _rec_refuse io; return 1; }
  wc -c <"$out.bytes" >"$out"
  st=$?
  if [ "$st" != 0 ] || ! _rec_num "$out"; then _rec_refuse io; return 1; fi
  [ "$REC_NUM" = 0 ] || { _rec_refuse byte; return 1; }

  # 4. Termination: not empty, and the last byte is LF.
  tail -c 1 <"$f" >"$out.bytes"
  st=$?
  [ "$st" = 0 ] || { _rec_refuse io; return 1; }
  od -An -tx1 <"$out.bytes" >"$out"
  st=$?
  [ "$st" = 0 ] || { _rec_refuse io; return 1; }
  [ "$(tr -d ' \n' <"$out")" = 0a ] || { _rec_refuse eof; return 1; }

  # 5. Framing and canonical form: one C-locale awk pass, lines from the
  # first; within a line, each check over the whole line in this order.
  LC_ALL=C awk -v hdr="$REC_HDR" -v maxrec="$REC_MAX_RECS" '
    function refuse(r) { printf "%s %d\n", r, NR; done = 1; exit 0 }
    {
      if (length($0) > 16384) refuse("line")
      if ($0 == "") refuse("blank")
      if ($0 ~ /^\t/ || $0 ~ /\t$/ || index($0, "\t\t") > 0) refuse("tab")
      if (NR == 1) { if ($0 != hdr) refuse("header"); next }
      n = split($0, f, "\t")
      if (n < 2 || f[1] !~ /^[a-z][a-z-]*$/ || length(f[1]) > 24) refuse("key")
      for (i = 2; i <= n; i++) {
        p = index(f[i], "=")
        if (p == 0) refuse("key")
        k = substr(f[i], 1, p - 1)
        if (k !~ /^[a-z][a-z0-9_]*$/ || length(k) > 32) refuse("key")
        v[i] = substr(f[i], p + 1)
      }
      for (i = 2; i <= n; i++)
        if (length(v[i]) > 4096 || v[i] !~ /^([A-Za-z0-9._~\/:@+,-]|%[0-9A-F][0-9A-F])*$/) refuse("value")
      for (i = 2; i <= n; i++) if (index(v[i], "%00") > 0) refuse("nul-escape")
      for (i = 2; i <= n; i++)
        if (v[i] ~ /%(2[B-F]|3[0-9A]|4[0-9A-F]|5[0-9AF]|6[1-9A-F]|7[0-9AE])/) refuse("non-canonical")
      if (maxrec > 0 && NR - 1 > maxrec) refuse("too-large")
    }
    END { if (!done) printf "ok %d\n", NR }' "$f" >"$out"
  st=$?
  [ "$st" = 0 ] || { _rec_refuse io; return 1; }
  read -r REC_REASON REC_AT <"$out" || { _rec_refuse io; return 1; }
  case "$REC_REASON" in
    ok) REC_REASON="" REC_LINES=$REC_AT REC_AT=0 ;;
    line | blank | tab | header | key | value | nul-escape | non-canonical | too-large) return 1 ;;
    *) _rec_refuse io ; return 1 ;;
  esac

  # A stored document's seal: its last line, over every byte before it.
  if [ "$REC_SEALED" = 1 ]; then
    _rec_seal_ok "$f" || { _rec_refuse seal; return 1; }
  fi

  # 6. Only now does Bash split lines on TAB and hold every record to its
  # schema; splitting can no longer normalise anything.
  _rec_schema "$family" "$op" "$f"
}

# _rec_sha256_prefix FILE N — REC_SHA: the SHA-256 of FILE's first N bytes,
# every stage's status checked (its own $?, as in rec_admit_copied).
_rec_sha256_prefix() {
  local out=$REC_TMP/sha st
  head -c "$2" "$1" >"$out.bytes"
  st=$?
  [ "$st" = 0 ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 <"$out.bytes" >"$out"
  else
    sha256sum <"$out.bytes" >"$out"
  fi
  st=$?
  [ "$st" = 0 ] || return 1
  read -r REC_SHA _ <"$out" || return 1
  _whole "$REC_SHA" '^[0-9a-f]{64}$'
}

# _rec_seal_ok FILE — exactly one seal line, the last, whose digest is the
# SHA-256 of every byte before it.
_rec_seal_ok() {
  local f=$1 st lastline
  LC_ALL=C awk 'BEGIN { n = 0 } /^seal\t/ { n++; at = NR } END { printf "%d %d %d\n", n, at, NR }' "$f" >"$REC_TMP/seals"
  st=$?
  [ "$st" = 0 ] || return 1
  local n at nr
  read -r n at nr <"$REC_TMP/seals" || return 1
  [ "$n" = 1 ] && [ "$at" = "$nr" ] || return 1
  lastline=$(tail -n 1 "$f") || return 1
  case "$lastline" in "seal	sha256="*) ;; *) return 1 ;; esac
  _whole "${lastline#seal	sha256=}" '^[0-9a-f]{64}$' || return 1
  _rec_sha256_prefix "$f" "$((REC_SIZE - ${#lastline} - 1))" || return 1
  [ "$REC_SHA" = "${lastline#seal	sha256=}" ]
}

# _rec_counts_reset / _rec_count TYPE / _rec_count_add TYPE — per-type
# record counts, in globals (no command substitution per record).
_rec_counts_reset() {
  local t
  for t in $REC_ORDER; do eval "REC_C_${t}=0 REC_S_${t}="; done
}
_rec_count() { eval "REC_CNT=\$REC_C_$1"; }

# _rec_schema FAMILY OP FILE — step 6: order, cardinality, fields and types;
# for a response, exactly one result, the last record.
_rec_schema() {
  local family=$1 op=$2 f=$3 line t no=1 lastidx=0 result=0 rest
  REC_N=0
  _rec_counts_reset
  {
    IFS= read -r line
    while IFS= read -r line; do
      no=$((no + 1))
      t=${line%%	*}
      # A sealed document's last line is its seal, checked already.
      [ "$REC_SEALED" = 1 ] && [ "$no" = "$REC_LINES" ] && break
      # A request names its operation in its first record.
      if [ "$family" = req ] && [ "$REC_N" = 0 ]; then
        [ "$t" = req ] || { _rec_refuse schema "$no"; return 1; }
        rest="	${line#*	}"
        op=${rest#*	op=}
        op=${op%%	*}
        case "$rest" in "	op="*) ;; *) _rec_refuse schema "$no"; return 1 ;; esac
        _rec_type_ok "enum(hello|snapshot|detail|validate|execute)" "$op" || { _rec_refuse type "$no"; return 1; }
      fi
      if [ "$family" = res ] && [ "$result" = 1 ]; then
        if [ "$t" = result ]; then _rec_refuse result "$no"; else _rec_refuse after-result "$no"; fi
        return 1
      fi
      _rec_index "$t"
      if [ "$REC_IDX" -le 0 ] || [ "$REC_IDX" -lt "$lastidx" ]; then _rec_refuse schema "$no"; return 1; fi
      lastidx=$REC_IDX
      _rec_card "$family" "$op" "$t" || { _rec_refuse schema "$no"; return 1; }
      _rec_count "$t"
      case "$REC_CARD" in
        -) _rec_refuse schema "$no"; return 1 ;;
        1 | \?) [ "$REC_CNT" = 0 ] || { _rec_refuse schema "$no"; return 1; } ;;
      esac
      _rec_record_ok "$family" "$t" "$line" || { _rec_refuse "$REC_WHY" "$no"; return 1; }
      eval "REC_C_$t=\$((REC_CNT + 1))"
      REC_T[REC_N]=$t
      REC_L[REC_N]=$line
      REC_N=$((REC_N + 1))
      [ "$t" = result ] && result=1
    done
  } <"$f"
  REC_OP=$op
  if [ "$family" = res ] && [ "$result" = 0 ]; then
    _rec_refuse result 0
    return 1
  fi
  # A request's operation comes from its `req` record: none, no request.
  if [ "$family" = req ] && [ "$REC_N" = 0 ]; then
    _rec_refuse schema 0
    return 1
  fi
  for t in $REC_ORDER; do
    _rec_card "$family" "$op" "$t" || continue
    _rec_count "$t"
    case "$REC_CARD" in
      1 | +) [ "$REC_CNT" -ge 1 ] || { _rec_refuse schema 0; return 1; } ;;
    esac
  done
  return 0
}

# _rec_index TYPE — REC_IDX: the type's place in the family's order, or 0.
_rec_index() {
  local t i=0
  REC_IDX=0
  for t in $REC_ORDER; do
    i=$((i + 1))
    [ "$t" = "$1" ] && REC_IDX=$i && return 0
  done
}

# _rec_field_raw LINE KEY — REC_RAW: the written value of KEY's first field.
_rec_field_raw() {
  local rest="	${1#*	}	"
  case "$rest" in *"	$2="*) ;; *) REC_RAW="" && return 1 ;; esac
  REC_RAW=${rest#*"	$2="}
  REC_RAW=${REC_RAW%%	*}
}

# _rec_record_ok FAMILY TYPE LINE — every field in the schema's order, lists
# in their place, nothing extra, each value its type; REC_WHY on failure.
_rec_record_ok() {
  local family=$1 t=$2 line=$3 spec name typ mod v kind="" i=0 nf c ukey="" uk seen IFS
  _rec_spec "$family" "$t" || { REC_WHY=schema; return 1; }
  IFS='	'
  set -f
  # shellcheck disable=SC2206 # admitted: single TABs between fields, no glob (set -f)
  local -a flds=(${line#*	})
  set +f
  IFS=' '
  nf=${#flds[@]}
  set -f
  for spec in $REC_SPEC; do
    name=${spec%%:*}
    typ=${spec#*:}
    mod=""
    case "$typ" in *\? | *\* | *+) mod=${typ#"${typ%?}"} typ=${typ%?} ;; esac
    case "$mod" in
      \* | +)
        c=0
        while [ "$i" -lt "$nf" ] && [ "${flds[i]%%=*}" = "$name" ]; do
          v=${flds[i]#*=}
          if [ -z "$v" ]; then
            case "$typ" in bytes | text) ;; *) REC_WHY='type' && set +f && return 1 ;; esac
          else
            _rec_type_ok "$typ" "$v" "$kind" || { REC_WHY='type' && set +f && return 1; }
          fi
          c=$((c + 1)) i=$((i + 1))
        done
        if [ "$mod" = + ] && [ "$c" = 0 ]; then REC_WHY=schema && set +f && return 1; fi
        ;;
      *)
        if [ "$i" -ge "$nf" ] || [ "${flds[i]%%=*}" != "$name" ]; then REC_WHY=schema && set +f && return 1; fi
        v=${flds[i]#*=}
        if [ -z "$v" ]; then
          [ "$mod" = "?" ] || { REC_WHY=schema && set +f && return 1; }
        else
          _rec_type_ok "$typ" "$v" "$kind" || { REC_WHY='type' && set +f && return 1; }
        fi
        [ "$name" = kind ] && kind=$v
        i=$((i + 1))
        ;;
    esac
  done
  set +f
  [ "$i" = "$nf" ] || { REC_WHY=schema; return 1; }
  # Bounds the schema states in words.
  case "$family.$t" in
    req.page)
      _rec_field_raw "$line" limit
      if [ "$REC_RAW" -lt 1 ] || [ "$REC_RAW" -gt 500 ]; then REC_WHY='type' && return 1; fi
      ;;
    req.arg)
      _rec_count arg
      [ "$REC_CNT" -lt 64 ] || { REC_WHY=schema; return 1; }
      ;;
  esac
  # A record the schema says is unique by its key.
  _rec_unique "$family" "$t"
  if [ -n "$REC_UKEYS" ]; then
    for uk in $REC_UKEYS; do
      _rec_field_raw "$line" "$uk"
      ukey="$ukey$REC_RAW/"
    done
    eval "seen=\$REC_S_$t"
    case "$seen" in *"
$ukey
"*) REC_WHY=schema && return 1 ;; esac
    [ -n "$seen" ] || seen="
"
    eval "REC_S_$t=\$seen\$ukey'
'"
  fi
  return 0
}

# rec_get I KEY — the decoded value of KEY (its first field) in admitted
# record I.
rec_get() {
  _rec_field_raw "${REC_L[$1]}" "$2" || return 1
  rec_dec "$REC_RAW"
}

# rec_find TYPE — REC_AT_I: the index of the first admitted record of TYPE.
rec_find() {
  local i=0
  while [ "$i" -lt "$REC_N" ]; do
    [ "${REC_T[i]}" = "$1" ] && REC_AT_I=$i && return 0
    i=$((i + 1))
  done
  return 1
}

# rec_line_v TYPE KEY VALUE [KEY VALUE ...] — REC_LINE: one record (no LF),
# each value in its canonical written form.
rec_line_v() {
  REC_LINE=$1
  shift
  while [ $# -ge 2 ]; do
    rec_enc_v "$2"
    REC_LINE="$REC_LINE	$1=$REC_ENC"
    shift 2
  done
}

# rec_line TYPE KEY VALUE [KEY VALUE ...] — one record, printed with its LF.
rec_line() {
  rec_line_v "$@"
  printf '%s\n' "$REC_LINE"
}

# rec_seal_write FILE — append the seal: the SHA-256 of every byte so far.
rec_seal_write() {
  local sha
  if command -v shasum >/dev/null 2>&1; then
    sha=$(shasum -a 256 "$1") || return 1
  else
    sha=$(sha256sum "$1") || return 1
  fi
  sha=${sha%% *}
  _whole "$sha" '^[0-9a-f]{64}$' || return 1
  printf 'seal\tsha256=%s\n' "$sha" >>"$1"
}
