const std = @import("std");
const helpers = @import("ast_helpers_test.zig");

test "heading, list, and blockquote render directly from AST" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const title = try fixture.text("Title");
    try fixture.appendBlock(helpers.RenderFixture.heading(1, title));

    const item_text = try fixture.text("Item");
    const item_paragraph = helpers.RenderFixture.paragraph(item_text);
    const item = try fixture.listItem(0, '-', null, null, &.{item_paragraph});
    try fixture.appendBlock(try fixture.unorderedList(&.{item}));

    const quote_text = try fixture.text("Quote");
    const quote_paragraph = helpers.RenderFixture.paragraph(quote_text);
    try fixture.appendBlock(try fixture.blockQuote(0, &.{quote_paragraph}));

    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Title\n• Item\n│ Quote", rendered);
}

test "sibling blockquotes render byte-identical styled gutter prefixes under ANSI" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const alpha = try fixture.text("Alpha");
    try fixture.appendBlock(try fixture.blockQuote(0, &.{helpers.RenderFixture.paragraph(alpha)}));

    const beta = try fixture.text("Beta");
    try fixture.appendBlock(try fixture.blockQuote(0, &.{helpers.RenderFixture.paragraph(beta)}));

    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{ .enable_ansi = true });
    defer allocator.free(rendered);

    const alpha_idx = std.mem.indexOf(u8, rendered, "Alpha").?;
    const beta_idx = std.mem.indexOf(u8, rendered, "Beta").?;
    const marker_a = rendered[0..alpha_idx];
    const marker_b = rendered[beta_idx - marker_a.len .. beta_idx];

    try std.testing.expectEqualStrings(marker_a, marker_b);
    try std.testing.expect(std.mem.indexOfScalar(u8, marker_a, 0x1b) != null);
}

test "ordered task list item renders number and checkbox from AST" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const done = try fixture.text("Done");
    const done_paragraph = helpers.RenderFixture.paragraph(done);
    const item = try fixture.listItem(0, '.', "1", true, &.{done_paragraph});
    try fixture.appendBlock(try fixture.orderedList(&.{item}));
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1. ☑ Done", rendered);
}

test "loose list items render with a blank line between items from AST" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const first_text = try fixture.text("First");
    const first_paragraph = helpers.RenderFixture.paragraph(first_text);
    const first_item = try fixture.listItem(0, '-', null, null, &.{first_paragraph});

    const second_text = try fixture.text("Second");
    const second_paragraph = helpers.RenderFixture.paragraph(second_text);
    const second_item = try fixture.listItem(0, '-', null, null, &.{second_paragraph});

    try fixture.appendBlock(try fixture.unorderedListWithLoose(&.{ first_item, second_item }, true));
    try fixture.finish(true);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("• First\n\n• Second\n", rendered);
}
