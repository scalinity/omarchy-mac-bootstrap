#!/usr/bin/env bash
# Export and the bundle check (docs/MIGRATION.md → *The bundle*): hash-named
# objects and one sealed bundle.omb, written as .partial-* and then renamed;
# a stop or a write failure leaving only .partial-*; nothing ever deleted;
# the size and free-space limits; a corrupt bundle refused by the bundle
# check; and the export side of the secret tests (secret-export-*): no
# planted secret in any byte written, a file whose captured bytes fail a
# rule left behind and reported. The scanner and the profile's identity are
# stand-ins here (a copy of the tool with its own lib/migrate_scan.sh and
# lib/migrate_profile.sh), driven by the fixture.
# shellcheck disable=SC2015,SC2016 # ok/fail always return 0; literal $ in single quotes
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load
# shellcheck source=lib/records.sh
. "$REPO/lib/records.sh"
# shellcheck source=lib/migrate_resolve.sh
. "$REPO/lib/migrate_resolve.sh"
# shellcheck source=lib/migrate_bundle.sh
. "$REPO/lib/migrate_bundle.sh"
echo "test-bundle"

OMB_HOME=$REPO
T=$(t_tmp)
TMPDIR=$T
omb_tmp_init
HOST=0123456789abcdef
PLANT_KEY='sk-ant-api03-PLANTEDsecretVALUE00000000000000000000000000000000'
PLANT_TOKEN='ghp_PLANTEDtoken0000000000000000000000'

