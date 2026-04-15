const std = @import("std");
const types = @import("types.zig");
const parse = @import("parse_git.zig");
const canvas_mod = @import("canvas.zig");
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

const lane_h: usize = 2;
const min_step_w: usize = 4;
const label_left_pad: usize = 1;
const label_right_pad: usize = 1;

pub fn writeGit(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    var graph = parse.parseSource(allocator, source) catch |err| switch (err) {
        error.InvalidMermaid, error.TooManyBranches => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer graph.deinit();

    if (graph.commits.len == 0 or graph.branches.len == 0) return;

    const label_col_w = computeLabelColumnWidth(&graph, opts.ambiguous_width);
    const step_w = computeStepWidth(&graph, opts.ambiguous_width);

    const commit_base_row: usize = 1;

    const canvas_rows = commit_base_row + graph.branches.len * lane_h;
    const canvas_cols = label_col_w + graph.commits.len * step_w + 1;

    var canvas = canvas_mod.Canvas.init(allocator, canvas_rows, canvas_cols) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer canvas.deinit();

    const glyphs = canvas_mod.GlyphSet.unicode;

    for (graph.branches) |br| {
        const row = commit_base_row + @as(usize, br.lane) * lane_h;
        canvas.setGlyph(row, 0, '[');
        canvas.drawLabel(row, 1, br.name, opts.ambiguous_width);
        const name_w = width_mod.displayWidth(br.name, opts.ambiguous_width);
        canvas.setGlyph(row, 1 + name_w, ']');
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
        const row = commit_base_row + @as(usize, br.lane) * lane_h;
        const first_col = commitCenterCol(label_col_w, step_w, lr.first.?);
        const last_col = commitCenterCol(label_col_w, step_w, lr.last.?);
        var c = first_col;
        while (c <= last_col) : (c += 1) {
            canvas.setGlyph(row, c, glyphs.h_line);
        }
    }

    for (graph.branches) |br| {
        const parent_lane = br.parent_lane orelse continue;
        const lr = lane_ranges[br.lane];
        if (lr.first == null) continue;
        const child_row = commit_base_row + @as(usize, br.lane) * lane_h;
        const parent_row = commit_base_row + @as(usize, parent_lane) * lane_h;
        const fork_col = commitCenterCol(label_col_w, step_w, lr.first.?);
        if (fork_col == 0) continue;
        const stem_col = fork_col - 1;
        drawLaneConnector(&canvas, parent_row, child_row, stem_col, &glyphs);
    }

    for (graph.commits) |commit| {
        const from_lane = commit.merge_from_lane orelse continue;
        const from_index = commit.merge_from_index orelse continue;
        const src_row = commit_base_row + @as(usize, from_lane) * lane_h;
        const tgt_row = commit_base_row + @as(usize, commit.lane) * lane_h;
        const src_col = commitCenterCol(label_col_w, step_w, from_index);
        const tgt_col = commitCenterCol(label_col_w, step_w, commit.index);
        if (tgt_col == 0 or src_col > tgt_col) continue;
        drawMergeConnector(&canvas, src_row, src_col, tgt_row, tgt_col, &glyphs);
    }

    for (graph.commits) |commit| {
        const row = commit_base_row + @as(usize, commit.lane) * lane_h;
        const col = commitCenterCol(label_col_w, step_w, commit.index);
        const glyph = commitGlyph(commit);
        canvas.setGlyph(row, col, glyph);

        const tag_text = commit.tag orelse commit.id_text;
        if (tag_text) |t| {
            if (row > 0) {
                const tag_row = row - 1;
                const tag_w = width_mod.displayWidth(t, opts.ambiguous_width);
                if (col + tag_w <= canvas.cols) {
                    canvas.drawLabel(tag_row, col, t, opts.ambiguous_width);
                }
            }
        }
    }

    canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
}

fn commitCenterCol(label_col_w: usize, step_w: usize, index: u16) usize {
    return label_col_w + @as(usize, index) * step_w + step_w / 2;
}

fn computeLabelColumnWidth(graph: *const types.GitGraph, ambiguous: width_mod.AmbiguousWidth) usize {
    var max_w: usize = 0;
    for (graph.branches) |br| {
        const w = width_mod.displayWidth(br.name, ambiguous);
        if (w > max_w) max_w = w;
    }
    return label_left_pad + 1 + max_w + 1 + label_right_pad;
}

fn computeStepWidth(graph: *const types.GitGraph, ambiguous: width_mod.AmbiguousWidth) usize {
    var max_w: usize = min_step_w;
    for (graph.commits) |c| {
        const tag_w: usize = if (c.tag) |t| width_mod.displayWidth(t, ambiguous) else 0;
        const id_w: usize = if (c.id_text) |i| width_mod.displayWidth(i, ambiguous) else 0;
        const label_w = @max(tag_w, id_w);
        max_w = @max(max_w, 2 * label_w + 1);
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
    glyphs: *const canvas_mod.GlyphSet,
) void {
    if (parent_row == child_row) return;
    const top = @min(parent_row, child_row);
    const bot = @max(parent_row, child_row);
    var r = top + 1;
    while (r < bot) : (r += 1) {
        canvas.setGlyph(r, col, glyphs.v_line);
    }
    if (child_row > parent_row) {
        canvas.setGlyph(parent_row, col, glyphs.corner_tr);
        canvas.setGlyph(child_row, col, glyphs.corner_bl);
    } else {
        canvas.setGlyph(parent_row, col, glyphs.corner_br);
        canvas.setGlyph(child_row, col, glyphs.corner_tl);
    }
}

fn drawMergeConnector(
    canvas: *canvas_mod.Canvas,
    src_row: usize,
    src_col: usize,
    tgt_row: usize,
    tgt_col: usize,
    glyphs: *const canvas_mod.GlyphSet,
) void {
    if (src_row == tgt_row) return;
    if (tgt_col == 0) return;
    const bend_col = tgt_col - 1;
    if (bend_col <= src_col) return;

    var c = src_col + 1;
    while (c <= bend_col) : (c += 1) {
        canvas.setGlyph(src_row, c, glyphs.h_line);
    }

    if (tgt_row > src_row) {
        canvas.setGlyph(src_row, bend_col, glyphs.corner_tr);
    } else {
        canvas.setGlyph(src_row, bend_col, glyphs.corner_br);
    }

    const top = @min(src_row, tgt_row);
    const bot = @max(src_row, tgt_row);
    var r = top + 1;
    while (r < bot) : (r += 1) {
        canvas.setGlyph(r, bend_col, glyphs.v_line);
    }

    if (tgt_row > src_row) {
        canvas.setGlyph(tgt_row, bend_col, glyphs.corner_bl);
    } else {
        canvas.setGlyph(tgt_row, bend_col, glyphs.corner_tl);
    }

    canvas.setGlyph(tgt_row, tgt_col, glyphs.h_line);
}

test "writeGit renders ● for NORMAL commits" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeGit(&sink.writer, alloc,
        \\gitGraph
        \\    commit
        \\    commit
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "●") != null);
}

