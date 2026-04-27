const std = @import("std");

pub const MeasureOptions = struct {
    warmup_runs: usize = 3,
    measured_runs: usize = 10,
};

pub const default_measure_options: MeasureOptions = .{};

pub const BenchTimer = struct {
    io: std.Io,
    start_ts: std.Io.Clock.Timestamp,

    pub fn start(io: std.Io) BenchTimer {
        return .{
            .io = io,
            .start_ts = std.Io.Clock.Timestamp.now(io, .awake),
        };
    }

    pub fn read(self: BenchTimer) u64 {
        const now_ts = std.Io.Clock.Timestamp.now(self.io, .awake);
        const ns = self.start_ts.durationTo(now_ts).raw.nanoseconds;
        if (ns <= 0) return 0;
        return @intCast(ns);
    }
};

test "BenchTimer.read returns non-decreasing nanoseconds" {
    var timer = BenchTimer.start(std.testing.io);
    const first = timer.read();
    var spin: usize = 0;
    while (spin < 64) : (spin += 1) {
        std.mem.doNotOptimizeAway(spin);
    }
    const second = timer.read();
    try std.testing.expect(second >= first);
}

pub const DurationStats = struct {
    sample_count: usize,
    min_ns: u64,
    median_ns: u64,
    max_ns: u64,

    pub fn summarizeInPlace(samples: []u64) DurationStats {
        std.debug.assert(samples.len > 0);

        std.mem.sort(u64, samples, {}, lessThanU64);
        const mid = samples.len / 2;
        const median_ns = if (samples.len % 2 == 1)
            samples[mid]
        else
            @as(u64, @intCast((@as(u128, samples[mid - 1]) + samples[mid]) / 2));

        return .{
            .sample_count = samples.len,
            .min_ns = samples[0],
            .median_ns = median_ns,
            .max_ns = samples[samples.len - 1],
        };
    }

    fn lessThanU64(_: void, lhs: u64, rhs: u64) bool {
        return lhs < rhs;
    }
};

pub fn measure(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: MeasureOptions,
    runner: anytype,
) !DurationStats {
    std.debug.assert(options.measured_runs > 0);

    for (0..options.warmup_runs) |_| {
        try runner.run();
    }

    const samples = try allocator.alloc(u64, options.measured_runs);
    defer allocator.free(samples);

    for (samples) |*sample| {
        const timer = BenchTimer.start(io);
        try runner.run();
        sample.* = timer.read();
    }

    return DurationStats.summarizeInPlace(samples);
}

pub fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

pub fn throughputMiBps(total_bytes: usize, ns: u64) f64 {
    if (ns == 0) return 0;
    const mib = @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0);
    return mib / (nsToMs(ns) / 1000.0);
}

test "DurationStats.summarizeInPlace reports median for even sample count" {
    var samples = [_]u64{ 90, 10, 70, 30 };
    const stats = DurationStats.summarizeInPlace(&samples);

    try std.testing.expectEqual(@as(usize, 4), stats.sample_count);
    try std.testing.expectEqual(@as(u64, 10), stats.min_ns);
    try std.testing.expectEqual(@as(u64, 50), stats.median_ns);
    try std.testing.expectEqual(@as(u64, 90), stats.max_ns);
}

pub const CounterSnapshot = struct {
    alloc_count: usize,
    resize_count: usize,
    free_count: usize,
    bytes_allocated: usize,
    bytes_freed: usize,
    live_bytes: usize,
    peak_bytes: usize,

    pub fn diff(after: CounterSnapshot, before: CounterSnapshot) CounterSnapshot {
        return .{
            .alloc_count = after.alloc_count - before.alloc_count,
            .resize_count = after.resize_count - before.resize_count,
            .free_count = after.free_count - before.free_count,
            .bytes_allocated = after.bytes_allocated - before.bytes_allocated,
            .bytes_freed = after.bytes_freed - before.bytes_freed,
            .live_bytes = after.live_bytes -| before.live_bytes,
            .peak_bytes = after.peak_bytes - before.peak_bytes,
        };
    }
};

pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    alloc_count: usize = 0,
    resize_count: usize = 0,
    free_count: usize = 0,
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn snapshot(self: *const CountingAllocator) CounterSnapshot {
        return .{
            .alloc_count = self.alloc_count,
            .resize_count = self.resize_count,
            .free_count = self.free_count,
            .bytes_allocated = self.bytes_allocated,
            .bytes_freed = self.bytes_freed,
            .live_bytes = self.live_bytes,
            .peak_bytes = self.peak_bytes,
        };
    }

    fn recordGrow(self: *CountingAllocator, delta: usize) void {
        self.bytes_allocated += delta;
        self.live_bytes += delta;
        if (self.live_bytes > self.peak_bytes) self.peak_bytes = self.live_bytes;
    }

    fn recordShrink(self: *CountingAllocator, delta: usize) void {
        self.bytes_freed += delta;
        self.live_bytes -|= delta;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.alloc_count += 1;
        self.recordGrow(len);
        return ptr;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.child.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) {
            self.resize_count += 1;
            if (new_len > memory.len) {
                self.recordGrow(new_len - memory.len);
            } else {
                self.recordShrink(memory.len - new_len);
            }
        }
        return ok;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.resize_count += 1;
        if (new_len > memory.len) {
            self.recordGrow(new_len - memory.len);
        } else {
            self.recordShrink(memory.len - new_len);
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.free_count += 1;
        self.recordShrink(memory.len);
        self.child.rawFree(memory, alignment, ret_addr);
    }
};
