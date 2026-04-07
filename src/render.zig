const std = @import("std");
const ansi = @import("ansi.zig");
const theme = @import("theme.zig");
const width = @import("width.zig");
const parse_block = @import("parse_block.zig");
const parse_link = @import("parse_link.zig");
const render_inline = @import("render_inline.zig");
const render_table = @import("render_table.zig");
const highlight = @import("highlight.zig");

/// Visible column width of a rendered thematic break. Short enough to fit
/// narrow terminals while still reading as a visual separator.
const thematic_break_width = 32;
const thematic_break_display = "-" ** thematic_break_width;

pub const RenderOptions = struct {
    enable_ansi: bool = false,
    theme: theme.Theme = .solarized_dark,
    wrap_width: ?usize = null,
};

pub fn renderMarkdown(allocator: std.mem.Allocator, writer: *std.io.Writer, input: []const u8, opts: RenderOptions) !void {
    if (input.len == 0) return;

    var link_defs = try parse_link.collectLinkDefinitions(allocator, input);
    defer {
        var it = link_defs.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        link_defs.deinit(allocator);
    }

    const palette = theme.palette(opts.theme);
    const syn_palette = theme.syntaxPalette(opts.theme);
    var active_fence: ?parse_block.Fence = null;
    var active_language: ?highlight.Language = null;
    var fence_buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer fence_buffer.deinit(allocator);
    var highlighter = highlight.Highlighter.init();
    defer highlighter.deinit();
    var line_start: usize = 0;
    var prev_was_blank: bool = false;

    while (line_start < input.len) {
        const line_end = std.mem.indexOfScalarPos(u8, input, line_start, '\n') orelse input.len;
        const has_newline = line_end < input.len;
        const raw_line = std.mem.trimEnd(u8, input[line_start..line_end], parse_block.carriage_return);

        if (active_fence) |fence| {
            if (parse_block.isClosingFence(raw_line, fence)) {
                try flushFenceBuffer(allocator, writer, &fence_buffer, active_language, &highlighter, opts, palette, syn_palette);
                try ansi.writeStyled(writer, opts.enable_ansi, .{
                    .fg = palette.code_fence,
                    .dim = true,
                }, raw_line);
                active_fence = null;
                active_language = null;
            } else {
                try fence_buffer.appendSlice(allocator, raw_line);
                if (has_newline) try fence_buffer.append(allocator, '\n');
                line_start = line_end + @intFromBool(has_newline);
                continue;
            }
        } else {
            const line = raw_line;

            if (parse_block.parseFence(line)) |fence| {
                active_fence = fence;
                active_language = highlight.Language.fromString(fence.language);
                try ansi.writeStyled(writer, opts.enable_ansi, .{
                    .fg = palette.code_fence,
                    .dim = true,
                }, line);
            } else if (std.mem.trim(u8, line, parse_block.horizontal_whitespace).len == 0) {
                if (!prev_was_blank) {
                    prev_was_blank = true;
                } else {
                    line_start = line_end + @intFromBool(has_newline);
                    continue;
                }
            } else if (parse_link.parseLinkDefinition(line) != null) {
                // Link definition lines are consumed in the first pass; skip in output
            } else if (parse_block.isThematicBreak(line)) {
                try ansi.writeStyled(writer, opts.enable_ansi, .{
                    .fg = palette.subtle,
                    .dim = true,
                }, thematic_break_display);
            } else if (try render_table.tryRenderTable(allocator, writer, input, line, line_end, opts.enable_ansi, palette, &link_defs)) |new_start| {
                prev_was_blank = false;
                line_start = new_start;
                continue;
            } else if (parse_block.parseHeading(line)) |heading| {
                try render_inline.renderInline(allocator, writer, parse_block.stripHardBreak(heading.content), opts.enable_ansi, headingStyle(heading.level, palette), palette, &link_defs);
            } else if (parse_block.parseBlockQuote(line)) |quote| {
                if (std.mem.indexOfScalar(u8, quote.content, '|') != null) {
                    if (try render_table.tryRenderBlockQuoteTable(allocator, writer, input, line_start, opts.enable_ansi, palette, &link_defs)) |new_start| {
                        prev_was_blank = false;
                        line_start = new_start;
                        continue;
                    }
                }
                try writer.splatByteAll(' ', quote.indent);
                try render_inline.renderBlockQuoteContent(allocator, writer, quote.content, opts.enable_ansi, palette, &link_defs);
            } else if (parse_block.parseOrderedListItem(line)) |ordered| {
                try writer.splatByteAll(' ', ordered.indent);
                try ansi.writeStyled(writer, opts.enable_ansi, .{
                    .fg = palette.list_marker,
                    .bold = true,
                }, ordered.number);
                const marker_buf: [2]u8 = .{ ordered.marker, ' ' };
                try ansi.writeStyled(writer, opts.enable_ansi, .{
                    .fg = palette.list_marker,
                    .bold = true,
                }, &marker_buf);
                try render_inline.renderCheckbox(writer, ordered.checked, opts.enable_ansi, palette);
                try render_inline.renderInline(allocator, writer, parse_block.stripHardBreak(ordered.content), opts.enable_ansi, .{
                    .fg = palette.body,
                }, palette, &link_defs);
                if (has_newline) try writer.writeByte('\n');
                const content_col = ordered.indent + ordered.number.len + parse_block.marker_suffix_width;
                line_start = try render_inline.consumeListContinuation(allocator, writer, input, line_end + @intFromBool(has_newline), content_col, opts.enable_ansi, palette, &link_defs);
                prev_was_blank = false;
                continue;
            } else if (parse_block.parseListItem(line)) |item| {
                try writer.splatByteAll(' ', item.indent);
                var marker: [2]u8 = .{ item.marker, ' ' };
                try ansi.writeStyled(writer, opts.enable_ansi, .{
                    .fg = palette.list_marker,
                    .bold = true,
                }, &marker);
                try render_inline.renderCheckbox(writer, item.checked, opts.enable_ansi, palette);
                try render_inline.renderInline(allocator, writer, parse_block.stripHardBreak(item.content), opts.enable_ansi, .{
                    .fg = palette.body,
                }, palette, &link_defs);
                if (has_newline) try writer.writeByte('\n');
                const content_col = item.indent + parse_block.marker_suffix_width;
                line_start = try render_inline.consumeListContinuation(allocator, writer, input, line_end + @intFromBool(has_newline), content_col, opts.enable_ansi, palette, &link_defs);
                prev_was_blank = false;
                continue;
            } else {
                if (opts.wrap_width) |wrap_w| {
                    var buf: std.io.Writer.Allocating = .init(allocator);
                    defer buf.deinit();
                    try render_inline.renderInline(allocator, &buf.writer, parse_block.stripHardBreak(line), opts.enable_ansi, .{
                        .fg = palette.body,
                    }, palette, &link_defs);
                    var list = buf.toArrayList();
                    defer list.deinit(allocator);
                    const rendered = try list.toOwnedSlice(allocator);
                    defer allocator.free(rendered);
                    const wrapped = try width.wrapText(allocator, rendered, wrap_w);
                    defer allocator.free(wrapped);
                    try writer.writeAll(wrapped);
                } else {
                    try render_inline.renderInline(allocator, writer, parse_block.stripHardBreak(line), opts.enable_ansi, .{
                        .fg = palette.body,
                    }, palette, &link_defs);
                }
            }

            if (std.mem.trim(u8, line, parse_block.horizontal_whitespace).len != 0) prev_was_blank = false;
        }

        if (has_newline) try writer.writeByte('\n');
        line_start = line_end + @intFromBool(has_newline);
    }

    // EOF flush: if the input ended without a closing fence, emit whatever
    // has been buffered so the content is not silently dropped.
    if (active_fence != null and fence_buffer.items.len > 0) {
        try flushFenceBuffer(allocator, writer, &fence_buffer, active_language, &highlighter, opts, palette, syn_palette);
    }
}

