const std = @import("std");
const bench = @import("bench_support");
const render = @import("../render.zig");
const helpers = @import("ast_helpers_test.zig");

fn renderMermaidFromFixture(
    fixture_allocator: std.mem.Allocator,
    renderer: *render.Renderer,
    cycle_allocator: std.mem.Allocator,
    mermaid_source: []const u8,
) !void {
    var fixture = helpers.RenderFixture.init(fixture_allocator);
    defer fixture.deinit();
    try fixture.appendBlock(try fixture.codeFence("```mermaid", "```", "mermaid", mermaid_source));
    try fixture.finish(false);

    var sink: [256]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink);
    try renderer.render(&discarding.writer, try fixture.document(), null, cycle_allocator);
}

fn renderMermaidSourcesFromFixture(
    fixture_allocator: std.mem.Allocator,
    renderer: *render.Renderer,
    cycle_allocator: std.mem.Allocator,
    wrap_width: ?usize,
    mermaid_sources: []const []const u8,
) !void {
    var fixture = helpers.RenderFixture.init(fixture_allocator);
    defer fixture.deinit();

    for (mermaid_sources) |mermaid_source| {
        try fixture.appendBlock(try fixture.codeFence("```mermaid", "```", "mermaid", mermaid_source));
    }
    try fixture.finish(false);

    var sink: [512]u8 = undefined;
    var discarding: std.Io.Writer.Discarding = .init(&sink);
    try renderer.render(&discarding.writer, try fixture.document(), wrap_width, cycle_allocator);
}

test "renderer memory is bounded across many mermaid render cycles" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var counting = bench.CountingAllocator.init(gpa.allocator());

    var cycle_arena = std.heap.ArenaAllocator.init(counting.allocator());
    defer cycle_arena.deinit();

    var renderer = render.Renderer.init(counting.allocator(), .{});
    defer renderer.deinit();

    const cycle_count: usize = 20;
    var src_buf: [128]u8 = undefined;
    var baseline: usize = 0;

    var i: usize = 0;
    while (i < cycle_count) : (i += 1) {
        const label: u8 = @intCast('a' + i);
        const src = try std.fmt.bufPrint(&src_buf, "flowchart LR\n  A{c} --> B{c}\n", .{ label, label });
        try renderMermaidFromFixture(std.testing.allocator, &renderer, cycle_arena.allocator(), src);
        _ = cycle_arena.reset(.retain_capacity);

        // Scratch and arena first-node sizes stabilise after the first two
        // cycles; pin the budget then. 1 KiB of slack tolerates arena churn
        // while still catching a per-cycle Diagram-sized leak.
        if (i == 1) baseline = counting.live_bytes;
        if (i > 1) {
            try std.testing.expect(counting.live_bytes <= baseline + 1024);
        }
    }
}

test "renderer reuses one compiled Mermaid diagram across repeated renders of identical source" {
    var cycle_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer cycle_arena.deinit();

    var renderer = render.Renderer.init(std.testing.allocator, .{});
    defer renderer.deinit();

    const source =
        \\flowchart LR
        \\  A --> B
    ;

    try renderMermaidFromFixture(std.testing.allocator, &renderer, cycle_arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_cache.count());
    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_compile_count);

    _ = cycle_arena.reset(.retain_capacity);

    try renderMermaidFromFixture(std.testing.allocator, &renderer, cycle_arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_cache.count());
    try std.testing.expectEqual(@as(usize, 1), renderer.mermaid_compile_count);
}

test "renderer invalidates only the changed Mermaid cache entry when fence content changes" {
    var cycle_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer cycle_arena.deinit();

    var renderer = render.Renderer.init(std.testing.allocator, .{});
    defer renderer.deinit();

    const source_a =
        \\flowchart LR
        \\  A --> B
    ;
    const source_b =
        \\flowchart LR
        \\  B --> C
    ;
    const source_c =
        \\flowchart LR
        \\  B --> D
    ;

    try renderMermaidSourcesFromFixture(std.testing.allocator, &renderer, cycle_arena.allocator(), null, &.{ source_a, source_b });
    try std.testing.expectEqual(@as(usize, 2), renderer.mermaid_cache.count());
    try std.testing.expectEqual(@as(usize, 2), renderer.mermaid_compile_count);
    try std.testing.expect(renderer.mermaid_cache.contains(source_a));
    try std.testing.expect(renderer.mermaid_cache.contains(source_b));

    _ = cycle_arena.reset(.retain_capacity);

    try renderMermaidSourcesFromFixture(std.testing.allocator, &renderer, cycle_arena.allocator(), null, &.{ source_a, source_c });
    try std.testing.expectEqual(@as(usize, 2), renderer.mermaid_cache.count());
    try std.testing.expectEqual(@as(usize, 3), renderer.mermaid_compile_count);
    try std.testing.expect(renderer.mermaid_cache.contains(source_a));
    try std.testing.expect(renderer.mermaid_cache.contains(source_c));
    try std.testing.expect(!renderer.mermaid_cache.contains(source_b));
}
