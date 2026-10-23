#!/usr/bin/env bash
# Test-only semantic taps on an independently extracted tree's Doctor owner.
# Production never uses this adapter or parses painted Doctor text.
#   findings — the tree's cmd_doctor, its ui_tag arguments as rows on stdout;
#              status and counters in $G2_PROBES.summary; its probes only.
#   render   — typed rows (file $3) and counters ($4..$6) through the tree's
#              own ui_tag and doc_summary, exiting with doc_summary's status.
# shellcheck disable=SC1090,SC2031,SC2034,SC2317,SC2329
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
    # A named M15-C delta: compare the unchanged owner path independently
    # of doc_ssh, whose full findings are tested in the complete capture.
    if [ "${G2_NO_SSH:-0}" = 1 ]; then doc_ssh() { :; }; fi
    cmd_doctor >/dev/null
    st=$?
    owner_summary="$st $DOC_PASS $DOC_WARN $DOC_FAIL"
    if [ "${G2_EXTENSIONS:-0}" = 1 ]; then
      . "$TREE/lib/core.sh"
      . "$TREE/lib/read.sh"
      . "$TREE/lib/health.sh"
      omb_tmp_init || exit 1
      core_health_extensions >&3 || exit 1
      OMB_SESSION_SCOPES=health OMB_SESSION_INTENT=act
      core_rows_snapshot 'agents.mcp' >/dev/null || exit 1
      # M16-report-reads: keep the Doctor/extension probes intact. Independently
      # capture the report's additional observations and all eight report rows.
      G2_PROBES=$G2_PROBES.report
      : >"$G2_PROBES"
      # Doctor's production capture is a subshell; its identity cache does
      # not reach the report. Match that boundary in this independent owner.
      SH_UID='' SH_GID=''
      journey_read "$DOC_PASS $DOC_WARN $DOC_FAIL" >/dev/null || exit 1
      journey_report_build || exit 1
      journey_report_records >"$G2_PROBES.rows" || exit 1
    fi
    printf '%s\n' "$owner_summary" >"${G2_PROBES%.report}.summary"
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
