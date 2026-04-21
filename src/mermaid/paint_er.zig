const std = @import("std");
const types = @import("types.zig");
const canvas_mod = @import("canvas.zig");
const compile_mod = @import("compile.zig");
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

pub fn paintEr(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    diagram_ptr: *const types.ErDiagram,
    opts: Options,
) RenderError!void {
    const diagram = diagram_ptr.*;

    if (diagram.entities.len == 0) return;

    var layout = computeErLayout(allocator, &diagram, opts.ambiguous_width) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer layout.deinit();

    if (layout.rows == 0 or layout.cols == 0) return;

    const glyphs = canvas_mod.GlyphSet.unicode;

    const canvas_rows = route_mod.canvasRows(&layout);
    const canvas_cols = route_mod.canvasCols(&layout);
    var canvas = canvas_mod.Canvas.init(allocator, canvas_rows, canvas_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    for (diagram.entities, 0..) |entity, i| {
        const pos = layout.positions[i];
        const top = route_mod.boxTop(&layout, pos.row);
        const left = route_mod.boxLeft(&layout, pos.col);
        drawEntityBox(&canvas, top, left, actualBoxHeight(&entity), layout.cell_w, &entity, &glyphs, opts.ambiguous_width);
    }

    for (diagram.relations) |rel| {
        drawRelation(allocator, &canvas, &layout, &diagram, rel, &glyphs, opts.ambiguous_width) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    route_mod.mergeJunctions(allocator, &canvas, &glyphs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
}

pub const ErLayoutError = error{OutOfMemory};

fn computeErLayout(
    allocator: std.mem.Allocator,
    diagram: *const types.ErDiagram,
    ambiguous: width_mod.AmbiguousWidth,
) ErLayoutError!types.Layout {
    const n = diagram.entities.len;
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

    try assignErLevels(allocator, diagram.relations, n, levels);

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

fn computeRequiredBoxHeight(diagram: *const types.ErDiagram) usize {
    var max_h: usize = 3;
    for (diagram.entities) |e| max_h = @max(max_h, actualBoxHeight(&e));
    return max_h;
}

fn computeRequiredBoxWidth(diagram: *const types.ErDiagram, ambiguous: width_mod.AmbiguousWidth) usize {
    var max_w: usize = 0;
    for (diagram.entities) |e| {
        max_w = @max(max_w, width_mod.displayWidth(e.id_text, ambiguous));
        for (e.attributes) |attr| {
            max_w = @max(max_w, attributeRowDisplayWidth(&attr, ambiguous));
        }
    }
    return @max(max_w + 4, 6);
}

fn attributeRowDisplayWidth(attr: *const types.ErAttribute, ambiguous: width_mod.AmbiguousWidth) usize {
    var w = width_mod.displayWidth(attr.type_text, ambiguous);
    w += 1;
    w += width_mod.displayWidth(attr.name, ambiguous);
    const mw = markTextWidth(attr.mark);
    if (mw > 0) w += 1 + mw;
    return w;
}

fn markTextWidth(mark: types.ErAttributeMark) usize {
    var count: usize = 0;
    if (mark.pk) count += 1;
    if (mark.fk) count += 1;
    if (mark.uk) count += 1;
    if (count == 0) return 0;
    return count * 2 + (count - 1);
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

fn drawEntityBox(
    canvas: *canvas_mod.Canvas,
    top: usize,
    left: usize,
    height: usize,
    width: usize,
    entity: *const types.ErEntity,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) void {
    canvas.drawRect(top, left, height, width, glyphs);

    const inner_w = width - 2;
    const name_w = width_mod.displayWidth(entity.id_text, ambiguous);
    const name_col_off = if (inner_w > name_w) (inner_w - name_w) / 2 else 0;
    canvas.drawLabel(top + 1, left + 1 + name_col_off, entity.id_text, ambiguous);

    if (entity.attributes.len == 0) return;

    drawDivider(canvas, top + 2, left, width, glyphs);

    var row = top + 3;
    for (entity.attributes) |attr| {
        if (row + 1 >= top + height) break;
        drawAttribute(canvas, row, left, &attr, ambiguous);
        row += 1;
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

fn drawAttribute(canvas: *canvas_mod.Canvas, row: usize, left: usize, attr: *const types.ErAttribute, ambiguous: width_mod.AmbiguousWidth) void {
    var col = left + 2;
    if (!attr.mark.isEmpty()) {
        var buf: [16]u8 = undefined;
        const text = writeMarkText(&buf, attr.mark);
        canvas.drawLabel(row, col, text, ambiguous);
        col += text.len;
        canvas.setGlyph(row, col, ' ');
        col += 1;
    }
    canvas.drawLabel(row, col, attr.type_text, ambiguous);
    col += width_mod.displayWidth(attr.type_text, ambiguous);
    canvas.setGlyph(row, col, ' ');
    col += 1;
    canvas.drawLabel(row, col, attr.name, ambiguous);
}

fn actualBoxHeight(entity: *const types.ErEntity) usize {
    if (entity.attributes.len == 0) return 3;
    return 4 + entity.attributes.len;
}

fn drawRelation(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    layout: *const types.Layout,
    diagram: *const types.ErDiagram,
    rel: types.ErRelation,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) !void {
    const src_pos = layout.positions[rel.from];
    const tgt_pos = layout.positions[rel.to];

    const src_top = route_mod.boxTop(layout, src_pos.row);
    const src_left = route_mod.boxLeft(layout, src_pos.col);
    const tgt_top = route_mod.boxTop(layout, tgt_pos.row);
    const tgt_left = route_mod.boxLeft(layout, tgt_pos.col);

    const tgt_box_h = actualBoxHeight(&diagram.entities[rel.to]);

    const start_row = src_top;
    const start_col = src_left + layout.cell_w / 2;
    const goal_row = tgt_top + tgt_box_h;
    const goal_col = tgt_left + layout.cell_w / 2;

    const endpoints = try route_mod.routeEdgeWithPorts(
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
        if (rel.identifying) types.EdgeStyle.arrow else types.EdgeStyle.dotted,
        glyphs,
        ambiguous,
    );

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

    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintEr(&sink.writer, alloc, &diagram.er, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "CUSTOMER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PK string id") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "string name") != null);
}

test "paintEr renders one-to-many with circle and crow glyphs" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
    );
    defer diagram.deinit();

    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintEr(&sink.writer, alloc, &diagram.er, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "CUSTOMER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ORDER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "○") != null or
        std.mem.indexOf(u8, out, "╤") != null or
        std.mem.indexOf(u8, out, "╪") != null or
        std.mem.indexOf(u8, out, "╫") != null or
        std.mem.indexOf(u8, out, "╬") != null);
}

test "paintEr renders identifying vs non-identifying distinctly" {
    const alloc = std.testing.allocator;

    var ident_diagram = try compile_mod.compile(alloc,
        \\erDiagram
        \\    A ||--|| B : r
    );
    defer ident_diagram.deinit();
    var ident_sink: std.io.Writer.Allocating = .init(alloc);
    defer ident_sink.deinit();
    try paintEr(&ident_sink.writer, alloc, &ident_diagram.er, .{ .wrap_width = null, .ambiguous_width = .narrow });

    var dotted_diagram = try compile_mod.compile(alloc,
        \\erDiagram
        \\    A ||..|| B : r
    );
    defer dotted_diagram.deinit();
    var dotted_sink: std.io.Writer.Allocating = .init(alloc);
    defer dotted_sink.deinit();
    try paintEr(&dotted_sink.writer, alloc, &dotted_diagram.er, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const ident = ident_sink.writer.buffered();
    const dotted = dotted_sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, dotted, "╎") != null);
    try std.testing.expect(std.mem.indexOf(u8, ident, "╎") == null);
}

test "paintEr renders relation label on the routed path" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
    );
    defer diagram.deinit();

    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintEr(&sink.writer, alloc, &diagram.er, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "places") != null);
}

