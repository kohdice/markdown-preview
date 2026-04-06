const std = @import("std");
const block = @import("block.zig");
const link_mod = @import("link.zig");

const LinkDefMap = link_mod.LinkDefMap;

const max_ref_label_len = 256;

/// CommonMark §6.2: delimiter runs of length 1/2/3 map to emphasis, strong,
/// and strong+emphasis; the same value drives the multiple-of-three
/// rejection rule in the closer search.
const max_emphasis_delim_run: usize = 3;

/// Accept both `~text~` and `~~text~~`; longer runs fall through as literal
/// tildes.
const max_strikethrough_delim_run: usize = 2;

/// RFC 3629 §3: a UTF-8 continuation byte has the bit pattern `10xxxxxx`.
const utf8_continuation_mask: u8 = 0xC0;
const utf8_continuation_tag: u8 = 0x80;

const scheme_separator: []const u8 = "://";

pub const InlineKind = enum { text, code_span, link_text, link_url, link_title, autolink, image_alt, image_url, emphasis, strong, bold_italic, strikethrough };

pub const InlineSegment = struct {
    kind: InlineKind,
    content: []const u8,
};

pub fn parseInlineSegments(allocator: std.mem.Allocator, text: []const u8, segments: *std.ArrayListUnmanaged(InlineSegment), link_defs: *const LinkDefMap) !void {
    var index: usize = 0;
    var plain_start: usize = 0;

    while (index < text.len) {
        switch (text[index]) {
            '\\' => {
                if (index + 1 < text.len and isEscapable(text[index + 1])) {
                    if (plain_start < index)
                        try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..index] });
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
            '!' => {
                if (index + 1 < text.len and text[index + 1] == '[') {
                    if (findLinkParts(text, index + 1)) |link| {
                        if (plain_start < index)
                            try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..index] });
                        try segments.append(allocator, .{ .kind = .image_alt, .content = text[link.text_start..link.text_end] });
                        try segments.append(allocator, .{ .kind = .image_url, .content = text[link.url_start..link.url_end] });
                        if (link.title) |title|
                            try segments.append(allocator, .{ .kind = .link_title, .content = title });
                        index = link.full_end;
                        plain_start = index;
                        continue;
                    }
                }
                index += 1;
            },
            '[' => {
                if (findLinkParts(text, index)) |link| {
                    if (plain_start < index)
                        try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..index] });
                    try segments.append(allocator, .{ .kind = .link_text, .content = text[link.text_start..link.text_end] });
                    try segments.append(allocator, .{ .kind = .link_url, .content = text[link.url_start..link.url_end] });
                    if (link.title) |title|
                        try segments.append(allocator, .{ .kind = .link_title, .content = title });
                    index = link.full_end;
                    plain_start = index;
                    continue;
                }
                if (tryParseRefLink(text, index, link_defs)) |ref| {
                    if (plain_start < index)
                        try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..index] });
                    try segments.append(allocator, .{ .kind = .link_text, .content = ref.link_text });
                    try segments.append(allocator, .{ .kind = .link_url, .content = ref.url });
                    if (ref.title) |title|
                        try segments.append(allocator, .{ .kind = .link_title, .content = title });
                    index = ref.end;
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
            '<' => {
                if (tryParseAutolink(text, index)) |al| {
                    if (plain_start < index)
                        try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..index] });
                    try segments.append(allocator, .{ .kind = .autolink, .content = al.url });
                    index = al.end;
                    plain_start = index;
                    continue;
                }
                index += 1;
            },
            else => {
                if (text[index] == 'h') {
                    if (tryParseBareUrl(text, index)) |bare| {
                        if (plain_start < index)
                            try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..index] });
                        try segments.append(allocator, .{ .kind = .autolink, .content = text[index..bare.end] });
                        index = bare.end;
                        plain_start = index;
                        continue;
                    }
                }
                index += 1;
            },
        }
    }

    if (plain_start < text.len)
        try segments.append(allocator, .{ .kind = .text, .content = text[plain_start..] });
}

pub fn findCodeSpanEnd(text: []const u8, start: usize) ?usize {
    var open_len: usize = 0;
    while (start + open_len < text.len and text[start + open_len] == '`') : (open_len += 1) {}
    if (open_len == 0) return null;

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

pub fn isEscapable(c: u8) bool {
    return switch (c) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/' => true,
        ':', ';', '<', '=', '>', '?', '@' => true,
        '[', '\\', ']', '^', '_', '`' => true,
        '{', '|', '}', '~' => true,
        else => false,
    };
}

