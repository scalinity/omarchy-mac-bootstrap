# shellcheck shell=bash
# The scanner (docs/MIGRATION.md → *The scanner*, *Sensitivity*; D19, D23,
# D40, D41): what this Mac's environment holds, read as text and never run.
#
# Every read goes through the seams — sys_cmd, sys_path, sys_walk — and fixed
# read-only utilities (find, plutil, wc, od, awk, and the perl sys_walk
# runs). No inventoried tool runs (brew, npm, cargo, uv, go, mise, an AI
# tool), no shell file is sourced, no hook, MCP server or plugin starts, and
# nothing reaches the network. Uncertainty stays visible: an adapter is done,
# partial (a budget ran out), unknown (a shape outside what it reads),
# denied (macOS refused the read) or skipped (nothing there), and every item
# carries its evidence.
#
# scan_run OUT        the inventory, as profile records (adapter, then item)
# scan_extract ID DIR what one item carries, in its Linux form (export's seam)
# scan_cmd            `scan`: the inventory, printed; writes nothing
# scan_secret_check   the whole-file credential scan
#
# Needs lib/common.sh, lib/ui.sh, lib/records.sh and lib/toml.sh.

# Budgets: a walk lists at most SCAN_MAX entries before it is partial; a file
# over SCAN_FILE_MAX is not read (its content is unknown); a listing keeps
# SCAN_LIST_MAX names.
SCAN_MAX=20000
SCAN_LIST_MAX=5000
SCAN_FILE_MAX=67108864
SCAN_KEY_MAX=16384
SCAN_ADAPTERS="homebrew apps languages editors shell terminal git ai folders"
# Exports that may become Bash (docs/RESOLVER.md → *From Zsh to Bash*).
SCAN_EXPORTS="EDITOR VISUAL PAGER MANPAGER LESS BAT_THEME FZF_DEFAULT_OPTS FZF_DEFAULT_COMMAND FZF_CTRL_T_OPTS FZF_ALT_C_OPTS HISTSIZE HISTFILESIZE GIT_EDITOR RIPGREP_CONFIG_PATH CLICOLOR LSCOLORS"
# Aliases Omarchy defines: one of the person's of the same name is not carried.
SCAN_OMARCHY_ALIASES="ls cd a c cx cy lt lsa"

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

# _scan_h REL — where a home-relative path is read (the fixture's root in
# tests); the home itself when REL is empty.
_scan_h() { sys_path "$SCAN_HOME${1:+/$1}"; }

# _scan_list DIR MIN MAX TYPE OUT — the names under DIR (a path as read, from
# sys_path) between depths MIN and MAX, relative to DIR, in byte order,
# never following a link; TYPE is find's -type letter or "any". A name
# holding a control byte is left out. SCAN_LIST_ST: 0 complete, 3 partial
# (more than SCAN_LIST_MAX), 4 denied (something could not be read), 1 DIR
# is not a folder.
_scan_list() {
  local dir=$1 out=$5 n
  SCAN_LIST_ST=0
  : >"$out"
  if [ ! -d "$dir" ] || [ -L "$dir" ]; then SCAN_LIST_ST=1 && return 1; fi
  if [ "$4" = any ]; then
    find -P "$dir" -mindepth "$2" -maxdepth "$3" -print0 2>"$out.err"
  else
    find -P "$dir" -mindepth "$2" -maxdepth "$3" -type "$4" -print0 2>"$out.err"
  fi | LC_ALL=C tr '\n\000' '\001\n' | LC_ALL=C awk -v p="$dir/" -v ctl="$(printf '[\001-\037\177]')" \
    'index($0, p) == 1 { s = substr($0, length(p) + 1); if (s !~ ctl) print s }' | LC_ALL=C sort >"$out.all"
  [ -s "$out.err" ] && SCAN_LIST_ST=4
  n=$(wc -l <"$out.all")
  if [ "$((n + 0))" -gt "$SCAN_LIST_MAX" ]; then
    head -n "$SCAN_LIST_MAX" "$out.all" >"$out"
    SCAN_LIST_ST=3
  else
    cat "$out.all" >"$out"
  fi
  rm -f "$out.all" "$out.err"
  [ "$SCAN_LIST_ST" = 0 ]
}

# _scan_pl FILE KEYPATH — a property list's or JSON file's value, through
# plutil: printed raw (a dictionary's keys one to a line, an array's count);
# its status is plutil's.
_scan_pl() { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# _scan_pl_ok FILE — plutil reads FILE (a property list or JSON) whole.
_scan_pl_ok() { plutil -convert json -o /dev/null "$1" >/dev/null 2>&1; }

# _scan_pl_into VAR FILE KEYPATH — VAR: that value without plutil's final LF;
# 1 (VAR empty) when there is none.
_scan_pl_into() {
  local __v __st
  __v=$(plutil -extract "$3" raw -o - "$2" 2>/dev/null)
  __st=$?
  [ "$__st" = 0 ] || __v=""
  eval "$1=\$__v"
  return "$__st"
}

# _scan_size PATH — SCAN_SIZE: a regular file's size in bytes.
_scan_size() {
  SCAN_SIZE=$(wc -c <"$1" 2>/dev/null) || { SCAN_SIZE="" && return 1; }
  SCAN_SIZE=$((SCAN_SIZE + 0))
}

# _scan_tree MACHINE-PATH — SCAN_TREE_BYTES and SCAN_TREE_FILES over a folder,
# by sys_walk (no file is opened); SCAN_TREE_ST is sys_walk's status.
_scan_tree() {
  local f
  f=$SCAN_TMP/tree
  sys_walk "$1" "$SCAN_MAX" >"$f"
  SCAN_TREE_ST=$?
  # shellcheck disable=SC2046 # two numbers, split on purpose
  set -- $(LC_ALL=C awk -F '\t' '$1 == "f" { b += $2; n++ } END { printf "%d %d\n", b, n }' "$f")
  SCAN_TREE_BYTES=${1:-0} SCAN_TREE_FILES=${2:-0}
}

# _scan_text VALUE — SCAN_TX: VALUE as record text: kept when it is valid
# UTF-8 without control bytes, otherwise with every byte outside printable
# ASCII as "?".
_scan_text() {
  local LC_ALL=C
  case "$1" in
    *[![:print:]]*) ;;
    *) SCAN_TX=$1 && return 0 ;;
  esac
  rec_enc_v "$1"
  if _rec_text_ok "$REC_ENC"; then SCAN_TX=$1 && return 0; fi
  SCAN_TX=${1//[![:print:]]/?}
}

# _scan_url_ok URL — 0 when a URL carries no credential: no user information
# and no query parameter named like one (docs/MIGRATION.md → *Secret channels*).
_scan_url_ok() {
  local LC_ALL=C u=$1 q
  case "$u" in
    *://*@*) u=${u#*://} && case "${u%%/*}" in *@*) return 1 ;; esac ;;
  esac
  case "$u" in *\?*) ;; *) return 0 ;; esac
  q=$(printf '%s' "${u#*\?}" | tr '[:upper:]' '[:lower:]')
  case "&$q" in
    *'&token'* | *'&key'* | *'&secret'* | *'&sig'* | *'&auth'* | *'&password'* | *'&api_key'* | *'&apikey'* | *'&access_token'*) return 1 ;;
    *[_-]token=* | *[_-]key=* | *[_-]secret=*) return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Sensitivity: the hard refusals and the credential scan
# ---------------------------------------------------------------------------

