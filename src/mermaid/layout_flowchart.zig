const std = @import("std");
const types = @import("types.zig");
const width_mod = @import("../term/width.zig");

pub const LayoutError = error{
    OutOfMemory,
};

const label_cap: usize = 40;
const ellipsis = "\u{2026}";
const cell_horizontal_padding: usize = 4;
const min_cell_width: usize = 6;
const regular_cell_height: usize = 3;
const diamond_cell_height: usize = 5;
const framed_subgraph_outer_padding: usize = 1;

/// Subgraph-aware layout: each subgraph group's internal edges determine
/// its members' local levels independently, so cross-boundary edges do not
/// affect intra-group ordering. Per-subgraph `direction` overrides swap the
/// layout axis for that group (e.g. LR inside a TD diagram arranges members
/// horizontally). Non-member nodes sort before subgraph members because
/// their path is empty.
pub fn computeLayout(
    allocator: std.mem.Allocator,
    graph: *const types.MermaidGraph,
    ambiguous: width_mod.AmbiguousWidth,
) LayoutError!types.Layout {
    const layout_dir = graph.direction.layoutDir();
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

    const paths = try computeNodePaths(allocator, graph);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }

    try reassignLocalLevels(allocator, graph, paths, levels);

    try composeVirtualNodeLevels(allocator, graph, paths, levels);

    var max_level: usize = 0;
    for (levels) |l| max_level = @max(max_level, l);

    const sorted_ids = try allocator.alloc(types.NodeId, n);
    defer allocator.free(sorted_ids);
    for (0..n) |i| sorted_ids[i] = @intCast(i);
    std.mem.sort(types.NodeId, sorted_ids, SortCtx{ .paths = paths, .levels = levels }, pathThenLevelLess);

    const sg_dirs = try computeSubgraphDirs(allocator, graph);
    defer allocator.free(sg_dirs);

    var group_starts: std.ArrayListUnmanaged(usize) = .empty;
    defer group_starts.deinit(allocator);
    var group_widths: std.ArrayListUnmanaged(usize) = .empty;
    defer group_widths.deinit(allocator);
    var group_dirs: std.ArrayListUnmanaged(types.Direction) = .empty;
    defer group_dirs.deinit(allocator);
    var group_min_levels: std.ArrayListUnmanaged(usize) = .empty;
    defer group_min_levels.deinit(allocator);
    const group_of = try allocator.alloc(usize, n);
    defer allocator.free(group_of);

    const level_counts = try allocator.alloc(usize, max_level + 1);
    defer allocator.free(level_counts);

    {
        var i: usize = 0;
        while (i < n) {
            const start = i;
            const first = sorted_ids[start];
            while (i < n and std.mem.eql(u32, paths[sorted_ids[i]], paths[first])) : (i += 1) {}

            const eff_dir = effectiveDirection(paths[first], sg_dirs, layout_dir);
            try group_dirs.append(allocator, eff_dir);

            var min_l: usize = std.math.maxInt(usize);
            @memset(level_counts, 0);
            for (sorted_ids[start..i]) |id| {
                level_counts[levels[id]] += 1;
                min_l = @min(min_l, levels[id]);
            }
            try group_min_levels.append(allocator, min_l);

            var width: usize = 0;
            if (eff_dir.isHorizontal() != layout_dir.isHorizontal()) {
                for (level_counts) |c| {
                    if (c > 0) width += 1;
                }
            } else {
                for (level_counts) |c| width = @max(width, c);
            }
            if (width == 0) width = 1;
            try group_widths.append(allocator, width);
            for (sorted_ids[start..i]) |id| group_of[id] = group_widths.items.len - 1;
        }
    }

    try group_starts.resize(allocator, group_widths.items.len);
    {
        var acc: usize = 0;
        for (group_widths.items, 0..) |w, idx| {
            group_starts.items[idx] = acc;
            acc += w;
        }
    }

    const local_idx_of = try allocator.alloc(usize, n);
    defer allocator.free(local_idx_of);
    const group_level_counts = try allocator.alloc(usize, (max_level + 1) * group_widths.items.len);
    defer allocator.free(group_level_counts);
    @memset(group_level_counts, 0);
    for (sorted_ids) |id| {
        const g = group_of[id];
        const cell = g * (max_level + 1) + levels[id];
        local_idx_of[id] = group_level_counts[cell];
        group_level_counts[cell] += 1;
    }

    const positions = try allocator.alloc(types.GridPos, n);
    errdefer allocator.free(positions);

    for (0..n) |i| {
        const g = group_of[i];
        const eff_dir = group_dirs.items[g];
        if (eff_dir.isHorizontal() != layout_dir.isHorizontal()) {
            const local_level = levels[i] - group_min_levels.items[g];
            const local_idx = local_idx_of[i];
            positions[i] = .{
                .row = group_min_levels.items[g] + local_idx,
                .col = group_starts.items[g] + local_level,
            };
        } else {
            const col = group_starts.items[g] + local_idx_of[i];
            positions[i] = gridPosFor(layout_dir, levels[i], col, max_level);
        }
    }

    var max_row: usize = 0;
    var max_col: usize = 0;
    for (positions) |pos| {
        max_row = @max(max_row, pos.row);
        max_col = @max(max_col, pos.col);
    }
    const grid_rows = max_row + 1;
    const grid_cols = max_col + 1;

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
    var cell_w: usize = label_w + cell_horizontal_padding;
    if (cell_w < min_cell_width) cell_w = min_cell_width;

    var any_diamond = false;
    for (graph.nodes) |node| {
        if (node.shape == .diamond) {
            any_diamond = true;
            break;
        }
    }
    const cell_h: usize = if (any_diamond) diamond_cell_height else regular_cell_height;

    const subgraph_frames = try computeSubgraphFrames(allocator, graph, positions, paths);
    errdefer allocator.free(subgraph_frames);

    var max_depth: usize = 0;
    for (subgraph_frames) |f| max_depth = @max(max_depth, f.depth);
    const outer_pad: usize = if (subgraph_frames.len > 0) max_depth + framed_subgraph_outer_padding else 0;

    return .{
        .allocator = allocator,
        .positions = positions,
        .truncated_labels = truncated_labels,
        .truncation_buf = truncation_buf,
        .rows = grid_rows,
        .cols = grid_cols,
        .cell_w = cell_w,
        .cell_h = cell_h,
        .subgraph_frames = subgraph_frames,
        .outer_pad = outer_pad,
    };
}

