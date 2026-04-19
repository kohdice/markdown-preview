const std = @import("std");
const file_watcher = @import("file_watcher.zig");
const loop = @import("loop.zig");
const options = @import("options.zig");
const pager = @import("pager.zig");
const pipeline = @import("pipeline.zig");
const raw_term = @import("raw_term.zig");
const render = @import("../render.zig");
const render_buffer_mod = @import("render_buffer.zig");
const term = @import("../term.zig");
const terminal = term.terminal;

const exit_success: u8 = 0;
const exit_failure: u8 = 1;

const default_term_cols: usize = 80;
const default_term_rows: usize = 24;

pub const WatchOptions = options.WatchOptions;

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

    var renderer: render.Renderer = undefined;
    renderer.init(state_arena.allocator(), .{
        .enable_ansi = opts.enable_ansi,
        .ambiguous_width = opts.ambiguous_width,
    });
    defer renderer.deinit();

    var cycle_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer cycle_arena.deinit();

    var buffer = render_buffer_mod.RenderBuffer.init(state_arena.allocator());
    defer buffer.deinit();

    var term_size = terminal.getTerminalSize(opts.stdout_handle) orelse terminal.TerminalSize{ .cols = default_term_cols, .rows = default_term_rows };
    var wrap_width: ?usize = if (opts.enable_ansi) term_size.cols else null;

    var rt = raw_term.RawTerm.setup(opts.stdin_handle, opts.stdout) catch {
        try opts.stderr.writeAll("mp: failed to configure terminal\n");
        return exit_failure;
    };
    defer rt.teardown();

    var scroll_offset: usize = 0;

    pipeline.renderTo(opts.cwd, opts.path, &renderer, &cycle_arena, &buffer, wrap_width);
    pager.displayPage(opts.stdout, &buffer, scroll_offset, term_size.rows, opts.enable_ansi);

    var watcher = file_watcher.FileWatcher.init(dir_z, name_z) catch |err| {
        try opts.stderr.print("mp: unable to watch '{s}': {s}\n", .{ opts.path, @errorName(err) });
        return exit_failure;
    };
    defer watcher.deinit();

    const exit_reason = loop.eventLoop(opts, &rt, &watcher, &renderer, &cycle_arena, &buffer, &term_size, &wrap_width, &scroll_offset);

    return switch (exit_reason) {
        .user_quit => exit_success,
        .signal_exit => exit_failure,
        .poll_error => exit_failure,
    };
}

fn toCString(buf: *[std.fs.max_path_bytes]u8, slice: []const u8) ?[*:0]const u8 {
    if (slice.len >= buf.len) return null;
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    return @ptrCast(buf[0..slice.len :0]);
}
