const std = @import("std");
const ansi = @import("ansi.zig");
const parse_table = @import("parse_table.zig");
const theme = @import("theme.zig");
const parse_block = @import("parse_block.zig");
const text = @import("text.zig");
const parse_link = @import("parse_link.zig");

const LinkDefMap = parse_link.LinkDefMap;

const min_table_col_width = 3;

const border = struct {
    const row_start = "| ";
    const cell_separator = " | ";
    const row_end = " |";
    const divider_start = "|-";
    const divider_fill = "-";
    const divider_separator = "-+-";
    const divider_end = "-|";
};

pub fn tryRenderTable(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    input: []const u8,
    header_line: []const u8,
    header_end: usize,
    enable_ansi: bool,
    palette: theme.Palette,
    link_defs: *const LinkDefMap,
) !?usize {
    if (std.mem.indexOfScalar(u8, header_line, '|') == null) return null;

    const after_header = header_end + 1;
    if (after_header >= input.len) return null;

    const delim_end = std.mem.indexOfScalarPos(u8, input, after_header, '\n') orelse input.len;
    const delim_line = std.mem.trimEnd(u8, input[after_header..delim_end], parse_block.carriage_return);

    if (!parse_table.isDelimiterRow(delim_line)) return null;

    const header_cells = try parse_table.parseCells(allocator, header_line);
    defer allocator.free(header_cells);
    const alignments = try parse_table.parseAlignments(allocator, delim_line);
    defer allocator.free(alignments);
    if (header_cells.len != alignments.len) return null;

    var body_lines: std.ArrayListUnmanaged([]const u8) = .{};
    defer body_lines.deinit(allocator);

    var pos = delim_end + 1;
    while (pos < input.len) {
        const row_end = std.mem.indexOfScalarPos(u8, input, pos, '\n') orelse input.len;
        const row_line = std.mem.trimEnd(u8, input[pos..row_end], parse_block.carriage_return);

        if (std.mem.trim(u8, row_line, parse_block.horizontal_whitespace).len == 0 or std.mem.indexOfScalar(u8, row_line, '|') == null) break;
        if (parse_block.isBlockLevelStart(row_line)) break;

        try body_lines.append(allocator, row_line);
        pos = row_end + 1;
    }

    var body_rows: std.ArrayListUnmanaged([][]const u8) = .{};
    defer {
        for (body_rows.items) |row| allocator.free(row);
        body_rows.deinit(allocator);
    }
    for (body_lines.items) |bl| {
        try body_rows.append(allocator, try parse_table.parseCells(allocator, bl));
    }

    const col_count = alignments.len;

    var col_widths = try allocator.alloc(usize, col_count);
    defer allocator.free(col_widths);
    for (col_widths) |*w| w.* = 0;

    for (0..col_count) |c| {
        if (c < header_cells.len)
            col_widths[c] = @max(col_widths[c], try text.renderedDisplayWidth(allocator, header_cells[c], palette, link_defs));
        for (body_rows.items) |row| {
            if (c < row.len)
                col_widths[c] = @max(col_widths[c], try text.renderedDisplayWidth(allocator, row[c], palette, link_defs));
        }
        col_widths[c] = @max(col_widths[c], min_table_col_width);
    }

    try renderTableRow(allocator, writer, header_cells, col_widths, alignments, col_count, enable_ansi, .{
        .fg = palette.body,
        .bold = true,
    }, palette, link_defs);
    try writer.writeByte('\n');

    try renderTableSeparator(writer, col_widths, col_count, enable_ansi, palette);
    try writer.writeByte('\n');

    for (body_rows.items) |row| {
        try renderTableRow(allocator, writer, row, col_widths, alignments, col_count, enable_ansi, .{
            .fg = palette.body,
        }, palette, link_defs);
        try writer.writeByte('\n');
    }

    return pos;
}

