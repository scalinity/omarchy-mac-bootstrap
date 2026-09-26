# Resolution

**Status: designed for M14 (registry, provisional resolution on macOS) and
M15 (checks on the target); not implemented.**

The resolver answers one question for every selected item: *what should
exist on Omarchy, on aarch64, and how does it get there?* It is a pure,
deterministic function of reviewed data. No language model decides an
installation.

```text
resolution = resolve(items, registry, local registry, the person's decisions, availability)
```

The same inputs give byte-identical output, in inventory order, under Bash
3.2 and Bash 5, in any locale (nothing is sorted by collation). Every
resolution names the registry rule, local rule or decision that produced it.

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
| `UNRESOLVED` | nothing in the registry and no decision yet | an unknown cask |

Sensitivity is not a disposition: an item has one disposition (what happens
on the target) and one class (whether its content may travel,
docs/MIGRATION.md). A secret file is `SECRET`, not "resolved".

## Where software comes from on the target

In order of preference. Each source has a check that can be made on macOS
before Linux exists (advisory) and a check on the target (authoritative).

| # | Source | Used for | Check on macOS (advisory) | Check on the target |
| --- | --- | --- | --- | --- |
| 0 | already there | anything Omarchy installs | the registry's capability list, from Omarchy's package lists | `pacman -Q`, or the command on `PATH` |
| 1 | pacman, through `omarchy-pkg-add` | system packages and CLIs in the repositories | the aarch64 repository databases: a name or `%PROVIDES%` match with `%ARCH%` `aarch64` or `any` | `LC_ALL=C pacman -Sp --print-format '%r/%n %v %a' <name>` (no root; follows provides) |
| 2 | Omarchy's own helpers | what Omarchy installs a particular way (`omarchy-install-terminal ghostty`, `omarchy-install-dev-env <language>`) | the helper and its arguments are in the registry | the helper exists; its result is checked afterwards, never its exit status |
| 3 | mise, core runtimes | node, python, go, ruby, java, bun, deno, rust tooling | `mise lock --platform linux-arm64` (when mise is on the Mac) produces a platform URL, glibc unless intended | the same lock check, then `mise ls --json` after installing |
| 4 | mise, `aqua:`/`github:` backends | single-binary CLIs not in the repositories | as 3 | as 3 |
| 5 | Flathub | desktop applications | Flathub's summary API lists `aarch64` | `flatpak remote-info --arch=aarch64`, then a launch test |
| 6 | `uv tool` (then pipx) | Python CLIs | `uv pip compile --python-platform aarch64-manylinux_2_28 --only-binary :all:` resolves | installed with `--no-build` |
| 7 | cargo-binstall | Rust CLIs | — | installed with the `compile` and `quick-install` strategies disabled |
| 8 | `go install module@version` | Go CLIs | the module path is known | builds; small and deterministic |
| 9 | `npm install -g package@version` | Node CLIs, last | — | installed under mise's node |
| — | the AUR | never automatically | — | reported, only when its `.SRCINFO` lists `aarch64` or `any` with an aarch64 source |
| — | Linuxbrew | never by default | — | aarch64 Linux is outside Homebrew's first support tier on Arch, and it duplicates pacman |

Rules that come with the sources:

- **Nothing compiles by surprise.** mise runs with `compile` off for
  python, ruby, node and erlang, and versions are pinned (mise's default
  24-hour release age makes `latest` depend on the day). cargo-binstall may
  not compile; `uv` may not build. A source that would build something large
  is not chosen; `go install`, which compiles small modules quickly, is the
  one exception, and says so in review.
- **The repository is qualified when it must be.** Omarchy Mac lists the
  `[omarchy]` repository with `Usage = Sync`: `pacman -Si` finds its
  packages but an unqualified `pacman -S` will not install them, and
  `omarchy-pkg-add` then fails or skips. A target in that repository is
  installed only when the registry names it with its repository
  (`omarchy/<name>`), as Omarchy itself does for Hyprland.
- **Every Omarchy helper is a handoff.** Any of them may ask for `sudo`, so
  each runs with the terminal handed to it (docs/FRONTEND.md), never
  managed.
- **Exit statuses are not results.** `omarchy-pkg-add` exits 0 when it
  skipped everything; installers print success and install nothing. Every
  install is judged by the check afterwards (docs/RESTORE.md).
- **16 KiB pages.** A binary whose ELF `LOAD` segments are aligned below
  `0x4000`, or whose allocator was built for 4 KiB pages, fails on the Asahi
  kernel before it starts. The registry marks known cases; after an install,
  `readelf -lW` (when binutils is present) checks the alignment without
  running the program, and the version check runs it.
