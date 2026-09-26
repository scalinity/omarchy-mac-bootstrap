# Omarchy Mac Bootstrap

Turn a supported Apple Silicon Mac into a dual-boot macOS + Omarchy machine
through a guided installer, with an optional Shared partition both systems
read and write.

```bash
git clone https://github.com/scalinity/omarchy-mac-bootstrap.git
cd omarchy-mac-bootstrap
./omarchy-bootstrap
```

Run it on macOS first. After the reboot, run it again on the new Arch system;
it detects which side it is on and continues.

```text
macOS ─▶ storage plan ─▶ Asahi Alarm installer ─▶ reboot ─▶ Arch (Asahi Alarm)
      ─▶ Omarchy Mac (quattro) ─▶ Omarchy 4 ─▶ [Shared: macOS creates it, Linux mounts it]
      ─▶ optional developer setup
```

## What it does

- **Surveys the Mac, read-only.** Model and chip, memory, the internal disk's
  exact partition layout and free regions, the macOS container, real free
  space, macOS version, FileVault, admin rights, Asahi support, internet, the
  installer's own resize floor, and where any earlier install stands.
- **Plans storage in bytes.** Shared first, then Linux, computed from this
  disk's layout with the installer's own rules. It shows every region and the
  exact values to type, and proves the plan holds before offering it.
- **Hands off to the official installers**, never around them: downloads each
  script to a file, shows URL, time, size and SHA-256, lets you read it, tells
  you exactly what to type, and launches it in the foreground only after you
  type a confirmation word. Afterwards it reads the disk again and tells you
  what actually happened.
- **Carries your choices across the reboot** in a short, readable resume token.
- **Continues on Linux**: network, then Omarchy Mac's own setup with your
  answers passed as its documented flags.
- **Creates and mounts Shared storage** when planned: one exFAT partition,
  created from macOS after Linux has finished, mounted at `/mnt/shared`.
- **Offers an optional developer setup** that uses Omarchy's own commands and
  reports what really happened in each module.
- **Explains itself**: `status`, `doctor`, `shared`, `logs`.

## What it deliberately does not do

- Partition anything but Shared. Asahi exclusively owns APFS resizing and
  creation of the Linux/boot layout. Omarchy Mac exclusively owns its boot
  migration and encryption. This bootstrap has only one additional
  disk-mutation authority: after positive topology validation and explicit
  user confirmation, it may create the one planned Shared cross-OS partition
  inside the previously reserved free region. It never deletes, resizes,
  reformats, or generically edits arbitrary partitions.
- Reimplement Omarchy Mac. User creation, sudo, hostname, keymap, the `/boot`
  move, encryption, snapshots, and the Omarchy install belong to
  `omarchy-mac-setup`.
- Type into an installer for you. No `expect`, no screen scraping.
- Store a secret. Passwords and passphrases are typed into the upstream program
  that asks for them.
- Repair anything automatically, remove macOS, write to APFS from Linux, or
  uninstall anything.

## Before you start

- A supported Apple Silicon Mac: M1 or M2 family. M3 is accepted as
  *experimental* (you type `experimental` to continue); M4 and later are not
  supported upstream yet. `./omarchy-bootstrap doctor` tells you which you have.
- macOS 13.5 or newer, logged in as an administrator.
- A recent backup of macOS. The tool asks you to confirm it; it cannot check it.
- Free space in one region: Linux needs at least 54 GB (a 50 GB root plus 3 GB
  of Asahi boot data; 100 GB recommended), *on top of* the 38 GB the installer
  keeps free in macOS for updates and a 5 GB margin; Shared, if you want it,
  comes on top of that.
- Internet on both sides. Wi-Fi works on the Linux side via `nmtui`.

Nothing to install first: it runs on stock macOS (`/bin/bash` 3.2) and on the
minimal Asahi Alarm image.

## How dual boot works

The Asahi installer shrinks the macOS APFS container and adds three things
after it: a 2.5 GB "stub macOS" container that makes Linux bootable from
Apple's boot picker, a 0.5 GB EFI partition, and the Linux root (Btrfs). With
Shared storage, the Shared partition follows the Linux root.

- **The new OS becomes the default startup disk** when the installer finishes.
- **Pick an OS**: hold the power button at startup until "Loading startup
  options…", then choose.
- **Set the default**: macOS System Settings › General › Startup Disk, or hold
  Option while selecting an entry in Startup Options.
- **Keep macOS installed.** Asahi needs it for firmware updates and recovery.

## Storage

On a 1 TB M1 Pro with 700 GB free, the presets are:

| Preset | Linux | Meaning |
| --- | --- | --- |
| Minimal | 100 GB | Omarchy plus moderate development |
| Balanced *(recommended)* | 25 % of the disk | projects, containers, packages |
| Linux-heavy | 50 % of the disk | a Linux laptop that keeps macOS |
| Maximum safe | what one region allows | macOS keeps used + 38 GB + snapshot overhead + 5 GB |
| Custom | `300GB`, `0.5TB`, `35%`, `max` | validated against the same limits |

