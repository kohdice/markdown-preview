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

test "renderer memory is bounded across many mermaid render cycles" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    var counting = bench.CountingAllocator.init(gpa.allocator());

    var state_arena = std.heap.ArenaAllocator.init(counting.allocator());
    defer state_arena.deinit();
    var cycle_arena = std.heap.ArenaAllocator.init(counting.allocator());
    defer cycle_arena.deinit();

    var renderer = render.Renderer.init(state_arena.allocator(), .{});
    defer renderer.deinit();

    const cycle_count: usize = 20;
    var src_buf: [128]u8 = undefined;
    var baseline: usize = 0;

    var i: usize = 0;
    while (i < cycle_count) : (i += 1) {
        const src = try std.fmt.bufPrint(&src_buf, "flowchart LR\n  A{d} --> B{d}\n", .{ i, i });
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
