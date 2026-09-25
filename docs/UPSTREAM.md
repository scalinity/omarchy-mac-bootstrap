# Upstream

What this repository targets, where each fact was read, and what differs from
the commonly quoted install steps. The values the code uses live in
`lib/sources.sh`; `./omarchy-bootstrap sources --check` compares them with
upstream on demand.

Verified: 2026-09-24.

## Asahi Alarm

| Item | Value | Read from |
| --- | --- | --- |
| Bootstrap | `https://asahi-alarm.org/installer-bootstrap.sh` | asahi-alarm.org |
| Installer version | `v0.9.2` | `https://asahi-alarm.org/latest` |
| OS list | `https://asahi-alarm.org/installer_data.json` | bootstrap `INSTALLER_DATA` |
| OS to choose | `Asahi Alarm Minimal (BTRFS)` | `installer_data.json` |
| Minimum macOS | 13.5 | bootstrap version guard, `MIN_MACOS_VERSION` |
| First login | `root` / `root` | asahi-alarm `manual-install.md`, Omarchy Mac README |

The bootstrap downloads the asahi-installer tarball named by `/latest` and runs
its `install.sh` under `sudo` and `caffeinate`. The installer asks for the macOS
admin password itself.

## Asahi installer (v0.9.2, `src/main.py`)

| Constant | Value | Effect |
| --- | --- | --- |
| `MIN_FREE_OS` | 38 GB | free space kept in the macOS container for upgrades |
| `STUB_SIZE` | 2.5 GB | the "stub macOS" APFS container that boots Linux |
| EFI partition | 524 288 000 B | from the OS template |
| `MIN_INSTALL_FREE` | 10 GB | smallest amount a resize may free |
| `PART_ALIGN` | 1 MiB | alignment of every size |
| overhead warning | > 16 GB | `MinimumSizePreferred − (used + 38 GB)`, usually Time Machine snapshots |

Units are SI (`psize`: base 1000; `GiB` style for base 1024).

**Prompts, in order, on a stock disk:**

1. `Choose what to do:` — **r** *Resize an existing partition to make space for
   a new OS* (default when resizable), **f** *Install an OS into free space*
   (default when free space exists), **q** quit. Also **p** (repair an
   incomplete install), **m** (upgrade m1n1), **7** (*Fix macOS 27 boot picker
   compatibility*, offered for existing installs).
2. Resize: `Enter the new size for your existing partition:` → **the new macOS
   size**, e.g. `744GB`, `50%`, or `min`. Minimum shown is
   `max(used + 38 GB, diskutil MinimumSizePreferred)`.
3. `Choose an OS to install` → `Asahi Alarm Minimal (BTRFS)`.
4. `New OS size` (default `max`) → total Linux allocation including stub and
   EFI.
5. `OS name` → shown in Startup Options.
6. Installer ends with a **shutdown** and a 7-step first-boot procedure (hold
   power, choose the new volume, macOS Recovery dialog, authenticate, follow
   the step-2 prompts).

**Difference from the commonly quoted flow:** there is no "Linux storage"
prompt during a resize install. The value to type first is the new macOS size;
the Linux size is the remainder, accepted with `max`. The planner computes both.

The read-only query the installer uses for its floor,
`diskutil apfs resizeContainer <container> limits -plist`, runs without root and
takes no action; the planner uses it to predict the same minimum.

## Asahi documentation

- FAQ: the installer always leaves 38 GB free for macOS upgrades.
- Partitioning cheatsheet: never delete `Apple_APFS_Recovery`; uninstall means
  deleting the stub container, EFI, and Linux partitions, then growing macOS.
- Device list + feature support: M1 and M2 families supported; M3 listed with
  display/USB work in progress; M4 listed as intended.

## Omarchy Mac

| Item | Value | Read from |
| --- | --- | --- |
| Canonical repository | `omacom/omarchy-mac` | GitHub API `full_name` |
| Documented repository | `omarchy-mac/omarchy-mac` (redirects) | README, `DEFAULT_REPO` |
| Branch | `quattro` (repository default) | GitHub API, `DEFAULT_REF` |
| Version on `quattro` | `4.0.3rc4` | `version` |
| Version on `main` | `3.8.2` (Omarchy 3 line) | `version` |
| Setup | `bin/omarchy-mac-setup` | README |
| Space | ≥ 50 GB, 100 GB recommended | README "Before you begin" |
| Devices | M1/M2 family | README |

**Setup flags used by this tool:** `--encrypt | --no-encrypt`, `--user`,
`--hostname`, `--keymap`, `--status`, `--resume`. Declared in the script's
`# omarchy:args=` header and parsed in `main()`.

**What the setup does:** asks encrypt/username/hostname (skipped when passed as
flags), keeps the current console keymap unless `--keymap` is given, creates the
user with sudo, moves `/boot` onto the EFI partition, encrypts the root in place
(passphrase chosen at the console), installs Omarchy from `quattro` as the user,
locks root's password, and resumes itself on each boot through
`omarchy-mac-setup.service` on tty1. It refuses Omarchy 3 unless
`--allow-omarchy3`.

**Upstream state signals:** `/etc/omarchy-mac-setup.conf` (in progress),
`/var/lib/omarchy-mac-setup/installed` (done), `/usr/share/omarchy/version`,
`/var/log/omarchy-mac-setup.log`, `/usr/local/bin/omarchy-mac-setup`.

**Post-install helpers this tool delegates to:** `omarchy-install-dev-env`,
`omarchy-install-editor-vscode`, `omarchy-setup-security-sshd`,
`omarchy-setup-security-sudoless-docker`, `omarchy-pkg-add`.

Omarchy already installs Docker, `mise`, git, ripgrep, fd, fzf, jq, btop, tmux,
unzip, Neovim (LazyVim), and runs IP-based timezone detection.

## AI coding CLIs (ARM64 Linux)

| Tool | Path | Evidence |
| --- | --- | --- |
| Claude Code | `https://claude.ai/install.sh` (native arm64 build) | script maps `aarch64` → `arm64` |
| Codex | `npm install -g @openai/codex` | releases publish `codex-aarch64-unknown-linux-musl` |

Asahi kernels use 16 KiB pages; the tool reports the page size and asks you to
confirm each CLI starts after installing.
