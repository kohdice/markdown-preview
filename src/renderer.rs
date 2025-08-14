//! Module for rendering Markdown files
//!
//! This module parses Markdown files and content,
//! converting them to terminal-displayable format.

use std::path::Path;

use anyhow::Result;
use pulldown_cmark::{Options, Parser};

use crate::theme::SolarizedOsaka;

// Internal modules for separating rendering concerns
mod element_accessor;
mod formatting;
mod handlers;
mod io;
pub mod state;
mod styling;

// Public API exports for external module usage
pub use element_accessor::{
    CodeBlockAccessor, ElementData, ImageAccessor, LinkAccessor, TableAccessor,
};
pub use state::{ActiveElement, RenderState};
pub use styling::TextStyle;

// Re-export core rendering functionality
use self::io::read_file;

/// Main Markdown renderer struct
///
/// # Primary Responsibilities
/// - Loading and parsing Markdown files
/// - Markdown parsing using pulldown_cmark
/// - Converting events to terminal-displayable format
#[derive(Debug)]
pub struct MarkdownRenderer {
    pub theme: SolarizedOsaka,
    pub state: RenderState,
    pub options: Options,
}

impl Default for MarkdownRenderer {
    fn default() -> Self {
        Self::new()
    }
}

impl MarkdownRenderer {
    /// Create a new MarkdownRenderer instance
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

    // Generic accessor methods using ElementData trait.
    // These replace all repetitive getter/setter methods with a single implementation.
    /// Get immutable reference to element data of type T
    pub fn get<T: ElementData>(&self) -> Option<&T::Output> {
        self.state.active_element.as_ref().and_then(T::extract)
    }

    /// Get mutable reference to element data of type T
    pub fn get_mut<T: ElementData>(&mut self) -> Option<&mut T::Output> {
        self.state.active_element.as_mut().and_then(T::extract_mut)
    }

    /// Get cloned element data of type T
    pub fn get_cloned<T>(&self) -> Option<T::Output>
    where
        T: ElementData,
        T::Output: Clone,
    {
        self.get::<T>().cloned()
    }

    /// Set active element with data of type T
    pub fn set<T: ElementData>(&mut self, data: T::Output) {
        self.state.active_element = Some(T::create(data));
    }

    // State management methods for tracking active Markdown elements during parsing.
    // These methods provide a clean API for state transitions without exposing
    // the internal state structure directly.
    pub fn set_strong_emphasis(&mut self, value: bool) {
        self.state.emphasis.strong = value;
    }

    pub fn set_italic_emphasis(&mut self, value: bool) {
        self.state.emphasis.italic = value;
    }

    pub fn set_link(&mut self, url: String) {
        self.state.active_element = Some(ActiveElement::Link(state::LinkState {
            text: String::new(),
            url,
        }));
    }

    pub fn clear_link(&mut self) {
        self.clear_active_element();
    }

    pub fn has_link(&self) -> bool {
        matches!(
            self.state.active_element,
            Some(state::ActiveElement::Link(_))
        )
    }

    pub fn set_image(&mut self, url: String) {
        self.state.active_element = Some(ActiveElement::Image(state::ImageState {
            alt_text: String::new(),
            url,
        }));
    }

    pub fn clear_image(&mut self) {
        self.clear_active_element();
    }

    pub fn clear_active_element(&mut self) {
        self.state.active_element = None;
    }

    // Legacy methods for backward compatibility - delegate to generic implementation
    pub fn get_link(&self) -> Option<state::LinkState> {
        self.get_cloned::<LinkAccessor>()
    }

    pub fn get_image(&self) -> Option<state::ImageState> {
        self.get_cloned::<ImageAccessor>()
    }

    pub fn get_code_block(&self) -> Option<state::CodeBlockState> {
        self.get_cloned::<CodeBlockAccessor>()
    }

    pub fn get_table(&self) -> Option<state::TableState> {
        self.get_cloned::<TableAccessor>()
    }

    pub fn get_table_mut(&mut self) -> Option<&mut state::TableState> {
        self.get_mut::<TableAccessor>()
    }

    pub fn get_link_mut(&mut self) -> Option<&mut state::LinkState> {
        self.get_mut::<LinkAccessor>()
    }

    pub fn get_image_mut(&mut self) -> Option<&mut state::ImageState> {
        self.get_mut::<ImageAccessor>()
    }

    pub fn get_code_block_mut(&mut self) -> Option<&mut state::CodeBlockState> {
        self.get_mut::<CodeBlockAccessor>()
    }

    pub fn set_code_block(&mut self, kind: pulldown_cmark::CodeBlockKind<'static>) {
        let language = match kind {
            pulldown_cmark::CodeBlockKind::Indented => None,
            pulldown_cmark::CodeBlockKind::Fenced(lang) => {
                if lang.is_empty() {
                    None
                } else {
                    Some(lang.to_string())
                }
            }
        };
        self.state.active_element = Some(ActiveElement::CodeBlock(state::CodeBlockState {
            language,
            content: String::new(),
        }));
    }

    pub fn clear_code_block(&mut self) {
        self.clear_active_element();
    }

    pub fn set_table(&mut self, alignments: Vec<pulldown_cmark::Alignment>) {
        self.state.active_element = Some(ActiveElement::Table(state::TableState {
            alignments,
            current_row: Vec::new(),
            is_header: true,
        }));
    }

    pub fn clear_table(&mut self) {
        self.clear_active_element();
    }

    pub fn push_list(&mut self, start: Option<u64>) {
        let list_type = if let Some(n) = start {
            state::ListType::Ordered {
                current: n as usize,
            }
        } else {
            state::ListType::Unordered
        };
        self.state.list_stack.push(list_type);
    }

    pub fn pop_list(&mut self) {
        self.state.list_stack.pop();
    }

    /// Load and render Markdown content from a file
    ///
    /// # Performance Optimizations
    /// - Pre-allocate memory based on file size
    /// - Efficient reading delegated to io module
    ///
    /// # Error Handling
    /// - Returns detailed error message if file doesn't exist
    pub fn render_file(&mut self, path: &Path) -> Result<()> {
        let content = read_file(path)?;
        self.render_content(&content)
    }

    /// Render Markdown content directly
    ///
    /// # Processing Flow
    /// 1. Parse Markdown with pulldown_cmark
    /// 2. Process each event
    /// 3. Convert to terminal format
    pub fn render_content(&mut self, content: &str) -> Result<()> {
        let parser = Parser::new_ext(content, self.options);

        for event in parser {
            self.process_event(event)?;
        }

        self.flush()?;
        Ok(())
    }

    /// Flush any remaining buffers
    pub fn flush(&mut self) -> Result<()> {
        if let Some(code_block) = self.get_code_block() {
            self.clear_active_element();
            self.render_code_block(&code_block)?;
        }
        Ok(())
    }
}

// Tests module is defined in tests.rs
#[cfg(test)]
mod tests;
