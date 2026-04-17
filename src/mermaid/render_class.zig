const std = @import("std");
const types = @import("types.zig");
const parse = @import("parse_class.zig");
const canvas_mod = @import("canvas.zig");
const route_mod = @import("route.zig");
const layout_flowchart = @import("layout_flowchart.zig");
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
    enable_ansi: bool = false,
};

const StyleKind = enum { static_, abstract_ };

const StyledSpan = struct {
    row: usize,
    col_start: usize,
    col_end: usize,
    kind: StyleKind,
};

pub fn writeClass(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    var diagram = parse.parseSource(allocator, source) catch |err| switch (err) {
        error.InvalidMermaid, error.TooManyClasses => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer diagram.deinit();

    if (diagram.classes.len == 0) return;

    const layout_info = try computeLayout(allocator, &diagram, opts.ambiguous_width);
    defer {
        var mutable_layout = layout_info.flow_layout;
        mutable_layout.deinit();
        allocator.free(layout_info.flow_graph_nodes);
        allocator.free(layout_info.flow_graph_edges);
    }

    const flow_layout = layout_info.flow_layout;
    if (flow_layout.rows == 0 or flow_layout.cols == 0) return;

    const glyphs = canvas_mod.GlyphSet.unicode;

    const canvas_rows = route_mod.canvasRows(&flow_layout);
    const canvas_cols = route_mod.canvasCols(&flow_layout);
    var canvas = canvas_mod.Canvas.init(allocator, canvas_rows, canvas_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    for (diagram.namespaces) |ns| {
        drawNamespaceFrame(&canvas, &flow_layout, &diagram, ns, &glyphs, opts.ambiguous_width);
    }

    var spans: std.ArrayListUnmanaged(StyledSpan) = .empty;
    defer spans.deinit(allocator);

    for (diagram.classes, 0..) |cls, i| {
        const pos = flow_layout.positions[i];
        const top = route_mod.boxTop(&flow_layout, pos.row);
        const left = route_mod.boxLeft(&flow_layout, pos.col);
        try drawClassBox(allocator, &canvas, top, left, actualBoxHeight(&cls), flow_layout.cell_w, &cls, &glyphs, opts.ambiguous_width, if (opts.enable_ansi) &spans else null);
    }

    for (diagram.relations) |rel| {
        drawRelation(allocator, &canvas, &flow_layout, &diagram, rel, &glyphs, opts.ambiguous_width) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    route_mod.mergeJunctions(allocator, &canvas, &glyphs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (opts.enable_ansi and spans.items.len > 0) {
        try writeCanvasWithSpans(writer, allocator, &canvas, spans.items, opts);
    } else {
        canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
    }
}

fn writeCanvasWithSpans(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    canvas: *const canvas_mod.Canvas,
    spans: []const StyledSpan,
    opts: Options,
) RenderError!void {
    var sink: std.io.Writer.Allocating = .init(allocator);
    defer sink.deinit();
    canvas_mod.writeCanvas(&sink.writer, canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;

    const plain = sink.writer.buffered();

    var row: usize = 0;
    var line_it = std.mem.splitScalar(u8, plain, '\n');
    var first = true;
    while (line_it.next()) |line| : (row += 1) {
        if (!first) writer.writeByte('\n') catch return error.WriteFailed;
        first = false;
        try writeLineWithSpans(writer, line, row, spans, opts.ambiguous_width);
    }
}

fn writeLineWithSpans(
    writer: *std.io.Writer,
    line: []const u8,
    row: usize,
    spans: []const StyledSpan,
    ambiguous: width_mod.AmbiguousWidth,
) RenderError!void {
    var col: usize = 0;
    var i: usize = 0;
    var open_static = false;
    var open_abstract = false;
    while (i < line.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const cp_end = @min(i + cp_len, line.len);
        const cp_bytes = line[i..cp_end];
        const cp_w: usize = if (cp_bytes.len == 1 and (cp_bytes[0] == ' ' or cp_bytes[0] == '\t'))
            1
        else
            width_mod.displayWidth(cp_bytes, ambiguous);

        if (!open_static and hasSpanStart(spans, row, col, .static_)) {
            try writeStyleOpen(writer, .static_);
            open_static = true;
        }
        if (!open_abstract and hasSpanStart(spans, row, col, .abstract_)) {
            try writeStyleOpen(writer, .abstract_);
            open_abstract = true;
        }

        writer.writeAll(cp_bytes) catch return error.WriteFailed;

        if (open_static and spanEndsAt(spans, row, col + cp_w, .static_)) {
            try writeStyleClose(writer, .static_);
            open_static = false;
        }
        if (open_abstract and spanEndsAt(spans, row, col + cp_w, .abstract_)) {
            try writeStyleClose(writer, .abstract_);
            open_abstract = false;
        }

        col += cp_w;
        i = cp_end;
    }
    if (open_static) try writeStyleClose(writer, .static_);
    if (open_abstract) try writeStyleClose(writer, .abstract_);
}

fn hasSpanStart(spans: []const StyledSpan, row: usize, col: usize, kind: StyleKind) bool {
    for (spans) |s| {
        if (s.row == row and s.col_start == col and s.kind == kind) return true;
    }
    return false;
}

fn spanEndsAt(spans: []const StyledSpan, row: usize, col: usize, kind: StyleKind) bool {
    for (spans) |s| {
        if (s.row == row and s.kind == kind and s.col_end == col) return true;
    }
    return false;
}

fn writeStyleOpen(writer: *std.io.Writer, kind: StyleKind) RenderError!void {
    const seq: []const u8 = switch (kind) {
        .static_ => "\x1b[4m",
        .abstract_ => "\x1b[3m",
    };
    writer.writeAll(seq) catch return error.WriteFailed;
}

fn writeStyleClose(writer: *std.io.Writer, kind: StyleKind) RenderError!void {
    const seq: []const u8 = switch (kind) {
        .static_ => "\x1b[24m",
        .abstract_ => "\x1b[23m",
    };
    writer.writeAll(seq) catch return error.WriteFailed;
}

const LayoutInfo = struct {
    flow_layout: types.Layout,
    flow_graph_nodes: []types.Node,
    flow_graph_edges: []types.Edge,
};

pub const ClassLayoutError = error{OutOfMemory};

fn computeClassLayout(
    allocator: std.mem.Allocator,
    diagram: *const types.ClassDiagram,
    ambiguous: width_mod.AmbiguousWidth,
) ClassLayoutError!types.Layout {
    const n = diagram.classes.len;
    if (n == 0) {
        const positions = try allocator.alloc(types.GridPos, 0);
        errdefer allocator.free(positions);
        const labels = try allocator.alloc([]const u8, 0);
        return .{
            .allocator = allocator,
            .positions = positions,
            .truncated_labels = labels,
            .truncation_buf = null,
            .rows = 0,
            .cols = 0,
            .cell_w = 0,
            .cell_h = 0,
        };
    }

    const levels = try allocator.alloc(usize, n);
    defer allocator.free(levels);
    @memset(levels, 0);

    try assignClassLevels(allocator, diagram.relations, n, levels);

    var max_level: usize = 0;
    for (levels) |l| max_level = @max(max_level, l);

    const level_counts = try allocator.alloc(usize, max_level + 1);
    defer allocator.free(level_counts);
    @memset(level_counts, 0);

    const positions = try allocator.alloc(types.GridPos, n);
    errdefer allocator.free(positions);

    for (0..n) |i| {
        const level = levels[i];
        const col = level_counts[level];
        level_counts[level] += 1;
        positions[i] = .{
            .row = max_level - level,
            .col = col,
        };
    }

    var cols: usize = 0;
    for (level_counts) |c| cols = @max(cols, c);
    if (cols == 0) cols = 1;

    const truncated_labels = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(truncated_labels);

    return .{
        .allocator = allocator,
        .positions = positions,
        .truncated_labels = truncated_labels,
        .truncation_buf = null,
        .rows = max_level + 1,
        .cols = cols,
        .cell_w = computeRequiredBoxWidth(diagram, ambiguous),
        .cell_h = computeRequiredBoxHeight(diagram),
        .outer_pad = if (diagram.namespaces.len > 0) 2 else 0,
    };
}

fn assignClassLevels(
    allocator: std.mem.Allocator,
    relations: []const types.ClassRelation,
    n: usize,
    levels: []usize,
) ClassLayoutError!void {
    const remaining = try allocator.alloc(u32, n);
    defer allocator.free(remaining);
    @memset(remaining, 0);
    for (relations) |rel| {
        if (rel.to < n) remaining[rel.to] += 1;
    }

    var queue: std.ArrayListUnmanaged(types.NodeId) = .empty;
    defer queue.deinit(allocator);

    for (0..n) |i| {
        if (remaining[i] == 0) try queue.append(allocator, @intCast(i));
    }
    if (queue.items.len == 0) {
        try queue.append(allocator, 0);
        remaining[0] = 0;
    }

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const u = queue.items[qi];
        for (relations) |rel| {
            if (rel.from != u) continue;
            const v = rel.to;
            if (v >= n) continue;
            const candidate = levels[u] + 1;
            if (candidate > levels[v]) levels[v] = candidate;
            if (remaining[v] > 0) {
                remaining[v] -= 1;
                if (remaining[v] == 0) try queue.append(allocator, v);
            }
        }
    }
}

fn computeLayout(
    allocator: std.mem.Allocator,
    diagram: *const types.ClassDiagram,
    ambiguous: width_mod.AmbiguousWidth,
) RenderError!LayoutInfo {
    const nodes = allocator.alloc(types.Node, diagram.classes.len) catch return error.OutOfMemory;
    errdefer allocator.free(nodes);

    for (diagram.classes, 0..) |cls, i| {
        nodes[i] = .{
            .id = @intCast(i),
            .id_text = cls.id_text,
            .label = cls.label,
            .shape = .rect,
        };
    }

    const edges = allocator.alloc(types.Edge, diagram.relations.len) catch return error.OutOfMemory;
    errdefer allocator.free(edges);
    for (diagram.relations, 0..) |rel, i| {
        edges[i] = .{
            .from = rel.from,
            .to = rel.to,
            .label = rel.label,
            .style = .arrow,
        };
    }

    var flow_graph = types.MermaidGraph{
        .allocator = allocator,
        .direction = .bottom_up,
        .nodes = nodes,
        .edges = edges,
    };

    var layout = layout_flowchart.computeLayout(allocator, &flow_graph, ambiguous) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer layout.deinit();

    const required_box_h = computeRequiredBoxHeight(diagram);
    const required_box_w = computeRequiredBoxWidth(diagram, ambiguous);
    if (required_box_h > layout.cell_h) layout.cell_h = required_box_h;
    if (required_box_w > layout.cell_w) layout.cell_w = required_box_w;

    if (diagram.namespaces.len > 0 and layout.outer_pad < 2) layout.outer_pad = 2;

    return .{
        .flow_layout = layout,
        .flow_graph_nodes = nodes,
        .flow_graph_edges = edges,
    };
}

fn computeRequiredBoxHeight(diagram: *const types.ClassDiagram) usize {
    var max_h: usize = 3;
    for (diagram.classes) |c| max_h = @max(max_h, actualBoxHeight(&c));
    return max_h;
}

fn computeRequiredBoxWidth(diagram: *const types.ClassDiagram, ambiguous: width_mod.AmbiguousWidth) usize {
    var max_w: usize = 0;
    for (diagram.classes) |c| {
        max_w = @max(max_w, width_mod.displayWidth(c.label, ambiguous));
        if (c.annotation) |st| {
            max_w = @max(max_w, width_mod.displayWidth(st, ambiguous) + 2);
        }
        for (c.attributes) |m| max_w = @max(max_w, memberDisplayWidth(&m, false, ambiguous));
        for (c.methods) |m| max_w = @max(max_w, memberDisplayWidth(&m, true, ambiguous));
    }
    return @max(max_w + 4, 6);
}

fn memberDisplayWidth(member: *const types.ClassMember, is_method: bool, ambiguous: width_mod.AmbiguousWidth) usize {
    var w: usize = 0;
    if (member.visibility != .unknown) w += 2;
    w += width_mod.displayWidth(member.name, ambiguous);
    if (is_method) {
        w += 2;
        if (member.params) |p| w += width_mod.displayWidth(p, ambiguous);
    }
    if (member.type_text) |t| {
        w += 2;
        w += width_mod.displayWidth(t, ambiguous);
    }
    return w;
}

fn drawNamespaceFrame(
    canvas: *canvas_mod.Canvas,
    layout: *const types.Layout,
    diagram: *const types.ClassDiagram,
    ns: types.ClassNamespace,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) void {
    if (ns.class_ids.len == 0) return;

    var min_row: usize = std.math.maxInt(usize);
    var max_row: usize = 0;
    var min_col: usize = std.math.maxInt(usize);
    var max_col: usize = 0;
    var max_h_in_row: usize = 3;

    for (ns.class_ids) |id| {
        if (id >= diagram.classes.len) continue;
        const pos = layout.positions[id];
        const h = actualBoxHeight(&diagram.classes[id]);
        min_row = @min(min_row, pos.row);
        max_row = @max(max_row, pos.row);
        min_col = @min(min_col, pos.col);
        max_col = @max(max_col, pos.col);
        max_h_in_row = @max(max_h_in_row, h);
    }
    if (min_row == std.math.maxInt(usize)) return;

    const inner_top = route_mod.boxTop(layout, min_row);
    const inner_left = route_mod.boxLeft(layout, min_col);
    const inner_bottom = route_mod.boxTop(layout, max_row) + max_h_in_row;
    const inner_right = route_mod.boxLeft(layout, max_col) + layout.cell_w;

    const pad: usize = 1;
    const top = if (inner_top >= pad + 1) inner_top - pad - 1 else 0;
    const left = if (inner_left >= pad + 1) inner_left - pad - 1 else 0;
    const bottom_raw = inner_bottom + pad;
    const right_raw = inner_right + pad;
    const bottom = if (bottom_raw >= canvas.rows) canvas.rows - 1 else bottom_raw;
    const right = if (right_raw >= canvas.cols) canvas.cols - 1 else right_raw;
    if (bottom <= top or right <= left) return;

    const h = bottom - top + 1;
    const w = right - left + 1;
    canvas.drawRect(top, left, h, w, glyphs);

    const name_w = width_mod.displayWidth(ns.name, ambiguous);
    if (w > name_w + 4) {
        const title_col = left + 2;
        canvas.drawLabel(top, title_col, ns.name, ambiguous);
    }
}

fn drawClassBox(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    top: usize,
    left: usize,
    height: usize,
    width: usize,
    cls: *const types.ClassNode,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
    spans: ?*std.ArrayListUnmanaged(StyledSpan),
) RenderError!void {
    canvas.drawRect(top, left, height, width, glyphs);

    const inner_w = width - 2;
    var name_row = top + 1;

    if (cls.annotation) |st| {
        var buf: [96]u8 = undefined;
        const wrapped = std.fmt.bufPrint(&buf, "«{s}»", .{st}) catch st;
        const stereo_w = width_mod.displayWidth(wrapped, ambiguous);
        const stereo_off = if (inner_w > stereo_w) (inner_w - stereo_w) / 2 else 0;
        canvas.drawLabel(name_row, left + 1 + stereo_off, wrapped, ambiguous);
        name_row += 1;
    }

    const label_w = width_mod.displayWidth(cls.label, ambiguous);
    const name_col_off = if (inner_w > label_w) (inner_w - label_w) / 2 else 0;
    canvas.drawLabel(name_row, left + 1 + name_col_off, cls.label, ambiguous);

    const has_fields = cls.attributes.len > 0;
    const has_methods = cls.methods.len > 0;
    if (!has_fields and !has_methods) return;

    const divider_row = name_row + 1;
    drawDivider(canvas, divider_row, left, width, glyphs);

    var row = divider_row + 1;
    if (has_fields) {
        for (cls.attributes) |m| {
            if (row + 1 >= top + height) break;
            try drawMember(allocator, canvas, row, left, &m, false, ambiguous, spans);
            row += 1;
        }
    }

    if (has_fields and has_methods and row + 1 < top + height) {
        drawDivider(canvas, row, left, width, glyphs);
        row += 1;
    }

    if (has_methods) {
        for (cls.methods) |m| {
            if (row + 1 >= top + height) break;
            try drawMember(allocator, canvas, row, left, &m, true, ambiguous, spans);
            row += 1;
        }
    }
}

fn drawDivider(canvas: *canvas_mod.Canvas, row: usize, left: usize, width: usize, glyphs: *const canvas_mod.GlyphSet) void {
    var c = left + 1;
    while (c + 1 < left + width) : (c += 1) {
        canvas.setGlyph(row, c, glyphs.h_line);
    }
    canvas.setGlyph(row, left, glyphs.tee_l);
    canvas.setGlyph(row, left + width - 1, glyphs.tee_r);
}

fn drawMember(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    row: usize,
    left: usize,
    member: *const types.ClassMember,
    is_method: bool,
    ambiguous: width_mod.AmbiguousWidth,
    spans: ?*std.ArrayListUnmanaged(StyledSpan),
) RenderError!void {
    var col = left + 2;
    if (visibilitySigil(member.visibility)) |s| {
        canvas.setGlyph(row, col, s);
        col += 1;
        canvas.setGlyph(row, col, ' ');
        col += 1;
    }
    const label_start = col;
    canvas.drawLabel(row, col, member.name, ambiguous);
    col += width_mod.displayWidth(member.name, ambiguous);
    if (is_method) {
        canvas.setGlyph(row, col, '(');
        col += 1;
        if (member.params) |p| {
            canvas.drawLabel(row, col, p, ambiguous);
            col += width_mod.displayWidth(p, ambiguous);
        }
        canvas.setGlyph(row, col, ')');
        col += 1;
    }
    if (member.type_text) |t| {
        canvas.setGlyph(row, col, ':');
        col += 1;
        canvas.setGlyph(row, col, ' ');
        col += 1;
        canvas.drawLabel(row, col, t, ambiguous);
        col += width_mod.displayWidth(t, ambiguous);
    }

    if (spans) |list| {
        if (member.is_static) {
            list.append(allocator, .{ .row = row, .col_start = label_start, .col_end = col, .kind = .static_ }) catch return error.OutOfMemory;
        }
        if (member.is_abstract) {
            list.append(allocator, .{ .row = row, .col_start = label_start, .col_end = col, .kind = .abstract_ }) catch return error.OutOfMemory;
        }
    }
}

fn visibilitySigil(v: types.Visibility) ?u21 {
    return switch (v) {
        .public => '+',
        .private => '-',
        .protected => '#',
        .package => '~',
        .unknown => null,
    };
}

fn actualBoxHeight(cls: *const types.ClassNode) usize {
    const annotation_rows: usize = if (cls.annotation != null) 1 else 0;
    if (cls.attributes.len == 0 and cls.methods.len == 0) return 3 + annotation_rows;
    const extra_divider: usize = if (cls.attributes.len > 0 and cls.methods.len > 0) 1 else 0;
    return 4 + annotation_rows + cls.attributes.len + cls.methods.len + extra_divider;
}

fn drawRelation(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    layout: *const types.Layout,
    diagram: *const types.ClassDiagram,
    rel: types.ClassRelation,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) !void {
    const src_pos = layout.positions[rel.from];
    const tgt_pos = layout.positions[rel.to];

    const src_top = route_mod.boxTop(layout, src_pos.row);
    const src_left = route_mod.boxLeft(layout, src_pos.col);
    const tgt_top = route_mod.boxTop(layout, tgt_pos.row);
    const tgt_left = route_mod.boxLeft(layout, tgt_pos.col);

    const src_box_h = actualBoxHeight(&diagram.classes[rel.from]);
    const tgt_box_h = actualBoxHeight(&diagram.classes[rel.to]);

    const start_row = src_top;
    const start_col = src_left + layout.cell_w / 2;
    const goal_row = tgt_top + tgt_box_h;
    const goal_col = tgt_left + layout.cell_w / 2;

    _ = try route_mod.routeEdgeWithPorts(
        allocator,
        canvas,
        layout,
        rel.from,
        rel.to,
        start_row,
        start_col,
        .up,
        goal_row,
        goal_col,
        rel.label,
        edgeStyleFor(rel.kind),
        glyphs,
        ambiguous,
    );

    switch (rel.marker_at) {
        .to => replaceArrowHeadAtBottom(canvas, tgt_top, tgt_left, tgt_box_h, layout.cell_w, rel, glyphs),
        .from => replaceArrowHeadAtTop(canvas, src_top, src_left, src_box_h, layout.cell_w, rel, glyphs),
    }

    if (rel.from_cardinality) |c| drawCardinalityLabel(canvas, start_row, start_col, c, ambiguous, .source);
    if (rel.to_cardinality) |c| drawCardinalityLabel(canvas, goal_row, goal_col, c, ambiguous, .target);
}

const CardinalitySide = enum { source, target };

fn drawCardinalityLabel(
    canvas: *canvas_mod.Canvas,
    endpoint_row: usize,
    endpoint_col: usize,
    text: []const u8,
    ambiguous: width_mod.AmbiguousWidth,
    side: CardinalitySide,
) void {
    if (text.len == 0) return;
    const text_w = width_mod.displayWidth(text, ambiguous);
    const col = endpoint_col + 2;
    if (col + text_w > canvas.cols) return;

    const row = switch (side) {
        .source => if (endpoint_row == 0) return else endpoint_row - 1,
        .target => endpoint_row + 1,
    };
    if (row >= canvas.rows) return;

    canvas.drawLabel(row, col, text, ambiguous);
}

fn replaceArrowHeadAtBottom(
    canvas: *canvas_mod.Canvas,
    box_top: usize,
    box_left: usize,
    box_h: usize,
    cell_w: usize,
    rel: types.ClassRelation,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    const center = box_left + cell_w / 2;

    const border_row = box_top + box_h - 1;
    if (border_row < canvas.rows and center < canvas.cols) {
        canvas.setGlyph(border_row, center, glyphs.tee_t);
    }

    const arrow_row = box_top + box_h;
    if (arrow_row < canvas.rows and center < canvas.cols) {
        canvas.setGlyph(arrow_row, center, relationHead(rel.kind, glyphs));
    }
}

fn replaceArrowHeadAtTop(
    canvas: *canvas_mod.Canvas,
    box_top: usize,
    box_left: usize,
    box_h: usize,
    cell_w: usize,
    rel: types.ClassRelation,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    _ = box_h;
    const center = box_left + cell_w / 2;

    if (box_top < canvas.rows and center < canvas.cols) {
        canvas.setGlyph(box_top, center, glyphs.tee_b);
    }

    if (box_top > 0 and center < canvas.cols) {
        canvas.setGlyph(box_top - 1, center, relationHead(rel.kind, glyphs));
    }
}

fn edgeStyleFor(kind: types.ClassRelationKind) types.EdgeStyle {
    return switch (kind) {
        .inheritance,
        .realization,
        .composition,
        .aggregation,
        .association,
        .dependency,
        => .arrow,
    };
}

fn relationHead(kind: types.ClassRelationKind, glyphs: *const canvas_mod.GlyphSet) u21 {
    return switch (kind) {
        .inheritance, .realization => '△',
        .composition => '◆',
        .aggregation => '◇',
        .association, .dependency => glyphs.arrow_up,
    };
}

test "writeClass renders class box with attribute type and method params" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    class Animal
        \\    Animal : +str name
        \\    Animal : +save(entity) Result
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Animal") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+ name: str") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+ save(entity): Result") != null);
}

test "writeClass collapses multi-whitespace and tabs in attribute name" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc, "classDiagram\n    class C {\n        +int retry   count\n        +bool is\tready\n    }\n", .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "+ retry count: int") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+ is ready: bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "retry   count") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "is\tready") == null);
}

