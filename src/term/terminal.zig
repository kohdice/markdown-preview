const std = @import("std");
const builtin = @import("builtin");
const ansi = @import("ansi.zig");
const width = @import("width.zig");

pub const AmbiguousWidth = width.AmbiguousWidth;
pub const displayWidth = width.displayWidth;

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

fn classifyWindowsCodePage(code_page: u32, wt_session_nonempty: bool) width.AmbiguousWidth {
    if (wt_session_nonempty) return .narrow;
    return switch (code_page) {
        932, 51932, 936, 949, 950 => .wide,
        else => .narrow,
    };
}

const EnvAdapter = struct {
    map: *const std.process.Environ.Map,
    pub fn get(self: @This(), name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }
};

pub fn detectAmbiguousWidthFromEnv(env: *const std.process.Environ.Map) width.AmbiguousWidth {
    if (builtin.os.tag == .windows) {
        if (env.get("RUNEWIDTH_EASTASIAN")) |v| {
            if (v.len > 0) {
                return if (std.mem.eql(u8, v, "1")) .wide else .narrow;
            }
        }
        const wt_session_nonempty = if (env.get("WT_SESSION")) |v| v.len > 0 else false;
        return classifyWindowsCodePage(
            std.os.windows.kernel32.GetConsoleOutputCP(),
            wt_session_nonempty,
        );
    }

    return width.detectAmbiguousWidth(EnvAdapter{ .map = env });
}

pub fn detectColorModeFromEnv(env: *const std.process.Environ.Map) ansi.ColorMode {
    if (builtin.os.tag == .windows) {
        if (env.get("NO_COLOR")) |v| if (v.len > 0) return .none;
        return .truecolor;
    }

    return ansi.detectColorMode(EnvAdapter{ .map = env });
}

test "classifyWindowsCodePage wide for classic CJK code pages" {
    try std.testing.expectEqual(width.AmbiguousWidth.wide, classifyWindowsCodePage(932, false));
    try std.testing.expectEqual(width.AmbiguousWidth.wide, classifyWindowsCodePage(51932, false));
    try std.testing.expectEqual(width.AmbiguousWidth.wide, classifyWindowsCodePage(936, false));
    try std.testing.expectEqual(width.AmbiguousWidth.wide, classifyWindowsCodePage(949, false));
    try std.testing.expectEqual(width.AmbiguousWidth.wide, classifyWindowsCodePage(950, false));
}

test "classifyWindowsCodePage WT_SESSION forces narrow" {
    try std.testing.expectEqual(width.AmbiguousWidth.narrow, classifyWindowsCodePage(932, true));
}

test "classifyWindowsCodePage narrow for UTF-8 and unknown code pages" {
    try std.testing.expectEqual(width.AmbiguousWidth.narrow, classifyWindowsCodePage(65001, false));
    try std.testing.expectEqual(width.AmbiguousWidth.narrow, classifyWindowsCodePage(0, false));
    try std.testing.expectEqual(width.AmbiguousWidth.narrow, classifyWindowsCodePage(1252, false));
}
