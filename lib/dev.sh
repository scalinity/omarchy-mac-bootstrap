# shellcheck shell=bash
# Optional developer setup, after Omarchy. Modular and rerunnable; nothing is
# installed without being selected. Where Omarchy ships a command for a job
# (omarchy-install-dev-env, omarchy-install-editor-vscode,
# omarchy-setup-security-sshd, omarchy-pkg-add), that command does it.
#
# Every module ends with one outcome — success, failed, skipped, cancelled or
# already-satisfied — decided by checking the machine afterwards, not by an
# exit status alone: some of those helpers exit 0 without having installed
# anything (a package unavailable for aarch64 is skipped, a failed download
# can look like success). Only success is timestamped; any failure makes the
# run exit non-zero.

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

# dev_tool_present NAME — on PATH, or where rustup and mise put it (a fresh
# install is not on this process's PATH yet).
dev_tool_present() {
  sys_has "$1" && return 0
  [ -n "${OMB_FIXTURE:-}" ] && return 1
  [ -x "$HOME/.cargo/bin/$1" ] || [ -x "$HOME/.local/share/mise/shims/$1" ] || [ -x "$HOME/.local/bin/$1" ]
}

# --- Outcomes ------------------------------------------------------------------
# A module calls exactly one of these last. DEV_FAILS collects the failures
# of a module with several parts, so one failing part never reads as success.
dev_begin() { DEV_OUTCOME="" DEV_DETAIL="" DEV_FAILS="" DEV_DONE_PARTS=""; }
dev_ok() { DEV_OUTCOME=success DEV_DETAIL=${1:-}; }
dev_fail() { DEV_OUTCOME=failed DEV_DETAIL=$1; }
dev_skip() { DEV_OUTCOME=skipped DEV_DETAIL=${1:-}; }
dev_cancel() { DEV_OUTCOME=cancelled DEV_DETAIL=${1:-}; }
dev_satisfied() { DEV_OUTCOME=already-satisfied DEV_DETAIL=${1:-}; }
dev_part_fail() { DEV_FAILS="$DEV_FAILS${DEV_FAILS:+; }$1"; }
dev_part_ok() { DEV_DONE_PARTS="$DEV_DONE_PARTS${DEV_DONE_PARTS:+, }$1"; }
# dev_parts_finish — the outcome of a module made of parts.
dev_parts_finish() {
  if [ -n "$DEV_FAILS" ]; then
    dev_fail "$DEV_FAILS"
  elif [ -n "$DEV_DONE_PARTS" ]; then
    dev_ok "$DEV_DONE_PARTS"
  else
    dev_skip "${1:-nothing to do}"
  fi
}
# dev_verifying — can the result be checked? Not in a dry run, where nothing
# ran; a test supplies the machine afterwards with OMB_TEST_AFTER.
dev_verifying() {
  [ "$OMB_DRY_RUN" = 1 ] && return 1
  [ -n "${OMB_TEST_RECORD:-}" ] && [ -z "${OMB_TEST_AFTER:-}" ] && return 1
  return 0
}

# dev_ssh_facts — the separate facts that make SSH access work:
# DEV_SSH_KEY, DEV_SSH_INSTALLED, DEV_SSH_ACTIVE, DEV_SSH_LISTENING,
# DEV_SSH_AUTHORIZED (0/1). The firewall is only readable as root.
dev_ssh_facts() {
  DEV_SSH_KEY=0 DEV_SSH_INSTALLED=0 DEV_SSH_ACTIVE=0 DEV_SSH_LISTENING=0 DEV_SSH_AUTHORIZED=0
  [ -f "$HOME/.ssh/id_ed25519" ] && DEV_SSH_KEY=1
  sys_has sshd && DEV_SSH_INSTALLED=1
  [ "$(sys_cmd sshd_active systemctl is-active sshd)" = active ] && DEV_SSH_ACTIVE=1
  sys_cmd ss_listen ss -Htln | awk '{print $4}' | grep -Eq '(^|:)22$' && DEV_SSH_LISTENING=1
  [ -s "$HOME/.ssh/authorized_keys" ] && DEV_SSH_AUTHORIZED=1
  return 0
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
      dev_tool_present cargo && DEV_S="${DEV_S}rust "
      dev_tool_present uv && DEV_S="${DEV_S}python "
      dev_tool_present node && DEV_S="${DEV_S}node "
      dev_tool_present go && DEV_S="${DEV_S}go "
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
      dev_ssh_facts
      DEV_S="key $([ "$DEV_SSH_KEY" = 1 ] && echo yes || echo no), sshd $([ "$DEV_SSH_ACTIVE" = 1 ] && echo on || echo off), port 22 $([ "$DEV_SSH_LISTENING" = 1 ] && echo open || echo closed), authorized keys $([ "$DEV_SSH_AUTHORIZED" = 1 ] && echo yes || echo no)"
      ;;
    ai)
      DEV_S=""
      dev_tool_present claude && DEV_S="claude "
      dev_tool_present codex && DEV_S="${DEV_S}codex"
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
  local results="" failed=0
  for m in $picked; do
    ui_section "$(dev_label "$m")"
    dev_begin
    "dev_run_$m"
    [ -n "$DEV_OUTCOME" ] || dev_fail "the module did not report an outcome"
    [ "$OMB_DRY_RUN" = 1 ] && [ "$DEV_OUTCOME" = success ] && DEV_OUTCOME=previewed
    case "$DEV_OUTCOME" in
      success) state_stamp "dev_${m}_at" ;;
      failed) failed=$((failed + 1)) ;;
    esac
    results="$results$m|$DEV_OUTCOME|$DEV_DETAIL
