/// Test helpers module for markdown-preview tests
/// Contains common assertion macros and test utilities
use markdown_preview::renderer::markdown::MarkdownRenderer;

/// Macro for asserting successful rendering of markdown content
#[macro_export]
macro_rules! assert_renders_successfully {
    ($content:expr) => {{
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

/// Helper function to render markdown and return stripped output
pub fn render_and_strip(content: &str) -> String {
    let mut renderer = MarkdownRenderer::new();
    // render_content returns Result<()>, so we capture stdout instead
    renderer
        .render_content(content)
        .expect("Failed to render markdown");
    // For now, return empty string since we can't capture stdout easily in tests
    String::new()
}

/// Strip ANSI color codes from output for testing
pub fn strip_ansi_codes(text: &str) -> String {
    let re = regex::Regex::new(r"\x1b\[[0-9;]*m").unwrap();
    re.replace_all(text, "").to_string()
}

/// Test data provider for common markdown elements
pub fn common_markdown_samples() -> Vec<(&'static str, &'static str)> {
    vec![
        ("heading1", "# Heading 1"),
        ("heading2", "## Heading 2"),
        ("heading3", "### Heading 3"),
        ("bold", "**bold text**"),
        ("italic", "*italic text*"),
        ("code", "`inline code`"),
        ("list_unordered", "- Item 1\n- Item 2"),
        ("list_ordered", "1. First\n2. Second"),
        ("blockquote", "> This is a quote"),
        ("horizontal_rule", "---"),
        ("link", "[Link text](https://example.com)"),
        ("image", "![Alt text](image.jpg)"),
        ("code_block", "```\ncode block\n```"),
        ("code_block_rust", "```rust\nfn main() {}\n```"),
    ]
}

/// Test data provider for complex markdown combinations
pub fn complex_markdown_samples() -> Vec<(&'static str, &'static str)> {
    vec![
        (
            "nested_lists",
            "- Item 1\n  - Nested 1\n    - Double nested\n  - Nested 2",
        ),
        ("mixed_emphasis", "**Bold _and italic_ text**"),
        (
            "table_simple",
            "| Col1 | Col2 |\n|------|------|\n| A    | B    |",
        ),
        (
            "table_alignment",
            "| Left | Center | Right |\n|:-----|:------:|------:|\n| A    | B      | C     |",
        ),
        (
            "combined_features",
            "# Title\n\n**Bold** and *italic* with `code`.\n\n> Quote\n\n- List",
        ),
    ]
}

/// Test data provider for edge cases
pub fn edge_case_samples() -> Vec<(&'static str, &'static str)> {
    vec![
        ("empty", ""),
        ("whitespace_only", "   \n\t\n   "),
        ("single_char", "a"),
        ("unicode", "こんにちは 🦀 Rust"),
        ("html_entities", "&lt;div&gt; &amp; &quot;text&quot;"),
        ("unclosed_emphasis", "**unclosed bold"),
        (
            "deeply_nested",
            "- 1\n  - 2\n    - 3\n      - 4\n        - 5",
        ),
    ]
}
