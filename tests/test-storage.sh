#!/usr/bin/env bash
# Storage geometry and planning. Every accepted plan is checked by an
# independent model of what the Asahi installer does with the typed answers
# (asahi-installer v0.9.2: resize aligns up, New OS size aligns down, stub,
# EFI and root created in order after the gap's start), rather than by the
# planner's own arithmetic. Layouts are built from exact byte extents.
# shellcheck disable=SC2015,SC2016,SC2086 # ok/fail always return 0; literal $ in single quotes; lists split on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load
echo "test-storage"

ISC=576716800
REC=5368664064
STUB=2499805184
EFI=524288000
D1T=1000555581440
D512=500277792768
U_ISC=A-ISC U_MAC=A-MAC U_REC=A-REC U_DATA=A-DATA
gbm() { printf '%s' $(($1 * GB / MIB * MIB)); }

# mk DISK BLOCK ENTRY... — a layout from the GPT's first usable block.
# ENTRY: id:content:size:uuid:role  or  gap:bytes
mk() {
  local disk=$1 block=$2 off e id content size uuid role
  shift 2
  off=$((2 * block + 16384))
  geo_reset
  for e in "$@"; do
    case "$e" in gap:*)
      off=$((off + ${e#gap:}))
      continue
      ;;
    esac
    IFS=: read -r id content size uuid role <<EOF
$e
EOF
    geo_add "$off" "$size" "$uuid" "$content" "$id" "$role"
    off=$((off + size))
  done
  geo_finalize "$disk" "$block"
}
# stock DISK BLOCK — ISC, the container filling the rest, Recovery.
stock() {
  local c=$(($1 - 2 * $2 - 16384 - $2 - 16384 - ISC - REC))
  mk "$1" "$2" "s1:Apple_APFS_ISC:$ISC:$U_ISC:isc" "s2:Apple_APFS:$c:$U_MAC:macos" "s3:Apple_APFS_Recovery:$REC:$U_REC:recovery"
  C=$c
}
# init FREE [PREF] — plan_init for the container; PREF defaults to used + 40 GB.
init() {
  local pref=${2-$((C - $1 + 40 * GB))}
  plan_init "$U_MAC" "$C" "$1" "$pref"
}

# --- The independent check ------------------------------------------------------
# sim LABEL LINUX SHARED — replays the plan's answers the way the installer
# would, then asserts the invariants on the resulting extents.
sim() {
  local label=$1 want_l=$2 want_s=$3 c0 csz next_start v gstart gend gsize os lin_start lin_end sh_avail
  local used min_raw minimum n inside
  geo_part "$U_MAC"
  c0=$GP_OFFSET csz=$GP_SIZE
  if geo_next "$U_MAC"; then next_start=$GN_OFFSET; else next_start=$GEO_USABLE_END; fi
  used=$PLAN_USED
  min_raw=$(( (used + 38000000000 + MIB - 1) / MIB * MIB ))
  minimum=$min_raw
  [ -n "$SIM_PREF" ] && [ "$SIM_PREF" -gt "$minimum" ] && minimum=$SIM_PREF
  case "$PLAN_MODE" in
    resize)
      case "$PLAN_ANSWER_RESIZE" in *MiB) ;; *) fail "$label: resize answer is not exact MiB ($PLAN_ANSWER_RESIZE)" ;; esac
      v=$(( ${PLAN_ANSWER_RESIZE%MiB} * MIB ))
      v=$(( (v + MIB - 1) / MIB * MIB ))                   # the installer aligns up
      [ "$v" -ge "$minimum" ] && ok || fail "$label: installer would refuse $v < minimum $minimum"
      [ "$v" -ge $((minimum + 5000000000)) ] && ok || fail "$label: macOS keeps less than its floor"
      [ "$v" -lt "$csz" ] && [ $((csz - v)) -gt 10000000000 ] && ok || fail "$label: resize frees too little"
      gstart=$((c0 + v)) gend=$next_start
      ;;
    free)
      [ -z "$PLAN_ANSWER_RESIZE" ] && ok || fail "$label: free-space install still resizes"
      n=$(printf '%s' "$GEO_GAPS" | awk -F'|' -v s="$PLAN_GAP_START" '$1 == s' | grep -c .)
      assert_eq "$n" 1 "$label: the plan names exactly one existing gap"
      gstart=$PLAN_GAP_START gend=$PLAN_GAP_END
      ;;
    *) fail "$label: no mode"; return ;;
  esac
  gsize=$((gend - gstart))
  if [ "$PLAN_ANSWER_OS" = max ]; then
    os=$(( gsize / MIB * MIB ))
  else
    case "$PLAN_ANSWER_OS" in *MiB) ;; *) fail "$label: OS answer is not exact MiB ($PLAN_ANSWER_OS)" ;; esac
    os=$(( ${PLAN_ANSWER_OS%MiB} * MIB / MIB * MIB ))    # the installer aligns down
  fi
  [ "$os" -le "$gsize" ] && ok || fail "$label: installer would refuse OS size $os > gap $gsize"
  [ "$os" -ge "$want_l" ] && ok || fail "$label: Linux gets $os < requested $want_l"
  [ $((os - STUB - EFI)) -ge 50000000000 ] && ok || fail "$label: root $((os - STUB - EFI)) below 50 GB"
  # man diskutil: addPartition starts a partition "immediately beyond the end"
  # of the one before it, which is how max is placed. For an exact answer the
  # plan must also hold if macOS rounds the start up to the next MiB.
  lin_start=$(( (gstart + MIB - 1) / MIB * MIB ))
  [ "$PLAN_ANSWER_OS" = max ] && lin_start=$gstart
  lin_end=$((lin_start + os))
  [ "$PLAN_ANSWER_OS" = max ] || { [ "$lin_end" -le "$gend" ] && ok || fail "$label: Linux runs past its gap"; }
  # Nothing already on the disk lies inside the region used.
  inside=$(printf '%s' "$GEO_PARTS" | awk -F'|' -v a="$gstart" -v b="$gend" '$1 < b && $1 + $2 > a && $3 != "'"$U_MAC"'"' | grep -c .)
  assert_eq "$inside" 0 "$label: the region used is one free interval"
  if [ "$want_s" -gt 0 ]; then
    [ "$PLAN_ANSWER_OS" != max ] && ok || fail "$label: Shared on but Linux typed max"
    sh_avail=$(( gend / MIB * MIB - lin_end ))
    [ "$sh_avail" -ge "$want_s" ] && ok || fail "$label: Shared keeps $sh_avail < requested $want_s"
  fi
  # Conservation: the layout afterwards accounts for every byte of the disk.
  local final
  final=$(printf '%s' "$GEO_PARTS" | awk -F'|' -v u="$U_MAC" -v v="${v:-0}" -v m="$PLAN_MODE" 'BEGIN{OFS="|"} $3 == u && m == "resize" {$2 = v} {print $1, $2}'
    printf '%s|%s\n' "$lin_start" "$STUB" "$((lin_start + STUB))" "$EFI" "$((lin_start + STUB + EFI))" "$((os - STUB - EFI))"
    [ "$want_s" -gt 0 ] && printf '%s|%s\n' "$lin_end" "$(( gend / MIB * MIB - lin_end ))")
  local sum
  sum=$(printf '%s\n' "$final" | sort -t'|' -k1,1n | awk -F'|' -v s="$GEO_USABLE_START" -v e="$GEO_USABLE_END" -v d="$GEO_DISK_SIZE" '
    BEGIN { pos = s; total = s + (d - e); bad = 0 }
    { if ($1 < pos) bad = 1; total += ($1 - pos) + $2; pos = $1 + $2 }
    END { if (pos > e) bad = 1; total += e - pos; print (bad ? "overlap" : total) }')
  assert_eq "$sum" "$GEO_DISK_SIZE" "$label: no overlap, and every byte accounted for"
}