# --- A copy of the tool whose scanner and profile identity are stand-ins --------------------
H=$T/tool
mkdir -p "$H"
cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$REPO/release" "$H/"
cat >"$H/lib/migrate_scan.sh" <<'EOF'
# shellcheck shell=bash
# Test stand-in for the scanner's seams: the fixture's scan/ folder says
# what the scan finds and what each item carries.
scan_cmd() { ui_fail "scan is a stand-in here."; return 1; }
scan_run() { cat "$OMB_FIXTURE/scan/items" >"$1"; }
scan_extract() {
  local n
  n=$(awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$OMB_FIXTURE/scan/index")
  [ -n "$n" ] && [ -d "$OMB_FIXTURE/scan/x/$n" ] || return 1
  cp -R "$OMB_FIXTURE/scan/x/$n/." "$2/"
}
scan_secret_check() {
  SCAN_HIT=""
  if grep -q 'sk-ant-' "$1"; then SCAN_HIT=anthropic-key && return 1; fi
  if grep -q 'ghp_[A-Za-z0-9]' "$1"; then SCAN_HIT=github-token && return 1; fi
  if grep -q 'PRIVATE KEY-----' "$1"; then SCAN_HIT=private-key && return 1; fi
  return 0
}
scan_key_check() { grep -q '^ENCRYPTED-ENVELOPE$' "$1"; }
EOF
cat >"$H/lib/migrate_profile.sh" <<'EOF'
# shellcheck shell=bash
# Test stand-in: this Mac's identity comes from the fixture.
prof_row() { return 1; }
prof_core_op() { core_result refused unavailable "The profile is a stand-in here."; }
prof_cmd() { ui_fail "profile is a stand-in here."; return 1; }
prof_host_id() { PROF_HOST_ID=$(cat "$OMB_FIXTURE/scan/host" 2>/dev/null); [ -n "$PROF_HOST_ID" ]; }
EOF

# --- The fixture: a Mac, its scan, and what each item carries ---------------------------------
# item ID KIND CLASS [SIZE] — one profile item line.
item() {
  rec_line item id "$1" adapter test kind "$2" category software name "$1" version 1.0 source "" \
    requested yes evidence observed class "$3" path "" size "${4:-}" note ""
}
# carry F N ID — item ID's capture is the fixture's scan/x/N; its records
# follow on stdin (rec_line output), into scan/x/N/carry.
carry() {
  mkdir -p "$1/scan/x/$2/f"
  printf '%s\t%s\n' "$3" "$2" >>"$1/scan/index"
  cat >"$1/scan/x/$2/carry"
}
# mkfix — a fixture: the roomy M1 Pro's probes, its free space, and a home
# whose items are listed below; prints its path.
mkfix() {
  local f
  f=$(t_variant mac-m1pro-1tb-roomy)
  mkdir -p "$f/scan/x"
  : >"$f/scan/index"
  printf '%s\n' "$HOST" >"$f/scan/host"
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 976490576 400000000 500000000 45%% /\n' >"$f/cmd/bndl_df"
  {
    item nvim file config
    item gitcfg git config
    item rclone brew-formula config
    item leaky file config
    item leaky-mcp mcp config
    item leaky-path file config
    item sshkey file secret
    item enckey file secret
    item plainkey file secret
    item dup file config
    item excluded file config
  } >"$f/scan/items"
  {
    rec_line dir dest .config/nvim mode 755
    rec_line file dest .config/nvim/init.lua src f/init.lua mode 644 whole 1
    rec_line file dest .config/nvim/run.sh src f/run.sh mode 755 whole 1
    rec_line file dest .config/nvim/copy.lua src f/copy.lua mode 644 whole 1
    rec_line link dest .config/nvim/latest target init.lua
    rec_line macpath dest .config/nvim/init.lua path /Users/alex/notes
  } | carry "$f" 1 nvim
  printf 'vim.o.number = true -- /Users/alex/notes\n' >"$f/scan/x/1/f/init.lua"
  cp "$f/scan/x/1/f/init.lua" "$f/scan/x/1/f/copy.lua"
  printf '#!/bin/sh\necho hi\n' >"$f/scan/x/1/f/run.sh"
  {
    rec_line setting kind git tool git name user.name value "Alex Example"
    rec_line setting kind git tool git name core.editor value nvim
  } | carry "$f" 2 gitcfg
  rec_line file dest .config/leaky/conf src f/conf mode 644 whole 1 | carry "$f" 3 leaky
  printf 'api_key = "%s"\n' "$PLANT_KEY" >"$f/scan/x/3/f/conf"
  rec_line setting kind mcp tool claude name github value "{\"env\":{\"TOKEN\":\"$PLANT_TOKEN\"}}" | carry "$f" 4 leaky-mcp
  {
    rec_line file dest .config/clean/conf src f/conf mode 644 whole 1
    rec_line macpath dest .config/clean/conf path "/Users/alex/$PLANT_KEY/notes"
  } | carry "$f" 11 leaky-path
  printf 'clean = true\n' >"$f/scan/x/11/f/conf"
  rec_line file dest .ssh/id_ed25519 src f/key mode 600 whole 1 | carry "$f" 5 sshkey
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nPLANTEDKEYMATERIAL\n-----END OPENSSH PRIVATE KEY-----\n' >"$f/scan/x/5/f/key"
  rec_line file dest .ssh/id_enc src f/key mode 600 whole 1 | carry "$f" 9 enckey
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nENCRYPTED-ENVELOPE\n-----END OPENSSH PRIVATE KEY-----\n' >"$f/scan/x/9/f/key"
  rec_line file dest .ssh/id_plain src f/key mode 600 whole 1 | carry "$f" 10 plainkey
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nPLANTEDPLAINKEY\n-----END OPENSSH PRIVATE KEY-----\n' >"$f/scan/x/10/f/key"
  rec_line file dest .config/nvim/init.lua src f/other mode 644 whole 1 | carry "$f" 6 dup
  printf 'another init.lua\n' >"$f/scan/x/6/f/other"
  rec_line file dest .config/excluded src f/x mode 644 whole 1 | carry "$f" 7 excluded
  printf 'not selected\n' >"$f/scan/x/7/f/x"
  printf '%s' "$f"
}

# mkprofile FIXTURE STATE [HOST] [EXTRA_ITEMS_FILE] — a saved profile in
# STATE: the fixture's items, a gone one, a selection and the resolutions.
mkprofile() {
  local f=$1 s=$2 host=${3:-$HOST} id st
  mkdir -p "$s" && chmod 700 "$s"
  { cat "$f/scan/items" && item gone file config && { [ -z "${4:-}" ] || cat "$4"; }; } >"$T/p.items"
  res_resolve "$T/p.items" "" "$T/p.res" || fail "the profile's resolution"
  {
    printf 'omb-profile 1\n'
    rec_line mac host "$host" model "MacBookPro18,2" os 27.2 user alex home /Users/alex shell /bin/zsh at 2026-10-22T00:00:00Z
    cat "$T/p.items"
    while IFS= read -r id; do
      st=include
      [ "$id" = excluded ] && st=exclude
      rec_line select id "$id" state "$st"
    done <<EOF
$(cut -f2 "$T/p.items" | sed 's/^id=//')
EOF
    for id in enckey plainkey; do rec_line consent word carry id "$id" at 2026-10-22T00:00:00Z; done
    cat "$T/p.res"
  } >"$s/profile.omb"
  rec_seal_write "$s/profile.omb"
  chmod 600 "$s/profile.omb"
}

# export_cli FIXTURE STATE INPUT ARGS... — the tool's copy, as the person runs it.
export_cli() {
  local f=$1 s=$2 in=$3
  shift 3
  T_ENV="OMB_STATE_DIR=$s ${T_ENV2:-}" t_cli "$f" "$in" export "$@"
}
# t_cli runs $REPO's entrypoint; the copy's is the one with the stand-ins.
REPO_REAL=$REPO
t_cli_copy() { REPO=$H; "$@"; REPO=$REPO_REAL; }

# bundles DIR — the names under DIR's bundles folder.
bundles() {
  local e
  for e in "$1"/omarchy-mac-bootstrap/bundles/* "$1"/omarchy-mac-bootstrap/bundles/.[!.]*; do
    [ -e "$e" ] || [ -L "$e" ] && printf '%s ' "${e##*/}"
  done
}
# rec_lines FILE TYPE — the admitted records of TYPE in bundle.omb FILE.
blines() { grep "^$2	" "$1"; }

