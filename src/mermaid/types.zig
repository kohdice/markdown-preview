const std = @import("std");

pub const NodeId = u16;
pub const max_nodes: usize = std.math.maxInt(NodeId);

pub const Direction = enum {
    top_down,
    bottom_up,
    left_right,
    right_left,

    pub fn fromString(s: []const u8) ?Direction {
        if (std.ascii.eqlIgnoreCase(s, "TD")) return .top_down;
        if (std.ascii.eqlIgnoreCase(s, "TB")) return .top_down;
        if (std.ascii.eqlIgnoreCase(s, "BT")) return .bottom_up;
        if (std.ascii.eqlIgnoreCase(s, "LR")) return .left_right;
        if (std.ascii.eqlIgnoreCase(s, "RL")) return .right_left;
        return null;
    }

    pub fn isHorizontal(self: Direction) bool {
        return self == .left_right or self == .right_left;
    }

    /// Normalises for layout: RL → LR (upstream parity). BT normalisation to
    /// TD + canvas flipVertical is done by renderMermaidGraph before calling
    /// computeLayout, not here, because render_class / render_er pass
    /// .bottom_up directly and hard-code `.up` routing direction.
    pub fn layoutDir(self: Direction) Direction {
        return switch (self) {
            .right_left => .left_right,
            else => self,
        };
    }
};

pub const NodeShape = enum {
    rect,
    diamond,
    round,
    stadium,
    circle,
    subroutine,
    double_circle,
    cylinder,
    hexagon,
    asymmetric,
    trapezoid,
    inv_trapezoid,
    implicit,
};

pub const EdgeStyle = enum {
    arrow,
    line,
    dotted,
    thick,
    dotted_line,
    thick_line,
};

pub const Node = struct {
    id: NodeId,
    id_text: []const u8,
    label: []const u8,
    shape: NodeShape,
    /// Marks a stateDiagram composite state without removing the node, so
    /// existing NodeId indices in `edges` stay valid.
    is_composite: bool = false,
};

pub const Edge = struct {
    from: NodeId,
    to: NodeId,
    label: ?[]const u8 = null,
    style: EdgeStyle = .arrow,
    bidirectional: bool = false,
};

pub const LinkStyleKey = union(enum) {
    default,
    index: u32,

    pub fn eql(a: LinkStyleKey, b: LinkStyleKey) bool {
        return switch (a) {
            .default => b == .default,
            .index => |ai| switch (b) {
                .default => false,
                .index => |bi| ai == bi,
            },
        };
    }
};

pub const LinkStyle = struct {
    key: LinkStyleKey,
    style_text: []const u8,
};

pub const ClassDef = struct {
    name: []const u8,
    style_text: []const u8,
};

pub const ClassAssignment = struct {
    node: NodeId,
    class_name: []const u8,
};

pub const NodeStyle = struct {
    node: NodeId,
    style_text: []const u8,
};

pub const Subgraph = struct {
    /// Explicit id from `subgraph id [title]`, or the slugified id for the
    /// label-only form.
    id_text: []const u8,
    title: ?[]const u8 = null,
    direction: ?Direction = null,
    /// Direct members only; nodes owned by `children` are not listed here.
    node_ids: []NodeId = &.{},
    edge_indices: []u32 = &.{},
    children: []Subgraph = &.{},
    /// For a stateDiagram composite state, the NodeId of the ordinary node
    /// sharing the same identifier, so layout can resolve edges to this
    /// frame's boundary. Always null for flowchart subgraphs.
    representative_node: ?NodeId = null,
};

