const std = @import("std");
const types = @import("types.zig");
const width_mod = @import("../term/width.zig");

pub const ParseError = error{
    InvalidMermaid,
    UnsupportedFeature,
    TooManyParticipants,
    OutOfMemory,
};

const BlockContext = struct {
    kind: types.SequenceBlockKind,
    label: []const u8,
    start_index: u32,
    source_order: u32,
    dividers: std.ArrayListUnmanaged(types.SequenceBlockDivider),
};

const Parser = struct {
    allocator: std.mem.Allocator,
    participants: std.ArrayListUnmanaged(types.Participant) = .empty,
    messages: std.ArrayListUnmanaged(types.SequenceMessage) = .empty,
    notes: std.ArrayListUnmanaged(types.SequenceNote) = .empty,
    blocks: std.ArrayListUnmanaged(types.SequenceBlock) = .empty,
    ctx_stack: std.ArrayListUnmanaged(BlockContext) = .empty,
    block_counter: u32 = 0,
    interned: std.StringHashMapUnmanaged(types.ParticipantId) = .empty,
    owned_strings: std.ArrayListUnmanaged([]u8) = .empty,

    fn intern(self: *Parser, id_text: []const u8, label: []const u8) ParseError!types.ParticipantId {
        const gop = try self.interned.getOrPut(self.allocator, id_text);
        if (gop.found_existing) return gop.value_ptr.*;
        if (self.participants.items.len >= std.math.maxInt(types.ParticipantId)) return error.TooManyParticipants;
        const new_id: types.ParticipantId = @intCast(self.participants.items.len);
        try self.participants.append(self.allocator, .{
            .id = new_id,
            .id_text = id_text,
            .label = label,
        });
        gop.value_ptr.* = new_id;
        return new_id;
    }

    fn updateLabel(self: *Parser, id: types.ParticipantId, label: []const u8) void {
        self.participants.items[id].label = label;
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

pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) ParseError!types.SequenceDiagram {
    var parser: Parser = .{ .allocator = allocator };
    defer parser.interned.deinit(allocator);
    defer {
        for (parser.ctx_stack.items) |*ctx| ctx.dividers.deinit(allocator);
        parser.ctx_stack.deinit(allocator);
    }
    errdefer parser.participants.deinit(allocator);
    errdefer parser.messages.deinit(allocator);
    errdefer {
        for (parser.notes.items) |n| {
            if (n.actor_ids.len > 0) allocator.free(n.actor_ids);
        }
        parser.notes.deinit(allocator);
    }
    errdefer {
        for (parser.blocks.items) |b| {
            if (b.dividers.len > 0) allocator.free(b.dividers);
        }
        parser.blocks.deinit(allocator);
    }
    errdefer {
        for (parser.owned_strings.items) |s| allocator.free(s);
        parser.owned_strings.deinit(allocator);
    }

    var header_seen = false;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        const stripped_cr = std.mem.trimRight(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, stripped_cr, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "%%")) continue;

        if (!header_seen) {
            if (!std.ascii.eqlIgnoreCase(trimmed, "sequenceDiagram")) return error.InvalidMermaid;
            header_seen = true;
            continue;
        }

        try parseLine(&parser, trimmed);
    }

    if (!header_seen) return error.InvalidMermaid;

    const participants = try parser.participants.toOwnedSlice(allocator);
    errdefer allocator.free(participants);
    const messages = try parser.messages.toOwnedSlice(allocator);
    errdefer allocator.free(messages);
    const notes = try parser.notes.toOwnedSlice(allocator);
    errdefer {
        for (notes) |n| {
            if (n.actor_ids.len > 0) allocator.free(n.actor_ids);
        }
        allocator.free(notes);
    }
    const blocks = try parser.blocks.toOwnedSlice(allocator);
    errdefer {
        for (blocks) |b| {
            if (b.dividers.len > 0) allocator.free(b.dividers);
        }
        allocator.free(blocks);
    }
    const owned_strings = try parser.owned_strings.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .participants = participants,
        .messages = messages,
        .notes = notes,
        .blocks = blocks,
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

