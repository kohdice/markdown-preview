const std = @import("std");
const text_util = @import("../text.zig");
const parse_block = @import("block.zig");
const unicode_case_fold = @import("unicode_case_fold_data.zig");

pub const Definition = struct {
    label: []const u8,
    url: []const u8,
    title: ?[]const u8,
};

pub const LinkDestination = struct {
    url: []const u8,
    end: usize,
};

pub const LinkTitle = struct {
    title: []const u8,
    end: usize,
};

pub const ParsedTarget = struct {
    url: []const u8,
    title: ?[]const u8,
};

pub const InlineTarget = struct {
    url: []const u8,
    title: ?[]const u8,
    end: usize,
};

pub const InlineTargetParse = union(enum) {
    match: InlineTarget,
    incomplete,
    invalid,
};

const RawLinkDestination = struct {
    raw: []const u8,
    end: usize,
};

const RawLinkTitle = struct {
    raw: []const u8,
    end: usize,
};

const RawParsedTarget = struct {
    url_raw: []const u8,
    title_raw: ?[]const u8,
};

const RawInlineTarget = struct {
    url_raw: []const u8,
    title_raw: ?[]const u8,
    end: usize,
};

const LinkWhitespace = struct {
    end: usize,
    consumed: bool,
};

pub const max_reference_label_chars = 999;

pub fn definition(text: []const u8) ?Definition {
    const indent = parse_block.countIndentUpTo(text, parse_block.max_block_indent);
    if (indent >= text.len or text[indent] != '[') return null;

    const close = findReferenceLabelEnd(text, indent + 1) orelse return null;
    if (close + 1 >= text.len or text[close + 1] != ':') return null;

    const label = text[indent + 1 .. close];
    if (!hasReferenceLabelText(label)) return null;

    const raw_target = parseTargetRaw(text[close + 2 ..]) orelse return null;
    return .{
        .label = label,
        .url = raw_target.url_raw,
        .title = raw_target.title_raw,
    };
}

pub fn definitionNeedsDestinationContinuation(line: []const u8) bool {
    const indent = parse_block.countIndentUpTo(line, parse_block.max_block_indent);
    if (indent >= line.len or line[indent] != '[') return false;

    const close = findReferenceLabelEnd(line, indent + 1) orelse return false;
    if (close + 1 >= line.len or line[close + 1] != ':') return false;

    const label = line[indent + 1 .. close];
    if (!hasReferenceLabelText(label)) return false;

    return std.mem.trim(u8, line[close + 2 ..], parse_block.horizontal_whitespace).len == 0;
}

pub fn normalizeReferenceLabel(allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
    var normalized: std.ArrayListUnmanaged(u8) = .empty;
    errdefer normalized.deinit(allocator);

    try appendNormalizedReferenceLabel(&normalized, allocator, label);
    return try normalized.toOwnedSlice(allocator);
}

pub fn normalizeReferenceLabelInto(
    buffer: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    label: []const u8,
) ![]const u8 {
    buffer.clearRetainingCapacity();
    try appendNormalizedReferenceLabel(buffer, allocator, label);
    return buffer.items;
}

pub fn findReferenceLabelEnd(text: []const u8, start: usize) ?usize {
    var pos = start;
    var char_count: usize = 0;
    while (pos < text.len) {
        switch (text[pos]) {
            '\\' => {
                if (pos + 1 < text.len and (text[pos + 1] == '[' or text[pos + 1] == ']')) {
                    if (char_count + 2 > max_reference_label_chars) return null;
                    char_count += 2;
                    pos += 2;
                    continue;
                }
                if (char_count + 1 > max_reference_label_chars) return null;
                char_count += 1;
                pos += 1;
            },
            '[' => return null,
            ']' => return pos,
            else => {
                const codepoint_len = referenceLabelCodepointLen(text, pos);
                if (char_count + 1 > max_reference_label_chars) return null;
                char_count += 1;
                pos += codepoint_len;
            },
        }
    }
    return null;
}

