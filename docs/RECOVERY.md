# Recovery

Every interruption point, what state it leaves, and the upstream-supported way
forward. `./omarchy-bootstrap status` tells you which case you are in.

## Before the installer launched

Nothing on the disk changed. Run `./omarchy-bootstrap` again; the saved plan is
offered as a starting point. Ctrl-C at any of this tool's prompts stops without side
effects; Ctrl-C inside a launched installer interrupts that installer, and the
tool says so.

## The Asahi installer stopped or failed

The installer exits 0 whether it finished, was quit or hit an error, so its
exit status says nothing. When it returns, this tool reads the disk again and
compares it with the layout recorded just before the launch. `./omarchy-bootstrap`
and `./omarchy-bootstrap status` do the same on any later run.

| What the disk shows | What happened | The way forward |
| --- | --- | --- |
| exactly the layout before the launch | quit at its first menu, or stopped before resizing | nothing to recover; run `./omarchy-bootstrap` again |
| macOS smaller, the freed space free, no new partitions | resized, then quit or stopped | quitting does not undo a resize; `./omarchy-bootstrap` plans an install into the freed space (the installer's **f**, no second resize) |
| a stub container only, or stub and EFI without a Linux partition | stopped while creating partitions | see *Removing an unfinished install* |
| all three partitions, but the stub lacks the installer's first-stage files | stopped before the first stage finished | see *Removing an unfinished install* |
| all three, first stage complete, first boot not run | normal after the installer's shutdown | boot the new OS from Startup Options (hold power) to finish step 2 |
| all three, the stub not readable from macOS | first boot status unknown from macOS | boot the new OS; if it does not reach the "Asahi Linux installer" screen, rerun the installer (below) |
| anything else | unclear | the tool stops; compare `./omarchy-bootstrap status` with this page before running anything |

**Repair (`p`)** is offered by the installer only when its first stage
finished: the stub must hold `step2.sh`, `boot.bin` and its install markers.
For an earlier interruption it prints "The existing installation is missing
files … please delete the partitions manually and reinstall from scratch".
Run the Asahi Alarm installer yourself to use it
(`curl https://asahi-alarm.org/installer-bootstrap.sh | sh`, or re-run the
saved copy in the state directory's `downloads/`).

**Resize failed** — the installer reports it; it is usually pre-existing APFS
damage. Boot Recovery (hold power → Options), run Disk Utility First Aid on
the macOS volume and container, then run `./omarchy-bootstrap` again.

### Removing an unfinished install

This tool never deletes partitions. When the installer's repair refuses, the
partitions it created must be removed by hand, from macOS, as the
[Asahi partitioning cheatsheet](https://asahilinux.org/docs/sw/partitioning-cheatsheet/)
describes:

1. Make macOS the startup disk (System Settings › General › Startup Disk).
2. `diskutil list` — find the partitions `./omarchy-bootstrap status` names:
   the small stub APFS container right after the macOS container, then the
   EFI partition, then the Linux partition. Device numbers are not stable;
   check sizes and order every time.
3. `sudo diskutil apfs deleteContainer <stub, e.g. disk0s4>`
4. `sudo diskutil eraseVolume free free <EFI partition>` and the same for the
   Linux partition, if they exist.
5. `diskutil apfs resizeContainer <macOS container, e.g. disk0s2> 0` grows
   macOS into the free space directly after it (it stops at the next
   partition).

Never touch `Apple_APFS_Recovery` or `Apple_APFS_ISC`. Then run
`./omarchy-bootstrap` again.

## First boot went wrong

- **Bootloop, or "macOS needs to be reinstalled"** — the power-button sequence
  was not followed exactly. Fully shut down, wait, press and *hold* once, choose
  the new volume. If still stuck, boot macOS and run `./omarchy-bootstrap`: it
  reads which stage the install reached and whether the installer's **p** applies.
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
- **Its output** — on tty1 only (Ctrl+Alt+F1); upstream keeps no log file.
- **Interrupted encryption** — upstream documents the in-place encryption as
  safe to interrupt; the next boot resumes it. `./omarchy-bootstrap doctor`
  reports it as not finished while `/etc/omarchy-btrfs-migrate.conf` exists or
  (as root) the LUKS header still carries `online-reencrypt`, and as a
  failure when root cannot read the header at all; either way Shared waits.
- **Boots to `grub rescue>`** — `/boot` was on the root when it was encrypted.
  Follow Omarchy Mac's `docs/btrfs.md`.
- **Stop the guided run** without undoing anything — `omarchy-mac-setup --abort`.

## After Omarchy

- **A bad update** — `omarchy snapshot restore` lists snapper snapshots plus
  `@fresh` (before Omarchy) and `@factory` (the installed system).
- **Developer setup** — every module is rerunnable: `./omarchy-bootstrap dev`.
  The summary names each module that failed and why; rerun just those once
  the cause is fixed. A failed module is never recorded as done.

## Shared storage stopped

`./omarchy-bootstrap shared` on either system shows the state and the reason.
Every case, and what to do about it, is in [SHARED.md](SHARED.md#when-it-stops).
In short: a Shared partition that exists is found and recorded, never created
twice; anything in Shared's place that is not the planned exFAT volume stops
everything, and this tool never formats or deletes it. A creation whose
result was not what it was allowed to produce stays stopped on every later
run, until its own check passes or you remove `shared-create.env` after
checking the disk. After a crash, check the exFAT volume with Disk Utility's
First Aid on macOS before relying on it.

## Back to macOS only

There is no automatic uninstaller, by design. From macOS, follow the
[Asahi partitioning cheatsheet](https://asahilinux.org/docs/sw/partitioning-cheatsheet/)
exactly: set macOS as the startup disk, delete the stub APFS container, delete
the EFI and Linux partitions, then grow the macOS container into the freed
space (*Removing an unfinished install* above lists the commands). Never
delete `Apple_APFS_Recovery`.

Shared storage is kept: it is not part of the Linux install. macOS can grow
only into free space directly after it, so with the layout
`macOS | (freed) | Shared | Recovery` it grows up to Shared and stops. To
give Shared's space back too, copy its files elsewhere first, then remove it
with `diskutil eraseVolume free free <Shared's id>` and grow macOS again. On
Linux the managed line in `/etc/fstab` goes with the Linux install.

## This tool's own state

Everything it records is in `~/.local/state/omarchy-mac-bootstrap/` (root on
Linux: `/var/lib/omarchy-mac-bootstrap/`). Deleting that directory forgets the
plan and history; it changes nothing on the disk. On macOS, keep
`shared-intent.env` while Shared storage is still to be created: it is the
record creation is checked against. `shared-create.env` exists only between
the creation and its recorded result; remove it only as docs/SHARED.md
describes.
