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

pub fn detectAmbiguousWidthFromProcess() width.AmbiguousWidth {
    if (builtin.os.tag == .windows) {
        if (std.process.hasNonEmptyEnvVarConstant("RUNEWIDTH_EASTASIAN")) {
            const env = std.process.getenvW(std.unicode.wtf8ToWtf16LeStringLiteral("RUNEWIDTH_EASTASIAN")) orelse unreachable;
            return if (env.len == 1 and env[0] == @as(u16, '1')) .wide else .narrow;
        }
        return classifyWindowsCodePage(
            std.os.windows.kernel32.GetConsoleOutputCP(),
            std.process.hasNonEmptyEnvVarConstant("WT_SESSION"),
        );
    }

    const process_env = struct {
        pub fn get(name: []const u8) ?[]const u8 {
            return std.posix.getenv(name);
        }
    };
    return width.detectAmbiguousWidth(process_env);
}

pub fn detectColorModeFromProcess() ansi.ColorMode {
    if (builtin.os.tag == .windows) {
        if (std.process.hasNonEmptyEnvVarConstant("NO_COLOR")) return .none;
        return .truecolor;
    }

    const process_env = struct {
        pub fn get(name: []const u8) ?[]const u8 {
            return std.posix.getenv(name);
        }
    };
    return ansi.detectColorMode(process_env);
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