pub fn lineCouldStartLinkTitle(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, parse_block.horizontal_whitespace);
    if (trimmed.len == 0) return false;
    return switch (trimmed[0]) {
        '"', '\'', '(' => true,
        else => false,
    };
}

pub fn referenceLabelLengthFits(label: []const u8) bool {
    var pos: usize = 0;
    var char_count: usize = 0;
    while (pos < label.len) {
        const codepoint_len = referenceLabelCodepointLen(label, pos);
        char_count += 1;
        if (char_count > max_reference_label_chars) return false;
        pos += codepoint_len;
    }
    return true;
}

fn appendNormalizedReferenceLabel(
    normalized: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    label: []const u8,
) !void {
    var pos: usize = 0;
    while (pos < label.len and isReferenceLabelWhitespace(label[pos])) : (pos += 1) {}

    var pending_space = false;
    while (pos < label.len) {
        if (isReferenceLabelWhitespace(label[pos])) {
            pending_space = normalized.items.len > 0;
            while (pos < label.len and isReferenceLabelWhitespace(label[pos])) : (pos += 1) {}
            continue;
        }

        if (pending_space and normalized.items.len > 0) {
            try normalized.append(allocator, ' ');
            pending_space = false;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(label[pos]) catch {
            try normalized.append(allocator, std.ascii.toLower(label[pos]));
            pos += 1;
            continue;
        };

        if (pos + sequence_len > label.len) {
            try normalized.append(allocator, std.ascii.toLower(label[pos]));
            pos += 1;
            continue;
        }

        const codepoint = std.unicode.utf8Decode(label[pos .. pos + sequence_len]) catch {
            try normalized.append(allocator, std.ascii.toLower(label[pos]));
            pos += 1;
            continue;
        };

        try unicode_case_fold.appendCaseFoldedCodepoint(normalized, allocator, codepoint);
        pos += sequence_len;
    }
}

pub fn parseTarget(allocator: std.mem.Allocator, text: []const u8) !?ParsedTarget {
    const raw_target = parseTargetRaw(text) orelse return null;
    return .{
        .url = try materializeLinkText(allocator, raw_target.url_raw),
        .title = if (raw_target.title_raw) |raw_title|
            try materializeLinkText(allocator, raw_title)
        else
            null,
    };
}

pub fn parseInlineTarget(allocator: std.mem.Allocator, text: []const u8) !InlineTargetParse {
    return switch (scanInlineTargetRaw(text)) {
        .match => |raw_target| .{ .match = .{
            .url = try ownLinkText(allocator, raw_target.url_raw),
            .title = if (raw_target.title_raw) |raw_title|
                try ownLinkText(allocator, raw_title)
            else
                null,
            .end = raw_target.end,
        } },
        .incomplete => .incomplete,
        .invalid => .invalid,
    };
}

pub fn parseLinkDestination(
    allocator: std.mem.Allocator,
    text: []const u8,
    start: usize,
) !?LinkDestination {
    const raw_destination = scanLinkDestination(text, start) orelse return null;
    return .{
        .url = try materializeLinkText(allocator, raw_destination.raw),
        .end = raw_destination.end,
    };
}

pub fn parseLinkTitle(
    allocator: std.mem.Allocator,
    text: []const u8,
    start: usize,
) !?LinkTitle {
    const raw_title = scanLinkTitle(text, start) orelse return null;
    return .{
        .title = try materializeLinkText(allocator, raw_title.raw),
        .end = raw_title.end,
    };
}

pub fn materializeLinkText(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (!needsLinkMaterialization(raw)) return raw;

    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buffer.deinit(allocator);

    var pos: usize = 0;
    while (pos < raw.len) {
        if (raw[pos] == '\\' and pos + 1 < raw.len and isEscapable(raw[pos + 1])) {
            try buffer.append(allocator, raw[pos + 1]);
            pos += 2;
            continue;
        }

        if (raw[pos] == '&') {
            if (text_util.decode(raw, pos)) |entity| {
                try buffer.appendSlice(allocator, entity.bytes[0..entity.len]);
                pos = entity.end;
                continue;
            }
        }

        try buffer.append(allocator, raw[pos]);
        pos += 1;
    }

    return try buffer.toOwnedSlice(allocator);
}

pub fn ownLinkText(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const materialized = try materializeLinkText(allocator, raw);
    if (materialized.ptr == raw.ptr and materialized.len == raw.len) {
        return try allocator.dupe(u8, raw);
    }
    return materialized;
}

fn parseTargetRaw(text: []const u8) ?RawParsedTarget {
    var pos = consumeLinkWhitespace(text, 0).end;

    const raw_destination = scanLinkDestination(text, pos) orelse return null;
    pos = raw_destination.end;

    const separation = consumeLinkWhitespace(text, pos);
    pos = separation.end;

    var raw_title: ?[]const u8 = null;
    if (pos < text.len) {
        if (!separation.consumed) return null;

        const parsed_title = scanLinkTitle(text, pos) orelse return null;
        raw_title = parsed_title.raw;
        pos = consumeLinkWhitespace(text, parsed_title.end).end;
    }

    if (pos != text.len) return null;

    return .{
        .url_raw = raw_destination.raw,
        .title_raw = raw_title,
    };
}

fn scanInlineTargetRaw(text: []const u8) union(enum) {
    match: RawInlineTarget,
    incomplete,
    invalid,
} {
    var pos = consumeLinkWhitespace(text, 0).end;
    if (pos == text.len) return .incomplete;

    if (text[pos] == ')') {
        return .{ .match = .{
            .url_raw = text[pos..pos],
            .title_raw = null,
            .end = pos + 1,
        } };
    }

    const raw_destination = switch (scanLinkDestinationStatus(text, pos)) {
        .match => |value| value,
        .incomplete => return .incomplete,
        .invalid => return .invalid,
    };
    pos = raw_destination.end;

    const separation = consumeLinkWhitespace(text, pos);
    pos = separation.end;
    if (pos == text.len) return .incomplete;

    var raw_title: ?[]const u8 = null;
    if (text[pos] != ')') {
        if (!separation.consumed) return .invalid;

        const parsed_title = switch (scanLinkTitleStatus(text, pos)) {
            .match => |value| value,
            .incomplete => return .incomplete,
            .invalid => return .invalid,
        };
        raw_title = parsed_title.raw;
        pos = consumeLinkWhitespace(text, parsed_title.end).end;
        if (pos == text.len) return .incomplete;
    }

    if (text[pos] != ')') return .invalid;
    return .{ .match = .{
        .url_raw = raw_destination.raw,
        .title_raw = raw_title,
        .end = pos + 1,
    } };
}

fn scanLinkDestination(text: []const u8, start: usize) ?RawLinkDestination {
    return switch (scanLinkDestinationStatus(text, start)) {
        .match => |value| value,
        else => null,
    };
}

fn scanLinkDestinationStatus(text: []const u8, start: usize) union(enum) {
    match: RawLinkDestination,
    incomplete,
    invalid,
} {
    if (start >= text.len) return .incomplete;

    if (text[start] == '<') {
        var pos = start + 1;
        while (pos < text.len) {
            switch (text[pos]) {
                '\\' => {
                    if (pos + 1 < text.len and isEscapable(text[pos + 1])) {
                        pos += 2;
                    } else {
                        pos += 1;
                    }
                },
                '>' => return .{ .match = .{
                    .raw = text[start + 1 .. pos],
                    .end = pos + 1,
                } },
                '<', '\n', '\r' => return .invalid,
                else => pos += 1,
            }
        }

        return .incomplete;
    }

    var pos = start;
    var paren_depth: usize = 0;
    while (pos < text.len) {
        switch (text[pos]) {
            '\\' => {
                if (pos + 1 < text.len and isEscapable(text[pos + 1])) {
                    pos += 2;
                } else {
                    pos += 1;
                }
            },
            '(' => {
                paren_depth += 1;
                pos += 1;
            },
            ')' => {
                if (paren_depth == 0) break;
                paren_depth -= 1;
                pos += 1;
            },
            '\n', '\r' => break,
            else => {
                if (isInvalidBareDestinationByte(text[pos])) return .invalid;
                if (parse_block.isHorizontalWhitespace(text[pos])) break;
                pos += 1;
            },
        }
    }

    if (pos == start) return .invalid;
    if (paren_depth != 0) return .incomplete;
    return .{ .match = .{
        .raw = text[start..pos],
        .end = pos,
    } };
}

fn scanLinkTitle(text: []const u8, start: usize) ?RawLinkTitle {
    return switch (scanLinkTitleStatus(text, start)) {
        .match => |value| value,
        else => null,
    };
}

fn scanLinkTitleStatus(text: []const u8, start: usize) union(enum) {
    match: RawLinkTitle,
    incomplete,
    invalid,
} {
    if (start >= text.len) return .incomplete;

    const closing_delim: u8 = switch (text[start]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return .invalid,
    };

    var pos = start + 1;
    while (pos < text.len) {
        switch (text[pos]) {
            '\\' => {
                pos += 1;
                if (pos < text.len) pos += 1;
            },
            '\n', '\r' => {
                const after_line_ending = consumeLineEnding(text, pos) orelse unreachable;
                if (lineEndingStartsBlankLine(text, after_line_ending)) return .invalid;
                pos = after_line_ending;
            },
            else => {
                if (closing_delim == ')' and text[pos] == '(') return .invalid;
                if (text[pos] == closing_delim) {
                    return .{ .match = .{
                        .raw = text[start + 1 .. pos],
                        .end = pos + 1,
                    } };
                }
                pos += 1;
            },
        }
    }

    return .incomplete;
}

fn needsLinkMaterialization(raw: []const u8) bool {
    var pos: usize = 0;
    while (pos < raw.len) {
        if (raw[pos] == '\\' and pos + 1 < raw.len and isEscapable(raw[pos + 1])) return true;
        if (raw[pos] == '&' and text_util.decode(raw, pos) != null) return true;
        pos += 1;
    }
    return false;
}

fn consumeLinkWhitespace(text: []const u8, start: usize) LinkWhitespace {
    var pos = start;
    var consumed = false;

    while (pos < text.len and parse_block.isHorizontalWhitespace(text[pos])) : (pos += 1) {
        consumed = true;
    }

    if (consumeLineEnding(text, pos)) |after_line_ending| {
        consumed = true;
        pos = after_line_ending;
        while (pos < text.len and parse_block.isHorizontalWhitespace(text[pos])) : (pos += 1) {}
    }

    return .{
        .end = pos,
        .consumed = consumed,
    };
}

fn consumeLineEnding(text: []const u8, start: usize) ?usize {
    if (start >= text.len) return null;
    if (text[start] == '\n') return start + 1;
    if (text[start] != '\r') return null;
    if (start + 1 < text.len and text[start + 1] == '\n') return start + 2;
    return start + 1;
}

fn lineEndingStartsBlankLine(text: []const u8, start: usize) bool {
    var pos = start;
    while (pos < text.len and parse_block.isHorizontalWhitespace(text[pos])) : (pos += 1) {}
    return consumeLineEnding(text, pos) != null;
}

fn hasReferenceLabelText(label: []const u8) bool {
    for (label) |char| {
        if (!isReferenceLabelWhitespace(char)) return true;
    }
    return false;
}

fn referenceLabelCodepointLen(text: []const u8, start: usize) usize {
    const sequence_len = std.unicode.utf8ByteSequenceLength(text[start]) catch return 1;
    if (start + sequence_len > text.len) return 1;
    _ = std.unicode.utf8Decode(text[start .. start + sequence_len]) catch return 1;
    return sequence_len;
}

fn isReferenceLabelWhitespace(char: u8) bool {
    return switch (char) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

fn isEscapable(char: u8) bool {
    return switch (char) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/' => true,
        ':', ';', '<', '=', '>', '?', '@' => true,
        '[', '\\', ']', '^', '_', '`' => true,
        '{', '|', '}', '~' => true,
        else => false,
    };
}

fn isInvalidBareDestinationByte(char: u8) bool {
    if (char == 0x7F) return true;
    return char < 0x20 and char != '\t' and char != '\n' and char != '\r';
}
