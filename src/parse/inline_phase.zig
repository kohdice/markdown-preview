const std = @import("std");
const ast = @import("../ast.zig");
const block_phase = @import("block_phase.zig");
const parse_inline = @import("inline.zig");
const raw = @import("raw.zig");

/// Arena-scoped, same contract as `raw.RawDocument`: owning allocations
/// are interleaved with borrowed source slices, so there is no safe
/// `deinit`. Must be backed by an arena and freed by draining it.
pub const ParseResult = struct {
    blocks: []ast.BlockNode,
    inline_nodes: []ast.InlineNode,
    inline_next: []ast.InlineRef,
    link_defs: ast.LinkDefMap,
};

pub fn resolveInlines(allocator: std.mem.Allocator, raw_doc: raw.RawDocument) !ParseResult {
    var resolver = Resolver{
        .allocator = allocator,
        .inline_builder = parse_inline.InlineBuilder.init(allocator),
        .link_defs = raw_doc.link_defs,
    };

    const blocks = try resolver.resolveBlocks(raw_doc.blocks);
    const storage = resolver.inline_builder.finish();

    return .{
        .blocks = blocks,
        .inline_nodes = storage.nodes,
        .inline_next = storage.next,
        .link_defs = resolver.link_defs,
    };
}

const Resolver = struct {
    allocator: std.mem.Allocator,
    inline_builder: parse_inline.InlineBuilder,
    link_defs: ast.LinkDefMap,

    fn resolveBlocks(self: *Resolver, raw_blocks: []const raw.RawBlock) anyerror![]ast.BlockNode {
        const out = try self.allocator.alloc(ast.BlockNode, raw_blocks.len);
        for (raw_blocks, 0..) |rb, i| {
            out[i] = try self.resolveBlock(rb);
        }
        return out;
    }

    fn resolveBlock(self: *Resolver, rb: raw.RawBlock) anyerror!ast.BlockNode {
        return switch (rb) {
            .paragraph => |p| .{
                .paragraph = .{
                    .children = try self.inline_builder.parseLines(p.lines, &self.link_defs),
                },
            },
            .heading => |h| .{
                .heading = .{
                    .level = h.level,
                    .children = try self.inline_builder.parseLines(h.lines, &self.link_defs),
                },
            },
            .blockquote => |bq| .{
                .blockquote = .{
                    .indent = bq.indent,
                    .blocks = try self.resolveBlocks(bq.children),
                },
            },
            .list => |list| .{
                .list = .{
                    .kind = list.kind,
                    .items = try self.resolveListItems(list.items),
                    .loose = list.loose,
                },
            },
            .code_block => |cb| .{ .code_block = .{ .content = cb.content } },
            .code_fence => |cf| .{
                .code_fence = .{
                    .opener = cf.opener,
                    .closer = cf.closer,
                    .language = cf.language,
                    .content = cf.content,
                },
            },
            .thematic_break => .{ .thematic_break = {} },
            .table => |t| .{ .table = try self.resolveTable(t) },
            .blank_line => .{ .blank_line = {} },
        };
    }

    fn resolveListItems(self: *Resolver, raw_items: []const raw.RawListItem) anyerror![]ast.ListItem {
        const out = try self.allocator.alloc(ast.ListItem, raw_items.len);
        for (raw_items, 0..) |ri, i| {
            out[i] = .{
                .indent = ri.indent,
                .marker = ri.marker,
                .number = ri.number,
                .checked = ri.checked,
                .blocks = try self.resolveBlocks(ri.children),
            };
        }
        return out;
    }

    fn resolveTable(self: *Resolver, rt: raw.RawTable) anyerror!ast.Table {
        const header = try self.allocator.alloc(ast.TableCell, rt.header.len);
        for (rt.header, 0..) |cell_text, i| {
            header[i] = .{
                .children = try self.inline_builder.parseSlice(cell_text, &self.link_defs),
            };
        }

        const alignments = try self.allocator.dupe(ast.Alignment, rt.alignments);

        const rows = try self.allocator.alloc([]ast.TableCell, rt.rows.len);
        for (rt.rows, 0..) |raw_row, r_idx| {
            const row = try self.allocator.alloc(ast.TableCell, raw_row.len);
            for (raw_row, 0..) |cell_text, c_idx| {
                row[c_idx] = .{
                    .children = try self.inline_builder.parseSlice(cell_text, &self.link_defs),
                };
            }
            rows[r_idx] = row;
        }

        return .{
            .header = header,
            .alignments = alignments,
            .rows = rows,
        };
    }
};

fn countInlines(nodes: []const ast.InlineNode, nexts: []const ast.InlineRef, first: ast.InlineRef) usize {
    var current = first;
    var count: usize = 0;
    while (ast.hasInline(current)) {
        count += 1;
        const idx: usize = @intCast(current);
        current = nexts[idx];
        _ = nodes;
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

    const raw_doc = try block_phase.buildRawDocument(arena.allocator(), "Plain text\n");
    const result = try resolveInlines(arena.allocator(), raw_doc);

    try std.testing.expectEqual(@as(usize, 1), result.blocks.len);
    try std.testing.expect(result.blocks[0] == .paragraph);
    const first = result.blocks[0].paragraph.children;
    try std.testing.expectEqual(@as(usize, 1), countInlines(result.inline_nodes, result.inline_next, first));
    const node = inlineAt(result.inline_nodes, result.inline_next, first, 0);
    try std.testing.expect(node.* == .text);
    try std.testing.expectEqualStrings("Plain text", node.text);
}

test "resolveInlines resolves forward-referencing reference link using link_defs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_doc = try block_phase.buildRawDocument(arena.allocator(), "See [label][ref].\n\n[ref]: /target\n");
    const result = try resolveInlines(arena.allocator(), raw_doc);

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

    const raw_doc = try block_phase.buildRawDocument(arena.allocator(), "one\ntwo\n");
    const result = try resolveInlines(arena.allocator(), raw_doc);

    const first = result.blocks[0].paragraph.children;
    try std.testing.expectEqual(@as(usize, 3), countInlines(result.inline_nodes, result.inline_next, first));
    try std.testing.expect(inlineAt(result.inline_nodes, result.inline_next, first, 1).* == .soft_break);
}

test "resolveInlines preserves fenced code block content verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw_doc = try block_phase.buildRawDocument(arena.allocator(), "```\n*no* _emphasis_\n```\n");
    const result = try resolveInlines(arena.allocator(), raw_doc);

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
    const raw_doc = try block_phase.buildRawDocument(arena.allocator(), source);
    const result = try resolveInlines(arena.allocator(), raw_doc);

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
