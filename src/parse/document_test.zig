const std = @import("std");
const ast = @import("../ast.zig");
const parse = @import("../parse.zig");

fn inlineCount(doc: *const ast.Document, first: ast.InlineRef) usize {
    var count: usize = 0;
    var current = first;
    while (ast.hasInline(current)) {
        count += 1;
        current = doc.inlineNext(current);
    }
    return count;
}

fn inlineNodeAt(doc: *const ast.Document, first: ast.InlineRef, index: usize) *const ast.InlineNode {
    var current = first;
    var i: usize = 0;
    while (ast.hasInline(current)) {
        if (i == index) return doc.inlineNode(current);
        current = doc.inlineNext(current);
        i += 1;
    }
    unreachable;
}

fn expectInlineText(expected: []const u8, doc: *const ast.Document, first: ast.InlineRef) !void {
    try std.testing.expect(ast.hasInline(first));
    const inline_node = doc.inlineNode(first);
    try std.testing.expect(inline_node.* == .text);
    try std.testing.expectEqualStrings(expected, inline_node.text);
}

fn expectParagraphText(expected: []const u8, doc: *const ast.Document, paragraph: *const ast.Paragraph) !void {
    try std.testing.expect(ast.hasInline(paragraph.children));
    const node = doc.inlineNode(paragraph.children);
    try std.testing.expect(node.* == .text);
    try std.testing.expectEqualStrings(expected, node.text);
    try std.testing.expectEqual(ast.no_inline, doc.inlineNext(paragraph.children));
}

fn expectParagraphPlainLines(expected: []const []const u8, doc: *const ast.Document, paragraph: *const ast.Paragraph) !void {
    try std.testing.expect(ast.hasInline(paragraph.children));
    var current = paragraph.children;
    for (expected, 0..) |want, idx| {
        const node = doc.inlineNode(current);
        try std.testing.expect(node.* == .text);
        try std.testing.expectEqualStrings(want, node.text);
        current = doc.inlineNext(current);
        if (idx + 1 < expected.len) {
            const break_node = doc.inlineNode(current);
            try std.testing.expect(break_node.* == .soft_break);
            current = doc.inlineNext(current);
        }
    }
    try std.testing.expectEqual(ast.no_inline, current);
}

fn paragraphInlineHead(paragraph: *const ast.Paragraph) ast.InlineRef {
    return paragraph.children;
}

fn expectLinkInlineNode(
    expected_url: []const u8,
    expected_title: ?[]const u8,
    inline_node: *const ast.InlineNode,
) !*const ast.LinkInline {
    try std.testing.expect(inline_node.* == .link);
    try std.testing.expectEqualStrings(expected_url, inline_node.link.url);
    if (expected_title) |title| {
        try std.testing.expectEqualStrings(title, inline_node.link.title.?);
    } else {
        try std.testing.expect(inline_node.link.title == null);
    }
    return &inline_node.link;
}

test "parseDocument produces a single Paragraph for plain text" {
    const allocator = std.testing.allocator;
    const input = "Hello world\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try expectParagraphText("Hello world", &doc, &doc.blocks[0].paragraph);
    try std.testing.expect(doc.has_trailing_newline);
}

test "parseDocument groups consecutive non-blank lines into one Paragraph" {
    const allocator = std.testing.allocator;
    const input = "First line\nSecond line\nThird line\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try expectParagraphPlainLines(&.{ "First line", "Second line", "Third line" }, &doc, &doc.blocks[0].paragraph);
}

test "parseDocument strips leading indentation from paragraph lines" {
    const allocator = std.testing.allocator;
    const input =
        "  aaa\n" ++
        "                 bbb\n" ++
        "                                        ccc\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try expectParagraphPlainLines(&.{ "aaa", "bbb", "ccc" }, &doc, &doc.blocks[0].paragraph);
}

test "parseDocument collapses runs of blank lines into one blank_line node" {
    const allocator = std.testing.allocator;
    const input = "First\n\n\n\nSecond\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 3), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try std.testing.expect(doc.blocks[1] == .blank_line);
    try std.testing.expect(doc.blocks[2] == .paragraph);
    try expectParagraphText("First", &doc, &doc.blocks[0].paragraph);
    try expectParagraphText("Second", &doc, &doc.blocks[2].paragraph);
}

test "parseDocument records ATX heading level and content" {
    const allocator = std.testing.allocator;
    const input = "## My Heading\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .heading);
    try std.testing.expectEqual(@as(u8, 2), doc.blocks[0].heading.level);
    try expectInlineText("My Heading", &doc, doc.blocks[0].heading.children);
}

