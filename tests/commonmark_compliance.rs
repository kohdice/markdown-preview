mod common;

use common::{run_data_driven_tests, TestCase};

/// Data-driven test macro for better organization
macro_rules! data_driven_test {
    ($test_name:ident, [$( ($name:expr, $input:expr $(, $desc:expr)?) ),+ $(,)?]) => {
        #[test]
        fn $test_name() {
            let test_cases = vec![
                $(
                    TestCase::new($name, $input)
                    $(.with_description($desc))?
                ),+
            ];
            run_data_driven_tests(test_cases);
        }
    };
}

data_driven_test!(
    test_headings,
    [
        ("h1", "# H1\n", "Level 1 heading"),
        ("h2", "## H2\n", "Level 2 heading"),
        ("h3", "### H3\n", "Level 3 heading"),
        ("h4", "#### H4\n", "Level 4 heading"),
        ("h5", "##### H5\n", "Level 5 heading"),
        ("h6", "###### H6\n", "Level 6 heading"),
        (
            "h7_invalid",
            "####### H7\n",
            "More than 6 # characters don't create a heading"
        )
    ]
);

data_driven_test!(
    test_emphasis,
    [
        ("italic_asterisk", "*italic*", "Italic with asterisk"),
        ("italic_underscore", "_italic_", "Italic with underscore"),
        ("bold_asterisk", "**bold**", "Bold with asterisks"),
        ("bold_underscore", "__bold__", "Bold with underscores"),
        (
            "bold_italic_asterisk",
            "***bold italic***",
            "Bold italic with asterisks"
        ),
        (
            "bold_italic_underscore",
            "___bold italic___",
            "Bold italic with underscores"
        )
    ]
);

data_driven_test!(
    test_code_spans,
    [
        ("simple_code", "`code`", "Simple inline code"),
        (
            "code_with_backtick",
            "``code with ` backtick``",
            "Code containing backtick"
        ),
        (
            "code_with_spaces",
            "` code with spaces `",
            "Code with surrounding spaces"
        )
    ]
);

data_driven_test!(
    test_links,
    [
        ("simple_link", "[link](http://example.com)", "Simple link"),
        (
            "link_with_title",
            "[link with title](http://example.com \"title\")",
            "Link with title attribute"
        ),
        ("autolink", "<http://example.com>", "Autolink URL")
    ]
);

data_driven_test!(
    test_lists,
    [
        (
            "unordered_dash",
            "- item 1\n- item 2",
            "Unordered list with dashes"
        ),
        (
            "unordered_asterisk",
            "* item 1\n* item 2",
            "Unordered list with asterisks"
        ),
        (
            "unordered_plus",
            "+ item 1\n+ item 2",
            "Unordered list with plus signs"
        ),
        (
            "ordered_period",
            "1. first\n2. second",
            "Ordered list with periods"
        ),
        (
            "ordered_paren",
            "1) first\n2) second",
            "Ordered list with parentheses"
        )
    ]
);

data_driven_test!(
    test_blockquotes,
    [
        ("simple_quote", "> quote", "Simple blockquote"),
        (
            "multiline_quote",
            "> line 1\n> line 2",
            "Multi-line blockquote"
        ),
        ("nested_quote", "> > nested", "Nested blockquote")
    ]
);

data_driven_test!(
    test_code_blocks,
    [
        (
            "fenced_no_lang",
            "```\ncode\n```",
            "Fenced code block without language"
        ),
        (
            "fenced_with_lang",
            "```rust\nfn main() {}\n```",
            "Fenced code block with language"
        ),
        ("indented_code", "    indented code", "Indented code block")
    ]
);

data_driven_test!(
    test_horizontal_rules,
    [
        ("hr_dashes", "---", "Horizontal rule with dashes"),
        ("hr_asterisks", "***", "Horizontal rule with asterisks"),
        ("hr_underscores", "___", "Horizontal rule with underscores"),
        (
            "hr_spaced_dashes",
            "- - -",
            "Horizontal rule with spaced dashes"
        ),
        (
            "hr_spaced_asterisks",
            "* * *",
            "Horizontal rule with spaced asterisks"
        )
    ]
);

data_driven_test!(
    test_line_breaks,
    [
        (
            "hard_break_spaces",
            "line 1  \nline 2",
            "Hard break with two spaces"
        ),
        (
            "hard_break_backslash",
            "line 1\\\nline 2",
            "Hard break with backslash"
        ),
        ("soft_break", "line 1\nline 2", "Soft break (becomes space)")
    ]
);

data_driven_test!(
    test_escape_sequences,
    [
        ("escaped_asterisk", r"\*not italic\*", "Escaped asterisks"),
        (
            "escaped_underscore",
            r"\_not italic\_",
            "Escaped underscores"
        ),
        ("escaped_hash", r"\# not heading", "Escaped hash symbol"),
        (
            "escaped_brackets",
            r"\[not link\]",
            "Escaped square brackets"
        )
    ]
);

data_driven_test!(
    test_gfm_extensions,
    [
        ("strikethrough", "~~strikethrough~~", "Strikethrough text"),
        (
            "task_unchecked",
            "- [ ] unchecked",
            "Unchecked task list item"
        ),
        ("task_checked", "- [x] checked", "Checked task list item"),
        (
            "simple_table",
            "| header |\n|--------|\n| cell |",
            "Simple table"
        )
    ]
);

data_driven_test!(
    test_images,
    [
        (
            "image_with_alt",
            "![alt text](image.png)",
            "Image with alt text"
        ),
        (
            "image_without_alt",
            "![](image.png)",
            "Image without alt text (fallback)"
        )
    ]
);

data_driven_test!(
    test_html_entities,
    [
        ("less_than", "&lt;", "Less than symbol"),
        ("greater_than", "&gt;", "Greater than symbol"),
        ("ampersand", "&amp;", "Ampersand"),
        ("quote", "&quot;", "Double quote"),
        ("apostrophe", "&#39;", "Apostrophe"),
        ("nbsp", "&nbsp;", "Non-breaking space"),
        ("copyright", "&copy;", "Copyright symbol"),
        ("registered", "&reg;", "Registered trademark"),
        ("euro", "&euro;", "Euro symbol"),
        (
            "mixed",
            "Text with &lt;tags&gt; and &amp;symbols&amp;",
            "Mixed HTML entities"
        )
    ]
);
