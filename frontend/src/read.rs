//! The Gate 2 read surface as the frontend holds it (docs/PROTOCOL.md → *The
//! Gate 2 read surface*): the scopes and detail kinds it presents, one page
//! of a detail at a time with the generation it came from, and the core's own
//! words when a read is refused or fails. Nothing here decides what a value
//! means: generations are compared for equality only, and a row's columns are
//! kept in the order the core sent them.

use crate::record::{self, Record};
use std::cell::Cell;

/// The read scopes the frontend presents.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    Journey,
    Health,
    Logs,
}

impl Scope {
    pub fn name(self) -> &'static str {
        match self {
            Scope::Journey => "journey",
            Scope::Health => "health",
            Scope::Logs => "logs",
        }
    }
}

/// The detail kinds: each pages a projection of its scope's data set and
/// shares that snapshot's generation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Machine,
    Status,
    Doctor,
    Log,
}

impl Kind {
    pub const ALL: [Kind; 4] = [Kind::Machine, Kind::Status, Kind::Doctor, Kind::Log];

    pub fn scope(self) -> Scope {
        match self {
            Kind::Machine | Kind::Status => Scope::Journey,
            Kind::Doctor => Scope::Health,
            Kind::Log => Scope::Logs,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Kind::Machine => "machine",
            Kind::Status => "status",
            Kind::Doctor => "doctor",
            Kind::Log => "log",
        }
    }

    pub fn index(self) -> usize {
        self as usize
    }

    /// What the status line says while a page of this kind is read.
    pub fn reading(self) -> &'static str {
        match self {
            Kind::Machine => "reading machine details",
            Kind::Status => "reading status details",
            Kind::Doctor => "reading health findings",
            Kind::Log => "reading log lines",
        }
    }
}

/// The rows the frontend asks for in one page: the most a detail answer may
/// carry (docs/PROTOCOL.md → *Request schemas*), so a whole log window — the
/// accepted 40 lines — always arrives in one answer.
pub const LIMIT: u64 = 500;

/// One page request: the kind, the generation of the snapshot it was opened
/// from, and the rows asked for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Page {
    pub kind: Kind,
    pub generation: String,
    pub offset: u64,
    pub limit: u64,
}

/// One row of a page: its key and its columns, as the core sent them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub key: String,
    pub cols: Vec<String>,
}

impl Row {
    pub fn col(&self, i: usize) -> &str {
        self.cols.get(i).map_or("", String::as_str)
    }
}

/// Why a view holds no current answer. Each keeps its meaning: a refusal or
/// an error is the core's own status, code and text; no answer is never a
/// negative finding.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Fault {
    /// The core answered `refused` or `error`.
    Said {
        status: String,
        code: String,
        text: String,
    },
    /// The core stopped without a complete answer.
    NoAnswer(String),
    /// The request never reached a core: nothing ran.
    NotSent(String),
}

/// Where the cursor lands when the page asked for arrives.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Land {
    First,
    Last,
}

/// An open detail: the one page shown, from the generation it was opened
/// from. Rows of two generations are never mixed: a page from another
/// generation is refused by the core and marks the view changed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Detail {
    pub kind: Kind,
    /// The generation the rows shown came from (before the first page, the
    /// one it was opened from).
    pub generation: String,
    pub offset: u64,
    pub total: u64,
    pub rows: Vec<Row>,
    /// A page has been admitted.
    pub loaded: bool,
    /// The core holds another generation now: shown as changed until it is
    /// reopened from a fresh snapshot.
    pub changed: bool,
    pub fault: Option<Fault>,
    /// The focused row among those shown.
    pub cursor: usize,
    /// The local filter over the loaded page, and whether it has the keys.
    pub filter: String,
    pub editing: bool,
    /// Logs only: show lines of this level alone.
    pub level: Option<String>,
    /// The focused row's full values, wrapped; while open, the moving keys
    /// scroll them instead of the rows.
    pub open: bool,
    /// The first line of the open values shown. Only the frame knows the
    /// width they wrap at and the room under the row, so it keeps this within
    /// them as it draws — as a stateful widget keeps its offset — and the
    /// keys move it from where the last frame left it.
    pub value_top: Cell<usize>,
    pub land: Land,
}

impl Detail {
    pub fn new(kind: Kind, generation: &str) -> Detail {
        Detail {
            kind,
            generation: generation.to_string(),
            offset: 0,
            total: 0,
            rows: Vec::new(),
            loaded: false,
            changed: false,
            fault: None,
            cursor: 0,
            filter: String::new(),
            editing: false,
            level: None,
            open: false,
            value_top: Cell::new(0),
            land: Land::First,
        }
    }

    /// The rows shown: the loaded page through the filter and the level.
    /// Local only: no row is ever fetched for a filter.
    pub fn shown(&self) -> Vec<&Row> {
        let needle = self.filter.to_lowercase();
        self.rows
            .iter()
            .filter(|r| {
                self.level
                    .as_ref()
                    .is_none_or(|l| self.kind == Kind::Log && r.col(1) == l)
            })
            .filter(|r| {
                needle.is_empty() || r.cols.iter().any(|c| c.to_lowercase().contains(&needle))
            })
            .collect()
    }

