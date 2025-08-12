//! Module for rendering Markdown files
//!
//! This module parses Markdown files and content,
//! converting them to terminal-displayable format.

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

use anyhow::Result;
use pulldown_cmark::{Event, Parser, Tag, TagEnd};

use super::base::BaseRenderer;
use super::handlers::ContentType;
use super::state::{ListType, StateChange};
use super::terminal::{OutputType, TableVariant};
use super::theme::{MarkdownTheme, styled_text, styled_text_with_bg};
use crate::html_entity::decode_html_entities;

/// Main Markdown renderer struct
///
/// # Primary Responsibilities
/// - Loading and parsing Markdown files
/// - Markdown parsing using pulldown_cmark
/// - Converting events to terminal-displayable format
#[derive(Debug)]
pub struct MarkdownRenderer {
    pub(crate) base: BaseRenderer,
}

impl Default for MarkdownRenderer {
    fn default() -> Self {
        Self::new()
    }
}

impl MarkdownRenderer {
    /// Create a new MarkdownRenderer instance
    pub fn new() -> Self {
        Self {
            base: BaseRenderer::new(),
        }
    }

    /// Load and render Markdown content from a file
    ///
    /// # Performance Optimizations
    /// - Pre-allocate memory based on file size
    /// - Efficient reading using BufReader
    ///
    /// # Error Handling
    /// - Returns detailed error message if file doesn't exist
    pub fn render_file(&mut self, path: &Path) -> Result<()> {
        let file = File::open(path)
            .map_err(|e| anyhow::anyhow!("Failed to open file '{}': {}", path.display(), e))?;

        // Pre-allocate memory based on file size
        let metadata = file.metadata()?;
        let file_size = metadata.len() as usize;

        let mut reader = BufReader::new(file);
        let mut content = String::with_capacity(file_size);
        reader.read_to_string(&mut content)?;

        self.render_content(&content)?;
        Ok(())
    }

    /// Render Markdown content directly
    ///
    /// # Processing Flow
    /// 1. Parse Markdown with pulldown_cmark
    /// 2. Process each event
    /// 3. Convert to terminal format
    pub fn render_content(&mut self, content: &str) -> Result<()> {
        let parser = Parser::new_ext(content, self.base.options);

        for event in parser {
            self.process_event(event)?;
        }

        self.flush()?;
        Ok(())
    }

    /// Flush any remaining buffers
    pub fn flush(&mut self) -> Result<()> {
        if let Some(code_block) = self.base.state.code_block.take() {
            self.base.render_code_block(&code_block)?;
        }
        Ok(())
    }

    /// Main method for processing events
    pub fn process_event(&mut self, event: Event) -> Result<()> {
        match event {
            Event::Start(tag) => self.handle_tag(tag, true),
            Event::End(tag) => match tag {
                TagEnd::Heading(level) => self.handle_tag(
                    Tag::Heading {
                        level,
                        id: None,
                        classes: vec![],
                        attrs: vec![],
                    },
                    false,
                ),
                TagEnd::Paragraph => self.handle_tag(Tag::Paragraph, false),
                TagEnd::Strong => self.handle_tag(Tag::Strong, false),
                TagEnd::Emphasis => self.handle_tag(Tag::Emphasis, false),
                TagEnd::Link => self.handle_tag(
                    Tag::Link {
                        link_type: pulldown_cmark::LinkType::Inline,
                        dest_url: "".into(),
                        title: "".into(),
                        id: "".into(),
                    },
                    false,
                ),
                TagEnd::List(_) => self.handle_tag(Tag::List(None), false),
                TagEnd::Item => self.handle_tag(Tag::Item, false),
                TagEnd::CodeBlock => self.handle_tag(
                    Tag::CodeBlock(pulldown_cmark::CodeBlockKind::Indented),
                    false,
                ),
                TagEnd::Table => self.handle_tag(Tag::Table(vec![]), false),
                TagEnd::TableHead => self.handle_tag(Tag::TableHead, false),
                TagEnd::TableRow => self.handle_tag(Tag::TableRow, false),
                TagEnd::BlockQuote(_) => self.handle_tag(Tag::BlockQuote(None), false),
                TagEnd::Image => self.handle_tag(
                    Tag::Image {
                        link_type: pulldown_cmark::LinkType::Inline,
                        dest_url: "".into(),
                        title: "".into(),
                        id: "".into(),
                    },
                    false,
                ),
                _ => Ok(()),
            },
            Event::Text(text) => self.handle_content(ContentType::Text(&text)),
            Event::Code(code) => self.handle_content(ContentType::Code(&code)),
            Event::Html(html) => self.handle_content(ContentType::Html(&html)),
            Event::SoftBreak => self.handle_content(ContentType::SoftBreak),
            Event::HardBreak => self.handle_content(ContentType::HardBreak),
            Event::Rule => self.handle_content(ContentType::Rule),
            Event::TaskListMarker(checked) => self.handle_content(ContentType::TaskMarker(checked)),
            _ => Ok(()),
        }
    }

