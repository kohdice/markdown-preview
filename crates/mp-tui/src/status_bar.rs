use std::path::Path;

use ratatui::{
    Frame,
    layout::{Alignment, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::Paragraph,
};

use crate::theme_adapter::RatatuiThemeAdapter;
use mp_core::theme::{MarkdownTheme, SolarizedOsaka, ThemeAdapter};

pub struct StatusBar<T: MarkdownTheme> {
    pub file_path: Option<String>,
    pub message: Option<String>,
    pub error: Option<String>,
    pub mode: StatusMode,
    pub search_query: Option<String>,
    theme: T,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum StatusMode {
    Normal,
    Search,
    Help,
}

impl<T: MarkdownTheme> StatusBar<T> {
    pub fn new(theme: T) -> Self {
        Self {
            file_path: None,
            message: None,
            error: None,
            mode: StatusMode::Normal,
            search_query: None,
            theme,
        }
    }

    pub fn set_file(&mut self, path: &Path) {
        self.file_path = Some(path.display().to_string());
        self.clear_message();
    }

    pub fn set_message(&mut self, msg: impl Into<String>) {
        self.message = Some(msg.into());
        self.error = None;
    }

    pub fn set_error(&mut self, err: impl Into<String>) {
        self.error = Some(err.into());
        self.message = None;
    }

    pub fn clear_message(&mut self) {
        self.message = None;
        self.error = None;
    }

    pub fn set_mode(&mut self, mode: StatusMode) {
        self.mode = mode;
    }

    pub fn set_search_query(&mut self, query: &str) {
        self.search_query = Some(query.to_string());
    }

    pub fn clear_search_query(&mut self) {
        self.search_query = None;
    }

    pub fn render(&self, frame: &mut Frame, area: Rect) {
        let mut spans = Vec::new();

        let mode_span = match self.mode {
            StatusMode::Normal => Span::styled(
                " NORMAL ",
                Style::default()
                    .fg(Color::Black)
                    .bg({
                        let adapter = RatatuiThemeAdapter;
                        adapter.to_color(&self.theme.status_normal_color())
                    })
                    .add_modifier(Modifier::BOLD),
            ),
            StatusMode::Search => Span::styled(
                " SEARCH ",
                Style::default()
                    .fg(Color::Black)
                    .bg({
                        let adapter = RatatuiThemeAdapter;
                        adapter.to_color(&self.theme.status_search_color())
                    })
                    .add_modifier(Modifier::BOLD),
            ),
            StatusMode::Help => Span::styled(
                " HELP ",
                Style::default()
                    .fg(Color::Black)
                    .bg({
                        let adapter = RatatuiThemeAdapter;
                        adapter.to_color(&self.theme.status_help_color())
                    })
                    .add_modifier(Modifier::BOLD),
            ),
        };
        spans.push(mode_span);
        spans.push(Span::raw(" "));

        if let Some(error) = &self.error {
            spans.push(Span::styled(
                error,
                Style::default()
                    .fg({
                        let adapter = RatatuiThemeAdapter;
                        adapter.to_color(&self.theme.status_error_color())
                    })
                    .add_modifier(Modifier::BOLD),
            ));
        } else if let Some(message) = &self.message {
            spans.push(Span::styled(
                message,
                Style::default()
                    .fg({
                        let adapter = RatatuiThemeAdapter;
                        adapter.to_color(&self.theme.status_message_color())
                    })
                    .add_modifier(Modifier::ITALIC),
            ));
        } else if self.mode == StatusMode::Search {
            if let Some(query) = &self.search_query {
                spans.push(Span::styled(
                    query,
                    Style::default()
                        .fg({
                            let adapter = RatatuiThemeAdapter;
                            adapter.to_color(&self.theme.status_message_color())
                        })
                        .add_modifier(Modifier::BOLD),
                ));
            } else {
                spans.push(Span::styled(
                    "",
                    Style::default()
                        .fg({
                            let adapter = RatatuiThemeAdapter;
                            adapter.to_color(&self.theme.status_message_color())
                        })
                        .add_modifier(Modifier::BOLD),
                ));
            }
        } else if let Some(path) = &self.file_path {
            spans.push(Span::styled(
                path,
                Style::default().fg({
                    let adapter = RatatuiThemeAdapter;
                    adapter.to_color(&self.theme.text_style().color)
                }),
            ));
        }

        let line = Line::from(spans);

        let paragraph = Paragraph::new(vec![line])
            .style(Style::default().bg({
                let adapter = RatatuiThemeAdapter;
                adapter.to_color(&self.theme.status_background_color())
            }))
            .alignment(Alignment::Left);

        frame.render_widget(paragraph, area);
    }
}

impl Default for StatusBar<SolarizedOsaka> {
    fn default() -> Self {
        Self::new(SolarizedOsaka)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn test_status_bar_creation() {
        let status = StatusBar::new(SolarizedOsaka);
        assert_eq!(status.mode, StatusMode::Normal);
        assert!(status.file_path.is_none());
        assert!(status.message.is_none());
        assert!(status.error.is_none());
    }

    #[test]
    fn test_status_bar_file_path() {
        let mut status = StatusBar::new(SolarizedOsaka);
        let path = PathBuf::from("/test/file.md");

        status.set_file(&path);
        assert_eq!(status.file_path, Some("/test/file.md".to_string()));
        assert!(status.message.is_none());
        assert!(status.error.is_none());
    }

    #[test]
    fn test_status_bar_messages() {
        let mut status = StatusBar::new(SolarizedOsaka);

        status.set_message("Test message");
        assert_eq!(status.message, Some("Test message".to_string()));
        assert!(status.error.is_none());

        status.set_error("Test error");
        assert!(status.message.is_none());
        assert_eq!(status.error, Some("Test error".to_string()));

        status.clear_message();
        assert!(status.message.is_none());
        assert!(status.error.is_none());
    }

    #[test]
    fn test_status_bar_mode() {
        let mut status = StatusBar::new(SolarizedOsaka);

        assert_eq!(status.mode, StatusMode::Normal);

        status.set_mode(StatusMode::Search);
        assert_eq!(status.mode, StatusMode::Search);

        status.set_mode(StatusMode::Help);
        assert_eq!(status.mode, StatusMode::Help);
    }
}
