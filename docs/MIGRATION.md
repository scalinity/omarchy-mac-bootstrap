# Migration

**Status: built in Gate 4 (scanner, profile: `lib/migrate_scan.sh`,
`lib/toml.sh`, `lib/migrate_profile.sh`) and Gate 5 (bundle:
`lib/migrate_bundle.sh`) and Linux restore (`lib/migrate_restore.sh`).** Resolution: docs/RESOLVER.md; restoring: docs/RESTORE.md; the AI
tools: docs/AI-TOOLS.md; the screens: docs/UX.md; the record format:
docs/PROTOCOL.md.

The source is **this Mac's own macOS**: the M1 after a Time Machine restore
from the everyday Mac, brought up to date, before Linux is installed. The
person selects from its scan, the selection is resolved and saved as the
Migration Profile, and export writes a bundle that `restore` brings to
Omarchy on the same Mac.

## The scanner

`scan` (read) prints what it found; `profile` (act) scans and saves the
inventory, then leads through selection and resolution in the frontend.
Each source has an **adapter**, the only code that knows its format, and
every read goes through the seam: `sys_cmd`, `sys_path`, or `sys_walk DIR`,
a `find -P` listing that never follows a link.

- **Read as text, never run.** Only fixed read-only utilities run (`find`,
  `plutil`, which reads JSON too, `wc`, `od`, `awk`), never a tool being
  inventoried (`brew`, `npm`, `cargo`, `uv`, `go`, `mise`, an AI tool),
  whose listing commands update, write, fetch or run configuration
  (docs/UPSTREAM.md). No MCP server starts, no hook runs, no shell file is
  sourced, no plugin loads, and nothing reaches the network:
  `scan` writes nothing, and `profile` writes only `profile.omb`.
- **One strict TOML reader.** Codex's and mise's configuration go through
  the TOML subset reader (`lib/toml.sh`), which accepts what they write; a
  file with anything outside the subset is refused whole, carries nothing,
  and is listed with the first line it could not read.
- **Out of protected places**: Desktop, Documents, Downloads, iCloud Drive,
  Mail, Messages, Safari, other apps' containers (macOS 27 denies a
  container read without a prompt, so an empty result never means
  "nothing"). A folder the person chooses is read; a denial is `denied`.
- **Uncertainty stays visible.** Running out of an entry budget is
  `partial`, never a short but complete list. Every item's evidence is
  `observed`, `inferred` (by a stated rule) or `unknown`; a shape outside
  the version an adapter reads (Homebrew receipts 4.3.11 to 7.x) or a
  contradiction (a receipt naming a missing tap, a cask whose app is gone)
  is `unknown`, never guessed.

### What the scan reads

