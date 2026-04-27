const std = @import("std");
const render_buffer_mod = @import("render_buffer");
const bench = @import("bench_support.zig");

const RenderBuffer = render_buffer_mod.RenderBuffer;
const timing_allocator = std.heap.smp_allocator;

const Scenario = struct {
    name: []const u8,
    total_bytes: usize,
    line_length: usize,
    chunk_size: usize,
};

const TimingResult = struct {
    stats: bench.DurationStats,
    total_bytes: usize,
    total_lines: usize,
};

const Run = struct {
    total_bytes: usize,
    total_lines: usize,
};

const TimeRunner = struct {
    allocator: std.mem.Allocator,
    scenario: Scenario,
    payload: []const u8,
    last_run: Run = .{ .total_bytes = 0, .total_lines = 0 },

    pub fn run(self: *@This()) !void {
        self.last_run = try runBuffer(self.allocator, self.scenario, self.payload);
        std.mem.doNotOptimizeAway(self.last_run.total_lines);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scenarios = [_]Scenario{
        .{ .name = "1MiB-ascii-lines80-chunk4096", .total_bytes = 1 << 20, .line_length = 80, .chunk_size = 4096 },
        .{ .name = "1MiB-ascii-lines80-chunk64", .total_bytes = 1 << 20, .line_length = 80, .chunk_size = 64 },
        .{ .name = "1MiB-ascii-lines80-chunk1", .total_bytes = 1 << 20, .line_length = 80, .chunk_size = 1 },
        .{ .name = "4MiB-ascii-lines200-chunk4096", .total_bytes = 4 << 20, .line_length = 200, .chunk_size = 4096 },
    };

    std.debug.print("watch buffer benchmark\n", .{});
    for (scenarios) |scenario| {
        const payload = try makePayload(allocator, scenario.total_bytes, scenario.line_length);
        defer allocator.free(payload);

        const timing = try measureTiming(allocator, io, scenario, payload);
        const counts = try profileAllocations(scenario, payload);

        std.debug.print(
            "{s}: n={d} median={d:.3}ms ({d:.1} MiB/s) [{d:.3}..{d:.3}] allocs={d} bytes_alloc={d} lines={d}\n",
            .{
                scenario.name,
                timing.stats.sample_count,
                bench.nsToMs(timing.stats.median_ns),
                bench.throughputMiBps(scenario.total_bytes, timing.stats.median_ns),
                bench.nsToMs(timing.stats.min_ns),
                bench.nsToMs(timing.stats.max_ns),
                counts.alloc_count,
                counts.bytes_allocated,
                timing.total_lines,
            },
        );
    }
}

fn measureTiming(
    sample_allocator: std.mem.Allocator,
    io: std.Io,
    scenario: Scenario,
    payload: []const u8,
) !TimingResult {
    var runner = TimeRunner{
        .allocator = timing_allocator,
        .scenario = scenario,
        .payload = payload,
    };

    return .{
        .stats = try bench.measure(io, sample_allocator, bench.default_measure_options, &runner),
        .total_bytes = runner.last_run.total_bytes,
        .total_lines = runner.last_run.total_lines,
    };
}

fn profileAllocations(scenario: Scenario, payload: []const u8) !bench.CounterSnapshot {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var counting = bench.CountingAllocator.init(gpa.allocator());
    const before = counting.snapshot();
    _ = try runBuffer(counting.allocator(), scenario, payload);
    const after = counting.snapshot();
    return bench.CounterSnapshot.diff(after, before);
}

fn runBuffer(
    allocator: std.mem.Allocator,
    scenario: Scenario,
    payload: []const u8,
) !Run {
    var rb: RenderBuffer = undefined;
    rb.init(allocator);
    defer rb.deinit();

    var pos: usize = 0;
    while (pos < payload.len) {
        const end = @min(pos + scenario.chunk_size, payload.len);
        try rb.writer.writeAll(payload[pos..end]);
        pos = end;
    }
    try rb.writer.flush();

    return .{
        .total_bytes = rb.buffered().len,
        .total_lines = rb.totalLines(),
    };
}

fn makePayload(allocator: std.mem.Allocator, total: usize, line_length: usize) ![]u8 {
    std.debug.assert(line_length > 0);
    const buf = try allocator.alloc(u8, total);
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const col = i % (line_length + 1);
        buf[i] = if (col == line_length) '\n' else @intCast('a' + @as(u8, @intCast(i % 26)));
    }
    return buf;
}
