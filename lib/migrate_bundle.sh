# shellcheck shell=bash
# Export and the bundle check (docs/MIGRATION.md → *The bundle*; D21, D39).
#
# export writes a new bundle each time, to verified Shared or to a folder
# the person names: hash-named plain objects and one sealed bundle.omb,
# inside omarchy-mac-bootstrap/bundles/<utc>.partial-<random>/, renamed to
# <utc> once the whole bundle reads back. Export never deletes anything
# there: a failure leaves only its .partial-* folder, which restore never
# lists. Every captured file is classified over the bytes it carries.
#
# bndl_check is the bundle check restore reuses on Linux: Bash 3.2 or 5,
# BSD or GNU tools, reading only the names bundle.omb lists. Needs
# lib/records.sh, lib/common.sh and lib/state.sh; export also needs the
# scanner's seams (scan_run, scan_extract, scan_secret_check, scan_key_check),
# the profile's prof_host_id, and lib/shared.sh to find verified Shared.

BNDL_MAX_OBJECT=67108864
BNDL_MAX_TOTAL=2147483648

# _recx_bundle WHAT [TYPE] — the stored family `bundle` (lib/records.sh →
# _recx): the export's time, Mac and counts; each carried item's class; an
# entry per folder, file and link; the settings, packages and macOS paths
# restore needs; what was left behind, with the reason.
_recx_bundle() {
  case "$1" in
    family) REC_HDR="omb-bundle 1" REC_MAX_BYTES=16777216 REC_MAX_RECS=0 REC_SEALED=1
      REC_ORDER="bundle item dir file link setting package macpath skip" ;;
    spec)
      case "$2" in
        bundle) REC_SPEC="at:utc host:hex16 model:text user:bytes home:bytes items:uint files:uint bytes:uint" ;;
        item) REC_SPEC="id:bytes class:enum(config|sensitive|opaque|secret|mac-only) whole:bool" ;;
        dir) REC_SPEC="item:bytes dest:bytes mode:enum(0700|0755)" ;;
        file) REC_SPEC="item:bytes dest:bytes mode:enum(0600|0644|0700|0755) sha256:hex64 size:uint whole:bool" ;;
        link) REC_SPEC="item:bytes dest:bytes target:bytes" ;;
        setting) REC_SPEC="item:bytes kind:enum(git|mcp|plugin) tool:id name:bytes value:bytes?" ;;
        package) REC_SPEC="item:bytes layer:enum(packages|runtimes|tools|ai) method:id target:bytes? version:bytes? guess:bool" ;;
        macpath) REC_SPEC="item:bytes dest:bytes path:bytes" ;;
        skip) REC_SPEC="item:bytes reason:text" ;;
        *) return 1 ;;
      esac
      ;;
    card)
      REC_CARD='*'
      [ "$2" = bundle ] && REC_CARD=1
      return 0
      ;;
    unique)
      REC_UKEYS=""
      [ "$2" = item ] && REC_UKEYS="id"
      return 0
      ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# The bundle check
# ---------------------------------------------------------------------------

# _bndl_sha FILE — BNDL_SHA: the lowercase hex SHA-256 of FILE's bytes,
# every stage's status checked.
_bndl_sha() {
  local out
  if command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 <"$1") || return 1
  else
    out=$(sha256sum <"$1") || return 1
  fi
  BNDL_SHA=${out%% *}
  _whole "$BNDL_SHA" '^[0-9a-f]{64}$'
}

