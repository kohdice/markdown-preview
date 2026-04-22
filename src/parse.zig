const std = @import("std");
const ast = @import("ast.zig");
const block_phase = @import("parse/block_phase.zig");
const inline_phase = @import("parse/inline_phase.zig");
const parse_inline = @import("parse/inline.zig");
const source_mod = @import("source");

pub const Document = ast.Document;
pub const Source = source_mod.Source;

fn estimateInlineNodeCapacity(bytes: []const u8) usize {
    // Scale the reserve with block boundaries (`\n\n`), not total line count:
    // a boundary is a reasonable proxy for the number of parseSlice /
    // parseLines calls that reach the builder, so single-paragraph inputs with
    // many internal soft breaks don't pre-allocate slots they won't use.
    const separator_count = std.mem.count(u8, bytes, "\n\n");
    if (separator_count < 256) return 0;
    return @min(separator_count, 8192);
}

pub fn parse(allocator: std.mem.Allocator, src: Source) !Document {
    switch (src) {
        .borrowed => |bytes| return buildDocument(allocator, bytes, .borrowed),
        .owned => |o| {
            errdefer o.allocator.free(o.buffer);
            return buildDocument(allocator, o.buffer, .{ .owned = o });
        },
        .mapped => |m| {
            errdefer std.posix.munmap(m.bytes);
            return buildDocument(allocator, m.bytes, .{ .mapped = m });
        },
    }
}

fn buildDocument(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    storage: ast.Document.SourceStorage,
) !Document {
    const has_trailing_newline = bytes.len > 0 and bytes[bytes.len - 1] == '\n';

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var builder = parse_inline.InlineBuilder.init(arena.allocator());
    try builder.reserve(estimateInlineNodeCapacity(bytes));
    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), &builder, bytes);
    const resolved = try inline_phase.resolveInlines(&builder, block_doc);
    return .{
        .source = bytes,
        .source_storage = storage,
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
    _ = @import("parse/inline_work.zig");
    _ = @import("parse/lifecycle_test.zig");
}

test "parse builds a document for a single paragraph" {
    var doc = try parse(std.testing.allocator, .{ .borrowed = "Hello\n" });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.has_trailing_newline);
}
