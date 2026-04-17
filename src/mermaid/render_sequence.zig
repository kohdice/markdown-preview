const std = @import("std");
const types = @import("types.zig");
const parse = @import("parse_sequence.zig");
const canvas_mod = @import("canvas.zig");
const route_mod = @import("route.zig");
const width_mod = @import("../term/width.zig");

pub const RenderError = error{
    InvalidMermaid,
    UnsupportedFeature,
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
const note_height: usize = 3;
const block_border_h: usize = 1;

pub fn writeSequence(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    var diagram = parse.parseSource(allocator, source) catch |err| switch (err) {
        error.InvalidMermaid, error.TooManyParticipants => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer diagram.deinit();

    if (diagram.participants.len == 0) return;

    const glyphs = canvas_mod.GlyphSet.unicode;
    const ambig = opts.ambiguous_width;
    const n_part = diagram.participants.len;

    const label_w = computeMaxLabelWidth(&diagram, ambig);
    const cell_w = @max(label_w + 4, 6);
    const gap_w = computeGap(&diagram, cell_w, ambig);
    const step_w = cell_w + gap_w;

    const body_rows = calculateBodyRows(&diagram);
    const total_rows = box_h + body_rows + box_h;
    const base_cols = n_part * cell_w + (n_part - 1) * gap_w;
    var extra: usize = 0;
    for (diagram.notes) |n| {
        if (n.after_index < 0) continue;
        if (n.actor_ids.len == 0) continue;
        const tw = width_mod.displayWidth(n.text, ambig);
        const nw = @max(tw + 4, 6);
        const p0 = participantCenter(n.actor_ids[0], cell_w, step_w);
        const needed: usize = switch (n.placement) {
            .right_of => (p0 + 2) + nw,
            .left_of => nw + 2,
            .over => blk: {
                if (n.actor_ids.len >= 2) {
                    const p1 = participantCenter(n.actor_ids[1], cell_w, step_w);
                    const lo = @min(p0, p1);
                    const hi = @max(p0, p1);
                    const span_w = hi - lo + 4;
                    const w = @max(nw, span_w);
                    break :blk (if (lo >= 2) lo - 2 else 0) + w;
                } else {
                    const left = if (p0 > nw / 2) p0 - nw / 2 else 0;
                    break :blk left + nw;
                }
            },
        };
        if (needed > base_cols) extra = @max(extra, needed - base_cols);
    }
    for (diagram.blocks, 0..) |b, bi| {
        var depth: usize = 0;
        for (diagram.blocks, 0..) |other, oi| {
            if (oi == bi) continue;
            if (other.start_index <= b.start_index and other.end_index >= b.end_index) depth += 1;
        }
        const margin = depth * 2;
        const kw = width_mod.displayWidth(blockKindName(b.kind), ambig);
        const lw = width_mod.displayWidth(b.label, ambig);
        const needed = kw + (if (b.label.len > 0) lw + 4 else 0) + 4 + margin;
        if (needed > base_cols) extra = @max(extra, needed - base_cols);
    }
    const total_cols = base_cols + extra;

    var canvas = canvas_mod.Canvas.init(allocator, total_rows, total_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    drawParticipantBoxes(&canvas, &diagram, cell_w, step_w, 0, &glyphs, ambig);
    drawParticipantBoxes(&canvas, &diagram, cell_w, step_w, box_h + body_rows, &glyphs, ambig);
    drawLifelines(&canvas, n_part, cell_w, step_w, box_h, body_rows, &glyphs);
    drawBody(allocator, &canvas, &diagram, cell_w, step_w, box_h, &glyphs, ambig) catch return error.OutOfMemory;

    route_mod.mergeJunctions(allocator, &canvas, &glyphs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, ambig) catch return error.WriteFailed;
}

// ── Layout calculation ─────────────────────────────────────────────────────

fn calculateBodyRows(diagram: *const types.SequenceDiagram) usize {
    const n_msg = diagram.messages.len;
    if (n_msg == 0 and diagram.notes.len == 0 and diagram.blocks.len == 0) return 1;

    var rows: usize = 0;

    // Each message takes message_spacing rows
    rows += n_msg * message_spacing;

    // Notes with after_index >= 0 take note_height rows each
    for (diagram.notes) |n| {
        if (n.after_index >= 0) rows += note_height;
    }

    // Blocks: each block contributes top + bottom border rows + dividers
    for (diagram.blocks) |b| {
        rows += 2; // top + bottom border
        rows += b.dividers.len; // each else/and divider
    }

    return if (rows == 0) 1 else rows + 2;
}

fn computeMaxLabelWidth(diagram: *const types.SequenceDiagram, ambig: width_mod.AmbiguousWidth) usize {
    var max_w: usize = 0;
    for (diagram.participants) |p| {
        max_w = @max(max_w, width_mod.displayWidth(p.label, ambig));
    }
    return max_w;
}

fn computeGap(diagram: *const types.SequenceDiagram, cell_w: usize, ambig: width_mod.AmbiguousWidth) usize {
    var max_needed: usize = min_arrow_span;
    for (diagram.messages) |m| {
        const span = columnSpan(m.from, m.to);
        const w = width_mod.displayWidth(m.label, ambig);
        const needed = if (span == 0) w + 4 else (w + 4 + span - 1) / span;
        max_needed = @max(max_needed, needed);
    }
    for (diagram.notes) |n| {
        const w = width_mod.displayWidth(n.text, ambig) + 6;
        max_needed = @max(max_needed, w);
    }
    for (diagram.blocks, 0..) |b, bi| {
        // Estimate nesting depth: count blocks that fully contain this one
        var depth: usize = 0;
        for (diagram.blocks, 0..) |other, oi| {
            if (oi == bi) continue;
            if (other.start_index <= b.start_index and other.end_index >= b.end_index) {
                depth += 1;
            }
        }
        const margin = depth * 2;
        const kw = width_mod.displayWidth(blockKindName(b.kind), ambig);
        const lw = width_mod.displayWidth(b.label, ambig);
        const header_w = kw + (if (b.label.len > 0) lw + 4 else 0) + 4 + margin;
        max_needed = @max(max_needed, header_w);
        for (b.dividers) |div| {
            const dw = width_mod.displayWidth(div.label, ambig) + 4 + margin;
            max_needed = @max(max_needed, dw);
        }
    }
    _ = cell_w;
    return @max(max_needed, min_arrow_span);
}

fn columnSpan(a: types.ParticipantId, b: types.ParticipantId) usize {
    return @max(a, b) - @min(a, b);
}

fn participantCenter(index: types.ParticipantId, cell_w: usize, step_w: usize) usize {
    return @as(usize, @intCast(index)) * step_w + cell_w / 2;
}

// ── Drawing primitives ─────────────────────────────────────────────────────

fn drawParticipantBoxes(
    canvas: *canvas_mod.Canvas,
    diagram: *const types.SequenceDiagram,
    cell_w: usize,
    step_w: usize,
    top_row: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) void {
    for (diagram.participants, 0..) |p, i| {
        const left = i * step_w;
        canvas.drawRect(top_row, left, box_h, cell_w, glyphs);
        const lw = width_mod.displayWidth(p.label, ambig);
        const inner = cell_w - 2;
        const offset = if (inner > lw) (inner - lw) / 2 else 0;
        canvas.drawLabel(top_row + 1, left + 1 + offset, p.label, ambig);
    }
}

fn drawLifelines(
    canvas: *canvas_mod.Canvas,
    n_part: usize,
    cell_w: usize,
    step_w: usize,
    top_box_rows: usize,
    body_rows: usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    var i: usize = 0;
    while (i < n_part) : (i += 1) {
        const center = participantCenter(@intCast(i), cell_w, step_w);
        var r = top_box_rows;
        while (r < top_box_rows + body_rows) : (r += 1) {
            canvas.setGlyph(r, center, glyphs.v_line);
        }
    }
}

// ── Messages-loop body renderer ────────────────────────────────────────────

const ActiveBlock = struct { block_idx: usize };

fn drawBody(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    diagram: *const types.SequenceDiagram,
    cell_w: usize,
    step_w: usize,
    top_box_rows: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) error{OutOfMemory}!void {
    var row: usize = top_box_rows + 1;
    const total_cols = canvas.cols;

    var active_blocks: std.ArrayListUnmanaged(ActiveBlock) = .empty;
    defer active_blocks.deinit(allocator);

    var closed_blocks: std.ArrayListUnmanaged(usize) = .empty;
    defer closed_blocks.deinit(allocator);

    const n_msg: u32 = @intCast(diagram.messages.len);
    var msg_idx: u32 = 0;
    while (msg_idx <= n_msg) : (msg_idx += 1) {
        // Open blocks at this msg_idx in source_order (smallest first).
        // Only open one block at a time; after opening, check if it should
        // be closed before opening the next (sequential blocks at same index).
        while (true) {
            var best: ?usize = null;
            var best_order: u32 = std.math.maxInt(u32);
            for (diagram.blocks, 0..) |b, bi| {
                if (b.start_index != msg_idx) continue;
                var already = false;
                for (active_blocks.items) |ab| {
                    if (ab.block_idx == bi) {
                        already = true;
                        break;
                    }
                }
                if (already) continue;
                for (closed_blocks.items) |cb| {
                    if (cb == bi) {
                        already = true;
                        break;
                    }
                }
                if (already) continue;
                if (b.source_order < best_order) {
                    best = bi;
                    best_order = b.source_order;
                }
            }
            const bi = best orelse break;
            const b = diagram.blocks[bi];

            // Close active blocks that are sequential siblings of b (not parents).
            // A block is b's parent if b.parent_order == active_b.source_order.
            // Close from innermost out.
            while (true) {
                if (active_blocks.items.len == 0) break;
                var closed_any = false;
                var ci: usize = active_blocks.items.len;
                while (ci > 0) {
                    ci -= 1;
                    const ab = active_blocks.items[ci];
                    const active_b = diagram.blocks[ab.block_idx];
                    const is_parent = if (b.parent_order) |po| po == active_b.source_order else false;
                    if (!is_parent) {
                        var d: usize = 0;
                        while (d < ci) : (d += 1) {
                            drawFrameSideBorders(canvas, row, 1, d, total_cols, glyphs);
                        }
                        drawBlockEndRow(canvas, row, ci, total_cols, glyphs);
                        row += 1;
                        try closed_blocks.append(allocator, ab.block_idx);
                        _ = active_blocks.orderedRemove(ci);
                        closed_any = true;
                        break;
                    }
                }
                if (!closed_any) break;
            }

            {
                var d: usize = 0;
                while (d < active_blocks.items.len) : (d += 1) {
                    drawFrameSideBorders(canvas, row, 1, d, total_cols, glyphs);
                }
            }
            drawBlockStartRow(canvas, row, b.kind, b.label, active_blocks.items.len, total_cols, glyphs, ambig);
            try active_blocks.append(allocator, .{ .block_idx = bi });
            row += 1;
        }

        if (msg_idx == n_msg) break;

        for (active_blocks.items, 0..) |ab, ai| {
            const b = diagram.blocks[ab.block_idx];
            for (b.dividers) |div| {
                if (div.message_index == msg_idx) {
                    // Draw outer frames' side borders on this divider row
                    {
                        var d: usize = 0;
                        while (d < ai) : (d += 1) {
                            drawFrameSideBorders(canvas, row, 1, d, total_cols, glyphs);
                        }
                    }
                    drawElseSeparatorRow(canvas, row, div.label, ai, total_cols, glyphs, ambig);
                    row += 1;
                }
            }
        }

        {
            var d: usize = 0;
            while (d < active_blocks.items.len) : (d += 1) {
                drawFrameSideBorders(canvas, row, message_spacing, d, total_cols, glyphs);
            }
        }

        const msg = diagram.messages[msg_idx];
        const from_c = participantCenter(msg.from, cell_w, step_w);
        const to_c = participantCenter(msg.to, cell_w, step_w);
        if (from_c == to_c) {
            drawSelfMessage(canvas, row, row + 1, from_c, cell_w, msg, glyphs, ambig);
        } else {
            drawMessageArrow(canvas, row, row + 1, from_c, to_c, msg, glyphs, ambig);
        }

        row += message_spacing;

        for (diagram.notes) |note| {
            if (note.after_index >= 0 and @as(u32, @intCast(note.after_index)) == msg_idx) {
                var d: usize = 0;
                while (d < active_blocks.items.len) : (d += 1) {
                    drawFrameSideBorders(canvas, row, note_height, d, total_cols, glyphs);
                }
                drawNoteAtRow(canvas, row, note, cell_w, step_w, glyphs, ambig);
                row += note_height;
            }
        }

        while (true) {
            if (active_blocks.items.len == 0) break;
            var found = false;
            var ci: usize = active_blocks.items.len;
            while (ci > 0) {
                ci -= 1;
                const b = diagram.blocks[active_blocks.items[ci].block_idx];
                if (b.end_index == msg_idx) {
                    // Draw outer frames' side borders on this close row
                    {
                        var d: usize = 0;
                        while (d < ci) : (d += 1) {
                            drawFrameSideBorders(canvas, row, 1, d, total_cols, glyphs);
                        }
                    }
                    drawBlockEndRow(canvas, row, ci, total_cols, glyphs);
                    row += 1;
                    try closed_blocks.append(allocator, active_blocks.items[ci].block_idx);
                    _ = active_blocks.orderedRemove(ci);
                    found = true;
                    break;
                }
            }
            if (!found) break;
        }
    }

    while (active_blocks.items.len > 0) {
        const len = active_blocks.items.len - 1;
        {
            var d: usize = 0;
            while (d < len) : (d += 1) {
                drawFrameSideBorders(canvas, row, 1, d, total_cols, glyphs);
            }
        }
        drawBlockEndRow(canvas, row, len, total_cols, glyphs);
        try closed_blocks.append(allocator, active_blocks.items[len].block_idx);
        _ = active_blocks.orderedRemove(len);
        row += 1;
    }
}

fn drawFrameSideBorders(
    canvas: *canvas_mod.Canvas,
    start_row: usize,
    height: usize,
    depth: usize,
    total_cols: usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    if (total_cols <= depth * 2 + 2) return;
    const left = depth;
    const right = total_cols - 1 - depth;
    var r = start_row;
    while (r < start_row + height) : (r += 1) {
        canvas.setGlyph(r, left, glyphs.v_line);
        canvas.setGlyph(r, right, glyphs.v_line);
    }
}

fn blockKindName(kind: types.SequenceBlockKind) []const u8 {
    return switch (kind) {
        .loop => "loop",
        .alt => "alt",
        .opt => "opt",
        .par => "par",
        .critical => "critical",
        .rect => "rect",
        .break_ => "break",
    };
}

fn drawBlockStartRow(
    canvas: *canvas_mod.Canvas,
    row: usize,
    kind: types.SequenceBlockKind,
    label: []const u8,
    indent: usize,
    total_cols: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) void {
    if (total_cols <= indent * 2 + 2) return;
    const left = indent;
    const right = total_cols - 1 - indent;

    canvas.setGlyph(row, left, glyphs.corner_tl);
    canvas.setGlyph(row, right, glyphs.corner_tr);
    var c = left + 1;
    while (c < right) : (c += 1) {
        canvas.setGlyph(row, c, glyphs.h_line);
    }

    // Format: "kind [label]" or just "kind" when label is empty (F5)
    const kind_text = blockKindName(kind);
    const kind_w = width_mod.displayWidth(kind_text, ambig);
    if (left + 2 + kind_w < right) {
        canvas.setGlyph(row, left + 1, ' ');
        canvas.drawLabel(row, left + 2, kind_text, ambig);
        if (label.len > 0) {
            const bracket_col = left + 2 + kind_w;
            if (bracket_col + 2 < right) {
                canvas.setGlyph(row, bracket_col, ' ');
                canvas.setGlyph(row, bracket_col + 1, '[');
                canvas.drawLabel(row, bracket_col + 2, label, ambig);
                const close_col = bracket_col + 2 + width_mod.displayWidth(label, ambig);
                if (close_col < right) {
                    canvas.setGlyph(row, close_col, ']');
                }
            }
        }
    }
}

fn drawBlockEndRow(
    canvas: *canvas_mod.Canvas,
    row: usize,
    indent: usize,
    total_cols: usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    if (total_cols <= indent * 2 + 2) return;
    const left = indent;
    const right = total_cols - 1 - indent;
    canvas.setGlyph(row, left, glyphs.corner_bl);
    canvas.setGlyph(row, right, glyphs.corner_br);
    var c = left + 1;
    while (c < right) : (c += 1) {
        canvas.setGlyph(row, c, glyphs.h_line);
    }
}

fn drawElseSeparatorRow(
    canvas: *canvas_mod.Canvas,
    row: usize,
    label: []const u8,
    indent: usize,
    total_cols: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) void {
    if (total_cols <= indent * 2 + 2) return;
    const left = indent;
    const right = total_cols - 1 - indent;
    canvas.setGlyph(row, left, glyphs.tee_l);
    canvas.setGlyph(row, right, glyphs.tee_r);
    var c = left + 1;
    while (c < right) : (c += 1) {
        canvas.setGlyph(row, c, glyphs.h_line_dashed);
    }
    if (label.len > 0 and left + 3 < right) {
        canvas.setGlyph(row, left + 1, ' ');
        canvas.drawLabel(row, left + 2, label, ambig);
    }
}

fn drawNoteAtRow(
    canvas: *canvas_mod.Canvas,
    row: usize,
    note: types.SequenceNote,
    cell_w: usize,
    step_w: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) void {
    const tw = width_mod.displayWidth(note.text, ambig);
    const text_note_w = @max(tw + 4, 6);
    if (note.actor_ids.len == 0) return;
    const p_center = participantCenter(note.actor_ids[0], cell_w, step_w);

    var left: usize = undefined;
    var note_w: usize = text_note_w;

    switch (note.placement) {
        .right_of => {
            left = p_center + 2;
        },
        .left_of => {
            left = if (p_center > text_note_w + 2) p_center - text_note_w - 2 else 0;
        },
        .over => {
            if (note.actor_ids.len >= 2) {
                const other = participantCenter(note.actor_ids[1], cell_w, step_w);
                const lo = @min(p_center, other);
                const hi = @max(p_center, other);
                const span_w = hi - lo + 4;
                note_w = @max(text_note_w, span_w);
                left = if (lo >= 2) lo - 2 else 0;
            } else {
                left = if (p_center > text_note_w / 2) p_center - text_note_w / 2 else 0;
            }
        },
    }

    if (left + note_w > canvas.cols) return;
    canvas.drawRect(row, left, 3, note_w, glyphs);
    if (tw > 0) {
        const inner = note_w - 2;
        const text_offset = if (inner > tw) (inner - tw) / 2 else 0;
        canvas.drawLabel(row + 1, left + 1 + text_offset, note.text, ambig);
    }
}

// ── Arrow drawing (F1: filled/open heads) ──────────────────────────────────

fn drawMessageArrow(
    canvas: *canvas_mod.Canvas,
    label_row: usize,
    arrow_row: usize,
    from_center: usize,
    to_center: usize,
    msg: types.SequenceMessage,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) void {
    const lo = @min(from_center, to_center);
    const hi = @max(from_center, to_center);
    const going_right = to_center > from_center;

    const label_w = width_mod.displayWidth(msg.label, ambig);
    if (label_w > 0) {
        const mid = (from_center + to_center) / 2;
        const half = label_w / 2;
        const col = if (mid > half) mid - half else 0;
        if (col + label_w <= canvas.cols) canvas.drawLabel(label_row, col, msg.label, ambig);
    }

    const line_glyph: u21 = if (msg.line_style == .dashed) '╌' else glyphs.h_line;
    var c = lo + 1;
    while (c < hi) : (c += 1) {
        canvas.setGlyph(arrow_row, c, line_glyph);
    }

    // Arrow head glyph: filled (▶◀) vs open (▷◁)
    const head_glyph: u21 = if (going_right)
        (if (msg.arrow_head == .filled) glyphs.arrow_right else '▷')
    else
        (if (msg.arrow_head == .filled) glyphs.arrow_left else '◁');

    if (going_right) {
        canvas.setGlyph(arrow_row, hi, head_glyph);
    } else {
        canvas.setGlyph(arrow_row, lo, head_glyph);
    }
}

fn drawSelfMessage(
    canvas: *canvas_mod.Canvas,
    label_row: usize,
    arrow_row: usize,
    center: usize,
    cell_w: usize,
    msg: types.SequenceMessage,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) void {
    const loop_w: usize = @max(cell_w / 2, 4);
    const right = if (center + loop_w < canvas.cols) center + loop_w else canvas.cols - 1;
    if (right <= center) return;

    const line_glyph: u21 = if (msg.line_style == .dashed) '╌' else glyphs.h_line;

    var c = center + 1;
    while (c <= right) : (c += 1) canvas.setGlyph(label_row, c, line_glyph);
    c = center + 1;
    while (c < right) : (c += 1) canvas.setGlyph(arrow_row, c, line_glyph);
    canvas.setGlyph(label_row, right, glyphs.corner_tr);
    canvas.setGlyph(arrow_row, right, glyphs.corner_br);

    const head: u21 = if (msg.arrow_head == .filled) glyphs.arrow_left else '◁';
    canvas.setGlyph(arrow_row, center + 1, head);

    const lw = width_mod.displayWidth(msg.label, ambig);
    if (lw > 0 and label_row < canvas.rows) {
        const col = center + 2;
        if (col + lw <= canvas.cols) canvas.drawLabel(label_row, col, msg.label, ambig);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "writeSequence renders participant boxes and arrow" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    Alice->>Bob: Hello
        \\    Bob-->>Alice: Hi
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hi") != null);
    // Filled arrow heads
    try std.testing.expect(std.mem.indexOf(u8, out, "►") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "◄") != null);
}

test "writeSequence handles single participant with no messages" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(
        &sink.writer,
        alloc,
        "sequenceDiagram\n    participant Alice\n",
        .{ .wrap_width = null, .ambiguous_width = .narrow },
    );
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Alice") != null);
}

test "renderer draws filled and open arrow heads" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    A->>B: filled
        \\    B->A: open
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "►") != null); // filled right
    try std.testing.expect(std.mem.indexOf(u8, out, "◁") != null); // open left
}

