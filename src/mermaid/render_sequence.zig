const std = @import("std");
const types = @import("types.zig");
const parse = @import("parse_sequence.zig");
const canvas_mod = @import("canvas.zig");
const route_mod = @import("route.zig");
const width_mod = @import("../term/width.zig");

pub const RenderError = error{
    InvalidMermaid,
    OutOfMemory,
    WriteFailed,
};

pub const Options = struct {
    wrap_width: ?usize,
    ambiguous_width: width_mod.AmbiguousWidth,
};

const box_h: usize = 3;
const message_spacing: usize = 2;
const min_arrow_span: usize = 6;

pub fn writeSequence(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    var diagram = parse.parseSource(allocator, source) catch |err| switch (err) {
        error.InvalidMermaid, error.TooManyParticipants => return error.InvalidMermaid,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer diagram.deinit();

    if (diagram.participants.len == 0) return;

    const glyphs = canvas_mod.GlyphSet.unicode;

    const label_w = computeMaxLabelWidth(&diagram, opts.ambiguous_width);
    const cell_w = @max(label_w + 4, 6);
    const gap_w = computeGap(&diagram, cell_w, opts.ambiguous_width);
    const step_w = cell_w + gap_w;

    const n_participants = diagram.participants.len;
    const n_messages = diagram.messages.len;

    const top_box_rows = box_h;
    const body_rows = if (n_messages == 0) 1 else n_messages * message_spacing + 2;
    const bottom_box_rows = box_h;
    const total_rows = top_box_rows + body_rows + bottom_box_rows;
    const total_cols = n_participants * cell_w + (n_participants - 1) * gap_w;

    var canvas = canvas_mod.Canvas.init(allocator, total_rows, total_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    drawParticipantBoxes(&canvas, &diagram, cell_w, step_w, 0, &glyphs, opts.ambiguous_width);
    drawParticipantBoxes(&canvas, &diagram, cell_w, step_w, top_box_rows + body_rows, &glyphs, opts.ambiguous_width);
    drawLifelines(&canvas, n_participants, cell_w, step_w, top_box_rows, body_rows, &glyphs);
    drawMessages(&canvas, &diagram, cell_w, step_w, top_box_rows, &glyphs, opts.ambiguous_width);

    route_mod.mergeJunctions(allocator, &canvas, &glyphs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
}

fn computeMaxLabelWidth(diagram: *const types.SequenceDiagram, ambiguous: width_mod.AmbiguousWidth) usize {
    var max_w: usize = 0;
    for (diagram.participants) |p| {
        max_w = @max(max_w, width_mod.displayWidth(p.label, ambiguous));
    }
    return max_w;
}

fn computeGap(diagram: *const types.SequenceDiagram, cell_w: usize, ambiguous: width_mod.AmbiguousWidth) usize {
    var max_msg: usize = min_arrow_span;
    for (diagram.messages) |m| {
        const span = columnSpan(m.from, m.to);
        const w = width_mod.displayWidth(m.label, ambiguous);
        const needed_per_gap = if (span == 0) w + 4 else (w + 4 + span - 1) / span;
        max_msg = @max(max_msg, needed_per_gap);
    }
    _ = cell_w;
    return @max(max_msg, min_arrow_span);
}

fn columnSpan(a: types.ParticipantId, b: types.ParticipantId) usize {
    const lo = @min(a, b);
    const hi = @max(a, b);
    return hi - lo;
}

fn participantCenter(index: types.ParticipantId, cell_w: usize, step_w: usize) usize {
    const left = @as(usize, @intCast(index)) * step_w;
    return left + cell_w / 2;
}

fn drawParticipantBoxes(
    canvas: *canvas_mod.Canvas,
    diagram: *const types.SequenceDiagram,
    cell_w: usize,
    step_w: usize,
    top_row: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) void {
    for (diagram.participants, 0..) |p, i| {
        const left = i * step_w;
        canvas.drawRect(top_row, left, box_h, cell_w, glyphs);
        const label_w = width_mod.displayWidth(p.label, ambiguous);
        const inner = cell_w - 2;
        const offset = if (inner > label_w) (inner - label_w) / 2 else 0;
        canvas.drawLabel(top_row + 1, left + 1 + offset, p.label, ambiguous);
    }
}

fn drawLifelines(
    canvas: *canvas_mod.Canvas,
    n_participants: usize,
    cell_w: usize,
    step_w: usize,
    top_box_rows: usize,
    body_rows: usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    const start_row = top_box_rows;
    const end_row = start_row + body_rows;
    var i: usize = 0;
    while (i < n_participants) : (i += 1) {
        const center = participantCenter(@intCast(i), cell_w, step_w);
        var r = start_row;
        while (r < end_row) : (r += 1) {
            canvas.setGlyph(r, center, glyphs.v_line);
        }
    }
}

fn drawMessages(
    canvas: *canvas_mod.Canvas,
    diagram: *const types.SequenceDiagram,
    cell_w: usize,
    step_w: usize,
    top_box_rows: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) void {
    for (diagram.messages, 0..) |msg, idx| {
        const label_row = top_box_rows + 1 + idx * message_spacing;
        const arrow_row = label_row + 1;
        const from_center = participantCenter(msg.from, cell_w, step_w);
        const to_center = participantCenter(msg.to, cell_w, step_w);

        if (from_center == to_center) {
            drawSelfMessage(canvas, label_row, arrow_row, from_center, cell_w, msg.label, msg.style, glyphs, ambiguous);
        } else {
            drawMessageArrow(canvas, label_row, arrow_row, from_center, to_center, msg.label, msg.style, glyphs, ambiguous);
        }
    }
}

fn drawMessageArrow(
    canvas: *canvas_mod.Canvas,
    label_row: usize,
    arrow_row: usize,
    from_center: usize,
    to_center: usize,
    label: []const u8,
    style: types.MessageStyle,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) void {
    const lo = @min(from_center, to_center);
    const hi = @max(from_center, to_center);
    const going_right = to_center > from_center;

    const label_w = width_mod.displayWidth(label, ambiguous);
    if (label_w > 0) {
        const mid = (from_center + to_center) / 2;
        const half = label_w / 2;
        const col = if (mid > half) mid - half else 0;
        if (col + label_w <= canvas.cols) {
            canvas.drawLabel(label_row, col, label, ambiguous);
        }
    }

    const line_glyph = switch (style) {
        .solid_arrow, .solid_line => glyphs.h_line,
        .dashed_arrow, .dashed_line => dashedLineGlyph(ambiguous, glyphs),
    };

    var c = lo + 1;
    while (c < hi) : (c += 1) {
        canvas.setGlyph(arrow_row, c, line_glyph);
    }

    const has_head = style == .solid_arrow or style == .dashed_arrow;
    if (has_head) {
        if (going_right) {
            canvas.setGlyph(arrow_row, hi, glyphs.arrow_right);
        } else {
            canvas.setGlyph(arrow_row, lo, glyphs.arrow_left);
        }
    }
}

fn dashedLineGlyph(ambiguous: width_mod.AmbiguousWidth, glyphs: *const canvas_mod.GlyphSet) u21 {
    _ = ambiguous;
    if (glyphs.h_line == '-') return '-';
    return '╌';
}

fn drawSelfMessage(
    canvas: *canvas_mod.Canvas,
    label_row: usize,
    arrow_row: usize,
    center: usize,
    cell_w: usize,
    label: []const u8,
    style: types.MessageStyle,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) void {
    const loop_w: usize = @max(cell_w / 2, 4);
    const right = if (center + loop_w < canvas.cols) center + loop_w else canvas.cols - 1;
    if (right <= center) return;

    const line_glyph = switch (style) {
        .solid_arrow, .solid_line => glyphs.h_line,
        .dashed_arrow, .dashed_line => dashedLineGlyph(ambiguous, glyphs),
    };

    var c = center + 1;
    while (c <= right) : (c += 1) {
        canvas.setGlyph(label_row, c, line_glyph);
    }
    c = center + 1;
    while (c < right) : (c += 1) {
        canvas.setGlyph(arrow_row, c, line_glyph);
    }
    canvas.setGlyph(label_row, right, glyphs.corner_tr);
    canvas.setGlyph(arrow_row, right, glyphs.corner_br);

    const has_head = style == .solid_arrow or style == .dashed_arrow;
    if (has_head) {
        canvas.setGlyph(arrow_row, center + 1, glyphs.arrow_left);
    } else {
        canvas.setGlyph(arrow_row, center + 1, line_glyph);
    }

    const label_w = width_mod.displayWidth(label, ambiguous);
    if (label_w > 0 and label_row < canvas.rows) {
        const col = center + 2;
        if (col + label_w <= canvas.cols) {
            canvas.drawLabel(label_row, col, label, ambiguous);
        }
    }
}

test "writeSequence renders participant boxes and arrow" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    const opts: Options = .{
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };
    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    Alice->>Bob: Hello
        \\    Bob-->>Alice: Hi
    , opts);

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "►") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "◄") != null);
}

test "writeSequence handles single participant with no messages" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    const opts: Options = .{
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };
    try writeSequence(&sink.writer, alloc, "sequenceDiagram\n    participant Alice\n", opts);

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Alice") != null);
}
