#!/usr/bin/env bash
# Test-only semantic taps on an independently extracted tree's Doctor owner.
# Production never uses this adapter or parses painted Doctor text.
#   findings — the tree's cmd_doctor, its ui_tag arguments as rows on stdout;
#              status and counters in $G2_PROBES.summary; its probes only.
#   render   — typed rows (file $3) and counters ($4..$6) through the tree's
#              own ui_tag and doc_summary, exiting with doc_summary's status.
# shellcheck disable=SC1090,SC2034,SC2329
set -u
TREE=$1 MODE=$2
for module in common ui state sources storage macos asahi linux shared doctor dev; do
  . "$TREE/lib/$module.sh"
done
. "$G2_CANDIDATE/lib/records.sh"
OMB_INTENT=read OMB_PERSIST=0 OMB_ASCII=1 OMB_COLOR=never
# Trace the existing probe seams; keep each original implementation intact.
# shellcheck source=tests/gate2-probe-taps.sh
. "$G2_CANDIDATE/tests/gate2-probe-taps.sh"
platform_init
state_init
ui_init
trap omb_cleanup EXIT
case "$MODE" in
  findings)
    # The shared request preamble above is not Doctor's; record only its reads.
    : >"$G2_PROBES"
    n=0
    exec 3>&1
    ui_tag() {
      n=$((n + 1))
      rec_line row kind doctor key "$n" col "$1" col "$2" col "${3:-}" >&3
    }
    cmd_doctor >/dev/null
    st=$?
    printf '%s %s %s %s\n' "$st" "$DOC_PASS" "$DOC_WARN" "$DOC_FAIL" >"$G2_PROBES.summary"
    ;;
  render)
    while IFS=$'\t' read -r _ _ _ s l d; do
      ui_tag "$(rec_dec "${s#col=}")" "$(rec_dec "${l#col=}")" "$(rec_dec "${d#col=}")"
    done <"$3"
    DOC_PASS=$4 DOC_WARN=$5 DOC_FAIL=$6
    doc_summary
    exit
    ;;
esac
[ "$OMB_INTENT:$OMB_PERSIST" = read:0 ] || exit 88