    /// The levels in the loaded page, in the order they first appear.
    pub fn levels(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for r in &self.rows {
            let l = r.col(1);
            if !l.is_empty() && !out.iter().any(|x| x == l) {
                out.push(l.to_string());
            }
        }
        out
    }

    /// The page after this one, from the same generation, if the core holds
    /// more rows than this page reaches.
    pub fn next(&self, limit: u64) -> Option<Page> {
        let end = self.offset + self.rows.len() as u64;
        (self.loaded && end < self.total).then(|| self.page(end, limit))
    }

    /// The page before this one.
    pub fn prev(&self, limit: u64) -> Option<Page> {
        (self.loaded && self.offset > 0)
            .then(|| self.page(self.offset.saturating_sub(limit), limit))
    }

    /// The first page, when another is shown.
    pub fn first(&self, limit: u64) -> Option<Page> {
        (self.loaded && self.offset > 0).then(|| self.page(0, limit))
    }

    /// The last page, when another is shown.
    pub fn last(&self, limit: u64) -> Option<Page> {
        let at = self.total.saturating_sub(1) / limit * limit;
        (self.loaded && self.total > 0 && at != self.offset).then(|| self.page(at, limit))
    }

    pub fn page(&self, offset: u64, limit: u64) -> Page {
        Page {
            kind: self.kind,
            generation: self.generation.clone(),
            offset,
            limit,
        }
    }
}

/// A plan check as the core answered it (docs/PROTOCOL.md → *Future plan
/// validation contract*): the inputs sent and every record of the answer,
/// shown as they came. It is never a saved plan and grants nothing.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Checked {
    pub linux: String,
    pub shared: String,
    pub status: String,
    pub code: String,
    pub text: String,
    /// The installer's questions and what to type: prompt, value, bytes.
    pub answers: Vec<(String, String, String)>,
    /// Each size as the core normalised it, in bytes.
    pub normals: Vec<(String, String)>,
    /// Name, code and text of a refused parameter.
    pub invalid: Vec<(String, String, String)>,
    /// Id, text and fix.
    pub warnings: Vec<(String, String, String)>,
    /// Level and text.
    pub messages: Vec<(String, String)>,
    /// The review basis, when every parameter was valid.
    pub basis: Option<String>,
}

fn field(r: &Record, k: &str) -> String {
    r.get(k)
        .map(|b| record::display(b, 8192))
        .unwrap_or_default()
}

impl Checked {
    pub fn of(records: &[Record], linux: &str, shared: &str) -> Checked {
        let mut c = Checked {
            linux: linux.to_string(),
            shared: shared.to_string(),
            ..Checked::default()
        };
        for r in records {
            match r.ty.as_str() {
                "answer" => {
                    c.answers
                        .push((field(r, "prompt"), field(r, "value"), field(r, "bytes")))
                }
                "normal" => c.normals.push((field(r, "name"), field(r, "value"))),
                "invalid" => c
                    .invalid
                    .push((field(r, "name"), field(r, "code"), field(r, "text"))),
                "warning" => c
                    .warnings
                    .push((field(r, "id"), field(r, "text"), field(r, "fix"))),
                "message" => c.messages.push((field(r, "level"), field(r, "text"))),
                "review" => c.basis = Some(field(r, "basis")),
                "result" => {
                    c.status = field(r, "status");
                    c.code = field(r, "code");
                    c.text = field(r, "text");
                }
                _ => {}
            }
        }
        c
    }
}

/// The generation record of an answer: its id and total.
pub fn generation(records: &[Record]) -> Option<(String, u64)> {
    let r = records.iter().find(|r| r.ty == "generation")?;
    let total = r.text("total").and_then(|t| t.parse().ok()).unwrap_or(0);
    Some((r.text("id").unwrap_or("").to_string(), total))
}

/// The rows of KIND in an answer, in the order the core sent them.
pub fn rows(records: &[Record], kind: Kind) -> Vec<Row> {
    records
        .iter()
        .filter(|r| r.ty == "row" && r.text("kind") == Some(kind.name()))
        .map(|r| Row {
            key: field(r, "key"),
            cols: r
                .list("col")
                .into_iter()
                .map(|c| record::display(c, 8192))
                .collect(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn loaded(offset: u64, n: usize, total: u64) -> Detail {
        let mut d = Detail::new(Kind::Status, &"ab".repeat(32));
        d.offset = offset;
        d.total = total;
        d.loaded = true;
        d.rows = (0..n)
            .map(|i| Row {
                key: i.to_string(),
                cols: vec![],
            })
            .collect();
        d
    }

    #[test]
    fn pages_step_by_the_rows_read_and_keep_the_generation() {
        let d = loaded(0, 500, 812);
        let n = d.next(500).unwrap();
        assert_eq!((n.offset, n.limit), (500, 500));
        assert_eq!(n.generation, d.generation);
        assert_eq!(d.prev(500), None);
        assert_eq!(d.last(500).unwrap().offset, 500);
        let d = loaded(500, 312, 812);
        assert_eq!(d.next(500), None, "the end of the data set");
        assert_eq!(d.prev(500).unwrap().offset, 0);
        assert_eq!(d.first(500).unwrap().offset, 0);
        assert_eq!(d.last(500), None, "already the last page");
        // Nothing pages before a page has been admitted.
        assert_eq!(Detail::new(Kind::Log, "x").next(500), None);
        assert_eq!(loaded(0, 0, 0).last(500), None);
    }
}
