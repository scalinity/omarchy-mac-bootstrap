#!/usr/bin/env bash
# Selection and the sealed profile (lib/migrate_profile.sh; docs/MIGRATION.md
# → *Selection*, *The Migration Profile*, *On the wire*): one omb-select
# document; the profile sealed and bound to this Mac; a rescan keeping
# choices by item id and reporting what is gone and new; a stop and a write
# failure at the save; a rerun that changes nothing; another Mac's profile
# invalid. The rows are driven through the core as the frontend drives them.
#
# The resolution unit (lib/migrate_resolve.sh) is replaced by a stand-in in a
# copy of the tool, so these cases hold the profile's own behaviour whatever
# the migration map says.
# shellcheck disable=SC2010,SC2015,SC2016,SC2030,SC2031 # ls|grep over our own state names; ok/fail always return 0; literal $ in stand-in source; subshell locals on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load
# shellcheck source=lib/records.sh
. "$REPO/lib/records.sh"
echo "test-profile"

T=$(t_tmp)
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"

# p_tool DIR — a copy of the tool whose resolution is a fixed stand-in.
p_tool() {
  mkdir -p "$1"
  cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$1/"
  cat >"$1/lib/migrate_resolve.sh" <<'EOF'
# shellcheck shell=bash
# A test stand-in for the resolution unit's seam.
res_resolve() {
  LC_ALL=C awk -F '\t' '
    function fld(k,   i) { for (i = 2; i <= NF; i++) if (index($i, k "=") == 1) return substr($i, length(k) + 2); return "" }
    FILENAME == ARGV[1] && ARGV[1] != ARGV[2] { if ($1 == "decision") { D[fld("id")] = fld("choice"); V[fld("id")] = fld("value") }; next }
    $1 == "item" {
      id = fld("id"); k = fld("kind"); n = fld("name"); cl = fld("class"); g = 0; t = ""; v = ""
      if (id in D && D[id] == "skip") { st = "skipped"; ly = "none"; m = "none" }
      else if (id in D) { st = "resolved"; ly = "packages"; m = "pacman"; t = V[id]; g = 1 }
      else if (cl == "mac-only") { st = "mac-only"; ly = "none"; m = "none" }
      else if (k == "nvm" || k == "mise" || k == "asdf") { st = "resolved"; ly = "runtimes"; m = "mise"; t = n; v = fld("version") }
      else if (n == "mystery" || n == "oddtool" || n == "Broken" || n == "jq") { st = "unresolved"; ly = "none"; m = "none" }
      else if (n == "gone-app") { st = "needs-decision"; ly = "packages"; m = "choose" }
      else if (k ~ /^(brew-formula|brew-cask|app|cargo|npm|pnpm|bun|uv|pipx|go|tap|extension)$/) { st = "resolved"; ly = "packages"; m = "pacman"; t = n }
      else if (k == "ai") { st = "resolved"; ly = "ai"; m = "mise"; t = n }
      else if (k == "git" || k == "mcp" || k == "plugin") { st = "resolved"; ly = "settings"; m = "place" }
      else { st = "resolved"; ly = "files"; m = "place" }
      printf "resolution\tid=%s\tlayer=%s\tmethod=%s\ttarget=%s\tversion=%s\tguess=%d\tstate=%s\tnote=\n", id, ly, m, t, v, g, st
    }' "$2" "$1" >"$3"
}
res_choices() {
  LC_ALL=C awk -F '\t' '$1 == "item" && ($6 == "name=mystery" || $6 == "name=oddtool" || $6 == "name=jq" || $6 == "name=gone-app") {
    split($2, a, "="); printf "row\tkind=choice\tkey=%s\tcol=skip\tcol=Leave%%20it%%20out\tcol=0\n", a[2]
    printf "row\tkind=choice\tkey=%s\tcol=pacman\tcol=Try%%20a%%20pacman%%20package\tcol=1\n", a[2] }' "$1" >"$2"
}
EOF
}
PT=$T/tool
p_tool "$PT"