- **Package names are data, never shell.** Each method validates its target
  against its own grammar (pacman names, mise tool ids, Flathub reverse-DNS
  ids, npm names, crate names, Go module paths) and builds an argument list;
  nothing from the registry, a profile or a receipt is placed into a command
  string.

## The registry

Versioned data in this repository, `data/registry.omb`, in the record format
(docs/PROTOCOL.md), with `#` comments. It is reviewed like code.

```text
omb-registry 1
registry	version=1
# ripgrep: the same program everywhere
sw	id=sw:ripgrep	name=ripgrep
from	sw=sw:ripgrep	source=brew-formula	name=ripgrep
from	sw=sw:ripgrep	source=cargo	name=ripgrep
to	sw=sw:ripgrep	disposition=EXACT	method=pacman	target=ripgrep	keep=none	verified=2026-09-26	evidence=alarm:extra
# Node.js: a runtime, the major version kept
sw	id=sw:node	name=Node.js
from	sw=sw:node	source=brew-formula	name=node
from	sw=sw:node	source=brew-formula	name=node@22
from	sw=sw:node	source=nvm	name=node
from	sw=sw:node	source=mise	name=node
to	sw=sw:node	disposition=RUNTIME	method=mise	target=node	keep=major	verified=2026-09-26	evidence=mise-lock:linux-arm64
# Rectangle: Omarchy already tiles
sw	id=sw:rectangle	name=Rectangle
from	sw=sw:rectangle	source=brew-cask	name=rectangle
from	sw=sw:rectangle	source=app	name=com.knollsoft.Rectangle
to	sw=sw:rectangle	disposition=OMARCHY_PROVIDED	cap=cap:tiling
cap	id=cap:tiling	name=Tiling%20window%20management	provided_by=hyprland	check=pkg:hyprland
# iTerm2: Omarchy has a terminal; the person may want another
sw	id=sw:iterm2	name=iTerm2
from	sw=sw:iterm2	source=brew-cask	name=iterm2
to	sw=sw:iterm2	disposition=ALTERNATIVE	cap=cap:terminal	choices=keep-default,ghostty,kitty,alacritty
choice	id=ghostty	cap=cap:terminal	method=omarchy-helper	target=omarchy-install-terminal	arg=ghostty
```

| Record | Holds |
| --- | --- |
| `registry` | the registry's version |
| `sw` | a software id and its display name |
| `from` | one way that software appears on macOS: source kind and name (a formula, a cask token, a bundle id, a crate, an npm name, a mise tool) |
| `to` | the resolution: disposition, method, target, kept version (`none`, `major`, `minor`, `exact`), capability, choices, the date it was verified and what verified it |
| `cap` | a capability, what provides it on Omarchy, and how to check that it is there |
| `choice` | one option of an `ALTERNATIVE` |
| `alias` | a command analogue for shell aliases (below) |
| `path` | a path rule (below) |
| `class` | a sensitivity rule for a path pattern (docs/MIGRATION.md) |
| `bad16k` | software known to fail on 16 KiB pages, with the version that fixed it if any |

**Layers.** The built-in registry, then the person's own
`~/.config/omarchy-mac-bootstrap/registry.local.omb` (same format, overriding a
built-in `to` for the same software), then the decisions recorded in the
profile. A local entry that overrides a built-in one is shown in review as
"yours". The profile records the digest of each registry it used.

**Keeping it true.** Each `to` carries the date and the evidence of its
last verification. `sources --check` gains a registry section: on macOS it
reads the aarch64 databases over the network into the per-run scratch
directory and checks `EXACT` pacman targets against them, keeping nothing (it
stays a read command); on Linux it asks `pacman -Sp`. It reports drift
without editing anything.

## Two resolutions: planned and checked

1. **Planned, on macOS** (in `profile`). The registry and decisions give
   every item a disposition, method and target. The optional **availability
   check** (an act action, because it downloads) fetches the aarch64
   repository databases Omarchy Mac uses (Arch Linux ARM `core`, `extra`,
   `alarm`; `asahi-alarm`; Omarchy's aarch64 repositories on the edge
   channel), reads them with `bsdtar` and `awk` keyed by each entry's folder
   (Arch Linux ARM keeps `%PROVIDES%` in a separate `depends` file; Omarchy's
   are zstd and keep it in `desc`), asks Flathub's summary API about
   Flathub ids, runs `mise lock --platform linux-arm64` when mise is on the
   Mac, and `uv pip compile --python-platform aarch64-manylinux_2_28
   --only-binary :all:` for Python tools when uv is. mise runs in a scratch
   folder holding only the tool list this check wrote, with its config,
   data, cache and state directories and its global config file all
   redirected into that folder, so none of the person's mise configuration —
   whose hooks and `_.source` scripts would run — is loaded. Everything it
   fetched is recorded with URL, time and digest. It is
   **advisory**: Arch Linux ARM serves its databases over HTTP without
   signatures, and repositories change before Linux is installed.
