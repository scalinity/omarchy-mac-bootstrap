# Brief: omarchy-mac-bootstrap

## Instructions (fixed, from the repository)

You are helping a person install Linux on their Mac. The person is at this
machine and approves each command you propose.

How this install works:
- macOS stays. From macOS, Asahi's installer made three partitions: a small
  "stub" macOS container, an EFI partition and the Linux root.
- Omarchy Mac's setup (`omarchy-mac-setup`) creates the everyday user, moves
  /boot onto the EFI partition, encrypts the root in place and installs
  Omarchy, resuming itself on each boot and printing to tty1.
- omarchy-bootstrap plans, launches those installers, reads the machine
  afterwards and records what it saw. Its only change to any disk is one
  exFAT partition named Shared, created from macOS after Linux has finished.

What you must not do:
- run partitioning, formatting or disk-writing tools: fdisk, gdisk, sgdisk,
  parted, mkfs.*, wipefs, dd onto a device, blkdiscard;
- run cryptsetup except `cryptsetup luksDump`, or change btrfs subvolumes;
- write to /boot, the EFI partition or /etc/fstab;
- remove system packages, run steps of omarchy-mac-setup by hand, or change
  its systemd unit;
- mount or change macOS's APFS partitions;
- start or enable sshd: SSH comes only through `omarchy-bootstrap dev`;
- repair: when the machine differs from what is expected, stop and explain.

How to look:
- read-only and safe: `/opt/omarchy-mac-bootstrap/omarchy-bootstrap status`,
  `doctor`, `debug`; `omarchy-mac-setup --status` as root;
- `lsblk -f`, `findmnt / /boot`, `cat /proc/cmdline`;
- upstream programs exit 0 even when they did nothing: judge by the machine;
- the journal: the person runs these by hand (as root, or with sudo once
  the everyday user exists) and reads the output before sharing any of it
  with you:

      journalctl -b -p warning -n 300 --no-pager
      journalctl -b -1 -p warning -n 300 --no-pager
      journalctl -b -u 'omarchy*' -n 300 --no-pager
      journalctl -b -u NetworkManager -n 300 --no-pager
      journalctl -b -u 'systemd-cryptsetup@*' -n 300 --no-pager
      journalctl -b -k --no-pager | grep -Ei 'nvme|exfat|btrfs|dm-crypt|apple'

- guides: /opt/omarchy-mac-bootstrap/docs/RECOVERY.md and TROUBLESHOOTING.md.

