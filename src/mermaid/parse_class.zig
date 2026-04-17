const std = @import("std");
const types = @import("types.zig");
const width_mod = @import("../term/width.zig");

pub const ParseError = error{
    InvalidMermaid,
    UnsupportedFeature,
    TooManyClasses,
    OutOfMemory,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    classes: std.ArrayListUnmanaged(BuildingClass) = .empty,
    relations: std.ArrayListUnmanaged(types.ClassRelation) = .empty,
    namespaces: std.ArrayListUnmanaged(BuildingNamespace) = .empty,
    interned: std.StringHashMapUnmanaged(types.NodeId) = .empty,
    owned_labels: std.ArrayListUnmanaged([]u8) = .empty,
    ctx_stack: std.ArrayListUnmanaged(Ctx) = .empty,
    in_block: bool = false,
    block_class: types.NodeId = 0,

    const BuildingClass = struct {
        id_text: []const u8,
        label: []const u8,
        annotation: ?[]const u8 = null,
        attributes: std.ArrayListUnmanaged(types.ClassMember) = .empty,
        methods: std.ArrayListUnmanaged(types.ClassMember) = .empty,
    };

    const BuildingNamespace = struct {
        name: []const u8,
        class_ids: std.ArrayListUnmanaged(types.NodeId) = .empty,
    };

    const CtxKind = enum { namespace };

    const Ctx = struct {
        kind: CtxKind,
        ns_index: u32,
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

    fn recordClassId(self: *Parser, id: types.NodeId) ParseError!void {
        if (self.ctx_stack.items.len == 0) return;
        const top = self.ctx_stack.items[self.ctx_stack.items.len - 1];
        switch (top.kind) {
            .namespace => {
                try self.namespaces.items[top.ns_index].class_ids.append(self.allocator, id);
            },
        }
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

/// Upstream `\S+?` — any non-empty, non-whitespace sequence.
fn validateIdent(text: []const u8) ParseError!void {
    if (text.len == 0) return error.InvalidMermaid;
    for (text) |b| {
        if (std.ascii.isWhitespace(b)) return error.InvalidMermaid;
    }
}

pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) ParseError!types.ClassDiagram {
    var parser: Parser = .{ .allocator = allocator };
    defer parser.interned.deinit(allocator);
    defer parser.ctx_stack.deinit(allocator);
    errdefer {
        for (parser.classes.items) |*c| {
            c.attributes.deinit(allocator);
            c.methods.deinit(allocator);
        }
        parser.classes.deinit(allocator);
        parser.relations.deinit(allocator);
        for (parser.namespaces.items) |*ns| ns.class_ids.deinit(allocator);
        parser.namespaces.deinit(allocator);
        for (parser.owned_labels.items) |s| allocator.free(s);
        parser.owned_labels.deinit(allocator);
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

    if (parser.in_block) return error.InvalidMermaid;
    if (parser.ctx_stack.items.len != 0) return error.InvalidMermaid;

    const classes = try allocator.alloc(types.ClassNode, parser.classes.items.len);
    errdefer allocator.free(classes);
    for (parser.classes.items, 0..) |*b, i| {
        const attrs = try b.attributes.toOwnedSlice(allocator);
        errdefer allocator.free(attrs);
        const meths = try b.methods.toOwnedSlice(allocator);
        classes[i] = .{
            .id = @intCast(i),
            .id_text = b.id_text,
            .label = b.label,
            .annotation = b.annotation,
            .attributes = attrs,
            .methods = meths,
        };
    }
    parser.classes.deinit(allocator);

    const relations = try parser.relations.toOwnedSlice(allocator);
    const owned_labels = try parser.owned_labels.toOwnedSlice(allocator);

    var namespaces = try allocator.alloc(types.ClassNamespace, parser.namespaces.items.len);
    errdefer allocator.free(namespaces);
    for (parser.namespaces.items, 0..) |*ns, i| {
        const ids = try ns.class_ids.toOwnedSlice(allocator);
        namespaces[i] = .{
            .name = ns.name,
            .class_ids = ids,
        };
    }
    parser.namespaces.deinit(allocator);

    return .{
        .allocator = allocator,
        .classes = classes,
        .relations = relations,
        .namespaces = namespaces,
        .owned_labels = owned_labels,
    };
}

fn parseLine(parser: *Parser, line: []const u8) ParseError!void {
    if (parser.in_block) {
        if (std.mem.eql(u8, line, "}")) {
            parser.in_block = false;
            return;
        }
        return parseBlockBodyLine(parser, line);
    }

    if (parser.ctx_stack.items.len > 0 and std.mem.eql(u8, line, "}")) {
        _ = parser.ctx_stack.pop();
        return;
    }

    if (tryOpenNamespace(parser, line) catch |err| return err) |_| {
        return;
    }

    if (isSilentlySkipped(line)) return;
    if (isUnsupportedStatement(line)) return error.UnsupportedFeature;

    if (std.mem.startsWith(u8, line, "class ")) {
        try parseClassDeclaration(parser, std.mem.trimLeft(u8, line[6..], " \t"));
        return;
    }
    if (parseMemberLine(parser, line)) |_| return else |err| switch (err) {
        error.NotMember => {},
        error.InvalidMermaid => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.TooManyClasses => return error.TooManyClasses,
        error.OutOfMemory => return error.OutOfMemory,
    }
    try parseRelation(parser, line);
}

fn tryOpenNamespace(parser: *Parser, line: []const u8) ParseError!?void {
    if (!std.ascii.startsWithIgnoreCase(line, "namespace")) return null;
    if (line.len <= "namespace".len) return null;
    const after_kw = line["namespace".len];
    if (after_kw != ' ' and after_kw != '\t') return null;

    const rest = std.mem.trim(u8, line["namespace".len..], " \t");
    if (rest.len == 0 or rest[rest.len - 1] != '{') return null;
    const name = std.mem.trim(u8, rest[0 .. rest.len - 1], " \t");
    if (name.len == 0) return null;

    const ns_index: u32 = @intCast(parser.namespaces.items.len);
    try parser.namespaces.append(parser.allocator, .{ .name = name });
    try parser.ctx_stack.append(parser.allocator, .{ .kind = .namespace, .ns_index = ns_index });
    return {};
}

fn isUnsupportedStatement(line: []const u8) bool {
    const keywords = [_][]const u8{
        "direction", "click", "cssClass",
        "style ",    "link ",
    };
    for (keywords) |kw| {
        if (std.ascii.startsWithIgnoreCase(line, kw)) return true;
    }
    return false;
}

fn isSilentlySkipped(line: []const u8) bool {
    const prefixes = [_][]const u8{
        "note ",
        "note for ",
    };
    for (prefixes) |kw| {
        if (std.ascii.startsWithIgnoreCase(line, kw)) return true;
    }
    if (std.ascii.eqlIgnoreCase(line, "note")) return true;
    if (std.mem.startsWith(u8, line, "<<")) return true;
    return false;
}

fn parseClassDeclaration(parser: *Parser, rest: []const u8) ParseError!void {
    var body = rest;
    const trimmed = std.mem.trimRight(u8, body, " \t");
    const opens_block = trimmed.len > 0 and trimmed[trimmed.len - 1] == '{';
    if (opens_block) body = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " \t");

    const match = matchClassNameAndGeneric(body) orelse return;
    const name = body[0..match.name_end];

    var inline_annotation: ?[]const u8 = null;
    if (!opens_block) {
        const after_name = std.mem.trim(u8, body[match.tail_start..], " \t");
        if (after_name.len != 0) {
            if (tryBracedStereotype(after_name)) |stereo| {
                try validateLabel(stereo);
                inline_annotation = stereo;
            } else {
                return;
            }
        }
    }

    const id = try parser.intern(name);
    try parser.recordClassId(id);

    if (match.generic) |gen| {
        try validateLabel(gen);
        const label = try std.fmt.allocPrint(parser.allocator, "{s}<{s}>", .{ name, gen });
        parser.classes.items[id].label = label;
        try parser.owned_labels.append(parser.allocator, label);
    }

    if (inline_annotation) |stereo| {
        parser.classes.items[id].annotation = stereo;
        return;
    }

    if (opens_block) {
        parser.in_block = true;
        parser.block_class = id;

        const after_open = std.mem.trim(u8, body[match.tail_start..], " \t");
        if (after_open.len > 0 and std.mem.endsWith(u8, after_open, "}")) {
            const inner = std.mem.trim(u8, after_open[0 .. after_open.len - 1], " \t");
            if (tryInlineStereotype(inner)) |stereo| {
                try validateLabel(stereo);
                parser.classes.items[id].annotation = stereo;
            }
            parser.in_block = false;
        }
    }
}

const ClassNameMatch = struct {
    /// Index into body where the class name ends.
    name_end: usize,
    /// Inner text of the `~...~` generic parameter, if any.
    generic: ?[]const u8,
    /// Index into body where trailing content (annotation/block) starts.
    tail_start: usize,
};

/// Emulates upstream `^class\s+(\S+?)(?:\s*~(\w+)~)?` with non-greedy `\S+?`:
/// pick the shortest prefix for which `~(\w+)~` matches or the suffix is empty
/// or starts with whitespace. Fall back to the full `\S+` run as a bare ID.
fn matchClassNameAndGeneric(body: []const u8) ?ClassNameMatch {
    if (body.len == 0 or std.ascii.isWhitespace(body[0])) return null;

    var i: usize = 1;
    while (i <= body.len) : (i += 1) {
        if (i < body.len) {
            const c = body[i];
            if (std.ascii.isWhitespace(c)) {
                return .{ .name_end = i, .generic = null, .tail_start = i };
            }
            if (c == '~') {
                if (matchTildeWordTilde(body, i)) |gen_end| {
                    return .{
                        .name_end = i,
                        .generic = body[i + 1 .. gen_end],
                        .tail_start = gen_end + 1,
                    };
                }
            }
        } else {
            return .{ .name_end = body.len, .generic = null, .tail_start = body.len };
        }
    }
    return null;
}

fn matchTildeWordTilde(body: []const u8, start: usize) ?usize {
    if (start >= body.len or body[start] != '~') return null;
    var i: usize = start + 1;
    if (i >= body.len) return null;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == '~') {
            if (i == start + 1) return null;
            return i;
        }
        const is_word = std.ascii.isAlphanumeric(c) or c == '_';
        if (!is_word) return null;
    }
    return null;
}

