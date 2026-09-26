//! Layers B–E (docs/TESTING.md → *Layers*): the foundation's screens —
//! the dashboard (2) and the gate (13) — and its states (connecting, handoff
//! result, unsupervised barrier, the core's failure, logs, help, too small),
//! rendered with TestBackend at 120×40, 100×30, 80×24, 60×24 and 59×20;
//! snapshots of the text (insta, which carries no colour); styles asserted on
//! the buffer; and every degraded profile (16 colours, no colour, ASCII).

use omb_tui::app::{Cmd, Model, Msg, Outcome, Req, Screen, update};
use omb_tui::record::Record;
use omb_tui::screens;
use omb_tui::theme::{Caps, Depth, Theme, Token};
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use ratatui::buffer::Buffer;
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers};
use ratatui::style::{Color, Modifier};

fn rec(ty: &str, f: &[(&str, &str)]) -> Record {
    Record {
        ty: ty.into(),
        fields: f
            .iter()
            .map(|(k, v)| (k.to_string(), v.as_bytes().to_vec()))
            .collect(),
    }
}
fn result(status: &str, code: &str, text: &str) -> Record {
    rec(
        "result",
        &[
            ("status", status),
            ("code", code),
            ("text", text),
            ("next", ""),
        ],
    )
}
fn action(id: &str, label: &str, gate: &str, handoff: bool, explain: &str) -> Record {
    rec(
        "action",
        &[
            ("id", id),
            ("scope", "journey"),
            ("label", label),
            ("intent", if gate.is_empty() { "read" } else { "act" }),
            ("gate", gate),
            ("terminal", if handoff { "handoff" } else { "managed" }),
            ("cancel", if gate.is_empty() { "1" } else { "0" }),
            ("basis", &"5f2e".repeat(16)),
            ("explain", explain),
        ],
    )
}
fn key(c: KeyCode) -> Msg {
    Msg::Key(KeyEvent {
        code: c,
        modifiers: KeyModifiers::NONE,
        kind: KeyEventKind::Press,
        state: KeyEventState::NONE,
    })
}

/// The dashboard as the core in fixture mode describes it.
fn dashboard(barrier: bool) -> Model {
    let mut m = Model::default();
    m.start();
    let hello = rec(
        "hello",
        &[
            ("core", "0.2.0"),
            ("platform", "macos"),
            ("arch", "arm64"),
            ("user", "user"),
            ("ceiling", "act"),
            ("dry_run", "0"),
            ("fixture", "1"),
        ],
    );
    update(
        &mut m,
        Msg::Done(
            Req::Hello,
            Outcome::Answer(vec![hello, result("done", "ok", "")]),
        ),
    );
    let mut snap = vec![
        rec(
            "fact",
            &[
                ("scope", "journey"),
                ("key", "foundation"),
                ("label", "Interface"),
                ("value", "the foundation: test actions over fixtures"),
                ("state", "info"),
            ],
        ),
        rec(
            "fact",
            &[
                ("scope", "journey"),
                ("key", "fixture"),
                ("label", "Fixture"),
                ("value", "mac-m1pro-1tb-roomy"),
                ("state", "info"),
            ],
        ),
    ];
    if barrier {
        snap.push(rec(
            "fact",
            &[
                ("scope", "journey"),
                ("key", "operation"),
                ("label", "Operation"),
                ("value", "test.mutate unsupervised"),
                ("state", "fail"),
            ],
        ));
        snap.push(rec(
            "blocker",
            &[
                ("id", "unsupervised"),
                ("text", "The outcome of test.mutate is unknown and a process it started may still be running."),
                ("fix", "Restart this Mac (or this Linux system), then run the tool again."),
            ],
        ));
        snap.push(action(
            "test.read",
            "Read the fixture (test)",
            "",
            false,
            "Runs the fake read child.",
        ));
    } else {
        snap.push(rec(
            "fact",
            &[
                ("scope", "journey"),
                ("key", "operation"),
                ("label", "Operation"),
                ("value", "none"),
                ("state", "ok"),
            ],
        ));
        snap.push(action("test.read", "Read the fixture (test)", "", false, "Runs the fake read child: its output is shown, its diagnostics kept within their limits."));
        snap.push(action(
            "test.mutate",
            "Change the fixture (test)",
            "test",
            false,
            "Runs the fake mutating child under supervision.",
        ));
        snap.push(action(
            "test.handoff",
            "Hand over the terminal (test)",
            "test",
            true,
            "Runs the fake handoff child on the real terminal.",
        ));
    }
    snap.push(result("done", "ok", ""));
    update(&mut m, Msg::Done(Req::Snapshot, Outcome::Answer(snap)));
    assert_eq!(m.screen, Screen::Dashboard);
    m
}

