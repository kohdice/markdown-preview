const std = @import("std");
const types = @import("types.zig");
const canvas_mod = @import("canvas.zig");
const compile_mod = @import("compile.zig");
const text_layout = @import("text_layout.zig");
const ansi_mod = @import("../term/ansi.zig");
const theme = @import("../term/theme.zig");
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
    enable_ansi: bool = false,
};

const lane_h: usize = 2;
const min_step_w: usize = 4;
const label_left_pad: usize = 1;
const label_right_pad: usize = 1;
const wrapped_min_label_col_w: usize = 4;
const wrapped_min_timeline_cols: usize = 4;
const lane_role_count = theme.default_lane_palette.len;

pub fn paintGit(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    graph_ptr: *const types.GitGraph,
    opts: Options,
) RenderError!void {
    const graph = graph_ptr.*;

    if (graph.commits.len == 0 or graph.branches.len == 0) return;
    if (opts.wrap_width) |wrap_width| {
        return paintGitWrapped(writer, allocator, &graph, wrap_width, opts);
    }

    return paintGitUnwrapped(writer, allocator, &graph, opts);
}

fn paintGitUnwrapped(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    graph: *const types.GitGraph,
    opts: Options,
) RenderError!void {
    const label_col_w = computeLabelColumnWidth(graph, opts.ambiguous_width);
    const step_w = computeStepWidth(graph, opts.ambiguous_width);

    const commit_base_row: usize = 1;

    const canvas_rows = try std.math.add(usize, commit_base_row, try std.math.mul(usize, graph.branches.len, lane_h));
    const canvas_cols = label_col_w +| (graph.commits.len *| step_w) +| 1;

    var canvas = canvas_mod.Canvas.init(allocator, canvas_rows, canvas_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    const glyphs = canvas_mod.GlyphSet.unicode;

    for (graph.branches) |br| {
        const row = commit_base_row +| (@as(usize, br.lane) *| lane_h);
        const role: u8 = @intCast(@as(usize, br.lane) % lane_role_count);
        canvas.setGlyphRole(row, 0, '[', role);
        try canvas.drawLabelRole(row, 1, br.name, role, opts.ambiguous_width);
        const name_w = width_mod.displayWidth(br.name, opts.ambiguous_width);
        canvas.setGlyphRole(row, 1 + name_w, ']', role);
    }

    const LaneRange = struct { first: ?u16 = null, last: ?u16 = null };
    const lane_ranges = allocator.alloc(LaneRange, graph.branches.len) catch return error.OutOfMemory;
    defer allocator.free(lane_ranges);
    for (lane_ranges) |*lr| lr.* = .{};

    for (graph.commits) |commit| {
        const lane = commit.lane;
        var lr = &lane_ranges[lane];
        if (lr.first == null) lr.first = commit.index;
        lr.last = commit.index;
    }

    for (graph.branches) |br| {
        const lr = lane_ranges[br.lane];
        if (lr.first == null) continue;
        const row = commit_base_row +| (@as(usize, br.lane) *| lane_h);
        const role: u8 = @intCast(@as(usize, br.lane) % lane_role_count);
        const first_col = commitCenterCol(label_col_w, step_w, lr.first.?);
        const last_col = commitCenterCol(label_col_w, step_w, lr.last.?);
        var c = first_col;
        while (c <= last_col) : (c += 1) {
            canvas.setGlyphRole(row, c, glyphs.h_line, role);
        }
    }

    for (graph.branches) |br| {
        const parent_lane = br.parent_lane orelse continue;
        const lr = lane_ranges[br.lane];
        if (lr.first == null) continue;
        const child_row = commit_base_row +| (@as(usize, br.lane) *| lane_h);
        const parent_row = commit_base_row +| (@as(usize, parent_lane) *| lane_h);
        const fork_col = commitCenterCol(label_col_w, step_w, lr.first.?);
        if (fork_col == 0) continue;
        const stem_col = fork_col - 1;
        drawLaneConnector(&canvas, parent_row, child_row, stem_col, @intCast(@as(usize, br.lane) % lane_role_count), &glyphs);
    }

    for (graph.commits) |commit| {
        const from_lane = commit.merge_from_lane orelse continue;
        const from_index = commit.merge_from_index orelse continue;
        const src_row = commit_base_row +| (@as(usize, from_lane) *| lane_h);
        const tgt_row = commit_base_row +| (@as(usize, commit.lane) *| lane_h);
        const src_col = commitCenterCol(label_col_w, step_w, from_index);
        const tgt_col = commitCenterCol(label_col_w, step_w, commit.index);
        if (tgt_col == 0 or src_col > tgt_col) continue;
        drawMergeConnector(&canvas, src_row, src_col, tgt_row, tgt_col, @intCast(@as(usize, commit.lane) % lane_role_count), &glyphs);
    }

    for (graph.commits) |commit| {
        const row = commit_base_row +| (@as(usize, commit.lane) *| lane_h);
        const col = commitCenterCol(label_col_w, step_w, commit.index);
        const glyph = commitGlyph(commit);
        const role: u8 = @intCast(@as(usize, commit.lane) % lane_role_count);
        canvas.setGlyphRole(row, col, glyph, role);

        const tag_text = commit.tag orelse commit.id_text;
        if (tag_text) |t| {
            if (row > 0) {
                const tag_row = row - 1;
                const tag_w = width_mod.displayWidth(t, opts.ambiguous_width);
                if (col + tag_w <= canvas.cols) {
                    try canvas.drawLabel(tag_row, col, t, opts.ambiguous_width);
                }
            }
        }
    }

    try writeGitCanvas(writer, &canvas, opts);
}

const GitCommitLabel = struct {
    layout: ?text_layout.LabelLayout = null,

    fn deinit(self: *GitCommitLabel) void {
        if (self.layout) |*layout| layout.deinit();
    }
};

fn paintGitWrapped(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    graph: *const types.GitGraph,
    wrap_width: usize,
    opts: Options,
) RenderError!void {
    if (wrap_width < wrapped_min_label_col_w + wrapped_min_timeline_cols) return error.WidthTooSmall;

    const label_col_w = computeWrappedLabelColumnWidth(graph, wrap_width, opts.ambiguous_width);
    if (label_col_w < wrapped_min_label_col_w or label_col_w +| wrapped_min_timeline_cols > wrap_width) return error.WidthTooSmall;

    const timeline_budget = wrap_width - label_col_w;
    if (timeline_budget < min_step_w) return error.WidthTooSmall;
    const commits_per_band = @max(@as(usize, 1), timeline_budget / min_step_w);
    const band_count = std.math.divCeil(usize, graph.commits.len, commits_per_band) catch unreachable;

    const branch_layouts = allocator.alloc(text_layout.LabelLayout, graph.branches.len) catch return error.OutOfMemory;
    var branch_layouts_init: usize = 0;
    defer {
        var i: usize = 0;
        while (i < branch_layouts_init) : (i += 1) branch_layouts[i].deinit();
        allocator.free(branch_layouts);
    }
    for (graph.branches, 0..) |branch, i| {
        branch_layouts[i] = text_layout.layoutLabel(allocator, branch.name, label_col_w - 2, opts.ambiguous_width) catch return error.OutOfMemory;
        branch_layouts_init += 1;
    }

    const commit_labels = allocator.alloc(GitCommitLabel, graph.commits.len) catch return error.OutOfMemory;
    defer {
        for (commit_labels) |*slot| slot.deinit();
        allocator.free(commit_labels);
    }
    for (commit_labels) |*slot| slot.* = .{};
    for (graph.commits, 0..) |commit, i| {
        const label = commit.tag orelse commit.id_text orelse continue;
        commit_labels[i].layout = text_layout.layoutLabel(allocator, label, min_step_w, opts.ambiguous_width) catch return error.OutOfMemory;
    }

    const branch_count = graph.branches.len;
    const band_lane_count = try std.math.mul(usize, band_count, branch_count);
    const lane_rows = allocator.alloc(usize, band_lane_count) catch return error.OutOfMemory;
    defer allocator.free(lane_rows);
    const branch_tops = allocator.alloc(usize, band_lane_count) catch return error.OutOfMemory;
    defer allocator.free(branch_tops);
    const tag_rows = allocator.alloc(usize, band_lane_count) catch return error.OutOfMemory;
    defer allocator.free(tag_rows);
    const merge_tops = allocator.alloc(usize, band_count) catch return error.OutOfMemory;
    defer allocator.free(merge_tops);

    const total_rows = try planGitWrappedRows(
        allocator,
        graph,
        band_count,
        commit_labels,
        branch_layouts,
        commits_per_band,
        wrap_width,
        opts.ambiguous_width,
        lane_rows,
        branch_tops,
        tag_rows,
        merge_tops,
    );

    var canvas = canvas_mod.Canvas.init(allocator, total_rows, wrap_width) catch return error.OutOfMemory;
    defer canvas.deinit();

    const glyphs = canvas_mod.GlyphSet.unicode;
    drawGitWrappedLayout(
        allocator,
        &canvas,
        graph,
        band_count,
        commit_labels,
        branch_layouts,
        commits_per_band,
        label_col_w,
        lane_rows,
        branch_tops,
        tag_rows,
        merge_tops,
        opts.ambiguous_width,
        &glyphs,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    try writeGitCanvas(writer, &canvas, opts);
}

fn computeWrappedLabelColumnWidth(
    graph: *const types.GitGraph,
    wrap_width: usize,
    ambiguous: width_mod.AmbiguousWidth,
) usize {
    var max_name_w: usize = 1;
    for (graph.branches) |br| {
        max_name_w = @max(max_name_w, width_mod.displayWidth(br.name, ambiguous));
    }

    const cap = wrap_width - wrapped_min_timeline_cols;
    const one_third = @max(wrapped_min_label_col_w, wrap_width / 3);
    const preferred = @min(max_name_w + 2, one_third);
    return @min(cap, @max(wrapped_min_label_col_w, preferred));
}

fn planGitWrappedRows(
    allocator: std.mem.Allocator,
    graph: *const types.GitGraph,
    band_count: usize,
    commit_labels: []const GitCommitLabel,
    branch_layouts: []const text_layout.LabelLayout,
    commits_per_band: usize,
    wrap_width: usize,
    ambiguous: width_mod.AmbiguousWidth,
    lane_rows: []usize,
    branch_tops: []usize,
    tag_rows: []usize,
    merge_tops: []usize,
) error{ OutOfMemory, Overflow }!usize {
    const branch_count = graph.branches.len;
    var row: usize = 0;
    var band: usize = 0;
    while (band < band_count) : (band += 1) {
        if (band > 0) row = try std.math.add(usize, row, 1);

        var active_count: usize = 0;
        var lane: usize = 0;
        while (lane < branch_count) : (lane += 1) {
            const slot = band * branch_count + lane;
            if (!branchActiveInBand(graph, lane, band, band_count, commits_per_band)) {
                branch_tops[slot] = row;
                tag_rows[slot] = 0;
                lane_rows[slot] = row;
                continue;
            }

            if (active_count > 0) row = try std.math.add(usize, row, 1);
            const tags = sumCommitLabelRowsForLaneInBand(graph, commit_labels, lane, band, commits_per_band);
            const branch_h = @max(@as(usize, 1), branch_layouts[lane].lines.len);
            branch_tops[slot] = row;
            tag_rows[slot] = tags;
            lane_rows[slot] = try std.math.add(usize, try std.math.add(usize, row, tags), branch_h / 2);
            row = try std.math.add(usize, try std.math.add(usize, row, tags), branch_h);
            active_count += 1;
        }

        merge_tops[band] = row;
        row = try std.math.add(usize, row, try crossBandMergeRows(allocator, graph, band, commits_per_band, wrap_width, ambiguous));
    }
    return row;
}

fn sumCommitLabelRowsForLaneInBand(
    graph: *const types.GitGraph,
    commit_labels: []const GitCommitLabel,
    lane: usize,
    band: usize,
    commits_per_band: usize,
) usize {
    const start = band *| commits_per_band;
    const end = @min(graph.commits.len, start +| commits_per_band);
    var rows: usize = 0;
    for (graph.commits[start..end], start..) |commit, idx| {
        if (commit.lane != lane) continue;
        if (commit_labels[idx].layout) |layout| rows = rows +| layout.lines.len;
    }
    return rows;
}

fn crossBandMergeRows(
    allocator: std.mem.Allocator,
    graph: *const types.GitGraph,
    band: usize,
    commits_per_band: usize,
    wrap_width: usize,
    ambiguous: width_mod.AmbiguousWidth,
) error{ OutOfMemory, Overflow }!usize {
    const start = try std.math.mul(usize, band, commits_per_band);
    const end = @min(graph.commits.len, try std.math.add(usize, start, commits_per_band));
    var rows: usize = 0;
    for (graph.commits[start..end]) |commit| {
        const from_index = commit.merge_from_index orelse continue;
        if (@as(usize, from_index) / commits_per_band == band) continue;
        const text = try formatCrossBandMerge(allocator, graph, commit);
        defer allocator.free(text);
        var layout = try text_layout.layoutLabel(allocator, text, wrap_width, ambiguous);
        defer layout.deinit();
        rows = try std.math.add(usize, rows, layout.lines.len);
    }
    return rows;
}

fn drawGitWrappedLayout(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    graph: *const types.GitGraph,
    band_count: usize,
    commit_labels: []const GitCommitLabel,
    branch_layouts: []const text_layout.LabelLayout,
    commits_per_band: usize,
    label_col_w: usize,
    lane_rows: []const usize,
    branch_tops: []const usize,
    tag_rows: []const usize,
    merge_tops: []const usize,
    ambiguous: width_mod.AmbiguousWidth,
    glyphs: *const canvas_mod.GlyphSet,
) error{OutOfMemory}!void {
    const branch_count = graph.branches.len;

    var band: usize = 0;
    while (band < band_count) : (band += 1) {
        if (band > 0) drawGitBandSeparator(canvas, branch_tops[band * branch_count] - 1, glyphs);

        for (graph.branches, 0..) |branch, lane| {
            if (!branchActiveInBand(graph, lane, band, band_count, commits_per_band)) continue;
            const slot = band * branch_count + lane;
            try drawWrappedBranchLabel(canvas, branch_tops[slot] + tag_rows[slot], label_col_w, &branch_layouts[lane], @intCast(@as(usize, branch.lane) % lane_role_count), ambiguous);
        }

        drawGitBandLaneRanges(canvas, graph, band, band_count, commits_per_band, label_col_w, lane_rows, glyphs);
        drawGitBandForks(canvas, graph, band, band_count, commits_per_band, label_col_w, lane_rows, glyphs);
        drawGitBandMerges(canvas, graph, band, band_count, commits_per_band, label_col_w, lane_rows, glyphs);
        try drawGitBandCommits(canvas, graph, commit_labels, band, commits_per_band, label_col_w, lane_rows, branch_tops, ambiguous);
        try drawGitCrossBandMerges(allocator, canvas, graph, band, commits_per_band, merge_tops[band], ambiguous);
    }
}

fn drawGitBandSeparator(canvas: *canvas_mod.Canvas, row: usize, glyphs: *const canvas_mod.GlyphSet) void {
    var c: usize = 0;
    while (c < canvas.cols) : (c += 1) canvas.setGlyphRole(row, c, glyphs.h_line, 0);
}

fn drawWrappedBranchLabel(
    canvas: *canvas_mod.Canvas,
    top: usize,
    label_col_w: usize,
    layout: *const text_layout.LabelLayout,
    role: u8,
    ambiguous: width_mod.AmbiguousWidth,
) error{OutOfMemory}!void {
    for (layout.lines, 0..) |line, idx| {
        const row = top + idx;
        canvas.setGlyphRole(row, 0, '[', role);
        try canvas.drawLabelRole(row, 1, line.text, role, ambiguous);
        canvas.setGlyphRole(row, @min(label_col_w - 1, 1 + line.width), ']', role);
    }
}

fn drawGitBandLaneRanges(
    canvas: *canvas_mod.Canvas,
    graph: *const types.GitGraph,
    band: usize,
    band_count: usize,
    commits_per_band: usize,
    label_col_w: usize,
    lane_rows: []const usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    const branch_count = graph.branches.len;
    for (graph.branches) |branch| {
        if (!branchActiveInBand(graph, @intCast(branch.lane), band, band_count, commits_per_band)) continue;
        const range = laneCommitRangeInBand(graph, branch.lane, band, commits_per_band) orelse continue;
        const row = lane_rows[band * branch_count + branch.lane];
        const role: u8 = @intCast(@as(usize, branch.lane) % lane_role_count);
        const first_col = wrappedCommitCenterCol(label_col_w, range.first - band * commits_per_band);
        const last_col = wrappedCommitCenterCol(label_col_w, range.last - band * commits_per_band);
        var c = first_col;
        while (c <= last_col) : (c += 1) canvas.setGlyphRole(row, c, glyphs.h_line, role);
    }
}

fn drawGitBandForks(
    canvas: *canvas_mod.Canvas,
    graph: *const types.GitGraph,
    band: usize,
    band_count: usize,
    commits_per_band: usize,
    label_col_w: usize,
    lane_rows: []const usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    const branch_count = graph.branches.len;
    for (graph.branches) |branch| {
        if (!branchActiveInBand(graph, @intCast(branch.lane), band, band_count, commits_per_band)) continue;
        const parent_lane = branch.parent_lane orelse continue;
        if (!branchActiveInBand(graph, @intCast(parent_lane), band, band_count, commits_per_band)) continue;
        const first_idx = firstCommitOnLane(graph, branch.lane) orelse continue;
        if (first_idx / commits_per_band != band) continue;
        const child_row = lane_rows[band * branch_count + branch.lane];
        const parent_row = lane_rows[band * branch_count + parent_lane];
        const fork_col = wrappedCommitCenterCol(label_col_w, first_idx - band * commits_per_band);
        if (fork_col == 0) continue;
        drawLaneConnector(canvas, parent_row, child_row, fork_col - 1, @intCast(@as(usize, branch.lane) % lane_role_count), glyphs);
    }
}

fn drawGitBandMerges(
    canvas: *canvas_mod.Canvas,
    graph: *const types.GitGraph,
    band: usize,
    band_count: usize,
    commits_per_band: usize,
    label_col_w: usize,
    lane_rows: []const usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    const branch_count = graph.branches.len;
    const start = band * commits_per_band;
    const end = @min(graph.commits.len, start + commits_per_band);
    for (graph.commits[start..end], start..) |commit, idx| {
        const from_lane = commit.merge_from_lane orelse continue;
        const from_index = commit.merge_from_index orelse continue;
        if (@as(usize, from_index) / commits_per_band != band) continue;
        if (!branchActiveInBand(graph, @intCast(from_lane), band, band_count, commits_per_band)) continue;
        if (!branchActiveInBand(graph, @intCast(commit.lane), band, band_count, commits_per_band)) continue;
        const src_row = lane_rows[band * branch_count + from_lane];
        const tgt_row = lane_rows[band * branch_count + commit.lane];
        const src_col = wrappedCommitCenterCol(label_col_w, @as(usize, from_index) - start);
        const tgt_col = wrappedCommitCenterCol(label_col_w, idx - start);
        if (tgt_col == 0 or src_col > tgt_col) continue;
        drawMergeConnector(canvas, src_row, src_col, tgt_row, tgt_col, @intCast(@as(usize, commit.lane) % lane_role_count), glyphs);
    }
}

fn drawGitBandCommits(
    canvas: *canvas_mod.Canvas,
    graph: *const types.GitGraph,
    commit_labels: []const GitCommitLabel,
    band: usize,
    commits_per_band: usize,
    label_col_w: usize,
    lane_rows: []const usize,
    branch_tops: []const usize,
    ambiguous: width_mod.AmbiguousWidth,
) error{OutOfMemory}!void {
    const branch_count = graph.branches.len;
    const start = band * commits_per_band;
    const end = @min(graph.commits.len, start + commits_per_band);
    for (graph.commits[start..end], start..) |commit, idx| {
        const slot = band * branch_count + commit.lane;
        const col = wrappedCommitCenterCol(label_col_w, idx - start);
        const row = lane_rows[slot];
        const role: u8 = @intCast(@as(usize, commit.lane) % lane_role_count);
        canvas.setGlyphRole(row, col, commitGlyph(commit), role);

        if (commit_labels[idx].layout) |layout| {
            const label_top = branch_tops[slot] + commitLabelRowOffsetInBand(graph, commit_labels, commit.lane, start, idx);
            try drawCenteredGitLabel(canvas, label_top, col, &layout, label_col_w, ambiguous);
        }
    }
}

fn commitLabelRowOffsetInBand(
    graph: *const types.GitGraph,
    commit_labels: []const GitCommitLabel,
    lane: u16,
    start: usize,
    idx: usize,
) usize {
    var offset: usize = 0;
    for (graph.commits[start..idx], start..) |commit, prior_idx| {
        if (commit.lane != lane) continue;
        if (commit_labels[prior_idx].layout) |layout| offset += layout.lines.len;
    }
    return offset;
}

fn drawGitCrossBandMerges(
    allocator: std.mem.Allocator,
    canvas: *canvas_mod.Canvas,
    graph: *const types.GitGraph,
    band: usize,
    commits_per_band: usize,
    start_row: usize,
    ambiguous: width_mod.AmbiguousWidth,
) error{OutOfMemory}!void {
    var row = start_row;
    const start = band * commits_per_band;
    const end = @min(graph.commits.len, start + commits_per_band);
    for (graph.commits[start..end]) |commit| {
        const from_index = commit.merge_from_index orelse continue;
        if (@as(usize, from_index) / commits_per_band == band) continue;
        const text = try formatCrossBandMerge(allocator, graph, commit);
        defer allocator.free(text);
        var layout = try text_layout.layoutLabel(allocator, text, canvas.cols, ambiguous);
        defer layout.deinit();
        for (layout.lines) |line| {
            try canvas.drawLabelRole(row, 0, line.text, @intCast(@as(usize, commit.lane) % lane_role_count), ambiguous);
            row += 1;
        }
    }
}

fn drawCenteredGitLabel(
    canvas: *canvas_mod.Canvas,
    top: usize,
    center_col: usize,
    layout: *const text_layout.LabelLayout,
    min_col: usize,
    ambiguous: width_mod.AmbiguousWidth,
) error{OutOfMemory}!void {
    if (layout.lines.len == 0) return;
    for (layout.lines, 0..) |line, idx| {
        const half = line.width / 2;
        var col = if (center_col > half) center_col - half else min_col;
        if (col < min_col) col = min_col;
        if (line.width <= canvas.cols and col + line.width > canvas.cols) col = canvas.cols - line.width;
        try canvas.drawLabel(top + idx, col, line.text, ambiguous);
    }
}

fn formatCrossBandMerge(
    allocator: std.mem.Allocator,
    graph: *const types.GitGraph,
    commit: types.GitCommit,
) error{OutOfMemory}![]u8 {
    const from_lane = commit.merge_from_lane orelse return allocator.dupe(u8, "merge");
    const from = graph.branches[from_lane].name;
    const to = graph.branches[commit.lane].name;
    if (commit.tag orelse commit.id_text) |label| {
        return std.fmt.allocPrint(allocator, "merge {s} -> {s}: {s}", .{ from, to, label });
    }
    return std.fmt.allocPrint(allocator, "merge {s} -> {s}", .{ from, to });
}

fn branchActiveInBand(
    graph: *const types.GitGraph,
    lane: usize,
    band: usize,
    band_count: usize,
    commits_per_band: usize,
) bool {
    const start = band * commits_per_band;
    const end = @min(graph.commits.len, start + commits_per_band);
    const branch = graph.branches[lane];
    const created_at: usize = branch.created_at;

    if (created_at >= start and created_at < end) return true;
    if (band + 1 == band_count and created_at == graph.commits.len) return true;

    for (graph.commits[start..end]) |commit| {
        if (commit.lane == branch.lane) return true;
        if (commit.merge_from_lane == branch.lane) return true;
    }
    return false;
}

const LaneCommitRange = struct { first: usize, last: usize };

fn laneCommitRangeInBand(
    graph: *const types.GitGraph,
    lane: u16,
    band: usize,
    commits_per_band: usize,
) ?LaneCommitRange {
    const start = band * commits_per_band;
    const end = @min(graph.commits.len, start + commits_per_band);
    var first: ?usize = null;
    var last: ?usize = null;
    for (graph.commits[start..end], start..) |commit, idx| {
        if (commit.lane != lane) continue;
        if (first == null) first = idx;
        last = idx;
    }
    if (first == null or last == null) return null;
    return .{ .first = first.?, .last = last.? };
}

fn firstCommitOnLane(graph: *const types.GitGraph, lane: u16) ?usize {
    for (graph.commits, 0..) |commit, idx| {
        if (commit.lane == lane) return idx;
    }
    return null;
}

fn wrappedCommitCenterCol(label_col_w: usize, local_index: usize) usize {
    return label_col_w +| (local_index *| min_step_w) +| (min_step_w / 2);
}

fn writeGitCanvas(writer: *std.Io.Writer, canvas: *const canvas_mod.Canvas, opts: Options) RenderError!void {
    if (opts.enable_ansi) {
        canvas_mod.writeCanvasAnsi(writer, canvas, opts.wrap_width, opts.ambiguous_width, &theme.default_lane_palette) catch return error.WriteFailed;
    } else {
        canvas_mod.writeCanvas(writer, canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
    }
}

fn commitCenterCol(label_col_w: usize, step_w: usize, index: u16) usize {
    return label_col_w +| (@as(usize, index) *| step_w) +| (step_w / 2);
}

fn computeLabelColumnWidth(graph: *const types.GitGraph, ambiguous: width_mod.AmbiguousWidth) usize {
    var max_w: usize = 0;
    for (graph.branches) |br| {
        const w = width_mod.displayWidth(br.name, ambiguous);
        if (w > max_w) max_w = w;
    }
    return label_left_pad +| 1 +| max_w +| 1 +| label_right_pad;
}

fn computeStepWidth(graph: *const types.GitGraph, ambiguous: width_mod.AmbiguousWidth) usize {
    var max_w: usize = min_step_w;
    for (graph.commits) |c| {
        const tag_w: usize = if (c.tag) |t| width_mod.displayWidth(t, ambiguous) else 0;
        const id_w: usize = if (c.id_text) |i| width_mod.displayWidth(i, ambiguous) else 0;
        const label_w = @max(tag_w, id_w);
        max_w = @max(max_w, (2 *| label_w) +| 1);
    }
    return max_w;
}

fn commitGlyph(commit: types.GitCommit) u21 {
    if (commit.merge_from_lane != null) return '◎';
    return switch (commit.commit_type) {
        .normal => '●',
        .reverse => '⊗',
        .highlight => '■',
    };
}

fn drawLaneConnector(
    canvas: *canvas_mod.Canvas,
    parent_row: usize,
    child_row: usize,
    col: usize,
    role: u8,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    if (parent_row == child_row) return;
    const top = @min(parent_row, child_row);
    const bot = @max(parent_row, child_row);
    var r = top + 1;
    while (r < bot) : (r += 1) {
        canvas.setGlyphRole(r, col, glyphs.v_line, role);
    }
    if (child_row > parent_row) {
        canvas.setGlyphRole(parent_row, col, glyphs.corner_tr, role);
        canvas.setGlyphRole(child_row, col, glyphs.corner_bl, role);
    } else {
        canvas.setGlyphRole(parent_row, col, glyphs.corner_br, role);
        canvas.setGlyphRole(child_row, col, glyphs.corner_tl, role);
    }
}

fn drawMergeConnector(
    canvas: *canvas_mod.Canvas,
    src_row: usize,
    src_col: usize,
    tgt_row: usize,
    tgt_col: usize,
    role: u8,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    if (src_row == tgt_row) return;
    if (tgt_col == 0) return;
    const bend_col = tgt_col - 1;
    if (bend_col <= src_col) return;

    var c = src_col + 1;
    while (c <= bend_col) : (c += 1) {
        canvas.setGlyphRole(src_row, c, glyphs.h_line, role);
    }

    if (tgt_row > src_row) {
        canvas.setGlyphRole(src_row, bend_col, glyphs.corner_tr, role);
    } else {
        canvas.setGlyphRole(src_row, bend_col, glyphs.corner_br, role);
    }

    const top = @min(src_row, tgt_row);
    const bot = @max(src_row, tgt_row);
    var r = top + 1;
    while (r < bot) : (r += 1) {
        canvas.setGlyphRole(r, bend_col, glyphs.v_line, role);
    }

    if (tgt_row > src_row) {
        canvas.setGlyphRole(tgt_row, bend_col, glyphs.corner_bl, role);
    } else {
        canvas.setGlyphRole(tgt_row, bend_col, glyphs.corner_tl, role);
    }

    canvas.setGlyphRole(tgt_row, tgt_col, glyphs.h_line, role);
}

test "paintGit renders ● for NORMAL commits" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    commit
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "●") != null);
}

