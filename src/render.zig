const std = @import("std");
const ansi = @import("ansi.zig");
const document = @import("document.zig");
const theme = @import("theme.zig");

pub const RenderOptions = struct {
    enable_ansi: bool = false,
    theme: theme.Theme = .solarized_dark,
};

const Fence = struct {
    fence_char: u8,
    fence_len: usize,
    language: []const u8,
};

const Heading = struct {
    level: u8,
    content: []const u8,
};

const ListItem = struct {
    indent: usize,
    marker: u8,
    content: []const u8,
    checked: ?bool = null,
};

const OrderedListItem = struct {
    indent: usize,
    number: []const u8,
    marker: u8,
    content: []const u8,
    checked: ?bool = null,
};

const BlockQuote = struct {
    indent: usize,
    content: []const u8,
};

pub fn renderMarkdown(allocator: std.mem.Allocator, writer: *std.io.Writer, input: []const u8, opts: RenderOptions) !void {
    if (input.len == 0) return;

    const palette = theme.palette(opts.theme);
    var active_fence: ?Fence = null;
    var line_start: usize = 0;

    while (line_start < input.len) {
        const line_end = std.mem.indexOfScalarPos(u8, input, line_start, '\n') orelse input.len;
        const has_newline = line_end < input.len;
        const line = document.trimCarriageReturn(input[line_start..line_end]);

        if (active_fence) |fence| {
            if (isClosingFence(line, fence)) {
                try writeStyledLine(writer, line, opts.enable_ansi, .{
                    .fg = palette.code_fence,
                    .dim = true,
                });
                active_fence = null;
            } else {
                try writeStyledLine(writer, line, opts.enable_ansi, .{
                    .fg = palette.inline_code,
                });
            }
        } else if (parseFence(line)) |fence| {
            active_fence = fence;
            try writeStyledLine(writer, line, opts.enable_ansi, .{
                .fg = palette.code_fence,
                .dim = true,
            });
        } else if (isBlankLine(line)) {} else if (isThematicBreak(line)) {
            try writeStyledLine(writer, "--------------------------------", opts.enable_ansi, .{
                .fg = palette.subtle,
                .dim = true,
            });
        } else if (parseHeading(line)) |heading| {
            try renderInline(allocator, writer, heading.content, opts.enable_ansi, headingStyle(heading.level), palette);
        } else if (parseBlockQuote(line)) |quote| {
            try writeIndent(writer, quote.indent);
            try renderBlockQuoteContent(allocator, writer, quote.content, opts.enable_ansi, palette);
        } else if (parseOrderedListItem(line)) |ordered| {
            try writeIndent(writer, ordered.indent);
            try ansi.writeStyled(writer, opts.enable_ansi, .{
                .fg = palette.list_marker,
                .bold = true,
            }, ordered.number);
            const marker_buf: [2]u8 = .{ ordered.marker, ' ' };
            try ansi.writeStyled(writer, opts.enable_ansi, .{
                .fg = palette.list_marker,
                .bold = true,
            }, &marker_buf);
            try renderCheckbox(writer, ordered.checked, opts.enable_ansi, palette);
            try renderInline(allocator, writer, ordered.content, opts.enable_ansi, .{
                .fg = palette.body,
            }, palette);
        } else if (parseListItem(line)) |item| {
            try writeIndent(writer, item.indent);
            var marker: [2]u8 = .{ item.marker, ' ' };
            try ansi.writeStyled(writer, opts.enable_ansi, .{
                .fg = palette.list_marker,
                .bold = true,
            }, &marker);
            try renderCheckbox(writer, item.checked, opts.enable_ansi, palette);
            try renderInline(allocator, writer, item.content, opts.enable_ansi, .{
                .fg = palette.body,
            }, palette);
        } else {
            try renderInline(allocator, writer, line, opts.enable_ansi, .{
                .fg = palette.body,
            }, palette);
        }

        if (has_newline) try writer.writeByte('\n');
        line_start = line_end + @intFromBool(has_newline);
    }
}

