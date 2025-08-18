//! Builder pattern implementation for MarkdownRenderer
//!
//! This module provides a builder pattern for constructing MarkdownRenderer instances
//! with custom configurations, demonstrating Rust's builder pattern implementation.

use std::io::{Stdout, Write};

use pulldown_cmark::Options;

use crate::renderer::{BufferedOutput, MarkdownRenderer, RenderConfig, RenderState};
use crate::theme::SolarizedOsaka;

/// Builder for creating configured MarkdownRenderer instances
///
/// # Example
/// ```
/// use markdown_preview::renderer::RendererBuilder;
/// use markdown_preview::theme::SolarizedOsaka;
///
/// let renderer = RendererBuilder::new()
///     .theme(SolarizedOsaka::default())
///     .enable_strikethrough(true)
///     .enable_tables(true)
///     .buffer_size(16 * 1024)
///     .build();
/// ```
pub struct RendererBuilder<W: Write = Stdout> {
    theme: Option<SolarizedOsaka>,
    options: Option<Options>,
    config: Option<RenderConfig>,
    #[allow(dead_code)]
    output: Option<BufferedOutput<W>>,
    buffer_size: Option<usize>,
    enable_strikethrough: bool,
    enable_tables: bool,
    enable_footnotes: bool,
    enable_tasklists: bool,
}

impl Default for RendererBuilder<Stdout> {
    fn default() -> Self {
        Self::new()
    }
}

impl RendererBuilder<Stdout> {
    pub fn new() -> Self {
        Self {
            theme: None,
            options: None,
            config: None,
            output: None,
            buffer_size: None,
            enable_strikethrough: true,
            enable_tables: true,
            enable_footnotes: true,
            enable_tasklists: true,
        }
    }
}

impl<W: Write> RendererBuilder<W> {
    pub fn with_writer(writer: W) -> Self {
        Self {
            theme: None,
            options: None,
            config: None,
            output: Some(BufferedOutput::new(writer)),
            buffer_size: None,
            enable_strikethrough: true,
            enable_tables: true,
            enable_footnotes: true,
            enable_tasklists: true,
        }
    }

    pub fn theme(mut self, theme: SolarizedOsaka) -> Self {
        self.theme = Some(theme);
        self
    }

    pub fn config(mut self, config: RenderConfig) -> Self {
        self.config = Some(config);
        self
    }

    pub fn buffer_size(mut self, size: usize) -> Self {
        self.buffer_size = Some(size);
        self
    }

    pub fn enable_strikethrough(mut self, enable: bool) -> Self {
        self.enable_strikethrough = enable;
        self
    }

    pub fn enable_tables(mut self, enable: bool) -> Self {
        self.enable_tables = enable;
        self
    }

    /// Enable or disable footnote parsing
    pub fn enable_footnotes(mut self, enable: bool) -> Self {
        self.enable_footnotes = enable;
        self
    }

    pub fn enable_tasklists(mut self, enable: bool) -> Self {
        self.enable_tasklists = enable;
        self
    }

    pub fn options(mut self, options: Options) -> Self {
        self.options = Some(options);
        self
    }
}

// Special implementation for Stdout to handle default case
impl RendererBuilder<Stdout> {
    pub fn build(self) -> MarkdownRenderer<Stdout> {
        let options = self.options.unwrap_or_else(|| {
            let mut opts = Options::empty();
            if self.enable_strikethrough {
                opts.insert(Options::ENABLE_STRIKETHROUGH);
            }
            if self.enable_tables {
                opts.insert(Options::ENABLE_TABLES);
            }
            if self.enable_footnotes {
                opts.insert(Options::ENABLE_FOOTNOTES);
            }
            if self.enable_tasklists {
                opts.insert(Options::ENABLE_TASKLISTS);
            }
            opts
        });

        let output = if let Some(size) = self.buffer_size {
            BufferedOutput::stdout_with_capacity(size)
        } else {
            BufferedOutput::stdout()
        };

        MarkdownRenderer {
            theme: self.theme.unwrap_or_default(),
            state: RenderState::default(),
            options,
            config: self.config.unwrap_or_default(),
            output,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_builder_default() {
        let renderer = RendererBuilder::new().build();
        assert!(renderer.options.contains(Options::ENABLE_STRIKETHROUGH));
        assert!(renderer.options.contains(Options::ENABLE_TABLES));
        assert!(renderer.options.contains(Options::ENABLE_FOOTNOTES));
        assert!(renderer.options.contains(Options::ENABLE_TASKLISTS));
    }

    #[test]
    fn test_builder_custom_options() {
        let renderer = RendererBuilder::new()
            .enable_strikethrough(false)
            .enable_tables(true)
            .enable_footnotes(false)
            .enable_tasklists(true)
            .build();

        assert!(!renderer.options.contains(Options::ENABLE_STRIKETHROUGH));
        assert!(renderer.options.contains(Options::ENABLE_TABLES));
        assert!(!renderer.options.contains(Options::ENABLE_FOOTNOTES));
        assert!(renderer.options.contains(Options::ENABLE_TASKLISTS));
    }

    #[test]
    fn test_builder_with_buffer_size() {
        let renderer = RendererBuilder::new().buffer_size(32 * 1024).build();
        // The buffer size is internal to BufferedOutput, so we can't directly test it
        // But we can verify the renderer is created successfully
        assert!(renderer.options.contains(Options::ENABLE_TABLES));
    }

    #[test]
    fn test_builder_with_custom_config() {
        let config = RenderConfig::default();
        let renderer = RendererBuilder::new().config(config.clone()).build();
        // Verify the renderer has the custom config
        assert_eq!(renderer.config.table_separator, config.table_separator);
    }
}
