//! The phase A review's findings on the frontend (H1–H4, M1–M13 and the
//! cheap lows), one state or frame test each: every one fails on the code
//! the review read and holds after its fix.

use super::actions::{
    BASIS, DONE, GEN, REVIEW, action, answer, answer_on, fact, frame, go, mac_journey, plan_review,
    press, ready_on, render, requests, sent, text_of, theme, typed,
};
use super::migration::{PGEN, item, items, on, paction, page, profile};
use omb_tui::app::{Model, Req, Screen};
use omb_tui::read::{Kind, Page, Scope};
use ratatui::crossterm::event::KeyCode;

fn journey(records: &str) -> String {
    format!("generation\tid={GEN}\ttotal=0\n{records}{DONE}")
}

fn exec_of(req: &Req) -> &str {
    match req {
        Req::Execute { action, .. } => action,
        r => panic!("not an execute: {r:?}"),
    }
}

/// H1: an act with no gate and no parameters is asked first, default no; a
/// read action is sent at once.
#[test]
fn h1_an_act_without_a_gate_is_asked_first() {
    let body = journey(&format!(
        "{}{}",
        action(
            "network.connect",
            "network",
            "Connect to the network",
            "",
            true,
            BASIS
        ),
        action("dev", "omarchy", "Developer setup", "", true, BASIS),
    ));
    let mut m = ready_on("linux", &body);
    go(&mut m, Screen::Install);
    assert_eq!(
        requests(&press(&mut m, KeyCode::Char('n'))),
        0,
        "asked first"
    );
    assert!(
        m.status
            .as_ref()
            .unwrap()
            .1
            .contains("Connect to the network?")
    );
    assert_eq!(
        requests(&press(&mut m, KeyCode::Enter)),
        0,
        "any other key is no"
    );
    assert!(m.ask.is_none());
    press(&mut m, KeyCode::Char('n'));
    let req = sent(&press(&mut m, KeyCode::Char('y')));
    assert_eq!(exec_of(&req), "network.connect");
    answer_on(&mut m, req, DONE, "linux");
    answer_on(&mut m, Req::Snapshot(Scope::Journey), &body, "linux");
    press(&mut m, KeyCode::Esc);
    m.focus = 1;
    assert_eq!(
        requests(&press(&mut m, KeyCode::Enter)),
        0,
        "dev is asked too"
    );
    assert!(m.ask.is_some());
    // The profile's scan, a managed act with no gate.
    let mut m = on(Screen::Scan);
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    assert!(m.status.as_ref().unwrap().1.contains("Scan this Mac?"));
    assert_eq!(
        exec_of(&sent(&press(&mut m, KeyCode::Char('y')))),
        "profile.scan"
    );
}

/// H2: where the core lists plan.save, only its declared parameters are
/// fields: none declared, none sent.
#[test]
fn h2_a_listed_plan_save_sends_only_what_it_declares() {
    let mut m = ready_on(
        "macos",
        &journey(&action("plan.save", "plan", "Save the plan", "", false, "")),
    );
    go(&mut m, Screen::Plan);
    assert!(m.plan.fields.is_empty(), "{:?}", m.plan.fields);
    assert!(!frame(&m, 120, 40).contains("Linux size"));
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert_eq!(
        req,
        Req::Validate {
            action: "plan.save".into(),
            args: vec![]
        }
    );
}

/// H3: after another action's form went through its gate, the planner
/// draws the planner's own fields.
#[test]
fn h3_the_planner_draws_its_own_fields() {
    let mut body = mac_journey();
    body = body.replace(
        DONE,
        &format!(
            "{}param\taction=x.carry\tname=code\ttype=text\tkind=\trequired=1\n{DONE}",
            action("x.carry", "plan", "Carry a thing", "carry", false, "")
        ),
    );
    // The action lines precede the params in the response's order.
    let body = reorder(&body);
    let mut m = ready_on("macos", &body);
    let i = m
        .snap
        .as_ref()
        .unwrap()
        .actions
        .iter()
        .position(|a| a.id == "x.carry")
        .unwrap();
    m.focus = i;
    press(&mut m, KeyCode::Enter);
    assert_eq!(m.screen, Screen::Form);
    typed(&mut m, "secret-thing");
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(
        &mut m,
        req,
        &format!(
            "normal\tname=code\tvalue=secret-thing\nreview\taction=x.carry\tbasis={REVIEW}\n{DONE}"
        ),
    );
    press(&mut m, KeyCode::Enter);
    assert_eq!(m.screen, Screen::Gate);
    typed(&mut m, "carry");
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(&mut m, req, DONE);
    answer(&mut m, Req::Snapshot(Scope::Journey), &body);
    assert_eq!(m.screen, Screen::Form);
    press(&mut m, KeyCode::Esc);
    go(&mut m, Screen::Plan);
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("Shared size") && !f.contains("secret-thing"),
        "{f}"
    );
}

