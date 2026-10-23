# shellcheck shell=bash
# shellcheck disable=SC2016 # literal $ in the synthetic files written
# The migration's fixtures (Gate 4): synthetic macOS homes under
# root/Users/alex, on the roomy M1 Pro's probes. Sourced by generate.sh, in
# tests/fixtures, after the fixtures it copies. Every value is synthetic;
# every secret below is shaped like a real one and grants nothing.
#
#   mig-mac-home     an everyday Mac: Homebrew, applications, language tools,
#                    editors, Zsh, terminal and Git settings, SSH (one
#                    encrypted key), the AI tools, chosen folders and projects
#   mig-mac-secrets  the same home with credentials planted where people
#                    leave them
#
# git holds nothing under a folder named .git, so a repository's .git is
# written as dot-git; t_variant (tests/lib.sh) names it .git in its copy.

# _mig_u32 N — four bytes, big-endian.
_mig_u32() {
  local o
  for o in $((($1 >> 24) & 255)) $((($1 >> 16) & 255)) $((($1 >> 8) & 255)) $(($1 & 255)); do
    # shellcheck disable=SC2059 # an octal escape built on purpose
    printf "\\$(printf '%03o' "$o")"
  done
}
_mig_str() { _mig_u32 "${#1}" && printf '%s' "$1"; }

# _mig_key FILE CIPHER KDF ROUNDS — a synthetic openssh-key-v1 envelope: the
# header a key carries, and filler where its keys would be.
_mig_key() {
  local f=$1 cipher=$2 kdf=$3 rounds=$4
  mkdir -p "$(dirname "$f")"
  {
    printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n'
    {
      printf 'openssh-key-v1\000'
      _mig_str "$cipher"
      _mig_str "$kdf"
      if [ "$kdf" = bcrypt ]; then
        _mig_u32 24 && _mig_u32 16 && printf 'FIXTURESALT00000' && _mig_u32 "$rounds"
      else
        _mig_u32 0
      fi
      _mig_u32 1
      _mig_str "ssh-ed25519 FIXTURE PUBLIC KEY BLOB 000000000000000"
      _mig_str "FIXTURE PRIVATE SECTION, NOT A KEY 0000000000000000000000000000"
    } | base64 | tr -d '\n' | fold -w 70
    printf '\n-----END OPENSSH PRIVATE KEY-----\n'
  } >"$f"
}

# _mig_base NAME — the roomy M1 Pro's probes, with the hardware UUID the
# profile binds to and the account the scanner reads.
_mig_base() {
  local d=$1
  rm -rf "$d"
  mkdir -p "$d"
  cp -R mac-m1pro-1tb-roomy/cmd mac-m1pro-1tb-roomy/net mac-m1pro-1tb-roomy/commands "$d/"
  plist "<array><dict><key>_items</key><array><dict><key>machine_name</key><string>MacBook Pro</string><key>machine_model</key><string>MacBookPro18,1</string><key>chip_type</key><string>Apple M1 Pro</string><key>physical_memory</key><string>16 GB</string><key>platform_UUID</key><string>5A1E0000-0000-4000-8000-0000000000A1</string></dict></array></dict></array>" >"$d/cmd/hardware_plist"
  put "$d/cmd/dscl_user" "NFSHomeDirectory: /Users/alex
UserShell: /bin/zsh"
}

_mig_app() { # ROOT NAME BUNDLE-ID VERSION
  mkdir -p "$1/$2/Contents"
  plist "<dict><key>CFBundleIdentifier</key><string>$3</string><key>CFBundleShortVersionString</key><string>$4</string></dict>" >"$1/$2/Contents/Info.plist"
}

