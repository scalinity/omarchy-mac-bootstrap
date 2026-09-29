#!/usr/bin/env bash
# The frontend's source-input identity and build closure (docs/FRONTEND.md →
# Four identities; docs/TESTING.md → frontend-input-*, frontend-lock-not-input),
# each rule broken on purpose in a throwaway Git repository and shown refused
# by tests/frontend-inputs.sh, the one definition CI and the release use.
# The repository under test holds a tiny crate named like the frontend, so a
# real `cargo build` produces the dependency files the closure is read from.
# shellcheck disable=SC2015,SC2016 # ok/fail always return 0; literal $ in Rust
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
echo "test-frontend-inputs"
T=$(t_tmp)
TOOL=$REPO/tests/frontend-inputs.sh
R=$T/repo
export CARGO_TARGET_DIR=$T/target
unset RUSTFLAGS CARGO_BUILD_TARGET

git_() { git -C "$R" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
commit() { git_ add -A >/dev/null && git_ commit -q -m "$1" --allow-empty; }
digest() { (cd "$R" && "$TOOL" digest "${1:-HEAD}"); }
check() { (cd "$R" && "$TOOL" "$@") >"$T/out" 2>&1; }
build() { (cd "$R/frontend" && cargo build --offline --quiet --message-format=json-render-diagnostics) >"$T/build.json" 2>"$T/build"; }

mkdir -p "$R/frontend/src" "$R/frontend/tests" "$R/release" "$R/.github/workflows"
git -C "$R" init -q
cat >"$R/frontend/Cargo.toml" <<'EOF'
[package]
name = "omb-tui"
version = "0.1.0"
edition = "2021"
publish = false

[[bin]]
name = "omb-tui"
path = "src/main.rs"
EOF
printf 'fn main() {\n    println!("{}", include_str!("../tests/schema.txt").len());\n}\n' >"$R/frontend/src/main.rs"
printf 'schema 1\n' >"$R/frontend/tests/schema.txt"
printf '[toolchain]\nchannel = "1.88.0"\n' >"$R/frontend/rust-toolchain.toml.pin"
printf 'omb-frontend-lock 1\n' >"$R/release/frontend.lock"
mkdir -p "$R/lib"
printf 'REC_PROTO=1\n' >"$R/lib/records.sh"
printf 'name: release\njobs:\n  build:\n    steps:\n      - run: cargo build --release --locked --offline\n' >"$R/.github/workflows/release.yml"
(cd "$R/frontend" && cargo generate-lockfile --offline --quiet) || fail "cargo generate-lockfile"
commit base
d0=$(digest)
case "$d0" in [0-9a-f]*) [ "${#d0}" = 64 ] && ok || fail "inputs_digest is a SHA-256: [$d0]" ;; *) fail "no digest: [$d0]" ;; esac

# --- frontend-lock-not-input ---------------------------------------------------------------
printf 'omb-frontend-lock 1\nfrontend\tversion=0.1.0\n' >"$R/release/frontend.lock"
commit "only the lock"
assert_eq "$(digest)" "$d0" "frontend-lock-not-input: a commit changing only the lock leaves inputs_digest unchanged"

# --- frontend-input-source-change, -cargo-lock, -toolchain ---------------------------------
printf 'fn main() {\n    println!("{}", include_str!("../tests/schema.txt").len() + 1);\n}\n' >"$R/frontend/src/main.rs"
commit source
d1=$(digest)
[ "$d1" != "$d0" ] && ok || fail "frontend-input-source-change: a source change changes inputs_digest"
# The CI comparison with the lock fails.
printf 'omb-frontend-lock 1\nfrontend\tversion=0.1.0\tproto=1\tsource_commit=%s\tinputs_digest=%s\trust=1.88.0\n' "$(printf '%040d' 0)" "$d0" >"$R/release/frontend.lock"
commit "the lock of the earlier inputs"
check lock
assert_rc "$?" 1 "frontend-input-source-change: the lock comparison fails"
assert_contains "$(cat "$T/out")" "a new release is needed" "and says a release is needed"
sed -i.bak "s/$d0/$d1/" "$R/release/frontend.lock" && rm -f "$R/release/frontend.lock.bak"
commit "the lock of these inputs"
check lock
assert_rc "$?" 0 "the lock naming these inputs passes"
sed -i.bak 's/proto=1/proto=2/' "$R/release/frontend.lock" && rm -f "$R/release/frontend.lock.bak"
commit "a lock of another protocol"
check lock
assert_rc "$?" 1 "a lock whose protocol is not the core's fails"
assert_contains "$(cat "$T/out")" "speaks protocol 2, the core 1" "and names both protocols"
sed -i.bak 's/proto=2/proto=1/' "$R/release/frontend.lock" && rm -f "$R/release/frontend.lock.bak"
commit "the lock of the core's protocol"
printf '\n' >>"$R/frontend/Cargo.lock"
commit "Cargo.lock"
d2=$(digest)
[ "$d2" != "$d1" ] && ok || fail "frontend-input-cargo-lock: Cargo.lock alone changes inputs_digest"
git_ mv frontend/rust-toolchain.toml.pin frontend/rust-toolchain.toml
commit toolchain
d3=$(digest)
[ "$d3" != "$d2" ] && ok || fail "frontend-input-toolchain: the toolchain file changes inputs_digest"
printf '[toolchain]\nchannel = "1.88.1"\n' >"$R/frontend/rust-toolchain.toml"
commit "another toolchain"
[ "$(digest)" != "$d3" ] && ok || fail "frontend-input-toolchain: a different pinned version changes it"
git_ rm -q frontend/rust-toolchain.toml
commit "the default toolchain for the builds below"