test "note with after_index=-1 is NOT rendered" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    Note right of A: early
        \\    A->>B: msg
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    // The note "early" has after_index=-1 so should not appear in output
    try std.testing.expect(std.mem.indexOf(u8, out, "early") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "msg") != null);
}

test "note with after_index>=0 IS rendered" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    A->>B: msg
        \\    Note right of B: visible
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "visible") != null);
}

test "activate/deactivate flags are parsed but ASCII does not draw activation (upstream parity)" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    A->>+B: Hello
        \\    A->>-B: World
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "World") != null);
    // upstream ASCII renderer does not visually distinguish activated lifelines
    try std.testing.expect(std.mem.indexOf(u8, out, "║") == null);
}

test "block header uses kind [label] format" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    loop every minute
        \\        A->>B: ping
        \\    end
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "loop [every minute]") != null);
}

test "label-less block renders kind only without brackets" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    loop
        \\        A->>B: ping
        \\    end
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    // Should have "loop" but NOT "loop ["
    try std.testing.expect(std.mem.indexOf(u8, out, "loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "loop [") == null);
}

test "nested blocks render outer before inner" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    loop outer
        \\        alt inner
        \\            A->>B: yes
        \\        end
        \\    end
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    // "loop" header must appear before "alt" header in the output (open order)
    const loop_pos = std.mem.indexOf(u8, out, "loop [outer]") orelse return error.WriteFailed;
    const alt_pos = std.mem.indexOf(u8, out, "alt [inner]") orelse return error.WriteFailed;
    try std.testing.expect(loop_pos < alt_pos);

    // Inner block (alt, depth=1) must close before outer block (loop, depth=0).
    // Count '└' characters: the first '└' should be at depth 1 (indented),
    // and the second at depth 0 (leftmost). We verify by checking that
    // the output contains inner close corner '┘' before outer close corner.
    // Simpler check: find the two bottom-left corners after the message area.
    // The inner close line (alt) should appear before the outer close line (loop).
    const msg_end = std.mem.indexOf(u8, out, "yes") orelse return error.WriteFailed;
    const rest = out[msg_end..];
    // After the arrow row, we expect inner alt closing line first (with indent),
    // then outer loop closing line (at column 0).
    // Inner close starts with " └" (indented), outer with "└" (column 0).
    // Find first "└" in rest — that should be the inner one (depth 1).
    const first_bl = std.mem.indexOf(u8, rest, "└") orelse return error.WriteFailed;
    // The inner close should be indented (preceded by space or another border char)
    if (first_bl > 0) {
        // Character before └ should NOT be newline (i.e. it's indented)
        try std.testing.expect(rest[first_bl - 1] != '\n');
    }
}

test "empty block still renders frame" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    participant A
        \\    loop empty
        \\    end
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "loop [empty]") != null);
}

