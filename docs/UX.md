# The interface

**Status: built in the released 0.2.0 frontend (screens 1–4, 5–9 and 11
as tabs, the Migration Review, 12–15 and 18–25).** How the frontend
(docs/FRONTEND.md) looks and behaves. Everything on screen comes from the
core's records (docs/PROTOCOL.md); this document decides how it is shown.
The owner's reference designs (*Reference designs*; docs/DECISIONS.md → D51)
decide how the interface looks, the core's records what it says, and
nothing in an image is a fact, a version, a status or a capability.

## Reference designs

The reference designs are fifteen images in `TUI Redesign Reference
Images/` at the repository root, not tracked by Git. They set the look every
screen shares: the pixel OMARCHY wordmark with its MAC BOOTSTRAP tagline and
the laptop-and-mountains art, the ten-station journey rail, the navigation
on the left, the System Overview and a context panel on the right, steppers,
check lists, the footer's key hints, and the midnight backdrop.

Their content is mock-up: every word, number and state in them is a
placeholder, and so are the rail's station names, the navigation's entries
and the Apple logo in the art. The rail shows the core's ten stations
(*The rail*), and the brand draws no vendor glyph (*Direction: a panelled
instrument*). A screen never shows what the core cannot observe: no
installer percentage, time remaining or live log, and no installer "in a
new terminal window", because an installer runs on this terminal, which the
frontend hands over. The footer says *read-only* and *no system changes*
only when *Layout* allows it.

Five file names do not say what the image shows: `Inventory.png` is the
System Scan, `Resolution Review.png` the Migration Selection,
`AI Environment.png` the Migration Review, `Linux Continuation.png` the
Asahi preparation, and `Completion.png` a second qualification layout, a
verdict with its counts over a check table, which the completion screen
takes for the report.

| # | Screen | Design |
| --- | --- | --- |
| 1 | Welcome and machine identity | `Frontend Acquisition.png`: the Frontend Check, with the verified release, target and SHA-256 |
| 2 | Journey dashboard | `Journey Dashboard.png` |
| 3 | Environment scan | `Inventory.png` |
| 4 | Migration selection | `Resolution Review.png` |
| 5–9, 11 | Inventory by category | none: one list and detail in the shared look |
| — | Migration review | `AI Environment.png` |
| 12, 19 | Storage planner, with Shared creation | `Storage Planer.png` |
| 13 | Gate | `Safety Gate.png`, from the core's `gate.*` facts and its word, with no button (*Confirmation*) |
| 14 | Asahi handoff | `Asahi Handoff.png`, with the four-step stepper and check list of `Linux Continuation.png` |
| 15 | Linux continuation | the stepper layout of 14, for the network and Omarchy Mac's start |
| 18 | Omarchy progress | `Omarchy Progress.png`, honestly: upstream's signals as a check list, and "runs on tty1" in place of the bar, the times and the log |
| 20 | Restore progress | `Restore Progress.png`; the bar only from the core's counts |
| 21 | Conflict and diff | `Conflict:Diff.png` |
| 22 | Health | `Health.png` |
| 23 | Qualification | `Qualification.png`, on its check table |
| 24 | Logs and diagnostics | none: as built |
| 25 | Completion | `Completion.png` |

Every screen holds at 80×24 and at the 60×20 floor, in ASCII and with no
colour.

The first journey answer after Connecting opens Welcome, with Welcome
selected in Screens; Enter goes on to Journey. A startup-check session
(`frontend-check`, which serves the journey only) opens on Journey, never on
Welcome. A retry from the error screen opens Journey. A reread and the return
from a handoff keep the screen they are on.

## Direction: a panelled instrument

The interface is a full-screen terminal application with a strong, quiet
structure: a branded header, a navigation rail on the left, the task's
workspace in the middle, a context sidebar on the right, and a footer of keys
and authority. It is open for an afternoon of reboots, and it is read at the
moments when a mistake costs a disk, so the structure stays still and only
what the core reports changes.

- **One frame, three columns.** The frame is a title rule, a banner, a body
  and a footer; the body is the navigation rail, the workspace and the
  context sidebar. A panel has a single-line outline in the `frame` token
  with its title set into the top border in `heading`. A panel holds rows or
  one card, never a panel inside a panel inside a panel.
