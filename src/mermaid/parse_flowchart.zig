const std = @import("std");
const source_mod = @import("source.zig");
const types = @import("types.zig");
const label_mod = @import("label.zig");

pub const Source = source_mod.Source;

pub const ParseError = error{
    InvalidMermaid,
    UnsupportedFeature,
    TooManyNodes,
    OutOfMemory,
};

const BuildingSubgraph = struct {
    id_text: []const u8,
    title: ?[]const u8 = null,
    direction: ?types.Direction = null,
    node_ids: std.ArrayList(types.NodeId) = .empty,
    edge_indices: std.ArrayList(u32) = .empty,
    children: std.ArrayList(BuildingSubgraph) = .empty,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(types.Node) = .empty,
    edges: std.ArrayList(types.Edge) = .empty,
    interned: std.StringHashMapUnmanaged(types.NodeId) = .empty,

    root_subgraphs: std.ArrayList(BuildingSubgraph) = .empty,
    ctx_stack: std.ArrayList(BuildingSubgraph) = .empty,
    class_defs: std.ArrayList(types.ClassDef) = .empty,
    class_assignments: std.ArrayList(types.ClassAssignment) = .empty,
    node_styles: std.ArrayList(types.NodeStyle) = .empty,
    link_styles: std.ArrayList(types.LinkStyle) = .empty,
    owned_strings: std.ArrayList([]u8) = .empty,
    touched: std.ArrayList(types.NodeId) = .empty,
    /// Tracks which nodes have already been claimed by a subgraph so the same
    /// node is not registered in multiple subgraphs' node_ids. Implements the
    /// upstream "first-defined subgraph wins" deduplication rule.
    globally_owned: std.AutoHashMapUnmanaged(types.NodeId, void) = .empty,

    fn internNode(self: *Parser, id_text: []const u8) ParseError!types.NodeId {
        const gop = try self.interned.getOrPut(self.allocator, id_text);
        const id = if (gop.found_existing) gop.value_ptr.* else blk: {
            if (self.nodes.items.len >= types.max_nodes) return error.TooManyNodes;
            const new_id: types.NodeId = @intCast(self.nodes.items.len);
            try self.nodes.append(self.allocator, .{
                .id = new_id,
                .id_text = id_text,
                .label = id_text,
                .shape = .implicit,
            });
            gop.value_ptr.* = new_id;
            break :blk new_id;
        };
        try self.touched.append(self.allocator, id);
        return id;
    }

    fn updateNode(self: *Parser, id: types.NodeId, shape: types.NodeShape, label: []const u8) void {
        var node = &self.nodes.items[id];
        node.shape = shape;
        node.label = label;
    }

    fn resetTouched(self: *Parser) void {
        self.touched.clearRetainingCapacity();
    }

    fn recordEntities(self: *Parser, old_e: usize) ParseError!void {
        if (self.ctx_stack.items.len == 0) return;
        const top = &self.ctx_stack.items[self.ctx_stack.items.len - 1];
        for (self.touched.items) |id| {
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

pub fn parseSource(allocator: std.mem.Allocator, source: anytype) ParseError!types.MermaidGraph {
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
        for (parser.ctx_stack.items) |*bs| freeBuildingSubgraph(allocator, bs);
        for (parser.root_subgraphs.items) |*bs| freeBuildingSubgraph(allocator, bs);
        parser.root_subgraphs.deinit(allocator);
        parser.class_defs.deinit(allocator);
        parser.class_assignments.deinit(allocator);
        parser.node_styles.deinit(allocator);
        parser.link_styles.deinit(allocator);
        for (parser.owned_strings.items) |s| allocator.free(s);
        parser.owned_strings.deinit(allocator);
    }

    {
        errdefer allocator.free(owned_source);
        try parser.owned_strings.append(allocator, owned_source);
    }

    var direction: ?types.Direction = null;
    var it = std.mem.splitScalar(u8, owned_source, '\n');
    while (it.next()) |raw_line| {
        const stripped_cr = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, stripped_cr, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "%%")) continue;

        if (direction == null) {
            direction = try parseHeader(trimmed);
            continue;
        }

        try dispatchLine(&parser, trimmed);
    }

    if (parser.ctx_stack.items.len != 0) return error.InvalidMermaid;

    const dir = direction orelse return error.InvalidMermaid;

    const nodes = try parser.nodes.toOwnedSlice(allocator);
    errdefer allocator.free(nodes);
    const edges = try parser.edges.toOwnedSlice(allocator);
    errdefer allocator.free(edges);

    const subgraphs = try finalizeSubgraphs(allocator, &parser.root_subgraphs);
    errdefer types.freeSubgraphsPublic(allocator, subgraphs);

    const class_defs = try parser.class_defs.toOwnedSlice(allocator);
    errdefer allocator.free(class_defs);
    const class_assignments = try parser.class_assignments.toOwnedSlice(allocator);
    errdefer allocator.free(class_assignments);
    const node_styles = try parser.node_styles.toOwnedSlice(allocator);
    errdefer allocator.free(node_styles);
    const link_styles = try parser.link_styles.toOwnedSlice(allocator);
    errdefer allocator.free(link_styles);
    const owned_strings = try parser.owned_strings.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .direction = dir,
        .nodes = nodes,
        .edges = edges,
        .subgraphs = subgraphs,
        .class_defs = class_defs,
        .class_assignments = class_assignments,
        .node_styles = node_styles,
        .link_styles = link_styles,
        .owned_strings = owned_strings,
    };
}

