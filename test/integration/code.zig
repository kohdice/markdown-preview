const std = @import("std");
const renderToOwnedSlice = @import("../helpers/render_from_source.zig").renderToOwnedSlice;

test "code fence with language preserves original format" {
    const allocator = std.testing.allocator;
    const source = "```python\nprint('hello')\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```python\nprint('hello')\n```\n", rendered);
}

test "code fence without language preserves format" {
    const allocator = std.testing.allocator;
    const source = "```\nplain code\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```\nplain code\n```\n", rendered);
}

test "code fence language is captured in Fence struct" {
    const allocator = std.testing.allocator;
    const source = "```javascript mocha\nconsole.log();\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```javascript mocha\nconsole.log();\n```\n", rendered);
}

test "zig code fence gets syntax highlighting under ANSI" {
    const allocator = std.testing.allocator;
    const source = "```zig\nconst x: u32 = 42;\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 2, "```"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "const"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "42"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;133;153;0m"));
}

test "zig code fence is plain text when ANSI disabled" {
    const allocator = std.testing.allocator;
    const source = "```zig\nconst x: u32 = 42;\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```zig\nconst x: u32 = 42;\n```\n", rendered);
}

test "unrecognized language falls back to uniform inline_code color" {
    const allocator = std.testing.allocator;
    const source = "```klingon\nQapla'!\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Qapla'!"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;42;161;152m"));
}

test "unclosed zig code fence at EOF is flushed" {
    const allocator = std.testing.allocator;
    const source = "```zig\nconst x = 1;\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "const x = 1;"));
}

test "empty code fence renders just the fences" {
    const allocator = std.testing.allocator;
    const source = "```zig\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```zig\n```\n", rendered);
}

test "code fence with syntax errors still renders (Tree-sitter error recovery)" {
    const allocator = std.testing.allocator;
    const source = "```zig\nconst x = @@@broken syntax;\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "const"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "broken"));
}

test "python code fence highlights with ANSI" {
    const allocator = std.testing.allocator;
    const source = "```python\ndef greet():\n    return 1\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "def"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "greet"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;"));
}

test "bash code fence uses sh alias" {
    const allocator = std.testing.allocator;
    const source = "```sh\necho hello\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "echo"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;"));
}

test "multiline zig raw string does not leak ANSI state across lines" {
    const allocator = std.testing.allocator;
    const source = "```zig\n" ++
        "const msg =\n" ++
        "    \\\\hello\n" ++
        "    \\\\world\n" ++
        ";\n" ++
        "```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "hello"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "world"));

    var reset_count: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, rendered, scan, "\x1b[0m")) |found| {
        reset_count += 1;
        scan = found + 4;
    }
    try std.testing.expect(reset_count > 0);
}

test "C0 control bytes inside a code fence are stripped by writeSanitized" {
    const allocator = std.testing.allocator;
    const source = "```zig\nconst x = \"\x1b[31mevil\\x07\";\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "\x1b[31m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "evil"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "\x07"));
}

test "python code fence is plain text when ANSI disabled" {
    const allocator = std.testing.allocator;
    const source = "```python\ndef greet():\n    return 1\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(source, rendered);
}

test "bash code fence is plain text when ANSI disabled" {
    const allocator = std.testing.allocator;
    const source = "```bash\necho hello\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(source, rendered);
}

test "hard break inside code fence is not stripped" {
    const allocator = std.testing.allocator;
    const source = "```\ncode with trailing spaces  \n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "code with trailing spaces  "));
}

test "code fence content is not wrapped" {
    const allocator = std.testing.allocator;
    const source = "```\nThis is long code that should not wrap\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .wrap_width = 10 });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "This is long code that should not wrap"));
}
