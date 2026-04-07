//! Test-only helpers. Not part of the public API.
//!
//! The `pub` qualifier on `renderToOwnedSlice` exists only so the
//! sibling render_test_*.zig files can import it. Consumers of
//! the `markdown_preview` module must not rely on anything
//! exported from this file.

const std = @import("std");
const render = @import("render.zig");

pub fn renderToOwnedSlice(
    allocator: std.mem.Allocator,
    input: []const u8,
    opts: render.RenderOptions,
) ![]u8 {
    var output: std.io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try render.renderMarkdown(allocator, &output.writer, input, opts);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}