The review shows macOS, Linux, Shared, system and unallocated space exactly,
and below them the values to type. The installer asks for the **new macOS
size**, then the **New OS size**; the tool gives both as whole MiB (for
example `711345MiB`), which the installer's rounding leaves unchanged, and the
first goes on the clipboard. Free space split across separate regions is never
added together: the installer uses one region at a time.

[docs/STORAGE.md](docs/STORAGE.md) has the full algorithm.

## Shared storage

Optional, chosen before the Linux size: 50, 100, 150 or 250 GB, or any size
that leaves Linux its minimum.

- **For** datasets, PDFs, media, model files, archives, downloads, files moving
  between the systems.
- **Not for** a Linux home, package databases, Docker storage, or Git checkouts
  that need Unix permissions and symlinks: exFAT has none of those.
- **Not encrypted** (FileVault and LUKS do not cover it) and **not a backup**.

It is created after Linux is completely installed: Linux shows a completion
code; on macOS, `./omarchy-bootstrap` takes that code, checks that the disk
is this Mac's internal disk and matches the plan throughout, asks for `yes`
and `create`, and adds the one partition;
back on Linux, `./omarchy-bootstrap shared activate` mounts it at
`/mnt/shared` on every boot. One reboot more than the install alone.
[docs/SHARED.md](docs/SHARED.md) explains every step and every stop.

## Install, step by step

### Phase 1 — macOS

```bash
./omarchy-bootstrap          # or: ./omarchy-bootstrap plan   (plan only)
```

1. Survey (read-only), with a disk strip of the current layout.
2. Shared storage (optional), then the Linux size, then Linux choices:
   encryption (default yes), username, hostname, console keymap, timezone,
   locale, SSH, GitHub key user, developer setup.
3. Review: continue, change something, or save and stop.
4. Backup gate: type `yes`.
5. Handoff: provenance, optional inspection, the answer card, the post-install
   boot guide, then type `launch`. The disk is read again, then the official
   installer runs in this terminal; answer it as the card says.

The installer ends by **shutting the Mac down**, so the boot guide and resume
token are shown *before* it launches. Photograph them, or run
`./omarchy-bootstrap resume` on macOS to see them again. If the installer
returns instead, the tool reads the disk and says what it did: nothing,
resized only (quitting does not undo a resize), stopped part-way, or finished.

### Reboot

1. Wait 25 seconds after power-off.
2. Press and **hold** the power button once, until "Loading startup options…".
3. Choose the new OS (default name `Asahi Alarm Minimal (BTRFS)`).
4. A macOS Recovery dialog appears; if asked, choose your macOS volume and
   authenticate.
5. Follow the "Asahi Linux installer" screen. The Mac boots Arch.
6. Log in as `root` / `root`, then connect: `nmtui`.

### Phase 2 — Arch

The minimal image has no git. Fetch this repository into `/opt` so your
everyday user can run it later too:

```bash
# public repository
mkdir -p /opt/omarchy-mac-bootstrap
curl -fsSL https://github.com/scalinity/omarchy-mac-bootstrap/archive/refs/heads/main.tar.gz \
  | tar xz --strip-components=1 -C /opt/omarchy-mac-bootstrap

# private repository (device-code sign-in, signed out again afterwards)
pacman -Syu --needed git github-cli
gh auth login
gh repo clone scalinity/omarchy-mac-bootstrap /opt/omarchy-mac-bootstrap
gh auth logout

cd /opt/omarchy-mac-bootstrap
./omarchy-bootstrap resume 'omb2:enc=1,user=…'     # the token from Phase 1
```

Phase 1 prints the right variant for your repository and the exact token,
pinned to the commit that made the plan when that commit is on GitHub (push
before launching to get the pin). Without a token it simply asks.

It checks the network (offering `nmtui`), confirms your choices, verifies that
the `quattro` branch carries Omarchy 4 and that `omarchy-mac-setup` still
accepts the flags it passes, shows provenance, and after you type `start` runs:

```bash
bash omarchy-mac-setup --encrypt --user <you> --hostname <host> --keymap <map>
```

From there Omarchy Mac drives the machine through its own reboots on tty1:
`/boot` onto the EFI partition, in-place encryption (you choose the disk
passphrase at the console), then Omarchy. About fifteen minutes and three
reboots. If a dialog offers to build packages with no aarch64 build, say no.

### Shared storage (if planned)

When Omarchy Mac has completely finished, `./omarchy-bootstrap` on Linux shows
a completion code (`ombdone-…`). Boot macOS, run `./omarchy-bootstrap`, type
the code, then `yes` and `create`. It shows a Shared code (`ombshare-…`). Boot
Linux, and as your everyday user run `./omarchy-bootstrap shared activate` and
type it, then `mount`.

### Phase 3 — developer setup (optional, rerunnable)

Log in as your user, open a terminal:

