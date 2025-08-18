mod common;
mod test_helpers;

use rstest::rstest;

use common::{TestCase, generate_large_markdown_content, run_data_driven_tests};

#[rstest]
#[case::heading1("# Heading 1")]
#[case::heading2("## Heading 2")]
#[case::heading3("### Heading 3")]
#[case::bold("**bold text**")]
#[case::italic("*italic text*")]
#[case::code("`inline code`")]
#[case::list_unordered("- Item 1\n- Item 2")]
#[case::list_ordered("1. First\n2. Second")]
#[case::blockquote("> This is a quote")]
#[case::horizontal_rule("---")]
#[case::link("[Link text](https://example.com)")]
#[case::code_block("```\ncode block\n```")]
#[case::code_block_rust("```rust\nfn main() {}\n```")]
fn test_basic_markdown_rendering(#[case] content: &str) {
    let test_case =
        TestCase::new("basic_markdown", content).with_description("Testing basic markdown element");
    run_data_driven_tests(vec![test_case]);
}

#[rstest]
#[case::nested_lists("- Item 1\n  - Nested 1\n    - Double nested\n  - Nested 2")]
#[case::mixed_emphasis("**Bold _and italic_ text**")]
#[case::simple_table("| Col1 | Col2 |\n|------|------|\n| A    | B    |")]
#[case::aligned_table(
    "| Left | Center | Right |\n|:-----|:------:|------:|\n| A    | B      | C     |"
)]
#[case::combined_features("# Title\n\n**Bold** and *italic* with `code`.\n\n> Quote\n\n- List")]
fn test_complex_markdown_features(#[case] content: &str) {
    let test_case = TestCase::new("complex_markdown", content)
        .with_description("Testing complex markdown combinations");
    run_data_driven_tests(vec![test_case]);
}

#[rstest]
#[case::empty("")]
#[case::whitespace_only("   \n\t\n   ")]
#[case::single_char("a")]
#[case::unicode("こんにちは 🦀 Rust")]
#[case::html_entities("&lt;div&gt; &amp; &quot;text&quot;")]
#[case::unclosed_emphasis("**unclosed bold")]
#[case::deeply_nested("- 1\n  - 2\n    - 3\n      - 4\n        - 5")]
fn test_edge_cases(#[case] content: &str) {
    let test_case =
        TestCase::new("edge_case", content).with_description("Testing edge case scenarios");
    run_data_driven_tests(vec![test_case]);
}

#[test]
fn test_comprehensive_markdown_document() {
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

    let test_case = TestCase::new("comprehensive_document", content)
        .with_description("Comprehensive markdown document with all features");

    run_data_driven_tests(vec![test_case]);
}

#[test]
fn test_large_file_performance() {
    let sizes = vec![100, 500, 1000];
    let test_cases: Vec<TestCase> = sizes
        .into_iter()
        .map(|size| {
            TestCase::new(
                format!("large_file_{}_lines", size),
                generate_large_markdown_content(size),
            )
            .with_description(format!("Large markdown file with {} lines", size))
        })
        .collect();

    run_data_driven_tests(test_cases);
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