# p_arg NAME VALUE — one request argument, encoded.
p_arg() { rec_line_v arg name "$1" value "$2" && printf '%s' "$REC_LINE"; }
# p_basis ACTION EXTRA GEN — a parameterised row's basis, as the core makes it.
p_basis() { rec_line_v basis action "$1" generation "$3" value "$2" && sha256_str "omb-basis 1
$REC_LINE
"; }
# p_field RECORD-TYPE KEY — KEY of the first such record in the spool.
p_field() { printf '%s\n' "$C_OUT" | awk -F '\t' -v t="$1" -v k="$2=" '$1 == t { for (i = 2; i <= NF; i++) if (index($i, k) == 1) { print substr($i, length(k) + 1); exit } }'; }
p_fact() { printf '%s\n' "$C_OUT" | awk -F '\t' -v k="key=$1" '$1 == "fact" && $3 == k { sub(/^value=/, "", $5); print $5; exit }'; }
p_action_basis() { printf '%s\n' "$C_OUT" | awk -F '\t' -v a="id=$1" '$1 == "action" && $2 == a { for (i = 2; i <= NF; i++) if ($i ~ /^basis=/) { sub(/^basis=/, "", $i); print $i } }'; }
p_snap() { c_run snapshot "scope	name=profile"; }
p_exec() { # ACTION WORD [RECORD...]
  local a=$1 w=$2 b
  shift 2
  p_snap
  b=$(p_action_basis "$a")
  [ -n "$b" ] || b=$(printf '%064d' 0)
  c_run execute "exec	action=$a	basis=$b	confirm=$w" "$@"
}
# p_rows KIND — a detail's rows, from a fresh snapshot's generation.
p_rows() {
  local g
  p_snap
  g=$(p_field generation id)
  c_run detail "page	scope=profile	kind=$1	generation=$g	offset=0	limit=500"
  printf '%s\n' "$C_OUT" | grep '^row	'
}
p_admit() { # FILE — the profile admits, its seal included
  (
    . "$REPO/lib/records.sh"
    rec_admit_file profile - "$1" && printf ok || printf '%s' "$REC_REASON"
    omb_cleanup
  )
}
# p_save DOC... — validate then execute profile.save with the document split
# into select.1, select.2, … at line ends, one line each.
p_save() {
  local i=0 line g b
  local -a args=()
  while IFS= read -r line; do
    i=$((i + 1))
    args+=("$(p_arg "select.$i" "$line
")")
  done <<EOF
$1
EOF
  c_run validate "select	action=profile.save" "${args[@]}"
  P_VALIDATE=$C_OUT
  b=$(p_field review basis)
  [ -n "$b" ] || b=$(printf '%064d' 0)
  c_run execute "exec	action=profile.save	basis=$b	confirm=" "${args[@]}"
}

if t_plutil "the profile over a fixture home"; then
  c_session
  C_HOME=$PT C_FIX=$(t_variant mig-mac-home) C_ENV="OMB_SESSION_SCOPES=profile"
  export C_HOME C_FIX C_ENV
  P=$T/state/profile.omb

  # --- profile-scan: a first scan through the core --------------------------
  p_snap
  assert_eq "$(c_result)" "done ok" "profile-scan: the snapshot of no profile answers"
  assert_eq "$(c_admits snapshot)" ok "profile-scan: and is an admissible response"
  assert_eq "$(p_fact profile.state)" not-scanned "profile-scan: no profile.omb is not-scanned"
  assert_contains "$C_OUT" "blocker	id=profile.none" "profile-scan: and says what to do"
  assert_eq "$(printf '%s\n' "$C_OUT" | awk -F '\t' '$1 == "action" { printf "%s ", $2 }')" "id=profile.scan " "profile-scan: only the scan is offered"
  p_exec profile.scan ""
  assert_eq "$(c_result)" "done ok" "profile-scan: the scan saves the inventory"
  assert_eq "$(c_admits execute)" ok "profile-scan: its answer is admissible"
  assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^progress	action=profile.scan')" 9 "profile-scan: one progress record per adapter"
  assert_contains "$C_OUT" "message	level=ok	text=homebrew" "profile-scan: each adapter's result is a message"
  assert_eq "$(p_admit "$P")" ok "profile-sealed: profile.omb admits, its seal checked"
  assert_eq "$(ls -A "$T/state/ops" 2>/dev/null)" "" "profile-scan: no operation record is left"
  p_snap
  assert_eq "$(p_fact profile.state)" scanned "profile-scan: an inventory with no selection saved is scanned"
  assert_contains "$(p_fact adapter.homebrew)" "done%20%C2%B7%209%20items" "profile-scan: each adapter's state and count"
  assert_eq "$(printf '%s\n' "$C_OUT" | awk -F '\t' '$1 == "action" { printf "%s ", $2 }')" "id=profile.scan id=profile.save " "profile-scan: an inventory can be chosen from"
  assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^param	action=profile.save	name=select\.')" 14 "profile-scan: profile.save takes select.1 to select.14"

  # --- profile-bound: the host id, never the UUID ----------------------------
  want=$(sha256_str "omarchy-mac-bootstrap host 1
5A1E0000-0000-4000-8000-0000000000A1")
  assert_contains "$(sed -n 2p "$P")" "mac	host=${want:0:16}	" "profile-bound: bound by the first 16 hex digits of the SHA-256 of a label and the hardware UUID"
  if grep -q '5A1E0000' "$P"; then fail "profile-bound: the hardware UUID itself is in the profile"; else ok; fi

  # --- profile-select: one omb-select document ------------------------------
  doc='omb-select 1
select	id=brew:ripgrep	state=exclude
select	id=brew:pcre2	state=include
select	id=brew:mystery	state=include
decision	id=brew:mystery	choice=pacman	value=mystery'
  p_save "$doc"
  assert_eq "$(printf '%s\n' "$P_VALIDATE" | awk -F '\t' '$1 == "result" { print $2 }')" "status=done" "profile-select: the document, split at line ends, validates"
  assert_eq "$(c_result)" "done ok" "profile-select: and saves"
  sel=$(awk -F '\t' '$1 == "select"' "$P")
  assert_contains "$sel" "select	id=brew:ripgrep	state=exclude" "profile-select: the person's exclusion of a default is stored"
  assert_contains "$sel" "select	id=brew:pcre2	state=include" "profile-select: the person's include is stored"
  assert_contains "$sel" "select	id=brew:node	state=include" "profile-select: so is every default include"
  assert_not_contains "$sel" "id=path:.myscripts" "profile-select: an opaque folder no one chose is not"
  assert_not_contains "$sel" "id=brew:oddtool" "profile-select: nor an item waiting for a decision"
  assert_eq "$(awk -F '\t' '$1 == "decision"' "$P")" "decision	id=brew:mystery	choice=pacman	value=mystery" "profile-select: the decision, as sent"
  assert_eq "$(p_admit "$P")" ok "profile-sealed: the saved profile admits"
  rows=$(p_rows items)
  assert_contains "$rows" "key=brew:ripgrep	col=software	col=ripgrep	col=homebrew/core	col=14.1.1	col=pacman%20ripgrep	col=exclude	col=config	col=person" \
    "profile-select: an excluded item, by the person"
  assert_contains "$rows" "key=brew:mystery	col=software	col=mystery	col=homebrew	col=1.0	col=pacman%20mystery%20%28a%20guess%29	col=include	col=config	col=person" \
    "profile-select: a decision resolves an unknown formula, shown as a guess"
  assert_contains "$rows" "key=brew:node	col=software	col=node	col=homebrew/core	col=22.11.0	col=pacman%20node	col=include	col=config	col=default" \
    "profile-select: a requested formula that resolves is included by default"
  assert_eq "$(printf '%s\n' "$rows" | sed -n 1p | grep -c 'col=decide')" 1 "profile-wire: items that need a decision come first"
  p_snap
  assert_eq "$(p_fact profile.state)" saved "profile-select: every included item resolved: saved"
  # A later document is merged over the earlier choices: what it names is
  # replaced, what it does not name keeps its choice and decision.
  p_save 'omb-select 1
select	id=brew:pcre2	state=exclude'
  assert_eq "$(c_result)" "done ok" "profile-select: a later document saves"
  sel=$(awk -F '\t' '$1 == "select"' "$P")
  assert_contains "$sel" "select	id=brew:ripgrep	state=exclude" "profile-select: an item the document does not name keeps its earlier choice"
  assert_contains "$sel" "select	id=brew:mystery	state=include" "profile-select: and its earlier include"
  assert_not_contains "$sel" "id=brew:pcre2" "profile-select: the document's choice replaces the earlier one"
  assert_eq "$(awk -F '\t' '$1 == "decision"' "$P")" "decision	id=brew:mystery	choice=pacman	value=mystery" "profile-select: and the earlier decision stays"
  p_save "$doc"
  assert_eq "$(c_result)" "done ok" "profile-select: the first document again"
  # A document naming an item the profile does not hold is refused whole.
  p_snap
  gen=$(p_field generation id)
  before=$(cat "$P")
  bad='omb-select 1
select	id=brew:nope	state=include'
  p_save "$bad"
  assert_contains "$P_VALIDATE" "invalid	name=select.1	code=invalid" "profile-select: validate refuses an id the profile does not hold"
  printf '%s\n' "$bad" >"$T/bad.doc"
  c_run execute "exec	action=profile.save	basis=$(p_basis profile.save "$(sha256_of "$T/bad.doc")" "$gen")	confirm=" "$(p_arg select.1 "$bad
")"
  assert_eq "$(c_result)" "failed no-effect" "profile-select: and so does execute: nothing changed"
  assert_eq "$(cat "$P")" "$before" "profile-select: the profile is as it was"
  c_run validate "select	action=profile.save" "$(p_arg select.2 'omb-select 1
')"
  assert_contains "$C_OUT" "invalid	name=select.1	code=gap" "profile-select: the parts run from select.1 without a gap"
  c_run validate "select	action=profile.save" "$(p_arg other x)"
  assert_contains "$C_OUT" "invalid	name=other	code=unknown-parameter" "profile-select: only select.N"
  c_run execute "exec	action=profile.save	basis=$(printf '%064d' 0)	confirm=" "$(p_arg select.1 "$doc
")"
  assert_eq "$(c_result)" "refused changed" "profile-select: a basis that is not the review's is refused"

  # --- profile-wire: the details --------------------------------------------
  p_snap
  gen=$(p_field generation id)
  assert_eq "$gen" "$(sha256_of "$P")" "profile-wire: the generation is the SHA-256 of profile.omb"
  c_run detail "page	scope=profile	kind=items	generation=$(printf '%064d' 1)	offset=0	limit=10"
  assert_eq "$(c_result)" "refused changed" "profile-wire: a detail of another generation is refused"
  c_run detail "page	scope=profile	kind=review	generation=$gen	offset=0	limit=50"
  assert_eq "$(c_admits detail)" ok "profile-wire: the review is admissible"
  assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^row	kind=review')" 8 "profile-wire: one review row per category"
  rows=$(p_rows keys)
  assert_eq "$rows" "row	kind=key	key=path:.ssh/id_ed25519	col=.ssh/id_ed25519	col=aes256-ctr	col=16" "profile-wire: the keys carry can include"
  rows=$(p_rows choices)
  assert_contains "$rows" "row	kind=choice	key=brew:oddtool	col=skip" "profile-wire: an item's choices, from the resolution unit"
  c_run detail "page	scope=profile	kind=nothing	generation=$gen	offset=0	limit=10"
  assert_eq "$(c_result)" "refused unavailable" "profile-wire: an unknown detail kind is refused"

  # --- profile-rescan: choices kept by item id; gone and new reported ---------
  rm -rf "$C_FIX/root/opt/homebrew/Cellar/node" "$C_FIX/root/opt/homebrew/opt/node"
  mkdir -p "$C_FIX/root/opt/homebrew/Cellar/jq/1.7.1"
  printf '{"installed_on_request":true,"runtime_dependencies":[],"source":{"tap":"homebrew/core"}}\n' >"$C_FIX/root/opt/homebrew/Cellar/jq/1.7.1/INSTALL_RECEIPT.json"
  p_exec profile.scan ""
  assert_eq "$(c_result)" "done ok" "profile-rescan: the rescan saves"
  assert_contains "$C_OUT" "text=Since%20the%20last%20scan:%201%20gone,%201%20new." "profile-rescan: and says what changed"
  assert_eq "$(awk -F '\t' '$1 == "change"' "$P")" "change	kind=gone	id=brew:node
change	kind=new	id=brew:jq" "profile-rescan: what is gone and what is new, by item id"
  sel=$(awk -F '\t' '$1 == "select"' "$P")
  assert_contains "$sel" "select	id=brew:ripgrep	state=exclude" "profile-rescan: the person's choices are kept by item id"
  assert_contains "$sel" "select	id=brew:mystery	state=include" "profile-rescan: an include the person made is kept"
  assert_not_contains "$sel" "id=brew:node" "profile-rescan: an item that is gone loses its select"
  assert_contains "$(awk -F '\t' '$1 == "decision"' "$P")" "decision	id=brew:mystery	choice=pacman" "profile-rescan: and its decisions"
  p_snap
  assert_eq "$(p_fact change.gone) $(p_fact change.new)" "1 1" "profile-rescan: the snapshot counts the changes"
  rows=$(p_rows changes)
  assert_eq "$rows" "row	kind=change	key=brew:node	col=gone	col=brew:node
row	kind=change	key=brew:jq	col=new	col=jq" "profile-rescan: the changes detail"
  rows=$(p_rows items)
  assert_contains "$rows" "key=brew:jq	col=software	col=jq	col=homebrew/core	col=1.7.1	col=unresolved	col=decide	col=config	col=default" \
    "profile-rescan: a new item waits for a decision"

  # --- profile-rerun, profile-stop, profile-fail: the CLI's save --------------
  SD=$T/cli-state
  F=$(t_variant mig-mac-home)
  REPO=$PT T_ENV="OMB_STATE_DIR=$SD" t_cli "$F" "" profile
  assert_rc "$T_RC" 0 "profile-rerun: profile saves the defaults"
  assert_contains "$T_OUT" "Migration review" "profile-rerun: and shows the review"
  assert_eq "$(p_admit "$SD/profile.omb")" ok "profile-rerun: the saved profile admits"
  sum=$(sha256_of "$SD/profile.omb")
  sleep 1
  REPO=$PT T_ENV="OMB_STATE_DIR=$SD" t_cli "$F" "" profile
  assert_rc "$T_RC" 0 "profile-rerun: a second run completes"
  assert_eq "$(sha256_of "$SD/profile.omb")" "$sum" "profile-rerun: and changes nothing, its time included"
  if awk -F '\t' '$1 == "consent"' "$SD/profile.omb" | grep -q .; then fail "profile-rerun: the CLI typed a word for the person"; else ok; fi
  # A write failure at the save: the old profile stays, byte for byte.
  mkdir -p "$F/root/Users/alex/.config/newthing" && printf 'x\n' >"$F/root/Users/alex/.config/newthing/conf"
  REPO=$PT T_ENV="OMB_STATE_DIR=$SD OMB_TEST_FAIL_AT=profile.save" t_cli "$F" "" profile
  assert_rc "$T_RC" 1 "profile-fail: a write that fails at the save fails the run"
  assert_eq "$(sha256_of "$SD/profile.omb")" "$sum" "profile-fail: the old profile is unchanged"
  assert_eq "$(ls -A "$SD" | grep -c '^\.profile')" 0 "profile-fail: no partial file is left"
  # A stop right after the save: the new profile is whole.
  REPO=$PT T_ENV="OMB_STATE_DIR=$SD OMB_TEST_STOP_AT=profile.save" t_cli "$F" "" profile
  assert_rc "$T_RC" 137 "profile-stop: the run stops right after the save"
  assert_eq "$(p_admit "$SD/profile.omb")" ok "profile-stop: the profile it leaves is whole"
  assert_contains "$(cat "$SD/profile.omb")" "id=path:.config/newthing" "profile-stop: and is the new one"
  assert_eq "$(ls -A "$SD" | grep -c '^\.profile')" 0 "profile-stop: no partial file is left"

  # --- profile-show: read-only ---------------------------------------------
  REPO=$PT T_ENV="OMB_STATE_DIR=$SD" t_cli "$F" "" profile show
  assert_rc "$T_RC" 0 "profile-show: shows the review"
  assert_contains "$T_OUT" "software" "profile-show: by category"
  REPO=$PT T_ENV="OMB_STATE_DIR=$SD" t_cli "$F" "" profile show --unresolved
  assert_contains "$T_OUT" "item	id=brew:oddtool	adapter=homebrew" "profile-show: --unresolved prints the unresolved items as records"
  assert_contains "$T_OUT" "resolution	id=brew:oddtool	layer=none" "profile-show: with what is known of their resolution"
  assert_not_contains "$T_OUT" "id=brew:ripgrep" "profile-show: and only those"
  REPO=$PT T_ENV="OMB_STATE_DIR=$T/none" t_cli "$F" "" profile show
  assert_contains "$T_OUT" "No profile yet" "profile-show: no profile, said so"
  assert_eq "$(ls -A "$T/none" 2>/dev/null)" "" "profile-show: writes nothing"

  # --- profile-invalid: another Mac's profile, or a tampered one -------------
  O=$(t_variant mig-mac-home)
  sed -i.bak 's/5A1E0000-0000-4000-8000-0000000000A1/0B0E0000-0000-4000-8000-0000000000B2/' "$O/cmd/hardware_plist" && rm -f "$O/cmd/hardware_plist.bak"
  C_FIX=$O p_snap
  assert_eq "$(p_fact profile.state)" invalid "profile-invalid: a profile made on another Mac is invalid"
  assert_contains "$C_OUT" "blocker	id=profile.invalid" "profile-invalid: and blocks, saying why"
  assert_eq "$(printf '%s\n' "$C_OUT" | awk -F '\t' '$1 == "action" { printf "%s ", $2 }')" "id=profile.scan " "profile-invalid: only a new scan is offered"
  REPO=$PT T_ENV="OMB_STATE_DIR=$SD" t_cli "$O" "" profile
  assert_rc "$T_RC" 0 "profile-invalid: the next profile replaces it"
  want=$(sha256_str "omarchy-mac-bootstrap host 1
0B0E0000-0000-4000-8000-0000000000B2")
  assert_contains "$(sed -n 2p "$SD/profile.omb")" "host=${want:0:16}" "profile-invalid: bound to this Mac now"
  sed -i.bak '3s/adapter/adaptor/' "$P" && rm -f "$P.bak"
  p_snap
  assert_eq "$(p_fact profile.state)" invalid "profile-invalid: a profile whose seal fails is invalid"
  rm -rf "$F" "$O" "$C_FIX"
fi

rm -rf "$T"
t_done test-profile
