# AI tools

**Status:** not built. Gate 4 builds the macOS side (scan, capture and the
TOML subset reader), Gate 5 the export, and M15-B the Linux side. Tool
facts: docs/UPSTREAM.md → *AI coding tools* and *Omarchy's agent wrappers*.

This Mac is meant to be an AI development machine, so the AI tools' setup is
a first-class part of the migration: settings, instructions, MCP servers,
skills, subagents, commands and plugins. Nothing that signs in travels, and
no session or history travels in v1; each tool is signed in once on Linux.

## Providers

`lib/agents.sh` holds one table, a row per tool — **Claude Code, Codex and
OpenCode** — naming its command, configuration files, sign-in file and
sign-in command, with the functions that read it. `dev` and `restore` share
it (D30 in docs/DECISIONS.md): each tool has one installer and one way of
being observed, and `dev`'s AI module keeps its place for a machine without
a bundle (MILESTONES.md → *M15-B — Packages and AI providers*). Gemini CLI,
Copilot CLI, Crush and Pi are recognised by the scan and shown as
"recognised, not migrated yet".

## What is observed

Omarchy writes a **lazy wrapper** for each agent in `~/.local/bin`: a small
script that runs `mise use -g <package>`, then `exec mise x <package> --
<tool>`. Running it — even as `claude --version` — installs the tool if it
is missing, rewrites mise's global configuration and resets a pinned version
to `latest`; once the tool is installed, mise's shims come first on `PATH`.
So `command -v` succeeding means nothing. The wrapper is recognised by
reading it, never by running it: a regular file, not a link, of at most
1 024 bytes, with a line starting `mise use -g `.

| Fact | Read from | Means |
| --- | --- | --- |
| `installed` | a version folder under `~/.local/share/mise/installs/<tool>/` (not a link, not `latest`) holding the tool's executable, or a foreign binary: a `~/.local/bin/<tool>` that is not Omarchy's wrapper | the tool's files exist |
| `ran-at-restore` | `mise x <package> -- <tool> --version` answered within its time limit right after this tool installed it; the run that installed it keeps the answer | it started on this kernel once |
| `configured` | the tool's configuration files, present and read by the table's reader | the restored settings are in place |
| `signed-in-file` | the tool's sign-in file is present; it is never read | a sign-in happened; only a live check shows whether it still works |

Each fact is shown on its own: Omarchy's wrapper alone is never `installed`,
`installed` never means the tool runs, and a sign-in file never means a
working sign-in. `dev` stops counting Omarchy's lazy wrappers as installed
tools: it asks the table, never `PATH`.

**Installing** runs, as a managed act step, what the wrapper would run on
first use — `mise use -g --quiet <package>` with
`MISE_MINIMUM_RELEASE_AGE=0`, the package read from the wrapper (for Claude
Code, `claude`) — so there is one copy of each tool, where Omarchy's
launcher expects it. Right after it, and only then, `mise x <package> --
<tool> --version` runs with a time limit; no other check runs a wrapper,
shim, mise or agent. No version is kept: the wrapper writes `latest` each
time it runs, and the review says so. A foreign `~/.local/bin/<tool>` is
left alone and never written over.

## What travels

| Component | Class | How |
| --- | --- | --- |
| settings | `config` | allowlisted keys, regenerated or merged key by key; commands inside (hooks, status line, helpers) listed for review; credential keys dropped |
| instructions (`CLAUDE.md`, `AGENTS.md`, rules) | `config` | as files; source paths inside shown for review, not rewritten |
| MCP servers | `config` | re-created from neutral records through the tool's interface or its configuration's own structure; secret values become variable names and the item is `needs-secret`; commands pass the path rules |
| skills, subagents, commands, output styles, keybindings, themes | `config` | as files; a skill folder is one unit |
| plugins | `config` | reinstalled from their marketplace records, never copied |
| code that runs (hook files, workflows, OpenCode plugins and tools) | `config`, marked "runs code" | only item by item, after the person has seen it |
| caches, logs, state databases, downloads | `mac-only` | never |
| sign-ins, tokens, API keys | `secret` | never; signed in again |
| sessions, transcripts, prompt history, agent memory | — | **not in v1**: listed as found, never carried (D41 in docs/DECISIONS.md) |

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
| `~/.claude.json` | never copied (it holds account metadata, machine ids and per-project state). Its user-scope `mcpServers` are read with `plutil` into neutral records and re-created on Linux with `claude mcp add-json <name> <json> --scope user`, the definition as one argument; secret values in `env` and `headers` become `${NAME}` references, which Claude Code expands for user-scope servers. Per-project servers are listed, and re-created (`--scope local`, run in that folder) only for project roots under the home that exist on Linux |
| `projects/`, `history.jsonl` | sessions, memory, history: not in v1 |
| `file-history/`, `shell-snapshots/`, `backups/`, `plans/`, `paste-cache/`, `debug/`, caches | never |
| sign-in | kept in the macOS Keychain, which this tool never reads; a `~/.claude/.credentials.json`, if present, is `secret` |

