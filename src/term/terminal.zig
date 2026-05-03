const std = @import("std");
const width = @import("width.zig");

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

pub fn getTerminalWidth(handle: std.posix.fd_t) ?usize {
    const size = getTerminalSize(handle) orelse return null;
    return size.cols;
}

const EnvAdapter = struct {
    map: *const std.process.Environ.Map,
    pub fn get(self: @This(), name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }
};

pub fn detectAmbiguousWidthFromEnv(env: *const std.process.Environ.Map) width.AmbiguousWidth {
    return width.detectAmbiguousWidth(EnvAdapter{ .map = env });
}
