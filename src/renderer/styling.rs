use super::{MarkdownRenderer, state::StateChange};
use crate::theme::MarkdownTheme;

// Re-export styling functions from theme module
pub use crate::theme::{styled_text, styled_text_with_bg};

impl MarkdownRenderer {
    /// Apply state change
    pub fn apply_state(&mut self, change: StateChange) {
        match &change {
            StateChange::PopList => {
                self.apply_state_change(change);
                if self.state.list_stack.is_empty() {
                    println!();
                }
                return;
            }
            StateChange::ClearTable => {
                self.apply_state_change(change);
                println!();
                return;
            }
            _ => {}
        }
        self.apply_state_change(change);
    }

    /// Internal helper to apply state change
    pub(super) fn apply_state_change(&mut self, change: StateChange) {
        change.apply_to(&mut self.state);
    }

    /// Get text color based on current emphasis state
    pub(super) fn get_text_color(&self) -> (u8, u8, u8) {
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

    /// Render styled text to stdout
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

    /// Helper method to create styled markers (headings, list items, etc.)
    pub fn create_styled_marker(&self, marker: &str, color: (u8, u8, u8), bold: bool) -> String {
        styled_text(marker, color, bold, false, false).to_string()
    }

    /// Helper method to create styled URL text
    pub fn create_styled_url(&self, url: &str) -> String {
        self.create_styled_marker(&format!(" ({})", url), self.theme.delimiter_color(), false)
    }

    /// Add text to the appropriate state container
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
}
