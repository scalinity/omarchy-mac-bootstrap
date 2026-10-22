#!/usr/bin/env bash
# Resolution (docs/RESOLVER.md): the migration map and the person's
# decisions, in fixed layers; one version per runtime; an item the map does
# not resolve becomes a decision, or a guess checked on Linux; a map that
# does not admit resolves nothing. Pure functions over files: nothing here
# reads the machine.
# shellcheck disable=SC2015 # ok/fail always return 0
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load
# shellcheck source=lib/records.sh
. "$REPO/lib/records.sh"
# shellcheck source=lib/migrate_resolve.sh
. "$REPO/lib/migrate_resolve.sh"
echo "test-resolve"

OMB_HOME=$REPO
T=$(t_tmp)
TMPDIR=$T
omb_tmp_init

# item ID KIND NAME VERSION [CLASS] [CATEGORY] — one profile item line.
item() {
  rec_line item id "$1" adapter test kind "$2" category "${6:-software}" name "$3" version "$4" source "" \
    requested yes evidence observed class "${5:-config}" path "" size "" note ""
}
decision() { rec_line decision id "$1" choice "$2" value "${3:-}"; }
# res ID — the resolution line of item ID in $T/out, fields after the id.
res() { awk -F'\t' -v k="id=$1" '$2 == k { $1 = ""; $2 = ""; sub(/^\t\t/, ""); print }' OFS='\t' "$T/out"; }
# want LAYER METHOD TARGET VERSION GUESS STATE — the written fields, before the note.
want() { printf 'layer=%s\tmethod=%s\ttarget=%s\tversion=%s\tguess=%s\tstate=%s' "$@"; }
fields() { res "$1" | cut -f1-6; }

# --- The map is admitted, and every entry says where it was confirmed --------------------------
res_map_load
assert_rc $? 0 "resolve-map-admits: data/migration-map.omb admits (${RES_WHY:-})"
[ "$RES_M_N" -ge 100 ] && ok || fail "the map covers the inventory: $RES_M_N entries"
assert_eq "$(grep -c '^map	' "$REPO/data/migration-map.omb")" "$(grep '^map	' "$REPO/data/migration-map.omb" | grep -c '	note=[^	]')" \
  "resolve-map-notes: every map entry records where its target was confirmed"
assert_eq "$(grep -c 'aur/\|method=aur' "$REPO/data/migration-map.omb")" 0 "the map never names the AUR"

# --- Fixed layers, in the items' order ----------------------------------------------------------
{
  item rg brew-formula rclone 1.71.0
  item gh brew-formula gh 2.80.0
  item node brew-formula node 26.12.0
  item fabric brew-formula fabric-ai 1.4.526
  item sc brew-formula shellcheck 0.11.0
  item fc npm firecrawl-cli 1.25.1
  item claude ai claude-code 2.1.308
  item gpd app com.github.GitHubClient 3.4.0
  item bat brew-formula bat 0.25.0
  item gitcfg git user.name "" config git-ssh
  item nvim file .config/nvim "" config editors
  item duti brew-formula duti 1.5.4
  item blender app org.blenderfoundation.blender 4.5
  item cache file Library/Caches/x "" mac-only folders
} >"$T/items"
res_resolve "$T/items" "" "$T/out"
assert_rc $? 0 "resolution runs"
assert_eq "$(cut -f2 "$T/out" | tr '\n' ' ')" "id=rg id=gh id=node id=fabric id=sc id=fc id=claude id=gpd id=bat id=gitcfg id=nvim id=duti id=blender id=cache " \
  "resolve-order: one resolution per item, in the items' order"
