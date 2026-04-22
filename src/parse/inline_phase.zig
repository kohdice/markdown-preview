const std = @import("std");
const ast = @import("../ast.zig");
const block_phase = @import("block_phase.zig");
const parse_inline = @import("inline.zig");
const inline_work_mod = @import("inline_work.zig");

const PendingInline = inline_work_mod.PendingInline;

pub const ParseResult = struct {
    blocks: []ast.BlockNode,
    inline_nodes: []ast.InlineNode,
    inline_next: []ast.InlineRef,
    link_defs: ast.LinkDefMap,
};

pub fn resolveInlines(
    builder: *parse_inline.InlineBuilder,
    block_doc: block_phase.BlockDocument,
) !ParseResult {
    var link_defs = block_doc.link_defs;

    var walk: Walk = .{
        .builder = builder,
        .link_defs = &link_defs,
        .pending = block_doc.pending_inline,
    };
    for (block_doc.blocks) |*blk| {
        try walk.resolveBlock(blk);
    }
    std.debug.assert(walk.cursor == block_doc.pending_inline.len);

    for (block_doc.inline_work) |work| {
        work.target.* = try builder.parseSlice(work.input.slice, &link_defs);
    }

    const storage = builder.finish();
    return .{
        .blocks = block_doc.blocks,
        .inline_nodes = storage.nodes,
        .inline_next = storage.next,
        .link_defs = link_defs,
    };
}

const Walk = struct {
    builder: *parse_inline.InlineBuilder,
    link_defs: *const ast.LinkDefMap,
    pending: []const PendingInline,
    cursor: usize = 0,

    fn takePending(self: *Walk) PendingInline {
        const entry = self.pending[self.cursor];
        self.cursor += 1;
        return entry;
    }

    fn resolveInline(self: *Walk, entry: PendingInline) !ast.InlineRef {
        return switch (entry) {
            .single => |line| if (line.len == 0)
                ast.no_inline
            else
                try self.builder.parseSlice(line, self.link_defs),
            .multi => |lines| if (lines.len == 0)
                ast.no_inline
            else
                try self.builder.parseLines(lines, self.link_defs),
        };
    }

    fn resolveBlock(self: *Walk, blk: *ast.BlockNode) anyerror!void {
        switch (blk.*) {
            .paragraph => |*p| {
                if (!ast.hasInline(p.children)) {
                    const entry = self.takePending();
                    p.children = try self.resolveInline(entry);
                }
            },
            .heading => |*h| {
                const entry = self.takePending();
                h.children = try self.resolveInline(entry);
            },
            .blockquote => |*bq| {
                for (bq.blocks) |*child| try self.resolveBlock(child);
            },
            .list => |*list| {
                for (list.items) |*item| {
                    for (item.blocks) |*child| try self.resolveBlock(child);
                }
            },
            .code_block, .code_fence, .thematic_break, .table, .blank_line => {},
        }
    }
};

fn buildAll(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    var builder = parse_inline.InlineBuilder.init(allocator);
    const block_doc = try block_phase.buildBlockDocument(allocator, &builder, source);
    return resolveInlines(&builder, block_doc);
}

test "resolveInlines materialises trigger-free single-line paragraph as text node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "Plain text\n");

    try std.testing.expectEqual(@as(usize, 1), result.blocks.len);
    try std.testing.expect(result.blocks[0] == .paragraph);
    const head = result.blocks[0].paragraph.children;
    try std.testing.expect(ast.hasInline(head));
    try std.testing.expect(result.inline_nodes[head] == .text);
    try std.testing.expectEqualStrings("Plain text", result.inline_nodes[head].text);
    try std.testing.expectEqual(ast.no_inline, result.inline_next[head]);
}

test "resolveInlines builds inline chain when paragraph contains a trigger" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "One *em* tag\n");

    try std.testing.expect(ast.hasInline(result.blocks[0].paragraph.children));
}

test "resolveInlines produces heading with ATX children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "# Title *em*\n");

    try std.testing.expect(result.blocks[0] == .heading);
    try std.testing.expect(ast.hasInline(result.blocks[0].heading.children));
}

test "resolveInlines produces setext heading with level 1 children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "Title\n=====\n");

    try std.testing.expect(result.blocks[0] == .heading);
    try std.testing.expectEqual(@as(u8, 1), result.blocks[0].heading.level);
    try std.testing.expect(ast.hasInline(result.blocks[0].heading.children));
}

test "resolveInlines produces heading nested inside blockquote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "> ## nested heading\n");

    try std.testing.expect(result.blocks[0] == .blockquote);
    const inner = result.blocks[0].blockquote.blocks[0];
    try std.testing.expect(inner == .heading);
    try std.testing.expect(ast.hasInline(inner.heading.children));
}

test "resolveInlines resolves forward-referencing reference link using link_defs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "See [label][ref].\n\n[ref]: /target\n");

    try std.testing.expect(result.blocks[0] == .paragraph);
    const head = result.blocks[0].paragraph.children;
    try std.testing.expect(ast.hasInline(head));

    var found_link = false;
    var current = head;
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

test "resolveInlines materialises multi-line trigger-free paragraph as text + soft_break chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "one\ntwo\n");

    try std.testing.expect(result.blocks[0] == .paragraph);
    const head = result.blocks[0].paragraph.children;
    try std.testing.expect(ast.hasInline(head));

    const expected = [_]std.meta.Tag(ast.InlineNode){ .text, .soft_break, .text };
    var idx: usize = 0;
    var current = head;
    while (ast.hasInline(current)) : (idx += 1) {
        try std.testing.expect(idx < expected.len);
        try std.testing.expect(std.meta.activeTag(result.inline_nodes[current]) == expected[idx]);
        current = result.inline_next[current];
    }
    try std.testing.expectEqual(@as(usize, expected.len), idx);
}

test "resolveInlines builds soft_break chain when multi-line paragraph has trigger" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "one *x*\ntwo\n");

    const head = result.blocks[0].paragraph.children;
    try std.testing.expect(ast.hasInline(head));

    var saw_soft_break = false;
    var current = head;
    while (ast.hasInline(current)) {
        const idx: usize = @intCast(current);
        if (result.inline_nodes[idx] == .soft_break) saw_soft_break = true;
        current = result.inline_next[idx];
    }
    try std.testing.expect(saw_soft_break);
}

test "resolveInlines preserves fenced code block content verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "```\n*no* _emphasis_\n```\n");

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
    const result = try buildAll(arena.allocator(), source);

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

test "resolveInlines descends into blockquote children and materialises inner paragraph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "> inner text\n");

    try std.testing.expect(result.blocks[0] == .blockquote);
    const inner = &result.blocks[0].blockquote.blocks[0];
    try std.testing.expect(inner.* == .paragraph);
    const head = inner.paragraph.children;
    try std.testing.expect(ast.hasInline(head));
    try std.testing.expect(result.inline_nodes[head] == .text);
    try std.testing.expectEqualStrings("inner text", result.inline_nodes[head].text);
}

test "resolveInlines preserves block count across resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "a\n\nb\n");

    try std.testing.expectEqual(@as(usize, 3), result.blocks.len);
}

test "resolveInlines on empty input returns empty storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "");

    try std.testing.expectEqual(@as(usize, 0), result.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), result.inline_nodes.len);
}