fn profile(name: &str) -> Theme {
    let caps = match name {
        "color" => Caps {
            depth: Depth::Full,
            unicode: true,
            console: false,
        },
        "sixteen" => Caps {
            depth: Depth::Sixteen,
            unicode: true,
            console: false,
        },
        "nocolor" => Caps {
            depth: Depth::None,
            unicode: true,
            console: false,
        },
        "ascii" => Caps {
            depth: Depth::Sixteen,
            unicode: false,
            console: true,
        },
        _ => unreachable!(),
    };
    Theme::new(caps)
}

fn render(m: &Model, t: &Theme, w: u16, h: u16) -> Buffer {
    let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
    term.draw(|f| screens::draw(f, m, t, 50)).unwrap();
    term.backend().buffer().clone()
}

fn text(b: &Buffer) -> String {
    let mut out = String::new();
    for y in 0..b.area.height {
        let mut line = String::new();
        for x in 0..b.area.width {
            line.push_str(b[(x, y)].symbol());
        }
        out.push_str(line.trim_end());
        out.push('\n');
    }
    out
}

const SIZES: [(u16, u16); 5] = [(120, 40), (100, 30), (80, 24), (60, 24), (59, 20)];

/// Layer B and C: the dashboard at every size, as text.
#[test]
fn dashboard_at_every_size() {
    let m = dashboard(false);
    for (w, h) in SIZES {
        let b = render(&m, &profile("color"), w, h);
        insta::assert_snapshot!(format!("dashboard_{w}x{h}"), text(&b));
    }
}

#[test]
fn the_barrier_at_80x24_and_60x24() {
    let m = dashboard(true);
    for (w, h) in [(80, 24), (60, 24)] {
        insta::assert_snapshot!(
            format!("barrier_{w}x{h}"),
            text(&render(&m, &profile("color"), w, h))
        );
    }
}

/// The gate (13): a typed-word field and no button, at every size.
#[test]
fn the_gate_at_every_size() {
    let mut m = dashboard(false);
    update(&mut m, key(KeyCode::Down));
    update(&mut m, key(KeyCode::Enter));
    for c in "tes".chars() {
        update(&mut m, key(KeyCode::Char(c)));
    }
    assert_eq!(m.screen, Screen::Gate);
    for (w, h) in [(120, 40), (80, 24), (60, 24)] {
        insta::assert_snapshot!(
            format!("gate_{w}x{h}"),
            text(&render(&m, &profile("color"), w, h))
        );
    }
    // An inexact word: said, nothing sent.
    let cmds = update(&mut m, key(KeyCode::Enter));
    assert!(cmds.is_empty());
    let t = text(&render(&m, &profile("color"), 80, 24));
    assert!(t.contains("Only the exact word \"test\" continues."), "{t}");
}