fn parseLine(parser: *Parser, line: []const u8) ParseError!void {
    if (isSilentlySkipped(line)) return;

    if (parseDivider(line)) |_| return;

    if (std.mem.eql(u8, line, "end")) {
        if (parser.ctx_stack.items.len > 0) {
            var ctx = parser.ctx_stack.pop().?;
            const msg_len: u32 = @intCast(parser.messages.items.len);
            const end_idx: u32 = if (msg_len > 0) @max(msg_len - 1, ctx.start_index) else ctx.start_index;
            const divs = try ctx.dividers.toOwnedSlice(parser.allocator);
            const parent_order: ?u32 = if (parser.ctx_stack.items.len > 0)
                parser.ctx_stack.items[parser.ctx_stack.items.len - 1].source_order
            else
                null;
            try parser.blocks.append(parser.allocator, .{
                .kind = ctx.kind,
                .label = ctx.label,
                .start_index = ctx.start_index,
                .end_index = end_idx,
                .source_order = ctx.source_order,
                .parent_order = parent_order,
                .dividers = divs,
            });
        }
        return;
    }

    if (try tryParseElseAnd(parser, line)) return;

    if (parseBlockKeyword(line)) |bk| {
        const order = parser.block_counter;
        parser.block_counter += 1;
        try parser.ctx_stack.append(parser.allocator, .{
            .kind = bk.kind,
            .label = bk.label,
            .start_index = @intCast(parser.messages.items.len),
            .source_order = order,
            .dividers = .empty,
        });
        return;
    }

    if (try tryParseNote(parser, line)) return;

    if (isActivationLine(line)) return;

    if (tryParseParticipant(parser, line)) |_| return else |err| switch (err) {
        error.NotParticipant => {},
        error.InvalidMermaid => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.TooManyParticipants => return error.TooManyParticipants,
        error.OutOfMemory => return error.OutOfMemory,
    }

    parseMessage(parser, line) catch |err| switch (err) {
        error.InvalidMermaid => {},
        error.UnsupportedFeature => {},
        else => return err,
    };
}

fn isSilentlySkipped(line: []const u8) bool {
    const prefixes = [_][]const u8{
        "autonumber", "create ",
        "destroy ",   "link ",
        "links ",     "properties ",
    };
    for (prefixes) |kw| {
        if (std.ascii.startsWithIgnoreCase(line, kw)) return true;
        const bare = if (kw[kw.len - 1] == ' ') kw[0 .. kw.len - 1] else kw;
        if (std.ascii.eqlIgnoreCase(line, bare)) return true;
    }
    return false;
}

fn parseDivider(line: []const u8) ?[]const u8 {
    if (line.len < 4) return null;
    if (!std.mem.startsWith(u8, line, "==")) return null;
    if (!std.mem.endsWith(u8, line, "==")) return null;
    return std.mem.trim(u8, line[2 .. line.len - 2], " \t");
}

const BlockMatch = struct { kind: types.SequenceBlockKind, label: []const u8 };

fn parseBlockKeyword(line: []const u8) ?BlockMatch {
    const keywords = [_]struct { prefix: []const u8, kind: types.SequenceBlockKind }{
        .{ .prefix = "loop ", .kind = .loop },
        .{ .prefix = "alt ", .kind = .alt },
        .{ .prefix = "opt ", .kind = .opt },
        .{ .prefix = "par ", .kind = .par },
        .{ .prefix = "critical ", .kind = .critical },
        .{ .prefix = "rect ", .kind = .rect },
        .{ .prefix = "break ", .kind = .break_ },
    };

    for (keywords) |kw| {
        // Case-sensitive matching (upstream does not use /i for block keywords)
        if (std.mem.startsWith(u8, line, kw.prefix)) {
            return .{
                .kind = kw.kind,
                .label = std.mem.trim(u8, line[kw.prefix.len..], " \t"),
            };
        }
        const bare = kw.prefix[0 .. kw.prefix.len - 1];
        if (std.mem.eql(u8, line, bare)) {
            return .{ .kind = kw.kind, .label = "" };
        }
    }
    return null;
}

