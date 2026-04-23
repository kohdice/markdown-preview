const std = @import("std");
const env_like = @import("env_like.zig");
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
const ansi256_seq_buf_size: usize = 12;
const ansi16_seq_buf_size: usize = 8;
const write_styled_fast_path_limit: usize = 256;
const write_styled_fast_path_buf_size: usize = style_prefix_buf_size + write_styled_fast_path_limit + reset_sequence.len;

const rec601 = struct {
    const r_weight: u32 = 299;
    const g_weight: u32 = 587;
    const b_weight: u32 = 114;
    const scale: u32 = 1000;
};

const ansi16 = struct {
    const base_code: u8 = 30;
    const bright_offset: u8 = 60;
    const bright_luma_threshold: u32 = 100;
    const dominant_threshold: u32 = 3;
    const dominant_scale: u32 = 5;
    const red_mask: u8 = 1;
    const green_mask: u8 = 2;
    const blue_mask: u8 = 4;
};

const ansi256 = struct {
    const cube_base: u8 = 16;
    const cube_axis_size: u32 = 6;
    const cube_green_stride: u32 = cube_axis_size;
    const cube_red_stride: u32 = cube_axis_size * cube_axis_size;
    const channel_quantization_divisor: u32 = 256;
    const grayscale_base: u8 = 232;
    const grayscale_steps: u32 = 23;
    const grayscale_step_size: u32 = 10;
    const grayscale_delta_threshold: u8 = 10;
    const grayscale_black_luma_threshold: u32 = 8;
};

const sgr = struct {
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const italic = italic_on;
    const underline = underline_on;
    const strikethrough = "\x1b[9m";
    const fg_truecolor_fmt = "\x1b[38;2;{};{};{}m";
};

pub const ColorMode = enum { none, ansi16, ansi256, truecolor };

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

pub fn detectColorMode(env: anytype) ColorMode {
    const Env = if (@TypeOf(env) == type) env else @TypeOf(env);
    comptime env_like.requireGetContract(Env);

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

pub fn writeSgrFg(writer: *std.Io.Writer, rgb: theme.Rgb, mode: ColorMode) !void {
    switch (mode) {
        .none => return,
        .truecolor => {
            var buf: [truecolor_seq_buf_size]u8 = undefined;
            const len = formatTruecolor(&buf, rgb.r, rgb.g, rgb.b);
            try writer.writeAll(buf[0..len]);
        },
        .ansi256 => {
            var buf: [ansi256_seq_buf_size]u8 = undefined;
            const len = formatAnsi256(&buf, ansi256Index(rgb.r, rgb.g, rgb.b));
            try writer.writeAll(buf[0..len]);
        },
        .ansi16 => {
            var buf: [ansi16_seq_buf_size]u8 = undefined;
            const len = formatAnsi16(&buf, ansi16Code(rgb.r, rgb.g, rgb.b));
            try writer.writeAll(buf[0..len]);
        },
    }
}

fn rec601Luma(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) * rec601.r_weight + @as(u32, g) * rec601.g_weight + @as(u32, b) * rec601.b_weight) / rec601.scale;
}

