#!/usr/bin/env bash
# The frontend's build-input identity and closure (docs/FRONTEND.md → Four
# identities, Building, Compatibility): one definition, used by CI, the
# release workflow and tests/test-frontend-inputs.sh.
#
#   frontend-inputs.sh digest [COMMIT]     inputs_digest, from Git's objects (never the working tree)
#   frontend-inputs.sh listing [COMMIT]    the canonical listing it is the SHA-256 of
#   frontend-inputs.sh clean               no untracked or ignored file under frontend/
#   frontend-inputs.sh closure DEPDIR BUILD  every target of the frontend's own the build compiled (BUILD: its
#                                          --message-format=json output) read only tracked inputs, the registry,
#                                          the sysroot and Cargo.toml's package values
#   frontend-inputs.sh metadata            no build script of its own; every package here or from crates.io
#   frontend-inputs.sh config [WORKFLOW]   no Cargo configuration elsewhere; no *FLAGS in the release workflow
#   frontend-inputs.sh lock [COMMIT]       the commit's inputs_digest against release/frontend.lock's
#   frontend-inputs.sh candidate VERSION [COMMIT]   an unreleased next version against the pinned release
#                                          (the release's intactness and the difference, never equality)
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

# The names Cargo 1.88.0 sets from a package's Cargo.toml when it runs
# rustc: fill_env in src/cargo/core/compiler/compilation.rs (the version,
# its parts, the name) and metadata_envs! in src/cargo/core/manifest.rs
# (the rest); the same fourteen the Cargo book's environment-variables
# reference lists at rust-1.88.0. No other name, CARGO_PKG_ or not, is a
# value the tracked inputs decide.
PKG_ENV="CARGO_PKG_VERSION CARGO_PKG_VERSION_MAJOR CARGO_PKG_VERSION_MINOR CARGO_PKG_VERSION_PATCH
CARGO_PKG_VERSION_PRE CARGO_PKG_NAME CARGO_PKG_AUTHORS CARGO_PKG_DESCRIPTION CARGO_PKG_HOMEPAGE
CARGO_PKG_REPOSITORY CARGO_PKG_LICENSE CARGO_PKG_LICENSE_FILE CARGO_PKG_RUST_VERSION CARGO_PKG_README"

# dep_hash CRATE NAME — the hash in NAME when NAME is one of CRATE's outputs
# in deps/: CRATE-HASH[.exe] (a binary) or libCRATE-HASH.EXT; nothing else.
dep_hash() {
  case "$2" in *.d) return 0 ;; esac
  printf '%s\n' "$2" | sed -n -E "s/^(lib)?$1-([0-9a-f]{16})(\\.[A-Za-z0-9]+)?\$/\\2/p"
}

# real PATH — PATH with its folder's links resolved; nothing when it is gone.
real() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }

# depfile_ok FILE WHAT — FILE, rustc's dependency file for WHAT, names only
# tracked inputs, the registry and the sysroot, and reads no build
# environment but Cargo.toml's package values.
depfile_ok() {
  local d=$1 what=$2
  # rustc's notes: `# env-dep:NAME[=VALUE]` for every env!() and
  # option_env!() the crate read at compile time, set or not. Such a value
  # is an input the listing does not hold unless Cargo set it from the
  # tracked Cargo.toml (PKG_ENV).
  grep '^# env-dep:' "$d" | while IFS= read -r e; do
    name=${e#\# env-dep:}
    name=${name%%=*}
    case " $(printf '%s' "$PKG_ENV" | tr '\n' ' ') " in
      *" $name "*) ;;
      *) die "$what reads the build environment's $name at compile time, an input the listing does not hold" ;;
    esac
  done || exit 1
  # A dependency file: "target: dep dep ...", one rule per line; spaces
  # in paths are escaped with a backslash; lines from '#' on are rustc's
  # notes (above), not files. Each rule's target (an output) is dropped;
  # everything after it is a file rustc read.
  grep -v '^#' "$d" | sed -E -e 's/\\ /@SP@/g' -e 's/^[^ ]*:( |$)//' | tr ' ' '\n' | sed -e 's/@SP@/ /g' | grep -v '^$' | while IFS= read -r p; do
    # Cargo runs rustc in the workspace folder, frontend/, and names a
    # local crate's files relative to it: resolve them, `..` included,
    # before judging.
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
      *) die "rustc read a file outside the closure: $p ($what)" ;;
    esac
  done || exit 1
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
    depdir=${1:?closure DEPDIR BUILD — deps/ holding the *.d files, and the messages of the build that wrote it}
    build=${2:?closure DEPDIR BUILD — the cargo --message-format=json output of that build}
    command -v jq >/dev/null 2>&1 || die "jq is needed to read cargo metadata"
    sysroot=$(cd frontend && rustc --print sysroot) || die "no rustc"
    registry="${CARGO_HOME:-$HOME/.cargo}/registry/src"
    root=$(pwd -P)
    tracked=$(git ls-files -- frontend) || die "git ls-files failed"
    dd=$(cd "$depdir" 2>/dev/null && pwd -P) || die "no folder $depdir"
    out=$(dirname "$dd")
    jq -e -s 'any(.[]; .reason == "build-finished" and .success == true)' "$build" >/dev/null ||
      die "$build is not the messages of a whole, successful build"
    # The frontend's own packages: each package cargo metadata shows under
    # frontend/ (without --no-deps: a path dependency is not a workspace
    # member, and --no-deps lists members only).
    m=$(cd frontend && cargo metadata --format-version 1 --locked --offline) || die "cargo metadata --locked failed"
    pk=$(printf '%s' "$m" | jq -c '[.packages[] | select(.source == null) | {key: .id, value: "\(.name)@\(.version)"}] | from_entries') ||
      die "cargo metadata cannot be read"
    # Every target of theirs the build compiled — its kind and name, its
    # package, its root file, then (F) each file the build reported for it.
    # Nothing is merged: two targets whose crate names are spelled alike (a
    # library omb_tui, a binary omb-tui) each need evidence of their own.
    arts=$(jq -r -s --argjson pk "$pk" '[.[] | select(.reason == "compiler-artifact") | select($pk[.package_id] != null)]
      | to_entries[] | .key as $i | .value
      | "T\t\($i)\t\(.target.kind | join(","))\t\(.target.name)\t\($pk[.package_id])\t\(.target.src_path)", (.filenames[] | "F\t\($i)\t\(.)")' "$build") ||
      die "$build cannot be read"
    printf '%s\n' "$arts" | grep -q '^T	' || die "the build compiled no target of the frontend's own packages"
    n=0 used=""
    while IFS='	' read -r tag i kind name pkg src; do
      [ "$tag" = T ] || continue
      what="$kind $name of $pkg"
      case ",$kind," in
        *,lib,* | *,rlib,* | *,dylib,* | *,cdylib,* | *,staticlib,* | *,proc-macro,* | *,bin,*) ;;
        *) die "the build compiled $what, a kind of target the closure does not hold" ;;
      esac
      crate=$(printf '%s' "$name" | tr - _)
      # Its evidence: rustc's dependency file for the output the build
      # reported. An output in deps/ carries the hash its dependency file is
      # named with; one Cargo copied out of deps/ (the binary) is the deps/
      # output with the same bytes.
      hashes=""
      files=$(printf '%s\n' "$arts" | awk -F'\t' -v i="$i" '$1 == "F" && $2 == i { print $3 }')
      while IFS= read -r f; do
        [ -f "$f" ] || continue
        fd=$(cd "$(dirname "$f")" 2>/dev/null && pwd -P) || die "the build's output $f is gone"
        if [ "$fd" = "$dd" ]; then
          h=$(dep_hash "$crate" "$(basename "$f")")
          [ -n "$h" ] || die "$f is not an output of $what"
          hashes="$hashes $h"
        elif [ "$fd" = "$out" ]; then
          for c in "$dd/$crate"-* "$dd/lib$crate"-*; do
            [ -f "$c" ] || continue
            h=$(dep_hash "$crate" "$(basename "$c")")
            if [ -n "$h" ] && cmp -s "$f" "$c"; then hashes="$hashes $h"; fi
          done
        else
          die "$f is not beside $dd: these messages are not of the build that wrote it"
        fi
      done <<EOF