# --- Export through the text interface ------------------------------------------------------------
F=$(mkfix)
S=$T/state
D=$T/usb
mkdir -p "$D"
mkprofile "$F" "$S"
t_cli_copy export_cli "$F" "$S" 'y\n' "$D"
assert_rc "$T_RC" 0 "bundle-write: export to a named folder succeeds ($(t_flat "$T_OUT" | tail -c 300))"
assert_contains "$T_OUT" "Bundle written" "it says where"
B=$(bundles "$D")
B=${B% }
case "$B" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ok ;;
  *) fail "bundle-rename: one finished bundle named by its UTC time, no .partial-* left: [$B]" ;;
esac
BD=$D/omarchy-mac-bootstrap/bundles/$B
bndl_check "$BD"
assert_rc $? 0 "bundle-check: the finished bundle passes the bundle check (${BNDL_WHY:-})"
M=$BD/bundle.omb
rec_admit_file bundle - "$M"
assert_rc $? 0 "bundle.omb admits, sealed"
# Objects: plain files named by their own SHA-256, each once, only those listed.
bad=""
for o in "$BD"/objects/*; do
  _bndl_sha "$o"
  [ "${o##*/}" = "$BNDL_SHA" ] && [ -f "$o" ] && [ ! -L "$o" ] || bad="$bad ${o##*/}"
done
assert_eq "$bad" "" "bundle-objects: every object is named by the SHA-256 of its bytes"
set -- "$BD"/objects/*
assert_eq "$#" 3 "a file carried twice is stored once (init.lua and its copy), with run.sh and the key: three objects"
assert_eq "$(blines "$M" file | grep -c .)" 4 "four file entries"
assert_contains "$(blines "$M" file | grep 'dest=.config/nvim/run.sh')" "mode=0755" "an executable keeps an execute bit, as 0755"
assert_contains "$(blines "$M" file | grep 'dest=.config/nvim/init.lua')" "mode=0644" "a config file is 0644"
assert_contains "$(blines "$M" dir)" "dest=.config/nvim	mode=0755" "a folder entry"
assert_contains "$(blines "$M" link)" "dest=.config/nvim/latest	target=init.lua" "a link entry, its text relative"
assert_contains "$(blines "$M" macpath)" "path=/Users/alex/notes" "a macOS path in a file carried whole is listed, not rewritten"
assert_contains "$(blines "$M" setting)" "name=user.name	value=Alex%20Example" "Git settings travel as records"
assert_contains "$(blines "$M" package)" "item=rclone	layer=packages	method=pacman	target=rclone" "packages from the profile's resolution"
assert_contains "$(blines "$M" bundle)" "host=$HOST" "the bundle names the Mac it came from"
assert_contains "$(blines "$M" bundle)" "items=4	files=4" "and its counts"
assert_contains "$(blines "$M" file | grep 'dest=.ssh/id_enc')" "mode=0600" "secret-export-carry: an encrypted key travels after its typed carry, 0600"
assert_contains "$(blines "$M" item | grep 'id=enckey')" "class=secret" "marked secret in the bundle"
skips=$(blines "$M" skip)
assert_contains "$skips" "item=leaky	reason=left%20behind:%20a%20credential%20shape%20%28anthropic-key%29" "secret-export-left-behind: a capture that fails the scan leaves its item behind, by kind"
assert_contains "$skips" "item=leaky-mcp	reason=left%20behind:%20a%20credential%20shape%20%28github-token%29%20in%20a%20setting" "and a setting that does"
assert_contains "$skips" "item=leaky-path	reason=left%20behind:%20a%20credential%20shape%20%28anthropic-key%29%20in%20what%20its%20records%20name" \
  "and an item whose records would name one (a macOS path here)"
assert_contains "$skips" "item=sshkey	reason=secret:" "a secret never travels without its typed carry"
assert_contains "$skips" "item=plainkey	reason=left%20behind:%20the%20key" "a key whose captured bytes are not encrypted stays behind, carry or not"
assert_contains "$skips" "item=gone	reason=gone:" "an item no longer on this Mac is reported and left out"
assert_contains "$skips" "item=dup	reason=left%20behind:%20two%20entries%20with%20one%20destination" "an item whose destination another item holds is left behind whole"
assert_not_contains "$(cat "$M")" "item=excluded" "an excluded item is nowhere in the bundle"
assert_contains "$T_OUT" "leaky: left behind: a credential shape (anthropic-key)" "the person is told what was left behind, by kind"
assert_contains "$(cat "$S/state.env")" "export_last=$BD" "where the last bundle went is recorded"
# secret-export: no planted secret in any byte written — the bundle, the
# state, the log and the output alike.
hits=$(grep -rl 'PLANTED' "$D" "$S" 2>/dev/null)
assert_eq "$hits" "" "secret-export-no-planted-secret: no planted secret in any byte written"
assert_not_contains "$T_OUT" "PLANTED" "nor in what export prints"
assert_empty_file "$T_DIR/shims.log" "export runs no forbidden command"
assert_empty_file "$T_DIR/record" "export runs nothing through run"

# --- Nothing deleted; a rerun writes a new bundle beside the old ------------------------------------
printf 'mine\n' >"$D/omarchy-mac-bootstrap/bundles/notes.txt"
mkdir -p "$D/omarchy-mac-bootstrap/bundles/20200101T000000Z.partial-abcdef"
before=$(t_snapshot "$D")
sleep 1
t_cli_copy export_cli "$F" "$S" 'y\n' "$D"
assert_rc "$T_RC" 0 "bundle-rerun: a second export succeeds"
after=$(t_snapshot "$D")
missing=$(printf '%s\n' "$before" | while IFS= read -r l; do printf '%s\n' "$after" | grep -qxF "$l" || printf '%s\n' "$l"; done)
assert_eq "$missing" "" "bundle-nothing-deleted: every earlier path and byte is still there (the first bundle, a stray file, an old partial)"
assert_eq "$(bundles "$D" | wc -w | tr -d ' ')" 4 "a new bundle beside them"

# --- A decline, a dry run: nothing written ------------------------------------------------------------
D2=$T/usb2
mkdir -p "$D2"
t_cli_copy export_cli "$F" "$S" 'n\n' "$D2"
assert_rc "$T_RC" 0 "declining is not an error"
assert_eq "$(ls -A "$D2")" "" "bundle-decline: Enter or n writes nothing"
S2=$T/state-dry
mkprofile "$F" "$S2"
before=$(t_snapshot "$S2")
t_cli_copy export_cli "$F" "$S2" '' "$D2" --dry-run
assert_rc "$T_RC" 0 "a dry run completes"
assert_contains "$T_OUT" "Dry run: nothing was written" "and says so"
assert_eq "$(ls -A "$D2")" "" "bundle-dry-run: a dry run writes nothing at the destination"
assert_eq "$(t_snapshot "$S2")" "$before" "nor in the state folder"

# --- Stops and write failures leave only .partial-* ---------------------------------------------------
for at in bundle-object bundle-manifest; do
  D3=$T/stop-$at
  mkdir -p "$D3"
  T_ENV2="OMB_TEST_STOP_AT=$at" t_cli_copy export_cli "$F" "$S" 'y\n' "$D3"
  assert_rc "$T_RC" 137 "bundle-stop: a stop at $at ends the run there"
  case "$(bundles "$D3")" in *T*Z.partial-??????" ") ok ;; *) fail "bundle-stop: a stop at $at leaves only .partial-*: [$(bundles "$D3")]" ;; esac
  D3=$T/fail-$at
  mkdir -p "$D3"
  T_ENV2="OMB_TEST_FAIL_AT=$at" t_cli_copy export_cli "$F" "$S" 'y\n' "$D3"
  assert_rc "$T_RC" 1 "bundle-write-failure: a write that fails at $at stops export"
  case "$(bundles "$D3")" in *T*Z.partial-??????" ") ok ;; *) fail "bundle-write-failure: a failure at $at leaves only .partial-*: [$(bundles "$D3")]" ;; esac
  assert_contains "$(t_flat "$T_OUT")" "which restore never lists" "the person is told what is left, and that it is inert"
done
P=$(ls -d "$T"/stop-bundle-manifest/omarchy-mac-bootstrap/bundles/*.partial-*)
rec_admit_file bundle - "$P/bundle.omb"
assert_rc $? 0 "a stop after the manifest leaves it sealed, still unrenamed"
D3=$T/fail-bundle-rename
mkdir -p "$D3"
T_ENV2="OMB_TEST_FAIL_AT=bundle-rename" t_cli_copy export_cli "$F" "$S" 'y\n' "$D3"
assert_rc "$T_RC" 1 "a rename that fails stops export"
case "$(bundles "$D3")" in *T*Z.partial-??????" ") ok ;; *) fail "a failed rename leaves the whole bundle as .partial-*: [$(bundles "$D3")]" ;; esac

# --- The limits: free space, 2 GiB, 64 MiB -------------------------------------------------------------
D4=$T/full
mkdir -p "$D4"
F4=$T/fix-full
cp -R "$F" "$F4"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk5s1 1000 999 1 99%% /Volumes/USB\n' >"$F4/cmd/bndl_df"
t_cli_copy export_cli "$F4" "$S" 'y\n' "$D4"
assert_rc "$T_RC" 1 "bundle-free-space: a destination without room refuses"
assert_contains "$(t_flat "$T_OUT")" "bytes free; the bundle needs" "and says how much it needs"
assert_eq "$(ls -A "$D4")" "" "nothing is written before the free space is known"
rm -f "$F4/cmd/bndl_df"
t_cli_copy export_cli "$F4" "$S" 'y\n' "$D4"
assert_contains "$(t_flat "$T_OUT")" "free space at $D4 cannot be read" "free space that cannot be read refuses too"
assert_eq "$(ls -A "$D4")" "" "and writes nothing"
item huge file config 3000000000 >"$T/extra"
S5=$T/state-big
mkprofile "$F" "$S5" "$HOST" "$T/extra"
t_cli_copy export_cli "$F" "$S5" 'y\n' "$D4"
assert_rc "$T_RC" 1 "bundle-size: selected files over 2 GiB refuse"
assert_contains "$(t_flat "$T_OUT")" "over the 2 GiB a bundle may hold" "and say why"
assert_eq "$(ls -A "$D4")" "" "before anything is captured or written"
F6=$T/fix-big
cp -R "$F" "$F6"
item bigfile file config >>"$F6/scan/items"
rec_line file dest .config/big src f/big mode 644 whole 1 | carry "$F6" 8 bigfile
head -c $((BNDL_MAX_OBJECT + 1)) /dev/zero >"$F6/scan/x/8/f/big"
S6=$T/state-bigfile
mkprofile "$F6" "$S6"
D6=$T/usb6
mkdir -p "$D6"
t_cli_copy export_cli "$F6" "$S6" 'y\n' "$D6"
assert_rc "$T_RC" 0 "an export with a file over 64 MiB still runs"
M6=$(ls -d "$D6"/omarchy-mac-bootstrap/bundles/*/bundle.omb)
assert_contains "$(blines "$M6" skip)" "item=bigfile	reason=too-large:" "bundle-object-size: a file over 64 MiB is skipped as too-large"
assert_not_contains "$(blines "$M6" file)" "dest=.config/big" "and never becomes an object"

