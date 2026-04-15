const std = @import("std");
const types = @import("types.zig");
const width_mod = @import("../term/width.zig");

pub const ParseError = error{
    InvalidMermaid,
    UnsupportedFeature,
    TooManyParticipants,
    OutOfMemory,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    participants: std.ArrayListUnmanaged(types.Participant) = .empty,
    messages: std.ArrayListUnmanaged(types.SequenceMessage) = .empty,
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
    errdefer parser.participants.deinit(allocator);
    errdefer parser.messages.deinit(allocator);
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
    const owned_strings = try parser.owned_strings.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .participants = participants,
        .messages = messages,
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

    if (isUnsupportedStatement(line)) return error.UnsupportedFeature;

    if (tryParseParticipant(parser, line)) |_| return else |err| switch (err) {
        error.NotParticipant => {},
        error.InvalidMermaid => return error.InvalidMermaid,
        error.UnsupportedFeature => return error.UnsupportedFeature,
        error.TooManyParticipants => return error.TooManyParticipants,
        error.OutOfMemory => return error.OutOfMemory,
    }
    try parseMessage(parser, line);
}

fn isSilentlySkipped(line: []const u8) bool {
    const prefixes = [_][]const u8{
        "activate ",  "deactivate ",
        "autonumber", "create ",
        "destroy ",   "link ",
        "links ",     "properties ",
        "Note ",      "note ",
        "loop ",      "alt ",
        "else ",      "opt ",
        "par ",       "and ",
        "critical ",  "rect ",
        "break ",
    };
    for (prefixes) |kw| {
        if (std.ascii.startsWithIgnoreCase(line, kw)) return true;
        const bare = if (kw[kw.len - 1] == ' ') kw[0 .. kw.len - 1] else kw;
        if (std.ascii.eqlIgnoreCase(line, bare)) return true;
    }
    if (std.ascii.eqlIgnoreCase(line, "end")) return true;
    if (std.ascii.eqlIgnoreCase(line, "else")) return true;
    return false;
}

fn isUnsupportedStatement(line: []const u8) bool {
    _ = line;
    return false;
}

const ParticipantError = ParseError || error{NotParticipant};

fn tryParseParticipant(parser: *Parser, line: []const u8) ParticipantError!void {
    const keyword_participant = "participant ";
    const keyword_actor = "actor ";

    const rest = if (std.mem.startsWith(u8, line, keyword_participant))
        line[keyword_participant.len..]
    else if (std.mem.startsWith(u8, line, keyword_actor))
        line[keyword_actor.len..]
    else
        return error.NotParticipant;

    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) return error.InvalidMermaid;

    const as_marker = " as ";
    if (std.mem.indexOf(u8, trimmed, as_marker)) |idx| {
        const id_text = std.mem.trimRight(u8, trimmed[0..idx], " \t");
        const raw_label = std.mem.trimLeft(u8, trimmed[idx + as_marker.len ..], " \t");
        if (id_text.len == 0 or raw_label.len == 0) return error.InvalidMermaid;
        try validateIdent(id_text);
        try validateLabel(raw_label);
        const label = try normalizeLabel(parser, raw_label);
        const id = try parser.intern(id_text, label);
        parser.updateLabel(id, label);
        return;
    }

    try validateIdent(trimmed);
    _ = try parser.intern(trimmed, trimmed);
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

const ArrowMatch = struct {
    start: usize,
    len: usize,
    style: types.MessageStyle,
};

fn findMessageArrow(text: []const u8) ?ArrowMatch {
    const candidates = [_]struct { op: []const u8, style: types.MessageStyle }{
        .{ .op = "-->>", .style = .dashed_arrow },
        .{ .op = "--)", .style = .dashed_arrow },
        .{ .op = "--x", .style = .dashed_arrow },
        .{ .op = "->>", .style = .solid_arrow },
        .{ .op = "-)", .style = .solid_arrow },
        .{ .op = "-x", .style = .solid_arrow },
        .{ .op = "-->", .style = .dashed_line },
        .{ .op = "->", .style = .solid_line },
    };

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        for (candidates) |c| {
            if (i + c.op.len > text.len) continue;
            if (!std.mem.eql(u8, text[i .. i + c.op.len], c.op)) continue;
            if (i > 0 and text[i - 1] == '-') continue;
            return .{ .start = i, .len = c.op.len, .style = c.style };
        }
    }
    return null;
}

