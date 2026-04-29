const std = @import("std");
const types = @import("types.zig");
const canvas_mod = @import("canvas.zig");
const compile_mod = @import("compile.zig");
const ansi_mod = @import("../term/ansi.zig");
const theme = @import("../term/theme.zig");
const width_mod = @import("../term/width.zig");

pub const RenderError = error{
    InvalidMermaid,
    UnsupportedFeature,
    WidthTooSmall,
    OutOfMemory,
    WriteFailed,
};

pub const Options = struct {
    wrap_width: ?usize,
    ambiguous_width: width_mod.AmbiguousWidth,
    enable_ansi: bool = false,
    color_mode: ansi_mod.ColorMode = .truecolor,
};

const lane_h: usize = 2;
const min_step_w: usize = 4;
const label_left_pad: usize = 1;
const label_right_pad: usize = 1;

fn laneRole(lane: u16) u8 {
    return @as(u8, @intCast(lane & 0x07));
}

pub fn paintGit(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    graph_ptr: *const types.GitGraph,
    opts: Options,
) RenderError!void {
    const graph = graph_ptr.*;

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
        const role = laneRole(br.lane);
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
        const row = commit_base_row + @as(usize, br.lane) * lane_h;
        const role = laneRole(br.lane);
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
        const child_row = commit_base_row + @as(usize, br.lane) * lane_h;
        const parent_row = commit_base_row + @as(usize, parent_lane) * lane_h;
        const fork_col = commitCenterCol(label_col_w, step_w, lr.first.?);
        if (fork_col == 0) continue;
        const stem_col = fork_col - 1;
        drawLaneConnector(&canvas, parent_row, child_row, stem_col, laneRole(br.lane), &glyphs);
    }

    for (graph.commits) |commit| {
        const from_lane = commit.merge_from_lane orelse continue;
        const from_index = commit.merge_from_index orelse continue;
        const src_row = commit_base_row + @as(usize, from_lane) * lane_h;
        const tgt_row = commit_base_row + @as(usize, commit.lane) * lane_h;
        const src_col = commitCenterCol(label_col_w, step_w, from_index);
        const tgt_col = commitCenterCol(label_col_w, step_w, commit.index);
        if (tgt_col == 0 or src_col > tgt_col) continue;
        drawMergeConnector(&canvas, src_row, src_col, tgt_row, tgt_col, laneRole(commit.lane), &glyphs);
    }

    for (graph.commits) |commit| {
        const row = commit_base_row + @as(usize, commit.lane) * lane_h;
        const col = commitCenterCol(label_col_w, step_w, commit.index);
        const glyph = commitGlyph(commit);
        const role = laneRole(commit.lane);
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

    if (opts.enable_ansi) {
        canvas_mod.writeCanvasAnsi(writer, &canvas, opts.wrap_width, opts.ambiguous_width, &theme.default_lane_palette, opts.color_mode) catch return error.WriteFailed;
    } else {
        canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
    }
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
    try std.testing.expect(std.mem.indexOf(u8, out, "●") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "⊗") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "■") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "◎") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "[main]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[develop]") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "v1.0") != null);
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
        if (main_tag_row == null and std.mem.indexOf(u8, line, "main-tag") != null) main_tag_row = row;
        if (dev_tag_row == null and std.mem.indexOf(u8, line, "dev-tag") != null) dev_tag_row = row;
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
    try std.testing.expect(std.mem.indexOf(u8, out, "◎") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "v1.0") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "◎") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "│") != null or
        std.mem.indexOf(u8, out, "└") != null or
        std.mem.indexOf(u8, out, "┘") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;") != null);
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

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |found| {
        count += 1;
        pos = found + needle.len;
    }
    return count;
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
    try std.testing.expect(std.mem.indexOf(u8, out, sgr0) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, sgr1) != null);
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
    const occ = countOccurrences(out, sgr0);
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
    try std.testing.expect(std.mem.indexOf(u8, out, sgr7) != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, pattern) != null);
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
        const bullseye_pos = std.mem.indexOf(u8, line, "◎") orelse continue;
        checked = true;
        const prefix = line[0..bullseye_pos];
        const last_sgr_start = std.mem.lastIndexOf(u8, prefix, "\x1b[38;2;") orelse return error.NoSgrBeforeMerge;
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
        const v_pos = std.mem.indexOf(u8, line, "│") orelse continue;
        if (std.mem.indexOf(u8, line, "●") != null) continue;
        if (std.mem.indexOf(u8, line, "◎") != null) continue;
        if (std.mem.indexOf(u8, line, "]") != null) continue;
        checked = true;
        const prefix = line[0..v_pos];
        const last_sgr_start = std.mem.lastIndexOf(u8, prefix, "\x1b[38;2;") orelse return error.NoSgrBeforeConnector;
        const last_sgr = prefix[last_sgr_start..];
        try std.testing.expect(std.mem.startsWith(u8, last_sgr, sgr0));
        try std.testing.expect(std.mem.indexOf(u8, line, sgr1) == null);
    }
    try std.testing.expect(checked);
}
