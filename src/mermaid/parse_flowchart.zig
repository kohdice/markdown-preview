const std = @import("std");
const types = @import("types.zig");
const width_mod = @import("../term/width.zig");

pub const ParseError = error{
    InvalidMermaid,
    UnsupportedFeature,
    TooManyNodes,
    OutOfMemory,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(types.Node) = .empty,
    edges: std.ArrayListUnmanaged(types.Edge) = .empty,
    interned: std.StringHashMapUnmanaged(types.NodeId) = .empty,

    fn internNode(self: *Parser, id_text: []const u8) ParseError!types.NodeId {
        const gop = try self.interned.getOrPut(self.allocator, id_text);
        if (gop.found_existing) return gop.value_ptr.*;

        if (self.nodes.items.len >= types.max_nodes) return error.TooManyNodes;
        const new_id: types.NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .id = new_id,
            .id_text = id_text,
            .label = id_text,
            .shape = .implicit,
        });
        gop.value_ptr.* = new_id;
        return new_id;
    }

    fn updateNode(self: *Parser, id: types.NodeId, shape: types.NodeShape, label: []const u8) void {
        var node = &self.nodes.items[id];
        node.shape = shape;
        node.label = label;
    }
};

pub fn isDisplayDependent(cp: u21) bool {
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

    var direction: ?types.Direction = null;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        const stripped_cr = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, stripped_cr, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "%%")) continue;

        if (direction == null) {
            direction = try parseHeader(trimmed);
            continue;
        }

        try parseContentLine(&parser, trimmed);
    }

    const dir = direction orelse return error.InvalidMermaid;

    const nodes = try parser.nodes.toOwnedSlice(allocator);
    errdefer allocator.free(nodes);
    const edges = try parser.edges.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .direction = dir,
        .nodes = nodes,
        .edges = edges,
    };
}

fn parseHeader(line: []const u8) ParseError!types.Direction {
    var i: usize = 0;
    const kw_start = i;
    while (i < line.len) : (i += 1) {
        const b = line[i];
        const is_alpha = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
        if (!is_alpha) break;
    }
    const keyword = line[kw_start..i];
    if (!std.ascii.eqlIgnoreCase(keyword, "graph") and !std.ascii.eqlIgnoreCase(keyword, "flowchart")) {
        return error.InvalidMermaid;
    }

    if (i >= line.len or (line[i] != ' ' and line[i] != '\t')) return error.InvalidMermaid;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    const dir_start = i;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
    const dir_text = line[dir_start..i];
    const direction = types.Direction.fromString(dir_text) orelse return error.InvalidMermaid;

    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i != line.len) return error.InvalidMermaid;
    return direction;
}

fn isUnsupportedStatement(line: []const u8) bool {
    _ = line;
    return false;
}

fn isSilentlySkipped(line: []const u8) bool {
    const prefixes = [_][]const u8{
        "subgraph",
        "classDef",
        "class ",
        "style ",
        "linkStyle",
        "direction",
        "click",
    };
    for (prefixes) |kw| {
        if (std.ascii.startsWithIgnoreCase(line, kw)) return true;
    }
    if (std.ascii.eqlIgnoreCase(line, "end")) return true;
    return false;
}

fn parseContentLine(parser: *Parser, trimmed: []const u8) ParseError!void {
    if (isSilentlySkipped(trimmed)) return;

    if (isUnsupportedStatement(trimmed)) return error.UnsupportedFeature;

    const first_arrow = (try findArrow(trimmed)) orelse {
        const ids = try parseNodeSpecList(parser, trimmed);
        parser.allocator.free(ids);
        return;
    };

    const lhs_text = std.mem.trimRight(u8, trimmed[0..first_arrow.start], " \t");
    if (lhs_text.len == 0) return error.InvalidMermaid;

    var current_ids = try parseNodeSpecList(parser, lhs_text);
    errdefer parser.allocator.free(current_ids);

    var current_arrow = first_arrow;
    var after_arrow = trimmed[first_arrow.start + first_arrow.len ..];

    while (true) {
        if (current_arrow.label) |l| try validateLabel(l);

        const next_arrow = try findArrow(after_arrow);
        const rhs_text = if (next_arrow) |na|
            std.mem.trim(u8, after_arrow[0..na.start], " \t")
        else
            std.mem.trimLeft(u8, after_arrow, " \t");
        if (rhs_text.len == 0) return error.InvalidMermaid;

        const rhs_ids = try parseNodeSpecList(parser, rhs_text);
        errdefer parser.allocator.free(rhs_ids);

        for (current_ids) |from| {
            for (rhs_ids) |to| {
                try parser.edges.append(parser.allocator, .{
                    .from = from,
                    .to = to,
                    .label = current_arrow.label,
                    .style = current_arrow.style,
                    .bidirectional = current_arrow.bidirectional,
                });
            }
        }

        parser.allocator.free(current_ids);
        current_ids = rhs_ids;

        const na = next_arrow orelse break;
        current_arrow = na;
        after_arrow = after_arrow[na.start + na.len ..];
    }

    parser.allocator.free(current_ids);
}

