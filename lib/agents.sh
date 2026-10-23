# shellcheck shell=bash
# shellcheck disable=SC2034 # public table, observation and core hook outputs
# Shared AI tool table. Static observation reads files, never a launcher,
# mise, an agent, or authentication contents. Package names and the wrapper
# template follow omarchy-mac quattro ba546a6, bin/omarchy-mise-install.

agent_ids() { printf '%s\n' 'claude-code codex opencode'; }

# agent_info ID — table fields; all paths are relative to the everyday home.
agent_info() {
  AG_ID=$1 AG_LABEL='' AG_PACKAGE='' AG_BINARY=''
  AG_CONFIG_FILES=() AG_SIGNIN_FILES=() AG_SIGNIN_ARGS=() AG_MCP_ARGS=(mcp list)
  case "$1" in
    claude-code)
      AG_LABEL='Claude Code' AG_PACKAGE=claude AG_BINARY=claude
      AG_CONFIG_FILES=(.claude/settings.json .claude/CLAUDE.md)
      AG_SIGNIN_FILES=(.claude/.credentials.json)
      ;;
    codex)
      AG_LABEL=Codex AG_PACKAGE=codex AG_BINARY=codex
      AG_CONFIG_FILES=(.codex/config.toml .codex/AGENTS.md .codex/AGENTS.override.md)
      AG_SIGNIN_FILES=(.codex/auth.json .codex/.credentials.json)
      AG_SIGNIN_ARGS=(login --device-auth)
      ;;
    opencode)
      AG_LABEL=OpenCode AG_PACKAGE=opencode AG_BINARY=opencode
      AG_CONFIG_FILES=(.config/opencode/opencode.json .config/opencode/opencode.jsonc .config/opencode/AGENTS.md)
      AG_SIGNIN_FILES=(.local/share/opencode/auth.json .local/share/opencode/mcp-auth.json)
      AG_SIGNIN_ARGS=(auth login)
      ;;
    *) return 1 ;;
  esac
}

# Compare the complete bounded regular file byte for byte, including NULs
# and its final LF. Never run a file to identify an Omarchy wrapper.
_agent_wrapper() {
  local file=$1 size
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  size=$(LC_ALL=C wc -c <"$file") || return 1
  _whole "$size" '^ *[0-9]+$' || return 1
  [ "$size" -le 1024 ] || return 1
  printf '%s\n' '#!/bin/bash' 'export MISE_MINIMUM_RELEASE_AGE=0' \
    "mise use -g --quiet \"$AG_PACKAGE\" || exit 1" \
    "exec mise x \"$AG_PACKAGE\" -- \"$AG_BINARY\" \"\$@\"" | cmp -s "$file" -
}

# Restore writes this non-secret record only after agent_install reports
# AG_INSTALL_RAN=1: agent<TAB>tool=ID<TAB>ran=1<LF>. Ignore torn last lines.
# Logs are this program's own state, not paths supplied by their contents.
_agent_restore_ran() {
  local file line want
  want=$(printf 'agent\ttool=%s\tran=1' "$AG_ID")
  [ -n "${OMB_STATE_DIR:-}" ] || return 1
  for file in "$OMB_STATE_DIR"/restore/runs/*.log; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    while IFS= read -r line; do
      [ "$line" != "$want" ] || return 0
    done <"$file"
  done
  return 1
}

# agent_observe ID — AG_INSTALLED=mise|other|none, AG_VERSION, AG_PATH,
# AG_RAN, AG_CONFIGURED, AG_SIGNIN and AG_WRAPPER (0|1). Installed means
# executable files exist, never that the tool starts or its sign-in works.
# sys_walk refuses linked roots and follows no links within version folders.
agent_observe() {
  AG_INSTALLED=none AG_VERSION='' AG_PATH='' AG_RAN=0 AG_CONFIGURED=0 AG_SIGNIN=0 AG_WRAPPER=0
  agent_info "$1" || return 1
  local file base listing type _size _mode rel _link version rest candidate
  file=$(sys_path "$HOME/.local/bin/$AG_BINARY")
  if _agent_wrapper "$file"; then AG_WRAPPER=1; fi
  base="$HOME/.local/share/mise/installs/$AG_PACKAGE"
  if listing=$(sys_walk "$base" 20000); then
    while IFS="$(printf '\t')" read -r type _size _mode rel _link; do
      [ "$type" = f ] || continue
      case "$rel" in */*) ;; *) continue ;; esac
      version=${rel%%/*}
      case "$version" in latest | '' | *[!A-Za-z0-9._+-]*) continue ;; esac
      rest=${rel##*/}
      [ "$rest" = "$AG_BINARY" ] || continue
      candidate=$(sys_path "$base/$rel")
      if [ -x "$candidate" ]; then
        AG_INSTALLED=mise AG_VERSION=$version AG_PATH="$base/$rel"
        break
      fi
    done <<EOF
