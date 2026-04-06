const std = @import("std");
const theme = @import("theme.zig");

/// ANSI Select Graphic Rendition (SGR) escape sequences (ECMA-48 §8.3.117).
/// The `38;2;r;g;b` form is the 24-bit "true color" foreground extension.
const sgr = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const italic = "\x1b[3m";
    const underline = "\x1b[4m";
    const strikethrough = "\x1b[9m";
    const fg_truecolor_fmt = "\x1b[38;2;{};{};{}m";
};

pub const TextStyle = struct {
    fg: ?theme.Rgb = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,

    pub fn isPlain(self: TextStyle) bool {
        return self.fg == null and !self.bold and !self.dim and !self.italic and
            !self.underline and !self.strikethrough;
    }

    pub fn merge(self: TextStyle, other: TextStyle) TextStyle {
        return .{
            .fg = other.fg orelse self.fg,
            .bold = self.bold or other.bold,
            .dim = self.dim or other.dim,
            .italic = self.italic or other.italic,
            .underline = self.underline or other.underline,
            .strikethrough = self.strikethrough or other.strikethrough,
        };
    }
};

pub fn applyStyle(writer: *std.io.Writer, style: TextStyle) !void {
    if (style.bold) try writer.writeAll(sgr.bold);
    if (style.dim) try writer.writeAll(sgr.dim);
    if (style.italic) try writer.writeAll(sgr.italic);
    if (style.underline) try writer.writeAll(sgr.underline);
    if (style.strikethrough) try writer.writeAll(sgr.strikethrough);
    if (style.fg) |fg| {
        try writer.print(sgr.fg_truecolor_fmt, .{ fg.r, fg.g, fg.b });
    }
}

pub fn writeStyled(
    writer: *std.io.Writer,
    enabled: bool,
    style: TextStyle,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    if (!enabled or style.isPlain()) {
        try writeSanitized(writer, text);
        return;
    }

    try applyStyle(writer, style);
    try writeSanitized(writer, text);
    try writer.writeAll(sgr.reset);
}

/// Write text with C0 control characters and DEL stripped to prevent
/// terminal escape-sequence injection from untrusted Markdown input.
/// Tab and newline are preserved because they are meaningful whitespace.
fn writeSanitized(writer: *std.io.Writer, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, i| {
        if (std.ascii.isControl(byte) and byte != '\t' and byte != '\n') {
            if (start < i) try writer.writeAll(text[start..i]);
            start = i + 1;
        }
    }
    if (start < text.len) try writer.writeAll(text[start..]);
}
