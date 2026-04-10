const std = @import("std");
const ast = @import("../ast.zig");
const parse = @import("../parse.zig");

fn expectInlineText(expected: []const u8, inlines: []const ast.Inline) !void {
    try std.testing.expect(inlines.len > 0);
    try std.testing.expect(inlines[0] == .text);
    try std.testing.expectEqualStrings(expected, inlines[0].text);
}

test "parseDocument produces a single Paragraph for plain text" {
    const allocator = std.testing.allocator;
    const input = "Hello world\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try expectInlineText("Hello world", doc.blocks[0].paragraph.children);
    try std.testing.expect(doc.has_trailing_newline);
}

test "parseDocument groups consecutive non-blank lines into one Paragraph" {
    const allocator = std.testing.allocator;
    const input = "First line\nSecond line\nThird line\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    const c = doc.blocks[0].paragraph.children;

    try std.testing.expectEqual(@as(usize, 5), c.len);
    try std.testing.expect(c[0] == .text);
    try std.testing.expectEqualStrings("First line", c[0].text);
    try std.testing.expect(c[1] == .soft_break);
    try std.testing.expect(c[2] == .text);
    try std.testing.expectEqualStrings("Second line", c[2].text);
    try std.testing.expect(c[3] == .soft_break);
    try std.testing.expect(c[4] == .text);
    try std.testing.expectEqualStrings("Third line", c[4].text);
}

test "parseDocument collapses runs of blank lines into one blank_line node" {
    const allocator = std.testing.allocator;
    const input = "First\n\n\n\nSecond\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try std.testing.expect(doc.blocks[1] == .blank_line);
    try std.testing.expect(doc.blocks[2] == .paragraph);
    try expectInlineText("First", doc.blocks[0].paragraph.children);
    try expectInlineText("Second", doc.blocks[2].paragraph.children);
}

test "parseDocument records ATX heading level and content" {
    const allocator = std.testing.allocator;
    const input = "## My Heading\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .heading);
    try std.testing.expectEqual(@as(u8, 2), doc.blocks[0].heading.level);
    try expectInlineText("My Heading", doc.blocks[0].heading.children);
}

test "parseDocument groups adjacent unordered list items into one List" {
    const allocator = std.testing.allocator;
    const input = "- First\n- Second\n- Third\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    try std.testing.expectEqual(ast.ListKind.unordered, doc.blocks[0].list.kind);
    try std.testing.expectEqual(@as(usize, 3), doc.blocks[0].list.items.len);

    for (doc.blocks[0].list.items) |item| {
        try std.testing.expectEqual(@as(u8, '-'), item.marker);
        try std.testing.expect(item.checked == null);
        try std.testing.expect(item.number == null);
        try std.testing.expectEqual(@as(usize, 1), item.blocks.len);
        try std.testing.expect(item.blocks[0] == .paragraph);
    }
    try expectInlineText("First", doc.blocks[0].list.items[0].blocks[0].paragraph.children);
    try expectInlineText("Second", doc.blocks[0].list.items[1].blocks[0].paragraph.children);
    try expectInlineText("Third", doc.blocks[0].list.items[2].blocks[0].paragraph.children);
}

test "parseDocument stores task checkbox state on list items" {
    const allocator = std.testing.allocator;
    const input = "- [x] Done\n- [ ] Todo\n- Plain item\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const items = doc.blocks[0].list.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);

    try std.testing.expectEqual(@as(?bool, true), items[0].checked);
    try std.testing.expectEqual(@as(?bool, false), items[1].checked);
    try std.testing.expectEqual(@as(?bool, null), items[2].checked);

    try expectInlineText("Done", items[0].blocks[0].paragraph.children);
    try expectInlineText("Todo", items[1].blocks[0].paragraph.children);
    try expectInlineText("Plain item", items[2].blocks[0].paragraph.children);
}

