const std = @import("std");
const types = @import("types.zig");
const canvas_mod = @import("canvas.zig");
const width_mod = @import("../term/width.zig");

pub const RouteError = error{
    OutOfMemory,
};

pub const gutter_w: usize = 2;
pub const gutter_h: usize = 2;

pub const Dir4 = enum { up, down, left, right };

pub const Axis = enum { horizontal, vertical };

pub fn axisOf(dir: Dir4) Axis {
    return switch (dir) {
        .up, .down => .vertical,
        .left, .right => .horizontal,
    };
}

pub const EdgeEndpoints = struct {
    start_dir: Dir4,
    end_dir: Dir4,
};

pub const SearchKey = struct { row: u32, col: u32, dir: Dir4 };

pub fn cellStepW(layout: *const types.Layout) usize {
    return layout.cell_w + gutter_w;
}

pub fn cellStepH(layout: *const types.Layout) usize {
    return layout.cell_h + gutter_h;
}

pub fn canvasRows(layout: *const types.Layout) usize {
    if (layout.rows == 0) return 0;
    return layout.rows * layout.cell_h + (layout.rows - 1) * gutter_h + 2 * layout.outer_pad;
}

pub fn canvasCols(layout: *const types.Layout) usize {
    if (layout.cols == 0) return 0;
    return layout.cols * layout.cell_w + (layout.cols - 1) * gutter_w + 2 * layout.outer_pad;
}

pub fn boxTop(layout: *const types.Layout, grid_row: usize) usize {
    return layout.outer_pad + grid_row * cellStepH(layout);
}

pub fn boxLeft(layout: *const types.Layout, grid_col: usize) usize {
    return layout.outer_pad + grid_col * cellStepW(layout);
}

