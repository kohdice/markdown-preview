const std = @import("std");
const parse_table = @import("parse_table.zig");
const parse_link = @import("parse_link.zig");

pub const Document = struct {
    blocks: []BlockNode,
    link_defs: parse_link.LinkDefMap,
    has_trailing_newline: bool,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.blocks) |*block| block.deinit(allocator);
        allocator.free(self.blocks);

        var it = self.link_defs.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        self.link_defs.deinit(allocator);
    }
};

pub const BlockNode = union(enum) {
    paragraph: Paragraph,
    heading: Heading,
    blockquote: BlockQuote,
    list: List,
    code_fence: CodeFence,
    thematic_break: void,
    table: Table,
    blank_line: void,

    pub fn deinit(self: *BlockNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .paragraph => |*p| p.deinit(allocator),
            .heading => {},
            .blockquote => |*bq| bq.deinit(allocator),
            .list => |*l| l.deinit(allocator),
            .code_fence => |*cf| cf.deinit(allocator),
            .thematic_break => {},
            .table => |*t| t.deinit(allocator),
            .blank_line => {},
        }
    }
};

pub const Paragraph = struct {
    lines: [][]const u8,

    pub fn deinit(self: *Paragraph, allocator: std.mem.Allocator) void {
        allocator.free(self.lines);
    }
};

pub const Heading = struct {
    level: u8,
    content: []const u8,
};

pub const BlockQuote = struct {
    indent: usize,
    blocks: []BlockNode,

    pub fn deinit(self: *BlockQuote, allocator: std.mem.Allocator) void {
        for (self.blocks) |*b| b.deinit(allocator);
        allocator.free(self.blocks);
    }
};

pub const ListKind = enum { unordered, ordered };

pub const List = struct {
    kind: ListKind,
    items: []ListItem,

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const ListItem = struct {
    indent: usize,
    /// `-`, `*`, `+` for unordered; `.` or `)` for ordered.
    marker: u8,
    number: ?[]const u8 = null,
    /// `null` means the item is not a task item; `false` means unchecked.
    checked: ?bool = null,
    blocks: []BlockNode,

    pub fn deinit(self: *ListItem, allocator: std.mem.Allocator) void {
        for (self.blocks) |*b| b.deinit(allocator);
        allocator.free(self.blocks);
    }
};

pub const CodeFence = struct {
    opener: []const u8,
    closer: ?[]const u8,
    language: []const u8,
    content: []const u8,

    pub fn deinit(self: *CodeFence, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const Table = struct {
    header: [][]const u8,
    alignments: []parse_table.Alignment,
    rows: [][][]const u8,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        allocator.free(self.header);
        allocator.free(self.alignments);
        for (self.rows) |row| allocator.free(row);
        allocator.free(self.rows);
    }
};