- **Sign in** with `claude` as a handoff: it shows a URL to open on any
  device and takes the code back, or the person types an API key into it.
- **Live check, on request**: `claude mcp list`, shown as it prints it and
  never parsed; it connects to every server, and so starts every stdio
  server once.

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
| `auth.json`, `.credentials.json` | `secret`: Codex keeps its sign-in in a file on macOS too, so it is excluded by rule, not by chance |

### Codex's configuration

Codex writes `config.toml` with `toml_edit` and reads it as TOML 1.1; it
ignores keys it does not know. This tool neither copies the file opaquely
nor pattern-matches it: on macOS, `lib/toml.sh` reads it with a **strict
subset reader** (`LC_ALL=C awk`, after the record format's byte checks, with
UTF-8 allowed inside strings and comments) and **refuses the whole file**
when any line falls outside the subset. A refused file carries nothing; the
review names the first line it could not read and the construct, and the
person can set those options again on Linux. `~/.codex` belongs to this
adapter, so the dotfolder picker cannot carry the file as opaque content
instead. The same reader reads mise's configuration; it runs on macOS only,
and its tests use files that Codex and mise write.

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
bytes; invalid UTF-8; a control character outside the escapes; a file over
1 MiB, a line over 16 KiB, or arrays and inline tables nested more than 16
deep; and anything TOML itself forbids — a key defined twice, a table
defined twice (including a `[a.b]` header after dotted keys such as `a.b.c
= 1` already defined `a.b`; a sub-table header such as `[a.b.x]` is
allowed), a key that is both a value and a table, `[[x]]` after `x` was a
static array.

What is carried from an accepted file, as neutral records:

| Carried | Rules |
| --- | --- |
| `model`, `model_provider`, `model_reasoning_effort`, `service_tier` | as values |
| `approval_policy`, `sandbox_mode` | only values Codex 0.157.1 accepts (`on-request`, `never`; `read-only`, `workspace-write`, `danger-full-access`); anything else dropped and listed |
| `notify`, `[hooks]` | runs code: item by item; path rules in the command |
| `[model_providers.<id>]` | `name`, `base_url`, `env_key` (a variable name), `wire_api`, `query_params` without credential-named parameters; `http_headers` values dropped, their names listed; `env_http_headers` carried (they name variables) |
| `[mcp_servers.<name>]` | `command`, `args`, `cwd`, `url`, `enabled`, `required`, `startup_timeout_sec`, `tool_timeout_sec`, `enabled_tools`, `disabled_tools`, `bearer_token_env_var`, `env_vars`, `env_http_headers`, `[…tools.<tool>]` approval settings; `env` values **never**: each name joins `env_vars`, so Codex forwards it from the environment, and the item is `needs-secret`; `http_headers` values dropped and listed; `bearer_token` (which Codex refuses anyway) dropped; path rules in `command`, `args` and `cwd`; the argument rules for secrets (docs/MIGRATION.md) |
| `[projects."<path>"]` | `trust_level`, only for project roots under the home, the path rewritten through `p:home` |
| `[plugins."<plugin>@<marketplace>"]` | `enabled` |
| `[features]`, `[tui]`, `[history]`, `[shell_environment_policy]` | keys whose values are booleans, numbers or short strings; `shell_environment_policy.set` values dropped |
| `[profiles.<name>]`, a top-level `profile` | not carried: Codex 0.134 and later reads profiles from `~/.codex/<name>.config.toml` and refuses a top-level `profile` |

