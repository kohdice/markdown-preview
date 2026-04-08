const std = @import("std");
const render = @import("render.zig");

pub fn renderToOwnedSlice(
    allocator: std.mem.Allocator,
    input: []const u8,
    opts: render.RenderOptions,
) ![]u8 {
    var output: std.io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try render.renderMarkdown(allocator, &output.writer, input, opts);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
