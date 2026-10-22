# shellcheck shell=bash
# A stand-in until its unit is built (MILESTONES.md → *The finish*, phase A).
bndl_row() { return 1; }
bndl_core_op() { core_result refused unavailable "Export is not built yet."; }
bndl_cmd_export() {
  ui_fail "export is not built yet."
  return 1
}
