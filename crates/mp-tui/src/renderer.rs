use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use ratatui::{
    buffer::Buffer,
    layout::{Constraint, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span, Text},
    widgets::{Block, Borders, Cell, Paragraph, Row, Table, Widget, Wrap},
};
use regex::Regex;

#[derive(Debug, Clone)]
enum MarkdownElement {
    Paragraph(Text<'static>),
    Table(TableData),
    CodeBlock(CodeBlockData),
}

#[derive(Debug, Clone)]
struct TableData {
    headers: Vec<String>,
    rows: Vec<Vec<String>>,
}

#[derive(Debug, Clone)]
struct CodeBlockData {
    language: Option<String>,
    content: String,
}

pub struct MarkdownWidget {
    content: String,
    scroll_offset: u16,
    border_style: Style,
    elements: Vec<MarkdownElement>,
}

impl MarkdownWidget {
    pub fn new(content: String) -> Self {
        let mut widget = Self {
            content: content.clone(),
            scroll_offset: 0,
            border_style: Style::default(),
            elements: Vec::new(),
        };
        widget.parse_markdown();
        widget
    }

    pub fn scroll_offset(mut self, offset: u16) -> Self {
        self.scroll_offset = offset;
        self
    }

    pub fn border_style(mut self, style: Style) -> Self {
        self.border_style = style;
        self
    }

