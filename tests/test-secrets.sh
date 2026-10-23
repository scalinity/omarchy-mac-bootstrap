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
# Codex's conversion holds its arguments and URLs to the same rules.
CX=$(t_variant mig-mac-home)
cat >"$CX/root/Users/alex/.codex/config.toml" <<'EOF'
[mcp_servers.svc]
command = "svc"
args = ["--key=harborpassKEY3", "--auth=harborpassAUTH3", "https://example.test/mcp?token=harborpassURL3", "--port", "8080"]

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
k_key() { # FILE PARTS — a synthetic envelope, its key's strings cut after PARTS of: pub, private, a short private
  {
    printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n'
    {
      printf 'openssh-key-v1\000'
      k_str aes256-ctr && k_str bcrypt && k_u32 24 && k_u32 16 && printf 'FIXTURESALT00000' && k_u32 16 && k_u32 1
      case "$2" in
        pub) k_str "ssh-ed25519 FIXTURE PUBLIC KEY" ;;
        whole) k_str "ssh-ed25519 FIXTURE PUBLIC KEY" && k_str "FIXTURE PRIVATE SECTION, NOT A KEY" ;;
        short) k_str "ssh-ed25519 FIXTURE PUBLIC KEY" && k_u32 400 && printf 'FIXTURE PRIVATE SECTION' ;;
      esac
    } | base64 | tr -d '\n' | fold -w 70
    printf '\n-----END OPENSSH PRIVATE KEY-----\n'
  } >"$1"
}
for parts in none pub short; do
  k_key "$T/torn-$parts" "$parts"
  scan_ssh_key "$T/torn-$parts"
  assert_eq "$SCAN_KEY" malformed "secret-ssh-torn: an envelope cut after its key count ($parts) is malformed"
  scan_key_check "$T/torn-$parts"
  assert_rc $? 1 "secret-ssh-torn: and is never carried ($parts)"
done
k_key "$T/torn-whole" whole
scan_key_check "$T/torn-whole"
assert_rc $? 0 "secret-ssh-torn: the same envelope whole is an encrypted key"
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
  printf '%s\n' '{"mcpServers":{"svc":{"command":"svc","args":["--key=harborpassKEY4","--auth=harborpassAUTH4","https://example.test/mcp?%74oken=harborpassURL6","--port","8080"]}}}' >"$V/root/Users/alex/.claude.json"
  printf '[remote "origin"]\n\turl = https://example.test/app.git?%%74oken=harborpassREMOTE1\n' >"$V/root/Users/alex/code/app/.git/config"
  (
    OMB_FIXTURE=$V
    scan_extract claude:mcp:svc "$T/x-cmcp" >/dev/null 2>&1
    scan_run "$T/inv-url" >/dev/null 2>&1
    omb_cleanup
  )
  assert_eq "$(grep -rl harborpass "$T/x-cmcp")" "" "secret-args: no credential argument or URL in Claude's MCP server"
  assert_contains "$(cat "$T/x-cmcp/carry")" "%22args%22:%5B%22--port%22,%228080%22%5D" "secret-args: its other arguments stay"
  if grep -q harborpass "$T/inv-url"; then fail "secret-url: a remote's encoded credential reached the inventory"; else ok; fi
  assert_contains "$(grep 'id=project:code/app' "$T/inv-url")" "its%20remote%20holds%20a%20credential" "secret-url: the remote is withheld, saying why"

  # secret-opencode-dotted (S1) and secret-opencode-command (S2): OpenCode's
  # file is rebuilt from allowlisted fields, so a server or provider whose
  # name a key path cannot address is left out, and its command is held to
  # the argument rules.
  printf '%s\n' '{"theme":"system","plugin":["opencode-x"],"corp.extra":"harborpassTOP1",
    "mcp":{"corp.mcp":{"type":"remote","url":"https://mcp.example.test","headers":{"Authorization":"Bearer harborpassHDR1"}},
           "local":{"type":"local","command":["server","--token","harborpassCMD1","--api-key=harborpassCMD2","--port","8080"],
                    "environment":{"MODE":"harborpassENV1"},"oauth":{"clientSecret":"harborpassOA"}}},
    "provider":{"corp.ai":{"options":{"apiKey":"harborpassPROV1"}},
                "anthropic":{"npm":"@ai-sdk/anthropic","options":{"apiKey":"harborpassPROV2","baseURL":"https://api.example.test"}}}}' \
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