# --- The profile and the destination it needs -------------------------------------------------------------
t_cli_copy export_cli "$F" "$T/state-none" 'y\n' "$D2"
assert_rc "$T_RC" 1 "bundle-no-profile: export needs a profile"
assert_contains "$(t_flat "$T_OUT")" "No profile is saved" "and says so"
mkprofile "$F" "$T/state-other" fedcba9876543210
t_cli_copy export_cli "$F" "$T/state-other" 'y\n' "$D2"
assert_rc "$T_RC" 1 "bundle-other-mac: a profile made on another Mac is never used"
assert_contains "$(t_flat "$T_OUT")" "made on another Mac" "and says so"
item undecided brew-formula config >"$T/extra"
mkprofile "$F" "$T/state-open" "$HOST" "$T/extra"
t_cli_copy export_cli "$F" "$T/state-open" 'y\n' "$D2"
assert_rc "$T_RC" 1 "bundle-not-saved: an included item that needs a decision stops export"
assert_contains "$(t_flat "$T_OUT")" "still needs a decision (unresolved)" "and says which state"
printf 'x' >>"$S2/profile.omb"
t_cli_copy export_cli "$F" "$S2" 'y\n' "$D2"
assert_rc "$T_RC" 1 "a profile whose seal fails is never used"
assert_eq "$(ls -A "$D2")" "" "and none of these writes anything"
t_cli_copy export_cli "$F" "$S" 'y\n' relative/dir
assert_contains "$(t_flat "$T_OUT")" "full path" "a folder named by a relative path is refused"
t_cli_copy export_cli "$F" "$S" 'y\n'
assert_rc "$T_RC" 1 "bundle-no-shared: without a folder, export needs verified Shared"
assert_contains "$(t_flat "$T_OUT")" "Shared is not verified on this disk" "and says so"

