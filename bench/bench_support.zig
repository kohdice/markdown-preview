const std = @import("std");

pub const CounterSnapshot = struct {
    alloc_count: usize,
    resize_count: usize,
    free_count: usize,
    bytes_allocated: usize,
    bytes_freed: usize,

    pub fn diff(after: CounterSnapshot, before: CounterSnapshot) CounterSnapshot {
        return .{
            .alloc_count = after.alloc_count - before.alloc_count,
            .resize_count = after.resize_count - before.resize_count,
            .free_count = after.free_count - before.free_count,
            .bytes_allocated = after.bytes_allocated - before.bytes_allocated,
            .bytes_freed = after.bytes_freed - before.bytes_freed,
        };
    }
};

pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    alloc_count: usize = 0,
    resize_count: usize = 0,
    free_count: usize = 0,
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn snapshot(self: *const CountingAllocator) CounterSnapshot {
        return .{
            .alloc_count = self.alloc_count,
            .resize_count = self.resize_count,
            .free_count = self.free_count,
            .bytes_allocated = self.bytes_allocated,
            .bytes_freed = self.bytes_freed,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.alloc_count += 1;
        self.bytes_allocated += len;
        return ptr;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.child.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) {
            self.resize_count += 1;
            if (new_len > memory.len) {
                self.bytes_allocated += new_len - memory.len;
            } else {
                self.bytes_freed += memory.len - new_len;
            }
        }
        return ok;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.resize_count += 1;
        if (new_len > memory.len) {
            self.bytes_allocated += new_len - memory.len;
        } else {
            self.bytes_freed += memory.len - new_len;
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.free_count += 1;
        self.bytes_freed += memory.len;
        self.child.rawFree(memory, alignment, ret_addr);
    }
};