assert_eq "$(fields rg)" "$(want packages pacman rclone '' 0 resolved)" "resolve-layer-packages: Homebrew rclone is pacman rclone"
assert_eq "$(fields gh)" "$(want packages pacman github-cli '' 0 resolved)" "a native equivalent under another name"
assert_eq "$(fields node)" "$(want runtimes mise node 26 0 resolved)" "resolve-layer-runtimes: node through mise, its major version kept"
assert_eq "$(fields fabric)" "$(want tools mise-backend github:danielmiessler/fabric 1.4.526 0 resolved)" "resolve-layer-tools: a release binary through mise's GitHub backend, at the version this Mac has"
assert_eq "$(fields sc)" "$(want tools mise-backend aqua:koalaman/shellcheck 0.11.0 0 resolved)" "a mise backend for a CLI the repositories lack"
assert_eq "$(fields fc)" "$(want tools npm firecrawl-cli 1.25.1 0 resolved)" "an npm global under mise's node"
assert_eq "$(fields claude)" "$(want ai agent claude '' 0 resolved)" "resolve-layer-ai: Claude Code through Omarchy's agent wrapper's package"
assert_eq "$(fields gpd)" "$(want tools flatpak io.github.shiftey.Desktop '' 0 resolved)" "an application through Flathub"
assert_eq "$(fields bat)" "$(want packages provided pkg:bat '' 0 resolved)" "Omarchy-provided: the check Linux runs, nothing installed"
assert_eq "$(fields gitcfg)" "$(want settings git '' '' 0 resolved)" "resolve-layer-settings: Git settings through their owner"
assert_eq "$(fields nvim)" "$(want files carry '' '' 0 resolved)" "resolve-layer-files: configuration carried as files"
assert_eq "$(fields duti)" "$(want none none '' '' 0 mac-only)" "macOS-only software is shown, never installed"
assert_eq "$(fields blender)" "$(want none none '' '' 0 unsupported)" "no aarch64 build: unsupported"
assert_eq "$(fields cache)" "$(want none none '' '' 0 mac-only)" "mac-only configuration never travels"
assert_contains "$(res rg)" "note=map%20rclone" "every resolution names the map entry that produced it"

# The output is the profile's own record: it admits there.
{
  printf 'omb-profile 1\n'
  rec_line mac host 0123456789abcdef model "MacBookPro18,2" os 27.2 user alex home /Users/alex shell /bin/zsh at 2026-10-22T00:00:00Z
  cat "$T/items" "$T/out"
} >"$T/profile.omb"
rec_seal_write "$T/profile.omb"
rec_admit_file profile - "$T/profile.omb"
assert_rc $? 0 "resolve-schema: resolutions admit in a profile (${REC_REASON:-})"

# Deterministic: the same inputs give the same bytes; a rerun changes nothing.
res_resolve "$T/items" "" "$T/out2"
assert_eq "$(cksum <"$T/out2")" "$(cksum <"$T/out")" "resolve-deterministic: a rerun writes the same bytes"

# --- One version per runtime ---------------------------------------------------------------------
{
  item py12 brew-formula python@3.12 3.12.15
  item py14 brew-formula python@3.14 3.14.8_2
  item node brew-formula node 26.12.0
  item nvmnode nvm node v26.1.0
  item java mise java ""
} >"$T/rt"
res_resolve "$T/rt" "" "$T/out"
assert_eq "$(fields py12)" "$(want none none '' '' 0 needs-decision)" "resolve-runtime-one: two Python versions are a decision"
assert_eq "$(fields py14)" "$(want none none '' '' 0 needs-decision)" "for both of its items"
assert_contains "$(res py12)" "this%20Mac%20has%203.12%203.14" "the decision names the versions this Mac has"
assert_eq "$(fields nvmnode)" "$(want runtimes mise node 26 0 resolved)" "Homebrew's node 26 and nvm's v26 are one program, one version"
assert_eq "$(fields java)" "$(want none none '' '' 0 needs-decision)" "a runtime of unknown version is a decision, never latest"
res_choices "$T/rt" "$T/choices"
assert_eq "$(grep -c 'key=py12	col=version:3.12	' "$T/choices") $(grep -c 'key=py12	col=version:3.14	' "$T/choices")" "1 1" \
  "the choices offer each version this Mac has"
decision py14 version:3.14 >"$T/dec"
res_resolve "$T/rt" "$T/dec" "$T/out"
assert_eq "$(fields py12)" "$(want runtimes mise python 3.14 0 resolved)" "resolve-runtime-decision: the chosen version holds for every item of that runtime"
assert_eq "$(fields py14)" "$(want runtimes mise python 3.14 0 resolved)" "including the item that carried the decision"
assert_contains "$(res py12)" "decision%20version:3.14" "the resolution names the decision"
decision py12 version:3.11 >"$T/dec"
res_resolve "$T/rt" "$T/dec" "$T/out"
assert_eq "$(fields py12)" "$(want none none '' '' 0 needs-decision)" "a version this Mac does not have decides nothing"
decision java version:21 >"$T/dec"
res_resolve "$T/rt" "$T/dec" "$T/out"
assert_eq "$(fields java)" "$(want runtimes mise java 21 0 resolved)" "an unknown version takes the version the person names"

