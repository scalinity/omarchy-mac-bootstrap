#!/usr/bin/env bash
# CI's plan, its evidence and the FULL completeness guard (docs/TESTING.md →
# *CI*). The workflow and tests/test-ci.sh run this; nothing else does.
#
#   tests/ci.sh mode EVENT REF [RETRY_OF]  full, fast or retry
#   tests/ci.sh plan MODE <PATHS           each lane's shards a run selects, as GITHUB_OUTPUT lines
#   tests/ci.sh lint                       tests/ci-manifest.tsv against the repository
#   tests/ci.sh begin LANE SHARD           a shard's evidence file and its lane's skip policy
#   tests/ci.sh shard                      $OMB_LANE $OMB_SHARD's units from the manifest
#   tests/ci.sh units UNIT...              the units named (FAST)
#   tests/ci.sh setup NAME -- CMD...       a step the units depend on, recorded
#   tests/ci.sh steps                      the job's step:NAME units, from $OMB_STEPS
#   tests/ci.sh guard DIR SHA [JOBS]       FULL's completeness guard over DIR's evidence
#   tests/ci.sh jobs REPO RUN ATTEMPT      a run attempt's jobs, as the guard reads them
#   tests/ci.sh retry-signal JOBS SHA MODE GUARD  the verdict's red is runners never acquired alone
#   tests/ci.sh retry REPO RUN SHA         re-run those jobs, once
#
# Evidence is one tab-separated file a shard: header rows (mode, lane, shard,
# sha, github_sha, run, attempt, job, os, arch), then a row for each unit run
# (unit NAME pass|fail EXIT BASH_VERSION SECONDS SUMMARIES), each skip it
# printed (skip NAME TEXT) and each setup step (setup NAME pass|fail EXIT).
# Exit 75 from a setup step is external infrastructure (tests/ci-bash.sh).

CI_REPO=$(cd "$(dirname "$0")/.." && pwd -P)
MANIFEST=${OMB_CI_MANIFEST:-$CI_REPO/tests/ci-manifest.tsv}
TAB=$(printf '\t')

ci_row() {
  local IFS="$TAB"
  if [ -z "${OMB_EVIDENCE:-}" ]; then
    echo "ci.sh: no evidence file (tests/ci.sh begin LANE SHARD)" >&2
    return 1
  fi
  printf '%s\n' "$*" >>"$OMB_EVIDENCE"
}

# The bash under test, chosen as tests/lib.sh chooses it.
ci_tbash() {
  local b=${OMB_TEST_BASH:-bash}
  if [ -x /bin/bash ] && [ "$(uname -s)" = Darwin ]; then b=${OMB_TEST_BASH:-/bin/bash}; fi
  printf '%s' "$b"
}

ci_shellver() {
  # shellcheck disable=SC2016 # expanded by the bash under test
  "$(ci_tbash)" -c 'echo "$BASH_VERSION"' 2>/dev/null || echo unknown
}

# ci_lane LANE FIELD — a lane's field from the manifest (3 runner, 4 os,
# 5 arch, 6 shell, 7 skips, 8 suites).
ci_lane() {
  awk -F'\t' -v l="$1" -v n="$2" '$1 == "lane" && $2 == l { print $n; exit }' "$MANIFEST"
}

ci_mode() {
  case $1 in
    workflow_dispatch) if [ -n "${3:-}" ]; then echo retry; else echo full; fi ;;
    push) if [ "$2" = refs/heads/main ]; then echo full; else echo fast; fi ;;
    *) echo fast ;;
  esac
}

