const std = @import("std");
const cli = @import("cli.zig");
const width = @import("width.zig");

const stdout_buffer_size = 4096;
const stderr_buffer_size = 1024;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    const args = try allocator.alloc([]const u8, raw_args.len);
    defer allocator.free(args);

    for (raw_args, 0..) |arg, index| {
        args[index] = arg;
    }

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

    const wrap_width = if (enable_ansi) cli.getTerminalWidth(stdout_file.handle) else null;
    const ambiguous_default = width.detectAmbiguousFromProcess();

    const exit_code = cli.run(
        allocator,
        std.fs.cwd(),
        args,
        &stdout_stream.interface,
        &stderr_stream.interface,
        enable_ansi,
        wrap_width,
        ambiguous_default,
    ) catch |err| return cli.unwrapWriteError(err, stdout_stream.err, stderr_stream.err);

    stdout_stream.interface.flush() catch |err| return cli.unwrapWriteError(err, stdout_stream.err, stderr_stream.err);
    stderr_stream.interface.flush() catch |err| return cli.unwrapWriteError(err, stdout_stream.err, stderr_stream.err);
    if (exit_code != 0) std.process.exit(exit_code);
}