```bash
/opt/omarchy-mac-bootstrap/omarchy-bootstrap dev
```

| Module | Does |
| --- | --- |
| Core tools | git, github-cli, base-devel, curl, wget, jq, ripgrep, fd, fzf, tmux, btop, tree, unzip, rsync (only the missing ones) |
| Languages | rust, python, node, go via `omarchy-install-dev-env` |
| Containers | Docker is already there (Omarchy); opt into sudoless Docker, or add Podman |
| Editor | Neovim is Omarchy's default; VS Code via `omarchy-install-editor-vscode` |
| Git identity | `user.name`, `user.email`, `init.defaultBranch` |
| GitHub CLI | `gh auth login`, `gh auth setup-git` |
| SSH | ed25519 key, add it to GitHub; SSH access (service, firewall, authorized keys, password login off) via `omarchy-setup-security-sshd` |
| AI coding CLIs | Claude Code (native arm64 installer), Codex (npm) |
| Time & locale | apply the timezone/locale from Phase 1 if Omarchy's differ |

Nothing installs unless selected. Each module is checked afterwards and ends
as complete, already set up, skipped, cancelled, or failed with the reason; a
failure makes the run exit non-zero and is not recorded as done.

## Commands

| Command | Purpose |
| --- | --- |
| `./omarchy-bootstrap` | guided flow for wherever this machine is |
| `plan` | survey + plan + choices; saves them, runs nothing, in any state |
| `install` | the current phase end to end |
| `resume [token]` | after a reboot (macOS: the state and the guide; Linux: continue) |
| `status` | what the machine shows, what was recorded, what's next (read-only) |
| `doctor` | health checks (read-only); exits non-zero only on FAIL |
| `shared [status]` | where Shared storage stands (read-only) |
| `shared create` | macOS: create the planned Shared partition |
| `shared activate` | Linux: mount Shared at `/mnt/shared` on every boot |
| `shared test` | write, read back and remove one test file on Shared |
| `dev` | developer setup (Linux, after Omarchy) |
| `sources [--check]` | targeted upstream; `--check` compares with upstream live (read-only) |
| `logs` | where the log is, and its recent lines (read-only) |

Flags: `--dry-run` (shows every step; changes nothing and keeps nothing — no
state, no log, no download), `--no-color`, `--ascii`, `--help`, `--version`.

## State and logs

- macOS, and your user on Linux: `~/.local/state/omarchy-mac-bootstrap/`
- root on Linux: `/var/lib/omarchy-mac-bootstrap/` (readable by your user later)

`state.env` holds non-secret progress and choices; `shared-intent.env` the
Shared plan; `logs/` one readable log per day (commands, exit codes,
checksums, choices); `downloads/` each fetched upstream script, for
provenance. The directory must be yours and private; override it with
`OMB_STATE_DIR` (an absolute path). Read-only commands and dry runs write none
of it.

## Recovery and uninstall

- Something stopped halfway: [docs/RECOVERY.md](docs/RECOVERY.md).
- Shared storage stopped: [docs/SHARED.md](docs/SHARED.md#when-it-stops).
- Something looks wrong: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md),
  and `./omarchy-bootstrap doctor`.
- **Uninstall** is manual, from macOS, following the
  [Asahi partitioning cheatsheet](https://asahilinux.org/docs/sw/partitioning-cheatsheet/)
  exactly: set macOS as the startup disk, delete the stub container, the EFI
  partition and the Linux partition, then grow macOS back. Never touch
  `Apple_APFS_Recovery`. Shared storage is kept; macOS grows only up to it.

## Upstream targets

| | Value |
| --- | --- |
| Asahi Alarm bootstrap | `https://asahi-alarm.org/installer-bootstrap.sh` |
| Asahi installer checked against | v0.9.2 (a different version blocks the handoff) |
| OS to choose | `Asahi Alarm Minimal (BTRFS)` |
| Omarchy Mac | `omarchy-mac/omarchy-mac` (GitHub home `omacom/omarchy-mac`), branch `quattro` |
| Omarchy checked against | 4.0.3rc4 |

All of these live in `lib/sources.sh`. `./omarchy-bootstrap sources --check`
reports drift; nothing switches automatically. What was read where, and what
differs from the commonly quoted steps: [docs/UPSTREAM.md](docs/UPSTREAM.md).

## Development

```bash
tests/run.sh             # syntax, shellcheck (if installed), every test (~15 min)
tests/run.sh storage     # one file
./omarchy-bootstrap --dry-run     # real machine, nothing changes
OMB_FIXTURE=$PWD/tests/fixtures/mac-m1pro-1tb-roomy ./omarchy-bootstrap --dry-run
```

CI runs every test on Linux (bash 5, ShellCheck) and macOS (`/bin/bash` 3.2).
Design and boundaries: [SPEC.md](SPEC.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[MILESTONES.md](MILESTONES.md). The planning and Shared logic is tested against
recorded disk layouts; qualification on real hardware is milestone M14.
