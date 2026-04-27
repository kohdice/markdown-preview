const std = @import("std");
const types = @import("types.zig");
const layout_flowchart = @import("layout_flowchart.zig");
const route_mod = @import("route.zig");
const canvas_mod = @import("canvas.zig");
const paint_mod = @import("paint.zig");
const width_mod = @import("../term/width.zig");

pub const PaintError = paint_mod.PaintError;
pub const Options = paint_mod.PaintOptions;

pub fn paintMermaidGraph(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    graph: *const @import("types.zig").MermaidGraph,
    opts: Options,
) PaintError!void {
    const needs_vflip = graph.direction == .bottom_up;
    var effective = graph.*;
    effective.direction = if (needs_vflip) .top_down else graph.direction;

    var layout = layout_flowchart.computeLayout(allocator, &effective, opts.ambiguous_width) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer layout.deinit();

    if (layout.rows == 0 or layout.cols == 0) return;

    const canvas_rows = route_mod.canvasRows(&layout);
    const canvas_cols = route_mod.canvasCols(&layout);
    if (canvas_rows == 0 or canvas_cols == 0) return;

    var canvas = canvas_mod.Canvas.init(allocator, canvas_rows, canvas_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    const glyphs = canvas_mod.GlyphSet.unicode;

    for (layout.subgraph_frames) |frame| {
        drawSubgraphFrame(&canvas, &layout, frame, &glyphs);
    }

    for (graph.nodes, 0..) |node, i| {
        if (node.is_composite) continue;
        const pos = layout.positions[i];
        const top = route_mod.boxTop(&layout, pos.row);
        const left = route_mod.boxLeft(&layout, pos.col);
        switch (node.shape) {
            .diamond => canvas.drawDiamondBox(top, left, layout.cell_h, layout.cell_w, &glyphs),
            .round, .stadium, .circle => canvas.drawRoundBox(top, left, layout.cell_h, layout.cell_w, &glyphs),
            .subroutine, .double_circle => canvas.drawDoubleBox(top, left, layout.cell_h, layout.cell_w, &glyphs),
            .cylinder => canvas.drawCylinderBox(top, left, layout.cell_h, layout.cell_w, &glyphs),
            .hexagon => canvas.drawHexagonBox(top, left, layout.cell_h, layout.cell_w, &glyphs),
            .asymmetric => canvas.drawAsymmetricBox(top, left, layout.cell_h, layout.cell_w, &glyphs),
            .trapezoid, .inv_trapezoid => canvas.drawRect(top, left, layout.cell_h, layout.cell_w, &glyphs),
            .rect, .implicit => canvas.drawRect(top, left, layout.cell_h, layout.cell_w, &glyphs),
        }
        const label = layout.truncated_labels[i];
        const label_w = width_mod.displayWidth(label, opts.ambiguous_width);
        const label_row = top + layout.cell_h / 2;
        const inner_w = layout.cell_w - 2;
        const label_col = left + 1 + (if (inner_w > label_w) (inner_w - label_w) / 2 else 0);
        canvas.drawLabel(label_row, label_col, label, opts.ambiguous_width);
    }

    const layout_dir = effective.direction.layoutDir();
    for (graph.edges) |edge| {
        const from_ep = layout.resolveEdgeEndpoint(graph.nodes, edge.from);
        const to_ep = layout.resolveEdgeEndpoint(graph.nodes, edge.to);
        if (from_ep == null or to_ep == null) continue;
        const has_frame = from_ep.? == .frame or to_ep.? == .frame;
        if (has_frame) {
            routeCompositeEdge(allocator, &canvas, &layout, from_ep.?, to_ep.?, edge, &glyphs, opts.ambiguous_width) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            continue;
        }
        route_mod.routeEdge(allocator, &canvas, &layout, edge, layout_dir, &glyphs, opts.ambiguous_width) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (edge.bidirectional) {
            const src_pos = layout.positions[edge.from];
            const src_top = route_mod.boxTop(&layout, src_pos.row);
            const src_left = route_mod.boxLeft(&layout, src_pos.col);
            const src_cx = src_left + layout.cell_w / 2;
            const src_cy = src_top + layout.cell_h / 2;
            route_mod.paintSourceArrowHead(&canvas, layout_dir, src_top, src_left, src_cx, src_cy, &glyphs);
        }
    }

    route_mod.mergeJunctions(allocator, &canvas, &glyphs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    for (layout.subgraph_frames) |frame| {
        drawSubgraphTitle(&canvas, &layout, frame, opts.ambiguous_width);
    }

    if (needs_vflip) canvas.flipVertical();

    canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
}

fn routeCompositeEdge(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    layout: *const @import("types.zig").Layout,
    from_ep: @import("types.zig").EndpointTarget,
    to_ep: @import("types.zig").EndpointTarget,
    edge: @import("types.zig").Edge,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) route_mod.RouteError!void {
    const start_center = epCenter(layout, from_ep) orelse return;
    const goal_center = epCenter(layout, to_ep) orelse return;

    const start_port = epFacingPort(layout, from_ep, goal_center) orelse return;
    const goal_port = epFacingPort(layout, to_ep, start_center) orelse return;

    _ = try route_mod.routeEdgeWithPorts(
        allocator,
        canvas,
        layout,
        edge.from,
        edge.to,
        start_port.row,
        start_port.col,
        start_port.dir,
        goal_port.row,
        goal_port.col,
        edge.label,
        edge.style,
        glyphs,
        ambiguous,
    );
}

const PortXY = struct { row: usize, col: usize, dir: route_mod.Dir4 };
const Center = struct { row: usize, col: usize };

fn epCenter(layout: *const @import("types.zig").Layout, ep: @import("types.zig").EndpointTarget) ?Center {
    switch (ep) {
        .node => |id| {
            const pos = layout.positions[id];
            const top = route_mod.boxTop(layout, pos.row);
            const left = route_mod.boxLeft(layout, pos.col);
            return .{ .row = top + layout.cell_h / 2, .col = left + layout.cell_w / 2 };
        },
        .frame => |frame| {
            const cr = route_mod.canvasRows(layout);
            const cc = route_mod.canvasCols(layout);
            if (frameBox(layout, cr, cc, frame)) |fb| {
                return .{ .row = fb.top + fb.h / 2, .col = fb.left + fb.w / 2 };
            }
            return null;
        },
    }
}

fn epFacingPort(layout: *const @import("types.zig").Layout, ep: @import("types.zig").EndpointTarget, toward: Center) ?PortXY {
    switch (ep) {
        .node => |id| {
            const pos = layout.positions[id];
            const top = route_mod.boxTop(layout, pos.row);
            const left = route_mod.boxLeft(layout, pos.col);
            return pickSide(top, left, top + layout.cell_h - 1, left + layout.cell_w - 1, toward);
        },
        .frame => |frame| {
            const cr = route_mod.canvasRows(layout);
            const cc = route_mod.canvasCols(layout);
            const fb = frameBox(layout, cr, cc, frame) orelse return null;
            return pickSide(fb.top, fb.left, fb.top + fb.h - 1, fb.left + fb.w - 1, toward);
        },
    }
}

fn pickSide(top: usize, left: usize, bottom: usize, right: usize, toward: Center) PortXY {
    const cx = (left + right) / 2;
    const cy = (top + bottom) / 2;
    const dy = @as(isize, @intCast(toward.row)) - @as(isize, @intCast(cy));
    const dx = @as(isize, @intCast(toward.col)) - @as(isize, @intCast(cx));
    if (@abs(dy) >= @abs(dx)) {
        if (dy >= 0) return .{ .row = bottom, .col = cx, .dir = .down };
        return .{ .row = top, .col = cx, .dir = .up };
    } else {
        if (dx >= 0) return .{ .row = cy, .col = right, .dir = .right };
        return .{ .row = cy, .col = left, .dir = .left };
    }
}

const FrameBox = struct { top: usize, left: usize, h: usize, w: usize };

fn frameBox(
    layout: *const @import("types.zig").Layout,
    canvas_rows: usize,
    canvas_cols: usize,
    frame: @import("types.zig").SubgraphFrame,
) ?FrameBox {
    const inner_top = route_mod.boxTop(layout, frame.row_start);
    const inner_left = route_mod.boxLeft(layout, frame.col_start);
    const inner_bottom = route_mod.boxTop(layout, frame.row_end) + layout.cell_h;
    const inner_right = route_mod.boxLeft(layout, frame.col_end) + layout.cell_w;

    const pad = if (layout.outer_pad > frame.depth) layout.outer_pad - frame.depth else 1;
    const top = if (inner_top >= pad) inner_top - pad else 0;
    const left = if (inner_left >= pad) inner_left - pad else 0;
    const bottom_raw = inner_bottom + pad - 1;
    const right_raw = inner_right + pad - 1;
    const bottom = if (bottom_raw >= canvas_rows) canvas_rows - 1 else bottom_raw;
    const right = if (right_raw >= canvas_cols) canvas_cols - 1 else right_raw;
    if (bottom <= top or right <= left) return null;

    return .{ .top = top, .left = left, .h = bottom - top + 1, .w = right - left + 1 };
}

fn drawSubgraphFrame(
    canvas: *canvas_mod.Canvas,
    layout: *const @import("types.zig").Layout,
    frame: @import("types.zig").SubgraphFrame,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    const box = frameBox(layout, canvas.rows, canvas.cols, frame) orelse return;
    canvas.drawRect(box.top, box.left, box.h, box.w, glyphs);
}

fn drawSubgraphTitle(
    canvas: *canvas_mod.Canvas,
    layout: *const @import("types.zig").Layout,
    frame: @import("types.zig").SubgraphFrame,
    ambiguous: width_mod.AmbiguousWidth,
) void {
    const title = frame.title orelse return;
    if (title.len == 0) return;
    const box = frameBox(layout, canvas.rows, canvas.cols, frame) orelse return;
    if (box.w <= 4) return;
    const budget = box.w - 4;
    const clipped = clipToWidth(title, budget, ambiguous);
    if (clipped.len == 0) return;
    canvas.drawLabel(box.top, box.left + 2, clipped, ambiguous);
}

fn clipToWidth(text: []const u8, budget: usize, ambiguous: width_mod.AmbiguousWidth) []const u8 {
    var view = std.unicode.Utf8View.init(text) catch return "";
    var it = view.iterator();
    var kept: usize = 0;
    while (it.nextCodepointSlice()) |cp| {
        const next = kept + cp.len;
        if (width_mod.displayWidth(text[0..next], ambiguous) > budget) break;
        kept = next;
    }
    return text[0..kept];
}
