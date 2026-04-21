const std = @import("std");
const ansi = @import("../term/ansi.zig");
const theme = @import("../term/theme.zig");
const width = @import("../term/width.zig");
const ast = @import("../ast.zig");
const parse_mod = @import("../parse.zig");
const render_inline = @import("inline.zig");
const prefix_writer = @import("prefix_writer.zig");
const render_table = @import("table.zig");
const highlight = @import("../term/highlight.zig");
const render_context = @import("context.zig");
const mermaid = @import("../mermaid.zig");

const RenderContext = render_context.RenderContext;

const thematic_break_width = 32;
const thematic_break_display = "─" ** thematic_break_width;
const blockquote_marker = "│ ";
const checkbox_checked = "☑ ";
const checkbox_unchecked = "☐ ";

const list_bullet = struct {
    const level0 = "• ";
    const level1 = "◦ ";
    const level2 = "▪ ";
};

fn bulletForDepth(depth: usize) []const u8 {
    return switch (depth % 3) {
        0 => list_bullet.level0,
        1 => list_bullet.level1,
        2 => list_bullet.level2,
        else => unreachable,
    };
}

fn canHighlight(mode: ansi.ColorMode) bool {
    return switch (mode) {
        .ansi256, .truecolor => true,
        .none, .ansi16 => false,
    };
}

fn headingStyle(level: u8, p: theme.Palette) ansi.TextStyle {
    const color = p.heading_colors[level - 1];
    return switch (level) {
        1, 2 => .{ .fg = color, .bold = true, .underline = true },
        3, 4 => .{ .fg = color, .bold = true },
        5 => .{ .fg = color },
        6 => .{ .fg = color, .dim = true },
        else => unreachable,
    };
}

