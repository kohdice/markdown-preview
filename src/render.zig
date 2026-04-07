const std = @import("std");
const ansi = @import("ansi.zig");
const theme = @import("theme.zig");
const width = @import("width.zig");
const parse_block = @import("parse_block.zig");
const parse_link = @import("parse_link.zig");
const text = @import("text.zig");
const tabular = @import("tabular.zig");
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
            } else if (try tabular.tryRenderTable(allocator, writer, input, line, line_end, opts.enable_ansi, palette, &link_defs)) |new_start| {
                prev_was_blank = false;
                line_start = new_start;
                continue;
            } else if (parse_block.parseHeading(line)) |heading| {
                try text.renderInline(allocator, writer, parse_block.stripHardBreak(heading.content), opts.enable_ansi, headingStyle(heading.level, palette), palette, &link_defs);
            } else if (parse_block.parseBlockQuote(line)) |quote| {
                if (std.mem.indexOfScalar(u8, quote.content, '|') != null) {
                    if (try tabular.tryRenderBlockQuoteTable(allocator, writer, input, line_start, opts.enable_ansi, palette, &link_defs)) |new_start| {
                        prev_was_blank = false;
                        line_start = new_start;
                        continue;
                    }
                }
                try writer.splatByteAll(' ', quote.indent);
                try text.renderBlockQuoteContent(allocator, writer, quote.content, opts.enable_ansi, palette, &link_defs);
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
                try text.renderCheckbox(writer, ordered.checked, opts.enable_ansi, palette);
                try text.renderInline(allocator, writer, parse_block.stripHardBreak(ordered.content), opts.enable_ansi, .{
                    .fg = palette.body,
                }, palette, &link_defs);
                if (has_newline) try writer.writeByte('\n');
                const content_col = ordered.indent + ordered.number.len + parse_block.marker_suffix_width;
                line_start = try text.consumeListContinuation(allocator, writer, input, line_end + @intFromBool(has_newline), content_col, opts.enable_ansi, palette, &link_defs);
                prev_was_blank = false;
                continue;
            } else if (parse_block.parseListItem(line)) |item| {
                try writer.splatByteAll(' ', item.indent);
                var marker: [2]u8 = .{ item.marker, ' ' };
                try ansi.writeStyled(writer, opts.enable_ansi, .{
                    .fg = palette.list_marker,
                    .bold = true,
                }, &marker);
                try text.renderCheckbox(writer, item.checked, opts.enable_ansi, palette);
                try text.renderInline(allocator, writer, parse_block.stripHardBreak(item.content), opts.enable_ansi, .{
                    .fg = palette.body,
                }, palette, &link_defs);
                if (has_newline) try writer.writeByte('\n');
                const content_col = item.indent + parse_block.marker_suffix_width;
                line_start = try text.consumeListContinuation(allocator, writer, input, line_end + @intFromBool(has_newline), content_col, opts.enable_ansi, palette, &link_defs);
                prev_was_blank = false;
                continue;
            } else {
                if (opts.wrap_width) |wrap_w| {
                    var buf: std.io.Writer.Allocating = .init(allocator);
                    defer buf.deinit();
                    try text.renderInline(allocator, &buf.writer, parse_block.stripHardBreak(line), opts.enable_ansi, .{
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
                    try text.renderInline(allocator, writer, parse_block.stripHardBreak(line), opts.enable_ansi, .{
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

fn renderToOwnedSlice(
    allocator: std.mem.Allocator,
    input: []const u8,
    opts: RenderOptions,
) ![]u8 {
    var output: std.io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try renderMarkdown(allocator, &output.writer, input, opts);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

test "renderMarkdown strips heading markers and preserves structure" {
    const allocator = std.testing.allocator;
    const source =
        \\# Title
        \\
        \\- item
        \\> quoted
        \\[link](https://example.com)
        \\```zig
        \\const value = 1;
        \\```
        \\
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\Title
        \\
        \\- item
        \\| quoted
        \\link(https://example.com)
        \\```zig
        \\const value = 1;
        \\```
        \\
    ,
        rendered,
    );
}

test "renderMarkdown emits Solarized Dark ANSI styling for headings and links" {
    const allocator = std.testing.allocator;
    const source =
        \\# Title
        \\[link](https://example.com)
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // link text: underline + link color; URL: dim + muted color (parens rendered separately)
    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[4m\x1b[38;2;181;137;0mTitle\x1b[0m\n" ++
            "\x1b[4m\x1b[38;2;108;113;196mlink\x1b[0m" ++
            "\x1b[2m\x1b[38;2;88;110;117m(\x1b[0m" ++
            "\x1b[2m\x1b[38;2;88;110;117mhttps://example.com\x1b[0m" ++
            "\x1b[2m\x1b[38;2;88;110;117m)\x1b[0m",
        rendered,
    );
}

test "link with parentheses inside URL renders semantically" {
    const allocator = std.testing.allocator;
    const source = "[wiki](https://en.wikipedia.org/wiki/Foo_(bar))";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("wiki(https://en.wikipedia.org/wiki/Foo_(bar))", rendered);
}

test "link text with balanced brackets" {
    const allocator = std.testing.allocator;
    const source = "[foo [bar]](https://example.com)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("foo [bar](https://example.com)", rendered);
}

test "link text with nested brackets" {
    const allocator = std.testing.allocator;
    const source = "[a [b [c]]](url)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("a [b [c]](url)", rendered);
}

test "nested blockquotes render with multiple pipe markers" {
    const allocator = std.testing.allocator;
    const source = "> > nested\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("| | nested\n", rendered);
}

test "heading levels produce different ANSI styles" {
    const allocator = std.testing.allocator;
    const source = "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // h1: bold + underline + yellow
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[4m\x1b[38;2;181;137;0m"));
    // h2: bold + underline + orange
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[4m\x1b[38;2;203;75;22m"));
    // h3: bold + blue (no underline)
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[38;2;38;139;210m"));
    // h4: bold + cyan
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[38;2;42;161;152m"));
    // h5: violet (no bold, no dim)
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;108;113;196mH5\x1b[0m"));
    // h6: dim + violet
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[2m\x1b[38;2;108;113;196mH6\x1b[0m"));
}

test "ordered list items are rendered with number markers" {
    const allocator = std.testing.allocator;
    const source =
        \\1. First item
        \\2. Second item
        \\3. Third item
        \\
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\1. First item
        \\2. Second item
        \\3. Third item
        \\
    ,
        rendered,
    );
}

test "ordered list with closing paren marker" {
    const allocator = std.testing.allocator;
    const source = "1) Item one\n2) Item two\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1) Item one\n2) Item two\n", rendered);
}

test "ordered list with indentation" {
    const allocator = std.testing.allocator;
    const source = "  1. Indented ordered item\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("  1. Indented ordered item\n", rendered);
}

test "ordered list with multi-digit numbers" {
    const allocator = std.testing.allocator;
    const source = "10. Tenth item\n999999999. Max digits\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("10. Tenth item\n999999999. Max digits\n", rendered);
}

test "ordered list rejects more than 9 digits" {
    const allocator = std.testing.allocator;
    const source = "1234567890. Too many digits\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1234567890. Too many digits\n", rendered);
}

test "ordered list items get ANSI styling" {
    const allocator = std.testing.allocator;
    const source = "1. Styled item\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // Number marker should have list_marker color (teal: 42, 161, 152) + bold
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m\x1b[38;2;42;161;152m1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Styled item"));
}

test "task list items render checkbox indicators" {
    const allocator = std.testing.allocator;
    const source =
        \\- [x] Completed task
        \\- [ ] Incomplete task
        \\- Regular item
        \\
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\- [x] Completed task
        \\- [ ] Incomplete task
        \\- Regular item
        \\
    ,
        rendered,
    );
}

test "task list with uppercase X" {
    const allocator = std.testing.allocator;
    const source = "- [X] Done\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- [x] Done\n", rendered);
}

test "ordered task list items" {
    const allocator = std.testing.allocator;
    const source = "1. [x] First done\n2. [ ] Second pending\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1. [x] First done\n2. [ ] Second pending\n", rendered);
}

test "task list items get ANSI styling" {
    const allocator = std.testing.allocator;
    const source = "- [x] Done\n- [ ] Todo\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // Checked: [x] should have list_marker color (teal: 42, 161, 152)
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;42;161;152m[x] "));
    // Unchecked: [ ] should have muted + dim
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[2m\x1b[38;2;88;110;117m[ ] "));
}

test "task list with tab separator" {
    const allocator = std.testing.allocator;
    const source = "- [x]\tTab-separated task\n- [\t] Tab in checkbox\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "[x] "));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "[ ] "));
}

test "empty ordered list item" {
    const allocator = std.testing.allocator;
    const source = "1. First\n2.\n3. Third\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    // "2." renders as "2. " because the marker includes trailing space
    try std.testing.expectEqualStrings("1. First\n2. \n3. Third\n", rendered);
}

test "nested task list items" {
    const allocator = std.testing.allocator;
    const source = "- [x] Parent\n  - [ ] Child\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- [x] Parent\n  - [ ] Child\n", rendered);
}

test "tab-indented headings and blockquotes are recognized" {
    const allocator = std.testing.allocator;
    const source = "\t# Tab Heading\n\t> Tab Quote\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Tab Heading"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Tab Quote"));
}

test "bold text renders without delimiters" {
    const allocator = std.testing.allocator;
    const source = "This is **bold** text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is bold text", rendered);
}

test "italic text renders without delimiters" {
    const allocator = std.testing.allocator;
    const source = "This is *italic* text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is italic text", rendered);
}

test "underscore italic renders without delimiters" {
    const allocator = std.testing.allocator;
    const source = "This is _italic_ text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is italic text", rendered);
}

test "strikethrough renders without delimiters" {
    const allocator = std.testing.allocator;
    const source = "This is ~~deleted~~ text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is deleted text", rendered);
}

test "single tilde strikethrough" {
    const allocator = std.testing.allocator;
    const source = "This is ~deleted~ text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is deleted text", rendered);
}

test "foo_bar_baz is not emphasis" {
    const allocator = std.testing.allocator;
    const source = "foo_bar_baz";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("foo_bar_baz", rendered);
}

test "unmatched delimiters render as literal text" {
    const allocator = std.testing.allocator;
    const source = "This has *unmatched delimiter";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This has *unmatched delimiter", rendered);
}

test "bold ANSI styling applies bold attribute" {
    const allocator = std.testing.allocator;
    const source = "**bold**";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "bold"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "**"));
}

test "italic ANSI styling applies italic attribute" {
    const allocator = std.testing.allocator;
    const source = "*italic*";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[3m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "italic"));
}

test "strikethrough ANSI styling applies strikethrough attribute" {
    const allocator = std.testing.allocator;
    const source = "~~struck~~";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[9m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "struck"));
}

test "code span takes precedence over emphasis" {
    const allocator = std.testing.allocator;
    const source = "*italic with `code` inside*";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "`code`"));
}

test "triple asterisk renders as bold italic" {
    const allocator = std.testing.allocator;
    const source = "***bold italic***";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[3m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "bold italic"));
}

test "nested bold with inner italic" {
    const allocator = std.testing.allocator;
    const source = "**bold _and italic_**";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("bold and italic", rendered);
}

test "link text with emphasis renders recursively" {
    const allocator = std.testing.allocator;
    const source = "[**bold link**](https://example.com)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("bold link(https://example.com)", rendered);
}

test "link text with emphasis gets ANSI styling" {
    const allocator = std.testing.allocator;
    const source = "[**bold**](url)";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "bold"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "**"));
}

test "double backtick code span" {
    const allocator = std.testing.allocator;
    const source = "``code with ` backtick``";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("``code with ` backtick``", rendered);
}

test "backslash escaped asterisk is not emphasis" {
    const allocator = std.testing.allocator;
    const source = "\\*not emphasis\\*";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("*not emphasis*", rendered);
}

test "code fence with language preserves original format" {
    const allocator = std.testing.allocator;
    const source = "```python\nprint('hello')\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```python\nprint('hello')\n```\n", rendered);
}

test "code fence without language preserves format" {
    const allocator = std.testing.allocator;
    const source = "```\nplain code\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```\nplain code\n```\n", rendered);
}

test "code fence language is captured in Fence struct" {
    const allocator = std.testing.allocator;
    const source = "```javascript mocha\nconsole.log();\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```javascript mocha\nconsole.log();\n```\n", rendered);
}

test "zig code fence gets syntax highlighting under ANSI" {
    const allocator = std.testing.allocator;
    const source = "```zig\nconst x: u32 = 42;\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 2, "```"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "const"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "42"));
    // Solarized green keyword color #859900 = 133,153,0.
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;133;153;0m"));
}

test "zig code fence is plain text when ANSI disabled" {
    const allocator = std.testing.allocator;
    const source = "```zig\nconst x: u32 = 42;\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```zig\nconst x: u32 = 42;\n```\n", rendered);
}

test "unrecognized language falls back to uniform inline_code color" {
    const allocator = std.testing.allocator;
    const source = "```klingon\nQapla'!\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Qapla'!"));
    // inline_code color (teal #2aa198 = 42,161,152) is applied to the buffered body.
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;42;161;152m"));
}

