const std = @import("std");
const ansi = @import("../term/ansi.zig");
const ast = @import("../ast.zig");
const theme = @import("../term/theme.zig");
const width = @import("../term/width.zig");
const render_inline = @import("inline.zig");
const render_context = @import("context.zig");
const cell_segment = @import("cell_segment.zig");

const RenderContext = render_context.RenderContext;
const CellRecord = cell_segment.CellRecord;
const CellSegmentBuilder = cell_segment.CellSegmentBuilder;

pub const min_col_width = 3;
const border_line_stack_buf_size: usize = 2048;
const fit_column_frozen_stack_cap: usize = 256;
const scratch_retained_bytes_limit: usize = 4 * 1024 * 1024;

pub fn fitColumnWidths(
    allocator: std.mem.Allocator,
    col_widths: []usize,
    wrap_width: ?usize,
    ambiguous_width: width.AmbiguousWidth,
) std.mem.Allocator.Error!void {
    for (col_widths) |*w| {
        w.* = normalizeColumnWidth(w.*, ambiguous_width);
    }

    const wrap_w = wrap_width orelse return;
    const n = col_widths.len;
    if (n == 0) return;

    const frame_w = frameWidth(n, ambiguous_width) orelse return;
    const normalized_min = normalizeColumnWidth(min_col_width, ambiguous_width);
    const min_total = std.math.mul(usize, n, normalized_min) catch return;
    const required = std.math.add(usize, frame_w, min_total) catch return;
    if (wrap_w < required) return;

    const available = wrap_w - frame_w;
    var total: usize = 0;
    for (col_widths) |w| {
        total = std.math.add(usize, total, w) catch return;
    }
    if (total <= available) return;

    const q: usize = if (ambiguous_width == .wide) 2 else 1;
    const available_q = available / q;

    var frozen_stack: [fit_column_frozen_stack_cap]bool = undefined;
    var frozen_heap: ?[]bool = null;
    defer if (frozen_heap) |h| allocator.free(h);
    const frozen: []bool = if (n <= frozen_stack.len)
        frozen_stack[0..n]
    else blk: {
        const heap = try allocator.alloc(bool, n);
        frozen_heap = heap;
        break :blk heap;
    };
    for (frozen) |*f| f.* = false;

    var remaining_q = available_q;
    while (true) {
        var wide_count: usize = 0;
        for (0..n) |i| {
            if (!frozen[i]) wide_count += 1;
        }
        if (wide_count == 0) break;

        const fair_q = remaining_q / wide_count;

        var new_frozen = false;
        for (0..n) |i| {
            if (frozen[i]) continue;
            const natural_q = col_widths[i] / q;
            if (natural_q <= fair_q) {
                frozen[i] = true;
                remaining_q -= natural_q;
                new_frozen = true;
            }
        }
        if (new_frozen) continue;

        var leftover_q = remaining_q - fair_q * wide_count;
        for (0..n) |i| {
            if (frozen[i]) continue;
            var target_q = fair_q;
            if (leftover_q > 0) {
                target_q += 1;
                leftover_q -= 1;
            }
            col_widths[i] = target_q * q;
        }
        break;
    }
}

fn normalizeColumnWidth(w: usize, ambiguous_width: width.AmbiguousWidth) usize {
    const clamped = @max(w, min_col_width);
    if (ambiguous_width == .wide and clamped % 2 != 0) return std.math.add(usize, clamped, 1) catch clamped;
    return clamped;
}

fn frameWidth(col_count: usize, ambiguous_width: width.AmbiguousWidth) ?usize {
    if (col_count == 0) return 0;
    const row_open_w = width.displayWidth(border.vertical ++ border.cell_pad, ambiguous_width);
    const cell_separator_w = width.displayWidth(border.cell_pad ++ border.vertical ++ border.cell_pad, ambiguous_width);
    const row_close_w = width.displayWidth(border.cell_pad ++ border.vertical, ambiguous_width);
    const separators = std.math.mul(usize, col_count - 1, cell_separator_w) catch return null;
    const open_and_separators = std.math.add(usize, row_open_w, separators) catch return null;
    return std.math.add(usize, open_and_separators, row_close_w) catch return null;
}

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
    col_widths: std.ArrayList(usize) = .empty,
    row_offsets: std.ArrayList(usize) = .empty,
    bytes_buf: std.ArrayList(u8) = .empty,
    cell_segments: std.ArrayList(CellRecord) = .empty,
    cell_seg_offsets: std.ArrayList(u32) = .empty,

    pub fn beginTable(self: *TableScratch, allocator: std.mem.Allocator) void {
        self.reset(allocator);
    }

    pub fn reset(self: *TableScratch, allocator: std.mem.Allocator) void {
        clearRetainingBounded(usize, &self.col_widths, allocator, scratch_retained_bytes_limit);
        clearRetainingBounded(usize, &self.row_offsets, allocator, scratch_retained_bytes_limit);
        clearRetainingBounded(u8, &self.bytes_buf, allocator, scratch_retained_bytes_limit);
        clearRetainingBounded(CellRecord, &self.cell_segments, allocator, scratch_retained_bytes_limit);
        clearRetainingBounded(u32, &self.cell_seg_offsets, allocator, scratch_retained_bytes_limit);
    }

    pub fn deinit(self: *TableScratch, allocator: std.mem.Allocator) void {
        self.col_widths.deinit(allocator);
        self.row_offsets.deinit(allocator);
        self.bytes_buf.deinit(allocator);
        self.cell_segments.deinit(allocator);
        self.cell_seg_offsets.deinit(allocator);
        self.* = .{};
    }
};