pub fn routeEdge(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    layout: *const types.Layout,
    edge: types.Edge,
    direction: types.Direction,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) RouteError!void {
    const ports = computePorts(layout, edge, direction) orelse return;

    const maybe_path = aStarPath(
        allocator,
        layout,
        canvas.rows,
        canvas.cols,
        edge.from,
        edge.to,
        ports.start_row,
        ports.start_col,
        ports.initial_dir,
        ports.goal_row,
        ports.goal_col,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (maybe_path) |path_list| {
        var path = path_list;
        defer path.deinit(allocator);

        drawAStarPath(canvas, path.items, glyphs, ports.initial_dir, edge.style);

        if (edge.label) |label| {
            placeEdgeLabelOnPath(canvas, label, path.items, ambiguous);
        }
        return;
    }

    try routeFallback(canvas, layout, edge, direction, glyphs, ambiguous, edge.style);
}

pub fn routeEdgeWithPorts(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    layout: *const types.Layout,
    from_id: types.NodeId,
    to_id: types.NodeId,
    start_row: usize,
    start_col: usize,
    start_dir: Dir4,
    goal_row: usize,
    goal_col: usize,
    edge_label: ?[]const u8,
    edge_style: types.EdgeStyle,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) RouteError!EdgeEndpoints {
    const maybe_path = aStarPath(
        allocator,
        layout,
        canvas.rows,
        canvas.cols,
        from_id,
        to_id,
        start_row,
        start_col,
        start_dir,
        goal_row,
        goal_col,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (maybe_path) |path_list| {
        var path = path_list;
        defer path.deinit(allocator);

        drawAStarPath(canvas, path.items, glyphs, start_dir, edge_style);

        if (edge_label) |label| {
            placeEdgeLabelOnPath(canvas, label, path.items, ambiguous);
        }

        const end_dir = if (path.items.len == 0) start_dir else path.items[path.items.len - 1].dir;
        return .{ .start_dir = start_dir, .end_dir = end_dir };
    }

    try drawPortFallback(
        allocator,
        canvas,
        start_row,
        start_col,
        start_dir,
        goal_row,
        goal_col,
        edge_label,
        edge_style,
        glyphs,
        ambiguous,
    );

    return .{ .start_dir = start_dir, .end_dir = .up };
}

fn drawPortFallback(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    start_row: usize,
    start_col: usize,
    start_dir: Dir4,
    goal_row: usize,
    goal_col: usize,
    edge_label: ?[]const u8,
    edge_style: types.EdgeStyle,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
) RouteError!void {
    if (start_row >= canvas.rows or start_col >= canvas.cols) return;
    if (goal_row >= canvas.rows or goal_col >= canvas.cols) return;
    if (start_dir != .up) return;
    if (goal_row >= start_row) return;

    var path: std.ArrayListUnmanaged(SearchKey) = .empty;
    defer path.deinit(allocator);

    try path.append(allocator, .{
        .row = @intCast(start_row),
        .col = @intCast(start_col),
        .dir = .up,
    });

    const bend_row = if (start_col == goal_col) goal_row else (start_row + goal_row) / 2;

    var r: usize = start_row;
    while (r > bend_row) : (r -= 1) {
        try path.append(allocator, .{
            .row = @intCast(r - 1),
            .col = @intCast(start_col),
            .dir = .up,
        });
    }

    if (start_col != goal_col) {
        const horiz_dir: Dir4 = if (goal_col > start_col) .right else .left;
        var c: usize = start_col;
        while (c != goal_col) {
            if (goal_col > start_col) c += 1 else c -= 1;
            try path.append(allocator, .{
                .row = @intCast(bend_row),
                .col = @intCast(c),
                .dir = horiz_dir,
            });
        }

        r = bend_row;
        while (r > goal_row) : (r -= 1) {
            try path.append(allocator, .{
                .row = @intCast(r - 1),
                .col = @intCast(goal_col),
                .dir = .up,
            });
        }
    }

    drawAStarPath(canvas, path.items, glyphs, start_dir, edge_style);

    if (edge_label) |label| {
        placeEdgeLabelOnPath(canvas, label, path.items, ambiguous);
    }
}

const Ports = struct {
    start_row: usize,
    start_col: usize,
    initial_dir: Dir4,
    goal_row: usize,
    goal_col: usize,
};

fn computePorts(layout: *const types.Layout, edge: types.Edge, direction: types.Direction) ?Ports {
    if (edge.from >= layout.positions.len or edge.to >= layout.positions.len) return null;

    const src_pos = layout.positions[edge.from];
    const tgt_pos = layout.positions[edge.to];
    const src_top = boxTop(layout, src_pos.row);
    const src_left = boxLeft(layout, src_pos.col);
    const tgt_top = boxTop(layout, tgt_pos.row);
    const tgt_left = boxLeft(layout, tgt_pos.col);
    const src_w_center = src_left + layout.cell_w / 2;
    const src_h_center = src_top + layout.cell_h / 2;
    const tgt_w_center = tgt_left + layout.cell_w / 2;
    const tgt_h_center = tgt_top + layout.cell_h / 2;

    return switch (direction) {
        .top_down => .{
            .start_row = src_top + layout.cell_h - 1,
            .start_col = src_w_center,
            .initial_dir = .down,
            .goal_row = if (tgt_top == 0) 0 else tgt_top - 1,
            .goal_col = tgt_w_center,
        },
        .left_right => .{
            .start_row = src_h_center,
            .start_col = src_left + layout.cell_w - 1,
            .initial_dir = .right,
            .goal_row = tgt_h_center,
            .goal_col = if (tgt_left == 0) 0 else tgt_left - 1,
        },
        else => unreachable,
    };
}

const AStarEntry = struct {
    key: SearchKey,
    g: u32,
    f: u32,
};

fn lessEntry(context: void, a: AStarEntry, b: AStarEntry) std.math.Order {
    _ = context;
    return std.math.order(a.f, b.f);
}

fn manhattan(a_r: usize, a_c: usize, b_r: usize, b_c: usize) u32 {
    const dr = if (a_r > b_r) a_r - b_r else b_r - a_r;
    const dc = if (a_c > b_c) a_c - b_c else b_c - a_c;
    return @intCast(dr + dc);
}

fn isBoxInterior(
    layout: *const types.Layout,
    row: usize,
    col: usize,
    exempt_a: types.NodeId,
    exempt_b: types.NodeId,
) bool {
    for (layout.positions, 0..) |pos, id| {
        if (id == exempt_a or id == exempt_b) continue;
        const top = boxTop(layout, pos.row);
        const left = boxLeft(layout, pos.col);
        if (row >= top and row < top + layout.cell_h and
            col >= left and col < left + layout.cell_w)
        {
            return true;
        }
    }
    return false;
}

pub fn aStarPath(
    allocator: std.mem.Allocator,
    layout: *const types.Layout,
    canvas_rows_: usize,
    canvas_cols_: usize,
    from_id: types.NodeId,
    to_id: types.NodeId,
    start_row: usize,
    start_col: usize,
    start_dir: Dir4,
    goal_row: usize,
    goal_col: usize,
) RouteError!?std.ArrayListUnmanaged(SearchKey) {
    if (start_row >= canvas_rows_ or start_col >= canvas_cols_) return null;
    if (goal_row >= canvas_rows_ or goal_col >= canvas_cols_) return null;

    var open = std.PriorityQueue(AStarEntry, void, lessEntry).empty;
    defer open.deinit(allocator);

    var came_from = std.AutoHashMap(SearchKey, SearchKey).init(allocator);
    defer came_from.deinit();

    var g_score = std.AutoHashMap(SearchKey, u32).init(allocator);
    defer g_score.deinit();

    const start_key: SearchKey = .{
        .row = @intCast(start_row),
        .col = @intCast(start_col),
        .dir = start_dir,
    };
    try g_score.put(start_key, 0);
    try open.push(allocator, .{
        .key = start_key,
        .g = 0,
        .f = manhattan(start_row, start_col, goal_row, goal_col),
    });

    const neighbors = [_]struct { dr: i32, dc: i32, dir: Dir4 }{
        .{ .dr = -1, .dc = 0, .dir = .up },
        .{ .dr = 1, .dc = 0, .dir = .down },
        .{ .dr = 0, .dc = -1, .dir = .left },
        .{ .dr = 0, .dc = 1, .dir = .right },
    };

    while (open.pop()) |current| {
        const recorded = g_score.get(current.key) orelse std.math.maxInt(u32);
        if (recorded < current.g) continue;

        if (current.key.row == goal_row and current.key.col == goal_col) {
            return try reconstructPath(allocator, came_from, current.key);
        }

        for (neighbors) |n| {
            const new_row_i = @as(i32, @intCast(current.key.row)) + n.dr;
            const new_col_i = @as(i32, @intCast(current.key.col)) + n.dc;
            if (new_row_i < 0 or new_col_i < 0) continue;
            const new_row: u32 = @intCast(new_row_i);
            const new_col: u32 = @intCast(new_col_i);
            if (new_row >= canvas_rows_ or new_col >= canvas_cols_) continue;

            const at_goal = new_row == goal_row and new_col == goal_col;
            const at_start = new_row == start_row and new_col == start_col;
            if (!at_goal and !at_start and isBoxInterior(layout, new_row, new_col, from_id, to_id)) continue;
            if (at_goal and n.dir != start_dir) continue;

            const turn_penalty: u32 = if (n.dir != current.key.dir) 2 else 0;
            const tentative_g = current.g + 1 + turn_penalty;

            const neighbor_key: SearchKey = .{ .row = new_row, .col = new_col, .dir = n.dir };
            const existing_g = g_score.get(neighbor_key) orelse std.math.maxInt(u32);
            if (tentative_g >= existing_g) continue;

            try g_score.put(neighbor_key, tentative_g);
            try came_from.put(neighbor_key, current.key);
            const h = manhattan(new_row, new_col, goal_row, goal_col);
            try open.push(allocator, .{ .key = neighbor_key, .g = tentative_g, .f = tentative_g + h });
        }
    }

    return null;
}

fn reconstructPath(
    allocator: std.mem.Allocator,
    came_from: std.AutoHashMap(SearchKey, SearchKey),
    end: SearchKey,
) !std.ArrayListUnmanaged(SearchKey) {
    var path: std.ArrayListUnmanaged(SearchKey) = .empty;
    errdefer path.deinit(allocator);

    var cur = end;
    try path.append(allocator, cur);
    while (came_from.get(cur)) |parent| {
        try path.append(allocator, parent);
        cur = parent;
    }
    std.mem.reverse(SearchKey, path.items);
    return path;
}

fn drawAStarPath(
    canvas: *canvas_mod.Canvas,
    path: []const SearchKey,
    glyphs: *const canvas_mod.GlyphSet,
    initial_dir: Dir4,
    edge_style: types.EdgeStyle,
) void {
    if (path.len == 0) return;

    const start = path[0];
    canvas.setGlyph(start.row, start.col, exitTeeFor(initial_dir, glyphs));

    var i: usize = 1;
    while (i + 1 < path.len) : (i += 1) {
        const incoming = path[i].dir;
        const outgoing = path[i + 1].dir;
        const glyph = glyphForStep(incoming, outgoing, glyphs, edge_style);
        canvas.setGlyph(path[i].row, path[i].col, glyph);
    }

    const goal = path[path.len - 1];
    canvas.setGlyph(goal.row, goal.col, endGlyphFor(edge_style, goal.dir, glyphs));
}

fn endGlyphFor(style: types.EdgeStyle, dir: Dir4, glyphs: *const canvas_mod.GlyphSet) u21 {
    return switch (style) {
        .arrow, .dotted, .thick => arrowFor(dir, glyphs),
        .line, .thick_line => switch (dir) {
            .up, .down => glyphs.v_line,
            .left, .right => glyphs.h_line,
        },
        .dotted_line => switch (dir) {
            .up, .down => glyphs.v_line_dashed,
            .left, .right => glyphs.h_line_dashed,
        },
    };
}

fn exitTeeFor(dir: Dir4, glyphs: *const canvas_mod.GlyphSet) u21 {
    return switch (dir) {
        .down => glyphs.tee_t,
        .up => glyphs.tee_b,
        .right => glyphs.tee_l,
        .left => glyphs.tee_r,
    };
}

fn arrowFor(dir: Dir4, glyphs: *const canvas_mod.GlyphSet) u21 {
    return switch (dir) {
        .down => glyphs.arrow_down,
        .up => glyphs.arrow_up,
        .right => glyphs.arrow_right,
        .left => glyphs.arrow_left,
    };
}

pub fn paintSourceArrowHead(
    canvas: *canvas_mod.Canvas,
    direction: types.Direction,
    src_top: usize,
    src_left: usize,
    src_cx: usize,
    src_cy: usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    switch (direction) {
        .top_down => {
            if (src_top == 0) return;
            canvas.setGlyph(src_top - 1, src_cx, glyphs.arrow_up);
        },
        .left_right => {
            if (src_left == 0) return;
            canvas.setGlyph(src_cy, src_left - 1, glyphs.arrow_left);
        },
        else => unreachable,
    }
}

fn glyphForStep(incoming: Dir4, outgoing: Dir4, glyphs: *const canvas_mod.GlyphSet, edge_style: types.EdgeStyle) u21 {
    const dashed = edge_style == .dotted or edge_style == .dotted_line;
    const h_line = if (dashed) glyphs.h_line_dashed else glyphs.h_line;
    const v_line = if (dashed) glyphs.v_line_dashed else glyphs.v_line;
    if (incoming == outgoing) {
        return switch (incoming) {
            .up, .down => v_line,
            .left, .right => h_line,
        };
    }
    return switch (incoming) {
        .down => switch (outgoing) {
            .right => glyphs.corner_bl,
            .left => glyphs.corner_br,
            else => v_line,
        },
        .up => switch (outgoing) {
            .right => glyphs.corner_tl,
            .left => glyphs.corner_tr,
            else => v_line,
        },
        .right => switch (outgoing) {
            .up => glyphs.corner_br,
            .down => glyphs.corner_tr,
            else => h_line,
        },
        .left => switch (outgoing) {
            .up => glyphs.corner_bl,
            .down => glyphs.corner_tl,
            else => h_line,
        },
    };
}

fn placeEdgeLabelOnPath(
    canvas: *canvas_mod.Canvas,
    label: []const u8,
    path: []const SearchKey,
    ambiguous: width_mod.AmbiguousWidth,
) void {
    const label_w = width_mod.displayWidth(label, ambiguous);
    if (label_w == 0 or path.len < 2) return;

    var best_start: usize = 0;
    var best_len: usize = 1;
    var cur_start: usize = 0;
    var cur_len: usize = 1;
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i].dir == path[i - 1].dir) {
            cur_len += 1;
        } else {
            if (cur_len > best_len) {
                best_len = cur_len;
                best_start = cur_start;
            }
            cur_start = i - 1;
            cur_len = 2;
        }
    }
    if (cur_len > best_len) {
        best_len = cur_len;
        best_start = cur_start;
    }

    const mid_idx = best_start + best_len / 2;
    if (mid_idx >= path.len) return;
    const mid = path[mid_idx];

    const is_horizontal = mid.dir == .left or mid.dir == .right;
    if (is_horizontal) {
        if (mid.row == 0) return;
        const half = label_w / 2;
        const col = if (mid.col > half) mid.col - half else 0;
        if (col + label_w <= canvas.cols) {
            canvas.drawLabel(mid.row - 1, col, label, ambiguous);
        }
        return;
    }

    const col_right = mid.col + 2;
    if (col_right + label_w <= canvas.cols) {
        canvas.drawLabel(mid.row, col_right, label, ambiguous);
        return;
    }
    const half = label_w / 2;
    const col = if (mid.col > half) mid.col - half else 0;
    if (col + label_w <= canvas.cols) {
        canvas.drawLabel(mid.row, col, label, ambiguous);
    }
}

