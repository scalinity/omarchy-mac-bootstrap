#!/usr/bin/env bash
# Classification, the hard refusals and the credential scan, the profile's
# side (docs/MIGRATION.md → *Sensitivity: what may travel*; D23, D40): no
# planted secret in the profile, state or log, nor in anything an item
# carries; the kind named, never the value; `opaque` once per save; an
# encrypted SSH key only after `carry`; UseKeychain dropped. The planted
# values (tests/fixtures/gen-migrate.sh) all hold "FIXTUREplanted".
# shellcheck disable=SC2015,SC2016,SC2030,SC2031 # ok/fail always return 0; literal $ in stand-in source; subshell locals on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load
# shellcheck source=lib/records.sh
. "$REPO/lib/records.sh"
# shellcheck source=lib/toml.sh
. "$REPO/lib/toml.sh"
# shellcheck source=lib/migrate_scan.sh
. "$REPO/lib/migrate_scan.sh"
echo "test-secrets"

T=$(t_tmp)
S=$FIX/mig-mac-secrets/root/Users/alex
PLANT=FIXTUREplanted

# --- secret-kind: the scan names the kind, never the value (no plutil) -------
check() { # FILE KIND
  scan_secret_check "$1"
  assert_eq "$? $SCAN_HIT" "1 $2" "secret-kind: ${1#"$S"/} is found as $2"
  assert_not_contains "$SCAN_HIT" "$PLANT" "secret-kind: the value is never named (${1#"$S"/})"
}
check "$S/.zshrc" "an API key (sk-)"
check "$S/.myscripts/deploy.sh" "a GitHub token"
check "$S/.config/nvim/lua/secret.lua" "a Google API key"
check "$S/.claude/settings.json" "an Anthropic API key"
check "$S/.env" "a credential assignment"
check "$S/.npmrc" "a credential assignment"
check "$S/.aws/credentials" "an AWS access key"
check "$S/.ssh/id_plain" "a private key"
printf 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJGSVhUVVJFcGxhbnRlZCJ9.c2lnbmF0dXJlRklYVFVSRXBsYW50ZWQ\n' >"$T/jwt"
check "$T/jwt" "a JSON Web Token"
printf 'xoxb-FIXTUREplanted-0001\n' >"$T/slack"
check "$T/slack" "a Slack token"
# secret-shape-line-start (S5): the 20-byte AKIA and 39-byte AIza shapes,
# at the start of a line and alone on it, are found.
printf 'AKIAFIXTUREPLANTED01\n' >"$T/aws-alone"
check "$T/aws-alone" "an AWS access key"
printf 'AKIAFIXTUREPLANTED01 is the id\n' >"$T/aws-start"
check "$T/aws-start" "an AWS access key"
printf 'AIzaFIXTUREplantedGOOGLEkey000000000000\n' >"$T/google-alone"
check "$T/google-alone" "a Google API key"
printf 'AIzaFIXTUREplantedGOOGLEkey000000000000, the key\n' >"$T/google-start"
check "$T/google-start" "a Google API key"
# The whole length: a credential past a long clean prefix is still found.
awk 'BEGIN { for (i = 0; i < 50000; i++) print "clean line " i; print "token = \"ghp_FIXTUREplantedLATEtoken000000000001\"" }' >"$T/long"
check "$T/long" "a GitHub token"
for f in "$FIX/mig-mac-home/root/Users/alex/.zshrc" "$FIX/mig-mac-home/root/Users/alex/.claude/settings.json" "$FIX/mig-mac-home/root/Users/alex/.config/nvim/init.lua"; do
  scan_secret_check "$f"
  assert_rc $? 0 "secret-kind: a clean file passes (${f##*/alex/})"
done
printf 'export X=${ANTHROPIC_API_KEY}\napi_key = "{env:OPENAI_API_KEY}"\nkey = "ctrl+shift+alt+cmd+k"\n' >"$T/refs"
scan_secret_check "$T/refs"
assert_rc $? 0 "secret-kind: a variable reference is not a credential"
SCAN_HOME=/Users/alex
for rel in .env .env.local .envrc .netrc .ssh/id_rsa .aws/config .docker/config.json .kube/config .gnupg/private-keys-v1.d/x.key \
  .config/gh/hosts.yml .codex/auth.json server.pem cert.p12 .git-credentials; do
  scan_refused "$rel"
  assert_rc $? 0 "secret-refused: $rel is refused by its path"
done
scan_refused .ssh/id_rsa.pub
assert_rc $? 1 "secret-refused: a public key is not"
# secret-refused-env (S8): every name that starts with .env.
for rel in .env-production .envrc.local .myscripts/.envfile .env_prod; do
  scan_refused "$rel"
  assert_eq "$? $SCAN_HIT" "0 an environment file (.env)" "secret-refused-env: $rel is refused by its path"
done

# --- secret-args (S3) and secret-url (S4): command arguments and URLs (no plutil)
for a in --key=harborpassKEY1 --auth=harborpassAUTH1 --API-KEY=harborpassKEY2 --access-token=harborpassTOK1 \
  'https://example.test/mcp?token=harborpassURL1'; do
  _scan_arg_ok -y "$a"
  assert_rc $? 1 "secret-args: $a never travels"
done
_scan_arg_ok --root /Users/alex/code
assert_rc $? 0 "secret-args: an ordinary argument travels"
_scan_arg_ok -y https://docs.example.test/mcp
assert_rc $? 0 "secret-args: a URL without a credential travels"
for u in 'https://example.test/repo?%74oken=harborpass' 'https://example.test/repo?%54OKEN=harborpass' \
  'https://bucket.example.test/f?X-Amz-Signature=0a1b2charborpass' 'https://bucket.example.test/f?X-Amz-Credential=AKIDharborpass' \
  'https://example.test/cb#access_token=harborpass' 'https://alex:harborpass@example.test/repo.git' 'https://example.test/r?a=1&Sig=harborpass'; do
  _scan_url_ok "$u"
  assert_rc $? 1 "secret-url: $u is refused"
done
for u in https://github.com/example/app.git 'https://example.test/search?q=docs&page=2' git@github.com:example/app.git; do
  _scan_url_ok "$u"
  assert_rc $? 0 "secret-url: $u passes"
done
# secret-args-embedded-url: a URL is held to the rule wherever it starts in
# an argument, the VALUE of FLAG=VALUE included.
for a in --url=https://alice:harborpassEMB1@example.test/r 'mirror=https://bob:harborpassEMB2@example.test/x' \
  'see:https://example.test/r?%74oken=harborpassEMB3' --endpoint=https://example.test/r#access_token=harborpassEMB4; do
  _scan_arg_ok -y "$a"
  assert_rc $? 1 "secret-args-embedded-url: $a never travels"
done
_scan_arg_ok -y --url=https://docs.example.test/mcp
assert_rc $? 0 "secret-args-embedded-url: a URL without a credential in FLAG=VALUE travels"
# Codex's conversion holds its arguments and URLs to the same rules.
CX=$(t_variant mig-mac-home)
cat >"$CX/root/Users/alex/.codex/config.toml" <<'EOF'
[mcp_servers.svc]
command = "svc"
args = ["--key=harborpassKEY3", "--auth=harborpassAUTH3", "https://example.test/mcp?token=harborpassURL3", "--port", "8080"]

[mcp_servers.embedded]
command = "svc"
args = ["--url=https://alice:harborpassEMB5@example.test/r", "--port", "9090"]

[mcp_servers.remote]
url = "https://example.test/mcp?%74oken=harborpassURL5"