pub fn tryRenderBlockQuoteTable(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    input: []const u8,
    start_pos: usize,
    enable_ansi: bool,
    palette: theme.Palette,
    link_defs: *const LinkDefMap,
) !?usize {
    var pos = start_pos;
    if (pos >= input.len) return null;
    var end = std.mem.indexOfScalarPos(u8, input, pos, '\n') orelse input.len;
    var has_nl = end < input.len;
    var raw = std.mem.trimEnd(u8, input[pos..end], parse_block.carriage_return);
    const first_bq = parse_block.parseBlockQuote(raw) orelse return null;
    if (std.mem.indexOfScalar(u8, first_bq.content, '|') == null) return null;
    const bq_indent = first_bq.indent;
    pos = end + @intFromBool(has_nl);

    if (pos >= input.len) return null;
    end = std.mem.indexOfScalarPos(u8, input, pos, '\n') orelse input.len;
    has_nl = end < input.len;
    raw = std.mem.trimEnd(u8, input[pos..end], parse_block.carriage_return);
    const second_bq = parse_block.parseBlockQuote(raw) orelse return null;
    if (!parse_table.isDelimiterRow(second_bq.content)) return null;
    pos = end + @intFromBool(has_nl);

    const header_cells = try parse_table.parseCells(allocator, first_bq.content);
    defer allocator.free(header_cells);
    const alignments = try parse_table.parseAlignments(allocator, second_bq.content);
    defer allocator.free(alignments);
    if (header_cells.len != alignments.len) return null;

    var body_rows: std.ArrayListUnmanaged([][]const u8) = .{};
    defer {
        for (body_rows.items) |row| allocator.free(row);
        body_rows.deinit(allocator);
    }

    while (pos < input.len) {
        end = std.mem.indexOfScalarPos(u8, input, pos, '\n') orelse input.len;
        has_nl = end < input.len;
        raw = std.mem.trimEnd(u8, input[pos..end], parse_block.carriage_return);

        const bq = parse_block.parseBlockQuote(raw) orelse break;
        if (std.mem.trim(u8, bq.content, parse_block.horizontal_whitespace).len == 0 or std.mem.indexOfScalar(u8, bq.content, '|') == null) break;
        if (parse_block.isBlockLevelStart(bq.content)) break;

        try body_rows.append(allocator, try parse_table.parseCells(allocator, bq.content));
        pos = end + @intFromBool(has_nl);
    }

    const col_count = alignments.len;

    var col_widths = try allocator.alloc(usize, col_count);
    defer allocator.free(col_widths);
    for (col_widths) |*w| w.* = 0;

    for (0..col_count) |c| {
        if (c < header_cells.len)
            col_widths[c] = @max(col_widths[c], try text.renderedDisplayWidth(allocator, header_cells[c], palette, link_defs));
        for (body_rows.items) |row| {
            if (c < row.len)
                col_widths[c] = @max(col_widths[c], try text.renderedDisplayWidth(allocator, row[c], palette, link_defs));
        }
        col_widths[c] = @max(col_widths[c], min_table_col_width);
    }

    try writer.splatByteAll(' ', bq_indent);
    try ansi.writeStyled(writer, enable_ansi, .{ .fg = palette.muted, .dim = true }, border.row_start);
    try renderTableRow(allocator, writer, header_cells, col_widths, alignments, col_count, enable_ansi, .{
        .fg = palette.muted,
        .bold = true,
    }, palette, link_defs);
    try writer.writeByte('\n');

    try writer.splatByteAll(' ', bq_indent);
    try ansi.writeStyled(writer, enable_ansi, .{ .fg = palette.muted, .dim = true }, border.row_start);
    try renderTableSeparator(writer, col_widths, col_count, enable_ansi, palette);
    try writer.writeByte('\n');

    for (body_rows.items) |row| {
        try writer.splatByteAll(' ', bq_indent);
        try ansi.writeStyled(writer, enable_ansi, .{ .fg = palette.muted, .dim = true }, border.row_start);
        try renderTableRow(allocator, writer, row, col_widths, alignments, col_count, enable_ansi, .{
            .fg = palette.muted,
        }, palette, link_defs);
        try writer.writeByte('\n');
    }

    return pos;
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
    try ansi.writeStyled(writer, enable_ansi, .{ .dim = true }, border.row_start);
    for (0..col_count) |c| {
        const cell_text = if (c < cells.len) cells[c] else "";
        const cell_width = try text.renderedDisplayWidth(allocator, cell_text, palette, link_defs);
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
        try text.renderInline(allocator, writer, cell_text, enable_ansi, style, palette, link_defs);
        try writer.splatByteAll(' ', right_pad);

        if (c + 1 < col_count) {
            try ansi.writeStyled(writer, enable_ansi, .{ .dim = true }, border.cell_separator);
        }
    }
    try ansi.writeStyled(writer, enable_ansi, .{ .dim = true }, border.row_end);
}

fn renderTableSeparator(
    writer: *std.io.Writer,
    col_widths: []const usize,
    col_count: usize,
    enable_ansi: bool,
    palette: theme.Palette,
) !void {
    const style: ansi.TextStyle = .{ .fg = palette.subtle, .dim = true };
    try ansi.writeStyled(writer, enable_ansi, style, border.divider_start);
    for (0..col_count) |c| {
        for (0..col_widths[c]) |_| {
            try ansi.writeStyled(writer, enable_ansi, style, border.divider_fill);
        }
        if (c + 1 < col_count) {
            try ansi.writeStyled(writer, enable_ansi, style, border.divider_separator);
        }
    }
    try ansi.writeStyled(writer, enable_ansi, style, border.divider_end);
}
