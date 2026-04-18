const std = @import("std");
const ast = @import("../ast.zig");
const parse_block = @import("block.zig");

pub const CellParseError = std.mem.Allocator.Error || error{UnclosedCodeSpan};

/// Accepts an optional leading `|`, then cells of `:?-+:?` separated by `|`.
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

pub fn alignments(allocator: std.mem.Allocator, line: []const u8) ![]ast.Alignment {
    const trimmed = std.mem.trim(u8, line, parse_block.horizontal_whitespace);
    var aligns: std.ArrayListUnmanaged(ast.Alignment) = .{};
    defer aligns.deinit(allocator);

    var iter = CellIterator.init(trimmed);
    while (iter.next()) |cell| {
        const c = std.mem.trim(u8, cell, parse_block.horizontal_whitespace);
        const starts_colon = c.len > 0 and c[0] == ':';
        const ends_colon = c.len > 0 and c[c.len - 1] == ':';

        const col_align: ast.Alignment = if (starts_colon and ends_colon)
            .center
        else if (ends_colon)
            .right
        else
            .left;
        try aligns.append(allocator, col_align);
    }
    if (iter.invalid) return error.UnclosedCodeSpan;

    return try aligns.toOwnedSlice(allocator);
}

/// Splits a row on unescaped `|` and trims horizontal whitespace in each cell.
pub fn cells(allocator: std.mem.Allocator, line: []const u8) CellParseError![][]const u8 {
    const trimmed = std.mem.trim(u8, line, parse_block.horizontal_whitespace);
    var result: std.ArrayListUnmanaged([]const u8) = .{};
    defer result.deinit(allocator);

    var iter = CellIterator.init(trimmed);
    while (iter.next()) |cell| {
        try result.append(allocator, std.mem.trim(u8, cell, parse_block.horizontal_whitespace));
    }
    if (iter.invalid) return error.UnclosedCodeSpan;

    return try result.toOwnedSlice(allocator);
}

pub fn cellCount(line: []const u8) usize {
    const trimmed = std.mem.trim(u8, line, parse_block.horizontal_whitespace);
    var count: usize = 0;
    var iter = CellIterator.init(trimmed);
    while (iter.next()) |_| count += 1;
    if (iter.invalid) return 0;
    return count;
}

/// Iterator that splits a row on `|`, handling optional outer pipes and escaped pipes.
const CellIterator = struct {
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

    fn next(self: *CellIterator) ?[]const u8 {
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

test "alignments" {
    const allocator = std.testing.allocator;
    const aligns = try alignments(allocator, "| :--- | :---: | ---: |");
    defer allocator.free(aligns);

    try std.testing.expectEqual(@as(usize, 3), aligns.len);
    try std.testing.expectEqual(ast.Alignment.left, aligns[0]);
    try std.testing.expectEqual(ast.Alignment.center, aligns[1]);
    try std.testing.expectEqual(ast.Alignment.right, aligns[2]);
}

test "cells handles basic table row" {
    const allocator = std.testing.allocator;
    const parsed = try cells(allocator, "| foo | bar | baz |");
    defer allocator.free(parsed);

    try std.testing.expectEqual(@as(usize, 3), parsed.len);
    try std.testing.expectEqualStrings("foo", parsed[0]);
    try std.testing.expectEqualStrings("bar", parsed[1]);
    try std.testing.expectEqualStrings("baz", parsed[2]);
}

test "cells handles escaped pipe" {
    const allocator = std.testing.allocator;
    const parsed = try cells(allocator, "| foo \\| bar | baz |");
    defer allocator.free(parsed);

    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("foo \\| bar", parsed[0]);
    try std.testing.expectEqualStrings("baz", parsed[1]);
}

test "cells without outer pipes" {
    const allocator = std.testing.allocator;
    const parsed = try cells(allocator, "foo | bar");
    defer allocator.free(parsed);

    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("foo", parsed[0]);
    try std.testing.expectEqualStrings("bar", parsed[1]);
}

test "cells keeps pipe inside code span in one cell" {
    const allocator = std.testing.allocator;
    const parsed = try cells(allocator, "| `a|b` | c |");
    defer allocator.free(parsed);

    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("`a|b`", parsed[0]);
    try std.testing.expectEqualStrings("c", parsed[1]);
}

test "cells keeps pipe inside multi-backtick code span in one cell" {
    const allocator = std.testing.allocator;
    const parsed = try cells(allocator, "| ``a|b`` | c |");
    defer allocator.free(parsed);

    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("``a|b``", parsed[0]);
    try std.testing.expectEqualStrings("c", parsed[1]);
}

test "cells rejects rows with unclosed code span" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnclosedCodeSpan, cells(allocator, "| `a|b | c |"));
}
