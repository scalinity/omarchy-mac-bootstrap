# shellcheck shell=bash
# shellcheck disable=SC2012,SC2016 # ls over names the test made; literal $ in the scripts it writes
# The hermetic boundary of the frontend-check-* cases (docs/TESTING.md →
# frontend-check-*): a copy of the tool whose release/frontend.lock is a test
# lock; a temporary HOME, XDG_CACHE_HOME, XDG_STATE_HOME and TMPDIR, with
# OMB_STATE_DIR unset and no fixture, development or OMB_TEST_ seam set; a
# loopback HTTPS server the test owns, its throwaway certificate authority
# trusted only through curl's own CURL_CA_BUNDLE, so acquisition runs its
# normal path — curl, the size, the digest, the promotion; and a real
# terminal, the PTY `script` makes, in a session of its own. Nothing is
# fetched from outside the loopback, no baseline probe or action runs, and
# the runner's root cache is never touched. Sourced after tests/lib.sh by
# tests/test-frontend-check.sh and tests/frontend-check.sh; set T first.

# fc_setup — the copy, the uname shim (every runner the aarch64 answer), the
# certificates, the folders. FC_TARGET: the host's frontend target, as the
# launcher will see it.
fc_setup() {
  TOOL=$T/tool
  mkdir -p "$TOOL/release" "$T/home" "$T/cache" "$T/xstate" "$T/tmp" "$T/www" "$T/pki" "$T/shim"
  cp -R "$REPO/omarchy-bootstrap" "$REPO/lib" "$REPO/data" "$TOOL/"
  case "$(uname -s)" in
    Darwin)
      FC_TARGET=aarch64-apple-darwin
      printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) /usr/bin/uname "$@" ;; esac\n' >"$T/shim/uname"
      ;;
    *)
      FC_TARGET=aarch64-unknown-linux-gnu
      printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo aarch64 ;; *) /bin/uname "$@" ;; esac\n' >"$T/shim/uname"
      ;;
  esac
  chmod +x "$T/shim/uname"
  FC_CACHE=$T/cache/omarchy-mac-bootstrap/frontend
  fc_pki
}

# fc_guard — $T/guard, first on the launcher's PATH (FC_PATH): every
# installer probe and action fails loudly into $T/forbid.log (none may run);
# a read of a frontend.lock through head is logged in $T/lock-reads.log; a
# cached omb-tui hashed is logged in $T/order.log (where a stand-in notes
# that it started).
fc_guard() {
  local g=$T/guard n real
  mkdir -p "$g"
  : >"$T/forbid.log"
  for n in diskutil system_profiler sw_vers bless nvram csrutil sudo pacman lsblk nmtui systemctl cryptsetup \
    hdiutil asr mount fdisk sgdisk wipefs mkfs.exfat omarchy-mac-setup; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>"%s"\necho "FORBIDDEN in frontend-check tests: %s" >&2\nexit 97\n' "$n" "$T/forbid.log" "$n" >"$g/$n"
    chmod +x "$g/$n"
  done
  real=$(command -v head)
  printf '#!/bin/sh\ncase "$*" in *frontend.lock*) printf "lock %%s\\n" "$*" >>"%s" ;; esac\nexec %s "$@"\n' "$T/lock-reads.log" "$real" >"$g/head"
  chmod +x "$g/head"
  for n in shasum sha256sum; do
    real=$(command -v "$n") || continue
    printf '#!/bin/sh\ncase "$*" in */omb-tui) printf "hash %%s\\n" "$*" >>"%s" ;; esac\nexec %s "$@"\n' "$T/order.log" "$real" >"$g/$n"
    chmod +x "$g/$n"
  done
  FC_PATH="$g:$T/shim:/usr/bin:/bin:/usr/sbin:/sbin"
}

