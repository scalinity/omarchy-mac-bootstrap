//! Terminal loss regressions use the launcher's recorded frontend identity.
//! A failed assertion kills only the fresh process group this test created.
use super::*;
use omb_tui::record::{Family, admit};
use rustix::process::{Pid, Signal, WaitOptions, kill_process, kill_process_group, waitpid};

fn process_table_required() {
    let read = Command::new("ps")
        .args(["-p", &std::process::id().to_string(), "-o", "lstart="])
        .env("LC_ALL", "C")
        .output()
        .unwrap_or_else(|e| panic!("UNRUN: this PTY regression requires ps for PID/start ownership and CPU measurement: {e}"));
    assert!(
        read.status.success() && !read.stdout.is_empty(),
        "UNRUN: this PTY regression requires ps for recorded PID/start ownership and CPU measurement: {}",
        String::from_utf8_lossy(&read.stderr)
    );
}

fn options() -> Opts<'static> {
    Opts {
        fixture: if Path::new("/usr/bin/plutil").exists() {
            "mac-m1pro-1tb-roomy"
        } else {
            "linux-omarchy-installed"
        },
        ..Opts::default()
    }
}

struct OwnedGroup {
    pid: Pid,
    armed: bool,
}
impl OwnedGroup {
    fn new(p: &Pty) -> Self {
        // portable-pty creates this child in a new session and process group.
        Self {
            pid: Pid::from_raw(p.child.process_id().unwrap() as i32).unwrap(),
            armed: true,
        }
    }
}
impl Drop for OwnedGroup {
    fn drop(&mut self) {
        if self.armed {
            let _ = kill_process_group(self.pid, Signal::KILL);
            for _ in 0..100 {
                match waitpid(Some(self.pid), WaitOptions::NOHANG) {
                    Ok(None) => std::thread::sleep(Duration::from_millis(10)),
                    _ => break,
                }
            }
        }
    }
}

struct Frontend {
    pid: i32,
    start: String,
    #[cfg(target_os = "linux")]
    ticks: u64,
    #[cfg(target_os = "linux")]
    hz: f64,
}
impl Frontend {
    fn recorded(p: &Pty) -> Self {
        let pid = p.frontend_pid();
        let bytes = p
            .sessions()
            .iter()
            .find_map(|s| std::fs::read(s.join("frontend.omb")).ok())
            .unwrap();
        let doc = admit(Family::Proc, None, &bytes).expect("sealed frontend record");
        let r = &doc.records[0];
        assert_eq!(r.text("role"), Some("frontend"));
        assert_eq!(r.text("pid").unwrap().parse::<i32>().unwrap(), pid);
        let start = r.text("start").unwrap().to_string();
        #[cfg(target_os = "linux")]
        let (ticks, hz) = {
            let stat = std::fs::read(format!("/proc/{pid}/stat")).unwrap();
            let (_, ticks) = omb_tui::core::proctable::parse_stat(&stat).unwrap();
            let out = Command::new("getconf").arg("CLK_TCK").output().unwrap();
            assert!(out.status.success());
            let hz = String::from_utf8(out.stdout)
                .unwrap()
                .trim()
                .parse::<f64>()
                .unwrap();
            assert!(hz > 0.0);
            (ticks, hz)
        };
        let f = Self {
            pid,
            start,
            #[cfg(target_os = "linux")]
            ticks,
            #[cfg(target_os = "linux")]
            hz,
        };
        assert!(f.ps().is_some(), "PID/start must match the launcher record");
        f
    }
    fn ps(&self) -> Option<Duration> {
        let out = Command::new("ps")
            .args(["-p", &self.pid.to_string(), "-o", "lstart=", "-o", "time="])
            .env("LC_ALL", "C")
            .output()
            .unwrap();
        assert!(
            out.stderr.is_empty(),
            "could not read owned frontend: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let text = String::from_utf8(out.stdout).unwrap();
        let mut parts: Vec<_> = text.split_whitespace().collect();
        let time = parts.pop()?;
        if parts.join(" ") != self.start {
            return None;
        }
        assert!(out.status.success());
        Some(cpu_time(time))
    }
    #[cfg(target_os = "macos")]
    fn cpu(&self) -> Option<Duration> {
        self.ps()
    }
    #[cfg(target_os = "linux")]
    fn cpu(&self) -> Option<Duration> {
        let stat = match std::fs::read(format!("/proc/{}/stat", self.pid)) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
            Err(e) => panic!("owned frontend stat: {e}"),
        };
        let (_, ticks) = omb_tui::core::proctable::parse_stat(&stat).unwrap();
        if ticks != self.ticks {
            return None;
        }
        let tail = &stat[stat.iter().rposition(|&b| b == b')').unwrap() + 1..];
        let parts: Vec<_> = std::str::from_utf8(tail)
            .unwrap()
            .split_whitespace()
            .collect();
        let cpu = parts[11].parse::<u64>().unwrap() + parts[12].parse::<u64>().unwrap();
        Some(Duration::from_secs_f64(cpu as f64 / self.hz))
    }
    fn signal(&self, signal: Signal) {
        assert!(self.ps().is_some(), "signal only the recorded PID/start");
        kill_process(Pid::from_raw(self.pid).unwrap(), signal).unwrap();
    }
}