# --- frontend-input-test-asset: tests are inputs --------------------------------------------
d4=$(digest)
printf 'schema 2\n' >"$R/frontend/tests/schema.txt"
commit "only the test asset"
[ "$(digest)" != "$d4" ] && ok || fail "frontend-input-test-asset: a file under tests/ that production code includes changes inputs_digest"
build && ok || fail "the crate builds: $(cat "$T/build")"
check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
assert_rc "$?" 0 "frontend-input-test-asset: the closure check passes (a tracked input)"

# --- frontend-input-include-outside ----------------------------------------------------------
printf 'outside\n' >"$R/outside.txt"
printf 'fn main() {\n    println!("{}", include_str!("../../outside.txt"));\n}\n' >"$R/frontend/src/main.rs"
commit "include outside frontend/"
build || fail "the outside include builds: $(cat "$T/build")"
check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
assert_rc "$?" 1 "frontend-input-include-outside: a file outside frontend/ fails the closure"
assert_contains "$(cat "$T/out")" "outside the closure: $(cd "$R" && pwd -P)/outside.txt" "and names it"
rm -rf "$CARGO_TARGET_DIR/debug/deps"/omb_tui-*
printf 'untracked\n' >"$R/frontend/src/untracked.txt"
printf 'fn main() {\n    println!("{}", include_str!("untracked.txt"));\n}\n' >"$R/frontend/src/main.rs"
git_ add frontend/src/main.rs && git_ commit -q -m "include an untracked file"
build || fail "the untracked include builds: $(cat "$T/build")"
check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
assert_rc "$?" 1 "frontend-input-include-outside: an untracked file inside frontend/ fails the closure"
assert_contains "$(cat "$T/out")" "which Git does not track" "and says so"
# The build's own output folder is not an input either: only each rule's
# target is an output, never a file rustc read from there.
rm -rf "$CARGO_TARGET_DIR/debug/deps"/omb_tui-*
printf 'planted\n' >"$CARGO_TARGET_DIR/debug/deps/planted.txt"
printf 'fn main() {\n    println!("{}", include_str!("%s"));\n}\n' "$CARGO_TARGET_DIR/debug/deps/planted.txt" >"$R/frontend/src/main.rs"
git_ add frontend/src/main.rs && git_ commit -q -m "include a file beside the build's outputs"
build || fail "the planted include builds: $(cat "$T/build")"
check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
assert_rc "$?" 1 "frontend-input-include-outside: a file in the build's own output folder fails the closure"
assert_contains "$(cat "$T/out")" "planted.txt" "and names it"

# --- frontend-input-generated-target-excluded -----------------------------------------------
dh=$(digest)
mkdir -p "$R/frontend/target/debug" && printf 'built' >"$R/frontend/target/debug/omb-tui"
assert_eq "$(digest)" "$dh" "frontend-input-generated-target-excluded: a target/ folder and an untracked file leave the digest unchanged"
check clean
assert_rc "$?" 1 "the release build refuses an unclean tree"
rm -rf "$R/frontend/target" "$R/frontend/src/untracked.txt"
printf 'fn main() {}\n' >"$R/frontend/src/main.rs"
commit "back to a plain main"
check clean
assert_rc "$?" 0 "a tree that is exactly the commit is clean"

