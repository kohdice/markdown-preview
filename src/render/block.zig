const std = @import("std");
const ansi = @import("../term/ansi.zig");
const theme = @import("../term/theme.zig");
const width = @import("../term/width.zig");
const ast = @import("../ast.zig");
const render_inline = @import("inline.zig");
const prefix_writer = @import("prefix_writer.zig");
const render_table = @import("table.zig");
const highlight = @import("../term/highlight.zig");

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

pub const Renderer = struct {
    doc: *const ast.Document,
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    enable_ansi: bool,
    wrap_width: ?usize,
    ambiguous_width: width.AmbiguousWidth,
    palette: theme.Palette,
    syn_palette: theme.SyntaxPalette,
    highlighter: *highlight.Highlighter,

    pub fn write(self: *Renderer, blocks: []const ast.BlockNode) !void {
        for (blocks, 0..) |block, i| {
            if (i > 0) try self.writer.writeByte('\n');
            try self.writeBlock(block, 0);
        }
    }

    fn writeBlock(self: *Renderer, block: ast.BlockNode, depth: usize) anyerror!void {
        switch (block) {
            .paragraph => |paragraph| try self.writeParagraph(paragraph),
            .heading => |heading| try self.writeHeading(heading),
            .blockquote => |blockquote| try self.writeBlockQuote(blockquote, depth),
            .list => |list| try self.writeList(list, depth),
            .code_fence => |code_fence| try self.writeCodeFence(code_fence),
            .thematic_break => try self.writeThematicBreak(),
            .table => |table| try render_table.writeTable(self.writer, self.allocator, self.doc, table, .top_level, self.enable_ansi, self.ambiguous_width, self.palette),
            .blank_line => {},
        }
    }

    fn writeParagraph(self: *Renderer, paragraph: ast.Paragraph) !void {
        try self.writeInlinesMaybeWrap(paragraph.children, .{ .fg = self.palette.body }, 0);
    }

    fn writeInlinesMaybeWrap(
        self: *Renderer,
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

        if (self.wrap_width) |wrap_width| {
            const available = if (wrap_width > continuation_indent)
                wrap_width - continuation_indent
            else
                1;
            var wrap = width.WrapWriter.init(target, available, self.ambiguous_width, self.allocator);
            defer wrap.deinit();
            try render_inline.writeInlineChain(&wrap.writer, self.doc, first, self.enable_ansi, base_style, self.palette);
            try wrap.finish();
        } else {
            try render_inline.writeInlineChain(target, self.doc, first, self.enable_ansi, base_style, self.palette);
        }

        if (prefix) |*p| try p.finish();
    }

    fn writeHeading(self: *Renderer, heading: ast.Heading) !void {
        try render_inline.writeInlineChain(
            self.writer,
            self.doc,
            heading.children,
            self.enable_ansi,
            headingStyle(heading.level, self.palette),
            self.palette,
        );
    }

    fn writeThematicBreak(self: *Renderer) !void {
        try ansi.writeStyled(self.writer, self.enable_ansi, .{
            .fg = self.palette.muted,
        }, thematic_break_display);
    }

    fn writeBlockQuote(self: *Renderer, blockquote: ast.BlockQuote, depth: usize) anyerror!void {
        const gutter_style: ansi.TextStyle = .{ .fg = self.palette.muted, .dim = true };
        const gutter_width = blockquote.indent + width.displayWidth(blockquote_marker, self.ambiguous_width);

        var prefix = prefix_writer.PrefixWriter.init(self.writer, .{
            .indent = blockquote.indent,
            .styled_prefix = blockquote_marker,
            .style = gutter_style,
            .enable_ansi = self.enable_ansi,
        });

        var child = self.*;
        child.writer = &prefix.writer;
        if (self.wrap_width) |ww| {
            child.wrap_width = if (ww > gutter_width) ww - gutter_width else null;
        }

        try child.writeBlocksInBlockQuote(blockquote.blocks, depth);
        try prefix.finish();
    }

    fn writeBlocksInBlockQuote(self: *Renderer, blocks: []const ast.BlockNode, depth: usize) anyerror!void {
        for (blocks, 0..) |block, i| {
            if (i > 0) try self.writer.writeByte('\n');
            switch (block) {
                .paragraph => |paragraph| try self.writeBlockQuoteParagraph(paragraph),
                .blockquote => |blockquote| try self.writeBlockQuote(blockquote, depth),
                .table => |table| try render_table.writeTable(self.writer, self.allocator, self.doc, table, .blockquote, self.enable_ansi, self.ambiguous_width, self.palette),
                else => try self.writeBlock(block, depth),
            }
        }
    }

    fn writeBlockQuoteParagraph(self: *Renderer, paragraph: ast.Paragraph) !void {
        try self.writeInlinesMaybeWrap(paragraph.children, .{ .fg = self.palette.muted }, 0);
    }

    fn writeList(self: *Renderer, list: ast.List, depth: usize) anyerror!void {
        for (list.items, 0..) |item, i| {
            if (i > 0) {
                try self.writer.writeByte('\n');
                if (list.loose) try self.writer.writeByte('\n');
            }
            try self.writeListItem(item, depth);
        }
    }

    fn writeListItem(self: *Renderer, item: ast.ListItem, depth: usize) anyerror!void {
        try self.writer.splatByteAll(' ', item.indent);

        const marker_style: ansi.TextStyle = .{
            .fg = self.palette.list_marker,
            .bold = true,
        };

        var content_col: usize = item.indent;
        if (item.number) |number| {
            try ansi.writeStyled(self.writer, self.enable_ansi, marker_style, number);
            const marker_buf: [2]u8 = .{ item.marker, ' ' };
            try ansi.writeStyled(self.writer, self.enable_ansi, marker_style, &marker_buf);
            content_col += width.displayWidth(number, self.ambiguous_width) + width.displayWidth(&marker_buf, self.ambiguous_width);
        } else {
            const marker_text = bulletForDepth(depth);
            try ansi.writeStyled(self.writer, self.enable_ansi, marker_style, marker_text);
            content_col += width.displayWidth(marker_text, self.ambiguous_width);
        }
        content_col += checkboxWidth(item.checked, self.ambiguous_width);

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
        self: *Renderer,
        child_block: ast.BlockNode,
        indent: usize,
        depth: usize,
    ) anyerror!void {
        if (indent == 0) return self.writeBlock(child_block, depth);

        var prefix = prefix_writer.PrefixWriter.init(self.writer, .{ .indent = indent });

        var child = self.*;
        child.writer = &prefix.writer;
        if (self.wrap_width) |ww| {
            child.wrap_width = if (ww > indent) ww - indent else null;
        }

        try child.writeBlock(child_block, depth);
        try prefix.finish();
    }

    fn writeListItemParagraph(
        self: *Renderer,
        paragraph: ast.Paragraph,
        content_col: usize,
    ) !void {
        if (content_col == 0 or self.wrap_width != null) {
            try self.writeInlinesMaybeWrap(paragraph.children, .{ .fg = self.palette.body }, content_col);
            return;
        }

        var prefix = prefix_writer.PrefixWriter.init(self.writer, .{
            .indent = content_col,
            .prefix_first_line = false,
        });
        try render_inline.writeInlineChain(
            &prefix.writer,
            self.doc,
            paragraph.children,
            self.enable_ansi,
            .{ .fg = self.palette.body },
            self.palette,
        );
        try prefix.finish();
    }

    fn writeCodeFence(self: *Renderer, code_fence: ast.CodeFence) !void {
        const fence_style: ansi.TextStyle = .{ .fg = self.palette.code_fence, .dim = true };
        try ansi.writeStyled(self.writer, self.enable_ansi, fence_style, code_fence.opener);

        const language = highlight.Language.fromString(code_fence.language);
        if (code_fence.content.len > 0) {
            try self.writer.writeByte('\n');
            try self.writeFenceBody(code_fence.content, language);
        }

        if (code_fence.closer) |closer| {
            try self.writer.writeByte('\n');
            try ansi.writeStyled(self.writer, self.enable_ansi, fence_style, closer);
        }
    }

    fn writeFenceBody(self: *Renderer, content: []const u8, language: ?highlight.Language) !void {
        if (language) |lang| {
            if (self.enable_ansi) {
                self.highlighter.writeHighlightedBlock(
                    self.allocator,
                    self.writer,
                    content,
                    lang,
                    self.syn_palette,
                ) catch |err| switch (err) {
                    error.QueryUnavailable => {
                        try ansi.writeStyled(self.writer, true, .{ .fg = self.palette.inline_code }, content);
                    },
                    else => return err,
                };
                return;
            }

            try ansi.writeStyled(self.writer, false, .{}, content);
            return;
        }

        try ansi.writeStyled(self.writer, self.enable_ansi, .{
            .fg = self.palette.inline_code,
        }, content);
    }

    fn writeCheckbox(self: *Renderer, checked: ?bool) !void {
        if (checked) |is_checked| {
            if (is_checked) {
                try ansi.writeStyled(self.writer, self.enable_ansi, .{
                    .fg = self.palette.list_marker,
                }, checkbox_checked);
            } else {
                try ansi.writeStyled(self.writer, self.enable_ansi, .{
                    .fg = self.palette.muted,
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

test "Renderer.write renders heading content without document trailing newline" {
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

    var renderer: Renderer = .{
        .doc = &doc,
        .writer = &buf.writer,
        .allocator = allocator,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
        .palette = theme.palette(.solarized_dark),
        .syn_palette = theme.syntaxPalette(.solarized_dark),
        .highlighter = &highlighter,
    };

    try renderer.write(doc.blocks);

    try std.testing.expectEqualStrings("Hello", buf.writer.buffered());
}
