#!/usr/bin/env bash
# The differential corpus (docs/TESTING.md → proto-diff-*, proto-invalid-schemas,
# proto-code-kind, proto-op-records, proto-golden-*): one document per case,
# written into DIR, and DIR/cases listing "NAME FAMILY OP EXPECTED" per case,
# EXPECTED being "ok" or the reason code. The Bash admission (tests/test-records.sh)
# and the Rust admission (frontend/tests/proto_diff.rs) both read this one
# generator's output, so both judge exactly the same bytes.
#
#   tests/proto/corpus.sh DIR
set -u
out=${1:?usage: corpus.sh DIR}
mkdir -p "$out" || exit 1
: >"$out/cases" || exit 1

S=0123456789abcdef
H64=5f2ec1a05f2ec1a05f2ec1a05f2ec1a05f2ec1a05f2ec1a05f2ec1a05f2ec1a0
GEN=9e3779b97f4a7c159e3779b97f4a7c159e3779b97f4a7c159e3779b97f4a7c15
HELLO="hello	core=0.3.0	commit=2edb76a7de3f78ec90927ac93d5eec3a84636253	source=c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00	proto=1	platform=macos	arch=arm64	user=user	ceiling=act	dry_run=0	fixture=0"
HELLO_PLAN=${HELLO/ceiling=act/ceiling=plan}
RESULT="result	status=done	code=ok	text=	next="
TOKEN="omb2:enc%3D1,user%3Dalex,host%3Dm1pro,kmap%3Dus,tz%3DAmerica/New_York,loc%3Den_US.UTF-8,ssh%3D0,gh%3Doctocat,linux%3D250,shared%3D150,dev%3D1,plan%3D1a2b3c4d,prof%3D3f09c2a1"

# case NAME FAMILY OP EXPECTED — the document is stdin, taken byte for byte.
case_() {
  cat >"$out/$1.doc" || exit 1
  printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >>"$out/cases"
}
# lines L... — each argument as one line, LF-terminated.
lines() { printf '%s\n' "$@"; }
req() { lines "omb-req 1" "$@"; }
res() { lines "omb-res 1" "$@"; }
# rep CHAR N — N copies of CHAR.
rep() { head -c "$2" /dev/zero | tr '\000' "$1"; }

REQ_HELLO="req	op=hello	proto=1	frontend=0.1.0	session=$S"
REQ_SNAP="req	op=snapshot	proto=1	frontend=0.1.0	session=$S"
REQ_VAL="req	op=validate	proto=1	frontend=0.1.0	session=$S"
REQ_EXEC="req	op=execute	proto=1	frontend=0.1.0	session=$S"
REQ_DETAIL="req	op=detail	proto=1	frontend=0.1.0	session=$S"

# --- The golden examples (docs/PROTOCOL.md → Golden examples) ---------------------
req "$REQ_HELLO" | case_ proto-golden-hello.req req - ok
res "$HELLO" "$RESULT" | case_ proto-golden-hello.res res hello ok
req "$REQ_SNAP" "scope	name=shared" | case_ proto-golden-snapshot.req req - ok
res "$HELLO" "generation	id=$GEN	total=0" "stage	name=shared	state=current	basis=machine	by=	at=	detail=" \
  "fact	scope=shared	key=shared.state	label=Shared	value=planned,%20not%20created	state=info" \
  "code	kind=token	value=$TOKEN" \
  "action	id=shared.create	scope=shared	label=Create%20Shared	intent=act	gate=create	terminal=handoff	cancel=0	basis=$H64	explain=" \
  "$RESULT" | case_ proto-golden-snapshot.res res snapshot ok
req "$REQ_DETAIL" "page	scope=profile	kind=inventory	generation=$GEN	offset=0	limit=2" | case_ proto-golden-detail.req req - ok
res "$HELLO" "generation	id=$GEN	total=212" \
  "row	kind=inventory	key=brew:ripgrep	col=ripgrep	col=brew	col=15.2.0	col=pacman%20ripgrep" \
  "row	kind=inventory	key=brew:node	col=node	col=brew	col=22.11.0	col=mise%20node@22" \
  "$RESULT" | case_ proto-golden-detail.res res detail ok