# FULL selects every shard; FAST selects by the paths a change touched, read
# from stdin (a lone * when they are not known). FAST is feedback only: its
# evidence says mode fast, and the guard never accepts it.
ci_plan() {
  local mode=$1 tiers='' fast='' p t n all=0 linux=0 lint=0 frontend=0
  case $mode in
    full) all=1 ;;
    retry) ;;
    fast)
      fast="check:fixtures check:syntax suite:docs suite:static suite:safety suite:ci"
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        case $p in
          frontend/* | release/*) t=frontend ;;
          tests/frontend-*) t="shell frontend" ;;
          *.md | docs/*) t=docs ;;
          .github/* | tests/ci.sh | tests/ci-*) t=workflow ;;
          tests/test-diag.sh | tests/diag-lib.sh) t=shell ;;
          tests/test-*.sh)
            t=suites n=${p#tests/test-}
            fast="$fast suite:${n%.sh}"
            ;;
          tests/diag-*.sh)
            t=suites n=${p#tests/diag-}
            fast="$fast diag:${n%.sh}"
            ;;
          lib/*) t="shell frontend" ;;
          omarchy-bootstrap | data/* | tests/* | bench/*) t=shell ;;
          *) t="shell frontend workflow" ;;
        esac
        tiers="$tiers $t"
      done
      case " $tiers " in *" shell "*) linux=1 ;; esac
      case " $tiers " in *" workflow "* | *" suites "*) lint=1 ;; esac
      case " $tiers " in *" frontend "*) frontend=1 ;; esac
      ;;
    *)
      echo "ci.sh: no mode $mode" >&2
      return 2
      ;;
  esac
  echo "mode=$mode"
  # One JSON array a lane, of its selected shards; steps says the shard runs
  # the lane job's step: units.
  awk -F'\t' -v all="$all" -v linux="$linux" -v lint="$lint" -v frontend="$frontend" '
    $1 == "lane" { lanes[++nl] = $2 }
    $1 == "unit" {
      k = $2 SUBSEP $3
      if (!(k in seen)) { seen[k] = 1; n[$2]++; sh[$2, n[$2]] = $3 }
      if ($4 ~ /^step:/) step[k] = 1
      if ($4 == "check:shellcheck") sc[k] = 1
    }
    END {
      for (i = 1; i <= nl; i++) {
        l = lanes[i]; out = ""
        for (j = 1; j <= n[l]; j++) {
          s = sh[l, j]; k = l SUBSEP s
          if (all || (linux && l == "linux-bash5") || (lint && (k in sc)) || (frontend && l == "frontend"))
            out = out (out == "" ? "" : ",") "{\"shard\":\"" s "\",\"steps\":" ((k in step) ? "true" : "false") "}"
        }
        print l "=[" out "]"
      }
    }' "$MANIFEST"
  # shellcheck disable=SC2086 # unit and tier names have no spaces
  echo "fast=$(printf '%s\n' $fast | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//')"
  # shellcheck disable=SC2086
  echo "tiers=$(printf '%s\n' $tiers | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//')"
}

# The manifest against the repository: every row well formed, every unit
# real, no unit twice in a lane, and each lane running exactly the suites its
# SUITES column names (diag as its units).
ci_lint() {
  local suites='' f n dunits
  for f in "$CI_REPO"/tests/test-*.sh; do
    n=${f##*/test-}
    suites="$suites ${n%.sh}"
  done
  dunits=$(sed -n 's/^UNITS="\(.*\)"$/\1/p' "$CI_REPO/tests/test-diag.sh")
  for n in $dunits; do
    [ -f "$CI_REPO/tests/diag-$n.sh" ] || dunits="$dunits missing:$n"
  done
  awk -F'\t' -v suites="$suites" -v dunits="$dunits" '
    function err(m) { print "manifest: " m; bad++ }
    function glob(p) { gsub(/\*/, ".*", p); gsub(/\?/, ".", p); return "^" p "$" }
    BEGIN {
      ns = split(suites, S, " "); for (i = 1; i <= ns; i++) isS[S[i]] = 1
      nd = split(dunits, D, " "); for (i = 1; i <= nd; i++) { if (D[i] ~ /^missing:/) err("tests/test-diag.sh lists " substr(D[i], 9) ", which has no tests/diag-" substr(D[i], 9) ".sh"); else isD[D[i]] = 1 }
      split("syntax shellcheck fixtures startup trap-comsub", C, " "); for (i in C) isC[C[i]] = 1
    }
    /^#/ || $0 == "" { next }
    $1 == "lane" {
      if (NF != 8) { err("line " NR ": a lane row has 8 fields, this has " NF); next }
      if ($2 in L) err("lane " $2 " is declared twice")
      L[$2] = $8; lanes[++nl] = $2
      next
    }
    $1 == "unit" {
      if (NF != 4) { err("line " NR ": a unit row has 4 fields, this has " NF); next }
      if (!($2 in L)) err("line " NR ": lane " $2 " is not declared")
      if ($4 !~ /^(suite|diag|check|step):[a-z0-9][a-z0-9-]*$/) { err("line " NR ": " $4 " is not a unit name"); next }
      k = $2 SUBSEP $4
      if (k in U) err("duplicate entry: " $2 " runs " $4 " in " U[k] " and " $3 "; a unit runs exactly once a lane")
      U[k] = $3
      kind = substr($4, 1, index($4, ":") - 1); name = substr($4, index($4, ":") + 1)
      if (kind == "suite" && (!(name in isS) || name == "diag")) err($2 " " $3 ": " $4 " is not a tests/test-*.sh suite (diag runs as diag:UNIT)")
      if (kind == "diag" && !(name in isD)) err($2 " " $3 ": " $4 " is not a unit of tests/test-diag.sh")
      if (kind == "check" && !(name in isC)) err($2 " " $3 ": " $4 " is not a check tests/ci.sh runs")
      if (kind == "step") { if (($2 in stepshard) && stepshard[$2] != $3) err("lane " $2 " has step units in " stepshard[$2] " and " $3 "; one shard a lane runs in its own job"); stepshard[$2] = $3 }
      if (kind == "suite" || kind == "diag") have[$2, $4] = 1
      next
    }
    { err("line " NR ": unknown row " $1) }
    END {
      for (i = 1; i <= nl; i++) {
        l = lanes[i]; np = split(L[l], P, " ")
        for (j = 1; j <= ns; j++) {
          s = S[j]; want = 0
          for (q = 1; q <= np; q++) if (P[q] == "*" || s ~ glob(P[q])) want = 1
          if (!want) continue
          if (s == "diag") { for (d = 1; d <= nd; d++) if (D[d] in isD) need[l, "diag:" D[d]] = 1 }
          else need[l, "suite:" s] = 1
        }
      }
      for (k in need) if (!(k in have)) { split(k, x, SUBSEP); err("lane " x[1] " must run " x[2] " (its SUITES name it) and no shard does") }
      for (k in have) if (!(k in need)) { split(k, x, SUBSEP); err("lane " x[1] " runs " x[2] ", which its SUITES do not name") }
      if (bad) exit 1
      print "manifest: ok (" nl " lanes)"
    }' "$MANIFEST"
}

