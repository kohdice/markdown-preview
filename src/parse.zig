const std = @import("std");
const ast = @import("ast.zig");
const block_phase = @import("parse/block_phase.zig");
const inline_phase = @import("parse/inline_phase.zig");

pub fn parseBorrowed(allocator: std.mem.Allocator, source: []const u8) !ast.Document {
    const has_trailing_newline = source.len > 0 and source[source.len - 1] == '\n';

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const raw_doc = try block_phase.buildRawDocument(arena.allocator(), source);
    const resolved = try inline_phase.resolveInlines(arena.allocator(), raw_doc);
    return .{
        .source = source,
        .source_storage = .borrowed,
        .inline_nodes = resolved.inline_nodes,
        .inline_next = resolved.inline_next,
        .blocks = resolved.blocks,
        .link_defs = resolved.link_defs,
        .has_trailing_newline = has_trailing_newline,
        .storage = .{ .arena = arena },
    };
}

pub fn parseOwned(allocator: std.mem.Allocator, source: ast.Document.OwnedSource) !ast.Document {
    errdefer source.allocator.free(source.buffer);

    const has_trailing_newline = source.buffer.len > 0 and source.buffer[source.buffer.len - 1] == '\n';

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const raw_doc = try block_phase.buildRawDocument(arena.allocator(), source.buffer);
    const resolved = try inline_phase.resolveInlines(arena.allocator(), raw_doc);
    return .{
        .source = source.buffer,
        .source_storage = .{ .owned = source },
        .inline_nodes = resolved.inline_nodes,
        .inline_next = resolved.inline_next,
        .blocks = resolved.blocks,
        .link_defs = resolved.link_defs,
        .has_trailing_newline = has_trailing_newline,
        .storage = .{ .arena = arena },
    };
}

test {
    _ = @import("parse/block_cursor.zig");
    _ = @import("parse/block_phase.zig");
    _ = @import("parse/document_test.zig");
    _ = @import("parse/inline_phase.zig");
    _ = @import("parse/raw.zig");
}

test "parseBorrowed builds a document for a single paragraph" {
    var doc = try parseBorrowed(std.testing.allocator, "Hello\n");
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.has_trailing_newline);
}

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

test "parseBorrowed does not free the caller-owned source buffer on deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracking = TrackingAllocator.init(gpa.allocator());
    const allocator = tracking.allocator();

    const source = try allocator.dupe(u8, "Hello\n");
    defer if (!tracking.tracked_freed) allocator.free(source);
    tracking.track(source);

    var doc = try parseBorrowed(allocator, source);
    doc.deinit();

    try std.testing.expect(!tracking.tracked_freed);

    allocator.free(source);
    try std.testing.expect(tracking.tracked_freed);
}

test "parseOwned frees the source buffer on deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracking = TrackingAllocator.init(gpa.allocator());
    const allocator = tracking.allocator();

    const source = try allocator.dupe(u8, "Hello\n");
    tracking.track(source);

    var doc = try parseOwned(allocator, .{
        .allocator = allocator,
        .buffer = source,
    });
    try std.testing.expect(!tracking.tracked_freed);
    doc.deinit();
    try std.testing.expect(tracking.tracked_freed);
}

test "parseOwned can free source with a different allocator than AST storage" {
    var ast_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = ast_gpa.deinit();

    var source_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = source_gpa.deinit();

    var source_tracking = TrackingAllocator.init(source_gpa.allocator());
    const source_allocator = source_tracking.allocator();

    const source = try source_allocator.dupe(u8, "Hello\n");
    source_tracking.track(source);

    var doc = try parseOwned(ast_gpa.allocator(), .{
        .allocator = source_allocator,
        .buffer = source,
    });

    try std.testing.expect(!source_tracking.tracked_freed);
    doc.deinit();
    try std.testing.expect(source_tracking.tracked_freed);
}
