const std = @import("std");
const block_ast = @import("block_ast.zig");
const parse_document = @import("parse_document.zig");

test "parseDocument produces a single Paragraph for plain text" {
    const allocator = std.testing.allocator;
    const input = "Hello world\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try std.testing.expectEqual(@as(usize, 1), doc.blocks[0].paragraph.lines.len);
    try std.testing.expectEqualStrings("Hello world", doc.blocks[0].paragraph.lines[0]);
    try std.testing.expect(doc.has_trailing_newline);
}

test "parseDocument groups consecutive non-blank lines into one Paragraph" {
    const allocator = std.testing.allocator;
    const input = "First line\nSecond line\nThird line\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try std.testing.expectEqual(@as(usize, 3), doc.blocks[0].paragraph.lines.len);
    try std.testing.expectEqualStrings("First line", doc.blocks[0].paragraph.lines[0]);
    try std.testing.expectEqualStrings("Second line", doc.blocks[0].paragraph.lines[1]);
    try std.testing.expectEqualStrings("Third line", doc.blocks[0].paragraph.lines[2]);
}

test "parseDocument collapses runs of blank lines into one blank_line node" {
    const allocator = std.testing.allocator;
    const input = "First\n\n\n\nSecond\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    try std.testing.expect(doc.blocks[1] == .blank_line);
    try std.testing.expect(doc.blocks[2] == .paragraph);
    try std.testing.expectEqualStrings("First", doc.blocks[0].paragraph.lines[0]);
    try std.testing.expectEqualStrings("Second", doc.blocks[2].paragraph.lines[0]);
}

test "parseDocument records ATX heading level and content" {
    const allocator = std.testing.allocator;
    const input = "## My Heading\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .heading);
    try std.testing.expectEqual(@as(u8, 2), doc.blocks[0].heading.level);
    try std.testing.expectEqualStrings("My Heading", doc.blocks[0].heading.content);
}

test "parseDocument groups adjacent unordered list items into one List" {
    const allocator = std.testing.allocator;
    const input = "- First\n- Second\n- Third\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    try std.testing.expectEqual(block_ast.ListKind.unordered, doc.blocks[0].list.kind);
    try std.testing.expectEqual(@as(usize, 3), doc.blocks[0].list.items.len);

    for (doc.blocks[0].list.items) |item| {
        try std.testing.expectEqual(@as(u8, '-'), item.marker);
        try std.testing.expect(item.checked == null);
        try std.testing.expect(item.number == null);
        try std.testing.expectEqual(@as(usize, 1), item.blocks.len);
        try std.testing.expect(item.blocks[0] == .paragraph);
    }
    try std.testing.expectEqualStrings("First", doc.blocks[0].list.items[0].blocks[0].paragraph.lines[0]);
    try std.testing.expectEqualStrings("Second", doc.blocks[0].list.items[1].blocks[0].paragraph.lines[0]);
    try std.testing.expectEqualStrings("Third", doc.blocks[0].list.items[2].blocks[0].paragraph.lines[0]);
}

test "parseDocument stores task checkbox state on list items" {
    const allocator = std.testing.allocator;
    const input = "- [x] Done\n- [ ] Todo\n- Plain item\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const items = doc.blocks[0].list.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);

    try std.testing.expectEqual(@as(?bool, true), items[0].checked);
    try std.testing.expectEqual(@as(?bool, false), items[1].checked);
    try std.testing.expectEqual(@as(?bool, null), items[2].checked);

    try std.testing.expectEqualStrings("Done", items[0].blocks[0].paragraph.lines[0]);
    try std.testing.expectEqualStrings("Todo", items[1].blocks[0].paragraph.lines[0]);
    try std.testing.expectEqualStrings("Plain item", items[2].blocks[0].paragraph.lines[0]);
}

test "parseDocument groups ordered list items and records numbers" {
    const allocator = std.testing.allocator;
    const input = "1. First\n2. Second\n10. Tenth\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    try std.testing.expectEqual(block_ast.ListKind.ordered, doc.blocks[0].list.kind);

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

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    try std.testing.expectEqual(@as(usize, 1), doc.blocks[0].list.items.len);

    const item = doc.blocks[0].list.items[0];
    try std.testing.expect(item.blocks[0] == .paragraph);
    const lines = item.blocks[0].paragraph.lines;
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("first line", lines[0]);
    try std.testing.expectEqualStrings("continued here", lines[1]);
    try std.testing.expectEqualStrings("more continuation", lines[2]);
}

