const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("ansi.zig");

const ESC = 0x1b;

const SOFT_HYPHEN = 0x00AD;
const ZWSP = 0x200B;
const ZWNJ = 0x200C;
const ZWJ = 0x200D;
const WORD_JOINER = 0x2060;
const BOM = 0xFEFF;

/// Interpretation of Unicode East Asian Width "Ambiguous" (UAX #11 category A).
/// Most modern terminals (Ghostty default, Alacritty, WezTerm, iTerm2) treat
/// Ambiguous characters as 1 column wide. CJK-legacy terminal configurations
/// (Vim `set ambiwidth=double`, Apple Terminal east-asian-wide setting, classic
/// xterm-cjk) treat them as 2 columns. Callers pick the interpretation that
/// matches their target terminal.
pub const AmbiguousWidth = enum { narrow, wide };

const multibyte_charsets = [_][]const u8{
    "utf-8",   "utf8",
    "jis",     "eucjp",
    "euckr",   "euccn",
    "sjis",    "cp932",
    "cp51932", "cp936",
    "cp949",   "cp950",
    "big5",    "gbk",
    "gb2312",  "gb18030",
};

fn isMultibyteCharset(charset: []const u8) bool {
    for (multibyte_charsets) |name| {
        if (std.ascii.eqlIgnoreCase(charset, name)) return true;
    }
    return false;
}

const LocaleInfo = struct {
    language: []const u8,
    charset: ?[]const u8,
    modifier: ?[]const u8,
};

fn isCjkLanguage(language: []const u8) bool {
    return std.mem.eql(u8, language, "ja") or
        std.mem.eql(u8, language, "ko") or
        std.mem.eql(u8, language, "zh");
}

fn parseLocale(locale: []const u8) ?LocaleInfo {
    if (locale.len == 0) return null;

    var i: usize = 0;
    while (i < locale.len and std.ascii.isLower(locale[i])) : (i += 1) {}
    if (i < 2 or i > 3) return null;

    const language = locale[0..i];

    if (i < locale.len and locale[i] == '_') {
        if (i + 2 >= locale.len) return null;
        if (!std.ascii.isUpper(locale[i + 1]) or !std.ascii.isUpper(locale[i + 2])) return null;
        i += 3;
    }

    var charset: ?[]const u8 = null;
    if (i < locale.len and locale[i] == '.') {
        const start = i + 1;
        if (start >= locale.len) return null;
        i = start;
        while (i < locale.len and locale[i] != '@') : (i += 1) {}
        if (start == i) return null;
        charset = locale[start..i];
    }

    var modifier: ?[]const u8 = null;
    if (i < locale.len and locale[i] == '@') {
        const start = i + 1;
        if (start >= locale.len) return null;
        modifier = locale[start..];
        i = locale.len;
    }

    if (i != locale.len) return null;
    return .{
        .language = language,
        .charset = charset,
        .modifier = modifier,
    };
}

fn classifyWindowsCodePage(code_page: u32, wt_session_nonempty: bool) AmbiguousWidth {
    if (wt_session_nonempty) return .narrow;
    return switch (code_page) {
        932, 51932, 936, 949, 950 => .wide,
        else => .narrow,
    };
}

/// Heuristic East Asian width detection modeled after `mattn/go-runewidth`.
/// The parser is intentionally conservative: malformed locale strings fall back
/// to narrow instead of assuming CJK behavior.
pub fn classifyLocale(locale: []const u8) AmbiguousWidth {
    if (std.mem.eql(u8, locale, "C")) return .narrow;
    if (std.mem.eql(u8, locale, "POSIX")) return .narrow;
    if (locale.len > 1 and locale[0] == 'C' and
        (locale[1] == '.' or locale[1] == '-'))
    {
        return .narrow;
    }
    if (locale.len == 0) return .narrow;

    const parsed = parseLocale(locale) orelse return .narrow;
    if (parsed.modifier) |modifier| {
        if (std.ascii.eqlIgnoreCase(modifier, "cjk_narrow")) return .narrow;
    }

    const charset = parsed.charset orelse return .narrow;
    if (!isMultibyteCharset(charset)) return .narrow;

    if (std.ascii.toLower(charset[0]) != 'u') return .wide;

    if (isCjkLanguage(parsed.language)) {
        return .wide;
    }
    return .narrow;
}

