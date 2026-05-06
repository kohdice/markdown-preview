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
    Overflow,
    WriteFailed,
};

pub const Options = struct {
    wrap_width: ?usize,
    ambiguous_width: width_mod.AmbiguousWidth,
};

const er_box_min_width: usize = 6;
const er_box_side_spacing: usize = 4;
const er_box_content_offset: usize = 2;
const er_box_border_columns: usize = 2;

const EntityBoxLayout = struct {
    name: text_layout.LabelLayout,
    attributes: []text_layout.LabelLayout,
    height: usize,
    max_content_width: usize,

    pub fn deinit(self: *EntityBoxLayout, allocator: std.mem.Allocator) void {
        self.name.deinit();
        for (self.attributes) |*attr| attr.deinit();
        allocator.free(self.attributes);
    }
};

const ErLayout = struct {
    base: types.Layout,
    entities: []EntityBoxLayout,

    pub fn deinit(self: *ErLayout) void {
        for (self.entities) |*entity| entity.deinit(self.base.allocator);
        self.base.allocator.free(self.entities);
        self.base.deinit();
    }
};

pub fn paintEr(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    diagram_ptr: *const types.ErDiagram,
    opts: Options,
) RenderError!void {
    const diagram = diagram_ptr.*;

    if (diagram.entities.len == 0) return;

    var layout = computeErLayout(allocator, &diagram, opts.wrap_width, opts.ambiguous_width) catch |err| switch (err) {
        error.WidthTooSmall => return error.WidthTooSmall,
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => return error.Overflow,
    };
    defer layout.deinit();

    if (layout.base.rows == 0 or layout.base.cols == 0) return;

    const glyphs = canvas_mod.GlyphSet.unicode;

    const canvas_rows = route_mod.canvasRows(&layout.base);
    const canvas_cols = route_mod.canvasCols(&layout.base);
    var canvas = canvas_mod.Canvas.init(allocator, canvas_rows, canvas_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    const protected_rects = try erProtectedRects(allocator, &layout);
    defer allocator.free(protected_rects);
    var route_scratch: route_mod.RouteScratch = .{};
    defer route_scratch.deinit(allocator);

    const defer_relation_labels = opts.wrap_width != null;
    const relation_label_wrap_width = @min(text_layout.edgeLabelWrapWidth(opts.wrap_width orelse canvas.cols), canvas.cols);

    for (diagram.entities, 0..) |_, i| {
        const pos = layout.base.positions[i];
        const top = route_mod.boxTop(&layout.base, pos.row);
        const left = route_mod.boxLeft(&layout.base, pos.col);
        try drawEntityBox(&canvas, top, left, layout.base.cell_w, &layout.entities[i], &glyphs, opts.ambiguous_width);
    }

    for (diagram.relations) |rel| {
        drawRelation(allocator, &route_scratch, &canvas, &layout, protected_rects, rel, &glyphs, defer_relation_labels, relation_label_wrap_width, opts.ambiguous_width) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WidthTooSmall => return error.WidthTooSmall,
        };
    }

    route_mod.mergeJunctions(allocator, &canvas, &glyphs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
}

pub const ErLayoutError = error{ OutOfMemory, Overflow, WidthTooSmall };

fn computeErLayout(
    allocator: std.mem.Allocator,
    diagram: *const types.ErDiagram,
    wrap_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
) ErLayoutError!ErLayout {
    const n = diagram.entities.len;
    if (n == 0) {
        const positions: []types.GridPos = &.{};
        const labels: []types.NodeLabelLayout = &.{};
        const entity_layouts: []EntityBoxLayout = &.{};
        const base: types.Layout = .{
            .allocator = allocator,
            .positions = positions,
            .node_labels = labels,
            .rows = 0,
            .cols = 0,
            .cell_w = 0,
            .cell_h = 0,
        };
        return .{
            .base = base,
            .entities = entity_layouts,
        };
    }

    const levels = try allocator.alloc(usize, n);
    defer allocator.free(levels);
    @memset(levels, 0);

    try assignErLevels(allocator, diagram.relations, n, levels);

    var max_level: usize = 0;
    for (levels) |l| max_level = @max(max_level, l);

    const level_slots = try std.math.add(usize, max_level, 1);
    const level_counts = try allocator.alloc(usize, level_slots);
    defer allocator.free(level_counts);
    @memset(level_counts, 0);

    const positions = try allocator.alloc(types.GridPos, n);
    errdefer allocator.free(positions);

    for (0..n) |i| {
        const level = levels[i];
        level_counts[level] += 1;
    }

    const content_budget = try erContentBudget(wrap_width);
    const entity_layouts = try computeEntityLayouts(allocator, diagram, content_budget, ambiguous);
    errdefer deinitEntityLayouts(allocator, entity_layouts);

    var cols: usize = 0;
    const cell_w = computeRequiredBoxWidth(entity_layouts);
    const max_cols_per_row = maxColumnsForWrap(wrap_width, cell_w, n);
    for (level_counts) |c| cols = @max(cols, @min(c, max_cols_per_row));
    if (cols == 0) cols = 1;

    const label_wrap_width = if (wrap_width) |w|
        @min(text_layout.edgeLabelWrapWidth(w), route_mod.canvasColsForGrid(cols, cell_w, 0))
    else
        null;
    var cell_h = computeRequiredBoxHeight(entity_layouts);
    cell_h = try std.math.add(usize, cell_h, try extraCellHeightForRelationLabels(allocator, diagram, label_wrap_width, ambiguous));

    const level_row_starts = try allocator.alloc(usize, level_slots);
    defer allocator.free(level_row_starts);

    var rows: usize = 0;
    var level_cursor = level_slots;
    while (level_cursor > 0) {
        level_cursor -= 1;
        level_row_starts[level_cursor] = rows;
        rows = try std.math.add(usize, rows, std.math.divCeil(usize, level_counts[level_cursor], max_cols_per_row) catch unreachable);
    }
    if (rows == 0) rows = 1;

    const level_next_indices = try allocator.alloc(usize, level_slots);
    defer allocator.free(level_next_indices);
    @memset(level_next_indices, 0);

    for (0..n) |i| {
        const level = levels[i];
        const local_idx = level_next_indices[level];
        level_next_indices[level] += 1;
        positions[i] = .{
            .row = try std.math.add(usize, level_row_starts[level], local_idx / max_cols_per_row),
            .col = local_idx % max_cols_per_row,
        };
    }

    const node_labels: []types.NodeLabelLayout = &.{};

    const base: types.Layout = .{
        .allocator = allocator,
        .positions = positions,
        .node_labels = node_labels,
        .rows = rows,
        .cols = cols,
        .cell_w = cell_w,
        .cell_h = cell_h,
    };
    return .{
        .base = base,
        .entities = entity_layouts,
    };
}

fn maxColumnsForWrap(wrap_width: ?usize, cell_w: usize, entity_count: usize) usize {
    const w = wrap_width orelse return @max(entity_count, 1);
    if (w <= cell_w) return 1;
    const step_w = std.math.add(usize, cell_w, route_mod.gutter_w) catch return 1;
    return 1 + (w - cell_w) / step_w;
}

fn erContentBudget(wrap_width: ?usize) ErLayoutError!?usize {
    const w = wrap_width orelse return null;
    if (w < er_box_min_width) return error.WidthTooSmall;
    if (w <= er_box_side_spacing) return error.WidthTooSmall;
    return w - er_box_side_spacing;
}

fn computeEntityLayouts(
    allocator: std.mem.Allocator,
    diagram: *const types.ErDiagram,
    max_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
) ErLayoutError![]EntityBoxLayout {
    const layouts = try allocator.alloc(EntityBoxLayout, diagram.entities.len);
    var initialized: usize = 0;
    errdefer {
        deinitEntityLayoutItems(allocator, layouts[0..initialized]);
        allocator.free(layouts);
    }

    for (diagram.entities, 0..) |entity, i| {
        layouts[i] = try computeEntityLayout(allocator, &entity, max_width, ambiguous);
        initialized += 1;
    }

    return layouts;
}

fn deinitEntityLayoutItems(allocator: std.mem.Allocator, layouts: []EntityBoxLayout) void {
    for (layouts) |*layout| layout.deinit(allocator);
}

fn deinitEntityLayouts(allocator: std.mem.Allocator, layouts: []EntityBoxLayout) void {
    deinitEntityLayoutItems(allocator, layouts);
    allocator.free(layouts);
}

fn computeEntityLayout(
    allocator: std.mem.Allocator,
    entity: *const types.ErEntity,
    max_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
) ErLayoutError!EntityBoxLayout {
    var name = text_layout.layoutLabel(allocator, entity.id_text, max_width, ambiguous) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer name.deinit();

    const attributes = try allocator.alloc(text_layout.LabelLayout, entity.attributes.len);
    var initialized: usize = 0;
    errdefer {
        for (attributes[0..initialized]) |*attr| attr.deinit();
        allocator.free(attributes);
    }

    var max_content_width = name.max_line_width;
    var attr_lines: usize = 0;
    for (entity.attributes, 0..) |attr, i| {
        const row_text = try formatAttributeRow(allocator, &attr);
        defer allocator.free(row_text);

        attributes[i] = text_layout.layoutLabel(allocator, row_text, max_width, ambiguous) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        initialized += 1;
        max_content_width = @max(max_content_width, attributes[i].max_line_width);
        attr_lines += attributes[i].lines.len;
    }

    const height = if (attributes.len == 0)
        @max(@as(usize, 3), 2 + name.lines.len)
    else
        2 + name.lines.len + 1 + attr_lines;

    return .{
        .name = name,
        .attributes = attributes,
        .height = height,
        .max_content_width = max_content_width,
    };
}

fn assignErLevels(
    allocator: std.mem.Allocator,
    relations: []const types.ErRelation,
    n: usize,
    levels: []usize,
) ErLayoutError!void {
    const remaining = try allocator.alloc(u32, n);
    defer allocator.free(remaining);
    @memset(remaining, 0);
    for (relations) |rel| {
        if (rel.to < n) remaining[rel.to] += 1;
    }

    var queue: std.ArrayList(types.NodeId) = .empty;
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

fn computeRequiredBoxHeight(layouts: []const EntityBoxLayout) usize {
    var max_h: usize = 3;
    for (layouts) |layout| max_h = @max(max_h, layout.height);
    return max_h;
}

fn computeRequiredBoxWidth(layouts: []const EntityBoxLayout) usize {
    var max_w: usize = 0;
    for (layouts) |layout| max_w = @max(max_w, layout.max_content_width);
    return @max(max_w + er_box_side_spacing, er_box_min_width);
}

fn extraCellHeightForRelationLabels(
    allocator: std.mem.Allocator,
    diagram: *const types.ErDiagram,
    label_wrap_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
) ErLayoutError!usize {
    const w = label_wrap_width orelse return 0;
    var max_lines: usize = 0;
    for (diagram.relations) |rel| {
        if (rel.label.len == 0) continue;
        var label = text_layout.layoutLabel(allocator, rel.label, w, ambiguous) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        const lines = label.lines.len;
        label.deinit();
        max_lines = @max(max_lines, lines);
    }
    const drawable_gutter = if (route_mod.gutter_h > 0) route_mod.gutter_h - 1 else 0;
    if (max_lines <= drawable_gutter) return 0;
    return max_lines - drawable_gutter;
}

fn writeMarkText(buf: []u8, mark: types.ErAttributeMark) []const u8 {
    var len: usize = 0;
    const append = struct {
        fn it(dst: []u8, at: *usize, s: []const u8) void {
            @memcpy(dst[at.* .. at.* + s.len], s);
            at.* += s.len;
        }
    }.it;
    if (mark.pk) {
        if (len > 0) {
            buf[len] = ' ';
            len += 1;
        }
        append(buf, &len, "PK");
    }
    if (mark.fk) {
        if (len > 0) {
            buf[len] = ' ';
            len += 1;
        }
        append(buf, &len, "FK");
    }
    if (mark.uk) {
        if (len > 0) {
            buf[len] = ' ';
            len += 1;
        }
        append(buf, &len, "UK");
    }
    return buf[0..len];
}

fn formatAttributeRow(allocator: std.mem.Allocator, attr: *const types.ErAttribute) ErLayoutError![]u8 {
    if (!attr.mark.isEmpty()) {
        var mark_buf: [16]u8 = undefined;
        const mark = writeMarkText(&mark_buf, attr.mark);
        return std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ mark, attr.type_text, attr.name });
    }
    return std.fmt.allocPrint(allocator, "{s} {s}", .{ attr.type_text, attr.name });
}