ci_begin() {
  local lane=$1 shard=$2 skips
  OMB_EVIDENCE=${OMB_EVIDENCE:-${RUNNER_TEMP:?}/omb-evidence.tsv}
  skips=$(ci_lane "$lane" 7)
  [ "$skips" = none ] && skips=''
  : >"$OMB_EVIDENCE" || return 1
  echo "# omb-ci-evidence 1" >>"$OMB_EVIDENCE"
  ci_row mode "${OMB_CI_MODE:-unset}"
  ci_row lane "$lane"
  ci_row shard "$shard"
  ci_row sha "$(git -C "$CI_REPO" rev-parse HEAD 2>/dev/null)"
  ci_row github_sha "${GITHUB_SHA:-unset}"
  ci_row run "${GITHUB_RUN_ID:-local}"
  ci_row attempt "${GITHUB_RUN_ATTEMPT:-0}"
  ci_row job "${GITHUB_JOB:-local}"
  ci_row os "$(uname -s)"
  ci_row arch "$(uname -m)"
  if [ -n "${GITHUB_ENV:-}" ]; then
    {
      echo "OMB_EVIDENCE=$OMB_EVIDENCE"
      echo "OMB_LANE=$lane"
      echo "OMB_SHARD=$shard"
      echo "OMB_STRICT_SKIPS=1"
      echo "OMB_ALLOWED_SKIP_RE=$skips"
    } >>"$GITHUB_ENV"
  fi
  echo "evidence: $OMB_EVIDENCE · $lane $shard · skips allowed: ${skips:-none}"
}

# ci_capture TYPE NAME CMD... — runs CMD with its output shown and kept, and
# records a row of TYPE (unit or setup).
ci_capture() {
  local type=$1 name=$2 out rc start sums
  shift 2
  out=$(mktemp "${TMPDIR:-/tmp}/omb-ci.XXXXXX") || return 1
  start=$(date +%s)
  echo "== $type $name"
  {
    "$@"
    echo "$?" >"$out.rc"
  } 2>&1 | tee "$out"
  rc=$(cat "$out.rc" 2>/dev/null)
  rc=${rc:-1}
  if [ "$type" = setup ]; then
    if [ "$rc" = 0 ]; then ci_row setup "$name" pass 0; else ci_row setup "$name" fail "$rc"; fi
  else
    sums=$(grep -E '^[A-Za-z0-9-]+: [0-9]+ passed, [0-9]+ failed, [0-9]+ skipped$' "$out" | awk '{ printf "%s%s", s, $0; s = "; " }')
    if [ "$rc" = 0 ]; then
      ci_row unit "$name" pass 0 "$(ci_shellver)" "$(($(date +%s) - start))" "${sums:--}"
    else
      ci_row unit "$name" fail "$rc" "$(ci_shellver)" "$(($(date +%s) - start))" "${sums:--}"
    fi
    sed -n 's/^  skip //p' "$out" | while IFS= read -r p; do ci_row skip "$name" "$p"; done
  fi
  rm -f "$out" "$out.rc"
  return "$rc"
}