test "parseDocument groups ordered list items and records numbers" {
    const allocator = std.testing.allocator;
    const input = "1. First\n2. Second\n10. Tenth\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    try std.testing.expectEqual(ast.ListKind.ordered, doc.blocks[0].list.kind);

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

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    try std.testing.expectEqual(@as(usize, 1), doc.blocks[0].list.items.len);

    const item = doc.blocks[0].list.items[0];
    try std.testing.expect(item.blocks[0] == .paragraph);
    const c = item.blocks[0].paragraph.children;

    try std.testing.expectEqual(@as(usize, 5), c.len);
    try std.testing.expectEqualStrings("first line", c[0].text);
    try std.testing.expect(c[1] == .soft_break);
    try std.testing.expectEqualStrings("continued here", c[2].text);
    try std.testing.expect(c[3] == .soft_break);
    try std.testing.expectEqualStrings("more continuation", c[4].text);
}

test "parseDocument collects link definitions into the document map" {
    const allocator = std.testing.allocator;
    const input = "[Foo]: http://foo.example/ \"Title\"\n[Bar]: http://bar.example/\nbody text\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), doc.link_defs.count());
    const foo = doc.link_defs.get("foo").?;
    try std.testing.expectEqualStrings("http://foo.example/", foo.url);
    try std.testing.expectEqualStrings("Title", foo.title.?);
    const bar = doc.link_defs.get("bar").?;
    try std.testing.expectEqualStrings("http://bar.example/", bar.url);
    try std.testing.expect(bar.title == null);
}

test "parseDocument parses fenced code block content" {
    const allocator = std.testing.allocator;
    const input = "```zig\nconst x = 1;\nconst y = 2;\n```\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

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

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .code_fence);
    const cf = doc.blocks[0].code_fence;
    try std.testing.expectEqualStrings("```", cf.opener);
    try std.testing.expect(cf.closer == null);
    try std.testing.expectEqualStrings("foo", cf.content);
}

test "parseDocument parses thematic break" {
    const allocator = std.testing.allocator;
    const input = "before\n\n---\n\nafter\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

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

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 0), bq.indent);
    try std.testing.expectEqual(@as(usize, 1), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .paragraph);
    const c = bq.blocks[0].paragraph.children;
    try std.testing.expectEqual(@as(usize, 3), c.len);
    try std.testing.expectEqualStrings("first quoted", c[0].text);
    try std.testing.expect(c[1] == .soft_break);
    try std.testing.expectEqualStrings("second quoted", c[2].text);
}

test "parseDocument parses table with header and body rows" {
    const allocator = std.testing.allocator;
    const input = "| A | B |\n| --- | ---: |\n| 1 | 2 |\n| 3 | 4 |\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .table);
    const tbl = doc.blocks[0].table;
    try std.testing.expectEqual(@as(usize, 2), tbl.header.len);
    try expectInlineText("A", tbl.header[0].children);
    try expectInlineText("B", tbl.header[1].children);
    try std.testing.expectEqual(@as(usize, 2), tbl.alignments.len);
    try std.testing.expectEqual(@as(usize, 2), tbl.rows.len);
    try expectInlineText("1", tbl.rows[0][0].children);
    try expectInlineText("2", tbl.rows[0][1].children);
    try expectInlineText("3", tbl.rows[1][0].children);
    try expectInlineText("4", tbl.rows[1][1].children);
}

test "parseDocument tracks has_trailing_newline correctly" {
    const allocator = std.testing.allocator;

    {
        var doc = try parse.parse(allocator, "Hello\n");
        defer doc.deinit(allocator);
        try std.testing.expect(doc.has_trailing_newline);
    }
    {
        var doc = try parse.parse(allocator, "Hello");
        defer doc.deinit(allocator);
        try std.testing.expect(!doc.has_trailing_newline);
    }
}

test "parseDocument handles empty input" {
    const allocator = std.testing.allocator;
    var doc = try parse.parse(allocator, "");
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), doc.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), doc.link_defs.count());
    try std.testing.expect(!doc.has_trailing_newline);
}

