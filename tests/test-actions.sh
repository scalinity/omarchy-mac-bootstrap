#!/usr/bin/env bash
# The installer's rows of the core's action table through `core execute`
# (docs/TESTING.md → Planned suites → tests/test-actions.sh): each row over
# the lifecycle fixtures — its success path, its refusals (unavailable,
# changed, the word, busy, an unsupervised, failed or unreadable record),
# the classifier's outcome on a fresh read, umask 022 while it runs, the
# interface word answering only the step's first typed prompt — and one
# equiv-* case per row against the accepted baseline 2edb76a. plan.save also
# stops at its first failed write and at a named save boundary, and succeeds
# only as a read-back. Handoff rows run on a terminal of their own (script),
# managed rows with stdin /dev/null; every command is recorded, never run.
# Ids: actions-*, equiv-*.
# shellcheck disable=SC2015,SC2030,SC2031 # ok/fail always return 0; scoped environments
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=tests/core-harness.sh
. "$TESTS_DIR/core-harness.sh"
echo test-actions
# A core that sets no umask of its own would run under this one: any 0022
# the sed shim notes was set by the core for the step.
umask 077
T=$(t_tmp)
BASELINE=2edb76a7de3f78ec90927ac93d5eec3a84636253
GB=1000000000
MIB=1048576
ZERO=$(printf '%064d' 0)
A_ALL=journey,plan,asahi,shared,network,omarchy
REAL_SED=$(command -v sed)
REAL_MV=$(command -v mv)
# The console Omarchy Mac's setup writes to (lib/sources.sh).
OMARCHY_SETUP_TTY=$(sed -n 's/^OMARCHY_SETUP_TTY=//p' "$REPO/lib/sources.sh")
c_session

# The tool under test.
A_TOOL=$REPO

# actions-omarchy.resume-claims: run and new-boot judgement without
# supervised children (the sandbox cannot read the process table). The real
# classifier and judge read fixtures; only the flow and state writes are
# replaced, so no installer or host command runs.
# shellcheck disable=SC2329 # mocks are invoked by the sourced functions
a_resume_observe() (
  local before_fixture=$1 after_fixture=$2 status=$3 fault=$4
  local ran=0 offered run_rc run_finding run_text prior_enc migrate_lookups=0
  t_load >/dev/null 2>&1
  OMB_HOME=$REPO
  # shellcheck source=lib/actions.sh
  . "$REPO/lib/actions.sh"
  OMB_UID=0 OMB_DRY_RUN=0 OMB_FIXTURE=$before_fixture
  eval "$(declare -f sys_cmd | sed '1s/sys_cmd/a_resume_sys_cmd/')"
  eval "$(declare -f lx_detect | sed '1s/lx_detect/a_resume_detect/')"
  sys_cmd() {
    case "$fault:$1" in
      luks:luks_dump | boot-fstype:findmnt_boot_fstype) return 1 ;;
    esac
    a_resume_sys_cmd "$@"
  }
  function [ {
    if builtin test "$#" = 3 && builtin test "$1" = -f; then
      case "$fault:$2" in
        migrate-second:*/etc/omarchy-btrfs-migrate.conf)
          migrate_lookups=$((migrate_lookups + 1))
          if builtin test "$migrate_lookups" = 2; then return 1; fi ;;
      esac
    fi
    builtin [ "$@"
  }
  cat() {
    case "$fault:$*" in setup-read:*/etc/omarchy-mac-setup.conf) return 1 ;; esac
    command cat "$@"
  }
  # The executable's lookup itself failing (an I/O error), and Perl failing
  # to start at all (an unloadable PERL5OPT module): neither is an
  # observation of the executable.
  perl() {
    case "$fault" in
      self-lookup) printf 'failed' && return 0 ;;
      perl-start) return 2 ;;
    esac
    command perl "$@"
  }
  lx_detect() {
    migrate_lookups=0
    if [ "$fault" = migrate-second ]; then
      # Model the reviewer's successful first observation, followed by a
      # failed lookup inside lx_detect_encryption. That failure recovers
      # after the command without the machine having changed.
      [ -f "$(sys_path "$OMS_MIGRATE_CONF")" ] || return 1
    fi
    a_resume_detect
  }
  act_lx_read() { lx_detect; }
  lx_begin() { lx_detect; }
  lx_in_progress() {
    ran=$((ran + 1))
    prior_enc=$LX_ENC_STATE
    return "$status"
  }
  if act_resume_offer; then offered=0; else offered=$?; fi
  if act_resume_run >/dev/null 2>&1; then run_rc=0; else run_rc=$?; fi
  OMB_FIXTURE=$after_fixture
  [ "$fault" != migrate-second ] || fault=''
  act_resume_judge "$run_rc"
  run_finding=$CORE_FINDING run_text=$CORE_JUDGE_TEXT
  # Deliberately leave a stale installed value: reconciliation must read now.
  ACT_READ=linux LX_OMARCHY_STATE=installed
  act_resume_judge reconcile
  printf '%s\n' "offer=$offered" "status=$run_rc" "ran=$ran" \
    "run=$run_finding" "reconcile=$CORE_FINDING" "before-encryption=${prior_enc:-}" "after-encryption=$LX_ENC_STATE" \
    "text=$run_text"
  # A later boot may finish upstream's automatic resume. The same record
  # must then judge completed, without a saved progress stage.
  OMB_FIXTURE=$FIX/linux-omarchy-finishing
  act_resume_judge reconcile
  printf '%s\n' "later=$CORE_FINDING"
)

a_resume_claims() {
  local present missing nonexec fallback runtime staged_luks row label prior after status fault want rwant got p=$T_PASS f=$T_FAIL
  present=$(t_variant linux-setup-in-progress)
  chmod +x "$present/root/usr/local/bin/omarchy-mac-setup"
  missing=$(t_variant linux-setup-in-progress)
  rm -f "$missing/root/usr/local/bin/omarchy-mac-setup"
  nonexec=$(t_variant linux-setup-in-progress)
  chmod -x "$nonexec/root/usr/local/bin/omarchy-mac-setup"
  fallback=$(t_variant linux-omarchy-finishing)
  rm -f "$fallback/root/var/lib/omarchy-mac-setup/installed"
  runtime=$(t_variant linux-setup-in-progress)
  mkdir -p "$runtime/root/usr/share/omarchy"
  printf '3.0.0\n' >"$runtime/root/usr/share/omarchy/version"
  chmod +x "$runtime/root/usr/local/bin/omarchy-mac-setup"
  staged_luks=$(t_variant linux-encrypt-reencrypting)
  printf 'ENCRYPT=1\n' >"$staged_luks/root/etc/omarchy-btrfs-migrate.conf"
  chmod +x "$staged_luks/root/usr/local/bin/omarchy-mac-setup"
  for row in \
    "installed-marker|$present|$FIX/linux-omarchy-finishing|0||completed" \
    "installed-runtime-display|$present|$fallback|1||completed" \
    "missing-127|$present|$missing|127||no-effect" \
    "missing-126|$present|$missing|126||no-effect" \
    "nonexec-126|$present|$nonexec|126||no-effect" \
    "nonexec-127|$present|$nonexec|127||no-effect" \
    "present-127|$present|$present|127||unexpected" \
    "present-126|$present|$present|126||unexpected" \
    "missing-0|$present|$missing|0||unexpected" \
    "missing-1|$present|$missing|1||unexpected" \
    "still-in-progress|$present|$present|0||unexpected" \
    "encryption-advanced|$FIX/linux-encrypt-staged|$staged_luks|0||unexpected" \
    "runtime-only|$present|$runtime|0||unexpected" \
    "migration-second-lookup|$FIX/linux-encrypt-staged|$FIX/linux-encrypt-staged|1|migrate-second|unexpected" \
    "luks-failed-staged-conf|$staged_luks|$staged_luks|0|luks|unexpected" \
    "boot-fstype-failed|$present|$present|0|boot-fstype|unexpected" \
    "setup-conf-unreadable|$present|$present|0|setup-read|unexpected" \
    "setup-conf-unreadable-127|$present|$present|127|setup-read|unexpected" \
    "present-127-lookup-fails|$present|$present|127|self-lookup|unexpected" \
    "missing-127-lookup-fails|$present|$missing|127|self-lookup|unexpected" \
    "present-127-perl-fails|$present|$present|127|perl-start|unexpected" \
    "present-126-perl-fails|$present|$present|126|perl-start|unexpected"; do
    IFS='|' read -r label prior after status fault want <<EOF
$row
EOF
    got=$(a_resume_observe "$prior" "$after" "$status" "$fault")
    assert_contains "$got" "offer=0" "actions-omarchy.resume-claims: $label: classifier offers in-progress"
    assert_contains "$got" "status=$status" "actions-omarchy.resume-claims: $label: run preserves status"
    assert_contains "$got" "run=$want" "actions-omarchy.resume-claims: $label: run"
    # After a new boot no status of the run is trusted: only installed settles.
    rwant=$want
    [ "$want" != no-effect ] || rwant=unexpected
    assert_contains "$got" "reconcile=$rwant" "actions-omarchy.resume-claims: $label: new-boot reconcile reads again"
    assert_contains "$got" "later=completed" "actions-omarchy.resume-claims: $label: upstream finishes after a restart"
    if [ "$want" = unexpected ]; then
      assert_contains "$got" "resume ended" "actions-omarchy.resume-claims: $label: the command ended"
      assert_contains "$got" "not yet installed" "actions-omarchy.resume-claims: $label: no completion claim"
      assert_contains "$got" "by itself on the console after a restart" "actions-omarchy.resume-claims: $label: automatic resume"
      assert_contains "$got" "this tool's resume is held until then" "actions-omarchy.resume-claims: $label: barrier explained"
      assert_contains "$got" "sudo /usr/local/bin/omarchy-mac-setup --resume" "actions-omarchy.resume-claims: $label: upstream command"
    fi
    if [ "$label" = migration-second-lookup ]; then
      assert_contains "$got" "before-encryption=none" "actions-omarchy.resume-claims: second migration lookup failed"
      assert_contains "$got" "after-encryption=migrating" "actions-omarchy.resume-claims: recovery alone changed the classification"
    fi
  done
  # A root-only conf's unreadable content must not erase its presence. This
  # is fd481b4's finishing-boot behaviour, also used by Shared's caller.
  # shellcheck disable=SC2329 # called by the sourced functions
  got=$(
    t_load >/dev/null 2>&1
    OMB_FIXTURE=$FIX/linux-omarchy-finishing OMB_UID=501
    cat() {
      case "$*" in (*/etc/omarchy-mac-setup.conf) return 1 ;; esac
      command cat "$@"
    }
    if cat "$(sys_path "$OMS_CONF")" >/dev/null 2>&1; then printf 'readable\n'; else printf 'unreadable\n'; fi
    lx_detect
    printf '%s\n' "conf=$LX_SETUP_CONF" "finishing=$LX_SETUP_FINISHING"
    if lx_setup_complete; then printf 'complete\n'; else printf 'refused: %s\n' "$LX_INCOMPLETE_WHY"; fi
  )
  assert_contains "$got" "unreadable" "actions-omarchy.resume-claims: setup conf read fails"
  assert_contains "$got" "conf=1" "actions-omarchy.resume-claims: unreadable setup conf remains present"
  assert_contains "$got" "finishing=1" "actions-omarchy.resume-claims: unreadable setup conf still means finishing"
  assert_contains "$got" "refused: omarchy-mac-setup is finishing; one more boot" "actions-omarchy.resume-claims: lx_setup_complete refuses as at fd481b4"
  printf 'actions-omarchy.resume-claims: %d passed, %d failed\n' "$((T_PASS - p))" "$((T_FAIL - f))"
}

