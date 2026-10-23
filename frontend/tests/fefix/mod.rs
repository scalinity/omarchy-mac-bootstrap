//! The phase C frontend review's confirmed defects, one state or frame test
//! each: every one fails on the code the review read and holds after its
//! fix. They are driven only through the model's boundary, keys and answers
//! in, requests and frames out.

use super::actions::{
    BASIS, DONE, action, answer, enc, frame, go, mac_journey, plan_review, press, ready_on, render,
    requests, sent, text_of, theme, typed,
};
use super::migration;
use super::{phase_b, phase_c};
use omb_tui::app::{Cmd, Model, Msg, NAV, Outcome, Region, Req, Screen, update};
use omb_tui::read::{Fault, Scope};
use ratatui::crossterm::event::KeyCode;

fn terminate(m: &mut Model) -> Vec<Cmd> {
    update(m, Msg::Terminate)
}

fn done(m: &mut Model, req: Req, o: Outcome) -> Vec<Cmd> {
    update(m, Msg::Done(req, o))
}

fn quit() -> Vec<Cmd> {
    vec![Cmd::Quit(0, String::new())]
}

// ── 1. one request at a time ────────────────────────────────────────────

/// A macOS journey that offers the planner's save, a plain act that runs
/// without the terminal, and the stations.
fn busy_journey() -> String {
    // The schema's record order: stages follow the generation, and the
    // actions are consecutive, before the parameters.
    let base = mac_journey();
    let mut lines = base.lines();
    let mut s = format!("{}\n", lines.next().unwrap());
    for l in phase_c::stages("verify").lines() {
        if l.starts_with("stage\t") {
            s.push_str(l);
            s.push('\n');
        }
    }
    for l in lines {
        if l.starts_with("param\t") && !s.contains("id=disk.survey") {
            s.push_str(&action(
                "disk.survey",
                "journey",
                "Survey the disk",
                "",
                false,
                BASIS,
            ));
        }
        s.push_str(l);
        s.push('\n');
    }
    s
}

/// The plain act, asked and answered `y`: a request that runs to its end.
fn running_act(m: &mut Model) -> Req {
    m.focus = m
        .snap
        .as_ref()
        .unwrap()
        .actions
        .iter()
        .position(|a| a.id == "disk.survey")
        .unwrap();
    assert_eq!(requests(&press(m, KeyCode::Enter)), 0, "asked first");
    let req = sent(&press(m, KeyCode::Char('y')));
    assert!(
        matches!(req, Req::Execute { handoff: false, .. }),
        "{req:?}"
    );
    assert!(m.pending.is_some());
    req
}

/// The rail to the Plan, then the key that opens it.
fn from_the_rail(m: &mut Model, open: KeyCode) -> Vec<Cmd> {
    let n = NAV.iter().position(|x| *x == Screen::Plan).unwrap();
    press(m, KeyCode::Left);
    for _ in 0..NAV.len() {
        press(m, KeyCode::Up);
    }
    for _ in 0..n {
        press(m, KeyCode::Down);
    }
    press(m, open)
}

/// `[` and `]` to the Plan's station, then Enter.
fn from_the_station(m: &mut Model) -> Vec<Cmd> {
    for _ in 0..12 {
        if m.station == Some(3) {
            break;
        }
        press(
            m,
            if m.station.is_some_and(|s| s > 3) {
                KeyCode::Char('[')
            } else {
                KeyCode::Char(']')
            },
        );
    }
    assert_eq!(m.station, Some(3), "the Plan's station");
    press(m, KeyCode::Enter)
}

fn is_plan_check(req: &Req) -> bool {
    matches!(req, Req::Validate { action, .. } if action == "plan.save")
}

