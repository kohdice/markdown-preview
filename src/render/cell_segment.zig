const std = @import("std");
const ansi = @import("../term/ansi.zig");
const width = @import("../term/width.zig");

pub const CellRecord = struct {
    byte_start: u32,
    byte_end: u32,
    display_width: u32,
};

pub const CellSegmentBuilder = struct {
    allocator: std.mem.Allocator,
    parent_buf: *std.ArrayList(u8),
    segments: *std.ArrayList(CellRecord),

    parent_writer: ParentBufWriter,

    enable_ansi: bool,
    ambiguous: width.AmbiguousWidth,
    wrap_width: usize,

    sgr_state: ansi.StyledState,
    active_style: ansi.TextStyle,
    style_at_last_space: ansi.TextStyle,
    seg_byte_start: usize,
    col: usize,
    last_space_parent_pos: ?usize,
    col_before_last_space: usize,
    col_after_last_space: usize,
    suppress_next_emoji: bool,

    pub fn init(
        self: *CellSegmentBuilder,
        allocator: std.mem.Allocator,
        parent_buf: *std.ArrayList(u8),
        segments: *std.ArrayList(CellRecord),
    ) void {
        self.allocator = allocator;
        self.parent_buf = parent_buf;
        self.segments = segments;
        self.parent_writer.init(parent_buf, allocator);
        self.enable_ansi = false;
        self.ambiguous = .narrow;
        self.wrap_width = 0;
        self.sgr_state = .{};
        self.active_style = .{};
        self.style_at_last_space = .{};
        self.seg_byte_start = 0;
        self.col = 0;
        self.last_space_parent_pos = null;
        self.col_before_last_space = 0;
        self.col_after_last_space = 0;
        self.suppress_next_emoji = false;
    }

    pub fn beginCell(
        self: *CellSegmentBuilder,
        enable_ansi: bool,
        ambiguous: width.AmbiguousWidth,
        wrap_width: usize,
    ) void {
        self.enable_ansi = enable_ansi;
        self.ambiguous = ambiguous;
        self.wrap_width = wrap_width;
        self.sgr_state = .{};
        self.active_style = .{};
        self.style_at_last_space = .{};
        self.seg_byte_start = self.parent_buf.items.len;
        self.col = 0;
        self.last_space_parent_pos = null;
        self.col_before_last_space = 0;
        self.col_after_last_space = 0;
        self.suppress_next_emoji = false;
    }

    pub fn finishCell(self: *CellSegmentBuilder) !void {
        try ansi.flushStyle(&self.parent_writer.writer, &self.sgr_state);
        try self.parent_writer.writer.flush();

        try self.segments.append(self.allocator, try makeCellRecord(
            self.seg_byte_start,
            self.parent_buf.items.len,
            self.col,
        ));
    }

    pub fn writeStyled(
        self: *CellSegmentBuilder,
        style: ansi.TextStyle,
        text: []const u8,
    ) !void {
        self.active_style = style;
        try ansi.writeStyledRun(
            &self.parent_writer.writer,
            self.enable_ansi,
            &self.sgr_state,
            style,
            "",
        );
        try self.parent_writer.writer.flush();

        var i: usize = 0;
        while (i < text.len) {
            if (isStrippedControl(text[i])) {
                i += 1;
                continue;
            }

            const decoded = switch (width.nextCodepoint(text, i)) {
                .ok => |d| d,
                .invalid => {
                    try self.appendChar(text[i .. i + 1], 1);
                    i += 1;
                    continue;
                },
                .incomplete => break,
            };
            const len = decoded.len;
            const cp = decoded.cp;

            if (self.suppress_next_emoji) {
                self.suppress_next_emoji = false;
                if (width.isEmoji(cp)) {
                    try self.parent_buf.appendSlice(self.allocator, text[i..][0..len]);
                    i += len;
                    continue;
                }
            }
            if (cp == width.ZWJ) {
                self.suppress_next_emoji = true;
                try self.parent_buf.appendSlice(self.allocator, text[i..][0..len]);
                i += len;
                continue;
            }

            const cw = width.codepointWidth(cp, self.ambiguous);
            try self.appendChar(text[i..][0..len], cw);
            i += len;
        }
    }

    pub fn breakSegment(self: *CellSegmentBuilder) !void {
        try self.hardBreak();
    }

    fn appendChar(self: *CellSegmentBuilder, bytes: []const u8, cw: usize) !void {
        const is_space = bytes.len == 1 and bytes[0] == ' ';

        if (self.wrap_width > 0) {
            const next_col_before_wrap = try std.math.add(usize, self.col, cw);
            if (next_col_before_wrap > self.wrap_width) {
                if (is_space) {
                    try self.hardBreak();
                    return;
                }
                if (self.last_space_parent_pos) |space_pos| {
                    try self.softBreakAt(space_pos);
                } else {
                    try self.hardBreak();
                }
            }
        }

        if (is_space) {
            self.last_space_parent_pos = self.parent_buf.items.len;
            self.col_before_last_space = self.col;
            self.style_at_last_space = self.active_style;
        }
        try self.parent_buf.appendSlice(self.allocator, bytes);
        self.col = try std.math.add(usize, self.col, cw);
        if (is_space) self.col_after_last_space = self.col;
    }

    fn softBreakAt(self: *CellSegmentBuilder, space_parent_pos: usize) !void {
        if (!self.enable_ansi) {
            try self.segments.append(self.allocator, try makeCellRecord(
                self.seg_byte_start,
                space_parent_pos,
                self.col_before_last_space,
            ));

            self.seg_byte_start = space_parent_pos + 1;
            self.col = self.col - self.col_after_last_space;
            self.last_space_parent_pos = null;
            self.col_before_last_space = 0;
            self.col_after_last_space = 0;
            self.style_at_last_space = .{};
            return;
        }

        const tail_start: usize = @as(usize, space_parent_pos) + 1;
        const tail_end = self.parent_buf.items.len;
        const tail_len = tail_end - tail_start;

        var tail_stack: [1024]u8 = undefined;
        var tail_heap: ?[]u8 = null;
        defer if (tail_heap) |h| self.allocator.free(h);
        var tail_slice: []const u8 = &.{};
        if (tail_len > 0) {
            if (tail_len <= tail_stack.len) {
                @memcpy(tail_stack[0..tail_len], self.parent_buf.items[tail_start..tail_end]);
                tail_slice = tail_stack[0..tail_len];
            } else {
                const heap = try self.allocator.alloc(u8, tail_len);
                tail_heap = heap;
                @memcpy(heap, self.parent_buf.items[tail_start..tail_end]);
                tail_slice = heap;
            }
        }

        self.parent_buf.shrinkRetainingCapacity(space_parent_pos);

        try ansi.flushStyle(&self.parent_writer.writer, &self.sgr_state);
        try self.parent_writer.writer.flush();

        try self.segments.append(self.allocator, try makeCellRecord(
            self.seg_byte_start,
            self.parent_buf.items.len,
            self.col_before_last_space,
        ));

        self.seg_byte_start = self.parent_buf.items.len;

        try ansi.writeStyledRun(
            &self.parent_writer.writer,
            self.enable_ansi,
            &self.sgr_state,
            self.style_at_last_space,
            "",
        );
        try self.parent_writer.writer.flush();
        if (tail_len > 0) {
            try self.parent_buf.appendSlice(self.allocator, tail_slice);
        }

        self.sgr_state.current = if (self.enable_ansi and !self.active_style.isPlain())
            self.active_style
        else
            null;

        self.col = self.col - self.col_after_last_space;
        self.last_space_parent_pos = null;
        self.col_before_last_space = 0;
        self.col_after_last_space = 0;
        self.style_at_last_space = .{};
    }

    fn hardBreak(self: *CellSegmentBuilder) !void {
        try ansi.flushStyle(&self.parent_writer.writer, &self.sgr_state);
        try self.parent_writer.writer.flush();

        try self.segments.append(self.allocator, try makeCellRecord(
            self.seg_byte_start,
            self.parent_buf.items.len,
            self.col,
        ));

        self.seg_byte_start = self.parent_buf.items.len;
        self.col = 0;
        self.last_space_parent_pos = null;
        self.col_before_last_space = 0;
        self.col_after_last_space = 0;

        try ansi.writeStyledRun(
            &self.parent_writer.writer,
            self.enable_ansi,
            &self.sgr_state,
            self.active_style,
            "",
        );
        try self.parent_writer.writer.flush();
    }
};