fn tryInlineStereotype(text: []const u8) ?[]const u8 {
    if (text.len < 4) return null;
    if (!std.mem.startsWith(u8, text, "<<")) return null;
    if (!std.mem.endsWith(u8, text, ">>")) return null;
    const name = std.mem.trim(u8, text[2 .. text.len - 2], " \t");
    if (name.len == 0) return null;
    return name;
}

fn tryBracedStereotype(text: []const u8) ?[]const u8 {
    if (text.len < 2 or text[0] != '{' or text[text.len - 1] != '}') return null;
    const inner = std.mem.trim(u8, text[1 .. text.len - 1], " \t");
    return tryInlineStereotype(inner);
}

fn parseBlockBodyLine(parser: *Parser, line: []const u8) ParseError!void {
    if (std.mem.startsWith(u8, line, "<<") and std.mem.endsWith(u8, line, ">>")) {
        const inner = std.mem.trim(u8, line[2 .. line.len - 2], " \t");
        if (inner.len == 0) return error.InvalidMermaid;
        try validateLabel(inner);
        parser.classes.items[parser.block_class].annotation = inner;
        return;
    }

    try validateLabel(line);
    const member = try parseMemberExpr(line);
    if (member.is_method) {
        try parser.classes.items[parser.block_class].methods.append(parser.allocator, member.value);
    } else {
        try parser.classes.items[parser.block_class].attributes.append(parser.allocator, member.value);
    }
}

