use super::actions::*;
use omb_tui::app::{Fact, Model, Msg, Region, Screen, update};
use omb_tui::read::{Detail, Kind, Row};
use ratatui::crossterm::event::KeyCode;

fn row(key: &str, cols: &[&str]) -> Row {
    Row {
        key: key.into(),
        id: key.as_bytes().to_vec(),
        cols: cols.iter().map(|s| s.to_string()).collect(),
    }
}
fn machine() -> Model {
    let mut m = ready_on("macos", &mac_journey());
    m.snap.as_mut().unwrap().facts.extend([
        Fact {
            key: "machine.platform".into(),
            label: "Platform".into(),
            value: "macos".into(),
            state: "info".into(),
        },
        Fact {
            key: "machine.memory".into(),
            label: "Memory".into(),
            value: "17179869184".into(),
            state: "info".into(),
        },
        Fact {
            key: "status.2".into(),
            label: "Machine".into(),
            value: "MacBook Pro (16-inch, M1 Pro, 2021)".into(),
            state: "info".into(),
        },
    ]);
    m.snap.as_mut().unwrap().guides =
        vec!["Run ./omarchy-bootstrap to survey this Mac and plan storage.".into()];
    m
}
fn status() -> Model {
    let mut m = machine();
    m.screen = Screen::Status;
    let mut d = Detail::new(Kind::Status, GEN);
    d.loaded = true;
    let path = format!(
        "{}/.local/state/omarchy-bootstrap/state.env",
        std::env::var("HOME").unwrap()
    );
    d.rows = vec![
        row("1", &["Detected now", "", "", "MacBookPro18,1"]),
        row(
            "2",
            &[
                "Detected now",
                "Machine",
                "MacBook Pro (16-inch, M1 Pro, 2021) with a full value that wraps to its END_MARK",
                "supported",
            ],
        ),
        row("3", &["Detected now", "Asahi install", "none", ""]),
        row("4", &["Detected now", "Safe Linux max", "654 GB", ""]),
        row("5", &["Recorded", "", "", &path]),
        row("6", &["Recorded", "Plan", "not yet", ""]),
    ];
    d.total = d.rows.len() as u64;
    m.details[Kind::Status.index()] = Some(d);
    update(&mut m, Msg::Tick);
    m
}
#[test]
fn status_sections_values_and_expansions_add_context() {
    let mut m = status();
    for (w, h) in [(120, 40), (80, 24)] {
        let f = frame(&m, w, h);
        for want in [
            "Read from this Mac now",
            "Saved progress",
            "Model ID MacBookPro18,1",
            "Saved in ~",
            "END_MARK",
            "supported",
        ] {
            assert!(f.contains(want), "{want}: {f}");
        }
        insta::assert_snapshot!(format!("status_{w}x{h}"), f);
    }
    assert_eq!(
        m.detail(Kind::Status).unwrap().cursor,
        1,
        "skip section heading"
    );
    press(&mut m, KeyCode::Enter);
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("read from this Mac just now") && f.contains("END_MARK"),
        "{f}"
    );
    assert!(!f.contains("Detected now / Machine"));
    insta::assert_snapshot!("expanded_source", f);
    press(&mut m, KeyCode::Enter);
    press(&mut m, KeyCode::End);
    frame(&m, 80, 24);
    assert!(
        m.detail(Kind::Status).unwrap().shown()[m.detail(Kind::Status).unwrap().cursor]
            .focusable(Kind::Status)
    );
    m.hello.as_mut().unwrap().platform = "linux".into();
    let d = m.details[Kind::Status.index()].as_mut().unwrap();
    d.rows = vec![
        row("1", &["Detected now", "", "", "read from the machine"]),
        row("2", &["Detected now", "Omarchy", "installed", "4.0.3rc4"]),
        row("3", &["omarchy-mac-setup --status", "", "", "upstream"]),
        row(
            "4",
            &["omarchy-mac-setup --status", "", "Root is encrypted.", ""],
        ),
    ];
    d.total = 4;
    d.cursor = 1;
    d.open = false;
    let f = frame(&m, 80, 24);
    assert!(
        f.contains("Read from Linux now") && f.contains("Omarchy setup status"),
        "{f}"
    );
    assert!(!f.contains("Model ID") && !f.contains(": Root"), "{f}");
    insta::assert_snapshot!("linux_status", f);
    let d = m.details[Kind::Status.index()].as_mut().unwrap();
    d.rows
        .push(row("5", &["Detected now", "Pending check", "", ""]));
    d.total = 5;
    press(&mut m, KeyCode::End);
    let f = frame(&m, 80, 24);
    assert!(
        f.contains("Pending check:"),
        "a label remains visible with an empty value: {f}"
    );
}
#[test]
fn an_uninformative_row_has_no_expansion() {
    let mut m = machine();
    m.screen = Screen::Logs;
    let mut d = Detail::new(Kind::Log, GEN);
    d.loaded = true;
    d.total = 1;
    d.rows = vec![row("1", &["", "info", "", "Ready."])];
    m.details[Kind::Log.index()] = Some(d);
    frame(&m, 80, 24);
    press(&mut m, KeyCode::Enter);
    assert!(!m.detail(Kind::Log).unwrap().open);
    assert!(!frame(&m, 80, 24).lines().last().unwrap().contains('⏎'));
}
#[test]
fn overview_next_step_navigation_and_system_names_are_readable() {
    let mut m = machine();
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("MacBook Pro (16-inch")
            && f.contains("Model ID")
            && f.contains("macOS")
            && f.contains("16 GB"),
        "{f}"
    );
    assert!(!f.contains("Run ./omarchy-bootstrap to"));
    assert!(f.contains("Next: Save the plan"));
    insta::assert_snapshot!("overview_next_step", f);
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 1);
    assert_eq!(m.screen, Screen::Plan);
    m = machine();
    m.focus = 1;
    assert!(m.guides()[0].contains(&m.focused().unwrap().label));
    m.station = Some(0);
    assert!(!m.guides()[0].contains("press Enter"));
    m.screen = Screen::Status;
    m.region = Region::Nav;
    m.nav = omb_tui::app::NAV.len() - 1;
    let f = frame(&m, 80, 20);
    assert!(f.contains("Completion") && f.contains('↑'), "{f}");
    insta::assert_snapshot!("screens_scrolled", f);
    m.hello.as_mut().unwrap().platform = "linux".into();
    m.snap
        .as_mut()
        .unwrap()
        .facts
        .iter_mut()
        .find(|f| f.key == "machine.platform")
        .unwrap()
        .value = "linux".into();
    assert!(frame(&m, 120, 40).contains("Linux"));
    assert!(!frame(&m, 120, 40).contains("Platform      linux"));
    // Linux supplies the marketing name directly rather than an Apple identifier.
    m.snap
        .as_mut()
        .unwrap()
        .facts
        .retain(|f| f.key != "status.2");
    m.snap
        .as_mut()
        .unwrap()
        .facts
        .iter_mut()
        .find(|f| f.key == "machine.model")
        .unwrap()
        .value = "Apple MacBook Pro (16-inch, M1 Pro, 2021)".into();
    let f = frame(&m, 120, 40);
    assert!(f.contains("Model         Apple MacBook"), "{f}");
    assert!(!f.contains("Model ID"), "{f}");
    assert_eq!(
        omb_tui::widgets::fact_value("restore.backup_bytes", "Backup bytes", "1073741824"),
        "1.1 GB"
    );
    assert_eq!(
        omb_tui::widgets::fact_value(
            "qualify.shared",
            "Shared",
            "4a7b1c2d-0007-4e5f-8a9b-000000000007 at /mnt/shared"
        ),
        "Verified at /mnt/shared"
    );
}

#[test]
fn migration_review_keeps_the_whole_note() {
    let mut m = super::migration::on(Screen::Review);
    m.details[Kind::Review.index()].as_mut().unwrap().rows[0].cols[3] = format!(
        "{}END_OF_REVIEW_NOTE",
        "The complete explanation remains readable. ".repeat(4)
    );
    let f = frame(&m, 120, 40);
    assert!(f.contains("END_OF_REVIEW_NOTE"), "{f}");
    insta::assert_snapshot!("review_full_note", f);
}