test "paintEr handles empty entity block" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\erDiagram
        \\    ORDER {}
    );
    defer diagram.deinit();

    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintEr(&sink.writer, alloc, &diagram.er, .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "ORDER") != null);
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

    var layout = try computeErLayout(alloc, diagram, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 1), layout.positions.len);
    try std.testing.expectEqual(@as(usize, 0), layout.positions[0].row);
    try std.testing.expectEqual(@as(usize, 0), layout.positions[0].col);
    try std.testing.expectEqual(@as(usize, 1), layout.rows);
    try std.testing.expectEqual(@as(usize, 1), layout.cols);
}

test "computeErLayout has outer_pad 0 (ER has no namespaces)" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\erDiagram
        \\    A ||--|| B : r
    );
    defer compiled.deinit();
    const diagram = &compiled.er;

    var layout = try computeErLayout(alloc, diagram, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 0), layout.outer_pad);
}

test "computeErLayout stacks two-entity relation as bottom_up rows" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
    );
    defer compiled.deinit();
    const diagram = &compiled.er;

    var layout = try computeErLayout(alloc, diagram, .narrow);
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

test "computeErLayout 1-parent 2-children branch separates siblings across columns" {
    const alloc = std.testing.allocator;
    var compiled = try compile_mod.compile(alloc,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
        \\    CUSTOMER ||--o{ INVOICE : receives
    );
    defer compiled.deinit();
    const diagram = &compiled.er;

    var layout = try computeErLayout(alloc, diagram, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 3), layout.positions.len);
    try std.testing.expectEqual(@as(usize, 2), layout.rows);
    try std.testing.expectEqual(@as(usize, 2), layout.cols);

    var id_customer: ?usize = null;
    var id_order: ?usize = null;
    var id_invoice: ?usize = null;
    for (diagram.entities, 0..) |entity, i| {
        if (std.mem.eql(u8, entity.id_text, "CUSTOMER")) id_customer = i;
        if (std.mem.eql(u8, entity.id_text, "ORDER")) id_order = i;
        if (std.mem.eql(u8, entity.id_text, "INVOICE")) id_invoice = i;
    }
    try std.testing.expect(id_customer != null and id_order != null and id_invoice != null);

    try std.testing.expectEqual(@as(usize, 1), layout.positions[id_customer.?].row);
    try std.testing.expectEqual(@as(usize, 0), layout.positions[id_order.?].row);
    try std.testing.expectEqual(@as(usize, 0), layout.positions[id_invoice.?].row);

    const o_col = layout.positions[id_order.?].col;
    const i_col = layout.positions[id_invoice.?].col;
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

    var layout = try computeErLayout(alloc, diagram, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 3), layout.positions.len);
    try std.testing.expectEqual(@as(usize, 2), layout.rows);
    try std.testing.expectEqual(@as(usize, 2), layout.cols);

    var id_customer: ?usize = null;
    var id_shipper: ?usize = null;
    var id_order: ?usize = null;
    for (diagram.entities, 0..) |entity, i| {
        if (std.mem.eql(u8, entity.id_text, "CUSTOMER")) id_customer = i;
        if (std.mem.eql(u8, entity.id_text, "SHIPPER")) id_shipper = i;
        if (std.mem.eql(u8, entity.id_text, "ORDER")) id_order = i;
    }
    try std.testing.expect(id_customer != null and id_shipper != null and id_order != null);

    try std.testing.expectEqual(@as(usize, 1), layout.positions[id_customer.?].row);
    try std.testing.expectEqual(@as(usize, 1), layout.positions[id_shipper.?].row);
    try std.testing.expectEqual(@as(usize, 0), layout.positions[id_order.?].row);

    const c_col = layout.positions[id_customer.?].col;
    const s_col = layout.positions[id_shipper.?].col;
    try std.testing.expect(c_col != s_col);
    try std.testing.expect(c_col < 2 and s_col < 2);
}
