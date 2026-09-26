#!/usr/bin/env bash
# The static checks M14 gate 1 relies on (docs/TESTING.md, docs/FRONTEND.md →
# The security boundary): the frontend's reach, sup-no-setsid,
# sup-one-spawner, proto-no-shell-text, proto-managed-prompt,
# diag-class-static, diag-mutator-tty-class, sup-mutating-daemon-classification,
# and sup-shared-critical's static half (the Shared creation's code, byte for
# byte the accepted baseline's).
# shellcheck disable=SC2015,SC2016 # ok/fail always return 0; literal $ in patterns
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-static"
BASELINE=2edb76a7de3f78ec90927ac93d5eec3a84636253

# rust_prod FILE... — the frontend's production code: every line outside a
# #[cfg(test)] item, as FILE:LINE: TEXT.
rust_prod() {
  awk '
    /^[[:space:]]*#\[cfg\(test\)\]/ { skip = 1; depth = 0; open = 0; next }
    skip {
      o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
      depth += o - c
      if (o > 0) open = 1
      if (open && depth <= 0) skip = 0
      next
    }
    /^[[:space:]]*\/\// { next }
    { print FILENAME ":" FNR ": " $0 }' "$@"
}
SRC=$(find "$REPO/frontend/src" -name '*.rs' | LC_ALL=C sort)
# shellcheck disable=SC2086 # a file list
PROD=$(rust_prod $SRC)

# --- The frontend's reach (docs/FRONTEND.md → The security boundary) ----------------
spawns=$(printf '%s\n' "$PROD" | grep -E 'Command::new|process::Command|posix_spawn|libc::fork|execv')
assert_eq "$(printf '%s\n' "$spawns" | grep -c 'Command::new')" 1 "the frontend spawns in one place"
assert_contains "$spawns" 'Command::new(self.home.join("omarchy-bootstrap"))' "and what it spawns is the core, from the tool's own home"
assert_eq "$(printf '%s\n' "$PROD" | grep -cE '\.env\("OMB_(SESSION_|HOME|DRY_RUN|FIXTURE|FRONTEND_DEV|TEST_)|set_var|remove_var')" 0 \
  "the frontend never sets the session variables (it passes the launcher's through; only OMB_EVENTS is its own)"
assert_eq "$(printf '%s\n' "$PROD" | grep -c '\.env(')" 1 "one environment value set: the request's spool"
assert_contains "$(printf '%s\n' "$PROD" | grep '\.env(')" '.env("OMB_EVENTS", &events)' "OMB_EVENTS"
assert_eq "$(printf '%s\n' "$PROD" | grep -cE 'EnableMouseCapture|EnableBracketedPaste|PushKeyboardEnhancementFlags|EnableFocusChange')" 0 \
  "mouse capture, bracketed paste, keyboard enhancement: never turned on"
assert_eq "$(printf '%s\n' "$PROD" | grep -cE 'File::open|OpenOptions' | tr -d ' ')" "$(printf '%s\n' "$PROD" | grep -E 'File::open|OpenOptions' | grep -c 'src/core.rs\|src/lib.rs')" \
  "files are opened only by the process model (core.rs) and the trace (lib.rs)"

# --- sup-no-setsid: no new group or session, no ignored or blocked signal -----------
assert_eq "$(printf '%s\n' "$PROD" | grep -cE 'setsid|setpgid|\.process_group\(|setpgrp')" 0 "sup-no-setsid: the frontend never calls setsid or setpgid"
assert_eq "$(printf '%s\n' "$PROD" | grep -cE 'SIG_IGN|SigIgn|sigprocmask|pthread_sigmask|signal::ignore|SIG_BLOCK')" 0 \
  "sup-no-setsid: the frontend never ignores or blocks a signal"
