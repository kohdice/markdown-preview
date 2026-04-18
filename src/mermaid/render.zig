const std = @import("std");
const types = @import("types.zig");
const parse_flowchart = @import("parse_flowchart.zig");
const layout_flowchart = @import("layout_flowchart.zig");
const route_mod = @import("route.zig");
const canvas_mod = @import("canvas.zig");
const render_sequence = @import("render_sequence.zig");
const render_class = @import("render_class.zig");
const render_er = @import("render_er.zig");
const render_git = @import("render_git.zig");
const render_xychart = @import("render_xychart.zig");
const parse_state = @import("parse_state.zig");
const directive = @import("directive.zig");
const width_mod = @import("../term/width.zig");

pub const RenderError = error{
    InvalidMermaid,
    UnsupportedDiagram,
    UnsupportedFeature,
    OutOfMemory,
    WriteFailed,
};

pub const Options = struct {
    enable_ansi: bool,
    wrap_width: ?usize,
    ambiguous_width: width_mod.AmbiguousWidth,
};

const DiagramKind = enum {
    flowchart,
    sequence,
    class_,
    state,
    er,
    journey,
    gantt,
    pie,
    mindmap,
    timeline,
    git_graph,
    quadrant,
    xychart,
    sankey,
    block,
    unknown,
};

pub fn classifyHeader(source: []const u8) DiagramKind {
    const line = firstMeaningfulLine(source) orelse return .unknown;
    const raw_token = leadingToken(line);
    const token = std.mem.trimRight(u8, raw_token, ":");

    if (std.ascii.eqlIgnoreCase(token, "graph")) return .flowchart;
    if (std.ascii.eqlIgnoreCase(token, "flowchart")) return .flowchart;
    if (std.ascii.eqlIgnoreCase(token, "sequenceDiagram")) return .sequence;
    if (std.ascii.eqlIgnoreCase(token, "classDiagram")) return .class_;
    if (std.ascii.eqlIgnoreCase(token, "classDiagram-v2")) return .class_;
    if (std.ascii.eqlIgnoreCase(token, "stateDiagram")) return .state;
    if (std.ascii.eqlIgnoreCase(token, "stateDiagram-v2")) return .state;
    if (std.ascii.eqlIgnoreCase(token, "erDiagram")) return .er;
    if (std.ascii.eqlIgnoreCase(token, "journey")) return .journey;
    if (std.ascii.eqlIgnoreCase(token, "gantt")) return .gantt;
    if (std.ascii.eqlIgnoreCase(token, "pie")) return .pie;
    if (std.ascii.eqlIgnoreCase(token, "mindmap")) return .mindmap;
    if (std.ascii.eqlIgnoreCase(token, "timeline")) return .timeline;
    if (std.ascii.eqlIgnoreCase(token, "gitGraph")) return .git_graph;
    if (std.ascii.eqlIgnoreCase(token, "quadrantChart")) return .quadrant;
    if (std.ascii.eqlIgnoreCase(token, "xychart")) return .xychart;
    if (std.ascii.eqlIgnoreCase(token, "sankey-beta")) return .sankey;
    if (std.ascii.eqlIgnoreCase(token, "block-beta")) return .block;

    return .unknown;
}

