const std = @import("std");
const root = @import("markdown_preview");

const max_file_bytes = 10 * 1024 * 1024;
const expected_arg_count = 2;
/// POSIX exit codes. Zig's std does not expose platform-neutral names, so
/// we define them locally to avoid naked numeric returns.
const exit_success: u8 = 0;
const exit_failure: u8 = 1;

pub fn getTerminalWidth(handle: std.posix.fd_t) ?usize {
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = std.posix.system.ioctl(handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(err) == .SUCCESS and winsize.col > 0) {
        return @intCast(winsize.col);
    }
    return null;
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
    if (args.len != expected_arg_count) {
        try stderr.writeAll("Usage: mp <FILE>\nPreview a Markdown file in the terminal.\n");
        return exit_failure;
    }

    const path = args[1];
    const source = dir.readFileAlloc(allocator, path, max_file_bytes) catch |err| {
        try stderr.print("mp: unable to read '{s}': {s}\n", .{ path, @errorName(err) });
        return exit_failure;
    };
    defer allocator.free(source);

    try root.renderMarkdown(allocator, stdout, source, .{
        .enable_ansi = enable_ansi,
        .theme = .solarized_dark,
        .wrap_width = wrap_width,
    });
    return exit_success;
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
        "Usage: mp <FILE>\nPreview a Markdown file in the terminal.\n",
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
        \\- item
        \\
    ,
        stdout.writer.buffered(),
    );
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
}
