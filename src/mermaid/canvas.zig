const std = @import("std");
const width_mod = @import("../term/width.zig");
const theme = @import("../term/theme.zig");
const ansi_mod = @import("../term/ansi.zig");

pub const Cell = struct {
    cp: u21 = ' ',
    kind: Kind = .glyph,
    role: ?u8 = null,

    pub const Kind = enum { glyph, continuation };
};

pub const GlyphSet = struct {
    h_line: u21,
    v_line: u21,
    h_line_dashed: u21,
    v_line_dashed: u21,
    corner_tl: u21,
    corner_tr: u21,
    corner_bl: u21,
    corner_br: u21,
    tee_l: u21,
    tee_r: u21,
    tee_t: u21,
    tee_b: u21,
    cross: u21,
    arrow_up: u21,
    arrow_down: u21,
    arrow_left: u21,
    arrow_right: u21,
    diamond_tl: u21,
    diamond_tr: u21,
    diamond_bl: u21,
    diamond_br: u21,
    round_tl: u21,
    round_tr: u21,
    round_bl: u21,
    round_br: u21,
    h_line_double: u21,
    v_line_double: u21,
    corner_tl_double: u21,
    corner_tr_double: u21,
    corner_bl_double: u21,
    corner_br_double: u21,

    pub const unicode: GlyphSet = .{
        .h_line = '─',
        .v_line = '│',
        .h_line_dashed = '╌',
        .v_line_dashed = '╎',
        .corner_tl = '┌',
        .corner_tr = '┐',
        .corner_bl = '└',
        .corner_br = '┘',
        .tee_l = '├',
        .tee_r = '┤',
        .tee_t = '┬',
        .tee_b = '┴',
        .cross = '┼',
        .arrow_up = '▲',
        .arrow_down = '▼',
        .arrow_left = '◄',
        .arrow_right = '►',
        .diamond_tl = '╱',
        .diamond_tr = '╲',
        .diamond_bl = '╲',
        .diamond_br = '╱',
        .round_tl = '╭',
        .round_tr = '╮',
        .round_bl = '╰',
        .round_br = '╯',
        .h_line_double = '═',
        .v_line_double = '║',
        .corner_tl_double = '╔',
        .corner_tr_double = '╗',
        .corner_bl_double = '╚',
        .corner_br_double = '╝',
    };
};