pub fn detectAmbiguousWidth(env: anytype) AmbiguousWidth {
    if (env.get("RUNEWIDTH_EASTASIAN")) |v| {
        if (v.len > 0) {
            return if (std.mem.eql(u8, v, "1")) .wide else .narrow;
        }
    }

    const names = [_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" };
    for (names) |name| {
        if (env.get(name)) |v| {
            if (v.len == 0) continue;
            return classifyLocale(v);
        }
    }
    return .narrow;
}

pub fn detectAmbiguousFromProcess() AmbiguousWidth {
    if (builtin.os.tag == .windows) {
        if (std.process.hasNonEmptyEnvVarConstant("RUNEWIDTH_EASTASIAN")) {
            const env = std.process.getenvW(std.unicode.wtf8ToWtf16LeStringLiteral("RUNEWIDTH_EASTASIAN")) orelse unreachable;
            return if (env.len == 1 and env[0] == @as(u16, '1')) .wide else .narrow;
        }
        return classifyWindowsCodePage(
            std.os.windows.kernel32.GetConsoleOutputCP(),
            std.process.hasNonEmptyEnvVarConstant("WT_SESSION"),
        );
    }

    const process_env = struct {
        pub fn get(name: []const u8) ?[]const u8 {
            return std.posix.getenv(name);
        }
    };
    return detectAmbiguousWidth(process_env);
}

/// ANSI CSI parameter byte range (0x20–0x3f per ECMA-48 §5.4)
fn isCsiParamByte(byte: u8) bool {
    return byte >= 0x20 and byte <= 0x3f;
}

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
/// The `ambiguous` argument controls how East Asian Width Ambiguous
/// characters are sized — see `AmbiguousWidth`.
pub fn displayWidth(text: []const u8, ambiguous: AmbiguousWidth) usize {
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

        w += codepointWidth(cp, ambiguous);
    }
    return w;
}

/// Slice a string to fit within max_width display columns.
/// Preserves ANSI escape sequences and respects UTF-8 byte boundaries.
pub fn sliceToWidth(text: []const u8, max_width: usize, ambiguous: AmbiguousWidth) []const u8 {
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

        const cw = codepointWidth(cp, ambiguous);
        if (width + cw > max_width) break;
        width += cw;
        i += len;
    }
    return text[0..i];
}