# Verified Shared: the mount point the baseline finds for Shared's GUID.
if t_plutil "export to verified Shared"; then
  U_ROOT=4A7B1C2D-0006-4E5F-8A9B-000000000006
  choices='\n\n\n\n\n\n\n\n\n\n'
  SS=$T/state-shared
  T_ENV="OMB_STATE_DIR=$SS" t_cli mac-m1pro-1tb-roomy "\n4\n\n$choices" plan
  digest=$(sed -n 's/^digest=//p' "$SS/shared-intent.env" | cut -c1-8)
  printf 'shared_linux_done=%s\n' "$(code_make ombdone "$digest" "$U_ROOT")" >>"$SS/state.env"
  FS=$T/fix-shared
  cp -R "$FIX/mac-shared-created" "$FS"
  cp -R "$F/scan" "$FS/scan"
  cp "$F/cmd/bndl_df" "$FS/cmd/bndl_df"
  mkdir -p "$FS/root/Volumes/Shared"
  mkprofile "$FS" "$SS"
  t_cli_copy export_cli "$FS" "$SS" 'y\n'
  assert_rc "$T_RC" 0 "bundle-shared: export finds verified Shared by itself"
  assert_eq "$(bundles "$FS/root/Volumes/Shared" | wc -w | tr -d ' ')" 1 "and writes the bundle there"
