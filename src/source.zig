const std = @import("std");

pub const Source = union(enum) {
    borrowed: []const u8,
    owned: Owned,
    mapped: Mapped,

    pub const Owned = struct {
        allocator: std.mem.Allocator,
        buffer: []u8,
    };

    pub const Mapped = struct {
        bytes: []align(std.heap.page_size_min) const u8,
    };

    pub fn bytes(self: Source) []const u8 {
        return switch (self) {
            .borrowed => |b| b,
            .owned => |o| o.buffer,
            .mapped => |m| m.bytes,
        };
    }
};