| Source | Reads | Becomes |
| --- | --- | --- |
| Homebrew | under `/opt/homebrew` and `/usr/local` (data from an Intel Mac can bring both): `Cellar/<name>/<version>/` and its receipt (`installed_on_request`, `runtime_dependencies`, `source.tap`), `Caskroom` and its receipts, the `opt/<name>` links, `Library/Taps/*/*` and each tap's remote; `~/Library/LaunchAgents/homebrew.mxcl.*.plist` | formulae, casks, taps; a service plist is a flag on its formula: configured, and whether it runs `unknown`, since no `launchctl` runs |
| applications | `Info.plist` of each `/Applications/*.app` and `~/Applications/*.app`: `CFBundleIdentifier`, version, `_MASReceipt` | applications; a cask and the app it installed are one item |
| language tools and runtimes | global `package.json` files under every Node prefix (Homebrew, nvm, fnm, Volta, mise), pnpm's and bun's; `.crates.toml`, `.crates2.json` and cargo-binstall's record; `uv-receipt.toml`; `pipx_metadata.json`; binaries in `GOBIN`, `GOPATH/bin` and `~/go/bin`, with the module and version Go embeds (found by a byte search); mise's `[tools]`; `~/.tool-versions` | global packages, tools and runtimes, one item per version |
| editors | VS Code, VSCodium and Cursor `extensions/extensions.json`, `User/settings.json`, `keybindings.json`, snippets; `~/.config/nvim` | extensions, editor settings |
| shell | the login shell (`dscl` read of `UserShell`); `~/.zshrc`, `~/.zprofile`, `~/.zshenv`, `~/.bashrc`, `~/.bash_profile`, as text (docs/RESOLVER.md → *From Zsh to Bash*) | aliases, exports, review-only lines; the Zsh rc files as reference copies |
| terminal settings | Ghostty, Kitty, WezTerm, Alacritty, iTerm2; tmux; Starship; fzf, zoxide, atuin, eza, bat and direnv configuration | terminal and prompt settings |
| Git, `gh` and SSH | Git's configuration and global ignore file; `gh`'s `config.yml`, and whether `hosts.yml` exists (never read); `~/.ssh/config`, `known_hosts`, public keys, each private key's envelope header | Git settings, SSH configuration and keys |
| AI tools | Claude Code, Codex and OpenCode in full; others recognised and listed (docs/AI-TOOLS.md) | settings, instructions, skills, MCP servers, plugins |
| chosen folders | names, sizes and types under `~` and `~/.config`; inside, only what the person opens (*Chosen folders*) | folders and files to carry |
| projects | only folders the person names: a Git checkout's remote and branch | projects to clone again on Linux; never copied |

The adapters run in this order: Homebrew, applications, language tools
and runtimes, editors, shell, terminal settings, Git, the AI tools, chosen
folders. An item's id names its adapter and name or its home-relative path
and never a version (`brew:`, `cask:`, `tap:`, `app:<bundle id>`, `npm:`,
`cargo:`, `uv:`, `go:<module>`, `vscode:ext:`, `claude:mcp:<name>`,
`path:<path>`, `project:<path>`); a runtime's id carries its release line
(`nvm:node@20.11`), so a patch update keeps it. Its `kind` is the migration
map's source for software (docs/RESOLVER.md → *The migration map*), `ai`
for the three AI tools, `git`, `mcp` or `plugin` for those settings, `tap`
and `extension` for Homebrew taps and editor extensions. What runs code —
hooks, a status line, Codex's `notify`, workflows — is listed with that
reason and never carried.

A receipt's `installed_on_request: true` is `requested=yes`, `false` is
`no`, and a missing field or receipt is `requested=unknown`, for the person
to decide. The migration map (docs/RESOLVER.md) says which sources are one
program: Homebrew's `node` 24 and nvm's node 20 are two versions of
Node.js, and Linux gets one. Two unknown items with one name are shown side
by side, never merged by a guess.

## Sensitivity: what may travel

| Class | Means | Travels |
| --- | --- | --- |
| `config` | settings and files a supported adapter understands | when selected |
| `sensitive` | private but not a credential (`known_hosts`) | only when opted in, item by item |
| `opaque` | content no supported adapter understands (a chosen folder, an unknown file) | only after typed `opaque`; **outside the secret guarantee** |
| `secret` | grants access | never (one exception, below) |
| `mac-only` | only means something on this Mac | never |

A class only moves towards more sensitive, through evidence.

### Allowlist first

- **Supported adapters carry fields, not files, wherever the format allows.**
  An adapter parses its format, keeps only the fields on its allowlist, drops
  every field on its credential list, and **regenerates** the target
  configuration from the kept fields (Git settings through `git config`, MCP
  servers through the tools' own definitions, Ghostty and Starship settings
  line by line). What an adapter does not understand, it does not carry.
- **Whole files** are carried where a format has no fields to allowlist
  (instructions, a skill's Markdown, a Neovim Lua tree, a tmux
  configuration, the Zsh rc files as reference copies that nothing
  sources). They are scanned, marked "carried whole" in the review, and
  outside the field guarantee below.
