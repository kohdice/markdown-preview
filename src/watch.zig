const std = @import("std");
const parse = @import("parse.zig");
const render = @import("render.zig");
const term = @import("term.zig");
const file_watcher = @import("watch/file_watcher.zig");
const raw_term = @import("watch/raw_term.zig");
const width = term.width;
const terminal = term.terminal;

const max_file_bytes = 10 * 1024 * 1024;
const exit_success: u8 = 0;
const exit_failure: u8 = 1;

pub const WatchOptions = struct {
    allocator: std.mem.Allocator,
    cwd: std.fs.Dir,
    path: []const u8,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    stdout_handle: std.posix.fd_t,
    stdin_handle: std.posix.fd_t,
    enable_ansi: bool,
    wrap_width: ?usize,
    ambiguous_width: width.AmbiguousWidth,
};

const KeyAction = enum {
    quit,
    scroll_up,
    scroll_down,
    page_up,
    page_down,
    scroll_top,
    scroll_bottom,
    none,
};

const ExitReason = enum {
    user_quit,
    signal_exit,
    poll_error,
};

pub fn run(opts: WatchOptions) !u8 {
    if (!std.posix.isatty(opts.stdout_handle) or !std.posix.isatty(opts.stdin_handle)) {
        try opts.stderr.writeAll("mp: --watch requires an interactive terminal (stdin and stdout must be a TTY)\n");
        return exit_failure;
    }

    const dir_path = std.fs.path.dirnamePosix(opts.path) orelse ".";
    const file_name = std.fs.path.basenamePosix(opts.path);

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_z = toCString(&dir_buf, dir_path) orelse {
        try opts.stderr.print("mp: path too long: '{s}'\n", .{opts.path});
        return exit_failure;
    };
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const name_z = toCString(&name_buf, file_name) orelse {
        try opts.stderr.print("mp: path too long: '{s}'\n", .{opts.path});
        return exit_failure;
    };

    var state_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer state_arena.deinit();

    var renderer = render.Renderer.init(state_arena.allocator(), .{
        .enable_ansi = opts.enable_ansi,
        .ambiguous_width = opts.ambiguous_width,
    });
    defer renderer.deinit();

    var cycle_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer cycle_arena.deinit();

    var output_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer output_arena.deinit();

    var term_size = terminal.getTerminalSize(opts.stdout_handle) orelse terminal.TerminalSize{ .cols = 80, .rows = 24 };
    var wrap_width: ?usize = if (opts.enable_ansi) term_size.cols else null;

    var rt = raw_term.RawTerm.setup(opts.stdin_handle, opts.stdout) catch {
        try opts.stderr.writeAll("mp: failed to configure terminal\n");
        return exit_failure;
    };
    defer rt.teardown();

    var scroll_offset: usize = 0;
    var rendered: []const u8 = "";
    var line_index: LineIndex = .{ .line_offsets = &.{}, .total_lines = 0 };

    rendered = renderToSlice(opts, &renderer, &cycle_arena, &output_arena, wrap_width);
    line_index = buildLineIndex(output_arena.allocator(), rendered);
    displayPage(opts.stdout, rendered, line_index, scroll_offset, term_size.rows, opts.enable_ansi);

    var watcher = file_watcher.FileWatcher.init(dir_z, name_z) catch |err| {
        try opts.stderr.print("mp: unable to watch '{s}': {s}\n", .{ opts.path, @errorName(err) });
        return exit_failure;
    };
    defer watcher.deinit();

    const exit_reason = eventLoop(opts, &rt, &watcher, &renderer, &cycle_arena, &output_arena, &term_size, &wrap_width, &scroll_offset, &rendered, &line_index);

    return switch (exit_reason) {
        .user_quit => exit_success,
        .signal_exit => exit_failure,
        .poll_error => exit_failure,
    };
}

