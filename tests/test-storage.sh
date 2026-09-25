#!/usr/bin/env bash
# Storage planner: pure arithmetic, expected values worked by hand from the
# fixture numbers (tests/fixtures/generate.sh).
# shellcheck disable=SC2015,SC2016,SC2086 # ok/fail always return 0; literal $ in single quotes; file lists split on purpose
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
t_load
echo "test-storage"

D1T=1000555581440
C1T=994662543360
D512=500277792768
C512=494384754688

# --- 1 TB, 700 GB free, preferred minimum = used + 40 GB -------------------
used=$((C1T - 700 * GB))
plan_compute $D1T $C1T $((700 * GB)) $((used + 40 * GB)) 0 0
assert_rc $? 0 "roomy fits"
assert_eq "$PLAN_USED" "$used" "roomy used"
assert_eq "$PLAN_LINUX_MAX" $((655 * GB)) "roomy safe maximum = 700 - 40 - 5"
assert_eq "$PLAN_MACOS_MIN" $((used + 40 * GB)) "installer minimum takes diskutil's larger value"
assert_eq "$PLAN_OVERHEAD_WARN" 0 "2 GB overhead is below the installer's warning"
plan_presets
assert_eq "$(printf '%s' "$PRESETS" | cut -d'|' -f1 | tr '\n' ' ')" "minimal balanced heavy max " "roomy preset keys"
assert_eq "$(printf '%s' "$PRESETS" | cut -d'|' -f3 | tr '\n' ' ')" "$((100 * GB)) $((250 * GB)) $((500 * GB)) $((655 * GB)) " "roomy preset sizes"
assert_eq "$PRESET_DEFAULT" balanced "roomy recommends balanced"
plan_layout $((250 * GB))
assert_eq "$PLAN_MODE" resize "250 GB needs a resize"
assert_eq "$PLAN_MACOS_NEW_GB" 745 "macOS new size = ceil(994.66 - 250)"
assert_eq "$PLAN_OS_SIZE_ANSWER" max "New OS size answer"
assert_eq "$PLAN_LINUX_ACTUAL" $((C1T - 745 * GB)) "Linux gets the whole freed region"
assert_eq "$PLAN_ROOT" $((C1T - 745 * GB - 2500000000 - 524288000)) "root = allocation - stub - EFI"
assert_eq "$PLAN_MACOS_FREE_AFTER" $((745 * GB - used)) "macOS free after"
plan_layout $((655 * GB))
[ "$PLAN_MACOS_NEW" -ge "$PLAN_MACOS_MIN" ] && ok || fail "maximum keeps macOS at or above the installer minimum"

# --- 1 TB, 60 GB free: blocked ---------------------------------------------
used=$((C1T - 60 * GB))
plan_compute $D1T $C1T $((60 * GB)) $((used + 39 * GB)) 0 0
assert_rc $? 1 "tight is blocked"
assert_eq "$PLAN_LINUX_MAX" $((16 * GB)) "tight maximum = 60 - 39 - 5"
assert_eq "$PLAN_SHORTFALL" $((34 * GB)) "tight shortfall to 50 GB"
plan_presets
assert_rc $? 1 "no presets when blocked"

# --- 512 GB with 20 GB snapshot overhead ------------------------------------
used=$((C512 - 250 * GB))
plan_compute $D512 $C512 $((250 * GB)) $((used + 58 * GB)) 0 0
assert_eq "$PLAN_LINUX_MAX" $((187 * GB)) "512 maximum = 250 - 58 - 5"
assert_eq "$PLAN_OVERHEAD_WARN" 1 "20 GB overhead warns"
plan_presets
assert_eq "$(printf '%s' "$PRESETS" | cut -d'|' -f3 | tr '\n' ' ')" "$((100 * GB)) $((125 * GB)) $((187 * GB)) " "512 presets drop Linux-heavy"
assert_eq "$PRESET_DEFAULT" balanced "512 recommends balanced (125 GB)"

# --- No diskutil limits: the installer's raw floor applies --------------------
plan_compute $D1T $C1T $((700 * GB)) 0 0 0
assert_eq "$PLAN_OVERHEAD" 0 "no overhead without limits"
raw=$(((C1T - 700 * GB + 38 * GB + 1048575) / 1048576 * 1048576))
assert_eq "$PLAN_MACOS_MIN" "$raw" "raw floor aligned up to 1 MiB"

# --- Presets near the edge ---------------------------------------------------
# Max 100 GB: the 100 GB preset is not below 90% of the maximum, so only "max" is offered.
plan_compute $D1T $((200 * GB)) $((150 * GB)) $((95 * GB)) 0 0
assert_eq "$PLAN_LINUX_MAX" $((100 * GB)) "edge maximum"
plan_presets
assert_eq "$(printf '%s' "$PRESETS" | cut -d'|' -f1 | tr '\n' ' ')" "max " "near-max presets collapse"
assert_eq "$PRESET_DEFAULT" max "falls back to max"
# Max 80 GB: minimal becomes the 50 GB minimum.
plan_compute $D1T $((200 * GB)) $((130 * GB)) $((115 * GB)) 0 0
assert_eq "$PLAN_LINUX_MAX" $((80 * GB)) "small maximum"
plan_presets
assert_eq "$(printf '%s' "$PRESETS" | cut -d'|' -f3 | tr '\n' ' ')" "$((50 * GB)) $((80 * GB)) " "minimal drops to 50 GB"