# fc_order — $T/order-shim, for FC_PATH ahead of the guard: the launcher's
# head, stty, ps and rm each logged into $T/order.log with its parent and
# its parent's parent (a command substitution runs in a child of the
# launcher), then run. For an omb-session path, rm refuses while
# $T/rm-refuse exists, removes it and still fails while $T/rm-fails-after
# does, and succeeds without removing it while $T/rm-skip does.
fc_order() {
  local n real ps
  ps=$(PATH="$FC_PATH" command -v ps)
  mkdir -p "$T/order-shim"
  for n in head stty ps rm; do
    real=$(PATH="$FC_PATH" command -v "$n")
    printf '#!/bin/sh\nprintf "%%s %%s %s %%s\\n" "$PPID" "$(%s -o ppid= -p "$PPID" | tr -d " ")" "$*" >>"%s"\n' "$n" "$ps" "$T/order.log" >"$T/order-shim/$n"
    [ "$n" = rm ] && printf 'case "$*" in\n  *omb-session.*)\n    [ -e "%s/rm-refuse" ] && exit 1\n    [ -e "%s/rm-skip" ] && exit 0\n    if [ -e "%s/rm-fails-after" ]; then %s "$@"; exit 1; fi\n    ;;\nesac\n' \
      "$T" "$T" "$T" "$real" >>"$T/order-shim/$n"
    printf 'exec %s "$@"\n' "$real" >>"$T/order-shim/$n"
    chmod +x "$T/order-shim/$n"
  done
}

# fc_order_seq PID — the launcher PID's own steps in $T/order.log, in order:
# G its settings read (stty -g), S put back, P a reading of the process
# group, H a spool admitted, R the session scratch removed.
fc_order_seq() {
  awk -v p="$1" '$1 == p || $2 == p {
      if ($3 == "ps" && $0 ~ /pgid=,lstart=/) s = s "P"
      else if ($3 == "head" && $0 ~ /\/req-[0-9]+\.events/) s = s "H"
      else if ($3 == "stty" && $4 == "-g") s = s "G"
      else if ($3 == "stty") s = s "S"
      else if ($3 == "rm" && $0 ~ /omb-session\./) s = s "R"
    } END { print s }' "$T/order.log"
}

# fc_openssl — FC_OPENSSL: an OpenSSL openssl, whose s_server binds
# 127.0.0.1 alone and reports the port it bound (LibreSSL's does neither).
fc_openssl() {
  local o
  FC_OPENSSL=""
  for o in "$(command -v openssl 2>/dev/null)" /opt/homebrew/bin/openssl /usr/local/bin/openssl \
    /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    if [ -z "$o" ] || [ ! -x "$o" ]; then continue; fi
    case "$("$o" version 2>/dev/null)" in
      OpenSSL\ [3-9]*)
        FC_OPENSSL=$o
        return 0
        ;;
    esac
  done
  return 1
}

# fc_pki — a throwaway certificate authority and a server certificate for
# 127.0.0.1, made for this run and trusted by nothing but CURL_CA_BUNDLE.
fc_pki() {
  local d=$T/pki
  printf '%s\n' '[req]' 'distinguished_name = dn' 'prompt = no' '[dn]' 'CN = omarchy-bootstrap test CA' \
    '[ca]' 'basicConstraints = critical,CA:TRUE' 'keyUsage = critical,keyCertSign,cRLSign' \
    '[srv]' 'basicConstraints = critical,CA:FALSE' 'keyUsage = critical,digitalSignature,keyEncipherment' \
    'extendedKeyUsage = serverAuth' 'subjectAltName = IP:127.0.0.1' >"$d/ca.cnf"
  "$FC_OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout "$d/ca.key" -out "$d/ca.pem" -days 2 -config "$d/ca.cnf" -extensions ca >/dev/null 2>&1 &&
    "$FC_OPENSSL" req -newkey rsa:2048 -nodes -keyout "$d/srv.key" -out "$d/srv.csr" -subj /CN=127.0.0.1 >/dev/null 2>&1 &&
    "$FC_OPENSSL" x509 -req -in "$d/srv.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAcreateserial -out "$d/srv.pem" \
      -days 2 -extfile "$d/ca.cnf" -extensions srv >/dev/null 2>&1
}

# fc_serve [stall] — the loopback server: $T/www over HTTPS (s_server -WWW,
# one "FILE:name" line in $T/srv.log per request), or, with stall, one that
# completes the handshake and never answers. FC_PORT, and FC_SRV with its
# start time: the only way the test signals it.
fc_serve() {
  local i=0 mode="-WWW" in=/dev/null
  fc_unserve
  : >"$T/srv.log"
  if [ "${1:-}" = stall ]; then
    # Its input a FIFO this shell holds open and never writes: after the
    # handshake it waits for bytes to send that never come.
    mode="" in=$T/stall
    [ -p "$in" ] || mkfifo "$in"
    exec 8<>"$in"
  fi
  # shellcheck disable=SC2086 # mode is one flag or none
  (cd "$T/www" && exec "$FC_OPENSSL" s_server -accept 127.0.0.1:0 -cert "$T/pki/srv.pem" -key "$T/pki/srv.key" $mode <"$in") >"$T/srv.log" 2>&1 &
  FC_SRV=$!
  FC_SRV_START=$(t_started "$FC_SRV")
  FC_PORT=""
  while [ -z "$FC_PORT" ] && [ "$i" -lt 100 ]; do
    FC_PORT=$(sed -n 's/^ACCEPT 127\.0\.0\.1:\([0-9][0-9]*\)$/\1/p' "$T/srv.log")
    [ -n "$FC_PORT" ] || sleep 0.1
    i=$((i + 1))
  done
  [ -n "$FC_PORT" ]
}