# plan L S — compute and lay out; SIM_PREF set by the caller.
plan() {
  plan_compute "$2"
  plan_layout "$1"
}

# --- Geometry: the walker refuses anything it cannot account for ---------------------
stock $D1T 4096
assert_eq "$GEO_OK" 1 "stock 1 TB layout reads"
assert_eq "$C" 994610155520 "the stock container is the real 1 TB M1 Pro size"
assert_eq "$GEO_GAPS" "" "a stock disk has no free gap"
assert_eq "$GEO_USABLE_START $GEO_USABLE_END" "24576 $((D1T - 20480))" "4096-byte GPT: first usable block 6, 5 blocks at the end"
mk $D1T 4096 "s1:Apple_APFS_ISC:$ISC:$U_ISC:isc" "s2:Apple_APFS:$((C + 4096)):$U_MAC:macos" "s3:Apple_APFS_Recovery:$REC:$U_REC:recovery"
assert_eq "$GEO_OK" 0 "partitions past the end of the disk are refused"
geo_reset
geo_add 24576 $ISC "$U_ISC" x s1 isc
geo_add 24576 $ISC "$U_MAC" x s2 macos
geo_finalize $D1T 4096
assert_contains "$GEO_ERR" "overlaps" "overlapping partitions are refused"
geo_reset
geo_add 24577 $ISC "$U_ISC" x s1 isc
geo_finalize $D1T 4096
assert_contains "$GEO_ERR" "not aligned" "a partition off the block size is refused"
geo_reset
geo_add 24576 $ISC "$U_ISC" x s1 isc
geo_add $((24576 + ISC)) $ISC "$U_ISC" x s2 isc
geo_finalize $D1T 4096
assert_contains "$GEO_ERR" "appears twice" "a duplicated GUID is refused"
geo_reset
geo_add "" $ISC "$U_ISC" x s1 isc
geo_finalize $D1T 4096
assert_eq "$GEO_OK" 0 "a missing offset leaves the geometry unknown"
geo_reset
geo_add 024576 $ISC "$U_ISC" x s1 isc
assert_rc $? 1 "a leading-zero offset is not a number here"
geo_reset
geo_add '1+1' $ISC "$U_ISC" x s1 isc
assert_rc $? 1 "arithmetic text is not an offset"
stock $D1T 4096
assert_eq "$(_geo_walk "$GEO_PARTS" $D1T 1024; echo "$W_OK")" 0 "an unsupported block size is refused"

