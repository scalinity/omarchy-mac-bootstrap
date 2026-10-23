//! `scan-*` and `profile-*` in the frontend (docs/TESTING.md → *Layers* A–C
//! and E): screens 3 (the scan), 4 (the selection), 5–9 and 11 (the category
//! tabs of one list and detail) and the Migration Review, over scope
//! `profile` as docs/MIGRATION.md → *On the wire* shapes it. Every count,
//! state and size is the core's; choosing is local until a save, which sends
//! one `omb-select 1` document in `select.N` parts, checked first and saved
//! with the review's basis; `opaque` is typed on the gate over the paths the
//! core says it covers.

use super::actions::{
    BASIS, DONE, GEN, REVIEW, answer, enc, frame, go, press, ready_on, requests, sent, sizes, typed,
};
use omb_tui::app::{Model, Msg, Req, Screen, update};
use omb_tui::read::{Kind, Page, Scope};
use omb_tui::record::Record;
use ratatui::crossterm::event::KeyCode;

pub const PGEN: &str = "9e3779b97f4a7c159e3779b97f4a7c159e3779b97f4a7c159e3779b97f4a7c15";

pub fn pfact(key: &str, label: &str, value: &str, state: &str) -> String {
    format!(
        "fact\tscope=profile\tkey={key}\tlabel={}\tvalue={}\tstate={state}\n",
        enc(label),
        enc(value)
    )
}

pub fn paction(id: &str, label: &str, gate: &str, cancel: bool, basis: &str) -> String {
    format!(
        "action\tid={id}\tscope=profile\tlabel={}\tintent=act\tgate={gate}\tterminal=managed\tcancel={}\tbasis={basis}\texplain=\n",
        enc(label),
        u8::from(cancel)
    )
}

/// The profile after a scan: its state, each source's, each category's
/// count and size, and its actions.
pub fn profile() -> String {
    let mut s = format!("generation\tid={PGEN}\ttotal=0\n");
    s.push_str(&pfact("profile.state", "State", "scanned", "info"));
    s.push_str(&pfact(
        "profile.counts",
        "Items",
        "5 items, 2 selected",
        "info",
    ));
    s.push_str(&pfact(
        "adapter.homebrew",
        "Homebrew",
        "done · 3 items",
        "ok",
    ));
    s.push_str(&pfact(
        "adapter.apps",
        "Applications",
        "partial · 1 items",
        "warn",
    ));
    s.push_str(&pfact(
        "adapter.ssh",
        "Git and SSH",
        "denied · 0 items",
        "fail",
    ));
    s.push_str(&pfact(
        "category.software",
        "Software",
        "1 of 3 · 6.3 MB",
        "warn",
    ));
    s.push_str(&pfact("category.apps", "Apps", "0 of 1 · 0 B", "info"));
    s.push_str(&pfact(
        "category.folders",
        "Folders",
        "0 of 1 · 4.0 GB",
        "info",
    ));
    s.push_str(&paction("profile.scan", "Scan this Mac", "", true, BASIS));
    s.push_str(&paction(
        "profile.save",
        "Save these choices",
        "",
        false,
        "",
    ));
    s.push_str(&paction(
        "profile.opaque",
        "Carry the chosen folders",
        "opaque",
        false,
        BASIS,
    ));
    for n in 1..=14 {
        s.push_str(&format!(
            "param\taction=profile.save\tname=select.{n}\ttype=bytes\tkind=\trequired=0\n"
        ));
    }
    s.push_str(DONE);
    s
}

pub fn item(id: &str, cols: [&str; 12]) -> String {
    let mut s = format!("row\tkind=item\tkey={}", enc(id));
    for c in cols {
        s.push_str(&format!("\tcol={}", enc(c)));
    }
    s.push('\n');
    s
}

