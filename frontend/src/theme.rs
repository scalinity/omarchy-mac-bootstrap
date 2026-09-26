//! Tokens, capability detection and glyph sets (docs/UX.md → *Tokens*,
//! *Glyphs*).
//!
//! The frontend styles by meaning, never by literal colour. Each token maps
//! to the baseline's palette (`lib/ui.sh`) in 256 colours, to the sixteen
//! named colours, and to plain attributes. Emphasis is reverse or underline,
//! never bold with a colour (the Linux console cancels bold when a
//! normal-intensity colour follows it). `NO_COLOR` is handled here: colours
//! are dropped and attributes kept, so the focus highlight survives.

use ratatui::style::{Color, Modifier, Style};

/// How many colours to use: the baseline's `UI_DEPTH` (256, 16 or none).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Depth {
    Full,
    Sixteen,
    None,
}

/// What the terminal gets: colour depth and whether Unicode glyphs are safe.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Caps {
    pub depth: Depth,
    pub unicode: bool,
    /// The Linux virtual console (`TERM=linux`): ASCII, sixteen colours, and
    /// the screen cleared on exit (older kernels have no alternate screen).
    pub console: bool,
}

/// The same decision `ui_init` makes in `lib/ui.sh`, from the environment.
/// The frontend runs nothing but the core, so where the baseline asks `tput
/// colors`, the frontend reads `TERM` and `COLORTERM`.
pub fn detect(env: &dyn Fn(&str) -> Option<String>, stdout_tty: bool) -> Caps {
    let get = |k: &str| env(k).unwrap_or_default();
    let term = get("TERM");
    let console = term == "linux";
    let color = get("OMB_COLOR");
    let mut depth = if !get("NO_COLOR").is_empty()
        || color == "never"
        || !stdout_tty
        || term.is_empty()
        || term == "dumb"
    {
        Depth::None
    } else if matches!(get("COLORTERM").as_str(), "truecolor" | "24bit")
        || term.contains("256color")
    {
        Depth::Full
    } else {
        Depth::Sixteen
    };
    if console && depth != Depth::None {
        depth = Depth::Sixteen;
    }
    if color == "always" {
        depth = Depth::Full;
    }
    let locale = env("LC_ALL")
        .filter(|v| !v.is_empty())
        .or_else(|| env("LC_CTYPE").filter(|v| !v.is_empty()))
        .or_else(|| env("LANG"))
        .unwrap_or_default();
    let mut unicode = ["UTF-8", "utf-8", "UTF8", "utf8"]
        .iter()
        .any(|u| locale.contains(u));
    if console || get("OMB_ASCII") == "1" {
        unicode = false;
    }
    Caps {
        depth,
        unicode,
        console,
    }
}

/// The meanings the interface styles by.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Token {
    Text,
    Muted,
    Rule,
    Accent,
    Focus,
    Selected,
    Ok,
    Info,
    Warn,
    Danger,
    Blocked,
    Pending,
    Gate,
    Macos,
    Linux,
    Boot,
    Shared,
    Free,
}

/// A theme: the capabilities and the glyph set that follows from them.
#[derive(Clone, Copy, Debug)]
pub struct Theme {
    pub caps: Caps,
    pub g: &'static Glyphs,
}

impl Theme {
    pub fn new(caps: Caps) -> Theme {
        Theme {
            caps,
            g: if caps.unicode { &UNICODE } else { &ASCII },
        }
    }

    /// The style for a token at this theme's depth.
    pub fn style(&self, t: Token) -> Style {
        use Token::*;
        let s = Style::new();
        match self.caps.depth {
            Depth::Full => {
                let c = |n: u8| s.fg(Color::Indexed(n));
                match t {
                    Text => c(253),
                    Muted | Pending => c(245),
                    Rule | Free => c(239),
                    Accent | Linux => c(209),
                    Focus => s.fg(Color::Indexed(209)).add_modifier(Modifier::REVERSED),
                    Selected | Ok => c(115),
                    Info | Macos => c(110),
                    Warn => c(222),
                    Danger => c(204),
                    Blocked => c(204).add_modifier(Modifier::REVERSED),
                    Gate => c(209).add_modifier(Modifier::UNDERLINED),
                    Boot => c(141),
                    Shared => c(114),
                }
            }
            Depth::Sixteen => {
                let c = |col: Color| s.fg(col);
                match t {
                    Text => s,
                    Muted | Rule | Pending | Free => c(Color::DarkGray),
                    Accent | Linux => c(Color::LightRed),
                    Focus => s.add_modifier(Modifier::REVERSED),
                    Selected | Ok | Shared => c(Color::Green),
                    Info => c(Color::Cyan),
                    Warn => c(Color::Yellow),
                    Danger => c(Color::Red),
                    Blocked => c(Color::Red).add_modifier(Modifier::REVERSED),
                    Gate => s.add_modifier(Modifier::UNDERLINED),
                    Macos => c(Color::Blue),
                    Boot => c(Color::Magenta),
                }
            }
            // No colour: meaning is kept by the word, the glyph and these
            // attributes (docs/UX.md: accent underline, focus reverse,
            // blocked reversed, gate underline).
            Depth::None => match t {
                Accent | Gate => s.add_modifier(Modifier::UNDERLINED),
                Focus | Blocked => s.add_modifier(Modifier::REVERSED),
                _ => s,
            },
        }
    }
}

