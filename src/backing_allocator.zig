const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum { debug, c, smp };

pub fn pickKind(
    comptime mode: std.builtin.OptimizeMode,
    comptime has_libc: bool,
) Kind {
    return switch (mode) {
        .Debug, .ReleaseSafe => .debug,
        .ReleaseFast, .ReleaseSmall => if (has_libc) .c else .smp,
    };
}

const current_kind: Kind = pickKind(builtin.mode, builtin.link_libc);

pub const Backing = union(Kind) {
    debug: std.heap.DebugAllocator(.{}),
    c: void,
    smp: void,

    pub const init: Backing = switch (current_kind) {
        .debug => .{ .debug = .init },
        .c => .c,
        .smp => .smp,
    };

    pub fn allocator(self: *Backing) std.mem.Allocator {
        return switch (self.*) {
            .debug => |*gpa| gpa.allocator(),
            .c => std.heap.c_allocator,
            .smp => std.heap.smp_allocator,
        };
    }

    pub fn deinit(self: *Backing) std.heap.Check {
        return switch (self.*) {
            .debug => |*gpa| gpa.deinit(),
            .c, .smp => .ok,
        };
    }
};

test "pickKind returns debug for Debug regardless of libc" {
    try std.testing.expectEqual(Kind.debug, pickKind(.Debug, false));
    try std.testing.expectEqual(Kind.debug, pickKind(.Debug, true));
}

test "pickKind returns debug for ReleaseSafe regardless of libc" {
    try std.testing.expectEqual(Kind.debug, pickKind(.ReleaseSafe, false));
    try std.testing.expectEqual(Kind.debug, pickKind(.ReleaseSafe, true));
}

test "pickKind returns c for ReleaseFast with libc" {
    try std.testing.expectEqual(Kind.c, pickKind(.ReleaseFast, true));
}

test "pickKind returns c for ReleaseSmall with libc" {
    try std.testing.expectEqual(Kind.c, pickKind(.ReleaseSmall, true));
}

test "pickKind returns smp for ReleaseFast without libc" {
    try std.testing.expectEqual(Kind.smp, pickKind(.ReleaseFast, false));
}

test "pickKind returns smp for ReleaseSmall without libc" {
    try std.testing.expectEqual(Kind.smp, pickKind(.ReleaseSmall, false));
}

test "Backing.init selects the kind reported by current_kind" {
    var backing: Backing = .init;
    defer _ = backing.deinit();
    try std.testing.expectEqual(current_kind, @as(Kind, backing));
}

test "Backing.allocator returns a usable allocator" {
    var backing: Backing = .init;
    defer _ = backing.deinit();
    const a = backing.allocator();
    const buf = try a.alloc(u8, 128);
    defer a.free(buf);
    buf[0] = 0xAB;
    buf[127] = 0xCD;
    try std.testing.expectEqual(@as(u8, 0xAB), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xCD), buf[127]);
}

test "Backing.deinit on debug kind reports ok when no leak" {
    if (comptime current_kind != .debug) return;
    var backing: Backing = .init;
    const a = backing.allocator();
    const buf = try a.alloc(u8, 64);
    a.free(buf);
    try std.testing.expectEqual(std.heap.Check.ok, backing.deinit());
}

test "Backing.deinit on stateless kinds reports ok" {
    if (comptime current_kind == .debug) return;
    var backing: Backing = .init;
    try std.testing.expectEqual(std.heap.Check.ok, backing.deinit());
}