pub const MermaidGraph = struct {
    allocator: std.mem.Allocator,
    /// `direction X` updates this only for stateDiagram. Flowchart accepts
    /// but ignores the line (intentional deviation from upstream).
    direction: Direction,
    nodes: []Node,
    edges: []Edge,
    subgraphs: []Subgraph = &.{},
    class_defs: []ClassDef = &.{},
    class_assignments: []ClassAssignment = &.{},
    node_styles: []NodeStyle = &.{},
    /// Repeated keys are kept in source order.
    /// TODO: add a per-property later-wins resolver matching upstream.
    link_styles: []LinkStyle = &.{},
    owned_strings: [][]u8 = &.{},

    pub fn deinit(self: *MermaidGraph) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.edges);
        freeSubgraphs(self.allocator, self.subgraphs);
        self.allocator.free(self.class_defs);
        self.allocator.free(self.class_assignments);
        self.allocator.free(self.node_styles);
        self.allocator.free(self.link_styles);
        for (self.owned_strings) |s| self.allocator.free(s);
        if (self.owned_strings.len > 0) self.allocator.free(self.owned_strings);
    }
};

fn freeSubgraphs(allocator: std.mem.Allocator, subgraphs: []Subgraph) void {
    for (subgraphs) |sg| {
        allocator.free(sg.node_ids);
        allocator.free(sg.edge_indices);
        freeSubgraphs(allocator, sg.children);
    }
    if (subgraphs.len > 0) allocator.free(subgraphs);
}

pub fn freeSubgraphsPublic(allocator: std.mem.Allocator, subgraphs: []Subgraph) void {
    freeSubgraphs(allocator, subgraphs);
}

pub const ParticipantId = u16;

pub const ParticipantKind = enum { participant, actor };

pub const LineStyle = enum { solid, dashed };
pub const ArrowHead = enum { filled, open };

pub const Participant = struct {
    id: ParticipantId,
    id_text: []const u8,
    label: []const u8,
    kind: ParticipantKind = .participant,
};

pub const SequenceMessage = struct {
    from: ParticipantId,
    to: ParticipantId,
    label: []const u8,
    line_style: LineStyle,
    arrow_head: ArrowHead,
    activate: bool = false,
    deactivate: bool = false,
};

pub const NotePlacement = enum { right_of, left_of, over };

pub const SequenceNote = struct {
    actor_ids: []ParticipantId,
    text: []const u8,
    placement: NotePlacement,
    after_index: i32,
};

pub const SequenceBlockKind = enum {
    loop,
    alt,
    opt,
    par,
    critical,
    rect,
    break_,
};

pub const SequenceBlockDivider = struct {
    message_index: u32,
    label: []const u8,
};

pub const SequenceBlock = struct {
    kind: SequenceBlockKind,
    label: []const u8,
    start_index: u32,
    end_index: u32,
    source_order: u32 = 0,
    parent_order: ?u32 = null,
    dividers: []SequenceBlockDivider = &.{},
};

pub const SequenceDiagram = struct {
    allocator: std.mem.Allocator,
    participants: []Participant,
    messages: []SequenceMessage,
    notes: []SequenceNote = &.{},
    blocks: []SequenceBlock = &.{},
    owned_strings: [][]u8 = &.{},

    pub fn deinit(self: *SequenceDiagram) void {
        self.allocator.free(self.participants);
        self.allocator.free(self.messages);
        for (self.notes) |n| {
            if (n.actor_ids.len > 0) self.allocator.free(n.actor_ids);
        }
        if (self.notes.len > 0) self.allocator.free(self.notes);
        for (self.blocks) |b| {
            if (b.dividers.len > 0) self.allocator.free(b.dividers);
        }
        if (self.blocks.len > 0) self.allocator.free(self.blocks);
        for (self.owned_strings) |s| self.allocator.free(s);
        if (self.owned_strings.len > 0) self.allocator.free(self.owned_strings);
    }
};

pub const ClassMemberKind = enum { field, method };

pub const Visibility = enum { public, private, protected, package, unknown };

pub const ClassMember = struct {
    kind: ClassMemberKind,
    visibility: Visibility,
    text: []const u8,
};

pub const ClassRelationKind = enum {
    inheritance,
    composition,
    aggregation,
    association,
    dependency,
    realization,
    link,
};

pub const ClassNode = struct {
    id: NodeId,
    id_text: []const u8,
    label: []const u8,
    stereotype: ?[]const u8 = null,
    members: []ClassMember,
};