req "$REQ_VAL" "select	action=plan.save" "arg	name=linux_size	value=250GB" "arg	name=shared_size	value=150GB" | case_ proto-golden-validate.req req - ok
res "$HELLO_PLAN" "answer	n=1	prompt=New%20size%20for%20macOS	value=532543MiB	bytes=558411808768" \
  "answer	n=2	prompt=New%20OS%20size	value=244140MiB	bytes=255999344640" \
  "normal	name=linux_size	value=250000000000" "normal	name=shared_size	value=150000000000" \
  "review	action=plan.save	basis=$H64" "$RESULT" | case_ proto-golden-validate.res res validate ok
res "$HELLO_PLAN" "invalid	name=linux_size	code=leading-zero	text=Sizes%20cannot%20start%20with%200" \
  "result	status=refused	code=invalid	text=	next=" | case_ proto-golden-validate-refused.res res validate ok
req "$REQ_EXEC" "exec	action=bundle.approve	basis=$H64	confirm=" "arg	name=code	value=ombbundle-3f09c2a1b7d45e60-26d1" | case_ proto-golden-approve.req req - ok
req "$REQ_EXEC" "exec	action=shared.create	basis=$H64	confirm=create" | case_ proto-golden-execute.req req - ok
res "$HELLO" "code	kind=ombshare	value=ombshare-1a2b3c4d-3c1f9e2d7a60-4149" "message	level=ok	text=Shared%20created%20as%20disk0s7" \
  "result	status=done	code=ok	text=	next=Boot%20Linux%20and%20run%20shared%20activate" | case_ proto-golden-execute.res res execute ok
res "$HELLO" "result	status=cancelled	code=cancelled	text=2%20of%205%20items%20done	next=" | case_ proto-golden-cancelled.res res execute ok
for c in "token $TOKEN" "ombdone ombdone-1a2b3c4d-8f2a41c0e9b7-f5f0" "ombshare ombshare-1a2b3c4d-3c1f9e2d7a60-4149" "ombbundle ombbundle-3f09c2a1b7d45e60-26d1"; do
  res "$HELLO" "code	kind=${c%% *}	value=${c#* }" "$RESULT" | case_ "proto-golden-codes.${c%% *}" res execute ok
done

