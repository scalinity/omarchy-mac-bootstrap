#!/usr/bin/env bash
# The accepted baseline is the oracle (docs/TESTING.md → Equivalence with the
# accepted baseline): M14 gate 1 changes the entrypoint's startup and routing
# (the core's entry, the new seams' refusals, --no-tui, the frontend only in
# fixture mode on a terminal), so every text command and flow must behave
# exactly as commit 2edb76a's does. Both entrypoints run the same fixtures
# with the same answers in the same sealed environment; the output, the exit
# status, every command recorded instead of run, and every file left in the
# state directory must be equal, after a fixed normaliser removes only what
# varies from run to run (times, temporary paths, PIDs). The comparison is with
# the accepted baseline itself, not with the candidate's own text path.
# shellcheck disable=SC2015 # ok/fail always return 0
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-baseline"
baseline_fixture_before=$(t_snapshot "$FIX")
BASELINE=2edb76a7de3f78ec90927ac93d5eec3a84636253
T=$(t_tmp)

if ! git -C "$REPO" cat-file -e "$BASELINE^{commit}" 2>/dev/null; then
  fail "the accepted baseline $BASELINE is not in this clone (CI checks out with fetch-depth: 0)"
  t_done test-baseline
  exit
fi
# The baseline's tree, as files (git archive: no worktree is registered).
mkdir -p "$T/base"
git -C "$REPO" archive "$BASELINE" | tar -x -C "$T/base" || fail "the baseline could not be extracted"
# And the commit before frontend-check's route (docs/TESTING.md →
# frontend-check-default-unchanged, frontend-check-install-unchanged): every
# command routes as it did there, --help gaining its one line.
PRE_ROUTE=569d67e728d4cee1f345134724e259e52d702af5
mkdir -p "$T/pre"
if git -C "$REPO" cat-file -e "$PRE_ROUTE^{commit}" 2>/dev/null; then
  git -C "$REPO" archive "$PRE_ROUTE" | tar -x -C "$T/pre" || fail "$PRE_ROUTE could not be extracted"
else
  fail "$PRE_ROUTE, the commit before frontend-check's route, is not in this clone"
fi

# date_shim DIR — one fixed clock for every tree: all read it only as
# `date -u +FORMAT`, and values made from a time (the Shared plan's digest,
# its codes) must come out the same. BSD date takes -r SECONDS, GNU date
# -d @SECONDS.
date_shim() {
  cat >"$1/date" <<'EOF'
#!/bin/sh
if /bin/date -u -r 0 >/dev/null 2>&1; then exec /bin/date -r 1790000000 "$@"; fi
exec /bin/date -d @1790000000 "$@"
EOF
  chmod +x "$1/date"
}

# run_one TREE DIR FIXTURE INPUT ARGS... — like t_cli, for either tree, into
# DIR. Run in the current shell: nothing it sets may be lost to a subshell.
run_one() {
  local tree=$1 d=$2 fixture=$3 input=$4 shims fx=""
  shift 4
  mkdir -p "$d/tmp" "$d/home"
  shims=$(t_shims "$d")
  date_shim "$shims"
  case "$fixture" in '') ;; /*) fx=$fixture ;; *) fx="$FIX/$fixture" ;; esac
  # shellcheck disable=SC2086 # B_ENV is a list of assignments by design
  printf '%b' "$input" | env -i PATH="$shims:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$d/home" TMPDIR="$d/tmp" \
    LANG=en_US.UTF-8 TERM=dumb OMB_STATE_DIR="$d/state" OMB_FIXTURE="$fx" SHIM_LOG="$d/shims.log" \
    OMB_TEST_RECORD="$d/record" ${B_ENV:-} "$T_BASH" "$tree/omarchy-bootstrap" "$@" >"$d/out" 2>&1
  printf '%s' "$?" >"$d/rc"
  touch "$d/record" "$d/shims.log"
}

# spin_out FILE — the transcript with each spinner's frames, however many a
# run's timing drew before its line was cleared, as one SPIN[label] (once,
# one extra "Checking GitHub" frame failed run 38146161907). Nothing else in
# it changes.
spin_out() {
  # shellcheck disable=SC2016 # Perl source: perl expands its own variables
  LC_ALL=C perl -CSD -pe 'BEGIN { $c = qr/(?:\e\[[0-9;]*m)*/; $g = qr/[\x{280B}\x{2819}\x{2839}\x{2838}\x{283C}\x{2834}\x{2826}\x{2827}\x{2807}\x{280F}|\/\-\\]/ }
    s/(?:   $c$g$c $c([^\e\n]*?)$c)+(?=\e\[2K)/SPIN[$1]/g' "$1"
}

