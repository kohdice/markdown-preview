const std = @import("std");
const types = @import("types.zig");
const width_mod = @import("../term/width.zig");

pub const ParseError = error{
    InvalidMermaid,
    TooManyClasses,
    OutOfMemory,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    classes: std.ArrayListUnmanaged(BuildingClass) = .empty,
    relations: std.ArrayListUnmanaged(types.ClassRelation) = .empty,
    interned: std.StringHashMapUnmanaged(types.NodeId) = .empty,

    const BuildingClass = struct {
        id_text: []const u8,
        label: []const u8,
        members: std.ArrayListUnmanaged(types.ClassMember) = .empty,
    };

    fn intern(self: *Parser, id_text: []const u8) ParseError!types.NodeId {
        const gop = try self.interned.getOrPut(self.allocator, id_text);
        if (gop.found_existing) return gop.value_ptr.*;
        if (self.classes.items.len >= types.max_nodes) return error.TooManyClasses;
        const new_id: types.NodeId = @intCast(self.classes.items.len);
        try self.classes.append(self.allocator, .{
            .id_text = id_text,
            .label = id_text,
        });
        gop.value_ptr.* = new_id;
        return new_id;
    }

    fn addMember(self: *Parser, id: types.NodeId, member: types.ClassMember) ParseError!void {
        try self.classes.items[id].members.append(self.allocator, member);
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

pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) ParseError!types.ClassDiagram {
    var parser: Parser = .{ .allocator = allocator };
    defer parser.interned.deinit(allocator);
    errdefer {
        for (parser.classes.items) |*c| c.members.deinit(allocator);
        parser.classes.deinit(allocator);
        parser.relations.deinit(allocator);
    }

    var header_seen = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        const stripped_cr = std.mem.trimRight(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, stripped_cr, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "%%")) continue;

        if (!header_seen) {
            if (!std.ascii.eqlIgnoreCase(trimmed, "classDiagram") and
                !std.ascii.eqlIgnoreCase(trimmed, "classDiagram-v2"))
                return error.InvalidMermaid;
            header_seen = true;
            continue;
        }

        try parseLine(&parser, trimmed);
    }

    if (!header_seen) return error.InvalidMermaid;

    const classes = try allocator.alloc(types.ClassNode, parser.classes.items.len);
    errdefer allocator.free(classes);
    for (parser.classes.items, 0..) |*b, i| {
        const members = try b.members.toOwnedSlice(allocator);
        classes[i] = .{
            .id = @intCast(i),
            .id_text = b.id_text,
            .label = b.label,
            .members = members,
        };
    }
    parser.classes.deinit(allocator);

    const relations = try parser.relations.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .classes = classes,
        .relations = relations,
    };
}

fn parseLine(parser: *Parser, line: []const u8) ParseError!void {
    if (std.mem.startsWith(u8, line, "class ")) {
        try parseClassDeclaration(parser, std.mem.trimLeft(u8, line[6..], " \t"));
        return;
    }
    if (parseMemberLine(parser, line)) |_| return else |err| switch (err) {
        error.NotMember => {},
        error.InvalidMermaid => return error.InvalidMermaid,
        error.TooManyClasses => return error.TooManyClasses,
        error.OutOfMemory => return error.OutOfMemory,
    }
    try parseRelation(parser, line);
}

fn parseClassDeclaration(parser: *Parser, rest: []const u8) ParseError!void {
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const b = rest[end];
        const is_alpha = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
        const is_digit = b >= '0' and b <= '9';
        const is_underscore = b == '_';
        if (end == 0) {
            if (!is_alpha) return error.InvalidMermaid;
        } else {
            if (!is_alpha and !is_digit and !is_underscore) break;
        }
    }
    if (end == 0) return error.InvalidMermaid;
    const name = rest[0..end];
    _ = try parser.intern(name);
}

const MemberError = ParseError || error{NotMember};

fn parseMemberLine(parser: *Parser, line: []const u8) MemberError!void {
    const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse return error.NotMember;
    const name_part = std.mem.trimRight(u8, line[0..colon_idx], " \t");
    const member_text = std.mem.trimLeft(u8, line[colon_idx + 1 ..], " \t");

    if (name_part.len == 0 or member_text.len == 0) return error.NotMember;
    validateIdent(name_part) catch return error.NotMember;
    try validateLabel(member_text);

    var visibility: types.Visibility = .unknown;
    var body = member_text;
    if (member_text.len > 0) {
        visibility = switch (member_text[0]) {
            '+' => .public,
            '-' => .private,
            '#' => .protected,
            '~' => .package,
            else => .unknown,
        };
        if (visibility != .unknown) body = std.mem.trimLeft(u8, member_text[1..], " \t");
    }
    if (body.len == 0) return error.InvalidMermaid;

    const kind: types.ClassMemberKind = if (std.mem.indexOfScalar(u8, body, '(') != null) .method else .field;

    const id = try parser.intern(name_part);
    try parser.addMember(id, .{
        .kind = kind,
        .visibility = visibility,
        .text = body,
    });
}

