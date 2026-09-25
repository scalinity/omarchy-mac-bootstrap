# Storage

The planner mirrors the Asahi installer's own arithmetic so the numbers you plan
with are the numbers the installer will accept. It never resizes anything; the
installer does, after you type the values it asks for.

## What the installer asks

On a stock disk the installer offers **r** (resize) by default:

1. `New size` — the **new size of the macOS container** (`745GB`, `50%`, `min`).
2. `Choose an OS to install` — `Asahi Alarm Minimal (BTRFS)`.
3. `New OS size` — the Linux allocation, default `max`. It includes the 2.5 GB
   stub container and the 0.5 GB EFI partition; the rest is the Btrfs root.

If the disk already has enough unpartitioned space, choose **f** instead and
type the Linux size at `New OS size`.

## Inputs

| Symbol | Meaning | Source |
| --- | --- | --- |
| D | internal disk size | `diskutil list -plist <disk>` |
| C | macOS container size | `APFSContainerSize` |
| F | container free | `APFSContainerFree` (purgeable space not counted) |
| U | macOS used, `C − F` | |
| P | `MinimumSizePreferred` | `diskutil apfs resizeContainer <c> limits -plist` |
| E | unpartitioned space | `D − Σ partitions`, counted above 1 GB |
| S | shared-area reservation | your choice, default 0 |

## Algorithm

```text
installer floor   M = max(align_up(U + 38 GB, 1 MiB), P)
overhead          O = M − align_up(U + 38 GB, 1 MiB)     warn above 16 GB
planning floor    M + 5 GB                               drift between plan and install
Linux maximum     floor_GB(max(C − (M + 5 GB) − S, E − S))
blocked when      Linux maximum < 50 GB                  (Omarchy Mac minimum)
```

For a Linux allocation A:

```text
A + S ≤ E  →  no resize:  choose f, type "<A>GB"
otherwise  →  choose r, type "<ceil_GB(C − A − S)>GB", then f and "max"
                                                  (or "<A>GB" when S > 0)
```

`38 GB`, `2.5 GB`, `0.5 GB`, `1 MiB` and the 16 GB warning come from
asahi-installer `src/main.py` (v0.9.2); the 50 / 100 GB guidance from the
Omarchy Mac README. All of them live in `lib/sources.sh`.

**Overhead** is space macOS reports free but cannot give up: usually Time
Machine local snapshots or a pending macOS update. Finish updates, or follow
<https://alx.sh/tmcleanup>, then re-run the planner.

## Presets

Each preset is kept only if it lies between 50 GB and the maximum and below
90 % of the maximum (closer than that, "Maximum safe" covers it).

| Preset | Size |
| --- | --- |
| Minimal | 100 GB, or 50 GB when 100 does not fit |
| Balanced *(recommended when offered)* | 25 % of D, nearest 25 GB |
| Linux-heavy | 50 % of D, nearest 25 GB |
| Maximum safe | the Linux maximum |
| Custom | `250`, `250GB`, `250.5 GB`, `1TB`, `0.5T`, `35%` (of D), `max` |

Custom sizes below 50 GB are rejected; above the maximum they are rejected with
the arithmetic shown; below 100 GB they are accepted with a warning.

## Reading the layout

The plan screen keeps three numbers apart:

- **Requested** — the Linux allocation you chose.
- **Estimated** — macOS ≈ its new size, Linux root ≈ allocation − 3 GB, boot
  data 3 GB, Apple's own partitions as measured.
- **Exact** — whatever the installer creates after aligning to 1 MiB. The tool
  only names the values to type.

## Optional shared area

Off by default. An exFAT partition both systems can read and write is handy for
hand-offs and poor for code (no permissions, no symlinks, case-insensitive, no
journal). Asahi documents no installer workflow for it, so the tool:

1. reserves S GB by making the installer's `New OS size` the Linux size instead
   of `max`, which leaves S GB unpartitioned;
2. writes `shared-storage-plan.txt` to the state directory with the manual
   steps — identify the free region, create one partition in it, restore GPT
   ordering with `fdisk` (`x`, `f`, `r`, `w`) as the partitioning cheatsheet
   requires, format with `mkfs.exfat` — and never runs them.

Read the [partitioning cheatsheet](https://asahilinux.org/docs/sw/partitioning-cheatsheet/)
before touching the partition table. Never modify `Apple_APFS_Recovery`.
