const std = @import("std");
const markdown_preview = @import("markdown_preview");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    const args = try allocator.alloc([]const u8, raw_args.len);
    defer allocator.free(args);

    for (raw_args, 0..) |arg, index| {
        args[index] = arg;
    }

    const exit_code = markdown_preview.run(allocator, args) catch |err| {
        if (err == error.BrokenPipe) return;
        return err;
    };
    if (exit_code != 0) std.process.exit(exit_code);
}
