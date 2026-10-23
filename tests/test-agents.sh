#!/usr/bin/env bash
# Static AI observations and explicit installs/handoffs; synthetic homes only.
# shellcheck disable=SC2015,SC2016,SC2034,SC2030,SC2031,SC2317,SC2329 # harness assertions; literal wrapper bytes; public hooks
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo test-agents
agents_fixture_before=$(t_snapshot "$FIX")
t_load
# shellcheck source=lib/records.sh
. "$REPO/lib/records.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"

T=$(t_tmp)
trap 'chmod -R u+rwX "$T"; rm -rf "$T"' EXIT
HOME=/home/alex OMB_FIXTURE=$FIX/agt-wrappers OMB_STATE_DIR=$T/state
OMB_PLATFORM=linux OMB_UID=1000 OMB_INTENT=read OMB_PERSIST=0 OMB_DRY_RUN=0
assert_eq "$(agent_ids)" 'claude-code codex opencode' agents-table
for id in $(agent_ids); do
  agent_observe "$id"
  assert_eq "$AG_INSTALLED|$AG_WRAPPER|$AG_RAN|$AG_CONFIGURED|$AG_SIGNIN" 'none|1|0|0|0' "agents-wrapper-alone-$id"
done
agent_info unknown && fail agents-unknown-id || ok

OMB_FIXTURE=$FIX/agt-installed
for id in $(agent_ids); do
  agent_observe "$id"
  assert_eq "$AG_INSTALLED|$AG_VERSION|$AG_WRAPPER|$AG_CONFIGURED|$AG_SIGNIN|$AG_RAN" 'mise|1.2.3|1|1|1|0' "agents-installed-$id"
done
# Authentication contents may be unreadable. Merely observing them succeeds.
fx=$(t_variant agt-installed)
chmod 000 "$fx/root/home/alex/.codex/auth.json"
OMB_FIXTURE=$fx
agent_observe codex
assert_eq "$AG_SIGNIN" 1 agents-unreadable-signin-presence

# Empty folders, latest aliases, linked version folders, and a mise shim
# have no executable installation; a foreign executable keeps its path.
fx=$(t_variant agt-wrappers)
mkdir -p "$fx/root/home/alex/.local/share/mise/installs/codex/empty" "$fx/root/home/alex/.local/share/mise/shims"
ln -s "$FIX/agt-installed/root/home/alex/.local/share/mise/installs/codex/1.2.3" "$fx/root/home/alex/.local/share/mise/installs/codex/latest"
ln -s latest "$fx/root/home/alex/.local/share/mise/installs/codex/2.0"
printf '/home/alex/.local/share/mise/shims/codex\n' >"$fx/cmd/agent_path_codex"
cp "$fx/root/home/alex/.local/bin/codex" "$fx/root/home/alex/.local/share/mise/shims/codex"
OMB_FIXTURE=$fx
agent_observe codex
assert_eq "$AG_INSTALLED" none agents-shim-and-alias-not-installed
OMB_FIXTURE=$FIX/agt-foreign
agent_observe codex
assert_eq "$AG_INSTALLED|$AG_PATH|$AG_WRAPPER" 'other|/usr/bin/codex|0' agents-foreign-binary
# A modified launcher is a foreign executable, never identified by a substring.
fx=$(t_variant agt-wrappers)
printf '# custom\n' >>"$fx/root/home/alex/.local/bin/codex"
OMB_FIXTURE=$fx
agent_observe codex
assert_eq "$AG_INSTALLED|$AG_WRAPPER" 'other|0' agents-exact-wrapper-content
fx=$(t_variant agt-wrappers)
printf '\0' >>"$fx/root/home/alex/.local/bin/codex"
OMB_FIXTURE=$fx
agent_observe codex
assert_eq "$AG_INSTALLED|$AG_WRAPPER" 'other|0' agents-wrapper-rejects-nul

# A real temporary home with executable traps on PATH and in every possible
# install/wrapper location proves observe never executes any of those files.
(
  OMB_FIXTURE='' HOME=$T/home OMB_STATE_DIR=$T/no-state
  mkdir -p "$HOME/.local/bin" "$T/shims"
  SHIM_LOG=$T/executed
  export SHIM_LOG
  for bin in claude codex opencode mise; do
    printf '%s\n' '#!/bin/sh' 'echo executed >>"$SHIM_LOG"' 'exit 97' >"$T/shims/$bin"
    chmod +x "$T/shims/$bin"
  done
  PATH="$T/shims:$PATH"
  for id in $(agent_ids); do
    agent_info "$id"
    mkdir -p "$HOME/.local/share/mise/installs/$AG_PACKAGE/1.0/bin"
    cp "$T/shims/$AG_BINARY" "$HOME/.local/share/mise/installs/$AG_PACKAGE/1.0/bin/$AG_BINARY"
    cp "$FIX/agt-wrappers/root/home/alex/.local/bin/$AG_BINARY" "$HOME/.local/bin/$AG_BINARY"
    mkdir -p "$HOME/.local/share/mise/shims"
    cp "$T/shims/$AG_BINARY" "$HOME/.local/share/mise/shims/$AG_BINARY"
    agent_observe "$id" || exit 1
    [ "$AG_INSTALLED" = mise ] && [ "$AG_WRAPPER" = 1 ] || exit 1
  done
  rm -rf "$HOME/.local/share/mise/installs"
  PATH="$HOME/.local/share/mise/shims:$PATH"
  for id in $(agent_ids); do
    agent_observe "$id" || exit 1
    [ "$AG_INSTALLED" = none ] && [ "$AG_WRAPPER" = 1 ] || exit 1
  done
  [ ! -e "$T/no-state" ] && [ ! -s "$T/executed" ]
) && ok || fail agents-observe-executes-nothing

