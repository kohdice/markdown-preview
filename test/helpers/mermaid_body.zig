const std = @import("std");
const internals = @import("internals");
const render_source = @import("render_from_source.zig");

pub const RenderedMermaid = struct {
    allocator: std.mem.Allocator,
    rendered: []u8,
    plain: []u8,
    body: []const u8,

    pub fn deinit(self: *RenderedMermaid) void {
        self.allocator.free(self.plain);
        self.allocator.free(self.rendered);
    }
};

pub fn renderFencedDiagram(
    allocator: std.mem.Allocator,
    mermaid_source: []const u8,
    opts: render_source.TestRenderOptions,
) !RenderedMermaid {
    var markdown: std.Io.Writer.Allocating = .init(allocator);
    defer markdown.deinit();

    try markdown.writer.writeAll("```mermaid\n");
    try markdown.writer.writeAll(mermaid_source);
    if (mermaid_source.len == 0 or mermaid_source[mermaid_source.len - 1] != '\n') {
        try markdown.writer.writeByte('\n');
    }
    try markdown.writer.writeAll("```\n");

    const rendered = try render_source.renderToOwnedSlice(allocator, markdown.writer.buffered(), opts);
    errdefer allocator.free(rendered);

    const plain = try internals.term.ansi.stripCsiAlloc(allocator, rendered);
    errdefer allocator.free(plain);

    return .{
        .allocator = allocator,
        .rendered = rendered,
        .plain = plain,
        .body = try extractMermaidBody(plain),
    };
}

pub fn expectBodyRowsFit(
    body: []const u8,
    wrap_width: usize,
    ambiguous: internals.term.width.AmbiguousWidth,
) !void {
    var rows = std.mem.splitScalar(u8, body, '\n');
    while (rows.next()) |row| {
        try std.testing.expect(internals.term.width.displayWidth(row, ambiguous) <= wrap_width);
    }
}

pub fn expectNoGeneratedClipping(source: []const u8, body: []const u8) !void {
    const ellipsis = "\u{2026}";
    const source_ellipsis_count = std.mem.count(u8, source, ellipsis);
    const body_ellipsis_count = std.mem.count(u8, body, ellipsis);
    try std.testing.expect(body_ellipsis_count <= source_ellipsis_count);
}

pub fn expectBodyContainsIgnoringWhitespace(
    allocator: std.mem.Allocator,
    body: []const u8,
    expected: []const u8,
) !void {
    const compact_body = try compactWhitespaceAlloc(allocator, body);
    defer allocator.free(compact_body);
    const compact_expected = try compactWhitespaceAlloc(allocator, expected);
    defer allocator.free(compact_expected);

    try std.testing.expect(std.mem.indexOf(u8, compact_body, compact_expected) != null);
}

pub fn expectBodyContainsSubsequenceIgnoringWhitespace(
    allocator: std.mem.Allocator,
    body: []const u8,
    expected: []const u8,
) !void {
    const compact_body = try compactWhitespaceAlloc(allocator, body);
    defer allocator.free(compact_body);
    const compact_expected = try compactWhitespaceAlloc(allocator, expected);
    defer allocator.free(compact_expected);

    var expected_pos: usize = 0;
    for (compact_body) |byte| {
        if (expected_pos == compact_expected.len) break;
        if (byte == compact_expected[expected_pos]) expected_pos += 1;
    }

    try std.testing.expectEqual(compact_expected.len, expected_pos);
}

pub fn expectBodyLacksIgnoringWhitespace(
    allocator: std.mem.Allocator,
    body: []const u8,
    unexpected: []const u8,
) !void {
    const compact_body = try compactWhitespaceAlloc(allocator, body);
    defer allocator.free(compact_body);
    const compact_unexpected = try compactWhitespaceAlloc(allocator, unexpected);
    defer allocator.free(compact_unexpected);

    try std.testing.expect(std.mem.indexOf(u8, compact_body, compact_unexpected) == null);
}

fn compactWhitespaceAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    for (input) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        try output.append(allocator, byte);
    }

    return try output.toOwnedSlice(allocator);
}

fn extractMermaidBody(rendered: []const u8) ![]const u8 {
    const opener_end = std.mem.indexOfScalar(u8, rendered, '\n') orelse return error.MissingMermaidFence;
    if (!std.mem.startsWith(u8, rendered[0..opener_end], "```mermaid")) return error.MissingMermaidFence;

    const closer_start = std.mem.lastIndexOf(u8, rendered, "\n```") orelse return error.MissingMermaidFence;
    const body_start = opener_end + 1;
    const body_end = if (closer_start < body_start) body_start else closer_start;
    return rendered[body_start..body_end];
}
