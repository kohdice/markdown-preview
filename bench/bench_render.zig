const std = @import("std");
const internals = @import("internals");
const parse = internals.parse.parse;
const Document = internals.parse.Document;
const Renderer = internals.render.Renderer;
const bench = @import("bench_support.zig");

const AmbiguousWidth = internals.term.width.AmbiguousWidth;
const timing_allocator = std.heap.smp_allocator;

const Scenario = struct {
    name: []const u8,
    input: []const u8,
    enable_ansi: bool = false,
    ambiguous_width: AmbiguousWidth = .narrow,
};

const RenderTiming = struct {
    stats: bench.DurationStats,
    output_bytes: usize,
};

const RenderProfile = struct {
    counts: bench.CounterSnapshot,
    output_bytes: usize,
};

const RenderTimeRunner = struct {
    allocator: std.mem.Allocator,
    renderer: *Renderer,
    doc: *const Document,
    last_output_bytes: usize = 0,

    pub fn run(self: *@This()) !void {
        self.last_output_bytes = try renderWithDiscarding(
            self.renderer,
            self.doc,
            self.allocator,
        );
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scenarios = [_]Scenario{
        .{ .name = "table-128x8-ascii", .input = try makeAsciiTableDocument(allocator, 1, 128, 8) },
        .{ .name = "table-64x6-cjk-wide", .input = try makeCjkTableDocument(allocator, 1, 64, 6), .ambiguous_width = .wide },
        .{ .name = "table-many-small-256", .input = try makeAsciiTableDocument(allocator, 256, 2, 2) },
        .{ .name = "blockquote-table-64x4", .input = try makeAsciiTableDocumentWithPrefix(allocator, 1, 64, 4, "> ") },
        .{ .name = "table-128x8-ansi", .input = try makeAsciiTableDocument(allocator, 1, 128, 8), .enable_ansi = true },
        .{ .name = "table-64x6-cjk-ansi", .input = try makeCjkTableDocument(allocator, 1, 64, 6), .enable_ansi = true, .ambiguous_width = .wide },
        .{ .name = "table-many-small-256-ansi", .input = try makeAsciiTableDocument(allocator, 256, 2, 2), .enable_ansi = true },
    };

    std.debug.print("render benchmark\n", .{});
    for (scenarios) |scenario| {
        try runScenario(allocator, io, scenario);
    }
}

fn runScenario(sample_allocator: std.mem.Allocator, io: std.Io, scenario: Scenario) !void {
    const render_time = try measureRender(sample_allocator, io, scenario);
    const render_profile = try profileRender(scenario);

    std.debug.print(
        "{s}: n={d} steady_render_median={d:.3}ms [{d:.3}..{d:.3}] render_allocs={d} render_resizes={d} render_bytes={d} out={d}\n",
        .{
            scenario.name,
            render_time.stats.sample_count,
            bench.nsToMs(render_time.stats.median_ns),
            bench.nsToMs(render_time.stats.min_ns),
            bench.nsToMs(render_time.stats.max_ns),
            render_profile.counts.alloc_count,
            render_profile.counts.resize_count,
            render_profile.counts.bytes_allocated,
            render_time.output_bytes,
        },
    );
}

fn measureRender(
    sample_allocator: std.mem.Allocator,
    io: std.Io,
    scenario: Scenario,
) !RenderTiming {
    var doc = try parse(timing_allocator, .{ .borrowed = scenario.input });
    defer doc.deinit();

    var renderer = Renderer.init(timing_allocator, .{
        .enable_ansi = scenario.enable_ansi,
        .ambiguous_width = scenario.ambiguous_width,
    });
    defer renderer.deinit();

    var runner = RenderTimeRunner{
        .allocator = timing_allocator,
        .renderer = &renderer,
        .doc = &doc,
    };

    return .{
        .stats = try bench.measure(io, sample_allocator, bench.default_measure_options, &runner),
        .output_bytes = runner.last_output_bytes,
    };
}

fn profileRender(scenario: Scenario) !RenderProfile {
    var parse_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = parse_gpa.deinit();

    var doc = try parse(parse_gpa.allocator(), .{ .borrowed = scenario.input });
    defer doc.deinit();

    var render_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = render_gpa.deinit();

    var counting = bench.CountingAllocator.init(render_gpa.allocator());
    var renderer = Renderer.init(counting.allocator(), .{
        .enable_ansi = scenario.enable_ansi,
        .ambiguous_width = scenario.ambiguous_width,
    });
    defer renderer.deinit();

    _ = try renderWithDiscarding(&renderer, &doc, counting.allocator());

    const before = counting.snapshot();
    const output_bytes = try renderWithDiscarding(&renderer, &doc, counting.allocator());
    const after = counting.snapshot();

    return .{
        .counts = bench.CounterSnapshot.diff(after, before),
        .output_bytes = output_bytes,
    };
}

fn renderWithDiscarding(
    renderer: *Renderer,
    doc: *const Document,
    cycle_allocator: std.mem.Allocator,
) !usize {
    var sink: [512]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink);
    try renderer.render(&discarding.writer, doc, null, cycle_allocator);
    try discarding.writer.flush();
    const output_bytes = discarding.fullCount();
    std.mem.doNotOptimizeAway(output_bytes);
    return output_bytes;
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
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;

    for (0..table_count) |table_index| {
        try appendAsciiTable(writer, prefix, table_index, row_count, col_count);
        if (table_index + 1 < table_count) {
            try writer.writeByte('\n');
        }
    }

    return aw.toOwnedSlice();
}

fn appendAsciiTable(
    writer: *std.Io.Writer,
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
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;

    for (0..table_count) |table_index| {
        try writeHeader(writer, "", table_index, col_count, true);
        try writeDelimiter(writer, "", col_count);
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

    return aw.toOwnedSlice();
}

fn writeHeader(
    writer: *std.Io.Writer,
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
    writer: *std.Io.Writer,
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
