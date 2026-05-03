const std = @import("std");
const input = @import("input.zig");
const render_buffer_mod = @import("render_buffer.zig");
const memory_policy = @import("memory_policy");

const retained_row_hash_bytes_limit: usize = 64 * 1024;

pub fn applyAction(action: input.KeyAction, scroll_offset: *usize, total_lines: usize, term_rows: usize) bool {
    const content_rows = if (term_rows > 1) term_rows - 1 else 1;
    const max_offset = if (total_lines > content_rows) total_lines - content_rows else 0;

    switch (action) {
        .none => {},
        .quit => return false,
        .scroll_up => {
            if (scroll_offset.* > 0) {
                scroll_offset.* -= 1;
                return true;
            }
        },
        .scroll_down => {
            if (scroll_offset.* < max_offset) {
                scroll_offset.* += 1;
                return true;
            }
        },
        .page_up => {
            const page = if (content_rows > 1) content_rows - 1 else 1;
            const new = if (scroll_offset.* > page) scroll_offset.* - page else 0;
            if (new != scroll_offset.*) {
                scroll_offset.* = new;
                return true;
            }
        },
        .page_down => {
            const page = if (content_rows > 1) content_rows - 1 else 1;
            const new = @min(scroll_offset.* + page, max_offset);
            if (new != scroll_offset.*) {
                scroll_offset.* = new;
                return true;
            }
        },
        .scroll_top => {
            if (scroll_offset.* != 0) {
                scroll_offset.* = 0;
                return true;
            }
        },
        .scroll_bottom => {
            if (scroll_offset.* != max_offset) {
                scroll_offset.* = max_offset;
                return true;
            }
        },
    }
    return false;
}

pub const Pager = struct {
    allocator: std.mem.Allocator,
    prev_row_hashes: std.ArrayList(u64) = .empty,
    curr_row_hashes: std.ArrayList(u64) = .empty,
    prev_scroll: ?usize = null,
    prev_enable_ansi: ?bool = null,
    prev_content_rows: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) Pager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Pager) void {
        self.prev_row_hashes.deinit(self.allocator);
        self.curr_row_hashes.deinit(self.allocator);
    }

    pub fn invalidate(self: *Pager) void {
        memory_policy.clearRetainingBounded(u64, &self.prev_row_hashes, self.allocator, retained_row_hash_bytes_limit);
        memory_policy.clearRetainingBounded(u64, &self.curr_row_hashes, self.allocator, retained_row_hash_bytes_limit);
        self.prev_scroll = null;
        self.prev_enable_ansi = null;
        self.prev_content_rows = null;
    }

    fn prevRowCount(self: *const Pager) usize {
        return self.prev_row_hashes.items.len;
    }

    fn prevRowHash(self: *const Pager, idx: usize) u64 {
        return self.prev_row_hashes.items[idx];
    }

    pub fn displayPage(
        self: *Pager,
        stdout: *std.Io.Writer,
        buffer: *const render_buffer_mod.RenderBuffer,
        scroll_offset: usize,
        visible_rows: usize,
        enable_ansi: bool,
    ) void {
        const content_rows = if (visible_rows > 1) visible_rows - 1 else 1;

        const can_diff = blk: {
            const ps = self.prev_scroll orelse break :blk false;
            const pa = self.prev_enable_ansi orelse break :blk false;
            const pc = self.prev_content_rows orelse break :blk false;
            break :blk ps == scroll_offset and pa == enable_ansi and pc == content_rows;
        };

        const visible = visibleRows(buffer, scroll_offset, content_rows);
        const row_count = visible.count();

        self.hashVisibleRows(visible) catch {
            self.invalidate();
            return;
        };

        if (!can_diff) {
            stdout.writeAll("\x1b[H\x1b[J") catch return;
            var k: usize = 0;
            while (k < row_count) : (k += 1) {
                if (k > 0) stdout.writeByte('\n') catch return;
                stdout.writeAll(visible.row(k)) catch return;
            }
        } else {
            const prev_count = self.prevRowCount();
            var k: usize = 0;
            while (k < row_count) : (k += 1) {
                const unchanged = k < prev_count and self.curr_row_hashes.items[k] == self.prevRowHash(k);
                if (unchanged) continue;
                stdout.print("\x1b[{d};1H\x1b[2K", .{k + 1}) catch return;
                stdout.writeAll(visible.row(k)) catch return;
            }
            if (prev_count > row_count) {
                var j: usize = row_count;
                while (j < prev_count) : (j += 1) {
                    stdout.print("\x1b[{d};1H\x1b[2K", .{j + 1}) catch return;
                }
            }
        }

        writeStatusLine(stdout, scroll_offset, content_rows, buffer.totalLines(), enable_ansi);
        stdout.flush() catch {};

        self.rollForwardHashes();
        self.prev_scroll = scroll_offset;
        self.prev_enable_ansi = enable_ansi;
        self.prev_content_rows = content_rows;
    }

    fn hashVisibleRows(self: *Pager, visible: VisibleRows) !void {
        memory_policy.clearRetainingBounded(u64, &self.curr_row_hashes, self.allocator, retained_row_hash_bytes_limit);
        const row_count = visible.count();
        try self.curr_row_hashes.ensureTotalCapacity(self.allocator, row_count);
        var k: usize = 0;
        while (k < row_count) : (k += 1) {
            self.curr_row_hashes.appendAssumeCapacity(std.hash.XxHash3.hash(0, visible.row(k)));
        }
    }

    fn rollForwardHashes(self: *Pager) void {
        const tmp = self.prev_row_hashes;
        self.prev_row_hashes = self.curr_row_hashes;
        self.curr_row_hashes = tmp;
        memory_policy.clearRetainingBounded(u64, &self.curr_row_hashes, self.allocator, retained_row_hash_bytes_limit);
    }
};