$files
EOF
      # shellcheck disable=SC2086 # the hashes, one word each
      hashes=$(printf '%s\n' $hashes | awk 'NF && !seen[$0]++')
      [ -n "$hashes" ] || die "no output of $what in $dd: nothing to read its evidence from"
      [ "$(printf '%s\n' "$hashes" | wc -l | tr -d ' ')" = 1 ] ||
        die "the outputs of $what in $dd are more than one compilation's: build into a target folder of its own"
      d=$dd/$crate-$hashes.d
      [ -f "$d" ] || die "no dependency file for $what: $d"
      # The file is that compilation's: a rule for that output, and first
      # the target's own root file.
      grep -v '^#' "$d" | sed -E -e 's/\\ /@SP@/g' -e 's/:( .*)?$//' | sed -e 's/@SP@/ /g' | awk -F/ '{ print $NF }' |
        grep -vxF "$crate-$hashes.d" | grep -qxE "(lib)?$crate-$hashes(\\.[A-Za-z0-9]+)?" || die "$d names no output of $what"
      first=$(sed -n 1p "$d" | sed -E -e 's/\\ /@SP@/g' -e 's/^[^ ]*:( |$)//' | awk '{ print $1 }' | sed -e 's/@SP@/ /g')
      case "$first" in /*) ;; *) first=frontend/$first ;; esac
      if [ -z "$first" ] || [ "$(real "$first")" != "$(real "$src")" ]; then
        die "$d is not the compilation of $what: it starts at ${first:-nothing}, the target at $src"
      fi
      case " $used " in *" $d "*) die "$d is the evidence of two targets" ;; esac
      used="$used $d"
      depfile_ok "$d" "$what"
      n=$((n + 1))
      printf '%s: %s\n' "$what" "${d#"$out"/}"
    done <<EOF
$arts
EOF
    echo "each of the $n targets of the frontend's own the build compiled has its own dependency file, and read only tracked inputs, a registry crate or the toolchain; no build environment but Cargo.toml's package values"
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
  candidate)
    # An unreleased frontend that means to be the next release (docs/DECISIONS.md
    # → D49). It is not the pinned release and never says it is: `lock` stays the
    # exact-release check and fails on any difference. This passes only when the
    # lock is well formed and its release intact, VERSION is newer than the
    # release's and is the commit's own, the commit's inputs differ from the
    # release's, and the release's protocol is the core's. The release workflow
    # never runs it.
    want=${1:?candidate VERSION [COMMIT]}
    commit=$(git rev-parse --verify --quiet "${2:-HEAD}^{commit}") || die "not a commit: ${2:-HEAD}"
    tab=$(printf '\t')
    semver='^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'
    newer() { awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, "."); for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 } exit 1 }'; }
    printf '%s\n' "$want" | grep -Eq "$semver" || die "the candidate version is not MAJOR.MINOR.PATCH: $want"
    lf=$(mktemp "${TMPDIR:-/tmp}/omb-lock.XXXXXX") || die "no temporary file"
    trap 'rm -f "$lf"' EXIT
    git cat-file -e "$commit:release/frontend.lock" 2>/dev/null || die "no release/frontend.lock at $commit: there is no pinned release for a candidate to differ from"
    git show "$commit:release/frontend.lock" >"$lf" || die "cannot read the lock at $commit"
    # The lock, as the launcher reads it: its header, one frontend line, at
    # least one artifact line, and a seal that is the SHA-256 of every byte
    # before it.
    [ "$(sed -n 1p "$lf")" = "omb-frontend-lock 1" ] || die "the lock's first line is not 'omb-frontend-lock 1'"
    [ "$(tail -c 1 "$lf" | od -An -c | tr -d ' ')" = '\n' ] || die "the lock does not end with a newline"
    stray=$(sed '1d;$d' "$lf" | grep -Ev "^(frontend|artifact)${tab}" || true)
    [ -z "$stray" ] || die "the lock holds a line that is neither frontend nor artifact: $(printf '%s\n' "$stray" | sed -n 1p)"
    [ "$(grep -c "^frontend${tab}" "$lf")" = 1 ] || die "the lock does not hold exactly one frontend line"
    [ "$(grep -c "^artifact${tab}" "$lf")" -ge 1 ] || die "the lock holds no artifact line"
    last=$(tail -n 1 "$lf")
    printf '%s\n' "$last" | grep -Eq "^seal${tab}sha256=[0-9a-f]{64}\$" || die "the lock's last line is not a seal"
    [ "$(grep -c '^seal' "$lf")" = 1 ] || die "the lock holds more than one seal"
    sealed=$(printf '%s\n' "$last" | sed "s/^seal${tab}sha256=//")
    [ "$(sed '$d' "$lf" | sha256)" = "$sealed" ] || die "the lock's seal does not match its bytes"
    fl=$(grep "^frontend${tab}" "$lf")
    printf '%s\n' "$fl" | grep -Eq "^frontend${tab}version=[0-9.]+${tab}proto=[0-9]+${tab}source_commit=[0-9a-f]{40}${tab}inputs_digest=[0-9a-f]{64}${tab}rust=[^${tab}]+\$" || die "the lock's frontend line is malformed"
    field() { printf '%s\n' "$fl" | awk -F'\t' -v k="$1" '{ for (i = 2; i <= NF; i++) if (index($i, k "=") == 1) { print substr($i, length(k) + 2); exit } }'; }
    lv=$(field version) lp=$(field proto) sc=$(field source_commit) ld=$(field inputs_digest)
    printf '%s\n' "$lv" | grep -Eq "$semver" || die "the lock's version is not MAJOR.MINOR.PATCH: $lv"
    # The pinned release stays intact: its source commit is here, holds the
    # inputs the lock names, and the release's tag names it. A checkout that
    # lacks the commit or the tag cannot show this, and is refused.
    git rev-parse --verify --quiet "$sc^{commit}" >/dev/null || die "the release's source commit $sc is not in this checkout: fetch the full history"
    rd=$("$0" digest "$sc") || exit 1
    [ "$rd" = "$ld" ] || die "the lock's inputs_digest $ld is not what its source commit $sc holds ($rd): the pinned release is not intact"
    tc=$(git rev-parse --verify --quiet "refs/tags/frontend-v$lv^{commit}" || true)
    [ -n "$tc" ] || die "the release tag frontend-v$lv is not in this checkout: fetch the tags"
    [ "$tc" = "$sc" ] || die "the tag frontend-v$lv names $tc, not the release's source commit $sc"
    # The candidate: newer, its own, different.
    newer "$want" "$lv" || die "the candidate $want is not newer than the pinned release $lv"
    cv=$(git show "$commit:frontend/Cargo.toml" | sed -n 's/^version = "\(.*\)"$/\1/p' | sed -n 1p)
    [ "$cv" = "$want" ] || die "frontend/Cargo.toml names ${cv:-no version} at $commit, not the candidate $want"
    cl=$(git show "$commit:frontend/Cargo.lock" | awk '/^name = "omb-tui"$/ { getline; print; exit }' | sed -n 's/^version = "\(.*\)"$/\1/p')
    [ "$cl" = "$want" ] || die "frontend/Cargo.lock names ${cl:-no version} for omb-tui at $commit, not the candidate $want"
    d=$("$0" digest "$commit") || exit 1
    [ "$d" != "$ld" ] || die "the commit's inputs_digest is the release's ($d): this is the released frontend, and the lock check is the one that applies"
    # The release's protocol against the core's (the candidate's own is held by
    # proto-diff-*).
    cp=$(git show "$commit:lib/records.sh" | sed -n 's/^REC_PROTO=\([0-9]*\)$/\1/p')
    [ -n "$cp" ] || die "the core's protocol cannot be read at $commit"
    [ "$lp" = "$cp" ] || die "the lock's frontend speaks protocol $lp, the core $cp"
    echo "candidate $want at $commit is UNRELEASED: inputs_digest $d differs from the pinned release $lv ($ld, source $sc, tag frontend-v$lv), which the lock still pins and which is intact; protocol $lp is the core's. No release equality is claimed."
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
