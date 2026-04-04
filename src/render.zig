const std = @import("std");
const ansi = @import("ansi.zig");
const document = @import("document.zig");
const theme = @import("theme.zig");

pub const RenderOptions = struct {
    enable_ansi: bool = false,
    theme: theme.Theme = .solarized_dark,
};

const Fence = struct {
    fence_char: u8,
    fence_len: usize,
};

const Heading = struct {
    level: u8,
    content: []const u8,
};

const ListItem = struct {
    indent: usize,
    marker: u8,
    content: []const u8,
};

const BlockQuote = struct {
    indent: usize,
    content: []const u8,
};

pub fn renderMarkdown(writer: *std.io.Writer, input: []const u8, opts: RenderOptions) !void {
    if (input.len == 0) return;

    const palette = theme.palette(opts.theme);
    var active_fence: ?Fence = null;
    var line_start: usize = 0;

    while (line_start < input.len) {
        const line_end = std.mem.indexOfScalarPos(u8, input, line_start, '\n') orelse input.len;
        const has_newline = line_end < input.len;
        const line = document.trimCarriageReturn(input[line_start..line_end]);

        if (active_fence) |fence| {
            if (isClosingFence(line, fence)) {
                try writeStyledLine(writer, line, opts.enable_ansi, .{
                    .fg = palette.code_fence,
                    .dim = true,
                });
                active_fence = null;
            } else {
                try writeStyledLine(writer, line, opts.enable_ansi, .{
                    .fg = palette.inline_code,
                });
            }
        } else if (parseFence(line)) |fence| {
            active_fence = fence;
            try writeStyledLine(writer, line, opts.enable_ansi, .{
                .fg = palette.code_fence,
                .dim = true,
            });
        } else if (isBlankLine(line)) {} else if (isThematicBreak(line)) {
            try writeStyledLine(writer, "--------------------------------", opts.enable_ansi, .{
                .fg = palette.subtle,
                .dim = true,
            });
        } else if (parseHeading(line)) |heading| {
            _ = heading.level;
            try renderInline(writer, heading.content, opts.enable_ansi, .{
                .fg = palette.heading,
                .bold = true,
            }, palette);
        } else if (parseBlockQuote(line)) |quote| {
            try writeIndent(writer, quote.indent);
            try renderBlockQuoteContent(writer, quote.content, opts.enable_ansi, palette);
        } else if (parseListItem(line)) |item| {
            try writeIndent(writer, item.indent);
            var marker: [2]u8 = .{ item.marker, ' ' };
            try ansi.writeStyled(writer, opts.enable_ansi, .{
                .fg = palette.list_marker,
                .bold = true,
            }, &marker);
            try renderInline(writer, item.content, opts.enable_ansi, .{
                .fg = palette.body,
            }, palette);
        } else {
            try renderInline(writer, line, opts.enable_ansi, .{
                .fg = palette.body,
            }, palette);
        }

        if (has_newline) try writer.writeByte('\n');
        line_start = line_end + @intFromBool(has_newline);
    }
}

fn isBlankLine(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t").len == 0;
}

fn parseHeading(line: []const u8) ?Heading {
    var index = countIndentUpTo(line, 3);
    if (index >= line.len or line[index] != '#') return null;

    var level: u8 = 0;
    while (index < line.len and line[index] == '#' and level < 6) : (index += 1) {
        level += 1;
    }

    if (level == 0) return null;
    if (index < line.len and line[index] != ' ' and line[index] != '\t') return null;

    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}

    return .{
        .level = level,
        .content = trimClosingHashes(line[index..]),
    };
}

fn trimClosingHashes(text: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, text, " \t");
    var end = trimmed.len;

    while (end > 0 and trimmed[end - 1] == '#') : (end -= 1) {}
    if (end == trimmed.len) return trimmed;
    if (end > 0 and (trimmed[end - 1] == ' ' or trimmed[end - 1] == '\t')) {
        return std.mem.trimRight(u8, trimmed[0 .. end - 1], " \t");
    }
    return trimmed;
}

fn parseListItem(line: []const u8) ?ListItem {
    const indent = countLeadingWhitespace(line);
    if (indent >= line.len) return null;

    const marker = line[indent];
    if (marker != '-' and marker != '*' and marker != '+') return null;
    if (indent + 1 >= line.len) return null;
    if (line[indent + 1] != ' ' and line[indent + 1] != '\t') return null;

    var content_index = indent + 1;
    while (content_index < line.len and (line[content_index] == ' ' or line[content_index] == '\t')) : (content_index += 1) {}

    return .{
        .indent = indent,
        .marker = marker,
        .content = line[content_index..],
    };
}

fn renderBlockQuoteContent(
    writer: *std.io.Writer,
    content: []const u8,
    enable_ansi: bool,
    palette: theme.Palette,
) !void {
    try ansi.writeStyled(writer, enable_ansi, .{
        .fg = palette.muted,
        .dim = true,
    }, "| ");

    if (parseBlockQuote(content)) |nested| {
        try writeIndent(writer, nested.indent);
        try renderBlockQuoteContent(writer, nested.content, enable_ansi, palette);
    } else {
        try renderInline(writer, content, enable_ansi, .{
            .fg = palette.muted,
        }, palette);
    }
}

fn parseBlockQuote(line: []const u8) ?BlockQuote {
    const indent = countIndentUpTo(line, 3);
    if (indent >= line.len or line[indent] != '>') return null;

    var content_index = indent + 1;
    while (content_index < line.len and (line[content_index] == ' ' or line[content_index] == '\t')) : (content_index += 1) {}

    return .{
        .indent = indent,
        .content = line[content_index..],
    };
}

