#!/usr/bin/env bash
# Restore placements and recovery over synthetic Omarchy homes. The local run
# stand-in executes only filesystem commands confined to this test's fixture;
# package/owner commands are simulated and never run on the development Mac.
# shellcheck disable=SC2015,SC2016,SC2031,SC2034,SC2317,SC2329
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load
# shellcheck source=lib/records.sh
. "$REPO/lib/records.sh"
# shellcheck source=lib/core.sh
. "$REPO/lib/core.sh"
# shellcheck source=lib/read.sh
. "$REPO/lib/read.sh"
# shellcheck source=lib/migrate_bundle.sh
. "$REPO/lib/migrate_bundle.sh"
# shellcheck source=lib/migrate_restore.sh
. "$REPO/lib/migrate_restore.sh"
echo test-restore
if [ "${1:-}" = child ]; then T=$RST_CHILD_T; else T=$(t_tmp); fi
OMB_HOME=$REPO
OMB_TMP=$T/omarchy-bootstrap.scratch
mkdir -p "$OMB_TMP"
REAL_HOME=$HOME

# Until the parallel AI unit lands: observation is files only, installation
# writes one synthetic artifact through the test's recorder.
agent_observe() {
  local p
  AG_INSTALLED=none AG_SIGNIN=0
  [ ! -f "$RST_HOME/.local/share/mise/installs/$1/1/bin/$1" ] || AG_INSTALLED=mise
  case "$1" in
    claude-code) p=.claude/.credentials.json ;;
    codex)
      p=.codex/auth.json
      [ ! -f "$RST_HOME/.codex/.credentials.json" ] || AG_SIGNIN=1 ;;
    opencode) p=.local/share/opencode/auth.json ;;
    *) return 1 ;;
  esac
  [ ! -f "$RST_HOME/$p" ] || AG_SIGNIN=1
  return 0
}
agent_install() {
  AG_INSTALL_RAN=0 AG_INSTALL_OUTCOME=failed AG_WHY=''
  agent_observe "$1" || return 1
  if [ "$AG_INSTALLED" != none ]; then AG_INSTALL_OUTCOME=already-satisfied; return 0; fi
  if [ "${AG_TEST_FAIL:-0}" = 1 ]; then AG_WHY='The post-install version check failed.'; return 1; fi
  run fake-agent "$1" || return 1
  AG_INSTALL_RAN=1 AG_INSTALL_OUTCOME=success
}
# A journal flush is observed without flushing the development machine.
sync() {
  printf 'flush\n' >>"$T/flushes"
  if [ -f "${RST_LOG:-}" ]; then tail -n 1 "$RST_LOG" >>"$T/flushed-lines"; fi
}
# Scratch trees use Linux ln's exact-destination form too. BSD ln lacks -T;
# emulate just that form while keeping the real GNU check below untouched.
ln() {
  if [ "${1:-}" = -s ] && [ "${2:-}" = -T ]; then
    shift 2
    [ ! -e "${3:-}" ] && [ ! -L "${3:-}" ] || return 1
    command ln -s "$@"
  else command ln "$@"; fi
}

eval "$(declare -f run | sed '1s/run/_restore_real_run/')"
# run's fixture execution stand-in: no generic evaluator, no external tools.
# BSD tools on macOS need the same no-replace semantics for fixture tests.
run() {
  local cmd=$1 arg src dst key i=0 argv
  local -a shown=()
  shift
  [ "$OMB_INTENT" = act ] && [ "$OMB_DRY_RUN" != 1 ] || return 1
  for arg in "$cmd" "$@"; do
    i=$((i + 1))
    if [ "$i" = "${OMB_RUN_WITHHELD:-0}" ]; then shown+=( '<withheld>' ); else shown+=( "$arg" ); fi
  done
  argv=$(quote_argv "${shown[@]}")
  printf '%s\n' "$argv" >>"$T/record"
  if [ -d "$OMB_STATE_DIR" ]; then log_event exec "$argv"; fi
  case "$cmd" in
    rst_log_write | rst_stage_write)
      if [ "$cmd" = rst_stage_write ] && [ "${2##*.}" = setting ] && [ "${RESTORE_TEST_SHORT_SETTING:-0}" = 1 ]; then
        RESTORE_TEST_SHORT_SETTING=0
        printf partial >"$2"; chmod 0600 "$2"; return 1
      fi
      if [ "$cmd" = rst_log_write ] && [ "${RESTORE_TEST_SETTING_LOG_FAIL:-0}" = 1 ]; then
        RESTORE_TEST_SETTING_LOG_FAIL=0
        return 1
      fi
      "$cmd" "$@" ;;
    sync) return 0 ;;
    mkdir | chmod | cp | rm)
      if [ "$cmd" = mkdir ] && [ "${RESTORE_TEST_CHECK_MKDIR_FAIL:-0}" = 1 ]; then return 1; fi
      for arg in "$@"; do
        case "$arg" in /*) case "$arg" in "$T"/* | "$TMP_ROOT"/*) ;; *) echo "unsafe test write: $arg" >&2; return 97 ;; esac ;; esac
      done
      if [ "$cmd" = cp ] && [ "$1" = -a ]; then
        shift
        key=0
        if [ "$1" = -T ]; then key=1; shift; fi
        [ "$1" != -- ] || shift
        if [ "${RESTORE_TEST_STAGE_LINK:-0}" = 1 ]; then
          RESTORE_TEST_STAGE_LINK=0
          rm -rf "${2%/}"
          ln -s "$T/outside" "${2%/}"
        fi
        if [ "$key" = 1 ]; then [ ! -e "$2" ] && [ ! -L "$2" ] || return 1; fi
        if [ "${RESTORE_TEST_PARTIAL_COPY:-0}" = 1 ]; then
          RESTORE_TEST_PARTIAL_COPY=0
          printf partial >"$2"
          return 1
        fi
        cp -pR "$@"
      elif [ "$cmd" = chmod ]; then
        if [ "$1" = -R ]; then
          shift; key=$1; shift; [ "$1" != -- ] || shift; chmod -R "$key" "$@"
        else key=$1; shift; [ "$1" != -- ] || shift; chmod "$key" "$@"; fi
      else "$cmd" "$@"; fi ;;
    mv)
      shift 3
      src=$1 dst=$2
      # Model an mv that accepts but ignores the no-clobber option.
      if [ "${RESTORE_TEST_CLOBBER:-0}" = 1 ]; then mv -- "$src" "$dst"; return; fi
      if [ "${RESTORE_TEST_CLOBBER:-0}" = unknown ]; then return 1; fi
      if [ "${RESTORE_TEST_EDIT_ON_MOVE:-0}" = 1 ]; then
        case "$dst" in *.placed) printf edited >"$src"; RESTORE_TEST_EDIT_ON_MOVE=0 ;; esac
      fi
      # Directory-only option loss must be caught even when file moves are safe.
      if [ "${RESTORE_TEST_CLOBBER:-0}" = directory ] && [ -d "$src" ] && [ -d "$dst" ]; then
        if rmdir "$dst" 2>/dev/null; then mv -- "$src" "$dst"; return; fi
        return 1
      fi
      [ ! -e "$dst" ] && [ ! -L "$dst" ] || return 1
      mv -- "$src" "$dst" ;;
    ln)
      if [ "$1" = -s ]; then
        shift 3; [ ! -e "$2" ] && [ ! -L "$2" ] || return 1
        ln -s -- "$1" "$2"
      else
        shift 2; [ ! -e "$2" ] && [ ! -L "$2" ] || return 1
        ln -- "$1" "$2"
      fi ;;
    omarchy-pkg-add)
      if [ "${INSTALL_TAKES:-0}" = 1 ]; then
        for key in "$@"; do printf '%s 1\n' "$key" >"$OMB_FIXTURE/cmd/rst_q_$key"; rm -f "$OMB_FIXTURE/cmd/rst_q_$key.rc"; done
      fi ;;
    git)
      if [ "${5:-}" = --unset-all ]; then
        key=$7
        : >"$OMB_FIXTURE/cmd/rst_git_$key"
        printf '1\n' >"$OMB_FIXTURE/cmd/rst_git_$key.rc"
      else
        key=${6:-}
        printf '%s\n' "${7:-}" >"$OMB_FIXTURE/cmd/rst_git_$key"
        rm -f "$OMB_FIXTURE/cmd/rst_git_$key.rc"
      fi
      if [ "${RESTORE_TEST_FAIL_AFTER_SETTING:-0}" = 1 ]; then
        RESTORE_TEST_FAIL_AFTER_SETTING=0 RESTORE_TEST_SETTING_LOG_FAIL=1
      fi ;;
    claude)
      mkdir -p "$RST_HOME"
      printf '{}\n' >"$T/json"
      [ ! -f "$RST_HOME/.claude.json" ] || cp "$RST_HOME/.claude.json" "$T/json"
      if [ "$2" = remove ]; then
        jq --arg k "$3" 'del(.mcpServers[$k])' "$T/json" >"$RST_HOME/.claude.json"
      else jq --arg k "$3" --argjson v "$4" '.mcpServers[$k] = $v' "$T/json" >"$RST_HOME/.claude.json"; fi ;;
    fake-agent)
      mkdir -p "$RST_HOME/.local/share/mise/installs/$1/1/bin"
      : >"$RST_HOME/.local/share/mise/installs/$1/1/bin/$1" ;;
    env | npm | uv)
      if [ "${INSTALL_TAKES:-0}" = 1 ]; then
        case "$cmd" in
          env)
            [ "${RESTORE_TEST_BACKEND_NO_FOLDER:-0}" != 1 ] || return 0
            key=$RST_HOME/.local/share/mise/installs/$RST_TARGET/${RST_VERSION:-1}/bin
            mkdir -p "$key"
            printf '#!/bin/sh\n' >"$key/$RST_TARGET"
            chmod +x "$key/$RST_TARGET" ;;
          npm)
            mkdir -p "$RST_HOME/.local/share/mise/installs/node/22/lib/node_modules/$RST_TARGET"
            printf '{}\n' >"$RST_HOME/.local/share/mise/installs/node/22/lib/node_modules/$RST_TARGET/package.json" ;;
          uv)
            mkdir -p "$RST_HOME/.local/share/uv/tools/$RST_TARGET"
            printf 'synthetic receipt\n' >"$RST_HOME/.local/share/uv/tools/$RST_TARGET/uv-receipt.toml" ;;
        esac
      fi ;;
    *) echo "unexpected test run: $cmd" >&2; return 97 ;;
  esac
}

# Every test starts from the generated fixture, never from the live home.
makefix() {
  local obj
  F=$(t_variant rst-ready)
  RST_TEST_DIRS+=("$F")
  B=$F/root/mnt/shared/omarchy-mac-bootstrap/bundles/20261022T120000Z
  for obj in "$B"/objects/*; do SHA=${obj##*/}; done
}
setup() {
  makefix
  HOME=/home/alex
  OMB_FIXTURE=$F OMB_PLATFORM=linux OMB_UID=1000 OMB_INTENT=act OMB_PERSIST=1 OMB_DRY_RUN=0
  OMB_STATE_DIR=$F/root/home/alex/.local/state/omarchy-mac-bootstrap
  OMB_RESTORE_DIR=$F/root/mnt/shared
  OMB_TEST_STOP_AT='' OMB_TEST_FAIL_AT='' OMB_TEST_PAUSE_AT=''
  RST_CORE=0 RST_REPLACE=() CORE_REQ_ARGS=0 INSTALL_TAKES=0 AG_TEST_FAIL=0
  RESTORE_TEST_EDIT_ON_MOVE=0 RESTORE_TEST_PARTIAL_COPY=0 RESTORE_TEST_STAGE_LINK=0 RESTORE_TEST_SHORT_SETTING=0
  RESTORE_TEST_CLOBBER=0 RESTORE_TEST_BACKEND_NO_FOLDER=0
  RESTORE_TEST_FAIL_AFTER_SETTING=0 RESTORE_TEST_SETTING_LOG_FAIL=0 RESTORE_TEST_CHECK_MKDIR_FAIL=0
  STATE_DIR_OK=''
  state_init
  : >"$T/record"
  : >"$T/flushed-lines"
}
load() { _rst_load || fail 'restore-load'; }
replace_all() {
  local n=0
  RST_REPLACE=()
  while [ "$n" -lt "$RST_N" ]; do RST_REPLACE+=("${RST_DEST[n]}"); n=$((n + 1)); done
}
apply() { _rst_dataset || return 1; RST_REVIEW=$RST_GEN; OMB_IFACE_WORD=restore; _rst_apply >"$T/out" 2>&1; RC=$?; }
assert_file() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ] && ok || fail "$3"; }

