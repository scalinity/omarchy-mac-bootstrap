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

The same inputs give byte-identical output under Bash 3.2 and Bash 5, in
any locale (nothing is sorted by collation): resolutions are listed in
inventory order, and the order of work is the graph's (*The graph*). Every
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
| 3 | mise, core runtimes | node, python, go, ruby, java, bun, deno, rust tooling | `mise lock --platform linux-arm64` (when mise is on the Mac) produces a platform URL, glibc unless intended | the same lock check, then the version folder under mise's installs after installing |
| 4 | mise, `aqua:`/`github:` backends | single-binary CLIs not in the repositories | as 3 | as 3 |
| 5 | Flathub | desktop applications | Flathub's summary API lists `aarch64` | `flatpak remote-info --arch=aarch64`, then a launch test |
| 6 | `uv tool` (then pipx) | Python CLIs | `uv pip compile --python-platform aarch64-manylinux_2_28 --only-binary :all:` resolves | installed with `--no-build` |
| 7 | cargo-binstall | Rust CLIs | — | installed with the `compile` and `quick-install` strategies disabled |
| 8 | `go install module@version` | Go CLIs | the module path is known | builds; small and deterministic |
| 9 | `npm install -g package@version` | Node CLIs, last | — | installed under mise's node |
| — | the AUR | never automatically | — | reported, only when its `.SRCINFO` lists `aarch64` or `any` with an aarch64 source |
| — | Linuxbrew | never by default | — | aarch64 Linux is outside Homebrew's first support tier on Arch, and it duplicates pacman |

Rules that come with the sources:

- **No implicit source build.** mise runs with `compile` off for python,
  ruby, node and erlang, and versions are pinned (mise's default 24-hour
  release age makes `latest` depend on the day); cargo-binstall runs with its
  `compile` and `quick-install` strategies disabled; uv and pipx install
  binary wheels only (`--no-build`, `--only-binary :all:`); the AUR is never
  used automatically. A build happens only when the chosen method *is* a
  build and the review says so: `go install module@version` compiles by
  design (small, quick, deterministic), and the person approves it like any
  other item. An unsupported package never falls back to building.
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

Versioned data in this repository, `data/registry.omb`, an `omb-registry 1`
document in the record format, admitted like every other (docs/PROTOCOL.md
→ §2). Notes for people are `note` records, never comment lines. It is
reviewed like code.

```text
omb-registry 1
registry	version=1
note	text=ripgrep:%20the%20same%20program%20everywhere
sw	id=sw:ripgrep	name=ripgrep
from	sw=sw:ripgrep	source=brew-formula	name=ripgrep
from	sw=sw:ripgrep	source=cargo	name=ripgrep
to	sw=sw:ripgrep	disposition=EXACT	method=pacman	target=ripgrep	keep=none	cap=	verified=2026-09-26	evidence=alarm:extra
note	text=Node.js:%20a%20runtime,%20the%20major%20version%20kept
sw	id=sw:node	name=Node.js
from	sw=sw:node	source=brew-formula	name=node
from	sw=sw:node	source=brew-formula	name=node@22
from	sw=sw:node	source=nvm	name=node
from	sw=sw:node	source=mise	name=node
to	sw=sw:node	disposition=RUNTIME	method=mise	target=node	keep=major	cap=cap:node	verified=2026-09-26	evidence=mise-lock:linux-arm64
note	text=Rectangle:%20Omarchy%20already%20tiles
sw	id=sw:rectangle	name=Rectangle
from	sw=sw:rectangle	source=brew-cask	name=rectangle
from	sw=sw:rectangle	source=app	name=com.knollsoft.Rectangle
to	sw=sw:rectangle	disposition=OMARCHY_PROVIDED	method=	target=	keep=	cap=cap:tiling	verified=2026-09-26	evidence=omarchy:hyprland
note	text=iTerm2:%20Omarchy%20has%20a%20terminal%3B%20the%20person%20may%20want%20another
sw	id=sw:iterm2	name=iTerm2
from	sw=sw:iterm2	source=brew-cask	name=iterm2
to	sw=sw:iterm2	disposition=ALTERNATIVE	method=	target=	keep=	cap=cap:terminal	choice=keep-default	choice=ghostty	choice=kitty	choice=alacritty	verified=2026-09-26	evidence=omarchy:terminals
cap	id=cap:tiling	name=Tiling%20window%20management	provided_by=hyprland	check=pkg:hyprland
choice	id=ghostty	cap=cap:terminal	method=omarchy-helper	target=omarchy-install-terminal	arg=ghostty
```

