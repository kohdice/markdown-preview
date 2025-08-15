use anyhow::Result;
use pulldown_cmark::{Event, Tag, TagEnd};

use super::{MarkdownRenderer, state::ContentType};
use crate::{
    html_entity::decode_html_entities,
    output::{ElementKind, ElementPhase, OutputType, TableVariant},
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
            Tag::Heading { level, .. } => {
                self.handle_element(ElementKind::Heading(level as u8), ElementPhase::Start)?
            }
            Tag::Paragraph => self.handle_element(ElementKind::Paragraph, ElementPhase::Start)?,
            Tag::Strong => self.set_strong_emphasis(true),
            Tag::Emphasis => self.set_italic_emphasis(true),
            Tag::Link { dest_url, .. } => self.set_link(dest_url.to_string()),
            Tag::List(start) => self.handle_list_start(start),
            Tag::Item => self.handle_element(ElementKind::ListItem, ElementPhase::Start)?,
            Tag::CodeBlock(kind) => self.handle_code_block_start(kind),
            Tag::Table(alignments) => self.set_table(alignments),
            Tag::TableHead => self.handle_element(
                ElementKind::Table(TableVariant::HeadStart),
                ElementPhase::Start,
            )?,
            Tag::BlockQuote(_) => {
                self.handle_element(ElementKind::BlockQuote, ElementPhase::Start)?
            }
            Tag::Image { dest_url, .. } => self.set_image(dest_url.to_string()),
            _ => {}
        }
        Ok(())
    }

    /// Handle closing tags to trigger rendering and cleanup
    fn handle_tag_end(&mut self, tag: Tag) -> Result<()> {
        match tag {
            Tag::Heading { .. } => {
                // Note: level is 0 for end tags in the original implementation
                self.handle_element(ElementKind::Heading(0), ElementPhase::End)?
            }
            Tag::Paragraph => self.handle_element(ElementKind::Paragraph, ElementPhase::End)?,
            Tag::Strong => self.set_strong_emphasis(false),
            Tag::Emphasis => self.set_italic_emphasis(false),
            Tag::Link { .. } => self.print_output(OutputType::Link)?,
            Tag::List(_) => self.handle_list_end(),
            Tag::Item => self.handle_element(ElementKind::ListItem, ElementPhase::End)?,
            Tag::CodeBlock(_) => self.print_output(OutputType::CodeBlock)?,
            Tag::Table(_) => self.handle_table_end(),
            Tag::TableHead => self.handle_element(
                ElementKind::Table(TableVariant::HeadEnd),
                ElementPhase::Start,
            )?,
            Tag::TableRow => self.handle_element(
                ElementKind::Table(TableVariant::RowEnd),
                ElementPhase::Start,
            )?,
            Tag::BlockQuote(_) => {
                self.handle_element(ElementKind::BlockQuote, ElementPhase::End)?
            }
            Tag::Image { .. } => self.print_output(OutputType::Image)?,
            _ => {}
        }
        Ok(())
    }

    // Unified element handler - replaces multiple duplicate methods
    fn handle_element(&mut self, kind: ElementKind, phase: ElementPhase) -> Result<()> {
        self.print_output(OutputType::Element { kind, phase })
    }

    // Special handlers for elements that require additional state management
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

    fn handle_table_end(&mut self) {
        self.clear_table();
        println!();
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