/// Action and param records in the response's order.
fn reorder(body: &str) -> String {
    let lines: Vec<&str> = body.lines().collect();
    let rank = |l: &str| match l.split('\t').next().unwrap() {
        "generation" => 0,
        "fact" => 1,
        "region" => 2,
        "answer" => 3,
        "guide" => 4,
        "code" => 5,
        "action" => 6,
        "param" => 7,
        _ => 9,
    };
    let mut v = lines.clone();
    v.sort_by_key(|l| rank(l));
    v.join("\n") + "\n"
}

/// H4: the console is the core's fact: shown from its value, and nothing
/// about a console without it.
#[test]
fn h4_the_console_comes_from_the_core() {
    let start = action(
        "omarchy.start",
        "omarchy",
        "Run omarchy-mac-setup",
        "start",
        true,
        BASIS,
    );
    let with = journey(&format!(
        "{}{start}",
        fact("omarchy.console", "Console", "tty1 (Ctrl+Alt+F1)", "info")
    ));
    let mut m = ready_on("linux", &with);
    go(&mut m, Screen::Install);
    assert!(frame(&m, 120, 40).contains("tty1 (Ctrl+Alt+F1)"));
    go(&mut m, Screen::Progress);
    let f = frame(&m, 120, 40);
    assert!(f.contains("tty1 (Ctrl+Alt+F1)"), "{f}");
    assert_eq!(
        f.matches("Console").count(),
        0,
        "a sentence, not a check-list line:\n{f}"
    );
    let mut m = ready_on("linux", &journey(&start));
    for s in [Screen::Install, Screen::Progress] {
        go(&mut m, s);
        let f = frame(&m, 120, 40);
        assert!(!f.contains("tty1") && !f.contains("Ctrl+Alt"), "{f}");
    }
}

/// M1 (a): a profile.save with a word goes to its gate.
#[test]
fn m1_a_gated_save_opens_its_gate() {
    let mut m = on(Screen::Review);
    let gated = profile().replace(
        &paction("profile.save", "Save these choices", "", false, ""),
        &paction("profile.save", "Save these choices", "save", false, ""),
    );
    let req = sent(&press(&mut m, KeyCode::Char('r')));
    let c = answer(&mut m, req, &gated);
    // Re-read details as the screen asks.
    feed(&mut m, c);
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(
        &mut m,
        req,
        &format!("review\taction=profile.save\tbasis={REVIEW}\n{DONE}"),
    );
    assert!(m.ask.is_none());
    assert_eq!(m.screen, Screen::Gate);
    typed(&mut m, "save");
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert!(
        matches!(&req, Req::Execute { word, .. } if word == "save"),
        "{req:?}"
    );
}

/// Answer every detail page the model asks for with the profile fixtures.
fn feed(m: &mut Model, mut c: Vec<omb_tui::app::Cmd>) {
    while requests(&c) > 0 {
        let req = sent(&c);
        let body = match &req {
            Req::Detail(p) => match p.kind {
                Kind::Items => items(),
                Kind::Review => super::migration::review_rows(),
                Kind::Choices => super::migration::choices(),
                k => panic!("{k:?}"),
            },
            Req::Snapshot(Scope::Profile) => profile(),
            Req::Snapshot(Scope::Journey) => journey(""),
            r => panic!("{r:?}"),
        };
        c = answer(m, req, &body);
    }
}

/// M1 (b): an answer that lands while a text field has the keys arms no
/// question; a y typed there is text.
#[test]
fn m1_a_late_answer_never_takes_a_key_typed_elsewhere() {
    let mut m = on(Screen::Review);
    let req = sent(&press(&mut m, KeyCode::Enter));
    go(&mut m, Screen::Inventory);
    press(&mut m, KeyCode::Char('/'));
    answer(
        &mut m,
        req,
        &format!("review\taction=profile.save\tbasis={REVIEW}\n{DONE}"),
    );
    assert!(m.ask.is_none(), "no question armed away from the review");
    assert_eq!(requests(&press(&mut m, KeyCode::Char('y'))), 0);
    assert_eq!(m.detail(Kind::Items).unwrap().filter, "y");
}