# _bndl_size FILE — BNDL_SIZE: FILE's size in bytes.
_bndl_size() {
  BNDL_SIZE=$(wc -c <"$1") || return 1
  BNDL_SIZE=${BNDL_SIZE//[!0-9]/}
  [ -n "$BNDL_SIZE" ]
}

# _bndl_dest_awk MODE — the destination rules over "item<TAB>type<TAB>dest
# <TAB>target" lines (written values, items contiguous). Each entry: not
# empty, not absolute, no empty, "." or ".." component, no control byte,
# components at most 255 bytes, 1 024 in all, 32 deep; a link's text
# relative, with no control byte, never climbing above the home. All
# together: no dest twice, nothing beneath a file or a link, no file or link
# where another entry needs a folder, and no link whose target passes
# through or names another link the bundle places (a chain such as a -> .
# and b -> a/.. leaves the home). strict (the bundle check): the first
# failure, "line<TAB>why", and status 1. items (export): every item whose
# entries break a rule against itself or the items accepted before it,
# "item<TAB>why", that item's entries taken back; then every item with a
# link through another accepted link.
# shellcheck disable=SC2016 # awk source: awk expands its own variables
BNDL_DEST_AWK='
function bytes(s,   t) { t = s; return length(s) - 2 * gsub(/%/, "", t) }
function grammar(d,   n, c, i) {
  if (d == "") return "an empty destination"
  if (substr(d, 1, 1) == "/") return "an absolute destination"
  if (d ~ /%(0[0-9A-F]|1[0-9A-F]|7F)/) return "a control byte in a destination"
  if (bytes(d) > 1024) return "a destination over 1024 bytes"
  n = split(d, c, "/")
  if (n > 32) return "a destination over 32 deep"
  for (i = 1; i <= n; i++) {
    if (c[i] == "" || c[i] == "." || c[i] == "..") return "an empty, . or .. component in a destination"
    if (bytes(c[i]) > 255) return "a destination component over 255 bytes"
  }
  return ""
}
function linkok(d, t,   n, c, i, depth) {
  if (t == "") return "a link with no text"
  if (substr(t, 1, 1) == "/") return "a link with an absolute target"
  if (t ~ /%(0[0-9A-F]|1[0-9A-F]|7F)/) return "a control byte in a link target"
  depth = split(d, c, "/") - 1
  n = split(t, c, "/")
  for (i = 1; i <= n; i++) {
    if (c[i] == "" || c[i] == ".") continue
    if (c[i] == "..") { if (--depth < 0) return "a link whose target climbs out of the home" }
    else depth++
  }
  return ""
}
function together(ty, d,   n, c, i, p) {
  if (d in kind) return "two entries with one destination"
  if (ty != "dir" && (d in under)) return "an entry beneath a file or a link"
  n = split(d, c, "/")
  p = ""
  for (i = 1; i < n; i++) {
    p = (i == 1) ? c[1] : p "/" c[i]
    if ((p in kind) && kind[p] != "dir") return "an entry beneath a file or a link"
  }
  return ""
}
function through(d, t,   n, c, i, s, st, p, k) {
  n = split(d, c, "/")
  s = n - 1
  for (i = 1; i < n; i++) st[i] = c[i]
  n = split(t, c, "/")
  for (i = 1; i <= n; i++) {
    if (c[i] == "" || c[i] == ".") continue
    if (c[i] == "..") { if (--s < 0) return "a link whose target climbs out of the home"; continue }
    st[++s] = c[i]
    p = st[1]
    for (k = 2; k <= s; k++) p = p "/" st[k]
    if ((p in kind) && kind[p] == "link") return "a link whose target passes through another link of the bundle"
  }
  return ""
}
function add(ty, d, t,   n, c, i, p) {
  kind[d] = ty
  n = split(d, c, "/")
  p = ""
  for (i = 1; i < n; i++) { p = (i == 1) ? c[1] : p "/" c[i]; under[p]++ }
  added[++na] = d
  if (ty == "link") { ld[++nl] = d; lt[nl] = t; lline[nl] = NR; litem[nl] = cur }
}
function takeback(   k, d, n, c, i, p) {
  for (k = 1; k <= na; k++) {
    d = added[k]
    delete kind[d]
    n = split(d, c, "/")
    p = ""
    for (i = 1; i < n; i++) { p = (i == 1) ? c[1] : p "/" c[i]; if (--under[p] == 0) delete under[p] }
  }
  nl = lstart
}
function close_item() { if (cur != "" && bad != "") { print cur "\t" bad; takeback() } na = 0; bad = "" }
BEGIN { FS = "\t"; cur = ""; na = 0; nl = 0; lstart = 0; bad = "" }
{
  if ($1 != cur) { close_item(); cur = $1; lstart = nl }
  if (mode == "items" && bad != "") next
  why = grammar($3)
  if (why == "" && $2 == "link") why = linkok($3, $4)
  if (why == "") why = together($2, $3)
  if (why != "") {
    if (mode == "strict") { print NR "\t" why; failed = 1; exit 1 }
    bad = why
    next
  }
  add($2, $3, $4)
}
END {
  if (failed) exit 1
  if (mode == "items") close_item()
  # Once every entry is known: a link whose target passes through a link
  # the bundle itself places resolves elsewhere than its text says.
  for (k = 1; k <= nl; k++) {
    why = through(ld[k], lt[k])
    if (why == "") continue
    if (mode == "strict") { print lline[k] "\t" why; exit 1 }
    if (!(litem[k] in shown)) { print litem[k] "\t" why; shown[litem[k]] = 1 }
  }
}'

# bndl_check DIR — the bundle check: bundle.omb admitted with its seal;
# every destination against the grammar, then all of them together; every
# object a plain file of its recorded size whose bytes have its digest.
# Reads only the names bundle.omb lists (the ._* and .DS_Store files macOS
# leaves on exFAT are never read). 0; 1 at the first failure, BNDL_WHY
# saying which.
bndl_check() {
  local dir=$1 i=0 f line st seen=" " sha size
  BNDL_WHY=""
  if [ ! -d "$dir" ] || [ -L "$dir" ]; then
    BNDL_WHY="$dir is not a folder"
    return 1
  fi
  f=$dir/bundle.omb
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    BNDL_WHY="it has no bundle.omb"
    return 1
  fi
  if ! rec_admit_file bundle - "$f"; then
    BNDL_WHY="bundle.omb does not admit (${REC_REASON:-io} at line ${REC_AT:-0})"
    return 1
  fi
  omb_tmp_init || { BNDL_WHY="no scratch folder"; return 1; }
  : >"$OMB_TMP/bndl.check" || { BNDL_WHY="no scratch folder"; return 1; }
  while [ "$i" -lt "$REC_N" ]; do
    line=${REC_L[i]}
    case "${REC_T[i]}" in
      dir | file | link)
        _rec_field_raw "$line" item
        f=$REC_RAW
        _rec_field_raw "$line" dest
        f="$f	${REC_T[i]}	$REC_RAW"
        _rec_field_raw "$line" target
        printf '%s\t%s\n' "$f" "$REC_RAW" >>"$OMB_TMP/bndl.check" || { BNDL_WHY="no scratch folder"; return 1; }
        ;;
    esac
    i=$((i + 1))
  done
  LC_ALL=C awk -v mode=strict "$BNDL_DEST_AWK" "$OMB_TMP/bndl.check" >"$OMB_TMP/bndl.why"
  st=$?
  if [ "$st" != 0 ]; then
    BNDL_WHY="a destination breaks the rules: $(cut -f2 "$OMB_TMP/bndl.why")"
    return 1
  fi
  i=0
  while [ "$i" -lt "$REC_N" ]; do
    if [ "${REC_T[i]}" = file ]; then
      _rec_field_raw "${REC_L[i]}" sha256
      sha=$REC_RAW
      _rec_field_raw "${REC_L[i]}" size
      size=$REC_RAW
      f=$dir/objects/$sha
      # Every file record's size and limit, a repeated object's included;
      # only the hashing is done once per object.
      if [ -L "$dir/objects" ] || [ ! -f "$f" ] || [ -L "$f" ]; then
        BNDL_WHY="object $sha is missing or not a plain file"
        return 1
      fi
      if [ "$size" -gt "$BNDL_MAX_OBJECT" ] || ! _bndl_size "$f" || [ "$BNDL_SIZE" != "$size" ]; then
        BNDL_WHY="object $sha is not the size bundle.omb records"
        return 1
      fi
      case "$seen" in
        *" $sha "*) ;;
        *)
          seen="$seen$sha "
          if ! _bndl_sha "$f" || [ "$BNDL_SHA" != "$sha" ]; then
            BNDL_WHY="object $sha does not match its digest"
            return 1
          fi
          ;;
      esac
    fi
    i=$((i + 1))
  done
  return 0
}