test "paintGit renders ⊗ for REVERSE and ■ for HIGHLIGHT" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit type: REVERSE
        \\    commit type: HIGHLIGHT
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "⊗") != null);
    try std.testing.expect(std.mem.find(u8, out, "■") != null);
}

test "paintGit renders ◎ for merge commits" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    merge develop
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "◎") != null);
}

test "paintGit renders branch lane labels and branch fork glyphs" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "[main]") != null);
    try std.testing.expect(std.mem.find(u8, out, "[develop]") != null);
}

test "paintGit renders tag text" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit tag: "v1.0"
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "v1.0") != null);
}

test "paintGit places each tag on the row just above its own lane" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit tag: "main-tag"
        \\    branch develop
        \\    commit tag: "dev-tag"
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const out = sink.writer.buffered();
    var lines = std.mem.splitScalar(u8, out, '\n');
    var main_tag_row: ?usize = null;
    var dev_tag_row: ?usize = null;
    var row: usize = 0;
    while (lines.next()) |line| : (row += 1) {
        if (main_tag_row == null and std.mem.find(u8, line, "main-tag") != null) main_tag_row = row;
        if (dev_tag_row == null and std.mem.find(u8, line, "dev-tag") != null) dev_tag_row = row;
    }
    try std.testing.expect(main_tag_row != null);
    try std.testing.expect(dev_tag_row != null);
    try std.testing.expect(main_tag_row.? != dev_tag_row.?);
    try std.testing.expect(dev_tag_row.? > main_tag_row.?);
}

