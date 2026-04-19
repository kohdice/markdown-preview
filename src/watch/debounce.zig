const std = @import("std");

pub const DebounceState = struct {
    deadline_ns: ?u64 = null,

    pub fn schedule(self: *DebounceState, now_ns: u64, window_ns: u64) void {
        self.deadline_ns = now_ns + window_ns;
    }

    pub fn pollTimeoutMs(self: *const DebounceState, now_ns: u64) i32 {
        const deadline = self.deadline_ns orelse return -1;
        if (now_ns >= deadline) return 0;
        const remaining_ns = deadline - now_ns;
        const remaining_ms = (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        if (remaining_ms > std.math.maxInt(i32)) return std.math.maxInt(i32);
        return @intCast(remaining_ms);
    }

    pub fn expired(self: *const DebounceState, now_ns: u64) bool {
        const deadline = self.deadline_ns orelse return false;
        return now_ns >= deadline;
    }

    pub fn isPending(self: *const DebounceState) bool {
        return self.deadline_ns != null;
    }

    pub fn clear(self: *DebounceState) void {
        self.deadline_ns = null;
    }
};

const ns_per_ms: u64 = std.time.ns_per_ms;

test "DebounceState fresh has infinite poll timeout" {
    const state: DebounceState = .{};
    try std.testing.expectEqual(@as(i32, -1), state.pollTimeoutMs(0));
}

test "DebounceState fresh is not pending" {
    const state: DebounceState = .{};
    try std.testing.expect(!state.isPending());
}

test "DebounceState schedule produces positive poll timeout" {
    var state: DebounceState = .{};
    state.schedule(100 * ns_per_ms, 100 * ns_per_ms);
    try std.testing.expectEqual(@as(i32, 50), state.pollTimeoutMs(150 * ns_per_ms));
    try std.testing.expect(state.isPending());
}

test "DebounceState expired after deadline" {
    var state: DebounceState = .{};
    state.schedule(100 * ns_per_ms, 100 * ns_per_ms);
    try std.testing.expect(state.expired(200 * ns_per_ms));
    try std.testing.expectEqual(@as(i32, 0), state.pollTimeoutMs(200 * ns_per_ms));
}

test "DebounceState second schedule extends window" {
    var state: DebounceState = .{};
    state.schedule(100 * ns_per_ms, 100 * ns_per_ms);
    state.schedule(150 * ns_per_ms, 100 * ns_per_ms);
    try std.testing.expectEqual(@as(i32, 70), state.pollTimeoutMs(180 * ns_per_ms));
    try std.testing.expect(!state.expired(180 * ns_per_ms));
}

test "DebounceState clear reverts to infinite timeout" {
    var state: DebounceState = .{};
    state.schedule(100 * ns_per_ms, 100 * ns_per_ms);
    state.clear();
    try std.testing.expectEqual(@as(i32, -1), state.pollTimeoutMs(200 * ns_per_ms));
    try std.testing.expect(!state.isPending());
}

test "DebounceState pollTimeoutMs rounds sub-millisecond remaining up to 1" {
    var state: DebounceState = .{};
    state.schedule(0, 100 * ns_per_ms + 500_000);
    try std.testing.expectEqual(@as(i32, 1), state.pollTimeoutMs(100 * ns_per_ms));
}