fn isBlankLine(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn parseHeading(line: []const u8) ?Heading {
    var index = countIndentUpTo(line, 3);
    if (index >= line.len or line[index] != '#') return null;

    var level: u8 = 0;
    while (index < line.len and line[index] == '#' and level < 6) : (index += 1) {
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

fn trimClosingHashes(text: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, text, " \t");
    var end = trimmed.len;

    while (end > 0 and trimmed[end - 1] == '#') : (end -= 1) {}
    if (end == trimmed.len) return trimmed;
    if (end > 0 and (trimmed[end - 1] == ' ' or trimmed[end - 1] == '\t')) {
        return std.mem.trimRight(u8, trimmed[0 .. end - 1], " \t");
    }
    return trimmed;
}

fn parseListItem(line: []const u8) ?ListItem {
    const indent = countLeadingWhitespace(line);
    if (indent >= line.len) return null;

    const marker = line[indent];
    if (marker != '-' and marker != '*' and marker != '+') return null;
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

fn parseCheckbox(content: []const u8) struct { checked: ?bool, rest: []const u8 } {
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

fn parseOrderedListItem(line: []const u8) ?OrderedListItem {
    const indent = countLeadingWhitespace(line);
    if (indent >= line.len) return null;

    const digit_start = indent;
    var digit_end = digit_start;
    while (digit_end < line.len and line[digit_end] >= '0' and line[digit_end] <= '9') : (digit_end += 1) {}

    const digit_count = digit_end - digit_start;
    if (digit_count == 0 or digit_count > 9) return null;

    if (digit_end >= line.len) return null;
    const marker = line[digit_end];
    if (marker != '.' and marker != ')') return null;

    // Allow empty ordered items (e.g., "2." at end of line)
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

fn renderCheckbox(
    writer: *std.io.Writer,
    checked: ?bool,
    enable_ansi: bool,
    palette: theme.Palette,
) !void {
    if (checked) |is_checked| {
        if (is_checked) {
            try ansi.writeStyled(writer, enable_ansi, .{
                .fg = palette.list_marker,
            }, "[x] ");
        } else {
            try ansi.writeStyled(writer, enable_ansi, .{
                .fg = palette.muted,
                .dim = true,
            }, "[ ] ");
        }
    }
}

fn renderBlockQuoteContent(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    content: []const u8,
    enable_ansi: bool,
    palette: theme.Palette,
) !void {
    try ansi.writeStyled(writer, enable_ansi, .{
        .fg = palette.muted,
        .dim = true,
    }, "| ");

    if (parseBlockQuote(content)) |nested| {
        try writeIndent(writer, nested.indent);
        try renderBlockQuoteContent(allocator, writer, nested.content, enable_ansi, palette);
    } else {
        try renderInline(allocator, writer, content, enable_ansi, .{
            .fg = palette.muted,
        }, palette);
    }
}

fn parseBlockQuote(line: []const u8) ?BlockQuote {
    const indent = countIndentUpTo(line, 3);
    if (indent >= line.len or line[indent] != '>') return null;

    var content_index = indent + 1;
    while (content_index < line.len and (line[content_index] == ' ' or line[content_index] == '\t')) : (content_index += 1) {}

    return .{
        .indent = indent,
        .content = line[content_index..],
    };
}

fn parseFence(line: []const u8) ?Fence {
    const index = countIndentUpTo(line, 3);
    if (index >= line.len) return null;

    const fence_char = line[index];
    if (fence_char != '`' and fence_char != '~') return null;

    const fence_len = countRepeatedByte(line[index..], fence_char);
    if (fence_len < 3) return null;

    // Extract language info string: first token after fence chars, trimmed
    const info_start = index + fence_len;
    const info = std.mem.trim(u8, line[info_start..], " \t");
    // Language is the first word (up to first space)
    const lang_end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;

    return .{
        .fence_char = fence_char,
        .fence_len = fence_len,
        .language = info[0..lang_end],
    };
}

fn isClosingFence(line: []const u8, fence: Fence) bool {
    const index = countIndentUpTo(line, 3);
    if (index >= line.len) return false;
    if (line[index] != fence.fence_char) return false;

    const fence_len = countRepeatedByte(line[index..], fence.fence_char);
    if (fence_len < fence.fence_len) return false;

    return std.mem.trim(u8, line[index + fence_len ..], " \t").len == 0;
}

fn isThematicBreak(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;

    const marker = trimmed[0];
    if (marker != '-' and marker != '_' and marker != '*') return false;

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

    return marker_count >= 3;
}

const InlineKind = enum { text, code_span, link_text, link_url, emphasis, strong, bold_italic, strikethrough };

const InlineSegment = struct {
    kind: InlineKind,
    content: []const u8,
};

fn renderInline(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    text: []const u8,
    enable_ansi: bool,
    base_style: ansi.TextStyle,
    palette: theme.Palette,
) !void {
    var segments: std.ArrayListUnmanaged(InlineSegment) = .{};
    defer segments.deinit(allocator);

    try parseInlineSegments(allocator, text, &segments);

    for (segments.items) |seg| {
        switch (seg.kind) {
            .text => try ansi.writeStyled(writer, enable_ansi, base_style, seg.content),
            .code_span => try ansi.writeStyled(writer, enable_ansi, .{ .fg = palette.inline_code }, seg.content),
            .link_text => try renderInline(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .fg = palette.link, .underline = true }), palette),
            .link_url => try ansi.writeStyled(writer, enable_ansi, .{ .fg = palette.muted, .dim = true }, seg.content),
            .emphasis => try renderInline(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .italic = true }), palette),
            .strong => try renderInline(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .bold = true }), palette),
            .bold_italic => try renderInline(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .bold = true, .italic = true }), palette),
            .strikethrough => try renderInline(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .strikethrough = true }), palette),
        }
    }
}

