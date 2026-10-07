#!/usr/bin/env bash
# CI's plan, evidence and FULL completeness guard (tests/ci.sh), its manifest
# (tests/ci-manifest.tsv) and the GNU Bash source acquisition
# (tests/ci-bash.sh), all offline: FAST never stands in for FULL; the
# manifest is the repository's suites; the guard refuses a missing shard or
# unit, a duplicate, another SHA, an undeclared skip or a skipped count its
# skip rows do not match, another shell or platform, FAST evidence and an
# executed failure, and tells a runner never acquired and an exhausted source
# download from a failure; only runners never acquired are retried, once,
# when the verdict's red follows from them alone, on this repository's ci.yml
# run at the SHA, as GitHub's metadata, read whole and each field of its
# type, proves; and a Bash source is used only with its pinned digest, from
# an origin or from the cache.
# shellcheck disable=SC2015 # ok/fail always return 0
# shellcheck disable=SC2016 # awk programs, expanded by awk
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-ci"
T=$(t_tmp)
M="$REPO/tests/ci-manifest.tsv"
SHA=0123456789abcdef0123456789abcdef01234567
NOTACQ="The job was not acquired by Runner of type hosted even after multiple attempts"
TAB=$(printf '\t')

# Nothing here writes into the CI job running it: no GITHUB_ENV, and every
# evidence file is named.
ci() { GITHUB_ENV='' "$T_BASH" "$REPO/tests/ci.sh" "$@"; }
digest() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }
# edit FILE AWK — FILE rewritten through an awk program (tab-separated).
edit() { awk -F'\t' -v OFS='\t' "$2" "$1" >"$1.new" && mv "$1.new" "$1"; }

# --- ci-mode-*: FULL only by hand or on main --------------------------------
assert_eq "$(ci mode push refs/heads/ci-throughput)" fast "ci-mode-push: a branch push is FAST"
assert_eq "$(ci mode pull_request refs/pull/7/merge)" fast "ci-mode-pr: a pull request is FAST"
assert_eq "$(ci mode push refs/heads/main)" full "ci-mode-main: a push to main is FULL"
assert_eq "$(ci mode workflow_dispatch refs/heads/ci-throughput '')" full "ci-mode-dispatch: a dispatch is FULL"
assert_eq "$(ci mode workflow_dispatch refs/heads/ci-throughput 37371989145)" retry "ci-mode-retry: a dispatch naming a run is the retry controller"

# --- ci-plan-*: FULL selects every shard, FAST never a FULL-only lane --------
count() { printf '%s\n' "$1" | grep -o "$2" | wc -l | tr -d ' '; }
shards=$(awk -F'\t' '$1 == "unit" && !s[$2 " " $3]++ { n++ } END { print n }' "$M")
stepped=$(awk -F'\t' '$1 == "unit" && $4 ~ /^step:/ && !s[$2]++ { n++ } END { print n }' "$M")
out=$(echo '*' | ci plan full)
assert_eq "$(count "$out" '"shard":')" "$shards" "ci-plan-full: every shard of every lane runs"
assert_eq "$(count "$out" '"steps":true')" "$stepped" "ci-plan-full: and in each lane with step units, one shard runs them"
printf '%s\n' "$out" | grep -qx 'fast=' && ok || fail "ci-plan-full: and no FAST checks"
for paths in 'docs/TESTING.md' 'lib/core.sh' 'tests/test-cli.sh' '.github/workflows/ci.yml' 'frontend/src/main.rs' '.gitignore'; do
  out=$(printf '%s\n' "$paths" | ci plan fast)
  for lane in macos-bash32 target-bash53 frontend-linux-arm64 frontend-macos-arm64; do
    printf '%s\n' "$out" | grep -qx "$lane=\[\]" && ok || fail "ci-plan-fast-not-full: a FAST run for $paths selects no $lane shard"
  done
  assert_contains "$out" "fast=check:fixtures check:syntax suite:docs suite:static suite:safety suite:ci" "ci-plan-fast: $paths gets the fast checks"
done
out=$(printf 'docs/TESTING.md\nREADME.md\n' | ci plan fast)
assert_eq "$(count "$out" '"shard":')" 0 "ci-plan-fast-docs: documents alone run no shard"
out=$(printf 'lib/core.sh\n' | ci plan fast)
assert_contains "$out" 'linux-bash5=[{"shard":"l0","steps":false},{"shard":"l1","steps":false},{"shard":"l2","steps":false},{"shard":"l3","steps":false}]' "ci-plan-fast-shell: product code runs every Linux bash 5 shard"
assert_contains "$out" 'frontend=[{"shard":"f1","steps":true}]' "ci-plan-fast-shell: and the frontend's checks against the core"
out=$(printf 'tests/test-cli.sh\ntests/diag-temp.sh\n' | ci plan fast)
assert_contains "$out" "suite:cli diag:temp" "ci-plan-fast-suites: a changed suite or unit runs itself"
assert_eq "$(count "$out" '"shard":') $(count "$out" '"shard":"l0"')" "1 1" "ci-plan-fast-suites: with ShellCheck, nothing more"
out=$(printf '.gitignore\n' | ci plan fast)
assert_contains "$out" "tiers=shell frontend workflow" "ci-plan-fast-unknown: a path no tier names runs every FAST tier"
out=$(echo '*' | ci plan retry)
assert_eq "$(count "$out" '"shard":')" 0 "ci-plan-retry: the retry controller runs no shard"

# --- ci-workflow-*: each lane is one job of the workflow --------------------
W="$REPO/.github/workflows/ci.yml"
wf=$(awk '
  /^jobs:/ { j = 1; next }
  j && /^  [a-z0-9-]+:$/ { job = $1; sub(/:$/, "", job); next }
  job == "" { next }
  /^    runs-on: / { print "runs", job, $2 }
  /^      - id: unit-/ { s = $3; sub(/^unit-/, "", s); print "step", job, s }
  /tests\/ci\.sh begin / { for (i = 1; i < NF; i++) if ($i == "begin") print "begin", job, $(i + 1) }
  /^          name: evidence-/ { print "upload", job }
' "$W")
needs=$(sed -n 's/^    needs: \[\(.*\)\]$/\1/p' "$W" | tr -d ' ')
lanes=$(awk -F'\t' '$1 == "lane" { print $2 }' "$M")
for lane in $lanes; do
  runner=$(awk -F'\t' -v l="$lane" '$1 == "lane" && $2 == l { print $3 }' "$M")
  assert_eq "$(printf '%s\n' "$wf" | awk -v l="$lane" '$1 == "runs" && $2 == l { print $3 }')" "$runner" "ci-workflow-runner: the $lane job runs on the manifest's runner"
  assert_eq "$(printf '%s\n' "$wf" | awk -v l="$lane" '$1 == "begin" && $2 == l { print $3 }')" "$lane" "ci-workflow-evidence: the $lane job's evidence names its lane"
  assert_eq "$(printf '%s\n' "$wf" | awk -v l="$lane" '$1 == "upload" && $2 == l' | wc -l | tr -d ' ')" 1 "ci-workflow-evidence: the $lane job uploads it"
  case ",$needs," in
    *",$lane,"*) ok ;;
    *) fail "ci-workflow-verdict: the verdict waits for the $lane job" ;;
  esac
  diff=$({
    awk -F'\t' -v l="$lane" '$1 == "unit" && $2 == l && $4 ~ /^step:/ { print "m", substr($4, 6) }' "$M"
    printf '%s\n' "$wf" | awk -v l="$lane" '$1 == "step" && $2 == l { print "w", $3 }'
  } | awk '{ c[$2] = c[$2] $1 } END { for (k in c) if (c[k] != "mw") print k " (" c[k] ")" }')
  assert_eq "$diff" "" "ci-workflow-steps: the $lane job's unit- steps are exactly its step units in the manifest"
done

