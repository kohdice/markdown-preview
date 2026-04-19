const std = @import("std");
const width = @import("../term.zig").width;

pub const WatchOptions = struct {
    cwd: std.fs.Dir,
    path: []const u8,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    stdout_handle: std.posix.fd_t,
    stdin_handle: std.posix.fd_t,
    enable_ansi: bool,
    ambiguous_width: width.AmbiguousWidth,
};
