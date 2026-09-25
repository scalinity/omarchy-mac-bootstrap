# shellcheck shell=bash
# Storage geometry and planning — pure arithmetic over byte extents, no I/O.
#
# The internal disk is modelled as partitions (offset, size, GPT GUID,
# content, role) in on-disk order and the gaps between them. A plan names one
# gap for Linux and, when Shared storage is on, the Shared reservation after
# it in that same gap. Separate gaps are never added together: the installer
# installs into one gap at a time. Everything is bytes; GB (10^9) is display.
#
# Installer behaviour modelled (asahi-installer v0.9.2, see lib/sources.sh):
#   resize   the typed new macOS size is aligned UP to PART_ALIGN; minimum
#            max(align_up(used + MIN_FREE_OS), MinimumSizePreferred)
#   install  one gap at a time; "New OS size" is aligned DOWN to PART_ALIGN;
#            stub, EFI and root are created in that order, each right after
#            the partition before it
# Answers are typed as exact MiB multiples, which neither alignment changes.
# macOS may also start a new partition on the next MiB boundary, so the
# planner assumes it does, and keeps PLAN_PLACEMENT_SLACK_BYTES spare.

GB=1000000000
MIB=1048576

# _uint VALUE — a canonical non-negative integer: digits only, no leading
# zero, at most 16 digits. Checked before any value reaches $(( )), where a
# leading zero means octal and text means an evaluated expression.
_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    0) return 0 ;;
    0*) return 1 ;;
  esac
  [ "${#1}" -le 16 ]
}

align_up() { printf '%s' $((($1 + $2 - 1) / $2 * $2)); }
align_down() { printf '%s' $(($1 / $2 * $2)); }
gb_floor() { printf '%s' $(($1 / GB)); }

# fmt_gb BYTES — "250 GB" for whole values, otherwise one decimal ("994.6 GB");
# amounts under 0.1 GB in MB ("1.2 MB"), so a small remainder is not "0 GB".
fmt_gb() {
  local b=$1 neg="" tenths
  if [ "$b" -lt 0 ]; then
    neg="-"
    b=$((-b))
  fi
  if [ "$b" -gt 0 ] && [ "$b" -lt $((GB / 10)) ]; then
    tenths=$(((b + 50000) / 100000))
    printf '%s%s.%s MB' "$neg" $((tenths / 10)) $((tenths % 10))
    return 0
  fi
  tenths=$(((b + GB / 20) / (GB / 10)))
  if [ $((tenths % 10)) = 0 ]; then
    printf '%s%s GB' "$neg" $((tenths / 10))
  else
    printf '%s%s.%s GB' "$neg" $((tenths / 10)) $((tenths % 10))
  fi
}