const ParsedMember = struct {
    value: types.ClassMember,
    is_method: bool,
};

/// Parses `visibility? rest` where `rest` is either a method
/// `name(params) ReturnType` or an attribute `Type name` (whitespace-split).
/// Upstream equivalent: `src/class/parser.ts parseMember`.
fn parseMemberExpr(line: []const u8) ParseError!ParsedMember {
    var visibility: types.Visibility = .unknown;
    var rest = line;
    if (rest.len > 0) {
        visibility = switch (rest[0]) {
            '+' => .public,
            '-' => .private,
            '#' => .protected,
            '~' => .package,
            else => .unknown,
        };
        if (visibility != .unknown) rest = std.mem.trimLeft(u8, rest[1..], " \t");
    }
    if (rest.len == 0) return error.InvalidMermaid;

    if (std.mem.indexOfScalar(u8, rest, '(')) |open_idx| {
        if (std.mem.indexOfScalarPos(u8, rest, open_idx + 1, ')')) |close_idx| {
            const name_raw = rest[0..open_idx];
            const params = rest[open_idx + 1 .. close_idx];
            const type_raw = std.mem.trimLeft(u8, rest[close_idx + 1 ..], " \t");

            var name = name_raw;
            var is_static = false;
            var is_abstract = false;
            if (name.len > 0 and name[name.len - 1] == '$') {
                is_static = true;
                name = name[0 .. name.len - 1];
            }
            if (name.len > 0 and name[name.len - 1] == '*') {
                is_abstract = true;
                name = name[0 .. name.len - 1];
            }
            if (std.mem.indexOfScalar(u8, rest, '$') != null) is_static = true;
            if (std.mem.indexOfScalar(u8, rest, '*') != null) is_abstract = true;
            const type_text: ?[]const u8 = if (type_raw.len == 0) null else type_raw;

            return .{
                .value = .{
                    .visibility = visibility,
                    .name = name,
                    .type_text = type_text,
                    .is_static = is_static,
                    .is_abstract = is_abstract,
                    .params = params,
                },
                .is_method = true,
            };
        }
    }

    var it = std.mem.tokenizeAny(u8, rest, " \t");
    const first = it.next() orelse return error.InvalidMermaid;
    var last: []const u8 = first;
    while (it.next()) |tok| last = tok;

    var name = last;
    var type_text: ?[]const u8 = if (last.ptr == first.ptr) null else first;
    var is_static = false;
    var is_abstract = false;
    if (name.len > 0 and name[name.len - 1] == '$') {
        is_static = true;
        name = name[0 .. name.len - 1];
    }
    if (name.len > 0 and name[name.len - 1] == '*') {
        is_abstract = true;
        name = name[0 .. name.len - 1];
    }
    _ = &type_text;

    return .{
        .value = .{
            .visibility = visibility,
            .name = name,
            .type_text = type_text,
            .is_static = is_static,
            .is_abstract = is_abstract,
        },
        .is_method = false,
    };
}

