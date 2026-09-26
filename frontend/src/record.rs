//! The record format and admission (docs/PROTOCOL.md → §1, §2).
//!
//! The same rules as `lib/records.sh`, applied directly on bytes: a document
//! is admitted or refused with the reason code of the first check that fails,
//! in the step order of the Bash admission (size, byte class, termination,
//! framing and canonical form, the seal, the schema). The two are held
//! together by the differential corpus (`tests/proto/corpus.sh`), which both
//! judge, and by a test that reads the schema tables out of `lib/records.sh`.
//!
//! [`Admitter`] reads a document in chunks as it grows (the event spool) and
//! gives the same verdict however the bytes were split.

use std::fmt;

pub const SCOPES: &str = "journey|disk|plan|profile|resolve|asahi|network|omarchy|shared|export|restore|rescue|qualify|debug";
pub const STAGES: &str = "survey|profile|resolve|plan|asahi|omarchy|shared|restore|verify|done";

const LINE_MAX: usize = 16384;
const VALUE_MAX: usize = 4096;
const CODE_MAX: usize = 512;
const SEAL_PREFIX: &[u8] = b"seal\tsha256=";

/// The document families the frontend admits or builds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Family {
    Req,
    Res,
    Lock,
    Children,
    Proc,
    Op,
}

impl Family {
    pub fn parse(s: &str) -> Option<Family> {
        Some(match s {
            "req" => Family::Req,
            "res" => Family::Res,
            "lock" => Family::Lock,
            "children" => Family::Children,
            "proc" => Family::Proc,
            "op" => Family::Op,
            _ => return None,
        })
    }
    pub fn name(self) -> &'static str {
        match self {
            Family::Req => "req",
            Family::Res => "res",
            Family::Lock => "lock",
            Family::Children => "children",
            Family::Proc => "proc",
            Family::Op => "op",
        }
    }
    pub fn header(self) -> &'static str {
        match self {
            Family::Req => "omb-req 1",
            Family::Res => "omb-res 1",
            Family::Lock => "omb-frontend-lock 1",
            Family::Children => "omb-children 1",
            Family::Proc => "omb-proc 1",
            Family::Op => "omb-op 1",
        }
    }
    pub fn max_bytes(self) -> usize {
        match self {
            Family::Req => 65536,
            Family::Res => 8 * 1024 * 1024,
            _ => 65536,
        }
    }
    /// 0: no record limit beyond the byte limit.
    pub fn max_records(self) -> usize {
        match self {
            Family::Req => 512,
            Family::Res => 65536,
            _ => 0,
        }
    }
    pub fn sealed(self) -> bool {
        !matches!(self, Family::Req | Family::Res)
    }
    pub fn order(self) -> &'static [&'static str] {
        match self {
            Family::Req => &["req", "scope", "page", "select", "exec", "arg"],
            Family::Res => &[
                "hello",
                "generation",
                "stage",
                "fact",
                "region",
                "answer",
                "guide",
                "code",
                "warning",
                "blocker",
                "action",
                "param",
                "normal",
                "invalid",
                "review",
                "row",
                "progress",
                "message",
                "overflow",
                "result",
            ],
            Family::Lock => &["frontend", "artifact"],
            Family::Children => &["child"],
            Family::Proc => &["proc"],
            Family::Op => &["op"],
        }
    }
}

/// The protocol's operations.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Op {
    Hello,
    Snapshot,
    Detail,
    Validate,
    Execute,
}

impl Op {
    pub fn parse(s: &str) -> Option<Op> {
        Some(match s {
            "hello" => Op::Hello,
            "snapshot" => Op::Snapshot,
            "detail" => Op::Detail,
            "validate" => Op::Validate,
            "execute" => Op::Execute,
            _ => return None,
        })
    }
    pub fn name(self) -> &'static str {
        match self {
            Op::Hello => "hello",
            Op::Snapshot => "snapshot",
            Op::Detail => "detail",
            Op::Validate => "validate",
            Op::Execute => "execute",
        }
    }
    fn column(self) -> usize {
        match self {
            Op::Hello => 0,
            Op::Snapshot => 1,
            Op::Detail => 2,
            Op::Validate => 3,
            Op::Execute => 4,
        }
    }
}

