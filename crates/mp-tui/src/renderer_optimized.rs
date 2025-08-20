use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use ratatui::{
    buffer::Buffer,
    layout::{Constraint, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Cell, Paragraph, Row, StatefulWidget, Table, Widget},
};
use regex::Regex;

use crate::theme_adapter::{RatatuiAdapter, RatatuiStyleAdapter};
use mp_core::theme::{MarkdownTheme, SolarizedOsaka};

#[derive(Debug, Clone)]
pub enum MarkdownElement {
    Line(Line<'static>),
    Table(TableData),
    CodeBlock(CodeBlockData),
}

#[derive(Debug, Clone)]
pub struct TableData {
    pub headers: Vec<String>,
    pub rows: Vec<Vec<String>>,
}

#[derive(Debug, Clone)]
pub struct CodeBlockData {
    pub language: Option<String>,
    pub content: String,
}

pub struct MarkdownWidget {
    content: String,
    lines: Vec<Line<'static>>,  // Flattened lines for efficient scrolling
    theme: SolarizedOsaka,
}

#[derive(Default, Clone)]
pub struct MarkdownWidgetState {
    pub scroll_offset: u16,
    pub border_style: Style,
}

impl MarkdownWidget {
    pub fn new(content: String) -> Self {
        let mut widget = Self {
            content: content.clone(),
            lines: Vec::new(),
            theme: SolarizedOsaka,
        };
        widget.parse_markdown();
        widget
    }

    pub fn get_lines(&self) -> &Vec<Line<'static>> {
        &self.lines
    }