2. **Checked, on Linux** (in `restore`). Every planned resolution is checked
   against the machine with the target checks above, read-only and without
   root. An item whose target is not there becomes `unavailable` with the
   reason; one whose target is available elsewhere in the preference order
   is offered as a new decision, never switched silently.

### Resolution states

| State | Means |
| --- | --- |
| `unresolved` | no rule and no decision |
| `needs-decision` | an `ALTERNATIVE`, or two rules that disagree |
| `resolved` | a disposition, method and target, planned |
| `unsupported` | `MACOS_ONLY` or `UNSUPPORTED_ARCH` |
| `ready` | the target check passed on Linux |
| `unavailable` | the target check failed on Linux; the reason is recorded |

A profile can be sealed when every included item is `resolved` or
`unsupported`; a restore can apply an item that is `ready`.

## Omarchy-provided or missing

A capability (`cap`) says what Omarchy provides and how to check it on the
machine: `pkg:hyprland`, `cmd:foot`, `file:/usr/share/omarchy/version`.
`OMARCHY_PROVIDED` is therefore a claim the target checks, not an
assumption: on Linux the check runs, and a capability that turns out to be
missing becomes an ordinary install decision. The capability list is built
from Omarchy Mac's own package lists at the verified commit
(docs/UPSTREAM.md) and re-checked by `sources --check`.

## Casks and applications

A cask or an application in `/Applications` is resolved by its cask token
or its bundle identifier. The registry says one of: the same application
exists for Linux on aarch64 (`EXACT`, by pacman, Omarchy helper or Flathub);
Omarchy provides the purpose (`OMARCHY_PROVIDED`); another program serves
it (`ALTERNATIVE`, with choices); or it is Mac-only. Application data
(`~/Library/Application Support/<App>`) is never migrated as part of an
application; where an application keeps portable settings in a known
place, its adapter says so explicitly (the editors do).

## The dependency graph