fn freeBuildingSubgraph(allocator: std.mem.Allocator, bs: *BuildingSubgraph) void {
    bs.node_ids.deinit(allocator);
    bs.edge_indices.deinit(allocator);
    for (bs.children.items) |*c| freeBuildingSubgraph(allocator, c);
    bs.children.deinit(allocator);
}

fn finalizeSubgraphs(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(BuildingSubgraph),
) ParseError![]types.Subgraph {
    if (list.items.len == 0) {
        list.deinit(allocator);
        return &.{};
    }
    const out = try allocator.alloc(types.Subgraph, list.items.len);
    for (out) |*slot| slot.* = .{ .id_text = "" };
    errdefer types.freeSubgraphsPublic(allocator, out);

    for (list.items, 0..) |*bs, i| {
        const node_ids = try bs.node_ids.toOwnedSlice(allocator);
        errdefer allocator.free(node_ids);
        const edge_indices = try bs.edge_indices.toOwnedSlice(allocator);
        errdefer allocator.free(edge_indices);
        const children = try finalizeSubgraphs(allocator, &bs.children);
        out[i] = .{
            .id_text = bs.id_text,
            .title = bs.title,
            .direction = bs.direction,
            .node_ids = node_ids,
            .edge_indices = edge_indices,
            .children = children,
        };
    }
    list.deinit(allocator);
    return out;
}

fn dispatchLine(parser: *Parser, trimmed: []const u8) ParseError!void {
    if (std.ascii.eqlIgnoreCase(trimmed, "end")) {
        return popSubgraph(parser);
    }
    if (std.ascii.startsWithIgnoreCase(trimmed, "subgraph ") or
        std.ascii.eqlIgnoreCase(trimmed, "subgraph"))
    {
        return pushSubgraph(parser, trimmed);
    }

    if (startsWithKeyword(trimmed, "classDef")) |rest| return parseClassDef(parser, rest);
    if (startsWithKeyword(trimmed, "class")) |rest| return parseClassAssignment(parser, rest);
    if (startsWithKeyword(trimmed, "style")) |rest| return parseStyleLine(parser, rest);
    if (startsWithKeyword(trimmed, "linkStyle")) |rest| return parseLinkStyleLine(parser, rest);
    if (startsWithKeyword(trimmed, "direction")) |rest| return parseDirectionLine(parser, rest);
    if (startsWithKeyword(trimmed, "click")) |_| return;

    parser.resetTouched();
    const old_e = parser.edges.items.len;
    try parseContentLine(parser, trimmed);
    try parser.recordEntities(old_e);
}

fn startsWithKeyword(line: []const u8, kw: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, kw)) return null;
    if (line.len == kw.len) return null;
    const c = line[kw.len];
    if (c != ' ' and c != '\t') return null;
    return std.mem.trimStart(u8, line[kw.len..], " \t");
}

