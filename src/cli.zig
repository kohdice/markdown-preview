const std = @import("std");
const parse = @import("parse.zig");
const render = @import("render.zig");
const term = @import("term.zig");
const width = term.width;

const max_file_bytes = 10 * 1024 * 1024;
const exit_success: u8 = 0;
const exit_failure: u8 = 1;

pub const RunOptions = struct {
    allocator: std.mem.Allocator,
    cwd: std.fs.Dir,
    args: []const [:0]const u8,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    enable_ansi: bool,
    wrap_width: ?usize,
    ambiguous_width: width.AmbiguousWidth,
};

const usage_message =
    \\Usage: mp [--] <FILE>
    \\
    \\Preview a Markdown file in the terminal.
    \\Use -- before a file whose name starts with -- to disambiguate.
    \\
;

const ParsedArgs = struct {
    path: []const u8,
};

const ParseError = error{
    MissingPath,
    TooManyPositional,
    UnknownFlag,
};

fn parseArgs(args: []const [:0]const u8) ParseError!ParsedArgs {
    var path: ?[]const u8 = null;
    var positional_only = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!positional_only) {
            if (std.mem.eql(u8, arg, "--")) {
                positional_only = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--")) {
                return error.UnknownFlag;
            }
        }
        if (path != null) return error.TooManyPositional;
        path = arg;
    }

    if (path) |p| return .{ .path = p };
    return error.MissingPath;
}

pub fn unwrapWriteError(
    err: anyerror,
    stdout_err: ?anyerror,
    stderr_err: ?anyerror,
) anyerror {
    if (err == error.WriteFailed) {
        if (stdout_err) |underlying| return underlying;
        if (stderr_err) |underlying| return underlying;
    }
    return err;
}

pub fn run(opts: RunOptions) !u8 {
    const parsed = parseArgs(opts.args) catch {
        try opts.stderr.writeAll(usage_message);
        return exit_failure;
    };

    const source = opts.cwd.readFileAlloc(opts.allocator, parsed.path, max_file_bytes) catch |err| {
        try opts.stderr.print("mp: unable to read '{s}': {s}\n", .{ parsed.path, @errorName(err) });
        return exit_failure;
    };
    defer opts.allocator.free(source);

    var doc = try parse.parse(opts.allocator, source);
    defer doc.deinit(opts.allocator);

    try render.write(opts.allocator, opts.stdout, doc, .{
        .enable_ansi = opts.enable_ansi,
        .theme = .solarized_dark,
        .wrap_width = opts.wrap_width,
        .ambiguous_width = opts.ambiguous_width,
    });
    return exit_success;
}

test "parseArgs accepts plain positional path" {
    const args = [_][:0]const u8{ "mp", "foo.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expectEqualStrings("foo.md", parsed.path);
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
    try std.testing.expectEqualStrings("--notes.md", parsed.path);
}

test "parseArgs with -- sentinel still rejects duplicate positional" {
    const args = [_][:0]const u8{ "mp", "--", "a.md", "b.md" };
    try std.testing.expectError(error.TooManyPositional, parseArgs(&args));
}

test "run reports usage errors" {
    var stdout: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .cwd = std.fs.cwd(),
        .args = &.{"mp"},
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    try std.testing.expectEqual(exit_failure, exit_code);
    try std.testing.expectEqualStrings("", stdout.writer.buffered());
    try std.testing.expectEqualStrings(
        \\Usage: mp [--] <FILE>
        \\
        \\Preview a Markdown file in the terminal.
        \\Use -- before a file whose name starts with -- to disambiguate.
        \\
    ,
        stderr.writer.buffered(),
    );
}

test "run reports missing files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .cwd = tmp.dir,
        .args = &.{ "mp", "missing.md" },
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    });

    try std.testing.expectEqual(exit_failure, exit_code);
    try std.testing.expectEqualStrings("", stdout.writer.buffered());
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr.writer.buffered(), 1, "missing.md"));
}

test "run renders markdown files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "example.md",
        .data =
        \\# Hello
        \\- item
        \\
        ,
    });

    var stdout: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .cwd = tmp.dir,
        .args = &.{ "mp", "example.md" },
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "cont.md",
        .data = "- first line\n  continued\n",
    });

    var stdout: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(.{
        .allocator = std.testing.allocator,
        .cwd = tmp.dir,
        .args = &.{ "mp", "cont.md" },
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
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

test "unwrapWriteError passes through errors other than WriteFailed" {
    try std.testing.expectEqual(
        @as(anyerror, error.OutOfMemory),
        unwrapWriteError(error.OutOfMemory, error.AccessDenied, error.AccessDenied),
    );
}

test "unwrapWriteError surfaces stdout underlying error and prefers it over stderr" {
    try std.testing.expectEqual(
        @as(anyerror, error.NoSpaceLeft),
        unwrapWriteError(error.WriteFailed, error.NoSpaceLeft, error.AccessDenied),
    );
}

test "unwrapWriteError falls back to stderr underlying error when stdout has none" {
    try std.testing.expectEqual(
        @as(anyerror, error.AccessDenied),
        unwrapWriteError(error.WriteFailed, null, error.AccessDenied),
    );
}

test "unwrapWriteError returns WriteFailed unchanged when both underlying errors are null" {
    try std.testing.expectEqual(
        @as(anyerror, error.WriteFailed),
        unwrapWriteError(error.WriteFailed, null, null),
    );
}
