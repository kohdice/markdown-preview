const std = @import("std");
const helpers = @import("ast_helpers_test.zig");

test "renderDocument appends one trailing newline when document requests it" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const hello = try fixture.text("Hello");
    try fixture.appendBlock(helpers.RenderFixture.paragraph(hello));
    try fixture.finish(true);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Hello\n", rendered);
}

test "renderDocument does not append trailing newline when document does not request it" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const hello = try fixture.text("Hello");
    try fixture.appendBlock(helpers.RenderFixture.paragraph(hello));
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Hello", rendered);
}

test "renderDocument emits an exact byte sequence for a two-column wrapped table" {
    const allocator = std.testing.allocator;
    const parse = @import("../parse.zig");

    const source = "| A | B |\n" ++
        "| --- | --- |\n" ++
        "| hi | hello world |\n";

    var doc = try parse.parse(allocator, .{ .borrowed = source });
    defer doc.deinit();

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, &doc, .{
        .wrap_width = 20,
    });
    defer allocator.free(rendered);

    const expected =
        "┌─────┬────────────┐\n" ++
        "│ A   │ B          │\n" ++
        "├─────┼────────────┤\n" ++
        "│ hi  │ hello      │\n" ++
        "│     │ world      │\n" ++
        "└─────┴────────────┘\n";
    try std.testing.expectEqualStrings(expected, rendered);
}

test "renderDocument wraps a Japanese changelog table against wrap_width" {
    const allocator = std.testing.allocator;
    const parse = @import("../parse.zig");

    const source =
        "| 日付 | 変更 |\n" ++
        "| --- | --- |\n" ++
        "| 2026-04-22 | 日本語の長文を含むセルの例です |\n";

    var doc = try parse.parse(allocator, .{ .borrowed = source });
    defer doc.deinit();

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, &doc, .{
        .wrap_width = 40,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "日付") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "変更") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "2026-04-22") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "日本語の長文を含むセル") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "の例です") != null);

    var nl: usize = 0;
    for (rendered) |b| if (b == '\n') {
        nl += 1;
    };
    try std.testing.expectEqual(@as(usize, 6), nl);

    var lines = std.mem.splitScalar(u8, rendered, '\n');
    while (lines.next()) |line| {
        const display_w = @import("../term/width.zig").displayWidth(line, .narrow);
        try std.testing.expect(display_w <= 40);
    }
}
