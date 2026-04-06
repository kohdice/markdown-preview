const std = @import("std");
const ansi = @import("ansi.zig");

const ESC = 0x1b;

// Unicode formatting characters with zero display width.
const SOFT_HYPHEN = 0x00AD;
const ZWSP = 0x200B;
const ZWNJ = 0x200C;
const ZWJ = 0x200D;
const WORD_JOINER = 0x2060;
const BOM = 0xFEFF;

/// ANSI CSI parameter byte range (0x20–0x3f per ECMA-48 §5.4)
fn isCsiParamByte(byte: u8) bool {
    return byte >= 0x20 and byte <= 0x3f;
}

/// Skip an ANSI CSI escape sequence starting at text[i].
/// Returns the index past the final byte, or null if not a CSI sequence.
fn skipAnsiCsi(text: []const u8, start: usize) ?usize {
    if (start + 1 >= text.len) return null;
    if (text[start] != ESC or text[start + 1] != '[') return null;
    var i = start + 2;
    while (i < text.len and isCsiParamByte(text[i])) : (i += 1) {}
    if (i < text.len) i += 1;
    return i;
}

/// Calculate the display width of a UTF-8 string in terminal columns.
/// ASCII printable characters are width 1, CJK characters are width 2,
/// ANSI escape sequences are width 0, control characters are width 0.
/// Combining characters and variation selectors are width 0.
/// ZWJ emoji sequences (e.g., family emoji) are counted as a single
/// width-2 unit instead of summing each component.
pub fn displayWidth(text: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    var suppress_next_emoji = false;

    while (i < text.len) {
        if (skipAnsiCsi(text, i)) |after| {
            i = after;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;

        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            i += 1;
            continue;
        };
        i += len;

        if (suppress_next_emoji) {
            suppress_next_emoji = false;
            if (isEmoji(cp)) continue;
        }

        if (cp == ZWJ) {
            suppress_next_emoji = true;
            continue;
        }

        w += codepointWidth(cp);
    }
    return w;
}

/// Slice a string to fit within max_width display columns.
/// Preserves ANSI escape sequences and respects UTF-8 byte boundaries.
pub fn sliceToWidth(text: []const u8, max_width: usize) []const u8 {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (skipAnsiCsi(text, i)) |after| {
            i = after;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;

        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            i += 1;
            continue;
        };

        const cw = codepointWidth(cp);
        if (width + cw > max_width) break;
        width += cw;
        i += len;
    }
    return text[0..i];
}

/// Like sliceToWidth but returns an allocated slice that appends an ANSI reset
/// sequence (\x1b[0m) if the text was truncated inside an active ANSI style.
/// This prevents style leakage into subsequent terminal output.
pub fn sliceToWidthAlloc(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]u8 {
    var w: usize = 0;
    var i: usize = 0;
    var ansi_active = false;
    var suppress_next_emoji = false;

    while (i < text.len) {
        if (skipAnsiCsi(text, i)) |after| {
            const seq = text[i..after];
            ansi_active = !std.mem.eql(u8, seq, ansi.reset_sequence);
            i = after;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            w += 1;
            continue;
        };
        if (i + len > text.len) break;

        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            i += 1;
            w += 1;
            continue;
        };

        if (suppress_next_emoji) {
            suppress_next_emoji = false;
            if (isEmoji(cp)) {
                i += len;
                continue;
            }
        }

        if (cp == ZWJ) {
            suppress_next_emoji = true;
            i += len;
            continue;
        }

        const cw = codepointWidth(cp);
        if (w + cw > max_width) break;
        w += cw;
        i += len;
    }

    const truncated = i < text.len;
    if (truncated and ansi_active) {
        var result = try allocator.alloc(u8, i + ansi.reset_sequence.len);
        @memcpy(result[0..i], text[0..i]);
        @memcpy(result[i..][0..ansi.reset_sequence.len], ansi.reset_sequence);
        return result;
    }
    return try allocator.dupe(u8, text[0..i]);
}