fn isStrippedControl(byte: u8) bool {
    return byte < 0x20 or byte == 0x7F;
}

fn makeCellRecord(byte_start: usize, byte_end: usize, display_width: usize) error{Overflow}!CellRecord {
    return .{
        .byte_start = std.math.cast(u32, byte_start) orelse return error.Overflow,
        .byte_end = std.math.cast(u32, byte_end) orelse return error.Overflow,
        .display_width = std.math.cast(u32, display_width) orelse return error.Overflow,
    };
}

const ParentBufWriter = struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    stack_buf: [512]u8,
    writer: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.defaultFlush,
        .rebase = std.Io.Writer.failingRebase,
    };

    fn init(self: *ParentBufWriter, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) void {
        self.buf = buf;
        self.allocator = allocator;
        self.writer = .{
            .buffer = &self.stack_buf,
            .vtable = &vtable,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ParentBufWriter = @fieldParentPtr("writer", w);
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

const testing = std.testing;

test "CellSegmentBuilder emits one segment when text fits within wrap_width" {
    const allocator = testing.allocator;
    var parent: std.ArrayList(u8) = .empty;
    defer parent.deinit(allocator);
    var segments: std.ArrayList(CellRecord) = .empty;
    defer segments.deinit(allocator);

    var builder: CellSegmentBuilder = undefined;
    builder.init(allocator, &parent, &segments);
    builder.beginCell(false, .narrow, 80);
    try builder.writeStyled(.{}, "hello");
    try builder.finishCell();

    try testing.expectEqual(@as(usize, 1), segments.items.len);
    try testing.expectEqual(@as(u32, 0), segments.items[0].byte_start);
    try testing.expectEqual(@as(u32, 5), segments.items[0].byte_end);
    try testing.expectEqual(@as(u32, 5), segments.items[0].display_width);
    try testing.expectEqualStrings("hello", parent.items);
}

test "CellSegmentBuilder soft-breaks on a space and drops the space character" {
    const allocator = testing.allocator;
    var parent: std.ArrayList(u8) = .empty;
    defer parent.deinit(allocator);
    var segments: std.ArrayList(CellRecord) = .empty;
    defer segments.deinit(allocator);

    var builder: CellSegmentBuilder = undefined;
    builder.init(allocator, &parent, &segments);
    builder.beginCell(false, .narrow, 5);
    try builder.writeStyled(.{}, "hello world");
    try builder.finishCell();

    try testing.expectEqual(@as(usize, 2), segments.items.len);
    try testing.expectEqual(@as(u32, 5), segments.items[0].display_width);
    try testing.expectEqual(@as(u32, 5), segments.items[1].display_width);
    const seg0 = parent.items[segments.items[0].byte_start..segments.items[0].byte_end];
    const seg1 = parent.items[segments.items[1].byte_start..segments.items[1].byte_end];
    try testing.expectEqualStrings("hello", seg0);
    try testing.expectEqualStrings("world", seg1);
}

test "CellSegmentBuilder hard-breaks mid-Japanese when no space is available" {
    const allocator = testing.allocator;
    var parent: std.ArrayList(u8) = .empty;
    defer parent.deinit(allocator);
    var segments: std.ArrayList(CellRecord) = .empty;
    defer segments.deinit(allocator);

    var builder: CellSegmentBuilder = undefined;
    builder.init(allocator, &parent, &segments);
    builder.beginCell(false, .narrow, 4);
    try builder.writeStyled(.{}, "日本語テスト");
    try builder.finishCell();

    try testing.expectEqual(@as(usize, 3), segments.items.len);
    try testing.expectEqual(@as(u32, 4), segments.items[0].display_width);
    try testing.expectEqual(@as(u32, 4), segments.items[1].display_width);
    try testing.expectEqual(@as(u32, 4), segments.items[2].display_width);
    const seg0 = parent.items[segments.items[0].byte_start..segments.items[0].byte_end];
    const seg1 = parent.items[segments.items[1].byte_start..segments.items[1].byte_end];
    const seg2 = parent.items[segments.items[2].byte_start..segments.items[2].byte_end];
    try testing.expectEqualStrings("日本", seg0);
    try testing.expectEqualStrings("語テ", seg1);
    try testing.expectEqualStrings("スト", seg2);
}

test "CellSegmentBuilder strips C0 control bytes injected in cell text" {
    const allocator = testing.allocator;
    var parent: std.ArrayList(u8) = .empty;
    defer parent.deinit(allocator);
    var segments: std.ArrayList(CellRecord) = .empty;
    defer segments.deinit(allocator);

    var builder: CellSegmentBuilder = undefined;
    builder.init(allocator, &parent, &segments);
    builder.beginCell(false, .narrow, 80);
    try builder.writeStyled(.{}, "abc\x1b[31mxyz\x07end");
    try builder.finishCell();

    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, parent.items, "\x1b"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, parent.items, "\x07"));
}