- **Structure at full depth, meaning always in words.** At 256 colours the
  page has a `backdrop`, cyan outlines, blue headings, and green for what is
  current, focused or ok. At sixteen colours, without colour and on the Linux
  console the same structure holds through glyphs and attributes on the
  terminal's own background. State is always a word and a glyph
  (`✓ verified`, `! needs you`, `✗ failed`), with colour only reinforcing it.
- **Human first, raw on demand.** A value is shown as a person reads it
  (`482 GB free`, `MacBookPro18,1`); its exact form — bytes, full
  identifiers, hashes, URLs — is one Enter away in a detail view. A long
  value truncates inside its panel and never crosses the border.
- **Provenance is visible.** What the machine showed this run and what was
  recorded are told apart by a word: a fact read from a record carries the
  word *recorded*.
- **Domain colours name places** — steel for macOS, coral for Linux, violet
  for boot, green for Shared, faint for free space — and appear on the disk
  strip and in small badges.
- **The disk strip is a scale bar**: proportional, with tick marks and
  labels below it, like the scale on a survey plate, so sizes are read and
  not guessed.
- **The journey is a traverse**: stations joined by a line, filled when
  done, a diamond where you are, and a dim *later* mark for a station the
  core has not derived.
- **The brand.** A block-character OMARCHY wordmark with the laptop and
  mountains art where the terminal has room (120 columns by 36 rows and up,
  Unicode); a one-line wordmark below that; plain spaced letters in ASCII.
  The art uses ASCII characters only, and nothing private-use or
  vendor-specific (no Apple logo glyph).
- **Motion only when something is happening**: a spinner after a request
  has run 150 ms, elapsed time after two seconds, determinate progress where
  the core reports counts. Nothing animates while idle.
- **Sparse where it matters, dense where it helps.** Gates, handoffs and
  reviews are sparse; the category lists and the health view are dense
  tables.

## Tokens

The frontend styles by meaning, never by literal colour. Each token has a
256-colour value, a name among the sixteen (which follow the person's
terminal theme), and a plain-attribute form.

| Token | Means | 256 | 16 | No colour |
| --- | --- | --- | --- | --- |
| `text` | body text | 253 | default | default |
| `muted` | labels, metadata | 245 | bright black | default |
| `rule` | dividers inside a panel, the rail's line | 241 | bright black | default |
| `accent` | the mark, the current station, the primary control | 78 | green | underline |
| `focus` | the focused row, field or control | reverse + 78 | reverse | reverse |
| `frame` | panel outlines and the title rule | 44 | cyan | the outline's own glyphs |
| `heading` | panel titles and section headings | 39 | blue | underline |
| `backdrop` | the page behind everything, a midnight blue field | RGB 11,31,58 on truecolor terminals; index 17 (`#00005f`) on 256-colour terminals | the terminal's own | the terminal's own |
| `selected` | an included item | 115 glyph | green glyph | the glyph alone (◉ / `[x]`) |
| `ok` | verified, passed | 115 | green | the word and ✓ / `+` |
| `info` | a note | 110 | cyan | the word |
| `warn` | needs attention | 222 | yellow | the word and ! |
| `danger` | failed, destructive | 204 | red | the word and ✗ / `x` |
| `blocked` | cannot go on | 204 | red | the word, reversed |
| `pending` | not yet | 245 | bright black | ○ / `.` |
| `gate` | a typed-word field | 253 underline | underline | underline |
| `macos`, `linux`, `boot`, `shared`, `free` | disk regions and badges | 110, 209, 141, 114, 241 | blue, bright red, magenta, green, bright black | the strip's letters (`M`, `L`, `b`, `s`, `.`) |

- **Emphasis is reverse or underline, never bold with a colour**: the Linux
  console cancels bold when a normal-intensity colour follows it. Hierarchy
  comes from the token, capitals and position, not from weight.
- **Sixteen named colours only** on the Linux console and whenever the
  terminal reports fewer than 256; true colour is never assumed.
- **The backdrop is midnight blue.** Truecolor terminals (`COLORTERM=truecolor`
  or `24bit`) use `#0B1F3A` (RGB 11,31,58). A 256-colour terminal uses
  index 17 (`#00005f`), the nearest blue; the nearer greys would lose the hue. Sixteen-colour terminals, the Linux console and
  `NO_COLOR` use the terminal's own background. Panels and spans have no
  background of their own; the page supplies one continuous field.
