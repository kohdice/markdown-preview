const std = @import("std");
const content_hash = @import("content_hash.zig");
const parse = @import("../parse.zig");
const render = @import("../render.zig");
const render_buffer_mod = @import("render_buffer.zig");
const source_loader = @import("../source_loader.zig");

pub const RenderOutcome = enum { rendered, skipped_unchanged, error_inline };

test {
    _ = @import("pipeline_test.zig");
}

pub fn renderTo(
    io: std.Io,
    cwd: std.Io.Dir,
    path: []const u8,
    renderer: *render.Renderer,
    cycle_arena: *std.heap.ArenaAllocator,
    buffer: *render_buffer_mod.RenderBuffer,
    wrap_width: ?usize,
    hash: *content_hash.ContentHash,
) RenderOutcome {
    _ = cycle_arena.reset(.retain_capacity);
    const cycle_alloc = cycle_arena.allocator();

    const source = source_loader.loadFile(cycle_alloc, io, cwd, path) catch |err| {
        buffer.reset();
        buffer.writer.print("mp: unable to read '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
        buffer.writer.flush() catch {};
        hash.reset();
        return .error_inline;
    };

    const cmp = hash.compare(source.bytes());
    if (cmp.result == .unchanged) {
        return .skipped_unchanged;
    }

    buffer.reset();

    var doc = parse.parse(cycle_alloc, source) catch {
        buffer.writer.writeAll("mp: parse error\n") catch {};
        buffer.writer.flush() catch {};
        hash.reset();
        return .error_inline;
    };
    defer doc.deinit();

    renderer.render(&buffer.writer, &doc, wrap_width, cycle_alloc) catch {
        buffer.writer.flush() catch {};
        hash.reset();
        return .error_inline;
    };
    buffer.writer.flush() catch {
        hash.reset();
        return .error_inline;
    };

    hash.commit(cmp.hash);
    return .rendered;
}
