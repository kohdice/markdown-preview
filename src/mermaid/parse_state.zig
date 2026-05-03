const std = @import("std");
const source_mod = @import("source.zig");
const types = @import("types.zig");
const unicode_letter = @import("unicode_letter.zig");
const label_mod = @import("label.zig");

pub const ParseError = error{
    InvalidMermaid,
    UnsupportedFeature,
    TooManyNodes,
    OutOfMemory,
};

const start_end_id: []const u8 = "[*]";
const start_end_label: []const u8 = "●";

const BuildingComposite = struct {
    id_text: []const u8,
    title: ?[]const u8 = null,
    direction: ?types.Direction = null,
    representative_node: ?types.NodeId = null,
    node_ids: std.ArrayList(types.NodeId) = .empty,
    edge_indices: std.ArrayList(u32) = .empty,
    children: std.ArrayList(BuildingComposite) = .empty,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(types.Node) = .empty,
    edges: std.ArrayList(types.Edge) = .empty,
    interned: std.StringHashMapUnmanaged(types.NodeId) = .empty,
    owned_strings: std.ArrayList([]u8) = .empty,
    ctx_stack: std.ArrayList(BuildingComposite) = .empty,
    root_subgraphs: std.ArrayList(BuildingComposite) = .empty,
    link_styles: std.ArrayList(types.LinkStyle) = .empty,
    touched: std.ArrayList(types.NodeId) = .empty,
    globally_owned: std.AutoHashMapUnmanaged(types.NodeId, void) = .empty,

    fn internKeyed(
        self: *Parser,
        key: []const u8,
        id_text: []const u8,
        label: []const u8,
        shape: types.NodeShape,
    ) ParseError!types.NodeId {
        const gop = try self.interned.getOrPut(self.allocator, key);
        const id = if (gop.found_existing) gop.value_ptr.* else blk: {
            if (self.nodes.items.len >= types.max_nodes) return error.TooManyNodes;
            const new_id: types.NodeId = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{
                .id = new_id,
                .id_text = id_text,
                .label = label,
                .shape = shape,
            });
            gop.value_ptr.* = new_id;
            break :blk new_id;
        };
        try self.touched.append(self.allocator, id);
        return id;
    }

    fn markComposite(self: *Parser, id: types.NodeId) void {
        self.nodes.items[id].is_composite = true;
    }

    fn resetTouched(self: *Parser) void {
        self.touched.clearRetainingCapacity();
    }

    fn recordEntities(self: *Parser, old_e: usize) ParseError!void {
        if (self.ctx_stack.items.len == 0) return;
        const top = &self.ctx_stack.items[self.ctx_stack.items.len - 1];
        for (self.touched.items) |id| {
            if (top.representative_node) |rep| {
                if (rep == id) continue;
            }
            if (self.globally_owned.contains(id)) continue;
            if (containsNodeId(top.node_ids.items, id)) continue;
            try top.node_ids.append(self.allocator, id);
            try self.globally_owned.put(self.allocator, id, {});
        }
        var m: usize = old_e;
        while (m < self.edges.items.len) : (m += 1) {
            try top.edge_indices.append(self.allocator, @intCast(m));
        }
    }
};

fn containsNodeId(slice: []const types.NodeId, id: types.NodeId) bool {
    for (slice) |v| if (v == id) return true;
    return false;
}

pub fn parse(allocator: std.mem.Allocator, source: anytype) ParseError!types.MermaidGraph {
    const owned_source = try source_mod.normalizeOwned(allocator, source);
    return parseFromOwned(allocator, owned_source);
}