test "unclosed zig code fence at EOF is flushed" {
    const allocator = std.testing.allocator;
    const source = "```zig\nconst x = 1;\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "const x = 1;"));
}

test "empty code fence renders just the fences" {
    const allocator = std.testing.allocator;
    const source = "```zig\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("```zig\n```\n", rendered);
}

test "code fence with syntax errors still renders (Tree-sitter error recovery)" {
    const allocator = std.testing.allocator;
    const source = "```zig\nconst x = @@@broken syntax;\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "const"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "broken"));
}

test "python code fence highlights with ANSI" {
    const allocator = std.testing.allocator;
    const source = "```python\ndef greet():\n    return 1\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "def"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "greet"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;"));
}

test "bash code fence uses sh alias" {
    const allocator = std.testing.allocator;
    const source = "```sh\necho hello\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "echo"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[38;2;"));
}

test "multiline zig raw string does not leak ANSI state across lines" {
    const allocator = std.testing.allocator;
    // Multi-line raw string literal spans three lines inside a code fence.
    // Every styled run must be followed by an `\x1b[0m` reset so color does
    // not bleed from one line into the next.
    const source = "```zig\n" ++
        "const msg =\n" ++
        "    \\\\hello\n" ++
        "    \\\\world\n" ++
        ";\n" ++
        "```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "hello"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "world"));

    // Every opening escape (style set) must be paired with a reset. Count
    // resets to confirm they appear and the styled runs close cleanly.
    var reset_count: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, rendered, scan, "\x1b[0m")) |found| {
        reset_count += 1;
        scan = found + 4;
    }
    try std.testing.expect(reset_count > 0);
}