# fc_unserve — end the server this test started, by its PID and start time.
fc_unserve() {
  if [ -n "${FC_SRV:-}" ]; then
    t_signal TERM "$FC_SRV" "$FC_SRV_START"
    wait "$FC_SRV" 2>/dev/null
  fi
  FC_SRV=""
  exec 8>&- 2>/dev/null
  return 0
}

# fc_requests — how many files the server has sent since it started.
fc_requests() { grep -c '^FILE:' "$T/srv.log"; }

# fc_lock SIZE SHA [VERSION] [TARGET] — the copy's lock, sealed: one frontend
# of VERSION (0.1.0) for TARGET (this host's) at the server's URL.
fc_lock() {
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    f=$TOOL/release/frontend.lock
    {
      printf 'omb-frontend-lock 1\n'
      rec_line frontend version "${3:-0.1.0}" proto 1 source_commit "$(printf '%040d' 0)" inputs_digest "$(printf '%064d' 0)" rust 1.88.0
      rec_line artifact target "${4:-$FC_TARGET}" url "https://127.0.0.1:$FC_PORT/omb-tui" size "$1" sha256 "$2" minos "" glibc_max "" interp "" align_min ""
    } >"$f"
    rec_seal_write "$f"
    omb_cleanup
  )
}

# fc_pin FILE [VERSION] — serve FILE as the artifact and pin it by its size
# and SHA-256. FC_SHA, FC_SIZE.
fc_pin() {
  cp "$1" "$T/www/omb-tui"
  FC_SHA=$(fc_sha "$1")
  FC_SIZE=$(wc -c <"$1" | tr -d ' ')
  fc_lock "$FC_SIZE" "$FC_SHA" "${2:-0.1.0}"
}

fc_sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -c1-64; else sha256sum "$1" | cut -c1-64; fi; }

# fc_standin FILE — a stand-in frontend: a shell script that speaks the
# protocol to the core as omb-tui does (a spool holding only its header,
# the request on fd 3, the session's values passed through unchanged), and
# does what $T/plan says, one step a line:
#   hello | snapshot SCOPE    a request, waited for
#   late SCOPE                a snapshot whose core it leaves running
#   killed SCOPE              a snapshot whose core it kills (SIGKILL) unanswered
#   say TEXT                  TEXT on stderr
#   env                       its environment into $T/standin-env
#   keep                      a copy of every spool so far into $T/kept/
#   note TEXT                 TEXT appended to $T/order.log
#   dangle                    a core identity that is a dangling link
#   touch FILE | sleep N      as the commands
#   idle                      waits until it is killed
#   exit N                    its status (0 when the plan ends without one)
fc_standin() {
  {
    printf '#!/bin/bash\n# A stand-in for omb-tui in the frontend-check-* tests.\nplan=%s/plan out=%s\n' "$T" "$T"
    cat <<'EOF'
dir=$2 n=0 core=""
req() {
  n=$((n + 1))
  (umask 077 && printf 'omb-res 1\n' >"$dir/req-$n.events")
  {
    printf 'omb-req 1\nreq\top=%s\tproto=1\tfrontend=0.1.0\tsession=0123456789abcdef\n' "$1"
    [ -z "${2:-}" ] || printf 'scope\tname=%s\n' "$2"
  } >"$dir/stand-in.req"
  OMB_EVENTS=$dir/req-$n.events "$OMB_HOME/omarchy-bootstrap" core "$1" 3<"$dir/stand-in.req" </dev/null >/dev/null 2>&1 &
  core=$!
}
while read -r step arg; do
  case "$step" in
    hello) req hello && wait "$core" ;;
    snapshot) req snapshot "$arg" && wait "$core" ;;
    late) req snapshot "$arg" ;;
    killed)
      req snapshot "$arg"
      # As soon as its identity is whole (sealed), before it can answer: it
      # still has its source to hash before hello, and hello before result.
      i=0
      while ! grep -q '^seal' "$dir/req-$n.core" 2>/dev/null && [ "$i" -lt 20000 ]; do i=$((i + 1)); done
      kill -KILL "$core"
      wait "$core"
      ;;
    say) echo "$arg" >&2 ;;
    env) env >"$out/standin-env" ;;
    keep) mkdir -p "$out/kept" && cp "$dir"/req-*.events "$out/kept/" ;;
    note) echo "$arg" >>"$out/order.log" ;;
    dangle) ln -s "$dir/gone" "$dir/req-99.core" ;;
    touch) : >"$arg" ;;
    sleep) sleep "$arg" ;;
    idle) while :; do sleep 1; done ;;
    exit) exit "$arg" ;;
  esac
