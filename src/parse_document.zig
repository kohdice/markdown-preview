const std = @import("std");
const block_ast = @import("block_ast.zig");
const parse_block = @import("parse_block.zig");
const parse_table = @import("parse_table.zig");
const parse_link = @import("parse_link.zig");

pub fn parseDocument(allocator: std.mem.Allocator, input: []const u8) !block_ast.Document {
    const has_trailing_newline = input.len > 0 and input[input.len - 1] == '\n';

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

    var parser = Parser{
        .allocator = allocator,
        .lines = lines.items,
        .pos = 0,
        .link_defs = .{},
    };

    const blocks = parser.parseBlocks() catch |err| {
        parser.deinitLinkDefs();
        return err;
    };

    return .{
        .blocks = blocks,
        .link_defs = parser.link_defs,
        .has_trailing_newline = has_trailing_newline,
    };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    pos: usize,
    link_defs: parse_link.LinkDefMap,

    fn deinitLinkDefs(self: *Parser) void {
        var it = self.link_defs.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.link_defs.deinit(self.allocator);
    }

    fn peekLine(self: *const Parser) []const u8 {
        return self.lines[self.pos];
    }

    fn advanceLine(self: *Parser) void {
        self.pos += 1;
    }

    fn lineStartsTable(self: *const Parser) bool {
        const line = self.peekLine();
        if (std.mem.indexOfScalar(u8, line, '|') == null) return false;

        const next_line = self.peekNextLine() orelse return false;
        if (!parse_table.isDelimiterRow(next_line)) return false;

        return parse_table.countCells(line) == parse_table.countCells(next_line);
    }

    fn peekNextLine(self: *const Parser) ?[]const u8 {
        if (self.pos + 1 >= self.lines.len) return null;
        return self.lines[self.pos + 1];
    }

    fn parseContainerBlocks(self: *Parser, container_lines: []const []const u8) anyerror![]block_ast.BlockNode {
        const saved_lines = self.lines;
        const saved_pos = self.pos;
        defer {
            self.lines = saved_lines;
            self.pos = saved_pos;
        }

        self.lines = container_lines;
        self.pos = 0;

        return try self.parseBlocks();
    }

    fn parseBlocks(self: *Parser) ![]block_ast.BlockNode {
        var blocks: std.ArrayListUnmanaged(block_ast.BlockNode) = .empty;
        errdefer {
            for (blocks.items) |*b| b.deinit(self.allocator);
            blocks.deinit(self.allocator);
        }

        while (self.pos < self.lines.len) {
            if (isBlankLine(self.peekLine())) {
                while (self.pos < self.lines.len and isBlankLine(self.peekLine())) {
                    self.advanceLine();
                }
                try blocks.append(self.allocator, .{ .blank_line = {} });
                continue;
            }

            const line = self.peekLine();

            if (parse_block.parseFence(line)) |fence_info| {
                const cf = try self.parseFenceBlock(fence_info);
                try blocks.append(self.allocator, cf);
                continue;
            }

            if (parse_link.parseLinkDefinition(line)) |def| {
                try self.addLinkDef(def);
                self.advanceLine();
                continue;
            }

            if (parse_block.isThematicBreak(line)) {
                self.advanceLine();
                try blocks.append(self.allocator, .{ .thematic_break = {} });
                continue;
            }

            if (try self.tryParseTable(line)) |table_node| {
                try blocks.append(self.allocator, table_node);
                continue;
            }

            if (parse_block.parseHeading(line)) |h| {
                self.advanceLine();
                try blocks.append(self.allocator, .{
                    .heading = .{ .level = h.level, .content = h.content },
                });
                continue;
            }

            if (parse_block.parseBlockQuote(line)) |_| {
                const bq = try self.parseBlockQuoteBlock();
                try blocks.append(self.allocator, bq);
                continue;
            }

            if (parse_block.parseListItem(line) != null) {
                const list = try self.parseListBlock(.unordered);
                try blocks.append(self.allocator, list);
                continue;
            }
            if (parse_block.parseOrderedListItem(line) != null) {
                const list = try self.parseListBlock(.ordered);
                try blocks.append(self.allocator, list);
                continue;
            }

            const p = try self.parseParagraph();
            try blocks.append(self.allocator, p);
        }

        return blocks.toOwnedSlice(self.allocator);
    }

    fn addLinkDef(self: *Parser, def: parse_link.LinkDefinition) !void {
        const key = try std.ascii.allocLowerString(self.allocator, def.label);
        errdefer self.allocator.free(key);

        const result = try self.link_defs.getOrPut(self.allocator, key);
        if (result.found_existing) {
            self.allocator.free(key);
        } else {
            result.value_ptr.* = .{ .url = def.url, .title = def.title };
        }
    }

    fn parseParagraph(self: *Parser) !block_ast.BlockNode {
        var paragraph_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer paragraph_lines.deinit(self.allocator);

        if (self.pos < self.lines.len and !isBlankLine(self.peekLine())) {
            try paragraph_lines.append(self.allocator, self.peekLine());
            self.advanceLine();
        }

        while (self.pos < self.lines.len) {
            const line = self.peekLine();
            if (isBlankLine(line)) break;
            if (parse_block.isBlockLevelStart(line)) break;
            if (parse_link.parseLinkDefinition(line) != null) break;
            if (self.lineStartsTable()) break;

            try paragraph_lines.append(self.allocator, line);
            self.advanceLine();
        }

        return .{ .paragraph = .{ .lines = try paragraph_lines.toOwnedSlice(self.allocator) } };
    }

    fn parseFenceBlock(self: *Parser, fence_info: parse_block.Fence) !block_ast.BlockNode {
        const opener = self.peekLine();
        self.advanceLine();

        var body_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer body_lines.deinit(self.allocator);

        var closer: ?[]const u8 = null;
        while (self.pos < self.lines.len) {
            const line = self.peekLine();
            if (parse_block.isClosingFence(line, fence_info)) {
                closer = line;
                self.advanceLine();
                break;
            }
            try body_lines.append(self.allocator, line);
            self.advanceLine();
        }

        var total_len: usize = 0;
        for (body_lines.items, 0..) |bl, i| {
            total_len += bl.len;
            if (i + 1 < body_lines.items.len) total_len += 1;
        }
        const content = try self.allocator.alloc(u8, total_len);
        errdefer self.allocator.free(content);

        var offset: usize = 0;
        for (body_lines.items, 0..) |bl, i| {
            @memcpy(content[offset .. offset + bl.len], bl);
            offset += bl.len;
            if (i + 1 < body_lines.items.len) {
                content[offset] = '\n';
                offset += 1;
            }
        }

        return .{
            .code_fence = .{
                .opener = opener,
                .closer = closer,
                .language = fence_info.language,
                .content = content,
            },
        };
    }

    fn parseBlockQuoteBlock(self: *Parser) anyerror!block_ast.BlockNode {
        const first_line = self.peekLine();
        const first_bq = parse_block.parseBlockQuote(first_line) orelse unreachable;
        const indent = first_bq.indent;

        var child_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer child_lines.deinit(self.allocator);

        while (self.pos < self.lines.len) {
            const line = self.peekLine();
            const bq = parse_block.parseBlockQuote(line) orelse break;
            if (bq.indent != indent) break;
            try child_lines.append(self.allocator, bq.content);
            self.advanceLine();
        }

        const child_blocks = try self.parseContainerBlocks(child_lines.items);

        return .{
            .blockquote = .{
                .indent = indent,
                .blocks = child_blocks,
            },
        };
    }

    fn parseListBlock(self: *Parser, kind: block_ast.ListKind) anyerror!block_ast.BlockNode {
        var items: std.ArrayListUnmanaged(block_ast.ListItem) = .empty;
        errdefer {
            for (items.items) |*it| it.deinit(self.allocator);
            items.deinit(self.allocator);
        }

        var min_indent: ?usize = null;
        var prev_child_indent: ?usize = null;

        outer: while (self.pos < self.lines.len) {
            const line = self.peekLine();
            if (isBlankLine(line)) break :outer;

            const item_node: block_ast.ListItem = switch (kind) {
                .unordered => blk: {
                    const parsed = parse_block.parseListItem(line) orelse break :outer;
                    if (min_indent) |mi| {
                        if (parsed.indent < mi) break :outer;
                        if (parsed.indent >= prev_child_indent.?) break :outer;
                    }
                    self.advanceLine();
                    if (min_indent == null) min_indent = parsed.indent;
                    prev_child_indent = parsed.content_col;
                    break :blk try self.buildUnorderedItem(parsed);
                },
                .ordered => blk: {
                    const parsed = parse_block.parseOrderedListItem(line) orelse break :outer;
                    if (min_indent) |mi| {
                        if (parsed.indent < mi) break :outer;
                        if (parsed.indent >= prev_child_indent.?) break :outer;
                    }
                    self.advanceLine();
                    if (min_indent == null) min_indent = parsed.indent;
                    prev_child_indent = parsed.content_col;
                    break :blk try self.buildOrderedItem(parsed);
                },
            };

            try items.append(self.allocator, item_node);
        }

        return .{
            .list = .{
                .kind = kind,
                .items = try items.toOwnedSlice(self.allocator),
            },
        };
    }

    fn buildUnorderedItem(self: *Parser, item: parse_block.ListItem) anyerror!block_ast.ListItem {
        const child_blocks = try self.buildListItemContent(item.content, item.content_col);
        return .{
            .indent = item.indent,
            .marker = item.marker,
            .number = null,
            .checked = item.checked,
            .blocks = child_blocks,
        };
    }

    fn buildOrderedItem(self: *Parser, item: parse_block.OrderedListItem) anyerror!block_ast.ListItem {
        const child_blocks = try self.buildListItemContent(item.content, item.content_col);
        return .{
            .indent = item.indent,
            .marker = item.marker,
            .number = item.number,
            .checked = item.checked,
            .blocks = child_blocks,
        };
    }

    fn buildListItemContent(
        self: *Parser,
        first_content: []const u8,
        content_col: usize,
    ) anyerror![]block_ast.BlockNode {
        var container_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer container_lines.deinit(self.allocator);

        try container_lines.append(self.allocator, first_content);

        while (self.pos < self.lines.len) {
            const line = self.peekLine();

            if (isBlankLine(line)) {
                const next = self.peekLineAfterBlanks() orelse break;
                const next_leading = parse_block.countLeadingWhitespace(next);
                if (next_leading < content_col) break;
                try container_lines.append(self.allocator, "");
                self.advanceLine();
                continue;
            }

            const leading = parse_block.countLeadingWhitespace(line);
            if (leading < content_col) break;

            try container_lines.append(self.allocator, line[content_col..]);
            self.advanceLine();
        }

        const child_blocks = try self.parseContainerBlocks(container_lines.items);

        shiftBlockIndents(child_blocks, content_col);

        return child_blocks;
    }

    fn peekLineAfterBlanks(self: *const Parser) ?[]const u8 {
        var p = self.pos;
        while (p < self.lines.len) {
            const line = self.lines[p];
            if (!isBlankLine(line)) return line;
            p += 1;
        }
        return null;
    }

    fn tryParseTable(self: *Parser, header_line: []const u8) !?block_ast.BlockNode {
        if (std.mem.indexOfScalar(u8, header_line, '|') == null) return null;

        if (self.pos + 1 >= self.lines.len) return null;
        const delim_line = self.lines[self.pos + 1];
        if (!parse_table.isDelimiterRow(delim_line)) return null;

        const header_cells = try parse_table.parseCells(self.allocator, header_line);
        errdefer self.allocator.free(header_cells);

        const alignments = try parse_table.parseAlignments(self.allocator, delim_line);
        errdefer self.allocator.free(alignments);

        if (header_cells.len != alignments.len) {
            self.allocator.free(header_cells);
            self.allocator.free(alignments);
            return null;
        }

        self.pos += 2;

        var rows: std.ArrayListUnmanaged([][]const u8) = .empty;
        errdefer {
            for (rows.items) |row| self.allocator.free(row);
            rows.deinit(self.allocator);
        }

        while (self.pos < self.lines.len) {
            const row_line = self.peekLine();
            if (isBlankLine(row_line)) break;
            if (std.mem.indexOfScalar(u8, row_line, '|') == null) break;
            if (parse_block.isBlockLevelStart(row_line)) break;

            const row_cells = try parse_table.parseCells(self.allocator, row_line);
            errdefer self.allocator.free(row_cells);
            try rows.append(self.allocator, row_cells);
            self.advanceLine();
        }

        return .{
            .table = .{
                .header = header_cells,
                .alignments = alignments,
                .rows = try rows.toOwnedSlice(self.allocator),
            },
        };
    }
};

fn isBlankLine(line: []const u8) bool {
    return std.mem.trim(u8, line, parse_block.horizontal_whitespace).len == 0;
}

fn shiftBlockIndents(blocks: []block_ast.BlockNode, offset: usize) void {
    if (offset == 0) return;
    for (blocks) |*b| {
        switch (b.*) {
            .list => |*l| {
                for (l.items) |*it| {
                    it.indent += offset;
                    shiftBlockIndents(it.blocks, offset);
                }
            },
            .blockquote => |*bq| {
                bq.indent += offset;
            },
            else => {},
        }
    }
}

test {
    _ = @import("parse_document_test.zig");
}