test "paintGit renders merge tag above the merge commit glyph" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    merge develop tag: "v1.0"
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "◎") != null);
    try std.testing.expect(std.mem.find(u8, out, "v1.0") != null);
}

test "paintGit null wrap keeps simple branch and merge snapshot" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    commit
        \\    merge develop
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const expected =
        \\
        \\[main]       ●──┐────●──┌◎
        \\                │       │
        \\[develop]       └●──────┘
        \\
    ;
    try std.testing.expectEqualStrings(expected, sink.writer.buffered());
}

test "paintGit null wrap keeps commit id tag and type snapshot" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit id: "root" tag: "v1.0"
        \\    commit type: REVERSE id: "rev"
        \\    commit type: HIGHLIGHT tag: "hi"
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const expected =
        \\            v1.0     rev      hi
        \\[main]      ●────────⊗────────■
        \\
    ;
    try std.testing.expectEqualStrings(expected, sink.writer.buffered());
}

test "paintGit null wrap keeps empty branch merge snapshot" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    checkout main
        \\    merge develop
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const expected =
        \\
        \\[main]       ●──┌◎
        \\                │
        \\[develop]     ──┘
        \\
    ;
    try std.testing.expectEqualStrings(expected, sink.writer.buffered());
}

test "paintGit null wrap keeps two-lane ANSI snapshot" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    var buf0: [32]u8 = undefined;
    var buf1: [32]u8 = undefined;
    const sgr0 = sgrForLane(&buf0, 0);
    const sgr1 = sgrForLane(&buf1, 1);
    const reset = ansi_mod.reset_sequence;
    const expected = try std.fmt.allocPrint(
        alloc,
        "\n" ++
            "{s}[main]{s}       {s}●{s}  {s}┐{s}\n" ++
            "                {s}│{s}\n" ++
            "{s}[develop]{s}       {s}└●{s}\n",
        .{ sgr0, reset, sgr0, reset, sgr1, reset, sgr1, reset, sgr1, reset, sgr1, reset },
    );
    defer alloc.free(expected);

    try std.testing.expectEqualStrings(expected, sink.writer.buffered());
}

