const std = @import("std");
const width_mod = @import("../term/width.zig");

pub const Cell = struct {
    cp: u21 = ' ',
    kind: Kind = .glyph,

    pub const Kind = enum { glyph, continuation };
};

pub const GlyphSet = struct {
    h_line: u21,
    v_line: u21,
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

    pub const unicode: GlyphSet = .{
        .h_line = '─',
        .v_line = '│',
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
    };
};

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

    pub fn setGlyph(self: *Canvas, r: usize, c: usize, cp: u21) void {
        if (r >= self.rows or c >= self.cols) return;
        self.cells[r * self.cols + c] = .{ .cp = cp, .kind = .glyph };
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
    writer: *std.io.Writer,
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

fn writeRow(writer: *std.io.Writer, canvas: *const Canvas, r: usize, cols: usize) !void {
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
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try writeCanvas(&sink.writer, canvas, null, .narrow);
    try std.testing.expectEqualStrings(expected, sink.writer.buffered());
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

    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
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

    var sink_zero: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink_zero.deinit();
    try writeCanvas(&sink_zero.writer, &canvas, 0, .narrow);
    try std.testing.expectEqualStrings("ABC", sink_zero.writer.buffered());

    var sink_one: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink_one.deinit();
    try writeCanvas(&sink_one.writer, &canvas, 1, .narrow);
    try std.testing.expectEqualStrings("ABC", sink_one.writer.buffered());
}