# scan_refused REL — 0 when REL (home-relative) is never carried, whatever is
# selected (*Hard refusals*, and the credential files refused even inside an
# opaque folder); SCAN_HIT names the kind.
scan_refused() {
  local rel=$1 base=${1##*/}
  SCAN_HIT=""
  case "/$rel/" in
    /Library/) SCAN_HIT="the Library folder, which is never carried as a whole" ;;
    */.aws/*) SCAN_HIT="cloud credentials (~/.aws)" ;;
    */.docker/config.json/*) SCAN_HIT="container credentials" ;;
    */.kube/config/*) SCAN_HIT="cluster credentials" ;;
    */.gnupg/private-keys-v1.d/* | */.gnupg/secring.gpg/*) SCAN_HIT="a GnuPG private key" ;;
    */Library/Keychains/*) SCAN_HIT="the Keychain" ;;
  esac
  [ -n "$SCAN_HIT" ] && return 0
  case "$base" in
    id_*.pub) ;;
    id_*) SCAN_HIT="an SSH private key" ;;
    *.pem | *.key | *.p12 | *.pfx | *.jks | *.keystore) SCAN_HIT="a key or certificate file" ;;
    .env*) SCAN_HIT="an environment file (.env)" ;;
    credentials | credentials.json | .credentials.json | .git-credentials | .pypirc) SCAN_HIT="a credentials file" ;;
    hosts.yml | auth.json | mcp-auth.json) SCAN_HIT="a sign-in file" ;;
    .netrc | _netrc) SCAN_HIT="a .netrc file" ;;
    .npmrc)
      if [ -n "${SCAN_HOME:-}" ] && LC_ALL=C grep -q '_authToken' "$(_scan_h "$rel")" 2>/dev/null; then
        SCAN_HIT="an npm token (.npmrc)"
      fi
      ;;
  esac
  [ -n "$SCAN_HIT" ]
}

# _SCAN_SECRET_AWK — prints the kind of the first credential shape over the
# whole input, or nothing. Shapes are found with match() and their lengths
# checked after, so no awk needs interval expressions.
# shellcheck disable=SC2016 # awk source
_SCAN_SECRET_AWK='
function hit(k) { print k; found = 1; exit 0 }
# A shape is measured without the delimiter before it, so one at the start
# of a line, or alone on it, is held to the same length as one after a
# space or a quote: MIN is the length of the token alone.
function tok(re, min, k,   s, n) {
  s = line
  while (match(s, re)) {
    n = RLENGTH
    if (substr(s, RSTART, 1) ~ /[^A-Za-z0-9]/) n--
    if (n >= min) hit(k)
    s = substr(s, RSTART + RLENGTH)
  }
}
{
  line = $0
  if (line ~ /-----BEGIN[ A-Z0-9]*PRIVATE KEY( BLOCK)?-----/) hit("a private key")
  tok("(^|[^A-Za-z0-9])sk-ant-[A-Za-z0-9_-]+", 27, "an Anthropic API key")
  tok("(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]+", 23, "an API key (sk-)")
  tok("(^|[^A-Za-z0-9])gh[pousr]_[A-Za-z0-9]+", 39, "a GitHub token")
  tok("(^|[^A-Za-z0-9])github_pat_[A-Za-z0-9_]+", 32, "a GitHub token")
  tok("(^|[^A-Za-z0-9])xox[abposr]-[A-Za-z0-9-]+", 14, "a Slack token")
  tok("(^|[^A-Za-z0-9])AKIA[0-9A-Z]+", 20, "an AWS access key")
  tok("(^|[^A-Za-z0-9])AIza[0-9A-Za-z_-]+", 39, "a Google API key")
  tok("eyJ[A-Za-z0-9_-]+[.]eyJ[A-Za-z0-9_-]+[.][A-Za-z0-9_-]+", 40, "a JSON Web Token")
  low = tolower(line)
  while (match(low, /(pass(word|wd|phrase)?|token|secret|api[_-]?key|access[_-]?key|private[_-]?key|credential|auth)[a-z0-9_]*["\047]?[ \t]*[:=][ \t]*["\047]?[a-z0-9+\/=_.-]+/)) {
    v = substr(low, RSTART, RLENGTH)
    sub(/^[^:=]*[:=][ \t]*["\047]?/, "", v)
    if (length(v) >= 16 && v ~ /[0-9]/ && v ~ /[a-z]/) hit("a credential assignment")
    low = substr(low, RSTART + RLENGTH)
  }
}'

# scan_secret_check FILE — the credential scan over FILE's whole length: 0
# clean, 1 a hit (SCAN_HIT names the kind, never the value), 2 FILE cannot
# be read or is over SCAN_FILE_MAX (its content is unknown). A miss proves
# nothing (docs/MIGRATION.md → *Allowlist first*).
scan_secret_check() {
  SCAN_HIT=""
  [ -f "$1" ] && [ -r "$1" ] || return 2
  _scan_size "$1" || return 2
  [ "$SCAN_SIZE" -le "$SCAN_FILE_MAX" ] || return 2
  SCAN_HIT=$(LC_ALL=C tr '\000' '\n' <"$1" | LC_ALL=C tr '\015' '\n' | LC_ALL=C awk "$_SCAN_SECRET_AWK")
  [ -z "$SCAN_HIT" ]
}

# scan_value_ok VALUE — the same shapes over one value (an export, an
# argument, a header): 0 when none is found.
scan_value_ok() {
  SCAN_HIT=$(printf '%s\n' "$1" | LC_ALL=C awk "$_SCAN_SECRET_AWK")
  [ -z "$SCAN_HIT" ]
}

# scan_ssh_key FILE — an SSH private key's envelope, parsed and never
# decrypted (*The one secret exception*): SCAN_KEY is encrypted (a supported
# cipher and bcrypt with at least 16 rounds: the one key that may travel),
# plain, unsupported, pem or malformed; SCAN_KEY_CIPHER, SCAN_KEY_KDF and
# SCAN_KEY_ROUNDS as the envelope says. The key is read by awk alone and
# nothing of it is printed but those names and the number.
# shellcheck disable=SC2016 # awk source
_SCAN_KEY_AWK='
function u32(i) { return ((B[i] * 256 + B[i + 1]) * 256 + B[i + 2]) * 256 + B[i + 3] }
function sstr(i, n,   s, j) { s = ""; for (j = 0; j < n; j++) s = s sprintf("%c", B[i + j]); return s }
function bad(w) { print "malformed - - 0"; exit 0 }
BEGIN {
  A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for (i = 1; i <= 64; i++) V[substr(A, i, 1)] = i - 1
}
NR == 1 {
  if ($0 == "-----BEGIN OPENSSH PRIVATE KEY-----") { inkey = 1; next }
  if ($0 ~ /^-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----$/) { print "pem - - 0"; done = 1; exit 0 }
  bad()
}
inkey && $0 == "-----END OPENSSH PRIVATE KEY-----" { ended = 1; inkey = 0; next }
inkey { body = body $0; next }
ended && $0 != "" { bad() }
END {
  if (done) exit 0
  if (!ended) bad()
  n = 0; acc = 0; bits = 0
  m = length(body)
  for (i = 1; i <= m; i++) {
    c = substr(body, i, 1)
    if (c == "=") break
    if (!(c in V)) bad()
    acc = acc * 64 + V[c]; bits += 6
    if (bits >= 8) { bits -= 8; B[n++] = int(acc / (2 ^ bits)); acc = acc % (2 ^ bits) }
  }
  if (n < 32 || sstr(0, 14) != "openssh-key-v1" || B[14] != 0) bad()
  # Every length is read only where four bytes remain, and every string it
  # names must lie whole inside the envelope.
  p = 15
  if (p + 4 > n) bad(); l = u32(p); p += 4; if (l < 1 || l > 64 || p + l > n) bad(); cipher = sstr(p, l); p += l
  if (p + 4 > n) bad(); l = u32(p); p += 4; if (l < 1 || l > 64 || p + l > n) bad(); kdf = sstr(p, l); p += l
  if (p + 4 > n) bad(); ol = u32(p); p += 4; if (p + ol > n) bad(); opts = p; p += ol
  if (p + 4 > n || u32(p) != 1) bad()
  p += 4
  # One key: its public-key string, then the (encrypted) private section,
  # each present in full; a torn envelope is malformed.
  if (p + 4 > n) bad(); l = u32(p); p += 4; if (l < 1 || p + l > n) bad(); p += l
  if (p + 4 > n) bad(); l = u32(p); p += 4; if (l < 1 || p + l > n) bad(); p += l
  l = ol
  if (cipher !~ /^[a-z0-9@.-]+$/ || kdf !~ /^[a-z0-9@.-]+$/) bad()
  rounds = 0
  if (kdf == "bcrypt") {
    if (l < 8) bad()
    sl = u32(opts); if (sl > l - 8) bad()
    rounds = u32(opts + 4 + sl)
  }
  if (cipher == "none" && kdf == "none") { print "plain none none 0"; exit 0 }
  if ((cipher == "aes256-ctr" || cipher == "aes256-gcm@openssh.com" || cipher == "chacha20-poly1305@openssh.com") && kdf == "bcrypt" && rounds >= 16) {
    print "encrypted " cipher " " kdf " " rounds; exit 0
  }
  print "unsupported " cipher " " kdf " " rounds
}'
scan_ssh_key() {
  local r
  SCAN_KEY=malformed SCAN_KEY_CIPHER="" SCAN_KEY_KDF="" SCAN_KEY_ROUNDS=0
  [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || return 1
  _scan_size "$1" || return 1
  [ "$SCAN_SIZE" -le "$SCAN_KEY_MAX" ] || return 1
  r=$(LC_ALL=C tr -d '\015' <"$1" | LC_ALL=C awk "$_SCAN_KEY_AWK")
  # shellcheck disable=SC2086 # four words, split on purpose
  set -- $r
  case "${1:-}" in encrypted | plain | unsupported | pem | malformed) SCAN_KEY=$1 ;; *) return 1 ;; esac
  SCAN_KEY_CIPHER=${2:-} SCAN_KEY_KDF=${3:-}
  case "${4:-0}" in *[!0-9]*) SCAN_KEY_ROUNDS=0 ;; *) SCAN_KEY_ROUNDS=${4:-0} ;; esac
  [ "$SCAN_KEY" = encrypted ]
}

# scan_key_check FILE — 0 when FILE's bytes are an openssh-key-v1 private key
# encrypted with a supported cipher and bcrypt of at least 16 rounds: the
# one secret export carries, after typed carry; 1 otherwise.
scan_key_check() { scan_ssh_key "$1"; }

# _scan_is_key FILE — the file's first line is a private key's header.
_scan_is_key() {
  local first
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  IFS= read -r first <"$1" 2>/dev/null || return 1
  case "$first" in -----BEGIN*PRIVATE\ KEY-----*) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------
# The inventory
# ---------------------------------------------------------------------------

# _scan_identity — SCAN_USER, SCAN_HOME (the account's home as the directory
# service has it), SCAN_SHELL (its login shell, or empty), SCAN_TMP.
_scan_identity() {
  local line
  omb_tmp_init || return 1
  SCAN_TMP=$OMB_TMP/scan
  mkdir -p "$SCAN_TMP" || return 1
  SCAN_USER=$(sys_cmd id_un id -un)
  case "$SCAN_USER" in '' | *[!A-Za-z0-9._-]* | [.-]*) return 1 ;; esac
  SCAN_HOME="" SCAN_SHELL=""
  while IFS= read -r line; do
    case "$line" in
      'NFSHomeDirectory: '/*) SCAN_HOME=${line#NFSHomeDirectory: } ;;
      'UserShell: '/*) SCAN_SHELL=${line#UserShell: } ;;
    esac
  done <<EOF
$(sys_cmd dscl_user dscl . -read "/Users/$SCAN_USER" NFSHomeDirectory UserShell)
EOF
  case "$SCAN_HOME" in /*/* | /*) ;; *) SCAN_HOME="" ;; esac
  case "$SCAN_HOME" in '' | */../* | */.. | */./*) SCAN_HOME=/Users/$SCAN_USER ;; esac
  SCAN_HOME=${SCAN_HOME%/}
  SCAN_TARGET_HOME=${SCAN_TARGET_HOME:-/home/$SCAN_USER}
}

# _scan_item ID KIND CATEGORY NAME VERSION SOURCE REQUESTED EVIDENCE CLASS PATH
# SIZE NOTE — one item record (lib/records.sh → profile.item) into the run's
# item file, once per id: a second item with an id already seen is dropped.
_scan_item() {
  case "$SCAN_SEEN" in *"
$1
"*) return 0 ;; esac
  SCAN_SEEN="$SCAN_SEEN$1
"
  _scan_text "${12}"
  rec_line item id "$1" adapter "$SCAN_AD" kind "$2" category "$3" name "${4:-$1}" version "$5" source "$6" \
    requested "$7" evidence "$8" class "$9" path "${10}" size "${11}" note "$SCAN_TX" >>"$SCAN_ITEMS"
  SCAN_N=$((SCAN_N + 1))
}

# _scan_state STATE NOTE — the adapter's state moves only towards less
# certain: done < skipped < partial < unknown < denied.
_scan_state() {
  local rank_old rank_new
  _scan_rank "$SCAN_ST"
  rank_old=$SCAN_RANK
  _scan_rank "$1"
  rank_new=$SCAN_RANK
  if [ "$rank_new" -gt "$rank_old" ]; then
    SCAN_ST=$1
    SCAN_NOTE=${2:-}
  fi
}
_scan_rank() {
  case "$1" in done) SCAN_RANK=0 ;; skipped) SCAN_RANK=1 ;; partial) SCAN_RANK=2 ;; unknown) SCAN_RANK=3 ;; *) SCAN_RANK=4 ;; esac
}

# _scan_whole REL ID KIND CATEGORY NAME — an adapter's own file or folder,
# carried whole: its size and, for every file inside, the hard refusals and
# the credential scan; a hit makes a file the item's "secret", a folder
# keeps the files that pass and names those that do not.
_scan_whole() {
  local rel=$1 id=$2 kind=$3 cat=$4 name=$5 p class=config note="carried whole" ev=observed size=""
  p=$(_scan_h "$rel")
  if [ -L "$p" ]; then
    _scan_item "$id" "$kind" "$cat" "$name" "" "" yes unknown config "$rel" "" "a link: carried only as a chosen folder"
    return 0
  fi
  if [ -f "$p" ]; then
    _scan_size "$p" && size=$SCAN_SIZE
    if scan_refused "$rel"; then
      class=secret note="never carried: $SCAN_HIT"
    else
      scan_secret_check "$p"
      case $? in
        0) ;;
        1) class=secret note="never carried: $SCAN_HIT" ;;
        *) ev=unknown note="carried whole; its content could not be read" ;;
      esac
    fi
  elif [ -d "$p" ]; then
    _scan_folder_check "$SCAN_HOME/$rel" "$rel"
    size=$SCAN_TREE_BYTES ev=$SCAN_FOLDER_EV note=$SCAN_FOLDER_NOTE
  else
    return 1
  fi
  _scan_item "$id" "$kind" "$cat" "$name" "" "" yes "$ev" "$class" "$rel" "$size" "$note"
}

# _scan_folder_check MACHINE-PATH REL — every file under a folder carried
# whole, refused by path or by the credential scan: SCAN_FOLDER_NOTE says
# how many files and which were left out (by kind), SCAN_FOLDER_EV is
# unknown when the walk was partial or denied.
_scan_folder_check() {
  local root=$1 rel=$2 t s m path link n=0 out=0 first="" st
  _scan_tree "$root"
  st=$SCAN_TREE_ST
  SCAN_FOLDER_EV=observed
  while IFS='	' read -r t s m path link; do
    [ "$t" = f ] || continue
    n=$((n + 1))
    path=$(rec_dec "$path")
    if scan_refused "$rel/$path" || ! scan_secret_check "$(sys_path "$root/$path")"; then
      [ -n "$SCAN_HIT" ] || continue
      out=$((out + 1))
      [ -n "$first" ] || first="$path ($SCAN_HIT)"
    fi
  done <"$SCAN_TMP/tree"
  SCAN_FOLDER_NOTE="carried whole: $n files"
  [ "$out" = 0 ] || SCAN_FOLDER_NOTE="$SCAN_FOLDER_NOTE; $out never carried, first $first"
  case "$st" in
    0) ;;
    3) SCAN_FOLDER_EV=unknown SCAN_FOLDER_NOTE="$SCAN_FOLDER_NOTE; partial: more than $SCAN_MAX entries" ;;
    *) SCAN_FOLDER_EV=unknown SCAN_FOLDER_NOTE="$SCAN_FOLDER_NOTE; some entries could not be read (denied)" ;;
  esac
}

# _scan_secret_item REL ID KIND CATEGORY NAME WHY — a file that is never
# carried, listed so the person sees it: named, never read.
_scan_secret_item() {
  local p
  p=$(_scan_h "$1")
  [ -e "$p" ] || [ -L "$p" ] || return 1
  _scan_item "$2" "$3" "$4" "$5" "" "" yes observed secret "$1" "" "never carried: $6"
}

# _scan_session_item ID NAME REL... — sessions, memory and history: listed
# when any is present, never carried (D41).
_scan_session_item() {
  local id=$1 name=$2 r
  shift 2
  for r in "$@"; do
    if [ -e "$(_scan_h "$r")" ]; then
      _scan_item "$id" session ai "$name" "" "" no observed mac-only "" "" "sessions, memory and history: not carried in v1"
      return 0
    fi
  done
}

# ---- Homebrew --------------------------------------------------------------

_scan_ad_homebrew() {
  local prefix root idp src found=0
  SCAN_CASK_APPS=""
  for prefix in /opt/homebrew /usr/local; do
    root=$(sys_path "$prefix")
    [ -d "$root/Cellar" ] || [ -d "$root/Caskroom" ] || continue
    found=1
    idp=brew src=homebrew
    [ "$prefix" = /usr/local ] && idp=brew-usr-local src="homebrew (/usr/local)"
    _scan_brew_formulae "$root" "$idp" "$src"
    _scan_brew_casks "$root" "$prefix"
    _scan_brew_taps "$root"
  done
  [ "$found" = 1 ] || _scan_state skipped "Homebrew is not installed"
}

_scan_brew_formulae() {
  local root=$1 idp=$2 src=$3 name ver vers link r ior tap ev req note svc
  _scan_list "$root/Cellar" 1 1 d "$SCAN_TMP/formulae"
  case "$SCAN_LIST_ST" in 3) _scan_state partial "more than $SCAN_LIST_MAX formulae" ;; 4) _scan_state denied "the Cellar could not be read" ;; esac
  while IFS= read -r name; do
    _scan_list "$root/Cellar/$name" 1 1 d "$SCAN_TMP/versions"
    vers=$(tr '\n' ' ' <"$SCAN_TMP/versions")
    vers=${vers% }
    ver="" ev=observed note=""
    link=$(readlink "$root/opt/$name" 2>/dev/null)
    case "$link" in */Cellar/"$name"/*) ver=${link##*/} ;; esac
    case " $vers " in *" $ver "*) ;; *) ver="" ;; esac
    if [ -z "$ver" ]; then
      case "$vers" in
        '') ev=unknown note="no installed version" ;;
        *' '*) ver=${vers##* } ev=unknown note="several versions ($vers), none linked" ;;
        *) ver=$vers ;;
      esac
    fi
    req=unknown tap=""
    r="$root/Cellar/$name/$ver/INSTALL_RECEIPT.json"
    if [ -n "$ver" ] && [ -f "$r" ]; then
      if _scan_pl_into ior "$r" installed_on_request; then
        case "$ior" in true) req=yes ;; false) req=no ;; *) ev=unknown note="a receipt this adapter does not read" ;; esac
      elif ! plutil -type runtime_dependencies "$r" >/dev/null 2>&1 && ! plutil -lint "$r" >/dev/null 2>&1; then
        ev=unknown note="a receipt this adapter does not read"
      fi
      _scan_pl_into tap "$r" source.tap
      case "$tap" in
        '' | homebrew/core | homebrew/cask) ;;
        */*)
          if [ ! -d "$root/Library/Taps/${tap%%/*}/homebrew-${tap#*/}" ]; then
            ev=unknown note="its receipt names a tap that is missing ($tap)"
          fi
          ;;
        *) ev=unknown note="a receipt this adapter does not read" ;;
      esac
    elif [ -n "$ver" ]; then
      note=${note:-"no receipt: whether it was requested is unknown"}
    fi
    svc=$(_scan_h "Library/LaunchAgents/homebrew.mxcl.$name.plist")
    if [ -f "$svc" ]; then note="${note:+$note; }a service is configured; whether it runs is unknown"; fi
    _scan_item "$idp:$name" brew-formula software "$name" "$ver" "${tap:-$src}" "$req" "$ev" config "" "" "$note"
  done <"$SCAN_TMP/formulae"
}

_scan_brew_casks() {
  local root=$1 token vers ver r i n app req ior ev note apps
  _scan_list "$root/Caskroom" 1 1 d "$SCAN_TMP/casks"
  case "$SCAN_LIST_ST" in 3) _scan_state partial "more than $SCAN_LIST_MAX casks" ;; 4) _scan_state denied "the Caskroom could not be read" ;; esac
  while IFS= read -r token; do
    _scan_list "$root/Caskroom/$token" 1 1 d "$SCAN_TMP/versions"
    vers=$(grep -v '^\.' "$SCAN_TMP/versions" | tr '\n' ' ')
    vers=${vers% }
    ver=${vers##* } ev=observed note="" req=unknown apps=""
    r="$root/Caskroom/$token/.metadata/INSTALL_RECEIPT.json"
    if [ -f "$r" ]; then
      if _scan_pl_into ior "$r" installed_on_request; then
        case "$ior" in true) req=yes ;; false) req=no ;; esac
      fi
      n=$(_scan_pl "$r" uninstall_artifacts)
      case "$n" in '' | *[!0-9]*) n=0 ;; esac
      i=0
      while [ "$i" -lt "$n" ] && [ "$i" -lt 64 ]; do
        if _scan_pl_into app "$r" "uninstall_artifacts.$i.app.0"; then apps="$apps$app
"; fi
        i=$((i + 1))
      done
    else
      ev=unknown note="no receipt: the app it installed and whether it was requested are unknown"
    fi
    while IFS= read -r app; do
      [ -n "$app" ] || continue
      case "$app" in */*) continue ;; esac
      if [ -d "$(sys_path "/Applications/$app")" ] || [ -d "$(_scan_h "Applications/$app")" ]; then
        SCAN_CASK_APPS="$SCAN_CASK_APPS$app
"
        note="${note:+$note; }installs $app"
      else
        ev=unknown note="${note:+$note; }the app it installed ($app) is gone"
      fi
    done <<EOF
$apps
EOF
    _scan_item "cask:$token" brew-cask apps "$token" "$ver" homebrew "$req" "$ev" config "" "" "$note"
  done <"$SCAN_TMP/casks"
}

_scan_brew_taps() {
  local root=$1 tap url note
  _scan_list "$root/Library/Taps" 2 2 d "$SCAN_TMP/taps"
  while IFS= read -r tap; do
    case "$tap" in */homebrew-*) ;; *) continue ;; esac
    url=$(LC_ALL=C awk '/^\[remote "origin"\]/ { o = 1; next } /^\[/ { o = 0 } o && $1 == "url" { sub(/^[^=]*=[ \t]*/, ""); print; exit }' \
      "$root/Library/Taps/$tap/.git/config" 2>/dev/null)
    note=""
    if [ -n "$url" ]; then
      if _scan_url_ok "$url"; then note="remote $url"; else note="its remote holds a credential: not shown"; fi
    fi
    _scan_item "tap:${tap%%/*}/${tap#*/homebrew-}" tap software "${tap%%/*}/${tap#*/homebrew-}" "" homebrew yes observed config "" "" "$note"
  done <"$SCAN_TMP/taps"
}

# ---- Applications ----------------------------------------------------------