fi

# --- The bundle check refuses a corrupt bundle whole ------------------------------------------------------
# mkb DIR RECORD... — a bundle with one object ("hello\n") and these records
# after its bundle record, sealed.
OBJ=$(printf 'hello\n' | shasum -a 256 2>/dev/null || printf 'hello\n' | sha256sum)
OBJ=${OBJ%% *}
mkb() {
  local d=$1 r
  shift
  mkdir -p "$d/objects"
  printf 'hello\n' >"$d/objects/$OBJ"
  {
    printf 'omb-bundle 1\n'
    rec_line bundle at 2026-10-22T00:00:00Z host "$HOST" model M user alex home /Users/alex items 1 files 1 bytes 6
    for r in "$@"; do printf '%s\n' "$r"; done
  } >"$d/bundle.omb"
  rec_seal_write "$d/bundle.omb"
}
I1=$(rec_line item id i class config whole 0)
DIR1=$(rec_line dir item i dest .config/x mode 0755)
FILE1=$(rec_line file item i dest .config/x/a mode 0644 sha256 "$OBJ" size 6 whole 0)
fl() { rec_line file item i dest "$1" mode 0644 sha256 "$OBJ" size 6 whole 0; }
lk() { rec_line link item i dest "$1" target "$2"; }
check() {
  local d
  d=$(mktemp -d "$T/b.XXXXXX")
  mkb "$d" "$@"
  bndl_check "$d"
}
check "$I1" "$DIR1" "$FILE1" "$(lk .config/x/b a)"
assert_rc $? 0 "a well-formed bundle passes"
d=$(mktemp -d "$T/b.XXXXXX")
mkb "$d" "$I1" "$FILE1"
printf 'x' >"$d/._bundle.omb" && printf 'x' >"$d/.DS_Store" && printf 'x' >"$d/objects/._$OBJ"
bndl_check "$d"
assert_rc $? 0 "the ._* and .DS_Store files macOS leaves are never read"
sed -i.bak 's/dest=.config\/x\/a/dest=.config\/x\/z/' "$d/bundle.omb" && rm -f "$d/bundle.omb.bak"
bndl_check "$d"
assert_rc $? 1 "bundle-corrupt-seal: an edited bundle.omb fails its seal"
assert_contains "$BNDL_WHY" "(seal at line" "and the seal is named"
d=$(mktemp -d "$T/b.XXXXXX")
mkb "$d" "$I1" "$FILE1"
printf 'jello\n' >"$d/objects/$OBJ"
bndl_check "$d"
assert_rc $? 1 "bundle-corrupt-digest: an object whose bytes changed is refused"
assert_contains "$BNDL_WHY" "does not match its digest" "by its digest"
printf 'hello!\n' >"$d/objects/$OBJ"
bndl_check "$d"
assert_contains "$BNDL_WHY" "not the size" "an object of another size is refused"
rm -f "$d/objects/$OBJ"
ln -s /etc/hosts "$d/objects/$OBJ"
bndl_check "$d"
assert_contains "$BNDL_WHY" "missing or not a plain file" "bundle-corrupt-object-link: an object that is a link is refused"
for bad in ../a /etc/passwd ".config/./a" ".config//a" "$(printf '.config/a\001b')" "$(printf '%0256d' 0)/a" \
  "$(printf 'a/%.0s' $(seq 1 32))a"; do
  check "$I1" "$(fl "$bad")"
  assert_rc $? 1 "bundle-corrupt-dest: the destination [$(printf '%s' "$bad" | cut -c1-40)] is refused"
