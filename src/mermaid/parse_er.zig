const std = @import("std");
const source_mod = @import("source.zig");
const types = @import("types.zig");

pub const Source = source_mod.Source;

pub const ParseError = error{
    InvalidMermaid,
    UnsupportedFeature,
    TooManyEntities,
    OutOfMemory,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    entities: std.ArrayListUnmanaged(BuildingEntity) = .empty,
    relations: std.ArrayListUnmanaged(types.ErRelation) = .empty,
    interned: std.StringHashMapUnmanaged(types.NodeId) = .empty,
    owned_strings: std.ArrayListUnmanaged([]u8) = .empty,

    const BuildingEntity = struct {
        id_text: []const u8,
        attributes: std.ArrayListUnmanaged(types.ErAttribute) = .empty,
    };

    fn intern(self: *Parser, id_text: []const u8) ParseError!types.NodeId {
        const gop = try self.interned.getOrPut(self.allocator, id_text);
        if (gop.found_existing) return gop.value_ptr.*;
        if (self.entities.items.len >= types.max_nodes) return error.TooManyEntities;
        const new_id: types.NodeId = @intCast(self.entities.items.len);
        try self.entities.append(self.allocator, .{ .id_text = id_text });
        gop.value_ptr.* = new_id;
        return new_id;
    }

    fn addAttribute(self: *Parser, id: types.NodeId, attr: types.ErAttribute) ParseError!void {
        try self.entities.items[id].attributes.append(self.allocator, attr);
    }
};

fn validateIdent(text: []const u8) ParseError!void {
    if (text.len == 0) return error.InvalidMermaid;
    for (text, 0..) |b, i| {
        const is_alpha = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z');
        const is_digit = b >= '0' and b <= '9';
        const is_underscore = b == '_';
        const is_hyphen = b == '-';
        if (i == 0) {
            if (!is_alpha) return error.InvalidMermaid;
        } else {
            if (!is_alpha and !is_digit and !is_underscore and !is_hyphen) return error.InvalidMermaid;
        }
    }
}

pub fn parseSource(allocator: std.mem.Allocator, source: anytype) ParseError!types.ErDiagram {
    const owned_source: []u8 = if (@TypeOf(source) == Source) switch (source) {
        .borrowed => |s| try allocator.dupe(u8, s),
        .owned => |s| s,
    } else try allocator.dupe(u8, source);
    return parseFromOwned(allocator, owned_source);
}

fn parseFromOwned(allocator: std.mem.Allocator, owned_source: []u8) ParseError!types.ErDiagram {
    var parser: Parser = .{ .allocator = allocator };
    defer parser.interned.deinit(allocator);
    errdefer {
        for (parser.entities.items) |*e| e.attributes.deinit(allocator);
        parser.entities.deinit(allocator);
        parser.relations.deinit(allocator);
        for (parser.owned_strings.items) |s| allocator.free(s);
        parser.owned_strings.deinit(allocator);
    }

    {
        errdefer allocator.free(owned_source);
        try parser.owned_strings.append(allocator, owned_source);
    }

    var header_seen = false;
    var in_block = false;
    var block_entity: types.NodeId = 0;

    var it = std.mem.splitScalar(u8, owned_source, '\n');
    while (it.next()) |raw| {
        const stripped_cr = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, stripped_cr, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "%%")) continue;

        if (!header_seen) {
            if (!std.ascii.eqlIgnoreCase(trimmed, "erDiagram")) return error.InvalidMermaid;
            header_seen = true;
            continue;
        }

        if (in_block) {
            if (std.mem.eql(u8, trimmed, "}")) {
                in_block = false;
                continue;
            }
            try parseAttributeLine(&parser, block_entity, trimmed);
            continue;
        }

        if (isDirectionLine(trimmed)) return error.UnsupportedFeature;
        if (hasAliasSyntax(trimmed)) return error.UnsupportedFeature;
        if (hasQuotedName(trimmed)) return error.UnsupportedFeature;

        if (tryParseRelation(&parser, trimmed)) |_| continue else |err| switch (err) {
            error.NotRelation => {},
            else => |e| return e,
        }

        if (tryParseBlockHeader(&parser, trimmed)) |open_result| {
            block_entity = open_result.id;
            in_block = !open_result.closed_inline;
            continue;
        } else |err| switch (err) {
            error.NotBlockHeader => {},
            else => |e| return e,
        }

        try validateIdent(trimmed);
        _ = try parser.intern(trimmed);
    }

    if (!header_seen) return error.InvalidMermaid;
    if (in_block) return error.InvalidMermaid;

    const entities = try allocator.alloc(types.ErEntity, parser.entities.items.len);
    errdefer allocator.free(entities);
    for (parser.entities.items, 0..) |*b, i| {
        const attrs = try b.attributes.toOwnedSlice(allocator);
        entities[i] = .{
            .id = @intCast(i),
            .id_text = b.id_text,
            .attributes = attrs,
        };
    }
    parser.entities.deinit(allocator);

    const relations = try parser.relations.toOwnedSlice(allocator);
    const owned_strings = try parser.owned_strings.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .entities = entities,
        .relations = relations,
        .owned_strings = owned_strings,
    };
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