fn parseFromOwned(allocator: std.mem.Allocator, owned_source: []u8) ParseError!types.MermaidGraph {
    var parser: Parser = .{ .allocator = allocator };
    defer parser.interned.deinit(allocator);
    defer parser.ctx_stack.deinit(allocator);
    defer parser.touched.deinit(allocator);
    defer parser.globally_owned.deinit(allocator);
    errdefer parser.nodes.deinit(allocator);
    errdefer parser.edges.deinit(allocator);
    errdefer {
        for (parser.ctx_stack.items) |*bc| freeBuildingComposite(allocator, bc);
        for (parser.root_subgraphs.items) |*bc| freeBuildingComposite(allocator, bc);
        parser.root_subgraphs.deinit(allocator);
        parser.link_styles.deinit(allocator);
        for (parser.owned_strings.items) |s| allocator.free(s);
        parser.owned_strings.deinit(allocator);
    }

    {
        errdefer allocator.free(owned_source);
        try parser.owned_strings.append(allocator, owned_source);
    }

    var header_seen = false;
    var top_direction: types.Direction = .top_down;
    var it = std.mem.splitScalar(u8, owned_source, '\n');
    while (it.next()) |raw| {
        const stripped_cr = std.mem.trimEnd(u8, raw, "\r");
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

        try dispatchLine(&parser, trimmed, &top_direction);
    }

    if (!header_seen) return error.InvalidMermaid;

    if (parser.ctx_stack.items.len != 0) return error.InvalidMermaid;

    const nodes = try parser.nodes.toOwnedSlice(allocator);
    errdefer allocator.free(nodes);
    const edges = try parser.edges.toOwnedSlice(allocator);
    errdefer allocator.free(edges);

    const subgraphs = try finalizeComposites(allocator, &parser.root_subgraphs);
    errdefer types.freeSubgraphsPublic(allocator, subgraphs);

    const link_styles = try parser.link_styles.toOwnedSlice(allocator);
    errdefer allocator.free(link_styles);

    const owned_strings = try parser.owned_strings.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .direction = top_direction,
        .nodes = nodes,
        .edges = edges,
        .subgraphs = subgraphs,
        .link_styles = link_styles,
        .owned_strings = owned_strings,
    };
}

fn freeBuildingComposite(allocator: std.mem.Allocator, bc: *BuildingComposite) void {
    bc.node_ids.deinit(allocator);
    bc.edge_indices.deinit(allocator);
    for (bc.children.items) |*c| freeBuildingComposite(allocator, c);
    bc.children.deinit(allocator);
}

fn finalizeComposites(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(BuildingComposite),
) ParseError![]types.Subgraph {
    if (list.items.len == 0) {
        list.deinit(allocator);
        list.* = .empty;
        return &.{};
    }
    const out = try allocator.alloc(types.Subgraph, list.items.len);
    for (out) |*slot| slot.* = .{ .id_text = "" };
    errdefer types.freeSubgraphsPublic(allocator, out);

    for (list.items, 0..) |*bc, i| {
        var node_ids: ?[]types.NodeId = try bc.node_ids.toOwnedSlice(allocator);
        errdefer if (node_ids) |ids| allocator.free(ids);

        var edge_indices: ?[]u32 = try bc.edge_indices.toOwnedSlice(allocator);
        errdefer if (edge_indices) |indices| allocator.free(indices);

        var children: ?[]types.Subgraph = try finalizeComposites(allocator, &bc.children);
        errdefer if (children) |items| types.freeSubgraphsPublic(allocator, items);

        out[i] = .{
            .id_text = bc.id_text,
            .title = bc.title,
            .direction = bc.direction,
            .node_ids = node_ids.?,
            .edge_indices = edge_indices.?,
            .children = children.?,
            .representative_node = bc.representative_node,
        };
        node_ids = null;
        edge_indices = null;
        children = null;
    }
    list.deinit(allocator);
    list.* = .empty;
    return out;
}

/// Matches `keyword` followed by whitespace so identifiers beginning with the
/// same prefix (e.g. `directional`) are not misdetected as the directive.
fn isDirectiveWord(line: []const u8, keyword: []const u8) bool {
    if (line.len <= keyword.len) return false;
    if (!std.ascii.startsWithIgnoreCase(line, keyword)) return false;
    const c = line[keyword.len];
    return c == ' ' or c == '\t';
}

