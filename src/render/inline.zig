const std = @import("std");
const ansi = @import("../term/ansi.zig");
const ast = @import("../ast.zig");
const text = @import("../text.zig");
const theme = @import("../term/theme.zig");
const render_context = @import("context.zig");
const RenderContext = render_context.RenderContext;

pub const link_url_open = "(";
pub const link_url_close = ")";
pub const link_title_separator = " — ";
pub const image_alt_prefix = "[img: ";
pub const image_alt_suffix = "]";

pub fn traverseInlineChain(
    comptime Visitor: type,
    visitor: *Visitor,
    doc: *const ast.Document,
    first: ast.InlineRef,
) anyerror!void {
    var current = first;
    while (ast.hasInline(current)) {
        const node = doc.inlineNode(current).*;
        switch (node) {
            .text => |content| try visitor.onText(content),
            .code_span => |content| try visitor.onCodeSpan(content),
            .autolink => |url| try visitor.onAutolink(url),
            .soft_break => try visitor.onSoftBreak(),
            .hard_break => try visitor.onHardBreak(),
            .emphasis => |children| try visitor.onContainer(.emphasis, doc, children),
            .strong => |children| try visitor.onContainer(.strong, doc, children),
            .bold_italic => |children| try visitor.onContainer(.bold_italic, doc, children),
            .strikethrough => |children| try visitor.onContainer(.strikethrough, doc, children),
            .link => |link| try visitor.onLink(doc, link),
            .image => |img| try visitor.onImage(doc, img),
        }
        current = doc.inlineNext(current);
    }
}

pub const ContainerKind = enum {
    emphasis,
    strong,
    bold_italic,
    strikethrough,
};

const WriteVisitor = struct {
    ctx: RenderContext,
    writer: *std.io.Writer,
    current_style: ansi.TextStyle,

    pub fn onText(self: *WriteVisitor, content: []const u8) anyerror!void {
        try writeTextWithEntities(self.writer, self.ctx.enable_ansi, self.current_style, content);
    }

    pub fn onCodeSpan(self: *WriteVisitor, content: []const u8) anyerror!void {
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, .{ .fg = self.ctx.palette.inline_code }, content);
    }

    pub fn onAutolink(self: *WriteVisitor, url: []const u8) anyerror!void {
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, self.current_style.merge(.{ .fg = self.ctx.palette.link, .underline = true }), url);
    }

    pub fn onSoftBreak(self: *WriteVisitor) anyerror!void {
        try self.writer.writeByte('\n');
    }

    pub fn onHardBreak(self: *WriteVisitor) anyerror!void {
        try self.writer.writeByte('\n');
    }

    pub fn onContainer(self: *WriteVisitor, kind: ContainerKind, doc: *const ast.Document, children: ast.InlineRef) anyerror!void {
        const saved = self.current_style;
        self.current_style = self.current_style.merge(switch (kind) {
            .emphasis => ansi.TextStyle{ .italic = true },
            .strong => ansi.TextStyle{ .bold = true },
            .bold_italic => ansi.TextStyle{ .bold = true, .italic = true },
            .strikethrough => ansi.TextStyle{ .strikethrough = true },
        });
        try traverseInlineChain(WriteVisitor, self, doc, children);
        self.current_style = saved;
    }

    pub fn onLink(self: *WriteVisitor, doc: *const ast.Document, link: ast.LinkInline) anyerror!void {
        const saved = self.current_style;
        self.current_style = self.current_style.merge(.{ .fg = self.ctx.palette.link, .underline = true });
        try traverseInlineChain(WriteVisitor, self, doc, link.children);
        self.current_style = saved;

        const muted_dim: ansi.TextStyle = .{ .fg = self.ctx.palette.muted, .dim = true };
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, muted_dim, link_url_open);
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, muted_dim, link.url);
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, muted_dim, link_url_close);
        if (link.title) |t| {
            const title_style: ansi.TextStyle = .{ .fg = self.ctx.palette.muted, .dim = true, .italic = true };
            try ansi.writeStyled(self.writer, self.ctx.enable_ansi, title_style, link_title_separator);
            try ansi.writeStyled(self.writer, self.ctx.enable_ansi, title_style, t);
        }
    }

    pub fn onImage(self: *WriteVisitor, doc: *const ast.Document, img: ast.ImageInline) anyerror!void {
        const img_style: ansi.TextStyle = .{ .fg = self.ctx.palette.muted, .italic = true };
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, img_style, image_alt_prefix);

        const saved = self.current_style;
        self.current_style = img_style;
        try traverseInlineChain(WriteVisitor, self, doc, img.children);
        self.current_style = saved;

        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, img_style, image_alt_suffix);
        const muted_dim: ansi.TextStyle = .{ .fg = self.ctx.palette.muted, .dim = true };
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, muted_dim, link_url_open);
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, muted_dim, img.url);
        try ansi.writeStyled(self.writer, self.ctx.enable_ansi, muted_dim, link_url_close);
        if (img.title) |t| {
            const title_style: ansi.TextStyle = .{ .fg = self.ctx.palette.muted, .dim = true, .italic = true };
            try ansi.writeStyled(self.writer, self.ctx.enable_ansi, title_style, link_title_separator);
            try ansi.writeStyled(self.writer, self.ctx.enable_ansi, title_style, t);
        }
    }
};

pub fn writeInlineChain(
    ctx: RenderContext,
    writer: *std.io.Writer,
    first: ast.InlineRef,
    base_style: ansi.TextStyle,
) !void {
    var visitor = WriteVisitor{
        .ctx = ctx,
        .writer = writer,
        .current_style = base_style,
    };
    try traverseInlineChain(WriteVisitor, &visitor, ctx.doc, first);
}

fn writeTextWithEntities(
    writer: *std.io.Writer,
    enable_ansi: bool,
    style: ansi.TextStyle,
    content: []const u8,
) !void {
    var pos: usize = 0;
    var plain_start: usize = 0;

    while (pos < content.len) {
        if (content[pos] == '&') {
            if (text.decode(content, pos)) |result| {
                if (plain_start < pos)
                    try ansi.writeStyled(writer, enable_ansi, style, content[plain_start..pos]);
                try ansi.writeStyled(writer, enable_ansi, style, result.bytes[0..result.len]);
                pos = result.end;
                plain_start = pos;
                continue;
            }
        }
        pos += 1;
    }

    if (plain_start < content.len)
        try ansi.writeStyled(writer, enable_ansi, style, content[plain_start..]);
}