const BBox = struct { r_min: usize, r_max: usize, c_min: usize, c_max: usize };

fn computeSubgraphFrames(
    allocator: std.mem.Allocator,
    graph: *const types.MermaidGraph,
    positions: []const types.GridPos,
    paths: []const []const u32,
) LayoutError![]types.SubgraphFrame {
    var out: std.ArrayListUnmanaged(types.SubgraphFrame) = .empty;
    errdefer out.deinit(allocator);

    var counter: u32 = 0;
    for (graph.subgraphs) |*sg| {
        try appendFrame(allocator, &out, sg, positions, 0, paths, &counter);
    }

    return try out.toOwnedSlice(allocator);
}

fn appendFrame(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(types.SubgraphFrame),
    sg: *const types.Subgraph,
    positions: []const types.GridPos,
    depth: usize,
    paths: []const []const u32,
    counter: *u32,
) LayoutError!void {
    counter.* += 1;
    const my_id = counter.*;
    var bbox: ?BBox = null;
    collectNodeBounds(sg, positions, &bbox, paths, depth, my_id);

    if (bbox) |b| {
        try out.append(allocator, .{
            .row_start = b.r_min,
            .col_start = b.c_min,
            .row_end = b.r_max,
            .col_end = b.c_max,
            .depth = depth,
            .title = sg.title orelse (if (sg.id_text.len > 0) sg.id_text else null),
            .representative_node = sg.representative_node,
        });
    }

    for (sg.children) |*child| {
        try appendFrame(allocator, out, child, positions, depth + 1, paths, counter);
    }
}

fn collectNodeBounds(
    sg: *const types.Subgraph,
    positions: []const types.GridPos,
    bbox: *?BBox,
    paths: []const []const u32,
    depth: usize,
    sg_id: u32,
) void {
    for (sg.node_ids) |id| {
        const p = paths[id];
        if (p.len < depth + 1 or p[depth] != sg_id) continue;
        expandBBox(bbox, positions[id]);
    }
    for (sg.children) |*child| collectChildBounds(child, positions, bbox);
}

fn collectChildBounds(
    sg: *const types.Subgraph,
    positions: []const types.GridPos,
    bbox: *?BBox,
) void {
    for (sg.node_ids) |id| expandBBox(bbox, positions[id]);
    for (sg.children) |*child| collectChildBounds(child, positions, bbox);
}

fn expandBBox(bbox: *?BBox, pos: types.GridPos) void {
    if (bbox.*) |*b| {
        b.r_min = @min(b.r_min, pos.row);
        b.r_max = @max(b.r_max, pos.row);
        b.c_min = @min(b.c_min, pos.col);
        b.c_max = @max(b.c_max, pos.col);
    } else {
        bbox.* = .{
            .r_min = pos.row,
            .r_max = pos.row,
            .c_min = pos.col,
            .c_max = pos.col,
        };
    }
}

