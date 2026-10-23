use super::actions::*;
use omb_tui::app::{Model, Screen};
use omb_tui::app::{Msg, update};
use omb_tui::read::{Detail, Kind, Row, Scope};
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

/// Fixture replies for the requested preset, so the frame's scale, normal
/// sizes and installer answers describe the same selection. Real planning is
/// separately exercised by gate2_read's Bash-core test.
fn preset_reply(m: &Model) -> String {
    let size = |name: &str| {
        let value = &m.plan.fields.iter().find(|f| f.name == name).unwrap().value;
        if value == "0" {
            return Some(0u64);
        }
        for (unit, scale) in [("GB", 1e9), ("TB", 1e12), ("%", 1e10)] {
            if let Some(n) = value.strip_suffix(unit).and_then(|n| n.parse::<f64>().ok()) {
                return Some((n * scale) as u64);
            }
        }
        None
    };
    let mut body = String::new();
    for name in ["shared_size", "linux_size"] {
        if size(name).is_none() {
            return format!(
                "invalid\tname={name}\tcode=required\ttext=This%20size%20parameter%20is%20required.\nresult\tstatus=refused\tcode=invalid\ttext=\tnext=\n"
            );
        }
    }
    let (linux, shared) = (size("linux_size").unwrap(), size("shared_size").unwrap());
    if linux.saturating_add(shared) > 654_000_000_000 {
        return "invalid\tname=linux_size\tcode=above-maximum\ttext=The%20size%20exceeds%20the%20current%20maximum%20for%20this%20parameter.\nresult\tstatus=refused\tcode=invalid\ttext=\tnext=\n".into();
    }
    let macos = 1_000_000_000_000 - 9_000_000_000 - linux - shared;
    let mut start = 0;
    for (role, bytes) in [
        ("apple", 6_000_000_000),
        ("macos", macos),
        ("stub", 3_000_000_000),
        ("linux", linux),
        ("shared", shared),
    ] {
        if bytes > 0 {
            body.push_str(&format!(
                "region\tstart={start}\tsize={bytes}\trole={role}\tlabel=\n"
            ));
        }
        start += bytes;
    }
    for (i, prompt, bytes) in [(1, "New size for macOS", macos), (2, "New OS size", linux)] {
        body.push_str(&format!(
            "answer\tn={i}\tprompt={}\tvalue={}MiB\tbytes={bytes}\n",
            enc(prompt),
            bytes / 1_048_576
        ));
    }
    let normals = plan_review();
    let (_, normals) = normals.split_once("normal\t").unwrap();
    body.push_str(
        &format!("normal\t{normals}")
            .replace("value=100000000000", &format!("value={shared}"))
            .replace("value=250000000000", &format!("value={linux}")),
    );
    body
}

fn planner() -> Model {
    let mut m = ready_on("macos", &mac_journey());
    let req = sent(&go(&mut m, Screen::Plan));
    let body = preset_reply(&m);
    answer(&mut m, req, &body);
    m
}

fn check(m: &mut Model, code: KeyCode) {
    let req = sent(&press(m, code));
    let body = preset_reply(m);
    assert_eq!(requests(&answer(m, req, &body)), 0, "no validation loop");
}

