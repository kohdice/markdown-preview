const std = @import("std");
const builtin = @import("builtin");
const ast = @import("ast.zig");

const mmap_threshold: u64 = 64 * 1024;

pub const Loaded = struct {
    bytes: []const u8,
    storage: Storage,

    pub const Storage = union(enum) {
        owned: ast.Document.OwnedSource,
        mapped: ast.Document.MappedSource,
    };
};

pub fn loadFile(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    path: []const u8,
) !Loaded {
    var file = try dir.openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size = stat.size;

    if (shouldMmap(size)) {
        if (mapFile(file.handle, size)) |mapped_bytes| {
            madviseSequential(mapped_bytes);
            return .{
                .bytes = mapped_bytes,
                .storage = .{ .mapped = .{ .bytes = mapped_bytes } },
            };
        } else |_| {}
    }

    return readFile(allocator, file, size);
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
        std.posix.PROT.READ,
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
    file: std.fs.File,
    size: u64,
) !Loaded {
    if (size > std.math.maxInt(usize)) return error.FileTooLarge;
    const len: usize = @intCast(size);
    var buffer = try allocator.alloc(u8, len);
    errdefer allocator.free(buffer);

    var filled: usize = 0;
    while (filled < len) {
        const n = try file.read(buffer[filled..]);
        if (n == 0) break;
        filled += n;
    }

    if (filled < len) {
        buffer = try allocator.realloc(buffer, filled);
    }

    return .{
        .bytes = buffer,
        .storage = .{ .owned = .{ .allocator = allocator, .buffer = buffer } },
    };
}

test "loadFile returns owned storage for small files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data = "Hello, source_loader!\n";
    try tmp.dir.writeFile(.{ .sub_path = "small.md", .data = data });

    const loaded = try loadFile(std.testing.allocator, tmp.dir, "small.md");
    defer loaded.storage.owned.allocator.free(loaded.storage.owned.buffer);

    try std.testing.expect(loaded.storage == .owned);
    try std.testing.expectEqualStrings(data, loaded.bytes);
}

test "loadFile returns mapped storage at or above mmap threshold" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data = try std.testing.allocator.alloc(u8, mmap_threshold);
    defer std.testing.allocator.free(data);
    @memset(data, 'a');
    data[data.len - 1] = '\n';

    try tmp.dir.writeFile(.{ .sub_path = "big.md", .data = data });

    const loaded = try loadFile(std.testing.allocator, tmp.dir, "big.md");
    defer std.posix.munmap(loaded.storage.mapped.bytes);

    try std.testing.expect(loaded.storage == .mapped);
    try std.testing.expectEqualSlices(u8, data, loaded.bytes);
}