_scan_ad_apps() {
  local dir app p bid ver src class ev
  for dir in /Applications "$SCAN_HOME/Applications"; do
    p=$(sys_path "$dir")
    _scan_list "$p" 1 1 d "$SCAN_TMP/apps" || {
      [ "$SCAN_LIST_ST" = 4 ] && _scan_state denied "$dir could not be read"
      [ "$SCAN_LIST_ST" = 3 ] && _scan_state partial "more than $SCAN_LIST_MAX applications"
    }
    while IFS= read -r app; do
      case "$app" in *.app) ;; *) continue ;; esac
      case "$SCAN_CASK_APPS" in *"
$app
"* | "$app
"*) continue ;; esac
      bid="" ver="" ev=observed class=config src=manual
      if ! _scan_pl_into bid "$p/$app/Contents/Info.plist" CFBundleIdentifier; then ev=unknown; fi
      _scan_pl_into ver "$p/$app/Contents/Info.plist" CFBundleShortVersionString || _scan_pl_into ver "$p/$app/Contents/Info.plist" CFBundleVersion
      [ -e "$p/$app/Contents/_MASReceipt/receipt" ] && src="App Store"
      case "$bid" in com.apple.*) class=mac-only ;; esac
      case "$bid" in
        '' | *[!A-Za-z0-9._-]*) _scan_item "app:path:${app%.app}" app apps "${app%.app}" "$ver" "$src" yes unknown "$class" "" "" "its bundle identifier could not be read" ;;
        *) _scan_item "app:$bid" app apps "$bid" "$ver" "$src" yes "$ev" "$class" "" "" "" ;;
      esac
    done <"$SCAN_TMP/apps"
  done
}

# ---- Language tools and runtimes -------------------------------------------

# _scan_line VERSION — SCAN_LINE: a version's release line (the version
# without its last component when it has three or more), so a patch update
# keeps a runtime's item id.
_scan_line() {
  local v=${1#v}
  case "$v" in *.*.*) SCAN_LINE=${v%.*} ;; *) SCAN_LINE=$v ;; esac
}

# _scan_node_modules DIR IDP SOURCE — the global packages under a
# node_modules folder (DIR as read): one item each, by package.json.
_scan_node_modules() {
  local dir=$1 idp=$2 src=$3 name sub ver
  [ -d "$dir" ] || return 0
  _scan_list "$dir" 1 1 any "$SCAN_TMP/nm"
  [ "$SCAN_LIST_ST" = 3 ] && _scan_state partial "more than $SCAN_LIST_MAX global packages"
  while IFS= read -r name; do
    case "$name" in
      .* | npm | corepack) continue ;;
      @*)
        _scan_list "$dir/$name" 1 1 any "$SCAN_TMP/nm2"
        while IFS= read -r sub; do
          ver=""
          _scan_pl_into ver "$dir/$name/$sub/package.json" version
          _scan_item "$idp:$name/$sub" "$idp" software "$name/$sub" "$ver" "$src" yes observed config "" "" ""
        done <"$SCAN_TMP/nm2"
        ;;
      *)
        ver=""
        _scan_pl_into ver "$dir/$name/package.json" version
        _scan_item "$idp:$name" "$idp" software "$name" "$ver" "$src" yes observed config "" "" ""
        ;;
    esac
  done <"$SCAN_TMP/nm"
}

# _scan_versions DIR IDP NAME SOURCE — one runtime item per installed
# version folder under DIR (as read).
_scan_versions() {
  local v
  _scan_list "$1" 1 1 d "$SCAN_TMP/rv" || return 0
  while IFS= read -r v; do
    _scan_line "$v"
    _scan_item "$2:$3@$SCAN_LINE" "$2" software "$3" "${v#v}" "$4" yes observed config "" "" ""
  done <"$SCAN_TMP/rv"
}

_scan_ad_languages() {
  local v d f name ver t line tool vers
  # Node: the global packages under every prefix, and the runtimes.
  for d in /opt/homebrew /usr/local; do
    _scan_node_modules "$(sys_path "$d/lib/node_modules")" npm "npm (Homebrew node)"
  done
  for d in .nvm/versions/node .local/share/fnm/node-versions .local/share/mise/installs/node; do
    _scan_list "$(_scan_h "$d")" 1 1 d "$SCAN_TMP/nodes" || continue
    while IFS= read -r v; do
      f=$(_scan_h "$d/$v/lib/node_modules")
      [ "$d" = .local/share/fnm/node-versions ] && f=$(_scan_h "$d/$v/installation/lib/node_modules")
      _scan_node_modules "$f" npm "npm (node ${v#v})"
    done <"$SCAN_TMP/nodes"
  done
  _scan_node_modules "$(_scan_h Library/pnpm/global/5/node_modules)" pnpm pnpm
  _scan_node_modules "$(_scan_h .bun/install/global/node_modules)" bun bun
  _scan_versions "$(_scan_h .nvm/versions/node)" nvm node nvm
  # Cargo's record of installed crates (cargo-binstall writes it too).
  f=$(_scan_h .cargo/.crates.toml)
  if [ -f "$f" ]; then
    if toml_read "$f" "$SCAN_TMP/crates"; then
      LC_ALL=C awk -F '\t' '$1 == "a" && $2 ~ /^v1\.[^.]+$/ { print substr($2, 4) }' "$SCAN_TMP/crates" >"$SCAN_TMP/crates.k"
      while IFS= read -r t; do
        t=$(rec_dec "$t")
        name=${t%% *} ver=${t#* }
        ver=${ver%% *}
        _scan_item "cargo:$name" cargo software "$name" "$ver" cargo yes observed config "" "" ""
      done <"$SCAN_TMP/crates.k"
    else
      _scan_item path:.cargo/.crates.toml refused software ".crates.toml" "" cargo unknown unknown config .cargo/.crates.toml "" \
        "refused by the TOML reader at line $TOML_AT: $TOML_WHY"
    fi
  fi
  # uv's tools, by their receipts.
  _scan_list "$(_scan_h .local/share/uv/tools)" 1 1 d "$SCAN_TMP/uv"
  while IFS= read -r name; do
    f=$(_scan_h ".local/share/uv/tools/$name/uv-receipt.toml")
    [ -f "$f" ] || continue
    if toml_read "$f" "$SCAN_TMP/uvr"; then
      _scan_item "uv:$name" uv software "$name" "" uv yes observed config "" "" ""
    else
      _scan_item "uv:$name" uv software "$name" "" uv yes unknown config "" "" "a receipt the TOML reader refused (line $TOML_AT: $TOML_WHY)"
    fi
  done <"$SCAN_TMP/uv"
  # pipx's venvs.
  _scan_list "$(_scan_h .local/pipx/venvs)" 1 1 d "$SCAN_TMP/pipx"
  while IFS= read -r name; do
    ver=""
    _scan_pl_into ver "$(_scan_h ".local/pipx/venvs/$name/pipx_metadata.json")" main_package.package_version
    _scan_item "pipx:$name" pipx software "$name" "$ver" pipx yes observed config "" "" ""
  done <"$SCAN_TMP/pipx"
  # Go binaries: the module and version Go embeds, found by a byte search.
  _scan_list "$(_scan_h go/bin)" 1 1 f "$SCAN_TMP/gobin"
  while IFS= read -r name; do
    f=$(_scan_h "go/bin/$name")
    _scan_size "$f" || continue
    [ "$SCAN_SIZE" -le "$SCAN_FILE_MAX" ] || continue
    line=$(LC_ALL=C tr '\000' '\n' <"$f" | LC_ALL=C awk '
      { i = index($0, "path\t"); if (i && path == "") { path = substr($0, i + 5); sub(/\t.*/, "", path) } }
      /^mod\t/ { split($0, a, "\t"); mod = a[2]; ver = a[3] }
      END { if (path != "") printf "%s\t%s\t%s\n", path, mod, ver }')
    if [ -n "$line" ]; then
      _scan_item "go:${line%%	*}" go software "${line%%	*}" "$(printf "%s" "$line" | cut -f3)" go yes observed config "" "" "the binary $name, module $(printf "%s" "$line" | cut -f2)"
    else
      _scan_item "go:path:$name" go software "$name" "" go yes unknown config "" "" "no Go build information found"
    fi
  done <"$SCAN_TMP/gobin"
  # mise's requested tools, through the TOML reader.
  f=$(_scan_h .config/mise/config.toml)
  if [ -f "$f" ]; then
    if toml_read "$f" "$SCAN_TMP/mise"; then
      LC_ALL=C awk -F '\t' '($1 == "s" || $1 == "i" || $1 == "f") && $2 ~ /^tools\./ {
        k = substr($2, 7); n = split(k, c, "."); if (n == 1 || (n == 2 && c[2] ~ /^[0-9]+$/)) print c[1] "\t" $3 }' \
        "$SCAN_TMP/mise" >"$SCAN_TMP/mise.t"
      while IFS='	' read -r tool ver; do
        tool=$(rec_dec "$tool") ver=$(rec_dec "$ver")
        _scan_line "$ver"
        _scan_item "mise:$tool@$SCAN_LINE" mise software "$tool" "$ver" mise yes observed config "" "" ""
      done <"$SCAN_TMP/mise.t"
    else
      _scan_item path:.config/mise/config.toml refused software "mise config.toml" "" mise unknown unknown config .config/mise/config.toml "" \
        "refused by the TOML reader at line $TOML_AT: $TOML_WHY; carries nothing"
    fi
  fi
  # ~/.tool-versions (asdf, and mise reads it too).
  f=$(_scan_h .tool-versions)
  if [ -f "$f" ]; then
    while read -r tool vers; do
      case "$tool" in '' | \#*) continue ;; esac
      case "$tool" in *[!A-Za-z0-9_.-]*) continue ;; esac
      for ver in $vers; do
        case "$ver" in \#*) break ;; esac
        _scan_line "$ver"
        _scan_item "asdf:$tool@$SCAN_LINE" asdf software "$tool" "$ver" asdf yes observed config "" "" ""
      done
    done <"$f"
  fi
}

# ---- Editors ----------------------------------------------------------------

_scan_ad_editors() {
  local ed user ext f n i id ver
  for ed in "vscode|Code|.vscode/extensions|VS Code" "vscodium|VSCodium|.vscode-oss/extensions|VSCodium" "cursor|Cursor|.cursor/extensions|Cursor"; do
    IFS='|' read -r id user ext n <<EOF
$ed
EOF
    user="Library/Application Support/$user/User"
    for f in settings.json keybindings.json; do
      [ -f "$(_scan_h "$user/$f")" ] && _scan_whole "$user/$f" "$id:${f%.json}" settings editors "$n ${f%.json}"
    done
    [ -d "$(_scan_h "$user/snippets")" ] && _scan_whole "$user/snippets" "$id:snippets" folder editors "$n snippets"
    f=$(_scan_h "$ext/extensions.json")
    [ -f "$f" ] || continue
    i=0
    while [ "$i" -lt "$SCAN_LIST_MAX" ] && _scan_pl_into ver "$f" "$i.identifier.id"; do
      ext=$ver ver=""
      _scan_pl_into ver "$f" "$i.version"
      _scan_item "$id:ext:$ext" extension editors "$ext" "$ver" "$n" yes observed config "" "" ""
      i=$((i + 1))
    done
  done
  [ -d "$(_scan_h .config/nvim)" ] && _scan_whole .config/nvim nvim:config folder editors "Neovim configuration"
  [ -f "$(_scan_h .vimrc)" ] && _scan_whole .vimrc path:.vimrc file editors ".vimrc"
  return 0
}

# ---- Shell -------------------------------------------------------------------

SCAN_ZSH_FILES=".zshenv .zprofile .zshrc .zlogin"
SCAN_RC_FILES=".zshenv .zprofile .zshrc .zlogin .bashrc .bash_profile .profile"

