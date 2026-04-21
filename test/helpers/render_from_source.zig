const std = @import("std");
const internals = @import("internals");
const parse = internals.parse.parse;
const Renderer = internals.render.Renderer;

pub const TestRenderOptions = struct {
    enable_ansi: bool = false,
    wrap_width: ?usize = null,
    ambiguous_width: internals.term.width.AmbiguousWidth = .narrow,
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

    var renderer = Renderer.init(allocator, .{
        .enable_ansi = opts.enable_ansi,
        .ambiguous_width = opts.ambiguous_width,
    });
    defer renderer.deinit();
    try renderer.render(&output.writer, &doc, opts.wrap_width);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