fn dispatchLine(
    parser: *Parser,
    line: []const u8,
    top_direction: *types.Direction,
) ParseError!void {
    if (std.mem.eql(u8, line, "}")) {
        return popComposite(parser);
    }

    if (isDirectiveWord(line, "direction")) {
        return parseDirectionLine(parser, line, top_direction);
    }

    if (std.ascii.startsWithIgnoreCase(line, "linkStyle ")) {
        return parseLinkStyleLine(parser, std.mem.trimStart(u8, line["linkStyle".len..], " \t"));
    }

    if (isSilentlySkipped(line)) return;

    parser.resetTouched();
    const old_e = parser.edges.items.len;
    try parseLine(parser, line);
    try parser.recordEntities(old_e);
}

fn parseDirectionLine(
    parser: *Parser,
    line: []const u8,
    top_direction: *types.Direction,
) ParseError!void {
    if (line.len < "direction".len + 1) return;
    const c = line["direction".len];
    if (c != ' ' and c != '\t') return;
    const rest = std.mem.trim(u8, line["direction".len..], " \t");
    if (rest.len == 0) return;
    const dir = types.Direction.fromString(rest) orelse return;
    if (parser.ctx_stack.items.len > 0) {
        parser.ctx_stack.items[parser.ctx_stack.items.len - 1].direction = dir;
    } else {
        top_direction.* = dir;
    }
}

fn parseLinkStyleLine(parser: *Parser, rest: []const u8) ParseError!void {
    const sp = std.mem.findAny(u8, rest, " \t") orelse return;
    const target = std.mem.trim(u8, rest[0..sp], " \t");
    const style_text = std.mem.trim(u8, rest[sp..], " \t");
    if (target.len == 0 or style_text.len == 0) return;

    if (std.mem.eql(u8, target, "default")) {
        try parser.link_styles.append(parser.allocator, .{
            .key = .default,
            .style_text = style_text,
        });
        return;
    }

    var it = std.mem.splitScalar(u8, target, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) continue;
        const idx = std.fmt.parseInt(u32, t, 10) catch continue;
        try parser.link_styles.append(parser.allocator, .{
            .key = .{ .index = idx },
            .style_text = style_text,
        });
    }
}

fn popComposite(parser: *Parser) ParseError!void {
    if (parser.ctx_stack.items.len == 0) return;
    var completed = parser.ctx_stack.pop().?;
    var completed_owned = true;
    errdefer if (completed_owned) freeBuildingComposite(parser.allocator, &completed);

    if (parser.ctx_stack.items.len > 0) {
        const top = &parser.ctx_stack.items[parser.ctx_stack.items.len - 1];
        try top.children.append(parser.allocator, completed);
    } else {
        try parser.root_subgraphs.append(parser.allocator, completed);
    }
    completed_owned = false;
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
    if (std.mem.startsWith(u8, line, "state ") or std.mem.eql(u8, line, "state")) {
        return parseStateDeclaration(parser, std.mem.trimStart(u8, line[5..], " \t"));
    }

    if (std.mem.find(u8, line, "-->")) |arrow_idx| {
        return parseTransition(parser, line, arrow_idx);
    }

    if (std.mem.findScalar(u8, line, ':')) |colon| {
        return parseStateDescription(parser, line, colon);
    }

    return error.InvalidMermaid;
}

fn isSilentlySkipped(line: []const u8) bool {
    const prefixes = [_][]const u8{
        "note ",
        "click ",
        "link ",
    };
    for (prefixes) |kw| {
        if (std.ascii.startsWithIgnoreCase(line, kw)) return true;
    }
    return false;
}