const SortCtx = struct {
    paths: []const []const u32,
    levels: []const usize,
};

fn pathThenLevelLess(ctx: SortCtx, a: types.NodeId, b: types.NodeId) bool {
    const pa = ctx.paths[a];
    const pb = ctx.paths[b];
    const min_len = @min(pa.len, pb.len);
    var i: usize = 0;
    while (i < min_len) : (i += 1) {
        if (pa[i] != pb[i]) return pa[i] < pb[i];
    }
    if (pa.len != pb.len) return pa.len < pb.len;
    if (ctx.levels[a] != ctx.levels[b]) return ctx.levels[a] < ctx.levels[b];
    return a < b;
}

/// Returns an allocator-owned array (one entry per node) whose element is the
/// subgraph-ownership path: the sequence of subgraph indices from outermost
/// to innermost, or an empty slice for nodes that are not inside any
/// subgraph. Each path is independently allocated; callers free both the
/// outer array and each inner slice.
fn computeNodePaths(
    allocator: std.mem.Allocator,
    graph: *const types.MermaidGraph,
) LayoutError![][]const u32 {
    const paths = try allocator.alloc([]const u32, graph.nodes.len);
    errdefer allocator.free(paths);
    for (paths) |*p| p.* = &.{};

    var stack: std.ArrayListUnmanaged(u32) = .empty;
    defer stack.deinit(allocator);
    var counter: u32 = 0;
    try walkSubgraphsForPaths(allocator, graph.subgraphs, &stack, &counter, paths);
    return paths;
}

fn walkSubgraphsForPaths(
    allocator: std.mem.Allocator,
    subs: []const types.Subgraph,
    stack: *std.ArrayListUnmanaged(u32),
    counter: *u32,
    paths: [][]const u32,
) LayoutError!void {
    for (subs) |*sg| {
        counter.* += 1;
        try stack.append(allocator, counter.*);
        for (sg.node_ids) |id| {
            if (paths[id].len == 0) {
                paths[id] = try allocator.dupe(u32, stack.items);
            }
        }
        try walkSubgraphsForPaths(allocator, sg.children, stack, counter, paths);
        _ = stack.pop();
    }
}

/// For each subgraph group (identified by non-empty path), re-compute levels
/// using only edges whose BOTH endpoints are members of that group. The base
/// row offset is the minimum global level across the group's members.
fn reassignLocalLevels(
    allocator: std.mem.Allocator,
    graph: *const types.MermaidGraph,
    paths: []const []const u32,
    levels: []usize,
) LayoutError!void {
    const n = graph.nodes.len;
    if (n == 0) return;

    var sorted: std.ArrayListUnmanaged(types.NodeId) = .empty;
    defer sorted.deinit(allocator);
    try sorted.resize(allocator, n);
    for (0..n) |i| sorted.items[i] = @intCast(i);
    std.mem.sort(types.NodeId, sorted.items, SortCtx{ .paths = paths, .levels = levels }, pathThenLevelLess);

    var i: usize = 0;
    while (i < n) {
        const start = i;
        const first = sorted.items[start];
        if (paths[first].len == 0) {
            while (i < n and paths[sorted.items[i]].len == 0) : (i += 1) {}
            continue;
        }
        while (i < n and std.mem.eql(u32, paths[sorted.items[i]], paths[first])) : (i += 1) {}
        const members = sorted.items[start..i];
        try reassignGroupLevels(allocator, members, graph.edges, levels);
    }
}

fn reassignGroupLevels(
    allocator: std.mem.Allocator,
    members: []const types.NodeId,
    edges: []const types.Edge,
    levels: []usize,
) LayoutError!void {
    const m = members.len;
    if (m <= 1) return;

    var base: usize = std.math.maxInt(usize);
    for (members) |id| base = @min(base, levels[id]);

    const remaining = try allocator.alloc(u32, m);
    defer allocator.free(remaining);
    @memset(remaining, 0);
    const local_levels = try allocator.alloc(usize, m);
    defer allocator.free(local_levels);
    @memset(local_levels, 0);

    for (edges) |edge| {
        const to_local = findLocalIdx(members, edge.to) orelse continue;
        if (findLocalIdx(members, edge.from) == null) continue;
        remaining[to_local] += 1;
    }

    var queue: std.ArrayListUnmanaged(usize) = .empty;
    defer queue.deinit(allocator);
    for (0..m) |j| {
        if (remaining[j] == 0) try queue.append(allocator, j);
    }
    if (queue.items.len == 0) {
        try queue.append(allocator, 0);
        remaining[0] = 0;
    }

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const u = queue.items[qi];
        const u_id = members[u];
        for (edges) |edge| {
            if (edge.from != u_id) continue;
            const v = findLocalIdx(members, edge.to) orelse continue;
            const candidate = local_levels[u] + 1;
            if (candidate > local_levels[v]) local_levels[v] = candidate;
            if (remaining[v] > 0) {
                remaining[v] -= 1;
                if (remaining[v] == 0) try queue.append(allocator, v);
            }
        }
    }

    for (members, 0..) |id, j| {
        levels[id] = base + local_levels[j];
    }
}

