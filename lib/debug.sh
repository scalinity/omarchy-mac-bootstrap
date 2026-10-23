# shellcheck shell=bash
# Phase B debugging stand-in, replaced by the debug and SSH unit (M15-A,
# M15-C). The core and text routes report unavailability until that unit
# supplies the fixed agent brief and read-only machine facts.

dbg_core_op() { core_result refused unavailable "Debugging help is not built yet."; }
dbg_cmd() { ui_fail "Debugging help is not built yet."; return 1; }
