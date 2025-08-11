// Import common test utilities
mod common;

use common::{TestCase, generate_large_markdown_content, run_data_driven_tests};

#[test]
fn test_render_complex_markdown_file() {
    let content = r#"# Test Document

This is a test with **bold** and *italic* text.

## Features

- List item 1
- List item 2
  - Nested item

```rust
fn main() {
    println!("Hello, World!");
}
```

> Quote text

| Header 1 | Header 2 |
|----------|----------|
| Cell 1   | Cell 2   |

[Link](https://example.com) and `inline code`.

---

Final paragraph."#;

    let test_case = TestCase::new("complex_markdown_file", content)
        .with_description("Complex markdown document with all features");

    run_data_driven_tests(vec![test_case]);
}

#[test]
fn test_empty_file() {
    let test_case = TestCase::new("empty_file", "").with_description("Empty markdown file");

    run_data_driven_tests(vec![test_case]);
}

#[test]
fn test_large_file_handling() {
    let content = generate_large_markdown_content(1000);
    let test_case = TestCase::new("large_file_1000_lines", content)
        .with_description("Large markdown file with 1000 lines");

    run_data_driven_tests(vec![test_case]);
}

#[test]
fn test_various_markdown_features() {
    let test_cases = vec![
        TestCase::new("nested_lists", "- Item 1\n  - Nested 1\n    - Double nested\n  - Nested 2")
            .with_description("Testing nested list rendering"),
        TestCase::new("mixed_formatting", "**Bold _and italic_ text**")
            .with_description("Mixed emphasis formatting"),
        TestCase::new("complex_table", "| Col1 | Col2 | Col3 |\n|------|------|------|\n| A    | B    | C    |\n| D    | E    | F    |")
            .with_description("Multi-column table"),
        TestCase::new("fenced_code_with_lang", "```python\nprint('Hello')\n```")
            .with_description("Fenced code with language"),
    ];

    run_data_driven_tests(test_cases);
}