fn clearRetainingBounded(
    comptime T: type,
    list: *std.ArrayList(T),
    allocator: std.mem.Allocator,
    byte_limit: usize,
) void {
    if (@sizeOf(T) != 0 and list.capacity > byte_limit / @sizeOf(T)) {
        list.clearAndFree(allocator);
    } else {
        list.clearRetainingCapacity();
    }
}

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

pub fn writeTable(
    ctx: *const RenderContext,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    scratch: *TableScratch,
    table: ast.Table,
    placement: TablePlacement,
    wrap_width: ?usize,
) !void {
    const col_count = table.alignments.len;

    scratch.beginTable(allocator);
    try scratch.col_widths.appendNTimes(allocator, 0, col_count);

    const cell_fg = placement.cellColor(ctx.palette);
    const header_style: ansi.TextStyle = .{ .fg = cell_fg, .bold = true };
    const body_style: ansi.TextStyle = .{ .fg = cell_fg };

    var builder: CellSegmentBuilder = undefined;
    builder.init(allocator, &scratch.bytes_buf, &scratch.cell_segments);

    try measureCells(
        ctx,
        &builder,
        scratch,
        scratch.col_widths.items,
        table,
        header_style,
        body_style,
        col_count,
    );

    scratch.bytes_buf.clearRetainingCapacity();
    scratch.cell_segments.clearRetainingCapacity();
    try scratch.cell_seg_offsets.append(allocator, 0);

    try fitColumnWidths(allocator, scratch.col_widths.items, wrap_width, ctx.ambiguous_width);

    for (0..col_count) |c| {
        const col_w = scratch.col_widths.items[c];
        builder.beginCell(ctx.enable_ansi, ctx.ambiguous_width, col_w);
        if (c < table.header.len) {
            try render_inline.writeSegmentedInlineChain(
                ctx,
                &builder,
                table.header[c].children,
                header_style,
            );
        }
        try builder.finishCell();
        try scratch.cell_seg_offsets.append(allocator, @intCast(scratch.cell_segments.items.len));
    }

    try scratch.row_offsets.append(allocator, col_count);

    for (table.rows) |row| {
        const cached_len = @min(row.len, col_count);
        for (row[0..cached_len], 0..) |cell, ci| {
            const col_w = scratch.col_widths.items[ci];
            builder.beginCell(ctx.enable_ansi, ctx.ambiguous_width, col_w);
            try render_inline.writeSegmentedInlineChain(
                ctx,
                &builder,
                cell.children,
                body_style,
            );
            try builder.finishCell();
            try scratch.cell_seg_offsets.append(allocator, @intCast(scratch.cell_segments.items.len));
        }
        try scratch.row_offsets.append(allocator, scratch.cell_seg_offsets.items.len - 1);
    }

    const col_widths = scratch.col_widths.items;
    const bytes = scratch.bytes_buf.items;
    const segments = scratch.cell_segments.items;
    const seg_offsets = scratch.cell_seg_offsets.items;

    try writeBorder(writer, col_widths, .top, ctx.enable_ansi, ctx.ambiguous_width, ctx.palette);
    try writer.writeByte('\n');

    try writeRowFromScratch(
        ctx,
        writer,
        bytes,
        segments,
        seg_offsets,
        0,
        col_count,
        col_widths,
        table.alignments,
    );
    try writer.writeByte('\n');

    try writeBorder(writer, col_widths, .middle, ctx.enable_ansi, ctx.ambiguous_width, ctx.palette);

    for (0..table.rows.len) |i| {
        const row_start = scratch.row_offsets.items[i];
        const row_end = scratch.row_offsets.items[i + 1];
        try writer.writeByte('\n');
        try writeRowFromScratch(
            ctx,
            writer,
            bytes,
            segments,
            seg_offsets,
            row_start,
            row_end - row_start,
            col_widths,
            table.alignments,
        );

        if (i + 1 < table.rows.len) {
            try writer.writeByte('\n');
            try writeBorder(writer, col_widths, .middle, ctx.enable_ansi, ctx.ambiguous_width, ctx.palette);
        }
    }

    try writer.writeByte('\n');
    try writeBorder(writer, col_widths, .bottom, ctx.enable_ansi, ctx.ambiguous_width, ctx.palette);
}