# --- ci-manifest-*: the manifest is the repository's suites ------------------
assert_eq "$(ci lint)" "manifest: ok (6 lanes)" "ci-manifest-ok: every lane runs exactly the suites it names"
for s in "$REPO"/tests/test-*.sh; do
  n=${s##*/test-}
  n=${n%.sh}
  [ "$n" = diag ] && continue
  for lane in macos-bash32 linux-bash5; do
    [ "$(awk -F'\t' -v l="$lane" -v u="suite:$n" '$1 == "unit" && $2 == l && $4 == u' "$M" | wc -l | tr -d ' ')" = 1 ] && ok ||
      fail "ci-manifest-suites: $lane runs tests/test-$n.sh exactly once"
  done
done
dunits=$(sed -n 's/^UNITS="\(.*\)"$/\1/p' "$REPO/tests/test-diag.sh")
for u in $dunits; do
  for lane in macos-bash32 linux-bash5 target-bash53 frontend-linux-arm64; do
    [ "$(awk -F'\t' -v l="$lane" -v u="diag:$u" '$1 == "unit" && $2 == l && $4 == u' "$M" | wc -l | tr -d ' ')" = 1 ] && ok ||
      fail "ci-manifest-diag: $lane runs the diagnostics unit $u exactly once"
  done
done
lint() { # NAME AWK — the lint of a manifest rewritten by AWK; sets out and rc
  awk -F'\t' -v OFS='\t' "$2" "$M" >"$T/$1.tsv"
  out=$(OMB_CI_MANIFEST=$T/$1.tsv ci lint)
  rc=$?
}
lint drop '!($1 == "unit" && $2 == "macos-bash32" && $4 == "suite:records")'
assert_rc "$rc" 1 "ci-manifest-missing: a suite no shard runs"
assert_contains "$out" "lane macos-bash32 must run suite:records" "ci-manifest-missing: is named"
lint dup '{ print } $1 == "unit" && $2 == "linux-bash5" && $4 == "suite:cli" { $3 = "l3"; print }'
assert_rc "$rc" 1 "ci-manifest-duplicate: a unit twice in a lane"
assert_contains "$out" "duplicate entry: linux-bash5 runs suite:cli in l1 and l3" "ci-manifest-duplicate: is named"
lint nosuite '{ print } END { print "unit", "linux-bash5", "l1", "suite:nope" }'
assert_contains "$out" "suite:nope is not a tests/test-*.sh suite" "ci-manifest-unknown: a suite with no file"
lint whole '{ print } END { print "unit", "linux-bash5", "l1", "suite:diag" }'
assert_contains "$out" "suite:diag is not a tests/test-*.sh suite (diag runs as diag:UNIT)" "ci-manifest-diag-whole: diagnostics run as units"
lint nodiag '{ print } END { print "unit", "linux-bash5", "l1", "diag:nope" }'
assert_contains "$out" "diag:nope is not a unit of tests/test-diag.sh" "ci-manifest-unknown: a diagnostics unit test-diag.sh does not list"
lint steps '{ print } END { print "unit", "frontend", "f2", "step:more" }'
assert_contains "$out" "lane frontend has step units in f1 and f2" "ci-manifest-steps: one shard a lane runs in its own job"
lint row '{ print } END { print "shard", "frontend", "f1" }'
assert_contains "$out" "unknown row shard" "ci-manifest-rows: no other row"

# --- ci-guard-*: FULL is green only on the whole manifest --------------------
# gen DIR — passing FULL evidence for every shard of the manifest at $SHA.
gen() {
  mkdir -p "$1"
  awk -F'\t' -v dir="$1" -v sha="$SHA" '
    $1 == "lane" { os[$2] = $4; ar[$2] = $5; v[$2] = ($2 ~ /macos/ ? "3.2.57(1)-release" : $2 == "target-bash53" ? "5.3.15(1)-release" : "5.2.21(1)-release") }
    $1 == "unit" {
      f = dir "/" $2 "-" $3 ".tsv"
      if (!(f in done)) {
        done[f] = 1
        printf "# omb-ci-evidence 1\nmode\tfull\nlane\t%s\nshard\t%s\nsha\t%s\ngithub_sha\t%s\nrun\t1\nattempt\t1\njob\tj\nos\t%s\narch\t%s\n", $2, $3, sha, sha, os[$2], ar[$2] >>f
      }
      printf "unit\t%s\tpass\t0\t%s\t1\t%s\n", $4, v[$2], ($4 ~ /^(suite|diag):/ ? "test-x: 3 passed, 0 failed, 0 skipped" : "-") >>f
      close(f)
    }' "$M"
}
G=$T/evidence
gen "$G"
out=$(ci guard "$G" "$SHA")
assert_rc "$?" 0 "ci-guard-green: the whole manifest, passed, at the SHA"
assert_contains "$out" "verdict: GREEN · every unit of the manifest executed and passed exactly once at $SHA" "ci-guard-green: says so"
# variant NAME — a copy of the passing evidence to change; prints its path.
variant() {
  rm -rf "${T:?}/$1"
  cp -R "$G" "$T/$1"
  printf '%s' "$T/$1"
}
guard() { # DIR [JOBS] — the guard at $SHA; sets out and rc
  out=$(ci guard "$1" "$SHA" "${2:-/dev/null}")
  rc=$?
}
v=$(variant missing-shard)
rm "$v/target-bash53-t3.tsv"
guard "$v"
assert_rc "$rc" 1 "ci-guard-missing-shard: a shard with no evidence"
assert_contains "$out" "missing · missing shard: target-bash53 · t3 left no evidence" "ci-guard-missing-shard: is named"
printf '1\ttarget-bash53 · t3\tcompleted\tcancelled\t0\t0\t%s\n' "$NOTACQ" >"$T/notacq.tsv"
assert_not_contains "$out" "retry:" "ci-guard-missing-shard: is not a runner never acquired"
guard "$v" "$T/notacq.tsv"
assert_contains "$out" "infrastructure · runner never acquired (infrastructure non-run): target-bash53 · t3" "ci-guard-not-acquired: a runner never acquired is infrastructure"
assert_contains "$out" "executed failures 0 · infrastructure 1 · missing 0" "ci-guard-not-acquired: not an executed failure"
assert_contains "$out" "retry: every problem is a runner never acquired (1)" "ci-guard-not-acquired: and, when it is every problem, says so"
v=$(variant failure)
edit "$v/linux-bash5-l2.tsv" '$1 == "unit" && $2 == "suite:dev" { $3 = "fail"; $4 = 1 } 1'
guard "$v"
assert_rc "$rc" 1 "ci-guard-failure: an executed test failure"
assert_contains "$out" "failure · executed failure: linux-bash5 · l2 · suite:dev (exit 1)" "ci-guard-failure: is named"
assert_contains "$out" "executed failures 1 · infrastructure 0" "ci-guard-failure: and counted as executed"
v=$(variant reported)
edit "$v/linux-bash5-l2.tsv" '$1 == "unit" && $2 == "suite:dev" { $7 = "test-dev: 3 passed, 2 failed, 0 skipped" } 1'
guard "$v"
assert_contains "$out" "executed failure: linux-bash5 · l2 · suite:dev reports test-dev: 3 passed, 2 failed, 0 skipped" "ci-guard-failure: a failed count with exit 0"
v=$(variant source)
edit "$v/target-bash53-t1.tsv" '$1 != "unit" { print } END { print "setup", "bash-5.3.15", "fail", 75 }'
guard "$v"
assert_contains "$out" "infrastructure · source acquisition / external infrastructure: target-bash53 · t1 · bash-5.3.15 exhausted every origin (exit 75)" "ci-guard-source: an exhausted Bash source download is infrastructure"
assert_contains "$out" "missing · not executed: target-bash53 · t1 · diag:children" "ci-guard-source: and its units did not run"
assert_contains "$out" "executed failures 0 · infrastructure 1" "ci-guard-source: not an executed failure"
assert_not_contains "$out" "retry:" "ci-guard-source: nor a runner never acquired"
v=$(variant unit)
edit "$v/macos-bash32-m2.tsv" '!($1 == "unit" && $2 == "suite:core")'
guard "$v"
assert_rc "$rc" 1 "ci-guard-missing-unit: a unit that did not run"
assert_contains "$out" "not executed: macos-bash32 · m2 · suite:core" "ci-guard-missing-unit: is named"
v=$(variant dup-unit)
printf 'unit\tsuite:cli\tpass\t0\t5.2.21(1)-release\t1\ttest-cli: 3 passed, 0 failed, 0 skipped\n' >>"$v/linux-bash5-l2.tsv"
guard "$v"
assert_rc "$rc" 1 "ci-guard-duplicate-unit: a unit run twice"
assert_contains "$out" "duplicate: linux-bash5 · suite:cli ran in l1 and in l2" "ci-guard-duplicate-unit: is named"
v=$(variant dup-shard)
cp "$v/macos-bash32-m1.tsv" "$v/again.tsv"
guard "$v"
assert_contains "$out" "duplicate: two evidence files for macos-bash32 · m1" "ci-guard-duplicate-shard: two files for one shard"
v=$(variant sha)
edit "$v/frontend-f1.tsv" '$1 == "sha" { $2 = "ffffffffffffffffffffffffffffffffffffffff" } 1'
guard "$v"
assert_rc "$rc" 1 "ci-guard-sha: a shard at another commit"
assert_contains "$out" "wrong SHA: frontend · f1 checked out ffffffffffffffffffffffffffffffffffffffff" "ci-guard-sha: is named"
v=$(variant github-sha)
edit "$v/frontend-f1.tsv" '$1 == "github_sha" { $2 = "eeee" } 1'
guard "$v"
assert_contains "$out" "wrong SHA: frontend · f1 ran for eeee" "ci-guard-sha: a shard of another run's commit"
out=$(ci guard "$G" ffffffffffffffffffffffffffffffffffffffff)
assert_rc "$?" 1 "ci-guard-sha: evidence for one commit is not evidence for another"
# skips FILE UNIT SUMMARIES [REASON...] — UNIT's summary lines, and a skip row
# for each REASON.
skips() {
  local f=$1 u=$2 s=$3 r
  shift 3
  awk -F'\t' -v OFS='\t' -v u="$u" -v s="$s" '$1 == "unit" && $2 == u { $7 = s } 1' "$f" >"$f.new" && mv "$f.new" "$f"
  for r in "$@"; do printf 'skip\t%s\t%s\n' "$u" "$r" >>"$f"; done
}
PL="macOS plist checks in test-core.sh (no plutil)"
CORE1="test-core: 506 passed, 0 failed, 1 skipped"
v=$(variant skip)
skips "$v/macos-bash32-m2.tsv" suite:core "$CORE1" "$PL"
guard "$v"
assert_rc "$rc" 1 "ci-guard-skip: a skip the macOS lane does not allow"
assert_contains "$out" "undeclared skip: macos-bash32 · m2 · suite:core: macOS plist checks in test-core.sh (no plutil)" "ci-guard-skip: is named"
v=$(variant skip-hidden)
skips "$v/macos-bash32-m2.tsv" suite:core "$CORE1"
guard "$v"
assert_rc "$rc" 1 "ci-guard-skip-hidden: 1 skipped on a lane that allows none, and no skip row (R2-A)"
assert_contains "$out" "integrity · skipped where no skip is allowed: macos-bash32 · m2 · suite:core reports 1 skipped" "ci-guard-skip-hidden: is named"
assert_contains "$out" "integrity · skip count: macos-bash32 · m2 · suite:core reports 1 skipped and gives 0 skip reasons" "ci-guard-skip-hidden: with the reasons it did not give"
v=$(variant skip-unreasoned)
skips "$v/linux-bash5-l3.tsv" suite:core "$CORE1"
guard "$v"
assert_rc "$rc" 1 "ci-guard-skip-count: an allowed lane's skip with no reason (R2-B)"
assert_contains "$out" "skip count: linux-bash5 · l3 · suite:core reports 1 skipped and gives 0 skip reasons" "ci-guard-skip-count: is named"
assert_not_contains "$out" "skipped where no skip is allowed" "ci-guard-skip-count: Linux allows its skips"
v=$(variant skip-few)
skips "$v/linux-bash5-l3.tsv" suite:core "test-core: 505 passed, 0 failed, 2 skipped" "$PL"
guard "$v"
assert_rc "$rc" 1 "ci-guard-skip-count: 2 skipped, 1 reason (R2-C)"
assert_contains "$out" "skip count: linux-bash5 · l3 · suite:core reports 2 skipped and gives 1 skip reasons" "ci-guard-skip-count: too few reasons"
v=$(variant skip-many)
skips "$v/linux-bash5-l3.tsv" suite:core "$CORE1" "$PL" "$PL"
guard "$v"
assert_rc "$rc" 1 "ci-guard-skip-count: 1 skipped, 2 reasons (R2-D)"
assert_contains "$out" "skip count: linux-bash5 · l3 · suite:core reports 1 skipped and gives 2 skip reasons" "ci-guard-skip-count: too many reasons"
v=$(variant skip-reason)
skips "$v/linux-bash5-l3.tsv" suite:core "$CORE1" "the storm (no reason)"
guard "$v"
assert_rc "$rc" 1 "ci-guard-skip: a reason the lane does not allow, counts agreeing (R2-E)"
assert_contains "$out" "undeclared skip: linux-bash5 · l3 · suite:core: the storm (no reason)" "ci-guard-skip: any other skip on Linux"
assert_not_contains "$out" "skip count:" "ci-guard-skip: the counts agree"
v=$(variant allowed)
skips "$v/linux-bash5-l3.tsv" suite:core "$CORE1" "$PL"
guard "$v"
assert_rc "$rc" 0 "ci-guard-skip-allowed: a plutil skip on Linux, counted and given its reason, is the lane's policy (R2-F)"
assert_eq "$(printf '%s\n' "$out" | grep -c '^  ok       linux-bash5 · l3 · .* · 1 skips$')" 1 "ci-guard-skip-allowed: and is shown"
TWO="test-diag-temp: 6 passed, 0 failed, 1 skipped; test-diag: 4 passed, 0 failed, 2 skipped"
v=$(variant skip-summaries)
skips "$v/linux-bash5-l2.tsv" diag:temp "$TWO" "a fixture (no plutil)" "a fixture (no plutil)" "the storm (Bash 5.2 upstream)"
guard "$v"
assert_rc "$rc" 0 "ci-guard-skip-summaries: 1 + 2 skipped over two summary lines, 3 reasons (R2-G)"
v=$(variant skip-summaries-short)
skips "$v/linux-bash5-l2.tsv" diag:temp "$TWO" "a fixture (no plutil)" "a fixture (no plutil)"
guard "$v"
assert_rc "$rc" 1 "ci-guard-skip-summaries: one reason fewer (R2-G)"
assert_contains "$out" "skip count: linux-bash5 · l2 · diag:temp reports 3 skipped and gives 2 skip reasons" "ci-guard-skip-summaries: every summary line counts"
guard "$G"
assert_rc "$rc" 0 "ci-guard-skip-none: 0 skipped and no skip row (R2-H)"
v=$(variant summary-unreadable)
skips "$v/linux-bash5-l3.tsv" suite:core "test-core: 506 passed, 0 failed"
guard "$v"
assert_contains "$out" "integrity · unreadable summary: linux-bash5 · l3 · suite:core reports test-core: 506 passed, 0 failed" "ci-guard-skip-count: a summary without its skipped count is not read as 0"
v=$(variant shell)
edit "$v/target-bash53-t2.tsv" '$1 == "unit" { $5 = "5.2.21(1)-release" } 1'
guard "$v"
assert_rc "$rc" 1 "ci-guard-shell: the target lane under the runner's Bash 5.2"
assert_contains "$out" "wrong shell: target-bash53 · t2 · diag:bounds ran under bash 5.2.21(1)-release" "ci-guard-shell: is named"
v=$(variant platform)
edit "$v/frontend-linux-arm64-a2.tsv" '$1 == "arch" { $2 = "x86_64" } 1'
guard "$v"
assert_contains "$out" "wrong platform: frontend-linux-arm64 · a2 ran on Linux x86_64" "ci-guard-platform: another architecture"
v=$(variant fast)
edit "$v/linux-bash5-l1.tsv" '$1 == "mode" { $2 = "fast" } 1'
guard "$v"
assert_rc "$rc" 1 "ci-guard-fast: FAST evidence is not FULL evidence"
assert_contains "$out" "not FULL evidence: linux-bash5 · l1 says mode fast" "ci-guard-fast: is named"
v=$(variant summary)
edit "$v/macos-bash32-m3.tsv" '$1 == "unit" && $2 == "suite:dev" { $7 = "-" } 1'
guard "$v"
assert_contains "$out" "no summary: macos-bash32 · m3 · suite:dev printed no" "ci-guard-summary: a suite that printed no count"
v=$(variant unexpected)
printf 'unit\tsuite:nope\tpass\t0\t5.2.21(1)-release\t1\ttest-nope: 1 passed, 0 failed, 0 skipped\n' >>"$v/linux-bash5-l1.tsv"
guard "$v"
assert_contains "$out" "unexpected: linux-bash5 · l1 · suite:nope is not in the manifest" "ci-guard-unexpected: a unit the manifest does not name"
guard "$G" "$T/notacq.tsv"
assert_rc "$rc" 0 "ci-guard-jobs: job records alone change nothing when every shard reported"
out=$(OMB_CI_MANIFEST=$T/dup.tsv ci guard "$G" "$SHA")
assert_rc "$?" 1 "ci-guard-manifest: a manifest that does not hold"
assert_contains "$out" "verdict: RED · the manifest does not hold" "ci-guard-manifest: is named"

# --- ci-retry-*: one retry, only for runners never acquired ------------------
# A run's first attempt as tests/ci.sh jobs lists it: id, name, status,
# conclusion, runner, steps, annotations, the steps that did not pass. Run
# 37371989145's: two jobs never acquired a runner (cancelled, runner 0, no
# step, GitHub's annotation); here its verdict job is at its end, running.
jobrow() { local IFS="$TAB"; printf '%s\n' "$*"; }
GSTEP=$(sed -n 's/^      - name: \(FULL completeness guard .*\)$/\1/p' "$W")
FSTEP=$(sed -n 's/^      - name: \(FAST is not acceptance evidence\)$/\1/p' "$W")
RSTEP=$(sed -n 's/^      - name: \(One automatic retry .*\)$/\1/p' "$W")
assert_eq "$(printf '%s\n' "$GSTEP" "$FSTEP" "$RSTEP" | grep -c .)" 3 "ci-workflow-verdict: one guard, one FAST and one retry step, as the controller reads them"
assert_contains "$(sed -n '/^  verdict:/,/^  retry:/p' "$W")" 'if tests/ci.sh retry-signal "$RUNNER_TEMP/jobs.tsv" "$GITHUB_SHA" "$MODE" "$RUNNER_TEMP/guard.txt"; then' "ci-workflow-verdict: the controller is dispatched only on the verdict's signal"
J=$T/jobs.tsv
{
  jobrow 11 "frontend-macos-arm64 · x1 · build" completed success 1000001760 15 - -
  jobrow 12 "target-bash53 · t4" completed success 1000001757 10 - -
  jobrow 13 "frontend · f1 · fmt, clippy" completed cancelled 0 0 "$NOTACQ" -
  jobrow 14 "linux-bash5 · l0" completed cancelled 0 0 "$NOTACQ" -
  jobrow 15 "FULL acceptance · completeness guard" in_progress - 1000001790 3 - "The run's jobs=-"
} >"$J"
v=$(variant not-acquired)
rm "$v/frontend-f1.tsv" "$v/linux-bash5-l0.tsv"
ci guard "$v" "$SHA" "$J" >"$T/guard.txt"
assert_contains "$(cat "$T/guard.txt")" "retry: every problem is a runner never acquired (2)" "ci-retry-signal: the guard finds the runners never acquired, and nothing else"
out=$(ci retry-signal "$J" "$SHA" full "$T/guard.txt")
assert_rc "$?" 0 "ci-retry-signal: the verdict's red is the runners never acquired alone"
assert_contains "$out" "runner never acquired: linux-bash5 · l0" "ci-retry-signal: each is named"
assert_contains "$out" "::notice::retry: red only from runners never acquired · full · $SHA · jobs 13,14" "ci-retry-signal: the notice it leaves on the verdict job names the mode, the SHA and those jobs"
skips "$v/macos-bash32-m2.tsv" suite:core "$CORE1"
ci guard "$v" "$SHA" "$J" >"$T/guard-more.txt"
out=$(ci retry-signal "$J" "$SHA" full "$T/guard-more.txt")
assert_rc "$?" 1 "ci-retry-signal-guard: no signal when the guard found more than the runners never acquired"
assert_contains "$out" "the guard found more than the runners never acquired, or did not finish" "ci-retry-signal-guard: is named"
assert_not_contains "$out" "::notice::" "ci-retry-signal-guard: and nothing is left on the verdict job"
out=$(ci retry-signal "$J" "$SHA" full "$T/no-guard.txt")
assert_rc "$?" 1 "ci-retry-signal-guard: no signal in FULL without the guard's output"
cp "$J" "$T/executed.tsv"
jobrow 16 "macos-bash32 · m1" completed failure 1000001761 9 "Process completed with exit code 1." "The shard's units=failure" >>"$T/executed.tsv"
out=$(ci retry-signal "$T/executed.tsv" "$SHA" full "$T/guard.txt")
assert_rc "$?" 1 "ci-retry-executed: no retry beside an executed failure"
assert_contains "$out" "not a runner-acquisition non-run: macos-bash32 · m1 (completed/failure)" "ci-retry-executed: is named"
cp "$J" "$T/source.tsv"
jobrow 16 "target-bash53 · t1" completed failure 1000001762 6 "Process completed with exit code 75." "GNU Bash 5.3.15=failure" >>"$T/source.tsv"
out=$(ci retry-signal "$T/source.tsv" "$SHA" full "$T/guard.txt")
assert_rc "$?" 1 "ci-retry-source: a source download that failed on a runner is not a non-run"
{
  head -2 "$J"
  jobrow 17 "linux-bash5 · l1" completed cancelled 0 0 - -
  tail -1 "$J"
} >"$T/cancelled.tsv"
out=$(ci retry-signal "$T/cancelled.tsv" "$SHA" fast)
assert_rc "$?" 1 "ci-retry-cancelled: a job cancelled before it started is not a non-run"
{
  head -2 "$J"
  tail -1 "$J"
} >"$T/green.tsv"
out=$(ci retry-signal "$T/green.tsv" "$SHA" fast)
assert_rc "$?" 1 "ci-retry-green: nothing to retry"

# The controller (tests/ci.sh retry) over recorded runs: a gh on PATH answers
# each request from $GH_FIXTURE, in the shapes GitHub's API answered (run
# 37371989145 for runners never acquired, run 36687583425 for jobs cancelled
# by hand), and records each write instead of making it. With --paginate it
# writes page after page as gh does (NAME.json, NAME.2.json, ...), and fails
# at a page recorded as NAME.N.fail, having written the pages before it. The
# verdict job's signal comes from tests/ci.sh retry-signal over the jobs
# tests/ci.sh jobs read, and the guard's own output.
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$T/bin"
  printf '%s\n' '#!/bin/sh' \
    '[ "$1" = api ] || exit 2' \
    'shift' \
    "m=GET q='' p='' all=''" \
    'while [ $# -gt 0 ]; do' \
    '  case $1 in' \
    '    --paginate) all=1 ;;' \
    '    -X) m=$2; shift ;;' \
    '    --jq) q=$2; shift ;;' \
    '    *) p=$1 ;;' \
    '  esac' \
    '  shift' \
    'done' \
    'if [ "$m" != GET ]; then echo "$m $p" >>"$GH_FIXTURE/writes"; exit 0; fi' \
    'f=$GH_FIXTURE/$(printf "%s" "${p%%\?*}" | tr / _)' \
    'if [ ! -f "$f.json" ]; then echo "gh: no recorded response for $p" >&2; exit 1; fi' \
    'n=1' \
    'g=$f.json' \
    'while [ -f "$g" ]; do' \
    '  if [ -n "$q" ]; then jq -r "$q" "$g" || exit 1; else cat "$g"; fi' \
    '  [ -n "$all" ] || exit 0' \
    '  n=$((n + 1))' \
    '  g=$f.$n.json' \
    '  if [ -f "$f.$n.fail" ]; then echo "gh: HTTP 502 at page $n of $p" >&2; exit 1; fi' \
    'done' >"$T/bin/gh"
  chmod +x "$T/bin/gh"
  GR=o/r
  POST="POST repos/o/r/actions/runs/7/rerun-failed-jobs"
  # api DIR REPO HEAD WORKFLOW EVENT BRANCH SHA ATTEMPT — run 7 of o/r as
  # DIR records it, and its first attempt's jobs from $T/rows: id, name,
  # status, conclusion (- while running), runner (- for null, as GitHub
  # records a skipped job's), steps (NAME=CONCLUSION;... or -), annotations
  # (A | B or -). The run passes through the jq filter $RMUT and the jobs
  # through $MUT, when set; then the function $HOOK, when set, is given DIR.
  api() {
    local d=$1 id notes
    rm -rf "$d"
    mkdir -p "$d"
    jq -n --arg r "$2" --arg h "$3" --arg p "$4" --arg e "$5" --arg b "$6" --arg s "$7" --argjson a "$8" \
      '{id: 7, status: "completed", repository: {full_name: $r}, head_repository: {full_name: $h}, path: $p, event: $e, head_branch: $b, head_sha: $s, run_attempt: $a} | '"${RMUT:-.}" >"$d/repos_o_r_actions_runs_7.json"
    jq -R -s '[split("\n")[] | select(length > 0) | split("\t") | {id: (.[0] | tonumber), name: .[1], status: .[2], conclusion: (if .[3] == "-" then null else .[3] end), runner_id: (if .[4] == "-" then null else .[4] | tonumber end), steps: (if .[5] == "-" then [] else [.[5] | split(";")[] | split("=") | {name: .[0], status: (if .[1] == "-" then "in_progress" else "completed" end), conclusion: (if .[1] == "-" then null else .[1] end)}] end)}] | {total_count: length, jobs: .} | '"${MUT:-.}" "$T/rows" >"$d/repos_o_r_actions_runs_7_attempts_1_jobs.json"
    while IFS="$TAB" read -r id _ _ _ _ _ notes; do
      [ "$notes" = - ] || printf '%s' "$notes" | jq -R -s 'split(" | ") | map({annotation_level: (if startswith("retry: ") then "notice" else "failure" end), message: .})' >"$d/repos_o_r_check-runs_${id}_annotations.json"
    done <"$T/rows"
    [ -z "${HOOK:-}" ] || "$HOOK" "$d"
  }
  # ctl NAME [REPO HEAD WORKFLOW EVENT BRANCH SHA ATTEMPT] — tests/ci.sh retry
  # o/r 7 $SHA over that run, by default this repository's ci.yml dispatched
  # at $SHA, attempt 1; sets out, rc and posts (the writes it asked for).
  ctl() {
    local d=$T/api/$1
    shift
    [ $# -gt 0 ] || set -- "$GR" "$GR" .github/workflows/ci.yml workflow_dispatch ci-throughput "$SHA" 1
    api "$d" "$@"
    out=$(PATH="$T/bin:$PATH" GH_FIXTURE=$d ci retry "$GR" 7 "$SHA" 2>&1)
    rc=$?
    posts=$(cat "$d/writes" 2>/dev/null)
  }
  ran="Set up job=success;Complete job=success"
  workload() {
    jobrow 100 plan completed success 1000001750 "$ran" -
    jobrow 101 "fast · syntax, fixtures, docs, static, safety, CI, the suites a change touched" completed skipped - - -
    jobrow 102 "macos-bash32 · m1 · stock /bin/bash 3.2 · BSD userland" completed success 1000001751 "$ran" -
    jobrow 103 "linux-bash5 · l0 · bash 5 · ShellCheck 0.9.0" completed cancelled 0 - "$NOTACQ"
    jobrow 104 "frontend · f1 · fmt · clippy · layers A–F and H · build inputs" completed cancelled 0 - "$NOTACQ"
    jobrow 105 "target-bash53 · t1 · GNU Bash 5.3.15 from pinned sources · aarch64" completed success 1000001752 "$ran" -
    jobrow 107 "retry controller · run" completed skipped - - -
  }
  # vsteps CHECKOUT EVIDENCE GUARD FAST RETRY — the verdict job's steps, so ended
  vsteps() { printf '%s' "Set up job=success;Run actions/checkout@v7=$1;The run's jobs=success;Every shard's evidence=$2;$GSTEP=$3;$FSTEP=$4;$RSTEP=$5;Post Run actions/checkout@v7=success;Complete job=success"; }
  # verdict STATUS CONCLUSION STEPS ANNOTATIONS — the FULL verdict job
  verdict() { jobrow 106 "FULL acceptance · completeness guard" "$@"; }
  # The FULL verdict job at its last step, still running.
  at_verdict() { verdict in_progress - 1000001790 "Set up job=success;Run actions/checkout@v7=success;The run's jobs=-" -; }

  # R1-A: at its end the verdict job reads the jobs, the guard has run, and
  # the signal it leaves is the controller's evidence.
  {
    workload
    at_verdict
  } >"$T/rows"
  api "$T/api/at-verdict" "$GR" "$GR" .github/workflows/ci.yml workflow_dispatch ci-throughput "$SHA" 1
  PATH="$T/bin:$PATH" GH_FIXTURE=$T/api/at-verdict ci jobs "$GR" 7 1 >"$T/jobs-at-verdict.tsv"
  assert_eq "$(awk -F'\t' '$1 == 103 { print $3, $4, $5, $6, $8 }' "$T/jobs-at-verdict.tsv")" "completed cancelled 0 0 -" "ci-jobs: a job never acquired, as GitHub records it"
  assert_contains "$(awk -F'\t' '$1 == 103 { print $7 }' "$T/jobs-at-verdict.tsv")" "$NOTACQ" "ci-jobs: with GitHub's annotation"
  assert_eq "$(awk -F'\t' '$1 == 106 { print $3, $4, $8 }' "$T/jobs-at-verdict.tsv")" "in_progress - The run's jobs=-" "ci-jobs: the verdict job still running"
  assert_eq "$(awk -F'\t' '$1 == 101 { print $4, $5, $6 }' "$T/jobs-at-verdict.tsv")" "skipped ?null 0" "ci-jobs: a skipped job's null runner reads ?null, never 0"
  AV=$(variant at-verdict)
  rm "$AV/frontend-f1.tsv" "$AV/linux-bash5-l0.tsv"
  ci guard "$AV" "$SHA" "$T/jobs-at-verdict.tsv" >"$T/guard-at-verdict.txt"
  sig=$(ci retry-signal "$T/jobs-at-verdict.tsv" "$SHA" full "$T/guard-at-verdict.txt" | sed -n 's/^::notice:://p')
  assert_eq "$sig" "retry: red only from runners never acquired · full · $SHA · jobs 103,104" "ci-retry-signal: from the jobs GitHub lists and the guard's own output"
  ok_verdict() { verdict completed failure 1000001790 "$(vsteps success success failure skipped success)" "Process completed with exit code 1. | $sig"; }
  {
    workload
    ok_verdict
  } >"$T/rows"
  ctl eligible
  assert_rc "$rc" 0 "ci-retry-eligible: the controller over the completed run"
  assert_eq "$posts" "$POST" "ci-retry-eligible: exactly one rerun-failed-jobs POST when runners never acquired are every cause (R1-A)"
  assert_contains "$out" "runner never acquired: frontend · f1 · fmt · clippy · layers A–F and H · build inputs" "ci-retry-eligible: each job is named"

  # FAST too: a push to a branch, its fast job never acquired.
  fast_jobs() {
    jobrow 100 plan completed success 1000001750 "$ran" -
    jobrow 101 "fast · syntax, fixtures, docs, static, safety, CI, the suites a change touched" completed cancelled 0 - "$NOTACQ"
    jobrow 102 "macos-bash32 · m1 · stock /bin/bash 3.2 · BSD userland" completed skipped - - -
    jobrow 103 "linux-bash5 · l0 · bash 5 · ShellCheck 0.9.0" completed success 1000001751 "$ran" -
  }
  {
    fast_jobs
    jobrow 106 "FAST · not acceptance evidence" in_progress - 1000001790 "Set up job=success;The run's jobs=-" -
  } >"$T/rows"
  api "$T/api/at-fast-verdict" "$GR" "$GR" .github/workflows/ci.yml push ci-throughput "$SHA" 1
  PATH="$T/bin:$PATH" GH_FIXTURE=$T/api/at-fast-verdict ci jobs "$GR" 7 1 >"$T/jobs-at-fast-verdict.tsv"
  fsig=$(ci retry-signal "$T/jobs-at-fast-verdict.tsv" "$SHA" fast | sed -n 's/^::notice:://p')
  assert_eq "$fsig" "retry: red only from runners never acquired · fast · $SHA · jobs 101" "ci-retry-signal-fast: FAST needs no guard"
  {
    fast_jobs
    jobrow 106 "FAST · not acceptance evidence" completed failure 1000001790 "$(vsteps success skipped skipped failure success)" "Process completed with exit code 1. | $fsig"
  } >"$T/rows"
  ctl fast "$GR" "$GR" .github/workflows/ci.yml push ci-throughput "$SHA" 1
  assert_eq "$posts" "$POST" "ci-retry-eligible-fast: one POST for a FAST run's runner never acquired"
  ctl fast-as-full "$GR" "$GR" .github/workflows/ci.yml push main "$SHA" 1
  assert_eq "$posts" "" "ci-retry-mode: a FAST signal on a run its event makes FULL"
  assert_contains "$out" "the verdict job went wrong in $FSTEP=failure, not in its own verdict step alone" "ci-retry-mode: is named"

  # R1-B, R1-C: the verdict job ended otherwise than from those jobs alone.
  CANCEL="The run was canceled by @owner. | The operation was canceled."
  {
    workload
    verdict completed cancelled 1000001790 "$(vsteps success success failure skipped cancelled)" "$CANCEL | Process completed with exit code 1. | $sig"
  } >"$T/rows"
  ctl verdict-cancelled
  assert_eq "$posts" "" "ci-retry-verdict-cancelled: a verdict cancelled by hand after its steps ran, its signal left: no POST (R1-B)"
  assert_contains "$out" "the verdict job ended completed/cancelled, not failed on a runner of its own" "ci-retry-verdict-cancelled: is named"
  {
    workload
    verdict completed timed_out 1000001790 "$(vsteps success success failure skipped cancelled)" "The job has exceeded the maximum execution time of 15m0s | $sig"
  } >"$T/rows"
  ctl verdict-timed-out
  assert_eq "$posts" "" "ci-retry-verdict-timed-out: a verdict that timed out: no POST (R1-B)"
  {
    workload
    verdict completed failure 1000001790 "$(vsteps success success failure skipped cancelled)" "The job has exceeded the maximum execution time of 15m0s | $sig"
  } >"$T/rows"
  ctl verdict-stopped
  assert_eq "$posts" "" "ci-retry-verdict-stopped: a verdict failed with a step stopped: no POST (R1-B)"
  assert_contains "$out" "the verdict job went wrong in $GSTEP=failure | $RSTEP=cancelled, not in its own verdict step alone" "ci-retry-verdict-stopped: is named"
  {
    workload
    verdict completed failure 1000001790 "$(vsteps success failure failure skipped success)" "Unable to download artifact(s): Artifact not found for name: evidence-macos-bash32-m1 | Process completed with exit code 1. | $sig"
  } >"$T/rows"
  ctl verdict-download
  assert_eq "$posts" "" "ci-retry-verdict-download: the verdict's own artifact download failed: no POST (R1-C)"
  assert_contains "$out" "the verdict job went wrong in Every shard's evidence=failure | $GSTEP=failure" "ci-retry-verdict-download: is named"
  {
    workload
    verdict completed failure 1000001790 "$(vsteps failure skipped failure skipped failure)" "Process completed with exit code 128."
  } >"$T/rows"
  ctl verdict-checkout
  assert_eq "$posts" "" "ci-retry-verdict-checkout: the verdict's checkout failed: no POST (R1-C)"
  {
    workload
    verdict completed failure 1000001790 "$(vsteps success success failure skipped success)" "Process completed with exit code 1."
  } >"$T/rows"
  ctl verdict-red
  assert_eq "$posts" "" "ci-retry-verdict-red: the guard red for a reason of its own, so no signal: no POST (R1-C)"
  assert_contains "$out" "the verdict job carries 0 retry signals, not one" "ci-retry-verdict-red: is named"
  {
    workload
    verdict completed failure 1000001790 "$(vsteps success success failure skipped success)" "Process completed with exit code 1. | ${sig%,104}"
  } >"$T/rows"
  ctl verdict-other-jobs
  assert_eq "$posts" "" "ci-retry-verdict-signal: a signal naming other jobs than those never acquired: no POST"
  assert_contains "$out" "the verdict job signals full · $SHA · jobs 103, not full · $SHA · jobs 103,104" "ci-retry-verdict-signal: is named"

  # R1-D, R1-E, R1-F: another job went wrong, the verdict job as in R1-A.
  {
    workload
    jobrow 108 "macos-bash32 · m2 · stock /bin/bash 3.2 · BSD userland" completed failure 1000001753 "Set up job=success;The shard's units=failure" "Process completed with exit code 1."
    ok_verdict
  } >"$T/rows"
  ctl executed
  assert_eq "$posts" "" "ci-retry-executed: an executed test failure beside them: no POST (R1-D)"
  assert_contains "$out" "not a runner-acquisition non-run: macos-bash32 · m2 · stock /bin/bash 3.2 · BSD userland (completed/failure)" "ci-retry-executed: is named"
  {
    workload
    jobrow 108 "target-bash53 · t2 · GNU Bash 5.3.15 from pinned sources · aarch64" completed failure 1000001753 "Set up job=success;GNU Bash 5.3.15, built from the sources tests/bash-5.3.15.sha256 pins=failure" "Process completed with exit code 75."
    ok_verdict
  } >"$T/rows"
  ctl source
  assert_eq "$posts" "" "ci-retry-source: sources exhausted on a runner it acquired: no POST (R1-E)"
  {
    workload
    jobrow 108 "macos-bash32 · m2 · stock /bin/bash 3.2 · BSD userland" completed cancelled 1000001753 "Set up job=success;The shard's units=cancelled" "$CANCEL"
    ok_verdict
  } >"$T/rows"
  ctl job-cancelled
  assert_eq "$posts" "" "ci-retry-job-cancelled: a job cancelled by hand: no POST (R1-F)"
  assert_contains "$out" "not a runner-acquisition non-run: macos-bash32 · m2 · stock /bin/bash 3.2 · BSD userland (completed/cancelled)" "ci-retry-job-cancelled: is named"

  # R1-G to R1-K: the run is not the one the controller was dispatched for.
  {
    workload
    ok_verdict
  } >"$T/rows"
  ctl wrong-sha "$GR" "$GR" .github/workflows/ci.yml workflow_dispatch ci-throughput ffffffffffffffffffffffffffffffffffffffff 1
  assert_eq "$rc $posts" "1 " "ci-retry-identity: another SHA: no POST (R1-G)"
  assert_contains "$out" "run 7 is at ffffffffffffffffffffffffffffffffffffffff, not $SHA; nothing re-run" "ci-retry-identity: is named"
  ctl wrong-workflow "$GR" "$GR" .github/workflows/release.yml workflow_dispatch ci-throughput "$SHA" 1
  assert_eq "$rc $posts" "1 " "ci-retry-identity: another workflow: no POST (R1-H)"
  assert_contains "$out" "run 7 is of .github/workflows/release.yml, not .github/workflows/ci.yml" "ci-retry-identity: is named"
  ctl wrong-event "$GR" "$GR" .github/workflows/ci.yml pull_request ci-throughput "$SHA" 1
  assert_eq "$rc $posts" "1 " "ci-retry-identity: a pull request: no POST (R1-I)"
  assert_contains "$out" "run 7 came from pull_request; only a push or a dispatch is retried" "ci-retry-identity: is named"
  ctl wrong-event-schedule "$GR" "$GR" .github/workflows/ci.yml schedule ci-throughput "$SHA" 1
  assert_eq "$rc $posts" "1 " "ci-retry-identity: any other event: no POST (R1-I)"
  ctl wrong-head "$GR" someone/fork .github/workflows/ci.yml workflow_dispatch ci-throughput "$SHA" 1
  assert_eq "$rc $posts" "1 " "ci-retry-identity: a head repository of another: no POST (R1-J)"
  assert_contains "$out" "run 7 is o/r's run 7, from someone/fork, not o/r's" "ci-retry-identity: is named"
  ctl wrong-repository other/r other/r .github/workflows/ci.yml workflow_dispatch ci-throughput "$SHA" 1
  assert_eq "$rc $posts" "1 " "ci-retry-identity: another repository's run: no POST (R1-J)"
  ctl attempt-2 "$GR" "$GR" .github/workflows/ci.yml workflow_dispatch ci-throughput "$SHA" 2
  assert_eq "$rc $posts" "0 " "ci-retry-spent: attempt 2: no POST (R1-K)"
  assert_contains "$out" "run 7 is at attempt 2: its one automatic retry is spent" "ci-retry-spent: is named"

  # R1-L: no runner went unacquired.
  {
    workload | grep -v "$NOTACQ"
    verdict completed failure 1000001790 "$(vsteps success success failure skipped success)" "Process completed with exit code 1."
  } >"$T/rows"
  ctl no-non-run
  assert_eq "$posts" "" "ci-retry-none: a red verdict with no runner never acquired: no POST (R1-L)"
  {
    workload | grep -v "$NOTACQ"
    verdict completed success 1000001790 "$(vsteps success success success skipped success)" -
  } >"$T/rows"
  ctl green
  assert_eq "$rc $posts" "0 " "ci-retry-none: a green run: no POST (R1-L)"

  # M1–M17: what the rule proves from must itself be proven. R1-A's run, its
  # jobs through $MUT and its recording through $HOOK, read by each half on
  # its own. mcase NAME: the verdict job's half — tests/ci.sh jobs (jrc, its
  # lines in $T/jobs-NAME.tsv), the guard, tests/ci.sh retry-signal (mout,
  # and msig, the signal it left) — then the controller's over the completed
  # run, whose verdict job carries R1-A's own signal, so that the controller
  # refuses unaided (out, rc, posts).
  mcase() {
    {
      workload
      at_verdict
    } >"$T/rows"
    api "$T/api/$1-at-verdict" "$GR" "$GR" .github/workflows/ci.yml workflow_dispatch ci-throughput "$SHA" 1
    PATH="$T/bin:$PATH" GH_FIXTURE=$T/api/$1-at-verdict ci jobs "$GR" 7 1 >"$T/jobs-$1.tsv" 2>"$T/jobs-$1.err"
    jrc=$?
    ci guard "$AV" "$SHA" "$T/jobs-$1.tsv" >"$T/guard-$1.txt"
    mout=$(ci retry-signal "$T/jobs-$1.tsv" "$SHA" full "$T/guard-$1.txt")
    msig=$(printf '%s\n' "$mout" | sed -n 's/^::notice:://p')
    {
      workload
      ok_verdict
    } >"$T/rows"
    ctl "$1"
  }
  # refused NAME WHAT — mcase NAME, and neither half moves.
  refused() {
    mcase "$1"
    assert_eq "$msig" "" "ci-retry-metadata-$1: $2: the verdict job leaves no signal"
    assert_eq "$posts" "" "ci-retry-metadata-$1: $2: the controller, its verdict signalling, makes no POST"
  }
  # unread NAME — in mcase NAME, tests/ci.sh jobs failed and printed nothing.
  unread() {
    assert_eq "$jrc" 1 "ci-jobs-unread-$1: tests/ci.sh jobs fails"
    assert_eq "$(wc -c <"$T/jobs-$1.tsv" | tr -d ' ')" 0 "ci-jobs-unread-$1: and prints no line to judge"
    assert_contains "$(cat "$T/jobs-$1.err")" "could not be read whole" "ci-jobs-unread-$1: and says so"
  }
  # col NAME ID — job ID's runner and steps as tests/ci.sh jobs printed them in mcase NAME.
  col() { awk -F'\t' -v id="$2" '$1 == id { print $5, $6 }' "$T/jobs-$1.tsv"; }
  J103='(.jobs[] | select(.id == 103))'
  J106='(.jobs[] | select(.id == 106))'
  JOBS=repos_o_r_actions_runs_7_attempts_1_jobs

  # M1: a non-run exactly as GitHub records one — runner_id the number 0,
  # steps the empty array, its annotation read — is eligible by this path.
  MUT="$J103 |= (.runner_id = 0 | .steps = [])"
  mcase m1
  assert_eq "$(jq -c "$J103 | [.runner_id, .steps]" "$T/api/m1/$JOBS.json")" "[0,[]]" "ci-retry-metadata-m1: runner_id the number 0, steps the empty array"
  assert_eq "$msig" "$sig" "ci-retry-metadata-m1: the verdict job signals (M1)"
  assert_eq "$posts" "$POST" "ci-retry-metadata-m1: and the controller makes its one POST (M1)"

  # M2–M9: a non-run's runner_id or steps left out, null or of another type.
  # badfield NAME WHAT FILTER RUNNER_STEPS — job 103 through FILTER: refused,
  # its runner and steps read as RUNNER_STEPS, never as 0.
  badfield() {
    MUT="$J103 |= ($3)"
    refused "$1" "$2"
    assert_eq "$(col "$1" 103)" "$4" "ci-jobs-metadata-$1: $2 reads $4"
  }
  badfield m2 "runner_id left out (M2)" 'del(.runner_id)' '?absent 0'
  assert_contains "$out" "not a runner-acquisition non-run: linux-bash5 · l0 · bash 5 · ShellCheck 0.9.0 (completed/cancelled) · runner ?absent · steps 0" "ci-retry-metadata-m2: is named"
  badfield m3 "runner_id null (M3)" '.runner_id = null' '?null 0'
  badfield m4 'runner_id the text "0" (M4)' '.runner_id = "0"' '?string 0'
  badfield m5 "runner_id an object (M5)" '.runner_id = {}' '?object 0'
  badfield m5-array "runner_id an array (M5)" '.runner_id = [0]' '?array 0'
  badfield m5-number "runner_id a number no runner has (M5)" '.runner_id = 0.5' '?malformed 0'
  badfield m6 "steps left out (M6)" 'del(.steps)' '0 ?absent'
  badfield m7 "steps null (M7)" '.steps = null' '0 ?null'
  badfield m8 "steps an object (M8)" '.steps = {}' '0 ?object'
  badfield m8-string "steps text (M8)" '.steps = ""' '0 ?string'
  badfield m9 "runner_id and steps left out (M9)" 'del(.runner_id, .steps)' '?absent ?absent'
  badfield m9-null "runner_id and steps null (M9)" '.runner_id = null | .steps = null' '?null ?null'

  # M10, M11: the annotation that proves a non-run could not be read, or not
  # as GitHub's list of annotations: no line is printed to judge.
  MUT=
  no_note() { rm "$1/repos_o_r_check-runs_103_annotations.json"; }
  HOOK=no_note
  refused m10 "its annotations could not be read (M10)"
  unread m10
  # An object keyed like a list, its value the very message: still no list.
  note_object() { jq '{"0": .[0]}' "$1/repos_o_r_check-runs_103_annotations.json" >"$1/note" && mv "$1/note" "$1/repos_o_r_check-runs_103_annotations.json"; }
  HOOK=note_object
  refused m11 "its annotations an object, not a list (M11)"
  unread m11
  note_number() { jq 'map(.message = 7)' "$1/repos_o_r_check-runs_103_annotations.json" >"$1/note" && mv "$1/note" "$1/repos_o_r_check-runs_103_annotations.json"; }
  HOOK=note_number
  refused m11-message "an annotation whose message is not text (M11)"
  unread m11-message

  # M12–M14: the jobs read fails before, during or after a valid prefix.
  no_jobs() { rm "$1/$JOBS.json"; }
  HOOK=no_jobs
  refused m12 "the jobs could not be read at all (M12)"
  unread m12
  assert_contains "$mout" "no job list" "ci-retry-metadata-m12: retry-signal says why"
  assert_eq "$rc" 1 "ci-retry-metadata-m12: the controller fails"
  HOOK=
  MUT='.jobs += ["not a job"] | .total_count += 1'
  refused m13 "a valid prefix, then a job that is not one (M13)"
  unread m13
  assert_eq "$rc" 1 "ci-retry-metadata-m13: the controller fails"
  # pages DIR — the jobs as two pages, the first $PAGE1 on the first, each
  # page counting them all, as GitHub's do; page2_fails DIR — the second
  # page's request fails.
  pages() { jq ".jobs |= .[$PAGE1:]" "$1/$JOBS.json" >"$1/$JOBS.2.json" && jq ".jobs |= .[:$PAGE1]" "$1/$JOBS.json" >"$1/page" && mv "$1/page" "$1/$JOBS.json"; }
  page2_fails() { pages "$1" && mv "$1/$JOBS.2.json" "$1/$JOBS.2.fail"; }
  MUT=
  PAGE1=3
  HOOK=pages
  mcase m14-pages
  assert_eq "$msig · $posts" "$sig · $POST" "ci-retry-metadata-m14-pages: two pages, both read: the verdict signals, the controller makes its POST"
  # Every job the verdict job reads is on the first page; on the second, an
  # executed failure that makes the attempt ineligible.
  MUT='.jobs += [{id: 108, name: "macos-bash32 · m2 · stock /bin/bash 3.2 · BSD userland", status: "completed", conclusion: "failure", runner_id: 1000001753, steps: [{name: "The units", status: "completed", conclusion: "failure"}]}] | .total_count += 1'
  PAGE1=8
  HOOK=page2_fails
  refused m14 "the second page could not be read (M14)"
  unread m14
  HOOK=
  MUT='.total_count += 1'
  refused m14-count "fewer jobs than GitHub counts (M14)"
  unread m14-count

  # M15: a job object whose id and name are not GitHub's: the list is read
  # whole, and the attempt is not proven.
  MUT='.jobs += [{id: null, name: {}, status: "completed", conclusion: "success", runner_id: null, steps: []}] | .total_count += 1'
  refused m15 "a job whose id and name are not GitHub's (M15)"
  assert_eq "$jrc" 0 "ci-jobs-metadata-m15: the list is read whole"
  assert_contains "$out" "a job GitHub did not describe whole: ?null · ?object (completed/success)" "ci-retry-metadata-m15: is named"

  # M16, M17: the verdict job's own runner and steps, as the controller
  # proves its red from them.
  # vbad NAME WHAT FILTER — the verdict job through FILTER: no POST.
  vbad() {
    MUT="$J106 |= ($3)"
    mcase "$1"
    assert_eq "$posts" "" "ci-retry-metadata-$1: $2: no POST"
  }
  vbad m16 "the verdict job's runner_id left out (M16)" 'del(.runner_id)'
  assert_contains "$out" "the verdict job shows runner ?absent and steps 9, not a runner of its own that ran its steps" "ci-retry-metadata-m16: is named"
  vbad m16-null "the verdict job's runner_id null (M16)" '.runner_id = null'
  vbad m16-string "the verdict job's runner_id text (M16)" '.runner_id = "1000001790"'
  vbad m17 "the verdict job's steps left out (M17)" 'del(.steps)'
  vbad m17-null "the verdict job's steps null (M17)" '.steps = null'
  vbad m17-object "the verdict job's steps an object (M17)" '.steps = {}'
  vbad m17-step "a verdict step whose conclusion is not text (M17)" '.steps[4].conclusion = 1'
  assert_contains "$out" "the verdict job shows runner 1000001790 and steps ?malformed" "ci-retry-metadata-m17-step: is named"
  MUT=

  # The run's own record, each field GitHub's and of its type: one left out,
  # null or of another type is unread, never a match.
  {
    workload
    ok_verdict
  } >"$T/rows"
  for f in '.id = "7"' '.run_attempt = "1"' '.head_branch = null' 'del(.event)' '.path = null' '.head_sha = 1' '.head_repository = null' '.repository.full_name = ["o/r"]'; do
    RMUT=$f
    ctl run-record
    assert_eq "$rc $posts" "1 " "ci-retry-run-record: a run record with $f: no POST"
  done
  RMUT=
  assert_contains "$out" "GitHub's record of run 7 could not be read whole; nothing re-run" "ci-retry-run-record: is named"

  # A1–A14: an annotation proves something only when every page GitHub
  # answered is a list and every member of it an annotation whose message is
  # text; the pages are joined only then, in page and member order.
  # paged DIR — job $NOTE_ID's annotations as the pages $NOTE_PAGES names, in
  # order: @ is the list recorded for it, ! a request that fails, and any
  # other page is itself, MSG in it standing for the recorded list's last
  # member (a non-run's annotation; the verdict job's signal).
  paged() {
    local f=$1/repos_o_r_check-runs_${NOTE_ID}_annotations n=1 p m
    [ -f "$f.json" ] || return 0
    mv "$f.json" "$1/recorded"
    m=$(jq -c '.[-1]' "$1/recorded")
    for p in "${NOTE_PAGES[@]}"; do
      case $p in
        '@') cp "$1/recorded" "$f.$n.json" ;;
        '!') touch "$f.$n.fail" ;;
        *) printf '%s\n' "${p//MSG/$m}" >"$f.$n.json" ;;
      esac
      n=$((n + 1))
    done
    mv "$f.1.json" "$f.json"
  }
  # pagecase NAME ID PAGE... — mcase NAME, job ID's annotations as PAGEs.
  pagecase() {
    local name=$1
    NOTE_ID=$2
    shift 2
    NOTE_PAGES=("$@")
    HOOK=paged
    mcase "$name"
    HOOK=
  }
  # note NAME ID — ci_note itself, under the bash under test, over job ID's
  # annotations as mcase NAME's completed run records them; sets nrc, nout.
  note() {
    mkdir -p "$T/note"
    nout=$(PATH="$T/bin:$PATH" GH_FIXTURE=$T/api/$1 "$T_BASH" -c 'f=$(sed -n "/^ci_note() {/,/^}/p" "$1") && eval "$f" && ci_note o/r "$2" "$3"' _ "$REPO/tests/ci.sh" "$2" "$T/note" 2>/dev/null)
    nrc=$?
  }
  # bad NAME PAGE... — a page set that is not GitHub's list of annotations,
  # on each half: as job 103's, a non-run's proof, the verdict job leaves no
  # signal and tests/ci.sh jobs prints nothing; as the completed verdict
  # job's, which carry its signal, the controller's own reread fails. In
  # both, ci_note fails and gives no text, and nothing is POSTed.
  bad() {
    local name=$1
    shift
    pagecase "$name" 103 "$@"
    assert_eq "$msig" "" "ci-retry-pages-$name: [$*] as a non-run's annotation pages: the verdict job leaves no signal"
    unread "$name"
    assert_eq "$rc $posts" "1 " "ci-retry-pages-$name: and the controller, its verdict signalling, makes no POST"
    assert_contains "$out" "could not be read whole" "ci-retry-pages-$name: its own reread failing"
    note "$name" 103
    assert_eq "$([ "$nrc" -ne 0 ] && echo fails) [$nout]" "fails []" "ci-note-pages-$name: ci_note fails and gives no text"
    pagecase "$name-verdict" 106 "$@"
    assert_eq "$msig" "$sig" "ci-retry-pages-$name-verdict: the verdict job, reading no annotation of its own, signals"
    assert_eq "$rc $posts" "1 " "ci-retry-pages-$name-verdict: [$*] as the completed verdict job's annotation pages: the controller makes no POST"
    assert_contains "$out" "could not be read whole" "ci-retry-pages-$name-verdict: its own reread failing"
    note "$name-verdict" 106
    assert_eq "$([ "$nrc" -ne 0 ] && echo fails) [$nout]" "fails []" "ci-note-pages-$name-verdict: ci_note fails and gives no text"
  }

  # A1, A2, A14: valid pages are kept, joined in page and member order, and
  # prove what they say on each half.
  pagecase a1 103 @
  assert_eq "$msig · $posts" "$sig · $POST" "ci-retry-pages-a1: one valid page: the verdict signals, the controller makes its POST (A1)"
  note a1 103
  assert_eq "$nrc [$nout]" "0 [$NOTACQ]" "ci-note-pages-a1: ci_note gives its message"
  pagecase a2 103 @ '[{"message":"on page 2"}]'
  assert_eq "$(awk -F'\t' '$1 == 103 { print $7 }' "$T/jobs-a2.tsv")" "$NOTACQ | on page 2" "ci-jobs-pages-a2: two valid pages, both kept, in page order (A2)"
  assert_eq "$msig · $posts" "$sig · $POST" "ci-retry-pages-a2: the verdict signals, the controller makes its POST (A2)"
  pagecase a2-verdict 106 '[{"message":"Process completed with exit code 1."}]' '[MSG]'
  note a2-verdict 106
  assert_eq "$nrc [$nout]" "0 [Process completed with exit code 1. | $sig]" "ci-note-pages-a2-verdict: the verdict job's two pages, in page order (A2)"
  assert_eq "$posts" "$POST" "ci-retry-pages-a2-verdict: its signal on the second page: the controller makes its POST (A2)"
  pagecase a14 103 '[{"message":"first"},{"message":"second"}]' '[{"message":"third"},MSG]'
  assert_eq "$(awk -F'\t' '$1 == 103 { print $7 }' "$T/jobs-a14.tsv")" "first | second | third | $NOTACQ" "ci-jobs-pages-a14: two pages of two, in page and member order (A14)"
  note a14 103
  assert_eq "$nrc [$nout]" "0 [first | second | third | $NOTACQ]" "ci-note-pages-a14: ci_note keeps that order (A14)"
  assert_eq "$msig · $posts" "$sig · $POST" "ci-retry-pages-a14: the verdict signals, the controller makes its POST (A14)"

  # A3–A13: a page, or a member of one, that is not GitHub's.
  bad a3 @ null
  bad a4 null @
  bad a5 null
  bad a6 @ MSG
  bad a7 MSG @
  bad a8-number @ 7
  bad a8-text @ '"text"'
  bad a8-boolean @ true
  bad a9 '[MSG,null]'
  bad a10 '[MSG,{"title":"no message"}]'
  bad a11 '[MSG,{"message":null}]'
  bad a12-number '[MSG,{"message":7}]'
  bad a12-object '[MSG,{"message":{}}]'
  bad a12-array '[MSG,{"message":[]}]'
  bad a13 @ '!'