test "CellSegmentBuilder soft-breaks at a space even when the tail exceeds the stack buffer" {
    const allocator = testing.allocator;
    var parent: std.ArrayList(u8) = .empty;
    defer parent.deinit(allocator);
    var segments: std.ArrayList(CellRecord) = .empty;
    defer segments.deinit(allocator);

    const tail_run: usize = 1500;
    const text = try allocator.alloc(u8, 2 + tail_run);
    defer allocator.free(text);
    text[0] = 'a';
    text[1] = ' ';
    @memset(text[2..], 'b');

    var builder: CellSegmentBuilder = undefined;
    builder.init(allocator, &parent, &segments);
    builder.beginCell(false, .narrow, 1200);
    try builder.writeStyled(.{}, text);
    try builder.finishCell();

    try testing.expect(segments.items.len >= 2);
    try testing.expectEqual(@as(u32, 1), segments.items[0].display_width);
    const seg0 = parent.items[segments.items[0].byte_start..segments.items[0].byte_end];
    try testing.expectEqualStrings("a", seg0);
}

test "CellSegmentBuilder strips tab and newline that would break the grid" {
    const allocator = testing.allocator;
    var parent: std.ArrayList(u8) = .empty;
    defer parent.deinit(allocator);
    var segments: std.ArrayList(CellRecord) = .empty;
    defer segments.deinit(allocator);

    var builder: CellSegmentBuilder = undefined;
    builder.init(allocator, &parent, &segments);
    builder.beginCell(false, .narrow, 80);
    try builder.writeStyled(.{}, "a\tb\nc");
    try builder.finishCell();

    try testing.expectEqualStrings("abc", parent.items);
    try testing.expectEqual(@as(usize, 1), segments.items.len);
    try testing.expectEqual(@as(u32, 3), segments.items[0].display_width);
}

