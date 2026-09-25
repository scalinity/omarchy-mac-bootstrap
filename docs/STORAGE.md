# Storage

The planner models the internal disk byte for byte and replays the Asahi
installer's own sizing rules, so the answers it asks you to type produce the
layout it showed you. The installer does the resize and creates the Linux
partitions; this tool computes, explains, and checks.

## What the installer asks

On a stock disk the installer offers **r** (resize) by default:

1. `New size` — the **new size of the macOS container**. The tool gives an
   exact value such as `711345MiB` (also on the clipboard).
2. The menu returns; choose **f** (*Install an OS into free space*). If the
   installer lists more than one free region, the card names the one to pick
   (`after disk0s2`, with its size).
3. `Choose an OS to install` — `Asahi Alarm Minimal (BTRFS)`.
4. `New OS size` — the Linux allocation (stub + EFI + Btrfs root): `max` when
   no Shared storage follows Linux, otherwise an exact value such as
   `238420MiB`. With Shared on, never type `max`: the space after Linux is
   Shared's.

If one existing free region already holds everything, there is no resize:
choose **f** and type the exact Linux size.

Every size is a whole number of MiB. The installer aligns the resize answer
up and the New OS size down to 1 MiB; a whole-MiB value passes through both
unchanged.

## The disk as extents

The survey reads every partition's offset, size and GPT GUID
(`diskutil info -plist <partition>`, cross-checked against `diskutil list
-plist`) and walks the GPT's usable range: the gaps between partitions are
listed one by one, with the partition before and after each. Everything must
add up to the disk size. A missing offset, two views that disagree, a
misaligned or overlapping partition, a second APFS container or a container
spread over two physical stores stops planning — nothing is guessed.

Separate free regions are never added together. The installer installs into
one region at a time, so two 75 GB gaps hold 75 GB of Linux, not 150.

## The macOS floor

| Symbol | Meaning | Source |
| --- | --- | --- |
| C | macOS container size | `APFSContainerSize` (must equal its partition) |
| F | container free | `APFSContainerFree` (purgeable space not counted) |
| U | macOS used | `C − F` |
| P | `MinimumSizePreferred` | `diskutil apfs resizeContainer <c> limits -plist` |

```text
installer minimum   M = max(align_up(U + 38 GB, 1 MiB), P)
overhead            O = M − align_up(U + 38 GB, 1 MiB)    warn above 16 GB
floor               align_up(M + 5 GB, 1 MiB)             drift between plan and install
```

When `limits` does not answer, no resize is planned: the installer's own
minimum cannot be predicted.

**Overhead** is space macOS reports free but cannot give up: usually Time
Machine local snapshots or a pending macOS update. Finish updates, or follow
<https://alx.sh/tmcleanup>, then plan again.

## Choosing the region

For Linux `L` and Shared `S`:

1. An existing gap that holds `L` (and `S` plus 16 MiB spare): no resize. The
   gap right after macOS is preferred, then the largest.
2. Otherwise the region a resize frees, from macOS's new end to the partition
   after it. The new macOS size is the largest whole-MiB value that still
   leaves room for `L`, then `S` and the spare, if each new partition starts on
   the next MiB boundary. It must stay at or above the floor.

The layout afterwards is `macOS | stub | EFI | Linux root | [Shared] | Recovery`.

## Linux sizes

- The minimum is **54 GB**: a 50 GB Btrfs root (Omarchy Mac's minimum) plus
  3 GB of Asahi boot data (stub 2 499 805 184 B, EFI 524 288 000 B), in whole GB.
- 100 GB is recommended; below that is accepted with a warning.
- The maximum is the largest single region allows, beside the chosen Shared
  size.

| Preset | Size |
| --- | --- |
| Minimal | 100 GB, or the minimum when 100 does not fit |
| Balanced *(recommended when offered)* | 25 % of the disk, nearest 25 GB (10 GB below 100 GB) |
| Linux-heavy | 50 % of the disk, nearest 25 GB (10 GB below 100 GB) |
| Maximum safe | the maximum |
| Custom | `250`, `250GB`, `250.5 GB`, `1TB`, `0.5T`, `35%` (of the disk), `max` |

Presets are kept only between the minimum and 90 % of the maximum. Custom
input takes up to three decimals (one for %), and refuses leading zeros
(`010` is ambiguous, never read as 8), signs, exponents, too many digits, and
anything not smaller than the disk. Fractional GB is rounded down to whole GB,
and the tool says so.

## What every plan proves

Checked on the resulting layout, not assumed from the arithmetic:

1. partitions + gaps + GPT structures = the disk;
2. no partitions overlap;
3. macOS keeps at least its floor (or is untouched without a resize);
4. Linux gets at least what was asked;
5. the Linux root keeps at least 50 GB after stub and EFI;
6. Shared's interval is at least what was asked;
7. with Shared on, Linux is never given `max`;
8. Linux and Shared lie in one free interval.

`tests/test-storage.sh` replays each accepted plan through an independent
model of the installer and checks these on its result.

## Reading the layout

The review shows each region exactly: macOS (used and free inside it), Linux
(root + boot data), Shared, system (Apple's iBoot and recovery containers,
untouched, plus the Asahi stub and EFI), and unallocated (partition-table
space, alignment, and free regions left as they are). Below it, the installer
answers and their byte values.

## Shared storage

Chosen before the Linux size, so the planner gives Linux only what leaves
Shared its room; created later, after Linux is installed. See
[SHARED.md](SHARED.md).

## Before the launch

The installer version and the OS template's EFI size are checked against the
values this model is built on; a difference refuses the launch. The disk is
read again right before it runs: a changed layout, or answers that no longer
hold because macOS filled up, stop it.
