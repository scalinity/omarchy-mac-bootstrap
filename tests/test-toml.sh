#!/usr/bin/env bash
# The strict TOML subset reader (lib/toml.sh; docs/AI-TOOLS.md → *Codex's
# configuration*, D44): files shaped as Codex and mise write them, read
# exactly; anything outside the subset refuses the whole file, naming its
# first line and the construct. No plutil: these run on every system.
# shellcheck disable=SC2015 # ok/fail always return 0
# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=lib/toml.sh
. "$REPO/lib/toml.sh"
echo "test-toml"

T=$(t_tmp)

# toml-codex: a configuration as Codex writes it (toml_edit: basic strings,
# quoted keys holding dots, sub-tables, floats for times, arrays of tables).
cat >"$T/codex.toml" <<'EOF'
# Written by Codex
model = "gpt-5.5-codex"
model_reasoning_effort = "high"
approval_policy = "on-request"
notify = ["bash", "-lc", "afplay /System/Library/Sounds/Glass.aiff"]

[mcp_servers.context7]
command = "npx"
args = ["-y", "@upstash/context7-mcp"]
startup_timeout_sec = 20.0

[mcp_servers.context7.env]
CONTEXT7_API_KEY = "a-value"

[mcp_servers."docs.example/mcp"]
url = "https://docs.example.com/mcp"
env_vars = ["A", { name = "B", source = "local" }]

[projects."/Users/alex/code/app"]
trust_level = "trusted"

[[skills.config]]
path = "/Users/alex/.agents/skills/x"
enabled = false

[[skills.config]]
path = "/Users/alex/.agents/skills/y"
EOF
toml_read "$T/codex.toml" "$T/codex.out"
assert_rc $? 0 "toml-codex: a file as Codex writes it is accepted"
out=$(cat "$T/codex.out")
for want in 's	model	gpt-5.5-codex' 's	notify.2	afplay%20/System/Library/Sounds/Glass.aiff' 'a	notify	3' \
  't	mcp_servers.context7' 's	mcp_servers.context7.args.1	@upstash/context7-mcp' 'f	mcp_servers.context7.startup_timeout_sec	20.0' \
  's	mcp_servers.context7.env.CONTEXT7_API_KEY	a-value' 's	mcp_servers.docs%2Eexample%2Fmcp.url	https://docs.example.com/mcp' \
  's	mcp_servers.docs%2Eexample%2Fmcp.env_vars.1.name	B' 's	projects.%2FUsers%2Falex%2Fcode%2Fapp.trust_level	trusted' \
  't	skills.config.0' 'b	skills.config.0.enabled	false' 's	skills.config.1.path	/Users/alex/.agents/skills/y'; do
  assert_contains "$out" "$want" "toml-codex: read exactly ($want)"
done
assert_eq "$(sed -n 1p "$T/codex.out")" "s	model	gpt-5.5-codex" "toml-codex: in the file's order"
cp "$T/codex.out" "$T/codex.first"
toml_read "$T/codex.toml" "$T/codex.out"
if cmp -s "$T/codex.first" "$T/codex.out"; then ok; else fail "toml-codex: a second read gives the same records"; fi

# toml-mise: mise's global configuration.
printf '[tools]\nnode = "22"\npython = ["3.12", "3.11"]\n"npm:prettier" = "latest"\n\n[settings]\nexperimental = true\njobs = 4\n' >"$T/mise.toml"
toml_read "$T/mise.toml" "$T/mise.out"
assert_rc $? 0 "toml-mise: mise's file is accepted"
assert_eq "$(tr '\n' '|' <"$T/mise.out")" "t	tools	|s	tools.node	22|s	tools.python.0	3.12|s	tools.python.1	3.11|a	tools.python	2|s	tools.npm%3Aprettier	latest|t	settings	|b	settings.experimental	true|i	settings.jobs	4|" \
  "toml-mise: every value, in order"

# toml-strings: the escapes, literal and multi-line strings TOML 1.1 defines.
cat >"$T/s.toml" <<'EOF'
a = "tab\there \"q\" \\ \u00e9 \x41 \e"
b = 'C:\no\escape'
c = """
first \
   second"""
d = '''two
lines'''''
e = ""
EOF
toml_read "$T/s.toml" "$T/s.out"
assert_rc $? 0 "toml-strings: the subset's strings are accepted"
assert_contains "$(cat "$T/s.out")" "s	a	tab%09here%20%22q%22%20%5C%20%C3%A9%20A%20%1B" "toml-strings: basic escapes, \\u and \\x as Unicode, \\e"
assert_contains "$(cat "$T/s.out")" "s	b	C:%5Cno%5Cescape" "toml-strings: a literal string keeps backslashes"
assert_contains "$(cat "$T/s.out")" "s	c	first%20second" "toml-strings: the first newline and a line-ending backslash"
assert_contains "$(cat "$T/s.out")" "s	d	two%0Alines%27%27" "toml-strings: up to two quotes close a multi-line literal"
assert_contains "$(cat "$T/s.out")" "s	e	" "toml-strings: an empty string"

# toml-tables: TOML's own rules on keys and tables.
for good in 'a.b.c = 1
[a.b.x]
z = 2' '[a.b]
[a]
c = 1' '[[x]]
[x.y]
z = 1
[[x]]'; do
  printf '%s\n' "$good" >"$T/g.toml"
  toml_read "$T/g.toml" "$T/g.out"
  assert_rc $? 0 "toml-tables: accepted: $(tr '\n' '|' <"$T/g.toml")"
