use anyhow::Result;
use pulldown_cmark::Options;

use super::state::{CodeBlockState, RenderContext, StateChange};
use super::theme::{MarkdownTheme, SolarizedOsaka, styled_text, styled_text_with_bg};

#[derive(Debug)]
pub struct BaseRenderer {
    pub theme: SolarizedOsaka,
    pub state: RenderContext,
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
            state: RenderContext::default(),
            options,
        }
    }

    pub fn apply_state_change(&mut self, change: StateChange) {
        change.apply_to(&mut self.state);
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
        print!("{}", self.create_styled_text(text));
    }

    /// Create styled text without printing it
    pub fn create_styled_text(&self, text: &str) -> String {
        let color = self.get_text_color();
        styled_text(
            text,
            color,
            self.state.emphasis.strong,
            self.state.emphasis.italic,
            false,
        )
        .to_string()
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
        println!("{}", self.create_code_fence(language));
    }

    /// Create code fence without printing it
    pub fn create_code_fence(&self, language: Option<&str>) -> String {
        let fence = styled_text("```", self.theme.delimiter_color(), false, false, false);
        if let Some(lang) = language {
            let lang_text = styled_text(lang, self.theme.cyan(), false, false, false);
            format!("{}{}", fence, lang_text)
        } else {
            fence.to_string()
        }
    }

    pub fn render_code_content(&self, content: &str) {
        for line in content.lines() {
            println!("{}", self.create_styled_code_line(line));
        }
    }

    /// Create styled code line without printing it
    pub fn create_styled_code_line(&self, line: &str) -> String {
        styled_text_with_bg(line, self.theme.code_color(), self.theme.code_background()).to_string()
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::renderer::state::{ImageState, LinkState, TableState};
    use rstest::rstest;

    #[test]
    fn test_base_renderer_creation() {
        let renderer = BaseRenderer::new();
        assert!(renderer.options.contains(Options::ENABLE_STRIKETHROUGH));
        assert!(renderer.options.contains(Options::ENABLE_TABLES));
        assert!(renderer.options.contains(Options::ENABLE_FOOTNOTES));
        assert!(renderer.options.contains(Options::ENABLE_TASKLISTS));
    }

    #[test]
    fn test_state_change_application() {
        let mut renderer = BaseRenderer::new();

        // Test strong emphasis
        renderer.apply_state_change(StateChange::SetStrongEmphasis(true));
        assert!(renderer.state.emphasis.strong);

        // Test italic emphasis
        renderer.apply_state_change(StateChange::SetItalicEmphasis(true));
        assert!(renderer.state.emphasis.italic);

        // Test link
        renderer.apply_state_change(StateChange::SetLink("https://example.com".to_string()));
        assert!(renderer.state.link.is_some());
        assert_eq!(
            renderer.state.link.as_ref().unwrap().url,
            "https://example.com"
        );

        // Test clear table
        renderer.apply_state_change(StateChange::SetTable(vec![]));
        assert!(renderer.state.table.is_some());
        renderer.apply_state_change(StateChange::ClearTable);
        assert!(renderer.state.table.is_none());
    }

    #[rstest]
    #[case(true, false, false)] // Strong emphasis
    #[case(false, true, false)] // Italic emphasis
    #[case(false, false, true)] // Link
    #[case(false, false, false)] // Normal text
    fn test_text_color_selection(
        #[case] strong: bool,
        #[case] italic: bool,
        #[case] has_link: bool,
    ) {
        let mut renderer = BaseRenderer::new();
        renderer.state.emphasis.strong = strong;
        renderer.state.emphasis.italic = italic;
        if has_link {
            renderer.state.link = Some(LinkState {
                text: String::new(),
                url: "test".to_string(),
            });
        }

        let color = renderer.get_text_color();
        if strong {
            assert_eq!(color, renderer.theme.strong_color());
        } else if italic {
            assert_eq!(color, renderer.theme.emphasis_color());
        } else if has_link {
            assert_eq!(color, renderer.theme.link_color());
        } else {
            assert_eq!(color, renderer.theme.text_color());
        }
    }

    #[test]
    fn test_add_text_to_state() {
        let mut renderer = BaseRenderer::new();

        // Test adding text to link
        renderer.state.link = Some(LinkState {
            text: String::new(),
            url: "test".to_string(),
        });
        assert!(renderer.add_text_to_state("link text"));
        assert_eq!(renderer.state.link.as_ref().unwrap().text, "link text");

        // Clear link and test image
        renderer.state.link = None;
        renderer.state.image = Some(ImageState {
            alt_text: String::new(),
            url: "image.jpg".to_string(),
        });
        assert!(renderer.add_text_to_state("alt text"));
        assert_eq!(renderer.state.image.as_ref().unwrap().alt_text, "alt text");

        // Clear image and test code block
        renderer.state.image = None;
        renderer.state.code_block = Some(CodeBlockState {
            language: None,
            content: String::new(),
        });
        assert!(renderer.add_text_to_state("code content"));
        assert_eq!(
            renderer.state.code_block.as_ref().unwrap().content,
            "code content"
        );

        // Clear code block and test table
        renderer.state.code_block = None;
        renderer.state.table = Some(TableState {
            alignments: vec![],
            current_row: vec![],
            is_header: true,
        });
        assert!(renderer.add_text_to_state("cell 1"));
        assert_eq!(
            renderer.state.table.as_ref().unwrap().current_row[0],
            "cell 1"
        );

        // Clear all and test no state
        renderer.state.table = None;
        assert!(!renderer.add_text_to_state("normal text"));
    }

    #[test]
    fn test_code_fence_creation() {
        let renderer = BaseRenderer::new();

        // Test without language
        let fence = renderer.create_code_fence(None);
        assert!(fence.contains("```"));

        // Test with language
        let fence_with_lang = renderer.create_code_fence(Some("rust"));
        assert!(fence_with_lang.contains("```"));
        assert!(fence_with_lang.contains("rust"));
    }
}
