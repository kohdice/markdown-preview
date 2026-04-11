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
