const std = @import("std");
const markdown_preview = @import("markdown_preview");
const parse = markdown_preview.parse;
const render = markdown_preview.render;
const bench = @import("bench_support.zig");

const Scenario = struct {
    name: []const u8,
    input: []const u8,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scenarios = [_]Scenario{
        .{ .name = "paragraph-1000-lines", .input = try makeParagraphInput(allocator, 1000, "alpha beta gamma delta epsilon") },
        .{ .name = "paragraph-100k", .input = try makeRepeatedInlineInput(allocator, 7000, "This is **bold** and [linked](https://example.com) text. ") },
        .{ .name = "nested-inline-depth-64", .input = try makeNestedInlineInput(allocator, 64) },
        .{ .name = "reference-links-256", .input = try makeReferenceLinkInput(allocator, 256) },
        .{ .name = "many-paragraphs-1024", .input = try makeManyParagraphsInput(allocator, 1024) },
        .{ .name = "many-headings-1024", .input = try makeManyHeadingsInput(allocator, 1024) },
        .{ .name = "table-cells-4096", .input = try makeTableInput(allocator, 64, 64) },
    };

    std.debug.print("inline benchmark\n", .{});
    for (scenarios) |scenario| {
        try runScenario(scenario);
    }
}

fn runScenario(scenario: Scenario) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var counting = bench.CountingAllocator.init(gpa.allocator());
    const allocator = counting.allocator();

    const before_parse = counting.snapshot();
    var timer = try std.time.Timer.start();
    var doc = try parse.parseBorrowed(allocator, scenario.input);
    defer doc.deinit();
    const parse_elapsed_ns = timer.read();
    const after_parse = counting.snapshot();

    var renderer = render.Renderer.init(allocator, .{
        .enable_ansi = false,
        .wrap_width = 80,
    });
    defer renderer.deinit();

    var sink: [512]u8 = undefined;
    var discarding: std.io.Writer.Discarding = .init(&sink);
    timer.reset();
    try renderer.renderDocument(&discarding.writer, &doc);
    const render_elapsed_ns = timer.read();
    const after_render = counting.snapshot();

    const parse_counts = bench.CounterSnapshot.diff(after_parse, before_parse);
    const render_counts = bench.CounterSnapshot.diff(after_render, after_parse);

    std.debug.print(
        "{s}: parse={d:.3}ms render={d:.3}ms parse_allocs={d} parse_resizes={d} parse_bytes={d} render_allocs={d} render_resizes={d} render_bytes={d} output_bytes={d}\n",
        .{
            scenario.name,
            nsToMs(parse_elapsed_ns),
            nsToMs(render_elapsed_ns),
            parse_counts.alloc_count,
            parse_counts.resize_count,
            parse_counts.bytes_allocated,
            render_counts.alloc_count,
            render_counts.resize_count,
            render_counts.bytes_allocated,
            discarding.fullCount(),
        },
    );
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn makeParagraphInput(allocator: std.mem.Allocator, line_count: usize, line: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (0..line_count) |_| {
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

fn makeRepeatedInlineInput(allocator: std.mem.Allocator, repeat_count: usize, segment: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (0..repeat_count) |_| {
        try out.appendSlice(allocator, segment);
    }

    return out.toOwnedSlice(allocator);
}

fn makeNestedInlineInput(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (0..depth) |index| {
        if (index % 2 == 0) {
            try out.appendSlice(allocator, "*[");
        } else {
            try out.appendSlice(allocator, "[*");
        }
    }

    try out.appendSlice(allocator, "x");

    for (0..depth) |reverse_index| {
        const index = depth - reverse_index - 1;
        if (index % 2 == 0) {
            try out.appendSlice(allocator, "](https://example.com)*");
        } else {
            try out.appendSlice(allocator, "*](https://example.com)");
        }
    }

    return out.toOwnedSlice(allocator);
}

fn makeManyParagraphsInput(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var writer = out.writer(allocator);

    for (0..count) |i| {
        try writer.print("Paragraph {d} with **bold** and *italic* text.\n\n", .{i});
    }

    return out.toOwnedSlice(allocator);
}

fn makeManyHeadingsInput(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var writer = out.writer(allocator);

    for (0..count) |i| {
        const level = (i % 6) + 1;
        for (0..level) |_| try out.append(allocator, '#');
        try writer.print(" Heading {d}\n\n", .{i});
    }

    return out.toOwnedSlice(allocator);
}

fn makeTableInput(allocator: std.mem.Allocator, rows: usize, cols: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    var writer = out.writer(allocator);

    // Header row
    for (0..cols) |c| {
        if (c > 0) try out.append(allocator, '|');
        try writer.print(" H{d} ", .{c});
    }
    try out.append(allocator, '\n');

    // Delimiter row
    for (0..cols) |c| {
        if (c > 0) try out.append(allocator, '|');
        try out.appendSlice(allocator, " --- ");
    }
    try out.append(allocator, '\n');

    // Data rows
    for (0..rows) |r| {
        for (0..cols) |c| {
            if (c > 0) try out.append(allocator, '|');
            try writer.print(" R{d}C{d} ", .{ r, c });
        }
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

fn makeReferenceLinkInput(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var writer = out.writer(allocator);
    for (0..count) |index| {
        try writer.print("[label-{d}]: https://example.com/{d} \"title-{d}\"\n", .{
            index,
            index,
            index,
        });
    }
    try out.append(allocator, '\n');

    for (0..count) |index| {
        try writer.print("[label-{d}][label-{d}] ", .{ index, index });
    }
    try out.append(allocator, '\n');

    return out.toOwnedSlice(allocator);
}