test "writeClass renders inheritance with triangle head" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    Animal <|-- Dog
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "△") != null);
}

test "writeClass renders composition with filled diamond" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    Car *-- Engine
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "◆") != null);
}

test "writeClass renders aggregation with empty diamond" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    Library o-- Book
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "◇") != null);
}

test "writeClass association arrow head points toward target (upward)" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    A --> B
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "▲") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "▼") == null);
}

test "writeClass shows literal star in abstract method type label" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    class C {
        \\        +run()*
        \\    }
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "run(): *") != null);
}

test "writeClass wraps static member with SGR underline when enable_ansi" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    class C {
        \\        +count$
        \\    }
    , .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[4m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[24m") != null);
}

test "writeClass wraps static and abstract method with both SGR when enable_ansi" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    class C {
        \\        +run$()*
        \\    }
    , .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[4m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[24m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[3m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[23m") != null);
}

test "writeClass wraps abstract method with SGR italic when enable_ansi" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    class C {
        \\        +run()*
        \\    }
    , .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[3m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[23m") != null);
}

test "writeClass emits no SGR when enable_ansi is false" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    class C {
        \\        +count$
        \\        +run()*
        \\    }
    , .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[") == null);
}

test "writeClass hides stripped dollar on static attribute" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    class C {
        \\        +count$
        \\    }
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "count") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$") == null);
}

test "writeClass separates attributes and methods with a divider" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    class Animal {
        \\        +str name
        \\        +eat()
        \\    }
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();

    var tee_l_count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out, idx, "├")) |found| {
        tee_l_count += 1;
        idx = found + "├".len;
    }
    try std.testing.expect(tee_l_count >= 2);
}