fn eventLoop(
    opts: WatchOptions,
    rt: *raw_term.RawTerm,
    watcher: *file_watcher.FileWatcher,
    renderer: *render.Renderer,
    cycle_arena: *std.heap.ArenaAllocator,
    output_arena: *std.heap.ArenaAllocator,
    term_size: *terminal.TerminalSize,
    wrap_width: *?usize,
    scroll_offset: *usize,
    rendered: *[]const u8,
    line_index: *LineIndex,
) ExitReason {
    const watcher_idx: usize = 0;
    const stdin_idx: usize = 1;
    const signal_idx: usize = 2;

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = watcher.getFd(), .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = opts.stdin_handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = rt.signalFd(), .events = std.posix.POLL.IN, .revents = 0 },
    };

    var input: InputState = .{};

    while (true) {
        _ = std.posix.poll(&poll_fds, -1) catch return .poll_error;

        var needs_redisplay = false;

        if (poll_fds[signal_idx].revents & std.posix.POLL.IN != 0) {
            if (rt.readSignal()) |sig| {
                if (sig == std.posix.SIG.WINCH) {
                    term_size.* = terminal.getTerminalSize(opts.stdout_handle) orelse term_size.*;
                    wrap_width.* = if (opts.enable_ansi) term_size.cols else null;
                    scroll_offset.* = 0;
                    rendered.* = renderToSlice(opts, renderer, cycle_arena, output_arena, wrap_width.*);
                    line_index.* = buildLineIndex(output_arena.allocator(), rendered.*);
                    needs_redisplay = true;
                } else {
                    return .signal_exit;
                }
            }
        }

        if (poll_fds[watcher_idx].revents & std.posix.POLL.IN != 0) {
            const event = watcher.consumeEvents() catch return .poll_error;
            if (event != .none) {
                scroll_offset.* = 0;
                rendered.* = renderToSlice(opts, renderer, cycle_arena, output_arena, wrap_width.*);
                line_index.* = buildLineIndex(output_arena.allocator(), rendered.*);
                needs_redisplay = true;
            }
        }

        if (poll_fds[stdin_idx].revents & std.posix.POLL.IN != 0) {
            var key_buf: [16]u8 = undefined;
            const n = std.posix.read(opts.stdin_handle, &key_buf) catch return .poll_error;
            for (key_buf[0..n]) |byte| {
                const action = input.feedByte(byte);
                if (action == .quit) return .user_quit;
                if (applyAction(action, scroll_offset, line_index.total_lines, term_size.rows)) {
                    needs_redisplay = true;
                }
            }
        }

        if (needs_redisplay) {
            displayPage(opts.stdout, rendered.*, line_index.*, scroll_offset.*, term_size.rows, opts.enable_ansi);
        }
    }
}