fn parseMessage(parser: *Parser, line: []const u8) ParseError!void {
    const arrow = findMessageArrow(line) orelse return error.InvalidMermaid;

    const from_text = std.mem.trim(u8, line[0..arrow.start], " \t");
    var after_arrow = line[arrow.start + arrow.len ..];

    const lead = std.mem.trimLeft(u8, after_arrow, " \t");
    if (lead.len > 0 and (lead[0] == '+' or lead[0] == '-')) {
        const ws_len = after_arrow.len - lead.len;
        after_arrow = after_arrow[ws_len + 1 ..];
    }

    const colon_idx = std.mem.indexOfScalar(u8, after_arrow, ':') orelse return error.InvalidMermaid;
    const to_text = std.mem.trim(u8, after_arrow[0..colon_idx], " \t");
    const raw_label = std.mem.trim(u8, after_arrow[colon_idx + 1 ..], " \t");

    try validateIdent(from_text);
    try validateIdent(to_text);
    try validateLabel(raw_label);
    const label = try normalizeLabel(parser, raw_label);

    const from_id = try parser.intern(from_text, from_text);
    const to_id = try parser.intern(to_text, to_text);

    try parser.messages.append(parser.allocator, .{
        .from = from_id,
        .to = to_id,
        .label = label,
        .style = arrow.style,
    });
}

test "parses bare sequenceDiagram header" {
    var d = try parseSource(std.testing.allocator, "sequenceDiagram\n");
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 0), d.participants.len);
}

test "parses explicit participant declarations" {
    const source =
        \\sequenceDiagram
        \\    participant Alice
        \\    participant Bob
    ;
    var d = try parseSource(std.testing.allocator, source);
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.participants.len);
    try std.testing.expectEqualStrings("Alice", d.participants[0].label);
    try std.testing.expectEqualStrings("Bob", d.participants[1].label);
}

test "parses participant with as alias" {
    const source =
        \\sequenceDiagram
        \\    participant A as Alice
    ;
    var d = try parseSource(std.testing.allocator, source);
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.participants.len);
    try std.testing.expectEqualStrings("A", d.participants[0].id_text);
    try std.testing.expectEqualStrings("Alice", d.participants[0].label);
}

test "parses solid arrow message A->>B: hello" {
    const source =
        \\sequenceDiagram
        \\    Alice->>Bob: Hello
    ;
    var d = try parseSource(std.testing.allocator, source);
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.participants.len);
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
    try std.testing.expectEqual(types.MessageStyle.solid_arrow, d.messages[0].style);
    try std.testing.expectEqualStrings("Hello", d.messages[0].label);
}

test "parses dashed arrow message A-->>B: reply" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    Bob-->>Alice: Reply
    );
    defer d.deinit();
    try std.testing.expectEqual(types.MessageStyle.dashed_arrow, d.messages[0].style);
}

test "auto-interns participants from messages" {
    const source =
        \\sequenceDiagram
        \\    A->>B: msg1
        \\    B->>C: msg2
        \\    A->>C: msg3
    ;
    var d = try parseSource(std.testing.allocator, source);
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 3), d.participants.len);
    try std.testing.expectEqual(@as(usize, 3), d.messages.len);
}

test "rejects source missing sequenceDiagram header" {
    try std.testing.expectError(error.InvalidMermaid, parseSource(std.testing.allocator, "A->>B: hi\n"));
}

test "ignores comment lines" {
    const source =
        \\sequenceDiagram
        \\%% this is a comment
        \\    Alice->>Bob: Hello
    ;
    var d = try parseSource(std.testing.allocator, source);
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
}

test "rejects malformed message without colon" {
    try std.testing.expectError(
        error.InvalidMermaid,
        parseSource(std.testing.allocator,
            \\sequenceDiagram
            \\    A->>B missing colon
        ),
    );
}

test "rejects label containing zero-width codepoint" {
    try std.testing.expectError(
        error.InvalidMermaid,
        parseSource(std.testing.allocator, "sequenceDiagram\n    A->>B: foo\u{200D}bar\n"),
    );
}

test "silently skips Note lines" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A->>B: Hello
        \\    Note right of B: A note
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
}

test "silently skips loop blocks but keeps inner messages" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    loop every minute
        \\        A->>B: ping
        \\    end
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
}

test "silently skips alt / else / end framing" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    alt condition
        \\        A->>B: yes
        \\    else
        \\        A->>B: no
        \\    end
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.messages.len);
}

test "accepts activate/deactivate shortcut and drops marker" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A->>+B: Hello
        \\    B-->>-A: World
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 2), d.messages.len);
    try std.testing.expectEqual(types.MessageStyle.solid_arrow, d.messages[0].style);
    try std.testing.expectEqualStrings("Hello", d.messages[0].label);
    try std.testing.expectEqual(types.MessageStyle.dashed_arrow, d.messages[1].style);
    try std.testing.expectEqualStrings("World", d.messages[1].label);
}

test "silently accepts explicit activate/deactivate lines" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    activate B
        \\    A->>B: Hello
        \\    deactivate B
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
}

test "parses -x lost message as solid arrow (folded from filled cross)" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A-xB: lost
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
    try std.testing.expectEqual(types.MessageStyle.solid_arrow, d.messages[0].style);
}

test "parses --) async message as dashed arrow" {
    var d = try parseSource(std.testing.allocator,
        \\sequenceDiagram
        \\    A--)B: async reply
    );
    defer d.deinit();
    try std.testing.expectEqual(@as(usize, 1), d.messages.len);
    try std.testing.expectEqual(types.MessageStyle.dashed_arrow, d.messages[0].style);
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