const MemberError = ParseError || error{NotMember};

fn parseMemberLine(parser: *Parser, line: []const u8) MemberError!void {
    const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse return error.NotMember;
    const name_part = std.mem.trimRight(u8, line[0..colon_idx], " \t");
    const member_text = std.mem.trimLeft(u8, line[colon_idx + 1 ..], " \t");

    if (name_part.len == 0 or member_text.len == 0) return error.NotMember;
    validateIdent(name_part) catch return error.NotMember;
    try validateLabel(member_text);

    const parsed = try parseMemberExpr(member_text);

    const id = try parser.intern(name_part);
    try parser.recordClassId(id);
    if (parsed.is_method) {
        try parser.classes.items[id].methods.append(parser.allocator, parsed.value);
    } else {
        try parser.classes.items[id].attributes.append(parser.allocator, parsed.value);
    }
}

const RelationOp = struct {
    op: []const u8,
    kind: types.ClassRelationKind,
    marker_at: types.ClassMarkerAt,
};

const relation_ops = [_]RelationOp{
    .{ .op = "<|--", .kind = .inheritance, .marker_at = .from },
    .{ .op = "--|>", .kind = .inheritance, .marker_at = .to },
    .{ .op = "<|..", .kind = .realization, .marker_at = .from },
    .{ .op = "..|>", .kind = .realization, .marker_at = .to },
    .{ .op = "*--", .kind = .composition, .marker_at = .from },
    .{ .op = "--*", .kind = .composition, .marker_at = .to },
    .{ .op = "o--", .kind = .aggregation, .marker_at = .from },
    .{ .op = "--o", .kind = .aggregation, .marker_at = .to },
    .{ .op = "..>", .kind = .dependency, .marker_at = .to },
    .{ .op = "<..", .kind = .dependency, .marker_at = .from },
    .{ .op = "-->", .kind = .association, .marker_at = .to },
    .{ .op = "<--", .kind = .association, .marker_at = .from },
    .{ .op = "--", .kind = .association, .marker_at = .to },
    .{ .op = "..", .kind = .association, .marker_at = .to },
};