"
  done
  state_set dev_modules "${picked# }"
  if [ "$failed" = 0 ]; then
    state_stamp dev_last_run_at
    state_unset dev_failed
  else
    state_set dev_failed "$(printf '%s' "$results" | awk -F'|' '$2 == "failed" {printf "%s%s", sep, $1; sep=" "}')"
  fi
  dev_summary "$results" "$failed"
  [ "$failed" = 0 ]
}

# dev_summary RESULTS FAILED — one line per module, and what needs attention.
dev_summary() {
  local m outcome detail mark label word
  ui_section "Developer setup" "$([ "$OMB_DRY_RUN" = 1 ] && echo "dry run: nothing was changed" || echo "what happened")"
  while IFS='|' read -r m outcome detail; do
    [ -n "$m" ] || continue
    case "$outcome" in
      success) mark="$C_PASS$G_PASS$C_RESET" word=complete ;;
      already-satisfied) mark="$C_PASS$G_PASS$C_RESET" word="already set up" ;;
      previewed) mark="$C_INFO$G_INFO$C_RESET" word="previewed" ;;
      failed) mark="$C_FAIL$G_FAIL$C_RESET" word=failed ;;
      cancelled) mark="$C_WARN$G_WARN$C_RESET" word=cancelled ;;
      *) mark="$C_DIM$G_INFO$C_RESET" word=skipped ;;
    esac
    label=$(dev_label "$m")
    _p '   %-16s %s %-15s %s%s%s\n' "$label" "$mark" "$word" "$C_DIM" "$detail" "$C_RESET"
  done <<EOF
$1
EOF
  printf '\n'
  if [ "$2" -gt 0 ]; then
    ui_fail "$2 requested operation$([ "$2" = 1 ] || echo s) need$([ "$2" = 1 ] && echo s) attention. Rerun './omarchy-bootstrap dev' for just those once fixed."
  else
    ui_ok "Developer setup finished. Rerun './omarchy-bootstrap dev' any time."
  fi
  printf '\n'
}

# ---------------------------------------------------------------------------

dev_run_core() {
  local missing
  missing=$(dev_core_missing)
  if [ -z "$missing" ]; then
    ui_ok "All core tools are present."
    dev_satisfied "all present"
    return 0
  fi
  ui_kv "Installs" "$missing"
  # shellcheck disable=SC2086 # package list
  if ! pkg_add $missing; then
    dev_fail "package install failed"
    return 1
  fi
  if dev_verifying; then
    missing=$(dev_core_missing)
    if [ -n "$missing" ]; then
      dev_fail "still missing: $missing"
      return 1
    fi
  fi
  dev_ok "installed"
}