test "activate/deactivate with multiple messages renders normally without activation marks" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    A->>+B: Hello
        \\    A->>B: working
        \\    A->>-B: Done
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "working") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Done") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "║") == null);
}

test "Note over two participants spans both lifelines" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    participant Alice
        \\    participant Bob
        \\    Alice->>Bob: Hello
        \\    Note over Alice,Bob: ok
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    // Find the note top border line (┌...┐ after the arrow)
    // The note box must span from Alice's lifeline area to Bob's lifeline area.
    // Look for the note border row: it should have ┌ near Alice and ┐ near Bob.
    // The header row with "Alice" tells us Alice's box starts at col 0.
    // The note top ┌ should be at or before Alice's center (col ~3),
    // and ┐ should be at or after Bob's center.
    const arrow_pos = std.mem.indexOf(u8, out, "Hello") orelse return error.WriteFailed;
    const rest = out[arrow_pos..];
    // Find ┌ in the rest (note top border)
    const tl = std.mem.indexOf(u8, rest, "┌") orelse return error.WriteFailed;
    const tr = std.mem.indexOf(u8, rest, "┐") orelse return error.WriteFailed;
    // ┐ must be significantly after ┌ (spanning both lifelines, not just text width)
    // With "ok" text (2 chars), text-only box would be 6 chars wide.
    // With two participants, the span should be much wider (at least 20 chars).
    try std.testing.expect(tr > tl + 20);
}