# normal TREE DIR — everything a run left, with only its per-run values
# replaced: the run's folder, the tree's own path, times, suffixes and PIDs;
# the transcript's spinner frames are one marker each (spin_out).
normal() {
  local tree=$1 d=$2 f
  {
    echo "== rc $(cat "$d/rc")"
    echo "== out"
    spin_out "$d/out"
    echo "== record"
    cat "$d/record"
    echo "== shims"
    cat "$d/shims.log"
    echo "== state"
    if [ -d "$d/state" ]; then
      (cd "$d/state" && find . -print | LC_ALL=C sort)
      find "$d/state" -type f | LC_ALL=C sort | while read -r f; do
        echo "-- ${f#"$d"/state}"
        cat "$f"
      done
    fi
  } | sed -E \
    -e "s#$d#RUN#g" \
    -e "s#$FIX#FIX#g" \
    -e "s#$tree#TREE#g" \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/TIME/g' \
    -e 's/[0-9]{8}T[0-9]{6}Z/STAMP/g' \
    -e 's/omarchy-bootstrap-[0-9]{8}\.log/omarchy-bootstrap-DATE.log/g' \
    -e 's/(omarchy-bootstrap|\.state\.env|downloads\/[a-z-]+\.sh-STAMP|shared-[a-z-]+\.env)\.[A-Za-z0-9]{6}/\1.XXXXXX/g' \
    -e 's/(-STAMP)\.[A-Za-z0-9]{6}/\1.XXXXXX/g' \
    -e 's/^[0-9]+ TIME [A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]+ [0-9:]{8} [0-9]{4}$/PID TIME STARTED/'
}

# agree NAME A B [TREE] — the run A of TREE (the accepted baseline by
# default) and the candidate's run B left the same thing behind.
agree() {
  local tree=${4:-$T/base} what="the accepted baseline"
  [ "$tree" = "$T/pre" ] && what="$PRE_ROUTE, before frontend-check's route (frontend-check-default-unchanged)"
  normal "$tree" "$2" >"$2.norm"
  normal "$REPO" "$3" >"$3.norm"
  case "${B_DELTA:-}" in
    M16-status-report)
      assert_eq "$(grep -cx ' ▍Journey' "$3.norm")" 1 'M16-status-report: one appended Journey section'
      awk '/^ ▍Journey$/ {journey=1; next} /^== record$/ {journey=0} journey {print}' "$3.norm" >"$3.stages"
      assert_eq "$(awk '{sub(/:$/,"",$1); printf "%s%s",sep,$1; sep=" "}' "$3.stages")" \
        'survey profile resolve plan asahi omarchy shared restore verify done' 'M16-status-report: exactly ten ordered stage lines'
      assert_eq "$(awk '$2 !~ /^(done|current|todo|skipped|blocked)(:|$)/ {bad++} END {print bad+0}' "$3.stages")" 0 'M16-status-report: closed stage states'
      # Drop only the appended blank, heading and ten checked lines. Every
      # earlier byte, exit status, recorded command and state file still agrees.
      awk '
        /^ ▍Journey$/ {held=""; have=0; skip=10; next}
        skip {skip--; next}
        {if (have) print held; held=$0; have=1}
        END {if (have) print held}' "$3.norm" >"$3.delta"
      mv "$3.delta" "$3.norm"
      ;;
    doctor-ssh-findings)
      # Only the two fixed M15-C findings on these off-SSH fixtures, and
      # their one extra pass in the existing summary, may differ.
      ssh='   [PASS] SSH policy               off: sshd is not running'
      alarm='   [INFO] Image alarm account      password state cannot be read here; the image sets alarm / alarm. As root, check passwd -S alarm; lock it with sudo passwd -l alarm'
      assert_eq "$(grep -cxF "$ssh" "$3.norm")" 1 'doctor-ssh-findings: one fixed policy finding'
      assert_eq "$(grep -cxF "$alarm" "$3.norm")" 1 'doctor-ssh-findings: one fixed image account finding'
      bp=$(sed -n 's/^   \([0-9]*\) passed .*/\1/p' "$2.norm")
      assert_eq "$(sed -n 's/^   \([0-9]*\) passed .*/\1/p' "$3.norm")" "$((bp + 1))" 'doctor-ssh-findings: exactly one added pass'
      awk -v ssh="$ssh" -v alarm="$alarm" -v bp="$bp" '$0 == ssh || $0 == alarm { next }
        /^   [0-9]+ passed / { sub(/^   [0-9]+ passed /, "   " bp " passed ") } { print }' "$3.norm" >"$3.delta"
      mv "$3.delta" "$3.norm"
      ;;
    start-disable-ssh)
      assert_eq "$(grep -cx 'systemctl disable --now sshd' "$3/record")" 1 'start-disable-ssh: exactly one recorded disable'
      assert_eq "$(head -1 "$3/record")" 'systemctl disable --now sshd' 'start-disable-ssh: disable precedes setup'
      assert_eq "$(grep -c '^systemctl ' "$2/record")" 0 'start-disable-ssh: BASE never disabled SSH'
      # Drop these exact new records only; the setup command, every other
      # transcript line and the remaining state still compare byte for byte.
      awk '
        $0 == "   ✓ SSH is stopped and disabled. Enable key-only access later through ./omarchy-bootstrap dev -> SSH." { next }
        $0 == "systemctl disable --now sshd" { next }
        $0 == "TIME [linux] exec   systemctl disable --now sshd" { skip=1; next }
        skip && $0 == "TIME [linux] exit   0 (recorded by test harness, not executed)" { skip=0; next }
        { skip=0; print }' "$3.norm" >"$3.delta"
      mv "$3.delta" "$3.norm"
      ;;
  esac
  if cmp -s "$2.norm" "$3.norm"; then
    ok
  else
    fail "$1: the candidate differs from $what"
    diff "$2.norm" "$3.norm" | head -20
  fi
}

