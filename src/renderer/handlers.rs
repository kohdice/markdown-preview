use anyhow::Result;
use pulldown_cmark::{Event, Tag, TagEnd};

use super::{MarkdownRenderer, state::ContentType};
use crate::{
    html_entity::decode_html_entities,
    output::{OutputType, TableVariant},
};

impl MarkdownRenderer {
    /// Main method for processing events
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

    /// Handle tag start and end
    pub(super) fn handle_tag(&mut self, tag: Tag, is_start: bool) -> Result<()> {
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
                Tag::Strong => self.set_strong_emphasis(true),
                Tag::Emphasis => self.set_italic_emphasis(true),
                Tag::Link { dest_url, .. } => {
                    self.set_link(dest_url.to_string());
                }
                Tag::List(start) => {
                    // Add newline before nested list if we're already in a list
                    if !self.state.list_stack.is_empty() {
                        println!();
                    }
                    self.push_list(start);
                }
                Tag::Item => {
                    let _ = self.print_output(OutputType::ListItem { is_end: false });
                }
                Tag::CodeBlock(kind) => {
                    // Convert lifetime to 'static for state management
                    let static_kind = match kind {
                        pulldown_cmark::CodeBlockKind::Indented => {
                            pulldown_cmark::CodeBlockKind::Indented
                        }
                        pulldown_cmark::CodeBlockKind::Fenced(lang) => {
                            pulldown_cmark::CodeBlockKind::Fenced(lang.to_string().into())
                        }
                    };
                    self.set_code_block(static_kind);
                }
                Tag::Table(alignments) => {
                    self.set_table(alignments);
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
                    self.set_image(dest_url.to_string());
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
                Tag::Strong => self.set_strong_emphasis(false),
                Tag::Emphasis => self.set_italic_emphasis(false),
                Tag::Link { .. } => {
                    let _ = self.print_output(OutputType::Link);
                }
                Tag::List(_) => {
                    self.pop_list();
                    if self.state.list_stack.is_empty() {
                        println!();
                    }
                }
                Tag::Item => {
                    let _ = self.print_output(OutputType::ListItem { is_end: true });
                }
                Tag::CodeBlock(_) => self.print_output(OutputType::CodeBlock)?,
                Tag::Table(_) => {
                    self.clear_table();
                    println!();
                }
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

    /// Handle text-related events
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
                    let _ = self.print_output(OutputType::InlineCode {
                        code: code.to_string(),
                    });
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
                let line = "─".repeat(40);
                let styled_line =
                    self.apply_text_style(&line, super::styling::TextStyle::Delimiter);
                println!("\n{}\n", styled_line);
            }
            ContentType::TaskMarker(checked) => {
                let _ = self.print_output(OutputType::TaskMarker { checked });
            }
        }
        Ok(())
    }
}
