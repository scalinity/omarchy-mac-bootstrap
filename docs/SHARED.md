# Shared storage

One exFAT partition that macOS and Linux both read and write, planned with
the rest of the disk and created by this tool after Linux is completely
installed. It appears at `/Volumes/Shared` on macOS (or `/Volumes/Shared 1`
if that name is taken; the tool records the real mount point) and at
`/mnt/shared` on Linux.

## What it is for

| Good for | Not for |
| --- | --- |
| datasets, PDFs, media, model files, archives, downloads, files moving between the systems | a Linux home directory, package databases, Docker or container storage, Git checkouts that rely on Unix permissions, anything that needs owners, modes or symlinks |

exFAT has no journal, no Unix owners or permissions, no symlinks or hard
links, and names are case-insensitive. Files larger than 4 GB are fine.

**It is not encrypted.** FileVault protects macOS and LUKS protects the Linux
root; neither covers Shared. **It is not a backup** either: back it up like
any other disk.

## The lifecycle

```text
macOS    plan: Shared size chosen first, reserved in the same plan as Linux
         Asahi installer: Linux gets an exact size; the reserved region stays free
reboot
Linux    Omarchy Mac installs, moves /boot, encrypts in place (its own reboots)
         once all of that has finished: a completion code (ombdone-...)
reboot
macOS    ./omarchy-bootstrap: type the completion code; the disk is checked;
         type yes (backup) and create; one sudo diskutil addPartition; the result is checked
         a Shared code (ombshare-...) is shown
reboot
Linux    ./omarchy-bootstrap shared activate: type the Shared code; type mount;
         one managed line in /etc/fstab; /mnt/shared mounts on first use from then on
```

One more reboot than the install alone. The state is read from the machine
on every run; `./omarchy-bootstrap shared` shows it on either system:

| State | Meaning |
| --- | --- |
| `off` | no Shared storage planned |
| `reserved` | planned; Asahi not installed yet |
| `awaiting-linux-completion` | Asahi installed; Linux not finished, or its code not typed in yet |
| `awaiting-macos-creation` | Linux finished, the region checked: ready to create |
| `created` | the Shared partition exists as planned |
| `awaiting-linux-activation` | (Linux) the partition is there, not mounted on boot yet |
| `ready` | (Linux) mounted at `/mnt/shared` on every boot |
| `blocked` | something does not match the plan; the tool stops and says what |

## Why it is created from macOS, after Linux

- The Asahi installer offers no way to create an extra data partition during
  the install, and its own partitioning uses `diskutil addPartition` from
  macOS. Creating Shared the same way keeps the GPT the way macOS writes it;
  the Asahi partitioning cheatsheet warns that Linux tools append partitions
  out of order.
- Omarchy Mac's migration rewrites `/boot` and encrypts the root in place
  across reboots. Nothing else changes the partition table while that runs:
  Linux shows the completion code only when Omarchy Mac's marker is written,
  its setup files and unit are gone, no migration is staged, and the
  encryption is positively finished: as root, the LUKS header of root's
  partition is read and is a LUKS2 header without `online-reencrypt`; as
  your everyday user, who cannot read the header, the migration's finish
  marker exists. A header that cannot be read (cryptsetup missing or
  failing, no output, something that is not a LUKS2 header) never counts as
  finished, and as root the marker does not stand in for it.
- macOS cannot read the encrypted Linux root, so Linux's word crosses the
  reboot as a typed code, bound to the plan and to the Linux root's GPT GUID.

## The codes

`ombdone-<plan>-<root>-<check>` (Linux → macOS) and
`ombshare-<plan>-<shared>-<check>` (macOS → Linux): the plan's short digest,
the first 12 hex digits of a GPT partition GUID, and four check digits that
catch a mistyped character. A code is input, never permission: each side
checks the disk itself, and a code for another plan or another partition is
refused.

## The plan record

`shared-intent.env` in macOS's state directory: a versioned, digested record
of the disk the plan was made for (size, block size, every partition's GUID,
offset and size), the answers given to the installer, and the region
reserved. A record that was edited, is from another version of this tool, or
describes another disk blocks creation.

## Creating it (macOS)

Before anything runs, the whole disk is read and must show:

- this Mac's internal disk: the whole disk and the physical store macOS runs
  from both report themselves internal, macOS runs from the container the
  plan was made on, on a single physical store, and the disk gives the name
  the plan recorded. A copy of the disk in an external enclosure can carry
  the same GUIDs and extents; it is never a target;
