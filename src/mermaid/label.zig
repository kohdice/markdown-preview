const std = @import("std");
const width_mod = @import("../term/width.zig");

pub const ValidationError = error{InvalidMermaid};

pub fn validate(text: []const u8) ValidationError!void {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidMermaid;

    var it = width_mod.DisplayClusterIterator.init(text, .narrow);
    while (it.next()) |cluster| {
        if (cluster.width == 0) return error.InvalidMermaid;
    }
}

test "validate accepts display clusters with zero-width dependents" {
    try validate("e\u{0301}");
    try validate("\u{2764}\u{FE0F}");
    try validate("\u{1F44D}\u{1F3FB}");
    try validate("\u{1F468}\u{200D}\u{1F469}");
}

test "validate rejects standalone zero-width clusters" {
    try std.testing.expectError(error.InvalidMermaid, validate("foo\u{200D}bar"));
    try std.testing.expectError(error.InvalidMermaid, validate("foo\u{200B}bar"));
    try std.testing.expectError(error.InvalidMermaid, validate("foo\u{200C}bar"));
    try std.testing.expectError(error.InvalidMermaid, validate("foo\u{FEFF}bar"));
}

test "validate rejects invalid UTF-8" {
    try std.testing.expectError(error.InvalidMermaid, validate(&.{0x80}));
}
