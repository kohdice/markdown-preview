const std = @import("std");
const ansi = @import("../term/ansi.zig");
const theme = @import("../term/theme.zig");
const width = @import("../term/width.zig");
const ast = @import("../ast.zig");
const parse_block = @import("../parse/block.zig");
const render_inline = @import("inline.zig");
const highlight = @import("../term/highlight.zig");

const DefMap = ast.LinkDefMap;

const thematic_break_width = 32;
const thematic_break_display = "─" ** thematic_break_width;
const min_table_col_width = 3;
const blockquote_marker = "│ ";
const checkbox_checked = "☑ ";
const checkbox_unchecked = "☐ ";

const list_bullet = struct {
    const level0 = "• ";
    const level1 = "◦ ";
    const level2 = "▪ ";
};

const table_border = struct {
    const vertical = "│";
    const horizontal = "─";

    const top_left = "┌";
    const top_join = "┬";
    const top_right = "┐";

    const mid_left = "├";
    const mid_join = "┼";
    const mid_right = "┤";

    const bot_left = "└";
    const bot_join = "┴";
    const bot_right = "┘";

    const cell_pad = " ";
};

const BorderKind = enum { top, middle, bottom };

const TablePlacement = enum {
    top_level,
    blockquote,

    fn cellColor(self: TablePlacement, palette: theme.Palette) theme.Rgb {
        return switch (self) {
            .top_level => palette.body,
            .blockquote => palette.muted,
        };
    }
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
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    enable_ansi: bool,
    wrap_width: ?usize,
    ambiguous_width: width.AmbiguousWidth,
    palette: theme.Palette,
    syn_palette: theme.SyntaxPalette,
    highlighter: *highlight.Highlighter,
    link_defs: *const DefMap,

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
            .table => |table| try self.writeTable(table, .top_level),
            .blank_line => {},
        }
    }

    fn writeParagraph(self: *Renderer, paragraph: ast.Paragraph) !void {
        for (paragraph.lines, 0..) |line, i| {
            if (i > 0) try self.writer.writeByte('\n');
            const stripped = parse_block.stripHardBreak(line);
            try self.writeInlineMaybeWrap(stripped, .{ .fg = self.palette.body }, 0);
        }
    }

    fn writeInlineMaybeWrap(
        self: *Renderer,
        text: []const u8,
        base_style: ansi.TextStyle,
        continuation_indent: usize,
    ) !void {
        if (self.wrap_width) |wrap_width| {
            var buf: std.io.Writer.Allocating = .init(self.allocator);
            defer buf.deinit();

            try render_inline.write(
                self.allocator,
                &buf.writer,
                text,
                self.enable_ansi,
                base_style,
                self.palette,
                self.link_defs,
            );

            var list = buf.toArrayList();
            defer list.deinit(self.allocator);
            const rendered = try list.toOwnedSlice(self.allocator);
            defer self.allocator.free(rendered);

            const available_width = if (wrap_width > continuation_indent) wrap_width - continuation_indent else 0;
            if (available_width == 0) {
                try self.writer.writeAll(rendered);
                return;
            }

            const wrapped = try width.wrapText(self.allocator, rendered, available_width, self.ambiguous_width);
            defer self.allocator.free(wrapped);
            if (continuation_indent == 0) {
                try self.writer.writeAll(wrapped);
                return;
            }

            var it = std.mem.splitScalar(u8, wrapped, '\n');
            var first = true;
            while (it.next()) |line| {
                if (!first) {
                    try self.writer.writeByte('\n');
                    try self.writer.splatByteAll(' ', continuation_indent);
                }
                first = false;
                try self.writer.writeAll(line);
            }
            return;
        }

        try render_inline.write(
            self.allocator,
            self.writer,
            text,
            self.enable_ansi,
            base_style,
            self.palette,
            self.link_defs,
        );
    }

    fn writeHeading(self: *Renderer, heading: ast.Heading) !void {
        const stripped = parse_block.stripHardBreak(heading.content);
        try render_inline.write(
            self.allocator,
            self.writer,
            stripped,
            self.enable_ansi,
            headingStyle(heading.level, self.palette),
            self.palette,
            self.link_defs,
        );
    }

    fn writeThematicBreak(self: *Renderer) !void {
        try ansi.writeStyled(self.writer, self.enable_ansi, .{
            .fg = self.palette.muted,
        }, thematic_break_display);
    }

    fn writeBlockQuote(self: *Renderer, blockquote: ast.BlockQuote, depth: usize) anyerror!void {
        var buf: std.io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();

        var child = self.*;
        child.writer = &buf.writer;
        if (self.wrap_width) |wrap_width| {
            const gutter_width = blockquote.indent + width.displayWidth(blockquote_marker, self.ambiguous_width);
            child.wrap_width = if (wrap_width > gutter_width) wrap_width - gutter_width else null;
        }

        try child.writeBlocksInBlockQuote(blockquote.blocks, depth);

        var list = buf.toArrayList();
        defer list.deinit(self.allocator);
        const rendered = try list.toOwnedSlice(self.allocator);
        defer self.allocator.free(rendered);

        const gutter_style: ansi.TextStyle = .{ .fg = self.palette.muted, .dim = true };
        var it = std.mem.splitScalar(u8, rendered, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try self.writer.writeByte('\n');
            first = false;
            try self.writer.splatByteAll(' ', blockquote.indent);
            try ansi.writeStyled(self.writer, self.enable_ansi, gutter_style, blockquote_marker);
            try self.writer.writeAll(line);
        }
    }

    fn writeBlocksInBlockQuote(self: *Renderer, blocks: []const ast.BlockNode, depth: usize) anyerror!void {
        for (blocks, 0..) |block, i| {
            if (i > 0) try self.writer.writeByte('\n');
            switch (block) {
                .paragraph => |paragraph| try self.writeBlockQuoteParagraph(paragraph),
                .blockquote => |blockquote| try self.writeBlockQuote(blockquote, depth),
                .table => |table| try self.writeTable(table, .blockquote),
                else => try self.writeBlock(block, depth),
            }
        }
    }

    fn writeBlockQuoteParagraph(self: *Renderer, paragraph: ast.Paragraph) !void {
        for (paragraph.lines, 0..) |line, i| {
            if (i > 0) try self.writer.writeByte('\n');
            const stripped = parse_block.stripHardBreak(line);
            try self.writeInlineMaybeWrap(stripped, .{ .fg = self.palette.muted }, 0);
        }
    }

    fn writeList(self: *Renderer, list: ast.List, depth: usize) anyerror!void {
        for (list.items, 0..) |item, i| {
            if (i > 0) try self.writer.writeByte('\n');
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

        var buf: std.io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();

        var child = self.*;
        child.writer = &buf.writer;
        if (self.wrap_width) |wrap_width| {
            child.wrap_width = if (wrap_width > indent) wrap_width - indent else null;
        }

        try child.writeBlock(child_block, depth);

        var list = buf.toArrayList();
        defer list.deinit(self.allocator);
        const rendered = try list.toOwnedSlice(self.allocator);
        defer self.allocator.free(rendered);

        var it = std.mem.splitScalar(u8, rendered, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) try self.writer.writeByte('\n');
            first = false;
            try self.writer.splatByteAll(' ', indent);
            try self.writer.writeAll(line);
        }
    }

    fn writeListItemParagraph(
        self: *Renderer,
        paragraph: ast.Paragraph,
        content_col: usize,
    ) !void {
        for (paragraph.lines, 0..) |line, i| {
            if (i > 0) {
                try self.writer.writeByte('\n');
                try self.writer.splatByteAll(' ', content_col);
            }
            const stripped = parse_block.stripHardBreak(line);
            try self.writeInlineMaybeWrap(stripped, .{ .fg = self.palette.body }, content_col);
        }
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

    fn writeTable(self: *Renderer, table: ast.Table, placement: TablePlacement) !void {
        const col_count = table.alignments.len;

        var col_widths = try self.allocator.alloc(usize, col_count);
        defer self.allocator.free(col_widths);
        for (col_widths) |*w| w.* = 0;

        for (0..col_count) |c| {
            if (c < table.header.len)
                col_widths[c] = @max(col_widths[c], try self.renderedInlineWidth(table.header[c]));
            for (table.rows) |row| {
                if (c < row.len)
                    col_widths[c] = @max(col_widths[c], try self.renderedInlineWidth(row[c]));
            }
            col_widths[c] = @max(col_widths[c], min_table_col_width);
        }

        if (self.ambiguous_width == .wide) {
            for (col_widths) |*w| {
                if (w.* % 2 != 0) w.* += 1;
            }
        }

        const cell_fg = placement.cellColor(self.palette);

        try self.writeTableBorder(col_widths, .top);
        try self.writer.writeByte('\n');

        try self.writeTableRow(table.header, col_widths, table.alignments, .{
            .fg = cell_fg,
            .bold = true,
        });
        try self.writer.writeByte('\n');

        try self.writeTableBorder(col_widths, .middle);

        for (table.rows, 0..) |row, i| {
            try self.writer.writeByte('\n');
            try self.writeTableRow(row, col_widths, table.alignments, .{
                .fg = cell_fg,
            });

            if (i + 1 < table.rows.len) {
                try self.writer.writeByte('\n');
                try self.writeTableBorder(col_widths, .middle);
            }
        }

        try self.writer.writeByte('\n');
        try self.writeTableBorder(col_widths, .bottom);
    }

    fn writeTableRow(
        self: *Renderer,
        cells: []const []const u8,
        col_widths: []const usize,
        alignments: []const ast.Alignment,
        style: ansi.TextStyle,
    ) !void {
        const bar_style: ansi.TextStyle = .{ .fg = self.palette.muted };

        try ansi.writeStyled(self.writer, self.enable_ansi, bar_style, table_border.vertical);
        try ansi.writeStyled(self.writer, self.enable_ansi, bar_style, table_border.cell_pad);
        for (0..col_widths.len) |c| {
            const cell_text = if (c < cells.len) cells[c] else "";
            const cell_width = try self.renderedInlineWidth(cell_text);
            const col_w = col_widths[c];
            const padding = if (col_w > cell_width) col_w - cell_width else 0;
            const col_align = if (c < alignments.len) alignments[c] else .left;

            const left_pad = switch (col_align) {
                .left => 0,
                .right => padding,
                .center => padding / 2,
            };
            const right_pad = padding - left_pad;

            try self.writer.splatByteAll(' ', left_pad);
            try render_inline.write(
                self.allocator,
                self.writer,
                cell_text,
                self.enable_ansi,
                style,
                self.palette,
                self.link_defs,
            );
            try self.writer.splatByteAll(' ', right_pad);

            if (c + 1 < col_widths.len) {
                try ansi.writeStyled(self.writer, self.enable_ansi, bar_style, table_border.cell_pad);
                try ansi.writeStyled(self.writer, self.enable_ansi, bar_style, table_border.vertical);
                try ansi.writeStyled(self.writer, self.enable_ansi, bar_style, table_border.cell_pad);
            }
        }
        try ansi.writeStyled(self.writer, self.enable_ansi, bar_style, table_border.cell_pad);
        try ansi.writeStyled(self.writer, self.enable_ansi, bar_style, table_border.vertical);
    }

    fn writeTableBorder(
        self: *Renderer,
        col_widths: []const usize,
        kind: BorderKind,
    ) !void {
        const style: ansi.TextStyle = .{ .fg = self.palette.muted };
        const left = switch (kind) {
            .top => table_border.top_left,
            .middle => table_border.mid_left,
            .bottom => table_border.bot_left,
        };
        const join = switch (kind) {
            .top => table_border.top_join,
            .middle => table_border.mid_join,
            .bottom => table_border.bot_join,
        };
        const right = switch (kind) {
            .top => table_border.top_right,
            .middle => table_border.mid_right,
            .bottom => table_border.bot_right,
        };

        const glyph_w: usize = if (self.ambiguous_width == .wide) 2 else 1;

        try ansi.writeStyled(self.writer, self.enable_ansi, style, left);
        for (0..col_widths.len) |c| {
            const segment_width = col_widths[c] + 2;
            const glyph_count = segment_width / glyph_w;
            for (0..glyph_count) |_| {
                try ansi.writeStyled(self.writer, self.enable_ansi, style, table_border.horizontal);
            }
            if (c + 1 < col_widths.len) {
                try ansi.writeStyled(self.writer, self.enable_ansi, style, join);
            }
        }
        try ansi.writeStyled(self.writer, self.enable_ansi, style, right);
    }

    fn renderedInlineWidth(self: *Renderer, text: []const u8) !usize {
        var output: std.io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();

        try render_inline.write(
            self.allocator,
            &output.writer,
            text,
            false,
            .{},
            self.palette,
            self.link_defs,
        );

        var list = output.toArrayList();
        defer list.deinit(self.allocator);
        const rendered = list.toOwnedSlice(self.allocator) catch return width.displayWidth(text, self.ambiguous_width);
        defer self.allocator.free(rendered);
        return width.displayWidth(rendered, self.ambiguous_width);
    }
};

fn checkboxWidth(checked: ?bool, ambiguous: width.AmbiguousWidth) usize {
    if (checked == null) return 0;
    const glyph = if (checked.?) checkbox_checked else checkbox_unchecked;
    return width.displayWidth(glyph, ambiguous);
}

test "Renderer.write renders heading content without document trailing newline" {
    const allocator = std.testing.allocator;
    const parse = @import("../parse.zig");
    var highlighter = highlight.Highlighter.init();
    defer highlighter.deinit();

    var doc = try parse.parse(allocator, "# Hello\n");
    defer doc.deinit(allocator);

    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    var renderer: Renderer = .{
        .writer = &buf.writer,
        .allocator = allocator,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
        .palette = theme.palette(.solarized_dark),
        .syn_palette = theme.syntaxPalette(.solarized_dark),
        .highlighter = &highlighter,
        .link_defs = &doc.link_defs,
    };

    try renderer.write(doc.blocks);

    try std.testing.expectEqualStrings("Hello", buf.writer.buffered());
}