fn pushSubgraph(parser: *Parser, line: []const u8) ParseError!void {
    var rest: []const u8 = "";
    if (line.len > "subgraph".len) {
        rest = std.mem.trim(u8, line["subgraph".len..], " \t");
    }
    var id_text: []const u8 = "";
    var title: ?[]const u8 = null;

    if (rest.len > 0 and std.mem.indexOf(u8, rest, "[") != null and
        std.mem.endsWith(u8, rest, "]"))
    {
        const lb = std.mem.indexOf(u8, rest, "[").?;
        const id_candidate = std.mem.trim(u8, rest[0..lb], " \t");
        const inner = std.mem.trim(u8, rest[lb + 1 .. rest.len - 1], " \t");
        if (id_candidate.len > 0 and inner.len > 0) {
            id_text = id_candidate;
            title = inner;
            try label_mod.validate(inner);
        }
    }

    if (id_text.len == 0 and rest.len > 0) {
        const slug = try slugify(parser.allocator, rest);
        try parser.owned_strings.append(parser.allocator, slug);
        id_text = slug;
        title = rest;
        try label_mod.validate(rest);
    }

    try parser.ctx_stack.append(parser.allocator, .{
        .id_text = id_text,
        .title = title,
    });
}

fn popSubgraph(parser: *Parser) ParseError!void {
    if (parser.ctx_stack.items.len == 0) return;
    const completed = parser.ctx_stack.pop().?;
    if (parser.ctx_stack.items.len > 0) {
        const top = &parser.ctx_stack.items[parser.ctx_stack.items.len - 1];
        try top.children.append(parser.allocator, completed);
    } else {
        try parser.root_subgraphs.append(parser.allocator, completed);
    }
}

fn slugify(allocator: std.mem.Allocator, label: []const u8) ParseError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var in_ws = false;
    while (i < label.len) : (i += 1) {
        const c = label[i];
        if (c == ' ' or c == '\t') {
            if (!in_ws) {
                try out.append(allocator, '_');
                in_ws = true;
            }
            continue;
        }
        in_ws = false;
        const is_word = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_';
        if (is_word) try out.append(allocator, c);
    }
    return try out.toOwnedSlice(allocator);
}

fn parseClassDef(parser: *Parser, rest: []const u8) ParseError!void {
    const sp = std.mem.indexOfAny(u8, rest, " \t") orelse return;
    const name = std.mem.trim(u8, rest[0..sp], " \t");
    const style = std.mem.trim(u8, rest[sp..], " \t");
    if (name.len == 0 or style.len == 0) return;
    try parser.class_defs.append(parser.allocator, .{
        .name = name,
        .style_text = style,
    });
}

fn parseClassAssignment(parser: *Parser, rest: []const u8) ParseError!void {
    const sp = std.mem.indexOfAny(u8, rest, " \t") orelse return;
    const ids_text = std.mem.trim(u8, rest[0..sp], " \t");
    const class_name = std.mem.trim(u8, rest[sp..], " \t");
    if (ids_text.len == 0 or class_name.len == 0) return;

    var it = std.mem.splitScalar(u8, ids_text, ',');
    while (it.next()) |tok| {
        const id_text = std.mem.trim(u8, tok, " \t");
        if (id_text.len == 0) continue;
        const id = try parser.internNode(id_text);
        try parser.class_assignments.append(parser.allocator, .{
            .node = id,
            .class_name = class_name,
        });
    }
}

fn parseStyleLine(parser: *Parser, rest: []const u8) ParseError!void {
    const sp = std.mem.indexOfAny(u8, rest, " \t") orelse return;
    const id_text = std.mem.trim(u8, rest[0..sp], " \t");
    const style_text = std.mem.trim(u8, rest[sp..], " \t");
    if (id_text.len == 0 or style_text.len == 0) return;
    const id = try parser.internNode(id_text);
    try parser.node_styles.append(parser.allocator, .{
        .node = id,
        .style_text = style_text,
    });
}