fn routeFallback(
    canvas: *canvas_mod.Canvas,
    layout: *const types.Layout,
    edge: types.Edge,
    direction: types.Direction,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
    edge_style: types.EdgeStyle,
) RouteError!void {
    switch (direction) {
        .top_down => try routeVertical(canvas, layout, edge, glyphs, ambiguous, .down, edge_style),
        .left_right => try routeHorizontal(canvas, layout, edge, glyphs, ambiguous, .right, edge_style),
        else => unreachable,
    }
}

const VerticalFlow = enum { down, up };
const HorizontalFlow = enum { right, left };

fn routeVertical(
    canvas: *canvas_mod.Canvas,
    layout: *const types.Layout,
    edge: types.Edge,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
    flow: VerticalFlow,
    edge_style: types.EdgeStyle,
) RouteError!void {
    const src_pos = layout.positions[edge.from];
    const tgt_pos = layout.positions[edge.to];

    const src_top = boxTop(layout, src_pos.row);
    const tgt_top = boxTop(layout, tgt_pos.row);
    const src_left = boxLeft(layout, src_pos.col);
    const tgt_left = boxLeft(layout, tgt_pos.col);

    const src_center = src_left + layout.cell_w / 2;
    const tgt_center = tgt_left + layout.cell_w / 2;

    const src_edge_row = switch (flow) {
        .down => src_top + layout.cell_h - 1,
        .up => src_top,
    };
    const tgt_edge_row = switch (flow) {
        .down => tgt_top,
        .up => tgt_top + layout.cell_h - 1,
    };

    const forward = switch (flow) {
        .down => tgt_edge_row > src_edge_row,
        .up => tgt_edge_row < src_edge_row,
    };
    if (!forward) return;

    const exit_tee = switch (flow) {
        .down => glyphs.tee_t,
        .up => glyphs.tee_b,
    };
    const end_dir: Dir4 = switch (flow) {
        .down => .down,
        .up => .up,
    };
    const arrow = endGlyphFor(edge_style, end_dir, glyphs);

    canvas.setGlyph(src_edge_row, src_center, exit_tee);

    const bend_row = switch (flow) {
        .down => tgt_edge_row - 1,
        .up => tgt_edge_row + 1,
    };

    if (src_center == tgt_center) {
        drawVerticalShaft(canvas, src_center, src_edge_row, bend_row, glyphs, flow);
        canvas.setGlyph(bend_row, tgt_center, arrow);
    } else {
        const shaft_end: usize = switch (flow) {
            .down => if (bend_row > 0) bend_row - 1 else bend_row,
            .up => bend_row + 1,
        };
        drawVerticalShaft(canvas, src_center, src_edge_row, shaft_end, glyphs, flow);

        const corner_at_src = switch (flow) {
            .down => if (tgt_center > src_center) glyphs.corner_bl else glyphs.corner_br,
            .up => if (tgt_center > src_center) glyphs.corner_tl else glyphs.corner_tr,
        };
        canvas.setGlyph(bend_row, src_center, corner_at_src);

        drawHorizontalRun(canvas, bend_row, src_center, tgt_center, glyphs);
        canvas.setGlyph(bend_row, tgt_center, arrow);
    }

    if (edge.label) |label| {
        placeEdgeLabel(canvas, label, bend_row, src_center, tgt_center, ambiguous);
    }
}