_mig_home() {
  local d=$1 r h b
  r=$d/root
  h=$r/Users/alex
  b=$r/opt/homebrew
  # Homebrew: requested, a dependency, no receipt, a missing tap, a service,
  # a cask with its app, a cask whose app is gone, a tap.
  put "$b/Cellar/ripgrep/14.1.1/INSTALL_RECEIPT.json" '{"installed_on_request":true,"runtime_dependencies":[{"full_name":"pcre2","version":"10.44"}],"source":{"tap":"homebrew/core","spec":"stable"}}'
  put "$b/Cellar/pcre2/10.44/INSTALL_RECEIPT.json" '{"installed_on_request":false,"runtime_dependencies":[],"source":{"tap":"homebrew/core"}}'
  put "$b/Cellar/node/22.11.0/INSTALL_RECEIPT.json" '{"installed_on_request":true,"runtime_dependencies":[],"source":{"tap":"homebrew/core"}}'
  put "$b/Cellar/mystery/1.0/README" 'no receipt here'
  put "$b/Cellar/oddtool/2.0/INSTALL_RECEIPT.json" '{"installed_on_request":true,"runtime_dependencies":[],"source":{"tap":"someone/missing"}}'
  put "$b/Cellar/postgresql@16/16.4/INSTALL_RECEIPT.json" '{"installed_on_request":true,"runtime_dependencies":[],"source":{"tap":"homebrew/core"}}'
  mkdir -p "$b/opt"
  for f in ripgrep/14.1.1 pcre2/10.44 node/22.11.0 oddtool/2.0 postgresql@16/16.4; do
    ln -sfn "../Cellar/$f" "$b/opt/${f%/*}"
  done
  put "$h/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist" '<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>homebrew.mxcl.postgresql@16</string></dict></plist>'
  # A cask whose app moved to /Applications leaves its version folder empty;
  # git keeps no empty folder, so each holds a placeholder the adapter never
  # lists (it lists folders only).
  put "$b/Caskroom/ghostty/1.1.3/.keep" ""
  put "$b/Caskroom/gone-app/2.0/.keep" ""
  put "$b/Caskroom/ghostty/.metadata/INSTALL_RECEIPT.json" '{"installed_on_request":true,"uninstall_artifacts":[{"app":["Ghostty.app"]},{"zap":[]}]}'
  put "$b/Caskroom/gone-app/.metadata/INSTALL_RECEIPT.json" '{"installed_on_request":true,"uninstall_artifacts":[{"app":["Gone.app"]}]}'
  put "$b/Library/Taps/someone/homebrew-tools/dot-git/config" '[remote "origin"]
	url = https://github.com/someone/homebrew-tools
	fetch = +refs/heads/*:refs/remotes/origin/*'
  # Applications: a cask's, a plain one, Apple's, the App Store's, unreadable.
  _mig_app "$r/Applications" Ghostty.app com.mitchellh.ghostty 1.1.3
  _mig_app "$r/Applications" Rectangle.app com.knollsoft.Rectangle 0.80
  _mig_app "$r/Applications" Safari.app com.apple.Safari 18.0
  _mig_app "$r/Applications" Xcode.app com.apple.dt.Xcode 16.0
  put "$r/Applications/Xcode.app/Contents/_MASReceipt/receipt" 'fixture receipt'
  put "$r/Applications/Broken.app/Contents/PkgInfo" "APPL????"
  # Language tools and runtimes.
  put "$h/.nvm/versions/node/v20.11.0/lib/node_modules/typescript/package.json" '{"name":"typescript","version":"5.6.3"}'
  put "$h/.nvm/versions/node/v20.11.0/lib/node_modules/@scope/tool/package.json" '{"name":"@scope/tool","version":"1.0.0"}'
  put "$h/.nvm/versions/node/v20.11.0/lib/node_modules/npm/package.json" '{"name":"npm","version":"10.2.4"}'
  put "$h/.cargo/.crates.toml" '[v1]
"ripgrep 14.1.1 (registry+https://github.com/rust-lang/crates.io-index)" = ["rg"]
"cargo-binstall 1.10.0 (registry+https://github.com/rust-lang/crates.io-index)" = ["cargo-binstall"]'
  put "$h/.local/share/uv/tools/ruff/uv-receipt.toml" '[tool]
requirements = [{ name = "ruff" }]
entrypoints = [
    { name = "ruff", install-path = "/Users/alex/.local/bin/ruff" },
]'
  mkdir -p "$h/go/bin"
  printf '\177ELF fixture\000\000\377 Go buildinf:\000\0000w\257\014path\tgolang.org/x/tools/gopls\nmod\tgolang.org/x/tools/gopls\tv0.16.2\th1:fixture=\ndep\tgolang.org/x/mod\tv0.20.0\n\000\000' >"$h/go/bin/gopls"
  chmod 755 "$h/go/bin/gopls"
  put "$h/.config/mise/config.toml" '[tools]
node = "22"
python = ["3.12", "3.11"]
"npm:prettier" = "latest"

[settings]
experimental = true'
  put "$h/.tool-versions" 'nodejs 20.11.0
# a comment
ruby 3.3.5'
  # Editors.
  put "$h/Library/Application Support/Code/User/settings.json" '{"editor.fontSize": 14, "workbench.colorTheme": "Default Dark Modern"}'
  put "$h/.vscode/extensions/extensions.json" '[{"identifier":{"id":"ms-python.python"},"version":"2024.20.0"},{"identifier":{"id":"rust-lang.rust-analyzer"},"version":"0.3.2200"}]'
  put "$h/.config/nvim/init.lua" 'vim.opt.number = true
require("opts")'
  put "$h/.config/nvim/lua/opts.lua" 'vim.opt.relativenumber = true
-- see /Users/alex/notes/vim.md'
  # Zsh: what becomes Bash, and what never does.
  put "$h/.zshenv" 'export PAGER=less'
  put "$h/.zprofile" 'eval "$(/opt/homebrew/bin/brew shellenv)"
export VISUAL=nvim'
  put "$h/.zshrc" '# Zsh for alex (fixture)
export EDITOR=nvim
export LESS="-R"
export BAT_THEME='"'"'Dracula'"'"'
export HISTSIZE=10000
export PATH="/opt/homebrew/bin:$PATH"
export HOMEBREW_NO_ANALYTICS=1
export NOTES_DIR=/Users/alex/notes
export RIPGREP_CONFIG_PATH=/Users/alex/.config/ripgrep/rc
alias gs='"'"'git status'"'"'
alias ll="ls -la"
alias cpwd='"'"'pwd | pbcopy'"'"'
alias ls='"'"'ls -G'"'"'
alias greet='"'"'echo $USER'"'"'
alias plain=ls
alias -g G='"'"'| grep'"'"'
touch "$HOME/omb-sourced-zshrc"
if [[ $OSTYPE == darwin* ]]; then
  alias inside_if='"'"'echo nested'"'"'
fi
mkcd() {
  alias inside_fn='"'"'echo fn'"'"'
  mkdir -p "$1" && cd "$1"
}
cat <<EOF >/dev/null
alias inside_heredoc='"'"'echo heredoc'"'"'
EOF
alias after_heredoc='"'"'echo after'"'"'
source ~/.oh-my-zsh/oh-my-zsh.sh
setopt autocd
bindkey -e'
  # Terminal settings.
  put "$h/.config/ghostty/config" '# Ghostty (fixture)
font-size = 14
theme = catppuccin-mocha
macos-titlebar-style = tabs
config-file = /Users/alex/.config/ghostty/extra'
  put "$h/.config/starship.toml" 'add_newline = false

[character]
success_symbol = "[>](bold green)"'
  put "$h/.tmux.conf" 'set -g mouse on
set -g default-command "reattach-to-user-namespace -l zsh"'
  # Git, gh and SSH.
  put "$h/.gitconfig" '[user]
	name = Alex Fixture
	email = alex@example.com
[core]
	excludesfile = /Users/alex/.gitignore_global
	editor = nvim
[alias]
	st = status -sb
	nuke = !git clean -fdx
[credential]
	helper = osxkeychain
[init]
	defaultBranch = main
[url "git@github.com:"]
	insteadOf = https://github.com/
[http]
	postBuffer = 524288000
[include]
	path = ~/.gitconfig.local'
  put "$h/.gitignore_global" '.DS_Store
*.swp'
  put "$h/.config/gh/config.yml" 'git_protocol: ssh
editor: nvim'
  put "$h/.ssh/config" 'Host *
  UseKeychain yes
  AddKeysToAgent yes
  IdentityFile ~/.ssh/id_ed25519
Host build
  HostName build.example.com
  IdentityFile /Users/alex/.ssh/id_ed25519
  usekeychain no'
  put "$h/.ssh/known_hosts" 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREFIXTUREFIXTUREFIXTUREFIXTUREFIXTURE'
  put "$h/.ssh/id_ed25519.pub" 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTUREFIXTUREFIXTUREFIXTUREFIXTURE alex@fixture'
  _mig_key "$h/.ssh/id_ed25519" aes256-ctr bcrypt 16
  # The AI tools.
  put "$h/.claude/settings.json" '{"model":"opus","theme":"dark","permissions":{"allow":["Bash(ls:*)"],"deny":["Read(./.env)"]},"env":{"FIXTURE_MODE":"fast"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"touch ~/omb-hook-ran"}]}]},"statusLine":{"type":"command","command":"touch ~/omb-statusline-ran"},"includeCoAuthoredBy":false}'
  put "$h/.claude/CLAUDE.md" '# Instructions (fixture)
Prefer small diffs. Notes live in /Users/alex/notes.'
  put "$h/.claude/skills/review/SKILL.md" '---
name: review
---
Review the diff.'
  put "$h/.claude/agents/helper.md" 'A helper agent (fixture).'
  put "$h/.claude/plugins/installed_plugins.json" '{"version":2,"plugins":{"superpowers@market":[{"scope":"user","version":"1.0.0"}]}}'
  put "$h/.claude/plugins/known_marketplaces.json" '{"market":{"source":{"source":"github","repo":"example/market"},"installLocation":"/Users/alex/.claude/plugins/marketplaces/market"}}'
  put "$h/.claude/projects/-Users-alex-code-app/session.jsonl" '{"type":"user","message":"a fixture session"}'
  put "$h/.claude.json" '{"numStartups":3,"mcpServers":{"context7":{"command":"npx","args":["-y","@upstash/context7-mcp"],"env":{"CONTEXT7_MODE":"fixture"}},"files":{"command":"/Users/alex/bin/mcp-files","args":["--root","/Users/alex/code"]}},"projects":{"/Users/alex/code/app":{"allowedTools":[]}}}'
  put "$h/.codex/config.toml" '# Codex (fixture)
model = "gpt-5.5-codex"
model_reasoning_effort = "high"
approval_policy = "on-request"
sandbox_mode = "workspace-write"
notify = ["bash", "-lc", "touch ~/omb-notify-ran"]

[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp"]

[mcp_servers.context7.env]
CONTEXT7_MODE = "fixture"

[mcp_servers."docs.local"]
url = "https://docs.example.com/mcp"
startup_timeout_sec = 20.0

[projects."/Users/alex/code/app"]
trust_level = "trusted"

[projects."/opt/elsewhere"]
trust_level = "trusted"

[plugins."superpowers@openai"]
enabled = true

[features]
web_search = true

[profiles.fast]
model = "gpt-5.5-mini"'
  put "$h/.codex/AGENTS.md" '# Codex instructions (fixture)'
  put "$h/.codex/sessions/2026/10/rollout.jsonl" '{"fixture":"session"}'
  put "$h/.agents/skills/notes/SKILL.md" '---
name: notes
---
Keep notes.'
  put "$h/.config/opencode/opencode.json" '{"$schema":"https://opencode.ai/config.json","theme":"system","mcp":{"local":{"type":"local","command":["npx","-y","mcp-local"],"environment":{"LOCAL_MODE":"fixture"}}},"plugin":["opencode-fixture-plugin"],"share":"manual"}'
  # Chosen folders, a Stow farm, projects, a protected folder, never-carried noise.
  put "$h/.myscripts/run.sh" 'echo run (fixture)'
  put "$h/.config/foo/foo.conf" 'colour = blue'
  put "$h/bin/hello" 'echo hello (fixture)'
  put "$h/dotfiles/stowed/conf.ini" 'key = value'
  ln -sfn conf.ini "$h/dotfiles/stowed/rel-link"
  ln -sfn ../../.zshrc "$h/dotfiles/stowed/out-link"
  ln -sfn ../dotfiles/stowed "$h/.config/stowed"
  put "$h/code/app/dot-git/config" '[remote "origin"]
	url = https://github.com/example/app.git'
  put "$h/code/app/dot-git/HEAD" 'ref: refs/heads/main'
  put "$h/code/app/README.md" 'an app (fixture)'
  put "$h/Documents/notes.txt" 'a protected note (fixture)'
  put "$h/.Trash/old.txt" 'trash (fixture)'
}

_mig_base mig-mac-home
_mig_home mig-mac-home

# The same home with credentials where people leave them. Each value is
# shaped to be found by the scan and grants nothing.
_mig_base mig-mac-secrets
_mig_home mig-mac-secrets
h=mig-mac-secrets/root/Users/alex
cat >>"$h/.zshrc" <<'EOF'
export OPENAI_API_KEY=sk-FIXTUREplantedOPENAIkey000000000001
EOF
put "$h/.claude/settings.json" '{"model":"opus","env":{"ANTHROPIC_API_KEY":"sk-ant-FIXTUREplantedANTHROPICkey000001"},"apiKeyHelper":"security find-generic-password -s fixture -w"}'
put "$h/.claude.json" '{"mcpServers":{"github":{"command":"npx","args":["-y","@modelcontextprotocol/server-github","--api-key","FIXTUREplantedARGsecret0001"],"env":{"GITHUB_TOKEN":"ghp_FIXTUREplantedGITHUBtoken0000000001"}},"remote":{"type":"http","url":"https://api.example.com/mcp?token=FIXTUREplantedURLtoken0001","headers":{"Authorization":"Bearer FIXTUREplantedHEADERtoken0001"}}}}'
put "$h/.codex/config.toml" 'model = "gpt-5.5-codex"

[mcp_servers.github]
command = "npx"
args = ["-y", "server-github", "--token", "FIXTUREplantedCODEXarg0001"]
bearer_token = "FIXTUREplantedBEARERtoken0001"

[mcp_servers.github.env]
GITHUB_TOKEN = "ghp_FIXTUREplantedCODEXtoken00000000001"

[mcp_servers.github.http_headers]
Authorization = "Bearer FIXTUREplantedCODEXheader0001"'
put "$h/.gitconfig" '[user]
	name = Alex Fixture
	email = alex@example.com
[credential]
	helper = osxkeychain
[url "https://alex:FIXTUREplantedGITpassword01@github.com/"]
	insteadOf = https://github.com/'
put "$h/.config/gh/hosts.yml" 'github.com:
    oauth_token: gho_FIXTUREplantedGHOAUTHtoken000000001
    user: alex'
put "$h/.env" 'DATABASE_PASSWORD=FIXTUREplantedDOTENVpassword01'
put "$h/.aws/credentials" '[default]
aws_access_key_id = AKIAFIXTUREPLANTED01
aws_secret_access_key = FIXTUREplantedAWSsecret0000000000000001'
put "$h/.netrc" 'machine example.com login alex password FIXTUREplantedNETRCpassword01'
put "$h/.npmrc" '//registry.npmjs.org/:_authToken=npm_FIXTUREplantedNPMtoken000000001'
put "$h/.myscripts/deploy.sh" 'TOKEN="ghp_FIXTUREplantedOPAQUEtoken00000000001"'
put "$h/.config/nvim/lua/secret.lua" 'vim.g.api = "AIzaFIXTUREplantedGOOGLEkey000000000001"'
put "$h/.config/opencode/opencode.json" '{"provider":{"anthropic":{"options":{"apiKey":"sk-ant-FIXTUREplantedOPENCODEkey00001"}}},"mcp":{"remote":{"type":"remote","url":"https://mcp.example.com","headers":{"Authorization":"Bearer FIXTUREplantedOCheader0001"}}}}'
_mig_key "$h/.ssh/id_plain" none none 0
_mig_key "$h/.ssh/id_weak" aes256-ctr bcrypt 8
put "$h/.ssh/id_legacy" '-----BEGIN RSA PRIVATE KEY-----
RklYVFVSRSBQRU0gS0VZLCBOT1QgQSBLRVk=
-----END RSA PRIVATE KEY-----'
put "$h/.claude/.credentials.json" '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-FIXTUREplantedOAUTHtoken0001"}}'
put "$h/.codex/auth.json" '{"OPENAI_API_KEY":"sk-FIXTUREplantedCODEXauth0000000000001"}'
unset h