# --- proto-diff-*: Bash and Rust agree ----------------------------------------------
req "$REQ_HELLO" | case_ proto-diff-canonical.hello req - ok
{ printf '\000'; req "$REQ_HELLO"; } | case_ proto-diff-nul.first req - byte
{ printf 'omb-req 1\nreq\top=hel\000lo\tproto=1\tfrontend=0.1.0\tsession=%s\n' "$S"; } | case_ proto-diff-nul.value req - byte
{ printf 'omb-req 1\nreq\to\000p=hello\tproto=1\tfrontend=0.1.0\tsession=%s\n' "$S"; } | case_ proto-diff-nul.key req - byte
{ req "$REQ_HELLO"; printf '\000'; } | case_ proto-diff-nul.last req - byte
req "req	op=hello		proto=1	frontend=0.1.0	session=$S" | case_ proto-diff-tab-double req - tab
req "	$REQ_HELLO" | case_ proto-diff-tab-lead req - tab
req "$REQ_HELLO	" | case_ proto-diff-tab-trail req - tab
printf 'omb-req 1\n%s\r\n' "$REQ_HELLO" | case_ proto-diff-byte-cr req - byte
printf 'omb-req 1\nreq\top=hello\tproto=1\tfrontend=0.1.0\tsession=%s\001\n' "$S" | case_ proto-diff-byte-ctrl req - byte
printf 'omb-req 1\nreq\top=hello\tproto=1\tfrontend=0.1.0\tsession=%s\177\n' "$S" | case_ proto-diff-byte-del req - byte
printf 'omb-req 1\nreq\top=hello\tproto=1\tfrontend=0.1.\303\251\tsession=%s\n' "$S" | case_ proto-diff-byte-high req - byte
printf 'omb-req 1\nreq\top=hello\tproto=1\tfrontend=\033[2J\tsession=%s\n' "$S" | case_ proto-diff-byte-esc req - byte
req "$REQ_VAL" "select	action=x" "arg	name=v	value=%20%25%0A%09" | case_ proto-diff-escape-valid req - ok
req "$REQ_VAL" "select	action=x" "arg	name=v	value=a%2fb" | case_ proto-diff-escape-lower req - value
req "$REQ_VAL" "select	action=x" "arg	name=v	value=a%4" | case_ proto-diff-escape-short.end req - value
req "$REQ_VAL" "select	action=x" "arg	name=v	value=%G1" | case_ proto-diff-escape-short.g req - value
req "$REQ_VAL" "select	action=x" "arg	name=v	value=%41" | case_ proto-diff-escape-unneeded.41 req - non-canonical
req "$REQ_VAL" "select	action=x" "arg	name=v	value=%2D" | case_ proto-diff-escape-unneeded.2d req - non-canonical
req "$REQ_VAL" "select	action=x" "arg	name=v	value=a%00b" | case_ proto-diff-escape-nul req - nul-escape
req "$REQ_VAL" "select	action=x" "arg	name=v	value=a b" | case_ proto-diff-raw-space req - value
req "$REQ_VAL" "select	action=x" "arg	name=v	value=a=b" | case_ proto-diff-raw-equals req - value
printf 'omb-req 1\n%s' "$REQ_HELLO" | case_ proto-diff-eof req - eof
printf '' | case_ proto-diff-empty req - eof
{ lines "omb-req 1" ""; lines "$REQ_HELLO"; } | case_ proto-diff-blank req - blank
{ printf 'omb-req 1\n%s\narg\tname=v\tvalue=' "$REQ_VAL"; rep a $((16385 - 17)); printf '\n'; } | case_ proto-diff-line-long req - line
{ printf 'omb-req 1\n%s\nselect\taction=x\narg\tname=v\tvalue=' "$REQ_VAL"; rep a 4097; printf '\n'; } | case_ proto-diff-value-long req - value
{ printf 'omb-req 1\n%s\n' "$REQ_VAL"; rep a 65536; printf '\n'; } | case_ proto-diff-request-large.bytes req - too-large
{
  printf 'omb-req 1\n%s\nselect\taction=x\n' "$REQ_VAL"
  i=0
  while [ "$i" -lt 511 ]; do printf 'arg\tname=a%d\tvalue=x\n' "$i"; i=$((i + 1)); done
} | case_ proto-diff-request-large.records req - too-large
{ printf 'omb-res 1\n%s\nmessage\tlevel=info\ttext=' "$HELLO"; rep a 8388608; printf '\n'; } | case_ proto-diff-response-large.bytes res execute too-large
{
  printf 'omb-res 1\n%s\n' "$HELLO"
  # 65 535 messages and the result: 65 537 records.
  awk 'BEGIN { for (i = 0; i < 65535; i++) print "message\tlevel=info\ttext=x" }'
  printf '%s\n' "$RESULT"
} | case_ proto-diff-response-large.records res execute too-large
lines "omb-rex 1" "$REQ_HELLO" | case_ proto-diff-header.name req - header
lines "omb-req 2" "$REQ_HELLO" | case_ proto-diff-header.version req - header
lines "$REQ_HELLO" | case_ proto-diff-header.missing req - header
req "req	Op=hello	proto=1	frontend=0.1.0	session=$S" | case_ proto-diff-key.upper req - key
req "$REQ_HELLO	$(rep k 33)=1" | case_ proto-diff-key.long req - key
req "$REQ_HELLO	1k=1" | case_ proto-diff-key.digit req - key
req "$REQ_SNAP" "scope	name=shared	name=disk" | case_ proto-diff-dup-key req - schema
res "$HELLO" "generation	id=$GEN	total=0" "param	action=a	name=n	type=choice	kind=	required=1	choice=c1	choice=c2	choice=c3" "$RESULT" | case_ proto-diff-list res snapshot ok
req "$REQ_SNAP" "scope	name=shared	extra=1" | case_ proto-diff-unknown-key req - schema
req "$REQ_SNAP" "scope	name=shared" "bogus	x=1" | case_ proto-diff-unknown-record req - schema
req "$REQ_EXEC" "exec	basis=$H64	action=shared.create	confirm=create" | case_ proto-diff-order req - schema
req "$REQ_EXEC" "exec	action=shared.create	confirm=create" | case_ proto-diff-missing req - schema
req "req	op=hello	proto=	frontend=0.1.0	session=$S" | case_ proto-diff-empty-required req - schema
# A request of its header alone: the grammar wants one record or more, and
# `req` is required.
lines "omb-req 1" | case_ proto-diff-header-only req - schema
req "$REQ_EXEC" "exec	action=shared.create	basis=$H64" | case_ proto-diff-optional-absent req - schema
res "$HELLO" "generation	id=$GEN	total=1" "row	kind=k	key=x	col=a	col=	col=b" "$RESULT" | case_ proto-diff-list-empty.bytes res detail ok
res "$HELLO" "generation	id=$GEN	total=0" "param	action=a	name=n	type=choice	kind=	required=1	choice=c1	choice=" "$RESULT" | case_ proto-diff-list-empty.id res snapshot type
req "$REQ_HELLO" "$REQ_HELLO" | case_ proto-diff-dup-record.req req - schema
req "$REQ_VAL" "select	action=x" "arg	name=v	value=1" "arg	name=v	value=2" | case_ proto-diff-dup-record.arg req - schema
for v in 01 -1 +1 1234567890123456789; do
  req "req	op=hello	proto=$v	frontend=0.1.0	session=$S" | case_ "proto-diff-uint.$v" req - type
