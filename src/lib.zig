const std = @import("std");
const parse_mod = @import("parse.zig");
const render_mod = @import("render.zig");
const source_loader_mod = @import("source_loader.zig");
const term_ansi = @import("term/ansi.zig");
const term_width = @import("term/width.zig");

pub const RenderOptions = render_mod.RenderOptions;
pub const AmbiguousWidth = term_width.AmbiguousWidth;
pub const ColorMode = term_ansi.ColorMode;

pub fn renderSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    writer: *std.Io.Writer,
    wrap_width: ?usize,
    options: RenderOptions,
) !void {
    var doc = try parse_mod.parse(allocator, .{ .borrowed = source });
    defer doc.deinit();

    var renderer = render_mod.Renderer.init(allocator, options);
    defer renderer.deinit();

    try renderer.render(writer, &doc, wrap_width, allocator);
}

pub fn renderFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
    writer: *std.Io.Writer,
    wrap_width: ?usize,
    options: RenderOptions,
) !void {
    const src = try source_loader_mod.loadFile(allocator, io, cwd, path);
    var doc = try parse_mod.parse(allocator, src);
    defer doc.deinit();

    var renderer = render_mod.Renderer.init(allocator, options);
    defer renderer.deinit();

    try renderer.render(writer, &doc, wrap_width, allocator);
}

test {
    _ = @import("watch/session.zig");
}

test "renderSource writes rendered markdown for heading and list" {
    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try renderSource(
        allocator,
        "# Title\n\n- item\n",
        &buf.writer,
        null,
        .{ .enable_ansi = false },
    );

    try std.testing.expectEqualStrings("Title\n\n• item\n", buf.writer.buffered());
}

test "renderSource honors wrap_width for plain paragraph" {
    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try renderSource(
        allocator,
        "alpha beta gamma delta\n",
        &buf.writer,
        10,
        .{ .enable_ansi = false },
    );

    try std.testing.expect(std.mem.indexOfScalar(u8, buf.writer.buffered(), '\n') != null);
}

test "renderFile reads from cwd and writes rendered output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "doc.md",
        .data = "## Hello\n",
    });

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try renderFile(
        allocator,
        io,
        tmp.dir,
        "doc.md",
        &buf.writer,
        null,
        .{ .enable_ansi = false },
    );

    try std.testing.expectEqualStrings("Hello\n", buf.writer.buffered());
}