a_resume_claims

# a_shims DIR — the forbidden commands (t_shims), one fixed clock (values
# made from a time must agree between runs) and a sed that notes the umask
# it runs under.
a_shims() {
  local s
  s=$(t_shims "$1")
  cat >"$s/date" <<'EOF'
#!/bin/sh
if /bin/date -u -r 0 >/dev/null 2>&1; then exec /bin/date -r 1790000000 "$@"; fi
exec /bin/date -d @1790000000 "$@"
EOF
  # shellcheck disable=SC2016 # expanded by the shim
  printf '#!/bin/sh\numask >>"${A_UMASK_LOG:-/dev/null}"\nexec %s "$@"\n' "$REAL_SED" >"$s/sed"
  chmod +x "$s/date" "$s/sed"
  printf '%s' "$s"
}

# a_use DIR FIXTURE — the folder this suite's next requests keep their state,
# record and logs in, and the machine they read.
a_use() {
  A_DIR=$1 A_FIX=$2
  mkdir -p "$A_DIR/home" "$A_DIR/tmp"
  A_SHIMS=$(a_shims "$A_DIR")
  : >"$A_DIR/umask"
  touch "$A_DIR/record" "$A_DIR/shims.log"
}

# a_env — the core's sealed environment, as the frontend gives it (as
# c_run_raw builds it), with this suite's folder; A_ENV adds assignments.
a_env() {
  local v
  A_ENVS=(
    "PATH=$A_SHIMS:/usr/bin:/bin:/usr/sbin:/sbin" "HOME=$A_DIR/home" "TMPDIR=$A_DIR/tmp" "LANG=en_US.UTF-8" "TERM=dumb"
    "OMB_HOME=$A_TOOL" "OMB_SESSION_INTENT=${A_INTENT:-act}" "OMB_SESSION_SCOPES=${A_SCOPES:-$A_ALL}" "OMB_DRY_RUN=${A_DRY:-0}"
    "OMB_SESSION_DIR=$SESS" "OMB_EVENTS=$C_EV" "OMB_FIXTURE=$A_FIX" "OMB_STATE_DIR=$A_DIR/state" "OMB_FRONTEND_DEV=1"
    "OMB_TEST_RECORD=$A_DIR/record" "SHIM_LOG=$A_DIR/shims.log" "A_UMASK_LOG=$A_DIR/umask"
  )
  # shellcheck disable=SC2086 # A_ENV is a list of assignments by design
  for v in ${A_ENV:-}; do A_ENVS+=("$v"); done
}

# a_run OP RECORD... — one request, its stdin /dev/null (a managed request).
a_run() {
  local op=$1
  shift
  c_prepare "$op" "$@"
  a_env
  env -i "${A_ENVS[@]}" "$T_BASH" "$A_TOOL/omarchy-bootstrap" core "$op" 3<"$T/request-$C_N" >"$A_DIR/out" 2>"$T/stderr" </dev/null
  C_RC=$?
  C_ERR=$(cat "$T/stderr")
  C_OUT=$(cat "$C_EV")
}

# a_script OUT CMD... — CMD on a terminal of its own, its bytes kept in OUT.
a_script() {
  local out=$1
  shift
  case "$(uname -s)" in
    Darwin) script -q -F "$out" "$@" ;;
    *) script -q -f -e -c "$(printf '%q ' "$@")" "$out" ;;
  esac
}

# a_tty KEYS OP RECORD... — one request on a terminal (a handoff): KEYS
# typed into it (after A_WAIT shows, when set), then held open until the core
# ends; one still waiting after 60 s is ended as the process it recorded.
# A_TTY: what the terminal showed.
a_tty() {
  local keys=$1 op=$2 d i=0 v pid
  shift 2
  c_prepare "$op" "$@"
  a_env
  d=$T/pty-$C_N
  mkdir -p "$d"
  {
    printf 'stty rows 40 cols 120 2>/dev/null\n'
    # shellcheck disable=SC2016 # expanded by the inner shell
    printf "/bin/sh -c 'echo \$\$ >\"\$0/pid\"; exec \"\$@\"' %q env -i" "$d"
    for v in "${A_ENVS[@]}"; do printf ' %q' "$v"; done
    printf ' %q %q core %q 3<%q 2>%q\n' "$T_BASH" "$A_TOOL/omarchy-bootstrap" "$op" "$T/request-$C_N" "$T/stderr"
    printf 'echo $? >%q\n' "$d/rc"
  } >"$d/inner"
  : >"$d/out"
  {
    if [ -n "${A_WAIT:-}" ]; then
      until tr -d '\r' <"$d/out" | grep -qF -- "$A_WAIT" || [ "$i" -ge 300 ]; do
        sleep 0.1
        i=$((i + 1))
      done
      sleep 0.5
    fi
    printf '%b' "$keys"
    i=0
    until [ -e "$d/rc" ] || [ "$i" -ge 600 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    if [ ! -e "$d/rc" ]; then
      echo stuck >"$d/stuck"
      pid=$(cat "$d/pid" 2>/dev/null)
      t_signal KILL "$pid" "$(t_started "$pid")"
    fi
  } | a_script "$d/out" "$T_BASH" "$d/inner" >/dev/null 2>&1
  C_RC=$(cat "$d/rc" 2>/dev/null)
  C_ERR=$(cat "$T/stderr" 2>/dev/null)
  C_OUT=$(cat "$C_EV")
  A_TTY=$(tr -d '\r' <"$d/out")
  [ ! -e "$d/stuck" ] && ok || fail "a terminal run asked for more than its keys ($*)"
}

# a_basis ACTION — A_B: the basis the journey snapshot shows for ACTION
# (empty when it does not list it).
a_basis() {
  a_run snapshot "scope	name=journey"
  A_B=$(printf '%s\n' "$C_OUT" | awk -F'\t' -v a="id=$1" '$1 == "action" && $2 == a { for (i = 2; i <= NF; i++) if ($i ~ /^basis=/) { sub(/^basis=/, "", $i); print $i } }')
}

# a_review ACTION RECORD... — A_B: the basis validate's review gives.
a_review() {
  local a=$1
  shift
  a_run validate "select	action=$a" "$@"
  A_B=$(printf '%s\n' "$C_OUT" | awk -F'\t' '$1 == "review" { sub(/^basis=/, "", $3); print $3 }')
}

# a_exec ACTION WORD [RECORD...] — execute, managed, with the basis shown.
a_exec() {
  local a=$1 w=$2
  shift 2
  if [ $# -gt 0 ]; then a_review "$a" "$@"; else a_basis "$a"; fi
  a_run execute "exec	action=$a	basis=${A_B:-$ZERO}	confirm=$w" "$@"
}

# a_exec_tty KEYS ACTION WORD [RECORD...] — execute on a terminal.
a_exec_tty() {
  local keys=$1 a=$2 w=$3
  shift 3
  if [ $# -gt 0 ]; then a_review "$a" "$@"; else a_basis "$a"; fi
  a_tty "$keys" execute "exec	action=$a	basis=${A_B:-$ZERO}	confirm=$w" "$@"
}

a_enc() { (. "$REPO/lib/records.sh" && rec_enc "$1"); }
a_arg() { printf 'arg\tname=%s\tvalue=%s' "$1" "$(a_enc "$2")"; }
a_actions() { printf '%s\n' "$C_OUT" | awk -F'\t' '$1 == "action" { sub(/^id=/, "", $2); printf "%s ", $2 }'; }
a_state() { cat "$A_DIR/state/state.env" 2>/dev/null; }
a_ops() { find "$A_DIR/state/ops" -mindepth 1 -maxdepth 1 2>/dev/null | sed 's#.*/##' | tr '\n' ' '; }
a_text() { printf '%s\n' "$C_OUT" | awk -F'\t' '$1 == "result" { sub(/^text=/, "", $4); print $4 }'; }

# a_umask LABEL — the step ran under umask 022: the text flow's own.
a_umask() {
  grep -qx 0022 "$A_DIR/umask" && ok || fail "$1: the step runs under umask 022 ($(sort -u "$A_DIR/umask" | tr '\n' ' '))"
}

# a_boot — this fixture's boot session, as the core reads it.
a_boot() {
  if [ -f "$A_FIX/cmd/bootsession" ]; then cat "$A_FIX/cmd/bootsession"; else cat "$A_FIX/root/proc/sys/kernel/random/boot_id"; fi
}

# a_plant SCOPE ACTION STATE [PID START BOOT] — an operation record, sealed as
# the core writes one; "garbage" plants one that cannot be read.
a_plant() {
  local rec=$A_DIR/state/ops/$1.omb boot=${6:-}
  mkdir -p "$A_DIR/state/ops"
  chmod 700 "$A_DIR/state" "$A_DIR/state/ops"
  [ -n "$boot" ] || boot=$(a_boot)
  if [ "$3" = garbage ]; then
    printf 'omb-op 1\nop\taction=%s\n' "$2" >"$rec"
  else
    a_rec "$rec" "$1" "$2" "$3" "${4:-1}" "${5:-Mon Jan  1 00:00:00 2001}" "$boot"
  fi
  chmod 600 "$rec"
}

# a_rec FILE SCOPE ACTION STATE PID START BOOT — one sealed operation record.
# Everything comes in as arguments: t_load's own loop variable is f.
a_rec() {
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    {
      printf 'omb-op 1\n'
      rec_line op action "$3" scope "$2" basis "$ZERO" session "$SESS" state "$4" finding "" \
        pid "$5" start "$6" boot "$7" at 2026-09-26T00:00:00Z
    } >"$1"
    rec_seal_write "$1"
    omb_cleanup
  )
}

# a_barriers ACTION SCOPE WORD [RECORD...] — each record that bars a scope
# refuses ACTION before anything is read: busy (its core alive), an
# unsupervised, a failed and an unreadable record; each is left in place.
a_barriers() {
  local a=$1 scope=$2 w=$3 live
  shift 3
  live=$(t_started $$)
  for kind in busy unsupervised failed unreadable; do
    case "$kind" in
      busy) a_plant "$scope" "$a" running $$ "$live" ;;
      unsupervised) a_plant "$scope" "$a" unsupervised ;;
      failed) a_plant "$scope" "$a" failed ;;
      unreadable) a_plant "$scope" "$a" garbage ;;
    esac
    cp "$A_DIR/state/ops/$scope.omb" "$T/planted"
    : >"$A_DIR/record"
    a_run execute "exec	action=$a	basis=$ZERO	confirm=$w" "$@"
    case "$kind" in
      busy) want="refused busy" ;;
      failed) want="refused unresolved" ;;
      *) want="refused unsupervised" ;;
    esac
    assert_eq "$(c_result)" "$want" "actions-$a-$kind: a $kind record in scope $scope refuses it"
    cmp -s "$A_DIR/state/ops/$scope.omb" "$T/planted" && ok || fail "actions-$a-$kind: the record is left as it was"
    assert_empty_file "$A_DIR/record" "actions-$a-$kind: nothing ran"
    rm -f "$A_DIR/state/ops/$scope.omb"
  done
}

# a_req ACTION RECORD... — one execute request as the row takes it: managed
# rows with stdin /dev/null, handoffs on a terminal given nothing to type.
a_req() {
  case "$1" in
    plan.save | shared.code)
      shift
      a_run execute "$@"
      ;;
    *)
      shift
      a_tty '\004\004\004' execute "$@"
      ;;
  esac
}

