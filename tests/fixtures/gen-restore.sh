# shellcheck shell=bash
# Synthetic Omarchy home, verified Shared and one sealed content-addressed
# bundle. Sourced after generate.sh has written linux-shared-ready.
(
  set -eu
  # shellcheck source=lib/common.sh
  . ../../lib/common.sh
  # shellcheck source=lib/state.sh
  . ../../lib/state.sh
  # shellcheck source=lib/records.sh
  . ../../lib/records.sh
  # shellcheck source=lib/migrate_bundle.sh
  . ../../lib/migrate_bundle.sh
  d=rst-ready
  mkdir -p "$d"
  cp -R linux-shared-ready/. "$d/"
  mkdir -p "$d/root/home/alex/.config" "$d/root/etc/skel/.config"
  printf 'Omarchy default\n' >"$d/root/etc/skel/.config/test.conf"
  chmod 0700 "$d/root/home/alex"
  printf 'Omarchy seeded configuration\n' >"$d/root/home/alex/.config/seed.conf"
  printf '%s\n' omarchy-pkg-add mise npm uv jq >>"$d/commands"
  printf '%s\n' alex >"$d/cmd/id_un"
  printf '%s\n' 1000 >"$d/cmd/id_u"
  printf '%s\n' '121 120 259:7 / /mnt/shared rw,relatime - exfat /dev/nvme0n1p7 rw,fmask=0177,dmask=0077' >>"$d/root/proc/self/mountinfo"
  b=$d/root/mnt/shared/omarchy-mac-bootstrap/bundles/20261022T120000Z
  mkdir -p "$b/objects"
  # Digest and size are derived from these exact synthetic bytes.
  mkdir -p ../.tmp
  scratch=$(mktemp -d ../.tmp/restore-gen.XXXXXX)
  trap 'rm -rf "$scratch"' EXIT
  printf 'new configuration\n' >"$scratch/object"
  _bndl_sha "$scratch/object"
  sha=$BNDL_SHA
  _bndl_size "$scratch/object"
  size=$BNDL_SIZE
  cp "$scratch/object" "$b/objects/$sha"
  {
    printf 'omb-bundle 1\n'
    rec_line bundle at 2026-10-22T12:00:00Z host 0123456789abcdef model 'MacBook Pro M1 Pro' user alex home /Users/alex items 1 files 1 bytes "$size"
    rec_line item id config:test class config whole 1
    rec_line file item config:test dest .config/test.conf mode 0644 sha256 "$sha" size "$size" whole 1
  } >"$b/bundle.omb"
  rec_seal_write "$b/bundle.omb"
)
