const std = @import("std");
const theme = @import("theme.zig");

pub const reset_sequence = "\x1b[0m";

pub const italic_on = "\x1b[3m";
pub const italic_off = "\x1b[23m";
pub const underline_on = "\x1b[4m";
pub const underline_off = "\x1b[24m";

const rgb_channel_max: f32 = 255.0;
const hsl_sector_angle: f32 = 60.0;
const hsl_full_turn: f32 = 360.0;
const style_prefix_buf_size: usize = 48;
const truecolor_seq_buf_size: usize = 24;
const write_styled_fast_path_limit: usize = 256;
const write_styled_fast_path_buf_size: usize = style_prefix_buf_size + write_styled_fast_path_limit + reset_sequence.len;

const sgr = struct {
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const italic = italic_on;
    const underline = underline_on;
    const strikethrough = "\x1b[9m";
};

pub const Hsl = struct { h: f32, s: f32, l: f32 };

pub fn hslToRgb(hsl: Hsl) theme.Rgb {
    const c = (1 - @abs(2 * hsl.l - 1)) * hsl.s;
    const h_prime = hsl.h / hsl_sector_angle;
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
        .r = @intFromFloat(@round((r1 + m) * rgb_channel_max)),
        .g = @intFromFloat(@round((g1 + m) * rgb_channel_max)),
        .b = @intFromFloat(@round((b1 + m) * rgb_channel_max)),
    };
}

pub fn rgbToHsl(rgb: theme.Rgb) Hsl {
    const r: f32 = @as(f32, @floatFromInt(rgb.r)) / rgb_channel_max;
    const g: f32 = @as(f32, @floatFromInt(rgb.g)) / rgb_channel_max;
    const b: f32 = @as(f32, @floatFromInt(rgb.b)) / rgb_channel_max;
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
    h *= hsl_sector_angle;
    if (h < 0) h += hsl_full_turn;
    return .{ .h = h, .s = s, .l = l };
}

