# Upstream

What this repository targets, where each fact was read, and what differs from
the commonly quoted install steps. The values the code uses live in
`lib/sources.sh`; `./omarchy-bootstrap sources --check` compares them with
upstream on demand.

Verified: 2026-09-25.

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

## Asahi installer (v0.9.2)

Read at `AsahiLinux/asahi-installer` tag v0.9.2 (`dffbb38`). The Alarm fork
`asahi-alarm/asahi-alarm-installer` v0.9.2 (`3cfef52`) and the tarball
`https://asahi-alarm.org/installer-v0.9.2.tar.gz` ship byte-identical
`src/*.py`; the fork differs only in CI, its bootstrap URLs and a redirect fix.

| Constant | Value | Where | Effect |
| --- | --- | --- | --- |
| `MIN_FREE_OS` | 38 GB | `main.py:14` | free space kept in the macOS container for upgrades (1 GB under 150 GiB disks or expert mode; the planner always keeps 38 GB) |
| `STUB_SIZE` | 2 499 805 184 B | `main.py:11` | `align_down(2.5 GB, PART_ALIGN)`: the "stub macOS" APFS container |
| EFI partition | 524 288 000 B | `installer_data.json` | the Minimal (BTRFS) template's `"size": "524288000B"` |
| Root template | 2 209 614 225 B, `expand` | `installer_data.json` | grows to fill the New OS size |
| `MIN_INSTALL_FREE` | 10 GB | `main.py:19` | a resize must free more than this |
| `PART_ALIGN` | 1 MiB | `main.py:9` | resize answers align **up**, New OS size aligns **down** |
| `FREE_THRESHOLD` | 16 MiB | `diskutil.py:21` | smaller gaps are not listed |
| smallest offered gap | 7 969 177 600 B | `main.py:333` | stub + 2 x template (Minimal, non-expert) |
| overhead warning | > 16 GB | `main.py:840` | `MinimumSizePreferred − align_up(used + 38 GB)`, usually Time Machine snapshots |

**How sizes are read** (`get_size`, `main.py:146-171`; `psize`, `util.py`):
a bare number is **bytes**; `GB`/`MB` are SI; a suffix with `i` (`MiB`, `GiB`)
is binary; `N%` is a share of the total; `min`, and in the free-space flow
`max`. The tool therefore types every size as a whole number of MiB
(`711345MiB`), which neither alignment changes.

**Resize** (`action_resize`, `main.py:804-923`): minimum
`max(align_up(CapacityCeiling − CapacityFree + MIN_FREE_OS), MinimumSizePreferred)`;
the answer is aligned up; rejected below the minimum, at or above the total,
or when it frees `MIN_INSTALL_FREE` or less; then
`diskutil apfs resizeContainer <store> <bytes>` and the menu is shown again.

**Install into free space** (`action_install_into_free`, `main.py:327-364`;
`OSInstaller.partition_disk`, `osinstall.py:67-110`): gaps are listed one per
gap, named after the partition before them; one eligible gap is used
directly, several are offered by number. `max` is the whole gap; the answer
is aligned down; then `diskutil addPartition <gap predecessor> apfs <name>
2499805184` (stub, populated before anything else), `diskutil addPartition
<stub> %EFI% %noformat% 524288000`, and `diskutil addPartition <efi> %Linux%
%noformat% <rest>`. Each partition starts right after the one before it
(`man diskutil`: "immediately beyond the end (start + size)"). Separate gaps
are never combined.

**Exit status:** quitting at the menu, a caught error, a declined warning, a
refused repair and a finished install all exit 0 (`main.py:1213-1232`). Only
early guards exit non-zero. The exit status says nothing about what happened;
the tool re-reads the disk instead.

**Prompts, in order, on a stock disk:**

1. `Choose what to do:` — **r** *Resize an existing partition to make space for
   a new OS* (default when resizable), **f** *Install an OS into free space*
   (default when free space exists), **q** quit. Also **p** (repair an
   incomplete install), **m** (upgrade m1n1), **v** (rebuild vendor firmware),
   **7** (*Fix macOS 27 boot picker compatibility*, offered for a stub whose
   system volume is not marked bootable).
2. Resize: `Enter the new size for your existing partition:` → **the new macOS
   size**. After it, the menu returns with **f** as the default.
3. `Choose an OS to install` → `Asahi Alarm Minimal (BTRFS)`.
4. `New OS size` (default `max`) → total Linux allocation including stub and
   EFI.
