const std = @import("std");
const ast = @import("../ast.zig");
const parse_mod = @import("../parse.zig");
const block_phase = @import("block_phase.zig");
const parse_inline = @import("inline.zig");
const inline_work_mod = @import("inline_work.zig");

const PendingInline = inline_work_mod.PendingInline;

pub const ParseResult = struct {
    blocks: []ast.BlockNode,
    inline_nodes: []ast.InlineNode,
    inline_next: []ast.InlineRef,
    link_defs: ast.LinkDefMap,
    trivial_runs: []const parse_mod.TrivialRun,
};

pub fn resolveInlines(
    allocator: std.mem.Allocator,
    builder: *parse_inline.InlineBuilder,
    block_doc: block_phase.BlockDocument,
) !ParseResult {
    var link_defs = block_doc.link_defs;

    var walk: Walk = .{
        .allocator = allocator,
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
        .trivial_runs = try walk.trivial.toOwnedSlice(allocator),
    };
}

const Walk = struct {
    allocator: std.mem.Allocator,
    builder: *parse_inline.InlineBuilder,
    link_defs: *const ast.LinkDefMap,
    pending: []const PendingInline,
    cursor: usize = 0,
    trivial: std.ArrayListUnmanaged(parse_mod.TrivialRun) = .empty,

    fn takePending(self: *Walk) PendingInline {
        const entry = self.pending[self.cursor];
        self.cursor += 1;
        return entry;
    }

    fn resolveParagraph(self: *Walk, p: *ast.Paragraph, entry: PendingInline) !void {
        switch (entry) {
            .full_single => |line| p.children = if (line.len == 0)
                ast.no_inline
            else
                try self.builder.parseSlice(line, self.link_defs),
            .full_multi => |lines| p.children = if (lines.len == 0)
                ast.no_inline
            else
                try self.builder.parseLines(lines, self.link_defs),
            // Trivial paragraphs skip materialization; the renderer
            // consults the private render seam via pointer match in
            // block-walk order.
            .trivial_single => |line| try self.trivial.append(self.allocator, .{
                .paragraph = p,
                .lines = .{ .single = line },
            }),
            .trivial_multi => |lines| try self.trivial.append(self.allocator, .{
                .paragraph = p,
                .lines = .{ .multi = lines },
            }),
        }
    }

    fn resolveHeading(self: *Walk, h: *ast.Heading, entry: PendingInline) !void {
        h.children = switch (entry) {
            .full_single => |line| if (line.len == 0)
                ast.no_inline
            else
                try self.builder.parseSlice(line, self.link_defs),
            .full_multi => |lines| if (lines.len == 0)
                ast.no_inline
            else
                try self.builder.parseLines(lines, self.link_defs),
            // Headings route through the full inline parser: trivial bypass
            // applies only to paragraphs (see block_phase heading emission).
            .trivial_single, .trivial_multi => unreachable,
        };
    }

    fn resolveBlock(self: *Walk, blk: *ast.BlockNode) anyerror!void {
        switch (blk.*) {
            .paragraph => |*p| {
                if (!ast.hasInline(p.children)) {
                    const entry = self.takePending();
                    try self.resolveParagraph(p, entry);
                }
            },
            .heading => |*h| {
                const entry = self.takePending();
                try self.resolveHeading(h, entry);
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
    return resolveInlines(allocator, &builder, block_doc);
}

test "resolveInlines records trigger-free single-line paragraph in trivial_runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "Plain text\n");

    try std.testing.expectEqual(@as(usize, 1), result.blocks.len);
    try std.testing.expect(result.blocks[0] == .paragraph);
    try std.testing.expectEqual(ast.no_inline, result.blocks[0].paragraph.children);

    try std.testing.expectEqual(@as(usize, 1), result.trivial_runs.len);
    try std.testing.expectEqual(&result.blocks[0].paragraph, result.trivial_runs[0].paragraph);
    try std.testing.expect(result.trivial_runs[0].lines == .single);
    try std.testing.expectEqualStrings("Plain text", result.trivial_runs[0].lines.single);
}

test "resolveInlines builds inline chain when paragraph contains a trigger" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "One *em* tag\n");

    try std.testing.expect(ast.hasInline(result.blocks[0].paragraph.children));
    try std.testing.expectEqual(@as(usize, 0), result.trivial_runs.len);
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
    try std.testing.expectEqual(@as(usize, 0), result.trivial_runs.len);
}

test "resolveInlines produces heading nested inside blockquote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "> ## nested heading\n");

    try std.testing.expect(result.blocks[0] == .blockquote);
    const inner = result.blocks[0].blockquote.blocks[0];
    try std.testing.expect(inner == .heading);
    try std.testing.expect(ast.hasInline(inner.heading.children));
    try std.testing.expectEqual(@as(usize, 0), result.trivial_runs.len);
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

test "resolveInlines stores multi-line trigger-free paragraph in trivial_runs without materializing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "one\ntwo\n");

    try std.testing.expect(result.blocks[0] == .paragraph);
    try std.testing.expectEqual(ast.no_inline, result.blocks[0].paragraph.children);

    try std.testing.expectEqual(@as(usize, 1), result.trivial_runs.len);
    const run = result.trivial_runs[0];
    try std.testing.expectEqual(&result.blocks[0].paragraph, run.paragraph);
    try std.testing.expect(run.lines == .multi);
    try std.testing.expectEqual(@as(usize, 2), run.lines.multi.len);
    try std.testing.expectEqualStrings("one", run.lines.multi[0]);
    try std.testing.expectEqualStrings("two", run.lines.multi[1]);
    try std.testing.expectEqual(@as(usize, 0), result.inline_nodes.len);
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

test "resolveInlines descends into blockquote children and records trivial paragraphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "> inner text\n");

    try std.testing.expect(result.blocks[0] == .blockquote);
    const inner = &result.blocks[0].blockquote.blocks[0];
    try std.testing.expect(inner.* == .paragraph);
    try std.testing.expectEqual(ast.no_inline, inner.paragraph.children);

    try std.testing.expectEqual(@as(usize, 1), result.trivial_runs.len);
    try std.testing.expectEqual(&inner.paragraph, result.trivial_runs[0].paragraph);
    try std.testing.expect(result.trivial_runs[0].lines == .single);
    try std.testing.expectEqualStrings("inner text", result.trivial_runs[0].lines.single);
}

test "resolveInlines preserves block count across resolution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "a\n\nb\n");

    try std.testing.expectEqual(@as(usize, 3), result.blocks.len);
    try std.testing.expectEqual(@as(usize, 2), result.trivial_runs.len);
}

test "resolveInlines on empty input returns empty storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try buildAll(arena.allocator(), "");

    try std.testing.expectEqual(@as(usize, 0), result.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), result.inline_nodes.len);
    try std.testing.expectEqual(@as(usize, 0), result.trivial_runs.len);
}
