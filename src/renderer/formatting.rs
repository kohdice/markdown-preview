use anyhow::Result;
use pulldown_cmark::Alignment;
use std::borrow::Cow;
use std::io::Write;

use super::{
    MarkdownRenderer,
    state::{CodeBlockState, ListType},
    styling::TextStyle,
};
use crate::{
    output::{ElementKind, ElementPhase, OutputType, TableVariant},
    theme::MarkdownTheme,
};

impl<W: Write> MarkdownRenderer<W> {
    pub fn print_output(&mut self, output_type: OutputType) -> Result<()> {
        match output_type {
            OutputType::Element { kind, phase } => {
                self.handle_element_output(kind, phase)?;
            }
            OutputType::HorizontalRule => {
                let line = self.config.create_horizontal_rule();
                let styled_line = self.apply_text_style(&line, TextStyle::Delimiter);
                self.output.writeln("")?;
                self.output.writeln(&styled_line)?;
                self.output.writeln("")?;
            }
            OutputType::InlineCode { ref code } => {
                let styled_code = self.apply_text_style(code, TextStyle::CodeBlock);
                self.output.write(&styled_code)?;
            }
            OutputType::TaskMarker { checked } => {
                let marker = if checked { "[x] " } else { "[ ] " };
                let styled_marker =
                    self.create_styled_marker(marker, self.theme.list_marker_color(), false);
                self.output.write(&styled_marker)?;
            }
            OutputType::Link => {
                if let Some(link) = self.get_link() {
                    self.clear_link();
                    let styled_link = self.apply_text_style(&link.text, TextStyle::Link);
                    let url_text = self.create_styled_url(&link.url);
                    self.output.write(&styled_link)?;
                    self.output.write(&url_text)?;
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
                    self.output.write(&styled_alt)?;
                    self.output.write(&url_text)?;
                }
            }
            OutputType::CodeBlock => {
                if let Some(code_block) = self.get_code_block() {
                    self.clear_code_block();
                    self.render_code_block(&code_block)?;
                }
            }
        }
        Ok(())
    }

    fn handle_element_output(&mut self, kind: ElementKind, phase: ElementPhase) -> Result<()> {
        match kind {
            ElementKind::Heading(level) => self.render_heading(level, phase),
            ElementKind::Paragraph => self.render_paragraph(phase),
            ElementKind::ListItem => self.render_list_item(phase),
            ElementKind::BlockQuote => self.render_blockquote(phase),
            ElementKind::Table(ref variant) => self.render_table_element(variant),
        }
    }

    fn render_heading(&mut self, level: u8, phase: ElementPhase) -> Result<()> {
        if phase == ElementPhase::End {
            self.output.writeln("")?;
            self.output.writeln("")?
        } else {
            let heading_marker = "#".repeat(level as usize);
            let color = self.theme.heading_color(level);
            let mut marker_with_space = heading_marker;
            marker_with_space.push(' ');
            let marker = self.create_styled_marker(&marker_with_space, color, true);
            self.output.write(&marker)?;
        }
        Ok(())
    }

    fn render_paragraph(&mut self, phase: ElementPhase) -> Result<()> {
        if phase == ElementPhase::End {
            self.output.newline()?;
        }
        Ok(())
    }

    fn render_list_item(&mut self, phase: ElementPhase) -> Result<()> {
        if phase == ElementPhase::End {
            self.output.newline()?;
        } else {
            let depth = self.state.list_stack.len();
            let indent = self.config.create_indent(depth.saturating_sub(1));
            self.output.write(&indent)?;

            if let Some(list_type) = self.state.list_stack.last_mut() {
                let marker = match list_type {
                    ListType::Unordered => Cow::Borrowed("• "),
                    ListType::Ordered { current } => {
                        let mut m = current.to_string();
                        m.push_str(".  ");
                        *current += 1;
                        Cow::Owned(m)
                    }
                };
                let styled_marker =
                    self.create_styled_marker(&marker, self.theme.list_marker_color(), false);
                self.output.write(&styled_marker)?;
            }
        }
        Ok(())
    }

    fn render_blockquote(&mut self, phase: ElementPhase) -> Result<()> {
        if phase == ElementPhase::End {
            self.output.newline()?;
        } else {
            let marker = self.create_styled_marker("> ", self.theme.delimiter_color(), false);
            self.output.write(&marker)?;
        }
        Ok(())
    }

    fn render_table_element(&mut self, variant: &TableVariant) -> Result<()> {
        match variant {
            TableVariant::HeadStart => self.render_table_head_start(),
            TableVariant::HeadEnd => self.render_table_head_end()?,
            TableVariant::RowEnd => self.render_table_row_end()?,
        }
        Ok(())
    }

    fn render_table_head_start(&mut self) {
        if let Some(ref mut table) = self.get_table_mut() {
            table.is_header = true;
        }
    }