fn flipGlyph(cp: u21) u21 {
    return switch (cp) {
        '┌' => '└',
        '└' => '┌',
        '┐' => '┘',
        '┘' => '┐',
        '┬' => '┴',
        '┴' => '┬',
        '▲' => '▼',
        '▼' => '▲',
        '╭' => '╰',
        '╰' => '╭',
        '╮' => '╯',
        '╯' => '╮',
        '╔' => '╚',
        '╚' => '╔',
        '╗' => '╝',
        '╝' => '╗',
        '╱' => '╲',
        '╲' => '╱',
        '^' => 'v',
        'v' => '^',
        '/' => '\\',
        '\\' => '/',
        else => cp,
    };
}

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    rows: usize,
    cols: usize,

    pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Canvas {
        const cells = try allocator.alloc(Cell, rows * cols);
        @memset(cells, .{});
        return .{
            .allocator = allocator,
            .cells = cells,
            .rows = rows,
            .cols = cols,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.cells);
    }

    pub fn at(self: *Canvas, r: usize, c: usize) *Cell {
        return &self.cells[r * self.cols + c];
    }

    /// Mirror the canvas top-to-bottom and remap vertically-directional glyphs
    /// so arrowheads and corners keep their meaning. Multi-column continuation
    /// cells stay paired with their glyph since the reversal operates on whole
    /// rows.
    pub fn flipVertical(self: *Canvas) void {
        var r: usize = 0;
        while (r < self.rows / 2) : (r += 1) {
            const other = self.rows - 1 - r;
            const top = self.cells[r * self.cols .. r * self.cols + self.cols];
            const bot = self.cells[other * self.cols .. other * self.cols + self.cols];
            for (top, bot) |*t, *b| {
                const tmp = t.*;
                t.* = b.*;
                b.* = tmp;
            }
        }
        for (self.cells) |*cell| {
            if (cell.kind != .glyph) continue;
            cell.cp = flipGlyph(cell.cp);
        }
    }

    pub fn setGlyph(self: *Canvas, r: usize, c: usize, cp: u21) void {
        if (r >= self.rows or c >= self.cols) return;
        self.cells[r * self.cols + c] = .{ .cp = cp, .kind = .glyph };
    }

    pub fn setGlyphRole(self: *Canvas, r: usize, c: usize, cp: u21, role: u8) void {
        if (r >= self.rows or c >= self.cols) return;
        self.cells[r * self.cols + c] = .{ .cp = cp, .kind = .glyph, .role = role };
    }

    pub fn drawCodepoint(self: *Canvas, r: usize, c: usize, cp: u21, ambiguous: width_mod.AmbiguousWidth) void {
        if (r >= self.rows or c >= self.cols) return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        const w = width_mod.displayWidth(buf[0..len], ambiguous);
        std.debug.assert(w != 0);
        const idx = r * self.cols + c;
        self.cells[idx] = .{ .cp = cp, .kind = .glyph };
        if (w == 2) {
            std.debug.assert(c + 1 < self.cols);
            self.cells[idx + 1] = .{ .cp = 0, .kind = .continuation };
        }
    }

    pub fn drawCodepointRole(self: *Canvas, r: usize, c: usize, cp: u21, role: u8, ambiguous: width_mod.AmbiguousWidth) void {
        if (r >= self.rows or c >= self.cols) return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        const w = width_mod.displayWidth(buf[0..len], ambiguous);
        std.debug.assert(w != 0);
        const idx = r * self.cols + c;
        self.cells[idx] = .{ .cp = cp, .kind = .glyph, .role = role };
        if (w == 2) {
            std.debug.assert(c + 1 < self.cols);
            self.cells[idx + 1] = .{ .cp = 0, .kind = .continuation, .role = role };
        }
    }

    pub fn drawLabel(self: *Canvas, r: usize, c: usize, text: []const u8, ambiguous: width_mod.AmbiguousWidth) void {
        var view = std.unicode.Utf8View.init(text) catch return;
        var it = view.iterator();
        var col = c;
        while (it.nextCodepoint()) |cp| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return;
            const w = width_mod.displayWidth(buf[0..len], ambiguous);
            if (w == 0) return;
            self.drawCodepoint(r, col, cp, ambiguous);
            col += w;
        }
    }

    pub fn drawLabelRole(self: *Canvas, r: usize, c: usize, text: []const u8, role: u8, ambiguous: width_mod.AmbiguousWidth) void {
        var view = std.unicode.Utf8View.init(text) catch return;
        var it = view.iterator();
        var col = c;
        while (it.nextCodepoint()) |cp| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return;
            const w = width_mod.displayWidth(buf[0..len], ambiguous);
            if (w == 0) return;
            self.drawCodepointRole(r, col, cp, role, ambiguous);
            col += w;
        }
    }

    pub fn drawRect(self: *Canvas, top: usize, left: usize, h: usize, w: usize, glyphs: *const GlyphSet) void {
        if (h < 2 or w < 2) return;
        self.setGlyph(top, left, glyphs.corner_tl);
        self.setGlyph(top, left + w - 1, glyphs.corner_tr);
        self.setGlyph(top + h - 1, left, glyphs.corner_bl);
        self.setGlyph(top + h - 1, left + w - 1, glyphs.corner_br);

        var c = left + 1;
        while (c + 1 < left + w) : (c += 1) {
            self.setGlyph(top, c, glyphs.h_line);
            self.setGlyph(top + h - 1, c, glyphs.h_line);
        }
        var r = top + 1;
        while (r + 1 < top + h) : (r += 1) {
            self.setGlyph(r, left, glyphs.v_line);
            self.setGlyph(r, left + w - 1, glyphs.v_line);
        }
    }

    pub fn drawRoundBox(self: *Canvas, top: usize, left: usize, h: usize, w: usize, glyphs: *const GlyphSet) void {
        if (h < 2 or w < 2) return;
        self.setGlyph(top, left, glyphs.round_tl);
        self.setGlyph(top, left + w - 1, glyphs.round_tr);
        self.setGlyph(top + h - 1, left, glyphs.round_bl);
        self.setGlyph(top + h - 1, left + w - 1, glyphs.round_br);

        var c = left + 1;
        while (c + 1 < left + w) : (c += 1) {
            self.setGlyph(top, c, glyphs.h_line);
            self.setGlyph(top + h - 1, c, glyphs.h_line);
        }
        var r = top + 1;
        while (r + 1 < top + h) : (r += 1) {
            self.setGlyph(r, left, glyphs.v_line);
            self.setGlyph(r, left + w - 1, glyphs.v_line);
        }
    }

    pub fn drawDoubleBox(self: *Canvas, top: usize, left: usize, h: usize, w: usize, glyphs: *const GlyphSet) void {
        if (h < 2 or w < 2) return;
        self.setGlyph(top, left, glyphs.corner_tl_double);
        self.setGlyph(top, left + w - 1, glyphs.corner_tr_double);
        self.setGlyph(top + h - 1, left, glyphs.corner_bl_double);
        self.setGlyph(top + h - 1, left + w - 1, glyphs.corner_br_double);

        var c = left + 1;
        while (c + 1 < left + w) : (c += 1) {
            self.setGlyph(top, c, glyphs.h_line_double);
            self.setGlyph(top + h - 1, c, glyphs.h_line_double);
        }
        var r = top + 1;
        while (r + 1 < top + h) : (r += 1) {
            self.setGlyph(r, left, glyphs.v_line_double);
            self.setGlyph(r, left + w - 1, glyphs.v_line_double);
        }
    }

    pub fn drawCylinderBox(self: *Canvas, top: usize, left: usize, h: usize, w: usize, glyphs: *const GlyphSet) void {
        self.drawRect(top, left, h, w, glyphs);
        if (h < 4) return;
        const divider_row = top + 1;
        var c = left + 1;
        while (c + 1 < left + w) : (c += 1) {
            self.setGlyph(divider_row, c, glyphs.h_line);
        }
        self.setGlyph(divider_row, left, glyphs.tee_l);
        self.setGlyph(divider_row, left + w - 1, glyphs.tee_r);
    }

    pub fn drawHexagonBox(self: *Canvas, top: usize, left: usize, h: usize, w: usize, glyphs: *const GlyphSet) void {
        self.drawRect(top, left, h, w, glyphs);
        if (h < 2 or w < 2) return;
        self.setGlyph(top, left, glyphs.diamond_tl);
        self.setGlyph(top, left + w - 1, glyphs.diamond_tr);
        self.setGlyph(top + h - 1, left, glyphs.diamond_bl);
        self.setGlyph(top + h - 1, left + w - 1, glyphs.diamond_br);
    }

    pub fn drawAsymmetricBox(self: *Canvas, top: usize, left: usize, h: usize, w: usize, glyphs: *const GlyphSet) void {
        self.drawRect(top, left, h, w, glyphs);
        if (h < 2 or w < 2) return;
        var r = top;
        while (r < top + h) : (r += 1) {
            self.setGlyph(r, left, '>');
        }
    }

    pub fn drawDiamondBox(self: *Canvas, top: usize, left: usize, h: usize, w: usize, glyphs: *const GlyphSet) void {
        if (h < 2 or w < 2) return;
        self.setGlyph(top, left, glyphs.diamond_tl);
        self.setGlyph(top, left + w - 1, glyphs.diamond_tr);
        self.setGlyph(top + h - 1, left, glyphs.diamond_bl);
        self.setGlyph(top + h - 1, left + w - 1, glyphs.diamond_br);

        var c = left + 1;
        while (c + 1 < left + w) : (c += 1) {
            self.setGlyph(top, c, glyphs.h_line);
            self.setGlyph(top + h - 1, c, glyphs.h_line);
        }
        var r = top + 1;
        while (r + 1 < top + h) : (r += 1) {
            self.setGlyph(r, left, glyphs.v_line);
            self.setGlyph(r, left + w - 1, glyphs.v_line);
        }
    }
};