dev_run_languages() {
  if ! sys_has omarchy-install-dev-env; then
    ui_warn "omarchy-install-dev-env not found; install languages with mise directly."
    dev_fail "omarchy-install-dev-env not found"
    return 1
  fi
  ui_note "Uses Omarchy's omarchy-install-dev-env: rust via rustup, python via mise + uv, node and go via mise."
  ui_multiselect "Which toolchains?" \
    "rust|$(dev_tool_present cargo && echo installed || echo rustup)|off" \
    "python|$(dev_tool_present uv && echo installed || echo "mise + uv")|off" \
    "node|$(dev_tool_present node && echo installed || echo mise)|off" \
    "go|$(dev_tool_present go && echo installed || echo mise)|off" || {
    dev_cancel
    return 0
  }
  local n lang tool
  for n in $UI_PICKED; do
    case "$n" in 1) lang=rust tool=cargo ;; 2) lang=python tool=uv ;; 3) lang=node tool=node ;; 4) lang=go tool=go ;; *) continue ;; esac
    if ! run omarchy-install-dev-env "$lang"; then
      dev_part_fail "$lang: the installer failed"
    elif dev_verifying && ! dev_tool_present "$tool"; then
      dev_part_fail "$lang: finished, but $tool is not installed"
    else
      dev_part_ok "$lang"
    fi
  done
  dev_parts_finish "no toolchain chosen"
  [ "$DEV_OUTCOME" != failed ]
}

dev_run_containers() {
  ui_kv "Docker" "Omarchy installs it; the daemon runs as root" "docker.socket enabled"
  ui_note "Omarchy deliberately does not add you to the docker group (that group is root-equivalent): use sudo docker, or opt in with omarchy-setup-security-sudoless-docker."
  ui_kv "Podman" "daemonless and rootless by default" "docker-compatible CLI"
  ui_note "Podman needs no root daemon and no group; some tools expect a Docker socket and need podman's socket service instead."
  ui_select "Container setup" 3 \
    "Docker|sudoless|opt in to running docker without sudo (root-equivalent)|" \
    "Podman|install|add podman and podman-compose alongside Docker|" \
    "Leave as is||Docker via sudo, as Omarchy ships it|" || {
    dev_cancel
    return 0
  }
  case "$UI_CHOICE" in
    1)
      if ! sys_has omarchy-setup-security-sudoless-docker; then
        ui_warn "omarchy-setup-security-sudoless-docker not found."
        dev_fail "omarchy-setup-security-sudoless-docker not found"
        return 1
      fi
      if ! run omarchy-setup-security-sudoless-docker; then
        dev_fail "the sudoless-docker helper failed"
        return 1
      fi
      dev_ok "sudoless docker (takes effect after a reboot)"
      ;;
    2)
      if ! pkg_add podman podman-compose; then
        dev_fail "package install failed"
        return 1
      fi
      if dev_verifying && ! sys_has podman; then
        dev_fail "podman is not installed after the install"
        return 1
      fi
      dev_ok "podman"
      ;;
    *)
      ui_info "Unchanged."
      dev_skip "left as Omarchy ships it"
      ;;
  esac
}

dev_run_editor() {
  ui_note "Neovim with LazyVim is Omarchy's default. VS Code comes from visual-studio-code-bin, which publishes aarch64 builds; omarchy-pkg-add skips it if the ARM build is unavailable."
  if sys_has code; then
    ui_ok "VS Code is already installed."
    dev_satisfied "VS Code present"
    return 0
  fi
  ui_yesno "Install VS Code?" n
  case $? in
    0) ;;
    3)
      dev_cancel
      return 0
      ;;
    *)
      dev_skip "Neovim only"
      return 0
      ;;
  esac
  if sys_has omarchy-install-editor-vscode; then
    run omarchy-install-editor-vscode || {
      dev_fail "the VS Code installer failed"
      return 1
    }
  else
    pkg_add visual-studio-code-bin || {
      dev_fail "package install failed"
      return 1
    }
  fi
  if dev_verifying && ! sys_has code; then
    dev_fail "VS Code is not installed afterwards (the aarch64 package may be unavailable)"
    return 1
  fi
  dev_ok "VS Code"
}

dev_run_git() {
  local name email
  ui_ask name "Git name" "$(sys_cmd git_name git config --global user.name)" || {
    dev_cancel
    return 0
  }
  ui_ask email "Git email" "$(sys_cmd git_email git config --global user.email)" || {
    dev_cancel
    return 0
  }
  if [ -n "$name" ]; then run git config --global user.name "$name" || dev_part_fail "user.name"; fi
  if [ -n "$email" ]; then run git config --global user.email "$email" || dev_part_fail "user.email"; fi
  run git config --global init.defaultBranch main || dev_part_fail "init.defaultBranch"
  if [ -n "$DEV_FAILS" ]; then
    dev_fail "git config failed: $DEV_FAILS"
    return 1
  fi
  dev_ok "${name:-identity unchanged}"
}