fn drawEntityBox(
    canvas: *canvas_mod.Canvas,
    top: usize,
    left: usize,
    width: usize,
    layout: *const EntityBoxLayout,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) error{OutOfMemory}!void {
    const height = layout.height;
    canvas.drawRect(top, left, height, width, glyphs);

    const inner_w = width - er_box_border_columns;
    var row = top + 1;
    for (layout.name.lines) |line| {
        const name_col_off = if (inner_w > line.width) (inner_w - line.width) / 2 else 0;
        try canvas.drawLabel(row, left + 1 + name_col_off, line.text, ambiguous);
        row += 1;
    }

    if (layout.attributes.len == 0) return;

    drawDivider(canvas, row, left, width, glyphs);
    row += 1;

    for (layout.attributes) |attr_layout| {
        for (attr_layout.lines) |line| {
            if (row + 1 >= top + height) break;
            try canvas.drawLabel(row, left + er_box_content_offset, line.text, ambiguous);
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

fn erProtectedRects(allocator: std.mem.Allocator, layout: *const ErLayout) error{OutOfMemory}![]route_mod.ProtectedRect {
    const rects = try allocator.alloc(route_mod.ProtectedRect, layout.entities.len);
    for (layout.entities, 0..) |entity, i| {
        const pos = layout.base.positions[i];
        rects[i] = .{
            .top = route_mod.boxTop(&layout.base, pos.row),
            .left = route_mod.boxLeft(&layout.base, pos.col),
            .height = entity.height,
            .width = layout.base.cell_w,
        };
    }
    return rects;
}

fn drawRelation(
    allocator: std.mem.Allocator,
    route_scratch: *route_mod.RouteScratch,
    canvas: *canvas_mod.Canvas,
    layout: *const ErLayout,
    protected_rects: []const route_mod.ProtectedRect,
    rel: types.ErRelation,
    glyphs: *const canvas_mod.GlyphSet,
    defer_label_placement: bool,
    label_wrap_width: usize,
    ambiguous: width_mod.AmbiguousWidth,
) error{ OutOfMemory, WidthTooSmall }!void {
    const base = &layout.base;
    const src_pos = base.positions[rel.from];
    const tgt_pos = base.positions[rel.to];

    const src_top = route_mod.boxTop(base, src_pos.row);
    const src_left = route_mod.boxLeft(base, src_pos.col);
    const tgt_top = route_mod.boxTop(base, tgt_pos.row);
    const tgt_left = route_mod.boxLeft(base, tgt_pos.col);

    const tgt_box_h = layout.entities[rel.to].height;

    const start_row = src_top;
    const start_col = src_left + base.cell_w / 2;
    const goal_row = tgt_top + tgt_box_h;
    const goal_col = tgt_left + base.cell_w / 2;

    var route = try route_mod.routeEdgeWithPortsScratch(
        allocator,
        route_scratch,
        canvas,
        base,
        rel.from,
        rel.to,
        start_row,
        start_col,
        .up,
        goal_row,
        goal_col,
        rel.label,
        if (rel.identifying) types.EdgeStyle.arrow else types.EdgeStyle.dotted,
        glyphs,
        defer_label_placement,
        ambiguous,
    );
    defer route.deinit(allocator);
    const endpoints = route.endpoints;

    if (defer_label_placement and rel.label.len > 0) {
        const placed = try route_mod.placeWrappedLabelOnRouteAnchored(
            allocator,
            canvas,
            protected_rects,
            route.label_path.points,
            rel.label,
            label_wrap_width,
            ambiguous,
            glyphs,
            .middle,
        );
        if (!placed) return error.WidthTooSmall;
    }

    drawCardinality(canvas, start_row, start_col, endpoints.start_dir, rel.left);
    drawCardinality(canvas, goal_row, goal_col, endpoints.end_dir, rel.right);
}

fn drawCardinality(
    canvas: *canvas_mod.Canvas,
    row: usize,
    col: usize,
    dir: route_mod.Dir4,
    card: types.ErCardinality,
) void {
    const axis = route_mod.axisOf(dir);
    const glyph = cardinalityGlyph(axis, card);
    canvas.setGlyph(row, col, glyph);
}

fn cardinalityGlyph(axis: route_mod.Axis, card: types.ErCardinality) u21 {
    return switch (axis) {
        .vertical => switch (card) {
            .exactly_one => '│',
            .zero_or_one => '○',
            .one_or_many => '╤',
            .zero_or_many => '╪',
        },
        .horizontal => switch (card) {
            .exactly_one => '─',
            .zero_or_one => '○',
            .one_or_many => '╫',
            .zero_or_many => '╬',
        },
    };
}

test "paintEr renders entity box with attributes" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\erDiagram
        \\    CUSTOMER {
        \\        string id PK
        \\        string name
        \\    }
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintEr(&sink.writer, alloc, &diagram.er, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "CUSTOMER") != null);
    try std.testing.expect(std.mem.find(u8, out, "PK string id") != null);
    try std.testing.expect(std.mem.find(u8, out, "string name") != null);
}

test "paintEr renders one-to-many with circle and crow glyphs" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintEr(&sink.writer, alloc, &diagram.er, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "CUSTOMER") != null);
    try std.testing.expect(std.mem.find(u8, out, "ORDER") != null);
    try std.testing.expect(std.mem.find(u8, out, "○") != null or
        std.mem.find(u8, out, "╤") != null or
        std.mem.find(u8, out, "╪") != null or
        std.mem.find(u8, out, "╫") != null or
        std.mem.find(u8, out, "╬") != null);
}