fn parseStateDeclaration(parser: *Parser, rest: []const u8) ParseError!void {
    const trimmed = std.mem.trim(u8, rest, " \t");

    if (trimmed.len > 0 and trimmed[0] == '"') {
        var j: usize = 1;
        while (j < trimmed.len and trimmed[j] != '"') : (j += 1) {}
        if (j >= trimmed.len) return;
        const raw_label = trimmed[1..j];
        const after = std.mem.trim(u8, trimmed[j + 1 ..], " \t");
        const as_kw = "as ";
        if (!std.mem.startsWith(u8, after, as_kw)) return;
        var ident_tail = std.mem.trim(u8, after[as_kw.len..], " \t");
        const opens_composite = ident_tail.len > 0 and ident_tail[ident_tail.len - 1] == '{';
        if (opens_composite) {
            ident_tail = std.mem.trimEnd(u8, ident_tail[0 .. ident_tail.len - 1], " \t");
        }
        validateIdentDeclaration(ident_tail) catch return;
        label_mod.validate(raw_label) catch return;
        const label = try normalizeLabel(parser, raw_label);
        const id = try parser.internKeyed(ident_tail, ident_tail, label, .stadium);
        parser.nodes.items[id].label = label;
        if (opens_composite) {
            parser.markComposite(id);
            try parser.ctx_stack.append(parser.allocator, .{
                .id_text = ident_tail,
                .title = label,
                .representative_node = id,
            });
        }
        return;
    }

    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '{') {
        const ident = std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - 1], " \t");
        if (ident.len == 0) return;
        validateIdentDeclaration(ident) catch return;
        const id = try parser.internKeyed(ident, ident, ident, .stadium);
        parser.markComposite(id);
        try parser.ctx_stack.append(parser.allocator, .{
            .id_text = ident,
            .title = null,
            .representative_node = id,
        });
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
    try label_mod.validate(raw_label);
    const label = try normalizeLabel(parser, raw_label);
    const id = try parser.internKeyed(ident, ident, label, .stadium);
    parser.nodes.items[id].label = label;
}

fn parseTransition(parser: *Parser, line: []const u8, arrow_idx: usize) ParseError!void {
    const arrow = "-->";
    const lhs_text = std.mem.trimEnd(u8, line[0..arrow_idx], " \t");
    var rhs_with_label = std.mem.trimStart(u8, line[arrow_idx + arrow.len ..], " \t");
    if (lhs_text.len == 0 or rhs_with_label.len == 0) return error.InvalidMermaid;

    var label: ?[]const u8 = null;
    if (std.mem.findScalar(u8, rhs_with_label, ':')) |colon| {
        const label_slice = std.mem.trim(u8, rhs_with_label[colon + 1 ..], " \t");
        if (label_slice.len > 0) {
            try label_mod.validate(label_slice);
            label = try normalizeLabel(parser, label_slice);
        }
        rhs_with_label = std.mem.trimEnd(u8, rhs_with_label[0..colon], " \t");
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
    return validateIdentImpl(text, true);
}

fn validateIdentDeclaration(text: []const u8) ParseError!void {
    return validateIdentImpl(text, false);
}

fn validateIdentImpl(text: []const u8, allow_hyphen: bool) ParseError!void {
    if (text.len == 0) return error.InvalidMermaid;
    var view = std.unicode.Utf8View.init(text) catch return error.InvalidMermaid;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x80) {
            const b: u8 = @intCast(cp);
            const is_alpha = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
            const is_digit = b >= '0' and b <= '9';
            const is_underscore = b == '_';
            const is_hyphen = b == '-' and allow_hyphen;
            if (!(is_alpha or is_digit or is_underscore or is_hyphen)) {
                return error.InvalidMermaid;
            }
        } else {
            if (!unicode_letter.isLetter(cp)) return error.InvalidMermaid;
        }
    }
}

test "parses stateDiagram-v2 header" {
    var g = try parse(std.testing.allocator, "stateDiagram-v2\n");
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
    var g = try parse(std.testing.allocator, source);
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
    var g = try parse(std.testing.allocator, source);
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 6), g.nodes.len);
    try std.testing.expect(g.edges[0].from != g.edges[1].from);
    try std.testing.expect(g.edges[2].to != g.edges[3].to);
}