# --- frontend-input-build-rs ----------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  check metadata
  assert_rc "$?" 0 "no build script, every package here or from crates.io"
  printf 'fn main() {}\n' >"$R/frontend/build.rs"
  commit "a build script"
  check metadata
  assert_rc "$?" 1 "frontend-input-build-rs: a build script of the frontend's own is refused"
  printf 'fn main() {\n    let _ = std::fs::read("tests/schema.txt");\n}\n' >"$R/frontend/build.rs"
  commit "a build script reading an asset"
  check metadata
  assert_rc "$?" 1 "frontend-input-build-rs: with an asset read too"
  git_ rm -q frontend/build.rs && commit "no build script"
  # --- frontend-input-local-path-dependency ---------------------------------------------------
  mkdir -p "$R/elsewhere/src"
  printf '[package]\nname = "elsewhere"\nversion = "0.1.0"\nedition = "2021"\n' >"$R/elsewhere/Cargo.toml"
  : >"$R/elsewhere/src/lib.rs"
  cp "$R/frontend/Cargo.toml" "$T/Cargo.toml.plain"
  printf '\n[dependencies]\nelsewhere = { path = "../elsewhere" }\n' >>"$R/frontend/Cargo.toml"
  (cd "$R/frontend" && cargo generate-lockfile --offline --quiet)
  commit "a path dependency outside frontend/"
  check metadata
  assert_rc "$?" 1 "frontend-input-local-path-dependency: a path package outside frontend/ is refused"
  assert_contains "$(cat "$T/out")" "a path package outside frontend/: elsewhere" "and named"
  cp "$T/Cargo.toml.plain" "$R/frontend/Cargo.toml"
  (cd "$R/frontend" && cargo generate-lockfile --offline --quiet)
  printf '\n[patch.crates-io]\n' >>"$R/frontend/Cargo.toml"
  commit "a patch section"
  check metadata
  assert_rc "$?" 1 "frontend-input-local-path-dependency: a [patch] section is refused"
  cp "$T/Cargo.toml.plain" "$R/frontend/Cargo.toml"
  printf '\n[[package]]\nname = "far"\nversion = "0.1.0"\nsource = "git+https://example.invalid/far#0000000000000000000000000000000000000000"\n' >>"$R/frontend/Cargo.lock"
  commit "a git source"
  check metadata
  assert_rc "$?" 1 "frontend-input-local-path-dependency: a git dependency is refused"
  (cd "$R/frontend" && cargo generate-lockfile --offline --quiet)
  commit "plain again"

  # --- frontend-input-local-crate: every crate of the frontend's own is read ------------------
  # A path package under frontend/ is allowed; what its crate reads is held
  # to the same closure as the frontend's.
  mkdir -p "$R/frontend/local-helper/src"
  printf '[package]\nname = "local-helper"\nversion = "0.1.0"\nedition = "2021"\npublish = false\n' >"$R/frontend/local-helper/Cargo.toml"
  printf 'pub const OUTSIDE: &[u8] = include_bytes!("../../../outside.txt");\n' >"$R/frontend/local-helper/src/lib.rs"
  cp "$R/frontend/Cargo.toml" "$T/Cargo.toml.plain"
  printf '\n[dependencies]\nlocal-helper = { path = "local-helper" }\n' >>"$R/frontend/Cargo.toml"
  printf 'fn main() {\n    println!("{}", local_helper::OUTSIDE.len());\n}\n' >"$R/frontend/src/main.rs"
  (cd "$R/frontend" && cargo generate-lockfile --offline --quiet)
  commit "a local crate that includes a file outside frontend/"
  check metadata
  assert_rc "$?" 0 "a path package under frontend/ is allowed"
  rm -f "$CARGO_TARGET_DIR/debug/deps"/*.d
  build || fail "the local crate builds: $(cat "$T/build")"
  check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
  assert_rc "$?" 1 "frontend-input-local-crate: a local crate's include from outside frontend/ fails the closure"
  assert_contains "$(cat "$T/out")" "outside the closure: $(cd "$R" && pwd -P)/outside.txt (lib local_helper of local-helper@0.1.0)" "and names the file and the target"
  printf 'pub const OUTSIDE: &[u8] = b"inside";\n' >"$R/frontend/local-helper/src/lib.rs"
  commit "the local crate reads nothing outside"
  rm -f "$CARGO_TARGET_DIR/debug/deps"/*.d
  build || fail "the local crate builds: $(cat "$T/build")"
  check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
  assert_rc "$?" 0 "a local crate reading only tracked inputs passes"
  rm -f "$CARGO_TARGET_DIR/debug/deps"/local_helper-*.d
  check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
  assert_rc "$?" 1 "frontend-input-target-evidence: a local path dependency's library the build compiled, with no dependency file, fails"
  assert_contains "$(cat "$T/out")" "no dependency file for lib local_helper of local-helper@0.1.0" "and names it"
  git_ rm -q -r frontend/local-helper
  cp "$T/Cargo.toml.plain" "$R/frontend/Cargo.toml"
  (cd "$R/frontend" && cargo generate-lockfile --offline --quiet)

  # --- frontend-input-env-dep: the build environment read at compile time ---------------------
  env_case() { # CODE ENV... — the closure's status over a build of main() { CODE } with ENV
    printf 'fn main() {\n    %s\n}\n' "$1" >"$R/frontend/src/main.rs"
    shift
    commit "an environment read"
    rm -f "$CARGO_TARGET_DIR/debug/deps"/*.d
    (cd "$R/frontend" && env "$@" cargo build --offline --quiet --message-format=json-render-diagnostics) >"$T/build.json" 2>"$T/build" || fail "the build: $(cat "$T/build")"
    check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
  }
  env_case 'println!("{}", env!("OMB_BUILD_ONLY"));' OMB_BUILD_ONLY=x
  assert_rc "$?" 1 "frontend-input-env-dep: env!() of an unapproved variable fails the closure"
  assert_contains "$(cat "$T/out")" "reads the build environment's OMB_BUILD_ONLY" "and names it"
  env_case 'println!("{:?}", option_env!("OMB_MAYBE"));' OMB_UNRELATED=1
  assert_rc "$?" 1 "frontend-input-env-dep: option_env!() of an unset variable fails too (its absence is an input)"
  assert_contains "$(cat "$T/out")" "OMB_MAYBE" "and names it"
  env_case 'println!("{}", env!("CARGO_PKG_VERSION"));' OMB_UNRELATED=1
  assert_rc "$?" 0 "frontend-input-env-dep: CARGO_PKG_VERSION (from the tracked Cargo.toml) passes"
  env_case 'println!("{} {}", env!("CARGO_PKG_NAME"), env!("CARGO_PKG_AUTHORS"));' OMB_UNRELATED=1
  assert_rc "$?" 0 "frontend-input-env-dep: CARGO_PKG_NAME and CARGO_PKG_AUTHORS, Cargo.toml's too, pass"
  # The fourteen names Cargo sets, not a family: another spelled like them
  # is the build environment's.
  env_case 'println!("{}", env!("CARGO_PKG_REVIEW_INPUT"));' CARGO_PKG_REVIEW_INPUT=x
  assert_rc "$?" 1 "frontend-input-env-dep: CARGO_PKG_REVIEW_INPUT, set, is not Cargo.toml's: it fails the closure"
  assert_contains "$(cat "$T/out")" "reads the build environment's CARGO_PKG_REVIEW_INPUT" "and names it"
  env_case 'println!("{:?}", option_env!("CARGO_PKG_REVIEW_INPUT"));' OMB_UNRELATED=1
  assert_rc "$?" 1 "frontend-input-env-dep: option_env!() of CARGO_PKG_REVIEW_INPUT, unset, fails too"
  assert_contains "$(cat "$T/out")" "reads the build environment's CARGO_PKG_REVIEW_INPUT" "and names it"
  env_case 'println!("{}", env!("CARGO_PKG_FAKE"));' CARGO_PKG_FAKE=x
  assert_rc "$?" 1 "frontend-input-env-dep: an invented CARGO_PKG_FAKE fails"
  env_case 'println!("{}", env!("CARGO_MANIFEST_DIR"));' OMB_UNRELATED=1
  assert_rc "$?" 1 "frontend-input-env-dep: CARGO_MANIFEST_DIR, where the build ran, fails"

  # --- frontend-input-target-evidence: each target the build compiled has its own ------------
  # A library omb_tui and a binary omb-tui: rustc names both crates omb_tui
  # and both dependency files omb_tui-HASH.d. Each needs its own; the
  # other's, or one another build left, never stands in.
  # dep_files — LIB_D and BIN_D: the build's two omb_tui dependency files,
  # told apart by what rustc wrote each for (a library's names its .rlib),
  # never by the check under test.
  dep_files() {
    LIB_D=$(grep -l '/libomb_tui-[0-9a-f]*\.rlib:' "$CARGO_TARGET_DIR/debug/deps"/omb_tui-*.d)
    BIN_D=$(grep -L '/libomb_tui-[0-9a-f]*\.rlib:' "$CARGO_TARGET_DIR/debug/deps"/omb_tui-*.d)
    if [ -f "$LIB_D" ] && [ -f "$BIN_D" ]; then ok; else fail "the build wrote one dependency file for each ([$LIB_D] [$BIN_D])"; fi
  }
  # one_gone FILE WHAT — the closure without FILE alone: it fails, naming WHAT.
  one_gone() {
    if [ ! -f "$1" ]; then
      fail "no dependency file to take away for $2"
      return
    fi
    mv "$1" "$T/held.d"
    check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
    assert_rc "$?" 1 "frontend-input-target-evidence: the dependency file of $2 gone, the other's there, fails"
    assert_contains "$(cat "$T/out")" "no dependency file for $2" "and names it"
    mv "$T/held.d" "$1"
  }
  printf 'fn main() {\n    println!("{}", omb_tui::X);\n}\n' >"$R/frontend/src/main.rs"
  printf 'pub const X: u8 = 1;\n' >"$R/frontend/src/lib.rs"
  commit "a library and a binary spelled alike"
  rm -f "$CARGO_TARGET_DIR/debug/deps"/*.d
  build || fail "the library and the binary build: $(cat "$T/build")"
  dep_files
  check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
  assert_rc "$?" 0 "frontend-input-target-evidence: a library and a binary spelled alike, each with its own dependency file, pass"
  assert_contains "$(cat "$T/out")" "lib omb_tui of omb-tui@0.1.0: deps/${LIB_D##*/}" "frontend-input-target-evidence: the library is bound to its own file"
  assert_contains "$(cat "$T/out")" "bin omb-tui of omb-tui@0.1.0: deps/${BIN_D##*/}" "and the binary to its own"
  one_gone "$BIN_D" "bin omb-tui of omb-tui@0.1.0"
  one_gone "$LIB_D" "lib omb_tui of omb-tui@0.1.0"
  cp "$BIN_D" "$T/held.d"
  cp "$LIB_D" "$BIN_D"
  check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
  assert_rc "$?" 1 "frontend-input-target-evidence: the library's file in the binary's place fails"
  assert_contains "$(cat "$T/out")" "names no output of bin omb-tui" "and says whose it is not"
  mv "$T/held.d" "$BIN_D"
  # A dependency file of the same crate name that no target of this build is
  # bound to — another build's — is neither evidence nor read.
  { cat "$BIN_D" && printf '# env-dep:OMB_BUILD_ONLY=x\n'; } >"$CARGO_TARGET_DIR/debug/deps/omb_tui-0000000000000000.d"
  check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
  assert_rc "$?" 0 "frontend-input-target-evidence: another build's dependency file beside them is not this build's evidence"
  rm -f "$CARGO_TARGET_DIR/debug/deps/omb_tui-0000000000000000.d"
  # The messages must be of the build that wrote the folder, and whole.
  sed "s#$CARGO_TARGET_DIR/debug/#$T/elsewhere/debug/#g" "$T/build.json" >"$T/other.json"
  check closure "$CARGO_TARGET_DIR/debug/deps" "$T/other.json"
  assert_rc "$?" 1 "frontend-input-target-evidence: another build's messages fail"
  grep -v '"build-finished"' "$T/build.json" >"$T/other.json"
  check closure "$CARGO_TARGET_DIR/debug/deps" "$T/other.json"
  assert_rc "$?" 1 "frontend-input-target-evidence: messages of a build that did not finish fail"
  # Two packages: this one's binary omb-tui, and a local package under
  # frontend/ whose library is named omb_tui.
  git_ rm -q frontend/src/lib.rs
  mkdir -p "$R/frontend/helper/src"
  printf '[package]\nname = "helper"\nversion = "0.1.0"\nedition = "2021"\npublish = false\n\n[lib]\nname = "omb_tui"\n' >"$R/frontend/helper/Cargo.toml"
  printf 'pub const X: u8 = 2;\n' >"$R/frontend/helper/src/lib.rs"
  cp "$R/frontend/Cargo.toml" "$T/Cargo.toml.plain"
  printf '\n[dependencies]\nhelper = { path = "helper" }\n' >>"$R/frontend/Cargo.toml"
  (cd "$R/frontend" && cargo generate-lockfile --offline --quiet)
  commit "a local package whose library is spelled like the binary"
  rm -f "$CARGO_TARGET_DIR/debug/deps"/*.d
  build || fail "the two packages build: $(cat "$T/build")"
  dep_files
  check closure "$CARGO_TARGET_DIR/debug/deps" "$T/build.json"
  assert_rc "$?" 0 "frontend-input-target-evidence: two packages' targets spelled alike, each with its own dependency file, pass"
  assert_contains "$(cat "$T/out")" "lib omb_tui of helper@0.1.0: deps/${LIB_D##*/}" "frontend-input-target-evidence: the other package's library is bound to its own file"
  assert_contains "$(cat "$T/out")" "bin omb-tui of omb-tui@0.1.0: deps/${BIN_D##*/}" "and the binary to its own"
  one_gone "$BIN_D" "bin omb-tui of omb-tui@0.1.0"
  one_gone "$LIB_D" "lib omb_tui of helper@0.1.0"
  git_ rm -q -r frontend/helper
  cp "$T/Cargo.toml.plain" "$R/frontend/Cargo.toml"
  (cd "$R/frontend" && cargo generate-lockfile --offline --quiet)
  printf 'fn main() {}\n' >"$R/frontend/src/main.rs"
  commit "plain again"
