const std = @import("std");
const types = @import("types.zig");
const canvas_mod = @import("canvas.zig");
const compile_mod = @import("compile.zig");
const route_mod = @import("route.zig");
const text_layout = @import("text_layout.zig");
const width_mod = @import("../term/width.zig");

pub const RenderError = error{
    InvalidMermaid,
    UnsupportedFeature,
    WidthTooSmall,
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

pub fn paintSequence(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    diagram_ptr: *const types.SequenceDiagram,
    opts: Options,
) RenderError!void {
    if (opts.wrap_width) |wrap_width| {
        return paintSequenceWrapped(writer, allocator, diagram_ptr, wrap_width, opts.ambiguous_width);
    }

    return paintSequenceCanvas(writer, allocator, diagram_ptr, opts);
}

fn paintSequenceCanvas(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    diagram_ptr: *const types.SequenceDiagram,
    opts: Options,
) RenderError!void {
    const diagram = diagram_ptr.*;

    if (diagram.participants.len == 0) return;

    const glyphs = canvas_mod.GlyphSet.unicode;
    const ambig = opts.ambiguous_width;
    const n_part = diagram.participants.len;

    const label_w = computeMaxLabelWidth(&diagram, ambig);
    const cell_w = @max(label_w + 4, 6);
    const gap_w = computeGap(&diagram, cell_w, ambig);
    const step_w = cell_w + gap_w;

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

    var body_plan = try planSequenceBandBody(allocator, &diagram, .{
        .mode = .canvas,
        .band = .{
            .start = 0,
            .end = n_part,
            .max_per_band = n_part,
        },
        .cell_w = cell_w,
        .step_w = step_w,
        .total_cols = total_cols,
    }, ambig);
    defer body_plan.deinit();

    const body_rows = canvasBodyRows(&body_plan);
    const total_rows = box_h + body_rows + box_h;

    var canvas = canvas_mod.Canvas.init(allocator, total_rows, total_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    try drawParticipantBoxes(&canvas, &diagram, cell_w, step_w, 0, &glyphs, ambig);
    try drawParticipantBoxes(&canvas, &diagram, cell_w, step_w, box_h + body_rows, &glyphs, ambig);
    drawLifelines(&canvas, n_part, cell_w, step_w, box_h, body_rows, &glyphs);
    try drawCanvasBandBody(&canvas, &diagram, &body_plan, cell_w, step_w, box_h, &glyphs, ambig);

    route_mod.mergeJunctions(allocator, &canvas, &glyphs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, ambig) catch return error.WriteFailed;
}

const min_wrapped_sequence_width: usize = 8;
const min_wrapped_participant_box_width: usize = 6;
const min_wrapped_note_width: usize = 6;
const wrapped_participant_gap: usize = min_arrow_span;
const wrapped_block_end_height: usize = 1;

const ParticipantBand = struct {
    start: usize,
    end: usize,
    max_per_band: usize,
};

const SequenceBodyMode = enum {
    canvas,
    wrapped,
};

const SequenceBandLayout = struct {
    mode: SequenceBodyMode,
    band: ParticipantBand,
    cell_w: usize,
    step_w: usize,
    total_cols: usize,
};

const BlockEmitter = struct {
    writer: *std.Io.Writer,
    needs_separator: bool = false,

    fn beginBlock(self: *BlockEmitter) RenderError!void {
        if (self.needs_separator) self.writer.writeByte('\n') catch return error.WriteFailed;
        self.needs_separator = true;
    }
};

fn paintSequenceWrapped(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    diagram: *const types.SequenceDiagram,
    wrap_width: usize,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    if (diagram.participants.len == 0) return;
    if (wrap_width < min_wrapped_sequence_width) return error.WidthTooSmall;

    const max_per_band = participantsPerBand(wrap_width);
    const glyphs = if (ambig == .wide) canvas_mod.GlyphSet.ascii else canvas_mod.GlyphSet.unicode;
    var emitter: BlockEmitter = .{ .writer = writer };
    var start: usize = 0;
    while (start < diagram.participants.len) {
        const end = @min(start + max_per_band, diagram.participants.len);
        const band: ParticipantBand = .{
            .start = start,
            .end = end,
            .max_per_band = max_per_band,
        };
        try renderWrappedBand(&emitter, allocator, diagram, band, wrap_width, &glyphs, ambig);
        start = end;
    }
}

fn participantsPerBand(wrap_width: usize) usize {
    return @max(@as(usize, 1), (wrap_width + wrapped_participant_gap) / (min_wrapped_participant_box_width + wrapped_participant_gap));
}

fn wrappedCellWidth(wrap_width: usize, participant_count: usize) RenderError!usize {
    if (participant_count == 0) return error.WidthTooSmall;
    const gaps = (participant_count - 1) * wrapped_participant_gap;
    if (wrap_width <= gaps) return error.WidthTooSmall;
    const cell_w = (wrap_width - gaps) / participant_count;
    if (cell_w < min_wrapped_participant_box_width) return error.WidthTooSmall;
    return cell_w;
}

fn wrappedCanvasCols(participant_count: usize, cell_w: usize) usize {
    return participant_count * cell_w + (participant_count - 1) * wrapped_participant_gap;
}

fn renderWrappedBand(
    emitter: *BlockEmitter,
    allocator: std.mem.Allocator,
    diagram: *const types.SequenceDiagram,
    band: ParticipantBand,
    wrap_width: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    const participant_count = band.end - band.start;
    const cell_w = try wrappedCellWidth(wrap_width, participant_count);
    const step_w = cell_w + wrapped_participant_gap;
    const canvas_cols = wrappedCanvasCols(participant_count, cell_w);

    var participant_labels = try allocator.alloc(text_layout.LabelLayout, participant_count);
    var initialized_labels: usize = 0;
    defer {
        for (participant_labels[0..initialized_labels]) |*layout| layout.deinit();
        allocator.free(participant_labels);
    }

    for (diagram.participants[band.start..band.end], 0..) |participant, local_idx| {
        participant_labels[local_idx] = try text_layout.layoutLabel(allocator, participant.label, cell_w - 2, ambig);
        initialized_labels += 1;
    }

    var participant_box_h: usize = 3;
    for (participant_labels) |layout| {
        participant_box_h = @max(participant_box_h, layout.lines.len + 2);
    }

    var body_plan = try planSequenceBandBody(allocator, diagram, .{
        .mode = .wrapped,
        .band = band,
        .cell_w = cell_w,
        .step_w = step_w,
        .total_cols = canvas_cols,
    }, ambig);
    defer body_plan.deinit();

    const body_rows = body_plan.rows;
    const total_rows = participant_box_h + body_rows + participant_box_h;

    var canvas = canvas_mod.Canvas.init(allocator, total_rows, canvas_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    try drawWrappedParticipantBoxes(&canvas, participant_labels, cell_w, step_w, participant_box_h, 0, glyphs, ambig);
    try drawWrappedParticipantBoxes(&canvas, participant_labels, cell_w, step_w, participant_box_h, participant_box_h + body_rows, glyphs, ambig);
    drawWrappedLifelines(&canvas, participant_count, cell_w, step_w, participant_box_h, body_rows, glyphs);
    try drawWrappedBandBody(&canvas, diagram, &body_plan, band, cell_w, step_w, participant_box_h, glyphs, ambig);

    route_mod.mergeJunctions(allocator, &canvas, glyphs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    try emitter.beginBlock();
    canvas_mod.writeCanvas(emitter.writer, &canvas, null, ambig) catch return error.WriteFailed;
}

fn drawWrappedParticipantBoxes(
    canvas: *canvas_mod.Canvas,
    labels: []const text_layout.LabelLayout,
    cell_w: usize,
    step_w: usize,
    box_height: usize,
    top_row: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    for (labels, 0..) |layout, local_idx| {
        const left = local_idx * step_w;
        canvas.drawRect(top_row, left, box_height, cell_w, glyphs);
        try text_layout.drawCenteredLabel(canvas, top_row + 1, left + 1, box_height - 2, cell_w - 2, layout.lines, ambig);
    }
}

fn drawWrappedLifelines(
    canvas: *canvas_mod.Canvas,
    participant_count: usize,
    cell_w: usize,
    step_w: usize,
    top_box_rows: usize,
    body_rows: usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    var local_idx: usize = 0;
    while (local_idx < participant_count) : (local_idx += 1) {
        const center = participantCenter(@intCast(local_idx), cell_w, step_w);
        var row = top_box_rows;
        while (row < top_box_rows + body_rows) : (row += 1) {
            canvas.setGlyph(row, center, glyphs.v_line);
        }
    }
}

const SequenceBodyItem = union(enum) {
    block_start: BlockStart,
    block_divider: BlockDivider,
    block_end: BlockEnd,
    message: Message,
    note: Note,

    const BlockStart = struct {
        block_idx: usize,
        depth: usize,
        height: usize,
        layout: ?text_layout.LabelLayout = null,
    };

    const BlockDivider = struct {
        block_idx: usize,
        divider_idx: usize,
        depth: usize,
        height: usize,
        layout: ?text_layout.LabelLayout = null,
    };

    const BlockEnd = struct {
        depth: usize,
    };

    const Message = struct {
        message_idx: usize,
        depth: usize,
        height: usize,
        label_layout: ?text_layout.LabelLayout = null,
        continuation_layout: ?text_layout.LabelLayout = null,
    };

    const Note = struct {
        note_idx: usize,
        depth: usize,
        height: usize,
        frame: ?NoteFrame = null,
        layout: ?text_layout.LabelLayout = null,
    };

    fn height(self: SequenceBodyItem) usize {
        return switch (self) {
            .block_start => |item| item.height,
            .block_divider => |item| item.height,
            .block_end => wrapped_block_end_height,
            .message => |item| item.height,
            .note => |item| item.height,
        };
    }

    fn deinit(self: *SequenceBodyItem) void {
        switch (self.*) {
            .block_start => |*item| if (item.layout) |*layout| layout.deinit(),
            .block_divider => |*item| if (item.layout) |*layout| layout.deinit(),
            .block_end => {},
            .message => |*item| {
                if (item.label_layout) |*layout| layout.deinit();
                if (item.continuation_layout) |*layout| layout.deinit();
            },
            .note => |*item| if (item.layout) |*layout| layout.deinit(),
        }
    }
};

const SequenceLayoutPlan = struct {
    allocator: std.mem.Allocator,
    items: []SequenceBodyItem,
    rows: usize,

    fn deinit(self: *SequenceLayoutPlan) void {
        deinitSequenceBodyItems(self.items);
        self.allocator.free(self.items);
    }
};

fn deinitSequenceBodyItems(items: []SequenceBodyItem) void {
    for (items) |*item| item.deinit();
}

fn appendSequenceBodyItem(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(SequenceBodyItem),
    rows: *usize,
    item: SequenceBodyItem,
) RenderError!void {
    var owned_item = item;
    errdefer owned_item.deinit();
    try items.append(allocator, owned_item);
    rows.* += owned_item.height();
}

fn planSequenceBandBody(
    allocator: std.mem.Allocator,
    diagram: *const types.SequenceDiagram,
    layout: SequenceBandLayout,
    ambig: width_mod.AmbiguousWidth,
) RenderError!SequenceLayoutPlan {
    var rows: usize = 0;
    var items: std.ArrayList(SequenceBodyItem) = .empty;
    errdefer {
        deinitSequenceBodyItems(items.items);
        items.deinit(allocator);
    }

    var active_blocks: std.ArrayList(ActiveBlock) = .empty;
    defer active_blocks.deinit(allocator);

    var closed_blocks: std.ArrayList(usize) = .empty;
    defer closed_blocks.deinit(allocator);

    const n_msg: u32 = @intCast(diagram.messages.len);
    var msg_idx: u32 = 0;
    while (msg_idx <= n_msg) : (msg_idx += 1) {
        while (true) {
            const block_idx = nextSequenceBlockToOpen(diagram, msg_idx, active_blocks.items, closed_blocks.items, layout) orelse break;
            const block = diagram.blocks[block_idx];

            while (true) {
                if (active_blocks.items.len == 0) break;
                var closed_any = false;
                var idx: usize = active_blocks.items.len;
                while (idx > 0) {
                    idx -= 1;
                    const active = active_blocks.items[idx];
                    const active_block = diagram.blocks[active.block_idx];
                    const is_parent = if (block.parent_order) |po| po == active_block.source_order else false;
                    if (!is_parent) {
                        try appendSequenceBodyItem(allocator, &items, &rows, .{ .block_end = .{ .depth = idx } });
                        try closed_blocks.append(allocator, active.block_idx);
                        _ = active_blocks.orderedRemove(idx);
                        closed_any = true;
                        break;
                    }
                }
                if (!closed_any) break;
            }

            const label_layout = switch (layout.mode) {
                .canvas => null,
                .wrapped => blk: {
                    const text = try blockHeaderText(allocator, block);
                    defer allocator.free(text);
                    const budget = try blockTextBudget(layout.total_cols, active_blocks.items.len);
                    break :blk try text_layout.layoutLabel(allocator, text, budget, ambig);
                },
            };
            try appendSequenceBodyItem(allocator, &items, &rows, .{ .block_start = .{
                .block_idx = block_idx,
                .depth = active_blocks.items.len,
                .height = if (label_layout) |label| @max(@as(usize, 1), label.lines.len) else block_border_h,
                .layout = label_layout,
            } });
            try active_blocks.append(allocator, .{ .block_idx = block_idx });
        }

        if (msg_idx == n_msg) break;

        for (active_blocks.items, 0..) |active, active_idx| {
            const block = diagram.blocks[active.block_idx];
            for (block.dividers, 0..) |divider, divider_idx| {
                if (divider.message_index == msg_idx) {
                    const label_layout = switch (layout.mode) {
                        .canvas => null,
                        .wrapped => blk: {
                            const budget = try blockTextBudget(layout.total_cols, active_idx);
                            break :blk try text_layout.layoutLabel(allocator, divider.label, budget, ambig);
                        },
                    };
                    try appendSequenceBodyItem(allocator, &items, &rows, .{ .block_divider = .{
                        .block_idx = active.block_idx,
                        .divider_idx = divider_idx,
                        .depth = active_idx,
                        .height = if (label_layout) |label| @max(@as(usize, 1), label.lines.len) else block_border_h,
                        .layout = label_layout,
                    } });
                }
            }
        }

        const message = diagram.messages[msg_idx];
        if (messageRelevantToBand(message, layout.band)) {
            const depth = active_blocks.items.len;
            const planned = switch (layout.mode) {
                .canvas => SequenceBodyItem.Message{
                    .message_idx = msg_idx,
                    .depth = depth,
                    .height = message_spacing,
                },
                .wrapped => try planWrappedMessage(allocator, diagram, message, msg_idx, layout.band, layout.cell_w, layout.step_w, layout.total_cols, depth, ambig),
            };
            try appendSequenceBodyItem(allocator, &items, &rows, .{ .message = .{
                .message_idx = planned.message_idx,
                .depth = planned.depth,
                .height = planned.height,
                .label_layout = planned.label_layout,
                .continuation_layout = planned.continuation_layout,
            } });
        }

        for (diagram.notes, 0..) |note, note_idx| {
            if (note.after_index >= 0 and @as(u32, @intCast(note.after_index)) == msg_idx and noteRelevantToBand(note, layout.band)) {
                const depth = active_blocks.items.len;
                const planned = switch (layout.mode) {
                    .canvas => SequenceBodyItem.Note{
                        .note_idx = note_idx,
                        .depth = depth,
                        .height = note_height,
                    },
                    .wrapped => try planWrappedNote(allocator, diagram, note, note_idx, layout.band, layout.cell_w, layout.step_w, layout.total_cols, depth, ambig),
                };
                try appendSequenceBodyItem(allocator, &items, &rows, .{ .note = .{
                    .note_idx = planned.note_idx,
                    .depth = planned.depth,
                    .height = planned.height,
                    .frame = planned.frame,
                    .layout = planned.layout,
                } });
            }
        }

        while (true) {
            if (active_blocks.items.len == 0) break;
            var found = false;
            var idx: usize = active_blocks.items.len;
            while (idx > 0) {
                idx -= 1;
                const active = active_blocks.items[idx];
                const block = diagram.blocks[active.block_idx];
                if (block.end_index == msg_idx) {
                    try appendSequenceBodyItem(allocator, &items, &rows, .{ .block_end = .{ .depth = idx } });
                    try closed_blocks.append(allocator, active.block_idx);
                    _ = active_blocks.orderedRemove(idx);
                    found = true;
                    break;
                }
            }
            if (!found) break;
        }
    }

    while (active_blocks.items.len > 0) {
        const idx = active_blocks.items.len - 1;
        const active = active_blocks.items[idx];
        try appendSequenceBodyItem(allocator, &items, &rows, .{ .block_end = .{ .depth = idx } });
        try closed_blocks.append(allocator, active.block_idx);
        _ = active_blocks.orderedRemove(idx);
    }

    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(allocator),
        .rows = if (rows == 0) 1 else rows,
    };
}

fn canvasBodyRows(plan: *const SequenceLayoutPlan) usize {
    return if (plan.items.len == 0) plan.rows else plan.rows + 2;
}

fn drawCanvasBandBody(
    canvas: *canvas_mod.Canvas,
    diagram: *const types.SequenceDiagram,
    plan: *const SequenceLayoutPlan,
    cell_w: usize,
    step_w: usize,
    top_box_rows: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    if (plan.items.len == 0) return;

    var row = top_box_rows + 1;
    const total_cols = canvas.cols;

    for (plan.items) |item| {
        switch (item) {
            .block_start => |planned| {
                drawFrameSideBordersBeforeDepth(canvas, row, planned.height, planned.depth, total_cols, glyphs);
                const block = diagram.blocks[planned.block_idx];
                try drawBlockStartRow(canvas, row, block.kind, block.label, planned.depth, total_cols, glyphs, ambig);
            },
            .block_divider => |planned| {
                drawFrameSideBordersBeforeDepth(canvas, row, planned.height, planned.depth, total_cols, glyphs);
                const block = diagram.blocks[planned.block_idx];
                const divider = block.dividers[planned.divider_idx];
                try drawElseSeparatorRow(canvas, row, divider.label, planned.depth, total_cols, glyphs, ambig);
            },
            .block_end => |planned| {
                drawFrameSideBordersBeforeDepth(canvas, row, wrapped_block_end_height, planned.depth, total_cols, glyphs);
                drawBlockEndRow(canvas, row, planned.depth, total_cols, glyphs);
            },
            .message => |planned| {
                drawFrameSideBordersBeforeDepth(canvas, row, planned.height, planned.depth, total_cols, glyphs);
                const message = diagram.messages[planned.message_idx];
                const from_center = participantCenter(message.from, cell_w, step_w);
                const to_center = participantCenter(message.to, cell_w, step_w);
                if (from_center == to_center) {
                    try drawSelfMessage(canvas, row, row + 1, from_center, cell_w, message, glyphs, ambig);
                } else {
                    try drawMessageArrow(canvas, row, row + 1, from_center, to_center, message, glyphs, ambig);
                }
            },
            .note => |planned| {
                drawFrameSideBordersBeforeDepth(canvas, row, planned.height, planned.depth, total_cols, glyphs);
                try drawNoteAtRow(canvas, row, diagram.notes[planned.note_idx], cell_w, step_w, glyphs, ambig);
            },
        }
        row += item.height();
    }
}

fn drawWrappedBandBody(
    canvas: *canvas_mod.Canvas,
    diagram: *const types.SequenceDiagram,
    plan: *const SequenceLayoutPlan,
    band: ParticipantBand,
    cell_w: usize,
    step_w: usize,
    body_top: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    var row = body_top;
    const total_cols = canvas.cols;

    for (plan.items) |item| {
        switch (item) {
            .block_start => |planned| {
                drawFrameSideBordersBeforeDepth(canvas, row, planned.height, planned.depth, total_cols, glyphs);
                const label_layout = planned.layout orelse return error.InvalidMermaid;
                try drawWrappedBlockStart(canvas, row, planned.height, planned.depth, total_cols, &label_layout, glyphs, ambig);
            },
            .block_divider => |planned| {
                drawFrameSideBordersBeforeDepth(canvas, row, planned.height, planned.depth, total_cols, glyphs);
                const label_layout = planned.layout orelse return error.InvalidMermaid;
                try drawWrappedBlockDivider(canvas, row, planned.height, planned.depth, total_cols, &label_layout, glyphs, ambig);
            },
            .block_end => |planned| {
                drawFrameSideBordersBeforeDepth(canvas, row, wrapped_block_end_height, planned.depth, total_cols, glyphs);
                drawBlockEndRow(canvas, row, planned.depth, total_cols, glyphs);
            },
            .message => |planned| {
                const message = diagram.messages[planned.message_idx];
                drawFrameSideBordersBeforeDepth(canvas, row, planned.height, planned.depth, total_cols, glyphs);
                try drawWrappedMessage(canvas, row, planned, message, band, cell_w, step_w, total_cols, glyphs, ambig);
            },
            .note => |planned| {
                drawFrameSideBordersBeforeDepth(canvas, row, planned.height, planned.depth, total_cols, glyphs);
                try drawWrappedNote(canvas, row, planned, total_cols, glyphs, ambig);
            },
        }
        row += item.height();
    }
}

fn drawFrameSideBordersBeforeDepth(
    canvas: *canvas_mod.Canvas,
    row: usize,
    height: usize,
    depth: usize,
    total_cols: usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    var d: usize = 0;
    while (d < depth) : (d += 1) {
        drawFrameSideBorders(canvas, row, height, d, total_cols, glyphs);
    }
}

fn participantBandIndex(participant_id: types.ParticipantId, max_per_band: usize) usize {
    return @as(usize, @intCast(participant_id)) / max_per_band;
}

fn participantDisplayLabel(diagram: *const types.SequenceDiagram, participant_id: types.ParticipantId) []const u8 {
    const idx: usize = @intCast(participant_id);
    if (idx >= diagram.participants.len) return "?";
    return diagram.participants[idx].label;
}

fn bandOrdinal(band: ParticipantBand) usize {
    return band.start / band.max_per_band;
}

fn bandContainsParticipant(band: ParticipantBand, participant_id: types.ParticipantId) bool {
    const idx: usize = @intCast(participant_id);
    return idx >= band.start and idx < band.end;
}

fn localParticipantIndex(band: ParticipantBand, participant_id: types.ParticipantId) usize {
    return @as(usize, @intCast(participant_id)) - band.start;
}

fn messageRelevantToBand(message: types.SequenceMessage, band: ParticipantBand) bool {
    const current_band = bandOrdinal(band);
    const from_band = participantBandIndex(message.from, band.max_per_band);
    const to_band = participantBandIndex(message.to, band.max_per_band);
    return current_band == from_band or current_band == to_band;
}

fn messageCrossesBands(message: types.SequenceMessage, band: ParticipantBand) bool {
    return participantBandIndex(message.from, band.max_per_band) != participantBandIndex(message.to, band.max_per_band);
}

fn noteRelevantToBand(note: types.SequenceNote, band: ParticipantBand) bool {
    if (note.actor_ids.len == 0) return false;
    const current_band = bandOrdinal(band);
    for (note.actor_ids) |actor_id| {
        if (participantBandIndex(actor_id, band.max_per_band) == current_band) return true;
    }
    return false;
}

fn noteSpansMultipleBands(note: types.SequenceNote, band: ParticipantBand) bool {
    if (note.actor_ids.len < 2) return false;
    const first_band = participantBandIndex(note.actor_ids[0], band.max_per_band);
    for (note.actor_ids[1..]) |actor_id| {
        if (participantBandIndex(actor_id, band.max_per_band) != first_band) return true;
    }
    return false;
}

fn blockAffectsBand(
    diagram: *const types.SequenceDiagram,
    block: types.SequenceBlock,
    band: ParticipantBand,
) bool {
    const start: usize = @intCast(block.start_index);
    const end: usize = @min(@as(usize, @intCast(block.end_index)), diagram.messages.len -| 1);
    if (start <= end and start < diagram.messages.len) {
        for (diagram.messages[start .. end + 1]) |message| {
            if (messageRelevantToBand(message, band)) return true;
        }
    }
    for (diagram.notes) |note| {
        if (note.after_index < 0) continue;
        const note_idx: usize = @intCast(note.after_index);
        if (note_idx >= start and note_idx <= end and noteRelevantToBand(note, band)) return true;
    }
    return start >= diagram.messages.len and band.start == 0;
}

fn nextSequenceBlockToOpen(
    diagram: *const types.SequenceDiagram,
    msg_idx: u32,
    active_blocks: []const ActiveBlock,
    closed_blocks: []const usize,
    layout: SequenceBandLayout,
) ?usize {
    var best: ?usize = null;
    var best_order: u32 = std.math.maxInt(u32);
    for (diagram.blocks, 0..) |block, block_idx| {
        if (block.start_index != msg_idx) continue;
        if (layout.mode == .wrapped and !blockAffectsBand(diagram, block, layout.band)) continue;
        if (isWrappedBlockActive(active_blocks, block_idx)) continue;
        if (std.mem.findScalar(usize, closed_blocks, block_idx) != null) continue;
        if (block.source_order < best_order) {
            best = block_idx;
            best_order = block.source_order;
        }
    }
    return best;
}

fn isWrappedBlockActive(active_blocks: []const ActiveBlock, block_idx: usize) bool {
    for (active_blocks) |active| {
        if (active.block_idx == block_idx) return true;
    }
    return false;
}

fn messageArrowText(message: types.SequenceMessage) []const u8 {
    return switch (message.line_style) {
        .solid => switch (message.arrow_head) {
            .filled => "->>",
            .open => "->",
        },
        .dashed => switch (message.arrow_head) {
            .filled => "-->>",
            .open => "-->",
        },
    };
}

fn notePlacementText(placement: types.NotePlacement) []const u8 {
    return switch (placement) {
        .right_of => "right of",
        .left_of => "left of",
        .over => "over",
    };
}

fn blockTextBudget(total_cols: usize, depth: usize) RenderError!usize {
    if (total_cols <= depth * 2 + 4) return error.WidthTooSmall;
    return total_cols - depth * 2 - 4;
}

fn blockHeaderText(allocator: std.mem.Allocator, block: types.SequenceBlock) std.mem.Allocator.Error![]u8 {
    const kind = blockKindName(block.kind);
    if (block.label.len == 0) return allocator.dupe(u8, kind);
    return std.fmt.allocPrint(allocator, "{s} [{s}]", .{ kind, block.label });
}

fn drawWrappedBlockStart(
    canvas: *canvas_mod.Canvas,
    row: usize,
    height: usize,
    depth: usize,
    total_cols: usize,
    layout: *const text_layout.LabelLayout,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    drawWrappedBlockTop(canvas, row, depth, total_cols, glyphs);
    drawWrappedBlockSideContinuations(canvas, row + 1, height - 1, depth, total_cols, glyphs);
    try drawWrappedTextLines(canvas, row, depth, total_cols, layout.lines, true, ambig);
}

fn drawWrappedBlockDivider(
    canvas: *canvas_mod.Canvas,
    row: usize,
    height: usize,
    depth: usize,
    total_cols: usize,
    layout: *const text_layout.LabelLayout,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    drawWrappedBlockDividerTop(canvas, row, depth, total_cols, glyphs);
    drawWrappedBlockSideContinuations(canvas, row + 1, height - 1, depth, total_cols, glyphs);
    try drawWrappedTextLines(canvas, row, depth, total_cols, layout.lines, true, ambig);
}

fn drawWrappedBlockTop(
    canvas: *canvas_mod.Canvas,
    row: usize,
    depth: usize,
    total_cols: usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    if (total_cols <= depth * 2 + 2) return;
    const left = depth;
    const right = total_cols - 1 - depth;
    canvas.setGlyph(row, left, glyphs.corner_tl);
    canvas.setGlyph(row, right, glyphs.corner_tr);
    var col = left + 1;
    while (col < right) : (col += 1) canvas.setGlyph(row, col, glyphs.h_line);
}

fn drawWrappedBlockDividerTop(
    canvas: *canvas_mod.Canvas,
    row: usize,
    depth: usize,
    total_cols: usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    if (total_cols <= depth * 2 + 2) return;
    const left = depth;
    const right = total_cols - 1 - depth;
    canvas.setGlyph(row, left, glyphs.tee_l);
    canvas.setGlyph(row, right, glyphs.tee_r);
    var col = left + 1;
    while (col < right) : (col += 1) canvas.setGlyph(row, col, glyphs.h_line_dashed);
}

fn drawWrappedBlockSideContinuations(
    canvas: *canvas_mod.Canvas,
    row: usize,
    height: usize,
    depth: usize,
    total_cols: usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    if (total_cols <= depth * 2 + 2) return;
    const left = depth;
    const right = total_cols - 1 - depth;
    var r = row;
    while (r < row + height) : (r += 1) {
        canvas.setGlyph(r, left, glyphs.v_line);
        canvas.setGlyph(r, right, glyphs.v_line);
    }
}

fn drawWrappedTextLines(
    canvas: *canvas_mod.Canvas,
    row: usize,
    depth: usize,
    total_cols: usize,
    lines: []const types.LabelLine,
    block_row: bool,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    const left = if (block_row) depth + 2 else depth * 2;
    const right = if (depth == 0) total_cols else total_cols - depth;
    if (left >= right) return error.WidthTooSmall;
    for (lines, 0..) |line, idx| {
        try canvas.drawLabel(row + idx, left, line.text, ambig);
    }
}

fn planWrappedMessage(
    allocator: std.mem.Allocator,
    diagram: *const types.SequenceDiagram,
    message: types.SequenceMessage,
    message_idx: usize,
    band: ParticipantBand,
    cell_w: usize,
    step_w: usize,
    total_cols: usize,
    frame_depth: usize,
    ambig: width_mod.AmbiguousWidth,
) RenderError!SequenceBodyItem.Message {
    if (messageCrossesBands(message, band)) {
        const text = try crossBandMessageText(allocator, diagram, message);
        defer allocator.free(text);
        const layout = try text_layout.layoutLabel(allocator, text, try continuationTextBudget(total_cols, frame_depth), ambig);
        return .{
            .message_idx = message_idx,
            .depth = frame_depth,
            .height = @max(@as(usize, 1), layout.lines.len),
            .continuation_layout = layout,
        };
    }

    if (message.label.len == 0) {
        return .{
            .message_idx = message_idx,
            .depth = frame_depth,
            .height = 2,
        };
    }

    const budget = messageLabelBudget(message, band, cell_w, step_w, total_cols);
    const layout = try text_layout.layoutLabel(allocator, message.label, budget, ambig);
    return .{
        .message_idx = message_idx,
        .depth = frame_depth,
        .height = @max(@as(usize, 2), layout.lines.len + 1),
        .label_layout = layout,
    };
}

fn drawWrappedMessage(
    canvas: *canvas_mod.Canvas,
    row: usize,
    planned: SequenceBodyItem.Message,
    message: types.SequenceMessage,
    band: ParticipantBand,
    cell_w: usize,
    step_w: usize,
    total_cols: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    if (planned.continuation_layout) |layout| {
        return drawWrappedTextLines(canvas, row, planned.depth, total_cols, layout.lines, false, ambig);
    }

    const from_center = participantCenter(@intCast(localParticipantIndex(band, message.from)), cell_w, step_w);
    const to_center = participantCenter(@intCast(localParticipantIndex(band, message.to)), cell_w, step_w);
    if (from_center == to_center) {
        return drawWrappedSelfMessage(canvas, row, planned.height, from_center, cell_w, message, planned.label_layout, glyphs, ambig);
    }
    return drawWrappedMessageArrow(canvas, row, planned.height, from_center, to_center, message, planned.label_layout, glyphs, ambig);
}

fn messageLabelBudget(
    message: types.SequenceMessage,
    band: ParticipantBand,
    cell_w: usize,
    step_w: usize,
    total_cols: usize,
) usize {
    const from_center = participantCenter(@intCast(localParticipantIndex(band, message.from)), cell_w, step_w);
    const to_center = participantCenter(@intCast(localParticipantIndex(band, message.to)), cell_w, step_w);
    if (from_center == to_center) {
        return selfMessageLabelBudget(from_center, total_cols);
    }
    const lo = @min(from_center, to_center);
    const hi = @max(from_center, to_center);
    return @max(@as(usize, 1), hi - lo -| 3);
}

fn selfMessageLabelBudget(center: usize, total_cols: usize) usize {
    const label_col = center + 2;
    if (label_col >= total_cols) return 1;
    return @max(@as(usize, 1), total_cols - label_col);
}

fn drawWrappedMessageArrow(
    canvas: *canvas_mod.Canvas,
    row: usize,
    height: usize,
    from_center: usize,
    to_center: usize,
    message: types.SequenceMessage,
    label_layout: ?text_layout.LabelLayout,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    if (label_layout) |layout| {
        const mid = (from_center + to_center) / 2;
        for (layout.lines, 0..) |line, idx| {
            try drawCenteredLine(canvas, row + idx, mid, line, ambig);
        }
    }

    const arrow_row = row + height - 1;
    const lo = @min(from_center, to_center);
    const hi = @max(from_center, to_center);
    const going_right = to_center > from_center;
    const line_glyph = horizontalLineGlyph(message, glyphs);

    var col = lo + 1;
    while (col < hi) : (col += 1) canvas.setGlyph(arrow_row, col, line_glyph);

    if (going_right) {
        canvas.setGlyph(arrow_row, hi, arrowRightGlyph(message, glyphs));
    } else {
        canvas.setGlyph(arrow_row, lo, arrowLeftGlyph(message, glyphs));
    }
}

fn drawWrappedSelfMessage(
    canvas: *canvas_mod.Canvas,
    row: usize,
    height: usize,
    center: usize,
    cell_w: usize,
    message: types.SequenceMessage,
    label_layout: ?text_layout.LabelLayout,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    const loop_w: usize = @max(cell_w / 2, 4);
    const right = if (center + loop_w < canvas.cols) center + loop_w else canvas.cols - 1;
    if (right <= center) return;

    const line_glyph = horizontalLineGlyph(message, glyphs);
    const arrow_row = row + height - 1;

    var col = center + 1;
    while (col <= right) : (col += 1) canvas.setGlyph(row, col, line_glyph);
    var r = row + 1;
    while (r < arrow_row) : (r += 1) canvas.setGlyph(r, right, glyphs.v_line);
    col = center + 1;
    while (col < right) : (col += 1) canvas.setGlyph(arrow_row, col, line_glyph);
    canvas.setGlyph(row, right, glyphs.corner_tr);
    canvas.setGlyph(arrow_row, right, glyphs.corner_br);
    canvas.setGlyph(arrow_row, center + 1, arrowLeftGlyph(message, glyphs));

    const layout = label_layout orelse return;
    const label_col = @min(center + 2, canvas.cols - 1);
    for (layout.lines, 0..) |line, idx| {
        try canvas.drawLabel(row + idx, label_col, line.text, ambig);
    }
}

fn drawCenteredLine(
    canvas: *canvas_mod.Canvas,
    row: usize,
    center: usize,
    line: types.LabelLine,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    var col = if (center > line.width / 2) center - line.width / 2 else 0;
    if (line.width < canvas.cols and col + line.width > canvas.cols) {
        col = canvas.cols - line.width;
    }
    try canvas.drawLabel(row, col, line.text, ambig);
}

fn horizontalLineGlyph(message: types.SequenceMessage, glyphs: *const canvas_mod.GlyphSet) u21 {
    return if (message.line_style == .dashed) glyphs.h_line_dashed else glyphs.h_line;
}

fn arrowRightGlyph(message: types.SequenceMessage, glyphs: *const canvas_mod.GlyphSet) u21 {
    if (message.arrow_head == .filled) return glyphs.arrow_right;
    return if (glyphs.arrow_right == '>') '>' else '▷';
}

fn arrowLeftGlyph(message: types.SequenceMessage, glyphs: *const canvas_mod.GlyphSet) u21 {
    if (message.arrow_head == .filled) return glyphs.arrow_left;
    return if (glyphs.arrow_left == '<') '<' else '◁';
}

fn planWrappedNote(
    allocator: std.mem.Allocator,
    diagram: *const types.SequenceDiagram,
    note: types.SequenceNote,
    note_idx: usize,
    band: ParticipantBand,
    cell_w: usize,
    step_w: usize,
    total_cols: usize,
    frame_depth: usize,
    ambig: width_mod.AmbiguousWidth,
) RenderError!SequenceBodyItem.Note {
    if (noteSpansMultipleBands(note, band)) {
        const text = try crossBandNoteText(allocator, diagram, note);
        defer allocator.free(text);
        const layout = try text_layout.layoutLabel(allocator, text, try continuationTextBudget(total_cols, frame_depth), ambig);
        return .{
            .note_idx = note_idx,
            .depth = frame_depth,
            .height = @max(@as(usize, 1), layout.lines.len),
            .layout = layout,
        };
    }

    const frame = computeWrappedNoteFrame(note, band, cell_w, step_w, total_cols, frame_depth, ambig) orelse return error.WidthTooSmall;
    const layout = try text_layout.layoutLabel(allocator, note.text, frame.width - 2, ambig);
    return .{
        .note_idx = note_idx,
        .depth = frame_depth,
        .height = @max(@as(usize, 3), layout.lines.len + 2),
        .frame = frame,
        .layout = layout,
    };
}

fn drawWrappedNote(
    canvas: *canvas_mod.Canvas,
    row: usize,
    planned: SequenceBodyItem.Note,
    total_cols: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    const label_layout = planned.layout orelse return error.InvalidMermaid;
    const frame = planned.frame orelse {
        return drawWrappedTextLines(canvas, row, planned.depth, total_cols, label_layout.lines, false, ambig);
    };

    canvas.drawRect(row, frame.left, planned.height, frame.width, glyphs);
    clearCanvasRect(canvas, row + 1, frame.left + 1, planned.height - 2, frame.width - 2);
    try text_layout.drawCenteredLabel(canvas, row + 1, frame.left + 1, planned.height - 2, frame.width - 2, label_layout.lines, ambig);
}

fn clearCanvasRect(canvas: *canvas_mod.Canvas, top: usize, left: usize, height: usize, width: usize) void {
    var row: usize = top;
    while (row < top + height) : (row += 1) {
        var col: usize = left;
        while (col < left + width) : (col += 1) {
            canvas.setGlyph(row, col, ' ');
        }
    }
}

const NoteFrame = struct {
    left: usize,
    width: usize,
};

const NoteFrameBounds = struct {
    left: usize,
    width: usize,

    fn right(self: NoteFrameBounds) usize {
        return self.left + self.width;
    }
};

fn computeWrappedNoteFrame(
    note: types.SequenceNote,
    band: ParticipantBand,
    cell_w: usize,
    step_w: usize,
    total_cols: usize,
    frame_depth: usize,
    ambig: width_mod.AmbiguousWidth,
) ?NoteFrame {
    if (note.actor_ids.len == 0) return null;
    if (!bandContainsParticipant(band, note.actor_ids[0])) return null;
    const bounds = noteFrameBounds(total_cols, frame_depth) orelse return null;
    const p_center = participantCenter(@intCast(localParticipantIndex(band, note.actor_ids[0])), cell_w, step_w);
    const desired = @max(min_wrapped_note_width, width_mod.displayWidth(note.text, ambig) + 4);

    switch (note.placement) {
        .right_of => {
            const left = @max(p_center + 2, bounds.left);
            if (left + min_wrapped_note_width > bounds.right()) return fallbackWrappedNoteFrame(bounds);
            return .{ .left = left, .width = @min(desired, bounds.right() - left) };
        },
        .left_of => {
            const right_limit = if (p_center > bounds.left + 2) p_center - 2 else bounds.left;
            const max_w = right_limit - bounds.left;
            if (max_w < min_wrapped_note_width) return fallbackWrappedNoteFrame(bounds);
            const note_w = @min(desired, max_w);
            const left = right_limit - note_w;
            return .{ .left = left, .width = note_w };
        },
        .over => {
            if (note.actor_ids.len >= 2) {
                if (!bandContainsParticipant(band, note.actor_ids[1])) return null;
                const other = participantCenter(@intCast(localParticipantIndex(band, note.actor_ids[1])), cell_w, step_w);
                const lo = @min(p_center, other);
                const hi = @max(p_center, other);
                const span_w = hi - lo + 4;
                const left = @max(if (lo >= 2) lo - 2 else 0, bounds.left);
                const available = bounds.right() - left;
                if (available < @max(span_w, min_wrapped_note_width)) return fallbackWrappedNoteFrame(bounds);
                return .{ .left = left, .width = @max(span_w, @min(desired, available)) };
            }

            const note_w = @min(desired, bounds.width);
            var left = if (p_center > note_w / 2) p_center - note_w / 2 else 0;
            if (left < bounds.left) left = bounds.left;
            if (left + note_w > bounds.right()) left = bounds.right() - note_w;
            return .{ .left = left, .width = note_w };
        },
    }
}

fn noteFrameBounds(total_cols: usize, frame_depth: usize) ?NoteFrameBounds {
    if (total_cols <= frame_depth * 2) return null;
    const width = total_cols - frame_depth * 2;
    if (width < min_wrapped_note_width) return null;
    return .{ .left = frame_depth, .width = width };
}

fn fallbackWrappedNoteFrame(bounds: NoteFrameBounds) NoteFrame {
    return .{ .left = bounds.left, .width = bounds.width };
}

fn continuationTextBudget(total_cols: usize, frame_depth: usize) RenderError!usize {
    const left = frame_depth * 2;
    const right = if (frame_depth == 0) total_cols else total_cols - frame_depth;
    if (left >= right) return error.WidthTooSmall;
    return right - left;
}

fn crossBandMessageText(
    allocator: std.mem.Allocator,
    diagram: *const types.SequenceDiagram,
    message: types.SequenceMessage,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "[cross-band] {s} {s} {s}: {s}",
        .{
            participantDisplayLabel(diagram, message.from),
            messageArrowText(message),
            participantDisplayLabel(diagram, message.to),
            message.label,
        },
    );
}

fn crossBandNoteText(
    allocator: std.mem.Allocator,
    diagram: *const types.SequenceDiagram,
    note: types.SequenceNote,
) RenderError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "[cross-band] Note {s} ", .{notePlacementText(note.placement)});
    for (note.actor_ids, 0..) |actor_id, idx| {
        try buf.print(allocator, "{s}{s}", .{
            if (idx > 0) "," else "",
            participantDisplayLabel(diagram, actor_id),
        });
    }
    try buf.print(allocator, ": {s}", .{note.text});
    return try buf.toOwnedSlice(allocator);
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

fn drawParticipantBoxes(
    canvas: *canvas_mod.Canvas,
    diagram: *const types.SequenceDiagram,
    cell_w: usize,
    step_w: usize,
    top_row: usize,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) RenderError!void {
    for (diagram.participants, 0..) |p, i| {
        const left = i * step_w;
        canvas.drawRect(top_row, left, box_h, cell_w, glyphs);
        const lw = width_mod.displayWidth(p.label, ambig);
        const inner = cell_w - 2;
        const offset = if (inner > lw) (inner - lw) / 2 else 0;
        try canvas.drawLabel(top_row + 1, left + 1 + offset, p.label, ambig);
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

const ActiveBlock = struct { block_idx: usize };

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
) error{OutOfMemory}!void {
    if (total_cols <= indent * 2 + 2) return;
    const left = indent;
    const right = total_cols - 1 - indent;

    canvas.setGlyph(row, left, glyphs.corner_tl);
    canvas.setGlyph(row, right, glyphs.corner_tr);
    var c = left + 1;
    while (c < right) : (c += 1) {
        canvas.setGlyph(row, c, glyphs.h_line);
    }

    const kind_text = blockKindName(kind);
    const kind_w = width_mod.displayWidth(kind_text, ambig);
    if (left + 2 + kind_w < right) {
        canvas.setGlyph(row, left + 1, ' ');
        try canvas.drawLabel(row, left + 2, kind_text, ambig);
        if (label.len > 0) {
            const bracket_col = left + 2 + kind_w;
            if (bracket_col + 2 < right) {
                canvas.setGlyph(row, bracket_col, ' ');
                canvas.setGlyph(row, bracket_col + 1, '[');
                try canvas.drawLabel(row, bracket_col + 2, label, ambig);
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
) error{OutOfMemory}!void {
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
        try canvas.drawLabel(row, left + 2, label, ambig);
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
) error{OutOfMemory}!void {
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
        try canvas.drawLabel(row + 1, left + 1 + text_offset, note.text, ambig);
    }
}

fn drawMessageArrow(
    canvas: *canvas_mod.Canvas,
    label_row: usize,
    arrow_row: usize,
    from_center: usize,
    to_center: usize,
    msg: types.SequenceMessage,
    glyphs: *const canvas_mod.GlyphSet,
    ambig: width_mod.AmbiguousWidth,
) error{OutOfMemory}!void {
    const lo = @min(from_center, to_center);
    const hi = @max(from_center, to_center);
    const going_right = to_center > from_center;

    const label_w = width_mod.displayWidth(msg.label, ambig);
    if (label_w > 0) {
        const mid = (from_center + to_center) / 2;
        const half = label_w / 2;
        const col = if (mid > half) mid - half else 0;
        if (col + label_w <= canvas.cols) try canvas.drawLabel(label_row, col, msg.label, ambig);
    }

    const line_glyph: u21 = if (msg.line_style == .dashed) '╌' else glyphs.h_line;
    var c = lo + 1;
    while (c < hi) : (c += 1) {
        canvas.setGlyph(arrow_row, c, line_glyph);
    }

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
) error{OutOfMemory}!void {
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
        if (col + lw <= canvas.cols) try canvas.drawLabel(label_row, col, msg.label, ambig);
    }
}

test "paintSequence renders participant boxes and arrow" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    Alice->>Bob: Hello
        \\    Bob-->>Alice: Hi
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "Alice") != null);
    try std.testing.expect(std.mem.find(u8, out, "Bob") != null);
    try std.testing.expect(std.mem.find(u8, out, "Hello") != null);
    try std.testing.expect(std.mem.find(u8, out, "Hi") != null);
    try std.testing.expect(std.mem.find(u8, out, "►") != null);
    try std.testing.expect(std.mem.find(u8, out, "◄") != null);
}