- **Contrast carries the palette.** Full-depth muted and pending text use
  245, headings 39, danger and blocked 204, and boot regions 141. Rule and
  free-space graphics use 241. Linux's 209 is a disk-graphic colour; text
  legends use the Text token. Editing fields use neutral Text with an
  underline, and become a warning or error colour only after a core answer.

- **`NO_COLOR` is the theme's job.** Crossterm 0.29.0 honours `NO_COLOR` by
  emitting a reset that also clears bold and reverse, which would erase the
  focus highlight; the frontend applies its own no-colour mapping (reset
  colours, attributes kept) and tells Crossterm to leave colour output
  alone. `--no-color` and `OMB_COLOR` keep the baseline's meaning.

## Glyphs

| Use | Unicode | ASCII |
| --- | --- | --- |
| mark | ◒ | `(o)` |
| station: done, current, to do, skipped, blocked | ● ◆ ○ ◌ ✗ | `*` `>` `.` `~` `x` |
| station not derived (later) | · | `_` |
| rule | ─ | `-` |
| focus pointer | ❯ | `>` |
| included, not included, opt-in | ◉ ○ ◌ | `[x]` `[ ]` `[?]` |
| ok, warn, fail, info | ✓ ! ✗ · | `+` `!` `x` `-` |
| arrow | → | `->` |
| disk strip: macOS used, macOS free, boot, Linux, Shared, free | █ ░ ▒ █ ▚ space | `M` `m` `b` `L` `s` `.` |
| tree | ▸ ▾ | `+` `-` |
| scrollbar | │ █ | `|` `#` |

ASCII is used on the Linux console (`TERM=linux`), in a non-UTF-8 locale,
and with `--ascii`, exactly as the baseline decides. Every glyph is one cell
wide; nothing uses emoji or double-width characters (Ratatui 0.30.2 still
mis-positions text after a wide character, fixed but unreleased). Several of
these shapes have *ambiguous* East Asian width; a terminal set to draw
ambiguous characters wide will misalign them, and `--ascii` is the answer.
Nerd Font icons are never used.

## Layout

