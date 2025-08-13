//! Module for rendering Markdown files
//!
//! This module parses Markdown files and content,
//! converting them to terminal-displayable format.

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

use anyhow::Result;
use pulldown_cmark::{Options, Parser};

use crate::theme::SolarizedOsaka;

// Sub-modules
mod formatting;
mod handlers;
pub mod state;
mod styling;

// Re-export commonly used types
pub use state::{ActiveElement, RenderState};
pub use styling::TextStyle;

/// Main Markdown renderer struct
///
/// # Primary Responsibilities
/// - Loading and parsing Markdown files
/// - Markdown parsing using pulldown_cmark
/// - Converting events to terminal-displayable format
#[derive(Debug)]
pub struct MarkdownRenderer {
    pub theme: SolarizedOsaka,
    pub state: RenderState,
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
            state: RenderState::default(),
            options,
        }
    }

    // Direct state modification methods
    pub fn set_strong_emphasis(&mut self, value: bool) {
        self.state.emphasis.strong = value;
    }

    pub fn set_italic_emphasis(&mut self, value: bool) {
        self.state.emphasis.italic = value;
    }

    pub fn set_link(&mut self, url: String) {
        self.state.active_element = Some(ActiveElement::Link(state::LinkState {
            text: String::new(),
            url,
        }));
    }

    pub fn clear_link(&mut self) {
        self.clear_active_element();
    }

    pub fn has_link(&self) -> bool {
        matches!(
            self.state.active_element,
            Some(state::ActiveElement::Link(_))
        )
    }

    pub fn set_image(&mut self, url: String) {
        self.state.active_element = Some(ActiveElement::Image(state::ImageState {
            alt_text: String::new(),
            url,
        }));
    }

    pub fn clear_image(&mut self) {
        self.clear_active_element();
    }

    pub fn clear_active_element(&mut self) {
        self.state.active_element = None;
    }

    pub fn get_link(&self) -> Option<state::LinkState> {
        match &self.state.active_element {
            Some(ActiveElement::Link(link)) => Some(link.clone()),
            _ => None,
        }
    }

    pub fn get_image(&self) -> Option<state::ImageState> {
        match &self.state.active_element {
            Some(ActiveElement::Image(image)) => Some(image.clone()),
            _ => None,
        }
    }

    pub fn get_code_block(&self) -> Option<state::CodeBlockState> {
        match &self.state.active_element {
            Some(ActiveElement::CodeBlock(code_block)) => Some(code_block.clone()),
            _ => None,
        }
    }

    pub fn get_table(&self) -> Option<state::TableState> {
        match &self.state.active_element {
            Some(ActiveElement::Table(table)) => Some(table.clone()),
            _ => None,
        }
    }

    pub fn get_table_mut(&mut self) -> Option<&mut state::TableState> {
        match &mut self.state.active_element {
            Some(ActiveElement::Table(table)) => Some(table),
            _ => None,
        }
    }

    pub fn get_link_mut(&mut self) -> Option<&mut state::LinkState> {
        match &mut self.state.active_element {
            Some(ActiveElement::Link(link)) => Some(link),
            _ => None,
        }
    }

    pub fn get_image_mut(&mut self) -> Option<&mut state::ImageState> {
        match &mut self.state.active_element {
            Some(ActiveElement::Image(image)) => Some(image),
            _ => None,
        }
    }

    pub fn get_code_block_mut(&mut self) -> Option<&mut state::CodeBlockState> {
        match &mut self.state.active_element {
            Some(ActiveElement::CodeBlock(code_block)) => Some(code_block),
            _ => None,
        }
    }

    pub fn set_code_block(&mut self, kind: pulldown_cmark::CodeBlockKind<'static>) {
        let language = match kind {
            pulldown_cmark::CodeBlockKind::Indented => None,
            pulldown_cmark::CodeBlockKind::Fenced(lang) => {
                if lang.is_empty() {
                    None
                } else {
                    Some(lang.to_string())
                }
            }
        };
        self.state.active_element = Some(ActiveElement::CodeBlock(state::CodeBlockState {
            language,
            content: String::new(),
        }));
    }

    pub fn clear_code_block(&mut self) {
        self.clear_active_element();
    }

    pub fn set_table(&mut self, alignments: Vec<pulldown_cmark::Alignment>) {
        self.state.active_element = Some(ActiveElement::Table(state::TableState {
            alignments,
            current_row: Vec::new(),
            is_header: true,
        }));
    }

    pub fn clear_table(&mut self) {
        self.clear_active_element();
    }

    pub fn push_list(&mut self, start: Option<u64>) {
        let list_type = if let Some(n) = start {
            state::ListType::Ordered {
                current: n as usize,
            }
        } else {
            state::ListType::Unordered
        };
        self.state.list_stack.push(list_type);
    }

    pub fn pop_list(&mut self) {
        self.state.list_stack.pop();
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

        // Performance optimization: pre-allocate based on file size
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
        if let Some(code_block) = self.get_code_block() {
            self.clear_active_element();
            self.render_code_block(&code_block)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rstest::rstest;

    #[test]
    fn test_renderer_creation() {
        let renderer = MarkdownRenderer::new();
        assert!(renderer.options.contains(Options::ENABLE_TABLES));
        assert!(renderer.options.contains(Options::ENABLE_STRIKETHROUGH));
        assert!(renderer.options.contains(Options::ENABLE_FOOTNOTES));
        assert!(renderer.options.contains(Options::ENABLE_TASKLISTS));
    }

    #[test]
    fn test_state_change_application() {
        let mut renderer = MarkdownRenderer::new();

        renderer.set_strong_emphasis(true);
        assert!(renderer.state.emphasis.strong);

        renderer.set_italic_emphasis(true);
        assert!(renderer.state.emphasis.italic);

        renderer.set_strong_emphasis(false);
        assert!(!renderer.state.emphasis.strong);
        assert!(renderer.state.emphasis.italic);
    }

    #[rstest]
    #[case(true, false, false)]
    #[case(false, true, false)]
    #[case(false, false, true)]
    #[case(true, true, false)]
    fn test_text_color_selection(
        #[case] strong: bool,
        #[case] italic: bool,
        #[case] has_link: bool,
    ) {
        let mut renderer = MarkdownRenderer::new();

        renderer.state.emphasis.strong = strong;
        renderer.state.emphasis.italic = italic;

        if has_link {
            renderer.set_link("test".to_string());
        }

        // Test that the state was set correctly
        assert_eq!(renderer.state.emphasis.strong, strong);
        assert_eq!(renderer.state.emphasis.italic, italic);
        assert_eq!(renderer.has_link(), has_link);
    }

    #[test]
    fn test_add_text_to_state() {
        let mut renderer = MarkdownRenderer::new();

        renderer.set_link("".to_string());
        assert!(renderer.add_text_to_state("link text"));
        assert_eq!(renderer.get_link().unwrap().text, "link text");

        renderer.clear_link();
        renderer.set_image("".to_string());
        assert!(renderer.add_text_to_state("alt text"));
        assert_eq!(renderer.get_image().unwrap().alt_text, "alt text");

        renderer.clear_image();
        renderer.set_code_block(pulldown_cmark::CodeBlockKind::Indented);
        assert!(renderer.add_text_to_state("code content"));
        assert_eq!(renderer.get_code_block().unwrap().content, "code content");

        renderer.clear_code_block();
        renderer.set_table(vec![]);
        assert!(renderer.add_text_to_state("cell content"));
        assert_eq!(renderer.get_table().unwrap().current_row[0], "cell content");

        renderer.clear_table();
        assert!(!renderer.add_text_to_state("regular text"));
    }

    #[test]
    fn test_code_fence_creation() {
        let renderer = MarkdownRenderer::new();

        let fence = renderer.create_code_fence(None);
        assert!(fence.contains("```"));

        let fence_with_lang = renderer.create_code_fence(Some("rust"));
        assert!(fence_with_lang.contains("```"));
        assert!(fence_with_lang.contains("rust"));
    }

    fn assert_render_success(content: &str) {
        let mut renderer = MarkdownRenderer::new();
        let result = renderer.render_content(content);
        assert!(result.is_ok(), "Failed to render: {}", content);
    }

    #[rstest]
    #[case("# Heading 1")]
    #[case("## Heading 2")]
    #[case("Normal paragraph text")]
    #[case("**Bold text**")]
    #[case("*Italic text*")]
    #[case("[Link text](https://example.com)")]
    #[case("`inline code`")]
    fn test_basic_markdown_elements(#[case] content: &str) {
        assert_render_success(content);
    }

    #[rstest]
    #[case("- Unordered list item")]
    #[case("1. Ordered list item")]
    #[case("- [ ] Task list unchecked")]
    #[case("- [x] Task list checked")]
    fn test_list_elements(#[case] content: &str) {
        assert_render_success(content);
    }

    #[rstest]
    #[case("> Block quote")]
    #[case("```rust\ncode block\n```")]
    #[case("---")]
    fn test_block_elements(#[case] content: &str) {
        assert_render_success(content);
    }

    #[test]
    fn test_table_rendering() {
        let table = r#"
| Header 1 | Header 2 |
|----------|----------|
| Cell 1   | Cell 2   |
"#;
        assert_render_success(table);
    }

    #[test]
    fn test_complex_markdown() {
        let content = r#"
# Main Title

This is a paragraph with **bold** and *italic* text.

## Features

- First feature
- Second feature with `inline code`
- Third feature

### Code Example

```rust
fn main() {
    println!("Hello, world!");
}
```

> This is a blockquote
> with multiple lines

| Column 1 | Column 2 |
|----------|----------|
| Data 1   | Data 2   |

[Visit our website](https://example.com)
"#;
        assert_render_success(content);
    }
}
