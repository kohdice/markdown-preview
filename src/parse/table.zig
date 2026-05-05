const std = @import("std");
const ast = @import("../ast.zig");
const parse_block = @import("block.zig");

const CellParseError = std.mem.Allocator.Error || error{UnclosedCodeSpan};

pub fn isDelimiterRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, parse_block.horizontal_whitespace);
    if (trimmed.len == 0) return false;

    var col_count: usize = 0;
    var iter = CellIterator.init(trimmed);
    while (iter.next()) |cell| {
        const c = std.mem.trim(u8, cell, parse_block.horizontal_whitespace);
        if (!isDelimiterCell(c)) return false;
        col_count += 1;
    }
    return col_count > 0;
}

fn isDelimiterCell(cell: []const u8) bool {
    if (cell.len == 0) return false;
    var i: usize = 0;
    if (i < cell.len and cell[i] == ':') i += 1;

    var dash_count: usize = 0;
    while (i < cell.len and cell[i] == '-') : (i += 1) {
        dash_count += 1;
    }
    if (dash_count == 0) return false;

    if (i < cell.len and cell[i] == ':') i += 1;
    return i == cell.len;
}

pub fn countCells(line: []const u8) usize {
    const trimmed = std.mem.trim(u8, line, parse_block.horizontal_whitespace);
    var count: usize = 0;
    var iter = CellIterator.init(trimmed);
    while (iter.next()) |_| count += 1;
    if (iter.invalid) return 0;
    return count;
}

fn fillCells(line: []const u8, out: [][]const u8) CellParseError!void {
    const trimmed = std.mem.trim(u8, line, parse_block.horizontal_whitespace);
    var iter = CellIterator.init(trimmed);
    var i: usize = 0;
    while (iter.next()) |cell| {
        if (i >= out.len) return error.UnclosedCodeSpan;
        out[i] = std.mem.trim(u8, cell, parse_block.horizontal_whitespace);
        i += 1;
    }
    if (iter.invalid) return error.UnclosedCodeSpan;
    if (i != out.len) return error.UnclosedCodeSpan;
}

pub fn fillAlignments(line: []const u8, out: []ast.Alignment) error{UnclosedCodeSpan}!void {
    const trimmed = std.mem.trim(u8, line, parse_block.horizontal_whitespace);
    var iter = CellIterator.init(trimmed);
    var i: usize = 0;
    while (iter.next()) |cell| {
        if (i >= out.len) return error.UnclosedCodeSpan;
        const c = std.mem.trim(u8, cell, parse_block.horizontal_whitespace);
        const starts_colon = c.len > 0 and c[0] == ':';
        const ends_colon = c.len > 0 and c[c.len - 1] == ':';
        out[i] = if (starts_colon and ends_colon)
            .center
        else if (ends_colon)
            .right
        else
            .left;
        i += 1;
    }
    if (iter.invalid) return error.UnclosedCodeSpan;
    if (i != out.len) return error.UnclosedCodeSpan;
}

pub fn iterateCells(line: []const u8) CellIterator {
    const trimmed = std.mem.trim(u8, line, parse_block.horizontal_whitespace);
    return CellIterator.init(trimmed);
}

pub const CellIterator = struct {
    text: []const u8,
    pos: usize,
    done: bool,
    invalid: bool,
    code_span_delim_len: ?usize,

    fn init(text: []const u8) CellIterator {
        var start: usize = 0;
        if (text.len > 0 and text[0] == '|') start = 1;
        return .{
            .text = text,
            .pos = start,
            .done = false,
            .invalid = false,
            .code_span_delim_len = null,
        };
    }

    pub fn nextTrimmed(self: *CellIterator) ?[]const u8 {
        const cell = self.next() orelse return null;
        return std.mem.trim(u8, cell, parse_block.horizontal_whitespace);
    }

    pub fn next(self: *CellIterator) ?[]const u8 {
        if (self.done) return null;
        if (self.pos >= self.text.len) {
            self.done = true;
            return null;
        }

        const start = self.pos;
        while (self.pos < self.text.len) {
            if (self.text[self.pos] == '\\' and self.pos + 1 < self.text.len) {
                self.pos += 2;
                continue;
            }
            if (self.text[self.pos] == '`') {
                const delim_len = parse_block.countRepeatedByte(self.text[self.pos..], '`');
                if (self.code_span_delim_len) |open_len| {
                    if (delim_len == open_len) self.code_span_delim_len = null;
                } else {
                    self.code_span_delim_len = delim_len;
                }
                self.pos += delim_len;
                continue;
            }
            if (self.text[self.pos] == '|' and self.code_span_delim_len == null) {
                const cell = self.text[start..self.pos];
                self.pos += 1;

                if (self.pos >= self.text.len or
                    std.mem.trim(u8, self.text[self.pos..], parse_block.horizontal_whitespace).len == 0)
                {
                    self.done = true;
                }
                return cell;
            }
            self.pos += 1;
        }

        self.done = true;
        if (self.code_span_delim_len != null) self.invalid = true;
        const cell = self.text[start..self.pos];
        if (std.mem.trim(u8, cell, parse_block.horizontal_whitespace).len == 0) return null;
        return cell;
    }
};

