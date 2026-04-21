const std = @import("std");
const ansi = @import("../term/ansi.zig");
const ast = @import("../ast.zig");
const text = @import("../text.zig");
const width_mod = @import("../term/width.zig");
const theme = @import("../term/theme.zig");
const render_context = @import("context.zig");
const RenderContext = render_context.RenderContext;

const link_url_open = "(";
const link_url_close = ")";
const link_title_separator = " — ";
const image_alt_prefix = "[img: ";
const image_alt_suffix = "]";

fn traverseInlineChain(
    comptime Visitor: type,
    visitor: *Visitor,
    doc: *const ast.Document,
    first: ast.InlineRef,
) Visitor.Error!void {
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

const ContainerKind = enum {
    emphasis,
    strong,
    bold_italic,
    strikethrough,
};

fn InlineVisitor(comptime measure: bool) type {
    return struct {
        pub const Error = error{WriteFailed};
        const Self = @This();

        ctx: *const RenderContext,
        writer: *std.Io.Writer,
        sgr_state: *ansi.StyledState,
        current_style: ansi.TextStyle,
        width_total: if (measure) usize else void,
        ambiguous: if (measure) width_mod.AmbiguousWidth else void,

        inline fn addWidth(self: *Self, bytes: []const u8) void {
            if (comptime measure) {
                self.width_total += width_mod.displayWidth(bytes, self.ambiguous);
            }
        }

        pub fn onText(self: *Self, content: []const u8) Error!void {
            try writeTextWithEntities(self, content, self.current_style);
        }

        pub fn onCodeSpan(self: *Self, content: []const u8) Error!void {
            self.addWidth(content);
            try ansi.writeStyledRun(
                self.writer,
                self.ctx.enable_ansi,
                self.ctx.color_mode,
                self.sgr_state,
                .{ .fg = self.ctx.palette.inline_code },
                content,
            );
        }

        pub fn onAutolink(self: *Self, url: []const u8) Error!void {
            self.addWidth(url);
            try ansi.writeStyledRun(
                self.writer,
                self.ctx.enable_ansi,
                self.ctx.color_mode,
                self.sgr_state,
                self.current_style.merge(.{ .fg = self.ctx.palette.link, .underline = true }),
                url,
            );
        }

        pub fn onSoftBreak(self: *Self) Error!void {
            try ansi.flushStyle(self.writer, self.sgr_state);
            self.writer.writeByte('\n') catch return error.WriteFailed;
        }

        pub fn onHardBreak(self: *Self) Error!void {
            try ansi.flushStyle(self.writer, self.sgr_state);
            self.writer.writeByte('\n') catch return error.WriteFailed;
        }

        pub fn onContainer(self: *Self, kind: ContainerKind, doc: *const ast.Document, children: ast.InlineRef) Error!void {
            const saved = self.current_style;
            self.current_style = self.current_style.merge(switch (kind) {
                .emphasis => ansi.TextStyle{ .italic = true },
                .strong => ansi.TextStyle{ .bold = true },
                .bold_italic => ansi.TextStyle{ .bold = true, .italic = true },
                .strikethrough => ansi.TextStyle{ .strikethrough = true },
            });
            try traverseInlineChain(Self, self, doc, children);
            self.current_style = saved;
        }

        pub fn onLink(self: *Self, doc: *const ast.Document, link: ast.LinkInline) Error!void {
            const saved = self.current_style;
            self.current_style = self.current_style.merge(.{ .fg = self.ctx.palette.link, .underline = true });
            try traverseInlineChain(Self, self, doc, link.children);
            self.current_style = saved;

            const muted_dim: ansi.TextStyle = .{ .fg = self.ctx.palette.muted, .dim = true };
            try writeUrlDisplay(self, muted_dim, link.url);
            if (link.title) |t| {
                const title_style: ansi.TextStyle = .{ .fg = self.ctx.palette.muted, .dim = true, .italic = true };
                self.addWidth(link_title_separator);
                self.addWidth(t);
                try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, title_style, link_title_separator);
                try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, title_style, t);
            }
        }

        pub fn onImage(self: *Self, doc: *const ast.Document, img: ast.ImageInline) Error!void {
            const img_style: ansi.TextStyle = .{ .fg = self.ctx.palette.muted, .italic = true };
            self.addWidth(image_alt_prefix);
            try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, img_style, image_alt_prefix);

            const saved = self.current_style;
            self.current_style = img_style;
            try traverseInlineChain(Self, self, doc, img.children);
            self.current_style = saved;

            self.addWidth(image_alt_suffix);
            try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, img_style, image_alt_suffix);
            const muted_dim: ansi.TextStyle = .{ .fg = self.ctx.palette.muted, .dim = true };
            try writeUrlDisplay(self, muted_dim, img.url);
            if (img.title) |t| {
                const title_style: ansi.TextStyle = .{ .fg = self.ctx.palette.muted, .dim = true, .italic = true };
                self.addWidth(link_title_separator);
                self.addWidth(t);
                try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, title_style, link_title_separator);
                try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, title_style, t);
            }
        }

        fn writeUrlDisplay(self: *Self, style: ansi.TextStyle, url: []const u8) Error!void {
            self.addWidth(link_url_open);
            self.addWidth(url);
            self.addWidth(link_url_close);
            try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, style, link_url_open);
            try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, style, url);
            try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, style, link_url_close);
        }

        fn writeTextWithEntities(self: *Self, content: []const u8, style: ansi.TextStyle) Error!void {
            if (std.mem.indexOfScalar(u8, content, '&') == null) {
                self.addWidth(content);
                try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, style, content);
                return;
            }

            var pos: usize = 0;
            var plain_start: usize = 0;

            while (pos < content.len) {
                if (content[pos] == '&') {
                    if (text.decode(content, pos)) |result| {
                        if (plain_start < pos) {
                            const plain = content[plain_start..pos];
                            self.addWidth(plain);
                            try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, style, plain);
                        }
                        const decoded = result.bytes[0..result.len];
                        self.addWidth(decoded);
                        try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, style, decoded);
                        pos = result.end;
                        plain_start = pos;
                        continue;
                    }
                }
                pos += 1;
            }

            if (plain_start < content.len) {
                const tail = content[plain_start..];
                self.addWidth(tail);
                try ansi.writeStyledRun(self.writer, self.ctx.enable_ansi, self.ctx.color_mode, self.sgr_state, style, tail);
            }
        }
    };
}

