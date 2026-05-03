const std = @import("std");
const source_mod = @import("source.zig");
const types = @import("types.zig");

pub const ParseError = error{
    InvalidMermaid,
    UnsupportedFeature,
    TooManyBranches,
    OutOfMemory,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    branches: std.ArrayList(types.GitBranch) = .empty,
    commits: std.ArrayList(types.GitCommit) = .empty,
    branch_index: std.StringHashMapUnmanaged(u16) = .empty,
    owned_strings: std.ArrayList([]u8) = .empty,
    current_lane: u16 = 0,

    fn ensureMain(self: *Parser) ParseError!void {
        if (self.branches.items.len != 0) return;
        try self.branches.append(self.allocator, .{
            .name = "main",
            .lane = 0,
            .created_at = 0,
            .parent_lane = null,
        });
        try self.branch_index.put(self.allocator, "main", 0);
    }

    fn branchLane(self: *const Parser, name: []const u8) ?u16 {
        return self.branch_index.get(name);
    }

    fn addBranch(self: *Parser, name: []const u8, parent_lane: u16) ParseError!u16 {
        if (self.branches.items.len >= 255) return error.TooManyBranches;
        const lane: u16 = @intCast(self.branches.items.len);
        const fork_idx = self.lastCommitOnLane(parent_lane);
        try self.branches.append(self.allocator, .{
            .name = name,
            .lane = lane,
            .created_at = @intCast(self.commits.items.len),
            .parent_lane = parent_lane,
            .fork_commit_index = fork_idx,
        });
        try self.branch_index.put(self.allocator, name, lane);
        return lane;
    }

    fn lastCommitOnLane(self: *const Parser, lane: u16) ?u16 {
        var i: usize = self.commits.items.len;
        while (i > 0) {
            i -= 1;
            if (self.commits.items[i].lane == lane) {
                return self.commits.items[i].index;
            }
        }
        return null;
    }
};

/// `source` must already be stripped of `%%{init: ...}%%` directives by
/// `compile` or the caller. Parsing does not revisit directive semantics.
pub fn parse(allocator: std.mem.Allocator, source: anytype) ParseError!types.GitGraph {
    const owned_source = try source_mod.normalizeOwned(allocator, source);
    return parseFromOwned(allocator, owned_source);
}

fn parseFromOwned(allocator: std.mem.Allocator, owned_source: []u8) ParseError!types.GitGraph {
    var parser: Parser = .{ .allocator = allocator };
    defer parser.branch_index.deinit(allocator);
    errdefer {
        parser.branches.deinit(allocator);
        parser.commits.deinit(allocator);
        for (parser.owned_strings.items) |s| allocator.free(s);
        parser.owned_strings.deinit(allocator);
    }

    {
        errdefer allocator.free(owned_source);
        try parser.owned_strings.append(allocator, owned_source);
    }

    var header_seen = false;

    var it = std.mem.splitScalar(u8, owned_source, '\n');
    while (it.next()) |raw| {
        const stripped_cr = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, stripped_cr, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "%%")) continue;

        if (!header_seen) {
            try validateHeader(trimmed);
            header_seen = true;
            try parser.ensureMain();
            continue;
        }

        try parseLine(&parser, trimmed);
    }

    if (!header_seen) return error.InvalidMermaid;

    const branches = try parser.branches.toOwnedSlice(allocator);
    errdefer allocator.free(branches);
    const commits = try parser.commits.toOwnedSlice(allocator);
    errdefer allocator.free(commits);
    const owned_strings = try parser.owned_strings.toOwnedSlice(allocator);

    return .{
        .allocator = allocator,
        .branches = branches,
        .commits = commits,
        .owned_strings = owned_strings,
    };
}

fn validateHeader(line: []const u8) ParseError!void {
    var head = line;
    const keyword = "gitGraph";

    if (head.len < keyword.len) return error.InvalidMermaid;
    if (!std.ascii.eqlIgnoreCase(head[0..keyword.len], keyword)) return error.InvalidMermaid;
    head = head[keyword.len..];

    head = std.mem.trim(u8, head, " \t");
    if (head.len == 0) return;
    if (head.len == 1 and head[0] == ':') return;

    if (head[head.len - 1] == ':') head = std.mem.trimEnd(u8, head[0 .. head.len - 1], " \t");

    if (std.ascii.eqlIgnoreCase(head, "LR")) return;
    if (std.ascii.eqlIgnoreCase(head, "TB") or std.ascii.eqlIgnoreCase(head, "BT")) return error.UnsupportedFeature;

    return error.InvalidMermaid;
}