fn parseFence(line: []const u8) ?Fence {
    const index = countIndentUpTo(line, 3);
    if (index >= line.len) return null;

    const fence_char = line[index];
    if (fence_char != '`' and fence_char != '~') return null;

    const fence_len = countRepeatedByte(line[index..], fence_char);
    if (fence_len < 3) return null;

    return .{
        .fence_char = fence_char,
        .fence_len = fence_len,
    };
}

fn isClosingFence(line: []const u8, fence: Fence) bool {
    const index = countIndentUpTo(line, 3);
    if (index >= line.len) return false;
    if (line[index] != fence.fence_char) return false;

    const fence_len = countRepeatedByte(line[index..], fence.fence_char);
    if (fence_len < fence.fence_len) return false;

    return std.mem.trim(u8, line[index + fence_len ..], " \t").len == 0;
}

fn isThematicBreak(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;

    const marker = trimmed[0];
    if (marker != '-' and marker != '_' and marker != '*') return false;

    var marker_count: usize = 0;
    for (trimmed) |char| {
        switch (char) {
            ' ', '\t' => {},
            else => {
                if (char != marker) return false;
                marker_count += 1;
            },
        }
    }

    return marker_count >= 3;
}

fn renderInline(
    writer: *std.io.Writer,
    text: []const u8,
    enable_ansi: bool,
    base_style: ansi.TextStyle,
    palette: theme.Palette,
) !void {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, index + 1, '`')) |end| {
                try ansi.writeStyled(writer, enable_ansi, .{
                    .fg = palette.inline_code,
                }, text[index .. end + 1]);
                index = end + 1;
                continue;
            }
            try ansi.writeStyled(writer, enable_ansi, base_style, text[index .. index + 1]);
            index += 1;
            continue;
        }

        if (text[index] == '[') {
            if (findSimpleLinkEnd(text, index)) |end| {
                try ansi.writeStyled(writer, enable_ansi, .{
                    .fg = palette.link,
                    .underline = true,
                }, text[index..end]);
                index = end;
                continue;
            }
            try ansi.writeStyled(writer, enable_ansi, base_style, text[index .. index + 1]);
            index += 1;
            continue;
        }

        const next_special = findNextSpecial(text, index + 1) orelse text.len;
        try ansi.writeStyled(writer, enable_ansi, base_style, text[index..next_special]);
        index = next_special;
    }
}

fn findSimpleLinkEnd(text: []const u8, start: usize) ?usize {
    const close_bracket = std.mem.indexOfScalarPos(u8, text, start + 1, ']') orelse return null;
    if (close_bracket + 1 >= text.len or text[close_bracket + 1] != '(') return null;

    var depth: usize = 1;
    var pos = close_bracket + 2;
    while (pos < text.len) : (pos += 1) {
        switch (text[pos]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return pos + 1;
            },
            else => {},
        }
    }
    return null;
}

fn findNextSpecial(text: []const u8, start: usize) ?usize {
    const backtick = std.mem.indexOfScalarPos(u8, text, start, '`');
    const bracket = std.mem.indexOfScalarPos(u8, text, start, '[');

    return switch (backtick != null) {
        true => switch (bracket != null) {
            true => @min(backtick.?, bracket.?),
            false => backtick,
        },
        false => bracket,
    };
}

fn writeStyledLine(
    writer: *std.io.Writer,
    text: []const u8,
    enable_ansi: bool,
    style: ansi.TextStyle,
) !void {
    try ansi.writeStyled(writer, enable_ansi, style, text);
}

fn writeIndent(writer: *std.io.Writer, count: usize) !void {
    for (0..count) |_| {
        try writer.writeByte(' ');
    }
}

fn countIndentUpTo(line: []const u8, max_spaces: usize) usize {
    var count: usize = 0;
    while (count < line.len and count < max_spaces and (line[count] == ' ' or line[count] == '\t')) : (count += 1) {}
    return count;
}

fn countLeadingWhitespace(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and (line[count] == ' ' or line[count] == '\t')) : (count += 1) {}
    return count;
}

fn countRepeatedByte(text: []const u8, byte: u8) usize {
    var count: usize = 0;
    while (count < text.len and text[count] == byte) : (count += 1) {}
    return count;
}

fn renderToOwnedSlice(
    allocator: std.mem.Allocator,
    input: []const u8,
    opts: RenderOptions,
) ![]u8 {
    var output: std.io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try renderMarkdown(&output.writer, input, opts);
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
        \\[link](https://example.com)
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

    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[38;2;38;139;210mTitle\x1b[0m\n" ++
            "\x1b[4m\x1b[38;2;108;113;196m[link](https://example.com)\x1b[0m",
        rendered,
    );
}

test "findSimpleLinkEnd handles parentheses inside URLs" {
    const allocator = std.testing.allocator;
    const source = "[wiki](https://en.wikipedia.org/wiki/Foo_(bar))";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(source, rendered);
}

test "nested blockquotes render with multiple pipe markers" {
    const allocator = std.testing.allocator;
    const source = "> > nested\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("| | nested\n", rendered);
}

test "tab-indented headings and blockquotes are recognized" {
    const allocator = std.testing.allocator;
    const source = "\t# Tab Heading\n\t> Tab Quote\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Tab Heading"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Tab Quote"));
}