fn tryParseElseAnd(parser: *Parser, line: []const u8) ParseError!bool {
    if (parser.ctx_stack.items.len == 0) return false;

    var label: []const u8 = undefined;
    if (std.mem.eql(u8, line, "else")) {
        label = "";
    } else if (std.mem.startsWith(u8, line, "else ")) {
        label = std.mem.trim(u8, line["else ".len..], " \t");
    } else if (std.mem.eql(u8, line, "and")) {
        label = "";
    } else if (std.mem.startsWith(u8, line, "and ")) {
        label = std.mem.trim(u8, line["and ".len..], " \t");
    } else if (std.mem.eql(u8, line, "option")) {
        label = "";
    } else if (std.mem.startsWith(u8, line, "option ")) {
        label = std.mem.trim(u8, line["option ".len..], " \t");
    } else {
        return false;
    }

    const top = &parser.ctx_stack.items[parser.ctx_stack.items.len - 1];
    try top.dividers.append(parser.allocator, .{
        .message_index = @intCast(parser.messages.items.len),
        .label = label,
    });
    return true;
}

fn tryParseNote(parser: *Parser, line: []const u8) ParseError!bool {
    // Note is case-insensitive (upstream uses /i flag)
    if (!std.ascii.startsWithIgnoreCase(line, "note ")) return false;

    var rest = std.mem.trimLeft(u8, line["note ".len..], " \t");

    var placement: types.NotePlacement = undefined;
    if (std.ascii.startsWithIgnoreCase(rest, "right of ")) {
        placement = .right_of;
        rest = rest["right of ".len..];
    } else if (std.ascii.startsWithIgnoreCase(rest, "left of ")) {
        placement = .left_of;
        rest = rest["left of ".len..];
    } else if (std.ascii.startsWithIgnoreCase(rest, "over ")) {
        placement = .over;
        rest = rest["over ".len..];
    } else {
        return false;
    }

    const colon_idx = std.mem.indexOfScalar(u8, rest, ':') orelse return false;
    const participants_text = std.mem.trim(u8, rest[0..colon_idx], " \t");
    const raw_text = std.mem.trim(u8, rest[colon_idx + 1 ..], " \t");
    if (participants_text.len == 0) return false;

    var ids_buf: [2]types.ParticipantId = undefined;
    var ids_len: usize = 0;

    if (placement == .over) {
        if (std.mem.indexOfScalar(u8, participants_text, ',')) |comma| {
            const p1 = std.mem.trim(u8, participants_text[0..comma], " \t");
            const p2 = std.mem.trim(u8, participants_text[comma + 1 ..], " \t");
            if (p1.len == 0 or p2.len == 0) return false;
            try validateSequenceActorId(p1);
            try validateSequenceActorId(p2);
            ids_buf[0] = try parser.intern(p1, p1);
            ids_buf[1] = try parser.intern(p2, p2);
            ids_len = 2;
        } else {
            try validateSequenceActorId(participants_text);
            ids_buf[0] = try parser.intern(participants_text, participants_text);
            ids_len = 1;
        }
    } else {
        try validateSequenceActorId(participants_text);
        ids_buf[0] = try parser.intern(participants_text, participants_text);
        ids_len = 1;
    }

    try validateLabel(raw_text);
    const text = try normalizeLabel(parser, raw_text);

    const actor_ids = try parser.allocator.alloc(types.ParticipantId, ids_len);
    @memcpy(actor_ids, ids_buf[0..ids_len]);

    const ai: i32 = @as(i32, @intCast(parser.messages.items.len)) - 1;
    try parser.notes.append(parser.allocator, .{
        .actor_ids = actor_ids,
        .text = text,
        .placement = placement,
        .after_index = ai,
    });
    return true;
}

fn isActivationLine(line: []const u8) bool {
    // Standalone activate/deactivate: silently accepted and ignored
    // (upstream: activation is from +/- shortcut on messages only)
    if (std.ascii.startsWithIgnoreCase(line, "activate ")) return true;
    if (std.ascii.startsWithIgnoreCase(line, "deactivate ")) return true;
    if (std.ascii.eqlIgnoreCase(line, "activate")) return true;
    if (std.ascii.eqlIgnoreCase(line, "deactivate")) return true;
    return false;
}

const ParticipantError = ParseError || error{NotParticipant};

