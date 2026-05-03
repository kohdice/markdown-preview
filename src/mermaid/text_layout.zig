const std = @import("std");
const canvas_mod = @import("canvas.zig");
const types = @import("types.zig");
const width_mod = @import("../term/width.zig");

pub const LabelLayout = struct {
    allocator: std.mem.Allocator,
    backing: []u8,
    lines: []types.LabelLine,
    max_line_width: usize,

    pub fn deinit(self: *LabelLayout) void {
        self.allocator.free(self.backing);
        self.allocator.free(self.lines);
    }
};

pub fn edgeLabelWrapWidth(canvas_cols: usize) usize {
    if (canvas_cols <= 8) return canvas_cols;
    return @max(@as(usize, 6), canvas_cols / 2);
}

const Range = struct {
    start: usize,
    end: usize,
    width: usize,
};

pub fn layoutLabel(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
) !LabelLayout {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(allocator);

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    var line_width: usize = 0;
    var last_space: ?usize = null;
    var max_line_width: usize = 0;

    var i: usize = 0;
    while (i < text.len) {
        if (hardBreakLen(text, i)) |n| {
            try appendLine(allocator, &out, &ranges, line.items, ambiguous, &max_line_width);
            line.clearRetainingCapacity();
            line_width = 0;
            last_space = null;
            i += n;
            continue;
        }

        var it = width_mod.DisplayClusterIterator.init(text[i..], ambiguous);
        const cluster = it.next() orelse break;
        i += cluster.bytes.len;

        const budget = max_width orelse 0;
        if (budget > 0) {
            var skip_cluster = false;
            while (line_width + cluster.width > budget) {
                if (isAsciiSpace(cluster.bytes)) {
                    try appendLine(allocator, &out, &ranges, line.items, ambiguous, &max_line_width);
                    line.clearRetainingCapacity();
                    line_width = 0;
                    last_space = null;
                    skip_cluster = true;
                    break;
                }

                if (last_space) |space_idx| {
                    const suffix = line.items[space_idx + 1 ..];
                    try appendLine(allocator, &out, &ranges, line.items[0..space_idx], ambiguous, &max_line_width);

                    const suffix_len = suffix.len;
                    @memmove(line.items[0..suffix_len], suffix);
                    line.shrinkRetainingCapacity(suffix_len);
                    line_width = width_mod.displayWidth(line.items, ambiguous);
                    last_space = std.mem.findScalarLast(u8, line.items, ' ');
                    continue;
                }

                if (line.items.len > 0) {
                    try appendLine(allocator, &out, &ranges, line.items, ambiguous, &max_line_width);
                    line.clearRetainingCapacity();
                    line_width = 0;
                    last_space = null;
                    continue;
                }

                break;
            }
            if (skip_cluster) continue;
        }

        if (isAsciiSpace(cluster.bytes) and line.items.len == 0) continue;
        if (isAsciiSpace(cluster.bytes)) last_space = line.items.len;
        try line.appendSlice(allocator, cluster.bytes);
        line_width += cluster.width;
    }

    try appendLine(allocator, &out, &ranges, line.items, ambiguous, &max_line_width);

    const backing = try out.toOwnedSlice(allocator);
    errdefer allocator.free(backing);

    const lines = try allocator.alloc(types.LabelLine, ranges.items.len);
    errdefer allocator.free(lines);
    for (ranges.items, 0..) |range, idx| {
        lines[idx] = .{
            .text = backing[range.start..range.end],
            .width = range.width,
        };
    }

    return .{
        .allocator = allocator,
        .backing = backing,
        .lines = lines,
        .max_line_width = max_line_width,
    };
}

pub fn drawCenteredLabel(
    canvas: *canvas_mod.Canvas,
    top: usize,
    left: usize,
    height: usize,
    width: usize,
    lines: []const types.LabelLine,
    ambiguous: width_mod.AmbiguousWidth,
) std.mem.Allocator.Error!void {
    if (height == 0 or width == 0 or lines.len == 0) return;
    const visible_lines = @min(height, lines.len);
    const row_offset = (height - visible_lines) / 2;

    for (lines[0..visible_lines], 0..) |line, idx| {
        const col_offset = if (width > line.width) (width - line.width) / 2 else 0;
        try canvas.drawLabel(top + row_offset + idx, left + col_offset, line.text, ambiguous);
    }
}

fn appendLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    ranges: *std.ArrayList(Range),
    line: []const u8,
    ambiguous: width_mod.AmbiguousWidth,
    max_line_width: *usize,
) !void {
    const start = out.items.len;
    try out.appendSlice(allocator, line);
    const end = out.items.len;
    const line_width = width_mod.displayWidth(line, ambiguous);
    max_line_width.* = @max(max_line_width.*, line_width);
    try ranges.append(allocator, .{
        .start = start,
        .end = end,
        .width = line_width,
    });
}