const ArrowInfo = struct {
    start: usize,
    len: usize,
    style: types.EdgeStyle,
    label: ?[]const u8,
    bidirectional: bool = false,
};

fn findArrowAfter(text: []const u8, from: usize) ArrowFindError!?struct {
    len: usize,
    style: types.EdgeStyle,
    label: ?[]const u8,
} {
    if (from >= text.len) return null;
    const info = (try findArrow(text[from..])) orelse return null;
    if (info.start != 0) return null;
    return .{ .len = info.len, .style = info.style, .label = info.label };
}

const ArrowFindError = ParseError;

fn findTextLabelArrow(text: []const u8) ArrowFindError!?ArrowInfo {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        const style: types.EdgeStyle = if (c == '-' and i + 1 < text.len and text[i + 1] == '-')
            .arrow
        else if (c == '-' and i + 1 < text.len and text[i + 1] == '.')
            .dotted
        else if (c == '=' and i + 1 < text.len and text[i + 1] == '=')
            .thick
        else
            continue;
        if (i > 0 and (text[i - 1] == c or text[i - 1] == '.' or text[i - 1] == '-' or text[i - 1] == '=')) continue;

        const open_len: usize = 2;
        if (i + open_len >= text.len or (text[i + open_len] != ' ' and text[i + open_len] != '\t')) continue;

        const label_start = i + open_len;
        var j = label_start;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
        const closer_left: u8 = switch (style) {
            .arrow => '-',
            .dotted => '.',
            .thick => '=',
            else => unreachable,
        };
        var label_end: ?usize = null;
        var closer_end: ?usize = null;
        var scan = j;
        while (scan + 3 < text.len) : (scan += 1) {
            if (text[scan] != ' ') continue;
            if (text[scan + 1] != closer_left) continue;
            const mid_expected: u8 = if (style == .dotted) '-' else closer_left;
            if (text[scan + 2] != mid_expected) continue;
            if (text[scan + 3] != '>') continue;
            label_end = scan;
            closer_end = scan + 4;
            break;
        }
        const le = label_end orelse continue;
        const ce = closer_end orelse continue;
        const label = std.mem.trim(u8, text[j..le], " \t");
        if (label.len == 0) continue;

        return .{
            .start = i,
            .len = ce - i,
            .style = style,
            .label = label,
        };
    }
    return null;
}