    pub fn parse_markdown(&mut self) {
        self.lines.clear();

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
                    Tag::Table(_) => {
                        if !current_line.is_empty() {
                            self.lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                        in_table = true;
                        table_headers.clear();
                        table_rows.clear();
                    }
                    Tag::CodeBlock(kind) => {
                        if !current_line.is_empty() {
                            self.lines.push(Line::from(current_line.clone()));
                            current_line.clear();
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
                        let heading_level = match level {
                            pulldown_cmark::HeadingLevel::H1 => 1,
                            pulldown_cmark::HeadingLevel::H2 => 2,
                            pulldown_cmark::HeadingLevel::H3 => 3,
                            pulldown_cmark::HeadingLevel::H4 => 4,
                            pulldown_cmark::HeadingLevel::H5 => 5,
                            pulldown_cmark::HeadingLevel::H6 => 6,
                        };
                        let heading_style = self.theme.heading_style(heading_level);
                        current_style = heading_style.to_ratatui_style();
                    }
                    Tag::Emphasis => {
                        let emphasis_style = self.theme.emphasis_style();
                        current_style = emphasis_style.to_ratatui_style();
                    }
                    Tag::Strong => {
                        let strong_style = self.theme.strong_style();
                        current_style = strong_style.to_ratatui_style();
                    }
                    Tag::List(start) => {
                        if in_list_item && !current_line.is_empty() {
                            self.lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                        let counter = start.unwrap_or(0);
                        list_stack.push((start, counter));
                    }
                    Tag::Item => {
                        in_list_item = true;
                        if !current_line.is_empty() {
                            self.lines.push(Line::from(current_line.clone()));
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
                        let link_style = self.theme.link_style();
                        let color = link_style.color.to_ratatui_color();
                        current_style = Style::default()
                            .fg(color)
                            .add_modifier(Modifier::UNDERLINED);
                    }
                    _ => {}
                },
                Event::End(tag) => match tag {
                    TagEnd::Table => {
                        in_table = false;
                        // Render table as simple lines
                        self.render_table_as_lines(&table_headers, &table_rows);
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
                        self.render_code_block_as_lines(&code_block_language, &code_block_content);
                        code_block_content.clear();
                        code_block_language = None;
                    }
                    TagEnd::Heading(_) => {
                        if !current_line.is_empty() {
                            self.lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                        self.lines.push(Line::from(""));
                        current_style = Style::default();
                    }
                    TagEnd::Emphasis | TagEnd::Strong => {
                        current_style = Style::default();
                    }
                    TagEnd::List(_) => {
                        list_stack.pop();
                        if list_stack.is_empty() && !current_line.is_empty() {
                            self.lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                    }
                    TagEnd::Item => {
                        in_list_item = false;
                        if !current_line.is_empty() {
                            self.lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                    }
                    TagEnd::Link => {
                        current_style = Style::default();
                    }
                    TagEnd::Paragraph => {
                        if !current_line.is_empty() && !in_table {
                            self.lines.push(Line::from(current_line.clone()));
                            current_line.clear();
                        }
                        if !in_code_block && !in_table {
                            self.lines.push(Line::from(""));
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
                                self.lines.push(Line::from(current_line.clone()));
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
                        let code_style = self.theme.code_style();
                        let fg_color = code_style.color.to_ratatui_color();
                        let bg_color = self.theme.code_background().to_ratatui_color();
                        current_line.push(Span::styled(
                            format!("`{}`", code),
                            Style::default().fg(fg_color).bg(bg_color),
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
                        self.lines.push(Line::from(current_line.clone()));
                        current_line.clear();
                    }
                }
                _ => {}
            }
        }

        if !current_line.is_empty() {
            self.lines.push(Line::from(current_line));
        }
    }

    fn render_table_as_lines(&mut self, headers: &[String], rows: &[Vec<String>]) {
        // Simplified table rendering as lines
        let header_line = headers.join(" | ");
        self.lines.push(Line::from(vec![Span::styled(
            header_line,
            Style::default().add_modifier(Modifier::BOLD),
        )]));
        
        self.lines.push(Line::from("-".repeat(40)));
        
        for row in rows {
            let row_line = row.join(" | ");
            self.lines.push(Line::from(row_line));
        }
        
        self.lines.push(Line::from(""));
    }

    fn render_code_block_as_lines(&mut self, language: &Option<String>, content: &str) {
        let delimiter_style = self.theme.delimiter_style();
        let fence_color = delimiter_style.color.to_ratatui_color();
        let fence_style = Style::default().fg(fence_color);
        
        let opening = if let Some(ref lang) = language {
            format!("```{}", lang)
        } else {
            "```".to_string()
        };
        
        self.lines.push(Line::from(Span::styled(opening, fence_style)));
        
        let theme_code_style = self.theme.code_style();
        let code_color = theme_code_style.color.to_ratatui_color();
        let code_style = Style::default().fg(code_color);
        
        for line in content.lines() {
            self.lines.push(Line::from(Span::styled(line.to_string(), code_style)));
        }
        
        self.lines.push(Line::from(Span::styled("```", fence_style)));
        self.lines.push(Line::from(""));
    }
}

impl StatefulWidget for &MarkdownWidget {
    type State = MarkdownWidgetState;

    fn render(self, area: Rect, buf: &mut Buffer, state: &mut Self::State) {
        let block = Block::default()
            .borders(Borders::ALL)
            .title("Preview")
            .border_style(state.border_style);

        let inner_area = block.inner(area);
        block.render(area, buf);

        // Virtual scrolling: only render visible lines
        let visible_lines = inner_area.height as usize;
        let skip_lines = state.scroll_offset as usize;
        
        for (i, line) in self.lines
            .iter()
            .skip(skip_lines)
            .take(visible_lines)
            .enumerate()
        {
            let y = inner_area.y + i as u16;
            let mut x = inner_area.x;
            
            for span in &line.spans {
                let content = span.content.as_ref();
                let max_width = (inner_area.width as usize).saturating_sub((x - inner_area.x) as usize);
                let display_len = content.chars().take(max_width).count();
                
                if display_len > 0 {
                    buf.set_stringn(x, y, content, display_len, span.style);
                    x += display_len as u16;
                }
                
                if x >= inner_area.x + inner_area.width {
                    break;
                }
            }
        }
    }
}

fn strip_ansi_codes(s: &str) -> String {
    let ansi_regex = Regex::new(r"\x1b\[[0-9;]*[mGKHF]").unwrap();
    ansi_regex.replace_all(s, "").to_string()
}