# same NAME FIXTURE INPUT ARGS... — the baseline, the commit before
# frontend-check's route and the candidate agree, each in its own fresh
# folder (SAME_PRE=0: the baseline alone).
N=0
same() {
  local name=$1 fixture=$2 input=$3 B_DELTA=${B_DELTA:-}
  case "$name" in doctor\ on\ linux-*) B_DELTA=doctor-ssh-findings ;; status\ on\ *) B_DELTA=M16-status-report ;; esac
  shift 3
  N=$((N + 1))
  run_one "$T/base" "$T/runs/base-$N" "$fixture" "$input" "$@"
  run_one "$REPO" "$T/runs/cand-$N" "$fixture" "$input" "$@"
  agree "$name" "$T/runs/base-$N" "$T/runs/cand-$N"
  if [ "${SAME_PRE:-1}" = 1 ]; then
    run_one "$T/pre" "$T/runs/pre-$N" "$fixture" "$input" "$@"
    agree "$name" "$T/runs/pre-$N" "$T/runs/cand-$N" "$T/pre"
  fi
}

# The comparison can fail: two different commands are told apart.
N=$((N + 1))
run_one "$T/base" "$T/runs/base-$N" "" "" --version
run_one "$REPO" "$T/runs/cand-$N" "" "" --help
normal "$T/base" "$T/runs/base-$N" >"$T/runs/base-$N.norm"
normal "$REPO" "$T/runs/cand-$N" >"$T/runs/cand-$N.norm"
if cmp -s "$T/runs/base-$N.norm" "$T/runs/cand-$N.norm"; then fail "the comparison cannot tell --version from --help"; else ok; fi

# --- Everywhere: the command surface -------------------------------------------------------
# --help: the two listed deltas, frontend-check's row (docs/FRONTEND.md →
# Help) and the read command operation SCOPE's (docs/PROTOCOL.md → The
# operation-record diagnostic), and nothing else, against each earlier tree.
N=$((N + 1))
run_one "$REPO" "$T/runs/cand-$N" "" "" --help
help_row='     frontend-check       check that the interface starts: downloads it once, changes nothing else'
op_row="     operation SCOPE      what a scope's operation record shows and what stays unknown (read-only)"
# Phase A's rows: operation clear and the migration's commands, each a named
# delta (docs/TESTING.md → *Equivalence with the accepted baseline*).
new_rows=$(printf '%s\n' \
  "     operation clear SCOPE move an operation record that cannot be read aside, after typed clear" \
  "     scan                 macOS: what this Mac holds that could come to Linux (read-only)" \
  "     profile [show]       macOS: choose what comes to Linux and save it; show prints it (read-only)" \
  "     export [DIR]         macOS: write the chosen environment to Shared or DIR" \
  "     restore [DIR]        Linux: restore the environment from Shared or DIR" \
  "     restore status       Linux: restore progress (read-only)" \
  "     restore undo         Linux: undo restored files that have not changed" \
  "     debug                read-only debugging brief and machine facts" \
  "     report               fresh final check table and verdict (read-only)" \
  "     qualify [status]     Shared cross-OS round trip; status is read-only")