test "CellSegmentBuilder reopens the style that was active at the soft-break space" {
    const allocator = testing.allocator;
    var parent: std.ArrayList(u8) = .empty;
    defer parent.deinit(allocator);
    var segments: std.ArrayList(CellRecord) = .empty;
    defer segments.deinit(allocator);

    const style_bold: ansi.TextStyle = .{ .bold = true };
    const style_italic: ansi.TextStyle = .{ .italic = true };

    var builder: CellSegmentBuilder = undefined;
    builder.init(allocator, &parent, &segments);
    builder.beginCell(true, .narrow, 3);
    try builder.writeStyled(style_bold, "a b");
    try builder.writeStyled(style_italic, "cd");
    try builder.finishCell();

    try testing.expect(segments.items.len >= 2);

    const seg1 = parent.items[segments.items[1].byte_start..segments.items[1].byte_end];
    const b_pos = std.mem.findScalar(u8, seg1, 'b').?;
    const before_b = seg1[0..b_pos];

    const bold_seq = "\x1b[1m";
    const italic_seq = "\x1b[3m";
    const last_bold = std.mem.findLast(u8, before_b, bold_seq);
    const last_italic = std.mem.findLast(u8, before_b, italic_seq);

    try testing.expect(last_bold != null);
    try testing.expect(last_italic == null or last_italic.? < last_bold.?);
}

test "CellSegmentBuilder reopens the active style after a split" {
    const allocator = testing.allocator;
    var parent: std.ArrayList(u8) = .empty;
    defer parent.deinit(allocator);
    var segments: std.ArrayList(CellRecord) = .empty;
    defer segments.deinit(allocator);

    var builder: CellSegmentBuilder = undefined;
    builder.init(allocator, &parent, &segments);
    builder.beginCell(true, .narrow, 5);
    const style: ansi.TextStyle = .{ .bold = true };
    try builder.writeStyled(style, "aaaa bbbb");
    try builder.finishCell();

    try testing.expectEqual(@as(usize, 2), segments.items.len);
    const seg0 = parent.items[segments.items[0].byte_start..segments.items[0].byte_end];
    const seg1 = parent.items[segments.items[1].byte_start..segments.items[1].byte_end];
    try testing.expect(std.mem.startsWith(u8, seg0, "\x1b[1m"));
    try testing.expect(std.mem.endsWith(u8, seg0, "\x1b[0m"));
    try testing.expect(std.mem.startsWith(u8, seg1, "\x1b[1m"));
    try testing.expect(std.mem.endsWith(u8, seg1, "\x1b[0m"));
}

test "makeCellRecord rejects values beyond u32" {
    const too_large = @as(usize, std.math.maxInt(u32)) + 1;
    try testing.expectError(
        error.Overflow,
        makeCellRecord(too_large, too_large, too_large),
    );
}
