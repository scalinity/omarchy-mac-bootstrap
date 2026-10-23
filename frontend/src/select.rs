//! The person's migration choices as they travel (docs/MIGRATION.md → *On
//! the wire*): one `omb-select 1` document of `select` and `decision`
//! records, only the choices that differ from the defaults, split at line
//! ends into the arguments `select.1` … `select.14`. The core joins them,
//! admits the whole and judges every id; nothing here decides what a choice
//! means.

use crate::read::{Args, Row};
use crate::record;

/// The most a document may be (the `select` family's limit).
pub const DOC_MAX: usize = 61_440;
/// The most argument parts, and the most each may be as written.
pub const PARTS: usize = 14;
pub const PART_MAX: usize = 4096;

/// One item's choice, made in this session: its id, byte for byte; the
/// state the person set, if any; the decision the person picked, if any.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pick {
    pub id: Vec<u8>,
    pub state: Option<String>,
    pub decision: Option<(String, Vec<u8>)>,
}

/// The items row's columns this module reads (docs/MIGRATION.md → `items`).
pub const COL_STATE: usize = 5;
pub const COL_BY: usize = 7;

/// The state shown for ROW: the person's choice in this session, or the
/// core's.
pub fn state<'a>(row: &'a Row, picks: &'a [Pick]) -> &'a str {
    picks
        .iter()
        .find(|p| p.id == row.id)
        .and_then(|p| p.state.as_deref())
        .unwrap_or(row.col(COL_STATE))
}

/// Set ROW's state to STATE in PICKS: a choice equal to the core's default
/// is no choice at all, so it is dropped again.
pub fn set_state(picks: &mut Vec<Pick>, row: &Row, state: &str) {
    let default = row.col(COL_BY) != "person" && row.col(COL_STATE) == state;
    match picks.iter().position(|p| p.id == row.id) {
        Some(i) => {
            picks[i].state = (!default).then(|| state.to_string());
            if picks[i].state.is_none() && picks[i].decision.is_none() {
                picks.remove(i);
            }
        }
        None if !default => picks.push(Pick {
            id: row.id.clone(),
            state: Some(state.to_string()),
            decision: None,
        }),
        None => {}
    }
}

/// Set ROW's decision to CHOICE in PICKS.
pub fn set_decision(picks: &mut Vec<Pick>, row: &Row, choice: &str) {
    let d = Some((choice.to_string(), Vec::new()));
    match picks.iter_mut().find(|p| p.id == row.id) {
        Some(p) => p.decision = d,
        None => picks.push(Pick {
            id: row.id.clone(),
            state: None,
            decision: d,
        }),
    }
}

/// The document: a `select` record for every item whose state the person
/// chose — earlier (the core's rows say `by=person`) or now — and a
/// `decision` record for every decision picked now, in the order the rows
/// and the picks came.
pub fn document(rows: &[Row], picks: &[Pick]) -> String {
    let mut out = String::from("omb-select 1\n");
    let mut seen: Vec<&[u8]> = Vec::new();
    for r in rows {
        // A `select` record carries include or exclude, nothing else the
        // core may show for a row (decide, never).
        if r.col(COL_BY) == "person"
            && matches!(r.col(COL_STATE), "include" | "exclude")
            && !picks.iter().any(|p| p.id == r.id && p.state.is_some())
        {
            out.push_str(&record::line(
                "select",
                &[("id", &r.id), ("state", r.col(COL_STATE).as_bytes())],
            ));
            seen.push(&r.id);
        }
    }
    for p in picks {
        if let Some(s) = &p.state
            && !seen.contains(&p.id.as_slice())
        {
            out.push_str(&record::line(
                "select",
                &[("id", &p.id), ("state", s.as_bytes())],
            ));
        }
    }
    for p in picks {
        if let Some((choice, value)) = &p.decision {
            out.push_str(&record::line(
                "decision",
                &[
                    ("id", &p.id),
                    ("choice", choice.as_bytes()),
                    ("value", value),
                ],
            ));
        }
    }
    out
}

