const std = @import("std");
const term = @import("../term.zig");
const ansi = term.ansi;
const width = term.width;

pub const WatchOptions = struct {
    cwd: std.fs.Dir,
    path: []const u8,
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
    stdout_handle: std.posix.fd_t,
    stdin_handle: std.posix.fd_t,
    enable_ansi: bool,
    ambiguous_width: width.AmbiguousWidth,
    color_mode: ansi.ColorMode = .truecolor,
};