# The restore marker is an exact complete non-secret record, not arbitrary
# output mentioning the tool; a torn line never counts.
OMB_FIXTURE=$FIX/agt-installed
mkdir -p "$OMB_STATE_DIR/restore/runs"
printf 'agent\ttool=codex\tran=1' >"$OMB_STATE_DIR/restore/runs/one.log"
agent_observe codex
assert_eq "$AG_RAN" 0 agents-torn-restore-line
printf '\n' >>"$OMB_STATE_DIR/restore/runs/one.log"
agent_observe codex
assert_eq "$AG_RAN" 1 agents-ran-at-restore
agent_observe claude-code
assert_eq "$AG_RAN" 0 agents-restore-tool-specific
rows=$(agent_health_rows)
assert_eq "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" 3 agents-health-three-rows
assert_contains "$rows" 'ran%20at%20restore:%201' agents-health-distinct-facts
assert_not_contains "$rows" SYNTHETIC_AUTH agents-health-no-credential-content

# Recorded act steps never execute; each package uses Omarchy's single copy.
OMB_INTENT=act OMB_PERSIST=0 OMB_TEST_RECORD=$T/record OMB_TEST_AFTER=$FIX/agt-installed
for id in $(agent_ids); do
  : >"$OMB_TEST_RECORD"
  OMB_FIXTURE=$FIX/agt-wrappers
  agent_install "$id"
  assert_rc "$?" 0 "agents-install-$id"
  assert_eq "$AG_INSTALL_OUTCOME|$AG_INSTALL_RAN|$AG_INSTALLED" 'success|1|mise' "agents-install-observed-$id"
  assert_eq "$(cat "$OMB_TEST_RECORD")" "mise use -g --quiet $AG_PACKAGE
timeout 30 mise x $AG_PACKAGE -- $AG_BINARY --version" "agents-install-one-copy-$id"
  before=$(cat "$OMB_TEST_RECORD")
  agent_install "$id"
  assert_eq "$AG_INSTALL_OUTCOME|$AG_INSTALL_RAN" 'already-satisfied|0' "agents-install-rerun-$id"
  assert_eq "$(cat "$OMB_TEST_RECORD")" "$before" "agents-rerun-no-version-$id"
done

OMB_FIXTURE=$FIX/agt-wrappers OMB_TEST_RC=1
: >"$OMB_TEST_RECORD"
agent_install codex && fail agents-install-command-failure || ok
assert_eq "$(wc -l <"$OMB_TEST_RECORD" | tr -d ' ')" 1 agents-no-version-after-install-failure
assert_eq "$AG_INSTALLED|$AG_INSTALL_RAN" 'mise|0' agents-failed-install-keeps-files-fact
OMB_TEST_RC=0 OMB_TEST_AFTER=$FIX/agt-wrappers OMB_FIXTURE=$FIX/agt-wrappers
agent_install codex && fail agents-helper-exit-not-proof || ok
assert_eq "$AG_INSTALL_RAN|$AG_INSTALLED" '0|none' agents-missing-artifact-not-success
# Fail only the version invocation, retaining the real recorder for argv.
(
  eval "$(declare -f run | sed '1s/run/agent_test_run/')"
  run() { if [ "$1" = timeout ]; then OMB_TEST_RC=124 agent_test_run "$@"; else agent_test_run "$@"; fi; }
  OMB_TEST_AFTER=$FIX/agt-installed OMB_FIXTURE=$FIX/agt-wrappers
  agent_install codex
  [ "$?" = 1 ] && [ "$AG_INSTALL_RAN" = 0 ] && [ "$AG_INSTALLED" = mise ]
) && ok || fail agents-version-timeout-keeps-files-fact

for missing in mise timeout; do
  fx=$(t_variant agt-wrappers)
  awk -v m="$missing" '$0 != m' "$fx/commands" >"$T/commands"
  cp "$T/commands" "$fx/commands"
  OMB_FIXTURE=$fx
  : >"$OMB_TEST_RECORD"
  agent_install codex && fail "agents-missing-$missing" || ok
  assert_empty_file "$OMB_TEST_RECORD" "agents-refuse-before-install-$missing"
