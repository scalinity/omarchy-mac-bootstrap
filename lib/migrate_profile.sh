# shellcheck shell=bash
# The Migration Profile (docs/MIGRATION.md → *Selection*, *The Migration
# Profile*, *On the wire*; D20, D40, D23).
#
# One `omb-profile 1` document, profile.omb in the macOS state directory,
# sealed on every write (written beside, then renamed over) and bound to this
# Mac by its host id. It holds the source Mac, each adapter's scan state, the
# items with their evidence and class, the selection (a `select
# state=include` for every item chosen to travel, defaults included, and the
# person's exclusions of a default), the person's decisions, the typed
# consents (`opaque` once per save, `carry` per key), the resolution and what
# a rescan found gone or new; never a file's contents. It is input, never
# authority: every read admits it whole. A select is the person's when it
# differs from what the defaults choose; a rescan keeps only those, by item
# id, and the defaults are chosen again.
#
#   prof_load            the profile, its state and the effective selection
#   prof_host_id         PROF_HOST_ID: this Mac's host id
#   prof_row ID          the profile's rows of the core's action table
#   prof_core_op OP      scope `profile` on the wire: snapshot, detail, validate
#   prof_cmd [show [--unresolved]]   `profile` and `profile show`
#   prof_selected OUT    the items export carries (export's seam)
#
# It calls the resolution unit's res_resolve and res_choices
# (lib/migrate_resolve.sh). Needs lib/common.sh, lib/ui.sh, lib/state.sh,
# lib/records.sh, lib/macos.sh (plist_get), lib/migrate_scan.sh.

PROF_IDS="profile.scan profile.save profile.opaque profile.carry"
PROF_HOST_LABEL="omarchy-mac-bootstrap host 1"
# The save boundary's name for the test seams (omb_stop_at, omb_fail_at).
PROF_BOUNDARY=profile.save
PROF_LOADED=""

prof_path() { printf '%s/profile.omb' "$OMB_STATE_DIR"; }

# prof_host_id — PROF_HOST_ID: this Mac's host id, the first 16 hex digits of the
# SHA-256 of a fixed label and the hardware UUID system_profiler reports
# (never the UUID itself); 1 when the UUID cannot be read.
prof_host_id() {
  local hw uuid
  PROF_HOST_ID=""
  hw=$(sys_cmd hardware_plist system_profiler -xml SPHardwareDataType)
  uuid=$(plist_get "$hw" 0._items.0.platform_UUID 2>/dev/null)
  case "$uuid" in '' | *[!0-9A-Fa-f-]*) return 1 ;; esac
  [ "${#uuid}" -ge 16 ] || return 1
  PROF_HOST_ID=$(sha256_str "$PROF_HOST_LABEL
$uuid") || return 1
  PROF_HOST_ID=${PROF_HOST_ID:0:16}
  _whole "$PROF_HOST_ID" '^[0-9a-f]{16}$'
}

# _prof_sha FILE — PROF_SHA: the file's SHA-256, or of nothing when absent.
_prof_sha() {
  if [ -f "$1" ]; then
    PROF_SHA=$(sha256_of "$1")
  else
    PROF_SHA=$(sha256_str "")
  fi
  _whole "$PROF_SHA" '^[0-9a-f]{64}$'
}

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

# The awk functions every view builder shares: record fields, the canonical
# encoding, and record text (valid UTF-8 without control bytes).
# shellcheck disable=SC2016 # awk source
_PROF_AWK_LIB='
function rec(line,   n, i, a, p) {
  delete F
  n = split(line, a, "\t")
  F["_type"] = a[1]
  for (i = 2; i <= n; i++) { p = index(a[i], "="); F[substr(a[i], 1, p - 1)] = substr(a[i], p + 1) }
}
function dec(s,   o, i) {
  o = ""
  while ((i = index(s, "%")) > 0) { o = o substr(s, 1, i - 1) sprintf("%c", HV[substr(s, i + 1, 2)]); s = substr(s, i + 3) }
  return o s
}
function enc(s,   o, i, n, c, a) {
  if (s !~ /[^A-Za-z0-9._~\/:@+,-]/) return s
  o = ""
  n = split(s, a, "")
  for (i = 1; i <= n; i++) {
    c = a[i]
    if (c ~ /[A-Za-z0-9._~\/:@+,-]/) o = o c
    else o = o "%" substr(HEX, int(ORD[c] / 16) + 1, 1) substr(HEX, ORD[c] % 16 + 1, 1)
  }
  return o
}
function text(s,   n, a, i, b, need, o) {
  n = split(s, a, "")
  need = 0
  for (i = 1; i <= n; i++) {
    b = ORD[a[i]]
    if (need == 0) {
      if (b < 32 || b == 127) return clean(s)
      if (b < 128) continue
      if (b >= 194 && b <= 223) need = 1
      else if (b >= 224 && b <= 239) need = 2
      else if (b >= 240 && b <= 244) need = 3
      else return clean(s)
    } else {
      if (b < 128 || b > 191) return clean(s)
      need--
    }
  }
  return need == 0 ? s : clean(s)
}
function clean(s,   n, a, i, o) {
  o = ""
  n = split(s, a, "")
  for (i = 1; i <= n; i++) o = o ((ORD[a[i]] >= 32 && ORD[a[i]] < 127) ? a[i] : "?")
  return o
}
function etext(v) { return enc(text(dec(v))) }
BEGIN {
  HEX = "0123456789ABCDEF"
  for (i = 1; i < 256; i++) { ORD[sprintf("%c", i)] = i; HV[sprintf("%02X", i)] = i }
  FS = "\n"
}'

