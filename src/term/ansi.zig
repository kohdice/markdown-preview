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

pub const ColorMode = enum { none, ansi16, ansi256, truecolor };

pub const Hsl = struct { h: f32, s: f32, l: f32 };

pub fn hslToRgb(hsl: Hsl) theme.Rgb {
    const c = (1 - @abs(2 * hsl.l - 1)) * hsl.s;
    const h_prime = hsl.h / 60.0;
    const x = c * (1 - @abs(@mod(h_prime, 2.0) - 1));
    var r1: f32 = 0;
    var g1: f32 = 0;
    var b1: f32 = 0;
    if (h_prime < 1) {
        r1 = c;
        g1 = x;
    } else if (h_prime < 2) {
        r1 = x;
        g1 = c;
    } else if (h_prime < 3) {
        g1 = c;
        b1 = x;
    } else if (h_prime < 4) {
        g1 = x;
        b1 = c;
    } else if (h_prime < 5) {
        r1 = x;
        b1 = c;
    } else {
        r1 = c;
        b1 = x;
    }
    const m = hsl.l - c / 2;
    return .{
        .r = @intFromFloat(@round((r1 + m) * 255)),
        .g = @intFromFloat(@round((g1 + m) * 255)),
        .b = @intFromFloat(@round((b1 + m) * 255)),
    };
}

