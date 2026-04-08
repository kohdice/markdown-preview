const std = @import("std");
const ansi = @import("ansi.zig");
const theme = @import("theme.zig");
const width = @import("width.zig");
const block_ast = @import("block_ast.zig");
const parse_block = @import("parse_block.zig");
const parse_link = @import("parse_link.zig");
const render_inline = @import("render_inline.zig");
const render_table = @import("render_table.zig");
const highlight = @import("highlight.zig");

const LinkDefMap = parse_link.LinkDefMap;

const thematic_break_width = 32;
const thematic_break_display = "-" ** thematic_break_width;

const list_bullet = struct {
    const level0 = "• ";
    const level1 = "◦ ";
    const level2 = "▪ ";
};

fn bulletForDepth(depth: usize) []const u8 {
    return switch (depth % 3) {
        0 => list_bullet.level0,
        1 => list_bullet.level1,
        2 => list_bullet.level2,
        else => unreachable,
    };
}

pub const RenderContext = struct {
    allocator: std.mem.Allocator,
    enable_ansi: bool,
    wrap_width: ?usize,
    palette: theme.Palette,
    syn_palette: theme.SyntaxPalette,
    highlighter: *highlight.Highlighter,
    link_defs: *const LinkDefMap,
};

pub fn renderDocument(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    doc: block_ast.Document,
    enable_ansi: bool,
    wrap_width: ?usize,
    palette: theme.Palette,
    syn_palette: theme.SyntaxPalette,
) !void {
    var highlighter = highlight.Highlighter.init();
    defer highlighter.deinit();

    const ctx: RenderContext = .{
        .allocator = allocator,
        .enable_ansi = enable_ansi,
        .wrap_width = wrap_width,
        .palette = palette,
        .syn_palette = syn_palette,
        .highlighter = &highlighter,
        .link_defs = &doc.link_defs,
    };

    try renderBlocks(writer, doc.blocks, ctx);

    if (doc.has_trailing_newline) try writer.writeByte('\n');
}

fn renderBlocks(
    writer: *std.io.Writer,
    blocks: []const block_ast.BlockNode,
    ctx: RenderContext,
) !void {
    for (blocks, 0..) |block, i| {
        if (i > 0) try writer.writeByte('\n');
        try renderBlock(writer, block, ctx, 0);
    }
}

fn renderBlock(
    writer: *std.io.Writer,
    block: block_ast.BlockNode,
    ctx: RenderContext,
    depth: usize,
) anyerror!void {
    switch (block) {
        .paragraph => |p| try renderParagraph(writer, p, ctx),
        .heading => |h| try renderHeading(writer, h, ctx),
        .blockquote => |bq| try renderBlockQuote(writer, bq, ctx, depth),
        .list => |l| try renderList(writer, l, ctx, depth),
        .code_fence => |cf| try renderCodeFence(writer, cf, ctx),
        .thematic_break => try renderThematicBreak(writer, ctx),
        .table => |t| try render_table.renderTableNode(
            writer,
            t,
            ctx.allocator,
            ctx.enable_ansi,
            ctx.palette,
            ctx.link_defs,
            .top_level,
        ),
        .blank_line => {},
    }
}

fn renderParagraph(
    writer: *std.io.Writer,
    paragraph: block_ast.Paragraph,
    ctx: RenderContext,
) !void {
    for (paragraph.lines, 0..) |line, i| {
        if (i > 0) try writer.writeByte('\n');
        const stripped = parse_block.stripHardBreak(line);
        try renderInlineMaybeWrap(writer, stripped, ctx, .{ .fg = ctx.palette.body });
    }
}

fn renderInlineMaybeWrap(
    writer: *std.io.Writer,
    text: []const u8,
    ctx: RenderContext,
    base_style: ansi.TextStyle,
) !void {
    if (ctx.wrap_width) |wrap_w| {
        var buf: std.io.Writer.Allocating = .init(ctx.allocator);
        defer buf.deinit();
        try render_inline.renderInline(
            ctx.allocator,
            &buf.writer,
            text,
            ctx.enable_ansi,
            base_style,
            ctx.palette,
            ctx.link_defs,
        );
        var list = buf.toArrayList();
        defer list.deinit(ctx.allocator);
        const rendered = try list.toOwnedSlice(ctx.allocator);
        defer ctx.allocator.free(rendered);
        const wrapped = try width.wrapText(ctx.allocator, rendered, wrap_w);
        defer ctx.allocator.free(wrapped);
        try writer.writeAll(wrapped);
    } else {
        try render_inline.renderInline(
            ctx.allocator,
            writer,
            text,
            ctx.enable_ansi,
            base_style,
            ctx.palette,
            ctx.link_defs,
        );
    }
}

