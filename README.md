# Omarchy Mac Bootstrap

Turn a supported Apple Silicon Mac into a dual-boot
macOS + Omarchy machine through a guided installer.

```bash
git clone https://github.com/scalinity/omarchy-mac-bootstrap.git
cd omarchy-mac-bootstrap
./omarchy-bootstrap
```

Run it on macOS first. After the reboot, run it again on the new Arch system;
it detects which side it is on and continues.

```text
macOS ─▶ storage plan ─▶ Asahi Alarm installer ─▶ reboot ─▶ Arch (Asahi Alarm)
      ─▶ Omarchy Mac (quattro) ─▶ Omarchy 4 ─▶ optional developer setup
```

## What it does

- **Surveys the Mac, read-only.** Model and chip, memory, disk, the macOS
  container, real free space, macOS version, FileVault, admin rights, Asahi
  support, internet, and the installer's own resize floor.
- **Plans storage.** Presets are calculated from this disk; custom sizes take
  GB, TB, or a percentage. It shows what macOS keeps and why a size is unsafe.
- **Hands off to the official installers**, never around them: downloads each
  script to a file, shows URL, time, size and SHA-256, lets you read it, tells
  you exactly what to type, and launches it in the foreground only after you
  type a confirmation word.
- **Carries your choices across the reboot** in a short, readable resume token.
- **Continues on Linux**: network, then Omarchy Mac's own setup with your
  answers passed as its documented flags.
- **Offers an optional developer setup** that uses Omarchy's own commands.
- **Explains itself afterwards**: `status`, `doctor`, `logs`.

## What it deliberately does not do

- Partition anything. The Asahi installer resizes macOS and creates every
  Linux partition. This tool's only disk query is the read-only
  `diskutil apfs resizeContainer … limits -plist` the installer itself uses.
- Reimplement Omarchy Mac. User creation, sudo, hostname, keymap, the `/boot`
  move, encryption, snapshots, and the Omarchy install belong to
  `omarchy-mac-setup`.
- Type into an installer for you. No `expect`, no screen scraping.
- Store a secret. Passwords and passphrases are typed into the upstream program
  that asks for them.
- Remove macOS, write to APFS from Linux, or uninstall anything.

## Before you start

- A supported Apple Silicon Mac: M1 or M2 family. M3 is accepted as
  *experimental* (you type `experimental` to continue); M4 and later are not
  supported upstream yet. `./omarchy-bootstrap doctor` tells you which you have.
- macOS 13.5 or newer, logged in as an administrator.
- A recent backup of macOS. The tool asks you to confirm it; it cannot check it.
- Free space: Omarchy Mac needs 50 GB for Linux (100 GB recommended) *on top
  of* the 38 GB the installer keeps free in macOS for updates.
- Internet on both sides. Wi-Fi works on the Linux side via `nmtui`.

Nothing to install first: it runs on stock macOS (`/bin/bash` 3.2) and on the
minimal Asahi Alarm image.

## How dual boot works

The Asahi installer shrinks the macOS APFS container and adds three things
after it: a 2.5 GB "stub macOS" container that makes Linux bootable from
Apple's boot picker, a 0.5 GB EFI partition, and the Linux root (Btrfs). macOS
stays exactly where it was and stays the default until you choose otherwise.

- **Pick an OS**: hold the power button at startup until "Loading startup
  options…", then choose.
- **Set the default**: macOS System Settings › General › Startup Disk, or hold
  Option while selecting an entry in Startup Options.
- **Keep macOS installed.** Asahi needs it for firmware updates and recovery.

## Storage

The planner offers presets computed from your disk, for example on a 1 TB
M1 Pro with 700 GB free:

| Preset | Linux | Meaning |
| --- | --- | --- |
| Minimal | 100 GB | Omarchy plus moderate development |
| Balanced *(recommended)* | 25 % of the disk | projects, containers, packages |
| Linux-heavy | 50 % of the disk | a Linux laptop that keeps macOS |
| Maximum safe | what macOS can spare | macOS keeps used + 38 GB + snapshot overhead + 5 GB |
| Custom | `300GB`, `0.5TB`, `35%`, `max` | validated against the same limits |

Three numbers are kept apart on screen: the size you **request**, the
**estimated** resulting layout, and the **exact** sizes the installer creates
(it aligns them itself). The installer does not ask "how much for Linux"; it
asks for the **new macOS size**, then the **New OS size**. The answer card
gives you both, and the first goes on the clipboard.

