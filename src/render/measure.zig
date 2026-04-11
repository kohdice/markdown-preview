const std = @import("std");
const ast = @import("../ast.zig");
const text = @import("../text.zig");
const width = @import("../term/width.zig");
const render_inline = @import("inline.zig");

pub fn inlineWidth(doc: *const ast.Document, first: ast.InlineRef, ambiguous: width.AmbiguousWidth) usize {
    var total: usize = 0;
    var current = first;
    while (ast.hasInline(current)) {
        const node = doc.inlineNode(current).*;
        total += switch (node) {
            .text => |content| textWidthWithEntities(content, ambiguous),
            .code_span => |content| width.displayWidth(content, ambiguous),
            .autolink => |url| width.displayWidth(url, ambiguous),
            .soft_break, .hard_break => 0,
            .emphasis => |children| inlineWidth(doc, children, ambiguous),
            .strong => |children| inlineWidth(doc, children, ambiguous),
            .bold_italic => |children| inlineWidth(doc, children, ambiguous),
            .strikethrough => |children| inlineWidth(doc, children, ambiguous),
            .link => |link| blk: {
                var w = inlineWidth(doc, link.children, ambiguous);
                w += width.displayWidth(render_inline.link_url_open, ambiguous);
                w += width.displayWidth(link.url, ambiguous);
                w += width.displayWidth(render_inline.link_url_close, ambiguous);
                if (link.title) |t| {
                    w += width.displayWidth(render_inline.link_title_separator, ambiguous);
                    w += width.displayWidth(t, ambiguous);
                }
                break :blk w;
            },
            .image => |img| blk: {
                var w = width.displayWidth(render_inline.image_alt_prefix, ambiguous);
                w += inlineWidth(doc, img.children, ambiguous);
                w += width.displayWidth(render_inline.image_alt_suffix, ambiguous);
                w += width.displayWidth(render_inline.link_url_open, ambiguous);
                w += width.displayWidth(img.url, ambiguous);
                w += width.displayWidth(render_inline.link_url_close, ambiguous);
                if (img.title) |t| {
                    w += width.displayWidth(render_inline.link_title_separator, ambiguous);
                    w += width.displayWidth(t, ambiguous);
                }
                break :blk w;
            },
        };
        current = doc.inlineNext(current);
    }
    return total;
}

fn textWidthWithEntities(content: []const u8, ambiguous: width.AmbiguousWidth) usize {
    var total: usize = 0;
    var pos: usize = 0;
    var plain_start: usize = 0;

    while (pos < content.len) {
        if (content[pos] == '&') {
            if (text.decode(content, pos)) |result| {
                if (plain_start < pos)
                    total += width.displayWidth(content[plain_start..pos], ambiguous);
                total += width.displayWidth(result.bytes[0..result.len], ambiguous);
                pos = result.end;
                plain_start = pos;
                continue;
            }
        }
        pos += 1;
    }

    if (plain_start < content.len)
        total += width.displayWidth(content[plain_start..], ambiguous);

    return total;
}

const testing = std.testing;

fn testDoc(inline_nodes: []const ast.InlineNode, inline_next: []const ast.InlineRef) ast.Document {
    return .{
        .inline_nodes = inline_nodes,
        .inline_next = inline_next,
        .blocks = &.{},
        .link_defs = .{},
        .has_trailing_newline = false,
    };
}

test "plain text width" {
    const nodes = [_]ast.InlineNode{.{ .text = "hello" }};
    const next = [_]ast.InlineRef{ast.no_inline};
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(5, inlineWidth(&doc, 0, .narrow));
}

test "empty inlines" {
    const doc = testDoc(&.{}, &.{});
    try testing.expectEqual(0, inlineWidth(&doc, ast.no_inline, .narrow));
}

test "code span width" {
    const nodes = [_]ast.InlineNode{.{ .code_span = "x + y" }};
    const next = [_]ast.InlineRef{ast.no_inline};
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(5, inlineWidth(&doc, 0, .narrow));
}

test "autolink width" {
    const nodes = [_]ast.InlineNode{.{ .autolink = "http://example.com" }};
    const next = [_]ast.InlineRef{ast.no_inline};
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(18, inlineWidth(&doc, 0, .narrow));
}