/// The first visit to the planner sends its check; with another request in
/// flight it waits for it instead of replacing it, by each route to the
/// Plan, and then sends the check exactly once.
#[test]
fn the_planners_first_check_waits_for_the_request_in_flight() {
    type Route = fn(&mut Model) -> Vec<Cmd>;
    let routes: [(&str, Route); 3] = [
        ("the rail, Enter", |m| from_the_rail(m, KeyCode::Enter)),
        ("the rail, Right", |m| from_the_rail(m, KeyCode::Right)),
        ("a station, Enter", from_the_station),
    ];
    for (name, route) in routes {
        let mut m = ready_on("macos", &busy_journey());
        let act = running_act(&mut m);
        let cmds = route(&mut m);
        assert_eq!(m.screen, Screen::Plan, "{name}");
        assert_eq!(requests(&cmds), 0, "{name}: {cmds:?}");
        assert_eq!(
            m.pending.as_ref().map(|p| &p.req),
            Some(&act),
            "{name}: the request in flight is still the one followed"
        );
        assert!(m.plan.due, "{name}: the check is owed");
        let f = frame(&m, 120, 40);
        assert!(f.contains("as soon as the request"), "{name}:\n{f}");
        // Typing meanwhile starts nothing either.
        assert_eq!(requests(&press(&mut m, KeyCode::Tab)), 0, "{name}");

        // Its own follow-up read comes first: an action is followed to its
        // end before anything else starts.
        let c = answer(&mut m, act, DONE);
        assert_eq!(sent(&c), Req::Snapshot(Scope::Journey), "{name}");
        // That read settles, and only then is the check sent, once.
        let c = answer(&mut m, Req::Snapshot(Scope::Journey), &busy_journey());
        let check = sent(&c);
        assert!(is_plan_check(&check), "{name}: {check:?}");
        assert!(!m.plan.due, "{name}");
        let c = answer(&mut m, check, &plan_review());
        assert_eq!(requests(&c), 0, "{name}: the check is not repeated");
        assert!(m.plan.current(), "{name}: the answer is for these sizes");
    }
}

/// A read in flight holds the check back the same way.
#[test]
fn a_read_in_flight_holds_the_planners_first_check_back() {
    let mut m = ready_on("macos", &busy_journey());
    let read = sent(&press(&mut m, KeyCode::Char('r')));
    assert_eq!(read, Req::Snapshot(Scope::Journey));
    let c = go(&mut m, Screen::Plan);
    assert_eq!(requests(&c), 0, "{c:?}");
    let c = answer(&mut m, read, &busy_journey());
    let check = sent(&c);
    assert!(is_plan_check(&check), "{check:?}");
    assert_eq!(requests(&answer(&mut m, check, &plan_review())), 0);
}

/// Leaving the Plan before the owed check is sent keeps it owed; it is sent
/// when the screen is shown again and nothing is pending, never from
/// another screen.
#[test]
fn an_owed_check_is_sent_only_from_the_plan() {
    let mut m = ready_on("macos", &busy_journey());
    let act = running_act(&mut m);
    go(&mut m, Screen::Plan);
    press(&mut m, KeyCode::Esc);
    assert_eq!(m.screen, Screen::Dashboard);
    let c = answer(&mut m, act, DONE);
    let c = answer(&mut m, sent(&c), &busy_journey());
    assert_eq!(requests(&c), 0, "{c:?}");
    assert!(m.plan.due);
    let check = sent(&go(&mut m, Screen::Plan));
    assert!(is_plan_check(&check), "{check:?}");
}