/// Like sliceToWidth but returns an allocated slice that appends an ANSI reset
/// sequence (\x1b[0m) if the text was truncated inside an active ANSI style.
/// This prevents style leakage into subsequent terminal output.
pub fn sliceToWidthAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_width: usize,
    ambiguous: AmbiguousWidth,
) ![]u8 {
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

        const cw = codepointWidth(cp, ambiguous);
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
pub fn wrapText(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_width: usize,
    ambiguous: AmbiguousWidth,
) ![]u8 {
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

        const cw = codepointWidth(cp, ambiguous);

        if (col + cw > max_width) {
            if (text[i] == ' ') {
                try result.append(allocator, '\n');
                col = 0;
                last_space_result = null;
                i += len;
                continue;
            }
            if (last_space_result) |space_pos| {
                result.items[space_pos] = '\n';
                col -= col_after_last_space;
                last_space_result = null;
            } else {
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
    if (cp >= 0x2600 and cp <= 0x26FF) return true; // Miscellaneous Symbols
    if (cp >= 0x2700 and cp <= 0x27BF) return true; // Dingbats
    return false;
}

/// Returns true for code points that should render as 2 columns when
/// the caller selects `AmbiguousWidth.wide`.
///
/// The primary source is Unicode 15.1 `EastAsianWidth.txt` category
/// `A` (Ambiguous). That catches the UAX #11 formal set — Greek,
/// Cyrillic, box drawing, most Misc Symbols, and the Private Use
/// Area.
///
/// On top of the formal set, the function also returns true for a
/// small group of **project glyphs** that UAX #11 classifies as
/// Neutral (`N`) but that the renderer intentionally uses in list,
/// checkbox, and bullet positions. Neutral characters are always
/// width 1 per the strict standard, but CJK-legacy terminal modes
/// (Apple Terminal east-asian-wide, Vim `set ambiwidth=double` in
/// the CJK font families that ship these glyphs as double-wide)
/// display them as 2 columns. Without the override, opting into
/// wide ambiguous rendering would fix top-level `•` bullets and
/// `│` gutters but leave `◦` / `▪` / `☐` / `☑` misaligned, which
/// defeats the feature's stated user goal.
///
/// Project-glyph overrides (formally N, pragmatically widened):
/// - U+25AA ▪ BLACK SMALL SQUARE (depth-2 list bullet)
/// - U+25E6 ◦ WHITE BULLET (depth-1 list bullet)
/// - U+2610 ☐ BALLOT BOX (unchecked task checkbox)
/// - U+2611 ☑ BALLOT BOX WITH CHECK (checked task checkbox)
///
/// Earlier short-circuit rules in `codepointWidth` already handle
/// combining marks (U+0300..U+036F → 0), variation selectors
/// (U+FE00..U+FE0F, U+E0100..U+E01EF → 0), and CJK ranges
/// (U+3200..U+32FF, U+F900..U+FAFF → 2), so those ranges are
/// deliberately omitted from this check to keep the list focused
/// on code points that actually need mode-dependent behavior.
///
/// When bumping the target Unicode version, diff the new
/// `EastAsianWidth.txt` against the ranges below and add or remove
/// entries as needed. Historical evidence shows A-category changes
/// are rare (typically 0–5 codepoints per Unicode release), so a
/// full regeneration is not necessary. Keep the project-glyph
/// override section intact across bumps.
fn isEastAsianAmbiguous(cp: u21) bool {
    if (cp < 0x00A1) return false;

    // Latin-1 Supplement
    if (cp == 0x00A1) return true;
    if (cp == 0x00A4) return true;
    if (cp >= 0x00A7 and cp <= 0x00A8) return true;
    if (cp == 0x00AA) return true;
    if (cp >= 0x00AD and cp <= 0x00AE) return true;
    if (cp >= 0x00B0 and cp <= 0x00B4) return true;
    if (cp >= 0x00B6 and cp <= 0x00BA) return true;
    if (cp >= 0x00BC and cp <= 0x00BF) return true;
    if (cp == 0x00C6) return true;
    if (cp == 0x00D0) return true;
    if (cp >= 0x00D7 and cp <= 0x00D8) return true;
    if (cp >= 0x00DE and cp <= 0x00E1) return true;
    if (cp == 0x00E6) return true;
    if (cp >= 0x00E8 and cp <= 0x00EA) return true;
    if (cp >= 0x00EC and cp <= 0x00ED) return true;
    if (cp == 0x00F0) return true;
    if (cp >= 0x00F2 and cp <= 0x00F3) return true;
    if (cp >= 0x00F7 and cp <= 0x00FA) return true;
    if (cp == 0x00FC) return true;
    if (cp == 0x00FE) return true;

    // Latin Extended-A
    if (cp == 0x0101) return true;
    if (cp == 0x0111) return true;
    if (cp == 0x0113) return true;
    if (cp == 0x011B) return true;
    if (cp >= 0x0126 and cp <= 0x0127) return true;
    if (cp == 0x012B) return true;
    if (cp >= 0x0131 and cp <= 0x0133) return true;
    if (cp == 0x0138) return true;
    if (cp >= 0x013F and cp <= 0x0142) return true;
    if (cp == 0x0144) return true;
    if (cp >= 0x0148 and cp <= 0x014B) return true;
    if (cp == 0x014D) return true;
    if (cp >= 0x0152 and cp <= 0x0153) return true;
    if (cp >= 0x0166 and cp <= 0x0167) return true;
    if (cp == 0x016B) return true;

    // Latin Extended-B
    if (cp == 0x01CE) return true;
    if (cp == 0x01D0) return true;
    if (cp == 0x01D2) return true;
    if (cp == 0x01D4) return true;
    if (cp == 0x01D6) return true;
    if (cp == 0x01D8) return true;
    if (cp == 0x01DA) return true;
    if (cp == 0x01DC) return true;

    // IPA Extensions
    if (cp == 0x0251) return true;
    if (cp == 0x0261) return true;

    // Spacing Modifier Letters
    if (cp == 0x02C4) return true;
    if (cp == 0x02C7) return true;
    if (cp >= 0x02C9 and cp <= 0x02CB) return true;
    if (cp == 0x02CD) return true;
    if (cp == 0x02D0) return true;
    if (cp >= 0x02D8 and cp <= 0x02DB) return true;
    if (cp == 0x02DD) return true;
    if (cp == 0x02DF) return true;

    // Greek and Coptic
    if (cp >= 0x0391 and cp <= 0x03A1) return true;
    if (cp >= 0x03A3 and cp <= 0x03A9) return true;
    if (cp >= 0x03B1 and cp <= 0x03C1) return true;
    if (cp >= 0x03C3 and cp <= 0x03C9) return true;

    // Cyrillic
    if (cp == 0x0401) return true;
    if (cp >= 0x0410 and cp <= 0x044F) return true;
    if (cp == 0x0451) return true;

    if (cp < 0x2010) return false;

    // General Punctuation
    if (cp == 0x2010) return true;
    if (cp >= 0x2013 and cp <= 0x2016) return true;
    if (cp >= 0x2018 and cp <= 0x2019) return true;
    if (cp >= 0x201C and cp <= 0x201D) return true;
    if (cp >= 0x2020 and cp <= 0x2022) return true;
    if (cp >= 0x2024 and cp <= 0x2027) return true;
    if (cp == 0x2030) return true;
    if (cp >= 0x2032 and cp <= 0x2033) return true;
    if (cp == 0x2035) return true;
    if (cp == 0x203B) return true;
    if (cp == 0x203E) return true;

    // Superscripts and Subscripts
    if (cp == 0x2074) return true;
    if (cp == 0x207F) return true;
    if (cp >= 0x2081 and cp <= 0x2084) return true;

    // Currency Symbols
    if (cp == 0x20AC) return true;

    // Letterlike Symbols
    if (cp == 0x2103) return true;
    if (cp == 0x2105) return true;
    if (cp == 0x2109) return true;
    if (cp == 0x2113) return true;
    if (cp == 0x2116) return true;
    if (cp >= 0x2121 and cp <= 0x2122) return true;
    if (cp == 0x2126) return true;
    if (cp == 0x212B) return true;

    // Number Forms
    if (cp >= 0x2153 and cp <= 0x2154) return true;
    if (cp >= 0x215B and cp <= 0x215E) return true;
    if (cp >= 0x2160 and cp <= 0x216B) return true;
    if (cp >= 0x2170 and cp <= 0x2179) return true;
    if (cp == 0x2189) return true;

    // Arrows
    if (cp >= 0x2190 and cp <= 0x2199) return true;
    if (cp >= 0x21B8 and cp <= 0x21B9) return true;
    if (cp == 0x21D2) return true;
    if (cp == 0x21D4) return true;
    if (cp == 0x21E7) return true;

    // Mathematical Operators
    if (cp == 0x2200) return true;
    if (cp >= 0x2202 and cp <= 0x2203) return true;
    if (cp >= 0x2207 and cp <= 0x2208) return true;
    if (cp == 0x220B) return true;
    if (cp == 0x220F) return true;
    if (cp == 0x2211) return true;
    if (cp == 0x2215) return true;
    if (cp == 0x221A) return true;
    if (cp >= 0x221D and cp <= 0x2220) return true;
    if (cp == 0x2223) return true;
    if (cp == 0x2225) return true;
    if (cp >= 0x2227 and cp <= 0x222C) return true;
    if (cp == 0x222E) return true;
    if (cp >= 0x2234 and cp <= 0x2237) return true;
    if (cp >= 0x223C and cp <= 0x223D) return true;
    if (cp == 0x2248) return true;
    if (cp == 0x224C) return true;
    if (cp == 0x2252) return true;
    if (cp >= 0x2260 and cp <= 0x2261) return true;
    if (cp >= 0x2264 and cp <= 0x2267) return true;
    if (cp >= 0x226A and cp <= 0x226B) return true;
    if (cp >= 0x226E and cp <= 0x226F) return true;
    if (cp >= 0x2282 and cp <= 0x2283) return true;
    if (cp >= 0x2286 and cp <= 0x2287) return true;
    if (cp == 0x2295) return true;
    if (cp == 0x2299) return true;
    if (cp == 0x22A5) return true;
    if (cp == 0x22BF) return true;

    // Miscellaneous Technical
    if (cp == 0x2312) return true;

    // Enclosed Alphanumerics
    if (cp >= 0x2460 and cp <= 0x24E9) return true;
    if (cp >= 0x24EB and cp <= 0x254B) return true;

    // Box Drawing
    if (cp >= 0x2550 and cp <= 0x2573) return true;

    // Block Elements
    if (cp >= 0x2580 and cp <= 0x258F) return true;
    if (cp >= 0x2592 and cp <= 0x2595) return true;

    // Geometric Shapes
    if (cp >= 0x25A0 and cp <= 0x25A1) return true;
    if (cp >= 0x25A3 and cp <= 0x25A9) return true;
    if (cp == 0x25AA) return true; // project override: depth-2 list bullet
    if (cp >= 0x25B2 and cp <= 0x25B3) return true;
    if (cp >= 0x25B6 and cp <= 0x25B7) return true;
    if (cp >= 0x25BC and cp <= 0x25BD) return true;
    if (cp >= 0x25C0 and cp <= 0x25C1) return true;
    if (cp >= 0x25C6 and cp <= 0x25C8) return true;
    if (cp == 0x25CB) return true;
    if (cp >= 0x25CE and cp <= 0x25D1) return true;
    if (cp >= 0x25E2 and cp <= 0x25E5) return true;
    if (cp == 0x25E6) return true; // project override: depth-1 list bullet
    if (cp == 0x25EF) return true;

    // Miscellaneous Symbols
    if (cp >= 0x2605 and cp <= 0x2606) return true;
    if (cp == 0x2609) return true;
    if (cp >= 0x260E and cp <= 0x260F) return true;
    if (cp >= 0x2610 and cp <= 0x2611) return true; // project override: task checkboxes ☐ ☑
    if (cp == 0x261C) return true;
    if (cp == 0x261E) return true;
    if (cp == 0x2640) return true;
    if (cp == 0x2642) return true;
    if (cp >= 0x2660 and cp <= 0x2661) return true;
    if (cp >= 0x2663 and cp <= 0x2665) return true;
    if (cp >= 0x2667 and cp <= 0x266A) return true;
    if (cp >= 0x266C and cp <= 0x266D) return true;
    if (cp == 0x266F) return true;
    if (cp >= 0x269E and cp <= 0x269F) return true;
    if (cp == 0x26BF) return true;
    if (cp >= 0x26C6 and cp <= 0x26CD) return true;
    if (cp >= 0x26CF and cp <= 0x26D3) return true;
    if (cp >= 0x26D5 and cp <= 0x26E1) return true;
    if (cp == 0x26E3) return true;
    if (cp >= 0x26E8 and cp <= 0x26E9) return true;
    if (cp >= 0x26EB and cp <= 0x26F1) return true;
    if (cp == 0x26F4) return true;
    if (cp >= 0x26F6 and cp <= 0x26F9) return true;
    if (cp >= 0x26FB and cp <= 0x26FC) return true;
    if (cp >= 0x26FE and cp <= 0x26FF) return true;

    // Dingbats
    if (cp == 0x273D) return true;
    if (cp >= 0x2776 and cp <= 0x277F) return true;

    // Miscellaneous Symbols and Arrows
    if (cp >= 0x2B56 and cp <= 0x2B59) return true;

    // Private Use Area
    if (cp >= 0xE000 and cp <= 0xF8FF) return true;

    // Specials
    if (cp == 0xFFFD) return true;

    // Enclosed Alphanumeric Supplement (subset flagged A)
    if (cp >= 0x1F100 and cp <= 0x1F10A) return true;
    if (cp >= 0x1F110 and cp <= 0x1F12D) return true;
    if (cp >= 0x1F130 and cp <= 0x1F169) return true;
    if (cp >= 0x1F170 and cp <= 0x1F18D) return true;
    if (cp >= 0x1F18F and cp <= 0x1F190) return true;
    if (cp >= 0x1F19B and cp <= 0x1F1AC) return true;

    // Supplementary Private Use Area-A and Area-B
    if (cp >= 0xF0000 and cp <= 0xFFFFD) return true;
    if (cp >= 0x100000 and cp <= 0x10FFFD) return true;

    return false;
}

fn codepointWidth(cp: u21, ambiguous: AmbiguousWidth) usize {
    if (cp < 0x20) return 0;
    if (cp == 0x7f) return 0;

    switch (cp) {
        ZWSP, ZWNJ, ZWJ, WORD_JOINER, BOM, SOFT_HYPHEN => return 0,
        else => {},
    }

    // Variation Selectors
    if (cp >= 0xFE00 and cp <= 0xFE0F) return 0;
    if (cp >= 0xE0100 and cp <= 0xE01EF) return 0;

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

    // CJK Symbols and Punctuation, Hiragana, and Katakana
    if (cp >= 0x2E80 and cp <= 0x30FF) return 2;
    // Katakana Phonetic Extensions
    if (cp >= 0x31F0 and cp <= 0x31FF) return 2;
    // Enclosed CJK Letters and Months
    if (cp >= 0x3200 and cp <= 0x32FF) return 2;
    // CJK Compatibility
    if (cp >= 0x3300 and cp <= 0x33FF) return 2;

    // Fullwidth Forms
    if (cp >= 0xFF01 and cp <= 0xFF60) return 2;
    // Fullwidth currency and punctuation variants
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;

    // Hangul Syllables
    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2;
    // Hangul Jamo
    if (cp >= 0x1100 and cp <= 0x115F) return 2;
    if (cp >= 0x2329 and cp <= 0x232A) return 2;

    // Emoji ranges treated as double-width
    if (cp >= 0x1F300 and cp <= 0x1F9FF) return 2;
    if (cp >= 0x1FA00 and cp <= 0x1FA6F) return 2;
    if (cp >= 0x1FA70 and cp <= 0x1FAFF) return 2;

    // East Asian Width Ambiguous; interpretation depends on terminal mode.
    if (isEastAsianAmbiguous(cp)) {
        return if (ambiguous == .wide) 2 else 1;
    }

    return 1;
}

test "ASCII string width" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello", .narrow));
    try std.testing.expectEqual(@as(usize, 0), displayWidth("", .narrow));
}

test "CJK characters are width 2" {
    try std.testing.expectEqual(@as(usize, 6), displayWidth("日本語", .narrow));
    try std.testing.expectEqual(@as(usize, 6), displayWidth("ab日cd", .narrow));
}

test "ANSI escape sequences are width 0" {
    try std.testing.expectEqual(@as(usize, 4), displayWidth("\x1b[1mbold\x1b[0m", .narrow));
    try std.testing.expectEqual(@as(usize, 3), displayWidth("\x1b[38;2;255;0;0mred\x1b[0m", .narrow));
}

test "control characters are width 0" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("a\x00b", .narrow));
}

