#!/usr/bin/env bash
# The fake children (tests/children) read their fixture's key=value lines in
# the shell, one lookup at a time and when it is asked for, rather than with a
# sed and a tail for every key. They must behave exactly as they did before
# that change: every case below runs the children of c855f61, the commit the
# change starts from, and the current ones, each from the same relative path,
# with the same environment, input and fixture, and compares the exit status,
# the output and every file the child wrote. Two cases rewrite or remove the
# fixture's file while the child sleeps, so a key read later must see the file
# as it is then, as each sed did.
# shellcheck disable=SC2015 # ok/fail always return 0
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-fake-children"
BEFORE=c855f6197be86e90f5fb833f7faec0d0f6372794
T=$(t_tmp)

if ! git -C "$REPO" cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
  fail "$BEFORE, the children before the change, is not in this clone (CI checks out with fetch-depth: 0)"
  t_done test-fake-children
  exit
fi
mkdir -p "$T/old" "$T/new/tests"
git -C "$REPO" archive "$BEFORE" tests/children | tar -x -C "$T/old" || fail "the children of $BEFORE could not be extracted"
cp -R "$REPO/tests/children" "$T/new/tests/"

# prepare WHICH NAME CHILD CONF — NAME's folder in WHICH tree (old, new): the
# fixture's file for CHILD holding CONF (printf %b; "-" for no file), and an
# empty folder for what the child writes. Prints the folder.
prepare() {
  local d=$T/$1/$2
  mkdir -p "$d/fx/test-children" "$d/out"
  [ "$4" = - ] || printf '%b' "$4" >"$d/fx/test-children/$3"
  printf '%s' "$d"
}

# launch DIR CHILD INPUT [ARGS...] — run fake-CHILD from DIR as
# ../tests/children/fake-CHILD, so both trees give it the same $0, with INPUT
# (printf %b) on its input and nothing in its environment but these.
launch() {
  local d=$1 child=$2 input=$3
  shift 3
  (cd "$d" && printf '%b' "$input" | env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C OMB_FIXTURE=fx \
    "../tests/children/fake-$child" "$@" >stdout 2>stderr
  printf '%s' "$?" >"$d/status")
}

# settle DIR — wait, at most 10 s, until every process the child recorded in
# out/pids has ended (read with ps, never signalled) and an escaped writer has
# written its ten bytes, so nothing it started is still writing.
settle() {
  local d=$1 i=0 busy pid
  while [ "$i" -lt 200 ]; do
    busy=0
    if [ -f "$d/out/pids" ]; then
      while read -r pid _; do
        [ -n "$(ps -p "$pid" -o pid= 2>/dev/null)" ] && busy=1
      done <"$d/out/pids"
    fi
    if [ -f "$d/expect-escaped" ] && command -v perl >/dev/null 2>&1; then
      [ "$(wc -c <"$d/out/escaped" 2>/dev/null | tr -d ' ')" = 10 ] || busy=1
    fi
    [ "$busy" = 0 ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
}

# dump DIR — what a run left, in a fixed order: its status, its output and
# error, and every file it wrote; a pids file by its line count, since a PID
# and a start time differ from run to run.
dump() {
  local d=$1 f
  printf 'status %s\n' "$(cat "$d/status")"
  printf -- '-- stdout\n'
  od -An -c "$d/stdout"
  printf -- '-- stderr\n'
  od -An -c "$d/stderr"
  (cd "$d/out" && find . -type f | LC_ALL=C sort) | while read -r f; do
    printf -- '-- %s\n' "$f"
    case "$f" in
      ./pids) wc -l <"$d/out/$f" | tr -d ' ' ;;
      *) od -An -c "$d/out/$f" ;;
    esac
  done
}

# agree NAME — the old and the new run of NAME left the same thing.
agree() {
  dump "$T/old/$1" >"$T/old/$1.dump"
  dump "$T/new/$1" >"$T/new/$1.dump"
  if cmp -s "$T/old/$1.dump" "$T/new/$1.dump"; then
    ok
  else
    fail "$1: the child differs from $BEFORE's"
    diff "$T/old/$1.dump" "$T/new/$1.dump" | head -20
  fi
}

# same NAME CHILD INPUT CONF [ARGS...] — one case, run by both trees.
same() {
  local name=$1 child=$2 input=$3 conf=$4 which d
  shift 4
  for which in old new; do
    d=$(prepare "$which" "$name" "$child" "$conf")
    case "$conf" in *escape=1*) : >"$d/expect-escaped" ;; esac
    launch "$d" "$child" "$input" "$@"
    settle "$d"
  done
  agree "$name"
}