fn parseLine(parser: *Parser, line: []const u8) ParseError!void {
    if (splitLeadingWord(line)) |sp| {
        const word = sp.word;
        const rest = sp.rest;

        if (std.mem.eql(u8, word, "cherry-pick")) return error.UnsupportedFeature;
        if (std.mem.eql(u8, word, "commit")) return parseCommit(parser, rest);
        if (std.mem.eql(u8, word, "branch")) return parseBranch(parser, rest);
        if (std.mem.eql(u8, word, "checkout") or std.mem.eql(u8, word, "switch")) return parseCheckout(parser, rest);
        if (std.mem.eql(u8, word, "merge")) return parseMerge(parser, rest);
    }
    return error.InvalidMermaid;
}

const Split = struct { word: []const u8, rest: []const u8 };

fn splitLeadingWord(line: []const u8) ?Split {
    if (line.len == 0) return null;
    var i: usize = 0;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
    const word = line[0..i];
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return .{ .word = word, .rest = line[i..] };
}

const CommitAttrs = struct {
    id_text: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    commit_type: types.GitCommitType = .normal,
};

fn parseCommitAttributes(rest: []const u8) ParseError!CommitAttrs {
    var attrs: CommitAttrs = .{};
    var cursor: usize = 0;
    while (cursor < rest.len) {
        while (cursor < rest.len and (rest[cursor] == ' ' or rest[cursor] == '\t')) : (cursor += 1) {}
        if (cursor >= rest.len) break;

        const kv = try takeKeyValue(rest, cursor);
        if (std.ascii.eqlIgnoreCase(kv.key, "id")) {
            attrs.id_text = kv.value;
        } else if (std.ascii.eqlIgnoreCase(kv.key, "tag")) {
            attrs.tag = kv.value;
        } else if (std.ascii.eqlIgnoreCase(kv.key, "type")) {
            if (std.ascii.eqlIgnoreCase(kv.value, "NORMAL")) {
                attrs.commit_type = .normal;
            } else if (std.ascii.eqlIgnoreCase(kv.value, "REVERSE")) {
                attrs.commit_type = .reverse;
            } else if (std.ascii.eqlIgnoreCase(kv.value, "HIGHLIGHT")) {
                attrs.commit_type = .highlight;
            } else {
                return error.InvalidMermaid;
            }
        } else {
            return error.InvalidMermaid;
        }
        cursor = kv.next;
    }
    return attrs;
}

fn parseCommit(parser: *Parser, rest: []const u8) ParseError!void {
    const attrs = try parseCommitAttributes(rest);
    try parser.commits.append(parser.allocator, .{
        .index = @intCast(parser.commits.items.len),
        .lane = parser.current_lane,
        .id_text = attrs.id_text,
        .tag = attrs.tag,
        .commit_type = attrs.commit_type,
    });
}

const KeyValue = struct { key: []const u8, value: []const u8, next: usize };

fn takeKeyValue(text: []const u8, start: usize) ParseError!KeyValue {
    var i = start;
    const key_start = i;
    while (i < text.len and text[i] != ':' and text[i] != ' ' and text[i] != '\t') : (i += 1) {}
    if (i >= text.len or text[i] != ':') return error.InvalidMermaid;
    const key = text[key_start..i];
    i += 1;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}

    if (i < text.len and text[i] == '"') {
        const value_start = i + 1;
        var j = value_start;
        while (j < text.len and text[j] != '"') : (j += 1) {}
        if (j >= text.len) return error.InvalidMermaid;
        return .{ .key = key, .value = text[value_start..j], .next = j + 1 };
    }

    const value_start = i;
    while (i < text.len and text[i] != ' ' and text[i] != '\t') : (i += 1) {}
    return .{ .key = key, .value = text[value_start..i], .next = i };
}