fn parseInlineSegments(allocator: std.mem.Allocator, text: []const u8, segments: *std.ArrayListUnmanaged(InlineSegment)) !void {
    var index: usize = 0;
    var plain_start: usize = 0;

    while (index < text.len) {
        switch (text[index]) {
            '\\' => {
                // Backslash escape: consume the backslash, keep the next char as literal
                if (index + 1 < text.len and isEscapable(text[index + 1])) {
                    // Flush text before the backslash
                    if (plain_start < index)
                        try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..index] });
                    // Emit the escaped character as plain text (skip the backslash)
                    try segments.append(allocator, .{ .kind = .text, .content = text[index + 1 .. index + 2] });
                    index += 2;
                    plain_start = index;
                    continue;
                }
                index += 1;
            },
            '`' => {
                if (findCodeSpanEnd(text, index)) |end| {
                    if (plain_start < index)
                        try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..index] });
                    try segments.append(allocator, .{ .kind = .code_span, .content = text[index .. end + 1] });
                    index = end + 1;
                    plain_start = index;
                    continue;
                }
                index += 1;
            },
            '[' => {
                if (findLinkParts(text, index)) |link| {
                    if (plain_start < index)
                        try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..index] });
                    try segments.append(allocator, .{ .kind = .link_text, .content = text[link.text_start..link.text_end] });
                    try segments.append(allocator, .{ .kind = .link_url, .content = text[link.url_start..link.url_end] });
                    index = link.full_end;
                    plain_start = index;
                    continue;
                }
                index += 1;
            },
            '*', '_' => {
                if (tryParseEmphasis(text, index)) |em| {
                    if (plain_start < index)
                        try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..index] });
                    try segments.append(allocator, .{ .kind = em.kind, .content = em.content });
                    index = em.end;
                    plain_start = index;
                    continue;
                }
                index += 1;
            },
            '~' => {
                if (tryParseStrikethrough(text, index)) |st| {
                    if (plain_start < index)
                        try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..index] });
                    try segments.append(allocator, .{ .kind = .strikethrough, .content = st.content });
                    index = st.end;
                    plain_start = index;
                    continue;
                }
                index += 1;
            },
            else => {
                index += 1;
            },
        }
    }

    if (plain_start < text.len)
        try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..] });
}

/// Find end of a code span. Matches opening backtick run length per CommonMark.
/// Returns the index of the last backtick in the closing run.
fn findCodeSpanEnd(text: []const u8, start: usize) ?usize {
    // Count opening backtick run
    var open_len: usize = 0;
    while (start + open_len < text.len and text[start + open_len] == '`') : (open_len += 1) {}
    if (open_len == 0) return null;

    // Find matching closing run of same length
    var pos = start + open_len;
    while (pos < text.len) {
        if (text[pos] == '`') {
            var close_len: usize = 0;
            while (pos + close_len < text.len and text[pos + close_len] == '`') : (close_len += 1) {}
            if (close_len == open_len) {
                return pos + close_len - 1;
            }
            pos += close_len;
        } else {
            pos += 1;
        }
    }
    return null;
}