fn findArrow(text: []const u8) ArrowFindError!?ArrowInfo {
    if (try findTextLabelArrow(text)) |info| return info;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];

        if (c == '<' and i + 1 < text.len and (text[i + 1] == '-' or text[i + 1] == '=')) {
            if (try findArrowAfter(text, i + 1)) |inner| {
                return .{
                    .start = i,
                    .len = inner.len + 1,
                    .style = inner.style,
                    .label = inner.label,
                    .bidirectional = true,
                };
            }
            continue;
        }

        if (c == '-') {
            if (i > 0 and (text[i - 1] == '-' or text[i - 1] == '.')) continue;

            var scan = i;
            if (scan + 2 <= text.len and text[scan + 1] == '.') {
                scan += 2;
                if (scan < text.len and text[scan] == '-') {
                    scan += 1;
                    if (scan < text.len and text[scan] == '>') {
                        return try maybeAttachLabel(text, i, scan + 1, .dotted);
                    }
                    return try maybeAttachLabel(text, i, scan, .dotted_line);
                }
                continue;
            }

            var dash_end = scan;
            while (dash_end < text.len and text[dash_end] == '-') : (dash_end += 1) {}
            const dash_count = dash_end - scan;
            const has_gt = dash_end < text.len and text[dash_end] == '>';

            if (has_gt and dash_count == 2) {
                return try maybeAttachLabel(text, i, dash_end + 1, .arrow);
            }
            if (!has_gt and dash_count == 3) {
                return try maybeAttachLabel(text, i, dash_end, .line);
            }
            continue;
        }

        if (c == '=') {
            if (i > 0 and text[i - 1] == '=') continue;

            var eq_end = i;
            while (eq_end < text.len and text[eq_end] == '=') : (eq_end += 1) {}
            const eq_count = eq_end - i;
            const has_gt = eq_end < text.len and text[eq_end] == '>';

            if (has_gt and eq_count == 2) {
                return try maybeAttachLabel(text, i, eq_end + 1, .thick);
            }
            if (!has_gt and eq_count == 3) {
                return try maybeAttachLabel(text, i, eq_end, .thick_line);
            }
            continue;
        }
    }
    return null;
}

fn maybeAttachLabel(text: []const u8, start: usize, op_end: usize, style: types.EdgeStyle) ArrowFindError!ArrowInfo {
    var scan = op_end;
    while (scan < text.len and (text[scan] == ' ' or text[scan] == '\t')) : (scan += 1) {}

    if (scan < text.len and text[scan] == '|') {
        scan += 1;
        const label_start = scan;
        while (scan < text.len and text[scan] != '|') : (scan += 1) {}
        if (scan >= text.len) return error.InvalidMermaid;
        const label = text[label_start..scan];
        scan += 1;
        return .{
            .start = start,
            .len = scan - start,
            .style = style,
            .label = label,
        };
    }

    return .{
        .start = start,
        .len = op_end - start,
        .style = style,
        .label = null,
    };
}

const ShapeMatch = struct { shape: types.NodeShape, label: []const u8, end: usize };

fn tryParseShape(text: []const u8, start: usize) ParseError!?ShapeMatch {
    if (start >= text.len) return null;
    const c = text[start];

    if (c == '[') {
        if (start + 1 < text.len) {
            const next = text[start + 1];
            if (next == '[') {
                const body = try matchBracketed(text, start + 1, '[', ']', .subroutine) orelse return null;
                if (body.end >= text.len or text[body.end] != ']') return error.InvalidMermaid;
                return .{ .shape = .subroutine, .label = body.label, .end = body.end + 1 };
            }
            if (next == '(') {
                const body = try matchBracketed(text, start + 1, '(', ')', .cylinder) orelse return null;
                if (body.end >= text.len or text[body.end] != ']') return error.InvalidMermaid;
                return .{ .shape = .cylinder, .label = body.label, .end = body.end + 1 };
            }
            if (next == '/') {
                return try matchUntilPair(text, start + 2, '\\', ']', .trapezoid);
            }
            if (next == '\\') {
                return try matchUntilPair(text, start + 2, '/', ']', .inv_trapezoid);
            }
        }
        return try matchBracketed(text, start, '[', ']', .rect);
    }

    if (c == '(') {
        if (start + 1 < text.len) {
            const next = text[start + 1];
            if (next == '[') {
                const body = try matchBracketed(text, start + 1, '[', ']', .stadium) orelse return null;
                if (body.end >= text.len or text[body.end] != ')') return error.InvalidMermaid;
                return .{ .shape = .stadium, .label = body.label, .end = body.end + 1 };
            }
            if (next == '(') {
                if (start + 2 < text.len and text[start + 2] == '(') {
                    return try matchTripleParens(text, start + 3);
                }
                return try matchCircle(text, start + 2);
            }
        }
        return try matchBracketed(text, start, '(', ')', .round);
    }

    if (c == '{') {
        if (start + 1 < text.len and text[start + 1] == '{') {
            return try matchHexagon(text, start + 2);
        }
        return try matchBracketed(text, start, '{', '}', .diamond);
    }

    if (c == '>') {
        var j = start + 1;
        const label_start = j;
        while (j < text.len and text[j] != ']') : (j += 1) {}
        if (j >= text.len) return error.InvalidMermaid;
        return .{ .shape = .asymmetric, .label = text[label_start..j], .end = j + 1 };
    }

    return null;
}