    fn render_table_head_end(&mut self) -> Result<()> {
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
        Ok(())
    }

    fn render_table_row_end(&mut self) -> Result<()> {
        if let Some(table) = self.get_table() {
            let current_row = table.current_row.clone();
            self.render_table_row(&current_row, false)?;
        }

        if let Some(ref mut table) = self.get_table_mut() {
            table.current_row.clear();
        }
        Ok(())
    }

    pub(super) fn render_code_block(&mut self, code_block: &CodeBlockState) -> Result<()> {
        self.render_code_fence(code_block.language.as_deref())?;
        self.render_code_content(&code_block.content)?;
        self.render_code_fence(None)?;
        Ok(())
    }

    pub(super) fn render_code_fence(&mut self, language: Option<&str>) -> Result<()> {
        let fence = self.create_code_fence(language);
        self.output.writeln(&fence)?;
        Ok(())
    }

    pub(super) fn create_code_fence(&self, language: Option<&str>) -> String {
        let fence = self.create_styled_marker("```", self.theme.delimiter_color(), false);
        if let Some(lang) = language {
            let lang_text = self.create_styled_marker(lang, self.theme.code_color(), false);
            let mut result = fence.into_owned();
            result.push_str(&lang_text);
            result
        } else {
            fence.into_owned()
        }
    }

    pub(super) fn render_code_content(&mut self, content: &str) -> Result<()> {
        // Collect styled lines first to avoid multiple borrows
        let styled_lines: Vec<String> = content
            .lines()
            .map(|line| self.create_styled_code_line(line))
            .collect();

        // Then write them all
        for styled_line in styled_lines {
            self.output.writeln(&styled_line)?;
        }
        Ok(())
    }

    pub(super) fn create_styled_code_line(&self, line: &str) -> String {
        self.apply_text_style(line, TextStyle::CodeBlock)
            .to_string()
    }

    pub fn render_table_row(&mut self, row: &[String], is_header: bool) -> Result<()> {
        // Pre-allocation reduces memory reallocations during string building,
        // improving performance for tables with many columns
        let estimated_size: usize = row.iter().map(|s| s.len() + 4).sum::<usize>() + 1;
        let mut output = String::with_capacity(estimated_size);
        output.push_str(self.config.table_separator);
        for cell in row {
            output.push(' ');
            if is_header {
                let styled = self.apply_text_style(cell, TextStyle::Heading(1));
                output.push_str(&styled.to_string());
            } else {
                output.push_str(cell);
            }
            output.push(' ');
            output.push_str(self.config.table_separator);
        }
        self.output.writeln(&output)?;
        Ok(())
    }