else
  skip "the retry controller reads GitHub's API through gh --jq (no jq)"
fi

# --- ci-evidence-*: what a shard records ------------------------------------
F=$T/repo
mkdir -p "$F/tests"
cp "$REPO/tests/ci.sh" "$F/tests/ci.sh"
printf '%s\n' 'echo "  skip a plist section (no plutil)"' 'echo "test-good: 3 passed, 0 failed, 1 skipped"' >"$F/tests/test-good.sh"
printf '%s\n' 'echo "test-bad: 1 passed, 2 failed, 0 skipped"' 'exit 1' >"$F/tests/test-bad.sh"
{
  printf 'lane\tlx\trunner\tany\tany\t.\tnone\tgood bad\n'
  printf 'lane\tly\trunner\tany\tany\t^9\\.\tnone\tgood\n'
  printf 'unit\tlx\ts1\tsuite:good\n'
  printf 'unit\tlx\ts1\tstep:elsewhere\n'
  printf 'unit\tlx\ts1\tsuite:bad\n'
  printf 'unit\tly\ts1\tsuite:good\n'
} >"$F/tests/ci-manifest.tsv"
fake() { GITHUB_ENV='' OMB_EVIDENCE=$T/ev.tsv OMB_CI_MODE=full "$T_BASH" "$F/tests/ci.sh" "$@"; }
fake begin lx s1 >/dev/null
OMB_LANE=lx OMB_SHARD=s1 fake shard >"$T/shard.out"
assert_rc "$?" 1 "ci-evidence-shard: a shard with a failed suite fails"
row() { awk -F'\t' -v t="$1" -v n="$2" '$1 == t && $2 == n' "$T/ev.tsv"; }
assert_eq "$(row lane lx)" "lane${TAB}lx" "ci-evidence-header: the lane"
assert_eq "$(row mode full | cut -f2)" full "ci-evidence-header: the mode"
assert_eq "$(row os "$(uname -s)" | cut -f2)" "$(uname -s)" "ci-evidence-header: the platform"
assert_eq "$(row unit suite:good | cut -f3,4,7)" "pass${TAB}0${TAB}test-good: 3 passed, 0 failed, 1 skipped" "ci-evidence-unit: a passing suite and its count"
assert_eq "$(row unit suite:good | cut -f5)" "$("$T_BASH" -c 'echo "$BASH_VERSION"')" "ci-evidence-unit: the bash under test it ran under"
assert_eq "$(row skip suite:good | cut -f3)" "a plist section (no plutil)" "ci-evidence-skip: each skip it printed"
assert_eq "$(row unit suite:bad | cut -f3,4,7)" "fail${TAB}1${TAB}test-bad: 1 passed, 2 failed, 0 skipped" "ci-evidence-unit: a failing suite runs and is recorded"
assert_eq "$(row unit step:elsewhere)" "" "ci-evidence-steps: a step unit is the workflow's to record"
: >"$T/ev.tsv"
OMB_LANE=ly OMB_SHARD=s1 fake shard >"$T/shard.out"
assert_rc "$?" 1 "ci-evidence-shell: a lane's units never run under another bash"
assert_contains "$(cat "$T/shard.out")" "the ly lane runs under a bash matching ^9\\.; " "ci-evidence-shell: says so"
assert_eq "$(row unit suite:good)$(row setup shell | cut -f3)" fail "ci-evidence-shell: and records no unit"
fake setup bash-5.3.15 -- sh -c 'exit 75' >/dev/null
assert_rc "$?" 75 "ci-evidence-setup: a setup step keeps its status"
assert_eq "$(row setup bash-5.3.15 | cut -f3,4)" "fail${TAB}75" "ci-evidence-setup: and records it"
if command -v jq >/dev/null 2>&1; then
  : >"$T/ev.tsv"
  OMB_STEPS='{"unit-fmt":{"outputs":{},"outcome":"success","conclusion":"success"},"unit-pty":{"outputs":{},"outcome":"failure","conclusion":"failure"},"unit-later":{"outputs":{},"outcome":"skipped","conclusion":"skipped"},"tools":{"outputs":{},"outcome":"success","conclusion":"success"}}' fake steps
  assert_eq "$(cut -f1-4 "$T/ev.tsv" | tr '\t\n' ' |')" "unit step:fmt pass 0|unit step:pty fail 1|" "ci-evidence-steps: each unit- step that ran, and only those"