assert_contains "$(printf '%s\n' "$PROD" | grep 'flag::register(SIGINT')" "signal_hook::flag::register(SIGINT" "SIGINT is caught (a handler), so a child after exec has the default"
assert_contains "$(printf '%s\n' "$PROD" | grep 'flag::register(SIGQUIT')" "register(SIGQUIT" "and SIGQUIT"
BASH_CODE="$REPO/omarchy-bootstrap $REPO/lib/core.sh $REPO/lib/frontend.sh $REPO/lib/records.sh"
# shellcheck disable=SC2086 # a file list
bash_code() { grep -nH '' $BASH_CODE | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#'; }
# The same, with quoted text blanked: for scans where a quoted word is data.
bash_calls() { bash_code | sed -e "s/\"[^\"]*\"/\"\"/g" -e "s/'[^']*'/''/g"; }
assert_eq "$(bash_calls | grep -cE '(^|[^a-z_-])(setsid|setpgid)([^a-z_-]|$)|set -m')" 0 "sup-no-setsid: the launcher and the core never make a new group or session"
assert_eq "$(bash_code | grep -cE "trap ('' ?|\"\" ?)(INT|QUIT|TSTP|TERM|HUP)")" 0 "sup-no-setsid: the launcher and the core never ignore a signal"

# --- sup-one-spawner -------------------------------------------------------------------
threads=$(printf '%s\n' "$PROD" | grep 'thread::spawn')
assert_eq "$(printf '%s\n' "$threads" | grep -c .)" 2 "two threads besides the main one: the spool reader and the read watcher"
reader=$(awk '/^fn reader\(/ { f = 1 } f { print } f && /^}/ { exit }' "$REPO/frontend/src/core.rs")
assert_eq "$(printf '%s\n' "$reader" | grep -cE 'File::open|OpenOptions|Command|pipe\(|spawn_command')" 0 \
  "sup-one-spawner: the reader thread opens and spawns nothing (it reads its already-open handle)"
watcher=$(awk '/^pub fn watch_reads\(/ { f = 1 } f { print } f && /^}/ { exit }' "$REPO/frontend/src/terminal.rs")
[ -n "$watcher" ] && ok || fail "the read watcher is found"
assert_eq "$(printf '%s\n' "$watcher" | grep -cE 'File::open|OpenOptions|Command|pipe\(|spawn_command|event::')" 0 \
  "sup-one-spawner: the read watcher opens, spawns and reads nothing (two counters, then an exit)"
follow=$(awk '/^pub fn follow</ { f = 1 } f { print } f && /^}/ { exit }' "$REPO/frontend/src/core.rs")
assert_eq "$(printf '%s\n' "$follow" | grep -cE 'File::open|OpenOptions|Command|pipe\(')" 0 "nor does the loop it runs"
spool_writes=$(grep -n '>>"\$CORE_EVENTS"' "$REPO/lib/core.sh")
assert_eq "$(printf '%s\n' "$spool_writes" | grep -c .)" 2 "sup-one-spawner: the spool is appended in two places"
for fn in core_emit core_op_snapshot; do
  body=$(awk -v f="^$fn\\\\(\\\\) \\\\{" '$0 ~ f { p = 1 } p { print } p && /^}/ { exit }' "$REPO/lib/core.sh")
  assert_contains "$body" '>>"$CORE_EVENTS"' "one is $fn"
done
assert_eq "$(bash_code | grep -cE '\$\((core_emit|core_result|core_message)|(core_emit|core_result|core_message)[^#]*&[[:space:]]*$|\|[[:space:]]*(core_emit|core_result|core_message)')" 0 \
  "sup-one-spawner: no record is written from a command substitution, a pipeline stage or a background job"

# --- proto-no-shell-text ------------------------------------------------------------------
# Every eval, reviewed: each is indexed by a literal or by a record type the
# family's order has already admitted.
evals=$(bash_code | grep -E '(^|[^a-z_])eval ' | sed 's/^[^:]*\/\([^/]*\):[0-9]*:[[:space:]]*/\1: /')
want='records.sh: eval "REC_CARD=\${$i}"
records.sh: for t in $REC_ORDER; do eval "REC_C_${t}=0 REC_S_${t}="; done
records.sh: _rec_count() { eval "REC_CNT=\$REC_C_$1"; }
records.sh: eval "REC_C_$t=\$((REC_CNT + 1))"
records.sh: eval "seen=\$REC_S_$t"
records.sh: eval "REC_S_$t=\$seen\$ukey'"'"''
assert_eq "$evals" "$want" "proto-no-shell-text: every eval in the protocol code is on the reviewed list"
# Every file sourced at a command position is a library of the tool itself.
sourced=$(bash_code | sed 's/^[^:]*:[0-9]*://' | grep -E '(^[[:space:]]*|[;&|({][[:space:]]*)(source|\.)[[:space:]]+' |
  grep -vE '(source|\.)[[:space:]]+"\$(OMB_HOME|1)/lib/[a-z]+\.sh"')
assert_eq "$sourced" "" "proto-no-shell-text: nothing but the tool's own libraries is ever sourced"
# _rec_count and REC_C_/REC_S_ are reached only after _rec_index admitted the type.
schema=$(awk '/^_rec_schema\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$REPO/lib/records.sh")
idx=$(printf '%s\n' "$schema" | grep -n '_rec_index "\$t"' | head -1 | cut -d: -f1)
cnt=$(printf '%s\n' "$schema" | grep -n '_rec_count "\$t"' | head -1 | cut -d: -f1)
[ -n "$idx" ] && [ -n "$cnt" ] && [ "$idx" -lt "$cnt" ] && ok || fail "a record's type is admitted by the order before it names a counter"

# --- proto-managed-prompt: nothing on a managed path can ask -------------------------
assert_eq "$(grep -cE '(^|[^a-z_])sudo([^a-z_]|$)' "$REPO/lib/core.sh" "$REPO/lib/frontend.sh" | awk -F: '{s += $2} END {print s}')" 0 \
  "proto-managed-prompt: the core and the launcher's frontend code run no sudo at all in this gate"
child=$(awk '/^core_child\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$REPO/lib/core.sh")
assert_contains "$child" '(_core_worker_exec "$CORE_WORKERS" "$cmd" "$@") </dev/null >/dev/null 2>&1' \
  "proto-managed-prompt and diag-class-static: a mutating child reads /dev/null and writes nowhere that can fill"
read_child=$(awk '/^core_child_read\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$REPO/lib/core.sh")
assert_eq "$(printf '%s\n' "$read_child" | grep -c '</dev/null >"$CORE_FUNC"')" 2 "a read child reads /dev/null"

# --- The child registry's rules: diag-class-static, diag-mutator-tty-class,
# --- sup-mutating-daemon-classification --------------------------------------------------
reg_check() { # LINE... — "ok" or the refusal, for a registry holding these entries
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    # shellcheck source=lib/core.sh
    . "$REPO/lib/core.sh"
    f=$OMB_TMP_REG
    { printf 'omb-children 1\n' && printf '%s\n' "$@"; } >"$f"
    rec_seal_write "$f"
    if core_registry_check "$f"; then printf ok; else printf '%s' "$CORE_REG_WHY"; fi
    omb_cleanup
  )
}
export OMB_TMP_REG
OMB_TMP_REG=$(t_tmp)/children.omb
entry() { # ACTION CMD CLASS OUT ERR TTY DETACHES [OWNER CHECK]
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    rec_line child action "$1" cmd "$2" class "$3" stdout "$4" stderr "$5" tty "$6" detaches "$7" owner "${8:-}" check "${9:-}"
  )
}
assert_eq "$(reg_check "$(entry a tests/x read functional diagnostics none no)")" ok "a read child with diagnostics is accepted"
assert_contains "$(reg_check "$(entry a tests/x mutating null null needs no)")" "a child that needs a terminal is a handoff" \
  "diag-mutator-tty-class: class=mutating with tty=needs is refused"
assert_contains "$(reg_check "$(entry a tests/x read null null needs no)")" "a child that needs a terminal is a handoff" \
  "diag-mutator-tty-class: any child that needs a terminal is a handoff"
assert_contains "$(reg_check "$(entry a tests/x mutating diagnostics null none no)")" "only a read child has diagnostics streams" \
  "diag-mutator-tty-class: a mutating entry with diagnostics streams is refused"
assert_contains "$(reg_check "$(entry a bin/sshd mutating null null none no)")" "sshd leaves something running" \
  "sup-mutating-daemon-classification: a program known to daemonise, registered as detaches=no, is refused"
assert_contains "$(reg_check "$(entry a bin/tool mutating null null none owned)")" "needs its owner and completion check" \
  "sup-mutating-daemon-classification: a detaching managed entry without an owner and check is refused"
assert_eq "$(reg_check "$(entry a bin/sshd mutating null null none owned "rescue server unit" rescue.sshd-listening)")" ok \
  "a detaching entry that names its owner and check is accepted"
assert_eq "$(reg_check "$(entry a bin/sshd handoff functional functional needs no)")" ok "a detaching program run as a handoff is accepted"
assert_contains "$(reg_check "$(entry a /usr/bin/x read functional diagnostics none no)")" "not a path inside the tool" "a registry command outside the tool is refused"
assert_contains "$(reg_check "$(entry a ../x read functional diagnostics none no)")" "not a path inside the tool" "and one that climbs out of it"
# The reviewed registry itself.
(
  t_load >/dev/null 2>&1
  # shellcheck source=lib/records.sh
  . "$REPO/lib/records.sh"
  # shellcheck source=lib/core.sh
  . "$REPO/lib/core.sh"
  if core_registry_check "$REPO/data/children.omb"; then echo ok; else echo "$CORE_REG_WHY"; fi
  omb_cleanup
) >"$OMB_TMP_REG.out"
assert_eq "$(cat "$OMB_TMP_REG.out")" ok "diag-class-static: data/children.omb passes its rules"
acts=$(sed -n 's/^CORE_TEST_ACTIONS="\(.*\)"$/\1/p' "$REPO/lib/core.sh")
[ -n "$acts" ] && ok || fail "diag-class-static: the core's test actions could not be read"
for a in $acts; do
  grep -q "^child	action=$a	" "$REPO/data/children.omb" && ok || fail "diag-class-static: $a, which the core runs, has a registry entry"
done
assert_eq "$(grep -c '^child	' "$REPO/data/children.omb")" 3 "the registry holds only the three test children: no installer operation yet"
assert_eq "$(grep -o 'core_child "[^"]*"' "$REPO/lib/core.sh" | sort -u | tr '\n' ' ')" 'core_child "$action" ' \
  "the core starts children only through the registry, by action"

# --- sup-shared-critical (static): the Shared creation is the accepted baseline's --------
if git -C "$REPO" cat-file -e "$BASELINE^{commit}" 2>/dev/null; then
  git -C "$REPO" show "$BASELINE:lib/shared.sh" >"$OMB_TMP_REG.shared"
  cmp -s "$OMB_TMP_REG.shared" "$REPO/lib/shared.sh" && ok || fail "sup-shared-critical: lib/shared.sh is byte-identical to the accepted baseline's"
  interval() { awk '/^  if ! run sudo -v; then$/ { f = 1 } f { print } f && /run sudo -n diskutil addPartition/ { exit }' "$1"; }
  a=$(interval "$OMB_TMP_REG.shared")
  b=$(interval "$REPO/lib/shared.sh")
  [ -n "$a" ] && [ "$a" = "$b" ] && ok || fail "sup-shared-critical: from sudo -v through the final read to addPartition, the code is the baseline's"
  assert_eq "$(printf '%s\n' "$b" | grep -cE 'core_|rec_|OMB_EVENTS|_core_ps|ps -|spool')" 0 \
    "sup-shared-critical: no record, process-table reading or spool write inside the interval"
  for f in macos.sh storage.sh asahi.sh state.sh common.sh; do
    git -C "$REPO" diff --quiet "$BASELINE" -- "lib/$f" && ok || fail "lib/$f, which the Shared creation calls, is the accepted baseline's"
  done
else
  fail "the accepted baseline $BASELINE is not in this clone (CI checks out with fetch-depth: 0)"
fi

t_done test-static