test "parseDocument wraps blockquote table in BlockQuote with Table child" {
    const allocator = std.testing.allocator;
    const input = "> | A | B |\n> | --- | --- |\n> | 1 | 2 |\n> | 3 | 4 |\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .table);
    const tbl = bq.blocks[0].table;
    try std.testing.expectEqual(@as(usize, 2), tbl.header.len);
    try expectInlineText("A", tbl.header[0].children);
    try expectInlineText("B", tbl.header[1].children);
    try std.testing.expectEqual(@as(usize, 2), tbl.rows.len);
    try expectInlineText("1", tbl.rows[0][0].children);
    try expectInlineText("4", tbl.rows[1][1].children);
}

test "parseDocument groups blockquote table and paragraph into one BlockQuote" {
    const allocator = std.testing.allocator;
    const input = "> | A |\n> | --- |\n> | 1 |\n> normal text\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 2), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .table);
    try std.testing.expect(bq.blocks[1] == .paragraph);
    try expectInlineText(
        "normal text",
        bq.blocks[1].paragraph.children,
    );
}

test "parseDocument rejects blockquote with pipes but no delimiter as plain blockquote" {
    const allocator = std.testing.allocator;
    const input = "> a | b\n> c | d\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    try std.testing.expect(doc.blocks[0].blockquote.blocks[0] == .paragraph);
    try expectInlineText("a | b", doc.blocks[0].blockquote.blocks[0].paragraph.children);
}

test "parseDocument rejects table with mismatched header and delimiter column counts" {
    const allocator = std.testing.allocator;
    const input = "| A |\n| --- | --- |\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expect(doc.blocks.len >= 1);
    for (doc.blocks) |block| {
        try std.testing.expect(block != .table);
    }
}

test "parseDocument parses table when code span contains pipe" {
    const allocator = std.testing.allocator;
    const input = "| `a|b` | c |\n| --- | --- |\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .table);
    const header = doc.blocks[0].table.header;
    try std.testing.expect(header[0].children.len > 0);
    try std.testing.expect(header[0].children[0] == .code_span);
    try std.testing.expectEqualStrings("`a|b`", header[0].children[0].code_span);
    try expectInlineText("c", header[1].children);
}