# a_common ACTION WORD [RECORD...] — the refusals every row shares, on the
# fixture in use (ACTION available there): the word, a basis that is not
# the one shown, a session without the scope or above its ceiling, and a
# handoff without a terminal; none leaves a record or runs anything.
a_common() {
  local a=$1 w=$2 bad=nope
  shift 2
  : >"$A_DIR/record"
  if [ $# -gt 0 ]; then a_review "$a" "$@"; else a_basis "$a"; fi
  [ -n "$A_B" ] && ok || fail "actions-$a: the fixture offers it ($(c_result))"
  a_req "$a" "exec	action=$a	basis=$A_B	confirm=$bad" "$@"
  assert_eq "$(c_result)" "refused word" "actions-$a-word: any other word is refused"
  if [ -n "$w" ]; then
    a_req "$a" "exec	action=$a	basis=$A_B	confirm=" "$@"
    assert_eq "$(c_result)" "refused word" "actions-$a-word: no word is refused"
  fi
  a_req "$a" "exec	action=$a	basis=$ZERO	confirm=$w" "$@"
  assert_eq "$(c_result)" "refused changed" "actions-$a-changed: a basis other than the one shown is refused"
  A_SCOPES=journey a_run execute "exec	action=$a	basis=$A_B	confirm=$w" "$@"
  assert_eq "$(c_result)" "refused scope" "actions-$a: a session without its scope refuses it"
  A_INTENT='read' a_run execute "exec	action=$a	basis=$A_B	confirm=$w" "$@"
  assert_eq "$(c_result)" "refused ceiling" "actions-$a: a read session refuses it"
  case "$a" in
    plan.save | shared.code) ;;
    *)
      a_run execute "exec	action=$a	basis=$A_B	confirm=$w" "$@"
      assert_eq "$(c_result)" "refused unavailable" "actions-$a: a handoff without a terminal is refused"
      ;;
  esac
  assert_eq "$(a_ops)" "" "actions-$a: no refusal leaves an operation record"
  assert_empty_file "$A_DIR/record" "actions-$a: no refusal runs anything"
}

# a_unavailable ACTION WORD FIXTURE [RECORD...] — on FIXTURE the text flow
# would not offer ACTION: the snapshot does not list it, and execute
# refuses it as unavailable, leaving no record.
a_unavailable() {
  local a=$1 w=$2 fx=$3 why
  shift 3
  a_use "$T/un-$a-$(basename "$fx")" "$fx"
  a_run snapshot "scope	name=journey"
  why=$(c_result)
  case " $(a_actions)" in *" $a "*) fail "actions-$a-unavailable: $(basename "$fx") lists it" ;; *) ok ;; esac
  a_run execute "exec	action=$a	basis=$ZERO	confirm=$w" "$@"
  assert_eq "$(c_result) $(a_ops)" "refused unavailable " "actions-$a-unavailable: $(basename "$fx") refuses it ($why)"
  assert_empty_file "$A_DIR/record" "actions-$a-unavailable: nothing ran"
}

# a_plan_state DIR FIXTURE LINUX_GB SHARED_GB — a plan saved in DIR by
# plan.save itself, the other inputs at their defaults.
a_plan_state() {
  local s=0
  [ "$4" = 0 ] || s="${4}GB"
  a_use "$1" "$2"
  a_exec plan.save "" "$(a_arg linux_size "${3}GB")" "$(a_arg shared_size "$s")"
  assert_eq "$(c_result)" "done ok" "actions-plan.save: the plan for $(basename "$1") is saved ($(a_text))"
}

