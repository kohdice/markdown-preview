const std = @import("std");
const content_hash = @import("content_hash.zig");
const parse = @import("../parse.zig");
const pipeline = @import("pipeline.zig");
const render = @import("../render.zig");
const render_buffer_mod = @import("render_buffer.zig");
const session_mod = @import("session.zig");

fn naiveLineOffsets(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) ![]usize {
    var offsets: std.ArrayList(usize) = .empty;
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

    var renderer = render.Renderer.init(allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer renderer.deinit();

    var buffer: render_buffer_mod.RenderBuffer = undefined;
    buffer.init(allocator);
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

    var renderer = render.Renderer.init(allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer renderer.deinit();

    var buffer: render_buffer_mod.RenderBuffer = undefined;
    buffer.init(allocator);
    defer buffer.deinit();

    try renderer.render(&buffer.writer, &doc, null);
    try buffer.writer.flush();

    const expected = try naiveLineOffsets(allocator, buffer.buffered());
    defer allocator.free(expected);

    try std.testing.expectEqualSlices(usize, expected, buffer.lineOffsets());
}

test "WatchSession refreshFrom returns .rendered on first call" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "doc.md", .data = "# Hello\n" });

    var session: session_mod.WatchSession = undefined;
    session.init(std.testing.allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer session.deinit();

    var hash: content_hash.ContentHash = .{};

    const outcome = session.refreshFrom(io, tmp.dir, "doc.md", null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, outcome);
    try std.testing.expect(session.buffer.buffered().len > 0);
}

test "renderFrom renders an already parsed document into RenderBuffer" {
    const allocator = std.testing.allocator;

    var doc = try parse.parse(allocator, .{ .borrowed =
        \\# Title
        \\
        \\Paragraph one.
        \\
        \\- item a
        \\- item b
        \\
    });
    defer doc.deinit();

    var renderer = render.Renderer.init(allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer renderer.deinit();

    var expected: render_buffer_mod.RenderBuffer = undefined;
    expected.init(allocator);
    defer expected.deinit();

    try renderer.render(&expected.writer, &doc, 24);
    try expected.writer.flush();

    var buffer: render_buffer_mod.RenderBuffer = undefined;
    buffer.init(allocator);
    defer buffer.deinit();

    const outcome = pipeline.renderFrom(&renderer, &buffer, &doc, 24);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, outcome);
    try std.testing.expectEqualSlices(u8, expected.buffered(), buffer.buffered());
    try std.testing.expectEqualSlices(usize, expected.lineOffsets(), buffer.lineOffsets());
}

test "renderFrom leaves ContentHash unchanged" {
    const allocator = std.testing.allocator;
    const source =
        \\# Title
        \\
        \\Paragraph one.
        \\
    ;

    var doc = try parse.parse(allocator, .{ .borrowed = source });
    defer doc.deinit();

    var renderer = render.Renderer.init(allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer renderer.deinit();

    var buffer: render_buffer_mod.RenderBuffer = undefined;
    buffer.init(allocator);
    defer buffer.deinit();

    var hash: content_hash.ContentHash = .{};
    const initial = hash.compare(source);
    hash.commit(initial.hash);

    const outcome = pipeline.renderFrom(&renderer, &buffer, &doc, 24);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, outcome);
    try std.testing.expectEqual(
        content_hash.CheckResult.unchanged,
        hash.compare(source).result,
    );
}

test "WatchSession refreshFrom returns .skipped_unchanged when hash matches" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "doc.md", .data = "# Hello\n" });

    var session: session_mod.WatchSession = undefined;
    session.init(std.testing.allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer session.deinit();

    var hash: content_hash.ContentHash = .{};

    _ = session.refreshFrom(io, tmp.dir, "doc.md", null, &hash);
    const first_bytes = try std.testing.allocator.dupe(u8, session.buffer.buffered());
    defer std.testing.allocator.free(first_bytes);

    const outcome = session.refreshFrom(io, tmp.dir, "doc.md", null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.skipped_unchanged, outcome);
    try std.testing.expectEqualSlices(u8, first_bytes, session.buffer.buffered());
}