test "writeGit renders ⊗ for REVERSE and ■ for HIGHLIGHT" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeGit(&sink.writer, alloc,
        \\gitGraph
        \\    commit type: REVERSE
        \\    commit type: HIGHLIGHT
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "⊗") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "■") != null);
}

test "writeGit renders ◎ for merge commits" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeGit(&sink.writer, alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    merge develop
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "◎") != null);
}

test "writeGit renders branch lane labels and branch fork glyphs" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeGit(&sink.writer, alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[main]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[develop]") != null);
}

test "writeGit renders tag text" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeGit(&sink.writer, alloc,
        \\gitGraph
        \\    commit tag: "v1.0"
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "v1.0") != null);
}

test "writeGit places each tag on the row just above its own lane" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeGit(&sink.writer, alloc,
        \\gitGraph
        \\    commit tag: "main-tag"
        \\    branch develop
        \\    commit tag: "dev-tag"
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    var lines = std.mem.splitScalar(u8, out, '\n');
    var main_tag_row: ?usize = null;
    var dev_tag_row: ?usize = null;
    var row: usize = 0;
    while (lines.next()) |line| : (row += 1) {
        if (main_tag_row == null and std.mem.indexOf(u8, line, "main-tag") != null) main_tag_row = row;
        if (dev_tag_row == null and std.mem.indexOf(u8, line, "dev-tag") != null) dev_tag_row = row;
    }
    try std.testing.expect(main_tag_row != null);
    try std.testing.expect(dev_tag_row != null);
    try std.testing.expect(main_tag_row.? != dev_tag_row.?);
    try std.testing.expect(dev_tag_row.? > main_tag_row.?);
}

test "writeGit renders merge tag above the merge commit glyph" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeGit(&sink.writer, alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    merge develop tag: "v1.0"
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "◎") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "v1.0") != null);
}

test "writeGit renders merge from an empty branch via fork point" {
    const alloc = std.testing.allocator;
    var sink: std.io.Writer.Allocating = .init(alloc);
    defer sink.deinit();

    try writeGit(&sink.writer, alloc,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    checkout main
        \\    merge develop
    , .{ .wrap_width = null, .ambiguous_width = .narrow });

    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "◎") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "│") != null or
        std.mem.indexOf(u8, out, "└") != null or
        std.mem.indexOf(u8, out, "┘") != null);
}