# --- Stock 1 TB, 700 GB free: Shared off, 50, 150, 250 ------------------------------------
stock $D1T 4096
SIM_PREF=$((C - 700 * GB + 40 * GB))
init $((700 * GB)) "$SIM_PREF"
assert_eq "$PLAN_TOPO_ERR" "" "the container is plannable"
assert_eq "$PLAN_RESIZE_OK" 1 "a resize is possible"
assert_eq "$PLAN_LINUX_MIN" $((54 * GB)) "Linux minimum: a 50 GB root plus stub and EFI, in whole GB"
for s in 0 50 150 250; do
  plan_compute $((s * GB))
  assert_rc $? 0 "1 TB with $s GB Shared fits"
  maxgb=$((PLAN_LINUX_MAX / GB))
  for l in 54 100 250 "$maxgb"; do
    plan $((l * GB)) $((s * GB))
    assert_eq "$PLAN_OK" 1 "1 TB, Linux $l GB, Shared $s GB: plan holds ($PLAN_ERR)"
    sim "1 TB L=$l S=$s" $((l * GB)) $((s * GB))
  done
done
plan_compute 0
max0=$PLAN_LINUX_MAX
plan_compute $((150 * GB))
assert_eq $(( (max0 - PLAN_LINUX_MAX) / GB )) 150 "Shared reduces the Linux maximum by its own size"
plan $((250 * GB)) 0
assert_eq "$PLAN_MODE $PLAN_ANSWER_OS" "resize max" "no Shared: Linux takes the freed region with max"
plan $((250 * GB)) $((150 * GB))
assert_eq "$PLAN_MODE" resize "Shared on: resize"
assert_contains "$PLAN_ANSWER_OS" MiB "Shared on: Linux gets an exact size"

# The audit's reproduction: Linux 250 GB with 32 GB Shared once left 31.66 GB.
plan $((250 * GB)) $((32 * GB))
[ $((PLAN_SHARED_END - PLAN_SHARED_START)) -ge $((32 * GB)) ] && ok || fail "32 GB Shared is fully reserved"
sim "audit: L=250 S=32" $((250 * GB)) $((32 * GB))
# And a 50 GB request once gave Linux 49.66 GB; it is now below the minimum.
assert_contains "$(plan_validate $((50 * GB)))" "error|50 GB is below the 54 GB Linux needs" "50 GB is refused: root would be under 50 GB"
assert_contains "$(plan_validate $((53 * GB)))" "error|" "53 GB is refused"
assert_eq "$(plan_validate $((54 * GB)))" "warn|54 GB works, but Omarchy Mac recommends 100 GB." "54 GB is the exact boundary"
plan $((54 * GB)) 0
sim "boundary 54 GB" $((54 * GB)) 0
[ "$PLAN_ROOT" -ge 50000000000 ] && ok || fail "54 GB leaves a root of at least 50 GB"

