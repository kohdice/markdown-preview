const std = @import("std");
const ast = @import("../ast.zig");
const bench = @import("bench_support");
const helpers = @import("ast_helpers_test.zig");
const parse = @import("../parse.zig");
const render = @import("../render.zig");

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

test "table renderer reuses scratch on repeated render of the same table-only document" {
    var parse_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = parse_gpa.deinit();

    var doc = try parse.parseBorrowed(parse_gpa.allocator(), "| A | B | C |\n" ++
        "| --- | --- | --- |\n" ++
        "| 1 | 2 | 3 |\n" ++
        "| 4 | 5 | 6 |\n");
    defer doc.deinit();

    var render_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = render_gpa.deinit();

    var counting = bench.CountingAllocator.init(render_gpa.allocator());
    var renderer = render.Renderer.init(counting.allocator(), .{});
    defer renderer.deinit();

    _ = try renderWithDiscarding(&renderer, &doc, &counting);
    const warm = try renderWithDiscarding(&renderer, &doc, &counting);

    try std.testing.expectEqual(@as(usize, 0), warm.alloc_count);
    try std.testing.expectEqual(@as(usize, 0), warm.resize_count);
    try std.testing.expectEqual(@as(usize, 0), warm.bytes_allocated);
}

test "table renderer reuses grown scratch when rendering small-large-small table-only documents" {
    var parse_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = parse_gpa.deinit();

    var small_doc = try parse.parseBorrowed(parse_gpa.allocator(), "| A | B |\n" ++
        "| --- | --- |\n" ++
        "| 1 | 2 |\n");
    defer small_doc.deinit();

    var large_doc = try parse.parseBorrowed(parse_gpa.allocator(), "| A | B | C | D |\n" ++
        "| --- | --- | --- | --- |\n" ++
        "| 1 | 2 | 3 | 4 |\n" ++
        "| 5 | 6 | 7 | 8 |\n" ++
        "| 9 | 10 | 11 | 12 |\n");
    defer large_doc.deinit();

    var render_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = render_gpa.deinit();

    var counting = bench.CountingAllocator.init(render_gpa.allocator());
    var renderer = render.Renderer.init(counting.allocator(), .{});
    defer renderer.deinit();

    _ = try renderWithDiscarding(&renderer, &small_doc, &counting);
    _ = try renderWithDiscarding(&renderer, &large_doc, &counting);
    const final_small = try renderWithDiscarding(&renderer, &small_doc, &counting);

    try std.testing.expectEqual(@as(usize, 0), final_small.alloc_count);
    try std.testing.expectEqual(@as(usize, 0), final_small.resize_count);
    try std.testing.expectEqual(@as(usize, 0), final_small.bytes_allocated);
}

test "wide table border near 2048-byte batch threshold produces correct output" {
    const allocator = std.testing.allocator;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var writer = buf.writer(allocator);

    try writer.writeAll("|");
    for (0..60) |c| {
        try writer.print(" col{d:0>3} |", .{c});
    }
    try writer.writeByte('\n');

    try writer.writeAll("|");
    for (0..60) |_| {
        try writer.writeAll(" --- |");
    }
    try writer.writeByte('\n');

    try writer.writeAll("|");
    for (0..60) |c| {
        try writer.print(" val{d:0>3} |", .{c});
    }
    try writer.writeByte('\n');

    const source = try buf.toOwnedSlice(allocator);
    defer allocator.free(source);

    var doc = try parse.parseBorrowed(allocator, source);
    defer doc.deinit();

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, &doc, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.startsWith(u8, rendered, "\xe2\x94\x8c"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\xe2\x94\x80"));

    var line_count: usize = 0;
    for (rendered) |byte| {
        if (byte == '\n') line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), line_count);
}

fn renderWithDiscarding(
    renderer: *render.Renderer,
    doc: *const parse.Document,
    counting: *const bench.CountingAllocator,
) !bench.CounterSnapshot {
    var sink: [256]u8 = undefined;
    var discarding: std.io.Writer.Discarding = .init(&sink);
    const before = counting.snapshot();
    try renderer.renderDocument(&discarding.writer, doc);
    const after = counting.snapshot();
    return bench.CounterSnapshot.diff(after, before);
}