test "paintSequence handles single participant with no messages" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc, "sequenceDiagram\n    participant Alice\n");
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "Alice") != null);
}

test "paintSequence keeps hard-break labels separated for single-line layout" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    A->>B: first<br/>second
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "first second") != null);
    try std.testing.expect(std.mem.find(u8, out, "firstsecond") == null);
}

test "renderer draws filled and open arrow heads" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    A->>B: filled
        \\    B->A: open
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "►") != null);
    try std.testing.expect(std.mem.find(u8, out, "◁") != null);
}

test "note with after_index=-1 is NOT rendered" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    Note right of A: early
        \\    A->>B: msg
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "early") == null);
    try std.testing.expect(std.mem.find(u8, out, "msg") != null);
}

test "note with after_index>=0 IS rendered" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    A->>B: msg
        \\    Note right of B: visible
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "visible") != null);
}

test "activate/deactivate flags are parsed but ASCII does not draw activation (upstream parity)" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    A->>+B: Hello
        \\    A->>-B: World
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "Hello") != null);
    try std.testing.expect(std.mem.find(u8, out, "World") != null);
    try std.testing.expect(std.mem.find(u8, out, "║") == null);
}

test "block header uses kind [label] format" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    loop every minute
        \\        A->>B: ping
        \\    end
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "loop [every minute]") != null);
}