# _SCAN_ZSH_AWK — the lexical tracker of docs/RESOLVER.md → *From Zsh to
# Bash*, over each file given: it follows quotes, backslash continuations,
# here-documents, compound commands, braces, subshells, $(...), ${...},
# $((...)) and backquotes, and a line is top-level only if it starts and
# ends outside all of them. From the first line it cannot follow, the rest
# of that file is review-only. Prints, per top-level line of the two forms:
#   A<TAB>NAME<TAB>VALUE   alias NAME='VALUE' (or "VALUE")
#   E<TAB>NAME<TAB>VALUE   export NAME=VALUE (VALUE unquoted)
# and R<TAB>FILE<TAB>LINE for every other line that holds a command.
# shellcheck disable=SC2016 # awk source
_SCAN_ZSH_AWK='
function push(c) { if (SP == 0 && D == 0 && OPEN == 0) OPEN = FNR; ST[++SP] = c }
function pop(c) { if (SP == 0 || ST[SP] != c) { fail(); return } SP-- }
function fail() { if (BAD == 0 || FNR < BAD) BAD = FNR }
function clean() { return SP == 0 && D == 0 && HN == 0 && !CONT }
function flush(   i) {
  if (FILE == "") return
  if (!(SP == 0 && D == 0 && HN == 0 && !CONT && !INHD)) { if (OPEN > 0) { if (BAD == 0 || OPEN < BAD) BAD = OPEN } else fail() }
  for (i = 1; i <= NCAND; i++) {
    if (BAD > 0 && CL[i] >= BAD) { print "R\t" FILE "\t" CL[i]; continue }
    print CT[i]
  }
  NCAND = 0
}
function cand(t) { CT[++NCAND] = t; CL[NCAND] = FNR }
function kw(w) {
  if (w == "if" || w == "case" || w == "for" || w == "while" || w == "until" || w == "select" || w == "repeat") { if (D == 0 && SP == 0) OPEN = FNR; K[++D] = w; return }
  if (w == "fi") { if (D == 0 || K[D] != "if") fail(); else D--; return }
  if (w == "esac") { if (D == 0 || K[D] != "case") fail(); else D--; return }
  if (w == "done") { if (D == 0 || K[D] == "if" || K[D] == "case" || K[D] == "{") fail(); else D--; return }
  if (w == "{") { if (D == 0 && SP == 0) OPEN = FNR; K[++D] = "{"; return }
  if (w == "}") { if (D == 0 || K[D] != "{") fail(); else D--; return }
}
BEGIN { SQ = sprintf("%c", 39) }
FNR == 1 { flush(); FILE = FILENAME; SP = 0; D = 0; HN = 0; HI = 0; INHD = 0; CONT = 0; BAD = 0; OPEN = 0 }
{
  line = $0
  if (INHD) {
    t = line
    if (HS[HI]) sub(/^\t+/, "", t)
    if (t == HT[HI]) { HI++; if (HI > HN) { HN = 0; HI = 0; INHD = 0 } }
    next
  }
  top = clean()
  wascont = CONT
  CONT = 0
  n = split(line, C, "")
  cmdpos = 1
  word = ""
  for (i = 1; i <= n + 1; i++) {
    c = (i <= n) ? C[i] : "\n"
    s = (SP > 0) ? ST[SP] : ""
    if (s == "q") { if (c == SQ) SP--; continue }
    if (s == "Q") {
      if (c == "\\") { i++; continue }
      if (c == "\"") { SP--; continue }
      if (c == "$" && C[i + 1] == "(") { push("("); i++; continue }
      if (c == "$" && C[i + 1] == "{") { push("{"); i++; continue }
      if (c == "`") { push("`"); continue }
      continue
    }
    if (s == "`") {
      if (c == "\\") { i++; continue }
      if (c == "`") SP--
      continue
    }
    if (s == "{") {
      if (c == "}") { SP--; continue }
      if (c == SQ) { push("q"); continue }
      if (c == "\"") { push("Q"); continue }
      if (c == "$" && C[i + 1] == "{") { push("{"); i++ }
      continue
    }
    if (s == "a") {
      if (c == "(") AP[SP]++
      else if (c == ")") { if (AP[SP] > 0) AP[SP]--; else if (C[i + 1] == ")") { SP--; i++ } else fail() }
      continue
    }
    # Code: top level, $( ), ( ).
    if (c == "\\") {
      if (i == n) { CONT = 1; break }
      i++; word = word "x"; continue
    }
    if (c == " " || c == "\t" || c == "\n" || c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "<" || c == ">") {
      if (word != "") { if (cmdpos && SP == 0) kw(word); cmdpos = cmdpos && (word == "then" || word == "do" || word == "else" || word == "elif" || word == "if" || word == "while" || word == "until" || word == "!" || word == "{" || word == "time"); word = "" }
      if (c == "\n") break
      if (c == ";" || c == "&" || c == "|") { cmdpos = 1; continue }
      if (c == "(") {
        if (C[i + 1] == "(" && cmdpos) { push("a"); AP[SP] = 0; i++; continue }
        push("("); cmdpos = 1; continue
      }
      if (c == ")") {
        if (SP > 0 && ST[SP] == "(") { SP--; continue }
        if (D > 0 && K[D] == "case") { cmdpos = 1; continue }
        fail(); continue
      }
      if (c == "<" && C[i + 1] == "<" && C[i + 2] == "<") { i += 2; continue }
      if (c == "<" && C[i + 1] == "<") {
        j = i + 2; strip = 0
        if (C[j] == "-") { strip = 1; j++ }
        while (C[j] == " " || C[j] == "\t") j++
        t = ""
        q = ""
        while (j <= n && C[j] !~ /[ \t;&|<>()]/) { if (C[j] == SQ || C[j] == "\"") q = 1; else if (C[j] != "\\") t = t C[j]; j++ }
        if (t == "") { fail(); continue }
        HT[++HN] = t; HS[HN] = strip
        if (OPEN == 0 && SP == 0 && D == 0) OPEN = FNR
        i = j - 1
        continue
      }
      continue
    }
    if (c == "#" && word == "") break
    if (c == SQ) { push("q"); word = word "q"; continue }
    if (c == "\"") { push("Q"); word = word "Q"; continue }
    if (c == "`") { push("`"); word = word "b"; continue }
    if (c == "$" && C[i + 1] == "(" && C[i + 2] == "(") { push("a"); AP[SP] = 0; i += 2; word = word "$"; continue }
    if (c == "$" && C[i + 1] == "(") { push("("); i++; word = word "$"; continue }
    if (c == "$" && C[i + 1] == "{") { push("{"); i++; word = word "$"; continue }
    if (cmdpos && word == "" && c == "[" && C[i + 1] == "[") {
      j = index(substr(line, i + 2), "]]")
      if (j == 0) { fail(); break }
      i = i + j + 2; cmdpos = 0; continue
    }
    word = word c
  }
  if (HN > 0) { INHD = 1; HI = 1 }
  if (SP == 0 && D == 0 && HN == 0 && !CONT) OPEN = 0
  if (line ~ /^[ \t]*(#.*)?$/) next
  if (top && !wascont && clean() && !INHD) {
    if (match(line, /^[ \t]*alias[ \t]+[A-Za-z0-9_.][A-Za-z0-9_.-]*=/)) {
      rest = substr(line, RLENGTH + 1); nm = substr(line, 1, RLENGTH - 1); sub(/^[ \t]*alias[ \t]+/, "", nm)
      sub(/[ \t]+$/, "", rest)
      q1 = substr(rest, 1, 1); v = substr(rest, 2, length(rest) - 2)
      if (length(rest) >= 2 && (q1 == SQ || q1 == "\"") && substr(rest, length(rest)) == q1 && index(v, q1) == 0 && v ~ /^[ -~]*$/ && v !~ /[$`\\!]/) { cand("A\t" nm "\t" v); next }
    }
    if (match(line, /^[ \t]*export[ \t]+[A-Za-z_][A-Za-z0-9_]*=/)) {
      rest = substr(line, RLENGTH + 1); nm = substr(line, 1, RLENGTH - 1); sub(/^[ \t]*export[ \t]+/, "", nm)
      sub(/[ \t]+$/, "", rest)
      q1 = substr(rest, 1, 1)
      if (q1 == SQ || q1 == "\"") {
        v = substr(rest, 2, length(rest) - 2)
        if (length(rest) >= 2 && substr(rest, length(rest)) == q1 && index(v, q1) == 0 && v ~ /^[ -~]*$/ && v !~ /[$`\\!]/) { cand("E\t" nm "\t" v); next }
      } else if (rest ~ /^[A-Za-z0-9_.\/:@%+=,-]*$/) { cand("E\t" nm "\t" rest); next }
    }
  }
  cand("R\t" FILE "\t" FNR)
}
END { flush() }'

# _scan_zsh OUT — the Zsh files the home holds, through the tracker, then the
# rules for what becomes Bash: lines "A NAME VALUE" (aliases, macOS commands
# replaced by their analogues), "E NAME VALUE" (allowlisted exports, a home
# path through p:home as $HOME), "S NAME" (an alias Omarchy defines: left
# for review), and "R ..." for review. SCAN_ZSH_A, _E and _R count them.
_scan_zsh() {
  local out=$1 f files="" t n v
  for f in $SCAN_ZSH_FILES; do
    [ -f "$(_scan_h "$f")" ] && [ ! -L "$(_scan_h "$f")" ] && files="$files $f"
  done
  SCAN_ZSH_A=0 SCAN_ZSH_E=0 SCAN_ZSH_R=0
  : >"$out"
  [ -n "$files" ] || return 1
  (
    cd "$(_scan_h "")" || exit 1
    # shellcheck disable=SC2086 # file names from the fixed list above
    LC_ALL=C awk "$_SCAN_ZSH_AWK" $files
  ) >"$out.raw" || return 1
  while IFS='	' read -r t n v; do
    case "$t" in
      A)
        case " $SCAN_OMARCHY_ALIASES " in *" $n "*) printf 'S\t%s\n' "$n" && SCAN_ZSH_R=$((SCAN_ZSH_R + 1)) && continue ;; esac
        if ! scan_value_ok "$v"; then SCAN_ZSH_R=$((SCAN_ZSH_R + 1)) && continue; fi
        v=$(printf '%s\n' "$v" | LC_ALL=C awk '
          function rw(s, w, r,   o, re) {
            o = ""; re = "(^|[ |;&(])" w "([ |;&)]|$)"
            while (match(s, re)) {
              o = o substr(s, 1, RSTART - 1)
              m = substr(s, RSTART, RLENGTH)
              sub(w, r, m)
              o = o m; s = substr(s, RSTART + RLENGTH)
            }
            return o s
          }
          { s = $0; s = rw(s, "pbcopy", "wl-copy"); s = rw(s, "pbpaste", "wl-paste"); s = rw(s, "open", "xdg-open"); s = rw(s, "caffeinate", "systemd-inhibit"); print s }')
        printf 'A\t%s\t%s\n' "$n" "$v"
        SCAN_ZSH_A=$((SCAN_ZSH_A + 1))
        ;;
      E)
        case " $SCAN_EXPORTS " in *" $n "*) ;; *) SCAN_ZSH_R=$((SCAN_ZSH_R + 1)) && continue ;; esac
        if ! scan_value_ok "$v"; then SCAN_ZSH_R=$((SCAN_ZSH_R + 1)) && continue; fi
        case "$v" in "$SCAN_HOME"/*) v="\$HOME/${v#"$SCAN_HOME"/}" ;; /Users/*) SCAN_ZSH_R=$((SCAN_ZSH_R + 1)) && continue ;; esac
        printf 'E\t%s\t%s\n' "$n" "$v"
        SCAN_ZSH_E=$((SCAN_ZSH_E + 1))
        ;;
      *) SCAN_ZSH_R=$((SCAN_ZSH_R + 1)) ;;
    esac
  done <"$out.raw" >"$out"
  rm -f "$out.raw"
}

_scan_ad_shell() {
  local f any=0
  for f in $SCAN_RC_FILES; do
    [ -f "$(_scan_h "$f")" ] || continue
    any=1
    _scan_whole "$f" "path:$f" rc terminal "$f"
  done
  if [ "$any" = 0 ]; then
    _scan_state skipped "no shell files"
    return 0
  fi
  if _scan_zsh "$SCAN_TMP/zsh"; then
    _scan_item shell:bash generated terminal shell.bash "" zsh yes inferred config "" "" \
      "$SCAN_ZSH_A aliases and $SCAN_ZSH_E exports become Bash; $SCAN_ZSH_R lines are for review (functions, plugins and other exports are not carried)"
  fi
}

# ---- Terminal settings -------------------------------------------------------

_scan_ad_terminal() {
  local rel f
  for rel in .config/ghostty/config "Library/Application Support/com.mitchellh.ghostty/config"; do
    [ -f "$(_scan_h "$rel")" ] || continue
    _scan_whole "$rel" ghostty:config parsed terminal "Ghostty settings"
    break
  done
  f=$(_scan_h .config/starship.toml)
  if [ -f "$f" ]; then
    if toml_read "$f" "$SCAN_TMP/starship"; then
      _scan_whole .config/starship.toml starship:config parsed terminal "Starship settings"
    else
      _scan_item starship:config refused terminal "Starship settings" "" "" yes unknown config .config/starship.toml "" \
        "refused by the TOML reader at line $TOML_AT: $TOML_WHY; carries nothing"
    fi
  fi
  for rel in .config/kitty .config/wezterm .wezterm.lua .config/alacritty .tmux.conf .config/tmux .config/atuin .config/eza .config/bat .config/direnv; do
    [ -e "$(_scan_h "$rel")" ] && _scan_whole "$rel" "path:$rel" file terminal "${rel#.config/}"
  done
  [ -f "$(_scan_h Library/Preferences/com.googlecode.iterm2.plist)" ] &&
    _scan_item iterm2:settings settings terminal "iTerm2 settings" "" "" yes observed mac-only "" "" "iTerm2's settings mean something only on macOS"
  [ -e "$(_scan_h "Library/Application Support/zoxide/db.zo")" ] &&
    _scan_item zoxide:db history terminal "zoxide database" "" "" yes observed mac-only "" "" "every entry is a macOS path"
  return 0
}

# ---- Git, gh and SSH ---------------------------------------------------------

_scan_ad_git() {
  local rel f name note id
  for rel in .gitconfig .config/git/config; do
    [ -f "$(_scan_h "$rel")" ] || continue
    id=git:config
    [ "$rel" = .gitconfig ] || id=git:config-xdg
    note="settings carried through git config"
    LC_ALL=C grep -qi 'helper[[:space:]]*=[[:space:]]*osxkeychain' "$(_scan_h "$rel")" &&
      note="$note; credential.helper osxkeychain dropped (macOS only)"
    _scan_item "$id" git git-ssh "Git settings (~/$rel)" "" "" yes observed config "$rel" "" "$note"
  done
  [ -f "$(_scan_h .config/git/ignore)" ] && _scan_whole .config/git/ignore path:.config/git/ignore file git-ssh "Git's global ignore file"
  [ -f "$(_scan_h .gitignore_global)" ] && _scan_whole .gitignore_global path:.gitignore_global file git-ssh "Git's global ignore file"
  [ -f "$(_scan_h .config/gh/config.yml)" ] && _scan_whole .config/gh/config.yml path:.config/gh/config.yml file git-ssh "gh settings"
  _scan_secret_item .config/gh/hosts.yml gh:hosts signin secrets "gh sign-in (hosts.yml)" "a sign-in file, never read; sign in again with gh auth login"
  f=$(_scan_h .ssh)
  [ -d "$f" ] || return 0
  _scan_list "$f" 1 1 any "$SCAN_TMP/ssh"
  [ "$SCAN_LIST_ST" = 4 ] && _scan_state denied "the .ssh folder could not be read"
  while IFS= read -r name; do
    rel=.ssh/$name
    if [ -L "$f/$name" ] || [ -d "$f/$name" ]; then continue; fi
    [ -f "$f/$name" ] || continue
    case "$name" in
      config)
        _scan_size "$f/$name"
        _scan_item ssh:config parsed git-ssh "SSH configuration" "" "" yes observed config "$rel" "$SCAN_SIZE" "UseKeychain lines dropped (Linux's OpenSSH refuses them)"
        ;;
      known_hosts | known_hosts2) _scan_size "$f/$name" && _scan_item "path:$rel" file git-ssh "$name" "" "" yes observed sensitive "$rel" "$SCAN_SIZE" "travels only when you opt in" ;;
      authorized_keys) _scan_size "$f/$name" && _scan_item "path:$rel" file git-ssh "$name" "" "" yes observed sensitive "$rel" "$SCAN_SIZE" "who may sign in to this Mac: travels only when you opt in" ;;
      *.pub) _scan_whole "$rel" "path:$rel" file git-ssh "$name" ;;
      *)
        if _scan_is_key "$f/$name" || case "$name" in id_*) true ;; *) false ;; esac; then
          if scan_ssh_key "$f/$name"; then
            _scan_item "path:$rel" key-encrypted git-ssh "$name" "$SCAN_KEY_ROUNDS" "$SCAN_KEY_CIPHER" yes observed secret "$rel" "" \
              "an encrypted SSH key ($SCAN_KEY_CIPHER, $SCAN_KEY_KDF $SCAN_KEY_ROUNDS rounds): travels only after typed carry"
          else
            case "$SCAN_KEY" in
              plain) note="an SSH private key without a passphrase: never carried" ;;
              pem) note="an SSH private key in the older PEM format: never carried" ;;
              unsupported) note="an SSH private key encrypted with $SCAN_KEY_CIPHER, $SCAN_KEY_KDF $SCAN_KEY_ROUNDS rounds (not a supported policy): never carried" ;;
              *) note="an SSH private key whose envelope could not be read: never carried" ;;
            esac
            _scan_item "path:$rel" key git-ssh "$name" "" "" yes observed secret "$rel" "" "$note"
          fi
        else
          _scan_whole "$rel" "path:$rel" file git-ssh "$name"
        fi
        ;;
    esac
  done <"$SCAN_TMP/ssh"
}

# ---- AI tools (docs/AI-TOOLS.md) ---------------------------------------------

# _scan_children REL KIND CATEGORY IDP — each folder (or file) directly under
# REL as one item carried whole: a skill folder is one unit.
_scan_children() {
  local rel=$1 name
  _scan_list "$(_scan_h "$rel")" 1 1 any "$SCAN_TMP/children" || return 0
  while IFS= read -r name; do
    case "$name" in .*) continue ;; esac
    if [ -L "$(_scan_h "$rel/$name")" ]; then
      _scan_item "path:$rel/$name" link "$3" "$name" "" "" yes observed config "$rel/$name" "" "a link (such as Omarchy's own skill): left alone, never carried"
      continue
    fi
    _scan_whole "$rel/$name" "path:$rel/$name" "$2" "$3" "$name"
  done <"$SCAN_TMP/children"
}

_scan_ad_ai() {
  local f k n note name any=0 rel
  # Claude Code.
  if [ -d "$(_scan_h .claude)" ] || [ -f "$(_scan_h .claude.json)" ]; then
    any=1
    f=$(_scan_h .claude/settings.json)
    if [ -f "$f" ]; then
      if _scan_pl_ok "$f"; then
        note="allowlisted settings carried"
        n=$(_scan_pl "$f" env | grep -c .)
        [ "$n" = 0 ] || note="$note; $n env values never travel (their names are listed)"
        _scan_pl "$f" hooks >/dev/null && note="$note; hooks run code: not carried"
        _scan_pl "$f" statusLine >/dev/null && note="$note; the status line runs code: not carried"
        _scan_pl "$f" apiKeyHelper >/dev/null && note="$note; apiKeyHelper dropped (a credential helper)"
        _scan_size "$f"
        _scan_item claude:settings parsed ai "Claude Code settings" "" claude yes observed config .claude/settings.json "$SCAN_SIZE" "$note"
      else
        _scan_item claude:settings refused ai "Claude Code settings" "" claude yes unknown config .claude/settings.json "" "plutil cannot read it: carries nothing"
      fi
    fi
    [ -f "$(_scan_h .claude/CLAUDE.md)" ] && _scan_whole .claude/CLAUDE.md path:.claude/CLAUDE.md file ai "Claude Code instructions (CLAUDE.md)"
    [ -f "$(_scan_h .claude/keybindings.json)" ] && _scan_whole .claude/keybindings.json path:.claude/keybindings.json file ai "Claude Code keybindings"
    for rel in rules agents commands output-styles themes; do
      [ -d "$(_scan_h ".claude/$rel")" ] && _scan_whole ".claude/$rel" "path:.claude/$rel" folder ai "Claude Code $rel"
    done
    _scan_children .claude/skills skill ai
    _scan_list "$(_scan_h .claude/workflows)" 1 1 f "$SCAN_TMP/wf"
    while IFS= read -r name; do
      case "$name" in *.js) ;; *) continue ;; esac
      _scan_whole ".claude/workflows/$name" "path:.claude/workflows/$name" runs-code ai "workflow $name"
    done <"$SCAN_TMP/wf"
    f=$(_scan_h .claude/plugins/installed_plugins.json)
    if [ -f "$f" ]; then
      n=$(_scan_pl "$f" plugins | grep -c .)
      k=0
      if _scan_pl_keys "$(_scan_h .claude/plugins/known_marketplaces.json)" "$SCAN_TMP/mkeys"; then k=$(grep -c . "$SCAN_TMP/mkeys"); fi
      _scan_item claude:plugins plugin ai "Claude Code plugins" "" claude yes observed config "" "" \
        "$n plugins from $k marketplaces, reinstalled on Linux from their marketplaces (which fetch and run code)"
    fi
    f=$(_scan_h .claude.json)
    if [ -f "$f" ]; then
      _scan_pl "$f" mcpServers >"$SCAN_TMP/mcp" 2>/dev/null
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        case "$name" in
          *.* | *[!A-Za-z0-9_@:/-]*) _scan_item "claude:mcp:$name" mcp ai "$name" "" claude yes unknown config "" "" "a server name this adapter cannot address: not carried" && continue ;;
        esac
        note="re-created with claude mcp add-json"
        n=$(_scan_pl "$f" "mcpServers.$name.env" | grep -c .)
        [ "$n" = 0 ] || note="$note; needs-secret: $n env values become variable references"
        _scan_item "claude:mcp:$name" mcp ai "$name" "" claude yes observed config "" "" "$note"
      done <"$SCAN_TMP/mcp"
      _scan_pl "$f" projects >/dev/null && _scan_item claude:projects session ai "Claude Code per-project state" "" claude no observed mac-only "" "" \
        "per-project servers and state in ~/.claude.json: listed, not carried in v1"
    fi
    _scan_secret_item .claude/.credentials.json claude:signin signin secrets "Claude Code sign-in" "a sign-in file; sign in again on Linux"
    _scan_session_item claude:sessions "Claude Code sessions and history" .claude/projects .claude/history.jsonl .claude/todos
  fi
  # Codex.
  if [ -d "$(_scan_h .codex)" ]; then
    any=1
    f=$(_scan_h .codex/config.toml)
    if [ -f "$f" ]; then
      if toml_read "$f" "$SCAN_TMP/codex"; then
        n=$(LC_ALL=C awk -F '\t' '$1 == "t" && $2 ~ /^mcp_servers\.[^.]+$/' "$SCAN_TMP/codex" | grep -c .)
        rm -f "$SCAN_TMP/codex"
        _scan_size "$f"
        _scan_item codex:config parsed ai "Codex configuration" "" codex yes observed config .codex/config.toml "$SCAN_SIZE" \
          "allowlisted keys carried, $n MCP servers; env values never travel"
      else
        _scan_item codex:config refused ai "Codex configuration" "" codex yes unknown config .codex/config.toml "" \
          "refused by the TOML reader at line $TOML_AT: $TOML_WHY; carries nothing"
      fi
    fi
    for rel in AGENTS.md AGENTS.override.md; do
      [ -f "$(_scan_h ".codex/$rel")" ] && _scan_whole ".codex/$rel" "path:.codex/$rel" file ai "Codex $rel"
    done
    for rel in rules prompts agents; do
      [ -d "$(_scan_h ".codex/$rel")" ] && _scan_whole ".codex/$rel" "path:.codex/$rel" folder ai "Codex $rel"
    done
    [ -f "$(_scan_h .codex/hooks.json)" ] && _scan_whole .codex/hooks.json path:.codex/hooks.json runs-code ai "Codex hooks"
    _scan_children .codex/skills skill ai
    _scan_secret_item .codex/auth.json codex:signin signin secrets "Codex sign-in (auth.json)" "a sign-in file; sign in again on Linux"
    _scan_secret_item .codex/.credentials.json codex:credentials signin secrets "Codex credentials" "a sign-in file; sign in again on Linux"
    _scan_session_item codex:sessions "Codex sessions and history" .codex/sessions .codex/archived_sessions .codex/history.jsonl
  fi
  if [ -d "$(_scan_h .agents/skills)" ]; then
    any=1
    _scan_children .agents/skills skill ai
  fi
  [ -f "$(_scan_h .agents/plugins/marketplace.json)" ] && _scan_whole .agents/plugins/marketplace.json path:.agents/plugins/marketplace.json file ai "Codex plugin marketplace"
  # OpenCode.
  if [ -d "$(_scan_h .config/opencode)" ]; then
    any=1
    f=$(_scan_h .config/opencode/opencode.json)
    if [ -f "$f" ]; then
      if _scan_pl_ok "$f"; then
        _scan_size "$f"
        _scan_item opencode:config parsed ai "OpenCode configuration" "" opencode yes observed config .config/opencode/opencode.json "$SCAN_SIZE" \
          "mcp, agent, command, instructions and permission entries carried; provider credentials dropped; plugins run code: not carried"
      else
        _scan_item opencode:config refused ai "OpenCode configuration" "" opencode yes unknown config .config/opencode/opencode.json "" "plutil cannot read it: carries nothing"
      fi
    fi
    [ -f "$(_scan_h .config/opencode/opencode.jsonc)" ] &&
      _scan_item path:.config/opencode/opencode.jsonc refused ai "opencode.jsonc" "" opencode yes unknown config .config/opencode/opencode.jsonc "" "a file with comments plutil cannot read: carries nothing"
    [ -f "$(_scan_h .config/opencode/AGENTS.md)" ] && _scan_whole .config/opencode/AGENTS.md path:.config/opencode/AGENTS.md file ai "OpenCode AGENTS.md"
    for rel in agents commands themes; do
      [ -d "$(_scan_h ".config/opencode/$rel")" ] && _scan_whole ".config/opencode/$rel" "path:.config/opencode/$rel" folder ai "OpenCode $rel"
    done
    _scan_children .config/opencode/skills skill ai
    for rel in plugins tools package.json; do
      [ -e "$(_scan_h ".config/opencode/$rel")" ] && _scan_whole ".config/opencode/$rel" "path:.config/opencode/$rel" runs-code ai "OpenCode $rel"
    done
  fi
  _scan_secret_item .local/share/opencode/auth.json opencode:signin signin secrets "OpenCode sign-in (auth.json)" "a sign-in file; sign in again on Linux"
  _scan_secret_item .local/share/opencode/mcp-auth.json opencode:mcp-signin signin secrets "OpenCode MCP sign-ins" "a sign-in file; sign in again on Linux"
  _scan_session_item opencode:sessions "OpenCode sessions and history" .local/share/opencode/opencode.db .local/state/opencode/prompt-history.jsonl
  # Recognised, not migrated yet: by name only (Crush's files run code when it loads them).
  for rel in ".gemini|gemini-cli|Gemini CLI" ".copilot|copilot-cli|Copilot CLI" ".config/crush|crush|Crush" ".pi|pi|Pi"; do
    if [ -e "$(_scan_h "${rel%%|*}")" ]; then
      any=1
      name=${rel#*|}
      _scan_item "ai:${name%%|*}" recognised ai "${name#*|}" "" "" yes observed config "${rel%%|*}" "" "recognised, not migrated yet"
    fi
  done
  # The tools themselves, installed on Linux in the AI layer (docs/AI-TOOLS.md
  # → *Providers*): one item each whose configuration is here.
  if [ -d "$(_scan_h .claude)" ] || [ -f "$(_scan_h .claude.json)" ]; then
    _scan_item ai:claude-code ai ai claude-code "" claude yes inferred config "" "" "its configuration is here; installed on Linux with mise and signed in again"
  fi
  if [ -d "$(_scan_h .codex)" ]; then
    _scan_item ai:codex ai ai codex "" codex yes inferred config "" "" "its configuration is here; installed on Linux with mise and signed in again"
  fi
  if [ -d "$(_scan_h .config/opencode)" ]; then
    _scan_item ai:opencode ai ai opencode "" opencode yes inferred config "" "" "its configuration is here; installed on Linux with mise and signed in again"
  fi
  [ "$any" = 1 ] || _scan_state skipped "no AI tool found"
}

# ---- Chosen folders and projects ---------------------------------------------

# What other adapters own, what is never carried, and what macOS protects:
# none of these is offered as a chosen folder.
SCAN_OWNED=" .claude .claude.json .codex .agents .ssh .gitconfig .gitignore_global .tool-versions .zshrc .zprofile .zshenv .zlogin .bashrc .bash_profile .profile .tmux.conf .wezterm.lua .vimrc .config .local .cargo .nvm .pyenv .bun .volta .vscode .vscode-oss .cursor go Applications Library "
SCAN_NEVER=" .Trash .cache .npm .rustup .gradle .m2 .zsh_sessions .zsh_history .bash_history .bash_sessions .lesshst .viminfo .python_history .node_repl_history .DS_Store .CFUserTextEncoding .cups .zcompdump Movies Music Pictures Public "
SCAN_PROTECTED=" Desktop Documents Downloads "
SCAN_CONFIG_OWNED=" nvim ghostty kitty wezterm alacritty tmux starship.toml atuin eza bat direnv git gh opencode mise crush omarchy-mac-bootstrap "

# _scan_project REL — a Git checkout under the home as a project: its remote
# and branch, read from .git, never copied.
_scan_project() {
  local rel=$1 g url head note
  g=$(_scan_h "$rel/.git")
  [ -f "$g/config" ] && [ -f "$g/HEAD" ] || return 1
  url=$(LC_ALL=C awk '/^\[remote "origin"\]/ { o = 1; next } /^\[/ { o = 0 } o && $1 == "url" { sub(/^[^=]*=[ \t]*/, ""); print; exit }' "$g/config")
  head=$(head -n 1 "$g/HEAD")
  case "$head" in 'ref: refs/heads/'*) head=${head#ref: refs/heads/} ;; *) head="(detached)" ;; esac
  note="branch $head"
  if [ -z "$url" ]; then
    note="$note; no remote: nothing to clone from"
  elif _scan_url_ok "$url"; then
    note="$note; remote $url"
  else
    note="$note; its remote holds a credential: enter it again on Linux"
  fi
  _scan_item "project:$rel" project folders "$rel" "" git yes observed config "$rel" "" "$note; cloned again on Linux, never copied"
}