test "parseDocument parses setext heading after link definition" {
    const allocator = std.testing.allocator;
    const input =
        "[foo]: /url\n" ++
        "bar\n" ++
        "===\n" ++
        "[foo]\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .heading);
    try std.testing.expectEqual(@as(u8, 1), doc.blocks[0].heading.level);
    try expectInlineText("bar", &doc, doc.blocks[0].heading.children);

    try std.testing.expect(doc.blocks[1] == .paragraph);
    const link = try expectLinkInlineNode("/url", null, doc.inlineNode(paragraphInlineHead(&doc.blocks[1].paragraph)));
    try expectInlineText("foo", &doc, link.children);
}

test "parseDocument strips leading indentation from setext heading content" {
    const allocator = std.testing.allocator;
    const input = "   Foo\n---\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .heading);
    try std.testing.expectEqual(@as(u8, 2), doc.blocks[0].heading.level);
    try expectInlineText("Foo", &doc, doc.blocks[0].heading.children);
}

test "parseDocument groups adjacent unordered list items into one List" {
    const allocator = std.testing.allocator;
    const input = "- First\n- Second\n- Third\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    try std.testing.expectEqual(ast.ListKind.unordered, doc.blocks[0].list.kind);
    try std.testing.expect(!doc.blocks[0].list.loose);
    try std.testing.expectEqual(@as(usize, 3), doc.blocks[0].list.items.len);

    for (doc.blocks[0].list.items) |item| {
        try std.testing.expectEqual(@as(u8, '-'), item.marker);
        try std.testing.expect(item.checked == null);
        try std.testing.expect(item.number == null);
        try std.testing.expectEqual(@as(usize, 1), item.blocks.len);
        try std.testing.expect(item.blocks[0] == .paragraph);
    }
    try expectParagraphText("First", &doc, &doc.blocks[0].list.items[0].blocks[0].paragraph);
    try expectParagraphText("Second", &doc, &doc.blocks[0].list.items[1].blocks[0].paragraph);
    try expectParagraphText("Third", &doc, &doc.blocks[0].list.items[2].blocks[0].paragraph);
}

test "parseDocument stores task checkbox state on list items" {
    const allocator = std.testing.allocator;
    const input = "- [x] Done\n- [ ] Todo\n- Plain item\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const items = doc.blocks[0].list.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);

    try std.testing.expectEqual(@as(?bool, true), items[0].checked);
    try std.testing.expectEqual(@as(?bool, false), items[1].checked);
    try std.testing.expectEqual(@as(?bool, null), items[2].checked);

    try expectParagraphText("Done", &doc, &items[0].blocks[0].paragraph);
    try expectParagraphText("Todo", &doc, &items[1].blocks[0].paragraph);
    try expectParagraphText("Plain item", &doc, &items[2].blocks[0].paragraph);
}

test "parseDocument groups ordered list items and records numbers" {
    const allocator = std.testing.allocator;
    const input = "1. First\n2. Second\n10. Tenth\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    try std.testing.expectEqual(ast.ListKind.ordered, doc.blocks[0].list.kind);
    try std.testing.expect(!doc.blocks[0].list.loose);

    const items = doc.blocks[0].list.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("1", items[0].number.?);
    try std.testing.expectEqualStrings("2", items[1].number.?);
    try std.testing.expectEqualStrings("10", items[2].number.?);
    try std.testing.expectEqual(@as(u8, '.'), items[0].marker);
}

test "parseDocument captures unordered list item continuation lines" {
    const allocator = std.testing.allocator;
    const input = "- first line\n  continued here\n  more continuation\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    try std.testing.expectEqual(@as(usize, 1), doc.blocks[0].list.items.len);

    const item = doc.blocks[0].list.items[0];
    try std.testing.expect(item.blocks[0] == .paragraph);
    try expectParagraphPlainLines(&.{ "first line", "continued here", "more continuation" }, &doc, &item.blocks[0].paragraph);
}

test "parseDocument collects link definitions into the document map" {
    const allocator = std.testing.allocator;
    const input = "[ Foo  Bar ]: http://foo.example/ \"Title\"\n[Bar]: http://bar.example/\nbody text\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.link_defs.count());
    const foo = doc.link_defs.get("foo bar").?;
    try std.testing.expectEqualStrings("http://foo.example/", foo.url);
    try std.testing.expectEqualStrings("Title", foo.title.?);
    const bar = doc.link_defs.get("bar").?;
    try std.testing.expectEqualStrings("http://bar.example/", bar.url);
    try std.testing.expect(bar.title == null);
}

