# AI tools

**Status: the implementation contract for M14 gate 4 (scan and capture),
M15-B (providers, restore, health) and M15-C (their rescue use); not
implemented.** Tool facts: docs/UPSTREAM.md → *AI coding tools* and
*Omarchy's agent wrappers*. The rescue use of these tools is in
docs/RESCUE.md.

This Mac is meant to be an AI development machine, so the AI tools' setup is
a first-class part of the migration: settings, instructions, MCP servers,
skills, subagents, commands and plugins. Nothing that signs in travels, and
no session or history travels in v1; each tool is signed in once on Linux.

## Providers

Each tool is a **provider**: one Bash file, `lib/agents/<id>.sh`, listed in
`AGENT_PROVIDERS`. Nothing outside that file knows a provider's paths or
formats, so adding one (Gemini CLI, Copilot CLI, Pi) is one file, its
fixtures, and registry entries.

| Function | Does |
| --- | --- |
| `detect` | where the tool's files are (on macOS for scanning, on Linux for restoring) |
| `components` | the provider's items, each with kind, class and path |
| `capture` | which fields or files a selected component contributes, and what is always left behind |
| `transform` | at export: keeps allowlisted fields, applies path rules in fields it knows, turns secret values into the tool's own variable references |
| `observe` | the six states below, from files only |
| `install` | install for the everyday user, the way Omarchy does |
| `restore` | the steps on Linux, through the tool's supported interfaces where it has them |
| `signin` | the sign-in command, run as a handoff |
| `verify` | live checks, only in an act run and with consent |
| `rescue` | install for root on the fresh system, and the rescue workspace's rules |

v1 providers: **Claude Code, Codex, OpenCode**. Gemini CLI, Copilot CLI,
Crush and Pi are recognised by the scan and shown as "recognised, not
migrated yet".

**`dev` and `restore` share the providers** (docs/DECISIONS.md → D30). The
developer setup's AI module keeps its place for a machine without a
profile, and calls the same `install`, `observe` and `verify` as `restore`:
there is one installer per tool. The baseline's `dev` module currently
counts any `claude` on `PATH` or in `~/.local/bin` as installed — Omarchy's
wrapper included — and otherwise installs Claude Code with the vendor's
installer into `~/.local/bin/claude`, the path of Omarchy's wrapper. Both
become calls to the provider, as a reviewed change to a baseline file
(MILESTONES.md → M15-B).

## What is observed

Omarchy writes a **lazy wrapper** for each agent in `~/.local/bin` (Claude
Code, Codex, OpenCode and others): a small script that runs `mise use -g
<package>` and then `exec mise x <package> -- <tool>`. Running it — even as
`claude --version` — installs the tool if it is missing, rewrites mise's
global configuration, and resets a pinned version to `latest`. mise's shims
come before `~/.local/bin` on `PATH`, so once installed, the command name
reaches the shim, not the wrapper. So a provider never runs the tool, its
wrapper, its shim or mise to find out what is there, and `command -v`
succeeding means nothing.

| State | Read from | Means |
| --- | --- | --- |
| `wrapper_present` | `~/.local/bin/<tool>`: a regular file (not a link) of at most 1 024 bytes with a line starting `mise use -g ` | Omarchy's wrapper is there; nothing is installed by it yet |
| `artifact_installed` | a version folder under `~/.local/share/mise/installs/<tool>/` (not a link, not `latest`) holding the tool's executable | the tool's files exist |
| `selected_version` | the tool's entry in `[tools]` of `~/.config/mise/config.toml` and `conf.d/*.toml` beside it (`MISE_GLOBAL_CONFIG_FILE` if set), read with the strict TOML subset reader (*Codex's configuration*, below) | what mise will run: usually `latest`, which the wrapper writes |
| `tool_runnable` | running the installed executable by its full path under `installs/`, `--version`, with a time limit — never the wrapper, the shim or `mise x` | it starts on this kernel. **Only in the act run that installed it and in `restore verify`**, never in a read command |
| `configured` | the tool's configuration files: present, and parsed by the provider's reader | the restored settings are in place |
| `authenticated` | the presence of the tool's sign-in file (never read) | a sign-in has happened; whether it still works is shown only by a live check, with consent |

