const std = @import("std");
const project = @import("project");
const parse = project.parse;
const render = project.render;

pub fn renderToOwnedSlice(
    allocator: std.mem.Allocator,
    input: []const u8,
    opts: render.RenderOptions,
) ![]u8 {
    var output: std.io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var doc = try parse.parseBorrowed(allocator, input);
    defer doc.deinit();

    var renderer = render.Renderer.init(allocator, opts);
    defer renderer.deinit();
    try renderer.renderDocument(&output.writer, &doc);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