/// M1 (c): choices changed after the check are checked again, never sent
/// under the old check; choices made while a save runs are kept.
#[test]
fn m1_newer_choices_are_never_lost() {
    let mut m = on(Screen::Review);
    let req = sent(&press(&mut m, KeyCode::Enter));
    go(&mut m, Screen::Inventory);
    press(&mut m, KeyCode::Down);
    press(&mut m, KeyCode::Char(' '));
    go(&mut m, Screen::Review);
    answer(
        &mut m,
        req,
        &format!("review\taction=profile.save\tbasis={REVIEW}\n{DONE}"),
    );
    assert!(m.ask.is_none(), "the check was of other choices");
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert!(
        matches!(req, Req::Validate { .. }),
        "checked again: {req:?}"
    );
    answer(
        &mut m,
        req,
        &format!("review\taction=profile.save\tbasis={REVIEW}\n{DONE}"),
    );
    let req = sent(&press(&mut m, KeyCode::Char('y')));
    assert_eq!(exec_of(&req), "profile.save");
    // A choice made while the save runs.
    go(&mut m, Screen::Inventory);
    press(&mut m, KeyCode::Char('f'));
    press(&mut m, KeyCode::Char(' '));
    assert_eq!(m.picks.len(), 2);
    answer(&mut m, req, DONE);
    assert_eq!(m.picks.len(), 1, "only what was sent is cleared");
    assert_eq!(m.picks[0].id, b"app:com.example.Thing");
}

/// M2: an execute carries what was typed, each declared name replaced by the
/// core's normal value where it gave one, and nothing it did not declare.
#[test]
fn m2_execute_replaces_typed_inputs_by_declared_normals() {
    let mut m = ready_on("macos", &mac_journey());
    go(&mut m, Screen::Plan);
    typed(&mut m, "100GB");
    for _ in 0..3 {
        press(&mut m, KeyCode::Tab);
    }
    typed(&mut m, "alex");
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(
        &mut m,
        req,
        &format!(
            "normal\tname=shared_size\tvalue=100000000000\nnormal\tname=linux_size\tvalue=250000000000\nnormal\tname=extra\tvalue=1\nreview\taction=plan.save\tbasis={REVIEW}\n{DONE}"
        ),
    );
    press(&mut m, KeyCode::Enter);
    let req = sent(&press(&mut m, KeyCode::Char('y')));
    let Req::Execute { args, .. } = &req else {
        panic!("{req:?}")
    };
    let got: Vec<(&str, &[u8])> = args
        .iter()
        .map(|(n, v)| (n.as_str(), v.as_slice()))
        .collect();
    assert_eq!(
        got,
        vec![
            ("shared_size", b"100000000000".as_slice()),
            ("linux_size", b"250000000000".as_slice()),
            ("user", b"alex".as_slice()),
        ]
    );
}

/// The profile with more items than one page holds: 501 rows in all.
fn big_items(offset: u64) -> String {
    let mut s = format!("generation\tid={PGEN}\ttotal=501\n");
    let n = if offset == 0 { 500 } else { 1 };
    for i in 0..n {
        let id = format!("brew:tool-{:03}", offset as usize + i);
        let name = id.clone();
        s.push_str(&item(
            &id,
            [
                "software", &name, "brew", "1", "pacman x", "include", "config", "default", "",
                "1", "observed", "yes",
            ],
        ));
    }
    s.push_str(DONE);
    s
}

/// M3: every page of the inventory is read before a whole category is put in
/// or out; until then Space says so and changes nothing.
#[test]
fn m3_a_whole_category_needs_every_item() {
    let mut m = ready_on("macos", &journey(""));
    let req = sent(&go(&mut m, Screen::Selection));
    let c = answer(&mut m, req, &profile());
    let req = sent(&c);
    assert_eq!(req, page(Kind::Items));
    let c = answer(&mut m, req, &big_items(0));
    let next = sent(&c);
    assert_eq!(
        next,
        Req::Detail(Page {
            kind: Kind::Items,
            generation: PGEN.into(),
            offset: 500,
            limit: 500
        }),
        "the rest is read"
    );
    assert_eq!(requests(&press(&mut m, KeyCode::Char(' '))), 0);
    assert!(m.picks.is_empty(), "nothing changes on a partial read");
    assert!(m.status.as_ref().unwrap().1.contains("500 of 501"));
    answer(&mut m, next, &big_items(500));
    press(&mut m, KeyCode::Char(' '));
    assert_eq!(m.picks.len(), 501, "every item of the category");
}