done <"$plan"
exit 0
EOF
  } >"$1"
  chmod 755 "$1"
}

# fc_plan STEP... — the stand-in's plan, one step an argument.
fc_plan() { printf '%s\n' "$@" >"$T/plan"; }

# fc_env [NAME=VALUE...] [-- ARG...] — FC_ENVS: the hermetic environment
# (FC_PATH, FC_TERM: TERM, empty for none) and NAME=VALUE; FC_ARGS the
# arguments after --.
fc_env() {
  FC_ENVS=("PATH=${FC_PATH:-$T/shim:/usr/bin:/bin:/usr/sbin:/sbin}" "HOME=$T/home" "XDG_CACHE_HOME=$T/cache"
    "XDG_STATE_HOME=$T/xstate" "TMPDIR=$T/tmp" "LANG=en_US.UTF-8" "CURL_CA_BUNDLE=$T/pki/ca.pem")
  [ -n "${FC_TERM-xterm-256color}" ] && FC_ENVS+=("TERM=${FC_TERM-xterm-256color}")
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    FC_ENVS+=("$1")
    shift
  done
  [ "${1:-}" = -- ] && shift
  FC_ARGS=("$@")
}

# fc_direct [NAME=VALUE...] [-- ARG...] — the same command with no terminal:
# stdin /dev/null, stdout and stderr into a file. FC_RC, FC_TEXT.
fc_direct() {
  fc_env "$@"
  env -i "${FC_ENVS[@]}" "$T_BASH" "$TOOL/omarchy-bootstrap" frontend-check ${FC_ARGS[@]+"${FC_ARGS[@]}"} </dev/null >"$T/direct.out" 2>&1
  FC_RC=$?
  FC_TEXT=$(fc_text <"$T/direct.out" | tr -s " ")
}

# fc_run [NAME=VALUE...] [-- ARG...] — `./omarchy-bootstrap frontend-check
# ARG...` in the copy, in a new terminal, with the hermetic environment and
# NAME=VALUE. The keys typed are FC_KEYS (fc_feed); FC_STDOUT=1 sends the
# launcher's stdout to a file instead of the terminal. FC_RC its status; the
# terminal's bytes in $T/pty/out; its settings before and after, as `stty -g`
# prints them in that terminal, in $T/pty/before and $T/pty/after; the
# launcher's PID in $T/pty/pid.
fc_run() {
  local p=$T/pty v
  fc_env "$@"
  rm -rf "$p"
  mkdir -p "$p"
  # The terminal's first shell catches Ctrl-C (so the launcher, its child,
  # starts with the default disposition), sets a size, records the settings,
  # and starts the launcher through a shell that writes its PID and execs.
  {
    printf '%s\n' "trap : INT QUIT" "stty rows 40 cols 120 2>/dev/null" "stty -g >'$p/before'"
    printf "/bin/sh -c 'echo \$\$ >\"\$0/pid\"; exec \"\$@\"' '%s' env -i" "$p"
    for v in "${FC_ENVS[@]}"; do printf " '%s'" "$v"; done
    printf " '%s' '%s' frontend-check" "$T_BASH" "$TOOL/omarchy-bootstrap"
    for v in ${FC_ARGS[@]+"${FC_ARGS[@]}"}; do printf " '%s'" "$v"; done
    [ -n "${FC_STDOUT:-}" ] && printf " >'%s'" "$p/stdout"
    printf '\n%s\n%s\n' "echo \$? >'$p/rc'" "stty -g >'$p/after'"
  } >"$p/inner"
  : >"$p/out"
  fc_feed ${FC_KEYS[@]+"${FC_KEYS[@]}"} | fc_script "$p/out" "$T_BASH" "$p/inner" >/dev/null 2>&1
  FC_RC=$(cat "$p/rc" 2>/dev/null)
  FC_TEXT=$(cat "$p/out" ${FC_STDOUT:+"$p/stdout"} 2>/dev/null | fc_text | tr -s " ")
}

