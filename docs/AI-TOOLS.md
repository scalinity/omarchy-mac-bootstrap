# AI tools

**Status: designed for M14 (scan and capture) and M15 (restore, health,
rescue); not implemented.** Tool facts verified on 2026-09-26
(docs/UPSTREAM.md → *AI coding tools*). The rescue use of these tools is in
docs/RESCUE.md.

This Mac is meant to be an AI development machine, so the AI tools' setup is
a first-class part of the migration: settings, instructions, MCP servers,
skills, subagents, commands, plugins and, if wanted, history. Nothing that
signs in travels; each tool is signed in once on Linux.

## Providers

Each tool is a **provider**: one Bash file, `lib/agents/<id>.sh`, listed in
`AGENT_PROVIDERS`. Nothing outside that file knows a provider's paths or
formats, so adding one (Gemini CLI, Copilot CLI, Pi) is one file, its
fixtures, and registry entries.

| Function | Does |
| --- | --- |
| `detect` | is the tool on this system; where its files are (on macOS for scanning, on Linux for restoring) |
| `components` | the provider's items, each with kind, class and path |
| `capture` | which files a selected component contributes, and what is always left behind |
| `transform` | provider-aware changes at export: path rules in fields it knows, secret values replaced by the tool's own variable references |
| `restore` | the steps on Linux, through the tool's supported interfaces where it has them |
| `install` | install for the everyday user, through Omarchy's mechanism |
| `signin` | the sign-in command, run as a handoff |
| `health` | static checks; live checks only with consent |
| `rescue` | install for root on the fresh system, and the rescue workspace's guardrails |

v1 providers: **Claude Code, Codex, OpenCode**. Gemini CLI, Copilot CLI,
Crush and Pi are recognised by the scan and shown as "recognised, not
migrated yet".

## What travels

| Component | Class | How |
| --- | --- | --- |
| settings | `PRIVATE_CONFIG` | as a file, conflict-aware; commands inside it (hooks, status line, helpers) are listed for review; secret-shaped values removed |
| instructions (`CLAUDE.md`, `AGENTS.md`, rules) | `PRIVATE_CONFIG` | as files; source paths inside are shown for review, not rewritten |
| MCP servers | `PRIVATE_CONFIG` | re-created through the tool's interface or its configuration's own structure; secret values become variable references; commands pass the path rules and gain dependencies |
| skills, subagents, commands, output styles, keybindings, themes | `PUBLIC_CONFIG` or `PRIVATE_CONFIG` | as files; a skill folder is one unit |
| plugins | `PRIVATE_CONFIG` | reinstalled from their marketplace records, never copied |
| code that runs (hooks files, workflows, OpenCode plugins and tools) | `PRIVATE_CONFIG`, marked "runs code" | only item by item, after the person has seen it |
| sessions, transcripts, prompt history, agent memory | `SENSITIVE` | only when opted in; carried as the tool's own files, whose format is internal to the tool |
| caches, logs, state databases, downloads | `MACHINE_SPECIFIC` | never |
| sign-ins, tokens, API keys | `SECRET` | never; signed in again |

**Safe to copy** therefore means: settings once reviewed, instructions,
skills, subagents, commands, rules, output styles, keybindings, themes, MCP
definitions without their secret values, and the lists of plugins and
marketplaces. **Needs signing in again**: every tool's account, every MCP
server's OAuth, the GitHub CLI, and every API key that lived in an
environment variable or `.env` file.

## Claude Code