assert_eq "$(grep -cxF -- "$help_row" "$T/runs/cand-$N/out")" 1 "--help lists frontend-check with its one line"
assert_eq "$(grep -cxF -- "$op_row" "$T/runs/cand-$N/out")" 1 "--help lists operation SCOPE with its one line"
while IFS= read -r row; do
  assert_eq "$(grep -cxF -- "$row" "$T/runs/cand-$N/out")" 1 "--help lists [${row#     }] with its one line"
done <<EOF_ROWS
$new_rows
EOF_ROWS
printf '%s\n' "$help_row" "$op_row" "$new_rows" >"$T/runs/cand-$N/rows"
grep -vxF -f "$T/runs/cand-$N/rows" "$T/runs/cand-$N/out" >"$T/runs/cand-$N/out.less"
for tree in base pre; do
  run_one "$T/$tree" "$T/runs/$tree-$N" "" "" --help
  cmp -s "$T/runs/$tree-$N/out" "$T/runs/cand-$N/out.less" && [ "$(cat "$T/runs/$tree-$N/rc")" = "$(cat "$T/runs/cand-$N/rc")" ] && ok ||
    fail "--help: the candidate's differs from the $tree tree's by more than the frontend-check and operation SCOPE rows"
done
same "--version" "" "" --version
same "an unknown flag" "" "" --frobnicate
same "an unknown command" linux-alarm-fresh "" frobnicate
# The commands of SPEC.md → Commands not built yet stay unknown commands, as
# before; none became reachable through frontend-check.
same "rescue (not built yet)" linux-alarm-fresh "" rescue
# M16-status-report: report and qualify are now implemented. Their fixed
# fixture behavior is checked separately; all preexisting commands keep the
# accepted baseline's byte comparison, apart from the appended status section.
for c in report qualify; do
  N=$((N + 1))
  run_one "$T/base" "$T/runs/base-$N" linux-alarm-fresh "" "$c"
  run_one "$REPO" "$T/runs/cand-$N" linux-alarm-fresh "" "$c"
  assert_eq "$(cat "$T/runs/base-$N/rc")" 2 "M16-status-report: BASE did not know $c"
  assert_empty_file "$T/runs/cand-$N/record" "M16-status-report: $c executes nothing on this fixture"
  assert_empty_file "$T/runs/cand-$N/shims.log" "M16-status-report: $c no forbidden command"
  if [ "$c" = report ]; then
    assert_eq "$(cat "$T/runs/cand-$N/rc")" 0 'M16-status-report: report is a completed read'
    assert_eq "$(grep -Ec '^   (pass|warn|fail|not-checked) ' "$T/runs/cand-$N/out")" 8 'M16-status-report: eight report rows'
    assert_contains "$(cat "$T/runs/cand-$N/out")" 'pass=1 warn=1 fail=0 not-checked=6' 'M16-status-report: exact report counts'
    assert_contains "$(cat "$T/runs/cand-$N/out")" 'Verdict             warn' 'M16-status-report: warn verdict'
    assert_eq "$(t_snapshot "$T/runs/cand-$N/state")" '(absent)' 'M16-status-report: report writes no persistent files'
  else
    assert_eq "$(cat "$T/runs/cand-$N/rc")" 1 'M16-status-report: qualify refuses without Shared'
    assert_eq "$(cat "$T/runs/cand-$N/out")" '   ✗ Shared is not ready: off' 'M16-status-report: exact qualify refusal'
    assert_eq "$(find "$T/runs/cand-$N/state" -type f | sed "s|$T/runs/cand-$N/state/||")" 'logs/omarchy-bootstrap-20260921.log' 'M16-status-report: only the normal act-intent log'
    assert_eq "$(cat "$T/runs/cand-$N/state/logs/omarchy-bootstrap-20260921.log")" '2026-09-21T14:13:20Z [linux] start  omarchy-bootstrap 0.2.0 cmd=qualify intent=act os=Linux uid=0 dry_run=0 fixture=linux-alarm-fresh' 'M16-status-report: fixed refusal log'
  fi