    fn parse_markdown(&mut self) {
        self.elements.clear();

        let mut current_paragraph_lines: Vec<Line> = Vec::new();
        let mut current_line = Vec::new();
        let mut current_style = Style::default();
        let mut list_stack: Vec<(Option<u64>, u64)> = Vec::new();
        let mut in_list_item = false;

        let mut in_table = false;
        let mut is_header_row = false;
        let mut table_headers: Vec<String> = Vec::new();
        let mut table_rows: Vec<Vec<String>> = Vec::new();
        let mut current_row: Vec<String> = Vec::new();
        let mut current_cell = String::new();

        let mut in_code_block = false;
        let mut code_block_content = String::new();
        let mut code_block_language: Option<String> = None;

        let mut options = Options::empty();
        options.insert(Options::ENABLE_TABLES);
        options.insert(Options::ENABLE_STRIKETHROUGH);
        let parser = Parser::new_ext(&self.content, options);

        for event in parser {
            match event {
                Event::Start(tag) => match tag {
                    Tag::Table(_alignments) => {
                        if !current_paragraph_lines.is_empty() {
                            self.elements.push(MarkdownElement::Paragraph(Text::from(
                                current_paragraph_lines.clone(),
                            )));
                            current_paragraph_lines.clear();
                        }

                        in_table = true;
                        table_headers.clear();
                        table_rows.clear();
                    }
                    Tag::TableHead => {
                        is_header_row = true;
                    }
                    Tag::TableRow => {
                        current_row.clear();
                    }
                    Tag::TableCell => {
                        current_cell.clear();
                    }
                    Tag::CodeBlock(kind) => {
                        if !current_paragraph_lines.is_empty() {
                            self.elements.push(MarkdownElement::Paragraph(Text::from(
                                current_paragraph_lines.clone(),
                            )));
                            current_paragraph_lines.clear();
                        }

                        in_code_block = true;
                        code_block_content.clear();
                        code_block_language = match kind {
                            pulldown_cmark::CodeBlockKind::Fenced(lang) => {
                                if lang.is_empty() {
                                    None
                                } else {
                                    Some(lang.to_string())
                                }
                            }
                            _ => None,
                        };
                    }
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
                    Tag::List(start) => {
                        if in_list_item && !current_line.is_empty() {
                            current_paragraph_lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                        let counter = start.unwrap_or(0);
                        list_stack.push((start, counter));
                    }
                    Tag::Item => {
                        in_list_item = true;
                        if !current_line.is_empty() {
                            current_paragraph_lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }

                        let indent = "  ".repeat(list_stack.len().saturating_sub(1));

                        let marker = if let Some((list_type, counter)) = list_stack.last_mut() {
                            match list_type {
                                Some(_) => {
                                    let current = *counter;
                                    *counter += 1;
                                    format!("{}. ", current)
                                }
                                None => "• ".to_string(),
                            }
                        } else {
                            "• ".to_string()
                        };

                        current_line.push(Span::raw(format!("{}{}", indent, marker)));
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
                    TagEnd::Table => {
                        in_table = false;
                        self.elements.push(MarkdownElement::Table(TableData {
                            headers: table_headers.clone(),
                            rows: table_rows.clone(),
                        }));
                        table_headers.clear();
                        table_rows.clear();
                    }
                    TagEnd::TableHead => {
                        is_header_row = false;
                    }
                    TagEnd::TableRow => {
                        if is_header_row {
                            table_headers = current_row.clone();
                        } else {
                            table_rows.push(current_row.clone());
                        }
                        current_row.clear();
                    }
                    TagEnd::TableCell => {
                        current_row.push(strip_ansi_codes(&current_cell));
                        current_cell.clear();
                    }
                    TagEnd::CodeBlock => {
                        in_code_block = false;
                        self.elements
                            .push(MarkdownElement::CodeBlock(CodeBlockData {
                                language: code_block_language.clone(),
                                content: code_block_content.clone(),
                            }));
                        code_block_content.clear();
                        code_block_language = None;
                    }
                    TagEnd::Heading(_) => {
                        if !current_line.is_empty() {
                            current_paragraph_lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                        current_paragraph_lines.push(Line::from(""));
                        current_style = Style::default();
                    }
                    TagEnd::Emphasis | TagEnd::Strong => {
                        current_style = Style::default();
                    }
                    TagEnd::List(_) => {
                        list_stack.pop();
                        if list_stack.is_empty() && !current_line.is_empty() {
                            current_paragraph_lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                    }
                    TagEnd::Item => {
                        in_list_item = false;
                        if !current_line.is_empty() {
                            current_paragraph_lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                    }
                    TagEnd::Link => {
                        current_style = Style::default();
                    }
                    TagEnd::BlockQuote(_) => {
                        if !current_line.is_empty() {
                            current_paragraph_lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                        current_style = Style::default();
                    }
                    TagEnd::Paragraph => {
                        if !current_line.is_empty() && !in_table {
                            current_paragraph_lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                        if !in_code_block && !in_table {
                            current_paragraph_lines.push(Line::from(""));
                        }
                    }
                    _ => {}
                },
                Event::Text(text) => {
                    if in_table {
                        current_cell.push_str(&text);
                    } else if in_code_block {
                        code_block_content.push_str(&text);
                    } else {
                        for line in text.to_string().lines() {
                            if !current_line.is_empty() && line.is_empty() {
                                current_paragraph_lines.push(Line::from(current_line.clone()));
                                current_line.clear();
                            } else {
                                current_line.push(Span::styled(line.to_string(), current_style));
                            }
                        }
                    }
                }
                Event::Code(code) => {
                    if in_table {
                        current_cell.push_str(&format!("`{}`", code));
                    } else {
                        current_line.push(Span::styled(
                            format!("`{}`", code),
                            Style::default()
                                .fg(Color::Rgb(42, 161, 152))
                                .bg(Color::Rgb(7, 54, 66)),
                        ));
                    }
                }
                Event::SoftBreak => {
                    if !in_table && !in_code_block {
                        current_line.push(Span::raw(" "));
                    }
                }
                Event::HardBreak => {
                    if !current_line.is_empty() && !in_table && !in_code_block {
                        current_paragraph_lines.push(Line::from(current_line.clone()));
                        current_line.clear();
                    }
                }
                _ => {}
            }
        }

        if !current_line.is_empty() {
            current_paragraph_lines.push(Line::from(current_line));
        }

        if !current_paragraph_lines.is_empty() {
            self.elements.push(MarkdownElement::Paragraph(Text::from(
                current_paragraph_lines,
            )));
        }
    }

    fn create_ratatui_table<'a>(&self, data: &'a TableData) -> Table<'a> {
        let header =
            Row::new(data.headers.iter().map(|h| {
                Cell::from(h.as_str()).style(Style::default().add_modifier(Modifier::BOLD))
            }));

        let rows: Vec<Row> = data
            .rows
            .iter()
            .map(|row| Row::new(row.iter().map(|cell| Cell::from(cell.as_str()))))
            .collect();

        let num_cols = data.headers.len();
        let constraints = if num_cols > 0 {
            vec![Constraint::Percentage((100 / num_cols) as u16); num_cols]
        } else {
            vec![]
        };

        Table::new(rows, constraints)
            .header(header)
            .block(Block::default().borders(Borders::ALL))
            .style(Style::default().fg(Color::Rgb(131, 148, 150)))
    }

    fn render_code_block(&self, data: &CodeBlockData) -> Paragraph<'_> {
        let mut lines = Vec::new();

        let fence_style = Style::default().fg(Color::Rgb(101, 123, 131));
        let opening = if let Some(ref lang) = data.language {
            format!("```{}", lang)
        } else {
            "```".to_string()
        };
        lines.push(Line::from(Span::styled(opening, fence_style)));

        let code_style = Style::default().fg(Color::Rgb(42, 161, 152));
        for line in data.content.lines() {
            lines.push(Line::from(Span::styled(line.to_string(), code_style)));
        }

        lines.push(Line::from(Span::styled("```", fence_style)));

        Paragraph::new(Text::from(lines))
    }
}

impl Widget for MarkdownWidget {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let block = Block::default()
            .borders(Borders::ALL)
            .title("Preview")
            .border_style(self.border_style);

        let inner_area = block.inner(area);
        block.render(area, buf);

        let mut current_y = inner_area.y;
        let mut accumulated_height = 0u16;

        for element in &self.elements {
            if accumulated_height < self.scroll_offset {
                let element_height = match element {
                    MarkdownElement::Paragraph(text) => text.lines.len() as u16,
                    MarkdownElement::Table(data) => {
                        (data.headers.len() + data.rows.len() + 2) as u16
                    }
                    MarkdownElement::CodeBlock(data) => (data.content.lines().count() + 2) as u16,
                };
                accumulated_height += element_height;

                if accumulated_height <= self.scroll_offset {
                    continue;
                }
            }

            if current_y >= inner_area.y + inner_area.height {
                break;
            }

            match element {
                MarkdownElement::Paragraph(text) => {
                    let paragraph = Paragraph::new(text.clone()).wrap(Wrap { trim: false });

                    let paragraph_area = Rect {
                        x: inner_area.x,
                        y: current_y,
                        width: inner_area.width,
                        height: (inner_area.y + inner_area.height).saturating_sub(current_y),
                    };

                    paragraph.render(paragraph_area, buf);
                    current_y += text.lines.len() as u16;
                }
                MarkdownElement::Table(data) => {
                    let table = self.create_ratatui_table(data);
                    let table_height = (data.rows.len() + 3) as u16; // +3 for header, separator, and borders

                    let table_area = Rect {
                        x: inner_area.x,
                        y: current_y,
                        width: inner_area.width,
                        height: table_height
                            .min((inner_area.y + inner_area.height).saturating_sub(current_y)),
                    };

                    table.render(table_area, buf);
                    current_y += table_height;
                }
                MarkdownElement::CodeBlock(data) => {
                    let code_block = self.render_code_block(data);
                    let code_height = (data.content.lines().count() + 2) as u16;

                    let code_area = Rect {
                        x: inner_area.x,
                        y: current_y,
                        width: inner_area.width,
                        height: code_height
                            .min((inner_area.y + inner_area.height).saturating_sub(current_y)),
                    };

                    code_block.render(code_area, buf);
                    current_y += code_height;
                }
            }
        }
    }
}

fn strip_ansi_codes(s: &str) -> String {
    let ansi_regex = Regex::new(r"\x1b\[[0-9;]*[mGKHF]").unwrap();
    ansi_regex.replace_all(s, "").to_string()
}