fn routeHorizontal(
    canvas: *canvas_mod.Canvas,
    layout: *const types.Layout,
    edge: types.Edge,
    glyphs: *const canvas_mod.GlyphSet,
    ambiguous: width_mod.AmbiguousWidth,
    flow: HorizontalFlow,
    edge_style: types.EdgeStyle,
) RouteError!void {
    const src_pos = layout.positions[edge.from];
    const tgt_pos = layout.positions[edge.to];

    const src_top = boxTop(layout, src_pos.row);
    const tgt_top = boxTop(layout, tgt_pos.row);
    const src_left = boxLeft(layout, src_pos.col);
    const tgt_left = boxLeft(layout, tgt_pos.col);

    const src_center_row = src_top + layout.cell_h / 2;
    const tgt_center_row = tgt_top + layout.cell_h / 2;

    const src_edge_col = switch (flow) {
        .right => src_left + layout.cell_w - 1,
        .left => src_left,
    };
    const tgt_edge_col = switch (flow) {
        .right => tgt_left,
        .left => tgt_left + layout.cell_w - 1,
    };

    const forward = switch (flow) {
        .right => tgt_edge_col > src_edge_col,
        .left => tgt_edge_col < src_edge_col,
    };
    if (!forward) return;

    const exit_tee = switch (flow) {
        .right => glyphs.tee_l,
        .left => glyphs.tee_r,
    };
    const end_dir: Dir4 = switch (flow) {
        .right => .right,
        .left => .left,
    };
    const arrow = endGlyphFor(edge_style, end_dir, glyphs);

    canvas.setGlyph(src_center_row, src_edge_col, exit_tee);

    const bend_col = switch (flow) {
        .right => tgt_edge_col - 1,
        .left => tgt_edge_col + 1,
    };

    if (src_center_row == tgt_center_row) {
        drawHorizontalShaft(canvas, src_center_row, src_edge_col, bend_col, glyphs, flow);
        canvas.setGlyph(src_center_row, bend_col, arrow);
    } else {
        const shaft_end: usize = switch (flow) {
            .right => if (bend_col > 0) bend_col - 1 else bend_col,
            .left => bend_col + 1,
        };
        drawHorizontalShaft(canvas, src_center_row, src_edge_col, shaft_end, glyphs, flow);

        const corner_at_src = switch (flow) {
            .right => if (tgt_center_row > src_center_row) glyphs.corner_tr else glyphs.corner_br,
            .left => if (tgt_center_row > src_center_row) glyphs.corner_tl else glyphs.corner_bl,
        };
        canvas.setGlyph(src_center_row, bend_col, corner_at_src);

        drawVerticalRun(canvas, bend_col, src_center_row, tgt_center_row, glyphs);
        canvas.setGlyph(tgt_center_row, bend_col, arrow);
    }

    if (edge.label) |label| {
        placeEdgeLabelHorizontal(canvas, label, src_center_row, tgt_center_row, bend_col, ambiguous);
    }
}

