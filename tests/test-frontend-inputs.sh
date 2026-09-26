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
build() { (cd "$R/frontend" && cargo build --offline --quiet) >"$T/build" 2>&1; }

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
check closure "$CARGO_TARGET_DIR/debug/deps"
assert_rc "$?" 0 "frontend-input-test-asset: the closure check passes (a tracked input)"

# --- frontend-input-include-outside ----------------------------------------------------------
printf 'outside\n' >"$R/outside.txt"
printf 'fn main() {\n    println!("{}", include_str!("../../outside.txt"));\n}\n' >"$R/frontend/src/main.rs"
commit "include outside frontend/"
build || fail "the outside include builds: $(cat "$T/build")"
check closure "$CARGO_TARGET_DIR/debug/deps"
assert_rc "$?" 1 "frontend-input-include-outside: a file outside frontend/ fails the closure"
assert_contains "$(cat "$T/out")" "outside the closure: $(cd "$R" && pwd -P)/outside.txt" "and names it"
rm -rf "$CARGO_TARGET_DIR/debug/deps"/omb_tui-*
printf 'untracked\n' >"$R/frontend/src/untracked.txt"
printf 'fn main() {\n    println!("{}", include_str!("untracked.txt"));\n}\n' >"$R/frontend/src/main.rs"
git_ add frontend/src/main.rs && git_ commit -q -m "include an untracked file"
build || fail "the untracked include builds: $(cat "$T/build")"
check closure "$CARGO_TARGET_DIR/debug/deps"
assert_rc "$?" 1 "frontend-input-include-outside: an untracked file inside frontend/ fails the closure"
assert_contains "$(cat "$T/out")" "which Git does not track" "and says so"

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

t_done test-frontend-inputs