pub fn writeCanvas(
    writer: *std.Io.Writer,
    canvas: *const Canvas,
    wrap_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
) !void {
    if (canvas.rows == 0) return;

    const ellipsis = "\u{2026}";
    const ellipsis_w = width_mod.displayWidth(ellipsis, ambiguous);

    const do_clip = blk: {
        const w = wrap_width orelse break :blk false;
        if (w <= ellipsis_w) break :blk false;
        if (canvas.cols <= w) break :blk false;
        break :blk true;
    };

    var r: usize = 0;
    while (r < canvas.rows) : (r += 1) {
        if (r > 0) try writer.writeByte('\n');
        if (do_clip) {
            const budget = wrap_width.? - ellipsis_w;
            var cut = budget;
            if (cut < canvas.cols and canvas.cells[r * canvas.cols + cut].kind == .continuation) {
                cut -= 1;
            }
            try writeRow(writer, canvas, r, cut);
            const pad = budget - cut;
            var p: usize = 0;
            while (p < pad) : (p += 1) try writer.writeByte(' ');
            try writer.writeAll(ellipsis);
        } else {
            try writeRow(writer, canvas, r, canvas.cols);
        }
    }
}

pub fn writeCanvasAnsi(
    writer: *std.Io.Writer,
    canvas: *const Canvas,
    wrap_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
    role_colors: []const theme.Rgb,
    mode: ansi_mod.ColorMode,
) !void {
    if (mode == .none or role_colors.len == 0) {
        return writeCanvas(writer, canvas, wrap_width, ambiguous);
    }
    if (canvas.rows == 0) return;

    const ellipsis = "\u{2026}";
    const ellipsis_w = width_mod.displayWidth(ellipsis, ambiguous);

    const do_clip = blk: {
        const w = wrap_width orelse break :blk false;
        if (w <= ellipsis_w) break :blk false;
        if (canvas.cols <= w) break :blk false;
        break :blk true;
    };

    var r: usize = 0;
    while (r < canvas.rows) : (r += 1) {
        if (r > 0) try writer.writeByte('\n');
        if (do_clip) {
            const budget = wrap_width.? - ellipsis_w;
            var cut = budget;
            if (cut < canvas.cols and canvas.cells[r * canvas.cols + cut].kind == .continuation) {
                cut -= 1;
            }
            try writeRowAnsi(writer, canvas, r, cut, role_colors, mode);
            const pad = budget - cut;
            var p: usize = 0;
            while (p < pad) : (p += 1) try writer.writeByte(' ');
            try writer.writeAll(ellipsis);
        } else {
            try writeRowAnsi(writer, canvas, r, canvas.cols, role_colors, mode);
        }
    }
}