# prof_load — the profile as it is now. PROF_STATE: not-scanned, scanned,
# selected, saved or invalid (PROF_WHY says why); PROF_GEN: the SHA-256 of
# profile.omb (of nothing when absent). When it admits, its records by type
# in $PROF_DIR (mac, adapter, item, select, decision, consent, resolution,
# change) and the view (_prof_view). 1 only when the scratch cannot be
# made; a profile that cannot be used is the state invalid. Cached by
# generation within one process.
prof_load() {
  local f t
  f=$(prof_path)
  omb_tmp_init || return 1
  PROF_DIR=$OMB_TMP/profile
  mkdir -p "$PROF_DIR" || return 1
  _prof_sha "$f" || return 1
  if [ -n "$PROF_LOADED" ] && [ "$PROF_LOADED" = "$PROF_SHA" ]; then return 0; fi
  PROF_GEN=$PROF_SHA PROF_WHY="" PROF_RESOLVED=0
  for t in mac adapter item select decision consent resolution change; do : >"$PROF_DIR/$t"; done
  : >"$PROF_DIR/view"
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    PROF_STATE=not-scanned PROF_LOADED=$PROF_GEN
    return 0
  fi
  PROF_STATE=invalid
  if ! _state_file_ok "$f"; then
    PROF_WHY="profile.omb is not a plain file owned by you"
  elif ! rec_admit_file profile - "$f"; then
    PROF_WHY="profile.omb fails admission ($REC_REASON at line $REC_AT)"
  else
    # The admitted copy, split by record type; the seal is not a record.
    LC_ALL=C awk -F '\t' -v d="$PROF_DIR" 'NR > 1 && $1 != "seal" { print > (d "/" $1) }' "$REC_TMP/doc" || return 1
    if ! prof_host_id; then
      PROF_WHY="this Mac's hardware id cannot be read"
    else
      rec_find mac
      rec_get_into PROF_MAC_HOST "$REC_AT_I" host
      if [ "$PROF_MAC_HOST" != "$PROF_HOST_ID" ]; then
        PROF_WHY="it was made on another Mac (a Time Machine restore brings the everyday Mac's); the next profile replaces it"
      else
        PROF_STATE=ok
      fi
    fi
  fi
  if [ "$PROF_STATE" = invalid ]; then
    for t in mac adapter item select decision consent resolution change; do : >"$PROF_DIR/$t"; done
    PROF_LOADED=$PROF_GEN
    return 0
  fi
  [ -s "$PROF_DIR/resolution" ] && PROF_RESOLVED=1
  rm -f "$PROF_DIR/resolution.view"
  if [ "$PROF_RESOLVED" = 0 ]; then
    # No selection saved yet: the defaults shown come from resolving the
    # inventory now, which writes nothing.
    _prof_resolve "$PROF_DIR/item" "$PROF_DIR/decision" "$PROF_DIR/res.now" && cp "$PROF_DIR/res.now" "$PROF_DIR/resolution.view"
    [ -f "$PROF_DIR/resolution.view" ] || : >"$PROF_DIR/resolution.view"
  else
    cp "$PROF_DIR/resolution" "$PROF_DIR/resolution.view" || return 1
  fi
  _prof_view "$PROF_DIR" "$PROF_DIR/resolution.view" "$PROF_DIR/view" || return 1
  PROF_STATE=scanned
  if [ "$PROF_RESOLVED" = 1 ]; then
    PROF_STATE=saved
    LC_ALL=C awk -F '\t' '$23 == 1 { bad = 1 } END { exit !bad }' "$PROF_DIR/view" && PROF_STATE=selected
  fi
  PROF_LOADED=$PROF_GEN
  return 0
}

# _prof_resolve ITEMS DECISIONS OUT — the resolution unit's answer, one
# resolution record per item in ITEMS' order; 1 (PROF_WHY) when it cannot
# give one.
_prof_resolve() {
  if ! declare -F res_resolve >/dev/null; then
    PROF_WHY="resolution is not available"
    return 1
  fi
  if ! res_resolve "$1" "$2" "$3"; then
    PROF_WHY="the migration map cannot be read, so nothing resolves"
    return 1
  fi
  # One per item, in order, each naming its item: anything else is not an answer.
  if ! LC_ALL=C awk -F '\t' 'NR == FNR { if ($1 == "item") ids[++n] = $2; next }
    $1 != "resolution" || $2 != ids[++m] { bad = 1 } END { exit (bad || m != n) }' "$1" "$3"; then
    PROF_WHY="the resolution does not match the inventory"
    return 1
  fi
}

# _prof_view DIR RESOLUTIONS OUT — one line per item of DIR (its item, select
# and consent records), in inventory order, every field in the record
# encoding:
#  1 id  2 kind  3 category  4 name  5 version  6 source  7 requested
#  8 evidence  9 class  10 path  11 size  12 note  13 resolution state
#  14 layer  15 method  16 target  17 resolved version  18 guess
#  19 state (include, exclude, decide, never)  20 by (default, person)
#  21 reason  22 adapter  23 1 when it is chosen to travel and still needs
#  a decision (what makes a profile selected rather than saved)
#  24 the state its defaults give  25 its stored select: include (every
#  item chosen to travel, defaults included), exclude (the person's
#  exclusion of a default), or empty
# The defaults of docs/MIGRATION.md → *Selection*, then the select records
# and the typed consents. A select is the person's (by) when it differs
# from what the defaults choose.
_prof_view() {
  LC_ALL=C awk "$_PROF_AWK_LIB"'
    function judge(s) {
      ST = ""; WHY = ""; WANT = 0
      if (cl == "secret" && k == "key-encrypted") {
        if (s == "include" && (id in CAR)) ST = "include"
        else if (s == "include") { ST = "decide"; WHY = "waits for the typed word carry" }
        else { ST = "exclude"; WHY = "an encrypted SSH key: typed carry includes it" }
      } else if (cl == "secret") { ST = "never"; WHY = "never carried: a credential" }
      else if (cl == "mac-only") { ST = "never"; WHY = "only means something on macOS" }
      else if (k == "refused" || k == "recognised" || k == "session" || k == "link" || k == "special") { ST = "never"; WHY = (k == "recognised") ? "recognised, not migrated yet" : (k == "refused" ? "carries nothing (see its note)" : "never carried") }
      else if (rs == "unsupported" || rs == "mac-only") { ST = "never"; WHY = (rs == "unsupported") ? "not available for Linux on this Mac" : "only means something on macOS" }
      else if (cl == "opaque") {
        if (s == "include") { if (OPQ) ST = "include"; else { ST = "decide"; WHY = "waits for the typed word opaque" } }
        else { ST = "exclude"; WHY = "a chosen folder: its contents are not checked; included only after typed opaque" }
      } else if (cl == "sensitive") {
        if (s == "include") ST = "include"
        else { ST = "exclude"; WHY = "private: travels only when you opt in" }
      } else {
        if (s != "") ST = s
        else if (soft) {
          if (rq == "no") { ST = "exclude"; WHY = "a dependency: not offered" }
          else if (rq == "unknown") { ST = "decide"; WHY = "whether it was requested is unknown" }
          else if (rs == "resolved") ST = "include"
          else if (rs == "skipped") { ST = "exclude"; WHY = "skipped by your decision" }
          else { ST = "decide"; WHY = (rs == "needs-decision") ? "a choice is needed" : "nothing says what it becomes on Linux" }
        } else if (k == "runs-code") { ST = "exclude"; WHY = "runs code: include it after reading it" }
        else ST = "include"
        if (ST == "include" && rs != "" && rs != "resolved" && rs != "unsupported") { ST = "decide"; WANT = 1; WHY = "included, and a decision is still needed" }
      }
    }
    FILENAME == RF { rec($0); R[F["id"]] = F["state"] "\t" F["layer"] "\t" F["method"] "\t" F["target"] "\t" F["version"] "\t" F["guess"]; next }
    FILENAME == SF { rec($0); S[F["id"]] = F["state"]; next }
    FILENAME == CF { rec($0); if (F["word"] == "opaque") OPQ = 1; if (F["word"] == "carry") CAR[F["id"]] = 1; next }
    FILENAME == IF {
      rec($0)
      id = F["id"]; k = F["kind"]; cl = F["class"]; rq = F["requested"]
      split((id in R) ? R[id] : "\t\t\t\t\t", r, "\t")
      rs = r[1]; ly = r[2]
      soft = (ly == "packages" || ly == "runtimes" || ly == "tools" || ly == "ai" || k ~ /^(brew-formula|brew-cask|app|cargo|npm|pnpm|bun|nvm|mise|asdf|uv|pipx|go|ai|tap|extension)$/)
      s = (id in S) ? S[id] : ""
      judge("")
      dst = ST; dchosen = (ST == "include" || WANT)
      judge(s)
      chosen = (ST == "include" || WANT)
      by = (s != "" && (s == "include") != dchosen) ? "person" : "default"
      store = ""
      if (chosen || (s == "include" && ST == "decide")) store = "include"
      else if (s == "exclude" && dchosen) store = "exclude"
      printf "%s", id
      printf "\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", k, F["category"], F["name"], F["version"], F["source"], rq, F["evidence"], cl
      printf "\t%s\t%s\t%s", F["path"], F["size"], F["note"]
      printf "\t%s\t%s\t%s\t%s\t%s\t%s", r[1], r[2], r[3], r[4], r[5], r[6]
      printf "\t%s\t%s\t%s\t%s\t%d\t%s\t%s\n", ST, by, enc(WHY), F["adapter"], WANT, dst, store
    }' RF="$2" SF="$1/select" CF="$1/consent" IF="$1/item" \
    "$2" "$1/select" "$1/consent" "$1/item" >"$3"
}