pub fn writeSgrFg(writer: *std.Io.Writer, rgb: theme.Rgb) !void {
    var buf: [truecolor_seq_buf_size]u8 = undefined;
    const len = formatTruecolor(&buf, rgb.r, rgb.g, rgb.b);
    try writer.writeAll(buf[0..len]);
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

pub fn applyStyle(writer: *std.Io.Writer, style: TextStyle) !void {
    var buf: [style_prefix_buf_size]u8 = undefined;
    const len = buildStylePrefix(&buf, style);
    if (len > 0) try writer.writeAll(buf[0..len]);
}

fn buildStylePrefix(buf: *[style_prefix_buf_size]u8, style: TextStyle) usize {
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

pub const StyledState = struct {
    current: ?TextStyle = null,
};

pub fn writeStyledRun(
    writer: *std.Io.Writer,
    enabled: bool,
    state: *StyledState,
    style: TextStyle,
    text: []const u8,
) !void {
    if (!enabled or style.isPlain()) {
        try flushStyle(writer, state);
        if (text.len > 0) try writeSanitized(writer, text);
        return;
    }
    if (state.current) |current| {
        if (stylesEqual(current, style)) {
            if (text.len > 0) try writeSanitized(writer, text);
            return;
        }
        try writer.writeAll(reset_sequence);
    }
    try applyStyle(writer, style);
    if (text.len > 0) try writeSanitized(writer, text);
    state.current = style;
}

pub fn flushStyle(writer: *std.Io.Writer, state: *StyledState) !void {
    if (state.current == null) return;
    try writer.writeAll(reset_sequence);
    state.current = null;
}

fn stylesEqual(a: TextStyle, b: TextStyle) bool {
    if (a.bold != b.bold or a.dim != b.dim or a.italic != b.italic) return false;
    if (a.underline != b.underline or a.strikethrough != b.strikethrough) return false;
    if (a.fg == null and b.fg == null) return true;
    if (a.fg == null or b.fg == null) return false;
    const af = a.fg.?;
    const bf = b.fg.?;
    return af.r == bf.r and af.g == bf.g and af.b == bf.b;
}

pub fn writeStyled(
    writer: *std.Io.Writer,
    enabled: bool,
    style: TextStyle,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    if (!enabled or style.isPlain()) {
        try writeSanitized(writer, text);
        return;
    }

    if (text.len <= write_styled_fast_path_limit and !containsControlChar(text)) {
        var buf: [write_styled_fast_path_buf_size]u8 = undefined;
        var pos: usize = 0;
        pos += buildStylePrefix(buf[0..style_prefix_buf_size], style);
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
fn writeSanitized(writer: *std.Io.Writer, text: []const u8) !void {
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

fn isCsiParamOrIntermediateByte(byte: u8) bool {
    return byte >= 0x20 and byte <= 0x3f;
}

fn isCsiFinalByte(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x7e;
}

fn skipCsi(input: []const u8, start: usize) ?usize {
    if (start + 1 >= input.len) return null;
    if (input[start] != 0x1b or input[start + 1] != '[') return null;

    var i = start + 2;
    while (i < input.len and isCsiParamOrIntermediateByte(input[i])) : (i += 1) {}
    if (i >= input.len or !isCsiFinalByte(input[i])) return null;
    return i + 1;
}

/// Return a copy of `input` with ANSI CSI sequences removed.
pub fn stripCsiAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (skipCsi(input, i)) |after| {
            i = after;
            continue;
        }

        try output.append(allocator, input[i]);
        i += 1;
    }

    return output.toOwnedSlice(allocator);
}

const testing = std.testing;

test "stripCsiAlloc removes complete CSI sequences" {
    const stripped = try stripCsiAlloc(testing.allocator, "\x1b[31mred\x1b[0m plain");
    defer testing.allocator.free(stripped);

    try testing.expectEqualStrings("red plain", stripped);
}

test "stripCsiAlloc preserves incomplete CSI bytes" {
    const stripped = try stripCsiAlloc(testing.allocator, "plain \x1b[31");
    defer testing.allocator.free(stripped);

    try testing.expectEqualStrings("plain \x1b[31", stripped);
}

test "writeSgrFg emits ESC[38;2;R;G;Bm" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeSgrFg(&buf.writer, .{ .r = 59, .g = 130, .b = 246 });
    try testing.expectEqualStrings("\x1b[38;2;59;130;246m", buf.writer.buffered());
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

test "writeStyledRun first call emits prefix and text, no reset" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var state: StyledState = .{};
    const style: TextStyle = .{ .fg = .{ .r = 255, .g = 0, .b = 0 } };
    try writeStyledRun(&buf.writer, true, &state, style, "hello");
    try testing.expectEqualStrings("\x1b[38;2;255;0;0mhello", buf.writer.buffered());
    try testing.expect(state.current != null);
}

test "writeStyledRun second call with same style skips prefix and reset" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var state: StyledState = .{};
    const style: TextStyle = .{ .fg = .{ .r = 255, .g = 0, .b = 0 } };
    try writeStyledRun(&buf.writer, true, &state, style, "A");
    try writeStyledRun(&buf.writer, true, &state, style, "B");
    try testing.expectEqualStrings("\x1b[38;2;255;0;0mAB", buf.writer.buffered());
}

test "writeStyledRun different style emits reset and new prefix" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var state: StyledState = .{};
    const red: TextStyle = .{ .fg = .{ .r = 255, .g = 0, .b = 0 } };
    const blue: TextStyle = .{ .fg = .{ .r = 0, .g = 0, .b = 255 } };
    try writeStyledRun(&buf.writer, true, &state, red, "X");
    try writeStyledRun(&buf.writer, true, &state, blue, "Y");
    try testing.expectEqualStrings(
        "\x1b[38;2;255;0;0mX\x1b[0m\x1b[38;2;0;0;255mY",
        buf.writer.buffered(),
    );
}

test "flushStyle emits reset when state is set and nothing when cleared" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var state: StyledState = .{};
    const red: TextStyle = .{ .fg = .{ .r = 255, .g = 0, .b = 0 } };
    try writeStyledRun(&buf.writer, true, &state, red, "Z");
    try flushStyle(&buf.writer, &state);
    try flushStyle(&buf.writer, &state);
    try testing.expectEqualStrings("\x1b[38;2;255;0;0mZ\x1b[0m", buf.writer.buffered());
    try testing.expectEqual(@as(?TextStyle, null), state.current);
}

test "writeStyledRun with ansi disabled emits plain text only" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var state: StyledState = .{};
    const style: TextStyle = .{ .fg = .{ .r = 255, .g = 0, .b = 0 } };
    try writeStyledRun(&buf.writer, false, &state, style, "plain");
    try testing.expectEqualStrings("plain", buf.writer.buffered());
    try testing.expectEqual(@as(?TextStyle, null), state.current);
}

test "writeStyled fast path boundary at 256 bytes" {
    const style: TextStyle = .{ .fg = .{ .r = 0, .g = 0, .b = 0 } };

    var buf256: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf256.deinit();
    const text256 = "a" ** 256;
    try writeStyled(&buf256.writer, true, style, text256);
    const out256 = buf256.writer.buffered();

    var buf257: std.Io.Writer.Allocating = .init(testing.allocator);
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