test "long Note over is not silently dropped" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    A->>B: x
        \\    Note over A,B: This is a very long note that should still appear
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "very long note") != null);
}

test "Note left of with long text is not silently dropped" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    A->>B: x
        \\    Note left of A: left side note here
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "left side note") != null);
}

test "long else label is fully rendered" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    alt success
        \\        A->>B: ok
        \\    else failed because timeout exceeded
        \\        A->>B: err
        \\    end
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "failed because timeout exceeded") != null);
}

test "nested block with long inner header is fully rendered" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    loop outer
        \\        alt very long inner condition label here
        \\            A->>B: ok
        \\        end
        \\    end
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "very long inner condition label here") != null);
}

test "nested else divider label is fully rendered" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    loop outer
        \\        alt ok
        \\            A->>B: yes
        \\        else failed with a very long reason description
        \\            A->>B: no
        \\        end
        \\    end
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "failed with a very long reason description") != null);
}

test "nested block outer frame has no gaps on inner block rows" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    loop outer
        \\        alt inner
        \\            A->>B: yes
        \\        end
        \\    end
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    // The inner block header line should have outer │ on both sides: │┌ alt ...┐│
    // Check that "│┌" appears (outer left border + inner top-left corner)
    try std.testing.expect(std.mem.indexOf(u8, out, "│┌") != null);
    // The inner block close line should also have outer │: │└...┘│
    try std.testing.expect(std.mem.indexOf(u8, out, "│└") != null);
}

test "final flush of nested empty blocks has outer frame borders" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    participant A
        \\    loop outer
        \\        alt inner
        \\        end
        \\    end
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "loop [outer]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "alt [inner]") != null);
    // Inner close must have outer │ on left side
    try std.testing.expect(std.mem.indexOf(u8, out, "│└") != null);
}

test "sequential blocks at same index are not nested" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeSequence(&sink.writer, alloc,
        \\sequenceDiagram
        \\    loop a
        \\    end
        \\    loop b
        \\        A->>B: x
        \\    end
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "loop [a]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "loop [b]") != null);
    const a_pos = std.mem.indexOf(u8, out, "loop [a]").?;
    const b_pos = std.mem.indexOf(u8, out, "loop [b]").?;
    try std.testing.expect(a_pos < b_pos);
    // They must NOT be nested
    try std.testing.expect(std.mem.indexOf(u8, out, "│┌ loop") == null);
}
