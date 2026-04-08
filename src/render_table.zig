const std = @import("std");
const ansi = @import("ansi.zig");
const parse_table = @import("parse_table.zig");
const theme = @import("theme.zig");
const render_inline = @import("render_inline.zig");
const parse_link = @import("parse_link.zig");
const block_ast = @import("block_ast.zig");

const LinkDefMap = parse_link.LinkDefMap;

const min_table_col_width = 3;

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

pub const TableContext = enum {
    top_level,
    in_blockquote,

    fn cellForeground(self: TableContext, palette: theme.Palette) theme.Rgb {
        return switch (self) {
            .top_level => palette.body,
            .in_blockquote => palette.muted,
        };
    }
};

pub fn renderTableNode(
    writer: *std.io.Writer,
    table: block_ast.Table,
    allocator: std.mem.Allocator,
    enable_ansi: bool,
    palette: theme.Palette,
    link_defs: *const LinkDefMap,
    context: TableContext,
) !void {
    const col_count = table.alignments.len;

    var col_widths = try allocator.alloc(usize, col_count);
    defer allocator.free(col_widths);
    for (col_widths) |*w| w.* = 0;

    for (0..col_count) |c| {
        if (c < table.header.len)
            col_widths[c] = @max(col_widths[c], try render_inline.renderedDisplayWidth(allocator, table.header[c], palette, link_defs, .narrow));
        for (table.rows) |row| {
            if (c < row.len)
                col_widths[c] = @max(col_widths[c], try render_inline.renderedDisplayWidth(allocator, row[c], palette, link_defs, .narrow));
        }
        col_widths[c] = @max(col_widths[c], min_table_col_width);
    }

    const cell_fg = context.cellForeground(palette);

    try renderTableBorder(writer, col_widths, col_count, enable_ansi, palette, .top);
    try writer.writeByte('\n');

    try renderTableRow(allocator, writer, table.header, col_widths, table.alignments, col_count, enable_ansi, .{
        .fg = cell_fg,
        .bold = true,
    }, palette, link_defs);
    try writer.writeByte('\n');

    try renderTableBorder(writer, col_widths, col_count, enable_ansi, palette, .middle);

    for (table.rows, 0..) |row, i| {
        try writer.writeByte('\n');
        try renderTableRow(allocator, writer, row, col_widths, table.alignments, col_count, enable_ansi, .{
            .fg = cell_fg,
        }, palette, link_defs);

        if (i + 1 < table.rows.len) {
            try writer.writeByte('\n');
            try renderTableBorder(writer, col_widths, col_count, enable_ansi, palette, .middle);
        }
    }

    try writer.writeByte('\n');
    try renderTableBorder(writer, col_widths, col_count, enable_ansi, palette, .bottom);
}

fn renderTableRow(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    cells: []const []const u8,
    col_widths: []const usize,
    alignments: []const parse_table.Alignment,
    col_count: usize,
    enable_ansi: bool,
    style: ansi.TextStyle,
    palette: theme.Palette,
    link_defs: *const LinkDefMap,
) !void {
    const bar_style: ansi.TextStyle = .{ .fg = palette.muted };

    try ansi.writeStyled(writer, enable_ansi, bar_style, border.vertical);
    try ansi.writeStyled(writer, enable_ansi, bar_style, border.cell_pad);
    for (0..col_count) |c| {
        const cell_text = if (c < cells.len) cells[c] else "";
        const cell_width = try render_inline.renderedDisplayWidth(allocator, cell_text, palette, link_defs, .narrow);
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
        try render_inline.renderInline(allocator, writer, cell_text, enable_ansi, style, palette, link_defs);
        try writer.splatByteAll(' ', right_pad);

        if (c + 1 < col_count) {
            try ansi.writeStyled(writer, enable_ansi, bar_style, border.cell_pad);
            try ansi.writeStyled(writer, enable_ansi, bar_style, border.vertical);
            try ansi.writeStyled(writer, enable_ansi, bar_style, border.cell_pad);
        }
    }
    try ansi.writeStyled(writer, enable_ansi, bar_style, border.cell_pad);
    try ansi.writeStyled(writer, enable_ansi, bar_style, border.vertical);
}

fn renderTableBorder(
    writer: *std.io.Writer,
    col_widths: []const usize,
    col_count: usize,
    enable_ansi: bool,
    palette: theme.Palette,
    kind: BorderKind,
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

    try ansi.writeStyled(writer, enable_ansi, style, left);
    for (0..col_count) |c| {
        const segment_width = col_widths[c] + 2;
        for (0..segment_width) |_| {
            try ansi.writeStyled(writer, enable_ansi, style, border.horizontal);
        }
        if (c + 1 < col_count) {
            try ansi.writeStyled(writer, enable_ansi, style, join);
        }
    }
    try ansi.writeStyled(writer, enable_ansi, style, right);
}