pub fn writeMermaid(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    const kind = classifyHeader(source);
    var key_buf: [1][]const u8 = undefined;
    const unsafe_keys: []const []const u8 = if (diagramConfigKey(kind)) |k| blk: {
        key_buf[0] = k;
        break :blk key_buf[0..1];
    } else &.{};
    const stripped = directive.stripInitDirectives(allocator, source, unsafe_keys) catch |err| switch (err) {
        error.InvalidDirective => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(stripped);
    return switch (kind) {
        .flowchart => writeFlowchart(writer, allocator, stripped, opts),
        .sequence => writeSequence(writer, allocator, stripped, opts),
        .class_ => writeClass(writer, allocator, stripped, opts),
        .state => writeState(writer, allocator, stripped, opts),
        .er => writeEr(writer, allocator, stripped, opts),
        .git_graph => writeGit(writer, allocator, stripped, opts),
        .xychart => writeXyChart(writer, allocator, stripped, opts),
        .journey,
        .gantt,
        .pie,
        .mindmap,
        .timeline,
        .quadrant,
        .sankey,
        .block,
        => error.UnsupportedDiagram,
        .unknown => error.InvalidMermaid,
    };
}

fn diagramConfigKey(kind: DiagramKind) ?[]const u8 {
    return switch (kind) {
        .flowchart => "\"flowchart\"",
        .sequence => "\"sequence\"",
        .class_ => "\"class\"",
        .state => "\"state\"",
        .er => "\"er\"",
        .git_graph => "\"gitGraph\"",
        .journey => "\"journey\"",
        .gantt => "\"gantt\"",
        .pie => "\"pie\"",
        .mindmap => "\"mindmap\"",
        .timeline => "\"timeline\"",
        .quadrant => "\"quadrantChart\"",
        .xychart => "\"xyChart\"",
        .sankey => "\"sankey\"",
        .block => "\"block\"",
        .unknown => null,
    };
}

fn writeClass(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    render_class.writeClass(writer, allocator, source, .{
        .wrap_width = opts.wrap_width,
        .ambiguous_width = opts.ambiguous_width,
        .enable_ansi = opts.enable_ansi,
    }) catch |err| switch (err) {
        error.InvalidMermaid => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
    };
}

fn writeEr(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    render_er.writeEr(writer, allocator, source, .{
        .wrap_width = opts.wrap_width,
        .ambiguous_width = opts.ambiguous_width,
    }) catch |err| switch (err) {
        error.InvalidMermaid => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
    };
}

fn writeGit(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    render_git.writeGit(writer, allocator, source, .{
        .wrap_width = opts.wrap_width,
        .ambiguous_width = opts.ambiguous_width,
        .enable_ansi = opts.enable_ansi,
    }) catch |err| switch (err) {
        error.InvalidMermaid => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
    };
}

fn writeXyChart(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    render_xychart.writeXyChart(writer, allocator, source, .{
        .wrap_width = opts.wrap_width,
        .ambiguous_width = opts.ambiguous_width,
        .enable_ansi = opts.enable_ansi,
    }) catch |err| switch (err) {
        error.InvalidMermaid => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
    };
}

fn writeSequence(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    render_sequence.writeSequence(writer, allocator, source, .{
        .wrap_width = opts.wrap_width,
        .ambiguous_width = opts.ambiguous_width,
    }) catch |err| switch (err) {
        error.InvalidMermaid => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
    };
}

fn writeState(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    var graph = parse_state.parseSource(allocator, source) catch |err| switch (err) {
        error.InvalidMermaid => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.TooManyNodes => return error.InvalidMermaid,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer graph.deinit();
    try renderMermaidGraph(writer, allocator, &graph, opts);
}

fn writeFlowchart(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    source: []const u8,
    opts: Options,
) RenderError!void {
    var graph = parse_flowchart.parseSource(allocator, source) catch |err| switch (err) {
        error.InvalidMermaid => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.TooManyNodes => return error.InvalidMermaid,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer graph.deinit();
    try renderMermaidGraph(writer, allocator, &graph, opts);
}

fn renderMermaidGraph(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    graph: *const @import("types.zig").MermaidGraph,
    opts: Options,
) RenderError!void {
    // BT is laid out as TD and flipped at the canvas level.
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

    // Outer frames sit further from nodes so nested frames do not collide.
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

fn firstMeaningfulLine(source: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < source.len) {
        const nl = std.mem.indexOfScalarPos(u8, source, cursor, '\n');
        const line_end = nl orelse source.len;
        const line = source[cursor..line_end];
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len != 0 and std.mem.startsWith(u8, trimmed, "%%{")) {
            const after = std.mem.indexOf(u8, source[cursor..], "}%%") orelse return null;
            cursor += after + 3;
            if (cursor < source.len and source[cursor] == '\r') cursor += 1;
            if (cursor < source.len and source[cursor] == '\n') cursor += 1;
            continue;
        }

        const advance = if (nl != null) line_end + 1 else line_end;
        if (trimmed.len != 0 and !std.mem.startsWith(u8, trimmed, "%%")) return trimmed;
        cursor = advance;
    }
    return null;
}

fn leadingToken(line: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    return line[0..end];
}

test "classifyHeader recognises graph and flowchart as flowchart" {
    try std.testing.expectEqual(DiagramKind.flowchart, classifyHeader("graph TD\n"));
    try std.testing.expectEqual(DiagramKind.flowchart, classifyHeader("flowchart LR\n"));
    try std.testing.expectEqual(DiagramKind.flowchart, classifyHeader("GRAPH TD\n"));
}

test "classifyHeader recognises sequenceDiagram as sequence" {
    try std.testing.expectEqual(DiagramKind.sequence, classifyHeader("sequenceDiagram\n"));
}

test "classifyHeader recognises classDiagram as class_" {
    try std.testing.expectEqual(DiagramKind.class_, classifyHeader("classDiagram\n"));
}

test "classifyHeader treats unknown types as unknown" {
    try std.testing.expectEqual(DiagramKind.unknown, classifyHeader("totallyBogusDiagram\n"));
    try std.testing.expectEqual(DiagramKind.unknown, classifyHeader(""));
    try std.testing.expectEqual(DiagramKind.unknown, classifyHeader("\n\n  \n"));
}

test "classifyHeader skips leading comments and blank lines" {
    const source =
        \\%% this is a mermaid comment
        \\
        \\graph TD
        \\    A --> B
    ;
    try std.testing.expectEqual(DiagramKind.flowchart, classifyHeader(source));
}

test "classifyHeader recognises bare xychart as xychart" {
    try std.testing.expectEqual(DiagramKind.xychart, classifyHeader("xychart\nbar [1, 2]\n"));
}

test "classifyHeader recognises case-insensitive XYChart as xychart" {
    try std.testing.expectEqual(DiagramKind.xychart, classifyHeader("XYChart\nbar [1, 2]\n"));
}

test "classifyHeader rejects legacy xychart-beta as unknown" {
    try std.testing.expectEqual(DiagramKind.unknown, classifyHeader("xychart-beta\nbar [1, 2]\n"));
}

test "writeMermaid accepts bare xychart source end-to-end" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const opts: Options = .{
        .wrap_width = null,
        .ambiguous_width = .narrow,
        .enable_ansi = false,
    };
    try writeMermaid(&sink.writer, std.testing.allocator, "xychart\nbar [1, 2, 3]\n", opts);
    try std.testing.expect(sink.writer.buffered().len > 0);
}

test "writeMermaid strips multi-line init directive before flowchart" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator,
        \\%%{init: {
        \\  "theme": "dark"
        \\}}%%
        \\graph TD
        \\    A --> B
    , opts);

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "▼") != null);
}

