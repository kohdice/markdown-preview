const std = @import("std");
const ansi = @import("../term/ansi.zig");
const ast = @import("../ast.zig");
const theme = @import("../term/theme.zig");
const width = @import("../term/width.zig");
const measure = @import("measure.zig");
const render_inline = @import("inline.zig");

const min_col_width = 3;

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
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    table: ast.Table,
    placement: TablePlacement,
    enable_ansi: bool,
    ambiguous_width: width.AmbiguousWidth,
    palette: theme.Palette,
) !void {
    const col_count = table.alignments.len;

    var col_widths = try allocator.alloc(usize, col_count);
    defer allocator.free(col_widths);
    for (col_widths) |*w| w.* = 0;

    var cell_widths_header = try allocator.alloc(usize, col_count);
    defer allocator.free(cell_widths_header);

    var body_widths = try allocator.alloc([]usize, table.rows.len);
    var initialized_body_rows: usize = 0;
    defer {
        for (body_widths[0..initialized_body_rows]) |row_widths| allocator.free(row_widths);
        allocator.free(body_widths);
    }

    for (table.rows, 0..) |row, row_index| {
        const row_cached = try allocator.alloc(usize, row.len);
        body_widths[row_index] = row_cached;
        initialized_body_rows += 1;
        for (row, 0..) |cell, cell_index| {
            const cw = measure.inlineWidth(cell.children, ambiguous_width);
            row_cached[cell_index] = cw;
            if (cell_index < col_count) {
                col_widths[cell_index] = @max(col_widths[cell_index], cw);
            }
        }
    }

    for (0..col_count) |c| {
        if (c < table.header.len) {
            const cw = measure.inlineWidth(table.header[c].children, ambiguous_width);
            cell_widths_header[c] = cw;
            col_widths[c] = @max(col_widths[c], cw);
        } else {
            cell_widths_header[c] = 0;
        }
        col_widths[c] = @max(col_widths[c], min_col_width);
    }

    if (ambiguous_width == .wide) {
        for (col_widths) |*w| {
            if (w.* % 2 != 0) w.* += 1;
        }
    }

    const cell_fg = placement.cellColor(palette);

    try writeBorder(writer, col_widths, .top, enable_ansi, ambiguous_width, palette);
    try writer.writeByte('\n');

    try writeRow(writer, table.header, col_widths, cell_widths_header, table.alignments, .{
        .fg = cell_fg,
        .bold = true,
    }, enable_ansi, ambiguous_width, palette);
    try writer.writeByte('\n');

    try writeBorder(writer, col_widths, .middle, enable_ansi, ambiguous_width, palette);

    for (table.rows, 0..) |row, i| {
        try writer.writeByte('\n');
        try writeRow(writer, row, col_widths, body_widths[i], table.alignments, .{
            .fg = cell_fg,
        }, enable_ansi, ambiguous_width, palette);

        if (i + 1 < table.rows.len) {
            try writer.writeByte('\n');
            try writeBorder(writer, col_widths, .middle, enable_ansi, ambiguous_width, palette);
        }
    }

    try writer.writeByte('\n');
    try writeBorder(writer, col_widths, .bottom, enable_ansi, ambiguous_width, palette);
}

fn writeRow(
    writer: *std.io.Writer,
    cells: []const ast.TableCell,
    col_widths: []const usize,
    pre_cell_widths: ?[]const usize,
    alignments: []const ast.Alignment,
    style: ansi.TextStyle,
    enable_ansi: bool,
    ambiguous_width: width.AmbiguousWidth,
    palette: theme.Palette,
) !void {
    const bar_style: ansi.TextStyle = .{ .fg = palette.muted };

    try ansi.writeStyled(writer, enable_ansi, bar_style, border.vertical);
    try ansi.writeStyled(writer, enable_ansi, bar_style, border.cell_pad);
    for (0..col_widths.len) |c| {
        const cell_children = if (c < cells.len) cells[c].children else &[_]ast.Inline{};
        const cell_width = if (pre_cell_widths) |pw|
            (if (c < pw.len) pw[c] else 0)
        else
            measure.inlineWidth(cell_children, ambiguous_width);
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
        try render_inline.writeInlines(
            writer,
            cell_children,
            enable_ansi,
            style,
            palette,
        );
        try writer.splatByteAll(' ', right_pad);

        if (c + 1 < col_widths.len) {
            try ansi.writeStyled(writer, enable_ansi, bar_style, border.cell_pad);
            try ansi.writeStyled(writer, enable_ansi, bar_style, border.vertical);
            try ansi.writeStyled(writer, enable_ansi, bar_style, border.cell_pad);
        }
    }
    try ansi.writeStyled(writer, enable_ansi, bar_style, border.cell_pad);
    try ansi.writeStyled(writer, enable_ansi, bar_style, border.vertical);
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