/// Below 60×20: the truthful stop, and nothing else.
#[test]
fn too_small_says_how_small() {
    let m = dashboard(false);
    for (w, h, want) in [
        (59, 20, "terminal too small — needs 60x20, this is 59x20"),
        (80, 19, "terminal too small — needs 60x20, this is 80x19"),
        (54, 18, "terminal too small — needs 60x20, this is 54x18"),
    ] {
        let t = text(&render(&m, &profile("color"), w, h));
        assert!(t.contains(want), "{t}");
        assert_eq!(
            t.lines().filter(|l| !l.trim().is_empty()).count(),
            1,
            "nothing else is drawn:\n{t}"
        );
    }
}

/// The states every screen has, at 80×24.
#[test]
fn the_foundations_states() {
    let t = profile("color");
    // Connecting, before the handshake.
    let mut m = Model::default();
    m.start();
    insta::assert_snapshot!("connecting_80x24", text(&render(&m, &t, 80, 24)));
    // A request running: a spinner only after 150 ms, elapsed after 2 s.
    let mut m = dashboard(false);
    update(&mut m, key(KeyCode::Enter));
    assert!(m.pending.is_some());
    let s = text(&render(&m, &t, 80, 24));
    assert!(
        !s.contains('⠋') && !s.contains('⠙'),
        "no spinner before 150 ms"
    );
    for _ in 0..3 {
        update(&mut m, Msg::Tick);
    }
    let s = text(&render(&m, &t, 80, 24));
    assert!(
        t.g.spin.iter().any(|g| s.contains(g)),
        "a spinner after 150 ms:\n{s}"
    );
    for _ in 0..40 {
        update(&mut m, Msg::Tick);
    }
    assert!(
        text(&render(&m, &t, 80, 24)).contains("  2s"),
        "elapsed time after 2 s"
    );
    // A handoff's result on the way back, and the core's failure.
    let mut m = dashboard(false);
    let req = Req::Execute {
        action: "test.handoff".into(),
        basis: "5f2e".repeat(16),
        word: "test".into(),
        handoff: true,
        cancel: false,
    };
    let c = update(
        &mut m,
        Msg::Done(req, Outcome::Answer(vec![result("done", "ok", "")])),
    );
    assert_eq!(c, vec![Cmd::Send(Req::Snapshot)]);
    insta::assert_snapshot!("handoff_returned_80x24", text(&render(&m, &t, 80, 24)));
    let req = Req::Execute {
        action: "test.mutate".into(),
        basis: "5f2e".repeat(16),
        word: "test".into(),
        handoff: false,
        cancel: false,
    };
    update(&mut m, Msg::Done(req, Outcome::Unknown("no result".into())));
    let s = text(&render(&m, &t, 80, 24));
    assert!(
        s.contains("The core stopped without a complete answer"),
        "{s}"
    );
    let mut m = Model::default();
    m.start();
    update(
        &mut m,
        Msg::Done(Req::Hello, Outcome::NotSent("no such file".into())),
    );
    insta::assert_snapshot!("fatal_80x24", text(&render(&m, &t, 80, 24)));
    // Logs and help.
    let mut m = dashboard(false);
    update(
        &mut m,
        Msg::Logs(vec![
            "request 1:".into(),
            "child\ttest.read\texit=000\tkept=00041\tdiscarded=0".into(),
            "fake read child: a line of diagnostics".into(),
        ]),
    );
    insta::assert_snapshot!("logs_80x24", text(&render(&m, &t, 80, 24)));
    let mut m = dashboard(false);
    update(&mut m, key(KeyCode::Char('?')));
    insta::assert_snapshot!("help_80x24", text(&render(&m, &t, 80, 24)));
}

/// Heights 20 to 23 merge the header into the rail line.
#[test]
fn short_terminals_merge_the_header() {
    let m = dashboard(false);
    let full = text(&render(&m, &profile("color"), 80, 24));
    let short = text(&render(&m, &profile("color"), 80, 22));
    assert!(
        full.lines()
            .next()
            .unwrap()
            .contains("omarchy mac bootstrap")
    );
    assert!(!short.contains("omarchy mac bootstrap"), "{short}");
    assert!(short.lines().next().unwrap().starts_with(" ◒ "), "{short}");
}

