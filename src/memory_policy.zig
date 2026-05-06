const std = @import("std");

pub fn clearRetainingBounded(
    comptime T: type,
    list: *std.ArrayList(T),
    allocator: std.mem.Allocator,
    byte_limit: usize,
) void {
    if (@sizeOf(T) != 0 and list.capacity > byte_limit / @sizeOf(T)) {
        list.clearAndFree(allocator);
    } else {
        list.clearRetainingCapacity();
    }
}

test "clearRetainingBounded frees capacity above byte limit" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.ensureTotalCapacity(allocator, 9);
    clearRetainingBounded(u8, &list, allocator, 8);

    try std.testing.expectEqual(@as(usize, 0), list.capacity);
}

test "clearRetainingBounded retains capacity within byte limit" {
    const allocator = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);

    try list.ensureTotalCapacity(allocator, 8);
    const capacity = list.capacity;
    clearRetainingBounded(u8, &list, allocator, 8);

    try std.testing.expectEqual(capacity, list.capacity);
}
