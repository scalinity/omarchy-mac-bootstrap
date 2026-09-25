# shellcheck shell=bash
# Storage planning — pure arithmetic, no I/O. Mirrors the Asahi installer's
# own minimum-size calculation (asahi-installer src/main.py, action_resize)
# and adds a small drift margin. All values are bytes; GB means 10^9, as in
# the installer's psize/ssize.

GB=1000000000

# gb_floor BYTES / gb_ceil BYTES — whole GB.
gb_floor() { printf '%s' $(($1 / GB)); }
gb_ceil() { printf '%s' $((($1 + GB - 1) / GB)); }

# fmt_gb BYTES — "250 GB" for whole values, otherwise one decimal ("994.6 GB").
fmt_gb() {
  local b=$1 neg="" tenths
  if [ "$b" -lt 0 ]; then
    neg="-"
    b=$((-b))
  fi
  tenths=$(((b + GB / 20) / (GB / 10)))
  if [ $((tenths % 10)) = 0 ]; then
    printf '%s%s GB' "$neg" $((tenths / 10))
  else
    printf '%s%s.%s GB' "$neg" $((tenths / 10)) $((tenths % 10))
  fi
}

align_up() { printf '%s' $((($1 + $2 - 1) / $2 * $2)); }

# pct PART WHOLE — whole-number percentage, rounded.
pct() { printf '%s' $((($1 * 100 + $2 / 2) / $2)); }

# plan_compute D C F P E S
#   D disk size, C container size, F container free,
#   P diskutil MinimumSizePreferred (0 if unknown), E existing unpartitioned
#   space, S shared-data reservation.
# Pre-existing free space may not sit next to the space a resize frees, so it
# is only counted when it can hold the Linux install on its own.
# Sets PLAN_* globals; returns 1 when Linux cannot fit its minimum.
plan_compute() {
  PLAN_DISK=$1 PLAN_CONTAINER=$2 PLAN_FREE=$3 PLAN_PREF=${4:-0} PLAN_EXISTING=${5:-0} PLAN_SHARED=${6:-0}
  PLAN_USED=$((PLAN_CONTAINER - PLAN_FREE))
  PLAN_MACOS_RAW=$(align_up $((PLAN_USED + ASAHI_MIN_FREE_OS_BYTES)) "$ASAHI_PART_ALIGN")
  PLAN_MACOS_MIN=$PLAN_MACOS_RAW
  [ "$PLAN_PREF" -gt "$PLAN_MACOS_MIN" ] && PLAN_MACOS_MIN=$PLAN_PREF
  PLAN_OVERHEAD=$((PLAN_MACOS_MIN - PLAN_MACOS_RAW))
  PLAN_MACOS_FLOOR=$((PLAN_MACOS_MIN + PLAN_DRIFT_MARGIN_BYTES))
  local room=$((PLAN_CONTAINER - PLAN_MACOS_FLOOR - PLAN_SHARED))
  local room_free=$((PLAN_EXISTING - PLAN_SHARED))
  [ "$room_free" -gt "$room" ] && room=$room_free
  [ "$room" -lt 0 ] && room=0
  PLAN_LINUX_MAX=$(($(gb_floor "$room") * GB))
  PLAN_LINUX_MIN=$((OMARCHY_LINUX_MIN_GB * GB))
  PLAN_LINUX_REC=$((OMARCHY_LINUX_RECOMMENDED_GB * GB))
  PLAN_RESERVE=$((ASAHI_MIN_FREE_OS_BYTES + PLAN_OVERHEAD + PLAN_DRIFT_MARGIN_BYTES))
  PLAN_OVERHEAD_WARN=0
  [ "$PLAN_OVERHEAD" -gt "$ASAHI_OVERHEAD_WARN_BYTES" ] && PLAN_OVERHEAD_WARN=1
  PLAN_SHORTFALL=0
  if [ "$PLAN_LINUX_MAX" -lt "$PLAN_LINUX_MIN" ]; then
    PLAN_SHORTFALL=$((PLAN_LINUX_MIN - PLAN_LINUX_MAX))
    return 1
  fi
  return 0
}

# round_nice BYTES — nearest 25 GB at or above 100 GB, nearest 10 GB below.
round_nice() {
  local g=$((($1 + GB / 2) / GB))
  if [ "$g" -ge 100 ]; then
    g=$((((g + 12) / 25) * 25))
  else
    g=$((((g + 5) / 10) * 10))
  fi
  printf '%s' $((g * GB))
}

# plan_presets — after plan_compute. Sets PRESETS to lines
# "key|label|bytes|description" and PRESET_DEFAULT to the recommended key.
plan_presets() {
  local max=$PLAN_LINUX_MAX min=$PLAN_LINUX_MIN keep=$((PLAN_LINUX_MAX * 9 / 10))
  local minimal balanced heavy
  PRESETS=""
  PRESET_DEFAULT=""
  [ "$max" -lt "$min" ] && return 1

  minimal=$PLAN_LINUX_REC
  [ "$minimal" -gt "$max" ] && minimal=$min
  balanced=$(round_nice $((PLAN_DISK / 4)))
  heavy=$(round_nice $((PLAN_DISK / 2)))

  if [ "$minimal" -lt "$keep" ]; then
    PRESETS="${PRESETS}minimal|Minimal|$minimal|Enough for Omarchy, development tools, and moderate use.
"
    PRESET_DEFAULT=minimal
  fi
  if [ "$balanced" -gt "$minimal" ] && [ "$balanced" -ge "$min" ] && [ "$balanced" -lt "$keep" ]; then
    PRESETS="${PRESETS}balanced|Balanced|$balanced|Plenty for projects, containers, packages, and development.
"
    PRESET_DEFAULT=balanced
  fi
  if [ "$heavy" -gt "$balanced" ] && [ "$heavy" -ge "$min" ] && [ "$heavy" -lt "$keep" ]; then
    PRESETS="${PRESETS}heavy|Linux-heavy|$heavy|Treat this primarily as a Linux laptop while keeping macOS.
"
  fi
  PRESETS="${PRESETS}max|Maximum safe|$max|As much as macOS can give while keeping its update room.
"
  [ -n "$PRESET_DEFAULT" ] || PRESET_DEFAULT=max
  return 0
}

