//! Block-level rendering tests: headings, lists (ordered, unordered, task),
//! blockquotes, blank-line handling, hard breaks, list continuation,
//! and paragraph wrapping.
//!
//! These are end-to-end tests of `renderMarkdown` extracted from
//! render.zig to keep that file focused on the orchestrator code.
//! Every test calls `renderToOwnedSlice` from render_test_helpers.zig.

const std = @import("std");
const renderToOwnedSlice = @import("render_test_helpers.zig").renderToOwnedSlice;

test "renderMarkdown strips heading markers and preserves structure" {
    const allocator = std.testing.allocator;
    const source =
        \\# Title
        \\
        \\- item
        \\> quoted
        \\[link](https://example.com)
        \\```zig
        \\const value = 1;
        \\```
        \\
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\Title
        \\
        \\- item
        \\│ quoted
        \\link(https://example.com)
        \\```zig
        \\const value = 1;
        \\```
        \\
    ,
        rendered,
    );
}

test "renderMarkdown emits Solarized Dark ANSI styling for headings and links" {
    const allocator = std.testing.allocator;
    const source =
        \\# Title
        \\[link](https://example.com)
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // link text: underline + link color; URL: dim + muted color (parens rendered separately)
    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[4m\x1b[38;2;181;137;0mTitle\x1b[0m\n" ++
            "\x1b[4m\x1b[38;2;108;113;196mlink\x1b[0m" ++
            "\x1b[2m\x1b[38;2;88;110;117m(\x1b[0m" ++
            "\x1b[2m\x1b[38;2;88;110;117mhttps://example.com\x1b[0m" ++
            "\x1b[2m\x1b[38;2;88;110;117m)\x1b[0m",
        rendered,
    );
}

test "nested blockquotes render with multiple vertical bar markers" {
    const allocator = std.testing.allocator;
    const source = "> > nested\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("│ │ nested\n", rendered);
}

test "heading levels produce different ANSI styles" {
    const allocator = std.testing.allocator;
    const source = "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // h1: bold + underline + yellow
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[4m\x1b[38;2;181;137;0m"));
    // h2: bold + underline + orange
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[4m\x1b[38;2;203;75;22m"));
    // h3: bold + blue (no underline)
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[38;2;38;139;210m"));
    // h4: bold + cyan
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[38;2;42;161;152m"));
    // h5: violet (no bold, no dim)
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;108;113;196mH5\x1b[0m"));
    // h6: dim + violet
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[2m\x1b[38;2;108;113;196mH6\x1b[0m"));
}

test "ordered list items are rendered with number markers" {
    const allocator = std.testing.allocator;
    const source =
        \\1. First item
        \\2. Second item
        \\3. Third item
        \\
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\1. First item
        \\2. Second item
        \\3. Third item
        \\
    ,
        rendered,
    );
}

test "ordered list with closing paren marker" {
    const allocator = std.testing.allocator;
    const source = "1) Item one\n2) Item two\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1) Item one\n2) Item two\n", rendered);
}

test "ordered list with indentation" {
    const allocator = std.testing.allocator;
    const source = "  1. Indented ordered item\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("  1. Indented ordered item\n", rendered);
}

test "ordered list with multi-digit numbers" {
    const allocator = std.testing.allocator;
    const source = "10. Tenth item\n999999999. Max digits\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("10. Tenth item\n999999999. Max digits\n", rendered);
}

test "ordered list rejects more than 9 digits" {
    const allocator = std.testing.allocator;
    const source = "1234567890. Too many digits\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1234567890. Too many digits\n", rendered);
}

test "ordered list items get ANSI styling" {
    const allocator = std.testing.allocator;
    const source = "1. Styled item\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // Number marker should have list_marker color (teal: 42, 161, 152) + bold
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[38;2;42;161;152m1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Styled item"));
}

test "task list items render checkbox indicators" {
    const allocator = std.testing.allocator;
    const source =
        \\- [x] Completed task
        \\- [ ] Incomplete task
        \\- Regular item
        \\
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\- [x] Completed task
        \\- [ ] Incomplete task
        \\- Regular item
        \\
    ,
        rendered,
    );
}

test "task list with uppercase X" {
    const allocator = std.testing.allocator;
    const source = "- [X] Done\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- [x] Done\n", rendered);
}

test "ordered task list items" {
    const allocator = std.testing.allocator;
    const source = "1. [x] First done\n2. [ ] Second pending\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1. [x] First done\n2. [ ] Second pending\n", rendered);
}

test "task list items get ANSI styling" {
    const allocator = std.testing.allocator;
    const source = "- [x] Done\n- [ ] Todo\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // Checked: [x] should have list_marker color (teal: 42, 161, 152)
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;42;161;152m[x] "));
    // Unchecked: [ ] should have muted + dim
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[2m\x1b[38;2;88;110;117m[ ] "));
}

test "task list with tab separator" {
    const allocator = std.testing.allocator;
    const source = "- [x]\tTab-separated task\n- [\t] Tab in checkbox\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "[x] "));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "[ ] "));
}

test "empty ordered list item" {
    const allocator = std.testing.allocator;
    const source = "1. First\n2.\n3. Third\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    // "2." renders as "2. " because the marker includes trailing space
    try std.testing.expectEqualStrings("1. First\n2. \n3. Third\n", rendered);
}

test "nested task list items" {
    const allocator = std.testing.allocator;
    const source = "- [x] Parent\n  - [ ] Child\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- [x] Parent\n  - [ ] Child\n", rendered);
}

test "tab-indented headings and blockquotes are recognized" {
    const allocator = std.testing.allocator;
    const source = "\t# Tab Heading\n\t> Tab Quote\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Tab Heading"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Tab Quote"));
}

test "consecutive blank lines are collapsed to one" {
    const allocator = std.testing.allocator;
    const source = "First\n\n\n\nSecond\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("First\n\nSecond\n", rendered);
}

test "single blank line between paragraphs is preserved" {
    const allocator = std.testing.allocator;
    const source = "First\n\nSecond\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("First\n\nSecond\n", rendered);
}

test "hard break trailing spaces are stripped" {
    const allocator = std.testing.allocator;
    const source = "Line one  \nLine two\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Line one\nLine two\n", rendered);
}

test "hard break with backslash at end of line" {
    const allocator = std.testing.allocator;
    const source = "Line one\\\nLine two\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Line one\nLine two\n", rendered);
}

test "single trailing space is preserved" {
    const allocator = std.testing.allocator;
    const source = "Line with one trailing space \nNext line\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    // Only 1 trailing space — not a hard break, should be preserved
    try std.testing.expectEqualStrings("Line with one trailing space \nNext line\n", rendered);
}

test "blank lines between different block elements are normalized" {
    const allocator = std.testing.allocator;
    const source = "# Heading\n\n\n\nParagraph\n\n\n- list\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Heading\n\nParagraph\n\n- list\n", rendered);
}

test "unordered list continuation line" {
    const allocator = std.testing.allocator;
    const source = "- first line\n  continued here\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- first line\n  continued here\n", rendered);
}

test "unordered list multiple continuation lines" {
    const allocator = std.testing.allocator;
    const source = "- first\n  second\n  third\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- first\n  second\n  third\n", rendered);
}

test "ordered list continuation line" {
    const allocator = std.testing.allocator;
    const source = "1. first line\n   continued here\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1. first line\n   continued here\n", rendered);
}

test "continuation stops at unindented line" {
    const allocator = std.testing.allocator;
    const source = "- first\n  continued\nnot continued\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- first\n  continued\nnot continued\n", rendered);
}

test "continuation stops at blank line" {
    const allocator = std.testing.allocator;
    const source = "- first\n\n  not continued\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- first\n\n  not continued\n", rendered);
}

test "continuation stops at nested list item" {
    const allocator = std.testing.allocator;
    const source = "- parent\n  - child\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- parent\n  - child\n", rendered);
}

test "ordered list multi-digit continuation" {
    const allocator = std.testing.allocator;
    const source = "10. first line\n    continued\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("10. first line\n    continued\n", rendered);
}

test "continuation with emphasis in continued line" {
    const allocator = std.testing.allocator;
    const source = "- start\n  **bold** continued\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- start\n  bold continued\n", rendered);
}

test "paragraph wraps at wrap_width" {
    const allocator = std.testing.allocator;
    const source = "Hello World";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .wrap_width = 8 });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Hello\nWorld", rendered);
}

test "paragraph no wrap when wrap_width is null" {
    const allocator = std.testing.allocator;
    const source = "This is a long paragraph that should not be wrapped";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is a long paragraph that should not be wrapped", rendered);
}

test "heading is not wrapped" {
    const allocator = std.testing.allocator;
    const source = "# This is a heading that is long";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .wrap_width = 10 });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is a heading that is long", rendered);
}

test "CRLF input renders ATX heading without trailing carriage return" {
    const allocator = std.testing.allocator;
    const source = "# Title\r\nbody\r\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Title\nbody\n", rendered);
}

test "CRLF input preserves list continuation" {
    const allocator = std.testing.allocator;
    const source = "- first line\r\n  continued here\r\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- first line\n  continued here\n", rendered);
}