test "paintEr renders identifying vs non-identifying distinctly" {
    const alloc = std.testing.allocator;

    var ident_diagram = try compile_mod.compile(alloc,
        \\erDiagram
        \\    A ||--|| B : r
    );
    defer ident_diagram.deinit();
    var ident_sink: std.Io.Writer.Allocating = .init(alloc);
    defer ident_sink.deinit();
    try paintEr(&ident_sink.writer, alloc, &ident_diagram.er, .{ .wrap_width = null, .ambiguous_width = .narrow });

    var dotted_diagram = try compile_mod.compile(alloc,
        \\erDiagram
        \\    A ||..|| B : r
    );
    defer dotted_diagram.deinit();
    var dotted_sink: std.Io.Writer.Allocating = .init(alloc);
    defer dotted_sink.deinit();
    try paintEr(&dotted_sink.writer, alloc, &dotted_diagram.er, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const ident = ident_sink.writer.buffered();
    const dotted = dotted_sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, dotted, "╎") != null);
    try std.testing.expect(std.mem.find(u8, ident, "╎") == null);
}

test "paintEr renders relation label on the routed path" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintEr(&sink.writer, alloc, &diagram.er, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "places") != null);
}

test "paintEr handles empty entity block" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\erDiagram
        \\    ORDER {}
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintEr(&sink.writer, alloc, &diagram.er, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "ORDER") != null);
}

