const std = @import("std");

pub const PrefixStack = struct {
    allocator: std.mem.Allocator,
    segments: std.ArrayList(Segment) = .empty,

    pub const Segment = struct {
        indent: usize = 0,
        marker: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator) PrefixStack {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PrefixStack) void {
        self.segments.deinit(self.allocator);
    }

    pub fn push(self: *PrefixStack, segment: Segment) !void {
        try self.segments.append(self.allocator, segment);
    }

    pub fn pop(self: *PrefixStack) void {
        _ = self.segments.pop();
    }

    pub fn isEmpty(self: *const PrefixStack) bool {
        return self.segments.items.len == 0;
    }

    pub fn emit(self: *const PrefixStack, writer: *std.Io.Writer) !void {
        for (self.segments.items) |seg| {
            if (seg.indent > 0) try writer.splatByteAll(' ', seg.indent);
            if (seg.marker.len > 0) try writer.writeAll(seg.marker);
        }
    }
};

pub const PrefixWriter = struct {
    parent: *std.Io.Writer,
    stack: *const PrefixStack,
    at_line_start: bool,
    buf: [recommended_buffer_size]u8,
    writer: std.Io.Writer,

    pub const recommended_buffer_size = 512;

    pub fn init(
        self: *PrefixWriter,
        parent: *std.Io.Writer,
        stack: *const PrefixStack,
    ) void {
        self.* = .{
            .parent = parent,
            .stack = stack,
            .at_line_start = true,
            .buf = undefined,
            .writer = .{
                .buffer = &self.buf,
                .vtable = &vtable,
            },
        };
    }

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.defaultFlush,
        .rebase = std.Io.Writer.failingRebase,
    };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *PrefixWriter = @fieldParentPtr("writer", w);

        const buffered = w.buffered();
        if (buffered.len > 0) {
            _ = try self.processSlice(buffered);
            w.end = 0;
        }

        var total: usize = 0;
        for (data, 0..) |slice, idx| {
            const repeat: usize = if (idx == data.len - 1) splat else 1;
            for (0..repeat) |_| {
                total += try self.processSlice(slice);
            }
        }

        return total;
    }

    fn processSlice(self: *PrefixWriter, bytes: []const u8) std.Io.Writer.Error!usize {
        var pos: usize = 0;

        while (pos < bytes.len) {
            if (self.at_line_start) {
                if (!self.stack.isEmpty()) try self.stack.emit(self.parent);
                self.at_line_start = false;
            }

            if (std.mem.findScalarPos(u8, bytes, pos, '\n')) |nl| {
                try self.parent.writeAll(bytes[pos .. nl + 1]);
                pos = nl + 1;
                self.at_line_start = true;
            } else {
                try self.parent.writeAll(bytes[pos..]);
                pos = bytes.len;
            }
        }

        return bytes.len;
    }
};

const testing = std.testing;

test "prefix stack push/pop changes emitted prefix" {
    const allocator = testing.allocator;
    var stack: PrefixStack = .init(allocator);
    defer stack.deinit();

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    var pw: PrefixWriter = undefined;
    pw.init(&buf.writer, &stack);

    try stack.push(.{ .marker = "> " });
    try pw.writer.writeAll("a\nb\n");
    try pw.writer.flush();
    stack.pop();
    try pw.writer.writeAll("c\n");
    try pw.writer.flush();

    try testing.expectEqualStrings("> a\n> b\nc\n", buf.written());
}

test "empty stack produces no prefix" {
    const allocator = testing.allocator;
    var stack: PrefixStack = .init(allocator);
    defer stack.deinit();

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    var pw: PrefixWriter = undefined;
    pw.init(&buf.writer, &stack);

    try pw.writer.writeAll("a\nb\n");
    try pw.writer.flush();

    try testing.expectEqualStrings("a\nb\n", buf.written());
}

test "nested prefixes compose via stack" {
    const allocator = testing.allocator;
    var stack: PrefixStack = .init(allocator);
    defer stack.deinit();

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    var pw: PrefixWriter = undefined;
    pw.init(&buf.writer, &stack);

    try stack.push(.{ .indent = 2 });
    try stack.push(.{ .marker = "> " });
    try pw.writer.writeAll("a\nb\n");
    try pw.writer.flush();
    stack.pop();
    stack.pop();
    try pw.writer.writeAll("c\n");
    try pw.writer.flush();

    try testing.expectEqualStrings("  > a\n  > b\nc\n", buf.written());
}

test "push mid-line does not retroactively prefix first line" {
    const allocator = testing.allocator;
    var stack: PrefixStack = .init(allocator);
    defer stack.deinit();

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    var pw: PrefixWriter = undefined;
    pw.init(&buf.writer, &stack);

    try pw.writer.writeAll("head ");
    try pw.writer.flush();
    try stack.push(.{ .indent = 2 });
    try pw.writer.writeAll("tail\nwrapped\n");
    try pw.writer.flush();
    stack.pop();

    try testing.expectEqualStrings("head tail\n  wrapped\n", buf.written());
}

test "styled prefix bytes pass through verbatim" {
    const allocator = testing.allocator;
    var stack: PrefixStack = .init(allocator);
    defer stack.deinit();

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    var pw: PrefixWriter = undefined;
    pw.init(&buf.writer, &stack);

    const gutter = "\x1b[2m| \x1b[0m";
    try stack.push(.{ .marker = gutter });
    try pw.writer.writeAll("x\ny");
    try pw.writer.flush();
    stack.pop();

    try testing.expectEqualStrings("\x1b[2m| \x1b[0mx\n\x1b[2m| \x1b[0my", buf.written());
}

test "writeByte triggers prefix" {
    const allocator = testing.allocator;
    var stack: PrefixStack = .init(allocator);
    defer stack.deinit();

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    var pw: PrefixWriter = undefined;
    pw.init(&buf.writer, &stack);

    try stack.push(.{ .indent = 1 });
    try pw.writer.writeByte('a');
    try pw.writer.writeByte('\n');
    try pw.writer.writeByte('b');
    try pw.writer.flush();
    stack.pop();

    try testing.expectEqualStrings(" a\n b", buf.written());
}

test "splatByteAll after newline receives prefix" {
    const allocator = testing.allocator;
    var stack: PrefixStack = .init(allocator);
    defer stack.deinit();

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    var pw: PrefixWriter = undefined;
    pw.init(&buf.writer, &stack);

    try stack.push(.{ .indent = 2 });
    try pw.writer.splatByteAll('x', 3);
    try pw.writer.flush();
    stack.pop();

    try testing.expectEqualStrings("  xxx", buf.written());
}

test "empty writes do not emit prefix" {
    const allocator = testing.allocator;
    var stack: PrefixStack = .init(allocator);
    defer stack.deinit();

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    var pw: PrefixWriter = undefined;
    pw.init(&buf.writer, &stack);

    try stack.push(.{ .indent = 2 });
    try pw.writer.writeAll("");
    try pw.writer.writeAll("a");
    try pw.writer.flush();
    stack.pop();

    try testing.expectEqualStrings("  a", buf.written());
}
