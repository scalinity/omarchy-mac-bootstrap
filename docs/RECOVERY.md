# Recovery

Every interruption point, what state it leaves, and the upstream-supported way
forward. `./omarchy-bootstrap status` tells you which case you are in.

## Before the installer launched

Nothing on the disk changed. Run `./omarchy-bootstrap` again; the saved plan is
offered as a starting point. Ctrl-C at any of this tool's prompts stops without side
effects; Ctrl-C inside a launched installer interrupts that installer, and the
tool says so.

## The Asahi installer stopped or failed

- **Quit at its menu (`q`)** — nothing changed.
- **Resize failed** — the installer reports it; it is usually pre-existing APFS
  damage. Boot Recovery (hold power → Options), run Disk Utility First Aid on
  the macOS volume and container, then run `./omarchy-bootstrap` again.
- **Stopped after partitioning** — Linux partitions exist but the OS may be
  incomplete. `./omarchy-bootstrap` detects the partitions and will not start a
  second install. Run the Asahi Alarm installer yourself
  (`curl https://asahi-alarm.org/installer-bootstrap.sh | sh`, or re-run the
  saved copy in the state directory's `downloads/`) and choose **p** — *Repair
  an incomplete installation*.

## First boot went wrong

- **Bootloop, or "macOS needs to be reinstalled"** — the power-button sequence
  was not followed exactly. Fully shut down, wait, press and *hold* once, choose
  the new volume. If still stuck, hold power, boot macOS, re-run the installer
  and choose **p**.
- **Linux missing from Startup Options after a macOS 27 upgrade** — re-run the
  Asahi Alarm installer from macOS and choose **7** — *Fix macOS 27 boot picker
  compatibility*.

## Omarchy Mac stopped

`omarchy-mac-setup` reads where the machine got to (is `/boot` separate, is the
root a finished LUKS device, is Omarchy installed) and resumes itself on the
next boot through `omarchy-mac-setup.service` on tty1.

- **Watch it** — Ctrl+Alt+F1.
- **Resume now** — as root: `./omarchy-bootstrap resume` (offers
  `omarchy-mac-setup --resume` when the unit is idle), or run
  `omarchy-mac-setup --resume` directly.
- **Its log** — `/var/log/omarchy-mac-setup.log`.
- **Interrupted encryption** — upstream documents the in-place encryption as
  safe to interrupt; the next boot resumes it.
- **Boots to `grub rescue>`** — `/boot` was on the root when it was encrypted.
  Follow Omarchy Mac's `docs/btrfs.md`.
- **Stop the guided run** without undoing anything — `omarchy-mac-setup --abort`.

## After Omarchy

- **A bad update** — `omarchy snapshot restore` lists snapper snapshots plus
  `@fresh` (before Omarchy) and `@factory` (the installed system).
- **Developer setup** — every module is rerunnable: `./omarchy-bootstrap dev`.

## Back to macOS only

There is no automatic uninstaller, by design. From macOS, follow the
[Asahi partitioning cheatsheet](https://asahilinux.org/docs/sw/partitioning-cheatsheet/)
exactly: set macOS as the startup disk, delete the stub APFS container, delete
the EFI and Linux partitions, then grow the macOS container into the freed
space. Never delete `Apple_APFS_Recovery`.

## This tool's own state

Everything it records is in `~/.local/state/omarchy-mac-bootstrap/` (root on
Linux: `/var/lib/omarchy-mac-bootstrap/`). Deleting that directory forgets the
plan and history; it changes nothing on the disk.
