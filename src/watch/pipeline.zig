const std = @import("std");
const parse = @import("../parse.zig");
const render = @import("../render.zig");
const render_buffer_mod = @import("render_buffer.zig");

pub const RenderOutcome = enum { rendered, skipped_unchanged, error_inline };

test {
    _ = @import("pipeline_test.zig");
}

pub fn renderFrom(
    renderer: *render.Renderer,
    cycle_arena: *std.heap.ArenaAllocator,
    buffer: *render_buffer_mod.RenderBuffer,
    doc: *const parse.Document,
    wrap_width: ?usize,
) RenderOutcome {
    _ = cycle_arena.reset(.retain_capacity);

    buffer.reset();

    renderer.render(&buffer.writer, doc, wrap_width, cycle_arena.allocator()) catch {
        buffer.writer.flush() catch {};
        return .error_inline;
    };
    buffer.writer.flush() catch {
        return .error_inline;
    };

    return .rendered;
}