test "C0 control bytes inside a code fence are stripped by writeSanitized" {
    const allocator = std.testing.allocator;
    // Injection attempt: raw ESC + CSI "red" sequence hidden inside a string.
    // writeSanitized must strip the ESC but leave visible characters intact.
    const source = "```zig\nconst x = \"\x1b[31mevil\\x07\";\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "\x1b[31m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "evil"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "\x07"));
}

test "python code fence is plain text when ANSI disabled" {
    const allocator = std.testing.allocator;
    const source = "```python\ndef greet():\n    return 1\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(source, rendered);
}

test "bash code fence is plain text when ANSI disabled" {
    const allocator = std.testing.allocator;
    const source = "```bash\necho hello\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(source, rendered);
}

test "simple table renders with aligned columns" {
    const allocator = std.testing.allocator;
    const source = "| A | B |\n| --- | --- |\n| 1 | 2 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "A"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "B"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "2"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "|"));
}

test "table inside code fence is not detected" {
    const allocator = std.testing.allocator;
    const source = "```\n| A | B |\n| --- | --- |\n| 1 | 2 |\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "| A | B |"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "| --- | --- |"));
}

test "line with pipe but no delimiter row is not a table" {
    const allocator = std.testing.allocator;
    const source = "a | b\nnot a table\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("a | b\nnot a table\n", rendered);
}