done
check "$I1" "$(fl .config/x/a)" "$(fl .config/x/a)"
assert_rc $? 1 "bundle-corrupt-duplicate: two entries with one destination are refused"
assert_contains "$BNDL_WHY" "two entries with one destination" "and named"
check "$I1" "$(fl .config/x/l/b)" "$(lk .config/x/l a)"
assert_rc $? 1 "bundle-corrupt-beneath-link: an entry beneath a link is refused"
assert_contains "$BNDL_WHY" "beneath a file or a link" "and named"
check "$I1" "$(rec_line dir item i dest .config/f/sub mode 0755)" "$(fl .config/f)"
assert_rc $? 1 "a file where a folder is needed is refused"
check "$I1" "$(lk .config/l ../../../etc/passwd)"
assert_rc $? 1 "a link whose target climbs out of the home is refused"
check "$I1" "$(lk .config/l /etc/passwd)"
assert_rc $? 1 "a link with an absolute target is refused"
check "$I1" "$(lk .config/l ../.ssh/config)"
assert_rc $? 0 "a link to elsewhere inside the home is kept"
check "$I1" "$(rec_line file item i dest .config/big mode 0644 sha256 "$OBJ" size $((BNDL_MAX_OBJECT + 1)) whole 0)"
assert_rc $? 1 "an object over 64 MiB is refused"