fn ansi16Code(r: u8, g: u8, b: u8) u8 {
    const luma = rec601Luma(r, g, b);
    const max_c: u32 = @max(@max(r, g), b);
    if (max_c == 0) return ansi16.base_code;
    const thr = max_c * ansi16.dominant_threshold;
    var code: u8 = ansi16.base_code;
    if (@as(u32, r) * ansi16.dominant_scale >= thr) code += ansi16.red_mask;
    if (@as(u32, g) * ansi16.dominant_scale >= thr) code += ansi16.green_mask;
    if (@as(u32, b) * ansi16.dominant_scale >= thr) code += ansi16.blue_mask;
    if (luma > ansi16.bright_luma_threshold) code += ansi16.bright_offset;
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
    if (max_c - min_c < ansi256.grayscale_delta_threshold) {
        const luma = rec601Luma(r, g, b);
        if (luma < ansi256.grayscale_black_luma_threshold) return ansi256.cube_base;
        const step = @min(@as(u32, ansi256.grayscale_steps), (luma - ansi256.grayscale_black_luma_threshold) / ansi256.grayscale_step_size);
        return ansi256.grayscale_base + @as(u8, @intCast(step));
    }
    const qr = (@as(u32, r) * ansi256.cube_axis_size) / ansi256.channel_quantization_divisor;
    const qg = (@as(u32, g) * ansi256.cube_axis_size) / ansi256.channel_quantization_divisor;
    const qb = (@as(u32, b) * ansi256.cube_axis_size) / ansi256.channel_quantization_divisor;
    return ansi256.cube_base + @as(u8, @intCast(ansi256.cube_red_stride * qr + ansi256.cube_green_stride * qg + qb));
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

pub fn applyStyle(writer: *std.Io.Writer, mode: ColorMode, style: TextStyle) !void {
    var buf: [style_prefix_buf_size]u8 = undefined;
    const len = buildStylePrefix(&buf, mode, style);
    if (len > 0) try writer.writeAll(buf[0..len]);
}

fn buildStylePrefix(buf: *[style_prefix_buf_size]u8, mode: ColorMode, style: TextStyle) usize {
    if (mode == .none) return 0;

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
        pos += switch (mode) {
            .none => 0,
            .truecolor => formatTruecolor(buf[pos..], fg.r, fg.g, fg.b),
            .ansi256 => formatAnsi256(buf[pos..], ansi256Index(fg.r, fg.g, fg.b)),
            .ansi16 => formatAnsi16(buf[pos..], ansi16Code(fg.r, fg.g, fg.b)),
        };
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
    mode: ColorMode,
    state: *StyledState,
    style: TextStyle,
    text: []const u8,
) !void {
    if (!enabled or mode == .none or style.isPlain()) {
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
    try applyStyle(writer, mode, style);
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
    mode: ColorMode,
    style: TextStyle,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    if (!enabled or mode == .none or style.isPlain()) {
        try writeSanitized(writer, text);
        return;
    }

    if (text.len <= write_styled_fast_path_limit and !containsControlChar(text)) {
        var buf: [write_styled_fast_path_buf_size]u8 = undefined;
        var pos: usize = 0;
        pos += buildStylePrefix(buf[0..style_prefix_buf_size], mode, style);
        @memcpy(buf[pos..][0..text.len], text);
        pos += text.len;
        @memcpy(buf[pos..][0..reset_sequence.len], reset_sequence);
        pos += reset_sequence.len;
        try writer.writeAll(buf[0..pos]);
        return;
    }

    try applyStyle(writer, mode, style);
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

const testing = std.testing;

test "writeSgrFg emits ESC[38;2;R;G;Bm in truecolor mode" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeSgrFg(&buf.writer, .{ .r = 59, .g = 130, .b = 246 }, .truecolor);
    try testing.expectEqualStrings("\x1b[38;2;59;130;246m", buf.writer.buffered());
}

test "writeSgrFg writes nothing in none mode" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeSgrFg(&buf.writer, .{ .r = 59, .g = 130, .b = 246 }, .none);
    try testing.expectEqualStrings("", buf.writer.buffered());
}

test "writeSgrFg in ansi256 mode maps pure red to color cube 196" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeSgrFg(&buf.writer, .{ .r = 255, .g = 0, .b = 0 }, .ansi256);
    try testing.expectEqualStrings("\x1b[38;5;196m", buf.writer.buffered());
}

test "writeSgrFg in ansi256 mode maps mid-gray to grayscale index 244" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeSgrFg(&buf.writer, .{ .r = 128, .g = 128, .b = 128 }, .ansi256);
    try testing.expectEqualStrings("\x1b[38;5;244m", buf.writer.buffered());
}

test "writeSgrFg in ansi16 mode maps bright red to code 91" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try writeSgrFg(&buf.writer, .{ .r = 255, .g = 64, .b = 64 }, .ansi16);
    try testing.expectEqualStrings("\x1b[91m", buf.writer.buffered());
}

test "writeSgrFg in ansi16 mode maps dark blue to code 34" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
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

test "detectColorMode returns truecolor when COLORTERM=truecolor" {
    const env = env_like.StubEnv(.{.{ "COLORTERM", "truecolor" }});
    try testing.expectEqual(ColorMode.truecolor, detectColorMode(env));
}

test "detectColorMode returns ansi256 when TERM contains 256color" {
    const env = env_like.StubEnv(.{.{ "TERM", "xterm-256color" }});
    try testing.expectEqual(ColorMode.ansi256, detectColorMode(env));
}

test "detectColorMode returns none when NO_COLOR is set" {
    const env = env_like.StubEnv(.{
        .{ "NO_COLOR", "1" },
        .{ "COLORTERM", "truecolor" },
    });
    try testing.expectEqual(ColorMode.none, detectColorMode(env));
}

