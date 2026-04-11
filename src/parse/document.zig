const std = @import("std");
const ast = @import("../ast.zig");
const parse_block = @import("block.zig");
const parse_table = @import("table.zig");
const parse_link = @import("link.zig");
const parse_inline = @import("inline.zig");

pub const ParseResult = struct {
    blocks: []ast.BlockNode,
    inline_nodes: []ast.InlineNode,
    inline_next: []ast.InlineRef,
    link_defs: ast.LinkDefMap,
};

pub fn parse(allocator: std.mem.Allocator, lines: []const []const u8) !ParseResult {
    var parser = Parser{
        .allocator = allocator,
        .lines = lines,
        .pos = 0,
        .inline_builder = parse_inline.InlineBuilder.init(allocator),
        .link_defs = .{},
    };
    const estimated_link_defs = countLinkDefinitions(lines);
    if (estimated_link_defs > 0) {
        const map_capacity = std.math.cast(u32, estimated_link_defs) orelse return error.Overflow;
        try parser.link_defs.ensureTotalCapacity(allocator, map_capacity);
    }

    const raw_blocks = try parser.parseBlocks();
    const blocks = try parser.resolveInlines(raw_blocks);
    const inline_storage = try parser.inline_builder.finish();

    return .{
        .blocks = blocks,
        .inline_nodes = inline_storage.nodes,
        .inline_next = inline_storage.next,
        .link_defs = parser.link_defs,
    };
}

const RawBlock = union(enum) {
    paragraph: RawParagraph,
    heading: RawHeading,
    blockquote: RawBlockQuote,
    list: RawList,
    code_fence: ast.CodeFence,
    thematic_break: void,
    table: RawTable,
    blank_line: void,

    fn deinit(self: *RawBlock, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .paragraph => |*p| p.deinit(allocator),
            .heading => {},
            .blockquote => |*bq| bq.deinit(allocator),
            .list => |*l| l.deinit(allocator),
            .code_fence => {},
            .thematic_break => {},
            .table => |*t| t.deinit(allocator),
            .blank_line => {},
        }
    }

    fn deinitShallow(self: *RawBlock, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .paragraph => |*p| allocator.free(p.lines),
            .heading => {},
            .blockquote => |*bq| {
                for (bq.blocks) |*b| b.deinitShallow(allocator);
                allocator.free(bq.blocks);
            },
            .list => |*l| {
                for (l.items) |*it| {
                    for (it.blocks) |*b| b.deinitShallow(allocator);
                    allocator.free(it.blocks);
                }
                allocator.free(l.items);
            },
            .code_fence => {},
            .thematic_break => {},
            .table => |*t| {
                allocator.free(t.header);
                for (t.rows) |row| allocator.free(row);
                allocator.free(t.rows);
            },
            .blank_line => {},
        }
    }
};

const RawParagraph = struct {
    lines: [][]const u8,

    fn deinit(self: *RawParagraph, allocator: std.mem.Allocator) void {
        allocator.free(self.lines);
    }
};

const RawHeading = struct {
    level: u8,
    content: []const u8,
};

const RawBlockQuote = struct {
    indent: usize,
    blocks: []RawBlock,

    fn deinit(self: *RawBlockQuote, allocator: std.mem.Allocator) void {
        for (self.blocks) |*b| b.deinit(allocator);
        allocator.free(self.blocks);
    }
};

const RawList = struct {
    kind: ast.ListKind,
    items: []RawListItem,

    fn deinit(self: *RawList, allocator: std.mem.Allocator) void {
        for (self.items) |*it| it.deinit(allocator);
        allocator.free(self.items);
    }
};

const RawListItem = struct {
    indent: usize,
    marker: u8,
    number: ?[]const u8 = null,
    checked: ?bool = null,
    blocks: []RawBlock,

    fn deinit(self: *RawListItem, allocator: std.mem.Allocator) void {
        for (self.blocks) |*b| b.deinit(allocator);
        allocator.free(self.blocks);
    }
};

