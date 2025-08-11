use anyhow::Result;
use pulldown_cmark::Options;

use super::state::{CodeBlockState, ImageState, LinkState, RenderState, StateChange, TableState};
use super::theme::{MarkdownTheme, SolarizedOsaka, styled_text, styled_text_with_bg};

#[derive(Debug)]
pub struct BaseRenderer {
    pub theme: SolarizedOsaka,
    pub state: RenderState,
    pub options: Options,
}

impl Default for BaseRenderer {
    fn default() -> Self {
        Self::new()
    }
}

impl BaseRenderer {
    pub fn new() -> Self {
        let mut options = Options::empty();
        options.insert(Options::ENABLE_STRIKETHROUGH);
        options.insert(Options::ENABLE_TABLES);
        options.insert(Options::ENABLE_FOOTNOTES);
        options.insert(Options::ENABLE_TASKLISTS);

        Self {
            theme: SolarizedOsaka,
            state: RenderState::default(),
            options,
        }
    }

    pub fn apply_state_change(&mut self, change: StateChange) {
        match change {
            StateChange::SetStrongEmphasis(value) => self.state.emphasis.strong = value,
            StateChange::SetItalicEmphasis(value) => self.state.emphasis.italic = value,
            StateChange::SetLink { url } => {
                self.state.link = Some(LinkState {
                    text: String::new(),
                    url,
                });
            }
            StateChange::SetImage { url } => {
                self.state.image = Some(ImageState {
                    alt_text: String::new(),
                    url,
                });
            }
            StateChange::SetCodeBlock { language } => {
                self.state.code_block = Some(CodeBlockState {
                    language,
                    content: String::new(),
                });
            }
            StateChange::SetTable { alignments } => {
                let expected_cells = alignments.len();
                let current_row = Vec::with_capacity(expected_cells);

                self.state.table = Some(TableState {
                    alignments,
                    current_row,
                    is_header: true,
                });
            }
            StateChange::PushList(list_type) => {
                self.state.list_stack.push(list_type);
            }
            StateChange::PopList => {
                self.state.list_stack.pop();
            }
            StateChange::ClearTable => self.state.table = None,
        }
    }

    pub fn get_text_color(&self) -> (u8, u8, u8) {
        if self.state.emphasis.strong {
            self.theme.strong_color()
        } else if self.state.emphasis.italic {
            self.theme.emphasis_color()
        } else if self.state.link.is_some() {
            self.theme.link_color()
        } else {
            self.theme.text_color()
        }
    }

    pub fn render_styled_text(&self, text: &str) {
        let color = self.get_text_color();
        let styled = styled_text(
            text,
            color,
            self.state.emphasis.strong,
            self.state.emphasis.italic,
            false,
        );
        print!("{}", styled);
    }

    pub fn add_text_to_state(&mut self, text: &str) -> bool {
        if let Some(ref mut link) = self.state.link {
            link.text.push_str(text);
            return true;
        }

        if let Some(ref mut image) = self.state.image {
            image.alt_text.push_str(text);
            return true;
        }

        if let Some(ref mut code_block) = self.state.code_block {
            code_block.content.push_str(text);
            return true;
        }

        if let Some(ref mut table) = self.state.table {
            if let Some(last_cell) = table.current_row.last_mut() {
                last_cell.push_str(text);
            } else {
                table.current_row.push(text.to_string());
            }
            return true;
        }

        false
    }

    pub fn render_code_fence(&self, language: Option<&str>) {
        let fence = styled_text("```", self.theme.delimiter_color(), false, false, false);
        if let Some(lang) = language {
            let lang_text = styled_text(lang, self.theme.cyan(), false, false, false);
            println!("{}{}", fence, lang_text);
        } else {
            println!("{}", fence);
        }
    }

    pub fn render_code_content(&self, content: &str) {
        for line in content.lines() {
            let styled_line =
                styled_text_with_bg(line, self.theme.code_color(), self.theme.code_background());
            println!("{}", styled_line);
        }
    }

    pub fn render_code_block(&self, code_block: &CodeBlockState) -> Result<()> {
        self.render_code_fence(code_block.language.as_deref());
        self.render_code_content(&code_block.content);
        self.render_code_fence(None);

        Ok(())
    }

    pub fn render_table_row(&self, row: &[String], is_header: bool) -> Result<()> {
        // Calculate estimated size for table row (character count per cell + separators)
        let estimated_size: usize = row.iter().map(|s| s.len() + 4).sum::<usize>() + 1;
        let mut output = String::with_capacity(estimated_size);
        output.push('|');
        for cell in row {
            output.push(' ');
            if is_header {
                let styled = styled_text(cell, self.theme.heading_color(1), true, false, false);
                output.push_str(&styled);
            } else {
                output.push_str(cell);
            }
            output.push_str(" |");
        }
        println!("{}", output);
        Ok(())
    }

    pub fn render_table_separator(&self, alignments: &[pulldown_cmark::Alignment]) -> Result<()> {
        // Each separator is max 7 chars (":---:" + " |") + starting "|"
        let mut output = String::with_capacity(alignments.len() * 8 + 1);
        output.push('|');
        for alignment in alignments {
            let separator = match alignment {
                pulldown_cmark::Alignment::Left => ":---",
                pulldown_cmark::Alignment::Center => ":---:",
                pulldown_cmark::Alignment::Right => "---:",
                pulldown_cmark::Alignment::None => "---",
            };
            output.push(' ');
            output.push_str(separator);
            output.push_str(" |");
        }
        println!("{}", output);
        Ok(())
    }
}