# fc_script OUT CMD... — CMD in a new PTY, its bytes kept in OUT as they come.
fc_script() {
  local out=$1
  shift
  case "$(uname -s)" in
    Darwin) script -q -F "$out" "$@" ;;
    *) script -q -f -e -c "$(printf '%q ' "$@")" "$out" ;;
  esac
}

# fc_feed STEP... — what a person types, each when the terminal shows what
# it answers: wait:TEXT (until the screen holds TEXT, up to 30 s), key:BYTES
# (printf %b), sleep:N, signal:SIG (to the launcher, by its PID and start),
# mark:NAME (fc_mark), file:PATTERN (until a path matches, up to 30 s),
# do:COMMAND (the test's own step, run here).
# Then the input stays open until the run ends; a run still going after
# 120 s is ended by SIGTERM, then SIGKILL, as the launcher it recorded, and
# $T/pty/forced says so (no case counts such a run).
fc_feed() {
  local s i pid start
  for s in "$@"; do
    case "$s" in
      wait:*)
        i=0
        until fc_screen | grep -qF -- "${s#wait:}" || [ "$i" -ge 300 ]; do
          sleep 0.1
          i=$((i + 1))
        done
        ;;
      key:*) printf '%b' "${s#key:}" ;;
      sleep:*) sleep "${s#sleep:}" ;;
      mark:*) printf '%s %s\n' "${s#mark:}" "$(wc -c <"$T/pty/out" | tr -d ' ')" >>"$T/pty/marks" ;;
      file:*)
        i=0
        # shellcheck disable=SC2086 # the pattern is expanded on purpose
        until ls -d ${s#file:} >/dev/null 2>&1 || [ "$i" -ge 300 ]; do
          sleep 0.1
          i=$((i + 1))
        done
        ;;
      do:*) eval "${s#do:}" ;;
      signal:*)
        pid=$(cat "$T/pty/pid" 2>/dev/null)
        t_signal "${s#signal:}" "$pid" "$(t_started "$pid")"
        ;;
    esac
  done
  i=0
  until [ -e "$T/pty/rc" ] || [ "$i" -ge 1200 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if [ ! -e "$T/pty/rc" ]; then
    : >"$T/pty/forced"
    pid=$(cat "$T/pty/pid" 2>/dev/null)
    start=$(t_started "$pid")
    t_signal TERM "$pid" "$start"
    sleep 5
    t_signal KILL "$pid" "$start"
  fi
}

# fc_text — the launcher's own lines from a terminal's bytes (stdin): the
# escape sequences, the carriage returns and the NULs taken out.
FC_ESC=$(printf '\033')
fc_text() { LC_ALL=C sed -e "s/$FC_ESC\\[[0-9;?]*[A-Za-z]//g" -e "s/${FC_ESC}[()][0-9A-Za-z]//g" | LC_ALL=C tr -d '\r\000'; }

# fc_screen — what the terminal of the current run holds now.
fc_screen() { fc_frame ""; }

