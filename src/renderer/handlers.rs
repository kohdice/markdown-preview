use anyhow::Result;
use pulldown_cmark::{Event, Tag, TagEnd};

use super::markdown::MarkdownRenderer;
use super::terminal::{OutputType, StateOperation, TableVariant, TerminalRenderer};
use crate::html_entity::decode_html_entities;

/// Unified event handler trait
/// Handles all Markdown event processing uniformly
pub trait EventHandler {
    /// Main method for processing events
    fn process_event(&mut self, event: Event) -> Result<()>;

    /// Handle tag start and end
    fn handle_tag(&mut self, tag: Tag, is_start: bool) -> Result<()>;

    /// Handle text-related events
    fn handle_content(&mut self, content: ContentType) -> Result<()>;
}

/// Text content types
pub enum ContentType<'a> {
    Text(&'a str),
    Code(&'a str),
    Html(&'a str),
    SoftBreak,
    HardBreak,
    Rule,
    TaskMarker(bool),
}

impl EventHandler for MarkdownRenderer {
    fn process_event(&mut self, event: Event) -> Result<()> {
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
                Tag::Strong => self.apply_state(StateOperation::SetStrong(true)),
                Tag::Emphasis => self.apply_state(StateOperation::SetEmphasis(true)),
                Tag::Link { dest_url, .. } => {
                    self.apply_state(StateOperation::SetLink(dest_url.to_string()));
                }
                Tag::List(start) => self.apply_state(StateOperation::PushList(start)),
                Tag::Item => {
                    let _ = self.print_output(OutputType::ListItem { is_end: false });
                }
                Tag::CodeBlock(kind) => self.apply_state(StateOperation::SetCodeBlock(kind)),
                Tag::Table(alignments) => {
                    self.apply_state(StateOperation::SetTable(alignments));
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
                    self.apply_state(StateOperation::SetImage(dest_url.to_string()));
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
                Tag::Strong => self.apply_state(StateOperation::SetStrong(false)),
                Tag::Emphasis => self.apply_state(StateOperation::SetEmphasis(false)),
                Tag::Link { .. } => {
                    let _ = self.print_output(OutputType::Link);
                }
                Tag::List(_) => self.apply_state(StateOperation::PopList),
                Tag::Item => {
                    let _ = self.print_output(OutputType::ListItem { is_end: true });
                }
                Tag::CodeBlock(_) => self.print_output(OutputType::CodeBlock)?,
                Tag::Table(_) => self.apply_state(StateOperation::ClearTable),
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

    fn handle_content(&mut self, content: ContentType) -> Result<()> {
        match content {
            ContentType::Text(text) => {
                let decoded_text = decode_html_entities(text);
                if !self.base.add_text_to_state(&decoded_text) {
                    self.base.render_styled_text(&decoded_text);
                }
            }
            ContentType::Code(code) => {
                if !self.base.add_text_to_state(code) {
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
}
