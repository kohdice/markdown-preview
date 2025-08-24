use std::borrow::Cow;
use std::io::Write;

use crossterm::style::{Color, StyledContent};

use mp_core::theme::{MarkdownTheme, ThemeColor};

use super::MarkdownRenderer;

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
    Custom { color: Color, bold: bool },
}

impl<W: Write> MarkdownRenderer<W> {
    pub fn apply_text_style(&self, text: &str, style: TextStyle) -> StyledContent<String> {
        use crate::theme_adapter::{styled_text, styled_text_with_bg};

        match style {
            TextStyle::Normal => styled_text(text, &self.theme.text_style()),
            TextStyle::Strong => styled_text(text, &self.theme.strong_style()),
            TextStyle::Emphasis => styled_text(text, &self.theme.emphasis_style()),
            TextStyle::Code => styled_text(text, &self.theme.code_style()),
            TextStyle::Link => styled_text(text, &self.theme.link_style()),
            TextStyle::Heading(level) => styled_text(text, &self.theme.heading_style(level)),
            TextStyle::ListMarker => styled_text(text, &self.theme.list_marker_style()),
            TextStyle::Delimiter => styled_text(text, &self.theme.delimiter_style()),
            TextStyle::CodeBlock => {
                let style = self.theme.code_style();
                let bg = self.theme.code_background();
                styled_text_with_bg(text, &style, &bg)
            }
            TextStyle::Custom { color, bold } => {
                let theme_color = match color {
                    Color::Rgb { r, g, b } => ThemeColor { r, g, b },
                    _ => ThemeColor {
                        r: 255,
                        g: 255,
                        b: 255,
                    },
                };
                let theme_style = mp_core::theme::ThemeStyle {
                    color: theme_color,
                    bold,
                    italic: false,
                    underline: false,
                };
                styled_text(text, &theme_style)
            }
        }
    }

    pub fn render_styled_text(&mut self, text: &str) {
        let styled = self.create_styled_text_with_state(text);
        self.output.write(&styled).ok();
    }

    pub fn create_styled_text_with_state(&self, text: &str) -> Cow<'static, str> {
        let style = if self.state.emphasis.strong {
            TextStyle::Strong
        } else if self.state.emphasis.italic {
            TextStyle::Emphasis
        } else if self.has_link() {
            TextStyle::Link
        } else {
            TextStyle::Normal
        };
        Cow::Owned(format!("{}", self.apply_text_style(text, style)))
    }

    pub fn create_styled_marker(
        &self,
        marker: &str,
        color: Color,
        bold: bool,
    ) -> Cow<'static, str> {
        let style = TextStyle::Custom { color, bold };
        Cow::Owned(format!("{}", self.apply_text_style(marker, style)))
    }

    pub fn create_styled_url(&self, url: &str) -> Cow<'static, str> {
        Cow::Owned(format!(
            "{}",
            self.apply_text_style(&format!(" ({})", url), TextStyle::Delimiter)
        ))
    }

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

    pub fn create_list_marker(&self, list_type: &mut crate::state::ListType) -> String {
        match list_type {
            crate::state::ListType::Unordered => "- ".to_string(),
            crate::state::ListType::Ordered { current } => {
                let marker = format!("{}. ", current);
                *current += 1;
                marker
            }
        }
    }

    pub fn create_styled_text(
        &self,
        text: &str,
        color: Color,
        bold: bool,
        italic: bool,
        underline: bool,
    ) -> Cow<'static, str> {
        let theme_color = match color {
            Color::Rgb { r, g, b } => ThemeColor { r, g, b },
            _ => ThemeColor {
                r: 147,
                g: 161,
                b: 161,
            },
        };
        let theme_style = mp_core::theme::ThemeStyle {
            color: theme_color,
            bold,
            italic,
            underline,
        };
        use crate::theme_adapter::styled_text;
        Cow::Owned(format!("{}", styled_text(text, &theme_style)))
    }

    pub fn create_styled_code_line(&self, line: &str) -> String {
        format!("{}", self.apply_text_style(line, TextStyle::Code))
    }

    pub fn create_code_fence(&self, language: Option<&str>) -> String {
        if let Some(lang) = language {
            format!("```{}", lang)
        } else {
            "```".to_string()
        }
    }
}