fn matchTripleParens(text: []const u8, label_start_arg: usize) ParseError!?ShapeMatch {
    var j = label_start_arg;
    while (j + 2 < text.len) : (j += 1) {
        if (text[j] == ')' and text[j + 1] == ')' and text[j + 2] == ')') {
            return .{ .shape = .double_circle, .label = text[label_start_arg..j], .end = j + 3 };
        }
    }
    return error.InvalidMermaid;
}

fn matchHexagon(text: []const u8, label_start_arg: usize) ParseError!?ShapeMatch {
    var j = label_start_arg;
    while (j + 1 < text.len) : (j += 1) {
        if (text[j] == '}' and text[j + 1] == '}') {
            return .{ .shape = .hexagon, .label = text[label_start_arg..j], .end = j + 2 };
        }
    }
    return error.InvalidMermaid;
}

fn matchUntilPair(text: []const u8, label_start_arg: usize, first: u8, second: u8, shape: types.NodeShape) ParseError!?ShapeMatch {
    var j = label_start_arg;
    while (j + 1 < text.len) : (j += 1) {
        if (text[j] == first and text[j + 1] == second) {
            return .{ .shape = shape, .label = text[label_start_arg..j], .end = j + 2 };
        }
    }
    return error.InvalidMermaid;
}

fn matchBracketed(text: []const u8, start: usize, open: u8, close: u8, shape: types.NodeShape) ParseError!?ShapeMatch {
    if (start >= text.len or text[start] != open) return null;
    var j = start + 1;
    const label_start = j;
    while (j < text.len and text[j] != close) : (j += 1) {}
    if (j >= text.len) return error.InvalidMermaid;
    return .{ .shape = shape, .label = text[label_start..j], .end = j + 1 };
}

fn matchCircle(text: []const u8, start: usize) ParseError!?ShapeMatch {
    var j = start;
    while (j + 1 < text.len) : (j += 1) {
        if (text[j] == ')' and text[j + 1] == ')') {
            return .{ .shape = .round, .label = text[start..j], .end = j + 2 };
        }
    }
    return error.InvalidMermaid;
}

fn parseNodeSpecList(parser: *Parser, text: []const u8) ParseError![]types.NodeId {
    var ids: std.ArrayListUnmanaged(types.NodeId) = .empty;
    errdefer ids.deinit(parser.allocator);

    var i: usize = 0;
    while (true) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
        if (i >= text.len) break;

        const ident_start = i;
        while (i < text.len) : (i += 1) {
            const b = text[i];
            const is_alpha = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
            const is_digit = b >= '0' and b <= '9';
            const is_underscore = b == '_';
            const is_hyphen = blk: {
                if (b != '-' or i == ident_start) break :blk false;
                if (i + 1 >= text.len) break :blk false;
                const nb = text[i + 1];
                const nb_alpha = (nb >= 'a' and nb <= 'z') or (nb >= 'A' and nb <= 'Z');
                const nb_digit = nb >= '0' and nb <= '9';
                break :blk nb_alpha or nb_digit or nb == '_';
            };
            if (i == ident_start) {
                if (!is_alpha) return error.InvalidMermaid;
                continue;
            }
            if (!is_alpha and !is_digit and !is_underscore and !is_hyphen) break;
        }
        if (i == ident_start) return error.InvalidMermaid;
        const id_text = text[ident_start..i];

        var shape: types.NodeShape = .implicit;
        var label: []const u8 = id_text;
        if (i < text.len) {
            if (try tryParseShape(text, i)) |sh| {
                try validateLabel(sh.label);
                shape = sh.shape;
                label = sh.label;
                i = sh.end;
            }
        }

        const id = try parser.internNode(id_text);
        if (shape != .implicit) parser.updateNode(id, shape, label);
        try ids.append(parser.allocator, id);

        if (i + 2 < text.len and text[i] == ':' and text[i + 1] == ':' and text[i + 2] == ':') {
            i += 3;
            while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '&') : (i += 1) {}
        }

        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}

        if (i < text.len and text[i] == '&') {
            i += 1;
            continue;
        }
        if (i < text.len) return error.InvalidMermaid;
        break;
    }

    if (ids.items.len == 0) return error.InvalidMermaid;
    return try ids.toOwnedSlice(parser.allocator);
}

