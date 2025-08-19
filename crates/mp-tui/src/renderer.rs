use pulldown_cmark::{Event, Parser, Tag, TagEnd};
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
    widgets::{Block, Borders, Paragraph, Widget, Wrap},
};

pub struct MarkdownWidget {
    content: String,
    scroll_offset: u16,
    border_style: Style,
}

impl MarkdownWidget {
    pub fn new(content: String) -> Self {
        Self {
            content,
            scroll_offset: 0,
            border_style: Style::default(),
        }
    }

    pub fn scroll_offset(mut self, offset: u16) -> Self {
        self.scroll_offset = offset;
        self
    }

    pub fn border_style(mut self, style: Style) -> Self {
        self.border_style = style;
        self
    }

    fn parse_to_text(&self) -> Text<'static> {
        let mut lines = Vec::new();
        let mut current_line = Vec::new();
        let mut current_style = Style::default();
        let mut in_code_block = false;
        let mut list_depth: usize = 0;

        let parser = Parser::new(&self.content);

        for event in parser {
            match event {
                Event::Start(tag) => match tag {
                    Tag::Heading { level, .. } => {
                        current_style = match level {
                            pulldown_cmark::HeadingLevel::H1 => Style::default()
                                .fg(Color::Rgb(211, 54, 130))
                                .add_modifier(Modifier::BOLD),
                            pulldown_cmark::HeadingLevel::H2 => Style::default()
                                .fg(Color::Rgb(108, 113, 196))
                                .add_modifier(Modifier::BOLD),
                            pulldown_cmark::HeadingLevel::H3 => {
                                Style::default().fg(Color::Rgb(38, 139, 210))
                            }
                            pulldown_cmark::HeadingLevel::H4 => {
                                Style::default().fg(Color::Rgb(42, 161, 152))
                            }
                            pulldown_cmark::HeadingLevel::H5 => {
                                Style::default().fg(Color::Rgb(133, 153, 0))
                            }
                            pulldown_cmark::HeadingLevel::H6 => {
                                Style::default().fg(Color::Rgb(181, 137, 0))
                            }
                        };
                    }
                    Tag::Emphasis => {
                        current_style = current_style.add_modifier(Modifier::ITALIC);
                    }
                    Tag::Strong => {
                        current_style = current_style.add_modifier(Modifier::BOLD);
                    }
                    Tag::CodeBlock(_) => {
                        in_code_block = true;
                        current_style = Style::default().fg(Color::Rgb(42, 161, 152));
                    }
                    Tag::List(_) => {
                        list_depth += 1;
                    }
                    Tag::Item => {
                        let indent = "  ".repeat(list_depth.saturating_sub(1));
                        current_line.push(Span::raw(format!("{}• ", indent)));
                    }
                    Tag::Link { .. } => {
                        current_style = Style::default()
                            .fg(Color::Rgb(38, 139, 210))
                            .add_modifier(Modifier::UNDERLINED);
                    }
                    Tag::BlockQuote(_) => {
                        current_line.push(Span::styled(
                            "> ",
                            Style::default().fg(Color::Rgb(101, 123, 131)),
                        ));
                        current_style = Style::default().fg(Color::Rgb(101, 123, 131));
                    }
                    _ => {}
                },
                Event::End(tag) => match tag {
                    TagEnd::Heading(_) => {
                        if !current_line.is_empty() {
                            lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                        lines.push(Line::from(""));
                        current_style = Style::default();
                    }
                    TagEnd::Emphasis | TagEnd::Strong => {
                        current_style = Style::default();
                    }
                    TagEnd::CodeBlock => {
                        in_code_block = false;
                        current_style = Style::default();
                        if !current_line.is_empty() {
                            lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                    }
                    TagEnd::List(_) => {
                        list_depth = list_depth.saturating_sub(1);
                        if list_depth == 0 && !current_line.is_empty() {
                            lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                    }
                    TagEnd::Item => {
                        if !current_line.is_empty() {
                            lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                    }
                    TagEnd::Link => {
                        current_style = Style::default();
                    }
                    TagEnd::BlockQuote(_) => {
                        if !current_line.is_empty() {
                            lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                        current_style = Style::default();
                    }
                    TagEnd::Paragraph => {
                        if !current_line.is_empty() {
                            lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                        if !in_code_block {
                            lines.push(Line::from(""));
                        }
                    }
                    _ => {}
                },
                Event::Text(text) => {
                    for line in text.to_string().lines() {
                        if !current_line.is_empty() && line.is_empty() {
                            lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        } else {
                            current_line.push(Span::styled(line.to_string(), current_style));
                        }
                    }
                }
                Event::Code(code) => {
                    current_line.push(Span::styled(
                        format!("`{}`", code),
                        Style::default()
                            .fg(Color::Rgb(42, 161, 152))
                            .bg(Color::Rgb(7, 54, 66)),
                    ));
                }
                Event::SoftBreak => {
                    current_line.push(Span::raw(" "));
                }
                Event::HardBreak => {
                    if !current_line.is_empty() {
                        lines.push(Line::from(current_line.clone()));
                        current_line.clear();
                    }
                }
                _ => {}
            }
        }

        if !current_line.is_empty() {
            lines.push(Line::from(current_line));
        }

        Text::from(lines)
    }
}

impl Widget for MarkdownWidget {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let text = self.parse_to_text();
        let paragraph = Paragraph::new(text)
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .title("📄 Preview")
                    .border_style(self.border_style),
            )
            .style(Style::default().fg(Color::Rgb(131, 148, 150)))
            .wrap(Wrap { trim: true })
            .scroll((self.scroll_offset, 0));
        paragraph.render(area, buf);
    }
}
