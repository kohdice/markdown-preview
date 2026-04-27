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

const DiagramTag = std.meta.Tag(Diagram);

pub const PaintTarget = enum {
    graph,
    sequence,
    class_,
    er,
    git_graph,
    xychart,
};

const DiagramSpec = struct {
    kind: DiagramKind,
    headers: []const []const u8,
    config_key: ?[]const u8,
    compile_tag: ?DiagramTag,
    paint_target: ?PaintTarget,
    parser: type,
};

pub const diagram_specs = [_]DiagramSpec{
    .{
        .kind = .flowchart,
        .headers = &.{ "graph", "flowchart" },
        .config_key = "\"flowchart\"",
        .compile_tag = .flowchart,
        .paint_target = .graph,
        .parser = parse_flowchart,
    },
    .{
        .kind = .sequence,
        .headers = &.{"sequenceDiagram"},
        .config_key = "\"sequence\"",
        .compile_tag = .sequence,
        .paint_target = .sequence,
        .parser = parse_sequence,
    },
    .{
        .kind = .class_,
        .headers = &.{ "classDiagram", "classDiagram-v2" },
        .config_key = "\"class\"",
        .compile_tag = .class_,
        .paint_target = .class_,
        .parser = parse_class,
    },
    .{
        .kind = .state,
        .headers = &.{ "stateDiagram", "stateDiagram-v2" },
        .config_key = "\"state\"",
        .compile_tag = .state,
        .paint_target = .graph,
        .parser = parse_state,
    },
    .{
        .kind = .er,
        .headers = &.{"erDiagram"},
        .config_key = "\"er\"",
        .compile_tag = .er,
        .paint_target = .er,
        .parser = parse_er,
    },
    .{
        .kind = .journey,
        .headers = &.{"journey"},
        .config_key = "\"journey\"",
        .compile_tag = null,
        .paint_target = null,
        .parser = void,
    },
    .{
        .kind = .gantt,
        .headers = &.{"gantt"},
        .config_key = "\"gantt\"",
        .compile_tag = null,
        .paint_target = null,
        .parser = void,
    },
    .{
        .kind = .pie,
        .headers = &.{"pie"},
        .config_key = "\"pie\"",
        .compile_tag = null,
        .paint_target = null,
        .parser = void,
    },
    .{
        .kind = .mindmap,
        .headers = &.{"mindmap"},
        .config_key = "\"mindmap\"",
        .compile_tag = null,
        .paint_target = null,
        .parser = void,
    },
    .{
        .kind = .timeline,
        .headers = &.{"timeline"},
        .config_key = "\"timeline\"",
        .compile_tag = null,
        .paint_target = null,
        .parser = void,
    },
    .{
        .kind = .git_graph,
        .headers = &.{"gitGraph"},
        .config_key = "\"gitGraph\"",
        .compile_tag = .git_graph,
        .paint_target = .git_graph,
        .parser = parse_git,
    },
    .{
        .kind = .quadrant,
        .headers = &.{"quadrantChart"},
        .config_key = "\"quadrantChart\"",
        .compile_tag = null,
        .paint_target = null,
        .parser = void,
    },
    .{
        .kind = .xychart,
        .headers = &.{"xychart"},
        .config_key = "\"xyChart\"",
        .compile_tag = .xychart,
        .paint_target = .xychart,
        .parser = parse_xychart,
    },
    .{
        .kind = .sankey,
        .headers = &.{"sankey-beta"},
        .config_key = "\"sankey\"",
        .compile_tag = null,
        .paint_target = null,
        .parser = void,
    },
    .{
        .kind = .block,
        .headers = &.{"block-beta"},
        .config_key = "\"block\"",
        .compile_tag = null,
        .paint_target = null,
        .parser = void,
    },
};

