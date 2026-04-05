const std = @import("std");

pub const Alignment = enum { left, center, right };

pub const Table = struct {
    header: []const []const u8,
    alignments: []const Alignment,
    rows: []const []const []const u8,
    col_count: usize,
};

/// Check if a line is a valid table delimiter row.
/// Pattern: optional leading `|`, then cells of `:?-+:?` separated by `|`.
pub fn isDelimiterRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;

    var col_count: usize = 0;
    var iter = CellIterator.init(trimmed);
    while (iter.next()) |cell| {
        const c = std.mem.trim(u8, cell, " \t");
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

/// Parse alignments from a delimiter row.
pub fn parseAlignments(allocator: std.mem.Allocator, line: []const u8) ![]Alignment {
    const trimmed = std.mem.trim(u8, line, " \t");
    var aligns: std.ArrayListUnmanaged(Alignment) = .{};
    defer aligns.deinit(allocator);

    var iter = CellIterator.init(trimmed);
    while (iter.next()) |cell| {
        const c = std.mem.trim(u8, cell, " \t");
        const starts_colon = c.len > 0 and c[0] == ':';
        const ends_colon = c.len > 0 and c[c.len - 1] == ':';

        const col_align: Alignment = if (starts_colon and ends_colon)
            .center
        else if (ends_colon)
            .right
        else
            .left;
        try aligns.append(allocator, col_align);
    }

    return try aligns.toOwnedSlice(allocator);
}

/// Parse a row into cells (split on unescaped `|`).
pub fn parseCells(allocator: std.mem.Allocator, line: []const u8) ![][]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    var cells: std.ArrayListUnmanaged([]const u8) = .{};
    defer cells.deinit(allocator);

    var iter = CellIterator.init(trimmed);
    while (iter.next()) |cell| {
        try cells.append(allocator, std.mem.trim(u8, cell, " \t"));
    }

    return try cells.toOwnedSlice(allocator);
}

/// Iterator that splits a row on `|`, handling optional outer pipes and escaped pipes.
const CellIterator = struct {
    text: []const u8,
    pos: usize,
    done: bool,

    fn init(text: []const u8) CellIterator {
        var start: usize = 0;
        // Skip leading pipe
        if (text.len > 0 and text[0] == '|') start = 1;
        return .{ .text = text, .pos = start, .done = false };
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
                self.pos += 2; // skip escaped char
                continue;
            }
            if (self.text[self.pos] == '|') {
                const cell = self.text[start..self.pos];
                self.pos += 1; // skip pipe

                // If this pipe is the trailing one and nothing follows, don't emit empty cell
                if (self.pos >= self.text.len or
                    std.mem.trim(u8, self.text[self.pos..], " \t").len == 0)
                {
                    self.done = true;
                }
                return cell;
            }
            self.pos += 1;
        }

        // Last cell (no trailing pipe)
        self.done = true;
        const cell = self.text[start..self.pos];
        if (std.mem.trim(u8, cell, " \t").len == 0) return null;
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

test "parseAlignments" {
    const allocator = std.testing.allocator;
    const aligns = try parseAlignments(allocator, "| :--- | :---: | ---: |");
    defer allocator.free(aligns);

    try std.testing.expectEqual(@as(usize, 3), aligns.len);
    try std.testing.expectEqual(Alignment.left, aligns[0]);
    try std.testing.expectEqual(Alignment.center, aligns[1]);
    try std.testing.expectEqual(Alignment.right, aligns[2]);
}

test "parseCells handles basic table row" {
    const allocator = std.testing.allocator;
    const cells = try parseCells(allocator, "| foo | bar | baz |");
    defer allocator.free(cells);

    try std.testing.expectEqual(@as(usize, 3), cells.len);
    try std.testing.expectEqualStrings("foo", cells[0]);
    try std.testing.expectEqualStrings("bar", cells[1]);
    try std.testing.expectEqualStrings("baz", cells[2]);
}

test "parseCells handles escaped pipe" {
    const allocator = std.testing.allocator;
    const cells = try parseCells(allocator, "| foo \\| bar | baz |");
    defer allocator.free(cells);

    try std.testing.expectEqual(@as(usize, 2), cells.len);
    try std.testing.expectEqualStrings("foo \\| bar", cells[0]);
    try std.testing.expectEqualStrings("baz", cells[1]);
}

test "parseCells without outer pipes" {
    const allocator = std.testing.allocator;
    const cells = try parseCells(allocator, "foo | bar");
    defer allocator.free(cells);

    try std.testing.expectEqual(@as(usize, 2), cells.len);
    try std.testing.expectEqualStrings("foo", cells[0]);
    try std.testing.expectEqualStrings("bar", cells[1]);
}