fn hardBreakLen(text: []const u8, i: usize) ?usize {
    if (text[i] == '\n') return 1;
    if (i + 1 < text.len and text[i] == '\\' and text[i + 1] == 'n') return 2;
    if (text[i] == '<') return types.brTagLen(text, i);
    return null;
}

fn isAsciiSpace(text: []const u8) bool {
    return text.len == 1 and text[0] == ' ';
}

fn expectLines(layout: *const LabelLayout, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, layout.lines.len);
    for (expected, 0..) |line, idx| {
        try std.testing.expectEqualStrings(line, layout.lines[idx].text);
    }
}

test "layoutLabel turns Mermaid hard breaks into rendered lines" {
    const allocator = std.testing.allocator;
    var layout = try layoutLabel(allocator, "one<br/>two<br>three<BR>four\nfive\\nsix", null, .narrow);
    defer layout.deinit();

    try expectLines(&layout, &.{ "one", "two", "three", "four", "five", "six" });
}

test "layoutLabel wraps ASCII text by display width without losing words" {
    const allocator = std.testing.allocator;
    var layout = try layoutLabel(allocator, "Alpha beta gamma", 10, .narrow);
    defer layout.deinit();

    try expectLines(&layout, &.{ "Alpha beta", "gamma" });
}

test "layoutLabel wraps CJK text without splitting UTF-8 sequences" {
    const allocator = std.testing.allocator;
    var layout = try layoutLabel(allocator, "日本語文字", 4, .narrow);
    defer layout.deinit();

    try expectLines(&layout, &.{ "日本", "語文", "字" });
}

test "layoutLabel splits unbreakable tokens at display-cluster boundaries" {
    const allocator = std.testing.allocator;
    var layout = try layoutLabel(allocator, "abcdefgh", 3, .narrow);
    defer layout.deinit();

    try expectLines(&layout, &.{ "abc", "def", "gh" });
}

test "layoutLabel keeps zero-width display clusters intact while wrapping" {
    const allocator = std.testing.allocator;

    var acute = try layoutLabel(allocator, "e\u{0301}e\u{0301}", 1, .narrow);
    defer acute.deinit();
    try expectLines(&acute, &.{ "e\u{0301}", "e\u{0301}" });

    var heart = try layoutLabel(allocator, "\u{2764}\u{FE0F}\u{2764}\u{FE0F}", 1, .narrow);
    defer heart.deinit();
    try expectLines(&heart, &.{ "\u{2764}\u{FE0F}", "\u{2764}\u{FE0F}" });

    var tone = try layoutLabel(allocator, "\u{1F44B}\u{1F3FD}\u{1F44B}\u{1F3FD}", 2, .narrow);
    defer tone.deinit();
    try expectLines(&tone, &.{ "\u{1F44B}\u{1F3FD}", "\u{1F44B}\u{1F3FD}" });

    var zwj = try layoutLabel(allocator, "\u{1F468}\u{200D}\u{1F469}\u{1F468}\u{200D}\u{1F469}", 2, .narrow);
    defer zwj.deinit();
    try expectLines(&zwj, &.{ "\u{1F468}\u{200D}\u{1F469}", "\u{1F468}\u{200D}\u{1F469}" });
}

test "layoutLabel reports line widths and maximum width for ambiguous-width modes" {
    const allocator = std.testing.allocator;

    var narrow = try layoutLabel(allocator, "ΩΩ", null, .narrow);
    defer narrow.deinit();
    try std.testing.expectEqual(@as(usize, 2), narrow.lines[0].width);
    try std.testing.expectEqual(@as(usize, 2), narrow.max_line_width);

    var wide = try layoutLabel(allocator, "ΩΩ", null, .wide);
    defer wide.deinit();
    try std.testing.expectEqual(@as(usize, 4), wide.lines[0].width);
    try std.testing.expectEqual(@as(usize, 4), wide.max_line_width);
}

test "layoutLabel converts raw flowchart br tags to multiline text" {
    const parse_flowchart = @import("parse_flowchart.zig");
    const allocator = std.testing.allocator;
    var graph = try parse_flowchart.parse(allocator,
        \\graph TD
        \\    A[first<br/>second<br>third<BR>fourth]
    );
    defer graph.deinit();

    var layout = try layoutLabel(allocator, graph.nodes[0].label, null, .narrow);
    defer layout.deinit();

    try expectLines(&layout, &.{ "first", "second", "third", "fourth" });
}

test "drawCenteredLabel centers multiline labels inside a fixed rectangle" {
    const allocator = std.testing.allocator;
    var layout = try layoutLabel(allocator, "hi\nthere", null, .narrow);
    defer layout.deinit();

    var canvas = try canvas_mod.Canvas.init(allocator, 4, 8);
    defer canvas.deinit();

    try drawCenteredLabel(&canvas, 0, 0, 4, 8, layout.lines, .narrow);

    var sink: std.Io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    try canvas_mod.writeCanvas(&sink.writer, &canvas, null, .narrow);

    try std.testing.expectEqualStrings("\n   hi\n there\n", sink.writer.buffered());
}
