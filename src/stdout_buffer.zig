const std = @import("std");

pub const tty_size: usize = 16 * 1024;
pub const pipe_size: usize = 64 * 1024;
pub const file_floor: usize = 64 * 1024;
pub const file_ceiling: usize = 256 * 1024;

pub const Kind = enum { tty, pipe, file };

pub fn sizeFor(io: std.Io, file: std.Io.File) !usize {
    const kind = try classifyFile(io, file);
    return switch (kind) {
        .tty => tty_size,
        .pipe => pipe_size,
        .file => fileBlockSize(io, file),
    };
}

pub fn classifyFile(io: std.Io, file: std.Io.File) !Kind {
    if (try file.isTty(io)) return .tty;
    const stat = file.stat(io) catch return .pipe;
    return switch (stat.kind) {
        .file => .file,
        else => .pipe,
    };
}

fn fileBlockSize(io: std.Io, file: std.Io.File) usize {
    const stat = file.stat(io) catch return clamp(file_floor);
    const raw: usize = stat.block_size;
    if (raw == 0) return clamp(file_floor);
    return clamp(raw);
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
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile(io, "buf_classify.txt", .{ .read = true });
    defer f.close(io);
    try std.testing.expectEqual(Kind.file, try classifyFile(io, f));
}

test "classifyFile labels /dev/null as .pipe, not .tty" {
    const io = std.testing.io;
    var dev_null = std.Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .read_write }) catch return;
    defer dev_null.close(io);
    try std.testing.expect((try classifyFile(io, dev_null)) != .tty);
}

test "sizeFor on a regular file clamps to the 64-256 KiB range" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile(io, "buf_size.txt", .{ .read = true });
    defer f.close(io);
    const size = try sizeFor(io, f);
    try std.testing.expect(size >= file_floor);
    try std.testing.expect(size <= file_ceiling);
}