# ---------------------------------------------------------------------------
# Export: the profile, the destination, the capture
# ---------------------------------------------------------------------------

# _bndl_say LEVEL TEXT — a line for the person: a message record when the
# core runs the row, the text interface's own line otherwise.
_bndl_say() {
  if [ "${BNDL_CORE:-0}" = 1 ]; then
    core_message "$1" "$2"
    return
  fi
  case "$1" in
    ok) ui_ok "$2" ;;
    warn) ui_warn "$2" ;;
    fail) ui_fail "$2" ;;
    *) ui_info "$2" ;;
  esac
}

# bndl_profile_load — the saved profile, its records split into the export's
# scratch folder (BNDL_W): p.mac, p.item, p.select, p.decision, p.consent,
# p.resolution. 0 saved; 1 with BNDL_STATE (none, invalid, other-mac,
# not-saved) and BNDL_WHY. BNDL_PROFILE_SHA: its SHA-256.
bndl_profile_load() {
  local f=$OMB_STATE_DIR/profile.omb i=0 t host id st
  BNDL_STATE=none BNDL_WHY="" BNDL_PROFILE_SHA=""
  omb_tmp_init || { BNDL_WHY="no scratch folder"; return 1; }
  BNDL_W=$OMB_TMP/export
  mkdir -p "$BNDL_W" || { BNDL_WHY="no scratch folder"; return 1; }
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    BNDL_WHY="No profile is saved: run ./omarchy-bootstrap profile first."
    return 1
  fi
  BNDL_STATE=invalid
  if ! _state_file_ok "$f" || ! rec_admit_file profile - "$f"; then
    BNDL_WHY="The profile cannot be read (${REC_REASON:-not a plain file of yours}); the next ./omarchy-bootstrap profile replaces it."
    return 1
  fi
  _bndl_sha "$f" || { BNDL_WHY="The profile cannot be read."; return 1; }
  BNDL_PROFILE_SHA=$BNDL_SHA
  for t in mac item select decision consent resolution; do : >"$BNDL_W/p.$t" || return 1; done
  while [ "$i" -lt "$REC_N" ]; do
    t=${REC_T[i]}
    case "$t" in
      mac | item | select | decision | consent | resolution) printf '%s\n' "${REC_L[i]}" >>"$BNDL_W/p.$t" || return 1 ;;
    esac
    i=$((i + 1))
  done
  rec_find mac
  rec_get_into host "$REC_AT_I" host
  if ! declare -F prof_host_id >/dev/null || ! prof_host_id; then
    BNDL_WHY="This Mac's identity cannot be read, so the profile cannot be held to it."
    return 1
  fi
  if [ "$host" != "$PROF_HOST_ID" ]; then
    BNDL_STATE=other-mac
    BNDL_WHY="The profile was made on another Mac (a Time Machine restore brings the everyday Mac's); the next ./omarchy-bootstrap profile replaces it."
    return 1
  fi
  # Saved: a selection, and every included item resolved or unsupported.
  BNDL_STATE=not-saved
  if ! grep -q '	state=include' "$BNDL_W/p.select"; then
    BNDL_WHY="The profile holds no selection yet: choose what to carry with ./omarchy-bootstrap profile."
    return 1
  fi
  while IFS= read -r t; do
    _rec_field_raw "$t" state
    [ "$REC_RAW" = include ] || continue
    _rec_field_raw "$t" id
    id=$REC_RAW
    st=$(awk -F'\t' -v k="id=$id" '$2 == k { for (i = 3; i <= NF; i++) if ($i ~ /^state=/) { s = $i; sub(/^state=/, "", s); print s } exit }' "$BNDL_W/p.resolution")
    case "$st" in
      resolved | unsupported | mac-only | skipped) ;;
      *)
        BNDL_WHY="An included item still needs a decision ($st): finish it with ./omarchy-bootstrap profile."
        return 1
        ;;
    esac
  done <"$BNDL_W/p.select"
  BNDL_STATE=saved
}

