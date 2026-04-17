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

    for (diagram.classes, 0..) |cls, i| {
        const pos = flow_layout.positions[i];
        const top = route_mod.boxTop(&flow_layout, pos.row);
        const left = route_mod.boxLeft(&flow_layout, pos.col);
        drawClassBox(&canvas, top, left, actualBoxHeight(&cls), flow_layout.cell_w, &cls, &glyphs, opts.ambiguous_width);
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
        for (c.attributes) |m| {
            const prefix_w: usize = if (m.visibility == .unknown) 0 else 1;
            max_w = @max(max_w, width_mod.displayWidth(m.name, ambiguous) + prefix_w + 1);
        }
        for (c.methods) |m| {
            const prefix_w: usize = if (m.visibility == .unknown) 0 else 1;
            max_w = @max(max_w, width_mod.displayWidth(m.name, ambiguous) + prefix_w + 1);
        }
    }
    return @max(max_w + 4, 6);
}

fn drawClassBox(
    canvas: *canvas_mod.Canvas,
    top: usize,
    left: usize,
    height: usize,
    width: usize,
    cls: *const types.ClassNode,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) void {
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
            drawMember(canvas, row, left, &m, ambiguous);
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
            drawMember(canvas, row, left, &m, ambiguous);
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

fn drawMember(canvas: *canvas_mod.Canvas, row: usize, left: usize, member: *const types.ClassMember, ambiguous: width_mod.AmbiguousWidth) void {
    var col = left + 2;
    if (visibilitySigil(member.visibility)) |s| {
        canvas.setGlyph(row, col, s);
        col += 1;
        canvas.setGlyph(row, col, ' ');
        col += 1;
    }
    canvas.drawLabel(row, col, member.name, ambiguous);
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

    replaceArrowHead(canvas, tgt_top, tgt_left, tgt_box_h, layout.cell_w, rel, glyphs);

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

fn replaceArrowHead(
    canvas: *canvas_mod.Canvas,
    tgt_top: usize,
    tgt_left: usize,
    tgt_box_h: usize,
    cell_w: usize,
    rel: types.ClassRelation,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    const tgt_center = tgt_left + cell_w / 2;

    const border_row = tgt_top + tgt_box_h - 1;
    if (border_row < canvas.rows and tgt_center < canvas.cols) {
        canvas.setGlyph(border_row, tgt_center, glyphs.tee_t);
    }

    const arrow_row = tgt_top + tgt_box_h;
    if (arrow_row < canvas.rows and tgt_center < canvas.cols) {
        const head = relationHead(rel.kind, glyphs);
        canvas.setGlyph(arrow_row, tgt_center, head);
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

test "writeClass renders class box with name and members" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeClass(&sink.writer, alloc,
        \\classDiagram
        \\    class Animal
        \\    Animal : +str name
        \\    Animal : +eat()
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Animal") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+ name") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+ eat") != null);
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
