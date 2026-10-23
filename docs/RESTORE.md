# Restore

`lib/migrate_restore.sh` owns restore, its run log and its read-only projections.

`restore [DIR]` (act, Linux) brings a bundle exported on macOS
(docs/MIGRATION.md) onto Omarchy; the AI tools' part is in docs/AI-TOOLS.md.
It runs as the everyday user, never as root (`EUID` 0 is refused), after
Omarchy has finished, and writes only inside that user's home; system
changes go through `omarchy-pkg-add`, which asks for `sudo` itself. The home must be a real folder owned by that user, with no link in its
absolute prefix. The guard checks it before searching for bundles, runs or
backups; undo reports the same home refusal as apply and status. It lists
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

Before installing packages or placing items, apply checks the placement
commands in the private `restore/no-clobber` folder inside the restore state
folder, on the home's filesystem. Both file and empty directory destinations
must make
`mv -T --update=none-fail` and `ln -T` refuse, with both sides unchanged;
symbolic links are checked too. Transfers to free names must also succeed,
so an unknown option cannot pass as a safe refusal. A failed check stops
apply with a plain explanation. GNU coreutils 9.5 or later is required.
The folder holds only synthetic probes. Each check removes any folder left by
a stopped check before creating it again, and removes it on return. A
completed rerun with nothing to place performs no check or mutation.

1. **Re-check**, before each item, not only before the run: every folder
   from the home down to `D`'s parent is a real directory owned by the user
   (a link on the path stops the item), and `D` is still what the review
   showed — absent, a file's digest and mode, a link's text or a folder's
   tree digest. If not, the item is `blocked` and comes back as a conflict
   in the next review.
2. **Stage**: the object, checked against its digest, is written beside `D`
   as `D.omb-new-<run>`. Files use Bash's `noclobber` and a private umask;
   folders use `cp -a -T -- SOURCE STAGE` with the stage absent, so the copy
   creates the folder itself. An existing unrecorded stage or link stops the
   item. The stage is given its mode, read back and flushed.
3. **Device check**: an existing `D` must be on the home's filesystem, with
   the backups; a rename to another device would be a copy, so the item is
   `blocked`.
4. **Move the original aside**, whole: the run log records the destination
   and reviewed fingerprints. The backup name is the SHA-256 of the relative
   destination, inside this run's backup folder. `D` is renamed into it,
   and what moved is compared with the review; if it
   differs, it is renamed back and the item stops as a conflict.
5. **Place** at exactly `D`: a regular or generated Bash file uses
   `ln -T -- <stage> D`, then removes the stage name; a symbolic link uses
   `ln -s -T -- <text> D`, then removes its stage; a folder uses
   `mv -T --update=none-fail -- <stage> D` (GNU coreutils 9.5 and later).
   `-T` is always given, so a folder that appeared at `D` is never taken as
   a place to put the new name inside.
   If something appeared, the item is `blocked`. If the destination is
   still free, the original is moved back with the same no-clobber move.
   Otherwise the original remains in its named backup; the next review
   names that location, and undo returns it once the destination is free.
   The run log binds the original before it moves, including a stop before
   placement.
6. **Read back** `D` (digest, mode or link text): the item is `placed`.