test "paintGit renders merge from an empty branch via fork point" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    checkout main
        \\    merge develop
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "◎") != null);
    try std.testing.expect(std.mem.find(u8, out, "│") != null or
        std.mem.find(u8, out, "└") != null or
        std.mem.find(u8, out, "┘") != null);
}

test "paintGit without ANSI contains no escape sequences" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    merge develop
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "\x1b[") == null);
}

test "paintGit with enable_ansi=true emits truecolor SGR" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "\x1b[38;2;") != null);
}

test "paintGit enable_ansi=false matches bare-default call byte-for-byte" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
    );
    defer diagram.deinit();

    var with_flag: std.Io.Writer.Allocating = .init(alloc);
    defer with_flag.deinit();
    try paintGit(&with_flag.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = false });

    var defaults: std.Io.Writer.Allocating = .init(alloc);
    defer defaults.deinit();
    try paintGit(&defaults.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow });

    try std.testing.expectEqualStrings(with_flag.writer.buffered(), defaults.writer.buffered());
}

fn sgrForLane(buf: []u8, lane_idx: usize) []const u8 {
    const c = theme.default_lane_palette[lane_idx & 0x07];
    return std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }) catch unreachable;
}

fn expectAllGitLinesFitAnsi(allocator: std.mem.Allocator, out: []const u8, limit: usize) !void {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const stripped = try ansi_mod.stripCsiAlloc(allocator, line);
        defer allocator.free(stripped);
        const w = width_mod.displayWidth(stripped, .narrow);
        try std.testing.expect(w <= limit);
    }
}