ci_fixtures() {
  tests/fixtures/generate.sh || return 1
  git diff --exit-code -- tests/fixtures || return 1
  test -z "$(git status --porcelain -- tests/fixtures)"
}

# macOS's sh is bash 3.2 in POSIX mode. A green exit status is not enough:
# stderr must be empty, the version exact, and a command whose code loads
# after lib/shared.sh must run.
ci_startup() (
  set -eu
  tmp=$(mktemp -d)
  want="omarchy-bootstrap $(sed -n 's/^OMB_VERSION="\(.*\)"$/\1/p' lib/common.sh)"
  for shell in sh /bin/bash; do
    echo "== $shell"
    OMB_STATE_DIR=$tmp/state "$shell" ./omarchy-bootstrap --version >"$tmp/out" 2>"$tmp/err"
    if [ -s "$tmp/err" ]; then
      echo "stderr from --version:"
      cat "$tmp/err"
      exit 1
    fi
    if [ "$(cat "$tmp/out")" != "$want" ]; then
      echo "stdout from --version: $(cat "$tmp/out")"
      exit 1
    fi
    echo "--version: $(cat "$tmp/out")"
    # doctor lives in lib/doctor.sh, which loads after lib/shared.sh.
    OMB_STATE_DIR=$tmp/state OMB_FIXTURE=$PWD/tests/fixtures/linux-omarchy-installed \
      "$shell" ./omarchy-bootstrap doctor --ascii >"$tmp/out" 2>"$tmp/err"
    if [ -s "$tmp/err" ]; then
      echo "stderr from doctor:"
      cat "$tmp/err"
      exit 1
    fi
    grep -F '[PASS] Omarchy 4' "$tmp/out"
    test ! -e "$tmp/state"
  done
)

# The upstream defect without this tool: none in 5.3.15; the runner's 5.2
# shown beside it.
ci_trap_comsub() {
  tests/bash-trap-comsub.sh "${OMB_TEST_BASH:?}" 20000 || return 1
  tests/bash-trap-comsub.sh /usr/bin/bash 20000 || echo "the runner's Bash 5.2 lost traps (the upstream defect)"
}

ci_exec() {
  local tb
  tb=$(ci_tbash)
  case $1 in
    suite:diag)
      echo "ci.sh: tests/test-diag.sh runs as its units, diag:NAME"
      return 2
      ;;
    suite:*) "$tb" "tests/test-${1#suite:}.sh" ;;
    diag:*) OMB_DIAG_UNITS=${1#diag:} "$tb" tests/test-diag.sh ;;
    check:syntax) tests/run.sh --syntax ;;
    check:shellcheck) tests/run.sh --shellcheck ;;
    check:fixtures) ci_fixtures ;;
    check:startup) ci_startup ;;
    check:trap-comsub) ci_trap_comsub ;;
    *)
      echo "ci.sh: $1 is not a unit this script runs"
      return 2
      ;;
  esac
}

# Every unit runs, as tests/run.sh runs every suite, and the status is
# whether all passed.
ci_units() {
  local u status=0
  cd "$CI_REPO" || return 1
  for u in "$@"; do
    ci_capture unit "$u" ci_exec "$u" || status=1
  done
  rm -rf tests/.tmp
  return "$status"
}

ci_shard() {
  local lane=${OMB_LANE:?} shard=${OMB_SHARD:?} re v units
  re=$(ci_lane "$lane" 6)
  v=$(ci_shellver)
  if [ -z "$re" ] || ! printf '%s\n' "$v" | grep -Eq "$re"; then
    echo "the $lane lane runs under a bash matching ${re:-(no lane)}; $(ci_tbash) is $v, so no unit runs"
    ci_row setup shell fail 1
    return 1
  fi
  units=$(awk -F'\t' -v l="$lane" -v s="$shard" '$1 == "unit" && $2 == l && $3 == s && $4 !~ /^step:/ { print $4 }' "$MANIFEST")
  if [ -z "$units" ]; then
    echo "ci.sh: the manifest gives $lane $shard no unit this script runs"
    return 1
  fi
  echo "$lane $shard under $(ci_tbash) ($v): $(printf '%s' "$units" | tr '\n' ' ')"
  # shellcheck disable=SC2086 # unit names have no spaces
  ci_units $units
}

