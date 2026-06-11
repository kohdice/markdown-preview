const std = @import("std");

pub const TerminalSize = struct {
    cols: usize,
    rows: usize,
};

pub fn getTerminalSize(handle: std.posix.fd_t) ?TerminalSize {
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const err = std.posix.system.ioctl(handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(err) == .SUCCESS and winsize.col > 0 and winsize.row > 0) {
        return .{ .cols = @intCast(winsize.col), .rows = @intCast(winsize.row) };
    }
    return null;
}