test "writeMermaid keeps %%{...}%% inside sequence message label" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator,
        \\sequenceDiagram
        \\    Alice->>Bob: %%{x}%%
    , opts);

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "%%{x}%%") != null);
}

test "writeMermaid keeps %%{...}%% inside flowchart node label" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator,
        \\graph TD
        \\    A[%%{x}%%] --> B
    , opts);

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "%%{x}%%") != null);
}

test "writeMermaid silently strips init config scoped to a different diagram" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator,
        \\%%{init: { "flowchart": { "curve": "basis" } }}%%
        \\sequenceDiagram
        \\    Alice->>Bob: hi
    , opts);

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hi") != null);
}

test "writeMermaid rejects init with diagram-specific config as UnsupportedFeature" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try std.testing.expectError(error.UnsupportedFeature, writeMermaid(
        &sink.writer,
        std.testing.allocator,
        "%%{init: { \"gitGraph\": { \"mainBranchName\": \"trunk\" } }}%%\ngitGraph\n    commit\n",
        opts,
    ));
}

test "writeMermaid rejects init xyChart config as UnsupportedFeature" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };
    try std.testing.expectError(error.UnsupportedFeature, writeMermaid(
        &sink.writer,
        std.testing.allocator,
        "%%{init: { \"xyChart\": { \"width\": 9999 } } }%%\nxychart\nbar [1, 2]\n",
        opts,
    ));
}

test "writeMermaid accepts init theme-only directive before xychart" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };
    try writeMermaid(
        &sink.writer,
        std.testing.allocator,
        "%%{init: { \"theme\": \"dark\" }}%%\nxychart\nbar [1, 2]\n",
        opts,
    );
    try std.testing.expect(sink.writer.buffered().len > 0);
}

test "writeMermaid treats lowercase xychart key as ordinary config (no UnsupportedFeature)" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };
    try writeMermaid(
        &sink.writer,
        std.testing.allocator,
        "%%{init: { \"xychart\": { \"width\": 9999 } } }%%\nxychart\nbar [1, 2]\n",
        opts,
    );
    try std.testing.expect(sink.writer.buffered().len > 0);
}

