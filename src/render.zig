const std = @import("std");
const ast = @import("ast.zig");
const term = @import("term.zig");
const highlight = term.highlight;
const theme = term.theme;
const width = term.width;
const render_block = @import("render/block.zig");
const render_table = @import("render/table.zig");

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
    scratch: render_table.RendererScratch,

    pub fn init(allocator: std.mem.Allocator, opts: RenderOptions) Renderer {
        return .{
            .allocator = allocator,
            .opts = opts,
            .palette = theme.palette(opts.theme),
            .syn_palette = theme.syntaxPalette(opts.theme),
            .highlighter = highlight.Highlighter.init(),
            .scratch = .{},
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.highlighter.deinit();
        self.scratch.deinit(self.allocator);
    }

    pub fn renderDocument(self: *Renderer, writer: *std.io.Writer, doc: *const ast.Document) !void {
        self.scratch.reset();

        var block_renderer: render_block.Renderer = .{
            .doc = doc,
            .writer = writer,
            .allocator = self.allocator,
            .enable_ansi = self.opts.enable_ansi,
            .wrap_width = self.opts.wrap_width,
            .ambiguous_width = self.opts.ambiguous_width,
            .palette = self.palette,
            .syn_palette = self.syn_palette,
            .highlighter = &self.highlighter,
            .scratch = &self.scratch,
        };

        try block_renderer.write(doc.blocks);

        if (doc.has_trailing_newline) try writer.writeByte('\n');
    }
};

test {
    _ = @import("render/block.zig");
    _ = @import("render/measure.zig");
    _ = @import("render/prefix_writer.zig");
    _ = @import("render/table.zig");
    _ = @import("render/ast_helpers_test.zig");
    _ = @import("render/document_test.zig");
    _ = @import("render/inline_test.zig");
    _ = @import("render/block_test.zig");
    _ = @import("render/table_test.zig");
    _ = @import("render/code_test.zig");
}
