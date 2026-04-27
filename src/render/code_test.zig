const std = @import("std");
const helpers = @import("ast_helpers_test.zig");

test "code fence node renders exact plain-text fence content" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    try fixture.appendBlock(try fixture.codeFence("```zig", "```", "zig", "const x: u32 = 42;"));
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```zig\nconst x: u32 = 42;\n```", rendered);
}

test "code fence node can be syntax highlighted from AST" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    try fixture.appendBlock(try fixture.codeFence("```zig", "```", "zig", "const x: u32 = 42;"));
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 2, "```"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "const"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "42"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;"));
}

test "code fence under ansi16 emits ansi16 fg codes and no 38;2; or 38;5;" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();
    try fixture.appendBlock(try fixture.codeFence("```zig", "```", "zig", "const x: u32 = 42;"));
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = true,
        .color_mode = .ansi16,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "38;2;") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "38;5;") == null);
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "const x: u32 = 42;"));
}

test "code fence under ansi256 emits 38;5; and never 38;2;" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();
    try fixture.appendBlock(try fixture.codeFence("```zig", "```", "zig", "const x: u32 = 42;"));
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = true,
        .color_mode = .ansi256,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "38;2;") == null);
}

test "code fence under none emits zero SGR even when ansi enabled" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();
    try fixture.appendBlock(try fixture.codeFence("```zig", "```", "zig", "const x: u32 = 42;"));
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = true,
        .color_mode = .none,
    });
    defer allocator.free(rendered);

    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, rendered, "\x1b["));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "const x: u32 = 42;"));
}
