const std = @import("std");
const ansi = @import("ansi.zig");
const entity = @import("entity.zig");
const theme = @import("theme.zig");
const width_mod = @import("width.zig");
const parse_block = @import("parse_block.zig");
const parse_inline = @import("parse_inline.zig");
const parse_link = @import("parse_link.zig");

const LinkDefMap = parse_link.LinkDefMap;
const InlineSegment = parse_inline.InlineSegment;

const link_url_open = "(";
const link_url_close = ")";
const link_title_separator = " — ";
const image_alt_prefix = "[img: ";
const image_alt_suffix = "]";
pub const blockquote_marker = "│ ";
const checkbox_checked = "☑ ";
const checkbox_unchecked = "☐ ";

pub fn renderInline(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    text: []const u8,
    enable_ansi: bool,
    base_style: ansi.TextStyle,
    palette: theme.Palette,
    link_defs: *const LinkDefMap,
) !void {
    var segments: std.ArrayListUnmanaged(InlineSegment) = .{};
    defer segments.deinit(allocator);

    try parse_inline.parseInlineSegments(allocator, text, &segments, link_defs);

    for (segments.items) |seg| {
        switch (seg.kind) {
            .text => try writeTextWithEntities(writer, enable_ansi, base_style, seg.content),
            .code_span => try ansi.writeStyled(writer, enable_ansi, .{ .fg = palette.inline_code }, seg.content),
            .link_text => try renderInline(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .fg = palette.link, .underline = true }), palette, link_defs),
            .link_url => {
                const muted_dim: ansi.TextStyle = .{ .fg = palette.muted, .dim = true };
                try ansi.writeStyled(writer, enable_ansi, muted_dim, link_url_open);
                try ansi.writeStyled(writer, enable_ansi, muted_dim, seg.content);
                try ansi.writeStyled(writer, enable_ansi, muted_dim, link_url_close);
            },
            .link_title => {
                const title_style: ansi.TextStyle = .{ .fg = palette.muted, .dim = true, .italic = true };
                try ansi.writeStyled(writer, enable_ansi, title_style, link_title_separator);
                try ansi.writeStyled(writer, enable_ansi, title_style, seg.content);
            },
            .autolink => {
                try ansi.writeStyled(writer, enable_ansi, base_style.merge(.{ .fg = palette.link, .underline = true }), seg.content);
            },
            .image_alt => {
                const img_style: ansi.TextStyle = .{ .fg = palette.muted, .italic = true };
                try ansi.writeStyled(writer, enable_ansi, img_style, image_alt_prefix);
                try renderInline(allocator, writer, seg.content, enable_ansi, img_style, palette, link_defs);
                try ansi.writeStyled(writer, enable_ansi, img_style, image_alt_suffix);
            },
            .image_url => {
                const muted_dim: ansi.TextStyle = .{ .fg = palette.muted, .dim = true };
                try ansi.writeStyled(writer, enable_ansi, muted_dim, link_url_open);
                try ansi.writeStyled(writer, enable_ansi, muted_dim, seg.content);
                try ansi.writeStyled(writer, enable_ansi, muted_dim, link_url_close);
            },
            .emphasis => try renderInline(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .italic = true }), palette, link_defs),
            .strong => try renderInline(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .bold = true }), palette, link_defs),
            .bold_italic => try renderInline(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .bold = true, .italic = true }), palette, link_defs),
            .strikethrough => try renderInline(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .strikethrough = true }), palette, link_defs),
        }
    }
}

pub fn renderCheckbox(
    writer: *std.io.Writer,
    checked: ?bool,
    enable_ansi: bool,
    palette: theme.Palette,
) !void {
    if (checked) |is_checked| {
        if (is_checked) {
            try ansi.writeStyled(writer, enable_ansi, .{
                .fg = palette.list_marker,
            }, checkbox_checked);
        } else {
            try ansi.writeStyled(writer, enable_ansi, .{
                .fg = palette.muted,
                .dim = true,
            }, checkbox_unchecked);
        }
    }
}

pub fn renderBlockQuoteContent(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    content: []const u8,
    enable_ansi: bool,
    palette: theme.Palette,
    link_defs: *const LinkDefMap,
) !void {
    try ansi.writeStyled(writer, enable_ansi, .{
        .fg = palette.muted,
        .dim = true,
    }, blockquote_marker);

    if (parse_block.parseBlockQuote(content)) |nested| {
        try writer.splatByteAll(' ', nested.indent);
        try renderBlockQuoteContent(allocator, writer, nested.content, enable_ansi, palette, link_defs);
    } else {
        try renderInline(allocator, writer, content, enable_ansi, .{
            .fg = palette.muted,
        }, palette, link_defs);
    }
}

pub fn writeTextWithEntities(
    writer: *std.io.Writer,
    enable_ansi: bool,
    style: ansi.TextStyle,
    text: []const u8,
) !void {
    var pos: usize = 0;
    var plain_start: usize = 0;

    while (pos < text.len) {
        if (text[pos] == '&') {
            if (entity.decode(text, pos)) |result| {
                if (plain_start < pos)
                    try ansi.writeStyled(writer, enable_ansi, style, text[plain_start..pos]);
                try ansi.writeStyled(writer, enable_ansi, style, result.bytes[0..result.len]);
                pos = result.end;
                plain_start = pos;
                continue;
            }
        }
        pos += 1;
    }

    if (plain_start < text.len)
        try ansi.writeStyled(writer, enable_ansi, style, text[plain_start..]);
}

pub fn renderedDisplayWidth(
    allocator: std.mem.Allocator,
    text: []const u8,
    palette: theme.Palette,
    link_defs: *const LinkDefMap,
    ambiguous: width_mod.AmbiguousWidth,
) !usize {
    var output: std.io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try renderInline(allocator, &output.writer, text, false, .{}, palette, link_defs);
    var list = output.toArrayList();
    const rendered = list.toOwnedSlice(allocator) catch return width_mod.displayWidth(text, ambiguous);
    defer allocator.free(rendered);
    return width_mod.displayWidth(rendered, ambiguous);
}

pub fn checkboxWidth(checked: ?bool, ambiguous: width_mod.AmbiguousWidth) usize {
    if (checked == null) return 0;
    const glyph = if (checked.?) checkbox_checked else checkbox_unchecked;
    return width_mod.displayWidth(glyph, ambiguous);
}
