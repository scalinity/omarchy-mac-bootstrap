# The interface

**Status: designed for M14–M16; not implemented.** How the frontend
(docs/FRONTEND.md) looks and behaves. Everything on screen comes from the
core's records (docs/PROTOCOL.md); this document decides how it is shown.

## Direction: a survey plate

The baseline's identity carries over: one mark (◒, a rising sun), a journey
drawn as a line of stations, and the disk strip as the centrepiece of
planning. The interface is a **calm instrument**, not a dashboard: it is
open for an afternoon of reboots, and it is read at the moments when a
mistake costs a disk.

- **Hairlines, not boxes.** Sections are separated by one thin rule and
  whitespace. No panel is boxed; the terminal's edge is the frame. The only
  border is around an overlay (a gate at wide sizes), never nested.
- **Colour says where, words say how.** Domain colours name places — steel
  for macOS, coral for Linux, violet for boot, green for Shared, faint for
  free space — and appear on the disk strip and in small badges. State is
  always a word and a glyph (`✓ verified`, `! needs you`, `✗ failed`), with
  colour only reinforcing it.
- **The disk strip is a scale bar**: proportional, with tick marks and
  labels below it, like the scale on a survey plate, so sizes are read and
  not guessed.
- **The journey is a traverse**: stations joined by a line, filled when
  done, a diamond where you are.
- **Motion only when something is happening**: a spinner after a request
  has run 150 ms, elapsed time after two seconds, determinate progress where
  the core reports counts. Nothing animates while idle.
- **Sparse where it matters, dense where it helps.** Gates, handoffs and
  reviews are sparse; the inventory, resolution and health views are dense
  tables.

## Tokens

