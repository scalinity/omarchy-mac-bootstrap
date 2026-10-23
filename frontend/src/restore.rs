//! Restore choices are local until validation and the typed Gate. Destinations
//! stay byte for byte as the core's conflict keys; rendered paths never become
//! arguments. An omitted destination is kept.

use crate::read::{Args, Checked, Row};
use crate::{record, select};
use std::cell::Cell;

#[derive(Debug, Default)]
pub struct Restore {
    /// The newest checked bundle's exact key, as the core ordered it.
    pub bundle: Vec<u8>,
    pub replacements: Vec<Vec<u8>>,
    pub conflict: usize,
    pub side_by_side: bool,
    pub side_visible: Cell<bool>,
    pub side_scroll: usize,
    /// Wrapped lines in the unified view; drawing bounds End to the page.
    pub line_scroll: Cell<usize>,
    pub checked: Option<Checked>,
    pub action: usize,
}

pub fn replacing(choices: &[Vec<u8>], dest: &[u8]) -> bool {
    choices.iter().any(|d| d == dest)
}

pub fn diff_rows<'a>(rows: &'a [Row], dest: &[u8]) -> Vec<&'a Row> {
    rows.iter()
        .filter(|r| {
            r.id.iter()
                .rposition(|b| *b == b'#')
                .is_some_and(|at| &r.id[..at] == dest)
        })
        .collect()
}

pub fn choose(choices: &mut Vec<Vec<u8>>, dest: &[u8], replace: bool) {
    choices.retain(|d| d != dest);
    if replace {
        choices.push(dest.to_vec());
    }
}

/// One document, in the core's conflict order, with no duplicate destinations.
pub fn document(rows: &[Row], choices: &[Vec<u8>]) -> String {
    let mut out = String::from("omb-replace 1\n");
    let mut seen: Vec<&[u8]> = Vec::new();
    for r in rows {
        if replacing(choices, &r.id) && !seen.contains(&r.id.as_slice()) {
            out.push_str(&record::line("replace", &[("dest", &r.id)]));
            seen.push(&r.id);
        }
    }
    out
}

/// Exactly the profile document's line-end and encoded argument bounds.
pub fn split(doc: &str) -> Option<Args> {
    select::split(doc).map(|parts| {
        parts
            .into_iter()
            .enumerate()
            .map(|(i, (_, bytes))| (format!("replace.{}", i + 1), bytes))
            .collect()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::Req;
    use crate::core::Session;
    use crate::record::{Family, admit};

    fn row(dest: Vec<u8>) -> Row {
        Row {
            key: record::display(&dest, 8192),
            id: dest,
            cols: vec![],
        }
    }

    #[test]
    fn keeps_are_omitted_and_destination_bytes_are_preserved() {
        let rows = [
            row(b".config/a b%#\xff".to_vec()),
            row(b".config/keep".to_vec()),
        ];
        let mut choices = Vec::new();
        assert_eq!(document(&rows, &choices), "omb-replace 1\n");
        choose(&mut choices, &rows[0].id, true);
        choose(&mut choices, &rows[0].id, true);
        assert_eq!(
            document(&rows, &choices),
            "omb-replace 1\nreplace\tdest=.config/a%20b%25%23%FF\n"
        );
        choose(&mut choices, &rows[0].id, false);
        assert_eq!(document(&rows, &choices), "omb-replace 1\n");
    }

    #[test]
    fn replacement_parts_fit_rejoin_and_form_an_admissible_core_request() {
        let rows: Vec<_> = (0..500)
            .map(|i| row(format!(".config/tool number {i:04}").into_bytes()))
            .collect();
        let choices: Vec<_> = rows.iter().map(|r| r.id.clone()).collect();
        let doc = document(&rows, &choices);
        let args = split(&doc).expect("fits");
        assert!(args.len() > 1 && args.len() <= select::PARTS);
        let mut joined = Vec::new();
        for (i, (name, value)) in args.iter().enumerate() {
            assert_eq!(*name, format!("replace.{}", i + 1));
            assert!(record::encode(value).len() <= select::PART_MAX);
            assert_eq!(value.last(), Some(&b'\n'));
            joined.extend_from_slice(value);
        }
        assert_eq!(joined, doc.as_bytes());
        let mut session = Session::new("/nonexistent/s".into(), "/nonexistent".into(), true);
        session.id = "0123456789abcdef".into();
        let req = Req::Validate {
            action: "restore.apply".into(),
            args,
        };
        assert!(admit(Family::Req, None, &session.request(&req)).is_ok());
        assert!(
            split(&"x".repeat(select::PART_MAX + 1)).is_none(),
            "a line is never cut"
        );
        assert!(
            split(&"x\n".repeat(select::DOC_MAX)).is_none(),
            "document ceiling"
        );
        let many = format!(
            "omb-replace 1\n{}",
            "replace\tdest=long path with many spaces\n".repeat(1500)
        );
        assert!(many.len() < select::DOC_MAX);
        assert!(split(&many).is_none(), "encoded parts ceiling");
    }
}
