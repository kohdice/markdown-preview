const std = @import("std");
const internals = @import("internals");
const renderToOwnedSlice = @import("../helpers/render_from_source.zig").renderToOwnedSlice;

test "simple table renders with aligned columns" {
    const allocator = std.testing.allocator;
    const source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "A"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "B"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "│"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "┌"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "├"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "└"));
}

test "table inside code fence is not detected" {
    const allocator = std.testing.allocator;
    const source = "```\n| A | B |\n| --- | --- |\n| 1 | 2 |\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "| A | B |"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "| --- | --- |"));
}

test "line with pipe but no delimiter row is not a table" {
    const allocator = std.testing.allocator;
    const source = "a | b\nnot a table\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("a | b\nnot a table\n", rendered);
}

test "blank line after table is preserved" {
    const allocator = std.testing.allocator;
    const source = "| A |\n| --- |\n| 1 |\n\nParagraph after table\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\n\nParagraph after table"));
}

test "table inside blockquote" {
    const allocator = std.testing.allocator;
    const source = "> | A | B |\n> | --- | --- |\n> | 1 | 2 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "│ "));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "A"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "B"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "2"));
    var line_iter = std.mem.splitScalar(u8, std.mem.trimEnd(u8, rendered, "\n"), '\n');
    while (line_iter.next()) |line| {
        try std.testing.expect(std.mem.startsWith(u8, line, "│ "));
    }
}

test "blockquote without table falls through to normal rendering" {
    const allocator = std.testing.allocator;
    const source = "> just a quote\n> another line\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("│ just a quote\n│ another line\n", rendered);
}

test "blockquote with pipe but no delimiter is not a table" {
    const allocator = std.testing.allocator;
    const source = "> a | b\n> c | d\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("│ a | b\n│ c | d\n", rendered);
}

test "blockquote table followed by normal blockquote" {
    const allocator = std.testing.allocator;
    const source = "> | A |\n> | --- |\n> | 1 |\n> normal text\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "A"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "normal text"));
}

test "CRLF input renders pipe table" {
    const allocator = std.testing.allocator;
    const source = "| A | B |\r\n| --- | --- |\r\n| 1 | 2 |\r\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "A"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "B"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "2"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "\r"));
}

test "CRLF input renders blockquote table" {
    const allocator = std.testing.allocator;
    const source = "> | A | B |\r\n> | --- | --- |\r\n> | 1 | 2 |\r\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "A"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "B"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "2"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "\r"));
    var line_iter = std.mem.splitScalar(u8, std.mem.trimEnd(u8, rendered, "\n"), '\n');
    while (line_iter.next()) |line| {
        try std.testing.expect(std.mem.startsWith(u8, line, "│ "));
    }
}

test "table renders with unicode top, middle, and bottom borders" {
    const allocator = std.testing.allocator;
    const source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "┌"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "┬"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "┐"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "├"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "┼"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "┤"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "└"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "┴"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "┘"));
}

test "table inserts inter-row borders between multiple body rows" {
    const allocator = std.testing.allocator;
    const source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 3, "┼"));
}

test "table with single body row has exactly one middle join" {
    const allocator = std.testing.allocator;
    const source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "┼"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 2, "┼"));
}

test "table with CJK content has uniform display width across all rows" {
    const allocator = std.testing.allocator;
    const source = "| 項目 | 値 |\n| --- | --- |\n| 日本語 | テスト |\n| ASCII | mixed 日本 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    var line_iter = std.mem.splitScalar(u8, std.mem.trimEnd(u8, rendered, "\n"), '\n');
    var expected_width: ?usize = null;
    while (line_iter.next()) |line| {
        const w = internals.term.terminal.displayWidth(line, .narrow);
        if (expected_width) |ew| {
            try std.testing.expectEqual(ew, w);
        } else {
            expected_width = w;
        }
    }
}

test "simple table golden output without ANSI" {
    const allocator = std.testing.allocator;
    const source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\┌─────┬─────┐
        \\│ A   │ B   │
        \\├─────┼─────┤
        \\│ 1   │ 2   │
        \\└─────┴─────┘
        \\
    ,
        rendered,
    );
}

test "header-only table golden output" {
    const allocator = std.testing.allocator;
    const source = "| A | B |\n| --- | --- |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\┌─────┬─────┐
        \\│ A   │ B   │
        \\├─────┼─────┤
        \\└─────┴─────┘
        \\
    ,
        rendered,
    );
}