fn writeRowAnsi(
    writer: *std.Io.Writer,
    canvas: *const Canvas,
    r: usize,
    cols: usize,
    role_colors: []const theme.Rgb,
    mode: ansi_mod.ColorMode,
) !void {
    var last_nonspace: usize = 0;
    var c: usize = 0;
    while (c < cols) : (c += 1) {
        const cell = canvas.cells[r * canvas.cols + c];
        if (cell.kind == .glyph and cell.cp != ' ') last_nonspace = c + 1;
    }

    var current_role: ?u8 = null;
    c = 0;
    while (c < last_nonspace) : (c += 1) {
        const cell = canvas.cells[r * canvas.cols + c];
        switch (cell.kind) {
            .glyph => {
                const effective: ?u8 = if (cell.role) |rl|
                    (if (rl < role_colors.len) rl else null)
                else
                    null;
                if (!rolesEqual(current_role, effective)) {
                    if (current_role != null) try writer.writeAll(ansi_mod.reset_sequence);
                    if (effective) |rl| try ansi_mod.writeSgrFg(writer, role_colors[rl], mode);
                    current_role = effective;
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.cp, &buf) catch continue;
                try writer.writeAll(buf[0..len]);
            },
            .continuation => {},
        }
    }
    if (current_role != null) try writer.writeAll(ansi_mod.reset_sequence);
}

fn rolesEqual(a: ?u8, b: ?u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

fn writeRow(writer: *std.Io.Writer, canvas: *const Canvas, r: usize, cols: usize) !void {
    var last_nonspace: usize = 0;
    var c: usize = 0;
    while (c < cols) : (c += 1) {
        const cell = canvas.cells[r * canvas.cols + c];
        if (cell.kind == .glyph and cell.cp != ' ') last_nonspace = c + 1;
    }

    c = 0;
    while (c < last_nonspace) : (c += 1) {
        const cell = canvas.cells[r * canvas.cols + c];
        switch (cell.kind) {
            .glyph => {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.cp, &buf) catch continue;
                try writer.writeAll(buf[0..len]);
            },
            .continuation => {},
        }
    }
}

fn expectCanvasOutput(canvas: *const Canvas, expected: []const u8) !void {
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try writeCanvas(&sink.writer, canvas, null, .narrow);
    try std.testing.expectEqualStrings(expected, sink.writer.buffered());
}

test "Cell defaults role to null" {
    const cell: Cell = .{};
    try std.testing.expectEqual(@as(?u8, null), cell.role);
}

