//! omb-tui: the omarchy-mac-bootstrap frontend (docs/FRONTEND.md).
//!
//! Presentation and input only. The Bash core reads the machine, decides what
//! is legal and runs everything; this crate draws what the core says, collects
//! choices and typed words, and hands the terminal to a child when the core
//! declares a handoff.

pub mod record;
