//! Keeps Mermaid source ownership stable across directive stripping so the
//! parser does at most one full-source copy and returned slices stay valid.

const std = @import("std");
const directive = @import("directive.zig");
const parse_class = @import("parse_class.zig");
const parse_er = @import("parse_er.zig");
const parse_flowchart = @import("parse_flowchart.zig");
const parse_git = @import("parse_git.zig");
const parse_sequence = @import("parse_sequence.zig");
const parse_state = @import("parse_state.zig");
const parse_xychart = @import("parse_xychart.zig");
const types = @import("types.zig");

pub const CompileError = error{
    InvalidMermaid,
    UnsupportedDiagram,
    UnsupportedFeature,
    OutOfMemory,
};

pub const DiagramKind = enum {
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

pub fn diagramConfigKey(kind: DiagramKind) ?[]const u8 {
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

pub const Diagram = union(enum) {
    flowchart: types.MermaidGraph,
    sequence: types.SequenceDiagram,
    class_: types.ClassDiagram,
    state: types.MermaidGraph,
    er: types.ErDiagram,
    git_graph: types.GitGraph,
    xychart: types.XyChart,

    pub fn deinit(self: *Diagram) void {
        switch (self.*) {
            inline else => |*d| d.deinit(),
        }
    }
};

pub fn compile(allocator: std.mem.Allocator, source: []const u8) CompileError!Diagram {
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
    var pending_free: ?[]u8 = switch (stripped) {
        .borrowed => null,
        .owned => |b| b,
    };
    defer if (pending_free) |b| allocator.free(b);

    switch (kind) {
        .flowchart => {
            pending_free = null;
            const data = parse_flowchart.parseSource(allocator, stripped) catch |err| switch (err) {
                error.InvalidMermaid, error.TooManyNodes => return error.InvalidMermaid,
                error.UnsupportedFeature => return error.UnsupportedFeature,
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .{ .flowchart = data };
        },
        .sequence => {
            pending_free = null;
            const data = parse_sequence.parseSource(allocator, stripped) catch |err| switch (err) {
                error.InvalidMermaid, error.TooManyParticipants => return error.InvalidMermaid,
                error.UnsupportedFeature => return error.UnsupportedFeature,
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .{ .sequence = data };
        },
        .class_ => {
            pending_free = null;
            const data = parse_class.parseSource(allocator, stripped) catch |err| switch (err) {
                error.InvalidMermaid, error.TooManyClasses => return error.InvalidMermaid,
                error.UnsupportedFeature => return error.UnsupportedFeature,
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .{ .class_ = data };
        },
        .state => {
            pending_free = null;
            const data = parse_state.parseSource(allocator, stripped) catch |err| switch (err) {
                error.InvalidMermaid, error.TooManyNodes => return error.InvalidMermaid,
                error.UnsupportedFeature => return error.UnsupportedFeature,
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .{ .state = data };
        },
        .er => {
            pending_free = null;
            const data = parse_er.parseSource(allocator, stripped) catch |err| switch (err) {
                error.InvalidMermaid, error.TooManyEntities => return error.InvalidMermaid,
                error.UnsupportedFeature => return error.UnsupportedFeature,
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .{ .er = data };
        },
        .git_graph => {
            pending_free = null;
            const data = parse_git.parseSource(allocator, stripped) catch |err| switch (err) {
                error.InvalidMermaid, error.TooManyBranches => return error.InvalidMermaid,
                error.UnsupportedFeature => return error.UnsupportedFeature,
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .{ .git_graph = data };
        },
        .xychart => {
            pending_free = null;
            const data = parse_xychart.parseSource(allocator, stripped) catch |err| switch (err) {
                error.InvalidMermaid => return error.InvalidMermaid,
                error.UnsupportedFeature => return error.UnsupportedFeature,
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .{ .xychart = data };
        },
        .journey, .gantt, .pie, .mindmap, .timeline, .quadrant, .sankey, .block => return error.UnsupportedDiagram,
        .unknown => return error.InvalidMermaid,
    }
}

test "compile returns flowchart variant for graph TD" {
    var diagram = try compile(std.testing.allocator, "graph TD\n    A --> B\n");
    defer diagram.deinit();
    try std.testing.expect(diagram == .flowchart);
    try std.testing.expectEqual(@as(usize, 2), diagram.flowchart.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), diagram.flowchart.edges.len);
}

test "compile returns sequence variant for sequenceDiagram" {
    var diagram = try compile(std.testing.allocator, "sequenceDiagram\n    Alice->>Bob: hi\n");
    defer diagram.deinit();
    try std.testing.expect(diagram == .sequence);
    try std.testing.expectEqual(@as(usize, 1), diagram.sequence.messages.len);
}

test "compile returns InvalidMermaid for bogus header" {
    try std.testing.expectError(error.InvalidMermaid, compile(std.testing.allocator, "bogus\n"));
}

test "compile returns UnsupportedDiagram for gantt" {
    try std.testing.expectError(error.UnsupportedDiagram, compile(std.testing.allocator, "gantt\n"));
}

test "compile strips init directive and still identifies flowchart" {
    var diagram = try compile(
        std.testing.allocator,
        "%%{init: { \"theme\": \"dark\" }}%%\ngraph TD\n    A --> B\n",
    );
    defer diagram.deinit();
    try std.testing.expect(diagram == .flowchart);
}

test "compile rejects init directive with diagram-specific gitGraph key" {
    try std.testing.expectError(error.UnsupportedFeature, compile(
        std.testing.allocator,
        "%%{init: { \"gitGraph\": { \"mainBranchName\": \"trunk\" } }}%%\ngitGraph\n    commit\n",
    ));
}

test "compile silently strips theme-only init directive for gitGraph" {
    var diagram = try compile(
        std.testing.allocator,
        "%%{init: { \"theme\": \"dark\" }}%%\ngitGraph\n    commit\n",
    );
    defer diagram.deinit();
    try std.testing.expect(diagram == .git_graph);
    try std.testing.expectEqual(@as(usize, 1), diagram.git_graph.commits.len);
    try std.testing.expectEqual(@as(usize, 1), diagram.git_graph.branches.len);
}

test "compile rejects unclosed init directive for gitGraph" {
    try std.testing.expectError(error.InvalidMermaid, compile(
        std.testing.allocator,
        "%%{init:\ngitGraph\n    commit\n",
    ));
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

test "classifyHeader accepts gitGraph with trailing colon forms" {
    try std.testing.expectEqual(DiagramKind.git_graph, classifyHeader("gitGraph\n"));
    try std.testing.expectEqual(DiagramKind.git_graph, classifyHeader("gitGraph:\n"));
    try std.testing.expectEqual(DiagramKind.git_graph, classifyHeader("gitGraph LR:\n"));
    try std.testing.expectEqual(DiagramKind.git_graph, classifyHeader("GITGRAPH\n"));
}
