use std::path::Path;

use anyhow::Result;

use super::state::RenderState;
use super::theme::MarkdownTheme;

/// Main trait for Markdown processing
pub trait MarkdownProcessor {
    fn render_file(&mut self, path: &Path) -> Result<()>;
    fn render_state(&self) -> &RenderState;
    fn render_state_mut(&mut self) -> &mut RenderState;
    fn theme(&self) -> &dyn MarkdownTheme;
}

/// Trait for table rendering
pub trait TableRenderer {
    fn render_table_row(&mut self, row: &[String], is_header: bool) -> Result<()>;
    fn render_table_separator(&mut self, alignments: &[pulldown_cmark::Alignment]) -> Result<()>;
}
