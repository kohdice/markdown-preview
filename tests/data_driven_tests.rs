mod common;

use common::{
    create_commonmark_test_cases, create_html_entity_test_cases, create_test_renderer,
    generate_large_markdown_content, measure_render_performance, run_data_driven_tests, TestCase,
};

/// Comprehensive data-driven tests for all CommonMark features
#[test]
fn test_all_commonmark_features() {
    let test_groups = create_commonmark_test_cases();

    for (group_name, cases) in test_groups {
        let test_cases: Vec<TestCase> = cases
            .into_iter()
            .enumerate()
            .map(|(i, input)| {
                TestCase::new(format!("{}_{}", group_name, i), input)
                    .with_description(format!("CommonMark {} test case {}", group_name, i))
            })
            .collect();
        run_data_driven_tests(test_cases);
    }
}

/// HTML entity tests using the data-driven approach
#[test]
fn test_html_entities_comprehensive() {
    let test_cases = create_html_entity_test_cases();
    run_data_driven_tests(test_cases);
}

/// Advanced markdown features
#[test]
fn test_advanced_markdown_features() {
    let test_cases = vec![
        TestCase::new(
            "deeply_nested_lists",
            "- Level 1\n  - Level 2\n    - Level 3\n      - Level 4\n        - Level 5",
        )
        .with_description("Testing deeply nested lists"),
        TestCase::new(
            "nested_blockquotes_with_content",
            "> First level\n> > Second level\n> > > Third level with **bold** text",
        )
        .with_description("Nested blockquotes with formatting"),
        TestCase::new(
            "blockquote_with_code",
            "> Quote with code:\n> ```rust\n> fn example() {}\n> ```",
        )
        .with_description("Blockquote containing code block"),
        TestCase::new(
            "aligned_table",
            "| Left | Center | Right |\n|:-----|:------:|------:|\n| A    |   B    |     C |",
        )
        .with_description("Table with column alignments"),
        TestCase::new(
            "task_list_mixed",
            "- [x] Completed task\n- [ ] Pending task\n- Regular item\n- [x] Another completed",
        )
        .with_description("Mixed task list and regular items"),
        TestCase::new(
            "strikethrough_with_emphasis",
            "~~deleted text~~ and **~~bold deleted~~**",
        )
        .with_description("Strikethrough with other formatting"),
        TestCase::new(
            "reference_style_links",
            "[link text][1]\n\n[1]: http://example.com \"Optional Title\"",
        )
        .with_description("Reference-style links"),
        TestCase::new("inline_html", "This is <span>inline HTML</span> text")
            .with_description("Inline HTML elements"),
        TestCase::new("various_escapes", r"\* \_ \` \~ \[ \] \( \) \# \+ \- \. \!")
            .with_description("Various escaped special characters"),
        TestCase::new(
            "unicode_content",
            "Unicode: 日本語 • Émojis: 🎉 🚀 • Math: ∑ ∫ √",
        )
        .with_description("Unicode characters and emojis"),
    ];

    run_data_driven_tests(test_cases);
}

/// Edge cases and boundary conditions
#[test]
fn test_edge_cases() {
    let test_cases = vec![
        TestCase::new("empty_emphasis", "****").with_description("Empty bold"),
        TestCase::new("empty_link", "[]()").with_description("Empty link"),
        TestCase::new("empty_code", "``").with_description("Empty inline code"),
        TestCase::new("unclosed_emphasis", "**unclosed").with_description("Unclosed bold"),
        TestCase::new("unclosed_code_block", "```\nunclosed")
            .with_description("Unclosed code block"),
        TestCase::new("long_line", "a".repeat(1000).as_str()).with_description("Very long line"),
        TestCase::new("null_chars", "Text\0with\0nulls").with_description("Null characters"),
        TestCase::new("tabs", "\t\tTabbed\tcontent").with_description("Tab characters"),
        TestCase::new("consecutive_hrs", "---\n---\n---").with_description("Multiple HRs"),
        TestCase::new("consecutive_quotes", "> Quote 1\n\n> Quote 2")
            .with_description("Consecutive blockquotes"),
    ];

    run_data_driven_tests(test_cases);
}

/// Performance test with generated content
#[test]
fn test_performance_with_large_content() {
    let sizes = vec![100, 500, 1000];

    for size in sizes {
        let content = generate_large_markdown_content(size);
        let test_case = TestCase::new(
            format!("large_content_{}_lines", size),
            content,
        )
        .with_description(format!("Performance test with {} lines", size));
        
        let duration = measure_render_performance(&test_case);

        // Performance target: 100 lines should complete within 1 second
        if size == 100 {
            assert!(
                duration.as_secs() < 1,
                "Performance issue: took {:?} to render {} lines",
                duration,
                size
            );
        }
    }
}