/// The audit: with a request pending, no key on any screen starts another,
/// and the request followed stays the one in flight.
#[test]
fn no_key_on_any_screen_starts_a_second_request() {
    let keys = [
        KeyCode::Enter,
        KeyCode::Char('r'),
        KeyCode::Char('c'),
        KeyCode::Char('t'),
        KeyCode::Char('n'),
        KeyCode::Char('d'),
        KeyCode::Char('f'),
        KeyCode::Char('y'),
        KeyCode::Char(' '),
        KeyCode::Char('/'),
        KeyCode::Char('L'),
        KeyCode::Char('['),
        KeyCode::Char(']'),
        KeyCode::Right,
        KeyCode::Left,
        KeyCode::Down,
        KeyCode::Up,
        KeyCode::Tab,
        KeyCode::PageDown,
        KeyCode::End,
        KeyCode::Home,
        KeyCode::Esc,
    ];
    let mut m = ready_on("macos", &busy_journey());
    let act = running_act(&mut m);
    for s in NAV {
        let c = go(&mut m, s);
        assert_eq!(requests(&c), 0, "{s:?}: {c:?}");
        for k in keys {
            let c = press(&mut m, k);
            assert_eq!(requests(&c), 0, "{s:?} {k:?}: {c:?}");
        }
        assert_eq!(m.pending.as_ref().map(|p| &p.req), Some(&act), "{s:?}");
        m.screen = Screen::Dashboard;
        m.region = Region::Work;
        m.ask = None;
        m.gate = None;
    }
}

// ── 3. a quit asked for during a request wins over its answer ───────────

type Setup = fn() -> (Model, Req);

/// A restore check in flight, on the Restore screen.
fn restore_check() -> (Model, Req) {
    let mut m = phase_b::on();
    press(&mut m, KeyCode::Home);
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert!(matches!(&req, Req::Validate { action, .. } if action == "restore.apply"));
    (m, req)
}

/// The planner's first check in flight.
fn plan_check() -> (Model, Req) {
    let mut m = ready_on("macos", &mac_journey());
    let req = sent(&go(&mut m, Screen::Plan));
    assert!(is_plan_check(&req));
    (m, req)
}

/// A save of migration choices being checked, on the Review.
fn profile_check() -> (Model, Req) {
    let mut m = migration::on(Screen::Review);
    go(&mut m, Screen::Inventory);
    press(&mut m, KeyCode::Down);
    press(&mut m, KeyCode::Char(' '));
    go(&mut m, Screen::Review);
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert!(matches!(&req, Req::Validate { action, .. } if action == "profile.save"));
    (m, req)
}

/// Another action's parameters being checked, on its form.
fn form_check() -> (Model, Req) {
    let body = format!(
        "generation\tid={}\ttotal=0\n{}param\taction=export.run\tname=dir\ttype=text\tkind=\trequired=1\n{DONE}",
        super::actions::GEN,
        action("export.run", "export", "Export the profile", "", false, "")
    );
    let mut m = ready_on("macos", &body);
    press(&mut m, KeyCode::Enter);
    assert_eq!(m.screen, Screen::Form);
    typed(&mut m, "/tmp/out");
    let req = sent(&press(&mut m, KeyCode::Enter));
    assert!(matches!(&req, Req::Validate { action, .. } if action == "export.run"));
    (m, req)
}

/// The core's answer to REQ with BODY after its hello, admitted as the
/// frontend admits it.
fn answered(req: &Req, body: &str) -> Outcome {
    let text = format!("omb-res 1\n{}{body}", super::actions::hello_line("macos"));
    let doc = omb_tui::record::admit(
        omb_tui::record::Family::Res,
        Some(omb_tui::core::op_of(req)),
        text.as_bytes(),
    )
    .unwrap_or_else(|e| panic!("{e:?}\n{text}"));
    Outcome::Answer(doc.records)
}

const CHANGED: &str = "result\tstatus=refused\tcode=changed\ttext=\tnext=\n";

fn answers(req: &Req) -> Vec<(&'static str, Outcome)> {
    let ok = match req {
        Req::Validate { action, .. } if action == "plan.save" => plan_review(),
        Req::Validate { action, .. } => format!(
            "review\taction={action}\tbasis={}\n{DONE}",
            super::actions::REVIEW
        ),
        r => panic!("{r:?}"),
    };
    vec![
        ("ok", answered(req, &ok)),
        ("refused as changed", answered(req, CHANGED)),
        ("no complete answer", Outcome::Unknown("exit 1".into())),
        ("not delivered", Outcome::NotSent("EPIPE".into())),
    ]
}

