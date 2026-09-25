# shellcheck shell=bash
# Terminal presentation.
#
# Visual language: a surveyor's plate. One mark (◒, a sun rising over a
# horizon — asahi), a journey rail that spans both operating systems, section
# bars (▍), and a proportional disk strip that is the centrepiece of planning.
# Colour carries meaning: steel = macOS, coral = Linux, violet = boot/system,
# mint/amber/rose = pass/warn/fail. Everything degrades: 256 → 16 → no colour,
# Unicode → ASCII. The Linux VT console (TERM=linux) always gets ASCII.

ESC=$(printf '\033')

ui_init() {
  local depth=256 colors

  if [ -n "${NO_COLOR:-}" ] || [ "${OMB_COLOR:-auto}" = never ] || [ ! -t 1 ] || [ "${TERM:-dumb}" = dumb ]; then
    depth=0
  else
    colors=$(tput colors 2>/dev/null || echo 8)
    case "${COLORTERM:-}" in
      truecolor | 24bit) depth=256 ;;
      *) if [ "${colors:-8}" -ge 256 ] 2>/dev/null; then depth=256; else depth=16; fi ;;
    esac
    [ "${TERM:-}" = linux ] && depth=16
  fi
  [ "${OMB_COLOR:-auto}" = always ] && depth=256
  UI_DEPTH=$depth

  UI_UNICODE=0
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8* | *utf-8* | *UTF8* | *utf8*) UI_UNICODE=1 ;;
  esac
  [ "${TERM:-}" = linux ] && UI_UNICODE=0
  [ "${OMB_ASCII:-0}" = 1 ] && UI_UNICODE=0

  local cols=${COLUMNS:-}
  [ -n "$cols" ] || cols=$(tput cols 2>/dev/null || echo 80)
  case "$cols" in '' | *[!0-9]*) cols=80 ;; esac
  UI_W=$((cols - 4))
  [ "$UI_W" -gt 72 ] && UI_W=72
  [ "$UI_W" -lt 40 ] && UI_W=40

  _ui_palette
  _ui_glyphs
}

_ui_palette() {
  if [ "$UI_DEPTH" = 0 ]; then
    C_RESET="" C_BOLD="" C_DIM="" C_FAINT="" C_INK="" C_ACCENT=""
    C_MAC="" C_LINUX="" C_BOOT="" C_PASS="" C_WARN="" C_FAIL="" C_INFO=""
    return
  fi
  C_RESET="${ESC}[0m"
  C_BOLD="${ESC}[1m"
  C_DIM="${ESC}[2m"
  if [ "$UI_DEPTH" = 256 ]; then
    C_INK="${ESC}[38;5;253m"
    C_FAINT="${ESC}[38;5;239m"
    C_ACCENT="${ESC}[38;5;209m"
    C_MAC="${ESC}[38;5;110m"
    C_LINUX="${ESC}[38;5;209m"
    C_BOOT="${ESC}[38;5;141m"
    C_PASS="${ESC}[38;5;115m"
    C_WARN="${ESC}[38;5;222m"
    C_FAIL="${ESC}[38;5;204m"
    C_INFO="${ESC}[38;5;110m"
    C_DIM="${ESC}[38;5;245m"
  else
    C_INK="${ESC}[37m"
    C_FAINT="${ESC}[90m"
    C_ACCENT="${ESC}[91m"
    C_MAC="${ESC}[34m"
    C_LINUX="${ESC}[91m"
    C_BOOT="${ESC}[35m"
    C_PASS="${ESC}[32m"
    C_WARN="${ESC}[33m"
    C_FAIL="${ESC}[31m"
    C_INFO="${ESC}[36m"
  fi
}