/// M4: an item's choices are read whole; "no choice" only from a whole read.
#[test]
fn m4_choices_are_read_whole() {
    let mut m = on(Screen::Inventory);
    let req = sent(&press(&mut m, KeyCode::Enter));
    let c = answer(
        &mut m,
        req,
        &format!(
            "generation\tid={PGEN}\ttotal=3\nrow\tkind=choice\tkey=brew:other\tcol=a\tcol=A\tcol=0\nrow\tkind=choice\tkey=brew:other\tcol=b\tcol=B\tcol=0\n{DONE}"
        ),
    );
    assert!(!frame(&m, 120, 40).contains("offers no choice"));
    let req = sent(&c);
    assert!(
        matches!(&req, Req::Detail(p) if p.kind == Kind::Choices && p.offset == 2),
        "{req:?}"
    );
    answer(
        &mut m,
        req,
        &format!(
            "generation\tid={PGEN}\ttotal=3\nrow\tkind=choice\tkey=cask:tailscale\tcol=flatpak\tcol=Flatpak\tcol=1\n{DONE}"
        ),
    );
    assert_eq!(m.item_choices().len(), 1);
    assert!(frame(&m, 120, 40).contains("Flatpak"));
}

/// M5: a new profile generation reads the inventory again, and a choice of
/// an item that is gone is dropped and said.
#[test]
fn m5_a_new_generation_rechecks_the_choices() {
    let mut m = on(Screen::Inventory);
    press(&mut m, KeyCode::Down);
    press(&mut m, KeyCode::Char(' '));
    assert_eq!(m.picks.len(), 1);
    const NEW: &str = "1111111111111111111111111111111111111111111111111111111111111111";
    let req = sent(&press(&mut m, KeyCode::Char('r')));
    let c = answer(&mut m, req, &profile().replace(PGEN, NEW));
    let req = sent(&c);
    assert!(
        matches!(&req, Req::Detail(p) if p.kind == Kind::Items && p.generation == NEW),
        "{req:?}"
    );
    let without = items()
        .replace(PGEN, NEW)
        .lines()
        .filter(|l| !l.contains("brew:ripgrep"))
        .map(|l| format!("{}\n", l.replace("total=5", "total=4")))
        .collect::<String>();
    answer(&mut m, req, &without);
    assert!(m.picks.is_empty(), "the gone item's choice is dropped");
    assert!(
        m.status.as_ref().unwrap().1.contains("no longer"),
        "{:?}",
        m.status
    );
}

/// M6: the document carries include or exclude only.
#[test]
fn m6_the_document_carries_only_include_or_exclude() {
    use omb_tui::read::Row;
    let row = |id: &str, state: &str| {
        let mut cols = vec![String::new(); 12];
        cols[5] = state.into();
        cols[7] = "person".into();
        Row {
            key: id.into(),
            id: id.as_bytes().to_vec(),
            cols,
        }
    };
    let doc = omb_tui::select::document(
        &[row("a", "decide"), row("b", "never"), row("c", "include")],
        &[],
    );
    assert_eq!(doc, "omb-select 1\nselect\tid=c\tstate=include\n");
}

/// M7: after a profile action the journey is read too.
#[test]
fn m7_a_profile_action_reads_the_journey_too() {
    let mut m = on(Screen::Scan);
    press(&mut m, KeyCode::Enter);
    let req = sent(&press(&mut m, KeyCode::Char('y')));
    let c = answer(&mut m, req, DONE);
    let req = sent(&c);
    assert_eq!(req, Req::Snapshot(Scope::Profile));
    let mut c = answer(&mut m, req, &profile());
    let mut seen = Vec::new();
    while requests(&c) > 0 {
        let req = sent(&c);
        seen.push(req.clone());
        let body = match &req {
            Req::Snapshot(Scope::Journey) => journey(""),
            Req::Detail(p) if p.kind == Kind::Items => items(),
            r => panic!("{r:?}"),
        };
        c = answer(&mut m, req, &body);
    }
    assert!(seen.contains(&Req::Snapshot(Scope::Journey)), "{seen:?}");
}