[model_providers.corp]
name = "Corp"
base_url = "https://api.example.test/v1?X-Amz-Signature=harborpassSIG1"
EOF
(
  OMB_FIXTURE=$CX
  scan_extract codex:config "$T/x-codex" >/dev/null 2>&1
  omb_cleanup
)
assert_eq "$(grep -rl harborpass "$T/x-codex")" "" "secret-args: no credential argument or URL in Codex's carried configuration"
src=$(awk -F '\t' '$1 == "file" { sub(/^src=/, "", $3); print $3 }' "$T/x-codex/carry")
assert_contains "$(cat "$T/x-codex/$src")" 'args = ["--port", "8080"]' "secret-args: Codex's other arguments stay"
assert_contains "$(cat "$T/x-codex/carry")" "codex%20mcp%20svc:%20needs-secret" "secret-args: and the server needs its secrets set again"
if grep -rq harborpassEMB "$T/x-codex"; then fail "secret-args-embedded-url: a URL inside FLAG=VALUE reached Codex's configuration"; else ok; fi
assert_contains "$(cat "$T/x-codex/$src")" 'args = ["--port", "9090"]' "secret-args-embedded-url: Codex keeps the rest"
# secret-args-control: decoded controls never reach an argument, URL or
# filtered configuration value, even when a URL parser would remove them.
for code in $(seq 1 31) 127; do
  printf -v oct '%03o' "$code"
  printf -v ctl '%b' "\\$oct"
  _scan_arg_ok -y "--url=https:${ctl}//alice:harborpassCTRL@example.test/r"
  assert_rc $? 1 "secret-args-control: argument control byte $code is refused"
  _scan_url_ok "https://alice:${ctl}harborpassCTRL@example.test/r"
  assert_rc $? 1 "secret-args-control: URL control byte $code is refused"
  scan_value_ok "value${ctl}harborpassCTRL"
  assert_rc $? 1 "secret-args-control: configuration control byte $code is refused"
done
cat >"$CX/root/Users/alex/.codex/config.toml" <<'EOF'
model = "fixture\tcontrol"
[mcp_servers.control]
command = "svc"
args = ["--url=https:\t//alice:harborpassCTRL@example.test/r", "https://alice:\nharborpassCTRL@example.test/r", "tail\n", "--port", "8080"]
url = "https:\t//alice:harborpassCTRL@example.test/r"
[model_providers.control]
base_url = "https://alice:\nharborpassCTRL@example.test/r"
EOF
(
  OMB_FIXTURE=$CX
  scan_extract codex:config "$T/x-control-codex" >/dev/null 2>&1
  omb_cleanup
)
src=$(awk -F '\t' '$1 == "file" { sub(/^src=/, "", $3); print $3 }' "$T/x-control-codex/carry")
assert_contains "$(cat "$T/x-control-codex/$src")" 'args = ["--port", "8080"]' "secret-args-control: Codex keeps its ordinary arguments"
assert_not_contains "$(cat "$T/x-control-codex/$src")" 'model =' "secret-args-control: Codex drops a configuration value with a control"
assert_eq "$(grep -rl harborpassCTRL "$T/x-control-codex")" "" "secret-args-control: Codex carries no control-obscured URL"
assert_contains "$(cat "$T/x-control-codex/carry")" "needs-secret" "secret-args-control: Codex reports the dropped values"
if t_plutil "control bytes in Claude and OpenCode conversions"; then
  cat >"$CX/root/Users/alex/.claude.json" <<'EOF'
{"mcpServers":{"control":{"command":"svc", "args":["--url=https:\t//alice:harborpassCTRL@example.test/r", "https://alice:\nharborpassCTRL@example.test/r", "tail\n", "--port", "8080"], "url":"https:\t//alice:harborpassCTRL@example.test/r"}}}
EOF
  cat >"$CX/root/Users/alex/.config/opencode/opencode.json" <<'EOF'
{"mcp":{"control":{"type":"local", "command":["svc", "--url=https:\t//alice:harborpassCTRL@example.test/r", "https://alice:\nharborpassCTRL@example.test/r", "tail\n", "--port", "8080"], "url":"https:\t//alice:harborpassCTRL@example.test/r"}}, "provider":{"control":{"options":{"baseURL":"https://alice:\nharborpassCTRL@example.test/r"}}}}
EOF
  for id in claude:mcp:control opencode:config; do
    out=$T/x-control-${id%%:*}
    (
      OMB_FIXTURE=$CX
      scan_extract "$id" "$out" >/dev/null 2>&1
      omb_cleanup
    )
    assert_eq "$(grep -rl harborpassCTRL "$out")" "" "secret-args-control: $id carries no control-obscured credential"
    assert_not_contains "$(cat "$out/carry" "$out"/f/* 2>/dev/null)" tail "secret-args-control: $id refuses a trailing newline"
    assert_contains "$(cat "$out/carry")" needs-secret "secret-args-control: $id reports its dropped arguments"
  done
fi
# secret-args-control-sequence: dropping a credential value with a control
# advances the previous argument, so the next ordinary switch stays.
cat >"$CX/root/Users/alex/.codex/config.toml" <<'EOF'
[mcp_servers.control]
command = "svc"
args = ["--token", "shortpass\n", "--port", "8080"]
EOF
(
  OMB_FIXTURE=$CX
  scan_extract codex:config "$T/x-control-sequence" >/dev/null 2>&1
  omb_cleanup
)
src=$(awk -F '\t' '$1 == "file" { sub(/^src=/, "", $3); print $3 }' "$T/x-control-sequence/carry")
assert_contains "$(cat "$T/x-control-sequence/$src")" 'args = ["--port", "8080"]' "secret-args-control-sequence: the next switch and its value stay together"
assert_not_contains "$(cat "$T/x-control-sequence/$src")" shortpass "secret-args-control-sequence: the token value is dropped"
assert_contains "$(cat "$T/x-control-sequence/carry")" needs-secret "secret-args-control-sequence: the item needs its secret set again"
# secret-starship-fields (S9): Starship's file is rebuilt by its documented
# field names; a field no rule names, and a custom module, stay behind.
cat >"$CX/root/Users/alex/.config/starship.toml" <<'EOF'
add_newline = false
api_key = "harborpassSTAR1"

[character]
success_symbol = "[>](bold green)"
api_key = "harborpassSTAR2"

[nodejs]
detect_extensions = ["js", "mjs"]

[custom.vpn]
command = "echo harborpassSTAR3"
when = "true"

[palettes.mine]
blue = "#1e66f5"
EOF
(
  OMB_FIXTURE=$CX
  scan_extract starship:config "$T/x-star" >/dev/null 2>&1
  omb_cleanup
)
assert_eq "$(grep -rl harborpass "$T/x-star")" "" "secret-starship-fields: no unknown field or custom module travels"
src=$(awk -F '\t' '$1 == "file" { sub(/^src=/, "", $3); print $3 }' "$T/x-star/carry")
star=$(cat "$T/x-star/$src")
for want in 'add_newline = false' '[character]
success_symbol = "[>](bold green)"' '[nodejs]
detect_extensions = ["js", "mjs"]' '[palettes.mine]
blue = "#1e66f5"'; do
  assert_contains "$star" "$want" "secret-starship-fields: a documented setting stays ($(printf '%s' "$want" | head -n 1))"
done
assert_contains "$(cat "$T/x-star/carry")" "starship%20character.api_key:%20left%20behind" "secret-starship-fields: what is left behind is listed"
assert_contains "$(cat "$T/x-star/carry")" "whole=0" "secret-starship-fields: as a rebuilt file, not one carried whole"
rm -rf "$CX"

