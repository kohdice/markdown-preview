const std = @import("std");
const helpers = @import("ast_helpers_test.zig");

test "explicit link node renders label, url, and title from AST" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const label = try fixture.text("OpenAI");
    const link = try fixture.link("https://example.com", "Docs", label);
    try fixture.appendBlock(helpers.RenderFixture.paragraph(link));
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("OpenAI(https://example.com) — Docs", rendered);
}

test "nested strong and emphasis nodes render without markdown delimiters" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const prefix = try fixture.text("This is ");
    const inner_text = try fixture.text("very");
    const italic = try fixture.emphasis(inner_text);
    const strong = try fixture.strong(italic);
    const suffix = try fixture.text(" important");
    const children = try fixture.chain(&.{ prefix, strong, suffix });
    try fixture.appendBlock(helpers.RenderFixture.paragraph(children));
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is very important", rendered);
}

test "link url batching boundary at 126/127 bytes" {
    const allocator = std.testing.allocator;

    var fixture126 = helpers.RenderFixture.init(allocator);
    defer fixture126.deinit();
    const url126 = "x" ** 126;
    const label126 = try fixture126.text("a");
    const link126 = try fixture126.link(url126, null, label126);
    try fixture126.appendBlock(helpers.RenderFixture.paragraph(link126));
    try fixture126.finish(false);
    const out126 = try helpers.renderDocumentToOwnedSlice(allocator, try fixture126.document(), .{ .enable_ansi = true });
    defer allocator.free(out126);

    var fixture127 = helpers.RenderFixture.init(allocator);
    defer fixture127.deinit();
    const url127 = "x" ** 127;
    const label127 = try fixture127.text("a");
    const link127 = try fixture127.link(url127, null, label127);
    try fixture127.appendBlock(helpers.RenderFixture.paragraph(link127));
    try fixture127.finish(false);
    const out127 = try helpers.renderDocumentToOwnedSlice(allocator, try fixture127.document(), .{ .enable_ansi = true });
    defer allocator.free(out127);

    try std.testing.expect(std.mem.containsAtLeast(u8, out126, 1, "(" ++ url126 ++ ")"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out127, 1, url127));
}

test "strong node applies ANSI bold styling" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const text = try fixture.text("bold");
    const strong = try fixture.strong(text);
    try fixture.appendBlock(helpers.RenderFixture.paragraph(strong));
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "bold"));
}
