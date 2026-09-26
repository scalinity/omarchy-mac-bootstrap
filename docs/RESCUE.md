# Rescue and debugging

**Status: designed for M15; not implemented.** Tool facts verified on
2026-09-26 (docs/UPSTREAM.md → *AI coding tools*, *Omarchy Mac*).

If the install goes somewhere unexpected, the person should not have to
scrape logs with unfamiliar tools. As soon as the fresh system has a
network, an agent can be at their side, with a report of the machine and a
brief of this install. None of it is required, and none of it can block
the install: *Continue installation* is always on the rescue screen.

## When

- **On the fresh Asahi system**, as root, once the network is up and the
  frontend is running (docs/FRONTEND.md): the Linux continuation screen
  offers *Rescue tools*.
- **While Omarchy Mac runs**, it prints to tty1 across its own reboots;
  rescue runs on another console (Ctrl-Alt-F2, log in as root) until setup
  locks root's password at the end.
- **After Omarchy**, the everyday user has their own restored tools
  (docs/AI-TOOLS.md); `rescue` then offers the debug report and the brief,
  and removal of anything left from the rescue.

## The rescue screen

| Option | State shown |
| --- | --- |
| Start Claude Code | `unavailable` (why) · `available` · `installed` (version) · `signed-in` · `failed` (why) · `skipped` |
| Start Codex | the same |
| Start OpenCode | the same; unavailable unless a verified release is pinned (below) |
| Remote rescue over SSH | `unavailable` · `available` · `open` (the address to use) |
| Debug report | always available |
| Continue installation | always |

