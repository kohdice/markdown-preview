const std = @import("std");
const types = @import("types.zig");
const width_mod = @import("../term/width.zig");

pub const ParseError = error{
    InvalidMermaid,
    TooManyNodes,
    OutOfMemory,
};

const start_end_id: []const u8 = "[*]";
const start_end_label: []const u8 = "●";
const start_key: []const u8 = "\x00__state_start__";
const end_key: []const u8 = "\x00__state_end__";

const Parser = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(types.Node) = .empty,
    edges: std.ArrayListUnmanaged(types.Edge) = .empty,
    interned: std.StringHashMapUnmanaged(types.NodeId) = .empty,

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

    const nodes = try parser.nodes.toOwnedSlice(allocator);
    errdefer allocator.free(nodes);
    const edges = try parser.edges.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .direction = .top_down,
        .nodes = nodes,
        .edges = edges,
    };
}

fn parseLine(parser: *Parser, line: []const u8) ParseError!void {
    const arrow = "-->";
    const arrow_idx = std.mem.indexOf(u8, line, arrow) orelse return error.InvalidMermaid;

    const lhs_text = std.mem.trimRight(u8, line[0..arrow_idx], " \t");
    var rhs_with_label = std.mem.trimLeft(u8, line[arrow_idx + arrow.len ..], " \t");
    if (lhs_text.len == 0 or rhs_with_label.len == 0) return error.InvalidMermaid;

    var label: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rhs_with_label, ':')) |colon| {
        const label_slice = std.mem.trim(u8, rhs_with_label[colon + 1 ..], " \t");
        if (label_slice.len > 0) {
            try validateLabel(label_slice);
            label = label_slice;
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
        const key = switch (side) {
            .from => start_key,
            .to => end_key,
        };
        return parser.internKeyed(key, start_end_id, start_end_label, .round);
    }
    try validateIdent(text);
    return parser.internKeyed(text, text, text, .stadium);
}

fn validateIdent(text: []const u8) ParseError!void {
    if (text.len == 0) return error.InvalidMermaid;
    for (text, 0..) |b, i| {
        const is_alpha = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
        const is_digit = b >= '0' and b <= '9';
        const is_underscore = b == '_';
        if (i == 0) {
            if (!is_alpha) return error.InvalidMermaid;
        } else {
            if (!is_alpha and !is_digit and !is_underscore) return error.InvalidMermaid;
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

test "shares a single start marker across multiple [*] sources" {
    const source =
        \\stateDiagram-v2
        \\    [*] --> A
        \\    [*] --> B
    ;
    var g = try parseSource(std.testing.allocator, source);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 3), g.nodes.len);
    try std.testing.expectEqual(g.edges[0].from, g.edges[1].from);
}

test "shares a single end marker across multiple [*] targets" {
    const source =
        \\stateDiagram-v2
        \\    A --> [*]
        \\    B --> [*]
    ;
    var g = try parseSource(std.testing.allocator, source);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 3), g.nodes.len);
    try std.testing.expectEqual(g.edges[0].to, g.edges[1].to);
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