test "paintGit returns WidthTooSmall when wrapped timeline cannot fit label plus commit glyph" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try std.testing.expectError(error.WidthTooSmall, paintGit(&sink.writer, alloc, &diagram.git_graph, .{
        .wrap_width = 7,
        .ambiguous_width = .narrow,
        .enable_ansi = false,
    }));
}

test "paintGit accepts minimum wrapped label column plus commit glyph width" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{
        .wrap_width = 8,
        .ambiguous_width = .narrow,
        .enable_ansi = false,
    });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.find(u8, out, "●") != null);
    try expectAllGitLinesFitAnsi(alloc, out, 8);
}

test "paintGit wraps labels and bands commits without generated clipping" {
    const alloc = std.testing.allocator;
    const source =
        \\gitGraph
        \\    commit id: "root … é"
        \\    branch 開発ブランチ長い
        \\    commit tag: "dev❤️‍🔥tag"
        \\    commit type: HIGHLIGHT tag: "highlight-long-tag"
        \\    checkout main
        \\    commit type: REVERSE tag: "reverse-very-long"
        \\    commit
        \\    commit
        \\    commit
        \\    commit
        \\    merge 開発ブランチ長い tag: "merge label"
    ;
    var diagram = try compile_mod.compile(alloc, source);
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{
        .wrap_width = 40,
        .ambiguous_width = .narrow,
        .enable_ansi = false,
    });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.count(u8, out, "\u{2026}") <= std.mem.count(u8, source, "\u{2026}"));
    try std.testing.expect(std.mem.find(u8, out, "[mermaid:") == null);
    try std.testing.expect(std.mem.find(u8, out, "root") != null);
    try std.testing.expect(std.mem.find(u8, out, "… é") != null);
    try std.testing.expect(std.mem.find(u8, out, "❤️‍🔥") != null);
    try std.testing.expect(std.mem.find(u8, out, "開") != null);
    try std.testing.expect(std.mem.find(u8, out, "■") != null);
    try std.testing.expect(std.mem.find(u8, out, "⊗") != null);
    try std.testing.expect(std.mem.find(u8, out, "◎") != null);
    try std.testing.expect(std.mem.find(u8, out, "merge") != null);
    try std.testing.expect(std.mem.count(u8, out, "●") >= 5);
    try expectAllGitLinesFitAnsi(alloc, out, 40);
}