fn tryParseParticipant(parser: *Parser, line: []const u8) ParticipantError!void {
    const keyword_participant = "participant ";
    const keyword_actor = "actor ";

    var kind: types.ParticipantKind = .participant;
    const rest = if (std.mem.startsWith(u8, line, keyword_participant))
        line[keyword_participant.len..]
    else if (std.mem.startsWith(u8, line, keyword_actor)) blk: {
        kind = .actor;
        break :blk line[keyword_actor.len..];
    } else return error.NotParticipant;

    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) return error.InvalidMermaid;

    const as_marker = " as ";
    if (std.mem.indexOf(u8, trimmed, as_marker)) |idx| {
        const id_text = std.mem.trimRight(u8, trimmed[0..idx], " \t");
        const raw_label = std.mem.trimLeft(u8, trimmed[idx + as_marker.len ..], " \t");
        if (id_text.len == 0 or raw_label.len == 0) return error.InvalidMermaid;
        try validateSequenceActorId(id_text);
        try validateLabel(raw_label);
        const label = try normalizeLabel(parser, raw_label);
        const id = try parser.intern(id_text, label);
        parser.updateLabel(id, label);
        parser.participants.items[id].kind = kind;
        return;
    }

    try validateSequenceActorId(trimmed);
    const id = try parser.intern(trimmed, trimmed);
    parser.participants.items[id].kind = kind;
}

/// Upstream `\S+?` equivalent: accepts any non-empty string without
/// whitespace characters.
fn validateSequenceActorId(text: []const u8) ParseError!void {
    if (text.len == 0) return error.InvalidMermaid;
    for (text) |b| {
        if (std.ascii.isWhitespace(b)) return error.InvalidMermaid;
    }
}

const ArrowMatch = struct {
    start: usize,
    len: usize,
    line_style: types.LineStyle,
    arrow_head: types.ArrowHead,
};

fn findMessageArrow(text: []const u8) ?ArrowMatch {
    const candidates = [_]struct {
        op: []const u8,
        line_style: types.LineStyle,
        arrow_head: types.ArrowHead,
    }{
        .{ .op = "-->>", .line_style = .dashed, .arrow_head = .filled },
        .{ .op = "--)", .line_style = .dashed, .arrow_head = .open },
        .{ .op = "--x", .line_style = .dashed, .arrow_head = .filled },
        .{ .op = "->>", .line_style = .solid, .arrow_head = .filled },
        .{ .op = "-)", .line_style = .solid, .arrow_head = .open },
        .{ .op = "-x", .line_style = .solid, .arrow_head = .filled },
        .{ .op = "-->", .line_style = .dashed, .arrow_head = .open },
        .{ .op = "->", .line_style = .solid, .arrow_head = .open },
    };

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        for (candidates) |c| {
            if (i + c.op.len > text.len) continue;
            if (!std.mem.eql(u8, text[i .. i + c.op.len], c.op)) continue;
            if (i > 0 and text[i - 1] == '-') continue;
            return .{
                .start = i,
                .len = c.op.len,
                .line_style = c.line_style,
                .arrow_head = c.arrow_head,
            };
        }
    }
    return null;
}

fn parseMessage(parser: *Parser, line: []const u8) ParseError!void {
    const arrow = findMessageArrow(line) orelse return error.InvalidMermaid;

    const from_text = std.mem.trim(u8, line[0..arrow.start], " \t");
    var after_arrow = line[arrow.start + arrow.len ..];

    var activate = false;
    var deactivate = false;
    const lead = std.mem.trimLeft(u8, after_arrow, " \t");
    if (lead.len > 0 and lead[0] == '+') {
        activate = true;
        const ws_len = after_arrow.len - lead.len;
        after_arrow = after_arrow[ws_len + 1 ..];
    } else if (lead.len > 0 and lead[0] == '-') {
        deactivate = true;
        const ws_len = after_arrow.len - lead.len;
        after_arrow = after_arrow[ws_len + 1 ..];
    }

    const colon_idx = std.mem.indexOfScalar(u8, after_arrow, ':') orelse return error.InvalidMermaid;
    const to_text = std.mem.trim(u8, after_arrow[0..colon_idx], " \t");
    const raw_label = std.mem.trim(u8, after_arrow[colon_idx + 1 ..], " \t");

    try validateSequenceActorId(from_text);
    try validateSequenceActorId(to_text);
    try validateLabel(raw_label);
    const label = try normalizeLabel(parser, raw_label);

    const from_id = try parser.intern(from_text, from_text);
    const to_id = try parser.intern(to_text, to_text);

    try parser.messages.append(parser.allocator, .{
        .from = from_id,
        .to = to_id,
        .label = label,
        .line_style = arrow.line_style,
        .arrow_head = arrow.arrow_head,
        .activate = activate,
        .deactivate = deactivate,
    });
}