# _prof_store_selects DIR — DIR's select records as the profile stores them:
# one `select state=include` for every item chosen to travel (defaults
# included), and the person's exclusions of a default; in inventory order.
# Only for a resolved DIR; 1 when the view cannot be made.
_prof_store_selects() {
  [ -s "$1/resolution" ] || return 0
  _prof_view "$1" "$1/resolution" "$1/view.store" || return 1
  LC_ALL=C awk -F '\t' '$25 != "" { printf "select\tid=%s\tstate=%s\n", $1, $25 }' "$1/view.store" >"$1/select.store" &&
    mv -f "$1/select.store" "$1/select"
}

# _prof_person DIR OUT — the select records of the loaded profile that are
# the person's own (they differ from what the defaults choose), for the
# items DIR still holds.
_prof_person() {
  LC_ALL=C awk -F '\t' 'FILENAME == ARGV[1] { if ($20 == "person") p["id=" $1] = 1; next }
    FILENAME == ARGV[2] { ids[$2] = 1; next }
    ($2 in p) && ($2 in ids)' "$PROF_DIR/view" "$1/item" "$PROF_DIR/select" >"$2"
}

# prof_selected OUT — export's seam: the item records of a saved profile that
# travel (effective state include: a chosen folder only after typed opaque,
# an encrypted key only after typed carry), in inventory order, each followed
# by its resolution record. 1 when the profile is not saved.
prof_selected() {
  prof_load || return 1
  [ "$PROF_STATE" = saved ] || return 1
  LC_ALL=C awk -F '\t' 'FILENAME == ARGV[1] { if ($19 == "include") inc[$1] = 1; next }
    FILENAME == ARGV[2] { split($2, a, "="); res[a[2]] = $0; next }
    { split($2, a, "="); if (a[2] in inc) { print; print res[a[2]] } }' \
    "$PROF_DIR/view" "$PROF_DIR/resolution" "$PROF_DIR/item" >"$1"
}

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