_ui_glyphs() {
  if [ "$UI_UNICODE" = 1 ]; then
    G_MARK="◒" G_RULE="─" G_HEAVY="━" G_BAR="▍" G_EDGE="┃"
    G_TOP="┏" G_BOT="┗" G_DONE="●" G_CUR="◆" G_TODO="○" G_ARROW="→"
    G_POINT="❯" G_PASS="✓" G_WARN="!" G_FAIL="✗" G_INFO="·" G_UNK="?"
    G_ON="◉" G_OFF="○" G_DOT="·" G_WOULD="◌" G_APPROX="≈"
    G_SL="▕" G_SR="▏"
    S_MAC_USED="█" S_MAC_FREE="░" S_LINUX="█" S_BOOT="▒" S_SHARED="▚" S_UNALLOC=" "
    G_SPIN="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  else
    G_MARK="(o)" G_RULE="-" G_HEAVY="=" G_BAR="| " G_EDGE="|"
    G_TOP="+" G_BOT="+" G_DONE="*" G_CUR=">" G_TODO="." G_ARROW="->"
    G_POINT=">" G_PASS="+" G_WARN="!" G_FAIL="x" G_INFO="-" G_UNK="?"
    G_ON="[x]" G_OFF="[ ]" G_DOT="-" G_WOULD="~" G_APPROX="~"
    G_SL="[" G_SR="]"
    S_MAC_USED="M" S_MAC_FREE="m" S_LINUX="L" S_BOOT="b" S_SHARED="s" S_UNALLOC="."
    G_SPIN="|/-\\"
  fi
}

# repeat CHAR N
_rep() {
  local out="" i=0
  while [ "$i" -lt "$2" ]; do
    out="$out$1"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

ui_rule() { printf ' %s%s%s\n' "$C_FAINT" "$(_rep "$G_RULE" "$UI_W")" "$C_RESET"; }

# ui_header RIGHT-LABEL
ui_header() {
  local right=$1 title="omarchy${G_DOT}mac bootstrap" pad
  pad=$((UI_W - ${#G_MARK} - 2 - ${#title} - ${#right}))
  [ "$pad" -lt 2 ] && pad=2
  printf '\n %s%s%s  %s%somarchy%s%s%s%smac bootstrap%s%s%s%s\n' \
    "$C_ACCENT" "$G_MARK" "$C_RESET" \
    "$C_BOLD" "$C_INK" "$C_RESET" "$C_FAINT" "$G_DOT" "$C_RESET$C_BOLD$C_INK" "$C_RESET" \
    "$(_rep ' ' "$pad")" "$C_DIM$right" "$C_RESET"
  ui_rule
}

# ui_rail "STATE STATE ..." — six states (done|current|todo), one per stage.
RAIL_STAGES="survey plan asahi reboot omarchy dev"
ui_rail() {
  local states=$1 line="" stage glyph color st join first=1
  join=" $G_RULE$G_RULE$G_RULE "
  [ "$UI_W" -lt 68 ] && join=" $G_RULE "
  for stage in $RAIL_STAGES; do
    st=${states%% *}
    states=${states#* }
    case "$st" in
      done) glyph=$G_DONE color=$C_PASS ;;
      current) glyph=$G_CUR color="$C_ACCENT$C_BOLD" ;;
      *) glyph=$G_TODO color=$C_FAINT ;;
    esac
    [ "$first" = 1 ] || line="$line$C_FAINT$join$C_RESET"
    first=0
    line="$line$color$glyph $stage$C_RESET"
  done
  printf ' %s\n' "$line"
}

ui_section() {
  local title=$1 right=${2:-} pad
  printf '\n %s%s%s%s%s%s' "$C_ACCENT" "$G_BAR" "$C_RESET" "$C_BOLD$C_INK" "$title" "$C_RESET"
  if [ -n "$right" ]; then
    pad=$((UI_W - ${#title} - ${#right} - 1))
    [ "$pad" -lt 2 ] && pad=2
    printf '%s%s%s%s' "$(_rep ' ' "$pad")" "$C_DIM" "$right" "$C_RESET"
  fi
  printf '\n'
}

# ui_kv KEY VALUE [NOTE]
ui_kv() {
  printf '   %s%-19s%s %s' "$C_DIM" "$1" "$C_RESET" "$2"
  [ -n "${3:-}" ] && printf '  %s%s%s' "$C_DIM" "$3" "$C_RESET"
  printf '\n'
}

_ui_status_style() {
  case "$1" in
    pass) UI_G=$G_PASS UI_C=$C_PASS UI_T=PASS ;;
    warn) UI_G=$G_WARN UI_C=$C_WARN UI_T=WARN ;;
    fail) UI_G=$G_FAIL UI_C=$C_FAIL UI_T=FAIL ;;
    info) UI_G=$G_INFO UI_C=$C_INFO UI_T=INFO ;;
    *) UI_G=$G_UNK UI_C=$C_WARN UI_T="  ? " ;;
  esac
}

