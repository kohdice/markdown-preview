const std = @import("std");
const parse_mod = @import("parse.zig");
const render_mod = @import("render.zig");
const source_loader_mod = @import("source_loader.zig");
const stdout_buffer_mod = @import("stdout_buffer.zig");
const term_ansi = @import("term/ansi.zig");
const term_terminal = @import("term/terminal.zig");
const term_width = @import("term/width.zig");
const watch_orchestrator = @import("watch/orchestrator.zig");
const unwrapWriteError = @import("write_error.zig").unwrapWriteError;

pub const RenderOptions = render_mod.RenderOptions;
pub const AmbiguousWidth = term_width.AmbiguousWidth;
pub const ColorMode = term_ansi.ColorMode;

pub fn renderSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    writer: *std.Io.Writer,
    wrap_width: ?usize,
    options: RenderOptions,
) !void {
    var doc = try parse_mod.parse(allocator, .{ .borrowed = source });
    defer doc.deinit();

    var renderer = render_mod.Renderer.init(allocator, options);
    defer renderer.deinit();

    try renderer.render(writer, &doc, wrap_width, allocator);
}

pub fn renderFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
    writer: *std.Io.Writer,
    wrap_width: ?usize,
    options: RenderOptions,
) !void {
    const src = try source_loader_mod.loadFile(allocator, io, cwd, path);
    var doc = try parse_mod.parse(allocator, src);
    defer doc.deinit();

    var renderer = render_mod.Renderer.init(allocator, options);
    defer renderer.deinit();

    try renderer.render(writer, &doc, wrap_width, allocator);
}

/// Semantic watch-mode request. The facade opens stdio and detects the
/// terminal itself, so callers don't plumb writers or handles through.
/// `render_options == null` auto-detects ANSI/color/ambiguous-width.
pub const WatchRequest = struct {
    allocator: std.mem.Allocator,
    cwd: std.Io.Dir,
    path: []const u8,
    render_options: ?RenderOptions = null,
};

/// Live-preview `request.path` on the process's stdout until the user quits.
/// Requires stdin and stdout to be interactive TTYs. Takes `std.process.Init`
/// so stdio, env, and the Io implementation stay encapsulated inside the
/// facade; callers pass along the `init` their `main` receives.
pub fn watchFile(init: std.process.Init, request: WatchRequest) !u8 {
    const io = init.io;
    const stdout_file = std.Io.File.stdout();
    const stderr_file = std.Io.File.stderr();
    const stdin_file = std.Io.File.stdin();

    const stdout_buffer = try request.allocator.alloc(u8, try stdout_buffer_mod.sizeFor(io, stdout_file));
    defer request.allocator.free(stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;

    var stdout_stream = stdout_file.writer(io, stdout_buffer);
    var stderr_stream = stderr_file.writer(io, &stderr_buffer);

    const options = request.render_options orelse try detectedRenderOptions(io, stdout_file, init.environ_map);

    const exit_code = watch_orchestrator.run(.{
        .allocator = request.allocator,
        .io = io,
        .cwd = request.cwd,
        .path = request.path,
        .stdout = &stdout_stream.interface,
        .stderr = &stderr_stream.interface,
        .stdout_file = stdout_file,
        .stdin_file = stdin_file,
        .enable_ansi = options.enable_ansi,
        .ambiguous_width = options.ambiguous_width,
        .color_mode = options.color_mode,
    }) catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);

    stdout_stream.interface.flush() catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);
    stderr_stream.interface.flush() catch |err| return unwrapWriteError(err, &stdout_stream, &stderr_stream);
    return exit_code;
}

fn detectedRenderOptions(
    io: std.Io,
    stdout_file: std.Io.File,
    environ_map: *const std.process.Environ.Map,
) !RenderOptions {
    const no_color = if (environ_map.get("NO_COLOR")) |v| v.len != 0 else false;
    const force_color = if (environ_map.get("CLICOLOR_FORCE")) |v| v.len != 0 else false;
    const mode = try std.Io.Terminal.Mode.detect(io, stdout_file, no_color, force_color);
    return .{
        .enable_ansi = mode != .no_color,
        .ambiguous_width = term_terminal.detectAmbiguousWidthFromEnv(environ_map),
        .color_mode = term_terminal.detectColorModeFromEnv(environ_map),
    };
}

test {
    _ = @import("watch/session.zig");
}

test "renderSource writes rendered markdown for heading and list" {
    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try renderSource(
        allocator,
        "# Title\n\n- item\n",
        &buf.writer,
        null,
        .{ .enable_ansi = false },
    );

    try std.testing.expectEqualStrings("Title\n\n• item\n", buf.writer.buffered());
}

test "renderSource honors wrap_width for plain paragraph" {
    const allocator = std.testing.allocator;
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try renderSource(
        allocator,
        "alpha beta gamma delta\n",
        &buf.writer,
        10,
        .{ .enable_ansi = false },
    );

    try std.testing.expect(std.mem.indexOfScalar(u8, buf.writer.buffered(), '\n') != null);
}

test "renderFile reads from cwd and writes rendered output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "doc.md",
        .data = "## Hello\n",
    });

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try renderFile(
        allocator,
        io,
        tmp.dir,
        "doc.md",
        &buf.writer,
        null,
        .{ .enable_ansi = false },
    );

    try std.testing.expectEqualStrings("Hello\n", buf.writer.buffered());
}
