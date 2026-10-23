#!/usr/bin/env bash
# The scanner (lib/migrate_scan.sh; docs/MIGRATION.md → *The scanner*,
# docs/RESOLVER.md → *From Zsh to Bash*): no inventoried tool runs and
# nothing is sourced; unknown, partial and denied stay visible; only Zsh's
# literal aliases and allowlisted exports become Bash; a Stow root is
# followed once. Every macOS fixture is read through plutil, so each section
# that scans one is gated on it.
# shellcheck disable=SC2015,SC2016,SC2030,SC2031 # ok/fail always return 0; literal $ in expected text; subshell locals on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-scan"

T=$(t_tmp)
# The tools a scan inventories, as shims that record and fail: none may run.
INVENTORIED="brew npm npx cargo uv go mise claude codex opencode pnpm bun pipx gem pip pip3 node python3 code cursor nvim tmux starship ghostty zsh dscl"
SHIMS=$(t_shims "$T")
for name in $INVENTORIED; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "$(basename "$0")" "$*" >>"${SHIM_LOG:-/dev/null}"\nexit 97\n' >"$SHIMS/$name"
  chmod +x "$SHIMS/$name"
done

# s_scan FIXTURE OUT [VAR=VALUE...] — the library's scan_run over FIXTURE,
# in a shell of its own, with the inventoried tools' shims first on PATH.
s_scan() {
  local fx=$1 out=$2
  shift 2
  (
    t_load >/dev/null 2>&1
    . "$REPO/lib/records.sh" && . "$REPO/lib/toml.sh" && . "$REPO/lib/migrate_scan.sh"
    PATH="$SHIMS:$PATH" SHIM_LOG=$T/inv.log OMB_FIXTURE=$fx
    for a in "$@"; do eval "$a"; done
    scan_run "$out"
    st=$?
    omb_cleanup
    exit "$st"
  )
}

# s_extract FIXTURE ID DIR — scan_extract in a shell of its own.
s_extract() {
  (
    t_load >/dev/null 2>&1
    . "$REPO/lib/records.sh" && . "$REPO/lib/toml.sh" && . "$REPO/lib/migrate_scan.sh"
    PATH="$SHIMS:$PATH" SHIM_LOG=$T/inv.log OMB_FIXTURE=$1
    scan_extract "$2" "$3"
    st=$?
    omb_cleanup
    exit "$st"
  )
}

# field ID KEY FILE — an item's field, as written.
field() { awk -F '\t' -v id="id=$1" -v k="$2=" '$2 == id { for (i = 3; i <= NF; i++) if (index($i, k) == 1) print substr($i, length(k) + 1) }' "$3"; }
adapter() { awk -F '\t' -v id="id=$1" '$1 == "adapter" && $2 == id { sub(/^state=/, "", $3); print $3 }' "$2"; }

: >"$T/inv.log"

