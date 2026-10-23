#!/usr/bin/env bash
# Restore placements and recovery over synthetic Omarchy homes. The local run
# stand-in executes only filesystem commands confined to this test's fixture;
# package/owner commands are simulated and never run on the development Mac.
# shellcheck disable=SC2015,SC2016,SC2031,SC2034,SC2329
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
OMB_TMP=$T/scratch
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

# run's fixture execution stand-in: no generic evaluator, no external tools.
# BSD tools on macOS need the same no-replace semantics for fixture tests.
run() {
  local cmd=$1 arg src dst key
  shift
  [ "$OMB_INTENT" = act ] && [ "$OMB_DRY_RUN" != 1 ] || return 1
  printf '%s\n' "$(quote_argv "$cmd" "$@")" >>"$T/record"
  case "$cmd" in
    rst_log_write | rst_stage_write) "$cmd" "$@" ;;
    sync) return 0 ;;
    mkdir | chmod | cp | rm)
      for arg in "$@"; do
        case "$arg" in /*) case "$arg" in "$T"/* | "$TMP_ROOT"/*) ;; *) echo "unsafe test write: $arg" >&2; return 97 ;; esac ;; esac
      done
      if [ "$cmd" = cp ] && [ "$1" = -a ]; then shift; [ "$1" != -- ] || shift; cp -pR "$@"
      elif [ "$cmd" = chmod ]; then key=$1; shift; [ "$1" != -- ] || shift; chmod "$key" "$@"
      else "$cmd" "$@"; fi ;;
    mv)
      shift 3
      src=$1 dst=$2
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
      key=${6:-}
      printf '%s\n' "${7:-}" >"$OMB_FIXTURE/cmd/rst_git_$key" ;;
    claude)
      mkdir -p "$RST_HOME"
      printf '{}\n' >"$T/json"
      [ ! -f "$RST_HOME/.claude.json" ] || cp "$RST_HOME/.claude.json" "$T/json"
      jq --arg k "$3" --argjson v "$4" '.mcpServers[$k] = $v' "$T/json" >"$RST_HOME/.claude.json" ;;
    fake-agent)
      mkdir -p "$RST_HOME/.local/share/mise/installs/$1/1/bin"
      : >"$RST_HOME/.local/share/mise/installs/$1/1/bin/$1" ;;
    env | npm | uv)
      if [ "${INSTALL_TAKES:-0}" = 1 ]; then
        case "$cmd" in
          env) mkdir -p "$RST_HOME/.local/share/mise/installs/$RST_TARGET/${RST_VERSION:-1}/bin" ;;
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
apply() { OMB_IFACE_WORD=restore; _rst_apply >"$T/out" 2>&1; RC=$?; }
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
  OMB_TMP=$T/child-scratch
  mkdir -p "$OMB_TMP"
  HOME=/home/alex OMB_FIXTURE=$F OMB_PLATFORM=linux OMB_UID=1000 OMB_INTENT=act OMB_PERSIST=1 OMB_DRY_RUN=0
  OMB_STATE_DIR=$F/root/home/alex/.local/state/omarchy-mac-bootstrap OMB_RESTORE_DIR=$F/root/mnt/shared
  OMB_TEST_STOP_AT=${RST_CHILD_STOP:-} OMB_TEST_FAIL_AT=${RST_CHILD_FAIL:-} OMB_TEST_PAUSE_AT=${RST_CHILD_PAUSE:-}
  RST_CORE=0 RST_REPLACE=() CORE_REQ_ARGS=0
  state_init
  _rst_load || exit 20
  replace_all
  if [ "${RST_CHILD_UNDO:-0}" = 1 ]; then OMB_IFACE_WORD=undo; _rst_undo
  else OMB_IFACE_WORD=restore; _rst_apply; fi
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
    assert_file "$RST_BACKUP" original restore-place-failure-retains-backup
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
load; replace_all; apply
assert_eq "$RC" 0 restore-agent-configs
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
load; replace_all; apply
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
CORE_REQ_ARGS=2 CORE_REQ_ARG_NAME=(bundle replace.1)
CORE_REQ_ARG_VALUE=(20261022T120000Z $'omb-replace 1\nreplace\tdest=.config/test.conf\n')
rst_apply_basis
assert_eq "$?" 0 restore-valid-replacement
first_basis=$CORE_BASIS
printf changed >"$F/root/home/alex/.config/test.conf"
rst_apply_basis
[ "$first_basis" != "$CORE_BASIS" ] && ok || fail restore-basis-binds-destination
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
c_run validate $'select\taction=restore.apply' "$(rec_line arg name bundle value 20261022T120000Z)"
assert_eq "$(c_result)" 'done ok' restore-wire-validate
assert_contains "$C_OUT" $'review\taction=restore.apply' restore-wire-validation-basis
printf concurrent >"$F/root/home/alex/.config/test.conf"
c_run detail "$(rec_line page scope restore kind review generation "$generation" offset 0 limit 50)"
assert_eq "$(c_result)" 'refused changed' restore-wire-stale-generation

HOME=$REAL_HOME
t_done test-restore
