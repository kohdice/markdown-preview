const std = @import("std");
const internals = @import("internals");
const markdown_preview = internals.facade;
const source_loader = internals.source_loader;

pub const FacadeRenderOptions = struct {
    enable_ansi: bool = false,
    wrap_width: ?usize = null,
    ambiguous_width: markdown_preview.AmbiguousWidth = .narrow,
};

pub fn renderBorrowedToOwnedSlice(
    allocator: std.mem.Allocator,
    input: []const u8,
    opts: FacadeRenderOptions,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var doc = try markdown_preview.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    var renderer = markdown_preview.Renderer.init(allocator, .{
        .enable_ansi = opts.enable_ansi,
        .ambiguous_width = opts.ambiguous_width,
    });
    defer renderer.deinit();

    try renderer.render(&output.writer, &doc, opts.wrap_width);

    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn renderLoadedFileToOwnedSlice(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
    opts: FacadeRenderOptions,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    const src = try source_loader.loadFile(allocator, io, cwd, path);
    var doc = try markdown_preview.parse(allocator, src);
    defer doc.deinit();

    var renderer = markdown_preview.Renderer.init(allocator, .{
        .enable_ansi = opts.enable_ansi,
        .ambiguous_width = opts.ambiguous_width,
    });
    defer renderer.deinit();

    try renderer.render(&output.writer, &doc, opts.wrap_width);

    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