# ui_check STATUS LABEL DETAIL — a compatibility line with a glyph.
ui_check() {
  _ui_status_style "$1"
  printf '   %s%s%s %-18s %s%s%s\n' "$UI_C$C_BOLD" "$UI_G" "$C_RESET" "$2" "$C_DIM" "${3:-}" "$C_RESET"
}

# ui_tag STATUS LABEL DETAIL — a doctor line: [PASS] label  detail
ui_tag() {
  _ui_status_style "$1"
  printf '   %s[%s]%s %-24s %s%s%s\n' "$UI_C$C_BOLD" "$UI_T" "$C_RESET" "$2" "$C_DIM" "${3:-}" "$C_RESET"
}

# ui_note TEXT — dim, wrapped, indented prose.
ui_note() {
  printf '%s\n' "$*" | fold -s -w $((UI_W - 4)) | while IFS= read -r l; do
    printf '   %s%s%s\n' "$C_DIM" "$l" "$C_RESET"
  done
}

# ui_para TEXT — normal wrapped prose.
ui_para() {
  printf '%s\n' "$*" | fold -s -w $((UI_W - 4)) | while IFS= read -r l; do
    printf '   %s\n' "$l"
  done
}

# ui_callout STYLE TITLE LINE... — heavy left edge; the motif for anything
# that matters before a destructive boundary.
ui_callout() {
  local style=$1 title=$2 color
  shift 2
  case "$style" in
    warn) color=$C_WARN ;;
    fail) color=$C_FAIL ;;
    linux) color=$C_LINUX ;;
    *) color=$C_INFO ;;
  esac
  printf '\n   %s%s%s %s%s%s\n' "$color" "$G_EDGE" "$C_RESET" "$C_BOLD" "$title" "$C_RESET"
  local line
  for line in "$@"; do
    ui_callout_body "$style" "$line"
  done
}

# ui_blockers TITLE LINES — a fail callout, one paragraph per line of LINES.
ui_blockers() {
  local line
  ui_callout fail "$1"
  while IFS= read -r line; do
    [ -n "$line" ] && ui_callout_body fail "$line"
  done <<EOF
$2
EOF
  printf '\n'
}

# ui_callout_body STYLE TEXT — one more wrapped paragraph under a callout.
ui_callout_body() {
  local color
  case "$1" in
    warn) color=$C_WARN ;;
    fail) color=$C_FAIL ;;
    linux) color=$C_LINUX ;;
    *) color=$C_INFO ;;
  esac
  printf '%s\n' "$2" | fold -s -w $((UI_W - 7)) | while IFS= read -r l; do
    printf '   %s%s%s %s\n' "$color" "$G_EDGE" "$C_RESET" "$l"
  done
}

# ui_cmd COMMAND — a copyable command, visually distinct, never wrapped.
ui_cmd() { printf '     %s$%s %s%s%s\n' "$C_FAINT" "$C_RESET" "$C_ACCENT" "$*" "$C_RESET"; }

ui_would() { printf '   %s%s would run%s  %s\n' "$C_WARN" "$G_WOULD" "$C_RESET" "$*"; }

ui_ok() { printf '   %s%s%s %s\n' "$C_PASS$C_BOLD" "$G_PASS" "$C_RESET" "$*"; }
ui_warn() { printf '   %s%s%s %s\n' "$C_WARN$C_BOLD" "$G_WARN" "$C_RESET" "$*"; }
ui_fail() { printf '   %s%s%s %s\n' "$C_FAIL$C_BOLD" "$G_FAIL" "$C_RESET" "$*"; }
ui_info() { printf '   %s%s%s %s\n' "$C_INFO" "$G_INFO" "$C_RESET" "$*"; }