# ---------------------------------------------------------------------------
# macOS rows (their fixtures are read through plutil)
# ---------------------------------------------------------------------------
if t_plutil "the macOS rows"; then
  R=$FIX/mac-m1pro-1tb-roomy

  # --- plan.save ------------------------------------------------------------------
  a_use "$T/plan" "$R"
  a_run snapshot "scope	name=journey"
  assert_eq "$(c_result) $(c_admits snapshot)" "done ok ok" "actions-plan.save: the journey snapshot admits"
  case " $(a_actions)" in *" plan.save "*) ok ;; *) fail "actions-plan.save: a plannable Mac offers it" ;; esac
  assert_eq "$(grep -c '^param	action=plan.save	' "$C_EV")" 11 "actions-plan.save: it takes the eleven inputs"
  assert_contains "$C_OUT" "action	id=plan.save	scope=plan	label=Save%20the%20plan	intent=plan	gate=	terminal=managed	cancel=0	basis=	" \
    "actions-plan.save: scope plan, intent plan, managed, no word, its basis from validate"
  a_exec plan.save "" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)" "$(a_arg user alex)" "$(a_arg gh octocat)"
  assert_eq "$(c_result) $(c_admits execute)" "done ok ok" "actions-plan.save-success: saved ($(a_text))"
  assert_eq "$C_ERR" "" "actions-plan.save-success: clean stderr"
  st=$(a_state)
  for kv in cfg_enc=1 cfg_user=alex cfg_host=omarchy cfg_kmap=us cfg_tz=America/New_York cfg_loc=en_US.UTF-8 cfg_ssh=0 cfg_gh=octocat cfg_linux=250 cfg_shared=0 cfg_dev=1; do
    assert_contains "$st" "$kv" "actions-plan.save-readback: $kv"
  done
  assert_contains "$st" "planned_at=" "actions-plan.save-readback: planned_at"
  assert_not_contains "$st" "cfg_plan=" "actions-plan.save-readback: no Shared, no plan digest"
  [ ! -e "$A_DIR/state/shared-intent.env" ] && ok || fail "actions-plan.save-readback: no Shared, no plan record"
  assert_eq "$(a_ops)" "" "actions-plan.save-success: its operation record is removed"
  assert_empty_file "$A_DIR/record" "actions-plan.save-success: nothing runs"
  a_umask actions-plan.save-umask
  # Its records for the storage screen, in the journey snapshot: the disk as
  # it is, every region.
  a_run snapshot "scope	name=journey"
  assert_eq "$(c_result) $(c_admits snapshot)" "done ok ok" "actions-plan.save-records: the snapshot admits"
  assert_eq "$(printf '%s\n' "$C_OUT" | sed -n 's/^region	start=[0-9]*	size=[0-9]*	role=\([a-z]*\)	.*/\1/p' | tr '\n' ' ')" "apple macos apple " \
    "actions-plan.save-records: iBoot, macOS and Recovery, in disk order"
  assert_contains "$C_OUT" "role=macos	label=disk0s2" "actions-plan.save-records: each named by its partition"
  # Validation's defaults are the text flow's, the saved choices first.
  a_review plan.save "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  assert_contains "$C_OUT" "normal	name=gh	value=octocat" "actions-plan.save: an omitted choice takes the saved one"
  # A rerun of the same inputs changes nothing (one fixed clock).
  before=$(t_snapshot "$A_DIR/state" | grep -v '/logs')
  a_exec plan.save "" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)" "$(a_arg user alex)" "$(a_arg gh octocat)"
  assert_eq "$(c_result)" "done ok" "actions-plan.save-rerun: done"
  assert_eq "$(t_snapshot "$A_DIR/state" | grep -v '/logs')" "$before" "actions-plan.save-rerun: a rerun changes nothing"
  # With Shared: the plan record, its digest in the choices.
  a_exec plan.save "" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 150GB)"
  assert_eq "$(c_result)" "done ok" "actions-plan.save-shared: saved with 150 GB of Shared"
  digest=$(sed -n 's/^digest=//p' "$A_DIR/state/shared-intent.env" | cut -c1-8)
  assert_contains "$(a_state)" "cfg_plan=$digest" "actions-plan.save-shared: the plan record's digest is in the choices"
  assert_contains "$(a_state)" "cfg_shared=150" "actions-plan.save-shared: 150 GB"
  # A dry run: the same steps, nothing written, no record, no lock.
  before=$(t_snapshot "$A_DIR/state")
  A_DRY=1 a_exec plan.save "" "$(a_arg linux_size 300GB)" "$(a_arg shared_size 0)"
  assert_eq "$(c_result)" "done dry-run" "actions-plan.save-dry-run: a dry run saves nothing"
  assert_eq "$(t_snapshot "$A_DIR/state")" "$before" "actions-plan.save-dry-run: the state folder is as it was"
  # Back to none: the record is removed, and so is the digest.
  a_exec plan.save "" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  assert_eq "$(c_result)" "done ok" "actions-plan.save-shared: saved again without Shared"
  [ ! -e "$A_DIR/state/shared-intent.env" ] && ok || fail "actions-plan.save-shared: no Shared, the plan record is removed"
  assert_not_contains "$(a_state)" "cfg_plan=" "actions-plan.save-shared: and the digest with it"
  a_common plan.save "" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  # Inputs that no longer hold on the machine: unavailable.
  a_review plan.save "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  a_run execute "exec	action=plan.save	basis=$A_B	confirm=" "$(a_arg linux_size 251GB)" "$(a_arg shared_size 0)"
  assert_eq "$(c_result)" "refused changed" "actions-plan.save-changed: other inputs than the review's"
  a_run execute "exec	action=plan.save	basis=$A_B	confirm=" "$(a_arg linux_size 700GB)" "$(a_arg shared_size 0)"
  assert_eq "$(c_result)" "refused unavailable" "actions-plan.save-unavailable: an input past this Mac's maximum now"
  a_run execute "exec	action=plan.save	basis=$A_B	confirm=" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)" "$(a_arg size 1)"
  assert_eq "$(c_result)" "refused invalid" "actions-plan.save: a parameter it does not take"
  # Free space is not in the basis: it moves, and the review still holds.
  V=$(t_variant mac-m1pro-1tb-roomy)
  a_use "$T/plan-drift" "$V"
  a_review plan.save "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  b0=$A_B
  sed -i.bak 's#<key>APFSContainerFree</key><integer>700000000000</integer>#<key>APFSContainerFree</key><integer>690000000000</integer>#' "$V/cmd/diskutil_info_root" && rm -f "$V/cmd/diskutil_info_root.bak"
  assert_eq "$(grep -c '<integer>690000000000</integer>' "$V/cmd/diskutil_info_root")" 1 "the copied fixture holds 10 GB less APFS free space"
  a_run execute "exec	action=plan.save	basis=$b0	confirm=" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  assert_eq "$(c_result)" "done ok" "actions-plan.save-drift: free space moved, the shown basis still saves"
  a_barriers plan.save plan "" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  for fx in mac-m1pro-1tb-tight mac-asahi-installed; do
    a_unavailable plan.save "" "$FIX/$fx" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  done
  # The stop at the first failed write: nothing after it is written, and the
  # read-back finds the plan incomplete.
  a_use "$T/plan-fail" "$R"
  A_ENV="OMB_TEST_FAIL_AT=cfg_host" a_exec plan.save "" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  assert_eq "$(c_result)" "failed postcondition" "actions-plan.save-fail: a write that fails: failed ($(a_text))"
  st=$(a_state)
  assert_contains "$st" "cfg_user=" "actions-plan.save-fail: what came before it is written"
  for k in cfg_host cfg_kmap cfg_tz cfg_loc cfg_linux planned_at; do
    assert_not_contains "$st" "$k=" "actions-plan.save-fail: nothing after the failed write ($k)"
  done
  assert_contains "$(cat "$A_DIR/state/ops/plan.omb" 2>/dev/null)" "	state=failed	finding=unexpected	" "actions-plan.save-fail: its record stays, failed"
  a_exec plan.save "" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  assert_eq "$(c_result)" "refused unresolved" "actions-plan.save-fail: the plan scope is barred until a new boot"
  # A stop at a save boundary: the core ends there, its record running.
  a_use "$T/plan-stop" "$R"
  A_ENV="OMB_TEST_STOP_AT=cfg_host" a_exec plan.save "" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  assert_eq "$(c_result)" "" "actions-plan.save-stop: the core ended at the boundary, without a result"
  st=$(a_state)
  assert_contains "$st" "cfg_host=omarchy" "actions-plan.save-stop: the boundary's own write is there"
  assert_not_contains "$st" "cfg_kmap=" "actions-plan.save-stop: nothing after it"
  assert_contains "$(cat "$A_DIR/state/ops/plan.omb" 2>/dev/null)" "	state=running	" "actions-plan.save-stop: its record stays, running"
  # The stopped core never reached its exit: its identity is left, as a
  # killed core leaves it.
  [ -f "$SESS/req-$C_N.core" ] && ok || fail "actions-plan.save-stop: the stopped core left its identity"
  rm -f "$SESS/req-$C_N.core"
  a_exec plan.save "" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  assert_eq "$(c_result)" "refused unsupervised" "actions-plan.save-stop: the next save is refused as unsupervised"
  # After a new boot, the stopped save is judged on the machine: the saved
  # choices are not the inputs it was given, so the scope stays barred.
  Vb=$(t_variant mac-m1pro-1tb-roomy)
  printf '5E1D0B00-7A3C-4F21-9D6E-00000000A001\n' >"$Vb/cmd/bootsession"
  A_FIX=$Vb a_run execute "exec	action=plan.save	basis=$ZERO	confirm=" "$(a_arg linux_size 250GB)" "$(a_arg shared_size 0)"
  assert_eq "$(c_result)" "refused unsupervised" "actions-plan.save-reconcile: an incomplete save is unexpected after a new boot"
  assert_contains "$C_OUT" "It%20needs%20you" "actions-plan.save-reconcile: and needs the person"

  # --- asahi.launch ----------------------------------------------------------------
  a_unavailable asahi.launch yes "$R"
  a_plan_state "$T/asahi" "$R" 250 0
  a_run snapshot "scope	name=journey"
  assert_contains "$C_OUT" "fact	scope=asahi	key=gate.asahi.launch.macos	label=macOS	value=its%20container%20%28disk0s2%29%20shrinks%20to" \
    "actions-asahi.launch: its gate facts name the resize"
  assert_contains "$C_OUT" "action	id=asahi.launch	scope=asahi	label=Run%20the%20Asahi%20Alarm%20installer	intent=act	gate=yes	terminal=handoff	cancel=0	basis=" \
    "actions-asahi.launch: scope asahi, a handoff, word yes"
  # Its records: the installer's answers as the card computes them, and the
  # boot steps after it.
  assert_eq "$(c_admits snapshot)" ok "actions-asahi.launch-records: the snapshot with its answers and guide admits"
  assert_contains "$C_OUT" "value=710114MiB	bytes=$((710114 * MIB))" "actions-asahi.launch-records: the resize answer with its exact bytes"
  assert_contains "$C_OUT" "prompt=New%20OS%20size%20%20%28Linux%20gets%29	value=max	bytes=" "actions-asahi.launch-records: then max for Linux"
  assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^answer	')" 8 "actions-asahi.launch-records: the card's eight answers"
  assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^guide	id=boot	')" 8 "actions-asahi.launch-records: the eight boot steps, as guide id=boot"
  a_common asahi.launch yes
  a_barriers asahi.launch asahi yes
  # The word answers the backup gate only: launch is typed on the terminal.
  a_exec_tty '\nyes\nn\n\004\004\004' asahi.launch yes
  assert_eq "$(c_result)" "failed no-effect" "actions-asahi.launch-word: declined at launch, the disk is as it was"
  assert_eq "$(printf '%s\n' "$A_TTY" | grep -c 'Typed in the interface: yes')" 1 "actions-asahi.launch-word: the word answered one prompt"
  assert_contains "$A_TTY" 'only the exact word "launch" continues' "actions-asahi.launch-word: launch was asked on the terminal"
  assert_not_contains "$(cat "$A_DIR/record")" "sh " "actions-asahi.launch-word: the installer did not run"
  assert_eq "$(a_ops)" "" "actions-asahi.launch-word: a proven no-effect leaves no record"
  # Launched: the recorded installer "runs", and the disk afterwards shows its
  # first stage done.
  : >"$A_DIR/record"
  A_ENV="OMB_TEST_AFTER=$FIX/mac-asahi-pending" a_exec_tty '\nlaunch\n\004\004\004' asahi.launch yes
  assert_eq "$(c_result)" "done ok" "actions-asahi.launch-success: the installer's partitions are in place ($(a_text))"
  assert_eq "$C_ERR" "" "actions-asahi.launch-success: clean stderr"
  rec=$(cat "$A_DIR/record")
  assert_contains "$rec" "pbcopy <<< 710114MiB" "actions-asahi.launch-success: the first answer is on the clipboard"
  assert_contains "$rec" "sh $A_DIR/state/downloads/asahi-alarm-bootstrap.sh-" "actions-asahi.launch-success: the downloaded installer runs"
  assert_contains "$(a_state)" "asahi_prelaunch_macos_size=" "actions-asahi.launch-success: the layout before is recorded first"
  assert_eq "$(a_ops)" "" "actions-asahi.launch-success: its record is removed"
  a_umask actions-asahi.launch-umask
  # A dry run on the terminal: every step shown, nothing run or written.
  : >"$A_DIR/record"
  before=$(t_snapshot "$A_DIR/state")
  A_DRY=1 a_exec_tty '\nlaunch\n\004\004\004' asahi.launch yes
  assert_eq "$(c_result)" "done dry-run" "actions-asahi.launch-dry-run: done as a dry run"
  assert_contains "$A_TTY" "would run" "actions-asahi.launch-dry-run: the launch is shown, not run"
  assert_empty_file "$A_DIR/record" "actions-asahi.launch-dry-run: nothing ran"
  assert_eq "$(t_snapshot "$A_DIR/state")" "$before" "actions-asahi.launch-dry-run: nothing written"
  # The installer quits at its first question: no change, proven.
  a_plan_state "$T/asahi-quit" "$R" 250 0
  a_exec_tty '\nlaunch\n\004\004\004' asahi.launch yes
  assert_eq "$(c_result)" "failed no-effect" "actions-asahi.launch-noeffect: the disk exactly as before is no effect"
  assert_eq "$(a_ops)" "" "actions-asahi.launch-noeffect: and leaves no record"
  # Something the installer does not leave: failed, a barrier.
  a_plan_state "$T/asahi-odd" "$R" 250 0
  A_ENV="OMB_TEST_AFTER=$FIX/mac-asahi-stub-only" a_exec_tty '\nlaunch\n\004\004\004' asahi.launch yes
  assert_eq "$(c_result)" "failed postcondition" "actions-asahi.launch-unexpected: a first stage cut short is failed"
  assert_contains "$(cat "$A_DIR/state/ops/asahi.omb" 2>/dev/null)" "	state=failed	finding=unexpected	" "actions-asahi.launch-unexpected: its record stays"
  # The installer resized macOS and was quit before installing: a state the
  # text flow continues from, so completed, and the next launch installs
  # into the freed space.
  a_plan_state "$T/asahi-resized" "$R" 250 0
  A_ENV="OMB_TEST_AFTER=$FIX/mac-asahi-resized-only" a_exec_tty '\nlaunch\n\004\004\004' asahi.launch yes
  assert_eq "$(c_result)" "done ok" "actions-asahi.launch-resized: resized, then quit, is completed"
  assert_contains "$(a_text)" "resized%20macOS%20and%20stopped%20before%20installing" "actions-asahi.launch-resized: and says so"
  assert_contains "$(a_text)" "The%20next%20launch%20continues%20from%20there" "actions-asahi.launch-resized: and what comes next"
  assert_eq "$(a_ops)" "" "actions-asahi.launch-resized: no record bars the asahi scope"
  A_FIX=$FIX/mac-asahi-resized-only a_run snapshot "scope	name=journey"
  case " $(a_actions)" in *" asahi.launch "*) ok ;; *) fail "actions-asahi.launch-resized: the next launch is offered" ;; esac
  assert_contains "$C_OUT" "value=not%20resized:%20Linux%20goes%20into%20the%20free%20space" "actions-asahi.launch-resized: into the freed space, no second resize"
  # After a new boot, the classifier judges the record on the machine.
  a_use "$T/asahi-boot" "$FIX/mac-asahi-pending"
  a_plant asahi asahi.launch running 1 x "5E1D0B00-7A3C-4F21-9D6E-0000000000AA"
  a_run execute "exec	action=asahi.launch	basis=$ZERO	confirm=yes"
  assert_contains "$C_OUT" "reconciled:%20completed" "actions-asahi.launch-reconcile: the first stage done is completed"
  assert_eq "$(c_result) $(a_ops)" "refused unavailable " "actions-asahi.launch-reconcile: the record goes; no second install is offered"
  # actions-asahi.launch-reconcile-layout: "nothing changed" after a new boot
  # is the whole layout recorded before the launch, every partition's GUID,
  # offset and size; macOS's size alone proves nothing.
  a_plan_state "$T/asahi-boot2" "$R" 250 0
  a_exec_tty '\nn\n\004\004\004' asahi.launch yes
  assert_eq "$(c_result)" "failed no-effect" "actions-asahi.launch-reconcile-layout: declined at launch, nothing changed"
  assert_contains "$(a_state)" "asahi_prelaunch_layout=" "actions-asahi.launch-reconcile-layout: the layout is recorded before the launch"
  cp -p "$A_DIR/state/state.env" "$T/asahi-layout.env"
  a_plant asahi asahi.launch running 1 x "5E1D0B00-7A3C-4F21-9D6E-0000000000AA"
  a_run execute "exec	action=asahi.launch	basis=$ZERO	confirm=yes"
  assert_contains "$C_OUT" "reconciled:%20no-effect" "actions-asahi.launch-reconcile-layout: the same layout is no effect"
  # Recovery replaced while macOS kept its size: not the layout recorded.
  VL=$(t_variant mac-m1pro-1tb-roomy)
  sed -i.bak 's/4A7B1C2D-0003-4E5F-8A9B-000000000003/4A7B1C2D-0009-4E5F-8A9B-000000000009/' "$VL/cmd/diskutil_list_disk0" "$VL/cmd/diskutil_info_disk0s3" &&
    rm -f "$VL/cmd/diskutil_list_disk0.bak" "$VL/cmd/diskutil_info_disk0s3.bak"
  assert_eq "$(grep -c '4A7B1C2D-0009' "$VL/cmd/diskutil_list_disk0")" 1 "actions-asahi.launch-reconcile-layout: the variant replaces Recovery's partition"
  a_use "$T/asahi-boot-layout" "$VL"
  mkdir -p "$A_DIR/state" && chmod 700 "$A_DIR/state" && cp -p "$T/asahi-layout.env" "$A_DIR/state/state.env"
  a_plant asahi asahi.launch running 1 x "5E1D0B00-7A3C-4F21-9D6E-0000000000AA"
  a_run execute "exec	action=asahi.launch	basis=$ZERO	confirm=yes"
  assert_eq "$(c_result)" "refused unsupervised" "actions-asahi.launch-reconcile-layout: another partition changed while macOS kept its size: unexpected"
  [ -e "$A_DIR/state/ops/asahi.omb" ] && ok || fail "actions-asahi.launch-reconcile-layout: its record stays"
  # actions-asahi.launch-reconcile-type: Recovery's type changed, its GUID
  # and extent kept: not the layout recorded either.
  VY=$(t_variant mac-m1pro-1tb-roomy)
  sed -i.bak 's/Apple_APFS_Recovery/Microsoft Basic Data/' "$VY/cmd/diskutil_list_disk0" "$VY/cmd/diskutil_info_disk0s3" &&
    rm -f "$VY/cmd/diskutil_list_disk0.bak" "$VY/cmd/diskutil_info_disk0s3.bak"
  assert_eq "$(grep -c 'Microsoft Basic Data' "$VY/cmd/diskutil_list_disk0") $(grep -c 'Apple_APFS_Recovery' "$VY/cmd/diskutil_info_disk0s3")" "1 0" \
    "actions-asahi.launch-reconcile-type: the variant changes Recovery's type alone"
  a_use "$T/asahi-boot-type" "$VY"
  mkdir -p "$A_DIR/state" && chmod 700 "$A_DIR/state" && cp -p "$T/asahi-layout.env" "$A_DIR/state/state.env"
  a_plant asahi asahi.launch running 1 x "5E1D0B00-7A3C-4F21-9D6E-0000000000AA"
  a_run execute "exec	action=asahi.launch	basis=$ZERO	confirm=yes"
  assert_eq "$(c_result)" "refused unsupervised" "actions-asahi.launch-reconcile-type: a partition whose type changed is unexpected"
  [ -e "$A_DIR/state/ops/asahi.omb" ] && ok || fail "actions-asahi.launch-reconcile-type: its record stays"
  # Resized after a new boot: completed only with the layout recorded before
  # the launch (the resized launch's own state, above) showing every other
  # partition as it was.
  a_use "$T/asahi-boot-resized" "$FIX/mac-asahi-resized-only"
  mkdir -p "$A_DIR/state" && chmod 700 "$A_DIR/state" && cp -p "$T/asahi-resized/state/state.env" "$A_DIR/state/state.env"
  assert_contains "$(a_state)" "asahi_prelaunch_resized=" "actions-asahi.launch-reconcile: the resized launch recorded the layout a resize keeps"
  a_plant asahi asahi.launch running 1 x "5E1D0B00-7A3C-4F21-9D6E-0000000000AA"
  a_run execute "exec	action=asahi.launch	basis=$ZERO	confirm=yes"
  assert_contains "$C_OUT" "reconciled:%20completed" "actions-asahi.launch-reconcile: resized and nothing installed is completed after a new boot"
  assert_eq "$(a_ops)" "" "actions-asahi.launch-reconcile: and the record goes"
  # actions-asahi.launch-reconcile-resized: macOS resized and Recovery gone
  # is not a resize; and without a recorded layout a resize cannot be told.
  VG=$(t_variant mac-asahi-resized-only)
  sed -i.bak 's#<dict><key>Content</key><string>Apple_APFS_Recovery</string><key>DeviceIdentifier</key><string>disk0s3</string><key>DiskUUID</key><string>4A7B1C2D-0003-4E5F-8A9B-000000000003</string><key>Size</key><integer>5368664064</integer></dict>##' "$VG/cmd/diskutil_list_disk0" &&
    rm -f "$VG/cmd/diskutil_list_disk0.bak" "$VG/cmd/diskutil_info_disk0s3"
  assert_eq "$(grep -c 'disk0s3' "$VG/cmd/diskutil_list_disk0")" 0 "actions-asahi.launch-reconcile-resized: the variant removes Recovery"
  for case in "gone|$VG|$T/asahi-resized/state/state.env" "unrecorded|$FIX/mac-asahi-resized-only|"; do
    a_use "$T/asahi-boot-resized-${case%%|*}" "$(printf '%s' "$case" | cut -d'|' -f2)"
    mkdir -p "$A_DIR/state" && chmod 700 "$A_DIR/state"
    if [ "${case%%|*}" = gone ]; then
      cp -p "${case##*|}" "$A_DIR/state/state.env"
    else
      printf 'asahi_prelaunch_macos_size=994610155520\n' >"$A_DIR/state/state.env" && chmod 600 "$A_DIR/state/state.env"
    fi
    a_plant asahi asahi.launch running 1 x "5E1D0B00-7A3C-4F21-9D6E-0000000000AA"
    a_run execute "exec	action=asahi.launch	basis=$ZERO	confirm=yes"
    assert_eq "$(c_result)" "refused unsupervised" "actions-asahi.launch-reconcile-resized: ${case%%|*} is not completed"
    [ -e "$A_DIR/state/ops/asahi.omb" ] && ok || fail "actions-asahi.launch-reconcile-resized: ${case%%|*}: its record stays"
  done
  a_use "$T/asahi-boot3" "$FIX/mac-asahi-stub-only"
  a_plant asahi asahi.launch running 1 x "5E1D0B00-7A3C-4F21-9D6E-0000000000AA"
  a_run execute "exec	action=asahi.launch	basis=$ZERO	confirm=yes"
  assert_eq "$(c_result)" "refused unsupervised" "actions-asahi.launch-reconcile: a cut-short stage needs the person"
  [ -e "$A_DIR/state/ops/asahi.omb" ] && ok || fail "actions-asahi.launch-reconcile: its record stays"
  # On an experimental Mac its first typed word is experimental; yes follows
  # on the terminal.
  a_plan_state "$T/asahi-m3" "$FIX/mac-m3pro-experimental" 120 0
  a_run snapshot "scope	name=journey"
  assert_contains "$C_OUT" "action	id=asahi.launch	scope=asahi	label=Run%20the%20Asahi%20Alarm%20installer	intent=act	gate=experimental	" \
    "actions-asahi.launch-experimental: the gate is experimental"
  a_basis asahi.launch
  a_req asahi.launch "exec	action=asahi.launch	basis=$A_B	confirm=yes"
  assert_eq "$(c_result)" "refused word" "actions-asahi.launch-experimental: yes is not its word"
  a_exec_tty 'n\n\004\004\004' asahi.launch experimental
  assert_contains "$A_TTY" "Typed in the interface: experimental" "actions-asahi.launch-experimental: the word answered the experimental gate"
  assert_contains "$A_TTY" 'A recent backup of this Mac exists.  Type yes to continue' "actions-asahi.launch-experimental: the backup gate was asked on the terminal"
  assert_eq "$(c_result)" "failed no-effect" "actions-asahi.launch-experimental: stopped at the backup gate, nothing changed"

  # --- shared.code (macOS) and shared.create -------------------------------------------
  a_plan_state "$T/plan150" "$R" 250 150
  digest=$(sed -n 's/^digest=//p' "$T/plan150/state/shared-intent.env" | cut -c1-8)
  CODE=$( (t_load >/dev/null 2>&1 && code_make ombdone "$digest" 4A7B1C2D-0006-4E5F-8A9B-000000000006))
  OTHER_PLAN=$( (t_load >/dev/null 2>&1 && code_make ombdone 0badc0de 4A7B1C2D-0006-4E5F-8A9B-000000000006))
  OTHER_ROOT=$( (t_load >/dev/null 2>&1 && code_make ombdone "$digest" 4A7B1C2D-0009-4E5F-8A9B-000000000009))
  # a_shared_state DIR — the Shared plan's state in DIR, on the Mac after Asahi.
  a_shared_state() {
    mkdir -p "$1/state"
    chmod 700 "$1/state"
    cp -p "$T/plan150/state/state.env" "$T/plan150/state/shared-intent.env" "$1/state/"
    a_use "$1" "$FIX/mac-shared-reserved"
  }
  a_shared_state "$T/code"
  a_run snapshot "scope	name=journey"
  assert_contains "$C_OUT" "param	action=shared.code	name=code	type=code	kind=ombdone	required=1" "actions-shared.code: it takes Linux's code"
  case " $(a_actions)" in *" shared.code "*) ok ;; *) fail "actions-shared.code: awaiting Linux, the snapshot offers it" ;; esac
  case " $(a_actions)" in *" shared.create "*) fail "actions-shared.create: not before Linux's code" ;; *) ok ;; esac
  # Validation judges the code as the text flow does.
  case "$CODE" in *0) MISTYPED=${CODE%?}1 ;; *) MISTYPED=${CODE%?}0 ;; esac
  for pair in "mistyped|$MISTYPED" "mistyped|ombdone-12" "other-plan|$OTHER_PLAN" "other-root|$OTHER_ROOT"; do
    a_run validate "select	action=shared.code" "$(a_arg code "${pair#*|}")"
    assert_eq "$(c_result) $(c_admits validate)" "refused invalid ok" "actions-shared.code-validate: ${pair%%|*}"
    assert_contains "$C_OUT" "invalid	name=code	code=${pair%%|*}	" "actions-shared.code-validate: ${pair%%|*} named"
  done
  a_run validate "select	action=shared.code"
  assert_contains "$C_OUT" "invalid	name=code	code=required	" "actions-shared.code-validate: the code is required"
  a_run validate "select	action=shared.code" "$(a_arg code "$CODE")" "$(a_arg extra 1)"
  assert_contains "$C_OUT" "invalid	name=extra	code=unknown-parameter	" "actions-shared.code-validate: nothing else is taken"
  up=$(printf '%s' "$CODE" | tr 'a-f' 'A-F')
  a_run validate "select	action=shared.code" "$(a_arg code "$up")"
  assert_contains "$C_OUT" "normal	name=code	value=$CODE" "actions-shared.code-validate: its normal form"
  a_common shared.code "" "$(a_arg code "$CODE")"
  a_barriers shared.code shared "" "$(a_arg code "$CODE")"
  a_exec shared.code "" "$(a_arg code "$CODE")"
  assert_eq "$(c_result) $(c_admits execute)" "done ok ok" "actions-shared.code-success: recorded ($(a_text))"
  assert_contains "$(a_state)" "shared_linux_done=$CODE" "actions-shared.code-success: Linux's code is recorded"
  assert_empty_file "$A_DIR/record" "actions-shared.code-success: nothing runs"
  assert_eq "$(a_ops)" "" "actions-shared.code-success: its record is removed"
  a_umask actions-shared.code-umask
  a_run snapshot "scope	name=journey"
  case " $(a_actions)" in *" shared.create "*) ok ;; *) fail "actions-shared.create: offered once Linux's code is in" ;; esac
  case " $(a_actions)" in *" shared.code "*) fail "actions-shared.code: not offered again" ;; *) ok ;; esac
  SH_BYTES=$(((150000000000 + MIB - 1) / MIB * MIB))
  assert_contains "$C_OUT" "key=gate.shared.create.command	label=Command	value=sudo%20-n%20diskutil%20addPartition%20disk0s6%20ExFAT%20Shared%20$SH_BYTES" \
    "actions-shared.create: its gate facts name the one command"
  assert_eq "$(c_admits snapshot)" ok "actions-shared.create-records: the snapshot with its regions admits"
  assert_contains "$C_OUT" "size=$SH_BYTES	role=shared	label=Shared,%20to%20be%20created" \
    "actions-shared.create-records: where Shared would be created, at its size"
  assert_eq "$(printf '%s\n' "$C_OUT" | grep -c '^region	.*role=linux')" 1 "actions-shared.create-records: after the Linux root"
  a_common shared.create yes
  a_barriers shared.create shared yes
  # The word answers the backup gate only: create is typed on the terminal.
  a_exec_tty 'yes\nn\n\004\004\004' shared.create yes
  assert_eq "$(c_result)" "failed no-effect" "actions-shared.create-word: declined at create, nothing created"
  assert_contains "$A_TTY" 'only the exact word "create" continues' "actions-shared.create-word: create was asked on the terminal"
  assert_empty_file "$A_DIR/record" "actions-shared.create-word: no sudo, no diskutil"
  A_ENV="OMB_TEST_AFTER=$FIX/mac-shared-created" a_exec_tty 'create\n\004\004\004' shared.create yes
  assert_eq "$(c_result)" "done ok" "actions-shared.create-success: created ($(a_text))"
  assert_eq "$(cat "$A_DIR/record")" "sudo -v
