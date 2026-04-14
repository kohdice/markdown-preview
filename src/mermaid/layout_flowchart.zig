const std = @import("std");
const types = @import("types.zig");
const width_mod = @import("../term/width.zig");

pub const LayoutError = error{
    OutOfMemory,
};

const label_cap: usize = 40;
const ellipsis = "\u{2026}";

pub fn computeLayout(
    allocator: std.mem.Allocator,
    graph: *const types.FlowGraph,
    ambiguous: width_mod.AmbiguousWidth,
) LayoutError!types.Layout {
    const n = graph.nodes.len;

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

    try assignLevels(allocator, graph, levels);

    var max_level: usize = 0;
    for (levels) |l| max_level = @max(max_level, l);

    const col_in_level = try allocator.alloc(usize, n);
    defer allocator.free(col_in_level);
    const level_counts = try allocator.alloc(usize, max_level + 1);
    defer allocator.free(level_counts);
    @memset(level_counts, 0);
    for (0..n) |i| {
        const l = levels[i];
        col_in_level[i] = level_counts[l];
        level_counts[l] += 1;
    }

    var max_cols_in_any_level: usize = 0;
    for (level_counts) |c| max_cols_in_any_level = @max(max_cols_in_any_level, c);

    const grid_rows: usize = if (graph.direction.isHorizontal()) max_cols_in_any_level else max_level + 1;
    const grid_cols: usize = if (graph.direction.isHorizontal()) max_level + 1 else max_cols_in_any_level;

    const positions = try allocator.alloc(types.GridPos, n);
    errdefer allocator.free(positions);

    for (0..n) |i| {
        positions[i] = gridPosFor(graph.direction, levels[i], col_in_level[i], max_level);
    }

    const truncated_labels = try allocator.alloc([]const u8, n);
    errdefer allocator.free(truncated_labels);

    var truncation_buf: ?[]u8 = null;
    errdefer if (truncation_buf) |buf| allocator.free(buf);

    var required_bytes: usize = 0;
    for (graph.nodes) |node| {
        if (width_mod.displayWidth(node.label, ambiguous) > label_cap) {
            required_bytes += node.label.len + ellipsis.len;
        }
    }
    if (required_bytes > 0) {
        truncation_buf = try allocator.alloc(u8, required_bytes);
    }

    var buf_pos: usize = 0;
    for (graph.nodes, 0..) |node, i| {
        if (width_mod.displayWidth(node.label, ambiguous) <= label_cap) {
            truncated_labels[i] = node.label;
        } else {
            const dest = truncation_buf.?[buf_pos..];
            const effective = truncateLabel(node.label, dest, ambiguous);
            truncated_labels[i] = effective;
            buf_pos += effective.len;
        }
    }

    var label_w: usize = 0;
    for (truncated_labels) |label| {
        label_w = @max(label_w, width_mod.displayWidth(label, ambiguous));
    }
    var cell_w: usize = label_w + 4;
    if (cell_w < 6) cell_w = 6;

    var any_diamond = false;
    for (graph.nodes) |node| {
        if (node.shape == .diamond) {
            any_diamond = true;
            break;
        }
    }
    const cell_h: usize = if (any_diamond) 5 else 3;

    return .{
        .allocator = allocator,
        .positions = positions,
        .truncated_labels = truncated_labels,
        .truncation_buf = truncation_buf,
        .rows = grid_rows,
        .cols = grid_cols,
        .cell_w = cell_w,
        .cell_h = cell_h,
    };
}

fn assignLevels(allocator: std.mem.Allocator, graph: *const types.FlowGraph, levels: []usize) LayoutError!void {
    const n = graph.nodes.len;

    const remaining = try allocator.alloc(u32, n);
    defer allocator.free(remaining);
    @memset(remaining, 0);
    for (graph.edges) |edge| remaining[edge.to] += 1;

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
        for (graph.edges) |edge| {
            if (edge.from != u) continue;
            const v = edge.to;
            const candidate = levels[u] + 1;
            if (candidate > levels[v]) levels[v] = candidate;
            if (remaining[v] > 0) {
                remaining[v] -= 1;
                if (remaining[v] == 0) try queue.append(allocator, v);
            }
        }
    }
}

