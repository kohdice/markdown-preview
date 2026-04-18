const std = @import("std");
const ansi = @import("../term/ansi.zig");
const theme = @import("../term/theme.zig");
const width = @import("../term/width.zig");
const ast = @import("../ast.zig");
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
    writer: *std.io.Writer,
    ephemeral_allocator: std.mem.Allocator,
    persistent_allocator: std.mem.Allocator,
    table_scratch: *render_table.TableScratch,
    wrap_writer: *width.WrapWriter,
    wrap_width: ?usize,
    highlighter: *highlight.Highlighter,

    pub fn renderDocument(self: *RenderSession) !void {
        self.table_scratch.reset();
        try self.write(self.ctx.doc.blocks);
        if (self.ctx.doc.has_trailing_newline) try self.writer.writeByte('\n');
    }

    pub fn write(self: *RenderSession, blocks: []const ast.BlockNode) !void {
        for (blocks, 0..) |block, i| {
            if (i > 0) try self.writer.writeByte('\n');
            try self.writeBlock(block, 0);
        }
    }

    fn writeBlock(self: *RenderSession, block: ast.BlockNode, depth: usize) anyerror!void {
        switch (block) {
            .paragraph => |paragraph| try self.writeParagraph(paragraph),
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

    fn writeParagraph(self: *RenderSession, paragraph: ast.Paragraph) !void {
        try self.writeInlinesMaybeWrap(paragraph.children, .{ .fg = self.ctx.palette.body }, 0);
    }

    fn writeInlinesMaybeWrap(
        self: *RenderSession,
        first: ast.InlineRef,
        base_style: ansi.TextStyle,
        continuation_indent: usize,
    ) !void {
        var prefix: ?prefix_writer.PrefixWriter = null;
        var target: *std.io.Writer = self.writer;
        if (continuation_indent > 0) {
            prefix = prefix_writer.PrefixWriter.init(self.writer, .{
                .indent = continuation_indent,
                .prefix_first_line = false,
            });
            target = &prefix.?.writer;
        }

        if (self.wrap_width) |wrap_w| {
            const available = if (wrap_w > continuation_indent)
                wrap_w - continuation_indent
            else
                1;
            self.wrap_writer.reset(target, available);
            try render_inline.writeInlineChain(self.ctx, &self.wrap_writer.writer, first, base_style);
            try self.wrap_writer.finish();
        } else {
            try render_inline.writeInlineChain(self.ctx, target, first, base_style);
        }

        if (prefix) |*p| try p.finish();
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
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, .{
            .fg = self.ctx.palette.muted,
        }, thematic_break_display);
    }

    fn writeBlockQuote(self: *RenderSession, blockquote: ast.BlockQuote, depth: usize) anyerror!void {
        const gutter_style: ansi.TextStyle = .{ .fg = self.ctx.palette.muted, .dim = true };
        const gutter_width = blockquote.indent + width.displayWidth(blockquote_marker, self.ctx.ambiguous_width);

        var prefix = prefix_writer.PrefixWriter.init(self.writer, .{
            .indent = blockquote.indent,
            .styled_prefix = blockquote_marker,
            .style = gutter_style,
            .enable_ansi = self.ctx.enable_ansi,
        });

        const saved_writer = self.writer;
        const saved_wrap = self.wrap_width;
        defer {
            self.writer = saved_writer;
            self.wrap_width = saved_wrap;
        }

        self.writer = &prefix.writer;
        if (saved_wrap) |ww| {
            self.wrap_width = if (ww > gutter_width) ww - gutter_width else null;
        }

        try self.writeBlocksInBlockQuote(blockquote.blocks, depth);
        try prefix.finish();
    }

    fn writeBlocksInBlockQuote(self: *RenderSession, blocks: []const ast.BlockNode, depth: usize) anyerror!void {
        for (blocks, 0..) |block, i| {
            if (i > 0) try self.writer.writeByte('\n');
            switch (block) {
                .paragraph => |paragraph| try self.writeBlockQuoteParagraph(paragraph),
                .blockquote => |blockquote| try self.writeBlockQuote(blockquote, depth),
                .table => |table| try render_table.writeTable(self.ctx, self.writer, self.persistent_allocator, self.table_scratch, table, .blockquote),
                else => try self.writeBlock(block, depth),
            }
        }
    }

    fn writeBlockQuoteParagraph(self: *RenderSession, paragraph: ast.Paragraph) !void {
        try self.writeInlinesMaybeWrap(paragraph.children, .{ .fg = self.ctx.palette.muted }, 0);
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
            try ansi.writeStyled(self.writer, self.ctx.enable_ansi, marker_style, number);
            const marker_buf: [2]u8 = .{ item.marker, ' ' };
            try ansi.writeStyled(self.writer, self.ctx.enable_ansi, marker_style, &marker_buf);
            content_col += width.displayWidth(number, self.ctx.ambiguous_width) + width.displayWidth(&marker_buf, self.ctx.ambiguous_width);
        } else {
            const marker_text = bulletForDepth(depth);
            try ansi.writeStyled(self.writer, self.ctx.enable_ansi, marker_style, marker_text);
            content_col += width.displayWidth(marker_text, self.ctx.ambiguous_width);
        }
        content_col += checkboxWidth(item.checked, self.ctx.ambiguous_width);

        try self.writeCheckbox(item.checked);

        for (item.blocks, 0..) |child, child_index| {
            if (child_index > 0) try self.writer.writeByte('\n');
            switch (child) {
                .paragraph => |paragraph| {
                    if (child_index > 0) try self.writer.splatByteAll(' ', content_col);
                    try self.writeListItemParagraph(paragraph, content_col);
                },
                .list => |nested| try self.writeList(nested, depth + 1),
                .blockquote => |blockquote| try self.writeBlockQuote(blockquote, depth + 1),
                .blank_line => try self.writeBlock(child, depth),
                else => {
                    if (child_index > 0) {
                        try self.writeListChildIndented(child, content_col, depth);
                    } else {
                        try self.writeBlock(child, depth);
                    }
                },
            }
        }
    }

    fn writeListChildIndented(
        self: *RenderSession,
        child_block: ast.BlockNode,
        indent: usize,
        depth: usize,
    ) anyerror!void {
        if (indent == 0) return self.writeBlock(child_block, depth);

        var prefix = prefix_writer.PrefixWriter.init(self.writer, .{ .indent = indent });

        const saved_writer = self.writer;
        const saved_wrap = self.wrap_width;
        defer {
            self.writer = saved_writer;
            self.wrap_width = saved_wrap;
        }

        self.writer = &prefix.writer;
        if (saved_wrap) |ww| {
            self.wrap_width = if (ww > indent) ww - indent else null;
        }

        try self.writeBlock(child_block, depth);
        try prefix.finish();
    }

    fn writeListItemParagraph(
        self: *RenderSession,
        paragraph: ast.Paragraph,
        content_col: usize,
    ) !void {
        if (content_col == 0 or self.wrap_width != null) {
            try self.writeInlinesMaybeWrap(paragraph.children, .{ .fg = self.ctx.palette.body }, content_col);
            return;
        }

        var prefix = prefix_writer.PrefixWriter.init(self.writer, .{
            .indent = content_col,
            .prefix_first_line = false,
        });
        try render_inline.writeInlineChain(
            self.ctx,
            &prefix.writer,
            paragraph.children,
            .{ .fg = self.ctx.palette.body },
        );
        try prefix.finish();
    }

    fn writeCodeFence(self: *RenderSession, code_fence: ast.CodeFence) !void {
        const fence_style: ansi.TextStyle = .{ .fg = self.ctx.palette.code_fence, .dim = true };
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, fence_style, code_fence.opener);

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
                try ansi.writeStyled(self.writer, self.ctx.enable_ansi, fence_style, closer);
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
            try ansi.writeStyled(self.writer, self.ctx.enable_ansi, fence_style, closer);
        }
    }

    fn writeMermaidBody(self: *RenderSession, content: []const u8) mermaid.RenderError!void {
        const opts: mermaid.Options = .{
            .enable_ansi = self.ctx.enable_ansi,
            .wrap_width = self.wrap_width,
            .ambiguous_width = self.ctx.ambiguous_width,
        };
        try mermaid.writeMermaid(self.writer, self.ephemeral_allocator, content, opts);
    }

    fn writeMermaidFallback(self: *RenderSession, content: []const u8, err: mermaid.RenderError) !void {
        const label = switch (err) {
            error.UnsupportedDiagram => "[mermaid: diagram type not yet supported by mp]\n",
            error.UnsupportedFeature => "[mermaid: feature not yet supported by mp]\n",
            error.InvalidMermaid => "[mermaid: parse error]\n",
            else => "[mermaid: render error]\n",
        };
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, .{
            .fg = self.ctx.palette.inline_code,
        }, label);
        try self.writeFenceBody(content, null);
    }

    fn writeFenceBody(self: *RenderSession, content: []const u8, language: ?highlight.Language) !void {
        if (language) |lang| {
            if (self.ctx.enable_ansi) {
                self.highlighter.writeHighlightedBlock(
                    self.ephemeral_allocator,
                    self.writer,
                    content,
                    lang,
                    self.ctx.syn_palette,
                ) catch |err| switch (err) {
                    error.QueryUnavailable => {
                        try ansi.writeStyled(self.writer, true, .{ .fg = self.ctx.palette.inline_code }, content);
                    },
                    else => return err,
                };
                return;
            }

            try ansi.writeStyled(self.writer, false, .{}, content);
            return;
        }

        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, .{
            .fg = self.ctx.palette.inline_code,
        }, content);
    }

    fn writeCodeBlock(self: *RenderSession, code_block: ast.CodeBlock) !void {
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, .{
            .fg = self.ctx.palette.inline_code,
        }, code_block.content);
    }

    fn writeCheckbox(self: *RenderSession, checked: ?bool) !void {
        if (checked) |is_checked| {
            if (is_checked) {
                try ansi.writeStyled(self.writer, self.ctx.enable_ansi, .{
                    .fg = self.ctx.palette.list_marker,
                }, checkbox_checked);
            } else {
                try ansi.writeStyled(self.writer, self.ctx.enable_ansi, .{
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

    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    var table_scratch: render_table.TableScratch = .{};
    defer table_scratch.deinit(allocator);
    var wrap = width.WrapWriter.init(undefined, 0, .narrow, allocator);
    defer wrap.deinit();

    const ctx: RenderContext = .{
        .doc = &doc,
        .enable_ansi = false,
        .ambiguous_width = .narrow,
        .palette = theme.default_palette,
        .syn_palette = theme.default_syntax_palette,
    };
    var session: RenderSession = .{
        .ctx = &ctx,
        .writer = &buf.writer,
        .ephemeral_allocator = allocator,
        .persistent_allocator = allocator,
        .table_scratch = &table_scratch,
        .wrap_writer = &wrap,
        .wrap_width = null,
        .highlighter = &highlighter,
    };

    try session.write(doc.blocks);

    try std.testing.expectEqualStrings("Hello", buf.writer.buffered());
}
