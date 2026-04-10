const std = @import("std");
const ansi = @import("../term/ansi.zig");

pub const PrefixWriter = struct {
    parent: *std.io.Writer,
    at_line_start: bool,
    config: Config,
    writer: std.io.Writer,

    pub const Config = struct {
        indent: usize = 0,
        styled_prefix: []const u8 = "",
        style: ansi.TextStyle = .{},
        enable_ansi: bool = false,
        prefix_first_line: bool = true,
    };

    pub fn init(parent: *std.io.Writer, config: Config) PrefixWriter {
        return .{
            .parent = parent,
            .at_line_start = config.prefix_first_line,
            .config = config,
            .writer = .{
                .buffer = &.{},
                .vtable = &vtable,
            },
        };
    }

    pub fn finish(self: *PrefixWriter) std.io.Writer.Error!void {
        if (self.at_line_start) {
            try self.emitPrefix();
            self.at_line_start = false;
        }
    }

    const vtable: std.io.Writer.VTable = .{
        .drain = drain,
        .flush = std.io.Writer.noopFlush,
        .rebase = std.io.Writer.failingRebase,
    };

    fn drain(w: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
        const self: *PrefixWriter = @fieldParentPtr("writer", w);
        var total: usize = 0;

        for (data, 0..) |slice, idx| {
            const repeat: usize = if (idx == data.len - 1) splat else 1;
            for (0..repeat) |_| {
                total += try self.processSlice(slice);
            }
        }

        return total;
    }

    fn processSlice(self: *PrefixWriter, bytes: []const u8) std.io.Writer.Error!usize {
        var pos: usize = 0;

        while (pos < bytes.len) {
            if (self.at_line_start) {
                try self.emitPrefix();
                self.at_line_start = false;
            }

            if (std.mem.indexOfScalarPos(u8, bytes, pos, '\n')) |nl| {
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

    fn emitPrefix(self: *PrefixWriter) std.io.Writer.Error!void {
        if (self.config.indent > 0)
            try self.parent.splatByteAll(' ', self.config.indent);

        if (self.config.styled_prefix.len > 0)
            try ansi.writeStyled(self.parent, self.config.enable_ansi, self.config.style, self.config.styled_prefix);
    }
};

const testing = std.testing;

fn collectOutput(f: anytype) ![]u8 {
    const allocator = testing.allocator;
    var buf: std.io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();
    try f(&buf.writer);
    var list = buf.toArrayList();
    defer buf.deinit();
    return list.toOwnedSlice(allocator);
}

test "prefix every line with indent" {
    const allocator = testing.allocator;
    const result = try collectOutput(struct {
        fn run(w: *std.io.Writer) !void {
            var pw = PrefixWriter.init(w, .{ .indent = 2 });
            try pw.writer.writeAll("a\nb\nc");
        }
    }.run);
    defer allocator.free(result);
    try testing.expectEqualStrings("  a\n  b\n  c", result);
}

test "empty line keeps prefix" {
    const allocator = testing.allocator;
    const result = try collectOutput(struct {
        fn run(w: *std.io.Writer) !void {
            var pw = PrefixWriter.init(w, .{ .indent = 2 });
            try pw.writer.writeAll("a\n\nb");
        }
    }.run);
    defer allocator.free(result);
    try testing.expectEqualStrings("  a\n  \n  b", result);
}

test "trailing newline emits prefix after finish" {
    const allocator = testing.allocator;
    const result = try collectOutput(struct {
        fn run(w: *std.io.Writer) !void {
            var pw = PrefixWriter.init(w, .{ .indent = 2 });
            try pw.writer.writeAll("a\n");
            try pw.finish();
        }
    }.run);
    defer allocator.free(result);
    try testing.expectEqualStrings("  a\n  ", result);
}

test "trailing newline without finish omits trailing prefix" {
    const allocator = testing.allocator;
    const result = try collectOutput(struct {
        fn run(w: *std.io.Writer) !void {
            var pw = PrefixWriter.init(w, .{ .indent = 2 });
            try pw.writer.writeAll("a\n");
        }
    }.run);
    defer allocator.free(result);
    try testing.expectEqualStrings("  a\n", result);
}

test "prefix_first_line false skips first line" {
    const allocator = testing.allocator;
    const result = try collectOutput(struct {
        fn run(w: *std.io.Writer) !void {
            var pw = PrefixWriter.init(w, .{ .indent = 3, .prefix_first_line = false });
            try pw.writer.writeAll("a\nb\nc");
        }
    }.run);
    defer allocator.free(result);
    try testing.expectEqualStrings("a\n   b\n   c", result);
}

test "prefix_first_line false with empty line" {
    const allocator = testing.allocator;
    const result = try collectOutput(struct {
        fn run(w: *std.io.Writer) !void {
            var pw = PrefixWriter.init(w, .{ .indent = 2, .prefix_first_line = false });
            try pw.writer.writeAll("a\n\nb");
        }
    }.run);
    defer allocator.free(result);
    try testing.expectEqualStrings("a\n  \n  b", result);
}

test "styled prefix without ANSI" {
    const allocator = testing.allocator;
    const result = try collectOutput(struct {
        fn run(w: *std.io.Writer) !void {
            var pw = PrefixWriter.init(w, .{
                .indent = 1,
                .styled_prefix = "| ",
                .enable_ansi = false,
            });
            try pw.writer.writeAll("x\ny");
        }
    }.run);
    defer allocator.free(result);
    try testing.expectEqualStrings(" | x\n | y", result);
}

test "empty write does not emit prefix" {
    const allocator = testing.allocator;
    const result = try collectOutput(struct {
        fn run(w: *std.io.Writer) !void {
            var pw = PrefixWriter.init(w, .{ .indent = 2 });
            try pw.writer.writeAll("");
            try pw.writer.writeAll("a");
        }
    }.run);
    defer allocator.free(result);
    try testing.expectEqualStrings("  a", result);
}

test "writeByte triggers prefix" {
    const allocator = testing.allocator;
    const result = try collectOutput(struct {
        fn run(w: *std.io.Writer) !void {
            var pw = PrefixWriter.init(w, .{ .indent = 1 });
            try pw.writer.writeByte('a');
            try pw.writer.writeByte('\n');
            try pw.writer.writeByte('b');
        }
    }.run);
    defer allocator.free(result);
    try testing.expectEqualStrings(" a\n b", result);
}

test "splatByteAll triggers prefix" {
    const allocator = testing.allocator;
    const result = try collectOutput(struct {
        fn run(w: *std.io.Writer) !void {
            var pw = PrefixWriter.init(w, .{ .indent = 2 });
            try pw.writer.splatByteAll('x', 3);
        }
    }.run);
    defer allocator.free(result);
    try testing.expectEqualStrings("  xxx", result);
}

test "nested prefix writers" {
    const allocator = testing.allocator;
    const result = try collectOutput(struct {
        fn run(w: *std.io.Writer) !void {
            var outer = PrefixWriter.init(w, .{ .indent = 2 });
            var inner = PrefixWriter.init(&outer.writer, .{ .indent = 3 });
            try inner.writer.writeAll("a\nb");
        }
    }.run);
    defer allocator.free(result);
    try testing.expectEqualStrings("     a\n     b", result);
}
