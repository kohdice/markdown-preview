use std::io::{Stdout, Write};

use pulldown_cmark::Options;

use mp_core::theme::SolarizedOsaka;

use crate::{BufferedOutput, MarkdownRenderer, RenderConfig, RenderState};

/// # Example
/// ```
/// use mp_stdout::RendererBuilder;
/// use mp_core::theme::SolarizedOsaka;
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
    writer: Option<W>,
    buffer_size: Option<usize>,
    enable_strikethrough: bool,
    enable_tables: bool,
    enable_tasklists: bool,
    enable_footnotes: bool,
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
            writer: None,
            buffer_size: None,
            enable_strikethrough: true,
            enable_tables: true,
            enable_tasklists: true,
            enable_footnotes: true,
        }
    }

    pub fn build(self) -> MarkdownRenderer<Stdout> {
        let options = self.build_options();

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

impl<W: Write> RendererBuilder<W> {
    pub fn with_writer(writer: W) -> Self {
        Self {
            theme: None,
            options: None,
            config: None,
            writer: Some(writer),
            buffer_size: None,
            enable_strikethrough: true,
            enable_tables: true,
            enable_tasklists: true,
            enable_footnotes: true,
        }
    }

    fn build_options(&self) -> Options {
        self.options.unwrap_or_else(|| {
            let mut opts = Options::empty();
            if self.enable_strikethrough {
                opts.insert(Options::ENABLE_STRIKETHROUGH);
            }
            if self.enable_tables {
                opts.insert(Options::ENABLE_TABLES);
            }
            if self.enable_tasklists {
                opts.insert(Options::ENABLE_TASKLISTS);
            }
            if self.enable_footnotes {
                opts.insert(Options::ENABLE_FOOTNOTES);
            }
            opts
        })
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

    pub fn enable_tasklists(mut self, enable: bool) -> Self {
        self.enable_tasklists = enable;
        self
    }

    pub fn enable_footnotes(mut self, enable: bool) -> Self {
        self.enable_footnotes = enable;
        self
    }

    pub fn options(mut self, options: Options) -> Self {
        self.options = Some(options);
        self
    }

    pub fn build_with_writer(self) -> MarkdownRenderer<W> {
        let options = self.build_options();

        let writer = self
            .writer
            .expect("Writer must be provided via with_writer()");
        let output = if let Some(size) = self.buffer_size {
            BufferedOutput::with_capacity(size, writer)
        } else {
            BufferedOutput::new(writer)
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
        assert!(renderer.options.contains(Options::ENABLE_TASKLISTS));
        assert!(renderer.options.contains(Options::ENABLE_FOOTNOTES));
    }

    #[test]
    fn test_builder_custom_options() {
        let renderer = RendererBuilder::new()
            .enable_strikethrough(false)
            .enable_tables(true)
            .enable_tasklists(true)
            .enable_footnotes(false)
            .build();

        assert!(!renderer.options.contains(Options::ENABLE_STRIKETHROUGH));
        assert!(renderer.options.contains(Options::ENABLE_TABLES));
        assert!(renderer.options.contains(Options::ENABLE_TASKLISTS));
        assert!(!renderer.options.contains(Options::ENABLE_FOOTNOTES));
    }

    #[test]
    fn test_builder_with_buffer_size() {
        let renderer = RendererBuilder::new().buffer_size(32 * 1024).build();
        assert!(renderer.options.contains(Options::ENABLE_TABLES));
    }

    #[test]
    fn test_builder_with_custom_config() {
        let config = RenderConfig::default();
        let renderer = RendererBuilder::new().config(config.clone()).build();
        assert_eq!(renderer.config.table_separator, config.table_separator);
    }

    #[test]
    fn test_builder_with_custom_writer() {
        let writer = Vec::with_capacity(256);
        let renderer = RendererBuilder::with_writer(writer)
            .enable_tables(false)
            .build_with_writer();

        assert!(!renderer.options.contains(Options::ENABLE_TABLES));
        assert!(renderer.options.contains(Options::ENABLE_STRIKETHROUGH));
    }
}
