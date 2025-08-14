use anyhow::Result;
use pulldown_cmark::Alignment;
use std::borrow::Cow;

use super::{
    MarkdownRenderer,
    state::{CodeBlockState, ListType},
    styling::TextStyle,
};
use crate::{
    output::{OutputType, TableVariant},
    theme::MarkdownTheme,
};

impl MarkdownRenderer {
    /// Central output dispatcher that handles all Markdown element rendering.
    /// Maintains consistent formatting and styling across all element types.
    pub fn print_output(&mut self, output_type: OutputType) -> Result<()> {
        match output_type {
            OutputType::Heading { level, is_end } => {
                if is_end {
                    println!("\n");
                } else {
                    let heading_marker = "#".repeat(level as usize);
                    let color = self.theme.heading_color(level);
                    let marker =
                        self.create_styled_marker(&format!("{} ", heading_marker), color, true);
                    print!("{}", marker);
                }
            }
            OutputType::Paragraph { is_end } => {
                if is_end {
                    println!();
                }
            }
            OutputType::HorizontalRule => {
                let line = self.config.create_horizontal_rule();
                let styled_line = self.apply_text_style(&line, TextStyle::Delimiter);
                println!("\n{}\n", styled_line);
            }
            OutputType::InlineCode { ref code } => {
                let styled_code = self.apply_text_style(code, TextStyle::CodeBlock);
                print!("{}", styled_code);
            }
            OutputType::TaskMarker { checked } => {
                let marker = if checked { "[x] " } else { "[ ] " };
                let styled_marker =
                    self.create_styled_marker(marker, self.theme.list_marker_color(), false);
                print!("{}", styled_marker);
            }
            OutputType::ListItem { is_end } => {
                if is_end {
                    println!();
                } else {
                    let depth = self.state.list_stack.len();
                    let indent = self.config.create_indent(depth.saturating_sub(1));
                    print!("{}", indent);

                    if let Some(list_type) = self.state.list_stack.last_mut() {
                        let marker = match list_type {
                            ListType::Unordered => Cow::Borrowed("• "),
                            ListType::Ordered { current } => {
                                let m = Cow::Owned(format!("{}.  ", current));
                                *current += 1;
                                m
                            }
                        };
                        let styled_marker = self.create_styled_marker(
                            &marker,
                            self.theme.list_marker_color(),
                            false,
                        );
                        print!("{}", styled_marker);
                    }
                }
            }
            OutputType::BlockQuote { is_end } => {
                if is_end {
                    println!();
                } else {
                    let marker =
                        self.create_styled_marker("> ", self.theme.delimiter_color(), false);
                    print!("{}", marker);
                }
            }
            OutputType::Link => {
                if let Some(link) = self.get_link() {
                    self.clear_link();
                    let styled_link = self.apply_text_style(&link.text, TextStyle::Link);
                    let url_text = self.create_styled_url(&link.url);
                    print!("{}{}", styled_link, url_text);
                }
            }
            OutputType::Image => {
                if let Some(image) = self.get_image() {
                    self.clear_image();
                    let display_text = if image.alt_text.is_empty() {
                        "[Image]"
                    } else {
                        &image.alt_text
                    };
                    let styled_alt = self.apply_text_style(display_text, TextStyle::Emphasis);
                    let url_text = self.create_styled_url(&image.url);
                    print!("{}{}", styled_alt, url_text);
                }
            }
            OutputType::Table { ref variant } => match variant {
                TableVariant::HeadStart => {
                    if let Some(ref mut table) = self.get_table_mut() {
                        table.is_header = true;
                    }
                }
                TableVariant::HeadEnd => {
                    if let Some(table) = self.get_table() {
                        let current_row = table.current_row.clone();
                        let alignments = table.alignments.clone();
                        self.render_table_row(&current_row, true)?;
                        self.render_table_separator(&alignments)?;
                    }

                    if let Some(ref mut table) = self.get_table_mut() {
                        table.current_row.clear();
                        table.is_header = false;
                    }
                }
                TableVariant::RowEnd => {
                    if let Some(table) = self.get_table() {
                        let current_row = table.current_row.clone();
                        self.render_table_row(&current_row, false)?;
                    }

                    if let Some(ref mut table) = self.get_table_mut() {
                        table.current_row.clear();
                    }
                }
            },
            OutputType::CodeBlock => {
                if let Some(code_block) = self.get_code_block() {
                    self.clear_code_block();
                    self.render_code_block(&code_block)?;
                }
            }
        }
        Ok(())
    }

    /// Renders complete code block with opening fence, content, and closing fence.
    /// Language identifier is included in opening fence if specified.
    pub(super) fn render_code_block(&self, code_block: &CodeBlockState) -> Result<()> {
        self.render_code_fence(code_block.language.as_deref());
        self.render_code_content(&code_block.content);
        self.render_code_fence(None);
        Ok(())
    }

    pub(super) fn render_code_fence(&self, language: Option<&str>) {
        println!("{}", self.create_code_fence(language));
    }

    /// Creates styled code fence marker with optional language identifier.
    /// Used for both opening (with language) and closing (without) fences.
    pub(super) fn create_code_fence(&self, language: Option<&str>) -> String {
        let fence = self.create_styled_marker("```", self.theme.delimiter_color(), false);
        if let Some(lang) = language {
            let lang_text = self.create_styled_marker(lang, self.theme.code_color(), false);
            format!("{}{}", fence, lang_text)
        } else {
            fence.into_owned()
        }
    }

    pub(super) fn render_code_content(&self, content: &str) {
        for line in content.lines() {
            println!("{}", self.create_styled_code_line(line));
        }
    }

    pub(super) fn create_styled_code_line(&self, line: &str) -> String {
        self.apply_text_style(line, TextStyle::CodeBlock)
            .to_string()
    }

    /// Formats and renders a table row with proper column separators.
    /// Header rows receive special styling for visual distinction.
    pub fn render_table_row(&mut self, row: &[String], is_header: bool) -> Result<()> {
        // Pre-allocation reduces memory reallocations during string building,
        // improving performance for tables with many columns
        let estimated_size: usize = row.iter().map(|s| s.len() + 4).sum::<usize>() + 1;
        let mut output = String::with_capacity(estimated_size);
        output.push_str(&self.config.table_separator);
        for cell in row {
            output.push(' ');
            if is_header {
                let styled = self.apply_text_style(cell, TextStyle::Heading(1));
                output.push_str(&styled.to_string());
            } else {
                output.push_str(cell);
            }
            output.push(' ');
            output.push_str(&self.config.table_separator);
        }
        println!("{}", output);
        Ok(())
    }

    /// Creates alignment-aware separator row between header and body.
    /// Alignment indicators (:) show column text alignment visually.
    pub fn render_table_separator(&mut self, alignments: &[Alignment]) -> Result<()> {
        // Each column needs up to 7 chars for alignment markers plus delimiters.
        // Pre-allocation avoids growth during string building
        let mut output = String::with_capacity(alignments.len() * 8 + 1);
        output.push_str(&self.config.table_separator);
        for alignment in alignments {
            let separator = match alignment {
                Alignment::Left => &self.config.table_alignment.left,
                Alignment::Center => &self.config.table_alignment.center,
                Alignment::Right => &self.config.table_alignment.right,
                Alignment::None => &self.config.table_alignment.none,
            };
            output.push(' ');
            output.push_str(separator);
            output.push(' ');
            output.push_str(&self.config.table_separator);
        }
        println!("{}", output);
        Ok(())
    }
}
