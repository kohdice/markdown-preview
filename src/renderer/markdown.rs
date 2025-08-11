//! Module for rendering Markdown files
//!
//! This module parses Markdown files and content,
//! converting them to terminal-displayable format through EventHandler.

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

use anyhow::Result;
use pulldown_cmark::Parser;

use super::base::BaseRenderer;
use super::handlers::EventHandler;

/// Main Markdown renderer struct
///
/// # Primary Responsibilities
/// - Loading and parsing Markdown files
/// - Markdown parsing using pulldown_cmark
/// - Event delegation to EventHandler
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
    /// 2. Delegate each event to EventHandler
    /// 3. EventHandler converts to terminal format
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
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_render_success(content: &str) {
        let mut renderer = MarkdownRenderer::new();
        let result = renderer.render_content(content);
        assert!(result.is_ok(), "Failed to render: {:?}", result);
    }

    #[test]
    fn test_basic_markdown_elements() {
        let test_cases = vec![
            "# Heading 1",
            "## Heading 2",
            "### Heading 3",
            "**Bold text**",
            "*Italic text*",
            "[Link](https://example.com)",
            "`inline code`",
            "Plain text",
        ];

        for content in test_cases {
            assert_render_success(content);
        }
    }

    #[test]
    fn test_list_elements() {
        let test_cases = vec![
            "- Item 1\n- Item 2",
            "* Item 1\n* Item 2",
            "1. Item 1\n2. Item 2",
            "- Item 1\n  - Nested 1\n  - Nested 2",
            "1. Item 1\n   1. Nested 1\n   2. Nested 2",
            "- [ ] Unchecked task\n- [x] Checked task",
        ];

        for content in test_cases {
            assert_render_success(content);
        }
    }

    #[test]
    fn test_block_elements() {
        let test_cases = vec![
            "```rust\nfn main() {}\n```",
            "```\nplain code\n```",
            "> Blockquote",
            "> Multi\n> Line\n> Quote",
            "---",
            "***",
        ];

        for content in test_cases {
            assert_render_success(content);
        }
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
