#!/bin/sh
# bash-trap-comsub.sh BASH [N] — the Bash 5.2 defect the core's signal storm
# names (docs/TESTING.md → sup-eintr), reproduced without this tool: a trap
# that runs while a command holding two command substitutions is expanded
# corrupts the parser ("trap: line 2: unexpected EOF while looking for
# matching `)'"), and the command fails. Reported upstream as "Parse error in
# bash 5.2+ with CHLD trap and 2 or more $() in a command" (bug-bash,
# 2023-09-06, https://lists.gnu.org/archive/html/bug-bash/2023-09/msg00058.html)
# and fixed in Bash's development branch that month, which became 5.3; the
# same report for 5.2.26 was answered as fixed by it (bug-bash, 2024-02-03,
# https://lists.gnu.org/archive/html/bug-bash/2024-02/msg00029.html). Any
# trap will do: here SIGHUP, as in the storm.
#
# BASH runs N commands `x="$(printf a)$(printf b)"` with a HUP trap set,
# while its parent sends it SIGHUP every 2 ms (a PID is never reused before
# its parent collects it). Prints BASH's version and what failed; exits 1
# when any command failed, 0 when none did.
# shellcheck disable=SC2016 # literal $ in the script the other shell runs
b=${1:?usage: bash-trap-comsub.sh BASH [N]}
n=${2:-20000}
out=$(mktemp) || exit 2
perl -e '
  use POSIX ":sys_wait_h";
  my ($out, @cmd) = @ARGV;
  my $pid = fork() // exit 2;
  if ($pid == 0) { open(STDOUT, ">", $out) or exit 2; open(STDERR, ">&STDOUT") or exit 2; exec @cmd or exit 127 }
  # The trap is set once the shell has said so.
  select(undef, undef, undef, 0.01) until -s $out || waitpid($pid, WNOHANG);
  until (waitpid($pid, WNOHANG)) { kill("HUP", $pid); select(undef, undef, undef, 0.002) }
  exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
' "$out" "$b" -c '
  trap ":" HUP
  echo ready
  n=$1 bad=0 i=0
  while [ "$i" -lt "$n" ]; do
    x="$(printf a)$(printf b)"
    [ "$x" = ab ] || bad=$((bad + 1))
    i=$((i + 1))
  done
  echo "done $bad"
' storm "$n"
st=$?
v=$("$b" -c 'echo "$BASH_VERSION"')
wrong=$(sed -n 's/^done //p' "$out")
parse=$(grep -c "unexpected EOF while looking for matching" "$out")
printf 'bash %s: %s commands, %s gave the wrong value, %s parse errors, exit %s\n' "$v" "$n" "${wrong:-?}" "$parse" "$st"
grep -m 3 "unexpected EOF" "$out"
rm -f "$out"
[ "$st" = 0 ] && [ "${wrong:-1}" = 0 ] && [ "$parse" = 0 ]