/// A terminate (SIGTERM, SIGHUP, a lost terminal) or `q` then `y` during an
/// in-flight check of each kind: whatever the answer is, and whenever it
/// arrives after the cancel, the frontend quits and starts nothing.
#[test]
fn a_quit_asked_for_during_a_check_wins_over_its_answer() {
    let checks: [(&str, Setup); 4] = [
        ("restore.apply", restore_check),
        ("plan", plan_check),
        ("profile", profile_check),
        ("export", form_check),
    ];
    for (kind, setup) in checks {
        let (probe, req) = setup();
        drop(probe);
        for (answer_name, _) in answers(&req) {
            for how in ["terminate", "q then y"] {
                let (mut m, req) = setup();
                let first = if how == "terminate" {
                    terminate(&mut m)
                } else {
                    // A field has the keys on the planner and the form: the
                    // person leaves it first, as the footer says.
                    if matches!(m.screen, Screen::Plan | Screen::Form) {
                        press(&mut m, KeyCode::Esc);
                    }
                    assert_eq!(requests(&press(&mut m, KeyCode::Char('q'))), 0);
                    press(&mut m, KeyCode::Char('y'))
                };
                assert!(m.quit_after, "{kind} {how}");
                assert!(
                    first.iter().all(|c| matches!(c, Cmd::Cancel)),
                    "{kind} {how}: {first:?}"
                );
                let outcome = answers(&req)
                    .into_iter()
                    .find(|(n, _)| *n == answer_name)
                    .unwrap()
                    .1;
                let c = done(&mut m, req, outcome);
                assert_eq!(
                    c,
                    quit(),
                    "{kind} {how}, answered {answer_name}: the session must end"
                );
            }
        }
    }
}

/// A quit asked for while a restore runs ends the session when its result
/// is in, even a refusal that sends the person back to re-read conflicts.
#[test]
fn a_quit_during_a_restore_wins_over_a_stale_review() {
    let (mut m, req) = restore_check();
    let ok = format!(
        "review\taction=restore.apply\tbasis={}\n{DONE}",
        super::actions::REVIEW
    );
    let outcome = answered(&req, &ok);
    done(&mut m, req, outcome);
    assert_eq!(m.screen, Screen::Gate);
    typed(&mut m, "restore");
    let exec = sent(&press(&mut m, KeyCode::Enter));
    assert!(matches!(exec, Req::Execute { handoff: true, .. }));
    // A handoff cannot be cancelled: the terminate waits for its result.
    assert!(terminate(&mut m).is_empty());
    let refused = answered(&exec, CHANGED);
    assert_eq!(done(&mut m, exec, refused), quit());
}

// ── 4. the unit selector stays with its field ───────────────────────────

/// Tab onto a custom size's unit, Up or Down to the other size: the digits
/// typed there go into that size, not nowhere.
#[test]
fn moving_between_sizes_leaves_the_unit_selector() {
    let mut m = ready_on("macos", &mac_journey());
    let req = sent(&go(&mut m, Screen::Plan));
    answer(&mut m, req, &plan_review());
    let size = |m: &mut Model, si: usize| {
        for _ in 0..8 {
            if m.plan.custom[si] {
                return;
            }
            render(m, &theme("color"), 120, 40);
            let req = sent(&press(m, KeyCode::Right));
            answer(m, req, &plan_review());
        }
        panic!("size {si} never reached Custom");
    };
    let linux = m.plan.field;
    assert_eq!(m.plan.fields[linux].name, "linux_size");
    size(&mut m, 0);
    render(&m, &theme("color"), 120, 40);
    press(&mut m, KeyCode::Down);
    let shared = m.plan.field;
    assert_eq!(m.plan.fields[shared].name, "shared_size");
    size(&mut m, 1);
    render(&m, &theme("color"), 120, 40);
    press(&mut m, KeyCode::Up);
    assert_eq!(m.plan.field, linux);
    press(&mut m, KeyCode::Tab);
    assert!(m.plan.unit_focus, "Tab selects the unit");
    render(&m, &theme("color"), 120, 40);
    press(&mut m, KeyCode::Down);
    assert_eq!(m.plan.field, shared);
    assert!(!m.plan.unit_focus, "the unit stays with the Linux size");
    let before = m.plan.fields[shared].value.clone();
    typed(&mut m, "5");
    assert_eq!(
        m.plan.fields[shared].value,
        format!("{}5GB", before.trim_end_matches("GB")),
        "the digit goes into the Shared size"
    );
}