- the disk the plan was made for, with Apple's ISC and Recovery partitions and
  every other partition from before exactly where they were;
- the macOS container at exactly the size the plan left it;
- Asahi's stub, EFI and Linux partitions, in that order;
- one free region after the Linux root, followed by the partition the plan
  expected, at least as large as planned;
- no partition and no free region that neither the plan nor Asahi left;
- Linux's completion code for this plan and this Linux root;
- the Mac on power, or a battery at 50 % or more. When macOS reports no
  power state at all (`pmset -g batt` prints nothing), the tool says the
  power state is unverified and goes on: keep the Mac plugged in.

It shows the physical disk, the interval in bytes, the size, the partitions
before and after, and the filesystem, and asks for `yes` (a current backup)
and `create`. Then `sudo` asks for your password (`sudo -v`; if it does not
authenticate, nothing more happens), so that typing it never sits between
the last read of the disk and the change. Then it reads the disk again; any
difference stops it. It
writes the creation record, `shared-create.env`: the disk, every partition on
it byte for byte, the free region the creation may use, the Linux root
before it, the partition after it, and the size it creates. A record that
cannot be written stops it. Then, and only then:

```bash
sudo diskutil addPartition <the Linux root, e.g. disk0s6> ExFAT Shared <bytes>
```

`<bytes>` is the planned size rounded up to a whole MiB, placed at the
region's first MiB boundary; the rest of the region stays free, which leaves
diskutil room for its own alignment. `sudo` needs your password because
diskutil must own the internal disk to change its partition map; it was
asked for before the last read, so this runs straight after it.

**What the last read cannot rule out.** This tool's lock keeps two of its own
runs apart; it is not a lock on the disk. Another program (Disk Utility, an
installer, another `diskutil`) could still change the partition table in the
moment between the last read and `addPartition`. That moment is kept short —
nothing waits for you after the read — and the creation record catches any
result that is not what was allowed. Close other disk tools while Shared is
created.

Afterwards the disk is read again and judged by the creation record: every
partition in it unchanged, byte for byte, and exactly one new partition,
inside the free region it was given, of type Microsoft Basic Data, formatted
exFAT, at least the planned size. Anything else stops with an explanation,
and the stop is recorded. **Nothing is ever repaired, formatted or deleted
automatically.**

Running it again is safe. While the creation record exists, every run —
`shared`, `shared create`, the guided flow — judges the disk by that same
check, never by reading it afresh: when it passes (the run that created
Shared ended before recording it), Shared is recorded and the record
removed; when diskutil left nothing new and no stop was recorded, it can be
created again; anything else stays stopped, even on a later run that could
otherwise make sense of the disk. A stop clears only when the check passes
(for example, an unformatted result you erased as exFAT yourself, below), or
when you remove the record after checking the disk yourself. Without a
record, a Shared partition already in the region is recognised and recorded
only if it follows the Linux root that Linux's completion code named, and it
is never created a second time. A partition in the region that is not the
planned exFAT volume (another type, another filesystem, too small,
unformatted) blocks; this tool never formats a partition that exists.

## Mounting it (Linux)

`./omarchy-bootstrap shared activate`, as your everyday user. It finds the
partition by the GUID in the Shared code, checks that it is on the same disk
as the Linux root, right after it, exFAT, Basic Data, and at least the
planned size, and refuses if `/etc/fstab` already mentions `/mnt/shared`, the
partition, or a volume named Shared. It then:

```bash
sudo install -d -m 0755 -o root -g root /mnt/shared
sudo cp -p /etc/fstab /etc/fstab.omarchy-bootstrap.bak
sudo install -m 0644 -o root -g root <new fstab> /etc/fstab.omarchy-bootstrap.new
sudo mv -f /etc/fstab.omarchy-bootstrap.new /etc/fstab
sudo systemctl daemon-reload
sudo systemctl start mnt-shared.automount
```

The new fstab is the old one, unchanged, plus one managed entry:

```text
# omarchy-bootstrap: Shared storage (managed; see ./omarchy-bootstrap shared)
PARTUUID=<guid> /mnt/shared exfat rw,nofail,x-systemd.automount,x-systemd.device-timeout=10s,uid=<you>,gid=<you>,fmask=0177,dmask=0077,nodev,nosuid,noexec 0 0
```

- `PARTUUID` (lowercase, as udev names it), never `/dev/nvme0n1pN`: device
  numbers can change when partitions are added.
- `nofail` and `x-systemd.automount`: boot never waits for Shared; it mounts on
  first use. `x-systemd.device-timeout=10s`: if it is missing, access fails
  after ten seconds instead of the default ninety.