rebuild() {
  {
    printf 'omb-bundle 1\n'
    rec_line bundle at 2026-10-22T12:00:00Z host 0123456789abcdef model 'MacBook Pro M1 Pro' user alex home /Users/alex items 1 files 1 bytes 18
    cat "$T/body"
  } >"$B/bundle.omb"
  rec_seal_write "$B/bundle.omb"
}
basebody() {
  rec_line item id config:test class config whole 1 >"$T/body"
  rec_line file item config:test dest .config/test.conf mode 0644 sha256 "$SHA" size 18 whole 1 >>"$T/body"
}
# A new process is required: omb_stop_at kills its own $$, as a power cut.
# It must never be called in a test subshell (Bash keeps the parent's $$).
if [ "${1:-}" = child ]; then
  F=$RST_CHILD_F T=$RST_CHILD_T
  OMB_TMP=$T/omarchy-bootstrap.child-scratch
  mkdir -p "$OMB_TMP"
  HOME=/home/alex OMB_FIXTURE=$F OMB_PLATFORM=linux OMB_UID=1000 OMB_INTENT=act OMB_PERSIST=1 OMB_DRY_RUN=0
  OMB_STATE_DIR=$F/root/home/alex/.local/state/omarchy-mac-bootstrap OMB_RESTORE_DIR=$F/root/mnt/shared
  OMB_TEST_STOP_AT=${RST_CHILD_STOP:-} OMB_TEST_FAIL_AT=${RST_CHILD_FAIL:-} OMB_TEST_PAUSE_AT=${RST_CHILD_PAUSE:-}
  RST_CORE=0 RST_REPLACE=() CORE_REQ_ARGS=0
  state_init
  _rst_load || exit 20
  replace_all
  if [ "${RST_CHILD_UNDO:-0}" = 1 ]; then OMB_IFACE_WORD=undo; _rst_undo
  else _rst_dataset; RST_REVIEW=$RST_GEN; OMB_IFACE_WORD=restore; _rst_apply; fi
  exit $?
fi
child() {
  env RST_CHILD_F="$F" RST_CHILD_T="$T" RST_CHILD_STOP="${1:-}" RST_CHILD_UNDO="${2:-0}" "$T_BASH" "$0" child >"$T/child.out" 2>&1
}

RST_TEST_DIRS=("$T")
cleanup_restore_tests() {
  local d
  for d in "${RST_TEST_DIRS[@]}"; do
    rm -rf "$d"
    rm -f "$d.go" "$d.at-restore.recheck" "$d.at-restore.place"
  done
}
trap cleanup_restore_tests EXIT

# restore-home-refusal: publish no unchecked home, and stop undo before it
# walks parents or searches for runs. Each spelling passes the relative check.
eval "$(declare -f _rst_parents | sed '1s/_rst_parents/_restore_home_parents/')"
_rst_parents() { printf '%s\n' "$1" >>"$T/home-reads"; _restore_home_parents "$@"; }
for bad_home in missing file prefix-link; do
  setup
  case "$bad_home" in
    missing) HOME=/home/missing ;;
    file) HOME=/home/file; printf ordinary >"$F/root/home/file" ;;
    prefix-link)
      mkdir -p "$F/root/home/real/leaf"
      ln -s real "$F/root/home/linked"
      HOME=/home/linked/leaf ;;
  esac
  _rst_safe_rel "${HOME#/}"
  assert_eq "$?" 0 "restore-home-refusal-safe-spelling-$bad_home"
  RST_HOME=stale
  _rst_home
  assert_eq "$?" 1 "restore-home-refusal-check-$bad_home"
  assert_eq "$RST_HOME" '' "restore-home-refusal-unpublished-$bad_home"
  : >"$T/home-reads"
  rst_cmd undo >"$T/out" 2>&1
  assert_eq "$?" 1 "restore-home-refusal-undo-$bad_home"
  assert_contains "$(cat "$T/out")" 'The home is not a real folder owned by this user.' "restore-home-refusal-reason-$bad_home"
  assert_not_contains "$(cat "$T/out")" 'No restore run is available to undo.' "restore-home-refusal-not-hidden-$bad_home"
  assert_empty_file "$T/home-reads" "restore-home-refusal-no-descendant-read-$bad_home"
done
_rst_parents() { _restore_home_parents "$@"; }
setup; load
assert_eq "${RST_GUARD_OK:-0}" 1 restore-home-guard-passed

# restore-never-root: root is refused before a machine or bundle read.
setup
OMB_UID=0
load
assert_eq "$RST_STATE" blocked restore-never-root
assert_contains "$RST_WHY" root restore-never-root-first
# restore-bundle-check-first: a corrupted object is never admitted.
setup
printf corrupt >"$B/objects/$SHA"
load
assert_eq "$RST_STATE" blocked restore-bundle-check-first
assert_empty_file "$T/record" restore-corrupt-no-writes
# restore-place-new: exact bytes/mode, journal, read-back and no-op rerun.
setup
load
assert_eq "$RST_STATE" not-started restore-review-new
apply
assert_eq "$RC" 0 restore-place-new
assert_file "$F/root/home/alex/.config/test.conf" 'new configuration' restore-read-back
load
assert_eq "${RST_STATUS[0]}" in-place restore-machine-outcome
before=$(t_snapshot "$F/root/home/alex")
: >"$T/record"
apply
assert_eq "$(t_snapshot "$F/root/home/alex")" "$before" restore-rerun-no-change
assert_empty_file "$T/record" restore-rerun-no-commands
# restore-keep-default: no replacement without explicit destinations.
setup
printf 'original\n' >"$F/root/home/alex/.config/test.conf"
load
assert_eq "${RST_ACTION[0]}" conflict restore-review-conflict
apply
assert_file "$F/root/home/alex/.config/test.conf" original restore-keep-default
load
assert_eq "${RST_STATUS[0]}" kept restore-keep-remembered
: >"$T/record"; apply
assert_empty_file "$T/record" restore-kept-rerun
# restore-backup-whole and undo: originals remain byte/mode identical.
setup
printf 'original\n' >"$F/root/home/alex/.config/test.conf"
chmod 0600 "$F/root/home/alex/.config/test.conf"
load
ORIGINAL=${RST_OLD[0]}
replace_all; apply
assert_eq "$RC" 0 restore-replace
_rst_backup_name .config/test.conf
_rst_node "$RST_BACKUP"
assert_eq "$RST_NODE" "$ORIGINAL" restore-backup-whole
load
OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1; RC=$?
assert_eq "$RC" 0 restore-undo
assert_file "$F/root/home/alex/.config/test.conf" original restore-undo-original
# restore-undo-refuse-changed: only the exact placement may be reversed.
setup; load; apply
printf changed >"$F/root/home/alex/.config/test.conf"
load
OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1; RC=$?
assert_eq "$RC" 1 restore-undo-refuse-changed
assert_file "$F/root/home/alex/.config/test.conf" changed restore-undo-left-alone
# restore-link-on-path: never follow a destination parent link.
setup
rm -f "$F/root/home/alex/.config/seed.conf"
rmdir "$F/root/home/alex/.config"
mkdir "$F/root/home/alex/outside"
ln -s outside "$F/root/home/alex/.config"
load
assert_eq "${RST_STATUS[0]}" blocked restore-link-on-path
# restore-write-failure: fail the log before the original can move.
setup
printf original >"$F/root/home/alex/.config/test.conf"
load; replace_all
OMB_TEST_FAIL_AT=restore.log
apply
assert_eq "$RC" 1 restore-log-write-failure
assert_file "$F/root/home/alex/.config/test.conf" original restore-log-before-move

# restore-stop-resume: each durable boundary can stop, then resume without
# another backup or a skipped read-back. The original is never discarded.
for boundary in restore.log restore.stage restore.backup restore.place; do
  setup
  printf original >"$F/root/home/alex/.config/test.conf"
  (child "$boundary") 2>/dev/null
  assert_eq "$?" 137 "restore-stop-$boundary"
  load; replace_all; apply
  assert_eq "$RC" 0 "restore-resume-$boundary"
  assert_file "$F/root/home/alex/.config/test.conf" 'new configuration' "restore-resumed-bytes-$boundary"
  _rst_backup_name .config/test.conf
  assert_file "$RST_BACKUP" original "restore-preserved-original-$boundary"
done
# restore-write-failures: each filesystem save fails without losing the old
# item; the unchanged journal is enough to finish the next attempt.
for boundary in restore.stage restore.backup restore.place; do
  setup
  printf original >"$F/root/home/alex/.config/test.conf"
  load; replace_all
  OMB_TEST_FAIL_AT=$boundary
  apply
  assert_eq "$RC" 1 "restore-fail-$boundary"
  if [ "$boundary" = restore.place ]; then
    _rst_backup_name .config/test.conf
    assert_file "$RST_HOME/.config/test.conf" original restore-place-failure-returns-original
  else assert_file "$F/root/home/alex/.config/test.conf" original "restore-failure-retains-original-$boundary"; fi
  OMB_TEST_FAIL_AT=''
  load; replace_all; apply
  assert_eq "$RC" 0 "restore-write-retry-$boundary"