# _prof_write DIR — profile.omb from the parts in DIR (mac.part, adapter,
# item, select, decision, consent, resolution, change; a resolved DIR's
# selects become the stored selection, _prof_store_selects): written beside
# and renamed over, sealed, 0600; the save boundary's test seams around the
# rename. When the new document says exactly what the old one does (its
# time apart), nothing is written: PROF_WROTE is 0. 1 when it cannot be
# written; the old profile then stays as it was.
_prof_write() {
  local d=$1 f tmp t old_at="" size
  PROF_WROTE=0
  f=$(prof_path)
  # A resolved profile stores every item chosen to travel as a select.
  _prof_store_selects "$d" || return 1
  if [ "$OMB_PERSIST" != 1 ] || [ "$OMB_DRY_RUN" = 1 ]; then return 0; fi
  state_dir_ready || return 1
  # A link is never written through, nor anything that is not a file; an
  # invalid profile of our own is simply replaced (renamed over).
  if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then return 1; fi
  # The time of an unchanged profile stays its time.
  if [ "${PROF_STATE:-}" != invalid ] && [ -s "$PROF_DIR/mac" ]; then
    old_at=$(LC_ALL=C awk -F '\t' '{ for (i = 2; i <= NF; i++) if ($i ~ /^at=/) print substr($i, 4) }' "$PROF_DIR/mac")
  fi
  {
    printf 'omb-profile 1\n'
    cat "$d/mac.part"
    for t in adapter item select decision consent resolution change; do cat "$d/$t"; done
  } >"$d/body.new" || return 1
  if [ -n "$old_at" ] && [ -f "$f" ]; then
    size=$(wc -c <"$f")
    # The old document without its seal line (seal, TAB, sha256=, 64, LF: 77 bytes).
    if LC_ALL=C sed "/^mac	/s/	at=[0-9TZ:-]*$/	at=$old_at/" "$d/body.new" >"$d/body.same" &&
      head -c "$((size - 77))" "$f" >"$d/body.old" 2>/dev/null && cmp -s "$d/body.same" "$d/body.old"; then
      return 0
    fi
  fi
  tmp=$(mktemp "$OMB_STATE_DIR/.profile.omb.XXXXXX") || return 1
  if cp "$d/body.new" "$tmp" && rec_seal_write "$tmp" && chmod 600 "$tmp" && ! omb_fail_at "$PROF_BOUNDARY" && mv -f "$tmp" "$f"; then
    PROF_WROTE=1
    PROF_LOADED=""
    log_event record "wrote profile.omb"
    omb_stop_at "$PROF_BOUNDARY"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# _prof_mac DIR — DIR/mac.part: the source Mac, at the time now.
_prof_mac() {
  local model os
  model=$(sys_cmd sysctl_hw_model sysctl -n hw.model)
  os=$(sys_cmd sw_vers sw_vers -productVersion)
  _scan_text "${model:-unknown}" && model=$SCAN_TX
  _scan_text "${os:-unknown}" && os=$SCAN_TX
  rec_line mac host "$PROF_HOST_ID" model "$model" os "$os" user "$SCAN_USER" home "$SCAN_HOME" shell "${SCAN_SHELL:-}" at "$(now_utc)" >"$1/mac.part"
}

# _prof_rescan DIR [resolve] — a fresh scan into DIR's parts, keeping the
# valid profile's choices by item id (a choice for an item that is gone is
# dropped) and writing what is gone and what is new; typed consents never
# survive it. With "resolve", or when the old profile was saved, the new
# inventory is resolved too. PROF_GONE and PROF_NEW count the changes. 1
# when the scan or the resolution cannot be made (PROF_WHY); 2 cancelled.
_prof_rescan() {
  local d=$1 st
  prof_load || return 1
  prof_host_id || { PROF_WHY="this Mac's hardware id cannot be read, so a profile cannot be bound to it" && return 1; }
  scan_run "$d/inventory"
  st=$?
  [ "$st" = 0 ] || { PROF_WHY=${PROF_WHY:-"the scan could not read this Mac's account"}; return "$st"; }
  LC_ALL=C awk -F '\t' -v d="$d" '{ print > (d "/" $1) }' "$d/inventory" || return 1
  : >>"$d/adapter" && : >>"$d/item" || return 1
  _prof_mac "$d" || return 1
  # Choices by item id, only for items still here.
  _prof_person "$d" "$d/select"
  LC_ALL=C awk -F '\t' 'FILENAME == ARGV[1] { ids[$2] = 1; next } $2 in ids' "$d/item" "$PROF_DIR/decision" >"$d/decision"
  : >"$d/consent"
  # What a rescan of a valid profile finds gone and new.
  if [ -s "$PROF_DIR/item" ]; then
    LC_ALL=C awk -F '\t' 'FILENAME == ARGV[1] { old[$2] = 1; o[++n] = $2; next } { now[$2] = 1; w[++m] = $2 }
      END {
        for (i = 1; i <= n; i++) if (!(o[i] in now)) printf "change\tkind=gone\t%s\n", o[i]
        for (i = 1; i <= m; i++) if (!(w[i] in old)) printf "change\tkind=new\t%s\n", w[i]
      }' "$PROF_DIR/item" "$d/item" >"$d/change"
  else
    : >"$d/change"
  fi
  PROF_GONE=$(grep -c 'kind=gone' "$d/change")
  PROF_NEW=$(grep -c 'kind=new' "$d/change")
  : >"$d/resolution"
  if [ "${2:-}" = resolve ] || [ "${PROF_RESOLVED:-0}" = 1 ]; then
    _prof_resolve "$d/item" "$d/decision" "$d/resolution" || return 1
  fi
  return 0
}

# _prof_parts_from_loaded DIR — DIR's parts as the loaded profile has them.
_prof_parts_from_loaded() {
  local t
  cp "$PROF_DIR/mac" "$1/mac.part" || return 1
  for t in adapter item select decision consent resolution change; do cp "$PROF_DIR/$t" "$1/$t" || return 1; done
}

# _prof_newdir — PROF_NEW_DIR: an empty scratch folder for the next write.
_prof_newdir() {
  PROF_NEW_DIR=$OMB_TMP/profile.next.$$
  rm -rf "$PROF_NEW_DIR"
  mkdir -p "$PROF_NEW_DIR"
}

# ---------------------------------------------------------------------------
# The person's choices: one omb-select document
# ---------------------------------------------------------------------------

# prof_select_doc OUT — the arguments select.1 … select.14 joined in number
# order (contiguous from select.1) into OUT; 1 when they are not contiguous
# (PROF_INVALID names the first missing one).
prof_select_doc() {
  local i=1 seen_gap=0 __v
  PROF_INVALID=""
  : >"$1" || return 1
  while [ "$i" -le 14 ]; do
    if core_arg_into "select.$i" __v; then
      if [ "$seen_gap" = 1 ]; then PROF_INVALID="select.$((i - 1))" && return 1; fi
      printf '%s' "$__v" >>"$1" || return 1
    else
      seen_gap=1
    fi
    i=$((i + 1))
  done
}

# prof_select_admit DOC — the omb-select document admitted whole and held to
# the profile: every id one the profile holds; no include for what never
# travels; a decision only one the item offers (when the resolution unit
# says what it offers). 0, or 1 with PROF_CODE and PROF_TEXT.
prof_select_admit() {
  local doc=$1 bad
  PROF_CODE="" PROF_TEXT=""
  if [ ! -s "$doc" ]; then
    printf 'omb-select 1\n' >"$doc"
  fi
  if ! rec_admit_file select - "$doc"; then
    PROF_CODE=invalid PROF_TEXT="The selection document is not an omb-select document ($REC_REASON at line $REC_AT)."
    return 1
  fi
  LC_ALL=C awk -F '\t' 'NR > 1' "$REC_TMP/doc" >"$PROF_DIR/doc.records"
  bad=$(LC_ALL=C awk -F '\t' 'FILENAME == ARGV[1] { st[$1] = $19; next }
    { split($2, a, "="); id = a[2]
      if (!(id in st)) { print "unknown " $2; exit }
      if ($1 == "select" && $3 == "state=include" && st[id] == "never") { print "never " $2; exit } }' \
    "$PROF_DIR/view" "$PROF_DIR/doc.records")
  case "$bad" in
    unknown*) PROF_CODE=invalid PROF_TEXT="The selection names an item the profile does not hold; nothing was saved." && return 1 ;;
    never*) PROF_CODE=invalid PROF_TEXT="The selection includes an item that never travels; nothing was saved." && return 1 ;;
  esac
  if declare -F res_choices >/dev/null && grep -q '^decision	' "$PROF_DIR/doc.records"; then
    res_choices "$PROF_DIR/item" "$PROF_DIR/choices" || { PROF_CODE=invalid PROF_TEXT="The choices the items offer cannot be read." && return 1; }
    bad=$(LC_ALL=C awk -F '\t' 'FILENAME == ARGV[1] { if ($1 == "row") { split($3, k, "="); split($4, c, "="); ok[k[2] "\t" c[2]] = 1 }; next }
      $1 == "decision" { split($2, a, "="); split($3, c, "="); if (!((a[2] "\t" c[2]) in ok)) { print "x"; exit } }' \
      "$PROF_DIR/choices" "$PROF_DIR/doc.records")
    if [ -n "$bad" ]; then PROF_CODE=invalid PROF_TEXT="The selection makes a decision an item does not offer; nothing was saved." && return 1; fi
  fi
  return 0
}

# _prof_basis ACTION EXTRA — PROF_BASIS: the SHA-256 of the canonical basis
# document over the action, the profile's generation and EXTRA (the joined
# document's SHA-256, or a key's id).
_prof_basis() {
  local line
  rec_line_v basis action "$1" generation "$PROF_GEN" value "$2"
  line=$REC_LINE
  PROF_BASIS=$(sha256_str "omb-basis 1
$line
")
}

# _prof_merge TYPE BASE OVER ITEMS OUT — TYPE's records of OVER, and those of
# BASE for an item OVER does not name, in the inventory's order.
_prof_merge() {
  LC_ALL=C awk -F '\t' -v t="$1" 'FILENAME == ARGV[1] { if ($1 == t) base[$2] = $0; next }
    FILENAME == ARGV[2] { if ($1 == t) over[$2] = $0; next }
    $1 == "item" { if ($2 in over) print over[$2]; else if ($2 in base) print base[$2] }' "$2" "$3" "$4" >"$5"
}

# _prof_save_from DOC — the person's choices from an admitted omb-select
# document merged over the profile's: a choice or decision the document
# makes replaces the earlier one for that item, an item it does not name
# keeps its earlier choice and decision, and every other item gets the
# defaults; resolved and saved over the loaded profile's inventory, the
# typed consents reset. 1 with PROF_WHY.
_prof_save_from() {
  local d
  _prof_newdir
  d=$PROF_NEW_DIR
  _prof_parts_from_loaded "$d" || return 1
  _prof_person "$d" "$d/person" || return 1
  _prof_merge select "$d/person" "$PROF_DIR/doc.records" "$d/item" "$d/select" || return 1
  _prof_merge decision "$PROF_DIR/decision" "$PROF_DIR/doc.records" "$d/item" "$d/decision" || return 1
  rm -f "$d/person"
  : >"$d/consent"
  _prof_resolve "$d/item" "$d/decision" "$d/resolution" || return 1
  prof_host_id || return 1
  _prof_write "$d" || { PROF_WHY="profile.omb could not be written; the old one is unchanged" && return 1; }
}

# ---------------------------------------------------------------------------
# The rows of the action table (docs/PROTOCOL.md → *The action table*)
# ---------------------------------------------------------------------------

prof_row() {
  CA_SCOPE=profile CA_INTENT=act CA_TERMINAL=managed CA_CANCEL=0 CA_GATE="" CA_PLATFORM=macos
  CA_PHASE=macos CA_PARAMS="" CA_LIMIT=3 CA_WHY=""
  case "$1" in
    profile.scan)
      CA_FN=prof_scan CA_CANCEL=1 CA_LABEL="Scan this Mac"
      CA_EXPLAIN="Reads Homebrew, applications, language tools, editors, the shell, terminal and Git settings, SSH, the AI tools and your folders as text; nothing runs. Saves the inventory, keeping your choices by item."
      ;;
    profile.save)
      CA_FN=prof_save CA_LABEL="Save the selection"
      CA_PARAMS="select.1 select.2 select.3 select.4 select.5 select.6 select.7 select.8 select.9 select.10 select.11 select.12 select.13 select.14"
      CA_EXPLAIN="Saves what you chose, resolves it with the migration map and your decisions, and binds the profile to this Mac."
      ;;
    profile.opaque)
      CA_FN=prof_opaque CA_GATE=opaque CA_LABEL="Include the chosen folders"
      CA_EXPLAIN="Their contents are not checked field by field, nothing promises they hold no secret, and Shared is not encrypted. Known credential files inside are still refused and the scan still runs."
      ;;
    profile.carry)
      CA_FN=prof_carry CA_GATE=carry CA_PARAMS=key CA_LABEL="Carry an encrypted SSH key"
      CA_EXPLAIN="An encrypted key is still valuable to anyone who copies it: a weak passphrase can be guessed offline. Making a new key on Linux is the better choice. Removing it from Shared later is not secure erasure."
      ;;
    *) return 1 ;;
  esac
}