# --- secret-stow-refused (S6): a chosen root is refused where it really is ---
SV=$(t_variant mig-mac-home)
SH=$SV/root/Users/alex
mkdir -p "$SH/.docker" "$SH/.aws" "$SH/Library/Thing" "$SV/root/opt/elsewhere"
printf '{"auths":{"registry.example":{"auth":"YWxleDpoYXJib3JwYXNz"}}}\n' >"$SH/.docker/config.json"
printf 'a note (fixture)\n' >"$SH/.docker/notes.txt"
printf '[default]\naws_secret_access_key = harborpassAWS01\n' >"$SH/.aws/credentials"
printf 'x\n' >"$SH/Library/Thing/x" && printf 'x\n' >"$SV/root/opt/elsewhere/x"
ln -s ../.docker "$SH/.config/dockercopy"
ln -s .. "$SH/.config/homecopy"
ln -s ../Library "$SH/.config/libcopy"
ln -s ../.aws "$SH/.config/awscopy"
ln -s ../.ssh "$SH/.config/sshcopy"
ln -s /opt/elsewhere "$SH/.config/outside"
stow() { # ID DIR
  (
    OMB_FIXTURE=$SV
    scan_extract "$1" "$2" >/dev/null 2>&1
    omb_cleanup
  )
}
stow path:.config/dockercopy "$T/x-dock"
carry=$(cat "$T/x-dock/carry")
assert_contains "$carry" "skip	reason=.config/dockercopy/config.json:%20container%20credentials" "secret-stow-refused: a file refused where it really is stays, under any name"
assert_not_contains "$carry" "file	dest=.config/dockercopy/config.json" "secret-stow-refused: the Docker credentials are not carried"
assert_contains "$carry" "file	dest=.config/dockercopy/notes.txt" "secret-stow-refused: the rest of the folder is"
for c in homecopy:"it%20leads%20to%20the%20home%20folder%20itself" libcopy:"it%20leads%20into%20the%20Library%20folder" \
  awscopy:"cloud%20credentials" sshcopy:"it%20leads%20into%20a%20folder%20of%20keys" outside:"it%20leads%20out%20of%20the%20home%20folder"; do
  stow "path:.config/${c%%:*}" "$T/x-${c%%:*}"
  carry=$(cat "$T/x-${c%%:*}/carry")
  assert_contains "$carry" "skip	reason=.config/${c%%:*}:%20${c#*:}" "secret-stow-refused: a root that resolves to a refused place is refused (${c%%:*})"
  assert_not_contains "$carry" "file	" "secret-stow-refused: and nothing of it is carried (${c%%:*})"
done
assert_eq "$(grep -rl harborpass "$T"/x-dock "$T"/x-awscopy 2>/dev/null)" "" "secret-stow-refused: no credential reached a carry"
# secret-stow-slash: a link chain hidden behind a trailing slash is still a
# link to a link, and is not followed; a single link with one still is.
ln -s .docker "$SH/hop"
ln -s ../hop/ "$SH/.config/dockerhop"
ln -s ../dotfiles/stowed/ "$SH/.config/stowslash"
stow path:.config/dockerhop "$T/x-hop"
carry=$(cat "$T/x-hop/carry")
assert_contains "$carry" "skip	reason=.config/dockerhop:%20a%20link%20to%20a%20link,%20not%20followed" "secret-stow-slash: a chain ending in a slash is refused"
assert_not_contains "$carry" "file	" "secret-stow-slash: and nothing of it is carried"
stow path:.config/stowslash "$T/x-slash"
assert_contains "$(cat "$T/x-slash/carry")" "file	dest=.config/stowslash/conf.ini" "secret-stow-slash: one link written with a slash is followed once"
# secret-stow-root: trimming a link target must preserve the root slash.
for target in / ////; do
  ln -s "$target" "$SH/.config/rootcopy"
  stow path:.config/rootcopy "$T/x-root-${#target}"
  carry=$(cat "$T/x-root-${#target}/carry")
  assert_contains "$carry" "skip	reason=.config/rootcopy:" "secret-stow-root: a link to $target is refused"
  assert_not_contains "$carry" "file	" "secret-stow-root: nothing is carried through $target"
  assert_eq "$(find "$T/x-root-${#target}/f" -type f)" "" "secret-stow-root: no captured bytes through $target"
  rm "$SH/.config/rootcopy"
done
# secret-stow-unicode: these names alias protected paths on the Mac. On a
# case-sensitive filesystem they are separate folders; the root guard must
# still refuse them, and the per-file guard must refuse an actual alias.
longs=$(printf '\305\277')
kelvin=$(printf '\342\204\252')
mkdir -p "$SH/.${longs}sh" "$SH/.${kelvin}ube" "$SH/dotfiles/unicode"
printf 'fixture key folder note\n' >"$SH/.${longs}sh/unicode-note"
printf 'fixture cluster configuration\n' >"$SH/.${kelvin}ube/config"
u=0
for name in ".${longs}sh" ".${kelvin}ube"; do
  u=$((u + 1))
  ln -s "../$name" "$SH/.config/unicodecopy"
  stow path:.config/unicodecopy "$T/x-unicode-$u"
  carry=$(cat "$T/x-unicode-$u/carry")
  assert_contains "$carry" "skip	reason=.config/unicodecopy:" "secret-stow-unicode: a non-ASCII resolved root is refused"
  assert_not_contains "$carry" "file	" "secret-stow-unicode: no bytes from a non-ASCII root travel"
  rm "$SH/.config/unicodecopy"
done
# A harmless name hard-linked to a hard-refused file exercises identity
# independently of name folding, on both case-sensitive and insensitive disks.
printf 'fixture container configuration\n' >"$SH/.docker/config.json"
ln "$SH/.docker/config.json" "$SH/dotfiles/unicode/ordinary.json"
ln "$SH/.${kelvin}ube/config" "$SH/dotfiles/unicode/cluster-note"
ln "$SH/.${longs}sh/unicode-note" "$SH/dotfiles/unicode/ssh-note"
stow path:dotfiles/unicode "$T/x-unicode-files"
carry=$(cat "$T/x-unicode-files/carry")
assert_not_contains "$carry" "file	dest=dotfiles/unicode/ordinary.json" "secret-stow-unicode: a protected file's identity is refused inside a chosen root"
for pair in "cluster-note:.kube/config" "ssh-note:.ssh/unicode-note"; do
  dest="file	dest=dotfiles/unicode/${pair%%:*}"
  assert_not_contains "$carry" "$dest" "secret-stow-unicode: an inode with a non-ASCII alias is refused (${pair%%:*})"
done
# Unicode path components inside the tree must not hide a protected place.
mkdir -p "$SH/dotfiles/unicode/.${kelvin}ube"
printf 'fixture cluster configuration\n' >"$SH/dotfiles/unicode/.${kelvin}ube/config"
stow path:dotfiles/unicode "$T/x-unicode-child"
carry=$(cat "$T/x-unicode-child/carry")
assert_not_contains "$carry" "file	dest=dotfiles/unicode/." "secret-stow-unicode: a protected Unicode spelling inside a chosen root is refused"
# secret-path-ascii: every name is printable ASCII, including adapter
# trees, opaque trees and an inode's other names on case-sensitive disks.
mkdir -p "$SH/dotfiles/ascii" "$SH/.config/nvim/dir${longs}"
ln -s init.lua "$SH/.config/nvim/link${longs}"
ln -s "credential${longs}" "$SH/.config/nvim/alias"
printf 'shortpassASCIIadapter\n' >"$SH/.config/nvim/credential${longs}"
printf 'shortpassASCIIopaque\n' >"$SH/dotfiles/ascii/credential${longs}"
ln "$SH/dotfiles/ascii/credential${longs}" "$SH/dotfiles/ascii/ordinary.txt"
cp "$S/.ssh/id_ed25519" "$SH/.ssh/id_${longs}"
for rel in ".config/nvim/credential${longs}" "dotfiles/ascii/credential${longs}" ".ssh/id_${longs}"; do
  scan_refused "$rel"
  assert_eq "$? $SCAN_HIT" "0 a path with a byte outside printable ASCII, which can hide a credential filename" "secret-path-ascii: a non-ASCII path is refused with its reason"
done
u=0
for id in nvim:config path:dotfiles/ascii "path:.ssh/id_${longs}"; do
  u=$((u + 1))
  out=$T/x-ascii-$u
  stow "$id" "$out"
  carry=$(cat "$out/carry")
  assert_contains "$carry" 'outside%20printable%20ASCII' "secret-path-ascii: $id reports its path refusal"
  assert_not_contains "$carry" 'file	dest=dotfiles/ascii/ordinary.txt' "secret-path-ascii: an ASCII hard link to a non-ASCII name is refused"
  assert_not_contains "$carry" 'file	dest=.config/nvim/credential' "secret-path-ascii: no adapter-owned non-ASCII file is carried"
  assert_not_contains "$carry" 'file	dest=.ssh/id_' "secret-path-ascii: the encrypted-key exception cannot override the path rule"
  assert_not_contains "$carry" 'dir	dest=.config/nvim/dir' "secret-path-ascii: a non-ASCII directory name is refused"
  assert_not_contains "$carry" 'link	dest=.config/nvim/link' "secret-path-ascii: a non-ASCII link name is refused"
  assert_not_contains "$carry" 'link	dest=.config/nvim/alias' "secret-path-ascii: a non-ASCII link target is refused"
  assert_eq "$(grep -rl shortpassASCII "$out/f")" "" "secret-path-ascii: none of the refused bytes is captured"
done
if t_plutil "non-ASCII path inventory"; then
  (
    OMB_FIXTURE=$SV
    scan_run "$T/inv-ascii" >/dev/null 2>&1
    omb_cleanup
  )
  for id in nvim:config "path:.ssh/id_${longs}"; do
    rec_enc_v "$id"
    line=$(awk -F '\t' -v id="id=$REC_ENC" '$1 == "item" && $2 == id' "$T/inv-ascii")
    assert_contains "$line" 'outside%20printable%20ASCII' "secret-path-ascii: $id explains the refusal in the inventory"
    assert_not_contains "$line" 'kind=key-encrypted' "secret-path-ascii: a non-ASCII filename is never an eligible encrypted-key item"
  done
fi
# secret-one-name: no regular file with another hard-link name travels,
# regardless of the tree class, the other name's spelling or its location.
ln "$SH/.config/nvim/credential${longs}" "$SH/.config/nvim/ordinary.txt"
mkdir -p "$SH/dotfiles/one-name"
printf 'shortpassONENAMEopaque\n' >"$SH/dotfiles/one-name/visible.txt"
ln "$SH/dotfiles/one-name/visible.txt" "$SH/dotfiles/one-name/alias"$'\n'
printf 'ordinary one-name file\n' >"$SH/dotfiles/one-name/single.txt"
printf 'shortpassONENAMEconfig\n' >"$SH/.tmux.conf"
ln "$SH/.tmux.conf" "$T/config-alias"
printf 'shortpassONENAMEsingle\n' >"$SH/dotfiles/single.txt"
ln "$SH/dotfiles/single.txt" "$T/opaque-alias"
ln "$SH/.ssh/known_hosts" "$T/hosts-alias"
ln "$SH/.ssh/id_ed25519" "$T/key-alias"
u=0
for id in nvim:config path:dotfiles/ascii path:dotfiles/one-name path:.tmux.conf path:dotfiles/single.txt path:.ssh/known_hosts path:.ssh/id_ed25519; do
  u=$((u + 1))
  out=$T/x-one-name-$u
  stow "$id" "$out"
  carry=$(cat "$out/carry")
  assert_contains "$carry" 'a%20file%20with%20other%20names%20%28hard%20links%29%20is%20not%20carried,%20because%20another%20name%20could%20hide%20a%20refused%20one' "secret-one-name: $id explains why a hard link is refused"
  assert_eq "$(grep -rl 'shortpassASCII\|shortpassONENAME' "$out/f")" "" "secret-one-name: $id captures none of the hard-linked bytes"
  case "$id" in
    nvim:config)
      assert_not_contains "$carry" 'file	dest=.config/nvim/ordinary.txt' 'secret-one-name: an adapter tree refuses an ASCII alias of a non-ASCII name'
      assert_contains "$carry" 'file	dest=.config/nvim/init.lua' 'secret-one-name: an ordinary single-name adapter file still carries'
      ;;
    path:dotfiles/ascii)
      assert_not_contains "$carry" 'file	dest=dotfiles/ascii/ordinary.txt' 'secret-one-name: an opaque tree refuses an ASCII alias of a non-ASCII name'
      ;;
    path:dotfiles/one-name)
      assert_not_contains "$carry" 'file	dest=dotfiles/one-name/visible.txt' 'secret-one-name: an alias ending in LF cannot make a file eligible'
      assert_contains "$carry" 'file	dest=dotfiles/one-name/single.txt' 'secret-one-name: an ordinary single-name opaque file still carries'
      ;;
    *)
      assert_not_contains "$carry" 'file	' "secret-one-name: $id carries no hard-linked file"
      assert_eq "$(find "$out/f" -type f)" "" "secret-one-name: $id captures no object"
      ;;
  esac