# ui_card_open TITLE / ui_card_row NUM PROMPT ANSWER NOTE / ui_card_close
# The answer card: what to type into an upstream installer, in order.
ui_card_open() {
  local rest=$((UI_W - ${#1} - 7))
  [ "$rest" -lt 3 ] && rest=3
  printf '\n   %s%s%s%s %s%s%s %s%s%s\n' "$C_LINUX" "$G_TOP" "$G_HEAVY" "$G_HEAVY" "$C_BOLD$C_INK" "$1" "$C_RESET" \
    "$C_LINUX" "$(_rep "$G_HEAVY" "$rest")" "$C_RESET"
  printf '   %s%s%s\n' "$C_LINUX" "$G_EDGE" "$C_RESET"
}
ui_card_row() {
  printf '   %s%s%s  %s%-2s%s %-30s %s%-12s%s' "$C_LINUX" "$G_EDGE" "$C_RESET" "$C_DIM" "$1" "$C_RESET" "$2" "$C_BOLD$C_ACCENT" "$3" "$C_RESET"
  [ -n "${4:-}" ] && printf ' %s%s%s' "$C_DIM" "$4" "$C_RESET"
  printf '\n'
}
ui_card_text() { printf '   %s%s%s     %s%s%s\n' "$C_LINUX" "$G_EDGE" "$C_RESET" "$C_DIM" "$1" "$C_RESET"; }
ui_card_close() {
  printf '   %s%s%s\n' "$C_LINUX" "$G_EDGE" "$C_RESET"
  printf '   %s%s%s%s\n' "$C_LINUX" "$G_BOT" "$(_rep "$G_HEAVY" $((UI_W - 4)))" "$C_RESET"
}

# ---------------------------------------------------------------------------
# The disk strip: proportional segments with a legend.
# ui_strip TOTAL KIND:BYTES:LABEL ...   KIND ∈ mac_used mac_free linux boot shared unalloc
# Every non-empty segment gets at least one cell; the largest segment absorbs
# the rounding so the bar is always exactly the same width.
# ---------------------------------------------------------------------------

_strip_style() {
  case "$1" in
    mac_used) UI_S=$S_MAC_USED UI_C=$C_MAC ;;
    mac_free) UI_S=$S_MAC_FREE UI_C=$C_MAC ;;
    linux) UI_S=$S_LINUX UI_C=$C_LINUX ;;
    boot) UI_S=$S_BOOT UI_C=$C_BOOT ;;
    shared) UI_S=$S_SHARED UI_C=$C_PASS ;;
    *) UI_S=$S_UNALLOC UI_C=$C_FAINT ;;
  esac
}

ui_strip() {
  local total=$1 width=$((UI_W - 6)) seg bytes cells sum=0 big=0 bigb=0 i=0 list=""
  shift
  [ "$total" -gt 0 ] || return 0
  for seg in "$@"; do
    i=$((i + 1))
    bytes=${seg#*:}
    bytes=${bytes%%:*}
    cells=0
    if [ "$bytes" -gt 0 ]; then
      cells=$(((bytes * width + total / 2) / total))
      [ "$cells" -lt 1 ] && cells=1
    fi
    [ "$bytes" -gt "$bigb" ] && bigb=$bytes big=$i
    sum=$((sum + cells))
    list="$list $cells"
  done
  local bar="" legend="" kind label
  i=0
  for seg in "$@"; do
    i=$((i + 1))
    # shellcheck disable=SC2086 # $list is a space-separated list by design
    cells=$(printf '%s\n' $list | sed -n "${i}p")
    [ "$i" = "$big" ] && cells=$((cells + width - sum))
    [ "$cells" -gt 0 ] || continue
    kind=${seg%%:*}
    label=${seg#*:}
    label=${label#*:}
    _strip_style "$kind"
    bar="$bar$UI_C$(_rep "$UI_S" "$cells")$C_RESET"
    legend="$legend$UI_C$UI_S$C_RESET $label    "
  done
  printf '\n   %s%s%s%s%s%s%s\n' "$C_FAINT" "$G_SL" "$C_RESET" "$bar" "$C_FAINT" "$G_SR" "$C_RESET"
  printf '    %s\n' "$legend"
}


# ---------------------------------------------------------------------------
# Input. Menus take arrows/j/k, digits, Enter, b (back), q (quit) on a TTY and
# fall back to line input when stdin is not a terminal (tests, pipes).
# Return codes: 0 chosen, 2 back, 3 quit.
# ---------------------------------------------------------------------------

ui_interactive() { [ -t 0 ] && [ -t 1 ]; }

_ui_read_key() {
  local k rest
  IFS= read -rsn1 k || {
    UI_KEY=eof
    return
  }
  if [ "$k" = "$ESC" ]; then
    IFS= read -rsn2 -t 1 rest
    case "$rest" in
      '[A' | 'OA') UI_KEY=up ;;
      '[B' | 'OB') UI_KEY=down ;;
      *) UI_KEY=esc ;;
    esac
  elif [ -z "$k" ]; then
    UI_KEY=enter
  else
    UI_KEY=$k
  fi
}

