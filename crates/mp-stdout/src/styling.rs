use std::borrow::Cow;
use std::io::Write;

use colored::ColoredString;

use super::MarkdownRenderer;
use mp_core::theme::MarkdownTheme;

/// Text styling for Markdown elements
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TextStyle {
    Normal,
    Strong,
    Emphasis,
    Code,
    Link,
    Heading(u8),
    ListMarker,
    Delimiter,
    CodeBlock,
    Custom { color: (u8, u8, u8), bold: bool },
}

impl<W: Write> MarkdownRenderer<W> {
    /// Apply text styling based on TextStyle enum
    pub fn apply_text_style(&self, text: &str, style: TextStyle) -> ColoredString {
        use mp_core::theme::{styled_text, styled_text_with_bg};

        match style {
            TextStyle::Normal => styled_text(text, self.theme.text_color(), false, false, false),
            TextStyle::Strong => styled_text(text, self.theme.strong_color(), true, false, false),
            TextStyle::Emphasis => {
                styled_text(text, self.theme.emphasis_color(), false, true, false)
            }
            TextStyle::Code => styled_text(text, self.theme.code_color(), false, false, false),
            TextStyle::Link => styled_text(text, self.theme.link_color(), false, false, true),
            TextStyle::Heading(level) => {
                styled_text(text, self.theme.heading_color(level), true, false, false)
            }
            TextStyle::ListMarker => {
                styled_text(text, self.theme.list_marker_color(), false, false, false)
            }
            TextStyle::Delimiter => {
                styled_text(text, self.theme.delimiter_color(), false, false, false)
            }
            TextStyle::CodeBlock => {
                styled_text_with_bg(text, self.theme.code_color(), self.theme.code_background())
            }
            TextStyle::Custom { color, bold } => styled_text(text, color, bold, false, false),
        }
    }

    pub fn render_styled_text(&mut self, text: &str) {
        let styled = self.create_styled_text(text);
        self.output.write(&styled).ok();
    }

    /// Create styled text based on current emphasis state
    pub fn create_styled_text(&self, text: &str) -> Cow<'static, str> {
        let style = if self.state.emphasis.strong {
            TextStyle::Strong
        } else if self.state.emphasis.italic {
            TextStyle::Emphasis
        } else if self.has_link() {
            TextStyle::Link
        } else {
            TextStyle::Normal
        };
        Cow::Owned(self.apply_text_style(text, style).to_string())
    }

    /// Create styled marker text
    pub fn create_styled_marker(
        &self,
        marker: &str,
        color: (u8, u8, u8),
        bold: bool,
    ) -> Cow<'static, str> {
        let style = if color == self.theme.list_marker_color() {
            TextStyle::ListMarker
        } else if color == self.theme.delimiter_color() {
            TextStyle::Delimiter
        } else {
            TextStyle::Custom { color, bold }
        };

        Cow::Owned(self.apply_text_style(marker, style).to_string())
    }

    /// Format URLs with delimiters
    pub fn create_styled_url(&self, url: &str) -> Cow<'static, str> {
        Cow::Owned(
            self.apply_text_style(&format!(" ({})", url), TextStyle::Delimiter)
                .to_string(),
        )
    }

    /// Route text to active element buffer
    pub fn add_text_to_state(&mut self, text: &str) -> bool {
        if let Some(ref mut link) = self.get_link_mut() {
            link.text.push_str(text);
            return true;
        }

        if let Some(ref mut image) = self.get_image_mut() {
            image.alt_text.push_str(text);
            return true;
        }

        if let Some(ref mut code_block) = self.get_code_block_mut() {
            code_block.content.push_str(text);
            return true;
        }

        if let Some(ref mut table) = self.get_table_mut() {
            if let Some(last_cell) = table.current_row.last_mut() {
                last_cell.push_str(text);
            } else {
                table.current_row.push(text.to_string());
            }
            return true;
        }

        false
    }
}
