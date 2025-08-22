use std::path::Path;

use ratatui::{
    Frame,
    layout::{Alignment, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::Paragraph,
};

pub struct StatusBar {
    pub file_path: Option<String>,
    pub message: Option<String>,
    pub error: Option<String>,
    pub mode: StatusMode,
    pub search_query: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum StatusMode {
    Normal,
    Search,
    Help,
}

impl StatusBar {
    pub fn new() -> Self {
        Self {
            file_path: None,
            message: None,
            error: None,
            mode: StatusMode::Normal,
            search_query: None,
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

        // Mode indicator
        let mode_span = match self.mode {
            StatusMode::Normal => Span::styled(
                " NORMAL ",
                Style::default()
                    .fg(Color::Black)
                    .bg(Color::Rgb(133, 153, 0))
                    .add_modifier(Modifier::BOLD),
            ),
            StatusMode::Search => Span::styled(
                " SEARCH ",
                Style::default()
                    .fg(Color::Black)
                    .bg(Color::Rgb(181, 137, 0))
                    .add_modifier(Modifier::BOLD),
            ),
            StatusMode::Help => Span::styled(
                " HELP ",
                Style::default()
                    .fg(Color::Black)
                    .bg(Color::Rgb(38, 139, 210))
                    .add_modifier(Modifier::BOLD),
            ),
        };
        spans.push(mode_span);
        spans.push(Span::raw(" "));

        // File path or message or search query
        if let Some(error) = &self.error {
            spans.push(Span::styled(
                error,
                Style::default()
                    .fg(Color::Rgb(220, 50, 47))
                    .add_modifier(Modifier::BOLD),
            ));
        } else if let Some(message) = &self.message {
            spans.push(Span::styled(
                message,
                Style::default()
                    .fg(Color::Rgb(181, 137, 0))
                    .add_modifier(Modifier::ITALIC),
            ));
        } else if self.mode == StatusMode::Search {
            if let Some(query) = &self.search_query {
                spans.push(Span::styled(
                    query,
                    Style::default()
                        .fg(Color::Rgb(181, 137, 0))
                        .add_modifier(Modifier::BOLD),
                ));
            } else {
                spans.push(Span::styled(
                    "",
                    Style::default()
                        .fg(Color::Rgb(181, 137, 0))
                        .add_modifier(Modifier::BOLD),
                ));
            }
        } else if let Some(path) = &self.file_path {
            spans.push(Span::styled(
                path,
                Style::default().fg(Color::Rgb(131, 148, 150)),
            ));
        }

        // Help text on the right
        let help_text = match self.mode {
            StatusMode::Normal => "Tab: Switch | q: Quit | /: Search | ?: Help",
            StatusMode::Search => "Enter: Confirm | Esc: Cancel | Type to search",
            StatusMode::Help => "Press any key to exit help",
        };

        let line = Line::from(spans);
        let _help_line = Line::from(vec![
            Span::raw(" ".repeat(area.width.saturating_sub(help_text.len() as u16) as usize)),
            Span::styled(
                help_text,
                Style::default()
                    .fg(Color::Rgb(88, 110, 117))
                    .add_modifier(Modifier::ITALIC),
            ),
        ]);

        let paragraph = Paragraph::new(vec![line])
            .style(Style::default().bg(Color::Rgb(7, 54, 66)))
            .alignment(Alignment::Left);

        frame.render_widget(paragraph, area);
    }
}

impl Default for StatusBar {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn test_status_bar_creation() {
        let status = StatusBar::new();
        assert_eq!(status.mode, StatusMode::Normal);
        assert!(status.file_path.is_none());
        assert!(status.message.is_none());
        assert!(status.error.is_none());
    }

    #[test]
    fn test_status_bar_file_path() {
        let mut status = StatusBar::new();
        let path = PathBuf::from("/test/file.md");

        status.set_file(&path);
        assert_eq!(status.file_path, Some("/test/file.md".to_string()));
        assert!(status.message.is_none());
        assert!(status.error.is_none());
    }

    #[test]
    fn test_status_bar_messages() {
        let mut status = StatusBar::new();

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
        let mut status = StatusBar::new();

        assert_eq!(status.mode, StatusMode::Normal);

        status.set_mode(StatusMode::Search);
        assert_eq!(status.mode, StatusMode::Search);

        status.set_mode(StatusMode::Help);
        assert_eq!(status.mode, StatusMode::Help);
    }
}