ui_hint() { printf '   %s%s%s\n' "$C_FAINT" "$*" "$C_RESET"; }

# In line mode the terminal does not echo piped answers; echo them so a
# transcript reads like the conversation it was.
_ui_echo() { [ -t 0 ] || printf '%s\n' "$1"; }

# Clear-line escape, only when redrawing a live menu.
_ui_clr() {
  UI_CLR=""
  ui_interactive && UI_CLR="${ESC}[2K"
}

# ui_select PROMPT DEFAULT "LABEL|VALUE|DESCRIPTION|BADGE" ...
# Sets UI_CHOICE (1-based).
ui_select() {
  local prompt=$1 default=$2
  shift 2
  local count=$# cur=$default
  _ui_clr
  printf '\n   %s%s%s\n\n' "$C_BOLD" "$prompt" "$C_RESET"

  if ! ui_interactive; then
    _ui_select_render "$cur" "$@"
    local ans
    while :; do
      printf '   %schoice%s [%s] ' "$C_DIM" "$C_RESET" "$default"
      IFS= read -r ans || return 3
      _ui_echo "$ans"
      case "$ans" in
        '') UI_CHOICE=$default && return 0 ;;
        b | B) return 2 ;;
        q | Q) return 3 ;;
        *[!0-9]*) ;;
        *) if [ "$ans" -ge 1 ] && [ "$ans" -le "$count" ]; then UI_CHOICE=$ans && return 0; fi ;;
      esac
      ui_hint "enter 1-$count, b to go back, q to quit"
    done
  fi

  local lines
  printf '%s' "${ESC}[?25l"
  _ui_select_render "$cur" "$@"
  lines=$UI_LINES
  ui_hint "↑↓ move · 1-$count pick · enter select · b back · q quit" | _ui_ascii_hint
  lines=$((lines + 1))
  while :; do
    _ui_read_key
    case "$UI_KEY" in
      up | k) [ "$cur" -gt 1 ] && cur=$((cur - 1)) ;;
      down | j) [ "$cur" -lt "$count" ] && cur=$((cur + 1)) ;;
      enter)
        UI_CHOICE=$cur
        printf '%s' "${ESC}[?25h"
        return 0
        ;;
      b | B | esc)
        printf '%s' "${ESC}[?25h"
        return 2
        ;;
      q | Q | eof)
        printf '%s' "${ESC}[?25h"
        return 3
        ;;
      [1-9]) [ "$UI_KEY" -le "$count" ] && cur=$UI_KEY ;;
    esac
    printf '%s' "${ESC}[${lines}A"
    _ui_select_render "$cur" "$@"
    ui_hint "↑↓ move · 1-$count pick · enter select · b back · q quit" | _ui_ascii_hint
  done
}

# ASCII stand-ins for the hint-line glyphs.
_ui_ascii_hint() {
  if [ "$UI_UNICODE" = 1 ]; then cat; else sed 's/↑↓/up\/down/; s/⏎/>/; s/·/-/g'; fi
}

# ui_next LABEL — Enter continues, b goes back, q quits. 0/2/3.
ui_next() {
  local ans
  printf '\n   %s⏎%s %s  %s· b back · q quit%s ' "$C_ACCENT" "$C_RESET" "$1" "$C_FAINT" "$C_RESET" | _ui_ascii_hint
  IFS= read -r ans || return 3
  _ui_echo "$ans"
  case "$ans" in
    b | B) return 2 ;;
    q | Q) return 3 ;;
  esac
  return 0
}