const RelationOp = struct {
    op: []const u8,
    kind: types.ClassRelationKind,
    reverse: bool,
};

const relation_ops = [_]RelationOp{
    .{ .op = "<|--", .kind = .inheritance, .reverse = true },
    .{ .op = "--|>", .kind = .inheritance, .reverse = false },
    .{ .op = "<|..", .kind = .realization, .reverse = true },
    .{ .op = "..|>", .kind = .realization, .reverse = false },
    .{ .op = "*--", .kind = .composition, .reverse = false },
    .{ .op = "--*", .kind = .composition, .reverse = true },
    .{ .op = "o--", .kind = .aggregation, .reverse = false },
    .{ .op = "--o", .kind = .aggregation, .reverse = true },
    .{ .op = "..>", .kind = .dependency, .reverse = false },
    .{ .op = "<..", .kind = .dependency, .reverse = true },
    .{ .op = "-->", .kind = .association, .reverse = false },
    .{ .op = "<--", .kind = .association, .reverse = true },
    .{ .op = "--", .kind = .link, .reverse = false },
    .{ .op = "..", .kind = .link, .reverse = false },
};

const RelationMatch = struct {
    start: usize,
    len: usize,
    kind: types.ClassRelationKind,
    reverse: bool,
};

fn findRelation(text: []const u8) ?RelationMatch {
    var best: ?RelationMatch = null;
    for (relation_ops) |candidate| {
        var i: usize = 0;
        while (i + candidate.op.len <= text.len) : (i += 1) {
            if (!std.mem.eql(u8, text[i .. i + candidate.op.len], candidate.op)) continue;
            if (best) |b| {
                if (candidate.op.len <= b.len) continue;
            }
            best = .{
                .start = i,
                .len = candidate.op.len,
                .kind = candidate.kind,
                .reverse = candidate.reverse,
            };
        }
    }
    return best;
}

fn parseRelation(parser: *Parser, line: []const u8) ParseError!void {
    const match = findRelation(line) orelse return error.InvalidMermaid;

    const lhs_text = std.mem.trimRight(u8, line[0..match.start], " \t");
    const after = line[match.start + match.len ..];

    var rhs_end: usize = after.len;
    var label: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, after, ':')) |idx| {
        rhs_end = idx;
        const label_slice = std.mem.trim(u8, after[idx + 1 ..], " \t");
        if (label_slice.len > 0) {
            try validateLabel(label_slice);
            label = label_slice;
        }
    }
    const rhs_text = std.mem.trim(u8, after[0..rhs_end], " \t");

    try validateIdent(lhs_text);
    try validateIdent(rhs_text);

    const lhs_id = try parser.intern(lhs_text);
    const rhs_id = try parser.intern(rhs_text);

    const from = if (match.reverse) rhs_id else lhs_id;
    const to = if (match.reverse) lhs_id else rhs_id;

    try parser.relations.append(parser.allocator, .{
        .from = from,
        .to = to,
        .kind = match.kind,
        .label = label,
    });
}

test "parses classDiagram header" {
    var d = try parseSource(std.testing.allocator, "classDiagram\n");
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.classes.len);
}

test "parses class declaration" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    class Animal
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.classes.len);
    try std.testing.expectEqualStrings("Animal", d.classes[0].label);
}

test "parses inheritance relation with reversed direction" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    Animal <|-- Dog
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.classes.len);
    try std.testing.expectEqual(@as(usize, 1), d.relations.len);
    try std.testing.expectEqual(types.ClassRelationKind.inheritance, d.relations[0].kind);
    try std.testing.expectEqualStrings("Dog", d.classes[d.relations[0].from].id_text);
    try std.testing.expectEqualStrings("Animal", d.classes[d.relations[0].to].id_text);
}

test "parses composition and aggregation relations" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    Car *-- Engine
        \\    Library o-- Book
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.relations.len);
    try std.testing.expectEqual(types.ClassRelationKind.composition, d.relations[0].kind);
    try std.testing.expectEqual(types.ClassRelationKind.aggregation, d.relations[1].kind);
}

test "parses member fields and methods" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    Animal : +name str
        \\    Animal : +eat()
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.classes.len);
    try std.testing.expectEqual(@as(usize, 2), d.classes[0].members.len);
    try std.testing.expectEqual(types.ClassMemberKind.field, d.classes[0].members[0].kind);
    try std.testing.expectEqual(types.Visibility.public, d.classes[0].members[0].visibility);
    try std.testing.expectEqualStrings("name str", d.classes[0].members[0].text);
    try std.testing.expectEqual(types.ClassMemberKind.method, d.classes[0].members[1].kind);
}

test "parses relation with label" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    Customer --> Order : places
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.relations.len);
    try std.testing.expectEqualStrings("places", d.relations[0].label.?);
}

test "rejects missing classDiagram header" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator, "Animal <|-- Dog\n"));
}