Each state is shown on its own. `wrapper_present` never implies
`artifact_installed`; `artifact_installed` never implies `tool_runnable`;
a sign-in file never implies a working sign-in.

## Installing

- **The way Omarchy's wrapper does.** `install` runs, as a managed act step,
  exactly the command the wrapper would run on first use — `mise use -g
  --quiet <package>` with `MISE_MINIMUM_RELEASE_AGE=0`, the package read from
  the wrapper file itself (for Claude Code, `claude`) — so there is one copy
  of each tool, where Omarchy's launcher expects it. It then observes
  `artifact_installed` and, in this act run, `tool_runnable`.
- **No version is kept for the agents.** The wrapper writes `latest` each
  time it runs, so a version this tool pinned would not survive Omarchy's own
  launch; the review says so and records the version installed.
- **No wrapper, no guess.** If `~/.local/bin/<tool>` exists and is not
  Omarchy's wrapper (the person installed the tool another way), the
  provider leaves it and observes it as it is. It never writes to that
  path: neither the vendor's installer nor a copy replaces it.

## What travels

| Component | Class | How |
| --- | --- | --- |
| settings | `PRIVATE_CONFIG` | allowlisted keys, re-generated or merged key by key; commands inside (hooks, status line, helpers) listed for review; credential keys dropped |
| instructions (`CLAUDE.md`, `AGENTS.md`, rules) | `PRIVATE_CONFIG` | as files; source paths inside shown for review, not rewritten |
| MCP servers | `PRIVATE_CONFIG` | re-created from neutral records through the tool's interface or its configuration's own structure; secret values become variable references and the item `needs-secret`; commands pass the path rules and gain graph edges |
| skills, subagents, commands, output styles, keybindings, themes | `PUBLIC_CONFIG` or `PRIVATE_CONFIG` | as files; a skill folder is one unit |
| plugins | `PRIVATE_CONFIG` | reinstalled from their marketplace records, never copied |
| code that runs (hook files, workflows, OpenCode plugins and tools) | `PRIVATE_CONFIG`, marked "runs code" | only item by item, after the person has seen it |
| caches, logs, state databases, downloads | `MACHINE_SPECIFIC` | never |
| sign-ins, tokens, API keys | `SECRET` | never; signed in again |
| sessions, transcripts, prompt history, agent memory | — | **not in v1**: listed as found, never carried (docs/DECISIONS.md → D41) |

**Carried** therefore means: reviewed settings, instructions, skills,
subagents, commands, rules, output styles, keybindings, themes, MCP
definitions without their secret values, and the lists of plugins and
marketplaces. **Needs signing in again**: every tool's account, every MCP
server's OAuth, the GitHub CLI, and every API key that lived in an
environment variable or a `.env` file.

## Claude Code