_ui_select_render() {
  local cur=$1 i=0 opt label value desc badge ptr
  shift
  UI_LINES=0
  for opt in "$@"; do
    i=$((i + 1))
    label=$(printf '%s' "$opt" | cut -d'|' -f1)
    value=$(printf '%s' "$opt" | cut -d'|' -f2)
    desc=$(printf '%s' "$opt" | cut -d'|' -f3)
    badge=$(printf '%s' "$opt" | cut -d'|' -f4)
    if [ "$i" = "$cur" ]; then
      ptr="$C_ACCENT$C_BOLD$G_POINT$C_RESET"
      printf '%s   %s %s%d%s  %s%-16s%s %s%-10s%s' "$UI_CLR" "$ptr" "$C_ACCENT" "$i" "$C_RESET" "$C_BOLD$C_INK" "$label" "$C_RESET" "$C_BOLD" "$value" "$C_RESET"
    else
      printf '%s     %s%d%s  %-16s %-10s' "$UI_CLR" "$C_DIM" "$i" "$C_RESET" "$label" "$value"
    fi
    [ -n "$badge" ] && printf ' %s%s%s' "$C_PASS" "$badge" "$C_RESET"
    printf '\n'
    UI_LINES=$((UI_LINES + 1))
    if [ -n "$desc" ]; then
      printf '%s        %s%s%s\n' "$UI_CLR" "$C_DIM" "$desc" "$C_RESET"
      UI_LINES=$((UI_LINES + 1))
    fi
  done
  printf '%s\n' "$UI_CLR"
  UI_LINES=$((UI_LINES + 1))
}

# ui_multiselect PROMPT "LABEL|DESC|on" ... — sets UI_PICKED to "1 3 4".
ui_multiselect() {
  local prompt=$1
  shift
  local count=$# i=0 opt
  local sel=""
  _ui_clr
  for opt in "$@"; do
    i=$((i + 1))
    [ "$(printf '%s' "$opt" | cut -d'|' -f3)" = on ] && sel="$sel $i"
  done
  printf '\n   %s%s%s\n\n' "$C_BOLD" "$prompt" "$C_RESET"

  if ! ui_interactive; then
    _ui_multi_render 0 "$sel" "$@"
    local ans
    printf '   %snumbers separated by spaces, enter for the marked set, q to quit%s\n   %schoice%s ' "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
    IFS= read -r ans || return 3
    _ui_echo "$ans"
    case "$ans" in
      q | Q) return 3 ;;
      b | B) return 2 ;;
      '') UI_PICKED=$sel ;;
      *) UI_PICKED=$(printf '%s' "$ans" | tr ',' ' ') ;;
    esac
    return 0
  fi

  local cur=1 lines
  printf '%s' "${ESC}[?25l"
  _ui_multi_render "$cur" "$sel" "$@"
  lines=$((UI_LINES + 1))
  ui_hint "↑↓ move · space toggle · enter confirm · b back · q quit" | _ui_ascii_hint
  while :; do
    _ui_read_key
    case "$UI_KEY" in
      up | k) [ "$cur" -gt 1 ] && cur=$((cur - 1)) ;;
      down | j) [ "$cur" -lt "$count" ] && cur=$((cur + 1)) ;;
      ' ' | x)
        case " $sel " in
          *" $cur "*) sel=$(printf '%s' " $sel " | sed "s/ $cur / /") ;;
          *) sel="$sel $cur" ;;
        esac
        ;;
      enter)
        UI_PICKED=$sel
        printf '%s' "${ESC}[?25h"
        return 0
        ;;
      b | B | esc)
        printf '%s' "${ESC}[?25h"
        return 2
        ;;
      q | Q | eof)
        printf '%s' "${ESC}[?25h"
        return 3
        ;;
    esac
    printf '%s' "${ESC}[${lines}A"
    _ui_multi_render "$cur" "$sel" "$@"
    ui_hint "↑↓ move · space toggle · enter confirm · b back · q quit" | _ui_ascii_hint
  done
}

