use super::MarkdownRenderer;
use crate::theme::MarkdownTheme;
use colored::ColoredString;

/// Unified text styling options
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
    /// Custom style with specific color and formatting
    Custom {
        color: (u8, u8, u8),
        bold: bool,
    },
}

impl MarkdownRenderer {
    /// Apply unified text styling based on style type
    pub fn apply_text_style(&self, text: &str, style: TextStyle) -> ColoredString {
        use crate::theme::{styled_text, styled_text_with_bg};

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

    /// Render styled text to stdout
    pub fn render_styled_text(&self, text: &str) {
        print!("{}", self.create_styled_text(text));
    }

    /// Create styled text without printing it
    pub fn create_styled_text(&self, text: &str) -> String {
        let style = if self.state.emphasis.strong {
            TextStyle::Strong
        } else if self.state.emphasis.italic {
            TextStyle::Emphasis
        } else if self.has_link() {
            TextStyle::Link
        } else {
            TextStyle::Normal
        };
        self.apply_text_style(text, style).to_string()
    }

    /// Helper method to create styled markers (headings, list items, etc.)
    pub fn create_styled_marker(&self, marker: &str, color: (u8, u8, u8), bold: bool) -> String {
        // Determine style based on color and bold settings
        let style = if color == self.theme.list_marker_color() {
            TextStyle::ListMarker
        } else if color == self.theme.delimiter_color() {
            TextStyle::Delimiter
        } else {
            // Use custom style for specific color/bold combinations
            TextStyle::Custom { color, bold }
        };

        self.apply_text_style(marker, style).to_string()
    }

    /// Helper method to create styled URL text
    pub fn create_styled_url(&self, url: &str) -> String {
        self.apply_text_style(&format!(" ({})", url), TextStyle::Delimiter)
            .to_string()
    }

    /// Add text to the appropriate state container
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
