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

pub const MarkdownMermaidSection = struct {
    name: []const u8,
    source: []const u8,
    body: []const u8,
};

pub const RenderedMarkdownMermaidSections = struct {
    allocator: std.mem.Allocator,
    plain: []u8,
    sections: []MarkdownMermaidSection,
    source_bodies: [][]u8,
    rendered_bodies: [][]u8,

    pub fn deinit(self: *RenderedMarkdownMermaidSections) void {
        self.allocator.free(self.sections);
        freeOwnedBodies(self.allocator, self.rendered_bodies);
        freeOwnedBodies(self.allocator, self.source_bodies);
        self.allocator.free(self.plain);
    }
};

pub const MermaidDiagnosticAllowlistEntry = struct {
    section: []const u8,
    wrap_width: usize,
    reason: []const u8,
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

pub fn extractMarkdownMermaidSections(
    allocator: std.mem.Allocator,
    source_markdown: []const u8,
    rendered_markdown: []const u8,
    section_names: []const []const u8,
) !RenderedMarkdownMermaidSections {
    const source_bodies = try collectMermaidBodies(allocator, source_markdown);
    errdefer freeOwnedBodies(allocator, source_bodies);

    const plain = try internals.term.ansi.stripCsiAlloc(allocator, rendered_markdown);
    errdefer allocator.free(plain);

    const rendered_bodies = try collectMermaidBodies(allocator, plain);
    errdefer freeOwnedBodies(allocator, rendered_bodies);

    if (source_bodies.len != rendered_bodies.len) return error.MermaidSectionCountMismatch;
    if (section_names.len != source_bodies.len) return error.MermaidSectionNameCountMismatch;

    const sections = try allocator.alloc(MarkdownMermaidSection, source_bodies.len);
    errdefer allocator.free(sections);

    for (sections, 0..) |*section, i| {
        section.* = .{
            .name = section_names[i],
            .source = source_bodies[i],
            .body = rendered_bodies[i],
        };
    }

    return .{
        .allocator = allocator,
        .plain = plain,
        .sections = sections,
        .source_bodies = source_bodies,
        .rendered_bodies = rendered_bodies,
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

pub fn expectNoUnexpectedDiagnostic(
    allocator: std.mem.Allocator,
    section: MarkdownMermaidSection,
    wrap_width: usize,
    allowlist: []const MermaidDiagnosticAllowlistEntry,
) !void {
    if (std.mem.find(u8, section.body, "[mermaid:") == null) return;

    if (try containsIgnoringWhitespace(allocator, section.body, "[mermaid: terminal width too small to render diagram]")) {
        try std.testing.expect(isAllowedWidthTooSmallDiagnostic(section.name, wrap_width, allowlist));
        return;
    }

    try std.testing.expect(false);
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

    try std.testing.expect(std.mem.find(u8, compact_body, compact_expected) != null);
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

    try std.testing.expect(std.mem.find(u8, compact_body, compact_unexpected) == null);
}

fn containsIgnoringWhitespace(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
) !bool {
    const compact_haystack = try compactWhitespaceAlloc(allocator, haystack);
    defer allocator.free(compact_haystack);
    const compact_needle = try compactWhitespaceAlloc(allocator, needle);
    defer allocator.free(compact_needle);

    return std.mem.find(u8, compact_haystack, compact_needle) != null;
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

fn isAllowedWidthTooSmallDiagnostic(
    section_name: []const u8,
    wrap_width: usize,
    allowlist: []const MermaidDiagnosticAllowlistEntry,
) bool {
    for (allowlist) |entry| {
        if (entry.wrap_width == wrap_width and std.mem.eql(u8, entry.section, section_name)) {
            return entry.reason.len > 0;
        }
    }
    return false;
}

fn collectMermaidBodies(allocator: std.mem.Allocator, markdown: []const u8) ![][]u8 {
    var doc = try internals.parse.parse(allocator, .{ .borrowed = markdown });
    defer doc.deinit();

    var bodies: std.ArrayList([]u8) = .empty;
    errdefer {
        freeOwnedBodyItems(allocator, bodies.items);
        bodies.deinit(allocator);
    }

    try appendMermaidBodiesFromBlocks(allocator, doc.blocks, &bodies);
    return try bodies.toOwnedSlice(allocator);
}

fn appendMermaidBodiesFromBlocks(
    allocator: std.mem.Allocator,
    blocks: anytype,
    bodies: *std.ArrayList([]u8),
) !void {
    for (blocks) |block| {
        switch (block) {
            .code_fence => |code_fence| {
                if (std.ascii.eqlIgnoreCase(code_fence.language, "mermaid")) {
                    const body = try allocator.dupe(u8, code_fence.content);
                    errdefer allocator.free(body);
                    try bodies.append(allocator, body);
                }
            },
            .blockquote => |blockquote| try appendMermaidBodiesFromBlocks(allocator, blockquote.blocks, bodies),
            .list => |list| {
                for (list.items) |item| {
                    try appendMermaidBodiesFromBlocks(allocator, item.blocks, bodies);
                }
            },
            else => {},
        }
    }
}

fn freeOwnedBodies(allocator: std.mem.Allocator, bodies: [][]u8) void {
    freeOwnedBodyItems(allocator, bodies);
    allocator.free(bodies);
}

fn freeOwnedBodyItems(allocator: std.mem.Allocator, bodies: []const []u8) void {
    for (bodies) |body| {
        allocator.free(body);
    }
}

fn extractMermaidBody(rendered: []const u8) ![]const u8 {
    const opener_end = std.mem.findScalar(u8, rendered, '\n') orelse return error.MissingMermaidFence;
    if (!std.mem.startsWith(u8, rendered[0..opener_end], "```mermaid")) return error.MissingMermaidFence;

    const closer_start = std.mem.findLast(u8, rendered, "\n```") orelse return error.MissingMermaidFence;
    const body_start = opener_end + 1;
    const body_end = if (closer_start < body_start) body_start else closer_start;
    return rendered[body_start..body_end];
}