_ui_multi_render() {
  local cur=$1 sel=$2 i=0 opt label desc box ptr
  shift 2
  UI_LINES=0
  for opt in "$@"; do
    i=$((i + 1))
    label=$(printf '%s' "$opt" | cut -d'|' -f1)
    desc=$(printf '%s' "$opt" | cut -d'|' -f2)
    case " $sel " in *" $i "*) box="$C_PASS$G_ON$C_RESET" ;; *) box="$C_FAINT$G_OFF$C_RESET" ;; esac
    ptr=" "
    [ "$i" = "$cur" ] && ptr="$C_ACCENT$C_BOLD$G_POINT$C_RESET"
    printf '%s   %s %s %s%d%s  %-14s %s%s%s\n' "$UI_CLR" "$ptr" "$box" "$C_DIM" "$i" "$C_RESET" "$label" "$C_DIM" "$desc" "$C_RESET"
    UI_LINES=$((UI_LINES + 1))
  done
  printf '%s\n' "$UI_CLR"
  UI_LINES=$((UI_LINES + 1))
}

# ui_ask VAR PROMPT DEFAULT [VALIDATOR] — validator prints its reason and
# returns non-zero to re-ask.
ui_ask() {
  # Locals are __-prefixed: the caller's variable name is assigned by eval,
  # and bash's dynamic scoping would otherwise let a local shadow it.
  local __var=$1 __prompt=$2 __default=$3 __validator=${4:-} __ans
  while :; do
    if [ -n "$__default" ]; then
      printf '   %s %s[%s]%s ' "$__prompt" "$C_DIM" "$__default" "$C_RESET"
    else
      printf '   %s ' "$__prompt"
    fi
    IFS= read -r __ans || return 3
    _ui_echo "$__ans"
    [ -z "$__ans" ] && __ans=$__default
    if [ -n "$__validator" ] && ! "$__validator" "$__ans"; then
      continue
    fi
    eval "$__var=\$__ans"
    return 0
  done
}

# ui_yesno PROMPT DEFAULT(y|n) — 0 yes, 1 no, 3 quit.
ui_yesno() {
  local prompt=$1 default=$2 ans hint="y/N"
  [ "$default" = y ] && hint="Y/n"
  while :; do
    printf '   %s %s[%s]%s ' "$prompt" "$C_DIM" "$hint" "$C_RESET"
    IFS= read -r ans || return 3
    _ui_echo "$ans"
    [ -z "$ans" ] && ans=$default
    case "$ans" in
      y | Y | yes | YES | Yes) return 0 ;;
      n | N | no | NO | No) return 1 ;;
      q | Q) return 3 ;;
    esac
    ui_hint "answer y or n"
  done
}

# ui_confirm_word WORD PROMPT — the gate before anything destructive. Only the
# exact word proceeds; Enter alone never does. 0 confirmed, 1 declined.
ui_confirm_word() {
  local word=$1 prompt=$2 ans
  while :; do
    printf '\n   %s  %sType %s%s%s%s to continue, or n to stop:%s ' "$prompt" "$C_DIM" "$C_RESET$C_BOLD$C_ACCENT" "$word" "$C_RESET" "$C_DIM" "$C_RESET"
    IFS= read -r ans || return 1
    _ui_echo "$ans"
    [ "$ans" = "$word" ] && return 0
    case "$ans" in
      n | N | no | q | Q | b | B) return 1 ;;
    esac
    ui_hint "only the exact word \"$word\" continues"
  done
}

ui_pause() {
  ui_interactive || return 0
  printf '\n   %s%s%s ' "$C_DIM" "${1:-Press Enter to continue}" "$C_RESET"
  IFS= read -r _
}

# ui_spin LABEL CMD... — run CMD with a spinner; returns its exit code.
ui_spin() {
  local label=$1
  shift
  if ! ui_interactive || [ "$UI_DEPTH" = 0 ]; then
    "$@" >/dev/null 2>&1
    return
  fi
  "$@" >/dev/null 2>&1 &
  local pid=$! i=0 n=${#G_SPIN} frame
  while kill -0 "$pid" 2>/dev/null; do
    frame=${G_SPIN:$((i % n)):1}
    printf '\r   %s%s%s %s%s%s' "$C_ACCENT" "$frame" "$C_RESET" "$C_DIM" "$label" "$C_RESET"
    i=$((i + 1))
    sleep 0.08
  done
  wait "$pid"
  local rc=$?
  printf '\r%s' "${ESC}[2K"
  return "$rc"
}

ui_cursor_restore() { [ -t 1 ] && printf '%s' "${ESC}[?25h"; }