# The job's step:NAME units: each workflow step whose id is unit-NAME, from
# the steps context (toJSON(steps) in $OMB_STEPS). A step that never ran
# leaves no row, and the guard reports it as not executed.
ci_steps() {
  local v
  v=$(ci_shellver)
  printf '%s' "${OMB_STEPS:?}" |
    jq -r 'to_entries[] | select(.key | startswith("unit-")) | select(.value.outcome != "skipped") | [("step:" + (.key | ltrimstr("unit-"))), .value.outcome] | @tsv' |
    while IFS="$TAB" read -r name outcome; do
      if [ "$outcome" = success ]; then ci_row unit "$name" pass 0 "$v" - -; else ci_row unit "$name" fail 1 "$v" - -; fi
    done
}

# A run attempt's jobs, a line each: id, name, status, conclusion, runner,
# steps, GitHub's annotations on a job that did not pass, and the steps that
# did not pass (NAME=CONCLUSION).
ci_jobs() {
  gh api --paginate "repos/$1/actions/runs/$2/attempts/$3/jobs?per_page=100" \
    --jq '.jobs[] | [.id, .name, .status, (.conclusion // "-"), (.runner_id // 0), (.steps // [] | length), ([.steps // [] | .[] | select(.conclusion != "success" and .conclusion != "skipped") | "\(.name)=\(.conclusion // "-")"] | join(" | ") | if . == "" then "-" else . end)] | @tsv' |
    while IFS="$TAB" read -r id name status concl rid steps bad; do
      note=-
      case $concl in
        success | skipped | -) ;;
        *) note=$(gh api "repos/$1/check-runs/$id/annotations" --jq '[.[].message] | join(" | ")' 2>/dev/null | tr '\t\n' '  ') ;;
      esac
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$status" "$concl" "$rid" "$steps" "${note:--}" "$bad"
    done
}

# The verdict job's own verdict step in each mode, as ci.yml names it, and the
# signal it leaves on itself when its red is runners never acquired alone.
CI_GUARD_STEP='FULL completeness guard (tests/ci-manifest.tsv)'
CI_FAST_STEP='FAST is not acceptance evidence'
CI_SIGNAL='retry: red only from runners never acquired'

# ci_judge WHO JOBS SHA MODE [NR] — the one automatic retry's rule over a
# run's first attempt (JOBS, from tests/ci.sh jobs). A runner never acquired:
# the job ended cancelled or failed with no runner, no step, and GitHub's own
# annotation saying so (run 37371989145). Every job that did not pass must be
# one, but the verdict job, whose red must follow from them alone.
# WHO verdict: the verdict job asks at its end, still running; in FULL its
# guard found nothing else (NR, the guard's count of them). Its answer, the
# signal, names MODE, SHA and those jobs. WHO controller: the run has
# completed, and the verdict job ended failed on a runner of its own, in its
# own verdict step alone, carrying that signal for exactly these jobs.
ci_judge() {
  awk -F'\t' -v who="$1" -v sha="$3" -v mode="$4" -v nr="${5:-}" \
    -v gstep="$CI_GUARD_STEP" -v fstep="$CI_FAST_STEP" -v sig="$CI_SIGNAL" '
    function no(m) { other++; print m }
    $2 ~ /^(FULL acceptance|FAST) · / { nv++; vs = $3; vc = $4; vr = $5; vk = $6; va = $7; vb = $8; next }
    $4 == "success" || $4 == "skipped" { next }
    $3 == "completed" && ($4 == "cancelled" || $4 == "failure") && $5 == 0 && $6 == 0 && $7 ~ /was not acquired by Runner/ {
      acq++; got[$1] = 1; ids = ids (ids == "" ? "" : ",") $1
      print "runner never acquired: " $2
      next
    }
    { no("not a runner-acquisition non-run: " $2 " (" $3 "/" $4 ")") }
    END {
      if (mode != "full" && mode != "fast") no("no mode " mode)
      if (nv != 1) no("the attempt has " nv + 0 " verdict jobs, not one")
      else if (who == "verdict") {
        if (vc != "-") no("the verdict job has already ended " vc)
        if (mode == "full" && nr != acq) no("the guard found more than the runners never acquired, or did not finish")
      } else if (vs != "completed" || vc != "failure" || vr == 0 || vk == 0) {
        no("the verdict job ended " vs "/" vc ", not failed on a runner of its own")
      } else if (vb != (mode == "full" ? gstep : fstep) "=failure") {
        no("the verdict job went wrong in " vb ", not in its own verdict step alone")
      } else {
        n = split(va, M, " [|] ")
        for (i = 1; i <= n; i++) {
          sub(/ +$/, "", M[i])
          if (index(M[i], sig " · ") == 1) { ns++; s = substr(M[i], length(sig " · ") + 1) }
        }
        if (ns != 1) no("the verdict job carries " ns + 0 " retry signals, not one")
        else {
          k = split(s, P, " · ")
          same = (k == 3 && P[1] == mode && P[2] == sha && substr(P[3], 1, 5) == "jobs ")
          if (same) {
            m = split(substr(P[3], 6), Q, ",")
            same = (m == acq)
            for (j = 1; j <= m; j++) { if (!(Q[j] in got) || (Q[j] in dup)) same = 0; dup[Q[j]] = 1 }
          }
          if (!same) no("the verdict job signals " s ", not " mode " · " sha " · jobs " ids)
        }
      }
      if (acq > 0 && other == 0) {
        print "eligible for the one automatic retry"
        if (who == "verdict") print "::notice::" sig " · " mode " · " sha " · jobs " ids
        exit 0
      }
      print "not eligible for an automatic retry"
      exit 1
    }' "$2"
}