fn gridPosFor(direction: types.Direction, level: usize, column: usize, max_level: usize) types.GridPos {
    return switch (direction) {
        .top_down => .{ .row = level, .col = column },
        .bottom_up => .{ .row = max_level - level, .col = column },
        .left_right => .{ .row = column, .col = level },
        .right_left => .{ .row = column, .col = max_level - level },
    };
}

fn truncateLabel(label: []const u8, dest: []u8, ambiguous: width_mod.AmbiguousWidth) []const u8 {
    const ellipsis_w = width_mod.displayWidth(ellipsis, ambiguous);
    const budget = if (label_cap > ellipsis_w) label_cap - ellipsis_w else 0;

    var kept_bytes: usize = 0;
    var view = std.unicode.Utf8View.init(label) catch {
        @memcpy(dest[0..ellipsis.len], ellipsis);
        return dest[0..ellipsis.len];
    };
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cp_slice| {
        const next_bytes = kept_bytes + cp_slice.len;
        const next_width = width_mod.displayWidth(label[0..next_bytes], ambiguous);
        if (next_width > budget) break;
        kept_bytes = next_bytes;
    }

    @memcpy(dest[0..kept_bytes], label[0..kept_bytes]);
    @memcpy(dest[kept_bytes .. kept_bytes + ellipsis.len], ellipsis);
    return dest[0 .. kept_bytes + ellipsis.len];
}

fn makeNode(id: types.NodeId, id_text: []const u8, label: []const u8, shape: types.NodeShape) types.Node {
    return .{ .id = id, .id_text = id_text, .label = label, .shape = shape };
}

fn makeEdge(from: types.NodeId, to: types.NodeId) types.Edge {
    return .{ .from = from, .to = to };
}

fn graphFor(allocator: std.mem.Allocator, direction: types.Direction, nodes: []const types.Node, edges: []const types.Edge) !types.FlowGraph {
    return .{
        .allocator = allocator,
        .direction = direction,
        .nodes = try allocator.dupe(types.Node, nodes),
        .edges = try allocator.dupe(types.Edge, edges),
    };
}

test "layout places single node at origin" {
    const alloc = std.testing.allocator;
    var graph = try graphFor(alloc, .top_down, &.{makeNode(0, "A", "A", .rect)}, &.{});
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 1), layout.positions.len);
    try std.testing.expectEqual(@as(usize, 0), layout.positions[0].row);
    try std.testing.expectEqual(@as(usize, 0), layout.positions[0].col);
    try std.testing.expectEqual(@as(usize, 1), layout.rows);
    try std.testing.expectEqual(@as(usize, 1), layout.cols);
}

test "layout TD assigns level as row" {
    const alloc = std.testing.allocator;
    const nodes = [_]types.Node{
        makeNode(0, "A", "A", .rect),
        makeNode(1, "B", "B", .rect),
        makeNode(2, "C", "C", .rect),
    };
    const edges = [_]types.Edge{ makeEdge(0, 1), makeEdge(1, 2) };
    var graph = try graphFor(alloc, .top_down, &nodes, &edges);
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 0), layout.positions[0].row);
    try std.testing.expectEqual(@as(usize, 1), layout.positions[1].row);
    try std.testing.expectEqual(@as(usize, 2), layout.positions[2].row);
    try std.testing.expectEqual(@as(usize, 3), layout.rows);
    try std.testing.expectEqual(@as(usize, 1), layout.cols);
}

test "layout LR assigns level as column" {
    const alloc = std.testing.allocator;
    const nodes = [_]types.Node{
        makeNode(0, "A", "A", .rect),
        makeNode(1, "B", "B", .rect),
        makeNode(2, "C", "C", .rect),
    };
    const edges = [_]types.Edge{ makeEdge(0, 1), makeEdge(1, 2) };
    var graph = try graphFor(alloc, .left_right, &nodes, &edges);
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 0), layout.positions[0].col);
    try std.testing.expectEqual(@as(usize, 1), layout.positions[1].col);
    try std.testing.expectEqual(@as(usize, 2), layout.positions[2].col);
    try std.testing.expectEqual(@as(usize, 1), layout.rows);
    try std.testing.expectEqual(@as(usize, 3), layout.cols);
}