test "label-less block renders kind only without brackets" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    loop
        \\        A->>B: ping
        \\    end
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "loop") != null);
    try std.testing.expect(std.mem.find(u8, out, "loop [") == null);
}

test "nested blocks render outer before inner" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    loop outer
        \\        alt inner
        \\            A->>B: yes
        \\        end
        \\    end
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    const loop_pos = std.mem.find(u8, out, "loop [outer]") orelse return error.WriteFailed;
    const alt_pos = std.mem.find(u8, out, "alt [inner]") orelse return error.WriteFailed;
    try std.testing.expect(loop_pos < alt_pos);

    const msg_end = std.mem.find(u8, out, "yes") orelse return error.WriteFailed;
    const rest = out[msg_end..];
    const first_bl = std.mem.find(u8, rest, "└") orelse return error.WriteFailed;
    if (first_bl > 0) {
        try std.testing.expect(rest[first_bl - 1] != '\n');
    }
}

test "empty block still renders frame" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    participant A
        \\    loop empty
        \\    end
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "loop [empty]") != null);
}

test "activate/deactivate with multiple messages renders normally without activation marks" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    A->>+B: Hello
        \\    A->>B: working
        \\    A->>-B: Done
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "Hello") != null);
    try std.testing.expect(std.mem.find(u8, out, "working") != null);
    try std.testing.expect(std.mem.find(u8, out, "Done") != null);
    try std.testing.expect(std.mem.find(u8, out, "║") == null);
}

