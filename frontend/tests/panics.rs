//! The panic hook's gate (docs/FRONTEND.md → *The terminal*): only a panic on
//! the thread that owns the terminal runs the restoring chain; another
//! thread's panic is kept for the owner. In a test binary of its own, because
//! a panic hook is the whole process's.

use std::sync::atomic::{AtomicUsize, Ordering};

static RAN: AtomicUsize = AtomicUsize::new(0);

#[test]
fn only_the_owners_panic_runs_the_restoring_chain() {
    // The chain as `terminal::start` leaves it: here, one that counts.
    std::panic::set_hook(Box::new(|_| {
        RAN.fetch_add(1, Ordering::SeqCst);
    }));
    omb_tui::terminal::own_panics(std::thread::current().id());

    let worker = std::thread::spawn(|| panic!("the spool reader dies")).join();
    assert!(worker.is_err());
    assert_eq!(
        RAN.load(Ordering::SeqCst),
        0,
        "a worker's panic never runs the restoring chain"
    );
    let kept = omb_tui::terminal::worker_panic().expect("the worker's panic is kept");
    assert!(kept.contains("the spool reader dies"), "{kept}");

    let owner = std::panic::catch_unwind(|| panic!("the main thread dies"));
    assert!(owner.is_err());
    assert_eq!(
        RAN.load(Ordering::SeqCst),
        1,
        "the owner's panic runs it, restoring the terminal"
    );
    // The first worker panic is the one kept.
    let _ = std::thread::spawn(|| panic!("a second one")).join();
    assert!(
        omb_tui::terminal::worker_panic()
            .unwrap()
            .contains("the spool reader dies")
    );
    assert_eq!(RAN.load(Ordering::SeqCst), 1);
}
