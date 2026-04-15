const std = @import("std");
const types = @import("types.zig");
const width_mod = @import("../term/width.zig");

pub const ParseError = error{
    InvalidMermaid,
    UnsupportedFeature,
    TooManyNodes,
    OutOfMemory,
};

const start_end_id: []const u8 = "[*]";
const start_end_label: []const u8 = "●";

const Parser = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(types.Node) = .empty,
    edges: std.ArrayListUnmanaged(types.Edge) = .empty,
    interned: std.StringHashMapUnmanaged(types.NodeId) = .empty,
    owned_strings: std.ArrayListUnmanaged([]u8) = .empty,
    composite_depth: u32 = 0,

    fn internKeyed(
        self: *Parser,
        key: []const u8,
        id_text: []const u8,
        label: []const u8,
        shape: types.NodeShape,
    ) ParseError!types.NodeId {
        const gop = try self.interned.getOrPut(self.allocator, key);
        if (gop.found_existing) return gop.value_ptr.*;
        if (self.nodes.items.len >= types.max_nodes) return error.TooManyNodes;
        const new_id: types.NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .id = new_id,
            .id_text = id_text,
            .label = label,
            .shape = shape,
        });
        gop.value_ptr.* = new_id;
        return new_id;
    }
};

fn isDisplayDependent(cp: u21) bool {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return true;
    return width_mod.displayWidth(buf[0..len], .narrow) == 0;
}

fn validateLabel(label: []const u8) ParseError!void {
    var view = std.unicode.Utf8View.init(label) catch return error.InvalidMermaid;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (isDisplayDependent(cp)) return error.InvalidMermaid;
    }
}

pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) ParseError!types.FlowGraph {
    var parser: Parser = .{ .allocator = allocator };
    defer parser.interned.deinit(allocator);
    errdefer parser.nodes.deinit(allocator);
    errdefer parser.edges.deinit(allocator);
    errdefer {
        for (parser.owned_strings.items) |s| allocator.free(s);
        parser.owned_strings.deinit(allocator);
    }

    var header_seen = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        const stripped_cr = std.mem.trimRight(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, stripped_cr, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "%%")) continue;

        if (!header_seen) {
            if (!std.ascii.eqlIgnoreCase(trimmed, "stateDiagram") and
                !std.ascii.eqlIgnoreCase(trimmed, "stateDiagram-v2"))
                return error.InvalidMermaid;
            header_seen = true;
            continue;
        }

        try parseLine(&parser, trimmed);
    }

    if (!header_seen) return error.InvalidMermaid;

    if (parser.composite_depth != 0) return error.InvalidMermaid;

    const nodes = try parser.nodes.toOwnedSlice(allocator);
    errdefer allocator.free(nodes);
    const edges = try parser.edges.toOwnedSlice(allocator);
    errdefer allocator.free(edges);
    const owned_strings = try parser.owned_strings.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .direction = .top_down,
        .nodes = nodes,
        .edges = edges,
        .owned_strings = owned_strings,
    };
}

fn normalizeLabel(parser: *Parser, text: []const u8) ParseError![]const u8 {
    const out = types.normalizeBrTags(parser.allocator, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (out.ptr == text.ptr) return text;
    const mutable: []u8 = @constCast(out);
    try parser.owned_strings.append(parser.allocator, mutable);
    return out;
}

fn parseLine(parser: *Parser, line: []const u8) ParseError!void {
    if (parser.composite_depth > 0) {
        if (std.mem.eql(u8, line, "}")) {
            parser.composite_depth -= 1;
            return;
        }
        if (std.mem.endsWith(u8, line, "{")) {
            parser.composite_depth += 1;
            return;
        }
        return;
    }

    if (isSilentlySkipped(line)) return;
    if (isUnsupportedStatement(line)) return error.UnsupportedFeature;

    if (std.mem.startsWith(u8, line, "state ") or std.mem.eql(u8, line, "state")) {
        return parseStateDeclaration(parser, std.mem.trimLeft(u8, line[5..], " \t"));
    }

    if (std.mem.indexOf(u8, line, "-->")) |arrow_idx| {
        return parseTransition(parser, line, arrow_idx);
    }

    if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
        return parseStateDescription(parser, line, colon);
    }

    return error.InvalidMermaid;
}