# --- Custom input -------------------------------------------------------------
plan_compute $D1T $C1T $((700 * GB)) $((C1T - 700 * GB + 40 * GB)) 0 0
assert_eq "$(parse_size 250)" $((250 * GB)) "bare number is GB"
assert_eq "$(parse_size 250GB)" $((250 * GB)) "GB suffix"
assert_eq "$(parse_size '250 gb')" $((250 * GB)) "space and lowercase"
assert_eq "$(parse_size 250G)" $((250 * GB)) "G suffix"
assert_eq "$(parse_size 250.5GB)" 250500000000 "one decimal"
assert_eq "$(parse_size 0.5TB)" $((500 * GB)) "TB with decimal"
assert_eq "$(parse_size 1T)" $((1000 * GB)) "T suffix"
assert_eq "$(parse_size 30%)" $((D1T * 300 / 1000)) "percent of the whole disk"
assert_eq "$(parse_size 12.5%)" $((D1T * 125 / 1000)) "decimal percent"
assert_eq "$(parse_size max)" $((655 * GB)) "max"
parse_size abc >/dev/null
assert_rc $? 1 "letters rejected"
parse_size 1.2.3 >/dev/null
assert_rc $? 1 "two dots rejected"
parse_size 150% >/dev/null
assert_rc $? 1 "over 100% rejected"
parse_size '' >/dev/null
assert_rc $? 1 "empty rejected"
parse_size -5 >/dev/null
assert_rc $? 1 "negative rejected"
for big in 9223372037 1844674407370955 18446744073709551916GB; do
  parse_size "$big" >/dev/null
  assert_rc $? 1 "huge value rejected instead of wrapping: $big"
done
assert_eq "$(parse_size 9999999)" $((9999999 * GB)) "seven digits still accepted"

assert_contains "$(plan_validate $((20 * GB)))" "error|20 GB is below the 50 GB" "below minimum"
assert_contains "$(plan_validate $((50 * GB)))" "warn|" "minimum accepted with warning"
assert_contains "$(plan_validate $((99 * GB)))" "recommends 100 GB" "below recommended warns"
assert_eq "$(plan_validate $((100 * GB)))" ok "recommended is ok"
assert_eq "$(plan_validate $((655 * GB)))" ok "maximum is ok"
v=$(plan_validate $((656 * GB)))
assert_contains "$v" "error|" "above maximum rejected"
assert_contains "$v" "$(fmt_gb "$ASAHI_MIN_FREE_OS_BYTES") for updates + 2 GB snapshot overhead + $(fmt_gb "$PLAN_DRIFT_MARGIN_BYTES") margin" "rejection explains the reserve from the constants"
assert_contains "$v" "at most 655 GB" "rejection names the maximum"

# --- Existing free space and the shared reservation ---------------------------
plan_compute $D1T $C1T $((700 * GB)) $((C1T - 700 * GB + 40 * GB)) $((300 * GB)) 0
plan_layout $((250 * GB))
assert_eq "$PLAN_MODE" free "fits in existing free space"
assert_eq "$PLAN_OS_SIZE_ANSWER" 250GB "free space install types the size"
assert_eq "$PLAN_MACOS_NEW" "$C1T" "macOS untouched"
# Existing space smaller than the request: resize, and type the reviewed size,
# because the freed region may merge with the existing gap.
plan_compute $D1T $C1T $((700 * GB)) $((C1T - 700 * GB + 40 * GB)) $((100 * GB)) 0
plan_layout $((250 * GB))
assert_eq "$PLAN_MODE" resize "existing space too small: resize"
assert_eq "$PLAN_MACOS_NEW_GB" 745 "macOS shrinks by the full request"
assert_eq "$PLAN_OS_SIZE_ANSWER" 250GB "the reviewed size is typed, not max"
assert_eq "$PLAN_LINUX_ACTUAL" $((250 * GB)) "Linux gets exactly what was reviewed"
plan_compute $D1T $C1T $((700 * GB)) $((C1T - 700 * GB + 40 * GB)) 0 $((32 * GB))
assert_eq "$PLAN_LINUX_MAX" $((623 * GB)) "shared space reduces the maximum"
plan_layout $((250 * GB))
assert_eq "$PLAN_MACOS_NEW_GB" 713 "macOS shrinks for Linux + shared"
assert_eq "$PLAN_OS_SIZE_ANSWER" 250GB "shared plan types the Linux size, leaving the rest free"

# --- Formatting -------------------------------------------------------------------
assert_eq "$(fmt_gb $((250 * GB)))" "250 GB" "whole GB"
assert_eq "$(fmt_gb $C1T)" "994.7 GB" "one decimal"
assert_eq "$(fmt_gb 0)" "0 GB" "zero"
assert_eq "$(fmt_gb 1050000000)" "1.1 GB" "rounding"
assert_eq "$(round_nice $((D1T / 4)))" $((250 * GB)) "25% of 1 TB rounds to 250"
assert_eq "$(round_nice $((D512 / 4)))" $((125 * GB)) "25% of 512 GB rounds to 125"
assert_eq "$(round_nice $((64 * GB)))" $((60 * GB)) "small values round to 10"

t_done test-storage