fn drawVerticalShaft(
    canvas: *canvas_mod.Canvas,
    col: usize,
    start_exclusive: usize,
    end_inclusive: usize,
    glyphs: *const canvas_mod.GlyphSet,
    flow: VerticalFlow,
) void {
    switch (flow) {
        .down => {
            var r = start_exclusive + 1;
            while (r <= end_inclusive) : (r += 1) {
                canvas.setGlyph(r, col, glyphs.v_line);
            }
        },
        .up => {
            if (start_exclusive == 0) return;
            var r = start_exclusive - 1;
            while (r >= end_inclusive) {
                canvas.setGlyph(r, col, glyphs.v_line);
                if (r == 0) break;
                r -= 1;
            }
        },
    }
}

fn drawHorizontalShaft(
    canvas: *canvas_mod.Canvas,
    row: usize,
    start_exclusive: usize,
    end_inclusive: usize,
    glyphs: *const canvas_mod.GlyphSet,
    flow: HorizontalFlow,
) void {
    switch (flow) {
        .right => {
            var c = start_exclusive + 1;
            while (c <= end_inclusive) : (c += 1) {
                canvas.setGlyph(row, c, glyphs.h_line);
            }
        },
        .left => {
            if (start_exclusive == 0) return;
            var c = start_exclusive - 1;
            while (c >= end_inclusive) {
                canvas.setGlyph(row, c, glyphs.h_line);
                if (c == 0) break;
                c -= 1;
            }
        },
    }
}

fn drawHorizontalRun(canvas: *canvas_mod.Canvas, row: usize, from_col: usize, to_col: usize, glyphs: *const canvas_mod.GlyphSet) void {
    const lo = @min(from_col, to_col);
    const hi = @max(from_col, to_col);
    var c = lo + 1;
    while (c < hi) : (c += 1) {
        canvas.setGlyph(row, c, glyphs.h_line);
    }
}

fn drawVerticalRun(canvas: *canvas_mod.Canvas, col: usize, from_row: usize, to_row: usize, glyphs: *const canvas_mod.GlyphSet) void {
    const lo = @min(from_row, to_row);
    const hi = @max(from_row, to_row);
    var r = lo + 1;
    while (r < hi) : (r += 1) {
        canvas.setGlyph(r, col, glyphs.v_line);
    }
}

