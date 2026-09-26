#!/usr/bin/env bash
# The frontend's build-input identity and closure (docs/FRONTEND.md → Four
# identities, Building, Compatibility): one definition, used by CI, the
# release workflow and tests/test-frontend-inputs.sh.
#
#   frontend-inputs.sh digest [COMMIT]     inputs_digest, from Git's objects (never the working tree)
#   frontend-inputs.sh listing [COMMIT]    the canonical listing it is the SHA-256 of
#   frontend-inputs.sh clean               no untracked or ignored file under frontend/
#   frontend-inputs.sh closure DEPDIR      every path rustc read is a tracked input, the registry or the sysroot
#   frontend-inputs.sh metadata            no build script of its own; every package here or from crates.io
#   frontend-inputs.sh config [WORKFLOW]   no Cargo configuration elsewhere; no *FLAGS in the release workflow
#   frontend-inputs.sh lock [COMMIT]       the commit's inputs_digest against release/frontend.lock's
#   frontend-inputs.sh compat-linux FILE   the Linux artifact's contract
#   frontend-inputs.sh compat-macos FILE   the macOS artifact's contract
#   frontend-inputs.sh lock-head VERSION [COMMIT]     the lock's header and frontend line
#   frontend-inputs.sh artifact-line TARGET FILE URL  one artifact's lock line, read from the binary
#
# A release's lock is lock-head, then one artifact-line per target, then
# `seal TAB sha256=` the SHA-256 of everything before it.
#
# Run from the repository's root (or with -C DIR first). Every check prints
# what it found and exits non-zero on the first thing that breaks the rule.
set -u
export LC_ALL=C

if [ "${1:-}" = -C ]; then
  cd "$2" || exit 2
  shift 2
fi

die() {
  printf 'frontend-inputs: %s\n' "$*" >&2
  exit 1
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-64; else sha256sum | cut -c1-64; fi
}

# listing COMMIT — `omb-frontend-inputs 1`, then one line per tracked path
# under frontend/ at COMMIT: path TAB mode TAB sha256 of its bytes, in byte
# order of the path. A tracked symbolic link or submodule is an error.
listing() {
  local commit=${1:-HEAD} mode type obj path sum out
  git rev-parse --verify --quiet "$commit^{commit}" >/dev/null || die "not a commit: $commit"
  out=$(git ls-tree -r --full-tree "$commit" -- frontend/) || die "git ls-tree failed"
  [ -n "$out" ] || die "nothing is tracked under frontend/ at $commit"
  printf 'omb-frontend-inputs 1\n'
  printf '%s\n' "$out" | sort -t '	' -k2,2 | while IFS='	' read -r meta path; do
    read -r mode type obj <<EOF
$meta
EOF
    case "$mode:$type" in
      100644:blob | 100755:blob) ;;
      120000:*) die "a tracked symbolic link under frontend/: $path" ;;
      *) die "not a plain file under frontend/: $path ($mode $type)" ;;
    esac
    [ "$(git cat-file -t "$obj" 2>/dev/null)" = blob ] || die "cannot read $path at $commit"
    sum=$(git cat-file blob "$obj" | sha256) || die "cannot read $path at $commit"
    printf '%s\t%s\t%s\n' "$path" "$mode" "$sum"
  done
}

