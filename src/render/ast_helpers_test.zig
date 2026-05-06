const std = @import("std");
const ast = @import("../ast.zig");
const parse = @import("../parse.zig");
const render = @import("../render.zig");
const ansi = @import("../term/ansi.zig");
const width = @import("../term/width.zig");

pub const FixtureError = error{
    FixtureAlreadyFinished,
    FixtureNotFinished,
    Overflow,
};

pub const RenderFixture = struct {
    state: State = .building,
    arena: ?std.heap.ArenaAllocator,
    inline_nodes: std.ArrayList(ast.InlineNode) = .empty,
    inline_next: std.ArrayList(ast.InlineRef) = .empty,
    blocks: std.ArrayList(ast.BlockNode) = .empty,
    output: ast.Document = .{
        .blocks = &.{},
        .link_defs = .{},
        .has_trailing_newline = false,
    },

    const State = enum {
        building,
        finished,
    };

    pub fn init(allocator: std.mem.Allocator) RenderFixture {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *RenderFixture) void {
        switch (self.state) {
            .building => {
                if (self.arena) |*arena| arena.deinit();
            },
            .finished => self.output.deinit(),
        }

        self.* = undefined;
    }

    pub fn appendBlock(
        self: *RenderFixture,
        block: ast.BlockNode,
    ) (FixtureError || std.mem.Allocator.Error)!void {
        const allocator = try self.buildingAllocator();
        try self.blocks.append(allocator, block);
    }

    pub fn appendInlineNode(
        self: *RenderFixture,
        node: ast.InlineNode,
    ) (FixtureError || std.mem.Allocator.Error)!ast.InlineRef {
        const allocator = try self.buildingAllocator();
        const ref = std.math.cast(ast.InlineRef, self.inline_nodes.items.len) orelse return error.Overflow;
        try self.inline_nodes.append(allocator, node);
        try self.inline_next.append(allocator, ast.no_inline);
        return ref;
    }

    pub fn chain(
        self: *RenderFixture,
        refs: []const ast.InlineRef,
    ) FixtureError!ast.InlineRef {
        _ = try self.buildingAllocator();
        if (refs.len == 0) return ast.no_inline;

        for (refs[0 .. refs.len - 1], refs[1..]) |current, next| {
            self.inline_next.items[@intCast(current)] = next;
        }
        self.inline_next.items[@intCast(refs[refs.len - 1])] = ast.no_inline;
        return refs[0];
    }

    pub fn dupe(
        self: *RenderFixture,
        comptime T: type,
        items: []const T,
    ) (FixtureError || std.mem.Allocator.Error)![]T {
        const allocator = try self.buildingAllocator();
        return try allocator.dupe(T, items);
    }

    pub fn dupeString(
        self: *RenderFixture,
        value: []const u8,
    ) (FixtureError || std.mem.Allocator.Error)![]const u8 {
        return try self.dupe(u8, value);
    }

    pub fn text(
        self: *RenderFixture,
        value: []const u8,
    ) (FixtureError || std.mem.Allocator.Error)!ast.InlineRef {
        return self.appendInlineNode(.{ .text = try self.dupeString(value) });
    }

    pub fn codeSpan(
        self: *RenderFixture,
        value: []const u8,
    ) (FixtureError || std.mem.Allocator.Error)!ast.InlineRef {
        return self.appendInlineNode(.{ .code_span = try self.dupeString(value) });
    }

    pub fn autolink(
        self: *RenderFixture,
        value: []const u8,
    ) (FixtureError || std.mem.Allocator.Error)!ast.InlineRef {
        return self.appendInlineNode(.{ .autolink = try self.dupeString(value) });
    }

    pub fn softBreak(self: *RenderFixture) (FixtureError || std.mem.Allocator.Error)!ast.InlineRef {
        return self.appendInlineNode(.{ .soft_break = {} });
    }

    pub fn hardBreak(self: *RenderFixture) (FixtureError || std.mem.Allocator.Error)!ast.InlineRef {
        return self.appendInlineNode(.{ .hard_break = {} });
    }

    pub fn emphasis(
        self: *RenderFixture,
        children: ast.InlineRef,
    ) (FixtureError || std.mem.Allocator.Error)!ast.InlineRef {
        return self.appendInlineNode(.{ .emphasis = children });
    }

    pub fn strong(
        self: *RenderFixture,
        children: ast.InlineRef,
    ) (FixtureError || std.mem.Allocator.Error)!ast.InlineRef {
        return self.appendInlineNode(.{ .strong = children });
    }

    pub fn boldItalic(
        self: *RenderFixture,
        children: ast.InlineRef,
    ) (FixtureError || std.mem.Allocator.Error)!ast.InlineRef {
        return self.appendInlineNode(.{ .bold_italic = children });
    }

    pub fn strikethrough(
        self: *RenderFixture,
        children: ast.InlineRef,
    ) (FixtureError || std.mem.Allocator.Error)!ast.InlineRef {
        return self.appendInlineNode(.{ .strikethrough = children });
    }

    pub fn link(
        self: *RenderFixture,
        url: []const u8,
        title: ?[]const u8,
        children: ast.InlineRef,
    ) (FixtureError || std.mem.Allocator.Error)!ast.InlineRef {
        return self.appendInlineNode(.{
            .link = .{
                .url = try self.dupeString(url),
                .title = if (title) |value| try self.dupeString(value) else null,
                .children = children,
            },
        });
    }

    pub fn image(
        self: *RenderFixture,
        url: []const u8,
        title: ?[]const u8,
        children: ast.InlineRef,
    ) (FixtureError || std.mem.Allocator.Error)!ast.InlineRef {
        return self.appendInlineNode(.{
            .image = .{
                .url = try self.dupeString(url),
                .title = if (title) |value| try self.dupeString(value) else null,
                .children = children,
            },
        });
    }

    pub fn paragraph(children: ast.InlineRef) ast.BlockNode {
        return .{ .paragraph = .{ .children = children } };
    }

    pub fn heading(level: u8, children: ast.InlineRef) ast.BlockNode {
        return .{ .heading = .{ .level = level, .children = children } };
    }

    pub fn codeFence(
        self: *RenderFixture,
        opener: []const u8,
        closer: ?[]const u8,
        language: []const u8,
        content: []const u8,
    ) (FixtureError || std.mem.Allocator.Error)!ast.BlockNode {
        return .{
            .code_fence = .{
                .opener = try self.dupeString(opener),
                .closer = if (closer) |value| try self.dupeString(value) else null,
                .language = try self.dupeString(language),
                .content = try self.dupeString(content),
            },
        };
    }

    pub fn tableCell(children: ast.InlineRef) ast.TableCell {
        return .{ .children = children };
    }

    pub fn blockQuote(
        self: *RenderFixture,
        indent: usize,
        blocks: []const ast.BlockNode,
    ) (FixtureError || std.mem.Allocator.Error)!ast.BlockNode {
        return .{
            .blockquote = .{
                .indent = indent,
                .blocks = try self.dupe(ast.BlockNode, blocks),
            },
        };
    }

    pub fn listItem(
        self: *RenderFixture,
        indent: usize,
        marker: u8,
        number: ?[]const u8,
        checked: ?bool,
        blocks: []const ast.BlockNode,
    ) (FixtureError || std.mem.Allocator.Error)!ast.ListItem {
        return .{
            .indent = indent,
            .marker = marker,
            .number = if (number) |value| try self.dupeString(value) else null,
            .checked = checked,
            .blocks = try self.dupe(ast.BlockNode, blocks),
        };
    }

    pub fn unorderedList(
        self: *RenderFixture,
        items: []const ast.ListItem,
    ) (FixtureError || std.mem.Allocator.Error)!ast.BlockNode {
        return self.unorderedListWithLoose(items, false);
    }

    pub fn unorderedListWithLoose(
        self: *RenderFixture,
        items: []const ast.ListItem,
        loose: bool,
    ) (FixtureError || std.mem.Allocator.Error)!ast.BlockNode {
        return .{
            .list = .{
                .kind = .unordered,
                .items = try self.dupe(ast.ListItem, items),
                .loose = loose,
            },
        };
    }

    pub fn orderedList(
        self: *RenderFixture,
        items: []const ast.ListItem,
    ) (FixtureError || std.mem.Allocator.Error)!ast.BlockNode {
        return self.orderedListWithLoose(items, false);
    }

    pub fn orderedListWithLoose(
        self: *RenderFixture,
        items: []const ast.ListItem,
        loose: bool,
    ) (FixtureError || std.mem.Allocator.Error)!ast.BlockNode {
        return .{
            .list = .{
                .kind = .ordered,
                .items = try self.dupe(ast.ListItem, items),
                .loose = loose,
            },
        };
    }

    pub fn table(
        self: *RenderFixture,
        header: []const ast.TableCell,
        alignments: []const ast.Alignment,
        rows: []const []const ast.TableCell,
    ) (FixtureError || std.mem.Allocator.Error)!ast.BlockNode {
        const allocator = try self.buildingAllocator();
        var owned_rows = try allocator.alloc([]ast.TableCell, rows.len);
        errdefer allocator.free(owned_rows);

        for (rows, 0..) |row, index| {
            owned_rows[index] = try self.dupe(ast.TableCell, row);
        }

        return .{
            .table = .{
                .header = try self.dupe(ast.TableCell, header),
                .alignments = try self.dupe(ast.Alignment, alignments),
                .rows = owned_rows,
            },
        };
    }

    pub fn finish(
        self: *RenderFixture,
        has_trailing_newline: bool,
    ) (FixtureError || std.mem.Allocator.Error)!void {
        const allocator = try self.buildingAllocator();

        const inline_nodes = try self.inline_nodes.toOwnedSlice(allocator);
        const inline_next = try self.inline_next.toOwnedSlice(allocator);
        const blocks = try self.blocks.toOwnedSlice(allocator);

        const arena = self.arena.?;
        self.arena = null;

        self.output = .{
            .source = "",
            .source_storage = .borrowed,
            .inline_nodes = inline_nodes,
            .inline_next = inline_next,
            .blocks = blocks,
            .link_defs = .{},
            .has_trailing_newline = has_trailing_newline,
            .storage = .{ .arena = arena },
        };
        self.state = .finished;
    }

    pub fn document(self: *const RenderFixture) FixtureError!*const ast.Document {
        if (self.state != .finished) return error.FixtureNotFinished;
        return &self.output;
    }

    fn buildingAllocator(
        self: *RenderFixture,
    ) FixtureError!std.mem.Allocator {
        if (self.state != .building) return error.FixtureAlreadyFinished;
        return self.arena.?.allocator();
    }
};