const RawTable = struct {
    header: [][]const u8,
    alignments: []ast.Alignment,
    rows: [][][]const u8,

    fn deinit(self: *RawTable, allocator: std.mem.Allocator) void {
        allocator.free(self.header);
        allocator.free(self.alignments);
        for (self.rows) |row| allocator.free(row);
        allocator.free(self.rows);
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    pos: usize,
    inline_builder: parse_inline.InlineBuilder,
    link_defs: ast.LinkDefMap,

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

        return parse_table.cellCount(line) == parse_table.cellCount(next_line);
    }

    fn peekNextLine(self: *const Parser) ?[]const u8 {
        if (self.pos + 1 >= self.lines.len) return null;
        return self.lines[self.pos + 1];
    }

    fn parseContainerBlocks(self: *Parser, container_lines: []const []const u8) anyerror![]RawBlock {
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

    fn parseBlocks(self: *Parser) ![]RawBlock {
        var blocks: std.ArrayListUnmanaged(RawBlock) = .empty;
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

            if (parse_block.fence(line)) |fence_info| {
                const cf = try self.parseFenceBlock(fence_info);
                try blocks.append(self.allocator, cf);
                continue;
            }

            if (parse_link.definition(line)) |def| {
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

            if (parse_block.heading(line)) |h| {
                self.advanceLine();
                try blocks.append(self.allocator, .{
                    .heading = .{ .level = h.level, .content = h.content },
                });
                continue;
            }

            if (parse_block.blockquote(line)) |_| {
                const bq = try self.parseBlockQuoteBlock();
                try blocks.append(self.allocator, bq);
                continue;
            }

            if (parse_block.listItem(line) != null) {
                const list = try self.parseListBlock(.unordered);
                try blocks.append(self.allocator, list);
                continue;
            }
            if (parse_block.orderedListItem(line) != null) {
                const list = try self.parseListBlock(.ordered);
                try blocks.append(self.allocator, list);
                continue;
            }

            const p = try self.parseParagraph();
            try blocks.append(self.allocator, p);
        }

        return blocks.toOwnedSlice(self.allocator);
    }

    fn addLinkDef(self: *Parser, def: parse_link.Definition) !void {
        const key = try std.ascii.allocLowerString(self.allocator, def.label);
        errdefer self.allocator.free(key);

        const result = try self.link_defs.getOrPut(self.allocator, key);
        if (result.found_existing) {
            self.allocator.free(key);
        } else {
            result.value_ptr.* = ast.LinkDef{
                .url = def.url,
                .title = def.title,
            };
        }
    }

    fn parseParagraph(self: *Parser) !RawBlock {
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
            if (parse_link.definition(line) != null) break;
            if (self.lineStartsTable()) break;

            try paragraph_lines.append(self.allocator, line);
            self.advanceLine();
        }

        return .{ .paragraph = .{ .lines = try paragraph_lines.toOwnedSlice(self.allocator) } };
    }

    fn parseFenceBlock(self: *Parser, fence_info: parse_block.Fence) !RawBlock {
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

        const content = switch (body_lines.items.len) {
            0 => "",
            1 => body_lines.items[0],
            else => try joinLines(self.allocator, body_lines.items),
        };

        return .{
            .code_fence = .{
                .opener = opener,
                .closer = closer,
                .language = fence_info.language,
                .content = content,
            },
        };
    }

    fn parseBlockQuoteBlock(self: *Parser) anyerror!RawBlock {
        const first_line = self.peekLine();
        const first_bq = parse_block.blockquote(first_line) orelse unreachable;
        const indent = first_bq.indent;

        var child_lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer child_lines.deinit(self.allocator);

        while (self.pos < self.lines.len) {
            const line = self.peekLine();
            const bq = parse_block.blockquote(line) orelse break;
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

    fn parseListBlock(self: *Parser, kind: ast.ListKind) anyerror!RawBlock {
        var items: std.ArrayListUnmanaged(RawListItem) = .empty;
        errdefer {
            for (items.items) |*it| it.deinit(self.allocator);
            items.deinit(self.allocator);
        }

        var min_indent: ?usize = null;
        var prev_child_indent: ?usize = null;

        outer: while (self.pos < self.lines.len) {
            const line = self.peekLine();
            if (isBlankLine(line)) break :outer;

            const item_node: RawListItem = switch (kind) {
                .unordered => blk: {
                    const parsed = parse_block.listItem(line) orelse break :outer;
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
                    const parsed = parse_block.orderedListItem(line) orelse break :outer;
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

    fn buildUnorderedItem(self: *Parser, item: parse_block.ListItem) anyerror!RawListItem {
        const child_blocks = try self.buildListItemContent(item.content, item.content_col);
        return .{
            .indent = item.indent,
            .marker = item.marker,
            .number = null,
            .checked = item.checked,
            .blocks = child_blocks,
        };
    }

    fn buildOrderedItem(self: *Parser, item: parse_block.OrderedListItem) anyerror!RawListItem {
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
    ) anyerror![]RawBlock {
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

    fn tryParseTable(self: *Parser, header_line: []const u8) !?RawBlock {
        if (std.mem.indexOfScalar(u8, header_line, '|') == null) return null;

        if (self.pos + 1 >= self.lines.len) return null;
        const delim_line = self.lines[self.pos + 1];
        if (!parse_table.isDelimiterRow(delim_line)) return null;

        const header_cells = parse_table.cells(self.allocator, header_line) catch |err| switch (err) {
            error.UnclosedCodeSpan => return null,
            else => return err,
        };
        errdefer self.allocator.free(header_cells);

        const alignments = parse_table.alignments(self.allocator, delim_line) catch |err| switch (err) {
            error.UnclosedCodeSpan => return null,
            else => return err,
        };
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

            const row_cells = parse_table.cells(self.allocator, row_line) catch |err| switch (err) {
                error.UnclosedCodeSpan => break,
                else => return err,
            };
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

    fn resolveInlines(self: *Parser, raw_blocks: []RawBlock) anyerror![]ast.BlockNode {
        return self.resolveBlockSlice(raw_blocks);
    }

    fn resolveBlockSlice(self: *Parser, raw_blocks: []RawBlock) anyerror![]ast.BlockNode {
        var blocks: std.ArrayListUnmanaged(ast.BlockNode) = .empty;
        try blocks.ensureTotalCapacity(self.allocator, raw_blocks.len);

        for (raw_blocks) |rb| {
            try blocks.append(self.allocator, try self.resolveOne(rb));
        }

        return blocks.toOwnedSlice(self.allocator);
    }

    fn resolveOne(self: *Parser, rb: RawBlock) anyerror!ast.BlockNode {
        return switch (rb) {
            .paragraph => |p| try self.resolveParagraph(p),
            .heading => |h| try self.resolveHeading(h),
            .blockquote => |bq| try self.resolveBlockQuote(bq),
            .list => |l| try self.resolveList(l),
            .code_fence => |cf| .{ .code_fence = cf },
            .thematic_break => .{ .thematic_break = {} },
            .table => |t| try self.resolveTable(t),
            .blank_line => .{ .blank_line = {} },
        };
    }

    fn resolveParagraph(self: *Parser, p: RawParagraph) anyerror!ast.BlockNode {
        const children = try self.inline_builder.parseLines(p.lines, &self.link_defs);
        return .{ .paragraph = .{ .children = children } };
    }

    fn resolveHeading(self: *Parser, h: RawHeading) anyerror!ast.BlockNode {
        const children = try self.inline_builder.parseSlice(h.content, &self.link_defs);
        return .{ .heading = .{ .level = h.level, .children = children } };
    }

    fn resolveBlockQuote(self: *Parser, bq: RawBlockQuote) anyerror!ast.BlockNode {
        const child_blocks = try self.resolveBlockSlice(bq.blocks);
        return .{ .blockquote = .{ .indent = bq.indent, .blocks = child_blocks } };
    }

    fn resolveList(self: *Parser, l: RawList) anyerror!ast.BlockNode {
        var items: std.ArrayListUnmanaged(ast.ListItem) = .empty;
        errdefer {
            for (items.items) |*it| it.deinit(self.allocator);
            items.deinit(self.allocator);
        }
        try items.ensureTotalCapacity(self.allocator, l.items.len);

        for (l.items) |raw_item| {
            const child_blocks = try self.resolveBlockSlice(raw_item.blocks);
            errdefer {
                for (child_blocks) |*b| @constCast(b).deinit(self.allocator);
                self.allocator.free(child_blocks);
            }
            try items.append(self.allocator, .{
                .indent = raw_item.indent,
                .marker = raw_item.marker,
                .number = raw_item.number,
                .checked = raw_item.checked,
                .blocks = child_blocks,
            });
        }

        return .{ .list = .{ .kind = l.kind, .items = try items.toOwnedSlice(self.allocator) } };
    }

    fn resolveTable(self: *Parser, t: RawTable) anyerror!ast.BlockNode {
        var header_cells: std.ArrayListUnmanaged(ast.TableCell) = .empty;
        errdefer header_cells.deinit(self.allocator);
        try header_cells.ensureTotalCapacity(self.allocator, t.header.len);

        for (t.header) |cell_text| {
            const children = try self.inline_builder.parseSlice(cell_text, &self.link_defs);
            try header_cells.append(self.allocator, .{ .children = children });
        }

        var rows: std.ArrayListUnmanaged([]ast.TableCell) = .empty;
        errdefer {
            for (rows.items) |row| {
                self.allocator.free(row);
            }
            rows.deinit(self.allocator);
        }
        try rows.ensureTotalCapacity(self.allocator, t.rows.len);

        for (t.rows) |raw_row| {
            var row_cells: std.ArrayListUnmanaged(ast.TableCell) = .empty;
            errdefer row_cells.deinit(self.allocator);
            try row_cells.ensureTotalCapacity(self.allocator, raw_row.len);

            for (raw_row) |cell_text| {
                const children = try self.inline_builder.parseSlice(cell_text, &self.link_defs);
                try row_cells.append(self.allocator, .{ .children = children });
            }
            try rows.append(self.allocator, try row_cells.toOwnedSlice(self.allocator));
        }

        return .{
            .table = .{
                .header = try header_cells.toOwnedSlice(self.allocator),
                .alignments = t.alignments,
                .rows = try rows.toOwnedSlice(self.allocator),
            },
        };
    }
};

fn countLinkDefinitions(lines: []const []const u8) usize {
    var total: usize = 0;
    for (lines) |line| {
        if (parse_link.definition(line) != null) total += 1;
    }
    return total;
}

fn joinLines(allocator: std.mem.Allocator, lines_slice: []const []const u8) ![]const u8 {
    if (lines_slice.len == 0) return "";
    if (lines_slice.len == 1) return lines_slice[0];

    var total_len: usize = 0;
    for (lines_slice, 0..) |line, i| {
        total_len += line.len;
        if (i + 1 < lines_slice.len) total_len += 1;
    }

    const buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);

    var offset: usize = 0;
    for (lines_slice, 0..) |line, i| {
        @memcpy(buf[offset .. offset + line.len], line);
        offset += line.len;
        if (i + 1 < lines_slice.len) {
            buf[offset] = '\n';
            offset += 1;
        }
    }
    return buf;
}

fn isBlankLine(line: []const u8) bool {
    return std.mem.trim(u8, line, parse_block.horizontal_whitespace).len == 0;
}

fn shiftBlockIndents(blocks: []RawBlock, offset: usize) void {
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