pub const ClassRelation = struct {
    from: NodeId,
    to: NodeId,
    kind: ClassRelationKind,
    label: ?[]const u8 = null,
    from_cardinality: ?[]const u8 = null,
    to_cardinality: ?[]const u8 = null,
};

pub const ClassDiagram = struct {
    allocator: std.mem.Allocator,
    classes: []ClassNode,
    relations: []ClassRelation,
    owned_labels: [][]u8 = &.{},

    pub fn deinit(self: *ClassDiagram) void {
        for (self.classes) |c| self.allocator.free(c.members);
        self.allocator.free(self.classes);
        self.allocator.free(self.relations);
        for (self.owned_labels) |s| self.allocator.free(s);
        if (self.owned_labels.len > 0) self.allocator.free(self.owned_labels);
    }
};

pub const ErCardinality = enum {
    zero_or_one,
    exactly_one,
    zero_or_many,
    one_or_many,
};

pub const ErAttributeMark = packed struct(u3) {
    pk: bool = false,
    fk: bool = false,
    uk: bool = false,

    pub const none: ErAttributeMark = .{};

    pub fn isEmpty(self: ErAttributeMark) bool {
        return !(self.pk or self.fk or self.uk);
    }

    pub fn eql(a: ErAttributeMark, b: ErAttributeMark) bool {
        return a.pk == b.pk and a.fk == b.fk and a.uk == b.uk;
    }
};

pub const ErAttribute = struct {
    type_text: []const u8,
    name: []const u8,
    mark: ErAttributeMark = .{},
    comment: ?[]const u8 = null,
};

pub const ErEntity = struct {
    id: NodeId,
    id_text: []const u8,
    attributes: []ErAttribute,
};

pub const ErRelation = struct {
    from: NodeId,
    to: NodeId,
    left: ErCardinality,
    right: ErCardinality,
    identifying: bool,
    label: []const u8,
};

pub const ErDiagram = struct {
    allocator: std.mem.Allocator,
    entities: []ErEntity,
    relations: []ErRelation,
    owned_strings: [][]u8 = &.{},

    pub fn deinit(self: *ErDiagram) void {
        for (self.entities) |e| self.allocator.free(e.attributes);
        self.allocator.free(self.entities);
        self.allocator.free(self.relations);
        for (self.owned_strings) |s| self.allocator.free(s);
        if (self.owned_strings.len > 0) self.allocator.free(self.owned_strings);
    }
};

pub const GitCommitType = enum { normal, reverse, highlight };

pub const GitCommit = struct {
    index: u16,
    lane: u16,
    id_text: ?[]const u8,
    tag: ?[]const u8,
    commit_type: GitCommitType = .normal,
    merge_from_lane: ?u16 = null,
    merge_from_index: ?u16 = null,
};

pub const GitBranch = struct {
    name: []const u8,
    lane: u16,
    created_at: u16,
    parent_lane: ?u16,
    fork_commit_index: ?u16 = null,
};

pub const GitGraph = struct {
    allocator: std.mem.Allocator,
    branches: []GitBranch,
    commits: []GitCommit,

    pub fn deinit(self: *GitGraph) void {
        self.allocator.free(self.branches);
        self.allocator.free(self.commits);
    }
};

