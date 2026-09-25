# shellcheck shell=bash
# Minimal test harness. Nothing here touches the real machine: CLI runs get a
# temporary HOME and state directory, fixture-backed probes, and a PATH whose
# first entries are recording shims for every command that could change a disk,
# boot configuration, packages, or the network.

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$TESTS_DIR/.." && pwd -P)
FIX="$TESTS_DIR/fixtures"
TMP_ROOT="$TESTS_DIR/.tmp"
T_BASH=${OMB_TEST_BASH:-bash}
[ -x /bin/bash ] && [ "$(uname -s)" = Darwin ] && T_BASH=${OMB_TEST_BASH:-/bin/bash}
T_PASS=0 T_FAIL=0 T_SKIP=0
mkdir -p "$TMP_ROOT"

# Commands that must never run during tests. Each shim records its argv to
# $SHIM_LOG and fails loudly.
FORBIDDEN_CMDS="diskutil dd gpt fdisk sfdisk parted bless nvram csrutil shutdown reboot halt poweroff
sudo pacman systemctl nmtui cryptsetup mkfs mkfs.exfat wipefs pbcopy omarchy-mac-setup curl wget sh
omarchy-pkg-add omarchy-install-dev-env omarchy-setup-security-sshd omarchy-install-editor-vscode
omarchy-setup-security-sudoless-docker gh ssh-keygen npm timedatectl localectl git
sgdisk gdisk blkdiscard btrfs hdiutil asr"

t_tmp() { mktemp -d "$TMP_ROOT/t.XXXXXX"; }

# t_variant BASE — a throwaway copy of a fixture to modify; prints its path.
t_variant() {
  local d
  d=$(t_tmp)
  cp -R "$FIX/$1/." "$d/"
  printf '%s' "$d"
}

t_shims() {
  local dir=$1/shims name
  mkdir -p "$dir"
  for name in $FORBIDDEN_CMDS; do
    cat >"$dir/$name" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >>"${SHIM_LOG:-/dev/null}"
echo "FORBIDDEN in tests: $(basename "$0")" >&2
exit 97
EOF
    chmod +x "$dir/$name"
  done
  printf '%s' "$dir"
}

ok() { T_PASS=$((T_PASS + 1)); }
fail() {
  T_FAIL=$((T_FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s\n' "$*"
}
skip() {
  # CI runs with OMB_STRICT_SKIPS=1: a skip is a failure unless it matches
  # OMB_ALLOWED_SKIP_RE (the Linux job allows only the plutil-bound checks),
  # so a safety check cannot quietly stop running.
  if [ "${OMB_STRICT_SKIPS:-0}" = 1 ] && ! printf "%s" "$*" | grep -Eq "${OMB_ALLOWED_SKIP_RE:-^\$^}"; then
    fail "skipped, and skips are not allowed here: $*"
    return 0
  fi
  T_SKIP=$((T_SKIP + 1))
  printf "  skip %s\n" "$*"
}

# t_plutil — may macOS plist checks run here? Records a skip when not, so
# a missing plutil is visible rather than silent.
t_plutil() {
  command -v plutil >/dev/null 2>&1 && return 0
  skip "macOS plist checks in $(basename "$0") (no plutil)"
  return 1
}

assert_eq() { if [ "$1" = "$2" ]; then ok; else fail "$3: expected [$2], got [$1]"; fi; }
assert_contains() { case "$1" in *"$2"*) ok ;; *) fail "$3: output lacks [$2]" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) fail "$3: output has [$2]" ;; *) ok ;; esac; }
assert_rc() { if [ "$1" = "$2" ]; then ok; else fail "$3: exit $1, expected $2"; fi; }
assert_empty_file() {
  if [ ! -s "$1" ]; then ok; else fail "$2: $(tr '\n' ';' <"$1")"; fi
}

# t_cli FIXTURE INPUT ARGS... — runs the entrypoint in a sealed environment.
# Sets T_OUT (combined output), T_RC, T_DIR (the run's temp dir; state in
# $T_DIR/state, shim log in $T_DIR/shims.log). Mutating commands are always
# recorded to $T_DIR/record instead of executed, even without --dry-run.
# Extra env via T_ENV="K=V ...".
t_cli() {
  local fixture=$1 input=$2
  shift 2
  T_DIR=$(t_tmp)
  local shims
  shims=$(t_shims "$T_DIR")
  local fx=""
  case "$fixture" in
    '') ;;
    /*) fx=$fixture ;;
    *) fx="$FIX/$fixture" ;;
  esac
  mkdir -p "$T_DIR/tmp"
  # shellcheck disable=SC2086 # T_ENV is a list of assignments by design
  T_OUT=$(printf '%b' "$input" | env -i \
    PATH="$shims:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$T_DIR/home" \
    TMPDIR="$T_DIR/tmp" \
    LANG=en_US.UTF-8 \
    TERM=dumb \
    OMB_STATE_DIR="$T_DIR/state" \
    OMB_FIXTURE="$fx" \
    SHIM_LOG="$T_DIR/shims.log" \
    OMB_TEST_RECORD="$T_DIR/record" \
    ${T_ENV:-} \
    "$T_BASH" "$REPO/omarchy-bootstrap" "$@" 2>&1)
  T_RC=$?
  touch "$T_DIR/shims.log" "$T_DIR/record"
}

# t_snapshot DIR — every path under DIR with a checksum for each file, so a
# before/after comparison shows any file created, removed, or changed.
t_snapshot() {
  [ -e "$1" ] || {
    echo "(absent)"
    return 0
  }
  (cd "$1" && find . -print | sort && find . -type f -exec cksum {} + | sort)
}

# Load the libraries into this shell for unit tests (main is not run).
t_load() {
  # shellcheck source=/dev/null
  for f in common ui state sources storage macos asahi shared linux doctor dev; do . "$REPO/lib/$f.sh"; done
  OMB_COLOR=never
  ui_init
}

# t_flat TEXT — output with wrapped lines joined and callout edges removed,
# for asserting on a sentence however the terminal width wrapped it.
t_flat() { printf '%s' "$1" | sed -E 's/^ *(┃|\|) //' | tr '\n' ' ' | tr -s ' '; }

# t_plan_answers FIXTURE LINUX_GB SHARED_GB — what the planner tells the
# installer for a macOS fixture: "RESIZE_ANSWER OS_ANSWER" ("-" for no
# resize). The answers themselves are proved in tests/test-storage.sh; CLI
# tests use this to check the answers reach the card and the clipboard.
t_plan_answers() {
  (
    t_load >/dev/null 2>&1
    OMB_FIXTURE="$FIX/$1"
    mac_detect
    mac_plan_compute "$3"
    plan_layout $(($2 * GB))
    printf '%s %s' "${PLAN_ANSWER_RESIZE:--}" "$PLAN_ANSWER_OS"
  )
}

t_done() {
  printf '%s: %d passed, %d failed, %d skipped\n' "$1" "$T_PASS" "$T_FAIL" "$T_SKIP"
  [ "$T_FAIL" = 0 ]
}
