//! Exercise the actual Unix input backend without needing the core's process
//! table. The launcher/fixture regressions are separately in pty_hangup.
use super::*;
use portable_pty::{Child, CommandBuilder, PtySize, native_pty_system};
use std::path::Path;

struct OwnedChild {
    child: Box<dyn Child + Send + Sync>,
    active: bool,
}
impl Drop for OwnedChild {
    fn drop(&mut self) {
        if self.active {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

#[test]
fn native_poll_handles_partial_input_and_hangup() {
    if let Ok(trace) = std::env::var("OMB_INPUT_CHILD_TRACE") {
        let stop = Arc::new(AtomicBool::new(false));
        signal_hook::flag::register(signal_hook::consts::SIGTERM, stop.clone()).unwrap();
        // Exercise terminal loss independently of the shell's SIGHUP forwarding.
        // SAFETY: this child only; the signal callback has no shared state.
        unsafe {
            signal_hook::low_level::register(signal_hook::consts::SIGHUP, || {}).unwrap();
        }
        let mut term = start(false).unwrap();
        let flags = rustix::fs::fcntl_getfl(io::stdin()).unwrap();
        let mut log = std::fs::File::create(trace).unwrap();
        writeln!(log, "ready").unwrap();
        let mut keyed = false;
        loop {
            let input = term.poll(&stop, Duration::from_millis(20));
            assert_eq!(rustix::fs::fcntl_getfl(io::stdin()).unwrap(), flags);
            match input {
                Input::Event(event::Event::Key(k)) if k.code == event::KeyCode::Char('j') => {
                    keyed = true;
                    writeln!(log, "key j").unwrap();
                }
                Input::Idle if keyed => {
                    writeln!(log, "idle").unwrap();
                }
                Input::Gone(why) => {
                    writeln!(log, "gone {why}").unwrap();
                    break;
                }
                Input::Terminate => {
                    writeln!(log, "terminated").unwrap();
                    break;
                }
                _ => {}
            }
        }
        term.restore();
        writeln!(log, "restored").unwrap();
        // The harness cannot print its summary onto a hung-up terminal.
        std::process::exit(0);
    }
    for mode in ["hangup", "terminate"] {
        let trace = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!(
            ".artifacts/hangup/native-{}-{mode}.trace",
            std::process::id()
        ));
        std::fs::create_dir_all(trace.parent().unwrap()).unwrap();
        let _ = std::fs::remove_file(&trace);
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .unwrap();
        let mut cmd = CommandBuilder::new(std::env::current_exe().unwrap());
        cmd.args([
            "--exact",
            "terminal::input_tests::native_poll_handles_partial_input_and_hangup",
            "--nocapture",
        ]);
        cmd.env("OMB_INPUT_CHILD_TRACE", &trace);
        cmd.env("TERM", "xterm-256color");
        let mut child = OwnedChild {
            child: pair.slave.spawn_command(cmd).unwrap(),
            active: true,
        };
        drop(pair.slave);
        // A live PTY needs its output drained, including while the session
        // leader exits. No reader clone is kept for the master-close case.
        let reader = if mode == "terminate" {
            let mut reader = pair.master.try_clone_reader().unwrap();
            Some(std::thread::spawn(move || {
                let _ = io::copy(&mut reader, &mut io::sink());
            }))
        } else {
            None
        };
        let mut writer = pair.master.take_writer().unwrap();
        let wait_for = |s: &str| {
            let deadline = Instant::now() + Duration::from_secs(5);
            while !std::fs::read_to_string(&trace)
                .unwrap_or_default()
                .contains(s)
            {
                assert!(
                    Instant::now() < deadline,
                    "{mode}: missing {s}; {:?}",
                    std::fs::read_to_string(&trace)
                );
                std::thread::sleep(Duration::from_millis(10));
            }
        };
        wait_for("ready");
        writer.write_all(b"j").unwrap();
        writer.flush().unwrap();
        wait_for("key j");
        let idle_before = std::fs::read_to_string(&trace)
            .unwrap()
            .lines()
            .filter(|l| *l == "idle")
            .count();
        // A partial CSI sequence must not block read, swallow SIGTERM, or spin.
        writer.write_all(b"\x1b[").unwrap();
        writer.flush().unwrap();
        let idle_deadline = Instant::now() + Duration::from_secs(5);
        while std::fs::read_to_string(&trace)
            .unwrap()
            .lines()
            .filter(|l| *l == "idle")
            .count()
            < idle_before + 3
        {
            assert!(
                Instant::now() < idle_deadline,
                "partial input blocked polling"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        if mode == "terminate" {
            let pid =
                rustix::process::Pid::from_raw(child.child.process_id().unwrap() as i32).unwrap();
            rustix::process::kill_process(pid, rustix::process::Signal::TERM).unwrap();
        }
        let mut handles = Some((writer, pair.master));
        if mode == "hangup" {
            drop(handles.take());
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = child.child.try_wait().unwrap() {
                child.active = false;
                assert!(
                    status.success(),
                    "{mode}: {status:?}; {:?}",
                    std::fs::read_to_string(&trace)
                );
                break;
            }
            assert!(
                Instant::now() < deadline,
                "{mode}: input child did not exit; {:?}",
                std::fs::read_to_string(&trace)
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        drop(handles);
        if let Some(reader) = reader {
            reader.join().unwrap();
        }
        let log = std::fs::read_to_string(&trace).unwrap();
        if mode == "hangup" {
            assert!(log.contains("gone "), "{log}");
        } else {
            assert!(log.contains("terminated"), "{log}");
        }
    }
}