| On macOS | Treatment |
| --- | --- |
| `~/.claude/settings.json` | file; `hooks`, `statusLine`, `apiKeyHelper` and `env` listed for review; `enabledPlugins` and `extraKnownMarketplaces` feed the plugin list |
| `~/.claude/CLAUDE.md`, `rules/` | files |
| `skills/`, `agents/`, `commands/`, `output-styles/`, `keybindings.json`, `themes/` | files; Omarchy's own skill link in `skills/` is left alone on Linux |
| `workflows/*.js` | runs code: item by item |
| `plugins/` | never copied: `installed_plugins.json` and `known_marketplaces.json` are read, and on Linux each marketplace is added (`claude plugin marketplace add`) and each plugin installed (`claude plugin install <plugin>@<marketplace> --scope user`); the marketplace sources are shown first, because a marketplace fetches and runs code from where it points |
| `~/.claude.json` | never copied (it holds account metadata, machine ids and per-project state). Its user-scope `mcpServers` are read with `plutil` into neutral records and re-created on Linux with `claude mcp add-json <name> <json> --scope user`; secret values in `env` and `headers` become `${NAME}` references, which Claude Code expands for user-scope servers. Per-project servers are listed, and re-created (`--scope local`, run in that folder) only for project roots the person mapped and that exist on Linux |
| `projects/<encoded path>/` | sessions and memory: `SENSITIVE`, opt-in; the folder name is re-encoded for the Linux path (Claude Code replaces every non-alphanumeric character with `-`); contents are not rewritten, so a session may not resume |
| `history.jsonl` | `SENSITIVE`, opt-in |
| `file-history/`, `shell-snapshots/`, `backups/`, `plans/`, `paste-cache/`, `debug/`, caches | never |
| sign-in | kept in the macOS Keychain, which this tool never reads; a `~/.claude/.credentials.json`, if present, is `SECRET` |

- **Install on Omarchy** through Omarchy's own lazy stub, `~/.local/bin/claude`,
  which installs Claude Code with mise on first use: the restore runs the
  stub's version check once and then confirms with `mise ls --json`. The
  vendor's installer is not used for the everyday user, because it writes to
  the same path and would replace Omarchy's stub. (The baseline's developer
  module does use it; docs/DECISIONS.md records that as an open question.)
- **Sign in** with `claude` as a handoff: it shows a URL to open on any
  device and takes the code back, or the person types an API key into it.
- **Health**: static, running nothing — installed per `mise ls --json`,
  `settings.json` parses, skill and agent counts, each re-created MCP
  server's command resolves on `PATH`, and each `${NAME}` it needs is named.
  The version is run only in the restore's own verification, right after
  installing (running Omarchy's stub from a read command would install the
  tool). Live, with consent — `claude mcp list`, which connects to every
  server and so starts every stdio server once.

## Codex

| On macOS | Treatment |
| --- | --- |
| `~/.codex/config.toml` | read by a strict line reader for the subset Codex uses (tables, strings, string arrays, booleans, numbers, inline tables of strings). At export: path rules in `command`, `args`, `cwd` and `notify`; a secret literal in `[mcp_servers.<name>.env]` is removed and its name added to that server's `env_vars`, so Codex forwards it from the environment; `[projects."<path>"]` entries follow the project mapping or are dropped. A file with anything outside the subset is not transformed: the person carries it unchanged (flagged) or leaves it |
| `AGENTS.md`, `AGENTS.override.md`, `rules/*.rules`, `agents/*.toml`, `prompts/` | files |
| `hooks.json` | runs commands: item by item |
| skills in `~/.agents/skills` (current) and `~/.codex/skills` (older, still read) | files into `~/.agents/skills`; Omarchy's link is left alone |
| `[plugins."<plugin>@<marketplace>"]`, `~/.agents/plugins/marketplace.json` | carried with `config.toml`; the marketplace file is shown for review; `plugins/cache` never |
| `sessions/`, `archived_sessions/`, `history.jsonl` | `SENSITIVE`, opt-in |
| `*.sqlite`, `packages/`, logs | never |
| `auth.json`, `.credentials.json` | `SECRET`: Codex keeps its sign-in in a file on macOS too, so it is excluded by rule, not by chance |

- **MCP servers travel inside `config.toml`**, not through `codex mcp add`:
  for a URL server that uses OAuth, `codex mcp add --url` starts a browser
  sign-in by itself, which a console cannot complete.
