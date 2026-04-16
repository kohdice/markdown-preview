const std = @import("std");
const types = @import("types.zig");
const parse = @import("parse_er.zig");
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
};

pub fn writeEr(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    var diagram = parse.parseSource(allocator, source) catch |err| switch (err) {
        error.InvalidMermaid, error.TooManyEntities => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer diagram.deinit();

    if (diagram.entities.len == 0) return;

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

    for (diagram.entities, 0..) |entity, i| {
        const pos = flow_layout.positions[i];
        const top = route_mod.boxTop(&flow_layout, pos.row);
        const left = route_mod.boxLeft(&flow_layout, pos.col);
        drawEntityBox(&canvas, top, left, actualBoxHeight(&entity), flow_layout.cell_w, &entity, &glyphs, opts.ambiguous_width);
    }

    for (diagram.relations) |rel| {
        drawRelation(allocator, &canvas, &flow_layout, &diagram, rel, &glyphs, opts.ambiguous_width) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    route_mod.mergeJunctions(allocator, &canvas, &glyphs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
}

const LayoutInfo = struct {
    flow_layout: types.Layout,
    flow_graph_nodes: []types.Node,
    flow_graph_edges: []types.Edge,
};

fn computeLayout(
    allocator: std.mem.Allocator,
    diagram: *const types.ErDiagram,
    ambiguous: width_mod.AmbiguousWidth,
) RenderError!LayoutInfo {
    const nodes = allocator.alloc(types.Node, diagram.entities.len) catch return error.OutOfMemory;
    errdefer allocator.free(nodes);

    for (diagram.entities, 0..) |entity, i| {
        nodes[i] = .{
            .id = @intCast(i),
            .id_text = entity.id_text,
            .label = entity.id_text,
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
            .style = if (rel.identifying) .arrow else .dotted,
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

    return .{
        .flow_layout = layout,
        .flow_graph_nodes = nodes,
        .flow_graph_edges = edges,
    };
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

test "writeEr renders entity box with attributes" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeEr(&sink.writer, alloc,
        \\erDiagram
        \\    CUSTOMER {
        \\        string id PK
        \\        string name
        \\    }
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "CUSTOMER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PK string id") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "string name") != null);
}

test "writeEr renders one-to-many with circle and crow glyphs" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeEr(&sink.writer, alloc,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "CUSTOMER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ORDER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "○") != null or
        std.mem.indexOf(u8, out, "╤") != null or
        std.mem.indexOf(u8, out, "╪") != null or
        std.mem.indexOf(u8, out, "╫") != null or
        std.mem.indexOf(u8, out, "╬") != null);
}

test "writeEr renders identifying vs non-identifying distinctly" {
    const alloc = std.testing.allocator;

    var ident_sink: std.io.Writer.Allocating = .init(alloc);
    defer ident_sink.deinit();
    try writeEr(&ident_sink.writer, alloc,
        \\erDiagram
        \\    A ||--|| B : r
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    var dotted_sink: std.io.Writer.Allocating = .init(alloc);
    defer dotted_sink.deinit();
    try writeEr(&dotted_sink.writer, alloc,
        \\erDiagram
        \\    A ||..|| B : r
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const ident = ident_sink.writer.buffered();
    const dotted = dotted_sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, dotted, "╎") != null);
    try std.testing.expect(std.mem.indexOf(u8, ident, "╎") == null);
}

test "writeEr renders relation label on the routed path" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeEr(&sink.writer, alloc,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "places") != null);
}

test "writeEr handles empty entity block" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeEr(&sink.writer, alloc,
        \\erDiagram
        \\    ORDER {}
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "ORDER") != null);
}