# _scan_chosen REL — one entry offered as a chosen folder: opaque (no adapter
# understands it), refused by path when it is a known credential file; a
# link at its root (a Stow farm) followed once.
_scan_chosen() {
  local rel=$1 p t note="" ev=observed size="" kind=folder
  p=$(_scan_h "$rel")
  if scan_refused "$rel"; then
    _scan_item "path:$rel" file secrets "$rel" "" "" yes observed secret "$rel" "" "never carried: $SCAN_HIT"
    return 0
  fi
  if [ -L "$p" ]; then
    t=$(readlink "$p")
    case "$t" in /*) t=$(sys_path "$t") ;; *) t=${p%/*}/$t ;; esac
    if [ -d "$t" ]; then
      note="a link to $(readlink "$p"), followed once; "
      p=$t
    elif [ -f "$t" ]; then
      kind=file note="a link to $(readlink "$p"), followed once; "
      p=$t
    else
      _scan_item "path:$rel" link folders "$rel" "" "" yes unknown opaque "$rel" "" "a link whose target is missing"
      return 0
    fi
  elif [ -f "$p" ]; then
    kind="file"
  elif [ ! -d "$p" ]; then
    _scan_item "path:$rel" special folders "$rel" "" "" yes observed mac-only "$rel" "" "not a file or folder: never carried"
    return 0
  fi
  if [ "$kind" = folder ]; then
    sys_walk "${p#"${OMB_FIXTURE:+$OMB_FIXTURE/root}"}" "$SCAN_MAX" >"$SCAN_TMP/tree"
    case $? in
      0) ;;
      3) ev=unknown note="${note}partial: more than $SCAN_MAX entries; " ;;
      4) ev=unknown note="${note}denied: some entries could not be read; " ;;
      *) ev=unknown note="${note}could not be listed; " ;;
    esac
    size=$(LC_ALL=C awk -F '\t' '$1 == "f" { b += $2 } END { printf "%d", b }' "$SCAN_TMP/tree")
  else
    _scan_size "$p" && size=$SCAN_SIZE
  fi
  _scan_item "path:$rel" "$kind" folders "$rel" "" "" yes "$ev" opaque "$rel" "$size" \
    "${note}opaque: its contents are not checked field by field"
}

_scan_ad_folders() {
  local name sub
  _scan_list "$(_scan_h "")" 1 1 any "$SCAN_TMP/home"
  case "$SCAN_LIST_ST" in 4) _scan_state denied "the home folder could not be listed" ;; 3) _scan_state partial "more than $SCAN_LIST_MAX entries in the home folder" ;; esac
  while IFS= read -r name; do
    case "$SCAN_OWNED$SCAN_NEVER" in *" $name "*) continue ;; esac
    case "$SCAN_PROTECTED" in
      *" $name "*)
        _scan_item "path:$name" protected folders "$name" "" "" yes unknown opaque "$name" "" "protected by macOS: read only when chosen"
        continue
        ;;
    esac
    if _scan_project "$name"; then continue; fi
    if [ -d "$(_scan_h "$name")" ] && [ ! -L "$(_scan_h "$name")" ]; then
      case "$name" in
        .*) ;;
        *)
          # A folder of checkouts: each is a project.
          _scan_list "$(_scan_h "$name")" 1 1 d "$SCAN_TMP/sub"
          while IFS= read -r sub; do _scan_project "$name/$sub"; done <"$SCAN_TMP/sub"
          ;;
      esac
    fi
    _scan_chosen "$name"
  done <"$SCAN_TMP/home"
  _scan_list "$(_scan_h .config)" 1 1 any "$SCAN_TMP/config"
  while IFS= read -r name; do
    case "$SCAN_CONFIG_OWNED" in *" $name "*) continue ;; esac
    _scan_chosen ".config/$name"
  done <"$SCAN_TMP/config"
}

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

# scan_run OUT — the inventory into OUT: one adapter record per adapter (in
# SCAN_ADAPTERS' order), then every item record, in the order found. Calls
# SCAN_PROGRESS (a function name, when set) with "start N TOTAL ADAPTER"
# before an adapter and "done ADAPTER STATE COUNT NOTE" after it. 0 when the
# inventory is written (adapters partial, unknown or denied included), 2
# when the run was cancelled (CORE_CANCEL), 1 when it cannot be written or
# this Mac's account cannot be read.
scan_run() {
  local out=$1 ad i=0 total=0 adapters
  _scan_identity || return 1
  SCAN_ITEMS=$SCAN_TMP/items adapters=$SCAN_TMP/adapters
  : >"$SCAN_ITEMS" && : >"$adapters" || return 1
  SCAN_SEEN="
"
  for ad in $SCAN_ADAPTERS; do total=$((total + 1)); done
  for ad in $SCAN_ADAPTERS; do
    [ "${CORE_CANCEL:-0}" = 1 ] && return 2
    i=$((i + 1))
    [ -z "${SCAN_PROGRESS:-}" ] || "$SCAN_PROGRESS" start "$i" "$total" "$ad"
    SCAN_AD=$ad SCAN_ST='done' SCAN_NOTE="" SCAN_N=0
    "_scan_ad_$ad"
    _scan_text "$SCAN_NOTE"
    rec_line adapter id "$ad" state "$SCAN_ST" items "$SCAN_N" note "$SCAN_TX" >>"$adapters" || return 1
    [ -z "${SCAN_PROGRESS:-}" ] || "$SCAN_PROGRESS" 'done' "$ad" "$SCAN_ST" "$SCAN_N" "$SCAN_TX"
  done
  cat "$adapters" "$SCAN_ITEMS" >"$out"
}

# ---------------------------------------------------------------------------
# What an item carries (export's seam)
# ---------------------------------------------------------------------------

# _scan_dest REL — SCAN_DEST: where a home-relative source path lands on
# Linux: VS Code's, VSCodium's and Cursor's user folders under ~/.config,
# Ghostty's macOS location as its Linux one, the shell's rc files as
# reference copies nothing sources; anything else at the same path.
_scan_dest() {
  case "$1" in
    "Library/Application Support/Code/User/"*) SCAN_DEST=".config/Code/User/${1#Library/Application Support/Code/User/}" ;;
    "Library/Application Support/VSCodium/User/"*) SCAN_DEST=".config/VSCodium/User/${1#Library/Application Support/VSCodium/User/}" ;;
    "Library/Application Support/Cursor/User/"*) SCAN_DEST=".config/Cursor/User/${1#Library/Application Support/Cursor/User/}" ;;
    "Library/Application Support/com.mitchellh.ghostty/config") SCAN_DEST=.config/ghostty/config ;;
    .zshenv | .zprofile | .zshrc | .zlogin | .bashrc | .bash_profile | .profile) SCAN_DEST=".config/omarchy-mac-bootstrap/zsh/$1" ;;
    *) SCAN_DEST=$1 ;;
  esac
}

# _scan_x_put SRC — capture SRC's bytes once into the next object under the
# output folder: SCAN_OBJ is its path relative to that folder.
_scan_x_put() {
  SCAN_XN=$((SCAN_XN + 1))
  SCAN_OBJ=f/$SCAN_XN
  cp "$1" "$SCAN_XO/$SCAN_OBJ" 2>/dev/null
}

_scan_x() { rec_line "$@" >>"$SCAN_XO/carry"; }

# _scan_x_macpaths FILE DEST — the macOS paths a file carried whole holds,
# listed and never rewritten (docs/RESOLVER.md → *Paths*).
_scan_x_macpaths() {
  local p
  LC_ALL=C tr '\000' '\n' <"$1" | LC_ALL=C awk -v home="$SCAN_HOME/" '
    {
      s = $0
      while (match(s, /(\/Users\/|\/opt\/homebrew\/|\/usr\/local\/Cellar\/|\/Applications\/|\/Volumes\/|~\/Library\/)[^ \t"\047<>(),;]*/)) {
        p = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        if (!(p in seen)) { seen[p] = 1; print p; if (++n >= 50) exit }
      }
    }' >"$SCAN_XO/macpaths"
  while IFS= read -r p; do
    _scan_x macpath dest "$2" path "$p"
  done <"$SCAN_XO/macpaths"
  rm -f "$SCAN_XO/macpaths"
}