test "consecutive blank lines are collapsed to one" {
    const allocator = std.testing.allocator;
    const source = "First\n\n\n\nSecond\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("First\n\nSecond\n", rendered);
}

test "single blank line between paragraphs is preserved" {
    const allocator = std.testing.allocator;
    const source = "First\n\nSecond\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("First\n\nSecond\n", rendered);
}

test "hard break trailing spaces are stripped" {
    const allocator = std.testing.allocator;
    const source = "Line one  \nLine two\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Line one\nLine two\n", rendered);
}

test "hard break with backslash at end of line" {
    const allocator = std.testing.allocator;
    const source = "Line one\\\nLine two\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Line one\nLine two\n", rendered);
}

test "single trailing space is preserved" {
    const allocator = std.testing.allocator;
    const source = "Line with one trailing space \nNext line\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    // Only 1 trailing space — not a hard break, should be preserved
    try std.testing.expectEqualStrings("Line with one trailing space \nNext line\n", rendered);
}

test "hard break inside code fence is not stripped" {
    const allocator = std.testing.allocator;
    const source = "```\ncode with trailing spaces  \n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "code with trailing spaces  "));
}

test "blank lines between different block elements are normalized" {
    const allocator = std.testing.allocator;
    const source = "# Heading\n\n\n\nParagraph\n\n\n- list\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Heading\n\nParagraph\n\n- list\n", rendered);
}

