const std = @import("std");
const ast = @import("../ast.zig");
const text = @import("../text.zig");
const width = @import("../term/width.zig");
const render_inline = @import("inline.zig");

pub fn inlineWidth(doc: *const ast.Document, range: ast.InlineRange, ambiguous: width.AmbiguousWidth) usize {
    var total: usize = 0;
    for (doc.inlineSlice(range)) |node| {
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

fn testDoc(inline_nodes: []const ast.InlineNode) ast.Document {
    return .{
        .inline_nodes = inline_nodes,
        .blocks = &.{},
        .link_defs = .{},
        .has_trailing_newline = false,
    };
}

fn fullRange(nodes: []const ast.InlineNode) ast.InlineRange {
    return .{
        .start = 0,
        .len = @intCast(nodes.len),
    };
}

test "plain text width" {
    const nodes = [_]ast.InlineNode{.{ .text = "hello" }};
    const doc = testDoc(&nodes);
    try testing.expectEqual(5, inlineWidth(&doc, fullRange(&nodes), .narrow));
}

test "empty inlines" {
    const doc = testDoc(&.{});
    try testing.expectEqual(0, inlineWidth(&doc, .{}, .narrow));
}

test "code span width" {
    const nodes = [_]ast.InlineNode{.{ .code_span = "x + y" }};
    const doc = testDoc(&nodes);
    try testing.expectEqual(5, inlineWidth(&doc, fullRange(&nodes), .narrow));
}

test "autolink width" {
    const nodes = [_]ast.InlineNode{.{ .autolink = "http://example.com" }};
    const doc = testDoc(&nodes);
    try testing.expectEqual(18, inlineWidth(&doc, fullRange(&nodes), .narrow));
}

test "soft break and hard break are zero width" {
    const nodes = [_]ast.InlineNode{ .{ .text = "a" }, .soft_break, .{ .text = "b" }, .hard_break, .{ .text = "c" } };
    const doc = testDoc(&nodes);
    try testing.expectEqual(3, inlineWidth(&doc, fullRange(&nodes), .narrow));
}

test "emphasis does not add width" {
    const nodes = [_]ast.InlineNode{
        .{ .strong = .{ .start = 1, .len = 1 } },
        .{ .text = "bold" },
    };
    const doc = testDoc(&nodes);
    try testing.expectEqual(4, inlineWidth(&doc, .{ .start = 0, .len = 1 }, .narrow));
}

test "link width includes url and delimiters" {
    const nodes = [_]ast.InlineNode{
        .{ .link = .{
            .url = "http://x.co",
            .title = null,
            .children = .{ .start = 1, .len = 1 },
        } },
        .{ .text = "click" },
    };
    const doc = testDoc(&nodes);
    try testing.expectEqual(18, inlineWidth(&doc, .{ .start = 0, .len = 1 }, .narrow));
}

test "link width includes title" {
    const nodes = [_]ast.InlineNode{
        .{ .link = .{
            .url = "u",
            .title = "T",
            .children = .{ .start = 1, .len = 1 },
        } },
        .{ .text = "a" },
    };
    const doc = testDoc(&nodes);
    try testing.expectEqual(8, inlineWidth(&doc, .{ .start = 0, .len = 1 }, .narrow));
}

test "image width includes alt prefix and suffix" {
    const nodes = [_]ast.InlineNode{
        .{ .image = .{
            .url = "img.png",
            .title = null,
            .children = .{ .start = 1, .len = 1 },
        } },
        .{ .text = "alt" },
    };
    const doc = testDoc(&nodes);
    try testing.expectEqual(19, inlineWidth(&doc, .{ .start = 0, .len = 1 }, .narrow));
}

test "HTML entity width uses decoded bytes" {
    const nodes = [_]ast.InlineNode{.{ .text = "&amp;" }};
    const doc = testDoc(&nodes);
    try testing.expectEqual(1, inlineWidth(&doc, fullRange(&nodes), .narrow));
}

test "mixed text with entity" {
    const nodes = [_]ast.InlineNode{.{ .text = "a&amp;b" }};
    const doc = testDoc(&nodes);
    try testing.expectEqual(3, inlineWidth(&doc, fullRange(&nodes), .narrow));
}

test "unknown entity is measured literally" {
    const nodes = [_]ast.InlineNode{.{ .text = "&unknown;" }};
    const doc = testDoc(&nodes);
    try testing.expectEqual(9, inlineWidth(&doc, fullRange(&nodes), .narrow));
}

test "CJK characters are width 2" {
    const nodes = [_]ast.InlineNode{.{ .text = "漢字" }};
    const doc = testDoc(&nodes);
    try testing.expectEqual(4, inlineWidth(&doc, fullRange(&nodes), .narrow));
}

test "nested emphasis with link" {
    const nodes = [_]ast.InlineNode{
        .{ .emphasis = .{ .start = 1, .len = 1 } },
        .{ .link = .{
            .url = "u",
            .title = null,
            .children = .{ .start = 2, .len = 1 },
        } },
        .{ .text = "x" },
    };
    const doc = testDoc(&nodes);
    try testing.expectEqual(4, inlineWidth(&doc, .{ .start = 0, .len = 1 }, .narrow));
}

test "matches rendered width" {
    const allocator = testing.allocator;
    const theme = @import("../term/theme.zig");
    const nodes = [_]ast.InlineNode{
        .{ .strong = .{ .start = 3, .len = 1 } },
        .{ .text = " " },
        .{ .link = .{ .url = "http://example.com", .title = "A title", .children = .{ .start = 4, .len = 1 } } },
        .{ .text = "hello &amp; world" },
        .{ .text = "link" },
    };
    const doc = testDoc(&nodes);
    const top_range: ast.InlineRange = .{ .start = 0, .len = 3 };

    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try render_inline.writeInlineRange(
        &buf.writer,
        &doc,
        top_range,
        false,
        .{},
        theme.palette(.solarized_dark),
    );

    const rendered = buf.writer.buffered();
    const rendered_width = width.displayWidth(rendered, .narrow);
    const measured_width = inlineWidth(&doc, top_range, .narrow);
    try testing.expectEqual(rendered_width, measured_width);
}
