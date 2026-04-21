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
/// per non-trivial block and the inline phase consumes them in the same
/// depth-first order, so no back-pointer is needed. The `.trivial_*` variants
/// are a hint from the block walker: the input contains no inline triggers,
/// so the inline phase can synthesize the text + soft_break chain directly
/// without running the full inline parser.
pub const PendingInline = union(enum) {
    full_single: []const u8,
    full_multi: []const []const u8,
    trivial_single: []const u8,
    trivial_multi: []const []const u8,
};

test "PendingInline.full_single carries the line verbatim" {
    const entry: PendingInline = .{ .full_single = "hello" };
    try std.testing.expect(entry == .full_single);
    try std.testing.expectEqualStrings("hello", entry.full_single);
}

test "PendingInline.trivial_multi carries the lines slice verbatim" {
    const lines = [_][]const u8{ "alpha", "beta" };
    const entry: PendingInline = .{ .trivial_multi = &lines };
    try std.testing.expect(entry == .trivial_multi);
    try std.testing.expectEqual(@as(usize, 2), entry.trivial_multi.len);
    try std.testing.expectEqualStrings("alpha", entry.trivial_multi[0]);
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