test "Note over two participants spans both lifelines" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    participant Alice
        \\    participant Bob
        \\    Alice->>Bob: Hello
        \\    Note over Alice,Bob: ok
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    const arrow_pos = std.mem.find(u8, out, "Hello") orelse return error.WriteFailed;
    const rest = out[arrow_pos..];
    const tl = std.mem.find(u8, rest, "┌") orelse return error.WriteFailed;
    const tr = std.mem.find(u8, rest, "┐") orelse return error.WriteFailed;
    const note_span = tr - tl;
    try std.testing.expect(note_span > 20);
}

test "long Note over is not silently dropped" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    A->>B: x
        \\    Note over A,B: This is a very long note that should still appear
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "very long note") != null);
}

test "Note left of with long text is not silently dropped" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    A->>B: x
        \\    Note left of A: left side note here
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "left side note") != null);
}

test "long else label is fully rendered" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    alt success
        \\        A->>B: ok
        \\    else failed because timeout exceeded
        \\        A->>B: err
        \\    end
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "failed because timeout exceeded") != null);
}

test "nested block with long inner header is fully rendered" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    loop outer
        \\        alt very long inner condition label here
        \\            A->>B: ok
        \\        end
        \\    end
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "very long inner condition label here") != null);
}

test "nested else divider label is fully rendered" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    loop outer
        \\        alt ok
        \\            A->>B: yes
        \\        else failed with a very long reason description
        \\            A->>B: no
        \\        end
        \\    end
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "failed with a very long reason description") != null);
}

test "nested block outer frame has no gaps on inner block rows" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    loop outer
        \\        alt inner
        \\            A->>B: yes
        \\        end
        \\    end
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "│┌") != null);
    try std.testing.expect(std.mem.find(u8, out, "│└") != null);
}

test "final flush of nested empty blocks has outer frame borders" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    participant A
        \\    loop outer
        \\        alt inner
        \\        end
        \\    end
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "loop [outer]") != null);
    try std.testing.expect(std.mem.find(u8, out, "alt [inner]") != null);
    try std.testing.expect(std.mem.find(u8, out, "│└") != null);
}

test "sequential blocks at same index are not nested" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\sequenceDiagram
        \\    loop a
        \\    end
        \\    loop b
        \\        A->>B: x
        \\    end
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintSequence(&sink.writer, alloc, &diagram.sequence, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "loop [a]") != null);
    try std.testing.expect(std.mem.find(u8, out, "loop [b]") != null);
    const a_pos = std.mem.find(u8, out, "loop [a]").?;
    const b_pos = std.mem.find(u8, out, "loop [b]").?;
    try std.testing.expect(a_pos < b_pos);
    try std.testing.expect(std.mem.find(u8, out, "│┌ loop") == null);
}