const VisibleRows = struct {
    buffer: *const render_buffer_mod.RenderBuffer,
    first: usize,
    last: usize,

    fn count(self: VisibleRows) usize {
        return if (self.last > self.first) self.last - self.first else 0;
    }

    fn row(self: VisibleRows, k: usize) []const u8 {
        return self.buffer.row(self.first + k);
    }
};

fn visibleRows(
    buffer: *const render_buffer_mod.RenderBuffer,
    scroll_offset: usize,
    content_rows: usize,
) VisibleRows {
    const total = buffer.totalLines();
    if (total == 0) return .{ .buffer = buffer, .first = 0, .last = 0 };
    const first = @min(scroll_offset, total);
    const last = @min(scroll_offset + content_rows, total);
    return .{ .buffer = buffer, .first = first, .last = last };
}

fn writeStatusLine(
    stdout: *std.Io.Writer,
    scroll_offset: usize,
    content_rows: usize,
    total_lines: usize,
    enable_ansi: bool,
) void {
    stdout.print("\x1b[{d};1H\x1b[2K", .{content_rows + 1}) catch return;

    if (total_lines <= content_rows or scroll_offset + content_rows >= total_lines) {
        if (enable_ansi) stdout.writeAll("\x1b[7m") catch return;
        stdout.writeAll("(END)") catch return;
        if (enable_ansi) stdout.writeAll("\x1b[0m") catch return;
    } else {
        stdout.writeAll(":") catch return;
    }
}

test "visibleRows strips trailing newlines" {
    const allocator = std.testing.allocator;
    var rb: render_buffer_mod.RenderBuffer = undefined;
    rb.init(allocator);
    defer rb.deinit();
    try rb.writer.writeAll("alpha\nbeta\ngamma\n");
    try rb.writer.flush();

    const vr = visibleRows(&rb, 0, 5);
    try std.testing.expectEqual(@as(usize, 3), vr.count());
    try std.testing.expectEqualStrings("alpha", vr.row(0));
    try std.testing.expectEqualStrings("beta", vr.row(1));
    try std.testing.expectEqualStrings("gamma", vr.row(2));
}

test "Pager reuses capacity across repaints without unbounded growth" {
    const allocator = std.testing.allocator;
    var pgr = Pager.init(allocator);
    defer pgr.deinit();

    var rb: render_buffer_mod.RenderBuffer = undefined;
    rb.init(allocator);
    defer rb.deinit();
    try rb.writer.writeAll("x\ny\nz\n");
    try rb.writer.flush();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    pgr.displayPage(&out.writer, &rb, 0, 3, false);
    const first_cap = pgr.prev_row_hashes.capacity;
    out.clearRetainingCapacity();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        pgr.displayPage(&out.writer, &rb, 0, 3, false);
        out.clearRetainingCapacity();
    }
    try std.testing.expectEqual(first_cap, pgr.prev_row_hashes.capacity);
}

test "Pager invalidate releases excessive row-hash capacity" {
    const allocator = std.testing.allocator;
    var pgr = Pager.init(allocator);
    defer pgr.deinit();

    try pgr.prev_row_hashes.ensureTotalCapacity(allocator, retained_row_hash_bytes_limit / @sizeOf(u64) + 1);
    try pgr.curr_row_hashes.ensureTotalCapacity(allocator, retained_row_hash_bytes_limit / @sizeOf(u64) + 1);

    pgr.invalidate();
    try std.testing.expectEqual(@as(usize, 0), pgr.prev_row_hashes.capacity);
    try std.testing.expectEqual(@as(usize, 0), pgr.curr_row_hashes.capacity);
}

