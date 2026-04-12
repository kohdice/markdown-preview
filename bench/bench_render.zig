const std = @import("std");
const project = @import("project");
const parse = project.parse;
const render = project.render;
const bench = @import("bench_support.zig");

const Scenario = struct {
    name: []const u8,
    input: []const u8,
    opts: render.RenderOptions = .{},
};

const RenderResult = struct {
    elapsed_ns: u64,
    counts: bench.CounterSnapshot,
    output_bytes: usize,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scenarios = [_]Scenario{
        .{ .name = "table-128x8-ascii", .input = try makeAsciiTableDocument(allocator, 1, 128, 8) },
        .{ .name = "table-64x6-cjk-wide", .input = try makeCjkTableDocument(allocator, 1, 64, 6), .opts = .{ .ambiguous_width = .wide } },
        .{ .name = "table-many-small-256", .input = try makeAsciiTableDocument(allocator, 256, 2, 2) },
        .{ .name = "blockquote-table-64x4", .input = try makeAsciiTableDocumentWithPrefix(allocator, 1, 64, 4, "> ") },
    };

    std.debug.print("render benchmark\n", .{});
    for (scenarios) |scenario| {
        try runScenario(scenario);
    }
}

fn runScenario(scenario: Scenario) !void {
    var parse_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = parse_gpa.deinit();

    var doc = try parse.parseBorrowed(parse_gpa.allocator(), scenario.input);
    defer doc.deinit();

    var render_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = render_gpa.deinit();

    var counting = bench.CountingAllocator.init(render_gpa.allocator());
    var renderer = render.Renderer.init(counting.allocator(), scenario.opts);
    defer renderer.deinit();

    const cold = try renderOnce(&renderer, &doc, &counting);
    const warm = try renderOnce(&renderer, &doc, &counting);

    std.debug.print(
        "{s}: cold_render={d:.3}ms cold_allocs={d} cold_resizes={d} cold_bytes={d} warm_render={d:.3}ms warm_allocs={d} warm_resizes={d} warm_bytes={d} output_bytes={d}\n",
        .{
            scenario.name,
            nsToMs(cold.elapsed_ns),
            cold.counts.alloc_count,
            cold.counts.resize_count,
            cold.counts.bytes_allocated,
            nsToMs(warm.elapsed_ns),
            warm.counts.alloc_count,
            warm.counts.resize_count,
            warm.counts.bytes_allocated,
            cold.output_bytes,
        },
    );
}

fn renderOnce(
    renderer: *render.Renderer,
    doc: *const parse.Document,
    counting: *const bench.CountingAllocator,
) !RenderResult {
    var sink: [512]u8 = undefined;
    var discarding: std.io.Writer.Discarding = .init(&sink);
    const before = counting.snapshot();
    var timer = try std.time.Timer.start();
    try renderer.renderDocument(&discarding.writer, doc);
    const after = counting.snapshot();
    return .{
        .elapsed_ns = timer.read(),
        .counts = bench.CounterSnapshot.diff(after, before),
        .output_bytes = discarding.fullCount(),
    };
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn makeAsciiTableDocument(
    allocator: std.mem.Allocator,
    table_count: usize,
    row_count: usize,
    col_count: usize,
) ![]u8 {
    return makeAsciiTableDocumentWithPrefix(allocator, table_count, row_count, col_count, "");
}

fn makeAsciiTableDocumentWithPrefix(
    allocator: std.mem.Allocator,
    table_count: usize,
    row_count: usize,
    col_count: usize,
    prefix: []const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var writer = out.writer(allocator);
    for (0..table_count) |table_index| {
        try appendAsciiTable(&writer, prefix, table_index, row_count, col_count);
        if (table_index + 1 < table_count) {
            try writer.writeByte('\n');
        }
    }

    return out.toOwnedSlice(allocator);
}

fn appendAsciiTable(
    writer: *std.ArrayListUnmanaged(u8).Writer,
    prefix: []const u8,
    table_index: usize,
    row_count: usize,
    col_count: usize,
) !void {
    try writeHeader(writer, prefix, table_index, col_count, false);
    try writeDelimiter(writer, prefix, col_count);

    for (0..row_count) |row_index| {
        try writer.writeAll(prefix);
        try writer.writeAll("|");
        for (0..col_count) |col_index| {
            try writer.print(" t{d}r{d}c{d} |", .{ table_index, row_index, col_index });
        }
        try writer.writeByte('\n');
    }
}

fn makeCjkTableDocument(
    allocator: std.mem.Allocator,
    table_count: usize,
    row_count: usize,
    col_count: usize,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var writer = out.writer(allocator);
    for (0..table_count) |table_index| {
        try writeHeader(&writer, "", table_index, col_count, true);
        try writeDelimiter(&writer, "", col_count);
        for (0..row_count) |row_index| {
            try writer.writeAll("|");
            for (0..col_count) |col_index| {
                try writer.print(" 行{d}-列{d} mixed 日本 {d} |", .{ row_index, col_index, table_index });
            }
            try writer.writeByte('\n');
        }
        if (table_index + 1 < table_count) {
            try writer.writeByte('\n');
        }
    }

    return out.toOwnedSlice(allocator);
}

fn writeHeader(
    writer: *std.ArrayListUnmanaged(u8).Writer,
    prefix: []const u8,
    table_index: usize,
    col_count: usize,
    cjk: bool,
) !void {
    try writer.writeAll(prefix);
    try writer.writeAll("|");
    for (0..col_count) |col_index| {
        if (cjk) {
            try writer.print(" 列{d}-{d} |", .{ table_index, col_index });
        } else {
            try writer.print(" H{d}{d} |", .{ table_index, col_index });
        }
    }
    try writer.writeByte('\n');
}

fn writeDelimiter(
    writer: *std.ArrayListUnmanaged(u8).Writer,
    prefix: []const u8,
    col_count: usize,
) !void {
    try writer.writeAll(prefix);
    try writer.writeAll("|");
    for (0..col_count) |_| {
        try writer.writeAll(" --- |");
    }
    try writer.writeByte('\n');
}
