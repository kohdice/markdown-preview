const std = @import("std");

pub const max_block_indent = 3;
pub const max_heading_level = 6;
pub const min_fence_len = 3;
pub const min_thematic_break_markers = 3;
pub const max_ordered_digits = 9;
/// CommonMark §6.7: a hard line break is signaled by a backslash or by
/// at least two trailing spaces at the end of a line.
pub const min_hard_break_spaces = 2;
/// One marker character (`-`, `*`, `+`, `.`, or `)`) plus the mandatory
/// trailing space.
pub const marker_suffix_width: usize = 2;

/// CommonMark §5.2: unordered list bullet markers.
pub const unordered_list_markers = "-*+";
/// CommonMark §5.2: ordered list number-delimiter characters.
pub const ordered_list_markers = ".)";
/// CommonMark §4.1: thematic break markers.
pub const thematic_break_markers = "-_*";
/// CommonMark §4.5: fenced code block delimiter characters.
pub const fence_chars = "`~";

pub const Heading = struct {
    level: u8,
    content: []const u8,
};

pub const ListItem = struct {
    indent: usize,
    marker: u8,
    content: []const u8,
    checked: ?bool = null,
};

pub const OrderedListItem = struct {
    indent: usize,
    number: []const u8,
    marker: u8,
    content: []const u8,
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

pub fn parseHeading(line: []const u8) ?Heading {
    var index = countIndentUpTo(line, max_block_indent);
    if (index >= line.len or line[index] != '#') return null;

    var level: u8 = 0;
    while (index < line.len and line[index] == '#' and level < max_heading_level) : (index += 1) {
        level += 1;
    }

    if (level == 0) return null;
    if (index < line.len and line[index] != ' ' and line[index] != '\t') return null;

    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}

    return .{
        .level = level,
        .content = trimClosingHashes(line[index..]),
    };
}

pub fn trimClosingHashes(text: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, " \t");
    var end = trimmed.len;

    while (end > 0 and trimmed[end - 1] == '#') : (end -= 1) {}
    if (end == trimmed.len) return trimmed;
    if (end > 0 and (trimmed[end - 1] == ' ' or trimmed[end - 1] == '\t')) {
        return std.mem.trimEnd(u8, trimmed[0 .. end - 1], " \t");
    }
    return trimmed;
}

pub fn parseListItem(line: []const u8) ?ListItem {
    const indent = countLeadingWhitespace(line);
    if (indent >= line.len) return null;

    const marker = line[indent];
    if (std.mem.indexOfScalar(u8, unordered_list_markers, marker) == null) return null;
    if (indent + 1 >= line.len) return null;
    if (line[indent + 1] != ' ' and line[indent + 1] != '\t') return null;

    var content_index = indent + 1;
    while (content_index < line.len and (line[content_index] == ' ' or line[content_index] == '\t')) : (content_index += 1) {}

    const checkbox = parseCheckbox(line[content_index..]);
    return .{
        .indent = indent,
        .marker = marker,
        .content = checkbox.rest,
        .checked = checkbox.checked,
    };
}

pub fn parseCheckbox(content: []const u8) struct { checked: ?bool, rest: []const u8 } {
    if (content.len >= 4 and content[0] == '[' and content[2] == ']' and
        (content[3] == ' ' or content[3] == '\t'))
    {
        if (content[1] == 'x' or content[1] == 'X') {
            return .{ .checked = true, .rest = content[4..] };
        } else if (content[1] == ' ' or content[1] == '\t') {
            return .{ .checked = false, .rest = content[4..] };
        }
    }
    return .{ .checked = null, .rest = content };
}

