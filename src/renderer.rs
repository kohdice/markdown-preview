//! Module for rendering Markdown files
//!
//! This module parses Markdown files and content,
//! converting them to terminal-displayable format.

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

use anyhow::Result;
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};

use crate::html_entity::decode_html_entities;
use crate::output::{OutputType, TableVariant};
use crate::parser::{CodeBlockState, ContentType, ListType, RenderContext, StateChange};
use crate::theme::{MarkdownTheme, SolarizedOsaka, styled_text, styled_text_with_bg};

/// Main Markdown renderer struct
///
/// # Primary Responsibilities
/// - Loading and parsing Markdown files
/// - Markdown parsing using pulldown_cmark
/// - Converting events to terminal-displayable format
#[derive(Debug)]
pub struct MarkdownRenderer {
    pub theme: SolarizedOsaka,
    pub state: RenderContext,
    pub options: Options,
}

impl Default for MarkdownRenderer {
    fn default() -> Self {
        Self::new()
    }
}

impl MarkdownRenderer {
    /// Create a new MarkdownRenderer instance
    pub fn new() -> Self {
        let mut options = Options::empty();
        options.insert(Options::ENABLE_STRIKETHROUGH);
        options.insert(Options::ENABLE_TABLES);
        options.insert(Options::ENABLE_FOOTNOTES);
        options.insert(Options::ENABLE_TASKLISTS);

        Self {
            theme: SolarizedOsaka,
            state: RenderContext::default(),
            options,
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
        let parser = Parser::new_ext(content, self.options);

        for event in parser {
            self.process_event(event)?;
        }

        self.flush()?;
        Ok(())
    }

    /// Flush any remaining buffers
    pub fn flush(&mut self) -> Result<()> {
        if let Some(code_block) = self.state.code_block.take() {
            self.render_code_block(&code_block)?;
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
                if !self.add_text_to_state(&decoded_text) {
                    self.render_styled_text(&decoded_text);
                }
            }
            ContentType::Code(code) => {
                if !self.add_text_to_state(code) {
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
                let line = "─".repeat(40);
                let styled_line =
                    styled_text(&line, self.theme.delimiter_color(), false, false, false);
                println!("\n{}\n", styled_line);
            }
            OutputType::InlineCode { ref code } => {
                let styled_code = styled_text_with_bg(
                    code,
                    self.theme.code_color(),
                    self.theme.code_background(),
                );
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
                    let indent = "  ".repeat(depth.saturating_sub(1));
                    print!("{}", indent);

                    if let Some(list_type) = self.state.list_stack.last_mut() {
                        let marker = match list_type {
                            ListType::Unordered => "• ".to_string(),
                            ListType::Ordered { current } => {
                                let m = format!("{}.  ", current);
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
                if let Some(link) = self.state.link.take() {
                    let styled_link =
                        styled_text(&link.text, self.theme.link_color(), false, false, true);
                    let url_text = self.create_styled_url(&link.url);
                    print!("{}{}", styled_link, url_text);
                }
            }
            OutputType::Image => {
                if let Some(image) = self.state.image.take() {
                    let display_text = if image.alt_text.is_empty() {
                        "[Image]"
                    } else {
                        &image.alt_text
                    };
                    let styled_alt =
                        styled_text(display_text, self.theme.code_color(), false, true, false);
                    let url_text = self.create_styled_url(&image.url);
                    print!("{}{}", styled_alt, url_text);
                }
            }
            OutputType::Table { ref variant } => match variant {
                TableVariant::HeadStart => {
                    if let Some(ref mut table) = self.state.table {
                        table.is_header = true;
                    }
                }
                TableVariant::HeadEnd => {
                    if let Some(table) = &self.state.table {
                        // Clone the data to avoid borrow issues
                        let current_row = table.current_row.clone();
                        let alignments = table.alignments.clone();
                        self.render_table_row(&current_row, true)?;
                        self.render_table_separator(&alignments)?;
                    }

                    // Reset table state
                    if let Some(ref mut table) = self.state.table {
                        table.current_row.clear();
                        table.is_header = false;
                    }
                }
                TableVariant::RowEnd => {
                    if let Some(table) = &self.state.table {
                        // Clone to avoid borrow issues
                        let current_row = table.current_row.clone();
                        self.render_table_row(&current_row, false)?;
                    }

                    if let Some(ref mut table) = self.state.table {
                        table.current_row.clear();
                    }
                }
            },
            OutputType::CodeBlock => {
                if let Some(code_block) = self.state.code_block.take() {
                    self.render_code_block(&code_block)?;
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
                self.apply_state_change(change);
                if self.state.list_stack.is_empty() {
                    println!();
                }
                return;
            }
            StateChange::ClearTable => {
                self.apply_state_change(change);
                println!();
                return;
            }
            _ => {}
        }
        self.apply_state_change(change);
    }

    // Helper methods from BaseRenderer
    fn apply_state_change(&mut self, change: StateChange) {
        change.apply_to(&mut self.state);
    }

    fn get_text_color(&self) -> (u8, u8, u8) {
        if self.state.emphasis.strong {
            self.theme.strong_color()
        } else if self.state.emphasis.italic {
            self.theme.emphasis_color()
        } else if self.state.link.is_some() {
            self.theme.link_color()
        } else {
            self.theme.text_color()
        }
    }

    fn render_styled_text(&self, text: &str) {
        print!("{}", self.create_styled_text(text));
    }

    /// Create styled text without printing it
    fn create_styled_text(&self, text: &str) -> String {
        let color = self.get_text_color();
        styled_text(
            text,
            color,
            self.state.emphasis.strong,
            self.state.emphasis.italic,
            false,
        )
        .to_string()
    }

    /// Helper method to create styled markers (headings, list items, etc.)
    fn create_styled_marker(&self, marker: &str, color: (u8, u8, u8), bold: bool) -> String {
        styled_text(marker, color, bold, false, false).to_string()
    }

    /// Helper method to create styled URL text
    fn create_styled_url(&self, url: &str) -> String {
        self.create_styled_marker(&format!(" ({})", url), self.theme.delimiter_color(), false)
    }

    fn add_text_to_state(&mut self, text: &str) -> bool {
        if let Some(ref mut link) = self.state.link {
            link.text.push_str(text);
            return true;
        }

        if let Some(ref mut image) = self.state.image {
            image.alt_text.push_str(text);
            return true;
        }

        if let Some(ref mut code_block) = self.state.code_block {
            code_block.content.push_str(text);
            return true;
        }

        if let Some(ref mut table) = self.state.table {
            if let Some(last_cell) = table.current_row.last_mut() {
                last_cell.push_str(text);
            } else {
                table.current_row.push(text.to_string());
            }
            return true;
        }

        false
    }

    fn render_code_fence(&self, language: Option<&str>) {
        println!("{}", self.create_code_fence(language));
    }

    /// Create code fence without printing it
    fn create_code_fence(&self, language: Option<&str>) -> String {
        let fence = self.create_styled_marker("```", self.theme.delimiter_color(), false);
        if let Some(lang) = language {
            let lang_text = self.create_styled_marker(lang, self.theme.code_color(), false);
            format!("{}{}", fence, lang_text)
        } else {
            fence
        }
    }

    fn render_code_content(&self, content: &str) {
        for line in content.lines() {
            println!("{}", self.create_styled_code_line(line));
        }
    }

    /// Create styled code line without printing it
    fn create_styled_code_line(&self, line: &str) -> String {
        styled_text_with_bg(line, self.theme.code_color(), self.theme.code_background()).to_string()
    }

    fn render_code_block(&self, code_block: &CodeBlockState) -> Result<()> {
        self.render_code_fence(code_block.language.as_deref());
        self.render_code_content(&code_block.content);
        self.render_code_fence(None);

        Ok(())
    }
}

// Table rendering methods
impl MarkdownRenderer {
    fn render_table_row(&mut self, row: &[String], is_header: bool) -> Result<()> {
        // Calculate estimated size for table row (character count per cell + separators)
        let estimated_size: usize = row.iter().map(|s| s.len() + 4).sum::<usize>() + 1;
        let mut output = String::with_capacity(estimated_size);
        output.push('|');
        for cell in row {
            output.push(' ');
            if is_header {
                let styled = styled_text(cell, self.theme.heading_color(1), true, false, false);
                output.push_str(&styled);
            } else {
                output.push_str(cell);
            }
            output.push_str(" |");
        }
        println!("{}", output);
        Ok(())
    }

    fn render_table_separator(&mut self, alignments: &[pulldown_cmark::Alignment]) -> Result<()> {
        // Each separator is max 7 chars (":---:" + " |") + starting "|"
        let mut output = String::with_capacity(alignments.len() * 8 + 1);
        output.push('|');
        for alignment in alignments {
            let separator = match alignment {
                pulldown_cmark::Alignment::Left => ":---",
                pulldown_cmark::Alignment::Center => ":---:",
                pulldown_cmark::Alignment::Right => "---:",
                pulldown_cmark::Alignment::None => "---",
            };
            output.push(' ');
            output.push_str(separator);
            output.push_str(" |");
        }
        println!("{}", output);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{ImageState, LinkState, TableState};
    use rstest::rstest;

    #[test]
    fn test_renderer_creation() {
        let renderer = MarkdownRenderer::new();
        assert!(renderer.options.contains(Options::ENABLE_STRIKETHROUGH));
        assert!(renderer.options.contains(Options::ENABLE_TABLES));
        assert!(renderer.options.contains(Options::ENABLE_FOOTNOTES));
        assert!(renderer.options.contains(Options::ENABLE_TASKLISTS));
    }

    #[test]
    fn test_state_change_application() {
        let mut renderer = MarkdownRenderer::new();

        // Test strong emphasis
        renderer.apply_state_change(StateChange::SetStrongEmphasis(true));
        assert!(renderer.state.emphasis.strong);

        // Test italic emphasis
        renderer.apply_state_change(StateChange::SetItalicEmphasis(true));
        assert!(renderer.state.emphasis.italic);

        // Test link
        renderer.apply_state_change(StateChange::SetLink("https://example.com".to_string()));
        assert!(renderer.state.link.is_some());
        assert_eq!(
            renderer.state.link.as_ref().unwrap().url,
            "https://example.com"
        );

        // Test clear table
        renderer.apply_state_change(StateChange::SetTable(vec![]));
        assert!(renderer.state.table.is_some());
        renderer.apply_state_change(StateChange::ClearTable);
        assert!(renderer.state.table.is_none());
    }

    #[rstest]
    #[case(true, false, false)] // Strong emphasis
    #[case(false, true, false)] // Italic emphasis
    #[case(false, false, true)] // Link
    #[case(false, false, false)] // Normal text
    fn test_text_color_selection(
        #[case] strong: bool,
        #[case] italic: bool,
        #[case] has_link: bool,
    ) {
        let mut renderer = MarkdownRenderer::new();
        renderer.state.emphasis.strong = strong;
        renderer.state.emphasis.italic = italic;
        if has_link {
            renderer.state.link = Some(LinkState {
                text: String::new(),
                url: "test".to_string(),
            });
        }

        let color = renderer.get_text_color();
        if strong {
            assert_eq!(color, renderer.theme.strong_color());
        } else if italic {
            assert_eq!(color, renderer.theme.emphasis_color());
        } else if has_link {
            assert_eq!(color, renderer.theme.link_color());
        } else {
            assert_eq!(color, renderer.theme.text_color());
        }
    }

    #[test]
    fn test_add_text_to_state() {
        let mut renderer = MarkdownRenderer::new();

        // Test adding text to link
        renderer.state.link = Some(LinkState {
            text: String::new(),
            url: "test".to_string(),
        });
        assert!(renderer.add_text_to_state("link text"));
        assert_eq!(renderer.state.link.as_ref().unwrap().text, "link text");

        // Clear link and test image
        renderer.state.link = None;
        renderer.state.image = Some(ImageState {
            alt_text: String::new(),
            url: "image.jpg".to_string(),
        });
        assert!(renderer.add_text_to_state("alt text"));
        assert_eq!(renderer.state.image.as_ref().unwrap().alt_text, "alt text");

        // Clear image and test code block
        renderer.state.image = None;
        renderer.state.code_block = Some(CodeBlockState {
            language: None,
            content: String::new(),
        });
        assert!(renderer.add_text_to_state("code content"));
        assert_eq!(
            renderer.state.code_block.as_ref().unwrap().content,
            "code content"
        );

        // Clear code block and test table
        renderer.state.code_block = None;
        renderer.state.table = Some(TableState {
            alignments: vec![],
            current_row: vec![],
            is_header: true,
        });
        assert!(renderer.add_text_to_state("cell 1"));
        assert_eq!(
            renderer.state.table.as_ref().unwrap().current_row[0],
            "cell 1"
        );

        // Clear all and test no state
        renderer.state.table = None;
        assert!(!renderer.add_text_to_state("normal text"));
    }

    #[test]
    fn test_code_fence_creation() {
        let renderer = MarkdownRenderer::new();

        // Test without language
        let fence = renderer.create_code_fence(None);
        assert!(fence.contains("```"));

        // Test with language
        let fence_with_lang = renderer.create_code_fence(Some("rust"));
        assert!(fence_with_lang.contains("```"));
        assert!(fence_with_lang.contains("rust"));
    }

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