#[test]
fn planner_presets_custom_units_and_core_messages() {
    let mut m = planner();
    for (name, code) in [
        ("linux_balanced", None),
        ("linux_minimal", Some(KeyCode::Left)),
        ("linux_balanced_again", Some(KeyCode::Right)),
        ("linux_heavy", Some(KeyCode::Right)),
        ("linux_custom", Some(KeyCode::Right)),
    ] {
        if let Some(code) = code {
            check(&mut m, code);
        }
        if name != "linux_balanced_again" {
            insta::assert_snapshot!(name, frame(&m, 100, 36));
        }
    }
    typed(&mut m, "200");
    let f = frame(&m, 100, 36);
    assert!(
        f.contains("200▏ GB") && !f.contains("This size parameter is required"),
        "{f}"
    );
    insta::assert_snapshot!("custom_typing", f);
    press(&mut m, KeyCode::Tab);
    check(&mut m, KeyCode::Right);
    assert!(
        m.plan
            .args()
            .iter()
            .any(|(n, v)| n == "linux_size" && v == b"200TB")
    );
    check(&mut m, KeyCode::Right);
    assert!(
        m.plan
            .args()
            .iter()
            .any(|(n, v)| n == "linux_size" && v == b"200%")
    );
    check(&mut m, KeyCode::Right);
    assert!(
        m.plan
            .args()
            .iter()
            .any(|(n, v)| n == "linux_size" && v == b"200GB")
    );
    let req = press(&mut m, KeyCode::Enter);
    // The synthetic core answered a valid review: Enter asks, it does not validate again.
    assert_eq!(requests(&req), 0);
    press(&mut m, KeyCode::Char('n'));
    m.plan.checked = None;
    let req = sent(&press(&mut m, KeyCode::Enter));
    let refused = String::from(
        "invalid\tname=linux_size\tcode=above-maximum\ttext=The%20size%20exceeds%20the%20current%20maximum%20for%20this%20parameter.\nresult\tstatus=refused\tcode=invalid\ttext=\tnext=\n",
    );
    answer(&mut m, req, &refused);
    insta::assert_snapshot!("custom_invalid", frame(&m, 100, 36));
    let small = frame(&m, 60, 20);
    assert!(
        small.contains("The size exceeds") && small.contains("parameter."),
        "{small}"
    );
    insta::assert_snapshot!("custom_invalid_60x20", small);
    assert!(
        frame(&m, 120, 70).contains("The size exceeds the current maximum for this parameter.")
    );
    update(
        &mut m,
        Msg::Key(KeyEvent::new(KeyCode::Char('u'), KeyModifiers::CONTROL)),
    );
    typed(&mut m, "20");
    assert!(
        !frame(&m, 120, 70).contains("The size exceeds the current maximum for this parameter.")
    );

    let mut m = planner();
    m.plan.field = m
        .plan
        .fields
        .iter()
        .position(|f| f.name == "shared_size")
        .unwrap();
    for _ in 0..3 {
        check(&mut m, KeyCode::Left);
    }
    for name in [
        "shared_none",
        "shared_50",
        "shared_100",
        "shared_150",
        "shared_250",
        "shared_custom",
    ] {
        insta::assert_snapshot!(name, frame(&m, 100, 36));
        if name != "shared_custom" {
            check(&mut m, KeyCode::Right);
        }
    }
}

#[test]
fn unavailable_presets_and_renamed_defaults() {
    let mut m = planner();
    m.snap.as_mut().unwrap().facts.push(omb_tui::app::Fact {
        key: "status.max".into(),
        label: "Safe Linux maximum".into(),
        value: "300 GB".into(),
        state: "info".into(),
    });
    insta::assert_snapshot!("unavailable_preset", frame(&m, 100, 36));
    let req = sent(&press(&mut m, KeyCode::Right));
    assert!(
        m.plan.custom[0],
        "skip the unavailable preset and reach Custom"
    );
    let body = preset_reply(&m);
    answer(&mut m, req, &body);
    let f = frame(&m, 120, 70);
    for (label, val) in [
        ("Encrypt Linux", "on"),
        ("User name", "alex"),
        ("Host name", "omarchy"),
        ("Keyboard layout", "us"),
        ("Time zone", "America/New_York"),
        ("Locale", "en_US.UTF-8"),
        ("SSH server", "off"),
        ("GitHub user", "octocat"),
        ("Developer tools", "on"),
    ] {
        assert!(f.contains(label) && f.contains(val), "{label} {val}: {f}");
    }
    assert!(!f.contains("not given"));
    insta::assert_snapshot!("named_defaults", f);
}

#[test]
fn action_rows_and_navigation_do_not_contradict_the_page() {
    let mut m = ready_on("macos", &mac_journey());
    go(&mut m, Screen::Progress);
    press(&mut m, KeyCode::Enter);
    assert!(m.status.is_some());
    press(&mut m, KeyCode::Esc);
    assert_eq!(m.screen, Screen::Dashboard);
    assert!(m.status.is_none());
    let f = frame(&m, 120, 70);
    assert!(!f.contains("Save the plan   plan") && !f.contains("Nothing on this page"));
    assert!(f.contains("The text flow's own plan.save."));
    insta::assert_snapshot!("action_rows", f);
}