# fmt_bytes BYTES — exact, grouped: "150,000,184,320 bytes".
fmt_bytes() {
  local s=$1 out=""
  while [ "${#s}" -gt 3 ]; do
    out=",${s:$((${#s} - 3))}$out"
    s=${s:0:$((${#s} - 3))}
  done
  printf '%s%s bytes' "$s" "$out"
}

# mib_answer BYTES — an exact answer for the installer ("238420MiB").
mib_answer() { printf '%sMiB' $(($1 / MIB)); }

# pct PART WHOLE — whole-number percentage, rounded.
pct() { printf '%s' $((($1 * 100 + $2 / 2) / $2)); }

# ---------------------------------------------------------------------------
# Checked size input. Deterministic: leading zeros, signs, exponents, extra
# dots, too many digits and anything larger than the disk are refused before
# any arithmetic.
# ---------------------------------------------------------------------------

# parse_size INPUT DISK_BYTES [MAX_BYTES] — prints bytes, or prints the reason
# and returns 1. Accepts 250, 250GB, 250 GB, 250.5GB, 1TB, 0.5T, 30% (of the
# disk), and max (MAX_BYTES). GB/TB take up to three decimals, % one.
parse_size() {
  local in=$1 disk=$2 max=${3:-} re unit int frac digits bytes
  # Trim surrounding blanks; blanks are allowed only between number and unit.
  in=${in#"${in%%[![:space:]]*}"}
  in=${in%"${in##*[![:space:]]}"}
  in=$(printf '%s' "$in" | tr '[:lower:]' '[:upper:]')
  case "$in" in
    '')
      printf '%s' "enter a size such as 250GB or 30%"
      return 1
      ;;
    MAX)
      if [ -n "$max" ]; then printf '%s' "$max"; return 0; fi
      printf '%s' "max is not available here"
      return 1
      ;;
  esac
  re='^([0-9]+)(\.([0-9]+))?[[:space:]]*(TB|T|GB|G|%)?$'
  if ! [[ $in =~ $re ]]; then
    printf '%s' "'$1' is not a size; use a number with GB, TB, or %"
    return 1
  fi
  int=${BASH_REMATCH[1]} frac=${BASH_REMATCH[3]} unit=${BASH_REMATCH[4]}
  case "$unit" in '' | G | GB) unit=GB ;; T | TB) unit=TB ;; esac
  case "$int" in
    0?*)
      # Refused rather than read as decimal or octal: 010 is ambiguous.
      local plain=${int#"${int%%[!0]*}"}
      printf '%s' "'$1' has a leading zero; write ${plain:-0}${frac:+.$frac}$([ "$unit" = % ] && printf '%%' || printf '%s' "$unit") if that is what you mean"
      return 1
      ;;
  esac
  case "$unit" in GB) digits=7 ;; TB) digits=4 ;; %) digits=3 ;; esac
  if [ "${#int}" -gt "$digits" ]; then
    printf '%s' "'$1' is too large"
    return 1
  fi
  if [ "$unit" = % ] && [ "${#frac}" -gt 1 ] || [ "${#frac}" -gt 3 ]; then
    printf '%s' "'$1' has more decimals than a size needs"
    return 1
  fi
  case "$unit" in
    GB)
      frac=${frac}000
      bytes=$((10#$int * GB + 10#${frac:0:3} * 1000000))
      ;;
    TB)
      frac=${frac}000
      bytes=$((10#$int * 1000 * GB + 10#${frac:0:3} * GB))
      ;;
    %)
      frac=${frac:-0}
      if [ $((10#$int * 10 + 10#$frac)) -gt 1000 ]; then
        printf '%s' "a percentage cannot exceed 100%"
        return 1
      fi
      bytes=$((disk * (10#$int * 10 + 10#$frac) / 1000))
      ;;
  esac
  if [ "$bytes" -le 0 ]; then
    printf '%s' "'$1' is zero"
    return 1
  fi
  if [ "$bytes" -ge "$disk" ]; then
    printf '%s' "'$1' is not smaller than the whole internal disk ($(fmt_gb "$disk"))"
    return 1
  fi
  printf '%s' "$bytes"
}

# ---------------------------------------------------------------------------
# Geometry. Records are "offset|size|uuid|content|id|role", one per line.
# ---------------------------------------------------------------------------

geo_reset() {
  GEO_PARTS="" GEO_ERR="" GEO_OK=0
}

# geo_add OFFSET SIZE UUID CONTENT ID ROLE — one partition. A value that is
# not a canonical integer marks the geometry unknown rather than guessed.
geo_add() {
  if ! _uint "$1" || ! _uint "$2"; then
    GEO_ERR="${GEO_ERR:-partition ${5:-?} has no usable offset or size}"
    return 1
  fi
  case "$3$4$5$6" in *'|'* | *"
"*)
    GEO_ERR="${GEO_ERR:-partition ${5:-?} has an unreadable field}"
    return 1
    ;;
  esac
  GEO_PARTS="$GEO_PARTS$1|$2|$3|$4|$5|$6
"
}

# _geo_walk LIST DISK BLOCK — the one geometry check. Sorts LIST by offset
# and walks the GPT's usable range, setting W_PARTS (sorted), W_ALLGAPS and
# W_GAPS ("start|size|pred_uuid|succ_uuid"; W_GAPS only those the installer
# would list), W_SUM (partitions + gaps + GPT structures, which must equal
# DISK), and W_OK / W_ERR. Refuses misaligned, overlapping, out-of-range,
# empty or duplicate-GUID partitions: a layout this cannot account for byte
# for byte is not planned on.
_geo_walk() {
  local list=$1 disk=$2 block=$3 off size uuid content id role prev_end prev_uuid="" seen=" " end
  W_OK=0 W_ERR="" W_PARTS="" W_ALLGAPS="" W_GAPS="" W_SUM=0
  if ! _uint "$disk" || ! _uint "$block"; then
    W_ERR="the disk size or block size is unknown"
    return 1
  fi
  case "$block" in 512 | 4096) ;; *)
    W_ERR="unsupported logical block size $block"
    return 1
    ;;
  esac
  # GPT: protective MBR + header + a 16 KiB entry array at the front; the
  # backup header and array at the end.
  W_START=$((2 * block + ASAHI_GPT_ENTRIES_BYTES))
  W_END=$((disk - block - ASAHI_GPT_ENTRIES_BYTES))
  W_PARTS=$(printf '%s' "$list" | sed '/^$/d' | sort -t'|' -k1,1n)
  prev_end=$W_START
  W_SUM=$((W_START + disk - W_END))
  while IFS='|' read -r off size uuid content id role; do
    [ -n "$off" ] || continue
    end=$((off + size))
    if [ "$size" -le 0 ] || [ $((off % block)) != 0 ] || [ $((size % block)) != 0 ]; then
      W_ERR="partition ${id:-$uuid} is not aligned to the ${block}-byte block size"
      return 1
    fi
    if [ "$off" -lt "$W_START" ] || [ "$end" -gt "$W_END" ]; then
      W_ERR="partition ${id:-$uuid} lies outside the disk's usable range"
      return 1
    fi
    if [ "$off" -lt "$prev_end" ]; then
      W_ERR="partition ${id:-$uuid} overlaps the partition before it"
      return 1
    fi
    case "$uuid" in
      '') ;;
      *)
        case "$seen" in *" $uuid "*)
          W_ERR="GUID $uuid appears twice"
          return 1
          ;;
        esac
        seen="$seen$uuid "
        ;;
    esac
    if [ "$off" -gt "$prev_end" ]; then
      W_ALLGAPS="$W_ALLGAPS$prev_end|$((off - prev_end))|$prev_uuid|$uuid
"
      [ $((off - prev_end)) -gt "$ASAHI_GAP_MIN_BYTES" ] && W_GAPS="$W_GAPS$prev_end|$((off - prev_end))|$prev_uuid|$uuid
"
      W_SUM=$((W_SUM + off - prev_end))
    fi
    W_SUM=$((W_SUM + size))
    prev_end=$end
    prev_uuid=$uuid
  done <<EOF
$W_PARTS
EOF
  if [ "$W_END" -gt "$prev_end" ]; then
    W_ALLGAPS="$W_ALLGAPS$prev_end|$((W_END - prev_end))|$prev_uuid|
"
    [ $((W_END - prev_end)) -gt "$ASAHI_GAP_MIN_BYTES" ] && W_GAPS="$W_GAPS$prev_end|$((W_END - prev_end))|$prev_uuid|
"
    W_SUM=$((W_SUM + W_END - prev_end))
  fi
  if [ "$W_SUM" != "$disk" ]; then
    W_ERR="partitions and gaps do not add up to the disk ($W_SUM of $disk bytes)"
    return 1
  fi
  W_OK=1
}

# geo_finalize DISK BLOCK — checks the recorded partitions and derives the
# gaps. GEO_OK=1 only when every byte of the disk is accounted for.
geo_finalize() {
  GEO_DISK_SIZE=$1 GEO_BLOCK=$2 GEO_OK=0
  [ -z "$GEO_ERR" ] || return 1
  if ! _geo_walk "$GEO_PARTS" "$1" "$2"; then
    GEO_ERR=$W_ERR
    return 1
  fi
  GEO_PARTS=$W_PARTS GEO_ALLGAPS=$W_ALLGAPS GEO_GAPS=$W_GAPS
  GEO_USABLE_START=$W_START GEO_USABLE_END=$W_END
  GEO_OK=1
}

# geo_part UUID — sets GP_OFFSET GP_SIZE GP_END GP_CONTENT GP_ID GP_ROLE.
geo_part() {
  local off size uuid content id role
  while IFS='|' read -r off size uuid content id role; do
    if [ -n "$1" ] && [ "$uuid" = "$1" ]; then
      GP_OFFSET=$off GP_SIZE=$size GP_END=$((off + size)) GP_CONTENT=$content GP_ID=$id GP_ROLE=$role
      return 0
    fi
  done <<EOF
$GEO_PARTS
EOF
  return 1
}

# geo_role_uuids ROLE — the GUIDs with that role, in disk order, one per line.
geo_role_uuids() {
  printf '%s' "$GEO_PARTS" | awk -F'|' -v r="$1" '$6 == r {print $3}'
}

# geo_next UUID — the partition after UUID in disk order: sets GN_* like
# geo_part; returns 1 when UUID is the last partition.
geo_next() {
  local off size uuid content id role hit=0
  while IFS='|' read -r off size uuid content id role; do
    [ -n "$off" ] || continue
    if [ "$hit" = 1 ]; then
      GN_OFFSET=$off GN_SIZE=$size GN_END=$((off + size)) GN_UUID=$uuid GN_CONTENT=$content GN_ID=$id GN_ROLE=$role
      return 0
    fi
    [ "$uuid" = "$1" ] && hit=1
  done <<EOF
$GEO_PARTS
EOF
  return 1
}

# geo_gap_after UUID — the gap (any size) right after UUID: GG_START GG_SIZE
# GG_END GG_SUCC. GG_SIZE=0 when the next partition follows directly.
geo_gap_after() {
  local start size pred succ
  GG_START=0 GG_SIZE=0 GG_END=0 GG_SUCC=""
  while IFS='|' read -r start size pred succ; do
    if [ -n "$start" ] && [ "$pred" = "$1" ]; then
      GG_START=$start GG_SIZE=$size GG_END=$((start + size)) GG_SUCC=$succ
      return 0
    fi
  done <<EOF
$GEO_ALLGAPS
EOF
  return 1
}

# geo_canon — the layout as identity: offset|size|uuid|content per partition.
# Device identifiers are left out: macOS may renumber them.
geo_canon() { printf '%s' "$GEO_PARTS" | cut -d'|' -f1-4; }

# ---------------------------------------------------------------------------
# Planning
# ---------------------------------------------------------------------------

# plan_init MACOS_UUID APFS_SIZE APFS_FREE PREFERRED — the facts every plan
# shares, from a finalized geometry and the survey. PREFERRED is diskutil's
# MinimumSizePreferred, empty when the limits query did not answer. Sets
# PLAN_TOPO_ERR when the macOS container cannot be planned around.
plan_init() {
  local uuid=$1 apfs=$2 free=$3 pref=$4
  PLAN_TOPO_ERR="" PLAN_RESIZE_OK=0 PLAN_RESIZE_WHY=""
  PLAN_DISK=${GEO_DISK_SIZE:-0}
  PLAN_LINUX_MIN=$(( (OMARCHY_ROOT_MIN_BYTES + ASAHI_STUB_BYTES + ASAHI_EFI_BYTES + GB - 1) / GB * GB ))
  PLAN_LINUX_REC=$((OMARCHY_LINUX_RECOMMENDED_GB * GB))
  PLAN_BOOT=$((ASAHI_STUB_BYTES + ASAHI_EFI_BYTES))
  PLAN_USED=0 PLAN_OVERHEAD=0 PLAN_OVERHEAD_WARN=0 PLAN_LIMITS_KNOWN=0
  PLAN_MACOS_RAW=0 PLAN_MACOS_MIN=0 PLAN_MACOS_FLOOR=0 PLAN_RESERVE=0
  PLAN_C0=0 PLAN_C=0 PLAN_RZ_END=0 PLAN_RZ_SUCC="" PLAN_MACOS_UUID=$uuid
  if [ "$GEO_OK" != 1 ]; then
    PLAN_TOPO_ERR="the partition layout could not be read completely (${GEO_ERR:-unknown})"
    return 1
  fi
  if ! geo_part "$uuid"; then
    PLAN_TOPO_ERR="the macOS container's partition was not found on the disk"
    return 1
  fi
  PLAN_C0=$GP_OFFSET PLAN_C=$GP_SIZE
  if ! _uint "$apfs" || ! _uint "$free" || [ "$free" -gt "$apfs" ]; then
    PLAN_TOPO_ERR="the APFS container did not report its size and free space"
    return 1
  fi
  # One physical store: the container is exactly its partition.
  if [ "$apfs" != "$PLAN_C" ]; then
    PLAN_TOPO_ERR="the APFS container ($apfs bytes) is not the size of its partition ($PLAN_C bytes)"
    return 1
  fi
  PLAN_USED=$((apfs - free))
  PLAN_MACOS_RAW=$(( (PLAN_USED + ASAHI_MIN_FREE_OS_BYTES + ASAHI_PART_ALIGN - 1) / ASAHI_PART_ALIGN * ASAHI_PART_ALIGN ))
  PLAN_MACOS_MIN=$PLAN_MACOS_RAW
  if _uint "$pref" && [ "$pref" -gt 0 ]; then
    PLAN_LIMITS_KNOWN=1
    [ "$pref" -gt "$PLAN_MACOS_MIN" ] && PLAN_MACOS_MIN=$pref
  fi
  PLAN_OVERHEAD=$((PLAN_MACOS_MIN - PLAN_MACOS_RAW))
  [ "$PLAN_OVERHEAD" -gt "$ASAHI_OVERHEAD_WARN_BYTES" ] && PLAN_OVERHEAD_WARN=1
  PLAN_MACOS_FLOOR=$(( (PLAN_MACOS_MIN + PLAN_DRIFT_MARGIN_BYTES + MIB - 1) / MIB * MIB ))
  PLAN_RESERVE=$((PLAN_MACOS_FLOOR - PLAN_USED))
  # A resize frees space from the container's end up to whatever follows it.
  if geo_next "$uuid"; then
    PLAN_RZ_END=$GN_OFFSET PLAN_RZ_SUCC=$GN_UUID
  else
    PLAN_RZ_END=$GEO_USABLE_END PLAN_RZ_SUCC=""
  fi
  if [ "$PLAN_LIMITS_KNOWN" != 1 ]; then
    PLAN_RESIZE_WHY="diskutil did not report the container's resize limits"
  elif [ "$PLAN_MACOS_FLOOR" -ge "$PLAN_C" ] || [ $((PLAN_C - PLAN_MACOS_FLOOR)) -le "$ASAHI_MIN_INSTALL_FREE_BYTES" ]; then
    PLAN_RESIZE_WHY="macOS has no space it can give up"
  else
    PLAN_RESIZE_OK=1
  fi
  return 0
}

# _fit G0 G1 SHARED — the largest Linux allocation (bytes, a MiB multiple)
# that fits in the one region [G0, G1), leaving SHARED bytes plus the
# placement slack after it. Assumes each new partition may start on the next
# MiB boundary. Prints 0 when nothing fits.
_fit() {
  local lo hi t
  lo=$(( ($1 + MIB - 1) / MIB * MIB ))
  hi=$(( $2 / MIB * MIB ))
  t=$((hi - lo))
  if [ "$3" -gt 0 ]; then
    t=$((t - ($3 + MIB - 1) / MIB * MIB - PLAN_PLACEMENT_SLACK_BYTES))
  fi
  [ "$t" -gt 0 ] || t=0
  printf '%s' "$t"
}

# plan_compute SHARED_BYTES — after plan_init. The best single option for this
# Shared size: an existing gap (no resize) or the region a resize frees.
# Sets PLAN_SHARED, PLAN_LINUX_MAX (whole GB, what presets and custom sizes
# may reach), PLAN_LINUX_MAX_BYTES, PLAN_SHORTFALL. Returns 1 when Linux
# cannot reach its minimum.
plan_compute() {
  local s=${1:-0} best=0 t start size pred succ
  PLAN_SHARED=$s
  _uint "$s" || s=0
  while IFS='|' read -r start size pred succ; do
    [ -n "$start" ] || continue
    t=$(_fit "$start" $((start + size)) "$s")
    [ "$t" -gt "$best" ] && best=$t
  done <<EOF
$GEO_GAPS
EOF
  if [ "$PLAN_RESIZE_OK" = 1 ]; then
    t=$(_fit $((PLAN_C0 + PLAN_MACOS_FLOOR)) "$PLAN_RZ_END" "$s")
    [ "$t" -gt "$best" ] && best=$t
  fi
  PLAN_LINUX_MAX_BYTES=$best
  PLAN_LINUX_MAX=$((best / GB * GB))
  PLAN_SHORTFALL=0
  if [ -n "$PLAN_TOPO_ERR" ]; then
    PLAN_SHORTFALL=$PLAN_LINUX_MIN
    return 1
  fi
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

# plan_validate BYTES — prints "ok", "warn|reason" or "error|reason".
plan_validate() {
  local b=$1
  if [ "$b" -lt "$PLAN_LINUX_MIN" ]; then
    printf 'error|%s is below the %s Linux needs: a %s root (Omarchy Mac minimum) plus %s of Asahi boot data.' \
      "$(fmt_gb "$b")" "$(fmt_gb "$PLAN_LINUX_MIN")" "$(fmt_gb "$OMARCHY_ROOT_MIN_BYTES")" "$(fmt_gb "$PLAN_BOOT")"
  elif [ "$b" -gt "$PLAN_LINUX_MAX" ]; then
    printf 'error|%s does not fit: macOS must keep %s used + %s for updates%s + %s margin%s, so Linux can have at most %s.' \
      "$(fmt_gb "$b")" "$(fmt_gb "$PLAN_USED")" "$(fmt_gb "$ASAHI_MIN_FREE_OS_BYTES")" \
      "$([ "$PLAN_OVERHEAD" -gt 0 ] && printf ' + %s snapshot overhead' "$(fmt_gb "$PLAN_OVERHEAD")")" \
      "$(fmt_gb "$PLAN_DRIFT_MARGIN_BYTES")" \
      "$([ "${PLAN_SHARED:-0}" -gt 0 ] && printf ', and %s stays reserved for Shared' "$(fmt_gb "$PLAN_SHARED")")" \
      "$(fmt_gb "$PLAN_LINUX_MAX")"
  elif [ "$b" -lt "$PLAN_LINUX_REC" ]; then
    printf 'warn|%s works, but Omarchy Mac recommends %s GB.' "$(fmt_gb "$b")" "$OMARCHY_LINUX_RECOMMENDED_GB"
  else
    printf 'ok'
  fi
}

# plan_layout LINUX_BYTES — the concrete plan for a Linux request, after
# plan_compute. Chooses one region, derives the exact installer answers, the
# resulting extents, and proves the plan's invariants (plan_verify). Sets
# PLAN_OK=1, or PLAN_OK=0 with PLAN_ERR.
#   PLAN_MODE          free (no resize) | resize
#   PLAN_GAP_START/END the one region the install uses (after any resize)
#   PLAN_GAP_PRED      GUID of the partition before it (installer lists the
#                      gap under that partition's name); PLAN_GAP_SUCC after
#   PLAN_MACOS_NEW     container size afterwards; PLAN_ANSWER_RESIZE
#   PLAN_ANSWER_OS     "max" or "<N>MiB"; PLAN_LINUX_ACTUAL; PLAN_ROOT
#   PLAN_LIN_START/END conservative Linux extent
#   PLAN_SHARED_START/END  the reserved Shared interval (Shared on)
#   PLAN_REMAINDER     bytes of the region left unallocated
plan_layout() {
  local req=$1 s=${PLAN_SHARED:-0} t start size pred succ fit best_fit=0 x v g0 g1
  PLAN_OK=0 PLAN_ERR="" PLAN_LINUX=$req PLAN_MODE="" PLAN_ANSWER_RESIZE="" PLAN_ANSWER_OS=""
  PLAN_SHARED_START=0 PLAN_SHARED_END=0 PLAN_REMAINDER=0
  if [ -n "$PLAN_TOPO_ERR" ]; then
    PLAN_ERR=$PLAN_TOPO_ERR
    return 1
  fi
  t=$(( (req + MIB - 1) / MIB * MIB ))
  # 1. An existing gap that holds everything: no resize. The gap right after
  #    the container is preferred, then the largest.
  while IFS='|' read -r start size pred succ; do
    [ -n "$start" ] || continue
    fit=$(_fit "$start" $((start + size)) "$s")
    [ "$fit" -ge "$t" ] || continue
    if [ "$pred" = "$PLAN_MACOS_UUID" ]; then
      best_fit=$((PLAN_DISK + 1))
    elif [ "$size" -le "$best_fit" ]; then
      continue
    else
      best_fit=$size
    fi
    PLAN_MODE=free g0=$start g1=$((start + size)) PLAN_GAP_PRED=$pred PLAN_GAP_SUCC=$succ
  done <<EOF
$GEO_GAPS
EOF
  if [ "$PLAN_MODE" = free ]; then
    PLAN_MACOS_NEW=$PLAN_C
    PLAN_ANSWER_OS=$(mib_answer "$t")
    PLAN_LINUX_ACTUAL=$t
  elif [ "$PLAN_RESIZE_OK" = 1 ]; then
    # 2. Shrink macOS just enough: the new end of the container, aligned,
    #    plus Linux, plus Shared and slack, must reach no further than what
    #    follows the container.
    PLAN_MODE=resize
    x=$(( PLAN_RZ_END / MIB * MIB - t ))
    [ "$s" -gt 0 ] && x=$((x - (s + MIB - 1) / MIB * MIB - PLAN_PLACEMENT_SLACK_BYTES))
    v=$(( (x - PLAN_C0) / MIB * MIB ))
    PLAN_MACOS_NEW=$v
    PLAN_ANSWER_RESIZE=$(mib_answer "$v")
    g0=$((PLAN_C0 + v)) g1=$PLAN_RZ_END PLAN_GAP_PRED=$PLAN_MACOS_UUID PLAN_GAP_SUCC=$PLAN_RZ_SUCC
    if [ "$s" = 0 ]; then
      # Linux takes the whole freed region, which was sized for it. Counted
      # from the aligned start, so this is what it gets at the least.
      PLAN_ANSWER_OS=max
      PLAN_LINUX_ACTUAL=$(( g1 / MIB * MIB - (g0 + MIB - 1) / MIB * MIB ))
    else
      PLAN_ANSWER_OS=$(mib_answer "$t")
      PLAN_LINUX_ACTUAL=$t
    fi
  else
    PLAN_ERR="no single free region holds $(fmt_gb "$req") of Linux$([ "$s" -gt 0 ] && printf ' plus %s of Shared' "$(fmt_gb "$s")"), and macOS cannot be resized: ${PLAN_RESIZE_WHY:-unknown}"
    return 1
  fi
  PLAN_GAP_START=$g0 PLAN_GAP_END=$g1
  PLAN_ROOT=$((PLAN_LINUX_ACTUAL - PLAN_BOOT))
  PLAN_LIN_START=$(( (g0 + MIB - 1) / MIB * MIB ))
  PLAN_LIN_END=$((PLAN_LIN_START + PLAN_LINUX_ACTUAL))
  if [ "$s" -gt 0 ]; then
    PLAN_SHARED_START=$PLAN_LIN_END
    PLAN_SHARED_END=$(( g1 / MIB * MIB ))
  fi
  PLAN_REMAINDER=$((g1 - g0 - PLAN_LINUX_ACTUAL - (PLAN_SHARED_END - PLAN_SHARED_START)))
  PLAN_MACOS_FREE_AFTER=$((PLAN_MACOS_NEW - PLAN_USED))
  plan_verify
}

# plan_verify — the invariants every accepted plan must satisfy, checked on
# the resulting layout rather than assumed from the arithmetic above.
plan_verify() {
  local final="" off size uuid content id role s=${PLAN_SHARED:-0}
  PLAN_OK=0
  # The layout afterwards: the container at its new size, then stub, EFI and
  # root from the conservative start, then the Shared reservation.
  while IFS='|' read -r off size uuid content id role; do
    [ -n "$off" ] || continue
    [ "$uuid" = "$PLAN_MACOS_UUID" ] && size=$PLAN_MACOS_NEW
    final="$final$off|$size|$uuid|$content|$id|$role
"
  done <<EOF
$GEO_PARTS
EOF
  final="$final$PLAN_LIN_START|$ASAHI_STUB_BYTES|plan-stub|Apple_APFS||asahi-stub
$((PLAN_LIN_START + ASAHI_STUB_BYTES))|$ASAHI_EFI_BYTES|plan-efi|EFI||efi
$((PLAN_LIN_START + PLAN_BOOT))|$PLAN_ROOT|plan-root|Linux||linux
"
  [ "$s" -gt 0 ] && final="$final$PLAN_SHARED_START|$((PLAN_SHARED_END - PLAN_SHARED_START))|plan-shared|Shared||shared
"
  if ! _geo_walk "$final" "$GEO_DISK_SIZE" "$GEO_BLOCK"; then
    PLAN_ERR="the planned layout does not fit the disk: $W_ERR"
    return 1
  fi
  if [ "$PLAN_MODE" = resize ]; then
    if [ "$PLAN_MACOS_NEW" -lt "$PLAN_MACOS_FLOOR" ]; then
      PLAN_ERR="macOS would keep $(fmt_gb "$PLAN_MACOS_NEW"), below its $(fmt_gb "$PLAN_MACOS_FLOOR") floor"
      return 1
    fi
    if [ "$PLAN_MACOS_NEW" -ge "$PLAN_C" ] || [ $((PLAN_C - PLAN_MACOS_NEW)) -le "$ASAHI_MIN_INSTALL_FREE_BYTES" ]; then
      PLAN_ERR="the resize would free too little for the installer to accept"
      return 1
    fi
  elif [ "$PLAN_MACOS_NEW" != "$PLAN_C" ]; then
    PLAN_ERR="an install into free space must leave macOS untouched"
    return 1
  fi
  if [ "$PLAN_LINUX_ACTUAL" -lt "$PLAN_LINUX" ]; then
    PLAN_ERR="Linux would get $(fmt_bytes "$PLAN_LINUX_ACTUAL"), less than the $(fmt_bytes "$PLAN_LINUX") requested"
    return 1
  fi
  if [ "$PLAN_ROOT" -lt "$OMARCHY_ROOT_MIN_BYTES" ]; then
    PLAN_ERR="the Linux root would be $(fmt_gb "$PLAN_ROOT"), below Omarchy Mac's $(fmt_gb "$OMARCHY_ROOT_MIN_BYTES")"
    return 1
  fi
  if [ "$PLAN_LIN_END" -gt "$PLAN_GAP_END" ]; then
    PLAN_ERR="Linux would run past the end of its free region"
    return 1
  fi
  if [ "$s" -gt 0 ]; then
    if [ "$PLAN_ANSWER_OS" = max ]; then
      PLAN_ERR="with Shared storage on, Linux must be given an exact size, never max"
      return 1
    fi
    if [ $((PLAN_SHARED_END - PLAN_SHARED_START)) -lt $(( (s + MIB - 1) / MIB * MIB + PLAN_PLACEMENT_SLACK_BYTES )) ]; then
      PLAN_ERR="the Shared reservation would be $(fmt_bytes $((PLAN_SHARED_END - PLAN_SHARED_START))), less than the $(fmt_bytes "$s") requested plus slack"
      return 1
    fi
  fi
  PLAN_OK=1
}
