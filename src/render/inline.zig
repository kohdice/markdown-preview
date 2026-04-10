const std = @import("std");
const ansi = @import("../term/ansi.zig");
const ast = @import("../ast.zig");
const text = @import("../text.zig");
const theme = @import("../term/theme.zig");
const parse_inline = @import("../parse/inline.zig");

const DefMap = ast.LinkDefMap;
const InlineSegment = parse_inline.InlineSegment;

const link_url_open = "(";
const link_url_close = ")";
const link_title_separator = " — ";
const image_alt_prefix = "[img: ";
const image_alt_suffix = "]";

pub fn write(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    content: []const u8,
    enable_ansi: bool,
    base_style: ansi.TextStyle,
    palette: theme.Palette,
    link_defs: *const DefMap,
) !void {
    var segments: std.ArrayListUnmanaged(InlineSegment) = .{};
    defer segments.deinit(allocator);

    try parse_inline.segments(allocator, content, &segments, link_defs);

    for (segments.items) |seg| {
        switch (seg.kind) {
            .text => try writeTextWithEntities(writer, enable_ansi, base_style, seg.content),
            .code_span => try ansi.writeStyled(writer, enable_ansi, .{ .fg = palette.inline_code }, seg.content),
            .link_text => try write(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .fg = palette.link, .underline = true }), palette, link_defs),
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
                try write(allocator, writer, seg.content, enable_ansi, img_style, palette, link_defs);
                try ansi.writeStyled(writer, enable_ansi, img_style, image_alt_suffix);
            },
            .image_url => {
                const muted_dim: ansi.TextStyle = .{ .fg = palette.muted, .dim = true };
                try ansi.writeStyled(writer, enable_ansi, muted_dim, link_url_open);
                try ansi.writeStyled(writer, enable_ansi, muted_dim, seg.content);
                try ansi.writeStyled(writer, enable_ansi, muted_dim, link_url_close);
            },
            .emphasis => try write(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .italic = true }), palette, link_defs),
            .strong => try write(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .bold = true }), palette, link_defs),
            .bold_italic => try write(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .bold = true, .italic = true }), palette, link_defs),
            .strikethrough => try write(allocator, writer, seg.content, enable_ansi, base_style.merge(.{ .strikethrough = true }), palette, link_defs),
        }
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