test "parseDocument collects link definitions into the document map" {
    const allocator = std.testing.allocator;
    const input = "[Foo]: http://foo.example/ \"Title\"\n[Bar]: http://bar.example/\nbody text\n";

    var doc = try parse_document.parseDocument(allocator, input);
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

    var doc = try parse_document.parseDocument(allocator, input);
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

    var doc = try parse_document.parseDocument(allocator, input);
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

    var doc = try parse_document.parseDocument(allocator, input);
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

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 0), bq.indent);
    try std.testing.expectEqual(@as(usize, 1), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .paragraph);
    const lines = bq.blocks[0].paragraph.lines;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("first quoted", lines[0]);
    try std.testing.expectEqualStrings("second quoted", lines[1]);
}

test "parseDocument parses table with header and body rows" {
    const allocator = std.testing.allocator;
    const input = "| A | B |\n| --- | ---: |\n| 1 | 2 |\n| 3 | 4 |\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .table);
    const tbl = doc.blocks[0].table;
    try std.testing.expectEqual(@as(usize, 2), tbl.header.len);
    try std.testing.expectEqualStrings("A", tbl.header[0]);
    try std.testing.expectEqualStrings("B", tbl.header[1]);
    try std.testing.expectEqual(@as(usize, 2), tbl.alignments.len);
    try std.testing.expectEqual(@as(usize, 2), tbl.rows.len);
    try std.testing.expectEqualStrings("1", tbl.rows[0][0]);
    try std.testing.expectEqualStrings("2", tbl.rows[0][1]);
    try std.testing.expectEqualStrings("3", tbl.rows[1][0]);
    try std.testing.expectEqualStrings("4", tbl.rows[1][1]);
}

test "parseDocument tracks has_trailing_newline correctly" {
    const allocator = std.testing.allocator;

    {
        var doc = try parse_document.parseDocument(allocator, "Hello\n");
        defer doc.deinit(allocator);
        try std.testing.expect(doc.has_trailing_newline);
    }
    {
        var doc = try parse_document.parseDocument(allocator, "Hello");
        defer doc.deinit(allocator);
        try std.testing.expect(!doc.has_trailing_newline);
    }
}

test "parseDocument handles empty input" {
    const allocator = std.testing.allocator;
    var doc = try parse_document.parseDocument(allocator, "");
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), doc.blocks.len);
    try std.testing.expectEqual(@as(usize, 0), doc.link_defs.count());
    try std.testing.expect(!doc.has_trailing_newline);
}

test "parseDocument wraps blockquote table in BlockQuote with Table child" {
    const allocator = std.testing.allocator;
    const input = "> | A | B |\n> | --- | --- |\n> | 1 | 2 |\n> | 3 | 4 |\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .table);
    const tbl = bq.blocks[0].table;
    try std.testing.expectEqual(@as(usize, 2), tbl.header.len);
    try std.testing.expectEqualStrings("A", tbl.header[0]);
    try std.testing.expectEqualStrings("B", tbl.header[1]);
    try std.testing.expectEqual(@as(usize, 2), tbl.rows.len);
    try std.testing.expectEqualStrings("1", tbl.rows[0][0]);
    try std.testing.expectEqualStrings("4", tbl.rows[1][1]);
}

test "parseDocument groups blockquote table and paragraph into one BlockQuote" {
    const allocator = std.testing.allocator;
    const input = "> | A |\n> | --- |\n> | 1 |\n> normal text\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 2), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .table);
    try std.testing.expect(bq.blocks[1] == .paragraph);
    try std.testing.expectEqualStrings(
        "normal text",
        bq.blocks[1].paragraph.lines[0],
    );
}

test "parseDocument rejects blockquote with pipes but no delimiter as plain blockquote" {
    const allocator = std.testing.allocator;
    const input = "> a | b\n> c | d\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    try std.testing.expect(doc.blocks[0].blockquote.blocks[0] == .paragraph);
    const lines = doc.blocks[0].blockquote.blocks[0].paragraph.lines;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("a | b", lines[0]);
    try std.testing.expectEqualStrings("c | d", lines[1]);
}

test "parseDocument rejects table with mismatched header and delimiter column counts" {
    const allocator = std.testing.allocator;
    const input = "| A |\n| --- | --- |\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expect(doc.blocks.len >= 1);
    for (doc.blocks) |block| {
        try std.testing.expect(block != .table);
    }
}