sudo -n diskutil addPartition disk0s6 ExFAT Shared $SH_BYTES" "actions-shared.create-success: sudo -v, then the one addPartition"
  assert_contains "$(a_state)" "shared_uuid=4A7B1C2D-0007-4E5F-8A9B-000000000007" "actions-shared.create-success: the partition is recorded"
  [ ! -e "$A_DIR/state/shared-create.env" ] && ok || fail "actions-shared.create-success: the creation record is removed"
  assert_eq "$(a_ops)" "" "actions-shared.create-success: its operation record is removed"
  a_umask actions-shared.create-umask
  # actions-shared.create-unrecorded: the partition made, but its result not
  # recorded (the state disk full at shared_uuid's write): never completed.
  a_shared_state "$T/create-unrecorded"
  printf 'shared_linux_done=%s\n' "$CODE" >>"$A_DIR/state/state.env"
  cat >"$A_SHIMS/mv" <<EOF
#!/bin/sh
last='' prev=''
for a in "\$@"; do prev=\$last; last=\$a; done
case "\$last" in */state.env) if grep -q '^shared_uuid=' "\$prev" 2>/dev/null; then exit 1; fi ;; esac
exec $REAL_MV "\$@"
EOF
  chmod +x "$A_SHIMS/mv"
  A_ENV="OMB_TEST_AFTER=$FIX/mac-shared-created" a_exec_tty 'create\n\004\004\004' shared.create yes
  rm -f "$A_SHIMS/mv"
  assert_eq "$(c_result)" "failed postcondition" "actions-shared.create-unrecorded: a partition whose result was not recorded is not completed"
  assert_not_contains "$(a_state)" "shared_uuid=" "actions-shared.create-unrecorded: the result write failed"
  assert_contains "$(cat "$A_DIR/state/ops/shared.omb" 2>/dev/null)" "	state=failed	finding=unexpected	" "actions-shared.create-unrecorded: the barrier stays"
  [ -f "$A_DIR/state/shared-create.env" ] && ok || fail "actions-shared.create-unrecorded: the creation record says what happened"
  # actions-shared.create-reconcile-record: after a new boot, the creation
  # record holds the partition on a fresh read, and its result is recorded
  # then; a reconciliation that cannot record it keeps the barrier.
  : >"$A_DIR/record"
  for case in unwritable writable; do
    if [ "$case" = unwritable ]; then
      cat >"$A_SHIMS/mv" <<EOF
