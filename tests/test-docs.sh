#!/usr/bin/env bash
# The documentation checks (docs/TESTING.md → *Documentation checks*), docs-*
# over SPEC.md, MILESTONES.md, README.md, AGENTS.md, CLAUDE.md and docs/: the
# documents that define the product agree with each other wherever a machine
# can tell. The rows of TESTING.md that define these checks name the words
# they look for, so they are left out of what is checked.
# shellcheck disable=SC2015,SC2016 # ok/fail always return 0; literal backquotes in patterns
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-docs"
cd "$REPO" || exit 1
DOCS=(SPEC.md MILESTONES.md README.md AGENTS.md CLAUDE.md docs/*.md)

# units — every paragraph, and every table row on its own, as one line:
# FILE TAB TEXT.
units() {
  local f
  for f in "${DOCS[@]}"; do
    awk -v f="$f" '
      function flush() { if (p != "") print f "\t" p; p = "" }
      /^\| `docs-/ { flush(); next }
      /^\|/ { flush(); print f "\t" $0; next }
      /^[[:space:]]*$/ { flush(); next }
      { p = p " " $0 }
      END { flush() }
    ' "$f"
  done
}

# where ERE — every line matching ERE, with the heading it sits under:
# FILE TAB HEADING TAB LINE.
where() {
  local f
  for f in "${DOCS[@]}"; do
    awk -v f="$f" -v re="$1" '
      /^\| `docs-/ { next }
      /^#+ / { h = $0; sub(/^#+ +/, "", h); next }
      $0 ~ re { print f "\t" h "\t" $0 }
    ' "$f"
  done
}

# headings FILE — its headings' text, and again without a leading "N. ".
headings() {
  sed -n 's/^#\{1,6\} \{1,\}//p' "$1" | sed 's/[[:space:]]*$//'
  sed -n 's/^#\{1,6\} \{1,\}[0-9]\{1,\}\. //p' "$1" | sed 's/[[:space:]]*$//'
}

# section FILE HEADING — the lines under a level-2 or level-3 heading, up to
# the next heading of the same or a higher level.
section() {
  awk -v want="$2" '
    /^#+ / {
      n = index($0, " ") - 1; t = substr($0, n + 2)
      if (on && n <= lvl) exit
      if (t == want) { on = 1; lvl = n; next }
    }
    on
  ' "$1"
}

# --- docs-agents-claude -----------------------------------------------------------------
cmp -s AGENTS.md CLAUDE.md && ok || fail "docs-agents-claude: AGENTS.md and CLAUDE.md differ"

# --- docs-refs: FILE → *Section* and FILE → §N name real headings -----------------------
n=0
for f in "${DOCS[@]}"; do
  refs=$(grep -v '^| `docs-' "$f" | tr '\n' ' ' | tr -s ' ' | grep -oE '[A-Za-z0-9_./-]+\.md → (\*[^*]+\*|§[0-9]+(–§[0-9]+)?)')
  [ -n "$refs" ] || continue
  while IFS= read -r r; do
    n=$((n + 1))
    target=${r%% → *}
    what=${r#* → }
    if [ -f "$target" ]; then
      :
    elif [ -f "docs/$target" ]; then
      target=docs/$target
    else
      fail "docs-refs: $f names $target, which does not exist"
      continue
    fi
    case "$what" in
      '§'*)
        for num in $(printf '%s' "$what" | grep -oE '[0-9]+'); do
          grep -qE "^## $num\. " "$target" || fail "docs-refs: $f names $target → §$num, which has no such section"
        done
        ;;
      *)
        s=${what#\*}
        s=${s%\*}
        headings "$target" | grep -qxF -- "$s" || fail "docs-refs: $f names $target → *$s*, which has no such heading"
        ;;
    esac
  done <<EOF
$refs
EOF
done
[ "$n" -ge 50 ] && ok || fail "docs-refs: only $n references read; the reader is broken"

# --- docs-test-ids: every test id SECURITY.md cites is defined in TESTING.md -------------
# Defined: in the first cell of a TESTING.md table row (and the second, when
# the first is a family such as `mcp-*` listing its members), in a heading,
# or in a sentence that lists ids ("One id per …"). A template such as
# `persist-death-<B>` defines `persist-death-*`; a cited family is defined by
# its members. A name followed by "corpus" is an outside corpus, not an id.
defined=$(
  {
    sed 's/<[A-Za-z]*>/*/g' docs/TESTING.md | grep -E '^\| `' | awk -F'|' '{ print $2; if ($2 ~ /^ `[a-z]+-\*` $/) print $3 }'
    grep -E '^#' docs/TESTING.md
    tr '\n' ' ' <docs/TESTING.md | grep -oE 'One id per[^.]*\.'
  } | grep -oE '`[a-z]+-[a-z0-9*-]+`' | tr -d '`' | awk '!seen[$0]++'
)
families=$(printf '%s\n' "$defined" | sed 's/-.*//' | awk '!seen[$0]++')
cited=$(sed -E 's/`[^`]+` corpus//g' docs/SECURITY.md | grep -oE '`[a-z]+-[a-z0-9*-]+`' | tr -d '`' | awk '!seen[$0]++')
n=0
for id in $cited; do
  printf '%s\n' "$families" | grep -qxF -- "${id%%-*}" || continue
  n=$((n + 1))
  printf '%s\n' "$defined" | grep -qxF -- "$id" && continue
  case "$id" in
    *'*') printf '%s\n' "$defined" | grep -qF -- "${id%\*}" && continue ;;
  esac
  fail "docs-test-ids: SECURITY.md cites $id, which TESTING.md does not define"