test "parseDocument groups blockquote paragraph and table into one BlockQuote" {
    const allocator = std.testing.allocator;
    const input = "> intro\n> | A |\n> | --- |\n> | 1 |\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 2), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .paragraph);
    try std.testing.expectEqualStrings("intro", bq.blocks[0].paragraph.lines[0]);
    try std.testing.expect(bq.blocks[1] == .table);
    const tbl = bq.blocks[1].table;
    try std.testing.expectEqualStrings("A", tbl.header[0]);
    try std.testing.expectEqualStrings("1", tbl.rows[0][0]);
}

test "parseDocument keeps paragraph continuous across invalid mid-paragraph table" {
    const allocator = std.testing.allocator;
    const input = "alpha\n| A |\n| --- | --- |\nbeta\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .paragraph);
    const lines = doc.blocks[0].paragraph.lines;
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings("alpha", lines[0]);
    try std.testing.expectEqualStrings("| A |", lines[1]);
    try std.testing.expectEqualStrings("| --- | --- |", lines[2]);
    try std.testing.expectEqualStrings("beta", lines[3]);
}

test "parseDocument splits blockquote on indent change between lines" {
    const allocator = std.testing.allocator;
    const input = "> a\n  > b\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    try std.testing.expectEqual(@as(usize, 0), doc.blocks[0].blockquote.indent);
    try std.testing.expectEqualStrings(
        "a",
        doc.blocks[0].blockquote.blocks[0].paragraph.lines[0],
    );
    try std.testing.expect(doc.blocks[1] == .blockquote);
    try std.testing.expectEqual(@as(usize, 2), doc.blocks[1].blockquote.indent);
    try std.testing.expectEqualStrings(
        "b",
        doc.blocks[1].blockquote.blocks[0].paragraph.lines[0],
    );
}

test "parseDocument represents nested blockquote as recursive BlockQuote" {
    const allocator = std.testing.allocator;
    const input = "> > nested\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const outer = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), outer.blocks.len);
    try std.testing.expect(outer.blocks[0] == .blockquote);
    const inner = outer.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), inner.blocks.len);
    try std.testing.expect(inner.blocks[0] == .paragraph);
    try std.testing.expectEqualStrings("nested", inner.blocks[0].paragraph.lines[0]);
}

test "parseDocument represents triple-nested blockquote" {
    const allocator = std.testing.allocator;
    const input = "> > > deep\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const l1 = doc.blocks[0].blockquote;
    try std.testing.expect(l1.blocks[0] == .blockquote);
    const l2 = l1.blocks[0].blockquote;
    try std.testing.expect(l2.blocks[0] == .blockquote);
    const l3 = l2.blocks[0].blockquote;
    try std.testing.expect(l3.blocks[0] == .paragraph);
    try std.testing.expectEqualStrings("deep", l3.blocks[0].paragraph.lines[0]);
}

test "parseDocument groups plain and nested blockquote lines as siblings" {
    const allocator = std.testing.allocator;
    const input = "> a\n> > b\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const outer = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 2), outer.blocks.len);

    try std.testing.expect(outer.blocks[0] == .paragraph);
    try std.testing.expectEqualStrings("a", outer.blocks[0].paragraph.lines[0]);

    try std.testing.expect(outer.blocks[1] == .blockquote);
    const inner = outer.blocks[1].blockquote;
    try std.testing.expect(inner.blocks[0] == .paragraph);
    try std.testing.expectEqualStrings("b", inner.blocks[0].paragraph.lines[0]);
}

test "parseDocument represents nested unordered list as ListItem.blocks child" {
    const allocator = std.testing.allocator;
    const input = "- parent\n  - child\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const outer_list = doc.blocks[0].list;
    try std.testing.expectEqual(@as(usize, 1), outer_list.items.len);

    const parent = outer_list.items[0];
    try std.testing.expectEqual(@as(usize, 0), parent.indent);
    try std.testing.expectEqual(@as(usize, 2), parent.blocks.len);

    try std.testing.expect(parent.blocks[0] == .paragraph);
    try std.testing.expectEqualStrings("parent", parent.blocks[0].paragraph.lines[0]);

    try std.testing.expect(parent.blocks[1] == .list);
    const inner_list = parent.blocks[1].list;
    try std.testing.expectEqual(block_ast.ListKind.unordered, inner_list.kind);
    try std.testing.expectEqual(@as(usize, 1), inner_list.items.len);

    const child = inner_list.items[0];
    try std.testing.expectEqual(@as(usize, 2), child.indent);
    try std.testing.expectEqual(@as(usize, 1), child.blocks.len);
    try std.testing.expect(child.blocks[0] == .paragraph);
    try std.testing.expectEqualStrings("child", child.blocks[0].paragraph.lines[0]);
}

