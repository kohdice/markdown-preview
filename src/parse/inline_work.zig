const std = @import("std");
const ast = @import("../ast.zig");

pub const InlineWork = struct {
    target: *ast.InlineRef,
    input: Input,

    pub const Input = union(enum) {
        lines: []const []const u8,
        slice: []const u8,
    };
};

test "InlineWork.Input carries paragraph lines verbatim" {
    var ref: ast.InlineRef = ast.no_inline;
    const lines = [_][]const u8{ "one", "two" };
    const work: InlineWork = .{
        .target = &ref,
        .input = .{ .lines = &lines },
    };
    try std.testing.expect(work.input == .lines);
    try std.testing.expectEqual(@as(usize, 2), work.input.lines.len);
    try std.testing.expectEqualStrings("one", work.input.lines[0]);
    try std.testing.expectEqualStrings("two", work.input.lines[1]);
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

test "InlineWork target holds ast.no_inline sentinel before resolution" {
    var ref: ast.InlineRef = ast.no_inline;
    const work: InlineWork = .{
        .target = &ref,
        .input = .{ .slice = "" },
    };
    try std.testing.expectEqual(ast.no_inline, work.target.*);
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
