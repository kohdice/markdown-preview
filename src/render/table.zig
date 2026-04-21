const std = @import("std");
const ansi = @import("../term/ansi.zig");
const ast = @import("../ast.zig");
const theme = @import("../term/theme.zig");
const width = @import("../term/width.zig");
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

const CellRecord = struct {
    byte_start: u32,
    byte_end: u32,
    display_width: u32,
};

pub const TableScratch = struct {
    col_widths: std.ArrayListUnmanaged(usize) = .empty,
    row_offsets: std.ArrayListUnmanaged(usize) = .empty,
    bytes_buf: std.ArrayListUnmanaged(u8) = .empty,
    header_records: std.ArrayListUnmanaged(CellRecord) = .empty,
    body_records_flat: std.ArrayListUnmanaged(CellRecord) = .empty,

    pub fn beginTable(self: *TableScratch) void {
        self.reset();
    }

    pub fn reset(self: *TableScratch) void {
        self.col_widths.clearRetainingCapacity();
        self.row_offsets.clearRetainingCapacity();
        self.bytes_buf.clearRetainingCapacity();
        self.header_records.clearRetainingCapacity();
        self.body_records_flat.clearRetainingCapacity();
    }

    pub fn deinit(self: *TableScratch, allocator: std.mem.Allocator) void {
        self.col_widths.deinit(allocator);
        self.row_offsets.deinit(allocator);
        self.bytes_buf.deinit(allocator);
        self.header_records.deinit(allocator);
        self.body_records_flat.deinit(allocator);
        self.* = .{};
    }
};

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

const ScratchWriter = struct {
    pub const stack_buffer_size: usize = 1024;

    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    stack_buf: [stack_buffer_size]u8 = undefined,
    writer: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.defaultFlush,
        .rebase = std.Io.Writer.failingRebase,
    };

    fn init(self: *ScratchWriter, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) void {
        self.* = .{
            .buf = buf,
            .allocator = allocator,
            .writer = .{
                .buffer = &.{},
                .vtable = &vtable,
            },
        };
        self.writer.buffer = &self.stack_buf;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ScratchWriter = @fieldParentPtr("writer", w);

        const pending = w.buffered();
        if (pending.len > 0) {
            self.buf.appendSlice(self.allocator, pending) catch return error.WriteFailed;
            w.end = 0;
        }

        var total: usize = 0;
        for (data, 0..) |slice, idx| {
            const repeat: usize = if (idx == data.len - 1) splat else 1;
            for (0..repeat) |_| {
                self.buf.appendSlice(self.allocator, slice) catch return error.WriteFailed;
                total += slice.len;
            }
        }
        return total;
    }
};