/// The inventory, decisions first.
pub fn items() -> String {
    let mut s = format!("generation\tid={PGEN}\ttotal=5\n");
    s.push_str(&item(
        "cask:tailscale",
        [
            "software",
            "tailscale",
            "cask",
            "1.88",
            "choose",
            "decide",
            "config",
            "default",
            "two ways to bring it",
            "52428800",
            "observed",
            "unknown",
        ],
    ));
    s.push_str(&item(
        "brew:ripgrep",
        [
            "software",
            "ripgrep",
            "brew",
            "15.2.0",
            "pacman ripgrep",
            "include",
            "config",
            "default",
            "",
            "6291456",
            "observed",
            "yes",
        ],
    ));
    s.push_str(&item(
        "brew:mas",
        [
            "software",
            "mas",
            "brew",
            "2.1.0",
            "macOS only",
            "never",
            "mac-only",
            "default",
            "only means something on macOS",
            "1048576",
            "observed",
            "yes",
        ],
    ));
    s.push_str(&item(
        "app:com.example.Thing",
        [
            "apps",
            "Thing",
            "app",
            "3.0",
            "flatpak com.example.Thing",
            "exclude",
            "config",
            "person",
            "",
            "0",
            "observed",
            "yes",
        ],
    ));
    s.push_str(&item(
        "path:.config/kitty",
        [
            "folders",
            ".config/kitty",
            "folder",
            "",
            "carried whole",
            "exclude",
            "opaque",
            "default",
            "no adapter reads it",
            "4000000000",
            "observed",
            "unknown",
        ],
    ));
    s.push_str(DONE);
    s
}

pub fn choices() -> String {
    format!(
        "generation\tid={PGEN}\ttotal=2\nrow\tkind=choice\tkey=cask:tailscale\tcol=flatpak\tcol=Flatpak%20com.tailscale\tcol=1\nrow\tkind=choice\tkey=cask:tailscale\tcol=skip\tcol=Leave%20it%20on%20macOS\tcol=0\n{DONE}"
    )
}

pub fn review_rows() -> String {
    format!(
        "generation\tid={PGEN}\ttotal=2\nrow\tkind=review\tkey=software\tcol=Software\tcol=1\tcol=6291456\tcol=installed%20with%20pacman\nrow\tkind=review\tkey=apps\tcol=Apps\tcol=0\tcol=0\tcol=nothing%20comes\n{DONE}"
    )
}

pub fn page(kind: Kind) -> Req {
    Req::Detail(Page {
        kind,
        generation: PGEN.into(),
        offset: 0,
        limit: 500,
    })
}

/// A macOS session whose journey lists nothing, on screen S of the profile,
/// its snapshot and the details it opens answered.
pub fn on(s: Screen) -> Model {
    let mut m = ready_on("macos", &format!("generation\tid={GEN}\ttotal=0\n{DONE}"));
    let req = sent(&go(&mut m, s));
    assert_eq!(
        req,
        Req::Snapshot(Scope::Profile),
        "the profile is read first"
    );
    let mut c = answer(&mut m, req, &profile());
    while requests(&c) > 0 {
        let req = sent(&c);
        let body = match &req {
            Req::Detail(p) => match p.kind {
                Kind::Items => items(),
                Kind::Review => review_rows(),
                Kind::Choices => choices(),
                k => panic!("{k:?}"),
            },
            r => panic!("{r:?}"),
        };
        c = answer(&mut m, req, &body);
    }
    m
}

pub fn progress(label: &str, done: u64) -> Msg {
    Msg::Live(Record {
        ty: "progress".into(),
        fields: [
            ("action", "profile.scan".to_string()),
            ("done", done.to_string()),
            ("total", "3".into()),
            ("unit", "adapter".into()),
            ("label", label.into()),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.into_bytes()))
        .collect(),
    })
}

