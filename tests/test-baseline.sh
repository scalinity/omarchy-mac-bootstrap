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

# run_one TREE DIR FIXTURE INPUT ARGS... — like t_cli, for either tree, into
# DIR. Run in the current shell: nothing it sets may be lost to a subshell.
run_one() {
  local tree=$1 d=$2 fixture=$3 input=$4 shims fx=""
  shift 4
  mkdir -p "$d/tmp" "$d/home"
  shims=$(t_shims "$d")
  # One fixed clock for both trees: both read it only as `date -u +FORMAT`,
  # and values made from a time (the Shared plan's digest, its codes) must
  # come out the same. BSD date takes -r SECONDS, GNU date -d @SECONDS.
  cat >"$shims/date" <<'EOF'
#!/bin/sh
if /bin/date -u -r 0 >/dev/null 2>&1; then exec /bin/date -r 1790000000 "$@"; fi
exec /bin/date -d @1790000000 "$@"
EOF
  chmod +x "$shims/date"
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

# agree NAME A B — the baseline's run A and the candidate's run B left the
# same thing behind.
agree() {
  normal "$T/base" "$2" >"$2.norm"
  normal "$REPO" "$3" >"$3.norm"
  if cmp -s "$2.norm" "$3.norm"; then
    ok
  else
    fail "$1: the candidate differs from the accepted baseline"
    diff "$2.norm" "$3.norm" | head -20
  fi
}

# same NAME FIXTURE INPUT ARGS... — the baseline and the candidate agree, each
# in its own fresh folder.
N=0
same() {
  local name=$1 fixture=$2 input=$3
  shift 3
  N=$((N + 1))
  run_one "$T/base" "$T/runs/base-$N" "$fixture" "$input" "$@"
  run_one "$REPO" "$T/runs/cand-$N" "$fixture" "$input" "$@"
  agree "$name" "$T/runs/base-$N" "$T/runs/cand-$N"
}

# The comparison can fail: two different commands are told apart.
N=$((N + 1))
run_one "$T/base" "$T/runs/base-$N" "" "" --version
run_one "$REPO" "$T/runs/cand-$N" "" "" --help
normal "$T/base" "$T/runs/base-$N" >"$T/runs/base-$N.norm"
normal "$REPO" "$T/runs/cand-$N" >"$T/runs/cand-$N.norm"
if cmp -s "$T/runs/base-$N.norm" "$T/runs/cand-$N.norm"; then fail "the comparison cannot tell --version from --help"; else ok; fi

# --- Everywhere: the command surface -------------------------------------------------------
same "--help" "" "" --help
same "--version" "" "" --version
same "an unknown flag" "" "" --frobnicate
same "an unknown command" linux-alarm-fresh "" frobnicate
same "sources" "" "" sources
same "a malformed OMB_DRY_RUN" linux-alarm-fresh "" status --dry-run=2

# --- Linux: read commands, plan, the default run, resume, dev ---------------------------------
for fx in linux-alarm-fresh linux-alarm-offline linux-setup-in-progress linux-omarchy-installed linux-shared-present linux-shared-ready; do
  for cmd in status doctor logs shared; do
    same "$cmd on $fx" "$fx" "" "$cmd"
  done
  same "plan on $fx" "$fx" '\nalex\nm1pro\n\n\n\n\n\n\n\n' plan
  same "the default run on $fx" "$fx" '\n\nstart\nq\n'
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
    same "a dry run on $fx" "$fx" "$mac_install" --dry-run
  done
  # Shared's creation end to end, as tests/test-shared.sh drives it: a plan
  # with 150 GB Shared; after Asahi, the completion code, both typed gates,
  # `sudo -v`, the one recorded addPartition and the read afterwards.
  t_load
  N=$((N + 1))
  for side in base cand; do
    if [ "$side" = base ]; then tree=$T/base; else tree=$REPO; fi
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
  assert_eq "$(cat "$T/runs/cand-$N/record")" "sudo -v
sudo -n diskutil addPartition disk0s6 ExFAT Shared $(((150000000000 + 1048575) / 1048576 * 1048576))" \
    "the creation reached its one recorded change on both"
fi

t_done test-baseline
