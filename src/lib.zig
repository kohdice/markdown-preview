const std = @import("std");
const parse_mod = @import("parse.zig");
const render_mod = @import("render.zig");
const term_width = @import("term/width.zig");

pub const RenderOptions = render_mod.RenderOptions;
pub const Renderer = render_mod.Renderer;
pub const Document = parse_mod.Document;
pub const Source = parse_mod.Source;
pub const AmbiguousWidth = term_width.AmbiguousWidth;

pub const parse = parse_mod.parse;

test {
    _ = @import("watch/session.zig");
}

test "parse re-exports parser entry point" {
    var doc = try parse(std.testing.allocator, .{ .borrowed = "# Title\n" });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.has_trailing_newline);
}

test "renderer renders through public Renderer type" {
    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    var doc = try parse(allocator, .{ .borrowed = "# Title\n\n- item\n" });
    defer doc.deinit();

    var renderer = Renderer.init(allocator, .{ .enable_ansi = false });
    defer renderer.deinit();

    try renderer.render(&buf.writer, &doc, null);

    try std.testing.expectEqualStrings("Title\n\n• item\n", buf.writer.buffered());
}
