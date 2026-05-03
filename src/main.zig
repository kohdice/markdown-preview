const std = @import("std");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const stdout_buffer_mod = @import("stdout_buffer.zig");
const term = @import("term.zig");
const terminal = term.terminal;
const unwrapWriteError = @import("write_error.zig").unwrapWriteError;

const stderr_buffer_size = 1024;

pub fn main(init: std.process.Init) !u8 {
    const process_arena = init.arena.allocator();
    const app_allocator = init.gpa;
    const args = try init.minimal.args.toSlice(process_arena);
    const io = init.io;

    const stdout_file = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();
    const stdin_file = std.Io.File.stdin();

    const stdout_buffer = try process_arena.alloc(u8, try stdout_buffer_mod.sizeFor(io, stdout_file));
    var stderr_buffer: [stderr_buffer_size]u8 = undefined;

    var stdout_stream = stdout_file.writerStreaming(io, stdout_buffer);
    var stderr_stream = stderr_file.writerStreaming(io, &stderr_buffer);

    const stdout_is_tty = stdout_file.isTty(io) catch false;
    const enable_ansi = try detectAutoAnsi(io, stdout_file, init.environ_map);
    const wrap_width = if (stdout_is_tty) terminal.getTerminalWidth(stdout_file.handle) else null;
    const ambiguous_default = terminal.detectAmbiguousWidthFromEnv(init.environ_map);

    const exit_code = cli.run(.{
        .app_allocator = app_allocator,
        .io = io,
        .cwd = std.Io.Dir.cwd(),
        .args = args,
        .version = build_options.version,
        .stdout = &stdout_stream.interface,
        .stderr = &stderr_stream.interface,
        .stdout_file = stdout_file,
        .stdin_file = stdin_file,
        .enable_ansi = enable_ansi,
        .wrap_width = wrap_width,
        .ambiguous_width = ambiguous_default,
    }) catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);

    stdout_stream.interface.flush() catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);
    stderr_stream.interface.flush() catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);

    return exit_code;
}

fn detectAutoAnsi(
    io: std.Io,
    file: std.Io.File,
    env: *const std.process.Environ.Map,
) !bool {
    const mode = try std.Io.Terminal.Mode.detect(
        io,
        file,
        envFlagSet(env, "NO_COLOR"),
        envFlagSet(env, "CLICOLOR_FORCE"),
    );
    return switch (mode) {
        .escape_codes => true,
        .no_color, .windows_api => false,
    };
}

fn envFlagSet(env: *const std.process.Environ.Map, name: []const u8) bool {
    return if (env.get(name)) |value| value.len != 0 else false;
}
