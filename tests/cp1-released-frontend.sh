#!/usr/bin/env bash
# CP1: execute the actual published native artifact, acquired and verified
# against the admitted production lock. All downloads and harness caches are
# test scratch; the existing terminal harness owns startup-check evidence.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
T=$(t_tmp)
TMPDIR=$T
trap 'rm -rf "$T"' EXIT
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"
# shellcheck source=lib/state.sh
. "$REPO/lib/state.sh"
# shellcheck source=lib/records.sh
. "$REPO/lib/records.sh"
# shellcheck source=lib/core.sh
. "$REPO/lib/core.sh"
# shellcheck source=lib/frontend.sh
. "$REPO/lib/frontend.sh"
OMB_HOME=$REPO OMB_FIXTURE=""
if ! fe_lock_read; then
  fail "CP1 published native artifact: $FE_WHY (required, never skipped)"
  t_done cp1-released-frontend
  exit 1
fi
assert_eq "$FE_VERSION" 0.1.0 "CP1 published version"
assert_eq "$FE_PROTO" 1 "CP1 published protocol"
if [ "$T_FAIL" != 0 ]; then t_done cp1-released-frontend; exit 1; fi
printf 'CP1 published artifact: target=%s version=%s proto=%s\nURL=%s\nsize=%s SHA-256=%s\n' \
  "$FE_TARGET" "$FE_VERSION" "$FE_PROTO" "$FE_URL" "$FE_SIZE" "$FE_SHA"
if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 -o "$T/omb-tui" "$FE_URL"; then
  fail "CP1 published artifact download failed"
  t_done cp1-released-frontend
  exit 1
fi
if ! fe_verified "$T/omb-tui"; then
  fail "CP1 published artifact differs from the production lock: size=$FE_GOT_SIZE SHA-256=$FE_GOT_SHA"
  t_done cp1-released-frontend
  exit 1
fi
ok
printf 'CP1 published artifact verified from production lock; executing native startup-check against current core\n'
chmod +x "$T/omb-tui"
if OMB_TEST_ARTIFACT="$T/omb-tui" OMB_TEST_ARTIFACT_VERSION="$FE_VERSION" \
  "$T_BASH" "$TESTS_DIR/frontend-check.sh"; then
  ok
else
  fail "CP1 actual published artifact startup-check did not complete"
fi
omb_cleanup
t_done cp1-released-frontend