pub fn parseOrderedListItem(line: []const u8) ?OrderedListItem {
    const indent = countLeadingWhitespace(line);
    if (indent >= line.len) return null;

    const digit_start = indent;
    var digit_end = digit_start;
    while (digit_end < line.len and line[digit_end] >= '0' and line[digit_end] <= '9') : (digit_end += 1) {}

    const digit_count = digit_end - digit_start;
    if (digit_count == 0 or digit_count > max_ordered_digits) return null;

    if (digit_end >= line.len) return null;
    const marker = line[digit_end];
    if (std.mem.indexOfScalar(u8, ordered_list_markers, marker) == null) return null;

    if (digit_end + 1 < line.len and line[digit_end + 1] != ' ' and line[digit_end + 1] != '\t') return null;

    var content_index = digit_end + 1;
    while (content_index < line.len and (line[content_index] == ' ' or line[content_index] == '\t')) : (content_index += 1) {}

    const checkbox = parseCheckbox(line[content_index..]);
    return .{
        .indent = indent,
        .number = line[digit_start..digit_end],
        .marker = marker,
        .content = checkbox.rest,
        .checked = checkbox.checked,
    };
}

pub fn isListContinuation(line: []const u8, content_col: usize) bool {
    if (std.mem.trim(u8, line, " \t").len == 0) return false;
    const indent = countLeadingWhitespace(line);
    if (indent < content_col) return false;
    if (parseListItem(line) != null) return false;
    if (parseOrderedListItem(line) != null) return false;
    if (parseHeading(line) != null) return false;
    if (parseBlockQuote(line) != null) return false;
    if (parseFence(line) != null) return false;
    if (isThematicBreak(line)) return false;
    return true;
}

pub fn parseBlockQuote(line: []const u8) ?BlockQuote {
    const indent = countIndentUpTo(line, max_block_indent);
    if (indent >= line.len or line[indent] != '>') return null;

    var content_index = indent + 1;
    while (content_index < line.len and (line[content_index] == ' ' or line[content_index] == '\t')) : (content_index += 1) {}

    return .{
        .indent = indent,
        .content = line[content_index..],
    };
}

pub fn parseFence(line: []const u8) ?Fence {
    const index = countIndentUpTo(line, max_block_indent);
    if (index >= line.len) return null;

    const fence_char = line[index];
    if (std.mem.indexOfScalar(u8, fence_chars, fence_char) == null) return null;

    const fence_len = countRepeatedByte(line[index..], fence_char);
    if (fence_len < min_fence_len) return null;

    const info_start = index + fence_len;
    const info = std.mem.trim(u8, line[info_start..], " \t");
    const lang_end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;

    return .{
        .fence_char = fence_char,
        .fence_len = fence_len,
        .language = info[0..lang_end],
    };
}

pub fn isClosingFence(line: []const u8, fence: Fence) bool {
    const index = countIndentUpTo(line, max_block_indent);
    if (index >= line.len) return false;
    if (line[index] != fence.fence_char) return false;

    const fence_len = countRepeatedByte(line[index..], fence.fence_char);
    if (fence_len < fence.fence_len) return false;

    return std.mem.trim(u8, line[index + fence_len ..], " \t").len == 0;
}

pub fn isThematicBreak(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < min_thematic_break_markers) return false;

    const marker = trimmed[0];
    if (std.mem.indexOfScalar(u8, thematic_break_markers, marker) == null) return false;

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

pub fn isBlockLevelStart(line: []const u8) bool {
    if (parseHeading(line) != null) return true;
    if (parseBlockQuote(line) != null) return true;
    if (parseListItem(line) != null) return true;
    if (parseOrderedListItem(line) != null) return true;
    if (parseFence(line) != null) return true;
    if (isThematicBreak(line)) return true;
    return false;
}

pub fn stripHardBreak(line: []const u8) []const u8 {
    if (line.len == 0) return line;

    if (line[line.len - 1] == '\\') {
        return line[0 .. line.len - 1];
    }

    var end = line.len;
    while (end > 0 and line[end - 1] == ' ') : (end -= 1) {}
    if (line.len - end >= min_hard_break_spaces) {
        return line[0..end];
    }
    return line;
}

pub fn countIndentUpTo(line: []const u8, max_spaces: usize) usize {
    var count: usize = 0;
    while (count < line.len and count < max_spaces and (line[count] == ' ' or line[count] == '\t')) : (count += 1) {}
    return count;
}

pub fn countLeadingWhitespace(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and (line[count] == ' ' or line[count] == '\t')) : (count += 1) {}
    return count;
}

pub fn countRepeatedByte(text: []const u8, byte: u8) usize {
    var count: usize = 0;
    while (count < text.len and text[count] == byte) : (count += 1) {}
    return count;
}
