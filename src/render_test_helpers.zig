const std = @import("std");
const parse = @import("parse.zig");
const render = @import("render.zig");

pub fn renderToOwnedSlice(
    allocator: std.mem.Allocator,
    input: []const u8,
    opts: render.RenderOptions,
) ![]u8 {
    var output: std.io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var doc = try parse.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try render.renderDocument(allocator, &output.writer, doc, opts);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
