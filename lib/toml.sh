# shellcheck shell=bash
# The strict TOML subset reader (docs/AI-TOOLS.md → *Codex's configuration*;
# docs/DECISIONS.md → D44), for Codex's and mise's configuration on macOS.
#
# It accepts what Codex and mise write and refuses the whole file on anything
# else, naming the first line it could not read and the construct: no value
# of a refused file is ever used. One C-locale awk pass reads the file (after
# a size check, and with NUL bytes turned into a control byte the pass then
# refuses): every line's bytes first, then the grammar, then TOML's own
# rules on keys and tables. Nothing is evaluated; no value reaches a shell.
#
# Needs nothing beyond awk, tr, wc and head.

TOML_MAX_BYTES=1048576

# toml_read FILE OUT — 0 accepted: OUT holds one line per definition, in the
# file's order, "KIND<TAB>PATH<TAB>VALUE":
#   t  a table: a [header], an element of an [[array of tables]], an inline
#      table (VALUE empty)
#   a  a static array; VALUE is its length (written after its elements)
#   s  a string   i  an integer   f  a float   b  true or false
# PATH is the key's components joined by "." — each byte outside
# [A-Za-z0-9_-] as %XX, so a quoted key holding a dot stays one component —
# and an array's elements are numbered from 0. VALUE is in the record
# format's canonical encoding (rec_dec decodes it; a string holds no NUL).
# 1 refused: TOML_AT is the first line it could not read (0: the whole file)
# and TOML_WHY the construct; OUT is empty. 2 when FILE cannot be read.
toml_read() {
  local f=$1 out=$2 size st
  TOML_AT=0 TOML_WHY=""
  : >"$out" || return 2
  [ -f "$f" ] && [ -r "$f" ] || return 2
  size=$(wc -c <"$f") || return 2
  size=$((size + 0))
  if [ "$size" -gt "$TOML_MAX_BYTES" ]; then
    TOML_WHY="a file over 1 MiB"
    return 1
  fi
  # A NUL becomes \001, which the pass refuses as a control character on
  # its own line; awk never sees a NUL.
  head -c "$((TOML_MAX_BYTES + 1))" "$f" | LC_ALL=C tr '\000' '\001' |
    LC_ALL=C awk -v out="$out" "$_TOML_AWK" >"$out.status"
  st=$?
  if [ "$st" != 0 ] || ! IFS=' ' read -r TOML_RES TOML_AT TOML_WHY <"$out.status"; then
    rm -f "$out.status"
    : >"$out"
    return 2
  fi
  rm -f "$out.status"
  case "$TOML_RES" in
    ok) TOML_AT=0 TOML_WHY="" && return 0 ;;
    refuse) : >"$out" && return 1 ;;
  esac
  : >"$out"
  return 2
}