pub fn writeTable(
    ctx: *const RenderContext,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    scratch: *TableScratch,
    table: ast.Table,
    placement: TablePlacement,
) !void {
    const col_count = table.alignments.len;

    scratch.beginTable();
    try scratch.col_widths.appendNTimes(allocator, 0, col_count);
    try scratch.row_offsets.append(allocator, 0);

    const cell_fg = placement.cellColor(ctx.palette);
    const header_style: ansi.TextStyle = .{ .fg = cell_fg, .bold = true };
    const body_style: ansi.TextStyle = .{ .fg = cell_fg };

    var scratch_writer: ScratchWriter = undefined;
    scratch_writer.init(&scratch.bytes_buf, allocator);

    for (0..col_count) |c| {
        const byte_start: u32 = @intCast(scratch.bytes_buf.items.len);
        var cell_width: usize = 0;
        if (c < table.header.len) {
            cell_width = try render_inline.writeAndMeasureInlineChain(
                ctx,
                &scratch_writer.writer,
                table.header[c].children,
                header_style,
                ctx.ambiguous_width,
            );
        }
        try scratch_writer.writer.flush();
        const byte_end: u32 = @intCast(scratch.bytes_buf.items.len);
        try scratch.header_records.append(allocator, .{
            .byte_start = byte_start,
            .byte_end = byte_end,
            .display_width = @intCast(cell_width),
        });
        scratch.col_widths.items[c] = @max(scratch.col_widths.items[c], cell_width);
    }

    for (table.rows) |row| {
        const cached_len = @min(row.len, col_count);
        for (row[0..cached_len], 0..) |cell, cell_index| {
            const byte_start: u32 = @intCast(scratch.bytes_buf.items.len);
            const cell_width = try render_inline.writeAndMeasureInlineChain(
                ctx,
                &scratch_writer.writer,
                cell.children,
                body_style,
                ctx.ambiguous_width,
            );
            try scratch_writer.writer.flush();
            const byte_end: u32 = @intCast(scratch.bytes_buf.items.len);
            try scratch.body_records_flat.append(allocator, .{
                .byte_start = byte_start,
                .byte_end = byte_end,
                .display_width = @intCast(cell_width),
            });
            scratch.col_widths.items[cell_index] = @max(scratch.col_widths.items[cell_index], cell_width);
        }
        try scratch.row_offsets.append(allocator, scratch.body_records_flat.items.len);
    }

    for (scratch.col_widths.items) |*w| {
        w.* = @max(w.*, min_col_width);
    }

    if (ctx.ambiguous_width == .wide) {
        for (scratch.col_widths.items) |*w| {
            if (w.* % 2 != 0) w.* += 1;
        }
    }

    const col_widths = scratch.col_widths.items;
    const bytes = scratch.bytes_buf.items;

    try writeBorder(writer, col_widths, .top, ctx.enable_ansi, ctx.color_mode, ctx.ambiguous_width, ctx.palette);
    try writer.writeByte('\n');

    try writeRowFromScratch(
        ctx,
        writer,
        bytes,
        scratch.header_records.items,
        col_widths,
        table.alignments,
    );
    try writer.writeByte('\n');

    try writeBorder(writer, col_widths, .middle, ctx.enable_ansi, ctx.color_mode, ctx.ambiguous_width, ctx.palette);

    for (0..table.rows.len) |i| {
        const row_start = scratch.row_offsets.items[i];
        const row_end = scratch.row_offsets.items[i + 1];
        try writer.writeByte('\n');
        try writeRowFromScratch(
            ctx,
            writer,
            bytes,
            scratch.body_records_flat.items[row_start..row_end],
            col_widths,
            table.alignments,
        );

        if (i + 1 < table.rows.len) {
            try writer.writeByte('\n');
            try writeBorder(writer, col_widths, .middle, ctx.enable_ansi, ctx.color_mode, ctx.ambiguous_width, ctx.palette);
        }
    }

    try writer.writeByte('\n');
    try writeBorder(writer, col_widths, .bottom, ctx.enable_ansi, ctx.color_mode, ctx.ambiguous_width, ctx.palette);
}

fn writeRowFromScratch(
    ctx: *const RenderContext,
    writer: *std.Io.Writer,
    bytes: []const u8,
    records: []const CellRecord,
    col_widths: []const usize,
    alignments: []const ast.Alignment,
) !void {
    const bar_style: ansi.TextStyle = .{ .fg = ctx.palette.muted };

    const row_open = border.vertical ++ border.cell_pad;
    const cell_separator = border.cell_pad ++ border.vertical ++ border.cell_pad;
    const row_close = border.cell_pad ++ border.vertical;

    try ansi.writeStyled(writer, ctx.enable_ansi, ctx.color_mode, bar_style, row_open);
    for (0..col_widths.len) |c| {
        const record: ?CellRecord = if (c < records.len) records[c] else null;
        const cell_width: usize = if (record) |r| r.display_width else 0;
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
        if (record) |r| {
            try writer.writeAll(bytes[r.byte_start..r.byte_end]);
        }
        try writer.splatByteAll(' ', right_pad);

        if (c + 1 < col_widths.len) {
            try ansi.writeStyled(writer, ctx.enable_ansi, ctx.color_mode, bar_style, cell_separator);
        }
    }
    try ansi.writeStyled(writer, ctx.enable_ansi, ctx.color_mode, bar_style, row_close);
}

fn writeBorder(
    writer: *std.Io.Writer,
    col_widths: []const usize,
    kind: BorderKind,
    enable_ansi: bool,
    color_mode: ansi.ColorMode,
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
        try ansi.writeStyled(writer, enable_ansi, color_mode, style, buf[0..pos]);
    } else {
        var sgr_state: ansi.StyledState = .{};
        try ansi.writeStyledRun(writer, enable_ansi, color_mode, &sgr_state, style, left);
        for (0..col_widths.len) |c| {
            const segment_width = col_widths[c] + 2;
            const glyph_count = segment_width / glyph_w;
            for (0..glyph_count) |_| {
                try ansi.writeStyledRun(writer, enable_ansi, color_mode, &sgr_state, style, border.horizontal);
            }
            if (c + 1 < col_widths.len) {
                try ansi.writeStyledRun(writer, enable_ansi, color_mode, &sgr_state, style, join);
            }
        }
        try ansi.writeStyledRun(writer, enable_ansi, color_mode, &sgr_state, style, right);
        try ansi.flushStyle(writer, &sgr_state);
    }
}
