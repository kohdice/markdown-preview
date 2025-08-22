use std::sync::Arc;

use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::StatefulWidget,
};
use regex::Regex;

use mp_core::theme::{MarkdownTheme, SolarizedOsaka};

use crate::theme_adapter::{RatatuiAdapter, RatatuiStyleAdapter};

pub struct MarkdownWidget {
    content: Arc<String>,
    lines: Vec<Line<'static>>,
    theme: SolarizedOsaka,
}

#[derive(Default, Clone)]
pub struct MarkdownWidgetState {
    pub scroll_offset: u16,
    pub border_style: Style,
}

impl MarkdownWidget {
    pub fn new(content: Arc<String>) -> Self {
        let mut widget = Self {
            content,
            lines: Vec::with_capacity(100),
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

        let mut current_line = Vec::with_capacity(10);
        let mut current_style = Style::default();
        let mut list_stack: Vec<(Option<u64>, u64)> = Vec::with_capacity(5);
        let mut in_list_item = false;

        let mut in_table = false;
        let mut is_header_row = false;
        let mut table_headers: Vec<String> = Vec::with_capacity(10);
        let mut table_rows: Vec<Vec<String>> = Vec::with_capacity(20);
        let mut current_row: Vec<String> = Vec::with_capacity(10);
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
                            self.lines
                                .push(Line::from(std::mem::take(&mut current_line)));
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
                        if !current_line.is_empty() {
                            self.lines
                                .push(Line::from(std::mem::take(&mut current_line)));
                        }
                        in_code_block = true;
                        code_block_content.clear();
                        code_block_language = match kind {
                            pulldown_cmark::CodeBlockKind::Fenced(lang) => {
                                if lang.is_empty() {
                                    None
                                } else {
                                    Some(lang.into())
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
                            self.lines
                                .push(Line::from(std::mem::take(&mut current_line)));
                        }
                        let counter = start.unwrap_or(0);
                        list_stack.push((start, counter));
                    }
                    Tag::Item => {
                        in_list_item = true;
                        if !current_line.is_empty() {
                            self.lines
                                .push(Line::from(std::mem::take(&mut current_line)));
                        }

                        let indent = "  ".repeat(list_stack.len().saturating_sub(1));
                        let marker = if let Some((list_type, counter)) = list_stack.last_mut() {
                            match list_type {
                                Some(_) => {
                                    let current = *counter;
                                    *counter += 1;
                                    format!("{}. ", current)
                                }
                                None => "• ".into(),
                            }
                        } else {
                            "• ".into()
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
                        let rendered_lines = Self::create_table_lines(&table_headers, &table_rows);
                        self.lines.extend(rendered_lines);
                        table_headers.clear();
                        table_rows.clear();
                    }
                    TagEnd::TableHead => {
                        is_header_row = false;
                    }
                    TagEnd::TableRow => {
                        if is_header_row {
                            table_headers = std::mem::take(&mut current_row);
                        } else {
                            table_rows.push(std::mem::take(&mut current_row));
                        }
                        current_row.clear();
                    }
                    TagEnd::TableCell => {
                        current_row.push(strip_ansi_codes(&current_cell));
                        current_cell.clear();
                    }
                    TagEnd::CodeBlock => {
                        in_code_block = false;
                        let rendered_lines =
                            self.create_code_block_lines(&code_block_language, &code_block_content);
                        self.lines.extend(rendered_lines);
                        code_block_content.clear();
                        code_block_language = None;
                    }
                    TagEnd::Heading(_) => {
                        if !current_line.is_empty() {
                            self.lines
                                .push(Line::from(std::mem::take(&mut current_line)));
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
                            self.lines
                                .push(Line::from(std::mem::take(&mut current_line)));
                        }
                    }
                    TagEnd::Item => {
                        in_list_item = false;
                        if !current_line.is_empty() {
                            self.lines
                                .push(Line::from(std::mem::take(&mut current_line)));
                        }
                    }
                    TagEnd::Link => {
                        current_style = Style::default();
                    }
                    TagEnd::Paragraph => {
                        if !current_line.is_empty() && !in_table {
                            self.lines
                                .push(Line::from(std::mem::take(&mut current_line)));
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
                        for line in text.as_ref().lines() {
                            if !current_line.is_empty() && line.is_empty() {
                                self.lines
                                    .push(Line::from(std::mem::take(&mut current_line)));
                            } else {
                                current_line.push(Span::styled(line.to_owned(), current_style));
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
                        self.lines
                            .push(Line::from(std::mem::take(&mut current_line)));
                    }
                }
                _ => {}
            }
        }

        if !current_line.is_empty() {
            self.lines.push(Line::from(current_line));
        }
    }

    fn create_table_lines(headers: &[String], rows: &[Vec<String>]) -> Vec<Line<'static>> {
        let mut lines = Vec::with_capacity(rows.len() + 3);
        let header_line = headers.join(" | ");
        lines.push(Line::from(vec![Span::styled(
            header_line,
            Style::default().add_modifier(Modifier::BOLD),
        )]));

        lines.push(Line::from("-".repeat(40)));

        for row in rows {
            let row_line = row.join(" | ");
            lines.push(Line::from(row_line));
        }

        lines.push(Line::from(""));
        lines
    }

    fn create_code_block_lines(
        &self,
        language: &Option<String>,
        content: &str,
    ) -> Vec<Line<'static>> {
        let content_lines = content.lines().count();
        let mut lines = Vec::with_capacity(content_lines + 2);
        let delimiter_style = self.theme.delimiter_style();
        let fence_color = delimiter_style.color.to_ratatui_color();
        let fence_style = Style::default().fg(fence_color);

        let opening = if let Some(lang) = language {
            format!("```{}", lang)
        } else {
            "```".into()
        };

        lines.push(Line::from(Span::styled(opening, fence_style)));

        let theme_code_style = self.theme.code_style();
        let code_color = theme_code_style.color.to_ratatui_color();
        let code_style = Style::default().fg(code_color);

        for line in content.lines() {
            lines.push(Line::from(Span::styled(line.to_owned(), code_style)));
        }

        lines.push(Line::from(Span::styled("```", fence_style)));
        lines.push(Line::from(""));
        lines
    }
}

impl StatefulWidget for &MarkdownWidget {
    type State = MarkdownWidgetState;

    fn render(self, area: Rect, buf: &mut Buffer, state: &mut Self::State) {
        // Don't render borders here - let PreviewWidget handle the borders
        let visible_lines = area.height as usize;
        let skip_lines = state.scroll_offset as usize;

        for (i, line) in self
            .lines
            .iter()
            .skip(skip_lines)
            .take(visible_lines)
            .enumerate()
        {
            let y = area.y + i as u16;
            let mut x = area.x;

            for span in &line.spans {
                let content = span.content.as_ref();
                let max_width = (area.width as usize).saturating_sub((x - area.x) as usize);
                let display_len = content.chars().take(max_width).count();

                if display_len > 0 {
                    buf.set_stringn(x, y, content, display_len, span.style);
                    x += display_len as u16;
                }

                if x >= area.x + area.width {
                    break;
                }
            }
        }
    }
}

fn strip_ansi_codes(s: &str) -> String {
    let ansi_regex = Regex::new(r"\x1b\[[0-9;]*[mGKHF]").unwrap();
    ansi_regex.replace_all(s, "").into_owned()
}