/// The fields of each record type, written exactly as in `lib/records.sh`
/// (`$s` is the scope enum). `?` optional, `*` a list, `+` a list of at least
/// one.
pub fn spec(family: Family, ty: &str) -> Option<&'static str> {
    Some(match (family, ty) {
        (Family::Req, "req") => {
            "op:enum(hello|snapshot|detail|validate|execute) proto:uint frontend:id session:hex16"
        }
        (Family::Req, "scope") => "name:$s",
        (Family::Req, "page") => "scope:$s kind:id generation:hex64 offset:uint limit:uint",
        (Family::Req, "select") => "action:id",
        (Family::Req, "exec") => "action:id basis:hex64 confirm:id?",
        (Family::Req, "arg") => "name:id value:bytes",
        (Family::Res, "hello") => {
            "core:id commit:hex40? source:hex64 proto:uint platform:enum(macos|linux) arch:enum(arm64|aarch64) user:enum(root|user) ceiling:enum(read|plan|act) dry_run:bool fixture:bool"
        }
        (Family::Res, "generation") => "id:hex64 total:uint",
        (Family::Res, "stage") => {
            "name:enum($REC_STAGES) state:enum(done|current|todo|skipped|blocked) basis:enum(machine|recorded) by:enum(macos|linux)? at:utc? detail:text?"
        }
        (Family::Res, "fact") => {
            "scope:$s key:id label:text value:text state:enum(ok|info|warn|fail|unknown)"
        }
        (Family::Res, "region") => {
            "start:uint size:uint role:enum(apple|macos|stub|efi|linux|shared|free|other) label:text?"
        }
        (Family::Res, "answer") => "n:uint prompt:text value:text bytes:uint?",
        (Family::Res, "guide") => "id:id step:uint text:text",
        (Family::Res, "code") => "kind:enum(token|ombdone|ombshare|ombbundle) value:code",
        (Family::Res, "warning") | (Family::Res, "blocker") => "id:id text:text fix:text?",
        (Family::Res, "action") => {
            "id:id scope:$s label:text intent:enum(read|plan|act) gate:id? terminal:enum(managed|handoff) cancel:bool basis:hex64? explain:text?"
        }
        (Family::Res, "param") => {
            "action:id name:id type:enum(uint|bool|id|bytes|text|choice|code) kind:id? required:bool choice:id*"
        }
        (Family::Res, "normal") => "name:id value:bytes",
        (Family::Res, "invalid") => "name:id code:id text:text",
        (Family::Res, "review") => "action:id basis:hex64",
        (Family::Res, "row") => "kind:id key:bytes col:text*",
        (Family::Res, "progress") => "action:id done:uint total:uint unit:id? label:text?",
        (Family::Res, "message") => "level:enum(info|ok|warn|fail) text:text",
        (Family::Res, "overflow") => "suppressed:uint",
        (Family::Res, "result") => {
            "status:enum(done|refused|failed|cancelled|stopped|error) code:id text:text? next:text?"
        }
        (Family::Lock, "frontend") => {
            "version:id proto:uint source_commit:hex40 inputs_digest:hex64 rust:id"
        }
        (Family::Lock, "artifact") => {
            "target:id url:bytes size:uint sha256:hex64 minos:id? glibc_max:id? interp:bytes? needed:bytes* align_min:uint?"
        }
        (Family::Children, "child") => {
            "action:id cmd:bytes class:enum(read|mutating|handoff) stdout:enum(functional|diagnostics|null) stderr:enum(functional|diagnostics|null) tty:enum(none|needs) detaches:enum(no|owned) owner:text? check:id?"
        }
        (Family::Proc, "proc") => {
            "role:enum(launcher|frontend|core|worker) pid:uint start:text boot:bytes"
        }
        (Family::Op, "op") => {
            "action:id scope:$s basis:hex64 session:bytes state:enum(running|unsupervised) pid:uint start:text boot:bytes at:utc"
        }
        _ => return None,
    })
}

/// The cardinality columns, as in `lib/records.sh`: hello, snapshot,
/// detail, validate, execute.
pub fn card_column(family: Family, ty: &str) -> Option<&'static str> {
    Some(match (family, ty) {
        (Family::Req, "req") => "1 1 1 1 1",
        (Family::Req, "scope") => "- 1 - - -",
        (Family::Req, "page") => "- - 1 - -",
        (Family::Req, "select") => "- - - 1 -",
        (Family::Req, "exec") => "- - - - 1",
        (Family::Req, "arg") => "- - - * *",
        (Family::Res, "hello") | (Family::Res, "result") => "1 1 1 1 1",
        (Family::Res, "generation") => "- 1 1 - -",
        (Family::Res, "stage" | "fact" | "blocker" | "action" | "param") => "- * - - -",
        (Family::Res, "region" | "answer") => "- * - * -",
        (Family::Res, "guide" | "code") => "- * - - *",
        (Family::Res, "warning") => "- * - * *",
        (Family::Res, "normal" | "invalid") => "- - - * -",
        (Family::Res, "review") => "- - - ? -",
        (Family::Res, "row") => "- - * - -",
        (Family::Res, "progress") => "- - - - *",
        (Family::Res, "message") => "- * * * *",
        (Family::Res, "overflow") => "- ? ? ? ?",
        _ => return None,
    })
}

fn card(family: Family, op: Option<Op>, ty: &str) -> Option<char> {
    match (family, ty) {
        (Family::Lock, "frontend") | (Family::Proc, "proc") | (Family::Op, "op") => {
            return Some('1');
        }
        (Family::Lock, "artifact") => return Some('+'),
        (Family::Children, "child") => return Some('*'),
        _ => {}
    }
    let col = card_column(family, ty)?;
    let op = op?;
    col.split(' ')
        .nth(op.column())
        .and_then(|c| c.chars().next())
}

fn unique_keys(family: Family, ty: &str) -> &'static [&'static str] {
    match (family, ty) {
        (Family::Req, "arg") | (Family::Res, "normal" | "invalid" | "stage") => &["name"],
        (Family::Res, "action") => &["id"],
        (Family::Res, "param") => &["action", "name"],
        (Family::Lock, "artifact") => &["target"],
        (Family::Children, "child") => &["action"],
        _ => &[],
    }
}

