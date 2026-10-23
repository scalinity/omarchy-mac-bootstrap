//! The rendered panel's line window. Key movement uses the same bounds as
//! drawing, including wrapped prose and fields taller than one line.
use crate::app::Screen;
use ratatui::crossterm::event::KeyCode;

#[derive(Clone, Debug, Default)]
pub struct Viewport {
    pub screen: Option<Screen>,
    pub top: usize,
    pub height: usize,
    pub total: usize,
    /// Focusable row IDs and their first rendered lines.
    pub rows: Vec<(usize, usize, usize)>,
    pub focus: Option<usize>,
    cursor: Option<usize>,
    manual: bool,
    /// A page opens at its top with its first row selected, and the window
    /// follows that row only once a key has moved it or acted on it.
    engaged: bool,
    /// The next layout opens engaged: the page under a help, gate, brief or
    /// form comes back as it was left, and a key can act before a first layout.
    resume: bool,
}

impl Viewport {
    /// The window of a page returned to: the next layout follows its focus.
    pub fn resuming() -> Self {
        Self {
            resume: true,
            ..Self::default()
        }
    }

    fn open(&mut self, screen: Screen) {
        let engaged = self.resume;
        *self = Self {
            screen: Some(screen),
            engaged,
            ..Self::default()
        };
    }

    /// A key acted on the page: the window follows its focus from here on.
    /// Before the page has been laid out, its first layout opens engaged.
    pub fn engage(&mut self) {
        if self.screen.is_some() {
            self.engaged = true;
        } else {
            self.resume = true;
        }
    }

    /// As `engage`, and the window leaves any scrolling the person did.
    pub fn reveal(&mut self) {
        self.engage();
        self.manual = false;
    }
    pub fn layout(
        &mut self,
        screen: Screen,
        height: usize,
        total: usize,
        rows: Vec<(usize, usize, usize)>,
        cursor: Option<usize>,
        initial: usize,
    ) -> usize {
        if self.screen != Some(screen) {
            self.open(screen);
        }
        if self.engaged && !self.manual {
            self.top = initial;
        }
        self.height = height;
        self.total = total;
        self.rows = rows;
        if !self.manual || self.cursor != cursor {
            self.focus = cursor;
            if self.engaged
                && let Some((line, end)) =
                    cursor.and_then(|id| self.rows.iter().find(|r| r.0 == id).map(|r| (r.1, r.2)))
            {
                if line < self.top {
                    self.top = line;
                }
                if end.saturating_sub(line) <= height && end > self.top.saturating_add(height) {
                    self.top = end.saturating_sub(height);
                } else if line >= self.top.saturating_add(height) {
                    self.top = line.saturating_add(1).saturating_sub(height);
                }
            }
        }
        self.cursor = cursor;
        self.top = self.top.min(total.saturating_sub(height));
        self.top
    }

    /// Some means a navigation key was consumed; its optional row is the
    /// focus now visible. Scrolling past all rows leaves the prose focused.
    pub fn key(&mut self, code: KeyCode) -> Option<Option<usize>> {
        let down = matches!(code, KeyCode::Down | KeyCode::Char('j'));
        let up = matches!(code, KeyCode::Up | KeyCode::Char('k'));
        let end = self.total.saturating_sub(self.height);
        if down || up {
            let line = self
                .focus
                .and_then(|id| self.rows.iter().find(|r| r.0 == id).map(|r| r.1));
            let next = if down {
                self.rows
                    .iter()
                    .find(|r| line.map_or(r.1 >= self.top, |l| r.1 > l))
            } else {
                self.rows
                    .iter()
                    .rev()
                    .find(|r| line.map_or(r.1 < self.top + self.height, |l| r.1 < l))
            }
            .copied();
            if let Some((id, line, row_end)) = next {
                self.focus = Some(id);
                self.top = self.top.min(line);
                if row_end.saturating_sub(line) <= self.height && row_end > self.top + self.height {
                    self.top = row_end.saturating_sub(self.height);
                } else if line >= self.top + self.height {
                    self.top = line.saturating_add(1).saturating_sub(self.height);
                }
            } else {
                self.top = if down {
                    self.top.saturating_add(1).min(end)
                } else {
                    self.top.saturating_sub(1)
                };
                if line.is_some_and(|l| l < self.top || l >= self.top + self.height) {
                    self.focus = None;
                }
            }
        } else {
            self.top = match code {
                KeyCode::PageDown => self
                    .top
                    .saturating_add(self.height.saturating_sub(1).max(1))
                    .min(end),
                KeyCode::PageUp => self
                    .top
                    .saturating_sub(self.height.saturating_sub(1).max(1)),
                KeyCode::Home | KeyCode::Char('g') => 0,
                KeyCode::End | KeyCode::Char('G') => end,
                _ => return None,
            };
            let visible =
                |r: &&(usize, usize, usize)| r.1 >= self.top && r.1 < self.top + self.height;
            self.focus = if matches!(code, KeyCode::PageDown | KeyCode::End | KeyCode::Char('G')) {
                self.rows.iter().rev().find(visible).map(|r| r.0)
            } else {
                self.rows.iter().find(visible).map(|r| r.0)
            };
        }
        self.manual = true;
        self.engaged = true;
        if self.focus.is_some() {
            self.cursor = self.focus;
        }
        Some(self.focus)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A page of 100 lines in a window of 10; two rows far below the top.
    fn page(v: &mut Viewport, cursor: Option<usize>, initial: usize) -> usize {
        v.layout(
            Screen::Dashboard,
            10,
            100,
            vec![(0, 80, 82), (1, 90, 92)],
            cursor,
            initial,
        )
    }

    #[test]
    fn a_page_opens_at_zero_until_a_key_moves_or_acts_on_its_focus() {
        let mut v = Viewport::default();
        for _ in 0..2 {
            assert_eq!(page(&mut v, Some(0), 70), 0);
            assert_eq!(v.focus, Some(0));
        }
        v.engage(); // Enter on the selected row.
        assert_eq!(page(&mut v, Some(0), 0), 72);
        v.key(KeyCode::Home);
        assert_eq!(page(&mut v, Some(0), 0), 0);
        v.key(KeyCode::Down);
        assert_eq!(page(&mut v, Some(0), 0), 72);
    }

    #[test]
    fn moving_the_focus_brings_it_into_the_window() {
        let mut v = Viewport::default();
        assert_eq!(page(&mut v, Some(0), 0), 0);
        v.key(KeyCode::Down);
        assert_eq!(page(&mut v, Some(1), 0), 82);
    }

    #[test]
    fn a_page_returned_to_follows_its_focus_at_once() {
        let mut v = Viewport::resuming();
        assert_eq!(page(&mut v, Some(1), 0), 82);
        assert_eq!(v.focus, Some(1));
    }
}
