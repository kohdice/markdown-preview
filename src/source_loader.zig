const std = @import("std");
const builtin = @import("builtin");
const source_mod = @import("source");

// Keep small files on the buffered path; mmap setup cost is not free.
const mmap_threshold: u64 = 64 * 1024;
const file_reader_buffer_size: usize = 8 * 1024;

pub fn loadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) !source_mod.Source {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const size = stat.size;

    if (shouldMmap(size)) {
        if (mapFile(file.handle, size)) |mapped_bytes| {
            madviseSequential(mapped_bytes);
            return .{ .mapped = .{ .bytes = mapped_bytes } };
        } else |_| {}
    }

    return readFile(allocator, io, file, size);
}

fn shouldMmap(size: u64) bool {
    if (builtin.os.tag == .windows) return false;
    return size >= mmap_threshold;
}

fn mapFile(fd: std.posix.fd_t, size: u64) ![]align(std.heap.page_size_min) const u8 {
    if (size > std.math.maxInt(usize)) return error.FileTooLarge;
    const len: usize = @intCast(size);
    return std.posix.mmap(
        null,
        len,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    );
}

fn madviseSequential(bytes: []align(std.heap.page_size_min) const u8) void {
    const mut_ptr: [*]align(std.heap.page_size_min) u8 = @constCast(bytes.ptr);
    std.posix.madvise(mut_ptr, bytes.len, std.posix.MADV.SEQUENTIAL) catch {};
}

fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    size: u64,
) !source_mod.Source {
    if (size > std.math.maxInt(usize)) return error.FileTooLarge;
    const len: usize = @intCast(size);

    adviseSequential(file.handle, len);

    var buffer = try allocator.alloc(u8, len);
    errdefer allocator.free(buffer);

    var read_buf: [file_reader_buffer_size]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const filled = file_reader.interface.readSliceShort(buffer) catch |err| switch (err) {
        error.ReadFailed => return file_reader.err.?,
    };

    if (filled < len) {
        buffer = try allocator.realloc(buffer, filled);
    }

    return .{ .owned = .{ .allocator = allocator, .buffer = buffer } };
}

fn adviseSequential(fd: std.posix.fd_t, len: usize) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    _ = linux.fadvise(fd, 0, @intCast(len), linux.POSIX_FADV.SEQUENTIAL);
}

test "loadFile returns owned source for small files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data = "Hello, source_loader!\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "small.md", .data = data });

    const source = try loadFile(std.testing.allocator, io, tmp.dir, "small.md");
    defer source.owned.allocator.free(source.owned.buffer);

    try std.testing.expect(source == .owned);
    try std.testing.expectEqualStrings(data, source.bytes());
}

test "loadFile returns mapped source at or above mmap threshold" {
    if (builtin.os.tag == .windows) return;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data = try std.testing.allocator.alloc(u8, mmap_threshold);
    defer std.testing.allocator.free(data);
    @memset(data, 'a');
    data[data.len - 1] = '\n';

    try tmp.dir.writeFile(io, .{ .sub_path = "big.md", .data = data });

    const source = try loadFile(std.testing.allocator, io, tmp.dir, "big.md");
    defer std.posix.munmap(source.mapped.bytes);

    try std.testing.expect(source == .mapped);
    try std.testing.expectEqualSlices(u8, data, source.bytes());
}