- `uid`/`gid` are your ids, read with `id`, never assumed to be 1000; files
  show as 0600 and folders as 0700, because exFAT stores no permissions.
- `nodev,nosuid,noexec`: nothing runs from Shared. Its files have no execute
  bits to honour anyway; a script can still be run with `bash file`.
- `/mnt/shared` itself stays root-owned and 0755, so if Shared is ever missing
  nothing can be written there by mistake onto the Linux root.

Running it again when the entry is in place changes nothing.

## Checking it

- `./omarchy-bootstrap shared` — the state and the next step (read-only).
- `./omarchy-bootstrap doctor` — identity, type, filesystem, size, disk, the
  fstab entry, whether it is mounted, with which options, free space, a
  read-only remount after an error, and a second mount of the same
  partition. Reading proves presence, not that it can be written.
- `./omarchy-bootstrap shared test` — after typing `test`: writes one uniquely
  named file, flushes it, reads it back, compares the checksum, and removes
  that file only.

## Switching between the systems

Shut down fully before starting the other system; do not hibernate or
suspend one system and then boot the other, which leaves a stale view of
Shared behind. After a crash or a forced power-off, the exFAT volume may be
marked dirty: Linux mounts it anyway and says so in its kernel log; check it
from macOS with Disk Utility's First Aid before relying on it. This tool
never runs a filesystem repair itself.

## When it stops

| It says | What to do |
| --- | --- |
| the Shared plan record was changed / has a line this tool did not write / is from another version | the record is not trustworthy; plan again before installing, or remove `shared-intent.env` to give up on Shared |
| this is not the disk the plan was made for / on | run it on the Mac that made the plan |
| the disk macOS runs from is not reported as internal / macOS is not running from the container the plan was made on / more than one physical store | boot this Mac's own macOS from its internal disk and run it there; an external copy of the disk is never a target |
| an Apple system partition, the macOS container, or another partition is not where the plan found it | something changed the disk since the plan; compare `diskutil list` with `./omarchy-bootstrap status` |
| an unexpected partition / a free region the plan did not leave | something other than Asahi changed the disk; nothing is created while which region is Shared's would be a guess |
| the free region after Linux is smaller than reserved | the installer was given a different Linux size than planned; Shared can still be created by hand in the space there is (below) |
| made on a different Linux partition / belongs to a different plan | type the code the current Linux shows (`./omarchy-bootstrap` on Linux) |
| not the exFAT volume planned (filesystem …) | the partition in Shared's place is not a finished exFAT volume. If it is yours to erase: `diskutil eraseVolume ExFAT Shared <id>` from macOS, then run `./omarchy-bootstrap shared create` to record it |
| the Shared creation started … did not leave the disk as planned / stopped | the one creation did something other than what it was allowed to (the message names what). Nothing more will run while it stands. Compare `diskutil list` with the message; when the disk is as it should be after all, `shared create` records it. When you have settled it another way, remove `shared-create.env` from the state directory: the disk is then read afresh, and still refused if it does not match the plan |
| an exFAT partition follows the Linux root, but Linux's completion code for this root is not recorded | the Linux root is not the one Linux vouched for; nothing is taken for Shared after it |
| /etc/fstab already has an entry … | remove or change that entry yourself, then run `shared activate` again |
| /mnt/shared already holds files | move them elsewhere first; mounting would hide them |

## Removing Linux, keeping Shared

Uninstalling Linux (docs/RECOVERY.md) never touches Shared. The layout is
`macOS | stub | EFI | Linux | Shared | Recovery`, so after the stub, EFI and
Linux partitions are removed, `diskutil apfs resizeContainer <macOS
container> 0` grows macOS into the freed space and stops at Shared: macOS can
only grow into free space directly after it. To give Shared's space back to
macOS as well, copy its contents elsewhere, remove it with `diskutil
eraseVolume free free <Shared's id>`, then grow macOS again.

## What still needs checking on the real Mac

These follow Apple's and upstream's documentation and have been exercised
only against recorded disk layouts: that `sudo diskutil addPartition` with an
exact byte count creates exactly that size at the start of the region,
without an extra alignment gap or booter partition; that macOS mounts the
new volume writable for your everyday user although root created it; that
Apple SSD GPT entries are renumbered but not reordered in a way that
confuses the Asahi boot chain; that macOS mounts the new volume as expected;
and that Omarchy's udiskie does not also mount Shared under `/run/media`
(doctor warns if it does).
