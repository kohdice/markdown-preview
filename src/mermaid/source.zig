const std = @import("std");

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