fn parseLinkStyleLine(parser: *Parser, rest: []const u8) ParseError!void {
    const sp = std.mem.indexOfAny(u8, rest, " \t") orelse return;
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

/// Accepted only inside a subgraph; top-level direction lines are a silent
/// no-op (intentional deviation from upstream).
fn parseDirectionLine(parser: *Parser, rest: []const u8) ParseError!void {
    const token = std.mem.trim(u8, rest, " \t");
    if (token.len == 0) return;
    const dir = types.Direction.fromString(token) orelse return;
    if (parser.ctx_stack.items.len == 0) return;
    const top = &parser.ctx_stack.items[parser.ctx_stack.items.len - 1];
    top.direction = dir;
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
    const first_arrow = (try findArrow(trimmed)) orelse {
        const ids = try parseNodeSpecList(parser, trimmed);
        parser.allocator.free(ids);
        return;
    };

    const lhs_text = std.mem.trimEnd(u8, trimmed[0..first_arrow.start], " \t");
    if (lhs_text.len == 0) return error.InvalidMermaid;

    var current_ids = try parseNodeSpecList(parser, lhs_text);
    errdefer parser.allocator.free(current_ids);

    var current_arrow = first_arrow;
    var after_arrow = trimmed[first_arrow.start + first_arrow.len ..];

    while (true) {
        if (current_arrow.label) |l| try label_mod.validate(l);

        const next_arrow = try findArrow(after_arrow);
        const rhs_text = if (next_arrow) |na|
            std.mem.trim(u8, after_arrow[0..na.start], " \t")
        else
            std.mem.trimStart(u8, after_arrow, " \t");
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
    var ids: std.ArrayList(types.NodeId) = .empty;
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
                // Upstream accepts `[\w-]+` at any position; digits and
                // underscores may start an id (e.g. `1 --> 2`). Hyphen start
                // stays disallowed so arrow tokens are not misread.
                if (!is_alpha and !is_digit and !is_underscore) return error.InvalidMermaid;
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
                try label_mod.validate(sh.label);
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
            const class_start = i;
            while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '&') : (i += 1) {}
            const class_name = text[class_start..i];
            if (class_name.len > 0) {
                try parser.class_assignments.append(parser.allocator, .{
                    .node = id,
                    .class_name = class_name,
                });
            }
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

test "preserves subgraph as AST entry while keeping edges flat" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    subgraph outer
        \\        A --> B
        \\    end
        \\    B --> C
    );
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.edges.len);
    try std.testing.expectEqual(@as(usize, 1), graph.subgraphs.len);
    try std.testing.expectEqualStrings("outer", graph.subgraphs[0].id_text);
    try std.testing.expectEqual(@as(usize, 1), graph.subgraphs[0].edge_indices.len);
    try std.testing.expectEqual(@as(usize, 2), graph.subgraphs[0].node_ids.len);
}

test "preserves classDef / class assignment / style and :::className" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    classDef warn fill:#f00
        \\    A[Alert]:::warn --> B
        \\    style B fill:#0f0
    );
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
    try std.testing.expectEqualStrings("Alert", graph.nodes[0].label);
    try std.testing.expectEqual(@as(usize, 1), graph.class_defs.len);
    try std.testing.expectEqualStrings("warn", graph.class_defs[0].name);
    try std.testing.expectEqualStrings("fill:#f00", graph.class_defs[0].style_text);
    try std.testing.expectEqual(@as(usize, 1), graph.class_assignments.len);
    try std.testing.expectEqualStrings("warn", graph.class_assignments[0].class_name);
    try std.testing.expectEqual(@as(usize, 1), graph.node_styles.len);
    try std.testing.expectEqualStrings("fill:#0f0", graph.node_styles[0].style_text);
}

test "parses nested subgraphs into tree" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    subgraph A
        \\        subgraph B
        \\            X --> Y
        \\        end
        \\    end
    );
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.subgraphs.len);
    try std.testing.expectEqualStrings("A", graph.subgraphs[0].id_text);
    try std.testing.expectEqual(@as(usize, 1), graph.subgraphs[0].children.len);
    try std.testing.expectEqualStrings("B", graph.subgraphs[0].children[0].id_text);
    try std.testing.expectEqual(@as(usize, 2), graph.subgraphs[0].children[0].node_ids.len);
}

test "slugifies label-only subgraph (upstream rule: spaces->_, non-word removed, case preserved)" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    subgraph My Flow
        \\        A --> B
        \\    end
    );
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.subgraphs.len);
    try std.testing.expectEqualStrings("My_Flow", graph.subgraphs[0].id_text);
    try std.testing.expectEqualStrings("My Flow", graph.subgraphs[0].title.?);
}

test "slugifies subgraph label drops non-word chars" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    subgraph Hello, World!
        \\    end
    );
    defer graph.deinit();
    try std.testing.expectEqualStrings("Hello_World", graph.subgraphs[0].id_text);
}

test "subgraph id [title] form preserves both separately" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    subgraph us-east [US East]
        \\        A --> B
        \\    end
    );
    defer graph.deinit();
    try std.testing.expectEqualStrings("us-east", graph.subgraphs[0].id_text);
    try std.testing.expectEqualStrings("US East", graph.subgraphs[0].title.?);
}

test "linkStyle default is stored with .default key" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    A --> B
        \\    linkStyle default stroke:red
    );
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 1), graph.link_styles.len);
    try std.testing.expect(graph.link_styles[0].key == .default);
    try std.testing.expectEqualStrings("stroke:red", graph.link_styles[0].style_text);
}