fn isDirectionLine(line: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(line, "direction")) return false;
    if (line.len == "direction".len) return true;
    const next = line["direction".len];
    return next == ' ' or next == '\t';
}

fn hasAliasSyntax(line: []const u8) bool {
    for (line, 0..) |b, i| {
        if (b == '[') return true;
        if (b == ' ' or b == '\t' or b == '{') return false;
        _ = i;
    }
    return false;
}

fn hasQuotedName(line: []const u8) bool {
    return line.len > 0 and line[0] == '"';
}

const BlockOpenResult = struct { id: types.NodeId, closed_inline: bool };
const BlockHeaderError = ParseError || error{NotBlockHeader};

fn tryParseBlockHeader(parser: *Parser, line: []const u8) BlockHeaderError!BlockOpenResult {
    const brace_idx = std.mem.indexOfScalar(u8, line, '{') orelse return error.NotBlockHeader;
    const name = std.mem.trim(u8, line[0..brace_idx], " \t");
    const rest = std.mem.trim(u8, line[brace_idx + 1 ..], " \t");

    try validateIdent(name);
    const id = try parser.intern(name);

    if (rest.len == 0) return .{ .id = id, .closed_inline = false };
    if (std.mem.eql(u8, rest, "}")) return .{ .id = id, .closed_inline = true };

    return error.InvalidMermaid;
}

fn parseAttributeLine(parser: *Parser, entity_id: types.NodeId, line: []const u8) ParseError!void {
    if (std.mem.startsWith(u8, line, "%%")) return;

    var tokens: [6][]const u8 = undefined;
    var count: usize = 0;

    var i: usize = 0;
    while (i < line.len and count < tokens.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len) break;

        if (line[i] == '"') {
            const start = i + 1;
            var j = start;
            while (j < line.len and line[j] != '"') : (j += 1) {}
            if (j >= line.len) return error.InvalidMermaid;
            tokens[count] = line[start..j];
            count += 1;
            i = j + 1;
            continue;
        }

        const start = i;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
        tokens[count] = line[start..i];
        count += 1;
    }

    if (count < 2) return error.InvalidMermaid;

    var attr: types.ErAttribute = .{
        .type_text = tokens[0],
        .name = tokens[1],
    };

    var next: usize = 2;
    while (next < count) : (next += 1) {
        const tag = tokens[next];
        if (std.ascii.eqlIgnoreCase(tag, "PK")) {
            attr.mark.pk = true;
        } else if (std.ascii.eqlIgnoreCase(tag, "FK")) {
            attr.mark.fk = true;
        } else if (std.ascii.eqlIgnoreCase(tag, "UK")) {
            attr.mark.uk = true;
        } else {
            break;
        }
    }

    if (next < count) {
        attr.comment = try normalizeLabel(parser, tokens[next]);
        next += 1;
    }

    if (next != count) return error.InvalidMermaid;

    try parser.addAttribute(entity_id, attr);
}

const RelationMatch = struct {
    left_card: types.ErCardinality,
    right_card: types.ErCardinality,
    identifying: bool,
    op_start: usize,
    op_len: usize,
};

const RelationError = ParseError || error{NotRelation};

fn tryParseRelation(parser: *Parser, line: []const u8) RelationError!void {
    const match = findRelation(line) orelse return error.NotRelation;

    const lhs_text = std.mem.trimEnd(u8, line[0..match.op_start], " \t");
    const after = line[match.op_start + match.op_len ..];

    const colon_idx = std.mem.indexOfScalar(u8, after, ':') orelse return error.InvalidMermaid;
    const rhs_text = std.mem.trim(u8, after[0..colon_idx], " \t");
    const label_raw = std.mem.trim(u8, after[colon_idx + 1 ..], " \t");
    const stripped = stripQuotes(label_raw);
    if (stripped.len == 0) return error.InvalidMermaid;
    const label = try normalizeLabel(parser, stripped);

    if (hasAliasOrQuote(lhs_text) or hasAliasOrQuote(rhs_text)) return error.UnsupportedFeature;

    try validateIdent(lhs_text);
    try validateIdent(rhs_text);

    const lhs_id = try parser.intern(lhs_text);
    const rhs_id = try parser.intern(rhs_text);

    try parser.relations.append(parser.allocator, .{
        .from = lhs_id,
        .to = rhs_id,
        .left = match.left_card,
        .right = match.right_card,
        .identifying = match.identifying,
        .label = label,
    });
}