| On macOS | Treatment |
| --- | --- |
| `~/.claude/settings.json` | read with `plutil` into neutral records; allowlisted keys carried (`permissions`, `model`, `outputStyle`, `statusLine`, `hooks`, `enabledPlugins`, `extraKnownMarketplaces`, `theme` and the like); `env` values never travel, their names are listed; `apiKeyHelper` dropped as a credential helper; `hooks` and `statusLine` are "runs code" |
| `~/.claude/CLAUDE.md`, `rules/` | files |
| `skills/`, `agents/`, `commands/`, `output-styles/`, `keybindings.json`, `themes/` | files; Omarchy's own skill link in `skills/` is left alone on Linux |
| `workflows/*.js` | runs code: item by item |
| `plugins/` | never copied: `installed_plugins.json` and `known_marketplaces.json` are read, and on Linux each marketplace is added (`claude plugin marketplace add`) and each plugin installed (`claude plugin install <plugin>@<marketplace> --scope user`); the marketplace sources are shown first, because a marketplace fetches and runs code from where it points |
| `~/.claude.json` | never copied (it holds account metadata, machine ids and per-project state). Its user-scope `mcpServers` are read with `plutil` into neutral records and re-created on Linux with `claude mcp add-json <name> <json> --scope user`; secret values in `env` and `headers` become `${NAME}` references, which Claude Code expands for user-scope servers. Per-project servers are listed, and re-created (`--scope local`, run in that folder) only for project roots the person mapped and that exist on Linux |
| `projects/`, `history.jsonl` | sessions, memory, history: not in v1 |
| `file-history/`, `shell-snapshots/`, `backups/`, `plans/`, `paste-cache/`, `debug/`, caches | never |
| sign-in | kept in the macOS Keychain, which this tool never reads; a `~/.claude/.credentials.json`, if present, is `SECRET` |

- **Sign in** with `claude` as a handoff: it shows a URL to open on any
  device and takes the code back, or the person types an API key into it.
- **Verify, live and with consent**: `claude mcp list`, which connects to
  every server and so starts every stdio server once.

## Codex

| On macOS | Treatment |
| --- | --- |
| `~/.codex/config.toml`, `~/.codex/*.config.toml` (profiles) | the strict subset reader below; allowlisted keys carried; everything else left behind and listed |
| `AGENTS.md`, `AGENTS.override.md`, `rules/*.rules`, `agents/*.toml`, `prompts/` | files (`agents/*.toml` through the same reader) |
| `hooks.json` | runs commands: item by item |
| skills in `~/.agents/skills` (current) and `~/.codex/skills` (older, still read) | files into `~/.agents/skills`; Omarchy's link is left alone |
| `~/.agents/plugins/marketplace.json` | shown for review; `plugins/cache` never |
| `sessions/`, `archived_sessions/`, `history.jsonl` | not in v1 |
| `*.sqlite`, `packages/`, logs | never |
| `auth.json`, `.credentials.json` | `SECRET`: Codex keeps its sign-in in a file on macOS too, so it is excluded by rule, not by chance |

### Codex's configuration

Codex writes `config.toml` with `toml_edit` and reads it as TOML 1.1; it
ignores keys it does not know. This tool neither copies the file opaquely
nor pattern-matches it: the core reads it with a **strict subset reader**
(`LC_ALL=C awk`, after the byte checks of docs/PROTOCOL.md → §2 with UTF-8
allowed inside strings and comments), and **refuses the whole file** when
any line falls outside the subset. A refused file carries nothing; the
review names the first line it could not read and the construct, and the
person can set those options again on Linux. `~/.codex` belongs to this
adapter, so the dotfolder picker cannot carry the file as opaque content
instead.

