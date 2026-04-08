const std = @import("std");
const theme = @import("theme.zig");
const width = @import("width.zig");
const parse_document = @import("parse_document.zig");
const render_block = @import("render_block.zig");

pub const RenderOptions = struct {
    enable_ansi: bool = false,
    theme: theme.Theme = .solarized_dark,
    wrap_width: ?usize = null,
    ambiguous_width: width.AmbiguousWidth = .narrow,
};

pub fn renderMarkdown(
    allocator: std.mem.Allocator,
    writer: *std.io.Writer,
    input: []const u8,
    opts: RenderOptions,
) !void {
    if (input.len == 0) return;

    var doc = try parse_document.parseDocument(allocator, input);
    defer doc.deinit(allocator);

    try render_block.renderDocument(
        allocator,
        writer,
        doc,
        opts.enable_ansi,
        opts.wrap_width,
        opts.ambiguous_width,
        theme.palette(opts.theme),
        theme.syntaxPalette(opts.theme),
    );
}

test {
    _ = @import("render_block.zig");
    _ = @import("render_test_block.zig");
    _ = @import("render_test_inline.zig");
    _ = @import("render_test_code.zig");
    _ = @import("render_test_table.zig");
}