fn parseBranch(parser: *Parser, rest: []const u8) ParseError!void {
    if (rest.len == 0) return error.InvalidMermaid;
    if (rest[0] == '"') return error.UnsupportedFeature;

    const sp = splitLeadingWord(rest) orelse return error.InvalidMermaid;
    const name = sp.word;
    const tail = std.mem.trim(u8, sp.rest, " \t");
    if (tail.len > 0) {
        return error.UnsupportedFeature;
    }

    if (parser.branchLane(name) != null) return error.InvalidMermaid;
    const parent_lane = parser.current_lane;
    const new_lane = try parser.addBranch(name, parent_lane);
    parser.current_lane = new_lane;
}

fn parseCheckout(parser: *Parser, rest: []const u8) ParseError!void {
    const name = std.mem.trim(u8, rest, " \t");
    if (name.len == 0) return error.InvalidMermaid;
    if (name[0] == '"') return error.UnsupportedFeature;
    const lane = parser.branchLane(name) orelse return error.InvalidMermaid;
    parser.current_lane = lane;
}

fn parseMerge(parser: *Parser, rest: []const u8) ParseError!void {
    if (rest.len == 0) return error.InvalidMermaid;
    if (rest[0] == '"') return error.UnsupportedFeature;

    const sp = splitLeadingWord(rest) orelse return error.InvalidMermaid;
    const name = sp.word;
    const tail = std.mem.trim(u8, sp.rest, " \t");
    const attrs = try parseCommitAttributes(tail);

    const source_lane = parser.branchLane(name) orelse return error.InvalidMermaid;
    if (source_lane == parser.current_lane) return error.InvalidMermaid;

    const merge_from_index = parser.lastCommitOnLane(source_lane) orelse blk: {
        const src_branch = parser.branches.items[source_lane];
        break :blk src_branch.fork_commit_index;
    };

    try parser.commits.append(parser.allocator, .{
        .index = @intCast(parser.commits.items.len),
        .lane = parser.current_lane,
        .id_text = attrs.id_text,
        .tag = attrs.tag,
        .commit_type = attrs.commit_type,
        .merge_from_lane = source_lane,
        .merge_from_index = merge_from_index,
    });
}

test "parses gitGraph header with and without colon" {
    {
        var g = try parse(std.testing.allocator, "gitGraph\n    commit\n");
        defer g.deinit();
        try std.testing.expectEqual(@as(usize, 1), g.commits.len);
    }
    {
        var g = try parse(std.testing.allocator, "gitGraph:\n    commit\n");
        defer g.deinit();
        try std.testing.expectEqual(@as(usize, 1), g.commits.len);
    }
    {
        var g = try parse(std.testing.allocator, "gitGraph LR:\n    commit\n");
        defer g.deinit();
        try std.testing.expectEqual(@as(usize, 1), g.commits.len);
    }
}

test "parses commit with id and tag" {
    var g = try parse(std.testing.allocator,
        \\gitGraph
        \\    commit id: "a1" tag: "v1"
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 1), g.commits.len);
    try std.testing.expectEqualStrings("a1", g.commits[0].id_text.?);
    try std.testing.expectEqualStrings("v1", g.commits[0].tag.?);
}

test "parses commit type NORMAL|REVERSE|HIGHLIGHT" {
    var g = try parse(std.testing.allocator,
        \\gitGraph
        \\    commit type: NORMAL
        \\    commit type: REVERSE
        \\    commit type: HIGHLIGHT
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 3), g.commits.len);
    try std.testing.expectEqual(types.GitCommitType.normal, g.commits[0].commit_type);
    try std.testing.expectEqual(types.GitCommitType.reverse, g.commits[1].commit_type);
    try std.testing.expectEqual(types.GitCommitType.highlight, g.commits[2].commit_type);
}

test "parses branch and checkout / switch aliases" {
    var g = try parse(std.testing.allocator,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    commit
        \\    switch develop
        \\    commit
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.branches.len);
    try std.testing.expectEqual(@as(usize, 4), g.commits.len);
    try std.testing.expectEqual(@as(u16, 0), g.commits[0].lane);
    try std.testing.expectEqual(@as(u16, 1), g.commits[1].lane);
    try std.testing.expectEqual(@as(u16, 0), g.commits[2].lane);
    try std.testing.expectEqual(@as(u16, 1), g.commits[3].lane);
}