test "paintEr wraps same-level entities to fit wrap_width" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\erDiagram
        \\    A
        \\    B
        \\    C
        \\    D
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintEr(&sink.writer, alloc, &diagram.er, .{ .wrap_width = 14, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "\u{2026}") == null);
    try std.testing.expect(std.mem.find(u8, out, "A") != null);
    try std.testing.expect(std.mem.find(u8, out, "B") != null);
    try std.testing.expect(std.mem.find(u8, out, "C") != null);
    try std.testing.expect(std.mem.find(u8, out, "D") != null);

    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(width_mod.displayWidth(line, .narrow) <= 14);
    }
}

fn expectComputeEntityLayoutsHandlesAllocationFailures(allocator: std.mem.Allocator) !void {
    var attrs = [_]types.ErAttribute{
        .{ .type_text = "string", .name = "very_long_customer_identifier", .mark = .{ .pk = true } },
        .{ .type_text = "string", .name = "display_name" },
    };
    var empty_attrs = [_]types.ErAttribute{};
    var entities = [_]types.ErEntity{
        .{ .id = 0, .id_text = "CUSTOMER", .attributes = attrs[0..] },
        .{ .id = 1, .id_text = "ORDER", .attributes = empty_attrs[0..] },
    };
    var relations = [_]types.ErRelation{};
    var diagram: types.ErDiagram = .{
        .allocator = allocator,
        .entities = entities[0..],
        .relations = relations[0..],
    };

    const layouts = try computeEntityLayouts(allocator, &diagram, 12, .narrow);
    defer deinitEntityLayouts(allocator, layouts);
}

