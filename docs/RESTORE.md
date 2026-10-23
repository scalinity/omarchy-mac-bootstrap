# Restore

`lib/migrate_restore.sh` owns restore, its run log and its read-only projections.

`restore [DIR]` (act, Linux) brings a bundle exported on macOS
(docs/MIGRATION.md) onto Omarchy; the AI tools' part is in docs/AI-TOOLS.md.
It runs as the everyday user, never as root (`EUID` 0 is refused), after
Omarchy has finished, and writes only inside that user's home; system
changes go through `omarchy-pkg-add`, which asks for `sudo` itself. It lists
the finished bundles it finds on Shared or in `DIR`, each with its origin
and time, and selects the newest one that passes the bundle check.

## The flow

1. **Bundle check**: the seal; every object's digest; every destination
   relative to the home, with no `..`, no absolute path, no control byte,
   nothing beneath a link and no duplicate. A bundle that fails is refused.
2. **Review**: what installs; where each file lands — new, already in place,
   or a conflict (*Conflicts*); what will need a sign-in or a secret.
3. **Typed `restore`**: the consent; no destination or restore run log is
   written before it, and it covers exactly what the review showed.
4. **Apply** in layers: packages, runtimes, ecosystem tools, AI tools,
   files, settings.
5. **Verify** each item on the machine, never by an exit status (an AI tool
   by docs/AI-TOOLS.md → *What is observed*); `restore status` and `doctor`
   start none of the programs they check.

## The run log

The full SHA-256 of `bundle.omb` identifies the run. Each run appends to
its own log, `restore/runs/<manifest-sha>.log` in the state
directory (`~/.local/state/omarchy-mac-bootstrap`): a line naming the
destination and its before/after fingerprints before an original moves into
`restore/backups/<manifest-sha>/` (0700), a line after
each item is placed, and lines for conflict decisions and undos. Each line
is followed by `sync`; a torn last line (no newline, after a crash or a
power cut) is ignored. Continuation appends a framing marker and complete
records without rewriting the existing bytes. A malformed complete record
blocks the run. The log is input, never authority: a rerun judges
each item from the filesystem (*After a crash*), so a stop resumes and a
rerun after a finished run changes nothing.

A successful restore-time AI install appends
`agent<TAB>tool=<claude-code|codex|opencode><TAB>ran=1<LF>` after its
bounded version invocation succeeds. These receipts can appear between
events. The `restore.agent` save boundary uses the same append-and-flush
writer; a failed flush stops the run. A torn receipt supplies no observation.

## Placing a file

For a destination `D` under the home:

1. **Re-check**, before each item, not only before the run: every folder
   from the home down to `D`'s parent is a real directory owned by the user
   (a link on the path stops the item), and `D` is still what the review
   showed — absent, a file's digest and mode, a link's text or a folder's
   tree digest. If not, the item is `blocked` and comes back as a conflict
   in the next review.
