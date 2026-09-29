# shellcheck shell=bash
# Test-only instrumentation of the baseline read seams; preserves originals.
for seam in sys_cmd sys_path sys_has sys_net sys_reachable; do
  eval "$(declare -f "$seam" | sed "1s/$seam/g2_original_$seam/")"
  eval "$seam() { printf '%s\\n' \"$seam \$*\" >>\"\$G2_PROBES\"; g2_original_$seam \"\$@\"; }"
done
