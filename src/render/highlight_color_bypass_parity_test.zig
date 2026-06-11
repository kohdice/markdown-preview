const std = @import("std");
const helpers = @import("ast_helpers_test.zig");
const highlight = @import("../term/highlight.zig");

const testing = std.testing;

const language_tags = [_][]const u8{
    "zig",
    "c",
    "rust",
    "go",
    "javascript",
    "bash",
    "cpp",
    "typescript",
    "tsx",
    "html",
    "css",
    "json",
};

fn renderFencedCode(
    allocator: std.mem.Allocator,
    language: []const u8,
    content: []const u8,
    enable_ansi: bool,
) ![]u8 {
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();
    try fixture.appendBlock(try fixture.codeFence("```", "```", language, content));
    try fixture.finish(false);
    return helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = enable_ansi,
    });
}

test "syntax highlighting emits truecolor SGR for supported languages" {
    const allocator = testing.allocator;

    for (language_tags) |lang| {
        const out = try renderFencedCode(allocator, lang, "const x: u32 = 42;", true);
        defer allocator.free(out);
        try testing.expect(std.mem.find(u8, out, "\x1b[38;2;") != null);
        try testing.expect(std.mem.find(u8, out, "\x1b[38;5;") == null);
    }
}

test "unknown language tag matches null-language baseline byte-for-byte" {
    const allocator = testing.allocator;
    const unknown_tags = [_][]const u8{ "fortran", "xyz", "nonexistent", "python", "py" };

    for (unknown_tags) |lang| {
        const out = try renderFencedCode(allocator, lang, "hello world", true);
        defer allocator.free(out);

        const baseline = try renderFencedCode(allocator, "", "hello world", true);
        defer allocator.free(baseline);

        try testing.expectEqualStrings(baseline, out);
    }
}

test "enable_ansi=false emits zero SGR" {
    const allocator = testing.allocator;

    const out = try renderFencedCode(allocator, "zig", "const x = 1;", false);
    defer allocator.free(out);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\x1b["));
}

test "Language.fromString coverage matches highlight corpus" {
    var seen: std.EnumSet(highlight.Language) = .empty;
    for (language_tags) |tag| {
        const lang = highlight.Language.fromString(tag) orelse return error.UnmappedTag;
        seen.insert(lang);
    }
    const full: std.EnumSet(highlight.Language) = .full;
    try testing.expect(seen.eql(full));
}
