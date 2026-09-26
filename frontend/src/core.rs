//! The only process the frontend starts: the core, one per request
//! (docs/PROTOCOL.md → §3, *Descriptors*, *A request's life*).
//!
//! F creates the request's spool holding only its header, opens a pipe, and
//! spawns `omarchy-bootstrap core OP` with the pipe's read end as fd 3 and
//! nothing else beyond 0–2; it writes the request and closes its end at once.
//! A reader thread follows the spool (a read-only handle the main thread
//! opened) and passes each admitted record through a bounded channel; the end
//! of a response is the core's exit, observed with `waitpid`, plus exactly one
//! `result` as the last complete line. Every descriptor the standard library
//! opens is close-on-exec, and this module opens and spawns only on the main
//! thread.

use crate::app::{Outcome, Req};
use crate::record::{self, Admitter, Family, Op, Record, Refusal};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, TryRecvError, sync_channel};
use std::thread::JoinHandle;
use std::time::Duration;

/// The frontend's version, as the release lock names it.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
/// The records the reader may hold for the main thread.
pub const CHANNEL: usize = 1024;

/// What the reader thread passes on.
pub enum Spool {
    Record(Record),
    End(Result<record::Document, Refusal>),
}

/// The session the launcher made: its scratch folder and this tool's home.
pub struct Session {
    pub dir: PathBuf,
    pub home: PathBuf,
    pub id: String,
    pub fixture: bool,
    n: u32,
}

impl Session {
    pub fn new(dir: PathBuf, home: PathBuf, fixture: bool) -> Session {
        // A per-session id for the requests: not a secret, not an identity.
        let seed = format!(
            "{}:{}:{:?}",
            dir.display(),
            std::process::id(),
            std::time::SystemTime::now()
        );
        let id = record::sha256_hex(seed.as_bytes())[..16].to_string();
        Session {
            dir,
            home,
            id,
            fixture,
            n: 0,
        }
    }

    /// The request's bytes, in canonical form (docs/PROTOCOL.md → §4).
    pub fn request(&self, req: &Req) -> Vec<u8> {
        let op = op_of(req);
        let mut out = String::from("omb-req 1\n");
        out.push_str(&record::line(
            "req",
            &[
                ("op", op.name().as_bytes()),
                ("proto", b"1"),
                ("frontend", VERSION.as_bytes()),
                ("session", self.id.as_bytes()),
            ],
        ));
        match req {
            Req::Hello => {}
            Req::Snapshot => out.push_str(&record::line("scope", &[("name", b"journey")])),
            Req::Execute {
                action,
                basis,
                word,
                ..
            } => out.push_str(&record::line(
                "exec",
                &[
                    ("action", action.as_bytes()),
                    ("basis", basis.as_bytes()),
                    ("confirm", word.as_bytes()),
                ],
            )),
        }
        out.into_bytes()
    }

    /// Start a core for REQ. A handoff gets the terminal on 0–2; a managed
    /// request gets /dev/null (and, in fixture mode, stderr in the scratch for
    /// the tests to read).
    pub fn start(&mut self, req: &Req) -> io::Result<Running> {
        let body = self.request(req);
        self.start_raw(
            op_of(req),
            matches!(req, Req::Execute { handoff: true, .. }),
            &body,
        )
    }

