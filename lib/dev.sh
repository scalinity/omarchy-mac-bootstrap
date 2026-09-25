# shellcheck shell=bash
# Optional developer setup, after Omarchy. Modular and rerunnable; nothing is
# installed without being selected. Where Omarchy ships a command for a job
# (omarchy-install-dev-env, omarchy-install-editor-vscode,
# omarchy-setup-security-sshd, omarchy-pkg-add), that command does it.

DEV_MODULES="core languages containers editor git github ssh ai time"
DEV_CORE_PKGS="git github-cli base-devel curl wget jq ripgrep fd fzf tmux btop tree unzip rsync"

# dev_core_missing — core packages not yet installed. One pacman -Qq per call,
# matched in the shell: a fresh list, since dev_run_core may just have
# installed some, and no pipeline to lose a cached value in a subshell.
dev_core_missing() {
  local p out="" have
  have="
$(sys_cmd pacman_qq pacman -Qq)
"
  for p in $DEV_CORE_PKGS; do
    case "$have" in
      *"
$p
"*) ;;
      *) out="$out $p" ;;
    esac
  done
  printf '%s' "${out# }"
}

pkg_add() {
  if sys_has omarchy-pkg-add; then
    run omarchy-pkg-add "$@"
  else
    run sudo pacman -S --needed "$@"
  fi
}

# dev_status MODULE — one-line summary, and DEV_DONE=1 when nothing is left.
dev_status() {
  DEV_DONE=0
  case "$1" in
    core)
      local m
      m=$(dev_core_missing)
      if [ -z "$m" ]; then DEV_DONE=1 && DEV_S="all present"; else DEV_S="missing: $m"; fi
      ;;
    languages)
      DEV_S=""
      sys_has cargo && DEV_S="${DEV_S}rust "
      sys_has uv && DEV_S="${DEV_S}python "
      sys_has node && DEV_S="${DEV_S}node "
      sys_has go && DEV_S="${DEV_S}go "
      DEV_S=${DEV_S:-none yet}
      ;;
    containers)
      DEV_S=""
      sys_has docker && DEV_S="docker (Omarchy default) "
      sys_has podman && DEV_S="${DEV_S}podman"
      DEV_S=${DEV_S:-none}
      ;;
    editor) if sys_has code; then DEV_DONE=1 && DEV_S="VS Code present; Neovim is Omarchy's default"; else DEV_S="Neovim (Omarchy default); VS Code optional"; fi ;;
    git)
      local n
      n=$(sys_cmd git_name git config --global user.name)
      if [ -n "$n" ]; then DEV_DONE=1 && DEV_S="$n <$(sys_cmd git_email git config --global user.email)>"; else DEV_S="identity not set"; fi
      ;;
    github) if sys_cmd gh_status gh auth status >/dev/null; then DEV_DONE=1 && DEV_S="signed in"; else DEV_S="not signed in"; fi ;;
    ssh)
      DEV_S=""
      [ -f "$HOME/.ssh/id_ed25519" ] && DEV_S="key present"
      [ "$(sys_cmd sshd_active systemctl is-active sshd)" = active ] && DEV_S="$DEV_S${DEV_S:+, }sshd on"
      DEV_S=${DEV_S:-no key, sshd off}
      ;;
    ai)
      DEV_S=""
      sys_has claude && DEV_S="claude "
      sys_has codex && DEV_S="${DEV_S}codex"
      DEV_S=${DEV_S:-none}
      ;;
    time)
      if [ "${LX_TZ:-}" = "${CFG_tz:-$LX_TZ}" ] && [ "${LX_LANG:-}" = "${CFG_loc:-$LX_LANG}" ]; then
        DEV_DONE=1 && DEV_S="${LX_TZ:-?} $G_DOT ${LX_LANG:-?}"
      else
        DEV_S="now ${LX_TZ:-?}/${LX_LANG:-?}, planned ${CFG_tz:-?}/${CFG_loc:-?}"
      fi
      ;;
  esac
}

dev_label() {
  case "$1" in
    core) echo "Core tools" ;; languages) echo "Languages" ;; containers) echo "Containers" ;;
    editor) echo "Editor" ;; git) echo "Git identity" ;; github) echo "GitHub CLI" ;;
    ssh) echo "SSH" ;; ai) echo "AI coding CLIs" ;; time) echo "Time & locale" ;;
  esac
}