test "blockquote table golden output" {
    const allocator = std.testing.allocator;
    const source = "> | A | B |\n> | --- | --- |\n> | 1 | 2 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\│ ┌─────┬─────┐
        \\│ │ A   │ B   │
        \\│ ├─────┼─────┤
        \\│ │ 1   │ 2   │
        \\│ └─────┴─────┘
        \\
    ,
        rendered,
    );
}

test "blockquote table with leading whitespace preserves indent" {
    const allocator = std.testing.allocator;
    const source = "  > | A | B |\n  > | --- | --- |\n  > | 1 | 2 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\  │ ┌─────┬─────┐
        \\  │ │ A   │ B   │
        \\  │ ├─────┼─────┤
        \\  │ │ 1   │ 2   │
        \\  │ └─────┴─────┘
        \\
    ,
        rendered,
    );
}

test "table in narrow mode renders byte-exact expected output" {
    const allocator = std.testing.allocator;
    const source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\┌─────┬─────┐
        \\│ A   │ B   │
        \\├─────┼─────┤
        \\│ 1   │ 2   │
        \\└─────┴─────┘
        \\
    ,
        rendered,
    );
}

test "table in wide mode renders byte-exact expected output" {
    const allocator = std.testing.allocator;
    const source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .ambiguous_width = .wide });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\┌───┬───┐
        \\│ A    │ B    │
        \\├───┼───┤
        \\│ 1    │ 2    │
        \\└───┴───┘
        \\
    ,
        rendered,
    );
}

test "table in wide mode with CJK cell renders byte-exact expected output" {
    const allocator = std.testing.allocator;
    const source = "| 日本語 | en |\n| --- | --- |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .ambiguous_width = .wide });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\┌────┬───┐
        \\│ 日本語 │ en   │
        \\├────┼───┤
        \\└────┴───┘
        \\
    ,
        rendered,
    );
}

test "table in wide mode with odd-width cell bumps correctly" {
    const allocator = std.testing.allocator;
    const source = "| abc | d |\n| --- | --- |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .ambiguous_width = .wide });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\┌───┬───┐
        \\│ abc  │ d    │
        \\├───┼───┤
        \\└───┴───┘
        \\
    ,
        rendered,
    );
}

test "table inside blockquote in wide mode renders byte-exact expected output" {
    const allocator = std.testing.allocator;
    const source = "> | A | B |\n> | --- | --- |\n> | 1 | 2 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .ambiguous_width = .wide });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\│ ┌───┬───┐
        \\│ │ A    │ B    │
        \\│ ├───┼───┤
        \\│ │ 1    │ 2    │
        \\│ └───┴───┘
        \\
    ,
        rendered,
    );
}

test "ragged table rows preserve empty trailing cells and ignore excess body cells" {
    const allocator = std.testing.allocator;
    const source =
        "| A | B | C |\n" ++
        "| --- | --- | --- |\n" ++
        "| 1 | 2 |\n" ++
        "| 3 | 4 | 5 | 6 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\┌─────┬─────┬─────┐
        \\│ A   │ B   │ C   │
        \\├─────┼─────┼─────┤
        \\│ 1   │ 2   │     │
        \\├─────┼─────┼─────┤
        \\│ 3   │ 4   │ 5   │
        \\└─────┴─────┴─────┘
        \\
    ,
        rendered,
    );
}

test "multiple tables in one document do not leak scratch state across shapes" {
    const allocator = std.testing.allocator;
    const source =
        "| A | B |\n" ++
        "| --- | --- |\n" ++
        "| 1 | 2 |\n" ++
        "\n" ++
        "| C | D | E | F |\n" ++
        "| --- | --- | --- | --- |\n" ++
        "| 3 | 4 | 5 | 6 |\n" ++
        "\n" ++
        "| G | H |\n" ++
        "| --- | --- |\n" ++
        "| 7 | 8 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\┌─────┬─────┐
        \\│ A   │ B   │
        \\├─────┼─────┤
        \\│ 1   │ 2   │
        \\└─────┴─────┘
        \\
        \\┌─────┬─────┬─────┬─────┐
        \\│ C   │ D   │ E   │ F   │
        \\├─────┼─────┼─────┼─────┤
        \\│ 3   │ 4   │ 5   │ 6   │
        \\└─────┴─────┴─────┴─────┘
        \\
        \\┌─────┬─────┐
        \\│ G   │ H   │
        \\├─────┼─────┤
        \\│ 7   │ 8   │
        \\└─────┴─────┘
        \\
    ,
        rendered,
    );
}
