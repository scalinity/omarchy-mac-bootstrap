#!/usr/bin/env bash
# GNU Bash 5.3.15 for CI's Linux target-shell lane (docs/TESTING.md → *CI*),
# from exactly the files tests/bash-5.3.15.sha256 pins.
#
#   tests/ci-bash.sh sources DIR         every pinned file in DIR, each held to its digest
#   tests/ci-bash.sh build DIR PREFIX    sources, then extract, patch, build, install, check
#
# An origin is transport only: what it serves is used only when its SHA-256
# is the pinned one, and the whole pinned set is checked strictly again
# before anything is extracted. Files already in DIR (a restored cache) are
# held to the same digests; a missing, short or different one is fetched
# again. Origins, in order: GNU's mirror redirector, GNU's own server, then
# the kernel.org GNU mirror; one that cannot be reached is not tried again.
# Exit 75: no origin delivered a pinned file (external infrastructure).

PIN=${OMB_BASH_PIN:-$(cd "$(dirname "$0")" && pwd -P)/bash-5.3.15.sha256}
ORIGINS=${OMB_BASH_ORIGINS:-https://ftpmirror.gnu.org/bash https://ftp.gnu.org/gnu/bash https://mirrors.kernel.org/gnu/bash}
WANT='5.3.15(1)-release'

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# Where a pinned file lives under an origin's bash/ directory.
remote() {
  case $1 in
    bash53-*) printf 'bash-5.3-patches/%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

sources() {
  local dir=$1 dead=' ' short=0 sum name f o rc got
  mkdir -p "$dir" || return 1
  rm -f "$dir"/*.part
  while read -r sum name; do
    f=$dir/$name
    if [ -f "$f" ]; then
      if [ "$(sha256 "$f" | awk '{print $1}')" = "$sum" ]; then
        echo "cached: $name"
        continue
      fi
      echo "cached $name does not match its pinned digest; fetching it again"
      rm -f "$f"
    fi
    got=''
    for o in $ORIGINS; do
      case $dead in *" $o "*) continue ;; esac
      curl -fsSL --retry 2 --connect-timeout 20 --max-time 600 -o "$f.part" "$o/$(remote "$name")"
      rc=$?
      if [ "$rc" != 0 ]; then
        rm -f "$f.part"
        echo "$o: $name not fetched (curl exit $rc)"
        case $rc in
          6 | 7 | 28 | 35)
            dead="$dead$o "
            echo "  $o cannot be reached; not tried again"
            ;;
        esac
        continue
      fi
      if [ "$(sha256 "$f.part" | awk '{print $1}')" != "$sum" ]; then
        rm -f "$f.part"
        echo "$o served $name with another digest; not used"
        continue
      fi
      mv "$f.part" "$f" || return 1
      echo "fetched $name from $o"
      got=1
      break
    done
    if [ -z "$got" ]; then
      echo "source acquisition exhausted: no origin delivered $name with its pinned digest"
      short=1
    fi
  done < <(grep -v '^#' "$PIN")
  [ "$short" = 0 ] || return 75
  # The pinned digests decide, as they always have: every file, strictly.
  (cd "$dir" && grep -v '^#' "$PIN" | sha256 --check --strict -)
}

build() {
  local src=$1 prefix=$2 work patches p b
  sources "$src" || return $?
  work=$(mktemp -d) || return 1
  tar -xzf "$src/bash-5.3.tar.gz" -C "$work" || return 1
  cd "$work/bash-5.3" || return 1
  patches=$(grep -v '^#' "$PIN" | awk '$2 ~ /^bash53-/ { print $2 }')
  for p in $patches; do
    patch -p0 -s <"$src/$p" || return 1
  done
  ./configure --prefix="$prefix" >/dev/null || return 1
  make -j"$(nproc 2>/dev/null || echo 2)" >/dev/null || return 1
  make install >/dev/null || return 1
  b=$prefix/bin/bash
  # shellcheck disable=SC2016 # expanded by the bash just built
  if [ "$("$b" -c 'echo "$BASH_VERSION"')" != "$WANT" ]; then
    echo "$b is not GNU Bash $WANT"
    return 1
  fi
  echo "GNU Bash $WANT: $b"
}

case ${1:-} in
  sources) sources "$2" ;;
  build) build "$2" "$3" ;;
  *)
    sed -n '5,6p' "$0" | sed 's/^# //'
    exit 2
    ;;
esac