| Record | Schema | Holds |
| --- | --- | --- |
| `registry` 1 | `version:uint` | the registry's version |
| `note` * | `text:text` | a note for people; the resolver ignores it |
| `sw` * | `id:id name:text` | a software id and its display name |
| `from` * | `sw:id source:enum(brew-formula\|brew-cask\|app\|cargo\|npm\|pnpm\|bun\|nvm\|mise\|asdf\|uv\|pipx\|go) name:bytes` | one way that software appears on macOS |
| `to` * | `sw:id disposition:enum(EXACT\|OMARCHY_PROVIDED\|NATIVE_EQUIVALENT\|RUNTIME\|ECOSYSTEM\|ALTERNATIVE\|MACOS_ONLY\|UNSUPPORTED_ARCH) method:id? target:bytes? keep:enum(none\|major\|minor\|exact)? cap:id? choice:id* verified:id evidence:id` | the resolution, the date it was verified and what verified it |
| `cap` * | `id:id name:text provided_by:id check:id` | a capability, what provides it on Omarchy, and how to check that it is there |
| `choice` * | `id:id cap:id method:id target:bytes arg:bytes*` | one option of an `ALTERNATIVE` |
| `alias` * | `from:bytes to:bytes` | a command analogue for shell aliases (*From Zsh to Bash*) |
| `path` * | `rule:id from:bytes to:bytes? applied:enum(auto\|review\|never)` | a path rule (*Paths*) |
| `class` * | `pattern:bytes class:enum(PUBLIC_CONFIG\|PRIVATE_CONFIG\|SENSITIVE\|OPAQUE\|SECRET\|MACHINE_SPECIFIC)` | a sensitivity rule for a path pattern (docs/MIGRATION.md) |
| `bad16k` * | `sw:id fixed:id?` | software known to fail on 16 KiB pages, with the version that fixed it if any |

**Order.** After `registry`, records are grouped by software: a `sw`
record, then its `from` records, then its `to` records; `note` records may
stand anywhere after `registry`; `cap`, `choice`, `alias`, `path`, `class`
and `bad16k` records follow all the software groups, each type together.

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

## The graph

The order of work is a **bounded, deterministic directed acyclic graph**.
The seven *layers* below remain, but only as the groups the screens show and
the terminal mode each group needs; they do not decide the order.

### Nodes and edges

| Node | Is | Example |
| --- | --- | --- |
| `need` | one consumer's requirement for a capability, with a version constraint (`any`, `major N`, `minor N.M`, `exact V`) | the GitHub MCP server needs a Node runtime, major 22 |
| `instance` | one provider installing one version of one software id: method, target, version | `mise node@22`, `mise node@24`, `pacman ripgrep` |
| `config` | writing or transforming configuration | re-create an MCP server; place `starship.toml`; add the Bash line |
| `verify` | a check after the fact | `mise exec node@22 -- node --version` |

Capabilities (`cap` in the registry) connect needs to the instances that can
satisfy them; software ids stay the display grouping. Edges are `requires`
(the consumer runs only if its target succeeded or was already satisfied),
`optional` (the consumer runs regardless; a failed target leaves it
`degraded`), `orders` (sequence without dependency: a package before
configuration of the same program) and `conflicts` (two instances that
cannot both be present: the registry's conflicts, or two instances that
would put the same command first on `PATH`), which is never ordered but
always a decision — keep one, or leave both out. Edges come from the
registry, from adapters (the commands a configuration names) and from
decisions.

