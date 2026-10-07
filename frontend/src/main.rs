//! Start and exit: the launcher contract (docs/FRONTEND.md). The launcher
//! starts `omb-tui --session DIR` only after checking this binary's SHA-256
//! against the reviewed lock; it reads the exit status: 0 finished, 10 fall
//! back to text, anything else a failure it reports.

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(omb_tui::run(&args));
}
