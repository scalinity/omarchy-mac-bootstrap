# shellcheck shell=bash
# Run directly to regenerate this unit only, or source from generate.sh.
# A subshell keeps helpers and loop variables out of the parent generator.
(
set -eu
cd "$(dirname "${BASH_SOURCE[0]}")"
agt_put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; }
# Synthetic Omarchy homes. Wrapper bytes follow omarchy-mac quattro
# ba546a6 bin/omarchy-mise-install:21-27; these are never executed.
for agt_name in agt-wrappers agt-installed agt-foreign; do
  rm -rf "$agt_name"
  cp -R linux-omarchy-installed "$agt_name"
  printf 'mise\ntimeout\nclaude\ncodex\nopencode\n' >>"$agt_name/commands"
  for agt_bin in claude codex opencode; do
    agt_put "$agt_name/root/home/alex/.local/bin/$agt_bin" "$(printf '%s\n' \
      '#!/bin/bash' 'export MISE_MINIMUM_RELEASE_AGE=0' \
      "mise use -g --quiet \"$agt_bin\" || exit 1" \
      "exec mise x \"$agt_bin\" -- \"$agt_bin\" \"\$@\"")"
    chmod +x "$agt_name/root/home/alex/.local/bin/$agt_bin"
    agt_put "$agt_name/cmd/agent_path_$agt_bin" "/home/alex/.local/bin/$agt_bin"
  done
  agt_put "$agt_name/cmd/agent_path_claude-code" /home/alex/.local/bin/claude
  if [ "$agt_name" = agt-installed ]; then
    for agt_bin in claude codex opencode; do
      agt_put "$agt_name/root/home/alex/.local/share/mise/installs/$agt_bin/1.2.3/bin/$agt_bin" '#!/bin/sh
exit 97'
      chmod +x "$agt_name/root/home/alex/.local/share/mise/installs/$agt_bin/1.2.3/bin/$agt_bin"
    done
    agt_put "$agt_name/root/home/alex/.local/share/mise/installs/codex/2.0/bin/codex" '#!/bin/sh
exit 97'
    chmod +x "$agt_name/root/home/alex/.local/share/mise/installs/codex/2.0/bin/codex"
    agt_put "$agt_name/root/home/alex/.claude/settings.json" '{}'
    agt_put "$agt_name/root/home/alex/.claude/.credentials.json" SYNTHETIC_AUTH_NEVER_READ
    agt_put "$agt_name/root/home/alex/.codex/config.toml" 'model = "example"'
    agt_put "$agt_name/root/home/alex/.codex/auth.json" SYNTHETIC_AUTH_NEVER_READ
    agt_put "$agt_name/root/home/alex/.config/opencode/opencode.json" '{}'
    agt_put "$agt_name/root/home/alex/.local/share/opencode/auth.json" SYNTHETIC_AUTH_NEVER_READ
  elif [ "$agt_name" = agt-foreign ]; then
    rm "$agt_name/root/home/alex/.local/bin/codex"
    agt_put "$agt_name/root/usr/bin/codex" '#!/bin/sh
exit 97'
    chmod +x "$agt_name/root/usr/bin/codex"
    agt_put "$agt_name/cmd/agent_path_codex" /usr/bin/codex
  fi
done

)