done
N=$((N + 1))
run_one "$REPO" "$T/runs/cand-$N" linux-alarm-fresh "" qualify status
assert_eq "$(cat "$T/runs/cand-$N/rc")" 1 'M16-status-report: qualify status reports the blocked read'
assert_contains "$(cat "$T/runs/cand-$N/out")" blocked 'M16-status-report: qualify status reports its state'
assert_eq "$(t_snapshot "$T/runs/cand-$N/state")" '(absent)' 'M16-status-report: qualify status writes nothing'
# The migration's commands are macOS's: on Linux each refuses, changing
# nothing (a named delta: the baseline knew none of them).
for c in scan profile export; do
  N=$((N + 1))
  run_one "$REPO" "$T/runs/cand-$N" linux-alarm-fresh "" "$c"
  assert_eq "$(cat "$T/runs/cand-$N/rc")" 1 "$c on Linux refuses"
  assert_contains "$(cat "$T/runs/cand-$N/out")" "runs on macOS" "$c on Linux says where it runs"
  assert_eq "$(cat "$T/runs/cand-$N/record")" "" "$c on Linux runs nothing"
done
same "sources" "" "" sources
same "a malformed OMB_DRY_RUN" linux-alarm-fresh "" status --dry-run=2

# debug-implemented and restore-implemented: each is a named command delta.
# Unknown future commands still compare above; these new commands must be
# read-only/refused on this root fixture, with no state or execution.
for c in debug restore; do
  N=$((N + 1))
  run_one "$T/base" "$T/runs/base-$N" linux-alarm-fresh "" "$c"
  run_one "$REPO" "$T/runs/cand-$N" linux-alarm-fresh "" "$c"
  assert_eq "$(cat "$T/runs/base-$N/rc")" 2 "$c-implemented: BASE did not know the command"
  if [ "$c" = debug ]; then
    assert_eq "$(cat "$T/runs/cand-$N/rc")" 0 'debug-implemented: fixed brief succeeds'
    assert_contains "$(cat "$T/runs/cand-$N/out")" '# Brief: omarchy-mac-bootstrap' 'debug-implemented: fixed instructions'
    assert_contains "$(cat "$T/runs/cand-$N/out")" 'SSH policy: off' 'debug-implemented: closed SSH observation'
  else
    assert_eq "$(cat "$T/runs/cand-$N/rc")" 1 'restore-implemented: root is refused'
    assert_contains "$(cat "$T/runs/cand-$N/out")" 'Restore never runs as root.' 'restore-implemented: explicit refusal'
  fi
  assert_empty_file "$T/runs/cand-$N/record" "$c-implemented: executes nothing"
  assert_empty_file "$T/runs/cand-$N/shims.log" "$c-implemented: no forbidden command"
  if [ "$c" = debug ]; then
    assert_eq "$(t_snapshot "$T/runs/cand-$N/state")" '(absent)' 'debug-implemented: no persistent writes'
  else
    assert_eq "$(find "$T/runs/cand-$N/state" -type f | sed "s|$T/runs/cand-$N/state/||")" 'logs/omarchy-bootstrap-20260921.log' 'restore-implemented: only the normal act-intent log'
    assert_eq "$(cat "$T/runs/cand-$N/state/logs/omarchy-bootstrap-20260921.log")" '2026-09-21T14:13:20Z [linux] start  omarchy-bootstrap 0.2.0 cmd=restore intent=act os=Linux uid=0 dry_run=0 fixture=linux-alarm-fresh' 'restore-implemented: fixed refusal log, no restore writes'
  fi
done

# start-disable-ssh: pin both fresh reads at the actual disable boundary.
(
  t_load >/dev/null 2>&1
  OMB_FIXTURE=$FIX/linux-alarm-fresh OMB_DRY_RUN=0
  # shellcheck disable=SC2317,SC2329 # callback invoked by lx_ssh_stop
  run() { printf 'run %s\n' "$*" >>"$T/start.reads"; }
  eval "$(declare -f sys_cmd | sed '1s/sys_cmd/b_original_sys_cmd/')"
  # shellcheck disable=SC2317,SC2329 # callback invoked by lx_ssh_stop
  sys_cmd() { printf 'read %s\n' "$*" >>"$T/start.reads"; b_original_sys_cmd "$@"; }
  lx_ssh_stop >/dev/null
)
assert_eq "$?" 0 'start-disable-ssh: inactive and disabled succeeds'
assert_eq "$(cat "$T/start.reads")" 'run systemctl disable --now sshd
read sshd_active systemctl is-active sshd
read sshd_enabled systemctl is-enabled sshd' 'start-disable-ssh: command then exactly the two post-disable reads'

