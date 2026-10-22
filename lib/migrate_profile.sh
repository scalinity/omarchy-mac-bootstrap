# shellcheck shell=bash
# A stand-in until its unit is built (MILESTONES.md → *The finish*, phase A).
prof_row() { return 1; }
prof_core_op() { core_result refused unavailable "The profile is not built yet."; }
prof_cmd() {
  ui_fail "profile is not built yet."
  return 1
}