test "parseDocument collects link definitions with escaped closing bracket labels" {
    const allocator = std.testing.allocator;
    const input = "[foo\\]]: /url\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.link_defs.count());
    const def = doc.link_defs.get("foo\\]").?;
    try std.testing.expectEqualStrings("/url", def.url);
    try std.testing.expect(def.title == null);
}

test "parseDocument collects multiline link definitions" {
    const allocator = std.testing.allocator;
    const input =
        "[r]:\n" ++
        " /url\n" ++
        " \"line1\n" ++
        "line2\"\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.link_defs.count());
    const def = doc.link_defs.get("r").?;
    try std.testing.expectEqualStrings("/url", def.url);
    try std.testing.expectEqualStrings("line1\nline2", def.title.?);
}

test "parseDocument keeps shortest valid link definition when title continuation is invalid" {
    const allocator = std.testing.allocator;
    const input =
        "[foo]: /url\n" ++
        "\"title\" ok\n" ++
        "[foo]\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.link_defs.count());
    const def = doc.link_defs.get("foo").?;
    try std.testing.expectEqualStrings("/url", def.url);
    try std.testing.expect(def.title == null);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);

    const first = paragraphInlineHead(&doc.blocks[0].paragraph);
    try std.testing.expectEqual(@as(usize, 3), inlineCount(&doc, first));
    try std.testing.expectEqualStrings("\"title\" ok", inlineNodeAt(&doc, first, 0).text);
    try std.testing.expect(inlineNodeAt(&doc, first, 1).* == .soft_break);
    const link = try expectLinkInlineNode("/url", null, inlineNodeAt(&doc, first, 2));
    try expectInlineText("foo", &doc, link.children);
}

test "parseDocument rejects link definitions with ASCII control characters in bare destination" {
    const allocator = std.testing.allocator;
    const input = "[r]: foo\x07bar\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), doc.link_defs.count());
}

test "parseDocument rejects link definitions with backslash before space in bare destination" {
    const allocator = std.testing.allocator;
    const input = "[r]: foo\\ bar\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), doc.link_defs.count());
}

test "parseDocument parses fenced code block content" {
    const allocator = std.testing.allocator;
    const input = "```zig\nconst x = 1;\nconst y = 2;\n```\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .code_fence);
    const cf = doc.blocks[0].code_fence;
    try std.testing.expectEqualStrings("```zig", cf.opener);
    try std.testing.expectEqualStrings("```", cf.closer.?);
    try std.testing.expectEqualStrings("zig", cf.language);
    try std.testing.expectEqualStrings("const x = 1;\nconst y = 2;", cf.content);
}

test "parseDocument records unclosed fenced code as code_fence with null closer" {
    const allocator = std.testing.allocator;
    const input = "```\nfoo\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .code_fence);
    const cf = doc.blocks[0].code_fence;
    try std.testing.expectEqualStrings("```", cf.opener);
    try std.testing.expect(cf.closer == null);
    try std.testing.expectEqualStrings("foo", cf.content);
}

test "parseDocument parses indented code block content" {
    const allocator = std.testing.allocator;
    const input =
        "    code\n" ++
        "    block\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .code_block);
    try std.testing.expectEqualStrings("code\nblock", doc.blocks[0].code_block.content);
}

test "parseDocument keeps trailing blank line outside indented code block" {
    const allocator = std.testing.allocator;
    const input =
        "    code\n" ++
        "\n" ++
        "next\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 3), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .code_block);
    try std.testing.expectEqualStrings("code", doc.blocks[0].code_block.content);
    try std.testing.expect(doc.blocks[1] == .blank_line);
    try std.testing.expect(doc.blocks[2] == .paragraph);
    try expectParagraphText("next", &doc, &doc.blocks[2].paragraph);
}

test "parseDocument parses thematic break" {
    const allocator = std.testing.allocator;
    const input = "before\n\n---\n\nafter\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 5), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try std.testing.expect(doc.blocks[1] == .blank_line);
    try std.testing.expect(doc.blocks[2] == .thematic_break);
    try std.testing.expect(doc.blocks[3] == .blank_line);
    try std.testing.expect(doc.blocks[4] == .paragraph);
}

test "parseDocument parses blockquote with content lines" {
    const allocator = std.testing.allocator;
    const input = "> first quoted\n> second quoted\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 0), bq.indent);
    try std.testing.expectEqual(@as(usize, 1), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .paragraph);
    try expectParagraphPlainLines(&.{ "first quoted", "second quoted" }, &doc, &bq.blocks[0].paragraph);
}

