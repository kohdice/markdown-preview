const std = @import("std");
const theme = @import("theme.zig");

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
    if (style.bold) try writer.writeAll("\x1b[1m");
    if (style.dim) try writer.writeAll("\x1b[2m");
    if (style.italic) try writer.writeAll("\x1b[3m");
    if (style.underline) try writer.writeAll("\x1b[4m");
    if (style.strikethrough) try writer.writeAll("\x1b[9m");
    if (style.fg) |fg| {
        try writer.print("\x1b[38;2;{};{};{}m", .{ fg.r, fg.g, fg.b });
    }
}

pub fn reset(writer: *std.io.Writer, enabled: bool) !void {
    if (enabled) try writer.writeAll("\x1b[0m");
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
    try reset(writer, true);
}

/// Write text with C0 control characters and ESC stripped to prevent
/// terminal escape-sequence injection from untrusted Markdown input.
fn writeSanitized(writer: *std.io.Writer, text: []const u8) !void {
    var start: usize = 0;
    for (text, 0..) |byte, i| {
        if (byte < 0x20 and byte != '\t' and byte != '\n') {
            if (start < i) try writer.writeAll(text[start..i]);
            start = i + 1;
        } else if (byte == 0x7f) {
            if (start < i) try writer.writeAll(text[start..i]);
            start = i + 1;
        }
    }
    if (start < text.len) try writer.writeAll(text[start..]);
}
