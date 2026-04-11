const std = @import("std");

pub const LinkDef = struct {
    url: []const u8,
    title: ?[]const u8 = null,
};

pub const LinkDefMap = std.StringHashMapUnmanaged(LinkDef);

pub const Alignment = enum { left, center, right };

pub const InlineRef = u32;
pub const no_inline: InlineRef = std.math.maxInt(InlineRef);

pub fn hasInline(ref: InlineRef) bool {
    return ref != no_inline;
}

pub const LinkInline = struct {
    url: []const u8,
    title: ?[]const u8,
    children: InlineRef = no_inline,
};

pub const ImageInline = struct {
    url: []const u8,
    title: ?[]const u8,
    children: InlineRef = no_inline,
};

pub const InlineNode = union(enum) {
    text: []const u8,
    code_span: []const u8,
    autolink: []const u8,
    soft_break: void,
    hard_break: void,
    emphasis: InlineRef,
    strong: InlineRef,
    bold_italic: InlineRef,
    strikethrough: InlineRef,
    link: LinkInline,
    image: ImageInline,
};

pub const Inline = InlineNode;

pub const TableCell = struct {
    children: InlineRef = no_inline,
};

pub const Document = struct {
    pub const OwnedSource = struct {
        allocator: std.mem.Allocator,
        buffer: []u8,
    };

    pub const SourceStorage = union(enum) {
        borrowed,
        owned: OwnedSource,
    };

    pub const Storage = union(enum) {
        none,
        arena: std.heap.ArenaAllocator,
    };

    source: []const u8 = "",
    source_storage: SourceStorage = .borrowed,
    inline_nodes: []const InlineNode = &.{},
    inline_next: []const InlineRef = &.{},
    blocks: []BlockNode,
    link_defs: LinkDefMap,
    has_trailing_newline: bool,
    storage: Storage = .none,

    pub fn deinit(self: *Document) void {
        switch (self.storage) {
            .none => {},
            .arena => |arena| arena.deinit(),
        }

        switch (self.source_storage) {
            .borrowed => {},
            .owned => |owned| owned.allocator.free(owned.buffer),
        }

        self.* = .{
            .source = "",
            .source_storage = .borrowed,
            .inline_nodes = &.{},
            .inline_next = &.{},
            .blocks = &.{},
            .link_defs = .{},
            .has_trailing_newline = false,
            .storage = .none,
        };
    }

    pub fn inlineNode(self: *const Document, ref: InlineRef) *const InlineNode {
        const index: usize = @intCast(ref);
        return &self.inline_nodes[index];
    }

    pub fn inlineNext(self: *const Document, ref: InlineRef) InlineRef {
        const index: usize = @intCast(ref);
        return self.inline_next[index];
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
            .code_fence => {},
            .thematic_break => {},
            .table => |*t| t.deinit(allocator),
            .blank_line => {},
        }
    }
};

pub const Paragraph = struct {
    children: InlineRef = no_inline,

    pub fn deinit(self: *Paragraph, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub const Heading = struct {
    level: u8,
    children: InlineRef = no_inline,

    pub fn deinit(self: *Heading, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
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
    loose: bool = false,

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
};

pub const Table = struct {
    header: []TableCell,
    alignments: []Alignment,
    rows: [][]TableCell,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        allocator.free(self.header);
        allocator.free(self.alignments);
        for (self.rows) |row| {
            allocator.free(row);
        }
        allocator.free(self.rows);
    }
};