fn findLocalIdx(members: []const types.NodeId, id: types.NodeId) ?usize {
    for (members, 0..) |mid, i| {
        if (mid == id) return i;
    }
    return null;
}

/// Builds a "virtual graph" where each subgraph group becomes one node whose
/// size equals its internal level span, then re-runs level assignment with
/// size-aware propagation (`candidate = levels[u] + sizes[u]`). This ensures
/// nodes after a subgraph are placed past the subgraph's occupied rows.
fn composeVirtualNodeLevels(
    allocator: std.mem.Allocator,
    graph: *const types.MermaidGraph,
    paths: []const []const u32,
    levels: []usize,
) LayoutError!void {
    const n = graph.nodes.len;
    if (n == 0) return;

    const GroupInfo = struct { base: usize, span: usize, path: []const u32 };
    var groups: std.ArrayListUnmanaged(GroupInfo) = .empty;
    defer groups.deinit(allocator);

    const virtual_id = try allocator.alloc(usize, n);
    defer allocator.free(virtual_id);
    for (0..n) |i| virtual_id[i] = i;

    const sorted = try allocator.alloc(types.NodeId, n);
    defer allocator.free(sorted);
    for (0..n) |i| sorted[i] = @intCast(i);
    std.mem.sort(types.NodeId, sorted, SortCtx{ .paths = paths, .levels = levels }, pathThenLevelLess);

    {
        var i: usize = 0;
        while (i < n) {
            const start = i;
            const first = sorted[start];
            while (i < n and std.mem.eql(u32, paths[sorted[i]], paths[first])) : (i += 1) {}
            if (paths[first].len == 0) continue;
            var base: usize = std.math.maxInt(usize);
            var top: usize = 0;
            for (sorted[start..i]) |id| {
                base = @min(base, levels[id]);
                top = @max(top, levels[id]);
            }
            const vid = n + groups.items.len;
            try groups.append(allocator, .{
                .base = base,
                .span = top - base + 1,
                .path = paths[first],
            });
            for (sorted[start..i]) |id| virtual_id[id] = vid;
        }
    }

    if (groups.items.len == 0) return;

    const vn = n + groups.items.len;
    const v_levels = try allocator.alloc(usize, vn);
    defer allocator.free(v_levels);
    @memset(v_levels, 0);
    const v_sizes = try allocator.alloc(usize, vn);
    defer allocator.free(v_sizes);
    for (0..n) |i| v_sizes[i] = 1;
    for (groups.items, 0..) |g, gi| {
        v_sizes[n + gi] = g.span;
    }

    const remaining = try allocator.alloc(u32, vn);
    defer allocator.free(remaining);
    @memset(remaining, 0);
    for (graph.edges) |edge| {
        const vfrom = virtual_id[edge.from];
        const vto = virtual_id[edge.to];
        if (vfrom == vto) continue;
        remaining[vto] += 1;
    }

    var queue: std.ArrayListUnmanaged(usize) = .empty;
    defer queue.deinit(allocator);
    for (0..vn) |i| {
        if (remaining[i] == 0) try queue.append(allocator, i);
    }
    if (queue.items.len == 0) {
        try queue.append(allocator, 0);
        remaining[0] = 0;
    }

    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const u = queue.items[qi];
        for (graph.edges) |edge| {
            if (virtual_id[edge.from] != u) continue;
            const vto = virtual_id[edge.to];
            if (vto == u) continue;
            const candidate = v_levels[u] + v_sizes[u];
            if (candidate > v_levels[vto]) v_levels[vto] = candidate;
            if (remaining[vto] > 0) {
                remaining[vto] -= 1;
                if (remaining[vto] == 0) try queue.append(allocator, vto);
            }
        }
    }

    for (0..n) |i| {
        const vid = virtual_id[i];
        if (vid == i) {
            levels[i] = v_levels[i];
        } else {
            const gi = vid - n;
            const local_offset = levels[i] - groups.items[gi].base;
            levels[i] = v_levels[vid] + local_offset;
        }
    }
}