    /// Start a core for OP with BODY as the request's bytes, taken as they
    /// are (the contract tests send malformed and over-long requests).
    pub fn start_raw(&mut self, op: Op, handoff: bool, body: &[u8]) -> io::Result<Running> {
        // The spool: created here, exclusively, holding only its header.
        let (events, n) = loop {
            self.n += 1;
            let p = self.dir.join(format!("req-{}.events", self.n));
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&p)
            {
                Ok(mut f) => {
                    f.write_all(b"omb-res 1\n")?;
                    break (p, self.n);
                }
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e),
            }
        };
        let spool = File::open(&events)?;
        let (rd, mut wr) = pipe()?;
        let mut cmd = Command::new(self.home.join("omarchy-bootstrap"));
        cmd.arg("core").arg(op.name()).env("OMB_EVENTS", &events);
        if handoff {
            cmd.stdin(Stdio::inherit())
                .stdout(Stdio::inherit())
                .stderr(Stdio::inherit());
        } else {
            cmd.stdin(Stdio::null()).stdout(Stdio::null());
            if self.fixture {
                let err = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(self.dir.join(format!("req-{n}.core-err")))?;
                cmd.stderr(err);
            } else {
                cmd.stderr(Stdio::null());
            }
        }
        let fd = rd.as_raw_fd();
        // SAFETY: the closure runs in the child between fork and exec, and
        // calls only dup2 and fcntl, which are async-signal-safe. It places
        // the request pipe's read end at fd 3 without close-on-exec (dup2
        // clears it on the new descriptor; when the pipe already is fd 3,
        // dup2 would change nothing, so the flag is cleared directly).
        unsafe {
            cmd.pre_exec(move || {
                let r = if fd == 3 {
                    os::fcntl(3, os::F_SETFD, 0)
                } else {
                    os::dup2(fd, 3)
                };
                if r == -1 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(())
                }
            });
        }
        let child = cmd.spawn()?;
        drop(rd);
        // An over-long request makes the core's bounded copy stop reading:
        // the write then fails (EPIPE, since Rust ignores SIGPIPE), which is a
        // refusal. The write end is closed as soon as it is written.
        let sent = wr.write_all(body);
        drop(wr);
        let (tx, rx) = sync_channel(CHANNEL);
        let done = Arc::new(AtomicBool::new(false));
        let reader = reader(spool, op, tx, done.clone());
        Ok(Running {
            child,
            reader: Some(reader),
            rx,
            done,
            n,
            sent,
            exited: false,
            end: None,
        })
    }

    /// The last request's kept diagnostics and the summaries, bounded, for
    /// the log screen: raw bytes, shown only through the display function.
    pub fn diagnostics(&self) -> Vec<String> {
        let mut out = Vec::new();
        for i in (1..=self.n).rev() {
            let p = self.dir.join(format!("req-{i}.diag"));
            if let Some(b) = read_bounded(&p, 262_144) {
                out.push(format!("request {i}:"));
                for l in b.split(|&c| c == b'\n') {
                    if !l.is_empty() {
                        out.push(record::display(l, 200));
                    }
                }
                if let Some(s) = read_bounded(&self.dir.join(format!("req-{i}.diag-summary")), 128)
                {
                    out.push(record::display(s.trim_ascii_end(), 200));
                }
                break;
            }
        }
        if let Some(s) = read_bounded(&self.dir.join("session.diag-summary"), 128) {
            let s = record::display(s.trim_ascii_end(), 200);
            if !s.contains("kept 0000000000, bytes discarded at least 0000000000") {
                out.push(format!("session: {s}"));
            }
        }
        out
    }
}

fn read_bounded(p: &Path, max: u64) -> Option<Vec<u8>> {
    let f = File::open(p).ok()?;
    let mut v = Vec::new();
    f.take(max).read_to_end(&mut v).ok()?;
    Some(v)
}

pub fn op_of(req: &Req) -> Op {
    match req {
        Req::Hello => Op::Hello,
        Req::Snapshot => Op::Snapshot,
        Req::Execute { .. } => Op::Execute,
    }
}

/// A pipe whose ends are both close-on-exec (the read end is placed at fd 3
/// in the core by `pre_exec`). On macOS the standard library sets the flag
/// in a second step; no other spawn can fall between the two, because this
/// thread is the only one that spawns.
fn pipe() -> io::Result<(std::io::PipeReader, std::io::PipeWriter)> {
    std::io::pipe()
}

/// The reader thread: follows the spool as it grows, admits what arrives,
/// and passes each admitted record on. It never touches the terminal. When
/// the main thread has seen the core exit, it reads what is left and gives
/// the verdict.
fn reader(spool: File, op: Op, tx: SyncSender<Spool>, done: Arc<AtomicBool>) -> JoinHandle<()> {
    std::thread::spawn(move || {
        #[cfg(feature = "test-hooks")]
        if std::env::var("OMB_TEST_HOOK").as_deref() == Ok("reader-panic") {
            panic!("test hook: the reader thread dies");
        }
        follow(spool, op, &tx, &done);
    })
}