fn validateDiagramSpecs() void {
    comptime var kind_counts = [_]u8{0} ** std.meta.tags(DiagramKind).len;
    comptime var tag_counts = [_]u8{0} ** std.meta.tags(DiagramTag).len;

    inline for (diagram_specs, 0..) |spec, spec_index| {
        if (spec.kind == .unknown) {
            @compileError("diagram_specs must not contain the sentinel kind 'unknown'");
        }
        if (spec.headers.len == 0) {
            @compileError("diagram_specs entry '" ++ @tagName(spec.kind) ++ "' must declare at least one header alias");
        }
        if (spec.config_key == null) {
            @compileError("diagram_specs entry '" ++ @tagName(spec.kind) ++ "' must declare a directive config key");
        }

        kind_counts[@intFromEnum(spec.kind)] += 1;

        if (spec.compile_tag) |compile_tag| {
            tag_counts[@intFromEnum(compile_tag)] += 1;
            if (spec.parser == void) {
                @compileError("diagram_specs entry '" ++ @tagName(spec.kind) ++ "' must provide a parser when compile_tag is set");
            }
            if (spec.paint_target == null) {
                @compileError("diagram_specs entry '" ++ @tagName(spec.kind) ++ "' must provide a paint target when compile_tag is set");
            }
        } else {
            if (spec.parser != void) {
                @compileError("diagram_specs entry '" ++ @tagName(spec.kind) ++ "' must not provide a parser when compile_tag is null");
            }
            if (spec.paint_target != null) {
                @compileError("diagram_specs entry '" ++ @tagName(spec.kind) ++ "' must not provide a paint target when compile_tag is null");
            }
        }

        inline for (spec.headers) |header| {
            if (header.len == 0) {
                @compileError("diagram_specs entry '" ++ @tagName(spec.kind) ++ "' must not contain empty header aliases");
            }

            inline for (diagram_specs, 0..) |other_spec, other_index| {
                if (other_index <= spec_index) continue;
                inline for (other_spec.headers) |other_header| {
                    if (std.ascii.eqlIgnoreCase(header, other_header)) {
                        @compileError(std.fmt.comptimePrint(
                            "diagram_specs header alias '{s}' is duplicated between '{s}' and '{s}'",
                            .{ header, @tagName(spec.kind), @tagName(other_spec.kind) },
                        ));
                    }
                }
            }
        }
    }

    inline for (std.meta.tags(DiagramKind)) |kind| {
        if (kind == .unknown) continue;
        const count = kind_counts[@intFromEnum(kind)];
        if (count != 1) {
            @compileError(std.fmt.comptimePrint(
                "diagram_specs must include exactly one entry for kind '{s}' (found {})",
                .{ @tagName(kind), count },
            ));
        }
    }

    inline for (std.meta.tags(DiagramTag)) |tag| {
        const count = tag_counts[@intFromEnum(tag)];
        if (count != 1) {
            @compileError(std.fmt.comptimePrint(
                "diagram_specs must include exactly one compile_tag for diagram tag '{s}' (found {})",
                .{ @tagName(tag), count },
            ));
        }
    }
}

comptime {
    validateDiagramSpecs();
}

pub fn diagramConfigKey(kind: DiagramKind) ?[]const u8 {
    inline for (diagram_specs) |spec| {
        if (kind == spec.kind) return spec.config_key;
    }
    return null;
}

pub fn classifyHeader(source: []const u8) DiagramKind {
    const line = firstMeaningfulLine(source) orelse return .unknown;
    const raw_token = leadingToken(line);
    const token = std.mem.trimEnd(u8, raw_token, ":");

    inline for (diagram_specs) |spec| {
        inline for (spec.headers) |header| {
            if (std.ascii.eqlIgnoreCase(token, header)) return spec.kind;
        }
    }

    return .unknown;
}