### From needs to instances

1. Collect every need for a capability with its constraint.
2. A capability already satisfied on the target (its `cap` check, read-only)
   satisfies its needs; no instance is made.
3. Otherwise take the capability's providers in preference order (the
   registry's, then *Where software comes from*) and the first that can meet
   the constraints.
4. When one version meets every consumer's constraint, one instance serves
   them all. When none does, it is a **decision**: one version for all (the
   screen names whose constraint breaks), side-by-side instances where the
   provider supports them (mise installs several versions; the global default
   is one, and a consumer pinned to another has its command wrapped as `mise
   exec <tool>@<version> --`, shown as a rewrite), or leaving consumers out.
   With no supported option the conflicting consumers are `unsupported`.
5. Alternatives (an `ALTERNATIVE`, or providers of equal rank) are decisions.

There is no solver: every step is deterministic, and every non-obvious choice
is put to the person.

### Order and bounds

Topological order by Kahn's algorithm; among nodes ready at the same time,
the order is by layer, then node kind (`instance`, `config`, `verify`), then
node id as bytes — the same on every system and in every locale, and
independent of inventory order. At most 5 000 nodes and 20 000 edges; a
larger graph is refused. A cycle makes every node on it, and everything that
requires them, `needs-decision`, and the cycle is shown.

### Outcomes