fn renderHeading(
    writer: *std.io.Writer,
    heading: block_ast.Heading,
    ctx: RenderContext,
) !void {
    const stripped = parse_block.stripHardBreak(heading.content);
    try render_inline.renderInline(
        ctx.allocator,
        writer,
        stripped,
        ctx.enable_ansi,
        headingStyle(heading.level, ctx.palette),
        ctx.palette,
        ctx.link_defs,
    );
}

fn headingStyle(level: u8, p: theme.Palette) ansi.TextStyle {
    const color = p.heading_colors[level - 1];
    return switch (level) {
        1, 2 => .{ .fg = color, .bold = true, .underline = true },
        3, 4 => .{ .fg = color, .bold = true },
        5 => .{ .fg = color },
        6 => .{ .fg = color, .dim = true },
        else => unreachable,
    };
}

fn renderThematicBreak(writer: *std.io.Writer, ctx: RenderContext) !void {
    try ansi.writeStyled(writer, ctx.enable_ansi, .{
        .fg = ctx.palette.subtle,
        .dim = true,
    }, thematic_break_display);
}

fn renderBlockQuote(
    writer: *std.io.Writer,
    bq: block_ast.BlockQuote,
    ctx: RenderContext,
    depth: usize,
) anyerror!void {
    var buf: std.io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();

    var child_ctx = ctx;
    child_ctx.wrap_width = null;

    try renderBlocksInBlockQuote(&buf.writer, bq.blocks, child_ctx, depth);

    var list = buf.toArrayList();
    defer list.deinit(ctx.allocator);
    const rendered = try list.toOwnedSlice(ctx.allocator);
    defer ctx.allocator.free(rendered);

    const gutter_style: ansi.TextStyle = .{ .fg = ctx.palette.muted, .dim = true };

    var it = std.mem.splitScalar(u8, rendered, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;
        try writer.splatByteAll(' ', bq.indent);
        try ansi.writeStyled(writer, ctx.enable_ansi, gutter_style, render_inline.blockquote_marker);
        try writer.writeAll(line);
    }
}

fn renderBlocksInBlockQuote(
    writer: *std.io.Writer,
    blocks: []const block_ast.BlockNode,
    ctx: RenderContext,
    depth: usize,
) anyerror!void {
    for (blocks, 0..) |block, i| {
        if (i > 0) try writer.writeByte('\n');
        switch (block) {
            .paragraph => |p| try renderBlockQuoteParagraph(writer, p, ctx),
            .blockquote => |inner| try renderBlockQuote(writer, inner, ctx, depth),
            .table => |t| try render_table.renderTableNode(
                writer,
                t,
                ctx.allocator,
                ctx.enable_ansi,
                ctx.palette,
                ctx.link_defs,
                .in_blockquote,
            ),
            else => try renderBlock(writer, block, ctx, depth),
        }
    }
}

fn renderBlockQuoteParagraph(
    writer: *std.io.Writer,
    paragraph: block_ast.Paragraph,
    ctx: RenderContext,
) !void {
    for (paragraph.lines, 0..) |line, i| {
        if (i > 0) try writer.writeByte('\n');
        const stripped = parse_block.stripHardBreak(line);
        try render_inline.renderInline(
            ctx.allocator,
            writer,
            stripped,
            ctx.enable_ansi,
            .{ .fg = ctx.palette.muted },
            ctx.palette,
            ctx.link_defs,
        );
    }
}

fn renderList(
    writer: *std.io.Writer,
    list: block_ast.List,
    ctx: RenderContext,
    depth: usize,
) anyerror!void {
    for (list.items, 0..) |item, i| {
        if (i > 0) try writer.writeByte('\n');
        try renderListItem(writer, item, ctx, depth);
    }
}