done
# restore-torn-log: an interrupted last line is ignored; continuation only
# appends a framing marker and new lines, preserving every old byte.
setup
printf original >"$F/root/home/alex/.config/test.conf"
(child restore.backup) 2>/dev/null
load
printf 'event\tstep=pla' >>"$RST_LOG"
cp "$RST_LOG" "$T/torn-before"
load; replace_all; apply
assert_eq "$RC" 0 restore-torn-resume
head -c "$(wc -c <"$T/torn-before" | tr -d ' ')" "$RST_LOG" >"$T/torn-prefix"
cmp -s "$T/torn-before" "$T/torn-prefix" && ok || fail restore-log-append-only
load
assert_eq "${RST_STATUS[0]}" in-place restore-log-after-torn-admits
# restore-review-race: change after review, before staging/placement.
setup
printf original >"$F/root/home/alex/.config/test.conf"
env RST_CHILD_F="$F" RST_CHILD_T="$T" RST_CHILD_PAUSE=restore.recheck "$T_BASH" "$0" child >"$T/race.out" 2>&1 &
child_pid=$!
i=0
while [ ! -f "$F.at-restore.recheck" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -f "$F.at-restore.recheck" ] && ok || fail restore-pause-reached
printf concurrent >"$F/root/home/alex/.config/test.conf"
touch "$F.go"
wait "$child_pid"; RC=$?
assert_eq "$RC" 1 restore-review-race-blocked
assert_file "$F/root/home/alex/.config/test.conf" concurrent restore-review-race-preserves-new-value
# restore-no-clobber: even a folder appearing at the final name is refused.
setup
printf original >"$F/root/home/alex/.config/test.conf"
env RST_CHILD_F="$F" RST_CHILD_T="$T" RST_CHILD_PAUSE=restore.place "$T_BASH" "$0" child >"$T/race.out" 2>&1 &
child_pid=$!
i=0
while [ ! -f "$F.at-restore.place" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -f "$F.at-restore.place" ] && ok || fail restore-place-pause-reached
mkdir "$F/root/home/alex/.config/test.conf"
printf concurrent >"$F/root/home/alex/.config/test.conf/entry"
touch "$F.go"
wait "$child_pid"; RC=$?
assert_eq "$RC" 1 restore-no-clobber
assert_file "$F/root/home/alex/.config/test.conf/entry" concurrent restore-no-folder-nesting
load; _rst_backup_name .config/test.conf
assert_file "$RST_BACKUP" original restore-race-retains-backup
# restore-folder-whole: a tree and its links are one unit, no per-file mix.
setup
{
  rec_line item id config:nvim class config whole 1
  rec_line dir item config:nvim dest .config/nvim mode 0755
  rec_line dir item config:nvim dest .config/nvim/empty mode 0700
  rec_line file item config:nvim dest .config/nvim/init.lua mode 0644 sha256 "$SHA" size 18 whole 1
  rec_line link item config:nvim dest .config/nvim/current target init.lua
} >"$T/body"
rebuild
mkdir "$F/root/home/alex/.config/nvim"
printf old >"$F/root/home/alex/.config/nvim/original"
ln -s original "$F/root/home/alex/.config/nvim/old-link"
load
assert_eq "$RST_N" 1 restore-folder-unit
old=${RST_OLD[0]}
replace_all; apply
assert_eq "$RC" 0 restore-folder-place
_rst_backup_name .config/nvim; _rst_node "$RST_BACKUP"
assert_eq "$RST_NODE" "$old" restore-folder-backup-compared
assert_eq "$(readlink "$F/root/home/alex/.config/nvim/current")" init.lua restore-folder-link
load
OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-folder-undo
assert_file "$F/root/home/alex/.config/nvim/original" old restore-folder-original-back
assert_eq "$(readlink "$F/root/home/alex/.config/nvim/old-link")" original restore-folder-original-link
# restore-leaf-link: the original symlink is backed up whole, never followed.
setup
ln -s ../old "$F/root/home/alex/.config/test.conf"
load; replace_all; apply
assert_eq "$RC" 0 restore-leaf-link-replaced
_rst_backup_name .config/test.conf
[ -L "$RST_BACKUP" ] && ok || fail restore-leaf-link-backed-up
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$(readlink "$F/root/home/alex/.config/test.conf")" ../old restore-leaf-link-undo
# restore-undo-save: undo has its own stop and write-failure boundary.
setup
printf original >"$F/root/home/alex/.config/test.conf"
load; replace_all; apply
(child restore.undo 1) 2>/dev/null
assert_eq "$?" 137 restore-undo-stop
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-undo-resume
assert_file "$F/root/home/alex/.config/test.conf" original restore-undo-resume-original
setup; load; apply
load; OMB_IFACE_WORD=undo OMB_TEST_FAIL_AT=restore.undo
_rst_undo >"$T/undo" 2>&1
assert_eq "$?" 1 restore-undo-write-failure
assert_file "$F/root/home/alex/.config/test.conf" 'new configuration' restore-undo-failure-leaves-placement
# restore-packages: one helper call, plain targets, observed pacman outcomes.
setup
basebody
rec_line package item config:test layer packages method pacman target ripgrep version '' guess 0 >>"$T/body"
rebuild
printf available >"$F/cmd/rst_si_ripgrep"
printf missing >"$F/cmd/rst_q_ripgrep"; printf '1\n' >"$F/cmd/rst_q_ripgrep.rc"
load; apply
assert_eq "${RST_STATUS[1]}" failed restore-package-exit-not-evidence
assert_eq "${RST_STATUS[0]}" blocked restore-package-blocks-files
assert_eq "$(grep -c '^omarchy-pkg-add ' "$T/record")" 1 restore-one-package-handoff
load
assert_eq "${RST_STATUS[1]}" failed restore-status-package-failure
INSTALL_TAKES=1
apply
assert_eq "$RC" 0 restore-package-retry
load
assert_eq "${RST_STATUS[1]}" in-place restore-package-observed-installed
setup
basebody
rec_line package item config:test layer packages method pacman target extra/ripgrep version '' guess 0 >>"$T/body"
rebuild; load
assert_eq "${RST_STATUS[1]}" blocked restore-repo-qualified-refused
# restore-opencode-codex: OpenCode combines objects, Codex replaces whole.
setup
printf '{"mcp":{"mine":{"enabled":true}}}\n' >"$T/json-object"
_bndl_sha "$T/json-object"; J=$BNDL_SHA; cp "$T/json-object" "$B/objects/$J"
_bndl_size "$T/json-object"; JS=$BNDL_SIZE
{
  rec_line item id config:agents class config whole 1
  rec_line file item config:agents dest .config/opencode/opencode.json mode 0644 sha256 "$J" size "$JS" whole 1
  rec_line file item config:agents dest .codex/config.toml mode 0600 sha256 "$SHA" size 18 whole 1
} >"$T/body"
rebuild
mkdir -p "$F/root/home/alex/.config/opencode" "$F/root/home/alex/.codex"
printf '{"theme":"omarchy","mcp":{"seed":{"enabled":true}}}\n' >"$F/root/home/alex/.config/opencode/opencode.json"
printf 'old = true\n' >"$F/root/home/alex/.codex/config.toml"
chmod 0600 "$F/root/home/alex/.config/opencode/opencode.json"
load; replace_all; apply
assert_eq "$RC" 0 restore-agent-configs
_rst_node "$RST_HOME/.config/opencode/opencode.json"
assert_contains "$RST_NODE" file:0600: restore-private-opencode-mode
assert_eq "$(jq -r '.theme' "$F/root/home/alex/.config/opencode/opencode.json")" omarchy restore-opencode-keeps-default
assert_eq "$(jq -r '.mcp.mine.enabled and .mcp.seed.enabled' "$F/root/home/alex/.config/opencode/opencode.json")" true restore-opencode-merged
assert_file "$F/root/home/alex/.codex/config.toml" 'new configuration' restore-codex-replaced-whole
load
before=$(t_snapshot "$F/root/home/alex")
apply
assert_eq "$(t_snapshot "$F/root/home/alex")" "$before" restore-opencode-idempotent
# restore-protected: a bundle may never move Omarchy or the restore state.
setup
{
  rec_line item id config:bad class config whole 1
  rec_line file item config:bad dest .config/omarchy/defaults/agent mode 0644 sha256 "$SHA" size 18 whole 1
} >"$T/body"
rebuild; load
assert_eq "${RST_STATUS[0]}" blocked restore-omarchy-default-protected
# restore-bundle-order: partial folders never list; newest corrupt falls back.
setup
cp -R "$B" "${B%/*}/20261023T120000Z"
printf corrupt >"${B%/*}/20261023T120000Z/objects/$SHA"
cp -R "$B" "${B%/*}/20261024T120000Z.partial-123"
load
assert_eq "${RST_BUNDLE##*/}" 20261022T120000Z restore-newest-valid
assert_eq "$(wc -l <"$RST_W/bundles" | tr -d ' ')" 2 restore-no-partial-bundles


# restore-short-stage: interrupted bytes are preserved and the next exclusive
# stage is rebuilt; no unrelated partial file is discarded.
setup
printf original >"$F/root/home/alex/.config/test.conf"
(child restore.log) 2>/dev/null
load
printf partial >"$RST_HOME/.config/test.conf.omb-new-$RST_RUN"
replace_all; apply
assert_eq "$RC" 0 restore-short-stage-recovered
_rst_backup_name .config/test.conf
assert_file "$RST_BACKUP.stage" partial restore-short-stage-preserved

# restore-shared: default discovery uses verified topology and mount identity.
setup
OMB_RESTORE_DIR=''
load
assert_eq "${RST_BUNDLE##*/}" 20261022T120000Z restore-verified-shared-discovery
# restore-nothing-outside-home: all other fixture bytes remain unchanged.
setup
before=$(t_snapshot "$F/root/usr")
load; apply
assert_eq "$(t_snapshot "$F/root/usr")" "$before" restore-only-home
# restore-dry-read: neither a preview nor status creates a state directory.
setup
load
OMB_DRY_RUN=1; apply
[ ! -e "$OMB_STATE_DIR" ] && ok || fail restore-dry-no-state
assert_empty_file "$T/record" restore-dry-no-command
OMB_DRY_RUN=0
# restore-device-boundary: a destination on another device is an item refusal.
setup
printf original >"$F/root/home/alex/.config/test.conf"
eval "$(declare -f _rst_meta | sed '1s/_rst_meta/_rst_real_meta/')"
_rst_meta() {
  _rst_real_meta "$1" || return
  case "$1" in */.config/test.conf) RST_META="another ${RST_META#* }" ;; esac
}
load
assert_eq "${RST_STATUS[0]}" blocked restore-device-boundary
# shellcheck disable=SC2317 # used in later restore invocations
_rst_meta() { _rst_real_meta "$1"; }
# restore-git-mcp: owner commands, one JSON argument, fresh reads and Keep.
setup
{
  rec_line item id settings:test class config whole 0
  rec_line setting item settings:test kind git tool git name user.name value 'Restored Name'
  rec_line setting item settings:test kind mcp tool claude name sample value '{"command":"sample-server","env":{"API_KEY":"${OMB_RESTORE_TEST_SECRET}"}}'
} >"$T/body"
rebuild
printf 'Old Name\n' >"$F/cmd/rst_git_user.name"
mkdir -p "$F/root/home/alex/.local/share/mise/installs/claude-code/1/bin"
: >"$F/root/home/alex/.local/share/mise/installs/claude-code/1/bin/claude-code"
load
assert_eq "${RST_ACTION[0]}" conflict restore-git-reviewed-conflict
replace_all; apply
assert_eq "$RC" 0 restore-settings-owner-commands
assert_eq "$(cat "$F/cmd/rst_git_user.name")" 'Restored Name' restore-git-read-back
assert_eq "$(jq -r '.mcpServers.sample.env.API_KEY' "$F/root/home/alex/.claude.json")" '${OMB_RESTORE_TEST_SECRET}' restore-mcp-variable-reference
assert_contains "$(cat "$T/record")" 'claude mcp add-json sample' restore-mcp-owner-command
assert_not_contains "$(cat "$RST_LOG")" 'Old Name' restore-no-old-setting-content-in-state
load
assert_eq "${RST_STATUS[0]}" in-place restore-settings-idempotent
assert_eq "${RST_STATUS[1]}" needs-secret restore-mcp-idempotent
# restore-shell-line: the Bash source line is built whole, exactly once.
setup
{
  rec_line item id shell:bash class config whole 1
  rec_line file item shell:bash dest .config/omarchy-mac-bootstrap/shell.bash mode 0644 sha256 "$SHA" size 18 whole 1
} >"$T/body"
rebuild
printf '# Omarchy Bash defaults\n' >"$F/root/home/alex/.bashrc"
load; _rst_dataset; generated_review=$RST_GEN
sleep 1
load; _rst_dataset
assert_eq "$RST_GEN" "$generated_review" restore-review-generation-generated
replace_all; apply
assert_eq "$RC" 0 restore-shell-line-place
assert_eq "$(grep -c '# omarchy-mac-bootstrap' "$F/root/home/alex/.bashrc")" 1 restore-shell-line-once
load
before=$(t_snapshot "$F/root/home/alex")
apply
assert_eq "$(t_snapshot "$F/root/home/alex")" "$before" restore-shell-line-rerun
# restore-method-layers: runtime first, then npm/uv, all observed as files.
setup
{
  rec_line item id packages:tools class config whole 0
  rec_line package item packages:tools layer runtimes method mise target node version 22 guess 0
  rec_line package item packages:tools layer tools method npm target example-cli version 1.2.3 guess 0
  rec_line package item packages:tools layer tools method uv target example-tool version 1.2.3 guess 0
} >"$T/body"
rebuild
load
INSTALL_TAKES=1
apply
assert_eq "$RC" 0 restore-method-layers
assert_eq "$(grep -E '^(env |npm |uv )' "$T/record" | awk '{print $1}' | tr '\n' ' ')" 'env npm uv ' restore-method-order
load
assert_eq "${RST_STATUS[0]} ${RST_STATUS[1]} ${RST_STATUS[2]}" 'in-place in-place in-place' restore-method-files
assert_contains "$(cat "$T/record")" 'MISE_NODE_COMPILE=false MISE_PYTHON_COMPILE=false MISE_RUBY_COMPILE=false MISE_ERLANG_COMPILE=false' restore-no-runtime-source-build
assert_contains "$(cat "$T/record")" 'npm install -g --ignore-scripts -- example-cli@1.2.3' restore-no-npm-build-scripts
assert_contains "$(cat "$T/record")" 'uv tool install --no-build -- example-tool==1.2.3' restore-no-uv-source-build
# restore-agents: install through the shared table, sign-in by presence only.
setup
{
  rec_line item id ai:codex class config whole 0
  rec_line package item ai:codex layer ai method agent target codex version '' guess 0
} >"$T/body"
rebuild
load; apply
assert_eq "${RST_STATUS[0]}" needs-sign-in restore-agent-needs-sign-in
load
assert_eq "$RST_STATE" complete restore-agent-waits-on-person
mkdir -p "$F/root/home/alex/.codex"
printf 'presence only; never parsed\n' >"$F/root/home/alex/.codex/auth.json"
load
assert_eq "${RST_STATUS[0]}" in-place restore-agent-sign-in-presence
mv "$F/root/home/alex/.codex/auth.json" "$F/root/home/alex/.codex/.credentials.json"
load
assert_eq "${RST_STATUS[0]}" in-place restore-agent-table-sign-in-path