# The opaque items the saved selection includes and the typed word would cover.
_prof_opaque_rows() {
  LC_ALL=C awk -F '\t' '$9 == "opaque" && ($19 == "include" || ($19 == "decide" && $20 == "person"))' "$PROF_DIR/view"
}

# profile.scan
prof_scan_offer() {
  if ! prof_host_id; then CA_WHY="this Mac's hardware id cannot be read" && return 1; fi
  return 0
}
prof_scan_facts() {
  prof_load || return 1
  rec_line fact scope profile key gate.profile.scan.profile label "Profile" value "$PROF_STATE" state info
  rec_line fact scope profile key gate.profile.scan.generation label "Generation" value "$PROF_GEN" state info
}
prof_scan_params() { :; }
prof_scan_basis() { return 1; }
_prof_scan_progress() {
  case "$1" in
    start) core_emit progress action profile.scan "done" "$(($2 - 1))" total "$3" unit adapter label "$4" ;;
    'done')
      # A response holds its progress records before its messages: each
      # adapter's result is kept and written once the scan has ended.
      local level=ok
      case "$3" in partial | unknown) level=warn ;; denied) level=fail ;; skipped) level=info ;; esac
      printf '%s\t%s\n' "$level" "$2: $3, $4 items${5:+, $5}" >>"$OMB_TMP/scan.messages"
      ;;
  esac
}
prof_scan_run() {
  local st
  prof_load || return 1
  PROF_PRE_GEN=$PROF_GEN
  _prof_newdir
  : >"$OMB_TMP/scan.messages"
  SCAN_PROGRESS=_prof_scan_progress
  _prof_rescan "$PROF_NEW_DIR"
  st=$?
  SCAN_PROGRESS=""
  while IFS='	' read -r level text; do
    core_message "$level" "$text"
  done <"$OMB_TMP/scan.messages"
  [ "$st" = 0 ] || return "$st"
  _prof_write "$PROF_NEW_DIR" || return 1
  [ "$PROF_GONE$PROF_NEW" = 00 ] || core_message info "Since the last scan: $PROF_GONE gone, $PROF_NEW new."
  _prof_sha "$(prof_path)"
  PROF_RUN_GEN=$PROF_SHA
}
prof_scan_judge() {
  PROF_LOADED=""
  _prof_sha "$(prof_path)"
  case "$1" in
    reconcile) _prof_judge_reconcile && return 0 ;;
    0)
      prof_load
      if [ "$PROF_STATE" != invalid ] && [ "$PROF_STATE" != not-scanned ] && [ "$PROF_SHA" = "${PROF_RUN_GEN:-}" ]; then
        CORE_FINDING=completed CORE_JUDGE_TEXT="The inventory is saved ($PROF_STATE)."
        return 0
      fi
      ;;
  esac
  if [ "$PROF_SHA" = "${PROF_PRE_GEN:-}" ]; then
    CORE_FINDING=no-effect CORE_JUDGE_TEXT="Nothing was saved: ${PROF_WHY:-the scan stopped}."
  else
    CORE_FINDING=unexpected CORE_JUDGE_TEXT="profile.omb changed, but not into the inventory this scan made."
  fi
}

# An interrupted write leaves the old document or the new one, never part of
# one (it is renamed into place), and every read derives the state from the
# file: whatever an earlier boot left is a profile the next run reads or
# replaces.
_prof_judge_reconcile() {
  CORE_FINDING=completed CORE_JUDGE_TEXT="profile.omb is whole: its state is read from it."
}

# profile.save
prof_save_offer() {
  prof_load || return 1
  case "$PROF_STATE" in
    scanned | selected | saved) return 0 ;;
  esac
  CA_WHY="there is no inventory to choose from (the profile is $PROF_STATE)"
  return 1
}
prof_save_facts() { :; }
prof_save_params() {
  local i=1
  while [ "$i" -le 14 ]; do
    rec_line param action profile.save name "select.$i" type bytes kind omb-select required 0
    i=$((i + 1))
  done
}
prof_save_basis() {
  local doc
  prof_load || return 1
  doc=$OMB_TMP/select.doc
  prof_select_doc "$doc" || { CORE_BASIS=$(printf '%064d' 0) && return 0; }
  _prof_basis profile.save "$(sha256_of "$doc")"
  CORE_BASIS=$PROF_BASIS
}
prof_save_run() {
  local doc
  prof_load || return 1
  PROF_PRE_GEN=$PROF_GEN
  doc=$OMB_TMP/select.doc
  if ! prof_select_doc "$doc"; then PROF_WHY="the selection arguments are not contiguous" && return 1; fi
  if ! prof_select_admit "$doc"; then PROF_WHY=$PROF_TEXT && return 1; fi
  cp "$PROF_DIR/doc.records" "$OMB_TMP/select.saved" || return 1
  _prof_save_from "$doc"
}
prof_save_judge() {
  PROF_LOADED=""
  [ "$1" = reconcile ] && { _prof_judge_reconcile; return 0; }
  prof_load
  # The read-back: every decision sent stored as sent, and every choice sent
  # standing in the stored selection (an include stored as an include; an
  # exclude never stored as one).
  if [ "$PROF_STATE" != invalid ] && [ "$PROF_STATE" != not-scanned ] && [ "$PROF_RESOLVED" = 1 ] && [ -f "$OMB_TMP/select.saved" ] &&
    LC_ALL=C awk -F '\t' 'FILENAME == ARGV[1] { st[$2] = $3; next } FILENAME == ARGV[2] { dec[$0] = 1; next }
      $1 == "select" { if ($3 == "state=include" && st[$2] != "state=include") bad = 1; if ($3 == "state=exclude" && st[$2] == "state=include") bad = 1 }
      $1 == "decision" && !($0 in dec) { bad = 1 }
      END { exit bad }' "$PROF_DIR/select" "$PROF_DIR/decision" "$OMB_TMP/select.saved"; then
    CORE_FINDING=completed CORE_JUDGE_TEXT="The selection is saved: the profile is $PROF_STATE."
    return 0
  fi
  if [ "$PROF_GEN" = "${PROF_PRE_GEN:-}" ]; then
    CORE_FINDING=no-effect CORE_JUDGE_TEXT="Nothing was saved: ${PROF_WHY:-the save stopped}."
  else
    CORE_FINDING=unexpected CORE_JUDGE_TEXT="profile.omb changed, but does not hold this selection."
  fi
}

