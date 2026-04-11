const std = @import("std");
const ast = @import("../ast.zig");
const helpers = @import("ast_helpers_test.zig");

test "table renderer accepts ast.no_inline cells and preserves layout" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const header_a = try fixture.text("A");
    const header_b = try fixture.text("B");
    const row_a = try fixture.text("1");

    const table = try fixture.table(
        &.{
            helpers.RenderFixture.tableCell(header_a),
            helpers.RenderFixture.tableCell(header_b),
        },
        &.{ .left, .left },
        &.{
            &.{
                helpers.RenderFixture.tableCell(row_a),
                helpers.RenderFixture.tableCell(ast.no_inline),
            },
        },
    );
    try fixture.appendBlock(table);
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\┌─────┬─────┐
        \\│ A   │ B   │
        \\├─────┼─────┤
        \\│ 1   │     │
        \\└─────┴─────┘
    ,
        rendered,
    );
}
