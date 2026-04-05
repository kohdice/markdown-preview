const std = @import("std");
const document = @import("document.zig");
const render = @import("render.zig");
const theme = @import("theme.zig");

pub fn runWithDir(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    args: []const []const u8,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    enable_ansi: bool,
) !u8 {
    var selected_theme: theme.Theme = .solarized_dark;
    var file_path: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--theme=")) {
            const name = arg["--theme=".len..];
            selected_theme = theme.Theme.fromString(name) orelse {
                try stderr.print("mp: unknown theme '{s}'\nAvailable themes: {s}\n", .{ name, theme.Theme.available });
                return 1;
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try stderr.print("mp: unknown option '{s}'\n", .{arg});
            try writeUsage(stderr);
            return 1;
        } else {
            if (file_path != null) {
                try writeUsage(stderr);
                return 1;
            }
            file_path = arg;
        }
    }

    const path = file_path orelse {
        try writeUsage(stderr);
        return 1;
    };

    const source = document.readFile(allocator, dir, path) catch |err| {
        try stderr.print("mp: unable to read '{s}': {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    defer allocator.free(source);

    try render.renderMarkdown(allocator, stdout, source, .{
        .enable_ansi = enable_ansi,
        .theme = selected_theme,
    });
    return 0;
}

fn writeUsage(writer: *std.io.Writer) !void {
    try writer.writeAll("Usage: mp [--theme=NAME] <FILE>\nPreview a Markdown file in the terminal.\n\nAvailable themes: " ++ theme.Theme.available ++ "\n");
}

test "runWithDir reports usage errors" {
    var stdout: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try runWithDir(
        std.testing.allocator,
        std.fs.cwd(),
        &.{"mp"},
        &stdout.writer,
        &stderr.writer,
        false,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout.writer.buffered());
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr.writer.buffered(), 1, "Usage: mp"));
}

test "runWithDir reports missing files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var stdout: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit_code = try runWithDir(
        std.testing.allocator,
        tmp.dir,
        &.{ "mp", "missing.md" },
        &stdout.writer,
        &stderr.writer,
        false,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    try std.testing.expectEqualStrings("", stdout.writer.buffered());
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr.writer.buffered(), 1, "missing.md"));
}

test "runWithDir renders markdown files" {
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

    const exit_code = try runWithDir(
        std.testing.allocator,
        tmp.dir,
        &.{ "mp", "example.md" },
        &stdout.writer,
        &stderr.writer,
        false,
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
