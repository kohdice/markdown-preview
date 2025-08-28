use std::sync::Arc;

use ratatui::{
    Frame,
    layout::Rect,
    style::{Color, Style},
    widgets::{Block, Borders, Paragraph, Wrap},
};

use mp_core::theme::{DefaultTheme, MarkdownTheme, ThemeAdapter};

use crate::renderer::{MarkdownWidget, MarkdownWidgetState};
use crate::theme_adapter::RatatuiThemeAdapter;

pub struct PreviewWidget {
    pub content: Arc<String>,
    pub scroll_offset: u16,
    pub markdown_widget: Option<MarkdownWidget>,
    pub markdown_state: MarkdownWidgetState,
    theme: DefaultTheme,
}

impl Default for PreviewWidget {
    fn default() -> Self {
        Self {
            content: Arc::new(String::new()),
            scroll_offset: 0,
            markdown_widget: None,
            markdown_state: MarkdownWidgetState::default(),
            theme: DefaultTheme,
        }
    }
}

impl PreviewWidget {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set_content(&mut self, content: Arc<String>) {
        self.content = Arc::clone(&content);
        self.markdown_widget = Some(MarkdownWidget::new(Arc::clone(&content)));
        self.scroll_offset = 0;
        self.markdown_state.scroll_offset = 0;
    }

    pub fn scroll_up(&mut self, lines: u16) {
        self.scroll_offset = self.scroll_offset.saturating_sub(lines);
        self.markdown_state.scroll_offset = self.scroll_offset;
    }

    pub fn scroll_down(&mut self, lines: u16) {
        self.scroll_offset = self.scroll_offset.saturating_add(lines);
        self.markdown_state.scroll_offset = self.scroll_offset;
    }

    pub fn scroll_to_top(&mut self) {
        self.scroll_offset = 0;
        self.markdown_state.scroll_offset = 0;
    }

    pub fn scroll_to_bottom(&mut self) {
        if let Some(widget) = &self.markdown_widget {
            let line_count = widget.line_count();
            self.scroll_offset = line_count.saturating_sub(1) as u16;
        } else {
            self.scroll_offset = u16::MAX;
        }
        self.markdown_state.scroll_offset = self.scroll_offset;
    }

    pub fn page_up(&mut self) {
        self.scroll_up(10);
    }

    pub fn page_down(&mut self) {
        self.scroll_down(10);
    }

    pub fn render(&mut self, frame: &mut Frame, area: Rect, is_focused: bool) {
        let border_style = if is_focused {
            let focus_color = self.theme.focus_border_style().color;
            let adapter = RatatuiThemeAdapter;
            Style::default().fg(adapter.to_color(&focus_color))
        } else {
            let delimiter_color = self.theme.delimiter_style().color;
            let adapter = RatatuiThemeAdapter;
            Style::default().fg(adapter.to_color(&delimiter_color))
        };

        if let Some(widget) = &self.markdown_widget {
            let block = Block::default()
                .borders(Borders::ALL)
                .title("Preview")
                .border_style(border_style);

            let inner_area = block.inner(area);
            frame.render_widget(block, area);
            frame.render_stateful_widget(widget, inner_area, &mut self.markdown_state);
        } else {
            let paragraph = Paragraph::new(self.content.as_str())
                .block(
                    Block::default()
                        .borders(Borders::ALL)
                        .title("Preview")
                        .border_style(border_style),
                )
                .style(Style::default().fg(Color::Rgb(131, 148, 150)))
                .wrap(Wrap { trim: true })
                .scroll((self.scroll_offset, 0));

            frame.render_widget(paragraph, area);
        }
    }

    pub fn get_status_info(&self) -> String {
        if self.content.is_empty() {
            "No content".to_string()
        } else {
            let lines = self.content.lines().count();
            let chars = self.content.len();
            format!(
                "Lines: {} | Chars: {} | Scroll: {}",
                lines, chars, self.scroll_offset
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_preview_scrolling() {
        let mut widget = PreviewWidget::new();
        widget.set_content(Arc::new("Line 1\nLine 2\nLine 3".to_string()));

        widget.scroll_down(5);
        assert_eq!(widget.scroll_offset, 5);

        widget.scroll_up(2);
        assert_eq!(widget.scroll_offset, 3);

        widget.scroll_to_top();
        assert_eq!(widget.scroll_offset, 0);
    }

    #[test]
    fn test_preview_content_update() {
        let mut widget = PreviewWidget::new();
        let content = Arc::new("# Test Content\n\nThis is a test.".to_string());

        widget.set_content(Arc::clone(&content));
        assert_eq!(widget.content.as_str(), content.as_str());
        assert_eq!(widget.scroll_offset, 0);
        assert!(widget.markdown_widget.is_some());
    }

    #[test]
    fn test_status_info() {
        let mut widget = PreviewWidget::new();
        assert_eq!(widget.get_status_info(), "No content");

        widget.set_content(Arc::new("Line 1\nLine 2".to_string()));
        let status = widget.get_status_info();
        assert!(status.contains("Lines: 2"));
        assert!(status.contains("Chars: 13"));
    }
}