pub fn rgbToHsl(rgb: theme.Rgb) Hsl {
    const r: f32 = @as(f32, @floatFromInt(rgb.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(rgb.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(rgb.b)) / 255.0;
    const max_c = @max(@max(r, g), b);
    const min_c = @min(@min(r, g), b);
    const l = (max_c + min_c) / 2;
    if (max_c == min_c) return .{ .h = 0, .s = 0, .l = l };
    const chroma = max_c - min_c;
    const s = chroma / (1 - @abs(2 * l - 1));
    var h: f32 = 0;
    if (max_c == r) {
        h = @mod((g - b) / chroma, 6);
    } else if (max_c == g) {
        h = (b - r) / chroma + 2;
    } else {
        h = (r - g) / chroma + 4;
    }
    h *= 60;
    if (h < 0) h += 360;
    return .{ .h = h, .s = s, .l = l };
}

pub fn detectColorMode(env: anytype) ColorMode {
    if (env.get("NO_COLOR")) |_| return .none;
    if (env.get("COLORTERM")) |v| {
        if (std.mem.eql(u8, v, "truecolor") or std.mem.eql(u8, v, "24bit")) return .truecolor;
    }
    if (env.get("TERM")) |v| {
        if (std.mem.indexOf(u8, v, "256color") != null) return .ansi256;
        if (!std.mem.eql(u8, v, "dumb") and v.len > 0) return .ansi16;
    }
    return .none;
}

pub fn writeSgrFg(writer: *std.io.Writer, rgb: theme.Rgb, mode: ColorMode) !void {
    switch (mode) {
        .none => return,
        .truecolor => {
            var buf: [24]u8 = undefined;
            const len = formatTruecolor(&buf, rgb.r, rgb.g, rgb.b);
            try writer.writeAll(buf[0..len]);
        },
        .ansi256 => {
            var buf: [12]u8 = undefined;
            const len = formatAnsi256(&buf, ansi256Index(rgb.r, rgb.g, rgb.b));
            try writer.writeAll(buf[0..len]);
        },
        .ansi16 => {
            var buf: [8]u8 = undefined;
            const len = formatAnsi16(&buf, ansi16Code(rgb.r, rgb.g, rgb.b));
            try writer.writeAll(buf[0..len]);
        },
    }
}

fn ansi16Code(r: u8, g: u8, b: u8) u8 {
    const luma = (@as(u32, r) * 299 + @as(u32, g) * 587 + @as(u32, b) * 114) / 1000;
    const max_c: u32 = @max(@max(r, g), b);
    if (max_c == 0) return 30;
    const thr = max_c * 3;
    var code: u8 = 30;
    if (@as(u32, r) * 5 >= thr) code += 1;
    if (@as(u32, g) * 5 >= thr) code += 2;
    if (@as(u32, b) * 5 >= thr) code += 4;
    if (luma > 100) code += 60;
    return code;
}

fn formatAnsi16(buf: []u8, code: u8) usize {
    const prefix = "\x1b[";
    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;
    pos += writeDecimal(buf[pos..], code);
    buf[pos] = 'm';
    pos += 1;
    return pos;
}

fn ansi256Index(r: u8, g: u8, b: u8) u8 {
    const max_c = @max(@max(r, g), b);
    const min_c = @min(@min(r, g), b);
    if (max_c - min_c < 10) {
        const luma = (@as(u32, r) * 299 + @as(u32, g) * 587 + @as(u32, b) * 114) / 1000;
        if (luma < 8) return 16;
        const step = @min(@as(u32, 23), (luma - 8) / 10);
        return 232 + @as(u8, @intCast(step));
    }
    const qr = (@as(u32, r) * 6) / 256;
    const qg = (@as(u32, g) * 6) / 256;
    const qb = (@as(u32, b) * 6) / 256;
    return 16 + @as(u8, @intCast(36 * qr + 6 * qg + qb));
}

fn formatAnsi256(buf: []u8, idx: u8) usize {
    const prefix = "\x1b[38;5;";
    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;
    pos += writeDecimal(buf[pos..], idx);
    buf[pos] = 'm';
    pos += 1;
    return pos;
}

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

    if (text.len <= 256 and !containsControlChar(text)) {
        var buf: [512]u8 = undefined;
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
    if (!containsControlChar(text)) return writer.writeAll(text);

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

test "writeSgrFg emits ESC[38;2;R;G;Bm in truecolor mode" {
    var buf: std.io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeSgrFg(&buf.writer, .{ .r = 59, .g = 130, .b = 246 }, .truecolor);
    try testing.expectEqualStrings("\x1b[38;2;59;130;246m", buf.writer.buffered());
}

test "writeSgrFg writes nothing in none mode" {
    var buf: std.io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeSgrFg(&buf.writer, .{ .r = 59, .g = 130, .b = 246 }, .none);
    try testing.expectEqualStrings("", buf.writer.buffered());
}

test "writeSgrFg in ansi256 mode maps pure red to color cube 196" {
    var buf: std.io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeSgrFg(&buf.writer, .{ .r = 255, .g = 0, .b = 0 }, .ansi256);
    try testing.expectEqualStrings("\x1b[38;5;196m", buf.writer.buffered());
}

test "writeSgrFg in ansi256 mode maps mid-gray to grayscale index 244" {
    var buf: std.io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeSgrFg(&buf.writer, .{ .r = 128, .g = 128, .b = 128 }, .ansi256);
    try testing.expectEqualStrings("\x1b[38;5;244m", buf.writer.buffered());
}

test "writeSgrFg in ansi16 mode maps bright red to code 91" {
    var buf: std.io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeSgrFg(&buf.writer, .{ .r = 255, .g = 64, .b = 64 }, .ansi16);
    try testing.expectEqualStrings("\x1b[91m", buf.writer.buffered());
}

test "writeSgrFg in ansi16 mode maps dark blue to code 34" {
    var buf: std.io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeSgrFg(&buf.writer, .{ .r = 0, .g = 0, .b = 64 }, .ansi16);
    try testing.expectEqualStrings("\x1b[34m", buf.writer.buffered());
}

test "hslToRgb converts pure red HSL (0, 1, 0.5) to RGB (255, 0, 0)" {
    const rgb = hslToRgb(.{ .h = 0, .s = 1, .l = 0.5 });
    try testing.expectEqual(@as(u8, 255), rgb.r);
    try testing.expectEqual(@as(u8, 0), rgb.g);
    try testing.expectEqual(@as(u8, 0), rgb.b);
}

test "rgbToHsl converts pure blue RGB (0, 0, 255) to HSL (240, 1, 0.5)" {
    const hsl = rgbToHsl(.{ .r = 0, .g = 0, .b = 255 });
    try testing.expectApproxEqAbs(@as(f32, 240), hsl.h, 1);
    try testing.expectApproxEqAbs(@as(f32, 1), hsl.s, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.5), hsl.l, 0.01);
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

test "detectColorMode returns truecolor when COLORTERM=truecolor" {
    const env = StubEnv(.{.{ "COLORTERM", "truecolor" }});
    try testing.expectEqual(ColorMode.truecolor, detectColorMode(env));
}

test "detectColorMode returns ansi256 when TERM contains 256color" {
    const env = StubEnv(.{.{ "TERM", "xterm-256color" }});
    try testing.expectEqual(ColorMode.ansi256, detectColorMode(env));
}

test "detectColorMode returns none when NO_COLOR is set" {
    const env = StubEnv(.{
        .{ "NO_COLOR", "1" },
        .{ "COLORTERM", "truecolor" },
    });
    try testing.expectEqual(ColorMode.none, detectColorMode(env));
}

test "writeStyled fast path boundary at 256 bytes" {
    const style: TextStyle = .{ .fg = .{ .r = 0, .g = 0, .b = 0 } };

    var buf256: std.io.Writer.Allocating = .init(testing.allocator);
    defer buf256.deinit();
    const text256 = "a" ** 256;
    try writeStyled(&buf256.writer, true, style, text256);
    const out256 = buf256.writer.buffered();

    var buf257: std.io.Writer.Allocating = .init(testing.allocator);
    defer buf257.deinit();
    const text257 = "a" ** 257;
    try writeStyled(&buf257.writer, true, style, text257);
    const out257 = buf257.writer.buffered();

    try testing.expect(std.mem.startsWith(u8, out256, "\x1b[38;2;0;0;0m"));
    try testing.expect(std.mem.endsWith(u8, out256, reset_sequence));
    try testing.expect(std.mem.startsWith(u8, out257, "\x1b[38;2;0;0;0m"));
    try testing.expect(std.mem.endsWith(u8, out257, reset_sequence));

    try testing.expectEqual(out256.len + 1, out257.len);
}