**On Linux** the file is never merged. Export writes the carried values as
a new `config.toml` in Codex's own shape (top-level keys, then one
`[mcp_servers.<name>]` table per server, single-line arrays, basic
strings); restore places it where Linux has none, and where one exists it
is a conflict, kept or replaced whole (docs/RESTORE.md → *Conflicts*). MCP
servers travel inside `config.toml`, not through `codex mcp add`, which for
a URL server using OAuth starts a browser sign-in a console cannot complete.

- **Sign in**: `codex login --device-auth` (the person must first allow
  device codes in ChatGPT's security settings), or `codex login
  --with-api-key` with the key typed into Codex, as a handoff.
- **Live check, on request**: `codex mcp list`, shown as it prints it; it
  starts no stdio server but contacts HTTP servers.

## OpenCode

| On macOS | Treatment |
| --- | --- |
| `~/.config/opencode/opencode.json` | read with `plutil`. Omarchy seeds this folder on Linux, so the person's entries are merged into Omarchy's file with `jq` (constant filters, values as arguments): their `mcp`, `agent`, `command`, `instructions` and `permission` entries are added where Omarchy's file lacks them; `provider` entries carry without credential fields; `plugin` entries run code and are item by item. Secret values become `{env:NAME}` substitutions |
| `opencode.jsonc` with comments | `plutil` cannot read it: not carried, and listed |
| `agents/`, `commands/`, `skills/`, `themes/`, `AGENTS.md` | files |
| `plugins/`, `tools/`, `package.json` | runs code (OpenCode installs `package.json` with Bun at start): item by item |
| `~/.local/share/opencode/auth.json`, `mcp-auth.json` | `secret` |
| `~/.local/share/opencode/opencode.db`, `~/.local/state/opencode/prompt-history.jsonl` | sessions and history: not in v1 |
| `log/`, `snapshot/`, `tool-output/`, `~/.cache/opencode` | never |

- **Sign in**: `opencode auth login` as a handoff.
- **Live check, on request**: `opencode mcp list`, shown as it prints it;
  it starts every enabled local server.

## Skills shared between tools

`~/.agents/skills` is read by Codex and OpenCode, `~/.claude/skills` by
Claude Code and OpenCode. A skill is carried to each place it was on macOS,
stored once in the bundle by content; no new links between tools' folders
are invented. Omarchy links its own skill into these folders; that link is
never replaced or removed.

## Omarchy's coding agent

Omarchy 4 has a default coding agent: `omarchy-agent` starts it,
`Super+Shift+Ctrl+A` opens a picker, and the choice is Omarchy's file,
`~/.config/omarchy/defaults/agent`. This tool never runs
`omarchy-default-agent`, which installs a missing agent in a new graphical
terminal and always ends by launching it, and never writes that file:
restore's summary names the restored tools and says how to pick one.
Omarchy starts its default agent in permissive modes (`claude
--permission-mode auto`, `codex --approve-for-me`, `opencode --auto`); the
review says so, and the restored permission rules still apply wherever the
tool honours them in that mode.

## Health, as shown

The Health screen (22, docs/UX.md → *Every screen*) is a read-only check
list. Restore adds a row for itself and one per AI tool, each fact on its
own:

```text
✓ Restore        complete · 412 placed · 9 kept · 2 wait on you
✓ Claude Code    installed 2.1.283 (mise) · ran at restore · configured · sign-in file
! Codex          installed 0.157.1 (mise) · configured · needs GITHUB_TOKEN for github
· OpenCode       not installed
```

A live check — the tool's own `mcp list`, shown as it prints it — runs only
after the person answers yes, one tool at a time, with a time limit.
"Ready" is said only after a check; a copied folder is never reported as
working, and the static list never says a tool runs.

## Things that execute, and never do so during a scan or a status

The scan reads these as text or not at all: Claude Code's `mcp list`,
`mcp get`, hooks, `headersHelper` and `apiKeyHelper`; OpenCode's `mcp list`,
plugins and its `package.json`; Codex's `notify` and hooks; Crush's
`crushrc` (a full shell) and `$(…)` in `crush.json`, which run when Crush
loads them; and, on Linux, Omarchy's agent wrappers, their mise shims, and
mise itself. Crush's files are recognised by name only.