- A failed node blocks every node that `requires` it (the chain is
  recorded: "GitHub MCP: blocked — needs Node 22; mise could not install
  node 22: …") and degrades every node that only `optional`-ly needs it.
- A need whose provider the person left out blocks its consumers, unless
  the capability is already satisfied.
- Nothing retries inside a run. Running `restore` again retries failed nodes
  and the nodes they blocked.
- Nothing is reported migrated until it and everything it requires
  verified (docs/RESTORE.md).

### Examples: MCP servers

An MCP server whose command is a tool from the repositories:

```text
need      fetch-mcp  needs cap:uv (any)            from the command /opt/homebrew/bin/uvx
instance  pacman uv                                provider of cap:uv
config    re-create fetch-mcp for Claude Code      command rewritten /opt/homebrew/bin/uvx → uvx (p:brew-bin)
verify    fetch-mcp answers (live, with consent)

edges     need → instance (requires); config → instance (requires); verify → config (requires)
```

MCP → runtime → tool → configuration, with two versions of one runtime:

```text
need      gh-mcp      needs cap:node (major 22)          the server's package declares node 22
need      lint-tool   needs cap:node (major 24)          a global npm tool the person kept
instance  mise node@24                                   the global default, first in preference
instance  mise node@22                                   the decision: side by side
instance  npm @modelcontextprotocol/server-github@2.3.1  installed under node@22
instance  npm lint-tool@5.0.0                            installed under node@24
config    re-create gh-mcp for Codex                     command wrapped: mise exec node@22 -- npx … (rewrite, shown)
verify    gh-mcp answers (live, with consent)

edges     gh-mcp need → node@22 (requires); lint-tool need → node@24 (requires);
          server-github → node@22 (requires); lint-tool → node@24 (requires);
          config → server-github (requires); verify → config (requires)
```

A tool that needs another tool in the same layer is one more `requires`
edge between two `instance` nodes; layers never forbid it.

### Layers, for the screens

| Layer | Holds | Terminal |
| --- | --- | --- |
| 1 | system packages (`omarchy-pkg-add`), Omarchy's install helpers | handoff: pacman, the helpers and `sudo` show their own output and prompts |
| 2 | runtimes (mise) | managed |
| 3 | ecosystem tools (uv, pipx, cargo-binstall, go, npm), Flathub applications | managed |
| 4 | AI tools, installed the way Omarchy's wrappers do (docs/AI-TOOLS.md) | managed |
| 5 | files: configuration and folders | managed |
| 6 | structured configuration: Git settings, MCP servers, the Bash file | managed, except a sign-in, which is a handoff |
| 7 | verification | managed; live checks only with consent |

### Graph records

| Record | Schema |
| --- | --- |
| `node` | `id:id kind:enum(need\|instance\|config\|verify) layer:uint item:bytes? sw:id? cap:id? method:enum(omarchy\|omarchy-helper\|pacman\|mise\|mise-backend\|flatpak\|uv\|pipx\|cargo-binstall\|go\|npm\|file\|structured\|check)? target:bytes? version:bytes? constraint:enum(any\|major\|minor\|exact)? value:bytes? rule:id? state:enum(planned\|ready\|unavailable\|needs-decision\|unsupported\|applied\|verified\|failed\|blocked\|degraded\|skipped\|accepted)` |
| `edge` | `from:id to:id kind:enum(requires\|optional\|orders\|conflicts)` |
| `decision` | `node:id question:id answer:id` |
| `rewrite` | `item:bytes field:id from:bytes to:bytes rule:id state:enum(auto\|review\|approved\|declined)` |

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

- **Read statically, with a lexical tracker.** Zsh files are read as text;
  nothing is sourced or evaluated. Before any line is considered, a
  conservative tracker follows, from the top of each file: single and double
  quotes, backslash line continuation, here-documents (`<<WORD` to `WORD`,
  `<<-`, quoted words), function bodies (`name() {`, `function name {`),
  compound commands (`if`…`fi`, `case`…`esac`, `for`/`while`/`until` …
  `done`, `{`…`}`, `(`…`)`), and `$(`…`)` and backquotes. A line is
  **top-level** only if it starts and ends outside all of these. From the
  first line the tracker cannot follow (end of file inside a quote, a body or
  a here-document; a construct it does not know) to the end of that file,
  every line is review-only.
- **Imported automatically: two forms, whole-line matches on top-level
  lines, nothing else.**
  - `alias NAME='VALUE'` or `alias NAME="VALUE"`: `NAME` is
    `[A-Za-z0-9_.][A-Za-z0-9_.-]*`; `VALUE` is one line of printable ASCII
    without the quote character, `$`, a backquote, `\` or `!` (no expansion,
    no substitution, no history). Not `alias -g` or `alias -s` (Zsh-only).
  - `export NAME=VALUE` (unquoted `VALUE` in `[A-Za-z0-9_./:@%+=,-]*`) or
    quoted as above, only for names on the adapter's allowlist (`EDITOR`,
    `VISUAL`, `PAGER`, `MANPAGER`, `LESS`, `BAT_THEME`, `FZF_DEFAULT_OPTS`,
    `HISTSIZE`, `HISTFILESIZE`, and the like), and only if the value passes
    the credential rules; values under `/Users/` pass through the path rules.
- **Aliases** are then checked for macOS-only commands. The registry's
  `alias` records give analogues: `pbcopy` → `wl-copy`, `pbpaste` →
  `wl-paste`, `open` → `xdg-open`, `caffeinate` → `systemd-inhibit`. An
  alias that shadows one Omarchy defines (`ls`, `cd`, `a`, `c`, `cx`, `cy`,
  `lt`, `lsa`) is shown beside Omarchy's: keep yours or keep Omarchy's.
- **Review-only**: functions, command substitutions, conditional or
  multi-line definitions, arrays, `source` and `.`, `setopt`, `bindkey`,
  `autoload`, `zstyle`, prompt settings, plugin managers, any other export.
  Each is listed with its text; an export can be included by the person one
  at a time.
- **Functions are code.** A function the person approves is carried as code,
  into a marked block of the shell file headed as reviewed code carried from
  Zsh, after a warning if it uses Zsh-only syntax. It is never described as
  portable data and never converted automatically.
- **Never carried**: `PATH` changes (the target's `PATH` is Omarchy's plus
  mise), `HOMEBREW_*`, `DYLD_*`, `LD_*`, anything credential-shaped.
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
- **History** content does not travel in v1; history settings (`HISTSIZE`,
  `HISTFILESIZE`) carry with the shell file.
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