if t_plutil "the scan of a fixture home"; then
  # scan-nothing-runs: `scan` reads and prints; no inventoried tool runs, no
  # shell file is sourced, no hook or notifier starts, nothing is written.
  F=$(t_variant mig-mac-home)
  T_ENV="PATH=$SHIMS:/usr/bin:/bin:/usr/sbin:/sbin SHIM_LOG=$T/inv.log" t_cli "$F" "" scan
  assert_rc "$T_RC" 0 "scan-nothing-runs: scan completes"
  assert_empty_file "$T/inv.log" "scan-nothing-runs: an inventoried tool ran"
  assert_empty_file "$T_DIR/record" "scan-nothing-runs: scan recorded a command"
  for m in omb-sourced-zshrc omb-hook-ran omb-statusline-ran omb-notify-ran; do
    if [ -e "$T_DIR/home/$m" ] || [ -e "$F/root/Users/alex/$m" ]; then fail "scan-nothing-runs: $m exists: something was sourced or run"; else ok; fi
  done
  assert_eq "$(ls -A "$T_DIR/state" 2>/dev/null)" "" "scan-nothing-runs: scan writes no state, log or profile"
  assert_eq "$(ls -A "$T_DIR/tmp")" "" "scan-nothing-runs: its scratch goes when it ends"
  assert_contains "$T_OUT" "ripgrep 14.1.1" "scan-nothing-runs: the inventory is printed"
  assert_contains "$T_OUT" "receipt names a tap that is missing" "scan-nothing-runs: what is unknown is printed as unknown"

  # scan-inventory: what each adapter reads, and its evidence.
  s_scan "$F" "$T/inv"
  assert_rc $? 0 "scan-inventory: scan_run completes"
  assert_empty_file "$T/inv.log" "scan-inventory: an inventoried tool ran"
  assert_eq "$(awk -F '\t' '$1 == "adapter" { printf "%s ", $2 }' "$T/inv")" \
    "id=homebrew id=apps id=languages id=editors id=shell id=terminal id=git id=ai id=folders " "scan-inventory: one adapter record each, in order"
  assert_eq "$(field brew:ripgrep requested "$T/inv") $(field brew:ripgrep evidence "$T/inv") $(field brew:ripgrep version "$T/inv")" "yes observed 14.1.1" \
    "scan-inventory: a requested formula, its version by its opt link"
  assert_eq "$(field brew:pcre2 requested "$T/inv")" "no" "scan-inventory: a dependency is requested=no"
  assert_eq "$(field brew:mystery requested "$T/inv")" "unknown" "scan-unknown: no receipt is requested=unknown, never a guess"
  assert_eq "$(field brew:oddtool evidence "$T/inv")" "unknown" "scan-unknown: a receipt naming a missing tap is unknown"
  assert_eq "$(field cask:gone-app evidence "$T/inv")" "unknown" "scan-unknown: a cask whose app is gone is unknown"
  assert_eq "$(field app:path:Broken evidence "$T/inv")" "unknown" "scan-unknown: an app whose Info.plist cannot be read is unknown"
  assert_contains "$(field brew:postgresql@16 note "$T/inv")" "whether%20it%20runs%20is%20unknown" "scan-inventory: a service is a flag; whether it runs is unknown"
  assert_eq "$(field app:com.mitchellh.ghostty kind "$T/inv")" "" "scan-inventory: a cask and the app it installed are one item"
  assert_eq "$(field app:com.apple.Safari class "$T/inv")" "mac-only" "scan-inventory: Apple's own applications are mac-only"
  assert_eq "$(field app:com.apple.dt.Xcode source "$T/inv")" "App%20Store" "scan-inventory: an App Store receipt is read"
  for id in npm:typescript npm:@scope/tool nvm:node@20.11 cargo:ripgrep uv:ruff go:golang.org/x/tools/gopls mise:python@3.12 mise:python@3.11 asdf:ruby@3.3 \
    vscode:ext:ms-python.python nvim:config shell:bash ghostty:config starship:config git:config ssh:config claude:settings claude:mcp:context7 \
    claude:plugins codex:config opencode:config path:.agents/skills/notes project:code/app path:.config/stowed path:Documents; do
    [ -n "$(field "$id" kind "$T/inv")" ] && ok || fail "scan-inventory: no item $id"
  done
  assert_eq "$(field npm:npm kind "$T/inv")" "" "scan-inventory: npm itself is not a global package"
  assert_eq "$(field path:.Trash kind "$T/inv")" "" "scan-inventory: the Trash is never offered"
  assert_eq "$(field path:Documents evidence "$T/inv") $(field path:Documents size "$T/inv")" "unknown " "scan-unknown: a protected folder is not read: its size is unknown"
  assert_eq "$(field claude:sessions class "$T/inv")" "mac-only" "scan-inventory: sessions are listed, never carried (D41)"
  assert_eq "$(field path:.ssh/id_ed25519 kind "$T/inv") $(field path:.ssh/id_ed25519 source "$T/inv") $(field path:.ssh/id_ed25519 version "$T/inv")" \
    "key-encrypted aes256-ctr 16" "scan-inventory: an encrypted key's envelope: cipher and rounds"
  assert_contains "$(field project:code/app note "$T/inv")" "remote%20https://github.com/example/app.git" "scan-inventory: a project is its remote and branch"
  if grep -q 'FIXTURE PRIVATE SECTION\|b3BlbnNzaC1rZXkt' "$T/inv"; then fail "scan-inventory: a key's bytes reached the inventory"; else ok; fi

  # scan-rerun: the same machine, the same inventory, byte for byte.
  s_scan "$F" "$T/inv2"
  if cmp -s "$T/inv" "$T/inv2"; then ok; else fail "scan-rerun: a second scan of the same home differs"; fi

  # scan-partial: a budget that runs out is partial, never a short complete list.
  s_scan "$F" "$T/inv3" SCAN_LIST_MAX=2
  assert_eq "$(adapter homebrew "$T/inv3")" partial "scan-partial: the formulae past the budget make Homebrew partial"
  # scan-denied: a folder macOS will not let us read is denied; a chosen
  # folder is read only when it is carried, and says so then.
  chmod 000 "$F/root/opt/homebrew/Cellar" "$F/root/Users/alex/.myscripts"
  s_scan "$F" "$T/inv4"
  s_extract "$F" path:.myscripts "$T/x-denied"
  chmod 755 "$F/root/opt/homebrew/Cellar" "$F/root/Users/alex/.myscripts"
  if [ "$(id -u)" = 0 ]; then
    skip "scan-denied: root reads a folder of mode 000"
  else
    assert_eq "$(adapter homebrew "$T/inv4")" denied "scan-denied: an unreadable Cellar makes Homebrew denied"
    assert_contains "$(cat "$T/x-denied/carry")" "some%20entries%20could%20not%20be%20read%20%28denied%29" "scan-denied: an unreadable chosen folder says so when it is carried"
  fi

  # scan-discovery-unread (S7): discovery reads no chosen folder before it is
  # chosen, and reports a link by its text without following it, a link into
  # a protected folder included (here also unreadable: following it would
  # show as denied).
  ln -s Documents "$F/root/Users/alex/.notes"
  chmod 000 "$F/root/Users/alex/Documents"
  s_scan "$F" "$T/inv6"
  chmod 755 "$F/root/Users/alex/Documents"
  assert_eq "$(field path:.notes kind "$T/inv6") $(field path:.notes size "$T/inv6") $(field path:.notes evidence "$T/inv6")" "link  observed" \
    "scan-discovery-unread: a link is reported as a link, never followed"
  assert_contains "$(field path:.notes note "$T/inv6")" "a%20link%20to%20Documents:%20followed%20once,%20and%20only%20if%20it%20is%20chosen" "scan-discovery-unread: with its target"
  assert_eq "$(field path:.myscripts kind "$T/inv6") $(field path:.myscripts size "$T/inv6")" "folder " "scan-discovery-unread: a folder is listed by its name, its contents unread"
  assert_eq "$(field path:.config/stowed kind "$T/inv6")" "link" "scan-discovery-unread: a Stow root is a link until it is chosen"
  rm -f "$F/root/Users/alex/.notes"
  # scan-skipped: nothing there is skipped, with the reason.
  s_scan "$FIX/mac-m1pro-1tb-roomy" "$T/inv5"
  assert_eq "$(adapter homebrew "$T/inv5") $(adapter ai "$T/inv5") $(adapter shell "$T/inv5")" "skipped skipped skipped" "scan-skipped: a Mac with nothing installed"

  # scan-zsh: only literal aliases and allowlisted exports become Bash.
  s_extract "$F" shell:bash "$T/x-shell"
  assert_rc $? 0 "scan-zsh: shell.bash is made"
  src=$(awk -F '\t' '$1 == "file" { sub(/^src=/, "", $3); print $3 }' "$T/x-shell/carry")
  assert_eq "$(cat "$T/x-shell/$src")" '# Made by omarchy-mac-bootstrap from the Zsh files on macOS: literal