pub const RenderSession = struct {
    ctx: *const RenderContext,
    writer: *std.Io.Writer,
    prefix_stack: *prefix_writer.PrefixStack,
    scratch: std.mem.Allocator,
    persistent_allocator: std.mem.Allocator,
    table_scratch: *render_table.TableScratch,
    wrap_writer: *width.WrapWriter,
    wrap_width: ?usize,
    highlighter: *highlight.Highlighter,
    mermaid_cache: *std.AutoHashMapUnmanaged(u64, mermaid.Diagram),
    /// Render-only side channel: paragraph pointer → raw lines for
    /// trigger-free paragraphs, in block-walk emission order. Lives on the
    /// session because it is not part of the public parse/render contract
    /// (`ParsedDocument` / `RenderContext` do not expose it).
    trivial_runs: []const parse_mod.TrivialRun = &.{},
    trivial_cursor: usize = 0,

    /// Peek the next trivial run and consume it iff it belongs to `p`. Used
    /// by every paragraph-visit site to decide between the raw-lines fast
    /// path and the regular inline chain.
    fn takeTrivialParagraph(self: *RenderSession, p: *const ast.Paragraph) ?parse_mod.TrivialRun.Lines {
        if (self.trivial_cursor >= self.trivial_runs.len) return null;
        const run = self.trivial_runs[self.trivial_cursor];
        if (run.paragraph != p) return null;
        self.trivial_cursor += 1;
        return run.lines;
    }

    fn pushSegment(self: *RenderSession, segment: prefix_writer.PrefixStack.Segment) !void {
        // PrefixWriter applies the active stack at line-start; unflushed bytes
        // must drain with the OLD stack before the new segment takes effect.
        // See prefix_writer.zig "push mid-line does not retroactively prefix
        // first line".
        if (self.writer.end > 0) try self.writer.flush();
        try self.prefix_stack.push(segment);
    }

    fn popPrefix(self: *RenderSession) !void {
        errdefer self.prefix_stack.pop();
        if (self.writer.end > 0) try self.writer.flush();
        self.prefix_stack.pop();
    }

    fn pushStyledPrefix(
        self: *RenderSession,
        indent: usize,
        marker: []const u8,
        style: ansi.TextStyle,
    ) !void {
        const rendered_marker: []const u8 = blk: {
            if (marker.len == 0) break :blk marker;
            if (!self.ctx.enable_ansi or style.isPlain()) break :blk marker;
            var tmp: std.Io.Writer.Allocating = .init(self.scratch);
            try ansi.writeStyled(&tmp.writer, self.ctx.enable_ansi, self.ctx.color_mode, style, marker);
            break :blk tmp.written();
        };
        try self.pushSegment(.{ .indent = indent, .marker = rendered_marker });
    }

    fn pushIndent(self: *RenderSession, indent: usize) !void {
        try self.pushSegment(.{ .indent = indent });
    }

    pub fn write(self: *RenderSession, blocks: []const ast.BlockNode) !void {
        for (blocks, 0..) |*block_ptr, i| {
            if (i > 0) try self.writer.writeByte('\n');
            try self.writeBlock(block_ptr, 0);
        }
    }

    fn writeBlock(self: *RenderSession, block_ptr: *const ast.BlockNode, depth: usize) anyerror!void {
        switch (block_ptr.*) {
            .paragraph => try self.writeParagraph(&block_ptr.paragraph),
            .heading => |heading| try self.writeHeading(heading),
            .blockquote => |blockquote| try self.writeBlockQuote(blockquote, depth),
            .list => |list| try self.writeList(list, depth),
            .code_block => |code_block| try self.writeCodeBlock(code_block),
            .code_fence => |code_fence| try self.writeCodeFence(code_fence),
            .thematic_break => try self.writeThematicBreak(),
            .table => |table| try render_table.writeTable(self.ctx, self.writer, self.persistent_allocator, self.table_scratch, table, .top_level),
            .blank_line => {},
        }
    }

    fn writeParagraph(self: *RenderSession, paragraph: *const ast.Paragraph) !void {
        const style: ansi.TextStyle = .{ .fg = self.ctx.palette.body };
        try self.writeParagraphContent(paragraph, style, 0);
    }

    fn writeParagraphContent(
        self: *RenderSession,
        paragraph: *const ast.Paragraph,
        base_style: ansi.TextStyle,
        continuation_indent: usize,
    ) !void {
        const pushed = continuation_indent > 0;
        if (pushed) try self.pushIndent(continuation_indent);
        defer if (pushed) self.popPrefix() catch {};

        const trivial_lines = self.takeTrivialParagraph(paragraph);

        if (self.wrap_width) |wrap_w| {
            const available = if (wrap_w > continuation_indent)
                wrap_w - continuation_indent
            else
                1;
            self.wrap_writer.reset(self.writer, available);
            try self.writeBody(&self.wrap_writer.writer, paragraph, trivial_lines, base_style);
            try self.wrap_writer.finish();
        } else {
            try self.writeBody(self.writer, paragraph, trivial_lines, base_style);
        }
    }

    fn writeBody(
        self: *RenderSession,
        writer: *std.Io.Writer,
        paragraph: *const ast.Paragraph,
        trivial_lines: ?parse_mod.TrivialRun.Lines,
        base_style: ansi.TextStyle,
    ) !void {
        if (trivial_lines) |lines| {
            switch (lines) {
                .single => |line| try render_inline.writePlainLines(self.ctx, writer, &.{line}, base_style),
                .multi => |multi| try render_inline.writePlainLines(self.ctx, writer, multi, base_style),
            }
        } else {
            try render_inline.writeInlineChain(self.ctx, writer, paragraph.children, base_style);
        }
    }

    fn writeHeading(self: *RenderSession, heading: ast.Heading) !void {
        try render_inline.writeInlineChain(
            self.ctx,
            self.writer,
            heading.children,
            headingStyle(heading.level, self.ctx.palette),
        );
    }

    fn writeThematicBreak(self: *RenderSession) !void {
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, .{
            .fg = self.ctx.palette.muted,
        }, thematic_break_display);
    }

    fn writeBlockQuote(self: *RenderSession, blockquote: ast.BlockQuote, depth: usize) anyerror!void {
        const gutter_style: ansi.TextStyle = .{ .fg = self.ctx.palette.muted, .dim = true };
        const gutter_width = blockquote.indent + width.displayWidth(blockquote_marker, self.ctx.ambiguous_width);

        try self.pushStyledPrefix(blockquote.indent, blockquote_marker, gutter_style);
        errdefer self.popPrefix() catch {};

        const saved_wrap = self.wrap_width;
        defer self.wrap_width = saved_wrap;
        if (saved_wrap) |ww| {
            self.wrap_width = if (ww > gutter_width) ww - gutter_width else null;
        }

        try self.writeBlocksInBlockQuote(blockquote.blocks, depth);
        try self.popPrefix();
    }

    fn writeBlocksInBlockQuote(self: *RenderSession, blocks: []const ast.BlockNode, depth: usize) anyerror!void {
        for (blocks, 0..) |*block_ptr, i| {
            if (i > 0) try self.writer.writeByte('\n');
            switch (block_ptr.*) {
                .paragraph => try self.writeBlockQuoteParagraph(&block_ptr.paragraph),
                .blockquote => |blockquote| try self.writeBlockQuote(blockquote, depth),
                .table => |table| try render_table.writeTable(self.ctx, self.writer, self.persistent_allocator, self.table_scratch, table, .blockquote),
                else => try self.writeBlock(block_ptr, depth),
            }
        }
    }

    fn writeBlockQuoteParagraph(self: *RenderSession, paragraph: *const ast.Paragraph) !void {
        const style: ansi.TextStyle = .{ .fg = self.ctx.palette.muted };
        try self.writeParagraphContent(paragraph, style, 0);
    }

    fn writeList(self: *RenderSession, list: ast.List, depth: usize) anyerror!void {
        for (list.items, 0..) |item, i| {
            if (i > 0) {
                try self.writer.writeByte('\n');
                if (list.loose) try self.writer.writeByte('\n');
            }
            try self.writeListItem(item, depth);
        }
    }

    fn writeListItem(self: *RenderSession, item: ast.ListItem, depth: usize) anyerror!void {
        try self.writer.splatByteAll(' ', item.indent);

        const marker_style: ansi.TextStyle = .{
            .fg = self.ctx.palette.list_marker,
            .bold = true,
        };

        var content_col: usize = item.indent;
        if (item.number) |number| {
            var sgr_state: ansi.StyledState = .{};
            try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, &sgr_state, marker_style, number);
            const marker_buf: [2]u8 = .{ item.marker, ' ' };
            try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, &sgr_state, marker_style, &marker_buf);
            try ansi.flushStyle(self.writer, &sgr_state);
            content_col += width.displayWidth(number, self.ctx.ambiguous_width) + width.displayWidth(&marker_buf, self.ctx.ambiguous_width);
        } else {
            const marker_text = bulletForDepth(depth);
            try ansi.writeStyled(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, marker_style, marker_text);
            content_col += width.displayWidth(marker_text, self.ctx.ambiguous_width);
        }
        content_col += checkboxWidth(item.checked, self.ctx.ambiguous_width);

        try self.writeCheckbox(item.checked);

        for (item.blocks, 0..) |*child_ptr, child_index| {
            if (child_index > 0) try self.writer.writeByte('\n');
            switch (child_ptr.*) {
                .paragraph => {
                    if (child_index > 0) try self.writer.splatByteAll(' ', content_col);
                    try self.writeListItemParagraph(&child_ptr.paragraph, content_col);
                },
                .list => |nested| try self.writeList(nested, depth + 1),
                .blockquote => |blockquote| try self.writeBlockQuote(blockquote, depth + 1),
                .blank_line => try self.writeBlock(child_ptr, depth),
                else => {
                    if (child_index > 0) {
                        try self.writeListChildIndented(child_ptr, content_col, depth);
                    } else {
                        try self.writeBlock(child_ptr, depth);
                    }
                },
            }
        }
    }

    fn writeListChildIndented(
        self: *RenderSession,
        child_block: *const ast.BlockNode,
        indent: usize,
        depth: usize,
    ) anyerror!void {
        if (indent == 0) return self.writeBlock(child_block, depth);

        try self.pushIndent(indent);
        errdefer self.popPrefix() catch {};

        const saved_wrap = self.wrap_width;
        defer self.wrap_width = saved_wrap;
        if (saved_wrap) |ww| {
            self.wrap_width = if (ww > indent) ww - indent else null;
        }

        try self.writeBlock(child_block, depth);
        try self.popPrefix();
    }

    fn writeListItemParagraph(
        self: *RenderSession,
        paragraph: *const ast.Paragraph,
        content_col: usize,
    ) !void {
        const style: ansi.TextStyle = .{ .fg = self.ctx.palette.body };

        if (content_col == 0 or self.wrap_width != null) {
            try self.writeParagraphContent(paragraph, style, content_col);
            return;
        }

        try self.pushIndent(content_col);
        errdefer self.popPrefix() catch {};

        try self.writeBody(self.writer, paragraph, self.takeTrivialParagraph(paragraph), style);

        try self.popPrefix();
    }

    fn writeCodeFence(self: *RenderSession, code_fence: ast.CodeFence) !void {
        const fence_style: ansi.TextStyle = .{ .fg = self.ctx.palette.code_fence, .dim = true };
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, fence_style, code_fence.opener);

        if (std.ascii.eqlIgnoreCase(code_fence.language, "mermaid")) {
            if (code_fence.content.len > 0) {
                try self.writer.writeByte('\n');
                self.writeMermaidBody(code_fence.content) catch |err| switch (err) {
                    error.InvalidMermaid, error.UnsupportedDiagram, error.UnsupportedFeature => try self.writeMermaidFallback(code_fence.content, err),
                    else => return err,
                };
            }
            if (code_fence.closer) |closer| {
                try self.writer.writeByte('\n');
                try ansi.writeStyled(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, fence_style, closer);
            }
            return;
        }

        const language = highlight.Language.fromString(code_fence.language);
        if (code_fence.content.len > 0) {
            try self.writer.writeByte('\n');
            try self.writeFenceBody(code_fence.content, language);
        }

        if (code_fence.closer) |closer| {
            try self.writer.writeByte('\n');
            try ansi.writeStyled(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, fence_style, closer);
        }
    }

    fn writeMermaidBody(self: *RenderSession, content: []const u8) mermaid.PaintError!void {
        const opts: mermaid.PaintOptions = .{
            .enable_ansi = self.ctx.enable_ansi,
            .wrap_width = self.wrap_width,
            .ambiguous_width = self.ctx.ambiguous_width,
            .color_mode = self.ctx.color_mode,
        };
        const key = std.hash.XxHash3.hash(0, content);
        const diagram_ptr = if (self.mermaid_cache.getPtr(key)) |cached|
            cached
        else blk: {
            var compiled = try mermaid.compile(self.persistent_allocator, content);
            errdefer compiled.deinit();
            try self.mermaid_cache.put(self.persistent_allocator, key, compiled);
            break :blk self.mermaid_cache.getPtr(key).?;
        };
        try mermaid.paint(self.writer, self.scratch, diagram_ptr, opts);
    }

    fn writeMermaidFallback(self: *RenderSession, content: []const u8, err: mermaid.PaintError) !void {
        const label = switch (err) {
            error.UnsupportedDiagram => "[mermaid: diagram type not yet supported by mp]\n",
            error.UnsupportedFeature => "[mermaid: feature not yet supported by mp]\n",
            error.InvalidMermaid => "[mermaid: parse error]\n",
            else => "[mermaid: render error]\n",
        };
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, .{
            .fg = self.ctx.palette.inline_code,
        }, label);
        try self.writeFenceBody(content, null);
    }

    fn writeFenceBody(self: *RenderSession, content: []const u8, language: ?highlight.Language) !void {
        if (language) |lang| {
            if (self.ctx.enable_ansi and canHighlight(self.ctx.color_mode)) {
                self.highlighter.writeHighlightedBlock(
                    self.scratch,
                    self.writer,
                    content,
                    lang,
                    self.ctx.syn_palette,
                    self.ctx.color_mode,
                ) catch |err| switch (err) {
                    error.QueryUnavailable => {
                        try ansi.writeStyled(self.writer, true, self.ctx.color_mode, .{ .fg = self.ctx.palette.inline_code }, content);
                    },
                    else => return err,
                };
                return;
            }

            if (!self.ctx.enable_ansi) {
                try ansi.writeStyled(self.writer, false, self.ctx.color_mode, .{}, content);
                return;
            }
        }

        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, .{
            .fg = self.ctx.palette.inline_code,
        }, content);
    }

    fn writeCodeBlock(self: *RenderSession, code_block: ast.CodeBlock) !void {
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, .{
            .fg = self.ctx.palette.inline_code,
        }, code_block.content);
    }

    fn writeCheckbox(self: *RenderSession, checked: ?bool) !void {
        if (checked) |is_checked| {
            if (is_checked) {
                try ansi.writeStyled(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, .{
                    .fg = self.ctx.palette.list_marker,
                }, checkbox_checked);
            } else {
                try ansi.writeStyled(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, .{
                    .fg = self.ctx.palette.muted,
                    .dim = true,
                }, checkbox_unchecked);
            }
        }
    }
};