done
OMB_FIXTURE=$FIX/agt-wrappers OMB_UID=0
agent_install codex >/dev/null && fail agents-root-install-refused || ok
OMB_UID=1000 OMB_PLATFORM=macos
agent_install codex >/dev/null && fail agents-macos-install-refused || ok
OMB_PLATFORM=linux OMB_INTENT=read
agent_install codex >/dev/null && fail agents-read-install-refused || ok
OMB_INTENT=act OMB_DRY_RUN=1 OMB_FIXTURE=$FIX/agt-wrappers
: >"$OMB_TEST_RECORD"
agent_install codex >/dev/null
assert_eq "$AG_INSTALL_OUTCOME|$AG_INSTALL_RAN" 'previewed|0' agents-dry-run-no-start-claim
assert_empty_file "$OMB_TEST_RECORD" agents-dry-run-no-execution
OMB_DRY_RUN=0

# Tool-owned foreground commands, requested individually, with no auth read.
OMB_FIXTURE=$FIX/agt-installed OMB_TEST_AFTER=''
for id in $(agent_ids); do
  : >"$OMB_TEST_RECORD"
  agent_signin "$id" >/dev/null
  assert_rc "$?" 0 "agents-signin-$id"
  assert_eq "$(cat "$OMB_TEST_RECORD")" "$AG_PATH${AG_SIGNIN_ARGS[*]:+ ${AG_SIGNIN_ARGS[*]}}" "agents-handoff-observed-path: signin $id"
  : >"$OMB_TEST_RECORD"
  agent_mcp_list "$id" >/dev/null
  assert_eq "$(cat "$OMB_TEST_RECORD")" "timeout 30 $AG_PATH mcp list" "agents-handoff-observed-path: mcp $id"
done
OMB_FIXTURE=$FIX/agt-foreign
: >"$OMB_TEST_RECORD"
agent_signin codex >/dev/null
assert_eq "$(cat "$OMB_TEST_RECORD")" '/usr/bin/codex login --device-auth' 'agents-handoff-observed-path: foreign signin'
: >"$OMB_TEST_RECORD"
agent_mcp_list codex >/dev/null
assert_eq "$(cat "$OMB_TEST_RECORD")" 'timeout 30 /usr/bin/codex mcp list' 'agents-handoff-observed-path: foreign mcp'
OMB_FIXTURE=$FIX/agt-wrappers
agent_mcp_list codex >/dev/null && fail agents-uninstalled-mcp-refused || ok
OMB_FIXTURE=$FIX/agt-installed OMB_UID=0
agent_signin codex >/dev/null && fail agents-root-signin-refused || ok
agent_mcp_list codex >/dev/null && fail agents-root-mcp-refused || ok
OMB_UID=1000
agent_row unknown && fail agents-unknown-row || ok
agent_row agents.mcp
assert_eq "$CA_SCOPE|$CA_INTENT|$CA_TERMINAL|$CA_GATE|$CA_PARAMS" 'health|act|handoff||tool' agents-mcp-row
agent_mcp_judge 0
assert_eq "$CORE_FINDING" completed agents-mcp-completed-handoff
agent_mcp_judge 1
assert_eq "$CORE_FINDING" unexpected agents-mcp-failure-not-health
agent_mcp_judge reconcile
assert_eq "$CORE_FINDING" unexpected agents-mcp-no-retrospective-health

# Production core validation reaches the provider row. Execution still
# requires a terminal; the health snapshot is owned by integration.
c_session
C_FIX=$FIX/agt-installed
C_ENV='HOME=/home/alex OMB_SESSION_SCOPES=health'
c_run validate $'select\taction=agents.mcp' $'arg\tname=tool\tvalue=codex'
assert_eq "$(c_result)" 'done ok' agents-core-valid-tool
assert_eq "$C_ERR" '' agents-core-validation-clean-stderr
assert_contains "$C_OUT" 'review' agents-core-review
basis=$(printf '%s\n' "$C_OUT" | awk -F '\t' '$1 == "review" { sub(/^basis=/, "", $3); print $3 }')
c_run execute "$(printf 'exec\taction=agents.mcp\tbasis=%s\tconfirm=' "$basis")" $'arg\tname=tool\tvalue=codex'
assert_eq "$(c_result)" 'refused unavailable' agents-core-terminal-required
assert_contains "$C_OUT" 'terminal' agents-core-no-headless-handoff
c_run validate $'select\taction=agents.mcp' $'arg\tname=tool\tvalue=unknown'
assert_eq "$(c_result)" 'refused invalid' agents-core-invalid-tool
c_run validate $'select\taction=agents.mcp'
assert_eq "$(c_result)" 'refused invalid' agents-core-missing-tool
c_run validate $'select\taction=agents.mcp' $'arg\tname=other\tvalue=codex'
assert_eq "$(c_result)" 'refused invalid' agents-core-unknown-argument
C_FIX=$FIX/agt-wrappers
c_run validate $'select\taction=agents.mcp' $'arg\tname=tool\tvalue=codex'
assert_eq "$(c_result)" 'refused unavailable' agents-core-wrapper-unavailable

assert_eq "$(t_snapshot "$FIX")" "$agents_fixture_before" agents-fixtures-read-only

t_done test-agents
