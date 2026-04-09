const std = @import("std");
const block_ast = @import("block_ast.zig");
const highlight = @import("highlight.zig");
const theme = @import("theme.zig");
const width = @import("width.zig");
const render_block = @import("render_block.zig");

pub const RenderOptions = struct {
    enable_ansi: bool = false,
    theme: theme.Theme = .solarized_dark,
    wrap_width: ?usize = null,
    ambiguous_width: width.AmbiguousWidth = .narrow,
};

pub fn write(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    doc: block_ast.Document,
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
        .link_defs = &doc.link_defs,
    };

    try renderer.write(doc.blocks);

    if (doc.has_trailing_newline) try writer.writeByte('\n');
}

test {
    _ = @import("render_block.zig");
    _ = @import("render_test_block.zig");
    _ = @import("render_test_inline.zig");
    _ = @import("render_test_code.zig");
    _ = @import("render_test_table.zig");
}