done
# secret-stow-case: the Mac's file system does not tell .DOCKER from .docker,
# Library from library, .ssh from .SSH; neither do the refusals. Written
# through the differently cased names, so a case-sensitive system holds the
# same shapes.
mkdir -p "$SH/.DOCKER" "$SH/library/Thing" "$SH/.SSH"
printf '{"auths":{"registry.example":{"auth":"YWxleDpoYXJib3JwYXNz"}}}\n' >"$SH/.DOCKER/config.json"
printf 'x\n' >"$SH/library/Thing/y"
ln -s ../.DOCKER "$SH/.config/dockercase"
ln -s ../library "$SH/.config/libcase"
ln -s ../.SSH "$SH/.config/sshcase"
stow path:.config/dockercase "$T/x-dcase"
carry=$(cat "$T/x-dcase/carry")
assert_contains "$carry" "skip	reason=.config/dockercase/config.json:%20container%20credentials" "secret-stow-case: a differently cased .docker keeps its refusal"
assert_not_contains "$carry" "file	dest=.config/dockercase/config.json" "secret-stow-case: its credentials are not carried"
for c in libcase:"it%20leads%20into%20the%20Library%20folder" sshcase:"it%20leads%20into%20a%20folder%20of%20keys"; do
  stow "path:.config/${c%%:*}" "$T/x-${c%%:*}"
  carry=$(cat "$T/x-${c%%:*}/carry")
  assert_contains "$carry" "skip	reason=.config/${c%%:*}:%20${c#*:}" "secret-stow-case: a differently cased root is refused (${c%%:*})"
  assert_not_contains "$carry" "file	" "secret-stow-case: and nothing of it is carried (${c%%:*})"
done
for rel in .DOCKER/config.json LIBRARY .AWS/credentials ID_RSA .ENV.local library/keychains/login.keychain-db; do
  scan_refused "$rel"
  assert_rc $? 0 "secret-stow-case: $rel is refused in any case"
done
rm -rf "$SV"

# --- secret-ssh: the one exception, by the key's envelope (no plutil) ---------
for k in id_ed25519:encrypted id_plain:plain id_weak:unsupported id_legacy:pem; do
  scan_ssh_key "$S/.ssh/${k%%:*}"
  assert_eq "$SCAN_KEY" "${k#*:}" "secret-ssh: ${k%%:*} is $SCAN_KEY"
done
scan_key_check "$S/.ssh/id_ed25519"
assert_rc $? 0 "secret-ssh: aes256-ctr with bcrypt 16 rounds may travel"
for k in id_plain id_weak id_legacy; do
  scan_key_check "$S/.ssh/$k"
  assert_rc $? 1 "secret-ssh: $k may not"
