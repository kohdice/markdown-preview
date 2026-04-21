const std = @import("std");
const internals = @import("internals");
const markdown_preview = internals.facade;

pub const FacadeRenderOptions = struct {
    enable_ansi: bool = false,
    wrap_width: ?usize = null,
    ambiguous_width: markdown_preview.AmbiguousWidth = .narrow,
    color_mode: markdown_preview.ColorMode = .truecolor,
};

pub fn renderSourceToOwnedSlice(
    allocator: std.mem.Allocator,
    input: []const u8,
    opts: FacadeRenderOptions,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try markdown_preview.renderSource(allocator, input, &output.writer, opts.wrap_width, .{
        .enable_ansi = opts.enable_ansi,
        .ambiguous_width = opts.ambiguous_width,
        .color_mode = opts.color_mode,
    });

    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

pub fn renderFileToOwnedSlice(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
    opts: FacadeRenderOptions,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try markdown_preview.renderFile(allocator, io, cwd, path, &output.writer, opts.wrap_width, .{
        .enable_ansi = opts.enable_ansi,
        .ambiguous_width = opts.ambiguous_width,
        .color_mode = opts.color_mode,
    });

    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