The frame has four bands, top to bottom: the **title rule** (the screen's
name and the frontend's version), the **banner**, the **body**, and the
**footer** (three to five key hints generated from the keymap, then the
authority statement). The body has up to three columns: the **navigation
rail** (the screens, the current one filled), the **workspace** (the
screen's panels and, at the top of the dashboard, the journey rail), and the
**context sidebar** (the machine's identity and summary, and what comes
next).

| Width | Behaviour |
| --- | --- |
| **wide, 120+** | all three columns: navigation 24 columns wide, the sidebar about 32, the workspace the rest; lists show a detail pane beside them |
| **standard, 80–119** | navigation with short labels, and the workspace; the sidebar's panels move under the workspace's own; details open on Enter |
| **narrow, 60–79** | one pane: navigation becomes one line of screen names and the sidebar a panel of its own, opened with `s`; tables drop their lowest-priority columns (each table declares its order); the diff is unified; hints shrink to three plus `?` |
| **below 60×20** | a truthful stop: `terminal too small — needs 60×20, this is 54×18`; nothing else is drawn until it grows |

The banner has three heights: the wordmark with its art from 36 rows (and
120 columns) up, a one-line wordmark from 24 to 35 rows, and none below 24,
where the title rule carries the screen's name and the navigation line takes
the banner's place. At 80×24 the chrome is at most five rows and the body at
least nineteen. Paths truncate at the start (`…/nvim/lua/plugins.lua`),
names and prose at the end; the full value is always one Enter away. Every
list over a few hundred rows is virtualised; filters answer in under
100 ms.

**The footer says what the session can do, and the core says it.** The words
*read-only* and *no system changes* appear only when the session's `hello`
shows a read ceiling and the snapshot lists no action; otherwise the footer
states the ceiling in words. It is never fixed text.

### The rail

The journey rail is a strip across the top of the dashboard's workspace: a
glyph per station joined by a line, with each station's name beneath it from
100 columns up, and the glyphs alone with the current station's name below
that.

```text
 ●───●───◆───○───○───○───○───○───○───○     wide and standard
 survey  profile  resolve  plan  asahi  …
 ● ● ◆ ○ ○ ○ ○ ○ ○ ○   resolve · 3 of 10   narrow
 * * > . . . . . . .   resolve 3/10        narrow, ASCII
```

The ten stations are `survey`, `profile`, `resolve`, `plan`, `asahi`,
`omarchy`, `shared`, `restore`, `verify`, `done` (docs/QUALIFICATION.md).
A station that only the other system can see is drawn with its recorded
state and *recorded by macos* or *recorded by linux*. The list of stations at
the foot of the page gives every station's state and provenance, and the
core's reason for a skipped or blocked station. `[` and `]` select a station,
starting at the current one; Enter opens it. The strip's summary names the
selected station. Up/down return to the dashboard's actions.

A journey snapshot either supplies all ten `stage` records in canonical
order, or supplies none. With none, the stations keep their *later*
(`·`, muted) marks; absence never becomes *to do*. A partial or out-of-order
set, more than one `current`, a machine stage with `by`, a recorded stage
without its system, or a misplaced or missing reason refuses the new
snapshot as unrepresentable. No part of that set is adopted. The last
admitted snapshot stays with the failure beside it, or the first read opens
the error screen.

The `verify` station opens Qualification and `done` opens Completion.
Both are also entries in the navigation rail.

## Keys

The keyboard reaches everything; the mouse is not captured at all, so the
terminal's own selection keeps working — codes and tokens are meant to be
copied.

| Where | Keys |
| --- | --- |
| everywhere | `?` help · `q` quit (asks while a request runs) · `Esc` back or close · `r` refresh · `Tab`/`Shift-Tab` move focus · `L` logs · Ctrl-C and Ctrl-Z as in docs/FRONTEND.md |
| the frame | `↑` `↓` move in the focused panel · `←` `→` switch between the navigation rail and the workspace · `Enter` select · `s` the sidebar's panels at narrow widths |
| lists and tables | `↑` `↓` (and `k` `j`) · `PgUp` `PgDn` · `Home` `End` (and `g` `G`) · `Enter` open · `Space` include or exclude · `/` filter (`Esc` clears) · `f` next category · `+` include all shown · `-` exclude all shown |
| trees | `→` `←` (and `l` `h`) expand and collapse |
| text fields | typed text, `Backspace`, Ctrl-U clears, `Enter` submits, `Esc` cancels; no single-letter commands while a field has focus |
| gates | the word, `Enter` (only an exact match continues), `Esc` |
| conflicts | `k` keep (the default) · `R` replace (capital, deliberately) · `K` keep the rest · `n`/`p` next and previous · `v` side by side or unified |
| codes and tokens | `y` copies the focused one (OSC 52 where the terminal allows it; on macOS through the core's clipboard action) |

Every overflowing workspace scrolls by its rendered lines, including wrapped
text. Up/down select the next focusable row in that direction; past the
first or last row they scroll the content. Page Up/Down move a visible page,
Home/End reach the top/bottom. A screen opens at its top, with its first
focusable row selected. The window follows that row only once the person has
moved the focus or pressed a key that acts on it, and then keeps it visible.
A page whose first row lies below the fold therefore still opens at its
heading, and Enter acts on the selected row all the same: on Journey it takes
the offered step before any focus movement. Help, the brief, the gate and a
parameter form give back the page they covered as it was left, not as a page
opened anew. When a page contains only prose, the panel has the keys. An edge
arrow appears only while more lines can be reached in that direction. Text
fields keep the letter keys for typing; the vim aliases apply outside fields.

The vim letters are aliases, never the only way. Help (`?`) lists every
binding of the current screen, generated from the same keymap as the hints.

Journey reads, top to bottom: the rail; Where it stands, with the current
stage and the next step; What you can do now, with the actions the snapshot
lists, followed by the blockers, warnings and notices; Facts; Codes; and last
the list of all ten stations. The rail, the current stage and the offered step
are in view together on opening at 80×24 and at 120×40. At the standard width
the System Overview panel sits under Journey only while Journey keeps 18 rows;
below that, Welcome and Machine hold those facts.

## Confirmation

Friction follows consequence, and the core checks every word
(docs/PROTOCOL.md).

| Level | For | Form |
| --- | --- | --- |
| none | moving, selecting, filtering, looking | — |
| yes / no, default no | saving a plan, saving a profile, exporting a bundle, running a tool's own `mcp list` (it may start the tool's MCP servers) | a one-line question; Enter alone answers no |
| yes / no, default yes | the first download of the frontend itself, in the text launcher (a pinned file, checked by digest) | `[Y/n]` |
| **typed word** | every gate the baseline has — `yes` (backup), `experimental`, `launch`, `start`, `resume`, `create`, `mount`, `test` (also each qualification step) — and `restore`, `undo`, `opaque` (chosen folders, once per save), `carry` (an encrypted SSH key) | the gate screen |

Which form an action takes follows from what the core lists for it
(`choose` in `frontend/src/app.rs`): `profile.save` opens the selection's
save; an action with parameters opens its form (the planner for
`plan.save`, a generic form otherwise), whose review the core answers for
exactly what is typed before `y` sends the validated size strings and the other core `normal` values with
the review's basis; `asahi.launch` opens screen 14 and `shared.create` screen
19; any other action with a word opens the gate; the rest is sent at once.

**The gate screen** says what will happen, on what, what it does not touch,
what cannot be undone, and what will ask next (a password, a passphrase, an
upstream installer). Then one field: `Type create to continue`. There is no
button. Enter with anything but the exact word does nothing but say so; `Esc`
leaves. On a narrow terminal the gate takes the whole screen.

## States every screen has

| State | Shown as |
| --- | --- |
| loading | the last content, a spinner after 150 ms, elapsed time after 2 s |
| empty | what would appear here, and how to make it appear |
| partial | what is there, and what is missing with the reason (`apps: 2 bundles unreadable`) |
| error | what failed, `r` to retry, `L` for the log, `D` for `debug` (the agent brief with the status and doctor facts) in the notes view |
| blocked | the core's blocker text and its fix, in the `blocked` token |
| changed | the review, or the open detail, is dimmed with `changed since you looked — r` when the core refused a stale basis or a generation it no longer holds |
| no answer | "the core stopped without answering", its diagnostics file, and `D` for `debug` |
| too small | the size needed and the size now |

## Screens

Wireframes are at 80 columns in Unicode; the ASCII forms follow the glyph
table. They show each screen's content, order and keys; the frame around
them (title rule, banner, navigation rail, sidebar, footer) is the one in
*Layout*.

**Journey dashboard** (standard):

```text
 ◒ omarchy mac bootstrap                           macOS · MacBookPro18,1
 ● ● ◆ ○ ○ ○ ○ ○ ○ ○   resolve · 3 of 10
 ──────────────────────────────────────────────────────────────────────────
 ▍Resolve what comes to Linux

   Selected        118 items
   Ready           104   exact 61 · Omarchy has it 22 · runtime 6 · other 15
   Needs you         9   alternatives and unknown casks
   Staying           5   macOS only

   Next   decide the 9 open items, then save the profile
 ──────────────────────────────────────────────────────────────────────────
 ⏎ decide   ? help
```

**Inventory by category** (standard; every category is the same list, with
the items that need a decision first; at 60 columns `source` and `version`
drop; from 120 columns a detail pane beside the list holds the focused
item's choices, a folder's contents or an AI tool's components, and
narrower the detail opens on Enter):

```text
 Software  Apps  Terminal  Editors  AI  Folders  Git & SSH  Secrets  / filter
 ──────────────────────────────────────────────────────────────────────────
   name              source         version   becomes
   ◌ tailscale       cask           1.88      choose                      !
   ◉ ripgrep         brew           15.2.0    pacman ripgrep              ✓
   ◉ node            brew · nvm     22.11.0   mise node@22                ✓
 ❯ ◉ gh              brew           2.81.0    pacman github-cli           ✓
   ○ mas             brew           2.1.0     macOS only                  –
                                                       118 selected · 212
 ──────────────────────────────────────────────────────────────────────────
 space include   ⏎ details   f category   / filter   ? help
```

**Storage planner** (the scale bar; answers computed by the core):

```text
 Plan the disk                                                      1.00 TB
 ──────────────────────────────────────────────────────────────────────────
 ▕██████████████████████████▒████████████▚▚▚▚▚▚▚░▏
  0         200         400         600         800         1000 GB
  macOS 520 · boot 3 · Linux 250 · Shared 150 · free 27

 Linux    ○ Minimal 100   ◉ Balanced 250   ○ Linux-heavy 500   ○ Custom
 Shared   ○ none   ○ 50   ○ 100   ◉ 150   ○ 250   ○ Custom

 The installer asks            you type
 new size for macOS            532543MiB
 New OS size                   244140MiB
 ──────────────────────────────────────────────────────────────────────────
 ⏎ review   tab next   ? help
```

The planner opens with one validation of its displayed sizes and the
choices already entered. Size validation stops at the first missing size,
before the core returns choice defaults, so the frontend supplies its
starting presets in this one request. When another request is running as the
planner opens, that validation is owed: the page says it waits, and it is
sent once, as soon as the running request ends. The reply never triggers a
second validation. When saving, Linux and Shared keep exactly the size strings
that were validated (`200GB`, for example); byte-count `normal` records
are display values, while other choices use their returned normals. The
core returns the defaults of omitted choices as `normal` records; these fill the fields. Without saved sizes in the
snapshot, Balanced 250 GB and Shared 150 GB start selected when the
snapshot's safe maximum allows them. A preset above that maximum is muted
and says why it is unavailable. Every accepted preset change sends exactly
one validation; its response never triggers another request.

Left/right select a preset in the focused Linux or Shared row. Custom
opens a number field, followed by GB, TB and %; GB starts selected. Tab
moves from the number to its unit selector, left/right change the unit,
and Tab moves on to the next field; moving to another field by any key,
Up and Down included, leaves the unit selector, which belongs to the field it
was reached on. `200` with GB selected is sent as
`200GB`. Typing stays neutral. Once the core answers, its invalid text
appears directly under that field, or its normalized size is shown there.
The scale bar and installer answers come from the current core response.

The remaining fields are Encrypt Linux, User name, Host name, Keyboard
layout, Time zone, Locale, SSH server, GitHub user and Developer tools.
Booleans are on/off toggles operated with Space; the other choices are
text fields. Enter reviews the inputs; Enter on a current valid review
asks whether to save. A changed input needs a new core check.

Status uses non-selectable section headings: Read from this Mac now
(or Read from Linux now) and Saved progress. Model IDs and the saved file's
home-shortened path appear below the heading. Values and notes wrap; a
supported note uses the ok style. Expansions show additional context and
source rather than repeating the row's columns. A row without additional
context has no expansion. Footers show a row range only while content is
outside the panel; generation hashes and value-line counters stay internal.

System Overview shows the marketing model name when the snapshot supplies
it, with a muted Model ID below. Without that name, an Apple identifier is
labelled Model ID; a full model name read from Linux is labelled Model. Protocol system values display as macOS and Linux
in prose only. What the owner may have to type, compare or copy is shown
byte for byte as the core gave it: a run of text between spaces holding
`=` (a `name=value` field, which takes in the whole resume token), `/`, `\` or
`~` (a path, file name or command) or `@` (an address) is left alone, and
the resume token, the other codes and the user name are shown as given
whatever they spell, so a user called `linux` is shown as `linux`.
An instruction to run this interface again is replaced by its offered
step; reboot, other-system and token-command instructions stay intact.
The Screens list follows its focus, marks scrollable ends, and dims screens
without current content while keeping them reachable.

The terminal title starts as `Omarchy Installation`, follows the core's
current station as `Omarchy Installation | Step N`, and becomes
`Omarchy Installation | Done` when the final station is done. The original
title is pushed and restored on exit, panic and termination, and before a
terminal handoff. Re-entry pushes it again and restores the current title.
The Linux console and non-terminal output receive no title sequences.

A closed terminal ends input and drawing, restores what can be restored,
and records the reason in the frontend trace. EOF, terminal I/O errors,
and repeated readiness without input use the same shutdown as SIGTERM or
SIGHUP: a cancellable request is cancelled; a non-cancellable request is
followed to its core-recorded outcome before exit. Polls have a bounded
timeout and check the terminate flag before and after reading. The launcher
remains responsible for reporting and cleaning up the ended session.

Action rows show their label and the core's explanation in muted text.
Intent and scope identifiers are not appended to the label. Moving to
another screen clears the previous page's transient status. Journey facts
from saved state show `(saved record)` after the value; machine facts and
byte-valued sizes are shown in readable units, with exact source values
retained in the model and open details.

**A gate:**

```text
 Create the Shared partition
 ──────────────────────────────────────────────────────────────────────────
   Disk          disk0 · internal · the disk this plan was made on
   Where         after disk0s6 (Linux) · 150.0 GB free, read just now
   Creates       one exFAT partition named Shared, 143051 MiB
   Leaves        macOS, Linux and every other partition as they are
   Next          sudo may ask for your password, as its policy says

   Type create to continue    create▏
 ──────────────────────────────────────────────────────────────────────────
 esc cancel
```

**A conflict** (from the restore review, on request; Keep is the default,
and *keep the rest* keeps every conflict after this one):

```text
 ~/.config/starship.toml          conflict 1 of 3 · Omarchy's ↔ from macOS
 ──────────────────────────────────────────────────────────────────────────
 - format = "$directory$git_branch$character"
 + format = "$all"
   [directory]
 - truncation_length = 2
 + truncation_length = 4
 ──────────────────────────────────────────────────────────────────────────
 k keep   R replace   K keep the rest   n next   v side by side   esc back
```

**Health:**

```text
 Health                                                         c mcp list
 ──────────────────────────────────────────────────────────────────────────
 Claude Code   ✓ installed 2.1.283 · wrapper Omarchy's · ran at restore
               ✓ configured   ✓ sign-in file   MCP 8 · ! xcode-mcp macOS-only
 Codex         ✓ installed 0.157.1   ✓ configured   ✓ sign-in file   MCP 4
 OpenCode      ✓ installed 1.18.32   ✓ configured   ○ no sign-in file
 Runtimes      ✓ node 22.20.0    ✓ python 3.13.15    ✓ go 1.27.1
 Packages      ✓ 58 of 61    ✗ 3 unavailable   ⏎ details
```

**Qualification:**

```text
 Cross-system check                               Shared · disk0s7 · 1a2b3c4d
 ──────────────────────────────────────────────────────────────────────────
  1  macOS   wrote a 4.00 GiB file, digest 5f2e…c1a0            ✓ recorded
  2  Linux   read it back, digest matches; wrote its own        ✓ recorded
  3  macOS   read Linux's file and the names                    ◆ now

     Identity   Shared is disk0s7, GUID 8F2A…41C0, on this Mac's disk
 ──────────────────────────────────────────────────────────────────────────
 ⏎ read again   t run step 3 (type test)   ? help
```

### Every screen

| # | Screen | Pattern | At 60 columns | Main keys |
| --- | --- | --- | --- | --- |
| 1 | Welcome and machine identity | one page of facts: this machine, the tool and the core, the frontend's verified release (target, SHA-256), where the journey stands; facts read from a record are named *recorded* | labels shorten; the sidebar is a panel of its own (`s`) | `⏎` `?` `q` |
| 2 | Journey dashboard | the traverse (a station the core has not derived is drawn as *later*), the next step, the actions the snapshot lists (and only those), then the blockers, the views of status, doctor and details, and the list of stations | one-line rail, the card only | `⏎`, the stage's own keys |
| 3 | Environment scan | adapters with live counts and states (`done`, `partial`, `denied`) | same | Ctrl-C cancels (safe) |
| 4 | Migration selection | the categories, each with its count, whether it is included and its estimated size; defaults marked by who chose; a category opens its list | sizes drop | `Space` `⏎` |
| 5–9, 11 | Inventory by category | one list and detail, a tab per category (secrets among them), decisions first; the detail pane holds an item's choices, a folder's contents and an AI tool's components | the detail on Enter | `f` `Space` `/` `⏎` |
| — | Migration review | the summary before the install: what is selected, by category, with its estimated size, and what comes next | same | `⏎` `Esc` |
| 12 | Storage planner | scale bar, presets, the answers | the strip shortens | `Tab` `⏎` |
| 13 | Gate | the core's `gate.*` facts and one field | whole screen | the word, `⏎`, `Esc` |
| 14 | Asahi handoff | a four-step stepper over a check list: provenance, inspection, the answer card, the boot guide, the token | sections scroll | `i` inspect `y` copy; `launch` |
| 15 | Linux continuation | the stepper of 14, for the token decoded, the network and Omarchy Mac's provenance and start | same | `n` network (nmtui); `start` |
| 18 | Omarchy progress | the stepper, with upstream's signals as a check list; Omarchy Mac runs on tty1, and the screen says so | same | `r` |
| 19 | Shared creation | the region on the strip, the checks, two gates | strip hidden below 70 | `yes`, `create` |
| 20 | Restore progress | the work grouped by layer, the current item, what is blocked, handoffs announced; the bar only from the core's counts | the current group only; core item counts remain visible | `n` `p` action, `⏎` review, `d` conflicts |
| 21 | Conflict and diff | each conflict of the restore review as a diff of both sides: Keep by default, Replace, and *keep the rest* for every conflict after it | unified diff; side by side needs 120 columns | `k` Keep, `R` Replace, `K` keep following, `n` `p` `v` |
| 22 | Health | doctor's checks with restore and AI rows: each tool's observed facts (docs/AI-TOOLS.md → *What is observed*); a tool's own `mcp list` on request | one tool per group | `c` |
| 23 | Qualification | the state, Shared's identity, the due step and the three core step rows with their observed results; an offered run opens the typed `test` gate and hands off this terminal | rows wrap; recorded checksums are described in words | `⏎` reads again; `t` opens the gate, or says why it cannot: the core lists no run, or the steps are not read in full |
| 24 | Logs and diagnostics | the tool's log (the entries `logs` shows) and the core's diagnostics, a tab each; filter by level | same | `/` `Tab` `f` `⏎` |
| 25 | Completion | every stage, and the report's check table under its verdict and counts; on `q`, only when the core's `done` stage is `done`, one receipt line stays in the scrollback: `✓ journey complete · ./omarchy-bootstrap report` (ASCII: `+ journey complete - ./omarchy-bootstrap report`) | same | `q` |

## Clutter audit of this design

- **Border depth: two at most** — a panel and the card inside it. An overlay
  (a gate at wide sizes) is one, and nothing nests inside it. Every outline
  is one line.
- **Signals per state: two** — a glyph and a word — with colour reinforcing,
  never a third mark.
- **No always-on markers.** The pointer appears on the focused row only;
  included items show ◉, excluded ○, so the marker carries the one fact.
- **Chrome:** at most five of twenty-four rows at 80×24; no repeated full
  dates (times are shown once per group, relative within a session); the
  navigation rail, sidebar and footer repeat nothing the workspace says.

## Degraded and accessible

- Monochrome keeps every meaning: stations by shape, states by word, focus by
  reverse.
- The backdrop, the wordmark's gradient and the cyan and blue structure exist
  only at 256 colours and above; every other profile keeps the same
  structure and meaning through glyphs, words and reverse.
- The Linux console gets ASCII, sixteen colours, and no bold-with-colour.
- A screen reader or a script uses `--no-tui` and the one-shot commands,
  which carry the same facts as the screens (docs/FRONTEND.md → *Without
  the frontend*).
- Nothing blinks, nothing moves while idle, nothing requires the mouse.


### Restore, Health and the brief

Restore waits for the complete review and conflict list of one generation
before enabling choices. Keep is the default. Replacement destinations are
encoded as one `omb-replace` document, split only at byte boundaries that
fit the declared parts, then validated by the core. A changed generation
clears the review; `r` reads again. The progress view uses only core item
counts, announces handoffs and offers no cancellation during an action.
Unified conflict diffs fit 60 columns; `v` selects side by side when 120
columns are available.

Health groups AI tools, Restore, SSH and system checks. Each tool's facts
remain separate, and `c` offers only the `agents.mcp` action admitted in the
current snapshot. Its confirmation explains that it may start servers; a
successful listing makes no sign-in or server-health claim.

`D` opens the scrollable Debugging brief from an error. It reads scope
`debug`, snapshot then detail kind `brief`, and waits for complete current
lines. Sections come from the core; the page adds no raw logs or upstream
output. It displays `./omarchy-bootstrap debug > file` for saving a copy;
`Esc` returns to the error and `r` reads again. These pages have frames at
80×24 and 60×20 in colour and ASCII without colour; the 120×40 conflict
frame covers side by side.

### Qualification and completion

Qualification reads scope `qualify`, then pages `detail kind=step` from
that snapshot's generation. It shows `qualify.state`, `qualify.shared` and
`qualify.due` as supplied, the blocker when present, and all three rows in
order. It never computes a digest or chooses the due step. Enter asks for
one fresh snapshot; unchanged rows remain current, and changed rows are
read from the new generation. `t` offers only `qualify.run` from the current
snapshot after the complete steps arrived. The normal typed gate collects
`test`; the action's `terminal=handoff` gives the child this terminal. After
it, fresh qualification and journey snapshots are read. A failed read stays
failed until an explicit refresh.

Completion lists every stage, then the health dataset's complete
`detail kind=report` table under its verdict and counts. The verdict is
`fail` if any row is `fail`, else `warn` if any is `warn`, else `pass`.
`not-checked` contributes only to its own count. No verdict is shown while
the report is incomplete, stale or failed. The moving keys scroll from the
stages through the report at every supported size; `r` reads the journey
and report again. The receipt follows terminal restoration, once, only on
`q` from Completion with a completed `done` stage. A report verdict alone
does not establish journey completion.