    /// Handle tag start and end
    fn handle_tag(&mut self, tag: Tag, is_start: bool) -> Result<()> {
        if is_start {
            match tag {
                Tag::Heading { level, .. } => {
                    let _ = self.print_output(OutputType::Heading {
                        level: level as u8,
                        is_end: false,
                    });
                }
                Tag::Paragraph => {
                    let _ = self.print_output(OutputType::Paragraph { is_end: false });
                }
                Tag::Strong => self.apply_state(StateChange::SetStrongEmphasis(true)),
                Tag::Emphasis => self.apply_state(StateChange::SetItalicEmphasis(true)),
                Tag::Link { dest_url, .. } => {
                    self.apply_state(StateChange::SetLink(dest_url.to_string()));
                }
                Tag::List(start) => self.apply_state(StateChange::PushList(start)),
                Tag::Item => {
                    let _ = self.print_output(OutputType::ListItem { is_end: false });
                }
                Tag::CodeBlock(kind) => {
                    // Convert lifetime to 'static by cloning if necessary
                    let static_kind = match kind {
                        pulldown_cmark::CodeBlockKind::Indented => {
                            pulldown_cmark::CodeBlockKind::Indented
                        }
                        pulldown_cmark::CodeBlockKind::Fenced(lang) => {
                            pulldown_cmark::CodeBlockKind::Fenced(lang.to_string().into())
                        }
                    };
                    self.apply_state(StateChange::SetCodeBlock(static_kind));
                }
                Tag::Table(alignments) => {
                    self.apply_state(StateChange::SetTable(alignments));
                }
                Tag::TableHead => {
                    let _ = self.print_output(OutputType::Table {
                        variant: TableVariant::HeadStart,
                    });
                }
                Tag::BlockQuote(_) => {
                    let _ = self.print_output(OutputType::BlockQuote { is_end: false });
                }
                Tag::Image { dest_url, .. } => {
                    self.apply_state(StateChange::SetImage(dest_url.to_string()));
                }
                _ => {}
            }
        } else {
            match tag {
                Tag::Heading { .. } => {
                    let _ = self.print_output(OutputType::Heading {
                        level: 0,
                        is_end: true,
                    });
                }
                Tag::Paragraph => {
                    let _ = self.print_output(OutputType::Paragraph { is_end: true });
                }
                Tag::Strong => self.apply_state(StateChange::SetStrongEmphasis(false)),
                Tag::Emphasis => self.apply_state(StateChange::SetItalicEmphasis(false)),
                Tag::Link { .. } => {
                    let _ = self.print_output(OutputType::Link);
                }
                Tag::List(_) => self.apply_state(StateChange::PopList),
                Tag::Item => {
                    let _ = self.print_output(OutputType::ListItem { is_end: true });
                }
                Tag::CodeBlock(_) => self.print_output(OutputType::CodeBlock)?,
                Tag::Table(_) => self.apply_state(StateChange::ClearTable),
                Tag::TableHead => {
                    self.print_output(OutputType::Table {
                        variant: TableVariant::HeadEnd,
                    })?;
                }
                Tag::TableRow => {
                    self.print_output(OutputType::Table {
                        variant: TableVariant::RowEnd,
                    })?;
                }
                Tag::BlockQuote(_) => {
                    let _ = self.print_output(OutputType::BlockQuote { is_end: true });
                }
                Tag::Image { .. } => {
                    let _ = self.print_output(OutputType::Image);
                }
                _ => {}
            }
        }
        Ok(())
    }

