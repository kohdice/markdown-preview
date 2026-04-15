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
const parse_state = @import("parse_state.zig");
const theme = @import("../term/theme.zig");
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
    palette: theme.Palette,
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
    if (std.ascii.eqlIgnoreCase(token, "xychart-beta")) return .xychart;
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
    return switch (classifyHeader(source)) {
        .flowchart => writeFlowchart(writer, allocator, source, opts),
        .sequence => writeSequence(writer, allocator, source, opts),
        .class_ => writeClass(writer, allocator, source, opts),
        .state => writeState(writer, allocator, source, opts),
        .er => writeEr(writer, allocator, source, opts),
        .git_graph => writeGit(writer, allocator, source, opts),
        .journey,
        .gantt,
        .pie,
        .mindmap,
        .timeline,
        .quadrant,
        .xychart,
        .sankey,
        .block,
        => error.UnsupportedDiagram,
        .unknown => error.InvalidMermaid,
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
    try renderFlowGraph(writer, allocator, &graph, opts);
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
    try renderFlowGraph(writer, allocator, &graph, opts);
}

fn renderFlowGraph(
    writer: *std.io.Writer,
    allocator: std.mem.Allocator,
    graph: *const @import("types.zig").FlowGraph,
    opts: Options,
) RenderError!void {
    var layout = layout_flowchart.computeLayout(allocator, graph, opts.ambiguous_width) catch |err| switch (err) {
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

    for (graph.nodes, 0..) |node, i| {
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

    for (graph.edges) |edge| {
        route_mod.routeEdge(allocator, &canvas, &layout, edge, graph.direction, &glyphs, opts.ambiguous_width) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (edge.bidirectional) {
            const src_pos = layout.positions[edge.from];
            const src_top = route_mod.boxTop(&layout, src_pos.row);
            const src_left = route_mod.boxLeft(&layout, src_pos.col);
            const src_cx = src_left + layout.cell_w / 2;
            const src_cy = src_top + layout.cell_h / 2;
            route_mod.paintSourceArrowHead(&canvas, graph.direction, src_top, src_left, src_cx, src_cy, layout, &glyphs);
        }
    }

    route_mod.mergeJunctions(allocator, &canvas, &glyphs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    canvas_mod.writeCanvas(writer, &canvas, opts.wrap_width, opts.ambiguous_width) catch return error.WriteFailed;
}

fn firstMeaningfulLine(source: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "%%")) continue;
        return trimmed;
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

test "writeMermaid returns UnsupportedDiagram for gantt" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .palette = theme.default_palette,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try std.testing.expectError(error.UnsupportedDiagram, writeMermaid(&sink.writer, std.testing.allocator, "gantt\n    title demo\n", opts));
}

test "writeMermaid renders erDiagram" {
    var sink: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();

    const opts: Options = .{
        .enable_ansi = false,
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
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
        .palette = theme.default_palette,
        .wrap_width = null,
        .ambiguous_width = .narrow,
    };

    try writeMermaid(&sink.writer, std.testing.allocator, "graph TD\n    A{Decide} --> B\n", opts);

    const output = sink.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "╱") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "╲") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Decide") != null);
}