test "drawCodepointRole stores role alongside codepoint" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 4);
    defer canvas.deinit();
    canvas.drawCodepointRole(0, 0, 'A', 3, .narrow);
    try std.testing.expectEqual(@as(u21, 'A'), canvas.at(0, 0).cp);
    try std.testing.expectEqual(@as(?u8, 3), canvas.at(0, 0).role);
}

test "writeCanvasAnsi wraps single role cell with SGR and reset" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 2);
    defer canvas.deinit();
    canvas.drawCodepointRole(0, 0, 'X', 0, .narrow);
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const colors = [_]theme.Rgb{.{ .r = 0, .g = 255, .b = 0 }};
    try writeCanvasAnsi(&sink.writer, &canvas, null, .narrow, &colors, .truecolor);
    try std.testing.expectEqualStrings("\x1b[38;2;0;255;0mX\x1b[0m", sink.writer.buffered());
}

test "writeCanvasAnsi groups consecutive same-role cells under single SGR prefix" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 4);
    defer canvas.deinit();
    canvas.drawCodepointRole(0, 0, 'A', 0, .narrow);
    canvas.drawCodepointRole(0, 1, 'B', 0, .narrow);
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const colors = [_]theme.Rgb{.{ .r = 255, .g = 0, .b = 0 }};
    try writeCanvasAnsi(&sink.writer, &canvas, null, .narrow, &colors, .truecolor);
    try std.testing.expectEqualStrings("\x1b[38;2;255;0;0mAB\x1b[0m", sink.writer.buffered());
}

test "writeCanvasAnsi in none mode equals plain writeCanvas" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 4);
    defer canvas.deinit();
    canvas.drawCodepointRole(0, 0, 'A', 0, .narrow);
    canvas.drawCodepoint(0, 1, 'B', .narrow);
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const colors = [_]theme.Rgb{.{ .r = 0, .g = 0, .b = 0 }};
    try writeCanvasAnsi(&sink.writer, &canvas, null, .narrow, &colors, .none);
    try std.testing.expectEqualStrings("AB", sink.writer.buffered());
}

test "writeCanvasAnsi clips to wrap_width with trailing ellipsis" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 40);
    defer canvas.deinit();
    canvas.drawCodepointRole(0, 0, 'X', 0, .narrow);
    var c: usize = 1;
    while (c < 40) : (c += 1) canvas.drawCodepoint(0, c, '.', .narrow);
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const colors = [_]theme.Rgb{.{ .r = 255, .g = 0, .b = 0 }};
    try writeCanvasAnsi(&sink.writer, &canvas, 20, .narrow, &colors, .truecolor);
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, out, "\u{2026}"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;255;0;0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null);
    const reset_pos = std.mem.indexOf(u8, out, "\x1b[0m").?;
    const ellipsis_pos = std.mem.indexOf(u8, out, "\u{2026}").?;
    try std.testing.expect(reset_pos < ellipsis_pos);
}

test "writeCanvas clips over-wide plain rows with trailing ellipsis" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 12);
    defer canvas.deinit();
    canvas.drawLabel(0, 0, "abcdefghijkl", .narrow);

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try writeCanvas(&sink.writer, &canvas, 5, .narrow);

    try std.testing.expectEqualStrings("abcd\u{2026}", sink.writer.buffered());
}

test "writeCanvasAnsi clips over-wide rows and resets before ellipsis" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 12);
    defer canvas.deinit();
    var c: usize = 0;
    while (c < 12) : (c += 1) canvas.drawCodepointRole(0, c, 'R', 0, .narrow);

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const colors = [_]theme.Rgb{.{ .r = 255, .g = 0, .b = 0 }};
    try writeCanvasAnsi(&sink.writer, &canvas, 5, .narrow, &colors, .truecolor);

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, out, "\u{2026}"));
    const reset_pos = std.mem.lastIndexOf(u8, out, ansi_mod.reset_sequence).?;
    const ellipsis_pos = std.mem.indexOf(u8, out, "\u{2026}").?;
    try std.testing.expect(reset_pos < ellipsis_pos);
}

