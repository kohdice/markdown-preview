const std = @import("std");
const markdown_preview = @import("markdown_preview");
const parse = markdown_preview.parse;
const render = markdown_preview.render;

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
    try renderer.renderDocument(&output.writer, &doc, opts.wrap_width, allocator);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
