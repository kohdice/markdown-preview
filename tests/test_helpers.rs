/// Test helpers module for markdown-preview tests
/// Contains common assertion macros and test utilities
/// Macro for asserting successful rendering of markdown content
#[macro_export]
macro_rules! assert_renders_successfully {
    ($content:expr) => {{
        use mp_stdout::MarkdownRenderer;
        let mut renderer = MarkdownRenderer::new();
        let result = renderer.render_content($content);
        assert!(
            result.is_ok(),
            "Failed to render markdown: {:?}",
            result.err()
        );
        result.unwrap()
    }};
    ($content:expr, $description:expr) => {{
        use mp_stdout::MarkdownRenderer;
        let mut renderer = MarkdownRenderer::new();
        let result = renderer.render_content($content);
        assert!(
            result.is_ok(),
            "Failed to render '{}': {:?}",
            $description,
            result.err()
        );
        result.unwrap()
    }};
}

/// Macro for asserting that rendered output contains expected text
#[macro_export]
macro_rules! assert_output_contains {
    ($output:expr, $expected:expr) => {
        assert!(
            $output.contains($expected),
            "Output does not contain expected text '{}'\nActual output: {}",
            $expected,
            $output
        );
    };
}

/// Macro for asserting that rendered output does not contain text
#[macro_export]
macro_rules! assert_output_not_contains {
    ($output:expr, $unexpected:expr) => {
        assert!(
            !$output.contains($unexpected),
            "Output unexpectedly contains text '{}'\nActual output: {}",
            $unexpected,
            $output
        );
    };
}
