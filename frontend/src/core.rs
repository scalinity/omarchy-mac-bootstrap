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
    End(End),
}

/// How the reader's following of a spool ended.
#[derive(Debug)]
pub enum End {
    /// The core had exited and the spool was read to its end: admission's
    /// verdict on the whole of it.
    Complete(Result<record::Document, Refusal>),
    /// A read failed, other than by an interruption: what had been read is
    /// not an answer, however whole it looked.
    IoError(String),
    /// The reader thread panicked.
    ReaderPanic,
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
        let reader = reader(spool, op, n, tx, done.clone());
        Ok(Running {
            child,
            reader: Some(reader),
            rx,
            done,
            n,
            sent,
            exited: false,
            verdict: None,
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
/// the verdict. A panic in its body stops at the thread's boundary and
/// becomes its verdict; the panic hook, which runs first, restores nothing
/// from this thread (`terminal::own_panics`).
fn reader(
    spool: File,
    op: Op,
    n: u32,
    tx: SyncSender<Spool>,
    done: Arc<AtomicBool>,
) -> JoinHandle<()> {
    std::thread::spawn(move || {
        let body = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            test_hook_reader(n);
            follow(spool, op, &tx, &done);
        }));
        if body.is_err() {
            let _ = tx.send(Spool::End(End::ReaderPanic));
        }
    })
}

/// A test hook (the `test-hooks` feature, never in a release): the reader of
/// every request (`reader-panic`) or of request N (`reader-panic:N`) dies.
fn test_hook_reader(_n: u32) {
    #[cfg(feature = "test-hooks")]
    if let Ok(h) = std::env::var("OMB_TEST_HOOK")
        && (h == "reader-panic" || h == format!("reader-panic:{_n}"))
    {
        panic!("test hook: the reader thread dies");
    }
}