test "parses bare sequenceDiagram header" {
    var d = try parseSource(std.testing.allocator, "sequenceDiagram\n");
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.participants.len);
}

test "parses explicit participant declarations" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    participant Alice
        \\    participant Bob
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.participants.len);
    try std.testing.expectEqualStrings("Alice", d.participants[0].label);
    try std.testing.expectEqualStrings("Bob", d.participants[1].label);
}

test "parses participant with as alias" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    participant A as Alice
    );
    defer d.deinit();
    try std.testing.expectEqualStrings("A", d.participants[0].id_text);
    try std.testing.expectEqualStrings("Alice", d.participants[0].label);
}

test "rejects source missing sequenceDiagram header" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator, "A->>B: hi\n"));
}

test "ignores comment lines" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\%% this is a comment
        \\    Alice->>Bob: Hello
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
}

test "silently ignores malformed message without colon" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A->>B missing colon
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.messages.len);
}

test "silently ignores label containing zero-width codepoint" {
    var d = try parseSource(std.testing.allocator, "sequenceDiagram\n    A->>B: foo\u{200D}bar\n");
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.messages.len);
}

test "auto-interns participants from messages" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A->>B: msg1
        \\    B->>C: msg2
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 3), d.participants.len);
    try std.testing.expectEqual(@as(usize, 2), d.messages.len);
}

test "actor keyword sets participant kind" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    actor Alice
        \\    participant Bob
    );
    defer d.deinit();
    try std.testing.expectEqual(types.ParticipantKind.actor, d.participants[0].kind);
    try std.testing.expectEqual(types.ParticipantKind.participant, d.participants[1].kind);
}

test "accepts hyphenated actor ID (upstream \\S+? parity)" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    participant user-1
    );
    defer d.deinit();
    try std.testing.expectEqualStrings("user-1", d.participants[0].id_text);
}

test "accepts numeric actor ID" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    actor 123 as User
    );
    defer d.deinit();
    try std.testing.expectEqualStrings("123", d.participants[0].id_text);
    try std.testing.expectEqual(types.ParticipantKind.actor, d.participants[0].kind);
}

test "silently accepts autonumber" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    autonumber
        \\    A->>B: Hello
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
}

test "silently accepts create/destroy lines" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    create participant C
        \\    A->>C: Hello
        \\    destroy C
    );
    defer d.deinit();
    try std.testing.expect(d.messages.len >= 1);
}

test "->> produces line_style=.solid, arrow_head=.filled" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A->>B: Hello
    );
    defer d.deinit();
    try std.testing.expectEqual(types.LineStyle.solid, d.messages[0].line_style);
    try std.testing.expectEqual(types.ArrowHead.filled, d.messages[0].arrow_head);
}

test "-> produces line_style=.solid, arrow_head=.open" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A->B: Hello
    );
    defer d.deinit();
    try std.testing.expectEqual(types.LineStyle.solid, d.messages[0].line_style);
    try std.testing.expectEqual(types.ArrowHead.open, d.messages[0].arrow_head);
}

test "--> produces line_style=.dashed, arrow_head=.open" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A-->B: Hello
    );
    defer d.deinit();
    try std.testing.expectEqual(types.LineStyle.dashed, d.messages[0].line_style);
    try std.testing.expectEqual(types.ArrowHead.open, d.messages[0].arrow_head);
}

test "-->> produces line_style=.dashed, arrow_head=.filled" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A-->>B: Reply
    );
    defer d.deinit();
    try std.testing.expectEqual(types.LineStyle.dashed, d.messages[0].line_style);
    try std.testing.expectEqual(types.ArrowHead.filled, d.messages[0].arrow_head);
}

test "activate/deactivate shortcut sets message flags" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A->>+B: Hello
        \\    B-->>-A: World
    );
    defer d.deinit();
    try std.testing.expect(d.messages[0].activate);
    try std.testing.expect(!d.messages[0].deactivate);
    try std.testing.expect(!d.messages[1].activate);
    try std.testing.expect(d.messages[1].deactivate);
}