fn stripQuotes(text: []const u8) []const u8 {
    if (text.len >= 2) {
        const first = text[0];
        const last = text[text.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return text[1 .. text.len - 1];
        }
    }
    return text;
}

fn hasAliasOrQuote(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] == '"') return true;
    return std.mem.indexOfScalar(u8, text, '[') != null;
}

fn findRelation(line: []const u8) ?RelationMatch {
    var idx: usize = 0;
    while (idx + 2 <= line.len) : (idx += 1) {
        const connector = line[idx .. idx + 2];
        const identifying = std.mem.eql(u8, connector, "--");
        const non_ident = std.mem.eql(u8, connector, "..");
        if (!identifying and !non_ident) continue;

        if (idx == 0 or idx + 2 >= line.len) continue;
        const before_end = idx;
        const after_start = idx + 2;

        const left_card = matchLeftCardinality(line, before_end) orelse continue;
        const right_card = matchRightCardinality(line, after_start) orelse continue;

        return .{
            .left_card = left_card.kind,
            .right_card = right_card.kind,
            .identifying = identifying,
            .op_start = left_card.start,
            .op_len = (after_start + right_card.len) - left_card.start,
        };
    }
    return null;
}

const LeftCardMatch = struct { kind: types.ErCardinality, start: usize };
const RightCardMatch = struct { kind: types.ErCardinality, len: usize };

fn matchLeftCardinality(line: []const u8, before_end: usize) ?LeftCardMatch {
    if (before_end < 2) return matchLeftSingle(line, before_end);
    const two = line[before_end - 2 .. before_end];
    if (std.mem.eql(u8, two, "||")) return .{ .kind = .exactly_one, .start = before_end - 2 };
    if (std.mem.eql(u8, two, "o|")) return .{ .kind = .zero_or_one, .start = before_end - 2 };
    if (std.mem.eql(u8, two, "}o")) return .{ .kind = .zero_or_many, .start = before_end - 2 };
    if (std.mem.eql(u8, two, "}|")) return .{ .kind = .one_or_many, .start = before_end - 2 };
    return matchLeftSingle(line, before_end);
}

fn matchLeftSingle(line: []const u8, before_end: usize) ?LeftCardMatch {
    if (before_end == 0) return null;
    const c = line[before_end - 1];
    return switch (c) {
        '|' => .{ .kind = .exactly_one, .start = before_end - 1 },
        else => null,
    };
}

fn matchRightCardinality(line: []const u8, after_start: usize) ?RightCardMatch {
    if (after_start + 2 <= line.len) {
        const two = line[after_start .. after_start + 2];
        if (std.mem.eql(u8, two, "||")) return .{ .kind = .exactly_one, .len = 2 };
        if (std.mem.eql(u8, two, "|o")) return .{ .kind = .zero_or_one, .len = 2 };
        if (std.mem.eql(u8, two, "o{")) return .{ .kind = .zero_or_many, .len = 2 };
        if (std.mem.eql(u8, two, "|{")) return .{ .kind = .one_or_many, .len = 2 };
    }
    if (after_start < line.len and line[after_start] == '|') {
        return .{ .kind = .exactly_one, .len = 1 };
    }
    return null;
}

test "parses erDiagram header only" {
    var d = try parseSource(std.testing.allocator, "erDiagram\n");
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.entities.len);
    try std.testing.expectEqual(@as(usize, 0), d.relations.len);
}

test "parses simple relation ||--o{" {
    var d = try parseSource(std.testing.allocator,
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.entities.len);
    try std.testing.expectEqual(@as(usize, 1), d.relations.len);
    try std.testing.expectEqual(types.ErCardinality.exactly_one, d.relations[0].left);
    try std.testing.expectEqual(types.ErCardinality.zero_or_many, d.relations[0].right);
    try std.testing.expect(d.relations[0].identifying);
    try std.testing.expectEqualStrings("places", d.relations[0].label);
}