test "parseDocument represents ordered parent containing unordered child" {
    const allocator = std.testing.allocator;
    const input = "1. outer\n   - inner\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const outer_list = doc.blocks[0].list;
    try std.testing.expectEqual(block_ast.ListKind.ordered, outer_list.kind);
    try std.testing.expectEqual(@as(usize, 1), outer_list.items.len);

    const outer_item = outer_list.items[0];
    try std.testing.expectEqualStrings("1", outer_item.number.?);
    try std.testing.expectEqual(@as(usize, 2), outer_item.blocks.len);

    try std.testing.expect(outer_item.blocks[0] == .paragraph);
    try std.testing.expectEqualStrings("outer", outer_item.blocks[0].paragraph.lines[0]);

    try std.testing.expect(outer_item.blocks[1] == .list);
    const inner_list = outer_item.blocks[1].list;
    try std.testing.expectEqual(block_ast.ListKind.unordered, inner_list.kind);
    try std.testing.expectEqual(@as(usize, 1), inner_list.items.len);

    const inner_item = inner_list.items[0];
    try std.testing.expectEqual(@as(usize, 3), inner_item.indent);
    try std.testing.expectEqualStrings("inner", inner_item.blocks[0].paragraph.lines[0]);
}

test "parseDocument keeps sibling list items flat when indents match" {
    const allocator = std.testing.allocator;
    const input = "- a\n- b\n- c\n";

    var doc = try parse_document.parseDocument(allocator, input);
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

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const outer = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 2), outer.blocks.len);

    try std.testing.expect(outer.blocks[0] == .paragraph);
    const lines = outer.blocks[0].paragraph.lines;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("first", lines[0]);
    try std.testing.expectEqualStrings("continued", lines[1]);

    try std.testing.expect(outer.blocks[1] == .list);
    const nested = outer.blocks[1].list;
    try std.testing.expectEqual(@as(usize, 1), nested.items.len);
    try std.testing.expectEqualStrings(
        "nested",
        nested.items[0].blocks[0].paragraph.lines[0],
    );
}

test "parseDocument groups slightly indented sibling items into one list" {
    const allocator = std.testing.allocator;
    const input = "- a\n - b\n  - c\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);

    const list = doc.blocks[0].list;
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqual(@as(usize, 0), list.items[0].indent);
    try std.testing.expectEqual(@as(usize, 1), list.items[1].indent);
    try std.testing.expectEqual(@as(usize, 2), list.items[2].indent);
    try std.testing.expectEqualStrings("a", list.items[0].blocks[0].paragraph.lines[0]);
    try std.testing.expectEqualStrings("b", list.items[1].blocks[0].paragraph.lines[0]);
    try std.testing.expectEqualStrings("c", list.items[2].blocks[0].paragraph.lines[0]);
}

test "parseDocument keeps zigzag-indented siblings in one list" {
    const allocator = std.testing.allocator;
    const input = "- a\n - b\n  - c\n - d\n- e\n";

    var doc = try parse_document.parseDocument(allocator, input);
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

    var doc = try parse_document.parseDocument(allocator, input);
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

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const outer = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 3), outer.blocks.len);

    try std.testing.expect(outer.blocks[0] == .paragraph);
    try std.testing.expectEqualStrings("foo", outer.blocks[0].paragraph.lines[0]);

    try std.testing.expect(outer.blocks[1] == .list);
    const nested = outer.blocks[1].list;
    try std.testing.expectEqual(@as(usize, 1), nested.items.len);
    try std.testing.expectEqualStrings("bar", nested.items[0].blocks[0].paragraph.lines[0]);

    try std.testing.expect(outer.blocks[2] == .paragraph);
    try std.testing.expectEqualStrings("baz", outer.blocks[2].paragraph.lines[0]);
}