# _scan_x_file SRC DEST CLASS — one file carried whole: captured, then those
# bytes classified (the bytes scanned are the bytes carried).
_scan_x_file() {
  local src=$1 dest=$2 class=$3 mode=0644
  _scan_size "$src" || { _scan_x skip reason "$dest: could not be read"; return 0; }
  if [ "$SCAN_SIZE" -gt "$SCAN_FILE_MAX" ]; then
    _scan_x skip reason "$dest: too-large"
    return 0
  fi
  if ! _scan_x_put "$src"; then
    _scan_x skip reason "$dest: could not be read"
    return 0
  fi
  scan_secret_check "$SCAN_XO/$SCAN_OBJ"
  case $? in
    0) ;;
    1)
      rm -f "$SCAN_XO/$SCAN_OBJ"
      _scan_x skip reason "$dest: $SCAN_HIT"
      return 0
      ;;
    *)
      rm -f "$SCAN_XO/$SCAN_OBJ"
      _scan_x skip reason "$dest: could not be read"
      return 0
      ;;
  esac
  [ -x "$src" ] && mode=0755
  if [ "$class" != config ]; then
    mode=0600
    [ -x "$src" ] && mode=0700
  fi
  _scan_x file dest "$dest" src "$SCAN_OBJ" mode "$mode" whole 1
  _scan_x_macpaths "$SCAN_XO/$SCAN_OBJ" "$dest"
}

# _scan_x_tree MACHINE-ROOT REL DEST CLASS — a folder carried whole: its
# folders, its files (each refused by path or by the scan on its own), and
# the links whose target, resolved from the link's own folder, stays inside
# the item and passes through no other link.
_scan_x_tree() {
  local root=$1 rel=$2 dest=$3 class=$4 dmode=0755 t s m path link
  [ "$class" = config ] || dmode=0700
  _scan_x dir dest "$dest" mode "$dmode"
  sys_walk "$root" "$SCAN_MAX" >"$SCAN_XO/walk"
  case $? in
    0) ;;
    3) _scan_x skip reason "$dest: partial, more than $SCAN_MAX entries; the rest left out" ;;
    *) _scan_x skip reason "$dest: some entries could not be read (denied)" ;;
  esac
  LC_ALL=C awk -F '\t' '$1 == "l" { print $4 }' "$SCAN_XO/walk" >"$SCAN_XO/links"
  while IFS='	' read -r t s m path link; do
    path=$(rec_dec "$path")
    case "$t" in
      d) _scan_x dir dest "$dest/$path" mode "$dmode" ;;
      f)
        if scan_refused "$rel/$path"; then
          _scan_x skip reason "$dest/$path: $SCAN_HIT"
          continue
        fi
        _scan_x_file "$(sys_path "$root/$path")" "$dest/$path" "$class"
        ;;
      l)
        link=$(rec_dec "$link")
        _scan_x_link_ok "$path" "$link"
        if [ "$SCAN_LINK_OK" = 1 ]; then
          _scan_x link dest "$dest/$path" target "$link"
        else
          _scan_x skip reason "$dest/$path: a link $SCAN_LINK_WHY"
        fi
        ;;
      *) _scan_x skip reason "$dest/$path: not a file, folder or link" ;;
    esac
  done <"$SCAN_XO/walk"
  rm -f "$SCAN_XO/walk" "$SCAN_XO/links"
}

# _scan_x_link_ok PATH TARGET — SCAN_LINK_OK 1 when TARGET, read lexically
# from PATH's folder, stays inside the item and passes through no other link
# (the walk's links are in $SCAN_XO/links, encoded).
_scan_x_link_ok() {
  local path=$1 tgt=$2 dir out="" c IFS
  SCAN_LINK_OK=0 SCAN_LINK_WHY=""
  case "$tgt" in
    '') SCAN_LINK_WHY="with no target" && return 0 ;;
    /*) SCAN_LINK_WHY="with an absolute target" && return 0 ;;
  esac
  dir=${path%/*}
  [ "$dir" = "$path" ] && dir=""
  IFS=/
  set -f
  for c in $dir $tgt; do
    case "$c" in
      '' | .) ;;
      ..)
        if [ -z "$out" ]; then set +f && SCAN_LINK_WHY="whose target is outside the item" && return 0; fi
        case "$out" in */*) out=${out%/*} ;; *) out="" ;; esac
        ;;
      *)
        out=${out:+$out/}$c
        rec_enc_v "$out"
        if grep -qxF "$REC_ENC" "$SCAN_XO/links"; then set +f && SCAN_LINK_WHY="whose target passes through another link" && return 0; fi
        ;;
    esac
  done
  set +f
  SCAN_LINK_OK=1
}

# _scan_class_of REL — SCAN_CLASS for a home-relative path an item names:
# opaque for a chosen folder, sensitive for SSH's known hosts and
# authorized keys, config for what an adapter owns.
_scan_class_of() {
  local top=${1%%/*}
  SCAN_CLASS=config
  case "$1" in
    .ssh/known_hosts | .ssh/known_hosts2 | .ssh/authorized_keys) SCAN_CLASS=sensitive && return 0 ;;
    .config/*)
      top=${1#.config/}
      top=${top%%/*}
      case "$SCAN_CONFIG_OWNED" in *" $top "*) return 0 ;; esac
      SCAN_CLASS=opaque
      ;;
    *)
      case "$SCAN_OWNED$SCAN_NEVER" in *" $top "*) return 0 ;; esac
      SCAN_CLASS=opaque
      ;;
  esac
}

# _scan_x_path REL — a path item: a file or folder carried whole, at its
# Linux place; a chosen folder whose root is a link followed once; an
# encrypted SSH key re-read from its envelope. 1 when it is gone.
_scan_x_path() {
  local rel=$1 p t mrel
  p=$(_scan_h "$rel")
  [ -e "$p" ] || [ -L "$p" ] || return 1
  _scan_class_of "$rel"
  _scan_dest "$rel"
  if scan_refused "$rel"; then
    case "$rel" in
      .ssh/*)
        if scan_ssh_key "$p" && _scan_x_put "$p"; then
          # The bytes captured are the bytes whose envelope is checked.
          if scan_ssh_key "$SCAN_XO/$SCAN_OBJ"; then
            _scan_x file dest "$SCAN_DEST" src "$SCAN_OBJ" mode 0600 whole 1
            return 0
          fi
          rm -f "$SCAN_XO/$SCAN_OBJ"
        fi
        ;;
    esac
    _scan_x skip reason "$SCAN_DEST: $SCAN_HIT"
    return 0
  fi
  case "$rel" in
    .ssh/*)
      if _scan_is_key "$p"; then
        if scan_ssh_key "$p" && _scan_x_put "$p" && scan_ssh_key "$SCAN_XO/$SCAN_OBJ"; then
          _scan_x file dest "$SCAN_DEST" src "$SCAN_OBJ" mode 0600 whole 1
        else
          _scan_x skip reason "$SCAN_DEST: an SSH private key that is not a supported encrypted key"
        fi
        return 0
      fi
      ;;
  esac
  mrel="$SCAN_HOME/$rel"
  if [ -L "$p" ]; then
    if [ "$SCAN_CLASS" != opaque ]; then
      _scan_x skip reason "$SCAN_DEST: a link, never followed"
      return 0
    fi
    # A Stow farm: the root is followed once, and only the root.
    t=$(readlink "$p")
    case "$t" in /*) mrel=$t ;; *) mrel=${mrel%/*}/$t ;; esac
    p=$(sys_path "$mrel")
    if [ -L "$p" ]; then
      _scan_x skip reason "$SCAN_DEST: a link to a link, not followed"
      return 0
    fi
  fi
  if [ -f "$p" ]; then
    _scan_x_file "$p" "$SCAN_DEST" "$SCAN_CLASS"
  elif [ -d "$p" ]; then
    _scan_x_tree "$mrel" "$rel" "$SCAN_DEST" "$SCAN_CLASS"
  else
    _scan_x skip reason "$SCAN_DEST: not a file or folder"
  fi
}

# _scan_x_gen DEST — the generated file $SCAN_XO/gen as the next object, its
# bytes scanned like any other; 0 when carried.
_scan_x_gen() {
  if ! scan_secret_check "$SCAN_XO/gen"; then
    _scan_x skip reason "$1: ${SCAN_HIT:-could not be read}"
    rm -f "$SCAN_XO/gen"
    return 1
  fi
  SCAN_XN=$((SCAN_XN + 1))
  SCAN_OBJ=f/$SCAN_XN
  mv -f "$SCAN_XO/gen" "$SCAN_XO/$SCAN_OBJ" || return 1
  _scan_x file dest "$1" src "$SCAN_OBJ" mode 0644 whole 0
}

# _scan_home_path VALUE — SCAN_HP: VALUE with p:home and p:shared applied
# (a path under this Mac's home moves to the target home; Shared's macOS
# mount point to /mnt/shared).
_scan_home_path() {
  SCAN_HP=$1
  case "$SCAN_HP" in
    "$SCAN_HOME"/*) SCAN_HP="$SCAN_TARGET_HOME/${SCAN_HP#"$SCAN_HOME"/}" ;;
    "$SCAN_HOME") SCAN_HP=$SCAN_TARGET_HOME ;;
    /Volumes/Shared/*) SCAN_HP="/mnt/shared/${SCAN_HP#/Volumes/Shared/}" ;;
  esac
}

# _scan_json_str VALUE — SCAN_JS: VALUE as a JSON string; 1 when it holds a
# control byte other than TAB or LF.
_scan_json_str() {
  local v=$1 LC_ALL=C
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  v=${v//$'\t'/\\t}
  v=${v//$'\n'/\\n}
  case "$v" in *[[:cntrl:]]*) SCAN_JS="" && return 1 ;; esac
  SCAN_JS="\"$v\""
}

# _scan_pl_keys FILE OUT — the keys of a small JSON file's top-level object,
# one to a line (plutil names no root key path, so the file is read as one
# value of a scratch object). 1 when it cannot be read.
_scan_pl_keys() {
  local w=$SCAN_TMP/keys.json
  _scan_size "$1" || return 1
  [ "$SCAN_SIZE" -le 262144 ] || return 1
  printf '{"r":0}\n' >"$w"
  if plutil -replace r -json "$(cat "$1")" "$w" >/dev/null 2>&1 && _scan_pl "$w" r >"$2"; then
    rm -f "$w"
    return 0
  fi
  rm -f "$w"
  return 1
}

# _scan_var NAME — SCAN_VAR: a header or key name as an environment variable
# name (upper case, every other byte "_").
_scan_var() { SCAN_VAR=$(printf '%s' "$1" | LC_ALL=C tr '[:lower:]' '[:upper:]' | LC_ALL=C tr -c 'A-Z0-9_' '_'); }

# _scan_cred_flag ARG — ARG is a credential-named flag.
_scan_cred_flag() {
  case "$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')" in
    --token | --api-key | --apikey | --password | --secret | --key | --auth | --access-token) return 0 ;;
  esac
  return 1
}

# _scan_arg_ok PREV ARG — 0 when a command argument may travel: neither a
# credential-named flag nor the argument after one, nor credential-shaped
# (*Secret channels*).
_scan_arg_ok() {
  if _scan_cred_flag "$1" || _scan_cred_flag "$2"; then return 1; fi
  case "$2" in --token=* | --api-key=* | --apikey=* | --password=* | --secret=* | --access-token=*) return 1 ;; esac
  scan_value_ok "$2"
}

_scan_x_shellbash() {
  local t n v
  _scan_zsh "$SCAN_TMP/zsh" || return 1
  {
    printf '# Made by omarchy-mac-bootstrap from the Zsh files on macOS: literal\n'
    printf '# aliases and allowlisted exports only. Nothing else was carried; the\n'
    printf '# Zsh files themselves are in ~/.config/omarchy-mac-bootstrap/zsh/.\n'
    while IFS='	' read -r t n v; do
      case "$t" in
        A)
          case "$v" in *"'"*) printf 'alias %s="%s"\n' "$n" "$v" ;; *) printf "alias %s='%s'\n" "$n" "$v" ;; esac
          ;;
        E)
          case "$v" in
            \$HOME/*) printf 'export %s="%s"\n' "$n" "$v" ;;
            *"'"*) printf 'export %s="%s"\n' "$n" "$v" ;;
            *) printf "export %s='%s'\n" "$n" "$v" ;;
          esac
          ;;
        S) _scan_x skip reason "alias $n: Omarchy defines $n; yours is left for review" ;;
      esac
    done <"$SCAN_TMP/zsh"
  } >"$SCAN_XO/gen"
  _scan_x_gen .config/omarchy-mac-bootstrap/shell.bash
  [ "$SCAN_ZSH_R" = 0 ] || _scan_x skip reason "shell.bash: $SCAN_ZSH_R lines for review (functions, plugins, other exports) are not carried"
  return 0
}

_scan_x_ghostty() {
  local rel f line k v
  for rel in .config/ghostty/config "Library/Application Support/com.mitchellh.ghostty/config"; do
    f=$(_scan_h "$rel")
    [ -f "$f" ] && break
  done
  [ -f "$f" ] || return 1
  : >"$SCAN_XO/gen"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | \#*) continue ;; esac
    k=${line%%=*}
    v=${line#*=}
    k=${k%"${k##*[![:space:]]}"} k=${k#"${k%%[![:space:]]*}"}
    v=${v#"${v%%[![:space:]]*}"}
    case "$line" in *=*) ;; *) _scan_x skip reason "ghostty: a line that is not key = value" && continue ;; esac
    case "$k" in
      '' | *[!a-z0-9-]*) _scan_x skip reason "ghostty: a line that is not key = value" && continue ;;
      macos-*) _scan_x skip reason "ghostty: $k is macOS only" && continue ;;
    esac
    if ! scan_value_ok "$v"; then _scan_x skip reason "ghostty: $k ($SCAN_HIT)" && continue; fi
    _scan_home_path "$v"
    case "$SCAN_HP" in /Users/* | /Applications/* | /opt/homebrew/*) _scan_x macpath dest .config/ghostty/config path "$SCAN_HP" ;; esac
    printf '%s = %s\n' "$k" "$SCAN_HP" >>"$SCAN_XO/gen"
  done <"$f"
  _scan_x_gen .config/ghostty/config
}

_scan_x_ssh() {
  local f
  f=$(_scan_h .ssh/config)
  [ -f "$f" ] || return 1
  LC_ALL=C awk -v home="$SCAN_HOME/" '
    { k = $1; sub(/=.*/, "", k) }
    tolower(k) == "usekeychain" { next }
    { while ((i = index($0, home)) > 0) $0 = substr($0, 1, i - 1) "~/" substr($0, i + length(home)); print }' "$f" >"$SCAN_XO/gen"
  _scan_x_gen .ssh/config
}

