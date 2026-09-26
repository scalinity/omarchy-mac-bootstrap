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

**What the handoff holds `installer_data.json` to** (`osinstall.py`
`min_size`, `partition_disk`, v0.9.2): the template's partitions are created
in order, each at `align_up(psize(size))`, and every one with a truthy
`expand` also receives `total_size - min_size`, the whole remainder. The
stub is not in the manifest (`main.py` `STUB_SIZE`, pinned by the installer
version). So the check (`storage_contract_ok`, reading the JSON with Apple's
`plutil`) requires the chosen template named exactly once, exactly two
partitions, the first `type` `EFI` with `size` exactly `524288000B` and no
`expand` key, the second `type` `Linux` with `expand` `true` and a `size` in
bytes whose installer minimum (`STUB_SIZE` + 2 x the aligned template, the
non-expert minimum at `main.py:313`) fits the planner's 54 GB. Other keys
(`format`, `volume_id`, `image`, `source`, …) do not change the layout and
are not checked. The live manifest, read on 2026-09-25, passes: the
Minimal (BTRFS) template is EFI `524288000B` (`format` `fat`), then Root
`2209614225B`, `expand` true.

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
| `/var/lib/omarchy/btrfs-migrate-done` | the encryption's finish service has run: written on a boot that got past the initramfs hook, which re-encrypts synchronously and drops to a shell on failure, after the service confirmed root is on dm-crypt |
| `cryptsetup luksDump <root partition>` with `online-reencrypt` | re-encryption still pending (root only) |

Upstream's own `root_is_encrypted` treats a `luksDump` that fails or prints
nothing as "encrypted" (its `grep` simply finds no flag), and its
`installed` marker is written after that check, so neither is proof that
the re-encryption finished. This tool reads the header itself as root and
accepts only a LUKS2 header (`LUKS header information`, `Version: 2`, a UUID,
`Data segments:`); as a user it relies on the finish marker, the one signal
readable without root (read at `quattro` `ba546a6`).
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

# Product expansion (designed, not implemented)