test "writeMermaid returns UnsupportedDiagram for gantt" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try std.testing.expectError(error.UnsupportedDiagram, writeMermaid(&sink.writer, std.testing.allocator, "gantt\n    title demo\n", opts));
}

test "writeMermaid renders graph BT as canvas vertical flip of graph TD" {
    const alloc = std.testing.allocator;
    var sink_td: std.io.Writer.Allocating = .init(alloc);
    defer sink_td.deinit();
    var sink_bt: std.io.Writer.Allocating = .init(alloc);
    defer sink_bt.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink_td.writer, alloc, "graph TD\n    A --> B --> C\n", opts);
    try writeMermaid(&sink_bt.writer, alloc, "graph BT\n    A --> B --> C\n", opts);

    const td_out = sink_td.writer.buffered();
    const bt_out = sink_bt.writer.buffered();

    // BT output must be byte-for-byte the canvas-level vertical flip of TD:
    // lines reversed plus directional glyph remap.
    const td_flipped = try flipOutputForTest(alloc, td_out);
    defer alloc.free(td_flipped);
    try std.testing.expectEqualStrings(td_flipped, bt_out);
}

fn flipOutputForTest(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |l| try lines.append(alloc, l);
    std.mem.reverse([]const u8, lines.items);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (lines.items, 0..) |line, i| {
        var view = std.unicode.Utf8View.init(line) catch return error.InvalidUtf8;
        var lit = view.iterator();
        while (lit.nextCodepoint()) |cp| {
            const mapped = testFlipGlyph(cp);
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(mapped, &enc) catch continue;
            try buf.appendSlice(alloc, enc[0..n]);
        }
        if (i + 1 < lines.items.len) try buf.append(alloc, '\n');
    }
    return try buf.toOwnedSlice(alloc);
}

fn testFlipGlyph(cp: u21) u21 {
    return switch (cp) {
        '┌' => '└',
        '└' => '┌',
        '┐' => '┘',
        '┘' => '┐',
        '┬' => '┴',
        '┴' => '┬',
        '▲' => '▼',
        '▼' => '▲',
        '╭' => '╰',
        '╰' => '╭',
        '╮' => '╯',
        '╯' => '╮',
        '╔' => '╚',
        '╚' => '╔',
        '╗' => '╝',
        '╝' => '╗',
        '╱' => '╲',
        '╲' => '╱',
        '^' => 'v',
        'v' => '^',
        '/' => '\\',
        '\\' => '/',
        else => cp,
    };
}

test "writeMermaid produces identical output for graph RL and graph LR" {
    var sink_lr: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink_lr.deinit();
    var sink_rl: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink_rl.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink_lr.writer, std.testing.allocator, "graph LR\n    A --> B --> C\n", opts);
    try writeMermaid(&sink_rl.writer, std.testing.allocator, "graph RL\n    A --> B --> C\n", opts);

    try std.testing.expectEqualStrings(sink_lr.writer.buffered(), sink_rl.writer.buffered());
}

test "writeMermaid draws frame and title around flowchart subgraph" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator,
        \\graph TD
        \\    subgraph inner
        \\        A --> B
        \\    end
    , opts);
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "└") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "in") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "B") != null);
}

test "writeMermaid drops edges to empty composite state" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator,
        \\stateDiagram-v2
        \\    [*] --> Empty
        \\    state Empty {
        \\    }
    , opts);
    const out = sink.writer.buffered();
    try std.testing.expect(out.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "├") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┤") == null);
}

test "writeMermaid draws composite state frame without routing to invisible node" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator,
        \\stateDiagram-v2
        \\    [*] --> Outer
        \\    state Outer {
        \\        [*] --> Inner
        \\    }
        \\    Outer --> [*]
    , opts);
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Outer") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Inner") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") != null);
    // External transitions attach to the frame boundary via a tee glyph rather
    // than the invisible composite node.
    try std.testing.expect(std.mem.indexOf(u8, out, "├") != null or std.mem.indexOf(u8, out, "┤") != null);
}

test "writeMermaid renders erDiagram" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "erDiagram\n    CUSTOMER ||--o{ ORDER : places\n", opts);
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "CUSTOMER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ORDER") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "places") != null);
}