test "emoji is width 2" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("🚀", .narrow));
}

test "sliceToWidth basic" {
    try std.testing.expectEqualStrings("hel", sliceToWidth("hello", 3, .narrow));
    try std.testing.expectEqualStrings("hello", sliceToWidth("hello", 10, .narrow));
}

test "sliceToWidth respects CJK width" {
    try std.testing.expectEqualStrings("日", sliceToWidth("日本", 3, .narrow));
}

test "sliceToWidth preserves ANSI" {
    const text = "\x1b[1mbold\x1b[0m";
    try std.testing.expectEqualStrings("\x1b[1mbol", sliceToWidth(text, 3, .narrow));
}

test "mixed content width" {
    try std.testing.expectEqual(@as(usize, 9), displayWidth("Hello日本", .narrow));
}

test "combining characters are width 0" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("e\u{0301}", .narrow));
    try std.testing.expectEqual(@as(usize, 1), displayWidth("a\u{0303}", .narrow));
}

test "variation selectors are width 0" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\u{2764}\u{FE0F}", .narrow));
}

test "ZWJ emoji sequence counts as single emoji width" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1F468}\u{200D}\u{1F469}", .narrow));
}

test "skin tone modifier is width 0" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{1F44B}\u{1F3FD}", .narrow));
}

