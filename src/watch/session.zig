const std = @import("std");
const content_hash_mod = @import("content_hash.zig");
const pager_mod = @import("pager.zig");
const pipeline = @import("pipeline.zig");
const render = @import("../render.zig");
const render_buffer_mod = @import("render_buffer.zig");

pub const WatchSession = struct {
    parent_allocator: std.mem.Allocator,
    state_arena: std.heap.ArenaAllocator,
    cycle_arena: std.heap.ArenaAllocator,
    renderer: render.Renderer,
    buffer: render_buffer_mod.RenderBuffer,
    pgr: pager_mod.Pager,

    pub fn init(
        self: *WatchSession,
        allocator: std.mem.Allocator,
        render_options: render.RenderOptions,
    ) void {
        self.* = .{
            .parent_allocator = allocator,
            .state_arena = std.heap.ArenaAllocator.init(allocator),
            .cycle_arena = std.heap.ArenaAllocator.init(allocator),
            .renderer = undefined,
            .buffer = undefined,
            .pgr = undefined,
        };
        const state_alloc = self.state_arena.allocator();
        self.renderer = render.Renderer.init(state_alloc, render_options);
        self.buffer.init(state_alloc);
        self.pgr = pager_mod.Pager.init(state_alloc);
    }

    pub fn deinit(self: *WatchSession) void {
        self.pgr.deinit();
        self.buffer.deinit();
        self.renderer.deinit();
        self.cycle_arena.deinit();
        self.state_arena.deinit();
    }

    pub fn cycleAllocator(self: *WatchSession) std.mem.Allocator {
        return self.cycle_arena.allocator();
    }

    pub fn resetCycle(self: *WatchSession) void {
        _ = self.cycle_arena.reset(.retain_capacity);
    }

    pub fn refreshFrom(
        self: *WatchSession,
        io: std.Io,
        cwd: std.Io.Dir,
        path: []const u8,
        wrap_width: ?usize,
        hash: *content_hash_mod.ContentHash,
    ) pipeline.RenderOutcome {
        return pipeline.renderTo(
            io,
            cwd,
            path,
            &self.renderer,
            &self.cycle_arena,
            &self.buffer,
            wrap_width,
            hash,
        );
    }
};

test "WatchSession init + deinit returns memory to the caller allocator" {
    var session: WatchSession = undefined;
    session.init(std.testing.allocator, .{});
    session.deinit();
}

test "WatchSession resetCycle keeps session state usable" {
    var session: WatchSession = undefined;
    session.init(std.testing.allocator, .{});
    defer session.deinit();

    const before = try session.cycleAllocator().alloc(u8, 1024);
    @memset(before, 0xAA);

    session.resetCycle();

    const after = try session.cycleAllocator().alloc(u8, 256);
    @memset(after, 0xBB);

    try std.testing.expect(session.buffer.totalLines() == 0);
}

test "WatchSession buffer writes use the session-owned arena" {
    var session: WatchSession = undefined;
    session.init(std.testing.allocator, .{});
    defer session.deinit();

    try session.buffer.writer.writeAll("alpha\nbeta\n");
    try session.buffer.writer.flush();

    try std.testing.expectEqual(@as(usize, 2), session.buffer.totalLines());
}

test "WatchSession pgr.displayPage allocates against the session-owned arena" {
    var session: WatchSession = undefined;
    session.init(std.testing.allocator, .{});
    defer session.deinit();

    var rb: render_buffer_mod.RenderBuffer = undefined;
    rb.init(std.testing.allocator);
    defer rb.deinit();
    try rb.writer.writeAll("one\ntwo\nthree\n");
    try rb.writer.flush();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    session.pgr.displayPage(&out.writer, &rb, 0, 4, false, .truecolor);
    try std.testing.expect(out.writer.buffered().len > 0);
}
