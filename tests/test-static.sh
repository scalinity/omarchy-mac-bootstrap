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
for fn in core_emit _core_emit_body; do
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

# --- sup-eintr-one-substitution: the core's own code, and Bash 5.2's lost trap ---------
# Bash 5.2 loses a trap that runs while a command holding two command
# substitutions side by side is expanded (tests/bash-trap-comsub.sh). The
# core's own files hold none; the baseline's two-substitution commands, which
# stay byte for byte (above), are the ones the storm test may name on 5.2.
twosub() {
  awk '/^[[:space:]]*#/ { next }
    { s = $0; d = 0; top = 0; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "$" && substr(s, i + 1, 1) == "(" && substr(s, i + 2, 1) != "(") { if (d == 0) top++; d++; i++ }
        else if (c == "(") d++
        else if (c == ")") { if (d > 0) d-- }
      }
      if (top >= 2) printf "%s:%d\n", FILENAME, FNR }' "$@"
}
assert_eq "$(cd "$REPO" && twosub lib/core.sh lib/records.sh)" "" \
  "sup-eintr-one-substitution: no command of the core's own holds two command substitutions"
assert_eq "$(cd "$REPO" && twosub lib/common.sh lib/state.sh | tr '\n' ' ')" "lib/common.sh:138 lib/common.sh:155 lib/state.sh:269 " \
  "and the baseline's that the core calls are the three the storm test may name"

# --- frontend-check-route (static): its own route, and nothing of any other --------------
# fbody FILE NAME — the function NAME's lines in FILE.
fbody() { awk -v f="^$2\\\\(\\\\) \\\\{" '$0 ~ f { p = 1 } p { print } p && /^}/ { exit }' "$1"; }
route=$(awk '/^  if \[ "\$cmd" = frontend-check \]; then$/ { p = 1 } p { print } p && /^  fi$/ { exit }' "$REPO/omarchy-bootstrap")
[ -n "$route" ] && ok || fail "frontend-check-route: the route is found"
assert_eq "$(printf '%s\n' "$route" | sed -n '$!p' | tail -n 1 | tr -d ' ')" "return" "frontend-check-route: the route ends by returning, whatever the check's outcome"
route_line=$(grep -n '^  if \[ "\$cmd" = frontend-check \]; then$' "$REPO/omarchy-bootstrap" | cut -d: -f1)
for later in 'state_init || return 1' 'state_lock || return 1' 'log_event start ' 'mac_main install' 'lx_main default' '_usage_error "OMB_FIXTURE, OMB_TEST_RECORD'; do
  n=$(grep -nF -- "$later" "$REPO/omarchy-bootstrap" | head -1 | cut -d: -f1)
  [ -n "$n" ] && [ -n "$route_line" ] && [ "$route_line" -lt "$n" ] && ok || fail "frontend-check-route: dispatched before '$later'"
done
check_code=$(printf '%s\n' "$route"
  for fn in fe_check fe_check_dry fe_check_run fe_check_exchanges _fe_check_stop _fe_check_failed _fe_check_left; do
    fbody "$REPO/lib/frontend.sh" "$fn"
  done)
assert_eq "$(printf '%s\n' "$check_code" | grep -vE '^[[:space:]]*#' | sed -e "s/\"[^\"]*\"/\"\"/g" -e "s/'[^']*'/''/g" | grep -cE '(^|[^a-z_])(mac_main|lx_main|mac_resume|lx_resume|dev_main|cmd_[a-z]+|state_lock|state_set|state_must_set|log_event|fetch_upstream|run|sudo|fe_run)([^a-z_]|$)')" 0 \
  "frontend-check-route: the check calls none of the installer's routing, the command handlers, run, sudo, the run lock or the log"
assert_eq "$(printf '%s\n' "$check_code" | grep -c 'Continuing in text\|continuing in the text')" 0 "frontend-check-route: no outcome of the check continues in text"
snap_code=$(for fn in core_check_op core_check_snapshot _core_check_body _core_emit_body; do fbody "$REPO/lib/core.sh" "$fn"; done)
[ "$(printf '%s\n' "$snap_code" | grep -c '^[a-z_]*() {')" = 4 ] && ok || fail "frontend-check-route: the check's snapshot path is found"
assert_eq "$(printf '%s\n' "$snap_code" | grep -vE '^[[:space:]]*#' | grep -cE 'core_barrier|core_reconcile|core_op_(read|write|remove|path)|core_failed_text|core_action_info|core_available|core_basis|core_child|core_execute|core_op_execute|_core_snapshot_body|state_lock|OMB_FIXTURE')" 0 \
  "frontend-check-route: the check's snapshot path reads no barrier, reconciles nothing, touches no operation record and starts nothing"
# frontend-check-no-render-claim (static): the check's report never says
# what was drawn; it names the exchanges and the session's end.
reports=$(printf '%s\n' "$check_code" | grep -E '_fe_check_say|ui_note|ui_would|ui_kv|ui_section')
[ -n "$reports" ] && ok || fail "frontend-check-no-render-claim: the check's report lines are found"
assert_eq "$(printf '%s\n' "$reports" | grep -ciE 'dashboard|drawn|draw |shown|display|render|receiv|seen|visible')" 0 \
  "frontend-check-no-render-claim: no report of the check says what was drawn, shown or received"
assert_contains "$reports" "answered hello and the journey snapshot, every exchange of the session ended done" "frontend-check-no-render-claim: the completed report names the exchanges"
# The session purpose: set in the check's session alone, removed from every
# other the launcher starts.
assert_eq "$(grep -c 'OMB_SESSION_PURPOSE=frontend-check' "$REPO/lib/frontend.sh")" 1 "frontend-check-read-session: one place sets the purpose"
assert_contains "$(fbody "$REPO/lib/frontend.sh" fe_check_run)" "OMB_SESSION_PURPOSE=frontend-check" "and it is the check's session"
assert_contains "$(fbody "$REPO/lib/frontend.sh" fe_run)" "unset OMB_SESSION_PURPOSE" "frontend-check-read-session: every other session the launcher starts drops an inherited one"

# --- test-owned-signal-only: tests signal only processes they own ---------------------
# A name or a command line matches the developer's own programs too; tests
# signal a PID they recorded (held to its start time) or a group they made
# (tests/lib.sh → t_signal). The words are split so this check does not match itself.
kills="p""kill|p""grep|kill""all"
matched=$(grep -rnE "(^|[^a-zA-Z_])($kills)([^a-zA-Z_]|\$)" "$REPO/tests" "$REPO/frontend/tests" "$REPO/.github" \
  --include='*.sh' --include='*.rs' --include='*.yml' --include='fake-*' --include='probe-*' 2>/dev/null)
assert_eq "$matched" "" "test-owned-signal-only: no test finds a process to signal by its name or command line"

t_done test-static
