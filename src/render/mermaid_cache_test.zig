const std = @import("std");
const render = @import("../render.zig");
const helpers = @import("ast_helpers_test.zig");

const simple_flowchart = "flowchart LR\n  A --> B\n";

test "Renderer starts with an empty mermaid cache" {
    const allocator = std.testing.allocator;
    var renderer: render.Renderer = undefined;
    renderer.init(allocator, .{});
    defer renderer.deinit();
    try std.testing.expectEqual(@as(usize, 0), renderer.mermaid_cache.count());
}

test "Rendering a mermaid block populates the cache" {
    const allocator = std.testing.allocator;
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    try fixture.appendBlock(try fixture.codeFence("```mermaid", "```", "mermaid", simple_flowchart));
    try fixture.finish(false);

    var renderer: render.Renderer = undefined;
    renderer.init(allocator, .{});
    defer renderer.deinit();

    var discarding: std.io.Writer.Discarding = .init(&.{});
    try renderer.render(&discarding.writer, try fixture.document(), null);

    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_cache.count());
}

test "Rendering identical mermaid twice keeps cache size at one" {
    const allocator = std.testing.allocator;
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    try fixture.appendBlock(try fixture.codeFence("```mermaid", "```", "mermaid", simple_flowchart));
    try fixture.finish(false);

    var renderer: render.Renderer = undefined;
    renderer.init(allocator, .{});
    defer renderer.deinit();

    var discarding: std.io.Writer.Discarding = .init(&.{});
    const doc = try fixture.document();
    try renderer.render(&discarding.writer, doc, null);
    try renderer.render(&discarding.writer, doc, null);

    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_cache.count());
}

test "Distinct mermaid contents produce distinct cache entries" {
    const allocator = std.testing.allocator;
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    try fixture.appendBlock(try fixture.codeFence("```mermaid", "```", "mermaid", simple_flowchart));
    try fixture.appendBlock(try fixture.codeFence("```mermaid", "```", "mermaid", "flowchart LR\n  X --> Y\n"));
    try fixture.finish(false);

    var renderer: render.Renderer = undefined;
    renderer.init(allocator, .{});
    defer renderer.deinit();

    var discarding: std.io.Writer.Discarding = .init(&.{});
    try renderer.render(&discarding.writer, try fixture.document(), null);

    try std.testing.expectEqual(@as(usize, 2), renderer.mermaid_cache.count());
}

test "Invalid mermaid does not populate cache" {
    const allocator = std.testing.allocator;
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();

    try fixture.appendBlock(try fixture.codeFence("```mermaid", "```", "mermaid", "not a real diagram\n"));
    try fixture.finish(false);

    var renderer: render.Renderer = undefined;
    renderer.init(allocator, .{});
    defer renderer.deinit();

    var discarding: std.io.Writer.Discarding = .init(&.{});
    try renderer.render(&discarding.writer, try fixture.document(), null);

    try std.testing.expectEqual(@as(usize, 0), renderer.mermaid_cache.count());
}