test "zero width joiner alone is width 0" {
    try std.testing.expectEqual(@as(usize, 0), displayWidth("\xE2\x80\x8D", .narrow));
}

test "ZWSP and BOM are width 0" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("a\u{200B}b", .narrow));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{FEFF}ab", .narrow));
}

test "wrapText basic word wrap" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "Hello World", 8, .narrow);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello\nWorld", result);
}

test "wrapText exact fit no wrap" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "Hello", 5, .narrow);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "wrapText multiple words" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "A B C D E F", 5, .narrow);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("A B C\nD E F", result);
}

test "wrapText hard break on long word" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "ABCDEFGHIJ", 5, .narrow);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("ABCDE\nFGHIJ", result);
}

test "wrapText preserves ANSI codes" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "\x1b[1mHello World\x1b[0m", 8, .narrow);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[1mHello\nWorld\x1b[0m", result);
}

test "wrapText preserves existing newlines" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "Line one\nLine two", 20, .narrow);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Line one\nLine two", result);
}

test "wrapText CJK characters" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "日本語", 5, .narrow);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("日本\n語", result);
}

test "wrapText zero width returns copy" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "Hello", 0, .narrow);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Hello", result);
}

test "sliceToWidthAlloc appends reset when truncating styled text" {
    const allocator = std.testing.allocator;
    const text = "\x1b[1mbold text\x1b[0m";
    const result = try sliceToWidthAlloc(allocator, text, 4, .narrow);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[1mbold\x1b[0m", result);
}

test "sliceToWidthAlloc no reset when not truncated" {
    const allocator = std.testing.allocator;
    const text = "\x1b[1mhi\x1b[0m";
    const result = try sliceToWidthAlloc(allocator, text, 10, .narrow);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[1mhi\x1b[0m", result);
}

test "sliceToWidthAlloc no reset for plain text" {
    const allocator = std.testing.allocator;
    const result = try sliceToWidthAlloc(allocator, "hello world", 5, .narrow);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "sliceToWidthAlloc with multiple styles" {
    const allocator = std.testing.allocator;
    const text = "\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m";
    const result = try sliceToWidthAlloc(allocator, text, 7, .narrow);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("\x1b[1mbold\x1b[0m \x1b[3mit\x1b[0m", result);
}

test "Ambiguous bullet is narrow 1 or wide 2" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("•", .narrow));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("•", .wide));
}

test "Ambiguous box drawing vertical is narrow 1 or wide 2" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("│", .narrow));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("│", .wide));
}

