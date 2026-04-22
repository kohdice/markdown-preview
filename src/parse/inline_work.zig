const std = @import("std");
const ast = @import("../ast.zig");

/// Inline resolution for a table cell: rows are resolved after the block walk
/// so the `target` pointer bridges their order mismatch with `PendingInline`.
pub const InlineWork = struct {
    target: *ast.InlineRef,
    input: Input,

    pub const Input = union(enum) {
        slice: []const u8,
    };
};

/// Queued paragraph / heading inline work. The block walk records one entry
/// per paragraph / heading and the inline phase consumes them in the same
/// depth-first order, so no back-pointer is needed.
pub const PendingInline = union(enum) {
    single: []const u8,
    multi: []const []const u8,
};

test "PendingInline.single carries the line verbatim" {
    const entry: PendingInline = .{ .single = "hello" };
    try std.testing.expect(entry == .single);
    try std.testing.expectEqualStrings("hello", entry.single);
}

test "PendingInline.multi carries the lines slice verbatim" {
    const lines = [_][]const u8{ "alpha", "beta" };
    const entry: PendingInline = .{ .multi = &lines };
    try std.testing.expect(entry == .multi);
    try std.testing.expectEqual(@as(usize, 2), entry.multi.len);
    try std.testing.expectEqualStrings("alpha", entry.multi[0]);
}

test "InlineWork.Input carries table cell slice verbatim" {
    var ref: ast.InlineRef = ast.no_inline;
    const work: InlineWork = .{
        .target = &ref,
        .input = .{ .slice = "cell text" },
    };
    try std.testing.expect(work.input == .slice);
    try std.testing.expectEqualStrings("cell text", work.input.slice);
}

test "InlineWork target mutation writes through to pointed InlineRef" {
    var ref: ast.InlineRef = ast.no_inline;
    const work: InlineWork = .{
        .target = &ref,
        .input = .{ .slice = "x" },
    };
    work.target.* = 7;
    try std.testing.expectEqual(@as(ast.InlineRef, 7), ref);
}