# parse_size INPUT — prints bytes. Accepts 250, 250G, 250GB, 250.5 GB, 1TB,
# 1.5T, 30% (of the internal disk), max. Prints an error and returns 1 otherwise.
parse_size() {
  local in unit int frac tenths
  in=$(printf '%s' "$1" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
  case "$in" in
    MAX)
      printf '%s' "$PLAN_LINUX_MAX"
      return 0
      ;;
    '')
      printf '%s' "enter a size such as 250GB or 30%"
      return 1
      ;;
  esac
  case "$in" in
    *%) unit=PCT in=${in%\%} ;;
    *TB) unit=TB in=${in%TB} ;;
    *T) unit=TB in=${in%T} ;;
    *GB) unit=GB in=${in%GB} ;;
    *G) unit=GB in=${in%G} ;;
    *[!0-9.]*)
      printf '%s' "'$1' is not a size; use GB, TB, or %"
      return 1
      ;;
    *) unit=GB ;;
  esac
  case "$in" in
    '' | . | *.*.* | *[!0-9.]*)
      printf '%s' "'$1' is not a number"
      return 1
      ;;
  esac
  int=${in%%.*}
  frac=""
  [ "$in" != "$int" ] && frac=${in#*.}
  int=${int:-0}
  frac=${frac}0
  frac=${frac:0:1}
  int=$((10#$int))
  tenths=$((int * 10 + frac))
  case "$unit" in
    GB) printf '%s' $((tenths * GB / 10)) ;;
    TB) printf '%s' $((tenths * 1000 * GB / 10)) ;;
    PCT)
      if [ "$tenths" -gt 1000 ]; then
        printf '%s' "a percentage cannot exceed 100%"
        return 1
      fi
      printf '%s' $((PLAN_DISK * tenths / 1000))
      ;;
  esac
}

# plan_validate BYTES — prints "ok", "warn|reason" or "error|reason".
plan_validate() {
  local b=$1
  if [ "$b" -lt "$PLAN_LINUX_MIN" ]; then
    printf 'error|%s is below the %s GB Omarchy Mac needs.' "$(fmt_gb "$b")" "$OMARCHY_LINUX_MIN_GB"
  elif [ "$b" -gt "$PLAN_LINUX_MAX" ]; then
    printf 'error|%s leaves macOS too little room: it must keep %s used + 38 GB for updates%s + 5 GB margin, so Linux can have at most %s.' \
      "$(fmt_gb "$b")" "$(fmt_gb "$PLAN_USED")" \
      "$([ "$PLAN_OVERHEAD" -gt 0 ] && printf ' + %s snapshot overhead' "$(fmt_gb "$PLAN_OVERHEAD")")" \
      "$(fmt_gb "$PLAN_LINUX_MAX")"
  elif [ "$b" -lt "$PLAN_LINUX_REC" ]; then
    printf 'warn|%s works, but Omarchy Mac recommends %s GB.' "$(fmt_gb "$b")" "$OMARCHY_LINUX_RECOMMENDED_GB"
  else
    printf 'ok'
  fi
}

# plan_layout BYTES — the handoff values and estimated layout for a Linux
# allocation (the installer's "New OS size", which includes stub and EFI).
plan_layout() {
  local a=$1
  PLAN_LINUX=$a
  if [ $((a + PLAN_SHARED)) -le "$PLAN_EXISTING" ]; then
    PLAN_MODE=free
    PLAN_MACOS_NEW=$PLAN_CONTAINER
    PLAN_MACOS_NEW_GB=""
  else
    PLAN_MODE=resize
    PLAN_MACOS_NEW_GB=$(gb_ceil $((PLAN_CONTAINER - a - PLAN_SHARED)))
    PLAN_MACOS_NEW=$((PLAN_MACOS_NEW_GB * GB))
  fi
  PLAN_FREED=$((PLAN_CONTAINER - PLAN_MACOS_NEW))
  # "max" takes the whole free region. The region a resize frees can merge
  # with unpartitioned space already next to the container, so "max" is used
  # only when there is none; otherwise the reviewed size is typed, and the
  # rest stays free (shared plan, or pre-existing space).
  if [ "$PLAN_MODE" = resize ] && [ "$PLAN_SHARED" = 0 ] && [ "$PLAN_EXISTING" = 0 ]; then
    PLAN_OS_SIZE_ANSWER="max"
    PLAN_LINUX_ACTUAL=$PLAN_FREED
  else
    PLAN_OS_SIZE_ANSWER="$(gb_floor "$a")GB"
    PLAN_LINUX_ACTUAL=$a
  fi
  PLAN_BOOT=$((ASAHI_STUB_BYTES + ASAHI_EFI_BYTES))
  PLAN_ROOT=$((PLAN_LINUX_ACTUAL - PLAN_BOOT))
  PLAN_MACOS_FREE_AFTER=$((PLAN_MACOS_NEW - PLAN_USED))
}