cmd=${1:-}
shift
case "$cmd" in
  listing)
    listing "${1:-HEAD}"
    ;;
  digest)
    # The listing is built in full first: a die inside it must not become a
    # digest of a partial listing.
    l=$(listing "${1:-HEAD}") || exit 1
    printf '%s\n' "$l" | sha256
    ;;
  clean)
    s=$(git status --porcelain --ignored -- frontend) || die "git status failed"
    if [ -n "$s" ]; then
      printf '%s\n' "$s" >&2
      die "untracked, ignored or changed files under frontend/: the build must start from the commit alone"
    fi
    echo "frontend/ is exactly the commit"
    ;;
  closure)
    depdir=${1:?closure DEPDIR, the target folder deps/ holding the *.d files}
    sysroot=$(cd frontend && rustc --print sysroot) || die "no rustc"
    registry="${CARGO_HOME:-$HOME/.cargo}/registry/src"
    root=$(pwd -P)
    tracked=$(git ls-files -- frontend) || die "git ls-files failed"
    found=0
    for d in "$depdir"/omb_tui-*.d "$depdir"/omb_tui*.d "$depdir"/omb-tui*.d; do
      [ -f "$d" ] || continue
      found=1
      # A dependency file: "target: dep dep ...", one rule per line; spaces
      # in paths are escaped with a backslash; lines from '#' on are rustc's
      # notes (env-dep, checksum), not files. Each rule's target (an output)
      # is dropped; everything after it is a file rustc read.
      grep -v '^#' "$d" | sed -E -e 's/\\ /@SP@/g' -e 's/^[^ ]*:( |$)//' | tr ' ' '\n' | sed -e 's/@SP@/ /g' | grep -v '^$' | while IFS= read -r p; do
        # rustc names the crate's own files relative to the package
        # (frontend/): resolve them, `..` included, before judging.
        case "$p" in
          /*) ;;
          *)
            dir=$(cd "frontend/$(dirname "$p")" 2>/dev/null && pwd -P) || die "rustc read a file that is gone: $p"
            p="$dir/$(basename "$p")"
            ;;
        esac
        case "$p" in
          "$registry"/* | "$sysroot"/*) continue ;;
          "$root"/frontend/*)
            rel=${p#"$root"/}
            printf '%s\n' "$tracked" | grep -qxF -- "$rel" || die "rustc read $rel, which Git does not track"
            ;;
          *) die "rustc read a file outside the closure: $p" ;;
        esac
      done || exit 1
    done
    [ "$found" = 1 ] || die "no dependency files for the frontend in $depdir"
    echo "every file rustc read is a tracked input, a registry crate or the toolchain"
    ;;
  metadata)
    command -v jq >/dev/null 2>&1 || die "jq is needed to read cargo metadata"
    m=$(cd frontend && cargo metadata --format-version 1 --locked --offline) || die "cargo metadata --locked failed"
    root=$(pwd -P)
    # The frontend's own packages: no build script.
    b=$(printf '%s' "$m" | jq -r '.packages[] | select(.source == null) | .targets[] | select(.kind[] == "custom-build") | .src_path')
    [ -z "$b" ] || die "a build script of the frontend's own: $b"
    # Every package from crates.io, or a path package under frontend/.
    printf '%s' "$m" | jq -r '.packages[] | [.name, (.source // "path"), .manifest_path] | @tsv' | while IFS='	' read -r name src manifest; do
      case "$src" in
        registry+https://github.com/rust-lang/crates.io-index) ;;
        path)
          case "$manifest" in "$root"/frontend/*) ;; *) die "a path package outside frontend/: $name ($manifest)" ;; esac
          ;;
        *) die "a package from outside crates.io: $name ($src)" ;;
      esac
    done || exit 1
    grep -q '^source = "git+' frontend/Cargo.lock && die "a git source in Cargo.lock"
    grep -Eq '^\[(patch|replace)' frontend/Cargo.toml && die "a [patch] or [replace] section in Cargo.toml"
    echo "no build script of its own; every package from crates.io or under frontend/"
    ;;
  config)
    wf=${1:-.github/workflows/release.yml}
    other=$(git ls-files | grep -E '(^|/)\.cargo/' | grep -v '^frontend/\.cargo/config\.toml$')
    [ -z "$other" ] || die "Cargo configuration outside frontend/.cargo/config.toml: $other"
    if [ -f "$wf" ]; then
      # The names the document lists, and the ones that do the same under
      # another name: a target's own flags, linker or runner, a compiler
      # wrapper, and configuration passed on Cargo's command line.
      bad=$(grep -nE '(^|[^A-Z_])(RUSTFLAGS|CARGO_ENCODED_RUSTFLAGS|RUSTC_WRAPPER|RUSTC_WORKSPACE_WRAPPER|CARGO_BUILD_[A-Z_]*|CARGO_PROFILE_[A-Z_]*|CARGO_TARGET_[A-Z0-9_]*_(RUSTFLAGS|LINKER|RUNNER))[[:space:]]*[:=]|cargo[^#]*[[:space:]]--config' "$wf")
      [ -z "$bad" ] || die "the release workflow sets build configuration: $bad"
      grep -q 'test-hooks' "$wf" && die "the release workflow names the test-hooks feature"
    fi
    echo "the only Cargo configuration is frontend/.cargo/config.toml"
    ;;
  lock)
    commit=${1:-HEAD}
    d=$("$0" digest "$commit") || exit 1
    if [ ! -f release/frontend.lock ]; then
      printf 'no release lock: the frontend at %s is unreleased (inputs_digest %s)\n' "$commit" "$d"
      exit 3
    fi
    l=$(sed -n 's/^frontend\t.*\tinputs_digest=\([0-9a-f]\{64\}\)\t.*/\1/p' release/frontend.lock)
    [ -n "$l" ] || die "release/frontend.lock names no inputs_digest"
    if [ "$l" != "$d" ]; then
      die "the frontend's inputs changed since the release: the commit's inputs_digest is $d, the lock's $l — a new release is needed"
    fi
    # The lock's protocol is the core's (docs/TESTING.md → CI), as the
    # launcher also checks before starting it.
    p=$(sed -n 's/^frontend\t.*\tproto=\([0-9]*\)\t.*/\1/p' release/frontend.lock)
    c=$(sed -n 's/^REC_PROTO=\([0-9]*\)$/\1/p' lib/records.sh 2>/dev/null)
    [ -n "$c" ] || die "the core's protocol cannot be read from lib/records.sh"
    [ "$p" = "$c" ] || die "the lock's frontend speaks protocol ${p:-none}, the core $c"
    echo "inputs_digest $d matches the lock; protocol $p, the core's"
    ;;
  compat-linux)
    f=${1:?compat-linux FILE}
    h=$(readelf -h "$f") || die "not an ELF file: $f"
    printf '%s' "$h" | grep -q 'Class:.*ELF64' || die "not 64-bit"
    printf '%s' "$h" | grep -q 'Machine:.*AArch64' || die "not AArch64"
    interp=$(readelf -l "$f" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
    [ "$interp" = /lib/ld-linux-aarch64.so.1 ] || die "interpreter is $interp"
    needed=$(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
    for n in $needed; do
      case "$n" in libc.so.6 | libm.so.6 | libgcc_s.so.1 | ld-linux-aarch64.so.1) ;; *) die "needs $n" ;; esac
    done
    top=$(objdump -T "$f" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    [ -n "$top" ] || die "no GLIBC_ symbol versions read"
    awk -v v="$top" 'BEGIN { split(v, a, "."); exit !(a[1] < 2 || (a[1] == 2 && a[2] <= 39)) }' || die "needs GLIBC_$top, above 2.39"
    # The alignment is the last column of each LOAD line (hex); read by the
    # shell, since mawk (Ubuntu's awk) has no strtonum.
    loads=$(readelf -lW "$f" | awk '$1 == "LOAD" { print $NF }')
    [ -n "$loads" ] || die "no LOAD segments read"
    for a in $loads; do
      case "$a" in 0x[0-9a-fA-F]*) ;; *) die "a LOAD alignment that is not hex: $a" ;; esac
      [ $((a)) -ge 16384 ] || die "a LOAD segment aligned below 0x4000 ($a)"
    done
    if grep -Eq '^name = "(tikv-)?jemalloc|^name = "mimalloc|^name = "snmalloc' frontend/Cargo.lock; then die "an allocator crate in Cargo.lock"; fi
    printf 'linux artifact: interpreter %s; needs %s; GLIBC_%s at most; LOAD aligned >= 0x4000; no allocator crate\n' "$interp" "$(printf '%s' "$needed" | tr '\n' ' ')" "$top"
    ;;
  compat-macos)
    f=${1:?compat-macos FILE}
    archs=$(lipo -archs "$f") || die "not a Mach-O file: $f"
    [ "$archs" = arm64 ] || die "architectures: $archs"
    minos=$(vtool -show-build "$f" | awk '$1 == "minos" { print $2 }')
    [ "$minos" = 13.5 ] || die "minos $minos, not 13.5"
    codesign -v "$f" || die "the signature does not verify"
    echo "macos artifact: arm64 only; minos 13.5; codesign -v passes"
    ;;
  lock-head)
    version=${1:?lock-head VERSION [COMMIT]}
    commit=$(git rev-parse --verify "${2:-HEAD}^{commit}") || die "not a commit: ${2:-HEAD}"
    d=$("$0" digest "$commit") || exit 1
    proto=$(git show "$commit:lib/records.sh" | sed -n 's/^REC_PROTO=\([0-9]*\)$/\1/p')
    rust=$(git show "$commit:frontend/rust-toolchain.toml" | sed -n 's/^channel = "\(.*\)"$/\1/p')
    if [ -z "$proto" ] || [ -z "$rust" ]; then die "the protocol or the toolchain cannot be read at $commit"; fi
    printf 'omb-frontend-lock 1\nfrontend\tversion=%s\tproto=%s\tsource_commit=%s\tinputs_digest=%s\trust=%s\n' "$version" "$proto" "$commit" "$d" "$rust"
    ;;
  artifact-line)
    target=${1:?artifact-line TARGET FILE URL} f=${2:?artifact-line TARGET FILE URL} url=${3:?artifact-line TARGET FILE URL}
    size=$(wc -c <"$f" | tr -d ' ') || die "cannot read $f"
    sum=$(sha256 <"$f")
    case "$target" in
      aarch64-apple-darwin)
        minos=$(vtool -show-build "$f" | awk '$1 == "minos" { print $2 }')
        [ -n "$minos" ] || die "no minos in $f"
        printf 'artifact\ttarget=%s\turl=%s\tsize=%s\tsha256=%s\tminos=%s\tglibc_max=\tinterp=\talign_min=\n' "$target" "$url" "$size" "$sum" "$minos"
        ;;
      aarch64-unknown-linux-gnu)
        interp=$(readelf -l "$f" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
        top=$(objdump -T "$f" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
        align=$(readelf -lW "$f" | awk '$1 == "LOAD" { print $NF }')
        if [ -z "$interp" ] || [ -z "$top" ] || [ -z "$align" ]; then die "the ELF facts of $f cannot be read"; fi
        min=""
        for a in $align; do
          if [ -z "$min" ] || [ $((a)) -lt "$min" ]; then min=$((a)); fi
        done
        printf 'artifact\ttarget=%s\turl=%s\tsize=%s\tsha256=%s\tminos=\tglibc_max=%s\tinterp=%s' "$target" "$url" "$size" "$sum" "$top" "$interp"
        for n in $(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do printf '\tneeded=%s' "$n"; done
        printf '\talign_min=%s\n' "$min"
        ;;
      *) die "no lock line is defined for $target" ;;
    esac
    ;;
  *)
    sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
    exit 2
    ;;
esac
