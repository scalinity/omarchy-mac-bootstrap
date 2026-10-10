//! Layer G, the real terminal (docs/TESTING.md → pty-*), and the supervision
//! cases that need the real topology: the launcher (L) started on a
//! pseudo-terminal, which starts this build of the frontend (F) through the
//! fixture-mode development override, which starts the core (C) per request,
//! which starts the fake children (X). The screen is read back with vt100.
//!
//! Built with `--features test-hooks` for the injected panic; everything
//! else runs without it.

use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn bash() -> String {
    std::env::var("OMB_TEST_BASH").unwrap_or_else(|_| {
        if cfg!(target_os = "macos") {
            "/bin/bash".into()
        } else {
            "bash".into()
        }
    })
}

/// One pseudo-terminal session: the child, the screen, and a writer.
struct Pty {
    child: Box<dyn Child + Send + Sync>,
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    screen: Arc<Mutex<vt100::Parser>>,
    raw: Arc<Mutex<Vec<u8>>>,
    dir: PathBuf,
    /// The terminal's settings before anything started on it.
    initial: String,
    fix: PathBuf,
    /// Tells the reader thread to stop after its next read; it answers on
    /// `read_done` once its copy of the controller's descriptor is closed.
    stop_reading: Arc<AtomicBool>,
    read_done: Receiver<()>,
}

struct Opts<'a> {
    rows: u16,
    cols: u16,
    env: Vec<(&'a str, String)>,
    /// Run the launcher from an interactive shell (job control), as a person
    /// does, instead of as the terminal's first process.
    shell: bool,
    /// The tool to launch (a copy with its own lock), instead of this checkout.
    home: Option<PathBuf>,
    /// Start this build through the fixture-mode development override.
    dev: bool,
    /// Keep the scratch folder of an earlier start with the same name.
    keep: bool,
    /// The fixture the session reads.
    fixture: &'a str,
}

impl Default for Opts<'_> {
    fn default() -> Self {
        Opts {
            rows: 24,
            cols: 80,
            env: Vec::new(),
            shell: false,
            home: None,
            dev: true,
            keep: false,
            fixture: "mac-m1pro-1tb-roomy",
        }
    }
}

fn fixture(dir: &Path, name: &str) -> PathBuf {
    let fix = dir.join("fixture");
    assert!(
        Command::new("cp")
            .arg("-R")
            .arg(repo().join("tests/fixtures").join(name))
            .arg(&fix)
            .status()
            .unwrap()
            .success()
    );
    std::fs::create_dir_all(fix.join("test-children")).unwrap();
    fix
}

fn scratch(name: &str) -> PathBuf {
    scratch_keep(name, false)
}

fn scratch_keep(name: &str, keep: bool) -> PathBuf {
    let d = std::env::temp_dir().join(format!("omb-pty-{name}-{}", std::process::id()));
    if !keep {
        let _ = std::fs::remove_dir_all(&d);
    }
    std::fs::create_dir_all(d.join("tmp")).unwrap();
    std::fs::create_dir_all(d.join("home")).unwrap();
    d
}