const LinkParts = struct {
    text_start: usize,
    text_end: usize,
    url_start: usize,
    url_end: usize,
    title: ?[]const u8 = null,
    full_end: usize,
};

fn findLinkParts(text: []const u8, start: usize) ?LinkParts {
    var bracket_depth: usize = 1;
    var bpos = start + 1;
    while (bpos < text.len) : (bpos += 1) {
        switch (text[bpos]) {
            '[' => bracket_depth += 1,
            ']' => {
                bracket_depth -= 1;
                if (bracket_depth == 0) break;
            },
            '\\' => {
                if (bpos + 1 < text.len) bpos += 1;
            },
            else => {},
        }
    }
    if (bracket_depth != 0) return null;
    const close_bracket = bpos;
    if (close_bracket + 1 >= text.len or text[close_bracket + 1] != '(') return null;

    var depth: usize = 1;
    var pos = close_bracket + 2;
    while (pos < text.len) : (pos += 1) {
        switch (text[pos]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    const inner_start = close_bracket + 2;
                    const inner_end = pos;
                    const title_info = extractTitle(text[inner_start..inner_end]);

                    return .{
                        .text_start = start + 1,
                        .text_end = close_bracket,
                        .url_start = inner_start,
                        .url_end = inner_start + title_info.url_len,
                        .title = title_info.title,
                        .full_end = pos + 1,
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

const TitleInfo = struct {
    url_len: usize,
    title: ?[]const u8,
};

fn extractTitle(inner: []const u8) TitleInfo {
    const trimmed = std.mem.trimEnd(u8, inner, block.horizontal_whitespace);
    if (trimmed.len < 4) return .{ .url_len = inner.len, .title = null };

    const last = trimmed[trimmed.len - 1];
    const open_quote: u8 = switch (last) {
        '"' => '"',
        '\'' => '\'',
        else => return .{ .url_len = inner.len, .title = null },
    };

    var i = trimmed.len - 2;
    while (i > 0) : (i -= 1) {
        if (trimmed[i] == open_quote) {
            if (i > 0 and (trimmed[i - 1] == ' ' or trimmed[i - 1] == '\t')) {
                const url_part = std.mem.trimEnd(u8, trimmed[0 .. i - 1], block.horizontal_whitespace);
                if (url_part.len == 0) return .{ .url_len = inner.len, .title = null };
                return .{
                    .url_len = url_part.len,
                    .title = trimmed[i + 1 .. trimmed.len - 1],
                };
            }
        }
    }

    return .{ .url_len = inner.len, .title = null };
}

const CharClass = enum { whitespace, punctuation, other };

fn prevCodepoint(text: []const u8, pos: usize) ?u21 {
    if (pos == 0) return null;
    var start = pos - 1;
    while (start > 0 and text[start] & utf8_continuation_mask == utf8_continuation_tag) : (start -= 1) {}
    if (text[start] & utf8_continuation_mask == utf8_continuation_tag) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[start]) catch return null;
    if (start + len != pos) return null;
    return std.unicode.utf8Decode(text[start..][0..len]) catch null;
}

fn nextCodepoint(text: []const u8, pos: usize) ?u21 {
    if (pos >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return null;
    if (pos + len > text.len) return null;
    return std.unicode.utf8Decode(text[pos..][0..len]) catch null;
}

fn cpClass(cp: ?u21) CharClass {
    const c = cp orelse return .whitespace;
    if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C) return .whitespace;
    if (c == 0x00A0) return .whitespace;
    if (c >= 0x2000 and c <= 0x200A) return .whitespace;
    if (c == 0x202F or c == 0x205F or c == 0x3000) return .whitespace;
    if (c >= 0x21 and c <= 0x2F) return .punctuation;
    if (c >= 0x3A and c <= 0x40) return .punctuation;
    if (c >= 0x5B and c <= 0x60) return .punctuation;
    if (c >= 0x7B and c <= 0x7E) return .punctuation;
    if (c >= 0x00A1 and c <= 0x00BF) return .punctuation;
    if (c == 0x00D7 or c == 0x00F7) return .punctuation;
    if (c >= 0x2010 and c <= 0x2027) return .punctuation;
    if (c >= 0x2030 and c <= 0x205E) return .punctuation;
    if (c >= 0x20A0 and c <= 0x20CF) return .punctuation;
    if (c >= 0x2100 and c <= 0x214F) return .punctuation;
    if (c >= 0x2190 and c <= 0x21FF) return .punctuation;
    if (c >= 0x2200 and c <= 0x22FF) return .punctuation;
    if (c >= 0x2300 and c <= 0x23FF) return .punctuation;
    if (c >= 0x2500 and c <= 0x25FF) return .punctuation;
    if (c >= 0x2600 and c <= 0x26FF) return .punctuation;
    if (c >= 0x2E00 and c <= 0x2E4F) return .punctuation;
    if (c >= 0x3001 and c <= 0x303F) return .punctuation;
    if (c >= 0xFF01 and c <= 0xFF0F) return .punctuation;
    if (c >= 0xFF1A and c <= 0xFF20) return .punctuation;
    if (c >= 0xFF3B and c <= 0xFF3F) return .punctuation;
    if (c >= 0xFF5B and c <= 0xFF65) return .punctuation;
    return .other;
}

fn checkFlanking(before: CharClass, after: CharClass) struct { left: bool, right: bool } {
    const left = after != .whitespace and
        (after != .punctuation or before == .whitespace or before == .punctuation);

    const right = before != .whitespace and
        (before != .punctuation or after == .whitespace or after == .punctuation);

    return .{ .left = left, .right = right };
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

    if (delim_len == 0 or delim_len > max_emphasis_delim_run) return null;

    const after_delim = start + delim_len;
    if (after_delim >= text.len) return null;

    const open_before = cpClass(prevCodepoint(text, start));
    const open_after = cpClass(nextCodepoint(text, after_delim));
    const open_flank = checkFlanking(open_before, open_after);

    if (!open_flank.left) return null;

    if (delim_char == '_' and open_flank.right and open_before != .punctuation) return null;

    var pos = after_delim;
    while (pos < text.len) {
        if (text[pos] == '\\' and pos + 1 < text.len and isEscapable(text[pos + 1])) {
            pos += 2;
            continue;
        }
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
                const close_after_pos = pos + close_len;
                const close_before = cpClass(prevCodepoint(text, pos));
                const close_after = cpClass(if (close_after_pos < text.len) nextCodepoint(text, close_after_pos) else null);
                const close_flank = checkFlanking(close_before, close_after);

                if (close_flank.right) {
                    if (delim_char == '_' and close_flank.left and close_after != .punctuation) {
                        pos += close_len;
                        continue;
                    }

                    const sum = delim_len + close_len;
                    if (sum % max_emphasis_delim_run == 0 and
                        (delim_len % max_emphasis_delim_run != 0 or
                            close_len % max_emphasis_delim_run != 0))
                    {
                        pos += close_len;
                        continue;
                    }

                    const extra = close_len - delim_len;
                    const content = text[after_delim .. pos + extra];
                    if (content.len == 0) {
                        pos += close_len;
                        continue;
                    }

                    const kind: InlineKind = if (delim_len >= max_emphasis_delim_run)
                        .bold_italic
                    else if (delim_len == 2)
                        .strong
                    else
                        .emphasis;

                    return .{
                        .kind = kind,
                        .content = content,
                        .end = pos + close_len,
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

    if (delim_len < 1 or delim_len > max_strikethrough_delim_run) return null;

    const after_delim = start + delim_len;
    if (after_delim >= text.len) return null;
    if (text[after_delim] == ' ' or text[after_delim] == '\t') return null;

    var pos = after_delim;
    while (pos < text.len) {
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

const AutolinkResult = struct {
    url: []const u8,
    end: usize,
};

fn tryParseAutolink(text: []const u8, start: usize) ?AutolinkResult {
    if (start >= text.len or text[start] != '<') return null;

    var pos = start + 1;
    var scheme_end: usize = 0;
    while (pos < text.len) {
        switch (text[pos]) {
            '>' => {
                if (scheme_end == 0) return null;
                const scheme = text[start + 1 .. scheme_end - scheme_separator.len];
                if (scheme.len == 0) return null;
                if (!std.ascii.isAlphabetic(scheme[0])) return null;
                return .{
                    .url = text[start + 1 .. pos],
                    .end = pos + 1,
                };
            },
            ' ', '\t', '\n', '<' => return null,
            ':' => {
                if (scheme_end == 0 and std.mem.startsWith(u8, text[pos..], scheme_separator)) {
                    scheme_end = pos + scheme_separator.len;
                }
                pos += 1;
            },
            else => {
                pos += 1;
            },
        }
    }
    return null;
}

const BareUrlResult = struct {
    end: usize,
};

fn tryParseBareUrl(text: []const u8, start: usize) ?BareUrlResult {
    const rest = text[start..];
    const https: []const u8 = "https://";
    const http: []const u8 = "http://";
    const prefix_len: usize = if (std.mem.startsWith(u8, rest, https))
        https.len
    else if (std.mem.startsWith(u8, rest, http))
        http.len
    else
        return null;

    if (start > 0) {
        const prev = text[start - 1];
        if (std.ascii.isAlphanumeric(prev) or prev == '.' or prev == '/' or prev == ':')
            return null;
    }

    if (start + prefix_len >= text.len) return null;

    var pos = start + prefix_len;
    while (pos < text.len) {
        switch (text[pos]) {
            ' ', '<', '>', 0...0x1f, 0x7f => break,
            else => pos += 1,
        }
    }

    while (pos > start + prefix_len) {
        switch (text[pos - 1]) {
            '.', ',', ':', '!', '?', '*', '_', '~', '\'', '"' => pos -= 1,
            ')' => {
                var open_count: usize = 0;
                var close_count: usize = 0;
                for (text[start..pos]) |c| {
                    if (c == '(') open_count += 1;
                    if (c == ')') close_count += 1;
                }
                if (close_count > open_count) {
                    pos -= 1;
                } else {
                    break;
                }
            },
            else => break,
        }
    }

    if (pos <= start + prefix_len) return null;

    const domain_start = start + prefix_len;
    const path_start = std.mem.indexOfScalarPos(u8, text[0..pos], domain_start, '/') orelse pos;
    const domain = text[domain_start..path_start];
    if (std.mem.indexOfScalar(u8, domain, '.') == null) return null;

    return .{ .end = pos };
}

const RefLinkResult = struct {
    link_text: []const u8,
    url: []const u8,
    title: ?[]const u8,
    end: usize,
};

fn tryParseRefLink(text: []const u8, start: usize, link_defs: *const LinkDefMap) ?RefLinkResult {
    if (start >= text.len or text[start] != '[') return null;

    var bracket_depth: usize = 1;
    var bpos = start + 1;
    while (bpos < text.len) : (bpos += 1) {
        switch (text[bpos]) {
            '[' => bracket_depth += 1,
            ']' => {
                bracket_depth -= 1;
                if (bracket_depth == 0) break;
            },
            '\\' => {
                if (bpos + 1 < text.len) bpos += 1;
            },
            else => {},
        }
    }
    if (bracket_depth != 0) return null;

    const text_end = bpos;
    const link_text = text[start + 1 .. text_end];

    if (text_end + 1 < text.len and text[text_end + 1] == '[') {
        const ref_start = text_end + 2;
        const ref_end = std.mem.indexOfScalarPos(u8, text, ref_start, ']') orelse return null;
        const ref_label = if (ref_end > ref_start) text[ref_start..ref_end] else link_text;

        var lower_buf: [max_ref_label_len]u8 = undefined;
        if (ref_label.len > lower_buf.len) return null;
        const lower_key = std.ascii.lowerString(lower_buf[0..ref_label.len], ref_label);

        if (link_defs.get(lower_key)) |def| {
            return .{
                .link_text = link_text,
                .url = def.url,
                .title = def.title,
                .end = ref_end + 1,
            };
        }
    }

    if (text_end + 1 < text.len and (text[text_end + 1] == '(' or text[text_end + 1] == '['))
        return null;

    var lower_buf: [max_ref_label_len]u8 = undefined;
    if (link_text.len > lower_buf.len) return null;
    const lower_key = std.ascii.lowerString(lower_buf[0..link_text.len], link_text);

    if (link_defs.get(lower_key)) |def| {
        return .{
            .link_text = link_text,
            .url = def.url,
            .title = def.title,
            .end = text_end + 1,
        };
    }

    return null;
}
