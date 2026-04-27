const std = @import("std");
const parse = @import("parse.zig");
const render = @import("render.zig");
const term = @import("term.zig");
const watch = @import("watch/orchestrator.zig");
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
    version: []const u8,
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
    \\Usage: mp [options] [--] <FILE>
    \\
    \\Preview a Markdown file in the terminal.
    \\
    \\Options:
    \\  --width <COLUMNS>  Override wrapping width for one-shot file rendering
    \\  --watch            Live-reload in an interactive terminal
    \\  --version          Show version number and quit
    \\  -h, --help         Show this help and quit
    \\  --                 Treat the next argument as FILE
    \\
;

pub const Command = union(enum) {
    render: RenderCommand,
    watch: WatchCommand,
    version,
    help,

    pub const RenderCommand = struct {
        path: []const u8,
        width_override: ?usize,
    };
    pub const WatchCommand = struct { path: []const u8 };
};

const ParseError = error{
    MissingPath,
    MissingWidth,
    InvalidWidth,
    DuplicateWidth,
    WidthWithWatch,
    TooManyPositional,
    UnknownFlag,
};

pub fn parseArgs(args: []const [:0]const u8) ParseError!Command {
    var path: ?[]const u8 = null;
    var width_override: ?usize = null;
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
            if (std.mem.eql(u8, arg, "--width")) {
                if (width_override != null) return error.DuplicateWidth;
                i += 1;
                if (i >= args.len) return error.MissingWidth;
                width_override = try parseWidth(args[i]);
                continue;
            }
            if (std.mem.eql(u8, arg, "--version")) {
                return .version;
            }
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                return .help;
            }
            if (std.mem.startsWith(u8, arg, "--")) {
                return error.UnknownFlag;
            }
        }
        if (path != null) return error.TooManyPositional;
        path = arg;
    }

    const resolved_path = path orelse return error.MissingPath;
    if (watch_flag and width_override != null) return error.WidthWithWatch;
    if (watch_flag) return .{ .watch = .{ .path = resolved_path } };
    return .{ .render = .{ .path = resolved_path, .width_override = width_override } };
}

fn parseWidth(value: []const u8) ParseError!usize {
    const parsed = std.fmt.parseInt(usize, value, 10) catch return error.InvalidWidth;
    if (parsed == 0) return error.InvalidWidth;
    return parsed;
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
            .allocator = opts.allocator,
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
        .render => |cmd| renderOnce(opts, cmd.path, cmd.width_override),
        .version => writeVersion(opts.stdout, opts.version),
        .help => writeHelp(opts.stdout),
    };
}

fn writeHelp(stdout: *std.Io.Writer) !u8 {
    try stdout.writeAll(usage_message);
    return exit_success;
}

fn writeVersion(stdout: *std.Io.Writer, version: []const u8) !u8 {
    try stdout.print("mp (markdown-preview) {s}\n", .{version});
    return exit_success;
}

fn renderOnce(opts: RunOptions, path: []const u8, width_override: ?usize) !u8 {
    const source = source_loader.loadFile(opts.allocator, opts.io, opts.cwd, path) catch |err| {
        try opts.stderr.print("mp: unable to read '{s}': {s}\n", .{ path, @errorName(err) });
        return exit_failure;
    };

    var doc = try parse.parse(opts.allocator, source);
    defer doc.deinit();

    var renderer = render.Renderer.init(opts.allocator, .{
        .enable_ansi = opts.enable_ansi,
        .ambiguous_width = opts.ambiguous_width,
        .color_mode = opts.color_mode,
    });
    defer renderer.deinit();

    try renderer.render(opts.stdout, &doc, width_override orelse opts.wrap_width, opts.allocator);
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
    try std.testing.expectEqual(@as(?usize, null), parsed.render.width_override);
}