test "layout BT flips rows relative to TD" {
    const alloc = std.testing.allocator;
    const nodes = [_]types.Node{
        makeNode(0, "A", "A", .rect),
        makeNode(1, "B", "B", .rect),
        makeNode(2, "C", "C", .rect),
    };
    const edges = [_]types.Edge{ makeEdge(0, 1), makeEdge(1, 2) };
    var graph = try graphFor(alloc, .bottom_up, &nodes, &edges);
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 2), layout.positions[0].row);
    try std.testing.expectEqual(@as(usize, 1), layout.positions[1].row);
    try std.testing.expectEqual(@as(usize, 0), layout.positions[2].row);
}

test "layout groups siblings in same level" {
    const alloc = std.testing.allocator;
    const nodes = [_]types.Node{
        makeNode(0, "A", "A", .rect),
        makeNode(1, "B", "B", .rect),
        makeNode(2, "C", "C", .rect),
    };
    const edges = [_]types.Edge{ makeEdge(0, 1), makeEdge(0, 2) };
    var graph = try graphFor(alloc, .top_down, &nodes, &edges);
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 0), layout.positions[0].row);
    try std.testing.expectEqual(@as(usize, 1), layout.positions[1].row);
    try std.testing.expectEqual(@as(usize, 1), layout.positions[2].row);
    try std.testing.expectEqual(@as(usize, 0), layout.positions[1].col);
    try std.testing.expectEqual(@as(usize, 1), layout.positions[2].col);
}

test "layout handles cycle without hanging and assigns every node a position" {
    const alloc = std.testing.allocator;
    const nodes = [_]types.Node{
        makeNode(0, "A", "A", .rect),
        makeNode(1, "B", "B", .rect),
        makeNode(2, "C", "C", .rect),
    };
    const edges = [_]types.Edge{ makeEdge(0, 1), makeEdge(1, 2), makeEdge(2, 0) };
    var graph = try graphFor(alloc, .top_down, &nodes, &edges);
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 3), layout.positions.len);
    for (layout.positions) |pos| {
        try std.testing.expect(pos.row < layout.rows);
        try std.testing.expect(pos.col < layout.cols);
    }
}

test "layout picks cell_h 5 when any node is a diamond" {
    const alloc = std.testing.allocator;
    var graph = try graphFor(alloc, .top_down, &.{
        makeNode(0, "A", "A", .rect),
        makeNode(1, "B", "B", .diamond),
    }, &.{makeEdge(0, 1)});
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 5), layout.cell_h);
}

test "layout picks cell_h 3 when no diamond is present" {
    const alloc = std.testing.allocator;
    var graph = try graphFor(alloc, .top_down, &.{
        makeNode(0, "A", "A", .rect),
        makeNode(1, "B", "B", .rect),
    }, &.{makeEdge(0, 1)});
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 3), layout.cell_h);
}

test "layout sizes cell_w from max label display width plus padding" {
    const alloc = std.testing.allocator;
    var graph = try graphFor(alloc, .top_down, &.{
        makeNode(0, "A", "Short", .rect),
        makeNode(1, "B", "A longer label", .rect),
    }, &.{});
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 14 + 4), layout.cell_w);
}

test "layout aliases node.label when display width is within cap" {
    const alloc = std.testing.allocator;
    var graph = try graphFor(alloc, .top_down, &.{
        makeNode(0, "A", "short", .rect),
    }, &.{});
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(graph.nodes[0].label.ptr, layout.truncated_labels[0].ptr);
    try std.testing.expectEqual(@as(?[]u8, null), layout.truncation_buf);
}