# --- The read child ------------------------------------------------------------------------
same read-no-file read "" -
same read-empty-file read "" ""
same read-text read "" 'stderr_text=hello\n'
same read-bytes read "" 'stderr_bytes=10\n'
same read-bytes-zero read "" 'stderr_bytes=0\n'
same read-stdout read "" 'stdout_bytes=7\nstderr_text=x\n'
same read-exit read "" 'exit=3\n'
same read-last-wins read "" 'exit=1\nexit=4\nstderr_text=a\nstderr_text=b\n'
same read-empty-value read "" 'stderr_text=\nstderr_bytes=5\n'
same read-empty-last read "" 'stderr_text=first\nstderr_text=\n'
same read-equals-spaces read "" 'stderr_text=a = b  \n'
same read-backslashes read "" 'stderr_text=a\\b\\n\n'
same read-no-final-newline read "" 'exit=2'
same read-carriage-return read "" 'stderr_text=x\r\n'
same read-unknown-key read "" 'nope=1\nstderr_text=y\n'
same read-leading-space read "" ' exit=5\nstderr_text=z\n'
same read-longer-key read "" 'grandchild_fds=out/g\nstderr_text=w\n'
same read-fds read "" 'fds=out/fds\n'
same read-grandchild read "" 'grandchild=0\ngrandchild_fds=out/gfds\npids=out/pids\n'
same read-sleep read "" 'sleep=0\nexit=0\n'
same read-everything read "" 'fds=out/fds\nstderr_bytes=3\nstdout_bytes=4\nstderr_text=t\nexit=6\n'

# --- The mutating child --------------------------------------------------------------------
same mutate-no-file mutate "" - out/effect WANT
same mutate-empty-file mutate "" "" out/effect WANT
same mutate-none mutate "" 'effect=none\n' out/effect WANT
same mutate-unexpected mutate "" 'effect=unexpected\n' out/effect WANT
same mutate-out-bytes mutate "" 'out_bytes=5\n' out/effect WANT
same mutate-exit mutate "" 'exit=7\n' out/effect WANT
same mutate-last-wins mutate "" 'effect=none\neffect=unexpected\n' out/effect WANT
same mutate-no-final-newline mutate "" 'effect=none' out/effect WANT
same mutate-fds mutate "" 'fds=out/fds\n' out/effect WANT
same mutate-linger mutate "" 'linger=0\npids=out/pids\n' out/effect WANT
same mutate-grandchild mutate "" 'grandchild=0\ngrandchild_fds=out/gfds\npids=out/pids\n' out/effect WANT
same mutate-escape mutate "" 'escape=1\nescape_out=out/escaped\n' out/effect WANT

# --- The handoff child ---------------------------------------------------------------------
same handoff-no-file handoff 'typed line\n' - out/effect WANT
same handoff-keys handoff 'typed line\n' 'keys_out=out/keys\n' out/effect WANT
same handoff-no-input handoff "" 'keys_out=out/keys\n' out/effect WANT
same handoff-none handoff 'x\n' 'effect=none\n' out/effect WANT
same handoff-last-wins handoff 'y\n' 'effect=none\neffect=go\n' out/effect WANT
same handoff-report handoff 'x\n' 'report=out/report\n' out/effect WANT
same handoff-fds handoff 'x\n' 'fds=out/fds\n' out/effect WANT
same handoff-raw handoff 'x\n' 'leave_raw=1\n' out/effect WANT

# --- The fixture's file changed while the child sleeps -------------------------------------
# A key read after the sleep sees the file as it is then: rewritten, the mutating
# child writes what the new file says; removed, the read child exits 0.
# changed NAME CHILD CONF NEW [ARGS...] — start CHILD with CONF (which makes it
# sleep), wait until it is inside that sleep, so every key before it has been
# read, then write NEW over the file ("-" removes it), and wait for the child.
# Inside its sleep: a process whose parent is the child, read with ps (by its
# parent's PID, never by a name, and never signalled), is a sleep.
changed() {
  local name=$1 child=$2 conf=$3 new=$4 which d pid i
  shift 4
  for which in old new; do
    d=$(prepare "$which" "$name" "$child" "$conf")
    # exec, twice: $! is the child's own PID.
    (cd "$d" && exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C OMB_FIXTURE=fx \
      "../tests/children/fake-$child" "$@" </dev/null >stdout 2>stderr) &
    pid=$!
    i=0
    until ps -axo ppid=,command= | awk -v p="$pid" '$1 == p && $2 ~ /(^|\/)sleep$/ { f = 1 } END { exit !f }'; do
      [ "$i" -lt 200 ] || break
      sleep 0.05
      i=$((i + 1))
    done
    if [ "$new" = - ]; then
      rm -f "$d/fx/test-children/$child"
    else
      printf '%b' "$new" >"$d/fx/test-children/$child"
    fi
    wait "$pid"
    printf '%s' "$?" >"$d/status"
  done
  agree "$name"
}
changed mutate-rewritten mutate 'sleep=1\n' 'effect=unexpected\n' out/effect WANT
assert_eq "$(cat "$T/new/mutate-rewritten/out/effect")" "something else" "a key read after the sleep sees the rewritten file"
changed read-removed read 'sleep=1\nexit=3\n' -
assert_eq "$(cat "$T/new/read-removed/status")" 0 "a key read after the file is removed is no key"

t_done test-fake-children
