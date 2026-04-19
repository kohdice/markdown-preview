const std = @import("std");
const ansi = @import("../term/ansi.zig");
const ast = @import("../ast.zig");
const theme = @import("../term/theme.zig");
const width = @import("../term/width.zig");
const measure = @import("measure.zig");
const render_inline = @import("inline.zig");
const render_context = @import("context.zig");

const RenderContext = render_context.RenderContext;

const min_col_width = 3;
const border_line_stack_buf_size: usize = 2048;

const border = struct {
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

pub const TableScratch = struct {
    col_widths: std.ArrayListUnmanaged(usize) = .empty,
    header_widths: std.ArrayListUnmanaged(usize) = .empty,
    body_widths_flat: std.ArrayListUnmanaged(usize) = .empty,
    row_offsets: std.ArrayListUnmanaged(usize) = .empty,

    pub fn beginTable(self: *TableScratch) void {
        self.reset();
    }

    pub fn reset(self: *TableScratch) void {
        self.col_widths.clearRetainingCapacity();
        self.header_widths.clearRetainingCapacity();
        self.body_widths_flat.clearRetainingCapacity();
        self.row_offsets.clearRetainingCapacity();
    }

    pub fn deinit(self: *TableScratch, allocator: std.mem.Allocator) void {
        self.col_widths.deinit(allocator);
        self.header_widths.deinit(allocator);
        self.body_widths_flat.deinit(allocator);
        self.row_offsets.deinit(allocator);
        self.* = .{};
    }
};

pub const TablePlacement = enum {
    top_level,
    blockquote,

    pub fn cellColor(self: TablePlacement, palette: theme.Palette) theme.Rgb {
        return switch (self) {
            .top_level => palette.body,
            .blockquote => palette.muted,
        };
    }
};

pub fn writeTable(
    ctx: *const RenderContext,
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    scratch: *TableScratch,
    table: ast.Table,
    placement: TablePlacement,
) !void {
    const col_count = table.alignments.len;

    scratch.beginTable();
    try scratch.col_widths.appendNTimes(allocator, 0, col_count);
    try scratch.header_widths.appendNTimes(allocator, 0, col_count);
    try scratch.row_offsets.append(allocator, 0);

    for (0..col_count) |c| {
        if (c < table.header.len) {
            const cw = measure.inlineWidth(ctx.doc, table.header[c].children, ctx.ambiguous_width);
            scratch.header_widths.items[c] = cw;
            scratch.col_widths.items[c] = @max(scratch.col_widths.items[c], cw);
        }
    }

    for (table.rows) |row| {
        const cached_len = @min(row.len, col_count);
        for (row[0..cached_len], 0..) |cell, cell_index| {
            const cw = measure.inlineWidth(ctx.doc, cell.children, ctx.ambiguous_width);
            try scratch.body_widths_flat.append(allocator, cw);
            scratch.col_widths.items[cell_index] = @max(scratch.col_widths.items[cell_index], cw);
        }
        try scratch.row_offsets.append(allocator, scratch.body_widths_flat.items.len);
    }

    for (scratch.col_widths.items) |*w| {
        w.* = @max(w.*, min_col_width);
    }

    if (ctx.ambiguous_width == .wide) {
        for (scratch.col_widths.items) |*w| {
            if (w.* % 2 != 0) w.* += 1;
        }
    }

    const cell_fg = placement.cellColor(ctx.palette);
    const col_widths = scratch.col_widths.items;
    const header_widths = scratch.header_widths.items;

    try writeBorder(writer, col_widths, .top, ctx.enable_ansi, ctx.ambiguous_width, ctx.palette);
    try writer.writeByte('\n');

    try writeRow(ctx, writer, table.header, col_widths, header_widths, table.alignments, .{
        .fg = cell_fg,
        .bold = true,
    });
    try writer.writeByte('\n');

    try writeBorder(writer, col_widths, .middle, ctx.enable_ansi, ctx.ambiguous_width, ctx.palette);

    for (table.rows, 0..) |row, i| {
        const row_start = scratch.row_offsets.items[i];
        const row_end = scratch.row_offsets.items[i + 1];
        try writer.writeByte('\n');
        try writeRow(ctx, writer, row, col_widths, scratch.body_widths_flat.items[row_start..row_end], table.alignments, .{
            .fg = cell_fg,
        });

        if (i + 1 < table.rows.len) {
            try writer.writeByte('\n');
            try writeBorder(writer, col_widths, .middle, ctx.enable_ansi, ctx.ambiguous_width, ctx.palette);
        }
    }

    try writer.writeByte('\n');
    try writeBorder(writer, col_widths, .bottom, ctx.enable_ansi, ctx.ambiguous_width, ctx.palette);
}

fn writeRow(
    ctx: *const RenderContext,
    writer: *std.io.Writer,
    cells: []const ast.TableCell,
    col_widths: []const usize,
    pre_cell_widths: []const usize,
    alignments: []const ast.Alignment,
    style: ansi.TextStyle,
) !void {
    const bar_style: ansi.TextStyle = .{ .fg = ctx.palette.muted };
    const empty_children: ast.InlineRef = ast.no_inline;

    const row_open = border.vertical ++ border.cell_pad;
    const cell_separator = border.cell_pad ++ border.vertical ++ border.cell_pad;
    const row_close = border.cell_pad ++ border.vertical;

    try ansi.writeStyled(writer, ctx.enable_ansi, bar_style, row_open);
    for (0..col_widths.len) |c| {
        const cell_children = if (c < cells.len) cells[c].children else empty_children;
        const cell_width = if (c < pre_cell_widths.len) pre_cell_widths[c] else 0;
        const col_w = col_widths[c];
        const padding = if (col_w > cell_width) col_w - cell_width else 0;
        const col_align = if (c < alignments.len) alignments[c] else .left;

        const left_pad = switch (col_align) {
            .left => 0,
            .right => padding,
            .center => padding / 2,
        };
        const right_pad = padding - left_pad;

        try writer.splatByteAll(' ', left_pad);
        try render_inline.writeInlineChain(
            ctx,
            writer,
            cell_children,
            style,
        );
        try writer.splatByteAll(' ', right_pad);

        if (c + 1 < col_widths.len) {
            try ansi.writeStyled(writer, ctx.enable_ansi, bar_style, cell_separator);
        }
    }
    try ansi.writeStyled(writer, ctx.enable_ansi, bar_style, row_close);
}

fn writeBorder(
    writer: *std.io.Writer,
    col_widths: []const usize,
    kind: BorderKind,
    enable_ansi: bool,
    ambiguous_width: width.AmbiguousWidth,
    palette: theme.Palette,
) !void {
    const style: ansi.TextStyle = .{ .fg = palette.muted };
    const left = switch (kind) {
        .top => border.top_left,
        .middle => border.mid_left,
        .bottom => border.bot_left,
    };
    const join = switch (kind) {
        .top => border.top_join,
        .middle => border.mid_join,
        .bottom => border.bot_join,
    };
    const right = switch (kind) {
        .top => border.top_right,
        .middle => border.mid_right,
        .bottom => border.bot_right,
    };

    const glyph_w: usize = if (ambiguous_width == .wide) 2 else 1;

    var estimated: usize = left.len + right.len;
    for (col_widths) |w| estimated += ((w + 2) / glyph_w) * border.horizontal.len;
    if (col_widths.len > 1) estimated += (col_widths.len - 1) * join.len;

    var buf: [border_line_stack_buf_size]u8 = undefined;
    if (estimated <= buf.len) {
        var pos: usize = 0;
        @memcpy(buf[pos..][0..left.len], left);
        pos += left.len;
        for (0..col_widths.len) |c| {
            const segment_width = col_widths[c] + 2;
            const glyph_count = segment_width / glyph_w;
            for (0..glyph_count) |_| {
                @memcpy(buf[pos..][0..border.horizontal.len], border.horizontal);
                pos += border.horizontal.len;
            }
            if (c + 1 < col_widths.len) {
                @memcpy(buf[pos..][0..join.len], join);
                pos += join.len;
            }
        }
        @memcpy(buf[pos..][0..right.len], right);
        pos += right.len;
        try ansi.writeStyled(writer, enable_ansi, style, buf[0..pos]);
    } else {
        try ansi.writeStyled(writer, enable_ansi, style, left);
        for (0..col_widths.len) |c| {
            const segment_width = col_widths[c] + 2;
            const glyph_count = segment_width / glyph_w;
            for (0..glyph_count) |_| {
                try ansi.writeStyled(writer, enable_ansi, style, border.horizontal);
            }
            if (c + 1 < col_widths.len) {
                try ansi.writeStyled(writer, enable_ansi, style, join);
            }
        }
        try ansi.writeStyled(writer, enable_ansi, style, right);
    }
}