test "isDelimiterRow recognizes valid delimiters" {
    try std.testing.expect(isDelimiterRow("| --- | --- |"));
    try std.testing.expect(isDelimiterRow("|---|---|"));
    try std.testing.expect(isDelimiterRow("| :---: | ---: |"));
    try std.testing.expect(isDelimiterRow("--- | ---"));
}

test "isDelimiterRow rejects invalid rows" {
    try std.testing.expect(!isDelimiterRow("| abc | def |"));
    try std.testing.expect(!isDelimiterRow(""));
    try std.testing.expect(!isDelimiterRow("|||"));
}

test "fillAlignments writes three alignments" {
    const line = "| :--- | :---: | ---: |";
    try std.testing.expectEqual(@as(usize, 3), countCells(line));
    var slots: [3]ast.Alignment = undefined;
    try fillAlignments(line, &slots);
    try std.testing.expectEqual(ast.Alignment.left, slots[0]);
    try std.testing.expectEqual(ast.Alignment.center, slots[1]);
    try std.testing.expectEqual(ast.Alignment.right, slots[2]);
}

test "fillCells handles basic table row" {
    try std.testing.expectEqual(@as(usize, 3), countCells("| foo | bar | baz |"));
    var spans: [3][]const u8 = undefined;
    try fillCells("| foo | bar | baz |", &spans);
    try std.testing.expectEqualStrings("foo", spans[0]);
    try std.testing.expectEqualStrings("bar", spans[1]);
    try std.testing.expectEqualStrings("baz", spans[2]);
}

test "fillCells handles escaped pipe" {
    try std.testing.expectEqual(@as(usize, 2), countCells("| foo \\| bar | baz |"));
    var spans: [2][]const u8 = undefined;
    try fillCells("| foo \\| bar | baz |", &spans);
    try std.testing.expectEqualStrings("foo \\| bar", spans[0]);
    try std.testing.expectEqualStrings("baz", spans[1]);
}

test "fillCells without outer pipes" {
    try std.testing.expectEqual(@as(usize, 2), countCells("foo | bar"));
    var spans: [2][]const u8 = undefined;
    try fillCells("foo | bar", &spans);
    try std.testing.expectEqualStrings("foo", spans[0]);
    try std.testing.expectEqualStrings("bar", spans[1]);
}

test "fillCells keeps pipe inside code span in one cell" {
    try std.testing.expectEqual(@as(usize, 2), countCells("| `a|b` | c |"));
    var spans: [2][]const u8 = undefined;
    try fillCells("| `a|b` | c |", &spans);
    try std.testing.expectEqualStrings("`a|b`", spans[0]);
    try std.testing.expectEqualStrings("c", spans[1]);
}

test "fillCells keeps pipe inside multi-backtick code span in one cell" {
    try std.testing.expectEqual(@as(usize, 2), countCells("| ``a|b`` | c |"));
    var spans: [2][]const u8 = undefined;
    try fillCells("| ``a|b`` | c |", &spans);
    try std.testing.expectEqualStrings("``a|b``", spans[0]);
    try std.testing.expectEqualStrings("c", spans[1]);
}

test "fillCells rejects rows with unclosed code span" {
    var spans: [3][]const u8 = undefined;
    try std.testing.expectError(error.UnclosedCodeSpan, fillCells("| `a|b | c |", &spans));
}