fn computeSubgraphDirs(
    allocator: std.mem.Allocator,
    graph: *const types.MermaidGraph,
) LayoutError![]?types.Direction {
    var total: u32 = 0;
    countSubgraphs(graph.subgraphs, &total);
    if (total == 0) return try allocator.alloc(?types.Direction, 0);
    const dirs = try allocator.alloc(?types.Direction, total + 1);
    @memset(dirs, null);
    var counter: u32 = 0;
    walkSubgraphDirs(graph.subgraphs, &counter, dirs);
    return dirs;
}

fn countSubgraphs(subs: []const types.Subgraph, counter: *u32) void {
    for (subs) |*sg| {
        counter.* += 1;
        countSubgraphs(sg.children, counter);
    }
}

fn walkSubgraphDirs(subs: []const types.Subgraph, counter: *u32, dirs: []?types.Direction) void {
    for (subs) |*sg| {
        counter.* += 1;
        if (sg.direction) |d| {
            dirs[counter.*] = d.layoutDir();
        }
        walkSubgraphDirs(sg.children, counter, dirs);
    }
}

fn effectiveDirection(
    path: []const u32,
    sg_dirs: []const ?types.Direction,
    layout_dir: types.Direction,
) types.Direction {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] < sg_dirs.len) {
            if (sg_dirs[path[i]]) |d| return d;
        }
    }
    return layout_dir;
}

fn assignLevels(allocator: std.mem.Allocator, graph: *const types.MermaidGraph, levels: []usize) LayoutError!void {
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
    _ = max_level;
    return switch (direction) {
        .top_down => .{ .row = level, .col = column },
        .left_right => .{ .row = column, .col = level },
        else => unreachable,
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

fn graphFor(allocator: std.mem.Allocator, direction: types.Direction, nodes: []const types.Node, edges: []const types.Edge) !types.MermaidGraph {
    return .{
        .allocator = allocator,
        .direction = direction,
        .nodes = try allocator.dupe(types.Node, nodes),
        .edges = try allocator.dupe(types.Edge, edges),
    };
}

test "subgraph members occupy a contiguous column band separate from external nodes" {
    const alloc = std.testing.allocator;
    const src =
        \\graph TD
        \\    Start --> S_in
        \\    subgraph processing
        \\        A --> B
        \\        B --> C
        \\    end
        \\    C --> S_out
    ;
    const parse_flowchart = @import("parse_flowchart.zig");
    var graph = try parse_flowchart.parseSource(alloc, src);
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    var id_start: ?types.NodeId = null;
    var id_a: ?types.NodeId = null;
    var id_c: ?types.NodeId = null;
    for (graph.nodes, 0..) |node, i| {
        const nid: types.NodeId = @intCast(i);
        if (std.mem.eql(u8, node.id_text, "Start")) id_start = nid;
        if (std.mem.eql(u8, node.id_text, "A")) id_a = nid;
        if (std.mem.eql(u8, node.id_text, "C")) id_c = nid;
    }

    const col_a = layout.positions[id_a.?].col;
    const col_c = layout.positions[id_c.?].col;
    const col_start = layout.positions[id_start.?].col;
    try std.testing.expectEqual(col_a, col_c);
    try std.testing.expect(col_a != col_start);

    try std.testing.expectEqual(@as(usize, 1), layout.subgraph_frames.len);
    const frame = layout.subgraph_frames[0];
    try std.testing.expect(col_start < frame.col_start or col_start > frame.col_end);
}

test "virtual node composition places external node after subgraph span" {
    const alloc = std.testing.allocator;
    const parse_flowchart = @import("parse_flowchart.zig");
    var graph = try parse_flowchart.parseSource(alloc,
        \\graph TD
        \\    X --> A
        \\    subgraph S
        \\        A --> B --> C
        \\    end
        \\    C --> Y
    );
    defer graph.deinit();

    var layout = try computeLayout(alloc, &graph, .narrow);
    defer layout.deinit();

    var id_c: ?types.NodeId = null;
    var id_y: ?types.NodeId = null;
    for (graph.nodes, 0..) |node, i| {
        const nid: types.NodeId = @intCast(i);
        if (std.mem.eql(u8, node.id_text, "C")) id_c = nid;
        if (std.mem.eql(u8, node.id_text, "Y")) id_y = nid;
    }

    const row_c = layout.positions[id_c.?].row;
    const row_y = layout.positions[id_y.?].row;
    try std.testing.expect(row_y > row_c);
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