# restore-agent-receipt: the shared table owns the version check. Only its
# successful ran=1 result becomes the exact, flushed line Health consumes.
assert_eq "$(grep -cFx $'agent\ttool=codex\tran=1' "$RST_LOG")" 1 restore-agent-exact-receipt
before=$(t_snapshot "$F/root/home/alex")
: >"$T/record"
apply
assert_empty_file "$T/record" restore-agent-rerun-no-command
assert_eq "$(t_snapshot "$F/root/home/alex")" "$before" restore-agent-rerun-no-receipt
{
  setup
  {
    rec_line item id ai:codex class config whole 0
    rec_line package item ai:codex layer ai method agent target codex version '' guess 0
  } >"$T/body"
  rebuild
  (child restore.agent) 2>/dev/null
  assert_eq "$?" 137 restore-agent-receipt-stop
  load
  assert_eq "$(grep -cFx $'agent\ttool=codex\tran=1' "$RST_LOG")" 1 restore-agent-receipt-stop-durable
  assert_eq "$(grep -cFx $'agent\ttool=codex\tran=1' "$T/flushed-lines")" 1 restore-agent-receipt-stop-flushed
  apply
  assert_eq "$RC" 0 restore-agent-receipt-stop-resume
  assert_eq "$(grep -cFx $'agent\ttool=codex\tran=1' "$RST_LOG")" 1 restore-agent-receipt-not-duplicated
  setup
  {
    rec_line item id ai:codex class config whole 0
    rec_line package item ai:codex layer ai method agent target codex version '' guess 0
  } >"$T/body"
  rebuild; load
  OMB_TEST_FAIL_AT=restore.agent
  apply
  assert_eq "$RC" 1 restore-agent-receipt-write-failure
  assert_eq "$(grep -cFx $'agent\ttool=codex\tran=1' "$RST_LOG")" 0 restore-agent-receipt-no-false-success
  rst_apply_judge 1
  assert_eq "$CORE_FINDING" unexpected restore-agent-log-failure-not-complete
  OMB_TEST_FAIL_AT=''
  # The torn tail is ignored by both readers; a complete receipt is admitted
  # even when ordinary events appear after it.
  printf 'agent\ttool=opencode\tran=' >>"$RST_LOG"
  load
  assert_eq "$RST_STATE" complete restore-agent-torn-receipt-ignored
}
# restore-health-counts: one strict numeric line, current file judgments,
# failed installs and person-waiting items; no frontend projection or writes.
setup
assert_eq "$(rst_status_counts)" '0 0 0 1' restore-counts-untried
load; apply
before=$(t_snapshot "$F/root/home/alex")
: >"$T/record"
assert_eq "$(rst_status_counts)" '1 0 0 0' restore-counts-verified
rst_status_counts >"$T/counts"
assert_eq "$(wc -l <"$T/counts" | tr -d ' ')" 1 restore-counts-exactly-one-line
counts=$(_rst_rows() { return 99; }; rst_status_counts)
assert_eq "$counts" '1 0 0 0' restore-counts-no-projection
assert_eq "$(t_snapshot "$F/root/home/alex")" "$before" restore-counts-read-only
assert_empty_file "$T/record" restore-counts-no-run
printf changed >"$F/root/home/alex/.config/test.conf"
assert_eq "$(rst_status_counts)" '0 0 0 1' restore-counts-rejudge-destination
load; apply
assert_eq "$(rst_status_counts)" '0 1 0 0' restore-counts-kept
printf corrupt >"$B/objects/$SHA"
rst_status_counts >"$T/counts"
assert_eq "$?" 1 restore-counts-refuse-corrupt
assert_empty_file "$T/counts" restore-counts-no-error-text
setup
basebody
rec_line package item config:test layer packages method pacman target ripgrep version '' guess 0 >>"$T/body"
rebuild
printf available >"$F/cmd/rst_si_ripgrep"
printf missing >"$F/cmd/rst_q_ripgrep"; printf '1\n' >"$F/cmd/rst_q_ripgrep.rc"
load; apply
assert_eq "$(rst_status_counts)" '0 0 1 1' restore-counts-failed-and-blocked

# restore-replacement-admission and basis: only current conflict destinations,
# joined contiguously, bound with both source seal and reviewed fingerprints.
setup
printf original >"$F/root/home/alex/.config/test.conf"
load
_rst_dataset
CORE_REQ_ARGS=3 CORE_REQ_ARG_NAME=(bundle replace.1 review)
CORE_REQ_ARG_VALUE=(20261022T120000Z $'omb-replace 1\nreplace\tdest=.config/test.conf\n' "$RST_GEN")
rst_apply_basis
assert_eq "$?" 0 restore-valid-replacement
printf changed >"$F/root/home/alex/.config/test.conf"
rst_apply_basis
assert_eq "$?" 1 restore-review-generation
assert_eq "$RST_INVALID_CODE" changed restore-review-generation-code
assert_eq "$CORE_BASIS" '' restore-execute-basis-refuses-changed
load; _rst_dataset; CORE_REQ_ARG_VALUE[2]=$RST_GEN
CORE_REQ_ARG_VALUE[1]=$'omb-replace 1\nreplace\tdest=.config/unknown\n'
rst_apply_basis
assert_eq "$?" 1 restore-unknown-replacement-refused
CORE_REQ_ARG_NAME[1]=replace.2
rst_apply_basis
assert_eq "$?" 1 restore-noncontiguous-replacement-refused
CORE_REQ_ARGS=0 CORE_REQ_ARG_NAME=() CORE_REQ_ARG_VALUE=()
# restore-protected-ancestor: changing the entry type must never permit moving
# a whole directory that contains an Omarchy-owned file or restore state.
setup
{
  rec_line item id config:bad class config whole 1
  rec_line file item config:bad dest .config/omarchy mode 0644 sha256 "$SHA" size 18 whole 1
} >"$T/body"
rebuild; load
assert_eq "${RST_STATUS[0]}" blocked restore-protected-ancestor-file
# restore-review-content: the exact target/version and the default's identity
# are visible; ordinary personal .config files are labelled other.
setup
cp "$F/root/etc/skel/.config/test.conf" "$F/root/home/alex/.config/test.conf"
load; _rst_rows
assert_contains "$(cat "$RST_W/conflicts")" 'Omarchy%27s%20default' restore-default-labelled
assert_contains "$(cat "$RST_W/diff")" 'new%20configuration' restore-diff-bundle-side
assert_contains "$(cat "$RST_W/diff")" 'Omarchy%20default' restore-diff-current-side
printf personal >"$F/root/home/alex/.config/test.conf"
load; _rst_rows
assert_contains "$(cat "$RST_W/conflicts")" 'col=other' restore-personal-conflict-labelled
# restore-observed-progress: one item record precedes its result messages.
setup; load
core_emit() { rec_line "$@" >>"$T/progress"; }
core_message() { rec_line message level "$1" text "$2" >>"$T/progress"; }
RST_CORE=1
apply
assert_eq "$RC" 0 restore-progress-run
assert_contains "$(head -n 1 "$T/progress")" $'progress\taction=restore.apply' restore-progress-before-message
rst_apply_judge 0
assert_eq "$CORE_FINDING" completed restore-judge-reads-files
RST_CORE=0

# restore-placement-return: a failed transfer puts the original back; undo
# can also settle the crash window before a placement or after an obstruction.
setup
printf original >"$F/root/home/alex/.config/test.conf"
load; replace_all
OMB_TEST_FAIL_AT=restore.place
apply
assert_file "$RST_HOME/.config/test.conf" original restore-placement-return
OMB_TEST_FAIL_AT=''
setup
printf original >"$F/root/home/alex/.config/test.conf"
(child restore.backup) 2>/dev/null
load
mkdir "$RST_HOME/.config/test.conf"
printf obstacle >"$RST_HOME/.config/test.conf/entry"
load
assert_contains "${RST_REASON[0]}" "$RST_BACK/" restore-pending-original-location
apply
assert_eq "$RC" 1 restore-pending-original-default-rerun
OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 1 restore-pending-original-refuses-occupied
rm "$RST_HOME/.config/test.conf/entry"
rmdir "$RST_HOME/.config/test.conf"
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-pending-original-undo
assert_file "$RST_HOME/.config/test.conf" original restore-pending-original-returned

# restore-undo-edit-during-move: fingerprint the moved object, then return an
# intervening editor save instead of leaving its destination absent.
setup; load; apply; load
RESTORE_TEST_EDIT_ON_MOVE=1 OMB_IFACE_WORD=undo
_rst_undo >"$T/undo" 2>&1
assert_eq "$?" 1 restore-undo-edit-during-move
assert_file "$RST_HOME/.config/test.conf" edited restore-undo-edit-put-back

# restore-undo-blocked-load and restore-undo-empty-load never claim success.
eval "$(declare -f _rst_load | sed '1s/_rst_load/_restore_saved_load/')"
_rst_load() { RST_STATE=blocked RST_N=0 RST_HOME=''; return 0; }
CORE_FINDING=pending
rst_undo_judge 1
assert_eq "$CORE_FINDING" unexpected restore-undo-blocked-load
OMB_IFACE_WORD=undo
rst_undo_run
assert_eq "$?" 1 restore-undo-blocked-run
_rst_load() { RST_STATE=complete RST_N=0 RST_HOME=''; return 0; }
CORE_FINDING=pending
rst_undo_judge 1
assert_eq "$CORE_FINDING" unexpected restore-undo-empty-load
# shellcheck disable=SC2317
_rst_load() { _restore_saved_load "$@"; }

# restore-undo-kept: an ordinary kept conflict is outside undo's work.
setup
basebody
rec_line file item config:test dest .config/another.conf mode 0644 sha256 "$SHA" size 18 whole 1 >>"$T/body"
rebuild
printf kept >"$F/root/home/alex/.config/another.conf"
load; apply; load
OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-undo-kept-run
rst_undo_judge 0
assert_eq "$CORE_FINDING" completed restore-undo-kept-judge
assert_file "$RST_HOME/.config/another.conf" kept restore-undo-kept-untouched

# restore-stage-repeated: preserve multiple partial stages with distinct names.
setup
printf original >"$F/root/home/alex/.config/test.conf"
(child restore.log) 2>/dev/null
load; _rst_backup_name .config/test.conf
printf previous >"$RST_BACKUP.stage"
printf partial >"$RST_HOME/.config/test.conf.omb-new-$RST_RUN"
replace_all; apply
assert_eq "$RC" 0 restore-stage-repeated
assert_file "$RST_BACKUP.stage" previous restore-stage-old-copy-preserved
assert_file "$RST_BACKUP.stage.1" partial restore-stage-fresh-copy-preserved
# restore-undo-partial-copy: a real short write and an existing preserved
# stage do not trap subsequent attempts in a permanent refusal.
load
RESTORE_TEST_PARTIAL_COPY=1 OMB_IFACE_WORD=undo
_rst_undo >"$T/undo" 2>&1
assert_eq "$?" 1 restore-undo-partial-copy-fails
_rst_backup_name .config/test.conf
printf earlier >"$RST_BACKUP.undo-stage"
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-undo-partial-copy-retry
assert_file "$RST_BACKUP.undo-stage.1" partial restore-undo-partial-copy-preserved
# restore-undo-partial-after-move: the same recovery works after the
# destination moved, before a stopped undo could return its original.
load; replace_all; apply; load
_rst_backup_name .config/test.conf
# Bind the actual original and placement for this synthetic crash boundary.
_rst_node "$RST_BACKUP"; undo_old=$RST_NODE
_rst_node "$RST_HOME/.config/test.conf"; undo_after=$RST_NODE
_rst_log undo-plan "${RST_ITEM[0]}" .config/test.conf "$undo_old" "$undo_after" ready
if [ -e "$RST_BACKUP.placed" ]; then mv "$RST_BACKUP.placed" "$RST_BACKUP.placed.saved"; fi
mv "$RST_HOME/.config/test.conf" "$RST_BACKUP.placed"
printf partial >"$RST_HOME/.config/test.conf.omb-undo-$RST_RUN"
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-undo-partial-after-move
assert_file "$RST_HOME/.config/test.conf" original restore-undo-partial-after-move-original

# restore-repeated-cycles: neither original nor placed names are overwritten.
for cycle in 1 2; do
  load; replace_all; apply
  assert_eq "$RC" 0 "restore-repeated-cycles-apply-$cycle"
  load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
  assert_eq "$?" 0 "restore-repeated-cycles-undo-$cycle"
  assert_file "$RST_HOME/.config/test.conf" original "restore-repeated-cycles-original-$cycle"
done
# restore-undo-continues: refusing the first item in reverse order still
# allows the independent earlier item to be undone.
setup
basebody
rec_line file item config:test dest .config/another.conf mode 0644 sha256 "$SHA" size 18 whole 1 >>"$T/body"
rebuild; load; apply
load; RESTORE_TEST_EDIT_ON_MOVE=1 OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 1 restore-undo-continues-refused
[ ! -e "$RST_HOME/.config/test.conf" ] && ok || fail restore-undo-continues-other-item
assert_file "$RST_HOME/.config/another.conf" edited restore-undo-continues-edited-item