fn isUnsupportedStatement(line: []const u8) bool {
    const keywords = [_][]const u8{
        "direction", "link ", "click ",
    };
    for (keywords) |kw| {
        if (std.ascii.startsWithIgnoreCase(line, kw)) return true;
    }
    return false;
}

fn isSilentlySkipped(line: []const u8) bool {
    const prefixes = [_][]const u8{
        "note ",
    };
    for (prefixes) |kw| {
        if (std.ascii.startsWithIgnoreCase(line, kw)) return true;
    }
    return false;
}

fn parseStateDeclaration(parser: *Parser, rest: []const u8) ParseError!void {
    const trimmed = std.mem.trim(u8, rest, " \t");

    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '{') {
        parser.composite_depth += 1;
        return;
    }

    if (trimmed.len > 0 and trimmed[0] == '"') {
        var j: usize = 1;
        while (j < trimmed.len and trimmed[j] != '"') : (j += 1) {}
        if (j >= trimmed.len) return error.InvalidMermaid;
        const raw_label = trimmed[1..j];
        const after = std.mem.trim(u8, trimmed[j + 1 ..], " \t");
        const as_kw = "as ";
        if (!std.mem.startsWith(u8, after, as_kw)) return error.InvalidMermaid;
        const ident = std.mem.trim(u8, after[as_kw.len..], " \t");
        try validateIdent(ident);
        try validateLabel(raw_label);
        const label = try normalizeLabel(parser, raw_label);
        const id = try parser.internKeyed(ident, ident, label, .stadium);
        parser.nodes.items[id].label = label;
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "<<") and std.mem.endsWith(u8, trimmed, ">>")) {
        return;
    }

    return;
}

fn parseStateDescription(parser: *Parser, line: []const u8, colon: usize) ParseError!void {
    const ident = std.mem.trim(u8, line[0..colon], " \t");
    const raw_label = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (ident.len == 0 or raw_label.len == 0) return error.InvalidMermaid;
    if (std.mem.eql(u8, ident, start_end_id)) return error.InvalidMermaid;
    try validateIdent(ident);
    try validateLabel(raw_label);
    const label = try normalizeLabel(parser, raw_label);
    const id = try parser.internKeyed(ident, ident, label, .stadium);
    parser.nodes.items[id].label = label;
}

fn parseTransition(parser: *Parser, line: []const u8, arrow_idx: usize) ParseError!void {
    const arrow = "-->";
    const lhs_text = std.mem.trimRight(u8, line[0..arrow_idx], " \t");
    var rhs_with_label = std.mem.trimLeft(u8, line[arrow_idx + arrow.len ..], " \t");
    if (lhs_text.len == 0 or rhs_with_label.len == 0) return error.InvalidMermaid;

    var label: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rhs_with_label, ':')) |colon| {
        const label_slice = std.mem.trim(u8, rhs_with_label[colon + 1 ..], " \t");
        if (label_slice.len > 0) {
            try validateLabel(label_slice);
            label = try normalizeLabel(parser, label_slice);
        }
        rhs_with_label = std.mem.trimRight(u8, rhs_with_label[0..colon], " \t");
    }

    const from_id = try internState(parser, lhs_text, .from);
    const to_id = try internState(parser, rhs_with_label, .to);

    try parser.edges.append(parser.allocator, .{
        .from = from_id,
        .to = to_id,
        .label = label,
        .style = .arrow,
    });
}

const StateSide = enum { from, to };

fn internState(parser: *Parser, text: []const u8, side: StateSide) ParseError!types.NodeId {
    if (std.mem.eql(u8, text, start_end_id)) {
        const counter = parser.nodes.items.len;
        var buf: [48]u8 = undefined;
        const key_slice = std.fmt.bufPrint(&buf, "\x00__state_{s}_{d}__", .{ sideTag(side), counter }) catch unreachable;
        const owned = try parser.allocator.dupe(u8, key_slice);
        try parser.owned_strings.append(parser.allocator, owned);
        return parser.internKeyed(owned, start_end_id, start_end_label, .round);
    }
    try validateIdent(text);
    return parser.internKeyed(text, text, text, .stadium);
}