const RelationMatch = struct {
    start: usize,
    len: usize,
    kind: types.ClassRelationKind,
    marker_at: types.ClassMarkerAt,
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
                .marker_at = candidate.marker_at,
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

    var lhs_ident = lhs_text;
    var rhs_ident = rhs_text;
    const lhs_card = takeTrailingQuoted(&lhs_ident);
    const rhs_card = takeLeadingQuoted(&rhs_ident);

    try validateIdent(lhs_ident);
    try validateIdent(rhs_ident);

    const lhs_id = try parser.intern(lhs_ident);
    try parser.recordClassId(lhs_id);
    const rhs_id = try parser.intern(rhs_ident);
    try parser.recordClassId(rhs_id);

    try parser.relations.append(parser.allocator, .{
        .from = lhs_id,
        .to = rhs_id,
        .kind = match.kind,
        .marker_at = match.marker_at,
        .label = label,
        .from_cardinality = lhs_card,
        .to_cardinality = rhs_card,
    });
}

fn takeTrailingQuoted(text: *[]const u8) ?[]const u8 {
    const s = std.mem.trimRight(u8, text.*, " \t");
    if (s.len < 2 or s[s.len - 1] != '"') return null;
    var i: usize = s.len - 2;
    while (i > 0 and s[i] != '"') : (i -= 1) {}
    if (s[i] != '"') return null;
    const card = s[i + 1 .. s.len - 1];
    text.* = std.mem.trimRight(u8, s[0..i], " \t");
    return card;
}

fn takeLeadingQuoted(text: *[]const u8) ?[]const u8 {
    const s = std.mem.trimLeft(u8, text.*, " \t");
    if (s.len == 0 or s[0] != '"') return null;
    var i: usize = 1;
    while (i < s.len and s[i] != '"') : (i += 1) {}
    if (i >= s.len) return null;
    const card = s[1..i];
    text.* = std.mem.trimLeft(u8, s[i + 1 ..], " \t");
    return card;
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

test "parses inheritance relation keeps text order and marker_at from" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    Animal <|-- Dog
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.classes.len);
    try std.testing.expectEqual(@as(usize, 1), d.relations.len);
    try std.testing.expectEqual(types.ClassRelationKind.inheritance, d.relations[0].kind);
    try std.testing.expectEqual(types.ClassMarkerAt.from, d.relations[0].marker_at);
    try std.testing.expectEqualStrings("Animal", d.classes[d.relations[0].from].id_text);
    try std.testing.expectEqualStrings("Dog", d.classes[d.relations[0].to].id_text);
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
    try std.testing.expectEqual(types.ClassMarkerAt.from, d.relations[0].marker_at);
    try std.testing.expectEqual(types.ClassRelationKind.aggregation, d.relations[1].kind);
    try std.testing.expectEqual(types.ClassMarkerAt.from, d.relations[1].marker_at);
}