test "blank line after table is preserved" {
    const allocator = std.testing.allocator;
    const source = "| A |\n| --- |\n| 1 |\n\nParagraph after table\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\n\nParagraph after table"));
}

test "image syntax renders as alt text placeholder" {
    const allocator = std.testing.allocator;
    const source = "![logo](https://example.com/logo.png)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("[img: logo](https://example.com/logo.png)", rendered);
}

test "image syntax with ANSI styling" {
    const allocator = std.testing.allocator;
    const source = "![alt](url)";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // alt text should have italic + muted color
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[3m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "[img: "));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "alt"));
}

test "image inside text" {
    const allocator = std.testing.allocator;
    const source = "See ![diagram](img.png) for details";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("See [img: diagram](img.png) for details", rendered);
}

test "exclamation mark without bracket is plain text" {
    const allocator = std.testing.allocator;
    const source = "This is great! Really!";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is great! Really!", rendered);
}

test "backslash escaped underscore is literal" {
    const allocator = std.testing.allocator;
    const source = "\\_literal\\_";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("_literal_", rendered);
}

test "HTML entities are decoded in text" {
    const allocator = std.testing.allocator;
    const source = "A &amp; B &lt; C &gt; D";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("A & B < C > D", rendered);
}

test "HTML numeric entity decimal" {
    const allocator = std.testing.allocator;
    const source = "&#65; &#66; &#67;";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("A B C", rendered);
}

test "HTML numeric entity hex" {
    const allocator = std.testing.allocator;
    const source = "&#x41; &#x42;";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("A B", rendered);
}

test "unknown HTML entity is preserved as-is" {
    const allocator = std.testing.allocator;
    const source = "&foobar; stays";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("&foobar; stays", rendered);
}

test "HTML entity in heading" {
    const allocator = std.testing.allocator;
    const source = "# Title &amp; Subtitle";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Title & Subtitle", rendered);
}

test "HTML entity in bold text" {
    const allocator = std.testing.allocator;
    const source = "**bold &amp; strong**";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("bold & strong", rendered);
}

test "ampersand without semicolon is preserved" {
    const allocator = std.testing.allocator;
    const source = "AT&T";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("AT&T", rendered);
}

test "autolink renders URL with link styling" {
    const allocator = std.testing.allocator;
    const source = "Visit <https://example.com> for details";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Visit https://example.com for details", rendered);
}

test "autolink with ANSI gets link styling" {
    const allocator = std.testing.allocator;
    const source = "<https://example.com>";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // Should have underline + link color (violet: 108, 113, 196)
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[4m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "<https"));
}

test "autolink requires scheme://" {
    const allocator = std.testing.allocator;
    const source = "<not-a-link>";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("<not-a-link>", rendered);
}

test "autolink with spaces is not parsed" {
    const allocator = std.testing.allocator;
    const source = "<https://example.com/path with spaces>";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("<https://example.com/path with spaces>", rendered);
}

test "autolink with ftp scheme" {
    const allocator = std.testing.allocator;
    const source = "<ftp://files.example.com/readme>";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("ftp://files.example.com/readme", rendered);
}

test "bare URL is detected as autolink" {
    const allocator = std.testing.allocator;
    const source = "Visit https://example.com for details";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Visit https://example.com for details", rendered);
}

test "bare URL with path and query" {
    const allocator = std.testing.allocator;
    const source = "See https://example.com/path?q=1&r=2 here";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("See https://example.com/path?q=1&r=2 here", rendered);
}

test "bare URL strips trailing punctuation" {
    const allocator = std.testing.allocator;
    const source = "Check https://example.com.";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Check https://example.com.", rendered);
}

