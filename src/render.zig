const std = @import("std");
const ast = @import("ast.zig");
const term = @import("term.zig");
const highlight = term.highlight;
const theme = term.theme;
const width = term.width;
const render_block = @import("render/block.zig");
const render_table = @import("render/table.zig");
const render_context = @import("render/context.zig");
const prefix_writer_mod = @import("render/prefix_writer.zig");

pub const retained_arena_limit: usize = 4 * 1024 * 1024;

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
    wrap_line_buf: std.ArrayList(u8) = .empty,
    scratch: std.heap.ArenaAllocator,
    mermaid_cache: render_block.MermaidCache = .empty,
    mermaid_compile_count: usize = 0,

    pub fn init(persistent_allocator: std.mem.Allocator, opts: RenderOptions) Renderer {
        return .{
            .persistent_allocator = persistent_allocator,
            .opts = opts,
            .palette = theme.default_palette,
            .syn_palette = theme.default_syntax_palette,
            .highlighter = highlight.Highlighter.init(),
            .table_scratch = .{},
            .wrap_line_buf = .empty,
            .scratch = std.heap.ArenaAllocator.init(persistent_allocator),
        };
    }

    pub fn deinit(self: *Renderer) void {
        var mermaid_it = self.mermaid_cache.iterator();
        while (mermaid_it.next()) |entry| {
            entry.value_ptr.diagram.deinit();
            if (!entry.value_ptr.key_owned_by_diagram) self.persistent_allocator.free(entry.key_ptr.*);
        }
        self.mermaid_cache.deinit(self.persistent_allocator);
        self.highlighter.deinit();
        self.table_scratch.deinit(self.persistent_allocator);
        self.wrap_line_buf.deinit(self.persistent_allocator);
        self.scratch.deinit();
    }

    pub fn render(
        self: *Renderer,
        writer: *std.Io.Writer,
        doc: *const ast.Document,
        wrap_width: ?usize,
    ) !void {
        _ = self.scratch.reset(.{ .retain_with_limit = retained_arena_limit });
        self.table_scratch.reset(self.persistent_allocator);
        self.markMermaidCacheUnused();
        errdefer self.pruneUnusedMermaidCache(self.scratch.allocator()) catch {};

        var prefix_stack: prefix_writer_mod.PrefixStack = .init(self.scratch.allocator());
        var prefix_w: prefix_writer_mod.PrefixWriter = undefined;
        prefix_w.init(writer, &prefix_stack);

        var wrap_writer: width.WrapWriter = undefined;
        wrap_writer.init(writer, 0, self.opts.ambiguous_width, self.persistent_allocator, &self.wrap_line_buf);

        const ctx: render_context.RenderContext = .{
            .doc = doc,
            .enable_ansi = self.opts.enable_ansi,
            .ambiguous_width = self.opts.ambiguous_width,
            .palette = self.palette,
            .syn_palette = self.syn_palette,
        };
        var session: render_block.RenderSession = .{
            .ctx = &ctx,
            .writer = &prefix_w.writer,
            .prefix_stack = &prefix_stack,
            .scratch = self.scratch.allocator(),
            .persistent_allocator = self.persistent_allocator,
            .wrap_width = wrap_width,
            .highlighter = &self.highlighter,
            .table_scratch = &self.table_scratch,
            .wrap_writer = &wrap_writer,
            .mermaid_cache = &self.mermaid_cache,
            .mermaid_compile_count = &self.mermaid_compile_count,
        };

        try session.write(doc.blocks);
        if (doc.has_trailing_newline) try prefix_w.writer.writeByte('\n');
        try prefix_w.writer.flush();
        try self.pruneUnusedMermaidCache(self.scratch.allocator());
    }

    fn markMermaidCacheUnused(self: *Renderer) void {
        var it = self.mermaid_cache.valueIterator();
        while (it.next()) |entry| entry.used_in_render = false;
    }

    fn pruneUnusedMermaidCache(self: *Renderer, allocator: std.mem.Allocator) !void {
        var stale_keys: std.ArrayList([]const u8) = .empty;
        defer stale_keys.deinit(allocator);

        var it = self.mermaid_cache.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.used_in_render) {
                try stale_keys.append(allocator, entry.key_ptr.*);
            }
        }

        for (stale_keys.items) |key| {
            const removed = self.mermaid_cache.fetchRemove(key) orelse continue;
            var diagram = removed.value.diagram;
            diagram.deinit();
            if (!removed.value.key_owned_by_diagram) self.persistent_allocator.free(removed.key);
        }
    }
};

test {
    _ = @import("render/block.zig");
    _ = @import("render/inline.zig");
    _ = @import("render/prefix_writer.zig");
    _ = @import("render/table.zig");
    _ = @import("render/cell_segment.zig");
    _ = @import("render/ast_helpers_test.zig");
    _ = @import("render/document_test.zig");
    _ = @import("render/inline_test.zig");
    _ = @import("render/block_test.zig");
    _ = @import("render/table_test.zig");
    _ = @import("render/code_test.zig");
    _ = @import("render/mermaid_cache_test.zig");
    _ = @import("render/highlight_color_bypass_parity_test.zig");
}