Drawing the screen runs nothing. An option's state comes from the machine
(the tool's files under `/root`, whether its sign-in file exists — never
read — the SSH drop-in and `sshd`'s state) and from **rescue's record**,
`/var/lib/omarchy-mac-bootstrap/rescue.omb`: what rescue installed and
changed, with each tool's version and whether it started, written when it
installed it. The record lists paths and versions, nothing secret, and the
everyday user can read it later.

**Unavailable** has a reason: not aarch64, no network to the vendor, less
than 512 MB of free memory, too little space in `/root`, or no verified
release to install. **Skipped** is the person's choice, recorded.

## Agents on this machine, as root

| Tool | Installed by | Where |
| --- | --- | --- |
| Claude Code (preferred) | the vendor's installer, `https://claude.ai/install.sh`, which checks the binary against its release manifest's SHA-256 | `/root/.local/bin/claude` |
| Codex | the vendor's installer, `https://chatgpt.com/codex/install.sh`, with `CODEX_NON_INTERACTIVE=1`; it checks the package against the release's checksums; a static musl build | `/root/.local/bin/codex` |
| OpenCode | its installer checks nothing, so this tool downloads the release asset itself, and only when `lib/sources.sh` pins a version and digest a maintainer verified | `/root/.local/bin/opencode` |

- **Provenance as for every upstream script**: downloaded to a private
  directory, URL, time, size and SHA-256 shown, open for inspection,
  re-hashed right before it runs, never piped into a shell. Run as root with
  `HOME=/root` and the working directory `/root` (Claude Code's installer
  scans from the working directory and refuses to run under `sudo`).
- **It must start.** Each tool is Bun-built (Claude Code, OpenCode) or Rust
  (Codex); their binaries are 64 KiB-aligned, but none has been run here on
  the Asahi kernel's 16 KiB pages. After installing, `--version` must answer;
  a tool that does not start is `failed` with its message, and the next one
  is offered. This is one of M17's checks.
- **Sign-in is the tool's own, as root, separately.** The rescue screen
  hands the terminal to the tool's sign-in: Claude Code shows a URL to open
  on any device and takes the code back; Codex offers a device code (after
  the person allows device codes in ChatGPT's settings) or reads an API key
  the person types into it; OpenCode has its own `auth login`. The
  credentials land in the tool's own file under `/root`, mode 0600. This
  tool never sees, reads or copies them.

### The rescue workspace

An agent starts in `/root/omarchy-rescue/` (0700), which is rebuilt each
time an agent starts:

| File | Purpose |
| --- | --- |
| `AGENTS.md` | the brief (below), read by Codex and OpenCode |
| `CLAUDE.md` | one line, `@AGENTS.md`, because Claude Code reads `AGENTS.md` by itself only when no `CLAUDE.md` exists anywhere above |
| `debug-report.txt` | a fresh debug report |
| `.claude/settings.json` | `deny` rules for disk, boot, encryption and package-removal commands, `ask` for the rest, bypass mode disabled |
| `.codex/rules/rescue.rules` | `forbidden` rules for the same commands; Codex is also started with `--sandbox read-only -a on-request` |
| `opencode.json` | `permission.bash`: ask for everything, deny the same commands |

These rules are **guidance with teeth, not a sandbox**: a pattern such as
`Bash(mkfs *)` does not stop `bash -c 'mkfs …'`. The real protection is
that each tool asks before running a command and the person reads it, and
that the brief tells the agent what it must never do.

### Starting an agent

A handoff (docs/FRONTEND.md): the frontend steps aside, the core starts the
tool in the workspace on the real terminal, and the frontend returns with a
fresh read of the machine when the tool exits. On the Linux console
(`TERM=linux`) the tools' own interfaces lose some glyphs; they work, and
remote rescue gives a better terminal.

## Remote rescue over SSH

The most comfortable rescue is often another computer: a full terminal, a
clipboard, and the person's own agent, already signed in, with nothing to
install or sign in on the fresh system.

- **What the base system does.** Arch Linux ARM's documentation says its
  base starts `sshd` with a user `alarm` whose password is `alarm`, besides
  `root`/`root`; Omarchy Mac removes `alarm` from `wheel` without locking it,
  and Omarchy's firewall closes port 22 only after Omarchy is installed. Not
  yet seen on this image (M17 checks it); the rescue screen and `doctor`
  report what the machine actually shows: `sshd` running or not, password
  logins allowed or not (`sshd -T`, as root, read-only), default accounts
  present and unlocked (`passwd -S`).
- **Opening it** (typed `ssh`) does three things, each recorded so it can be
  undone exactly: adds the person's public keys to
  `/root/.ssh/authorized_keys` between marker lines (fetched from
  `https://github.com/<user>.keys` for the token's `gh=` user, shown before
  use, or pasted); writes `/etc/ssh/sshd_config.d/10-omarchy-mac-bootstrap-rescue.conf`
  (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PermitRootLogin prohibit-password`); reloads `sshd` (starting it for this
  boot if it is not running; never enabling it). The screen shows `ssh
  root@<address>`.
- **On the other computer**, `ssh root@<address>` and then
  `/opt/omarchy-mac-bootstrap/omarchy-bootstrap debug context` prints the
  brief for the person's own agent, which can then work over the same SSH
  session.

## `rescue remove`

Typed `remove`, as root. It removes exactly what the rescue recorded: each
tool's files and its sign-in file under `/root`, the workspace, the marked
lines in root's `authorized_keys`, and the SSH drop-in (then reloads
`sshd`). It leaves the SSH configuration as upstream made it; if that still
allows password logins, `doctor` says so and points to the developer
setup's SSH module, which runs Omarchy's own `omarchy-setup-security-sshd`.

After Omarchy, root's password is locked and `/root` is not readable by the
everyday user. The verify stage, run as that user, reads rescue's record
and reports what it lists as still installed; the person removes it with
`sudo ./omarchy-bootstrap rescue remove`, which runs as root through the
user's own `sudo`.

## Root and the everyday user

- Rescue lives in `/root`. **Nothing is copied from root to the everyday
  user**: not the tools, not their sign-ins, not the workspace. The user
  installs through Omarchy's stubs and signs in once, as themselves
  (docs/AI-TOOLS.md).
- `/root` survives Omarchy Mac's in-place encryption (its migration restores
  the root filesystem's contents), and setup locks root's password at the
  end; the rescue tools stay reachable through `sudo -i` until removed.
- What root and the user share is only what the baseline already shares:
  the non-secret records in `/var/lib/omarchy-mac-bootstrap`, readable by the
  user.

## The debug report

`debug` (read-only) prints it; `debug save` (act) writes it to the state
directory's `debug/` as `omarchy-bootstrap-debug-<utc>.txt`, mode 0600; the
rescue workspace gets its own fresh copy.

```text
omarchy-bootstrap debug report
format    1
created   2026-10-10T09:20:11Z
tool      0.3.0 · commit e33714195c76 · frontend 0.1.0 (verified)
system    linux · aarch64 · root · TERM=linux
contains  identity journey status doctor disk mounts encryption omarchy shared restore qualify journal log redactions
never     files from any home, credentials, keys, tokens, Wi-Fi secrets, shell history, agent sessions

== identity
== journey
…
== redactions
secret-shaped values masked: 0
```

| Section | Linux source | macOS source |
| --- | --- | --- |
| identity | `uname -m`, device-tree model, `os-release`, `EUID` | model, chip, macOS version |
| journey | the core's stage derivation | the same |
| status, doctor | their own output, `--no-tui --ascii` | the same |
| disk | `lsblk -P` with named columns (name, `MAJ:MIN`, type, size, filesystem, PARTUUID, part type, label, mount points) | `diskutil list`, and the geometry the planner read |
| mounts | `findmnt` for `/`, `/boot`, `/mnt/shared`; their `mountinfo` lines | — |
| encryption | the baseline's classification and which evidence it used; never the LUKS header dump | — |
| omarchy | the baseline's signals: marker, conf present, unit state, version | — |
| shared, restore, qualify | their states and the summary fields of their records | shared, profile and export states |
| journal | `journalctl` for this boot and the last, warning and above, only the setup unit, NetworkManager, `systemd-cryptsetup@*`, the btrfs migration units, and kernel lines about `nvme`, `exfat`, `btrfs`, `dm-crypt` and Apple drivers; at most 300 lines each | — |
| log | the tool's own log, last 200 lines | the same |
| redactions | how many values of each kind were masked | the same |

- **Built from an allowlist.** Each section names its probes, and those
  probes are in the safety allowlist like every other. No file in any home
  is read except this tool's own log and records in its state directory; no
  credential store is opened (the Keychain, NetworkManager's
  `system-connections`, the tools' sign-in files, SSH keys).
- **Scrubbed as well.** After assembly every line passes the secret-shape
  patterns of docs/MIGRATION.md; a match becomes `[redacted:<kind>]` and is
  counted.
- **Honest about what stays visible:** user names, host names, disk GUIDs and
  sizes, Wi-Fi network names and IP addresses in logs. They help diagnosis
  and are not secret; the header says to read the report before posting it
  anywhere public.
- **Works on a half-finished install.** Every section stands alone; a probe
  that fails prints its failure and the report goes on. At most 256 KiB,
  each truncated section marked.

## The agent brief

`debug context` (read-only) prints it; the rescue workspace holds it as
`AGENTS.md`. Its fixed part is a file in this repository, reviewed like
code; the facts come from the core. It depends on no particular tool or
session format. Proposed text:

```markdown
# Rescue brief: omarchy-mac-bootstrap

You are helping a person install Linux on their Mac. You are running as
root on Arch Linux ARM on an Apple Silicon Mac (Asahi Linux), either freshly
installed or while Omarchy is being installed. The person is at this
machine and approves each command you propose.

## This machine now
{tool version and commit · frontend version · the Mac's model and chip}
{journey: each stage and its state · the next expected step}
{disk: the partitions in order, with sizes and roles, and the plan id}
{Omarchy Mac: setup state, encryption state · Shared state}

## How this install works
- macOS stays. From macOS, Asahi's installer made three partitions: a small
  "stub" macOS container, an EFI partition and the Linux root.
- Omarchy Mac's setup (`omarchy-mac-setup`) creates the everyday user, moves
  /boot onto the EFI partition, encrypts the root in place and installs
  Omarchy, resuming itself on each boot and printing to tty1.
- omarchy-bootstrap plans, launches those installers, reads the machine
  afterwards and records what it saw. Its only change to any disk is one
  exFAT partition named Shared, created from macOS, after Linux has finished.

## What you must not do
- Never run partitioning, formatting or disk-writing tools: fdisk, gdisk,
  sgdisk, parted, mkfs.*, wipefs, dd onto a device, blkdiscard.
- Never run cryptsetup except `cryptsetup luksDump`, and never change btrfs
  subvolumes.
- Never write to /boot, the EFI partition, or /etc/fstab.
- Never remove system packages, and never run steps of omarchy-mac-setup by
  hand or change its systemd unit.
- Never mount or change macOS's APFS partitions.
- Do not repair: when the machine differs from what is expected, stop and
  explain what you see.

## How to look
- Read-only and safe: `/opt/omarchy-mac-bootstrap/omarchy-bootstrap status`,
  `doctor`, `debug`, `logs`; `omarchy-mac-setup --status` (as root).
- `journalctl -b -u omarchy-mac-setup.service`, `journalctl -b -p warning`,
  `lsblk -f`, `findmnt / /boot`, `cat /proc/cmdline`.
- Setup in progress: /etc/omarchy-mac-setup.conf. Finished:
  /var/lib/omarchy-mac-setup/installed.
- Upstream programs exit 0 even when they did nothing: judge by the machine.
- Guides: /opt/omarchy-mac-bootstrap/docs/RECOVERY.md and TROUBLESHOOTING.md.

## Not yet seen on real hardware
{the open hardware questions from MILESTONES.md → M17}
```
