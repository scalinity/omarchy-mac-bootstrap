#!/usr/bin/env bash
# Missing identity and opaque upstream whitespace use existing read owners.
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-gate2-edge
T=$(t_tmp)
c_session
C_FIX=$(t_variant linux-omarchy-installed)
: >"$C_FIX/root/proc/device-tree/model"
c_run snapshot "scope	name=journey"
assert_eq "$(c_admits snapshot)" ok 'unknown identity has a schema-valid representation'
assert_contains "$C_OUT" 'key=machine.model	label=Model	value=unknown	state=unknown' 'missing model remains explicitly unknown'
assert_eq "$C_ERR" '' 'unknown identity clean stderr'
# The fixture's root identity selects the upstream status read, never sudo.
printf '0\n' >"$C_FIX/cmd/id_u"
printf 'first\n\nlast\n\n' >"$C_FIX/cmd/setup_status"
mkdir -p "$T/base" "$T/tmp"
git -C "$REPO" archive 2edb76a7de3f78ec90927ac93d5eec3a84636253 | tar -x -C "$T/base" || exit 1
for mode in base dataset; do
  tree=$REPO
  [ "$mode" != base ] || tree=$T/base
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$T/home" TMPDIR="$T/tmp" \
    OMB_STATE_DIR="$T/state" OMB_FIXTURE="$C_FIX" G2_CANDIDATE="$REPO" G2_PROBES="$T/$mode.probes" \
    "$T_BASH" "$TESTS_DIR/gate2-oracle.sh" "$tree" "$mode" >"$T/$mode.out" 2>"$T/$mode.err"
  assert_rc "$?" 0 "$mode upstream read succeeds"
  assert_empty_file "$T/$mode.err" "$mode upstream clean stderr"
done
actual=$(awk -F '\t' '$1 == "guide" || $1 == "code" || ($1 == "row" && $2 == "kind=status")' "$T/dataset.out")
assert_eq "$actual" "$(cat "$T/base.out")" 'upstream internal and trailing blank lines preserved'
assert_eq "$(cat "$T/dataset.probes")" "$(cat "$T/base.probes")" 'upstream probe footprint unchanged'
c_run snapshot "scope	name=journey"
assert_eq "$(c_admits snapshot)" ok 'root fixture upstream snapshot admitted'
assert_eq "$C_ERR" '' 'root fixture upstream stderr empty'
# A hash tool printing a digest and then failing must not produce a success.
mkdir -p "$T/hash-bin"
cat >"$T/hash-bin/shasum" <<'HASH'
#!/bin/sh
case "${3:-}" in */journey) printf '%064d  %s\n' 0 "$3"; exit 1 ;; esac
if [ -x /usr/bin/shasum ]; then exec /usr/bin/shasum "$@"; fi
shift 2
exec sha256sum "$@"
HASH
chmod +x "$T/hash-bin/shasum"
C_PATH="$T/hash-bin:/usr/bin:/bin:/usr/sbin:/sbin" c_run snapshot "scope	name=journey"
assert_eq "$(c_result)" 'error io' 'hash failure refuses even after printing a digest'
assert_eq "$(c_admits snapshot)" ok 'hash failure has an admissible refusal'
assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^fact	')" 0 'hash failure exposes no partial facts'
t_done test-gate2-edge
