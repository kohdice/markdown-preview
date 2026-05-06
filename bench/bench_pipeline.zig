const std = @import("std");
const internals = @import("internals");
const parse = internals.parse.parse;
const Renderer = internals.render.Renderer;
const source_loader = internals.source_loader;
const bench = @import("bench_support.zig");
const fixtures = @import("fixtures");

const AmbiguousWidth = internals.term.width.AmbiguousWidth;
const timing_allocator = std.heap.smp_allocator;

const Scenario = struct {
    name: []const u8,
    spec: fixtures.Spec,
    ambiguous: AmbiguousWidth,
};

const scenarios = [_]Scenario{
    .{ .name = "stress-ascii", .spec = fixtures.stress_ascii, .ambiguous = .narrow },
    .{ .name = "stress-cjk", .spec = fixtures.stress_cjk, .ambiguous = .wide },
};

const TimeRun = struct {
    read_ns: u64,
    parse_ns: u64,
    render_ns: u64,
    input_bytes: usize,
    output_bytes: usize,
};

const TimingSummary = struct {
    input_bytes: usize,
    output_bytes: usize,
    read: bench.DurationStats,
    parse: bench.DurationStats,
    render: bench.DurationStats,
};

const AllocationSummary = struct {
    output_bytes: usize,
    parse_counts: bench.CounterSnapshot,
    render_counts: bench.CounterSnapshot,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var explicit_ambiguous: ?AmbiguousWidth = null;
    var custom_path: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--wide")) {
            explicit_ambiguous = .wide;
        } else if (std.mem.eql(u8, arg, "--narrow")) {
            explicit_ambiguous = .narrow;
        } else {
            custom_path = arg;
        }
    }

    if (custom_path) |path| {
        const ambiguous = explicit_ambiguous orelse blk: {
            for (scenarios) |scenario| {
                if (std.mem.eql(u8, scenario.spec.path, path)) break :blk scenario.ambiguous;
            }
            std.debug.print("warning: ambiguous mode not specified for {s}; defaulting to narrow. Pass --wide for CJK-heavy input.\n", .{path});
            break :blk .narrow;
        };
        std.debug.print("pipeline benchmark (single fixture: {s}, ambiguous={s})\n", .{ path, @tagName(ambiguous) });
        const timing = try measureTiming(allocator, io, path, ambiguous);
        const counts = try profileAllocations(io, path, ambiguous);
        printSummary("custom", timing, counts);
        return;
    }

    std.debug.print("pipeline benchmark (file -> parse -> render -> Discarding)\n", .{});
    for (scenarios) |scenario| {
        try fixtures.ensure(allocator, io, scenario.spec);
        const timing = try measureTiming(allocator, io, scenario.spec.path, scenario.ambiguous);
        const counts = try profileAllocations(io, scenario.spec.path, scenario.ambiguous);
        printSummary(scenario.name, timing, counts);
    }
}

fn printSummary(name: []const u8, timing: TimingSummary, counts: AllocationSummary) void {
    const kib = @as(f64, @floatFromInt(timing.input_bytes)) / 1024.0;
    const parse_peak_kib = @as(f64, @floatFromInt(counts.parse_counts.peak_bytes)) / 1024.0;

    std.debug.print(
        "{s}: n={d} in={d:.1}KiB read={d:.3}ms [{d:.3}..{d:.3}] parse={d:.3}ms [{d:.3}..{d:.3}] render={d:.3}ms [{d:.3}..{d:.3}] parse_allocs={d} parse_peak={d:.1}KiB render_allocs={d} out={d}B\n",
        .{
            name,
            timing.read.sample_count,
            kib,
            bench.nsToMs(timing.read.median_ns),
            bench.nsToMs(timing.read.min_ns),
            bench.nsToMs(timing.read.max_ns),
            bench.nsToMs(timing.parse.median_ns),
            bench.nsToMs(timing.parse.min_ns),
            bench.nsToMs(timing.parse.max_ns),
            bench.nsToMs(timing.render.median_ns),
            bench.nsToMs(timing.render.min_ns),
            bench.nsToMs(timing.render.max_ns),
            counts.parse_counts.alloc_count,
            parse_peak_kib,
            counts.render_counts.alloc_count,
            timing.output_bytes,
        },
    );
}

