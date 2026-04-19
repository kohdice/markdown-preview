const std = @import("std");
const markdown_preview = @import("markdown_preview");
const parse = markdown_preview.parse;
const Renderer = markdown_preview.Renderer;

pub const TestRenderOptions = struct {
    enable_ansi: bool = false,
    wrap_width: ?usize = null,
    ambiguous_width: markdown_preview.terminal.AmbiguousWidth = .narrow,
};

pub fn renderToOwnedSlice(
    allocator: std.mem.Allocator,
    input: []const u8,
    opts: TestRenderOptions,
) ![]u8 {
    var output: std.io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var doc = try parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    var renderer: Renderer = undefined;
    renderer.init(allocator, .{
        .enable_ansi = opts.enable_ansi,
        .ambiguous_width = opts.ambiguous_width,
    });
    defer renderer.deinit();
    try renderer.render(&output.writer, &doc, opts.wrap_width);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