- **Heuristics reject; they never approve.** Every captured text object is
  scanned for credential shapes — private-key headers, token forms (`sk-ant-`,
  `sk-`, `ghp_`, `gho_`, `github_pat_`, `xox?-`, `AKIA` and sixteen
  capitals, `AIza`, JWT shapes) and `password`/`token`/`secret`/`key`
  assignments with long values — over its **whole length**. A hit excludes
  the file and names it with the kind of match, never the value. A miss
  proves nothing.
- **Classification and export see the same bytes.** Export captures each file
  once into its object, then classifies the object: the bytes scanned are the
  bytes carried. A file whose captured bytes now fail a rule it passed at
  selection is left behind and reported.

### Custom paths: opaque, by consent

What no supported adapter understands in a chosen folder is `opaque`:
excluded by default, and included only after the person types `opaque`,
once per save, on a screen that lists every opaque path being saved and
says that their contents are not checked field by field, that the product
makes no promise they hold no secret, and that Shared is not encrypted.
Known credential files are still refused inside it by path (`id_*` private
keys, `.env*`, `credentials`, `*.pem`, `*.key`, `*.p12`, `hosts.yml`,
`auth.json`, `.netrc`, `.npmrc` with `_authToken`, the tools' sign-in
files), the heuristic scan still runs, and restore shows the content as
opaque again.

### Hard refusals

Every carried path is printable ASCII (bytes 0x20 through 0x7E), including
paths inside adapter-owned and opaque trees and every name the filesystem
identity check reports for an inode. A name outside that range is refused
because Unicode spellings can hide a credential filename on the Mac. The
item names this reason. The encrypted SSH-key exception does not override
the path rule.

Every regular file carried from macOS has exactly one name. A file with
other names (hard links) is refused, because another name could hide a
refused one. This applies inside adapter-owned and opaque trees, to single
files and to encrypted SSH keys. The link count and file type come from
one `lstat`, which never follows a link; directories and symbolic links
keep their own rules.

Never carried, whatever is selected: SSH private keys (except below), the
tools' sign-in and token files, `.env` files, cloud and container
credentials (`~/.aws`, `~/.docker/config.json`, `~/.kube/config`), `.netrc`,
GnuPG private keys, anything in the Keychain (never read), browser profiles,
`~/Library` as a whole.

### Secret channels

