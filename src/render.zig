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

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    opts: RenderOptions,
    palette: theme.Palette,
    syn_palette: theme.SyntaxPalette,
    highlighter: highlight.Highlighter,

    pub fn init(allocator: std.mem.Allocator, opts: RenderOptions) Renderer {
        return .{
            .allocator = allocator,
            .opts = opts,
            .palette = theme.palette(opts.theme),
            .syn_palette = theme.syntaxPalette(opts.theme),
            .highlighter = highlight.Highlighter.init(),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.highlighter.deinit();
    }

    pub fn renderDocument(self: *Renderer, writer: *std.io.Writer, doc: *const ast.Document) !void {
        var block_renderer: render_block.Renderer = .{
            .writer = writer,
            .allocator = self.allocator,
            .enable_ansi = self.opts.enable_ansi,
            .wrap_width = self.opts.wrap_width,
            .ambiguous_width = self.opts.ambiguous_width,
            .palette = self.palette,
            .syn_palette = self.syn_palette,
            .highlighter = &self.highlighter,
        };

        try block_renderer.write(doc.blocks);

        if (doc.has_trailing_newline) try writer.writeByte('\n');
    }
};

pub fn write(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    doc: *const ast.Document,
    opts: RenderOptions,
) !void {
    var renderer = Renderer.init(allocator, opts);
    defer renderer.deinit();
    try renderer.renderDocument(writer, doc);
}

test {
    _ = @import("render/block.zig");
    _ = @import("render/measure.zig");
    _ = @import("render/prefix_writer.zig");
    _ = @import("render/table.zig");
    _ = @import("render/test_block.zig");
    _ = @import("render/test_inline.zig");
    _ = @import("render/test_code.zig");
    _ = @import("render/test_table.zig");
}
