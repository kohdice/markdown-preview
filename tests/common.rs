#![allow(dead_code)]

use mp_renderer::{MarkdownRenderer, BufferedOutput};
use std::io::Write;
use std::sync::{Arc, Mutex};

/// Mock writer for testing that captures output to a buffer
pub struct MockWriter {
    buffer: Arc<Mutex<Vec<u8>>>,
}

impl MockWriter {
    pub fn new() -> (Self, Arc<Mutex<Vec<u8>>>) {
        let buffer = Arc::new(Mutex::new(Vec::new()));
        (
            MockWriter {
                buffer: Arc::clone(&buffer),
            },
            buffer,
        )
    }

    pub fn new_with_buffer(buffer: Arc<Mutex<Vec<u8>>>) -> Self {
        MockWriter { buffer }
    }
}

impl Write for MockWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let mut buffer = self.buffer.lock().unwrap();
        buffer.extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Create a test renderer that outputs to a buffer instead of stdout
#[cfg(not(test))]
pub fn create_test_renderer() -> MarkdownRenderer {
    MarkdownRenderer::new()
}

/// Create a test renderer that outputs to a buffer instead of stdout
#[cfg(test)]
pub fn create_test_renderer() -> MarkdownRenderer<MockWriter> {
    let buffer = Arc::new(Mutex::new(Vec::new()));
    let mock_writer = MockWriter::new_with_buffer(buffer);
    let output = BufferedOutput::new(mock_writer);
    MarkdownRenderer::with_output(output)
}

/// Create a test renderer with access to the output buffer
#[cfg(test)]
pub fn create_test_renderer_with_buffer() -> (MarkdownRenderer<MockWriter>, Arc<Mutex<Vec<u8>>>) {
    let buffer = Arc::new(Mutex::new(Vec::new()));
    let mock_writer = MockWriter::new_with_buffer(Arc::clone(&buffer));
    let output = BufferedOutput::new(mock_writer);
    (MarkdownRenderer::with_output(output), buffer)
}

/// Test case struct for data-driven testing
#[derive(Debug, Clone)]
pub struct TestCase {
    pub name: String,
    pub input: String,
    pub description: Option<String>,
}

impl TestCase {
    pub fn new(name: impl Into<String>, input: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            input: input.into(),
            description: None,
        }
    }

    pub fn with_description(mut self, desc: impl Into<String>) -> Self {
        self.description = Some(desc.into());
        self
    }
}

/// Test Markdown rendering in data-driven format
pub fn run_data_driven_tests(test_cases: Vec<TestCase>) {
    for case in test_cases {
        let mut renderer = create_test_renderer();
        let result = renderer.render_content(&case.input);

        assert!(
            result.is_ok(),
            "Test '{}' failed: {:?}. Input: '{}'. Description: {}",
            case.name,
            result.err(),
            case.input.trim(),
            case.description
                .as_ref()
                .unwrap_or(&"No description".to_string())
        );
    }
}

/// Helper for HTML entities testing
pub fn create_html_entity_test_cases() -> Vec<TestCase> {
    vec![
        TestCase::new("less_than", "&lt;").with_description("Less than symbol"),
        TestCase::new("greater_than", "&gt;").with_description("Greater than symbol"),
        TestCase::new("ampersand", "&amp;").with_description("Ampersand"),
        TestCase::new("quote", "&quot;").with_description("Double quote"),
        TestCase::new("apostrophe", "&#39;").with_description("Apostrophe"),
        TestCase::new("nbsp", "&nbsp;").with_description("Non-breaking space"),
        TestCase::new("copyright", "&copy;").with_description("Copyright symbol"),
        TestCase::new("registered", "&reg;").with_description("Registered trademark"),
        TestCase::new("euro", "&euro;").with_description("Euro symbol"),
        TestCase::new(
            "mixed_entities",
            "Text with &lt;tags&gt; and &amp;symbols&amp;",
        )
        .with_description("Mixed HTML entities in text"),
    ]
}

/// Helper for CommonMark compliance testing
pub fn create_commonmark_test_cases() -> Vec<(String, Vec<&'static str>)> {
    vec![
        (
            "headings".to_string(),
            vec![
                "# H1\n",
                "## H2\n",
                "### H3\n",
                "#### H4\n",
                "##### H5\n",
                "###### H6\n",
                "####### H7\n",
            ],
        ),
        (
            "emphasis".to_string(),
            vec![
                "*italic*",
                "_italic_",
                "**bold**",
                "__bold__",
                "***bold italic***",
                "___bold italic___",
            ],
        ),
        (
            "code_spans".to_string(),
            vec!["`code`", "``code with ` backtick``", "` code with spaces `"],
        ),
        (
            "links".to_string(),
            vec![
                "[link](http://example.com)",
                "[link with title](http://example.com \"title\")",
                "<http://example.com>",
            ],
        ),
        (
            "lists".to_string(),
            vec![
                "- item 1\n- item 2",
                "* item 1\n* item 2",
                "+ item 1\n+ item 2",
                "1. first\n2. second",
                "1) first\n2) second",
            ],
        ),
        (
            "blockquotes".to_string(),
            vec!["> quote", "> line 1\n> line 2", "> > nested"],
        ),
        (
            "code_blocks".to_string(),
            vec![
                "```\ncode\n```",
                "```rust\nfn main() {}\n```",
                "    indented code",
            ],
        ),
        (
            "horizontal_rules".to_string(),
            vec!["---", "***", "___", "- - -", "* * *"],
        ),
    ]
}

/// Helper for large file testing
pub fn generate_large_markdown_content(lines: usize) -> String {
    // Performance optimization: pre-allocate based on estimated line length
    let mut content = String::with_capacity(lines * 40);
    for i in 0..lines {
        content.push_str(&format!("## Heading {}\n\nParagraph text {}\n\n", i, i));
    }
    content
}

/// Helper for performance testing
pub fn measure_render_performance<F>(
    name: &str,
    content: &str,
    mut test_fn: F,
) -> std::time::Duration
where
    F: FnMut(&str) -> anyhow::Result<()>,
{
    use std::time::Instant;

    let start = Instant::now();
    let result = test_fn(content);
    let duration = start.elapsed();

    assert!(
        result.is_ok(),
        "Performance test '{}' failed: {:?}",
        name,
        result.err()
    );

    duration
}