/// Layer D: focus is reversed; the barrier is `blocked` (reversed) as well as
/// its word; a failure is danger; monochrome keeps reverse.
#[test]
fn emphasis_by_token() {
    let m = dashboard(false);
    for p in ["color", "sixteen", "nocolor"] {
        let t = profile(p);
        let b = render(&m, &t, 80, 24);
        let y = (0..24)
            .find(|&y| {
                (0..80)
                    .map(|x| b[(x, y)].symbol())
                    .collect::<String>()
                    .contains("❯")
            })
            .unwrap();
        let x = (0..80).find(|&x| b[(x, y)].symbol() == "R").unwrap();
        assert!(
            b[(x, y)].modifier.contains(Modifier::REVERSED),
            "{p}: the focused row is reversed"
        );
        assert_eq!(
            b[(x, y)].style(),
            t.style(Token::Focus).patch(b[(x, y)].style()),
            "{p}"
        );
        assert!(
            !b[(x, y)].modifier.contains(Modifier::BOLD),
            "{p}: never bold"
        );
    }
    let m = dashboard(true);
    let t = profile("color");
    let b = render(&m, &t, 80, 24);
    let s = text(&b);
    let y = s.lines().position(|l| l.contains("blocked")).unwrap() as u16;
    let x = (0..80).find(|&x| b[(x, y)].symbol() == "b").unwrap();
    assert!(
        b[(x, y)].modifier.contains(Modifier::REVERSED),
        "blocked is reversed"
    );
    assert_eq!(
        b[(x, y)].fg,
        Color::Indexed(204),
        "blocked is danger's colour"
    );
    let t = profile("nocolor");
    let b = render(&m, &t, 80, 24);
    assert!(
        b[(x, y)].modifier.contains(Modifier::REVERSED),
        "monochrome keeps the reverse"
    );
    assert_eq!(b[(x, y)].fg, Color::Reset, "and no colour");
}

/// Layer E: every state keeps its word and glyph in every profile; the ASCII
/// profile draws nothing but ASCII; no colour means no colour at all.
#[test]
fn degraded_profiles() {
    let mut models = vec![dashboard(false), dashboard(true)];
    let mut g = dashboard(false);
    update(&mut g, key(KeyCode::Down));
    update(&mut g, key(KeyCode::Enter));
    models.push(g);
    let mut c = Model::default();
    c.start();
    models.push(c);
    for m in &models {
        for (w, h) in SIZES {
            let a = render(m, &profile("ascii"), w, h);
            for cell in a.content() {
                assert!(
                    cell.symbol().is_ascii(),
                    "ASCII only at {w}x{h}: {:?}",
                    cell.symbol()
                );
                // Sixteen colours on the console, never 256.
                assert!(
                    !matches!(cell.fg, Color::Indexed(_) | Color::Rgb(..)),
                    "{w}x{h}"
                );
            }
            let n = render(m, &profile("nocolor"), w, h);
            for cell in n.content() {
                assert_eq!(
                    (cell.fg, cell.bg),
                    (Color::Reset, Color::Reset),
                    "no colour at {w}x{h}"
                );
            }
            let s = render(m, &profile("sixteen"), w, h);
            for cell in s.content() {
                assert!(
                    !matches!(cell.fg, Color::Indexed(_) | Color::Rgb(..)),
                    "named colours only at {w}x{h}"
                );
            }
        }
    }
    let a = text(&render(&dashboard(true), &profile("ascii"), 80, 24));
    assert!(
        a.contains("x blocked"),
        "the word and the glyph survive ASCII:\n{a}"
    );
    assert!(a.contains("(o)"), "the mark in ASCII");
    let a = text(&render(&dashboard(false), &profile("ascii"), 80, 24));
    assert!(
        a.contains("> Read the fixture"),
        "the pointer in ASCII:\n{a}"
    );
    insta::assert_snapshot!("dashboard_ascii_80x24", a);
}