    pub fn render_table_separator(&mut self, alignments: &[Alignment]) -> Result<()> {
        // Each column needs up to 7 chars for alignment markers plus delimiters.
        // Pre-allocation avoids growth during string building
        let mut output = String::with_capacity(alignments.len() * 8 + 1);
        output.push_str(self.config.table_separator);
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
            output.push_str(self.config.table_separator);
        }
        self.output.writeln(&output)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        output::{ElementKind, ElementPhase, OutputType, TableVariant},
        renderer::{BufferedOutput, MarkdownRenderer},
    };
    use rstest::rstest;
    use std::io::Write;
    use std::sync::{Arc, Mutex};

    // Test-specific MockWriter implementation
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

    fn create_test_renderer() -> MarkdownRenderer<MockWriter> {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        let mock_writer = MockWriter::new_with_buffer(buffer);
        let output = BufferedOutput::new(mock_writer);
        MarkdownRenderer::with_output(output)
    }

    #[rstest]
    #[case(OutputType::Element { kind: ElementKind::Heading(1), phase: ElementPhase::Start })]
    #[case(OutputType::Element { kind: ElementKind::Heading(1), phase: ElementPhase::End })]
    #[case(OutputType::Element { kind: ElementKind::Heading(3), phase: ElementPhase::Start })]
    #[case(OutputType::Element { kind: ElementKind::Paragraph, phase: ElementPhase::End })]
    #[case(OutputType::Element { kind: ElementKind::BlockQuote, phase: ElementPhase::Start })]
    #[case(OutputType::Element { kind: ElementKind::BlockQuote, phase: ElementPhase::End })]
    fn test_print_output_element_types(#[case] output_type: OutputType) {
        let mut renderer = create_test_renderer();
        let result = renderer.print_output(output_type);
        assert!(result.is_ok());
    }

    #[rstest]
    #[case(OutputType::Element { kind: ElementKind::ListItem, phase: ElementPhase::Start }, None)]
    #[case(OutputType::Element { kind: ElementKind::ListItem, phase: ElementPhase::End }, None)]
    #[case(OutputType::Element { kind: ElementKind::ListItem, phase: ElementPhase::Start }, Some(1))]
    fn test_print_output_list_items(
        #[case] output_type: OutputType,
        #[case] list_start: Option<u64>,
    ) {
        let mut renderer = create_test_renderer();
        renderer.push_list(list_start);
        let result = renderer.print_output(output_type);
        assert!(result.is_ok());
        renderer.pop_list();
    }

    #[rstest]
    #[case(TableVariant::HeadStart)]
    #[case(TableVariant::HeadEnd)]
    #[case(TableVariant::RowEnd)]
    fn test_print_output_table_elements(#[case] variant: TableVariant) {
        let mut renderer = create_test_renderer();
        renderer.set_table(vec![]);

        // Add test data for HeadEnd and RowEnd cases
        if matches!(variant, TableVariant::HeadEnd | TableVariant::RowEnd)
            && let Some(table) = renderer.get_table_mut()
        {
            table.current_row.push("Cell1".to_string());
            table.current_row.push("Cell2".to_string());
        }

        let result = renderer.print_output(OutputType::Element {
            kind: ElementKind::Table(variant),
            phase: ElementPhase::Start,
        });
        assert!(result.is_ok());
    }

    #[rstest]
    #[case(OutputType::HorizontalRule)]
    #[case(OutputType::InlineCode { code: "test code".to_string() })]
    #[case(OutputType::TaskMarker { checked: true })]
    #[case(OutputType::TaskMarker { checked: false })]
    fn test_print_output_inline_types(#[case] output_type: OutputType) {
        let mut renderer = create_test_renderer();
        let result = renderer.print_output(output_type);
        assert!(result.is_ok());
    }

    #[test]
    fn test_print_output_link() {
        let mut renderer = create_test_renderer();
        renderer.set_link("https://example.com".to_string());
        if let Some(link) = renderer.get_link_mut() {
            link.text = "Example Link".to_string();
        }
        let result = renderer.print_output(OutputType::Link);
        assert!(result.is_ok());
    }

    #[test]
    fn test_print_output_image() {
        let mut renderer = create_test_renderer();
        renderer.set_image("https://example.com/image.jpg".to_string());
        if let Some(image) = renderer.get_image_mut() {
            image.alt_text = "Example Image".to_string();
        }
        let result = renderer.print_output(OutputType::Image);
        assert!(result.is_ok());
    }

    #[test]
    fn test_print_output_code_block() {
        let mut renderer = create_test_renderer();
        renderer.set_code_block(pulldown_cmark::CodeBlockKind::Fenced("rust".into()));
        if let Some(code) = renderer.get_code_block_mut() {
            code.content = "fn main() {}".to_string();
        }
        let result = renderer.print_output(OutputType::CodeBlock);
        assert!(result.is_ok());
    }

    #[rstest]
    #[case("# Heading 1\n## Heading 2", "headings")]
    #[case("- Item 1\n- Item 2\n1. Ordered item", "lists")]
    #[case("> This is a quote", "blockquote")]
    #[case("| Header |\n|--------|\n| Cell |", "table")]
    #[case("```rust\nfn main() {}\n```", "code_block")]
    #[case("**bold** *italic* `code`", "inline_elements")]
    #[case("[Link](https://example.com)", "link")]
    #[case("---", "horizontal_rule")]
    fn test_render_content_markdown_elements(#[case] markdown: &str, #[case] _description: &str) {
        let mut renderer = create_test_renderer();
        let result = renderer.render_content(markdown);
        assert!(result.is_ok(), "Failed to render {}", _description);
    }

    #[test]
    fn test_complex_markdown_rendering() {
        let mut renderer = create_test_renderer();

        let complex_markdown = r#"
# Main Title

This is a paragraph with **bold** and *italic* text.

## Lists

- Unordered item 1
- Unordered item 2
  - Nested item

1. Ordered item 1
2. Ordered item 2

## Code

```rust
fn hello() {
    println!("Hello, world!");
}
```

## Table

| Column 1 | Column 2 |
|----------|----------|
| Data 1   | Data 2   |

> A blockquote with multiple
> lines of text

---

[Link](https://example.com)
"#;

        let result = renderer.render_content(complex_markdown);
        assert!(result.is_ok());
    }

    #[rstest]
    #[case(1)]
    #[case(2)]
    #[case(3)]
    #[case(4)]
    #[case(5)]
    #[case(6)]
    fn test_heading_levels(#[case] level: u8) {
        let mut renderer = create_test_renderer();
        let markdown = format!("{} Heading Level {}", "#".repeat(level as usize), level);
        let result = renderer.render_content(&markdown);
        assert!(result.is_ok(), "Failed to render heading level {}", level);
    }

    #[rstest]
    #[case("- [ ] Unchecked task")]
    #[case("- [x] Checked task")]
    #[case("- [X] Also checked task")]
    fn test_task_lists(#[case] markdown: &str) {
        let mut renderer = create_test_renderer();
        let result = renderer.render_content(markdown);
        assert!(result.is_ok(), "Failed to render task list: {}", markdown);
    }
}