test "Ambiguous ballot box with check is narrow 1 or wide 2" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("☑", .narrow));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("☑", .wide));
}

test "Ambiguous bullet prefix composes in wide mode" {
    try std.testing.expectEqual(@as(usize, 6), displayWidth("• abc", .wide));
}

test "CJK Wide is unaffected by Ambiguous mode" {
    try std.testing.expectEqual(@as(usize, 6), displayWidth("日本語", .narrow));
    try std.testing.expectEqual(@as(usize, 6), displayWidth("日本語", .wide));
}

test "ASCII is unaffected by Ambiguous mode" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello", .narrow));
    try std.testing.expectEqual(@as(usize, 5), displayWidth("hello", .wide));
}

test "☂ (U+2602) is Neutral and unaffected by Ambiguous mode" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("☂", .narrow));
    try std.testing.expectEqual(@as(usize, 1), displayWidth("☂", .wide));
}

test "🚀 (U+1F680) stays width 2 in both Ambiguous modes" {
    try std.testing.expectEqual(@as(usize, 2), displayWidth("🚀", .narrow));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("🚀", .wide));
}

test "sliceToWidth truncates at wide Ambiguous width" {
    try std.testing.expectEqualStrings("••", sliceToWidth("•••", 4, .wide));
}

test "wrapText respects wide Ambiguous width" {
    const allocator = std.testing.allocator;
    const result = try wrapText(allocator, "• a • b", 4, .wide);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("• a\n• b", result);
}

test "Greek capital letters follow Ambiguous rule" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("Ω", .narrow));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("Ω", .wide));
    try std.testing.expectEqual(@as(usize, 1), displayWidth("α", .narrow));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("α", .wide));
}