/// M8: a gate with more than fits keeps its label, what it does, the field
/// and the note on the screen, and scrolls the rest; the opaque list says
/// how many paths it holds.
#[test]
fn m8_the_gate_keeps_its_field_and_scrolls() {
    let mut facts = String::new();
    for i in 0..30 {
        facts.push_str(&fact(
            &format!("gate.asahi.launch.f{i:02}"),
            &format!("Fact {i:02}"),
            "a value",
            "info",
        ));
    }
    let body = reorder(&journey(&format!(
        "{facts}{}",
        action(
            "asahi.launch",
            "asahi",
            "Run the Asahi Alarm installer",
            "yes",
            true,
            BASIS
        )
    )));
    let mut m = ready_on("macos", &body);
    go(&mut m, Screen::Install);
    press(&mut m, KeyCode::Enter);
    assert_eq!(m.screen, Screen::Gate);
    typed(&mut m, "no");
    press(&mut m, KeyCode::Enter);
    for (w, h) in [(120, 40), (80, 24), (60, 20)] {
        let f = frame(&m, w, h);
        for want in [
            "Run the Asahi Alarm installer",
            "Does",
            "Type yes to continue",
            "Only the exact word",
        ] {
            assert!(f.contains(want), "{want:?} at {w}x{h}:\n{f}");
        }
        assert!(!f.contains("Fact 29"), "{w}x{h}");
    }
    press(&mut m, KeyCode::End);
    assert!(frame(&m, 60, 20).contains("Fact 29"), "the facts scroll");
    assert_eq!(m.gate_input, "no", "the moving keys are not text");
    // The opaque list: its count, from a whole read.
    let mut m = on(Screen::Review);
    press(&mut m, KeyCode::Down);
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(
        &mut m,
        req,
        &format!(
            "generation\tid={PGEN}\ttotal=2\nrow\tkind=opaque\tkey=path:a\tcol=~/a\tcol=1\nrow\tkind=opaque\tkey=path:b\tcol=~/b\tcol=1\n{DONE}"
        ),
    );
    assert!(frame(&m, 80, 24).contains("2 paths"));
}

/// M9: the item's choices stay on the screen at the 60x20 floor.
#[test]
fn m9_the_item_view_fits_the_floor() {
    let mut m = on(Screen::Inventory);
    let req = sent(&press(&mut m, KeyCode::Enter));
    let mut body = format!("generation\tid={PGEN}\ttotal=6\n");
    for i in 0..6 {
        body.push_str(&format!(
            "row\tkind=choice\tkey=cask:tailscale\tcol=c{i}\tcol=Choice%20number%20{i}\tcol=0\n"
        ));
    }
    body.push_str(DONE);
    answer(&mut m, req, &body);
    for _ in 0..5 {
        press(&mut m, KeyCode::Down);
    }
    let f = frame(&m, 60, 20);
    assert!(f.contains("❯ ○ Choice number 5"), "{f}");
}

/// M10 and M11: the legend lists each region the core sent, never a sum; and
/// macOS and Linux are told apart by more than colour.
#[test]
fn m10_m11_each_region_and_its_letter() {
    let regions = "region\tstart=0\tsize=400000000000\trole=macos\tlabel=\n\
                   region\tstart=400000000000\tsize=20000000000\trole=free\tlabel=\n\
                   region\tstart=420000000000\tsize=250000000000\trole=linux\tlabel=\n\
                   region\tstart=670000000000\tsize=30000000000\trole=free\tlabel=\n";
    let body = journey(&format!(
        "{regions}{}",
        action(
            "shared.create",
            "shared",
            "Create Shared storage",
            "yes",
            true,
            BASIS
        )
    ));
    let mut m = ready_on("macos", &body);
    press(&mut m, KeyCode::Enter);
    assert_eq!(m.screen, Screen::Shared);
    let f = frame(&m, 120, 40);
    assert!(f.contains("free 20 GB") && f.contains("free 30 GB"), "{f}");
    assert!(!f.contains("free 50 GB"), "never a sum:\n{f}");
    let bar = f.lines().find(|l| l.contains('▕')).unwrap();
    assert!(bar.contains('M') && bar.contains('L'), "{bar}");
}

