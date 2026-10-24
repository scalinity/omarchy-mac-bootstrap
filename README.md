# Omarchy Mac Bootstrap

Turn a supported Apple Silicon Mac into a dual-boot macOS + Omarchy machine
through a guided installer, with an optional Shared partition both systems
read and write.

```bash
git clone https://github.com/scalinity/omarchy-mac-bootstrap.git
cd omarchy-mac-bootstrap
./omarchy-bootstrap
```

Run it on macOS first. After the reboot, run it again on the new Arch system
with the resume token the first run prints; it detects which side it is on and
continues. [Install, step by step](#install-step-by-step) is the guide for the
whole run, written to be read beside the Mac.

```text
macOS ─▶ [your environment: scan, choose] ─▶ storage plan ─▶ Asahi Alarm installer ─▶ reboot
      ─▶ Arch (Asahi Alarm) ─▶ Omarchy Mac (quattro) ─▶ Omarchy 4
      ─▶ [Shared: macOS creates it, Linux mounts it] ─▶ [restore your environment]
      ─▶ [cross-system check] ─▶ report ─▶ optional developer setup
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
- **Carries your choices across the reboot** in a short, readable resume token,
  and each system's word to the other as a short code: a completion code from
  Linux, a Shared code from macOS.
- **Continues on Linux**: network, then Omarchy Mac's own setup with your
  answers passed as its documented flags.
- **Creates and mounts Shared storage** when planned: one exFAT partition,
  created from macOS after Linux has finished, mounted at `/mnt/shared`.
- **Brings this Mac's environment to Omarchy**, if you choose. It reads Homebrew,
  applications, language tools, editors, the shell, terminal and Git settings,
  SSH and the AI tools (Claude Code, Codex, OpenCode) as text and runs none of
  them. Your selection is saved as one profile; `export` writes the files and
  records that may travel, with no secret among them (an encrypted SSH key only
  if you choose to carry it), to Shared or a folder;
  `restore` places them on Linux inside your home, moving each original into a
  backup first and keeping every conflict by default.
- **Checks that the two systems agree about Shared** (`qualify`): macOS writes a
  file over 4 GiB, Linux reads it back bit for bit and writes its own, macOS
  reads that back, and file names survive both ways.
- **Shows the whole journey in a full-screen interface**: ten stations derived
  from the machine on both systems, over the Bash core, which alone reads the
  machine and runs everything. A plain-text interface runs the same steps when
  the interface cannot start.
- **Ends with a report** (`report`): every check pass, warn, fail or not
  checked, with its reason.
- **Offers an optional developer setup** that uses Omarchy's own commands and
  reports what really happened in each module.
- **Explains itself**: `status`, `report`, `doctor`, `shared`, `qualify status`,
  `logs`, `debug`.

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
minimal Asahi Alarm image. Start it as `./omarchy-bootstrap` or
`bash ./omarchy-bootstrap`; started with `sh` (on macOS, bash in POSIX mode)
it starts itself again under `bash`, in bash's own mode, before loading
anything. The interface is the one download, about 1.6 MB taken once and
checked against `release/frontend.lock` (size and SHA-256) before it starts; if
it cannot be, the text interface runs the same steps.

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

On a 1 TB M1 Pro with 700 GB free, the interface's planner offers:

| Choice | Linux | Meaning |
| --- | --- | --- |
| Minimal | 100 GB | Omarchy plus moderate development |
| Balanced *(selected first when it fits)* | 250 GB | projects, containers, packages |
| Linux-heavy | 500 GB | a Linux laptop that keeps macOS |
| Custom | a number with GB, TB or % | validated by the core against the same limits |

A choice above what the disk allows is muted, with the reason. The text
interface computes its presets from the disk instead: Minimal 100 GB, Balanced
25 % of the disk, Linux-heavy 50 %, and Maximum safe, what one region allows
(macOS keeps used + 38 GB + snapshot overhead + 5 GB); its custom input takes
`300GB`, `0.5TB`, `35%` or `max`.

The review shows macOS, Linux, Shared, system and unallocated space exactly,
and below them the values to type. The installer asks for the **new macOS
size**, then the **New OS size**; the tool gives both as whole MiB (for
example `711345MiB`), which the installer's rounding leaves unchanged, and the
first goes on the clipboard. Free space split across separate regions is never
added together: the installer uses one region at a time.

[docs/STORAGE.md](docs/STORAGE.md) has the full algorithm.

## Shared storage

Optional, planned before the Linux size: 50, 100, 150 or 250 GB, or any size
that leaves Linux its minimum.

- **For** datasets, PDFs, media, model files, archives, downloads, files moving
  between the systems.
- **Not for** a Linux home, package databases, Docker storage, or Git checkouts
  that need Unix permissions and symlinks: exFAT has none of those.
- **Not encrypted** (FileVault and LUKS do not cover it) and **not a backup**.

It is created after Linux is completely installed: Linux shows a completion
code (`./omarchy-bootstrap --no-tui` on Linux prints it); on macOS,
`./omarchy-bootstrap` takes that code, checks that the disk is this Mac's
internal disk and matches the plan throughout, asks for `yes` and `create`
(`yes` in the interface, `create` and your `sudo` password on the terminal it
hands over), and adds the one partition; back on Linux,
`./omarchy-bootstrap shared activate` mounts it at `/mnt/shared` on every boot.
`./omarchy-bootstrap qualify` then proves that both systems read and write it
correctly ([docs/QUALIFICATION.md](docs/QUALIFICATION.md)). Shared adds the
trips between the systems: macOS to create it, Linux to mount it, macOS to
finish the check. [docs/SHARED.md](docs/SHARED.md) explains every step and
every stop.

## Install, step by step

Written for the one run on a 2021 16-inch MacBook Pro (M1 Pro,
`MacBookPro18,1`). Another supported Mac follows the same steps with different
sizes; the sizes below are examples from a 1 TB disk.

The run crosses at least five reboots and two systems that never run at the
same time. Every step says what to run, what you will see, what to type, how
you know it worked and what to do if it did not. The tool's own header says
`macOS · phase 1` and `Linux · phase 2`; the developer setup is phase 3.

**Stop anywhere.** Run `./omarchy-bootstrap` again on whichever system is up.
It reads the machine, not its own notes, and shows the next step. Nothing
starts by itself after a reboot, and a reboot is never taken as consent.

**The run at a glance.**

| Step | On | Do |
| --- | --- | --- |
| 1 | macOS | clone and run `./omarchy-bootstrap` |
| 2 | macOS | read Journey |
| 3 | macOS | optional: scan this Mac, choose what comes to Linux |
| 4 | macOS | plan the disk and save the plan |
| 5 | macOS | open the Asahi handoff, type **yes** |
| 6 | macOS | read the text screens, photograph them, type **launch** |
| 7 | macOS | answer the Asahi installer; the Mac shuts down |
| 8 | the boot picker | hold the power button, choose the new OS |
| 9 | Linux, as root | connect with `nmtui` |
| 10 | Linux, as root | fetch this repository, `resume` with the token |
| 11 | Linux, as root | confirm the choices, type **start** |
| 12 | Linux | let Omarchy Mac run through its reboots |
| 13 | Linux, as you | get Linux's completion code |
| 14 | macOS | type the completion code |
| 15 | macOS | create Shared: **yes**, **create** |
| 16 | macOS | write your environment to Shared or a drive |
| 17 | macOS | qualification step 1: **test** |
| 18 | Linux, as you | mount Shared: **mount** |
| 19 | Linux, as you | restore your environment: **restore** |
| 20 | Linux, as you | qualification step 2: **test** |
| 21 | macOS | qualification step 3: **test** |
| 22 | macOS and Linux | read the report |
| 23 | Linux, as you | optional: developer setup |

Steps 15, 17, 18, 20 and 21 only with Shared; 3, 16 and 19 only if you bring
your environment.

**The interface.** `./omarchy-bootstrap` opens a full-screen program. Its home
is **Journey**: the ten stations of the install along the top, **Where it
stands**, and **What you can do now**, the steps the machine offers. The first
one is selected; ⏎ takes it. The terminal must be at least 60 columns by 20 rows
(it says so otherwise); 80×24 holds every screen and 120×40 shows the most. On
the Linux console it draws in ASCII and 16 colours, and `--ascii` and
`--no-color` do the same anywhere.

| Key | Does |
| --- | --- |
| ⏎ | take the selected step, open the selected row |
| ↑ ↓ | move; PgUp and PgDn scroll |
| ← → | switch between the Screens list and the page |
| Tab | next field |
| Esc | back |
| r | read the machine again |
| ? | every key of this screen |
| L | the log |
| D | the debugging brief, from an error |
| q | quit |

A typed word is a field on a gate screen: type it exactly, then ⏎. Anything
else does nothing but say so, and Esc leaves. These are all the words:

| Word | Where | Means |
| --- | --- | --- |
| **yes** | macOS, before the Asahi installer and before Shared is created | a current backup exists |
| **launch** | macOS, after the installer's download | run the Asahi Alarm installer now |
| **start** | Linux | run `omarchy-mac-setup` now |
| **create** | macOS | create the Shared partition now |
| **mount** | Linux | mount Shared on every boot |
| **test** | either | run the due qualification step, or the Shared write test |
| **restore** | Linux | apply the reviewed restore |
| **opaque**, **carry** | macOS | include the folders you chose; carry an encrypted SSH key |
| **experimental** | macOS | continue on an M3 Mac |
| **resume** | Linux | continue `omarchy-mac-setup` |
| **undo** | Linux | undo restored files that have not changed |
| **clear** | either | move an unreadable operation record aside |

### Before the run

1. **Back up macOS.** The tool shows the newest Time Machine backup it sees and
   asks you to confirm one; it cannot check that the backup is good.
2. **Plug the Mac in and keep it plugged in.** Shared is not created on a
   battery below 50 %, and the install and the disk encryption run long.
3. **Have macOS ready.** This Mac, restored from the Time Machine backup of
   the everyday Mac and brought up to date: macOS 13.5 or newer, logged in as
   an administrator. The scan of your environment (step 3) reads this macOS as
   it stands, before Linux exists.
4. **Have network on both systems.** macOS must reach the internet: the tool
   downloads the interface once and the Asahi installer script. On Linux, have
   the Wi-Fi name and password to hand; they are typed into `nmtui`.
5. **Have two screens.** Read this page on another device: the Mac's own screen
   is busy with the install. Have a phone to photograph two screens.
6. **Have these ready to type:** your macOS password (the Asahi installer
   asks for it), the disk passphrase you will choose for Linux, and the
   password for the new user.
7. **Have the room.** Linux needs at least 54 GB in one region, on top of the
   reserve macOS keeps free (38 GB for updates, the snapshot overhead and a 5 GB
   margin: the survey shows the total for this disk). Shared, if you want it,
   comes on top.

### Phase 1: macOS, look, choose, plan

**1. Clone and run.**

```bash
git clone https://github.com/scalinity/omarchy-mac-bootstrap.git
cd omarchy-mac-bootstrap
./omarchy-bootstrap
```

- Clone with `git`, not from a tarball: the tool reads this checkout's
  `origin` and commit to print the commands Linux will need.
- **You see**, on the first run only: **The interface** (*a one-time download,
  checked against this checkout's lock*) with its URL, version, size and
  SHA-256, and `Download and check it now? [Y/n]`. Press ⏎. Then the full
  screen: **Connecting**, then **Welcome**.
- **Worked when** Welcome's **This machine** says Platform macOS, Architecture
  arm64, Model ID `MacBookPro18,1`, Chip Apple M1 Pro and Memory 16 GB, and **The
  tool and the core** names the interface's version.
- **If it stops:** the text interface starts instead and says why (*If
  something goes wrong*). The words you type are the same.

**2. Read Journey.** Press ⏎ on Welcome.

- **You see** the rail (`Survey`, `Choices`, `Review`, `Plan`, `Asahi`,
  `Omarchy`, `Shared`, `Restore`, `Verify`, `Done`), the current stage
  (`Plan storage: current step · 4 of 10`), and under **Facts** the machine,
  `Asahi install  none` and `Safe Linux max`. A read can take a few seconds
  (`reading the journey`); `r` reads again.
- **Worked when** Survey is done and **Safe Linux max** is at least 54 GB.
  `Choose what to bring` and `Review choices` read `skipped - no migration`
  until you do step 3.
- **If it stops:** **What you can do now** reads `Nothing is available now.`
  with a `✗ blocked` line in the core's words (for example, `Not enough space
  for Linux yet: free about 39 GB more in macOS (Linux needs 54 GB in one
  region).`). Free the space and press `r`. An unsupported Mac stops here, before
  any plan.

**3. Choose what comes to Linux (optional).** Skip this to bring nothing.

- **Run:** press ← to reach the Screens list, move to **Scan**, press ⏎, then ⏎
  on `Scan this Mac` and **y**. Nothing it reads is run: Homebrew, applications,
  language tools, editors, the shell, terminal and Git settings, SSH, the AI
  tools and the folders you name are read as text.
- **You see** the sources with their counts (`homebrew  done · 9 items`) and a
  total (`68 items · 30 selected · 20 to decide`).
- **Then:** **Selection** lists the categories (`software`, `apps`, `terminal`,
  `editors`, `ai`, `folders`, `git-ssh`, `secrets`). ⏎ opens a category and
  Space puts all of it in or out. In a category's list, Space includes or
  excludes one item, ⏎ opens its details, `f` goes to the next category and `/`
  filters; items that need a decision come first.
- **Then:** **Review** lists each category with what is selected, its size and
  `ready` or `N wait for you` (the items that need a decision, which Inventory
  shows first). ⏎ on `Save the selection` checks it (`✓ Checked`); ⏎ again asks
  `Save these choices? y goes on; any other key does not.` Press **y**. It
  resolves what you chose against the migration map and binds the profile to
  this Mac. If you included chosen folders or an encrypted SSH key, Review also
  asks for **opaque** or **carry**.
- **Worked when** `profile.save: done — The selection is saved: the profile is
  saved.` appears. After Journey reads again (`r`), `Choose what to bring` and
  `Review choices` read `done` and `Plan storage` is the current step.
  `./omarchy-bootstrap profile show` prints the saved profile.
- You can change the selection up to the export (step 16), even after the Asahi
  install; a new plan cannot be made after it.

**4. Plan the disk.** On Journey, ⏎ on `Save the plan`.

- **You see** the **Storage planner**: the disk as a scale bar, **Linux size**
  (`Minimal 100`, `Balanced 250`, `Linux-heavy 500`, `Custom`), **Shared size**
  (`none`, `50`, `100`, `150`, `250`, `Custom`), then what the installer will ask
  and what you type for it (`New size for macOS`, `New OS size`, in whole
  MiB), then **Encrypt Linux** (on), **User name**, **Host name**, **Keyboard
  layout**, **Time zone**, **Locale**, **SSH server** (off), **GitHub user** and
  **Developer tools** (on). Balanced 250 and Shared 150 start selected when they
  fit; a size that does not fit is muted with the reason.
- **Do:** ← → change a size, Tab moves to the next field, Space flips an on/off
  field. `Custom` takes a number, then Tab and ← → pick GB, TB or %. Decide
  Shared now: its space is kept free at the install. Each change is checked at
  once; the answers update.
- **Then:** ⏎ reviews the plan (`✓ checked`, `Review ready`); ⏎ again asks `Save
  this plan? y goes on; any other key does not.` Press **y**.
- **Worked when** the line reads `plan.save: done — The plan is saved and read
  back: Linux 250 GB, Shared 150 GB.` Nothing on the disk has changed.
- **If it stops:** a refused size says why under its field. Change it and review
  again. The plan is the last thing you can change before the installer.

### Phase 1: macOS, hand off to the Asahi installer

**5. Open the handoff.** Back on Journey, press ↓ to `Run the Asahi Alarm
installer` (the first row is still `Save the plan`), then ⏎.

- **You see** **Asahi handoff**, a four-step strip (`1 Check`, `2 Answers`, `3
  Boot`, `4 Token`) over four sections. Scroll with PgDn.
  - **Before the installer:** the disk (internal, this Mac's), the size macOS
    shrinks to, what is created, what Shared keeps, and what is left alone.
  - **What the installer asks:** each prompt and exactly what you type.
  - **After the installer:** the boot steps and the Linux fetch commands.
  - **Resume token:** `omb2:enc=1,user=…,plan=…`.
- **Then:** ⏎ opens the gate. Type **yes** (a current backup exists), ⏎.

**6. Read the text screens, photograph, launch.** The interface steps aside and
the tool continues in plain text on this terminal.

- **You see**, in order: the machine again; **Backup** (`A recent backup of this
  Mac exists.  Typed in the interface: yes`); **Asahi Alarm installer** (*download
  first, run second*: URL, time, size, SHA-256, where it was saved, `Fetches
  installer v0.9.2  matches the version this tool was checked against`) and
  `Inspect the script before running it? [y/N]`; the answer card **When the
  Asahi Alarm installer asks**; **After the installer** with the fetch commands and
  the token; and `Last stop before your disk changes.`
- **Do:** answer `n` to the inspection, or `y` to read the script first. Then
  **photograph the answer card, the `After the installer` steps and the token**
  (scroll up if needed): the installer ends by shutting the Mac down, and they
  go with the terminal. `./omarchy-bootstrap resume` on macOS shows them again.
- **Type:** `Run the official Asahi Alarm installer now.  Type launch to
  continue, or n to stop:` **launch**. `n` stops with nothing changed.
- **If it stops:** before `launch` nothing has touched the disk. If the disk
  changed since the plan, the tool says so and runs nothing; run it again for a
  fresh plan.

**7. Answer the Asahi installer.** It is the official one, in this terminal. It
asks only what the card listed. Type each answer exactly, sizes included. With
the example plan:

| It asks | You type |
| --- | --- |
| Press enter to continue | ⏎, and your macOS password when asked |
| Choose what to do | **r** (resize an existing partition) |
| New size (macOS keeps) | **567046MiB** (on your clipboard) |
| Continue? | **y** (the Mac may seem frozen; wait) |
| Choose what to do | **f** (install an OS into free space) |
| Choose an OS to install | the number of `Asahi Alarm Minimal (BTRFS)` |
| New OS size (Linux gets) | **238419MiB** |
| OS name | ⏎ (or a name of your own; choose that name in the boot picker) |

- Never type `max` at a size prompt: the space after Linux is Shared's.
- The installer exits 0 whether it finished, was quit or failed, so the tool
  reads the disk afterwards and says what it did (nothing, resized only, stopped
  part-way, or finished).
- **Worked when** the Mac shuts down by itself.
- **If it stops** after the resize, quitting does not undo it: run
  `./omarchy-bootstrap` again, which plans the install into the freed space.
  A stop part-way is `docs/RECOVERY.md`; this tool never deletes the partitions
  it left.

### The reboot into Linux

**8. Boot the new system.** The card's steps, in order:

1. Wait 25 seconds after the Mac powers off.
2. Press and **hold** the power button once, until `Loading startup options…`
   appears.
3. Choose `Asahi Alarm Minimal (BTRFS)` (the OS name you gave the installer).
4. A macOS Recovery dialog appears briefly. If it asks `Select a volume to
   recover`, choose your normal macOS volume and authenticate.
5. Follow the prompts on the `Asahi Linux installer` screen. The Mac then boots
   Arch.
6. Log in as `root` / `root`.

- **If it stops:** a bootloop or `macOS needs to be reinstalled` means the power
  button sequence was not followed exactly: shut down fully, wait, hold once,
  choose the new volume (`docs/RECOVERY.md`, *First boot went wrong*).

**9. Connect.** Run **`nmtui`**, choose `Activate a connection`, pick your
network, enter the password, then **Quit**.

- **Worked when** the next step can download.

**10. Fetch this repository and resume.** Type what the photographed screen
printed. For a public repository:

```bash
mkdir -p /opt/omarchy-mac-bootstrap
curl -fsSL https://github.com/scalinity/omarchy-mac-bootstrap/archive/<commit>.tar.gz \
  | tar xz --strip-components=1 -C /opt/omarchy-mac-bootstrap
cd /opt/omarchy-mac-bootstrap && ./omarchy-bootstrap resume omb2:enc=1,user=alex,host=omarchy,kmap=us,tz=America/New_York,loc=en_US.UTF-8,ssh=0,linux=250,shared=150,dev=1,plan=bc0bdd63
```

- A private repository prints a different first part (`pacman -Syu --needed git
  github-cli`, `gh auth login` with a device code, `gh repo clone`, `gh auth
  logout`); type those as printed. The commit is pinned when it is on GitHub; a
  fresh clone of `main` is.
- The token above is an example. Type yours exactly, as printed; it ends in
  `plan=` and eight characters.
- This step runs in plain text, not in the interface: a command given an
  argument stays in text.
- **You see** `Phase 1 choices loaded: alex@omarchy, encryption on, Linux 250
  GB, Shared 150 GB.`, the machine and its checks (aarch64, Apple Silicon, Arch
  Linux ARM, Btrfs root, Network), then `Use these? [Y/n]`.
- **If it stops:** offline, it offers `nmtui` itself. `must run as root` means
  log in as root. With no token it simply asks the choices.

### Phase 2: Linux, Omarchy

**11. Confirm and start.**

- **Type:** ⏎ at `Use these? [Y/n]`.
- **You see** **Omarchy Mac** (`Branch quattro carries Omarchy 4.0.3rc4.`), the
  script's URL, size and SHA-256, and `Inspect the script before running it?
  [y/N]`; then the box `What omarchy-mac-setup does next`.
- **Type:** `n` (or `y` to read it), then at `Run omarchy-mac-setup now.  Type
  start to continue, or n to stop:` **start**.
- First it stops and disables the image's `sshd` and checks it:
  `SSH is stopped and disabled.` If it cannot confirm, it says `Omarchy Mac
  setup was not started.` and nothing runs.

**12. Let Omarchy Mac run.** It drives the machine through its own reboots on
`tty1`.

- It asks `Start? [Y/n]` first: answer **y**. You set the new user's password.
  Then it moves `/boot` onto the EFI partition (reboot), encrypts the root in
  place (you choose the disk passphrase at the console; reboot), and installs
  Omarchy (about fifteen minutes, then a reboot into the desktop): three
  reboots. After each it resumes by itself; you type only the passphrase.
- If a dialog offers to build packages that have no aarch64 build, say **no**.
- Watch it with Ctrl+Alt+F1.
- **Worked when** the desktop appears and you can log in as your user.
- **If it stops:** as root, `./omarchy-bootstrap resume` offers
  `omarchy-mac-setup --resume` (typed **resume**). Interrupted encryption is safe:
  the next boot resumes it (`docs/RECOVERY.md`, *Omarchy Mac stopped*).

**13. Get Linux's completion code.** Log in as your user, open a terminal, run:

```bash
/opt/omarchy-mac-bootstrap/omarchy-bootstrap --no-tui
```

- Use `--no-tui` here: the interface's Journey does not print the code; the
  text screen does.
- **You see** `Omarchy is installed  4.0.3rc4` and, under `Next, on macOS`,
  `Linux has completely finished. Shut down, boot macOS (hold the power button,
  choose Macintosh HD), then run … there. When it asks, type this code:` and a
  line `ombdone-…`. **Photograph it.** It then offers `Open the developer setup?
  [Y/n]`; **n** for now.
- The code is shown only when Omarchy Mac and its encryption have finished.
  Without the token on this system it says so; run `./omarchy-bootstrap resume
  <token>` once to load it.
- The run goes back to macOS with this code, with or without Shared: macOS
  cannot read the encrypted Linux root, so Linux's word crosses as a typed code,
  and the journey ends on macOS.

### macOS again: Linux's code, Shared, your environment

**14. Boot macOS and type the code.** Shut Linux down fully (not sleep), hold the
power button, choose your macOS volume. Run `./omarchy-bootstrap`.

- **You see** on Journey `Enter Linux's completion code`. ⏎, type the
  `ombdone-…` code in the `code` field, ⏎.
- **Worked when** the code is accepted (the text screen says `Linux's completion
  code matches this disk.`) and, if Shared is planned, `Create Shared storage`
  is offered. A wrong code is refused with a reason: mistyped, a different plan,
  or a different Linux partition.
- With **no Shared planned**, skip steps 15, 17, 18, 20 and 21. If you chose to
  bring your environment, do step 16 with a drive, then step 19 on Linux. Then
  go to step 22.

**15. Create Shared (if planned).** On Journey, `Create Shared storage`.

- **You see** the gate: the disk, where it goes, the exFAT partition and its
  size, what it leaves alone. Type **yes** (a current backup exists), ⏎.
- The interface steps aside. The terminal then asks **create**, then `sudo`
  asks for your password. Before and after, the whole disk is read and must
  match the plan; Shared's creation is the one change this tool makes.
- **Worked when** `Shared storage created: disk0sN, 150 GB exFAT, mounted at
  /Volumes/Shared.` and a line `ombshare-…` appear. The interface redraws the
  moment the step ends and that text is gone: read the code again with
  `./omarchy-bootstrap shared`, which prints it.
- **If it stops:** nothing is repaired. A refusal says what differs; running it
  again starts over from the gates. If `sudo -n` finds its authorization lapsed,
  nothing was created. See `docs/SHARED.md`, *When it stops*.

**16. Write your environment to Shared (if you chose one in step 3).** On
Journey, `Write a bundle`, or run `./omarchy-bootstrap export`.

- **You see** a fresh scan reconciled with your profile, then the question to
  write it (`Write the bundle to …? [y/N]` in text). Answer **y**.
- **Worked when** `Bundle written:` names the folder under
  `omarchy-mac-bootstrap/bundles/` on Shared. It holds only what passed the
  secret scan.
- **Without Shared,** use a USB or SD card (exFAT or FAT32): `./omarchy-bootstrap
  export /Volumes/NAME`.
- **If it stops:** a failed export leaves a `.partial-*` folder that restore never
  lists; remove it by hand. Selected files over 2 GiB are refused.

**17. Qualification step 1 (if Shared).** Run `./omarchy-bootstrap qualify`; it
opens the interface with Journey and **Qualification** only. Open
**Qualification** from the Screens list, press `t`, type **test**, ⏎.

- **You see** three rows: `macOS writes`, `Linux checks and writes`, `macOS
  checks`. Step 1 writes one 4,296,015,889-byte file of random bytes and seven
  test names into `omarchy-mac-bootstrap/qualify/` on Shared, and a record of
  its SHA-256. It needs twice the file's size (about 8 GiB) free on Shared, plus
  a reserve of the larger of 1 GiB and 2 % of Shared; Linux needs one file's
  size plus the same reserve.
- **Worked when** the state reads `waiting-for-linux`, and the tool
  says `Shut down fully before booting the other system; do not sleep or
  hibernate.`
- **If it stops:** a step that stops part-way leaves no record, so the same step
  is offered again and repeats itself from its first check. Running
  qualification step 1 again starts over.

### Linux again: Shared, your environment, qualification step 2

Shut macOS down fully, hold the power button, choose `Asahi Alarm Minimal
(BTRFS)`, log in as your user.

**18. Mount Shared (if planned).** `./omarchy-bootstrap shared activate`.

- **You see** `Enter the Shared code`: type the `ombshare-…` code, ⏎. Then
  `Mount Shared on every boot`: type **mount**; `sudo` asks for your password.
  It adds one managed line to `/etc/fstab`, keeping every other line.
- **Worked when** `./omarchy-bootstrap shared` says `ready … mounts at
  /mnt/shared on every boot`. `./omarchy-bootstrap shared test` (type **test**)
  writes, reads back and removes one file.
- **If it stops:** a code for another plan or partition is refused. Type the
  code macOS showed (`./omarchy-bootstrap shared` on macOS prints it). An
  `/etc/fstab` entry or files already at `/mnt/shared` stop it, and the message
  says what to move.

**19. Restore your environment (if you chose one).** As your user, never as
root: `./omarchy-bootstrap restore`, or `./omarchy-bootstrap restore
/absolute/path/to/folder` for a drive.

- **You see** **Restore progress** and the bundle it found. ⏎ reviews: what
  installs, and where each file lands (new, already there, or a conflict). A
  conflict is **Keep** by default; `d` opens it as a diff (`k` keep, `R` replace,
  `K` keep the rest). Type **restore**, ⏎. Packages go through one
  `omarchy-pkg-add` handoff and `sudo` asks for your password.
- Every file's original is moved whole into a backup first. A rerun after a stop
  resumes; after a finished run it changes nothing.
- **Worked when** `./omarchy-bootstrap restore status` says `complete`. A tool
  that needs signing in reads `needs-sign-in` until you sign in.
- **Undo:** `./omarchy-bootstrap restore undo` (type **undo**) puts back each
  item that is still exactly as restore left it. Packages and sign-ins are not
  reversed.
- On Linux the Journey keeps `Restore` as the current station if there is no
  bundle: it cannot tell that you chose none. That is expected; the journey ends
  on macOS.

**20. Qualification step 2 (if Shared).** `./omarchy-bootstrap qualify`, open
**Qualification**, `t`, **test**.

- **You see** it check `data.macos.bin` against the digest macOS recorded, read
  the test names, and write its own file and names.
- **Worked when** the step ends with `Shut down fully before booting the other
  system`. A digest that does not read back does not stop it: it is recorded and
  qualification step 3 will say `failed`. An exFAT dirty flag is shown as
  information only.
- **If it stops:** it runs as your user, after macOS step 1. `Step 1 is due;
  Linux qualification runs as the everyday user, after macOS step 1.` means go
  back to macOS.

### macOS again: the cross-system check and the report

Shut Linux down fully, boot macOS.

**21. Qualification step 3 (if Shared).** `./omarchy-bootstrap qualify`, open
**Qualification**, `t`, **test**.

- **Worked when** `Qualification passed; Linux exFAT dirty flag: 0.` The two
  data files and the names folders are then removed; the three step records
  stay for `report`.
- **If it says failed** (`mismatch`, `data-unreadable` or
  `macos-data-unreadable`), everything stays on Shared until qualification step 1
  is run again, which starts over. A `blocked` state names the one file on Shared
  to delete from `omarchy-mac-bootstrap/qualify`.

**22. Read the report.** `./omarchy-bootstrap report`.

- **You see** a table, each row `pass`, `warn`, `fail` or `not-checked` with its
  reason: the Mac, disk, Shared, Linux, qualification, restore and AI tools,
  doctor, and Recovery boot and a current backup. Then `Verdict` (`fail` if any
  row fails, else `warn` if any warns, else `pass`) and `Counts`.
- `Recovery boot, a current backup` is always `not-checked`: the tool cannot see
  them. Check Recovery yourself (hold the power button, choose Options).
- Rows about the other system read `not-checked` with the reason; run `report`
  on Linux too.
- **Worked when** the journey says Done: the **Completion** screen lists every
  station, and `q` leaves one line, `✓ journey complete · ./omarchy-bootstrap
  report`.

### Phase 3: developer setup (optional, rerunnable)

**23.** On Linux, as your user:

```bash
/opt/omarchy-mac-bootstrap/omarchy-bootstrap dev
```

- **You see** a menu of modules; ↑↓ move, Space toggles, ⏎ confirms. Nothing
  installs unless selected.

| Module | Does |
| --- | --- |
| Core tools | git, github-cli, base-devel, curl, wget, jq, ripgrep, fd, fzf, tmux, btop, tree, unzip, rsync (only the missing ones) |
| Languages | rust, python, node, go via `omarchy-install-dev-env` |
| Containers | Docker is already there (Omarchy); opt into sudoless Docker, or add Podman |
| Editor | Neovim is Omarchy's default; VS Code via `omarchy-install-editor-vscode` |
| Git identity | `user.name`, `user.email`, `init.defaultBranch` |
| GitHub CLI | `gh auth login`, `gh auth setup-git` |
| SSH | ed25519 key, add it to GitHub; SSH access (service, firewall, authorized keys, password login off) via `omarchy-setup-security-sshd` |
| AI coding CLIs | Claude Code, Codex and OpenCode through Omarchy's `mise` packages, one copy each, one bounded version check per new install |
| Time & locale | apply the timezone/locale from step 4 if Omarchy's differ |

- **Worked when** the summary lists each module as complete, already set up,
  skipped, cancelled, or failed with the reason. A failed module makes the run
  exit non-zero and is not recorded as done: fix the cause and rerun.

### What is kept

- **State and logs:** `~/.local/state/omarchy-mac-bootstrap/` on macOS and for
  your user on Linux, `/var/lib/omarchy-mac-bootstrap/` as root on Linux. One
  readable log a day is in `logs/`: each command, its exit code, checksums and
  your choices. [State and logs](#state-and-logs) says what each file holds.
- **On Shared:** `omarchy-mac-bootstrap/bundles/` and
  `omarchy-mac-bootstrap/qualify/`.
- **Nothing is secret.** The tool never reads a password: upstream programs and
  `sudo` ask for their own. State refuses keys shaped like a secret, and the log
  holds each command and its exit code, never its output. The resume token and
  the codes carry choices and identifiers only. Shared is not encrypted; a bundle
  there holds no secret by rule, except an encrypted SSH key you chose to carry.

## If something goes wrong

**Stop anywhere, then run `./omarchy-bootstrap` again.** Every run reads the
machine again and says where it is: it takes a record as input, never as proof.
Ctrl-C at one of this tool's prompts stops without side effects; Ctrl-C inside a
launched installer interrupts that installer, and the tool says so.
`./omarchy-bootstrap status` (read-only, text) prints the ten stations, one per
line, with the next step.

**Read the Journey.** Each station is in one state:

| State | Unicode | ASCII | Means |
| --- | --- | --- | --- |
| done | ● | `*` | the machine shows it finished; `recorded by macos` or `recorded by linux` when only a code or a checked bundle from the other system says so |
| current | ◆ | `>` | the first unfinished station due on this system; there is at most one |
| todo | ○ | `.` | not yet (the list says `not yet`) |
| skipped | ◌ | `~` | not needed, with the reason (`no migration`, `Shared is not planned`) |
| blocked | ✗ | `x` | cannot go on; the reason is shown, and later stations wait |
| later | · | `_` | the core has not derived it |

The rail names the stations `Survey`, `Choices`, `Review`, `Plan`, `Asahi`,
`Omarchy`, `Shared`, `Restore`, `Verify`, `Done`; the list below it says `Choose
what to bring`, `Review choices`, `Plan storage`, `Install Asahi`, `Install
Omarchy`, `Shared storage`, `Restore`, `Verify`, `Complete`; `status` prints
`survey`, `profile`, `resolve`, `plan`, `asahi`, `omarchy`, `shared`, `restore`,
`verify`, `done`. They are the same ten. The journey ends on macOS; on Linux
`Done` stays not yet.

| You see | Do |
| --- | --- |
| `Interface: missing`, `mismatch`, `unrunnable` or `fallback`, then `Continuing in text.` | the interface could not start; the text interface runs the same steps with the same typed words (below) |
| `restart this Mac (or this Linux system), then run the tool again` | a step was cut off by a crash or power loss. Restart, then run `./omarchy-bootstrap`: it reads what the machine shows and settles the step. A reboot is never counted as success |
| a record that cannot be read, in the core's words | `./omarchy-bootstrap operation SCOPE` shows what can be known. `./omarchy-bootstrap operation clear SCOPE` moves that one record aside after you type **clear**; it never opens or deletes it, and the next step makes every check again |
| the Asahi installer quit or failed | the disk is read afterwards: unchanged, resized only (quitting does not undo a resize), stopped part-way, or finished. Run `./omarchy-bootstrap` again. `docs/RECOVERY.md` has each case |
| it refuses to launch (`partition layout changed since it was surveyed`, or `the answers shown no longer hold`) | the disk or macOS's free space changed. Nothing was launched. Run `./omarchy-bootstrap` again for a fresh plan |
| Omarchy Mac stopped or seems idle | watch it with Ctrl+Alt+F1; as root, `./omarchy-bootstrap resume` offers `omarchy-mac-setup --resume` (**resume**) |
| a code is refused (`a character was mistyped`, `That code belongs to a different plan`, `made on a different Linux partition`) | type the code the other system shows now |
| Shared is `blocked`, or a partition `is not the exFAT volume planned` | `./omarchy-bootstrap shared` says why; nothing is repaired or formatted; `docs/SHARED.md`, *When it stops* |
| qualification is `blocked` or `failed` | `./omarchy-bootstrap qualify status` says why; `failed` is cleared by running qualification step 1 again |

**The text interface.** `./omarchy-bootstrap --no-tui` runs any command in plain
text, and the launcher does the same when the interface cannot be verified or
started, when stdin or stdout is not a terminal, or when `TERM` is unset or
`dumb`. It skips no gate: the typed word is read from the keyboard. It is
complete for the install and for every read. Choices about your environment are
made in the interface; without it, `profile` saves the defaults and `restore`
keeps every conflict, each after its typed word. A command given an argument
(`resume TOKEN`, `export DIR`, `shared create CODE`) always runs in text.

**Ask for help.** `./omarchy-bootstrap doctor` and `logs` read and write
nothing. `./omarchy-bootstrap debug` prints a brief for an AI agent you choose
(`debug > file` keeps a copy): fixed instructions, then what `status` and
`doctor` show, never a log line or a file's contents. `docs/TROUBLESHOOTING.md`
lists the symptoms.

**What this tool never does.** It never deletes, resizes, reformats or
generically edits a partition: Asahi's installer owns the resize and the Linux
layout, and Omarchy Mac owns `/boot` and the encryption. Its one disk change is
the planned Shared partition, after the whole disk has been read, two typed
words and `sudo`. It never launches an installer without a typed word, never
stores a password, never repairs anything by itself, and never removes macOS.
A half-finished install is left as it is, with the way forward written down.

## Commands

| Command | Purpose |
| --- | --- |
| `./omarchy-bootstrap` | guided flow for wherever this machine is |
| `plan` | survey + plan + choices; saves them, runs nothing, in any state |
| `install` | the current phase end to end |
| `resume [token]` | after a reboot (macOS: the state and the guide; Linux: continue); a token is read in text |
| `status` | the ten stations, what the machine shows, what was recorded, what's next (read-only) |
| `report` | a fresh check table and its verdict (read-only; it succeeds whatever the verdict) |
| `doctor` | health checks (read-only); exits non-zero only on FAIL |
| `shared [status]` | where Shared storage stands (read-only) |
| `shared create` | macOS: create the planned Shared partition |
| `shared activate` | Linux: mount Shared at `/mnt/shared` on every boot |
| `shared test` | write, read back and remove one test file on Shared |
| `qualify` | run the cross-system step that is due on this system (type `test`) |
| `qualify status` | where the cross-system check stands (read-only) |
| `scan` | macOS: what this Mac holds that could come to Linux (read-only; nothing is run) |
| `profile` | macOS: choose what comes to Linux and save it |
| `profile show` | print the saved profile (read-only) |
| `export [DIR]` | macOS: write the chosen environment to Shared or a folder |
| `restore [DIR]` | Linux: restore the environment from Shared or an absolute path to an existing folder |
| `restore status` | Linux: restore progress (read-only) |
| `restore undo` | Linux: undo restored files that have not changed |
| `dev` | developer setup (Linux, after Omarchy) |
| `debug` | debugging brief and machine facts (read-only) |
| `operation SCOPE` | what a scope's operation record shows (read-only) |
| `operation clear SCOPE` | move an unreadable operation record aside, after typed `clear` |
| `sources [--check]` | targeted upstream; `--check` compares with upstream live (read-only) |
| `logs` | where the log is, and its recent lines (read-only) |
| `frontend-check` | check that the interface starts: downloads it once, changes nothing else |

Flags: `--dry-run` (shows every step; changes nothing and keeps nothing — no
state, no log, no download), `--no-tui` (the text interface for any command; it
skips no gate), `--no-color`, `--ascii`, `--help`, `--version`.

The interactive commands (none, `install`, `resume`, `plan`, `profile`,
`export`, `restore`, `qualify`, `shared create`, `shared activate`) open the
interface on a terminal; every other command prints text, as a contract for
scripts. A command given an argument (`resume TOKEN`, `export DIR`, `shared
create CODE`) runs in text, except `restore DIR`.

## State and logs

- macOS, and your user on Linux: `~/.local/state/omarchy-mac-bootstrap/`
- root on Linux: `/var/lib/omarchy-mac-bootstrap/` (readable by your user later)

`state.env` holds non-secret progress and choices; `shared-intent.env` the
Shared plan; `shared-create.env`, between Shared's creation and its recorded
result, what that creation was allowed to produce; `profile.omb` the selection
of what comes to Linux; `ops/` the record of a step that may change the machine,
from its start until it is judged; `restore/` each restore's run log and the
backups it made; `logs/` one readable log per day (commands, exit codes, checksums,
choices); `downloads/` each fetched upstream script, for provenance. The
directory must be yours and private; override it with `OMB_STATE_DIR` (an
absolute path). Read-only commands and dry runs write none of it.

The interface, once downloaded, is cached in
`~/.cache/omarchy-mac-bootstrap/frontend/` (as root on Linux,
`/var/cache/omarchy-mac-bootstrap/frontend/`), held to the size and SHA-256 in
`release/frontend.lock` on every start. On Shared, `omarchy-mac-bootstrap/`
holds `bundles/` (what `export` wrote) and `qualify/` (the cross-system check).

## Recovery and uninstall

- Something stopped halfway: [docs/RECOVERY.md](docs/RECOVERY.md), and
  [If something goes wrong](#if-something-goes-wrong) for a cut-off step or an
  operation record.
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
tests/run.sh             # syntax, shellcheck (if installed), every test (~30 min)
tests/run.sh storage     # one file
./omarchy-bootstrap --dry-run     # real machine, nothing changes
OMB_FIXTURE=$PWD/tests/fixtures/mac-m1pro-1tb-roomy ./omarchy-bootstrap --dry-run
```

CI runs every test on Linux (bash 5, ShellCheck) and macOS (`/bin/bash` 3.2).
Design and boundaries: [SPEC.md](SPEC.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[MILESTONES.md](MILESTONES.md). The planning and Shared logic is tested against
recorded disk layouts, and the interface, the migration, the journey and
qualification over recorded machines; qualification on real hardware is
milestone M17, the first real install with the finished product. The interface
is [docs/FRONTEND.md](docs/FRONTEND.md) and [docs/UX.md](docs/UX.md); the
migration is [docs/MIGRATION.md](docs/MIGRATION.md),
[docs/RESOLVER.md](docs/RESOLVER.md) and [docs/RESTORE.md](docs/RESTORE.md); the
journey and qualification are [docs/QUALIFICATION.md](docs/QUALIFICATION.md);
their decisions are in [docs/DECISIONS.md](docs/DECISIONS.md).