/// Emit buffered code fence content.
///
/// Dispatch order:
/// 1. Recognized language + ANSI enabled → Tree-sitter highlighter.
///    On `error.QueryUnavailable`, fall back to uniform inline_code color.
/// 2. Recognized language + ANSI disabled → plain text (Tree-sitter bypassed).
/// 3. Unrecognized language → uniform inline_code color.
///
/// All paths go through `ansi.writeStyled` → `writeSanitized`, preserving
/// the sanitization invariant for code fence content.
fn flushFenceBuffer(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    fence_buffer: *std.ArrayListUnmanaged(u8),
    active_language: ?highlight.Language,
    highlighter: *highlight.Highlighter,
    opts: RenderOptions,
    palette: theme.Palette,
    syn_palette: theme.SyntaxPalette,
) !void {
    const content = fence_buffer.items;
    if (content.len == 0) return;

    if (active_language) |lang| {
        if (opts.enable_ansi) {
            highlighter.writeHighlightedBlock(allocator, writer, content, lang, syn_palette) catch |err| switch (err) {
                error.QueryUnavailable => {
                    try ansi.writeStyled(writer, true, .{ .fg = palette.inline_code }, content);
                },
                else => return err,
            };
        } else {
            try ansi.writeStyled(writer, false, .{}, content);
        }
    } else {
        try ansi.writeStyled(writer, opts.enable_ansi, .{
            .fg = palette.inline_code,
        }, content);
    }
    fence_buffer.clearRetainingCapacity();
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

test {
    _ = @import("render_test_block.zig");
    _ = @import("render_test_inline.zig");
    _ = @import("render_test_code.zig");
    _ = @import("render_test_table.zig");
}
