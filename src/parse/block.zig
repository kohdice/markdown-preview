const std = @import("std");

pub const max_block_indent = 3;
const max_heading_level = 6;
const min_fence_len = 3;
const min_thematic_break_markers = 3;
const max_ordered_digits = 9;
const tab_stop_columns = 4;
const checkbox_marker_len = 4;
const checkbox_open_offset = 0;
const checkbox_state_offset = 1;
const checkbox_close_offset = 2;
const checkbox_gap_offset = 3;
const unordered_list_markers = "-*+";
const ordered_list_markers = ".)";
const thematic_break_markers = "-_*";
const fence_chars = "`~";
pub const horizontal_whitespace = " \t";
pub const carriage_return = "\r";
pub fn isHorizontalWhitespace(c: u8) bool {
    return c == ' ' or c == '\t';
}

pub const Heading = struct {
    level: u8,
    content: []const u8,
};

pub const SetextHeadingUnderline = struct {
    level: u8,
};

pub const ListItem = struct {
    indent: usize,
    marker: u8,
    content: []const u8,
    content_col: usize,
    checked: ?bool = null,
};

pub const OrderedListItem = struct {
    indent: usize,
    number: []const u8,
    marker: u8,
    content: []const u8,
    content_col: usize,
    checked: ?bool = null,
};

pub const BlockQuote = struct {
    indent: usize,
    content: []const u8,
};

pub const Fence = struct {
    fence_char: u8,
    fence_len: usize,
    language: []const u8,
};

pub const Indent = struct {
    bytes: usize,
    columns: usize,
};

pub fn heading(line: []const u8) ?Heading {
    var index = indentAtMost(line, max_block_indent) orelse return null;
    if (index >= line.len or line[index] != '#') return null;

    var level: u8 = 0;
    while (index < line.len and line[index] == '#' and level < max_heading_level) : (index += 1) {
        level += 1;
    }

    if (level == 0) return null;
    if (index < line.len and !isHorizontalWhitespace(line[index])) return null;

    while (index < line.len and isHorizontalWhitespace(line[index])) : (index += 1) {}

    return .{
        .level = level,
        .content = trimClosingHashes(line[index..]),
    };
}

fn trimClosingHashes(text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, horizontal_whitespace);
    var end = trimmed.len;

    while (end > 0 and trimmed[end - 1] == '#') : (end -= 1) {}
    if (end == trimmed.len) return trimmed;
    if (end > 0 and isHorizontalWhitespace(trimmed[end - 1])) {
        return std.mem.trimEnd(u8, trimmed[0 .. end - 1], horizontal_whitespace);
    }
    return trimmed;
}

pub fn listItem(line: []const u8) ?ListItem {
    const indent = leadingIndent(line);
    if (indent.columns > max_block_indent) return null;
    if (indent.bytes >= line.len) return null;

    const marker = line[indent.bytes];
    if (std.mem.findScalar(u8, unordered_list_markers, marker) == null) return null;
    if (indent.bytes + 1 >= line.len) return null;
    if (!isHorizontalWhitespace(line[indent.bytes + 1])) return null;

    var content_index = indent.bytes + 1;
    var content_col = indent.columns + 1;
    while (content_index < line.len and isHorizontalWhitespace(line[content_index])) : (content_index += 1) {
        content_col = advanceIndentColumn(content_col, line[content_index]);
    }

    const checked_state = checkbox(line[content_index..]);
    return .{
        .indent = indent.columns,
        .marker = marker,
        .content = checked_state.rest,
        .content_col = content_col,
        .checked = checked_state.checked,
    };
}

fn checkbox(content: []const u8) struct { checked: ?bool, rest: []const u8 } {
    if (content.len >= checkbox_marker_len and
        content[checkbox_open_offset] == '[' and
        content[checkbox_close_offset] == ']' and
        isHorizontalWhitespace(content[checkbox_gap_offset]))
    {
        if (content[checkbox_state_offset] == 'x' or content[checkbox_state_offset] == 'X') {
            return .{ .checked = true, .rest = content[checkbox_marker_len..] };
        } else if (isHorizontalWhitespace(content[checkbox_state_offset])) {
            return .{ .checked = false, .rest = content[checkbox_marker_len..] };
        }
    }
    return .{ .checked = null, .rest = content };
}

pub fn orderedListItem(line: []const u8) ?OrderedListItem {
    const indent = leadingIndent(line);
    if (indent.columns > max_block_indent) return null;
    if (indent.bytes >= line.len) return null;

    const digit_start = indent.bytes;
    var digit_end = digit_start;
    while (digit_end < line.len and line[digit_end] >= '0' and line[digit_end] <= '9') : (digit_end += 1) {}

    const digit_count = digit_end - digit_start;
    if (digit_count == 0 or digit_count > max_ordered_digits) return null;

    if (digit_end >= line.len) return null;
    const marker = line[digit_end];
    if (std.mem.findScalar(u8, ordered_list_markers, marker) == null) return null;

    if (digit_end + 1 < line.len and !isHorizontalWhitespace(line[digit_end + 1])) return null;

    var content_index = digit_end + 1;
    var content_col = indent.columns + digit_count + 1;
    while (content_index < line.len and isHorizontalWhitespace(line[content_index])) : (content_index += 1) {
        content_col = advanceIndentColumn(content_col, line[content_index]);
    }

    const checked_state = checkbox(line[content_index..]);
    return .{
        .indent = indent.columns,
        .number = line[digit_start..digit_end],
        .marker = marker,
        .content = checked_state.rest,
        .content_col = content_col,
        .checked = checked_state.checked,
    };
}