[docs/STORAGE.md](docs/STORAGE.md) has the full algorithm, and the optional
shared exFAT area (off by default, planned but never created).

## Install, step by step

### Phase 1 — macOS

```bash
./omarchy-bootstrap          # or: ./omarchy-bootstrap plan   (plan only)
```

1. Survey (read-only), with a disk strip of the current layout.
2. Storage plan and Linux choices: encryption (default yes), username,
   hostname, console keymap, timezone, locale, SSH, GitHub key user.
3. Review: continue, change something, or save and stop.
4. Backup gate: type `yes`.
5. Handoff: provenance, optional inspection, the answer card, the post-install
   boot guide, then type `launch`. The official installer runs in this
   terminal; answer it as the card says.

The installer ends by **shutting the Mac down**, so the boot guide and resume
token are shown *before* it launches. Photograph them, or run
`./omarchy-bootstrap resume` on macOS to see them again.

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
./omarchy-bootstrap resume 'omb1:enc=1,user=…'     # the token from Phase 1
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
| SSH | ed25519 key, add it to GitHub, enable sshd via `omarchy-setup-security-sshd` |
| AI coding CLIs | Claude Code (native arm64 installer), Codex (npm) |
| Time & locale | apply the timezone/locale from Phase 1 if Omarchy's differ |

Nothing installs unless selected; installed things are skipped.

## Commands

| Command | Purpose |
| --- | --- |
| `./omarchy-bootstrap` | guided flow for wherever this machine is |
| `plan` | survey + plan + choices, launches nothing |
| `install` | the current phase end to end |
| `resume [token]` | after a reboot (macOS: reprint the guide; Linux: continue) |
| `status` | what the machine reports, what was recorded, what's next |
| `doctor` | read-only health checks; exits non-zero only on FAIL |
| `dev` | developer setup (Linux, after Omarchy) |
| `sources [--check]` | targeted upstream; `--check` compares with upstream live |
| `logs` | where the log is, and its recent lines |

Flags: `--dry-run` (shows everything, runs nothing that changes the machine),
`--no-color`, `--ascii`, `--help`, `--version`.

## State and logs

- macOS, and your user on Linux: `~/.local/state/omarchy-mac-bootstrap/`
- root on Linux: `/var/lib/omarchy-mac-bootstrap/` (readable by your user later)

`state.env` holds non-secret progress and choices; `logs/` has one readable
log per day (commands, exit codes, checksums, choices); `downloads/` keeps each
fetched upstream script for provenance. Override with `OMB_STATE_DIR`.

## Files between macOS and Linux

macOS stays on APFS, which Linux cannot write reliably, so this tool never
tries. Use Git, a network share, or cloud sync for projects. If you want a
shared partition anyway, the planner can leave space for an exFAT area and
write a post-install plan; see [docs/STORAGE.md](docs/STORAGE.md).

## Recovery and uninstall

- Something stopped halfway: [docs/RECOVERY.md](docs/RECOVERY.md).
- Something looks wrong: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md),
  and `./omarchy-bootstrap doctor`.
- **Uninstall** is manual, from macOS, following the
  [Asahi partitioning cheatsheet](https://asahilinux.org/docs/sw/partitioning-cheatsheet/)
  exactly: delete the stub container, the EFI partition and the Linux
  partition, then grow macOS back. Never touch `Apple_APFS_Recovery`. Set macOS
  as the startup disk first.

## Upstream targets

| | Value |
| --- | --- |
| Asahi Alarm bootstrap | `https://asahi-alarm.org/installer-bootstrap.sh` |
| Asahi installer checked against | v0.9.2 |
| OS to choose | `Asahi Alarm Minimal (BTRFS)` |
| Omarchy Mac | `omarchy-mac/omarchy-mac` (GitHub home `omacom/omarchy-mac`), branch `quattro` |
| Omarchy checked against | 4.0.3rc4 |

All of these live in `lib/sources.sh`. `./omarchy-bootstrap sources --check`
reports drift; nothing switches automatically. What was read where, and what
differs from the commonly quoted steps: [docs/UPSTREAM.md](docs/UPSTREAM.md).

## Development

```bash
tests/run.sh             # syntax, shellcheck (if installed), every test
tests/run.sh storage     # one file
./omarchy-bootstrap --dry-run     # real machine, nothing changes
OMB_FIXTURE=$PWD/tests/fixtures/mac-m1pro-1tb-roomy ./omarchy-bootstrap --dry-run
```

Design and boundaries: [SPEC.md](SPEC.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[MILESTONES.md](MILESTONES.md).