test "parseDocument supports lazy continuation lines in blockquotes" {
    const allocator = std.testing.allocator;
    const input =
        "> foo\n" ++
        "bar\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .paragraph);
    try expectParagraphPlainLines(&.{ "foo", "bar" }, &doc, &bq.blocks[0].paragraph);
}

test "parseDocument parses table with header and body rows" {
    const allocator = std.testing.allocator;
    const input = "| A | B |\n| --- | ---: |\n| 1 | 2 |\n| 3 | 4 |\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .table);
    const tbl = doc.blocks[0].table;
    try std.testing.expectEqual(@as(usize, 2), tbl.header.len);
    try expectInlineText("A", &doc, tbl.header[0].children);
    try expectInlineText("B", &doc, tbl.header[1].children);
    try std.testing.expectEqual(@as(usize, 2), tbl.alignments.len);
    try std.testing.expectEqual(@as(usize, 2), tbl.rows.len);
    try expectInlineText("1", &doc, tbl.rows[0][0].children);
    try expectInlineText("2", &doc, tbl.rows[0][1].children);
    try expectInlineText("3", &doc, tbl.rows[1][0].children);
    try expectInlineText("4", &doc, tbl.rows[1][1].children);
}

test "parseDocument tracks has_trailing_newline correctly" {
    const allocator = std.testing.allocator;

    {
        var doc = try parse.parse(allocator, .{ .borrowed = "Hello\n" });
        defer doc.deinit();
        try std.testing.expect(doc.has_trailing_newline);
    }
    {
        var doc = try parse.parse(allocator, .{ .borrowed = "Hello" });
        defer doc.deinit();
        try std.testing.expect(!doc.has_trailing_newline);
    }
}

test "parseDocument handles empty input" {
    const allocator = std.testing.allocator;
    var doc = try parse.parse(allocator, .{ .borrowed = "" });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), doc.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), doc.link_defs.count());
    try std.testing.expect(!doc.has_trailing_newline);
}

test "parseDocument wraps blockquote table in BlockQuote with Table child" {
    const allocator = std.testing.allocator;
    const input = "> | A | B |\n> | --- | --- |\n> | 1 | 2 |\n> | 3 | 4 |\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .table);
    const tbl = bq.blocks[0].table;
    try std.testing.expectEqual(@as(usize, 2), tbl.header.len);
    try expectInlineText("A", &doc, tbl.header[0].children);
    try expectInlineText("B", &doc, tbl.header[1].children);
    try std.testing.expectEqual(@as(usize, 2), tbl.rows.len);
    try expectInlineText("1", &doc, tbl.rows[0][0].children);
    try expectInlineText("4", &doc, tbl.rows[1][1].children);
}

test "parseDocument groups blockquote table and paragraph into one BlockQuote" {
    const allocator = std.testing.allocator;
    const input = "> | A |\n> | --- |\n> | 1 |\n> normal text\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 2), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .table);
    try std.testing.expect(bq.blocks[1] == .paragraph);
    try expectParagraphText("normal text", &doc, &bq.blocks[1].paragraph);
}

test "parseDocument rejects blockquote with pipes but no delimiter as plain blockquote" {
    const allocator = std.testing.allocator;
    const input = "> a | b\n> c | d\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    try std.testing.expect(doc.blocks[0].blockquote.blocks[0] == .paragraph);
    try expectParagraphPlainLines(&.{ "a | b", "c | d" }, &doc, &doc.blocks[0].blockquote.blocks[0].paragraph);
}

test "parseDocument rejects table with mismatched header and delimiter column counts" {
    const allocator = std.testing.allocator;
    const input = "| A |\n| --- | --- |\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expect(doc.blocks.len >= 1);
    for (doc.blocks) |block| {
        try std.testing.expect(block != .table);
    }
}

test "parseDocument parses table when code span contains pipe" {
    const allocator = std.testing.allocator;
    const input = "| `a|b` | c |\n| --- | --- |\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .table);
    const header = doc.blocks[0].table.header;
    const first_header_children = header[0].children;
    try std.testing.expect(ast.hasInline(first_header_children));
    try std.testing.expect(doc.inlineNode(first_header_children).* == .code_span);
    try std.testing.expectEqualStrings("`a|b`", doc.inlineNode(first_header_children).code_span);
    try expectInlineText("c", &doc, header[1].children);
}