test "parses merge with merge_from set" {
    var g = try parse(std.testing.allocator,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    merge develop
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 3), g.commits.len);
    const last = g.commits[2];
    try std.testing.expectEqual(@as(u16, 0), last.lane);
    try std.testing.expectEqual(@as(?u16, 1), last.merge_from_lane);
    try std.testing.expect(last.merge_from_index != null);
}

test "rejects cherry-pick explicitly" {
    try std.testing.expectError(error.UnsupportedFeature, parse(std.testing.allocator,
        \\gitGraph
        \\    commit
        \\    cherry-pick id: "a1"
    ));
}

test "rejects gitGraph TB: orientation" {
    try std.testing.expectError(error.UnsupportedFeature, parse(std.testing.allocator,
        \\gitGraph TB:
        \\    commit
    ));
}

test "rejects gitGraph BT: orientation" {
    try std.testing.expectError(error.UnsupportedFeature, parse(std.testing.allocator,
        \\gitGraph BT:
        \\    commit
    ));
}

test "rejects branch order: suffix" {
    try std.testing.expectError(error.UnsupportedFeature, parse(std.testing.allocator,
        \\gitGraph
        \\    commit
        \\    branch develop order: 2
    ));
}

test "rejects unknown commit key as invalid" {
    try std.testing.expectError(error.InvalidMermaid, parse(std.testing.allocator,
        \\gitGraph
        \\    commit rotateCommitLabel: true
    ));
}

test "rejects unknown commit type value as invalid" {
    try std.testing.expectError(error.InvalidMermaid, parse(std.testing.allocator,
        \\gitGraph
        \\    commit type: FOO
    ));
}

test "merge from empty branch uses parent fork point as source" {
    var g = try parse(std.testing.allocator,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    checkout main
        \\    merge develop
    );
    defer g.deinit();

    try std.testing.expectEqual(@as(usize, 2), g.commits.len);
    const merge = g.commits[1];
    try std.testing.expectEqual(@as(?u16, 1), merge.merge_from_lane);
    try std.testing.expectEqual(@as(?u16, 0), merge.merge_from_index);

    try std.testing.expectEqual(@as(?u16, 0), g.branches[1].fork_commit_index);
}

test "parses merge with id/tag/type attributes" {
    var g = try parse(std.testing.allocator,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    merge develop id: "m1" tag: "v1.0" type: HIGHLIGHT
    );
    defer g.deinit();

    try std.testing.expectEqual(@as(usize, 3), g.commits.len);
    const merge = g.commits[2];
    try std.testing.expectEqual(@as(?u16, 1), merge.merge_from_lane);
    try std.testing.expectEqualStrings("m1", merge.id_text.?);
    try std.testing.expectEqualStrings("v1.0", merge.tag.?);
    try std.testing.expectEqual(types.GitCommitType.highlight, merge.commit_type);
}

test "rejects unknown merge attribute key as invalid" {
    try std.testing.expectError(error.InvalidMermaid, parse(std.testing.allocator,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    merge develop rotateCommitLabel: true
    ));
}

test "rejects unknown merge type value as invalid" {
    try std.testing.expectError(error.InvalidMermaid, parse(std.testing.allocator,
        \\gitGraph
        \\    commit
        \\    branch develop
        \\    commit
        \\    checkout main
        \\    merge develop type: FOO
    ));
}

fn expectParseGitHandlesAllocationFailures(allocator: std.mem.Allocator) !void {
    var g = try parse(allocator,
        \\gitGraph
        \\    commit id: "a"
        \\    branch develop
        \\    checkout develop
        \\    commit tag: "v1"
        \\    checkout main
        \\    merge develop
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(usize, 2), g.branches.len);
    try std.testing.expectEqual(@as(usize, 3), g.commits.len);
}

test "parse cleans up git allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        expectParseGitHandlesAllocationFailures,
        .{},
    );
}