const LinkParts = struct {
    text_start: usize,
    text_end: usize,
    url_start: usize,
    url_end: usize,
    full_end: usize,
};

fn findLinkParts(text: []const u8, start: usize) ?LinkParts {
    const close_bracket = std.mem.indexOfScalarPos(u8, text, start + 1, ']') orelse return null;
    if (close_bracket + 1 >= text.len or text[close_bracket + 1] != '(') return null;

    var depth: usize = 1;
    var pos = close_bracket + 2;
    while (pos < text.len) : (pos += 1) {
        switch (text[pos]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    return .{
                        .text_start = start + 1,
                        .text_end = close_bracket,
                        .url_start = close_bracket + 1,
                        .url_end = pos + 1,
                        .full_end = pos + 1,
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

const EmphasisResult = struct {
    kind: InlineKind,
    content: []const u8,
    end: usize,
};

fn tryParseEmphasis(text: []const u8, start: usize) ?EmphasisResult {
    const delim_char = text[start];
    var delim_len: usize = 0;
    while (start + delim_len < text.len and text[start + delim_len] == delim_char) : (delim_len += 1) {}

    if (delim_len == 0 or delim_len > 3) return null;

    // Check left-flanking: must be followed by non-whitespace
    const after_delim = start + delim_len;
    if (after_delim >= text.len) return null;
    if (text[after_delim] == ' ' or text[after_delim] == '\t' or text[after_delim] == '\n') return null;

    // For underscore: must not be preceded by alphanumeric AND followed by alphanumeric
    // (prevents foo_bar_baz from being parsed as emphasis)
    if (delim_char == '_' and start > 0 and std.ascii.isAlphanumeric(text[start - 1])) return null;

    // Find matching closing delimiter
    var pos = after_delim;
    while (pos < text.len) {
        // Skip backslash-escaped characters
        if (text[pos] == '\\' and pos + 1 < text.len and isEscapable(text[pos + 1])) {
            pos += 2;
            continue;
        }
        // Skip code spans inside emphasis
        if (text[pos] == '`') {
            if (findCodeSpanEnd(text, pos)) |code_end| {
                pos = code_end + 1;
                continue;
            }
        }
        if (text[pos] == delim_char) {
            var close_len: usize = 0;
            while (pos + close_len < text.len and text[pos + close_len] == delim_char) : (close_len += 1) {}

            if (close_len >= delim_len) {
                // Check right-flanking: must be preceded by non-whitespace
                if (pos > 0 and text[pos - 1] != ' ' and text[pos - 1] != '\t' and text[pos - 1] != '\n') {
                    // For underscore: must not be followed by alphanumeric
                    if (delim_char == '_' and pos + close_len < text.len and std.ascii.isAlphanumeric(text[pos + close_len])) {
                        pos += close_len;
                        continue;
                    }

                    const content = text[after_delim..pos];
                    if (content.len == 0) {
                        pos += close_len;
                        continue;
                    }

                    const kind: InlineKind = if (delim_len >= 3)
                        .bold_italic
                    else if (delim_len == 2)
                        .strong
                    else
                        .emphasis;

                    return .{
                        .kind = kind,
                        .content = content,
                        .end = pos + delim_len,
                    };
                }
            }
            pos += close_len;
        } else {
            pos += 1;
        }
    }
    return null;
}

const StrikethroughResult = struct {
    content: []const u8,
    end: usize,
};

fn tryParseStrikethrough(text: []const u8, start: usize) ?StrikethroughResult {
    var delim_len: usize = 0;
    while (start + delim_len < text.len and text[start + delim_len] == '~') : (delim_len += 1) {}

    if (delim_len < 1 or delim_len > 2) return null;

    const after_delim = start + delim_len;
    if (after_delim >= text.len) return null;
    if (text[after_delim] == ' ' or text[after_delim] == '\t') return null;

    // Find matching closing tildes
    var pos = after_delim;
    while (pos < text.len) {
        // Skip backslash-escaped characters
        if (text[pos] == '\\' and pos + 1 < text.len and isEscapable(text[pos + 1])) {
            pos += 2;
            continue;
        }
        if (text[pos] == '~') {
            var close_len: usize = 0;
            while (pos + close_len < text.len and text[pos + close_len] == '~') : (close_len += 1) {}

            if (close_len >= delim_len and pos > after_delim) {
                if (text[pos - 1] != ' ' and text[pos - 1] != '\t') {
                    return .{
                        .content = text[after_delim..pos],
                        .end = pos + delim_len,
                    };
                }
            }
            pos += close_len;
        } else {
            pos += 1;
        }
    }
    return null;
}

/// CommonMark 2.4: ASCII punctuation characters can be backslash-escaped.
fn isEscapable(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/' => true,
        ':', ';', '<', '=', '>', '?', '@' => true,
        '[', '\\', ']', '^', '_', '`' => true,
        '{', '|', '}', '~' => true,
        else => false,
    };
}

fn writeStyledLine(
    writer: *std.io.Writer,
    text: []const u8,
    enable_ansi: bool,
    style: ansi.TextStyle,
) !void {
    try ansi.writeStyled(writer, enable_ansi, style, text);
}

fn writeIndent(writer: *std.io.Writer, count: usize) !void {
    for (0..count) |_| {
        try writer.writeByte(' ');
    }
}

fn countIndentUpTo(line: []const u8, max_spaces: usize) usize {
    var count: usize = 0;
    while (count < line.len and count < max_spaces and (line[count] == ' ' or line[count] == '\t')) : (count += 1) {}
    return count;
}

fn countLeadingWhitespace(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and (line[count] == ' ' or line[count] == '\t')) : (count += 1) {}
    return count;
}

fn countRepeatedByte(text: []const u8, byte: u8) usize {
    var count: usize = 0;
    while (count < text.len and text[count] == byte) : (count += 1) {}
    return count;
}

fn headingStyle(level: u8) ansi.TextStyle {
    return switch (level) {
        1 => .{ .fg = .{ .r = 0xb5, .g = 0x89, .b = 0x00 }, .bold = true, .underline = true },
        2 => .{ .fg = .{ .r = 0xcb, .g = 0x4b, .b = 0x16 }, .bold = true, .underline = true },
        3 => .{ .fg = .{ .r = 0x26, .g = 0x8b, .b = 0xd2 }, .bold = true },
        4 => .{ .fg = .{ .r = 0x2a, .g = 0xa1, .b = 0x98 }, .bold = true },
        5 => .{ .fg = .{ .r = 0x6c, .g = 0x71, .b = 0xc4 } },
        6 => .{ .fg = .{ .r = 0x6c, .g = 0x71, .b = 0xc4 }, .dim = true },
        else => .{ .fg = .{ .r = 0x6c, .g = 0x71, .b = 0xc4 }, .dim = true },
    };
}

fn renderToOwnedSlice(
    allocator: std.mem.Allocator,
    input: []const u8,
    opts: RenderOptions,
) ![]u8 {
    var output: std.io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try renderMarkdown(allocator, &output.writer, input, opts);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

test "renderMarkdown strips heading markers and preserves structure" {
    const allocator = std.testing.allocator;
    const source =
        \\# Title
        \\
        \\- item
        \\> quoted
        \\[link](https://example.com)
        \\```zig
        \\const value = 1;
        \\```
        \\
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\Title
        \\
        \\- item
        \\| quoted
        \\link(https://example.com)
        \\```zig
        \\const value = 1;
        \\```
        \\
    ,
        rendered,
    );
}

test "renderMarkdown emits Solarized Dark ANSI styling for headings and links" {
    const allocator = std.testing.allocator;
    const source =
        \\# Title
        \\[link](https://example.com)
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // link text: underline + link color; URL: dim + muted color
    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[4m\x1b[38;2;181;137;0mTitle\x1b[0m\n" ++
            "\x1b[4m\x1b[38;2;108;113;196mlink\x1b[0m" ++
            "\x1b[2m\x1b[38;2;88;110;117m(https://example.com)\x1b[0m",
        rendered,
    );
}

test "link with parentheses inside URL renders semantically" {
    const allocator = std.testing.allocator;
    const source = "[wiki](https://en.wikipedia.org/wiki/Foo_(bar))";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("wiki(https://en.wikipedia.org/wiki/Foo_(bar))", rendered);
}

test "nested blockquotes render with multiple pipe markers" {
    const allocator = std.testing.allocator;
    const source = "> > nested\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("| | nested\n", rendered);
}

test "heading levels produce different ANSI styles" {
    const allocator = std.testing.allocator;
    const source = "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // h1: bold + underline + yellow
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[4m\x1b[38;2;181;137;0m"));
    // h2: bold + underline + orange
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[4m\x1b[38;2;203;75;22m"));
    // h3: bold + blue (no underline)
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[38;2;38;139;210m"));
    // h4: bold + cyan
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[38;2;42;161;152m"));
    // h5: violet (no bold, no dim)
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;108;113;196mH5\x1b[0m"));
    // h6: dim + violet
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[2m\x1b[38;2;108;113;196mH6\x1b[0m"));
}

test "ordered list items are rendered with number markers" {
    const allocator = std.testing.allocator;
    const source =
        \\1. First item
        \\2. Second item
        \\3. Third item
        \\
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\1. First item
        \\2. Second item
        \\3. Third item
        \\
    ,
        rendered,
    );
}

test "ordered list with closing paren marker" {
    const allocator = std.testing.allocator;
    const source = "1) Item one\n2) Item two\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1) Item one\n2) Item two\n", rendered);
}

test "ordered list with indentation" {
    const allocator = std.testing.allocator;
    const source = "  1. Indented ordered item\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("  1. Indented ordered item\n", rendered);
}

test "ordered list with multi-digit numbers" {
    const allocator = std.testing.allocator;
    const source = "10. Tenth item\n999999999. Max digits\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("10. Tenth item\n999999999. Max digits\n", rendered);
}

test "ordered list rejects more than 9 digits" {
    const allocator = std.testing.allocator;
    const source = "1234567890. Too many digits\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    // Should be rendered as plain text, not as an ordered list
    try std.testing.expectEqualStrings("1234567890. Too many digits\n", rendered);
}

test "ordered list items get ANSI styling" {
    const allocator = std.testing.allocator;
    const source = "1. Styled item\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // Number marker should have list_marker color (teal: 42, 161, 152) + bold
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[38;2;42;161;152m1"));
    // Content should have body color
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Styled item"));
}

test "task list items render checkbox indicators" {
    const allocator = std.testing.allocator;
    const source =
        \\- [x] Completed task
        \\- [ ] Incomplete task
        \\- Regular item
        \\
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\- [x] Completed task
        \\- [ ] Incomplete task
        \\- Regular item
        \\
    ,
        rendered,
    );
}

test "task list with uppercase X" {
    const allocator = std.testing.allocator;
    const source = "- [X] Done\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- [x] Done\n", rendered);
}

test "ordered task list items" {
    const allocator = std.testing.allocator;
    const source = "1. [x] First done\n2. [ ] Second pending\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1. [x] First done\n2. [ ] Second pending\n", rendered);
}

test "task list items get ANSI styling" {
    const allocator = std.testing.allocator;
    const source = "- [x] Done\n- [ ] Todo\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // Checked: [x] should have list_marker color (teal: 42, 161, 152)
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;42;161;152m[x] "));
    // Unchecked: [ ] should have muted + dim
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[2m\x1b[38;2;88;110;117m[ ] "));
}

test "task list with tab separator" {
    const allocator = std.testing.allocator;
    const source = "- [x]\tTab-separated task\n- [\t] Tab in checkbox\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "[x] "));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "[ ] "));
}

test "empty ordered list item" {
    const allocator = std.testing.allocator;
    const source = "1. First\n2.\n3. Third\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    // "2." renders as "2. " because the marker includes trailing space
    try std.testing.expectEqualStrings("1. First\n2. \n3. Third\n", rendered);
}

test "nested task list items" {
    const allocator = std.testing.allocator;
    const source = "- [x] Parent\n  - [ ] Child\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- [x] Parent\n  - [ ] Child\n", rendered);
}

test "tab-indented headings and blockquotes are recognized" {
    const allocator = std.testing.allocator;
    const source = "\t# Tab Heading\n\t> Tab Quote\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Tab Heading"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Tab Quote"));
}

test "bold text renders without delimiters" {
    const allocator = std.testing.allocator;
    const source = "This is **bold** text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is bold text", rendered);
}

test "italic text renders without delimiters" {
    const allocator = std.testing.allocator;
    const source = "This is *italic* text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is italic text", rendered);
}

test "underscore italic renders without delimiters" {
    const allocator = std.testing.allocator;
    const source = "This is _italic_ text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is italic text", rendered);
}

test "strikethrough renders without delimiters" {
    const allocator = std.testing.allocator;
    const source = "This is ~~deleted~~ text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is deleted text", rendered);
}

test "single tilde strikethrough" {
    const allocator = std.testing.allocator;
    const source = "This is ~deleted~ text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is deleted text", rendered);
}

test "foo_bar_baz is not emphasis" {
    const allocator = std.testing.allocator;
    const source = "foo_bar_baz";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("foo_bar_baz", rendered);
}

test "unmatched delimiters render as literal text" {
    const allocator = std.testing.allocator;
    const source = "This has *unmatched delimiter";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This has *unmatched delimiter", rendered);
}

test "bold ANSI styling applies bold attribute" {
    const allocator = std.testing.allocator;
    const source = "**bold**";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // bold text should have bold + body color
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "bold"));
    // delimiters should not appear
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "**"));
}

test "italic ANSI styling applies italic attribute" {
    const allocator = std.testing.allocator;
    const source = "*italic*";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // italic text should have italic escape code
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[3m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "italic"));
}

test "strikethrough ANSI styling applies strikethrough attribute" {
    const allocator = std.testing.allocator;
    const source = "~~struck~~";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // strikethrough should have strikethrough escape code
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[9m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "struck"));
}

test "code span takes precedence over emphasis" {
    const allocator = std.testing.allocator;
    const source = "*italic with `code` inside*";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    // The code span should prevent emphasis from matching across it
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "`code`"));
}

test "triple asterisk renders as bold italic" {
    const allocator = std.testing.allocator;
    const source = "***bold italic***";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // Should have both bold and italic
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[3m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "bold italic"));
}