fn renderListItem(
    writer: *std.io.Writer,
    item: block_ast.ListItem,
    ctx: RenderContext,
    depth: usize,
) anyerror!void {
    try writer.splatByteAll(' ', item.indent);

    const marker_style: ansi.TextStyle = .{
        .fg = ctx.palette.list_marker,
        .bold = true,
    };

    const content_col = blk: {
        if (item.number) |number| {
            try ansi.writeStyled(writer, ctx.enable_ansi, marker_style, number);
            const marker_buf: [2]u8 = .{ item.marker, ' ' };
            try ansi.writeStyled(writer, ctx.enable_ansi, marker_style, &marker_buf);
            break :blk item.indent + width.displayWidth(number) + width.displayWidth(&marker_buf);
        } else {
            const marker_text = bulletForDepth(depth);
            try ansi.writeStyled(writer, ctx.enable_ansi, marker_style, marker_text);
            break :blk item.indent + width.displayWidth(marker_text);
        }
    };

    try render_inline.renderCheckbox(writer, item.checked, ctx.enable_ansi, ctx.palette);

    for (item.blocks, 0..) |child, ci| {
        if (ci > 0) try writer.writeByte('\n');
        switch (child) {
            .paragraph => |p| {
                if (ci > 0) try writer.splatByteAll(' ', content_col);
                try renderListItemParagraph(writer, p, ctx, content_col);
            },
            .list => |nested| try renderList(writer, nested, ctx, depth + 1),
            .blockquote => |bq| try renderBlockQuote(writer, bq, ctx, depth + 1),
            .blank_line => try renderBlock(writer, child, ctx, depth),
            else => {
                if (ci > 0) {
                    try renderListChildIndented(writer, child, ctx, content_col, depth);
                } else {
                    try renderBlock(writer, child, ctx, depth);
                }
            },
        }
    }
}

fn renderListChildIndented(
    writer: *std.io.Writer,
    child: block_ast.BlockNode,
    ctx: RenderContext,
    indent: usize,
    depth: usize,
) anyerror!void {
    if (indent == 0) return renderBlock(writer, child, ctx, depth);

    var buf: std.io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();

    try renderBlock(&buf.writer, child, ctx, depth);

    var list = buf.toArrayList();
    defer list.deinit(ctx.allocator);
    const rendered = try list.toOwnedSlice(ctx.allocator);
    defer ctx.allocator.free(rendered);

    var it = std.mem.splitScalar(u8, rendered, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try writer.writeByte('\n');
        first = false;
        try writer.splatByteAll(' ', indent);
        try writer.writeAll(line);
    }
}

fn renderListItemParagraph(
    writer: *std.io.Writer,
    paragraph: block_ast.Paragraph,
    ctx: RenderContext,
    content_col: usize,
) !void {
    for (paragraph.lines, 0..) |line, i| {
        if (i > 0) {
            try writer.writeByte('\n');
            try writer.splatByteAll(' ', content_col);
        }
        const stripped = parse_block.stripHardBreak(line);
        try render_inline.renderInline(
            ctx.allocator,
            writer,
            stripped,
            ctx.enable_ansi,
            .{ .fg = ctx.palette.body },
            ctx.palette,
            ctx.link_defs,
        );
    }
}

fn renderCodeFence(
    writer: *std.io.Writer,
    cf: block_ast.CodeFence,
    ctx: RenderContext,
) !void {
    const fence_style: ansi.TextStyle = .{ .fg = ctx.palette.code_fence, .dim = true };

    try ansi.writeStyled(writer, ctx.enable_ansi, fence_style, cf.opener);

    const language = highlight.Language.fromString(cf.language);

    if (cf.content.len > 0) {
        try writer.writeByte('\n');
        try writeFenceBody(writer, cf.content, language, ctx);
    }

    if (cf.closer) |closer| {
        try writer.writeByte('\n');
        try ansi.writeStyled(writer, ctx.enable_ansi, fence_style, closer);
    }
}

fn writeFenceBody(
    writer: *std.io.Writer,
    content: []const u8,
    language: ?highlight.Language,
    ctx: RenderContext,
) !void {
    if (language) |lang| {
        if (ctx.enable_ansi) {
            ctx.highlighter.writeHighlightedBlock(
                ctx.allocator,
                writer,
                content,
                lang,
                ctx.syn_palette,
            ) catch |err| switch (err) {
                error.QueryUnavailable => {
                    try ansi.writeStyled(writer, true, .{ .fg = ctx.palette.inline_code }, content);
                },
                else => return err,
            };
        } else {
            try ansi.writeStyled(writer, false, .{}, content);
        }
    } else {
        try ansi.writeStyled(writer, ctx.enable_ansi, .{
            .fg = ctx.palette.inline_code,
        }, content);
    }
}

test "renderDocument compile-check smoke" {
    const allocator = std.testing.allocator;
    const parse_document = @import("parse_document.zig");

    var doc = try parse_document.parseDocument(allocator, "# Hello\n");
    defer doc.deinit(allocator);

    var buf: std.io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    try renderDocument(
        allocator,
        &buf.writer,
        doc,
        false,
        null,
        theme.palette(.solarized_dark),
        theme.syntaxPalette(.solarized_dark),
    );

    try std.testing.expectEqualStrings("Hello\n", buf.writer.buffered());
}