fn scroll_roundtrip(mut m: Model, name: &str) {
    let _ = frame(&m, 60, 20);
    let total = m.viewport.borrow().total;
    assert!(total > m.viewport.borrow().height, "{name} has overflow");
    press(&mut m, KeyCode::End);
    let bottom = frame(&m, 60, 20);
    let v = m.viewport.borrow();
    assert_eq!(v.top + v.height, v.total, "{name} end");
    assert!(
        !bottom
            .lines()
            .any(|l| l.ends_with("v│") || l.ends_with("↓│")),
        "{name}: {bottom}"
    );
    drop(v);
    insta::assert_snapshot!(format!("{name}_end"), bottom);
    press(&mut m, KeyCode::Home);
    let _ = frame(&m, 60, 20);
    assert_eq!(m.viewport.borrow().top, 0, "{name} home");
    press(&mut m, KeyCode::PageDown);
    let _ = frame(&m, 60, 20);
    assert!(m.viewport.borrow().top > 0, "{name} page down");
    press(&mut m, KeyCode::PageUp);
    let _ = frame(&m, 60, 20);
    assert_eq!(m.viewport.borrow().top, 0, "{name} page up");
}

#[test]
fn prose_screens_scroll_to_end_and_back() {
    for screen in [
        Screen::Dashboard,
        Screen::Shared,
        Screen::Install,
        Screen::Progress,
        Screen::Scan,
    ] {
        let mut m = ready_on("macos", &mac_journey());
        m.screen = screen;
        if screen == Screen::Scan {
            m.profile.snap = Some(omb_tui::app::snapshot_of(&[]));
            m.profile.snap.as_mut().unwrap().facts = (0..40)
                .map(|i| omb_tui::app::Fact {
                    key: format!("adapter.{i}"),
                    label: format!("Source {i}"),
                    value: "observed".into(),
                    state: "ok".into(),
                })
                .collect();
        }
        if screen == Screen::Shared {
            m.snap
                .as_mut()
                .unwrap()
                .facts
                .extend((0..30).map(|i| omb_tui::app::Fact {
                    key: format!("gate.shared.create.check{i}"),
                    label: format!("Check {i}"),
                    value: "observed".into(),
                    state: "ok".into(),
                }));
        }
        if screen == Screen::Progress {
            m.hello.as_mut().unwrap().platform = "linux".into();
            m.snap
                .as_mut()
                .unwrap()
                .facts
                .extend((0..30).map(|i| omb_tui::app::Fact {
                    key: format!("omarchy.signal{i}"),
                    label: format!("Signal {i}"),
                    value: "observed".into(),
                    state: "ok".into(),
                }));
        }
        scroll_roundtrip(m, screen.title());
    }
    scroll_roundtrip(planner(), "plan");
    scroll_roundtrip(super::phase_b::on(), "restore");
    let mut m = super::phase_b::on();
    m.screen = Screen::Brief;
    m.debug.snap = Some(omb_tui::app::snapshot_of(&[]));
    add_rows(&mut m, Kind::Brief, 40);
    scroll_roundtrip(m, "brief");
    let mut m = super::phase_c::on_qualify("passed");
    let d = m.details[Kind::Step.index()].as_mut().unwrap();
    d.rows[0].cols[2] = "Detailed core qualification result. ".repeat(30);
    scroll_roundtrip(m, "qualification");
    scroll_roundtrip(super::phase_c::on_completion(&["pass"; 8]), "completion");
}

fn add_rows(m: &mut Model, kind: Kind, n: usize) {
    let mut d = Detail::new(kind, m.generation(kind.scope()).unwrap_or(GEN));
    d.loaded = true;
    d.total = n as u64;
    d.rows = (0..n)
        .map(|i| Row {
            key: format!("line{i}"),
            id: format!("row{i}").into_bytes(),
            cols: match kind {
                Kind::Doctor => vec!["pass".into(), format!("Check {i}"), "observed".into()],
                Kind::Log => vec!["".into(), "info".into(), "core".into(), format!("Line {i}")],
                _ => vec![
                    format!("Line {i}"),
                    format!("Value {i}"),
                    "observed".into(),
                    String::new(),
                ],
            },
        })
        .collect();
    m.details[kind.index()] = Some(d);
}

