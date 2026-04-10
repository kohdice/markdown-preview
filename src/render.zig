const std = @import("std");
const ast = @import("ast.zig");
const term = @import("term.zig");
const highlight = term.highlight;
const theme = term.theme;
const width = term.width;
const render_block = @import("render/block.zig");

pub const RenderOptions = struct {
    enable_ansi: bool = false,
    theme: theme.Theme = .solarized_dark,
    wrap_width: ?usize = null,
    ambiguous_width: width.AmbiguousWidth = .narrow,
};

pub fn write(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    doc: ast.Document,
    opts: RenderOptions,
) !void {
    var highlighter = highlight.Highlighter.init();
    defer highlighter.deinit();

    var renderer: render_block.Renderer = .{
        .writer = writer,
        .allocator = allocator,
        .enable_ansi = opts.enable_ansi,
        .wrap_width = opts.wrap_width,
        .ambiguous_width = opts.ambiguous_width,
        .palette = theme.palette(opts.theme),
        .syn_palette = theme.syntaxPalette(opts.theme),
        .highlighter = &highlighter,
    };

    try renderer.write(doc.blocks);

    if (doc.has_trailing_newline) try writer.writeByte('\n');
}

test {
    _ = @import("render/block.zig");
    _ = @import("render/test_block.zig");
    _ = @import("render/test_inline.zig");
    _ = @import("render/test_code.zig");
    _ = @import("render/test_table.zig");
}