fn checkboxWidth(checked: ?bool, ambiguous: width.AmbiguousWidth) usize {
    if (checked == null) return 0;
    const glyph = if (checked.?) checkbox_checked else checkbox_unchecked;
    return width.displayWidth(glyph, ambiguous);
}

test "RenderSession.write renders heading content without document trailing newline" {
    const allocator = std.testing.allocator;
    var highlighter = highlight.Highlighter.init();
    defer highlighter.deinit();

    const inline_nodes = [_]ast.InlineNode{.{ .text = "Hello" }};
    const inline_next = [_]ast.InlineRef{ast.no_inline};
    var blocks = [_]ast.BlockNode{
        .{ .heading = .{ .level = 1, .children = 0 } },
    };
    const doc: ast.Document = .{
        .inline_nodes = &inline_nodes,
        .inline_next = &inline_next,
        .blocks = &blocks,
        .link_defs = .{},
        .has_trailing_newline = false,
    };

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    var table_scratch: render_table.TableScratch = .{};
    defer table_scratch.deinit(allocator);
    var wrap_line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer wrap_line_buf.deinit(allocator);
    var wrap: width.WrapWriter = undefined;
    wrap.init(undefined, 0, .narrow, allocator, &wrap_line_buf);
    defer wrap.deinit();

    var prefix_stack: prefix_writer.PrefixStack = .init(allocator);
    defer prefix_stack.deinit();
    var prefix_w: prefix_writer.PrefixWriter = undefined;
    prefix_w.init(&buf.writer, &prefix_stack);

    const ctx: RenderContext = .{
        .doc = &doc,
        .enable_ansi = false,
        .ambiguous_width = .narrow,
        .palette = theme.default_palette,
        .syn_palette = theme.default_syntax_palette,
    };
    var cache: std.AutoHashMapUnmanaged(u64, mermaid.Diagram) = .empty;
    defer cache.deinit(allocator);

    var session: RenderSession = .{
        .ctx = &ctx,
        .writer = &prefix_w.writer,
        .prefix_stack = &prefix_stack,
        .scratch = allocator,
        .persistent_allocator = allocator,
        .table_scratch = &table_scratch,
        .wrap_writer = &wrap,
        .wrap_width = null,
        .highlighter = &highlighter,
        .mermaid_cache = &cache,
    };

    try session.write(doc.blocks);
    try prefix_w.writer.flush();

    try std.testing.expectEqualStrings("Hello", buf.writer.buffered());
}