dev_run_github() {
  if sys_cmd gh_status gh auth status >/dev/null; then
    ui_ok "gh is already signed in."
    dev_satisfied "signed in"
    return 0
  fi
  ui_note "gh signs in with a one-time device code in your browser and stores its own credential; this tool never sees it."
  if ! run gh auth login; then
    dev_fail "authentication failed"
    return 1
  fi
  if dev_verifying && ! sys_cmd gh_status gh auth status >/dev/null; then
    dev_fail "gh auth login finished, but gh is not signed in"
    return 1
  fi
  ui_yesno "Let git use gh for HTTPS credentials?" y
  case $? in
    0) run gh auth setup-git || dev_part_fail "gh auth setup-git failed" ;;
  esac
  if [ -n "$DEV_FAILS" ]; then
    dev_fail "signed in; $DEV_FAILS"
    return 1
  fi
  dev_ok "signed in"
}

# SSH access is several separate things, and a running sshd is only one of
# them: omarchy-setup-security-sshd installs openssh, enables sshd, opens
# port 22 in ufw (rate-limited), authorizes keys, and turns password login
# off once a key is authorized. It runs whenever SSH access is chosen, even
# with sshd already running, and the result is checked afterwards.
dev_run_ssh() {
  local key="$HOME/.ssh/id_ed25519" email want
  dev_ssh_facts
  ui_kv "Your key" "$([ "$DEV_SSH_KEY" = 1 ] && echo "$(tildify "$key").pub" || echo none)"
  ui_kv "sshd" "$([ "$DEV_SSH_INSTALLED" = 1 ] && echo installed || echo "not installed")$([ "$DEV_SSH_ACTIVE" = 1 ] && echo ", running")"
  ui_kv "Port 22" "$([ "$DEV_SSH_LISTENING" = 1 ] && echo listening || echo "not listening")" "the firewall is checked by the helper, as root"
  ui_kv "Authorized keys" "$([ "$DEV_SSH_AUTHORIZED" = 1 ] && echo present || echo none)" "$(tildify "$HOME/.ssh/authorized_keys")"
  if [ "$DEV_SSH_KEY" = 0 ]; then
    ui_yesno "Generate an ed25519 SSH key?" y
    case $? in
      0)
        email=$(sys_cmd git_email git config --global user.email)
        ui_note "ssh-keygen asks for an optional passphrase itself."
        if run ssh-keygen -t ed25519 -C "${email:-${CFG_user:-$LX_USER}@${CFG_host:-omarchy}}" -f "$key"; then
          dev_part_ok "key generated"
        else
          dev_part_fail "ssh-keygen failed"
        fi
        ;;
      3)
        dev_cancel
        return 0
        ;;
    esac
  fi
  if [ -f "$key.pub" ] && sys_cmd gh_status gh auth status >/dev/null; then
    if ui_yesno "Add the public key to your GitHub account?" n; then
      if run gh ssh-key add "$key.pub" --title "${CFG_host:-omarchy}"; then dev_part_ok "key added to GitHub"; else dev_part_fail "gh ssh-key add failed"; fi
    fi
  fi
  ui_note "Enabling SSH access runs omarchy-setup-security-sshd: it enables sshd, opens port 22 with rate limiting, offers to fetch public keys from github.com/<user>.keys${CFG_gh:+ (you planned $CFG_gh)}, and turns password login off once a key is authorized. It runs even when sshd is already on, because the firewall and keys are separate from the service."
  want=n
  [ "${CFG_ssh:-0}" = 1 ] && want=y
  ui_yesno "Set up SSH access to this machine?" "$want"
  case $? in
    0)
      if ! sys_has omarchy-setup-security-sshd; then
        dev_part_fail "omarchy-setup-security-sshd not found"
      elif ! run omarchy-setup-security-sshd; then
        dev_part_fail "the SSH helper failed"
      elif dev_verifying; then
        dev_ssh_facts
        [ "$DEV_SSH_ACTIVE" = 1 ] || dev_part_fail "sshd is not running"
        [ "$DEV_SSH_LISTENING" = 1 ] || dev_part_fail "nothing listens on port 22"
        [ "$DEV_SSH_AUTHORIZED" = 1 ] || dev_part_fail "no authorized keys"
        [ -n "$DEV_FAILS" ] || dev_part_ok "configured"
      else
        dev_part_ok "configured"
      fi
      ;;
    3)
      dev_cancel
      return 0
      ;;
  esac
  dev_parts_finish "SSH left as it is"
  [ "$DEV_OUTCOME" != failed ]
}