test "soft break and hard break are zero width" {
    const nodes = [_]ast.InlineNode{ .{ .text = "a" }, .soft_break, .{ .text = "b" }, .hard_break, .{ .text = "c" } };
    const next = [_]ast.InlineRef{ 1, 2, 3, 4, ast.no_inline };
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(3, inlineWidth(&doc, 0, .narrow));
}

test "emphasis does not add width" {
    const nodes = [_]ast.InlineNode{
        .{ .strong = 1 },
        .{ .text = "bold" },
    };
    const next = [_]ast.InlineRef{ ast.no_inline, ast.no_inline };
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(4, inlineWidth(&doc, 0, .narrow));
}

test "link width includes url and delimiters" {
    const nodes = [_]ast.InlineNode{
        .{ .link = .{
            .url = "http://x.co",
            .title = null,
            .children = 1,
        } },
        .{ .text = "click" },
    };
    const next = [_]ast.InlineRef{ ast.no_inline, ast.no_inline };
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(18, inlineWidth(&doc, 0, .narrow));
}

test "link width includes title" {
    const nodes = [_]ast.InlineNode{
        .{ .link = .{
            .url = "u",
            .title = "T",
            .children = 1,
        } },
        .{ .text = "a" },
    };
    const next = [_]ast.InlineRef{ ast.no_inline, ast.no_inline };
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(8, inlineWidth(&doc, 0, .narrow));
}

test "image width includes alt prefix and suffix" {
    const nodes = [_]ast.InlineNode{
        .{ .image = .{
            .url = "img.png",
            .title = null,
            .children = 1,
        } },
        .{ .text = "alt" },
    };
    const next = [_]ast.InlineRef{ ast.no_inline, ast.no_inline };
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(19, inlineWidth(&doc, 0, .narrow));
}

test "HTML entity width uses decoded bytes" {
    const nodes = [_]ast.InlineNode{.{ .text = "&amp;" }};
    const next = [_]ast.InlineRef{ast.no_inline};
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(1, inlineWidth(&doc, 0, .narrow));
}

test "mixed text with entity" {
    const nodes = [_]ast.InlineNode{.{ .text = "a&amp;b" }};
    const next = [_]ast.InlineRef{ast.no_inline};
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(3, inlineWidth(&doc, 0, .narrow));
}

test "unknown entity is measured literally" {
    const nodes = [_]ast.InlineNode{.{ .text = "&unknown;" }};
    const next = [_]ast.InlineRef{ast.no_inline};
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(9, inlineWidth(&doc, 0, .narrow));
}

test "CJK characters are width 2" {
    const nodes = [_]ast.InlineNode{.{ .text = "漢字" }};
    const next = [_]ast.InlineRef{ast.no_inline};
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(4, inlineWidth(&doc, 0, .narrow));
}

test "nested emphasis with link" {
    const nodes = [_]ast.InlineNode{
        .{ .emphasis = 1 },
        .{ .link = .{
            .url = "u",
            .title = null,
            .children = 2,
        } },
        .{ .text = "x" },
    };
    const next = [_]ast.InlineRef{ ast.no_inline, ast.no_inline, ast.no_inline };
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(4, inlineWidth(&doc, 0, .narrow));
}

test "matches rendered width" {
    const allocator = testing.allocator;
    const theme = @import("../term/theme.zig");
    const nodes = [_]ast.InlineNode{
        .{ .strong = 3 },
        .{ .text = " " },
        .{ .link = .{ .url = "http://example.com", .title = "A title", .children = 4 } },
        .{ .text = "hello &amp; world" },
        .{ .text = "link" },
    };
    const next = [_]ast.InlineRef{ 1, 2, ast.no_inline, ast.no_inline, ast.no_inline };
    const doc = testDoc(&nodes, &next);

    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try render_inline.writeInlineChain(
        &buf.writer,
        &doc,
        0,
        false,
        .{},
        theme.palette(.solarized_dark),
    );

    const rendered = buf.writer.buffered();
    const rendered_width = width.displayWidth(rendered, .narrow);
    const measured_width = inlineWidth(&doc, 0, .narrow);
    try testing.expectEqual(rendered_width, measured_width);
}