/// The reader's loop over any byte source: admit what arrives, pass each
/// admitted record on, and once DONE is set (the core has exited) read what
/// is left and give the verdict.
pub fn follow<R: Read>(mut spool: R, op: Op, tx: &SyncSender<Spool>, done: &AtomicBool) {
    let mut adm = Admitter::new(Family::Res, Some(op));
    // The header was written by the frontend; admission reads it too.
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let finished = done.load(Ordering::Acquire);
        match spool.read(&mut buf) {
            Ok(0) if finished => break,
            Ok(0) => std::thread::sleep(Duration::from_millis(5)),
            Ok(n) => {
                for r in adm.push(&buf[..n]) {
                    if tx.send(Spool::Record(r)).is_err() {
                        return;
                    }
                }
            }
            // A signal interrupting a read: the call is retried.
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
    let _ = tx.send(Spool::End(adm.finish()));
}

#[cfg(test)]
mod tests {
    use super::*;

    /// sup-eintr: a read interrupted by a signal is retried, not taken as the
    /// end (the interruptions are injected, so the test does not depend on
    /// when a signal lands).
    #[test]
    fn an_interrupted_read_is_retried() {
        struct Flaky {
            data: Vec<u8>,
            at: usize,
            calls: usize,
        }
        impl Read for Flaky {
            fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
                self.calls += 1;
                if self.calls % 2 == 1 && self.at < self.data.len() {
                    return Err(io::Error::from(io::ErrorKind::Interrupted));
                }
                let n = buf.len().min(7).min(self.data.len() - self.at);
                buf[..n].copy_from_slice(&self.data[self.at..self.at + n]);
                self.at += n;
                Ok(n)
            }
        }
        let doc = b"omb-res 1\nhello\tcore=0.2.0\tcommit=\tsource=5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e\tproto=1\tplatform=macos\tarch=arm64\tuser=user\tceiling=act\tdry_run=0\tfixture=1\nresult\tstatus=done\tcode=ok\ttext=\tnext=\n";
        let (tx, rx) = sync_channel(CHANNEL);
        let done = AtomicBool::new(true);
        follow(
            Flaky {
                data: doc.to_vec(),
                at: 0,
                calls: 0,
            },
            Op::Hello,
            &tx,
            &done,
        );
        let mut records = 0;
        let mut end = None;
        while let Ok(m) = rx.try_recv() {
            match m {
                Spool::Record(_) => records += 1,
                Spool::End(v) => end = Some(v),
            }
        }
        assert_eq!(records, 2);
        assert!(
            end.unwrap().is_ok(),
            "the whole answer, despite every other read being interrupted"
        );
    }
}

/// A request in flight.
pub struct Running {
    pub child: Child,
    reader: Option<JoinHandle<()>>,
    rx: Receiver<Spool>,
    done: Arc<AtomicBool>,
    pub n: u32,
    sent: io::Result<()>,
    exited: bool,
    end: Option<Outcome>,
}

impl Running {
    /// Take in what has arrived; `Some` when the request has ended. Live
    /// records go to ON_RECORD. `hold` leaves the channel full (a test hook
    /// for a slow frontend): the reader then waits, and only the reader.
    pub fn poll(&mut self, on_record: &mut dyn FnMut(Record), hold: bool) -> Option<Outcome> {
        if let Some(o) = self.end.take() {
            return Some(o);
        }
        if !self.exited {
            match self.child.try_wait() {
                Ok(Some(_)) => {
                    self.exited = true;
                    self.done.store(true, Ordering::Release);
                }
                Ok(None) => {}
                Err(_) => {}
            }
        }
        if hold {
            return None;
        }
        loop {
            match self.rx.try_recv() {
                Ok(Spool::Record(r)) => on_record(r),
                Ok(Spool::End(verdict)) => {
                    if let Some(h) = self.reader.take() {
                        let _ = h.join();
                    }
                    return Some(self.outcome(verdict));
                }
                Err(TryRecvError::Empty) => return None,
                Err(TryRecvError::Disconnected) => {
                    // The reader died: once the core has exited, the outcome
                    // is unknown and the state is read again.
                    if self.exited {
                        self.reader.take();
                        return Some(Outcome::Unknown("the spool reader stopped".into()));
                    }
                    return None;
                }
            }
        }
    }