done
[ "$n" -ge 20 ] && ok || fail "docs-test-ids: only $n cited ids read; the reader is broken"

# --- docs-states: every state in SPEC.md → *States* is in its owner's document ----------
# The owners are the documents SPEC.md → *Product expansion* hands each
# subsystem to.
n=0
rows=$(section SPEC.md States | grep -E '^\| [A-Za-z]' | grep -v '^| Subsystem')
while IFS='|' read -r _ sub states _; do
  sub=$(printf '%s' "$sub" | sed 's/^ *//; s/ *$//')
  case "$sub" in
    profile*) owner=docs/MIGRATION.md ;;
    resolution*) owner=docs/RESOLVER.md ;;
    restore*) owner=docs/RESTORE.md ;;
    'AI tool'*) owner=docs/AI-TOOLS.md ;;
    rescue*) owner=docs/RESCUE.md ;;
    operation*) owner=docs/PROTOCOL.md ;;
    qualification* | journey*) owner=docs/QUALIFICATION.md ;;
    frontend*) owner=docs/FRONTEND.md ;;
    *)
      fail "docs-states: no owning document is known for the subsystem '$sub'"
      continue
      ;;
  esac
  for s in $(printf '%s' "$states" | grep -oE '`[a-z_-]+`' | tr -d '`' | awk '!seen[$0]++'); do
    n=$((n + 1))
    grep -qF -- "\`$s\`" "$owner" || fail "docs-states: $sub state $s is not defined in $owner"
  done
done <<EOF
$rows
EOF
[ "$n" -ge 60 ] && ok || fail "docs-states: only $n states read; the reader is broken"

# --- docs-commands: every command named is in SPEC.md → *Commands*, with an intent -------
cmds=""
n=0
table=$(section SPEC.md Commands | grep -E '^\| (`|\*\(none\))')
while IFS='|' read -r _ cell intent _; do
  intent=$(printf '%s' "$intent" | sed 's/^ *//; s/ *$//')
  case "$intent" in
    read | plan | act | 'act, scoped' | 'per operation') ;;
    *) fail "docs-commands: SPEC.md → *Commands* gives '$cell' the intent '$intent'" ;;
  esac
  for span in $(printf '%s' "$cell" | grep -oE '`[^`]+`' | tr ' ' '_'); do
    c=$(printf '%s' "$span" | tr -d '`' | tr '_' ' ' | sed 's/\[[^]]*\]//g' |
      awk '{ o = ""; for (i = 1; i <= NF; i++) { if ($i !~ /^[a-z][a-z-]*$/) break; o = o (o == "" ? "" : " ") $i } print o }')
    cmds="$cmds$c
"
    n=$((n + 1))
  done
done <<EOF
$table
EOF
[ "$n" -ge 25 ] && ok || fail "docs-commands: only $n commands read from SPEC.md; the reader is broken"
known() { printf '%s' "$cmds" | grep -qxF -- "$1"; }
named=$(for f in "${DOCS[@]}"; do grep -v '^| `docs-' "$f" | grep -oE '(\./|/|`)omarchy-bootstrap( +[a-z][a-z-]*)*' | sed -E 's/^.*omarchy-bootstrap *//' | sed "s|^|$f	|"; done)
n=$(printf '%s\n' "$named" | grep -c .)
while IFS='	' read -r f words; do
  [ -n "$words" ] || continue # the default run
  w1=${words%% *}
  w2=$(printf '%s' "$words" | awk '{ print $2 }')
  if known "$w1 $w2" || known "$w1"; then continue; fi
  fail "docs-commands: $f names 'omarchy-bootstrap $words', which SPEC.md → *Commands* does not list"
done <<EOF
$named
EOF
[ "$n" -ge 20 ] && ok || fail "docs-commands: only $n invocations read; the reader is broken"

# --- docs-read-writes: no read command is described as writing anything -----------------
verbs='(^|[^a-z])(write|writes|written|save|saves|saved|create|creates|store|stores|remove|removes|delete|deletes|move|moves|download|downloads)([^a-z]|$)'
reads=""
while IFS='|' read -r _ cell intent mac linux _; do
  intent=$(printf '%s' "$intent" | sed 's/^ *//; s/ *$//')
  [ "$intent" = read ] || continue
  said=$(printf '%s %s' "$mac" "$linux" | sed -E 's/writes? nothing//g; s/writes? no [a-z]+//g')
  if printf '%s' "$said" | grep -qE "$verbs"; then
    fail "docs-read-writes: the read command $cell is described as writing: $said"
  fi
  reads="$reads$(printf '%s' "$cell" | grep -oE '`[^`]+`' | tr -d '`' | sed 's/ *\[[^]]*\]//g')
