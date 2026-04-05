const std = @import("std");
const root = @import("root.zig");

const max_file_bytes = 10 * 1024 * 1024;

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
    if (args.len != 2) {
        try stderr.writeAll("Usage: mp <FILE>\nPreview a Markdown file in the terminal.\n");
        return 1;
    }

    const path = args[1];
    const source = dir.readFileAlloc(allocator, path, max_file_bytes) catch |err| {
        try stderr.print("mp: unable to read '{s}': {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    defer allocator.free(source);

    try root.renderMarkdown(allocator, stdout, source, .{
        .enable_ansi = enable_ansi,
        .theme = .solarized_dark,
        .wrap_width = wrap_width,
    });
    return 0;
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

    try std.testing.expectEqual(@as(u8, 1), exit_code);
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

    try std.testing.expectEqual(@as(u8, 1), exit_code);
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

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings(
        \\Hello
        \\- item
        \\
    ,
        stdout.writer.buffered(),
    );
    try std.testing.expectEqualStrings("", stderr.writer.buffered());
}