done
res "${HELLO/dry_run=0/dry_run=2}" "$RESULT" | case_ proto-diff-bool res hello type
req "req	op=hello	proto=1	frontend=0.1.0	session=0123456789ABCDEF" | case_ proto-diff-hex.upper req - type
req "req	op=hello	proto=1	frontend=0.1.0	session=0123" | case_ proto-diff-hex.length req - type
for v in A -x "$(rep a 129)" a%20b; do
  n=$v
  [ "${#v}" -gt 10 ] && n=129
  req "req	op=hello	proto=1	frontend=$v	session=$S" | case_ "proto-diff-id.$n" req - type
done
res "$HELLO" "message	level=info	text=%1B%5B2J" "$RESULT" | case_ proto-diff-text-control.text res execute type
req "$REQ_VAL" "select	action=x" "arg	name=v	value=%1B%5B2J" | case_ proto-diff-text-control.bytes req - ok
for v in %C3 %C0%AF %ED%A0%80; do
  res "$HELLO" "message	level=info	text=a$v" "$RESULT" | case_ "proto-diff-text-utf8.$v" res execute type
done
res "$HELLO" "message	level=ok	text=caf%C3%A9%20%E2%9C%93" "$RESULT" | case_ proto-diff-text-utf8-valid res execute ok
res "$HELLO" "message	level=info	text=a%C2%85" "$RESULT" | case_ proto-diff-text-c1 res execute type
res "$HELLO" "$RESULT" "message	level=info	text=x" | case_ proto-diff-after-result res execute after-result
{ res "$HELLO" "$RESULT"; printf 'X'; } | case_ proto-diff-after-result-partial res execute eof
res "$HELLO" "message	level=info	text=x" | case_ proto-diff-no-result res execute result
res "$HELLO" "$RESULT" "$RESULT" | case_ proto-diff-two-results res execute result

# A sealed stored document (the lock): valid, a wrong seal, bytes after the seal.
LOCK_BODY=$(printf 'omb-frontend-lock 1\nfrontend\tversion=0.1.0\tproto=1\tsource_commit=%s\tinputs_digest=%s\trust=1.88.0\nartifact\ttarget=aarch64-apple-darwin\turl=https://example.invalid/omb-tui\tsize=3145728\tsha256=%s\tminos=13.5\tglibc_max=\tinterp=\talign_min=\n' \
  2edb76a7de3f78ec90927ac93d5eec3a84636253 "$H64" "$H64"; printf x)