Folder units (Neovim's folder, a skill folder) and generated files — the
shell file, `~/.bashrc` with its one marked line, OpenCode's `opencode.json`
merged with `jq` (constant filters, values as arguments) from Omarchy's file
and the person's entries — are built whole beside their target and placed
the same way. Codex's `config.toml` is kept or replaced whole: this tool
reads no TOML on Linux. Modes are a ceiling (no setuid, setgid or sticky
bit, nothing group- or world-writable); a replacement also takes the
original's more private mode, including generated Bash and OpenCode files.
For folders, the more private root mode is applied only to the stage;
the reusable scratch source retains its writable bundle mode.
New parents under `~/.local` and `~/.config` use 0755; other new parents use
0700. State and backup folders remain private. `chown` is never used. One race
remains: a program that keeps the old file open and writes to it after it
was moved aside writes into the backup, unnoticed.

**Settings** go through their owners' commands: Git's through `git config`,
key by key; Claude Code's MCP servers through `claude mcp add-json <name>
<json> --scope user`, the definition as one argument. Each is read again
just before its command, written only if it still has the reviewed value,
and read back; a write by another program in between is overwritten and not
detected. Before a setting changes, its previous value is saved verbatim in
one private 0600 file, `<destination-sha>.setting`, inside this run's backup
folder. The log records only fingerprints, including whether the setting
existed. Owner commands withhold their value argument from the run log,
recorder and preview, and their output is suppressed. The reversal hint
names the backup file; it never prints either value. Undo uses that file to
restore the previous Git setting or MCP definition, or removes a setting
that did not exist before.

### After a crash

Originals are only renamed, never deleted or overwritten, and the run log
binds each backup to its destination and fingerprints before its original
moves. After any stop — a crash, a
power cut, a full disk — the next `restore` judges each item from the
filesystem: a destination already holding the bundle's version is
`in-place`; where the destination is gone and its original sits in the
named backup, the original returns with a no-clobber move before placement
is retried. Generated Bash and OpenCode files are reviewed against the exact
recorded original in that backup, preserving custom lines and entries.
After returning it, apply reviews the item again and refuses a changed
result. Undo can return that original too. An occupied destination is
left alone; a refused placement is `blocked`, with the backup location
shown in the next review. An intervening destination blocks that unfinished
placement, so a later default Keep cannot erase its recovery record. A
completed stage name left behind is removed by apply only when its journal,
bytes and current destination agree. Undo compares finished stages with the
retained backup or the freshly reviewed desired bytes before removing them. A matched redundant folder stage is made
writable for removal; its source and retained backup keep their modes.
Undo retries this cleanup even when its completion was already recorded.
A partial or
unexpected recorded stage, including an undo stage, is moved whole into the
backup folder with a fresh suffix before rebuilding it. Existing preserved
stages and earlier restore/undo cycles never collide or overwrite bytes.

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
destination fingerprints. `restore.apply` requires `review`, the 64-hex
generation of the restore snapshot whose conflicts and diffs were shown.
Validation and execution's fresh basis check refuse with `refused changed`
if it differs from the current restore dataset. Validation names `bundle`
for a missing or unchecked bundle, and `review` for a missing, malformed or
changed review. The text interface binds
the generation of the review it printed too.

If a second Replace finds the original's backup name occupied, it keeps
both copies and names that backup. When the current destination has been
edited, the hint says to move it to a safe name, copy the original back with
`cp -a -T BACKUP DEST` to preserve its type and mode while retaining the
backup, run `restore undo`, then review another Replace. The copy lets undo
recognize the returned original when the previous placement was recorded.
For an unfinished replacement without a placement record, the hint instead
says to move the current destination to a safe name and run `restore undo`
while the destination is free, so the pending original can return.

Omarchy's seeded files in `~/.config` are the person's after the install: a
conflict with one is labelled "Omarchy's default", and OpenCode's file is
merged instead (*Placing a file*). **Omarchy's own files are never
touched**: `/usr/share/omarchy`, `~/.local/state/omarchy`, its skill links
at `~/.agents/skills/omarchy`, `~/.claude/skills/omarchy`,
`~/.codex/skills/omarchy` and `~/.config/opencode/skills/omarchy`, every
ancestor that would displace one of those links, its lazy agent wrappers in `~/.local/bin`
and its default-agent choice (docs/AI-TOOLS.md → *Omarchy's coding agent*).

## Packages

One `omarchy-pkg-add` handoff installs every pacman package the review
approved; `sudo` asks when its policy requires. Each package is judged by
`pacman -Q`, never by the exit status (the helper exits 0 when it skipped
everything): one it skipped is `failed` with its reason, and what needs it
is `blocked`. Then mise, npm and uv install the rest, managed and never
prompting, each judged by what it put on disk. A mise version folder counts
only when it holds its runtime's executable with execute permission; an
empty or incomplete folder does not count. cargo-binstall, go and
Flathub installs are printed as commands to run by hand.

For a mise backend target (`aqua:`, `github:` or `ubi:`), observation looks
only for a version folder under `installs/<kebab-case name>/`, using mise
v2026.9.12's heck 0.5.0 naming rule on the target as typed: punctuation
separates words, case boundaries split words, and letters become lowercase.
For example, `aqua:BurntSushi/ripgrep` uses `aqua-burnt-sushi-ripgrep`.
Only printable ASCII targets are observed; other names stay unverified.
Links and a real `latest` folder do not count. No executable name is inferred
from the target. A successful `mise use -g` with no such
folder is `unverified`: installed according to the command, with a warning
that the installation was not verified. It never blocks later layers and
is not installed again on a rerun of that bundle. Status counts it as
pending, rather than verified; a matching version folder clears that state.
When apply completes with unverified items, including a completed no-op
rerun, its final message gives their count and says nothing showed them
installed.

## Undo

`restore undo` (typed `undo`) finds the most recently written restore run
log and checks its bundle, even if a newer bundle has been exported. If
that bundle is unavailable, the home or log fails its checks, or no units
can be read, undo refuses and its judge cannot report completion. A readable
run whose items are blocked can still undo its actual changes or finish
without changing items never placed.

The current cycle is the item's events after its last `undone`. A recorded
placement in that cycle permits undo only while the current destination
still matches the placement. A backup retained from an already undone cycle
alone does not require another undo.

Without a placement record in the current cycle, undo never moves, removes
or replaces a destination. If it matches the recorded after and differs from
the before, undo names it, explains that it matches what restore places but
no placement was recorded, and leaves it as is. It names the original's
backup, or says there was no original. Its judge reports `unexpected`, naming
the destination. This includes a stop after placement but before the journal
append. Neither matching bytes nor the presence or absence of a stage proves
who placed it. With no pending original, an absent destination, the recorded
before or any third state is skipped silently. An old after from an undone
cycle never authorizes another undo.

The one automatic recovery without a placement record returns a pending
original from its checked backup to a free destination with a no-clobber
move. An occupied destination is refused, even if it matches the before or
after; undo names the backup and leaves the occupant alone. A missing or
changed pending backup is refused when its original needs to return. Skipped
or refused items are not recorded as undone. A silently skipped item can
still have a completed, redundant private stage cleaned up under the existing
byte checks; its destination stays untouched.

For a recorded placement, undo moves the destination aside and checks the bytes
that actually moved. An intervening edit is put back with a no-clobber move
and the item is refused. An unchanged placement returns its original from
the backup, or leaves the destination absent if it was new. Displaced bytes
remain at `<backup>.placed`; earlier copies keep fresh suffixes. Independent
items continue after a refusal. Completed undo stages are removed only when
they match the retained backup. Completed new stages are removed only when
they match the recorded and freshly reviewed desired bytes; partial or
unexpected stages remain available for recovery.

Git settings and MCP definitions revert from their private `.setting`
backups only with a `placed` event in the current cycle and a matching
current value. Without that event, undo never changes the setting. It names
the setting, explains that restore cannot tell whether it set the current
value, and names the saved previous value's private backup. The judge reports
`unexpected`, naming the setting. Values are never shown or logged.
Packages, sign-ins and what an external
installer changed are not reversible. Backups stay until the person removes
them; `restore status` shows their size.

## States

| Restore state | Means |
| --- | --- |
| `not-started` | no run for the bundle in use |
| `partial` | some items done; others failed, blocked or not reached |
| `blocked` | nothing more can go on: no bundle passes the check, running as root, Omarchy not finished, or the package step failed for everything after it |
| `complete` | every item is `placed`, `in-place`, `kept` or `unverified`, or waits only on the person (`needs-sign-in`, `needs-secret`) |

| Item state | Means |
| --- | --- |
| `placed` | this restore put it there and read it back; a package, once `pacman -Q` shows it |
| `in-place` | already there, exactly as the bundle has it |
| `kept` | a conflict kept as it is |
| `failed` | tried and did not take, with the reason |
| `unverified` | a mise backend install succeeded, but its version folder was not found under its mise directory name; later layers continue |
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