Resolution produces edges (`dep` records): an MCP server whose command is
`npx` needs `sw:node`; a Flathub application needs `sw:flatpak` and the
Flathub remote; a uv tool needs `sw:uv`; Git's `credential.helper
osxkeychain` is replaced by GitHub CLI's helper, which needs `sw:github-cli`
and a sign-in. Edges come from the registry (tools that need a runtime), from
adapters (commands named in configuration), and from decisions.

Installation runs in fixed **layers**, and an edge may only point to an
earlier layer, which makes cycles impossible and the order obvious:

| Layer | Holds | Terminal |
| --- | --- | --- |
| 1 | system packages (`omarchy-pkg-add`), Omarchy's install helpers | handoff: pacman, the helpers and `sudo` show their own output and prompts |
| 2 | runtimes (mise) | managed |
| 3 | ecosystem tools (uv, pipx, cargo-binstall, go, npm), Flathub applications | managed |
| 4 | AI tools (docs/AI-TOOLS.md) | managed |
| 5 | files: configuration and folders | managed |
| 6 | structured configuration: Git settings, MCP servers, the Bash file; the default agent through `omarchy-default-agent` | managed, except the Omarchy helper and a sign-in, which are handoffs |
| 7 | verification | managed; live checks only with consent |

Within a layer, items keep inventory order. An item whose dependency did not
finish is **blocked**, not attempted, and says through which chain ("GitHub
MCP: blocked — needs Node.js; mise could not install node 22: …"). Nothing
is reported migrated until it and everything it needs verified
(docs/RESTORE.md).

## Paths

Source-specific paths are found by rules in the registry, applied by
adapters:

| Rule | From | To | Applied |
| --- | --- | --- | --- |
| `p:home` | `/Users/<source user>/` | `/home/<target user>/`, or `~/` where the format expands it | automatically in fields an adapter knows are paths |
| `p:brew-bin` | `/opt/homebrew/bin/<name>`, `/usr/local/bin/<name>` | `<name>`, found on `PATH` | automatically in command fields, and only when `<name>` resolves to an item on the target (the edge is added) |
| `p:brew-opt` | `/opt/homebrew/opt/…`, `/opt/homebrew/Cellar/…` | — | review: a versioned install path has no general target |
| `p:shared` | `/Volumes/Shared/` (or the mount point recorded for Shared) | `/mnt/shared/` | automatically in path fields |
| `p:project` | a source project root the person mapped | the target root they chose | automatically in path fields, only for mapped roots |
| `p:apps` | `/Applications/…`, `*.app/Contents/…` | — | never: Mac-only |
| `p:library` | `~/Library/…` | — | never: Mac-only |
| `p:volumes` | `/Volumes/<other>/…` | — | never |

- **Only inside known fields.** An adapter that parses a format (an MCP
  definition, Git settings, Ghostty's `key = value` lines) applies automatic
  rules to the fields it knows are paths or commands. It never replaces text
  in a file it does not parse.
- **Plain files are reviewed, not rewritten.** In a file an adapter carries
  whole, matches are listed with line numbers and a suggested change; the
  person approves each file's changes after seeing the diff, or keeps the
  file as it is.
- **What cannot be rewritten says why:** "points into an app bundle",
  "refers to another disk", "a macOS binary".

## From Zsh to Bash

The source shell is Zsh; the target stays **Bash**, deliberately, as a
Linux and Bash learning environment. Nothing tries to make Bash behave like
Zsh; the shell adapter carries what is portable and explains the rest.

- **Read statically.** Zsh files are read as text, line by line; nothing is
  sourced or evaluated. Recognised: `alias name=value` in its simple quoted
  forms, `export NAME=value`, function headers (`name() {`, `function name`),
  `source` lines, `setopt`, plugin-manager and framework markers (Oh My Zsh,
  zinit, antidote, zplug).
- **Aliases** are checked for Zsh-only syntax (global and suffix aliases,
  parameter flags such as `${(…)`, glob qualifiers, `=cmd`, `noglob`,
  `print -P`) and for macOS-only commands. The registry's `alias` records
  give analogues: `pbcopy` → `wl-copy`, `pbpaste` → `wl-paste`, `open` →
  `xdg-open`, `caffeinate` → `systemd-inhibit`. An alias that shadows one
  Omarchy defines (`ls`, `cd`, `a`, `c`, `cx`, `cy`, `lt`, `lsa`) is shown
  beside Omarchy's: keep yours or keep Omarchy's.
- **Functions** are listed with their bodies for review and carried only when
  the person approves each one, after a warning if they use Zsh-only
  syntax; they are never converted automatically.
- **Exports** are reviewed: `EDITOR`, `VISUAL`, `PAGER`, `LESS` and the like
  carry over; `PATH` changes never do (the target's `PATH` is Omarchy's plus
  mise); `HOMEBREW_*` is dropped; anything secret-shaped is `SECRET`;
  values under `/Users/` pass through the path rules.
- **Plugins and frameworks** are not migrated. The review names the Bash
  way to the same end where there is one: completion and key bindings for
  fzf and zoxide, and Starship, which Omarchy already sets up.
- **Where it goes.** Everything approved goes into one file the tool owns,
  `~/.config/omarchy-mac-bootstrap/shell.bash`, sourced by one marked line
  appended to `~/.bashrc` after Omarchy's own `rc` line — Omarchy's
  documented place for personal additions, which its updates do not
  overwrite. `~/.bashrc` is otherwise left alone. `omarchy reinstall
  configs` rewrites `~/.bashrc` without a backup; rerunning `restore` puts
  the line back.
- **History** is `SENSITIVE` and opt-in: Zsh's extended history becomes Bash
  history format in a separate file, `~/.bash_history_macos`, and the review
  shows the one command that merges it into `~/.bash_history` if wanted.
  History settings (`HISTSIZE`, `HISTFILESIZE`) carry with the shell file.
- **Terminal tools**: Starship's configuration carries (Omarchy seeds its
  own, so it is a conflict decided at restore); tmux configuration carries
  with macOS-only lines (clipboard helpers, `reattach-to-user-namespace`)
  flagged; zoxide's database is `MACHINE_SPECIFIC` (every entry is a macOS
  path); atuin's configuration carries and its history syncs by its own
  means.

## What a language model may do

Nothing in this tool calls a model. For items left `unresolved`, the
frontend shows everything known about them (source, description, homepage,
versions), and `profile show --unresolved` (read-only) prints the same list
as records the person may give to their own agent. An agent's suggestions become real only as entries
in the person's local registry, which the resolver then reads like any other
reviewed data. The installation authority is always the registry plus the
target check.

## Why is this installed?

Every restored item keeps its provenance in the restore journal
(docs/RESTORE.md), and `restore why <name>` (read-only) answers from it:

```text
ripgrep
  source        Homebrew formula on this Mac's macOS (requested by you)
  resolution    EXACT, registry rule r:ripgrep (verified 2026-09-26)
  target        pacman extra/ripgrep 15.2.0, aarch64
  installed     2026-10-10 by omarchy-pkg-add; pacman -Q ripgrep 15.2.0-1
  verified      rg --version 15.2.0
```