#!/bin/sh
last='' prev=''
for a in "\$@"; do prev=\$last; last=\$a; done
case "\$last" in */state.env) if grep -q '^shared_uuid=' "\$prev" 2>/dev/null; then exit 1; fi ;; esac
exec $REAL_MV "\$@"
EOF
      chmod +x "$A_SHIMS/mv"
    fi
    a_plant shared shared.create running 1 x "5E1D0B00-7A3C-4F21-9D6E-0000000000CC"
    A_FIX=$FIX/mac-shared-created a_run execute "exec	action=shared.create	basis=$ZERO	confirm=yes"
    rm -f "$A_SHIMS/mv"
    if [ "$case" = unwritable ]; then
      assert_eq "$(c_result)" "refused unsupervised" "actions-shared.create-reconcile-record: a result that cannot be recorded is not completed"
      assert_not_contains "$(a_state)" "shared_uuid=" "actions-shared.create-reconcile-record: nothing recorded"
      [ -e "$A_DIR/state/ops/shared.omb" ] && ok || fail "actions-shared.create-reconcile-record: the barrier stays"
      [ -f "$A_DIR/state/shared-create.env" ] && ok || fail "actions-shared.create-reconcile-record: and the creation record"
    else
      assert_contains "$C_OUT" "reconciled:%20completed" "actions-shared.create-reconcile-record: the proven partition is recorded and completed"
      assert_contains "$(a_state)" "shared_uuid=4A7B1C2D-0007-4E5F-8A9B-000000000007" "actions-shared.create-reconcile-record: its result is recorded"
      [ ! -e "$A_DIR/state/shared-create.env" ] && ok || fail "actions-shared.create-reconcile-record: the creation record is removed"
      assert_eq "$(a_ops)" "" "actions-shared.create-reconcile-record: the barrier goes"
      assert_empty_file "$A_DIR/record" "actions-shared.create-reconcile-record: nothing is created again"
    fi
  done
  # A partition on the disk whose record was lost: recorded, with no word.
  a_shared_state "$T/create-lost"
  printf 'shared_linux_done=%s\n' "$CODE" >>"$A_DIR/state/state.env"
  A_FIX=$FIX/mac-shared-created a_run snapshot "scope	name=journey"
  assert_contains "$C_OUT" "action	id=shared.create	scope=shared	label=Create%20Shared%20storage	intent=act	gate=	" \
    "actions-shared.create-record: a partition to record takes no word"
  A_FIX=$FIX/mac-shared-created a_exec_tty '\004\004' shared.create ""
  assert_eq "$(c_result)" "done ok" "actions-shared.create-record: recorded, nothing created ($(a_text))"
  assert_empty_file "$A_DIR/record" "actions-shared.create-record: no command ran"
  assert_contains "$(a_state)" "shared_uuid=4A7B1C2D-0007-4E5F-8A9B-000000000007" "actions-shared.create-record: the partition is recorded"
  a_unavailable shared.code "" "$R" "$(a_arg code "$CODE")"
  a_unavailable shared.create yes "$R"
fi

# ---------------------------------------------------------------------------
# Linux rows
# ---------------------------------------------------------------------------

# --- network.connect ---------------------------------------------------------------
a_use "$T/net" "$FIX/linux-alarm-offline"
a_run snapshot "scope	name=journey"
assert_eq "$(c_result) $(c_admits snapshot)" "done ok ok" "actions-network.connect: the Linux journey snapshot admits"
assert_contains "$C_OUT" "action	id=network.connect	scope=network	label=Connect%20to%20the%20network	intent=act	gate=	terminal=handoff	" \
  "actions-network.connect: scope network, a handoff, no word"
a_common network.connect ""
a_barriers network.connect network ""
A_ENV="OMB_TEST_AFTER=$FIX/linux-alarm-fresh" a_exec_tty 'y\n\004\004\004' network.connect ""
assert_eq "$(c_result)" "done ok" "actions-network.connect-success: online afterwards ($(a_text))"
assert_eq "$(cat "$A_DIR/record")" "nmtui" "actions-network.connect-success: nmtui ran once"
a_umask actions-network.connect-umask
: >"$A_DIR/record"
a_exec_tty 'y\ny\ny\n\004\004\004' network.connect ""
assert_eq "$(c_result)" "failed no-effect" "actions-network.connect-offline: still offline is no change"
assert_eq "$(grep -c '^nmtui$' "$A_DIR/record")" 3 "actions-network.connect-offline: nmtui offered three times, as the text flow does"
assert_eq "$(a_ops)" "" "actions-network.connect-offline: and leaves no record"
a_unavailable network.connect "" "$FIX/linux-alarm-fresh"
a_unavailable network.connect "" "$FIX/linux-omarchy-installed"

# --- omarchy.start -------------------------------------------------------------------
a_use "$T/start" "$FIX/linux-alarm-fresh"
a_run snapshot "scope	name=journey"
assert_contains "$C_OUT" "action	id=omarchy.start	scope=omarchy	label=Run%20omarchy-mac-setup	intent=act	gate=start	terminal=handoff	" \
  "actions-omarchy.start: scope omarchy, a handoff, word start"
