const std = @import("std");
const renderToOwnedSlice = @import("../helpers/render_from_source.zig").renderToOwnedSlice;

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
        \\• item
        \\│ quoted
        \\│ link(https://example.com)
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

    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[4m\x1b[38;2;181;137;0mTitle\x1b[0m\n" ++
            "\x1b[4m\x1b[38;2;108;113;196mlink\x1b[0m" ++
            "\x1b[2m\x1b[38;2;88;110;117m(https://example.com)\x1b[0m",
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

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[4m\x1b[38;2;181;137;0m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[4m\x1b[38;2;203;75;22m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[38;2;38;139;210m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[38;2;42;161;152m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;108;113;196mH5\x1b[0m"));
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
        \\• ☑ Completed task
        \\• ☐ Incomplete task
        \\• Regular item
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

    try std.testing.expectEqualStrings("• ☑ Done\n", rendered);
}

test "ordered task list items" {
    const allocator = std.testing.allocator;
    const source = "1. [x] First done\n2. [ ] Second pending\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1. ☑ First done\n2. ☐ Second pending\n", rendered);
}

test "task list items get ANSI styling" {
    const allocator = std.testing.allocator;
    const source = "- [x] Done\n- [ ] Todo\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;42;161;152m☑ "));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[2m\x1b[38;2;88;110;117m☐ "));
}

test "task list with tab separator" {
    const allocator = std.testing.allocator;
    const source = "- [x]\tTab-separated task\n- [\t] Tab in checkbox\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "☑ "));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "☐ "));
}

test "empty ordered list item" {
    const allocator = std.testing.allocator;
    const source = "1. First\n2.\n3. Third\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1. First\n2. \n3. Third\n", rendered);
}

test "nested task list items" {
    const allocator = std.testing.allocator;
    const source = "- [x] Parent\n  - [ ] Child\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• ☑ Parent\n  ◦ ☐ Child\n", rendered);
}

test "tab-indented headings and blockquotes render as indented code" {
    const allocator = std.testing.allocator;
    const source = "\t# Tab Heading\n\t> Tab Quote\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("# Tab Heading\n> Tab Quote\n", rendered);
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

test "single trailing space is trimmed by inline parser" {
    const allocator = std.testing.allocator;
    const source = "Line with one trailing space \nNext line\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Line with one trailing space\nNext line\n", rendered);
}

test "blank lines between different block elements are normalized" {
    const allocator = std.testing.allocator;
    const source = "# Heading\n\n\n\nParagraph\n\n\n- list\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Heading\n\nParagraph\n\n• list\n", rendered);
}

test "unordered list continuation line" {
    const allocator = std.testing.allocator;
    const source = "- first line\n  continued here\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• first line\n  continued here\n", rendered);
}

test "unordered list multiple continuation lines" {
    const allocator = std.testing.allocator;
    const source = "- first\n  second\n  third\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• first\n  second\n  third\n", rendered);
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

    try std.testing.expectEqualStrings("• first\n  continued\nnot continued\n", rendered);
}

test "continuation stops at blank line" {
    const allocator = std.testing.allocator;
    const source = "- first\n\n  not continued\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• first\n\n  not continued\n", rendered);
}

test "continuation stops at nested list item" {
    const allocator = std.testing.allocator;
    const source = "- parent\n  - child\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• parent\n  ◦ child\n", rendered);
}

test "nested unordered list with multiple children preserves visual layout" {
    const allocator = std.testing.allocator;
    const source = "- parent\n  - child1\n  - child2\n- sibling\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "• parent\n  ◦ child1\n  ◦ child2\n• sibling\n",
        rendered,
    );
}

test "three-level deep unordered nesting renders with increasing indent" {
    const allocator = std.testing.allocator;
    const source = "- a\n  - b\n    - c\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• a\n  ◦ b\n    ▪ c\n", rendered);
}

test "ordered parent containing unordered child renders with column indent" {
    const allocator = std.testing.allocator;
    const source = "1. outer\n   - inner\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1. outer\n   ◦ inner\n", rendered);
}

test "list item with continuation line then nested list" {
    const allocator = std.testing.allocator;
    const source = "- first\n  continued\n  - nested\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "• first\n  continued\n  ◦ nested\n",
        rendered,
    );
}

test "paragraph after nested list stays inside outer list item" {
    const allocator = std.testing.allocator;
    const source = "- foo\n  - bar\n  baz\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• foo\n  ◦ bar\n  baz\n", rendered);
}

test "multi-space marker preserves byte-for-byte continuation rendering" {
    const allocator = std.testing.allocator;
    const source = "-   first\n    second\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• first\n  second\n", rendered);
}

test "blockquote containing unordered list renders as gutter plus list" {
    const allocator = std.testing.allocator;
    const source = "> - item\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("│ • item\n", rendered);
}

test "blockquote containing ordered list renders as gutter plus numbered markers" {
    const allocator = std.testing.allocator;
    const source = "> 1. foo\n> 2. bar\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("│ 1. foo\n│ 2. bar\n", rendered);
}

test "loose list with blank-separated paragraphs in same item" {
    const allocator = std.testing.allocator;
    const source = "- foo\n\n  bar\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• foo\n\n  bar\n", rendered);
}