# Named D30 deltas are constrained to the AI module selected here. Existing
# non-AI dev equivalence below continues to compare its entire transcript.
N=$((N + 1))
B_ENV=HOME=/home/alex run_one "$T/base" "$T/runs/base-$N" agt-wrappers '8\n1 2\n' dev --dry-run
B_ENV=HOME=/home/alex run_one "$REPO" "$T/runs/cand-$N" agt-wrappers '8\n1 2 3\n' dev --dry-run
assert_contains "$(cat "$T/runs/base-$N/out")" 'Claude Code is already installed.' 'agents-lazy-wrapper: BASE accepts the lazy wrapper'
assert_contains "$(cat "$T/runs/cand-$N/out")" 'AI coding CLIs none' 'agents-lazy-wrapper: wrapper-only is absent'
for package in claude codex opencode; do
  assert_contains "$(cat "$T/runs/cand-$N/out")" "would run  mise use -g --quiet $package" "agents-mise-install: $package preview"
done
assert_contains "$(cat "$T/runs/cand-$N/out")" '3  OpenCode' 'agents-opencode: third selectable provider'
assert_not_contains "$(cat "$T/runs/base-$N/out")" '3  OpenCode' 'agents-opencode: absent from BASE'
assert_empty_file "$T/runs/cand-$N/record" 'agents-mise-install: preview runs nothing'
assert_eq "$(t_snapshot "$T/runs/cand-$N/state")" '(absent)' 'agents-mise-install: preview keeps no provenance'

# Exercise the replacement of each legacy installer as an actual recorded
# success, including the exact removed Claude download/provenance family.
AIFX=$(t_variant agt-wrappers)
awk '$0 != "claude" && $0 != "codex" && $0 != "opencode"' "$AIFX/commands" >"$AIFX/commands.new"
printf 'npm\n' >>"$AIFX/commands.new"; mv "$AIFX/commands.new" "$AIFX/commands"
for tool in claude codex; do
  choice=1 input='8\n1\n\ny\n'
  [ "$tool" != codex ] || { choice=2; input='8\n2\n'; }
  N=$((N + 1))
  B_ENV="HOME=/home/alex OMB_TEST_AFTER=$FIX/agt-installed" run_one "$T/base" "$T/runs/base-$N" "$AIFX" "$input" dev
  B_ENV="HOME=/home/alex OMB_TEST_AFTER=$FIX/agt-installed" run_one "$REPO" "$T/runs/cand-$N" "$AIFX" "8\n$choice\n" dev
  assert_eq "$(cat "$T/runs/base-$N/rc") $(cat "$T/runs/cand-$N/rc")" '0 0' "agents-mise-install: $tool both complete"
  assert_eq "$(cat "$T/runs/cand-$N/record")" "mise use -g --quiet $tool
timeout 30 mise x $tool -- $tool --version" "agents-mise-install: $tool exact replacement commands"
  if [ "$tool" = claude ]; then
    assert_contains "$(cat "$T/runs/base-$N/record")" 'bash ' 'agents-mise-install: BASE executes its Claude download'
    assert_contains "$(cat "$T/runs/base-$N/state/state.env")" 'claude_install_sha256=' 'agents-mise-install: BASE keeps Claude provenance'
    assert_not_contains "$(cat "$T/runs/cand-$N/state/state.env")" 'claude_install_sha256=' 'agents-mise-install: no downloaded-Claude provenance'
    assert_eq "$(find "$T/runs/cand-$N/state" -name '*claude-code-install*')" '' 'agents-mise-install: no kept Claude download'
  else
    assert_eq "$(cat "$T/runs/base-$N/record")" 'npm install -g @openai/codex' 'agents-mise-install: BASE uses npm'
  fi
  assert_empty_file "$T/runs/cand-$N/shims.log" "agents-mise-install: $tool executes no real command"
done

# --- Linux: read commands, plan, the default run, resume, dev ---------------------------------
for fx in linux-alarm-fresh linux-alarm-offline linux-setup-in-progress linux-omarchy-installed linux-shared-present linux-shared-ready; do
  for cmd in status doctor logs shared; do
    same "$cmd on $fx" "$fx" "" "$cmd"
  done
  same "plan on $fx" "$fx" '\nalex\nm1pro\n\n\n\n\n\n\n\n' plan
  same "the default run on $fx" "$fx" '\n\nstart\nq\n'
  same "install on $fx" "$fx" '\n\nstart\nq\n' install
  same "a dry run on $fx" "$fx" '\n\nstart\nq\n' --dry-run