test "Pager diffing skips emission for unchanged rows" {
    const allocator = std.testing.allocator;
    var pgr = Pager.init(allocator);
    defer pgr.deinit();

    var rb: render_buffer_mod.RenderBuffer = undefined;
    rb.init(allocator);
    defer rb.deinit();
    try rb.writer.writeAll("one\ntwo\nthree\n");
    try rb.writer.flush();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    pgr.displayPage(&out.writer, &rb, 0, 4, false);
    const first_bytes = try allocator.dupe(u8, out.writer.buffered());
    defer allocator.free(first_bytes);

    out.clearRetainingCapacity();
    pgr.displayPage(&out.writer, &rb, 0, 4, false);
    const second_bytes = out.writer.buffered();

    try std.testing.expect(first_bytes.len > second_bytes.len);
    try std.testing.expect(std.mem.find(u8, second_bytes, "\x1b[H\x1b[J") == null);
}

test "Pager (END) status line with ANSI disabled emits no reverse-video SGR" {
    const allocator = std.testing.allocator;
    var pgr = Pager.init(allocator);
    defer pgr.deinit();

    var rb: render_buffer_mod.RenderBuffer = undefined;
    rb.init(allocator);
    defer rb.deinit();
    try rb.writer.writeAll("one\ntwo\n");
    try rb.writer.flush();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    pgr.displayPage(&out.writer, &rb, 0, 5, false);

    const bytes = out.writer.buffered();
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[7m") == null);
    try std.testing.expect(std.mem.find(u8, bytes, "(END)") != null);
}

test "Pager (END) status line with ANSI enabled emits reverse-video SGR" {
    const allocator = std.testing.allocator;
    var pgr = Pager.init(allocator);
    defer pgr.deinit();

    var rb: render_buffer_mod.RenderBuffer = undefined;
    rb.init(allocator);
    defer rb.deinit();
    try rb.writer.writeAll("one\ntwo\n");
    try rb.writer.flush();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    pgr.displayPage(&out.writer, &rb, 0, 5, true);

    const bytes = out.writer.buffered();
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[7m") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "(END)") != null);
}

test "Pager diff forces full repaint when ANSI state changes" {
    const allocator = std.testing.allocator;
    var pgr = Pager.init(allocator);
    defer pgr.deinit();

    var rb: render_buffer_mod.RenderBuffer = undefined;
    rb.init(allocator);
    defer rb.deinit();
    try rb.writer.writeAll("alpha\nbeta\n");
    try rb.writer.flush();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    pgr.displayPage(&out.writer, &rb, 0, 4, true);
    out.clearRetainingCapacity();

    pgr.displayPage(&out.writer, &rb, 0, 4, false);
    const bytes = out.writer.buffered();
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[H\x1b[J") != null);
}

test "Pager diff does not require buffer.finalize to populate a row-hash cache" {
    const allocator = std.testing.allocator;
    var pgr = Pager.init(allocator);
    defer pgr.deinit();

    var rb: render_buffer_mod.RenderBuffer = undefined;
    rb.init(allocator);
    defer rb.deinit();
    try rb.writer.writeAll("alpha\nbeta\ngamma\n");
    try rb.writer.flush();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    pgr.displayPage(&out.writer, &rb, 0, 4, false);
    const first_bytes = try allocator.dupe(u8, out.writer.buffered());
    defer allocator.free(first_bytes);

    out.clearRetainingCapacity();
    pgr.displayPage(&out.writer, &rb, 0, 4, false);
    const second_bytes = out.writer.buffered();

    try std.testing.expect(first_bytes.len > second_bytes.len);
    try std.testing.expect(std.mem.find(u8, second_bytes, "\x1b[H\x1b[J") == null);
}

test "Pager full repaint when scroll changes" {
    const allocator = std.testing.allocator;
    var pgr = Pager.init(allocator);
    defer pgr.deinit();

    var rb: render_buffer_mod.RenderBuffer = undefined;
    rb.init(allocator);
    defer rb.deinit();
    try rb.writer.writeAll("a\nb\nc\nd\n");
    try rb.writer.flush();

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    pgr.displayPage(&out.writer, &rb, 0, 3, false);
    out.clearRetainingCapacity();

    pgr.displayPage(&out.writer, &rb, 1, 3, false);
    const bytes = out.writer.buffered();
    try std.testing.expect(std.mem.find(u8, bytes, "\x1b[H\x1b[J") != null);
}
