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
};

pub const NodeShape = enum {
    rect,
    diamond,
    round,
    stadium,
    implicit,
};

pub const EdgeStyle = enum {
    arrow,
    line,
    dotted,
    thick,
};

pub const Node = struct {
    id: NodeId,
    id_text: []const u8,
    label: []const u8,
    shape: NodeShape,
};

pub const Edge = struct {
    from: NodeId,
    to: NodeId,
    label: ?[]const u8 = null,
    style: EdgeStyle = .arrow,
};

pub const FlowGraph = struct {
    allocator: std.mem.Allocator,
    direction: Direction,
    nodes: []Node,
    edges: []Edge,

    pub fn deinit(self: *FlowGraph) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.edges);
    }
};

pub const ParticipantId = u16;

pub const MessageStyle = enum {
    solid_arrow,
    dashed_arrow,
    solid_line,
    dashed_line,
};

pub const Participant = struct {
    id: ParticipantId,
    id_text: []const u8,
    label: []const u8,
};

pub const SequenceMessage = struct {
    from: ParticipantId,
    to: ParticipantId,
    label: []const u8,
    style: MessageStyle,
};

pub const SequenceDiagram = struct {
    allocator: std.mem.Allocator,
    participants: []Participant,
    messages: []SequenceMessage,

    pub fn deinit(self: *SequenceDiagram) void {
        self.allocator.free(self.participants);
        self.allocator.free(self.messages);
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
    members: []ClassMember,
};

pub const ClassRelation = struct {
    from: NodeId,
    to: NodeId,
    kind: ClassRelationKind,
    label: ?[]const u8 = null,
};

pub const ClassDiagram = struct {
    allocator: std.mem.Allocator,
    classes: []ClassNode,
    relations: []ClassRelation,

    pub fn deinit(self: *ClassDiagram) void {
        for (self.classes) |c| self.allocator.free(c.members);
        self.allocator.free(self.classes);
        self.allocator.free(self.relations);
    }
};

pub const GridPos = struct { row: usize, col: usize };

pub const Layout = struct {
    allocator: std.mem.Allocator,
    positions: []GridPos,
    truncated_labels: []const []const u8,
    truncation_buf: ?[]u8,
    rows: usize,
    cols: usize,
    cell_w: usize,
    cell_h: usize,

    pub fn deinit(self: *Layout) void {
        self.allocator.free(self.positions);
        self.allocator.free(self.truncated_labels);
        if (self.truncation_buf) |buf| self.allocator.free(buf);
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
