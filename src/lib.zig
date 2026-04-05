const std = @import("std");

pub const Theme = @import("theme.zig").Theme;
pub const RenderOptions = @import("render.zig").RenderOptions;
pub const renderMarkdown = @import("render.zig").renderMarkdown;

const cli = @import("cli.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !u8 {
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

    const exit_code = cli.runWithDir(
        allocator,
        std.fs.cwd(),
        args,
        &stdout_stream.interface,
        &stderr_stream.interface,
        enable_ansi,
    ) catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);

    stdout_stream.interface.flush() catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);
    stderr_stream.interface.flush() catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);
    return exit_code;
}

fn unwrapWriteError(
    err: anyerror,
    stdout_stream: *std.fs.File.Writer,
    stderr_stream: *std.fs.File.Writer,
) !u8 {
    if (err == error.WriteFailed) {
        if (stdout_stream.err) |underlying| return underlying;
        if (stderr_stream.err) |underlying| return underlying;
    }
    return err;
}

test {
    _ = @import("ansi.zig");
    _ = @import("cli.zig");
    _ = @import("document.zig");
    _ = @import("render.zig");
    _ = @import("theme.zig");
    _ = @import("width.zig");
    _ = @import("table.zig");
}