# Presets from the geometry.
plan_compute 0
plan_presets
assert_eq "$(printf '%s' "$PRESETS" | cut -d'|' -f1 | tr '\n' ' ')" "minimal balanced heavy max " "1 TB preset keys"
assert_eq "$(printf '%s' "$PRESETS" | cut -d'|' -f3 | tr '\n' ' ')" "$((100 * GB)) $((250 * GB)) $((500 * GB)) $max0 " "1 TB preset sizes"
assert_eq "$PRESET_DEFAULT" balanced "1 TB recommends balanced"

# --- 512 GB -------------------------------------------------------------------------
stock $D512 4096
SIM_PREF=$((C - 250 * GB + 58 * GB))
init $((250 * GB)) "$SIM_PREF"
assert_eq "$PLAN_OVERHEAD_WARN" 1 "512 GB: 20 GB of snapshot overhead warns"
for s in 0 50; do
  plan_compute $((s * GB))
  for l in 54 100 $((PLAN_LINUX_MAX / GB)); do
    plan $((l * GB)) $((s * GB))
    assert_eq "$PLAN_OK" 1 "512 GB, Linux $l, Shared $s: plan holds ($PLAN_ERR)"
    sim "512 L=$l S=$s" $((l * GB)) $((s * GB))
  done
done

# --- Near-full and snapshot-constrained APFS ----------------------------------------------
stock $D1T 4096
init $((45 * GB)) $((C - 45 * GB + 38 * GB))
plan_compute 0
assert_rc $? 1 "near-full: no room for Linux"
[ "$PLAN_SHORTFALL" -gt 0 ] && ok || fail "near-full: the shortfall is reported"
plan_layout $((54 * GB))
assert_eq "$PLAN_OK" 0 "near-full: no plan is produced"
SIM_PREF=$((C - 300 * GB + 38 * GB + 30 * GB))
init $((300 * GB)) "$SIM_PREF"
assert_eq "$PLAN_OVERHEAD" $((SIM_PREF - PLAN_MACOS_RAW)) "snapshots: overhead is what diskutil keeps above used + 38 GB"
plan_compute 0
[ "$PLAN_LINUX_MAX" -le $((C - SIM_PREF - 5 * GB)) ] && ok || fail "snapshots: Linux never gets what diskutil says macOS must keep"
plan $((PLAN_LINUX_MAX)) 0
sim "snapshot max" "$PLAN_LINUX_MAX" 0

# --- Unknown resize limits: no resize is planned on a guess ---------------------------------
stock $D1T 4096
init $((700 * GB)) ""
assert_eq "$PLAN_RESIZE_OK" 0 "unknown limits: no resize"
assert_contains "$PLAN_RESIZE_WHY" "resize limits" "unknown limits: the reason is named"
plan_compute 0
assert_rc $? 1 "unknown limits and no free gap: blocked"
plan_layout $((100 * GB))
assert_contains "$PLAN_ERR" "cannot be resized" "unknown limits: the plan refuses"

# --- Fractional alignment: a container that does not start on a MiB boundary ---------------
stock $D1T 4096
geo_part "$U_MAC"
[ $((GP_OFFSET % MIB)) != 0 ] && ok || fail "the stock container starts off a MiB boundary (as on real disks)"
SIM_PREF=$((C - 700 * GB + 40 * GB))
init $((700 * GB)) "$SIM_PREF"
for l in 54 99 101 333; do
  plan $((l * GB)) $((77 * GB))
  sim "unaligned start L=$l S=77" $((l * GB)) $((77 * GB))
done

# --- Existing free space ----------------------------------------------------------------------
# One adequate gap, not next to the container: used without any resize.
c=$((C - $(gbm 20) - $(gbm 120)))
mk $D1T 4096 "s1:Apple_APFS_ISC:$ISC:$U_ISC:isc" "s2:Apple_APFS:$c:$U_MAC:macos" "s4:Microsoft Basic Data:$(gbm 20):$U_DATA:data" \
  "gap:$(gbm 120)" "s3:Apple_APFS_Recovery:$REC:$U_REC:recovery"