test "parseArgs records width when --width precedes path" {
    const args = [_][:0]const u8{ "mp", "--width", "72", "foo.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .render);
    try std.testing.expectEqualStrings("foo.md", parsed.render.path);
    try std.testing.expectEqual(@as(?usize, 72), parsed.render.width_override);
}

test "parseArgs records width when --width follows path" {
    const args = [_][:0]const u8{ "mp", "foo.md", "--width", "72" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .render);
    try std.testing.expectEqualStrings("foo.md", parsed.render.path);
    try std.testing.expectEqual(@as(?usize, 72), parsed.render.width_override);
}

test "parseArgs treats --width after -- as a render path" {
    const args = [_][:0]const u8{ "mp", "--", "--width" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .render);
    try std.testing.expectEqualStrings("--width", parsed.render.path);
    try std.testing.expectEqual(@as(?usize, null), parsed.render.width_override);
}

test "parseArgs rejects --width without a value" {
    const args = [_][:0]const u8{ "mp", "--width" };
    try std.testing.expectError(error.MissingWidth, parseArgs(&args));
}

test "parseArgs rejects non-numeric --width value" {
    const args = [_][:0]const u8{ "mp", "--width", "wide", "foo.md" };
    try std.testing.expectError(error.InvalidWidth, parseArgs(&args));
}

test "parseArgs rejects zero --width value" {
    const args = [_][:0]const u8{ "mp", "--width", "0", "foo.md" };
    try std.testing.expectError(error.InvalidWidth, parseArgs(&args));
}

test "parseArgs rejects duplicate --width values" {
    const args = [_][:0]const u8{ "mp", "--width", "72", "foo.md", "--width", "80" };
    try std.testing.expectError(error.DuplicateWidth, parseArgs(&args));
}

test "parseArgs rejects --width with --watch" {
    const args = [_][:0]const u8{ "mp", "--watch", "--width", "72", "foo.md" };
    try std.testing.expectError(error.WidthWithWatch, parseArgs(&args));
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

test "parseArgs returns version command for exact --version invocation" {
    const args = [_][:0]const u8{ "mp", "--version" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .version);
}

test "parseArgs ignores trailing operands after --version" {
    const args = [_][:0]const u8{ "mp", "--version", "extra.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .version);
}

test "parseArgs lets --version take precedence over watch and render arguments" {
    const args = [_][:0]const u8{ "mp", "--watch", "--version", "example.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .version);
}

test "parseArgs lets --version take precedence after a render path" {
    const args = [_][:0]const u8{ "mp", "README.md", "--version" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .version);
}

test "parseArgs returns help command for --help" {
    const args = [_][:0]const u8{ "mp", "--help" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .help);
}

test "parseArgs returns help command for -h" {
    const args = [_][:0]const u8{ "mp", "-h" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .help);
}

test "parseArgs treats bare version as a render path" {
    const args = [_][:0]const u8{ "mp", "version" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .render);
    try std.testing.expectEqualStrings("version", parsed.render.path);
}

test "parseArgs treats --version after -- as a render path" {
    const args = [_][:0]const u8{ "mp", "--", "--version" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .render);
    try std.testing.expectEqualStrings("--version", parsed.render.path);
}

test "parseArgs treats --help after -- as a render path" {
    const args = [_][:0]const u8{ "mp", "--", "--help" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .render);
    try std.testing.expectEqualStrings("--help", parsed.render.path);
}

test "parseArgs keeps version as a watch path when --watch is present" {
    const args = [_][:0]const u8{ "mp", "--watch", "version" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .watch);
    try std.testing.expectEqualStrings("version", parsed.watch.path);
}

test "parseArgs keeps version as a render path after the -- sentinel" {
    const args = [_][:0]const u8{ "mp", "--", "version" };
    const parsed = try parseArgs(&args);
    try std.testing.expect(parsed == .render);
    try std.testing.expectEqualStrings("version", parsed.render.path);
}

test "parseArgs rejects extra positional arguments after a bare version path" {
    const args = [_][:0]const u8{ "mp", "version", "extra" };
    try std.testing.expectError(error.TooManyPositional, parseArgs(&args));
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
        .version = "",
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
        \\Usage: mp [options] [--] <FILE>
        \\
        \\Preview a Markdown file in the terminal.
        \\
        \\Options:
        \\  --width <COLUMNS>  Override wrapping width for one-shot file rendering
        \\  --watch            Live-reload in an interactive terminal
        \\  --version          Show version number and quit
        \\  -h, --help         Show this help and quit
        \\  --                 Treat the next argument as FILE
        \\
    ,
        stderr.writer.buffered(),
    );
}

test "run writes help information for width and watch options" {
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cwd = std.Io.Dir.cwd(),
        .args = &.{ "mp", "--help" },
        .version = "",
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
        \\Usage: mp [options] [--] <FILE>
        \\
        \\Preview a Markdown file in the terminal.
        \\
        \\Options:
        \\  --width <COLUMNS>  Override wrapping width for one-shot file rendering
        \\  --watch            Live-reload in an interactive terminal
        \\  --version          Show version number and quit
        \\  -h, --help         Show this help and quit
        \\  --                 Treat the next argument as FILE
        \\
    ,
        stdout.writer.buffered(),
    );
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
}

test "run writes compact version information for the version option" {
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cwd = std.Io.Dir.cwd(),
        .args = &.{ "mp", "--version" },
        .version = "1.2.3",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdout_file = invalid_file,
        .stdin_file = invalid_file,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    try std.testing.expectEqual(exit_success, exit_code);
    try std.testing.expectEqualStrings("mp (markdown-preview) 1.2.3\n", stdout.writer.buffered());
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
}

test "run renders a file literally named version" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "version",
        .data = "# Version File\n",
    });

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .io = io,
        .cwd = tmp.dir,
        .args = &.{ "mp", "version" },
        .version = "",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdout_file = invalid_file,
        .stdin_file = invalid_file,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    try std.testing.expectEqual(exit_success, exit_code);
    try std.testing.expectEqualStrings("Version File\n", stdout.writer.buffered());
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
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
        .version = "",
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

