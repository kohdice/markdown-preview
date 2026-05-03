const std = @import("std");
const ast = @import("../ast.zig");
const parse_block = @import("block.zig");
const parse_table = @import("table.zig");

pub const BlockCursor = struct {
    source: []const u8,
    raw_pos: usize,
    mode: Mode,
    parent: ?*const BlockCursor = null,

    pub const Mode = union(enum) {
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

    pub fn initRoot(source: []const u8) BlockCursor {
        return .{
            .source = source,
            .raw_pos = 0,
            .mode = .root,
        };
    }

    pub fn initBlockQuote(parent: *const BlockCursor, outer_indent: usize) BlockCursor {
        return .{
            .source = parent.source,
            .raw_pos = parent.raw_pos,
            .mode = .{ .blockquote = .{ .outer_indent = outer_indent } },
            .parent = parent,
        };
    }

    pub fn initListItem(
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

    pub fn peekLine(self: *const BlockCursor) ?[]const u8 {
        return self.peekLineAt(self.raw_pos);
    }

    pub fn peekNextLine(self: *const BlockCursor) ?[]const u8 {
        var lookahead = self.*;
        _ = lookahead.peekLine() orelse return null;
        lookahead.advanceLine();
        return lookahead.peekLine();
    }

    pub fn advanceLine(self: *BlockCursor) void {
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

    pub fn blockIndentBase(self: *const BlockCursor) usize {
        return switch (self.mode) {
            .root, .blockquote => 0,
            .list_item => |list_item| list_item.indent_offset,
        };
    }

    pub fn peekLineAt(self: *const BlockCursor, raw_pos: usize) ?[]const u8 {
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

pub fn lineStartsTable(cursor: BlockCursor) bool {
    const line = cursor.peekLine() orelse return false;
    if (parse_block.indentedCodeContent(line) != null) return false;
    if (std.mem.findScalar(u8, line, '|') == null) return false;

    const next_line = cursor.peekNextLine() orelse return false;
    if (parse_block.indentedCodeContent(next_line) != null) return false;
    if (!parse_table.isDelimiterRow(next_line)) return false;

    return parse_table.countCells(line) == parse_table.countCells(next_line);
}

pub fn skipInterItemBlankLines(
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

pub fn itemBlocksMakeListLoose(comptime T: type, blocks: []const T) bool {
    if (blocks.len <= 1) return false;
    for (blocks) |block| {
        if (block == .blank_line) return true;
    }
    return false;
}

fn rawLineAt(source: []const u8, raw_pos: usize) ?[]const u8 {
    if (raw_pos >= source.len) return null;
    const newline_index = std.mem.findScalarPos(u8, source, raw_pos, '\n') orelse source.len;
    return std.mem.trimEnd(u8, source[raw_pos..newline_index], parse_block.carriage_return);
}

fn nextRawLinePos(source: []const u8, raw_pos: usize) usize {
    if (raw_pos >= source.len) return source.len;
    const newline_index = std.mem.findScalarPos(u8, source, raw_pos, '\n') orelse return source.len;
    return newline_index + 1;
}

pub fn advanceLines(cursor: *BlockCursor, count: usize) void {
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        cursor.advanceLine();
    }
}

pub fn advanceParagraphLine(cursor: *BlockCursor, lazy: bool) void {
    if (!lazy) {
        cursor.advanceLine();
        return;
    }

    cursor.raw_pos = nextRawLinePos(cursor.source, cursor.raw_pos);
}

pub fn isBlankLine(line: []const u8) bool {
    return std.mem.trim(u8, line, parse_block.horizontal_whitespace).len == 0;
}

pub fn normalizeParagraphLine(line: []const u8) []const u8 {
    return std.mem.trimStart(u8, line, parse_block.horizontal_whitespace);
}

pub fn countInterveningCodeBlankLines(cursor: *const BlockCursor) usize {
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