test "writeClass renders namespace frame with name" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    namespace Shapes {
        \\        class Circle
        \\        class Square
        \\    }
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Shapes") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Circle") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Square") != null);
}

test "writeClass marker_at from places triangle at source end" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    Animal <|-- Dog
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();

    var line_iter = std.mem.splitScalar(u8, out, '\n');
    var triangle_line: ?usize = null;
    var animal_line: ?usize = null;
    var dog_line: ?usize = null;
    var idx: usize = 0;
    while (line_iter.next()) |line| : (idx += 1) {
        if (std.mem.indexOf(u8, line, "△") != null and triangle_line == null) triangle_line = idx;
        if (std.mem.indexOf(u8, line, "Animal") != null and animal_line == null) animal_line = idx;
        if (std.mem.indexOf(u8, line, "Dog") != null and dog_line == null) dog_line = idx;
    }
    try std.testing.expect(triangle_line != null);
    try std.testing.expect(animal_line != null);
    try std.testing.expect(dog_line != null);

    const t = triangle_line.?;
    const a = animal_line.?;
    const d = dog_line.?;
    const dist_to_animal = if (t > a) t - a else a - t;
    const dist_to_dog = if (t > d) t - d else d - t;
    try std.testing.expect(dist_to_animal < dist_to_dog);
}