/// Wrap text to fit within max_width display columns.
/// Preserves ANSI escape sequences. Breaks at word boundaries (spaces) when possible.
/// Falls back to hard-breaking at the column limit if no space is found.
pub fn wrapText(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]u8 {
    if (max_width == 0) return try allocator.dupe(u8, text);

    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);

    var col: usize = 0;
    var last_space_result: ?usize = null;
    var col_after_last_space: usize = 0;
    var i: usize = 0;
    var suppress_next_emoji = false;

    while (i < text.len) {
        if (skipAnsiCsi(text, i)) |after| {
            try result.appendSlice(allocator, text[i..after]);
            i = after;
            continue;
        }

        if (text[i] == '\n') {
            try result.append(allocator, '\n');
            col = 0;
            last_space_result = null;
            suppress_next_emoji = false;
            i += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            try result.append(allocator, text[i]);
            i += 1;
            col += 1;
            continue;
        };
        if (i + len > text.len) break;

        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            try result.append(allocator, text[i]);
            i += 1;
            col += 1;
            continue;
        };

        if (suppress_next_emoji) {
            suppress_next_emoji = false;
            if (isEmoji(cp)) {
                try result.appendSlice(allocator, text[i..][0..len]);
                i += len;
                continue;
            }
        }

        if (cp == ZWJ) {
            suppress_next_emoji = true;
            try result.appendSlice(allocator, text[i..][0..len]);
            i += len;
            continue;
        }

        const cw = codepointWidth(cp);

        if (col + cw > max_width) {
            if (text[i] == ' ') {
                // Space at overflow boundary — use it as break point directly
                try result.append(allocator, '\n');
                col = 0;
                last_space_result = null;
                i += len;
                continue;
            }
            if (last_space_result) |space_pos| {
                // Backtrack: replace last space with newline for word-wrap
                result.items[space_pos] = '\n';
                col -= col_after_last_space;
                last_space_result = null;
            } else {
                // No word boundary found — hard break at current position
                try result.append(allocator, '\n');
                col = 0;
            }
        }

        if (text[i] == ' ') {
            last_space_result = result.items.len;
            try result.appendSlice(allocator, text[i..][0..len]);
            col += cw;
            col_after_last_space = col;
            i += len;
            continue;
        }

        try result.appendSlice(allocator, text[i..][0..len]);
        col += cw;
        i += len;
    }

    return try result.toOwnedSlice(allocator);
}

fn isEmoji(cp: u21) bool {
    if (cp >= 0x1F300 and cp <= 0x1F9FF) return true;
    if (cp >= 0x1FA00 and cp <= 0x1FAFF) return true;
    if (cp >= 0x2600 and cp <= 0x26FF) return true; // Misc Symbols
    if (cp >= 0x2700 and cp <= 0x27BF) return true; // Dingbats
    return false;
}

fn codepointWidth(cp: u21) usize {
    if (cp < 0x20) return 0;
    if (cp == 0x7f) return 0;

    switch (cp) {
        ZWSP, ZWNJ, ZWJ, WORD_JOINER, BOM, SOFT_HYPHEN => return 0,
        else => {},
    }

    // Variation Selectors
    if (cp >= 0xFE00 and cp <= 0xFE0F) return 0; // VS1-VS16
    if (cp >= 0xE0100 and cp <= 0xE01EF) return 0; // VS17-VS256

    // Combining Diacritical Marks
    if (cp >= 0x0300 and cp <= 0x036F) return 0;
    // Combining Diacritical Marks Extended
    if (cp >= 0x1AB0 and cp <= 0x1AFF) return 0;
    // Combining Diacritical Marks Supplement
    if (cp >= 0x1DC0 and cp <= 0x1DFF) return 0;
    // Combining Diacritical Marks for Symbols
    if (cp >= 0x20D0 and cp <= 0x20FF) return 0;
    // Combining Half Marks
    if (cp >= 0xFE20 and cp <= 0xFE2F) return 0;
    // Thai combining marks
    if (cp >= 0x0E31 and cp <= 0x0E3A) return 0;
    if (cp >= 0x0E47 and cp <= 0x0E4E) return 0;

    // Skin tone modifiers (Fitzpatrick) — modify preceding emoji
    if (cp >= 0x1F3FB and cp <= 0x1F3FF) return 0;

    // Enclosing marks
    if (cp >= 0x20DD and cp <= 0x20E0) return 0;
    if (cp >= 0x20E2 and cp <= 0x20E4) return 0;

    // CJK Unified Ideographs
    if (cp >= 0x4E00 and cp <= 0x9FFF) return 2;
    // CJK Unified Ideographs Extension A
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2;
    // CJK Compatibility Ideographs
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
    // CJK Unified Ideographs Extension B-F
    if (cp >= 0x20000 and cp <= 0x2FA1F) return 2;

    // CJK Symbols and Punctuation, Hiragana, Katakana, etc.
    if (cp >= 0x2E80 and cp <= 0x30FF) return 2;
    // Katakana Phonetic Extensions
    if (cp >= 0x31F0 and cp <= 0x31FF) return 2;
    // Enclosed CJK Letters and Months
    if (cp >= 0x3200 and cp <= 0x32FF) return 2;
    // CJK Compatibility
    if (cp >= 0x3300 and cp <= 0x33FF) return 2;

    // Fullwidth forms
    if (cp >= 0xFF01 and cp <= 0xFF60) return 2;
    // Fullwidth Pound/Yen/Won
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;

    // Hangul Syllables
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2;
    // Hangul Jamo Extended
    if (cp >= 0x1100 and cp <= 0x115F) return 2;
    if (cp >= 0x2329 and cp <= 0x232A) return 2;

    // Basic emoji ranges (simplified — width 2)
    if (cp >= 0x1F300 and cp <= 0x1F9FF) return 2;
    if (cp >= 0x1FA00 and cp <= 0x1FA6F) return 2;
    if (cp >= 0x1FA70 and cp <= 0x1FAFF) return 2;

    return 1;
}

test "ASCII string width" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello"));
    try std.testing.expectEqual(@as(usize, 0), displayWidth(""));
}