# _bndl_dest DIR — BNDL_DEST: DIR when one is named (a folder that exists),
# otherwise the mount point the baseline verifies for Shared's GUID. 1 with
# BNDL_WHY when there is none.
_bndl_dest() {
  BNDL_DEST="" BNDL_WHY="" BNDL_SHARED=""
  if [ -n "$1" ]; then
    case "$1" in
      /*) ;;
      *)
        BNDL_WHY="Name the folder by its full path (it starts with /)."
        return 1
        ;;
    esac
    if [ ! -d "$1" ]; then
      BNDL_WHY="$1 is not a folder."
      return 1
    fi
    BNDL_DEST=${1%/}
    [ -n "$BNDL_DEST" ] || BNDL_DEST=/
    return 0
  fi
  mac_detect >/dev/null 2>&1
  cfg_load
  shared_mac_state >/dev/null 2>&1
  if [ "$SHARED_STATE" != created ] || [ -z "$SHARED_MOUNT" ]; then
    BNDL_WHY="Shared is not verified on this disk (${SHARED_STATE:-off}); name a folder instead: ./omarchy-bootstrap export DIR."
    return 1
  fi
  BNDL_SHARED=$SHARED_MOUNT
  BNDL_DEST=$(sys_path "$SHARED_MOUNT")
  if [ ! -d "$BNDL_DEST" ]; then
    BNDL_WHY="Shared is not mounted at $SHARED_MOUNT."
    return 1
  fi
}

# _bndl_mode SOURCE_MODE CLASS DIR — BNDL_MODE: what the entry is given on
# Linux: 0644, or 0755 with any execute bit; 0600 or 0700 for what is not
# config; a folder 0755, or 0700.
_bndl_mode() {
  local m=$1 x=0
  _whole "$m" '^[0-7]{1,6}$' && x=$((8#$m & 73))
  if [ "$3" = dir ]; then x=1; fi
  if [ "$2" = config ]; then
    if [ "$x" != 0 ]; then BNDL_MODE=0755; else BNDL_MODE=0644; fi
  else
    if [ "$x" != 0 ]; then BNDL_MODE=0700; else BNDL_MODE=0600; fi
  fi
}

# _bndl_skip ITEM REASON — a skip record for an item (written id).
_bndl_skip() {
  rec_line_v skip item "" reason "$2"
  printf '%s\n' "skip	item=$1	${REC_LINE#skip	item=	}" >>"$BNDL_W/r.skip"
}

# _bndl_item ID CLASS WHOLE — the item record of a carried item (written id).
_bndl_item() {
  rec_line_v item id "" class "$2" whole "$3"
  printf '%s\n' "item	id=$1	${REC_LINE#item	id=	}" >>"$BNDL_W/r.item"
}

# _bndl_rec FILE TYPE ITEM KEY VALUE... — a record of ITEM (written id),
# appended to FILE.
_bndl_rec() {
  local f=$1 t=$2 item=$3
  shift 3
  rec_line_v "$t" item "" "$@"
  printf '%s\n' "$t	item=$item	${REC_LINE#"$t	item=	"}" >>"$f"
}

# _bndl_field LINE KEY — BNDL_V: KEY's decoded value in LINE.
_bndl_field() {
  _rec_field_raw "$1" "$2"
  _rec_dec_into BNDL_V "$REC_RAW"
}

# _bndl_extract N ITEM CLASS — capture item ITEM (written id) with
# scan_extract into $BNDL_X/N and stage its records in $BNDL_W/i.*. 0 the
# item travels; 1 it is left behind, with BNDL_WHY; 2 it is gone.
_bndl_extract() {
  local n=$1 item=$2 class=$3 out=$BNDL_X/$1 line t src kind whole=0 id
  BNDL_WHY=""
  for t in dir file link setting macpath skip obj ent text; do : >"$BNDL_W/i.$t" || return 1; done
  mkdir -p "$out" || return 1
  _rec_dec_into id "$item"
  scan_extract "$id" "$out" || return 2
  [ -f "$out/carry" ] || return 2
  while IFS= read -r line; do
    t=${line%%	*}
    case "$t" in
      file)
        _bndl_field "$line" src
        src=$BNDL_V
        case "/$src/" in */../* | */./* | //*) BNDL_WHY="a capture outside its folder" && return 1 ;; esac
        src=$out/$src
        if [ ! -f "$src" ] || [ -L "$src" ]; then BNDL_WHY="a capture that is not a plain file" && return 1; fi
        _bndl_size "$src" || return 1
        _bndl_field "$line" dest
        if [ "$BNDL_SIZE" -gt "$BNDL_MAX_OBJECT" ]; then
          _bndl_rec "$BNDL_W/i.skip" skip "$item" reason "too-large: a file over 64 MiB is not carried"
          continue
        fi
        # The bytes scanned are the bytes carried: this capture is hashed,
        # scanned and later copied, and the copy is held to this digest.
        _bndl_sha "$src" || return 1
        SCAN_HIT=""
        if [ "$class" = secret ]; then
          # The one secret that travels, after its typed carry: an
          # encrypted OpenSSH key, its envelope checked again on these bytes.
          if ! declare -F scan_key_check >/dev/null || ! scan_key_check "$src"; then
            BNDL_WHY="the key's captured bytes are not an encrypted key of a supported kind"
            return 1
          fi
        elif ! scan_secret_check "$src"; then
          kind=${SCAN_HIT//[!a-z0-9-]/}
          BNDL_WHY="a credential shape (${kind:-unknown}) in what it carries"
          return 1
        fi
        _bndl_field "$line" mode
        _bndl_mode "$BNDL_V" "$class" file
        _bndl_field "$line" whole
        [ "$BNDL_V" = 1 ] || BNDL_V=0
        [ "$BNDL_V" = 0 ] || whole=1
        kind=$BNDL_V
        _bndl_field "$line" dest
        _bndl_rec "$BNDL_W/i.file" file "$item" dest "$BNDL_V" mode "$BNDL_MODE" sha256 "$BNDL_SHA" size "$BNDL_SIZE" whole "$kind"
        printf '%s\t%s\t%s\n' "$BNDL_SHA" "$BNDL_SIZE" "$src" >>"$BNDL_W/i.obj"
        _rec_field_raw "$line" dest
        printf '%s\tfile\t%s\t\n' "$item" "$REC_RAW" >>"$BNDL_W/i.ent"
        ;;
      dir)
        _bndl_field "$line" mode
        _bndl_mode "$BNDL_V" "$class" dir
        _bndl_field "$line" dest
        _bndl_rec "$BNDL_W/i.dir" dir "$item" dest "$BNDL_V" mode "$BNDL_MODE"
        _rec_field_raw "$line" dest
        printf '%s\tdir\t%s\t\n' "$item" "$REC_RAW" >>"$BNDL_W/i.ent"
        ;;
      link)
        _bndl_field "$line" dest
        src=$BNDL_V
        _bndl_field "$line" target
        _bndl_rec "$BNDL_W/i.link" link "$item" dest "$src" target "$BNDL_V"
        _rec_field_raw "$line" dest
        src=$REC_RAW
        _rec_field_raw "$line" target
        printf '%s\tlink\t%s\t%s\n' "$item" "$src" "$REC_RAW" >>"$BNDL_W/i.ent"
        ;;
      setting)
        _bndl_field "$line" value
        printf '%s' "$BNDL_V" >"$BNDL_W/setting.value" || return 1
        SCAN_HIT=""
        if ! scan_secret_check "$BNDL_W/setting.value"; then
          kind=${SCAN_HIT//[!a-z0-9-]/}
          BNDL_WHY="a credential shape (${kind:-unknown}) in a setting"
          return 1
        fi
        set --
        for kind in kind tool name value; do
          _bndl_field "$line" "$kind"
          set -- "$@" "$kind" "$BNDL_V"
        done
        _bndl_rec "$BNDL_W/i.setting" setting "$item" "$@"
        ;;
      macpath)
        _bndl_field "$line" dest
        src=$BNDL_V
        _bndl_field "$line" path
        _bndl_rec "$BNDL_W/i.macpath" macpath "$item" dest "$src" path "$BNDL_V"
        ;;
      skip)
        _bndl_field "$line" reason
        _rec_text_ok "$(rec_enc "$BNDL_V")" || BNDL_V="a part the scanner left behind"
        _bndl_rec "$BNDL_W/i.skip" skip "$item" reason "$BNDL_V"
        ;;
    esac
    _bndl_text "$line" || return 1
  done <"$out/carry"
  # Every value the item's records would write — destinations, link text,
  # macOS paths, setting names, reasons — is scanned too.
  SCAN_HIT=""
  if ! scan_secret_check "$BNDL_W/i.text"; then
    kind=${SCAN_HIT//[!a-z0-9-]/}
    BNDL_WHY="a credential shape (${kind:-unknown}) in what its records name"
    return 1
  fi
  BNDL_WHOLE=$whole
  return 0
}

# _bndl_text LINE — append LINE's decoded values, but a capture's place in
# the scratch folder, to $BNDL_W/i.text.
_bndl_text() {
  local f IFS='	'
  set -f
  # shellcheck disable=SC2086 # split on TAB on purpose; globbing is off
  set -- ${1#*	}
  set +f
  for f in "$@"; do
    case "$f" in src=*) continue ;; esac
    _rec_dec_into BNDL_V "${f#*=}"
    printf '%s\n' "$BNDL_V" >>"$BNDL_W/i.text" || return 1
  done
}

# _bndl_selected — BNDL_SELECTED: the bytes the profile records for its
# included items (after bndl_profile_load).
_bndl_selected() {
  BNDL_SELECTED=$(LC_ALL=C awk -F'\t' 'NR == FNR { if ($3 == "state=include") inc[$2] = 1; next }
    ($2 in inc) { for (i = 3; i <= NF; i++) if ($i ~ /^size=[0-9]+$/) { s = $i; sub(/^size=/, "", s); t += s } }
    END { printf "%.0f", t }' "$BNDL_W/p.select" "$BNDL_W/p.item")
  case "$BNDL_SELECTED" in '' | *[!0-9]*) BNDL_SELECTED=0 ;; esac
}

# _bndl_room BYTES — within 2 GiB.
_bndl_room() {
  [ "$1" -le "$BNDL_MAX_TOTAL" ] && return 0
  BNDL_WHY="The selected files come to $1 bytes, over the 2 GiB a bundle may hold; leave some out in ./omarchy-bootstrap profile."
  return 1
}

# bndl_prepare — everything before the first byte is written: the saved
# profile, a fresh scan reconciled with it, each selected item's carried
# form classified over its captured bytes, the destination rules, the body
# of bundle.omb ($BNDL_W/body) and the objects it names ($BNDL_W/objects:
# sha, size, capture). BNDL_ITEMS, BNDL_FILES, BNDL_BYTES, BNDL_GONE,
# BNDL_NEW, BNDL_LEFT (left behind). 1 with BNDL_WHY when export cannot go on.
bndl_prepare() {
  local line id class n=0 rs layer st t mac at host model user home
  bndl_profile_load || return 1
  BNDL_X=$(mktemp -d "$BNDL_W/x.XXXXXX") || { BNDL_WHY="no scratch folder"; return 1; }
  for t in item dir file link setting package macpath skip; do : >"$BNDL_W/r.$t" || return 1; done
  : >"$BNDL_W/objects.all" && : >"$BNDL_W/entries" && : >"$BNDL_W/scan" || return 1
  BNDL_GONE=0 BNDL_NEW=0 BNDL_LEFT=0
  # What the profile's selection would capture, before anything is.
  _bndl_selected
  _bndl_room "$BNDL_SELECTED" || return 1
  if ! scan_run "$BNDL_W/scan"; then
    BNDL_WHY="The fresh scan did not finish, so nothing can be reconciled with the profile."
    return 1
  fi
  # A new item waits for the next profile.
  while IFS= read -r line; do
    case "$line" in item"	"*) ;; *) continue ;; esac
    _rec_field_raw "$line" id
    grep -qF "item	id=$REC_RAW	" "$BNDL_W/p.item" || BNDL_NEW=$((BNDL_NEW + 1))
  done <"$BNDL_W/scan"
  while IFS= read -r line; do
    _rec_field_raw "$line" state
    [ "$REC_RAW" = include ] || continue
    _rec_field_raw "$line" id
    id=$REC_RAW
    n=$((n + 1))
    if ! grep -qF "item	id=$id	" "$BNDL_W/scan"; then
      _bndl_skip "$id" "gone: no longer on this Mac"
      BNDL_GONE=$((BNDL_GONE + 1))
      continue
    fi
    class=$(awk -F'\t' -v k="id=$id" '$2 == k { for (i = 3; i <= NF; i++) if ($i ~ /^class=/) { s = $i; sub(/^class=/, "", s); print s } exit }' "$BNDL_W/p.item")
    rs=$(awk -F'\t' -v k="id=$id" '$2 == k { print; exit }' "$BNDL_W/p.resolution")
    _rec_field_raw "$rs" state
    st=$REC_RAW
    _rec_field_raw "$rs" layer
    layer=$REC_RAW
    case "$class" in
      mac-only)
        _bndl_skip "$id" "mac-only: it only means something on this Mac"
        BNDL_LEFT=$((BNDL_LEFT + 1))
        continue
        ;;
      secret)
        if ! grep -qF "consent	word=carry	id=$id	" "$BNDL_W/p.consent"; then
          _bndl_skip "$id" "secret: never carried without its typed carry"
          BNDL_LEFT=$((BNDL_LEFT + 1))
          continue
        fi
        ;;
      opaque)
        if ! grep -q '^consent	word=opaque	' "$BNDL_W/p.consent"; then
          _bndl_skip "$id" "opaque: never carried without the typed opaque"
          BNDL_LEFT=$((BNDL_LEFT + 1))
          continue
        fi
        ;;
    esac
    if [ "$st" != resolved ]; then
      _bndl_skip "$id" "not installed on Linux: $st"
      continue
    fi
    case "$layer" in
      packages | runtimes | tools | ai)
        set --
        for t in layer method target version guess; do
          _bndl_field "$rs" "$t"
          set -- "$@" "$t" "$BNDL_V"
        done
        _bndl_rec "$BNDL_W/r.package" package "$id" "$@"
        _bndl_item "$id" "$class" 0
        continue
        ;;
    esac
    _bndl_extract "$n" "$id" "$class"
    case $? in
      0) ;;
      2)
        _bndl_skip "$id" "gone: no longer on this Mac"
        BNDL_GONE=$((BNDL_GONE + 1))
        continue
        ;;
      *)
        _bndl_skip "$id" "left behind: ${BNDL_WHY:-it could not be captured}"
        BNDL_LEFT=$((BNDL_LEFT + 1))
        continue
        ;;
    esac
    for t in dir file link setting macpath skip; do cat "$BNDL_W/i.$t" >>"$BNDL_W/r.$t" || return 1; done
    cat "$BNDL_W/i.obj" >>"$BNDL_W/objects.all" && cat "$BNDL_W/i.ent" >>"$BNDL_W/entries" || return 1
    _bndl_item "$id" "$class" "$BNDL_WHOLE"
  done <"$BNDL_W/p.select"
  # The destination rules, item by item against those before it: an item
  # that breaks one is left behind whole.
  LC_ALL=C awk -v mode=items "$BNDL_DEST_AWK" "$BNDL_W/entries" >"$BNDL_W/dest.bad" || { BNDL_WHY="The destinations could not be checked."; return 1; }
  if [ -s "$BNDL_W/dest.bad" ]; then
    while IFS='	' read -r id t; do
      _bndl_skip "$id" "left behind: $t"
      BNDL_LEFT=$((BNDL_LEFT + 1))
    done <"$BNDL_W/dest.bad"
    for t in item dir file link setting macpath; do
      LC_ALL=C awk -F'\t' 'NR == FNR { bad["item=" $1] = 1; bad["id=" $1] = 1; next } !($2 in bad)' \
        "$BNDL_W/dest.bad" "$BNDL_W/r.$t" >"$BNDL_W/r.$t.kept" && mv -f "$BNDL_W/r.$t.kept" "$BNDL_W/r.$t" || return 1
    done
  fi
  # The objects the kept files name, each once.
  LC_ALL=C awk -F'\t' 'NR == FNR { for (i = 3; i <= NF; i++) if ($i ~ /^sha256=/) { s = $i; sub(/^sha256=/, "", s); want[s] = 1 } next }
    ($1 in want) && !seen[$1]++' "$BNDL_W/r.file" "$BNDL_W/objects.all" >"$BNDL_W/objects" || return 1
  BNDL_BYTES=$(awk -F'\t' '{ s += $2 } END { printf "%.0f", s }' "$BNDL_W/objects") || return 1
  _bndl_room "$BNDL_BYTES" || return 1
  BNDL_ITEMS=$(wc -l <"$BNDL_W/r.item") && BNDL_ITEMS=${BNDL_ITEMS//[!0-9]/}
  BNDL_FILES=$(wc -l <"$BNDL_W/r.file") && BNDL_FILES=${BNDL_FILES//[!0-9]/}
  mac=$(cat "$BNDL_W/p.mac")
  for t in host model user home; do
    _bndl_field "$mac" "$t"
    case "$t" in host) host=$BNDL_V ;; model) model=$BNDL_V ;; user) user=$BNDL_V ;; home) home=$BNDL_V ;; esac
  done
  at=$(now_utc)
  {
    printf 'omb-bundle 1\n' &&
      rec_line bundle at "$at" host "$host" model "$model" user "$user" home "$home" items "$BNDL_ITEMS" files "$BNDL_FILES" bytes "$BNDL_BYTES" &&
      cat "$BNDL_W/r.item" "$BNDL_W/r.dir" "$BNDL_W/r.file" "$BNDL_W/r.link" "$BNDL_W/r.setting" \
        "$BNDL_W/r.package" "$BNDL_W/r.macpath" "$BNDL_W/r.skip"
  } >"$BNDL_W/body" || { BNDL_WHY="The bundle's records could not be built."; return 1; }
}

# _bndl_free BYTES — the destination has room for BYTES (df's available
# space, read through the system seam).
_bndl_free() {
  local avail
  avail=$(sys_cmd bndl_df df -Pk "$BNDL_DEST" | awk 'NR == 2 { print $4 }')
  case "$avail" in
    '' | *[!0-9]*)
      BNDL_WHY="The free space at $BNDL_DEST cannot be read."
      return 1
      ;;
  esac
  [ "$((avail * 1024))" -ge "$1" ] && return 0
  BNDL_WHY="$BNDL_DEST has $((avail * 1024)) bytes free; the bundle needs $1."
  return 1
}

# bndl_write — the bundle, from bndl_prepare's scratch: a new
# <utc>.partial-<random> folder, every object copied and held to its digest,
# bundle.omb sealed last, the whole bundle checked, then the folder renamed
# to <utc>. Never deletes, never replaces: a failure leaves the .partial-*
# folder (BNDL_PARTIAL). BNDL_FINAL on success.
bndl_write() {
  local root sha size src utc final st body
  BNDL_PARTIAL="" BNDL_FINAL="" BNDL_WHY=""
  if [ "$OMB_INTENT" != act ] || [ "$OMB_DRY_RUN" = 1 ]; then
    BNDL_WHY="Only export itself, not a preview, writes a bundle."
    return 1
  fi
  _bndl_size "$BNDL_W/body" || return 1
  body=$BNDL_SIZE
  _bndl_free "$((BNDL_BYTES + body + 80))" || return 1
  root=$BNDL_DEST
  for st in omarchy-mac-bootstrap bundles; do
    root=$root/$st
    if [ -L "$root" ] || { [ -e "$root" ] && [ ! -d "$root" ]; }; then
      BNDL_WHY="$root is not a folder of its own; nothing was written."
      return 1
    fi
    [ -d "$root" ] || mkdir "$root" || { BNDL_WHY="$root cannot be made."; return 1; }
  done
  utc=$(now_stamp)
  final=$root/$utc
  if [ -e "$final" ] || [ -L "$final" ]; then
    BNDL_WHY="A bundle named $utc is already there; run export again."
    return 1
  fi
  BNDL_PARTIAL=$(mktemp -d "$root/$utc.partial-XXXXXX") || { BNDL_PARTIAL=""; BNDL_WHY="$root cannot be written."; return 1; }
  if ! mkdir "$BNDL_PARTIAL/objects"; then
    BNDL_WHY="$BNDL_PARTIAL cannot be written."
    return 1
  fi
  while IFS='	' read -r sha size src; do
    if omb_fail_at bundle-object || ! cp "$src" "$BNDL_PARTIAL/objects/$sha.part" ||
      ! _bndl_sha "$BNDL_PARTIAL/objects/$sha.part" || [ "$BNDL_SHA" != "$sha" ] ||
      ! mv "$BNDL_PARTIAL/objects/$sha.part" "$BNDL_PARTIAL/objects/$sha"; then
      BNDL_WHY="An object could not be written whole."
      return 1
    fi
    omb_stop_at bundle-object
  done <"$BNDL_W/objects"
  if omb_fail_at bundle-manifest || ! cp "$BNDL_W/body" "$BNDL_PARTIAL/bundle.omb" || ! rec_seal_write "$BNDL_PARTIAL/bundle.omb"; then
    BNDL_WHY="bundle.omb could not be written."
    return 1
  fi
  omb_stop_at bundle-manifest
  if ! bndl_check "$BNDL_PARTIAL"; then
    BNDL_WHY="The bundle does not read back: $BNDL_WHY"
    return 1
  fi
  if [ -e "$final" ] || [ -L "$final" ] || omb_fail_at bundle-rename || ! mv "$BNDL_PARTIAL" "$final"; then
    BNDL_WHY="The finished bundle could not be renamed to $utc."
    return 1
  fi
  BNDL_FINAL=$final BNDL_PARTIAL=""
  state_set export_last "$final" || _bndl_say warn "The bundle is written, but where could not be recorded."
  log_event export "bundle $utc: $BNDL_ITEMS items, $BNDL_FILES files, $BNDL_BYTES bytes"
  return 0
}

# bndl_export DIR — prepare and write, reporting through _bndl_say.
bndl_export() {
  if ! _bndl_dest "${1:-}" || ! bndl_prepare; then
    _bndl_say fail "$BNDL_WHY"
    return 1
  fi
  _bndl_report
  if [ "$OMB_DRY_RUN" = 1 ]; then
    _bndl_say info "Dry run: nothing was written."
    return 0
  fi
  if ! bndl_write; then
    _bndl_say fail "$BNDL_WHY"
    [ -z "$BNDL_PARTIAL" ] || _bndl_say info "It left $BNDL_PARTIAL, which restore never lists; remove it by hand."
    return 1
  fi
  _bndl_say ok "Bundle written: $BNDL_FINAL"
}

# _bndl_report — what the bundle holds and what stays behind.
_bndl_report() {
  local line reason
  _bndl_say info "$BNDL_ITEMS items, $BNDL_FILES files, $BNDL_BYTES bytes, to $BNDL_DEST."
  [ "$BNDL_GONE" = 0 ] || _bndl_say warn "$BNDL_GONE selected items are no longer on this Mac and are left out."
  [ "$BNDL_NEW" = 0 ] || _bndl_say info "$BNDL_NEW new items wait for the next ./omarchy-bootstrap profile."
  while IFS= read -r line; do
    _bndl_field "$line" reason
    reason=$BNDL_V
    case "$reason" in
      "left behind: "* | "too-large: "* | "secret: "* | "opaque: "*)
        _bndl_field "$line" item
        _bndl_say warn "$BNDL_V: $reason"
        ;;
    esac
  done <"$BNDL_W/r.skip"
}

# bndl_cmd_export [DIR] — `export [DIR]` in the text interface.
bndl_cmd_export() {
  OMB_PHASE=macos
  ui_header "macos $G_DOT export"
  if ! _bndl_dest "${1:-}" || ! bndl_prepare; then
    ui_fail "$BNDL_WHY"
    return 1
  fi
  _bndl_report
  if [ "$OMB_DRY_RUN" = 1 ]; then
    ui_info "Dry run: nothing was written."
    return 0
  fi
  ui_yesno "Write the bundle to $BNDL_DEST?" n
  case $? in
    0) ;;
    *)
      ui_info "Nothing was written."
      return 0
      ;;
  esac
  if ! bndl_write; then
    ui_fail "$BNDL_WHY"
    [ -z "$BNDL_PARTIAL" ] || ui_note "It left $(tildify "$BNDL_PARTIAL"), which restore never lists; remove it by hand."
    return 1
  fi
  ui_ok "Bundle written: $(tildify "$BNDL_FINAL")"
}

# ---------------------------------------------------------------------------
# The row export.write and the export scope (docs/PROTOCOL.md → §5)
# ---------------------------------------------------------------------------

bndl_row() {
  case "$1" in
    export.write)
      CA_SCOPE=export CA_INTENT=act CA_TERMINAL=managed CA_CANCEL=0 CA_GATE="" CA_LIMIT=3
      CA_LABEL="Write a bundle"
      CA_EXPLAIN="Scans again, carries what the saved profile selects into a new bundle on verified Shared or in the folder named, and deletes nothing."
      CA_PLATFORM=macos CA_PHASE=macos CA_PARAMS="dir" CA_FN=bndl_w
      ;;
    *) return 1 ;;
  esac
}

bndl_w_offer() {
  CA_WHY=""
  bndl_profile_load >/dev/null 2>&1 && return 0
  CA_WHY=$BNDL_WHY
  return 1
}

bndl_w_facts() {
  rec_line fact scope export key gate.export.write.profile label "Profile" value "${BNDL_PROFILE_SHA:0:16}" state info
}

bndl_w_params() {
  rec_line param action export.write name dir type bytes kind "" required 0
}

# bndl_w_basis — CORE_BASIS over the action, the profile's digest and where
# the bundle would go (the folder named, or verified Shared's mount point).
bndl_w_basis() {
  local dir doc
  core_arg_into dir dir
  bndl_profile_load >/dev/null 2>&1 || return 1
  _bndl_dest "$dir" >/dev/null 2>&1 || return 1
  doc=$(rec_line basis action export.write proto "$REC_PROTO" profile "$BNDL_PROFILE_SHA" dir "$dir" dest "$BNDL_DEST")
  CORE_BASIS=$(sha256_str "omb-basis 1
$doc
")
}

bndl_w_run() {
  local dir
  core_arg_into dir dir
  BNDL_CORE=1
  bndl_export "$dir"
}

# bndl_w_judge STATUS|reconcile — completed when this run's bundle reads
# back whole; otherwise no-effect: export deletes nothing and leaves at most
# a .partial-* folder, which restore never lists.
bndl_w_judge() {
  CORE_JUDGE_TEXT=""
  if [ "$1" != reconcile ] && [ -n "${BNDL_FINAL:-}" ] && bndl_check "$BNDL_FINAL"; then
    CORE_FINDING=completed CORE_JUDGE_TEXT="Bundle written: $BNDL_FINAL"
    return 0
  fi
  CORE_FINDING=no-effect
  if [ -n "${BNDL_PARTIAL:-}" ]; then
    CORE_JUDGE_TEXT="No bundle was finished; $BNDL_PARTIAL is left, which restore never lists."
  else
    CORE_JUDGE_TEXT="No bundle was finished. ${BNDL_WHY:-}"
  fi
}

# bndl_core_op OP — scope export: its snapshot (facts export.profile,
# export.dest, export.size, export.last and the row), and the validation of
# export.write's folder; nothing else.
bndl_core_op() {
  case "$1" in
    snapshot) _bndl_snapshot ;;
    validate) _bndl_validate ;;
    *) core_result refused unavailable "The export scope has no details to page." ;;
  esac
}

_bndl_snapshot() {
  local body gen st state=fail value last size=0
  omb_tmp_init || { core_read_failure 1; return; }
  body=$OMB_TMP/export.snapshot
  if bndl_profile_load >/dev/null 2>&1; then
    state=ok value="saved"
    _bndl_selected
    size=$BNDL_SELECTED
  else
    value="$BNDL_STATE: $BNDL_WHY"
    [ "$BNDL_STATE" = not-saved ] && state=warn
  fi
  last=$(state_get export_last)
  {
    rec_line fact scope export key export.profile label "Profile" value "$value" state "$state" &&
      if _bndl_dest "" >/dev/null 2>&1; then
        rec_line fact scope export key export.dest label "Destination" value "verified Shared at $BNDL_SHARED" state ok
      else
        rec_line fact scope export key export.dest label "Destination" value "none: name a folder" state info
      fi &&
      rec_line fact scope export key export.size label "Selected" value "$size bytes" state info &&
      rec_line fact scope export key export.last label "Last bundle" value "${last:-none}" state info
  } >"$body" || { core_read_failure 1; return; }
  core_rows_snapshot export.write >/dev/null || { core_read_failure 1; return; }
  cat "$OMB_TMP/rows.facts" "$OMB_TMP/rows.blockers" "$OMB_TMP/rows.actions" "$OMB_TMP/rows.params" >>"$body" || { core_read_failure 1; return; }
  gen=$(sha256_str "$(cat "$body")")
  core_read_prefix || { core_read_failure 1; return; }
  core_read_stage snapshot "$gen" 0 "$body"
  st=$?
  if [ "$st" != 0 ]; then core_read_failure "$st"; return; fi
  core_read_publish
}

# _bndl_validate — `validate select action=export.write`: the folder as it
# will be used, and the review basis execute must send.
_bndl_validate() {
  local body=$OMB_TMP/export.validate dir status="done" code=ok text="" st
  omb_tmp_init || { core_read_failure 1; return; }
  if [ "$CORE_REQ_SELECT" != export.write ]; then
    core_result refused unavailable "Validation in the export scope answers export.write."
    return
  fi
  core_arg_into dir dir
  : >"$body" || { core_read_failure 1; return; }
  if ! bndl_profile_load >/dev/null 2>&1; then
    status=refused code=unavailable text=$BNDL_WHY
  elif ! _bndl_dest "$dir" >/dev/null 2>&1; then
    rec_line invalid name dir code no-destination text "$BNDL_WHY" >>"$body" || { core_read_failure 1; return; }
    status=refused code=invalid text=$BNDL_WHY
  else
    CA_FN=bndl_w CA_PARAMS=dir
    bndl_w_basis || { core_read_failure 1; return; }
    { rec_line normal name dir value "$dir" && rec_line review action export.write basis "$CORE_BASIS"; } >>"$body" || { core_read_failure 1; return; }
  fi
  core_read_prefix || { core_read_failure 1; return; }
  {
    cat "$OMB_TMP/journey.prefix" "$body" &&
      rec_line result status "$status" code "$code" text "$text" next ''
  } >"$OMB_TMP/export.response" || { core_read_failure 1; return; }
  core_read_admit validate "$OMB_TMP/export.response"
  st=$?
  if [ "$st" != 0 ]; then core_read_failure "$st"; return; fi
  core_read_publish
}