    fn outcome(&mut self, verdict: Result<record::Document, Refusal>) -> Outcome {
        // A request the core stopped reading (EPIPE: over its bound) was
        // refused before anything ran, whatever the spool then says.
        if let Err(e) = &self.sent {
            return Outcome::NotSent(format!("the request could not be written: {e}"));
        }
        match verdict {
            Ok(doc) => Outcome::Answer(doc.records),
            Err(r) => Outcome::Unknown(format!("{} at line {}", r.reason, r.at)),
        }
    }

    /// SIGTERM to the core, for a request declared cancellable.
    pub fn cancel(&self) {
        let _ = rustix::process::kill_process(
            rustix::process::Pid::from_child(&self.child),
            rustix::process::Signal::TERM,
        );
    }

    pub fn exited(&self) -> bool {
        self.exited
    }
}

/// Every descriptor this process inherited beyond 0, 1 and 2 is made
/// close-on-exec, so nothing a caller left open reaches the core or its
/// children (docs/PROTOCOL.md → *Descriptors*: F holds nothing else).
pub fn seal_inherited_descriptors() {
    for fd in 3..1024 {
        // SAFETY: fcntl on an integer that may not be an open descriptor only
        // returns EBADF; no Rust object owns or is invalidated by the flag.
        unsafe {
            let flags = os::fcntl(fd, os::F_GETFD, 0);
            if flags >= 0 && flags & os::FD_CLOEXEC == 0 {
                os::fcntl(fd, os::F_SETFD, flags | os::FD_CLOEXEC);
            }
        }
    }
}

/// Stop the whole job's group (Ctrl-Z): the launcher, the frontend, and
/// anything else in it stop and continue together.
pub fn stop_group() {
    let _ = rustix::process::kill_current_process_group(rustix::process::Signal::TSTP);
}

/// The C library calls the process model needs and rustix does not offer.
mod os {
    use std::os::raw::c_int;
    pub const F_GETFD: c_int = 1;
    pub const F_SETFD: c_int = 2;
    pub const FD_CLOEXEC: c_int = 1;
    unsafe extern "C" {
        pub fn dup2(old: c_int, new: c_int) -> c_int;
        pub fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
    }
}

/// The process table read directly — `/proc` on Linux, `libproc` on macOS —
/// spawning nothing (docs/PROTOCOL.md → *When something dies*). Identities
/// are compared only with ones read here.
pub mod proctable {
    use std::io;

    /// A process: its PID and its start time, in this module's own units.
    pub type Ident = (i32, u64);

    /// This process's group.
    pub fn my_group() -> i32 {
        rustix::process::getpgrp().as_raw_nonzero().get()
    }