What the M14–M16 design relies on, where each fact was read, and what is
not yet verified. Verified: 2026-09-26. Facts that decide behaviour at run
time are checked again then (the registry's target checks, `sources
--check`); nothing here is a contract the code may assume without looking.

## Package inventories on macOS

Read at Homebrew 7.0.6 (tag `570982948a`, 2026-09-21), `Library/Homebrew/`
unless noted; local install 6.0.19 compared read-only.

| Fact | Where |
| --- | --- |
| `brew bundle` is built in; `dump` writes `tap`, `brew`, `cask`, then `mas`, `vscode`, `go`, `cargo`, `uv`, `flatpak`, `winget`, `krew`, `npm` lines; only requested formulae; every cask; `--file=-` is stdout | `bundle/dumper.rb`, `bundle/extensions.rb`, `bundle/brew.rb`, `bundle/cask.rb`, `bundle/brewfile.rb` |
| `bundle` is an auto-update command (a `git fetch` when `FETCH_HEAD` is a day old, unless `HOMEBREW_NO_AUTO_UPDATE`); every Ruby command may fetch and write the API cache; analytics unless `HOMEBREW_NO_ANALYTICS`; the dump runs `code`/`cursor`, `mas`, `go`, `cargo install --list`, `uv tool list`, `npm list -g`, `kubectl-krew` — which is why the scanner never runs it | `utils/auto-update.sh`, `brew.rb`, `api.rb`, `utils/analytics.rb` |
| formula receipts `Cellar/<name>/<version>/INSTALL_RECEIPT.json`: `installed_on_request`, `runtime_dependencies`, `source.tap`; `installed_as_dependency` removed 2026-04-27 (`916f6a1711`); cask receipts `Caskroom/<token>/.metadata/INSTALL_RECEIPT.json` with `uninstall_artifacts` (since 4.3.11); receipts are internal (`@api internal`), so the adapter's contract is versioned and a shape outside it is `unknown` | `tab.rb`, `tab/tab.rb`, `cask/tab.rb`; <https://docs.brew.sh/rubydoc/> |
| `cargo install --list` creates `.crates.toml`/`.crates2.json` when missing; `uv tool list` writes a lock and cache; `npm ls` checks the registry unless `--no-update-notifier`; `go version -m` may fetch a toolchain unless `GOTOOLCHAIN=local` | observed in a scratch directory; <https://go.dev/doc/toolchain> |
| file locations for npm (Homebrew, nvm, fnm, Volta, mise prefixes), pnpm, bun, cargo, cargo-binstall, uv (`uv-receipt.toml`), pipx (`pipx_metadata.json`), Go, mise, asdf, VS Code/VSCodium/Cursor extensions and settings | <https://docs.npmjs.com/cli/v11/configuring-npm/folders>, <https://pnpm.io/10.x/settings>, <https://doc.rust-lang.org/cargo/guide/cargo-home.html>, <https://docs.astral.sh/uv/reference/storage/>, <https://mise.jdx.dev/directories.html>, <https://asdf-vm.com/manage/configuration.html>, <https://code.visualstudio.com/docs/configure/settings> |
| protected folders: Desktop, Documents, Downloads, iCloud Drive and removable volumes prompt; Mail, Messages, Safari need Full Disk Access; other apps' containers are denied without a prompt on macOS 27 | <https://support.apple.com/guide/security/controlling-app-access-to-files-secddd1d86a6/web>, macOS 27 release notes |
| Time Machine restore uses Migration Assistant; the login keychain transfers, "this device only" items do not work elsewhere | <https://support.apple.com/en-us/102551>, <https://support.apple.com/guide/keychain-access/kyca1121/mac> |

## Omarchy 4 on Omarchy Mac

Read at `omacom/omarchy-mac` `quattro` `ba546a61f881c1fe9d79d75ec050eab048b8cb63`
(version `4.0.3rc4`) and `omacom/omarchy` `quattro`
`7b336b1b0da722e7bb864a7136f91e784ef731bf` (tags `v4.0.3` `0534987`,
`v4.0.4` `c668141`); paths in the Mac repository unless noted.

| Fact | Where |
| --- | --- |
| `omarchy-pkg-add` filters with `pacman -Q \|\| pacman -Si`, skips what it cannot find, exits 0 when nothing is left, then checks `pacman -Q` | `bin/omarchy-pkg-add` |
| pacman's `-Si` searches every sync database, an unqualified `-S` skips `Usage = Sync` repositories; Omarchy Mac lists `[omarchy]` with `Usage = Sync` and installs from it by qualified name | pacman `src/pacman/sync.c`, `lib/libalpm/deps.c`; `default/pacman/pacman-edge.conf`, `install/helpers/arm-package-sources.sh` |
| repositories: `[omarchy]` (OPR, `pkgs.omarchy.org/edge/$arch`), `[omarchy-aarch64]` (GitHub releases `edge` and `rc`; `stable` answers 404; `SigLevel = Optional TrustAll`), `[asahi-alarm]`, Arch Linux ARM `core`, `extra`, `alarm`, `aur`; the edge channel on aarch64 | `default/pacman/pacman-edge.conf`, `install/post-install/pacman.sh`; fetched 2026-09-26 |
| Bash is the login shell; `~/.bashrc` sources `/usr/share/omarchy/default/bash/rc` and is the documented place for personal additions, not overwritten by updates; `OMARCHY_PATH` is `/usr/share/omarchy`; `PATH` puts `~/.local/share/mise/shims` before `~/.local/bin` | `bin/omarchy-mac-setup`, `default/bashrc`, `default/bash/env-bootstrap` (lines 33–40), `manual/31-dotfiles.md` |
| seeded into `~/.config` and user-owned afterwards: alacritty, btop, foot, ghostty, git, herdr, hypr, kitty, lazygit, omarchy, opencode, tmux, `starship.toml` and more; `omarchy-reinstall-configs` copies `/etc/skel` over the home without a backup; theme state in `~/.local/state/omarchy` | `config/`, `docs/file-layout.md`, `bin/omarchy-reinstall-configs` |
| foot is the default terminal; Ghostty only from `[omarchy-aarch64]`; Flatpak not installed by default; `jq`, `git`, `curl`, `openssl` and `mise` (`mise-bin` 2026.9.12) present after install; `visual-studio-code-bin` only in the `Usage = Sync` repository (issue #297) | `manual/15-terminal.md`, `install/omarchy-base.packages` (line 80) |
| Omarchy's firewall denies incoming connections (`ufw default deny incoming`); setup locks root's password and removes `alarm` from `wheel`, but neither changes `alarm`'s password nor disables `sshd`; `omarchy-setup-security-sshd` writes a key-only drop-in, checks it with `sshd -t` and `sshd -T -C` | `install/config/firewall.sh` (line 23), `bin/omarchy-mac-setup` (lines 742–801), `bin/omarchy-setup-security-sshd` (lines 148–188), `migrations/1788124236.sh` |
| `/root` survives the in-place encryption | `bin/omarchy-system-btrfs-migrate` |

## Omarchy's agent wrappers

Read at the same commits, and mise `v2026.9.12`
(`1698dd8ff8308b6e39fee8ce1537ddf93f246a2a`, the version Omarchy installs).

| Fact | Where |
| --- | --- |
| `install/user/mise.sh` writes a wrapper in `~/.local/bin` for codex, claude, crush, agy, gh, copilot, opencode, playwright, pi, omp, grok, ghui, hunk, hey and ori; generated under a throwaway home, Claude Code's is 123 bytes: `export MISE_MINIMUM_RELEASE_AGE=0`, `mise use -g --quiet "claude" \|\| exit 1`, `exec mise x "claude" -- "claude" "$@"`; nothing is downloaded until it first runs | `bin/omarchy-mise-install` (lines 21–27), `install/user/mise.sh`, `manual/17-ai.md` |
| the wrapper checks nothing first: every run runs `mise use -g`; after the first, the command name reaches mise's shim, earlier on `PATH`; a wrapper is at most 1 024 bytes, and four older wrapper shapes may still be on disk | as above; `migrations/1787573629.sh` |
| `mise use -g claude` without a version requests `latest`: with a version installed it picks the newest installed one without the network, otherwise resolves over the network; it then rewrites `~/.config/mise/config.toml` on every call and writes `claude = "latest"`, replacing a pinned version | mise `src/cli/use.rs` (lines 277, 298–318, 352–374), `src/toolset/tool_version.rs` (lines 739–745), `src/config/config_file/mise_toml.rs` (lines 1491–1498) |
| installed versions live in `~/.local/share/mise/installs/<tool>/<version>/` (skip links and a real `latest` folder, left by a 2026.4 regression); shims in `~/.local/share/mise/shims/`; global selection in `~/.config/mise/config.toml` and `conf.d/*.toml` beside it, or `MISE_GLOBAL_CONFIG_FILE`; `mise ls` and `mise where` resolve the toolset and may reach the network | mise `src/backend/backend_arg.rs` (lines 280–289), `src/runtime_symlinks.rs` (line 427), `src/config/mod.rs` (lines 3030–3035), `src/cli/ls.rs` (line 373) |
| `omarchy-default-agent <name>` accepts an allowlisted name, installs a missing agent with `mise use -g` inside a new graphical terminal, writes `~/.config/omarchy/defaults/agent` after a successful install, and always ends by `exec omarchy-agent`; without arguments it prints the current default | `bin/omarchy-default-agent` (lines 13–81) |
| `omarchy-agent` treats `command -v` success as installed; launch modes: `claude --permission-mode auto`, `codex --approve-for-me`, `opencode --auto`, `crush --yolo`, `copilot --allow-all`, and bypass modes for others; from `$HOME` it starts in `~/Work` | `bin/omarchy-agent` (lines 36–123) |
| Omarchy links its own skill into `~/.{agents,claude,codex,pi/agent}/skills/` | `bin/omarchy-provision-user`, `docs/file-layout.md` |

## The Asahi image and OpenSSH

| Fact | Where |
| --- | --- |
| "Asahi Alarm Minimal (BTRFS)" is `asahi-base-btrfs.zip`, built from Arch Linux ARM's root filesystem by the base scripts only (the desktop script's `userdel -r alarm` does not run); nothing disables `sshd` | `installer_data.json` (fetched 2026-09-26); `asahi-alarm/asahi-alarm-builder` `58cc158c7fda3ef6aeae36606f84a63b4b0867e7` `build.sh` (lines 5, 48, 172–174), `scripts/base/10-base-packages.sh` |
| the root filesystem (`ArchLinuxARM-aarch64-latest.tar.gz`, md5 `23eec86365b24f7913c403e8f4e8719b`, 2026-08-05) holds Bash 5.3.15, gawk 5.4.1, coreutils 9.11 (`head`, `tail`, `tr`, `od`, `wc`, `sync`, `mktemp`, `sha256sum`), OpenSSL 3.6.3, iproute2 (`ss`), `readelf`, `objdump`, openssh 10.4p1 with `sshd.service` enabled and no host keys (made at first boot), `alarm` (uid 1000, in `wheel`) and `20-systemd-userdb.conf` | its pacman database and file list, read 2026-09-26 |
| Arch Linux ARM documents `root`/`root`, `alarm`/`alarm` and `sshd` started | <https://archlinuxarm.org/platforms/armv8/generic> |
| Arch's (and Arch Linux ARM's, identical) `sshd_config` starts with `Include /etc/ssh/sshd_config.d/*.conf`; `99-archlinux.conf` sets `KbdInteractiveAuthentication no`, `UsePAM yes`; `PasswordAuthentication` stays at its default, yes | `archlinux/packaging/packages/openssh` `87ce57139f3b40e1fb20b85128fb5b10b9128f40` (10.5p1-1) `PKGBUILD` (lines 93–95, 159); the Arch Linux ARM package inspected |
| OpenSSH 10.5p1: `-t` checks the configuration and keys; `-T` prints the effective configuration, `-C` sets `addr`, `user`, `host`, `laddr`, `lport`, `rdomain` (and `invalid-user`), and an attribute left out makes a `Match` on it false; both need root (they load the host keys); the first value of a keyword wins; included files are read in name order; a satisfied `Match` overrides the global value; since 10.4 the dump's keywords are in mixed case | openssh-portable `V_10_5_P1` `b3f7344209832eea8ece447d871ea748767c444b` `servconf.c` (lines 893–897, 2649–2681), `sshd.c` (lines 1506, 1567–1745); sshd(8), sshd_config(5); release notes 10.4 |
| with `BatchMode=yes` the client never sends a password and fails with `Permission denied (<methods>)`, listing the server's methods for that account | openssh-portable `sshconnect2.c` (lines 405–414, 543, 2414), `auth2.c` |
| `sshd -f <file>` reads that configuration instead of `/etc/ssh/sshd_config`; `-D` keeps it in the foreground; `-E <file>` sends its log there; it refuses to run unless started by an absolute path; `Match` and `Include` are its only conditional and indirection keywords, so a configuration without either has one effective policy | openssh-portable `V_10_5_P1` `sshd.c` (lines 1350, 1364, 1370, 1455), `servconf.c` (lines 517–518) |
| `AuthenticationMethods publickey` lets only public-key authentication complete a login; methods it lists should also be enabled | sshd_config(5); `auth2.c` |

## Platform tools the core relies on

| Fact | Where |
| --- | --- |
| admission uses `head -c`, `wc -c`, `tr -d`, `tail -c`, `od`, and `awk` in the C locale: BSD `awk` 20200816 on stock macOS, gawk on the image and Omarchy | this Mac; the image's package list above |
| GNU `sync FILE` flushes that file (and a directory given as an argument); macOS's `sync` ignores arguments and flushes everything | coreutils 9.11 `src/sync.c`, `NEWS` 8.24; `apple-oss-distributions/system_cmds` `408bba7453608006b89772db185defbac8fe2fd0` `sync/sync.c`; `/bin/sync /nonexistent` exits 0 on macOS 27.0 |
| Bash's `noclobber` refuses `>` onto an existing regular file or any link and creates a new file with `O_EXCL`; `>|` and `>>` bypass it; an existing FIFO or device is opened without `O_EXCL` | Bash `redir.c` `noclobber_open` (Apple bash-3.2 `51bf3fc6f26e9517c3a2e4bc3d208f9b39b87178`, lines 525–548; bash-5.3); *Experiments* |
| GNU `mv -n` refuses to replace an existing destination atomically where the kernel offers `renameat2` with `RENAME_NOREPLACE` (since 8.30); `--update=none-fail` (since 9.5) does the same and exits with failure when the destination exists; the image and Omarchy ship 9.11 | coreutils `NEWS` (8.30, 9.5) |
| a boot session's identity: `/proc/sys/kernel/random/boot_id` on Linux; `sysctl -n kern.bootsessionuuid` on macOS (a UUID, read on this Mac); a process's start time: `ps -p <pid> -o lstart=` on both, as the baseline's `_proc_started` reads it | `lib/state.sh` (line 220); this Mac |

## aarch64 availability

| Fact | Where |
| --- | --- |
| Arch Linux ARM databases at `http://mirror.archlinuxarm.org/aarch64/<repo>/<repo>.db` (gzip; `extra` 10.6 MB, 12,929 packages); HTTPS fails certificate validation, no `.db.sig`; `%PROVIDES%` in a separate `depends` file | fetched 2026-09-26; archlinuxarm issue #400 |
| Asahi Alarm `https://github.com/asahi-alarm/asahi-alarm/releases/download/aarch64/asahi-alarm.db`; OPR `https://pkgs.omarchy.org/{edge,stable}/aarch64/omarchy.db` (zstd, provides in `desc`); `[omarchy-aarch64]` `…/releases/download/{edge,rc}/omarchy-aarch64.db` | fetched 2026-09-26 |
| `pacman -Si`, `-Sl`, `-Ss`, `-Sp` need no root; `-Si` matches names only; `-Sp --print-format '%r/%n %v %a'` follows provides | pacman `src/pacman/util.c`, `sync.c` |
| the AUR's RPC has no architecture field; `.SRCINFO` does | <https://aur.archlinux.org/rpc/v5/info>; <https://aur.archlinux.org/cgit/aur.git/plain/.SRCINFO> |
| Flathub's summary API lists `arches` | <https://flathub.org/api/v2/summary/org.mozilla.firefox> |
| `mise lock --platform linux-arm64` records a platform URL without installing, skips (exit 0) when no artifact exists; mise's 24-hour release age makes `latest` time-dependent; `compile=false` settings forbid source builds | <https://mise.jdx.dev/cli/lock.html>, <https://mise.jdx.dev/dev-tools/backends/>; run from macOS against mise v2026.9.14 |
| prebuilt linux-arm64 runtimes: Node, python-build-standalone, Go, rustup, Bun, Deno, Temurin, jdx/ruby; Arch Linux ARM has nodejs, python, go, rust, ruby, zig, JDKs, uv, pipx, cargo-binstall, flatpak but not mise, bun or deno | the projects' release indexes; the `extra` database |
| 16 KiB pages: `LOAD` segments aligned below `0x4000` fail before start; jemalloc built for 4 KiB pages aborts; Electron before Chromium 134 crashed; x86_64 runs only through FEX in muvm | <https://asahilinux.org/docs/sw/broken-software/>; electron issue #45560 |
| Homebrew supports ARM64 Linux, but Arch Linux ARM is outside its first tier | <https://github.com/Homebrew/brew/blob/main/docs/Support-Tiers.md> |

## AI coding tools

| Fact | Where |
| --- | --- |
| Claude Code 2.1.283: `https://claude.ai/install.sh` (redirecting to `downloads.claude.ai/claude-code-releases/bootstrap.sh`, SHA-256 `3a68d340…aa766a944` on 2026-09-25) checks the binary's SHA-256 from its manifest and installs `~/.local/bin/claude` → `~/.local/share/claude/versions/`; it refuses to run under `sudo` (`SUDO_USER` set) unless `CLAUDE_INSTALL_ALLOW_SUDO` is set, and allows real root; it does not check memory first, and says it needs about 512 MB when the install is killed; run from `/` it scans the whole filesystem; `--dangerously-skip-permissions` is refused as root; the supported systems listed are macOS 13+, Ubuntu 20.04+, Debian 10+, Alpine 3.19+ | `bootstrap.sh` (lines 20, 39, 249–251); <https://code.claude.com/docs/en/setup>, <https://code.claude.com/docs/en/troubleshoot-install>, <https://code.claude.com/docs/en/permission-modes> |
| Claude Code layout (`settings.json`, `CLAUDE.md`, `rules/`, `skills/`, `agents/`, `commands/`, `plugins/` with `installed_plugins.json` and `known_marketplaces.json`, `projects/<encoded path>/` sessions, `history.jsonl`; `~/.claude.json` with user-scope `mcpServers`, per-project state and account metadata); `claude mcp add-json … --scope user`; `claude mcp list` connects to every server; `${VAR}` expands in user-scope servers; `AGENTS.md` read only without a `CLAUDE.md`; sign-in without a browser by copying a URL and pasting a code | <https://code.claude.com/docs/en/claude-directory>, <https://code.claude.com/docs/en/mcp>, <https://code.claude.com/docs/en/memory>, <https://code.claude.com/docs/en/authentication> |
| Codex 0.157.1: `https://chatgpt.com/codex/install.sh` (musl build, checksums checked, `CODEX_NON_INTERACTIVE=1`); `auth.json` is a file on macOS too; skills in `~/.agents/skills`; `codex login --device-auth`; `codex mcp list` starts no stdio server; `codex mcp add --url` may start a browser sign-in | <https://github.com/openai/codex>, <https://learn.chatgpt.com/docs/auth>, <https://learn.chatgpt.com/docs/extend/mcp> |
| OpenCode 1.18.32 (`anomalyco/opencode`): its installer verifies nothing; `~/.config/opencode/opencode.json` (`mcp`, `agent`, `command`, `plugin`, `permission`), `{env:VAR}`; credentials in `~/.local/share/opencode/auth.json`; `opencode mcp list` starts every local server; plugins run code | <https://opencode.ai/docs/config>, <https://opencode.ai/docs/plugins> |
| Crush's `crushrc` runs in a shell and `$(…)` in `crush.json` runs at load | <https://github.com/charmbracelet/crush> |
| the Bun-built binaries (Claude Code, OpenCode) are 64 KiB-aligned; Bun's own 16 KiB check is open (oven-sh/bun #17627); Codex links jemalloc 5.3.1, whose aarch64 default suits 16 KiB | binaries inspected with `llvm-objdump`; <https://github.com/oven-sh/bun/issues/17627> |

## Codex's configuration file

Read at `openai/codex` `rust-v0.157.1`
(`36650394c5b38c2990ccf2a3457165ca3e9d9726`), which uses `toml_edit`
0.24.0 and `toml` 0.9.11, both TOML 1.1; documentation at
`learn.chatgpt.com/docs/config-file/` (config-reference, config-advanced,
config-sample) as fetched on 2026-09-26.

| Fact | Where |
| --- | --- |
| every writer edits the file in place with `toml_edit`, keeping comments and layout, and writes it atomically | `codex-rs/core/src/config/edit.rs` |
| `codex mcp add` writes `[mcp_servers.<name>]` tables: `command`, a single-line `args`, `env` as a sub-table `[mcp_servers.<name>.env]` with sorted keys, `env_vars` entries as strings or `{ name, source }`, timeouts as floats; server names may hold `:`, `@`, `/`, `.`, and are then quoted; it replaces a server's table wholesale, dropping keys Codex does not model | `core/src/config/edit/document_helpers.rs`, `edit.rs` (lines 220, 431–477), `cli/src/mcp_cmd.rs` (line 1079), `edit_tests.rs` (line 1052) |
| strings are written basic when possible, else literal, else multi-line (only with a newline); keys bare when possible, else quoted; arrays on one line; Codex never writes dotted keys but keeps those the person wrote; it also writes `[[skills.config]]`, arrays of inline tables, integers for times and quoted keys containing dots | `toml_writer` 1.0.6 `crates/toml_writer/src/string.rs`; `edit.rs` |
| documented keys include `model`, `model_provider`, `model_reasoning_effort`, `model_providers.<id>`, `approval_policy` (`on-request`, `never`, granular; `untrusted` is refused at start), `sandbox_mode`, `notify`, the `mcp_servers.<id>` keys, `projects.<path>.trust_level`, `plugins."<p>@<m>".enabled`, `features`, `shell_environment_policy`, `tui`, `history`; an inline `bearer_token` is refused | config-reference.md; `core/src/config/mod.rs` (line 227), `config/src/mcp_edit.rs` (line 33) |
| since 0.134.0 profiles are separate files `~/.codex/<name>.config.toml`; a top-level `profile` stops Codex at start | config-advanced.md; `core/src/config/mod.rs` (line 3344), `config/src/loader/mod.rs` (lines 299–319) |
| unknown keys are ignored unless `--strict-config`; syntax errors and wrong types stop Codex | `config/src/config_toml.rs` (line 165), `config/src/loader/layer_io.rs` (line 162) |
| the documentation's examples use inline `env = { … }`, sub-tables, literal strings, multi-line arrays of inline tables and quoted keys with dots | config-sample.md, mcp.md |

## Ratatui and distribution

| Fact | Where |
| --- | --- |
| Ratatui 0.30.2 (2026-06-19), MSRV 1.88; applications depend on `ratatui` and reach Crossterm 0.29 through `ratatui::crossterm` | <https://crates.io/api/v1/crates/ratatui>, `ratatui/src/lib.rs` at `ratatui-v0.30.2` (`e665c36c`) |
| `try_init()` installs a restoring panic hook, raw mode and the alternate screen; `try_restore()` leaves both and does not show the cursor; neither touches mouse, paste or keyboard modes | `ratatui/src/init.rs` (lines 365, 397, 554) |
| the official way to run a child: leave the alternate screen, raw mode off, run, raw mode on, enter, `terminal.clear()`; a thread still reading input steals the child's replies | <https://ratatui.rs/recipes/apps/spawn-vim/> |
| raw mode clears `ISIG` (Ctrl-C is a key); Crossterm saves the terminal settings when raw mode is enabled and restores exactly those; the terminal is stdin if it is one, else `/dev/tty` | Crossterm 0.29 `src/terminal/sys/unix.rs` (lines 30, 108–168), `src/terminal/sys/file_descriptor.rs` |
| a caught signal is reset to default by `exec`, an ignored one stays ignored | POSIX `exec` |
| Rust's `Command` duplicates only 0, 1 and 2 into the child and closes nothing else; everything the standard library opens is close-on-exec; a `pre_exec` closure (with `dup2`) places another descriptor and forces fork and exec | Rust 1.98.1 `library/std/src/sys/process/unix/unix.rs` (lines 283–297, 470, 705–719), `sys/fs/unix.rs` (line 1382), `sys/pipe/unix.rs` (line 28), `os/unix/process.rs` |
| `TestBackend` with `assert_buffer_lines`; `insta` snapshots carry no colour; PTY testing for the event loop and teardown | <https://ratatui.rs/recipes/testing/snapshots/> |
| Crossterm 0.29.0's `NO_COLOR` handling resets bold and reverse (fixed, unreleased); Ratatui 0.30.2 mis-positions text after a wide character (fixed, unreleased); no ASCII border set is shipped | crossterm PR #1069; ratatui issues #2651, #2652 |
| the Linux console: at most 512 glyphs; a normal-intensity colour cancels bold; the alternate screen exists only since August 2025 (`23743ba64709`) | `drivers/tty/vt/vt.c` |
| native arm64 runners `macos-latest` and `ubuntu-24.04-arm`; Ubuntu 24.04 has glibc 2.39, Arch Linux ARM 2.43 (`glibc` 2.43+r22), and its `base` brings `libgcc_s.so.1` through `libgcc` | <https://docs.github.com/en/actions/reference/runners/github-hosted-runners>; packages.ubuntu.com noble libc6; <https://archlinuxarm.org/packages/aarch64/libgcc> |
| a Rust binary built on Ubuntu 24.04 for `aarch64-unknown-linux-gnu` needs `/lib/ld-linux-aarch64.so.1`, `libc.so.6` and `libgcc_s.so.1`, and glibc symbol versions up to `GLIBC_2.39` (from `std::process`'s `pidfd_spawnp`), all required; Rust's glibc 2.17 floor holds only for a build against an old glibc | an inspected Codex `rust-v0.157.1` aarch64 artifact (`readelf`, `objdump -T`); Rust `library/std/src/sys/pal/unix/weak/weak_linkage.rs`; glibc `elf/dl-version.c` |
| aarch64 linkers default to 64 KiB page alignment | binutils `bfd/elfnn-aarch64.c`, lld `ELF/Arch/AArch64.cpp` |
| Rust's default macOS arm64 deployment target is 11.0; `MACOSX_DEPLOYMENT_TARGET` raises it and it becomes `LC_BUILD_VERSION`'s `minos` | Rust `compiler/rustc_target/src/spec/base/apple/mod.rs` (line 332), `compiler/rustc_session/src/session.rs` (lines 909–940) |
| arm64 macOS binaries are signed ad hoc by the linker; `curl` sets no quarantine attribute, browsers do | Apple's Big Sur universal-apps release notes; Apple developer forums thread 706442 |
| artifact attestations record repository, workflow and commit, SLSA build level 2, verified with `gh attestation verify` | <https://docs.github.com/en/actions/concepts/security/artifact-attestations> |

## Experiments

Run on this Mac on 2026-09-26 (macOS 27.0, `/bin/bash` 3.2.57, Homebrew Bash
5.3.20, BSD `awk` 20200816, LibreSSL 3.3.6), outside the repository.

- **Bash's `read` normalises before any check.** `IFS= read -r line`, then
  splitting on TAB into an array: a doubled, a leading and a trailing TAB
  give the same fields as the canonical line, on both shells; an embedded
  NUL truncates the line on 3.2 and is dropped on 5.3, so the 5.3 fields
  equal the canonical ones. CR, non-ASCII, ESC and DEL pass through.
- **Admission catches all of them first.** The steps of docs/PROTOCOL.md →
  §2 over 21 cases, on both shells: canonical and `%20` admitted; refused
  with the right reason — doubled, leading and trailing TAB; NUL, CR,
  non-ASCII, ESC, DEL; no final LF; a blank line; `%2f`, `%4`, a raw space,
  a raw `=`; `%41`; `%00`; an upper-case key; 70 KB against 64 KiB; a 17 KB
  line against 16 KiB.
- **The qualification stream** (docs/QUALIFICATION.md → *The stream*):
  every reference value there was produced with `openssl enc
  -aes-256-ctr -nosalt` over `head -c N /dev/zero`, every `PIPESTATUS` 0;
  the MiB at offset 2³² generated from its counter equals the same MiB cut
  from the full stream; the full stream took 96 s.
- **`noclobber`** on `/bin/bash` 3.2.57 and Bash 5.3.20: `>` onto a new file
  succeeds; onto an existing file, a dangling link, or a link to a file it
  fails; `>|` and `>>` succeed.

## Not verified yet

Split by what can answer it (docs/DECISIONS.md → *Resolved review questions*, O9). Nothing is left for
the Mac that source, package metadata or a CI runner can answer.

### Before a feature's gate closes

| Fact | How | Gate |
| --- | --- | --- |
| a stable Rust toolchain gives the same loader, libraries and glibc symbol versions as the inspected artifact; C dependencies follow `MACOSX_DEPLOYMENT_TARGET`; the stripped macOS binary keeps its ad hoc signature | `frontend-compat-linux`, `frontend-compat-macos` on the first build | M14 gate 1 |
| the Asahi kernel in `asahi-alarm` includes the console alternate screen (`23743ba64709`) | the `linux-asahi` package's version and source | M14 gate 1 |
| the delivered `asahi-base-btrfs.zip` has the root filesystem's packages, `sshd` enabled and `alarm` present, as inferred from its builder | list the image's package database and enabled units | M15-C |
| Codex, OpenCode, Gemini CLI and Crush refuse or change behaviour as root | their source | M15-C |
| `claude install` refuses root in any case beyond bypass mode; its working-directory scan | an install as root in a container on the aarch64 runner | M15-C |
| the rescue server on the image: `sshd -D -f` under `systemd-run`, `UsePAM no` with Arch's build, the `sshd-session` and `sshd-auth` helpers it starts, and `ssh -o StrictHostKeyChecking=yes` against a prepared host-key file | a run in a container of the image's root filesystem on the aarch64 runner | M15-C |
| `renameat2` with `RENAME_NOREPLACE` on btrfs, ext4, xfs and tmpfs in the Asahi kernel | the kernel source of the `linux-asahi` version | M15-A |
| which mise backend Claude Code resolves to on linux-arm64, the executable's path under `installs/claude/<version>/`, and whether mise reaches the network beyond version resolution | mise's source and a run in a container on the aarch64 runner | M15-B |
| how mise quotes keys for tools outside its registry in `config.toml` | mise's source | M15-B |
| `omarchy-pkg-add` with a repository-qualified target from a `Usage = Sync` repository | its source and pacman's | M15-B |

### Only the Mac can show (M17)

The Asahi kernel's 16 KiB pages under the frontend, Claude Code, OpenCode
and Codex; the Linux console's glyphs and whether any frame is left behind
after a handoff; the image's `sshd -T` on its first-boot host keys; the
installers' behaviour on this disk, and everything else in
docs/QUALIFICATION.md → *Real-hardware qualification (M17)*.