test "parses round node A(Start)" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A(Start) --> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqual(types.NodeShape.round, graph.nodes[0].shape);
    try std.testing.expectEqualStrings("Start", graph.nodes[0].label);
}

test "parses stadium node A([Start])" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A([Start]) --> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.NodeShape.stadium, graph.nodes[0].shape);
    try std.testing.expectEqualStrings("Start", graph.nodes[0].label);
}

test "parses circle node A((Start))" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A((Start)) --> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.NodeShape.round, graph.nodes[0].shape);
    try std.testing.expectEqualStrings("Start", graph.nodes[0].label);
}

test "parses dotted arrow -.->" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A -.-> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.EdgeStyle.dotted, graph.edges[0].style);
}

test "parses thick arrow ==>" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A ==> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.EdgeStyle.thick, graph.edges[0].style);
}

test "parses subroutine shape A[[sub]]" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A[[sub]] --> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.NodeShape.subroutine, graph.nodes[0].shape);
    try std.testing.expectEqualStrings("sub", graph.nodes[0].label);
}

test "parses hexagon shape A{{hex}}" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A{{hex}} --> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.NodeShape.hexagon, graph.nodes[0].shape);
    try std.testing.expectEqualStrings("hex", graph.nodes[0].label);
}

test "parses cylinder shape A[(db)]" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A[(db)] --> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.NodeShape.cylinder, graph.nodes[0].shape);
    try std.testing.expectEqualStrings("db", graph.nodes[0].label);
}

test "parses asymmetric shape A>asym]" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A>asym] --> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.NodeShape.asymmetric, graph.nodes[0].shape);
    try std.testing.expectEqualStrings("asym", graph.nodes[0].label);
}

test "parses trapezoid shape A[/trap\\]" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A[/trap\\] --> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.NodeShape.trapezoid, graph.nodes[0].shape);
}

test "parses text-embedded label -- Yes -->" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A -- Yes --> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
    try std.testing.expectEqualStrings("Yes", graph.edges[0].label.?);
    try std.testing.expectEqual(types.EdgeStyle.arrow, graph.edges[0].style);
}

test "parses text-embedded label -. Maybe .->" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A -. Maybe .-> B\n");
    defer graph.deinit();
    try std.testing.expectEqualStrings("Maybe", graph.edges[0].label.?);
    try std.testing.expectEqual(types.EdgeStyle.dotted, graph.edges[0].style);
}

test "parses text-embedded label == Sure ==>" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A == Sure ==> B\n");
    defer graph.deinit();
    try std.testing.expectEqualStrings("Sure", graph.edges[0].label.?);
    try std.testing.expectEqual(types.EdgeStyle.thick, graph.edges[0].style);
}

test "parses double-circle shape A(((X)))" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A(((X))) --> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.NodeShape.double_circle, graph.nodes[0].shape);
    try std.testing.expectEqualStrings("X", graph.nodes[0].label);
}

test "parses bidirectional arrow <-->" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A <--> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
    try std.testing.expect(graph.edges[0].bidirectional);
    try std.testing.expectEqual(types.EdgeStyle.arrow, graph.edges[0].style);
}

test "parses bidirectional dotted <-.->" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A <-.-> B\n");
    defer graph.deinit();
    try std.testing.expect(graph.edges[0].bidirectional);
    try std.testing.expectEqual(types.EdgeStyle.dotted, graph.edges[0].style);
}

test "parses bidirectional thick <==>" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A <==> B\n");
    defer graph.deinit();
    try std.testing.expect(graph.edges[0].bidirectional);
    try std.testing.expectEqual(types.EdgeStyle.thick, graph.edges[0].style);
}

test "parses no-arrow dotted (-.-) as dotted_line" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A -.- B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.EdgeStyle.dotted_line, graph.edges[0].style);
}

