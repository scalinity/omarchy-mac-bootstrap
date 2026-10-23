//! Tokens, capability detection and glyph sets (docs/UX.md → *Tokens*,
//! *Glyphs*).
//!
//! The frontend styles by meaning, never by literal colour. Each token maps
//! to its 256-colour value, to one of the sixteen named colours, and to plain
//! attributes (docs/UX.md → *Tokens*). Emphasis is reverse or underline,
//! never bold with a colour (the Linux console cancels bold when a
//! normal-intensity colour follows it). `NO_COLOR` is handled here: colours
//! are dropped and attributes kept, so the focus highlight survives. The
//! sapphire backdrop is painted at full colour depth, and no state depends on it.

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
    pub truecolor: bool,
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
    let truecolor =
        stdout_tty && !console && matches!(get("COLORTERM").as_str(), "truecolor" | "24bit");
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
    if color == "always" {
        depth = Depth::Full;
    }
    if console && depth != Depth::None {
        depth = Depth::Sixteen;
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
        truecolor,
    }
}

/// Display protocol system names as product names, retaining record bytes.
/// Paths, commands and embedded identifiers stay intact.
pub fn human_text(s: &str) -> String {
    s.split_inclusive(|c: char| !c.is_ascii_alphanumeric() && !"_/.-".contains(c))
        .map(|part| {
            let end = part
                .trim_end_matches(|c: char| !c.is_ascii_alphanumeric() && !"_/-".contains(c))
                .len();
            let (word, tail) = part.split_at(end);
            let word = match word {
                "macos" => "macOS",
                "linux" => "Linux",
                "not-started" => "not started",
                "not-checked" => "not checked",
                "waiting-for-linux" => "waiting for Linux",
                "waiting-for-macos" => "waiting for macOS",
                "awaiting-linux-activation" => "ready to activate on Linux",
                "awaiting-macos-creation" => "ready to create on macOS",
                "awaiting-linux-completion" => "waiting for Linux to finish",
                _ => word,
            };
            if word.len() >= 12
                && word.bytes().all(|b| b.is_ascii_hexdigit())
                && word.bytes().any(|b| b.is_ascii_alphabetic())
            {
                format!("checksum recorded{tail}")
            } else {
                format!("{word}{tail}")
            }
        })
        .collect()
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
    /// Panel outlines and the title rule.
    Frame,
    /// Panel titles and section headings.
    Heading,
    /// The sapphire page at full colour depth; terminal background otherwise.
    Backdrop,
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
                    Muted | Pending => c(249),
                    Rule | Free => c(244),
                    Accent => c(78),
                    Linux => c(209),
                    Focus => c(78).add_modifier(Modifier::REVERSED),
                    Selected | Ok => c(115),
                    Info | Macos => c(110),
                    Warn => c(222),
                    Danger => c(210),
                    Blocked => c(210).add_modifier(Modifier::REVERSED),
                    Gate => c(253).add_modifier(Modifier::UNDERLINED),
                    Boot => c(147),
                    Shared => c(114),
                    Frame => c(44),
                    Heading => c(75),
                    Backdrop => s.bg(if self.caps.truecolor {
                        Color::Rgb(13, 59, 132)
                    } else {
                        Color::Indexed(18)
                    }),
                }
            }
            Depth::Sixteen => {
                let c = |col: Color| s.fg(col);
                match t {
                    Text | Backdrop => s,
                    Muted | Rule | Pending | Free => c(Color::DarkGray),
                    Accent | Selected | Ok | Shared => c(Color::Green),
                    Linux => c(Color::LightRed),
                    Focus => s.add_modifier(Modifier::REVERSED),
                    Info | Frame => c(Color::Cyan),
                    Warn => c(Color::Yellow),
                    Danger => c(Color::Red),
                    Blocked => c(Color::Red).add_modifier(Modifier::REVERSED),
                    Gate => s.add_modifier(Modifier::UNDERLINED),
                    Macos | Heading => c(Color::Blue),
                    Boot => c(Color::Magenta),
                }
            }
            // No colour: meaning is kept by the word, the glyph and these
            // attributes (docs/UX.md: accent underline, focus reverse,
            // blocked reversed, gate underline).
            Depth::None => match t {
                Accent | Gate | Heading => s.add_modifier(Modifier::UNDERLINED),
                Focus | Blocked => s.add_modifier(Modifier::REVERSED),
                _ => s,
            },
        }
    }

    /// Text for the screen: as it is in Unicode; in ASCII, with the
    /// punctuation the baseline's `_p` rewrites for the Linux console
    /// (`lib/ui.sh`) rewritten the same way. Presentation only: the model
    /// keeps the core's bytes.
    pub fn say(&self, s: &str) -> String {
        let s = human_text(s);
        if self.caps.unicode {
            return s;
        }
        s.replace(['—', '–'], "-")
            .replace('→', "->")
            .replace('≥', ">=")
            .replace('≈', "~")
            .replace('…', "...")
            .replace('·', "-")
            .replace('⏎', ">")
            .replace("↑↓", "up/down")
    }

    /// The wordmark's Ith letter: a green-to-cyan gradient at 256 colours,
    /// the accent otherwise (docs/UX.md → *Degraded and accessible*).
    pub fn wordmark(&self, i: usize) -> Style {
        const RAMP: [u8; 7] = [78, 78, 79, 79, 80, 44, 45];
        match self.caps.depth {
            Depth::Full => Style::new().fg(Color::Indexed(RAMP[i % RAMP.len()])),
            _ => self.style(Token::Accent),
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
    /// A station the core has not derived.
    pub later: &'static str,
    pub rule: &'static str,
    pub pointer: &'static str,
    pub ok: &'static str,
    pub warn: &'static str,
    pub fail: &'static str,
    pub info: &'static str,
    pub arrow: &'static str,
    pub bar: &'static str,
    /// The current screen in the navigation.
    pub here: &'static str,
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
    later: "·",
    rule: "─",
    pointer: "❯",
    ok: "✓",
    warn: "!",
    fail: "✗",
    info: "·",
    arrow: "→",
    bar: "▍",
    here: "▍",
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
    later: "_",
    rule: "-",
    pointer: ">",
    ok: "+",
    warn: "!",
    fail: "x",
    info: "-",
    arrow: "->",
    bar: "|",
    here: "*",
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
    fn display_names_preserve_paths_and_commands() {
        assert_eq!(
            human_text("macos, linux. macos.omb linux.omb ./omarchy-bootstrap /home/linux/bin"),
            "macOS, Linux. macos.omb linux.omb ./omarchy-bootstrap /home/linux/bin"
        );
    }

    #[test]
    fn detection_follows_the_baseline() {
        let c = caps(&[("TERM", "xterm-256color"), ("LANG", "en_US.UTF-8")], true);
        assert_eq!(
            c,
            Caps {
                depth: Depth::Full,
                unicode: true,
                console: false,
                truecolor: false
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
                console: true,
                truecolor: false
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
            truecolor: false,
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
                truecolor: false,
            });
            use Token::*;
            for tok in [
                Text, Muted, Rule, Accent, Focus, Selected, Ok, Info, Warn, Danger, Blocked,
                Pending, Gate, Macos, Linux, Boot, Shared, Free, Frame, Heading, Backdrop,
            ] {
                assert!(
                    !t.style(tok).add_modifier.contains(Modifier::BOLD),
                    "{tok:?} at {depth:?}"
                );
            }
            for i in 0..7 {
                assert!(!t.wordmark(i).add_modifier.contains(Modifier::BOLD));
            }
        }
    }

    #[test]
    fn ascii_text_follows_the_baseline() {
        let ascii = Theme::new(Caps {
            depth: Depth::Sixteen,
            unicode: false,
            console: true,
            truecolor: false,
        });
        assert_eq!(
            ascii.say("on — the installer asks · 1 → 2 … ⏎ ↑↓ ≥ ≈ –"),
            "on - the installer asks - 1 -> 2 ... > up/down >= ~ -"
        );
        let uni = Theme::new(Caps {
            depth: Depth::Full,
            unicode: true,
            console: false,
            truecolor: false,
        });
        assert_eq!(uni.say("on — it"), "on — it");
    }

    #[test]
    fn every_glyph_is_one_cell() {
        for g in [&UNICODE, &ASCII] {
            for s in [
                g.done, g.current, g.todo, g.skipped, g.blocked, g.later, g.rule, g.pointer, g.ok,
                g.warn, g.fail, g.info, g.bar, g.here, g.dot,
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

#[cfg(test)]
mod sapphire_tests {
    use super::*;

    #[test]
    fn truecolor_is_a_separate_capability() {
        for value in ["truecolor", "24bit"] {
            let env = |k: &str| match k {
                "TERM" => Some("xterm".into()),
                "COLORTERM" => Some(value.into()),
                _ => None,
            };
            assert!(detect(&env, true).truecolor);
            assert!(!detect(&env, false).truecolor);
        }
        let env = |k: &str| (k == "TERM").then(|| "xterm-256color".into());
        assert_eq!(detect(&env, true).depth, Depth::Full);
        assert!(!detect(&env, true).truecolor);
    }

    #[test]
    fn backdrop_and_editing_styles_follow_capabilities() {
        for (depth, truecolor, bg) in [
            (Depth::Full, true, Some(Color::Rgb(13, 59, 132))),
            (Depth::Full, false, Some(Color::Indexed(18))),
            (Depth::Sixteen, false, None),
            (Depth::None, false, None),
        ] {
            let t = Theme::new(Caps {
                depth,
                truecolor,
                unicode: true,
                console: false,
            });
            assert_eq!(t.style(Token::Backdrop).bg, bg);
            assert_eq!(t.style(Token::Gate).fg, t.style(Token::Text).fg);
            for token in [Token::Text, Token::Muted, Token::Gate, Token::Frame] {
                assert!(t.style(token).bg.is_none());
            }
        }
        let t = Theme::new(detect(
            &|k| match k {
                "TERM" => Some("linux".into()),
                "COLORTERM" => Some("truecolor".into()),
                _ => None,
            },
            true,
        ));
        assert!(!t.caps.truecolor);
        assert!(t.style(Token::Backdrop).bg.is_none());
    }

    fn rgb(c: Color) -> [f64; 3] {
        match c {
            Color::Rgb(r, g, b) => [r as f64, g as f64, b as f64],
            Color::Indexed(i) if i >= 232 => [8.0 + 10.0 * (i - 232) as f64; 3],
            Color::Indexed(i) if i >= 16 => {
                let i = i - 16;
                let level = |n: u8| if n == 0 { 0.0 } else { 55.0 + 40.0 * n as f64 };
                [level(i / 36), level(i / 6 % 6), level(i % 6)]
            }
            _ => panic!("unexpected full-depth colour {c:?}"),
        }
    }
    fn luminance(c: Color) -> f64 {
        let [r, g, b] = rgb(c).map(|v| {
            let v = v / 255.0;
            if v <= 0.04045 {
                v / 12.92
            } else {
                ((v + 0.055) / 1.055).powf(2.4)
            }
        });
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    #[test]
    fn every_full_depth_token_has_contrast_on_both_backdrops() {
        use Token::*;
        let t = Theme::new(Caps {
            depth: Depth::Full,
            truecolor: true,
            unicode: true,
            console: false,
        });
        for bg in [Color::Rgb(13, 59, 132), Color::Indexed(18)] {
            for token in [
                Text, Muted, Pending, Heading, Accent, Focus, Selected, Ok, Info, Warn, Danger,
                Blocked, Gate, Macos, Linux, Boot, Shared, Frame, Rule, Free,
            ] {
                let a = luminance(t.style(token).fg.unwrap());
                let b = luminance(bg);
                let ratio = (a.max(b) + 0.05) / (a.min(b) + 0.05);
                // Rule, free space and Linux are disk graphics; their legends use Text.
                let min = if matches!(token, Rule | Free | Linux) {
                    2.5
                } else {
                    4.5
                };
                assert!(ratio >= min, "{token:?} on {bg:?}: {ratio:.3} < {min}");
            }
        }
    }
}
