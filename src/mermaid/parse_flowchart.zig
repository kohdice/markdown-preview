const std = @import("std");
const types = @import("types.zig");
const width_mod = @import("../term/width.zig");

pub const ParseError = error{
    InvalidMermaid,
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

fn parseContentLine(parser: *Parser, trimmed: []const u8) ParseError!void {
    const first_arrow = findArrow(trimmed) orelse {
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

        const next_arrow = findArrow(after_arrow);
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
};

fn findArrow(text: []const u8) ?ArrowInfo {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '-') continue;
        if (i > 0 and text[i - 1] == '-') continue;

        var dash_end = i;
        while (dash_end < text.len and text[dash_end] == '-') : (dash_end += 1) {}
        const dash_count = dash_end - i;
        const has_gt = dash_end < text.len and text[dash_end] == '>';
        const op_end = if (has_gt) dash_end + 1 else dash_end;

        const style: types.EdgeStyle = if (has_gt and dash_count == 2)
            .arrow
        else if (!has_gt and dash_count == 3)
            .line
        else
            continue;

        var scan = op_end;
        while (scan < text.len and (text[scan] == ' ' or text[scan] == '\t')) : (scan += 1) {}

        if (scan < text.len and text[scan] == '|') {
            scan += 1;
            const label_start = scan;
            while (scan < text.len and text[scan] != '|') : (scan += 1) {}
            if (scan >= text.len) return null;
            const label = text[label_start..scan];
            scan += 1;
            return .{
                .start = i,
                .len = scan - i,
                .style = style,
                .label = label,
            };
        }

        return .{
            .start = i,
            .len = op_end - i,
            .style = style,
            .label = null,
        };
    }
    return null;
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
            if (i == ident_start) {
                if (!is_alpha) return error.InvalidMermaid;
                continue;
            }
            if (!is_alpha and !is_digit and !is_underscore) break;
        }
        if (i == ident_start) return error.InvalidMermaid;
        const id_text = text[ident_start..i];

        var shape: types.NodeShape = .implicit;
        var label: []const u8 = id_text;
        if (i < text.len and (text[i] == '[' or text[i] == '{')) {
            const open = text[i];
            const close: u8 = if (open == '[') ']' else '}';
            const s: types.NodeShape = if (open == '[') .rect else .diamond;
            i += 1;
            const label_start = i;
            while (i < text.len and text[i] != close) : (i += 1) {}
            if (i >= text.len) return error.InvalidMermaid;
            const label_text = text[label_start..i];
            i += 1;
            try validateLabel(label_text);
            shape = s;
            label = label_text;
        }

        const id = try parser.internNode(id_text);
        if (shape != .implicit) parser.updateNode(id, shape, label);
        try ids.append(parser.allocator, id);

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
