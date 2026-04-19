const std = @import("std");
const content_hash = @import("content_hash.zig");
const parse = @import("../parse.zig");
const pipeline = @import("pipeline.zig");
const render = @import("../render.zig");
const render_buffer_mod = @import("render_buffer.zig");

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

test "pipeline.renderTo returns .rendered on first call" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "doc.md", .data = "# Hello\n" });

    var renderer: render.Renderer = undefined;
    renderer.init(allocator, .{ .enable_ansi = false, .ambiguous_width = .narrow });
    defer renderer.deinit();

    var cycle_arena = std.heap.ArenaAllocator.init(allocator);
    defer cycle_arena.deinit();

    var buffer = render_buffer_mod.RenderBuffer.init(allocator);
    defer buffer.deinit();

    var hash: content_hash.ContentHash = .{};

    const outcome = pipeline.renderTo(tmp.dir, "doc.md", &renderer, &cycle_arena, &buffer, null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, outcome);
    try std.testing.expect(buffer.buffered().len > 0);
}

test "pipeline.renderTo returns .skipped_unchanged when hash matches" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "doc.md", .data = "# Hello\n" });

    var renderer: render.Renderer = undefined;
    renderer.init(allocator, .{ .enable_ansi = false, .ambiguous_width = .narrow });
    defer renderer.deinit();

    var cycle_arena = std.heap.ArenaAllocator.init(allocator);
    defer cycle_arena.deinit();

    var buffer = render_buffer_mod.RenderBuffer.init(allocator);
    defer buffer.deinit();

    var hash: content_hash.ContentHash = .{};

    _ = pipeline.renderTo(tmp.dir, "doc.md", &renderer, &cycle_arena, &buffer, null, &hash);
    const first_bytes = try allocator.dupe(u8, buffer.buffered());
    defer allocator.free(first_bytes);

    const outcome = pipeline.renderTo(tmp.dir, "doc.md", &renderer, &cycle_arena, &buffer, null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.skipped_unchanged, outcome);
    try std.testing.expectEqualSlices(u8, first_bytes, buffer.buffered());
}

test "pipeline.renderTo returns .rendered after hash.reset()" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "doc.md", .data = "# Hello\n" });

    var renderer: render.Renderer = undefined;
    renderer.init(allocator, .{ .enable_ansi = false, .ambiguous_width = .narrow });
    defer renderer.deinit();

    var cycle_arena = std.heap.ArenaAllocator.init(allocator);
    defer cycle_arena.deinit();

    var buffer = render_buffer_mod.RenderBuffer.init(allocator);
    defer buffer.deinit();

    var hash: content_hash.ContentHash = .{};

    _ = pipeline.renderTo(tmp.dir, "doc.md", &renderer, &cycle_arena, &buffer, null, &hash);
    hash.reset();

    const outcome = pipeline.renderTo(tmp.dir, "doc.md", &renderer, &cycle_arena, &buffer, null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, outcome);
}

test "pipeline.renderTo recovers after read error without stale skip" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var renderer: render.Renderer = undefined;
    renderer.init(allocator, .{ .enable_ansi = false, .ambiguous_width = .narrow });
    defer renderer.deinit();

    var cycle_arena = std.heap.ArenaAllocator.init(allocator);
    defer cycle_arena.deinit();

    var buffer = render_buffer_mod.RenderBuffer.init(allocator);
    defer buffer.deinit();

    var hash: content_hash.ContentHash = .{};

    const first = pipeline.renderTo(tmp.dir, "missing.md", &renderer, &cycle_arena, &buffer, null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.error_inline, first);

    try tmp.dir.writeFile(.{ .sub_path = "missing.md", .data = "# Now present\n" });

    const second = pipeline.renderTo(tmp.dir, "missing.md", &renderer, &cycle_arena, &buffer, null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, second);
}