dev_run_ai() {
  ui_note "Asahi kernels use ${LX_PAGESIZE:-16384}-byte pages. After installing, confirm each CLI starts (claude --version, codex --version)."
  ui_multiselect "Which CLIs?" \
    "Claude Code|$(dev_tool_present claude && echo installed || echo "native arm64 installer from claude.ai")|off" \
    "Codex|$(dev_tool_present codex && echo installed || echo "npm $CODEX_NPM_PACKAGE (needs node)")|off" || {
    dev_cancel
    return 0
  }
  local n
  for n in $UI_PICKED; do
    case "$n" in
      1) dev_ai_claude ;;
      2) dev_ai_codex ;;
    esac
  done
  dev_parts_finish "no CLI chosen"
  [ "$DEV_OUTCOME" != failed ]
}

dev_ai_claude() {
  if dev_tool_present claude; then
    ui_ok "Claude Code is already installed."
    dev_part_ok "Claude Code present"
    return 0
  fi
  if ! fetch_upstream claude-code-install.sh "$CLAUDE_CODE_INSTALL_URL"; then
    ui_fail "Download failed: $CLAUDE_CODE_INSTALL_URL"
    dev_part_fail "Claude Code: download failed"
    return 0
  fi
  show_provenance
  state_set claude_install_sha256 "$FETCH_SHA256"
  offer_inspection || return 0
  ui_yesno "Run the Claude Code installer?" n || return 0
  fetch_unchanged || {
    dev_part_fail "Claude Code: the download changed before running"
    return 0
  }
  if ! run bash "$FETCH_PATH"; then
    dev_part_fail "Claude Code install failed"
  elif dev_verifying && ! dev_tool_present claude; then
    dev_part_fail "Claude Code: installer finished, but claude is not installed"
  else
    dev_part_ok "Claude Code"
  fi
}

dev_ai_codex() {
  if dev_tool_present codex; then
    ui_ok "Codex is already installed."
    dev_part_ok "Codex present"
  elif ! sys_has npm; then
    ui_warn "npm not found. Install node first (Languages → node), then rerun."
    dev_part_fail "Codex: npm not found (install node first)"
  elif ! run npm install -g "$CODEX_NPM_PACKAGE"; then
    dev_part_fail "Codex install failed"
  elif dev_verifying && ! dev_tool_present codex; then
    dev_part_fail "Codex: npm finished, but codex is not installed"
  else
    dev_part_ok "Codex"
  fi
}

dev_run_time() {
  if [ -n "${CFG_tz:-}" ] && [ "${LX_TZ:-}" != "$CFG_tz" ]; then
    ui_kv "Timezone" "${LX_TZ:-unset} $G_ARROW $CFG_tz"
    if ui_yesno "Set the timezone to $CFG_tz?" y; then
      if run sudo timedatectl set-timezone "$CFG_tz"; then dev_part_ok "timezone $CFG_tz"; else dev_part_fail "timedatectl failed"; fi
    fi
  else
    ui_ok "Timezone ${LX_TZ:-unset}."
  fi
  if [ -n "${CFG_loc:-}" ] && [ "${LX_LANG:-}" != "$CFG_loc" ]; then
    if sys_cmd locales localectl list-locales | grep -qx "$CFG_loc"; then
      if ui_yesno "Set the system locale to $CFG_loc?" y; then
        if run sudo localectl set-locale "LANG=$CFG_loc"; then dev_part_ok "locale $CFG_loc"; else dev_part_fail "localectl failed"; fi
      fi
    else
      ui_warn "$CFG_loc is not generated on this system."
      ui_note "Uncomment it in /etc/locale.gen, run sudo locale-gen, then rerun this module."
      dev_part_fail "$CFG_loc is not generated"
    fi
  else
    ui_ok "Locale ${LX_LANG:-unset}."
  fi
  if [ -z "$DEV_FAILS$DEV_DONE_PARTS" ] && [ "${LX_TZ:-}" = "${CFG_tz:-$LX_TZ}" ] && [ "${LX_LANG:-}" = "${CFG_loc:-$LX_LANG}" ]; then
    dev_satisfied "${LX_TZ:-?} $G_DOT ${LX_LANG:-?}"
    return 0
  fi
  dev_parts_finish "left as they are"
  [ "$DEV_OUTCOME" != failed ]
}