5. `OS name` → shown in Startup Options.
6. `bless --setBoot` on the new OS ("Setting the new OS as the default boot
   volume", `main.py:653-680`): **the new OS becomes the default startup
   disk**; macOS is chosen by holding power, or set back in Startup Disk.
7. Installer ends with a **shutdown** and a 7-step first-boot procedure (hold
   power, choose the new volume, macOS Recovery dialog, authenticate, follow
   the step-2 prompts). The Alarm bootstrap also asks whether to report the
   install.

**Difference from the commonly quoted flow:** there is no "Linux storage"
prompt during a resize install. The value to type first is the new macOS size;
the Linux size is the remainder, accepted with `max`, or typed exactly when
Shared storage follows it. The planner computes both.

The read-only query the installer uses for its floor,
`diskutil apfs resizeContainer <container> limits -plist`, runs without root and
takes no action; the planner uses it to predict the same minimum, and plans no
resize when it does not answer.

**macOS disk facts the planner reads** (`man diskutil`, macOS 27.0;
`diskutil info -plist` on an internal Apple SSD): partition offsets
(`PartitionMapPartitionOffset`, bytes) and GPT unique GUIDs (`DiskUUID`) come
only from `diskutil info -plist <partition>`; `diskutil list -plist` lists
partitions in disk order with `Size` and `DiskUUID` but no offsets. Apple SSDs
use 4096-byte blocks; the GPT's first usable block is 6 (24 576 B) and its
backup takes the last 20 480 B.

## Asahi installer: what an interrupted install leaves

Read at the same v0.9.2 source. The order of work decides what an
interruption leaves behind, so the tool classifies from the disk:

| Evidence on macOS | State | Repair (`p`) |
| --- | --- | --- |
| macOS container smaller than before a recorded launch, freed space free, no stub | resized only (quitting keeps a resize) | not applicable |
| a stub container, nothing after it | stopped while preparing the stub | refused |
| stub and EFI, no Linux root | stopped between partitions | refused |
| all three; stub with fewer than 4 volumes, or without `step2.sh`/`boot.bin` | first stage incomplete | refused: "The existing installation is missing files" (`main.py:435-438`) |
| all three; stub holds `.IAPhysicalMedia` and `SystemVersion-disabled.plist` | first stage complete, first boot (step 2) not run | offered |
| all three; `IAPhysicalMedia-disabled.plist` and `SystemVersion.plist` | step 2 has run | not needed |

Repair eligibility is `stub.py` `check_existing_install` (the four files on the
stub's system volume) and `main.py:1092-1120` (listed when the stub has a
version and its boot policy lacks `coih`). The stub's files are readable from
macOS only when its system volume is already mounted; the tool never mounts
it, and says "unverified" otherwise.

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

**What the setup does** (read at `omacom/omarchy-mac` `quattro` `e77295a`):
asks encrypt/username/hostname (skipped when passed as flags), keeps the
current console keymap unless `--keymap` is given, creates the user with sudo,
moves `/boot` onto the EFI partition, encrypts the root in place (passphrase
chosen at the console), installs Omarchy from `quattro` as the user, locks
root's password, and resumes itself on each boot through
`omarchy-mac-setup.service` on tty1. It refuses Omarchy 3 unless
`--allow-omarchy3`. It touches only the root partition and the EFI partition;
it never uses or grows unpartitioned space, and creates nothing under `/mnt`.

**Upstream state signals:**

| Signal | Meaning |
| --- | --- |
| `/etc/omarchy-mac-setup.conf` | guided setup in progress (0600, root only); removed on the boot after the marker is written |
| `/var/lib/omarchy-mac-setup/installed` | install finished (written after encryption has fully finished) |
| `/usr/share/omarchy/version` + `display-manager.service` as a symlink | installed, for installs before the marker (upstream also wants the `@factory` subvolume) |
| `omarchy-mac-setup.service` `activating` | running now (a oneshot unit is never `active`) |
| `/etc/omarchy-btrfs-migrate.conf` | in-place encryption staged; removed by its finish service |
| `/var/lib/omarchy/btrfs-migrate-done` | the encryption's finish service has run |
| `cryptsetup luksDump <root partition>` with `online-reencrypt` | re-encryption still pending (root only) |
| `/usr/local/bin/omarchy-mac-setup` | upstream's own copy; stays after the install |

Upstream keeps no log file: `/var/log/omarchy-mac-setup.log` is declared but
never written; the unit's output goes to tty1. `--status` reads the root-only
conf, so it works only as root; its banner carries colour codes.

**Post-install helpers this tool delegates to**, and what they do (read in the
`omarchy-mac/omarchy-mac` checkout Omarchy Mac installs, `quattro`):

| Helper | Does | Exit status |
| --- | --- | --- |
| `omarchy-pkg-add` | installs packages; skips any with no aarch64 build, with a warning | 0 when it skipped everything; non-zero when pacman fails |
| `omarchy-install-dev-env <lang>` | rust (rustup), python (mise + uv), node, go (mise), … | 0 for an unknown language, and when a download fails for python or rust |
| `omarchy-setup-security-sshd` | installs openssh, enables sshd, `ufw limit 22/tcp`, fetches keys from `github.com/<user>.keys` into the invoking user's `authorized_keys`, then turns password login off once a key is authorized | runs every step every time (sshd already running changes nothing); non-zero on a failed step |
| `omarchy-install-editor-vscode` | `visual-studio-code-bin` via `omarchy-pkg-add`, settings | effectively always 0 |
| `omarchy-setup-security-sudoless-docker` | adds the user to `docker` after a gum confirmation | 0 when declined |

Because several exit 0 without doing the job, each developer module checks
the machine afterwards (packages present, the tool on PATH or in
`~/.cargo/bin`/mise shims, `gh auth status`, sshd running, port 22 listening,
authorized keys) before reporting success. Omarchy's firewall is ufw with
`default deny incoming` and no rule for port 22.

Omarchy already installs Docker, `mise`, git, ripgrep, fd, fzf, jq, btop, tmux,
unzip, Neovim (LazyVim), and runs IP-based timezone detection.

## AI coding CLIs (ARM64 Linux)

| Tool | Path | Evidence |
| --- | --- | --- |
| Claude Code | `https://claude.ai/install.sh` (native arm64 build) | script maps `aarch64` → `arm64` |
| Codex | `npm install -g @openai/codex` | releases publish `codex-aarch64-unknown-linux-musl` |

Asahi kernels use 16 KiB pages; the tool reports the page size and asks you to
confirm each CLI starts after installing.