test "parses no-arrow thick (===) as thick_line" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A === B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.EdgeStyle.thick_line, graph.edges[0].style);
}

test "silently skips click statements" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    A --> B
        \\    click A "https://example.com"
    );
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
}

test "silently skips subgraph / end" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    subgraph outer
        \\        A --> B
        \\    end
        \\    B --> C
    );
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.edges.len);
}

test "silently skips classDef / style / :::className" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    classDef warn fill:#f00
        \\    A[Alert]:::warn --> B
        \\    style B fill:#0f0
    );
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
    try std.testing.expectEqualStrings("Alert", graph.nodes[0].label);
}

test "parses graph TD header" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.Direction.top_down, graph.direction);
    try std.testing.expectEqual(@as(usize, 0), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), graph.edges.len);
}

test "parses flowchart LR header" {
    var graph = try parseSource(std.testing.allocator, "flowchart LR\n    A --> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(types.Direction.left_right, graph.direction);
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
}

test "parses rectangular node declaration" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A[Start]\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.nodes.len);
    try std.testing.expectEqual(types.NodeShape.rect, graph.nodes[0].shape);
    try std.testing.expectEqualStrings("Start", graph.nodes[0].label);
    try std.testing.expectEqualStrings("A", graph.nodes[0].id_text);
}

test "parses diamond node declaration" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    B{Decision}\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.nodes.len);
    try std.testing.expectEqual(types.NodeShape.diamond, graph.nodes[0].shape);
    try std.testing.expectEqualStrings("Decision", graph.nodes[0].label);
}

test "parses simple edge A --> B" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A --> B\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
    try std.testing.expectEqual(types.EdgeStyle.arrow, graph.edges[0].style);
    try std.testing.expectEqual(@as(?[]const u8, null), graph.edges[0].label);
}

test "parses edge with no spaces A-->B" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A-->B\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
    try std.testing.expectEqualStrings("A", graph.nodes[graph.edges[0].from].id_text);
    try std.testing.expectEqualStrings("B", graph.nodes[graph.edges[0].to].id_text);
}

test "parses unlabeled line A---B" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A---B\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
    try std.testing.expectEqual(types.EdgeStyle.line, graph.edges[0].style);
}

test "parses unlabeled line A --- B" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A --- B\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
    try std.testing.expectEqual(types.EdgeStyle.line, graph.edges[0].style);
}

test "parses labeled edge A -->|yes| B" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A -->|yes| B\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
    try std.testing.expectEqual(types.EdgeStyle.arrow, graph.edges[0].style);
    try std.testing.expectEqualStrings("yes", graph.edges[0].label.?);
}

test "parses labeled edge with space before pipe: A --> |yes| B" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A --> |yes| B\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
    try std.testing.expectEqualStrings("yes", graph.edges[0].label.?);
}

test "parses labeled edge without any spaces A-->|yes|B" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A-->|yes|B\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
    try std.testing.expectEqualStrings("yes", graph.edges[0].label.?);
}

test "fans out multi-decl A & B --> C" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A & B --> C\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 3), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), graph.edges.len);
}

test "fans out multi-decl without spaces around & A&B-->C" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A&B-->C\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 3), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), graph.edges.len);
}

test "parses chained edge A --> B --> C" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A --> B --> C\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 3), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), graph.edges.len);
    try std.testing.expectEqualStrings("A", graph.nodes[graph.edges[0].from].id_text);
    try std.testing.expectEqualStrings("B", graph.nodes[graph.edges[0].to].id_text);
    try std.testing.expectEqualStrings("B", graph.nodes[graph.edges[1].from].id_text);
    try std.testing.expectEqualStrings("C", graph.nodes[graph.edges[1].to].id_text);
}

test "parses chained edge with labels A -->|x| B -->|y| C" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A -->|x| B -->|y| C\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.edges.len);
    try std.testing.expectEqualStrings("x", graph.edges[0].label.?);
    try std.testing.expectEqualStrings("y", graph.edges[1].label.?);
}

test "fans out cross product of A & B --> C & D" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A & B --> C & D\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 4), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 4), graph.edges.len);
}