done

# toml-refuse: each construct outside the subset refuses the whole file,
# naming its first line and what it is; nothing of it is read.
refuse() { # LINE WHY CONTENT
  printf '%s\n' "$3" >"$T/r.toml"
  printf 'ok = 1\n' >"$T/r.out"
  toml_read "$T/r.toml" "$T/r.out"
  assert_eq "$? $TOML_AT $TOML_WHY" "1 $1 $2" "toml-refuse: $(tr '\n' '|' <"$T/r.toml")"
  assert_eq "$(wc -c <"$T/r.out" | tr -d ' ')" 0 "toml-refuse: nothing read from $(head -n 1 "$T/r.toml")"
}
refuse 2 "a date or time value" 'model = "x"
when = 1979-05-27T07:32:00Z'
refuse 1 "a date or time value" 'at = 07:32:00'
refuse 1 "a hexadecimal, octal or binary integer" 'n = 0xDEAD'
refuse 1 "a hexadecimal, octal or binary integer" 'n = 0o755'
refuse 1 "an underscore in a number" 'n = 1_000'
refuse 1 "inf or nan" 'n = -inf'
refuse 1 "inf or nan" 'n = nan'
refuse 1 "a number with a leading zero" 'n = 012'
refuse 1 "an integer outside 64 bits" 'n = 9223372036854775808'
refuse 1 "an inline table over several lines" 't = { a = 1,
  b = 2 }'
refuse 1 "a trailing comma in an inline table" 't = { a = 1, }'
refuse 2 "a key defined twice" 'a = 1
a = 2'
refuse 2 "a table defined twice" '[t]
[t]'
refuse 2 "a table defined twice" 'a.b.c = 1
[a.b]'
refuse 3 "a table defined twice" '[x.y]
[x]
y.z = 1'
refuse 2 "a key that is both a value and a table" 'a = 1
[a]'
refuse 2 "an array of tables after a static array of that name" 'x = [1]
[[x]]'
refuse 1 "an escape TOML does not define" 's = "\q"'
refuse 1 "a NUL escape in a string" 's = "\u0000"'
refuse 1 "an escape that is not a Unicode scalar" 's = "\uD800"'
refuse 1 "an unterminated string" 's = "open'
refuse 1 "a value outside the subset" 's = bare'
refuse 1 "an empty key" '"" = 1'
refuse 2 "text after a value on its line" 'a = 1
b = 2 c = 3'
printf 'a = "x\r"\n' >"$T/r.toml"
toml_read "$T/r.toml" "$T/r.out"
assert_eq "$? $TOML_AT $TOML_WHY" "1 1 a CR byte" "toml-refuse: a CR byte"
printf 'a = 1\nb = "caf\351"\n' >"$T/r.toml"
toml_read "$T/r.toml" "$T/r.out"
assert_eq "$? $TOML_AT $TOML_WHY" "1 2 invalid UTF-8" "toml-refuse: invalid UTF-8"
printf 'a = 1\n# ok \303\251\nb = "x\000y"\n' >"$T/r.toml"
toml_read "$T/r.toml" "$T/r.out"
assert_eq "$? $TOML_AT $TOML_WHY" "1 3 a control character" "toml-refuse: a NUL byte, on its own line"
printf 'a = "x\033y"\n' >"$T/r.toml"
toml_read "$T/r.toml" "$T/r.out"
assert_eq "$? $TOML_AT $TOML_WHY" "1 1 a control character" "toml-refuse: a raw control character"

# toml-bounds: size, line length and nesting.
deep="a = "
i=0
while [ "$i" -lt 17 ]; do deep="${deep}[" && i=$((i + 1)); done
i=0
while [ "$i" -lt 17 ]; do deep="$deep]" && i=$((i + 1)); done
printf '%s\n' "$deep" >"$T/r.toml"
toml_read "$T/r.toml" "$T/r.out"
assert_eq "$? $TOML_AT $TOML_WHY" "1 1 arrays or inline tables nested more than 16 deep" "toml-bounds: nesting past 16"
printf 'a = %s1%s\n' "$(printf '%016d' 0 | tr 0 '[')" "$(printf '%016d' 0 | tr 0 ']')" >"$T/r.toml"
toml_read "$T/r.toml" "$T/r.out"
assert_rc $? 0 "toml-bounds: nesting of 16 is accepted"
awk 'BEGIN { s = "a = \""; for (i = 0; i < 16400; i++) s = s "x"; print s "\"" }' >"$T/r.toml"
toml_read "$T/r.toml" "$T/r.out"
assert_eq "$? $TOML_AT $TOML_WHY" "1 1 a line over 16 KiB" "toml-bounds: a line over 16 KiB"
awk 'BEGIN { for (i = 0; i < 20000; i++) printf "k%d = \"%s\"\n", i, "0123456789012345678901234567890123456789012" }' >"$T/r.toml"
toml_read "$T/r.toml" "$T/r.out"
assert_eq "$? $TOML_AT $TOML_WHY" "1 0 a file over 1 MiB" "toml-bounds: a file over 1 MiB, refused unread"
toml_read "$T/missing.toml" "$T/r.out"
assert_rc $? 2 "toml-bounds: a file that cannot be read"

rm -rf "$T"
t_done test-toml