test "nested bold with inner italic" {
    const allocator = std.testing.allocator;
    const source = "**bold _and italic_**";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    // Delimiters should be removed, content preserved
    try std.testing.expectEqualStrings("bold and italic", rendered);
}

test "link text with emphasis renders recursively" {
    const allocator = std.testing.allocator;
    const source = "[**bold link**](https://example.com)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    // Link text should have emphasis delimiters removed
    try std.testing.expectEqualStrings("bold link(https://example.com)", rendered);
}

test "link text with emphasis gets ANSI styling" {
    const allocator = std.testing.allocator;
    const source = "[**bold**](url)";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // bold should appear (bold from emphasis + underline from link)
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "bold"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "**"));
}

test "double backtick code span" {
    const allocator = std.testing.allocator;
    const source = "``code with ` backtick``";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("``code with ` backtick``", rendered);
}

test "backslash escaped asterisk is not emphasis" {
    const allocator = std.testing.allocator;
    const source = "\\*not emphasis\\*";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("*not emphasis*", rendered);
}

test "code fence with language preserves original format" {
    const allocator = std.testing.allocator;
    const source = "```python\nprint('hello')\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```python\nprint('hello')\n```\n", rendered);
}

test "code fence without language preserves format" {
    const allocator = std.testing.allocator;
    const source = "```\nplain code\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```\nplain code\n```\n", rendered);
}

test "code fence language is captured in Fence struct" {
    const allocator = std.testing.allocator;
    const source = "```javascript mocha\nconsole.log();\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    // Fence line preserved as-is; language extraction is internal (for future syntax highlighting)
    try std.testing.expectEqualStrings("```javascript mocha\nconsole.log();\n```\n", rendered);
}

test "backslash escaped underscore is literal" {
    const allocator = std.testing.allocator;
    const source = "\\_literal\\_";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("_literal_", rendered);
}
