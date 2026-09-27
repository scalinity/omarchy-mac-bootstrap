#!/usr/bin/env bash
# The record format and admission in Bash (docs/PROTOCOL.md → §1, §2): the
# differential corpus (tests/proto/corpus.sh), the value functions, and a
# tool failing during admission. frontend/tests/proto_diff.rs holds the Rust
# side to the same corpus.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031 # ok/fail always return 0; literal $ in shims; PATH set only inside a substitution, on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-records"
t_load
# shellcheck source=lib/records.sh
. "$REPO/lib/records.sh"

corpus=$(t_tmp)
"$T_BASH" "$REPO/tests/proto/corpus.sh" "$corpus" || fail "the corpus generator failed"

# --- proto-diff-*, proto-invalid-schemas, proto-code-kind, proto-op-records ----------
n=0
while read -r name family op want; do
  n=$((n + 1))
  rec_admit_file "$family" "$op" "$corpus/$name.doc"
  got=${REC_REASON:-ok}
  assert_eq "$got" "$want" "$name ($family/$op)"
done <"$corpus/cases"
[ "$n" -gt 100 ] && ok || fail "the corpus has only $n cases"

# proto-diff-escape-valid: admitted, and decoded exactly.
rec_admit_file req - "$corpus/proto-diff-escape-valid.doc"
rec_find arg && v=$(rec_get "$REC_AT_I" value; printf x)
assert_eq "${v%x}" " %
	" "%20 %25 %0A %09 decode to space, percent, LF and TAB"

# proto-diff-list: a list key three times, in order.
rec_admit_file res snapshot "$corpus/proto-diff-list.doc"
rec_find param && assert_eq "$(printf '%s' "${REC_L[$REC_AT_I]}" | tr '\t' '\n' | grep '^choice=' | tr '\n' ' ')" \
  "choice=c1 choice=c2 choice=c3 " "list elements keep their order"

# --- Values: encoding is canonical and round-trips ----------------------------------
assert_eq "$(rec_enc 'safe-._~/:@+,Az09')" 'safe-._~/:@+,Az09' "a safe byte is written as itself"
assert_eq "$(rec_enc 'a b=%é')" 'a%20b%3D%25%C3%A9' "every other byte is % and upper-case hex (high bytes too, on bash 3.2)"
assert_eq "$(rec_enc "$(printf 'x\033[2J')")" 'x%1B%5B2J' "an escape sequence is encoded, never raw"
v=$(rec_dec "$(rec_enc "$(printf 'tab\there nl\nend')")"; printf x)
assert_eq "${v%x}" "$(printf 'tab\there nl\nend')" "decode(encode(x)) is x"
assert_eq "$(rec_line res x 'a b' y '')" "$(printf 'res\tx=a%%20b\ty=')" "rec_line writes canonical fields, empty for none"

# --- rec_get_into: a decoded value, byte for byte, in a shell variable (L01) --------
# A `bytes` value may end in LF; `$(rec_get ...)` drops every trailing LF, so
# every library caller reads values with rec_get_into.
opdoc=$(t_tmp)/op.omb
for want in "$(printf 'end\n.')" "$(printf 'end\n\n.')" "$(printf 'end\t\n.')" "ordinary text."; do
  want=${want%.}
  shown=$(printf '%s' "$want" | od -An -c | tr -s ' ')
  {
    printf 'omb-op 1\n'
    rec_line op action test.mutate scope journey basis "$(printf '%064d' 0)" session "$want" \
      state running finding "" pid 1 start x boot b at 2026-01-01T00:00:00Z
  } >"$opdoc"
  rec_seal_write "$opdoc"
  rec_admit_file op - "$opdoc" || fail "a session of [$shown] admits ($REC_REASON)"
  got=""
  rec_get_into got 0 session
  [ "$got" = "$want" ] && ok || fail "rec_get_into keeps [$shown] byte for byte"
done
v="$(rec_get 0 session)"
[ "$v" = "ordinary text" ] && ok || fail "rec_get still decodes a value without trailing bytes"
# A name that is not a name is refused, and nothing of it is evaluated.
flag=$(t_tmp)/evaluated
rec_get_into "x[\$(touch $flag)]" 0 session
assert_eq "$?" 2 "rec_get_into refuses a name that is not one"
[ ! -e "$flag" ] && ok || fail "and evaluates nothing"
# A field the record does not have leaves the variable empty, not stale.
got=stale
rec_get_into got 0 nosuchkey
assert_eq "$?:$got" "1:" "a missing field empties the variable"

# --- proto-admit-io: a failing tool refuses the document, never admits it ----------
# However it fails: printing nothing, printing what the real tool would (the
# right answer, then a failing status), or printing part of that. Its status
# is judged apart from its output (M02).
good="$corpus/proto-golden-hello.req.doc"
for tool in head wc tr tail od awk; do
  real=$(command -v "$tool")
  for mode in nothing whole part; do
    shimdir=$(t_tmp)
    case "$mode" in
      nothing) printf '#!/bin/sh\nexit 3\n' ;;
      whole) printf '#!/bin/sh\n"%s" "$@"\nexit 3\n' "$real" ;;
      part) printf '#!/bin/sh\n"%s" "$@" | dd bs=1 count=1 2>/dev/null\nexit 3\n' "$real" ;;
    esac >"$shimdir/$tool"
    chmod +x "$shimdir/$tool"
    got=$(PATH="$shimdir:$PATH" && rec_admit_file req - "$good"; printf '%s' "${REC_REASON:-ok}")
    assert_eq "$got" io "a $tool that prints $mode of its answer and fails refuses with io"
  done
done
# The review's case: the termination check's tr prints exactly the expected
# 0a, then fails.
shimdir=$(t_tmp)
printf '#!/bin/sh\nif [ "$1" = -d ] && [ "$2" = " \\n" ]; then printf 0a; exit 3; fi\nexec "%s" "$@"\n' "$(command -v tr)" >"$shimdir/tr"
chmod +x "$shimdir/tr"
got=$(PATH="$shimdir:$PATH" && rec_admit_file req - "$good"; printf '%s' "${REC_REASON:-ok}")
assert_eq "$got" io "proto-admit-io: a tr that prints 0a and fails, at the last-byte check, refuses with io"
# The same document admits with the real tools: the refusals above are the tools'.
rec_admit_file req - "$good"
assert_eq "${REC_REASON:-ok}" ok "the document itself is admissible"

# A stored document over its limit is refused unread.
big=$(t_tmp)/big
head -c 70000 /dev/zero | tr '\000' a >"$big"
rec_admit_file lock - "$big"
assert_eq "$REC_REASON" too-large "a stored document over 64 KiB is refused by its size"

# --- rec_seal_write: a sealed document admits ----------------------------------------
d=$(t_tmp)/child.omb
{
  printf 'omb-children 1\n'
  rec_line child action test.read cmd tests/children/fake-read class read stdout functional stderr diagnostics tty none detaches no owner '' check ''
} >"$d"
rec_seal_write "$d"
rec_admit_file children - "$d"
assert_eq "${REC_REASON:-ok}" ok "a document sealed by rec_seal_write admits"
printf 'x' >>"$d"
rec_admit_file children - "$d"
assert_eq "$REC_REASON" eof "a byte appended after the seal: termination first"

omb_cleanup
t_done test-records