# --- Alternatives -------------------------------------------------------------------------------------
item chrome app com.google.Chrome 141.0 >"$T/alt"
res_resolve "$T/alt" "" "$T/out"
assert_eq "$(fields chrome)" "$(want none none '' '' 0 needs-decision)" "resolve-alternative: an alternative waits for the person"
res_choices "$T/alt" "$T/choices"
assert_eq "$(cut -f4 "$T/choices" | tr '\n' ' ')" "col=keep-default col=google-chrome col=skip " "its choices, from the map, in the map's order"
decision chrome google-chrome >"$T/dec"
res_resolve "$T/alt" "$T/dec" "$T/out"
assert_eq "$(fields chrome)" "$(want packages pacman omarchy/google-chrome '' 0 resolved)" "a chosen alternative, from Omarchy's repository, named with it"
decision chrome keep-default >"$T/dec"
res_resolve "$T/alt" "$T/dec" "$T/out"
assert_eq "$(fields chrome)" "$(want packages provided pkg:chromium '' 0 resolved)" "keep-default keeps Omarchy's own, checked on Linux"

# --- What the map does not name ------------------------------------------------------------------------
item odd brew-formula some-unknown-tool 1.0 >"$T/odd"
res_resolve "$T/odd" "" "$T/out"
assert_eq "$(fields odd)" "$(want none none '' '' 0 unresolved)" "resolve-unresolved: an item the map does not name is unresolved"
res_choices "$T/odd" "$T/choices"
assert_eq "$(cut -f4,6 "$T/choices" | tr '\n\t' ' :')" "col=skip:col=0 col=pacman:col=1 " "resolve-guess: its decision is skip, or try pacman, marked a guess"
decision odd pacman some-unknown-tool >"$T/dec"
res_resolve "$T/odd" "$T/dec" "$T/out"
assert_eq "$(fields odd)" "$(want packages pacman some-unknown-tool '' 1 resolved)" "try pacman NAME: resolved as a guess, checked on Linux"
decision odd skip >"$T/dec"
res_resolve "$T/odd" "$T/dec" "$T/out"
assert_eq "$(fields odd)" "$(want none none '' '' 0 skipped)" "skip leaves it out"
decision odd pacman 'x;reboot' >"$T/dec"
res_resolve "$T/odd" "$T/dec" "$T/out"
assert_eq "$(fields odd)" "$(want none none '' '' 0 unresolved)" "a package name outside pacman's grammar is never a target"

# --- A map that does not admit resolves nothing --------------------------------------------------------
# with_map — a copy of the tool's home whose map is $T/home/data/migration-map.omb.
mkdir -p "$T/home/data"
reseal() { sed '$d' "$1" >"$1.body" && mv "$1.body" "$1" && rec_seal_write "$1"; }
printf 'kept\n' >"$T/out"
cp "$REPO/data/migration-map.omb" "$T/home/data/migration-map.omb"
sed -i.bak 's/target=rclone/target=rclonex/' "$T/home/data/migration-map.omb" && rm -f "$T/home/data/migration-map.omb.bak"
OMB_HOME=$T/home res_resolve "$T/items" "" "$T/out"
assert_rc $? 1 "resolve-map-refused: a map whose seal fails resolves nothing"
assert_eq "$(cat "$T/out")" kept "and writes nothing"
assert_contains "$RES_WHY" "(seal at line" "the reason is the seal"
for change in 's/target=rclone/target=rg%3Breboot/' 's/name=rclone/name=gh/' 's/map=app-chrome	id=google-chrome/map=rclone	id=google-chrome/' \
  's/disposition=MACOS_ONLY	method=	target=/disposition=MACOS_ONLY	method=pacman	target=x/'; do
  cp "$REPO/data/migration-map.omb" "$T/home/data/migration-map.omb"
  sed -i.bak "$change" "$T/home/data/migration-map.omb" && rm -f "$T/home/data/migration-map.omb.bak"
  reseal "$T/home/data/migration-map.omb"
  OMB_HOME=$T/home res_resolve "$T/items" "" "$T/out"
  assert_rc $? 1 "a sealed map breaking a rule admission cannot state refuses ($change: ${RES_WHY:-})"
done
assert_eq "$(cat "$T/out")" kept "a refused map never touches the output"

# --- Kinds no map source names: a tap stays on macOS, an extension is the editor's ----------
res_map_load
{
  item tap:homebrew/cask-fonts tap homebrew/cask-fonts ""
  item vscode:ext:ms-python.python extension ms-python.python 2025.1 config editors
} >"$T/items"
res_resolve "$T/items" "" "$T/out"
assert_eq "$(fields tap:homebrew/cask-fonts)" "$(want none none '' '' 0 mac-only)" "resolve-kinds: a Homebrew tap is macOS-only, never carried"
assert_eq "$(fields vscode:ext:ms-python.python)" "$(want none none '' '' 0 unsupported)" "resolve-kinds: an editor extension is not installed or carried"

omb_cleanup
t_done test-resolve
