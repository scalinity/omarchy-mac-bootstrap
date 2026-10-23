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
}

impl Viewport {
    pub fn reveal(&mut self) {
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
            *self = Self {
                screen: Some(screen),
                top: initial,
                ..Self::default()
            };
        }
        if !self.manual {
            self.top = initial;
        }
        self.height = height;
        self.total = total;
        self.rows = rows;
        if !self.manual || self.cursor != cursor {
            self.focus = cursor;
            if let Some((line, end)) =
                cursor.and_then(|id| self.rows.iter().find(|r| r.0 == id).map(|r| (r.1, r.2)))
            {
                if line < self.top {
                    self.top = line;
                }
                if end > self.top.saturating_add(height) {
                    self.top = end.saturating_sub(height).min(line);
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
                if row_end > self.top + self.height {
                    self.top = row_end.saturating_sub(self.height).min(line);
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
        if self.focus.is_some() {
            self.cursor = self.focus;
        }
        Some(self.focus)
    }
}