fn placeEdgeLabel(
    canvas: *canvas_mod.Canvas,
    label: []const u8,
    bend_row: usize,
    src_center: usize,
    tgt_center: usize,
    ambiguous: width_mod.AmbiguousWidth,
) void {
    const label_w = width_mod.displayWidth(label, ambiguous);
    if (label_w == 0) return;

    const label_row = if (bend_row == 0) 0 else bend_row - 1;
    if (label_row >= canvas.rows) return;

    if (src_center == tgt_center) {
        const col_right = src_center + 2;
        if (col_right + label_w <= canvas.cols) {
            canvas.drawLabel(label_row, col_right, label, ambiguous);
            return;
        }
        const half = label_w / 2;
        const col = if (src_center > half) src_center - half else 0;
        if (col + label_w <= canvas.cols) {
            canvas.drawLabel(label_row, col, label, ambiguous);
        }
        return;
    }

    const mid = (src_center + tgt_center) / 2;
    const half = label_w / 2;
    const col = if (mid > half) mid - half else 0;
    if (col + label_w <= canvas.cols) {
        canvas.drawLabel(label_row, col, label, ambiguous);
    }
}

fn placeEdgeLabelHorizontal(
    canvas: *canvas_mod.Canvas,
    label: []const u8,
    src_row: usize,
    tgt_row: usize,
    bend_col: usize,
    ambiguous: width_mod.AmbiguousWidth,
) void {
    const label_w = width_mod.displayWidth(label, ambiguous);
    if (label_w == 0) return;

    const label_row = if (src_row == tgt_row)
        if (src_row == 0) 0 else src_row - 1
    else blk: {
        const mid_row = (src_row + tgt_row) / 2;
        break :blk if (mid_row == 0) 0 else mid_row - 1;
    };
    const label_col = if (bend_col > label_w + 1) bend_col - label_w - 1 else 0;

    if (label_row < canvas.rows and label_col + label_w <= canvas.cols) {
        canvas.drawLabel(label_row, label_col, label, ambiguous);
    }
}

const Connectivity = struct { u: bool, d: bool, l: bool, r: bool };

fn connectivity(cp: u21, glyphs: *const canvas_mod.GlyphSet) Connectivity {
    if (cp == glyphs.h_line) return .{ .u = false, .d = false, .l = true, .r = true };
    if (cp == glyphs.v_line) return .{ .u = true, .d = true, .l = false, .r = false };
    if (cp == glyphs.corner_tl) return .{ .u = false, .d = true, .l = false, .r = true };
    if (cp == glyphs.corner_tr) return .{ .u = false, .d = true, .l = true, .r = false };
    if (cp == glyphs.corner_bl) return .{ .u = true, .d = false, .l = false, .r = true };
    if (cp == glyphs.corner_br) return .{ .u = true, .d = false, .l = true, .r = false };
    if (cp == glyphs.tee_l) return .{ .u = true, .d = true, .l = false, .r = true };
    if (cp == glyphs.tee_r) return .{ .u = true, .d = true, .l = true, .r = false };
    if (cp == glyphs.tee_t) return .{ .u = false, .d = true, .l = true, .r = true };
    if (cp == glyphs.tee_b) return .{ .u = true, .d = false, .l = true, .r = true };
    if (cp == glyphs.cross) return .{ .u = true, .d = true, .l = true, .r = true };
    if (cp == glyphs.arrow_down) return .{ .u = true, .d = false, .l = false, .r = false };
    if (cp == glyphs.arrow_up) return .{ .u = false, .d = true, .l = false, .r = false };
    if (cp == glyphs.arrow_right) return .{ .u = false, .d = false, .l = true, .r = false };
    if (cp == glyphs.arrow_left) return .{ .u = false, .d = false, .l = false, .r = true };
    return .{ .u = false, .d = false, .l = false, .r = false };
}

fn isArrowHead(cp: u21, glyphs: *const canvas_mod.GlyphSet) bool {
    return cp == glyphs.arrow_up or cp == glyphs.arrow_down or cp == glyphs.arrow_left or cp == glyphs.arrow_right;
}

fn glyphForConnectivity(u: bool, d: bool, l: bool, r: bool, glyphs: *const canvas_mod.GlyphSet) u21 {
    const mask: u4 = (@as(u4, @intFromBool(u)) << 0) | (@as(u4, @intFromBool(d)) << 1) | (@as(u4, @intFromBool(l)) << 2) | (@as(u4, @intFromBool(r)) << 3);
    return switch (mask) {
        0b0000 => ' ',
        0b0001, 0b0010, 0b0011 => glyphs.v_line,
        0b0100, 0b1000, 0b1100 => glyphs.h_line,
        0b0101 => glyphs.corner_br,
        0b0110 => glyphs.corner_tr,
        0b0111 => glyphs.tee_r,
        0b1001 => glyphs.corner_bl,
        0b1010 => glyphs.corner_tl,
        0b1011 => glyphs.tee_l,
        0b1101 => glyphs.tee_b,
        0b1110 => glyphs.tee_t,
        0b1111 => glyphs.cross,
    };
}

