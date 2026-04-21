const std = @import("std");
const parse = @import("parse.zig");
const render = @import("render.zig");
const term = @import("term.zig");
const watch = @import("watch.zig");
const source_loader = @import("source_loader.zig");
const ansi = term.ansi;
const width = term.width;

const exit_success: u8 = 0;
const exit_failure: u8 = 1;

pub const RunOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    args: []const [:0]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    stdout_file: std.Io.File,
    stdin_file: std.Io.File,
    enable_ansi: bool,
    wrap_width: ?usize,
    ambiguous_width: width.AmbiguousWidth,
    color_mode: ansi.ColorMode = .truecolor,
};

const usage_message =
    \\Usage: mp [--watch] [--] <FILE>
    \\
    \\Preview a Markdown file in the terminal.
    \\Use --watch to live-reload on file changes.
    \\Use -- before a file whose name starts with -- to disambiguate.
    \\
;

pub const Command = union(enum) {
    render: RenderCommand,
    watch: WatchCommand,

    pub const RenderCommand = struct { path: []const u8 };
    pub const WatchCommand = struct { path: []const u8 };
};

const ParseError = error{
    MissingPath,
    TooManyPositional,
    UnknownFlag,
};

pub fn parseArgs(args: []const [:0]const u8) ParseError!Command {
    var path: ?[]const u8 = null;
    var positional_only = false;
    var watch_flag = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!positional_only) {
            if (std.mem.eql(u8, arg, "--")) {
                positional_only = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--watch")) {
                watch_flag = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--")) {
                return error.UnknownFlag;
            }
        }
        if (path != null) return error.TooManyPositional;
        path = arg;
    }

    const resolved_path = path orelse return error.MissingPath;
    if (watch_flag) return .{ .watch = .{ .path = resolved_path } };
    return .{ .render = .{ .path = resolved_path } };
}

pub fn run(opts: RunOptions) !u8 {
    const command = parseArgs(opts.args) catch {
        try opts.stderr.writeAll(usage_message);
        return exit_failure;
    };

    return executeCommand(opts, command);
}

pub fn executeCommand(opts: RunOptions, command: Command) !u8 {
    return switch (command) {
        .watch => |cmd| watch.run(.{
            .io = opts.io,
            .cwd = opts.cwd,
            .path = cmd.path,
            .stdout = opts.stdout,
            .stderr = opts.stderr,
            .stdout_file = opts.stdout_file,
            .stdin_file = opts.stdin_file,
            .enable_ansi = opts.enable_ansi,
            .ambiguous_width = opts.ambiguous_width,
            .color_mode = opts.color_mode,
        }),
        .render => |cmd| renderOnce(opts, cmd.path),
    };
}

fn renderOnce(opts: RunOptions, path: []const u8) !u8 {
    const source = source_loader.loadFile(opts.allocator, opts.io, opts.cwd, path) catch |err| {
        try opts.stderr.print("mp: unable to read '{s}': {s}\n", .{ path, @errorName(err) });
        return exit_failure;
    };

    var output = try parse.parse(opts.allocator, source);
    defer output.deinit();

    var renderer = render.Renderer.init(opts.allocator, .{
        .enable_ansi = opts.enable_ansi,
        .ambiguous_width = opts.ambiguous_width,
        .color_mode = opts.color_mode,
    });
    defer renderer.deinit();

    try renderer.render(opts.stdout, &output, opts.wrap_width);
    return exit_success;
}

const invalid_file: std.Io.File = .{
    .handle = -1,
    .flags = .{ .nonblocking = false },
};