fn measureTiming(
    sample_allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    ambiguous: AmbiguousWidth,
) !TimingSummary {
    const options = bench.default_measure_options;
    std.debug.assert(options.measured_runs > 0);

    const read_samples = try sample_allocator.alloc(u64, options.measured_runs);
    defer sample_allocator.free(read_samples);
    const parse_samples = try sample_allocator.alloc(u64, options.measured_runs);
    defer sample_allocator.free(parse_samples);
    const render_samples = try sample_allocator.alloc(u64, options.measured_runs);
    defer sample_allocator.free(render_samples);

    for (0..options.warmup_runs) |_| {
        const warm = try runTimedPipeline(timing_allocator, io, path, ambiguous);
        std.mem.doNotOptimizeAway(warm.output_bytes);
    }

    var last_run: TimeRun = undefined;
    for (0..options.measured_runs) |i| {
        last_run = try runTimedPipeline(timing_allocator, io, path, ambiguous);
        read_samples[i] = last_run.read_ns;
        parse_samples[i] = last_run.parse_ns;
        render_samples[i] = last_run.render_ns;
    }

    return .{
        .input_bytes = last_run.input_bytes,
        .output_bytes = last_run.output_bytes,
        .read = bench.DurationStats.summarizeInPlace(read_samples),
        .parse = bench.DurationStats.summarizeInPlace(parse_samples),
        .render = bench.DurationStats.summarizeInPlace(render_samples),
    };
}

fn runTimedPipeline(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    ambiguous: AmbiguousWidth,
) !TimeRun {
    const read_timer = bench.BenchTimer.start(io);
    const source = try source_loader.loadFile(allocator, io, std.Io.Dir.cwd(), path);
    const read_ns = read_timer.read();
    const input_bytes = source.bytes().len;

    const parse_timer = bench.BenchTimer.start(io);
    var doc = try parse(allocator, source);
    const parse_ns = parse_timer.read();
    defer doc.deinit();

    var renderer = Renderer.init(allocator, .{ .ambiguous_width = ambiguous });
    defer renderer.deinit();

    var sink: [4096]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink);

    const render_timer = bench.BenchTimer.start(io);
    try renderer.render(&discarding.writer, &doc, null);
    try discarding.writer.flush();
    const render_ns = render_timer.read();
    const output_bytes = discarding.fullCount();
    std.mem.doNotOptimizeAway(output_bytes);

    return .{
        .read_ns = read_ns,
        .parse_ns = parse_ns,
        .render_ns = render_ns,
        .input_bytes = input_bytes,
        .output_bytes = output_bytes,
    };
}

fn profileAllocations(
    io: std.Io,
    path: []const u8,
    ambiguous: AmbiguousWidth,
) !AllocationSummary {
    var source_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = source_gpa.deinit();

    const source = try source_loader.loadFile(source_gpa.allocator(), io, std.Io.Dir.cwd(), path);

    var parse_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = parse_gpa.deinit();
    var parse_counting = bench.CountingAllocator.init(parse_gpa.allocator());

    const parse_before = parse_counting.snapshot();
    var doc = try parse(parse_counting.allocator(), source);
    const parse_after = parse_counting.snapshot();
    defer doc.deinit();

    var render_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = render_gpa.deinit();
    var render_counting = bench.CountingAllocator.init(render_gpa.allocator());

    var renderer = Renderer.init(render_counting.allocator(), .{ .ambiguous_width = ambiguous });
    defer renderer.deinit();

    var sink: [4096]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink);

    const render_before = render_counting.snapshot();
    try renderer.render(&discarding.writer, &doc, null);
    try discarding.writer.flush();
    const render_after = render_counting.snapshot();
    const output_bytes = discarding.fullCount();

    return .{
        .output_bytes = output_bytes,
        .parse_counts = bench.CounterSnapshot.diff(parse_after, parse_before),
        .render_counts = bench.CounterSnapshot.diff(render_after, render_before),
    };
}
