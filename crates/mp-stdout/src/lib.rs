use std::fs::{self, File};
use std::io::{Read, Stdout, Write};
use std::path::Path;

use anyhow::{Context, Result};
use pulldown_cmark::{Options, Parser};

use mp_core::theme::SolarizedOsaka;
use mp_core::utils::normalize_line_endings;

pub mod buffered_output;
pub mod builder;
pub mod output;
pub mod state;

mod config;
mod formatting;
mod styling;
mod table_builder;
mod theme_adapter;

pub use builder::RendererBuilder;
pub use config::RenderConfig;
pub use state::{ActiveElement, RenderState};
pub use styling::TextStyle;
pub use table_builder::{Table, TableBuilder};

pub use self::buffered_output::BufferedOutput;

pub struct MarkdownRenderer<W: Write = Stdout> {
    pub theme: SolarizedOsaka,
    pub state: RenderState,
    pub options: Options,
    pub config: RenderConfig,
    pub output: BufferedOutput<W>,
}

impl Default for MarkdownRenderer<Stdout> {
    fn default() -> Self {
        Self::new()
    }
}

impl MarkdownRenderer<Stdout> {
    pub fn new() -> Self {
        Self::with_output(BufferedOutput::stdout())
    }
}

impl<W: Write> MarkdownRenderer<W> {
    pub fn with_output(output: BufferedOutput<W>) -> Self {
        let mut options = Options::empty();
        options.insert(Options::ENABLE_STRIKETHROUGH);
        options.insert(Options::ENABLE_TABLES);
        options.insert(Options::ENABLE_TASKLISTS);
        options.insert(Options::ENABLE_FOOTNOTES);

        Self {
            theme: SolarizedOsaka,
            state: RenderState::default(),
            options,
            config: RenderConfig::default(),
            output,
        }
    }

    pub fn render_file(&mut self, path: &Path) -> Result<()> {
        let content = read_markdown_file(path)
            .with_context(|| format!("Failed to read markdown file: {}", path.display()))?;
        self.render_content(&content)
    }

    pub fn render_content(&mut self, content: &str) -> Result<()> {
        let parser = Parser::new_ext(content, self.options);

        for event in parser {
            self.process_event(event)?;
        }

        self.flush()?;
        self.output.flush()?;
        Ok(())
    }

    pub fn flush(&mut self) -> Result<()> {
        if let Some(code_block) = self.get_code_block() {
            self.clear_active_element();
            self.render_code_block(&code_block)?;
        }
        Ok(())
    }

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

    pub fn get_link(&self) -> Option<state::LinkState> {
        self.state
            .active_element
            .as_ref()
            .and_then(|e| e.as_link())
            .cloned()
    }

    pub fn get_link_mut(&mut self) -> Option<&mut state::LinkState> {
        self.state
            .active_element
            .as_mut()
            .and_then(|e| e.as_link_mut())
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

    pub fn get_image(&self) -> Option<state::ImageState> {
        self.state
            .active_element
            .as_ref()
            .and_then(|e| e.as_image())
            .cloned()
    }

    pub fn get_image_mut(&mut self) -> Option<&mut state::ImageState> {
        self.state
            .active_element
            .as_mut()
            .and_then(|e| e.as_image_mut())
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

    pub fn get_code_block(&self) -> Option<state::CodeBlockState> {
        self.state
            .active_element
            .as_ref()
            .and_then(|e| e.as_code_block())
            .cloned()
    }

    pub fn get_code_block_mut(&mut self) -> Option<&mut state::CodeBlockState> {
        self.state
            .active_element
            .as_mut()
            .and_then(|e| e.as_code_block_mut())
    }

    pub fn set_table(&mut self, alignments: Vec<pulldown_cmark::Alignment>) {
        let column_count = alignments.len();
        self.state.active_element = Some(ActiveElement::Table(state::TableState {
            alignments,
            current_row: Vec::with_capacity(column_count),
            is_header: true,
        }));
    }

    pub fn clear_table(&mut self) {
        self.clear_active_element();
    }

    pub fn get_table(&self) -> Option<state::TableState> {
        self.state
            .active_element
            .as_ref()
            .and_then(|e| e.as_table())
            .cloned()
    }

    pub fn get_table_mut(&mut self) -> Option<&mut state::TableState> {
        self.state
            .active_element
            .as_mut()
            .and_then(|e| e.as_table_mut())
    }

    /// Build a table using the TableBuilder API
    pub fn build_table(&self) -> TableBuilder {
        TableBuilder::new()
            .separator(self.config.table_separator)
            .alignment_config(config::TableAlignmentConfig {
                left: self.config.table_alignment.left,
                center: self.config.table_alignment.center,
                right: self.config.table_alignment.right,
                none: self.config.table_alignment.none,
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

    pub fn clear_active_element(&mut self) {
        self.state.active_element = None;
    }
}

fn read_markdown_file(path: &Path) -> Result<String> {
    if !path.exists() {
        return Err(anyhow::anyhow!("File not found: {}", path.display()));
    }

    let metadata = fs::metadata(path)
        .with_context(|| format!("Failed to get metadata for: {}", path.display()))?;
    let file_size = metadata.len();

    let mut file =
        File::open(path).with_context(|| format!("Failed to open file: {}", path.display()))?;

    let mut content = String::with_capacity(file_size as usize);
    file.read_to_string(&mut content)
        .with_context(|| format!("Failed to read file: {}", path.display()))?;

    Ok(normalize_line_endings(&content).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use pulldown_cmark::Options;
    use rstest::rstest;
    use std::io::Write;
    use std::sync::{Arc, Mutex};

    struct MockWriter {
        buffer: Arc<Mutex<Vec<u8>>>,
    }

    impl MockWriter {
        fn new_with_buffer(buffer: Arc<Mutex<Vec<u8>>>) -> Self {
            MockWriter { buffer }
        }
    }

    impl Write for MockWriter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            let mut buffer = self.buffer.lock().unwrap();
            buffer.extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

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

    fn create_renderer() -> MarkdownRenderer<MockWriter> {
        let buffer = Arc::new(Mutex::new(Vec::with_capacity(1024)));
        let mock_writer = MockWriter::new_with_buffer(buffer);
        let output = BufferedOutput::new(mock_writer);
        MarkdownRenderer::with_output(output)
    }

    fn assert_render_success(content: &str) {
        let mut renderer = create_renderer();
        let result = renderer.render_content(content);
        assert!(result.is_ok(), "Failed to render: {}", content);
    }

    #[test]
    fn test_renderer_creation() {
        let renderer = create_renderer();
        assert!(renderer.options.contains(Options::ENABLE_TABLES));
        assert!(renderer.options.contains(Options::ENABLE_STRIKETHROUGH));
        assert!(renderer.options.contains(Options::ENABLE_TASKLISTS));
        assert!(renderer.options.contains(Options::ENABLE_FOOTNOTES));
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

        renderer.state.emphasis.strong = strong;
        renderer.state.emphasis.italic = italic;

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

        assert_eq!(table.column_count(), 3);
        assert_eq!(table.row_count(), 2);
        assert!(table.headers().is_some());

        let lines = table.render();
        assert!(!lines.is_empty());
        assert!(lines[0].contains("Column 1"));
        assert!(lines[1].contains(":---"));
        assert!(lines[1].contains(":---:"));
        assert!(lines[1].contains("---:"));
    }

    #[test]
    fn test_table_builder_with_config() {
        let mut renderer = create_renderer();
        renderer.config.table_separator = "||";

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