// ── 5. t says why it does nothing ───────────────────────────────────────

/// `t` is advertised in the footer on the Qualification screen: where the
/// core lists no step to run, or the steps are not read in full, it says so.
#[test]
fn t_on_the_qualification_screen_says_why_it_does_nothing() {
    let mut m = phase_c::on_qualify("waiting-for-linux");
    assert!(m.offered(Scope::Qualify, "qualify.run").is_none());
    assert_eq!(requests(&press(&mut m, KeyCode::Char('t'))), 0);
    let (_, said) = m.status.clone().expect("a dead key says why");
    assert!(
        said.contains("Nothing on this page is offered now"),
        "the words other pages use: {said}"
    );
    assert_eq!(m.screen, Screen::Qualification);

    let mut m = phase_c::on_qualify("not-started");
    m.qualify.fault = Some(Fault::NoAnswer("exit 1".into()));
    m.status = None;
    press(&mut m, KeyCode::Char('t'));
    let (_, said) = m.status.clone().expect("a dead key says why");
    assert!(said.contains("not read in full"), "{said}");
    assert_eq!(m.screen, Screen::Qualification);

    // Offered, and read whole: the gate, as before.
    let mut m = phase_c::on_qualify("not-started");
    press(&mut m, KeyCode::Char('t'));
    assert_eq!(m.screen, Screen::Gate);
}

// ── 2. what the owner types is shown as the core gave it ────────────────

const TOKEN: &str = "omb2:enc=1,user=alex,host=m1pro,kmap=us,tz=America/New_York,loc=en_US.UTF-8,ssh=0,gh=octocat,linux=250,shared=150,dev=1,plan=1a2b3c4d";
const NAMED_AFTER_SYSTEMS: &str = "omb2:enc=1,user=linux,host=macos,kmap=us,tz=America/New_York,loc=en_US.UTF-8,ssh=0,gh=octocat,linux=250,shared=150,dev=1,plan=1a2b3c4d";
const DONE_CODE: &str = "ombdone-1a2b3c4d-8f2a41c0e9b7-f5f0";
const SHARE_CODE: &str = "ombshare-1a2b3c4d-8f2a41c0e9b7-ef34";

fn journey_with(codes: &[(&str, &str)]) -> String {
    // The codes sit where the schema puts them: before the actions.
    let mut s = String::new();
    let mut put = false;
    for l in mac_journey().lines() {
        if l.starts_with("code\t") {
            continue;
        }
        if l.starts_with("action\t") && !put {
            put = true;
            for (kind, value) in codes {
                s.push_str(&format!("code\tkind={kind}\tvalue={}\n", enc(value)));
            }
        }
        s.push_str(l);
        s.push('\n');
    }
    s
}