/// Why a document was refused: the reason codes of docs/PROTOCOL.md → §2.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reason {
    Io,
    TooLarge,
    Byte,
    Eof,
    Line,
    Blank,
    Tab,
    Header,
    Key,
    Value,
    NulEscape,
    NonCanonical,
    Seal,
    Schema,
    Type,
    AfterResult,
    Result,
}

impl Reason {
    pub fn code(self) -> &'static str {
        match self {
            Reason::Io => "io",
            Reason::TooLarge => "too-large",
            Reason::Byte => "byte",
            Reason::Eof => "eof",
            Reason::Line => "line",
            Reason::Blank => "blank",
            Reason::Tab => "tab",
            Reason::Header => "header",
            Reason::Key => "key",
            Reason::Value => "value",
            Reason::NulEscape => "nul-escape",
            Reason::NonCanonical => "non-canonical",
            Reason::Seal => "seal",
            Reason::Schema => "schema",
            Reason::Type => "type",
            Reason::AfterResult => "after-result",
            Reason::Result => "result",
        }
    }
}

impl fmt::Display for Reason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.code())
    }
}

/// A refusal: the reason and the line it was found on (0 when it concerns
/// the whole document), as the Bash admission reports them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub reason: Reason,
    pub at: usize,
}

/// One admitted record: its type and its fields, values decoded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub ty: String,
    pub fields: Vec<(String, Vec<u8>)>,
}

impl Record {
    /// The first value of KEY.
    pub fn get(&self, key: &str) -> Option<&[u8]> {
        self.fields
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_slice())
    }
    /// The first value of KEY as text (admitted values of text, id and enum
    /// types are always valid UTF-8).
    pub fn text(&self, key: &str) -> Option<&str> {
        self.get(key).and_then(|v| std::str::from_utf8(v).ok())
    }
    /// Every value of a list KEY, in order.
    pub fn list(&self, key: &str) -> Vec<&[u8]> {
        self.fields
            .iter()
            .filter(|(k, _)| k == key)
            .map(|(_, v)| v.as_slice())
            .collect()
    }
}

/// An admitted document.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Document {
    pub op: Option<Op>,
    pub records: Vec<Record>,
}

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

fn safe(b: u8) -> bool {
    b.is_ascii_alphanumeric()
        || matches!(
            b,
            b'.' | b'_' | b'~' | b'/' | b':' | b'@' | b'+' | b',' | b'-'
        )
}

fn hexu(b: u8) -> bool {
    b.is_ascii_digit() || (b'A'..=b'F').contains(&b)
}

fn hexval(b: u8) -> u8 {
    match b {
        b'0'..=b'9' => b - b'0',
        b'A'..=b'F' => b - b'A' + 10,
        b'a'..=b'f' => b - b'a' + 10,
        _ => 0,
    }
}

/// The one canonical written form of a value.
pub fn encode(value: &[u8]) -> String {
    let mut out = String::with_capacity(value.len());
    for &b in value {
        if safe(b) {
            out.push(b as char);
        } else {
            out.push('%');
            out.push(char::from(b"0123456789ABCDEF"[(b >> 4) as usize]));
            out.push(char::from(b"0123456789ABCDEF"[(b & 15) as usize]));
        }
    }
    out
}

/// The decoded bytes of an admitted written value.
pub fn decode(written: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(written.len());
    let mut i = 0;
    while i < written.len() {
        if written[i] == b'%' && i + 2 < written.len() {
            out.push(hexval(written[i + 1]) << 4 | hexval(written[i + 2]));
            i += 3;
        } else {
            out.push(written[i]);
            i += 1;
        }
    }
    out
}

/// A record written in canonical form, with its LF.
pub fn line(ty: &str, fields: &[(&str, &[u8])]) -> String {
    let mut out = String::from(ty);
    for (k, v) in fields {
        out.push('\t');
        out.push_str(k);
        out.push('=');
        out.push_str(&encode(v));
    }
    out.push('\n');
    out
}

/// The one display function for `bytes` values: printable UTF-8 as itself,
/// every other byte as `\xNN`, then truncated to at most MAX characters with
/// a final `…` (docs/PROTOCOL.md → *Display versus data*). Never the raw
/// bytes: a control sequence in a file name is data, never display.
pub fn display(bytes: &[u8], max: usize) -> String {
    let mut out = String::new();
    let mut rest = bytes;
    while !rest.is_empty() {
        match std::str::from_utf8(rest) {
            Ok(s) => {
                push_printable(&mut out, s);
                break;
            }
            Err(e) => {
                let (good, bad) = rest.split_at(e.valid_up_to());
                // The prefix is valid UTF-8 by construction.
                push_printable(&mut out, std::str::from_utf8(good).unwrap_or(""));
                let n = e.error_len().unwrap_or(bad.len()).max(1);
                for b in &bad[..n] {
                    out.push_str(&format!("\\x{b:02x}"));
                }
                rest = &bad[n..];
            }
        }
    }
    if out.chars().count() > max {
        let keep = max.saturating_sub(1);
        out = out.chars().take(keep).collect();
        out.push('…');
    }
    out
}