else
  fail "jq is needed to read cargo metadata (frontend-input-build-rs, -local-path-dependency)"
fi

# --- frontend-input-cargo-config -------------------------------------------------------------
check config
assert_rc "$?" 0 "no Cargo configuration elsewhere, no build flags in the release workflow"
mkdir -p "$R/.cargo" && printf '[build]\nrustflags = []\n' >"$R/.cargo/config.toml"
commit "configuration at the root"
check config
assert_rc "$?" 1 "frontend-input-cargo-config: a .cargo/config.toml at the repository root is refused"
git_ rm -q -r .cargo && commit "no root configuration"
printf '    env:\n      RUSTFLAGS: "-C target-cpu=native"\n' >>"$R/.github/workflows/release.yml"
commit "flags in the release workflow"
check config
assert_rc "$?" 1 "frontend-input-cargo-config: RUSTFLAGS set in the release workflow is refused"
assert_contains "$(cat "$T/out")" "RUSTFLAGS" "and named"
printf 'name: release\njobs:\n  build:\n    steps:\n      - run: cargo build --release --features test-hooks\n' >"$R/.github/workflows/release.yml"
commit "test hooks in a release"
check config
assert_rc "$?" 1 "a release workflow naming the test-hooks feature is refused"
# The same configuration under other names.
for bad in '      CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS: "-C opt-level=0"' '      RUSTC_WRAPPER: sccache' \
  '      - run: cargo build --release --config profile.release.debug=true'; do
  printf 'name: release\njobs:\n  build:\n    steps:\n%s\n' "$bad" >"$R/.github/workflows/release.yml"
  commit "configuration under another name"
  check config
  assert_rc "$?" 1 "frontend-input-cargo-config: the release workflow setting it this way is refused: $bad"
