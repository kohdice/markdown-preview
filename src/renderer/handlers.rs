use anyhow::Result;
use pulldown_cmark::{Event, Tag, TagEnd};

use super::{MarkdownRenderer, state::ContentType};
use crate::{
    html_entity::decode_html_entities,
    output::{OutputType, TableVariant},
};

impl MarkdownRenderer {
    /// Process pulldown_cmark events and route them to appropriate handlers.
    /// Converts Tag events to handle_tag and content events to handle_content.
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

    /// Process opening and closing tags to manage state transitions and output.
    /// Opening tags set up state, closing tags trigger rendering and cleanup.
    pub(super) fn handle_tag(&mut self, tag: Tag, is_start: bool) -> Result<()> {
        if is_start {
            self.handle_tag_start(tag)
        } else {
            self.handle_tag_end(tag)
        }
    }

    /// Handle opening tags to set up state for element processing
    fn handle_tag_start(&mut self, tag: Tag) -> Result<()> {
        match tag {
            Tag::Heading { level, .. } => self.handle_heading_start(level as u8)?,
            Tag::Paragraph => self.handle_paragraph_start()?,
            Tag::Strong => self.set_strong_emphasis(true),
            Tag::Emphasis => self.set_italic_emphasis(true),
            Tag::Link { dest_url, .. } => self.set_link(dest_url.to_string()),
            Tag::List(start) => self.handle_list_start(start),
            Tag::Item => self.handle_list_item_start()?,
            Tag::CodeBlock(kind) => self.handle_code_block_start(kind),
            Tag::Table(alignments) => self.set_table(alignments),
            Tag::TableHead => self.handle_table_head_start()?,
            Tag::BlockQuote(_) => self.handle_block_quote_start()?,
            Tag::Image { dest_url, .. } => self.set_image(dest_url.to_string()),
            _ => {}
        }
        Ok(())
    }

    /// Handle closing tags to trigger rendering and cleanup
    fn handle_tag_end(&mut self, tag: Tag) -> Result<()> {
        match tag {
            Tag::Heading { .. } => self.handle_heading_end()?,
            Tag::Paragraph => self.handle_paragraph_end()?,
            Tag::Strong => self.set_strong_emphasis(false),
            Tag::Emphasis => self.set_italic_emphasis(false),
            Tag::Link { .. } => self.handle_link_end()?,
            Tag::List(_) => self.handle_list_end(),
            Tag::Item => self.handle_list_item_end()?,
            Tag::CodeBlock(_) => self.print_output(OutputType::CodeBlock)?,
            Tag::Table(_) => self.handle_table_end(),
            Tag::TableHead => self.handle_table_head_end()?,
            Tag::TableRow => self.handle_table_row_end()?,
            Tag::BlockQuote(_) => self.handle_block_quote_end()?,
            Tag::Image { .. } => self.handle_image_end()?,
            _ => {}
        }
        Ok(())
    }

    // Helper methods for handling specific tag types
    fn handle_heading_start(&mut self, level: u8) -> Result<()> {
        self.print_output(OutputType::Heading {
            level,
            is_end: false,
        })
    }

    fn handle_heading_end(&mut self) -> Result<()> {
        self.print_output(OutputType::Heading {
            level: 0,
            is_end: true,
        })
    }

    fn handle_paragraph_start(&mut self) -> Result<()> {
        self.print_output(OutputType::Paragraph { is_end: false })
    }

    fn handle_paragraph_end(&mut self) -> Result<()> {
        self.print_output(OutputType::Paragraph { is_end: true })
    }

    fn handle_list_start(&mut self, start: Option<u64>) {
        // Nested lists need visual separation from their parent list items
        // to maintain readability in terminal output
        if !self.state.list_stack.is_empty() {
            println!();
        }
        self.push_list(start);
    }

    fn handle_list_end(&mut self) {
        self.pop_list();
        if self.state.list_stack.is_empty() {
            println!();
        }
    }

    fn handle_list_item_start(&mut self) -> Result<()> {
        self.print_output(OutputType::ListItem { is_end: false })
    }

    fn handle_list_item_end(&mut self) -> Result<()> {
        self.print_output(OutputType::ListItem { is_end: true })
    }

    fn handle_code_block_start(&mut self, kind: pulldown_cmark::CodeBlockKind) {
        // Convert borrowed language string to owned for state storage.
        // Required because state outlives the parsing event lifetime
        let static_kind = match kind {
            pulldown_cmark::CodeBlockKind::Indented => pulldown_cmark::CodeBlockKind::Indented,
            pulldown_cmark::CodeBlockKind::Fenced(lang) => {
                pulldown_cmark::CodeBlockKind::Fenced(lang.to_string().into())
            }
        };
        self.set_code_block(static_kind);
    }

    fn handle_table_head_start(&mut self) -> Result<()> {
        self.print_output(OutputType::Table {
            variant: TableVariant::HeadStart,
        })
    }

    fn handle_table_head_end(&mut self) -> Result<()> {
        self.print_output(OutputType::Table {
            variant: TableVariant::HeadEnd,
        })
    }

    fn handle_table_row_end(&mut self) -> Result<()> {
        self.print_output(OutputType::Table {
            variant: TableVariant::RowEnd,
        })
    }

    fn handle_table_end(&mut self) {
        self.clear_table();
        println!();
    }

    fn handle_block_quote_start(&mut self) -> Result<()> {
        self.print_output(OutputType::BlockQuote { is_end: false })
    }

    fn handle_block_quote_end(&mut self) -> Result<()> {
        self.print_output(OutputType::BlockQuote { is_end: true })
    }

    fn handle_link_end(&mut self) -> Result<()> {
        self.print_output(OutputType::Link)
    }

    fn handle_image_end(&mut self) -> Result<()> {
        self.print_output(OutputType::Image)
    }

    /// Process content events including text, code, HTML, and breaks.
    /// Routes content to active elements or renders directly based on state.
    pub(super) fn handle_content(&mut self, content: ContentType) -> Result<()> {
        match content {
            ContentType::Text(text) => {
                let decoded_text = decode_html_entities(text);
                if !self.add_text_to_state(&decoded_text) {
                    self.render_styled_text(&decoded_text);
                }
            }
            ContentType::Code(code) => {
                if let Some(ref mut cb) = self.get_code_block_mut() {
                    cb.content.push_str(code);
                } else {
                    self.print_output(OutputType::InlineCode {
                        code: code.to_string(),
                    })?;
                }
            }
            ContentType::Html(html) => {
                let decoded = decode_html_entities(html);
                if !self.add_text_to_state(&decoded) {
                    self.render_styled_text(&decoded);
                }
            }
            ContentType::SoftBreak => {
                print!(" ");
            }
            ContentType::HardBreak => {
                println!();
            }
            ContentType::Rule => {
                let line = self.config.create_horizontal_rule();
                let styled_line =
                    self.apply_text_style(&line, super::styling::TextStyle::Delimiter);
                println!("\n{}\n", styled_line);
            }
            ContentType::TaskMarker(checked) => {
                self.print_output(OutputType::TaskMarker { checked })?;
            }
        }
        Ok(())
    }
}