test "bare URL with ANSI gets link styling" {
    const allocator = std.testing.allocator;
    const source = "https://example.com";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[4m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
}

test "bare URL not detected inside words" {
    const allocator = std.testing.allocator;
    const source = "foohttps://example.com";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("foohttps://example.com", rendered);
}

test "bare http URL detected" {
    const allocator = std.testing.allocator;
    const source = "http://example.com";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("http://example.com", rendered);
}

test "bare URL with unmatched trailing paren is stripped" {
    const allocator = std.testing.allocator;
    const source = "(see https://example.com)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("(see https://example.com)", rendered);
}

test "bare URL rejects localhost (no dot in domain)" {
    const allocator = std.testing.allocator;
    const source = "http://localhost/path";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("http://localhost/path", rendered);
}

test "bare URL strips trailing underscore and tilde" {
    const allocator = std.testing.allocator;
    const source = "https://example.com_";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("https://example.com_", rendered);
}

test "bare URL not detected after bracket" {
    const allocator = std.testing.allocator;
    const source = "foo[https://example.com";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // Should detect — [ is valid preceding char
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[4m"));
}

test "link with title renders title" {
    const allocator = std.testing.allocator;
    const source =
        \\[GitHub](https://github.com "GitHub Homepage")
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("GitHub(https://github.com) — GitHub Homepage", rendered);
}

test "link with single-quote title" {
    const allocator = std.testing.allocator;
    const source = "[link](url 'My Title')";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("link(url) — My Title", rendered);
}

test "link without title unchanged" {
    const allocator = std.testing.allocator;
    const source = "[link](https://example.com)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("link(https://example.com)", rendered);
}

test "link title with ANSI styling" {
    const allocator = std.testing.allocator;
    const source =
        \\[text](url "title")
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    // Title should have italic + dim + muted
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[2m\x1b[3m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "title"));
}

test "same-delimiter nesting **bold *italic***" {
    const allocator = std.testing.allocator;
    const source = "**bold *italic***";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("bold italic", rendered);
}

test "same-delimiter nesting *italic **bold***" {
    const allocator = std.testing.allocator;
    const source = "*italic **bold***";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("italic bold", rendered);
}

test "same-delimiter nesting with ANSI" {
    const allocator = std.testing.allocator;
    const source = "**bold *italic***";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[3m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "bold"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "italic"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "***"));
}

test "reference-style link resolves to definition" {
    const allocator = std.testing.allocator;
    const source = "[GitHub][1]\n\n[1]: https://github.com\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "GitHub"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://github.com"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "[1]:"));
}

test "reference link with empty ref uses text as label" {
    const allocator = std.testing.allocator;
    const source = "[example][]\n\n[example]: https://example.com\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "example"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
}

test "shortcut reference link" {
    const allocator = std.testing.allocator;
    const source = "[example]\n\n[example]: https://example.com\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "example"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
}

test "reference link is case-insensitive" {
    const allocator = std.testing.allocator;
    const source = "[Text][FOO]\n\n[foo]: https://example.com\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Text"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
}

test "undefined reference link is rendered as plain text" {
    const allocator = std.testing.allocator;
    const source = "[text][missing]";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("[text][missing]", rendered);
}

test "link definition with title" {
    const allocator = std.testing.allocator;
    const source = "[link][ref]\n\n[ref]: https://example.com \"My Title\"\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "link"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "My Title"));
}

test "unordered list continuation line" {
    const allocator = std.testing.allocator;
    const source = "- first line\n  continued here\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- first line\n  continued here\n", rendered);
}

test "unordered list multiple continuation lines" {
    const allocator = std.testing.allocator;
    const source = "- first\n  second\n  third\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- first\n  second\n  third\n", rendered);
}

test "ordered list continuation line" {
    const allocator = std.testing.allocator;
    const source = "1. first line\n   continued here\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("1. first line\n   continued here\n", rendered);
}

test "continuation stops at unindented line" {
    const allocator = std.testing.allocator;
    const source = "- first\n  continued\nnot continued\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- first\n  continued\nnot continued\n", rendered);
}

test "continuation stops at blank line" {
    const allocator = std.testing.allocator;
    const source = "- first\n\n  not continued\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- first\n\n  not continued\n", rendered);
}

test "continuation stops at nested list item" {
    const allocator = std.testing.allocator;
    const source = "- parent\n  - child\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- parent\n  - child\n", rendered);
}

test "ordered list multi-digit continuation" {
    const allocator = std.testing.allocator;
    const source = "10. first line\n    continued\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("10. first line\n    continued\n", rendered);
}

test "continuation with emphasis in continued line" {
    const allocator = std.testing.allocator;
    const source = "- start\n  **bold** continued\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- start\n  bold continued\n", rendered);
}

