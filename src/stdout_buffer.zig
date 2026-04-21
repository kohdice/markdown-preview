const std = @import("std");
const builtin = @import("builtin");

pub const tty_size: usize = 16 * 1024;
pub const pipe_size: usize = 64 * 1024;
pub const file_floor: usize = 64 * 1024;
pub const file_ceiling: usize = 256 * 1024;

pub const Kind = enum { tty, pipe, file };

pub fn sizeFor(file: std.fs.File) usize {
    return switch (classifyFile(file)) {
        .tty => tty_size,
        .pipe => pipe_size,
        .file => fileBlockSize(file.handle),
    };
}

pub fn classifyFile(file: std.fs.File) Kind {
    if (std.posix.isatty(file.handle)) return .tty;
    const stat = file.stat() catch return .pipe;
    return switch (stat.kind) {
        .file => .file,
        else => .pipe,
    };
}

fn fileBlockSize(handle: std.posix.fd_t) usize {
    if (builtin.os.tag == .windows) return clamp(file_floor);
    const stat = std.posix.fstat(handle) catch return clamp(file_floor);
    const raw: isize = @intCast(stat.blksize);
    if (raw <= 0) return clamp(file_floor);
    return clamp(@intCast(raw));
}

pub fn clamp(block_size: usize) usize {
    if (block_size < file_floor) return file_floor;
    if (block_size > file_ceiling) return file_ceiling;
    return block_size;
}

test "clamp returns floor when block size is below floor" {
    try std.testing.expectEqual(file_floor, clamp(0));
    try std.testing.expectEqual(file_floor, clamp(1024));
    try std.testing.expectEqual(file_floor, clamp(file_floor - 1));
}

test "clamp preserves block size within the valid range" {
    try std.testing.expectEqual(file_floor, clamp(file_floor));
    try std.testing.expectEqual(@as(usize, 128 * 1024), clamp(128 * 1024));
    try std.testing.expectEqual(file_ceiling, clamp(file_ceiling));
}

test "clamp caps at ceiling when block size is above ceiling" {
    try std.testing.expectEqual(file_ceiling, clamp(file_ceiling + 1));
    try std.testing.expectEqual(file_ceiling, clamp(1 << 20));
}

test "classifyFile labels a regular file as .file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile("buf_classify.txt", .{ .read = true });
    defer f.close();
    try std.testing.expectEqual(Kind.file, classifyFile(f));
}

test "classifyFile labels /dev/null as .pipe, not .tty" {
    if (builtin.os.tag == .windows) return;
    var dev_null = std.fs.openFileAbsolute("/dev/null", .{ .mode = .read_write }) catch return;
    defer dev_null.close();
    try std.testing.expect(classifyFile(dev_null) != .tty);
}

test "sizeFor on a regular file clamps to the 64-256 KiB range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile("buf_size.txt", .{ .read = true });
    defer f.close();
    const size = sizeFor(f);
    try std.testing.expect(size >= file_floor);
    try std.testing.expect(size <= file_ceiling);
}
