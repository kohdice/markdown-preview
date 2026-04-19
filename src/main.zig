const std = @import("std");
const cli = @import("cli.zig");
const term = @import("term.zig");
const terminal = term.terminal;

const stdout_buffer_size = 64 * 1024;
const stderr_buffer_size = 1024;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    const stdout_file = std.fs.File.stdout();
    const stderr_file = std.fs.File.stderr();

    var stdout_buffer: [stdout_buffer_size]u8 = undefined;
    var stderr_buffer: [stderr_buffer_size]u8 = undefined;
    var stdout_stream = stdout_file.writer(&stdout_buffer);
    var stderr_stream = stderr_file.writer(&stderr_buffer);

    const enable_ansi = switch (std.io.tty.Config.detect(stdout_file)) {
        .escape_codes, .windows_api => true,
        .no_color => false,
    };

    const wrap_width = if (enable_ansi) terminal.getTerminalWidth(stdout_file.handle) else null;
    const ambiguous_default = terminal.detectAmbiguousWidthFromProcess();

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
    }) catch |err| return cli.unwrapWriteError(err, stdout_stream.err, stderr_stream.err);

    stdout_stream.interface.flush() catch |err| return cli.unwrapWriteError(err, stdout_stream.err, stderr_stream.err);
    stderr_stream.interface.flush() catch |err| return cli.unwrapWriteError(err, stdout_stream.err, stderr_stream.err);

    if (exit_code != 0) std.process.exit(exit_code);
}