# restore-private-setting-backups: Unicode and trailing newlines survive,
# existing MCP definitions return, and only private filenames appear in hints.
setup
{
  rec_line item id settings:test class config whole 0
  rec_line setting item settings:test kind git tool git name user.name value NEWSETTINGVALUE
  rec_line setting item settings:test kind mcp tool claude name sample value '{"command":"new-setting-server"}'
} >"$T/body"
rebuild
printf 'Jos\303\251 OLDSETTINGVALUE\n\n\n' >"$F/cmd/rst_git_user.name"
cp "$F/cmd/rst_git_user.name" "$T/old-git-output"
printf '{"mcpServers":{"sample":{"command":"old-setting-server"}}}\n' >"$F/root/home/alex/.claude.json"
mkdir -p "$F/root/home/alex/.local/share/mise/installs/claude-code/1/bin"
: >"$F/root/home/alex/.local/share/mise/installs/claude-code/1/bin/claude-code"
load; replace_all; apply
assert_eq "$RC" 0 restore-private-setting-backups
_rst_backup_name git:user.name
_rst_node "$RST_BACKUP.setting"
assert_contains "$RST_NODE" file:0600: restore-setting-backup-private
assert_contains "$(cat "$T/out")" "$RST_BACKUP.setting" restore-setting-hint-path
for value in OLDSETTINGVALUE NEWSETTINGVALUE old-setting-server new-setting-server; do
  assert_not_contains "$(cat "$T/out")" "$value" "restore-setting-terminal-withheld-$value"
  assert_not_contains "$(cat "$(log_file)")" "$value" "restore-setting-log-withheld-$value"
  assert_not_contains "$(cat "$RST_LOG")" "$value" "restore-setting-journal-withheld-$value"
done
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-settings-undo
cmp -s "$T/old-git-output" "$F/cmd/rst_git_user.name" && ok || fail restore-settings-undo-exact-bytes
assert_eq "$(jq -r '.mcpServers.sample.command' "$RST_HOME/.claude.json")" old-setting-server restore-settings-undo-mcp
# restore-setting-save: a failed/short backup cannot change the setting;
# a stop after the durable backup is safe to resume without replacing it.
setup
{
  rec_line item id settings:test class config whole 0
  rec_line setting item settings:test kind git tool git name user.name value replacement
} >"$T/body"
rebuild
printf 'original\n' >"$F/cmd/rst_git_user.name"
load; replace_all
OMB_TEST_FAIL_AT=restore.setting
apply
assert_eq "$RC" 1 restore-setting-save-failure
assert_file "$F/cmd/rst_git_user.name" original restore-setting-save-failure-original
OMB_TEST_FAIL_AT=''
RESTORE_TEST_SHORT_SETTING=1
load; replace_all; apply
assert_eq "$RC" 1 restore-setting-short-write
assert_file "$F/cmd/rst_git_user.name" original restore-setting-short-write-original
load; replace_all; apply
assert_eq "$RC" 0 restore-setting-short-write-retry
_rst_backup_name git:user.name
assert_file "$RST_BACKUP.setting.partial" partial restore-setting-short-write-preserved
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
(child restore.setting) 2>/dev/null
assert_eq "$?" 137 restore-setting-save-stop
assert_file "$F/cmd/rst_git_user.name" original restore-setting-stop-original
load; replace_all; apply
assert_eq "$RC" 0 restore-setting-save-resume
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_file "$F/cmd/rst_git_user.name" original restore-setting-save-undo

# restore-withheld-run: the production run boundary masks execute, refusal,
# dry-run and recorder output without changing the real command's argument.
(
  run() { _restore_real_run "$@"; }
  unset OMB_FIXTURE
  OMB_TEST_RECORD=$T/withheld-record
  : >"$OMB_TEST_RECORD"
  run_withheld 2 printf PRIVATESETTINGVALUE
  assert_not_contains "$(cat "$OMB_TEST_RECORD")" PRIVATESETTINGVALUE restore-withheld-record
  assert_contains "$(cat "$OMB_TEST_RECORD")" withheld restore-withheld-record-marker
  unset OMB_TEST_RECORD
  run_withheld 2 printf PRIVATESETTINGVALUE >"$T/withheld-actual"
  assert_file "$T/withheld-actual" PRIVATESETTINGVALUE restore-withheld-actual-argument
  OMB_DRY_RUN=1
  run_withheld 2 printf PRIVATESETTINGVALUE >"$T/withheld-dry"
  assert_not_contains "$(cat "$T/withheld-dry")" PRIVATESETTINGVALUE restore-withheld-dry
  OMB_DRY_RUN=0 OMB_INTENT=read
  run_withheld 2 printf PRIVATESETTINGVALUE >"$T/withheld-refused" 2>&1
  assert_eq "$?" 1 restore-withheld-refusal
  assert_not_contains "$(cat "$T/withheld-refused")" PRIVATESETTINGVALUE restore-withheld-refused-output
  assert_not_contains "$(cat "$(log_file)")" PRIVATESETTINGVALUE restore-withheld-real-log
  printf '%s %s\n' "$T_PASS" "$T_FAIL" >"$T/withheld-counts"
)
read -r T_PASS T_FAIL <"$T/withheld-counts"

# restore-setting-absent-and-empty: empty is a real reviewed value; absent
# settings and servers are removed again by undo.
setup
{
  rec_line item id settings:test class config whole 0
  rec_line setting item settings:test kind git tool git name user.name value restored
  rec_line setting item settings:test kind mcp tool claude name sample value '{"command":"sample-server"}'
} >"$T/body"
rebuild
: >"$F/cmd/rst_git_user.name"
load
assert_eq "${RST_ACTION[0]}" conflict restore-setting-empty-is-conflict
printf '1\n' >"$F/cmd/rst_git_user.name.rc"
mkdir -p "$F/root/home/alex/.local/share/mise/installs/claude-code/1/bin"
: >"$F/root/home/alex/.local/share/mise/installs/claude-code/1/bin/claude-code"
load; apply
assert_eq "$RC" 0 restore-setting-absent-place
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-setting-absent-undo
assert_eq "$(cat "$F/cmd/rst_git_user.name.rc")" 1 restore-setting-absent-git-unset
assert_eq "$(jq -r '.mcpServers.sample // "absent"' "$RST_HOME/.claude.json")" absent restore-setting-absent-mcp-removed

# restore-runtime-executable: empty folders and nonexecutable files fail the
# observation, and a successful stand-in must create executable bytes.
setup
{
  rec_line item id runtime:test class config whole 0
  rec_line package item runtime:test layer runtimes method mise target node version 22 guess 0
} >"$T/body"
rebuild
mkdir -p "$F/root/home/alex/.local/share/mise/installs/node/22/bin"
load
assert_eq "${RST_STATUS[0]}" ready restore-runtime-empty-folder
printf partial >"$RST_HOME/.local/share/mise/installs/node/22/bin/node"
chmod 0644 "$RST_HOME/.local/share/mise/installs/node/22/bin/node"
load
assert_eq "${RST_STATUS[0]}" ready restore-runtime-nonexecutable
apply
assert_eq "${RST_STATUS[0]}" failed restore-runtime-failed-install
INSTALL_TAKES=1; load; apply
assert_eq "$RC" 0 restore-runtime-executable

# restore-protected-skill-links: leaves and every ancestor refuse Replace.
setup; load
for dest in .agents/skills/omarchy .claude/skills/omarchy .codex/skills/omarchy .config/opencode/skills/omarchy; do
  while [ -n "$dest" ]; do
    if _rst_dest_ok "$dest"; then fail "restore-protected-skill-link-$dest"; else ok; fi
    [ "${dest%/*}" != "$dest" ] || break
    dest=${dest%/*}
  done
done
# restore-stage-directory-link: no cp into a precreated directory or link.
setup
{
  rec_line item id config:tree class config whole 1
  rec_line dir item config:tree dest .config/tree mode 0755
  rec_line file item config:tree dest .config/tree/entry mode 0644 sha256 "$SHA" size 18 whole 1
} >"$T/body"
rebuild
mkdir -p "$T/outside"
printf outside >"$T/outside/entry"
load
RESTORE_TEST_STAGE_LINK=1
apply
assert_eq "$RC" 1 restore-stage-directory-link-refused
assert_file "$T/outside/entry" outside restore-stage-directory-link-no-write
rm -rf "$T/outside"

# restore-undo-latest-run: a newly exported bundle has no restore history.
setup; load; apply
new_bundle=${B%/*}/20261023T120000Z
cp -R "$B" "$new_bundle"
sed 's/2026-10-22T12:00:00Z/2026-10-23T12:00:00Z/' "$B/bundle.omb" | sed '/^seal/d' >"$new_bundle/bundle.omb"
rec_seal_write "$new_bundle/bundle.omb"
load
assert_eq "${RST_BUNDLE##*/}" 20261023T120000Z restore-undo-new-bundle-visible
OMB_IFACE_WORD=undo
rst_undo_run >"$T/undo" 2>&1
assert_eq "$?" 0 restore-undo-latest-run
[ ! -e "$RST_HOME/.config/test.conf" ] && ok || fail restore-undo-latest-run-file
RST_CORE=0
# restore-stale-stage-name: only a stage matching the placement is removed.
setup
printf original >"$F/root/home/alex/.config/test.conf"
(child restore.place) 2>/dev/null
load
cp -p "$RST_HOME/.config/test.conf" "$RST_HOME/.config/test.conf.omb-new-$RST_RUN"
apply
assert_eq "$RC" 0 restore-stale-stage-name-rerun
[ ! -e "$RST_HOME/.config/test.conf.omb-new-$RST_RUN" ] && ok || fail restore-stale-stage-name-cleaned
# restore-private-mode and restore-parent-modes: generated files respect a
# more private original; ordinary config parents remain traversable.
setup
{
  rec_line item id shell:bash class config whole 1
  rec_line file item shell:bash dest .config/omarchy-mac-bootstrap/shell.bash mode 0644 sha256 "$SHA" size 18 whole 1
} >"$T/body"
rebuild
printf private >"$F/root/home/alex/.bashrc"
chmod 0600 "$F/root/home/alex/.bashrc"
load; replace_all; apply
_rst_node "$RST_HOME/.bashrc"
assert_contains "$RST_NODE" file:0600: restore-private-bashrc-mode
_rst_meta "$RST_HOME/.config/omarchy-mac-bootstrap"
assert_eq "${RST_META##* }" 0755 restore-parent-config-mode
_rst_parents .local/new-config/file 1
_rst_meta "$RST_HOME/.local/new-config"
assert_eq "${RST_META##* }" 0755 restore-parent-local-mode
_rst_parents .private/new/file 1
_rst_meta "$RST_HOME/.private/new"
assert_eq "${RST_META##* }" 0700 restore-parent-private-mode
# restore-scratch-guard: an inherited arbitrary folder is never cleared.
setup
saved_scratch=$OMB_TMP
OMB_TMP=$T/unowned-scratch
mkdir -p "$OMB_TMP/restore/want"
printf preserve >"$OMB_TMP/restore/want/entry"
_rst_load
assert_eq "$?" 1 restore-scratch-guard
assert_file "$OMB_TMP/restore/want/entry" preserve restore-scratch-guard-preserves-bytes
OMB_TMP=$saved_scratch

# restore-generated-backup-resume: regenerate from the recorded original,
# including entries that exist only in that original, after its backup moved.
for generated in bashrc opencode; do
  setup
  if [ "$generated" = bashrc ]; then
    {
      rec_line item id shell:bash class config whole 1
      rec_line file item shell:bash dest .config/omarchy-mac-bootstrap/shell.bash mode 0644 sha256 "$SHA" size 18 whole 1
    } >"$T/body"
    dest=.bashrc
    printf '# custom Bash lines\nalias mine=true\n' >"$F/root/home/alex/$dest"
  else
    printf '{"bundle":true}\n' >"$T/json"
    _bndl_sha "$T/json"; json_sha=$BNDL_SHA
    _bndl_size "$T/json"; json_size=$BNDL_SIZE
    cp "$T/json" "$B/objects/$json_sha"
    {
      rec_line item id config:opencode class config whole 1
      rec_line file item config:opencode dest .config/opencode/opencode.json mode 0644 sha256 "$json_sha" size "$json_size" whole 1
    } >"$T/body"
    dest=.config/opencode/opencode.json
    mkdir -p "$F/root/home/alex/${dest%/*}"
    printf '{"custom":{"mine":true}}\n' >"$F/root/home/alex/$dest"
  fi
  rebuild
  (child restore.backup) 2>/dev/null
  assert_eq "$?" 137 "restore-generated-backup-stop-$generated"
  load; _rst_history "$dest"
  recorded_after=$RST_H_AFTER
  if [ "$generated" = bashrc ]; then n=1; else n=0; fi
  assert_eq "${RST_NEW[n]}" "$recorded_after" "restore-generated-backup-review-$generated"
  apply
  assert_eq "$RC" 0 "restore-generated-backup-resume-$generated"
  if [ "$generated" = bashrc ]; then
    assert_contains "$(cat "$RST_HOME/$dest")" 'alias mine=true' restore-generated-backup-bashrc-custom
  else
    assert_eq "$(jq -r '.custom.mine and .bundle' "$RST_HOME/$dest")" true restore-generated-backup-opencode-custom
  fi
