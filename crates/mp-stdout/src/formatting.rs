use std::io::Write;

use anyhow::Result;
use pulldown_cmark::{Alignment, Event, Tag, TagEnd};

use mp_core::html_entity::decode_html_entities;
use mp_core::theme::MarkdownTheme;

use super::{
    MarkdownRenderer,
    state::{CodeBlockState, ContentType},
    styling::TextStyle,
};
use crate::output::{ElementKind, ElementPhase, OutputType, TableVariant};
use crate::theme_adapter::CrosstermAdapter;

impl<W: Write> MarkdownRenderer<W> {
    pub fn process_event(&mut self, event: Event) -> Result<()> {
        match event {
            Event::Start(tag) => self.handle_tag_start(tag),
            Event::End(tag_end) => self.handle_tag_end(tag_end),
            Event::Text(text) => self.handle_content(ContentType::Text(&text)),
            Event::Code(code) => self.handle_content(ContentType::Code(&code)),
            Event::Html(html) => self.handle_content(ContentType::Html(&html)),
            Event::SoftBreak => self.handle_content(ContentType::SoftBreak),
            Event::HardBreak => self.handle_content(ContentType::HardBreak),
            Event::Rule => self.handle_content(ContentType::Rule),
            Event::TaskListMarker(checked) => self.handle_content(ContentType::TaskMarker(checked)),
            Event::FootnoteReference(label) => {
                let footnote_text = format!("[^{}]", label.as_ref());
                self.handle_content(ContentType::Text(&footnote_text))
            }
            _ => Ok(()),
        }
    }

    fn handle_tag_start(&mut self, tag: Tag) -> Result<()> {
        match tag {
            Tag::Heading { level, .. } => {
                self.handle_element(ElementKind::Heading(level as u8), ElementPhase::Start)?
            }
            Tag::Paragraph => self.handle_element(ElementKind::Paragraph, ElementPhase::Start)?,
            Tag::Strong => self.set_strong_emphasis(true),
            Tag::Emphasis => self.set_italic_emphasis(true),
            Tag::Link { dest_url, .. } => self.set_link(dest_url.as_ref().to_owned()),
            Tag::List(start) => self.handle_list_start(start),
            Tag::Item => self.handle_element(ElementKind::ListItem, ElementPhase::Start)?,
            Tag::CodeBlock(kind) => self.handle_code_block_start(kind),
            Tag::Table(alignments) => self.set_table(alignments),
            Tag::TableHead => self.handle_element(
                ElementKind::Table(TableVariant::HeadStart),
                ElementPhase::Start,
            )?,
            Tag::TableRow => {
                if let Some(table) = self.get_table_mut() {
                    table.current_row.clear();
                }
            }
            Tag::TableCell => {
                if let Some(table) = self.get_table_mut() {
                    table.current_row.push(String::new());
                }
            }
            Tag::BlockQuote(_) => {
                self.handle_element(ElementKind::BlockQuote, ElementPhase::Start)?
            }
            Tag::Image { dest_url, .. } => self.set_image(dest_url.as_ref().to_owned()),
            Tag::FootnoteDefinition(label) => {
                self.output.newline().ok();
                self.output.write(&format!("[{}]: ", label.as_ref())).ok();
            }
            _ => {}
        }
        Ok(())
    }

    fn handle_tag_end(&mut self, tag_end: TagEnd) -> Result<()> {
        match tag_end {
            TagEnd::Heading(_) => {
                self.handle_element(ElementKind::Heading(0), ElementPhase::End)?
            }
            TagEnd::Paragraph => self.handle_element(ElementKind::Paragraph, ElementPhase::End)?,
            TagEnd::Strong => self.set_strong_emphasis(false),
            TagEnd::Emphasis => self.set_italic_emphasis(false),
            TagEnd::Link => self.print_output(OutputType::Link)?,
            TagEnd::List(_) => self.handle_list_end(),
            TagEnd::Item => self.handle_element(ElementKind::ListItem, ElementPhase::End)?,
            TagEnd::CodeBlock => self.print_output(OutputType::CodeBlock)?,
            TagEnd::Table => self.handle_table_end(),
            TagEnd::TableHead => self.handle_element(
                ElementKind::Table(TableVariant::HeadEnd),
                ElementPhase::Start,
            )?,
            TagEnd::TableRow => self.handle_element(
                ElementKind::Table(TableVariant::RowEnd),
                ElementPhase::Start,
            )?,
            TagEnd::TableCell => {}
            TagEnd::BlockQuote(_) => {
                self.handle_element(ElementKind::BlockQuote, ElementPhase::End)?
            }
            TagEnd::Image => self.print_output(OutputType::Image)?,
            TagEnd::FootnoteDefinition => {
                self.output.newline().ok();
            }
            _ => {}
        }
        Ok(())
    }