C=$c SIM_PREF=$((C - 300 * GB + 40 * GB))
init $((300 * GB)) "$SIM_PREF"
plan $((100 * GB)) 0
assert_eq "$PLAN_MODE" free "one adequate gap: no resize"
assert_eq "$PLAN_GAP_PRED" "$U_DATA" "the gap after the data partition is the one used"
sim "non-adjacent adequate gap" $((100 * GB)) 0
# The same gap is too small for Linux + Shared: a resize, and the other gap is left alone.
plan $((100 * GB)) $((50 * GB))
assert_eq "$PLAN_MODE" resize "gap too small with Shared: resize instead"
assert_eq "$PLAN_GAP_PRED" "$U_MAC" "the region after the container is used"
sim "non-adjacent gap, resize" $((100 * GB)) $((50 * GB))

# Two 75 GB gaps, macOS unable to shrink: 150 GB free, but 100 GB fits nowhere.
C=$((D1T - 45056 - ISC - REC - 2 * $(gbm 75) - $(gbm 20)))
mk $D1T 4096 "s1:Apple_APFS_ISC:$ISC:$U_ISC:isc" "s2:Apple_APFS:$C:$U_MAC:macos" "gap:$(gbm 75)" \
  "s4:Microsoft Basic Data:$(gbm 20):$U_DATA:data" "gap:$(gbm 75)" "s3:Apple_APFS_Recovery:$REC:$U_REC:recovery"
SIM_PREF=$((C - 40 * GB + 39 * GB))
init $((40 * GB)) "$SIM_PREF"
assert_eq "$PLAN_RESIZE_OK" 0 "two gaps: macOS cannot shrink"
plan_compute 0
[ "$PLAN_LINUX_MAX" -lt $((75 * GB)) ] && ok || fail "two gaps: the maximum is one gap's worth, not the sum"
plan_layout $((100 * GB))
assert_eq "$PLAN_OK" 0 "two gaps: 100 GB is refused although 150 GB is free"
plan $((60 * GB)) 0
assert_eq "$PLAN_OK $PLAN_MODE" "1 free" "two gaps: 60 GB fits in one of them"
sim "two gaps, one used" $((60 * GB)) 0
plan_compute $((30 * GB))
plan_layout $((54 * GB))
assert_eq "$PLAN_OK" 0 "two gaps: Linux in one and Shared in the other is never planned"

# Adjacent gap: the resize frees space that merges with it, and the plan counts both exactly.
stock $D1T 4096
cstock=$C
C=$((cstock - $(gbm 80)))
mk $D1T 4096 "s1:Apple_APFS_ISC:$ISC:$U_ISC:isc" "s2:Apple_APFS:$C:$U_MAC:macos" "gap:$(gbm 80)" "s3:Apple_APFS_Recovery:$REC:$U_REC:recovery"
SIM_PREF=$((C - 500 * GB + 40 * GB))
init $((500 * GB)) "$SIM_PREF"
plan $((60 * GB)) 0
assert_eq "$PLAN_MODE" free "adjacent 80 GB gap holds 60 GB without a resize"
sim "adjacent gap, free" $((60 * GB)) 0
plan $((100 * GB)) 0
assert_eq "$PLAN_MODE" resize "adjacent gap too small: resize"
[ $((C - PLAN_MACOS_NEW)) -lt $((100 * GB)) ] && ok || fail "the resize frees only what the adjacent gap lacks"
sim "adjacent gap, merged" $((100 * GB)) 0
plan $((100 * GB)) $((50 * GB))
sim "adjacent gap, merged, Shared" $((100 * GB)) $((50 * GB))

# --- 512-byte logical sectors ----------------------------------------------------------------
stock 500107862016 512
assert_eq "$GEO_OK $GEO_USABLE_START" "1 17408" "512-byte GPT: first usable block 34"
SIM_PREF=$((C - 300 * GB + 40 * GB))
init $((300 * GB)) "$SIM_PREF"
for s in 0 50; do
  plan $((100 * GB)) $((s * GB))
  assert_eq "$PLAN_OK" 1 "512-byte sectors, Shared $s: plan holds ($PLAN_ERR)"
  sim "512-byte sectors S=$s" $((100 * GB)) $((s * GB))