done
B_DELTA=start-disable-ssh same "resume with a token" linux-alarm-fresh '\n\nstart\n' resume 'omb2:enc=1,user=alex,host=omarchy,kmap=us'
same "resume refusing upstream drift" linux-upstream-drift '\n\nstart\n' resume 'omb1:enc=1,user=alex,host=omarchy,kmap=us'
same "dev, previewed" linux-omarchy-installed '1 2 3\n1\n2\n\n' dev --dry-run
same "shared activate refusing without a code" linux-shared-present '\n' shared activate
same "shared test" linux-shared-ready 'test\n' shared test

# --- macOS: read commands, plan, the install flow, Shared ------------------------------------
if t_plutil "the baseline equivalence over macOS fixtures"; then
  mac_install='\n\n\n\n\n\n\n\n\n\n\n\n\nyes\n\nlaunch\n'
  for fx in mac-m1pro-1tb-roomy mac-m1-free-space mac-asahi-installed mac-asahi-pending mac-shared-reserved mac-shared-created mac-intel; do
    for cmd in status doctor shared; do
      same "$cmd on $fx" "$fx" "" "$cmd"
    done
    same "plan on $fx" "$fx" '\n\n\n\n\n\n\n\n\n\n\n\n\n\n' plan
    same "the default run on $fx" "$fx" "$mac_install"
    same "install on $fx" "$fx" "$mac_install" install
    same "resume on $fx" "$fx" '\n' resume
    same "a dry run on $fx" "$fx" "$mac_install" --dry-run
  done
  # Shared's creation end to end, as tests/test-shared.sh drives it: a plan
  # with 150 GB Shared; after Asahi, the completion code, both typed gates,
  # `sudo -v`, the one recorded addPartition and the read afterwards.
  t_load
  N=$((N + 1))
  for side in base pre cand; do
    case $side in base) tree=$T/base ;; pre) tree=$T/pre ;; *) tree=$REPO ;; esac
    d=$T/runs/$side-$N
    run_one "$tree" "$d-plan" mac-m1pro-1tb-roomy '\n4\n\n\n\n\n\n\n\n\n\n\n\n' plan
    digest=$(sed -n 's/^digest=//p' "$d-plan/state/shared-intent.env" | cut -c1-8)
    mkdir -p "$d/state"
    cp -p "$d-plan/state/state.env" "$d-plan/state/shared-intent.env" "$d/state/"
    B_ENV="OMB_TEST_AFTER=$FIX/mac-shared-created" run_one "$tree" "$d" mac-shared-reserved \
      "$(code_make ombdone "$digest" 4A7B1C2D-0006-4E5F-8A9B-000000000006)\nyes\ncreate\n" shared create
  done
  agree "Shared's plan record" "$T/runs/base-$N-plan" "$T/runs/cand-$N-plan"
  agree "Shared's creation, gated and recorded" "$T/runs/base-$N" "$T/runs/cand-$N"
  agree "Shared's plan record" "$T/runs/pre-$N-plan" "$T/runs/cand-$N-plan" "$T/pre"
  agree "Shared's creation, gated and recorded" "$T/runs/pre-$N" "$T/runs/cand-$N" "$T/pre"
  assert_eq "$(cat "$T/runs/cand-$N/record")" "sudo -v
sudo -n diskutil addPartition disk0s6 ExFAT Shared $(((150000000000 + 1048575) / 1048576 * 1048576))" \
    "the creation reached its one recorded change on both"
fi

