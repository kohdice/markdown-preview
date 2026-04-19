const std = @import("std");
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

fn isCompleteCsi(text: []const u8, start: usize) bool {
    if (start + 1 >= text.len) return false;
    if (text[start] != ESC or text[start + 1] != '[') return false;
    var i = start + 2;
    while (i < text.len and isCsiParamByte(text[i])) : (i += 1) {}
    return i < text.len;
}

fn isAsciiPrintable(text: []const u8) bool {
    for (text) |byte| {
        if (byte < 0x20 or byte > 0x7e) return false;
    }
    return true;
}

/// ASCII printable characters are width 1, CJK characters are width 2,
/// ANSI escape sequences are width 0, control characters are width 0.
/// Combining characters and variation selectors are width 0.
/// ZWJ emoji sequences (e.g., family emoji) are counted as a single
/// width-2 unit instead of summing each component.
/// The `ambiguous` argument controls how East Asian Width Ambiguous
/// characters are sized — see `AmbiguousWidth`.
pub fn displayWidth(text: []const u8, ambiguous: AmbiguousWidth) usize {
    if (isAsciiPrintable(text)) return text.len;

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

fn sliceToWidth(text: []const u8, max_width: usize, ambiguous: AmbiguousWidth) []const u8 {
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

fn sliceToWidthAlloc(
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

fn wrapText(
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

pub const WrapWriter = struct {
    parent: *std.io.Writer,
    line_buf: *std.ArrayListUnmanaged(u8),
    col: usize,
    last_space_buf: ?usize,
    col_after_last_space: usize,
    max_width: usize,
    ambiguous: AmbiguousWidth,
    allocator: std.mem.Allocator,
    suppress_next_emoji: bool,
    pending: [24]u8,
    pending_len: u5,
    writer_buf: [writer_buffer_size]u8,
    writer: std.io.Writer,

    const writer_buffer_size = 512;

    pub fn init(
        self: *WrapWriter,
        parent: *std.io.Writer,
        max_width: usize,
        ambiguous: AmbiguousWidth,
        allocator: std.mem.Allocator,
        line_buf: *std.ArrayListUnmanaged(u8),
    ) void {
        line_buf.clearRetainingCapacity();
        self.* = .{
            .parent = parent,
            .line_buf = line_buf,
            .col = 0,
            .last_space_buf = null,
            .col_after_last_space = 0,
            .max_width = max_width,
            .ambiguous = ambiguous,
            .allocator = allocator,
            .suppress_next_emoji = false,
            .pending = undefined,
            .pending_len = 0,
            .writer_buf = undefined,
            .writer = .{
                .buffer = &self.writer_buf,
                .vtable = &wrap_vtable,
            },
        };
    }

    pub fn reset(
        self: *WrapWriter,
        parent: *std.io.Writer,
        max_width: usize,
    ) void {
        self.parent = parent;
        self.max_width = max_width;
        self.col = 0;
        self.last_space_buf = null;
        self.col_after_last_space = 0;
        self.suppress_next_emoji = false;
        self.pending_len = 0;
        self.line_buf.clearRetainingCapacity();
        self.writer.end = 0;
    }

    pub fn deinit(self: *WrapWriter) void {
        _ = self;
    }

    pub fn finish(self: *WrapWriter) std.io.Writer.Error!void {
        try self.writer.flush();
        if (self.pending_len > 0) {
            if (self.pending[0] == ESC) {
                self.line_buf.appendSlice(self.allocator, self.pending[0..self.pending_len]) catch
                    return error.WriteFailed;
            }
            self.pending_len = 0;
        }
        if (self.line_buf.items.len > 0) {
            try self.parent.writeAll(self.line_buf.items);
            self.line_buf.clearRetainingCapacity();
        }
    }

    const wrap_vtable: std.io.Writer.VTable = .{
        .drain = wrapDrain,
        .flush = wrapFlush,
        .rebase = std.io.Writer.failingRebase,
    };

    fn wrapFlush(w: *std.io.Writer) std.io.Writer.Error!void {
        const self: *WrapWriter = @fieldParentPtr("writer", w);
        const buffered = w.buffered();
        if (buffered.len > 0) {
            self.processBytes(buffered) catch return error.WriteFailed;
            w.end = 0;
        }
        if (self.line_buf.items.len > 0) {
            try self.parent.writeAll(self.line_buf.items);
            self.line_buf.clearRetainingCapacity();
        }
        self.last_space_buf = null;
    }

    fn wrapDrain(w: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
        const self: *WrapWriter = @fieldParentPtr("writer", w);

        const buffered = w.buffered();
        if (buffered.len > 0) {
            self.processBytes(buffered) catch return error.WriteFailed;
            w.end = 0;
        }

        var total: usize = 0;
        for (data, 0..) |slice, idx| {
            const repeat: usize = if (idx == data.len - 1) splat else 1;
            for (0..repeat) |_| {
                self.processBytes(slice) catch return error.WriteFailed;
                total += slice.len;
            }
        }

        return total;
    }

    fn processBytes(self: *WrapWriter, bytes: []const u8) !void {
        if (self.max_width == 0) {
            try self.line_buf.appendSlice(self.allocator, bytes);
            return;
        }

        if (self.pending_len > 0) {
            const consumed = try self.drainPending(bytes);
            if (consumed >= bytes.len) return;
            return self.processBytes(bytes[consumed..]);
        }

        var i: usize = 0;

        while (i < bytes.len) {
            if (bytes[i] == ESC) {
                if (isCompleteCsi(bytes, i)) {
                    const after = skipAnsiCsi(bytes, i).?;
                    try self.line_buf.appendSlice(self.allocator, bytes[i..after]);
                    i = after;
                    continue;
                }
                if (i + 1 >= bytes.len) {
                    self.pending[0] = ESC;
                    self.pending_len = 1;
                    break;
                }
                if (bytes[i + 1] == '[') {
                    const remaining = bytes.len - i;
                    if (remaining <= self.pending.len) {
                        @memcpy(self.pending[0..remaining], bytes[i..]);
                        self.pending_len = @intCast(remaining);
                    } else {
                        try self.line_buf.appendSlice(self.allocator, bytes[i..][0..1]);
                        i += 1;
                        continue;
                    }
                    break;
                }
            }

            if (bytes[i] == '\n') {
                try self.flushLine();
                try self.parent.writeByte('\n');
                self.col = 0;
                self.last_space_buf = null;
                self.suppress_next_emoji = false;
                i += 1;
                continue;
            }

            const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
                try self.appendCharAdvance(bytes[i..][0..1], 1);
                i += 1;
                continue;
            };
            if (i + len > bytes.len) {
                const remaining: u5 = @intCast(bytes.len - i);
                @memcpy(self.pending[0..remaining], bytes[i..]);
                self.pending_len = remaining;
                break;
            }

            const cp = std.unicode.utf8Decode(bytes[i..][0..len]) catch {
                try self.appendCharAdvance(bytes[i..][0..1], 1);
                i += 1;
                continue;
            };

            if (self.suppress_next_emoji) {
                self.suppress_next_emoji = false;
                if (isEmoji(cp)) {
                    try self.line_buf.appendSlice(self.allocator, bytes[i..][0..len]);
                    i += len;
                    continue;
                }
            }

            if (cp == ZWJ) {
                self.suppress_next_emoji = true;
                try self.line_buf.appendSlice(self.allocator, bytes[i..][0..len]);
                i += len;
                continue;
            }

            const cw = codepointWidth(cp, self.ambiguous);

            if (self.col + cw > self.max_width) {
                if (bytes[i] == ' ') {
                    try self.line_buf.append(self.allocator, '\n');
                    try self.flushLine();
                    self.col = 0;
                    self.last_space_buf = null;
                    i += len;
                    continue;
                }
                if (self.last_space_buf) |space_pos| {
                    self.line_buf.items[space_pos] = '\n';
                    self.col -= self.col_after_last_space;
                    self.last_space_buf = null;
                    try self.flushUpToLastNewline();
                } else {
                    try self.line_buf.append(self.allocator, '\n');
                    try self.flushLine();
                    self.col = 0;
                }
            }

            if (bytes[i] == ' ') {
                self.last_space_buf = self.line_buf.items.len;
                try self.line_buf.appendSlice(self.allocator, bytes[i..][0..len]);
                self.col += cw;
                self.col_after_last_space = self.col;
                i += len;
                continue;
            }

            try self.line_buf.appendSlice(self.allocator, bytes[i..][0..len]);
            self.col += cw;
            i += len;
        }
    }

    fn drainPending(self: *WrapWriter, bytes: []const u8) !usize {
        if (self.pending[0] == ESC) return self.drainPendingAnsi(bytes);
        return self.drainPendingUtf8(bytes);
    }

    fn drainPendingUtf8(self: *WrapWriter, bytes: []const u8) !usize {
        const p: usize = self.pending_len;
        const first_byte = self.pending[0];
        const seq_len: usize = std.unicode.utf8ByteSequenceLength(first_byte) catch {
            try self.appendCharAdvance(self.pending[0..1], 1);
            const leftover = p - 1;
            if (leftover > 0) {
                std.mem.copyForwards(u8, self.pending[0..leftover], self.pending[1..p]);
                self.pending_len = @intCast(leftover);
            } else {
                self.pending_len = 0;
            }
            return 0;
        };

        const still_needed = seq_len - p;
        if (still_needed > bytes.len) {
            @memcpy(self.pending[p .. p + bytes.len], bytes);
            self.pending_len = @intCast(p + bytes.len);
            return bytes.len;
        }

        @memcpy(self.pending[p .. p + still_needed], bytes[0..still_needed]);

        const char_bytes = self.pending[0..seq_len];
        const cp = std.unicode.utf8Decode(char_bytes) catch {
            try self.appendCharAdvance(self.pending[0..1], 1);
            const leftover = seq_len - 1;
            if (leftover > 0) {
                std.mem.copyForwards(u8, self.pending[0..leftover], self.pending[1..seq_len]);
                self.pending_len = @intCast(leftover);
            } else {
                self.pending_len = 0;
            }
            return still_needed;
        };
        self.pending_len = 0;

        if (self.suppress_next_emoji) {
            self.suppress_next_emoji = false;
            if (isEmoji(cp)) {
                try self.line_buf.appendSlice(self.allocator, char_bytes);
                return still_needed;
            }
        }

        if (cp == ZWJ) {
            self.suppress_next_emoji = true;
            try self.line_buf.appendSlice(self.allocator, char_bytes);
            return still_needed;
        }

        const cw = codepointWidth(cp, self.ambiguous);
        if (char_bytes[0] == ' ') {
            if (self.col + cw > self.max_width) {
                try self.line_buf.append(self.allocator, '\n');
                try self.flushLine();
                self.col = 0;
                self.last_space_buf = null;
                return still_needed;
            }
            self.last_space_buf = self.line_buf.items.len;
            try self.line_buf.appendSlice(self.allocator, char_bytes);
            self.col += cw;
            self.col_after_last_space = self.col;
            return still_needed;
        }

        try self.appendCharAdvance(char_bytes, cw);
        return still_needed;
    }

    fn drainPendingAnsi(self: *WrapWriter, bytes: []const u8) !usize {
        const p: usize = self.pending_len;
        const extra = @min(bytes.len, self.pending.len - p);
        @memcpy(self.pending[p .. p + extra], bytes[0..extra]);
        const combined_len = p + extra;

        if (combined_len < 2) {
            self.pending_len = @intCast(combined_len);
            return extra;
        }

        if (self.pending[1] != '[') {
            try self.line_buf.appendSlice(self.allocator, self.pending[0..1]);
            const leftover = p - 1;
            if (leftover > 0) {
                std.mem.copyForwards(u8, self.pending[0..leftover], self.pending[1..p]);
                self.pending_len = @intCast(leftover);
            } else {
                self.pending_len = 0;
            }
            return 0;
        }

        if (isCompleteCsi(self.pending[0..combined_len], 0)) {
            const after = skipAnsiCsi(self.pending[0..combined_len], 0).?;
            try self.line_buf.appendSlice(self.allocator, self.pending[0..after]);
            self.pending_len = 0;
            return if (after > p) after - p else 0;
        }

        if (combined_len >= self.pending.len) {
            try self.line_buf.appendSlice(self.allocator, self.pending[0..p]);
            self.pending_len = 0;
            return 0;
        }

        self.pending_len = @intCast(combined_len);
        return extra;
    }

    fn appendCharAdvance(self: *WrapWriter, char_bytes: []const u8, cw: usize) !void {
        if (self.col + cw > self.max_width) {
            if (self.last_space_buf) |space_pos| {
                self.line_buf.items[space_pos] = '\n';
                self.col -= self.col_after_last_space;
                self.last_space_buf = null;
                try self.flushUpToLastNewline();
            } else {
                try self.line_buf.append(self.allocator, '\n');
                try self.flushLine();
                self.col = 0;
            }
        }
        try self.line_buf.appendSlice(self.allocator, char_bytes);
        self.col += cw;
    }

    fn flushLine(self: *WrapWriter) !void {
        if (self.line_buf.items.len > 0) {
            try self.parent.writeAll(self.line_buf.items);
            self.line_buf.clearRetainingCapacity();
        }
    }

    fn flushUpToLastNewline(self: *WrapWriter) !void {
        const items = self.line_buf.items;
        var nl_pos: ?usize = null;
        var j: usize = items.len;
        while (j > 0) {
            j -= 1;
            if (items[j] == '\n') {
                nl_pos = j;
                break;
            }
        }

        if (nl_pos) |pos| {
            try self.parent.writeAll(items[0 .. pos + 1]);
            const remaining = items.len - (pos + 1);
            if (remaining > 0) {
                std.mem.copyForwards(u8, items[0..remaining], items[pos + 1 ..]);
            }
            self.line_buf.shrinkRetainingCapacity(remaining);
        }
    }
};

fn isEmoji(cp: u21) bool {
    if (cp >= 0x1F300 and cp <= 0x1F9FF) return true;
    if (cp >= 0x1FA00 and cp <= 0x1FAFF) return true;
    if (cp >= 0x2600 and cp <= 0x26FF) return true;
    if (cp >= 0x2700 and cp <= 0x27BF) return true;
    return false;
}

const eaw_ambiguous_ranges = [_][2]u21{
    .{ 0x00A1, 0x00A1 },
    .{ 0x00A4, 0x00A4 },
    .{ 0x00A7, 0x00A8 },
    .{ 0x00AA, 0x00AA },
    .{ 0x00AD, 0x00AE },
    .{ 0x00B0, 0x00B4 },
    .{ 0x00B6, 0x00BA },
    .{ 0x00BC, 0x00BF },
    .{ 0x00C6, 0x00C6 },
    .{ 0x00D0, 0x00D0 },
    .{ 0x00D7, 0x00D8 },
    .{ 0x00DE, 0x00E1 },
    .{ 0x00E6, 0x00E6 },
    .{ 0x00E8, 0x00EA },
    .{ 0x00EC, 0x00ED },
    .{ 0x00F0, 0x00F0 },
    .{ 0x00F2, 0x00F3 },
    .{ 0x00F7, 0x00FA },
    .{ 0x00FC, 0x00FC },
    .{ 0x00FE, 0x00FE },
    .{ 0x0101, 0x0101 },
    .{ 0x0111, 0x0111 },
    .{ 0x0113, 0x0113 },
    .{ 0x011B, 0x011B },
    .{ 0x0126, 0x0127 },
    .{ 0x012B, 0x012B },
    .{ 0x0131, 0x0133 },
    .{ 0x0138, 0x0138 },
    .{ 0x013F, 0x0142 },
    .{ 0x0144, 0x0144 },
    .{ 0x0148, 0x014B },
    .{ 0x014D, 0x014D },
    .{ 0x0152, 0x0153 },
    .{ 0x0166, 0x0167 },
    .{ 0x016B, 0x016B },
    .{ 0x01CE, 0x01CE },
    .{ 0x01D0, 0x01D0 },
    .{ 0x01D2, 0x01D2 },
    .{ 0x01D4, 0x01D4 },
    .{ 0x01D6, 0x01D6 },
    .{ 0x01D8, 0x01D8 },
    .{ 0x01DA, 0x01DA },
    .{ 0x01DC, 0x01DC },
    .{ 0x0251, 0x0251 },
    .{ 0x0261, 0x0261 },
    .{ 0x02C4, 0x02C4 },
    .{ 0x02C7, 0x02C7 },
    .{ 0x02C9, 0x02CB },
    .{ 0x02CD, 0x02CD },
    .{ 0x02D0, 0x02D0 },
    .{ 0x02D8, 0x02DB },
    .{ 0x02DD, 0x02DD },
    .{ 0x02DF, 0x02DF },
    .{ 0x0391, 0x03A1 },
    .{ 0x03A3, 0x03A9 },
    .{ 0x03B1, 0x03C1 },
    .{ 0x03C3, 0x03C9 },
    .{ 0x0401, 0x0401 },
    .{ 0x0410, 0x044F },
    .{ 0x0451, 0x0451 },
    .{ 0x2010, 0x2010 },
    .{ 0x2013, 0x2016 },
    .{ 0x2018, 0x2019 },
    .{ 0x201C, 0x201D },
    .{ 0x2020, 0x2022 },
    .{ 0x2024, 0x2027 },
    .{ 0x2030, 0x2030 },
    .{ 0x2032, 0x2033 },
    .{ 0x2035, 0x2035 },
    .{ 0x203B, 0x203B },
    .{ 0x203E, 0x203E },
    .{ 0x2074, 0x2074 },
    .{ 0x207F, 0x207F },
    .{ 0x2081, 0x2084 },
    .{ 0x20AC, 0x20AC },
    .{ 0x2103, 0x2103 },
    .{ 0x2105, 0x2105 },
    .{ 0x2109, 0x2109 },
    .{ 0x2113, 0x2113 },
    .{ 0x2116, 0x2116 },
    .{ 0x2121, 0x2122 },
    .{ 0x2126, 0x2126 },
    .{ 0x212B, 0x212B },
    .{ 0x2153, 0x2154 },
    .{ 0x215B, 0x215E },
    .{ 0x2160, 0x216B },
    .{ 0x2170, 0x2179 },
    .{ 0x2189, 0x2189 },
    .{ 0x2190, 0x2199 },
    .{ 0x21B8, 0x21B9 },
    .{ 0x21D2, 0x21D2 },
    .{ 0x21D4, 0x21D4 },
    .{ 0x21E7, 0x21E7 },
    .{ 0x2200, 0x2200 },
    .{ 0x2202, 0x2203 },
    .{ 0x2207, 0x2208 },
    .{ 0x220B, 0x220B },
    .{ 0x220F, 0x220F },
    .{ 0x2211, 0x2211 },
    .{ 0x2215, 0x2215 },
    .{ 0x221A, 0x221A },
    .{ 0x221D, 0x2220 },
    .{ 0x2223, 0x2223 },
    .{ 0x2225, 0x2225 },
    .{ 0x2227, 0x222C },
    .{ 0x222E, 0x222E },
    .{ 0x2234, 0x2237 },
    .{ 0x223C, 0x223D },
    .{ 0x2248, 0x2248 },
    .{ 0x224C, 0x224C },
    .{ 0x2252, 0x2252 },
    .{ 0x2260, 0x2261 },
    .{ 0x2264, 0x2267 },
    .{ 0x226A, 0x226B },
    .{ 0x226E, 0x226F },
    .{ 0x2282, 0x2283 },
    .{ 0x2286, 0x2287 },
    .{ 0x2295, 0x2295 },
    .{ 0x2299, 0x2299 },
    .{ 0x22A5, 0x22A5 },
    .{ 0x22BF, 0x22BF },
    .{ 0x2312, 0x2312 },
    .{ 0x2460, 0x24E9 },
    .{ 0x24EB, 0x254B },
    .{ 0x2550, 0x2573 },
    .{ 0x2580, 0x258F },
    .{ 0x2592, 0x2595 },
    .{ 0x25A0, 0x25A1 },
    .{ 0x25A3, 0x25AA },
    .{ 0x25B2, 0x25B3 },
    .{ 0x25B6, 0x25B7 },
    .{ 0x25BC, 0x25BD },
    .{ 0x25C0, 0x25C1 },
    .{ 0x25C6, 0x25C8 },
    .{ 0x25CB, 0x25CB },
    .{ 0x25CE, 0x25D1 },
    .{ 0x25E2, 0x25E6 },
    .{ 0x25EF, 0x25EF },
    .{ 0x2605, 0x2606 },
    .{ 0x2609, 0x2609 },
    .{ 0x260E, 0x260F },
    .{ 0x2610, 0x2611 },
    .{ 0x261C, 0x261C },
    .{ 0x261E, 0x261E },
    .{ 0x2640, 0x2640 },
    .{ 0x2642, 0x2642 },
    .{ 0x2660, 0x2661 },
    .{ 0x2663, 0x2665 },
    .{ 0x2667, 0x266A },
    .{ 0x266C, 0x266D },
    .{ 0x266F, 0x266F },
    .{ 0x269E, 0x269F },
    .{ 0x26BF, 0x26BF },
    .{ 0x26C6, 0x26CD },
    .{ 0x26CF, 0x26D3 },
    .{ 0x26D5, 0x26E1 },
    .{ 0x26E3, 0x26E3 },
    .{ 0x26E8, 0x26E9 },
    .{ 0x26EB, 0x26F1 },
    .{ 0x26F4, 0x26F4 },
    .{ 0x26F6, 0x26F9 },
    .{ 0x26FB, 0x26FC },
    .{ 0x26FE, 0x26FF },
    .{ 0x273D, 0x273D },
    .{ 0x2776, 0x277F },
    .{ 0x2B56, 0x2B59 },
    .{ 0xE000, 0xF8FF },
    .{ 0xFFFD, 0xFFFD },
    .{ 0x1F100, 0x1F10A },
    .{ 0x1F110, 0x1F12D },
    .{ 0x1F130, 0x1F169 },
    .{ 0x1F170, 0x1F18D },
    .{ 0x1F18F, 0x1F190 },
    .{ 0x1F19B, 0x1F1AC },
    .{ 0xF0000, 0xFFFFD },
    .{ 0x100000, 0x10FFFD },
};

fn isEastAsianAmbiguous(cp: u21) bool {
    if (cp < eaw_ambiguous_ranges[0][0]) return false;
    if (cp > eaw_ambiguous_ranges[eaw_ambiguous_ranges.len - 1][1]) return false;

    var lo: usize = 0;
    var hi: usize = eaw_ambiguous_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = eaw_ambiguous_ranges[mid];
        if (cp < r[0]) {
            hi = mid;
        } else if (cp > r[1]) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn codepointWidth(cp: u21, ambiguous: AmbiguousWidth) usize {
    if (cp >= 0x20 and cp < 0x7F) return 1;

    if (cp < 0x20) return 0;
    if (cp == 0x7f) return 0;

    switch (cp) {
        ZWSP, ZWNJ, ZWJ, WORD_JOINER, BOM, SOFT_HYPHEN => return 0,
        else => {},
    }

    if (cp >= 0xFE00 and cp <= 0xFE0F) return 0;
    if (cp >= 0xE0100 and cp <= 0xE01EF) return 0;

    if (cp >= 0x0300 and cp <= 0x036F) return 0;
    if (cp >= 0x1AB0 and cp <= 0x1AFF) return 0;
    if (cp >= 0x1DC0 and cp <= 0x1DFF) return 0;
    if (cp >= 0x20D0 and cp <= 0x20FF) return 0;
    if (cp >= 0xFE20 and cp <= 0xFE2F) return 0;
    if (cp >= 0x0E31 and cp <= 0x0E3A) return 0;
    if (cp >= 0x0E47 and cp <= 0x0E4E) return 0;

    // Skin tone modifiers (Fitzpatrick) — modify preceding emoji
    if (cp >= 0x1F3FB and cp <= 0x1F3FF) return 0;

    if (cp >= 0x20DD and cp <= 0x20E0) return 0;
    if (cp >= 0x20E2 and cp <= 0x20E4) return 0;

    if (cp >= 0x4E00 and cp <= 0x9FFF) return 2;
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2;
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
    if (cp >= 0x20000 and cp <= 0x2FA1F) return 2;

    if (cp >= 0x2E80 and cp <= 0x30FF) return 2;
    if (cp >= 0x31F0 and cp <= 0x31FF) return 2;
    if (cp >= 0x3200 and cp <= 0x32FF) return 2;
    if (cp >= 0x3300 and cp <= 0x33FF) return 2;

    if (cp >= 0xFF01 and cp <= 0xFF60) return 2;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;

    if (cp >= 0xAC00 and cp <= 0xD7A3) return 2;
    if (cp >= 0x1100 and cp <= 0x115F) return 2;
    if (cp >= 0x2329 and cp <= 0x232A) return 2;

    if (cp >= 0x1F300 and cp <= 0x1F9FF) return 2;
    if (cp >= 0x1FA00 and cp <= 0x1FA6F) return 2;
    if (cp >= 0x1FA70 and cp <= 0x1FAFF) return 2;

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

fn wrapWriterCollect(input: []const u8, max_w: usize, ambiguous: AmbiguousWidth) ![]u8 {
    const allocator = std.testing.allocator;
    var buf: std.io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);
    var ww: WrapWriter = undefined;
    ww.init(&buf.writer, max_w, ambiguous, allocator, &line_buf);
    defer ww.deinit();
    try ww.writer.writeAll(input);
    try ww.finish();

    var list = buf.toArrayList();
    defer buf.deinit();
    return list.toOwnedSlice(allocator);
}

fn expectWrapParity(input: []const u8, max_w: usize, ambiguous: AmbiguousWidth) !void {
    const allocator = std.testing.allocator;

    const expected = try wrapText(allocator, input, max_w, ambiguous);
    defer allocator.free(expected);

    const actual = try wrapWriterCollect(input, max_w, ambiguous);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test "WrapWriter basic word wrap matches wrapText" {
    try expectWrapParity("Hello World", 5, .narrow);
}

test "WrapWriter multiple words" {
    try expectWrapParity("one two three four five", 10, .narrow);
}

test "WrapWriter long word hard break" {
    try expectWrapParity("abcdefghij", 5, .narrow);
}

test "WrapWriter preserves existing newlines" {
    try expectWrapParity("abc\ndef\nghi", 10, .narrow);
}

test "WrapWriter consecutive spaces" {
    try expectWrapParity("a  b", 5, .narrow);
}

test "WrapWriter leading and trailing spaces" {
    try expectWrapParity(" hello ", 10, .narrow);
}

test "WrapWriter ANSI sequences preserved" {
    try expectWrapParity("\x1b[1mHello\x1b[0m \x1b[3mWorld\x1b[0m", 5, .narrow);
}

test "WrapWriter CJK characters width 2" {
    try expectWrapParity("漢字テスト", 6, .narrow);
}

test "WrapWriter styled fragment boundaries" {
    const allocator = std.testing.allocator;
    const input = "\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m word";

    const expected = try wrapText(allocator, input, 10, .narrow);
    defer allocator.free(expected);

    var buf: std.io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);
    var ww: WrapWriter = undefined;
    ww.init(&buf.writer, 10, .narrow, allocator, &line_buf);
    defer ww.deinit();

    try ww.writer.writeAll("\x1b[1m");
    try ww.writer.writeAll("bold");
    try ww.writer.writeAll("\x1b[0m");
    try ww.writer.writeAll(" ");
    try ww.writer.writeAll("\x1b[3m");
    try ww.writer.writeAll("italic");
    try ww.writer.writeAll("\x1b[0m");
    try ww.writer.writeAll(" word");
    try ww.finish();

    var list = buf.toArrayList();
    defer buf.deinit();
    const actual = try list.toOwnedSlice(allocator);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test "WrapWriter max_width 0 passes through" {
    try expectWrapParity("hello world", 0, .narrow);
}

test "WrapWriter single char per line" {
    try expectWrapParity("ab cd", 1, .narrow);
}

test "WrapWriter non-CSI ESC matches wrapText" {
    try expectWrapParity("\x1bXhello", 10, .narrow);
}

test "WrapWriter trailing ESC preserved" {
    try expectWrapParity("abc\x1b", 10, .narrow);
}

test "WrapWriter trailing incomplete CSI preserved" {
    try expectWrapParity("abc\x1b[", 10, .narrow);
}

test "WrapWriter trailing incomplete CSI with params preserved" {
    try expectWrapParity("abc\x1b[31", 10, .narrow);
}

test "WrapWriter split ANSI CSI across writes" {
    const allocator = std.testing.allocator;
    const input = "\x1b[31mred\x1b[0m text";

    const expected = try wrapText(allocator, input, 10, .narrow);
    defer allocator.free(expected);

    var buf: std.io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);
    var ww: WrapWriter = undefined;
    ww.init(&buf.writer, 10, .narrow, allocator, &line_buf);
    defer ww.deinit();

    try ww.writer.writeAll("\x1b");
    try ww.writer.writeAll("[31m");
    try ww.writer.writeAll("red");
    try ww.writer.writeAll("\x1b[0m text");
    try ww.finish();

    var list = buf.toArrayList();
    defer buf.deinit();
    const actual = try list.toOwnedSlice(allocator);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}

test "WrapWriter split ANSI ESC+[ across writes" {
    const allocator = std.testing.allocator;

    var buf: std.io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);
    var ww: WrapWriter = undefined;
    ww.init(&buf.writer, 10, .narrow, allocator, &line_buf);
    defer ww.deinit();

    try ww.writer.writeAll("\x1b[");
    try ww.writer.writeAll("1m");
    try ww.writer.writeAll("bold");
    try ww.writer.writeAll("\x1b[0m");
    try ww.finish();

    var list = buf.toArrayList();
    defer buf.deinit();
    const actual = try list.toOwnedSlice(allocator);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings("\x1b[1mbold\x1b[0m", actual);
}

test "WrapWriter split UTF-8 across writes" {
    const allocator = std.testing.allocator;
    const full = "漢字";
    const expected = try wrapText(allocator, full, 10, .narrow);
    defer allocator.free(expected);

    var buf: std.io.Writer.Allocating = .init(allocator);
    errdefer buf.deinit();

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);
    var ww: WrapWriter = undefined;
    ww.init(&buf.writer, 10, .narrow, allocator, &line_buf);
    defer ww.deinit();
    try ww.writer.writeAll(full[0..1]);
    try ww.writer.writeAll(full[1..]);
    try ww.finish();

    var list = buf.toArrayList();
    defer buf.deinit();
    const actual = try list.toOwnedSlice(allocator);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(expected, actual);
}