test "WatchSession refreshFrom returns .rendered after hash.reset()" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "doc.md", .data = "# Hello\n" });

    var session: session_mod.WatchSession = undefined;
    session.init(std.testing.allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer session.deinit();

    var hash: content_hash.ContentHash = .{};

    _ = session.refreshFrom(io, tmp.dir, "doc.md", null, &hash);
    hash.reset();

    const outcome = session.refreshFrom(io, tmp.dir, "doc.md", null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, outcome);
}

test "WatchSession refreshFrom recovers after read error without stale skip" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var session: session_mod.WatchSession = undefined;
    session.init(std.testing.allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer session.deinit();

    var hash: content_hash.ContentHash = .{};

    const first = session.refreshFrom(io, tmp.dir, "missing.md", null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.error_inline, first);

    try tmp.dir.writeFile(io, .{ .sub_path = "missing.md", .data = "# Now present\n" });

    const second = session.refreshFrom(io, tmp.dir, "missing.md", null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, second);
}

test "resize rerenders from cached document without hash reset" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const source = "alpha beta gamma delta epsilon\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "doc.md", .data = source });

    var session: session_mod.WatchSession = undefined;
    session.init(std.testing.allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer session.deinit();

    var hash: content_hash.ContentHash = .{};

    const first = session.refreshFrom(io, tmp.dir, "doc.md", 24, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, first);

    const initial_output = try std.testing.allocator.dupe(u8, session.buffer.buffered());
    defer std.testing.allocator.free(initial_output);

    const rerendered = session.rerender(10);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, rerendered);
    try std.testing.expect(!std.mem.eql(u8, initial_output, session.buffer.buffered()));
    try std.testing.expectEqual(content_hash.CheckResult.unchanged, hash.compare(source).result);

    const second = session.refreshFrom(io, tmp.dir, "doc.md", 10, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.skipped_unchanged, second);
}

test "content refresh replaces cached parsed document and commits the new hash" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "doc.md", .data = "# First\n" });

    var session: session_mod.WatchSession = undefined;
    session.init(std.testing.allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer session.deinit();

    var hash: content_hash.ContentHash = .{};

    const first = session.refreshFrom(io, tmp.dir, "doc.md", null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, first);
    try std.testing.expectEqualStrings("# First\n", session.cachedDocument().?.source);

    try tmp.dir.writeFile(io, .{ .sub_path = "doc.md", .data = "# Second\n" });

    const second = session.refreshFrom(io, tmp.dir, "doc.md", null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, second);
    try std.testing.expectEqualStrings("# Second\n", session.cachedDocument().?.source);
    try std.testing.expect(std.mem.find(u8, session.buffer.buffered(), "Second") != null);

    const third = session.refreshFrom(io, tmp.dir, "doc.md", null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.skipped_unchanged, third);
}

test "read error drops cached parsed state and prevents stale unchanged skip on recovery" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "doc.md", .data = "# Hello\n" });

    var session: session_mod.WatchSession = undefined;
    session.init(std.testing.allocator, .{
        .enable_ansi = false,
        .ambiguous_width = .narrow,
    });
    defer session.deinit();

    var hash: content_hash.ContentHash = .{};

    const first = session.refreshFrom(io, tmp.dir, "doc.md", null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, first);
    try std.testing.expect(session.cachedDocument() != null);

    try tmp.dir.deleteFile(io, "doc.md");

    const second = session.refreshFrom(io, tmp.dir, "doc.md", null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.error_inline, second);
    try std.testing.expect(session.cachedDocument() == null);

    try tmp.dir.writeFile(io, .{ .sub_path = "doc.md", .data = "# Hello\n" });

    const third = session.refreshFrom(io, tmp.dir, "doc.md", null, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, third);
    try std.testing.expect(session.cachedDocument() != null);
}