/// scan-states: each source's state as the core reports it — done, partial,
/// denied — and the scan run as the profile lists it, its progress followed.
#[test]
fn the_scan_shows_each_source_and_follows_the_scan() {
    let mut m = on(Screen::Scan);
    let f = frame(&m, 120, 40);
    for want in [
        "Environment scan",
        "✓ Homebrew",
        "done · 3 items",
        "! Applications",
        "partial",
        "✗ Git and SSH",
        "denied",
        "⏎ Scan this Mac",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    sizes(&m, "scan");
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0, "asked first");
    let req = sent(&press(&mut m, KeyCode::Char('y')));
    assert_eq!(
        req,
        Req::Execute {
            action: "profile.scan".into(),
            args: vec![],
            basis: BASIS.into(),
            word: String::new(),
            handoff: false,
            cancel: true,
        }
    );
    assert!(
        m.pending.as_ref().unwrap().cancellable,
        "a read of the Mac may be cancelled"
    );
    update(&mut m, progress("homebrew", 1));
    update(&mut m, progress("apps", 2));
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("homebrew") && f.contains("reading now 2 of 3"),
        "{f}"
    );
    sizes(&m, "scan_running");
    let c = answer(&mut m, req, DONE);
    assert_eq!(
        sent(&c),
        Req::Snapshot(Scope::Profile),
        "the profile is read again"
    );
}

/// The selection: the core's count and size per category; space puts every
/// item of one in or out (here, and only until a save); Enter opens its tab.
#[test]
fn the_selection_chooses_a_category_and_opens_it() {
    let mut m = on(Screen::Selection);
    let f = frame(&m, 120, 40);
    for want in [
        "Migration selection",
        "Software",
        "! 1 of 3 · 6.3 MB",
        "Folders",
        "0 of 1 · 4.0 GB",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    sizes(&m, "selection");
    press(&mut m, KeyCode::Down);
    assert_eq!(
        requests(&press(&mut m, KeyCode::Char(' '))),
        0,
        "choosing is local"
    );
    assert_eq!(m.picks.len(), 1);
    assert_eq!(m.picks[0].state.as_deref(), Some("include"));
    assert!(frame(&m, 120, 40).contains("1 chosen here"));
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    assert_eq!(m.screen, Screen::Inventory);
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("Thing") && !f.contains("ripgrep"),
        "the Apps tab:\n{f}"
    );
}