test "note after 1 message gets after_index=0" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A->>B: Hello
        \\    Note right of B: A note
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.notes.len);
    try std.testing.expectEqual(@as(i32, 0), d.notes[0].after_index);
    try std.testing.expectEqual(types.NotePlacement.right_of, d.notes[0].placement);
    try std.testing.expectEqualStrings("A note", d.notes[0].text);
}

test "note before any message gets after_index=-1" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    Note over A,B: early note
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.notes.len);
    try std.testing.expectEqual(@as(i32, -1), d.notes[0].after_index);
}

test "alt/else block records dividers with message_index and label" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    alt condition
        \\        A->>B: yes
        \\    else failed
        \\        A->>B: no
        \\    end
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.blocks.len);
    try std.testing.expectEqual(types.SequenceBlockKind.alt, d.blocks[0].kind);
    try std.testing.expectEqualStrings("condition", d.blocks[0].label);
    try std.testing.expectEqual(@as(u32, 0), d.blocks[0].start_index);
    try std.testing.expectEqual(@as(u32, 1), d.blocks[0].end_index);
    try std.testing.expectEqual(@as(usize, 1), d.blocks[0].dividers.len);
    try std.testing.expectEqualStrings("failed", d.blocks[0].dividers[0].label);
    try std.testing.expectEqual(@as(u32, 1), d.blocks[0].dividers[0].message_index);
}

test "standalone activate/deactivate lines are silently ignored" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    activate B
        \\    A->>B: Hello
        \\    deactivate B
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
    try std.testing.expectEqual(@as(usize, 0), d.notes.len);
    try std.testing.expectEqual(@as(usize, 0), d.blocks.len);
}

test "loop block records start_index and end_index" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    loop every minute
        \\        A->>B: ping
        \\    end
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.blocks.len);
    try std.testing.expectEqual(types.SequenceBlockKind.loop, d.blocks[0].kind);
    try std.testing.expectEqualStrings("every minute", d.blocks[0].label);
    try std.testing.expectEqual(@as(u32, 0), d.blocks[0].start_index);
    try std.testing.expectEqual(@as(u32, 0), d.blocks[0].end_index);
}

test "critical block with option separator records divider" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    critical establish connection
        \\        A->>B: connect
        \\    option network failure
        \\        B-->>A: retry
        \\    end
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.blocks.len);
    try std.testing.expectEqual(types.SequenceBlockKind.critical, d.blocks[0].kind);
    try std.testing.expectEqualStrings("establish connection", d.blocks[0].label);
    try std.testing.expectEqual(@as(usize, 1), d.blocks[0].dividers.len);
    try std.testing.expectEqualStrings("network failure", d.blocks[0].dividers[0].label);
}

test "par block with and separator records divider" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    par task1
        \\        A->>B: req1
        \\    and task2
        \\        A->>C: req2
        \\    end
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.blocks.len);
    try std.testing.expectEqual(types.SequenceBlockKind.par, d.blocks[0].kind);
    try std.testing.expectEqual(@as(usize, 1), d.blocks[0].dividers.len);
    try std.testing.expectEqualStrings("task2", d.blocks[0].dividers[0].label);
}

test "nested blocks produce separate block entries" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    loop outer
        \\        alt check
        \\            A->>B: yes
        \\        end
        \\    end
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.blocks.len);
    try std.testing.expectEqual(types.SequenceBlockKind.alt, d.blocks[0].kind);
    try std.testing.expectEqual(types.SequenceBlockKind.loop, d.blocks[1].kind);
}

test "divider == text == is silently accepted" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A->>B: Hello
        \\    == Phase 2 ==
        \\    A->>B: World
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.messages.len);
}

test "Note over two participants" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    participant A
        \\    participant B
        \\    Note over A,B: shared
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.notes.len);
    try std.testing.expectEqual(types.NotePlacement.over, d.notes[0].placement);
    try std.testing.expectEqual(@as(usize, 2), d.notes[0].actor_ids.len);
    try std.testing.expectEqual(@as(types.ParticipantId, 0), d.notes[0].actor_ids[0]);
    try std.testing.expectEqual(@as(types.ParticipantId, 1), d.notes[0].actor_ids[1]);
}