test "parseDocument uses dynamic content_col from multi-space marker" {
    const allocator = std.testing.allocator;
    const input = "-   foo\n    continuation\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 1), item.blocks.len);
    try std.testing.expect(item.blocks[0] == .paragraph);
    const lines = item.blocks[0].paragraph.lines;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("foo", lines[0]);
    try std.testing.expectEqualStrings("continuation", lines[1]);
}

test "parseDocument rejects under-indented continuation when marker has extra spaces" {
    const allocator = std.testing.allocator;
    const input = "-   foo\n  sub\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 1), item.blocks.len);
    try std.testing.expect(item.blocks[0] == .paragraph);
    try std.testing.expectEqual(@as(usize, 1), item.blocks[0].paragraph.lines.len);
    try std.testing.expectEqualStrings("foo", item.blocks[0].paragraph.lines[0]);

    try std.testing.expect(doc.blocks[1] == .paragraph);
}

test "parseDocument represents blockquote containing unordered list" {
    const allocator = std.testing.allocator;
    const input = "> - item\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const bq = doc.blocks[0].blockquote;
    try std.testing.expectEqual(@as(usize, 1), bq.blocks.len);
    try std.testing.expect(bq.blocks[0] == .list);
    const list = bq.blocks[0].list;
    try std.testing.expectEqual(block_ast.ListKind.unordered, list.kind);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings(
        "item",
        list.items[0].blocks[0].paragraph.lines[0],
    );
}

test "parseDocument represents blockquote containing ordered list" {
    const allocator = std.testing.allocator;
    const input = "> 1. foo\n> 2. bar\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .blockquote);
    const list = doc.blocks[0].blockquote.blocks[0].list;
    try std.testing.expectEqual(block_ast.ListKind.ordered, list.kind);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("1", list.items[0].number.?);
    try std.testing.expectEqualStrings("2", list.items[1].number.?);
    try std.testing.expectEqualStrings("foo", list.items[0].blocks[0].paragraph.lines[0]);
    try std.testing.expectEqualStrings("bar", list.items[1].blocks[0].paragraph.lines[0]);
}

test "parseDocument represents loose list with blank-separated paragraphs in one item" {
    const allocator = std.testing.allocator;
    const input = "- foo\n\n  bar\n";

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expect(doc.blocks[0] == .list);
    const item = doc.blocks[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 3), item.blocks.len);
    try std.testing.expect(item.blocks[0] == .paragraph);
    try std.testing.expect(item.blocks[1] == .blank_line);
    try std.testing.expect(item.blocks[2] == .paragraph);
    try std.testing.expectEqualStrings("foo", item.blocks[0].paragraph.lines[0]);
    try std.testing.expectEqualStrings("bar", item.blocks[2].paragraph.lines[0]);
}

test "parseDocument represents list item containing blockquote child" {
    const allocator = std.testing.allocator;
    const input = "- intro\n  > quoted child\n";

    var doc = try parse_document.parseDocument(allocator, input);
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
    try std.testing.expectEqualStrings(
        "quoted child",
        inner_bq.blocks[0].paragraph.lines[0],
    );
}

test "parseDocument keeps inner blockquote indent at zero inside list item" {
    const allocator = std.testing.allocator;
    const input = "- foo\n  > > quoted\n";

    var doc = try parse_document.parseDocument(allocator, input);
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
    try std.testing.expectEqualStrings(
        "quoted",
        inner_bq.blocks[0].paragraph.lines[0],
    );
}

test "parseDocument represents list item containing fenced code child" {
    const allocator = std.testing.allocator;
    const input = "- outer\n  ```\n  body\n  ```\n";

    var doc = try parse_document.parseDocument(allocator, input);
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

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    const l0 = doc.blocks[0].list;
    try std.testing.expectEqual(@as(usize, 1), l0.items.len);
    try std.testing.expectEqualStrings("a", l0.items[0].blocks[0].paragraph.lines[0]);

    try std.testing.expect(l0.items[0].blocks[1] == .list);
    const l1 = l0.items[0].blocks[1].list;
    try std.testing.expectEqual(@as(usize, 1), l1.items.len);
    try std.testing.expectEqualStrings("b", l1.items[0].blocks[0].paragraph.lines[0]);

    try std.testing.expect(l1.items[0].blocks[1] == .list);
    const l2 = l1.items[0].blocks[1].list;
    try std.testing.expectEqual(@as(usize, 1), l2.items.len);
    try std.testing.expectEqualStrings("c", l2.items[0].blocks[0].paragraph.lines[0]);
}
