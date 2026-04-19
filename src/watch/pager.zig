const std = @import("std");
const actions = @import("actions.zig");
const render_buffer_mod = @import("render_buffer.zig");

pub fn applyAction(action: actions.KeyAction, scroll_offset: *usize, total_lines: usize, term_rows: usize) bool {
    const content_rows = if (term_rows > 1) term_rows - 1 else 1;
    const max_offset = if (total_lines > content_rows) total_lines - content_rows else 0;

    switch (action) {
        .quit, .none => return false,
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

pub fn displayPage(
    stdout: *std.io.Writer,
    buffer: *const render_buffer_mod.RenderBuffer,
    scroll_offset: usize,
    visible_rows: usize,
    enable_ansi: bool,
) void {
    const content_rows = if (visible_rows > 1) visible_rows - 1 else 1;

    stdout.writeAll("\x1b[H\x1b[J") catch return;

    const rendered = buffer.buffered();
    const range = visibleRange(buffer.lineOffsets(), rendered.len, scroll_offset, content_rows);
    if (range.end > range.start) {
        stdout.writeAll(rendered[range.start..range.end]) catch return;
    }

    writeStatusLine(stdout, scroll_offset, content_rows, buffer.totalLines(), enable_ansi);

    stdout.flush() catch {};
}

fn writeStatusLine(
    stdout: *std.io.Writer,
    scroll_offset: usize,
    content_rows: usize,
    total_lines: usize,
    enable_ansi: bool,
) void {
    stdout.print("\x1b[{d};1H", .{content_rows + 1}) catch return;

    if (total_lines <= content_rows or scroll_offset + content_rows >= total_lines) {
        if (enable_ansi) stdout.writeAll("\x1b[7m") catch return;
        stdout.writeAll("(END)") catch return;
        if (enable_ansi) stdout.writeAll("\x1b[0m") catch return;
    } else {
        stdout.writeAll(":") catch return;
    }
}

const VisibleRange = struct {
    start: usize,
    end: usize,
};

fn visibleRange(
    line_offsets: []const usize,
    data_len: usize,
    scroll_offset: usize,
    content_rows: usize,
) VisibleRange {
    if (line_offsets.len == 0) return .{ .start = 0, .end = 0 };

    const first = @min(scroll_offset, line_offsets.len - 1);
    const last = @min(scroll_offset + content_rows, line_offsets.len);
    const start = line_offsets[first];
    const end = if (last < line_offsets.len) line_offsets[last] else data_len;
    return .{ .start = start, .end = end };
}

test "visibleRange selects correct byte range" {
    const offsets = [_]usize{ 0, 4, 8, 12 };
    const range = visibleRange(&offsets, 15, 1, 2);
    try std.testing.expectEqual(@as(usize, 4), range.start);
    try std.testing.expectEqual(@as(usize, 12), range.end);
}

test "visibleRange from start" {
    const offsets = [_]usize{ 0, 4, 8 };
    const range = visibleRange(&offsets, 10, 0, 2);
    try std.testing.expectEqual(@as(usize, 0), range.start);
    try std.testing.expectEqual(@as(usize, 8), range.end);
}

test "visibleRange clamps to end of data" {
    const offsets = [_]usize{ 0, 4, 8 };
    const range = visibleRange(&offsets, 10, 1, 5);
    try std.testing.expectEqual(@as(usize, 4), range.start);
    try std.testing.expectEqual(@as(usize, 10), range.end);
}

test "visibleRange empty offsets" {
    const offsets = [_]usize{};
    const range = visibleRange(&offsets, 0, 0, 10);
    try std.testing.expectEqual(@as(usize, 0), range.start);
    try std.testing.expectEqual(@as(usize, 0), range.end);
}