else
  skip "ci.sh steps reads the steps context with jq (no jq)"
fi

# --- ci-diag-units: tests/test-diag.sh runs the units it is given ------------
out=$(OMB_DIAG_UNITS=nope "$T_BASH" "$REPO/tests/test-diag.sh")
assert_rc "$?" 1 "ci-diag-units: a unit test-diag.sh does not list"
assert_contains "$out" "OMB_DIAG_UNITS names nope, which is not a diagnostics unit" "ci-diag-units: is named"
out=$(OMB_DIAG_UNITS=bounds "$T_BASH" "$REPO/tests/test-diag.sh")
assert_rc "$?" 0 "ci-diag-units: one unit alone"
assert_contains "$out" "test-diag-bounds: " "ci-diag-units: runs it"
assert_not_contains "$out" "test-diag-temp: " "ci-diag-units: and no other"
assert_contains "$out" "test-diag: 6 passed, 0 failed" "ci-diag-units: with the listing checks"

# --- ci-bash-*: a source is used only with its pinned digest -----------------
B=$T/bash
mkdir -p "$B/good/bash-5.3-patches" "$B/bad/bash-5.3-patches"
printf 'the tarball\n' >"$B/good/bash-5.3.tar.gz"
printf 'patch one\n' >"$B/good/bash-5.3-patches/bash53-001"
printf 'patch two\n' >"$B/good/bash-5.3-patches/bash53-002"
printf 'patch one, changed\n' >"$B/bad/bash-5.3-patches/bash53-001"
{
  echo "# the test's pin"
  printf '%s  bash-5.3.tar.gz\n' "$(digest "$B/good/bash-5.3.tar.gz")"
  printf '%s  bash53-001\n' "$(digest "$B/good/bash-5.3-patches/bash53-001")"
  printf '%s  bash53-002\n' "$(digest "$B/good/bash-5.3-patches/bash53-002")"
} >"$B/pin"
src() { # ORIGINS DIR — sets out and rc
  out=$(OMB_BASH_PIN=$B/pin OMB_BASH_ORIGINS=$1 "$T_BASH" "$REPO/tests/ci-bash.sh" sources "$2" 2>&1)
  rc=$?
}
src "file://$B/none file://$B/bad file://$B/good" "$B/src"
assert_rc "$rc" 0 "ci-bash-origins: every pinned file from the origins in order"
assert_contains "$out" "file://$B/none: bash-5.3.tar.gz not fetched" "ci-bash-origins: an origin without the file is passed over"
assert_contains "$out" "file://$B/bad served bash53-001 with another digest; not used" "ci-bash-digest: a file with another digest is not used"
assert_contains "$out" "fetched bash53-001 from file://$B/good" "ci-bash-origins: the origin that delivered each file is named"
assert_eq "$(cat "$B/src/bash53-001")" "patch one" "ci-bash-digest: the pinned bytes, not the other origin's"
assert_contains "$out" "bash53-002: OK" "ci-bash-strict: the whole pin is checked strictly at the end"
printf 'patch t' >"$B/src/bash53-002"
rm "$B/src/bash-5.3.tar.gz"
src "file://$B/good" "$B/src"
assert_rc "$rc" 0 "ci-bash-cache: a restored cache is held to the pin"
assert_contains "$out" "cached: bash53-001" "ci-bash-cache: a cached file with its digest is used"
assert_contains "$out" "cached bash53-002 does not match its pinned digest; fetching it again" "ci-bash-cache: a short or changed cached file is not"
assert_contains "$out" "fetched bash-5.3.tar.gz from file://$B/good" "ci-bash-cache: a missing cached file is fetched again"
assert_eq "$(cat "$B/src/bash53-002")" "patch two" "ci-bash-cache: and replaced with the pinned bytes"
src "file://$B/none file://$B/bad" "$B/src2"
assert_rc "$rc" 75 "ci-bash-exhausted: no origin with the pinned file is external infrastructure"
assert_contains "$out" "source acquisition exhausted: no origin delivered bash53-001 with its pinned digest" "ci-bash-exhausted: is named"
assert_eq "$(ls "$B/src2")" "" "ci-bash-exhausted: and nothing with another digest is kept"

t_done test-ci