test "computeEntityLayouts cleans up partial layouts on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        expectComputeEntityLayoutsHandlesAllocationFailures,
        .{},
    );
}

test "computeErLayout places single entity at origin with rows=cols=1" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\erDiagram
        \\    CUSTOMER {
        \\        string id
        \\    }
    );
    defer compiled.deinit();
    const diagram = &compiled.er;

    var layout = try computeErLayout(alloc, diagram, null, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 1), layout.base.positions.len);
    try std.testing.expectEqual(@as(usize, 0), layout.base.positions[0].row);
    try std.testing.expectEqual(@as(usize, 0), layout.base.positions[0].col);
    try std.testing.expectEqual(@as(usize, 1), layout.base.rows);
    try std.testing.expectEqual(@as(usize, 1), layout.base.cols);
}

test "computeErLayout has outer_pad 0 (ER has no namespaces)" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\erDiagram
        \\    A ||--|| B : r
    );
    defer compiled.deinit();
    const diagram = &compiled.er;

    var layout = try computeErLayout(alloc, diagram, null, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 0), layout.base.outer_pad);
}

test "computeErLayout stacks two-entity relation as bottom_up rows" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
    );
    defer compiled.deinit();
    const diagram = &compiled.er;

    var layout = try computeErLayout(alloc, diagram, null, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.base.positions.len);
    try std.testing.expectEqual(@as(usize, 2), layout.base.rows);
    try std.testing.expectEqual(@as(usize, 1), layout.base.cols);

    var row_set = [_]bool{ false, false };
    for (layout.base.positions) |pos| {
        try std.testing.expectEqual(@as(usize, 0), pos.col);
        try std.testing.expect(pos.row < 2);
        row_set[pos.row] = true;
    }
    try std.testing.expect(row_set[0] and row_set[1]);
}