- **Install** through Omarchy's stub (mise). **Sign in**: `codex login
  --device-auth` (the person must first allow device codes in ChatGPT's
  security settings), or `codex login --with-api-key` with the key typed into
  Codex.
- **Health**: static checks as above; `codex mcp list` starts no stdio server
  but contacts HTTP servers, so it runs only as a live check.

## OpenCode

| On macOS | Treatment |
| --- | --- |
| `~/.config/opencode/opencode.json` | Omarchy seeds this folder, so it is always a conflict. JSON is merged on Linux key by key with `jq` (constant filters, values as arguments): the person's `mcp`, `agent`, `command`, `instructions` and `permission` entries are added where Omarchy's file lacks them; `provider` entries carry without credentials; `plugin` entries run code and are opt-in. Secret values become `{env:NAME}` substitutions |
| `opencode.jsonc` with comments | `plutil` cannot read it, so it is carried whole under a conflict decision (keep or replace), never merged |
| `agents/`, `commands/`, `skills/`, `themes/`, `AGENTS.md` | files |
| `plugins/`, `tools/`, `package.json` | runs code (OpenCode installs `package.json` with Bun at start): item by item |
| `~/.local/share/opencode/auth.json`, `mcp-auth.json` | `SECRET` |
| `~/.local/share/opencode/opencode.db` (sessions), `~/.local/state/opencode/prompt-history.jsonl` | `SENSITIVE`, opt-in, whole files |
| `log/`, `snapshot/`, `tool-output/`, `~/.cache/opencode` | never |

- **Install** through Omarchy's stub (mise). **Sign in**: `opencode auth
  login` as a handoff.
- **Health**: `opencode mcp list` starts every enabled local server, so it is
  a live check only.

## Skills shared between tools

`~/.agents/skills` is read by Codex and OpenCode, `~/.claude/skills` by
Claude Code and OpenCode. A skill is carried to each place it was on macOS,
stored once in the bundle by content; no new links between tools' folders
are invented. Omarchy links its own skill into these folders; that link is
never replaced or removed.

## Omarchy's coding agent

Omarchy 4 has a default coding agent: `omarchy-agent` starts it,
`Super+Shift+Ctrl+A` opens a picker, the aliases `a`, `c`, `cx`, `cy` start
agents in the shell, and `omarchy-default-agent <name>` chooses (and
installs) the default, stored in `~/.config/omarchy/defaults/agent`.

- The restore offers to make one of the restored tools Omarchy's default
  (yes/no) and runs `omarchy-default-agent <name>`; it never writes the file.
- The review states, as information: Omarchy starts its default agent in
  permissive modes (`claude --permission-mode auto`, `codex --approve-for-me`,
  `opencode --auto`, and others). This tool does not change Omarchy's
  launcher; the person's restored permission rules still apply wherever the
  tool honours them in that mode.
- The restored tools use Omarchy's stubs and mise, the same path Omarchy's
  launcher uses, so there is one copy of each tool, not two.

## Health, as shown

```text
Claude Code
  ✓ installed 2.1.283 (mise)
  ✓ settings parse
  ✓ 23 skills, 7 agents
  ✓ 8 of 9 MCP servers ready
  ! xcode-mcp is macOS-only: not restored
Codex
  ✓ installed 0.157.1 (mise)
  ✓ config parses
  ✓ 6 skills
  ✓ 4 MCP servers defined · live check not run (c)
  ! needs GITHUB_TOKEN in your environment for github
```

"Ready" is said only after a check; a copied folder is never reported as
working.

## Things that execute, and never do so during a scan

The scan reads these as text or not at all: Claude Code's `mcp list`,
`mcp get`, hooks, `headersHelper` and `apiKeyHelper`; OpenCode's `mcp list`,
plugins and its `package.json`; Codex's `notify` and hooks; Crush's
`crushrc` (a full shell) and `$(…)` in `crush.json`, which run when Crush
loads them. Crush's files are recognised by name only.