fn applyAction(action: KeyAction, scroll_offset: *usize, total_lines: usize, term_rows: usize) bool {
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

const InputPhase = enum { idle, esc, csi, csi_digit };

const InputState = struct {
    phase: InputPhase = .idle,
    digit: u8 = 0,

    fn feedByte(self: *InputState, b: u8) KeyAction {
        switch (self.phase) {
            .idle => return self.handleKey(b),
            .esc => {
                if (b == '[') {
                    self.phase = .csi;
                    return .none;
                }
                self.phase = .idle;
                return self.handleKey(b);
            },
            .csi => {
                self.phase = .idle;
                return switch (b) {
                    'A' => .scroll_up,
                    'B' => .scroll_down,
                    '5', '6' => blk: {
                        self.phase = .csi_digit;
                        self.digit = b;
                        break :blk .none;
                    },
                    else => .none,
                };
            },
            .csi_digit => {
                self.phase = .idle;
                if (b == '~') {
                    return switch (self.digit) {
                        '5' => .page_up,
                        '6' => .page_down,
                        else => .none,
                    };
                }
                return .none;
            },
        }
    }

    fn handleKey(self: *InputState, b: u8) KeyAction {
        if (b == 0x1b) {
            self.phase = .esc;
            return .none;
        }
        return switch (b) {
            'q' => .quit,
            'k' => .scroll_up,
            'j' => .scroll_down,
            'g' => .scroll_top,
            'G' => .scroll_bottom,
            else => .none,
        };
    }
};

fn renderToSlice(
    opts: WatchOptions,
    renderer: *render.Renderer,
    cycle_arena: *std.heap.ArenaAllocator,
    output_arena: *std.heap.ArenaAllocator,
    wrap_width: ?usize,
) []const u8 {
    _ = cycle_arena.reset(.retain_capacity);
    _ = output_arena.reset(.retain_capacity);
    const cycle_alloc = cycle_arena.allocator();
    const out_alloc = output_arena.allocator();

    var output: std.io.Writer.Allocating = .init(out_alloc);

    const source = opts.cwd.readFileAlloc(cycle_alloc, opts.path, max_file_bytes) catch |err| {
        output.writer.print("mp: unable to read '{s}': {s}\n", .{ opts.path, @errorName(err) }) catch {};
        return flushAndGetBuffer(&output);
    };

    var doc = parse.parseOwned(cycle_alloc, .{
        .allocator = cycle_alloc,
        .buffer = source,
    }) catch {
        output.writer.writeAll("mp: parse error\n") catch {};
        return flushAndGetBuffer(&output);
    };
    defer doc.deinit();

    renderer.renderDocument(&output.writer, &doc, wrap_width, cycle_alloc) catch {};
    return flushAndGetBuffer(&output);
}

fn flushAndGetBuffer(output: *std.io.Writer.Allocating) []const u8 {
    output.writer.flush() catch {};
    return output.writer.buffered();
}

fn displayPage(
    stdout: *std.io.Writer,
    rendered: []const u8,
    line_index: LineIndex,
    scroll_offset: usize,
    visible_rows: usize,
    enable_ansi: bool,
) void {
    const content_rows = if (visible_rows > 1) visible_rows - 1 else 1;

    stdout.writeAll("\x1b[H\x1b[J") catch return;

    const range = visibleRange(line_index.line_offsets, rendered.len, scroll_offset, content_rows);
    if (range.end > range.start) {
        stdout.writeAll(rendered[range.start..range.end]) catch return;
    }

    writeStatusLine(stdout, scroll_offset, content_rows, line_index.total_lines, enable_ansi);

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

const LineIndex = struct {
    line_offsets: []const usize,
    total_lines: usize,
};

fn buildLineIndex(allocator: std.mem.Allocator, data: []const u8) LineIndex {
    var offsets: std.ArrayListUnmanaged(usize) = .empty;
    offsets.append(allocator, 0) catch return .{ .line_offsets = &.{}, .total_lines = 0 };

    for (data, 0..) |byte, i| {
        if (byte == '\n' and i + 1 < data.len) {
            offsets.append(allocator, i + 1) catch break;
        }
    }

    const total = offsets.items.len;
    if (data.len == 0) return .{ .line_offsets = &.{}, .total_lines = 0 };

    return .{
        .line_offsets = offsets.items,
        .total_lines = total,
    };
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

fn toCString(buf: *[std.fs.max_path_bytes]u8, slice: []const u8) ?[*:0]const u8 {
    if (slice.len >= buf.len) return null;
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    return @ptrCast(buf[0..slice.len :0]);
}

test "InputState single-byte keys" {
    var s: InputState = .{};
    try std.testing.expectEqual(KeyAction.quit, s.feedByte('q'));
    try std.testing.expectEqual(KeyAction.scroll_up, s.feedByte('k'));
    try std.testing.expectEqual(KeyAction.scroll_down, s.feedByte('j'));
    try std.testing.expectEqual(KeyAction.scroll_top, s.feedByte('g'));
    try std.testing.expectEqual(KeyAction.scroll_bottom, s.feedByte('G'));
    try std.testing.expectEqual(KeyAction.none, s.feedByte('x'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState complete arrow sequence in burst" {
    var s: InputState = .{};
    try std.testing.expectEqual(KeyAction.none, s.feedByte(0x1b));
    try std.testing.expectEqual(InputPhase.esc, s.phase);
    try std.testing.expectEqual(KeyAction.none, s.feedByte('['));
    try std.testing.expectEqual(InputPhase.csi, s.phase);
    try std.testing.expectEqual(KeyAction.scroll_up, s.feedByte('A'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState arrow down" {
    var s: InputState = .{};
    _ = s.feedByte(0x1b);
    _ = s.feedByte('[');
    try std.testing.expectEqual(KeyAction.scroll_down, s.feedByte('B'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState PageUp sequence" {
    var s: InputState = .{};
    _ = s.feedByte(0x1b);
    _ = s.feedByte('[');
    try std.testing.expectEqual(KeyAction.none, s.feedByte('5'));
    try std.testing.expectEqual(InputPhase.csi_digit, s.phase);
    try std.testing.expectEqual(KeyAction.page_up, s.feedByte('~'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState PageDown sequence" {
    var s: InputState = .{};
    _ = s.feedByte(0x1b);
    _ = s.feedByte('[');
    _ = s.feedByte('6');
    try std.testing.expectEqual(KeyAction.page_down, s.feedByte('~'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState ESC then regular key processes the key" {
    var s: InputState = .{};
    _ = s.feedByte(0x1b);
    try std.testing.expectEqual(InputPhase.esc, s.phase);
    try std.testing.expectEqual(KeyAction.scroll_down, s.feedByte('j'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState ESC then unknown key is ignored" {
    var s: InputState = .{};
    _ = s.feedByte(0x1b);
    try std.testing.expectEqual(KeyAction.none, s.feedByte('x'));
    try std.testing.expectEqual(InputPhase.idle, s.phase);
}

test "InputState double ESC: first consumed, second starts new sequence" {
    var s: InputState = .{};
    _ = s.feedByte(0x1b);
    try std.testing.expectEqual(KeyAction.none, s.feedByte(0x1b));
    try std.testing.expectEqual(InputPhase.esc, s.phase);
}

test "buildLineIndex empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const idx = buildLineIndex(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), idx.total_lines);
}

test "buildLineIndex single line without newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const idx = buildLineIndex(arena.allocator(), "hello");
    try std.testing.expectEqual(@as(usize, 1), idx.total_lines);
    try std.testing.expectEqual(@as(usize, 0), idx.line_offsets[0]);
}

test "buildLineIndex single line with newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const idx = buildLineIndex(arena.allocator(), "hello\n");
    try std.testing.expectEqual(@as(usize, 1), idx.total_lines);
    try std.testing.expectEqual(@as(usize, 0), idx.line_offsets[0]);
}

test "buildLineIndex two lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const idx = buildLineIndex(arena.allocator(), "a\nb");
    try std.testing.expectEqual(@as(usize, 2), idx.total_lines);
    try std.testing.expectEqual(@as(usize, 0), idx.line_offsets[0]);
    try std.testing.expectEqual(@as(usize, 2), idx.line_offsets[1]);
}

test "buildLineIndex three lines with trailing newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const idx = buildLineIndex(arena.allocator(), "a\nb\nc\n");
    try std.testing.expectEqual(@as(usize, 3), idx.total_lines);
    try std.testing.expectEqual(@as(usize, 0), idx.line_offsets[0]);
    try std.testing.expectEqual(@as(usize, 2), idx.line_offsets[1]);
    try std.testing.expectEqual(@as(usize, 4), idx.line_offsets[2]);
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