| Channel | Handling |
| --- | --- |
| configuration values | supported adapters keep allowlisted fields only |
| environment values (shell exports, MCP `env`) | a value never travels unless the adapter's allowlist names that variable and its value passes the value grammar; MCP `env` values never travel — they become the tool's own variable reference and the item is `needs-secret` |
| URLs | a URL with user information (`user@` or `user:pass@`, in any URL with a scheme) or a query or fragment parameter whose name, percent-decoded, is named like a credential (`token`, `key`, `secret`, `sig`, `signature` such as `X-Amz-Signature`, `credential`, `auth`, `password`, `session`) is dropped, and the field flagged; an argument, URL or configuration value holding a control byte (which URL parsers strip) is dropped the same way; `git@host:path` names an account, not a credential, and passes |
| Git remotes | the same URL rule; a remote that fails it is withheld from the inventory, for the person to re-enter |
| command arguments (MCP `args` and OpenCode's `command`, hooks) | an argument after a credential-named flag (`--token`, `--api-key`, `--key`, `--auth`, `--password`, `--secret`), the same flag written `FLAG=VALUE`, an argument holding a URL that fails the URL rule, or one matching a credential shape, is dropped and the item is `needs-secret` |
| logs and records | hold names, ids, digests and sanitised URLs only |
| MCP configuration | re-created from neutral records with the rules above (docs/AI-TOOLS.md) |
| SSH | `~/.ssh/config` is `config`, its `UseKeychain` lines dropped (Linux's OpenSSH refuses them); `known_hosts` is `sensitive`; private keys are refused except below |
| `.env*` files (every name starting with `.env`: `.envrc`, `.env-production`, `.envrc.local`) | refused |
| Keychain references (`credential.helper osxkeychain`, a `security` command in `apiKeyHelper`) | dropped as macOS-only and flagged |

### The one secret exception: an encrypted SSH key

An OpenSSH private key may travel only if its envelope is parsed and shows
encryption with a supported policy, and the person types `carry` for that
key:

- the file is at most 16 KiB and is canonical OpenSSH armor: exactly
  `-----BEGIN OPENSSH PRIVATE KEY-----` and LF, nonempty standard-alphabet
  Base64 lines of at most 76 characters with LF endings, then exactly
  `-----END OPENSSH PRIVATE KEY-----` and one final LF. Padding (`=`) is
  allowed only at the end of the body, with its unused bits zero. No text,
  comments, blank lines, CR bytes or second Base64 run may appear;
- the body decodes in full to one `openssh-key-v1` envelope, consumed
  exactly, including its KDF options. Its cipher is `aes256-ctr`,
  `aes256-gcm@openssh.com` or `chacha20-poly1305@openssh.com`; its KDF is
  `bcrypt` with a salt of at least 16 bytes and at least 16 rounds;
- its single public blob is complete: `ssh-ed25519` has a 32-byte key;
  `ssh-rsa` has two canonical positive mpints, e and n, with n at least
  2048 bits. Security-key (`sk-`)
  and DSA types are refused. ECDSA private keys (`ecdsa-sha2-nistp256`,
  `ecdsa-sha2-nistp384`, `ecdsa-sha2-nistp521`) are refused: the scanner
  cannot check that their public point is on its curve without big-number
  arithmetic. Re-create the key on Linux, or carry an Ed25519 or RSA key;
- the private section is at least the minimum encoding for its public type:
  two check integers, its type and required key strings or mpints, a comment
  string, and padding. Ed25519 needs at least 132 bytes before rounding up
  to a whole cipher block. The section is block-aligned (16 bytes for AES,
  8 for ChaCha20); either authenticated cipher has exactly its 16-byte tag
  after it. An older PEM format, an unencrypted key, an unknown cipher or
  any malformed file or envelope is refused;
- the passphrase is never asked for, and its strength is not checked: the
  screen says that an encrypted key is still valuable to anyone who copies
  it, because a weak passphrase can be guessed offline, and that making a new
  key on Linux is the better choice;
- the key is placed 0600, never previewed, never logged, never in a report;
- removing it from Shared later is not secure erasure, and the screen says
  so.

### The guarantee, exactly

Three kinds of content, three different promises:

| Kind | Promise | Not promised |
| --- | --- | --- |
| **parsed configuration** of a supported adapter (Git settings, MCP definitions, the AI tools' settings, Codex's configuration, Ghostty and Starship settings; Starship's file is rebuilt from its prompt settings, module display fields, palettes and directory substitutions, its custom modules and unknown fields left behind and listed) | only its allowlisted fields leave macOS; its known credential fields never do; the credential-shape scan rejects on top | that an allowlisted field never holds a credential in a form nobody recognises |
| **files a supported adapter carries whole** (instructions, skills, a Neovim tree, a tmux configuration) | the hard refusals and the whole-length scan apply; a credential of a shape the scan knows excludes the file; the review marks each as "carried whole" | that the file is secret-free: a scan that finds nothing proves nothing |
| **opaque custom paths** | excluded by default; carried only after typed `opaque`, with the warning that Shared is not encrypted; known credential files inside are still refused; the scan still runs | anything about their contents: they are outside the secret guarantee |

The one exception, an encrypted SSH key, is above. The product never claims
that a file carried whole, or an opaque one, contains no secret.

## Selection

Selection happens in the frontend (docs/UX.md → *Every screen*). By
default, requested software (`requested=yes`) that resolves to an install
or to something Omarchy provides is included, `requested=unknown` is a
decision, and dependencies are not offered; macOS-only and unsupported
items are shown and excluded, with the reason; alternatives and unresolved
items are held for a decision; each adapter's known portable configuration
is included; chosen folders wait to be chosen, and opaque ones for
`opaque`; `sensitive` items wait for an opt-in; `secret` and `mac-only`
never travel, apart from the one exception.

**Not in v1**: agent sessions, transcripts and prompt histories, agent
memory, shell history, application data from `~/Library`. History
*settings* (such as `HISTSIZE`) carry with the shell adapter.

## Chosen folders

Discovery lists names and types under `~` and `~/.config` without
reading inside: a candidate folder has no size until it is carried, and a
link is listed by its text, never followed. The one read below the top is
project discovery: one level of a top-level folder that is neither a link
nor protected (`~/code`), and only each child checkout's `.git/config` and
`.git/HEAD`, none of them through a link (a checkout whose `.git` or either
file is a link is listed by name, not read). What an adapter owns (`~/.claude`, `~/.codex`,
`~/.config/nvim`) goes to that adapter. A folder's contents are read
(`sys_walk`), each file classified, and a denial reported only when it is
carried; the folder shows its most sensitive class and the preview masks
credential-shaped values. A chosen root is resolved through every link on
the way and refused when it leads to the home itself, above or outside the
home, into `~/Library`, `~/.ssh` or `~/.gnupg`, or to a hard-refused path
(held by device and inode, not by spelling, since the Mac's filesystem
folds case and Unicode, and refused when its resolved path is not
printable ASCII), or when the link leads to another link; a link to `/`
leads outside the home;
a root that is a link (a GNU Stow farm) is carried as a folder at the
chosen path, and each file inside is checked by its real path as well as
by the name it was chosen under.

## The Migration Profile

One `omb-profile 1` document, `profile.omb` in the macOS state directory,
sealed on every write and bound to this Mac by its host id: the first 16
hex digits of SHA-256 over a fixed label and the hardware UUID
`system_profiler` reports, never the UUID itself. It holds the source Mac
(model, macOS version, user, home, shell), each adapter's scan state
(`done`, `partial`, `unknown`, `denied`, `skipped`), the items with their
evidence and class, the selection, the decisions and the resolution; never
file contents. It is input, never authority.

`profile` saves the inventory, and the frontend sends the person's choices
as one `omb-select 1` document: `select` records (include or exclude) and
`decision` records (docs/RESOLVER.md → *The person's decisions*). The core
admits it, refuses it whole if it names an id the profile does not hold,
asks for the typed words the choices need (`opaque` once if any opaque
folder is included, `carry` for each encrypted SSH key), resolves and
saves; without the frontend, `profile` saves the defaults. Every run scans
afresh, keeps choices by item id (adapter and name, or path; never a
version), and reports what is gone and what is new. `profile show` prints
the review; `profile show --unresolved`, the unresolved items.

| State | Means |
| --- | --- |
| `not-scanned` | no `profile.omb` |
| `scanned` | an inventory; no selection saved yet |
| `selected` | a selection with an included item still `unresolved` or `needs-decision` |
| `saved` | every included item `resolved` or `unsupported`: export can use it |
| `invalid` | fails admission or its seal, or was made on another Mac (a Time Machine restore brings the everyday Mac's): never used, and replaced by the next `profile` |

### On the wire

The frontend reads the profile through scope `profile` and acts on it
through the rows of docs/PROTOCOL.md → *The action table*; `lib/migrate_profile.sh`
answers (`prof_core_op`), from `profile.omb` and, for `profile.scan`, a
fresh scan.

- **`snapshot scope=profile`**: facts `profile.state` (the state above),
  `profile.mac`, `profile.scanned`, `profile.counts`; one
  `adapter.<adapter>` per adapter (value `<state> · <n> items`; `ok` done,
  `warn` partial, `fail` denied, `unknown`, `info` skipped); one
  `category.<category>` per category (`<selected> of <total> · <size>`;
  `warn` while a decision is open); `change.gone` and `change.new` after a
  rescan; blockers; the profile's actions and their parameters.
- **`detail scope=profile`**, paged, under the snapshot's generation (the
  SHA-256 of `profile.omb`):
  - `items` — `row kind=item key=<item id>`, columns: category, name,
    source, version, becomes, state (`include`, `exclude`, `decide` or
    `never`), class, by (`default` or `person`), reason, size in bytes,
    evidence, requested. Items that need a decision come first.
  - `choices` — `row kind=choice key=<item id>`, columns: choice id,
    label, guess (`0` or `1`); the decisions an item offers.
  - `review` — `row kind=review key=<category>`, columns: label, selected,
    size in bytes, what comes next; the Migration Review.
  - `changes` — `row kind=change key=<item id>`, columns: `gone` or `new`,
    name.
  - `opaque` — `row kind=opaque key=<item id>`, columns: path, size; what
    a typed `opaque` would cover.
  - `keys` — `row kind=key key=<item id>`, columns: path, cipher, KDF
    rounds; the encrypted SSH keys `carry` can include.
- **The person's choices** travel as one `omb-select 1` document: `select
  id=<item id> state=include|exclude` and `decision id=<item id>
  choice=<choice id> value=<bytes>` records, only the choices that differ
  from the defaults, at most 60 KiB. The frontend splits it at line ends
  into the arguments `select.1` … `select.14`, each value at most 4 KiB as
  written; the core joins them in number order and admits the whole as an
  `omb-select` document, refused whole if it names an item the profile does
  not hold. `validate select action=profile.save` answers its `review`
  basis (the SHA-256 of the action id, the profile's generation and the
  joined document); `execute profile.save` sends the same arguments and
  that basis.
- `profile.scan` emits a `progress` record per adapter (`unit=adapter`,
  the adapter's name as label) and a `message` with each adapter's result.

Scope `export` (`lib/migrate_bundle.sh`, `bndl_core_op`): facts
`export.profile`, `export.dest` (verified Shared and its mount point, or
none), `export.size`, `export.last`; the row `export.write`.

## The bundle

`export [DIR]` (act, macOS) needs a `saved` profile and writes a new bundle
each time: to Shared once the baseline has verified it (the mount point
`diskutil` reports for Shared's GUID), or to a folder the person names,
such as a USB drive or SD card. It scans afresh and reconciles with the
profile (an item no longer found is reported and left out; a new one waits
for the next `profile`); refuses when the selected files pass 2 GiB or the
destination's free space; captures each file once into the run's scratch
directory and classifies those bytes (*Allowlist first*); and writes what
passes into `omarchy-mac-bootstrap/bundles/<utc>.partial-<random>/`
(`objects/<sha256>` and `bundle.omb`, sealed last), then renames the folder
to `<utc>`. Nothing in a bundle folder, finished or partial, is ever
deleted, on either system: a failed export leaves its `.partial-*` folder,
which restore never lists, for the person to remove by hand.

The bundle holds files ready for their place on Linux (Claude Code's
settings, Codex's `config.toml`, `shell.bash`, what is carried whole).
`bundle.omb` records the time, the Mac and the counts; each item's class,
parsed or carried whole; an entry per file, folder and link (`dest`, mode,
SHA-256 or link text); what Linux sets up through its owners' commands
(docs/RESTORE.md): Git settings, MCP servers (Claude Code's and OpenCode's,
secret values replaced by variable references; Codex's travel in its
`config.toml`), plugins, and packages (layer, method, target, version,
whether a guess); the macOS paths found in files carried whole, listed and
never rewritten; and what was skipped, with the reason.

`bundle.omb` is an `omb-bundle 1` document, sealed, at most 16 MiB
(`lib/migrate_bundle.sh` defines the family, `_recx_bundle`), its records
in this order:

| Record | Schema |
| --- | --- |
| `bundle` 1 | `at:utc host:hex16 model:text user:bytes home:bytes items:uint files:uint bytes:uint` |
| `item` * | `id:bytes class:enum(…) whole:bool`, one per item carried |
| `dir` * | `item:bytes dest:bytes mode:enum(0700\|0755)` |
| `file` * | `item:bytes dest:bytes mode:enum(0600\|0644\|0700\|0755) sha256:hex64 size:uint whole:bool` |
| `link` * | `item:bytes dest:bytes target:bytes` |
| `setting` * | `item:bytes kind:enum(git\|mcp\|plugin) tool:id name:bytes value:bytes?` |
| `package` * | `item:bytes layer:enum(packages\|runtimes\|tools\|ai) method:id target:bytes? version:bytes? guess:bool` |
| `macpath` * | `item:bytes dest:bytes path:bytes` |
| `skip` * | `item:bytes reason:text` |

Export takes each item's carried form from the scanner (`scan_extract`),
hashes each captured file and scans those bytes (`scan_secret_check`; for a
key carried after `carry`, `scan_key_check`), and scans every value the
item would write as well: one hit leaves the whole item behind, reported by
kind. The writes stop and fail cleanly at three boundaries — each object,
the manifest, the rename — and leave only the `.partial-*` folder. Before
the rename the whole bundle passes the bundle check, `bndl_check DIR`,
which restore runs again on Linux: the seal, every `dest` against the
grammar and all of them together, each link's text (relative, never above
the home), and each object a plain file of its recorded size, at most
64 MiB, with its digest.

Objects are plain regular files named by the lowercase hex SHA-256 of their
bytes, at most 64 MiB each (a larger file is skipped as `too-large`): no
link, FIFO, socket or device object, no other name, no archive. Where a
file goes is only ever its entry's `dest`: relative to the target home;
components separated by `/`, none empty, `.` or `..`; no control byte; at
most 255 bytes a component, 1 024 in all, 32 deep; inside the item's own
root. All entries are checked together: no two with one `dest`, no `file`
or `link` where another needs a folder, nothing beneath a `link` entry.
Only destinations are compared, byte for byte as Linux does, since objects
are named by hash; names that differ only in Unicode normalisation are
allowed, with a warning.

### What is carried from each kind of source

| Source | Carried as | Not carried |
| --- | --- | --- |
| regular file | an object and its `dest`; mode 0644, or 0755 if any execute bit was set; 0600 or 0700 for what is not `config` | ownership, timestamps, flags, ACLs |
| directory | a `dir` entry (0755, or 0700 for what is not `config`); empty directories kept | ownership, timestamps |
| symbolic link | a `link` entry only if its target, resolved lexically from the link's directory, stays inside the item's own root and passes through no other link; stored as relative text | absolute targets, targets outside the item, chains: `skipped` with the reason |
| hard link (a regular file with more than one name) | — | `skipped` with the reason: another name could hide a refused one |
| extended attributes, resource forks, quarantine flags | — | never read, never carried |
| socket, FIFO, device | — | `skipped` with the reason |

## Moving between the systems

The two systems never run at the same time, and Linux never reads APFS.
Before Shared exists, Linux needs only the resume token (the install
answers and plan id, typed); the tool comes from the commit the Phase 1
guide pinned and its frontend from the release lock, and recovery help is
`debug`'s agent brief on either system (docs/TROUBLESHOOTING.md). macOS
exports in the same boot that creates Shared; without Shared, a USB drive
or SD card (exFAT or FAT32; the 16-inch MacBook Pro has an SDXC slot)
carries the bundle. Never the network or a Git remote: the systems are
never up together, and configuration pushed to a remote stays in its
history.

## Import on Linux

`restore [DIR]` (docs/RESTORE.md) lists the bundles on verified Shared or
in the folder given, each with the Mac it came from and its time, and
selects the newest finished bundle that passes the check, refusing a bundle
whole at
the first failure: `bundle.omb` admitted (docs/PROTOCOL.md → §2) and its
seal checked; every `dest` against the grammar, then all of them together
(*The bundle*); every object against its digest, and again as it is
staged. It reads only the names `bundle.omb` lists; the `._name` and
`.DS_Store` files macOS leaves on exFAT are ignored. Nothing else is asked:
nobody but this Mac's two systems writes Shared, the seal and the digests
catch corruption, and the typed `restore` after the review is the consent.


Restore reviews destinations and keeps conflicts by default. The apply
request's required `review` parameter binds the exact 64-hex restore
snapshot generation shown with its conflicts and diffs; validation and the
fresh execution basis refuse a changed generation. After typed
`restore`, it stages beside each destination, rechecks parents and bytes,
moves an original whole into a private backup and places with no-clobber
GNU `ln -T` for regular files, `ln -s -T` for symbolic links, or
`mv -T --update=none-fail` for folders. File and link stages are removed
after the link is made. The manifest's full SHA-256 identifies the run.
Before any install or placement, apply tests refusal of occupied file and
directory destinations and success at free names in a
private `restore/no-clobber` folder on the home's filesystem, clearing any
probes left by a stopped check before reusing it. Unsupported or unsafe placement
commands stop apply; GNU coreutils 9.5 or later is required. The same SHA
names `restore/runs/<sha>.log` and `restore/backups/<sha>/` under the state
directory. Every append is flushed; complete records are admitted and torn
tails ignored. Successful AI version invocations add the complete
`agent<TAB>tool=ID<TAB>ran=1<LF>` receipt at `restore.agent`.

A rerun reads the filesystem again and settles an interrupted placement.
If placement failed after an original moved, it returns with a no-clobber
move when the destination is free; otherwise its backup location is shown.
Generated Bash and OpenCode files use the recorded original's custom
content during review, then are reviewed again after that original returns.
Private directory modes are applied to the stage, leaving scratch writable.
Partial stages and previous undo cycles are preserved under fresh names.
Git settings and MCP definitions have private 0600 backups; values never
reach output or the run log. `restore undo` follows the newest restore run
log, checks the bytes it actually moved and puts an intervening edit back
before refusing that item. Undo reverses only placements recorded in the
current cycle, after the last `undone`. Without a placement record, a
destination matching the recorded after and differing from the before is
left as is and named, with its original's backup or a note that there was
no original. Its judge reports `unexpected`, naming it. Matching bytes and
stage names do not establish who placed it. Other states without a pending
original are skipped silently. A pending original in its checked backup
returns only when the destination is free; an occupied destination is
refused, with the backup path shown, and never moved. Settings without a
current-cycle placement record are never reverted automatically: undo names
the setting and its private backup, and its judge reports `unexpected`. No
value is printed. Completed stages are removed only when their bytes match
the reviewed content or retained backup; cleaning a silently skipped item's
private stage leaves its destination untouched. Independent items continue
after refusal. A second Replace names
`cp -a -T BACKUP DEST` to return a recorded placement's original with its
type and mode while retaining the backup, before undo and another review.
An unrecorded pending original instead requires a free destination for undo.
A successful mise backend install with no observed version folder under mise's kebab-case directory name is unverified,
warns, and allows later layers to continue. The final complete message counts
unverified items and says nothing showed them installed. Originals and displaced restored bytes remain in backups. Packages
and external installer changes require manual reversal. `rst_status_counts` supplies
Health with verified (`placed` or `in-place`), kept, failed and pending
counts, in that order. Pending includes items waiting on a person; an
unreadable count is a fixed warning. The exact placement, recovery and undo
rules are in docs/RESTORE.md.
