# shellcheck shell=bash
# Additional journey observations. Existing layouts supply fresh/installed,
# Shared identities and encryption. These add a mounted everyday-user home
# and the before/after bytes of one real restore unit.
(
  set -eu
  # shellcheck source=lib/common.sh
  . ../../lib/common.sh
  # shellcheck source=lib/state.sh
  . ../../lib/state.sh
  # shellcheck source=lib/records.sh
  . ../../lib/records.sh
  for phase in pending restored; do
    d=journey-linux-$phase
    rm -rf "$d"
    cp -R linux-shared-ready "$d"
    printf '%s\n' 1000 >"$d/cmd/id_u"
    printf '%s\n' alex >"$d/cmd/id_un"
    mkdir -p "$d/root/home/alex/.config"
    chmod 700 "$d/root/home/alex"
    printf '%s\n' '121 120 259:7 / /mnt/shared rw,relatime - exfat /dev/nvme0n1p7 rw,fmask=0177,dmask=0077' >>"$d/root/proc/self/mountinfo"
    b=$d/root/mnt/shared/omarchy-mac-bootstrap/bundles/20261022T120000Z
    mkdir -p "$b/objects"
    payload='journey configuration'
    sha=$(printf '%s\n' "$payload" | shasum -a 256)
    sha=${sha%% *}
    printf '%s\n' "$payload" >"$b/objects/$sha"
    size=$(wc -c <"$b/objects/$sha" | tr -d ' ')
    {
      printf 'omb-bundle 1\n'
      rec_line bundle at 2026-10-22T12:00:00Z host 0123456789abcdef model 'MacBook Pro M1 Pro' user alex home /Users/alex items 1 files 1 bytes "$size"
      rec_line item id config:journey class config whole 1
      rec_line file item config:journey dest .config/journey.conf mode 0644 sha256 "$sha" size "$size" whole 1
    } >"$b/bundle.omb"
    rec_seal_write "$b/bundle.omb"
    if [ "$phase" = restored ]; then
      cp "$b/objects/$sha" "$d/root/home/alex/.config/journey.conf"
      chmod 0644 "$d/root/home/alex/.config/journey.conf"
    fi
  done
)
# macOS can positively see step 2 in this mounted stub, alongside Shared.
(
  d=journey-mac-created
  rm -rf "$d"
  cp -R mac-shared-created "$d"
  apfs_list "$d" disk0s4 4 /Volumes/Omarchy
  stub_files "$d" /Volumes/Omarchy 'done'
  cp mig-mac-home/cmd/hardware_plist "$d/cmd/hardware_plist"
)