test "parses transition labels" {
    var g = try parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    Idle --> Running : start
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 1), g.edges.len);
    try std.testing.expectEqualStrings("start", g.edges[0].label.?);
}

test "rejects missing stateDiagram header" {
    try std.testing.expectError(error.InvalidMermaid, parse(std.testing.allocator, "[*] --> Idle\n"));
}

test "parses aliased state declaration" {
    var g = try parse(std.testing.allocator,
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
    var g = try parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    Idle : Waiting for input
        \\    Idle --> Running
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.nodes.len);
    try std.testing.expectEqualStrings("Waiting for input", g.nodes[0].label);
}

test "accepts labels containing display clusters with zero-width dependents" {
    var g = try parse(std.testing.allocator, "stateDiagram-v2\n    Idle : e\u{0301} \u{2764}\u{FE0F} \u{1F468}\u{200D}\u{1F469}\n    Idle --> Running : \u{1F44D}\u{1F3FB}\n");
    defer g.deinit();
    try std.testing.expectEqualStrings("e\u{0301} \u{2764}\u{FE0F} \u{1F468}\u{200D}\u{1F469}", g.nodes[0].label);
    try std.testing.expectEqualStrings("\u{1F44D}\u{1F3FB}", g.edges[0].label.?);
}

test "preserves composite state block as subgraph with inner transitions" {
    var g = try parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    [*] --> Outer
        \\    state Outer {
        \\        [*] --> Inner
        \\    }
        \\    Outer --> [*]
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 3), g.edges.len);
    try std.testing.expectEqual(@as(usize, 1), g.subgraphs.len);
    try std.testing.expectEqualStrings("Outer", g.subgraphs[0].id_text);
    try std.testing.expect(g.subgraphs[0].representative_node != null);
    const rep = g.subgraphs[0].representative_node.?;
    try std.testing.expect(g.nodes[rep].is_composite);
    try std.testing.expect(g.subgraphs[0].edge_indices.len >= 1);
}

test "preserves <br> in transition label as hard-break markers" {
    var g = try parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    A --> B : step<br>one<br/>two
    );
    defer g.deinit();
    try std.testing.expectEqualStrings("step\none\ntwo", g.edges[0].label.?);
}

test "accepts top-level direction line and updates graph.direction" {
    var g = try parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    direction LR
        \\    [*] --> Idle
    );
    defer g.deinit();
    try std.testing.expectEqual(types.Direction.left_right, g.direction);
    try std.testing.expectEqual(@as(usize, 1), g.edges.len);
}

test "accepts direction inside composite state" {
    var g = try parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    state S {
        \\        direction LR
        \\        [*] --> X
        \\    }
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 1), g.subgraphs.len);
    try std.testing.expectEqual(types.Direction.left_right, g.subgraphs[0].direction.?);
}

test "accepts Unicode letter identifiers in transitions" {
    var g = try parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    État --> Δelta
        \\    Состояние --> 状態A
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 4), g.nodes.len);
    try std.testing.expectEqualStrings("État", g.nodes[0].id_text);
    try std.testing.expectEqualStrings("Δelta", g.nodes[1].id_text);
    try std.testing.expectEqualStrings("Состояние", g.nodes[2].id_text);
    try std.testing.expectEqualStrings("状態A", g.nodes[3].id_text);
}

test "silently skips aliased composite with hyphenated id" {
    var g = try parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    state "Label" as A-B {
        \\        [*] --> X
        \\    }
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 0), g.subgraphs.len);
    // Upstream silently ignores the declaration; inner [*] --> X falls to
    // top-level transition parsing because no composite ctx is active.
    try std.testing.expect(g.edges.len >= 1);
}

