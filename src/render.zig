const std = @import("std");
const ast = @import("ast.zig");
const term = @import("term.zig");
const highlight = term.highlight;
const theme = term.theme;
const width = term.width;
const render_block = @import("render/block.zig");
const render_scratch = @import("render/scratch.zig");
const render_context = @import("render/context.zig");

pub const RenderOptions = struct {
    enable_ansi: bool = false,
    ambiguous_width: width.AmbiguousWidth = .narrow,
};

pub const Renderer = struct {
    persistent_allocator: std.mem.Allocator,
    opts: RenderOptions,
    palette: theme.Palette,
    syn_palette: theme.SyntaxPalette,
    highlighter: highlight.Highlighter,
    scratch: render_scratch.RendererScratch,

    pub fn init(persistent_allocator: std.mem.Allocator, opts: RenderOptions) Renderer {
        return .{
            .persistent_allocator = persistent_allocator,
            .opts = opts,
            .palette = theme.default_palette,
            .syn_palette = theme.default_syntax_palette,
            .highlighter = highlight.Highlighter.init(),
            .scratch = render_scratch.RendererScratch.init(persistent_allocator, opts.ambiguous_width),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.highlighter.deinit();
        self.scratch.deinit(self.persistent_allocator);
    }

    pub fn renderDocument(
        self: *Renderer,
        writer: *std.io.Writer,
        doc: *const ast.Document,
        wrap_width: ?usize,
        ephemeral_allocator: std.mem.Allocator,
    ) !void {
        var session: render_block.RenderSession = .{
            .ctx = .{
                .doc = doc,
                .enable_ansi = self.opts.enable_ansi,
                .ambiguous_width = self.opts.ambiguous_width,
                .palette = self.palette,
                .syn_palette = self.syn_palette,
            },
            .writer = writer,
            .ephemeral_allocator = ephemeral_allocator,
            .persistent_allocator = self.persistent_allocator,
            .wrap_width = wrap_width,
            .highlighter = &self.highlighter,
            .scratch = &self.scratch,
        };

        try session.renderDocument();
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