const WriteVisitor = InlineVisitor(false);
const MeasureWriteVisitor = InlineVisitor(true);

pub fn writeInlineChain(
    ctx: *const RenderContext,
    writer: *std.Io.Writer,
    first: ast.InlineRef,
    base_style: ansi.TextStyle,
) !void {
    var sgr_state: ansi.StyledState = .{};
    var visitor: WriteVisitor = .{
        .ctx = ctx,
        .writer = writer,
        .sgr_state = &sgr_state,
        .current_style = base_style,
        .width_total = {},
        .ambiguous = {},
    };
    try traverseInlineChain(WriteVisitor, &visitor, ctx.doc, first);
    try ansi.flushStyle(writer, &sgr_state);
}

/// Emit a trigger-free paragraph's raw lines as `text + soft_break + ... +
/// text` without materialising an inline chain. Used by the render session's
/// trivial-paragraph fast path; `isTrivial` in the parser already rejects
/// non-final lines with 2+ trailing spaces (hard-break) so any lone trailing
/// space here is insignificant whitespace per CommonMark 0.31.2 §2.1 and is
/// trimmed.
pub fn writePlainLines(
    ctx: *const RenderContext,
    writer: *std.Io.Writer,
    lines: []const []const u8,
    base_style: ansi.TextStyle,
) !void {
    var sgr_state: ansi.StyledState = .{};
    var visitor: WriteVisitor = .{
        .ctx = ctx,
        .writer = writer,
        .sgr_state = &sgr_state,
        .current_style = base_style,
        .width_total = {},
        .ambiguous = {},
    };
    for (lines, 0..) |line, idx| {
        const is_final = idx + 1 == lines.len;
        const content = if (is_final) line else trimTrivialTrailingSpaces(line);
        if (content.len > 0) try visitor.onText(content);
        if (!is_final) try visitor.onSoftBreak();
    }
    try ansi.flushStyle(writer, &sgr_state);
}

fn trimTrivialTrailingSpaces(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and line[end - 1] == ' ') end -= 1;
    return line[0..end];
}

pub fn writeAndMeasureInlineChain(
    ctx: *const RenderContext,
    writer: *std.Io.Writer,
    first: ast.InlineRef,
    base_style: ansi.TextStyle,
    ambiguous: width_mod.AmbiguousWidth,
) !usize {
    var sgr_state: ansi.StyledState = .{};
    var visitor: MeasureWriteVisitor = .{
        .ctx = ctx,
        .writer = writer,
        .sgr_state = &sgr_state,
        .current_style = base_style,
        .width_total = 0,
        .ambiguous = ambiguous,
    };
    try traverseInlineChain(MeasureWriteVisitor, &visitor, ctx.doc, first);
    try ansi.flushStyle(writer, &sgr_state);
    return visitor.width_total;
}

