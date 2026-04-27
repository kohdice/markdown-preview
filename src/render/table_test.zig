const std = @import("std");
const ast = @import("../ast.zig");
const bench = @import("bench_support");
const helpers = @import("ast_helpers_test.zig");
const parse = @import("../parse.zig");
const render = @import("../render.zig");
const render_table = @import("table.zig");
const width = @import("../term/width.zig");

fn fitWidths(
    widths: []usize,
    wrap_width: ?usize,
    ambiguous: width.AmbiguousWidth,
) !void {
    try render_table.fitColumnWidths(std.testing.allocator, widths, wrap_width, ambiguous);
}

test "fitColumnWidths clamps below-min widths to min_col_width in narrow mode" {
    var widths = [_]usize{ 1, 3, 7 };
    try fitWidths(&widths, null, .narrow);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 3, 3, 7 }, &widths);
}

test "fitColumnWidths rounds widths up to the next even value in wide mode" {
    var widths = [_]usize{ 1, 3, 6 };
    try fitWidths(&widths, null, .wide);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 4, 4, 6 }, &widths);
}

test "fitColumnWidths leaves widths alone when natural total fits (narrow frame)" {
    var widths = [_]usize{ 10, 10 };
    try fitWidths(&widths, 30, .narrow);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 10, 10 }, &widths);
}

test "fitColumnWidths leaves widths alone when natural total fits (wide frame)" {
    var widths = [_]usize{ 10, 10 };
    try fitWidths(&widths, 32, .wide);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 10, 10 }, &widths);
}

test "fitColumnWidths gives up when wrap_width is below the minimum-fit threshold" {
    var widths = [_]usize{ 50, 50 };
    try fitWidths(&widths, 5, .narrow);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 50, 50 }, &widths);
}

test "fitColumnWidths shrinks only wide columns when a narrow column is frozen" {
    var widths = [_]usize{ 3, 100 };
    try fitWidths(&widths, 30, .narrow);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 3, 20 }, &widths);
    try std.testing.expect(widths[0] + widths[1] <= 30 - 7);
}

test "fitColumnWidths distributes leftover quanta to leftmost wide columns" {
    var widths = [_]usize{ 50, 50, 50 };
    try fitWidths(&widths, 26, .narrow);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 6, 5, 5 }, &widths);
    var sum: usize = 0;
    for (widths) |w| sum += w;
    try std.testing.expect(sum <= 26 - 10);
}

test "fitColumnWidths uses quantum=2 when ambiguous width is wide" {
    var widths = [_]usize{ 40, 40 };
    try fitWidths(&widths, 30, .wide);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 10, 10 }, &widths);
    try std.testing.expect(widths[0] % 2 == 0);
    try std.testing.expect(widths[1] % 2 == 0);
}

test "fitColumnWidths iteratively freezes columns as fair share grows" {
    var widths = [_]usize{ 3, 7, 15 };
    try fitWidths(&widths, 30, .narrow);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 3, 7, 10 }, &widths);
    var sum: usize = 0;
    for (widths) |w| sum += w;
    try std.testing.expect(sum <= 30 - 10);
}

test "fitColumnWidths honors wrap_width for tables with more than 256 columns" {
    const allocator = std.testing.allocator;
    const n: usize = 300;
    const widths = try allocator.alloc(usize, n);
    defer allocator.free(widths);
    for (widths) |*w| w.* = 50;

    const wrap_w: usize = 2000;
    try fitWidths(widths, wrap_w, .narrow);

    const frame_w = 3 * n + 1;
    const available = wrap_w - frame_w;
    var sum: usize = 0;
    for (widths) |w| sum += w;
    try std.testing.expect(sum <= available);
}