The subset covers everything Codex itself writes and everything its
documentation shows (docs/UPSTREAM.md → *Codex's configuration file*):

| Accepted | Form |
| --- | --- |
| lines | LF endings; blank lines; `#` comments to the end of a line, outside strings |
| keys | bare `[A-Za-z0-9_-]+`, basic-quoted `"…"`, literal-quoted `'…'`; dotted (`a."b.c".d`) with optional spaces around the dots |
| tables | `[key]` and `[[key]]` headers with the same key forms; an empty table |
| strings | basic `"…"` with TOML's escapes (`\b \t \n \f \r \e \" \\ \xHH \uXXXX \UXXXXXXXX`); literal `'…'`; multi-line basic `"""…"""` and multi-line literal `'''…'''`, with TOML's first-newline and line-ending-backslash rules |
| numbers | decimal integers (`0`, `-3`, `42`), no underscores, no leading zeros, within 64 bits; decimal floats with a fraction or exponent (`5.0`, `1e3`) |
| booleans | `true`, `false` |
| arrays | of any accepted value, nested; over several lines, with comments and a trailing comma |
| inline tables | `{ k = v, … }` on one line, of any accepted value |

**Refused, and the file with it:** date and time values; hexadecimal, octal
and binary integers; underscores in numbers; `inf` and `nan`; inline tables
over several lines or with a trailing comma (TOML 1.1 allows both); CR
bytes; invalid UTF-8; a control character outside the escapes; and anything
TOML itself forbids — a key defined twice, a table defined twice, a key
that is both a value and a table, `[[x]]` after `x` was a static array.

What is carried from an accepted file, as neutral records:

| Carried | Rules |
| --- | --- |
| `model`, `model_provider`, `model_reasoning_effort`, `service_tier` | as values |
| `approval_policy`, `sandbox_mode` | only values Codex 0.157.1 accepts (`on-request`, `never`; `read-only`, `workspace-write`, `danger-full-access`); anything else dropped and listed |
| `notify`, `[hooks]` | runs code: item by item; path rules in the command |
| `[model_providers.<id>]` | `name`, `base_url`, `env_key` (a variable name), `wire_api`, `query_params` without credential-named parameters; `http_headers` values dropped, their names listed; `env_http_headers` carried (they name variables) |
| `[mcp_servers.<name>]` | `command`, `args`, `cwd`, `url`, `enabled`, `required`, `startup_timeout_sec`, `tool_timeout_sec`, `enabled_tools`, `disabled_tools`, `bearer_token_env_var`, `env_vars`, `env_http_headers`, `[…tools.<tool>]` approval settings; `env` values **never**: each name joins `env_vars`, so Codex forwards it from the environment, and the item is `needs-secret`; `http_headers` values dropped and listed; `bearer_token` (which Codex refuses anyway) dropped; path rules in `command`, `args` and `cwd`; the argument rules of docs/MIGRATION.md → *Secret channels* |
| `[projects."<path>"]` | `trust_level`, only for project roots the person mapped, rewritten to the Linux path |
| `[plugins."<plugin>@<marketplace>"]` | `enabled` |
| `[features]`, `[tui]`, `[history]`, `[shell_environment_policy]` | keys whose values are booleans, numbers or short strings; `shell_environment_policy.set` values dropped |
| `[profiles.<name>]`, a top-level `profile` | not carried: Codex 0.134 and later reads profiles from `~/.codex/<name>.config.toml` and refuses a top-level `profile` |

**Writing on Linux.** The provider writes Codex's own shape: top-level
keys first, then one `[mcp_servers.<name>]` table per server (the name
quoted when it holds `.`, `:`, `@` or `/`), single-line arrays, basic
strings with escapes. Where Linux has no `config.toml`, that is the file.
Where one exists, the same reader reads it:

- **it is refused**: a conflict with two choices, Keep or Replace (the old
  file to the backup);
- **it is read**: new top-level keys are inserted before its first table,
  new tables appended after its last line, and nothing existing is edited;
  a key or server present on both sides with different values is a
  conflict (Keep, or Replace the whole file). The result is placed as a
  whole file (docs/RESTORE.md → *Placing a file*), so undo is the same as
  for any file.

Codex's own `codex mcp add` later rewrites a server's table from what Codex
models, which is exactly what this writes, so nothing is lost when it does.
MCP servers travel inside `config.toml`, not through `codex mcp add`: for a
URL server that uses OAuth, `codex mcp add --url` starts a browser sign-in
by itself, which a console cannot complete.

- **Sign in**: `codex login --device-auth` (the person must first allow
  device codes in ChatGPT's security settings), or `codex login
  --with-api-key` with the key typed into Codex, as a handoff.
- **Verify, live and with consent**: `codex mcp list` starts no stdio server
  but contacts HTTP servers.

## OpenCode

| On macOS | Treatment |
| --- | --- |
| `~/.config/opencode/opencode.json` | read with `plutil`; Omarchy seeds this folder on Linux, so it is always a conflict. JSON is merged key by key on Linux with `jq` (constant filters, values as arguments): the person's `mcp`, `agent`, `command`, `instructions` and `permission` entries are added where Omarchy's file lacks them; `provider` entries carry without credential fields; `plugin` entries run code and are item by item. Secret values become `{env:NAME}` substitutions |
| `opencode.jsonc` with comments | `plutil` cannot read it: not carried, and listed |
| `agents/`, `commands/`, `skills/`, `themes/`, `AGENTS.md` | files |
| `plugins/`, `tools/`, `package.json` | runs code (OpenCode installs `package.json` with Bun at start): item by item |
| `~/.local/share/opencode/auth.json`, `mcp-auth.json` | `SECRET` |
| `~/.local/share/opencode/opencode.db`, `~/.local/state/opencode/prompt-history.jsonl` | sessions and history: not in v1 |
| `log/`, `snapshot/`, `tool-output/`, `~/.cache/opencode` | never |

- **Sign in**: `opencode auth login` as a handoff.
- **Verify, live and with consent**: `opencode mcp list` starts every
  enabled local server.

## Skills shared between tools

`~/.agents/skills` is read by Codex and OpenCode, `~/.claude/skills` by
Claude Code and OpenCode. A skill is carried to each place it was on macOS,
stored once in the bundle by content; no new links between tools' folders
are invented. Omarchy links its own skill into these folders; that link is
never replaced or removed.

## Omarchy's coding agent

Omarchy 4 has a default coding agent: `omarchy-agent` starts it,
`Super+Shift+Ctrl+A` opens a picker, the aliases `a`, `c`, `cx`, `cy` start
agents in the shell, and the choice is stored in
`~/.config/omarchy/defaults/agent`.

- **The person chooses it, through Omarchy.** `omarchy-default-agent
  <name>` installs a missing agent in a new graphical terminal and always
  ends by launching the agent, so it cannot run as a step of a restore; and
  the defaults file is Omarchy's. The restore therefore sets no default: its
  summary names the restored tools and says how to choose one
  (`Super+Shift+Ctrl+A`, or `omarchy-default-agent <name>`, which starts it).
  Reading the current default (the file, or the command without arguments)
  is a static observation.
- **Its launch modes are shown, not changed.** The review states that
  Omarchy starts its default agent in permissive modes (`claude
  --permission-mode auto`, `codex --approve-for-me`, `opencode --auto`, and
  others). This tool does not change Omarchy's launcher; the person's
  restored permission rules still apply wherever the tool honours them in
  that mode. Nothing in an agent's launch flags authorises anything in this
  tool.

## Health, as shown

```text
Claude Code
  ✓ wrapper       Omarchy's (mise package claude)
  ✓ installed     2.1.283 (mise)
  · selected      latest
  ✓ runs          checked in this restore
  ✓ configured    settings read · 23 skills · 7 agents
  · signed in     sign-in file present · live check not run (c)
  ! xcode-mcp is macOS-only: not restored
Codex
  ✓ wrapper       Omarchy's (mise package codex)
  ✓ installed     0.157.1 (mise)
  ✓ configured    config read · 6 skills · 4 MCP servers
  ! needs GITHUB_TOKEN in your environment for github
```

"Ready" is said only after a check; a copied folder is never reported as
working, and a static screen never says a tool runs.

## Things that execute, and never do so during a scan or a status

The scan reads these as text or not at all: Claude Code's `mcp list`,
`mcp get`, hooks, `headersHelper` and `apiKeyHelper`; OpenCode's `mcp list`,
plugins and its `package.json`; Codex's `notify` and hooks; Crush's
`crushrc` (a full shell) and `$(…)` in `crush.json`, which run when Crush
loads them; and, on Linux, Omarchy's agent wrappers, their mise shims, and
mise itself. Crush's files are recognised by name only.