dev_main() {
  OMB_PHASE=dev
  [ -n "${LX_ARCH:-}" ] || lx_detect
  cfg_load
  if [ -z "${CFG_user:-}" ] && [ -f "$STATE_SYSTEM_FILE" ]; then
    cfg_load "$STATE_SYSTEM_FILE"
  fi
  lx_screen dev
  if [ "$LX_OMARCHY_STATE" != installed ]; then
    ui_fail "Omarchy is not installed yet; the developer setup builds on its commands."
    ui_note "Run ./omarchy-bootstrap first."
    printf '\n'
    return 1
  fi
  if [ "$OMB_UID" = 0 ] && [ "$OMB_DRY_RUN" != 1 ]; then
    ui_fail "Run the developer setup as your everyday user; it uses sudo where needed."
    return 1
  fi

  ui_section "Developer setup" "optional $G_DOT rerunnable"
  local m preset i=0 map=""
  set --
  for m in $DEV_MODULES; do
    i=$((i + 1))
    dev_status "$m"
    preset=off
    case "$m" in
      core) [ "$DEV_DONE" = 0 ] && preset=on ;;
      ssh) [ "${CFG_ssh:-0}" = 1 ] && preset=on ;;
      time) [ "$DEV_DONE" = 0 ] && [ -n "${CFG_tz:-}" ] && preset=on ;;
    esac
    set -- "$@" "$(dev_label "$m")|$DEV_S|$preset"
    map="$map $m"
  done
  ui_multiselect "Choose what to set up" "$@" || {
    printf '\n'
    ui_info "Nothing selected. Nothing changed."
    return 0
  }
  local picked="" n
  for n in $UI_PICKED; do
    case "$n" in *[!0-9]*) continue ;; esac
    # shellcheck disable=SC2086 # $map is a space-separated list by design
    m=$(printf '%s\n' $map | sed -n "${n}p")
    [ -n "$m" ] && picked="$picked $m"
  done
  if [ -z "$picked" ]; then
    ui_info "Nothing selected. Nothing changed."
    return 0
  fi
  for m in $picked; do
    ui_section "$(dev_label "$m")"
    "dev_run_$m"
    state_stamp "dev_${m}_at"
  done
  state_set dev_modules "${picked# }"
  state_stamp dev_last_run_at
  printf '\n'
  ui_ok "Developer setup finished. Rerun './omarchy-bootstrap dev' any time."
  printf '\n'
}

# ---------------------------------------------------------------------------

dev_run_core() {
  local missing
  missing=$(dev_core_missing)
  if [ -z "$missing" ]; then
    ui_ok "All core tools are present."
    return 0
  fi
  ui_kv "Installs" "$missing"
  # shellcheck disable=SC2086 # package list
  pkg_add $missing
}

dev_run_languages() {
  if ! sys_has omarchy-install-dev-env; then
    ui_warn "omarchy-install-dev-env not found; install languages with mise directly."
    return 0
  fi
  ui_note "Uses Omarchy's omarchy-install-dev-env: rust via rustup, python via mise + uv, node and go via mise."
  ui_multiselect "Which toolchains?" \
    "rust|$(sys_has cargo && echo installed || echo rustup)|off" \
    "python|$(sys_has uv && echo installed || echo "mise + uv")|off" \
    "node|$(sys_has node && echo installed || echo mise)|off" \
    "go|$(sys_has go && echo installed || echo mise)|off" || return 0
  local n lang
  for n in $UI_PICKED; do
    case "$n" in 1) lang=rust ;; 2) lang=python ;; 3) lang=node ;; 4) lang=go ;; *) continue ;; esac
    run omarchy-install-dev-env "$lang"
  done
}

dev_run_containers() {
  ui_kv "Docker" "Omarchy installs it; the daemon runs as root" "docker.socket enabled"
  ui_note "Omarchy deliberately does not add you to the docker group (that group is root-equivalent): use sudo docker, or opt in with omarchy-setup-security-sudoless-docker."
  ui_kv "Podman" "daemonless and rootless by default" "docker-compatible CLI"
  ui_note "Podman needs no root daemon and no group; some tools expect a Docker socket and need podman's socket service instead."
  ui_select "Container setup" 3 \
    "Docker|sudoless|opt in to running docker without sudo (root-equivalent)|" \
    "Podman|install|add podman and podman-compose alongside Docker|" \
    "Leave as is||Docker via sudo, as Omarchy ships it|" || return 0
  case "$UI_CHOICE" in
    1)
      if sys_has omarchy-setup-security-sudoless-docker; then
        run omarchy-setup-security-sudoless-docker
      else
        ui_warn "omarchy-setup-security-sudoless-docker not found."
      fi
      ;;
    2) pkg_add podman podman-compose ;;
    *) ui_info "Unchanged." ;;
  esac
}

dev_run_editor() {
  ui_note "Neovim with LazyVim is Omarchy's default. VS Code comes from visual-studio-code-bin, which publishes aarch64 builds; omarchy-pkg-add skips it if the ARM build is unavailable."
  if sys_has code; then
    ui_ok "VS Code is already installed."
    return 0
  fi
  if ui_yesno "Install VS Code?" n; then
    if sys_has omarchy-install-editor-vscode; then
      run omarchy-install-editor-vscode
    else
      pkg_add visual-studio-code-bin
    fi
  fi
}

