const std = @import("std");
const ast = @import("../ast.zig");
const block_phase = @import("block_phase.zig");
const parse_inline = @import("inline.zig");

pub const ParseResult = struct {
    blocks: []ast.BlockNode,
    inline_nodes: []ast.InlineNode,
    inline_next: []ast.InlineRef,
    link_defs: ast.LinkDefMap,
};

pub fn resolveInlines(
    allocator: std.mem.Allocator,
    block_doc: block_phase.BlockDocument,
) !ParseResult {
    var inline_builder = parse_inline.InlineBuilder.init(allocator);
    var link_defs = block_doc.link_defs;

    for (block_doc.blocks) |*blk| {
        try resolveBlock(blk, &inline_builder, &link_defs);
    }

    for (block_doc.inline_work) |work| {
        work.target.* = try inline_builder.parseSlice(work.input.slice, &link_defs);
    }

    const storage = inline_builder.finish();
    return .{
        .blocks = block_doc.blocks,
        .inline_nodes = storage.nodes,
        .inline_next = storage.next,
        .link_defs = link_defs,
    };
}

fn resolveBlock(
    blk: *ast.BlockNode,
    builder: *parse_inline.InlineBuilder,
    link_defs: *const ast.LinkDefMap,
) anyerror!void {
    switch (blk.*) {
        .paragraph => |*p| {
            if (p.pending_lines.len > 0) {
                p.children = try builder.parseLines(p.pending_lines, link_defs);
                p.pending_lines = &.{};
            }
        },
        .heading => |*h| {
            if (h.pending_lines.len > 0) {
                h.children = try builder.parseLines(h.pending_lines, link_defs);
                h.pending_lines = &.{};
            }
        },
        .blockquote => |*bq| {
            for (bq.blocks) |*child| try resolveBlock(child, builder, link_defs);
        },
        .list => |*list| {
            for (list.items) |*item| {
                for (item.blocks) |*child| try resolveBlock(child, builder, link_defs);
            }
        },
        .code_block, .code_fence, .thematic_break, .table, .blank_line => {},
    }
}

fn countInlines(nexts: []const ast.InlineRef, first: ast.InlineRef) usize {
    var current = first;
    var count: usize = 0;
    while (ast.hasInline(current)) {
        count += 1;
        const idx: usize = @intCast(current);
        current = nexts[idx];
    }
    return count;
}

fn inlineAt(nodes: []const ast.InlineNode, nexts: []const ast.InlineRef, first: ast.InlineRef, index: usize) *const ast.InlineNode {
    var current = first;
    var i: usize = 0;
    while (ast.hasInline(current)) : (i += 1) {
        const idx: usize = @intCast(current);
        if (i == index) return &nodes[idx];
        current = nexts[idx];
    }
    unreachable;
}

test "resolveInlines produces a text span for a single-line paragraph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), "Plain text\n");
    const result = try resolveInlines(arena.allocator(), block_doc);

    try std.testing.expectEqual(@as(usize, 1), result.blocks.len);
    try std.testing.expect(result.blocks[0] == .paragraph);
    const first = result.blocks[0].paragraph.children;
    try std.testing.expectEqual(@as(usize, 1), countInlines(result.inline_next, first));
    const node = inlineAt(result.inline_nodes, result.inline_next, first, 0);
    try std.testing.expect(node.* == .text);
    try std.testing.expectEqualStrings("Plain text", node.text);
}

test "resolveInlines clears pending_lines on paragraph after resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), "Plain text\n");
    const result = try resolveInlines(arena.allocator(), block_doc);

    try std.testing.expectEqual(@as(usize, 0), result.blocks[0].paragraph.pending_lines.len);
}

test "resolveInlines clears pending_lines on ATX heading after resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), "# Title *em*\n");
    const result = try resolveInlines(arena.allocator(), block_doc);

    try std.testing.expect(result.blocks[0] == .heading);
    try std.testing.expectEqual(@as(usize, 0), result.blocks[0].heading.pending_lines.len);
    try std.testing.expect(ast.hasInline(result.blocks[0].heading.children));
}