test "rejects non-Letter codepoints inside Letter-dominated blocks" {
    try std.testing.expectError(error.InvalidMermaid, parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    \u{30A0} --> B
    ));
    try std.testing.expectError(error.InvalidMermaid, parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    \u{0660} --> B
    ));
    try std.testing.expectError(error.InvalidMermaid, parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    \u{0E47} --> B
    ));
    try std.testing.expectError(error.InvalidMermaid, parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    \u{0984} --> B
    ));
}

test "accepts Ethiopic letter identifiers" {
    var g = try parse(std.testing.allocator, "stateDiagram-v2\n    \u{1200} --> \u{1210}\n");
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.nodes.len);
}

test "accepts Thaana letter identifiers" {
    var g = try parse(std.testing.allocator, "stateDiagram-v2\n    \u{0780} --> \u{0790}\n");
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.nodes.len);
}

test "accepts Tifinagh letter identifiers" {
    var g = try parse(std.testing.allocator, "stateDiagram-v2\n    \u{2D30} --> \u{2D40}\n");
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.nodes.len);
}

test "accepts SMP Letter identifiers (Deseret, Old Italic)" {
    var g1 = try parse(std.testing.allocator, "stateDiagram-v2\n    \u{10400} --> \u{10428}\n");
    defer g1.deinit();
    try std.testing.expectEqual(@as(usize, 2), g1.nodes.len);
    var g2 = try parse(std.testing.allocator, "stateDiagram-v2\n    \u{10300} --> \u{10310}\n");
    defer g2.deinit();
    try std.testing.expectEqual(@as(usize, 2), g2.nodes.len);
    try std.testing.expectError(error.InvalidMermaid, parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    \u{30FB} --> B
    ));
}

test "accepts Adlam letter identifiers" {
    var g = try parse(std.testing.allocator, "stateDiagram-v2\n    \u{1E900} --> \u{1E922}\n");
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.nodes.len);
}

test "accepts Mende Kikakui letter identifiers" {
    var g = try parse(std.testing.allocator, "stateDiagram-v2\n    \u{1E800} --> \u{1E810}\n");
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.nodes.len);
}

test "rejects emoji codepoints in state identifiers" {
    try std.testing.expectError(error.InvalidMermaid, parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    \u{1F680} --> B
    ));
}

test "state ID starting with direction prefix is not misread as directive" {
    var g = try parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    directional --> Done
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.nodes.len);
    try std.testing.expectEqualStrings("directional", g.nodes[0].id_text);
    try std.testing.expectEqualStrings("Done", g.nodes[1].id_text);
}

test "composite representative node is excluded from its own node_ids" {
    var g = try parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    [*] --> Outer
        \\    state Outer {
        \\        [*] --> Inner
        \\    }
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 1), g.subgraphs.len);
    const rep = g.subgraphs[0].representative_node.?;
    for (g.subgraphs[0].node_ids) |id| {
        try std.testing.expect(id != rep);
    }
}

test "silently skips note lines" {
    var g = try parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    [*] --> Idle
        \\    note left of Idle : a note
        \\    Idle --> [*]
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.edges.len);
}

test "silently skips init directive" {
    var g = try parse(std.testing.allocator,
        \\stateDiagram-v2
        \\    %%{init: {"theme": "dark"}}%%
        \\    [*] --> Idle
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 1), g.edges.len);
}

fn expectParseStateHandlesAllocationFailures(allocator: std.mem.Allocator) !void {
    var g = try parse(allocator,
        \\stateDiagram-v2
        \\    [*] --> Outer
        \\    state Outer {
        \\        state Inner {
        \\            [*] --> Done
        \\        }
        \\    }
        \\    Outer --> [*]
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 1), g.subgraphs.len);
    try std.testing.expectEqual(@as(usize, 1), g.subgraphs[0].children.len);
}

test "parse cleans up nested state allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        expectParseStateHandlesAllocationFailures,
        .{},
    );
}