test "run reports missing files with --width like default file rendering" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var default_stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer default_stdout.deinit();
    var default_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer default_stderr.deinit();

    const default_exit_code = try run(.{
        .allocator = std.testing.allocator,
        .io = io,
        .cwd = tmp.dir,
        .args = &.{ "mp", "missing.md" },
        .version = "",
        .stdout = &default_stdout.writer,
        .stderr = &default_stderr.writer,
        .stdout_file = invalid_file,
        .stdin_file = invalid_file,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    var width_stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer width_stdout.deinit();
    var width_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer width_stderr.deinit();

    const width_exit_code = try run(.{
        .allocator = std.testing.allocator,
        .io = io,
        .cwd = tmp.dir,
        .args = &.{ "mp", "--width", "8", "missing.md" },
        .version = "",
        .stdout = &width_stdout.writer,
        .stderr = &width_stderr.writer,
        .stdout_file = invalid_file,
        .stdin_file = invalid_file,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    try std.testing.expectEqual(default_exit_code, width_exit_code);
    try std.testing.expectEqual(exit_failure, width_exit_code);
    try std.testing.expectEqualStrings(default_stdout.writer.buffered(), width_stdout.writer.buffered());
    try std.testing.expectEqualStrings(default_stderr.writer.buffered(), width_stderr.writer.buffered());
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
        .version = "",
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

test "run uses detected wrap width when --width is not provided" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "plain.md",
        .data = "Hello World",
    });

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .io = io,
        .cwd = tmp.dir,
        .args = &.{ "mp", "plain.md" },
        .version = "",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdout_file = invalid_file,
        .stdin_file = invalid_file,
        .enable_ansi = false,
        .wrap_width = 8,
        .ambiguous_width = .narrow,
    });

    try std.testing.expectEqual(exit_success, exit_code);
    try std.testing.expectEqualStrings("Hello\nWorld", stdout.writer.buffered());
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
}

test "run applies --width when detected wrap width is absent" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "plain.md",
        .data = "Hello World",
    });

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .io = io,
        .cwd = tmp.dir,
        .args = &.{ "mp", "--width", "8", "plain.md" },
        .version = "",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdout_file = invalid_file,
        .stdin_file = invalid_file,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    try std.testing.expectEqual(exit_success, exit_code);
    try std.testing.expectEqualStrings("Hello\nWorld", stdout.writer.buffered());
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
}

test "run lets --width override detected wrap width" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "plain.md",
        .data = "Hello World",
    });

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .io = io,
        .cwd = tmp.dir,
        .args = &.{ "mp", "plain.md", "--width", "8" },
        .version = "",
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .stdout_file = invalid_file,
        .stdin_file = invalid_file,
        .enable_ansi = false,
        .wrap_width = 80,
        .ambiguous_width = .narrow,
    });

    try std.testing.expectEqual(exit_success, exit_code);
    try std.testing.expectEqualStrings("Hello\nWorld", stdout.writer.buffered());
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
        .version = "",
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
        .version = "",
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