test "resolveInlines clears pending_lines on setext heading after resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), "Title\n=====\n");
    const result = try resolveInlines(arena.allocator(), block_doc);

    try std.testing.expect(result.blocks[0] == .heading);
    try std.testing.expectEqual(@as(u8, 1), result.blocks[0].heading.level);
    try std.testing.expectEqual(@as(usize, 0), result.blocks[0].heading.pending_lines.len);
    try std.testing.expect(ast.hasInline(result.blocks[0].heading.children));
}

test "resolveInlines clears pending_lines on heading nested inside blockquote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), "> ## nested heading\n");
    const result = try resolveInlines(arena.allocator(), block_doc);

    try std.testing.expect(result.blocks[0] == .blockquote);
    const inner = result.blocks[0].blockquote.blocks[0];
    try std.testing.expect(inner == .heading);
    try std.testing.expectEqual(@as(usize, 0), inner.heading.pending_lines.len);
}

test "resolveInlines resolves forward-referencing reference link using link_defs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), "See [label][ref].\n\n[ref]: /target\n");
    const result = try resolveInlines(arena.allocator(), block_doc);

    try std.testing.expect(result.blocks[0] == .paragraph);
    const first = result.blocks[0].paragraph.children;

    var found_link = false;
    var current = first;
    while (ast.hasInline(current)) {
        const idx: usize = @intCast(current);
        const n = &result.inline_nodes[idx];
        if (n.* == .link) {
            try std.testing.expectEqualStrings("/target", n.link.url);
            found_link = true;
        }
        current = result.inline_next[idx];
    }
    try std.testing.expect(found_link);
}

test "resolveInlines maps soft line breaks between joined paragraph lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), "one\ntwo\n");
    const result = try resolveInlines(arena.allocator(), block_doc);

    const first = result.blocks[0].paragraph.children;
    try std.testing.expectEqual(@as(usize, 3), countInlines(result.inline_next, first));
    try std.testing.expect(inlineAt(result.inline_nodes, result.inline_next, first, 1).* == .soft_break);
}

test "resolveInlines preserves fenced code block content verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), "```\n*no* _emphasis_\n```\n");
    const result = try resolveInlines(arena.allocator(), block_doc);

    try std.testing.expect(result.blocks[0] == .code_fence);
    try std.testing.expectEqualStrings("*no* _emphasis_", result.blocks[0].code_fence.content);
}

test "resolveInlines walks table cells and resolves inline emphasis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\| h1 | h2 |
        \\| - | - |
        \\| *em* | plain |
        \\
    ;
    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), source);
    const result = try resolveInlines(arena.allocator(), block_doc);

    try std.testing.expect(result.blocks[0] == .table);
    const row = result.blocks[0].table.rows[0];
    const em_cell = row[0];

    var saw_emphasis = false;
    var current = em_cell.children;
    while (ast.hasInline(current)) {
        const idx: usize = @intCast(current);
        if (result.inline_nodes[idx] == .emphasis) saw_emphasis = true;
        current = result.inline_next[idx];
    }
    try std.testing.expect(saw_emphasis);
}

test "resolveInlines descends into blockquote children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), "> inner text\n");
    const result = try resolveInlines(arena.allocator(), block_doc);

    try std.testing.expect(result.blocks[0] == .blockquote);
    const inner = result.blocks[0].blockquote.blocks[0];
    try std.testing.expect(inner == .paragraph);
    try std.testing.expect(ast.hasInline(inner.paragraph.children));
    try std.testing.expectEqual(@as(usize, 0), inner.paragraph.pending_lines.len);
}

test "resolveInlines returns block slice pointer-identical to block_doc input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), "a\n\nb\n");
    const before_ptr = @intFromPtr(block_doc.blocks.ptr);
    const result = try resolveInlines(arena.allocator(), block_doc);

    try std.testing.expectEqual(before_ptr, @intFromPtr(result.blocks.ptr));
    try std.testing.expectEqual(block_doc.blocks.len, result.blocks.len);
}

test "resolveInlines on empty BlockDocument returns empty storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try block_phase.buildBlockDocument(arena.allocator(), "");
    const result = try resolveInlines(arena.allocator(), block_doc);

    try std.testing.expectEqual(@as(usize, 0), result.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), result.inline_nodes.len);
}