test "paintGit wrapped bands do not render branches before their creation point" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    commit
        \\    commit
        \\    commit
        \\    commit
        \\    branch future
        \\    commit
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{
        .wrap_width = 24,
        .ambiguous_width = .narrow,
        .enable_ansi = false,
    });

    const out = sink.writer.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "[future]"));
    try expectAllGitLinesFitAnsi(alloc, out, 24);
}

test "paintGit wrapped bands omit inactive branch labels after earlier branch activity" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch feature
        \\    commit
        \\    checkout main
        \\    commit
        \\    commit
        \\    commit
        \\    commit
        \\    commit
        \\    commit
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{
        .wrap_width = 24,
        .ambiguous_width = .narrow,
        .enable_ansi = false,
    });

    const out = sink.writer.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "[featur]"));
    try expectAllGitLinesFitAnsi(alloc, out, 24);
}

test "paintGit keeps ANSI lane colors across wrapped labels and band separators" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch feature長い
        \\    commit tag: "feature-label"
        \\    checkout main
        \\    commit
        \\    commit
        \\    commit
        \\    merge feature長い tag: "done"
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{
        .wrap_width = 24,
        .ambiguous_width = .narrow,
        .enable_ansi = true,
    });

    const out = sink.writer.buffered();
    var buf0: [32]u8 = undefined;
    var buf1: [32]u8 = undefined;
    const sgr0 = sgrForLane(&buf0, 0);
    const sgr1 = sgrForLane(&buf1, 1);
    try std.testing.expect(std.mem.find(u8, out, sgr0) != null);
    try std.testing.expect(std.mem.find(u8, out, sgr1) != null);
    try std.testing.expect(std.mem.find(u8, out, "\u{2026}") == null);
    try expectAllGitLinesFitAnsi(alloc, out, 24);
}