# toml_get FILE PATH — the VALUE of PATH's line in toml_read's output, encoded;
# 1 when there is none.
toml_get() {
  local line
  line=$(LC_ALL=C awk -F '\t' -v p="$2" '$2 == p { print; exit }' "$1") || return 1
  [ -n "$line" ] || return 1
  TOML_KIND=${line%%	*}
  line=${line#*	}
  TOML_VALUE=${line#*	}
}

# shellcheck disable=SC2016 # awk source: awk expands its own variables
_TOML_AWK='
function refuse(why) {
  if (!DONE) printf "refuse %d %s\n", (LN > NL ? NL : LN), why
  DONE = 1
  exit 0
}
function load(ln) { LN = ln; NC = split(L[ln], CH, ""); P = 1 }
function eol() { return P > NC }
function cur() { return P <= NC ? CH[P] : "\n" }
function nextline() {
  if (LN >= NL) refuse("an unterminated value at the end of the file")
  load(LN + 1)
}
function ws() { while (P <= NC && (CH[P] == " " || CH[P] == "\t")) P++ }
# Whitespace, newlines and comments inside an array.
function wsnl() {
  for (;;) {
    ws()
    if (P <= NC && CH[P] == "#") P = NC + 1
    if (P <= NC) return
    nextline()
  }
}
function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }
function utf8(cp) {
  if (cp < 128) return sprintf("%c", cp)
  if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
  if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
  return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
}
# An escape after a backslash at P (P is on the character after it).
function escape(   c, n, i, cp, h) {
  c = cur()
  if (c == "b") { P++; return "\b" }
  if (c == "t") { P++; return "\t" }
  if (c == "n") { P++; return "\n" }
  if (c == "f") { P++; return "\f" }
  if (c == "r") { P++; return "\r" }
  if (c == "e") { P++; return sprintf("%c", 27) }
  if (c == "\"") { P++; return "\"" }
  if (c == "\\") { P++; return "\\" }
  n = 0
  if (c == "x") n = 2
  if (c == "u") n = 4
  if (c == "U") n = 8
  if (n == 0) refuse("an escape TOML does not define")
  P++
  cp = 0
  for (i = 0; i < n; i++) {
    h = (P <= NC) ? hexval(CH[P]) : -1
    if (h < 0) refuse("an escape TOML does not define")
    cp = cp * 16 + h
    P++
  }
  if (cp == 0) refuse("a NUL escape in a string")
  if ((cp >= 55296 && cp <= 57343) || cp > 1114111) refuse("an escape that is not a Unicode scalar")
  return utf8(cp)
}
# Strings: P is on the opening quote.
function basic(   s, c) {
  P++
  s = ""
  for (;;) {
    if (P > NC) refuse("an unterminated string")
    c = CH[P]
    if (c == "\"") { P++; return s }
    if (c == "\\") { P++; s = s escape(); continue }
    s = s c
    P++
  }
}
function literal(   s, c) {
  P++
  s = ""
  for (;;) {
    if (P > NC) refuse("an unterminated string")
    c = CH[P]
    if (c == SQ) { P++; return s }
    s = s c
    P++
  }
}
# Multi-line strings: P is on the first of the three quotes; q is the quote.
function multi(q,   s, c, n, rest) {
  P += 3
  s = ""
  if (P > NC) nextline()
  for (;;) {
    if (P > NC) { s = s "\n"; nextline(); continue }
    c = CH[P]
    if (c == q) {
      n = 0
      while (P <= NC && CH[P] == q) { n++; P++ }
      if (n < 3) { while (n-- > 0) s = s q; continue }
      if (n > 5) refuse("too many quotes closing a multi-line string")
      while (n-- > 3) s = s q
      return s
    }
    if (q == "\"" && c == "\\") {
      rest = substr(L[LN], P + 1)
      if (rest ~ /^[ \t]*$/) {
        # A line-ending backslash: the newline and the whitespace after it go.
        P = NC + 1
        for (;;) {
          if (P > NC) { nextline(); continue }
          if (CH[P] == " " || CH[P] == "\t") { P++; continue }
          break
        }
        continue
      }
      P++
      s = s escape()
      continue
    }
    s = s c
    P++
  }
}
function str(   c) {
  c = cur()
  if (c == "\"") {
    if (CH[P + 1] == "\"" && CH[P + 2] == "\"") return multi("\"")
    return basic()
  }
  if (CH[P + 1] == SQ && CH[P + 2] == SQ) return multi(SQ)
  return literal()
}
# A key: KN components in K[1..KN], decoded.
function key(   c, s) {
  KN = 0
  for (;;) {
    ws()
    c = cur()
    if (c == "\"") { s = basic() }
    else if (c == SQ) { s = literal() }
    else {
      s = ""
      while (P <= NC && CH[P] ~ /[A-Za-z0-9_-]/) { s = s CH[P]; P++ }
      if (s == "") refuse("a key outside the subset")
    }
    if (s == "") refuse("an empty key")
    K[++KN] = s
    ws()
    if (cur() != ".") return
    P++
  }
}
# A path component, encoded: bytes outside [A-Za-z0-9_-] as %XX.
function enck(s,   o, i, n, c, a) {
  o = ""
  n = split(s, a, "")
  for (i = 1; i <= n; i++) {
    c = a[i]
    if (c ~ /[A-Za-z0-9_-]/) o = o c
    else o = o "%" substr(HEX, int(ORD[c] / 16) + 1, 1) substr(HEX, ORD[c] % 16 + 1, 1)
  }
  return o
}
# A value, in the record format canonical encoding.
function encv(s,   o, i, n, c, a) {
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
function emit(kind, path, v) { printf "%s\t%s\t%s\n", kind, path, v > out }
function join(a, b) { return a == "" ? b : a "." b }
function both() { refuse("a key that is both a value and a table") }
# [header] or [[header]]: P is on the first bracket.
function header(   aot, i, p, k, cp, e) {
  P++
  aot = 0
  if (cur() == "[") { aot = 1; P++ }
  key()
  if (cur() != "]") refuse("a table header outside the subset")
  P++
  if (aot) {
    if (cur() != "]") refuse("a table header outside the subset")
    P++
  }
  cp = ""
  for (i = 1; i < KN; i++) {
    p = join(cp, enck(K[i]))
    k = KIND[p]
    if (k == "") { KIND[p] = "I"; cp = p }
    else if (k == "T" || k == "I" || k == "D") cp = p
    else if (k == "A") cp = p "." (AOTN[p] - 1)
    else both()
  }
  p = join(cp, enck(K[KN]))
  k = KIND[p]
  if (aot) {
    if (k == "S") refuse("an array of tables after a static array of that name")
    if (k != "" && k != "A") refuse("a table defined twice")
    if (k == "") { KIND[p] = "A"; AOTN[p] = 0 }
    e = p "." AOTN[p]
    AOTN[p]++
    KIND[e] = "T"
    emit("t", e, "")
    CUR = e
    return
  }
  if (k == "" || k == "I") { KIND[p] = "T"; emit("t", p, ""); CUR = p; return }
  if (k == "V" || k == "S" || k == "L") both()
  refuse("a table defined twice")
}
# key = value, in the table at base: P is on the key.
function keyval(base, depth,   i, p, k, cp) {
  key()
  if (cur() != "=") refuse("a key without = and a value")
  P++
  ws()
  cp = base
  for (i = 1; i < KN; i++) {
    p = join(cp, enck(K[i]))
    k = KIND[p]
    if (k == "") { KIND[p] = "D"; cp = p }
    else if (k == "D") cp = p
    else if (k == "V" || k == "S" || k == "L") both()
    else refuse("a table defined twice")
  }
  p = join(cp, enck(K[KN]))
  k = KIND[p]
  if (k == "V" || k == "S" || k == "L") refuse("a key defined twice")
  if (k != "") both()
  value(p, depth)
}
function number(p,   t, c, d, lim) {
  t = ""
  while (P <= NC && CH[P] ~ /[A-Za-z0-9_.:+-]/) { t = t CH[P]; P++ }
  if (t == "") refuse("a value outside the subset")
  if (t ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ || t ~ /^[0-9][0-9]:[0-9][0-9]/) refuse("a date or time value")
  if (t ~ /^[+-]?(inf|nan)$/) refuse("inf or nan")
  if (index(t, "_")) refuse("an underscore in a number")
  if (t ~ /^[+-]?0[xob]/) refuse("a hexadecimal, octal or binary integer")
  if (t ~ /^[+-]?(0|[1-9][0-9]*)$/) {
    d = t
    sub(/^[+-]/, "", d)
    lim = (substr(t, 1, 1) == "-") ? "9223372036854775808" : "9223372036854775807"
    if (length(d) > 19 || (length(d) == 19 && d > lim)) refuse("an integer outside 64 bits")
    sub(/^\+/, "", t)
    KIND[p] = "V"
    emit("i", p, encv(t))
    return
  }
  if (t ~ /^[+-]?0[0-9]/) refuse("a number with a leading zero")
  if (t ~ /^[+-]?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/ && t ~ /[.eE]/) {
    sub(/^\+/, "", t)
    KIND[p] = "V"
    emit("f", p, encv(t))
    return
  }
  refuse("a value outside the subset")
}
function value(p, depth,   c, n, s, ln0) {
  c = cur()
  if (c == "\"" || c == SQ) {
    s = str()
    KIND[p] = "V"
    emit("s", p, encv(s))
    return
  }
  if (c == "[") {
    if (depth >= 16) refuse("arrays or inline tables nested more than 16 deep")
    P++
    KIND[p] = "S"
    n = 0
    for (;;) {
      wsnl()
      if (cur() == "]") { P++; break }
      value(p "." n, depth + 1)
      n++
      wsnl()
      c = cur()
      if (c == ",") { P++; continue }
      if (c == "]") { P++; break }
      refuse("an array outside the subset")
    }
    emit("a", p, n)
    return
  }
  if (c == "{") {
    if (depth >= 16) refuse("arrays or inline tables nested more than 16 deep")
    P++
    # The whole table on its line: a value inside it (an array, a
    # multi-line string) may not carry it onto the next.
    ln0 = LN
    KIND[p] = "L"
    emit("t", p, "")
    ws()
    if (eol()) refuse("an inline table over several lines")
    if (cur() == "}") { P++; return }
    for (;;) {
      keyval(p, depth + 1)
      if (LN != ln0) { LN = ln0; refuse("an inline table over several lines") }
      ws()
      if (eol()) refuse("an inline table over several lines")
      c = cur()
      if (c == "}") { P++; return }
      if (c != ",") refuse("an inline table outside the subset")
      P++
      ws()
      if (eol()) refuse("an inline table over several lines")
      if (cur() == "}") refuse("a trailing comma in an inline table")
    }
  }
  if (substr(L[LN], P, 4) == "true" && (P + 4 > NC || CH[P + 4] ~ /[ \t,\]}#]/)) {
    P += 4
    KIND[p] = "V"
    emit("b", p, "true")
    return
  }
  if (substr(L[LN], P, 5) == "false" && (P + 5 > NC || CH[P + 5] ~ /[ \t,\]}#]/)) {
    P += 5
    KIND[p] = "V"
    emit("b", p, "false")
    return
  }
  number(p)
}
# Every line bytes first: length, control bytes, UTF-8.
function utf8ok(s,   n, a, i, b, need, lo, hi) {
  n = split(s, a, "")
  need = 0
  for (i = 1; i <= n; i++) {
    b = ORD[a[i]]
    if (need == 0) {
      if (b < 128) continue
      lo = 128; hi = 191
      if (b >= 194 && b <= 223) need = 1
      else if (b >= 224 && b <= 239) { need = 2; if (b == 224) lo = 160; if (b == 237) hi = 159 }
      else if (b >= 240 && b <= 244) { need = 3; if (b == 240) lo = 144; if (b == 244) hi = 143 }
      else return 0
    } else {
      if (b < lo || b > hi) return 0
      lo = 128; hi = 191
      need--
    }
  }
  return need == 0
}
BEGIN {
  HEX = "0123456789ABCDEF"
  SQ = sprintf("%c", 39)
  for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
  CTRL = sprintf("[%c-%c%c-%c%c]", 1, 8, 11, 31, 127)
  HIGH = sprintf("[%c-%c]", 128, 255)
  CR = sprintf("%c", 13)
}
{
  NL = NR
  L[NR] = $0
  if (DONE) next
  LN = NR
  if (length($0) > 16384) refuse("a line over 16 KiB")
  if (index($0, CR)) refuse("a CR byte")
  if ($0 ~ CTRL) refuse("a control character")
  if ($0 ~ HIGH && !utf8ok($0)) refuse("invalid UTF-8")
}
END {
  if (DONE) exit 0
  CUR = ""
  LN = 1
  while (LN <= NL) {
    load(LN)
    ws()
    c = cur()
    if (c == "[") header()
    else if (c != "#" && c != "\n") keyval(CUR, 0)
    ws()
    if (cur() == "#") P = NC + 1
    if (!eol()) refuse("text after a value on its line")
    LN++
  }
  printf "ok 0 -\n"
}'