impl Pty {
    fn start(name: &str, o: Opts) -> Pty {
        let dir = scratch_keep(name, o.keep);
        let fix = if o.keep && dir.join("fixture").exists() {
            dir.join("fixture")
        } else {
            fixture(&dir, o.fixture)
        };
        let home = o.home.clone().unwrap_or_else(repo);
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: o.rows,
                cols: o.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .expect("open a pseudo-terminal");
        let mut cmd = CommandBuilder::new(bash());
        if o.shell {
            cmd.args(["--noprofile", "--norc", "-i"]);
        } else {
            cmd.arg(home.join("omarchy-bootstrap"));
        }
        cmd.cwd(repo());
        cmd.env_clear();
        let path = match std::env::var("OMB_TEST_BASH") {
            Ok(b) => format!(
                "{}:/usr/bin:/bin:/usr/sbin:/sbin",
                Path::new(&b).parent().unwrap().display()
            ),
            Err(_) => "/usr/bin:/bin:/usr/sbin:/sbin".into(),
        };
        let base = [
            ("PATH", path),
            ("HOME", dir.join("home").display().to_string()),
            ("TMPDIR", dir.join("tmp").display().to_string()),
            ("LANG", "en_US.UTF-8".into()),
            ("TERM", "xterm-256color".into()),
            ("PS1", "$ ".into()),
            ("HISTFILE", "/dev/null".into()),
            ("OMB_FIXTURE", fix.display().to_string()),
            ("OMB_TEST_FOUNDATION", "1".into()),
            ("OMB_STATE_DIR", dir.join("state").display().to_string()),
            (
                "OMB_FRONTEND_DEV",
                if o.dev {
                    env!("CARGO_BIN_EXE_omb-tui").into()
                } else {
                    String::new()
                },
            ),
            ("OMB_TUI_LOG", dir.join("trace").display().to_string()),
        ];
        for (k, v) in base.iter().cloned().chain(o.env) {
            cmd.env(k, v);
        }
        let initial = format!(
            "{:?}",
            pair.master.get_termios().map(|t| (
                t.input_flags,
                t.output_flags,
                t.local_flags,
                t.control_flags
            ))
        );
        let child = pair
            .slave
            .spawn_command(cmd)
            .expect("spawn in the pseudo-terminal");
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader().unwrap();
        let writer = pair.master.take_writer().unwrap();
        let screen = Arc::new(Mutex::new(vt100::Parser::new(o.rows, o.cols, 0)));
        let raw = Arc::new(Mutex::new(Vec::new()));
        let (s2, r2) = (screen.clone(), raw.clone());
        let stop_reading = Arc::new(AtomicBool::new(false));
        let (stop2, (done_tx, read_done)) = (stop_reading.clone(), channel());
        std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            while let Ok(n) = reader.read(&mut buf) {
                if n == 0 {
                    break;
                }
                s2.lock().unwrap().process(&buf[..n]);
                r2.lock().unwrap().extend_from_slice(&buf[..n]);
                if stop2.load(Ordering::SeqCst) {
                    break;
                }
            }
            drop(reader);
            let _ = done_tx.send(());
        });
        let mut p = Pty {
            child,
            master: pair.master,
            writer,
            screen,
            raw,
            dir,
            initial,
            fix,
            stop_reading,
            read_done,
        };
        if o.shell {
            p.wait_for("$ ");
            let launcher = home.join("omarchy-bootstrap");
            p.send(format!("{} {}\r", bash(), launcher.display()).as_bytes());
        }
        p
    }

    fn contents(&self) -> String {
        self.screen.lock().unwrap().screen().contents()
    }

    fn wait_until(&self, what: &str, ok: impl Fn(&Pty) -> bool) {
        let t0 = Instant::now();
        while !ok(self) {
            if t0.elapsed() > Duration::from_secs(60) {
                let raw = self.raw.lock().unwrap();
                let tail = String::from_utf8_lossy(&raw[raw.len().saturating_sub(1500)..])
                    .escape_debug()
                    .to_string();
                panic!(
                    "timed out waiting for {what}; the screen:\n{}\nthe last bytes: {tail}",
                    self.contents()
                );
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    fn wait_for(&self, text: &str) {
        self.wait_until(text, |p| p.contents().contains(text));
    }

    fn send(&mut self, b: &[u8]) {
        self.writer.write_all(b).unwrap();
        self.writer.flush().unwrap();
    }

    fn keys(&mut self, s: &str) {
        for b in s.bytes() {
            self.send(&[b]);
            std::thread::sleep(Duration::from_millis(15));
        }
    }

    fn wait_exit(&mut self) -> u32 {
        let t0 = Instant::now();
        loop {
            if let Some(st) = self.child.try_wait().unwrap() {
                // Let the last bytes reach the parser.
                std::thread::sleep(Duration::from_millis(200));
                return st.exit_code();
            }
            assert!(
                t0.elapsed() < Duration::from_secs(60),
                "the launcher did not exit; the screen:\n{}",
                self.contents()
            );
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    fn termios(&self) -> String {
        format!(
            "{:?}",
            self.master.get_termios().map(|t| (
                t.input_flags,
                t.output_flags,
                t.local_flags,
                t.control_flags
            ))
        )
    }

    /// The session scratch folders the launcher made.
    fn sessions(&self) -> Vec<PathBuf> {
        std::fs::read_dir(self.dir.join("tmp"))
            .map(|d| {
                d.filter_map(|e| e.ok())
                    .map(|e| e.path())
                    .filter(|p| {
                        p.file_name()
                            .unwrap()
                            .to_string_lossy()
                            .starts_with("omb-session.")
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// The PID the launcher recorded for the frontend.
    fn frontend_pid(&self) -> i32 {
        let t0 = Instant::now();
        loop {
            for s in self.sessions() {
                if let Ok(t) = std::fs::read_to_string(s.join("frontend.omb"))
                    && let Some(p) = t.split('\t').find_map(|f| f.strip_prefix("pid="))
                {
                    return p.parse().unwrap();
                }
            }
            assert!(t0.elapsed() < Duration::from_secs(30), "no frontend.omb");
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    fn conf(&self, child: &str, lines: &str) {
        std::fs::write(self.fix.join("test-children").join(child), lines).unwrap();
    }

    fn restored(&self) -> bool {
        let s = self.screen.lock().unwrap();
        !s.screen().alternate_screen() && !s.screen().hide_cursor()
    }

    /// No request in flight: every request the trace records has its outcome.
    fn idle(&self) {
        self.wait_until("no request in flight", |p| {
            let t = std::fs::read_to_string(p.dir.join("trace")).unwrap_or_default();
            let sent = t.lines().filter(|l| l.starts_with("send ")).count();
            sent > 0 && sent == t.lines().filter(|l| l.starts_with("outcome ")).count()
        });
    }

    fn dashboard(&self) {
        self.wait_for("Read the fixture (test)");
    }

    fn select(&mut self, down: usize) {
        for _ in 0..down {
            self.send(b"\x1b[B");
            std::thread::sleep(Duration::from_millis(30));
        }
    }

    /// Close the terminal as a closing window does: every descriptor of the
    /// pseudo-terminal's controller shut. The reader thread holds a copy, so
    /// it is told to stop and woken: by a resize, which the frontend answers
    /// with a redraw, or — during a handoff, when nothing redraws — by a key
    /// the terminal echoes. Returns the launcher.
    fn hang_up(mut self, echo: bool) -> Box<dyn Child + Send + Sync> {
        self.stop_reading.store(true, Ordering::SeqCst);
        if echo {
            self.send(b"x");
        } else {
            self.master
                .resize(PtySize {
                    rows: 30,
                    cols: 100,
                    pixel_width: 0,
                    pixel_height: 0,
                })
                .unwrap();
        }
        self.read_done
            .recv_timeout(Duration::from_secs(30))
            .expect("the reader thread closed its descriptor");
        drop(self.writer);
        drop(self.master);
        self.child
    }
}

fn kill(pid: i32, sig: &str) {
    assert!(
        Command::new("kill")
            .arg(format!("-{sig}"))
            .arg(pid.to_string())
            .status()
            .unwrap()
            .success()
    );
}

fn alive(pid: i32) -> bool {
    Command::new("kill")
        .arg("-0")
        .arg(pid.to_string())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success()
}

// --- pty-exit, pty-ctrlc-idle, sup-owner-cleanup ---------------------------------

#[test]
fn pty_exit_restores_and_the_owner_cleans_up() {
    let mut p = Pty::start("exit", Opts::default());
    p.dashboard();
    assert!(
        p.screen.lock().unwrap().screen().alternate_screen(),
        "the dashboard is on the alternate screen"
    );
    assert_eq!(p.sessions().len(), 1, "one session scratch while it runs");
    p.idle();
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
    assert!(p.restored(), "alternate screen left, cursor shown");
    assert_eq!(
        p.termios(),
        p.initial,
        "the terminal's settings are the ones before start"
    );
    assert!(
        p.sessions().is_empty(),
        "sup-owner-cleanup: the launcher, alive, removed its own scratch"
    );
}

#[test]
fn pty_ctrlc_idle_quits() {
    let mut p = Pty::start("ctrlc", Opts::default());
    p.dashboard();
    p.send(b"\x03");
    assert_eq!(p.wait_exit(), 0);
    assert!(p.restored());
}

// --- pty-panic ------------------------------------------------------------------

#[cfg(feature = "test-hooks")]
#[test]
fn pty_panic_restores() {
    let mut p = Pty::start(
        "panic",
        Opts {
            env: vec![("OMB_TEST_HOOK", "panic".into())],
            ..Opts::default()
        },
    );
    let code = p.wait_exit();
    assert_ne!(code, 0, "a crash is a failure the launcher reports");
    assert!(
        p.restored(),
        "alternate screen left, cursor shown after a panic"
    );
    let raw = String::from_utf8_lossy(&p.raw.lock().unwrap()).to_string();
    assert!(
        raw.contains("the interface stopped"),
        "reported on the normal screen: {raw}"
    );
}

// --- pty-reader-panic: a worker's panic leaves the terminal to its owner (H02) ----------
// Request 1 is hello and 2 the first snapshot, so `reader-panic:3` kills the
// reader of the first request the person makes.

/// Bytes the terminal received since BEFORE.
fn since(p: &Pty, before: usize) -> String {
    String::from_utf8_lossy(&p.raw.lock().unwrap()[before..]).to_string()
}

/// The interface still owns the terminal as it did: the alternate screen,
/// the cursor hidden, raw mode as on the dashboard, and nothing written that
/// leaves the alternate screen.
#[cfg(feature = "test-hooks")]
fn still_owned(p: &Pty, raw_mode: &str, before: usize, what: &str) {
    {
        let s = p.screen.lock().unwrap();
        assert!(
            s.screen().alternate_screen(),
            "{what}: the alternate screen"
        );
        assert!(s.screen().hide_cursor(), "{what}: the cursor hidden");
    }
    assert_eq!(p.termios(), raw_mode, "{what}: raw mode as it was");
    assert!(
        !since(p, before).contains("\x1b[?1049l"),
        "{what}: nothing left the alternate screen"
    );
}

/// The session ends: the terminal restored by the main thread, the worker's
/// panic reported after that, nothing left running, the scratch removed.
#[cfg(feature = "test-hooks")]
fn ends_cleanly(mut p: Pty) {
    let f = p.frontend_pid();
    p.idle();
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
    assert!(p.restored());
    assert_eq!(p.termios(), p.initial);
    let raw = String::from_utf8_lossy(&p.raw.lock().unwrap()).to_string();
    let restored_at = raw.rfind("\x1b[?1049l").expect("the main thread restored");
    let reported_at = raw.rfind("a background thread stopped").expect("reported");
    assert!(reported_at > restored_at, "reported on the normal screen");
    assert!(!alive(f), "no frontend left");
    assert!(p.sessions().is_empty(), "the scratch removed");
}

#[cfg(feature = "test-hooks")]
#[test]
fn pty_reader_panic_on_an_idle_refresh() {
    let mut p = Pty::start(
        "rpanic-idle",
        Opts {
            cols: 120,
            env: vec![("OMB_TEST_HOOK", "reader-panic:3".into())],
            ..Opts::default()
        },
    );
    p.dashboard();
    p.idle();
    let raw_mode = p.termios();
    let before = p.raw.lock().unwrap().len();
    p.keys("r");
    p.wait_for("without a complete answer");
    still_owned(&p, &raw_mode, before, "after the reader's panic");
    // The interface goes on: the next read is answered.
    p.keys("r");
    p.idle();
    p.dashboard();
    still_owned(&p, &raw_mode, before, "after the next read");
    ends_cleanly(p);
}

#[cfg(feature = "test-hooks")]
#[test]
fn pty_reader_panic_during_a_live_request() {
    let mut p = Pty::start(
        "rpanic-live",
        Opts {
            cols: 120,
            env: vec![("OMB_TEST_HOOK", "reader-panic:3".into())],
            ..Opts::default()
        },
    );
    p.conf("mutate", "sleep=2\n");
    p.dashboard();
    p.idle();
    let raw_mode = p.termios();
    let before = p.raw.lock().unwrap().len();
    p.select(1);
    p.send(b"\r");
    p.wait_for("Type test to continue");
    p.keys("test");
    p.send(b"\r");
    // The child runs under the core; the reader is already dead.
    let t0 = Instant::now();
    while !p
        .sessions()
        .iter()
        .any(|s| s.join("req-3.worker-1").exists())
    {
        assert!(
            t0.elapsed() < Duration::from_secs(30),
            "the child did not start"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    let trace = || std::fs::read_to_string(p.dir.join("trace")).unwrap_or_default();
    assert_eq!(
        trace().matches("outcome ").count(),
        2,
        "no outcome for the request while its core runs: {}",
        trace()
    );
    still_owned(&p, &raw_mode, before, "while the core runs");
    p.wait_for("without a complete answer");
    assert!(
        p.dir.join("state/test/effect-mutate").exists(),
        "the outcome came only after the core had finished its work"
    );
    assert!(trace().contains("outcome Unknown(\"the response reader stopped\")"));
    still_owned(&p, &raw_mode, before, "after the request");
    p.dashboard();
    ends_cleanly(p);
}

#[cfg(feature = "test-hooks")]
#[test]
fn pty_reader_panic_during_a_handoff_leaves_the_child_the_terminal() {
    let mut p = Pty::start(
        "rpanic-handoff",
        Opts {
            cols: 120,
            env: vec![("OMB_TEST_HOOK", "reader-panic:3".into())],
            ..Opts::default()
        },
    );
    start_handoff(&mut p);
    p.wait_until("the child", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("type a line and press Enter")
    });
    // The reader died as the core started. The child owns the terminal: its
    // group in the foreground, its settings, nothing written over it.
    let (fg, settings) = (p.master.process_group_leader(), p.termios());
    let before = p.raw.lock().unwrap().len();
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(p.master.process_group_leader(), fg, "the foreground group");
    assert_eq!(p.termios(), settings, "the child's settings");
    assert!(
        !p.screen.lock().unwrap().screen().alternate_screen(),
        "not taken back to the alternate screen"
    );
    assert_eq!(
        since(&p, before),
        "",
        "nothing written while the child owns it"
    );
    p.send(b"a line\r");
    p.wait_for("without a complete answer");
    assert!(
        p.dir.join("state/test/effect-handoff").exists(),
        "the child finished its work"
    );
    p.dashboard();
    ends_cleanly(p);
}

// --- pty-resize -------------------------------------------------------------------

#[test]
fn pty_resize_follows_and_says_too_small() {
    let mut p = Pty::start("resize", Opts::default());
    p.dashboard();
    let resize = |p: &mut Pty, rows, cols| {
        p.master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        p.screen.lock().unwrap().screen_mut().set_size(rows, cols);
    };
    resize(&mut p, 20, 60);
    p.wait_until("the 60-column layout", |p| {
        p.contents().contains("? help") && !p.contents().contains("L logs")
    });
    resize(&mut p, 18, 54);
    p.wait_for("terminal too small — needs 60x20, this is 54x18");
    resize(&mut p, 24, 80);
    p.wait_for("L logs");
    p.idle();
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
}

// --- sup-completion-controllers-live, on the real topology --------------------------

#[test]
fn sup_completion_with_controllers_alive() {
    let mut p = Pty::start("complete", Opts::default());
    p.dashboard();
    p.idle();
    p.select(1);
    p.send(b"\r");
    p.wait_for("Type test to continue");
    p.keys("tes");
    p.send(b"\r");
    p.wait_for("Only the exact word \"test\" continues.");
    p.keys("t");
    p.send(b"\r");
    p.wait_for("test.mutate: done");
    assert!(
        !p.dir.join("state/ops/journey.omb").exists(),
        "the operation completed: its record is removed"
    );
    assert!(
        p.dir.join("state/test/effect-mutate").exists(),
        "the child's effect is there"
    );
    // L and F were alive throughout, in the same group as C.
    let f = p.frontend_pid();
    assert!(alive(f));
    p.idle();
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
}

// --- a handoff: pty-pgid, pty-dispositions, pty-no-steal, pty-termios, sup-spool-handoff

/// A handoff child that reports what it was given, reads 100 keys and a
/// cursor-position reply raw, may leave the terminal odd, then writes its
/// effect. Args: EFFECT WANT (as the registry's child gets).
fn probe_child(dir: &Path) -> PathBuf {
    let p = dir.join("probe-child");
    std::fs::write(
        &p,
        r#"#!/bin/sh
out=$(dirname "$0")/probe
ps -o pgid=,tpgid= -p $$ >"$out.pg"
perl -MPOSIX -e '
  for my $n (qw(INT QUIT TSTP)) {
    my $old = POSIX::SigAction->new;
    POSIX::sigaction(eval "POSIX::SIG$n", undef, $old);
    my $h = $old->handler;
    print "$n=", (ref $h ? "caught" : $h), "\n";
  }
  my $set = POSIX::SigSet->new;
  POSIX::sigprocmask(POSIX::SIG_BLOCK, undef, $set);
  my @blocked = grep { $set->ismember($_) } 1 .. 31;
  print "mask=", join(",", @blocked), "\n";
' >"$out.sig"
for f in launcher frontend; do
  pid=$(sed -n 's/.*	pid=\([0-9]*\)	.*/\1/p' "$OMB_SESSION_DIR/$f.omb")
  ps -o pgid= -p "$pid" | tr -d ' ' >>"$out.group"
done
ps -o pgid= -p $PPID | tr -d ' ' >>"$out.group"
saved=$(stty -g)
stty raw -echo
printf 'probe: ready\r\n'
printf '\033[6n'
head -c 108 >"$out.keys"
if [ -f "$out.leave-raw" ]; then :; else stty "$saved"; fi
printf '%s' "$2" >"$1"
printf 'probe: done\r\n'
"#,
    )
    .unwrap();
    assert!(
        Command::new("chmod")
            .arg("+x")
            .arg(&p)
            .status()
            .unwrap()
            .success()
    );
    p
}

fn start_handoff(p: &mut Pty) {
    p.dashboard();
    p.idle();
    p.select(2);
    p.send(b"\r");
    p.wait_for("Type test to continue");
    p.keys("test");
    p.send(b"\r");
}

#[test]
fn a_handoff_owns_the_terminal() {
    let dir = scratch("handoff-probe");
    let probe = probe_child(&dir);
    let mut p = Pty::start(
        "handoff",
        Opts {
            env: vec![("OMB_TEST_HANDOFF_CHILD", probe.display().to_string())],
            ..Opts::default()
        },
    );
    // sup-spool-handoff: the core appends 10 000 progress records while the
    // frontend has stepped aside and follows the spool.
    p.conf("core", "progress=10000\n");
    p.dashboard();
    // Raw mode on the dashboard: what re-entry must rebuild, from the saved settings.
    let raw_mode = p.termios();
    start_handoff(&mut p);
    p.wait_until("the probe", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("probe: ready")
    });
    assert!(
        !p.screen.lock().unwrap().screen().alternate_screen(),
        "the frontend left the alternate screen for the child"
    );
    // 100 keys and a cursor-position reply: the child must get every byte.
    let keys: String = (0..100).map(|i| (b'a' + (i % 26) as u8) as char).collect();
    p.send(keys.as_bytes());
    p.send(b"\x1b[12;34R");
    p.wait_for("test.handoff: done");
    let got = std::fs::read(dir.join("probe.keys")).unwrap();
    assert_eq!(
        got,
        [keys.as_bytes(), b"\x1b[12;34R"].concat(),
        "pty-no-steal: the child received every key and the reply"
    );
    // pty-pgid: the terminal's foreground group is the job's, holding L, F, C.
    let pg = std::fs::read_to_string(dir.join("probe.pg")).unwrap();
    let v: Vec<&str> = pg.split_whitespace().collect();
    assert_eq!(
        v[0], v[1],
        "pty-pgid: the child is in the terminal's foreground group"
    );
    let groups = std::fs::read_to_string(dir.join("probe.group")).unwrap();
    assert!(
        groups.lines().all(|g| g == v[0]),
        "pty-pgid: L, F and C share that group ({groups})"
    );
    // pty-dispositions: default dispositions, an empty mask.
    let sig = std::fs::read_to_string(dir.join("probe.sig")).unwrap();
    assert_eq!(
        sig, "INT=DEFAULT\nQUIT=DEFAULT\nTSTP=DEFAULT\nmask=\n",
        "pty-dispositions"
    );
    // sup-spool-handoff: every record followed, in order, while stepped aside.
    let trace = std::fs::read_to_string(p.dir.join("trace")).unwrap();
    // hello, the 10 000 progress records, and the result.
    assert!(trace.contains("handoff followed 10002 records"), "{trace}");
    assert_eq!(
        p.termios(),
        raw_mode,
        "re-entry rebuilt the same raw mode, not the child's settings"
    );
    p.idle();
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
    assert_eq!(p.termios(), p.initial);
}

#[test]
fn pty_termios_a_child_that_leaves_the_terminal_raw() {
    let dir = scratch("termios-probe");
    let probe = probe_child(&dir);
    std::fs::write(dir.join("probe.leave-raw"), "").unwrap();
    let mut p = Pty::start(
        "termios",
        Opts {
            env: vec![("OMB_TEST_HANDOFF_CHILD", probe.display().to_string())],
            ..Opts::default()
        },
    );
    start_handoff(&mut p);
    p.wait_until("the probe", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("probe: ready")
    });
    p.send(&[b'x'; 100]);
    p.send(b"\x1b[12;34R");
    p.wait_for("test.handoff: done");
    p.idle();
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
    assert_eq!(
        p.termios(),
        p.initial,
        "pty-termios: on exit the settings equal the ones before start"
    );
}

// --- pty-ctrlc-child ----------------------------------------------------------------

#[test]
fn pty_ctrlc_during_a_handoff_goes_to_the_child() {
    let mut p = Pty::start("ctrlc-child", Opts::default());
    start_handoff(&mut p);
    p.wait_until("the child", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("type a line and press Enter")
    });
    let f = p.frontend_pid();
    p.send(b"\x03");
    p.wait_until("the child to say so", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("fake handoff child: interrupted")
    });
    // F and L survive and redraw after a fresh snapshot.
    p.dashboard();
    p.wait_for("test.handoff");
    assert!(alive(f), "the frontend survived Ctrl-C during the handoff");
    p.idle();
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
    assert!(p.restored());
}

// --- pty-sigterm, pty-sighup ---------------------------------------------------------

#[test]
fn pty_sigterm_and_sighup_idle() {
    for sig in ["TERM", "HUP"] {
        let mut p = Pty::start(&format!("sig-{sig}"), Opts::default());
        p.dashboard();
        kill(p.frontend_pid(), sig);
        assert_eq!(p.wait_exit(), 0, "SIG{sig}");
        assert!(p.restored(), "SIG{sig}: the terminal restored");
    }
}

#[test]
fn pty_sigterm_and_sighup_to_the_launcher_reach_the_frontend() {
    for sig in ["TERM", "HUP"] {
        let mut p = Pty::start(&format!("lsig-{sig}"), Opts::default());
        p.dashboard();
        p.idle();
        kill(p.child.process_id().unwrap() as i32, sig);
        assert_eq!(p.wait_exit(), 0, "SIG{sig} to the launcher");
        assert!(
            p.restored(),
            "SIG{sig} to the launcher: the terminal restored"
        );
        assert!(
            p.sessions().is_empty(),
            "SIG{sig} to the launcher: the scratch removed"
        );
    }
}

// --- pty-hangup: the terminal closes under a session -------------------------------------
// The launcher leads the terminal's session here, as over SSH, so the hangup
// signals only it: it passes SIGHUP to the frontend. The frontend, whose
// terminal now reads as end of file, stops instead of spinning; the launcher
// cleans up and exits.

#[test]
fn pty_hangup_ends_the_session() {
    let p = Pty::start("hangup", Opts::default());
    p.dashboard();
    p.idle();
    let f = p.frontend_pid();
    let tmp = p.dir.join("tmp");
    let mut launcher = p.hang_up(false);
    let t0 = Instant::now();
    while launcher.try_wait().unwrap().is_none() {
        assert!(
            t0.elapsed() < Duration::from_secs(30),
            "the launcher is still running 30 s after its terminal closed"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(!alive(f), "the frontend ended with its terminal");
    let left: Vec<_> = std::fs::read_dir(&tmp)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().starts_with("omb-session."))
        .collect();
    assert!(left.is_empty(), "the session scratch was removed");
}

#[test]
fn pty_sigterm_during_a_handoff_waits_for_the_child() {
    let mut p = Pty::start("sigterm-handoff", Opts::default());
    start_handoff(&mut p);
    p.wait_until("the child", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("type a line and press Enter")
    });
    let f = p.frontend_pid();
    kill(f, "TERM");
    std::thread::sleep(Duration::from_millis(500));
    assert!(alive(f), "the frontend waits for the child");
    p.send(b"a line\r");
    assert_eq!(p.wait_exit(), 0);
    assert!(p.restored());
    assert!(
        p.dir.join("state/test/effect-handoff").exists(),
        "the child finished its work first"
    );
}

// --- pty-tstp -------------------------------------------------------------------------

#[test]
fn pty_tstp_idle_and_during_a_child() {
    let mut p = Pty::start(
        "tstp",
        Opts {
            shell: true,
            ..Opts::default()
        },
    );
    p.dashboard();
    let events = |p: &Pty| {
        p.sessions()
            .iter()
            .map(|s| {
                std::fs::read_dir(s)
                    .unwrap()
                    .filter(|e| {
                        e.as_ref()
                            .unwrap()
                            .file_name()
                            .to_string_lossy()
                            .ends_with(".events")
                    })
                    .count()
            })
            .sum::<usize>()
    };
    let n0 = events(&p);
    // Ctrl-Z idle: the frontend restores the terminal and stops the group.
    p.send(b"\x1a");
    p.wait_until("the job to stop", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("Stopped")
    });
    assert!(p.restored(), "the terminal restored before stopping");
    p.send(b"fg\r");
    p.dashboard();
    p.wait_until("a fresh snapshot after continuing", |p| events(p) > n0);
    // SIGTSTP to the group during a child, then SIGCONT.
    start_handoff(&mut p);
    p.wait_until("the child", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("type a line and press Enter")
    });
    let stopped_before = String::from_utf8_lossy(&p.raw.lock().unwrap())
        .matches("Stopped")
        .count();
    p.send(b"\x1a");
    p.wait_until("the group to stop", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap())
            .matches("Stopped")
            .count()
            > stopped_before
    });
    p.send(b"fg\r");
    std::thread::sleep(Duration::from_millis(300));
    p.send(b"still here\r");
    p.wait_for("test.handoff: done");
    p.idle();
    p.keys("q");
    p.wait_until("the shell prompt", |p| {
        p.contents().trim_end().ends_with('$')
    });
    p.send(b"exit\r");
    p.wait_exit();
}

// --- sup-frontend-death-core-live --------------------------------------------------------

#[test]
fn sup_frontend_death_core_live() {
    let mut p = Pty::start("fdeath", Opts::default());
    p.conf("mutate", "sleep=3\n");
    p.dashboard();
    p.idle();
    p.select(1);
    p.send(b"\r");
    p.wait_for("Type test to continue");
    p.keys("test");
    p.send(b"\r");
    // The child is running under the core: kill the frontend.
    let t0 = Instant::now();
    while !p
        .sessions()
        .iter()
        .any(|s| s.join("req-3.worker-1").exists() || s.join("req-4.worker-1").exists())
    {
        assert!(
            t0.elapsed() < Duration::from_secs(30),
            "the child did not start"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    kill(p.frontend_pid(), "KILL");
    let code = p.wait_exit();
    assert_ne!(code, 0, "the launcher reports that the interface stopped");
    assert!(p.restored(), "the launcher restored the terminal");
    assert!(
        p.dir.join("state/test/effect-mutate").exists(),
        "the core completed its work"
    );
    assert!(
        !p.dir.join("state/ops/journey.omb").exists(),
        "and removed its operation record"
    );
    assert!(
        p.sessions().is_empty(),
        "the launcher waited for the core, then cleaned up as the owner"
    );
    let raw = String::from_utf8_lossy(&p.raw.lock().unwrap()).to_string();
    assert!(
        raw.contains("status"),
        "it says what to run to see the machine's state"
    );
}

// --- The launcher takes the terminal back only once the session is over (H06) --------------

/// The probe child owns the terminal in raw mode; the frontend is killed.
/// Returns the session and the probe's folder.
fn frontend_killed_under_the_probe(name: &str, leave_raw: bool) -> (Pty, PathBuf) {
    let dir = scratch(&format!("{name}-probe"));
    let probe = probe_child(&dir);
    if leave_raw {
        std::fs::write(dir.join("probe.leave-raw"), "").unwrap();
    }
    let mut p = Pty::start(
        name,
        Opts {
            env: vec![("OMB_TEST_HANDOFF_CHILD", probe.display().to_string())],
            ..Opts::default()
        },
    );
    start_handoff(&mut p);
    p.wait_until("the probe", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("probe: ready")
    });
    (p, dir)
}

#[test]
fn launcher_waits_for_a_handoff_child_the_frontend_left() {
    let (mut p, _dir) = frontend_killed_under_the_probe("fdeath-handoff", false);
    let childs = p.termios();
    let before = p.raw.lock().unwrap().len();
    kill(p.frontend_pid(), "KILL");
    std::thread::sleep(Duration::from_millis(1500));
    assert!(
        p.child.try_wait().unwrap().is_none(),
        "the launcher still waits"
    );
    assert_eq!(p.termios(), childs, "the child's settings, untouched");
    assert_eq!(since(&p, before), "", "nothing written over the child");
    p.send(&[b'x'; 100]);
    p.send(b"\x1b[12;34R");
    assert_ne!(p.wait_exit(), 0, "the interface stopped: a failure");
    assert_eq!(p.termios(), p.initial, "restored once the child was done");
    let raw = String::from_utf8_lossy(&p.raw.lock().unwrap()).to_string();
    let done = raw.find("probe: done").expect("the child finished");
    let report = raw.find("the interface stopped").expect("reported");
    assert!(done < report, "the launcher spoke only after the child");
    assert!(p.dir.join("state/test/effect-handoff").exists());
    assert!(p.sessions().is_empty(), "the scratch removed");
}

#[test]
fn launcher_leaves_the_terminal_when_an_identity_cannot_be_read() {
    let (mut p, _dir) = frontend_killed_under_the_probe("fdeath-torn", true);
    let worker = p
        .sessions()
        .iter()
        .map(|s| s.join("req-3.worker-1"))
        .find(|w| w.exists())
        .expect("the child's identity");
    std::fs::write(&worker, "omb-proc 1\ntorn").unwrap();
    kill(p.frontend_pid(), "KILL");
    p.send(&[b'x'; 100]);
    p.send(b"\x1b[12;34R");
    p.wait_until("the child to finish", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("probe: done")
    });
    let left = p.termios();
    assert_ne!(left, p.initial, "the child left the terminal raw");
    assert_eq!(p.wait_exit(), 1, "not known to be over: a failure");
    assert_eq!(
        p.termios(),
        left,
        "the launcher did not take the terminal back"
    );
    let raw = String::from_utf8_lossy(&p.raw.lock().unwrap()).to_string();
    assert!(raw.contains("not known to be over"), "it says so");
    assert!(!p.sessions().is_empty(), "the scratch kept");
}

/// The frontend killed under a raw-mode child, with `entry` of the session
/// made a dangling link: an identity nothing can be read from, which is
/// never taken for the absence of one.
fn a_dangling_identity_leaves_the_terminal(name: &str, entry: &str) {
    let (mut p, _dir) = frontend_killed_under_the_probe(name, true);
    let session = p
        .sessions()
        .into_iter()
        .find(|s| s.join("req-3.worker-1").exists())
        .expect("the child's identity");
    let link = session.join(entry);
    let _ = std::fs::remove_file(&link);
    std::os::unix::fs::symlink(session.join("gone"), &link).unwrap();
    kill(p.frontend_pid(), "KILL");
    p.send(&[b'x'; 100]);
    p.send(b"\x1b[12;34R");
    p.wait_until("the child to finish", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("probe: done")
    });
    let left = p.termios();
    assert_ne!(left, p.initial, "the child left the terminal raw");
    assert_eq!(p.wait_exit(), 1, "not known to be over: a failure");
    assert_eq!(
        p.termios(),
        left,
        "the launcher did not take the terminal back"
    );
    let raw = String::from_utf8_lossy(&p.raw.lock().unwrap()).to_string();
    assert!(raw.contains("not known to be over"), "it says so");
    assert!(
        !raw.contains("Continuing in text"),
        "and no text interface follows"
    );
    assert!(session.is_dir(), "the scratch kept");
    assert!(
        link.symlink_metadata()
            .is_ok_and(|m| m.file_type().is_symlink()),
        "with the link in it"
    );
}

#[test]
fn launcher_leaves_the_terminal_on_a_dangling_worker_identity() {
    a_dangling_identity_leaves_the_terminal("fdeath-dangling-worker", "req-3.worker-1");
}

#[test]
fn launcher_leaves_the_terminal_on_a_dangling_core_identity() {
    a_dangling_identity_leaves_the_terminal("fdeath-dangling-core", "req-9.core");
}

#[test]
fn the_terminal_closes_during_a_live_request() {
    let mut p = Pty::start("hangup-live", Opts::default());
    p.conf("mutate", "sleep=3\n");
    p.dashboard();
    p.idle();
    p.select(1);
    p.send(b"\r");
    p.wait_for("Type test to continue");
    p.keys("test");
    p.send(b"\r");
    let t0 = Instant::now();
    while !p
        .sessions()
        .iter()
        .any(|s| s.join("req-3.worker-1").exists())
    {
        assert!(
            t0.elapsed() < Duration::from_secs(30),
            "the child did not start"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    let (f, state, tmp) = (p.frontend_pid(), p.dir.join("state"), p.dir.join("tmp"));
    let mut launcher = p.hang_up(false);
    let t0 = Instant::now();
    while launcher.try_wait().unwrap().is_none() {
        assert!(
            t0.elapsed() < Duration::from_secs(30),
            "the launcher outlived its terminal"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(!alive(f), "no frontend left");
    assert!(
        state.join("test/effect-mutate").exists(),
        "the core finished its work"
    );
    assert!(
        !state.join("ops/journey.omb").exists(),
        "a supervised completion"
    );
    assert_eq!(
        std::fs::read_dir(&tmp).unwrap().count(),
        0,
        "the scratch removed"
    );
}

#[test]
fn the_terminal_closes_during_a_handoff() {
    let mut p = Pty::start("hangup-handoff", Opts::default());
    start_handoff(&mut p);
    p.wait_until("the child", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("type a line and press Enter")
    });
    let (f, tmp) = (p.frontend_pid(), p.dir.join("tmp"));
    let mut launcher = p.hang_up(true);
    let t0 = Instant::now();
    while launcher.try_wait().unwrap().is_none() {
        assert!(
            t0.elapsed() < Duration::from_secs(30),
            "the launcher outlived its terminal"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(!alive(f), "no frontend left");
    assert_eq!(
        std::fs::read_dir(&tmp).unwrap().count(),
        0,
        "the scratch removed"
    );
}

// --- The launcher starts the verified artifact -------------------------------------------

/// A copy of the tool whose release/frontend.lock pins ARTIFACT (sealed),
/// for this host's target.
#[cfg(target_arch = "aarch64")]
fn tool_with_lock(dir: &Path, artifact: &[u8], target: &str) -> PathBuf {
    let tool = dir.join("tool");
    std::fs::create_dir_all(tool.join("release")).unwrap();
    std::fs::create_dir_all(tool.join("tests")).unwrap();
    for p in ["omarchy-bootstrap", "lib", "data"] {
        assert!(
            Command::new("cp")
                .arg("-R")
                .arg(repo().join(p))
                .arg(&tool)
                .status()
                .unwrap()
                .success()
        );
    }
    assert!(
        Command::new("cp")
            .arg("-R")
            .arg(repo().join("tests/children"))
            .arg(tool.join("tests"))
            .status()
            .unwrap()
            .success()
    );
    let body = format!(
        "omb-frontend-lock 1\nfrontend\tversion={}\tproto=1\tsource_commit={}\tinputs_digest={}\trust=1.88.0\nartifact\ttarget={target}\turl=https://example.invalid/omb-tui\tsize={}\tsha256={}\tminos=\tglibc_max=\tinterp=\talign_min=\n",
        omb_tui::core::VERSION,
        "0".repeat(40),
        "0".repeat(64),
        artifact.len(),
        omb_tui::record::sha256_hex(artifact),
    );
    let seal = omb_tui::record::sha256_hex(body.as_bytes());
    std::fs::write(
        tool.join("release/frontend.lock"),
        format!("{body}seal\tsha256={seal}\n"),
    )
    .unwrap();
    tool
}

/// MILESTONES.md → Gate 1's exit: the artifact built, verified and started by
/// the launcher. The artifact is OMB_TEST_ARTIFACT (CI's release build) or
/// this test build; the launcher acquires it from the fixture's network after
/// [Y/n], checks its size and SHA-256 against the lock, and starts it; a
/// second run starts it from the cache; a tampered cache copy is never run.
#[cfg(target_arch = "aarch64")]
#[test]
fn the_launcher_starts_the_verified_artifact() {
    let artifact =
        std::env::var("OMB_TEST_ARTIFACT").unwrap_or_else(|_| env!("CARGO_BIN_EXE_omb-tui").into());
    let bytes = std::fs::read(&artifact).unwrap();
    let target = if cfg!(target_os = "macos") {
        "aarch64-apple-darwin"
    } else {
        "aarch64-unknown-linux-gnu"
    };
    let name = "verified";
    let dir = scratch(name);
    let tool = tool_with_lock(&dir, &bytes, target);
    let opts = || Opts {
        home: Some(tool.clone()),
        dev: false,
        keep: true,
        ..Opts::default()
    };
    let mut p = Pty::start(name, opts());
    std::fs::write(p.fix.join(format!("net/frontend-{target}")), &bytes).unwrap();
    p.wait_until("the download prompt", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("Download and check it now?")
    });
    let raw = String::from_utf8_lossy(&p.raw.lock().unwrap()).to_string();
    assert!(
        raw.contains(&omb_tui::record::sha256_hex(&bytes)),
        "the pinned SHA-256 is shown before the download"
    );
    p.send(b"y\r");
    p.dashboard();
    p.idle();
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
    let cached = p.dir.join(format!(
        "home/.cache/omarchy-mac-bootstrap/frontend/{}/omb-tui",
        omb_tui::record::sha256_hex(&bytes)
    ));
    assert_eq!(
        std::fs::read(&cached).unwrap(),
        bytes,
        "the verified bytes are cached under their digest"
    );
    // A second run: from the cache, nothing downloaded, no prompt.
    std::fs::remove_file(p.fix.join(format!("net/frontend-{target}"))).unwrap();
    let mut p = Pty::start(name, opts());
    p.dashboard();
    p.idle();
    let raw = String::from_utf8_lossy(&p.raw.lock().unwrap()).to_string();
    assert!(
        !raw.contains("Download and check it now?"),
        "no download when the cache holds the pinned bytes"
    );
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
    // A tampered cache copy is never started; declining the move falls back.
    let mut b = bytes.clone();
    b.push(0);
    std::fs::write(&cached, &b).unwrap();
    let mut p = Pty::start(name, opts());
    p.wait_until("the mismatch", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("Move it aside")
    });
    p.send(b"n\r");
    p.wait_until("the text interface", |p| {
        String::from_utf8_lossy(&p.raw.lock().unwrap()).contains("Interface: mismatch")
    });
    assert!(p.sessions().is_empty(), "the frontend was never started");
    p.send(b"q\r");
    p.wait_exit();
}

// --- pty-gate2-read: the read surface through the launcher ----------------------

/// The ordinary fixture session the launcher starts (no foundation authority):
/// the Journey dashboard over the real journey read; a refresh whose running
/// state reaches the terminal before its answer replaces it; a detail opened
/// from the snapshot's generation; Health's counts and the doctor's findings,
/// and Logs' selected source and its lines, which this session's scopes (the
/// launcher's `FE_ALL_SCOPES`, `health` and `logs` among them) admit; the
/// plan check; and no execute anywhere. On Linux, which has no `plutil` for
/// the macOS fixtures, the same over a Linux fixture.
#[test]
fn pty_gate2_reads_through_the_launcher() {
    let mac = Path::new("/usr/bin/plutil").exists();
    let mut p = Pty::start(
        "gate2-read",
        Opts {
            rows: 40,
            cols: 120,
            env: vec![("OMB_TEST_FOUNDATION", String::new())],
            fixture: if mac {
                "mac-m1pro-1tb-roomy"
            } else {
                "linux-omarchy-installed"
            },
            ..Opts::default()
        },
    );
    p.wait_for("Nothing is available now.");
    p.wait_for("every station is later");
    p.idle();
    // r: drawn running before the answer, then answered.
    let before = p.raw.lock().unwrap().len();
    p.keys("r");
    p.wait_until("the refresh drawn running, then answered", |p| {
        let raw = String::from_utf8_lossy(&p.raw.lock().unwrap()[before..]).to_string();
        raw.contains("reading the journey") && !p.contents().contains("reading the journey")
    });
    // The machine detail, from the rail.
    p.send(b"\x1b[D");
    for _ in 0..8 {
        p.send(b"\x1b[A");
    }
    p.send(b"\x1b[B\x1b[B");
    p.send(b"\r");
    p.wait_for("rows 1–");
    p.wait_for("Architecture");
    p.idle();
    // Health, from the rail: the doctor's counts, then its findings.
    p.send(b"\x1b[D");
    for _ in 0..8 {
        p.send(b"\x1b[A");
    }
    p.send(b"\x1b[B\x1b[B\x1b[B\x1b[B");
    p.send(b"\r");
    p.wait_for("Supported model");
    p.idle();
    let f = p.contents();
    for want in [
        "Passed ",
        "Warnings ",
        "Failures ",
        "Apple Silicon",
        "rows 1–",
    ] {
        assert!(f.contains(want), "{want:?} on Health:\n{f}");
    }
    assert!(!f.contains("refused"), "Health is answered:\n{f}");
    // Logs: the selected source and its lines.
    let logs = p.dir.join("state").join("logs");
    std::fs::create_dir_all(&logs).unwrap();
    std::fs::write(
        logs.join("omarchy-bootstrap-29991231.log"),
        "2999-12-31T10:00:00Z [SURVEY] info   PTY_LOG_FIRST reading the disk\n2999-12-31T10:00:01Z [PLAN] warn   PTY_LOG_LAST below recommended\n",
    )
    .unwrap();
    p.keys("L");
    p.wait_for("PTY_LOG_LAST");
    p.idle();
    let f = p.contents();
    for want in [
        "omarchy-bootstrap-29991231.log",
        "PTY_LOG_FIRST reading the disk",
        "rows 1–2 of 2",
    ] {
        assert!(f.contains(want), "{want:?} on Logs:\n{f}");
    }
    assert!(!f.contains("refused"), "Logs is answered:\n{f}");
    // The plan check.
    p.send(b"\x1b[D");
    for _ in 0..8 {
        p.send(b"\x1b[A");
    }
    for _ in 0..6 {
        p.send(b"\x1b[B");
    }
    p.send(b"\r");
    p.wait_for("Linux size");
    p.keys("250GB");
    p.send(b"\t");
    p.keys("100GB");
    p.send(b"\r");
    if mac {
        p.wait_for("you type 614730MiB");
    } else {
        p.wait_for("refused · unavailable");
    }
    p.idle();
    p.send(b"\x1b");
    p.wait_for("Nothing is available now.");
    p.keys("q");
    assert_eq!(p.wait_exit(), 0);
    assert!(p.restored(), "the terminal came back");
    let trace = std::fs::read_to_string(p.dir.join("trace")).unwrap();
    // The ordinary session's scopes: every earlier one, in its order, then
    // the two accepted read scopes. frontend-check keeps `journey` alone
    // (tests/test-frontend-check.sh, frontend-check-read-session).
    let launcher = std::fs::read_to_string(repo().join("lib/frontend.sh")).unwrap();
    assert!(launcher.contains(
        "\nFE_ALL_SCOPES=\"journey,disk,plan,profile,resolve,asahi,network,omarchy,shared,export,restore,rescue,qualify,debug,health,logs\"\n"
    ));
    for want in [
        "send Detail(Page { kind: Machine",
        "send Read(Health)",
        "send Detail(Page { kind: Doctor",
        "send Read(Logs)",
        "send Detail(Page { kind: Log",
        "send Validate {",
    ] {
        assert!(trace.contains(want), "{want:?}: {trace}");
    }
    assert!(!trace.contains("send Execute"), "no execute: {trace}");
}

#[test]
fn pty_d55_operation_navigation_refresh_degradation_and_restoration() {
    for width in [80, 60] {
        let mut p = Pty::start(
            &format!("d55-{width}"),
            Opts {
                cols: width,
                ..Opts::default()
            },
        );
        p.dashboard();
        p.idle();
        let startup = std::fs::read_to_string(p.dir.join("trace")).unwrap();
        let sent: Vec<_> = startup.lines().filter(|l| l.starts_with("send ")).collect();
        assert_eq!(sent, ["send Hello", "send Snapshot"]);
        assert!(!p.dir.join("state").exists());
        p.send(b"\x1b[D");
        for _ in 0..8 {
            p.send(b"\x1b[A");
        }
        for _ in 0..7 {
            p.send(b"\x1b[B");
        }
        p.send(b"\r");
        p.wait_for("rows 1–");
        p.wait_for("State");
        p.idle();
        assert!(p.contents().contains("none"), "{}", p.contents());
        assert!(!p.dir.join("state").exists());

        // Only this test writes the hostile record. The read preserves it.
        let ops = p.dir.join("state/ops");
        std::fs::create_dir_all(&ops).unwrap();
        let record = ops.join("journey.omb");
        let hostile = b"omb-op 1\ntorn\0\x1b[2J\nHOSTILE_OPERATOR_CLEAR";
        std::fs::write(&record, hostile).unwrap();
        p.keys("r");
        p.wait_for("unreadable");
        p.idle();
        assert!(!p.contents().contains("HOSTILE_OPERATOR_CLEAR"));
        p.keys("/Worker");
        p.send(b"\r");
        p.wait_for("filter");
        p.send(b"\r");
        p.wait_for("value lines");
        assert!(p.contents().contains("unknown"), "{}", p.contents());
        p.master
            .resize(PtySize {
                rows: 20,
                cols: 59,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        p.wait_for("terminal too small");
        p.master
            .resize(PtySize {
                rows: 24,
                cols: width,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        p.wait_for("value lines");
        p.send(b"\x1b");
        p.keys("q");
        assert_eq!(p.wait_exit(), 0);
        assert!(p.restored());
        assert_eq!(p.termios(), p.initial);
        assert_eq!(std::fs::read(&record).unwrap(), hostile);
        assert_eq!(std::fs::read_dir(p.dir.join("state")).unwrap().count(), 1);
        assert_eq!(std::fs::read_dir(&ops).unwrap().count(), 1);
        assert_eq!(std::fs::read_dir(p.dir.join("home")).unwrap().count(), 0);
        let trace = std::fs::read_to_string(p.dir.join("trace")).unwrap();
        assert!(!trace.contains("send Execute") && !trace.contains("send Validate"));
        for line in trace.lines().filter(|l| l.starts_with("send Detail")) {
            assert!(
                line.contains("kind: Operation")
                    && line.contains("offset: 0")
                    && line.contains("limit: 500"),
                "{line}"
            );
        }
    }
}
