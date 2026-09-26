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
}

struct Opts<'a> {
    rows: u16,
    cols: u16,
    env: Vec<(&'a str, String)>,
    /// Run the launcher from an interactive shell (job control), as a person
    /// does, instead of as the terminal's first process.
    shell: bool,
}

impl Default for Opts<'_> {
    fn default() -> Self {
        Opts {
            rows: 24,
            cols: 80,
            env: Vec::new(),
            shell: false,
        }
    }
}

fn fixture(dir: &Path) -> PathBuf {
    let fix = dir.join("fixture");
    assert!(
        Command::new("cp")
            .arg("-R")
            .arg(repo().join("tests/fixtures/mac-m1pro-1tb-roomy"))
            .arg(&fix)
            .status()
            .unwrap()
            .success()
    );
    std::fs::create_dir_all(fix.join("test-children")).unwrap();
    fix
}

fn scratch(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("omb-pty-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("tmp")).unwrap();
    std::fs::create_dir_all(d.join("home")).unwrap();
    d
}

impl Pty {
    fn start(name: &str, o: Opts) -> Pty {
        let dir = scratch(name);
        let fix = fixture(&dir);
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
            cmd.arg(repo().join("omarchy-bootstrap"));
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
            ("OMB_STATE_DIR", dir.join("state").display().to_string()),
            ("OMB_FRONTEND_DEV", env!("CARGO_BIN_EXE_omb-tui").into()),
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
        std::thread::spawn(move || {
            let mut buf = [0u8; 8192];
            while let Ok(n) = reader.read(&mut buf) {
                if n == 0 {
                    break;
                }
                s2.lock().unwrap().process(&buf[..n]);
                r2.lock().unwrap().extend_from_slice(&buf[..n]);
            }
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
        };
        if o.shell {
            p.wait_for("$ ");
            let launcher = repo().join("omarchy-bootstrap");
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
