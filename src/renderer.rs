//! Module for rendering Markdown files
//!
//! This module parses Markdown files and content,
//! converting them to terminal-displayable format.

use std::path::Path;

use anyhow::Result;
use pulldown_cmark::{Options, Parser};

use crate::theme::SolarizedOsaka;

// Internal modules for separating rendering concerns
mod config;
mod element_accessor;
mod formatting;
mod handlers;
mod io;
pub mod state;
mod styling;
mod table_builder;

// Public API exports for external module usage
pub use config::RenderConfig;
pub use element_accessor::{
    CodeBlockAccessor, ElementData, ImageAccessor, LinkAccessor, TableAccessor,
};
pub use state::{ActiveElement, RenderState};
pub use styling::TextStyle;
pub use table_builder::{Table, TableBuilder};

// Re-export core rendering functionality
use self::io::read_file;

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
    pub config: RenderConfig,
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
            config: RenderConfig::default(),
        }
    }

    // Generic accessor methods using ElementData trait.
    // These replace all repetitive getter/setter methods with a single implementation.
    /// Get immutable reference to element data of type T
    pub fn get<T: ElementData>(&self) -> Option<&T::Output> {
        self.state.active_element.as_ref().and_then(T::extract)
    }

    /// Get mutable reference to element data of type T
    pub fn get_mut<T: ElementData>(&mut self) -> Option<&mut T::Output> {
        self.state.active_element.as_mut().and_then(T::extract_mut)
    }

    /// Get cloned element data of type T
    pub fn get_cloned<T>(&self) -> Option<T::Output>
    where
        T: ElementData,
        T::Output: Clone,
    {
        self.get::<T>().cloned()
    }

    /// Set active element with data of type T
    pub fn set<T: ElementData>(&mut self, data: T::Output) {
        self.state.active_element = Some(T::create(data));
    }

    // State management methods for tracking active Markdown elements during parsing.
    // These methods provide a clean API for state transitions without exposing
    // the internal state structure directly.
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

    // Legacy methods for backward compatibility - delegate to generic implementation
    pub fn get_link(&self) -> Option<state::LinkState> {
        self.get_cloned::<LinkAccessor>()
    }

    pub fn get_image(&self) -> Option<state::ImageState> {
        self.get_cloned::<ImageAccessor>()
    }

    pub fn get_code_block(&self) -> Option<state::CodeBlockState> {
        self.get_cloned::<CodeBlockAccessor>()
    }

    pub fn get_table(&self) -> Option<state::TableState> {
        self.get_cloned::<TableAccessor>()
    }

    pub fn get_table_mut(&mut self) -> Option<&mut state::TableState> {
        self.get_mut::<TableAccessor>()
    }

    pub fn get_link_mut(&mut self) -> Option<&mut state::LinkState> {
        self.get_mut::<LinkAccessor>()
    }

    pub fn get_image_mut(&mut self) -> Option<&mut state::ImageState> {
        self.get_mut::<ImageAccessor>()
    }

    pub fn get_code_block_mut(&mut self) -> Option<&mut state::CodeBlockState> {
        self.get_mut::<CodeBlockAccessor>()
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

    /// Build a table using the TableBuilder API
    ///
    /// # Example
    /// ```no_run
    /// use markdown_preview::renderer::MarkdownRenderer;
    ///
    /// let renderer = MarkdownRenderer::new();
    /// let table = renderer.build_table()
    ///     .header(vec!["Name", "Age"])
    ///     .row(vec!["Alice", "30"])
    ///     .build()
    ///     .unwrap();
    /// ```
    pub fn build_table(&self) -> TableBuilder {
        TableBuilder::new()
            .separator(self.config.table_separator.clone())
            .alignment_config(table_builder::TableAlignmentConfig {
                left: self.config.table_alignment.left.clone(),
                center: self.config.table_alignment.center.clone(),
                right: self.config.table_alignment.right.clone(),
                none: self.config.table_alignment.none.clone(),
            })
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
    /// - Efficient reading delegated to io module
    ///
    /// # Error Handling
    /// - Returns detailed error message if file doesn't exist
    pub fn render_file(&mut self, path: &Path) -> Result<()> {
        let content = read_file(path)?;
        self.render_content(&content)
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
    use pulldown_cmark::Options;
    use rstest::rstest;

    // ====================
    // Test Data Constants
    // ====================

    /// Common test data for various markdown elements
    mod test_data {
        pub const HEADING_1: &str = "# Heading 1";
        pub const HEADING_2: &str = "## Heading 2";
        pub const PARAGRAPH: &str = "Normal paragraph text";
        pub const BOLD_TEXT: &str = "**Bold text**";
        pub const ITALIC_TEXT: &str = "*Italic text*";
        pub const LINK: &str = "[Link text](https://example.com)";
        pub const INLINE_CODE: &str = "`inline code`";

        pub const UNORDERED_LIST: &str = "- Unordered list item";
        pub const ORDERED_LIST: &str = "1. Ordered list item";
        pub const TASK_UNCHECKED: &str = "- [ ] Task list unchecked";
        pub const TASK_CHECKED: &str = "- [x] Task list checked";

        pub const BLOCKQUOTE: &str = "> Block quote";
        pub const CODE_BLOCK: &str = "```rust\ncode block\n```";
        pub const HORIZONTAL_RULE: &str = "---";

        pub const TABLE: &str = r#"
| Header 1 | Header 2 |
|----------|----------|
| Cell 1   | Cell 2   |
"#;

        pub const COMPLEX_MARKDOWN: &str = r#"
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
    }

    // ====================
    // Helper Functions
    // ====================

    /// Helper function to create a renderer with default settings
    fn create_renderer() -> MarkdownRenderer {
        MarkdownRenderer::new()
    }

    /// Helper function to assert rendering succeeds
    fn assert_render_success(content: &str) {
        let mut renderer = create_renderer();
        let result = renderer.render_content(content);
        assert!(result.is_ok(), "Failed to render: {}", content);
    }

    /// Helper function to set emphasis state
    fn set_emphasis_state(renderer: &mut MarkdownRenderer, strong: bool, italic: bool) {
        renderer.state.emphasis.strong = strong;
        renderer.state.emphasis.italic = italic;
    }

    // ====================
    // Unit Tests
    // ====================

    #[test]
    fn test_renderer_creation() {
        let renderer = create_renderer();
        assert!(renderer.options.contains(Options::ENABLE_TABLES));
        assert!(renderer.options.contains(Options::ENABLE_STRIKETHROUGH));
        assert!(renderer.options.contains(Options::ENABLE_FOOTNOTES));
        assert!(renderer.options.contains(Options::ENABLE_TASKLISTS));
    }

    #[test]
    fn test_state_change_application() {
        let mut renderer = create_renderer();

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
        let mut renderer = create_renderer();

        set_emphasis_state(&mut renderer, strong, italic);

        if has_link {
            renderer.set_link("test".to_string());
        }

        assert_eq!(renderer.state.emphasis.strong, strong);
        assert_eq!(renderer.state.emphasis.italic, italic);
        assert_eq!(renderer.has_link(), has_link);
    }

    #[test]
    fn test_add_text_to_state() {
        let mut renderer = create_renderer();

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
        let renderer = create_renderer();

        let fence = renderer.create_code_fence(None);
        assert!(fence.contains("```"));

        let fence_with_lang = renderer.create_code_fence(Some("rust"));
        assert!(fence_with_lang.contains("```"));
        assert!(fence_with_lang.contains("rust"));
    }

    // ====================
    // Parametrized Tests
    // ====================

    #[rstest]
    #[case(test_data::HEADING_1)]
    #[case(test_data::HEADING_2)]
    #[case(test_data::PARAGRAPH)]
    #[case(test_data::BOLD_TEXT)]
    #[case(test_data::ITALIC_TEXT)]
    #[case(test_data::LINK)]
    #[case(test_data::INLINE_CODE)]
    fn test_basic_markdown_elements(#[case] content: &str) {
        assert_render_success(content);
    }

    #[rstest]
    #[case(test_data::UNORDERED_LIST)]
    #[case(test_data::ORDERED_LIST)]
    #[case(test_data::TASK_UNCHECKED)]
    #[case(test_data::TASK_CHECKED)]
    fn test_list_elements(#[case] content: &str) {
        assert_render_success(content);
    }

    #[rstest]
    #[case(test_data::BLOCKQUOTE)]
    #[case(test_data::CODE_BLOCK)]
    #[case(test_data::HORIZONTAL_RULE)]
    fn test_block_elements(#[case] content: &str) {
        assert_render_success(content);
    }

    #[test]
    fn test_table_rendering() {
        assert_render_success(test_data::TABLE);
    }

    #[test]
    fn test_table_builder_integration() {
        let renderer = create_renderer();

        // Test building a table with the integrated builder
        let table = renderer
            .build_table()
            .header(vec!["Column 1", "Column 2", "Column 3"])
            .alignments(vec![
                pulldown_cmark::Alignment::Left,
                pulldown_cmark::Alignment::Center,
                pulldown_cmark::Alignment::Right,
            ])
            .row(vec!["Left", "Center", "Right"])
            .row(vec!["Data 1", "Data 2", "Data 3"])
            .build()
            .unwrap();

        // Verify table structure
        assert_eq!(table.column_count(), 3);
        assert_eq!(table.row_count(), 2);
        assert!(table.headers().is_some());

        // Verify rendering output
        let lines = table.render();
        assert!(!lines.is_empty());
        assert!(lines[0].contains("Column 1"));
        assert!(lines[1].contains(":---")); // Left alignment
        assert!(lines[1].contains(":---:")); // Center alignment
        assert!(lines[1].contains("---:")); // Right alignment
    }

    #[test]
    fn test_table_builder_with_config() {
        let mut renderer = create_renderer();
        renderer.config.table_separator = "||".to_string();

        let table = renderer
            .build_table()
            .header(vec!["A", "B"])
            .row(vec!["1", "2"])
            .build()
            .unwrap();

        let lines = table.render();
        assert!(lines[0].starts_with("||"));
        assert!(lines[0].contains("|| A ||"));
    }

    #[test]
    fn test_complex_markdown() {
        assert_render_success(test_data::COMPLEX_MARKDOWN);
    }
}