done

# restore-readonly-directory: review and reload keep reusable scratch writable;
# only the placed tree takes the original's more private root mode.
setup
{
  rec_line item id config:tree class config whole 1
  rec_line dir item config:tree dest .config/tree mode 0755
  rec_line file item config:tree dest .config/tree/entry mode 0644 sha256 "$SHA" size 18 whole 1
} >"$T/body"
rebuild
mkdir "$F/root/home/alex/.config/tree"
printf original >"$F/root/home/alex/.config/tree/entry"
chmod 0555 "$F/root/home/alex/.config/tree"
load
readonly_src=${RST_SRC[0]}
[ -w "$readonly_src" ] && ok || fail restore-readonly-directory-scratch-writable
replace_all; apply
readonly_tree=$F/root/home/alex/.config/tree
if [ "$RC" != 0 ]; then
  # macOS refuses a cross-parent rename of a 0555 directory. The Linux
  # placement stand-in must still reach that move, after rebuilding scratch
  # and producing the correctly restricted stage, and keep the original.
  assert_contains "${RST_REASON[0]}" 'The original could not be moved whole' restore-readonly-directory-backup-refusal
  assert_file "$readonly_tree/entry" original restore-readonly-directory-original
  readonly_tree=$readonly_tree.omb-new-$RST_RUN
fi
_rst_node "$readonly_tree"
assert_contains "$RST_NODE" dir:0555: restore-readonly-directory-mode
assert_file "$readonly_tree/entry" 'new configuration' restore-readonly-directory-bytes
if [ "$RC" != 0 ]; then
  load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
  assert_eq "$?" 0 restore-readonly-directory-stage-undo
  [ ! -e "$readonly_tree" ] && ok || fail restore-readonly-directory-stage-cleaned
fi
# Allow cleanup on the deliberately broken implementation too.
chmod u+w "$readonly_src" "$F/root/home/alex/.config/tree"
if [ -d "$readonly_tree" ]; then chmod u+w "$readonly_tree"; fi
_rst_backup_name .config/tree
if [ -d "$RST_BACKUP" ]; then chmod u+w "$RST_BACKUP"; fi

# restore-self-check-refuses-clobber: an option-ignoring mv is caught on the
# home's filesystem before an original, a package or a destination changes.
for behavior in 1 unknown; do
  setup
  printf original >"$F/root/home/alex/.config/test.conf"
  load; replace_all
  RESTORE_TEST_CLOBBER=$behavior
  apply
  assert_eq "$RC" 1 "restore-self-check-refuses-clobber-$behavior"
  assert_contains "$(cat "$T/out")" 'no-clobber' "restore-self-check-plain-reason-$behavior"
  assert_file "$F/root/home/alex/.config/test.conf" original "restore-self-check-before-placement-$behavior"
  assert_not_contains "$(cat "$T/record")" 'omarchy-pkg-add' "restore-self-check-before-install-$behavior"
done

# restore-backend-unverified: a successful backend may use an unknown install
# name; it warns, never blocks later files, and is not counted as verified.
setup
basebody
rec_line package item config:test layer tools method mise-backend target github:owner/tool version 1 guess 0 >>"$T/body"
rebuild; load
INSTALL_TAKES=1 RESTORE_TEST_BACKEND_NO_FOLDER=1
apply
assert_eq "$RC" 0 restore-backend-unverified-continues
assert_eq "${RST_STATUS[1]}" unverified restore-backend-unverified-state
assert_contains "$(cat "$T/out")" 'not verified' restore-backend-unverified-warning
assert_contains "$(tail -n 1 "$T/out")" '1 unverified; nothing showed these items installed' restore-backend-unverified-final-count
assert_file "$RST_HOME/.config/test.conf" 'new configuration' restore-backend-unverified-later-file
assert_eq "$(rst_status_counts)" '1 0 0 1' restore-backend-unverified-count
load; : >"$T/record"; apply
assert_empty_file "$T/record" restore-backend-unverified-no-reinstall
assert_contains "$(tail -n 1 "$T/out")" '1 unverified; nothing showed these items installed' restore-backend-unverified-rerun-summary

# restore-second-replace-hint: follow the advice both during review (the last
# placement is still complete) and after a second Replace was refused.
for hint_stage in review placement; do
  setup
  printf original >"$F/root/home/alex/.config/test.conf"
  chmod 0664 "$F/root/home/alex/.config/test.conf"
  load; replace_all; apply
  printf edited >"$RST_HOME/.config/test.conf"
  load
  if [ "$hint_stage" = placement ]; then replace_all; apply; fi
  _rst_backup_name .config/test.conf
  hint=${RST_REASON[0]}
  assert_contains "$hint" "$RST_BACKUP" "restore-second-replace-original-location-$hint_stage"
  assert_contains "$hint" 'Move the current destination' "restore-second-replace-actionable-hint-$hint_stage"
  assert_file "$RST_HOME/.config/test.conf" edited "restore-second-replace-preserves-current-$hint_stage"
  mv "$RST_HOME/.config/test.conf" "$RST_HOME/.config/test.saved"
  assert_contains "$hint" 'cp -a -T' "restore-second-replace-copy-command-$hint_stage"
  # Execute exactly the printed command through the fixture's command seam.
  case "$hint" in *'cp -a -T'*) run cp -a -T -- "$RST_BACKUP" "$RST_HOME/.config/test.conf" ;; esac
  _rst_node "$RST_HOME/.config/test.conf"
  assert_contains "$RST_NODE" file:0664: "restore-second-replace-copy-mode-$hint_stage"
  load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
  assert_eq "$?" 0 "restore-second-replace-follow-hint-undo-$hint_stage"
  assert_file "$RST_HOME/.config/test.conf" original "restore-second-replace-follow-hint-original-$hint_stage"
  load; replace_all; apply
  assert_eq "$RC" 0 "restore-second-replace-follow-hint-apply-$hint_stage"
  assert_file "$RST_HOME/.config/test.saved" edited "restore-second-replace-follow-hint-edit-$hint_stage"
  assert_file "$RST_HOME/.config/test.conf" 'new configuration' "restore-second-replace-follow-hint-new-$hint_stage"
done

# restore-undo-stage-cleanup: a refused or failed undo removes only its
# completed copy, once the retained backup proves those bytes redundant.
for failure in checkpoint edit; do
  setup
  printf original >"$F/root/home/alex/.config/test.conf"
  load; replace_all; apply; load
  if [ "$failure" = checkpoint ]; then OMB_TEST_FAIL_AT=restore.undo
  else RESTORE_TEST_EDIT_ON_MOVE=1; fi
  OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
  assert_eq "$?" 1 "restore-undo-stage-cleanup-refuses-$failure"
  [ ! -e "$RST_HOME/.config/test.conf.omb-undo-$RST_RUN" ] && ok || fail "restore-undo-stage-cleanup-$failure"
  _rst_backup_name .config/test.conf
  assert_file "$RST_BACKUP" original "restore-undo-stage-cleanup-backup-$failure"
done
setup
printf original >"$F/root/home/alex/.config/test.conf"
(child restore.backup) 2>/dev/null
(child restore.log 1) 2>/dev/null
assert_eq "$?" 137 restore-undo-new-stage-stop-after-undone
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-undo-new-stage-run
[ ! -e "$RST_HOME/.config/test.conf.omb-new-$RST_RUN" ] && ok || fail restore-undo-new-stage-cleanup
assert_file "$RST_HOME/.config/test.conf" original restore-undo-new-stage-original

# restore-undo-never-placed: a third state without a pending original is
# skipped silently, regardless of whether a stage was ever created.
setup
printf original >"$F/root/home/alex/.config/test.conf"
load; replace_all; OMB_TEST_FAIL_AT=restore.stage; apply
printf edited >"$RST_HOME/.config/test.conf"
OMB_TEST_FAIL_AT=''
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-undo-never-placed-skipped
rst_undo_judge 0
assert_eq "$CORE_FINDING" completed restore-undo-never-placed-judge
assert_file "$RST_HOME/.config/test.conf" edited restore-undo-never-placed-current
assert_not_contains "$(cat "$T/undo")" '.config/test.conf' restore-undo-never-placed-silent
RST_CORE=0
for recovery in changed missing; do
  setup
  printf original >"$F/root/home/alex/.config/test.conf"
  (child restore.backup) 2>/dev/null
  load; _rst_backup_name .config/test.conf
  if [ "$recovery" = changed ]; then printf edited >"$RST_BACKUP"; else rm "$RST_BACKUP"; fi
  OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
  assert_eq "$?" 1 "restore-undo-pending-original-$recovery-refuses"
  rst_undo_judge 1
  assert_eq "$CORE_FINDING" unexpected "restore-undo-pending-original-$recovery-judge"
  RST_CORE=0
done

# restore-undo-unlogged: the machine can change before its journal append.
setup
(child restore.place) 2>/dev/null
assert_eq "$?" 137 restore-undo-unlogged-file-stop
load; _rst_history .config/test.conf
assert_eq "$RST_H_PLACED" 0 restore-undo-unlogged-file-no-event
rst_undo_judge 0
assert_eq "$CORE_FINDING" unexpected restore-undo-unlogged-file-judge-before
RST_CORE=0 OMB_IFACE_WORD=undo
_rst_undo >"$T/undo" 2>&1
assert_eq "$?" 1 restore-undo-unlogged-file-refused
_rst_backup_name .config/test.conf
assert_file "$RST_HOME/.config/test.conf" 'new configuration' restore-undo-unlogged-file-retained
assert_contains "$(cat "$T/undo")" '.config/test.conf' restore-undo-unlogged-file-named
assert_contains "$(cat "$T/undo")" 'matches what the restore places' restore-undo-unlogged-file-matches
assert_contains "$(cat "$T/undo")" 'no placement was recorded' restore-undo-unlogged-file-no-record-explained
assert_contains "$(cat "$T/undo")" 'left as is' restore-undo-unlogged-file-left-explained
assert_contains "$(cat "$T/undo")" 'There was no original' restore-undo-unlogged-file-no-original
rst_undo_judge 1
assert_eq "$CORE_FINDING" unexpected restore-undo-unlogged-file-judge-after
assert_contains "$CORE_JUDGE_TEXT" '.config/test.conf' restore-undo-unlogged-file-judge-named
RST_CORE=0
setup
{
  rec_line item id settings:test class config whole 1
  rec_line setting item settings:test kind git tool git name user.name value Restored
} >"$T/body"
rebuild
printf 'Original\n' >"$F/cmd/rst_git_user.name"
load; replace_all
RESTORE_TEST_FAIL_AFTER_SETTING=1
apply
assert_eq "$RC" 1 restore-undo-unlogged-setting-append-fails
assert_file "$F/cmd/rst_git_user.name" Restored restore-undo-unlogged-setting-changed
load; _rst_history git:user.name
assert_eq "$RST_H_PLACED" 0 restore-undo-unlogged-setting-no-event
rst_undo_judge 0
assert_eq "$CORE_FINDING" unexpected restore-undo-unlogged-setting-judge-before
RST_CORE=0 OMB_IFACE_WORD=undo
_rst_undo >"$T/undo" 2>&1
assert_eq "$?" 1 restore-undo-unlogged-setting-refused
assert_file "$F/cmd/rst_git_user.name" Restored restore-undo-unlogged-setting-retained
assert_contains "$(cat "$T/undo")" 'cannot tell whether it set' restore-undo-unlogged-setting-explained
assert_contains "$(cat "$T/undo")" 'git:user.name' restore-undo-unlogged-setting-named
_rst_backup_name git:user.name
assert_contains "$(cat "$T/undo")" "$RST_BACKUP.setting" restore-undo-unlogged-setting-backup
rst_undo_judge 0
assert_eq "$CORE_FINDING" unexpected restore-undo-unlogged-setting-judge-after
assert_contains "$CORE_JUDGE_TEXT" 'git:user.name' restore-undo-unlogged-setting-judge-named
RST_CORE=0
# A failed later Replace has no placement; an older placed event is not proof.
setup
printf original >"$F/root/home/alex/.config/test.conf"
load; replace_all; apply
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
printf edited >"$RST_HOME/.config/test.conf"
load; replace_all; apply
assert_eq "$RC" 1 restore-undo-later-replace-refused
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-undo-later-replace-skipped
rst_undo_offer
assert_eq "$?" 0 restore-undo-later-replace-offered
OMB_IFACE_WORD=undo; rst_cmd undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-undo-later-replace-text-route
OMB_IFACE_WORD=undo; rst_undo_run >"$T/undo" 2>&1
assert_eq "$?" 0 restore-undo-later-replace-core-route
rst_undo_judge 0
assert_eq "$CORE_FINDING" completed restore-undo-later-replace-judge
assert_file "$RST_HOME/.config/test.conf" edited restore-undo-later-replace-edit-retained
RST_CORE=0

