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
