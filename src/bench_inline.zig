const std = @import("std");
const parse = @import("parse.zig");
const render = @import("render.zig");

const CounterSnapshot = struct {
    alloc_count: usize,
    resize_count: usize,
    free_count: usize,
    bytes_allocated: usize,
    bytes_freed: usize,

    fn diff(after: CounterSnapshot, before: CounterSnapshot) CounterSnapshot {
        return .{
            .alloc_count = after.alloc_count - before.alloc_count,
            .resize_count = after.resize_count - before.resize_count,
            .free_count = after.free_count - before.free_count,
            .bytes_allocated = after.bytes_allocated - before.bytes_allocated,
            .bytes_freed = after.bytes_freed - before.bytes_freed,
        };
    }
};

const CountingAllocator = struct {
    child: std.mem.Allocator,
    alloc_count: usize = 0,
    resize_count: usize = 0,
    free_count: usize = 0,
    bytes_allocated: usize = 0,
    bytes_freed: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn snapshot(self: *const CountingAllocator) CounterSnapshot {
        return .{
            .alloc_count = self.alloc_count,
            .resize_count = self.resize_count,
            .free_count = self.free_count,
            .bytes_allocated = self.bytes_allocated,
            .bytes_freed = self.bytes_freed,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.alloc_count += 1;
        self.bytes_allocated += len;
        return ptr;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.child.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) {
            self.resize_count += 1;
            if (new_len > memory.len) {
                self.bytes_allocated += new_len - memory.len;
            } else {
                self.bytes_freed += memory.len - new_len;
            }
        }
        return ok;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.resize_count += 1;
        if (new_len > memory.len) {
            self.bytes_allocated += new_len - memory.len;
        } else {
            self.bytes_freed += memory.len - new_len;
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.free_count += 1;
        self.bytes_freed += memory.len;
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

const Scenario = struct {
    name: []const u8,
    input: []const u8,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scenarios = [_]Scenario{
        .{ .name = "paragraph-1000-lines", .input = try makeParagraphInput(allocator, 1000, "alpha beta gamma delta epsilon") },
        .{ .name = "paragraph-100k", .input = try makeRepeatedInlineInput(allocator, 7000, "This is **bold** and [linked](https://example.com) text. ") },
        .{ .name = "nested-inline-depth-64", .input = try makeNestedInlineInput(allocator, 64) },
        .{ .name = "reference-links-256", .input = try makeReferenceLinkInput(allocator, 256) },
    };

    std.debug.print("inline benchmark\n", .{});
    for (scenarios) |scenario| {
        try runScenario(scenario);
    }
}

fn runScenario(scenario: Scenario) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var counting = CountingAllocator.init(gpa.allocator());
    const allocator = counting.allocator();

    var timer = try std.time.Timer.start();
    var doc = try parse.parseBorrowed(allocator, scenario.input);
    defer doc.deinit();
    const parse_elapsed_ns = timer.read();
    const after_parse = counting.snapshot();

    var renderer = render.Renderer.init(allocator, .{
        .enable_ansi = false,
        .wrap_width = 80,
    });
    defer renderer.deinit();

    var sink: [512]u8 = undefined;
    var discarding: std.io.Writer.Discarding = .init(&sink);
    timer.reset();
    try renderer.renderDocument(&discarding.writer, &doc);
    const render_elapsed_ns = timer.read();
    const after_render = counting.snapshot();

    const parse_counts = after_parse;
    const render_counts = CounterSnapshot.diff(after_render, after_parse);

    std.debug.print(
        "{s}: parse={d:.3}ms render={d:.3}ms parse_allocs={d} parse_resizes={d} parse_bytes={d} render_allocs={d} render_resizes={d} render_bytes={d} output_bytes={d}\n",
        .{
            scenario.name,
            nsToMs(parse_elapsed_ns),
            nsToMs(render_elapsed_ns),
            parse_counts.alloc_count,
            parse_counts.resize_count,
            parse_counts.bytes_allocated,
            render_counts.alloc_count,
            render_counts.resize_count,
            render_counts.bytes_allocated,
            discarding.fullCount(),
        },
    );
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn makeParagraphInput(allocator: std.mem.Allocator, line_count: usize, line: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (0..line_count) |_| {
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

fn makeRepeatedInlineInput(allocator: std.mem.Allocator, repeat_count: usize, segment: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (0..repeat_count) |_| {
        try out.appendSlice(allocator, segment);
    }

    return out.toOwnedSlice(allocator);
}

fn makeNestedInlineInput(allocator: std.mem.Allocator, depth: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (0..depth) |index| {
        if (index % 2 == 0) {
            try out.appendSlice(allocator, "*[");
        } else {
            try out.appendSlice(allocator, "[*");
        }
    }

    try out.appendSlice(allocator, "x");

    for (0..depth) |reverse_index| {
        const index = depth - reverse_index - 1;
        if (index % 2 == 0) {
            try out.appendSlice(allocator, "](https://example.com)*");
        } else {
            try out.appendSlice(allocator, "*](https://example.com)");
        }
    }

    return out.toOwnedSlice(allocator);
}

fn makeReferenceLinkInput(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var writer = out.writer(allocator);
    for (0..count) |index| {
        try writer.print("[label-{d}]: https://example.com/{d} \"title-{d}\"\n", .{
            index,
            index,
            index,
        });
    }
    try out.append(allocator, '\n');

    for (0..count) |index| {
        try writer.print("[label-{d}][label-{d}] ", .{ index, index });
    }
    try out.append(allocator, '\n');

    return out.toOwnedSlice(allocator);
}