test "paintGit with enable_ansi=true uses different SGR for lane 0 and lane 1" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    var buf0: [32]u8 = undefined;
    var buf1: [32]u8 = undefined;
    const sgr0 = sgrForLane(&buf0, 0);
    const sgr1 = sgrForLane(&buf1, 1);
    try std.testing.expect(!std.mem.eql(u8, sgr0, sgr1));
    try std.testing.expect(std.mem.find(u8, out, sgr0) != null);
    try std.testing.expect(std.mem.find(u8, out, sgr1) != null);
}

test "paintGit wraps lane colors modulo 8 (lane 0 and lane 8 share role)" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch b1
        \\    commit
        \\    branch b2
        \\    commit
        \\    branch b3
        \\    commit
        \\    branch b4
        \\    commit
        \\    branch b5
        \\    commit
        \\    branch b6
        \\    commit
        \\    branch b7
        \\    commit
        \\    branch b8
        \\    commit
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    var buf0: [32]u8 = undefined;
    const sgr0 = sgrForLane(&buf0, 0);
    const occ = std.mem.count(u8, out, sgr0);
    try std.testing.expect(occ >= 2);
}

test "paintGit lane 7 and lane 8 use distinct roles" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch b1
        \\    commit
        \\    branch b2
        \\    commit
        \\    branch b3
        \\    commit
        \\    branch b4
        \\    commit
        \\    branch b5
        \\    commit
        \\    branch b6
        \\    commit
        \\    branch b7
        \\    commit
        \\    branch b8
        \\    commit
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    var buf0: [32]u8 = undefined;
    var buf7: [32]u8 = undefined;
    const sgr0 = sgrForLane(&buf0, 0);
    const sgr7 = sgrForLane(&buf7, 7);
    try std.testing.expect(!std.mem.eql(u8, sgr0, sgr7));
    try std.testing.expect(std.mem.find(u8, out, sgr7) != null);
}