done
head -n 2 "$S/.ssh/id_ed25519" >"$T/torn" && printf -- '-----END OPENSSH PRIVATE KEY-----\n' >>"$T/torn"
scan_ssh_key "$T/torn"
assert_eq "$SCAN_KEY" malformed "secret-ssh: a torn envelope is malformed"
# secret-ssh-torn (S12): the envelope must hold the key's public-key string
# and its private section in full, or it is malformed — never "encrypted".
k_u32() {
  local o
  for o in $((($1 >> 24) & 255)) $((($1 >> 16) & 255)) $((($1 >> 8) & 255)) $(($1 & 255)); do
    # shellcheck disable=SC2059 # an octal escape built on purpose
    printf "\\$(printf '%03o' "$o")"
  done
}
k_str() { k_u32 "${#1}" && printf '%s' "$1"; }
# k_key FILE CIPHER PUB PRIV TAG — a synthetic envelope shaped as OpenSSH
# writes one (bcrypt, 16 rounds), its key's parts chosen: PUB real (an
# ssh-ed25519 type and 32 key bytes), text (a placeholder string) or none;
# PRIV the private section's length in bytes, short (a length past the end)
# or none; TAG 1 for the 16 bytes an authenticated cipher keeps after it.
k_key() {
  local type curve point hex
  {
    printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n'
    {
      printf 'openssh-key-v1\000'
      k_str "$2" && k_str bcrypt && k_u32 24 && k_u32 16 && printf 'FIXTURESALT00000' && k_u32 16 && k_u32 1
      case "$3" in
        real) k_u32 51 && k_str ssh-ed25519 && k_str FIXTUREPUBLICKEYFIXTUREPUBLICKEY ;;
        text) k_str "ssh-ed25519 FIXTURE PUBLIC KEY" ;;
        type) k_u32 15 && k_str ssh-ed25519 ;;
        tiny) k_u32 20 && k_str ssh-ed25519 && k_str F ;;
        extra) k_u32 52 && k_str ssh-ed25519 && k_str FIXTUREPUBLICKEYFIXTUREPUBLICKEY && printf F ;;
        rsa)
          k_u32 279 && k_str ssh-rsa && k_u32 3 && printf '\001\000\001'
          k_u32 257 && printf '\000\200' && head -c 255 /dev/zero | tr '\0' F
          ;;
        rsa-small) k_u32 21 && k_str ssh-rsa && k_str E && k_str N ;;
        rsa-short) k_u32 16 && k_str ssh-rsa && k_str E ;;
        dss) k_u32 31 && k_str ssh-dss && k_str P && k_str Q && k_str G && k_str Y ;;
        ecdsa | ecdsa384 | ecdsa521 | ecdsa-zero | ecdsa384-zero | ecdsa521-zero | ecdsa-short | ecdsa-curve | ecdsa-prefix)
          curve=nistp256 point=65
          # The standard curves' generator points are valid public points;
          # no generated or live private key is needed for these fixtures.
          hex=046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5
          case "$3" in
            ecdsa384 | ecdsa384-zero)
              curve=nistp384 point=97
              hex=04aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab73617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f
              ;;
            ecdsa521 | ecdsa521-zero)
              curve=nistp521 point=133
              hex=0400c6858e06b70404e9cd9e3ecb662395b4429c648139053fb521f828af606b4d3dbaa14b5e77efe75928fe1dc127a2ffa8de3348b3c1856a429bf97e7e31c2e5bd66011839296a789a3bc0045c8a5fb42c7d1bd998f54449579b446817afbd17273e662c97ee72995ef42640c550b9013fad0761353c7086a272c24088be94769fd16650
              ;;
            ecdsa-short) point=1 ;;
          esac
          type=ecdsa-sha2-$curve
          [ "$3" != ecdsa-curve ] || curve=nistp521
          k_u32 $((4 + ${#type} + 4 + ${#curve} + 4 + point)) && k_str "$type" && k_str "$curve" && k_u32 "$point"
          case "$3" in
            *-zero) printf '\004' && head -c "$((point - 1))" /dev/zero ;;
            ecdsa-short) printf Q ;;
            ecdsa-prefix) printf Q && head -c "$((point - 1))" /dev/zero ;;
            *) perl -e 'print pack("H*", $ARGV[0])' -- "$hex" ;;
          esac
          ;;
        sk-ed) k_u32 81 && k_str sk-ssh-ed25519@openssh.com && k_str FIXTUREPUBLICKEYFIXTUREPUBLICKEY && k_str fixture-app ;;
        sk-ec) k_u32 70 && k_str sk-ecdsa-sha2-nistp256@openssh.com && k_str nistp256 && k_str Q && k_str fixture-app ;;
      esac
      case "$4" in
        none) ;;
        short) k_u32 400 && printf 'FIXTURE PRIVATE SECTION' ;;
        *) k_u32 "$4" && head -c "$4" /dev/zero | tr '\0' 'F' ;;
      esac
      case "$5" in
        1) printf 'FIXTURE TAG 0016' ;;
        extra) printf 'FIXTURE EXTRA BYTE' ;;
        tag-extra) printf 'FIXTURE TAG 0016X' ;;
      esac
    } | base64 | tr -d '\n' | fold -w 70
    printf '\n-----END OPENSSH PRIVATE KEY-----\n'
  } >"$1"
}
for parts in "none none" "real none" "real short"; do
  # shellcheck disable=SC2086 # two words, split on purpose
  k_key "$T/torn" aes256-ctr $parts 0
  scan_ssh_key "$T/torn"
  assert_eq "$SCAN_KEY" malformed "secret-ssh-torn: an envelope cut after its key count ($parts) is malformed"
  scan_key_check "$T/torn"
  assert_rc $? 1 "secret-ssh-torn: and is never carried ($parts)"
done
# secret-ssh-padded: the public key begins with a key type OpenSSH writes,
# and the private section is whole cipher blocks with an authenticated
# cipher's tag after it; anything else is malformed, never carried.
for c in "aes256-ctr real 1 0" "aes256-ctr real 17 0" "aes256-ctr text 160 0" "aes256-gcm@openssh.com real 160 0" \
  "chacha20-poly1305@openssh.com real 12 1" "chacha20-poly1305@openssh.com real 168 0"; do
  # shellcheck disable=SC2086 # four words, split on purpose
  k_key "$T/padded" $c
  scan_ssh_key "$T/padded"
  assert_eq "$SCAN_KEY" malformed "secret-ssh-padded: $c is malformed"
done
for c in "aes256-ctr real 160 0" "aes256-gcm@openssh.com real 160 1" "chacha20-poly1305@openssh.com real 168 1"; do
  # shellcheck disable=SC2086 # four words, split on purpose
  k_key "$T/padded" $c
  scan_key_check "$T/padded"
  assert_rc $? 0 "secret-ssh-padded: $c, shaped as OpenSSH writes it, is an encrypted key"
done
# secret-ssh-envelope: parse every public-key string, and consume exactly
# the private section and the authenticated cipher's tag, with no suffix.
for c in "aes256-ctr type 16 0" "aes256-ctr tiny 16 0" "aes256-ctr extra 16 0" "aes256-ctr rsa-short 16 0" \
  "aes256-ctr real 16 extra" "aes256-gcm@openssh.com real 16 tag-extra" "chacha20-poly1305@openssh.com real 16 tag-extra"; do
  # shellcheck disable=SC2086 # four words, split on purpose
  k_key "$T/envelope" $c
  scan_ssh_key "$T/envelope"
  assert_eq "$SCAN_KEY" malformed "secret-ssh-envelope: $c is malformed"
  scan_key_check "$T/envelope"
  assert_rc $? 1 "secret-ssh-envelope: $c is never carried"