test "writeCanvasAnsi with wrap_width null emits full-width output unchanged" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 40);
    defer canvas.deinit();
    canvas.drawCodepointRole(0, 0, 'X', 0, .narrow);
    var c: usize = 1;
    while (c < 40) : (c += 1) canvas.drawCodepoint(0, c, '.', .narrow);
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const colors = [_]theme.Rgb{.{ .r = 255, .g = 0, .b = 0 }};
    try writeCanvasAnsi(&sink.writer, &canvas, null, .narrow, &colors, .truecolor);
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{2026}") == null);
    try std.testing.expect(std.mem.count(u8, out, ".") == 39);
    try std.testing.expect(std.mem.indexOf(u8, out, "X") != null);
}

test "writeCanvasAnsi clip path emits reset before ellipsis for colored last cell" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 40);
    defer canvas.deinit();
    var c: usize = 0;
    while (c < 40) : (c += 1) canvas.drawCodepointRole(0, c, 'R', 0, .narrow);
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const colors = [_]theme.Rgb{.{ .r = 255, .g = 0, .b = 0 }};
    try writeCanvasAnsi(&sink.writer, &canvas, 20, .narrow, &colors, .truecolor);
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, out, "\u{2026}"));
    const last_reset = std.mem.lastIndexOf(u8, out, "\x1b[0m").?;
    const ellipsis_pos = std.mem.indexOf(u8, out, "\u{2026}").?;
    try std.testing.expect(last_reset < ellipsis_pos);
}

test "writeCanvasAnsi with wrap_width larger than cols does not clip" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 10);
    defer canvas.deinit();
    var c: usize = 0;
    while (c < 10) : (c += 1) canvas.drawCodepointRole(0, c, 'A', 0, .narrow);
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const colors = [_]theme.Rgb{.{ .r = 0, .g = 128, .b = 0 }};
    try writeCanvasAnsi(&sink.writer, &canvas, 100, .narrow, &colors, .truecolor);
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{2026}") == null);
    try std.testing.expect(std.mem.count(u8, out, "A") == 10);
}

test "writeCanvasAnsi with wrap_width leq ellipsis width does not clip" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 10);
    defer canvas.deinit();
    var c: usize = 0;
    while (c < 10) : (c += 1) canvas.drawCodepointRole(0, c, 'B', 0, .narrow);
    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const colors = [_]theme.Rgb{.{ .r = 0, .g = 0, .b = 128 }};
    try writeCanvasAnsi(&sink.writer, &canvas, 1, .narrow, &colors, .truecolor);
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\u{2026}") == null);
    try std.testing.expect(std.mem.count(u8, out, "B") == 10);

    var sink_zero: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink_zero.deinit();
    try writeCanvasAnsi(&sink_zero.writer, &canvas, 0, .narrow, &colors, .truecolor);
    try std.testing.expect(std.mem.indexOf(u8, sink_zero.writer.buffered(), "\u{2026}") == null);
    try std.testing.expect(std.mem.count(u8, sink_zero.writer.buffered(), "B") == 10);
}

test "flipVertical reverses rows and remaps directional glyphs" {
    var canvas = try Canvas.init(std.testing.allocator, 3, 3);
    defer canvas.deinit();
    canvas.setGlyph(0, 0, '┌');
    canvas.setGlyph(0, 1, '┬');
    canvas.setGlyph(0, 2, '┐');
    canvas.setGlyph(1, 1, '▼');
    canvas.setGlyph(2, 0, '└');
    canvas.setGlyph(2, 2, '┘');

    canvas.flipVertical();

    try std.testing.expectEqual(@as(u21, '┌'), canvas.at(0, 0).cp);
    try std.testing.expectEqual(@as(u21, '┐'), canvas.at(0, 2).cp);
    try std.testing.expectEqual(@as(u21, '▲'), canvas.at(1, 1).cp);
    try std.testing.expectEqual(@as(u21, '└'), canvas.at(2, 0).cp);
    try std.testing.expectEqual(@as(u21, '┴'), canvas.at(2, 1).cp);
    try std.testing.expectEqual(@as(u21, '┘'), canvas.at(2, 2).cp);
}

test "flipVertical roundtrip restores original canvas" {
    var canvas = try Canvas.init(std.testing.allocator, 2, 2);
    defer canvas.deinit();
    canvas.setGlyph(0, 0, '╭');
    canvas.setGlyph(0, 1, '╮');
    canvas.setGlyph(1, 0, '╰');
    canvas.setGlyph(1, 1, '╯');

    canvas.flipVertical();
    canvas.flipVertical();

    try std.testing.expectEqual(@as(u21, '╭'), canvas.at(0, 0).cp);
    try std.testing.expectEqual(@as(u21, '╮'), canvas.at(0, 1).cp);
    try std.testing.expectEqual(@as(u21, '╰'), canvas.at(1, 0).cp);
    try std.testing.expectEqual(@as(u21, '╯'), canvas.at(1, 1).cp);
}