test "paintGit HIGHLIGHT commit glyph uses lane role color" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit type: HIGHLIGHT
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    var buf: [64]u8 = undefined;
    const sgr0 = sgrForLane(buf[0..32], 0);
    const pattern = std.fmt.bufPrint(buf[32..], "{s}■", .{sgr0}) catch unreachable;
    try std.testing.expect(std.mem.find(u8, out, pattern) != null);
}

test "paintGit merge commit ◎ is preceded by destination lane SGR" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    merge develop
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    var buf0: [32]u8 = undefined;
    const sgr0 = sgrForLane(&buf0, 0);

    var lines = std.mem.splitScalar(u8, out, '\n');
    var checked = false;
    while (lines.next()) |line| {
        const bullseye_pos = std.mem.find(u8, line, "◎") orelse continue;
        checked = true;
        const prefix = line[0..bullseye_pos];
        const last_sgr_start = std.mem.findLast(u8, prefix, "\x1b[38;2;") orelse return error.NoSgrBeforeMerge;
        const last_sgr = prefix[last_sgr_start..];
        try std.testing.expect(std.mem.startsWith(u8, last_sgr, sgr0));
    }
    try std.testing.expect(checked);
}

test "paintGit merge connector uses destination lane role" {
    const alloc = std.testing.allocator;
    var diagram = try compile_mod.compile(alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    checkout main
        \\    merge develop
    );
    defer diagram.deinit();

    var sink: std.Io.Writer.Allocating = .init(alloc);
    defer sink.deinit();
    try paintGit(&sink.writer, alloc, &diagram.git_graph, .{ .wrap_width = null, .ambiguous_width = .narrow, .enable_ansi = true });

    const out = sink.writer.buffered();
    var buf0: [32]u8 = undefined;
    var buf1: [32]u8 = undefined;
    const sgr0 = sgrForLane(&buf0, 0);
    const sgr1 = sgrForLane(&buf1, 1);

    var lines = std.mem.splitScalar(u8, out, '\n');
    var checked = false;
    while (lines.next()) |line| {
        const v_pos = std.mem.find(u8, line, "│") orelse continue;
        if (std.mem.find(u8, line, "●") != null) continue;
        if (std.mem.find(u8, line, "◎") != null) continue;
        if (std.mem.find(u8, line, "]") != null) continue;
        checked = true;
        const prefix = line[0..v_pos];
        const last_sgr_start = std.mem.findLast(u8, prefix, "\x1b[38;2;") orelse return error.NoSgrBeforeConnector;
        const last_sgr = prefix[last_sgr_start..];
        try std.testing.expect(std.mem.startsWith(u8, last_sgr, sgr0));
        try std.testing.expect(std.mem.find(u8, line, sgr1) == null);
    }
    try std.testing.expect(checked);
}
