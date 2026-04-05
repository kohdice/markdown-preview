const std = @import("std");
const cli = @import("cli.zig");

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

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_stream = stdout_file.writer(&stdout_buffer);
    var stderr_stream = stderr_file.writer(&stderr_buffer);

    const enable_ansi = switch (std.io.tty.Config.detect(stdout_file)) {
        .escape_codes, .windows_api => true,
        .no_color => false,
    };

    const wrap_width = if (enable_ansi) cli.getTerminalWidth(stdout_file.handle) else null;

    const exit_code = cli.run(
        allocator,
        std.fs.cwd(),
        args,
        &stdout_stream.interface,
        &stderr_stream.interface,
        enable_ansi,
        wrap_width,
    ) catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);

    stdout_stream.interface.flush() catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);
    stderr_stream.interface.flush() catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);
    if (exit_code != 0) std.process.exit(exit_code);
}

fn unwrapWriteError(
    err: anyerror,
    stdout_stream: *std.fs.File.Writer,
    stderr_stream: *std.fs.File.Writer,
) anyerror {
    if (err == error.WriteFailed) {
        if (stdout_stream.err) |underlying| return underlying;
        if (stderr_stream.err) |underlying| return underlying;
    }
    return err;
}