    fn handle_element(&mut self, kind: ElementKind, phase: ElementPhase) -> Result<()> {
        self.print_output(OutputType::Element { kind, phase })
    }

    fn handle_list_start(&mut self, start: Option<u64>) {
        if !self.state.list_stack.is_empty() {
            self.output.newline().ok();
        }
        self.push_list(start);
    }

    fn handle_list_end(&mut self) {
        self.pop_list();
        if self.state.list_stack.is_empty() {
            self.output.newline().ok();
        }
    }

    fn handle_code_block_start(&mut self, kind: pulldown_cmark::CodeBlockKind) {
        let static_kind = match kind {
            pulldown_cmark::CodeBlockKind::Indented => pulldown_cmark::CodeBlockKind::Indented,
            pulldown_cmark::CodeBlockKind::Fenced(lang) => {
                pulldown_cmark::CodeBlockKind::Fenced(lang.to_string().into())
            }
        };
        self.set_code_block(static_kind);
    }

    fn handle_table_end(&mut self) {
        if let Some(table) = self.get_table() {
            self.render_formatted_table(&table).ok();
        }
        self.clear_table();
        self.output.newline().ok();
    }

    pub(super) fn handle_content(&mut self, content: ContentType) -> Result<()> {
        match content {
            ContentType::Text(text) => self.handle_text_content(text),
            ContentType::Code(code) => self.handle_code_content(code),
            ContentType::Html(html) => self.handle_html_content(html),
            ContentType::SoftBreak => self.handle_soft_break(),
            ContentType::HardBreak => self.handle_hard_break(),
            ContentType::Rule => self.handle_rule(),
            ContentType::TaskMarker(checked) => self.handle_task_marker(checked),
        }
    }

    fn handle_text_content(&mut self, text: &str) -> Result<()> {
        let decoded_text = decode_html_entities(text);
        if !self.add_text_to_state(&decoded_text) {
            self.render_styled_text(&decoded_text);
        }
        Ok(())
    }

    fn handle_code_content(&mut self, code: &str) -> Result<()> {
        if let Some(ref mut cb) = self.get_code_block_mut() {
            cb.content.push_str(code);
        } else if !self.add_text_to_state(&format!("`{}`", code)) {
            self.print_output(OutputType::InlineCode {
                code: code.to_string(),
            })?;
        }
        Ok(())
    }

    fn handle_html_content(&mut self, html: &str) -> Result<()> {
        let decoded = decode_html_entities(html);
        if !self.add_text_to_state(&decoded) {
            self.render_styled_text(&decoded);
        }
        Ok(())
    }

    fn handle_soft_break(&mut self) -> Result<()> {
        self.output.write(" ")?;
        Ok(())
    }

    fn handle_hard_break(&mut self) -> Result<()> {
        self.output.newline()?;
        Ok(())
    }

    fn handle_rule(&mut self) -> Result<()> {
        self.render_horizontal_rule()
    }

    fn handle_task_marker(&mut self, checked: bool) -> Result<()> {
        self.print_output(OutputType::TaskMarker { checked })
    }

    pub fn print_output(&mut self, output_type: OutputType) -> Result<()> {
        match output_type {
            OutputType::Element { kind, phase } => self.handle_element_output(kind, phase),
            OutputType::HorizontalRule => self.render_horizontal_rule(),
            OutputType::InlineCode { ref code } => self.render_inline_code(code),
            OutputType::TaskMarker { checked } => self.render_task_marker(checked),
            OutputType::Link => self.render_link(),
            OutputType::Image => self.render_image(),
            OutputType::CodeBlock => self.render_code_block_output(),
        }
    }

    fn render_horizontal_rule(&mut self) -> Result<()> {
        let line = self.config.create_horizontal_rule();
        let styled_line = format!("{}", self.apply_text_style(&line, TextStyle::Delimiter));
        self.output.writeln("")?;
        self.output.writeln(&styled_line)?;
        self.output.writeln("")?;
        Ok(())
    }