#[test]
fn tables_scroll_to_end_and_back() {
    for (screen, kind) in [
        (Screen::Machine, Kind::Machine),
        (Screen::Status, Kind::Status),
        (Screen::Health, Kind::Doctor),
        (Screen::Logs, Kind::Log),
        (Screen::Operation, Kind::Operation),
    ] {
        let mut m = ready_on("macos", &mac_journey());
        m.screen = screen;
        if kind.scope() != Scope::Journey {
            let s = omb_tui::app::snapshot_of(&[]);
            if kind == Kind::Log {
                m.logread.snap = Some(s);
            } else {
                m.health.snap = Some(s);
            }
        }
        add_rows(&mut m, kind, 40);
        scroll_roundtrip(m, screen.title());
    }
}

#[test]
fn migration_screens_scroll_to_end_and_back() {
    for screen in [Screen::Selection, Screen::Inventory, Screen::Review] {
        let mut m = super::migration::on(screen);
        if screen == Screen::Selection {
            m.profile
                .snap
                .as_mut()
                .unwrap()
                .facts
                .extend((0..30).map(|i| omb_tui::app::Fact {
                    key: format!("category.extra{i}"),
                    label: format!("Category {i}"),
                    value: "1 item".into(),
                    state: "info".into(),
                }));
        }
        if screen == Screen::Inventory {
            let d = m.details[Kind::Items.index()].as_mut().unwrap();
            let row = d.rows[0].clone();
            for i in 0..30 {
                let mut r = row.clone();
                r.id = format!("item{i}").into_bytes();
                d.rows.push(r);
            }
            d.total = d.rows.len() as u64;
        }
        if screen == Screen::Review {
            add_rows(&mut m, Kind::Review, 30);
        }
        scroll_roundtrip(m, screen.title());
    }
}

#[test]
fn arrows_reach_prose_beyond_actions_and_keep_fields_visible() {
    let mut m = ready_on("macos", &mac_journey());
    frame(&m, 60, 20);
    for _ in 0..60 {
        press(&mut m, KeyCode::Up);
        frame(&m, 60, 20);
    }
    assert_eq!(m.viewport.borrow().top, 0);
    for _ in 0..60 {
        press(&mut m, KeyCode::Down);
        frame(&m, 60, 20);
    }
    let v = m.viewport.borrow();
    assert_eq!(v.top + v.height, v.total);
    drop(v);
    let mut m = planner();
    for _ in 0..12 {
        frame(&m, 60, 20);
        press(&mut m, KeyCode::Down);
    }
    let f = frame(&m, 60, 20);
    assert!(f.contains("Developer tools"), "{f}");
}

#[test]
fn saved_sizes_and_typing_keys_are_preserved() {
    let mut m = ready_on("macos", &mac_journey());
    m.snap.as_mut().unwrap().facts.push(omb_tui::app::Fact {
        key: "recorded.plan".into(),
        label: "Plan".into(),
        value: "Linux 500 GB + 50 GB shared".into(),
        state: "info".into(),
    });
    let req = sent(&go(&mut m, Screen::Plan));
    let wire = bytes(&req);
    assert!(
        wire.contains("name=linux_size\tvalue=500GB")
            && wire.contains("name=shared_size\tvalue=50GB")
    );
    answer(&mut m, req, &plan_review());
    m.plan.field = m.plan.fields.iter().position(|f| f.name == "gh").unwrap();
    m.plan.fields[m.plan.field].value.clear();
    frame(&m, 60, 20);
    typed(&mut m, "jkgG");
    assert_eq!(
        m.plan.fields[m.plan.field].value, "jkgG",
        "letters stay text"
    );
    frame(&m, 60, 20);
    assert!(m.focus_visible());
}

#[test]
fn expanded_health_and_item_views_scroll_to_end_and_back() {
    let mut m = ready_on("linux", &mac_journey());
    m.screen = Screen::Health;
    m.health.snap = Some(omb_tui::app::snapshot_of(&[]));
    add_rows(&mut m, Kind::Doctor, 40);
    m.details[Kind::Doctor.index()].as_mut().unwrap().rows[0].key = "agents.codex".into();
    scroll_roundtrip(m, "health_grouped");
    let mut m = super::migration::on(Screen::Inventory);
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(&mut m, req, &super::migration::choices());
    let d = m.details[Kind::Items.index()].as_mut().unwrap();
    d.rows[0].cols[8] = "Core explanation of this item. ".repeat(40);
    scroll_roundtrip(m, "inventory_item");
}
