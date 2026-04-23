const std = @import("std");

/// Mermaid parsers only need a stable byte buffer after directive stripping.
/// This stays narrower than root `src/source.zig`, which also models loader
/// provenance such as mapped files and allocator-carrying owned buffers.
pub const Source = union(enum) {
    borrowed: []const u8,
    owned: []u8,

    pub fn bytes(self: Source) []const u8 {
        return switch (self) {
            .borrowed => |s| s,
            .owned => |s| s,
        };
    }
};

pub fn normalizeOwned(allocator: std.mem.Allocator, source: anytype) error{OutOfMemory}![]u8 {
    if (@TypeOf(source) == Source) {
        return switch (source) {
            .borrowed => |bytes| try allocator.dupe(u8, bytes),
            .owned => |bytes| bytes,
        };
    }

    return try allocator.dupe(u8, source);
}