/// DOC split at line ends into `select.1` … `select.N`, each part at most
/// PART_MAX bytes as the request writes it; None when the document is over
/// its limit or needs more than PARTS parts.
pub fn split(doc: &str) -> Option<Args> {
    if doc.len() > DOC_MAX {
        return None;
    }
    let mut parts: Vec<String> = Vec::new();
    let mut cur = String::new();
    for line in doc.split_inclusive('\n') {
        if record::encode(line.as_bytes()).len() > PART_MAX {
            return None;
        }
        if record::encode(format!("{cur}{line}").as_bytes()).len() > PART_MAX {
            parts.push(std::mem::take(&mut cur));
        }
        cur.push_str(line);
    }
    if !cur.is_empty() {
        parts.push(cur);
    }
    if parts.len() > PARTS {
        return None;
    }
    Some(
        parts
            .into_iter()
            .enumerate()
            .map(|(i, p)| (format!("select.{}", i + 1), p.into_bytes()))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::{Family, admit};

    fn row(id: &str, state: &str, by: &str) -> Row {
        let mut cols = vec![String::new(); 12];
        cols[COL_STATE] = state.into();
        cols[COL_BY] = by.into();
        Row {
            key: id.into(),
            id: id.as_bytes().to_vec(),
            cols,
        }
    }

    #[test]
    fn only_choices_that_differ_from_the_defaults_travel() {
        let rows = [
            row("brew:ripgrep", "include", "default"),
            row("brew:mas", "exclude", "default"),
            row("cask:tailscale", "decide", "default"),
            row("path:.config/kitty", "exclude", "person"),
        ];
        let mut picks = Vec::new();
        set_state(&mut picks, &rows[0], "exclude");
        set_state(&mut picks, &rows[1], "include");
        set_state(&mut picks, &rows[1], "exclude");
        set_decision(&mut picks, &rows[2], "flatpak");
        let doc = document(&rows, &picks);
        assert_eq!(
            doc,
            "omb-select 1\n\
             select\tid=path:.config/kitty\tstate=exclude\n\
             select\tid=brew:ripgrep\tstate=exclude\n\
             decision\tid=cask:tailscale\tchoice=flatpak\tvalue=\n"
        );
        // Back to the default: nothing for that item.
        set_state(&mut picks, &rows[0], "include");
        assert!(!document(&rows, &picks).contains("ripgrep"));
    }

    #[test]
    fn the_parts_join_into_the_document_and_each_fits() {
        let rows: Vec<Row> = (0..700)
            .map(|i| {
                row(
                    &format!("brew:tool-with-a-long-name-{i:04}"),
                    "include",
                    "person",
                )
            })
            .collect();
        let doc = document(&rows, &[]);
        let args = split(&doc).expect("fits in the parts");
        assert!(args.len() > 1 && args.len() <= PARTS);
        let mut joined = Vec::new();
        for (i, (name, value)) in args.iter().enumerate() {
            assert_eq!(name, &format!("select.{}", i + 1));
            assert!(record::encode(value).len() <= PART_MAX);
            assert_eq!(value.last(), Some(&b'\n'), "split at line ends");
            joined.extend_from_slice(value);
        }
        assert_eq!(joined, doc.as_bytes());
        // The joined document is one admissible request's worth of args.
        let mut req = String::from(
            "omb-req 1\nreq\top=validate\tproto=1\tfrontend=0.2.0\tsession=0123456789abcdef\nselect\taction=profile.save\n",
        );
        for (n, v) in &args {
            req.push_str(&record::line(
                "arg",
                &[("name", n.as_bytes()), ("value", v)],
            ));
        }
        assert!(admit(Family::Req, None, req.as_bytes()).is_ok());
        // Too much for the parts: refused here, never cut.
        let rows: Vec<Row> = (0..3000)
            .map(|i| row(&format!("brew:tool-{i:05}"), "include", "person"))
            .collect();
        assert_eq!(split(&document(&rows, &[])), None);
    }
}
