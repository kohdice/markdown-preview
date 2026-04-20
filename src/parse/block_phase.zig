const std = @import("std");
const ast = @import("../ast.zig");
const block_cursor = @import("block_cursor.zig");
const parse_block = @import("block.zig");
const parse_link = @import("link.zig");
const parse_table = @import("table.zig");
const inline_work_mod = @import("inline_work.zig");

const BlockCursor = block_cursor.BlockCursor;
const InlineWork = inline_work_mod.InlineWork;

pub const BlockDocument = struct {
    blocks: []ast.BlockNode,
    inline_work: []const InlineWork,
    link_defs: ast.LinkDefMap,
};

pub fn buildBlockDocument(allocator: std.mem.Allocator, source: []const u8) !BlockDocument {
    var walker = Walker{
        .allocator = allocator,
        .link_defs = .{},
    };
    defer walker.deinitScratch();

    var cursor = BlockCursor.initRoot(source);
    const blocks = try walker.parseBlocks(&cursor);

    return .{
        .blocks = blocks,
        .inline_work = walker.inline_work.items,
        .link_defs = walker.link_defs,
    };
}

const Walker = struct {
    allocator: std.mem.Allocator,
    link_defs: ast.LinkDefMap,
    inline_work: std.ArrayListUnmanaged(InlineWork) = .empty,
    link_definition_scratch: std.ArrayListUnmanaged(u8) = .empty,
    link_label_scratch: std.ArrayListUnmanaged(u8) = .empty,
    paragraph_lines: std.ArrayListUnmanaged([]const u8) = .empty,
    code_lines: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinitScratch(self: *Walker) void {
        self.link_definition_scratch.deinit(self.allocator);
        self.link_label_scratch.deinit(self.allocator);
        self.paragraph_lines.deinit(self.allocator);
        self.code_lines.deinit(self.allocator);
    }

    fn parseBlocks(self: *Walker, cursor: *BlockCursor) anyerror![]ast.BlockNode {
        var blocks: std.ArrayListUnmanaged(ast.BlockNode) = .empty;

        while (cursor.peekLine()) |line| {
            if (block_cursor.isBlankLine(line)) {
                while (cursor.peekLine()) |blank| {
                    if (!block_cursor.isBlankLine(blank)) break;
                    cursor.advanceLine();
                }
                try blocks.append(self.allocator, .blank_line);
                continue;
            }

            if (parse_block.fence(line)) |fence_info| {
                try blocks.append(self.allocator, try self.parseFenceBlock(cursor, fence_info));
                continue;
            }

            if (try self.peekLinkDefinition(cursor)) |match| {
                try self.addLinkDef(match.def);
                block_cursor.advanceLines(cursor, match.lines_consumed);
                continue;
            }

            if (parse_block.indentedCodeContent(line) != null) {
                try blocks.append(self.allocator, try self.parseIndentedCodeBlock(cursor));
                continue;
            }

            if (parse_block.isThematicBreak(line)) {
                cursor.advanceLine();
                try blocks.append(self.allocator, .thematic_break);
                continue;
            }

            if (try self.tryParseTable(cursor)) |table_node| {
                try blocks.append(self.allocator, table_node);
                continue;
            }

            if (parse_block.heading(line)) |heading| {
                cursor.advanceLine();
                const lines_buf = try self.allocator.alloc([]const u8, 1);
                lines_buf[0] = heading.content;
                try blocks.append(self.allocator, .{
                    .heading = .{
                        .level = heading.level,
                        .children = ast.no_inline,
                        .pending_lines = lines_buf,
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

    fn addLinkDef(self: *Walker, def: parse_link.Definition) anyerror!void {
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

    fn parseParagraph(self: *Walker, cursor: *BlockCursor) anyerror!ast.BlockNode {
        self.paragraph_lines.clearRetainingCapacity();
        var is_first = true;

        while (try self.peekParagraphLine(cursor, is_first)) |paragraph_line| {
            const line = paragraph_line.text;
            if (block_cursor.isBlankLine(line)) break;
            if (!is_first) {
                if (parse_block.setextHeadingUnderline(line)) |underline| {
                    block_cursor.advanceParagraphLine(cursor, paragraph_line.lazy);
                    const lines_copy = try self.allocator.dupe([]const u8, self.paragraph_lines.items);
                    return .{
                        .heading = .{
                            .level = underline.level,
                            .children = ast.no_inline,
                            .pending_lines = lines_copy,
                        },
                    };
                }
                if (!paragraph_line.lazy) {
                    if (parse_block.isBlockLevelStart(line)) break;
                    if (try self.peekLinkDefinition(cursor) != null) break;
                    if (block_cursor.lineStartsTable(cursor.*)) break;
                }
            }

            try self.paragraph_lines.append(self.allocator, block_cursor.normalizeParagraphLine(line));
            block_cursor.advanceParagraphLine(cursor, paragraph_line.lazy);
            is_first = false;
        }

        const lines_copy = try self.allocator.dupe([]const u8, self.paragraph_lines.items);
        return .{
            .paragraph = .{
                .children = ast.no_inline,
                .pending_lines = lines_copy,
            },
        };
    }

    fn peekLinkDefinition(self: *Walker, cursor: *const BlockCursor) anyerror!?LinkDefinitionMatch {
        self.link_definition_scratch.clearRetainingCapacity();

        var lookahead = cursor.*;
        var lines_consumed: usize = 0;
        var waiting_for_title_completion = false;
        var best_match: ?LinkDefinitionMatch = null;

        while (lookahead.peekLine()) |line| {
            if (lines_consumed > 0 and block_cursor.isBlankLine(line)) {
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
        self: *Walker,
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
        self: *Walker,
        cursor: *const BlockCursor,
    ) anyerror!?ParagraphLine {
        var parent = switch (cursor.mode) {
            .root => return null,
            .blockquote => cursor.parent.?.*,
            .list_item => return null,
        };
        parent.raw_pos = cursor.raw_pos;

        const line = parent.peekLine() orelse return null;
        if (block_cursor.isBlankLine(line)) return null;
        if (parse_block.isBlockLevelStart(line)) return null;
        if (try self.peekLinkDefinition(&parent) != null) return null;
        if (block_cursor.lineStartsTable(parent)) return null;

        return .{
            .text = line,
            .lazy = true,
        };
    }

    fn parseIndentedCodeBlock(self: *Walker, cursor: *BlockCursor) anyerror!ast.BlockNode {
        self.code_lines.clearRetainingCapacity();

        while (cursor.peekLine()) |line| {
            if (parse_block.indentedCodeContent(line)) |content| {
                try self.code_lines.append(self.allocator, content);
                cursor.advanceLine();
                continue;
            }

            const blank_count = block_cursor.countInterveningCodeBlankLines(cursor);
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

    fn parseFenceBlock(self: *Walker, cursor: *BlockCursor, fence_info: parse_block.Fence) anyerror!ast.BlockNode {
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

    fn parseBlockQuoteBlock(self: *Walker, cursor: *BlockCursor, first_bq: parse_block.BlockQuote) anyerror!ast.BlockNode {
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

    fn parseListBlock(self: *Walker, cursor: *BlockCursor, kind: ast.ListKind) anyerror!ast.BlockNode {
        var items: std.ArrayListUnmanaged(ast.ListItem) = .empty;
        var min_indent: ?usize = null;
        var prev_child_indent: ?usize = null;
        var list_marker: ?u8 = null;
        var loose = false;
        const base_indent = cursor.blockIndentBase();

        while (cursor.peekLine()) |line| {
            if (block_cursor.isBlankLine(line)) {
                if (block_cursor.skipInterItemBlankLines(cursor, kind, list_marker, min_indent, prev_child_indent)) {
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
            if (block_cursor.itemBlocksMakeListLoose(ast.BlockNode, child_blocks)) loose = true;

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

    fn tryParseTable(self: *Walker, cursor: *BlockCursor) anyerror!?ast.BlockNode {
        const header_line = cursor.peekLine() orelse return null;
        if (parse_block.indentedCodeContent(header_line) != null) return null;
        if (std.mem.indexOfScalar(u8, header_line, '|') == null) return null;

        const delim_line = cursor.peekNextLine() orelse return null;
        if (parse_block.indentedCodeContent(delim_line) != null) return null;
        if (!parse_table.isDelimiterRow(delim_line)) return null;

        const header_count = parse_table.countCells(header_line);
        if (header_count == 0) return null;
        const align_count = parse_table.countAlignmentCells(delim_line);
        if (header_count != align_count) return null;

        const alignments = try self.allocator.alloc(ast.Alignment, align_count);
        parse_table.fillAlignments(delim_line, alignments) catch |err| switch (err) {
            error.UnclosedCodeSpan => return null,
        };

        const header = try self.allocator.alloc(ast.TableCell, header_count);
        for (header) |*cell| cell.* = .{};
        {
            var iter = parse_table.iterateCells(header_line);
            var i: usize = 0;
            while (iter.nextTrimmed()) |cell_text| {
                if (i >= header_count) break;
                if (cell_text.len > 0) {
                    try self.inline_work.append(self.allocator, .{
                        .target = &header[i].children,
                        .input = .{ .slice = cell_text },
                    });
                }
                i += 1;
            }
            if (iter.invalid) return null;
        }

        cursor.advanceLine();
        cursor.advanceLine();

        var rows: std.ArrayListUnmanaged([]ast.TableCell) = .empty;
        while (cursor.peekLine()) |row_line| {
            if (block_cursor.isBlankLine(row_line)) break;
            if (parse_block.indentedCodeContent(row_line) != null) break;
            if (std.mem.indexOfScalar(u8, row_line, '|') == null) break;
            if (parse_block.isBlockLevelStart(row_line)) break;

            const row_count = parse_table.countCells(row_line);
            if (row_count == 0) break;

            const row = try self.allocator.alloc(ast.TableCell, row_count);
            for (row) |*cell| cell.* = .{};
            var iter = parse_table.iterateCells(row_line);
            var i: usize = 0;
            while (iter.nextTrimmed()) |cell_text| {
                if (i >= row_count) break;
                if (cell_text.len > 0) {
                    try self.inline_work.append(self.allocator, .{
                        .target = &row[i].children,
                        .input = .{ .slice = cell_text },
                    });
                }
                i += 1;
            }
            if (iter.invalid) break;

            try rows.append(self.allocator, row);
            cursor.advanceLine();
        }

        return .{
            .table = .{
                .header = header,
                .alignments = alignments,
                .rows = try rows.toOwnedSlice(self.allocator),
            },
        };
    }
};

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

test "buildBlockDocument emits paragraph with no_inline placeholder and pending_lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try buildBlockDocument(arena.allocator(), "Hello world\n");
    try std.testing.expectEqual(@as(usize, 1), block_doc.blocks.len);
    try std.testing.expect(block_doc.blocks[0] == .paragraph);
    try std.testing.expectEqual(ast.no_inline, block_doc.blocks[0].paragraph.children);
    try std.testing.expectEqual(@as(usize, 1), block_doc.blocks[0].paragraph.pending_lines.len);
    try std.testing.expectEqualStrings("Hello world", block_doc.blocks[0].paragraph.pending_lines[0]);

    try std.testing.expectEqual(@as(usize, 0), block_doc.inline_work.len);
}

test "buildBlockDocument ATX heading emits heading variant with pending_lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try buildBlockDocument(arena.allocator(), "## Title\n\nBody\n");
    try std.testing.expectEqual(@as(usize, 3), block_doc.blocks.len);
    try std.testing.expect(block_doc.blocks[0] == .heading);
    try std.testing.expectEqual(@as(u8, 2), block_doc.blocks[0].heading.level);
    try std.testing.expectEqual(ast.no_inline, block_doc.blocks[0].heading.children);
    try std.testing.expectEqualStrings("Title", block_doc.blocks[0].heading.pending_lines[0]);

    try std.testing.expect(block_doc.blocks[1] == .blank_line);
    try std.testing.expect(block_doc.blocks[2] == .paragraph);
    try std.testing.expectEqualStrings("Body", block_doc.blocks[2].paragraph.pending_lines[0]);

    try std.testing.expectEqual(@as(usize, 0), block_doc.inline_work.len);
}

test "buildBlockDocument setext heading pivot sets pending_lines on heading not paragraph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try buildBlockDocument(arena.allocator(), "Alpha\nBeta\n====\n");
    try std.testing.expectEqual(@as(usize, 1), block_doc.blocks.len);
    try std.testing.expect(block_doc.blocks[0] == .heading);
    try std.testing.expectEqual(@as(u8, 1), block_doc.blocks[0].heading.level);
    try std.testing.expectEqual(ast.no_inline, block_doc.blocks[0].heading.children);

    try std.testing.expectEqual(@as(usize, 2), block_doc.blocks[0].heading.pending_lines.len);
    try std.testing.expectEqualStrings("Alpha", block_doc.blocks[0].heading.pending_lines[0]);
    try std.testing.expectEqualStrings("Beta", block_doc.blocks[0].heading.pending_lines[1]);

    try std.testing.expectEqual(@as(usize, 0), block_doc.inline_work.len);
}

test "buildBlockDocument blockquote recursion populates inner paragraph pending_lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try buildBlockDocument(arena.allocator(), "> inner one\n> inner two\n");
    try std.testing.expect(block_doc.blocks[0] == .blockquote);
    const bq = block_doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .paragraph);

    try std.testing.expectEqual(@as(usize, 2), bq.blocks[0].paragraph.pending_lines.len);
    try std.testing.expectEqualStrings("inner one", bq.blocks[0].paragraph.pending_lines[0]);
    try std.testing.expectEqualStrings("inner two", bq.blocks[0].paragraph.pending_lines[1]);

    try std.testing.expectEqual(@as(usize, 0), block_doc.inline_work.len);
}

test "buildBlockDocument table emits TableCell array with per-cell slice work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\| a | b |
        \\| :- | --: |
        \\| 1 | 2 |
        \\
    ;
    const block_doc = try buildBlockDocument(arena.allocator(), source);
    try std.testing.expect(block_doc.blocks[0] == .table);
    const t = block_doc.blocks[0].table;
    try std.testing.expectEqual(@as(usize, 2), t.header.len);
    try std.testing.expectEqual(ast.no_inline, t.header[0].children);
    try std.testing.expectEqual(ast.no_inline, t.header[1].children);
    try std.testing.expectEqual(ast.Alignment.left, t.alignments[0]);
    try std.testing.expectEqual(ast.Alignment.right, t.alignments[1]);
    try std.testing.expectEqual(@as(usize, 1), t.rows.len);
    try std.testing.expectEqual(@as(usize, 2), t.rows[0].len);

    try std.testing.expectEqual(@as(usize, 4), block_doc.inline_work.len);
    try std.testing.expect(block_doc.inline_work[0].input == .slice);
    try std.testing.expectEqualStrings("a", block_doc.inline_work[0].input.slice);
    try std.testing.expectEqualStrings("b", block_doc.inline_work[1].input.slice);
    try std.testing.expectEqualStrings("1", block_doc.inline_work[2].input.slice);
    try std.testing.expectEqualStrings("2", block_doc.inline_work[3].input.slice);
    try std.testing.expectEqual(
        @intFromPtr(&t.header[0].children),
        @intFromPtr(block_doc.inline_work[0].target),
    );
    try std.testing.expectEqual(
        @intFromPtr(&t.rows[0][1].children),
        @intFromPtr(block_doc.inline_work[3].target),
    );
}

test "buildBlockDocument collects link definition into link_defs and drops the block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try buildBlockDocument(arena.allocator(), "[anchor]: /target \"Example\"\n\nTrailing paragraph\n");
    try std.testing.expectEqual(@as(u32, 1), block_doc.link_defs.count());

    const def = block_doc.link_defs.get("anchor") orelse return error.TestUnexpected;
    try std.testing.expectEqualStrings("/target", def.url);
    try std.testing.expect(def.title != null);
    try std.testing.expectEqualStrings("Example", def.title.?);

    var saw_paragraph = false;
    for (block_doc.blocks) |b| {
        if (b == .paragraph) saw_paragraph = true;
    }
    try std.testing.expect(saw_paragraph);

    try std.testing.expectEqual(@as(usize, 0), block_doc.inline_work.len);
}

test "buildBlockDocument records forward-referencing link definition before its use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try buildBlockDocument(arena.allocator(), "See [x][ref] later.\n\n[ref]: /u\n");
    try std.testing.expect(block_doc.link_defs.count() == 1);
    const def = block_doc.link_defs.get("ref") orelse return error.TestUnexpected;
    try std.testing.expectEqualStrings("/u", def.url);

    try std.testing.expect(block_doc.blocks[0] == .paragraph);
    try std.testing.expectEqualStrings("See [x][ref] later.", block_doc.blocks[0].paragraph.pending_lines[0]);
}

test "buildBlockDocument captures fenced code block with language and content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try buildBlockDocument(arena.allocator(), "```zig\nconst x = 1;\n```\n");
    try std.testing.expect(block_doc.blocks[0] == .code_fence);
    try std.testing.expectEqualStrings("zig", block_doc.blocks[0].code_fence.language);
    try std.testing.expectEqualStrings("const x = 1;", block_doc.blocks[0].code_fence.content);
    try std.testing.expectEqual(@as(usize, 0), block_doc.inline_work.len);
}

test "buildBlockDocument emits list with per-item child paragraph pending_lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try buildBlockDocument(arena.allocator(), "- alpha\n- beta\n- gamma\n");
    try std.testing.expect(block_doc.blocks[0] == .list);
    const list = block_doc.blocks[0].list;
    try std.testing.expectEqual(ast.ListKind.unordered, list.kind);
    try std.testing.expectEqual(@as(usize, 3), list.items.len);

    try std.testing.expectEqual(@as(usize, 0), block_doc.inline_work.len);
    for (list.items, [_][]const u8{ "alpha", "beta", "gamma" }) |item, expected_text| {
        try std.testing.expectEqual(@as(u8, '-'), item.marker);
        try std.testing.expectEqual(@as(usize, 1), item.blocks.len);
        try std.testing.expect(item.blocks[0] == .paragraph);
        try std.testing.expectEqualStrings(expected_text, item.blocks[0].paragraph.pending_lines[0]);
    }
}

test "buildBlockDocument preserves ordered list number and nested task-list checkbox" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try buildBlockDocument(arena.allocator(), "1. [x] done\n2. [ ] todo\n");
    try std.testing.expect(block_doc.blocks[0] == .list);
    const list = block_doc.blocks[0].list;
    try std.testing.expectEqual(ast.ListKind.ordered, list.kind);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);

    try std.testing.expect(list.items[0].number != null);
    try std.testing.expectEqualStrings("1", list.items[0].number.?);
    try std.testing.expect(list.items[0].checked != null);
    try std.testing.expect(list.items[0].checked.?);

    try std.testing.expect(list.items[1].number != null);
    try std.testing.expectEqualStrings("2", list.items[1].number.?);
    try std.testing.expect(list.items[1].checked != null);
    try std.testing.expect(!list.items[1].checked.?);
}

test "buildBlockDocument does NOT treat link-definition-like line inside fenced code as a link def" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\```
        \\[not-a-ref]: /fake
        \\```
        \\
        \\[real]: /target
        \\
        \\See [x][real].
        \\
    ;
    const block_doc = try buildBlockDocument(arena.allocator(), source);

    try std.testing.expect(block_doc.blocks[0] == .code_fence);
    try std.testing.expectEqualStrings("[not-a-ref]: /fake", block_doc.blocks[0].code_fence.content);

    try std.testing.expectEqual(@as(u32, 1), block_doc.link_defs.count());
    try std.testing.expect(block_doc.link_defs.get("not-a-ref") == null);
    const real = block_doc.link_defs.get("real") orelse return error.TestUnexpected;
    try std.testing.expectEqualStrings("/target", real.url);
}

test "buildBlockDocument emits thematic break and blank line variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try buildBlockDocument(arena.allocator(), "text\n\n---\n");
    try std.testing.expect(block_doc.blocks[0] == .paragraph);
    try std.testing.expect(block_doc.blocks[1] == .blank_line);
    try std.testing.expect(block_doc.blocks[2] == .thematic_break);
}

test "buildBlockDocument empty input yields empty blocks and empty work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const block_doc = try buildBlockDocument(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), block_doc.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), block_doc.inline_work.len);
    try std.testing.expectEqual(@as(u32, 0), block_doc.link_defs.count());
}
