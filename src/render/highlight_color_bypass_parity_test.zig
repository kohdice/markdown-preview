const std = @import("std");
const helpers = @import("ast_helpers_test.zig");
const highlight = @import("../term/highlight.zig");
const ansi = @import("../term/ansi.zig");

const testing = std.testing;

const language_tags = [_][]const u8{
    "zig",
    "c",
    "rust",
    "go",
    "python",
    "javascript",
    "bash",
    "cpp",
    "typescript",
    "tsx",
    "html",
    "css",
    "json",
};

const body_variants = [_][]const u8{
    "const x: u32 = 42;",
    "a\nb\nc",
    "",
    "x := 1 + 2",
    "const esc = \"\\x1b[31m\";",
};

fn renderFencedCode(
    allocator: std.mem.Allocator,
    language: []const u8,
    content: []const u8,
    enable_ansi: bool,
    color_mode: ansi.ColorMode,
) ![]u8 {
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();
    try fixture.appendBlock(try fixture.codeFence("```", "```", language, content));
    try fixture.finish(false);
    return helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = enable_ansi,
        .color_mode = color_mode,
    });
}

fn hasAnyOf(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, haystack, n) != null) return true;
    }
    return false;
}

const ansi16_fg_codes = [_][]const u8{
    "\x1b[30m", "\x1b[31m", "\x1b[32m", "\x1b[33m",
    "\x1b[34m", "\x1b[35m", "\x1b[36m", "\x1b[37m",
    "\x1b[90m", "\x1b[91m", "\x1b[92m", "\x1b[93m",
    "\x1b[94m", "\x1b[95m", "\x1b[96m", "\x1b[97m",
};

test "color_mode=.none suppresses all SGR for every language and body" {
    const allocator = testing.allocator;

    for (language_tags) |lang| {
        for (body_variants) |body| {
            const out = try renderFencedCode(allocator, lang, body, true, .none);
            defer allocator.free(out);
            try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\x1b["));
        }
    }
}

test "color_mode=.ansi16 emits ansi16 fg codes, never 38;2; or 38;5;" {
    const allocator = testing.allocator;

    for (language_tags) |lang| {
        for (body_variants) |body| {
            if (body.len == 0) continue;
            const out = try renderFencedCode(allocator, lang, body, true, .ansi16);
            defer allocator.free(out);

            try testing.expect(std.mem.indexOf(u8, out, "38;2;") == null);
            try testing.expect(std.mem.indexOf(u8, out, "38;5;") == null);
            try testing.expect(hasAnyOf(out, &ansi16_fg_codes));
        }
    }
}

test "color_mode=.ansi256 emits 38;5; fg codes, never 38;2;" {
    const allocator = testing.allocator;

    for (language_tags) |lang| {
        const out = try renderFencedCode(allocator, lang, "const x: u32 = 42;", true, .ansi256);
        defer allocator.free(out);

        try testing.expect(std.mem.indexOf(u8, out, "38;2;") == null);
        try testing.expect(std.mem.indexOf(u8, out, "\x1b[38;5;") != null);
    }
}

test "color_mode=.truecolor emits 38;2; fg codes" {
    const allocator = testing.allocator;

    const out = try renderFencedCode(allocator, "zig", "const x: u32 = 42;", true, .truecolor);
    defer allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;") != null);
}

test "color_mode=.ansi16 bypasses tree-sitter: fewer SGR runs than .ansi256" {
    const allocator = testing.allocator;

    const body = "const x: u32 = 42; var y = x + 1;";

    const ansi16_out = try renderFencedCode(allocator, "zig", body, true, .ansi16);
    defer allocator.free(ansi16_out);

    const ansi256_out = try renderFencedCode(allocator, "zig", body, true, .ansi256);
    defer allocator.free(ansi256_out);

    try testing.expect(
        std.mem.count(u8, ansi256_out, "\x1b[") >
            std.mem.count(u8, ansi16_out, "\x1b["),
    );
}

test "unknown language tag matches null-language baseline byte-for-byte under every mode" {
    const allocator = testing.allocator;

    const modes = [_]ansi.ColorMode{ .none, .ansi16, .ansi256, .truecolor };
    const unknown_tags = [_][]const u8{ "fortran", "xyz", "nonexistent" };

    for (modes) |mode| {
        for (unknown_tags) |lang| {
            const out = try renderFencedCode(allocator, lang, "hello world", true, mode);
            defer allocator.free(out);

            const baseline = try renderFencedCode(allocator, "", "hello world", true, mode);
            defer allocator.free(baseline);

            try testing.expectEqualStrings(baseline, out);
        }
    }
}

test "enable_ansi=false emits zero SGR regardless of color_mode" {
    const allocator = testing.allocator;

    const modes = [_]ansi.ColorMode{ .none, .ansi16, .ansi256, .truecolor };

    for (modes) |mode| {
        const out = try renderFencedCode(allocator, "zig", "const x = 1;", false, mode);
        defer allocator.free(out);
        try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\x1b["));
    }
}

test "Language.fromString coverage matches bypass corpus" {
    var seen: std.EnumSet(highlight.Language) = .{};
    for (language_tags) |tag| {
        const lang = highlight.Language.fromString(tag) orelse return error.UnmappedTag;
        seen.insert(lang);
    }
    const full = std.EnumSet(highlight.Language).initFull();
    try testing.expect(seen.eql(full));
}
