const std = @import("std");
const backing_allocator = @import("backing_allocator.zig");
const cli = @import("cli.zig");
const stdout_buffer_mod = @import("stdout_buffer.zig");
const term = @import("term.zig");
const terminal = term.terminal;

const stderr_buffer_size = 1024;

pub fn main() !u8 {
    var backing: backing_allocator.Backing = .init;
    defer _ = backing.deinit();
    const allocator = backing.allocator();
    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    const stdout_file = std.fs.File.stdout();
    const stderr_file = std.fs.File.stderr();

    const stdout_buffer = try allocator.alloc(u8, stdout_buffer_mod.sizeFor(stdout_file));
    defer allocator.free(stdout_buffer);
    var stderr_buffer: [stderr_buffer_size]u8 = undefined;
    var stdout_stream = stdout_file.writer(stdout_buffer);
    var stderr_stream = stderr_file.writer(&stderr_buffer);

    const enable_ansi = switch (std.io.tty.Config.detect(stdout_file)) {
        .escape_codes, .windows_api => true,
        .no_color => false,
    };

    const wrap_width = if (enable_ansi) terminal.getTerminalWidth(stdout_file.handle) else null;
    const ambiguous_default = terminal.detectAmbiguousWidthFromProcess();
    const color_mode = terminal.detectColorModeFromProcess();

    const exit_code = cli.run(.{
        .allocator = allocator,
        .cwd = std.fs.cwd(),
        .args = raw_args,
        .stdout = &stdout_stream.interface,
        .stderr = &stderr_stream.interface,
        .stdout_handle = stdout_file.handle,
        .stdin_handle = std.fs.File.stdin().handle,
        .enable_ansi = enable_ansi,
        .wrap_width = wrap_width,
        .ambiguous_width = ambiguous_default,
        .color_mode = color_mode,
    }) catch |err| return unwrapWriteError(err, stdout_stream.err, stderr_stream.err);

    stdout_stream.interface.flush() catch |err| return unwrapWriteError(err, stdout_stream.err, stderr_stream.err);
    stderr_stream.interface.flush() catch |err| return unwrapWriteError(err, stdout_stream.err, stderr_stream.err);

    return exit_code;
}

fn unwrapWriteError(
    err: anyerror,
    stdout_err: ?anyerror,
    stderr_err: ?anyerror,
) anyerror {
    if (err == error.WriteFailed) {
        if (stdout_err) |underlying| return underlying;
        if (stderr_err) |underlying| return underlying;
    }
    return err;
}