fn cpu_time(s: &str) -> Duration {
    let (days, time) = s
        .split_once('-')
        .map_or((0.0, s), |(d, t)| (d.parse::<f64>().unwrap(), t));
    let secs = time
        .split(':')
        .fold(0.0, |n, p| n * 60.0 + p.parse::<f64>().unwrap());
    Duration::from_secs_f64(days * 86400.0 + secs)
}

fn group_empty(group: i32) -> bool {
    let out = Command::new("ps")
        .args(["-axo", "pid=,pgid="])
        .output()
        .unwrap();
    assert!(out.status.success(), "process group must be readable");
    !String::from_utf8(out.stdout).unwrap().lines().any(|l| {
        l.split_whitespace()
            .nth(1)
            .and_then(|s| s.parse::<i32>().ok())
            == Some(group)
    })
}

fn exited(child: &mut dyn Child, f: &Frontend, group: i32, before: Duration) -> Duration {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut peak = before;
    loop {
        let cpu = f.cpu();
        if let Some(cpu) = cpu {
            peak = peak.max(cpu);
        }
        assert!(
            peak.saturating_sub(before) <= Duration::from_millis(250),
            "frontend used {:?} CPU after terminal loss",
            peak.saturating_sub(before)
        );
        if child.try_wait().unwrap().is_some() && cpu.is_none() && group_empty(group) {
            return peak.saturating_sub(before);
        }
        assert!(
            Instant::now() < deadline,
            "frontend or launcher survived terminal loss/termination for 5 s"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

pub(super) fn hangup_ends_the_session() {
    process_table_required();
    let p = Pty::start("hangup", options());
    let mut owner = OwnedGroup::new(&p);
    p.dashboard();
    p.idle();
    let f = Frontend::recorded(&p);
    let before = f.cpu().unwrap();
    let dir = p.dir.clone();
    let mut launcher = p.hang_up(false);
    let cpu = exited(&mut *launcher, &f, owner.pid.as_raw_nonzero().get(), before);
    eprintln!(
        "frontend {}: sampled CPU after hang-up {cpu:?} (limit 250 ms)",
        f.pid
    );
    owner.armed = false;
    assert_eq!(
        std::fs::read_dir(dir.join("tmp")).unwrap().count(),
        0,
        "owner removed session scratch"
    );
    let trace = std::fs::read_to_string(dir.join("trace")).unwrap();
    assert!(
        trace.contains("terminal gone:") || trace.contains("terminate signal"),
        "{trace}"
    );
    assert!(trace.contains("exit "), "frontend traced its exit: {trace}");
}

pub(super) fn signals_end_the_idle_session() {
    process_table_required();
    for signal in [Signal::TERM, Signal::HUP] {
        let p = Pty::start(&format!("sig-{signal:?}"), options());
        let mut owner = OwnedGroup::new(&p);
        p.dashboard();
        p.idle();
        let f = Frontend::recorded(&p);
        let before = f.cpu().unwrap();
        f.signal(signal);
        let mut p = p;
        let cpu = exited(&mut *p.child, &f, owner.pid.as_raw_nonzero().get(), before);
        eprintln!(
            "frontend {}: sampled CPU after {signal:?} {cpu:?} (limit 250 ms)",
            f.pid
        );
        owner.armed = false;
        assert!(p.restored(), "terminal restored after {signal:?}");
        assert!(p.sessions().is_empty());
        let trace = std::fs::read_to_string(p.dir.join("trace")).unwrap();
        assert!(
            trace.contains("terminate signal") && trace.contains("exit 0"),
            "{trace}"
        );
    }
}

#[test]
fn cpu_time_formats_keep_fractional_seconds() {
    assert_eq!(cpu_time("0:00.03"), Duration::from_millis(30));
    assert_eq!(cpu_time("01:02:03"), Duration::from_secs(3723));
    assert_eq!(cpu_time("1-00:00:01"), Duration::from_secs(86401));
}