done

# --- A plan never guesses about the container ------------------------------------------------
stock $D1T 4096
plan_init "$U_MAC" $((C + 4096)) $((700 * GB)) $((C - 660 * GB))
assert_contains "$PLAN_TOPO_ERR" "not the size of its partition" "a container larger than its partition is refused"
plan_init "NOPE" "$C" $((700 * GB)) 1
assert_contains "$PLAN_TOPO_ERR" "not found" "a missing container partition is refused"
plan_init "$U_MAC" "$C" "$((C + 1))" 1
assert_contains "$PLAN_TOPO_ERR" "did not report" "free space larger than the container is refused"

# --- Checked size input --------------------------------------------------------------------
D=$D1T
MAXB=$((654 * GB))
for pair in "250:$((250 * GB))" "250GB:$((250 * GB))" "250 gb:$((250 * GB))" "250G:$((250 * GB))" \
  "250.5GB:250500000000" "250.125GB:250125000000" "0.5TB:$((500 * GB))" "1T:$((1000 * GB))" \
  "30%:$((D * 300 / 1000))" "12.5%:$((D * 125 / 1000))" "max:$MAXB" "MAX:$MAXB" "0.1GB:100000000"; do
  in=${pair%%:*} want=${pair#*:}
  assert_eq "$(parse_size "$in" "$D" "$MAXB")" "$want" "parse '$in'"
done
tab=$(printf '\t')
assert_eq "$(parse_size "  250 GB  " "$D")" $((250 * GB)) "surrounding blanks are ignored"
assert_eq "$(parse_size "${tab}250${tab}GB${tab}" "$D")" $((250 * GB)) "tabs are blanks too"
for bad in 08 010 00 0 -1 +1 1..0 1..2GB 1844674.5TB 999999999999 9999999999999999999999 \
  18446744073709551916GB 100.0% 100.1% 150% NaN nan abc 1e3 0x10 '' ' ' '2 50' 250MB 1.2345GB 12.55% \
  '$(reboot)' 'a[$(touch /tmp/x)]' "1$tab$tab%%" 10000TB 1001GBX; do
  parse_size "$bad" "$D" "$MAXB" >/dev/null
  assert_rc $? 1 "rejected: '$bad'"
done
assert_contains "$(parse_size 010 "$D")" "leading zero" "010 is refused as ambiguous, not read as octal"
assert_contains "$(parse_size 08 "$D")" "write 8GB" "08 names what was probably meant"
assert_contains "$(parse_size 1001GB "$D")" "not smaller than the whole internal disk" "no request can exceed the disk"
assert_contains "$(parse_size max "$D")" "not available" "max without a maximum is refused"

# --- Formatting --------------------------------------------------------------------------
assert_eq "$(fmt_gb $((250 * GB)))" "250 GB" "whole GB"
assert_eq "$(fmt_gb 994610155520)" "994.6 GB" "one decimal"
assert_eq "$(fmt_gb 0)" "0 GB" "zero"
assert_eq "$(fmt_gb 1216512)" "1.2 MB" "a small remainder is shown in MB, not as 0 GB"
assert_eq "$(fmt_bytes 150000184320)" "150,000,184,320 bytes" "exact bytes, grouped"
assert_eq "$(fmt_bytes 999)" "999 bytes" "small exact bytes"
assert_eq "$(mib_answer $((238420 * MIB)))" "238420MiB" "installer answers are whole MiB"
assert_eq "$(round_nice $((D1T / 4)))" $((250 * GB)) "25% of 1 TB rounds to 250"
assert_eq "$(round_nice $((D512 / 4)))" $((125 * GB)) "25% of 512 GB rounds to 125"

# --- Version comparison (macOS minimum) ------------------------------------------------
for pair in "13.5 13.5 0" "13.10 13.5 0" "14 13.5 0" "27.0 13.5 0" "13.4.1 13.5 1" "13 13.5 1" "12.7 13.5 1" "13.5.1 13.5 0"; do
  set -- $pair
  ver_ge "$1" "$2"
  assert_rc $? "$3" "ver_ge $1 >= $2"
done

t_done test-storage