test "Canvas initializes cells to blank glyphs" {
    var canvas = try Canvas.init(std.testing.allocator, 3, 4);
    defer canvas.deinit();
    try std.testing.expectEqual(@as(usize, 3), canvas.rows);
    try std.testing.expectEqual(@as(usize, 4), canvas.cols);
    try std.testing.expectEqual(@as(u21, ' '), canvas.at(0, 0).cp);
    try std.testing.expectEqual(Cell.Kind.glyph, canvas.at(2, 3).kind);
}

test "drawCodepoint places a narrow glyph" {
    var canvas = try Canvas.init(std.testing.allocator, 2, 4);
    defer canvas.deinit();
    canvas.drawCodepoint(0, 0, 'A', .narrow);
    try std.testing.expectEqual(@as(u21, 'A'), canvas.at(0, 0).cp);
    try std.testing.expectEqual(Cell.Kind.glyph, canvas.at(0, 0).kind);
}

test "drawCodepoint places wide char and continuation sentinel" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 4);
    defer canvas.deinit();
    canvas.drawCodepoint(0, 0, '日', .narrow);
    try std.testing.expectEqual(@as(u21, '日'), canvas.at(0, 0).cp);
    try std.testing.expectEqual(Cell.Kind.glyph, canvas.at(0, 0).kind);
    try std.testing.expectEqual(Cell.Kind.continuation, canvas.at(0, 1).kind);
}

test "drawLabel advances by display width" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 8);
    defer canvas.deinit();
    canvas.drawLabel(0, 0, "日A", .narrow);
    try std.testing.expectEqual(@as(u21, '日'), canvas.at(0, 0).cp);
    try std.testing.expectEqual(Cell.Kind.continuation, canvas.at(0, 1).kind);
    try std.testing.expectEqual(@as(u21, 'A'), canvas.at(0, 2).cp);
}

test "writeCanvas skips continuation cells" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 4);
    defer canvas.deinit();
    canvas.drawCodepoint(0, 0, '日', .narrow);
    try expectCanvasOutput(&canvas, "日");
}

test "writeCanvas trims trailing spaces after wide char" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 6);
    defer canvas.deinit();
    canvas.drawCodepoint(0, 0, '日', .narrow);
    try expectCanvasOutput(&canvas, "日");
}

test "writeCanvas emits box drawing via drawRect" {
    var canvas = try Canvas.init(std.testing.allocator, 3, 5);
    defer canvas.deinit();
    canvas.drawRect(0, 0, 3, 5, &GlyphSet.unicode);
    try expectCanvasOutput(&canvas, "┌───┐\n│   │\n└───┘");
}

test "writeCanvas clipping never splits a wide glyph" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 10);
    defer canvas.deinit();
    canvas.drawCodepoint(0, 0, 'A', .narrow);
    canvas.drawCodepoint(0, 1, 'B', .narrow);
    canvas.drawCodepoint(0, 2, 'C', .narrow);
    canvas.drawCodepoint(0, 3, '日', .narrow);
    canvas.drawCodepoint(0, 5, 'D', .narrow);

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try writeCanvas(&sink.writer, &canvas, 5, .narrow);
    try std.testing.expectEqualStrings("ABC …", sink.writer.buffered());
}

test "writeCanvas skips clipping for degenerate wrap_width" {
    var canvas = try Canvas.init(std.testing.allocator, 1, 10);
    defer canvas.deinit();
    canvas.drawCodepoint(0, 0, 'A', .narrow);
    canvas.drawCodepoint(0, 1, 'B', .narrow);
    canvas.drawCodepoint(0, 2, 'C', .narrow);

    var sink_zero: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink_zero.deinit();
    try writeCanvas(&sink_zero.writer, &canvas, 0, .narrow);
    try std.testing.expectEqualStrings("ABC", sink_zero.writer.buffered());

    var sink_one: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink_one.deinit();
    try writeCanvas(&sink_one.writer, &canvas, 1, .narrow);
    try std.testing.expectEqualStrings("ABC", sink_one.writer.buffered());
}
