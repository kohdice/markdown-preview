const std = @import("std");
const types = @import("types.zig");
const layout_flowchart = @import("layout_flowchart.zig");
const route_mod = @import("route.zig");
const canvas_mod = @import("canvas.zig");
const paint_mod = @import("paint.zig");
const text_layout = @import("text_layout.zig");
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

    var layout = layout_flowchart.computeLayout(allocator, &effective, .{
        .wrap_width = opts.wrap_width,
        .ambiguous_width = opts.ambiguous_width,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WidthTooSmall => return error.WidthTooSmall,
    };
    defer layout.deinit();

    if (layout.rows == 0 or layout.cols == 0) return;

    const canvas_rows = route_mod.canvasRows(&layout);
    const canvas_cols = route_mod.canvasCols(&layout);
    if (canvas_rows == 0 or canvas_cols == 0) return;
    if (opts.wrap_width) |w| {
        if (canvas_cols > w) return error.WidthTooSmall;
    }
    const layout_dir = effective.direction.layoutDir();
    if (opts.wrap_width != null and layout_dir.isHorizontal() and hasBlockedSingleColumnBandedEdge(&layout, &effective, canvas_cols)) {
        return error.WidthTooSmall;
    }
    const defer_route_labels = opts.wrap_width != null and hasRouteLabels(&effective);

    var canvas = canvas_mod.Canvas.init(allocator, canvas_rows, canvas_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    const glyphs = canvas_mod.GlyphSet.unicode;
    var routed_labels: std.ArrayList(RoutedEdgeLabel) = .empty;
    defer routed_labels.deinit(allocator);
    defer deinitRoutedEdgeLabels(allocator, routed_labels.items);

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
        const inner_w = layout.cell_w - 2;
        const inner_h = layout.cell_h - 2;
        try text_layout.drawCenteredLabel(
            &canvas,
            top + 1,
            left + 1,
            inner_h,
            inner_w,
            layout.node_labels[i].lines,
            opts.ambiguous_width,
        );
    }

    for (graph.edges) |edge| {
        const from_ep = layout.resolveEdgeEndpoint(graph.nodes, edge.from);
        const to_ep = layout.resolveEdgeEndpoint(graph.nodes, edge.to);
        if (from_ep == null or to_ep == null) continue;
        const has_frame = from_ep.? == .frame or to_ep.? == .frame;
        if (has_frame) {
            const maybe_route = routeCompositeEdge(allocator, &canvas, &layout, from_ep.?, to_ep.?, edge, &glyphs, defer_route_labels, opts.ambiguous_width) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (try routeForDeferredLabel(allocator, &layout, from_ep.?, to_ep.?, edge, maybe_route, defer_route_labels, opts.ambiguous_width)) |route| {
                try appendRoutedEdgeLabel(allocator, &routed_labels, edge, route, defer_route_labels, opts.ambiguous_width);
            }
            continue;
        }
        const maybe_route = route_mod.routeEdge(allocator, &canvas, &layout, edge, layout_dir, &glyphs, defer_route_labels, opts.ambiguous_width) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (try routeForDeferredLabel(allocator, &layout, from_ep.?, to_ep.?, edge, maybe_route, defer_route_labels, opts.ambiguous_width)) |route| {
            try appendRoutedEdgeLabel(allocator, &routed_labels, edge, route, defer_route_labels, opts.ambiguous_width);
        }
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

    if (defer_route_labels) {
        try redrawWrappedEdgeLabels(allocator, &canvas, &layout, &effective, layout_dir, routed_labels.items, opts.ambiguous_width);
    }

    for (layout.subgraph_frames) |frame| {
        try drawSubgraphTitle(&canvas, &layout, frame, opts.wrap_width, opts.ambiguous_width);
    }

    if (needs_vflip) canvas.flipVertical();

    canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
}

fn hasRouteLabels(graph: *const types.MermaidGraph) bool {
    for (graph.edges) |edge| {
        const label = edge.label orelse continue;
        if (label.len > 0) return true;
    }
    return false;
}

fn hasBlockedSingleColumnBandedEdge(layout: *const types.Layout, graph: *const types.MermaidGraph, canvas_cols: usize) bool {
    if (layout.cols != 1 or canvas_cols > layout.cell_w) return false;

    for (graph.edges) |edge| {
        if (edge.label != null) continue;
        if (edge.from >= layout.positions.len or edge.to >= layout.positions.len) continue;
        if (graph.nodes[edge.from].is_composite or graph.nodes[edge.to].is_composite) continue;

        const from_pos = layout.positions[edge.from];
        const to_pos = layout.positions[edge.to];
        if (from_pos.col != to_pos.col) continue;

        const row_min = @min(from_pos.row, to_pos.row);
        const row_max = @max(from_pos.row, to_pos.row);
        if (row_max <= row_min + 1) continue;

        for (graph.nodes, 0..) |node, id| {
            if (id == edge.from or id == edge.to or node.is_composite) continue;
            const pos = layout.positions[id];
            if (pos.col == from_pos.col and pos.row > row_min and pos.row < row_max) return true;
        }
    }

    return false;
}

fn routeCompositeEdge(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    layout: *const @import("types.zig").Layout,
    from_ep: @import("types.zig").EndpointTarget,
    to_ep: @import("types.zig").EndpointTarget,
    edge: @import("types.zig").Edge,
    glyphs: *const canvas_mod.GlyphSet,
    defer_label_placement: bool,
    ambiguous: width_mod.AmbiguousWidth,
) route_mod.RouteError!?route_mod.EdgeRoute {
    const start_center = epCenter(layout, from_ep) orelse return null;
    const goal_center = epCenter(layout, to_ep) orelse return null;

    const start_port = epFacingPort(layout, from_ep, goal_center) orelse return null;
    const goal_port = epFacingPort(layout, to_ep, start_center) orelse return null;

    return try route_mod.routeEdgeWithPorts(
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
        defer_label_placement,
        ambiguous,
    );
}

const PortXY = struct { row: usize, col: usize, dir: route_mod.Dir4 };
const Center = struct { row: usize, col: usize };

const RoutedEdgeLabel = struct {
    edge: types.Edge,
    route: route_mod.EdgeRoute,
};

fn deinitRoutedEdgeLabels(allocator: std.mem.Allocator, routed_labels: []RoutedEdgeLabel) void {
    for (routed_labels) |*routed| routed.route.deinit(allocator);
}

fn appendRoutedEdgeLabel(
    allocator: std.mem.Allocator,
    routed_labels: *std.ArrayList(RoutedEdgeLabel),
    edge: types.Edge,
    route: route_mod.EdgeRoute,
    defer_route_labels: bool,
    ambiguous: width_mod.AmbiguousWidth,
) PaintError!void {
    var owned_route = route;
    errdefer owned_route.deinit(allocator);

    if (!defer_route_labels or edgeLabelWidth(edge, ambiguous) == 0 or owned_route.label_path.points.len == 0) {
        owned_route.deinit(allocator);
        return;
    }

    try routed_labels.append(allocator, .{
        .edge = edge,
        .route = owned_route,
    });
}

fn routeForDeferredLabel(
    allocator: std.mem.Allocator,
    layout: *const types.Layout,
    from_ep: types.EndpointTarget,
    to_ep: types.EndpointTarget,
    edge: types.Edge,
    maybe_route: ?route_mod.EdgeRoute,
    defer_route_labels: bool,
    ambiguous: width_mod.AmbiguousWidth,
) PaintError!?route_mod.EdgeRoute {
    var route = maybe_route orelse {
        if (!defer_route_labels or edgeLabelWidth(edge, ambiguous) == 0) return null;
        return try syntheticLabelRoute(allocator, layout, from_ep, to_ep);
    };

    if (!defer_route_labels or edgeLabelWidth(edge, ambiguous) == 0) {
        route.deinit(allocator);
        return null;
    }
    if (route.label_path.points.len == 0) {
        route.deinit(allocator);
        return try syntheticLabelRoute(allocator, layout, from_ep, to_ep);
    }
    return route;
}

fn syntheticLabelRoute(
    allocator: std.mem.Allocator,
    layout: *const types.Layout,
    from_ep: types.EndpointTarget,
    to_ep: types.EndpointTarget,
) PaintError!route_mod.EdgeRoute {
    const start_center = epCenter(layout, from_ep) orelse return error.WidthTooSmall;
    const goal_center = epCenter(layout, to_ep) orelse return error.WidthTooSmall;
    const start_port = epFacingPort(layout, from_ep, goal_center) orelse return error.WidthTooSmall;
    const goal_port = epFacingPort(layout, to_ep, start_center) orelse return error.WidthTooSmall;

    var path: std.ArrayList(route_mod.SearchKey) = .empty;
    errdefer path.deinit(allocator);
    try path.append(allocator, .{
        .row = @intCast(start_port.row),
        .col = @intCast(start_port.col),
        .dir = start_port.dir,
    });

    if (route_mod.axisOf(start_port.dir) == .vertical) {
        try appendSyntheticVertical(allocator, &path, start_port.row, goal_port.row, start_port.col);
        try appendSyntheticHorizontal(allocator, &path, start_port.col, goal_port.col, goal_port.row);
    } else {
        try appendSyntheticHorizontal(allocator, &path, start_port.col, goal_port.col, start_port.row);
        try appendSyntheticVertical(allocator, &path, start_port.row, goal_port.row, goal_port.col);
    }

    return .{
        .endpoints = .{ .start_dir = start_port.dir, .end_dir = goal_port.dir },
        .label_path = .{ .points = try path.toOwnedSlice(allocator) },
    };
}

fn appendSyntheticVertical(
    allocator: std.mem.Allocator,
    path: *std.ArrayList(route_mod.SearchKey),
    from_row: usize,
    to_row: usize,
    col: usize,
) PaintError!void {
    if (from_row == to_row) return;
    const dir: route_mod.Dir4 = if (to_row > from_row) .down else .up;
    var row = from_row;
    while (row != to_row) {
        if (to_row > from_row) row += 1 else row -= 1;
        try path.append(allocator, .{
            .row = @intCast(row),
            .col = @intCast(col),
            .dir = dir,
        });
    }
}

fn appendSyntheticHorizontal(
    allocator: std.mem.Allocator,
    path: *std.ArrayList(route_mod.SearchKey),
    from_col: usize,
    to_col: usize,
    row: usize,
) PaintError!void {
    if (from_col == to_col) return;
    const dir: route_mod.Dir4 = if (to_col > from_col) .right else .left;
    var col = from_col;
    while (col != to_col) {
        if (to_col > from_col) col += 1 else col -= 1;
        try path.append(allocator, .{
            .row = @intCast(row),
            .col = @intCast(col),
            .dir = dir,
        });
    }
}

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

fn redrawWrappedEdgeLabels(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    layout: *const types.Layout,
    graph: *const types.MermaidGraph,
    layout_dir: types.Direction,
    routed_labels: []const RoutedEdgeLabel,
    ambiguous: width_mod.AmbiguousWidth,
) PaintError!void {
    const sorted_edge_indexes = try allocator.alloc(usize, routed_labels.len);
    defer allocator.free(sorted_edge_indexes);
    for (sorted_edge_indexes, 0..) |*idx, i| idx.* = i;

    std.mem.sort(usize, sorted_edge_indexes, LabelOrder{
        .routed_labels = routed_labels,
        .ambiguous = ambiguous,
    }, LabelOrder.lessThan);

    for (sorted_edge_indexes) |idx| {
        if (edgeLabelWidth(routed_labels[idx].edge, ambiguous) == 0) break;
        try redrawWrappedEdgeLabel(allocator, canvas, layout, graph, layout_dir, routed_labels[idx], ambiguous);
    }
}

const LabelOrder = struct {
    routed_labels: []const RoutedEdgeLabel,
    ambiguous: width_mod.AmbiguousWidth,

    fn lessThan(ctx: LabelOrder, lhs: usize, rhs: usize) bool {
        const lhs_w = edgeLabelWidth(ctx.routed_labels[lhs].edge, ctx.ambiguous);
        const rhs_w = edgeLabelWidth(ctx.routed_labels[rhs].edge, ctx.ambiguous);
        if (lhs_w != rhs_w) return lhs_w > rhs_w;
        return lhs < rhs;
    }
};

fn edgeLabelWidth(edge: types.Edge, ambiguous: width_mod.AmbiguousWidth) usize {
    const label = edge.label orelse return 0;
    if (label.len == 0) return 0;
    return width_mod.displayWidth(label, ambiguous);
}

fn redrawWrappedEdgeLabel(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    layout: *const types.Layout,
    graph: *const types.MermaidGraph,
    layout_dir: types.Direction,
    routed_label: RoutedEdgeLabel,
    ambiguous: width_mod.AmbiguousWidth,
) PaintError!void {
    const glyphs = canvas_mod.GlyphSet.unicode;
    const edge = routed_label.edge;
    const label = edge.label orelse return;
    const path = routed_label.route.label_path.points;
    const anchor = routeLabelAnchor(path) orelse return error.WidthTooSmall;

    const label_w = width_mod.displayWidth(label, ambiguous);
    const label_budget = if (layout_dir.isHorizontal() or label_w > canvas.cols)
        text_layout.edgeLabelWrapWidth(canvas.cols)
    else
        canvas.cols;
    var label_layout = text_layout.layoutLabel(allocator, label, label_budget, ambiguous) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer label_layout.deinit();
    if (label_layout.lines.len == 0) return;

    const preferred_row = if (anchor.row > label_layout.lines.len / 2)
        anchor.row - label_layout.lines.len / 2
    else
        0;
    const preferred_col = if (anchor.col > label_layout.max_line_width / 2)
        anchor.col - label_layout.max_line_width / 2
    else
        0;

    const placement = findDeferredLabelPlacement(
        canvas,
        layout,
        graph,
        path,
        label_layout.lines,
        label_layout.max_line_width,
        preferred_row,
        preferred_col,
        &glyphs,
        true,
        true,
        true,
    ) orelse findDeferredLabelPlacement(
        canvas,
        layout,
        graph,
        path,
        label_layout.lines,
        label_layout.max_line_width,
        preferred_row,
        preferred_col,
        &glyphs,
        false,
        true,
        true,
    ) orelse findDeferredLabelPlacement(
        canvas,
        layout,
        graph,
        path,
        label_layout.lines,
        label_layout.max_line_width,
        preferred_row,
        preferred_col,
        &glyphs,
        false,
        false,
        false,
    ) orelse return error.WidthTooSmall;

    try drawPlacedLabel(canvas, label_layout.lines, label_layout.max_line_width, placement, ambiguous);
}

const LabelPlacement = struct {
    row: usize,
    col: usize,
};

fn routeLabelAnchor(path: []const route_mod.SearchKey) ?LabelPlacement {
    if (path.len == 0) return null;
    const point = path[path.len / 2];
    return .{
        .row = @intCast(point.row),
        .col = @intCast(point.col),
    };
}

fn findDeferredLabelPlacement(
    canvas: *const canvas_mod.Canvas,
    layout: *const types.Layout,
    graph: *const types.MermaidGraph,
    path: []const route_mod.SearchKey,
    lines: []const types.LabelLine,
    max_line_width: usize,
    preferred_row: usize,
    preferred_col: usize,
    glyphs: *const canvas_mod.GlyphSet,
    avoid_text_neighbors: bool,
    require_route_touch: bool,
    protect_foreign_lines: bool,
) ?LabelPlacement {
    if (lines.len == 0 or max_line_width == 0) return null;
    if (lines.len > canvas.rows or max_line_width > canvas.cols) return null;

    const max_row = canvas.rows - lines.len;
    const max_col = canvas.cols - max_line_width;
    const base_row = @min(preferred_row, max_row);
    const base_col = @min(preferred_col, max_col);

    var best: ?LabelPlacement = null;
    var best_score: usize = std.math.maxInt(usize);

    for (0..max_row + 1) |row| {
        for (0..max_col + 1) |col| {
            const placement: LabelPlacement = .{ .row = row, .col = col };
            if (!canPlaceDeferredLabel(canvas, layout, graph, path, lines, max_line_width, placement, glyphs, avoid_text_neighbors, require_route_touch, protect_foreign_lines)) continue;

            const row_distance = if (row > base_row) row - base_row else base_row - row;
            const col_distance = if (col > base_col) col - base_col else base_col - col;
            const score = row_distance * canvas.cols + col_distance;
            if (score < best_score) {
                best = placement;
                best_score = score;
            }
        }
    }

    return best;
}

fn canPlaceDeferredLabel(
    canvas: *const canvas_mod.Canvas,
    layout: *const types.Layout,
    graph: *const types.MermaidGraph,
    path: []const route_mod.SearchKey,
    lines: []const types.LabelLine,
    max_line_width: usize,
    placement: LabelPlacement,
    glyphs: *const canvas_mod.GlyphSet,
    avoid_text_neighbors: bool,
    require_route_touch: bool,
    protect_foreign_lines: bool,
) bool {
    if (require_route_touch and !labelPlacementTouchesRoutePath(path, placement, lines.len, max_line_width)) return false;

    for (lines, 0..) |line, idx| {
        const row = placement.row + idx;
        const col = placement.col + (max_line_width - line.width) / 2;
        var c = col;
        while (c < col + line.width) : (c += 1) {
            if (isProtectedGraphCell(layout, graph, canvas.rows, canvas.cols, row, c)) return false;
            const cell = canvas.cells[row * canvas.cols + c];
            if (!isDeferredLabelDrawableCell(cell, glyphs)) return false;
            if (protect_foreign_lines and cell.cp != ' ' and !routePathContains(path, row, c)) return false;
        }
        if (avoid_text_neighbors and deferredLabelTouchesText(canvas, row, col, line.width, glyphs)) return false;
    }
    return true;
}

fn labelPlacementTouchesRoutePath(
    path: []const route_mod.SearchKey,
    placement: LabelPlacement,
    line_count: usize,
    max_line_width: usize,
) bool {
    if (line_count == 0 or max_line_width == 0) return false;

    const row_min = if (placement.row == 0) 0 else placement.row - 1;
    const row_max = placement.row + line_count;
    const col_min = if (placement.col == 0) 0 else placement.col - 1;
    const col_max = placement.col + max_line_width;

    for (path) |point| {
        const point_row: usize = @intCast(point.row);
        const point_col: usize = @intCast(point.col);
        if (point_row >= row_min and point_row <= row_max and
            point_col >= col_min and point_col <= col_max)
        {
            return true;
        }
    }
    return false;
}

fn routePathContains(path: []const route_mod.SearchKey, row: usize, col: usize) bool {
    for (path) |point| {
        if (@as(usize, @intCast(point.row)) == row and @as(usize, @intCast(point.col)) == col) return true;
    }
    return false;
}

fn deferredLabelTouchesText(
    canvas: *const canvas_mod.Canvas,
    row: usize,
    col: usize,
    width: usize,
    glyphs: *const canvas_mod.GlyphSet,
) bool {
    if (width == 0) return false;

    const row_min = if (row == 0) 0 else row - 1;
    const row_max = @min(canvas.rows - 1, row + 1);
    const col_min = if (col == 0) 0 else col - 1;
    const col_max = @min(canvas.cols - 1, col + width);

    for (row_min..row_max + 1) |r| {
        for (col_min..col_max + 1) |c| {
            const cell = canvas.cells[r * canvas.cols + c];
            if (!isDeferredLabelNeighborCell(cell, glyphs)) return true;
        }
    }

    return false;
}

fn drawPlacedLabel(
    canvas: *canvas_mod.Canvas,
    lines: []const types.LabelLine,
    max_line_width: usize,
    placement: LabelPlacement,
    ambiguous: width_mod.AmbiguousWidth,
) PaintError!void {
    for (lines, 0..) |line, idx| {
        const col = placement.col + (max_line_width - line.width) / 2;
        try canvas.drawLabel(placement.row + idx, col, line.text, ambiguous);
    }
}

fn isProtectedGraphCell(
    layout: *const types.Layout,
    graph: *const types.MermaidGraph,
    canvas_rows: usize,
    canvas_cols: usize,
    row: usize,
    col: usize,
) bool {
    for (graph.nodes, 0..) |node, id| {
        if (node.is_composite or id >= layout.positions.len) continue;
        const pos = layout.positions[id];
        const top = route_mod.boxTop(layout, pos.row);
        const left = route_mod.boxLeft(layout, pos.col);
        if (row >= top and row < top + layout.cell_h and
            col >= left and col < left + layout.cell_w)
        {
            return true;
        }
    }

    for (layout.subgraph_frames) |frame| {
        const box = frameBox(layout, canvas_rows, canvas_cols, frame) orelse continue;
        const bottom = box.top + box.h - 1;
        const right = box.left + box.w - 1;
        if (row < box.top or row > bottom or col < box.left or col > right) continue;
        if (row == box.top or row == bottom or col == box.left or col == right) return true;
    }

    return false;
}

fn isDeferredLabelDrawableCell(cell: canvas_mod.Cell, glyphs: *const canvas_mod.GlyphSet) bool {
    if (cell.kind != .glyph) return false;
    if (cell.cp == ' ') return true;
    return cell.cp == glyphs.h_line or
        cell.cp == glyphs.v_line or
        cell.cp == glyphs.h_line_dashed or
        cell.cp == glyphs.v_line_dashed or
        cell.cp == glyphs.corner_tl or
        cell.cp == glyphs.corner_tr or
        cell.cp == glyphs.corner_bl or
        cell.cp == glyphs.corner_br or
        cell.cp == glyphs.tee_l or
        cell.cp == glyphs.tee_r or
        cell.cp == glyphs.tee_t or
        cell.cp == glyphs.tee_b or
        cell.cp == glyphs.cross;
}

fn isDeferredLabelNeighborCell(cell: canvas_mod.Cell, glyphs: *const canvas_mod.GlyphSet) bool {
    return isDeferredLabelDrawableCell(cell, glyphs) or
        cell.cp == glyphs.arrow_up or
        cell.cp == glyphs.arrow_down or
        cell.cp == glyphs.arrow_left or
        cell.cp == glyphs.arrow_right;
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

    const pad_y_base = layout.verticalOuterPad();
    const pad_x_base = layout.outer_pad;
    const pad_y = if (pad_y_base > frame.depth) pad_y_base - frame.depth else 1;
    const pad_x = if (pad_x_base > frame.depth) pad_x_base - frame.depth else 1;
    const top = if (inner_top >= pad_y) inner_top - pad_y else 0;
    const left = if (inner_left >= pad_x) inner_left - pad_x else 0;
    const bottom_raw = inner_bottom + pad_y - 1;
    const right_raw = inner_right + pad_x - 1;
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
    wrap_width: ?usize,
    ambiguous: width_mod.AmbiguousWidth,
) PaintError!void {
    const title = frame.title orelse return;
    if (title.len == 0) return;
    const box = frameBox(layout, canvas.rows, canvas.cols, frame) orelse return;
    if (box.w <= 4) return;
    const budget = box.w - 4;
    if (wrap_width == null) {
        const clipped = width_mod.sliceToDisplayWidth(title, budget, ambiguous);
        if (clipped.len == 0) return;
        try canvas.drawLabel(box.top, box.left + 2, clipped, ambiguous);
        return;
    }

    var title_layout = text_layout.layoutLabel(canvas.allocator, title, budget, ambiguous) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer title_layout.deinit();
    if (title_layout.max_line_width > budget) return error.WidthTooSmall;
    const inner_top = route_mod.boxTop(layout, frame.row_start);
    const top_room = inner_top - box.top;
    if (title_layout.lines.len > top_room) return error.WidthTooSmall;
    for (title_layout.lines, 0..) |line, idx| {
        const col_offset = if (budget > line.width) (budget - line.width) / 2 else 0;
        try canvas.drawLabel(box.top + idx, box.left + 2 + col_offset, line.text, ambiguous);
    }
}

test "deferred route labels may cover line segments but not arrowheads" {
    const glyphs = canvas_mod.GlyphSet.unicode;

    try std.testing.expect(isDeferredLabelDrawableCell(.{ .cp = glyphs.h_line }, &glyphs));
    try std.testing.expect(isDeferredLabelDrawableCell(.{ .cp = glyphs.v_line }, &glyphs));
    try std.testing.expect(!isDeferredLabelDrawableCell(.{ .cp = glyphs.arrow_up }, &glyphs));
    try std.testing.expect(!isDeferredLabelDrawableCell(.{ .cp = glyphs.arrow_down }, &glyphs));
    try std.testing.expect(!isDeferredLabelDrawableCell(.{ .cp = glyphs.arrow_left }, &glyphs));
    try std.testing.expect(!isDeferredLabelDrawableCell(.{ .cp = glyphs.arrow_right }, &glyphs));
}

test "deferred route labels may sit next to arrowheads" {
    const glyphs = canvas_mod.GlyphSet.unicode;

    try std.testing.expect(isDeferredLabelNeighborCell(.{ .cp = glyphs.arrow_up }, &glyphs));
    try std.testing.expect(isDeferredLabelNeighborCell(.{ .cp = glyphs.arrow_down }, &glyphs));
    try std.testing.expect(isDeferredLabelNeighborCell(.{ .cp = glyphs.arrow_left }, &glyphs));
    try std.testing.expect(isDeferredLabelNeighborCell(.{ .cp = glyphs.arrow_right }, &glyphs));
}

test "deferred route labels do not cover foreign route segments in route-constrained placement" {
    const allocator = std.testing.allocator;
    const glyphs = canvas_mod.GlyphSet.unicode;
    var canvas = try canvas_mod.Canvas.init(allocator, 3, 3);
    defer canvas.deinit();
    canvas.setGlyph(1, 1, glyphs.h_line);

    const layout: types.Layout = .{
        .allocator = allocator,
        .positions = &.{},
        .node_labels = &.{},
        .rows = 0,
        .cols = 0,
        .cell_w = 0,
        .cell_h = 0,
    };
    const graph: types.MermaidGraph = .{
        .allocator = allocator,
        .direction = .top_down,
        .nodes = &.{},
        .edges = &.{},
    };
    const lines = [_]types.LabelLine{.{ .text = "x", .width = 1 }};
    const foreign_path = [_]route_mod.SearchKey{.{ .row = 2, .col = 2, .dir = .right }};
    const own_path = [_]route_mod.SearchKey{.{ .row = 1, .col = 1, .dir = .right }};

    try std.testing.expect(!canPlaceDeferredLabel(&canvas, &layout, &graph, &foreign_path, &lines, 1, .{ .row = 1, .col = 1 }, &glyphs, false, true, true));
    try std.testing.expect(canPlaceDeferredLabel(&canvas, &layout, &graph, &own_path, &lines, 1, .{ .row = 1, .col = 1 }, &glyphs, false, true, true));
}