pub fn normalizeBrTags(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var needs_alloc = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '<' and brTagLen(text, i) != null) {
            needs_alloc = true;
            break;
        }
    }
    if (!needs_alloc) return text;

    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, text.len);
    errdefer out.deinit(allocator);
    var j: usize = 0;
    while (j < text.len) {
        if (text[j] == '<') {
            if (brTagLen(text, j)) |n| {
                try out.append(allocator, ' ');
                j += n;
                continue;
            }
        }
        try out.append(allocator, text[j]);
        j += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn brTagLen(text: []const u8, i: usize) ?usize {
    if (i + 4 > text.len) return null;
    if (text[i] != '<') return null;
    const b1 = text[i + 1];
    const b2 = text[i + 2];
    if (!((b1 == 'b' or b1 == 'B') and (b2 == 'r' or b2 == 'R'))) return null;
    var j = i + 3;
    while (j < text.len and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
    if (j < text.len and text[j] == '/') j += 1;
    while (j < text.len and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
    if (j >= text.len or text[j] != '>') return null;
    return j + 1 - i;
}

pub const GridPos = struct { row: usize, col: usize };

/// Bounding box on the grid for a subgraph, used by the renderer to draw a
/// surrounding frame. Coordinates are inclusive cell indices in `Layout`.
pub const SubgraphFrame = struct {
    row_start: usize,
    col_start: usize,
    row_end: usize,
    col_end: usize,
    /// 0 for top-level subgraphs; +1 per nesting level.
    depth: usize,
    title: ?[]const u8,
    /// Mirrors `Subgraph.representative_node` so the renderer can look up the
    /// frame that belongs to a given composite NodeId without re-walking the
    /// subgraph tree.
    representative_node: ?NodeId = null,
};

pub const EndpointTarget = union(enum) {
    node: NodeId,
    frame: SubgraphFrame,
};

pub const Layout = struct {
    allocator: std.mem.Allocator,
    positions: []GridPos,
    truncated_labels: []const []const u8,
    truncation_buf: ?[]u8,
    rows: usize,
    cols: usize,
    cell_w: usize,
    cell_h: usize,
    subgraph_frames: []SubgraphFrame = &.{},
    /// Extra rows/columns reserved on every side so subgraph frames and titles
    /// have space outside node boxes. Set to (max subgraph depth + 1) when
    /// frames exist, 0 otherwise.
    outer_pad: usize = 0,

    /// Returns `.frame` when the node is a composite with a rendered frame,
    /// `.node` for ordinary nodes, or `null` for a composite that has no
    /// frame (empty body) — the caller should skip routing to avoid drawing
    /// an arrow into an invisible cell.
    pub fn resolveEdgeEndpoint(self: *const Layout, nodes: []const Node, id: NodeId) ?EndpointTarget {
        if (!nodes[id].is_composite) return .{ .node = id };
        for (self.subgraph_frames) |f| {
            if (f.representative_node) |rep| {
                if (rep == id) return .{ .frame = f };
            }
        }
        return null;
    }

    pub fn deinit(self: *Layout) void {
        self.allocator.free(self.positions);
        self.allocator.free(self.truncated_labels);
        if (self.truncation_buf) |buf| self.allocator.free(buf);
        self.allocator.free(self.subgraph_frames);
    }
};

test "Direction.fromString parses TD and TB as top_down" {
    try std.testing.expectEqual(@as(?Direction, .top_down), Direction.fromString("TD"));
    try std.testing.expectEqual(@as(?Direction, .top_down), Direction.fromString("TB"));
    try std.testing.expectEqual(@as(?Direction, .top_down), Direction.fromString("td"));
}

test "Direction.fromString parses LR and RL" {
    try std.testing.expectEqual(@as(?Direction, .left_right), Direction.fromString("LR"));
    try std.testing.expectEqual(@as(?Direction, .right_left), Direction.fromString("RL"));
}

test "Direction.fromString parses BT as bottom_up" {
    try std.testing.expectEqual(@as(?Direction, .bottom_up), Direction.fromString("BT"));
}

test "Direction.fromString rejects unknown token" {
    try std.testing.expectEqual(@as(?Direction, null), Direction.fromString("XX"));
    try std.testing.expectEqual(@as(?Direction, null), Direction.fromString(""));
}

test "Direction.isHorizontal distinguishes vertical and horizontal layouts" {
    try std.testing.expect(!Direction.isHorizontal(.top_down));
    try std.testing.expect(!Direction.isHorizontal(.bottom_up));
    try std.testing.expect(Direction.isHorizontal(.left_right));
    try std.testing.expect(Direction.isHorizontal(.right_left));
}