# --- The row export.write through the core ---------------------------------------------------------------
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
c_session
C_FIX=$F C_HOME=$H C_STATE=$T/core-state C_ENV="OMB_SESSION_SCOPES=export"
mkprofile "$F" "$T/core-state"
c_run snapshot "scope	name=export"
assert_eq "$(c_result)" "done ok" "bundle-row-snapshot: the export scope answers ($C_ERR)"
assert_eq "$(c_admits snapshot)" ok "its answer admits"
assert_contains "$C_OUT" "key=export.profile	label=Profile	value=saved	state=ok" "the profile's state"
assert_contains "$C_OUT" "key=export.dest	label=Destination	value=none:%20name%20a%20folder" "no verified Shared on this disk"
assert_contains "$C_OUT" "action	id=export.write	scope=export" "the row export.write"
assert_contains "$C_OUT" "param	action=export.write	name=dir	type=bytes" "with its folder parameter"
# Validation answers export.write's review basis. Until lib/core.sh routes
# `validate select action=export.write` to the export scope, the copy of
# the tool here carries that route.
if ! grep -q 'CORE_REQ_SELECT" = export.write' "$H/lib/core.sh"; then
  awk '/elif \[ "\$CORE_REQ_SELECT" != plan.save \]/ {
      print "      elif [ \"$CORE_REQ_SELECT\" = export.write ] && core_in_scopes export; then"
      print "        core_mod_for export"
      print "        core_mod_load export"
      print "        . \"$OMB_HOME/lib/read.sh\" || _omb_unloaded read"
      print "        bndl_core_op validate"
    } { print }' "$REPO/lib/core.sh" >"$H/lib/core.sh"
fi
D7=$T/core-usb
mkdir -p "$D7"
c_run validate "select	action=export.write" "arg	name=dir	value=$T/not-there"
assert_eq "$(c_result)" "refused invalid" "bundle-row-validate: a folder that does not exist is refused ($C_ERR)"
assert_contains "$C_OUT" "invalid	name=dir	code=no-destination" "the parameter is named"
c_run validate "select	action=export.write" "arg	name=dir	value=$D7"
assert_eq "$(c_result)" "done ok" "validation answers the folder"
assert_eq "$(c_admits validate)" ok "its answer admits"
b=$(printf '%s\n' "$C_OUT" | sed -n 's/^review	action=export.write	basis=//p')
assert_eq "${#b}" 64 "with the review basis execute must send"
c_run execute "exec	action=export.write	basis=$(printf '%064d' 0)	confirm=" "arg	name=dir	value=$D7"
assert_eq "$(c_result)" "refused changed" "a basis that is not the fresh read's is refused"
assert_eq "$(ls -A "$D7")" "" "and writes nothing"
c_run execute "exec	action=export.write	basis=$b	confirm=" "arg	name=dir	value=$D7"
assert_eq "$(c_result)" "done ok" "bundle-row-execute: export.write writes the bundle ($C_ERR)"
assert_eq "$(c_admits execute)" ok "its answer admits"
assert_eq "$(bundles "$D7" | wc -w | tr -d ' ')" 1 "one bundle at the folder named"
assert_eq "$(ls "$T/core-state/ops" 2>/dev/null)" "" "the operation record is gone: the classifier saw the bundle"
c_run snapshot "scope	name=export"
assert_contains "$C_OUT" "key=export.last" "the snapshot names the last bundle"
assert_contains "$C_OUT" "core-usb/omarchy-mac-bootstrap/bundles/" "where it went"

omb_cleanup
t_done test-bundle