/// The value shown beside LABEL: the text after the label on its row, then
/// each row under it that has no label, as the owner would read it off the
/// screen. FIRST is the start of the value.
fn shown(f: &str, label: &str, first: &str) -> String {
    let lines: Vec<Vec<char>> = f.lines().map(|l| l.chars().collect()).collect();
    let at = |l: &[char], needle: &str| {
        let n: Vec<char> = needle.chars().collect();
        (0..l.len().saturating_sub(n.len() - 1)).find(|i| l[*i..*i + n.len()] == n[..])
    };
    let chunk = |l: &[char], x: usize| -> String {
        l[x.min(l.len())..]
            .iter()
            .take_while(|c| !matches!(**c, '│' | '|'))
            .collect::<String>()
            .trim_end()
            .to_string()
    };
    // The row holds the label and, after it, the start of the value; a
    // heading of the same name holds only the label.
    let start = |l: &[char]| -> Option<usize> {
        (0..l.len())
            .rev()
            .find(|x| l[*x..].iter().collect::<String>().starts_with(first))
    };
    let (y, x_label, x0) = lines
        .iter()
        .enumerate()
        .find_map(|(y, l)| {
            let x_label = at(l, label)?;
            let x0 = start(l).filter(|x| *x > x_label)?;
            Some((y, x_label, x0))
        })
        .unwrap_or_else(|| panic!("no row of {label:?} with a value from {first:?}:\n{f}"));
    let mut out = chunk(&lines[y], x0);
    for l in &lines[y + 1..] {
        let blank_label = l.len() > x0 && l[x_label..x0].iter().all(|c| *c == ' ');
        let piece = chunk(l, x0);
        if !blank_label || piece.is_empty() {
            break;
        }
        out.push_str(&piece);
    }
    out
}

/// Every code and the resume token, on the dashboard and the install pages,
/// at several widths (narrow enough that they wrap) and in every profile,
/// read off the screen byte for byte as the core gave them.
#[test]
fn codes_and_the_resume_token_are_shown_exactly_as_the_core_gave_them() {
    for token in [TOKEN, NAMED_AFTER_SYSTEMS] {
        let codes = [
            ("token", token),
            ("ombdone", DONE_CODE),
            ("ombshare", SHARE_CODE),
        ];
        let body = journey_with(&codes);
        let mut mac = ready_on("macos", &body);
        let mut linux = ready_on("linux", &body);
        go(&mut linux, Screen::Install);
        let dashboard = mac.screen;
        assert_eq!(dashboard, Screen::Dashboard);
        let mut install = ready_on("macos", &body);
        go(&mut install, Screen::Install);
        assert_eq!(install.screen, Screen::Install);
        for profile in ["color", "ascii"] {
            for w in [120u16, 100, 80, 60] {
                let on = |m: &Model| text_of(&render(m, &theme(profile), w, 120));
                let dash = on(&mac);
                let ins = on(&install);
                let lin = on(&linux);
                for (page, f) in [("dashboard", &dash), ("install", &ins), ("linux", &lin)] {
                    assert_eq!(
                        shown(f, "Resume token", "omb2:"),
                        token,
                        "{page} {profile} {w}:\n{f}"
                    );
                }
                for (kind, code) in &codes[1..] {
                    assert_eq!(
                        shown(&dash, kind, &format!("{kind}-")),
                        *code,
                        "dashboard {profile} {w}:\n{dash}"
                    );
                }
            }
        }
        mac.screen = Screen::Dashboard;
    }
}

/// The user name the core reports is a name, not a platform: a user called
/// `linux` is shown as `linux`, while the platform beside it still reads
/// macOS.
#[test]
fn the_welcome_page_shows_the_user_name_as_it_is() {
    let mut m = ready_on("macos", &mac_journey());
    m.hello.as_mut().unwrap().user = "linux".into();
    m.screen = Screen::Welcome;
    for profile in ["color", "ascii"] {
        let f = text_of(&render(&m, &theme(profile), 100, 40));
        assert!(f.contains("macOS, arm64, linux"), "{profile}:\n{f}");
    }
    m.hello.as_mut().unwrap().user = "alex".into();
    let f = frame(&m, 100, 40);
    assert!(f.contains("macOS, arm64, alex"), "{f}");
}