fn push_printable(out: &mut String, s: &str) {
    for c in s.chars() {
        if c.is_control() || ('\u{80}'..='\u{9f}').contains(&c) {
            let mut buf = [0u8; 4];
            for b in c.encode_utf8(&mut buf).bytes() {
                out.push_str(&format!("\\x{b:02x}"));
            }
        } else {
            out.push(c);
        }
    }
}

fn text_ok(bytes: &[u8]) -> bool {
    match std::str::from_utf8(bytes) {
        Ok(s) => !s
            .chars()
            .any(|c| (c as u32) < 0x20 || c == '\u{7f}' || ('\u{80}'..='\u{9f}').contains(&c)),
        Err(_) => false,
    }
}

fn all(s: &[u8], f: impl Fn(u8) -> bool) -> bool {
    s.iter().all(|&b| f(b))
}

fn is_hex_lower(s: &[u8], n: usize) -> bool {
    s.len() == n && all(s, |b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn uint_ok(s: &[u8]) -> bool {
    s == b"0" || (!s.is_empty() && s.len() <= 18 && s[0] != b'0' && all(s, |b| b.is_ascii_digit()))
}

fn id_ok(s: &[u8]) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && (s[0].is_ascii_lowercase() || s[0].is_ascii_digit())
        && all(s, |b| {
            b.is_ascii_lowercase()
                || b.is_ascii_digit()
                || matches!(b, b'.' | b'_' | b':' | b'@' | b'+' | b'-')
        })
}

fn utc_ok(s: &[u8]) -> bool {
    let shape = b"0000-00-00T00:00:00Z";
    s.len() == shape.len()
        && s.iter().zip(shape.iter()).all(|(&b, &p)| {
            if p == b'0' {
                b.is_ascii_digit()
            } else {
                b == p
            }
        })
}

// The baseline's validators (lib/state.sh), used by the token's semantic
// check exactly as cfg_field_ok applies them.
const RESERVED_USERS: &[&str] = &[
    "root", "bin", "daemon", "sys", "adm", "mail", "ftp", "http", "nobody", "dbus", "alarm",
    "sddm", "polkitd", "rtkit", "avahi", "uuidd", "colord", "git",
];
const TOKEN_FIELDS: &[&str] = &[
    "enc", "user", "host", "kmap", "tz", "loc", "ssh", "gh", "linux", "shared", "dev", "plan",
    "prof",
];

fn username_ok(v: &str) -> bool {
    if RESERVED_USERS.contains(&v) || v.starts_with("systemd-") {
        return false;
    }
    let b = v.as_bytes();
    !b.is_empty()
        && b.len() <= 32
        && (b[0].is_ascii_lowercase() || b[0] == b'_')
        && all(b, |c| {
            c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_' || c == b'-'
        })
}

fn hostname_ok(v: &str) -> bool {
    let b = v.as_bytes();
    let alnum = |c: u8| c.is_ascii_alphanumeric();
    match b.len() {
        0 => false,
        1 => alnum(b[0]),
        n => {
            n <= 63
                && alnum(b[0])
                && alnum(b[n - 1])
                && all(&b[1..n - 1], |c| alnum(c) || c == b'-')
        }
    }
}

fn tz_part_ok(p: &[u8]) -> bool {
    !p.is_empty()
        && all(p, |c| {
            c.is_ascii_alphanumeric() || matches!(c, b'_' | b'+' | b'-')
        })
}

fn cfg_field_ok(k: &str, v: &str) -> bool {
    let b = v.as_bytes();
    match k {
        "enc" | "ssh" | "dev" => v == "0" || v == "1",
        "user" => username_ok(v),
        "host" => hostname_ok(v),
        "kmap" => {
            !b.is_empty()
                && b.len() <= 32
                && all(b, |c| {
                    c.is_ascii_alphanumeric() || matches!(c, b'_' | b'.' | b'-')
                })
        }
        "tz" => {
            let parts: Vec<&[u8]> = b.split(|&c| c == b'/').collect();
            parts.len() <= 3 && parts.iter().all(|p| tz_part_ok(p))
        }
        "loc" => {
            let Some(base) = v.strip_suffix(".UTF-8") else {
                return false;
            };
            let (lang, region) = match base.split_once('_') {
                Some((l, r)) => (l, Some(r)),
                None => (base, None),
            };
            (2..=3).contains(&lang.len())
                && lang.bytes().all(|c| c.is_ascii_lowercase())
                && region.is_none_or(|r| r.len() == 2 && r.bytes().all(|c| c.is_ascii_uppercase()))
        }
        "gh" => {
            v != "-"
                && (v.is_empty()
                    || (b.len() <= 39
                        && b[0].is_ascii_alphanumeric()
                        && all(b, |c| c.is_ascii_alphanumeric() || c == b'-')))
        }
        "linux" | "shared" => {
            v == "0"
                || (!b.is_empty() && b.len() <= 7 && b[0] != b'0' && all(b, |c| c.is_ascii_digit()))
        }
        "plan" | "prof" => is_hex_lower(b, 8),
        _ => false,
    }
}

fn check_digits(body: &str, check: &str) -> bool {
    let d = sha256_hex(body.as_bytes());
    d[..4] == *check
}

/// A decoded code of that kind: its grammar, then its semantic check
/// (docs/PROTOCOL.md → *Value types*, Codes).
pub fn code_ok(kind: &str, c: &str) -> bool {
    match kind {
        "token" => {
            let Some(body) = c.strip_prefix("omb2:") else {
                return false;
            };
            if body.is_empty()
                || body.starts_with(',')
                || body.ends_with(',')
                || body.contains(",,")
            {
                return false;
            }
            let mut seen: Vec<&str> = Vec::new();
            for pair in body.split(',') {
                let Some((k, v)) = pair.split_once('=') else {
                    return false;
                };
                if k.is_empty() || !k.bytes().all(|b| b.is_ascii_lowercase()) || v.contains('=') {
                    return false;
                }
                if seen.contains(&k) || !TOKEN_FIELDS.contains(&k) {
                    return false;
                }
                seen.push(k);
                if !cfg_field_ok(k, v) {
                    return false;
                }
            }
            true
        }
        "ombdone" | "ombshare" => {
            let parts: Vec<&str> = c.split('-').collect();
            parts.len() == 4
                && parts[0] == kind
                && is_hex_lower(parts[1].as_bytes(), 8)
                && is_hex_lower(parts[2].as_bytes(), 12)
                && is_hex_lower(parts[3].as_bytes(), 4)
                && check_digits(&c[..c.len() - 5], parts[3])
        }
        "ombbundle" => {
            let parts: Vec<&str> = c.split('-').collect();
            parts.len() == 3
                && parts[0] == "ombbundle"
                && is_hex_lower(parts[1].as_bytes(), 16)
                && is_hex_lower(parts[2].as_bytes(), 4)
                && check_digits(&c[..c.len() - 5], parts[2])
        }
        _ => false,
    }
}

fn expand(t: &str) -> String {
    t.replace("$s", &format!("enum({SCOPES})"))
        .replace("$REC_STAGES", STAGES)
}

/// A non-empty written value of that type (KIND: the record's code kind).
fn type_ok(ty: &str, v: &[u8], kind: &[u8]) -> bool {
    match ty {
        "uint" => uint_ok(v),
        "bool" => v == b"0" || v == b"1",
        "id" => id_ok(v),
        "hex8" => is_hex_lower(v, 8),
        "hex16" => is_hex_lower(v, 16),
        "hex40" => is_hex_lower(v, 40),
        "hex64" => is_hex_lower(v, 64),
        "utc" => utc_ok(v),
        "text" => text_ok(&decode(v)),
        "bytes" => true,
        "code" => {
            let d = decode(v);
            if d.len() > CODE_MAX || !all(&d, |b| (0x20..=0x7e).contains(&b)) {
                return false;
            }
            let (Ok(kind), Ok(d)) = (std::str::from_utf8(kind), std::str::from_utf8(&d)) else {
                return false;
            };
            code_ok(kind, d)
        }
        _ => {
            if let Some(list) = ty.strip_prefix("enum(").and_then(|r| r.strip_suffix(')')) {
                list.split('|').any(|w| w.as_bytes() == v)
            } else {
                false
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Admission
// ---------------------------------------------------------------------------

/// Step 5 over one complete line (LF excluded), line number NO.
fn frame(family: Family, no: usize, line: &[u8]) -> Option<Reason> {
    if line.len() > LINE_MAX {
        return Some(Reason::Line);
    }
    if line.is_empty() {
        return Some(Reason::Blank);
    }
    if line[0] == b'\t' || line[line.len() - 1] == b'\t' || line.windows(2).any(|w| w == b"\t\t") {
        return Some(Reason::Tab);
    }
    if no == 1 {
        return (line != family.header().as_bytes()).then_some(Reason::Header);
    }
    let parts: Vec<&[u8]> = line.split(|&b| b == b'\t').collect();
    let ty = parts[0];
    if parts.len() < 2
        || ty.is_empty()
        || ty.len() > 24
        || !ty[0].is_ascii_lowercase()
        || !all(ty, |b| b.is_ascii_lowercase() || b == b'-')
    {
        return Some(Reason::Key);
    }
    let mut values = Vec::with_capacity(parts.len() - 1);
    for f in &parts[1..] {
        let Some(p) = f.iter().position(|&b| b == b'=') else {
            return Some(Reason::Key);
        };
        let k = &f[..p];
        if k.is_empty()
            || k.len() > 32
            || !k[0].is_ascii_lowercase()
            || !all(k, |b| {
                b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_'
            })
        {
            return Some(Reason::Key);
        }
        values.push(&f[p + 1..]);
    }
    for v in &values {
        if v.len() > VALUE_MAX || !value_grammar(v) {
            return Some(Reason::Value);
        }
    }
    for v in &values {
        if v.windows(3).any(|w| w == b"%00") {
            return Some(Reason::NulEscape);
        }
    }
    for v in &values {
        let mut i = 0;
        while i < v.len() {
            if v[i] == b'%' {
                if safe(hexval(v[i + 1]) << 4 | hexval(v[i + 2])) {
                    return Some(Reason::NonCanonical);
                }
                i += 3;
            } else {
                i += 1;
            }
        }
    }
    let max = family.max_records();
    if max > 0 && no - 1 > max {
        return Some(Reason::TooLarge);
    }
    None
}

fn value_grammar(v: &[u8]) -> bool {
    let mut i = 0;
    while i < v.len() {
        if v[i] == b'%' {
            if i + 2 >= v.len() {
                return false;
            }
            if !hexu(v[i + 1]) || !hexu(v[i + 2]) {
                return false;
            }
            i += 3;
        } else if safe(v[i]) {
            i += 1;
        } else {
            return false;
        }
    }
    true
}

/// Step 6: the schema, one record at a time.
struct Schema {
    family: Family,
    op: Option<Op>,
    n: usize,
    lastidx: usize,
    result: bool,
    counts: Vec<usize>,
    seen: Vec<Vec<Vec<u8>>>,
}

impl Schema {
    fn new(family: Family, op: Option<Op>) -> Schema {
        let k = family.order().len();
        Schema {
            family,
            op,
            n: 0,
            lastidx: 0,
            result: false,
            counts: vec![0; k],
            seen: vec![Vec::new(); k],
        }
    }

    fn record(&mut self, no: usize, line: &[u8]) -> Result<Record, Refusal> {
        let refuse = |reason| Err(Refusal { reason, at: no });
        let parts: Vec<&[u8]> = line.split(|&b| b == b'\t').collect();
        let ty = std::str::from_utf8(parts[0]).unwrap_or("");
        if self.family == Family::Req && self.n == 0 {
            if ty != "req" || !parts[1].starts_with(b"op=") {
                return refuse(Reason::Schema);
            }
            match std::str::from_utf8(&parts[1][3..]).ok().and_then(Op::parse) {
                Some(op) => self.op = Some(op),
                None => return refuse(Reason::Type),
            }
        }
        if self.family == Family::Res && self.result {
            return refuse(if ty == "result" {
                Reason::Result
            } else {
                Reason::AfterResult
            });
        }
        let order = self.family.order();
        let Some(idx) = order.iter().position(|t| *t == ty).map(|i| i + 1) else {
            return refuse(Reason::Schema);
        };
        if idx < self.lastidx {
            return refuse(Reason::Schema);
        }
        self.lastidx = idx;
        let Some(c) = card(self.family, self.op, ty) else {
            return refuse(Reason::Schema);
        };
        let count = self.counts[idx - 1];
        match c {
            '-' => return refuse(Reason::Schema),
            '1' | '?' if count > 0 => return refuse(Reason::Schema),
            _ => {}
        }
        let fields = match self.fields(ty, &parts[1..]) {
            Ok(f) => f,
            Err(r) => return refuse(r),
        };
        // Bounds the schema states in words.
        match (self.family, ty) {
            (Family::Req, "page") => {
                let lim: u64 = raw(&parts[1..], "limit")
                    .and_then(|v| std::str::from_utf8(v).ok()?.parse().ok())
                    .unwrap_or(0);
                if !(1..=500).contains(&lim) {
                    return refuse(Reason::Type);
                }
            }
            (Family::Req, "arg") if count >= 64 => return refuse(Reason::Schema),
            _ => {}
        }
        let keys = unique_keys(self.family, ty);
        if !keys.is_empty() {
            let mut key = Vec::new();
            for k in keys {
                key.extend_from_slice(raw(&parts[1..], k).unwrap_or(b""));
                key.push(b'/');
            }
            if self.seen[idx - 1].contains(&key) {
                return refuse(Reason::Schema);
            }
            self.seen[idx - 1].push(key);
        }
        self.counts[idx - 1] += 1;
        self.n += 1;
        if ty == "result" {
            self.result = true;
        }
        Ok(Record {
            ty: ty.to_string(),
            fields,
        })
    }

    fn fields(&self, ty: &str, flds: &[&[u8]]) -> Result<Vec<(String, Vec<u8>)>, Reason> {
        let spec = expand(spec(self.family, ty).ok_or(Reason::Schema)?);
        let split: Vec<(&[u8], &[u8])> = flds
            .iter()
            .map(|f| {
                let p = f.iter().position(|&b| b == b'=').unwrap_or(f.len());
                (&f[..p], f.get(p + 1..).unwrap_or(b""))
            })
            .collect();
        let mut out = Vec::with_capacity(split.len());
        let mut i = 0;
        let mut kind: &[u8] = b"";
        for s in spec.split(' ') {
            let (name, mut ty) = s.split_once(':').unwrap_or((s, ""));
            let m = match ty.as_bytes().last() {
                Some(b'?') | Some(b'*') | Some(b'+') => {
                    let m = ty.as_bytes()[ty.len() - 1];
                    ty = &ty[..ty.len() - 1];
                    m
                }
                _ => 0,
            };
            match m {
                b'*' | b'+' => {
                    let mut c = 0;
                    while i < split.len() && split[i].0 == name.as_bytes() {
                        let v = split[i].1;
                        if v.is_empty() {
                            if ty != "bytes" && ty != "text" {
                                return Err(Reason::Type);
                            }
                        } else if !type_ok(ty, v, kind) {
                            return Err(Reason::Type);
                        }
                        out.push((name.to_string(), decode(v)));
                        c += 1;
                        i += 1;
                    }
                    if m == b'+' && c == 0 {
                        return Err(Reason::Schema);
                    }
                }
                _ => {
                    if i >= split.len() || split[i].0 != name.as_bytes() {
                        return Err(Reason::Schema);
                    }
                    let v = split[i].1;
                    if v.is_empty() {
                        if m != b'?' {
                            return Err(Reason::Schema);
                        }
                    } else if !type_ok(ty, v, kind) {
                        return Err(Reason::Type);
                    }
                    if name == "kind" {
                        kind = v;
                    }
                    out.push((name.to_string(), decode(v)));
                    i += 1;
                }
            }
        }
        if i != split.len() {
            return Err(Reason::Schema);
        }
        Ok(out)
    }

    fn end(&self) -> Result<(), Refusal> {
        if self.family == Family::Res && !self.result {
            return Err(Refusal {
                reason: Reason::Result,
                at: 0,
            });
        }
        for (i, ty) in self.family.order().iter().enumerate() {
            if let Some('1' | '+') = card(self.family, self.op, ty)
                && self.counts[i] == 0
            {
                return Err(Refusal {
                    reason: Reason::Schema,
                    at: 0,
                });
            }
        }
        Ok(())
    }
}

fn raw<'a>(flds: &[&'a [u8]], key: &str) -> Option<&'a [u8]> {
    flds.iter().find_map(|f| {
        let p = f.iter().position(|&b| b == b'=')?;
        (&f[..p] == key.as_bytes()).then(|| &f[p + 1..])
    })
}

/// Admission of a document that arrives in pieces. [`Admitter::push`] hands
/// back each complete line that is admitted so far (provisional: a later
/// byte can still refuse the document); [`Admitter::finish`] gives the
/// verdict, the same as the Bash admission's over the whole document.
pub struct Admitter {
    family: Family,
    total: usize,
    byte_bad: bool,
    last: Option<u8>,
    partial: Vec<u8>,
    no: usize,
    frame_fail: Option<Refusal>,
    schema_fail: Option<Refusal>,
    schema: Schema,
    records: Vec<Record>,
    /// A sealed family is judged whole at the end (its last line is the seal).
    whole: Vec<u8>,
}

impl Admitter {
    /// OP: the operation a response answers (a request names its own).
    pub fn new(family: Family, op: Option<Op>) -> Admitter {
        Admitter {
            family,
            total: 0,
            byte_bad: false,
            last: None,
            partial: Vec::new(),
            no: 0,
            frame_fail: None,
            schema_fail: None,
            schema: Schema::new(family, op),
            records: Vec::new(),
            whole: Vec::new(),
        }
    }

    fn too_large(&self) -> bool {
        self.total > self.family.max_bytes()
    }

    /// Consumes more bytes; returns the records admitted so far by this push.
    pub fn push(&mut self, bytes: &[u8]) -> Vec<Record> {
        let before = self.records.len();
        let room = (self.family.max_bytes() + 1).saturating_sub(self.total);
        // Like `head -c LIMIT+1`: nothing past the limit's first byte is kept.
        let take = &bytes[..bytes.len().min(room)];
        self.total += bytes.len();
        if take.is_empty() {
            return Vec::new();
        }
        self.last = take.last().copied();
        for &b in take {
            if !(b == b'\t' || b == b'\n' || (0x20..=0x7e).contains(&b)) {
                self.byte_bad = true;
            }
        }
        if self.family.sealed() {
            self.whole.extend_from_slice(take);
        }
        let mut start = 0;
        for (i, &b) in take.iter().enumerate() {
            if b == b'\n' {
                self.partial.extend_from_slice(&take[start..i]);
                let line = std::mem::take(&mut self.partial);
                self.line(&line);
                start = i + 1;
            }
        }
        self.partial.extend_from_slice(&take[start..]);
        self.records[before..].to_vec()
    }

    fn line(&mut self, line: &[u8]) {
        self.no += 1;
        if self.frame_fail.is_some() || self.byte_bad {
            return;
        }
        if let Some(reason) = frame(self.family, self.no, line) {
            self.frame_fail = Some(Refusal {
                reason,
                at: self.no,
            });
            return;
        }
        // Sealed families are held to their schema at the end, when the
        // seal line is known; the header is framing only.
        if self.no == 1 || self.family.sealed() || self.schema_fail.is_some() {
            return;
        }
        match self.schema.record(self.no, line) {
            Ok(r) => self.records.push(r),
            Err(f) => self.schema_fail = Some(f),
        }
    }

    /// The verdict over everything pushed.
    pub fn finish(mut self) -> Result<Document, Refusal> {
        let whole = |reason| Err(Refusal { reason, at: 0 });
        if self.too_large() {
            return whole(Reason::TooLarge);
        }
        if self.byte_bad {
            return whole(Reason::Byte);
        }
        if self.last != Some(b'\n') {
            return whole(Reason::Eof);
        }
        if let Some(f) = self.frame_fail {
            return Err(f);
        }
        if self.family.sealed() {
            let doc = std::mem::take(&mut self.whole);
            return self.finish_sealed(&doc);
        }
        if let Some(f) = self.schema_fail {
            return Err(f);
        }
        self.schema.end()?;
        Ok(Document {
            op: self.schema.op,
            records: self.records,
        })
    }

    fn finish_sealed(mut self, doc: &[u8]) -> Result<Document, Refusal> {
        let seal = Err(Refusal {
            reason: Reason::Seal,
            at: 0,
        });
        let lines: Vec<&[u8]> = doc[..doc.len() - 1].split(|&b| b == b'\n').collect();
        let seals = lines.iter().filter(|l| l.starts_with(b"seal\t")).count();
        let last = lines[lines.len() - 1];
        if seals != 1 || !last.starts_with(SEAL_PREFIX) {
            return seal;
        }
        let digest = &last[SEAL_PREFIX.len()..];
        let body = &doc[..doc.len() - last.len() - 1];
        if !is_hex_lower(digest, 64) || sha256_hex(body).as_bytes() != digest {
            return seal;
        }
        for (i, l) in lines.iter().enumerate().take(lines.len() - 1).skip(1) {
            match self.schema.record(i + 1, l) {
                Ok(r) => self.records.push(r),
                Err(f) => return Err(f),
            }
        }
        self.schema.end()?;
        Ok(Document {
            op: self.schema.op,
            records: self.records,
        })
    }
}

/// Admits a whole document.
pub fn admit(family: Family, op: Option<Op>, bytes: &[u8]) -> Result<Document, Refusal> {
    let mut a = Admitter::new(family, op);
    a.push(bytes);
    a.finish()
}

// ---------------------------------------------------------------------------
// SHA-256 (FIPS 180-4), for the codes' check digits and the seals.
// ---------------------------------------------------------------------------

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// The SHA-256 of DATA.
pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    let mut msg = data.to_vec();
    let bits = (data.len() as u64).wrapping_mul(8);
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bits.to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for (i, word) in chunk.chunks(4).enumerate() {
            w[i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(t1);
            d = c;
            c = b;
            b = a;
            a = t1.wrapping_add(t2);
        }
        for (x, y) in h.iter_mut().zip([a, b, c, d, e, f, g, hh]) {
            *x = x.wrapping_add(y);
        }
    }
    let mut out = [0u8; 32];
    for (i, x) in h.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&x.to_be_bytes());
    }
    out
}