done
# secret-ssh-canonical: only one complete, canonical armor and envelope;
# each supported type has its exact public fields and enough private bytes.
for c in aes256-ctr aes256-gcm@openssh.com chacha20-poly1305@openssh.com; do
  tag=1
  [ "$c" != aes256-ctr ] || tag=0
  for parts in "real 144" "rsa 320"; do
    # shellcheck disable=SC2086 # public shape and private length, split on purpose
    k_key "$T/canonical" "$c" $parts "$tag"
    scan_key_check "$T/canonical"
    assert_rc $? 0 "secret-ssh-canonical: a complete $c $parts envelope is supported"
  done
  for parts in "ecdsa 128" "ecdsa384 160" "ecdsa521 192" "ecdsa-zero 128" "ecdsa384-zero 160" "ecdsa521-zero 192"; do
    # shellcheck disable=SC2086 # public shape and private length, split on purpose
    k_key "$T/canonical" "$c" $parts "$tag"
    scan_key_check "$T/canonical"
    assert_rc $? 1 "secret-ssh-canonical: an ECDSA key never carries ($c $parts)"
    assert_contains "$SCAN_HIT" 're-create the key on Linux, or carry an Ed25519 or RSA key' 'secret-ssh-canonical: the ECDSA refusal gives the alternatives'
  done
done
# The inventory and export explain the policy for a well-shaped ECDSA key,
# whether its name starts with id_ or just its header identifies it.
EK=$(t_variant mig-mac-home)
for parts in "ecdsa 128" "ecdsa384 160" "ecdsa521 192"; do
  name=${parts%% *}
  # shellcheck disable=SC2086 # public shape and private length, split on purpose
  k_key "$EK/root/Users/alex/.ssh/$name" aes256-ctr $parts 0
  (
    OMB_FIXTURE=$EK
    scan_extract "path:.ssh/$name" "$T/x-$name" >/dev/null 2>&1
    omb_cleanup
  )
  carry=$(cat "$T/x-$name/carry")
  assert_contains "$carry" 're-create%20the%20key%20on%20Linux,%20or%20carry%20an%20Ed25519%20or%20RSA%20key' "secret-ssh-canonical: export explains why $name stays"
  assert_not_contains "$carry" 'file	' "secret-ssh-canonical: export carries no $name key"
done
if t_plutil 'ECDSA key inventory'; then
  (
    OMB_FIXTURE=$EK
    scan_run "$T/inv-ecdsa" >/dev/null 2>&1
    omb_cleanup
  )
  for name in ecdsa ecdsa384 ecdsa521; do
    line=$(awk -F '\t' -v id="id=path:.ssh/$name" '$1 == "item" && $2 == id' "$T/inv-ecdsa")
    assert_contains "$line" 're-create%20the%20key%20on%20Linux,%20or%20carry%20an%20Ed25519%20or%20RSA%20key' "secret-ssh-canonical: the inventory explains why $name stays"
    assert_not_contains "$line" 'kind=key-encrypted' "secret-ssh-canonical: $name is not eligible for carry"
  done
fi
rm -rf "$EK"
for parts in "real 16" "ecdsa-short 160" "ecdsa-curve 160" "ecdsa-prefix 160" "ecdsa384 144" "ecdsa521 176" "rsa-small 320" "rsa 304" "dss 160" "sk-ed 160" "sk-ec 160"; do
  # shellcheck disable=SC2086 # public shape and private length, split on purpose
  k_key "$T/canonical" aes256-ctr $parts 0
  scan_ssh_key "$T/canonical"
  assert_eq "$SCAN_KEY" malformed "secret-ssh-canonical: malformed or unsupported public/private fields ($parts) are refused"
done
# This size has Base64 padding, so suffix text and a second run exercise the
# precise boundary at which the old decoder stopped reading.
k_key "$T/canonical" aes256-ctr real 160 0
assert_contains "$(cat "$T/canonical")" '=' "secret-ssh-canonical: the armor fixture reaches Base64 padding"
for form in text second-run comment crlf no-final-lf trailing-blank prefix blank-body wide padding-bits; do
  case "$form" in
    text) sed '/^-----END/i\
api_key = sk-FIXTUREcleartextsecret0000000000
' "$T/canonical" >"$T/armor" ;;
    second-run) sed '/^-----END/i\
RklYVFVSRSBTRUNPTkQgUlVO
' "$T/canonical" >"$T/armor" ;;
    comment) sed '2i\
# synthetic fixture comment
' "$T/canonical" >"$T/armor" ;;
    crlf) awk '{ printf "%s\r\n", $0 }' "$T/canonical" >"$T/armor" ;;
    no-final-lf) head -c "$(($(wc -c <"$T/canonical") - 1))" "$T/canonical" >"$T/armor" ;;
    trailing-blank) { cat "$T/canonical"; printf '\n'; } >"$T/armor" ;;
    prefix) { printf 'fixture text\n'; cat "$T/canonical"; } >"$T/armor" ;;
    blank-body) sed '2i\

' "$T/canonical" >"$T/armor" ;;
    wide) awk '/^-----/ { if (body != "") { print body; body = "" }; print; next } { body = body $0 }' "$T/canonical" >"$T/armor" ;;
    padding-bits) sed 's/Y=$/Z=/' "$T/canonical" >"$T/armor" ;;
  esac
  scan_ssh_key "$T/armor"
  assert_eq "$SCAN_KEY" malformed "secret-ssh-canonical: $form armor is refused"
done
{ cat "$S/.ssh/id_ed25519"; head -c 17000 /dev/zero | tr '\0' 'A'; } >"$T/big"
scan_key_check "$T/big"
assert_rc $? 1 "secret-ssh: a key over 16 KiB is refused"

# p_tool DIR — a copy of the tool whose resolution is a fixed stand-in.
p_tool() {
  mkdir -p "$1"
  cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$1/"
  cat >"$1/lib/migrate_resolve.sh" <<'EOF'
# shellcheck shell=bash
# A test stand-in for the resolution unit's seam: everything resolves.
res_resolve() {
  LC_ALL=C awk -F '\t' '$1 == "item" { k = $4; sub(/^kind=/, "", k)
    ly = (k == "git" || k == "mcp" || k == "plugin") ? "settings" : "files"
    if (k ~ /^(brew-formula|brew-cask|app|cargo|npm|pnpm|bun|uv|pipx|go|tap|extension|nvm|mise|asdf)$/) ly = "packages"
    printf "resolution\t%s\tlayer=%s\tmethod=place\ttarget=\tversion=\tguess=0\tstate=resolved\tnote=\n", $2, ly }' "$1" >"$3"
}
res_choices() { : >"$2"; }
EOF
}

