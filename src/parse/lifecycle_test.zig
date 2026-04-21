const std = @import("std");
const builtin = @import("builtin");
const parse = @import("../parse.zig");
const source_loader = @import("../source_loader.zig");

const TrackingAllocator = struct {
    child: std.mem.Allocator,
    tracked_ptr: ?[*]u8 = null,
    tracked_len: usize = 0,
    tracked_freed: bool = false,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(child: std.mem.Allocator) TrackingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn track(self: *TrackingAllocator, buffer: []u8) void {
        self.tracked_ptr = buffer.ptr;
        self.tracked_len = buffer.len;
        self.tracked_freed = false;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        if (self.tracked_ptr) |tracked_ptr| {
            if (tracked_ptr == memory.ptr and self.tracked_len == memory.len) {
                self.tracked_freed = true;
            }
        }
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "parse with borrowed source does not free the caller-owned buffer on deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracking = TrackingAllocator.init(gpa.allocator());
    const allocator = tracking.allocator();

    const source = try allocator.dupe(u8, "Hello\n");
    defer if (!tracking.tracked_freed) allocator.free(source);
    tracking.track(source);

    var doc = try parse.parse(allocator, .{ .borrowed = source });
    doc.deinit();

    try std.testing.expect(!tracking.tracked_freed);

    allocator.free(source);
    try std.testing.expect(tracking.tracked_freed);
}

test "parse with owned source frees the buffer on deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracking = TrackingAllocator.init(gpa.allocator());
    const allocator = tracking.allocator();

    const source = try allocator.dupe(u8, "Hello\n");
    tracking.track(source);

    var doc = try parse.parse(allocator, .{ .owned = .{
        .allocator = allocator,
        .buffer = source,
    } });
    try std.testing.expect(!tracking.tracked_freed);
    doc.deinit();
    try std.testing.expect(tracking.tracked_freed);
}

test "parse with mapped source unmaps the buffer on deinit" {
    if (builtin.os.tag == .windows) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const threshold = 64 * 1024;
    const data = try std.testing.allocator.alloc(u8, threshold);
    defer std.testing.allocator.free(data);
    @memset(data, 'a');
    data[data.len - 1] = '\n';

    try tmp.dir.writeFile(.{ .sub_path = "big.md", .data = data });

    const source = try source_loader.loadFile(std.testing.allocator, tmp.dir, "big.md");
    try std.testing.expect(source == .mapped);

    var doc = try parse.parse(std.testing.allocator, source);
    try std.testing.expect(doc.parsed.document.source_storage == .mapped);
    try std.testing.expectEqual(@as(usize, threshold), doc.parsed.document.source.len);

    doc.deinit();
    try std.testing.expect(doc.parsed.document.source_storage == .borrowed);
    try std.testing.expectEqual(@as(usize, 0), doc.parsed.document.source.len);
}

test "parse with owned source can free buffer with a different allocator than AST storage" {
    var ast_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = ast_gpa.deinit();

    var source_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = source_gpa.deinit();

    var source_tracking = TrackingAllocator.init(source_gpa.allocator());
    const source_allocator = source_tracking.allocator();

    const source = try source_allocator.dupe(u8, "Hello\n");
    source_tracking.track(source);

    var doc = try parse.parse(ast_gpa.allocator(), .{ .owned = .{
        .allocator = source_allocator,
        .buffer = source,
    } });

    try std.testing.expect(!source_tracking.tracked_freed);
    doc.deinit();
    try std.testing.expect(source_tracking.tracked_freed);
}