# fc_frame BYTES — the screen a 40x120 terminal holds after the first BYTES
# bytes of the run's output (all of it when BYTES is empty): one line a row,
# trailing blanks dropped, then "@alt=0|1 cursor=0|1" (the alternate screen
# in use; the cursor shown). A small terminal: cursor addressing and moves,
# erasing, scrolling, the alternate screen (1049) and the cursor (25);
# colour and every other sequence change no cell. A UTF-8 character is one
# cell; the frontend draws no wide one (docs/DECISIONS.md, D15).
fc_frame() {
  head -c "${1:-2147483647}" "$T/pty/out" | LC_ALL=C awk -v R=40 -v C=120 '
    function wipe(r0, c0, r1, c1,   r, c) {
      for (r = r0; r <= r1; r++) for (c = (r == r0 ? c0 : 1); c <= (r == r1 ? c1 : C); c++) s[r, c] = " "
    }
    function lf(   r, c) {
      if (row < R) { row++; return }
      for (r = 1; r < R; r++) for (c = 1; c <= C; c++) s[r, c] = s[r + 1, c]
      wipe(R, 1, R, C)
    }
    function put(ch) {
      if (col > C) { col = 1; lf() }
      s[row, col] = ch
      col++
    }
    function num(p, d) { return p == "" ? d : p + 0 }
    function csi(p, f,   a, n, k, m) {
      if (f == "H" || f == "f") {
        n = split(p, a, ";")
        row = num(a[1], 1); col = num(a[2], 1)
      } else if (f == "J") {
        n = num(p, 0)
        if (n == 0) wipe(row, col, R, C); else if (n == 1) wipe(1, 1, row, col); else wipe(1, 1, R, C)
      } else if (f == "K") {
        n = num(p, 0)
        if (n == 0) wipe(row, col, row, C); else if (n == 1) wipe(row, 1, row, col); else wipe(row, 1, row, C)
      } else if (f == "A") row -= num(p, 1)
      else if (f == "B") row += num(p, 1)
      else if (f == "C") col += num(p, 1)
      else if (f == "D") col -= num(p, 1)
      else if (f == "G") col = num(p, 1)
      else if (f == "d") row = num(p, 1)
      else if ((f == "h" || f == "l") && substr(p, 1, 1) == "?") {
        n = split(substr(p, 2), a, ";")
        for (k = 1; k <= n; k++) {
          m = a[k] + 0
          if (m == 25) cur = (f == "h")
          if (m == 1049 && f == "h" && !alt) {
            for (key in s) main[key] = s[key]
            mr = row; mc = col; alt = 1; wipe(1, 1, R, C)
          }
          if (m == 1049 && f == "l" && alt) {
            for (key in main) s[key] = main[key]
            row = mr; col = mc; alt = 0
          }
        }
      }
      if (row < 1) row = 1; if (row > R) row = R
      if (col < 1) col = 1; if (col > C + 1) col = C + 1
    }
    function text(t,   k, n, ch) {
      n = length(t)
      for (k = 1; k <= n; k++) {
        ch = substr(t, k, 1)
        if (ch == "\r") col = 1
        else if (ch == "\n") lf()
        else if (ch == "\b") { if (col > 1) col-- }
        else if (ch >= "\200" && ch <= "\277") { if (col > 1) s[row, col - 1] = s[row, col - 1] ch }
        else if (ch >= " ") put(ch)
      }
    }
    BEGIN { RS = "\033"; row = 1; col = 1; alt = 0; cur = 1; wipe(1, 1, R, C) }
    {
      rec = $0; i = 1
      if (NR > 1) {
        c1 = substr(rec, 1, 1)
        if (c1 == "[") {
          j = 2
          while (j <= length(rec) && substr(rec, j, 1) !~ /[@-~]/) j++
          csi(substr(rec, 2, j - 2), substr(rec, j, 1))
          i = j + 1
        } else if (c1 == "(" || c1 == ")") i = 3
        else i = 2
      }
      text(substr(rec, i))
    }
    END {
      for (r = 1; r <= R; r++) {
        line = ""
        for (c = 1; c <= C; c++) line = line s[r, c]
        sub(/ +$/, "", line)
        print line
      }
      print "@alt=" alt " cursor=" cur
    }'
}

# fc_mark NAME — the run's output length when NAME was marked (fc_feed's
# mark:NAME), for fc_frame.
fc_mark() { sed -n "s/^$1 //p" "$T/pty/marks" 2>/dev/null | tail -n 1; }

# fc_dashboard FRAME — the frame is the check's dashboard: the four facts
# and "Nothing is available now." on the alternate screen, and nothing of
# the connecting screen. This is the PTY check's rendering evidence; a run
# whose screen never showed it is not counted, whatever it reported.
fc_dashboard() {
  local f=$1 want
  case "$f" in *"@alt=1 "*) ;; *) return 1 ;; esac
  for want in "frontend startup check (frontend-check)" "frontend ${FC_VERSION:-0.1.0} as the lock pins, protocol 1" \
    "read-only, journey scope only, not a dry run" "none in this session" "Nothing is available now."; do
    case "$f" in *"$want"*) ;; *) return 1 ;; esac
  done
  case "$f" in *"Asking the core"*) return 1 ;; esac
  return 0
}

# fc_snap DIR — every entry under DIR with its type and mode, and a file's
# size and checksum: what the effects of a case are judged by.
fc_snap() {
  [ -e "$1" ] || {
    echo "(absent)"
    return 0
  }
  (
    cd "$1" || exit 1
    find . -print | LC_ALL=C sort | while IFS= read -r e; do
      m=$(ls -ld "$e" | awk '{ m = $1; sub(/[@+.]$/, "", m); print m }')
      c=""
      [ -f "$e" ] && [ ! -L "$e" ] && c=" $(cksum <"$e")"
      printf '%s %s%s\n' "$e" "$m" "$c"
    done
  )
}
