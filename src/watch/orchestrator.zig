const std = @import("std");
const content_hash = @import("content_hash.zig");
const file_watcher = @import("file_watcher.zig");
const loop = @import("loop.zig");
const raw_term = @import("../term/raw.zig");
const session_mod = @import("session.zig");
const term = @import("../term.zig");
const ansi = term.ansi;
const terminal = term.terminal;
const width = term.width;

const exit_success: u8 = 0;
const exit_failure: u8 = 1;

const default_term_cols: usize = 80;
const default_term_rows: usize = 24;

pub const WatchOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    stdout_file: std.Io.File,
    stdin_file: std.Io.File,
    enable_ansi: bool,
    ambiguous_width: width.AmbiguousWidth,
    color_mode: ansi.ColorMode = .truecolor,
};

pub fn run(opts: WatchOptions) !u8 {
    const stdout_tty = opts.stdout_file.isTty(opts.io) catch false;
    const stdin_tty = opts.stdin_file.isTty(opts.io) catch false;
    if (!stdout_tty or !stdin_tty) {
        try opts.stderr.writeAll("mp: --watch requires an interactive terminal (stdin and stdout must be a TTY)\n");
        return exit_failure;
    }

    const dir_path = std.fs.path.dirnamePosix(opts.path) orelse ".";
    const file_name = std.fs.path.basenamePosix(opts.path);

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_z = toCString(&dir_buf, dir_path) orelse {
        try opts.stderr.print("mp: path too long: '{s}'\n", .{opts.path});
        return exit_failure;
    };
    var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const name_z = toCString(&name_buf, file_name) orelse {
        try opts.stderr.print("mp: path too long: '{s}'\n", .{opts.path});
        return exit_failure;
    };

    var session: session_mod.WatchSession = undefined;
    session.init(opts.allocator, .{
        .enable_ansi = opts.enable_ansi,
        .ambiguous_width = opts.ambiguous_width,
        .color_mode = opts.color_mode,
    });
    defer session.deinit();

    var term_size = terminal.getTerminalSize(opts.stdout_file.handle) orelse terminal.TerminalSize{ .cols = default_term_cols, .rows = default_term_rows };
    var wrap_width: ?usize = if (opts.enable_ansi) term_size.cols else null;

    var rt = raw_term.RawTerm.setup(opts.stdin_file.handle, opts.stdout) catch {
        try opts.stderr.writeAll("mp: failed to configure terminal\n");
        return exit_failure;
    };
    defer rt.teardown();

    var scroll_offset: usize = 0;
    var hash: content_hash.ContentHash = .{};

    _ = session.refreshFrom(opts.io, opts.cwd, opts.path, wrap_width, &hash);
    session.pgr.displayPage(opts.stdout, &session.buffer, scroll_offset, term_size.rows, opts.enable_ansi, opts.color_mode);

    var watcher = file_watcher.FileWatcher.init(dir_z, name_z) catch |err| {
        try opts.stderr.print("mp: unable to watch '{s}': {s}\n", .{ opts.path, @errorName(err) });
        return exit_failure;
    };
    defer watcher.deinit();

    const exit_reason = loop.eventLoop(opts, &rt, &watcher, &session, &term_size, &wrap_width, &scroll_offset, &hash);

    return switch (exit_reason) {
        .user_quit => exit_success,
        .signal_exit => exit_failure,
        .poll_error => exit_failure,
    };
}

fn toCString(buf: *[std.Io.Dir.max_path_bytes]u8, slice: []const u8) ?[*:0]const u8 {
    if (slice.len >= buf.len) return null;
    @memcpy(buf[0..slice.len], slice);
    buf[slice.len] = 0;
    return @ptrCast(buf[0..slice.len :0]);
}