test "linkStyle with multiple indices produces multiple entries" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    A --> B
        \\    A --> C
        \\    A --> D
        \\    linkStyle 0,2 stroke:blue
    );
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.link_styles.len);
    try std.testing.expectEqual(@as(u32, 0), graph.link_styles[0].key.index);
    try std.testing.expectEqual(@as(u32, 2), graph.link_styles[1].key.index);
}

test "layout exposes subgraph frame bounding box with title" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    subgraph inner
        \\        A --> B
        \\    end
        \\    B --> C
    );
    defer graph.deinit();

    var layout = try @import("layout_flowchart.zig").computeLayout(std.testing.allocator, &graph, .narrow);
    defer layout.deinit();

    try std.testing.expectEqual(@as(usize, 1), layout.subgraph_frames.len);
    const frame = layout.subgraph_frames[0];
    try std.testing.expectEqualStrings("inner", frame.title.?);
    try std.testing.expectEqual(@as(usize, 0), frame.depth);
    try std.testing.expectEqual(@as(usize, 0), frame.row_start);
    try std.testing.expectEqual(@as(usize, 1), frame.row_end);
}

test "subgraph direction LR arranges members horizontally in a TD diagram" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    subgraph inner
        \\        direction LR
        \\        A --> B --> C
        \\    end
    );
    defer graph.deinit();

    var layout = try @import("layout_flowchart.zig").computeLayout(std.testing.allocator, &graph, .narrow);
    defer layout.deinit();

    const row_a = layout.positions[0].row;
    const row_b = layout.positions[1].row;
    const row_c = layout.positions[2].row;
    try std.testing.expectEqual(row_a, row_b);
    try std.testing.expectEqual(row_b, row_c);

    const col_a = layout.positions[0].col;
    const col_b = layout.positions[1].col;
    const col_c = layout.positions[2].col;
    try std.testing.expect(col_a < col_b);
    try std.testing.expect(col_b < col_c);
}

test "direction inside subgraph overrides subgraph direction" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    subgraph inner
        \\        direction LR
        \\        A --> B
        \\    end
    );
    defer graph.deinit();
    try std.testing.expectEqual(types.Direction.top_down, graph.direction);
    try std.testing.expectEqual(types.Direction.left_right, graph.subgraphs[0].direction.?);
}

test "accepts numeric flowchart identifiers" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    1 --> 2\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqualStrings("1", graph.nodes[0].id_text);
    try std.testing.expectEqualStrings("2", graph.nodes[1].id_text);
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
}

test "flowchart identifier starting with click prefix is not skipped" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    clickbait --> B
    );
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqualStrings("clickbait", graph.nodes[0].id_text);
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
}

test "top-level direction is accepted but does not mutate graph.direction" {
    var graph = try parseSource(std.testing.allocator,
        \\graph TD
        \\    direction LR
        \\    A --> B
    );
    defer graph.deinit();
    try std.testing.expectEqual(types.Direction.top_down, graph.direction);
    try std.testing.expectEqual(@as(usize, 1), graph.edges.len);
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

test "accepts labels containing display clusters with zero-width dependents" {
    var graph = try parseSource(
        std.testing.allocator,
        "graph TD\n    A[e\u{0301}] --> B[\u{2764}\u{FE0F}] --> C[\u{1F44D}\u{1F3FB}] --> D[\u{1F468}\u{200D}\u{1F469}]\n",
    );
    defer graph.deinit();

    try std.testing.expectEqual(@as(usize, 4), graph.nodes.len);
    try std.testing.expectEqualStrings("e\u{0301}", graph.nodes[0].label);
    try std.testing.expectEqualStrings("\u{2764}\u{FE0F}", graph.nodes[1].label);
    try std.testing.expectEqualStrings("\u{1F44D}\u{1F3FB}", graph.nodes[2].label);
    try std.testing.expectEqualStrings("\u{1F468}\u{200D}\u{1F469}", graph.nodes[3].label);
}

test "rejects label containing standalone zero-width cluster" {
    try std.testing.expectError(
        error.InvalidMermaid,
        parseSource(std.testing.allocator, "graph TD\n    A[foo\u{200D}bar] --> B\n"),
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

test "accepts plain CJK and single-codepoint emoji" {
    var graph = try parseSource(std.testing.allocator, "graph TD\n    A[日本語] --> B[\u{1F680}]\n");
    defer graph.deinit();
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.len);
    try std.testing.expectEqualStrings("日本語", graph.nodes[0].label);
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