test "Cyrillic letters follow Ambiguous rule" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("Ж", .narrow));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("Ж", .wide));
    try std.testing.expectEqual(@as(usize, 1), displayWidth("я", .narrow));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("я", .wide));
    try std.testing.expectEqual(@as(usize, 1), displayWidth("ё", .narrow));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("ё", .wide));
}

test "ASCII Latin letters are Neutral and unaffected by Ambiguous mode" {
    try std.testing.expectEqual(@as(usize, 5), displayWidth("Hello", .narrow));
    try std.testing.expectEqual(@as(usize, 5), displayWidth("Hello", .wide));
}

test "Latin Extended non-Ambiguous codepoints stay Neutral in wide mode" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("Ā", .narrow));
    try std.testing.expectEqual(@as(usize, 1), displayWidth("Ā", .wide));
}

test "Private Use Area is Ambiguous" {
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\u{E000}", .narrow));
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\u{E000}", .wide));
}

test "wrapText with Greek text wraps at wide-mode width" {
    const allocator = std.testing.allocator;
    const narrow_result = try wrapText(allocator, "ΑΒΓ", 4, .narrow);
    defer allocator.free(narrow_result);
    try std.testing.expectEqualStrings("ΑΒΓ", narrow_result);

    const wide_result = try wrapText(allocator, "ΑΒΓ", 4, .wide);
    defer allocator.free(wide_result);
    try std.testing.expectEqualStrings("ΑΒ\nΓ", wide_result);
}

test "classifyLocale wide for ja/ko/zh UTF-8 locales" {
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyLocale("ja_JP.UTF-8"));
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyLocale("ja_JP.utf8"));
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyLocale("ko_KR.UTF-8"));
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyLocale("zh_CN.UTF-8"));
}

test "classifyLocale wide for CJK non-UTF multi-byte charsets" {
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyLocale("ja_JP.eucJP"));
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyLocale("ko_KR.eucKR"));
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyLocale("zh_CN.GB2312"));
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyLocale("zh_CN.GB18030"));
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyLocale("zh_TW.Big5"));
}

test "classifyLocale wide for non-CJK locale with multi-byte non-UTF charset" {
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyLocale("en_US.eucJP"));
}

test "classifyLocale narrow for big5hkscs charset not in mblenTable" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("zh_HK.Big5HKSCS"));
}

test "classifyLocale narrow for non-CJK UTF-8 locales" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("en_US.UTF-8"));
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("fr_FR.UTF-8"));
}

test "classifyLocale narrow for single-byte charset" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("en_US.ISO8859-1"));
}

test "classifyLocale narrow for C and POSIX family" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("C"));
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("POSIX"));
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("C.UTF-8"));
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("C-UTF8"));
}

test "classifyLocale @cjk_narrow suffix overrides to narrow" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("ja_JP.UTF-8@cjk_narrow"));
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("ja_JP@cjk_narrow"));
}

test "classifyLocale narrow for locale without charset" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("ja_JP"));
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("ja"));
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("ja_JP@cjk"));
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("fr_FR@euro"));
}

test "classifyLocale narrow for empty string" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale(""));
}

test "classifyLocale narrow for malformed locale: single uppercase after underscore" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("ja_A.UTF-8"));
}

test "classifyLocale narrow for malformed locale: three uppercase after underscore" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("ja_JPN.UTF-8"));
}

test "classifyLocale narrow for malformed locale: lowercase region" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("ja_jp.UTF-8"));
}

test "classifyLocale narrow for malformed locale: four lowercase letters before dot" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("abcd.UTF-8"));
}

test "classifyLocale narrow for uppercase leading letters" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("JA_JP.UTF-8"));
}

test "classifyLocale narrow for two-letter non-CJK with charset" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("ab.UTF-8"));
}

test "classifyLocale wide for three-letter lowercase with non-UTF charset" {
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyLocale("abc.eucjp"));
}

test "classifyLocale narrow for three-letter UTF-8 locale sharing a CJK prefix" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("jan.UTF-8"));
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale("kok.UTF-8"));
}

test "classifyLocale narrow for malformed long locale with @cjk_narrow suffix" {
    const locale = "ja_JP.UTF-8" ++ ("x" ** 80) ++ "@cjk_narrow";
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale(locale));
}

test "classifyLocale narrow for malformed long non-UTF locale with @cjk_narrow suffix" {
    const locale = "en_US.eucJP" ++ ("y" ** 80) ++ "@cjk_narrow";
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale(locale));
}

test "classifyLocale narrow for long non-CJK locale" {
    const locale = "en_US.UTF-8" ++ ("z" ** 100);
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyLocale(locale));
}