    /// Every process now in process group PGID.
    #[cfg(target_os = "linux")]
    pub fn group(pgid: i32) -> io::Result<Vec<Ident>> {
        let mut out = Vec::new();
        for e in std::fs::read_dir("/proc")? {
            let Ok(e) = e else { continue };
            let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else {
                continue;
            };
            // A process can end between the listing and the reading.
            let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
                continue;
            };
            // The command (field 2) is in parentheses and may hold spaces:
            // the fields that follow start after the last ')'.
            let Some(rest) = stat.rfind(')').map(|i| &stat[i + 1..]) else {
                continue;
            };
            let f: Vec<&str> = rest.split_whitespace().collect();
            // Field 5 is the process group, field 22 the start time.
            let (Some(pg), Some(start)) = (
                f.get(2).and_then(|s| s.parse::<i32>().ok()),
                f.get(19).and_then(|s| s.parse::<u64>().ok()),
            ) else {
                continue;
            };
            if pg == pgid {
                out.push((pid, start));
            }
        }
        Ok(out)
    }

    /// Every process now in process group PGID.
    #[cfg(target_os = "macos")]
    pub fn group(pgid: i32) -> io::Result<Vec<Ident>> {
        use std::mem::{MaybeUninit, size_of};
        use std::os::raw::{c_int, c_void};
        let count = unsafe { ffi::proc_listallpids(std::ptr::null_mut(), 0) };
        if count <= 0 {
            return Err(io::Error::last_os_error());
        }
        // Room for processes started since the count.
        let mut pids = vec![0 as c_int; count as usize + 256];
        // SAFETY: the buffer is valid for its length in bytes, which is what
        // is passed; the call writes at most that many bytes of PIDs.
        let got = unsafe {
            ffi::proc_listallpids(
                pids.as_mut_ptr() as *mut c_void,
                (pids.len() * size_of::<c_int>()) as c_int,
            )
        };
        if got <= 0 {
            return Err(io::Error::last_os_error());
        }
        let mut out = Vec::new();
        for &pid in &pids[..(got as usize).min(pids.len())] {
            let mut info = MaybeUninit::<ffi::ProcBsdInfo>::zeroed();
            let size = size_of::<ffi::ProcBsdInfo>() as c_int;
            // SAFETY: the buffer is one ProcBsdInfo, zeroed, whose size is
            // passed; the call fills at most that many bytes and returns how
            // many. Only a full struct is read.
            let n = unsafe {
                ffi::proc_pidinfo(
                    pid,
                    ffi::PROC_PIDTBSDINFO,
                    0,
                    info.as_mut_ptr() as *mut c_void,
                    size,
                )
            };
            if n != size {
                // Ended since the listing, or another user's (the full record
                // needs the same user; a setuid program is one). The short
                // record needs no permission and names the group: a process
                // of this group whose start cannot be read has no identity,
                // and counts as present (docs/PROTOCOL.md → an identity that
                // cannot be established is possibly alive).
                if short_group(pid) == Some(pgid) {
                    out.push((pid, UNKNOWN_START));
                }
                continue;
            }
            // SAFETY: fully written by the call above (n == size).
            let info = unsafe { info.assume_init() };
            if info.pbi_pgid as i32 == pgid {
                out.push((
                    pid,
                    info.pbi_start_tvsec
                        .wrapping_mul(1_000_000)
                        .wrapping_add(info.pbi_start_tvusec),
                ));
            }
        }
        Ok(out)
    }

    /// The start of a process whose start cannot be read: never equal to a
    /// real one, so such a process is never taken for one in a snapshot.
    #[cfg(target_os = "macos")]
    pub const UNKNOWN_START: u64 = u64::MAX;

    /// A process's group from its short record, which any user may read.
    #[cfg(target_os = "macos")]
    fn short_group(pid: std::os::raw::c_int) -> Option<i32> {
        use std::mem::{MaybeUninit, size_of};
        use std::os::raw::{c_int, c_void};
        let mut short = MaybeUninit::<ffi::ProcBsdShortInfo>::zeroed();
        let size = size_of::<ffi::ProcBsdShortInfo>() as c_int;
        // SAFETY: the buffer is one ProcBsdShortInfo, zeroed, whose size is
        // passed; the call fills at most that many bytes and returns how
        // many. Only a full struct is read.
        let n = unsafe {
            ffi::proc_pidinfo(
                pid,
                ffi::PROC_PIDT_SHORTBSDINFO,
                0,
                short.as_mut_ptr() as *mut c_void,
                size,
            )
        };
        if n != size {
            return None;
        }
        // SAFETY: fully written by the call above (n == size).
        Some(unsafe { short.assume_init() }.pbsi_pgid as i32)
    }

    #[cfg(target_os = "macos")]
    mod ffi {
        use std::os::raw::{c_char, c_int, c_void};
        pub const PROC_PIDTBSDINFO: c_int = 3;
        pub const PROC_PIDT_SHORTBSDINFO: c_int = 13;
        /// `struct proc_bsdshortinfo` from <sys/proc_info.h>: 64 bytes,
        /// checked by a test. Readable for any process (no same-user check).
        #[repr(C)]
        pub struct ProcBsdShortInfo {
            pub pbsi_pid: u32,
            pub pbsi_ppid: u32,
            pub pbsi_pgid: u32,
            pub pbsi_status: u32,
            pub pbsi_comm: [c_char; 16],
            pub pbsi_flags: u32,
            pub pbsi_uid: u32,
            pub pbsi_gid: u32,
            pub pbsi_ruid: u32,
            pub pbsi_rgid: u32,
            pub pbsi_svuid: u32,
            pub pbsi_svgid: u32,
            pub pbsi_rfu: u32,
        }
        /// `struct proc_bsdinfo` from <sys/proc_info.h> (MAXCOMLEN 16): 136
        /// bytes, checked by a test.
        #[repr(C)]
        pub struct ProcBsdInfo {
            pub pbi_flags: u32,
            pub pbi_status: u32,
            pub pbi_xstatus: u32,
            pub pbi_pid: u32,
            pub pbi_ppid: u32,
            pub pbi_uid: u32,
            pub pbi_gid: u32,
            pub pbi_ruid: u32,
            pub pbi_rgid: u32,
            pub pbi_svuid: u32,
            pub pbi_svgid: u32,
            pub rfu_1: u32,
            pub pbi_comm: [c_char; 16],
            pub pbi_name: [c_char; 32],
            pub pbi_nfiles: u32,
            pub pbi_pgid: u32,
            pub pbi_pjobc: u32,
            pub e_tdev: u32,
            pub e_tpgid: u32,
            pub pbi_nice: i32,
            pub pbi_start_tvsec: u64,
            pub pbi_start_tvusec: u64,
        }
        unsafe extern "C" {
            pub fn proc_listallpids(buffer: *mut c_void, buffersize: c_int) -> c_int;
            pub fn proc_pidinfo(
                pid: c_int,
                flavor: c_int,
                arg: u64,
                buffer: *mut c_void,
                buffersize: c_int,
            ) -> c_int;
        }
    }

    /// The processes in GROUP now that were not in SNAPSHOT: the workers
    /// still present, after a handoff.
    pub fn present(pgid: i32, snapshot: &[Ident]) -> io::Result<Vec<i32>> {
        Ok(group(pgid)?
            .into_iter()
            .filter(|p| !snapshot.contains(p))
            .map(|p| p.0)
            .collect())
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn finds_this_process_in_its_group() {
            let me = std::process::id() as i32;
            let g = group(my_group()).unwrap();
            assert!(g.iter().any(|(p, _)| *p == me), "{me} not in {g:?}");
            // Read twice, a live process has the same identity.
            let a = g.iter().find(|(p, _)| *p == me).unwrap();
            let b = *group(my_group())
                .unwrap()
                .iter()
                .find(|(p, _)| *p == me)
                .unwrap();
            assert_eq!(*a, b);
        }

        #[cfg(target_os = "macos")]
        #[test]
        fn proc_bsdinfo_has_the_kernels_size() {
            assert_eq!(std::mem::size_of::<ffi::ProcBsdInfo>(), 136);
            assert_eq!(std::mem::size_of::<ffi::ProcBsdShortInfo>(), 64);
        }

        #[cfg(target_os = "macos")]
        #[test]
        fn the_short_record_names_the_group() {
            let me = std::process::id() as std::os::raw::c_int;
            assert_eq!(short_group(me), Some(my_group()));
        }

        #[test]
        fn a_new_process_is_present_until_it_ends() {
            let pg = my_group();
            let snap = group(pg).unwrap();
            let mut child = std::process::Command::new("sleep")
                .arg("2")
                .spawn()
                .unwrap();
            let id = child.id() as i32;
            assert!(present(pg, &snap).unwrap().contains(&id));
            child.kill().unwrap();
            child.wait().unwrap();
            assert!(!present(pg, &snap).unwrap().contains(&id));
        }
    }
}