# The verdict job's half, its last step: succeeds, having left the signal on
# the verdict job as a notice, only when its red is runners never acquired
# alone; the workflow then dispatches the controller. GUARD is the FULL
# guard's output.
ci_retry_signal() {
  local nr=''
  if [ "$3" = full ]; then
    nr=$(sed -n 's/^retry: every problem is a runner never acquired (\([0-9][0-9]*\))$/\1/p' "$4" 2>/dev/null)
  fi
  ci_judge verdict "$1" "$2" "$3" "$nr"
}

# The controller, in a run of its own: GitHub re-runs a job only once its run
# has completed. RUN must be this repository's ci.yml, from a push or a
# dispatch (never a pull request), at SHA, in its first attempt; its mode is
# the one its event and branch give.
ci_retry() {
  local repo=$1 run=$2 sha=$3 n=0 info id of from path event branch head attempt jobs
  while [ "$(gh api "repos/$repo/actions/runs/$run" --jq .status)" != completed ]; do
    n=$((n + 1))
    if [ "$n" -gt 160 ]; then
      echo "run $run did not complete; nothing re-run"
      return 1
    fi
    sleep 15
  done
  info=$(gh api "repos/$repo/actions/runs/$run" --jq '[.id, .repository.full_name, .head_repository.full_name, .path, .event, .head_branch, .head_sha, .run_attempt] | map(. // "-") | @tsv') || return 1
  IFS="$TAB" read -r id of from path event branch head attempt <<EOF
$info
EOF
  if [ "$id" != "$run" ] || [ "$of" != "$repo" ] || [ "$from" != "$repo" ]; then
    echo "run $run is $of's run $id, from $from, not $repo's; nothing re-run"
    return 1
  fi
  if [ "$path" != .github/workflows/ci.yml ]; then
    echo "run $run is of $path, not .github/workflows/ci.yml; nothing re-run"
    return 1
  fi
  case $event in
    push | workflow_dispatch) ;;
    *)
      echo "run $run came from $event; only a push or a dispatch is retried; nothing re-run"
      return 1
      ;;
  esac
  if [ "$head" != "$sha" ]; then
    echo "run $run is at $head, not $sha; nothing re-run"
    return 1
  fi
  if [ "$attempt" != 1 ]; then
    echo "run $run is at attempt $attempt: its one automatic retry is spent; nothing re-run"
    return 0
  fi
  jobs=$(mktemp) || return 1
  ci_jobs "$repo" "$run" 1 >"$jobs" || return 1
  if ! ci_judge controller "$jobs" "$sha" "$(ci_mode "$event" "refs/heads/$branch")"; then
    echo "nothing re-run"
    return 0
  fi
  gh api -X POST "repos/$repo/actions/runs/$run/rerun-failed-jobs" >/dev/null || return 1
  echo "run $run: the jobs whose runner was never acquired run again as attempt 2, the guard after them"
}