2. **Stage**: the object, checked against its digest, is written beside `D`
   as `D.omb-new-<run>`, created exclusively (Bash's `noclobber`) with a
   private umask, given its mode, read back and flushed.
3. **Device check**: an existing `D` must be on the home's filesystem, with
   the backups; a rename to another device would be a copy, so the item is
   `blocked`.
4. **Move the original aside**, whole: the run log records the destination
   and reviewed fingerprints. The backup name is the SHA-256 of the relative
   destination, inside this run's backup folder. `D` is renamed into it,
   and what moved is compared with the review; if it
   differs, it is renamed back and the item stops as a conflict.
5. **Place** at exactly `D` with forms that fail if anything has appeared
   there: a file by `ln -T -- <stage> D`, then the stage name removed; a
   link by `ln -s -T -- <text> D`; a folder by
   `mv -T --update=none-fail -- <stage> D` (GNU coreutils 9.5 and later).
   `-T` is always given, so a folder that appeared at `D` is never taken as
   a place to put the new name inside. If something appeared, the item
   stops as a conflict and the original stays in its backup. The run log
   notes the placing.
6. **Read back** `D` (digest, mode or link text): the item is `placed`.

Folder units (Neovim's folder, a skill folder) and generated files — the
shell file, `~/.bashrc` with its one marked line, OpenCode's `opencode.json`
merged with `jq` (constant filters, values as arguments) from Omarchy's file
and the person's entries — are built whole beside their target and placed
the same way. Codex's `config.toml` is kept or replaced whole: this tool
reads no TOML on Linux. Modes are a ceiling (no setuid, setgid or sticky
bit, nothing group- or world-writable), and `chown` is never used. One race
remains: a program that keeps the old file open and writes to it after it
was moved aside writes into the backup, unnoticed.

**Settings** go through their owners' commands: Git's through `git config`,
key by key; Claude Code's MCP servers through `claude mcp add-json <name>
<json> --scope user`, the definition as one argument. Each is read again
just before its command, written only if it still has the reviewed value,
and read back; a write by another program in between is overwritten and not
detected.

### After a crash

Originals are only renamed, never deleted or overwritten, and the run log
binds each backup to its destination and fingerprints before its original
moves. After any stop — a crash, a
power cut, a full disk — the next `restore` judges each item from the
filesystem: a destination already holding the bundle's version is
`in-place`; where the destination is gone and its original sits in the
named backup, placing goes on; anything else is a conflict, left alone. A
stage left behind is removed only when the journal and read-back fingerprint
match the intended bytes. A partial or unexpected stage is moved whole to
a separate backup; unexpected bytes are preserved.

## Conflicts

A conflict is a destination holding something other than the bundle's
version; the unit is the whole item (Neovim's folder is kept or replaced
whole). The review asks about each: **Keep** (the default) leaves it
(`kept`); **Replace** moves it into the backups and places the bundle's
version; **diff** shows both sides and asks again; **keep the rest** keeps
every conflict not yet decided. Without the frontend, the text interface
keeps every conflict. Keep decisions are logged with the destination and
its fingerprint. The frontend sends explicit replacements in an `omb-replace 1` document; the
apply basis binds that document, the checked bundle and the reviewed
destination fingerprints.

Omarchy's seeded files in `~/.config` are the person's after the install: a
conflict with one is labelled "Omarchy's default", and OpenCode's file is
merged instead (*Placing a file*). **Omarchy's own files are never
touched**: `/usr/share/omarchy`, `~/.local/state/omarchy`, its skill links
in the AI tools' skill folders, its lazy agent wrappers in `~/.local/bin`
and its default-agent choice (docs/AI-TOOLS.md → *Omarchy's coding agent*).

## Packages

One `omarchy-pkg-add` handoff installs every pacman package the review
approved; `sudo` asks when its policy requires. Each package is judged by
`pacman -Q`, never by the exit status (the helper exits 0 when it skipped
everything): one it skipped is `failed` with its reason, and what needs it
is `blocked`. Then mise, npm and uv install the rest, managed and never
prompting, each judged by what it put on disk. cargo-binstall, go and
Flathub installs are printed as commands to run by hand.

## Undo

`restore undo` (typed `undo`) reverses the files, folders and links the
restore placed: where a destination is exactly what was placed, the
original comes back from its backup with the same no-clobber forms, or the
new one is moved to the backup name with `.placed` appended if nothing was
there; where it changed since, that item is refused, naming what is there
now. Git settings and MCP servers are reversed by hand; the apply output
prints owner-command hints (`git config` and `claude mcp remove`). Packages,
sign-ins and what an external installer changed are not reversible. Backups stay until the person removes
them; `restore status` shows their size.

## States

| Restore state | Means |
| --- | --- |
| `not-started` | no run for the bundle in use |
| `partial` | some items done; others failed, blocked or not reached |
| `blocked` | nothing more can go on: no bundle passes the check, running as root, Omarchy not finished, or the package step failed for everything after it |
| `complete` | every item is `placed`, `in-place` or `kept`, or waits only on the person (`needs-sign-in`, `needs-secret`) |

| Item state | Means |
| --- | --- |
| `placed` | this restore put it there and read it back; a package, once `pacman -Q` shows it |
| `in-place` | already there, exactly as the bundle has it |
| `kept` | a conflict kept as it is |
| `failed` | tried and did not take, with the reason |
| `blocked` | not tried, with the reason: something it needs failed, a link on its path, another device, or a change since the review |
| `needs-sign-in` | restored, waiting for the tool's sign-in; clears by itself when the sign-in file appears (presence only, never read; docs/AI-TOOLS.md → *What is observed*) |
| `needs-secret` | restored without its secret values; names the variables to set |

`rst_status_counts` returns four whole numbers: **verified kept failed
pending**. Verified includes `placed` and `in-place`; failed includes
`failed`; pending includes every other item, including blocked, untried,
manual-command and person-waiting items. It reads no diff, writes no state,
and fails with no output when counts cannot be established. Health appends
one Restore row with these counts, or the fixed warning
`Restore counts could not be read.` A nonzero failed count is a warning;
other valid counts are informational.