pub fn blockquote(line: []const u8) ?BlockQuote {
    const indent = leadingIndentAtMost(line, max_block_indent) orelse return null;
    if (indent.bytes >= line.len or line[indent.bytes] != '>') return null;

    var content_index = indent.bytes + 1;
    while (content_index < line.len and isHorizontalWhitespace(line[content_index])) : (content_index += 1) {}

    return .{
        .indent = indent.columns,
        .content = line[content_index..],
    };
}

pub fn fence(line: []const u8) ?Fence {
    const index = indentAtMost(line, max_block_indent) orelse return null;
    if (index >= line.len) return null;

    const fence_char = line[index];
    if (std.mem.findScalar(u8, fence_chars, fence_char) == null) return null;

    const fence_len = countRepeatedByte(line[index..], fence_char);
    if (fence_len < min_fence_len) return null;

    const info_start = index + fence_len;
    const info = std.mem.trim(u8, line[info_start..], horizontal_whitespace);
    const lang_end = std.mem.findAny(u8, info, horizontal_whitespace) orelse info.len;

    return .{
        .fence_char = fence_char,
        .fence_len = fence_len,
        .language = info[0..lang_end],
    };
}

pub fn isClosingFence(line: []const u8, fence_info: Fence) bool {
    const index = indentAtMost(line, max_block_indent) orelse return false;
    if (index >= line.len) return false;
    if (line[index] != fence_info.fence_char) return false;

    const fence_len = countRepeatedByte(line[index..], fence_info.fence_char);
    if (fence_len < fence_info.fence_len) return false;

    return std.mem.trim(u8, line[index + fence_len ..], horizontal_whitespace).len == 0;
}

pub fn isThematicBreak(line: []const u8) bool {
    const indent = indentAtMost(line, max_block_indent) orelse return false;
    const trimmed = std.mem.trim(u8, line[indent..], horizontal_whitespace);
    if (trimmed.len < min_thematic_break_markers) return false;

    const marker = trimmed[0];
    if (std.mem.findScalar(u8, thematic_break_markers, marker) == null) return false;

    var marker_count: usize = 0;
    for (trimmed) |char| {
        switch (char) {
            ' ', '\t' => {},
            else => {
                if (char != marker) return false;
                marker_count += 1;
            },
        }
    }

    return marker_count >= min_thematic_break_markers;
}

pub fn setextHeadingUnderline(line: []const u8) ?SetextHeadingUnderline {
    const indent = indentAtMost(line, max_block_indent) orelse return null;
    const trimmed = std.mem.trim(u8, line[indent..], horizontal_whitespace);
    if (trimmed.len == 0) return null;

    const marker = trimmed[0];
    const level: u8 = switch (marker) {
        '=' => 1,
        '-' => 2,
        else => return null,
    };

    for (trimmed) |char| {
        if (char != marker) return null;
    }

    return .{ .level = level };
}

pub fn indentedCodeContent(line: []const u8) ?[]const u8 {
    if (std.mem.trim(u8, line, horizontal_whitespace).len == 0) return null;

    var index: usize = 0;
    var columns: usize = 0;
    while (index < line.len and isHorizontalWhitespace(line[index])) : (index += 1) {
        columns = switch (line[index]) {
            ' ' => columns + 1,
            '\t' => columns + (tab_stop_columns - (columns % tab_stop_columns)),
            else => unreachable,
        };
        if (columns >= tab_stop_columns) return line[index + 1 ..];
    }

    return null;
}

pub fn isBlockLevelStart(line: []const u8) bool {
    if (heading(line) != null) return true;
    if (blockquote(line) != null) return true;
    if (listItem(line) != null) return true;
    if (orderedListItem(line) != null) return true;
    if (fence(line) != null) return true;
    if (isThematicBreak(line)) return true;
    return false;
}

pub fn indentAtMost(line: []const u8, max_columns: usize) ?usize {
    return (leadingIndentAtMost(line, max_columns) orelse return null).bytes;
}

pub fn leadingIndentColumns(line: []const u8) usize {
    return leadingIndent(line).columns;
}

pub fn indentBytesAtLeast(line: []const u8, min_columns: usize) ?usize {
    var index: usize = 0;
    var columns: usize = 0;

    while (index < line.len and isHorizontalWhitespace(line[index])) : (index += 1) {
        columns = advanceIndentColumn(columns, line[index]);
        if (columns >= min_columns) return index + 1;
    }

    return if (columns >= min_columns) index else null;
}

pub fn countRepeatedByte(text: []const u8, byte: u8) usize {
    var count: usize = 0;
    while (count < text.len and text[count] == byte) : (count += 1) {}
    return count;
}

pub fn leadingIndent(line: []const u8) Indent {
    var index: usize = 0;
    var columns: usize = 0;

    while (index < line.len and isHorizontalWhitespace(line[index])) : (index += 1) {
        columns = advanceIndentColumn(columns, line[index]);
    }

    return .{ .bytes = index, .columns = columns };
}

pub fn leadingIndentAtMost(line: []const u8, max_columns: usize) ?Indent {
    var index: usize = 0;
    var columns: usize = 0;

    while (index < line.len and isHorizontalWhitespace(line[index])) : (index += 1) {
        const next_columns = advanceIndentColumn(columns, line[index]);
        if (next_columns > max_columns) return null;
        columns = next_columns;
    }

    return .{ .bytes = index, .columns = columns };
}

fn advanceIndentColumn(columns: usize, byte: u8) usize {
    return switch (byte) {
        ' ' => columns + 1,
        '\t' => columns + (tab_stop_columns - (columns % tab_stop_columns)),
        else => unreachable,
    };
}