/// One glyph set; every glyph is one cell wide.
#[derive(Debug)]
pub struct Glyphs {
    pub mark: &'static str,
    pub done: &'static str,
    pub current: &'static str,
    pub todo: &'static str,
    pub skipped: &'static str,
    pub blocked: &'static str,
    pub rule: &'static str,
    pub pointer: &'static str,
    pub ok: &'static str,
    pub warn: &'static str,
    pub fail: &'static str,
    pub info: &'static str,
    pub arrow: &'static str,
    pub bar: &'static str,
    pub dot: &'static str,
    pub spin: &'static [&'static str],
}

pub static UNICODE: Glyphs = Glyphs {
    mark: "◒",
    done: "●",
    current: "◆",
    todo: "○",
    skipped: "◌",
    blocked: "✗",
    rule: "─",
    pointer: "❯",
    ok: "✓",
    warn: "!",
    fail: "✗",
    info: "·",
    arrow: "→",
    bar: "▍",
    dot: "·",
    spin: &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"],
};

pub static ASCII: Glyphs = Glyphs {
    mark: "(o)",
    done: "*",
    current: ">",
    todo: ".",
    skipped: "~",
    blocked: "x",
    rule: "-",
    pointer: ">",
    ok: "+",
    warn: "!",
    fail: "x",
    info: "-",
    arrow: "->",
    bar: "|",
    dot: "-",
    spin: &["|", "/", "-", "\\"],
};

#[cfg(test)]
mod tests {
    use super::*;

    fn caps(pairs: &[(&str, &str)], tty: bool) -> Caps {
        let env = |k: &str| {
            pairs
                .iter()
                .find(|(n, _)| *n == k)
                .map(|(_, v)| v.to_string())
        };
        detect(&env, tty)
    }

    #[test]
    fn detection_follows_the_baseline() {
        let c = caps(&[("TERM", "xterm-256color"), ("LANG", "en_US.UTF-8")], true);
        assert_eq!(
            c,
            Caps {
                depth: Depth::Full,
                unicode: true,
                console: false
            }
        );
        assert_eq!(
            caps(&[("TERM", "xterm"), ("LANG", "C")], true).depth,
            Depth::Sixteen
        );
        assert!(!caps(&[("TERM", "xterm"), ("LANG", "C")], true).unicode);
        // The Linux console: ASCII and sixteen colours, whatever the locale.
        let c = caps(
            &[
                ("TERM", "linux"),
                ("LANG", "en_US.UTF-8"),
                ("COLORTERM", "truecolor"),
            ],
            true,
        );
        assert_eq!(
            c,
            Caps {
                depth: Depth::Sixteen,
                unicode: false,
                console: true
            }
        );
        assert_eq!(
            caps(&[("TERM", "xterm-256color"), ("NO_COLOR", "1")], true).depth,
            Depth::None
        );
        assert_eq!(
            caps(&[("TERM", "xterm-256color"), ("OMB_COLOR", "never")], true).depth,
            Depth::None
        );
        assert_eq!(caps(&[("TERM", "dumb")], true).depth, Depth::None);
        assert_eq!(
            caps(&[("TERM", "xterm-256color")], false).depth,
            Depth::None
        );
        assert!(
            !caps(
                &[
                    ("TERM", "xterm"),
                    ("LANG", "en_US.UTF-8"),
                    ("OMB_ASCII", "1")
                ],
                true
            )
            .unicode
        );
        assert_eq!(
            caps(&[("TERM", "dumb"), ("OMB_COLOR", "always")], true).depth,
            Depth::Full
        );
    }

    #[test]
    fn no_colour_keeps_emphasis() {
        let t = Theme::new(Caps {
            depth: Depth::None,
            unicode: false,
            console: false,
        });
        let focus = t.style(Token::Focus);
        assert_eq!(focus.fg, None);
        assert!(focus.add_modifier.contains(Modifier::REVERSED));
        assert!(
            t.style(Token::Gate)
                .add_modifier
                .contains(Modifier::UNDERLINED)
        );
        assert_eq!(t.style(Token::Danger), Style::new());
    }

    #[test]
    fn never_bold_with_a_colour() {
        for depth in [Depth::Full, Depth::Sixteen, Depth::None] {
            let t = Theme::new(Caps {
                depth,
                unicode: true,
                console: false,
            });
            use Token::*;
            for tok in [
                Text, Muted, Rule, Accent, Focus, Selected, Ok, Info, Warn, Danger, Blocked,
                Pending, Gate, Macos, Linux, Boot, Shared, Free,
            ] {
                assert!(
                    !t.style(tok).add_modifier.contains(Modifier::BOLD),
                    "{tok:?} at {depth:?}"
                );
            }
        }
    }

    #[test]
    fn every_glyph_is_one_cell() {
        for g in [&UNICODE, &ASCII] {
            for s in [
                g.done, g.current, g.todo, g.skipped, g.blocked, g.rule, g.pointer, g.ok, g.warn,
                g.fail, g.info, g.bar, g.dot,
            ] {
                assert_eq!(s.chars().count(), 1, "{s}");
            }
            for s in g.spin {
                assert_eq!(s.chars().count(), 1, "{s}");
            }
        }
        for s in [ASCII.mark, ASCII.arrow, UNICODE.mark, UNICODE.arrow] {
            assert!(s.is_ascii() || s.chars().count() == 1, "{s}");
        }
    }
}