fn normalizeParseError(comptime Parser: type, err: Parser.ParseError) CompileError {
    if (Parser == parse_flowchart or Parser == parse_state) {
        return switch (err) {
            error.InvalidMermaid, error.TooManyNodes => error.InvalidMermaid,
            error.UnsupportedFeature => error.UnsupportedFeature,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    if (Parser == parse_sequence) {
        return switch (err) {
            error.InvalidMermaid, error.TooManyParticipants => error.InvalidMermaid,
            error.UnsupportedFeature => error.UnsupportedFeature,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    if (Parser == parse_class) {
        return switch (err) {
            error.InvalidMermaid, error.TooManyClasses => error.InvalidMermaid,
            error.UnsupportedFeature => error.UnsupportedFeature,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    if (Parser == parse_er) {
        return switch (err) {
            error.InvalidMermaid, error.TooManyEntities => error.InvalidMermaid,
            error.UnsupportedFeature => error.UnsupportedFeature,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    if (Parser == parse_git) {
        return switch (err) {
            error.InvalidMermaid, error.TooManyBranches => error.InvalidMermaid,
            error.UnsupportedFeature => error.UnsupportedFeature,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    if (Parser == parse_xychart) {
        return switch (err) {
            error.InvalidMermaid => error.InvalidMermaid,
            error.UnsupportedFeature => error.UnsupportedFeature,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    @compileError("missing parse error normalization for parser '" ++ @typeName(Parser) ++ "'");
}

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

    inline for (diagram_specs) |spec| {
        if (kind == spec.kind) {
            if (spec.compile_tag) |compile_tag| {
                pending_free = null;
                const data = spec.parser.parseSource(allocator, stripped) catch |err| {
                    return normalizeParseError(spec.parser, err);
                };
                return @unionInit(Diagram, @tagName(compile_tag), data);
            }

            return error.UnsupportedDiagram;
        }
    }

    return error.InvalidMermaid;
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

test "compile returns expected variants for every implemented diagram kind" {
    const cases = [_]struct {
        source: []const u8,
        expected_tag: std.meta.Tag(Diagram),
    }{
        .{ .source = "graph TD\n    A --> B\n", .expected_tag = .flowchart },
        .{ .source = "sequenceDiagram\n    Alice->>Bob: hi\n", .expected_tag = .sequence },
        .{ .source = "classDiagram-v2\n    class Animal\n", .expected_tag = .class_ },
        .{ .source = "stateDiagram-v2\n    [*] --> Idle\n", .expected_tag = .state },
        .{ .source = "erDiagram\n    CUSTOMER\n", .expected_tag = .er },
        .{ .source = "gitGraph:\n    commit\n", .expected_tag = .git_graph },
        .{ .source = "xychart\n    bar [1, 2, 3]\n", .expected_tag = .xychart },
    };

    for (cases) |case| {
        var diagram = try compile(std.testing.allocator, case.source);
        defer diagram.deinit();
        try std.testing.expectEqual(case.expected_tag, std.meta.activeTag(diagram));
    }
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

test "classifyHeader recognises every implemented diagram alias" {
    const cases = [_]struct {
        source: []const u8,
        expected: DiagramKind,
    }{
        .{ .source = "graph TD\n", .expected = .flowchart },
        .{ .source = "flowchart LR\n", .expected = .flowchart },
        .{ .source = "sequenceDiagram\n", .expected = .sequence },
        .{ .source = "classDiagram-v2\n", .expected = .class_ },
        .{ .source = "stateDiagram-v2\n", .expected = .state },
        .{ .source = "erDiagram\n", .expected = .er },
        .{ .source = "gitGraph:\n", .expected = .git_graph },
        .{ .source = "xychart\n", .expected = .xychart },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, classifyHeader(case.source));
    }
}

test "diagramConfigKey returns expected keys for implemented kinds and null for unknown" {
    const cases = [_]struct {
        kind: DiagramKind,
        expected: ?[]const u8,
    }{
        .{ .kind = .flowchart, .expected = "\"flowchart\"" },
        .{ .kind = .sequence, .expected = "\"sequence\"" },
        .{ .kind = .class_, .expected = "\"class\"" },
        .{ .kind = .state, .expected = "\"state\"" },
        .{ .kind = .er, .expected = "\"er\"" },
        .{ .kind = .git_graph, .expected = "\"gitGraph\"" },
        .{ .kind = .xychart, .expected = "\"xyChart\"" },
        .{ .kind = .unknown, .expected = null },
    };

    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected orelse "", diagramConfigKey(case.kind) orelse "");
        try std.testing.expectEqual(case.expected == null, diagramConfigKey(case.kind) == null);
    }
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
