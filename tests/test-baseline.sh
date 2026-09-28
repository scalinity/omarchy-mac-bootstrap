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

# normal TREE DIR — everything a run left, with only its per-run values
# replaced: the run's folder, the tree's own path, times, suffixes and PIDs.
normal() {
  local tree=$1 d=$2 f
  {
    echo "== rc $(cat "$d/rc")"
    echo "== out"
    cat "$d/out"
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
  local name=$1 fixture=$2 input=$3
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
# --help: the one listed delta, frontend-check's row (docs/FRONTEND.md → Help),
# and nothing else, against each earlier tree.
N=$((N + 1))
run_one "$REPO" "$T/runs/cand-$N" "" "" --help
help_row='     frontend-check       check that the interface starts: downloads it once, changes nothing else'
assert_eq "$(grep -cxF -- "$help_row" "$T/runs/cand-$N/out")" 1 "--help lists frontend-check with its one line"
grep -vxF -- "$help_row" "$T/runs/cand-$N/out" >"$T/runs/cand-$N/out.less"
for tree in base pre; do
  run_one "$T/$tree" "$T/runs/$tree-$N" "" "" --help
  cmp -s "$T/runs/$tree-$N/out" "$T/runs/cand-$N/out.less" && [ "$(cat "$T/runs/$tree-$N/rc")" = "$(cat "$T/runs/cand-$N/rc")" ] && ok ||
    fail "--help: the candidate's differs from the $tree tree's by more than frontend-check's row"
done
same "--version" "" "" --version
same "an unknown flag" "" "" --frobnicate
same "an unknown command" linux-alarm-fresh "" frobnicate
# The commands of SPEC.md → Commands not built yet stay unknown commands, as
# before; none became reachable through frontend-check.
for c in scan profile export restore rescue debug qualify report; do
  same "$c (not built yet)" linux-alarm-fresh "" "$c"
done
same "sources" "" "" sources
same "a malformed OMB_DRY_RUN" linux-alarm-fresh "" status --dry-run=2

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
same "resume with a token" linux-alarm-fresh '\n\nstart\n' resume 'omb2:enc=1,user=alex,host=omarchy,kmap=us'
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
  local tree=$1 d=$2 fx=$T/pty-fixture input=$4 shims i=0
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
  # -q when its input is not a terminal: its lines, not either tree's.
  tr -d '\r' <"$d/pty" | grep -vE '^Script (started|done) on ' >"$d/out"
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
assert_eq "$(git -C "$REPO" status --porcelain --untracked-files=all -- tests/fixtures)" "" "the committed fixtures are as they were"

t_done test-baseline