pub fn mergeJunctions(allocator: std.mem.Allocator, canvas: *canvas_mod.Canvas, glyphs: *const canvas_mod.GlyphSet) !void {
    const snapshot = try allocator.dupe(canvas_mod.Cell, canvas.cells);
    defer allocator.free(snapshot);

    for (canvas.cells, 0..) |*cell, i| {
        if (cell.kind != .glyph) continue;
        if (isArrowHead(cell.cp, glyphs)) continue;
        const own = connectivity(cell.cp, glyphs);
        if (!(own.u or own.d or own.l or own.r)) continue;

        const r = i / canvas.cols;
        const c = i % canvas.cols;

        const has_u = if (r > 0) connectivity(snapshot[(r - 1) * canvas.cols + c].cp, glyphs).d else false;
        const has_d = if (r + 1 < canvas.rows) connectivity(snapshot[(r + 1) * canvas.cols + c].cp, glyphs).u else false;
        const has_l = if (c > 0) connectivity(snapshot[r * canvas.cols + c - 1].cp, glyphs).r else false;
        const has_r = if (c + 1 < canvas.cols) connectivity(snapshot[r * canvas.cols + c + 1].cp, glyphs).l else false;

        cell.cp = glyphForConnectivity(
            own.u or has_u,
            own.d or has_d,
            own.l or has_l,
            own.r or has_r,
            glyphs,
        );
    }
}

test "canvas dimensions for single cell" {
    var layout: types.Layout = .{
        .allocator = std.testing.allocator,
        .positions = &.{},
        .truncated_labels = &.{},
        .truncation_buf = null,
        .rows = 1,
        .cols = 1,
        .cell_w = 6,
        .cell_h = 3,
    };
    try std.testing.expectEqual(@as(usize, 3), canvasRows(&layout));
    try std.testing.expectEqual(@as(usize, 6), canvasCols(&layout));
}

test "canvas dimensions include gutter between cells" {
    var layout: types.Layout = .{
        .allocator = std.testing.allocator,
        .positions = &.{},
        .truncated_labels = &.{},
        .truncation_buf = null,
        .rows = 2,
        .cols = 3,
        .cell_w = 6,
        .cell_h = 3,
    };
    try std.testing.expectEqual(@as(usize, 2 * 3 + 1 * gutter_h), canvasRows(&layout));
    try std.testing.expectEqual(@as(usize, 3 * 6 + 2 * gutter_w), canvasCols(&layout));
}

test "glyphForConnectivity maps four-way to cross" {
    const g = glyphForConnectivity(true, true, true, true, &canvas_mod.GlyphSet.unicode);
    try std.testing.expectEqual(@as(u21, '┼'), g);
}

test "glyphForConnectivity maps right+down to corner_tl" {
    const g = glyphForConnectivity(false, true, false, true, &canvas_mod.GlyphSet.unicode);
    try std.testing.expectEqual(@as(u21, '┌'), g);
}

test "glyphForConnectivity maps three-way down+left+right to tee_t" {
    const g = glyphForConnectivity(false, true, true, true, &canvas_mod.GlyphSet.unicode);
    try std.testing.expectEqual(@as(u21, '┬'), g);
}

test "mergeJunctions upgrades crossing lines to four-way cross" {
    const alloc = std.testing.allocator;
    var canvas = try canvas_mod.Canvas.init(alloc, 3, 3);
    defer canvas.deinit();

    canvas.setGlyph(1, 0, '─');
    canvas.setGlyph(1, 1, '─');
    canvas.setGlyph(1, 2, '─');
    canvas.setGlyph(0, 1, '│');
    canvas.setGlyph(2, 1, '│');

    try mergeJunctions(alloc, &canvas, &canvas_mod.GlyphSet.unicode);

    try std.testing.expectEqual(@as(u21, '┼'), canvas.at(1, 1).cp);
}

test "mergeJunctions does not touch non-line glyphs like arrows" {
    const alloc = std.testing.allocator;
    var canvas = try canvas_mod.Canvas.init(alloc, 3, 3);
    defer canvas.deinit();

    canvas.setGlyph(0, 1, '│');
    canvas.setGlyph(1, 1, '▼');

    try mergeJunctions(alloc, &canvas, &canvas_mod.GlyphSet.unicode);

    try std.testing.expectEqual(@as(u21, '▼'), canvas.at(1, 1).cp);
}

test "aStarPath returns a straight path when unobstructed" {
    const alloc = std.testing.allocator;
    var layout: types.Layout = .{
        .allocator = alloc,
        .positions = &.{},
        .truncated_labels = &.{},
        .truncation_buf = null,
        .rows = 1,
        .cols = 1,
        .cell_w = 1,
        .cell_h = 1,
    };

    var result = (try aStarPath(alloc, &layout, 5, 5, 0, 0, 0, 0, .right, 0, 4)) orelse return error.TestUnexpectedNull;
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 5), result.items.len);
    for (result.items, 0..) |node, i| {
        try std.testing.expectEqual(@as(u32, 0), node.row);
        try std.testing.expectEqual(@as(u32, @intCast(i)), node.col);
    }
}