/// M12: the save's check shows the core's warnings before the question.
#[test]
fn m12_the_saves_warnings_come_first() {
    let mut m = on(Screen::Review);
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(
        &mut m,
        req,
        &format!(
            "warning\tid=opaque-pending\ttext=Two%20chosen%20folders%20wait%20for%20opaque.\tfix=Type%20opaque%20next.\nreview\taction=profile.save\tbasis={REVIEW}\n{DONE}"
        ),
    );
    let f = frame(&m, 120, 40);
    assert!(
        f.contains("Two chosen folders wait for opaque.") && f.contains("Type opaque next."),
        "{f}"
    );
}

/// M13: the Install page's Enter runs only the action the page describes;
/// with no hello there is no page action at all.
#[test]
fn m13_the_install_page_runs_only_its_own_action() {
    let body = journey(&action(
        "omarchy.start",
        "omarchy",
        "Run omarchy-mac-setup",
        "start",
        true,
        BASIS,
    ));
    let mut m = ready_on("macos", &body);
    go(&mut m, Screen::Install);
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    assert_eq!(
        m.screen,
        Screen::Install,
        "no gate for an action the page does not show"
    );
    // A snapshot without hello's system: no page, and Enter runs nothing.
    let body = journey(&action(
        "asahi.launch",
        "asahi",
        "Run the Asahi Alarm installer",
        "yes",
        true,
        BASIS,
    ));
    let mut m = ready_on("macos", &body);
    m.hello = None;
    go(&mut m, Screen::Install);
    let f = frame(&m, 120, 40);
    assert!(
        !f.contains("Asahi handoff") && f.contains("has not said which system"),
        "{f}"
    );
    assert_eq!(requests(&press(&mut m, KeyCode::Enter)), 0);
    assert_eq!(m.screen, Screen::Install);
}

/// L1: the same names with new definitions take them, and a review of other
/// fields is dropped.
#[test]
fn l1_a_form_takes_the_cores_newer_definitions() {
    let declare = |ty: &str| {
        journey(&format!(
            "{}param\taction=shared.code\tname=code\ttype={ty}\tkind=ombdone\trequired=1\n",
            action("shared.code", "shared", "Enter the code", "", false, "")
        ))
    };
    let mut m = ready_on("macos", &declare("code"));
    press(&mut m, KeyCode::Enter);
    assert_eq!(m.form.fields[0].ty, "code");
    press(&mut m, KeyCode::Esc);
    answer(&mut m, Req::Snapshot(Scope::Journey), &declare("text"));
    press(&mut m, KeyCode::Enter);
    assert_eq!(m.form.fields[0].ty, "text");
}

/// L2: a value past the field's limit is said, never silently cut short of
/// what a request carries.
#[test]
fn l2_a_long_value_is_kept_and_a_cut_is_said() {
    let mut m = ready_on("macos", &mac_journey());
    go(&mut m, Screen::Plan);
    let long = "x".repeat(300);
    typed(&mut m, &long);
    assert_eq!(m.plan.fields[0].value.len(), 300);
}

/// L5 and L6: choices pass through the ASCII rewrite; only the two sizes are
/// named by the frontend, the rest by their parameter names.
#[test]
fn l5_l6_choices_in_ascii_and_names_as_declared() {
    let body = journey(&format!(
        "{}param\taction=plan.save\tname=enc\ttype=choice\tkind=\trequired=0\tchoice=on\tchoice=off\n",
        action("plan.save", "plan", "Save the plan", "", false, "")
    ));
    let mut m = ready_on("macos", &body);
    go(&mut m, Screen::Plan);
    let f = text_of(&render(&m, &theme("ascii"), 80, 24));
    assert!(f.contains("enc") && !f.contains("Encryption"), "{f}");
}

/// L7: the Progress page's Enter says it offers no action.
#[test]
fn l7_progress_offers_no_action() {
    let mut m = ready_on("linux", &journey(""));
    go(&mut m, Screen::Progress);
    press(&mut m, KeyCode::Enter);
    assert!(
        m.status.as_ref().unwrap().1.contains("offers no action"),
        "{:?}",
        m.status
    );
}

/// The plan's check says it saved nothing, also where plan.save is listed.
#[test]
fn a_check_says_it_saved_nothing() {
    let mut m = ready_on("macos", &mac_journey());
    go(&mut m, Screen::Plan);
    typed(&mut m, "100GB");
    let req = sent(&press(&mut m, KeyCode::Enter));
    answer(&mut m, req, &plan_review());
    assert!(frame(&m, 120, 70).contains("nothing was saved"));
}