test "CJK characters are width 2" {
    try std.testing.expectEqual(@as(usize, 6), displayWidth("日本語"));
    try std.testing.expectEqual(@as(usize, 6), displayWidth("ab日cd"));
}

test "ANSI escape sequences are width 0" {
    try std.testing.expectEqual(@as(usize, 4), displayWidth("\x1b[1mbold\x1b[0m"));
    try std.testing.expectEqual(@as(usize, 3), displayWidth("\x1b[38;2;255;0;0mred\x1b[0m"));
}

test "control characters are width 0" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("a\x00b"));
}

test "emoji is width 2" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("🚀"));
}

test "sliceToWidth basic" {
    try std.testing.expectEqualStrings("hel", sliceToWidth("hello", 3));
    try std.testing.expectEqualStrings("hello", sliceToWidth("hello", 10));
}

test "sliceToWidth respects CJK width" {
    // "日" is width 2, so max_width 3 only fits one CJK char
    try std.testing.expectEqualStrings("日", sliceToWidth("日本", 3));
}

test "sliceToWidth preserves ANSI" {
    const text = "\x1b[1mbold\x1b[0m";
    try std.testing.expectEqualStrings("\x1b[1mbol", sliceToWidth(text, 3));
}

test "mixed content width" {
    // "Hello日本" = 5 + 4 = 9
    try std.testing.expectEqual(@as(usize, 9), displayWidth("Hello日本"));
}

test "combining characters are width 0" {
    // e + combining acute accent (U+0301) → é, display width 1
    try std.testing.expectEqual(@as(usize, 1), displayWidth("e\xCC\x81"));
    // a + combining tilde (U+0303) → ã, display width 1
    try std.testing.expectEqual(@as(usize, 1), displayWidth("a\xCC\x83"));
}

test "variation selectors are width 0" {
    // ❤ (U+2764) + VS16 (U+FE0F) → ❤️
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\xE2\x9D\xA4\xEF\xB8\x8F"));
}

test "ZWJ emoji sequence counts as single emoji width" {
    // 👨 (U+1F468) + ZWJ (U+200D) + 👩 (U+1F469) = family pair
    // Should be width 2 (one emoji), not 4 (two emojis)
    try std.testing.expectEqual(@as(usize, 2), displayWidth("👨\xE2\x80\x8D👩"));
}

test "skin tone modifier is width 0" {
    // 👋 (U+1F44B) + skin tone (U+1F3FD) → 👋🏽
    // Should be width 2 (base emoji only)
    try std.testing.expectEqual(@as(usize, 2), displayWidth("👋🏽"));
}

test "zero width joiner alone is width 0" {
    try std.testing.expectEqual(@as(usize, 0), displayWidth("\xE2\x80\x8D"));
}

test "ZWSP and BOM are width 0" {
    // Zero Width Space (U+200B)
    try std.testing.expectEqual(@as(usize, 2), displayWidth("a\xE2\x80\x8Bb"));
    // BOM (U+FEFF)
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\xEF\xBB\xBFab"));
}

test "wrapText basic word wrap" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "Hello World", 8);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello\nWorld", result);
}

test "wrapText exact fit no wrap" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "Hello", 5);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "wrapText multiple words" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "A B C D E F", 5);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("A B C\nD E F", result);
}

test "wrapText hard break on long word" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "ABCDEFGHIJ", 5);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ABCDE\nFGHIJ", result);
}

test "wrapText preserves ANSI codes" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "\x1b[1mHello World\x1b[0m", 8);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[1mHello\nWorld\x1b[0m", result);
}

test "wrapText preserves existing newlines" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "Line one\nLine two", 20);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Line one\nLine two", result);
}

test "wrapText CJK characters" {
    const allocator = std.testing.allocator;
    // "日本語" = 6 display columns, max_width=5 means hard break after 2 chars (4 cols)
    const result = try wrapText(allocator, "日本語", 5);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("日本\n語", result);
}

test "wrapText zero width returns copy" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "Hello", 0);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "sliceToWidthAlloc appends reset when truncating styled text" {
    const allocator = std.testing.allocator;
    const text = "\x1b[1mbold text\x1b[0m";
    const result = try sliceToWidthAlloc(allocator, text, 4);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[1mbold\x1b[0m", result);
}

test "sliceToWidthAlloc no reset when not truncated" {
    const allocator = std.testing.allocator;
    const text = "\x1b[1mhi\x1b[0m";
    const result = try sliceToWidthAlloc(allocator, text, 10);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[1mhi\x1b[0m", result);
}

test "sliceToWidthAlloc no reset for plain text" {
    const allocator = std.testing.allocator;
    const result = try sliceToWidthAlloc(allocator, "hello world", 5);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "sliceToWidthAlloc with multiple styles" {
    const allocator = std.testing.allocator;
    const text = "\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m";
    // Truncate inside "italic" region
    const result = try sliceToWidthAlloc(allocator, text, 7);
    defer allocator.free(result);
    // "bold" (4) + " " (1) + "it" (2) = 7; italic style is open
    try std.testing.expectEqualStrings("\x1b[1mbold\x1b[0m \x1b[3mit\x1b[0m", result);
}
