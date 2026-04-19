const std = @import("std");
const parse = @import("../parse.zig");
const render = @import("../render.zig");
const render_buffer_mod = @import("render_buffer.zig");
const source_loader = @import("../source_loader.zig");

pub fn renderTo(
    cwd: std.fs.Dir,
    path: []const u8,
    renderer: *render.Renderer,
    cycle_arena: *std.heap.ArenaAllocator,
    buffer: *render_buffer_mod.RenderBuffer,
    wrap_width: ?usize,
) void {
    _ = cycle_arena.reset(.retain_capacity);
    const cycle_alloc = cycle_arena.allocator();
    buffer.reset();

    const source = source_loader.loadFile(cycle_alloc, cwd, path) catch |err| {
        buffer.writer.print("mp: unable to read '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
        buffer.writer.flush() catch {};
        return;
    };

    var doc = parse.parse(cycle_alloc, source) catch {
        buffer.writer.writeAll("mp: parse error\n") catch {};
        buffer.writer.flush() catch {};
        return;
    };
    defer doc.deinit();

    renderer.render(&buffer.writer, &doc, wrap_width) catch {};
    buffer.writer.flush() catch {};
}

fn naiveLineOffsets(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]usize {
    var offsets: std.ArrayListUnmanaged(usize) = .empty;
    if (bytes.len == 0) return offsets.toOwnedSlice(allocator);
    try offsets.append(allocator, 0);
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] == '\n') try offsets.append(allocator, i + 1);
    }
    return offsets.toOwnedSlice(allocator);
}

test "render cycle produces line offsets matching naive newline scan" {
    const allocator = std.testing.allocator;

    var doc = try parse.parse(allocator, .{ .borrowed = 
        \\# Title
        \\
        \\Paragraph one with **bold** and _italic_ text.
        \\
        \\- item a
        \\- item b
        \\
        \\Paragraph two.
        \\
    });
    defer doc.deinit();

    var renderer: render.Renderer = undefined;
    renderer.init(allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer renderer.deinit();

    var buffer = render_buffer_mod.RenderBuffer.init(allocator);
    defer buffer.deinit();

    try renderer.render(&buffer.writer, &doc, null);
    try buffer.writer.flush();

    const expected = try naiveLineOffsets(allocator, buffer.buffered());
    defer allocator.free(expected);

    try std.testing.expectEqualSlices(usize, expected, buffer.lineOffsets());
}

test "render cycle of empty document produces no line offsets" {
    const allocator = std.testing.allocator;

    var doc = try parse.parse(allocator, .{ .borrowed = "" });
    defer doc.deinit();

    var renderer: render.Renderer = undefined;
    renderer.init(allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer renderer.deinit();

    var buffer = render_buffer_mod.RenderBuffer.init(allocator);
    defer buffer.deinit();

    try renderer.render(&buffer.writer, &doc, null);
    try buffer.writer.flush();

    const expected = try naiveLineOffsets(allocator, buffer.buffered());
    defer allocator.free(expected);

    try std.testing.expectEqualSlices(usize, expected, buffer.lineOffsets());
}