The frontend styles by meaning, never by literal colour. Each token maps to
the baseline's own palette (`lib/ui.sh`) in 256 colours, to the sixteen
named colours (which follow the person's terminal theme), and to plain
attributes.

| Token | Means | 256 | 16 | No colour |
| --- | --- | --- | --- | --- |
| `text` | body text | 253 | default | default |
| `muted` | labels, metadata | 245 | bright black | default |
| `rule` | hairlines, the rail's line | 239 | bright black | default |
| `accent` | the mark, the current station, headings' bar | 209 | bright red | underline |
| `focus` | the focused row or field | reverse + 209 | reverse | reverse |
| `selected` | an included item | 115 glyph | green glyph | the glyph alone (◉ / `[x]`) |
| `ok` | verified, passed | 115 | green | the word and ✓ / `+` |
| `info` | a note | 110 | cyan | the word |
| `warn` | needs attention | 222 | yellow | the word and ! |
| `danger` | failed, destructive | 204 | red | the word and ✗ / `x` |
| `blocked` | cannot go on | 204 | red | the word, reversed |
| `pending` | not yet | 245 | bright black | ○ / `.` |
| `gate` | a typed-word field | 209 underline | underline | underline |
| `macos`, `linux`, `boot`, `shared`, `free` | disk regions and badges | 110, 209, 141, 114, 239 | blue, bright red, magenta, green, bright black | the strip's letters (`M`, `L`, `b`, `s`, `.`) |

- **Emphasis is reverse or underline, never bold with a colour**: the Linux
  console cancels bold when a normal-intensity colour follows it.
- **Sixteen named colours only** on the Linux console and whenever the
  terminal reports fewer than 256; true colour is never assumed.
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

Four bands, top to bottom: a **header** line (mark, name, where: `macOS ·
MacBookPro18,2` or `Linux · root`), the **rail**, the **body**, and a
**footer** (a status line when there is something to say, then three to five
key hints generated from the keymap).

| Width | Behaviour |
| --- | --- |
| **wide, 120+** | the rail becomes a column on the left (stations with names and which system each runs on); lists show a detail pane beside them |
| **standard, 80–119** | the rail is one line; the body is one primary view; details open on Enter (from 100 columns a list may keep a narrow detail pane) |
| **narrow, 60–79** | one pane; tables drop their lowest-priority columns (each table declares its order); the diff is unified; hints shrink to three plus `?` |
| **below 60×20** | a truthful stop: `terminal too small — needs 60×20, this is 54×18`; nothing else is drawn until it grows |

At 80×24 the chrome is five rows (header, rail, two rules, hints) and the
body has nineteen. Heights from 20 to 23 merge the header into the rail line.
Paths truncate at the start (`…/nvim/lua/plugins.lua`), names and prose at
the end; the full value is always one Enter away. Every list over a few
hundred rows is virtualised; filters answer in under 100 ms.

### The rail

```text
wide (a column):          standard (one line):
 ● survey                  ● ● ◆ ○ ○ ○ ○ ○ ○ ○   resolve · 3 of 10
 │                        narrow ASCII:
 ● profile                 * * > . . . . . . .   resolve 3/10
 │
 ◆ resolve   macOS
 │
 ○ plan
 ┊
 ○ done
```

The ten stations are `survey`, `profile`, `resolve`, `plan`, `asahi`,
`omarchy`, `shared`, `restore`, `verify`, `done` (docs/QUALIFICATION.md).
A station that only the other system can see is drawn with its recorded
state and the word *recorded*.

## Keys

The keyboard reaches everything; the mouse is not captured at all, so the
terminal's own selection keeps working — codes and tokens are meant to be
copied.

| Where | Keys |
| --- | --- |
| everywhere | `?` help · `q` quit (asks while a request runs) · `Esc` back or close · `r` refresh · `Tab`/`Shift-Tab` move focus · `L` logs · `D` debug report · Ctrl-C and Ctrl-Z as in docs/FRONTEND.md |
| lists and tables | `↑` `↓` (and `k` `j`) · `PgUp` `PgDn` · `Home` `End` (and `g` `G`) · `Enter` open · `Space` include or exclude · `/` filter (`Esc` clears) · `f` next category · `+` include all shown · `-` exclude all shown |
| trees | `→` `←` (and `l` `h`) expand and collapse |
| text fields | typed text, `Backspace`, Ctrl-U clears, `Enter` submits, `Esc` cancels; no single-letter commands while a field has focus |
| gates | the word, `Enter` (only an exact match continues), `Esc` |
| conflicts | `k` keep · `R` replace (capital, deliberately) · `m` merge where offered · `s` skip · `n`/`p` next and previous · `v` side by side or unified |
| codes and tokens | `y` copies the focused one (OSC 52 where the terminal allows it; on macOS through the core's clipboard action) |

The vim letters are aliases, never the only way. Help (`?`) lists every
binding of the current screen, generated from the same keymap as the hints.

## Confirmation

Friction follows consequence, and the core checks every word
(docs/PROTOCOL.md).

| Level | For | Form |
| --- | --- | --- |
| none | moving, selecting, filtering, looking | — |
| yes / no, default no | saving a plan, finishing a profile, exporting a bundle, the availability check, starting a rescue agent, closing SSH for this boot, live checks, accepting an item as it is, saving raw diagnostics | a one-line question; Enter alone answers no |
| yes / no, default yes | the first download of the frontend itself, in the text launcher (a pinned file, checked by digest) | `[Y/n]` |
| **typed word** | every gate the baseline has — `yes` (backup), `experimental`, `launch`, `start`, `resume`, `create`, `mount`, `test` — and the new `restore`, `undo`, `import` (a foreign bundle), `opaque` (a custom path no adapter understands), `carry` (an encrypted SSH key), `ssh` (remote rescue), `harden` (the system's SSH), `remove` (rescue tools), `clean` (qualification files) | the gate screen |
| **approval code** | restoring a bundle: the `ombbundle-…` code macOS showed after the export | the gate screen, with the code's field in place of the word |

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
| error | what failed, `r` to retry, `L` for the log, `D` to prepare a debug report |
| blocked | the core's blocker text and its fix, in the `blocked` token |
| changed | the review is dimmed with `changed since you looked — r` when the core refused a stale basis |
| no answer | "the core stopped without answering", its diagnostics file, and the debug report |
| too small | the size needed and the size now |

## Screens

Wireframes are at 80 columns in Unicode; the ASCII forms follow the glyph
table.

**Journey dashboard** (standard):

```text
 ◒ omarchy mac bootstrap                           macOS · MacBookPro18,2
 ● ● ◆ ○ ○ ○ ○ ○ ○ ○   resolve · 3 of 10
 ──────────────────────────────────────────────────────────────────────────
 ▍Resolve what comes to Linux

   Selected        118 items
   Ready           104   exact 61 · Omarchy has it 22 · runtime 6 · other 15
   Needs you         9   alternatives and unknown casks
   Staying           5   macOS only
   aarch64         not checked yet

   Next   decide the 9 open items, then seal the profile
 ──────────────────────────────────────────────────────────────────────────
 ⏎ decide   c check aarch64   s seal   ? help
```

**Inventory** (standard; at 60 columns `source` and `version` drop):

```text
 Software  Apps  Terminal  Editors  AI  Dotfolders  Git & SSH      / filter
 ──────────────────────────────────────────────────────────────────────────
   name              source         version   becomes
   ◉ ripgrep         brew           15.2.0    pacman ripgrep              ✓
   ◉ node            brew · nvm     22.11.0   mise node@22                ✓
   ○ mas             brew           2.1.0     macOS only                  –
 ❯ ◉ gh              brew           2.81.0    pacman github-cli           ✓
   ◌ tailscale       cask           1.88      choose                      !
                                                       118 selected · 212
 ──────────────────────────────────────────────────────────────────────────
 space include   ⏎ details   f category   / filter   ? help
```

**Resolution review** (source and target side by side; narrow stacks each
row on two lines):

```text
 From macOS                          On Omarchy, aarch64
 ──────────────────────────────────────────────────────────────────────────
 iTerm2            cask           →  ! terminal: foot (Omarchy's) or another
 1Password         cask           →  ! no aarch64 build · alternatives
 VS Code           cask           →  ✓ pacman omarchy/visual-studio-code-bin
 GitHub MCP        Claude · user  →  ✓ claude mcp · needs node (mise 22)
                                       /opt/homebrew/bin/npx → npx
 ──────────────────────────────────────────────────────────────────────────
 ⏎ decide or details   ? help
```

**Dotfolders** (tree; at 120+ a preview pane shows the file with flagged
paths underlined and secret-shaped values masked):

```text
 Dotfolders                                                     ~ on this Mac
 ──────────────────────────────────────────────────────────────────────────
 ▸ .claude            412 MB   AI tool · on the AI screen
 ▾ .config            1.2 GB
     ◉ nvim           3.4 MB   portable
     ◉ ghostty          4 KB   portable · 2 Mac-only keys
     ○ gh               8 KB   personal · hosts.yml is secret and stays
     ○ karabiner       60 KB   Mac-only
 ▸ .ssh                24 KB   personal · 2 keys, 1 encrypted
   ◌ .scripts         120 KB   opaque · type opaque to carry
   – .zsh_history     2.1 MB   history · not carried in v1
```

**AI environment** (providers across, components down; narrow shows one
provider at a time, `Tab` to switch):

```text
 AI tools                   Claude Code       Codex            OpenCode
 ──────────────────────────────────────────────────────────────────────────
 settings                   ◉ settings.json   ◉ config.toml    ◉ opencode.json
 instructions               ◉ CLAUDE.md       ◉ AGENTS.md      ○ none
 MCP servers                ◉ 9 · 1 Mac-only  ◉ 4              ◉ 2
 skills                     ◉ 23              ◉ 6 shared       –
 agents · commands          ◉ 7 · 12          ◉ 2              ◉ 3 · 1
 plugins                    ◉ 5 reinstalled   –                ◌ 1 runs code
 hooks                      ! 3 run commands  –                –
 sessions · history         – not in v1       – not in v1      – not in v1
 sign-in                    again on Linux    again            again
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

**A conflict:**

```text
 ~/.config/starship.toml                    Omarchy's default ↔ from macOS
 ──────────────────────────────────────────────────────────────────────────
 - format = "$directory$git_branch$character"
 + format = "$all"
   [directory]
 - truncation_length = 2
 + truncation_length = 4
 ──────────────────────────────────────────────────────────────────────────
 k keep   R replace   s skip   n next   v side by side   esc back
```

**Health:**

```text
 Health                                               static · c live checks
 ──────────────────────────────────────────────────────────────────────────
 Claude Code   ✓ installed 2.1.283 · wrapper Omarchy's · ran at restore
               ✓ settings  ✓ skills 23  MCP 8 ok · ! xcode-mcp macOS-only
 Codex         ✓ installed 0.157.1   ✓ config   ✓ skills 6   ✓ MCP 4
 OpenCode      ✓ installed 1.18.32   ! kept Omarchy's opencode.json
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
 ⏎ run step 3   ? help
```

### Every screen

| # | Screen | Pattern | At 60 columns | Main keys |
| --- | --- | --- | --- | --- |
| 1 | Welcome and machine identity | one page of facts; records from another Mac named | labels shorten | `⏎` `?` `q` |
| 2 | Journey dashboard | traverse and the current stage's card | one-line rail, the card only | `⏎`, the stage's own keys |
| 3 | Environment scan | adapters with live counts and states (`done`, `partial`, `denied`) | same | Ctrl-C cancels (safe) |
| 4 | Migration selection | category tabs over lists, defaults marked by who chose | tabs become one picker line | `Tab` categories |
| 5 | Homebrew and tool inventory | virtualised table, detail on Enter | source and version drop | `Space` `/` `f` `⏎` |
| 6 | Resolution review | source → target, decisions first | two-line rows | `⏎` |
| 7 | Application alternatives | an app's purpose and its choices | the choices full screen | `⏎` |
| 8 | Dotfolder picker | tree with badges, preview at 120+ | preview on Enter | `→` `←` `Space` `⏎` |
| 9 | AI environment | providers × components matrix, drill into one | one provider at a time | `Tab` `⏎` |
| 10 | Path rewrites | per file: found → proposed, diff | diff on Enter | `a` approve `d` decline |
| 11 | Secrets and sensitive data | secrets (staying, with how to sign in again), sensitive opt-ins, findings in selected files | same | `Space`; `carry` gate for an encrypted key |
| 12 | Storage planner | scale bar, presets, the answers | the strip shortens | `Tab` `⏎` |
| 13 | Gate | the facts and one field | whole screen | the word, `⏎`, `Esc` |
| 14 | Asahi handoff | provenance, inspection, answer card, boot guide, token | sections scroll | `i` inspect `y` copy; `launch` |
| 15 | Linux continuation | token decoded, network, Omarchy Mac provenance | same | `n` network (nmtui); `start` |
| 16 | Rescue | the options and their states (docs/RESCUE.md) | same | `⏎` |
| 17 | Debug report | the safe fields by group, preview; raw diagnostics offered separately, marked potentially sensitive | preview on Enter | `s` save `⏎` |
| 18 | Omarchy progress | upstream's signals as a checklist; where upstream prints (tty1) | same | `r` |
| 19 | Shared creation | the region on the strip, the checks, two gates | strip hidden below 70 | `yes`, `create` |
| 20 | Restore progress | the graph's work grouped by layer, the current node, blocked chains, handoffs announced | the current group only | Ctrl-C between items |
| 21 | Conflict and diff | both sides, the choices | unified only | `k` `R` `m` `s` `n` `v` |
| 22 | Health | tools × observed states (docs/AI-TOOLS.md → *What is observed*), live checks on request | one tool per group | `c` |
| 23 | Qualification | the steps, identity, digests | digests shortened | `⏎`; `test` |
| 24 | Logs and diagnostics | the tool's log, the core's diagnostics, the restore journal; filter by level | same | `/` `Tab` `f` |
| 25 | Completion | every stage and the report; on quit, one receipt line stays in the scrollback: `✓ journey complete · ./omarchy-bootstrap report` | same | `q` |

## Clutter audit of this design

- **Border depth: zero** on every screen; one (the overlay) for a gate at
  wide sizes. No box contains another.
- **Signals per state: two** — a glyph and a word — with colour reinforcing,
  never a third mark.
- **No always-on markers.** The pointer appears on the focused row only;
  included items show ◉, excluded ○, so the marker carries the one fact.
- **Chrome:** five of twenty-four rows at 80×24; no repeated full dates
  (times are shown once per group, relative within a session).

## Degraded and accessible

- Monochrome keeps every meaning: stations by shape, states by word, focus by
  reverse.
- The Linux console gets ASCII, sixteen colours, and no bold-with-colour.
- A screen reader or a script uses `--no-tui` and the one-shot commands,
  which carry the same facts as the screens (docs/FRONTEND.md → *Without
  the frontend*).
- Nothing blinks, nothing moves while idle, nothing requires the mouse.
