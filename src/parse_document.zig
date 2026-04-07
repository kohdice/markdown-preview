const std = @import("std");
const block_ast = @import("block_ast.zig");
const parse_block = @import("parse_block.zig");
const parse_table = @import("parse_table.zig");
const parse_link = @import("parse_link.zig");

pub fn parseDocument(allocator: std.mem.Allocator, input: []const u8) !block_ast.Document {
    var parser = Parser{
        .allocator = allocator,
        .input = input,
        .pos = 0,
        .link_defs = .{},
        .has_trailing_newline = input.len > 0 and input[input.len - 1] == '\n',
    };

    const blocks = parser.parseBlocks() catch |err| {
        parser.deinitLinkDefs();
        return err;
    };

    return .{
        .blocks = blocks,
        .link_defs = parser.link_defs,
        .has_trailing_newline = parser.has_trailing_newline,
    };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    pos: usize,
    link_defs: parse_link.LinkDefMap,
    has_trailing_newline: bool,

    fn deinitLinkDefs(self: *Parser) void {
        var it = self.link_defs.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.link_defs.deinit(self.allocator);
    }

    fn peekLine(self: *const Parser) []const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.input, self.pos, '\n') orelse self.input.len;
        return std.mem.trimEnd(u8, self.input[self.pos..end], parse_block.carriage_return);
    }

    fn advanceLine(self: *Parser) void {
        const end = std.mem.indexOfScalarPos(u8, self.input, self.pos, '\n') orelse self.input.len;
        self.pos = if (end < self.input.len) end + 1 else end;
    }

    fn lineStartsTable(self: *const Parser) bool {
        const line = self.peekLine();
        if (std.mem.indexOfScalar(u8, line, '|') == null) return false;

        const next_line = self.peekNextLine() orelse return false;
        if (!parse_table.isDelimiterRow(next_line)) return false;

        return parse_table.countCells(line) == parse_table.countCells(next_line);
    }

    fn wouldStartValidBlockQuoteTable(self: *const Parser) bool {
        const line = self.peekLine();
        const first_bq = parse_block.parseBlockQuote(line) orelse return false;
        if (std.mem.indexOfScalar(u8, first_bq.content, '|') == null) return false;

        const next_line = self.peekNextLine() orelse return false;
        const next_bq = parse_block.parseBlockQuote(next_line) orelse return false;
        if (!parse_table.isDelimiterRow(next_bq.content)) return false;

        return parse_table.countCells(first_bq.content) == parse_table.countCells(next_bq.content);
    }

    fn peekNextLine(self: *const Parser) ?[]const u8 {
        const cur_end = std.mem.indexOfScalarPos(u8, self.input, self.pos, '\n') orelse self.input.len;
        if (cur_end >= self.input.len) return null;
        const next_start = cur_end + 1;
        if (next_start >= self.input.len) return null;
        const next_end = std.mem.indexOfScalarPos(u8, self.input, next_start, '\n') orelse self.input.len;
        return std.mem.trimEnd(u8, self.input[next_start..next_end], parse_block.carriage_return);
    }

    fn parseBlocks(self: *Parser) ![]block_ast.BlockNode {
        var blocks: std.ArrayListUnmanaged(block_ast.BlockNode) = .empty;
        errdefer {
            for (blocks.items) |*b| b.deinit(self.allocator);
            blocks.deinit(self.allocator);
        }

        while (self.pos < self.input.len) {
            if (isBlankLine(self.peekLine())) {
                while (self.pos < self.input.len and isBlankLine(self.peekLine())) {
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
        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer lines.deinit(self.allocator);

        if (self.pos < self.input.len and !isBlankLine(self.peekLine())) {
            try lines.append(self.allocator, self.peekLine());
            self.advanceLine();
        }

        while (self.pos < self.input.len) {
            const line = self.peekLine();
            if (isBlankLine(line)) break;
            if (parse_block.isBlockLevelStart(line)) break;
            if (parse_link.parseLinkDefinition(line) != null) break;
            if (self.lineStartsTable()) break;

            try lines.append(self.allocator, line);
            self.advanceLine();
        }

        return .{ .paragraph = .{ .lines = try lines.toOwnedSlice(self.allocator) } };
    }

    fn parseFenceBlock(self: *Parser, fence_info: parse_block.Fence) !block_ast.BlockNode {
        const opener = self.peekLine();
        self.advanceLine();

        var body_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer body_lines.deinit(self.allocator);

        var closer: ?[]const u8 = null;
        while (self.pos < self.input.len) {
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

    fn parseBlockQuoteBlock(self: *Parser) !block_ast.BlockNode {
        if (try self.tryParseBlockQuoteTable()) |bq_with_table| {
            return bq_with_table;
        }

        const first_line = self.peekLine();
        const first_bq = parse_block.parseBlockQuote(first_line) orelse unreachable;
        const indent = first_bq.indent;

        var content_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer content_lines.deinit(self.allocator);

        while (self.pos < self.input.len) {
            const line = self.peekLine();
            const bq = parse_block.parseBlockQuote(line) orelse break;
            if (bq.indent != indent) break;
            if (self.wouldStartValidBlockQuoteTable()) break;
            try content_lines.append(self.allocator, bq.content);
            self.advanceLine();
        }

        const child_blocks = try self.parseBlockQuoteChildren(content_lines.items);
        errdefer {
            for (child_blocks) |*b| b.deinit(self.allocator);
            self.allocator.free(child_blocks);
        }

        return .{
            .blockquote = .{
                .indent = indent,
                .blocks = child_blocks,
            },
        };
    }

    fn parseBlockQuoteChildren(
        self: *Parser,
        content_lines: []const []const u8,
    ) ![]block_ast.BlockNode {
        var children: std.ArrayListUnmanaged(block_ast.BlockNode) = .empty;
        errdefer {
            for (children.items) |*b| b.deinit(self.allocator);
            children.deinit(self.allocator);
        }

        var i: usize = 0;
        while (i < content_lines.len) {
            if (parse_block.parseBlockQuote(content_lines[i]) != null) {
                var nested_content: std.ArrayListUnmanaged([]const u8) = .empty;
                defer nested_content.deinit(self.allocator);

                while (i < content_lines.len) {
                    const nested_bq = parse_block.parseBlockQuote(content_lines[i]) orelse break;
                    try nested_content.append(self.allocator, nested_bq.content);
                    i += 1;
                }

                const nested_children = try self.parseBlockQuoteChildren(nested_content.items);
                {
                    errdefer {
                        for (nested_children) |*b| b.deinit(self.allocator);
                        self.allocator.free(nested_children);
                    }
                    try children.append(self.allocator, .{
                        .blockquote = .{
                            .indent = 0,
                            .blocks = nested_children,
                        },
                    });
                }
            } else {
                var para_lines: std.ArrayListUnmanaged([]const u8) = .empty;
                defer para_lines.deinit(self.allocator);

                while (i < content_lines.len) {
                    if (parse_block.parseBlockQuote(content_lines[i]) != null) break;
                    try para_lines.append(self.allocator, content_lines[i]);
                    i += 1;
                }

                const lines_slice = try para_lines.toOwnedSlice(self.allocator);
                {
                    errdefer self.allocator.free(lines_slice);
                    try children.append(self.allocator, .{
                        .paragraph = .{ .lines = lines_slice },
                    });
                }
            }
        }

        return children.toOwnedSlice(self.allocator);
    }

    fn parseListBlock(self: *Parser, kind: block_ast.ListKind) !block_ast.BlockNode {
        var items: std.ArrayListUnmanaged(block_ast.ListItem) = .empty;
        errdefer {
            for (items.items) |*it| it.deinit(self.allocator);
            items.deinit(self.allocator);
        }

        while (self.pos < self.input.len) {
            const line = self.peekLine();
            if (isBlankLine(line)) break;

            const item_node: block_ast.ListItem = switch (kind) {
                .unordered => blk: {
                    const parsed = parse_block.parseListItem(line) orelse break;
                    self.advanceLine();
                    break :blk try self.buildUnorderedItem(parsed);
                },
                .ordered => blk: {
                    const parsed = parse_block.parseOrderedListItem(line) orelse break;
                    self.advanceLine();
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

    fn buildUnorderedItem(self: *Parser, item: parse_block.ListItem) !block_ast.ListItem {
        const content_col = item.indent + parse_block.marker_suffix_width;
        const child_blocks = try self.buildListItemContent(item.content, content_col);
        return .{
            .indent = item.indent,
            .marker = item.marker,
            .number = null,
            .checked = item.checked,
            .blocks = child_blocks,
        };
    }

    fn buildOrderedItem(self: *Parser, item: parse_block.OrderedListItem) !block_ast.ListItem {
        const content_col = item.indent + item.number.len + parse_block.marker_suffix_width;
        const child_blocks = try self.buildListItemContent(item.content, content_col);
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
    ) ![]block_ast.BlockNode {
        var paragraph_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer paragraph_lines.deinit(self.allocator);

        try paragraph_lines.append(self.allocator, first_content);

        while (self.pos < self.input.len) {
            const line = self.peekLine();
            if (!parse_block.isListContinuation(line, content_col)) break;
            const leading = parse_block.countLeadingWhitespace(line);
            try paragraph_lines.append(self.allocator, line[leading..]);
            self.advanceLine();
        }

        const lines_slice = try paragraph_lines.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(lines_slice);

        var child_blocks: std.ArrayListUnmanaged(block_ast.BlockNode) = .empty;
        errdefer {
            for (child_blocks.items) |*b| b.deinit(self.allocator);
            child_blocks.deinit(self.allocator);
        }

        try child_blocks.append(self.allocator, .{
            .paragraph = .{ .lines = lines_slice },
        });

        return try child_blocks.toOwnedSlice(self.allocator);
    }

    fn tryParseTable(self: *Parser, header_line: []const u8) !?block_ast.BlockNode {
        if (std.mem.indexOfScalar(u8, header_line, '|') == null) return null;

        const header_end = std.mem.indexOfScalarPos(u8, self.input, self.pos, '\n') orelse self.input.len;
        const after_header = if (header_end < self.input.len) header_end + 1 else header_end;
        if (after_header >= self.input.len) return null;

        const delim_end = std.mem.indexOfScalarPos(u8, self.input, after_header, '\n') orelse self.input.len;
        const delim_line = std.mem.trimEnd(u8, self.input[after_header..delim_end], parse_block.carriage_return);
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

        self.pos = if (delim_end < self.input.len) delim_end + 1 else delim_end;

        var rows: std.ArrayListUnmanaged([][]const u8) = .empty;
        errdefer {
            for (rows.items) |row| self.allocator.free(row);
            rows.deinit(self.allocator);
        }

        while (self.pos < self.input.len) {
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

    fn tryParseBlockQuoteTable(self: *Parser) !?block_ast.BlockNode {
        const save_pos = self.pos;

        const first_line = self.peekLine();
        const first_bq = parse_block.parseBlockQuote(first_line) orelse return null;
        if (std.mem.indexOfScalar(u8, first_bq.content, '|') == null) return null;
        const header_content = first_bq.content;
        const indent = first_bq.indent;
        self.advanceLine();

        if (self.pos >= self.input.len) {
            self.pos = save_pos;
            return null;
        }
        const second_line = self.peekLine();
        const second_bq = parse_block.parseBlockQuote(second_line) orelse {
            self.pos = save_pos;
            return null;
        };
        if (!parse_table.isDelimiterRow(second_bq.content)) {
            self.pos = save_pos;
            return null;
        }
        const delim_content = second_bq.content;
        self.advanceLine();

        const header_cells = try parse_table.parseCells(self.allocator, header_content);
        errdefer self.allocator.free(header_cells);

        const alignments = try parse_table.parseAlignments(self.allocator, delim_content);
        errdefer self.allocator.free(alignments);

        if (header_cells.len != alignments.len) {
            self.allocator.free(header_cells);
            self.allocator.free(alignments);
            self.pos = save_pos;
            return null;
        }

        var rows: std.ArrayListUnmanaged([][]const u8) = .empty;
        errdefer {
            for (rows.items) |row| self.allocator.free(row);
            rows.deinit(self.allocator);
        }

        while (self.pos < self.input.len) {
            const row_line = self.peekLine();
            const row_bq = parse_block.parseBlockQuote(row_line) orelse break;
            if (std.mem.indexOfScalar(u8, row_bq.content, '|') == null) break;
            if (parse_block.isBlockLevelStart(row_bq.content)) break;

            const row_cells = try parse_table.parseCells(self.allocator, row_bq.content);
            errdefer self.allocator.free(row_cells);
            try rows.append(self.allocator, row_cells);
            self.advanceLine();
        }

        const rows_slice = try rows.toOwnedSlice(self.allocator);
        errdefer {
            for (rows_slice) |row| self.allocator.free(row);
            self.allocator.free(rows_slice);
        }

        var child_blocks: std.ArrayListUnmanaged(block_ast.BlockNode) = .empty;
        errdefer {
            for (child_blocks.items) |*b| b.deinit(self.allocator);
            child_blocks.deinit(self.allocator);
        }

        try child_blocks.append(self.allocator, .{
            .table = .{
                .header = header_cells,
                .alignments = alignments,
                .rows = rows_slice,
            },
        });

        return .{
            .blockquote = .{
                .indent = indent,
                .blocks = try child_blocks.toOwnedSlice(self.allocator),
            },
        };
    }
};

fn isBlankLine(line: []const u8) bool {
    return std.mem.trim(u8, line, parse_block.horizontal_whitespace).len == 0;
}

test {
    _ = @import("parse_document_test.zig");
}