dev_run_git() {
  local name email
  ui_ask name "Git name" "$(sys_cmd git_name git config --global user.name)" || return 0
  ui_ask email "Git email" "$(sys_cmd git_email git config --global user.email)" || return 0
  [ -n "$name" ] && run git config --global user.name "$name"
  [ -n "$email" ] && run git config --global user.email "$email"
  run git config --global init.defaultBranch main
}

dev_run_github() {
  if sys_cmd gh_status gh auth status >/dev/null; then
    ui_ok "gh is already signed in."
    return 0
  fi
  ui_note "gh signs in with a one-time device code in your browser and stores its own credential; this tool never sees it."
  run gh auth login
  if ui_yesno "Let git use gh for HTTPS credentials?" y; then
    run gh auth setup-git
  fi
}

dev_run_ssh() {
  local key="$HOME/.ssh/id_ed25519" email
  if [ -f "$key" ]; then
    ui_ok "SSH key present: $(tildify "$key").pub"
  elif ui_yesno "Generate an ed25519 SSH key?" y; then
    email=$(sys_cmd git_email git config --global user.email)
    ui_note "ssh-keygen asks for an optional passphrase itself."
    run ssh-keygen -t ed25519 -C "${email:-${CFG_user:-$LX_USER}@${CFG_host:-omarchy}}" -f "$key"
  fi
  if [ -f "$key.pub" ] && sys_cmd gh_status gh auth status >/dev/null && ui_yesno "Add the public key to your GitHub account?" n; then
    run gh ssh-key add "$key.pub" --title "${CFG_host:-omarchy}"
  fi
  if [ "$(sys_cmd sshd_active systemctl is-active sshd)" = active ]; then
    ui_ok "sshd is running."
    return 0
  fi
  ui_note "Omarchy's firewall blocks port 22 until SSH is enabled deliberately. omarchy-setup-security-sshd enables sshd, opens the port with rate limiting, and offers to fetch public keys from github.com/<user>.keys${CFG_gh:+ — you planned $CFG_gh}."
  if ui_yesno "Enable SSH access to this machine?" "$([ "${CFG_ssh:-0}" = 1 ] && echo y || echo n)"; then
    if sys_has omarchy-setup-security-sshd; then
      run omarchy-setup-security-sshd
    else
      ui_warn "omarchy-setup-security-sshd not found."
    fi
  fi
}

dev_run_ai() {
  ui_note "Asahi kernels use ${LX_PAGESIZE:-16384}-byte pages. After installing, confirm each CLI starts (claude --version, codex --version)."
  ui_multiselect "Which CLIs?" \
    "Claude Code|$(sys_has claude && echo installed || echo "native arm64 installer from claude.ai")|off" \
    "Codex|$(sys_has codex && echo installed || echo "npm $CODEX_NPM_PACKAGE (needs node)")|off" || return 0
  local n
  for n in $UI_PICKED; do
    case "$n" in
      1)
        if sys_has claude; then
          ui_ok "Claude Code is already installed."
          continue
        fi
        fetch_upstream claude-code-install.sh "$CLAUDE_CODE_INSTALL_URL" || {
          ui_fail "Download failed: $CLAUDE_CODE_INSTALL_URL"
          continue
        }
        ui_kv "URL" "$FETCH_URL"
        ui_kv "SHA-256" "$FETCH_SHA256"
        ui_kv "Saved to" "$(tildify "$FETCH_PATH")"
        state_set claude_install_sha256 "$FETCH_SHA256"
        offer_inspection || continue
        ui_yesno "Run the Claude Code installer?" n && fetch_unchanged && run bash "$FETCH_PATH"
        ;;
      2)
        if sys_has codex; then
          ui_ok "Codex is already installed."
        elif sys_has npm; then
          run npm install -g "$CODEX_NPM_PACKAGE"
        else
          ui_warn "npm not found. Install node first (Languages → node), then rerun."
        fi
        ;;
    esac
  done
}

dev_run_time() {
  if [ -n "${CFG_tz:-}" ] && [ "${LX_TZ:-}" != "$CFG_tz" ]; then
    ui_kv "Timezone" "${LX_TZ:-unset} $G_ARROW $CFG_tz"
    ui_yesno "Set the timezone to $CFG_tz?" y && run sudo timedatectl set-timezone "$CFG_tz"
  else
    ui_ok "Timezone ${LX_TZ:-unset}."
  fi
  if [ -n "${CFG_loc:-}" ] && [ "${LX_LANG:-}" != "$CFG_loc" ]; then
    if sys_cmd locales localectl list-locales | grep -qx "$CFG_loc"; then
      ui_yesno "Set the system locale to $CFG_loc?" y && run sudo localectl set-locale "LANG=$CFG_loc"
    else
      ui_warn "$CFG_loc is not generated on this system."
      ui_note "Uncomment it in /etc/locale.gen, run sudo locale-gen, then rerun this module."
    fi
  else
    ui_ok "Locale ${LX_LANG:-unset}."
  fi
}
