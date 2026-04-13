const std = @import("std");
const width = @import("../term/width.zig");
const render_table = @import("table.zig");

pub const RendererScratch = struct {
    table: render_table.TableScratch = .{},
    wrap: width.WrapWriter,

    pub fn init(allocator: std.mem.Allocator, ambiguous: width.AmbiguousWidth) RendererScratch {
        return .{
            .table = .{},
            .wrap = width.WrapWriter.init(undefined, 0, ambiguous, allocator),
        };
    }

    pub fn reset(self: *RendererScratch) void {
        self.table.reset();
    }

    pub fn deinit(self: *RendererScratch, allocator: std.mem.Allocator) void {
        self.table.deinit(allocator);
        self.wrap.deinit();
        self.* = undefined;
    }
};