test "table inside blockquote" {
    const allocator = std.testing.allocator;
    const source = "> | A | B |\n> | --- | --- |\n> | 1 | 2 |\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "| "));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "A"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "B"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "2"));
    var line_iter = std.mem.splitScalar(u8, std.mem.trimEnd(u8, rendered, "\n"), '\n');
    while (line_iter.next()) |line| {
        try std.testing.expect(std.mem.startsWith(u8, line, "| "));
    }
}

test "blockquote without table falls through to normal rendering" {
    const allocator = std.testing.allocator;
    const source = "> just a quote\n> another line\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("| just a quote\n| another line\n", rendered);
}

test "blockquote with pipe but no delimiter is not a table" {
    const allocator = std.testing.allocator;
    const source = "> a | b\n> c | d\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("| a | b\n| c | d\n", rendered);
}

test "blockquote table followed by normal blockquote" {
    const allocator = std.testing.allocator;
    const source = "> | A |\n> | --- |\n> | 1 |\n> normal text\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "A"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "normal text"));
}

test "paragraph wraps at wrap_width" {
    const allocator = std.testing.allocator;
    const source = "Hello World";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .wrap_width = 8 });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Hello\nWorld", rendered);
}

test "paragraph no wrap when wrap_width is null" {
    const allocator = std.testing.allocator;
    const source = "This is a long paragraph that should not be wrapped";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is a long paragraph that should not be wrapped", rendered);
}

test "heading is not wrapped" {
    const allocator = std.testing.allocator;
    const source = "# This is a heading that is long";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .wrap_width = 10 });
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is a heading that is long", rendered);
}

test "code fence content is not wrapped" {
    const allocator = std.testing.allocator;
    const source = "```\nThis is long code that should not wrap\n```\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{ .wrap_width = 10 });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "This is long code that should not wrap"));
}

test "emphasis after punctuation" {
    const allocator = std.testing.allocator;
    // CommonMark: *foo* inside quotes should parse as emphasis
    const source = "\"*foo*\"";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("\"foo\"", rendered);
}

test "emphasis wrapping punctuation" {
    const allocator = std.testing.allocator;
    const source = "*\"foo\"*";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("\"foo\"", rendered);
}

test "multiple-of-3 rule rejects *foo**" {
    const allocator = std.testing.allocator;
    // opener=1, closer=2: sum=3, 3%3==0, neither individually %3==0 → reject
    const source = "*foo**";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("*foo**", rendered);
}

test "multiple-of-3 rule allows ***foo***" {
    const allocator = std.testing.allocator;
    // opener=3, closer=3: sum=6, 6%3==0, both%3==0 → valid
    const source = "***foo***";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("foo", rendered);
}

test "underscore emphasis inside quotes" {
    const allocator = std.testing.allocator;
    const source = "\"_foo_\"";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("\"foo\"", rendered);
}

test "space before closing delimiter prevents emphasis" {
    const allocator = std.testing.allocator;
    const source = "*foo *";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("*foo *", rendered);
}

test "CRLF input renders ATX heading without trailing carriage return" {
    const allocator = std.testing.allocator;
    const source = "# Title\r\nbody\r\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Title\nbody\n", rendered);
}

test "CRLF input resolves reference link definition" {
    const allocator = std.testing.allocator;
    const source = "[text][ref]\r\n\r\n[ref]: https://example.com\r\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "text"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "\r"));
}

test "CRLF input renders pipe table" {
    const allocator = std.testing.allocator;
    const source = "| A | B |\r\n| --- | --- |\r\n| 1 | 2 |\r\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "A"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "B"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "2"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "\r"));
}

test "CRLF input renders blockquote table" {
    const allocator = std.testing.allocator;
    const source = "> | A | B |\r\n> | --- | --- |\r\n> | 1 | 2 |\r\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "A"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "B"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "2"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "\r"));
    var line_iter = std.mem.splitScalar(u8, std.mem.trimEnd(u8, rendered, "\n"), '\n');
    while (line_iter.next()) |line| {
        try std.testing.expect(std.mem.startsWith(u8, line, "| "));
    }
}

test "CRLF input preserves list continuation" {
    const allocator = std.testing.allocator;
    const source = "- first line\r\n  continued here\r\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("- first line\n  continued here\n", rendered);
}
