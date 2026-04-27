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

    /// Normalises for layout: RL → LR (upstream parity). BT is intentionally
    /// not normalised here because it requires a paired canvas flipVertical;
    /// paintMermaidGraph owns that coupling before calling computeLayout.
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
    id_text: []const u8,
    title: ?[]const u8 = null,
    direction: ?Direction = null,
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
    link_styles: []LinkStyle = &.{},
    /// Owned allocations backing borrowed string slices in nodes, edges,
    /// subgraphs, etc. Includes a private copy of the (directive-stripped)
    /// source so labels stay valid for the lifetime of the diagram without
    /// requiring the caller to keep the original source alive.
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
    /// Owns a copy of the (directive-stripped) source plus any allocated
    /// auxiliary strings. Borrowed slices in messages/notes point into this.
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

pub const Visibility = enum { public, private, protected, package, unknown };

pub const ClassMember = struct {
    visibility: Visibility,
    name: []const u8,
    type_text: ?[]const u8 = null,
    is_static: bool = false,
    is_abstract: bool = false,
    params: ?[]const u8 = null,
};

pub const ClassRelationKind = enum {
    inheritance,
    composition,
    aggregation,
    association,
    dependency,
    realization,
};

pub const ClassMarkerAt = enum { from, to };

pub const ClassNode = struct {
    id: NodeId,
    id_text: []const u8,
    label: []const u8,
    annotation: ?[]const u8 = null,
    attributes: []ClassMember,
    methods: []ClassMember,
};

pub const ClassRelation = struct {
    from: NodeId,
    to: NodeId,
    kind: ClassRelationKind,
    marker_at: ClassMarkerAt,
    label: ?[]const u8 = null,
    from_cardinality: ?[]const u8 = null,
    to_cardinality: ?[]const u8 = null,
};

pub const ClassNamespace = struct {
    name: []const u8,
    class_ids: []NodeId,
};

pub const ClassDiagram = struct {
    allocator: std.mem.Allocator,
    classes: []ClassNode,
    relations: []ClassRelation,
    namespaces: []ClassNamespace = &.{},
    /// Owns a copy of the (directive-stripped) source plus any allocated
    /// auxiliary labels. Borrowed slices in classes/relations point into this.
    owned_labels: [][]u8 = &.{},

    pub fn deinit(self: *ClassDiagram) void {
        for (self.classes) |c| {
            self.allocator.free(c.attributes);
            self.allocator.free(c.methods);
        }
        self.allocator.free(self.classes);
        self.allocator.free(self.relations);
        for (self.namespaces) |ns| {
            if (ns.class_ids.len > 0) self.allocator.free(ns.class_ids);
        }
        if (self.namespaces.len > 0) self.allocator.free(self.namespaces);
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
    /// Owns a copy of the (directive-stripped) source plus any allocated
    /// auxiliary strings. Borrowed slices in entities/relations point into this.
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
    /// Owns a copy of the (directive-stripped) source. Borrowed slices in
    /// commits/branches point into this.
    owned_strings: [][]u8 = &.{},

    pub fn deinit(self: *GitGraph) void {
        self.allocator.free(self.branches);
        self.allocator.free(self.commits);
        for (self.owned_strings) |s| self.allocator.free(s);
        if (self.owned_strings.len > 0) self.allocator.free(self.owned_strings);
    }
};

pub const XyOrientation = enum { vertical, horizontal };

pub const XySeriesKind = enum { bar, line };

pub const XyAxisKind = enum { category, numeric };

pub const XyAxis = struct {
    title: ?[]const u8 = null,
    kind: XyAxisKind = .numeric,
    categories: [][]const u8 = &.{},
    numeric_min: f64 = 0,
    numeric_max: f64 = 0,
    has_explicit_range: bool = false,
};

pub const XySeries = struct {
    kind: XySeriesKind,
    data: []f64,
};

pub const XyChart = struct {
    allocator: std.mem.Allocator,
    title: ?[]const u8 = null,
    orientation: XyOrientation = .vertical,
    x_axis: XyAxis = .{},
    y_axis: XyAxis = .{},
    series: []XySeries = &.{},
    /// Owns a copy of the (directive-stripped) source plus any allocated
    /// auxiliary strings (titles, category labels, …).
    owned_strings: [][]u8 = &.{},

    pub fn deinit(self: *XyChart) void {
        if (self.x_axis.categories.len > 0)
            self.allocator.free(self.x_axis.categories);
        if (self.y_axis.categories.len > 0)
            self.allocator.free(self.y_axis.categories);
        for (self.series) |s| if (s.data.len > 0) self.allocator.free(s.data);
        if (self.series.len > 0) self.allocator.free(self.series);
        for (self.owned_strings) |s| self.allocator.free(s);
        if (self.owned_strings.len > 0) self.allocator.free(self.owned_strings);
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

pub const SubgraphFrame = struct {
    row_start: usize,
    col_start: usize,
    row_end: usize,
    col_end: usize,
    depth: usize,
    title: ?[]const u8,
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