test "LOOP x is silent-ignored (case-sensitive block keywords)" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    LOOP x
        \\    A->>B: Hello
        \\    END
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.blocks.len);
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
}

test "top-level else with empty stack is silent-ignored" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    else orphan
        \\    A->>B: Hello
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.blocks.len);
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
}

test "loop internal else records as divider (upstream parity)" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    loop x
        \\    else y
        \\    A->>B: m
        \\    end
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.blocks.len);
    try std.testing.expectEqual(types.SequenceBlockKind.loop, d.blocks[0].kind);
    try std.testing.expectEqual(@as(usize, 1), d.blocks[0].dividers.len);
    try std.testing.expectEqualStrings("y", d.blocks[0].dividers[0].label);
}

test "loop internal option records as divider (upstream parity)" {
    // Upstream mermaid treats `else`, `and`, and `option` as a generic
    // divider keyword inside any non-empty block context rather than
    // pairing them with a specific block kind. This test pins that
    // stance — `option` inside a `loop` is accepted as a divider, not
    // silently ignored, matching the sibling `else`-in-`loop` test.
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    loop x
        \\    option y
        \\    A->>B: m
        \\    end
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.blocks.len);
    try std.testing.expectEqual(types.SequenceBlockKind.loop, d.blocks[0].kind);
    try std.testing.expectEqual(@as(usize, 1), d.blocks[0].dividers.len);
    try std.testing.expectEqualStrings("y", d.blocks[0].dividers[0].label);
}

test "top-level option with empty stack is silent-ignored" {
    // Upstream parity: branch keywords outside any block fall through to
    // message parsing, which silently ignores syntactically invalid lines.
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    option orphan
        \\    A->>B: m
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.blocks.len);
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
}

test "Note left of participant" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    participant A
        \\    Note left of A: left note
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.notes.len);
    try std.testing.expectEqual(types.NotePlacement.left_of, d.notes[0].placement);
    try std.testing.expectEqualStrings("left note", d.notes[0].text);
}

test "auto-interns dotted actor IDs from messages" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    user-1->>api.v1: ok
    );
    defer d.deinit();
    try std.testing.expectEqualStrings("user-1", d.participants[0].id_text);
    try std.testing.expectEqualStrings("api.v1", d.participants[1].id_text);
}

test "note auto-intern head Note adds participants even with after_index=-1" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    Note over A,B: early
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.participants.len);
    try std.testing.expectEqualStrings("A", d.participants[0].id_text);
    try std.testing.expectEqualStrings("B", d.participants[1].id_text);
    try std.testing.expectEqual(types.ParticipantKind.participant, d.participants[0].kind);
    try std.testing.expectEqual(@as(usize, 1), d.notes.len);
    try std.testing.expectEqual(@as(i32, -1), d.notes[0].after_index);
}

test "note auto-intern after message adds new participant" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A->>B: x
        \\    Note over C: n
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 3), d.participants.len);
    try std.testing.expectEqualStrings("C", d.participants[2].id_text);
    try std.testing.expectEqual(types.ParticipantKind.participant, d.participants[2].kind);
}

test "Note keyword is case-insensitive" {
    var d1 = try parseSource(std.testing.allocator, "sequenceDiagram\nnote over A: n\n");
    defer d1.deinit();
    try std.testing.expectEqual(@as(usize, 1), d1.notes.len);

    var d2 = try parseSource(std.testing.allocator, "sequenceDiagram\nNOTE OVER A: n\n");
    defer d2.deinit();
    try std.testing.expectEqual(@as(usize, 1), d2.notes.len);

    var d3 = try parseSource(std.testing.allocator, "sequenceDiagram\nNote LEFT OF A: n\n");
    defer d3.deinit();
    try std.testing.expectEqual(@as(usize, 1), d3.notes.len);
    try std.testing.expectEqual(types.NotePlacement.left_of, d3.notes[0].placement);

    var d4 = try parseSource(std.testing.allocator, "sequenceDiagram\nNOTE right of A: n\n");
    defer d4.deinit();
    try std.testing.expectEqual(@as(usize, 1), d4.notes.len);
    try std.testing.expectEqual(types.NotePlacement.right_of, d4.notes[0].placement);
}