_scan_x_git() {
  local f=$1 name v label
  [ -f "$f" ] || return 1
  LC_ALL=C awk '
    function unq(v,   o, i, c, q) {
      o = ""; q = 0
      for (i = 1; i <= length(v); i++) {
        c = substr(v, i, 1)
        if (c == "\\" && i < length(v)) { i++; c = substr(v, i, 1); if (c == "n") c = "\n"; else if (c == "t") c = "\t"; o = o c; continue }
        if (c == "\"") { q = !q; continue }
        if (!q && (c == "#" || c == ";")) break
        o = o c
      }
      sub(/[ \t]+$/, "", o)
      return o
    }
    /^[ \t]*([#;].*)?$/ { next }
    /^[ \t]*\[/ {
      s = $0; sub(/^[ \t]*\[/, "", s); sub(/\][ \t]*([#;].*)?$/, "", s)
      sub_ = ""
      if (match(s, /[ \t]+"/)) { sub_ = substr(s, RSTART + RLENGTH); sub(/"$/, "", sub_); gsub(/\\"/, "\"", sub_); s = substr(s, 1, RSTART - 1) }
      sec = tolower(s); if (sub_ != "") sec = sec "." sub_
      next
    }
    {
      line = $0; sub(/^[ \t]+/, "", line)
      k = line; sub(/[ \t]*=.*$/, "", k)
      v = "true"
      if (index(line, "=")) { v = line; sub(/^[^=]*=[ \t]*/, "", v); v = unq(v) }
      if (sec != "" && k ~ /^[A-Za-z][A-Za-z0-9-]*$/) printf "%s.%s\t%s\n", sec, tolower(k), v
    }' "$f" >"$SCAN_XO/git"
  while IFS='	' read -r name v; do
    # A subsection (a URL, a path) is never written into a reason.
    label=$name
    [ "${name%%.*}.${name##*.}" = "$name" ] || label="${name%%.*}.*.${name##*.}"
    case "$name" in
      user.name | user.email | core.editor | core.pager | core.autocrlf | core.whitespace | core.excludesfile | init.defaultbranch | \
        pull.rebase | pull.ff | push.default | push.autosetupremote | push.followtags | fetch.prune | fetch.prunetags | \
        merge.conflictstyle | merge.ff | diff.algorithm | diff.colormoved | rebase.autosquash | rebase.autostash | rebase.updaterefs | \
        rerere.enabled | branch.sort | tag.sort | column.ui | color.ui | help.autocorrect | commit.verbose | status.showuntrackedfiles | log.date) ;;
      alias.*)
        case "$v" in '!'*) _scan_x skip reason "git $label runs a shell command: listed, not carried" && continue ;; esac
        ;;
      url.*.insteadof | url.*.pushinsteadof)
        if ! _scan_url_ok "$v" || ! _scan_url_ok "${name#url.}"; then
          _scan_x skip reason "git $label: a URL holding a credential, dropped"
          continue
        fi
        ;;
      credential.*) _scan_x skip reason "git $label: a credential helper (macOS only), dropped" && continue ;;
      user.signingkey | commit.gpgsign | tag.gpgsign | gpg.*) _scan_x skip reason "git $label: signing is set up again on Linux" && continue ;;
      include.* | includeif.*) _scan_x skip reason "git $label: an include, listed and not followed" && continue ;;
      *) _scan_x skip reason "git $label: left behind" && continue ;;
    esac
    if ! scan_value_ok "$v"; then _scan_x skip reason "git $label: $SCAN_HIT" && continue; fi
    case "$name" in core.excludesfile | core.editor)
      case "$v" in \~/*) ;; *) _scan_home_path "$v" && v=$SCAN_HP ;; esac
      ;;
    esac
    _scan_x setting kind git tool git name "$name" value "$v"
  done <"$SCAN_XO/git"
  rm -f "$SCAN_XO/git"
}

# Claude Code's settings keys that travel (docs/AI-TOOLS.md → *Claude Code*).
SCAN_CLAUDE_KEYS="permissions model outputStyle enabledPlugins extraKnownMarketplaces theme includeCoAuthoredBy cleanupPeriodDays alwaysThinkingEnabled spinnerTipsEnabled"

# _scan_json_of FILE KEYPATH — SCAN_JV: the value at KEYPATH as JSON text.
_scan_json_of() {
  local t v
  SCAN_JV=""
  t=$(plutil -type "$2" "$1" 2>/dev/null) || return 1
  case "$t" in
    dictionary | array) SCAN_JV=$(plutil -extract "$2" json -o - "$1" 2>/dev/null) || return 1 ;;
    string) _scan_pl_into v "$1" "$2" && _scan_json_str "$v" && SCAN_JV=$SCAN_JS ;;
    bool | integer | float) _scan_pl_into SCAN_JV "$1" "$2" ;;
    *) return 1 ;;
  esac
  [ -n "$SCAN_JV" ]
}

_scan_x_claude_settings() {
  local f k out="{" sep="" names
  f=$(_scan_h .claude/settings.json)
  [ -f "$f" ] || return 1
  for k in $SCAN_CLAUDE_KEYS; do
    _scan_json_of "$f" "$k" || continue
    out="$out$sep\"$k\":$SCAN_JV"
    sep=,
  done
  printf '%s}' "$out" >"$SCAN_XO/raw.json"
  if ! plutil -convert json -r -o "$SCAN_XO/gen" "$SCAN_XO/raw.json" >/dev/null 2>&1; then
    _scan_x skip reason ".claude/settings.json: could not be rebuilt"
    rm -f "$SCAN_XO/raw.json"
    return 0
  fi
  rm -f "$SCAN_XO/raw.json"
  names=$(_scan_pl "$f" env | tr '\n' ' ')
  [ -z "$names" ] || _scan_x skip reason "claude env values never travel: ${names% }"
  _scan_pl "$f" hooks >/dev/null && _scan_x skip reason "claude hooks run code: not carried"
  _scan_pl "$f" statusLine >/dev/null && _scan_x skip reason "claude statusLine runs code: not carried"
  _scan_pl "$f" apiKeyHelper >/dev/null && _scan_x skip reason "claude apiKeyHelper: a credential helper, dropped"
  _scan_x_gen .claude/settings.json
}

_scan_x_claude_mcp() {
  local name=$1 f b out="{" sep="" n i v prev="" arr="" asep="" k needs=""
  f=$(_scan_h .claude.json)
  b="mcpServers.$name"
  plutil -type "$b" "$f" >/dev/null 2>&1 || return 1
  for k in type command cwd url; do
    _scan_pl_into v "$f" "$b.$k" || continue
    case "$k" in
      command | cwd) _scan_home_path "$v" && v=$SCAN_HP ;;
      url)
        if ! _scan_url_ok "$v"; then
          _scan_x skip reason "mcp $name: its URL holds a credential, dropped"
          needs=1
          continue
        fi
        ;;
    esac
    _scan_json_str "$v" || continue
    out="$out$sep\"$k\":$SCAN_JS" sep=,
  done
  n=$(_scan_pl "$f" "$b.args")
  case "$n" in '' | *[!0-9]*) n=0 ;; esac
  i=0
  while [ "$i" -lt "$n" ]; do
    _scan_pl_into v "$f" "$b.args.$i"
    i=$((i + 1))
    if ! _scan_arg_ok "$prev" "$v"; then
      prev=$v
      needs=1
      continue
    fi
    prev=$v
    _scan_home_path "$v"
    _scan_json_str "$SCAN_HP" || continue
    arr="$arr$asep$SCAN_JS" asep=,
  done
  [ "$n" = 0 ] || out="$out$sep\"args\":[$arr]" sep=,
  for k in env headers; do
    _scan_pl "$f" "$b.$k" >"$SCAN_XO/mk" 2>/dev/null || continue
    arr="" asep=""
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      _scan_var "$v"
      _scan_json_str "$v" || continue
      arr="$arr$asep$SCAN_JS:\"\${$SCAN_VAR}\"" asep=,
      needs=1
    done <"$SCAN_XO/mk"
    out="$out$sep\"$k\":{$arr}" sep=,
  done
  rm -f "$SCAN_XO/mk"
  out="$out}"
  _scan_x setting kind mcp tool claude name "$name" value "$out"
  [ -z "$needs" ] || _scan_x skip reason "mcp $name: needs-secret (set its variables on Linux)"
}

_scan_x_claude_plugins() {
  local f k src
  f=$(_scan_h .claude/plugins/known_marketplaces.json)
  if [ -f "$f" ] && _scan_pl_keys "$f" "$SCAN_XO/mk"; then
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      case "$k" in *.*) continue ;; esac
      src=$(plutil -extract "$k.source" json -o - "$f" 2>/dev/null) || continue
      _scan_x setting kind plugin tool claude name "marketplace:$k" value "$src"
    done <"$SCAN_XO/mk"
  fi
  f=$(_scan_h .claude/plugins/installed_plugins.json)
  [ -f "$f" ] || return 1
  _scan_pl "$f" plugins >"$SCAN_XO/mk" 2>/dev/null
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    _scan_x setting kind plugin tool claude name "$k" value install
  done <"$SCAN_XO/mk"
  rm -f "$SCAN_XO/mk"
}

_scan_x_opencode() {
  local f w k p v
  f=$(_scan_h .config/opencode/opencode.json)
  [ -f "$f" ] || return 1
  w=$SCAN_XO/oc.json
  cp "$f" "$w" || return 1
  if _scan_pl_keys "$f" "$SCAN_XO/ok"; then
    while IFS= read -r k; do
      case "$k" in \$schema | mcp | agent | command | instructions | permission | provider | theme | model | small_model | keybinds) continue ;; esac
      case "$k" in *.*) continue ;; esac
      plutil -remove "$k" "$w" >/dev/null 2>&1
      _scan_x skip reason "opencode $k: left behind"
    done <"$SCAN_XO/ok"
  fi
  _scan_pl "$w" plugin >/dev/null && plutil -remove plugin "$w" >/dev/null 2>&1
  _scan_pl "$w" provider >"$SCAN_XO/ok" 2>/dev/null
  while IFS= read -r p; do
    case "$p" in '' | *.*) continue ;; esac
    if _scan_pl "$w" "provider.$p.options.apiKey" >/dev/null; then
      plutil -remove "provider.$p.options.apiKey" "$w" >/dev/null 2>&1
      _scan_x skip reason "opencode provider $p: its API key dropped"
    fi
  done <"$SCAN_XO/ok"
  _scan_pl "$w" mcp >"$SCAN_XO/ok" 2>/dev/null
  while IFS= read -r p; do
    case "$p" in '' | *.*) continue ;; esac
    for k in environment headers; do
      _scan_pl "$w" "mcp.$p.$k" >"$SCAN_XO/ok2" 2>/dev/null || continue
      while IFS= read -r v; do
        case "$v" in '' | *.*) continue ;; esac
        _scan_var "$v"
        plutil -replace "mcp.$p.$k.$v" -string "{env:$SCAN_VAR}" "$w" >/dev/null 2>&1
      done <"$SCAN_XO/ok2"
      _scan_x skip reason "opencode mcp $p: needs-secret ($k values become {env:NAME})"
    done
    if _scan_pl_into v "$w" "mcp.$p.url" && ! _scan_url_ok "$v"; then
      plutil -remove "mcp.$p.url" "$w" >/dev/null 2>&1
      _scan_x skip reason "opencode mcp $p: its URL holds a credential, dropped"
    fi
  done <"$SCAN_XO/ok"
  plutil -convert json -r -o "$SCAN_XO/gen" "$w" >/dev/null 2>&1 || { rm -f "$w" "$SCAN_XO/ok" "$SCAN_XO/ok2"; return 1; }
  rm -f "$w" "$SCAN_XO/ok" "$SCAN_XO/ok2"
  _scan_x skip reason "opencode plugins run code: not carried"
  _scan_x_gen .config/opencode/opencode.json
}

# _SCAN_CODEX_AWK — Codex's configuration, carried as a new config.toml in
# Codex's own shape from the reader's records (docs/AI-TOOLS.md → *Codex's
# configuration*): allowlisted keys only; env values become env_vars names;
# header values, bearer tokens and credential-shaped arguments dropped; the
# rest listed. Writes the file to stdout and one reason per line to `skips`.
# shellcheck disable=SC2016 # awk source
_SCAN_CODEX_AWK='
function dec(s,   o, i) {
  o = ""
  while ((i = index(s, "%")) > 0) { o = o substr(s, 1, i - 1) sprintf("%c", HV[substr(s, i + 1, 2)]); s = substr(s, i + 3) }
  return o s
}
function q(s,   o, i, c, n, a) {
  o = ""
  n = split(s, a, "")
  for (i = 1; i <= n; i++) {
    c = a[i]
    if (c == "\\") o = o "\\\\"
    else if (c == "\"") o = o "\\\""
    else if (c == "\t") o = o "\\t"
    else if (c == "\n") o = o "\\n"
    else if (ORD[c] < 32 || ORD[c] == 127) o = o sprintf("\\u%04X", ORD[c])
    else o = o c
  }
  return "\"" o "\""
}
function k(s) { return s ~ /^[A-Za-z0-9_-]+$/ ? s : q(s) }
function skip(r) { print r > skips }
function lit(t, v) { return t == "s" ? q(v) : v }
function homep(v) {
  if (index(v, home "/") == 1) return target "/" substr(v, length(home) + 2)
  if (v == home) return target
  if (index(v, "/Volumes/Shared/") == 1) return "/mnt/shared/" substr(v, 17)
  return v
}
function urlok(u,   a, l) {
  l = tolower(u)
  a = l; sub(/^[a-z]+:\/\//, "", a); sub(/\/.*/, "", a)
  if (index(a, "@")) return 0
  if (l ~ /[?&](token|key|secret|sig|auth|password|api_key|apikey|access_token)[^=&]*=/) return 0
  return 1
}
function credname(n,   l) { l = tolower(n); return l ~ /(token|key|secret|sig|auth|password)/ }
function credflag(a) { return tolower(a) ~ /^--(token|api-key|apikey|password|secret|key|auth|access-token)$/ }
function shaped(v) {
  return v ~ /(^|[^A-Za-z0-9])(sk-[A-Za-z0-9_-]|gh[pousr]_[A-Za-z0-9]|github_pat_|xox[abposr]-|AKIA[0-9A-Z]|AIza[0-9A-Za-z_-]|eyJ[A-Za-z0-9_-]+[.]eyJ)/
}
function add(sec, line) {
  if (!(sec in SEEN)) { SEEN[sec] = 1; ORDER[++NS] = sec }
  if (line != "") BODY[sec] = BODY[sec] line "\n"
}
BEGIN {
  for (i = 1; i < 256; i++) { ORD[sprintf("%c", i)] = i; HV[sprintf("%02X", i)] = i }
  FS = "\t"
}
{
  t = $1; n = split($2, P, "."); for (i = 1; i <= n; i++) P[i] = dec(P[i]); v = dec($3)
  top = P[1]
  if (n == 1) {
    if (t == "t" || t == "a") next
    if (top == "model" || top == "model_provider" || top == "model_reasoning_effort" || top == "service_tier") { if (t == "s") add("", k(top) " = " q(v)); next }
    if (top == "approval_policy") { if (v == "on-request" || v == "never") add("", k(top) " = " q(v)); else skip("codex approval_policy " v ": not a value Codex 0.157.1 accepts, dropped"); next }
    if (top == "sandbox_mode") { if (v == "read-only" || v == "workspace-write" || v == "danger-full-access") add("", k(top) " = " q(v)); else skip("codex sandbox_mode " v ": dropped"); next }
    if (top == "notify") next
    if (top == "profile") { skip("codex profile: not carried (Codex reads profiles from their own files)"); next }
    skip("codex " top ": left behind"); next
  }
  if (top == "notify") { if (!NOTIFY++) skip("codex notify runs code: not carried"); next }
  if (top == "hooks") { if (!HOOKS++) skip("codex hooks run code: not carried"); next }
  if (top == "profiles") { if (!PROF++) skip("codex [profiles]: not carried (Codex reads profiles from their own files)"); next }
  if (top == "mcp_servers" && n >= 2) {
    s = P[2]; sec = "[mcp_servers." k(s) "]"
    add(sec, ""); SRV[sec] = s
    if (n == 2) next
    f = P[3]
    if (f == "env") { if (n == 4 && t != "t") { ENVN[s] = ENVN[s] (ENVN[s] == "" ? "" : ", ") q(P[4]) }; NEEDS[s] = 1; next }
    if (f == "http_headers") { if (n == 4) skip("codex mcp " s ": http_headers " P[4] " dropped (set it again on Linux)"); next }
    if (f == "bearer_token") { skip("codex mcp " s ": bearer_token dropped"); next }
    if ((f == "command" || f == "cwd") && n == 3 && t == "s") { add(sec, f " = " q(homep(v))); next }
    if (f == "url" && n == 3 && t == "s") { if (urlok(v)) add(sec, "url = " q(v)); else { skip("codex mcp " s ": its URL holds a credential, dropped"); NEEDS[s] = 1 }; next }
    if (f == "args") {
      if (n == 3 && t == "a") { ARGS[s] = ARGS[s] ""; HASARGS[s] = 1; next }
      if (n == 4 && t == "s") {
        if (credflag(PREV[s]) || credflag(v) || shaped(v) || v ~ /^--(token|api-key|apikey|password|secret|access-token)=/) { NEEDS[s] = 1; PREV[s] = v; next }
        PREV[s] = v
        ARGS[s] = ARGS[s] (ARGS[s] == "" ? "" : ", ") q(homep(v)); next
      }
      next
    }
    if (f == "env_vars") { if (n == 4 && t == "s") ENVN[s] = ENVN[s] (ENVN[s] == "" ? "" : ", ") q(v); next }
    if ((f == "enabled_tools" || f == "disabled_tools") && n == 4 && t == "s") { TOOLS[s, f] = TOOLS[s, f] (TOOLS[s, f] == "" ? "" : ", ") q(v); TL[s, f] = 1; next }
    if ((f == "enabled" || f == "required") && n == 3 && t == "b") { add(sec, f " = " v); next }
    if ((f == "startup_timeout_sec" || f == "tool_timeout_sec") && n == 3 && (t == "i" || t == "f")) { add(sec, f " = " v); next }
    if (f == "bearer_token_env_var" && n == 3 && t == "s") { add(sec, f " = " q(v)); next }
    if (f == "env_http_headers" && n == 4 && t == "s") { add(sec, "env_http_headers." k(P[4]) " = " q(v)); next }
    if (f == "tools" && n == 5 && (t == "s" || t == "b")) { add(sec, "tools." k(P[4]) "." k(P[5]) " = " lit(t, v)); next }
    if (t != "t" && t != "a" && !(f == "args" || f == "enabled_tools" || f == "disabled_tools" || f == "tools" || f == "env_http_headers")) skip("codex mcp " s ": " f " left behind")
    next
  }
  if (top == "model_providers" && n >= 2) {
    s = P[2]; sec = "[model_providers." k(s) "]"
    add(sec, "")
    if (n == 2) next
    f = P[3]
    if ((f == "name" || f == "env_key" || f == "wire_api") && n == 3 && t == "s") { add(sec, f " = " q(v)); next }
    if (f == "base_url" && n == 3 && t == "s") { if (urlok(v)) add(sec, "base_url = " q(v)); else skip("codex provider " s ": its URL holds a credential, dropped"); next }
    if (f == "query_params" && n == 4 && t == "s") { if (credname(P[4])) skip("codex provider " s ": query parameter " P[4] " dropped"); else add(sec, "query_params." k(P[4]) " = " q(v)); next }
    if (f == "http_headers" && n == 4) { skip("codex provider " s ": http_headers " P[4] " dropped"); next }
    if (f == "env_http_headers" && n == 4 && t == "s") { add(sec, "env_http_headers." k(P[4]) " = " q(v)); next }
    if (t != "t") skip("codex provider " s ": " f " left behind")
    next
  }
  if (top == "projects" && n == 3 && P[3] == "trust_level" && t == "s") {
    if (index(P[2], home "/") == 1 || P[2] == home) add("[projects." q(homep(P[2])) "]", "trust_level = " q(v))
    else skip("codex project " P[2] ": outside the home, not carried")
    next
  }
  if (top == "projects") next
  if (top == "plugins" && n == 3 && P[3] == "enabled" && t == "b") { add("[plugins." q(P[2]) "]", "enabled = " v); next }
  if (top == "plugins") next
  if (top == "features" || top == "tui" || top == "history" || top == "shell_environment_policy") {
    if (n == 1 || t == "t") next
    if (top == "shell_environment_policy" && P[2] == "set") { if (n == 3) skip("codex shell_environment_policy.set." P[3] ": value dropped"); next }
    if (n == 2 && (t == "b" || t == "i" || t == "f" || (t == "s" && length(v) <= 64 && !shaped(v)))) { add("[" top "]", k(P[2]) " = " lit(t, v)); next }
    if (t != "a") skip("codex " top "." P[2] ": left behind")
    next
  }
  if (t == "t" && n == 1) next
  if (!(top in LEFT)) { LEFT[top] = 1; skip("codex [" top "]: left behind") }
}
END {
  printf "# Carried from macOS by omarchy-mac-bootstrap: allowlisted keys only.\n"
  printf "%s", BODY[""]
  for (i = 1; i <= NS; i++) {
    sec = ORDER[i]
    if (sec == "") continue
    printf "\n%s\n%s", sec, BODY[sec]
    if (!(sec in SRV)) continue
    s = SRV[sec]
    if (s in HASARGS) printf "args = [%s]\n", ARGS[s]
    if (ENVN[s] != "") printf "env_vars = [%s]\n", ENVN[s]
    if ((s, "enabled_tools") in TL) printf "enabled_tools = [%s]\n", TOOLS[s, "enabled_tools"]
    if ((s, "disabled_tools") in TL) printf "disabled_tools = [%s]\n", TOOLS[s, "disabled_tools"]
    if (s in NEEDS) print "codex mcp " s ": needs-secret (set its variables on Linux)" > skips
  }
}'