const testing = std.testing;

fn testDoc(inline_nodes: []const ast.InlineNode, inline_next: []const ast.InlineRef) ast.Document {
    return .{
        .inline_nodes = inline_nodes,
        .inline_next = inline_next,
        .blocks = &.{},
        .link_defs = .{},
        .has_trailing_newline = false,
    };
}

fn measureOnly(doc: *const ast.Document, first: ast.InlineRef, ambiguous: width_mod.AmbiguousWidth) !usize {
    var sink: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink);
    const ctx: RenderContext = .{
        .doc = doc,
        .enable_ansi = false,
        .ambiguous_width = ambiguous,
        .palette = theme.default_palette,
        .syn_palette = theme.default_syntax_palette,
    };
    return try writeAndMeasureInlineChain(&ctx, &discarding.writer, first, .{}, ambiguous);
}

test "writeAndMeasureInlineChain measures plain text" {
    const nodes = [_]ast.InlineNode{.{ .text = "hello" }};
    const next = [_]ast.InlineRef{ast.no_inline};
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(@as(usize, 5), try measureOnly(&doc, 0, .narrow));
}

test "writeAndMeasureInlineChain treats soft and hard breaks as zero width" {
    const nodes = [_]ast.InlineNode{
        .{ .text = "a" },
        .soft_break,
        .{ .text = "b" },
        .hard_break,
        .{ .text = "c" },
    };
    const next = [_]ast.InlineRef{ 1, 2, 3, 4, ast.no_inline };
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(@as(usize, 3), try measureOnly(&doc, 0, .narrow));
}

test "writeAndMeasureInlineChain decodes HTML entity when measuring" {
    const nodes = [_]ast.InlineNode{.{ .text = "a&amp;b" }};
    const next = [_]ast.InlineRef{ast.no_inline};
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(@as(usize, 3), try measureOnly(&doc, 0, .narrow));
}

test "writeAndMeasureInlineChain counts CJK text as width two" {
    const nodes = [_]ast.InlineNode{.{ .text = "漢字" }};
    const next = [_]ast.InlineRef{ast.no_inline};
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(@as(usize, 4), try measureOnly(&doc, 0, .narrow));
}

test "writeAndMeasureInlineChain includes link url and delimiters" {
    const nodes = [_]ast.InlineNode{
        .{ .link = .{
            .url = "http://x.co",
            .title = null,
            .children = 1,
        } },
        .{ .text = "click" },
    };
    const next = [_]ast.InlineRef{ ast.no_inline, ast.no_inline };
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(@as(usize, 18), try measureOnly(&doc, 0, .narrow));
}

test "writeAndMeasureInlineChain includes image alt and url" {
    const nodes = [_]ast.InlineNode{
        .{ .image = .{
            .url = "img.png",
            .title = null,
            .children = 1,
        } },
        .{ .text = "alt" },
    };
    const next = [_]ast.InlineRef{ ast.no_inline, ast.no_inline };
    const doc = testDoc(&nodes, &next);
    try testing.expectEqual(@as(usize, 19), try measureOnly(&doc, 0, .narrow));
}

test "writeAndMeasureInlineChain width equals displayWidth of rendered bytes" {
    const allocator = testing.allocator;
    const nodes = [_]ast.InlineNode{
        .{ .strong = 3 },
        .{ .text = " " },
        .{ .link = .{ .url = "http://example.com", .title = "A title", .children = 4 } },
        .{ .text = "hello &amp; world" },
        .{ .text = "link" },
    };
    const next = [_]ast.InlineRef{ 1, 2, ast.no_inline, ast.no_inline, ast.no_inline };
    const doc = testDoc(&nodes, &next);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    const ctx: RenderContext = .{
        .doc = &doc,
        .enable_ansi = false,
        .ambiguous_width = .narrow,
        .palette = theme.default_palette,
        .syn_palette = theme.default_syntax_palette,
    };
    const measured = try writeAndMeasureInlineChain(&ctx, &buf.writer, 0, .{}, .narrow);
    try buf.writer.flush();
    const rendered = buf.writer.buffered();
    try testing.expectEqual(width_mod.displayWidth(rendered, .narrow), measured);
}