# restore-recorded-only: identical owner-made nodes are left as is without
# a current-cycle placement record, for every filesystem kind.
undo_kind_fixture() {
  setup
  case "$1" in
    file) n=0 ;;
    dir)
      {
        rec_line item id config:tree class config whole 1
        rec_line dir item config:tree dest .config/tree mode 0755
        rec_line file item config:tree dest .config/tree/entry mode 0644 sha256 "$SHA" size 18 whole 1
      } >"$T/body"
      rebuild; n=0 ;;
    link)
      basebody
      rec_line link item config:test dest .config/link target test.conf >>"$T/body"
      rebuild; n=1 ;;
    bashrc)
      {
        rec_line item id shell:bash class config whole 1
        rec_line file item shell:bash dest .config/omarchy-mac-bootstrap/shell.bash mode 0644 sha256 "$SHA" size 18 whole 1
      } >"$T/body"
      rebuild; n=1 ;;
  esac
  load
  path=$RST_HOME/${RST_DEST[n]} stage=$RST_HOME/${RST_DEST[n]}.omb-new-$RST_RUN
  _rst_ready
  _rst_parents "${RST_DEST[n]}" 1
  _rst_log prepare "${RST_ITEM[n]}" "${RST_DEST[n]}" "${RST_OLD[n]}" "${RST_NEW[n]}" ready
  _rst_stage "$n" "$stage"
}
for kind in file dir link bashrc; do
  undo_kind_fixture "$kind"
  # The owner's copy is separate from the retained stage, even when identical.
  run cp -a -T -- "$stage" "$path"
  _rst_node "$path"; handmade=$RST_NODE
  load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
  assert_eq "$?" 1 "restore-cycle-handmade-refused-$kind"
  _rst_node "$path"
  assert_eq "$RST_NODE" "$handmade" "restore-cycle-handmade-retained-$kind"
  # Repeated undo must keep the same destination untouched.
  load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
  assert_eq "$?" 1 "restore-cycle-handmade-rerun-$kind"
  _rst_node "$path"
  assert_eq "$RST_NODE" "$handmade" "restore-cycle-handmade-rerun-retained-$kind"
  rst_undo_judge 0
  assert_eq "$CORE_FINDING" unexpected "restore-cycle-handmade-judge-$kind"
  assert_contains "$CORE_JUDGE_TEXT" "${path#"$RST_HOME"/}" "restore-cycle-handmade-judge-named-$kind"
  RST_CORE=0

  undo_kind_fixture "$kind"
  : >"$T/record"
  _rst_transfer "$stage" "$path" "${RST_NEW[n]}"
  assert_eq "$?" 0 "restore-transfer-$kind"
  case "$kind" in
    file | bashrc) primitive='ln -T --' ;;
    link) primitive='ln -s -T --' ;;
    dir) primitive='mv -T --update=none-fail --' ;;
  esac
  assert_contains "$(head -n 1 "$T/record")" "$primitive" "restore-transfer-primitive-$kind"
  _rst_log placed "${RST_ITEM[n]}" "${RST_DEST[n]}" "${RST_OLD[n]}" "${RST_NEW[n]}" placed
  load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
  assert_eq "$?" 0 "restore-recorded-undo-$kind"
  [ ! -e "$path" ] && [ ! -L "$path" ] && ok || fail "restore-recorded-removed-$kind"
done

# A real stop after staging, including a pending original, never authorizes
# moving an identical destination made by hand. Repeat the undo to check both.
for original in absent present; do
  setup
  if [ "$original" = present ]; then printf original >"$F/root/home/alex/.config/test.conf"; boundary=restore.backup
  else boundary=restore.stage; fi
  (child "$boundary") 2>/dev/null
  assert_eq "$?" 137 "restore-cycle-stop-$original"
  load; stage=$RST_HOME/.config/test.conf.omb-new-$RST_RUN
  run cp -a -T -- "$stage" "$RST_HOME/.config/test.conf"
  for attempt in 1 2; do
    load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1; rc=$?
    if [ "$original" = present ]; then
      assert_eq "$rc" 1 "restore-cycle-pending-refused-$attempt"
      _rst_backup_name .config/test.conf
      assert_file "$RST_BACKUP" original "restore-cycle-pending-original-$attempt"
      assert_contains "$(cat "$T/undo")" "$RST_BACKUP" "restore-cycle-pending-backup-named-$attempt"
    else assert_eq "$rc" 1 "restore-cycle-absent-refused-$attempt"; fi
    assert_file "$RST_HOME/.config/test.conf" 'new configuration' "restore-cycle-stop-handmade-retained-$original-$attempt"
  done
done

# Neither a crash before stage creation nor apply's stage cleanup records
# a placement. Both used to let undo move an identical owner-made file.
for boundary in before-stage apply-cleanup; do
  setup
  if [ "$boundary" = before-stage ]; then
    load; _rst_ready
    _rst_log prepare "${RST_ITEM[0]}" "${RST_DEST[0]}" "${RST_OLD[0]}" "${RST_NEW[0]}" ready
    run cp -a -T -- "$B/objects/$SHA" "$RST_HOME/.config/test.conf"
  else
    (child restore.stage) 2>/dev/null
    load; stage=$RST_HOME/.config/test.conf.omb-new-$RST_RUN
    run cp -a -T -- "$stage" "$RST_HOME/.config/test.conf"
    load; apply
    assert_eq "$RC" 0 restore-unrecorded-apply-cleanup-rerun
    [ ! -e "$stage" ] && ok || fail restore-unrecorded-apply-cleanup-stage-gone
  fi
  load; : >"$T/record"; OMB_IFACE_WORD=undo
  _rst_undo >"$T/undo" 2>&1
  assert_eq "$?" 1 "restore-unrecorded-$boundary-refused"
  assert_file "$RST_HOME/.config/test.conf" 'new configuration' "restore-unrecorded-$boundary-owner-retained"
  assert_empty_file "$T/record" "restore-unrecorded-$boundary-no-mutation"
  assert_contains "$(cat "$T/undo")" '.config/test.conf' "restore-unrecorded-$boundary-named"
  rst_undo_judge 1
  assert_eq "$CORE_FINDING" unexpected "restore-unrecorded-$boundary-judge"
  assert_contains "$CORE_JUDGE_TEXT" '.config/test.conf' "restore-unrecorded-$boundary-judge-named"
  RST_CORE=0
done

# A pending original returns only to a free destination. Even a copy of the
# before at the destination remains untouched while the backup is pending.
for occupant in absent before after third; do
  setup
  printf original >"$F/root/home/alex/.config/test.conf"
  (child restore.backup) 2>/dev/null
  load; _rst_backup_name .config/test.conf
  backup=$RST_BACKUP
  case "$occupant" in
    before) cp -p "$backup" "$RST_HOME/.config/test.conf" ;;
    after) cp -p "$B/objects/$SHA" "$RST_HOME/.config/test.conf" ;;
    third) printf owner-edit >"$RST_HOME/.config/test.conf" ;;
  esac
  _rst_node "$RST_HOME/.config/test.conf"; occupant_fp=$RST_NODE
  : >"$T/record"; OMB_IFACE_WORD=undo
  _rst_undo >"$T/undo" 2>&1; rc=$?
  if [ "$occupant" = absent ]; then
    assert_eq "$rc" 0 restore-pending-free-recovered
    assert_file "$RST_HOME/.config/test.conf" original restore-pending-free-original
    assert_contains "$(cat "$T/record")" 'mv -T --update=none-fail' restore-pending-free-no-clobber
    rst_undo_judge 0
    assert_eq "$CORE_FINDING" completed restore-pending-free-judge
  else
    assert_eq "$rc" 1 "restore-pending-$occupant-refused"
    _rst_node "$RST_HOME/.config/test.conf"
    assert_eq "$RST_NODE" "$occupant_fp" "restore-pending-$occupant-owner-retained"
    assert_file "$backup" original "restore-pending-$occupant-backup-retained"
    assert_empty_file "$T/record" "restore-pending-$occupant-no-mutation"
    assert_contains "$(cat "$T/undo")" "$backup" "restore-pending-$occupant-backup-named"
    rst_undo_judge 1
    assert_eq "$CORE_FINDING" unexpected "restore-pending-$occupant-judge"
  fi
  RST_CORE=0
done

# An occupant appearing after the undo decision must still never be moved.
setup
printf original >"$F/root/home/alex/.config/test.conf"
(child restore.backup) 2>/dev/null
load; _rst_history .config/test.conf
_rst_undo_needed 0
assert_eq "$?" 0 restore-pending-free-decision
backup=$RST_BACKUP
cp -p "$B/objects/$SHA" "$RST_HOME/.config/test.conf"
: >"$T/record"
_rst_undo_file 0 >"$T/undo" 2>&1
assert_eq "$?" 1 restore-pending-late-occupant-refused
assert_file "$RST_HOME/.config/test.conf" 'new configuration' restore-pending-late-occupant-retained
assert_file "$backup" original restore-pending-late-occupant-backup
assert_empty_file "$T/record" restore-pending-late-occupant-no-mutation

# The unrecorded pending-original hint is followed with the destination free.
setup
printf original >"$F/root/home/alex/.config/test.conf"
(child restore.backup) 2>/dev/null
load
printf owner-edit >"$RST_HOME/.config/test.conf"
load
assert_contains "${RST_REASON[0]}" 'while the destination is free' restore-pending-hint-free
mv "$RST_HOME/.config/test.conf" "$RST_HOME/.config/test.saved"
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-pending-hint-undo
assert_file "$RST_HOME/.config/test.conf" original restore-pending-hint-original
assert_file "$RST_HOME/.config/test.saved" owner-edit restore-pending-hint-owner-retained

# Without a pending backup, absent, before and third states are skipped.
for current in absent before third; do
  setup
  printf original >"$F/root/home/alex/.config/test.conf"
  load; _rst_ready
  _rst_log prepare "${RST_ITEM[0]}" "${RST_DEST[0]}" "${RST_OLD[0]}" "${RST_NEW[0]}" ready
  case "$current" in
    absent) rm "$RST_HOME/.config/test.conf" ;;
    third) printf owner-edit >"$RST_HOME/.config/test.conf" ;;
  esac
  # No backup means the absent original is not available for recovery.
  if [ "$current" = absent ]; then
    # Model a new item, whose before was absent rather than a lost original.
    _rst_log prepare "${RST_ITEM[0]}" "${RST_DEST[0]}" absent "${RST_NEW[0]}" ready
  fi
  : >"$T/record"; OMB_IFACE_WORD=undo
  _rst_undo >"$T/undo" 2>&1
  assert_eq "$?" 0 "restore-unrecorded-skip-$current"
  assert_not_contains "$(cat "$T/undo")" '.config/test.conf' "restore-unrecorded-silent-$current"
  assert_empty_file "$T/record" "restore-unrecorded-no-mutation-$current"
  rst_undo_judge 0
  assert_eq "$CORE_FINDING" completed "restore-unrecorded-skip-judge-$current"
  RST_CORE=0
done

# An undone cycle's after cannot authorize a new undo after a status-only event.
setup
printf original >"$F/root/home/alex/.config/test.conf"
load; replace_all; apply
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
load; _rst_mark 0 blocked 'An earlier install did not complete.'
run cp -a -T -- "$B/objects/$SHA" "$RST_HOME/.config/test.conf.owner-copy"
mv "$RST_HOME/.config/test.conf.owner-copy" "$RST_HOME/.config/test.conf"
load; : >"$T/record"
OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 0 restore-cycle-stale-after-skipped
assert_file "$RST_HOME/.config/test.conf" 'new configuration' restore-cycle-stale-after-retained
assert_empty_file "$T/record" restore-cycle-stale-after-no-mutation
rst_undo_judge 0
assert_eq "$CORE_FINDING" completed restore-cycle-stale-after-judge
RST_CORE=0

