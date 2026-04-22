const std = @import("std");

/// Monotonic stopwatch helper for benchmark harnesses.
///
/// Replaces the removed `std.time.Timer` API on Zig 0.16.0. Backed by
/// `std.Io.Clock` so platform-specific clock source selection (e.g.
/// `CLOCK_MONOTONIC` on Linux, `CLOCK_UPTIME_RAW` on macOS) lives inside
/// the `Io` implementation rather than the bench code.
pub const BenchTimer = struct {
    io: std.Io,
    start_ts: std.Io.Clock.Timestamp,

    /// Captures a starting timestamp on the `awake` (monotonic) clock.
    pub fn start(io: std.Io) BenchTimer {
        return .{
            .io = io,
            .start_ts = std.Io.Clock.Timestamp.now(io, .awake),
        };
    }

    /// Returns nanoseconds elapsed since `start`.
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