# FULL's completeness guard: DIR's evidence files against the manifest, at
# SHA. JOBS (tests/ci.sh jobs) names why a shard left no evidence. A suite or
# diagnostics unit's skipped count, summed over its summary lines, is its
# number of skip rows, and is 0 where its lane allows no skip. When runners
# never acquired are every problem, it says so (tests/ci.sh retry-signal).
ci_guard() {
  local dir=$1 sha=$2 jobs=${3:-/dev/null} f
  ci_lint || {
    echo "verdict: RED · the manifest does not hold"
    return 1
  }
  set --
  while IFS= read -r f; do
    [ -n "$f" ] && set -- "$@" "$f"
  done <<EOF
$(find "$dir" -type f -name '*.tsv' 2>/dev/null)
EOF
  awk -F'\t' -v sha="$sha" '
    function problem(kind, m) { P[++np] = kind " · " m; K[kind]++ }
    function jobkey(name,   i, a) {
      i = index(name, " · "); if (!i) return ""
      a = substr(name, 1, i - 1); name = substr(name, i + length(" · "))
      i = index(name, " · ")
      return a SUBSEP (i ? substr(name, 1, i - 1) : name)
    }
    FILENAME == ARGV[1] {
      if (/^#/ || $0 == "") next
      if ($1 == "lane") { Los[$2] = $4; Lar[$2] = $5; Lsh[$2] = $6; Lsk[$2] = $7; nl++ }
      if ($1 == "unit") {
        k = $2 SUBSEP $4; Ush[k] = $3; uo[++nu] = k
        sk = $2 SUBSEP $3; if (!(sk in Sd)) { Sd[sk] = 1; so[++ns] = sk }; Sn[sk]++
      }
      next
    }
    FILENAME == ARGV[2] {
      jk = jobkey($2); if (jk == "") next
      Jc[jk] = $4; Js[jk] = $3
      Jacq[jk] = ($3 == "completed" && ($4 == "cancelled" || $4 == "failure") && $5 == 0 && $6 == 0 && $7 ~ /was not acquired by Runner/)
      next
    }
    FNR == 1 { nf++; Fn[nf] = FILENAME }
    /^#/ || $0 == "" { next }
    $1 ~ /^(mode|lane|shard|sha|github_sha|run|attempt|job|os|arch)$/ { H[nf, $1] = $2; next }
    {
      lane = H[nf, "lane"]; shard = H[nf, "shard"]; at = lane " · " shard
      if (lane == "" || shard == "") { problem("integrity", Fn[nf] ": a " $1 " row before the lane and shard"); next }
    }
    $1 == "unit" {
      k = lane SUBSEP $2; Fu[nf]++
      if (Fv[nf] == "") Fv[nf] = $5
      if (k in Seen) {
        a = Seen[k]; b = shard
        if (b < a) { a = shard; b = Seen[k] }
        problem("integrity", "duplicate: " lane " · " $2 " ran in " a " and in " b)
      }
      Seen[k] = shard
      if (!(k in Ush)) problem("integrity", "unexpected: " at " · " $2 " is not in the manifest for " lane)
      else if (Ush[k] != shard) problem("integrity", "wrong shard: " at " · " $2 " belongs to " Ush[k])
      if ($3 != "pass" || $4 != "0") {
        if ($4 == "75") problem("infrastructure", "external infrastructure: " at " · " $2 " (exit 75)")
        else problem("failure", "executed failure: " at " · " $2 " (exit " $4 ")")
      } else Fp[nf]++
      if ($5 !~ Lsh[lane]) problem("integrity", "wrong shell: " at " · " $2 " ran under bash " $5 "; " lane " needs " Lsh[lane])
      if ($2 ~ /^(suite|diag):/) {
        uk = nf SUBSEP $2
        if (!(uk in Rep)) { ro[++nro] = uk; Rat[uk] = at; Rl[uk] = lane; Rep[uk] = 0 }
        if ($7 == "" || $7 == "-") problem("integrity", "no summary: " at " · " $2 " printed no \"N passed, N failed, N skipped\" line")
        n = split($7, sm, "; ")
        for (i = 1; i <= n; i++) {
          if (sm[i] !~ / 0 failed, /) problem("failure", "executed failure: " at " · " $2 " reports " sm[i])
          if (sm[i] ~ /^[A-Za-z0-9-]+: [0-9]+ passed, [0-9]+ failed, [0-9]+ skipped$/) {
            sv = sm[i]; sub(/ skipped$/, "", sv); sub(/.* /, "", sv); Rep[uk] += sv
          } else if ($7 != "" && $7 != "-") problem("integrity", "unreadable summary: " at " · " $2 " reports " sm[i])
        }
      }
      next
    }
    $1 == "skip" {
      Fs[nf]++
      if (Lsk[lane] == "none" || Lsk[lane] == "" || $3 !~ Lsk[lane]) problem("integrity", "undeclared skip: " at " · " $2 ": " $3)
      if ($2 ~ /^(suite|diag):/) {
        uk = nf SUBSEP $2
        if (!(uk in Rep)) { ro[++nro] = uk; Rat[uk] = at; Rl[uk] = lane; Rep[uk] = 0 }
        Rows[uk]++
      }
      next
    }
    $1 == "setup" {
      if ($3 != "pass") {
        if ($4 == "75") problem("infrastructure", "source acquisition / external infrastructure: " at " · " $2 " exhausted every origin (exit 75)")
        else problem("failure", "setup failed: " at " · " $2 " (exit " $4 ")")
      }
      next
    }
    { problem("integrity", Fn[nf] ": unknown row " $1) }
    END {
      for (f = 1; f <= nf; f++) {
        lane = H[f, "lane"]; shard = H[f, "shard"]; at = lane " · " shard; sk = lane SUBSEP shard
        if (H[f, "mode"] != "full") problem("integrity", "not FULL evidence: " at " says mode " H[f, "mode"])
        if (H[f, "sha"] != sha) problem("integrity", "wrong SHA: " at " checked out " H[f, "sha"])
        if (H[f, "github_sha"] != sha) problem("integrity", "wrong SHA: " at " ran for " H[f, "github_sha"])
        if (!(sk in Sd)) { problem("integrity", "unexpected: " at " is not a shard of the manifest"); continue }
        if (sk in Have) problem("integrity", "duplicate: two evidence files for " at)
        Have[sk] = f
        if (H[f, "os"] != Los[lane] || H[f, "arch"] != Lar[lane]) problem("integrity", "wrong platform: " at " ran on " H[f, "os"] " " H[f, "arch"] "; " lane " is " Los[lane] " " Lar[lane])
      }
      for (i = 1; i <= nu; i++) {
        k = uo[i]; split(k, x, SUBSEP); sk = x[1] SUBSEP Ush[k]
        if ((k in Seen) || !(sk in Have)) continue
        problem("missing", "not executed: " x[1] " · " Ush[k] " · " x[2])
      }
      for (i = 1; i <= nro; i++) {
        uk = ro[i]; split(uk, x, SUBSEP); l = Rl[uk]
        if ((Lsk[l] == "none" || Lsk[l] == "") && Rep[uk] > 0) problem("integrity", "skipped where no skip is allowed: " Rat[uk] " · " x[2] " reports " Rep[uk] " skipped")
        if (Rep[uk] != Rows[uk] + 0) problem("integrity", "skip count: " Rat[uk] " · " x[2] " reports " Rep[uk] " skipped and gives " Rows[uk] + 0 " skip reasons")
      }
      printf "FULL acceptance guard · candidate %s\n", sha
      printf "manifest: %d lanes · %d shards · %d units\n", nl, ns, nu
      for (i = 1; i <= ns; i++) {
        sk = so[i]; split(sk, x, SUBSEP); at = x[1] " · " x[2]
        if (!(sk in Have)) {
          if (Jacq[sk]) { problem("infrastructure", "runner never acquired (infrastructure non-run): " at " left no evidence"); nrun++ }
          else if (sk in Jc) problem("missing", "missing shard: " at " left no evidence (job " Js[sk] "/" Jc[sk] ")")
          else problem("missing", "missing shard: " at " left no evidence")
          printf "  MISSING  %s · 0/%d units\n", at, Sn[sk]
          continue
        }
        f = Have[sk]
        printf "  %-7s  %s · %d/%d units passed · %s %s · bash %s · %d skips\n", (Fp[f] == Sn[sk] && Fu[f] == Sn[sk] ? "ok" : "FAIL"), at, Fp[f], Sn[sk], H[f, "os"], H[f, "arch"], Fv[f], Fs[f]
      }
      if (np == 0) {
        printf "verdict: GREEN · every unit of the manifest executed and passed exactly once at %s\n", sha
        exit 0
      }
      print "problems:"
      for (i = 1; i <= np; i++) print "  " P[i]
      if (nrun == np) print "retry: every problem is a runner never acquired (" nrun ")"
      printf "verdict: RED · %d problems · executed failures %d · infrastructure %d · missing %d · integrity %d\n", np, K["failure"], K["infrastructure"], K["missing"], K["integrity"]
      exit 1
    }' "$MANIFEST" "$jobs" "$@"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
  mode) ci_mode "$@" ;;
  plan) ci_plan "$@" ;;
  lint) ci_lint ;;
  begin) ci_begin "$@" ;;
  shard) ci_shard ;;
  units) ci_units "$@" ;;
  setup)
    name=$1
    shift
    [ "${1:-}" = -- ] && shift
    ci_capture setup "$name" "$@"
    ;;
  steps) ci_steps ;;
  guard) ci_guard "$@" ;;
  jobs) ci_jobs "$@" ;;
  retry-signal) ci_retry_signal "$@" ;;
  retry) ci_retry "$@" ;;
  *)
    sed -n '5,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
