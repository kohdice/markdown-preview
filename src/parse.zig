const std = @import("std");
const ast = @import("ast.zig");
const parse_block = @import("parse/block.zig");
const parse_document = @import("parse/document.zig");

pub const Document = ast.Document;

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Document {
    const has_trailing_newline = input.len > 0 and input[input.len - 1] == '\n';
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);

    if (input.len > 0) {
        var it = std.mem.splitScalar(u8, input, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, parse_block.carriage_return);
            try lines.append(allocator, line);
        }

        if (has_trailing_newline and lines.items.len > 0) {
            _ = lines.pop();
        }
    }

    const parsed = try parse_document.parse(arena_allocator, lines.items);
    return .{
        .source = input,
        .inline_nodes = parsed.inline_nodes,
        .blocks = parsed.blocks,
        .link_defs = parsed.link_defs,
        .has_trailing_newline = has_trailing_newline,
        .storage = .{ .arena = arena },
    };
}

test "parse builds a document for a single paragraph" {
    var doc = try parse(std.testing.allocator, "Hello\n");
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.has_trailing_newline);
}