# --- On a terminal: the bare command, before frontend-check's route and now ----------------
# (frontend-check-default-unchanged.) Each tree in a new terminal of its
# own, the same keys typed as it starts; the terminal's bytes (carriage
# returns taken out), the records and the state compared as above.
# shellcheck source=tests/frontend-check-lib.sh
. "$TESTS_DIR/frontend-check-lib.sh"
# pty_one TREE DIR FIXTURE INPUT — run_one's sealed environment, on a
# terminal. The fixture is a fresh copy at one path for every tree: on a
# terminal the default run first tries the interface, and a fixture whose
# user is root keeps root's frontend cache under its own root/ folder.
pty_one() {
  local tree=$1 d=$2 fx=$T/pty-fixture input=$4 shims i=0 bs
  rm -rf "$fx"
  mkdir -p "$fx" "$d/tmp" "$d/home"
  cp -R "$FIX/$3/." "$fx/"
  shims=$(t_shims "$d")
  date_shim "$shims"
  {
    printf 'stty rows 40 cols 120 2>/dev/null\n'
    printf "/bin/sh -c 'echo \$\$ >\"\$0/pid\"; exec \"\$@\"' '%s' env -i PATH='%s' HOME='%s' TMPDIR='%s' LANG=en_US.UTF-8 TERM=xterm-256color OMB_STATE_DIR='%s' OMB_FIXTURE='%s' SHIM_LOG='%s' OMB_TEST_RECORD='%s' '%s' '%s/omarchy-bootstrap'\n" \
      "$d" "$shims:/usr/bin:/bin:/usr/sbin:/sbin" "$d/home" "$d/tmp" "$d/state" "$fx" "$d/shims.log" "$d/record" "$T_BASH" "$tree"
    printf 'echo $? >"%s/rc"\n' "$d"
  } >"$d/inner"
  # The keys, then the input held open until the run ends; one still going
  # after 60 s asks for more than it was given: ended as the process it
  # recorded, and its case fails on what it left.
  {
    printf '%b' "$input"
    until [ -e "$d/rc" ] || [ "$i" -ge 600 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    if [ ! -e "$d/rc" ]; then
      echo "the run did not end: it asked for more than its keys" >"$d/stuck"
      t_signal KILL "$(cat "$d/pid")" "$(t_started "$(cat "$d/pid")")"
    fi
  } | fc_script "$d/pty" "$T_BASH" "$d/inner" >/dev/null 2>&1
  [ ! -e "$d/stuck" ] && ok || fail "the default run on a terminal ($3, $(basename "$tree")): $(cat "$d/stuck")"
  # util-linux script logs its own start and end, with the time, even with
  # -q when its input is not a terminal: its lines, not either tree's. And
  # the terminal echoes a queued ^D (macOS: "^D" then two backspaces) when
  # it takes it, which for a surplus one may be before or after the program
  # has ended: the terminal's bytes, not the program's.
  bs=$(printf '\b')
  tr -d '\r' <"$d/pty" | grep -vE '^Script (started|done) on ' | sed -e "s/\\^D$bs$bs//g" -e 's/\^D//g' >"$d/out"
  touch "$d/record" "$d/shims.log"
}
# pty_same NAME FIXTURE KEYS — both trees, the same KEYS typed at once, then
# eight ^D: a terminal gives no EOF of its own, and each queued ^D is one
# EOF to the next prompt, as a pipe's end is to the text runs above.
pty_same() {
  N=$((N + 1))
  pty_one "$T/pre" "$T/runs/pre-$N" "$2" "$3"'\004\004\004\004\004\004\004\004'
  pty_one "$REPO" "$T/runs/cand-$N" "$2" "$3"'\004\004\004\004\004\004\004\004'
  [ -s "$T/runs/cand-$N/out" ] && ok || fail "$1: the terminal recorded nothing"
  agree "$1" "$T/runs/pre-$N" "$T/runs/cand-$N" "$T/pre"
}
# On a host that has a frontend target, both trees first ask to download the
# interface (the fixture's network has none, so both then continue in
# text): one more line to answer, whichever fixture runs.
first=""
case "$(uname -s):$(uname -m)" in Darwin:arm64 | Linux:aarch64) first='\n' ;; esac
if command -v script >/dev/null 2>&1; then
  for fx in linux-alarm-fresh linux-alarm-offline linux-setup-in-progress linux-omarchy-installed linux-shared-present linux-shared-ready; do
    pty_same "the default run on a terminal on $fx" "$fx" "$first"'\n\nstart\nq\n'
  done
  if t_plutil "the default run on a terminal over macOS fixtures"; then
    for fx in mac-m1pro-1tb-roomy mac-m1-free-space mac-asahi-installed mac-asahi-pending mac-shared-reserved mac-shared-created mac-intel; do
      pty_same "the default run on a terminal on $fx" "$fx" "$first$mac_install"
    done
  fi
else
  fail "frontend-check-default-unchanged: no script(1) to give the default run a terminal"
fi
# No run of any tree wrote into the committed fixtures.
assert_eq "$(t_snapshot "$FIX")" "$baseline_fixture_before" "the committed fixtures are as they were"

t_done test-baseline