fn sideTag(side: StateSide) []const u8 {
    return switch (side) {
        .from => "start",
        .to => "end",
    };
}

fn validateIdent(text: []const u8) ParseError!void {
    if (text.len == 0) return error.InvalidMermaid;
    for (text, 0..) |b, i| {
        const is_alpha = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
        const is_digit = b >= '0' and b <= '9';
        const is_underscore = b == '_';
        const is_hyphen = b == '-' and i > 0 and i + 1 < text.len;
        if (i == 0) {
            if (!is_alpha) return error.InvalidMermaid;
        } else {
            if (!is_alpha and !is_digit and !is_underscore and !is_hyphen) return error.InvalidMermaid;
        }
    }
}

test "parses stateDiagram-v2 header" {
    var g = try parseSource(std.testing.allocator, "stateDiagram-v2\n");
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 0), g.nodes.len);
}

test "parses transitions with distinct start and end markers" {
    const source =
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    Idle --> Running
        \\    Running --> [*]
    ;
    var g = try parseSource(std.testing.allocator, source);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 4), g.nodes.len);
    try std.testing.expectEqual(@as(usize, 3), g.edges.len);
    try std.testing.expectEqualStrings(start_end_id, g.nodes[0].id_text);
    try std.testing.expectEqualStrings(start_end_id, g.nodes[3].id_text);
    try std.testing.expect(g.edges[0].from != g.edges[2].to);
}

test "creates distinct [*] nodes per occurrence" {
    const source =
        \\stateDiagram-v2
        \\    [*] --> A
        \\    [*] --> B
        \\    A --> [*]
        \\    B --> [*]
    ;
    var g = try parseSource(std.testing.allocator, source);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 6), g.nodes.len);
    try std.testing.expect(g.edges[0].from != g.edges[1].from);
    try std.testing.expect(g.edges[2].to != g.edges[3].to);
}

test "parses transition labels" {
    var g = try parseSource(std.testing.allocator,
        \\stateDiagram-v2
        \\    Idle --> Running : start
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 1), g.edges.len);
    try std.testing.expectEqualStrings("start", g.edges[0].label.?);
}

test "rejects missing stateDiagram header" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator, "[*] --> Idle\n"));
}

test "parses aliased state declaration" {
    var g = try parseSource(std.testing.allocator,
        \\stateDiagram-v2
        \\    state "Processing request" as Busy
        \\    Busy --> [*]
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.nodes.len);
    try std.testing.expectEqualStrings("Busy", g.nodes[0].id_text);
    try std.testing.expectEqualStrings("Processing request", g.nodes[0].label);
}

test "parses inline state description (S : text)" {
    var g = try parseSource(std.testing.allocator,
        \\stateDiagram-v2
        \\    Idle : Waiting for input
        \\    Idle --> Running
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.nodes.len);
    try std.testing.expectEqualStrings("Waiting for input", g.nodes[0].label);
}

test "silently skips composite state blocks (inner content ignored)" {
    var g = try parseSource(std.testing.allocator,
        \\stateDiagram-v2
        \\    [*] --> Outer
        \\    state Outer {
        \\        [*] --> Inner
        \\    }
        \\    Outer --> [*]
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.edges.len);
}

test "normalises <br> in transition label" {
    var g = try parseSource(std.testing.allocator,
        \\stateDiagram-v2
        \\    A --> B : step<br>one<br/>two
    );
    defer g.deinit();
    try std.testing.expectEqualStrings("step one two", g.edges[0].label.?);
}

test "rejects direction line as unsupported feature" {
    try std.testing.expectError(error.UnsupportedFeature, parseSource(std.testing.allocator,
        \\stateDiagram-v2
        \\    direction LR
        \\    [*] --> Idle
    ));
}

test "silently skips note lines" {
    var g = try parseSource(std.testing.allocator,
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    note left of Idle : a note
        \\    Idle --> [*]
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.edges.len);
}

test "silently skips init directive" {
    var g = try parseSource(std.testing.allocator,
        \\stateDiagram-v2
        \\    %%{init: {"theme": "dark"}}%%
        \\    [*] --> Idle
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 1), g.edges.len);
}
