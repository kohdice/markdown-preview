const std = @import("std");
const internals = @import("internals");
const parse = internals.parse.parse;
const Document = internals.parse.Document;
const Renderer = internals.render.Renderer;
const bench = @import("bench_support.zig");

const timing_allocator = std.heap.smp_allocator;

const Scenario = struct {
    name: []const u8,
    input: []const u8,
    enable_ansi: bool = false,
    wrap_width: ?usize = null,
};

const RenderTiming = struct {
    stats: bench.DurationStats,
    output_bytes: usize,
};

const RenderProfile = struct {
    counts: bench.CounterSnapshot,
    output_bytes: usize,
};

const ParseTimeRunner = struct {
    allocator: std.mem.Allocator,
    input: []const u8,

    pub fn run(self: *@This()) !void {
        var doc = try parse(self.allocator, .{ .borrowed = self.input });
        defer doc.deinit();
        std.mem.doNotOptimizeAway(doc.blocks.len);
    }
};

const RenderTimeRunner = struct {
    allocator: std.mem.Allocator,
    renderer: *Renderer,
    doc: *const Document,
    wrap_width: ?usize,
    last_output_bytes: usize = 0,

    pub fn run(self: *@This()) !void {
        self.last_output_bytes = try renderWithDiscarding(
            self.renderer,
            self.doc,
            self.wrap_width,
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
        .{ .name = "paragraph-1000-lines", .input = try makeParagraphInput(allocator, 1000, "alpha beta gamma delta epsilon") },
        .{ .name = "paragraph-100k", .input = try makeRepeatedInlineInput(allocator, 7000, "This is **bold** and [linked](https://example.com) text. ") },
        .{ .name = "nested-inline-depth-64", .input = try makeNestedInlineInput(allocator, 64) },
        .{ .name = "reference-links-256", .input = try makeReferenceLinkInput(allocator, 256) },
        .{ .name = "many-paragraphs-1024", .input = try makeManyParagraphsInput(allocator, 1024) },
        .{ .name = "many-headings-1024", .input = try makeManyHeadingsInput(allocator, 1024) },
        .{ .name = "table-cells-4096", .input = try makeTableInput(allocator, 64, 64) },
        .{ .name = "paragraph-100k-ansi", .input = try makeRepeatedInlineInput(allocator, 7000, "This is **bold** and [linked](https://example.com) text. "), .enable_ansi = true },
        .{ .name = "many-paragraphs-1024-ansi", .input = try makeManyParagraphsInput(allocator, 1024), .enable_ansi = true },
        .{ .name = "table-cells-4096-ansi", .input = try makeTableInput(allocator, 64, 64), .enable_ansi = true },
    };

    std.debug.print("inline benchmark\n", .{});
    for (scenarios) |scenario| {
        try runScenario(allocator, io, scenario);
    }
}

fn runScenario(sample_allocator: std.mem.Allocator, io: std.Io, scenario: Scenario) !void {
    const wrap_width: ?usize = scenario.wrap_width orelse 80;
    const parse_time = try measureParse(sample_allocator, io, scenario);
    const render_time = try measureRender(sample_allocator, io, scenario, wrap_width);
    const parse_profile = try profileParse(scenario);
    const render_profile = try profileRender(scenario, wrap_width);

    std.debug.print(
        "{s}: n={d} parse_median={d:.3}ms [{d:.3}..{d:.3}] render_median={d:.3}ms [{d:.3}..{d:.3}] parse_allocs={d} parse_resizes={d} parse_bytes={d} render_allocs={d} render_resizes={d} render_bytes={d} out={d}\n",
        .{
            scenario.name,
            parse_time.sample_count,
            bench.nsToMs(parse_time.median_ns),
            bench.nsToMs(parse_time.min_ns),
            bench.nsToMs(parse_time.max_ns),
            bench.nsToMs(render_time.stats.median_ns),
            bench.nsToMs(render_time.stats.min_ns),
            bench.nsToMs(render_time.stats.max_ns),
            parse_profile.alloc_count,
            parse_profile.resize_count,
            parse_profile.bytes_allocated,
            render_profile.counts.alloc_count,
            render_profile.counts.resize_count,
            render_profile.counts.bytes_allocated,
            render_time.output_bytes,
        },
    );
}

fn measureParse(
    sample_allocator: std.mem.Allocator,
    io: std.Io,
    scenario: Scenario,
) !bench.DurationStats {
    var runner = ParseTimeRunner{
        .allocator = timing_allocator,
        .input = scenario.input,
    };
    return bench.measure(io, sample_allocator, bench.default_measure_options, &runner);
}

fn measureRender(
    sample_allocator: std.mem.Allocator,
    io: std.Io,
    scenario: Scenario,
    wrap_width: ?usize,
) !RenderTiming {
    var doc = try parse(timing_allocator, .{ .borrowed = scenario.input });
    defer doc.deinit();

    var renderer = Renderer.init(timing_allocator, .{
        .enable_ansi = scenario.enable_ansi,
    });
    defer renderer.deinit();

    var runner = RenderTimeRunner{
        .allocator = timing_allocator,
        .renderer = &renderer,
        .doc = &doc,
        .wrap_width = wrap_width,
    };

    return .{
        .stats = try bench.measure(io, sample_allocator, bench.default_measure_options, &runner),
        .output_bytes = runner.last_output_bytes,
    };
}

fn profileParse(scenario: Scenario) !bench.CounterSnapshot {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var counting = bench.CountingAllocator.init(gpa.allocator());
    const before = counting.snapshot();
    var doc = try parse(counting.allocator(), .{ .borrowed = scenario.input });
    defer doc.deinit();
    const after = counting.snapshot();
    return bench.CounterSnapshot.diff(after, before);
}

fn profileRender(scenario: Scenario, wrap_width: ?usize) !RenderProfile {
    var parse_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = parse_gpa.deinit();

    var doc = try parse(parse_gpa.allocator(), .{ .borrowed = scenario.input });
    defer doc.deinit();

    var render_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = render_gpa.deinit();

    var counting = bench.CountingAllocator.init(render_gpa.allocator());
    var renderer = Renderer.init(counting.allocator(), .{
        .enable_ansi = scenario.enable_ansi,
    });
    defer renderer.deinit();

    _ = try renderWithDiscarding(&renderer, &doc, wrap_width, counting.allocator());

    const before = counting.snapshot();
    const output_bytes = try renderWithDiscarding(&renderer, &doc, wrap_width, counting.allocator());
    const after = counting.snapshot();

    return .{
        .counts = bench.CounterSnapshot.diff(after, before),
        .output_bytes = output_bytes,
    };
}

fn renderWithDiscarding(
    renderer: *Renderer,
    doc: *const Document,
    wrap_width: ?usize,
    cycle_allocator: std.mem.Allocator,
) !usize {
    var sink: [512]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink);
    try renderer.render(&discarding.writer, doc, wrap_width, cycle_allocator);
    try discarding.writer.flush();
    const output_bytes = discarding.fullCount();
    std.mem.doNotOptimizeAway(output_bytes);
    return output_bytes;
}

