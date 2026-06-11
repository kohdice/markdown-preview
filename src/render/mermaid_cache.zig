const std = @import("std");
const mermaid = @import("../mermaid.zig");

pub const MermaidCacheEntry = struct {
    diagram: mermaid.Diagram,
    key_owned_by_diagram: bool = false,
    used_in_render: bool = false,
};

pub const MermaidCache = std.StringHashMapUnmanaged(MermaidCacheEntry);

pub fn markUnused(cache: *MermaidCache) void {
    var it = cache.valueIterator();
    while (it.next()) |entry| entry.used_in_render = false;
}

pub fn pruneUnused(
    cache: *MermaidCache,
    scratch: std.mem.Allocator,
    persistent: std.mem.Allocator,
) !void {
    var stale_keys: std.ArrayList([]const u8) = .empty;
    defer stale_keys.deinit(scratch);

    var it = cache.iterator();
    while (it.next()) |entry| {
        if (!entry.value_ptr.used_in_render) {
            try stale_keys.append(scratch, entry.key_ptr.*);
        }
    }

    for (stale_keys.items) |key| {
        const removed = cache.fetchRemove(key) orelse continue;
        var diagram = removed.value.diagram;
        diagram.deinit();
        if (!removed.value.key_owned_by_diagram) persistent.free(removed.key);
    }
}