    fn render_inline_code(&mut self, code: &str) -> Result<()> {
        let styled_code = format!("{}", self.apply_text_style(code, TextStyle::CodeBlock));
        self.output.write(&styled_code)?;
        Ok(())
    }

    fn render_task_marker(&mut self, checked: bool) -> Result<()> {
        let marker = if checked { "[x] " } else { "[ ] " };
        let list_marker_style = self.theme.list_marker_style();
        let styled_marker =
            self.create_styled_marker(marker, list_marker_style.color.to_crossterm_color(), false);
        self.output.write(&styled_marker)?;
        Ok(())
    }

    fn render_link(&mut self) -> Result<()> {
        if let Some(link) = self.get_link() {
            if !link.text.is_empty() {
                let hyperlink = format!("\x1b]8;;{}\x1b\\{}\x1b]8;;\x1b\\", link.url, link.text);
                self.output.write(&hyperlink)?;
            } else {
                let link_style = self.theme.link_style();
                let styled_url = self.create_styled_text(
                    &link.url,
                    link_style.color.to_crossterm_color(),
                    false,
                    false,
                    link_style.underline,
                );
                self.output.write(&styled_url)?;
            }
        }
        self.clear_link();
        Ok(())
    }

    fn render_image(&mut self) -> Result<()> {
        if let Some(image) = self.get_image() {
            let display_text = if !image.alt_text.is_empty() {
                format!("[{}]", image.alt_text)
            } else {
                "[Image]".to_string()
            };

            let image_style = self.theme.link_style();
            let styled_text = self.create_styled_text(
                &display_text,
                image_style.color.to_crossterm_color(),
                false,
                false,
                false,
            );
            self.output.write(&styled_text)?;

            let styled_url = self.create_styled_text(
                &format!(" ({})", image.url),
                crossterm::style::Color::Rgb {
                    r: 133,
                    g: 153,
                    b: 0,
                },
                false,
                true,
                false,
            );
            self.output.write(&styled_url)?;
        }
        self.clear_image();
        Ok(())
    }

    fn render_code_block_output(&mut self) -> Result<()> {
        if let Some(code_block) = self.get_code_block() {
            self.clear_code_block();
            self.render_code_block(&code_block)?;
        }
        Ok(())
    }

    fn handle_element_output(&mut self, kind: ElementKind, phase: ElementPhase) -> Result<()> {
        match (kind, phase) {
            (ElementKind::Heading(level), ElementPhase::Start) => {
                self.render_heading_start(level)?
            }
            (ElementKind::Heading(_), ElementPhase::End) => self.render_heading_end()?,
            (ElementKind::Paragraph, ElementPhase::Start) => {}
            (ElementKind::Paragraph, ElementPhase::End) => self.output.newline()?,
            (ElementKind::ListItem, ElementPhase::Start) => self.render_list_item()?,
            (ElementKind::ListItem, ElementPhase::End) => {}
            (ElementKind::BlockQuote, ElementPhase::Start) => self.render_blockquote_start()?,
            (ElementKind::BlockQuote, ElementPhase::End) => self.output.newline()?,
            (ElementKind::Table(variant), ElementPhase::Start) => {
                self.handle_table_variant(variant)?
            }
            _ => {}
        }
        Ok(())
    }

    fn render_heading_start(&mut self, level: u8) -> Result<()> {
        let heading_style = self.theme.heading_style(level);
        let prefix = "#".repeat(level as usize);
        let styled_prefix = self.create_styled_text(
            &prefix,
            heading_style.color.to_crossterm_color(),
            heading_style.bold,
            false,
            heading_style.underline,
        );
        self.output.write(&styled_prefix)?;
        self.output.write(" ")?;
        Ok(())
    }

    fn render_heading_end(&mut self) -> Result<()> {
        self.output.newline()?;
        self.output.newline()?;
        Ok(())
    }

    fn render_list_item(&mut self) -> Result<()> {
        let indent_level = self.state.list_stack.len().saturating_sub(1);
        let indent = self.config.create_indent(indent_level);
        self.output.write(&indent)?;

        let marker = match self.state.list_stack.last_mut() {
            Some(crate::state::ListType::Unordered) => "- ".to_string(),
            Some(crate::state::ListType::Ordered { current }) => {
                let marker = format!("{}. ", current);
                *current += 1;
                marker
            }
            None => String::new(),
        };

        if !marker.is_empty() {
            let list_marker_style = self.theme.list_marker_style();
            let styled_marker = self.create_styled_marker(
                &marker,
                list_marker_style.color.to_crossterm_color(),
                list_marker_style.bold,
            );
            self.output.write(&styled_marker)?;
        }
        Ok(())
    }

