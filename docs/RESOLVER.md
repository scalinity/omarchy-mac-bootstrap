# Resolution

**Status: built in Gate 4 (`lib/migrate_resolve.sh`,
`data/migration-map.omb`); the check on Linux comes with M15-A.**

The resolver answers one question for every selected item: *what should
exist on Omarchy, on aarch64, and how does it get there?* It is a pure,
deterministic function of reviewed data. No language model decides an
installation.

```text
resolution = resolve(selected items, the migration map, the person's decisions)
```

The same inputs give byte-identical output under Bash 3.2 and Bash 5, in
any locale (nothing is sorted by collation): resolutions are listed in
inventory order. Every resolution names the map entry or the decision that
produced it.

## Dispositions

| Disposition | Means | Example |
| --- | --- | --- |
| `EXACT` | the same software exists natively for Omarchy on aarch64 | Homebrew `ripgrep` → pacman `ripgrep` |
| `OMARCHY_PROVIDED` | Omarchy already provides the capability; nothing to install | Rectangle → Hyprland tiling; `fzf`, `zoxide`, `starship` |
| `NATIVE_EQUIVALENT` | the same capability through a different target package or name | `gh` → `github-cli`; `nvim` → `neovim`; GNU `coreutils` → the base system |
| `RUNTIME` | a language runtime, installed through mise at a kept version | `node` 22.x → `mise use -g node@22` |
| `ECOSYSTEM` | a tool installed through its own ecosystem | a `uv tool`, a Go module, a crate through cargo-binstall |
| `ALTERNATIVE` | a different Linux program for the same purpose; the person chooses | iTerm2 → foot (Omarchy's default), Ghostty, Kitty or Alacritty |
| `MACOS_ONLY` | exists only on macOS | `mas`, `pinentry-mac`, Xcode, Keychain tools |
| `UNSUPPORTED_ARCH` | exists for Linux, but not for aarch64 (or only built for 4 KiB pages) | an x86-only AppImage; a Flathub app without an aarch64 build |
| `UNRESOLVED` | nothing in the map and no decision yet | an unknown cask |

Sensitivity is not a disposition: an item has one disposition (what happens
on the target) and one class (whether its content may travel,
docs/MIGRATION.md). A secret file is `secret`, not "resolved".

## Where software comes from on the target

In order of preference. Nothing checks availability on macOS; the check on
the target decides.

| # | Source | Used for | Check on the target |
| --- | --- | --- | --- |
| 0 | already there | what Omarchy provides | the map entry's check (*Omarchy-provided or missing*) |
| 1 | pacman, through `omarchy-pkg-add` | system packages and CLIs in the repositories | `LC_ALL=C pacman -Si <name>` before installing (no root), `pacman -Q` after |
| 2 | Omarchy's own helpers | what Omarchy installs a particular way (`omarchy-install-terminal ghostty`, `omarchy-install-dev-env <language>`) | the helper exists; its result is checked afterwards, never its exit status |
| 3 | mise, core runtimes | node, python, go, ruby, java, bun, deno, rust tooling | the version folder under mise's installs, after installing |
| 4 | mise, `aqua:`/`github:` backends | single-binary CLIs not in the repositories | as 3 |
| 5 | Flathub | desktop applications | printed as a command to run by hand; Omarchy does not install Flatpak |
| 6 | `uv tool` | Python CLIs, pipx's included | installed with `--no-build`; the tool's folder afterwards |
| 7 | cargo-binstall | Rust CLIs | printed as a command to run by hand |
| 8 | `go install module@version` | Go CLIs | printed as a command to run by hand |
| 9 | `npm install -g package@version` | Node CLIs, last | installed under mise's node; the package folder afterwards |
| — | the AUR | never automatically | — |
| — | Linuxbrew | never by default | aarch64 Linux is outside Homebrew's first support tier on Arch, and it duplicates pacman |

Rules that come with the sources:

- **No implicit source build.** mise runs with `compile` off for python,
  ruby, node and erlang, at pinned versions (mise's default 24-hour release
  age makes `latest` depend on the day); uv installs binary wheels only
  (`--no-build`); the printed cargo-binstall command disables its `compile`
  and `quick-install` strategies; the AUR is never used automatically.
  `go install module@version` compiles by design (small, quick,
  deterministic), and the person runs it. An unsupported package never
  falls back to building.
- **The repository is qualified when it must be.** Omarchy Mac lists the
  `[omarchy]` repository with `Usage = Sync`: `pacman -Si` finds its
  packages but an unqualified `pacman -S` will not install them, and
  `omarchy-pkg-add` then fails or skips. A target in that repository is
  named in the map with its repository (`omarchy/<name>`), as Omarchy
  itself does for Hyprland.
- **Every Omarchy helper is a handoff.** Any of them may ask for `sudo`, so
  each runs with the terminal handed to it (docs/FRONTEND.md), never
  managed.
- **Exit statuses are not results.** `omarchy-pkg-add` exits 0 when it
  skipped everything; installers print success and install nothing. Every
  install is judged by the check afterwards (docs/RESTORE.md).
- **16 KiB pages.** A binary whose ELF `LOAD` segments are aligned below
  `0x4000`, or whose allocator was built for 4 KiB pages, fails on the Asahi
  kernel before it starts. The map marks known cases `UNSUPPORTED_ARCH`;
  after an install, `readelf -lW` (when binutils is present) checks the
  alignment without running the program.
- **Package names are data, never shell.** Each method checks its target
  against its own grammar (pacman names, mise tool ids, Flathub reverse-DNS
  ids, npm names, crate names, Go module paths) and passes it as one element
  of an argument array; nothing from the map, a profile, a bundle or a
  receipt is placed into a command string.

## Omarchy-provided or missing

An `OMARCHY_PROVIDED` entry names how Linux shows the capability is there:
`pkg:hyprland` (`pacman -Q`), `cmd:foot` (the command on `PATH`) or
`file:/usr/share/omarchy/version`. The claim is checked on Linux,
read-only, never assumed: a capability that turns out to be missing becomes
an ordinary install decision. These entries come from Omarchy Mac's own
package lists at the verified commit (docs/UPSTREAM.md).

## The migration map

`data/migration-map.omb` is an `omb-migration-map 1` document in the record
format, sealed, at most 1 MiB, admitted like every other (docs/PROTOCOL.md
→ §2) and reviewed like code. It is written for the owner's own inventory:
what the everyday Mac holds, and what each becomes on Omarchy Mac on
aarch64; every entry's `note` says where its target was confirmed (the Arch
Linux ARM aarch64 databases, the `[omarchy]` repository, Omarchy Mac's
package lists, Flathub, the tool's own releases). What it does not name is
`unresolved`, and the person decides. `lib/migrate_resolve.sh` defines the
family (`_recx_map`); the generator that writes and seals it is kept beside
the map's review, not in the tool.

```text
omb-migration-map 1
note	text=…
map	id=bat	source=brew-formula	name=bat	disposition=OMARCHY_PROVIDED	method=	target=	keep=	check=pkg:bat	note=…
map	id=binutils	source=brew-formula	name=binutils	disposition=EXACT	method=pacman	target=binutils	keep=	check=	note=…
map	id=cliclick	source=brew-formula	name=cliclick	disposition=ALTERNATIVE	method=	target=	keep=	check=	note=…
choice	map=cliclick	id=keep-default	label=Leave%20it:%20Omarchy%27s%20wtype%20types%20keys	method=	target=
choice	map=cliclick	id=ydotool	label=ydotool:%20keyboard%20and%20mouse%20input	method=pacman	target=ydotool
```

| Record | Schema | Holds |
| --- | --- | --- |
| `note` * | `text:text` | a note for people; the resolver ignores it |
| `map` * | `id:id source:enum(brew-formula\|brew-cask\|app\|cargo\|npm\|pnpm\|bun\|nvm\|mise\|asdf\|uv\|pipx\|go\|ai) name:bytes disposition:enum(EXACT\|OMARCHY_PROVIDED\|NATIVE_EQUIVALENT\|RUNTIME\|ECOSYSTEM\|ALTERNATIVE\|MACOS_ONLY\|UNSUPPORTED_ARCH) method:enum(pacman\|mise\|mise-backend\|flatpak\|uv\|cargo-binstall\|go\|npm\|agent)? target:bytes? keep:enum(major\|minor\|exact)? check:bytes? note:text?` | what one macOS item becomes: a method and target, how much of a runtime's version is kept, or the check that shows Omarchy provides it |
| `choice` * | `map:id id:id label:text method:enum(…)? target:bytes?` | one option of an `ALTERNATIVE`; `keep-default`, with no method, keeps Omarchy's own |

The records come in that order: notes, the entries, then the choices. An
item's `source` is its kind in the inventory, and an application's `name`
its bundle id; the AI tools are `source=ai` with `claude-code`, `codex` and
`opencode`, installed by `method=agent` (docs/AI-TOOLS.md). Entries with one
method and target are one program, so Homebrew's `node` and nvm's are both
mise's `node`. A map that admits but breaks a rule — a source and name used
twice, a target outside its method's grammar, a disposition without the
method, target, keep or check it needs, a choice of an entry that is not an
`ALTERNATIVE`, or an `ALTERNATIVE` without choices — is refused whole, and
nothing resolves.

## Resolved on macOS, checked on Linux

1. **On macOS**, in `profile`: `res_resolve` gives every selected item a
   `resolution` record in the profile, from the map and the person's
   decisions, in the inventory's order. Nothing is fetched: whether a
   package exists for aarch64 is decided on Linux.
2. **On Linux**, in `restore` (docs/RESTORE.md): before anything installs,
   each package is looked up with `LC_ALL=C pacman -Si <name>` (no root;
   it matches names only, so the map names the package itself), and each
   other method's own tool is looked for. An item that passes is `ready`;
   one that fails is `unavailable`, with the reason, and is never switched
   silently to another source.

| Record | Schema |
| --- | --- |
| `resolution` (in the profile) | `id:bytes layer:enum(packages\|runtimes\|tools\|ai\|files\|settings\|none) method:id target:bytes? version:bytes? guess:bool state:enum(resolved\|unresolved\|needs-decision\|unsupported\|mac-only\|skipped) note:text?` |

A resolution's method is the map's, or `provided` (Omarchy has it, with the
entry's check), `carry` (a file the bundle carries), `git`, `mcp` or
`plugin` (a setting), or `none`; its `note` names the map entry or decision
that produced it. The layer follows the method: pacman and `provided` are
packages; mise is runtimes; mise backends, Flathub, uv, cargo-binstall, go
and npm are tools; `agent` is AI tools; `carry` is files; `git`, `mcp` and
`plugin` are settings.

### The person's decisions

What the map does not settle is a decision, recorded as `decision
id:bytes choice:id value:bytes?` (the profile's choices,
docs/MIGRATION.md → *On the wire*):

- an `ALTERNATIVE`: one of its `choice` ids, `keep-default` among them;
- several versions of one runtime on the Mac: `version:<V>`, one this Mac
  has, since each runtime has one version;
- an item the map does not name: `skip` (it is left out), or `pacman`
  with the package name as its value, trying that package: shown as a
  guess, and checked on Linux like any other.

The `choices` detail lists what each open item offers (`res_choices`).

### Resolution states

| State | Means |
| --- | --- |
| `unresolved` | no map entry and no decision |
| `needs-decision` | the map offers choices, or the Mac has several versions of one runtime, and the person has not chosen |
| `resolved` | a method and target, from the map or a decision (a guess marked as one) |
| `unsupported` | `UNSUPPORTED_ARCH`: shown with the reason, never installed |
| `mac-only` | `MACOS_ONLY`: shown with the reason, never installed |
| `skipped` | the person chose to leave it out |
| `ready` | on Linux, the check before installing passed |
| `unavailable` | on Linux, that check failed; the reason is recorded, and nothing is tried in its place |

A profile is `saved` when every included item is `resolved`,
`unsupported`, `mac-only` or `skipped`; restore installs an item only when
it is `ready`.

## Layers

The work on Linux runs in six fixed layers, in this order, and within a
layer in inventory order:

| Layer | Holds | Terminal |
| --- | --- | --- |
| 1 packages | pacman packages, through one `omarchy-pkg-add` handoff; Omarchy's install helpers | handoff: pacman, the helpers and `sudo` show their own output and prompts |
| 2 runtimes | mise runtimes, one version each | managed |
| 3 ecosystem tools | mise backends, npm and uv tools; cargo-binstall, go and Flathub printed as commands to run by hand | managed |
| 4 AI tools | Claude Code, Codex and OpenCode, installed with `mise use -g` (docs/AI-TOOLS.md) | managed; a sign-in is a handoff |
| 5 files | configuration files and folders, placed (docs/RESTORE.md) | managed |
| 6 settings | Git settings, MCP servers, plugins, the line that sources `shell.bash` | managed |

What an item needs sits in an earlier layer (a runtime before the npm
tools under it, a tool before the settings that name it) or is its own
package manager's business, so the fixed order is the whole ordering.

## Casks and applications

A cask or an application in `/Applications` is resolved by its cask token
or its bundle identifier. The map says one of: the same application exists
for Linux on aarch64 (`EXACT`, by pacman, Omarchy helper or Flathub);
Omarchy provides the purpose (`OMARCHY_PROVIDED`); another program serves
it (`ALTERNATIVE`, with choices); or it is Mac-only. Application data
(`~/Library/Application Support/<App>`) is never migrated as part of an
application; where an application keeps portable settings in a known
place, its adapter says so explicitly (the editors do).

## Paths

Three rules rewrite macOS paths, and only inside fields an adapter parses
and knows to be paths or commands (an MCP definition, Git settings,
Ghostty's `key = value` lines):

| Rule | From | To |
| --- | --- | --- |
| `p:home` | `/Users/<source user>/` | `/home/<target user>/`, or `~/` where the format expands it |
| `p:brew-bin` | `/opt/homebrew/bin/<name>`, `/usr/local/bin/<name>` | `<name>`, found on `PATH`, only when `<name>` is an item that reaches Linux |
| `p:shared` | `/Volumes/Shared/` (or the mount point recorded for Shared) | `/mnt/shared/` |

A file carried whole is never rewritten: its macOS paths are listed in the
review, with line numbers. Any other macOS path in a parsed field stays as
it is and says why: a versioned Homebrew path (`/opt/homebrew/opt/…`,
`Cellar`), "points into an app bundle" (`/Applications/…`), "Mac-only"
(`~/Library/…`), "refers to another disk" (`/Volumes/<other>/…`).

## From Zsh to Bash

The source shell is Zsh; the target stays **Bash**, deliberately, as a
Linux and Bash learning environment. Nothing tries to make Bash behave like
Zsh; the shell adapter carries what is portable and explains the rest.

- **Read as text, with a lexical tracker.** Nothing is sourced or
  evaluated. From the top of each file, a conservative tracker follows
  quotes, backslash continuations, here-documents (`<<WORD`, `<<-`, quoted
  words), function bodies, compound commands (`if`…`fi`, `case`…`esac`,
  loops, `{`…`}`, `(`…`)`), `$(`…`)` and backquotes. A line is
  **top-level** only if it starts and ends outside all of these; from the
  first line the tracker cannot follow to the end of that file, every line
  is review-only.
- **Two forms become Bash, as whole top-level lines, and nothing else:**
  - `alias NAME='VALUE'` or `alias NAME="VALUE"`: `NAME` is
    `[A-Za-z0-9_.][A-Za-z0-9_.-]*`; `VALUE` is one line of printable ASCII
    without the quote character, `$`, a backquote, `\` or `!` (no expansion,
    no substitution, no history). Not `alias -g` or `alias -s`.
  - `export NAME=VALUE` (unquoted `VALUE` in `[A-Za-z0-9_./:@%+=,-]*`, or
    quoted as above), only for names on the adapter's allowlist (`EDITOR`,
    `VISUAL`, `PAGER`, `MANPAGER`, `LESS`, `BAT_THEME`, `FZF_DEFAULT_OPTS`,
    `HISTSIZE`, `HISTFILESIZE` and the like) and values that pass the
    credential rules; a value under `/Users/` passes through `p:home`.
- **Aliases** for macOS-only commands take the adapter's analogues:
  `pbcopy` → `wl-copy`, `pbpaste` → `wl-paste`, `open` → `xdg-open`,
  `caffeinate` → `systemd-inhibit`. An alias that shadows one Omarchy
  defines (`ls`, `cd`, `a`, `c`, `cx`, `cy`, `lt`, `lsa`) is a decision:
  keep yours or Omarchy's.
- **Everything else is listed, not carried**: functions, command
  substitutions, conditional or multi-line definitions, arrays, `source`
  and `.`, `setopt`, `bindkey`, `autoload`, `zstyle`, prompt settings,
  plugin managers, any other export. Functions are not carried as code. The
  review names the Bash way to the same end where there is one: completion
  and key bindings for fzf and zoxide, and Starship, which Omarchy already
  sets up.
- **Never carried**: `PATH` changes (the target's `PATH` is Omarchy's plus
  mise), `HOMEBREW_*`, `DYLD_*`, `LD_*`, anything credential-shaped.
- **Where it goes.** What becomes Bash goes into one file the tool owns,
  `~/.config/omarchy-mac-bootstrap/shell.bash`, sourced by one marked line
  appended to `~/.bashrc` after Omarchy's own `rc` line — Omarchy's
  documented place for personal additions, which its updates do not
  overwrite; `~/.bashrc` is otherwise left alone. `omarchy-reinstall-configs`
  rewrites `~/.bashrc` without a backup; rerunning `restore` puts the line
  back. The Zsh rc files travel as reference copies into
  `~/.config/omarchy-mac-bootstrap/zsh/`, to read; nothing sources them.
- **History** content does not travel in v1; history settings (`HISTSIZE`,
  `HISTFILESIZE`) carry in `shell.bash`.
- **Terminal tools**: Starship's configuration carries (Omarchy seeds its
  own, so it is a conflict decided at restore); tmux's carries with
  macOS-only lines (clipboard helpers, `reattach-to-user-namespace`)
  flagged; zoxide's database is `mac-only` (every entry is a macOS path);
  atuin's configuration carries, and its history syncs by its own means.

## What a language model may do

Nothing in this tool calls a model. `profile show --unresolved` prints the
unresolved items as records, with everything known about them (source,
description, homepage, versions), for the person to give to their own
agent. A suggestion becomes real only as the person's decision (a guess
checked on Linux) or as an entry added to the migration map, which is
reviewed like code.