test "parses member fields and methods (upstream Type name split)" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    Animal : +str name
        \\    Animal : +eat()
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.classes.len);
    try std.testing.expectEqual(@as(usize, 1), d.classes[0].attributes.len);
    try std.testing.expectEqual(@as(usize, 1), d.classes[0].methods.len);

    const attr = d.classes[0].attributes[0];
    try std.testing.expectEqual(types.Visibility.public, attr.visibility);
    try std.testing.expectEqualStrings("name", attr.name);
    try std.testing.expectEqualStrings("str", attr.type_text.?);

    const meth = d.classes[0].methods[0];
    try std.testing.expectEqual(types.Visibility.public, meth.visibility);
    try std.testing.expectEqualStrings("eat", meth.name);
    try std.testing.expectEqualStrings("", meth.params.?);
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

test "parses class block with members and annotation" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    class Repository {
        \\        <<interface>>
        \\        +save(entity)
        \\        +findById(id)
        \\    }
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.classes.len);
    try std.testing.expectEqualStrings("interface", d.classes[0].annotation.?);
    try std.testing.expectEqual(@as(usize, 2), d.classes[0].methods.len);
    try std.testing.expectEqual(@as(usize, 0), d.classes[0].attributes.len);
}

test "parses generic class declaration with tilde parameter" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    class List~T~
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.classes.len);
    try std.testing.expectEqualStrings("List", d.classes[0].id_text);
    try std.testing.expectEqualStrings("List<T>", d.classes[0].label);
}

test "parses multi-param tilde generic as raw ID (upstream non-greedy)" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    class Map~K,V~ {
        \\        +get(key) V
        \\    }
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.classes.len);
    try std.testing.expectEqualStrings("Map~K,V~", d.classes[0].id_text);
    try std.testing.expectEqualStrings("Map~K,V~", d.classes[0].label);
    try std.testing.expectEqual(@as(usize, 1), d.classes[0].methods.len);
}

test "parses multi-param tilde standalone class" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    class Map~K,V~
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.classes.len);
    try std.testing.expectEqualStrings("Map~K,V~", d.classes[0].id_text);
    try std.testing.expectEqualStrings("Map~K,V~", d.classes[0].label);
}

test "parses multiplicity and retains cardinality strings" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    Customer "1" --> "*" Order : places
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.relations.len);
    const rel = d.relations[0];
    try std.testing.expectEqualStrings("1", rel.from_cardinality.?);
    try std.testing.expectEqualStrings("*", rel.to_cardinality.?);
    try std.testing.expectEqualStrings("places", rel.label.?);
}

test "silently skips note / namespace lines" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    note "hello"
        \\    class Circle
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.classes.len);
    try std.testing.expectEqualStrings("Circle", d.classes[0].id_text);
}

test "rejects unterminated namespace block" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator,
        \\classDiagram
        \\    namespace Shapes {
        \\        class Circle
    ));
}

test "parses namespace block and inner class" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    namespace Shapes {
        \\        class Circle
        \\        class Square
        \\    }
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.classes.len);
    try std.testing.expectEqualStrings("Circle", d.classes[0].id_text);
    try std.testing.expectEqualStrings("Square", d.classes[1].id_text);
    try std.testing.expectEqual(@as(usize, 1), d.namespaces.len);
    try std.testing.expectEqualStrings("Shapes", d.namespaces[0].name);
    try std.testing.expectEqual(@as(usize, 2), d.namespaces[0].class_ids.len);
    try std.testing.expectEqual(@as(types.NodeId, 0), d.namespaces[0].class_ids[0]);
    try std.testing.expectEqual(@as(types.NodeId, 1), d.namespaces[0].class_ids[1]);
}

