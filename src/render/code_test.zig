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