pub const TestRenderOptions = struct {
    enable_ansi: bool = false,
    wrap_width: ?usize = null,
    ambiguous_width: width.AmbiguousWidth = .narrow,
};

pub fn renderDocumentToOwnedSlice(
    allocator: std.mem.Allocator,
    parse_output: *const ast.Document,
    opts: TestRenderOptions,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var renderer = render.Renderer.init(allocator, .{
        .enable_ansi = opts.enable_ansi,
        .ambiguous_width = opts.ambiguous_width,
    });
    defer renderer.deinit();
    try renderer.render(&output.writer, parse_output, opts.wrap_width);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

test "RenderFixture document is unavailable before finish" {
    var fixture = RenderFixture.init(std.testing.allocator);
    defer fixture.deinit();

    try std.testing.expectError(error.FixtureNotFinished, fixture.document());
}

test "RenderFixture append APIs reject calls after finish" {
    var fixture = RenderFixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.finish(false);

    try std.testing.expectError(error.FixtureAlreadyFinished, fixture.appendInlineNode(.{ .text = "x" }));
    try std.testing.expectError(error.FixtureAlreadyFinished, fixture.appendBlock(.{ .blank_line = {} }));
    try std.testing.expectError(error.FixtureAlreadyFinished, fixture.finish(false));
}

test "RenderFixture supports empty inline chains via ast.no_inline" {
    var fixture = RenderFixture.init(std.testing.allocator);
    defer fixture.deinit();

    try fixture.appendBlock(.{ .paragraph = .{ .children = ast.no_inline } });
    try fixture.finish(false);

    const rendered = try fixture.document();
    try std.testing.expectEqual(@as(usize, 0), rendered.inline_nodes.len);
    try std.testing.expectEqual(ast.no_inline, rendered.blocks[0].paragraph.children);
}
