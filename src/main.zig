const std = @import("std");
const cli = @import("cli.zig");
const stdout_buffer_mod = @import("stdout_buffer.zig");
const term = @import("term.zig");
const terminal = term.terminal;
const unwrapWriteError = @import("write_error.zig").unwrapWriteError;

const stderr_buffer_size = 1024;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    const stdout_file = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();
    const stdin_file = std.Io.File.stdin();

    const stdout_buffer = try arena.alloc(u8, try stdout_buffer_mod.sizeFor(io, stdout_file));
    var stderr_buffer: [stderr_buffer_size]u8 = undefined;

    var stdout_stream = stdout_file.writer(io, stdout_buffer);
    var stderr_stream = stderr_file.writer(io, &stderr_buffer);

    const no_color = if (init.environ_map.get("NO_COLOR")) |v| v.len != 0 else false;
    const force_color = if (init.environ_map.get("CLICOLOR_FORCE")) |v| v.len != 0 else false;
    const tty_mode = try std.Io.Terminal.Mode.detect(io, stdout_file, no_color, force_color);
    const enable_ansi = tty_mode != .no_color;

    const wrap_width = if (enable_ansi) terminal.getTerminalWidth(stdout_file.handle) else null;
    const ambiguous_default = terminal.detectAmbiguousWidthFromEnv(init.environ_map);
    const color_mode = terminal.detectColorModeFromEnv(init.environ_map);

    const exit_code = cli.run(.{
        .allocator = arena,
        .io = io,
        .cwd = std.Io.Dir.cwd(),
        .args = args,
        .stdout = &stdout_stream.interface,
        .stderr = &stderr_stream.interface,
        .stdout_file = stdout_file,
        .stdin_file = stdin_file,
        .enable_ansi = enable_ansi,
        .wrap_width = wrap_width,
        .ambiguous_width = ambiguous_default,
        .color_mode = color_mode,
    }) catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);

    stdout_stream.interface.flush() catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);
    stderr_stream.interface.flush() catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);

    return exit_code;
}