test "parses namespace with inner class block and annotation" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    namespace Service {
        \\        class Repository {
        \\            <<interface>>
        \\            +save(entity)
        \\        }
        \\    }
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.classes.len);
    try std.testing.expectEqualStrings("interface", d.classes[0].annotation.?);
    try std.testing.expectEqual(@as(usize, 1), d.classes[0].methods.len);
    try std.testing.expectEqual(@as(usize, 1), d.namespaces.len);
    try std.testing.expectEqualStrings("Service", d.namespaces[0].name);
}

test "parses inline annotation class Foo { <<interface>> }" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    class Repository { <<interface>> }
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.classes.len);
    try std.testing.expectEqualStrings("Repository", d.classes[0].id_text);
    try std.testing.expectEqualStrings("interface", d.classes[0].annotation.?);
}

test "silently ignores trailing annotation class Foo <<interface>>" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    class Repository <<interface>>
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.classes.len);
}

test "parses class attribute Type name split" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    class C {
        \\        +int count
        \\    }
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.classes[0].attributes.len);
    const a = d.classes[0].attributes[0];
    try std.testing.expectEqualStrings("count", a.name);
    try std.testing.expectEqualStrings("int", a.type_text.?);
    try std.testing.expect(!a.is_static);
    try std.testing.expect(!a.is_abstract);
}

test "parses class static attribute" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    class C {
        \\        +count$
        \\    }
    );
    defer d.deinit();
    const a = d.classes[0].attributes[0];
    try std.testing.expectEqualStrings("count", a.name);
    try std.testing.expect(a.is_static);
}

test "parses class method with return type" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    class C {
        \\        +save(entity) Result
        \\    }
    );
    defer d.deinit();
    const m = d.classes[0].methods[0];
    try std.testing.expectEqualStrings("save", m.name);
    try std.testing.expectEqualStrings("entity", m.params.?);
    try std.testing.expectEqualStrings("Result", m.type_text.?);
}

test "parses class abstract method with star after paren" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    class C {
        \\        +run()*
        \\    }
    );
    defer d.deinit();
    const m = d.classes[0].methods[0];
    try std.testing.expectEqualStrings("run", m.name);
    try std.testing.expect(m.is_abstract);
    try std.testing.expectEqualStrings("*", m.type_text.?);
}

test "parses class abstract method with star in name" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    class C {
        \\        +run*()
        \\    }
    );
    defer d.deinit();
    const m = d.classes[0].methods[0];
    try std.testing.expectEqualStrings("run", m.name);
    try std.testing.expect(m.is_abstract);
}

test "accepts dotted class IDs in relations" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    com.example.Foo --> com.example.Bar
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.classes.len);
    try std.testing.expectEqualStrings("com.example.Foo", d.classes[0].id_text);
    try std.testing.expectEqualStrings("com.example.Bar", d.classes[1].id_text);
    try std.testing.expectEqual(@as(usize, 1), d.relations.len);
}

test "inheritance right-side marker places marker_at on to" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    Dog --|> Cat
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.relations.len);
    try std.testing.expectEqual(types.ClassRelationKind.inheritance, d.relations[0].kind);
    try std.testing.expectEqual(types.ClassMarkerAt.to, d.relations[0].marker_at);
    try std.testing.expectEqualStrings("Dog", d.classes[d.relations[0].from].id_text);
    try std.testing.expectEqualStrings("Cat", d.classes[d.relations[0].to].id_text);
}

test "bare -- is association with marker_at to" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    A -- B
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.relations.len);
    try std.testing.expectEqual(types.ClassRelationKind.association, d.relations[0].kind);
    try std.testing.expectEqual(types.ClassMarkerAt.to, d.relations[0].marker_at);
}

test "silently skips separate-line <<annotation>> shorthand" {
    var d = try parseSource(std.testing.allocator,
        \\classDiagram
        \\    <<interface>> Repository
        \\    class Repository
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.classes.len);
    try std.testing.expect(d.classes[0].annotation == null);
}