# profile.opaque
prof_opaque_offer() {
  prof_load || return 1
  case "$PROF_STATE" in selected | saved) ;; *) CA_WHY="no selection is saved" && return 1 ;; esac
  if ! _prof_opaque_rows | LC_ALL=C awk -F '\t' '$19 == "decide" { f = 1 } END { exit !f }'; then
    CA_WHY="no chosen folder waits for the typed word"
    return 1
  fi
}
prof_opaque_facts() {
  local n=0 path size
  prof_load || return 1
  rec_line fact scope profile key gate.profile.opaque.profile label "Profile" value "$PROF_GEN" state info
  _prof_opaque_rows | LC_ALL=C awk -F '\t' '{ print $10 "\t" $11 }' >"$PROF_DIR/opaque.facts"
  while IFS='	' read -r path size; do
    n=$((n + 1))
    _rec_dec_into path "$path"
    _scan_text "$path"
    rec_line fact scope profile key "gate.profile.opaque.path.$n" label "Opaque path" value "$SCAN_TX (${size:-unknown} bytes)" state warn
  done <"$PROF_DIR/opaque.facts"
  rec_line fact scope profile key gate.profile.opaque.count label "Covered" value "$n opaque paths" state warn
  rec_line fact scope profile key gate.profile.opaque.warning label "Not checked" value \
    "Their contents are not checked field by field; nothing promises they hold no secret; Shared is not encrypted." state warn
}
prof_opaque_params() { :; }
prof_opaque_basis() { return 1; }
prof_opaque_run() {
  local d
  prof_load || return 1
  PROF_PRE_GEN=$PROF_GEN
  _prof_newdir
  d=$PROF_NEW_DIR
  _prof_parts_from_loaded "$d" || return 1
  LC_ALL=C awk -F '\t' '!($1 == "consent" && $2 == "word=opaque")' "$PROF_DIR/consent" >"$d/consent"
  rec_line consent word opaque id "" at "$(now_utc)" >>"$d/consent" || return 1
  prof_host_id || return 1
  _prof_write "$d"
}
prof_opaque_judge() {
  PROF_LOADED=""
  [ "$1" = reconcile ] && { _prof_judge_reconcile; return 0; }
  prof_load
  if [ "$PROF_STATE" != invalid ] && grep -q '	word=opaque	' "$PROF_DIR/consent"; then
    CORE_FINDING=completed CORE_JUDGE_TEXT="The chosen folders are included."
  elif [ "$PROF_GEN" = "${PROF_PRE_GEN:-}" ]; then
    CORE_FINDING=no-effect CORE_JUDGE_TEXT="Nothing was saved."
  else
    CORE_FINDING=unexpected CORE_JUDGE_TEXT="profile.omb changed, but holds no typed opaque."
  fi
}

# profile.carry
_prof_key_rows() { LC_ALL=C awk -F '\t' '$2 == "key-encrypted" && $19 != "include"' "$PROF_DIR/view"; }
prof_carry_offer() {
  prof_load || return 1
  case "$PROF_STATE" in selected | saved) ;; *) CA_WHY="no selection is saved" && return 1 ;; esac
  if [ -z "$(_prof_key_rows)" ]; then CA_WHY="no encrypted SSH key waits for the typed word" && return 1; fi
}
prof_carry_facts() { :; }
prof_carry_params() { rec_line param action profile.carry name key type bytes kind item required 1; }
# The review whose basis profile.carry's execute is held to (the core calls
# a row's own validation for `validate select action=profile.carry`).
prof_carry_validate() { prof_core_op validate; }
prof_save_validate() { prof_core_op validate; }
# _prof_carry_key KEY — the key's item is an encrypted SSH key the profile
# holds and does not include yet, and its envelope, read again now, still
# shows a supported policy: PROF_KEY_REL is its home-relative path.
_prof_carry_key() {
  local rel
  PROF_KEY_REL=""
  [ -n "$1" ] || return 1
  rec_enc_v "$1"
  rel=$(_prof_key_rows | LC_ALL=C awk -F '\t' -v id="$REC_ENC" '$1 == id { print $10; exit }')
  [ -n "$rel" ] || return 1
  _rec_dec_into PROF_KEY_REL "$rel"
  _scan_identity || return 1
  scan_ssh_key "$(_scan_h "$PROF_KEY_REL")"
}
prof_carry_basis() {
  local key
  prof_load || return 1
  core_arg_into key key
  _prof_basis profile.carry "$key"
  CORE_BASIS=$PROF_BASIS
}
prof_carry_run() {
  local key d
  prof_load || return 1
  PROF_PRE_GEN=$PROF_GEN
  core_arg_into key key
  if ! _prof_carry_key "$key"; then PROF_WHY="that is not an encrypted SSH key with a supported policy" && return 1; fi
  _prof_newdir
  d=$PROF_NEW_DIR
  _prof_parts_from_loaded "$d" || return 1
  rec_enc_v "$key"
  LC_ALL=C awk -F '\t' -v id="id=$REC_ENC" '$2 != id' "$PROF_DIR/select" >"$d/select"
  rec_line select id "$key" state include >>"$d/select" || return 1
  rec_line consent word carry id "$key" at "$(now_utc)" >>"$d/consent" || return 1
  PROF_CARRY_KEY=$key
  prof_host_id || return 1
  _prof_write "$d"
}
prof_carry_judge() {
  PROF_LOADED=""
  [ "$1" = reconcile ] && { _prof_judge_reconcile; return 0; }
  prof_load
  rec_enc_v "${PROF_CARRY_KEY:-}"
  if [ "$PROF_STATE" != invalid ] && [ -n "${PROF_CARRY_KEY:-}" ] && grep -q "	word=carry	id=$REC_ENC	" "$PROF_DIR/consent"; then
    CORE_FINDING=completed CORE_JUDGE_TEXT="The key travels with the next export."
  elif [ "$PROF_GEN" = "${PROF_PRE_GEN:-}" ]; then
    CORE_FINDING=no-effect CORE_JUDGE_TEXT="Nothing was saved: ${PROF_WHY:-the step stopped}."
  else
    CORE_FINDING=unexpected CORE_JUDGE_TEXT="profile.omb changed, but holds no typed carry for that key."
  fi
}

# ---------------------------------------------------------------------------
# Scope `profile` on the wire (docs/MIGRATION.md → *On the wire*)
# ---------------------------------------------------------------------------