test "computeErLayout 1-parent 2-children branch separates siblings across columns" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
        \\    CUSTOMER ||--o{ INVOICE : receives
    );
    defer compiled.deinit();
    const diagram = &compiled.er;

    var layout = try computeErLayout(alloc, diagram, null, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 3), layout.base.positions.len);
    try std.testing.expectEqual(@as(usize, 2), layout.base.rows);
    try std.testing.expectEqual(@as(usize, 2), layout.base.cols);

    var id_customer: ?usize = null;
    var id_order: ?usize = null;
    var id_invoice: ?usize = null;
    for (diagram.entities, 0..) |entity, i| {
        if (std.mem.eql(u8, entity.id_text, "CUSTOMER")) id_customer = i;
        if (std.mem.eql(u8, entity.id_text, "ORDER")) id_order = i;
        if (std.mem.eql(u8, entity.id_text, "INVOICE")) id_invoice = i;
    }
    try std.testing.expect(id_customer != null and id_order != null and id_invoice != null);

    try std.testing.expectEqual(@as(usize, 1), layout.base.positions[id_customer.?].row);
    try std.testing.expectEqual(@as(usize, 0), layout.base.positions[id_order.?].row);
    try std.testing.expectEqual(@as(usize, 0), layout.base.positions[id_invoice.?].row);

    const o_col = layout.base.positions[id_order.?].col;
    const i_col = layout.base.positions[id_invoice.?].col;
    try std.testing.expect(o_col != i_col);
    try std.testing.expect(o_col < 2 and i_col < 2);
}

test "computeErLayout 2-parents 1-child merge stacks parents in bottom row" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
        \\    SHIPPER ||--o{ ORDER : handles
    );
    defer compiled.deinit();
    const diagram = &compiled.er;

    var layout = try computeErLayout(alloc, diagram, null, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 3), layout.base.positions.len);
    try std.testing.expectEqual(@as(usize, 2), layout.base.rows);
    try std.testing.expectEqual(@as(usize, 2), layout.base.cols);

    var id_customer: ?usize = null;
    var id_shipper: ?usize = null;
    var id_order: ?usize = null;
    for (diagram.entities, 0..) |entity, i| {
        if (std.mem.eql(u8, entity.id_text, "CUSTOMER")) id_customer = i;
        if (std.mem.eql(u8, entity.id_text, "SHIPPER")) id_shipper = i;
        if (std.mem.eql(u8, entity.id_text, "ORDER")) id_order = i;
    }
    try std.testing.expect(id_customer != null and id_shipper != null and id_order != null);

    try std.testing.expectEqual(@as(usize, 1), layout.base.positions[id_customer.?].row);
    try std.testing.expectEqual(@as(usize, 1), layout.base.positions[id_shipper.?].row);
    try std.testing.expectEqual(@as(usize, 0), layout.base.positions[id_order.?].row);

    const c_col = layout.base.positions[id_customer.?].col;
    const s_col = layout.base.positions[id_shipper.?].col;
    try std.testing.expect(c_col != s_col);
    try std.testing.expect(c_col < 2 and s_col < 2);
}