# A prepare alone cannot identify who set a value; preserve both private values.
setup
{
  rec_line item id settings:test class config whole 1
  rec_line setting item settings:test kind git tool git name user.name value PRIVATE_NEW_VALUE
} >"$T/body"
rebuild
printf 'PRIVATE_OLD_VALUE\n' >"$F/cmd/rst_git_user.name"
load; _rst_ready
_rst_backup_name git:user.name
setting_backup=$RST_BACKUP.setting
printf '%s' "$RST_VALUE" >"$T/saved-setting"
run rst_stage_write "$T/saved-setting" "$setting_backup" 0600
_rst_log prepare "${RST_ITEM[0]}" "${RST_DEST[0]}" "${RST_OLD[0]}" "${RST_NEW[0]}" ready
printf 'PRIVATE_NEW_VALUE\n' >"$F/cmd/rst_git_user.name"
load; : >"$T/record"; OMB_IFACE_WORD=undo
_rst_undo >"$T/undo" 2>&1
assert_eq "$?" 1 restore-cycle-handset-refused
assert_file "$F/cmd/rst_git_user.name" PRIVATE_NEW_VALUE restore-cycle-handset-retained
assert_file "$setting_backup" PRIVATE_OLD_VALUE restore-cycle-handset-backup
assert_contains "$(cat "$T/undo")" 'cannot tell whether it set' restore-cycle-handset-explained
assert_contains "$(cat "$T/undo")" "$setting_backup" restore-cycle-handset-backup-named
assert_not_contains "$(cat "$T/undo")" PRIVATE_OLD_VALUE restore-cycle-handset-old-withheld
assert_not_contains "$(cat "$T/undo")" PRIVATE_NEW_VALUE restore-cycle-handset-new-withheld
assert_empty_file "$T/record" restore-cycle-handset-no-mutation
rst_undo_judge 1
assert_eq "$CORE_FINDING" unexpected restore-cycle-handset-judge
assert_contains "$CORE_JUDGE_TEXT" 'git:user.name' restore-cycle-handset-judge-named
RST_CORE=0

# A final bundle recheck failure never publishes a checked bundle.
eval "$(declare -f bndl_check | sed '1s/bndl_check/_restore_recheck_bundle/')"
bndl_check() {
  _restore_recheck_bundle "$@" || return 1
  if [ "${RESTORE_TEST_CHANGE_BUNDLE:-0}" = 1 ]; then
    RESTORE_TEST_CHANGE_BUNDLE=0
    printf changed >>"$1/objects/$SHA"
  fi
}
setup; RESTORE_TEST_CHANGE_BUNDLE=1
load
assert_eq "$RST_BUNDLE" '' restore-bundle-final-check-unpublished
assert_eq "$RST_STATE" blocked restore-bundle-final-check-blocked
setup; RESTORE_TEST_CHANGE_BUNDLE=1
CORE_REQ_ARGS=2 CORE_REQ_ARG_NAME=(bundle review)
CORE_REQ_ARG_VALUE=(20261022T120000Z malformed)
rst_apply_basis
assert_eq "$?" 1 restore-bundle-final-check-basis-refused
assert_eq "$RST_INVALID_NAME" bundle restore-bundle-final-check-field
bndl_check() { _restore_recheck_bundle "$@"; }
CORE_REQ_ARGS=0 CORE_REQ_ARG_NAME=() CORE_REQ_ARG_VALUE=()

# Refusals name the destination/backup, including an owner-deleted destination.
setup
printf original >"$F/root/home/alex/.config/test.conf"
load; replace_all; apply
printf edited >"$RST_HOME/.config/test.conf"
load; replace_all; apply
rm "$RST_HOME/.config/test.conf"
_rst_backup_name .config/test.conf
printf changed >"$RST_BACKUP"
load; OMB_IFACE_WORD=undo; _rst_undo >"$T/undo" 2>&1
assert_eq "$?" 1 restore-undo-deleted-destination-refused
assert_contains "$(cat "$T/undo")" '.config/test.conf' restore-undo-deleted-destination-named
assert_contains "$(cat "$T/undo")" "$RST_BACKUP" restore-undo-deleted-destination-backup

setup; load; apply
mv "$OMB_STATE_DIR/restore/runs" "$OMB_STATE_DIR/restore/saved-runs"
ln -s saved-runs "$OMB_STATE_DIR/restore/runs"
OMB_IFACE_WORD=undo; rst_cmd undo >"$T/undo" 2>&1
assert_eq "$?" 1 restore-undo-unsafe-runs-refused
assert_contains "$(cat "$T/undo")" 'run path is not safe' restore-undo-unsafe-runs-reason

# restore-self-check-directory: a plain rename replaces an empty directory.
setup; load; _rst_ready
RESTORE_TEST_CLOBBER=directory
_rst_no_clobber >"$T/out" 2>&1
assert_eq "$?" 1 restore-self-check-directory-option-loss
RESTORE_TEST_CLOBBER=0
mkdir -p "$OMB_STATE_DIR/restore/no-clobber"
printf leftover >"$OMB_STATE_DIR/restore/no-clobber/stopped"
_rst_no_clobber >"$T/out" 2>&1
assert_eq "$?" 0 restore-self-check-leftover-retry
[ ! -e "$OMB_STATE_DIR/restore/no-clobber" ] && ok || fail restore-self-check-leftover-removed
RESTORE_TEST_CHECK_MKDIR_FAIL=1
_rst_no_clobber >"$T/out" 2>&1
assert_eq "$?" 1 restore-self-check-mkdir-refused
assert_contains "$(cat "$T/out")" 'could not create' restore-self-check-mkdir-reason
RESTORE_TEST_CHECK_MKDIR_FAIL=0
RST_DEVICE=another-device
_rst_no_clobber >"$T/out" 2>&1
assert_eq "$?" 1 restore-self-check-device-refused
assert_contains "$(cat "$T/out")" 'another filesystem' restore-self-check-device-reason
assert_not_contains "$(cat "$T/out")" coreutils restore-self-check-device-no-option-blame

# restore-backend-kebab: observe mise's namespaces, never links or latest.
setup; load
RST_METHOD=mise-backend RST_VERSION=1
for case_pair in 'npm:@antfu/ni npm-antfu-ni' 'cargo:eza cargo-eza' \
  'vfox:version-fox/vfox-nodejs vfox-version-fox-vfox-nodejs' \
  'aqua:BurntSushi/ripgrep aqua-burnt-sushi-ripgrep' \
  'github:XMLHttpRequest/abc123Def github-xml-http-request-abc123-def'; do
  read -r RST_TARGET directory <<<"$case_pair"
  base=$RST_HOME/.local/share/mise/installs/$directory
  mkdir -p "$base/latest" "$T/backend-version"
  ln -s "$T/backend-version" "$base/1"
  _rst_pkg_present
  assert_eq "$?" 1 "restore-backend-kebab-links-latest-$directory"
  rm "$base/1"; mkdir "$base/1"
  _rst_pkg_present
  assert_eq "$?" 0 "restore-backend-kebab-found-$directory"
done
RST_TARGET=$'github:owner/caf\303\251'
mkdir -p "$RST_HOME/.local/share/mise/installs/$RST_TARGET/1"
_rst_pkg_present
assert_eq "$?" 1 restore-backend-kebab-nonascii-unverified

# restore-real-gnu-no-clobber: run the actual Linux placement primitives. This
# explicit skip is also visible to Linux CI's strict-skip policy.
coreutils_version=$(mv --version 2>/dev/null | awk 'NR == 1 && /GNU coreutils/ { print $NF }')
if [ -n "$coreutils_version" ] && ver_ge "$coreutils_version" 9.5; then
  real=$T/real-coreutils
  mkdir -p "$real/source" "$real/dest"
  printf source >"$real/source/entry"
  printf destination >"$real/dest/entry"
  mv -T --update=none-fail -- "$real/source" "$real/dest" >/dev/null 2>&1
  assert_eq "$?" 1 restore-real-mv-refuses-existing-directory
  assert_file "$real/dest/entry" destination restore-real-mv-no-nesting
  mv -T --update=none-fail -- "$real/source" "$real/moved"
  assert_eq "$?" 0 restore-real-mv-success
  ln -T -- "$real/moved/entry" "$real/dest" >/dev/null 2>&1
  assert_eq "$?" 1 restore-real-ln-refuses-directory
  ln -T -- "$real/moved/entry" "$real/linked"
  assert_eq "$?" 0 restore-real-ln-success
  cp -a -T -- "$real/moved" "$real/copied"
  assert_file "$real/copied/entry" source restore-real-cp-creates-directory
  ln -s "$real/dest" "$real/copy-link"
  cp -a -T -- "$real/moved" "$real/copy-link" >/dev/null 2>&1
  assert_eq "$?" 1 restore-real-cp-refuses-link
  assert_file "$real/dest/entry" destination restore-real-cp-no-follow
else skip 'restore-real-no-clobber (GNU coreutils 9.5+ absent)'; fi

# restore-entrypoint-refusals: nounset and the actual CLI route, not libraries
# alone, exercise root, unfinished Omarchy and missing bundle failures.
setup
printf '0\n' >"$F/cmd/id_u"
t_cli "$F" '' restore status
assert_eq "$T_RC" 1 restore-cli-root
assert_contains "$T_OUT" 'never runs as root' restore-cli-root-text
setup
rm "$F/root/var/lib/omarchy-mac-setup/install-complete" 2>/dev/null || :
# The installed marker is the source constant; delete only the fixture copy.
rm -f "$(sys_path "$OMS_MARKER")" "$(sys_path "$OMARCHY_RUNTIME_VERSION")"
t_cli "$F" '' restore status
assert_eq "$T_RC" 1 restore-cli-omarchy
assert_contains "$T_OUT" 'Omarchy is not finished' restore-cli-omarchy-text
# restore-wire: staged/admitted snapshots, all detail kinds, stale paging and
# real validation through the shared core harness.
# shellcheck source=tests/core-harness.sh
. "$REPO/tests/core-harness.sh"
setup
C_FIX=$F C_STATE=$OMB_STATE_DIR S=0123456789abcdef
C_ENV="OMB_SESSION_SCOPES=restore OMB_RESTORE_DIR=$F/root/mnt/shared HOME=/home/alex"
c_session
c_run snapshot $'scope\tname=restore'
assert_eq "$(c_result)" 'done ok' restore-wire-snapshot
assert_empty_file "$T/stderr" restore-wire-clean-stderr
assert_contains "$C_OUT" 'key=restore.state' restore-wire-state-fact
assert_contains "$C_OUT" 'id=restore.apply' restore-wire-apply-action
generation=$(printf '%s\n' "$C_OUT" | awk -F '\t' '$1 == "generation" { sub(/^id=/, "", $2); print $2; exit }')
for kind in bundles review conflicts diff status; do
  c_run detail "$(rec_line page scope restore kind "$kind" generation "$generation" offset 0 limit 50)"
  assert_eq "$(c_result)" 'done ok' "restore-wire-$kind"
done
c_run validate $'select\taction=restore.apply' "$(rec_line arg name bundle value 20261022T120000Z)" "$(rec_line arg name review value "$generation")"
assert_eq "$(c_result)" 'done ok' restore-wire-validate
assert_contains "$C_OUT" $'review\taction=restore.apply' restore-wire-validation-basis
# restore-validation-field: bundle errors take precedence; review errors
# name review only after the checked bundle has been identified.
for invalid_case in missing-bundle wrong-bundle missing-review malformed-review changed-review; do
  invalid_field=review invalid_code=invalid
  case "$invalid_case" in
    missing-bundle)
      invalid_field=bundle
      c_run validate $'select\taction=restore.apply' "$(rec_line arg name review value "$generation")" ;;
    wrong-bundle)
      invalid_field=bundle
      c_run validate $'select\taction=restore.apply' "$(rec_line arg name bundle value 20261021T120000Z)" "$(rec_line arg name review value "$generation")" ;;
    missing-review)
      c_run validate $'select\taction=restore.apply' "$(rec_line arg name bundle value 20261022T120000Z)" ;;
    malformed-review)
      c_run validate $'select\taction=restore.apply' "$(rec_line arg name bundle value 20261022T120000Z)" "$(rec_line arg name review value malformed)" ;;
    changed-review)
      invalid_code=changed
      c_run validate $'select\taction=restore.apply' "$(rec_line arg name bundle value 20261022T120000Z)" "$(rec_line arg name review value "$(printf '%064d' 0)")" ;;
  esac
  assert_eq "$(c_result)" "refused $invalid_code" "restore-validation-field-result-$invalid_case"
  assert_contains "$C_OUT" "$(printf 'invalid\tname=%s\tcode=%s' "$invalid_field" "$invalid_code")" "restore-validation-field-$invalid_case"
done
printf concurrent >"$F/root/home/alex/.config/test.conf"
c_run validate $'select\taction=restore.apply' "$(rec_line arg name bundle value 20261022T120000Z)" "$(rec_line arg name review value "$generation")"
assert_eq "$(c_result)" 'refused changed' restore-review-generation-wire
c_run detail "$(rec_line page scope restore kind review generation "$generation" offset 0 limit 50)"
assert_eq "$(c_result)" 'refused changed' restore-wire-stale-generation

HOME=$REAL_HOME
t_done test-restore
