const std = @import("std");

/// Calculate the display width of a UTF-8 string in terminal columns.
/// ASCII printable characters are width 1, CJK characters are width 2,
/// ANSI escape sequences are width 0, control characters are width 0.
///
/// Known non-goals: combining characters, variation selectors, and ZWJ
/// emoji sequences are not handled. Each codepoint is measured independently.
pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        // Skip ANSI escape sequences (CSI: ESC [ ... final_byte)
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and text[i] >= 0x20 and text[i] <= 0x3f) : (i += 1) {}
            if (i < text.len) i += 1; // skip final byte
            continue;
        }

        // Decode UTF-8 codepoint
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

        width += codepointWidth(cp);
    }
    return width;
}

/// Slice a string to fit within max_width display columns.
/// Preserves ANSI escape sequences and respects UTF-8 byte boundaries.
pub fn sliceToWidth(text: []const u8, max_width: usize) []const u8 {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        // Pass through ANSI escape sequences (zero width)
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and text[i] >= 0x20 and text[i] <= 0x3f) : (i += 1) {}
            if (i < text.len) i += 1;
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

fn codepointWidth(cp: u21) usize {
    // Control characters and zero-width
    if (cp < 0x20) return 0;
    if (cp == 0x7f) return 0;

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

    // Everything else is width 1
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