LOCK_BODY=${LOCK_BODY%x}
if command -v shasum >/dev/null 2>&1; then
  seal=$(printf '%s' "$LOCK_BODY" | shasum -a 256 | awk '{print $1}')
else
  seal=$(printf '%s' "$LOCK_BODY" | sha256sum | awk '{print $1}')
fi
printf '%sseal\tsha256=%s\n' "$LOCK_BODY" "$seal" | case_ proto-diff-seal.valid lock - ok
printf '%sseal\tsha256=%s\n' "$LOCK_BODY" "$H64" | case_ proto-diff-seal.wrong lock - seal
printf '%sseal\tsha256=%s\nartifact\ttarget=x\n' "$LOCK_BODY" "$seal" | case_ proto-diff-seal.after lock - seal
printf '%s' "$LOCK_BODY" | case_ proto-diff-seal.missing lock - seal

# --- proto-invalid-schemas: the invalid examples of docs/PROTOCOL.md ----------------
req "$REQ_VAL" | case_ proto-invalid-schemas.no-select req - schema
req "$REQ_EXEC" "exec	action=shared.create	confirm=create" | case_ proto-invalid-schemas.no-basis req - schema
res "$HELLO" "code	kind=ombdone	value=omb2:enc%3D1" "$RESULT" | case_ proto-invalid-schemas.code-kind res execute type
req "$REQ_SNAP" "scope	name=shared	extra=1" | case_ proto-invalid-schemas.extra req - schema
req "$REQ_SNAP" "scope	name=shared	name=disk" | case_ proto-invalid-schemas.dup-field req - schema
req "$REQ_HELLO" "# a note" | case_ proto-invalid-schemas.comment req - key
res "$HELLO" "$RESULT" "message	level=info	text=x" | case_ proto-invalid-schemas.after-result res execute after-result
{ res "$HELLO" "$RESULT"; printf 'x'; } | case_ proto-invalid-schemas.byte-after res execute eof

# --- proto-code-kind: codes held to their kind ----------------------------------------
code_res() { res "$HELLO" "code	kind=$1	value=$2" "$RESULT"; }
code_res token "omb2:enc%3D1,color%3Dred" | case_ proto-code-kind.token-unknown res execute type
code_res token "omb2:enc%3D1,enc%3D0" | case_ proto-code-kind.token-repeated res execute type
# "omb2:tz=" is 8 bytes; tz has no length rule of its own, so only the
# 512-byte bound separates these two.
code_res token "omb2:tz%3D$(rep a 504)" | case_ proto-code-kind.token-512 res execute ok
code_res token "omb2:tz%3D$(rep a 505)" | case_ proto-code-kind.token-513 res execute type
code_res token "omb2:user%3Droot" | case_ proto-code-kind.token-bad-value res execute type
code_res ombdone ombdone-1a2b3c4d-8f2a41c0e9b7-f5f1 | case_ proto-code-kind.check-digits res execute type
code_res ombdone "$TOKEN" | case_ proto-code-kind.token-as-ombdone res execute type
code_res ombbundle ombbundle-3F09C2A1B7D45E60-26D1 | case_ proto-code-kind.bundle-upper res execute type
code_res ombshare ombdone-1a2b3c4d-8f2a41c0e9b7-f5f0 | case_ proto-code-kind.wrong-prefix res execute type

# --- proto-op-records: a request record where its operation forbids it ----------------
req "$REQ_VAL" "select	action=x" | case_ proto-op-records.validate-ok req - ok
req "$REQ_VAL" "page	scope=profile	kind=inventory	generation=$GEN	offset=0	limit=2" "select	action=x" | case_ proto-op-records.page-in-validate req - schema
req "$REQ_SNAP" "scope	name=shared" "arg	name=v	value=1" | case_ proto-op-records.arg-in-snapshot req - schema
req "$REQ_EXEC" "select	action=x" "exec	action=shared.create	basis=$H64	confirm=" | case_ proto-op-records.select-in-execute req - schema
req "$REQ_DETAIL" "page	scope=profile	kind=inventory	generation=$GEN	offset=0	limit=501" | case_ proto-op-records.page-limit req - type
exit 0