fn makeParagraphInput(allocator: std.mem.Allocator, line_count: usize, line: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (0..line_count) |_| {
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

fn makeRepeatedInlineInput(allocator: std.mem.Allocator, repeat_count: usize, segment: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (0..repeat_count) |_| {
        try out.appendSlice(allocator, segment);
    }

    return out.toOwnedSlice(allocator);
}

fn makeNestedInlineInput(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
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
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (0..count) |i| {
        try out.print(allocator, "Paragraph {d} with **bold** and *italic* text.\n\n", .{i});
    }

    return out.toOwnedSlice(allocator);
}

fn makeManyHeadingsInput(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (0..count) |i| {
        const level = (i % 6) + 1;
        for (0..level) |_| try out.append(allocator, '#');
        try out.print(allocator, " Heading {d}\n\n", .{i});
    }

    return out.toOwnedSlice(allocator);
}

fn makeTableInput(allocator: std.mem.Allocator, rows: usize, cols: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (0..cols) |c| {
        if (c > 0) try out.append(allocator, '|');
        try out.print(allocator, " H{d} ", .{c});
    }
    try out.append(allocator, '\n');

    for (0..cols) |c| {
        if (c > 0) try out.append(allocator, '|');
        try out.appendSlice(allocator, " --- ");
    }
    try out.append(allocator, '\n');

    for (0..rows) |r| {
        for (0..cols) |c| {
            if (c > 0) try out.append(allocator, '|');
            try out.print(allocator, " R{d}C{d} ", .{ r, c });
        }
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

fn makeReferenceLinkInput(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (0..count) |index| {
        try out.print(allocator, "[label-{d}]: https://example.com/{d} \"title-{d}\"\n", .{
            index,
            index,
            index,
        });
    }
    try out.append(allocator, '\n');

    for (0..count) |index| {
        try out.print(allocator, "[label-{d}][label-{d}] ", .{ index, index });
    }
    try out.append(allocator, '\n');

    return out.toOwnedSlice(allocator);
}