$listing
EOF
  fi
  if [ "$AG_INSTALLED" = none ]; then
    # command -v is a shell lookup, not an invocation. A mise shim alone is
    # no installation; a foreign executable is reported by its actual path.
    candidate=$(sys_cmd "agent_path_$AG_ID" command -v "$AG_BINARY") || candidate=''
    for candidate in "$candidate" "$HOME/.local/bin/$AG_BINARY"; do
      case "$candidate" in /*) ;; *) continue ;; esac
      case "$candidate" in "$HOME/.local/share/mise/shims/"* | "$HOME/.local/share/mise/installs/"*) continue ;; esac
      file=$(sys_path "$candidate")
      [ -f "$file" ] && [ -x "$file" ] || continue
      if _agent_wrapper "$file"; then continue; fi
      AG_INSTALLED=other AG_PATH=$candidate
      break
    done
  fi
  for candidate in "${AG_CONFIG_FILES[@]}"; do
    file=$(sys_path "$HOME/$candidate")
    if [ -f "$file" ] && [ ! -L "$file" ]; then AG_CONFIGURED=1; fi
  done
  for candidate in "${AG_SIGNIN_FILES[@]}"; do
    file=$(sys_path "$HOME/$candidate")
    # Presence only, including an unreadable sign-in file. Never open it.
    if [ -f "$file" ] && [ ! -L "$file" ]; then AG_SIGNIN=1; fi
  done
  if _agent_restore_ran; then AG_RAN=1; fi
  return 0
}

_agent_user() {
  AG_WHY=''
  if [ "${OMB_PLATFORM:-}" != linux ]; then AG_WHY='AI setup is available on Linux.'
  elif [ "${OMB_UID:-0}" = 0 ]; then AG_WHY='Run AI setup as the everyday user.'
  else return 0
  fi
  ui_fail "$AG_WHY"
  return 1
}

# No owned save: the restore owner logs AG_INSTALL_RAN in its existing run
# log. dev does not claim that its own version check happened at restore.
agent_install() {
  AG_INSTALL_RAN=0 AG_INSTALL_OUTCOME=failed AG_WHY=''
  agent_observe "$1" || { AG_WHY='Unknown AI tool.'; return 1; }
  _agent_user || return 1
  if [ "$AG_INSTALLED" != none ]; then AG_INSTALL_OUTCOME=already-satisfied; return 0; fi
  if ! sys_has mise; then AG_WHY='mise not found; finish Omarchy setup first.'; return 1; fi
  if ! sys_has timeout; then AG_WHY='timeout not found; the install check cannot be bounded.'; return 1; fi
  local MISE_MINIMUM_RELEASE_AGE=0
  export MISE_MINIMUM_RELEASE_AGE
  if ! run mise use -g --quiet "$AG_PACKAGE"; then
    agent_observe "$1" || return 1
    AG_WHY="$AG_LABEL install failed"
    return 1
  fi
  if [ "$OMB_DRY_RUN" = 1 ]; then AG_INSTALL_OUTCOME=previewed; return 0; fi
  # The only version invocation: immediately after a successful install.
  if ! run timeout 30 mise x "$AG_PACKAGE" -- "$AG_BINARY" --version; then
    agent_observe "$1"
    AG_WHY="$AG_LABEL installed files may exist, but its version check failed or timed out"
    return 1
  fi
  agent_observe "$1" || return 1
  if [ "$AG_INSTALLED" != mise ]; then AG_WHY="$AG_LABEL: mise finished, but no installed executable was found"; return 1; fi
  AG_INSTALL_RAN=1 AG_INSTALL_OUTCOME=success
}

# Explicit foreground handoffs. Bypass the lazy wrapper so a handoff does
# not reset its package pin. Output belongs to the tool and is never parsed.
_agent_handoff() {
  local operation=$1
  shift
  _agent_user || return 1
  if [ "$AG_INSTALLED" = none ]; then AG_WHY='Install this tool before its handoff.'; ui_fail "$AG_WHY"; return 1; fi
  if [ "$operation" = mcp ]; then
    if ! sys_has timeout; then AG_WHY='timeout not found; the live check cannot be bounded.'; ui_fail "$AG_WHY"; return 1; fi
    if [ "$AG_INSTALLED" = mise ]; then
      run timeout 30 mise x "$AG_PACKAGE" -- "$AG_BINARY" "$@"
    else
      run timeout 30 "$AG_PATH" "$@"
    fi
  elif [ "$AG_INSTALLED" = mise ]; then
    run mise x "$AG_PACKAGE" -- "$AG_BINARY" "$@"
  else
    run "$AG_PATH" "$@"
  fi
}

agent_signin() {
  agent_observe "$1" || return 1
  ui_note "$AG_LABEL handles its own sign-in on this terminal; type credentials only into the tool."
  _agent_handoff signin ${AG_SIGNIN_ARGS[@]+"${AG_SIGNIN_ARGS[@]}"}
}

agent_mcp_list() {
  agent_observe "$1" || return 1
  ui_note "$AG_LABEL will contact its MCP servers and may start their commands. Its output is shown as printed."
  _agent_handoff mcp "${AG_MCP_ARGS[@]}"
}

agent_health_rows() {
  local id detail status
  for id in $(agent_ids); do
    agent_observe "$id" || return 1
    detail="installed: $AG_INSTALLED"
    [ -z "$AG_VERSION" ] || detail="$detail $AG_VERSION"
    [ "$AG_INSTALLED" != other ] || detail="$detail ($AG_PATH)"
    detail="$detail; ran at restore: $AG_RAN; configured file: $AG_CONFIGURED; sign-in file: $AG_SIGNIN; Omarchy wrapper: $AG_WRAPPER"
    status=info
    if [ "$AG_INSTALLED" != none ] && [ "$AG_SIGNIN" = 0 ]; then status=warn; fi
    rec_line row kind doctor key "agent.$id" col "$status" col "$AG_LABEL" col "$detail" || return 1
  done
}

agent_row() {
  [ "$1" = agents.mcp ] || return 1
  CA_SCOPE=health CA_INTENT=act CA_TERMINAL=handoff CA_CANCEL=0 CA_GATE='' CA_LIMIT=3
  CA_PLATFORM=linux CA_PHASE=dev CA_PARAMS=tool CA_FN=agent_mcp
  CA_LABEL="List an AI tool's MCP servers"
  CA_EXPLAIN='Runs the selected tool on this terminal, contacting its MCP servers and possibly starting their commands. Output is shown unparsed; this does not certify a working sign-in.'
}

agent_mcp_offer() {
  CA_WHY=''
  if [ "${OMB_PLATFORM:-}" != linux ] || [ "${OMB_UID:-0}" = 0 ]; then
    CA_WHY='MCP checks run on Linux as the everyday user.'
    return 1
  fi
  if ! sys_has timeout; then CA_WHY='timeout is required for an MCP check.'; return 1; fi
  local id
  for id in $(agent_ids); do
    agent_observe "$id" || return 1
    [ "$AG_INSTALLED" = none ] || return 0
  done
  CA_WHY='No AI tool is installed.'
  return 1
}
agent_mcp_facts() {
  rec_line fact scope health key gate.agents.mcp.effect label 'Live MCP check' \
    value 'Contacts servers and may start their commands; output is not parsed.' state warn
}
agent_mcp_params() {
  rec_line param action agents.mcp name tool type choice kind '' required 1 \
    choice claude-code choice codex choice opencode
}
agent_mcp_basis() {
  local tool doc
  core_arg_into tool tool || return 1
  agent_observe "$tool" || return 1
  [ "$AG_INSTALLED" != none ] || return 1
  doc=$(rec_line basis action agents.mcp proto "$REC_PROTO" tool "$tool" \
    installed "$AG_INSTALLED" version "$AG_VERSION" path "$AG_PATH") || return 1
  CORE_BASIS=$(sha256_str "$doc")
}
agent_mcp_run() {
  local tool
  core_arg_into tool tool || return 1
  agent_mcp_list "$tool"
}
agent_mcp_judge() {
  CORE_FINDING=unexpected CORE_JUDGE_TEXT='The MCP handoff did not finish; no server health or sign-in is inferred.'
  if [ "$1" != reconcile ] && [ "$1" = 0 ]; then
    CORE_FINDING=completed CORE_JUDGE_TEXT='The MCP listing finished. Its output is the result; no working sign-in is inferred.'
  fi
}
agent_mcp_validate() {
  local tool='' i=0 name invalid='' text='' status='done' code=ok st body
  omb_tmp_init || { core_result error io 'Cannot prepare the MCP review.'; return; }
  body=$OMB_TMP/agents.validate
  : >"$body" || { core_result error io 'Cannot prepare the MCP review.'; return; }
  while [ "$i" -lt "$CORE_REQ_ARGS" ]; do
    name=${CORE_REQ_ARG_NAME[i]}
    if [ "$name" != tool ]; then
      invalid=$name text='This action accepts only tool.'
      break
    fi
    i=$((i + 1))
  done
  if [ -n "$invalid" ]; then
    rec_line invalid name "$invalid" code unknown-parameter text "$text" >"$body" || return 1
    status=refused code=invalid
  elif ! agent_mcp_offer; then
    status=refused code=unavailable text=$CA_WHY
  elif ! core_arg_into tool tool || ! agent_info "$tool"; then
    text='Choose claude-code, codex or opencode.'
    rec_line invalid name tool code invalid text "$text" >"$body" || return 1
    status=refused code=invalid
  elif ! agent_mcp_basis; then
    text='This tool has no installed executable.'
    rec_line invalid name tool code unavailable text "$text" >"$body" || return 1
    status=refused code=invalid
  else
    { rec_line normal name tool value "$tool" && rec_line review action agents.mcp basis "$CORE_BASIS"; } >"$body" || return 1
  fi
  core_read_prefix || { core_read_failure 1; return; }
  {
    cat "$OMB_TMP/journey.prefix" "$body" &&
      rec_line result status "$status" code "$code" text "$text" next ''
  } >"$OMB_TMP/agents.response" || { core_read_failure 1; return; }
  core_read_admit validate "$OMB_TMP/agents.response"
  st=$?
  if [ "$st" != 0 ]; then core_read_failure "$st"; return; fi
  core_read_publish
}