fn measureCells(
    ctx: *const RenderContext,
    builder: *CellSegmentBuilder,
    scratch: *TableScratch,
    col_widths: []usize,
    table: ast.Table,
    header_style: ansi.TextStyle,
    body_style: ansi.TextStyle,
    col_count: usize,
) !void {
    const huge_wrap: usize = std.math.maxInt(usize);

    for (0..col_count) |c| {
        if (c < table.header.len) {
            const w = try measureOneCell(
                ctx,
                builder,
                scratch,
                table.header[c].children,
                header_style,
                huge_wrap,
            );
            col_widths[c] = @max(col_widths[c], w);
        }
    }
    for (table.rows) |row| {
        const cached_len = @min(row.len, col_count);
        for (row[0..cached_len], 0..) |cell, ci| {
            const w = try measureOneCell(
                ctx,
                builder,
                scratch,
                cell.children,
                body_style,
                huge_wrap,
            );
            col_widths[ci] = @max(col_widths[ci], w);
        }
    }
}

fn measureOneCell(
    ctx: *const RenderContext,
    builder: *CellSegmentBuilder,
    scratch: *TableScratch,
    first: ast.InlineRef,
    base_style: ansi.TextStyle,
    wrap_width: usize,
) !usize {
    scratch.bytes_buf.clearRetainingCapacity();
    scratch.cell_segments.clearRetainingCapacity();
    builder.beginCell(false, ctx.ambiguous_width, wrap_width);
    try render_inline.writeSegmentedInlineChain(ctx, builder, first, base_style);
    try builder.finishCell();
    var maxw: usize = 0;
    for (scratch.cell_segments.items) |r| maxw = @max(maxw, r.display_width);
    return maxw;
}

fn writeRowFromScratch(
    ctx: *const RenderContext,
    writer: *std.Io.Writer,
    bytes: []const u8,
    segments: []const CellRecord,
    seg_offsets: []const u32,
    row_cell_start: usize,
    row_cell_count: usize,
    col_widths: []const usize,
    alignments: []const ast.Alignment,
) !void {
    const bar_style: ansi.TextStyle = .{ .fg = ctx.palette.muted };

    const row_open = border.vertical ++ border.cell_pad;
    const cell_separator = border.cell_pad ++ border.vertical ++ border.cell_pad;
    const row_close = border.cell_pad ++ border.vertical;

    var row_height: usize = 1;
    for (0..row_cell_count) |c| {
        const k = row_cell_start + c;
        const seg_count = seg_offsets[k + 1] - seg_offsets[k];
        if (seg_count > row_height) row_height = seg_count;
    }

    for (0..row_height) |line_idx| {
        try ansi.writeStyled(writer, ctx.enable_ansi, bar_style, row_open);
        for (0..col_widths.len) |c| {
            var rec: ?CellRecord = null;
            if (c < row_cell_count) {
                const k = row_cell_start + c;
                const seg_start = seg_offsets[k];
                const seg_end = seg_offsets[k + 1];
                if (line_idx < seg_end - seg_start) {
                    rec = segments[seg_start + line_idx];
                }
            }

            const cell_width: usize = if (rec) |r| r.display_width else 0;
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
            if (rec) |r| {
                try writer.writeAll(bytes[r.byte_start..r.byte_end]);
            }
            try writer.splatByteAll(' ', right_pad);

            if (c + 1 < col_widths.len) {
                try ansi.writeStyled(writer, ctx.enable_ansi, bar_style, cell_separator);
            }
        }
        try ansi.writeStyled(writer, ctx.enable_ansi, bar_style, row_close);

        if (line_idx + 1 < row_height) try writer.writeByte('\n');
    }
}

fn writeBorder(
    writer: *std.Io.Writer,
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
        var sgr_state: ansi.StyledState = .{};
        try ansi.writeStyledRun(writer, enable_ansi, &sgr_state, style, left);
        for (0..col_widths.len) |c| {
            const segment_width = col_widths[c] + 2;
            const glyph_count = segment_width / glyph_w;
            for (0..glyph_count) |_| {
                try ansi.writeStyledRun(writer, enable_ansi, &sgr_state, style, border.horizontal);
            }
            if (c + 1 < col_widths.len) {
                try ansi.writeStyledRun(writer, enable_ansi, &sgr_state, style, join);
            }
        }
        try ansi.writeStyledRun(writer, enable_ansi, &sgr_state, style, right);
        try ansi.flushStyle(writer, &sgr_state);
    }
}