test "writeTable wraps long body cells into multi-line rows when wrap_width is set" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const date_h = try fixture.text("Date");
    const change_h = try fixture.text("Change");
    const date_1 = try fixture.text("2026-04-22");
    const change_1 = try fixture.text("hello world hello world hello world");

    const table = try fixture.table(
        &.{
            helpers.RenderFixture.tableCell(date_h),
            helpers.RenderFixture.tableCell(change_h),
        },
        &.{ .left, .left },
        &.{
            &.{
                helpers.RenderFixture.tableCell(date_1),
                helpers.RenderFixture.tableCell(change_1),
            },
        },
    );
    try fixture.appendBlock(table);
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .wrap_width = 40,
    });
    defer allocator.free(rendered);

    var line_count: usize = 0;
    for (rendered) |byte| {
        if (byte == '\n') line_count += 1;
    }
    try std.testing.expect(line_count >= 5);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "hello") != null);
}

test "writeTable keeps borders stable across multi-line rows" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const h1 = try fixture.text("A");
    const h2 = try fixture.text("B");
    const row_a = try fixture.text("foo bar baz");
    const row_b = try fixture.text("qux");

    const table = try fixture.table(
        &.{
            helpers.RenderFixture.tableCell(h1),
            helpers.RenderFixture.tableCell(h2),
        },
        &.{ .left, .left },
        &.{
            &.{
                helpers.RenderFixture.tableCell(row_a),
                helpers.RenderFixture.tableCell(row_b),
            },
        },
    );
    try fixture.appendBlock(table);
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .wrap_width = 15,
    });
    defer allocator.free(rendered);

    const top_borders = std.mem.count(u8, rendered, "┌");
    const mid_borders = std.mem.count(u8, rendered, "├");
    const bot_borders = std.mem.count(u8, rendered, "└");
    try std.testing.expectEqual(@as(usize, 1), top_borders);
    try std.testing.expectEqual(@as(usize, 1), mid_borders);
    try std.testing.expectEqual(@as(usize, 1), bot_borders);
}

test "writeTable renders an empty body cell as one zero-width segment under wrap_width" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const h1 = try fixture.text("A");
    const h2 = try fixture.text("B");
    const row_filled = try fixture.text("filled");

    const table = try fixture.table(
        &.{
            helpers.RenderFixture.tableCell(h1),
            helpers.RenderFixture.tableCell(h2),
        },
        &.{ .left, .left },
        &.{
            &.{
                helpers.RenderFixture.tableCell(row_filled),
                helpers.RenderFixture.tableCell(ast.no_inline),
            },
        },
    );
    try fixture.appendBlock(table);
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .wrap_width = 20,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "filled") != null);
    const mids = std.mem.count(u8, rendered, "├");
    try std.testing.expectEqual(@as(usize, 1), mids);
}

test "writeTable keeps table borders aligned for BMP emoji presentation symbols" {
    const allocator = std.testing.allocator;
    const source = "| Status | Note |\n" ++
        "| --- | --- |\n" ++
        "| ✅ | ok |\n";
    var doc = try parse.parse(allocator, .{ .borrowed = source });
    defer doc.deinit();

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, &doc, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\┌────────┬──────┐
        \\│ Status │ Note │
        \\├────────┼──────┤
        \\│ ✅     │ ok   │
        \\└────────┴──────┘
        \\
    ,
        rendered,
    );
}

test "writeTable keeps column widths even in ambiguous-wide mode after fitting" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const h1 = try fixture.text("日付");
    const h2 = try fixture.text("変更");
    const row_date = try fixture.text("2026-04-22");
    const row_change = try fixture.text("長い変更の説明文がここに入ります");

    const table = try fixture.table(
        &.{
            helpers.RenderFixture.tableCell(h1),
            helpers.RenderFixture.tableCell(h2),
        },
        &.{ .left, .left },
        &.{
            &.{
                helpers.RenderFixture.tableCell(row_date),
                helpers.RenderFixture.tableCell(row_change),
            },
        },
    );
    try fixture.appendBlock(table);
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .wrap_width = 38,
        .ambiguous_width = .wide,
    });
    defer allocator.free(rendered);

    var lines = std.mem.splitScalar(u8, rendered, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const dw = width.displayWidth(line, .wide);
        try std.testing.expect(dw <= 38);
    }
}

