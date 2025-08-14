//! Tests for the Markdown renderer

use super::*;
use pulldown_cmark::Options;
use rstest::rstest;

#[test]
fn test_renderer_creation() {
    let renderer = MarkdownRenderer::new();
    assert!(renderer.options.contains(Options::ENABLE_TABLES));
    assert!(renderer.options.contains(Options::ENABLE_STRIKETHROUGH));
    assert!(renderer.options.contains(Options::ENABLE_FOOTNOTES));
    assert!(renderer.options.contains(Options::ENABLE_TASKLISTS));
}

#[test]
fn test_state_change_application() {
    let mut renderer = MarkdownRenderer::new();

    renderer.set_strong_emphasis(true);
    assert!(renderer.state.emphasis.strong);

    renderer.set_italic_emphasis(true);
    assert!(renderer.state.emphasis.italic);

    renderer.set_strong_emphasis(false);
    assert!(!renderer.state.emphasis.strong);
    assert!(renderer.state.emphasis.italic);
}

#[rstest]
#[case(true, false, false)]
#[case(false, true, false)]
#[case(false, false, true)]
#[case(true, true, false)]
fn test_text_color_selection(#[case] strong: bool, #[case] italic: bool, #[case] has_link: bool) {
    let mut renderer = MarkdownRenderer::new();

    renderer.state.emphasis.strong = strong;
    renderer.state.emphasis.italic = italic;

    if has_link {
        renderer.set_link("test".to_string());
    }

    assert_eq!(renderer.state.emphasis.strong, strong);
    assert_eq!(renderer.state.emphasis.italic, italic);
    assert_eq!(renderer.has_link(), has_link);
}

#[test]
fn test_add_text_to_state() {
    let mut renderer = MarkdownRenderer::new();

    renderer.set_link("".to_string());
    assert!(renderer.add_text_to_state("link text"));
    assert_eq!(renderer.get_link().unwrap().text, "link text");

    renderer.clear_link();
    renderer.set_image("".to_string());
    assert!(renderer.add_text_to_state("alt text"));
    assert_eq!(renderer.get_image().unwrap().alt_text, "alt text");

    renderer.clear_image();
    renderer.set_code_block(pulldown_cmark::CodeBlockKind::Indented);
    assert!(renderer.add_text_to_state("code content"));
    assert_eq!(renderer.get_code_block().unwrap().content, "code content");

    renderer.clear_code_block();
    renderer.set_table(vec![]);
    assert!(renderer.add_text_to_state("cell content"));
    assert_eq!(renderer.get_table().unwrap().current_row[0], "cell content");

    renderer.clear_table();
    assert!(!renderer.add_text_to_state("regular text"));
}

#[test]
fn test_code_fence_creation() {
    let renderer = MarkdownRenderer::new();

    let fence = renderer.create_code_fence(None);
    assert!(fence.contains("```"));

    let fence_with_lang = renderer.create_code_fence(Some("rust"));
    assert!(fence_with_lang.contains("```"));
    assert!(fence_with_lang.contains("rust"));
}

fn assert_render_success(content: &str) {
    let mut renderer = MarkdownRenderer::new();
    let result = renderer.render_content(content);
    assert!(result.is_ok(), "Failed to render: {}", content);
}

#[rstest]
#[case("# Heading 1")]
#[case("## Heading 2")]
#[case("Normal paragraph text")]
#[case("**Bold text**")]
#[case("*Italic text*")]
#[case("[Link text](https://example.com)")]
#[case("`inline code`")]
fn test_basic_markdown_elements(#[case] content: &str) {
    assert_render_success(content);
}

#[rstest]
#[case("- Unordered list item")]
#[case("1. Ordered list item")]
#[case("- [ ] Task list unchecked")]
#[case("- [x] Task list checked")]
fn test_list_elements(#[case] content: &str) {
    assert_render_success(content);
}

#[rstest]
#[case("> Block quote")]
#[case("```rust\ncode block\n```")]
#[case("---")]
fn test_block_elements(#[case] content: &str) {
    assert_render_success(content);
}

#[test]
fn test_table_rendering() {
    let table = r#"
| Header 1 | Header 2 |
|----------|----------|
| Cell 1   | Cell 2   |
"#;
    assert_render_success(table);
}

#[test]
fn test_complex_markdown() {
    let content = r#"
# Main Title

This is a paragraph with **bold** and *italic* text.

## Features

- First feature
- Second feature with `inline code`
- Third feature

### Code Example

```rust
fn main() {
    println!("Hello, world!");
}
```

> This is a blockquote
> with multiple lines

| Column 1 | Column 2 |
|----------|----------|
| Data 1   | Data 2   |

[Visit our website](https://example.com)
"#;
    assert_render_success(content);
}