test "parseArgs returns render command for plain positional path" {
    const args = [_][:0]const u8{ "mp", "foo.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .render);
    try std.testing.expectEqualStrings("foo.md", parsed.render.path);
}

test "parseArgs returns watch command when --watch precedes path" {
    const args = [_][:0]const u8{ "mp", "--watch", "foo.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .watch);
    try std.testing.expectEqualStrings("foo.md", parsed.watch.path);
}

test "parseArgs returns watch command when --watch follows path" {
    const args = [_][:0]const u8{ "mp", "foo.md", "--watch" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .watch);
    try std.testing.expectEqualStrings("foo.md", parsed.watch.path);
}

test "parseArgs returns watch command when --watch precedes -- sentinel" {
    const args = [_][:0]const u8{ "mp", "--watch", "--", "--notes.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .watch);
    try std.testing.expectEqualStrings("--notes.md", parsed.watch.path);
}

test "parseArgs rejects --watch without path" {
    const args = [_][:0]const u8{ "mp", "--watch" };
    try std.testing.expectError(error.MissingPath, parseArgs(&args));
}

test "parseArgs rejects unknown flag" {
    const args = [_][:0]const u8{ "mp", "--unknown", "bar.md" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(&args));
}

test "parseArgs rejects two positional args" {
    const args = [_][:0]const u8{ "mp", "foo.md", "bar.md" };
    try std.testing.expectError(error.TooManyPositional, parseArgs(&args));
}

test "parseArgs rejects no positional args" {
    const args = [_][:0]const u8{"mp"};
    try std.testing.expectError(error.MissingPath, parseArgs(&args));
}

test "parseArgs with -- sentinel treats following arg as positional even if it starts with --" {
    const args = [_][:0]const u8{ "mp", "--", "--notes.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .render);
    try std.testing.expectEqualStrings("--notes.md", parsed.render.path);
}

test "parseArgs with -- sentinel still rejects duplicate positional" {
    const args = [_][:0]const u8{ "mp", "--", "a.md", "b.md" };
    try std.testing.expectError(error.TooManyPositional, parseArgs(&args));
}

test "run reports usage errors" {
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cwd = std.Io.Dir.cwd(),
        .args = &.{"mp"},
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdout_file = invalid_file,
        .stdin_file = invalid_file,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    try std.testing.expectEqual(exit_failure, exit_code);
    try std.testing.expectEqualStrings("", stdout.writer.buffered());
    try std.testing.expectEqualStrings(
        \\Usage: mp [--watch] [--] <FILE>
        \\
        \\Preview a Markdown file in the terminal.
        \\Use --watch to live-reload on file changes.
        \\Use -- before a file whose name starts with -- to disambiguate.
        \\
    ,
        stderr.writer.buffered(),
    );
}

test "run reports missing files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .io = io,
        .cwd = tmp.dir,
        .args = &.{ "mp", "missing.md" },
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdout_file = invalid_file,
        .stdin_file = invalid_file,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    try std.testing.expectEqual(exit_failure, exit_code);
    try std.testing.expectEqualStrings("", stdout.writer.buffered());
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr.writer.buffered(), 1, "missing.md"));
}

test "run renders markdown files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "example.md",
        .data =
        \\# Hello
        \\- item
        \\
        ,
    });

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .io = io,
        .cwd = tmp.dir,
        .args = &.{ "mp", "example.md" },
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdout_file = invalid_file,
        .stdin_file = invalid_file,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    try std.testing.expectEqual(exit_success, exit_code);
    try std.testing.expectEqualStrings(
        \\Hello
        \\• item
        \\
    ,
        stdout.writer.buffered(),
    );
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
}

test "run threads ambiguous_width through to the renderer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "cont.md",
        .data = "- first line\n  continued\n",
    });

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .io = io,
        .cwd = tmp.dir,
        .args = &.{ "mp", "cont.md" },
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdout_file = invalid_file,
        .stdin_file = invalid_file,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .wide,
    });

    try std.testing.expectEqual(exit_success, exit_code);
    try std.testing.expectEqualStrings(
        "• first line\n   continued\n",
        stdout.writer.buffered(),
    );
}

test "run frees the file buffer carried by the source loader" {
    const io = std.testing.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.testing.expect(status == .ok) catch @panic("gpa leak");
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "owned.md",
        .data = "# Owned\n",
    });

    var stdout: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(gpa.allocator());
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = gpa.allocator(),
        .io = io,
        .cwd = tmp.dir,
        .args = &.{ "mp", "owned.md" },
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdout_file = invalid_file,
        .stdin_file = invalid_file,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    try std.testing.expectEqual(exit_success, exit_code);
    try std.testing.expectEqualStrings("Owned\n", stdout.writer.buffered());
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
}
