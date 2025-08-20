use std::io::Write;

use anyhow::Result;
use pulldown_cmark::{Event, Tag, TagEnd};

use mp_core::html_entity::decode_html_entities;

use super::{MarkdownRenderer, state::ContentType};
use crate::output::{ElementKind, ElementPhase, OutputType, TableVariant};

impl<W: Write> MarkdownRenderer<W> {
    fn tag_end_to_tag(tag_end: TagEnd) -> Option<Tag<'static>> {
        match tag_end {
            TagEnd::Heading(level) => Some(Tag::Heading {
                level,
                id: None,
                classes: vec![],
                attrs: vec![],
            }),
            TagEnd::Paragraph => Some(Tag::Paragraph),
            TagEnd::Strong => Some(Tag::Strong),
            TagEnd::Emphasis => Some(Tag::Emphasis),
            TagEnd::Link => Some(Tag::Link {
                link_type: pulldown_cmark::LinkType::Inline,
                dest_url: "".into(),
                title: "".into(),
                id: "".into(),
            }),
            TagEnd::List(_) => Some(Tag::List(None)),
            TagEnd::Item => Some(Tag::Item),
            TagEnd::CodeBlock => Some(Tag::CodeBlock(pulldown_cmark::CodeBlockKind::Indented)),
            TagEnd::Table => Some(Tag::Table(vec![])),
            TagEnd::TableHead => Some(Tag::TableHead),
            TagEnd::TableRow => Some(Tag::TableRow),
            TagEnd::BlockQuote(_) => Some(Tag::BlockQuote(None)),
            TagEnd::Image => Some(Tag::Image {
                link_type: pulldown_cmark::LinkType::Inline,
                dest_url: "".into(),
                title: "".into(),
                id: "".into(),
            }),
            _ => None,
        }
    }

    pub fn process_event(&mut self, event: Event) -> Result<()> {
        match event {
            Event::Start(tag) => self.handle_tag(tag, true),
            Event::End(tag_end) => {
                if let Some(tag) = Self::tag_end_to_tag(tag_end) {
                    self.handle_tag(tag, false)
                } else {
                    Ok(())
                }
            }
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

    pub(super) fn handle_tag(&mut self, tag: Tag, is_start: bool) -> Result<()> {
        if is_start {
            self.handle_tag_start(tag)
        } else {
            self.handle_tag_end(tag)
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

    fn handle_tag_end(&mut self, tag: Tag) -> Result<()> {
        match tag {
            Tag::Heading { .. } => {
                self.handle_element(ElementKind::Heading(0), ElementPhase::End)?
            }
            Tag::Paragraph => self.handle_element(ElementKind::Paragraph, ElementPhase::End)?,
            Tag::Strong => self.set_strong_emphasis(false),
            Tag::Emphasis => self.set_italic_emphasis(false),
            Tag::Link { .. } => self.print_output(OutputType::Link)?,
            Tag::List(_) => self.handle_list_end(),
            Tag::Item => self.handle_element(ElementKind::ListItem, ElementPhase::End)?,
            Tag::CodeBlock(_) => self.print_output(OutputType::CodeBlock)?,
            Tag::Table(_) => {
                self.handle_table_end();
            }
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
        self.clear_table();
        self.output.newline().ok();
    }

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
                self.output.write(" ")?;
            }
            ContentType::HardBreak => {
                self.output.newline()?;
            }
            ContentType::Rule => {
                let line = self.config.create_horizontal_rule();
                let styled_line = format!(
                    "{}",
                    self.apply_text_style(&line, super::styling::TextStyle::Delimiter)
                );
                self.output.writeln("")?;
                self.output.writeln(&styled_line)?;
                self.output.writeln("")?;
            }
            ContentType::TaskMarker(checked) => {
                self.print_output(OutputType::TaskMarker { checked })?;
            }
        }
        Ok(())
    }
}