test "parses entity with attributes PK/FK" {
    var d = try parseSource(std.testing.allocator,
        \\erDiagram
        \\    CUSTOMER {
        \\        string id PK
        \\        string name
        \\        int shop_id FK
        \\    }
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.entities.len);
    try std.testing.expectEqual(@as(usize, 3), d.entities[0].attributes.len);
    try std.testing.expect(d.entities[0].attributes[0].mark.pk);
    try std.testing.expect(!d.entities[0].attributes[0].mark.fk);
    try std.testing.expectEqualStrings("id", d.entities[0].attributes[0].name);
    try std.testing.expect(d.entities[0].attributes[1].mark.isEmpty());
    try std.testing.expect(d.entities[0].attributes[2].mark.fk);
    try std.testing.expect(!d.entities[0].attributes[2].mark.pk);
}

test "parses attribute with multiple key constraints (PK + FK)" {
    var d = try parseSource(std.testing.allocator,
        \\erDiagram
        \\    ORDER_ITEM {
        \\        int order_id PK FK
        \\        int product_id PK FK
        \\    }
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.entities[0].attributes.len);
    try std.testing.expect(d.entities[0].attributes[0].mark.pk);
    try std.testing.expect(d.entities[0].attributes[0].mark.fk);
    try std.testing.expect(d.entities[0].attributes[1].mark.pk);
    try std.testing.expect(d.entities[0].attributes[1].mark.fk);
}

test "normalises <br> in relation label to a space" {
    var d = try parseSource(std.testing.allocator,
        \\erDiagram
        \\    A ||--|| B : "one<br>per<BR>kind"
    );
    defer d.deinit();
    try std.testing.expectEqualStrings("one per kind", d.relations[0].label);
}

test "normalises <br/> in attribute comment" {
    var d = try parseSource(std.testing.allocator,
        \\erDiagram
        \\    USER {
        \\        string note "first<br/>second"
        \\    }
    );
    defer d.deinit();
    try std.testing.expectEqualStrings("first second", d.entities[0].attributes[0].comment.?);
}

test "parses attribute with PK UK combined" {
    var d = try parseSource(std.testing.allocator,
        \\erDiagram
        \\    USER {
        \\        string email PK UK "unique email"
        \\    }
    );
    defer d.deinit();
    const attr = d.entities[0].attributes[0];
    try std.testing.expect(attr.mark.pk);
    try std.testing.expect(attr.mark.uk);
    try std.testing.expectEqualStrings("unique email", attr.comment.?);
}

test "parses standalone entity declaration" {
    var d = try parseSource(std.testing.allocator,
        \\erDiagram
        \\    ORDER
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.entities.len);
    try std.testing.expectEqualStrings("ORDER", d.entities[0].id_text);
    try std.testing.expectEqual(@as(usize, 0), d.entities[0].attributes.len);
}

test "parses standalone entity with empty block" {
    var d = try parseSource(std.testing.allocator,
        \\erDiagram
        \\    ORDER { }
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.entities.len);
    try std.testing.expectEqual(@as(usize, 0), d.entities[0].attributes.len);
}

test "parses hyphenated identifier LINE-ITEM" {
    var d = try parseSource(std.testing.allocator,
        \\erDiagram
        \\    ORDER ||--|{ LINE-ITEM : contains
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.entities.len);
    try std.testing.expectEqualStrings("LINE-ITEM", d.entities[1].id_text);
}

test "rejects direction LR line" {
    try std.testing.expectError(error.UnsupportedFeature, parseSource(std.testing.allocator,
        \\erDiagram
        \\    direction LR
        \\    CUSTOMER ||--o{ ORDER : places
    ));
}

test "silently skips init directive" {
    var d = try parseSource(std.testing.allocator,
        \\%%{init: {"theme": "dark"}}%%
        \\erDiagram
        \\    CUSTOMER ||--o{ ORDER : places
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.entities.len);
    try std.testing.expectEqual(@as(usize, 1), d.relations.len);
}

test "rejects missing header" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator, "CUSTOMER ||--o{ ORDER : places\n"));
}

test "rejects alias syntax" {
    try std.testing.expectError(error.UnsupportedFeature, parseSource(std.testing.allocator,
        \\erDiagram
        \\    CUSTOMER["Customer entity"]
    ));
}

test "rejects alias on the right-hand side of a relation" {
    try std.testing.expectError(error.UnsupportedFeature, parseSource(std.testing.allocator,
        \\erDiagram
        \\    A ||--|| B["Bee"] : r
    ));
}

test "rejects quoted entity name on the left-hand side of a relation" {
    try std.testing.expectError(error.UnsupportedFeature, parseSource(std.testing.allocator,
        \\erDiagram
        \\    "Customer Order" ||--o{ ORDER : places
    ));
}