test "loose list with blank-separated sibling items preserves blank line" {
    const allocator = std.testing.allocator;
    const source = "- foo\n\n- bar\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• foo\n\n• bar\n", rendered);
}

test "list item containing blockquote child renders with indented gutter" {
    const allocator = std.testing.allocator;
    const source = "- intro\n  > quoted child\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• intro\n  │ quoted child\n", rendered);
}

test "list item containing nested blockquote renders without double indent" {
    const allocator = std.testing.allocator;
    const source = "- foo\n  > > quoted\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• foo\n  │ │ quoted\n", rendered);
}

test "list item containing fenced code child renders with content-column indent" {
    const allocator = std.testing.allocator;
    const source = "- outer\n  ```\n  body\n  ```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• outer\n  ```\n  body\n  ```\n", rendered);
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

    try std.testing.expectEqualStrings("• start\n  bold continued\n", rendered);
}

test "paragraph wraps at wrap_width" {
    const allocator = std.testing.allocator;
    const source = "Hello World";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .wrap_width = 8 });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Hello\nWorld", rendered);
}

test "blockquote paragraph wraps at wrap_width" {
    const allocator = std.testing.allocator;
    const source = "> Alpha Beta Gamma Delta\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .wrap_width = 12 });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("│ Alpha Beta\n│ Gamma\n│ Delta\n", rendered);
}

test "list paragraph wraps with continuation alignment" {
    const allocator = std.testing.allocator;
    const source = "- Alpha Beta Gamma Delta\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .wrap_width = 12 });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• Alpha Beta\n  Gamma\n  Delta\n", rendered);
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

    try std.testing.expectEqualStrings("• first line\n  continued here\n", rendered);
}

test "unordered bullet depth cycles through level0 level1 level2 and wraps" {
    const allocator = std.testing.allocator;
    const source = "- a\n  - b\n    - c\n      - d\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• a\n  ◦ b\n    ▪ c\n      • d\n", rendered);
}

test "three-level list nesting accumulates depth across ordered and unordered" {
    const allocator = std.testing.allocator;
    const source = "- outer\n  1. middle\n     - deepest\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• outer\n  1. middle\n     ▪ deepest\n", rendered);
}

test "task checkbox inside nested list uses nested bullet glyph" {
    const allocator = std.testing.allocator;
    const source = "- top\n  - [x] nested done\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• top\n  ◦ ☑ nested done\n", rendered);
}

test "list inside blockquote child of list item inherits outer depth" {
    const allocator = std.testing.allocator;
    const source = "- outer\n  > - inner\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• outer\n  │ ◦ inner\n", rendered);
}

test "task list with continuation aligns under text in narrow mode" {
    const allocator = std.testing.allocator;
    const source = "- [x] task\n  cont\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• ☑ task\n    cont\n", rendered);
}

test "list continuation widens by one column in wide ambiguous mode" {
    const allocator = std.testing.allocator;
    const source = "- first line\n  continued\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .ambiguous_width = .wide });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• first line\n   continued\n", rendered);
}

test "nested list continuation widens in wide ambiguous mode" {
    const allocator = std.testing.allocator;
    const source = "- a\n  - b\n    cont\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .ambiguous_width = .wide });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• a\n  ◦ b\n     cont\n", rendered);
}

test "task checkbox continuation in wide mode accumulates bullet and checkbox width" {
    const allocator = std.testing.allocator;
    const source = "- [x] task\n  cont\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .ambiguous_width = .wide });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• ☑ task\n      cont\n", rendered);
}

test "list with blockquote child and continuation aligns in wide mode" {
    const allocator = std.testing.allocator;
    const source = "- outer\n  cont\n  > quote\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .ambiguous_width = .wide });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• outer\n   cont\n  │ quote\n", rendered);
}

test "narrow mode preserves byte-identical output for wide mode regression inputs" {
    const allocator = std.testing.allocator;

    const plain = try renderToOwnedSlice(allocator, "- first line\n  continued\n", .{});
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("• first line\n  continued\n", plain);

    const nested = try renderToOwnedSlice(allocator, "- a\n  - b\n    cont\n", .{});
    defer allocator.free(nested);
    try std.testing.expectEqualStrings("• a\n  ◦ b\n    cont\n", nested);

    const quoted = try renderToOwnedSlice(allocator, "- outer\n  cont\n  > quote\n", .{});
    defer allocator.free(quoted);
    try std.testing.expectEqualStrings("• outer\n  cont\n  │ quote\n", quoted);
}

test "thematic break renders as a solid box-drawing horizontal line" {
    const allocator = std.testing.allocator;
    const rendered = try renderToOwnedSlice(allocator, "---\n", .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("─" ** 32 ++ "\n", rendered);
}

test "thematic break uses muted palette color without dim attribute" {
    const allocator = std.testing.allocator;
    const rendered = try renderToOwnedSlice(allocator, "---\n", .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "\x1b[38;2;88;110;117m" ++ ("─" ** 32) ++ "\x1b[0m\n",
        rendered,
    );
    try std.testing.expect(std.mem.find(u8, rendered, "\x1b[2m") == null);
}