/// The inventory: decisions first, as the core orders them; space includes
/// or excludes, never an item that never travels; f the next category; a
/// filter over what is loaded; Enter the item's choices, read once.
#[test]
fn the_inventory_chooses_items_and_decisions() {
    let mut m = on(Screen::Inventory);
    let f = frame(&m, 120, 40);
    let at = |s: &str| f.find(s).unwrap_or_else(|| panic!("{s:?}:\n{f}"));
    assert!(
        at("tailscale") < at("ripgrep") && at("ripgrep") < at("mas"),
        "decisions first"
    );
    for want in ["▍Software", "◌", "◉", "decide", "never"] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    sizes(&m, "inventory");
    press(&mut m, KeyCode::Down);
    assert_eq!(requests(&press(&mut m, KeyCode::Char(' '))), 0);
    assert_eq!(m.picks[0].id, b"brew:ripgrep");
    assert!(frame(&m, 120, 40).contains("you, not saved"));
    press(&mut m, KeyCode::Down);
    press(&mut m, KeyCode::Char(' '));
    assert_eq!(m.picks.len(), 1, "an item that never travels is not chosen");
    assert!(m.status.as_ref().unwrap().1.contains("never travels"));
    // A filter, over the loaded rows only.
    press(&mut m, KeyCode::Char('/'));
    assert_eq!(requests(&typed(&mut m, "tail")), 0);
    press(&mut m, KeyCode::Enter);
    let f = frame(&m, 120, 40);
    assert!(f.contains("tailscale") && !f.contains("ripgrep"), "{f}");
    // The item's choices: read once, picked here.
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert_eq!(req, page(Kind::Choices));
    answer(&mut m, req, &choices());
    let f = frame(&m, 120, 40);
    for want in [
        "Flatpak com.tailscale (a guess)",
        "Leave it on macOS",
        "two ways to bring it",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    press(&mut m, KeyCode::Down);
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    let p = m.picks.iter().find(|p| p.id == b"cask:tailscale").unwrap();
    assert_eq!(p.decision.as_ref().unwrap().0, "skip");
    sizes(&m, "inventory_item");
    press(&mut m, KeyCode::Esc);
    assert!(!m.inv.open);
    // f: the next category.
    press(&mut m, KeyCode::Char('/'));
    press(&mut m, KeyCode::Esc);
    press(&mut m, KeyCode::Char('f'));
    assert!(frame(&m, 120, 40).contains("Thing"));
}

/// profile-select-document: a save is checked first — one omb-select
/// document of the choices that differ from the defaults, in select.N parts
/// — then asked, then sent with the same parts and the review's basis.
#[test]
fn the_review_saves_the_choices_as_one_document() {
    let mut m = on(Screen::Review);
    let f = frame(&m, 120, 40);
    for want in [
        "Migration review",
        "Software",
        "6.3 MB",
        "installed with pacman",
        "Save these choices",
        "type opaque",
    ] {
        assert!(f.contains(want), "{want:?}:\n{f}");
    }
    sizes(&m, "review");
    // A choice made in the inventory, then the save.
    go(&mut m, Screen::Inventory);
    press(&mut m, KeyCode::Down);
    press(&mut m, KeyCode::Char(' '));
    go(&mut m, Screen::Review);
    assert!(frame(&m, 120, 40).contains("1 choice made here, not saved yet"));
    let req = sent(&press(&mut m, KeyCode::Enter));
    let Req::Validate { action, args } = &req else {
        panic!("{req:?}")
    };
    assert_eq!(action, "profile.save");
    assert_eq!(args.len(), 1);
    assert_eq!(args[0].0, "select.1");
    assert_eq!(
        String::from_utf8(args[0].1.clone()).unwrap(),
        "omb-select 1\nselect\tid=app:com.example.Thing\tstate=exclude\nselect\tid=brew:ripgrep\tstate=exclude\n"
    );
    let parts = args.clone();
    answer(
        &mut m,
        req,
        &format!("review\taction=profile.save\tbasis={REVIEW}\n{DONE}"),
    );
    assert!(m.status.as_ref().unwrap().1.contains("Save these choices?"));
    let req = sent(&press(&mut m, KeyCode::Char('y')));
    assert_eq!(
        req,
        Req::Execute {
            action: "profile.save".into(),
            args: parts,
            basis: REVIEW.into(),
            word: String::new(),
            handoff: false,
            cancel: false,
        }
    );
    let c = answer(&mut m, req, DONE);
    assert_eq!(sent(&c), Req::Snapshot(Scope::Profile));
    assert!(m.picks.is_empty(), "the choices are saved");
}

/// A save the core refuses keeps the choices and says why.
#[test]
fn a_refused_save_keeps_the_choices() {
    let mut m = on(Screen::Review);
    go(&mut m, Screen::Inventory);
    press(&mut m, KeyCode::Down);
    press(&mut m, KeyCode::Char(' '));
    go(&mut m, Screen::Review);
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(
        &mut m,
        req,
        "invalid\tname=select.1\tcode=unknown-item\ttext=The%20profile%20holds%20no%20item%20brew:ripgrep.\nresult\tstatus=refused\tcode=invalid\ttext=\tnext=\n",
    );
    assert!(m.ask.is_none(), "nothing is asked of a refused check");
    assert_eq!(m.picks.len(), 1);
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("refused · invalid") && f.contains("The profile holds no item"),
        "{f}"
    );
}

/// opaque is typed on the gate, over the paths the core says it covers.
#[test]
fn opaque_is_typed_over_what_it_covers() {
    let mut m = on(Screen::Review);
    press(&mut m, KeyCode::Down);
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert_eq!(m.screen, Screen::Gate);
    assert_eq!(req, page(Kind::Opaque));
    answer(
        &mut m,
        req,
        &format!(
            "generation\tid={PGEN}\ttotal=1\nrow\tkind=opaque\tkey=path:.config/kitty\tcol=~/.config/kitty\tcol=4000000000\n{DONE}"
        ),
    );
    let f = frame(&m, 80, 24);
    assert!(
        f.contains("~/.config/kitty") && f.contains("Type opaque to continue"),
        "{f}"
    );
    sizes(&m, "gate_opaque");
    typed(&mut m, "opaque");
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert!(
        matches!(&req, Req::Execute { action, word, .. } if action == "profile.opaque" && word == "opaque"),
        "{req:?}"
    );
}
