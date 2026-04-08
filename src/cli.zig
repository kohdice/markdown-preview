const std = @import("std");
const render = @import("render.zig");
const width = @import("width.zig");

const max_file_bytes = 10 * 1024 * 1024;
const exit_success: u8 = 0;
const exit_failure: u8 = 1;

const usage_message =
    "Usage: mp [--ambiguous-width=narrow|wide] [--] <FILE>\nPreview a Markdown file in the terminal.\nUse -- before a file whose name starts with -- to disambiguate.\n";

pub const ParsedArgs = struct {
    path: []const u8,
    ambiguous_width: width.AmbiguousWidth,
};

pub const ParseError = error{
    MissingPath,
    TooManyPositional,
    UnknownFlag,
    InvalidAmbiguousWidth,
};

pub fn parseArgs(args: []const []const u8) ParseError!ParsedArgs {
    var path: ?[]const u8 = null;
    var ambiguous: width.AmbiguousWidth = .narrow;
    var positional_only = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!positional_only) {
            if (std.mem.eql(u8, arg, "--")) {
                positional_only = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--ambiguous-width=")) {
                const value = arg["--ambiguous-width=".len..];
                if (std.mem.eql(u8, value, "narrow")) {
                    ambiguous = .narrow;
                } else if (std.mem.eql(u8, value, "wide")) {
                    ambiguous = .wide;
                } else {
                    return error.InvalidAmbiguousWidth;
                }
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--")) {
                return error.UnknownFlag;
            }
        }
        if (path != null) return error.TooManyPositional;
        path = arg;
    }

    if (path) |p| return .{ .path = p, .ambiguous_width = ambiguous };
    return error.MissingPath;
}

pub fn getTerminalWidth(handle: std.posix.fd_t) ?usize {
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = std.posix.system.ioctl(handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(err) == .SUCCESS and winsize.col > 0) {
        return @intCast(winsize.col);
    }
    return null;
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

pub fn run(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    args: []const []const u8,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    enable_ansi: bool,
    wrap_width: ?usize,
) !u8 {
    const parsed = parseArgs(args) catch {
        try stderr.writeAll(usage_message);
        return exit_failure;
    };

    const source = dir.readFileAlloc(allocator, parsed.path, max_file_bytes) catch |err| {
        try stderr.print("mp: unable to read '{s}': {s}\n", .{ parsed.path, @errorName(err) });
        return exit_failure;
    };
    defer allocator.free(source);

    try render.renderMarkdown(allocator, stdout, source, .{
        .enable_ansi = enable_ansi,
        .theme = .solarized_dark,
        .wrap_width = wrap_width,
        .ambiguous_width = parsed.ambiguous_width,
    });
    return exit_success;
}

test "parseArgs accepts plain positional path" {
    const args = [_][]const u8{ "mp", "foo.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expectEqualStrings("foo.md", parsed.path);
    try std.testing.expectEqual(width.AmbiguousWidth.narrow, parsed.ambiguous_width);
}

test "parseArgs accepts --ambiguous-width=wide before path" {
    const args = [_][]const u8{ "mp", "--ambiguous-width=wide", "foo.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expectEqualStrings("foo.md", parsed.path);
    try std.testing.expectEqual(width.AmbiguousWidth.wide, parsed.ambiguous_width);
}

test "parseArgs accepts --ambiguous-width=wide after path" {
    const args = [_][]const u8{ "mp", "foo.md", "--ambiguous-width=wide" };
    const parsed = try parseArgs(&args);
    try std.testing.expectEqualStrings("foo.md", parsed.path);
    try std.testing.expectEqual(width.AmbiguousWidth.wide, parsed.ambiguous_width);
}

test "parseArgs accepts --ambiguous-width=narrow explicitly" {
    const args = [_][]const u8{ "mp", "--ambiguous-width=narrow", "foo.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expectEqual(width.AmbiguousWidth.narrow, parsed.ambiguous_width);
}

test "parseArgs rejects invalid ambiguous-width value" {
    const args = [_][]const u8{ "mp", "--ambiguous-width=foo", "bar.md" };
    try std.testing.expectError(error.InvalidAmbiguousWidth, parseArgs(&args));
}

test "parseArgs rejects unknown flag" {
    const args = [_][]const u8{ "mp", "--unknown", "bar.md" };
    try std.testing.expectError(error.UnknownFlag, parseArgs(&args));
}

test "parseArgs rejects two positional args" {
    const args = [_][]const u8{ "mp", "foo.md", "bar.md" };
    try std.testing.expectError(error.TooManyPositional, parseArgs(&args));
}

test "parseArgs rejects no positional args" {
    const args = [_][]const u8{"mp"};
    try std.testing.expectError(error.MissingPath, parseArgs(&args));
}

test "parseArgs with -- sentinel treats following arg as positional even if it starts with --" {
    const args = [_][]const u8{ "mp", "--", "--notes.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expectEqualStrings("--notes.md", parsed.path);
    try std.testing.expectEqual(width.AmbiguousWidth.narrow, parsed.ambiguous_width);
}

test "parseArgs with -- sentinel preserves prior flags" {
    const args = [_][]const u8{ "mp", "--ambiguous-width=wide", "--", "--weird-name.md" };
    const parsed = try parseArgs(&args);
    try std.testing.expectEqualStrings("--weird-name.md", parsed.path);
    try std.testing.expectEqual(width.AmbiguousWidth.wide, parsed.ambiguous_width);
}

test "parseArgs with -- sentinel still rejects duplicate positional" {
    const args = [_][]const u8{ "mp", "--", "a.md", "b.md" };
    try std.testing.expectError(error.TooManyPositional, parseArgs(&args));
}

test "run reports usage errors" {
    var stdout: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try run(
        std.testing.allocator,
        std.fs.cwd(),
        &.{"mp"},
        &stdout.writer,
        &stderr.writer,
        false,
        null,
    );

    try std.testing.expectEqual(exit_failure, exit_code);
    try std.testing.expectEqualStrings("", stdout.writer.buffered());
    try std.testing.expectEqualStrings(
        "Usage: mp [--ambiguous-width=narrow|wide] [--] <FILE>\nPreview a Markdown file in the terminal.\nUse -- before a file whose name starts with -- to disambiguate.\n",
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

    const exit_code = try run(
        std.testing.allocator,
        tmp.dir,
        &.{ "mp", "missing.md" },
        &stdout.writer,
        &stderr.writer,
        false,
        null,
    );

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

    const exit_code = try run(
        std.testing.allocator,
        tmp.dir,
        &.{ "mp", "example.md" },
        &stdout.writer,
        &stderr.writer,
        false,
        null,
    );

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