test "aStarPath prefers fewer turns on equal-length alternatives" {
    const alloc = std.testing.allocator;
    var layout: types.Layout = .{
        .allocator = alloc,
        .positions = &.{},
        .truncated_labels = &.{},
        .truncation_buf = null,
        .rows = 1,
        .cols = 1,
        .cell_w = 1,
        .cell_h = 1,
    };

    var result = (try aStarPath(alloc, &layout, 5, 5, 0, 0, 0, 0, .right, 2, 2)) orelse return error.TestUnexpectedNull;
    defer result.deinit(alloc);

    var turns: usize = 0;
    var i: usize = 1;
    while (i < result.items.len) : (i += 1) {
        if (result.items[i].dir != result.items[i - 1].dir) turns += 1;
    }
    try std.testing.expect(turns <= 2);
}

test "aStarPath routes around a blocking node" {
    const alloc = std.testing.allocator;
    var positions = [_]types.GridPos{
        .{ .row = 0, .col = 0 },
        .{ .row = 0, .col = 1 },
        .{ .row = 0, .col = 2 },
    };
    var layout: types.Layout = .{
        .allocator = alloc,
        .positions = positions[0..],
        .truncated_labels = &.{},
        .truncation_buf = null,
        .rows = 1,
        .cols = 3,
        .cell_w = 5,
        .cell_h = 3,
    };

    var result = (try aStarPath(alloc, &layout, 10, canvasCols(&layout), 0, 2, 1, 4, .right, 1, 16)) orelse return error.TestUnexpectedNull;
    defer result.deinit(alloc);

    for (result.items) |step| {
        const r: usize = step.row;
        const c: usize = step.col;
        if (r <= 2 and c >= 7 and c <= 11) {
            return error.TestExpectedRoute;
        }
    }
}

test "routeEdgeWithPorts fallback draws a visible edge when A* is blocked" {
    const alloc = std.testing.allocator;

    var positions = [_]types.GridPos{
        .{ .row = 0, .col = 0 },
        .{ .row = 1, .col = 0 },
        .{ .row = 2, .col = 0 },
    };
    var layout: types.Layout = .{
        .allocator = alloc,
        .positions = positions[0..],
        .truncated_labels = &.{},
        .truncation_buf = null,
        .rows = 3,
        .cols = 1,
        .cell_w = 1,
        .cell_h = 3,
    };

    const canvas_rows = canvasRows(&layout);
    const canvas_cols = canvasCols(&layout);
    var canvas = try canvas_mod.Canvas.init(alloc, canvas_rows, canvas_cols);
    defer canvas.deinit();

    const bottom_center_row = boxTop(&layout, 2);
    const top_center_row = boxTop(&layout, 0) + layout.cell_h - 1;
    try std.testing.expectEqual(
        @as(?std.ArrayListUnmanaged(SearchKey), null),
        try aStarPath(alloc, &layout, canvas_rows, canvas_cols, 2, 0, bottom_center_row, 0, .up, top_center_row, 0),
    );

    _ = try routeEdgeWithPorts(
        alloc,
        &canvas,
        &layout,
        2,
        0,
        bottom_center_row,
        0,
        .up,
        top_center_row,
        0,
        null,
        .arrow,
        &canvas_mod.GlyphSet.unicode,
        .narrow,
    );

    const glyphs = canvas_mod.GlyphSet.unicode;
    try std.testing.expectEqual(@as(u21, glyphs.tee_b), canvas.at(bottom_center_row, 0).cp);
    try std.testing.expectEqual(@as(u21, glyphs.arrow_up), canvas.at(top_center_row, 0).cp);
    try std.testing.expectEqual(@as(u21, glyphs.v_line), canvas.at(bottom_center_row - 1, 0).cp);
}

test "routeEdgeWithPorts fallback bends horizontally when ports differ in column" {
    const alloc = std.testing.allocator;

    var positions = [_]types.GridPos{
        .{ .row = 0, .col = 0 },
        .{ .row = 1, .col = 0 },
        .{ .row = 2, .col = 0 },
    };
    var layout: types.Layout = .{
        .allocator = alloc,
        .positions = positions[0..],
        .truncated_labels = &.{},
        .truncation_buf = null,
        .rows = 3,
        .cols = 1,
        .cell_w = 5,
        .cell_h = 3,
    };

    const canvas_rows = canvasRows(&layout);
    const canvas_cols = canvasCols(&layout);
    var canvas = try canvas_mod.Canvas.init(alloc, canvas_rows, canvas_cols);
    defer canvas.deinit();

    const start_row = boxTop(&layout, 2);
    const top_row = boxTop(&layout, 0) + layout.cell_h - 1;

    _ = try routeEdgeWithPorts(
        alloc,
        &canvas,
        &layout,
        2,
        0,
        start_row,
        0,
        .up,
        top_row,
        canvas_cols - 1,
        null,
        .arrow,
        &canvas_mod.GlyphSet.unicode,
        .narrow,
    );

    const glyphs = canvas_mod.GlyphSet.unicode;
    try std.testing.expectEqual(@as(u21, glyphs.tee_b), canvas.at(start_row, 0).cp);
    try std.testing.expectEqual(@as(u21, glyphs.arrow_up), canvas.at(top_row, canvas_cols - 1).cp);

    var saw_horizontal = false;
    for (canvas.cells) |cell| {
        if (cell.cp == glyphs.h_line) {
            saw_horizontal = true;
            break;
        }
    }
    try std.testing.expect(saw_horizontal);
}
