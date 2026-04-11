const std = @import("std");
const ansi = @import("../term/ansi.zig");
const ast = @import("../ast.zig");
const text = @import("../text.zig");
const theme = @import("../term/theme.zig");

pub const link_url_open = "(";
pub const link_url_close = ")";
pub const link_title_separator = " — ";
pub const image_alt_prefix = "[img: ";
pub const image_alt_suffix = "]";

pub fn writeInlineChain(
    writer: *std.io.Writer,
    doc: *const ast.Document,
    first: ast.InlineRef,
    enable_ansi: bool,
    base_style: ansi.TextStyle,
    palette: theme.Palette,
) !void {
    var current = first;
    while (ast.hasInline(current)) {
        const inline_node = doc.inlineNode(current).*;
        switch (inline_node) {
            .text => |content| try writeTextWithEntities(writer, enable_ansi, base_style, content),
            .code_span => |content| try ansi.writeStyled(writer, enable_ansi, .{ .fg = palette.inline_code }, content),
            .autolink => |url| try ansi.writeStyled(writer, enable_ansi, base_style.merge(.{ .fg = palette.link, .underline = true }), url),
            .soft_break => try writer.writeByte('\n'),
            .hard_break => try writer.writeByte('\n'),
            .emphasis => |children| try writeInlineChain(writer, doc, children, enable_ansi, base_style.merge(.{ .italic = true }), palette),
            .strong => |children| try writeInlineChain(writer, doc, children, enable_ansi, base_style.merge(.{ .bold = true }), palette),
            .bold_italic => |children| try writeInlineChain(writer, doc, children, enable_ansi, base_style.merge(.{ .bold = true, .italic = true }), palette),
            .strikethrough => |children| try writeInlineChain(writer, doc, children, enable_ansi, base_style.merge(.{ .strikethrough = true }), palette),
            .link => |link| {
                try writeInlineChain(writer, doc, link.children, enable_ansi, base_style.merge(.{ .fg = palette.link, .underline = true }), palette);
                const muted_dim: ansi.TextStyle = .{ .fg = palette.muted, .dim = true };
                try ansi.writeStyled(writer, enable_ansi, muted_dim, link_url_open);
                try ansi.writeStyled(writer, enable_ansi, muted_dim, link.url);
                try ansi.writeStyled(writer, enable_ansi, muted_dim, link_url_close);
                if (link.title) |t| {
                    const title_style: ansi.TextStyle = .{ .fg = palette.muted, .dim = true, .italic = true };
                    try ansi.writeStyled(writer, enable_ansi, title_style, link_title_separator);
                    try ansi.writeStyled(writer, enable_ansi, title_style, t);
                }
            },
            .image => |img| {
                const img_style: ansi.TextStyle = .{ .fg = palette.muted, .italic = true };
                try ansi.writeStyled(writer, enable_ansi, img_style, image_alt_prefix);
                try writeInlineChain(writer, doc, img.children, enable_ansi, img_style, palette);
                try ansi.writeStyled(writer, enable_ansi, img_style, image_alt_suffix);
                const muted_dim: ansi.TextStyle = .{ .fg = palette.muted, .dim = true };
                try ansi.writeStyled(writer, enable_ansi, muted_dim, link_url_open);
                try ansi.writeStyled(writer, enable_ansi, muted_dim, img.url);
                try ansi.writeStyled(writer, enable_ansi, muted_dim, link_url_close);
                if (img.title) |t| {
                    const title_style: ansi.TextStyle = .{ .fg = palette.muted, .dim = true, .italic = true };
                    try ansi.writeStyled(writer, enable_ansi, title_style, link_title_separator);
                    try ansi.writeStyled(writer, enable_ansi, title_style, t);
                }
            },
        }
        current = doc.inlineNext(current);
    }
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
