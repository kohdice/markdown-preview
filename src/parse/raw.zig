const std = @import("std");
const ast = @import("../ast.zig");

pub const TextSpan = []const u8;

pub const RawParagraph = struct {
    lines: []const TextSpan,
};

pub const RawHeading = struct {
    level: u8,
    lines: []const TextSpan,
};

pub const RawCodeBlock = struct {
    content: TextSpan,
};

pub const RawCodeFence = struct {
    opener: TextSpan,
    closer: ?TextSpan,
    language: TextSpan,
    content: TextSpan,
};

pub const RawBlockQuote = struct {
    indent: usize,
    children: []const RawBlock,
};

pub const RawListItem = struct {
    indent: usize,
    marker: u8,
    number: ?TextSpan = null,
    checked: ?bool = null,
    children: []const RawBlock,
};

pub const RawList = struct {
    kind: ast.ListKind,
    items: []const RawListItem,
    loose: bool = false,
};

pub const RawTable = struct {
    header: []const TextSpan,
    alignments: []const ast.Alignment,
    rows: []const []const TextSpan,
};

pub const RawBlock = union(enum) {
    paragraph: RawParagraph,
    heading: RawHeading,
    blockquote: RawBlockQuote,
    list: RawList,
    code_block: RawCodeBlock,
    code_fence: RawCodeFence,
    thematic_break: void,
    table: RawTable,
    blank_line: void,
};

pub const BuildError = std.mem.Allocator.Error || error{UnclosedCodeSpan};

pub const RawDocument = struct {
    blocks: []const RawBlock,
    link_defs: ast.LinkDefMap,
};

test "RawBlock union constructs each variant" {
    const p: RawBlock = .{ .paragraph = .{ .lines = &.{} } };
    try std.testing.expect(p == .paragraph);

    const h: RawBlock = .{ .heading = .{ .level = 1, .lines = &.{"x"} } };
    try std.testing.expect(h == .heading);
    try std.testing.expectEqual(@as(u8, 1), h.heading.level);

    const tb: RawBlock = .thematic_break;
    try std.testing.expect(tb == .thematic_break);

    const bl: RawBlock = .blank_line;
    try std.testing.expect(bl == .blank_line);
}