    fn render_blockquote_start(&mut self) -> Result<()> {
        let quote_style = self.theme.code_style();
        let styled_marker = self.create_styled_text(
            "> ",
            quote_style.color.to_crossterm_color(),
            quote_style.bold,
            quote_style.italic,
            false,
        );
        self.output.write(&styled_marker)?;
        Ok(())
    }

    fn handle_table_variant(&mut self, variant: TableVariant) -> Result<()> {
        match variant {
            TableVariant::HeadStart => {}
            TableVariant::HeadEnd => {
                if let Some(table) = self.get_table_mut() {
                    table.headers = table.current_row.clone();
                    table.current_row.clear();
                    table.is_header = false;
                }
            }
            TableVariant::RowEnd => {
                if let Some(table) = self.get_table_mut()
                    && !table.current_row.is_empty()
                {
                    table.rows.push(table.current_row.clone());
                    table.current_row.clear();
                }
            }
        }
        Ok(())
    }

    pub(super) fn render_code_content(&mut self, content: &str) -> Result<()> {
        let styled_lines: Vec<String> = content
            .lines()
            .map(|line| self.create_styled_code_line(line))
            .collect();

        for styled_line in styled_lines {
            self.output.writeln(&styled_line)?;
        }
        Ok(())
    }

    pub(super) fn render_code_block(&mut self, code_block: &CodeBlockState) -> Result<()> {
        let fence = self.create_code_fence(code_block.language.as_deref());
        let code_style = self.theme.code_style();
        let styled_fence = self.create_styled_text(
            &fence,
            code_style.color.to_crossterm_color(),
            false,
            false,
            false,
        );

        self.output.newline()?;
        self.output.writeln(&styled_fence)?;
        self.render_code_content(&code_block.content)?;
        self.output.writeln(&styled_fence)?;
        self.output.newline()?;
        Ok(())
    }

    fn render_formatted_table(&mut self, table: &crate::state::TableState) -> Result<()> {
        let mut column_widths = vec![0; table.alignments.len()];

        for (i, header) in table.headers.iter().enumerate() {
            if i < column_widths.len() {
                column_widths[i] = column_widths[i].max(header.len());
            }
        }

        for row in &table.rows {
            for (i, cell) in row.iter().enumerate() {
                if i < column_widths.len() {
                    column_widths[i] = column_widths[i].max(cell.len());
                }
            }
        }

        if !table.headers.is_empty() {
            let mut output = String::new();
            output.push_str(self.config.table_separator);
            for (i, header) in table.headers.iter().enumerate() {
                let width = column_widths.get(i).copied().unwrap_or(0);
                output.push(' ');
                output.push_str(&format!("{:<width$}", header, width = width));
                output.push(' ');
                output.push_str(self.config.table_separator);
            }
            self.output.writeln(&output)?;

            let mut sep_output = String::new();
            sep_output.push_str(self.config.table_separator);
            for (i, alignment) in table.alignments.iter().enumerate() {
                let width = column_widths.get(i).copied().unwrap_or(3).max(3);
                let separator = match alignment {
                    Alignment::Left => format!(":{}", "-".repeat(width - 1)),
                    Alignment::Center => format!(":{}:", "-".repeat(width - 2)),
                    Alignment::Right => format!("{}:", "-".repeat(width - 1)),
                    Alignment::None => "-".repeat(width),
                };
                sep_output.push(' ');
                sep_output.push_str(&separator);
                sep_output.push(' ');
                sep_output.push_str(self.config.table_separator);
            }
            self.output.writeln(&sep_output)?;
        }

        for row in &table.rows {
            let mut output = String::new();
            output.push_str(self.config.table_separator);
            for (i, cell) in row.iter().enumerate() {
                let width = column_widths.get(i).copied().unwrap_or(0);
                let alignment = table.alignments.get(i).unwrap_or(&Alignment::None);
                let formatted_cell = match alignment {
                    Alignment::Left | Alignment::None => format!("{:<width$}", cell, width = width),
                    Alignment::Center => format!("{:^width$}", cell, width = width),
                    Alignment::Right => format!("{:>width$}", cell, width = width),
                };
                output.push(' ');
                output.push_str(&formatted_cell);
                output.push(' ');
                output.push_str(self.config.table_separator);
            }
            self.output.writeln(&output)?;
        }

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        MarkdownRenderer,
        buffered_output::BufferedOutput,
        output::{ElementKind, OutputType},
        state::ActiveElement,
    };
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