done
printf 'name: release\njobs:\n  build:\n    steps:\n      - run: cargo build --release --locked --offline\n' >"$R/.github/workflows/release.yml"
commit "a plain release workflow"

# --- frontend-input-link ---------------------------------------------------------------------
ln -s main.rs "$R/frontend/src/link.rs"
commit "a symbolic link"
(cd "$R" && "$TOOL" digest) >"$T/out" 2>&1
assert_rc "$?" 1 "frontend-input-link: a tracked symbolic link under frontend/ is refused"
assert_contains "$(cat "$T/out")" "a tracked symbolic link under frontend/: frontend/src/link.rs" "and named"
git_ rm -q frontend/src/link.rs && commit "no link"

# --- frontend-input-order --------------------------------------------------------------------
for f in B.rs a.rs _x.rs a-b.rs Z_z.rs a.b.rs; do printf '// %s\n' "$f" >"$R/frontend/src/$f"; done
commit "names whose order depends on the locale"
c=$(LC_ALL=C digest)
u=$(LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 digest)
assert_eq "$u" "$c" "frontend-input-order: the listing under LC_ALL=C and a UTF-8 locale is byte-identical"
assert_eq "$(cd "$R" && "$TOOL" listing | sed -n '2,$p' | cut -f1 | LC_ALL=C sort -c 2>&1)" "" "the listing is in byte order of the path"

# --- The digest reads the commit, never the working tree --------------------------------------
dc=$(digest)
printf '// uncommitted\n' >>"$R/frontend/src/a.rs"
assert_eq "$(digest)" "$dc" "an uncommitted change is not an input: the digest is the commit's"
assert_eq "$(digest HEAD~1)" "$(cd "$R" && "$TOOL" digest HEAD~1)" "any commit's digest can be computed"