# aliases and allowlisted exports only. Nothing else was carried; the
# Zsh files themselves are in ~/.config/omarchy-mac-bootstrap/zsh/.
export PAGER='"'"'less'"'"'
export VISUAL='"'"'nvim'"'"'
export EDITOR='"'"'nvim'"'"'
export LESS='"'"'-R'"'"'
export BAT_THEME='"'"'Dracula'"'"'
export HISTSIZE='"'"'10000'"'"'
export RIPGREP_CONFIG_PATH="$HOME/.config/ripgrep/rc"
alias gs='"'"'git status'"'"'
alias ll='"'"'ls -la'"'"'
alias cpwd='"'"'pwd | wl-copy'"'"'
alias after_heredoc='"'"'echo after'"'"'' \
    "scan-zsh: shell.bash holds exactly the literal aliases and allowlisted exports, macOS commands replaced"
  /bin/bash -n "$T/x-shell/$src"
  assert_rc $? 0 "scan-zsh: shell.bash is Bash"
  for no in inside_if inside_fn inside_heredoc greet plain 'alias G' "alias ls" 'export PATH' HOMEBREW NOTES_DIR touch source setopt; do
    assert_not_contains "$(cat "$T/x-shell/$src")" "$no" "scan-zsh: not carried: $no"
  done
  assert_eq "$(awk -F '\t' '$1 == "file" { print $2 }' "$T/x-shell/carry")" "dest=.config/omarchy-mac-bootstrap/shell.bash" "scan-zsh: shell.bash goes where Linux sources it from"
  s_extract "$F" path:.zshrc "$T/x-rc"
  assert_contains "$(cat "$T/x-rc/carry")" "dest=.config/omarchy-mac-bootstrap/zsh/.zshrc" "scan-zsh: the rc file travels as a reference copy nothing sources"

  # scan-stow: a chosen folder whose root is a link is followed once; a link
  # inside stays only when it stays inside the item.
  s_extract "$F" path:.config/stowed "$T/x-stow"
  carry=$(cat "$T/x-stow/carry")
  assert_contains "$carry" "file	dest=.config/stowed/conf.ini	src=f/1	mode=0600	whole=1" "scan-stow: the folder it names is carried at the chosen path"
  assert_contains "$carry" "link	dest=.config/stowed/rel-link	target=conf.ini" "scan-stow: a link inside the item stays a link"
  assert_contains "$carry" "out-link:%20a%20link%20whose%20target%20is%20outside%20the%20item" "scan-stow: a link out of the item is skipped, with the reason"
  ln -s stowed "$F/root/Users/alex/.config/chain"
  s_extract "$F" path:.config/chain "$T/x-chain"
  assert_contains "$(cat "$T/x-chain/carry")" "a%20link%20to%20a%20link,%20not%20followed" "scan-stow: a root link is followed once, never twice"
  s_extract "$F" path:.config/gone "$T/x-gone"
  assert_rc $? 1 "scan-stow: an item no longer found answers 1"
  assert_empty_file "$T/inv.log" "scan-extract: an inventoried tool ran"
  rm -rf "$F"
fi

rm -rf "$T"
t_done test-scan