test "writeTable overflows naturally when wrap_width is below the minimum fit threshold" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const h1 = try fixture.text("AAAAAAAA");
    const h2 = try fixture.text("BBBBBBBB");
    const h3 = try fixture.text("CCCCCCCC");

    const table = try fixture.table(
        &.{
            helpers.RenderFixture.tableCell(h1),
            helpers.RenderFixture.tableCell(h2),
            helpers.RenderFixture.tableCell(h3),
        },
        &.{ .left, .left, .left },
        &.{},
    );
    try fixture.appendBlock(table);
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .wrap_width = 5,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "AAAAAAAA") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "BBBBBBBB") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "CCCCCCCC") != null);
}

test "writeTable measures natural cell width as the max segment width when explicit breaks split the cell" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const h0 = try fixture.text("A");
    const h1 = try fixture.text("B");
    const c00 = try fixture.text("x");
    const c10 = try fixture.text("looooong");
    const br = try fixture.softBreak();
    const c11 = try fixture.text("y");
    const chain = try fixture.chain(&.{ c10, br, c11 });

    const table = try fixture.table(
        &.{
            helpers.RenderFixture.tableCell(h0),
            helpers.RenderFixture.tableCell(h1),
        },
        &.{ .left, .left },
        &.{
            &.{
                helpers.RenderFixture.tableCell(c00),
                helpers.RenderFixture.tableCell(chain),
            },
        },
    );
    try fixture.appendBlock(table);
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "┬──────────┐") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "┬───────────┐") == null);
}

test "writeTable treats soft_break as a segment boundary inside a cell" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const h1 = try fixture.text("H");
    const first = try fixture.text("a");
    const brk = try fixture.softBreak();
    const last = try fixture.text("b");
    const chain = try fixture.chain(&.{ first, brk, last });

    const table = try fixture.table(
        &.{helpers.RenderFixture.tableCell(h1)},
        &.{.left},
        &.{&.{helpers.RenderFixture.tableCell(chain)}},
    );
    try fixture.appendBlock(table);
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{});
    defer allocator.free(rendered);

    var lines = std.mem.splitScalar(u8, rendered, '\n');
    var saw_a = false;
    var saw_b = false;
    while (lines.next()) |line| {
        const has_a = std.mem.indexOfScalar(u8, line, 'a') != null;
        const has_b = std.mem.indexOfScalar(u8, line, 'b') != null;
        try std.testing.expect(!(has_a and has_b));
        if (has_a) saw_a = true;
        if (has_b) saw_b = true;
    }
    try std.testing.expect(saw_a);
    try std.testing.expect(saw_b);
}

test "writeTable strips HTML-entity-decoded tabs and newlines from cell content" {
    const allocator = std.testing.allocator;
    const source = "| A | B |\n" ++
        "| --- | --- |\n" ++
        "| abc&#10;xyz | p&#9;q |\n";
    var doc = try parse.parse(allocator, .{ .borrowed = source });
    defer doc.deinit();

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, &doc, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "abcxyz") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "pq") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, rendered, '\t') == null);

    const bars = std.mem.count(u8, rendered, "│");
    try std.testing.expectEqual(@as(usize, 6), bars);
}

test "writeTable shrinks a blockquote-nested table when the gutter reduces wrap_width" {
    const allocator = std.testing.allocator;
    var doc = try parse.parse(allocator, .{ .borrowed = "> | A | B |\n" ++
        "> | --- | --- |\n" ++
        "> | short | hello world hello world |\n" });
    defer doc.deinit();

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, &doc, .{
        .wrap_width = 40,
    });
    defer allocator.free(rendered);

    var lines = std.mem.splitScalar(u8, rendered, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const dw = width.displayWidth(line, .narrow);
        try std.testing.expect(dw <= 40);
    }
}

