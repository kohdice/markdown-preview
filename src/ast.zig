const std = @import("std");

pub const LinkDef = struct {
    url: []const u8,
    title: ?[]const u8 = null,
};

pub const LinkDefMap = std.StringHashMapUnmanaged(LinkDef);

pub const Alignment = enum { left, center, right };

pub const LinkInline = struct {
    url: []const u8,
    title: ?[]const u8,
    children: []Inline,
};

pub const ImageInline = struct {
    url: []const u8,
    title: ?[]const u8,
    children: []Inline,
};

pub const Inline = union(enum) {
    text: []const u8,
    code_span: []const u8,
    autolink: []const u8,
    soft_break: void,
    hard_break: void,
    emphasis: []Inline,
    strong: []Inline,
    bold_italic: []Inline,
    strikethrough: []Inline,
    link: LinkInline,
    image: ImageInline,
};

pub fn deinitInlines(allocator: std.mem.Allocator, inlines: []Inline) void {
    for (inlines) |inline_node| {
        switch (inline_node) {
            .emphasis, .strong, .bold_italic, .strikethrough => |children| {
                deinitInlines(allocator, children);
            },
            .link => |l| {
                deinitInlines(allocator, l.children);
            },
            .image => |i| {
                deinitInlines(allocator, i.children);
            },
            .text, .code_span, .autolink, .soft_break, .hard_break => {},
        }
    }
    allocator.free(inlines);
}

pub const TableCell = struct {
    children: []Inline,

    pub fn deinit(self: *TableCell, allocator: std.mem.Allocator) void {
        deinitInlines(allocator, self.children);
    }
};

pub const Document = struct {
    blocks: []BlockNode,
    link_defs: LinkDefMap,
    has_trailing_newline: bool,
    owned_text: [][]u8 = &.{},

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.blocks) |*block| block.deinit(allocator);
        allocator.free(self.blocks);

        var it = self.link_defs.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        self.link_defs.deinit(allocator);

        for (self.owned_text) |buf| allocator.free(buf);
        allocator.free(self.owned_text);
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
            .heading => |*h| h.deinit(allocator),
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
    children: []Inline,

    pub fn deinit(self: *Paragraph, allocator: std.mem.Allocator) void {
        deinitInlines(allocator, self.children);
    }
};

pub const Heading = struct {
    level: u8,
    children: []Inline,

    pub fn deinit(self: *Heading, allocator: std.mem.Allocator) void {
        deinitInlines(allocator, self.children);
    }
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
    header: []TableCell,
    alignments: []Alignment,
    rows: [][]TableCell,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        for (self.header) |*cell| cell.deinit(allocator);
        allocator.free(self.header);
        allocator.free(self.alignments);
        for (self.rows) |row| {
            for (row) |*cell| cell.deinit(allocator);
            allocator.free(row);
        }
        allocator.free(self.rows);
    }
};