if t_plutil "the profile and the extracts over planted secrets"; then
  PT=$T/tool
  p_tool "$PT"
  F=$(t_variant mig-mac-secrets)

  # --- secret-profile: nothing planted reaches the profile, state or log -------
  SD=$T/state-cli
  REPO=$PT T_ENV="OMB_STATE_DIR=$SD" t_cli "$F" "" profile
  assert_rc "$T_RC" 0 "secret-profile: profile saves over a home full of credentials"
  [ -f "$SD/profile.omb" ] && ok || fail "secret-profile: no profile.omb"
  assert_eq "$(grep -rl "$PLANT" "$SD" 2>/dev/null)" "" "secret-profile: no planted value in the profile, state or log"
  assert_not_contains "$T_OUT" "$PLANT" "secret-profile: none printed"
  inv=$(cat "$SD/profile.omb")
  for want in "id=path:.zshrc	adapter=shell	kind=rc	category=terminal	name=.zshrc" "id=path:.env	" "id=path:.aws	" "id=gh:hosts	" "id=path:.ssh/id_plain	" "id=claude:signin	" "id=codex:signin	"; do
    line=$(printf '%s\n' "$inv" | grep "^item	$want")
    assert_contains "$line" "class=secret" "secret-profile: ${want%%	*} is secret"
  done
  assert_contains "$(printf '%s\n' "$inv" | grep '^item	id=path:.zshrc	')" "an%20API%20key%20%28sk-%29" "secret-profile: the kind is named"
  assert_contains "$(printf '%s\n' "$inv" | grep '^item	id=path:.ssh/id_plain	')" "without%20a%20passphrase" "secret-profile: an unencrypted key says why it stays"
  assert_contains "$(printf '%s\n' "$inv" | grep '^item	id=path:.npmrc	')" "class=secret" "secret-profile: an npm token file is refused by what it holds"
  if printf '%s\n' "$inv" | grep '^select	' | grep -qE 'id=(path:.env|path:.ssh/id_plain|path:.ssh/id_ed25519|gh:hosts|path:.myscripts|path:.ssh/known_hosts)	state'; then
    fail "secret-profile: a secret, opaque or sensitive item is selected by default"
  else
    ok
  fi
  if printf '%s\n' "$inv" | grep -q '^consent	'; then fail "secret-profile: the CLI typed a consent"; else ok; fi

  # --- secret-extract: nothing planted in what any item carries ---------------
  ids=$(awk -F '\t' '$1 == "item" { sub(/^id=/, "", $2); print $2 }' "$SD/profile.omb")
  n=0
  (
    OMB_FIXTURE=$F
    i=0
    while IFS= read -r id; do
      i=$((i + 1))
      scan_extract "$(rec_dec "$id")" "$T/x/$i" >/dev/null 2>&1
    done <<EOF
$ids
EOF
    omb_cleanup
  )
  n=$(find "$T/x" -name carry | grep -c .)
  assert_eq "$n" "$(printf '%s\n' "$ids" | grep -c .)" "secret-extract: every item extracted"
  assert_eq "$(grep -rl "$PLANT" "$T/x")" "" "secret-extract: no planted value in any byte an item carries"
  carry=$(cat "$T"/x/*/carry)
  assert_contains "$carry" "skip	reason=.config/omarchy-mac-bootstrap/zsh/.zshrc:%20an%20API%20key%20%28sk-%29" "secret-extract: a file carried whole with a credential is left out, by kind"
  assert_contains "$carry" "skip	reason=.myscripts/deploy.sh:%20a%20GitHub%20token" "secret-extract: inside an opaque folder too"
  assert_contains "$carry" "skip	reason=claude%20env%20values%20never%20travel:%20ANTHROPIC_API_KEY" "secret-extract: env values never travel, their names are listed"
  assert_contains "$carry" "%22GITHUB_TOKEN%22:%22%24%7BGITHUB_TOKEN%7D%22" "secret-extract: an MCP env value becomes a variable reference"
  assert_contains "$(cat "$T"/x/*/f/* 2>/dev/null)" 'env_vars = ["GITHUB_TOKEN"]' "secret-extract: Codex's env names join env_vars"
  assert_contains "$carry" "git%20url.%2A.insteadof:%20a%20URL%20holding%20a%20credential,%20dropped" "secret-extract: a Git URL with a password is dropped"
  # --- secret-usekeychain ---------------------------------------------------
  (
    OMB_FIXTURE=$F
    scan_extract ssh:config "$T/x-ssh" >/dev/null 2>&1
    omb_cleanup
  )
  src=$(awk -F '\t' '$1 == "file" { sub(/^src=/, "", $3); print $3 }' "$T/x-ssh/carry")
  if grep -qi usekeychain "$T/x-ssh/$src"; then fail "secret-usekeychain: a UseKeychain line travelled"; else ok; fi
  assert_contains "$(cat "$T/x-ssh/$src")" "IdentityFile ~/.ssh/id_ed25519" "secret-usekeychain: the rest of the configuration stays"
  assert_contains "$(cat "$T/x-ssh/carry")" "dest=.ssh/config	src=f/1	mode=0644	whole=0" "secret-usekeychain: as a regenerated file"

  # secret-args (S3), Claude's side, and secret-url (S4), a project's remote.
  V=$(t_variant mig-mac-home)
  printf '%s\n' '{"mcpServers":{"svc":{"command":"svc","args":["--key=harborpassKEY4","--auth=harborpassAUTH4","https://example.test/mcp?%74oken=harborpassURL6","--port","8080"]},
    "emb":{"command":"svc","args":["--url=https://alice:harborpassEMB6@example.test/r","--port","7070"]}}}' >"$V/root/Users/alex/.claude.json"
  printf '[remote "origin"]\n\turl = https://example.test/app.git?%%74oken=harborpassREMOTE1\n' >"$V/root/Users/alex/code/app/.git/config"
  (
    OMB_FIXTURE=$V
    scan_extract claude:mcp:svc "$T/x-cmcp" >/dev/null 2>&1
    scan_extract claude:mcp:emb "$T/x-cemb" >/dev/null 2>&1
    scan_run "$T/inv-url" >/dev/null 2>&1
    omb_cleanup
  )
  assert_eq "$(grep -rl harborpass "$T/x-cmcp")" "" "secret-args: no credential argument or URL in Claude's MCP server"
  assert_contains "$(cat "$T/x-cmcp/carry")" "%22args%22:%5B%22--port%22,%228080%22%5D" "secret-args: its other arguments stay"
  assert_eq "$(grep -rl harborpass "$T/x-cemb")" "" "secret-args-embedded-url: a URL inside FLAG=VALUE never reaches Claude's MCP server"
  assert_contains "$(cat "$T/x-cemb/carry")" "%22args%22:%5B%22--port%22,%227070%22%5D" "secret-args-embedded-url: Claude keeps the rest"
  if grep -q harborpass "$T/inv-url"; then fail "secret-url: a remote's encoded credential reached the inventory"; else ok; fi
  assert_contains "$(grep 'id=project:code/app' "$T/inv-url")" "its%20remote%20holds%20a%20credential" "secret-url: the remote is withheld, saying why"

  # secret-opencode-dotted (S1) and secret-opencode-command (S2): OpenCode's
  # file is rebuilt from allowlisted fields, so a server or provider whose
  # name a key path cannot address is left out, and its command is held to
  # the argument rules.
  printf '%s\n' '{"theme":"system","plugin":["opencode-x"],"corp.extra":"harborpassTOP1",
    "mcp":{"corp.mcp":{"type":"remote","url":"https://mcp.example.test","headers":{"Authorization":"Bearer harborpassHDR1"}},
           "local":{"type":"local","command":["server","--token","harborpassCMD1","--api-key=harborpassCMD2","--port","8080"],
                    "environment":{"MODE":"harborpassENV1"},"oauth":{"clientSecret":"harborpassOA"}},
           "embedded":{"type":"local","command":["server","--url=https://alice:harborpassEMB7@example.test/r","--port","6060"]}},
    "provider":{"corp.ai":{"options":{"apiKey":"harborpassPROV1"}},
                "anthropic":{"npm":"@ai-sdk/anthropic","options":{"apiKey":"harborpassPROV2","baseURL":"https://api.example.test"},
                             "models":{"example":{"name":"Example","options":{"apiKey":"harborpassMOD1"},"headers":{"Authorization":"Bearer harborpassMOD2"}}}}}}' \
    >"$V/root/Users/alex/.config/opencode/opencode.json"
  (
    OMB_FIXTURE=$V
    scan_extract opencode:config "$T/x-oc" >/dev/null 2>&1
    omb_cleanup
  )
  assert_eq "$(grep -rl harborpass "$T/x-oc")" "" "secret-opencode-dotted: no credential of a dotted server, provider or key travels"
  src=$(awk -F '\t' '$1 == "file" { sub(/^src=/, "", $3); print $3 }' "$T/x-oc/carry")
  oc=$(tr -d ' \n' <"$T/x-oc/$src")
  assert_not_contains "$oc" "corp.mcp" "secret-opencode-dotted: the dotted server is left out"
  assert_not_contains "$oc" "corp.ai" "secret-opencode-dotted: and the dotted provider"
  assert_contains "$(cat "$T/x-oc/carry")" "an%20entry%20whose%20name%20holds%20a%20dot" "secret-opencode-dotted: saying so"
  assert_contains "$oc" '"command":["server","--port","8080"]' "secret-opencode-command: the command keeps only what the argument rules allow"
  assert_contains "$oc" '"environment":{"MODE":"{env:MODE}"}' "secret-opencode-command: environment values become references"
  assert_contains "$oc" '"baseURL":"https:\/\/api.example.test"' "secret-opencode-dotted: a provider keeps its base URL"
  assert_contains "$(cat "$T/x-oc/carry")" "opencode%20mcp%20local:%20needs-secret" "secret-opencode-command: and the server needs its secrets set again"
  if grep -rq harborpassEMB "$T/x-oc"; then fail "secret-args-embedded-url: a URL inside FLAG=VALUE reached OpenCode's command"; else ok; fi
  # secret-opencode-provider-models: a provider carries only its baseURL; its
  # models, with their options and headers, stay behind.
  if grep -rq harborpassMOD "$T/x-oc"; then fail "secret-opencode-provider-models: a model's credential reached OpenCode's file"; else ok; fi
  assert_contains "$oc" '"anthropic":{"options":{"baseURL":"https:\/\/api.example.test"}}' "secret-opencode-provider-models: the provider carries its baseURL alone"
  assert_contains "$(cat "$T/x-oc/carry")" "opencode%20provider%20anthropic:%20models%20left%20behind" "secret-opencode-provider-models: its models are listed as left behind"
  assert_contains "$oc" '"command":["server","--port","6060"]' "secret-args-embedded-url: OpenCode keeps the rest"
  rm -rf "$V"

  # --- secret-opaque and secret-carry, through the core ----------------------
  # shellcheck source=tests/core-harness.sh
  . "$TESTS_DIR/core-harness.sh"
  c_session
  C_HOME=$PT C_FIX=$F C_ENV="OMB_SESSION_SCOPES=profile"
  export C_HOME C_FIX C_ENV
  P=$T/state/profile.omb
  p_snap() { c_run snapshot "scope	name=profile"; }
  p_actions() { printf '%s\n' "$C_OUT" | awk -F '\t' '$1 == "action" { printf "%s ", $2 }'; }
  p_basis_of() { printf '%s\n' "$C_OUT" | awk -F '\t' -v a="id=$1" '$1 == "action" && $2 == a { for (i = 2; i <= NF; i++) if ($i ~ /^basis=/) { sub(/^basis=/, "", $i); print $i } }'; }
  p_gen() { printf '%s\n' "$C_OUT" | awk -F '\t' '$1 == "generation" { sub(/^id=/, "", $2); print $2 }'; }
  p_item() { # ID — the item's row in the items detail
    local g
    p_snap
    g=$(p_gen)
    c_run detail "page	scope=profile	kind=items	generation=$g	offset=0	limit=500"
    printf '%s\n' "$C_OUT" | grep "^row	kind=item	key=$1	"
  }
  p_save() { # DOC
    local b
    rec_line_v arg name select.1 value "$1
"
    c_run validate "select	action=profile.save" "$REC_LINE"
    b=$(printf '%s\n' "$C_OUT" | awk -F '\t' '$1 == "review" { sub(/^basis=/, "", $3); print $3 }')
    [ -n "$b" ] || b=$(printf '%064d' 0)
    rec_line_v arg name select.1 value "$1
"
    c_run execute "exec	action=profile.save	basis=$b	confirm=" "$REC_LINE"
  }
  p_snap
  c_run execute "exec	action=profile.scan	basis=$(p_basis_of profile.scan)	confirm="
  assert_eq "$(c_result)" "done ok" "secret-opaque: the scan saves"
  p_save 'omb-select 1
select	id=path:.myscripts	state=include'
  assert_eq "$(c_result)" "done ok" "secret-opaque: a selection including a chosen folder saves"
  assert_contains "$(p_item path:.myscripts)" "col=decide	col=opaque	col=person	col=waits%20for%20the%20typed%20word%20opaque" \
    "secret-opaque: the folder waits for the typed word"
  p_snap
  assert_contains "$(p_actions)" "id=profile.opaque" "secret-opaque: profile.opaque is offered"
  assert_contains "$C_OUT" "key=gate.profile.opaque.path.1	label=Opaque%20path	value=.myscripts%20%28" "secret-opaque: its gate lists every opaque path it covers"
  assert_contains "$C_OUT" "Shared%20is%20not%20encrypted" "secret-opaque: and says Shared is not encrypted"
  c_run execute "exec	action=profile.opaque	basis=$(p_basis_of profile.opaque)	confirm=yes"
  assert_eq "$(c_result)" "refused word" "secret-opaque: only the exact word opaque continues"
  if grep -q '^consent	' "$P"; then fail "secret-opaque: a wrong word left a consent"; else ok; fi
  p_snap
  c_run execute "exec	action=profile.opaque	basis=$(p_basis_of profile.opaque)	confirm=opaque"
  assert_eq "$(c_result)" "done ok" "secret-opaque: typed opaque includes it"
  assert_eq "$(awk -F '\t' '$1 == "consent" { print $2 "\t" $3 }' "$P")" "word=opaque	id=" "secret-opaque: one consent, for every opaque folder"
  assert_contains "$(p_item path:.myscripts)" "col=include	col=opaque	col=person" "secret-opaque: the folder now travels"
  p_save 'omb-select 1
select	id=path:.myscripts	state=include'
  assert_eq "$(c_result)" "done ok" "secret-opaque: the next save"
  if grep -q '^consent	word=opaque' "$P"; then fail "secret-opaque: a consent outlived its save"; else ok; fi
  assert_contains "$(p_item path:.myscripts)" "col=decide" "secret-opaque: each save asks again"

  # An encrypted key travels only after typed carry; no other key ever.
  assert_contains "$(p_item path:.ssh/id_ed25519)" "col=exclude	col=secret	col=default" "secret-carry: an encrypted key stays by default"
  p_snap
  assert_contains "$(p_actions)" "id=profile.carry" "secret-carry: profile.carry is offered"
  assert_contains "$C_OUT" "param	action=profile.carry	name=key	type=bytes	kind=item	required=1" "secret-carry: it takes the key's item id"
  gen=$(p_gen)
  carry() { # KEY WORD
    rec_line_v basis action profile.carry generation "$gen" value "$1"
    b=$(sha256_str "omb-basis 1
$REC_LINE
")
    rec_line_v arg name key value "$1"
    c_run execute "exec	action=profile.carry	basis=$b	confirm=$2" "$REC_LINE"
  }
  carry path:.ssh/id_plain carry
  assert_eq "$(c_result)" "failed no-effect" "secret-carry: an unencrypted key can never be carried"
  carry path:.ssh/id_weak carry
  assert_eq "$(c_result)" "failed no-effect" "secret-carry: nor one under a weak policy"
  carry path:.ssh/id_ed25519 yes
  assert_eq "$(c_result)" "refused word" "secret-carry: only the exact word carry continues"
  carry path:.ssh/id_ed25519 carry
  assert_eq "$(c_result)" "done ok" "secret-carry: typed carry includes the encrypted key"
  assert_contains "$(awk -F '\t' '$1 == "consent"' "$P")" "consent	word=carry	id=path:.ssh/id_ed25519	" "secret-carry: its consent is recorded"
  assert_contains "$(awk -F '\t' '$1 == "select"' "$P")" "select	id=path:.ssh/id_ed25519	state=include" "secret-carry: and it is selected"
  assert_contains "$(p_item path:.ssh/id_ed25519)" "col=include	col=secret	col=person" "secret-carry: the key now travels"
  assert_eq "$(grep -rl "$PLANT" "$T/state" "$SESS" 2>/dev/null)" "" "secret-profile: no planted value in the core's state, spools or diagnostics"
  rm -rf "$F"
fi

rm -rf "$T"
t_done test-secrets
