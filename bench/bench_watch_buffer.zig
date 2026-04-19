const std = @import("std");
const render_buffer_mod = @import("render_buffer");
const bench = @import("bench_support.zig");

const RenderBuffer = render_buffer_mod.RenderBuffer;

const Scenario = struct {
    name: []const u8,
    total_bytes: usize,
    line_length: usize,
    chunk_size: usize,
};

const Run = struct {
    elapsed_ns: u64,
    counts: bench.CounterSnapshot,
    total_bytes: usize,
    total_lines: usize,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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

        const cold = try runOnce(scenario, payload);
        const warm = try runOnce(scenario, payload);

        const mib = @as(f64, @floatFromInt(scenario.total_bytes)) / (1024.0 * 1024.0);
        std.debug.print(
            "{s}: cold={d:.3}ms ({d:.1} MiB/s) allocs={d} bytes_alloc={d}  warm={d:.3}ms ({d:.1} MiB/s) allocs={d} bytes_alloc={d}  lines={d}\n",
            .{
                scenario.name,
                nsToMs(cold.elapsed_ns),
                mib / (nsToMs(cold.elapsed_ns) / 1000.0),
                cold.counts.alloc_count,
                cold.counts.bytes_allocated,
                nsToMs(warm.elapsed_ns),
                mib / (nsToMs(warm.elapsed_ns) / 1000.0),
                warm.counts.alloc_count,
                warm.counts.bytes_allocated,
                cold.total_lines,
            },
        );
    }
}

fn runOnce(scenario: Scenario, payload: []const u8) !Run {
    var counting = bench.CountingAllocator.init(std.heap.smp_allocator);
    var rb = RenderBuffer.init(counting.allocator());
    defer rb.deinit();

    const before = counting.snapshot();
    var timer = try std.time.Timer.start();

    var pos: usize = 0;
    while (pos < payload.len) {
        const end = @min(pos + scenario.chunk_size, payload.len);
        try rb.writer.writeAll(payload[pos..end]);
        pos = end;
    }
    try rb.writer.flush();

    const elapsed = timer.read();
    const after = counting.snapshot();

    return .{
        .elapsed_ns = elapsed,
        .counts = bench.CounterSnapshot.diff(after, before),
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

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}