fn StubEnv(comptime pairs: anytype) type {
    return struct {
        pub fn get(name: []const u8) ?[]const u8 {
            inline for (pairs) |pair| {
                if (std.mem.eql(u8, name, pair[0])) return pair[1];
            }
            return null;
        }
    };
}

test "detectAmbiguousWidth RUNEWIDTH_EASTASIAN=1 forces wide" {
    const env = StubEnv(.{
        .{ "RUNEWIDTH_EASTASIAN", "1" },
    });
    try std.testing.expectEqual(AmbiguousWidth.wide, detectAmbiguousWidth(env));
}

test "detectAmbiguousWidth RUNEWIDTH_EASTASIAN=0 forces narrow" {
    const env = StubEnv(.{
        .{ "RUNEWIDTH_EASTASIAN", "0" },
    });
    try std.testing.expectEqual(AmbiguousWidth.narrow, detectAmbiguousWidth(env));
}

test "detectAmbiguousWidth RUNEWIDTH_EASTASIAN=true forces narrow" {
    const env = StubEnv(.{
        .{ "RUNEWIDTH_EASTASIAN", "true" },
    });
    try std.testing.expectEqual(AmbiguousWidth.narrow, detectAmbiguousWidth(env));
}

test "detectAmbiguousWidth empty RUNEWIDTH_EASTASIAN falls through to locale" {
    const env = StubEnv(.{
        .{ "RUNEWIDTH_EASTASIAN", "" },
        .{ "LANG", "ja_JP.UTF-8" },
    });
    try std.testing.expectEqual(AmbiguousWidth.wide, detectAmbiguousWidth(env));
}

test "detectAmbiguousWidth override beats CJK locale" {
    const env = StubEnv(.{
        .{ "RUNEWIDTH_EASTASIAN", "0" },
        .{ "LANG", "ja_JP.UTF-8" },
    });
    try std.testing.expectEqual(AmbiguousWidth.narrow, detectAmbiguousWidth(env));
}

test "detectAmbiguousWidth override forces wide on narrow locale" {
    const env = StubEnv(.{
        .{ "RUNEWIDTH_EASTASIAN", "1" },
        .{ "LANG", "en_US.UTF-8" },
    });
    try std.testing.expectEqual(AmbiguousWidth.wide, detectAmbiguousWidth(env));
}

test "detectAmbiguousWidth LC_ALL alone triggers wide" {
    const env = StubEnv(.{
        .{ "LC_ALL", "ja_JP.UTF-8" },
    });
    try std.testing.expectEqual(AmbiguousWidth.wide, detectAmbiguousWidth(env));
}

test "detectAmbiguousWidth empty LC_ALL skipped to LC_CTYPE" {
    const env = StubEnv(.{
        .{ "LC_ALL", "" },
        .{ "LC_CTYPE", "ja_JP.UTF-8" },
    });
    try std.testing.expectEqual(AmbiguousWidth.wide, detectAmbiguousWidth(env));
}

test "detectAmbiguousWidth empty LC_ALL and LC_CTYPE skipped to LANG" {
    const env = StubEnv(.{
        .{ "LC_ALL", "" },
        .{ "LC_CTYPE", "" },
        .{ "LANG", "ja_JP.UTF-8" },
    });
    try std.testing.expectEqual(AmbiguousWidth.wide, detectAmbiguousWidth(env));
}

test "detectAmbiguousWidth LANG en_US narrow" {
    const env = StubEnv(.{
        .{ "LANG", "en_US.UTF-8" },
    });
    try std.testing.expectEqual(AmbiguousWidth.narrow, detectAmbiguousWidth(env));
}

test "detectAmbiguousWidth no env vars narrow" {
    const env = StubEnv(.{});
    try std.testing.expectEqual(AmbiguousWidth.narrow, detectAmbiguousWidth(env));
}

test "detectAmbiguousWidth LC_ALL beats LC_CTYPE and LANG" {
    const env = StubEnv(.{
        .{ "LC_ALL", "en_US.UTF-8" },
        .{ "LC_CTYPE", "ja_JP.UTF-8" },
        .{ "LANG", "ja_JP.UTF-8" },
    });
    try std.testing.expectEqual(AmbiguousWidth.narrow, detectAmbiguousWidth(env));
}

test "classifyWindowsCodePage wide for classic CJK code pages" {
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyWindowsCodePage(932, false));
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyWindowsCodePage(51932, false));
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyWindowsCodePage(936, false));
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyWindowsCodePage(949, false));
    try std.testing.expectEqual(AmbiguousWidth.wide, classifyWindowsCodePage(950, false));
}

test "classifyWindowsCodePage WT_SESSION forces narrow" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyWindowsCodePage(932, true));
}

test "classifyWindowsCodePage narrow for UTF-8 and unknown code pages" {
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyWindowsCodePage(65001, false));
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyWindowsCodePage(0, false));
    try std.testing.expectEqual(AmbiguousWidth.narrow, classifyWindowsCodePage(1252, false));
}