test "detectColorMode accepts pointer env adapters" {
    const PointerEnv = struct {
        no_color: ?[]const u8 = null,
        colorterm: ?[]const u8 = null,
        term: ?[]const u8 = null,

        pub fn get(self: @This(), name: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name, "NO_COLOR")) return self.no_color;
            if (std.mem.eql(u8, name, "COLORTERM")) return self.colorterm;
            if (std.mem.eql(u8, name, "TERM")) return self.term;
            return null;
        }
    };

    var env: PointerEnv = .{ .colorterm = "24bit" };
    try testing.expectEqual(ColorMode.truecolor, detectColorMode(&env));
}

test "writeStyledRun first call emits prefix and text, no reset" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var state: StyledState = .{};
    const style: TextStyle = .{ .fg = .{ .r = 255, .g = 0, .b = 0 } };
    try writeStyledRun(&buf.writer, true, .truecolor, &state, style, "hello");
    try testing.expectEqualStrings("\x1b[38;2;255;0;0mhello", buf.writer.buffered());
    try testing.expect(state.current != null);
}

test "writeStyledRun second call with same style skips prefix and reset" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var state: StyledState = .{};
    const style: TextStyle = .{ .fg = .{ .r = 255, .g = 0, .b = 0 } };
    try writeStyledRun(&buf.writer, true, .truecolor, &state, style, "A");
    try writeStyledRun(&buf.writer, true, .truecolor, &state, style, "B");
    try testing.expectEqualStrings("\x1b[38;2;255;0;0mAB", buf.writer.buffered());
}

test "writeStyledRun different style emits reset and new prefix" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var state: StyledState = .{};
    const red: TextStyle = .{ .fg = .{ .r = 255, .g = 0, .b = 0 } };
    const blue: TextStyle = .{ .fg = .{ .r = 0, .g = 0, .b = 255 } };
    try writeStyledRun(&buf.writer, true, .truecolor, &state, red, "X");
    try writeStyledRun(&buf.writer, true, .truecolor, &state, blue, "Y");
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
    try writeStyledRun(&buf.writer, true, .truecolor, &state, red, "Z");
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
    try writeStyledRun(&buf.writer, false, .truecolor, &state, style, "plain");
    try testing.expectEqualStrings("plain", buf.writer.buffered());
    try testing.expectEqual(@as(?TextStyle, null), state.current);
}

test "writeStyledRun with color_mode=.none emits plain text even when enabled" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var state: StyledState = .{};
    const style: TextStyle = .{ .fg = .{ .r = 255, .g = 0, .b = 0 }, .bold = true };
    try writeStyledRun(&buf.writer, true, .none, &state, style, "plain");
    try testing.expectEqualStrings("plain", buf.writer.buffered());
    try testing.expectEqual(@as(?TextStyle, null), state.current);
}

test "writeStyledRun with color_mode=.ansi16 emits ansi16 fg code not truecolor" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var state: StyledState = .{};
    const style: TextStyle = .{ .fg = .{ .r = 255, .g = 64, .b = 64 } };
    try writeStyledRun(&buf.writer, true, .ansi16, &state, style, "r");
    try flushStyle(&buf.writer, &state);
    const out = buf.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[91m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;") == null);
    try testing.expect(std.mem.indexOf(u8, out, "38;5;") == null);
}

test "writeStyledRun with color_mode=.ansi256 emits 38;5; not 38;2;" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var state: StyledState = .{};
    const style: TextStyle = .{ .fg = .{ .r = 255, .g = 0, .b = 0 } };
    try writeStyledRun(&buf.writer, true, .ansi256, &state, style, "r");
    try flushStyle(&buf.writer, &state);
    const out = buf.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[38;5;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;") == null);
}

test "writeStyled fast path boundary at 256 bytes" {
    const style: TextStyle = .{ .fg = .{ .r = 0, .g = 0, .b = 0 } };

    var buf256: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf256.deinit();
    const text256 = "a" ** 256;
    try writeStyled(&buf256.writer, true, .truecolor, style, text256);
    const out256 = buf256.writer.buffered();

    var buf257: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf257.deinit();
    const text257 = "a" ** 257;
    try writeStyled(&buf257.writer, true, .truecolor, style, text257);
    const out257 = buf257.writer.buffered();

    try testing.expect(std.mem.startsWith(u8, out256, "\x1b[38;2;0;0;0m"));
    try testing.expect(std.mem.endsWith(u8, out256, reset_sequence));
    try testing.expect(std.mem.startsWith(u8, out257, "\x1b[38;2;0;0;0m"));
    try testing.expect(std.mem.endsWith(u8, out257, reset_sequence));

    try testing.expectEqual(out256.len + 1, out257.len);
}
