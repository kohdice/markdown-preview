const std = @import("std");
const ast = @import("ast.zig");
const term = @import("term.zig");
const highlight = term.highlight;
const theme = term.theme;
const width = term.width;
const render_block = @import("render/block.zig");
const render_table = @import("render/table.zig");
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
    table_scratch: render_table.TableScratch = .{},
    wrap_writer: width.WrapWriter,
    scratch: std.heap.ArenaAllocator,

    pub fn init(persistent_allocator: std.mem.Allocator, opts: RenderOptions) Renderer {
        return .{
            .persistent_allocator = persistent_allocator,
            .opts = opts,
            .palette = theme.default_palette,
            .syn_palette = theme.default_syntax_palette,
            .highlighter = highlight.Highlighter.init(),
            .wrap_writer = width.WrapWriter.init(undefined, 0, opts.ambiguous_width, persistent_allocator),
            .scratch = std.heap.ArenaAllocator.init(persistent_allocator),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.highlighter.deinit();
        self.table_scratch.deinit(self.persistent_allocator);
        self.wrap_writer.deinit();
        self.scratch.deinit();
    }

    pub fn render(
        self: *Renderer,
        writer: *std.io.Writer,
        doc: *const ast.Document,
        wrap_width: ?usize,
    ) !void {
        _ = self.scratch.reset(.retain_capacity);
        self.table_scratch.reset();
        const ctx: render_context.RenderContext = .{
            .doc = doc,
            .enable_ansi = self.opts.enable_ansi,
            .ambiguous_width = self.opts.ambiguous_width,
            .palette = self.palette,
            .syn_palette = self.syn_palette,
        };
        var session: render_block.RenderSession = .{
            .ctx = &ctx,
            .writer = writer,
            .scratch = self.scratch.allocator(),
            .persistent_allocator = self.persistent_allocator,
            .wrap_width = wrap_width,
            .highlighter = &self.highlighter,
            .table_scratch = &self.table_scratch,
            .wrap_writer = &self.wrap_writer,
        };

        try session.write(doc.blocks);
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
