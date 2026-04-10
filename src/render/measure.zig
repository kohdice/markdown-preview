const std = @import("std");
const ast = @import("../ast.zig");
const text = @import("../text.zig");
const width = @import("../term/width.zig");
const render_inline = @import("inline.zig");

pub fn inlineWidth(inlines: []const ast.Inline, ambiguous: width.AmbiguousWidth) usize {
    var total: usize = 0;
    for (inlines) |node| {
        total += switch (node) {
            .text => |content| textWidthWithEntities(content, ambiguous),
            .code_span => |content| width.displayWidth(content, ambiguous),
            .autolink => |url| width.displayWidth(url, ambiguous),
            .soft_break, .hard_break => 0,
            .emphasis => |children| inlineWidth(children, ambiguous),
            .strong => |children| inlineWidth(children, ambiguous),
            .bold_italic => |children| inlineWidth(children, ambiguous),
            .strikethrough => |children| inlineWidth(children, ambiguous),
            .link => |link| blk: {
                var w = inlineWidth(link.children, ambiguous);
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
                w += inlineWidth(img.children, ambiguous);
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

test "plain text width" {
    const inlines = [_]ast.Inline{.{ .text = "hello" }};
    try testing.expectEqual(5, inlineWidth(&inlines, .narrow));
}

test "empty inlines" {
    try testing.expectEqual(0, inlineWidth(&.{}, .narrow));
}

test "code span width" {
    const inlines = [_]ast.Inline{.{ .code_span = "x + y" }};
    try testing.expectEqual(5, inlineWidth(&inlines, .narrow));
}

test "autolink width" {
    const inlines = [_]ast.Inline{.{ .autolink = "http://example.com" }};
    try testing.expectEqual(18, inlineWidth(&inlines, .narrow));
}

test "soft break and hard break are zero width" {
    const inlines = [_]ast.Inline{ .{ .text = "a" }, .soft_break, .{ .text = "b" }, .hard_break, .{ .text = "c" } };
    try testing.expectEqual(3, inlineWidth(&inlines, .narrow));
}

test "emphasis does not add width" {
    var children = [_]ast.Inline{.{ .text = "bold" }};
    const inlines = [_]ast.Inline{.{ .strong = &children }};
    try testing.expectEqual(4, inlineWidth(&inlines, .narrow));
}

test "link width includes url and delimiters" {
    var children = [_]ast.Inline{.{ .text = "click" }};
    const inlines = [_]ast.Inline{.{ .link = .{
        .url = "http://x.co",
        .title = null,
        .children = &children,
    } }};
    try testing.expectEqual(18, inlineWidth(&inlines, .narrow));
}

test "link width includes title" {
    var children = [_]ast.Inline{.{ .text = "a" }};
    const inlines = [_]ast.Inline{.{ .link = .{
        .url = "u",
        .title = "T",
        .children = &children,
    } }};
    try testing.expectEqual(8, inlineWidth(&inlines, .narrow));
}

test "image width includes alt prefix and suffix" {
    var children = [_]ast.Inline{.{ .text = "alt" }};
    const inlines = [_]ast.Inline{.{ .image = .{
        .url = "img.png",
        .title = null,
        .children = &children,
    } }};
    try testing.expectEqual(19, inlineWidth(&inlines, .narrow));
}

test "HTML entity width uses decoded bytes" {
    const inlines = [_]ast.Inline{.{ .text = "&amp;" }};
    try testing.expectEqual(1, inlineWidth(&inlines, .narrow));
}

test "mixed text with entity" {
    const inlines = [_]ast.Inline{.{ .text = "a&amp;b" }};
    try testing.expectEqual(3, inlineWidth(&inlines, .narrow));
}

test "unknown entity is measured literally" {
    const inlines = [_]ast.Inline{.{ .text = "&unknown;" }};
    try testing.expectEqual(9, inlineWidth(&inlines, .narrow));
}

test "CJK characters are width 2" {
    const inlines = [_]ast.Inline{.{ .text = "漢字" }};
    try testing.expectEqual(4, inlineWidth(&inlines, .narrow));
}

test "nested emphasis with link" {
    var link_children = [_]ast.Inline{.{ .text = "x" }};
    var em_children = [_]ast.Inline{.{ .link = .{
        .url = "u",
        .title = null,
        .children = &link_children,
    } }};
    const inlines = [_]ast.Inline{.{ .emphasis = &em_children }};
    try testing.expectEqual(4, inlineWidth(&inlines, .narrow));
}

test "matches rendered width" {
    const allocator = testing.allocator;
    const theme = @import("../term/theme.zig");

    var children = [_]ast.Inline{.{ .text = "hello &amp; world" }};
    var link_children = [_]ast.Inline{.{ .text = "link" }};
    var inlines = [_]ast.Inline{
        .{ .strong = &children },
        .{ .text = " " },
        .{ .link = .{ .url = "http://example.com", .title = "A title", .children = &link_children } },
    };

    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try render_inline.writeInlines(
        &buf.writer,
        &inlines,
        false,
        .{},
        theme.palette(.solarized_dark),
    );

    const rendered = buf.writer.buffered();
    const rendered_width = width.displayWidth(rendered, .narrow);
    const measured_width = inlineWidth(&inlines, .narrow);
    try testing.expectEqual(rendered_width, measured_width);
}
