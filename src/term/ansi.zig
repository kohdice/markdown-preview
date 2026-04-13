const std = @import("std");
const theme = @import("theme.zig");

/// ANSI SGR reset sequence (ECMA-48 §8.3.117, SGR parameter 0).
/// Clears all active style attributes. Exported so modules that emit or
/// detect ANSI style boundaries share a single source of truth.
pub const reset_sequence = "\x1b[0m";

/// ANSI Select Graphic Rendition (SGR) escape sequences (ECMA-48 §8.3.117).
/// The `38;2;r;g;b` form is the 24-bit "true color" foreground extension.
const sgr = struct {
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const italic = "\x1b[3m";
    const underline = "\x1b[4m";
    const strikethrough = "\x1b[9m";
    const fg_truecolor_fmt = "\x1b[38;2;{};{};{}m";
};

pub const TextStyle = struct {
    fg: ?theme.Rgb = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,

    pub fn isPlain(self: TextStyle) bool {
        return self.fg == null and !self.bold and !self.dim and !self.italic and
            !self.underline and !self.strikethrough;
    }

    pub fn merge(self: TextStyle, other: TextStyle) TextStyle {
        return .{
            .fg = other.fg orelse self.fg,
            .bold = self.bold or other.bold,
            .dim = self.dim or other.dim,
            .italic = self.italic or other.italic,
            .underline = self.underline or other.underline,
            .strikethrough = self.strikethrough or other.strikethrough,
        };
    }
};

pub fn applyStyle(writer: *std.io.Writer, style: TextStyle) !void {
    var buf: [48]u8 = undefined;
    const len = buildStylePrefix(&buf, style);
    if (len > 0) try writer.writeAll(buf[0..len]);
}

fn buildStylePrefix(buf: *[48]u8, style: TextStyle) usize {
    var pos: usize = 0;
    if (style.bold) {
        @memcpy(buf[pos..][0..sgr.bold.len], sgr.bold);
        pos += sgr.bold.len;
    }
    if (style.dim) {
        @memcpy(buf[pos..][0..sgr.dim.len], sgr.dim);
        pos += sgr.dim.len;
    }
    if (style.italic) {
        @memcpy(buf[pos..][0..sgr.italic.len], sgr.italic);
        pos += sgr.italic.len;
    }
    if (style.underline) {
        @memcpy(buf[pos..][0..sgr.underline.len], sgr.underline);
        pos += sgr.underline.len;
    }
    if (style.strikethrough) {
        @memcpy(buf[pos..][0..sgr.strikethrough.len], sgr.strikethrough);
        pos += sgr.strikethrough.len;
    }
    if (style.fg) |fg| {
        pos += formatTruecolor(buf[pos..], fg.r, fg.g, fg.b);
    }
    return pos;
}

fn formatTruecolor(buf: []u8, r: u8, g: u8, b: u8) usize {
    const prefix = "\x1b[38;2;";
    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;
    pos += writeDecimal(buf[pos..], r);
    buf[pos] = ';';
    pos += 1;
    pos += writeDecimal(buf[pos..], g);
    buf[pos] = ';';
    pos += 1;
    pos += writeDecimal(buf[pos..], b);
    buf[pos] = 'm';
    pos += 1;
    return pos;
}

fn writeDecimal(buf: []u8, val: u8) usize {
    if (val >= 100) {
        buf[0] = '0' + val / 100;
        buf[1] = '0' + (val / 10) % 10;
        buf[2] = '0' + val % 10;
        return 3;
    } else if (val >= 10) {
        buf[0] = '0' + val / 10;
        buf[1] = '0' + val % 10;
        return 2;
    } else {
        buf[0] = '0' + val;
        return 1;
    }
}

pub fn writeStyled(
    writer: *std.io.Writer,
    enabled: bool,
    style: TextStyle,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    if (!enabled or style.isPlain()) {
        try writeSanitized(writer, text);
        return;
    }

    if (text.len <= 64 and !containsControlChar(text)) {
        var buf: [128]u8 = undefined;
        var pos: usize = 0;
        pos += buildStylePrefix(buf[0..48], style);
        @memcpy(buf[pos..][0..text.len], text);
        pos += text.len;
        @memcpy(buf[pos..][0..reset_sequence.len], reset_sequence);
        pos += reset_sequence.len;
        try writer.writeAll(buf[0..pos]);
        return;
    }

    try applyStyle(writer, style);
    try writeSanitized(writer, text);
    try writer.writeAll(reset_sequence);
}

fn containsControlChar(text: []const u8) bool {
    for (text) |byte| {
        if (std.ascii.isControl(byte) and byte != '\t' and byte != '\n') return true;
    }
    return false;
}

/// Write text with C0 control characters and DEL stripped to prevent
/// terminal escape-sequence injection from untrusted Markdown input.
/// Tab and newline are preserved because they are meaningful whitespace.
fn writeSanitized(writer: *std.io.Writer, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, i| {
        if (std.ascii.isControl(byte) and byte != '\t' and byte != '\n') {
            if (start < i) try writer.writeAll(text[start..i]);
            start = i + 1;
        }
    }
    if (start < text.len) try writer.writeAll(text[start..]);
}

const testing = std.testing;

test "writeStyled fast path boundary at 64 bytes" {
    const style: TextStyle = .{ .fg = .{ .r = 0, .g = 0, .b = 0 } };

    var buf64: std.io.Writer.Allocating = .init(testing.allocator);
    defer buf64.deinit();
    const text64 = "a" ** 64;
    try writeStyled(&buf64.writer, true, style, text64);
    const out64 = buf64.writer.buffered();

    var buf65: std.io.Writer.Allocating = .init(testing.allocator);
    defer buf65.deinit();
    const text65 = "a" ** 65;
    try writeStyled(&buf65.writer, true, style, text65);
    const out65 = buf65.writer.buffered();

    try testing.expect(std.mem.startsWith(u8, out64, "\x1b[38;2;0;0;0m"));
    try testing.expect(std.mem.endsWith(u8, out64, reset_sequence));
    try testing.expect(std.mem.startsWith(u8, out65, "\x1b[38;2;0;0;0m"));
    try testing.expect(std.mem.endsWith(u8, out65, reset_sequence));

    try testing.expectEqual(out64.len + 1, out65.len);
}