test "table renderer reuses scratch on repeated render with wrap_width" {
    var parse_gpa = std.heap.DebugAllocator(.{}){};
    defer _ = parse_gpa.deinit();

    var doc = try parse.parse(parse_gpa.allocator(), .{ .borrowed = "| A | B |\n" ++
        "| --- | --- |\n" ++
        "| hello world hello world | short |\n" });
    defer doc.deinit();

    var render_gpa = std.heap.DebugAllocator(.{}){};
    defer _ = render_gpa.deinit();

    var counting = bench.CountingAllocator.init(render_gpa.allocator());
    var renderer = render.Renderer.init(counting.allocator(), .{});
    defer renderer.deinit();

    _ = try renderWithDiscardingWrap(&renderer, &doc, &counting, 20);
    const warm = try renderWithDiscardingWrap(&renderer, &doc, &counting, 20);

    try std.testing.expectEqual(@as(usize, 0), warm.alloc_count);
    try std.testing.expectEqual(@as(usize, 0), warm.resize_count);
    try std.testing.expectEqual(@as(usize, 0), warm.bytes_allocated);
}

test "writeTable right-aligns each sub-line independently" {
    const allocator = std.testing.allocator;

    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    const h1 = try fixture.text("N");
    const cell_1 = try fixture.text("aa bb cc");

    const table = try fixture.table(
        &.{helpers.RenderFixture.tableCell(h1)},
        &.{.right},
        &.{
            &.{helpers.RenderFixture.tableCell(cell_1)},
        },
    );
    try fixture.appendBlock(table);
    try fixture.finish(false);

    const rendered = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .wrap_width = 8,
    });
    defer allocator.free(rendered);

    var lines = std.mem.splitScalar(u8, rendered, '\n');
    var matched: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "aa")) |_| {
            try std.testing.expect(std.mem.indexOf(u8, line, "  aa │") != null);
            matched += 1;
        }
        if (std.mem.indexOf(u8, line, "bb")) |_| {
            try std.testing.expect(std.mem.indexOf(u8, line, "  bb │") != null);
            matched += 1;
        }
        if (std.mem.indexOf(u8, line, "cc")) |_| {
            try std.testing.expect(std.mem.indexOf(u8, line, "  cc │") != null);
            matched += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), matched);
}

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
    var parse_gpa = std.heap.DebugAllocator(.{}){};
    defer _ = parse_gpa.deinit();

    var doc = try parse.parse(parse_gpa.allocator(), .{ .borrowed = "| A | B | C |\n" ++
        "| --- | --- | --- |\n" ++
        "| 1 | 2 | 3 |\n" ++
        "| 4 | 5 | 6 |\n" });
    defer doc.deinit();

    var render_gpa = std.heap.DebugAllocator(.{}){};
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
    var parse_gpa = std.heap.DebugAllocator(.{}){};
    defer _ = parse_gpa.deinit();

    var small_doc = try parse.parse(parse_gpa.allocator(), .{ .borrowed = "| A | B |\n" ++
        "| --- | --- |\n" ++
        "| 1 | 2 |\n" });
    defer small_doc.deinit();

    var large_doc = try parse.parse(parse_gpa.allocator(), .{ .borrowed = "| A | B | C | D |\n" ++
        "| --- | --- | --- | --- |\n" ++
        "| 1 | 2 | 3 | 4 |\n" ++
        "| 5 | 6 | 7 | 8 |\n" ++
        "| 9 | 10 | 11 | 12 |\n" });
    defer large_doc.deinit();

    var render_gpa = std.heap.DebugAllocator(.{}){};
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

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;

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

    var list = buf.toArrayList();
    const source = try list.toOwnedSlice(allocator);
    defer allocator.free(source);

    var doc = try parse.parse(allocator, .{ .borrowed = source });
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
    output: *const ast.Document,
    counting: *bench.CountingAllocator,
) !bench.CounterSnapshot {
    var sink: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink);
    const before = counting.snapshot();
    try renderer.render(&discarding.writer, output, null, counting.allocator());
    const after = counting.snapshot();
    return bench.CounterSnapshot.diff(after, before);
}

fn renderWithDiscardingWrap(
    renderer: *render.Renderer,
    output: *const ast.Document,
    counting: *bench.CountingAllocator,
    wrap_width: usize,
) !bench.CounterSnapshot {
    var sink: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink);
    const before = counting.snapshot();
    try renderer.render(&discarding.writer, output, wrap_width, counting.allocator());
    const after = counting.snapshot();
    return bench.CounterSnapshot.diff(after, before);
}