test "writeMermaid renders gitGraph with LR colon header" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "gitGraph LR:\n    commit\n    commit\n", opts);
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "●") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[main]") != null);
}

test "writeMermaid returns UnsupportedFeature for cherry-pick" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try std.testing.expectError(error.UnsupportedFeature, writeMermaid(
        &sink.writer,
        std.testing.allocator,
        "gitGraph\n    commit\n    cherry-pick id: \"a1\"\n",
        opts,
    ));
}

test "writeMermaid returns UnsupportedFeature for erDiagram direction" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try std.testing.expectError(error.UnsupportedFeature, writeMermaid(
        &sink.writer,
        std.testing.allocator,
        "erDiagram\n    direction LR\n    A ||--|| B : r\n",
        opts,
    ));
}

test "classifyHeader accepts gitGraph with trailing colon forms" {
    try std.testing.expectEqual(DiagramKind.git_graph, classifyHeader("gitGraph\n"));
    try std.testing.expectEqual(DiagramKind.git_graph, classifyHeader("gitGraph:\n"));
    try std.testing.expectEqual(DiagramKind.git_graph, classifyHeader("gitGraph LR:\n"));
    try std.testing.expectEqual(DiagramKind.git_graph, classifyHeader("GITGRAPH\n"));
}

test "writeMermaid renders stateDiagram-v2" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "stateDiagram-v2\n    [*] --> Idle\n    Idle --> Running\n    Running --> [*]\n", opts);
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Idle") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Running") != null);
}

test "writeMermaid renders sequence diagram" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "sequenceDiagram\n    Alice->>Bob: hi\n", opts);
    const out = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hi") != null);
}

test "writeMermaid returns InvalidMermaid for unknown diagram type" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try std.testing.expectError(error.InvalidMermaid, writeMermaid(&sink.writer, std.testing.allocator, "bogus\n", opts));
}

test "writeMermaid renders single-edge flowchart" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "graph TD\n    A --> B\n", opts);

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "▼") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "┌") != null);
}

test "writeMermaid renders labeled edge with label text in output" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "graph TD\n    A --> B\n    B -->|yes| C\n", opts);

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "yes") != null);
}

test "writeMermaid keeps Unicode glyphs in wide ambiguous mode" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .wide,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "graph TD\n    A --> B\n", opts);

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "─") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "+") == null);
}

test "writeMermaid LR direction renders horizontally" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "graph LR\n    A --> B\n", opts);

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "►") != null);
}

test "writeMermaid empty flowchart emits nothing" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "graph TD\n", opts);
    try std.testing.expectEqualStrings("", sink.writer.buffered());
}

test "writeMermaid flowchart --- edge does not emit an arrow head" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "graph TD\n    A --- B\n", opts);

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "B") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "▼") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "▲") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "│") != null);
}

test "writeMermaid stateDiagram renders rounded corners for [*] and stadium states" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "stateDiagram-v2\n    [*] --> Idle\n    Idle --> [*]\n", opts);

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "╭") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "╮") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "╰") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "╯") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "●") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Idle") != null);
}

test "writeMermaid diamond node renders with diamond corners" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "graph TD\n    A{Decide} --> B\n", opts);

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "╱") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "╲") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Decide") != null);
}

test "writeMermaid dispatches xychart to writeXyChart" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };
    try writeMermaid(&sink.writer, std.testing.allocator, "xychart\ntitle \"Demo\"\n", opts);
    try std.testing.expect(std.mem.indexOf(u8, sink.writer.buffered(), "Demo") != null);
}

test "writeMermaid no longer returns UnsupportedDiagram for xychart" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };
    try writeMermaid(&sink.writer, std.testing.allocator, "xychart\n", opts);
}

test "writeMermaid still returns UnsupportedDiagram for other diagrams" {
    const opts: Options = .{
        .enable_ansi = false,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };
    const headers = [_][]const u8{
        "gantt\n",
        "journey\n",
        "pie\n",
        "mindmap\n",
        "timeline\n",
        "quadrantChart\n",
        "sankey-beta\n",
        "block-beta\n",
    };
    for (headers) |h| {
        var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
        defer sink.deinit();
        try std.testing.expectError(error.UnsupportedDiagram, writeMermaid(&sink.writer, std.testing.allocator, h, opts));
    }
}