    fn create_renderer() -> MarkdownRenderer<MockWriter> {
        let buffer = Arc::new(Mutex::new(Vec::with_capacity(1024)));
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
        let mut renderer = create_renderer();
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
        let mut renderer = create_renderer();
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
        let mut renderer = create_renderer();
        renderer.set_table(vec![]);

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
        let mut renderer = create_renderer();
        let result = renderer.print_output(output_type);
        assert!(result.is_ok());
    }

    #[test]
    fn test_print_output_link() {
        let mut renderer = create_renderer();
        renderer.set_link("https://example.com".to_string());
        if let Some(link) = renderer.get_link_mut() {
            link.text = "Example Link".to_string();
        }
        let result = renderer.print_output(OutputType::Link);
        assert!(result.is_ok());
        assert!(!renderer.has_link());
    }

    #[test]
    fn test_print_output_image() {
        let mut renderer = create_renderer();
        renderer.set_image("https://example.com/image.png".to_string());
        if let Some(image) = renderer.get_image_mut() {
            image.alt_text = "Example Image".to_string();
        }
        let result = renderer.print_output(OutputType::Image);
        assert!(result.is_ok());
        assert!(renderer.get_image().is_none());
    }

    #[test]
    fn test_print_output_code_block() {
        let mut renderer = create_renderer();
        renderer.set_code_block(pulldown_cmark::CodeBlockKind::Fenced("rust".into()));
        if let Some(cb) = renderer.get_code_block_mut() {
            cb.content = "fn main() {\n    println!(\"Hello\");\n}".to_string();
        }
        assert!(renderer.print_output(OutputType::CodeBlock).is_ok());
        assert!(renderer.get_code_block().is_none());
    }

    #[test]
    fn test_handle_content_text() {
        let mut renderer = create_renderer();
        renderer.set_link("".to_string());
        assert!(
            renderer
                .handle_content(ContentType::Text("test text"))
                .is_ok()
        );
        assert_eq!(renderer.get_link().unwrap().text, "test text");
    }

    #[test]
    fn test_handle_content_code() {
        let mut renderer = create_renderer();
        renderer.set_code_block(pulldown_cmark::CodeBlockKind::Indented);
        assert!(
            renderer
                .handle_content(ContentType::Code("let x = 5;"))
                .is_ok()
        );
        assert_eq!(renderer.get_code_block().unwrap().content, "let x = 5;");
    }

    #[test]
    fn test_nested_lists() {
        let mut renderer = create_renderer();
        renderer.push_list(None);
        renderer.push_list(Some(1));
        assert_eq!(renderer.state.list_stack.len(), 2);

        let result = renderer.print_output(OutputType::Element {
            kind: ElementKind::ListItem,
            phase: ElementPhase::Start,
        });
        assert!(result.is_ok());

        renderer.pop_list();
        renderer.pop_list();
        assert!(renderer.state.list_stack.is_empty());
    }

    #[test]
    fn test_table_with_alignments() {
        let mut renderer = create_renderer();
        let alignments = vec![
            Alignment::Left,
            Alignment::Center,
            Alignment::Right,
            Alignment::None,
        ];
        renderer.set_table(alignments.clone());

        let table = renderer.get_table();
        assert!(table.is_some());
        let table = table.unwrap();
        assert_eq!(table.alignments, alignments);
        assert!(table.is_header);
    }

    #[test]
    fn test_emphasis_states() {
        let mut renderer = create_renderer();
        renderer.set_strong_emphasis(true);
        assert!(renderer.state.emphasis.strong);

        renderer.set_italic_emphasis(true);
        assert!(renderer.state.emphasis.italic);

        renderer.set_strong_emphasis(false);
        assert!(!renderer.state.emphasis.strong);
        assert!(renderer.state.emphasis.italic);
    }

    #[test]
    fn test_active_element_transitions() {
        let mut renderer = create_renderer();

        renderer.set_link("url1".to_string());
        assert!(matches!(
            renderer.state.active_element,
            Some(ActiveElement::Link(_))
        ));

        renderer.set_image("url2".to_string());
        assert!(matches!(
            renderer.state.active_element,
            Some(ActiveElement::Image(_))
        ));

        renderer.clear_active_element();
        assert!(renderer.state.active_element.is_none());
    }
}