"
done <<EOF
$table
EOF
bad=$(units | READS=$reads awk -F'\t' '
  BEGIN { n = split(ENVIRON["READS"], r, "\n") }
  { for (i = 1; i <= n; i++) if (r[i] != "") {
      k = index($2, "`" r[i] "` ")
      s = substr($2, k + length(r[i]) + 3)
      if (k && s ~ /^(writes|saves|creates|stores|records) / && s !~ /^writes (nothing|no )/) print $1 ": `" r[i] "` " substr(s, 1, 30)
    } }')
[ -z "$bad" ] && ok || fail "docs-read-writes: a read command described as writing: $bad"

# --- docs-milestones: each gate and milestone defined once; M17 and M18 not started ------
ids=$(grep -E '^#{2,3} (M[0-9]+(-[A-Z])?|Gate [0-9]+) ' MILESTONES.md | sed -E 's/^#+ //; s/^(M[0-9]+(-[A-Z])?|Gate [0-9]+) .*/\1/')
dup=$(printf '%s\n' "$ids" | awk 'seen[$0]++ == 1')
[ -z "$dup" ] && ok || fail "docs-milestones: defined more than once in MILESTONES.md: $dup"
elsewhere=$(for f in "${DOCS[@]}"; do [ "$f" = MILESTONES.md ] || grep -HE '^#+ (M[0-9]+(-[A-Z])?|Gate [0-9]+) —' "$f"; done)
[ -z "$elsewhere" ] && ok || fail "docs-milestones: a gate or milestone defined outside MILESTONES.md: $elsewhere"
mentioned=$(for f in "${DOCS[@]}"; do grep -v '^| `docs-' "$f"; done | grep -oE '(M1[4-8](-[A-C])?|[Gg]ate [0-5])([^0-9A-Za-z-]|$)' |
  sed -E 's/[^0-9A-Za-z]$//; s/^gate/Gate/' | awk '!seen[$0]++')
while IFS= read -r m; do
  [ -n "$m" ] || continue
  c=$(printf '%s\n' "$ids" | grep -cxF -- "$m")
  [ "$c" = 1 ] || fail "docs-milestones: $m is named, and defined $c times in MILESTONES.md"
done <<EOF
$mentioned
EOF
for m in M17 M18; do
  st=$(awk -v m="$m" '/^## / { on = (index($0, "## " m " ") == 1); next } on && /\*\*Status:\*\*/' MILESTONES.md)
  case "$st" in
    *"not started"*) ok ;;
    *) fail "docs-milestones: $m's status is not 'not started': $st" ;;
  esac
done

# --- docs-shell: the target shell is Bash wherever one is named -------------------------
bad=$(units | awk -F'\t' 'tolower($2) ~ /target shell/ && $2 !~ /Bash/ { print $1 ": " substr($2, 1, 100) }')
[ -z "$bad" ] && ok || fail "docs-shell: a target shell named without Bash: $bad"
[ "$(units | grep -ci 'target shell')" -ge 3 ] && ok || fail "docs-shell: the target shell is not named where it is decided"

# --- docs-windows: Windows appears only as a non-goal ------------------------------------
bad=$(where '(^|[^A-Za-z])Windows([^A-Za-z]|$)' | awk -F'\t' '!($1 == "SPEC.md" && $2 == "Non-goals")')
[ -z "$bad" ] && ok || fail "docs-windows: Windows outside SPEC.md → *Non-goals*: $bad"
section SPEC.md Non-goals | grep -qw Windows && ok || fail "docs-windows: SPEC.md → *Non-goals* no longer names Windows"

# --- docs-debug-names: debug, debug context, debug raw, debug save -----------------------
bad=$(
  {
    for f in "${DOCS[@]}"; do grep -v '^| `docs-' "$f"; done | grep -oE '`debug [^`]*`' | tr -d '`'
    printf '%s\n' "$named" | cut -f2 | grep '^debug '
  } | awk '$2 != "context" && $2 != "raw" && $2 != "save"'
)
[ -z "$bad" ] && ok || fail "docs-debug-names: another debug subcommand named: $bad"

# --- docs-sudo-k: sudo -k only in docs/DECISIONS.md → *Rejected* -------------------------
bad=$(where 'sudo -k' | awk -F'\t' '!($1 == "docs/DECISIONS.md" && $2 ~ /^Rejected/)')
[ -z "$bad" ] && ok || fail "docs-sudo-k: sudo -k outside docs/DECISIONS.md → *Rejected*: $bad"

# --- docs-sessions: agent sessions and histories only as not carried in v1 ----------------
bad=$(units | awk -F'\t' '{ t = tolower($2) } t ~ /agent sessions?|histories/ && t !~ /not in v1|no sessions or histories in v1|not carried/ { print $1 ": " substr($2, 1, 100) }')
[ -z "$bad" ] && ok || fail "docs-sessions: agent sessions or histories not marked as not carried in v1: $bad"

t_done test-docs