/// The SHA-256 of DATA in lower-case hex.
pub fn sha256_hex(data: &[u8]) -> String {
    sha256(data).iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_vectors() {
        // FIPS 180-4 examples.
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
        assert_eq!(
            sha256_hex(&vec![b'a'; 1_000_000]),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        );
    }

    #[test]
    fn encode_is_canonical_and_round_trips() {
        assert_eq!(encode(b"safe-._~/:@+,Az09"), "safe-._~/:@+,Az09");
        assert_eq!(encode("a b=%é".as_bytes()), "a%20b%3D%25%C3%A9");
        let all: Vec<u8> = (1..=255).collect();
        assert_eq!(decode(encode(&all).as_bytes()), all);
    }

    #[test]
    fn display_never_emits_control_bytes() {
        assert_eq!(display(b"x\x1b[2J", 40), "x\\x1b[2J");
        assert_eq!(
            display("caf\u{e9}\u{85}".as_bytes(), 40),
            "caf\u{e9}\\xc2\\x85"
        );
        assert_eq!(display(b"\xff\xfeok", 40), "\\xff\\xfeok");
        assert_eq!(display(b"abcdefgh", 5), "abcd…");
    }

    #[test]
    fn codes_follow_the_baseline_rules() {
        assert!(code_ok("ombdone", "ombdone-1a2b3c4d-8f2a41c0e9b7-f5f0"));
        assert!(!code_ok("ombdone", "ombdone-1a2b3c4d-8f2a41c0e9b7-f5f1"));
        assert!(code_ok("ombshare", "ombshare-1a2b3c4d-3c1f9e2d7a60-4149"));
        assert!(code_ok("ombbundle", "ombbundle-3f09c2a1b7d45e60-26d1"));
        assert!(!code_ok("ombshare", "ombdone-1a2b3c4d-8f2a41c0e9b7-f5f0"));
        assert!(code_ok("token", "omb2:enc=1,user=alex,prof=3f09c2a1"));
        assert!(!code_ok("token", "omb2:user=root"));
        assert!(!code_ok("token", "omb2:enc=1,enc=0"));
        assert!(!code_ok("token", "omb1:enc=1"));
        assert!(code_ok("token", "omb2:gh="));
        assert!(!code_ok("token", "omb2:gh=-"));
        assert!(code_ok("token", "omb2:loc=en_US.UTF-8,tz=America/New_York"));
        assert!(!code_ok("token", "omb2:tz=a/b/c/d"));
        assert!(!code_ok("token", "omb2:linux=0250"));
    }
}