test "writeClass bare -- renders as association with arrow" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    A -- B
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "▲") != null);
}

test "computeClassLayout places single class at origin with rows=cols=1" {
    const alloc = std.testing.allocator;
    var diagram = try parse.parseSource(alloc,
        \\classDiagram
        \\    class Animal
    );
    defer diagram.deinit();

    var layout = try computeClassLayout(alloc, &diagram, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 1), layout.positions.len);
    try std.testing.expectEqual(@as(usize, 0), layout.positions[0].row);
    try std.testing.expectEqual(@as(usize, 0), layout.positions[0].col);
    try std.testing.expectEqual(@as(usize, 1), layout.rows);
    try std.testing.expectEqual(@as(usize, 1), layout.cols);
}

test "computeClassLayout sets outer_pad to 2 when namespaces exist" {
    const alloc = std.testing.allocator;
    var diagram = try parse.parseSource(alloc,
        \\classDiagram
        \\    namespace Shapes {
        \\        class Circle
        \\    }
    );
    defer diagram.deinit();

    var layout = try computeClassLayout(alloc, &diagram, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.outer_pad);
}

test "computeClassLayout stacks two-class inheritance as bottom_up rows" {
    const alloc = std.testing.allocator;
    var diagram = try parse.parseSource(alloc,
        \\classDiagram
        \\    Animal <|-- Dog
    );
    defer diagram.deinit();

    var layout = try computeClassLayout(alloc, &diagram, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.positions.len);
    try std.testing.expectEqual(@as(usize, 2), layout.rows);
    try std.testing.expectEqual(@as(usize, 1), layout.cols);

    var row_set = [_]bool{ false, false };
    for (layout.positions) |pos| {
        try std.testing.expectEqual(@as(usize, 0), pos.col);
        try std.testing.expect(pos.row < 2);
        row_set[pos.row] = true;
    }
    try std.testing.expect(row_set[0] and row_set[1]);
}