# _prof_respond OP BODY STATUS CODE [TEXT] — the response: the live prefix,
# BODY's records, the result; staged, admitted whole, and published as its
# admitted copy (lib/read.sh), or an error result when it cannot be.
_prof_respond() {
  local st
  if ! core_read_prefix || ! {
    cat "$OMB_TMP/journey.prefix" && cat "$2" && rec_line result status "$3" code "$4" text "${5:-}" next ''
  } >"$OMB_TMP/profile.response"; then
    core_result error io "The profile response could not be prepared."
    return
  fi
  core_read_admit "$1" "$OMB_TMP/profile.response"
  st=$?
  case "$st" in
    0) core_read_publish ;;
    2) core_result error representation "The profile response cannot be represented in Protocol 1." ;;
    *) core_result error io "The profile response could not be prepared." ;;
  esac
}

prof_core_op() {
  if ! prof_load; then
    core_result error io "The profile could not be read."
    return
  fi
  case "$1" in
    snapshot) _prof_snapshot ;;
    detail) _prof_detail ;;
    validate) _prof_validate ;;
    *) core_result refused unavailable "The profile answers snapshot, detail and validate." ;;
  esac
}

# _prof_fact KEY LABEL VALUE STATE — one fact of scope profile, its text
# made safe to render.
_prof_fact() {
  _scan_text "$3"
  rec_line fact scope profile key "$1" label "$2" value "$SCAN_TX" state "$4"
}

_prof_snapshot() {
  local body=$OMB_TMP/profile.body st v a s n note mac="" model os user at cat line
  core_rows_snapshot "$PROF_IDS" >/dev/null || { core_result error io "The profile's actions could not be read."; return; }
  {
    rec_line generation id "$PROF_GEN" total 0
    case "$PROF_STATE" in saved) st=ok ;; selected) st=warn ;; invalid) st=fail ;; not-scanned) st=unknown ;; *) st=info ;; esac
    _prof_fact profile.state "Profile" "$PROF_STATE" "$st"
    if [ -s "$PROF_DIR/mac" ]; then
      line=$(cat "$PROF_DIR/mac")
      _rec_field_raw "$line" model && _rec_dec_into model "$REC_RAW"
      _rec_field_raw "$line" os && _rec_dec_into os "$REC_RAW"
      _rec_field_raw "$line" user && _rec_dec_into user "$REC_RAW"
      _rec_field_raw "$line" at && at=$REC_RAW
      mac="$model · macOS $os · $user"
      _prof_fact profile.mac "Mac" "$mac" info
      _prof_fact profile.scanned "Scanned" "$at" info
      LC_ALL=C awk -F '\t' '{ n++; if ($19 == "include") i++; if ($19 == "decide") d++ } END { printf "%d items · %d selected · %d to decide\n", n, i, d }' "$PROF_DIR/view" >"$PROF_DIR/counts"
      _prof_fact profile.counts "Items" "$(cat "$PROF_DIR/counts")" info
      while IFS= read -r line; do
        _rec_field_raw "$line" id && a=$REC_RAW
        _rec_field_raw "$line" state && s=$REC_RAW
        _rec_field_raw "$line" items && n=$REC_RAW
        _rec_field_raw "$line" note && _rec_dec_into note "$REC_RAW"
        case "$s" in done) st=ok ;; partial) st=warn ;; denied) st=fail ;; skipped) st=info ;; *) st=unknown ;; esac
        _prof_fact "adapter.$a" "$a" "$s · $n items${note:+ · $note}" "$st"
      done <"$PROF_DIR/adapter"
      for cat in ${REC_CATEGORIES//|/ }; do
        v=$(LC_ALL=C awk -F '\t' -v c="$cat" '$3 == c { t++; if ($19 == "include") { i++; b += $11 }; if ($19 == "decide") d++ }
          END { printf "%d of %d · %d bytes %d\n", i, t, b, d }' "$PROF_DIR/view")
        st=info
        [ "${v##* }" = 0 ] || st=warn
        _prof_fact "category.$cat" "$cat" "${v% *}" "$st"
      done
      if [ -s "$PROF_DIR/change" ]; then
        _prof_fact change.gone "Gone since the last scan" "$(grep -c 'kind=gone' "$PROF_DIR/change")" info
        _prof_fact change.new "New since the last scan" "$(grep -c 'kind=new' "$PROF_DIR/change")" info
      fi
    fi
    cat "$OMB_TMP/rows.facts"
    case "$PROF_STATE" in
      invalid) rec_line blocker id profile.invalid text "The profile cannot be used: $PROF_WHY." fix "Scan again: the next profile replaces it." ;;
      not-scanned) rec_line blocker id profile.none text "There is no profile yet." fix "Scan this Mac." ;;
    esac
    prof_host_id || rec_line blocker id profile.host text "This Mac's hardware id cannot be read, so a profile cannot be bound to it." fix ""
    cat "$OMB_TMP/rows.blockers" "$OMB_TMP/rows.actions" "$OMB_TMP/rows.params"
  } >"$body" || { core_result error io "The profile snapshot could not be prepared."; return; }
  _prof_respond snapshot "$body" "done" ok
}

# _PROF_ROWS_AWK — a detail kind's rows over the view (kind in -v k).
# shellcheck disable=SC2016 # awk source
_PROF_ROWS_AWK='
function becomes(   s, m) {
  s = $13
  if (s == "resolved") {
    if ($14 == "files" || $14 == "settings") m = "carried"
    else { m = dec($15); if ($16 != "") m = m " " dec($16); if ($17 != "") m = m "@" dec($17) }
    if ($18 == 1) m = m " (a guess)"
    return m
  }
  if (s == "needs-decision") return "choose"
  if (s == "unsupported") return "not for this Linux"
  if (s == "mac-only") return "macOS only"
  return s
}
function row(key, n,   i, o) {
  o = "row\tkind=" k "\tkey=" key
  for (i = 1; i <= n; i++) o = o "\tcol=" C[i]
  print o
}
k == "item" {
  C[1] = $3; C[2] = etext($4); C[3] = etext($6); C[4] = etext($5); C[5] = enc(text(becomes()))
  C[6] = $19; C[7] = $9; C[8] = $20; C[9] = $21; C[10] = ($11 == "" ? "0" : $11); C[11] = $8; C[12] = $7
  r = "row\tkind=item\tkey=" $1
  for (i = 1; i <= 12; i++) r = r "\tcol=" C[i]
  if ($19 == "decide") print r; else later[++nl] = r
  next
}
k == "opaque" && $9 == "opaque" && ($19 == "include" || ($19 == "decide" && $20 == "person")) { C[1] = etext($10); C[2] = ($11 == "" ? "0" : $11); row($1, 2); next }
k == "key" && $2 == "key-encrypted" { C[1] = etext($10); C[2] = etext($6); C[3] = etext($5); row($1, 3); next }
END { for (i = 1; i <= nl; i++) print later[i] }'

_prof_detail() {
  local rows=$OMB_TMP/profile.rows cat label
  : >"$rows"
  case "$CORE_REQ_KIND" in
    items | opaque | keys)
      LC_ALL=C awk -v k="${CORE_REQ_KIND%s}" "$_PROF_AWK_LIB"'