test "parseDocument rejects table with unclosed code span in header row" {
    const allocator = std.testing.allocator;
    const input = "| `a|b | c |\n| --- | --- |\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try expectInlineText("| `a|b | c |", doc.blocks[0].paragraph.children);
}

test "parseDocument groups blockquote paragraph and table into one BlockQuote" {
    const allocator = std.testing.allocator;
    const input = "> intro\n> | A |\n> | --- |\n> | 1 |\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 2), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .paragraph);
    try expectInlineText("intro", bq.blocks[0].paragraph.children);
    try std.testing.expect(bq.blocks[1] == .table);
    const tbl = bq.blocks[1].table;
    try expectInlineText("A", tbl.header[0].children);
    try expectInlineText("1", tbl.rows[0][0].children);
}

test "parseDocument keeps paragraph continuous across invalid mid-paragraph table" {
    const allocator = std.testing.allocator;
    const input = "alpha\n| A |\n| --- | --- |\nbeta\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    const c = doc.blocks[0].paragraph.children;

    try std.testing.expectEqual(@as(usize, 7), c.len);
    try std.testing.expectEqualStrings("alpha", c[0].text);
    try std.testing.expect(c[1] == .soft_break);
    try std.testing.expectEqualStrings("| A |", c[2].text);
    try std.testing.expect(c[3] == .soft_break);
    try std.testing.expectEqualStrings("| --- | --- |", c[4].text);
    try std.testing.expect(c[5] == .soft_break);
    try std.testing.expectEqualStrings("beta", c[6].text);
}

test "parseDocument splits blockquote on indent change between lines" {
    const allocator = std.testing.allocator;
    const input = "> a\n  > b\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    try std.testing.expectEqual(@as(usize, 0), doc.blocks[0].blockquote.indent);
    try expectInlineText(
        "a",
        doc.blocks[0].blockquote.blocks[0].paragraph.children,
    );
    try std.testing.expect(doc.blocks[1] == .blockquote);
    try std.testing.expectEqual(@as(usize, 2), doc.blocks[1].blockquote.indent);
    try expectInlineText(
        "b",
        doc.blocks[1].blockquote.blocks[0].paragraph.children,
    );
}

test "parseDocument represents nested blockquote as recursive BlockQuote" {
    const allocator = std.testing.allocator;
    const input = "> > nested\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const outer = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), outer.blocks.len);
    try std.testing.expect(outer.blocks[0] == .blockquote);
    const inner = outer.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), inner.blocks.len);
    try std.testing.expect(inner.blocks[0] == .paragraph);
    try expectInlineText("nested", inner.blocks[0].paragraph.children);
}

test "parseDocument represents triple-nested blockquote" {
    const allocator = std.testing.allocator;
    const input = "> > > deep\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const l1 = doc.blocks[0].blockquote;
    try std.testing.expect(l1.blocks[0] == .blockquote);
    const l2 = l1.blocks[0].blockquote;
    try std.testing.expect(l2.blocks[0] == .blockquote);
    const l3 = l2.blocks[0].blockquote;
    try std.testing.expect(l3.blocks[0] == .paragraph);
    try expectInlineText("deep", l3.blocks[0].paragraph.children);
}

test "parseDocument groups plain and nested blockquote lines as siblings" {
    const allocator = std.testing.allocator;
    const input = "> a\n> > b\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const outer = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 2), outer.blocks.len);

    try std.testing.expect(outer.blocks[0] == .paragraph);
    try expectInlineText("a", outer.blocks[0].paragraph.children);

    try std.testing.expect(outer.blocks[1] == .blockquote);
    const inner = outer.blocks[1].blockquote;
    try std.testing.expect(inner.blocks[0] == .paragraph);
    try expectInlineText("b", inner.blocks[0].paragraph.children);
}

test "parseDocument represents nested unordered list as ListItem.blocks child" {
    const allocator = std.testing.allocator;
    const input = "- parent\n  - child\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const outer_list = doc.blocks[0].list;
    try std.testing.expectEqual(@as(usize, 1), outer_list.items.len);

    const parent = outer_list.items[0];
    try std.testing.expectEqual(@as(usize, 0), parent.indent);
    try std.testing.expectEqual(@as(usize, 2), parent.blocks.len);

    try std.testing.expect(parent.blocks[0] == .paragraph);
    try expectInlineText("parent", parent.blocks[0].paragraph.children);

    try std.testing.expect(parent.blocks[1] == .list);
    const inner_list = parent.blocks[1].list;
    try std.testing.expectEqual(ast.ListKind.unordered, inner_list.kind);
    try std.testing.expectEqual(@as(usize, 1), inner_list.items.len);

    const child = inner_list.items[0];
    try std.testing.expectEqual(@as(usize, 2), child.indent);
    try std.testing.expectEqual(@as(usize, 1), child.blocks.len);
    try std.testing.expect(child.blocks[0] == .paragraph);
    try expectInlineText("child", child.blocks[0].paragraph.children);
}

test "parseDocument represents ordered parent containing unordered child" {
    const allocator = std.testing.allocator;
    const input = "1. outer\n   - inner\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const outer_list = doc.blocks[0].list;
    try std.testing.expectEqual(ast.ListKind.ordered, outer_list.kind);
    try std.testing.expectEqual(@as(usize, 1), outer_list.items.len);

    const outer_item = outer_list.items[0];
    try std.testing.expectEqualStrings("1", outer_item.number.?);
    try std.testing.expectEqual(@as(usize, 2), outer_item.blocks.len);

    try std.testing.expect(outer_item.blocks[0] == .paragraph);
    try expectInlineText("outer", outer_item.blocks[0].paragraph.children);

    try std.testing.expect(outer_item.blocks[1] == .list);
    const inner_list = outer_item.blocks[1].list;
    try std.testing.expectEqual(ast.ListKind.unordered, inner_list.kind);
    try std.testing.expectEqual(@as(usize, 1), inner_list.items.len);

    const inner_item = inner_list.items[0];
    try std.testing.expectEqual(@as(usize, 3), inner_item.indent);
    try expectInlineText("inner", inner_item.blocks[0].paragraph.children);
}

test "parseDocument keeps sibling list items flat when indents match" {
    const allocator = std.testing.allocator;
    const input = "- a\n- b\n- c\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

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

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const outer = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 2), outer.blocks.len);

    try std.testing.expect(outer.blocks[0] == .paragraph);
    try expectInlineText("first", outer.blocks[0].paragraph.children);

    try std.testing.expect(outer.blocks[1] == .list);
    const nested = outer.blocks[1].list;
    try std.testing.expectEqual(@as(usize, 1), nested.items.len);
    try expectInlineText(
        "nested",
        nested.items[0].blocks[0].paragraph.children,
    );
}

test "parseDocument groups slightly indented sibling items into one list" {
    const allocator = std.testing.allocator;
    const input = "- a\n - b\n  - c\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const list = doc.blocks[0].list;
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqual(@as(usize, 0), list.items[0].indent);
    try std.testing.expectEqual(@as(usize, 1), list.items[1].indent);
    try std.testing.expectEqual(@as(usize, 2), list.items[2].indent);
    try expectInlineText("a", list.items[0].blocks[0].paragraph.children);
    try expectInlineText("b", list.items[1].blocks[0].paragraph.children);
    try expectInlineText("c", list.items[2].blocks[0].paragraph.children);
}

test "parseDocument keeps zigzag-indented siblings in one list" {
    const allocator = std.testing.allocator;
    const input = "- a\n - b\n  - c\n - d\n- e\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

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

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

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

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const outer = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 3), outer.blocks.len);

    try std.testing.expect(outer.blocks[0] == .paragraph);
    try expectInlineText("foo", outer.blocks[0].paragraph.children);

    try std.testing.expect(outer.blocks[1] == .list);
    const nested = outer.blocks[1].list;
    try std.testing.expectEqual(@as(usize, 1), nested.items.len);
    try expectInlineText("bar", nested.items[0].blocks[0].paragraph.children);

    try std.testing.expect(outer.blocks[2] == .paragraph);
    try expectInlineText("baz", outer.blocks[2].paragraph.children);
}

test "parseDocument uses dynamic content_col from multi-space marker" {
    const allocator = std.testing.allocator;
    const input = "-   foo\n    continuation\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 1), item.blocks.len);
    try std.testing.expect(item.blocks[0] == .paragraph);
    try expectInlineText("foo", item.blocks[0].paragraph.children);
}

test "parseDocument rejects under-indented continuation when marker has extra spaces" {
    const allocator = std.testing.allocator;
    const input = "-   foo\n  sub\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 1), item.blocks.len);
    try std.testing.expect(item.blocks[0] == .paragraph);
    try expectInlineText("foo", item.blocks[0].paragraph.children);

    try std.testing.expect(doc.blocks[1] == .paragraph);
}

test "parseDocument represents blockquote containing unordered list" {
    const allocator = std.testing.allocator;
    const input = "> - item\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .list);
    const list = bq.blocks[0].list;
    try std.testing.expectEqual(ast.ListKind.unordered, list.kind);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try expectInlineText(
        "item",
        list.items[0].blocks[0].paragraph.children,
    );
}

test "parseDocument represents blockquote containing ordered list" {
    const allocator = std.testing.allocator;
    const input = "> 1. foo\n> 2. bar\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const list = doc.blocks[0].blockquote.blocks[0].list;
    try std.testing.expectEqual(ast.ListKind.ordered, list.kind);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("1", list.items[0].number.?);
    try std.testing.expectEqualStrings("2", list.items[1].number.?);
    try expectInlineText("foo", list.items[0].blocks[0].paragraph.children);
    try expectInlineText("bar", list.items[1].blocks[0].paragraph.children);
}

test "parseDocument represents loose list with blank-separated paragraphs in one item" {
    const allocator = std.testing.allocator;
    const input = "- foo\n\n  bar\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 3), item.blocks.len);
    try std.testing.expect(item.blocks[0] == .paragraph);
    try std.testing.expect(item.blocks[1] == .blank_line);
    try std.testing.expect(item.blocks[2] == .paragraph);
    try expectInlineText("foo", item.blocks[0].paragraph.children);
    try expectInlineText("bar", item.blocks[2].paragraph.children);
}

test "parseDocument represents list item containing blockquote child" {
    const allocator = std.testing.allocator;
    const input = "- intro\n  > quoted child\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 2), item.blocks.len);
    try std.testing.expect(item.blocks[0] == .paragraph);
    try std.testing.expect(item.blocks[1] == .blockquote);
    const inner_bq = item.blocks[1].blockquote;
    try std.testing.expectEqual(@as(usize, 2), inner_bq.indent);
    try std.testing.expect(inner_bq.blocks[0] == .paragraph);
    try expectInlineText(
        "quoted child",
        inner_bq.blocks[0].paragraph.children,
    );
}

test "parseDocument keeps inner blockquote indent at zero inside list item" {
    const allocator = std.testing.allocator;
    const input = "- foo\n  > > quoted\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

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
    try expectInlineText(
        "quoted",
        inner_bq.blocks[0].paragraph.children,
    );
}

test "parseDocument represents list item containing fenced code child" {
    const allocator = std.testing.allocator;
    const input = "- outer\n  ```\n  body\n  ```\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

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

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const l0 = doc.blocks[0].list;
    try std.testing.expectEqual(@as(usize, 1), l0.items.len);
    try expectInlineText("a", l0.items[0].blocks[0].paragraph.children);

    try std.testing.expect(l0.items[0].blocks[1] == .list);
    const l1 = l0.items[0].blocks[1].list;
    try std.testing.expectEqual(@as(usize, 1), l1.items.len);
    try expectInlineText("b", l1.items[0].blocks[0].paragraph.children);

    try std.testing.expect(l1.items[0].blocks[1] == .list);
    const l2 = l1.items[0].blocks[1].list;
    try std.testing.expectEqual(@as(usize, 1), l2.items.len);
    try expectInlineText("c", l2.items[0].blocks[0].paragraph.children);
}

test "parseDocument paragraph with hard break produces hard_break node" {
    const allocator = std.testing.allocator;
    const input = "foo  \nbar\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    const children = doc.blocks[0].paragraph.children;
    try std.testing.expectEqual(@as(usize, 3), children.len);
    try std.testing.expect(children[0] == .text);
    try std.testing.expectEqualStrings("foo", children[0].text);
    try std.testing.expect(children[1] == .hard_break);
    try std.testing.expect(children[2] == .text);
    try std.testing.expectEqualStrings("bar", children[2].text);
}

test "parseDocument paragraph with soft break produces soft_break node" {
    const allocator = std.testing.allocator;
    const input = "foo\nbar\n";

    var doc = try parse.parse(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    const children = doc.blocks[0].paragraph.children;
    try std.testing.expectEqual(@as(usize, 3), children.len);
    try std.testing.expect(children[0] == .text);
    try std.testing.expectEqualStrings("foo", children[0].text);
    try std.testing.expect(children[1] == .soft_break);
    try std.testing.expect(children[2] == .text);
    try std.testing.expectEqualStrings("bar", children[2].text);
}