/// The reader's loop over any byte source: admit what arrives, pass each
/// admitted record on, and once DONE is set (the core has exited) read what
/// is left and give the verdict. A failed read ends it with that failure,
/// never with a verdict on what came before it.
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
            Err(e) => {
                let _ = tx.send(Spool::End(End::IoError(e.to_string())));
                return;
            }
        }
    }
    let _ = tx.send(Spool::End(End::Complete(adm.finish())));
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
            matches!(end, Some(End::Complete(Ok(_)))),
            "the whole answer, despite every other read being interrupted"
        );
    }

    const HELLO: &[u8] = b"omb-res 1\nhello\tcore=0.2.0\tcommit=\tsource=5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e5f2e\tproto=1\tplatform=macos\tarch=arm64\tuser=user\tceiling=act\tdry_run=0\tfixture=1\nresult\tstatus=done\tcode=ok\ttext=\tnext=\n";

    /// A spool whose read fails with EIO once AT bytes have been read.
    struct Broken {
        data: Vec<u8>,
        at: usize,
        pos: usize,
    }
    impl Read for Broken {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            if self.pos >= self.at {
                return Err(io::Error::from_raw_os_error(5));
            }
            let n = buf
                .len()
                .min(self.at - self.pos)
                .min(self.data.len() - self.pos);
            buf[..n].copy_from_slice(&self.data[self.pos..self.pos + n]);
            self.pos += n;
            Ok(n)
        }
    }

    /// How following DATA ends when its read fails at AT (the core has
    /// exited, so the end of the bytes would be the end of the answer).
    fn end_of(data: &[u8], at: usize) -> End {
        let (tx, rx) = sync_channel(CHANNEL);
        let src = Broken {
            data: data.to_vec(),
            at,
            pos: 0,
        };
        follow(src, Op::Hello, &tx, &AtomicBool::new(true));
        drop(tx);
        rx.iter()
            .find_map(|m| match m {
                Spool::End(e) => Some(e),
                Spool::Record(_) => None,
            })
            .expect("a verdict")
    }

    /// H03: a read that fails is never the end of the stream, wherever it
    /// falls — even after a whole, valid answer.
    #[test]
    fn a_failed_read_is_never_the_end_of_the_answer() {
        let hello_end = HELLO.iter().position(|&b| b == b'\n').unwrap() + 1;
        let hello_end =
            hello_end + HELLO[hello_end..].iter().position(|&b| b == b'\n').unwrap() + 1;
        for (at, what) in [
            (0, "before the header"),
            (5, "in the header"),
            (10, "after the header"),
            (40, "in a record"),
            (hello_end, "after hello"),
            (HELLO.len(), "after a valid result"),
        ] {
            let end = end_of(HELLO, at);
            assert!(matches!(end, End::IoError(_)), "EIO {what}: {end:?}");
        }
        let junk = [HELLO, b"junk\n"].concat();
        let end = end_of(&junk, HELLO.len());
        assert!(
            matches!(end, End::IoError(_)),
            "EIO before trailing bytes: {end:?}"
        );
        // The same bytes, read whole, are the answer.
        assert!(matches!(end_of(HELLO, usize::MAX), End::Complete(Ok(_))));
    }

    fn running(child: std::process::Child, rx: Receiver<Spool>) -> Running {
        Running {
            child,
            reader: None,
            rx,
            done: Arc::new(AtomicBool::new(false)),
            n: 1,
            sent: Ok(()),
            exited: false,
            verdict: None,
        }
    }

    fn settle(r: &mut Running) -> Outcome {
        let t0 = std::time::Instant::now();
        loop {
            if let Some(o) = r.poll(&mut |_| {}, false) {
                return o;
            }
            assert!(
                t0.elapsed() < Duration::from_secs(10),
                "the request never ended"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// H03: whatever the reader says, and whenever it stops, a request ends
    /// only once its core has exited.
    #[test]
    fn nothing_ends_before_the_core_has_exited() {
        let whole = || End::Complete(record::admit(Family::Res, Some(Op::Hello), HELLO));
        let cases: [(&str, Option<End>, &str); 4] = [
            ("a whole answer", Some(whole()), "answer"),
            (
                "an I/O error after a valid result",
                Some(End::IoError("EIO".into())),
                "could not be read",
            ),
            (
                "a reader that panicked",
                Some(End::ReaderPanic),
                "reader stopped",
            ),
            ("a reader gone without a word", None, "reader stopped"),
        ];
        for (what, verdict, then) in cases {
            let (tx, rx) = sync_channel(CHANNEL);
            let core = Command::new("sleep").arg("30").spawn().unwrap();
            let mut r = running(core, rx);
            match verdict {
                Some(v) => tx.send(Spool::End(v)).unwrap(),
                None => drop(tx),
            }
            for _ in 0..40 {
                assert!(
                    r.poll(&mut |_| {}, false).is_none(),
                    "{what}: ended while the core runs"
                );
                std::thread::sleep(Duration::from_millis(5));
            }
            r.child.kill().unwrap();
            let o = settle(&mut r);
            match (&o, then) {
                (Outcome::Answer(_), "answer") => {}
                (Outcome::Unknown(w), t) if w.contains(t) => {}
                _ => panic!("{what}: {o:?}"),
            }
        }
    }

    /// H03: a core whose state cannot be read (collected by another, so
    /// waitpid fails) is lost at once, not polled for ever.
    #[test]
    fn a_core_whose_state_cannot_be_read_is_lost() {
        let (_tx, rx) = sync_channel(CHANNEL);
        let core = Command::new("sleep").arg("0").spawn().unwrap();
        let pid = rustix::process::Pid::from_raw(core.id() as i32).unwrap();
        rustix::process::waitpid(Some(pid), rustix::process::WaitOptions::empty()).unwrap();
        let mut r = running(core, rx);
        match r.poll(&mut |_| {}, false) {
            Some(Outcome::Lost(w)) => assert!(w.contains("could not be read"), "{w}"),
            o => panic!("{o:?}"),
        }
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
    verdict: Option<End>,
}

impl Running {
    /// Take in what has arrived; `Some` when the request has ended. Live
    /// records go to ON_RECORD. `hold` leaves the channel full (a test hook
    /// for a slow frontend): the reader then waits, and only the reader.
    ///
    /// A request ends only once the core has exited and the reader has given
    /// its verdict: a reader that failed or died early leaves the request
    /// running until the core is gone. A core whose state cannot be read is
    /// `Lost` at once — nothing will ever say it has ended.
    pub fn poll(&mut self, on_record: &mut dyn FnMut(Record), hold: bool) -> Option<Outcome> {
        if !self.exited {
            match self.child.try_wait() {
                Ok(Some(_)) => {
                    self.exited = true;
                    self.done.store(true, Ordering::Release);
                }
                Ok(None) => {}
                Err(e) => {
                    return Some(Outcome::Lost(format!(
                        "the state of core {} could not be read ({e})",
                        self.child.id()
                    )));
                }
            }
        }
        if hold {
            return None;
        }
        while self.verdict.is_none() {
            match self.rx.try_recv() {
                Ok(Spool::Record(r)) => on_record(r),
                Ok(Spool::End(v)) => self.verdict = Some(v),
                Err(TryRecvError::Empty) => break,
                // The reader ended without a verdict.
                Err(TryRecvError::Disconnected) => self.verdict = Some(End::ReaderPanic),
            }
        }
        if !self.exited {
            return None;
        }
        let verdict = self.verdict.take()?;
        if let Some(h) = self.reader.take() {
            let _ = h.join();
        }
        Some(self.outcome(verdict))
    }

    fn outcome(&mut self, verdict: End) -> Outcome {
        // A request the core stopped reading (EPIPE: over its bound) was
        // refused before anything ran, whatever the spool then says.
        if let Err(e) = &self.sent {
            return Outcome::NotSent(format!("the request could not be written: {e}"));
        }
        match verdict {
            End::Complete(Ok(doc)) => Outcome::Answer(doc.records),
            End::Complete(Err(r)) => Outcome::Unknown(format!("{} at line {}", r.reason, r.at)),
            End::IoError(e) => Outcome::Unknown(format!("the response could not be read: {e}")),
            End::ReaderPanic => Outcome::Unknown("the response reader stopped".into()),
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
/// children (docs/PROTOCOL.md → *Descriptors*: F holds nothing else). The
/// descriptors are the ones the kernel lists as open — no numeric ceiling,
/// however high a caller placed one. A descriptor that cannot be sealed, or
/// a list that cannot be read, is an error: the caller does not go on.
pub fn seal_inherited_descriptors() -> io::Result<()> {
    #[cfg(feature = "test-hooks")]
    if std::env::var("OMB_TEST_HOOK").as_deref() == Ok("seal-fails") {
        return Err(io::Error::other("test hook: sealing fails"));
    }
    for fd in open_descriptors()? {
        if fd < 3 {
            continue;
        }
        // SAFETY: fcntl on an integer that may not be an open descriptor only
        // returns EBADF; no Rust object owns or is invalidated by the flag.
        let flags = unsafe { os::fcntl(fd, os::F_GETFD, 0) };
        if flags == -1 {
            let e = io::Error::last_os_error();
            // Closed since the listing (the listing's own handle is one).
            if e.raw_os_error() == Some(os::EBADF) {
                continue;
            }
            return Err(e);
        }
        if flags & os::FD_CLOEXEC == 0 {
            // SAFETY: as above.
            if unsafe { os::fcntl(fd, os::F_SETFD, flags | os::FD_CLOEXEC) } == -1 {
                return Err(io::Error::last_os_error());
            }
        }
    }
    Ok(())
}

/// The descriptors open in this process, as the kernel lists them.
#[cfg(target_os = "linux")]
pub fn open_descriptors() -> io::Result<Vec<i32>> {
    let mut out = Vec::new();
    for e in std::fs::read_dir("/proc/self/fd")? {
        let name = e?.file_name();
        match name.to_str().and_then(|s| s.parse::<i32>().ok()) {
            Some(fd) => out.push(fd),
            None => {
                return Err(io::Error::other(format!(
                    "/proc/self/fd lists {name:?}, not a descriptor"
                )));
            }
        }
    }
    Ok(out)
}

/// The descriptors open in this process, as the kernel lists them.
#[cfg(target_os = "macos")]
pub fn open_descriptors() -> io::Result<Vec<i32>> {
    use std::mem::size_of;
    use std::os::raw::{c_int, c_void};
    let me = std::process::id() as c_int;
    let each = size_of::<proctable::ffi::ProcFdInfo>();
    // SAFETY: with no buffer, the call only reports the size it needs.
    let need = unsafe {
        proctable::ffi::proc_pidinfo(
            me,
            proctable::ffi::PROC_PIDLISTFDS,
            0,
            std::ptr::null_mut(),
            0,
        )
    };
    if need <= 0 {
        return Err(io::Error::last_os_error());
    }
    // Room for descriptors opened since; a list that fills it may be cut
    // short, so it is read again with more room.
    let mut room = need as usize / each + 64;
    for _ in 0..8 {
        let mut buf = vec![
            proctable::ffi::ProcFdInfo {
                proc_fd: 0,
                proc_fdtype: 0
            };
            room
        ];
        let size = (room * each) as c_int;
        // SAFETY: the buffer is ROOM entries, SIZE bytes, which is what is
        // passed; the call writes at most that many bytes and returns how
        // many.
        let got = unsafe {
            proctable::ffi::proc_pidinfo(
                me,
                proctable::ffi::PROC_PIDLISTFDS,
                0,
                buf.as_mut_ptr() as *mut c_void,
                size,
            )
        };
        if got <= 0 {
            return Err(io::Error::last_os_error());
        }
        if got < size {
            buf.truncate(got as usize / each);
            return Ok(buf.iter().map(|f| f.proc_fd).collect());
        }
        room *= 2;
    }
    Err(io::Error::other("the descriptor list kept growing"))
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
    pub const EBADF: c_int = 9;
    unsafe extern "C" {
        pub fn dup2(old: c_int, new: c_int) -> c_int;
        pub fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
    }
}

/// The process table read directly — `/proc` on Linux, `libproc` on macOS —
/// spawning nothing (docs/PROTOCOL.md → *When something dies*). Identities
/// are compared only with ones read here. A process that cannot be read is
/// never taken for one that is not there: it is possibly present, and a
/// group holding one is not quiescent.
pub mod proctable {
    use std::io;

    /// A process's start time, in this module's own units, or unknown when
    /// it cannot be read. An unknown start equals nothing — not a known one,
    /// and not another unknown one.
    #[derive(Clone, Copy, Debug)]
    pub enum Start {
        Known(u64),
        Unknown,
    }

    /// A process: its PID and its start.
    #[derive(Clone, Copy, Debug)]
    pub struct Ident {
        pub pid: i32,
        pub start: Start,
    }

    impl Ident {
        /// The same process: the same PID with the same, known, start.
        pub fn same(&self, o: &Ident) -> bool {
            self.pid == o.pid
                && matches!((self.start, o.start), (Start::Known(a), Start::Known(b)) if a == b)
        }
    }

    /// One process as the table gave it.
    #[derive(Debug, PartialEq, Eq)]
    pub enum Entry {
        /// Ended since the listing: not present.
        Gone,
        /// Its group and its start.
        Known { pgid: i32, start: u64 },
        /// Its group, but not its start.
        GroupOnly { pgid: i32 },
        /// Nothing could be read: it may be in any group.
        Unreadable,
    }

    /// A reading of one process group.
    #[derive(Debug, Default)]
    pub struct Group {
        /// Every process read as a member.
        pub members: Vec<Ident>,
        /// Processes whose group could not be read: any may be a member.
        pub unreadable: Vec<i32>,
    }

    impl Group {
        pub fn add(&mut self, pgid: i32, pid: i32, e: Entry) {
            match e {
                Entry::Known { pgid: g, start } if g == pgid => self.members.push(Ident {
                    pid,
                    start: Start::Known(start),
                }),
                Entry::GroupOnly { pgid: g } if g == pgid => self.members.push(Ident {
                    pid,
                    start: Start::Unknown,
                }),
                Entry::Unreadable => self.unreadable.push(pid),
                Entry::Gone | Entry::Known { .. } | Entry::GroupOnly { .. } => {}
            }
        }

        /// Every member is known: fit to be a snapshot.
        pub fn whole(&self) -> bool {
            self.unreadable.is_empty()
                && self
                    .members
                    .iter()
                    .all(|m| matches!(m.start, Start::Known(_)))
        }

        /// The members that are not in SNAPSHOT: the workers present. An
        /// error when that cannot be established, because a process whose
        /// group could not be read may be one.
        pub fn workers(&self, snapshot: &[Ident]) -> io::Result<Vec<i32>> {
            if !self.unreadable.is_empty() {
                return Err(io::Error::other(format!(
                    "{} process(es) could not be read: {:?}",
                    self.unreadable.len(),
                    self.unreadable
                )));
            }
            Ok(self
                .members
                .iter()
                .filter(|p| !snapshot.iter().any(|s| s.same(p)))
                .map(|p| p.pid)
                .collect())
        }
    }

    /// This process's group.
    pub fn my_group() -> i32 {
        rustix::process::getpgrp().as_raw_nonzero().get()
    }

    /// The processes in GROUP now that were not in SNAPSHOT: the workers
    /// still present. An error when the table, or any process in it, cannot
    /// be read.
    pub fn present(pgid: i32, snapshot: &[Ident]) -> io::Result<Vec<i32>> {
        group(pgid)?.workers(snapshot)
    }

    /// The process group (field 5) and start time (field 22) from the bytes
    /// of /proc/PID/stat. The command (field 2) is in parentheses and may
    /// hold any byte but NUL — spaces, parentheses, bytes that are not UTF-8
    /// — so the fields that follow start after the last ')'.
    pub fn parse_stat(stat: &[u8]) -> Option<(i32, u64)> {
        let open = stat.iter().position(|&b| b == b'(')?;
        let close = stat.iter().rposition(|&b| b == b')')?;
        if close < open {
            return None;
        }
        let f: Vec<&[u8]> = stat[close + 1..]
            .split(|b| b.is_ascii_whitespace())
            .filter(|s| !s.is_empty())
            .collect();
        // After the command: state (3), parent (4), group (5), ... start (22).
        let pgid = std::str::from_utf8(f.get(2)?).ok()?.parse().ok()?;
        let start = std::str::from_utf8(f.get(19)?).ok()?.parse().ok()?;
        Some((pgid, start))
    }

    /// A Linux process's entry from reading its stat. GONE says whether
    /// /proc no longer holds the process, asked only when the stat could
    /// not be used (it may have ended while being read).
    pub fn linux_entry(read: io::Result<Vec<u8>>, gone: impl FnOnce() -> bool) -> Entry {
        const ESRCH: i32 = 3;
        let e = match read {
            Ok(b) => match parse_stat(&b) {
                Some((pgid, start)) => return Entry::Known { pgid, start },
                None => Entry::Unreadable,
            },
            Err(e) if e.kind() == io::ErrorKind::NotFound || e.raw_os_error() == Some(ESRCH) => {
                return Entry::Gone;
            }
            Err(_) => Entry::Unreadable,
        };
        if gone() { Entry::Gone } else { e }
    }

    /// Every process now in process group PGID.
    #[cfg(target_os = "linux")]
    pub fn group(pgid: i32) -> io::Result<Group> {
        let mut g = Group::default();
        for e in std::fs::read_dir("/proc")? {
            // A listing that cannot be read is no reading.
            let e = e?;
            // Entries whose names are not numbers are not processes.
            let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<i32>().ok()) else {
                continue;
            };
            let entry = linux_entry(std::fs::read(format!("/proc/{pid}/stat")), || {
                matches!(std::fs::metadata(format!("/proc/{pid}")),
                    Err(ref e) if e.kind() == io::ErrorKind::NotFound)
            });
            g.add(pgid, pid, entry);
        }
        Ok(g)
    }

    /// A macOS process's entry from its full record (group, start) or the
    /// errno that refused it, and, when that fails, from its short record
    /// (group only, readable for any user's process).
    pub fn mac_entry(
        full: Result<(i32, u64), i32>,
        short: impl FnOnce() -> Result<i32, i32>,
    ) -> Entry {
        const ESRCH: i32 = 3;
        match full {
            Ok((pgid, start)) => Entry::Known { pgid, start },
            Err(ESRCH) => Entry::Gone,
            // Another user's (a setuid program is one), or cut short.
            Err(_) => match short() {
                Ok(pgid) => Entry::GroupOnly { pgid },
                Err(ESRCH) => Entry::Gone,
                Err(_) => Entry::Unreadable,
            },
        }
    }

    /// Every process now in process group PGID.
    #[cfg(target_os = "macos")]
    pub fn group(pgid: i32) -> io::Result<Group> {
        let mut g = Group::default();
        for pid in all_pids()? {
            g.add(pgid, pid, mac_entry(full_record(pid), || short_group(pid)));
        }
        Ok(g)
    }

    /// Every PID now, from a list the call did not have to cut short.
    #[cfg(target_os = "macos")]
    fn all_pids() -> io::Result<Vec<i32>> {
        use std::mem::size_of;
        use std::os::raw::{c_int, c_void};
        // SAFETY: with no buffer, the call only counts.
        let count = unsafe { ffi::proc_listallpids(std::ptr::null_mut(), 0) };
        if count <= 0 {
            return Err(io::Error::last_os_error());
        }
        let mut room = count as usize + 256;
        for _ in 0..8 {
            let mut pids = vec![0 as c_int; room];
            // SAFETY: the buffer is valid for its length in bytes, which is
            // what is passed; the call writes at most that many bytes of PIDs
            // and returns how many PIDs it wrote.
            let got = unsafe {
                ffi::proc_listallpids(
                    pids.as_mut_ptr() as *mut c_void,
                    (room * size_of::<c_int>()) as c_int,
                )
            };
            if got <= 0 {
                return Err(io::Error::last_os_error());
            }
            if (got as usize) < room {
                pids.truncate(got as usize);
                return Ok(pids);
            }
            room *= 2;
        }
        Err(io::Error::other("the process list kept growing"))
    }

    /// A process's group and start from its full record, or the errno.
    #[cfg(target_os = "macos")]
    fn full_record(pid: i32) -> Result<(i32, u64), i32> {
        use std::mem::{MaybeUninit, size_of};
        use std::os::raw::{c_int, c_void};
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
            return Err(errno_or(n));
        }
        // SAFETY: fully written by the call above (n == size).
        let info = unsafe { info.assume_init() };
        Ok((
            info.pbi_pgid as i32,
            info.pbi_start_tvsec
                .wrapping_mul(1_000_000)
                .wrapping_add(info.pbi_start_tvusec),
        ))
    }

    /// A process's group from its short record, which any user may read.
    #[cfg(target_os = "macos")]
    fn short_group(pid: i32) -> Result<i32, i32> {
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
            return Err(errno_or(n));
        }
        // SAFETY: fully written by the call above (n == size).
        Ok(unsafe { short.assume_init() }.pbsi_pgid as i32)
    }

    /// The errno of a failed call; a call that returned a short record set
    /// none, and that is not ESRCH.
    #[cfg(target_os = "macos")]
    fn errno_or(n: std::os::raw::c_int) -> i32 {
        if n > 0 {
            return -1;
        }
        io::Error::last_os_error().raw_os_error().unwrap_or(-1)
    }

    #[cfg(target_os = "macos")]
    pub(crate) mod ffi {
        use std::os::raw::{c_char, c_int, c_void};
        pub const PROC_PIDLISTFDS: c_int = 1;
        pub const PROC_PIDTBSDINFO: c_int = 3;
        pub const PROC_PIDT_SHORTBSDINFO: c_int = 13;
        /// `struct proc_fdinfo` from <sys/proc_info.h>: 8 bytes.
        #[repr(C)]
        #[derive(Clone, Copy)]
        pub struct ProcFdInfo {
            pub proc_fd: i32,
            pub proc_fdtype: u32,
        }
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

    #[cfg(test)]
    mod tests {
        use super::*;

        fn member(g: &Group, pid: i32) -> Option<Ident> {
            g.members.iter().find(|m| m.pid == pid).copied()
        }

        #[test]
        fn finds_this_process_in_its_group() {
            let me = std::process::id() as i32;
            let g = group(my_group()).unwrap();
            let a = member(&g, me).expect("this process in its group");
            assert!(matches!(a.start, Start::Known(_)), "{a:?}");
            // Read twice, a live process is the same process.
            let b = member(&group(my_group()).unwrap(), me).unwrap();
            assert!(a.same(&b));
        }

        #[cfg(target_os = "macos")]
        #[test]
        fn the_kernel_records_have_their_sizes() {
            assert_eq!(std::mem::size_of::<ffi::ProcBsdInfo>(), 136);
            assert_eq!(std::mem::size_of::<ffi::ProcBsdShortInfo>(), 64);
            assert_eq!(std::mem::size_of::<ffi::ProcFdInfo>(), 8);
        }

        #[cfg(target_os = "macos")]
        #[test]
        fn the_short_record_names_the_group() {
            let me = std::process::id() as i32;
            assert_eq!(short_group(me), Ok(my_group()));
        }

        #[test]
        fn a_new_process_is_present_until_it_ends() {
            let pg = my_group();
            let snap = group(pg).unwrap().members;
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

        /// A live child whose command is NAME (a link to sleep so named) is
        /// read as a member of this group, with its start.
        /// Returns the child's stat as read once it ran under NAME (Linux).
        fn a_child_named(name: &std::ffi::OsStr) -> Vec<u8> {
            use std::sync::atomic::{AtomicUsize, Ordering};
            static N: AtomicUsize = AtomicUsize::new(0);
            let d = std::env::temp_dir().join(format!(
                "omb-proctable-{}-{}",
                std::process::id(),
                N.fetch_add(1, Ordering::SeqCst)
            ));
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(&d).unwrap();
            let link = d.join(name);
            std::os::unix::fs::symlink("/bin/sleep", &link).unwrap();
            let mut child = std::process::Command::new(&link).arg("5").spawn().unwrap();
            let id = child.id() as i32;
            // Until its exec, the child runs under this test's own name.
            let stat = running_as(id, name);
            let g = group(my_group()).unwrap();
            let seen = member(&g, id);
            child.kill().unwrap();
            child.wait().unwrap();
            let _ = std::fs::remove_dir_all(&d);
            let seen = seen.unwrap_or_else(|| panic!("{name:?} ({id}) not read as a member"));
            assert!(matches!(seen.start, Start::Known(_)), "{seen:?}");
            stat
        }

        /// ID's stat once its command (field 2) is NAME, as the kernel keeps
        /// it (at most 15 bytes).
        #[cfg(target_os = "linux")]
        fn running_as(id: i32, name: &std::ffi::OsStr) -> Vec<u8> {
            use std::os::unix::ffi::OsStrExt;
            let n = name.as_bytes();
            let want = [b"(".as_slice(), &n[..n.len().min(15)], b")"].concat();
            let t0 = std::time::Instant::now();
            loop {
                let stat = std::fs::read(format!("/proc/{id}/stat")).unwrap_or_default();
                if stat.windows(want.len()).any(|w| w == want.as_slice()) {
                    return stat;
                }
                assert!(
                    t0.elapsed() < std::time::Duration::from_secs(10),
                    "{id} never ran as {name:?}"
                );
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        }

        #[cfg(not(target_os = "linux"))]
        fn running_as(_: i32, _: &std::ffi::OsStr) -> Vec<u8> {
            std::thread::sleep(std::time::Duration::from_millis(200));
            Vec::new()
        }

        #[test]
        fn a_command_with_parentheses_and_spaces_is_read() {
            let stat = a_child_named(std::ffi::OsStr::new("omb) (x y"));
            if cfg!(target_os = "linux") {
                assert!(parse_stat(&stat).is_some(), "{stat:?}");
            }
        }

        /// The review's counterexample: a live process of the group whose
        /// command is not UTF-8 (its stat is not a string) is read, not
        /// skipped.
        #[cfg(target_os = "linux")]
        #[test]
        fn a_command_that_is_not_utf8_is_read() {
            use std::os::unix::ffi::OsStrExt;
            let stat = a_child_named(std::ffi::OsStr::from_bytes(b"omb-\xff-probe"));
            // Its stat, read while it ran under that name, is not UTF-8.
            assert!(
                std::str::from_utf8(&stat).is_err(),
                "the stat holds a byte that is not UTF-8"
            );
            assert!(parse_stat(&stat).is_some());
        }

        #[test]
        fn the_stat_is_parsed_as_bytes_after_the_last_parenthesis() {
            let tail = b" S 1 4242 4242 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 987654 1 2";
            let stat = |comm: &[u8]| [b"77 (".as_slice(), comm, b")", tail].concat();
            for comm in [
                b"sleep".as_slice(),
                b"omb-\xff-probe",
                b"a) (b c",
                b") 9 9 9 (",
                b"",
            ] {
                assert_eq!(parse_stat(&stat(comm)), Some((4242, 987654)), "{comm:?}");
            }
            // Malformed: no parentheses, too few fields, a field not a number.
            assert_eq!(parse_stat(b"77 sleep S 1 4242"), None);
            assert_eq!(parse_stat(b"77 (sleep) S 1 4242"), None);
            assert_eq!(
                parse_stat(&stat(b"x").replace_first(b"4242", b"42x2")),
                None
            );
            assert_eq!(parse_stat(b")77 (sleep"), None);
            assert_eq!(parse_stat(b""), None);
        }

        trait ReplaceFirst {
            fn replace_first(&self, a: &[u8], b: &[u8]) -> Vec<u8>;
        }
        impl ReplaceFirst for Vec<u8> {
            fn replace_first(&self, a: &[u8], b: &[u8]) -> Vec<u8> {
                let i = self.windows(a.len()).position(|w| w == a).unwrap();
                [&self[..i], b, &self[i + a.len()..]].concat()
            }
        }

        #[test]
        fn an_entry_is_gone_only_when_the_process_is() {
            let ok = b"1 (x) S 1 7 7 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 55 1 2".to_vec();
            assert_eq!(
                linux_entry(Ok(ok), || true),
                Entry::Known { pgid: 7, start: 55 }
            );
            let nf = || Err(io::Error::from(io::ErrorKind::NotFound));
            assert_eq!(linux_entry(nf(), || false), Entry::Gone);
            let esrch = Err(io::Error::from_raw_os_error(3));
            assert_eq!(linux_entry(esrch, || false), Entry::Gone);
            // Unreadable while the process is there: possibly present.
            let denied = || Err(io::Error::from(io::ErrorKind::PermissionDenied));
            assert_eq!(linux_entry(denied(), || false), Entry::Unreadable);
            assert_eq!(
                linux_entry(Ok(b"1 (x".to_vec()), || false),
                Entry::Unreadable
            );
            // Ended while being read: an empty stat, and /proc no longer has it.
            assert_eq!(linux_entry(Ok(Vec::new()), || true), Entry::Gone);
            assert_eq!(linux_entry(denied(), || true), Entry::Gone);
        }

        #[test]
        fn a_mac_record_that_cannot_be_read_is_never_absent() {
            const EPERM: i32 = 1;
            const ESRCH: i32 = 3;
            assert_eq!(
                mac_entry(Ok((7, 55)), || panic!("not asked")),
                Entry::Known { pgid: 7, start: 55 }
            );
            assert_eq!(mac_entry(Err(ESRCH), || panic!("not asked")), Entry::Gone);
            // Another user's process: its group from the short record.
            assert_eq!(
                mac_entry(Err(EPERM), || Ok(7)),
                Entry::GroupOnly { pgid: 7 }
            );
            assert_eq!(mac_entry(Err(EPERM), || Err(ESRCH)), Entry::Gone);
            // The short record refused too: possibly in any group.
            assert_eq!(mac_entry(Err(EPERM), || Err(EPERM)), Entry::Unreadable);
            assert_eq!(mac_entry(Err(-1), || Err(-1)), Entry::Unreadable);
        }

        #[test]
        fn unknown_identities_never_match_and_block_quiescence() {
            let k = |pid, s| Ident {
                pid,
                start: Start::Known(s),
            };
            let u = |pid| Ident {
                pid,
                start: Start::Unknown,
            };
            let mut g = Group::default();
            g.add(7, 10, Entry::Known { pgid: 7, start: 1 });
            g.add(7, 11, Entry::GroupOnly { pgid: 7 });
            g.add(7, 12, Entry::Known { pgid: 8, start: 1 });
            g.add(7, 13, Entry::Gone);
            g.add(7, 14, Entry::Known { pgid: 7, start: 2 });
            // 10 in the snapshot; 11 unknown in both; 14 a reused PID.
            let snap = [k(10, 1), u(11), k(14, 9)];
            assert_eq!(g.workers(&snap).unwrap(), vec![11, 14]);
            assert!(!g.whole(), "an unknown start is no snapshot");
            assert!(!u(11).same(&u(11)));
            assert!(!k(11, u64::MAX).same(&u(11)));
            // A process whose group could not be read: no answer at all.
            g.add(7, 15, Entry::Unreadable);
            assert!(g.workers(&snap).is_err());
            assert!(!g.whole());
        }
    }
}
