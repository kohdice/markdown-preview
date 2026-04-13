const std = @import("std");
const ast = @import("../ast.zig");
const parse_block = @import("block.zig");
const parse_inline = @import("inline.zig");
const parse_link = @import("link.zig");
const parse_table = @import("table.zig");

pub const ParseResult = struct {
    blocks: []ast.BlockNode,
    inline_nodes: []ast.InlineNode,
    inline_next: []ast.InlineRef,
    link_defs: ast.LinkDefMap,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    var parser = Parser{
        .allocator = allocator,
        .inline_builder = parse_inline.InlineBuilder.init(allocator),
        .link_defs = .{},
    };

    if (std.mem.indexOf(u8, source, "]:") != null) {
        var defs_ctx = BlockCursor.initRoot(source);
        try parser.collectLinkDefinitions(&defs_ctx);
    }

    var blocks_ctx = BlockCursor.initRoot(source);
    const blocks = try parser.parseBlocks(&blocks_ctx);
    const inline_storage = parser.inline_builder.finish();

    return .{
        .blocks = blocks,
        .inline_nodes = inline_storage.nodes,
        .inline_next = inline_storage.next,
        .link_defs = parser.link_defs,
    };
}

const Parser = struct {
    allocator: std.mem.Allocator,
    inline_builder: parse_inline.InlineBuilder,
    link_defs: ast.LinkDefMap,
    link_definition_scratch: std.ArrayListUnmanaged(u8) = .empty,
    link_label_scratch: std.ArrayListUnmanaged(u8) = .empty,
    paragraph_lines: std.ArrayListUnmanaged([]const u8) = .empty,
    code_lines: std.ArrayListUnmanaged([]const u8) = .empty,

    fn collectLinkDefinitions(self: *Parser, cursor: *BlockCursor) anyerror!void {
        while (cursor.peekLine()) |line| {
            if (isBlankLine(line)) {
                while (cursor.peekLine()) |blank| {
                    if (!isBlankLine(blank)) break;
                    cursor.advanceLine();
                }
                continue;
            }

            if (parse_block.fence(line)) |fence_info| {
                self.skipFenceBlock(cursor, fence_info);
                continue;
            }

            if (try self.peekLinkDefinition(cursor)) |match| {
                try self.addLinkDef(match.def);
                advanceLines(cursor, match.lines_consumed);
                continue;
            }

            if (parse_block.indentedCodeContent(line) != null) {
                self.skipIndentedCodeBlock(cursor);
                continue;
            }

            if (parse_block.isThematicBreak(line)) {
                cursor.advanceLine();
                continue;
            }

            if (lineStartsTable(cursor.*)) {
                self.skipTable(cursor);
                continue;
            }

            if (parse_block.heading(line) != null) {
                cursor.advanceLine();
                continue;
            }

            if (parse_block.blockquote(line)) |bq| {
                var child_ctx = BlockCursor.initBlockQuote(cursor, bq.indent);
                try self.collectLinkDefinitions(&child_ctx);
                cursor.raw_pos = child_ctx.raw_pos;
                continue;
            }

            if (parse_block.listItem(line) != null) {
                try self.skipListBlock(cursor, .unordered);
                continue;
            }

            if (parse_block.orderedListItem(line) != null) {
                try self.skipListBlock(cursor, .ordered);
                continue;
            }

            try self.skipParagraph(cursor);
        }
    }

    fn parseBlocks(self: *Parser, cursor: *BlockCursor) anyerror![]ast.BlockNode {
        var blocks: std.ArrayListUnmanaged(ast.BlockNode) = .empty;

        while (cursor.peekLine()) |line| {
            if (isBlankLine(line)) {
                while (cursor.peekLine()) |blank| {
                    if (!isBlankLine(blank)) break;
                    cursor.advanceLine();
                }
                try blocks.append(self.allocator, .{ .blank_line = {} });
                continue;
            }

            if (parse_block.fence(line)) |fence_info| {
                try blocks.append(self.allocator, try self.parseFenceBlock(cursor, fence_info));
                continue;
            }

            if (try self.peekLinkDefinition(cursor)) |match| {
                try self.addLinkDef(match.def);
                advanceLines(cursor, match.lines_consumed);
                continue;
            }

            if (parse_block.indentedCodeContent(line) != null) {
                try blocks.append(self.allocator, try self.parseIndentedCodeBlock(cursor));
                continue;
            }

            if (parse_block.isThematicBreak(line)) {
                cursor.advanceLine();
                try blocks.append(self.allocator, .{ .thematic_break = {} });
                continue;
            }

            if (try self.tryParseTable(cursor)) |table_node| {
                try blocks.append(self.allocator, table_node);
                continue;
            }

            if (parse_block.heading(line)) |heading| {
                cursor.advanceLine();
                try blocks.append(self.allocator, .{
                    .heading = .{
                        .level = heading.level,
                        .children = try self.inline_builder.parseSlice(heading.content, &self.link_defs),
                    },
                });
                continue;
            }

            if (parse_block.blockquote(line)) |bq| {
                try blocks.append(self.allocator, try self.parseBlockQuoteBlock(cursor, bq));
                continue;
            }

            if (parse_block.listItem(line) != null) {
                try blocks.append(self.allocator, try self.parseListBlock(cursor, .unordered));
                continue;
            }

            if (parse_block.orderedListItem(line) != null) {
                try blocks.append(self.allocator, try self.parseListBlock(cursor, .ordered));
                continue;
            }

            try blocks.append(self.allocator, try self.parseParagraph(cursor));
        }

        return try blocks.toOwnedSlice(self.allocator);
    }

    fn addLinkDef(self: *Parser, def: parse_link.Definition) anyerror!void {
        const normalized = try parse_link.normalizeReferenceLabelInto(
            &self.link_label_scratch,
            self.allocator,
            def.label,
        );
        if (normalized.len == 0) return;
        if (self.link_defs.get(normalized) != null) return;

        const key = try self.allocator.dupe(u8, normalized);

        const result = try self.link_defs.getOrPut(self.allocator, key);
        std.debug.assert(!result.found_existing);
        result.value_ptr.* = .{
            .url = try parse_link.ownLinkText(self.allocator, def.url),
            .title = if (def.title) |title|
                try parse_link.ownLinkText(self.allocator, title)
            else
                null,
        };
    }

    const LinkDefinitionMatch = struct {
        def: parse_link.Definition,
        lines_consumed: usize,
    };

    const ParagraphLine = struct {
        text: []const u8,
        lazy: bool,
    };

    fn skipParagraph(self: *Parser, cursor: *BlockCursor) anyerror!void {
        var is_first = true;
        while (try self.peekParagraphLine(cursor, is_first)) |paragraph_line| {
            const line = paragraph_line.text;
            if (isBlankLine(line)) break;
            if (!is_first) {
                if (parse_block.setextHeadingUnderline(line) != null) {
                    advanceParagraphLine(cursor, paragraph_line.lazy);
                    break;
                }
                if (!paragraph_line.lazy) {
                    if (parse_block.isBlockLevelStart(line)) break;
                    if (try self.peekLinkDefinition(cursor) != null) break;
                    if (lineStartsTable(cursor.*)) break;
                }
            }

            advanceParagraphLine(cursor, paragraph_line.lazy);
            is_first = false;
        }
    }

    fn parseParagraph(self: *Parser, cursor: *BlockCursor) anyerror!ast.BlockNode {
        self.paragraph_lines.clearRetainingCapacity();
        var is_first = true;

        while (try self.peekParagraphLine(cursor, is_first)) |paragraph_line| {
            const line = paragraph_line.text;
            if (isBlankLine(line)) break;
            if (!is_first) {
                if (parse_block.setextHeadingUnderline(line)) |underline| {
                    advanceParagraphLine(cursor, paragraph_line.lazy);
                    return .{
                        .heading = .{
                            .level = underline.level,
                            .children = try self.inline_builder.parseLines(self.paragraph_lines.items, &self.link_defs),
                        },
                    };
                }
                if (!paragraph_line.lazy) {
                    if (parse_block.isBlockLevelStart(line)) break;
                    if (try self.peekLinkDefinition(cursor) != null) break;
                    if (lineStartsTable(cursor.*)) break;
                }
            }

            try self.paragraph_lines.append(self.allocator, normalizeParagraphLine(line));
            advanceParagraphLine(cursor, paragraph_line.lazy);
            is_first = false;
        }

        return .{
            .paragraph = .{
                .children = try self.inline_builder.parseLines(self.paragraph_lines.items, &self.link_defs),
            },
        };
    }

    fn peekLinkDefinition(self: *Parser, cursor: *const BlockCursor) anyerror!?LinkDefinitionMatch {
        self.link_definition_scratch.clearRetainingCapacity();

        var lookahead = cursor.*;
        var lines_consumed: usize = 0;
        var waiting_for_title_completion = false;
        var best_match: ?LinkDefinitionMatch = null;

        while (lookahead.peekLine()) |line| {
            if (lines_consumed > 0 and isBlankLine(line)) {
                return best_match;
            }

            if (lines_consumed > 0) {
                try self.link_definition_scratch.append(self.allocator, '\n');
            }
            try self.link_definition_scratch.appendSlice(self.allocator, line);
            lines_consumed += 1;

            if (parse_link.definition(self.link_definition_scratch.items)) |def| {
                const match: LinkDefinitionMatch = .{
                    .def = def,
                    .lines_consumed = lines_consumed,
                };
                best_match = match;

                if (def.title != null) return match;

                var next = lookahead;
                next.advanceLine();
                const next_line = next.peekLine() orelse return best_match;
                if (!parse_link.lineCouldStartLinkTitle(next_line)) return best_match;
                waiting_for_title_completion = true;
            } else if (lines_consumed == 1 and parse_link.definitionNeedsDestinationContinuation(line)) {
                // CommonMark allows the destination to begin on the next line.
            } else if (!waiting_for_title_completion) {
                return null;
            }

            lookahead.advanceLine();
        }

        return best_match;
    }

    fn peekParagraphLine(
        self: *Parser,
        cursor: *const BlockCursor,
        is_first: bool,
    ) anyerror!?ParagraphLine {
        if (cursor.peekLine()) |line| {
            return .{
                .text = line,
                .lazy = false,
            };
        }
        if (is_first) return null;
        return try self.peekLazyParagraphContinuation(cursor);
    }

    fn peekLazyParagraphContinuation(
        self: *Parser,
        cursor: *const BlockCursor,
    ) anyerror!?ParagraphLine {
        var parent = switch (cursor.mode) {
            .root => return null,
            .blockquote => cursor.parent.?.*,
            .list_item => return null,
        };
        parent.raw_pos = cursor.raw_pos;

        const line = parent.peekLine() orelse return null;
        if (isBlankLine(line)) return null;
        if (parse_block.isBlockLevelStart(line)) return null;
        if (try self.peekLinkDefinition(&parent) != null) return null;
        if (lineStartsTable(parent)) return null;

        return .{
            .text = line,
            .lazy = true,
        };
    }

    fn parseIndentedCodeBlock(self: *Parser, cursor: *BlockCursor) anyerror!ast.BlockNode {
        self.code_lines.clearRetainingCapacity();

        while (cursor.peekLine()) |line| {
            if (parse_block.indentedCodeContent(line)) |content| {
                try self.code_lines.append(self.allocator, content);
                cursor.advanceLine();
                continue;
            }

            const blank_count = countInterveningCodeBlankLines(cursor);
            if (blank_count == 0) break;

            var remaining = blank_count;
            while (remaining > 0) : (remaining -= 1) {
                try self.code_lines.append(self.allocator, "");
                cursor.advanceLine();
            }
        }

        const content = switch (self.code_lines.items.len) {
            0 => "",
            1 => self.code_lines.items[0],
            else => try joinLines(self.allocator, self.code_lines.items),
        };

        return .{
            .code_block = .{
                .content = content,
            },
        };
    }

    fn skipIndentedCodeBlock(self: *Parser, cursor: *BlockCursor) void {
        _ = self;

        while (cursor.peekLine()) |line| {
            if (parse_block.indentedCodeContent(line) != null) {
                cursor.advanceLine();
                continue;
            }

            const blank_count = countInterveningCodeBlankLines(cursor);
            if (blank_count == 0) break;

            advanceLines(cursor, blank_count);
        }
    }

    fn parseFenceBlock(self: *Parser, cursor: *BlockCursor, fence_info: parse_block.Fence) anyerror!ast.BlockNode {
        const opener = cursor.peekLine() orelse unreachable;
        cursor.advanceLine();

        self.code_lines.clearRetainingCapacity();
        var closer: ?[]const u8 = null;
        while (cursor.peekLine()) |line| {
            if (parse_block.isClosingFence(line, fence_info)) {
                closer = line;
                cursor.advanceLine();
                break;
            }

            try self.code_lines.append(self.allocator, line);
            cursor.advanceLine();
        }

        const content = switch (self.code_lines.items.len) {
            0 => "",
            1 => self.code_lines.items[0],
            else => trySliceSource(self.code_lines.items) orelse try joinLines(self.allocator, self.code_lines.items),
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

    fn skipFenceBlock(self: *Parser, cursor: *BlockCursor, fence_info: parse_block.Fence) void {
        _ = self;
        cursor.advanceLine();
        while (cursor.peekLine()) |line| {
            cursor.advanceLine();
            if (parse_block.isClosingFence(line, fence_info)) break;
        }
    }

    fn parseBlockQuoteBlock(self: *Parser, cursor: *BlockCursor, first_bq: parse_block.BlockQuote) anyerror!ast.BlockNode {
        const base_indent = cursor.blockIndentBase();

        var child_ctx = BlockCursor.initBlockQuote(cursor, first_bq.indent);
        const child_blocks = try self.parseBlocks(&child_ctx);
        cursor.raw_pos = child_ctx.raw_pos;

        return .{
            .blockquote = .{
                .indent = first_bq.indent + base_indent,
                .blocks = child_blocks,
            },
        };
    }

    const AnyListItem = struct {
        indent: usize,
        marker: u8,
        content: []const u8,
        content_col: usize,
        checked: ?bool,
        number: ?[]const u8,
    };

    fn parseAnyListItem(line: []const u8, kind: ast.ListKind) ?AnyListItem {
        return switch (kind) {
            .unordered => if (parse_block.listItem(line)) |item| .{
                .indent = item.indent,
                .marker = item.marker,
                .content = item.content,
                .content_col = item.content_col,
                .checked = item.checked,
                .number = null,
            } else null,
            .ordered => if (parse_block.orderedListItem(line)) |item| .{
                .indent = item.indent,
                .marker = item.marker,
                .content = item.content,
                .content_col = item.content_col,
                .checked = item.checked,
                .number = item.number,
            } else null,
        };
    }

    fn parseListBlock(self: *Parser, cursor: *BlockCursor, kind: ast.ListKind) anyerror!ast.BlockNode {
        var items: std.ArrayListUnmanaged(ast.ListItem) = .empty;
        var min_indent: ?usize = null;
        var prev_child_indent: ?usize = null;
        var list_marker: ?u8 = null;
        var loose = false;
        const base_indent = cursor.blockIndentBase();

        while (cursor.peekLine()) |line| {
            if (isBlankLine(line)) {
                if (skipInterItemBlankLines(cursor, kind, list_marker, min_indent, prev_child_indent)) {
                    loose = true;
                    continue;
                }
                break;
            }

            const item = parseAnyListItem(line, kind) orelse break;
            if (list_marker) |marker| {
                if (item.marker != marker) break;
            } else {
                list_marker = item.marker;
            }
            if (min_indent) |existing_min| {
                if (item.indent < existing_min) break;
                if (item.indent >= prev_child_indent.?) break;
            }

            cursor.advanceLine();
            if (min_indent == null) min_indent = item.indent;
            prev_child_indent = item.content_col;

            var child_ctx = BlockCursor.initListItem(
                cursor,
                item.content,
                item.content_col,
                base_indent + item.content_col,
            );
            const child_blocks = try self.parseBlocks(&child_ctx);
            cursor.raw_pos = child_ctx.raw_pos;
            if (itemBlocksMakeListLoose(child_blocks)) loose = true;

            try items.append(self.allocator, .{
                .indent = item.indent + base_indent,
                .marker = item.marker,
                .number = item.number,
                .checked = item.checked,
                .blocks = child_blocks,
            });
        }

        return .{
            .list = .{
                .kind = kind,
                .items = try items.toOwnedSlice(self.allocator),
                .loose = loose,
            },
        };
    }

    fn skipListBlock(self: *Parser, cursor: *BlockCursor, kind: ast.ListKind) anyerror!void {
        var min_indent: ?usize = null;
        var prev_child_indent: ?usize = null;
        var list_marker: ?u8 = null;

        while (cursor.peekLine()) |line| {
            if (isBlankLine(line)) {
                if (skipInterItemBlankLines(cursor, kind, list_marker, min_indent, prev_child_indent)) continue;
                break;
            }

            const item = parseAnyListItem(line, kind) orelse break;
            if (list_marker) |marker| {
                if (item.marker != marker) break;
            } else {
                list_marker = item.marker;
            }
            if (min_indent) |existing_min| {
                if (item.indent < existing_min) break;
                if (item.indent >= prev_child_indent.?) break;
            }

            cursor.advanceLine();
            if (min_indent == null) min_indent = item.indent;
            prev_child_indent = item.content_col;

            var child_ctx = BlockCursor.initListItem(
                cursor,
                item.content,
                item.content_col,
                cursor.blockIndentBase() + item.content_col,
            );
            try self.collectLinkDefinitions(&child_ctx);
            cursor.raw_pos = child_ctx.raw_pos;
        }
    }

    fn tryParseTable(self: *Parser, cursor: *BlockCursor) anyerror!?ast.BlockNode {
        const header_line = cursor.peekLine() orelse return null;
        if (parse_block.indentedCodeContent(header_line) != null) return null;
        if (std.mem.indexOfScalar(u8, header_line, '|') == null) return null;

        const delim_line = cursor.peekNextLine() orelse return null;
        if (parse_block.indentedCodeContent(delim_line) != null) return null;
        if (!parse_table.isDelimiterRow(delim_line)) return null;

        const header_cells = parse_table.cells(self.allocator, header_line) catch |err| switch (err) {
            error.UnclosedCodeSpan => return null,
            else => return err,
        };

        const alignments = parse_table.alignments(self.allocator, delim_line) catch |err| switch (err) {
            error.UnclosedCodeSpan => return null,
            else => return err,
        };

        if (header_cells.len != alignments.len) return null;

        cursor.advanceLine();
        cursor.advanceLine();

        var header: std.ArrayListUnmanaged(ast.TableCell) = .empty;
        try header.ensureTotalCapacity(self.allocator, header_cells.len);
        for (header_cells) |cell_text| {
            try header.append(self.allocator, .{
                .children = try self.inline_builder.parseSlice(cell_text, &self.link_defs),
            });
        }

        var rows: std.ArrayListUnmanaged([]ast.TableCell) = .empty;
        while (cursor.peekLine()) |row_line| {
            if (isBlankLine(row_line)) break;
            if (parse_block.indentedCodeContent(row_line) != null) break;
            if (std.mem.indexOfScalar(u8, row_line, '|') == null) break;
            if (parse_block.isBlockLevelStart(row_line)) break;

            const row_cells = parse_table.cells(self.allocator, row_line) catch |err| switch (err) {
                error.UnclosedCodeSpan => break,
                else => return err,
            };

            var row: std.ArrayListUnmanaged(ast.TableCell) = .empty;
            try row.ensureTotalCapacity(self.allocator, row_cells.len);
            for (row_cells) |cell_text| {
                try row.append(self.allocator, .{
                    .children = try self.inline_builder.parseSlice(cell_text, &self.link_defs),
                });
            }

            try rows.append(self.allocator, try row.toOwnedSlice(self.allocator));
            cursor.advanceLine();
        }

        return .{
            .table = .{
                .header = try header.toOwnedSlice(self.allocator),
                .alignments = alignments,
                .rows = try rows.toOwnedSlice(self.allocator),
            },
        };
    }

    fn skipTable(self: *Parser, cursor: *BlockCursor) void {
        _ = self;
        cursor.advanceLine();
        cursor.advanceLine();

        while (cursor.peekLine()) |row_line| {
            if (isBlankLine(row_line)) break;
            if (parse_block.indentedCodeContent(row_line) != null) break;
            if (std.mem.indexOfScalar(u8, row_line, '|') == null) break;
            if (parse_block.isBlockLevelStart(row_line)) break;
            cursor.advanceLine();
        }
    }
};

/// Walks block input under root, blockquote, or list-item rules.
const BlockCursor = struct {
    source: []const u8,
    raw_pos: usize,
    mode: Mode,
    parent: ?*const BlockCursor = null,

    const Mode = union(enum) {
        root,
        blockquote: struct {
            outer_indent: usize,
        },
        list_item: struct {
            first_line_pending: bool,
            first_line_content: []const u8,
            content_col: usize,
            indent_offset: usize,
        },
    };

    fn initRoot(source: []const u8) BlockCursor {
        return .{
            .source = source,
            .raw_pos = 0,
            .mode = .root,
        };
    }

    fn initBlockQuote(parent: *const BlockCursor, outer_indent: usize) BlockCursor {
        return .{
            .source = parent.source,
            .raw_pos = parent.raw_pos,
            .mode = .{ .blockquote = .{ .outer_indent = outer_indent } },
            .parent = parent,
        };
    }

    fn initListItem(
        parent: *const BlockCursor,
        first_line_content: []const u8,
        content_col: usize,
        indent_offset: usize,
    ) BlockCursor {
        return .{
            .source = parent.source,
            .raw_pos = parent.raw_pos,
            .mode = .{
                .list_item = .{
                    .first_line_pending = true,
                    .first_line_content = first_line_content,
                    .content_col = content_col,
                    .indent_offset = indent_offset,
                },
            },
            .parent = parent,
        };
    }

    fn peekLine(self: *const BlockCursor) ?[]const u8 {
        return self.peekLineAt(self.raw_pos);
    }

    fn peekNextLine(self: *const BlockCursor) ?[]const u8 {
        var lookahead = self.*;
        _ = lookahead.peekLine() orelse return null;
        lookahead.advanceLine();
        return lookahead.peekLine();
    }

    fn advanceLine(self: *BlockCursor) void {
        switch (self.mode) {
            .root, .blockquote => {
                _ = self.peekLine() orelse return;
                self.raw_pos = nextRawLinePos(self.source, self.raw_pos);
            },
            .list_item => |*list_item| {
                if (list_item.first_line_pending) {
                    list_item.first_line_pending = false;
                    return;
                }

                _ = self.peekLine() orelse return;
                self.raw_pos = nextRawLinePos(self.source, self.raw_pos);
            },
        }
    }

    fn blockIndentBase(self: *const BlockCursor) usize {
        return switch (self.mode) {
            .root, .blockquote => 0,
            .list_item => |list_item| list_item.indent_offset,
        };
    }

    fn peekLineAt(self: *const BlockCursor, raw_pos: usize) ?[]const u8 {
        return switch (self.mode) {
            .root => rawLineAt(self.source, raw_pos),
            .blockquote => |blockquote| blk: {
                const line = self.parent.?.peekLineAt(raw_pos) orelse break :blk null;
                const quote = parse_block.blockquote(line) orelse break :blk null;
                if (quote.indent != blockquote.outer_indent) break :blk null;
                break :blk quote.content;
            },
            .list_item => |list_item| blk: {
                if (raw_pos == self.raw_pos and list_item.first_line_pending) {
                    break :blk list_item.first_line_content;
                }

                var parent = self.parent.?.*;
                parent.raw_pos = raw_pos;
                const line = parent.peekLine() orelse break :blk null;

                if (isBlankLine(line)) {
                    var lookahead = parent;
                    while (lookahead.peekLine()) |candidate| {
                        if (!isBlankLine(candidate)) {
                            break :blk if (parse_block.countLeadingWhitespace(candidate) >= list_item.content_col) "" else null;
                        }
                        lookahead.advanceLine();
                    }
                    break :blk null;
                }

                if (parse_block.countLeadingWhitespace(line) < list_item.content_col) break :blk null;
                break :blk line[list_item.content_col..];
            },
        };
    }
};

fn lineStartsTable(cursor: BlockCursor) bool {
    const line = cursor.peekLine() orelse return false;
    if (parse_block.indentedCodeContent(line) != null) return false;
    if (std.mem.indexOfScalar(u8, line, '|') == null) return false;

    const next_line = cursor.peekNextLine() orelse return false;
    if (parse_block.indentedCodeContent(next_line) != null) return false;
    if (!parse_table.isDelimiterRow(next_line)) return false;

    return parse_table.cellCount(line) == parse_table.cellCount(next_line);
}

fn skipInterItemBlankLines(
    cursor: *BlockCursor,
    kind: ast.ListKind,
    list_marker: ?u8,
    min_indent: ?usize,
    prev_child_indent: ?usize,
) bool {
    const existing_min = min_indent orelse return false;
    const previous_child = prev_child_indent orelse return false;
    const marker = list_marker orelse return false;
    const line = cursor.peekLine() orelse return false;
    if (!isBlankLine(line)) return false;

    var lookahead = cursor.*;
    while (lookahead.peekLine()) |candidate| {
        if (!isBlankLine(candidate)) {
            const continues_list = switch (kind) {
                .unordered => if (parse_block.listItem(candidate)) |item|
                    item.marker == marker and item.indent >= existing_min and item.indent < previous_child
                else
                    false,
                .ordered => if (parse_block.orderedListItem(candidate)) |item|
                    item.marker == marker and item.indent >= existing_min and item.indent < previous_child
                else
                    false,
            };

            if (!continues_list) return false;

            while (cursor.peekLine()) |blank| {
                if (!isBlankLine(blank)) break;
                cursor.advanceLine();
            }
            return true;
        }

        lookahead.advanceLine();
    }

    return false;
}

fn itemBlocksMakeListLoose(blocks: []const ast.BlockNode) bool {
    if (blocks.len <= 1) return false;
    for (blocks) |block| {
        if (block == .blank_line) return true;
    }
    return false;
}

fn rawLineAt(source: []const u8, raw_pos: usize) ?[]const u8 {
    if (raw_pos >= source.len) return null;
    const newline_index = std.mem.indexOfScalarPos(u8, source, raw_pos, '\n') orelse source.len;
    return std.mem.trimEnd(u8, source[raw_pos..newline_index], parse_block.carriage_return);
}

fn nextRawLinePos(source: []const u8, raw_pos: usize) usize {
    if (raw_pos >= source.len) return source.len;
    const newline_index = std.mem.indexOfScalarPos(u8, source, raw_pos, '\n') orelse return source.len;
    return newline_index + 1;
}

fn trySliceSource(lines: []const []const u8) ?[]const u8 {
    if (lines.len <= 1) return null;
    for (lines[0 .. lines.len - 1], lines[1..]) |prev, cur| {
        if (@intFromPtr(cur.ptr) != @intFromPtr(prev.ptr) + prev.len + 1) return null;
    }
    const first = lines[0];
    const last = lines[lines.len - 1];
    const total = (@intFromPtr(last.ptr) + last.len) - @intFromPtr(first.ptr);
    return first.ptr[0..total];
}

fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return "";
    if (lines.len == 1) return lines[0];

    var total_len: usize = 0;
    for (lines, 0..) |line, index| {
        total_len += line.len;
        if (index + 1 < lines.len) total_len += 1;
    }

    const buffer = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (lines, 0..) |line, index| {
        @memcpy(buffer[offset .. offset + line.len], line);
        offset += line.len;
        if (index + 1 < lines.len) {
            buffer[offset] = '\n';
            offset += 1;
        }
    }
    return buffer;
}

fn advanceLines(cursor: *BlockCursor, count: usize) void {
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        cursor.advanceLine();
    }
}

fn advanceParagraphLine(cursor: *BlockCursor, lazy: bool) void {
    if (!lazy) {
        cursor.advanceLine();
        return;
    }

    cursor.raw_pos = nextRawLinePos(cursor.source, cursor.raw_pos);
}

fn isBlankLine(line: []const u8) bool {
    return std.mem.trim(u8, line, parse_block.horizontal_whitespace).len == 0;
}

fn normalizeParagraphLine(line: []const u8) []const u8 {
    return std.mem.trimLeft(u8, line, parse_block.horizontal_whitespace);
}

fn countInterveningCodeBlankLines(cursor: *const BlockCursor) usize {
    var lookahead = cursor.*;
    var blank_count: usize = 0;

    while (lookahead.peekLine()) |line| {
        if (!isBlankLine(line)) break;
        blank_count += 1;
        lookahead.advanceLine();
    }

    if (blank_count == 0) return 0;
    const next_line = lookahead.peekLine() orelse return 0;
    if (parse_block.indentedCodeContent(next_line) == null) return 0;
    return blank_count;
}