    /// Handle text-related events
    fn handle_content(&mut self, content: ContentType) -> Result<()> {
        match content {
            ContentType::Text(text) => {
                let decoded_text = decode_html_entities(text);
                if !self.base.add_text_to_state(&decoded_text) {
                    self.base.render_styled_text(&decoded_text);
                }
            }
            ContentType::Code(code) => {
                if !self.base.add_text_to_state(code) {
                    let _ = self.print_output(OutputType::InlineCode {
                        code: code.to_string(),
                    });
                }
            }
            ContentType::Html(html) => {
                let decoded = decode_html_entities(html);
                print!("{}", decoded);
            }
            ContentType::SoftBreak => print!(" "),
            ContentType::HardBreak => println!(),
            ContentType::Rule => {
                let _ = self.print_output(OutputType::HorizontalRule);
            }
            ContentType::TaskMarker(checked) => {
                let _ = self.print_output(OutputType::TaskMarker { checked });
            }
        }
        Ok(())
    }

    /// Unified output method
    pub fn print_output(&mut self, output_type: OutputType) -> Result<()> {
        match output_type {
            OutputType::Heading { level, is_end } => {
                if is_end {
                    println!("\n");
                } else {
                    let heading_marker = "#".repeat(level as usize);
                    let color = self.base.theme.heading_color(level);
                    let styled_marker =
                        styled_text(format!("{} ", heading_marker), color, true, false, false);
                    print!("{}", styled_marker);
                }
            }
            OutputType::Paragraph { is_end } => {
                if is_end {
                    println!();
                }
            }
            OutputType::HorizontalRule => {
                let line = "─".repeat(40);
                let styled_line = styled_text(
                    &line,
                    self.base.theme.delimiter_color(),
                    false,
                    false,
                    false,
                );
                println!("\n{}\n", styled_line);
            }
            OutputType::InlineCode { ref code } => {
                let styled_code = styled_text_with_bg(
                    code,
                    self.base.theme.code_color(),
                    self.base.theme.code_background(),
                );
                print!("{}", styled_code);
            }
            OutputType::TaskMarker { checked } => {
                let marker = if checked { "[x] " } else { "[ ] " };
                let styled_marker = styled_text(
                    marker,
                    self.base.theme.list_marker_color(),
                    false,
                    false,
                    false,
                );
                print!("{}", styled_marker);
            }
            OutputType::ListItem { is_end } => {
                if is_end {
                    println!();
                } else {
                    let depth = self.base.state.list_stack.len();
                    let indent = "  ".repeat(depth.saturating_sub(1));
                    print!("{}", indent);

                    if let Some(list_type) = self.base.state.list_stack.last_mut() {
                        let marker = match list_type {
                            ListType::Unordered => "• ".to_string(),
                            ListType::Ordered { current } => {
                                let m = format!("{}.  ", current);
                                *current += 1;
                                m
                            }
                        };
                        let styled_marker = styled_text(
                            &marker,
                            self.base.theme.list_marker_color(),
                            false,
                            false,
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
                        styled_text("> ", self.base.theme.delimiter_color(), false, false, false);
                    print!("{}", marker);
                }
            }
            OutputType::Link => {
                if let Some(link) = self.base.state.link.take() {
                    let styled_link =
                        styled_text(&link.text, self.base.theme.link_color(), false, false, true);
                    let url_text = styled_text(
                        format!(" ({})", link.url),
                        self.base.theme.delimiter_color(),
                        false,
                        false,
                        false,
                    );
                    print!("{}{}", styled_link, url_text);
                }
            }
            OutputType::Image => {
                if let Some(image) = self.base.state.image.take() {
                    let display_text = if image.alt_text.is_empty() {
                        "[Image]"
                    } else {
                        &image.alt_text
                    };
                    let styled_alt =
                        styled_text(display_text, self.base.theme.cyan(), false, true, false);
                    let url_text = styled_text(
                        format!(" ({})", image.url),
                        self.base.theme.delimiter_color(),
                        false,
                        false,
                        false,
                    );
                    print!("{}{}", styled_alt, url_text);
                }
            }
            OutputType::Table { ref variant } => match variant {
                TableVariant::HeadStart => {
                    if let Some(ref mut table) = self.base.state.table {
                        table.is_header = true;
                    }
                }
                TableVariant::HeadEnd => {
                    if let Some(ref table) = self.base.state.table {
                        // Use reference for better performance
                        self.base.render_table_row(&table.current_row, true)?;
                        self.base.render_table_separator(&table.alignments)?;
                    }

                    // Reset table state
                    if let Some(ref mut table) = self.base.state.table {
                        table.current_row.clear();
                        table.is_header = false;
                    }
                }
                TableVariant::RowEnd => {
                    if let Some(ref table) = self.base.state.table {
                        // Use direct reference (no clone needed)
                        self.base.render_table_row(&table.current_row, false)?;
                    }

                    if let Some(ref mut table) = self.base.state.table {
                        table.current_row.clear();
                    }
                }
            },
            OutputType::CodeBlock => {
                if let Some(code_block) = self.base.state.code_block.take() {
                    self.base.render_code_block(&code_block)?;
                }
            }
        }
        Ok(())
    }

    /// Apply state change
    pub fn apply_state(&mut self, change: StateChange) {
        // Handle special cases before applying state change
        match &change {
            StateChange::PopList => {
                self.base.apply_state_change(change);
                if self.base.state.list_stack.is_empty() {
                    println!();
                }
                return;
            }
            StateChange::ClearTable => {
                self.base.apply_state_change(change);
                println!();
                return;
            }
            _ => {}
        }
        self.base.apply_state_change(change);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rstest::rstest;

    fn assert_render_success(content: &str) {
        let mut renderer = MarkdownRenderer::new();
        let result = renderer.render_content(content);
        assert!(result.is_ok(), "Failed to render: {:?}", result);
    }

    // Use rstest for parameterized tests to reduce duplication
    #[rstest]
    #[case("# Heading 1")]
    #[case("## Heading 2")]
    #[case("### Heading 3")]
    #[case("**Bold text**")]
    #[case("*Italic text*")]
    #[case("[Link](https://example.com)")]
    #[case("`inline code`")]
    #[case("Plain text")]
    fn test_basic_markdown_elements(#[case] content: &str) {
        assert_render_success(content);
    }

    #[rstest]
    #[case("- Item 1\n- Item 2")]
    #[case("* Item 1\n* Item 2")]
    #[case("1. Item 1\n2. Item 2")]
    #[case("- Item 1\n  - Nested 1\n  - Nested 2")]
    #[case("1. Item 1\n   1. Nested 1\n   2. Nested 2")]
    #[case("- [ ] Unchecked task\n- [x] Checked task")]
    fn test_list_elements(#[case] content: &str) {
        assert_render_success(content);
    }

    #[rstest]
    #[case("```rust\nfn main() {}\n```")]
    #[case("```\nplain code\n```")]
    #[case("> Blockquote")]
    #[case("> Multi\n> Line\n> Quote")]
    #[case("---")]
    #[case("***")]
    fn test_block_elements(#[case] content: &str) {
        assert_render_success(content);
    }

    #[test]
    fn test_table_rendering() {
        let table = r#"
| Header 1 | Header 2 | Header 3 |
|----------|:--------:|---------:|
| Left     | Center   | Right    |
| Cell 1   | Cell 2   | Cell 3   |
"#;
        assert_render_success(table);
    }

    #[test]
    fn test_complex_markdown() {
        let content = r#"
# Main Title

This is a paragraph with **bold** and *italic* text.

## Lists

- Item 1
- Item 2
  - Nested item

1. Ordered item 1
2. Ordered item 2

## Code

```rust
fn main() {
    println!("Hello, world!");
}
```

## Table

| Header 1 | Header 2 |
|----------|----------|
| Cell 1   | Cell 2   |

> Blockquote text

---

Task list:
- [x] Completed task
- [ ] Incomplete task
"#;
        assert_render_success(content);
    }
}