test "ignores comment lines" {
    const source =
        \\graph TD
        \\%% top-level comment
        \\    %% indented comment
        \\    A --> B
        \\%% trailing comment
    ;
    var graph = try parseSource(std.testing.allocator, source);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
}

test "rejects missing direction with InvalidMermaid" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator, "graph\n    A --> B\n"));
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator, "graph XX\n"));
}

test "interns nodes referenced before declaration" {
    const source =
        \\graph TD
        \\    A --> B
        \\    A[First]
    ;
    var graph = try parseSource(std.testing.allocator, source);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqualStrings("First", graph.nodes[0].label);
    try std.testing.expectEqualStrings("A", graph.nodes[0].id_text);
    try std.testing.expectEqualStrings("B", graph.nodes[1].label);
}

test "last-write-wins for redefined node" {
    const source =
        \\graph TD
        \\    A[First]
        \\    A[Second]
        \\    A --> B
    ;
    var graph = try parseSource(std.testing.allocator, source);
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqualStrings("Second", graph.nodes[0].label);
}

test "rejects label containing ZWJ emoji sequence" {
    try std.testing.expectError(
        error.InvalidMermaid,
        parseSource(std.testing.allocator, "graph TD\n    A[\u{1F468}\u{200D}\u{1F469}] --> B\n"),
    );
}

test "rejects label containing combining mark" {
    try std.testing.expectError(
        error.InvalidMermaid,
        parseSource(std.testing.allocator, "graph TD\n    A[e\u{0301}] --> B\n"),
    );
}

test "rejects label containing emoji variation selector" {
    try std.testing.expectError(
        error.InvalidMermaid,
        parseSource(std.testing.allocator, "graph TD\n    A[\u{2764}\u{FE0F}] --> B\n"),
    );
}

test "rejects label containing emoji skin tone modifier" {
    try std.testing.expectError(
        error.InvalidMermaid,
        parseSource(std.testing.allocator, "graph TD\n    A[\u{1F44D}\u{1F3FB}] --> B\n"),
    );
}

test "rejects label containing BOM, ZWSP, ZWNJ" {
    try std.testing.expectError(
        error.InvalidMermaid,
        parseSource(std.testing.allocator, "graph TD\n    A[foo\u{FEFF}bar] --> B\n"),
    );
    try std.testing.expectError(
        error.InvalidMermaid,
        parseSource(std.testing.allocator, "graph TD\n    A[foo\u{200B}bar] --> B\n"),
    );
    try std.testing.expectError(
        error.InvalidMermaid,
        parseSource(std.testing.allocator, "graph TD\n    A[foo\u{200C}bar] --> B\n"),
    );
}

test "isDisplayDependent covers every codepoint for which displayWidth returns 0" {
    try std.testing.expect(isDisplayDependent(0x200D));
    try std.testing.expect(isDisplayDependent(0x200B));
    try std.testing.expect(isDisplayDependent(0x200C));
    try std.testing.expect(isDisplayDependent(0xFEFF));
    try std.testing.expect(isDisplayDependent(0xFE0F));
    try std.testing.expect(isDisplayDependent(0x0301));
    try std.testing.expect(isDisplayDependent(0x1F3FB));
    try std.testing.expect(isDisplayDependent(0x1F3FF));

    try std.testing.expect(!isDisplayDependent('A'));
    try std.testing.expect(!isDisplayDependent(' '));
    try std.testing.expect(!isDisplayDependent(0x65E5));
    try std.testing.expect(!isDisplayDependent(0x1F680));
}

test "accepts plain CJK and single-codepoint emoji" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A[日本語] --> B[\u{1F680}]\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqualStrings("日本語", graph.nodes[0].label);

    const source = "graph TD\n    A[日本語] --> B[\u{1F680}]\n";
    const label_slice = graph.nodes[0].label;
    const label_addr = @intFromPtr(label_slice.ptr);
    const source_start = @intFromPtr(source.ptr);
    const source_end = source_start + source.len;
    try std.testing.expect(label_addr >= source_start and label_addr < source_end);
}

test "parseSource rejects empty source" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator, "\n\n  \n"));
}

test "parseSource handles trailing newline and CRLF" {
    var graph = try parseSource(std.testing.allocator, "graph TD\r\n    A --> B\r\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
}