test "parseDocument rejects table with unclosed code span in header row" {
    const allocator = std.testing.allocator;
    const input = "| `a|b | c |\n| --- | --- |\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try expectInlineText("| `a|b | c |", &doc, paragraphInlineHead(&doc.blocks[0].paragraph));
}

test "parseDocument groups blockquote paragraph and table into one BlockQuote" {
    const allocator = std.testing.allocator;
    const input = "> intro\n> | A |\n> | --- |\n> | 1 |\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 2), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .paragraph);
    try expectParagraphText("intro", &doc, &bq.blocks[0].paragraph);
    try std.testing.expect(bq.blocks[1] == .table);
    const tbl = bq.blocks[1].table;
    try expectInlineText("A", &doc, tbl.header[0].children);
    try expectInlineText("1", &doc, tbl.rows[0][0].children);
}

test "parseDocument keeps paragraph continuous across invalid mid-paragraph table" {
    const allocator = std.testing.allocator;
    const input = "alpha\n| A |\n| --- | --- |\nbeta\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try expectParagraphPlainLines(
        &.{ "alpha", "| A |", "| --- | --- |", "beta" },
        &doc,
        &doc.blocks[0].paragraph,
    );
}

test "parseDocument splits blockquote on indent change between lines" {
    const allocator = std.testing.allocator;
    const input = "> a\n  > b\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    try std.testing.expectEqual(@as(usize, 0), doc.blocks[0].blockquote.indent);
    try expectParagraphText("a", &doc, &doc.blocks[0].blockquote.blocks[0].paragraph);
    try std.testing.expect(doc.blocks[1] == .blockquote);
    try std.testing.expectEqual(@as(usize, 2), doc.blocks[1].blockquote.indent);
    try expectParagraphText("b", &doc, &doc.blocks[1].blockquote.blocks[0].paragraph);
}

test "parseDocument represents nested blockquote as recursive BlockQuote" {
    const allocator = std.testing.allocator;
    const input = "> > nested\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const outer = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), outer.blocks.len);
    try std.testing.expect(outer.blocks[0] == .blockquote);
    const inner = outer.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), inner.blocks.len);
    try std.testing.expect(inner.blocks[0] == .paragraph);
    try expectParagraphText("nested", &doc, &inner.blocks[0].paragraph);
}

test "parseDocument represents triple-nested blockquote" {
    const allocator = std.testing.allocator;
    const input = "> > > deep\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const l1 = doc.blocks[0].blockquote;
    try std.testing.expect(l1.blocks[0] == .blockquote);
    const l2 = l1.blocks[0].blockquote;
    try std.testing.expect(l2.blocks[0] == .blockquote);
    const l3 = l2.blocks[0].blockquote;
    try std.testing.expect(l3.blocks[0] == .paragraph);
    try expectParagraphText("deep", &doc, &l3.blocks[0].paragraph);
}

test "parseDocument groups plain and nested blockquote lines as siblings" {
    const allocator = std.testing.allocator;
    const input = "> a\n> > b\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const outer = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 2), outer.blocks.len);

    try std.testing.expect(outer.blocks[0] == .paragraph);
    try expectParagraphText("a", &doc, &outer.blocks[0].paragraph);

    try std.testing.expect(outer.blocks[1] == .blockquote);
    const inner = outer.blocks[1].blockquote;
    try std.testing.expect(inner.blocks[0] == .paragraph);
    try expectParagraphText("b", &doc, &inner.blocks[0].paragraph);
}

test "parseDocument represents nested unordered list as ListItem.blocks child" {
    const allocator = std.testing.allocator;
    const input = "- parent\n  - child\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const outer_list = doc.blocks[0].list;
    try std.testing.expectEqual(@as(usize, 1), outer_list.items.len);

    const parent = outer_list.items[0];
    try std.testing.expectEqual(@as(usize, 0), parent.indent);
    try std.testing.expectEqual(@as(usize, 2), parent.blocks.len);

    try std.testing.expect(parent.blocks[0] == .paragraph);
    try expectParagraphText("parent", &doc, &parent.blocks[0].paragraph);

    try std.testing.expect(parent.blocks[1] == .list);
    const inner_list = parent.blocks[1].list;
    try std.testing.expectEqual(ast.ListKind.unordered, inner_list.kind);
    try std.testing.expectEqual(@as(usize, 1), inner_list.items.len);

    const child = inner_list.items[0];
    try std.testing.expectEqual(@as(usize, 2), child.indent);
    try std.testing.expectEqual(@as(usize, 1), child.blocks.len);
    try std.testing.expect(child.blocks[0] == .paragraph);
    try expectParagraphText("child", &doc, &child.blocks[0].paragraph);
}

test "parseDocument represents ordered parent containing unordered child" {
    const allocator = std.testing.allocator;
    const input = "1. outer\n   - inner\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const outer_list = doc.blocks[0].list;
    try std.testing.expectEqual(ast.ListKind.ordered, outer_list.kind);
    try std.testing.expectEqual(@as(usize, 1), outer_list.items.len);

    const outer_item = outer_list.items[0];
    try std.testing.expectEqualStrings("1", outer_item.number.?);
    try std.testing.expectEqual(@as(usize, 2), outer_item.blocks.len);

    try std.testing.expect(outer_item.blocks[0] == .paragraph);
    try expectParagraphText("outer", &doc, &outer_item.blocks[0].paragraph);

    try std.testing.expect(outer_item.blocks[1] == .list);
    const inner_list = outer_item.blocks[1].list;
    try std.testing.expectEqual(ast.ListKind.unordered, inner_list.kind);
    try std.testing.expectEqual(@as(usize, 1), inner_list.items.len);

    const inner_item = inner_list.items[0];
    try std.testing.expectEqual(@as(usize, 3), inner_item.indent);
    try expectParagraphText("inner", &doc, &inner_item.blocks[0].paragraph);
}

test "parseDocument keeps sibling list items flat when indents match" {
    const allocator = std.testing.allocator;
    const input = "- a\n- b\n- c\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const list = doc.blocks[0].list;
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    for (list.items) |item| {
        try std.testing.expectEqual(@as(usize, 1), item.blocks.len);
        try std.testing.expect(item.blocks[0] == .paragraph);
    }
}

test "parseDocument promotes continuation paragraph then nested list as siblings" {
    const allocator = std.testing.allocator;
    const input = "- first\n  continued\n  - nested\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const outer = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 2), outer.blocks.len);

    try std.testing.expect(outer.blocks[0] == .paragraph);
    try expectParagraphPlainLines(&.{ "first", "continued" }, &doc, &outer.blocks[0].paragraph);

    try std.testing.expect(outer.blocks[1] == .list);
    const nested = outer.blocks[1].list;
    try std.testing.expectEqual(@as(usize, 1), nested.items.len);
    try expectParagraphText("nested", &doc, &nested.items[0].blocks[0].paragraph);
}

test "parseDocument groups slightly indented sibling items into one list" {
    const allocator = std.testing.allocator;
    const input = "- a\n - b\n  - c\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const list = doc.blocks[0].list;
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqual(@as(usize, 0), list.items[0].indent);
    try std.testing.expectEqual(@as(usize, 1), list.items[1].indent);
    try std.testing.expectEqual(@as(usize, 2), list.items[2].indent);
    try expectParagraphText("a", &doc, &list.items[0].blocks[0].paragraph);
    try expectParagraphText("b", &doc, &list.items[1].blocks[0].paragraph);
    try expectParagraphText("c", &doc, &list.items[2].blocks[0].paragraph);
}

test "parseDocument keeps zigzag-indented siblings in one list" {
    const allocator = std.testing.allocator;
    const input = "- a\n - b\n  - c\n - d\n- e\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const list = doc.blocks[0].list;
    try std.testing.expectEqual(@as(usize, 5), list.items.len);
    try std.testing.expectEqual(@as(usize, 0), list.items[0].indent);
    try std.testing.expectEqual(@as(usize, 1), list.items[1].indent);
    try std.testing.expectEqual(@as(usize, 2), list.items[2].indent);
    try std.testing.expectEqual(@as(usize, 1), list.items[3].indent);
    try std.testing.expectEqual(@as(usize, 0), list.items[4].indent);
}

test "parseDocument promotes child when next indent reaches prev content_col" {
    const allocator = std.testing.allocator;
    const input = "- outer\n  - inner\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const list = doc.blocks[0].list;
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    const outer = list.items[0];
    try std.testing.expectEqual(@as(usize, 2), outer.blocks.len);
    try std.testing.expect(outer.blocks[1] == .list);
}

test "parseDocument preserves paragraph after nested list in same list item" {
    const allocator = std.testing.allocator;
    const input = "- foo\n  - bar\n  baz\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const outer = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 3), outer.blocks.len);

    try std.testing.expect(outer.blocks[0] == .paragraph);
    try expectParagraphText("foo", &doc, &outer.blocks[0].paragraph);

    try std.testing.expect(outer.blocks[1] == .list);
    const nested = outer.blocks[1].list;
    try std.testing.expectEqual(@as(usize, 1), nested.items.len);
    try expectParagraphText("bar", &doc, &nested.items[0].blocks[0].paragraph);

    try std.testing.expect(outer.blocks[2] == .paragraph);
    try expectParagraphText("baz", &doc, &outer.blocks[2].paragraph);
}

test "parseDocument uses dynamic content_col from multi-space marker" {
    const allocator = std.testing.allocator;
    const input = "-   foo\n    continuation\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 1), item.blocks.len);
    try std.testing.expect(item.blocks[0] == .paragraph);
    try expectParagraphPlainLines(&.{ "foo", "continuation" }, &doc, &item.blocks[0].paragraph);
}

test "parseDocument rejects under-indented continuation when marker has extra spaces" {
    const allocator = std.testing.allocator;
    const input = "-   foo\n  sub\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 1), item.blocks.len);
    try std.testing.expect(item.blocks[0] == .paragraph);
    try expectParagraphText("foo", &doc, &item.blocks[0].paragraph);

    try std.testing.expect(doc.blocks[1] == .paragraph);
}

test "parseDocument represents blockquote containing unordered list" {
    const allocator = std.testing.allocator;
    const input = "> - item\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .list);
    const list = bq.blocks[0].list;
    try std.testing.expectEqual(ast.ListKind.unordered, list.kind);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try expectParagraphText("item", &doc, &list.items[0].blocks[0].paragraph);
}

test "parseDocument represents blockquote containing ordered list" {
    const allocator = std.testing.allocator;
    const input = "> 1. foo\n> 2. bar\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const list = doc.blocks[0].blockquote.blocks[0].list;
    try std.testing.expectEqual(ast.ListKind.ordered, list.kind);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("1", list.items[0].number.?);
    try std.testing.expectEqualStrings("2", list.items[1].number.?);
    try expectParagraphText("foo", &doc, &list.items[0].blocks[0].paragraph);
    try expectParagraphText("bar", &doc, &list.items[1].blocks[0].paragraph);
}

test "parseDocument represents loose list with blank-separated paragraphs in one item" {
    const allocator = std.testing.allocator;
    const input = "- foo\n\n  bar\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    try std.testing.expect(doc.blocks[0].list.loose);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 3), item.blocks.len);
    try std.testing.expect(item.blocks[0] == .paragraph);
    try std.testing.expect(item.blocks[1] == .blank_line);
    try std.testing.expect(item.blocks[2] == .paragraph);
    try expectParagraphText("foo", &doc, &item.blocks[0].paragraph);
    try expectParagraphText("bar", &doc, &item.blocks[2].paragraph);
}

test "parseDocument keeps blank-separated sibling items in one loose list" {
    const allocator = std.testing.allocator;
    const input = "- foo\n\n- bar\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const list = doc.blocks[0].list;
    try std.testing.expectEqual(ast.ListKind.unordered, list.kind);
    try std.testing.expect(list.loose);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);

    try expectParagraphText("foo", &doc, &list.items[0].blocks[0].paragraph);
    try expectParagraphText("bar", &doc, &list.items[1].blocks[0].paragraph);
}

test "parseDocument splits unordered lists when bullet markers differ" {
    const allocator = std.testing.allocator;
    const input = "- foo\n+ bar\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    try std.testing.expect(doc.blocks[1] == .list);
    try std.testing.expectEqual(@as(u8, '-'), doc.blocks[0].list.items[0].marker);
    try std.testing.expectEqual(@as(u8, '+'), doc.blocks[1].list.items[0].marker);
}

test "parseDocument splits ordered lists when delimiters differ" {
    const allocator = std.testing.allocator;
    const input = "1. foo\n2) bar\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    try std.testing.expect(doc.blocks[1] == .list);
    try std.testing.expectEqual(@as(u8, '.'), doc.blocks[0].list.items[0].marker);
    try std.testing.expectEqual(@as(u8, ')'), doc.blocks[1].list.items[0].marker);
}

test "parseDocument represents list item containing blockquote child" {
    const allocator = std.testing.allocator;
    const input = "- intro\n  > quoted child\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 2), item.blocks.len);
    try std.testing.expect(item.blocks[0] == .paragraph);
    try std.testing.expect(item.blocks[1] == .blockquote);
    const inner_bq = item.blocks[1].blockquote;
    try std.testing.expectEqual(@as(usize, 2), inner_bq.indent);
    try std.testing.expect(inner_bq.blocks[0] == .paragraph);
    try expectParagraphText("quoted child", &doc, &inner_bq.blocks[0].paragraph);
}

test "parseDocument keeps inner blockquote indent at zero inside list item" {
    const allocator = std.testing.allocator;
    const input = "- foo\n  > > quoted\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 2), item.blocks.len);
    try std.testing.expect(item.blocks[1] == .blockquote);
    const outer_bq = item.blocks[1].blockquote;
    try std.testing.expectEqual(@as(usize, 2), outer_bq.indent);
    try std.testing.expectEqual(@as(usize, 1), outer_bq.blocks.len);
    try std.testing.expect(outer_bq.blocks[0] == .blockquote);
    const inner_bq = outer_bq.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 0), inner_bq.indent);
    try expectParagraphText("quoted", &doc, &inner_bq.blocks[0].paragraph);
}

test "parseDocument represents list item containing fenced code child" {
    const allocator = std.testing.allocator;
    const input = "- outer\n  ```\n  body\n  ```\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 2), item.blocks.len);
    try std.testing.expect(item.blocks[0] == .paragraph);
    try std.testing.expect(item.blocks[1] == .code_fence);
    try std.testing.expectEqualStrings("body", item.blocks[1].code_fence.content);
}

test "parseDocument builds three-level deep unordered nesting" {
    const allocator = std.testing.allocator;
    const input = "- a\n  - b\n    - c\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const l0 = doc.blocks[0].list;
    try std.testing.expectEqual(@as(usize, 1), l0.items.len);
    try expectParagraphText("a", &doc, &l0.items[0].blocks[0].paragraph);

    try std.testing.expect(l0.items[0].blocks[1] == .list);
    const l1 = l0.items[0].blocks[1].list;
    try std.testing.expectEqual(@as(usize, 1), l1.items.len);
    try expectParagraphText("b", &doc, &l1.items[0].blocks[0].paragraph);

    try std.testing.expect(l1.items[0].blocks[1] == .list);
    const l2 = l1.items[0].blocks[1].list;
    try std.testing.expectEqual(@as(usize, 1), l2.items.len);
    try expectParagraphText("c", &doc, &l2.items[0].blocks[0].paragraph);
}

test "parseDocument paragraph with hard break produces hard_break node" {
    const allocator = std.testing.allocator;
    const input = "foo  \nbar\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    const children = paragraphInlineHead(&doc.blocks[0].paragraph);
    try std.testing.expectEqual(@as(usize, 3), inlineCount(&doc, children));
    try std.testing.expect(inlineNodeAt(&doc, children, 0).* == .text);
    try std.testing.expectEqualStrings("foo", inlineNodeAt(&doc, children, 0).text);
    try std.testing.expect(inlineNodeAt(&doc, children, 1).* == .hard_break);
    try std.testing.expect(inlineNodeAt(&doc, children, 2).* == .text);
    try std.testing.expectEqualStrings("bar", inlineNodeAt(&doc, children, 2).text);
}

test "parseDocument trivial multi-line paragraph builds soft_break chain via fast path" {
    const allocator = std.testing.allocator;
    const input = "foo\nbar\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try expectParagraphPlainLines(&.{ "foo", "bar" }, &doc, &doc.blocks[0].paragraph);
}

test "parseDocument paragraph with trigger falls back to full inline parser" {
    const allocator = std.testing.allocator;
    const input = "foo *x*\nbar\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    const first = paragraphInlineHead(&doc.blocks[0].paragraph);
    try std.testing.expect(ast.hasInline(first));

    var saw_soft_break = false;
    var current = first;
    while (ast.hasInline(current)) {
        if (doc.inlineNode(current).* == .soft_break) saw_soft_break = true;
        current = doc.inlineNext(current);
    }
    try std.testing.expect(saw_soft_break);
}

test "parseDocument parses table when escaped pipe appears inside a cell" {
    const allocator = std.testing.allocator;
    const input = "| a\\|b | c |\n| --- | --- |\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .table);
    const children = doc.blocks[0].table.header[0].children;
    try std.testing.expectEqual(@as(usize, 3), inlineCount(&doc, children));
    try std.testing.expectEqualStrings("a", inlineNodeAt(&doc, children, 0).text);
    try std.testing.expectEqualStrings("|", inlineNodeAt(&doc, children, 1).text);
    try std.testing.expectEqualStrings("b", inlineNodeAt(&doc, children, 2).text);
    try expectInlineText("c", &doc, doc.blocks[0].table.header[1].children);
}

test "parseDocument parses table when multi-backtick code span contains pipe" {
    const allocator = std.testing.allocator;
    const input = "| ``a|b`` | c |\n| --- | --- |\n";

    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .table);
    const first_header_children = doc.blocks[0].table.header[0].children;
    try std.testing.expect(ast.hasInline(first_header_children));
    try std.testing.expect(doc.inlineNode(first_header_children).* == .code_span);
    try std.testing.expectEqualStrings("``a|b``", doc.inlineNode(first_header_children).code_span);
    try expectInlineText("c", &doc, doc.blocks[0].table.header[1].children);
}