# --- The release's lock lines: what the release workflow prints, the launcher admits ---------
# Read from this host's build of the crate: the Darwin lines on macOS, the
# ELF lines on Linux.
printf '[toolchain]\nchannel = "1.88.0"\n' >"$R/frontend/rust-toolchain.toml"
git_ add frontend/rust-toolchain.toml && git_ commit -q -m "a toolchain for the lock"
case "$(uname -s)" in Darwin) tgt=aarch64-apple-darwin ;; *) tgt=aarch64-unknown-linux-gnu ;; esac
bin=$CARGO_TARGET_DIR/debug/omb-tui
(cd "$R" && "$TOOL" lock-head 0.1.0 && "$TOOL" artifact-line "$tgt" "$bin" https://example.invalid/omb-tui) >"$T/lock.body" 2>"$T/lock.err"
assert_rc "$?" 0 "the lock lines are printed ($(cat "$T/lock.err"))"
if command -v shasum >/dev/null 2>&1; then seal=$(shasum -a 256 <"$T/lock.body" | cut -c1-64); else seal=$(sha256sum <"$T/lock.body" | cut -c1-64); fi
{
  cat "$T/lock.body"
  printf 'seal\tsha256=%s\n' "$seal"
} >"$T/frontend.lock"
assert_contains "$(cat "$T/lock.body")" "source_commit=$(git_ rev-parse HEAD)	inputs_digest=$(digest)	rust=1.88.0" "the frontend line names the commit, its inputs and its toolchain"
if command -v shasum >/dev/null 2>&1; then sum=$(shasum -a 256 <"$bin" | cut -c1-64); else sum=$(sha256sum <"$bin" | cut -c1-64); fi
assert_contains "$(cat "$T/lock.body")" "target=$tgt	url=https://example.invalid/omb-tui	size=$(wc -c <"$bin" | tr -d ' ')	sha256=$sum" "the artifact line pins the binary's size and SHA-256"
r=$(
  t_load >/dev/null 2>&1
  # shellcheck source=lib/records.sh
  . "$REPO/lib/records.sh"
  if rec_admit_file lock - "$T/frontend.lock"; then echo admitted; else echo "refused: $REC_REASON"; fi
)
assert_eq "$r" admitted "the launcher's reader admits the lock the release prints"

# --- frontend-input-candidate-*: an unreleased next version, never the release ---------------
# A second throwaway repository holding a release (its inputs, then its sealed
# lock and tag) and, on top of it, candidates that each break one rule. `lock`
# stays the exact-release check; `candidate` passes only the honest other state
# (docs/DECISIONS.md → D49).
C=$T/cand
cg() { git -C "$C" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
cmt() { cg add -A >/dev/null && cg commit -q -m "$1" --allow-empty; }
cand() { (cd "$C" && "$TOOL" candidate "$@") >"$T/out" 2>&1; }
lockcheck() { (cd "$C" && "$TOOL" lock) >"$T/out" 2>&1; }
sha_() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-64; else sha256sum | cut -c1-64; fi; }
ART="artifact	target=aarch64-apple-darwin	url=https://example.invalid/omb-tui	size=1	sha256=$(printf '%064d' 1)	minos=13.5	glibc_max=	interp=	align_min="
# seal FILE — append the seal of what FILE holds.
seal() { printf 'seal\tsha256=%s\n' "$(sha_ <"$1")" >>"$1"; }
# mklock VERSION PROTO SOURCE DIGEST — the lock a release writes.
mklock() {
  {
    printf 'omb-frontend-lock 1\n'
    printf 'frontend\tversion=%s\tproto=%s\tsource_commit=%s\tinputs_digest=%s\trust=1.88.0\n' "$1" "$2" "$3" "$4"
    printf '%s\n' "$ART"
  } >"$C/release/frontend.lock"
  seal "$C/release/frontend.lock"
}
# admits — the launcher's own reader on the lock as it stands.
admits() {
  (
    t_load >/dev/null 2>&1
    # shellcheck source=lib/records.sh
    . "$REPO/lib/records.sh"
    if rec_admit_file lock - "$C/release/frontend.lock"; then echo admitted; else echo refused; fi
  )
}
cdigest() { (cd "$C" && "$TOOL" digest "${1:-HEAD}"); }
setver() { # VERSION — the crate's version in both files that hold it
  printf '[package]\nname = "omb-tui"\nversion = "%s"\nedition = "2024"\n' "$1" >"$C/frontend/Cargo.toml"
  printf '[[package]]\nname = "omb-tui"\nversion = "%s"\ndependencies = []\n' "$1" >"$C/frontend/Cargo.lock"
}
mkdir -p "$C/frontend/src" "$C/lib" "$C/release"
git -C "$C" init -q
setver 0.1.0
printf 'fn main() {}\n' >"$C/frontend/src/main.rs"
printf 'REC_PROTO=1\n' >"$C/lib/records.sh"
cmt "the release's inputs"
rel=$(cg rev-parse HEAD)
reld=$(cdigest)
mklock 0.1.0 1 "$rel" "$reld"
cmt "the release's lock"
cg tag frontend-v0.1.0 "$rel"
base=$(cg rev-parse HEAD)

# The released frontend: `lock` passes, and `candidate` has nothing to classify.
lockcheck
assert_rc "$?" 0 "frontend-input-candidate-released: the released inputs pass the exact lock check"
assert_eq "$(admits)" admitted "and the launcher's reader admits the lock (the definitions agree)"
cand 0.2.0
assert_rc "$?" 1 "frontend-input-candidate-released: no candidate is named by an unchanged release"
assert_contains "$(cat "$T/out")" "not the candidate 0.2.0" "the crate does not name it"
cand 0.1.0
assert_rc "$?" 1 "the release's own version is never a candidate"
assert_contains "$(cat "$T/out")" "is not newer than the pinned release 0.1.0" "and is not newer"

# The same version with changed inputs is a failure, of both checks.
printf 'fn main() { println!("changed"); }\n' >"$C/frontend/src/main.rs"
cmt "changed inputs, still 0.1.0"
lockcheck
assert_rc "$?" 1 "frontend-input-candidate-same-version: the lock check fails on the difference"
assert_contains "$(cat "$T/out")" "a new release is needed" "and says a release is needed"
cand 0.1.0
assert_rc "$?" 1 "frontend-input-candidate-same-version: 0.1.0 with a changed digest is refused"
assert_contains "$(cat "$T/out")" "is not newer than the pinned release" "as no newer version"
cand 0.2.0
assert_rc "$?" 1 "an unexplained difference: the crate still says 0.1.0, so 0.2.0 is refused"
assert_contains "$(cat "$T/out")" "frontend/Cargo.toml names 0.1.0" "naming the version the crate holds"
cg reset -q --hard "$base"

# An explicit next version with changed inputs is classified, and never called released.
setver 0.2.0
printf 'fn main() { println!("candidate"); }\n' >"$C/frontend/src/main.rs"
cmt "the candidate 0.2.0"
cnd=$(cg rev-parse HEAD)
lockcheck
assert_rc "$?" 1 "frontend-input-candidate-classified: the lock check still fails: the candidate is not the release"
cand 0.2.0
assert_rc "$?" 0 "frontend-input-candidate-classified: the named 0.2.0 candidate is accepted"
assert_contains "$(cat "$T/out")" "UNRELEASED" "and called unreleased"
assert_contains "$(cat "$T/out")" "No release equality is claimed" "with no equality claimed"
assert_not_contains "$(cat "$T/out")" "matches the lock" "and never said to match the lock"
assert_eq "$(git -C "$C" show HEAD:release/frontend.lock | sha_)" "$(git -C "$C" show "$base:release/frontend.lock" | sha_)" "the release's lock was not touched by the candidate"
cand 0.3.0
assert_rc "$?" 1 "frontend-input-candidate-version-expected: a version the crate does not hold is refused"
assert_contains "$(cat "$T/out")" "not the candidate 0.3.0" "naming it"
cand 0.2.1
assert_rc "$?" 1 "frontend-input-candidate-version-expected: 0.2.1 is refused too"
cand 0.0.9
assert_rc "$?" 1 "frontend-input-candidate-version-expected: an older version is refused"
assert_contains "$(cat "$T/out")" "is not newer than the pinned release" "as not newer"
for bad in 0.2 v0.2.0 0.2.0-rc1 01.2.0 ""; do
  cand "$bad"
  assert_rc "$?" 1 "frontend-input-candidate-version-expected: '$bad' is not MAJOR.MINOR.PATCH"
done

# The crate's lock file must hold the candidate version as well.
printf '[[package]]\nname = "omb-tui"\nversion = "0.1.0"\ndependencies = []\n' >"$C/frontend/Cargo.lock"
cmt "Cargo.lock behind"
cand 0.2.0
assert_rc "$?" 1 "frontend-input-candidate-cargo-lock: a Cargo.lock at another version is refused"
assert_contains "$(cat "$T/out")" "frontend/Cargo.lock names 0.1.0 for omb-tui" "naming it"
cg reset -q --hard "$cnd"

# The release's protocol must be the core's.
printf 'REC_PROTO=2\n' >"$C/lib/records.sh"
cmt "a core of another protocol"
cand 0.2.0
assert_rc "$?" 1 "frontend-input-candidate-protocol: a core whose protocol the pinned release does not speak is refused"
assert_contains "$(cat "$T/out")" "the lock's frontend speaks protocol 1, the core 2" "naming both"
cg reset -q --hard "$cnd"

# A lock that is not well formed fails, and the launcher's reader agrees it is not.
badlock() { # LABEL WANT — the lock as written now, committed, then judged by both
  cmt "a lock: $1"
  cand 0.2.0
  assert_rc "$?" 1 "frontend-input-candidate-malformed-lock: $1 is refused"
  assert_contains "$(cat "$T/out")" "$2" "$1: the reason is named"
  assert_eq "$(admits)" refused "$1: the launcher's reader refuses it too (the definitions agree)"
  cg reset -q --hard "$cnd"
}
mklock 0.1.0 1 "$rel" "$reld"
assert_eq "$(admits)" admitted "a well-formed lock is admitted by the launcher's reader"
sed -i.bak 's/size=1/size=2/' "$C/release/frontend.lock" && rm -f "$C/release/frontend.lock.bak"
badlock "a lock edited after it was sealed" "seal does not match its bytes"
mklock 0.1.0 1 "$rel" "$reld"
sed '$d' "$C/release/frontend.lock" >"$T/nolock" && cp "$T/nolock" "$C/release/frontend.lock"
badlock "a lock with no seal" "last line is not a seal"
mklock 0.1.0 1 "$rel" "$reld"
printf 'artifact\ttarget=x\n' >>"$C/release/frontend.lock"
badlock "a lock with a line after its seal" "neither frontend nor artifact"
{ printf 'omb-frontend-lock 1\nfrontend\tversion=0.1.0\tproto=1\tsource_commit=%s\tinputs_digest=%s\trust=1.88.0\n' "$rel" "$reld"; } >"$C/release/frontend.lock"
seal "$C/release/frontend.lock"
badlock "a lock with no artifact" "holds no artifact line"
{
  printf 'omb-frontend-lock 1\nfrontend\tversion=0.1.0\tproto=1\tsource_commit=%s\tinputs_digest=%s\trust=1.88.0\n' "$rel" "$reld"
  printf 'frontend\tversion=0.1.0\tproto=1\tsource_commit=%s\tinputs_digest=%s\trust=1.88.0\n%s\n' "$rel" "$reld" "$ART"
} >"$C/release/frontend.lock"
seal "$C/release/frontend.lock"
badlock "a lock with two frontend lines" "exactly one frontend line"
{
  printf 'omb-frontend-lock 2\nfrontend\tversion=0.1.0\tproto=1\tsource_commit=%s\tinputs_digest=%s\trust=1.88.0\n%s\n' "$rel" "$reld" "$ART"
} >"$C/release/frontend.lock"
seal "$C/release/frontend.lock"
badlock "a lock with another header" "first line is not 'omb-frontend-lock 1'"
{
  printf 'omb-frontend-lock 1\nfrontend\tversion=0.1.0\tproto=1\tsource_commit=%s\tinputs_digest=%s\n%s\n' "$rel" "$reld" "$ART"
} >"$C/release/frontend.lock"
seal "$C/release/frontend.lock"
badlock "a frontend line with a field missing" "frontend line is malformed"
{
  printf 'omb-frontend-lock 1\nfrontend\tversion=0.1.0\tproto=1\tsource_commit=%s\tinputs_digest=%s\trust=1.88.0\n%s\nnote\ttext=x\n' "$rel" "$reld" "$ART"
} >"$C/release/frontend.lock"
seal "$C/release/frontend.lock"
badlock "a lock with a record that is neither frontend nor artifact" "neither frontend nor artifact"
mklock 0.1.0 1 "$rel" "$reld"
printf '%s' "$(cat "$C/release/frontend.lock")" >"$T/nonl" && cp "$T/nonl" "$C/release/frontend.lock"
badlock "a lock without its final newline" "does not end with a newline"
cg rm -q release/frontend.lock
cmt "no lock"
cand 0.2.0
assert_rc "$?" 1 "frontend-input-candidate-malformed-lock: no lock at all is refused (there is no release to differ from)"
assert_contains "$(cat "$T/out")" "no release/frontend.lock" "and says so"
cg reset -q --hard "$cnd"

# The pinned release must be intact: its inputs reproducible from its source commit.
mklock 0.1.0 1 "$rel" "$(cdigest "$cnd")"
cmt "a lock whose digest is not its source commit's"
cand 0.2.0
assert_rc "$?" 1 "frontend-input-candidate-release-intact: a lock whose digest its source commit does not hold is refused"
assert_contains "$(cat "$T/out")" "the pinned release is not intact" "as not intact"
cg reset -q --hard "$cnd"
mklock 0.1.0 1 "$(printf '%040d' 1)" "$reld"
cmt "a lock naming a commit this checkout lacks"
cand 0.2.0
assert_rc "$?" 1 "frontend-input-candidate-release-intact: a source commit that is not in the checkout is refused"
assert_contains "$(cat "$T/out")" "is not in this checkout" "and says to fetch it"
cg reset -q --hard "$cnd"
cg tag -f frontend-v0.1.0 "$cnd" >/dev/null
cand 0.2.0
assert_rc "$?" 1 "frontend-input-candidate-release-intact: a release tag that names another commit is refused"
assert_contains "$(cat "$T/out")" "the tag frontend-v0.1.0 names" "naming the tag"
cg tag -d frontend-v0.1.0 >/dev/null
cand 0.2.0
assert_rc "$?" 0 "frontend-input-candidate-release-intact: with no tag in the checkout (a shallow one), the rest still holds"
cg tag frontend-v0.1.0 "$rel"

# A lock whose inputs the commit itself holds is the released frontend, never a candidate.
mklock 0.0.1 1 "$rel" "$reld"
git -C "$C" checkout -q "$base" -- frontend lib
cmt "the release's inputs under an older lock"
cand 0.1.0
assert_rc "$?" 1 "frontend-input-candidate-identical: inputs equal to the lock's are the release, not a candidate"
assert_contains "$(cat "$T/out")" "this is the released frontend" "and the lock check is the one that applies"
cg reset -q --hard "$cnd"

# The release workflow stays exact; CI names its candidate on purpose.
assert_eq "$(grep -c 'candidate' "$REPO/.github/workflows/release.yml")" 0 "frontend-input-release-strict: the release workflow never runs the candidate check"
ciwant=$(sed -n 's/^ *FRONTEND_CANDIDATE_VERSION: "\(.*\)"$/\1/p' "$REPO/.github/workflows/ci.yml")
crate=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$REPO/frontend/Cargo.toml" | sed -n 1p)
assert_eq "$ciwant" "$crate" "frontend-input-candidate-ci-version: the candidate version CI names is the crate's, set by hand in the workflow"
grep -q 'tests/frontend-inputs.sh lock ||' "$REPO/.github/workflows/ci.yml" && ok || fail "frontend-input-candidate-ci-version: CI still runs the exact lock check first"

t_done test-frontend-inputs
