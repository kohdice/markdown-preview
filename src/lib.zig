const std = @import("std");
const parse_mod = @import("parse.zig");
const render_mod = @import("render.zig");
const source_loader_mod = @import("source_loader.zig");
const stdout_buffer_mod = @import("stdout_buffer.zig");
const term_ansi = @import("term/ansi.zig");
const term_terminal = @import("term/terminal.zig");
const term_width = @import("term/width.zig");
const watch_orchestrator = @import("watch/orchestrator.zig");

pub const RenderOptions = render_mod.RenderOptions;
pub const AmbiguousWidth = term_width.AmbiguousWidth;
pub const ColorMode = term_ansi.ColorMode;

pub fn renderSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    writer: *std.io.Writer,
    wrap_width: ?usize,
    options: RenderOptions,
) !void {
    var doc = try parse_mod.parse(allocator, .{ .borrowed = source });
    defer doc.deinit();

    var renderer = render_mod.Renderer.init(allocator, options);
    defer renderer.deinit();

    try renderer.render(writer, &doc, wrap_width);
}

pub fn renderFile(
    allocator: std.mem.Allocator,
    cwd: std.fs.Dir,
    path: []const u8,
    writer: *std.io.Writer,
    wrap_width: ?usize,
    options: RenderOptions,
) !void {
    const src = try source_loader_mod.loadFile(allocator, cwd, path);
    var doc = try parse_mod.parse(allocator, src);
    defer doc.deinit();

    var renderer = render_mod.Renderer.init(allocator, options);
    defer renderer.deinit();

    try renderer.render(writer, &doc, wrap_width);
}

/// Semantic watch-mode request. The facade opens stdio and detects the
/// terminal itself, so callers don't plumb writers or handles through.
/// `render_options == null` auto-detects ANSI/color/ambiguous-width.
pub const WatchRequest = struct {
    allocator: std.mem.Allocator,
    cwd: std.fs.Dir,
    path: []const u8,
    render_options: ?RenderOptions = null,
};

/// Live-preview `request.path` on the process's stdout until the user quits.
/// Requires stdin and stdout to be interactive TTYs.
pub fn watchFile(request: WatchRequest) !u8 {
    const stdout_file = std.fs.File.stdout();
    const stderr_file = std.fs.File.stderr();
    const stdin_file = std.fs.File.stdin();

    const stdout_buffer = try request.allocator.alloc(u8, stdout_buffer_mod.sizeFor(stdout_file));
    defer request.allocator.free(stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;

    var stdout_stream = stdout_file.writer(stdout_buffer);
    var stderr_stream = stderr_file.writer(&stderr_buffer);

    const options = request.render_options orelse detectedRenderOptions(stdout_file);

    const exit_code = try watch_orchestrator.run(.{
        .cwd = request.cwd,
        .path = request.path,
        .stdout = &stdout_stream.interface,
        .stderr = &stderr_stream.interface,
        .stdout_handle = stdout_file.handle,
        .stdin_handle = stdin_file.handle,
        .enable_ansi = options.enable_ansi,
        .ambiguous_width = options.ambiguous_width,
        .color_mode = options.color_mode,
    });

    try stdout_stream.interface.flush();
    try stderr_stream.interface.flush();
    return exit_code;
}

fn detectedRenderOptions(stdout_file: std.fs.File) RenderOptions {
    const enable_ansi = switch (std.io.tty.Config.detect(stdout_file)) {
        .escape_codes, .windows_api => true,
        .no_color => false,
    };
    return .{
        .enable_ansi = enable_ansi,
        .ambiguous_width = term_terminal.detectAmbiguousWidthFromProcess(),
        .color_mode = term_terminal.detectColorModeFromProcess(),
    };
}

test "renderSource writes rendered markdown for heading and list" {
    const allocator = std.testing.allocator;
    var buf: std.io.Writer.Allocating = .init(allocator);
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

test "renderSource honors wrap_width for trivial paragraph" {
    const allocator = std.testing.allocator;
    var buf: std.io.Writer.Allocating = .init(allocator);
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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "doc.md",
        .data = "## Hello\n",
    });

    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try renderFile(
        allocator,
        tmp.dir,
        "doc.md",
        &buf.writer,
        null,
        .{ .enable_ansi = false },
    );

    try std.testing.expectEqualStrings("Hello\n", buf.writer.buffered());
}
