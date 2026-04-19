const std = @import("std");

pub const RenderBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    line_offsets: std.ArrayListUnmanaged(usize) = .empty,
    pending_newline: bool = false,
    writer: std.io.Writer,

    const vtable: std.io.Writer.VTable = .{
        .drain = drain,
        .flush = flushFn,
        .rebase = std.io.Writer.failingRebase,
    };

    pub fn init(allocator: std.mem.Allocator) RenderBuffer {
        return .{
            .allocator = allocator,
            .writer = .{
                .buffer = &.{},
                .vtable = &vtable,
            },
        };
    }

    pub fn deinit(self: *RenderBuffer) void {
        self.bytes.deinit(self.allocator);
        self.line_offsets.deinit(self.allocator);
    }

    pub fn reset(self: *RenderBuffer) void {
        self.bytes.clearRetainingCapacity();
        self.line_offsets.clearRetainingCapacity();
        self.pending_newline = false;
    }

    pub fn buffered(self: *const RenderBuffer) []const u8 {
        return self.bytes.items;
    }

    pub fn lineOffsets(self: *const RenderBuffer) []const usize {
        return self.line_offsets.items;
    }

    pub fn totalLines(self: *const RenderBuffer) usize {
        return self.line_offsets.items.len;
    }

    fn drain(w: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
        const self: *RenderBuffer = @fieldParentPtr("writer", w);
        var total: usize = 0;
        for (data, 0..) |slice, idx| {
            const repeat: usize = if (idx == data.len - 1) splat else 1;
            for (0..repeat) |_| {
                self.appendSlice(slice) catch return error.WriteFailed;
                total += slice.len;
            }
        }
        return total;
    }

    fn flushFn(w: *std.io.Writer) std.io.Writer.Error!void {
        _ = w;
    }

    fn appendSlice(self: *RenderBuffer, slice: []const u8) !void {
        if (slice.len == 0) return;
        if (slice.len == 1) return self.appendByte(slice[0]);

        const base = self.bytes.items.len;

        if (base == 0 and self.line_offsets.items.len == 0) {
            try self.line_offsets.append(self.allocator, 0);
        }

        if (self.pending_newline) {
            try self.line_offsets.append(self.allocator, base);
            self.pending_newline = false;
        }

        try self.bytes.appendSlice(self.allocator, slice);

        var pos: usize = 0;
        while (std.mem.indexOfScalarPos(u8, slice, pos, '\n')) |nl| {
            if (nl + 1 < slice.len) {
                try self.line_offsets.append(self.allocator, base + nl + 1);
            } else {
                self.pending_newline = true;
            }
            pos = nl + 1;
        }
    }

    inline fn appendByte(self: *RenderBuffer, byte: u8) !void {
        if (self.pending_newline) {
            try self.line_offsets.append(self.allocator, self.bytes.items.len);
            self.pending_newline = false;
        }
        if (self.bytes.items.len == 0 and self.line_offsets.items.len == 0) {
            try self.line_offsets.append(self.allocator, 0);
        }
        try self.bytes.append(self.allocator, byte);
        if (byte == '\n') self.pending_newline = true;
    }
};

test "RenderBuffer tracks offsets for two complete lines" {
    var rb = RenderBuffer.init(std.testing.allocator);
    defer rb.deinit();

    try rb.writer.writeAll("abc\ndef\n");
    try rb.writer.flush();

    try std.testing.expectEqualStrings("abc\ndef\n", rb.buffered());
    try std.testing.expectEqual(@as(usize, 2), rb.totalLines());
    try std.testing.expectEqual(@as(usize, 0), rb.lineOffsets()[0]);
    try std.testing.expectEqual(@as(usize, 4), rb.lineOffsets()[1]);
}

test "RenderBuffer treats a single line without newline as one line" {
    var rb = RenderBuffer.init(std.testing.allocator);
    defer rb.deinit();

    try rb.writer.writeAll("abc");
    try rb.writer.flush();

    try std.testing.expectEqual(@as(usize, 1), rb.totalLines());
    try std.testing.expectEqual(@as(usize, 0), rb.lineOffsets()[0]);
}

test "RenderBuffer reports no lines for empty input" {
    var rb = RenderBuffer.init(std.testing.allocator);
    defer rb.deinit();

    try std.testing.expectEqual(@as(usize, 0), rb.totalLines());
    try std.testing.expectEqualStrings("", rb.buffered());
}

test "RenderBuffer treats a single newline as one line" {
    var rb = RenderBuffer.init(std.testing.allocator);
    defer rb.deinit();

    try rb.writer.writeAll("\n");
    try rb.writer.flush();

    try std.testing.expectEqual(@as(usize, 1), rb.totalLines());
    try std.testing.expectEqual(@as(usize, 0), rb.lineOffsets()[0]);
}

test "RenderBuffer treats three lines with trailing newline as three lines" {
    var rb = RenderBuffer.init(std.testing.allocator);
    defer rb.deinit();

    try rb.writer.writeAll("a\nb\nc\n");
    try rb.writer.flush();

    try std.testing.expectEqual(@as(usize, 3), rb.totalLines());
    try std.testing.expectEqual(@as(usize, 0), rb.lineOffsets()[0]);
    try std.testing.expectEqual(@as(usize, 2), rb.lineOffsets()[1]);
    try std.testing.expectEqual(@as(usize, 4), rb.lineOffsets()[2]);
}

test "RenderBuffer reset retains capacity and reproduces offsets" {
    var rb = RenderBuffer.init(std.testing.allocator);
    defer rb.deinit();

    try rb.writer.writeAll("alpha\nbeta\n");
    try rb.writer.flush();

    rb.reset();
    try std.testing.expectEqual(@as(usize, 0), rb.totalLines());
    try std.testing.expectEqualStrings("", rb.buffered());

    try rb.writer.writeAll("alpha\nbeta\n");
    try rb.writer.flush();

    try std.testing.expectEqual(@as(usize, 2), rb.totalLines());
    try std.testing.expectEqual(@as(usize, 0), rb.lineOffsets()[0]);
    try std.testing.expectEqual(@as(usize, 6), rb.lineOffsets()[1]);
}
