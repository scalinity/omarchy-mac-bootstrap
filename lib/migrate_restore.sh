# shellcheck shell=bash
# Phase B restore stand-in, replaced by the restore unit (M15-A). The row
# lookup exposes no actions; the core and text routes report unavailability
# until that unit supplies bundle selection, restore, status and undo.

rst_row() { return 1; }
rst_core_op() { core_result refused unavailable "Restore is not built yet."; }
rst_cmd() { ui_fail "Restore is not built yet."; return 1; }
