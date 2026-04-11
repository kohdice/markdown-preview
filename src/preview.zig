const std = @import("std");
const parse = @import("parse.zig");
const render = @import("render.zig");

pub fn renderSource(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    source: []const u8,
    opts: render.RenderOptions,
) !void {
    var doc = try parse.parse(allocator, source);
    defer doc.deinit();

    var renderer = render.Renderer.init(allocator, opts);
    defer renderer.deinit();
    try renderer.renderDocument(writer, &doc);
}