test "layout truncates labels exceeding 40 display columns with ellipsis" {
    const alloc = std.testing.allocator;
    const long_label = "0123456789012345678901234567890123456789XYZ";
    var graph = try graphFor(alloc, .top_down, &.{
        makeNode(0, "A", long_label, .rect),
    }, &.{});
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    const effective = layout.truncated_labels[0];
    try std.testing.expect(std.mem.endsWith(u8, effective, ellipsis));
    try std.testing.expect(width_mod.displayWidth(effective, .narrow) <= label_cap);
    try std.testing.expect(layout.truncation_buf != null);
}

test "layout truncation preserves UTF-8 codepoint boundaries" {
    const alloc = std.testing.allocator;
    const long_jp = "日本語日本語日本語日本語日本語日本語日本語日本語日本語";
    var graph = try graphFor(alloc, .top_down, &.{
        makeNode(0, "A", long_jp, .rect),
    }, &.{});
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    const effective = layout.truncated_labels[0];
    try std.testing.expect(std.unicode.utf8ValidateSlice(effective));
    try std.testing.expect(std.mem.endsWith(u8, effective, ellipsis));
    try std.testing.expect(width_mod.displayWidth(effective, .narrow) <= label_cap);
}

test "layout frees truncation buffer via deinit" {
    const alloc = std.testing.allocator;
    const long_label = "0123456789012345678901234567890123456789XYZABC";
    var graph = try graphFor(alloc, .top_down, &.{
        makeNode(0, "A", long_label, .rect),
        makeNode(1, "B", "B", .rect),
    }, &.{makeEdge(0, 1)});
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    try std.testing.expect(layout.truncation_buf != null);
    layout.deinit();
}

test "layout cell_w accommodates wide ambiguous-width labels" {
    const alloc = std.testing.allocator;
    const cjk_label = "日本語";
    var graph = try graphFor(alloc, .top_down, &.{
        makeNode(0, "A", cjk_label, .rect),
    }, &.{});
    defer graph.deinit();

    var wide_layout = try computeLayout(alloc, &graph, .wide);
    defer wide_layout.deinit();

    const label_w = width_mod.displayWidth(cjk_label, .wide);
    try std.testing.expect(wide_layout.cell_w >= label_w + 4);
}

test "layout cell_w differs between narrow and wide for EAW=A labels" {
    const alloc = std.testing.allocator;
    // Greek letters are East Asian Width "Ambiguous": 1 column narrow, 2 columns wide.
    const ambig_label = "αβγ";
    try std.testing.expectEqual(@as(usize, 3), width_mod.displayWidth(ambig_label, .narrow));
    try std.testing.expectEqual(@as(usize, 6), width_mod.displayWidth(ambig_label, .wide));

    var graph = try graphFor(alloc, .top_down, &.{
        makeNode(0, "A", ambig_label, .rect),
    }, &.{});
    defer graph.deinit();

    var narrow_layout = try computeLayout(alloc, &graph, .narrow);
    defer narrow_layout.deinit();
    var wide_layout = try computeLayout(alloc, &graph, .wide);
    defer wide_layout.deinit();

    try std.testing.expect(wide_layout.cell_w > narrow_layout.cell_w);
    try std.testing.expect(wide_layout.cell_w >= 6 + 4);
    try std.testing.expect(narrow_layout.cell_w >= 3 + 4);
}

test "layout truncation uses the same ambiguous_width mode as rendering" {
    const alloc = std.testing.allocator;
    const long_jp = "日本語日本語日本語日本語日本語日本語日本語日本語日本語";
    var graph = try graphFor(alloc, .top_down, &.{
        makeNode(0, "A", long_jp, .rect),
    }, &.{});
    defer graph.deinit();

    var wide_layout = try computeLayout(alloc, &graph, .wide);
    defer wide_layout.deinit();

    const effective = wide_layout.truncated_labels[0];
    try std.testing.expect(width_mod.displayWidth(effective, .wide) <= label_cap);
}

test "computeLayout returns empty layout for empty graph" {
    const alloc = std.testing.allocator;
    var graph = try graphFor(alloc, .top_down, &.{}, &.{});
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 0), layout.rows);
    try std.testing.expectEqual(@as(usize, 0), layout.cols);
    try std.testing.expectEqual(@as(usize, 0), layout.positions.len);
}