'"$_PROF_ROWS_AWK" FS='\t' "$PROF_DIR/view" >"$rows"
      ;;
    choices)
      if declare -F res_choices >/dev/null && [ -s "$PROF_DIR/item" ]; then
        res_choices "$PROF_DIR/item" "$rows" || { core_result error io "The choices could not be read."; return; }
      fi
      ;;
    review)
      for cat in ${REC_CATEGORIES//|/ }; do
        case "$cat" in
          software) label=Software ;; apps) label=Apps ;; terminal) label=Terminal ;; editors) label=Editors ;;
          ai) label=AI ;; folders) label=Folders ;; git-ssh) label="Git & SSH" ;; *) label=Secrets ;;
        esac
        LC_ALL=C awk -F '\t' -v c="$cat" '$3 == c { t++; if ($19 == "include") { i++; b += $11 }; if ($19 == "decide") d++; if ($19 == "never") n++ }
          END { printf "%d of %d\t%d\t%s\n", i, t, b, d ? d " wait for you" : (i ? "ready" : (n ? "never carried" : "nothing selected")) }' \
          "$PROF_DIR/view" >"$OMB_TMP/review.line"
        IFS='	' read -r a b c <"$OMB_TMP/review.line"
        rec_line row kind review key "$cat" col "$label" col "$a" col "$b" col "$c" >>"$rows"
      done
      ;;
    changes)
      LC_ALL=C awk -F '\t' "$_PROF_AWK_LIB"'
        FILENAME == ARGV[1] { split($0, f, "\t"); name[f[1]] = f[4]; next }
        { rec($0); id = F["id"]; printf "row\tkind=change\tkey=%s\tcol=%s\tcol=%s\n", id, F["kind"], (id in name) ? etext(name[id]) : etext(id) }' \
        "$PROF_DIR/view" "$PROF_DIR/change" >"$rows"
      ;;
    *)
      core_result refused unavailable "The profile has no detail of that kind."
      return
      ;;
  esac
  core_read_page "$PROF_GEN" "$(cat "$rows")"
}

# _prof_invalid NAME CODE TEXT — a validation's refusal of one argument.
_prof_invalid() { rec_line invalid name "$1" code "$2" text "$3" >>"$OMB_TMP/profile.body"; }

_prof_validate() {
  local body=$OMB_TMP/profile.body i=0 n key
  : >"$body"
  case "$PROF_STATE" in
    scanned | selected | saved) ;;
    *)
      _prof_respond validate "$body" refused unavailable "There is no inventory to choose from (the profile is $PROF_STATE)."
      return
      ;;
  esac
  case "$CORE_REQ_SELECT" in
    profile.save)
      while [ "$i" -lt "$CORE_REQ_ARGS" ]; do
        n=${CORE_REQ_ARG_NAME[i]}
        case "$n" in select.[1-9] | select.1[0-4]) ;; *) _prof_invalid "$n" unknown-parameter "profile.save takes select.1 to select.14." ;; esac
        i=$((i + 1))
      done
      if [ -s "$body" ]; then
        _prof_respond validate "$body" refused invalid
        return
      fi
      if ! prof_select_doc "$OMB_TMP/select.doc"; then
        _prof_invalid "$PROF_INVALID" gap "The selection's parts must run from select.1 without a gap."
        _prof_respond validate "$body" refused invalid
        return
      fi
      if ! prof_select_admit "$OMB_TMP/select.doc"; then
        _prof_invalid select.1 "$PROF_CODE" "$PROF_TEXT"
        _prof_respond validate "$body" refused invalid
        return
      fi
      _prof_basis profile.save "$(sha256_of "$OMB_TMP/select.doc")"
      ;;
    profile.carry)
      core_arg_into key key
      if ! _prof_carry_key "$key"; then
        _prof_invalid key not-a-key "That is not an encrypted SSH key with a supported policy that waits for carry."
        _prof_respond validate "$body" refused invalid
        return
      fi
      _prof_basis profile.carry "$key"
      ;;
    *)
      _prof_respond validate "$body" refused unavailable "The profile validates profile.save and profile.carry."
      return
      ;;
  esac
  rec_line review action "$CORE_REQ_SELECT" basis "$PROF_BASIS" >>"$body"
  _prof_respond validate "$body" "done" ok
}

# ---------------------------------------------------------------------------
# The text interface: `profile` and `profile show [--unresolved]`
# ---------------------------------------------------------------------------

prof_cmd() {
  case "${1:-}" in
    '') _prof_cmd_save ;;
    show) _prof_cmd_show "${2:-}" ;;
    *) ui_fail "profile takes nothing, show, or show --unresolved." && return 2 ;;
  esac
}

_prof_cmd_save() {
  local st
  ui_header "profile"
  ui_section "Scanning this Mac" "read as text; nothing runs"
  prof_load || return 1
  _prof_newdir
  SCAN_PROGRESS=_scan_cmd_progress
  _prof_rescan "$PROF_NEW_DIR" resolve
  st=$?
  SCAN_PROGRESS=""
  if [ "$st" != 0 ]; then
    ui_fail "Nothing was saved: $PROF_WHY."
    return 1
  fi
  if ! _prof_write "$PROF_NEW_DIR"; then
    ui_fail "profile.omb could not be written; the old one is unchanged."
    return 1
  fi
  if [ "$OMB_PERSIST" != 1 ] || [ "$OMB_DRY_RUN" = 1 ]; then
    ui_would "save $(tildify "$(prof_path)")"
    return 0
  fi
  PROF_LOADED=""
  prof_load || return 1
  [ "$PROF_GONE$PROF_NEW" = 00 ] || ui_note "Since the last scan: $PROF_GONE gone, $PROF_NEW new."
  _prof_cmd_review
  ui_note "Saved with your earlier choices and the defaults. Chosen folders and encrypted SSH keys are never included here: the interface asks for the typed words they need."
  printf '\n'
}

_prof_cmd_review() {
  local cat a b c
  ui_section "Migration review" "$PROF_STATE"
  for cat in ${REC_CATEGORIES//|/ }; do
    LC_ALL=C awk -F '\t' -v c="$cat" '$3 == c { t++; if ($19 == "include") { i++; b += $11 }; if ($19 == "decide") d++ }
      END { printf "%d of %d\t%d bytes\t%s\n", i, t, b, d ? d " wait for a decision" : "" }' "$PROF_DIR/view" >"$OMB_TMP/review.line"
    IFS='	' read -r a b c <"$OMB_TMP/review.line"
    ui_kv "$cat" "$a selected, $b" "$c"
  done
}

_prof_cmd_show() {
  ui_header "profile"
  prof_load || return 1
  case "$PROF_STATE" in
    not-scanned)
      ui_note "No profile yet: ./omarchy-bootstrap profile scans this Mac and saves one."
      printf '\n'
      return 0
      ;;
    invalid)
      ui_warn "The profile cannot be used: $PROF_WHY."
      printf '\n'
      return 1
      ;;
  esac
  if [ "$1" = --unresolved ]; then
    # The unresolved items as records, with everything known about them, for
    # the person to read or give to their own agent.
    LC_ALL=C awk -F '\t' 'FILENAME == ARGV[1] { if ($13 == "unresolved" || $13 == "needs-decision") want["id=" $1] = 1; next }
      FILENAME == ARGV[2] { res[$2] = $0; next }
      $2 in want { print; if ($2 in res) print res[$2] }' \
      "$PROF_DIR/view" "$PROF_DIR/resolution.view" "$PROF_DIR/item"
    return 0
  fi
  _prof_cmd_review
  printf '\n'
}
