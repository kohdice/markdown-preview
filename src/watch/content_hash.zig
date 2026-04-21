const std = @import("std");

pub const CheckResult = enum { changed, unchanged };

pub const Compare = struct {
    result: CheckResult,
    hash: u64,
};

pub const ContentHash = struct {
    last: ?u64 = null,

    pub fn compare(self: *const ContentHash, bytes: []const u8) Compare {
        const h = std.hash.XxHash3.hash(0, bytes);
        const result: CheckResult = if (self.last) |prev|
            (if (prev == h) .unchanged else .changed)
        else
            .changed;
        return .{ .result = result, .hash = h };
    }

    pub fn commit(self: *ContentHash, hash: u64) void {
        self.last = hash;
    }

    pub fn reset(self: *ContentHash) void {
        self.last = null;
    }
};

test "ContentHash first compare reports changed" {
    var hash: ContentHash = .{};
    try std.testing.expectEqual(CheckResult.changed, hash.compare("hello").result);
}

test "ContentHash compare without commit does not confirm hash" {
    var hash: ContentHash = .{};
    _ = hash.compare("hello");
    try std.testing.expectEqual(CheckResult.changed, hash.compare("hello").result);
}

test "ContentHash identical bytes report unchanged after commit" {
    var hash: ContentHash = .{};
    const c = hash.compare("hello");
    hash.commit(c.hash);
    try std.testing.expectEqual(CheckResult.unchanged, hash.compare("hello").result);
}

test "ContentHash different bytes report changed" {
    var hash: ContentHash = .{};
    const c = hash.compare("hello");
    hash.commit(c.hash);
    try std.testing.expectEqual(CheckResult.changed, hash.compare("world").result);
}

test "ContentHash reset forces next compare to changed" {
    var hash: ContentHash = .{};
    const c = hash.compare("hello");
    hash.commit(c.hash);
    hash.reset();
    try std.testing.expectEqual(CheckResult.changed, hash.compare("hello").result);
}