assert_contains "$C_OUT" "fact	scope=omarchy	key=omarchy.console	label=Console	value=$(a_enc "$OMARCHY_SETUP_TTY (Ctrl+Alt+F${OMARCHY_SETUP_TTY#tty})")	state=info" \
  "actions-omarchy-console: the console the setup will write to, before it starts"
a_common omarchy.start start
a_barriers omarchy.start omarchy start
A_ENV="OMB_TEST_AFTER=$FIX/linux-setup-in-progress" a_exec_tty '\nalex\n\n\n\n\004\004\004' omarchy.start start
assert_eq "$(c_result)" "done ok" "actions-omarchy.start-success: the setup is under way ($(a_text))"
assert_contains "$(cat "$A_DIR/record")" "bash $A_DIR/state/downloads/omarchy-mac-setup-" "actions-omarchy.start-success: the checked download runs"
assert_contains "$(cat "$A_DIR/record")" " --encrypt --user alex --hostname omarchy --keymap us" "actions-omarchy.start-success: with the choices as flags"
assert_eq "$(printf '%s\n' "$A_TTY" | grep -c 'Typed in the interface: start')" 1 "actions-omarchy.start-word: the word answered the start gate once"
assert_contains "$(a_state)" "omarchy_launched_at=" "actions-omarchy.start-success: the launch is recorded first"
a_umask actions-omarchy.start-umask
a_use "$T/start-quit" "$FIX/linux-alarm-fresh"
a_exec_tty '\nalex\n\n\n\n\004\004\004' omarchy.start start
assert_eq "$(c_result)" "failed no-effect" "actions-omarchy.start-noeffect: the setup ended leaving the machine as it was"
a_use "$T/start-stop" "$FIX/linux-alarm-fresh"
a_exec_tty 'q\n\004\004\004' omarchy.start start
assert_eq "$(c_result)" "failed no-effect" "actions-omarchy.start-noeffect: stopped at the choices, never launched"
assert_empty_file "$A_DIR/record" "actions-omarchy.start-noeffect: nothing ran"
a_unavailable omarchy.start start "$FIX/linux-alarm-offline"
a_unavailable omarchy.start start "$FIX/linux-setup-in-progress"
a_unavailable omarchy.start start "$FIX/linux-omarchy-installed"

# --- omarchy.resume ------------------------------------------------------------------
a_use "$T/resume" "$FIX/linux-setup-in-progress"
# The progress screen reads Omarchy's own signals from its facts.
a_run snapshot "scope	name=journey"
assert_eq "$(c_result) $(c_admits snapshot)" "done ok ok" "actions-omarchy.resume: the snapshot admits"
assert_contains "$C_OUT" "fact	scope=omarchy	key=omarchy.state	label=Omarchy	value=in-progress	state=info" "actions-omarchy.resume-facts: Omarchy's state"
assert_contains "$C_OUT" "key=omarchy.encryption	" "actions-omarchy.resume-facts: its encryption"
assert_contains "$C_OUT" "key=omarchy.upstream.1	label=Upstream	value=" "actions-omarchy.resume-facts: upstream's own status, read as root"
assert_contains "$C_OUT" "fact	scope=omarchy	key=omarchy.console	label=Console	value=$(a_enc "$OMARCHY_SETUP_TTY (Ctrl+Alt+F${OMARCHY_SETUP_TTY#tty})")	state=info" \
  "actions-omarchy-console: the console the setup writes to, on its progress page"
a_common omarchy.resume resume
a_barriers omarchy.resume omarchy resume
A_ENV="OMB_TEST_AFTER=$FIX/linux-omarchy-finishing" a_exec_tty '\004\004\004' omarchy.resume resume
assert_eq "$(c_result)" "done ok" "actions-omarchy.resume-success: resumed, and the machine shows Omarchy installed ($(a_text))"
assert_eq "$(cat "$A_DIR/record")" "/usr/local/bin/omarchy-mac-setup --resume" "actions-omarchy.resume-success: upstream's resume runs"
assert_contains "$(a_state)" "omarchy_resumed_at=" "actions-omarchy.resume-success: recorded first"
a_umask actions-omarchy.resume-umask
# actions-omarchy.resume-claims: the command's status alone never proves no
# effect. Even real progress remains unexpected until installed is observed.
VP=$(t_variant linux-setup-in-progress)
chmod +x "$VP/root/usr/local/bin/omarchy-mac-setup"
VR=$(t_variant linux-setup-in-progress)
rm -f "$VR/root/usr/local/bin/omarchy-mac-setup"
VF=$(t_variant linux-setup-in-progress)
printf 'failed\n' >"$VF/cmd/unit_active"
VS=$(t_variant linux-setup-in-progress)
: >"$VS/cmd/setup_status"
printf '1\n' >"$VS/cmd/setup_status.rc"
VB=$(t_variant linux-setup-in-progress)
: >"$VB/cmd/findmnt_boot"
printf '1\n' >"$VB/cmd/findmnt_boot.rc"
for case in "present-127|$VP|$VP|127|failed postcondition" \
  "missing-127|$VP|$VR|127|failed no-effect" \
  "missing-0|$VP|$VR|0|failed postcondition" \
  "same|$VP|$VP|0|failed postcondition" \
  "advanced|$FIX/linux-encrypt-staged|$FIX/linux-encrypt-reencrypting|0|failed postcondition" \
  "failed-service|$VP|$VF|0|failed postcondition" \
  "unread-status|$VP|$VS|1|failed postcondition" \
  "boot-absent|$VB|$VB|0|failed postcondition" \
  "boot-absent-installed|$VB|$FIX/linux-omarchy-finishing|1|done ok"; do
  a_use "$T/resume-${case%%|*}" "$(printf '%s' "$case" | cut -d'|' -f2)"
  A_ENV="OMB_TEST_AFTER=$(printf '%s' "$case" | cut -d'|' -f3) OMB_TEST_RC=$(printf '%s' "$case" | cut -d'|' -f4)" a_exec_tty '\004\004\004' omarchy.resume resume
  assert_eq "$(c_result)" "${case##*|}" "actions-omarchy.resume-claims: ${case%%|*} ($(a_text))"
  if [ "${case##*|}" = "failed postcondition" ]; then
    assert_contains "$(a_ops)" "omarchy.omb" "actions-omarchy.resume-claims: ${case%%|*} keeps the operation barrier"
  else
    assert_eq "$(a_ops)" "" "actions-omarchy.resume-claims: ${case%%|*} leaves no operation barrier"
  fi
done
a_unavailable omarchy.resume resume "$FIX/linux-setup-active"
a_unavailable omarchy.resume resume "$FIX/linux-alarm-fresh"

# --- shared.code (Linux) and shared.activate ----------------------------------------------
SCODE=$( (t_load >/dev/null 2>&1 && code_make ombshare 1a2b3c4d 4A7B1C2D-0007-4E5F-8A9B-000000000007))
a_use "$T/lcode" "$FIX/linux-shared-present"
a_run snapshot "scope	name=journey"
assert_contains "$C_OUT" "param	action=shared.code	name=code	type=code	kind=ombshare	required=1" "actions-shared.code: on Linux it takes macOS's code"
for pair in "mistyped|ombshare-1" "no-partition|$( (t_load >/dev/null 2>&1 && code_make ombshare 1a2b3c4d 4A7B1C2D-0009-4E5F-8A9B-000000000009))"; do
  a_run validate "select	action=shared.code" "$(a_arg code "${pair#*|}")"
  assert_contains "$C_OUT" "invalid	name=code	code=${pair%%|*}	" "actions-shared.code-validate: Linux, ${pair%%|*}"
done
a_common shared.code "" "$(a_arg code "$SCODE")"
a_exec shared.code "" "$(a_arg code "$SCODE")"
assert_eq "$(c_result)" "done ok" "actions-shared.code-linux: recorded ($(a_text))"
assert_contains "$(a_state)" "shared_id12=4a7b1c2d0007" "actions-shared.code-linux: the partition is identified"
a_umask actions-shared.code-linux-umask
a_run snapshot "scope	name=journey"
case " $(a_actions)" in *" shared.activate "*) ok ;; *) fail "actions-shared.activate: offered once the partition is identified" ;; esac
a_common shared.activate mount
a_barriers shared.activate shared mount
A_ENV="OMB_TEST_AFTER=$FIX/linux-shared-ready" a_exec_tty '\004\004\004' shared.activate mount
assert_eq "$(c_result)" "done ok" "actions-shared.activate-success: mounts on every boot ($(a_text))"
assert_eq "$(sed 's#/[^ ]*/omarchy-bootstrap\.[A-Za-z0-9]*/fstab#TMP/fstab#' "$A_DIR/record")" "sudo install -d -m 0755 -o root -g root /mnt/shared
sudo cp -p /etc/fstab /etc/fstab.omarchy-bootstrap.bak
sudo install -m 0644 -o root -g root TMP/fstab /etc/fstab.omarchy-bootstrap.new
sudo mv -f /etc/fstab.omarchy-bootstrap.new /etc/fstab
sudo systemctl daemon-reload
sudo systemctl start mnt-shared.automount" "actions-shared.activate-success: the text flow's commands, in its order"
assert_contains "$(a_state)" "shared_activated_at=" "actions-shared.activate-success: recorded"
a_umask actions-shared.activate-umask
a_use "$T/activate-none" "$FIX/linux-shared-present"
printf 'shared_id12=4a7b1c2d0007\n' >"$A_DIR/state.env.pre"
mkdir -p "$A_DIR/state" && chmod 700 "$A_DIR/state" && mv "$A_DIR/state.env.pre" "$A_DIR/state/state.env" && chmod 600 "$A_DIR/state/state.env"
a_exec_tty '\004\004\004' shared.activate mount
assert_eq "$(c_result)" "failed postcondition" "actions-shared.activate-absent: the commands ran and Shared is not set to mount: failed"
assert_contains "$(cat "$A_DIR/state/ops/shared.omb" 2>/dev/null)" "	state=failed	finding=absent	" "actions-shared.activate-absent: its record says so"
a_unavailable shared.code "" "$FIX/linux-shared-ready" "$(a_arg code "$SCODE")"
a_unavailable shared.activate mount "$FIX/linux-shared-present"
a_unavailable shared.activate mount "$FIX/linux-alarm-fresh"

# --- shared.test --------------------------------------------------------------------------
# Shared mounted, as the kernel's mount table shows it once the automount has.
VT=$(t_variant linux-shared-ready)
"$REAL_SED" -i.bak 's#^120 23 0:48 / /mnt/shared .*#120 23 259:7 / /mnt/shared rw,nodev,nosuid,noexec,relatime shared:60 - exfat /dev/nvme0n1p7 rw,uid=1000,gid=1000,fmask=0177,dmask=0077#' "$VT/root/proc/self/mountinfo" && rm -f "$VT/root/proc/self/mountinfo.bak"
a_use "$T/stest" "$VT"
a_common shared.test test
a_barriers shared.test shared test
a_exec_tty '\004\004\004' shared.test test
assert_eq "$(c_result)" "done ok" "actions-shared.test-success: written, read back, removed ($(a_text))"
assert_eq "$(sed -e 's#/[^ ]*/omarchy-bootstrap\.[A-Za-z0-9]*/shared-test#SRC#' -e 's#test-[0-9TZ]*-[0-9]*$#test-X#' "$A_DIR/record")" "cp SRC /mnt/shared/.omarchy-bootstrap-test-X
sync
rm -f /mnt/shared/.omarchy-bootstrap-test-X" "actions-shared.test-success: the write, the flush, the removal"
a_umask actions-shared.test-umask
mkdir -p "$VT/root/mnt/shared"
: >"$VT/root/mnt/shared/.omarchy-bootstrap-test-20260101T000000Z-1"
a_exec_tty '\004\004\004' shared.test test
assert_eq "$(c_result)" "failed postcondition" "actions-shared.test-left: a test file left on Shared is failed"
a_unavailable shared.test test "$FIX/linux-shared-present"

# --- dev ----------------------------------------------------------------------------------
a_use "$T/dev" "$FIX/linux-omarchy-installed"
a_run snapshot "scope	name=journey"
assert_contains "$C_OUT" "action	id=dev	scope=omarchy	label=Developer%20setup	intent=act	gate=	terminal=handoff	" \
  "actions-dev: in the omarchy scope, a handoff, no word"
a_common dev ""
a_barriers dev omarchy ""
A_WAIT="Choose what to set up" A_ENV="OMB_TEST_AFTER=$FIX/linux-dev-complete" a_exec_tty '\n\004\004\004' dev ""
assert_eq "$(c_result)" "done ok" "actions-dev-success: the marked part set up ($(a_text))"
assert_contains "$(cat "$A_DIR/record")" "omarchy-pkg-add " "actions-dev-success: through Omarchy's own helper"
assert_contains "$(a_state)" "dev_last_run_at=" "actions-dev-success: the run is stamped done"
a_umask actions-dev-umask
a_use "$T/dev-none" "$FIX/linux-omarchy-installed"
A_WAIT="Choose what to set up" a_exec_tty ' \n\004\004\004' dev ""
assert_eq "$(c_result)" "failed no-effect" "actions-dev-noeffect: nothing chosen, nothing changed"
assert_empty_file "$A_DIR/record" "actions-dev-noeffect: nothing ran"
# actions-dev-reconcile-older: after a new boot, an older run's success never
# completes an operation that began after it; one recorded after it does.
# actions-dev-reconcile-same-second: so does one recorded in the second the
# operation began (both are kept to the second; the record's at is
# 2026-09-26T00:00:00Z).
for case in "older|2026-01-01T00:00:00Z" "later|2026-12-01T00:00:00Z" "same|2026-09-26T00:00:00Z"; do
  a_use "$T/dev-boot-${case%%|*}" "$FIX/linux-omarchy-installed"
  mkdir -p "$A_DIR/state" && chmod 700 "$A_DIR/state"
  printf 'dev_last_run_at=%s\ndev_modules=core\n' "${case#*|}" >"$A_DIR/state/state.env" && chmod 600 "$A_DIR/state/state.env"
  a_plant omarchy dev running 1 x "5E1D0B00-7A3C-4F21-9D6E-0000000000BB"
  a_run execute "exec	action=dev	basis=$ZERO	confirm="
  if [ "${case%%|*}" = older ]; then
    assert_eq "$(c_result)" "refused unsupervised" "actions-dev-reconcile-older: a success older than the operation does not complete it"
    [ -e "$A_DIR/state/ops/omarchy.omb" ] && ok || fail "actions-dev-reconcile-older: the record stays"
  else
    t=actions-dev-reconcile-older
    [ "${case%%|*}" = same ] && t=actions-dev-reconcile-same-second
    assert_contains "$C_OUT" "reconciled:%20completed" "$t: a success recorded at or after the operation began completes it (${case%%|*})"
  fi
done
a_unavailable dev "" "$FIX/linux-alarm-fresh"
a_unavailable dev "" "$FIX/linux-setup-in-progress"

# ---------------------------------------------------------------------------
# equiv-*: each row against the accepted baseline (docs/TESTING.md →
# Equivalence with the accepted baseline). The same fixture and words through
# the baseline's text flow and through `core execute`, from the same state:
# the recorded commands in order and the final state folder, byte for byte
# after the fixed normaliser. Named deltas, each with its reason:
#   - logs/: the core logs its own requests and operation records; the log
#     is the run's narration, never state a decision reads.
#   - ops/: the core's operation records live there and each is removed when
#     its action ends; the folder stays, empty.
#   - asahi_prelaunch_layout and asahi_prelaunch_resized in state.env: what
#     the launch began from, recorded before it runs, so a reconciliation
#     after a new boot can prove what changed.
# ---------------------------------------------------------------------------
mkdir -p "$T/base"
if git -C "$REPO" cat-file -e "$BASELINE^{commit}" 2>/dev/null; then
  git -C "$REPO" archive "$BASELINE" | tar -x -C "$T/base" || fail "the baseline could not be extracted"
else
  fail "the accepted baseline $BASELINE is not in this clone (CI checks out with fetch-depth: 0)"
fi
E=0

# e_prep DIR [PRE] — a fresh side: home, tmp, and PRE's state files.
e_prep() {
  mkdir -p "$1/home" "$1/tmp"
  if [ -n "${2:-}" ]; then
    mkdir -p "$1/state"
    chmod 700 "$1/state"
    cp -p "$2"/state.env "$1/state/"
    [ ! -f "$2/shared-intent.env" ] || cp -p "$2/shared-intent.env" "$1/state/"
  fi
}

# e_base DIR FIXTURE INPUT ARGS... — the baseline's text flow, its words piped.
e_base() {
  local d=$1 fx=$2 input=$3 s
  shift 3
  s=$(a_shims "$d")
  # shellcheck disable=SC2086 # E_ENV is a list of assignments by design
  printf '%b' "$input" | env -i PATH="$s:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$d/home" TMPDIR="$d/tmp" \
    LANG=en_US.UTF-8 TERM=dumb OMB_STATE_DIR="$d/state" OMB_FIXTURE="$fx" SHIM_LOG="$d/shims.log" \
    OMB_TEST_RECORD="$d/record" ${E_ENV:-} "$T_BASH" "$T/base/omarchy-bootstrap" "$@" >"$d/out" 2>&1
  touch "$d/record" "$d/shims.log"
}

# e_norm TREE DIR — what a run left, its per-run values replaced: the run's
# folder, the tree, times, stamps, mktemp suffixes and $$; the named deltas
# left out.
e_norm() {
  local tree=$1 d=$2 f
  {
    echo "== record"
    cat "$d/record"
    echo "== shims"
    cat "$d/shims.log"
    echo "== state"
    if [ -d "$d/state" ]; then
      (cd "$d/state" && find . -print | grep -v -e '^\./logs' -e '^\./ops$' | LC_ALL=C sort)
      find "$d/state" -type f | grep -v -e '/logs/' -e '/ops/' | LC_ALL=C sort | while read -r f; do
        echo "-- ${f#"$d"/state}"
        cat "$f"
      done
    fi
  } | "$REAL_SED" -E \
    -e "s#$d#RUN#g" \
    -e "s#$FIX#FIX#g" \
    -e "s#$tree#TREE#g" \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/TIME/g' \
    -e 's/[0-9]{8}T[0-9]{6}Z/STAMP/g' \
    -e 's/(omarchy-bootstrap|\.state\.env|downloads\/[a-z-]+\.sh-STAMP|shared-[a-z-]+\.env)\.[A-Za-z0-9]{6}/\1.XXXXXX/g' \
    -e 's/(-STAMP)\.[A-Za-z0-9]{6}/\1.XXXXXX/g' \
    -e 's/(\.omarchy-bootstrap-test-STAMP)-[0-9]+/\1-PID/g' \
    -e '/^asahi_prelaunch_layout=/d' -e '/^asahi_prelaunch_resized=/d'
}

# e_agree ID — the baseline's side and the core's side left the same.
e_agree() {
  e_norm "$T/base" "$EB" >"$EB.norm"
  e_norm "$REPO" "$EC" >"$EC.norm"
  if cmp -s "$EB.norm" "$EC.norm"; then
    ok
  else
    fail "$1: the core's run differs from the accepted baseline's"
    diff "$EB.norm" "$EC.norm" | head -20
  fi
  [ -s "$EB.norm" ] && ok || fail "$1: nothing to compare"
}

# e_case [PRE] — EB and EC, two fresh sides of the next case.
e_case() {
  E=$((E + 1))
  EB=$T/e/base-$E EC=$T/e/core-$E
  e_prep "$EB" "${1:-}"
  e_prep "$EC" "${1:-}"
}

# e_core FIXTURE — the core's side reads FIXTURE and writes into EC.
e_core() {
  A_DIR=$EC A_FIX=$1
  A_SHIMS=$(a_shims "$EC")
  : >"$EC/umask"
  touch "$EC/record" "$EC/shims.log"
}

# e_preset FIXTURE SHARED_GB — the Linux size the text flow's storage
# question offers by default, in whole GB.
e_preset() {
  (
    t_load >/dev/null 2>&1
    OMB_FIXTURE=$FIX/$1
    mac_detect
    mac_plan_compute "$2"
    plan_presets
    printf '%s\n' "$PRESETS" | awk -F'|' -v k="$PRESET_DEFAULT" '$1 == k { print int($3 / 1000000000) }'
  )
}

if t_plutil "the macOS rows against the baseline"; then
  # plan.save: the text flow's plan with every default, and with 150 GB of
  # Shared (option 4).
  for s in 0 150; do
    e_case
    lin=$(e_preset mac-m1pro-1tb-roomy "$s")
    if [ "$s" = 0 ]; then
      e_base "$EB" "$R" '\n\n\n\n\n\n\n\n\n\n\n\n\n\n' plan
      sv=0
    else
      e_base "$EB" "$R" '\n4\n\n\n\n\n\n\n\n\n\n\n\n' plan
      sv=150GB
    fi
    e_core "$R"
    a_exec plan.save "" "$(a_arg linux_size "${lin}GB")" "$(a_arg shared_size "$sv")"
    assert_eq "$(c_result)" "done ok" "equiv-plan.save ($s GB Shared): the core saved it"
    e_agree "equiv-plan.save ($s GB Shared)"
    [ "$s" = 0 ] && cp -R "$EB/state" "$T/pre-plan0"
    [ "$s" = 150 ] && cp -R "$EB/state" "$T/pre-plan150"
  done
  # asahi.launch: from the saved plan, the install flow's answers (the saved
  # ones), yes, no inspection, launch.
  e_case "$T/pre-plan0"
  E_ENV="OMB_TEST_AFTER=$FIX/mac-asahi-pending" e_base "$EB" "$R" '\n\n\n\n\n\n\n\n\n\n\n\n\nyes\n\nlaunch\n' install
  e_core "$R"
  A_ENV="OMB_TEST_AFTER=$FIX/mac-asahi-pending" a_exec_tty '\nlaunch\n\004\004\004' asahi.launch yes
  assert_eq "$(c_result)" "done ok" "equiv-asahi.launch: the core launched it"
  e_agree equiv-asahi.launch
  # shared.code: Linux's code into shared create, which then stops at its
  # first gate.
  digest=$(sed -n 's/^digest=//p' "$T/pre-plan150/shared-intent.env" | cut -c1-8)
  CODE=$( (t_load >/dev/null 2>&1 && code_make ombdone "$digest" 4A7B1C2D-0006-4E5F-8A9B-000000000006))
  e_case "$T/pre-plan150"
  e_base "$EB" "$FIX/mac-shared-reserved" 'n\n' shared create "$CODE"
  e_core "$FIX/mac-shared-reserved"
  a_exec shared.code "" "$(a_arg code "$CODE")"
  assert_eq "$(c_result)" "done ok" "equiv-shared.code: the core took the code"
  e_agree equiv-shared.code
  cp -R "$EB/state" "$T/pre-receipt"
  # shared.create: from Linux's code, both gates and the one recorded change.
  e_case "$T/pre-receipt"
  E_ENV="OMB_TEST_AFTER=$FIX/mac-shared-created" e_base "$EB" "$FIX/mac-shared-reserved" 'yes\ncreate\n' shared create
  e_core "$FIX/mac-shared-reserved"
  A_ENV="OMB_TEST_AFTER=$FIX/mac-shared-created" a_exec_tty 'create\n\004\004\004' shared.create yes
  assert_eq "$(c_result)" "done ok" "equiv-shared.create: the core created it"
  e_agree equiv-shared.create
fi

# network.connect: offline, nmtui three times, still offline.
e_case
e_base "$EB" "$FIX/linux-alarm-offline" 'y\ny\ny\n'
e_core "$FIX/linux-alarm-offline"
a_exec_tty 'y\ny\ny\n\004\004\004' network.connect ""
e_agree equiv-network.connect
# omarchy.start: the choices asked, no inspection, start.
e_case
E_ENV="OMB_TEST_AFTER=$FIX/linux-setup-in-progress" e_base "$EB" "$FIX/linux-alarm-fresh" '\nalex\n\n\n\nstart\n'
e_core "$FIX/linux-alarm-fresh"
A_ENV="OMB_TEST_AFTER=$FIX/linux-setup-in-progress" a_exec_tty '\nalex\n\n\n\n\004\004\004' omarchy.start start
e_agree equiv-omarchy.start
# omarchy.resume.
e_case
E_ENV="OMB_TEST_AFTER=$FIX/linux-omarchy-finishing" e_base "$EB" "$FIX/linux-setup-in-progress" 'resume\n'
e_core "$FIX/linux-setup-in-progress"
A_ENV="OMB_TEST_AFTER=$FIX/linux-omarchy-finishing" a_exec_tty '\004\004\004' omarchy.resume resume
e_agree equiv-omarchy.resume
# shared.code on Linux: macOS's code into shared activate, which then stops
# at its gate.
e_case
e_base "$EB" "$FIX/linux-shared-present" 'n\n' shared activate "$SCODE"
e_core "$FIX/linux-shared-present"
a_exec shared.code "" "$(a_arg code "$SCODE")"
e_agree equiv-shared.code-linux
cp -R "$EB/state" "$T/pre-id12"
# shared.activate: from the identified partition, mount.
e_case "$T/pre-id12"
E_ENV="OMB_TEST_AFTER=$FIX/linux-shared-ready" e_base "$EB" "$FIX/linux-shared-present" 'mount\n' shared activate
e_core "$FIX/linux-shared-present"
A_ENV="OMB_TEST_AFTER=$FIX/linux-shared-ready" a_exec_tty '\004\004\004' shared.activate mount
e_agree equiv-shared.activate
# shared.test, on Shared mounted.
rm -rf "$VT/root/mnt"
e_case
e_base "$EB" "$VT" 'test\n' shared test
e_core "$VT"
a_exec_tty '\004\004\004' shared.test test
e_agree equiv-shared.test
# dev: the marked part (core tools), through Omarchy's helper.
e_case
E_ENV="OMB_TEST_AFTER=$FIX/linux-dev-complete" e_base "$EB" "$FIX/linux-omarchy-installed" '\n' dev
e_core "$FIX/linux-omarchy-installed"
A_WAIT="Choose what to set up" A_ENV="OMB_TEST_AFTER=$FIX/linux-dev-complete" a_exec_tty '\n\004\004\004' dev ""
e_agree equiv-dev

# No run wrote into the committed fixtures, and no request left its scratch.
assert_eq "$(git -C "$REPO" status --porcelain --untracked-files=all -- tests/fixtures)" "" "the committed fixtures are as they were"
assert_eq "$(find "$SESS" -name '*.core' -o -name '*.worker-*')" "" "no core identity residue"
t_done test-actions