_scan_x_codex() {
  local f
  f=$(_scan_h .codex/config.toml)
  [ -f "$f" ] || return 1
  if ! toml_read "$f" "$SCAN_XO/codex.rec"; then
    _scan_x skip reason ".codex/config.toml: refused by the TOML reader at line $TOML_AT ($TOML_WHY); carries nothing"
    rm -f "$SCAN_XO/codex.rec"
    return 0
  fi
  : >"$SCAN_XO/skips"
  LC_ALL=C awk -v home="$SCAN_HOME" -v target="$SCAN_TARGET_HOME" -v skips="$SCAN_XO/skips" "$_SCAN_CODEX_AWK" "$SCAN_XO/codex.rec" >"$SCAN_XO/gen"
  while IFS= read -r f; do
    _scan_text "$f"
    _scan_x skip reason "$SCAN_TX"
  done <"$SCAN_XO/skips"
  rm -f "$SCAN_XO/skips" "$SCAN_XO/codex.rec"
  # The file written must itself be one the reader accepts.
  if ! toml_read "$SCAN_XO/gen" "$SCAN_XO/check"; then
    rm -f "$SCAN_XO/gen" "$SCAN_XO/check"
    _scan_x skip reason ".codex/config.toml: the rebuilt file did not read back; carries nothing"
    return 0
  fi
  rm -f "$SCAN_XO/check"
  _scan_x_gen .codex/config.toml
}

# scan_extract ITEM_ID OUTDIR — what the item carries, in its Linux form:
# files ready for their place under OUTDIR/f/, and OUTDIR/carry, record lines
#   file dest=REL src=f/N mode=OCTAL whole=0|1   (whole: carried as found)
#   dir dest=REL mode=OCTAL
#   link dest=REL target=RELATIVE-TEXT
#   setting kind=git|mcp|plugin tool=ID name=BYTES value=BYTES
#   macpath dest=REL path=BYTES   (a macOS path in a file carried whole)
#   skip reason=TEXT
# Every byte written was scanned for credential shapes after it was
# captured. A package carries nothing here (its resolution says how Linux
# gets it). 0; 1 when the item is no longer found; 2 when OUTDIR cannot be
# written or this Mac's account cannot be read.
scan_extract() {
  local id=$1 rc=0
  _scan_identity || return 2
  SCAN_XO=$2 SCAN_XN=0
  mkdir -p "$SCAN_XO/f" && : >"$SCAN_XO/carry" || return 2
  case "$id" in
    shell:bash) _scan_x_shellbash || rc=1 ;;
    ghostty:config) _scan_x_ghostty || rc=1 ;;
    starship:config)
      if [ ! -f "$(_scan_h .config/starship.toml)" ]; then
        rc=1
      elif toml_read "$(_scan_h .config/starship.toml)" "$SCAN_XO/check"; then
        _scan_x_file "$(_scan_h .config/starship.toml)" .config/starship.toml config
      else
        _scan_x skip reason ".config/starship.toml: refused by the TOML reader at line $TOML_AT ($TOML_WHY)"
      fi
      rm -f "$SCAN_XO/check"
      ;;
    ssh:config) _scan_x_ssh || rc=1 ;;
    git:config) _scan_x_git "$(_scan_h .gitconfig)" || rc=1 ;;
    git:config-xdg) _scan_x_git "$(_scan_h .config/git/config)" || rc=1 ;;
    claude:settings) _scan_x_claude_settings || rc=1 ;;
    claude:mcp:*) _scan_x_claude_mcp "${id#claude:mcp:}" || rc=1 ;;
    claude:plugins) _scan_x_claude_plugins || rc=1 ;;
    codex:config) _scan_x_codex || rc=1 ;;
    opencode:config) _scan_x_opencode || rc=1 ;;
    nvim:config) _scan_x_path .config/nvim || rc=1 ;;
    vscode:settings | vscode:keybindings) _scan_x_path "Library/Application Support/Code/User/${id#vscode:}.json" || rc=1 ;;
    vscodium:settings | vscodium:keybindings) _scan_x_path "Library/Application Support/VSCodium/User/${id#vscodium:}.json" || rc=1 ;;
    cursor:settings | cursor:keybindings) _scan_x_path "Library/Application Support/Cursor/User/${id#cursor:}.json" || rc=1 ;;
    vscode:snippets) _scan_x_path "Library/Application Support/Code/User/snippets" || rc=1 ;;
    vscodium:snippets) _scan_x_path "Library/Application Support/VSCodium/User/snippets" || rc=1 ;;
    cursor:snippets) _scan_x_path "Library/Application Support/Cursor/User/snippets" || rc=1 ;;
    path:*) _scan_x_path "${id#path:}" || rc=1 ;;
    project:*)
      if [ -d "$(_scan_h "${id#project:}/.git")" ]; then
        _scan_x skip reason "${id#project:}: a project, cloned again on Linux and never copied"
      else
        rc=1
      fi
      ;;
    *:signin | *:credentials | *:mcp-signin | gh:hosts) _scan_x skip reason "$id: a sign-in, never carried" ;;
    *:sessions | claude:projects) _scan_x skip reason "$id: sessions and history, not carried in v1" ;;
    iterm2:* | zoxide:*) _scan_x skip reason "$id: macOS only" ;;
    ai:claude-code | ai:codex | ai:opencode) ;;
    ai:*) _scan_x skip reason "$id: recognised, not migrated yet" ;;
    *) ;;
  esac
  return "$rc"
}

# ---------------------------------------------------------------------------
# `scan` (read): the inventory, printed; nothing is written but the run's
# scratch, which goes when it ends.
# ---------------------------------------------------------------------------

_scan_cmd_progress() {
  case "$1" in
    done)
      case "$3" in
        done) ui_check pass "$2" "$4 items" ;;
        skipped) ui_check info "$2" "skipped${5:+ · $5}" ;;
        partial) ui_check warn "$2" "partial · $4 items${5:+ · $5}" ;;
        *) ui_check fail "$2" "$3 · $4 items${5:+ · $5}" ;;
      esac
      ;;
  esac
}

scan_cmd() {
  local out cat line name ver cls ev note last=""
  ui_header "scan"
  ui_section "Environment scan" "read as text; nothing runs"
  omb_tmp_init || return 1
  out=$OMB_TMP/inventory
  SCAN_PROGRESS=_scan_cmd_progress
  if ! scan_run "$out"; then
    ui_fail "The scan could not read this Mac's account."
    return 1
  fi
  SCAN_PROGRESS=""
  for cat in ${REC_CATEGORIES//|/ }; do
    last=""
    while IFS= read -r line; do
      case "$line" in item*) ;; *) continue ;; esac
      _rec_field_raw "$line" category
      [ "$REC_RAW" = "$cat" ] || continue
      [ -n "$last" ] || ui_section "$cat"
      last=1
      _rec_field_raw "$line" name && _rec_dec_into name "$REC_RAW"
      _rec_field_raw "$line" version && _rec_dec_into ver "$REC_RAW"
      _rec_field_raw "$line" class && cls=$REC_RAW
      _rec_field_raw "$line" evidence && ev=$REC_RAW
      _rec_field_raw "$line" note && _rec_dec_into note "$REC_RAW"
      _scan_text "$name${ver:+ $ver}"
      name=$SCAN_TX
      _scan_text "$cls${ev:+, $ev}${note:+, $note}"
      ui_kv "$name" "$SCAN_TX"
    done <"$out"
  done
  printf '\n'
  ui_note "Nothing was run and nothing was written. ./omarchy-bootstrap profile saves this inventory and your choices."
  printf '\n'
}
