const std = @import("std");
const builtin = @import("builtin");

const enter_alt_screen = "\x1b[?1049h";
const exit_alt_screen = "\x1b[?1049l";

var signal_pipe_write: std.posix.fd_t = -1;

pub const RawTerm = struct {
    stdin_fd: std.posix.fd_t,
    stdout: *std.Io.Writer,
    original_termios: std.posix.termios,
    signal_pipe: [2]std.posix.fd_t,
    prev_sigint: std.posix.Sigaction,
    prev_sigterm: std.posix.Sigaction,
    prev_sigwinch: std.posix.Sigaction,

    pub fn setup(stdin_fd: std.posix.fd_t, stdout: *std.Io.Writer) !RawTerm {
        const original = try std.posix.tcgetattr(stdin_fd);

        const pipe = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        errdefer {
            signal_pipe_write = -1;
            std.Io.Threaded.closeFd(pipe[0]);
            std.Io.Threaded.closeFd(pipe[1]);
        }
        signal_pipe_write = pipe[1];

        const sa: std.posix.Sigaction = .{
            .handler = .{ .handler = signalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };

        var prev_sigint: std.posix.Sigaction = undefined;
        var prev_sigterm: std.posix.Sigaction = undefined;
        var prev_sigwinch: std.posix.Sigaction = undefined;
        std.posix.sigaction(std.posix.SIG.INT, &sa, &prev_sigint);
        errdefer std.posix.sigaction(std.posix.SIG.INT, &prev_sigint, null);
        std.posix.sigaction(std.posix.SIG.TERM, &sa, &prev_sigterm);
        errdefer std.posix.sigaction(std.posix.SIG.TERM, &prev_sigterm, null);
        std.posix.sigaction(std.posix.SIG.WINCH, &sa, &prev_sigwinch);
        errdefer std.posix.sigaction(std.posix.SIG.WINCH, &prev_sigwinch, null);

        var raw = original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(stdin_fd, .NOW, raw);
        errdefer std.posix.tcsetattr(stdin_fd, .NOW, original) catch {};

        try stdout.writeAll(enter_alt_screen);
        try stdout.flush();

        return .{
            .stdin_fd = stdin_fd,
            .stdout = stdout,
            .original_termios = original,
            .signal_pipe = pipe,
            .prev_sigint = prev_sigint,
            .prev_sigterm = prev_sigterm,
            .prev_sigwinch = prev_sigwinch,
        };
    }

    pub fn teardown(self: *RawTerm) void {
        self.stdout.writeAll(exit_alt_screen) catch {};
        self.stdout.flush() catch {};

        std.posix.tcsetattr(self.stdin_fd, .NOW, self.original_termios) catch {};

        std.posix.sigaction(std.posix.SIG.INT, &self.prev_sigint, null);
        std.posix.sigaction(std.posix.SIG.TERM, &self.prev_sigterm, null);
        std.posix.sigaction(std.posix.SIG.WINCH, &self.prev_sigwinch, null);

        signal_pipe_write = -1;
        std.Io.Threaded.closeFd(self.signal_pipe[0]);
        std.Io.Threaded.closeFd(self.signal_pipe[1]);
    }

    pub fn signalFd(self: *const RawTerm) std.posix.fd_t {
        return self.signal_pipe[0];
    }

    pub fn readSignal(self: *const RawTerm) ?u8 {
        var buf: [1]u8 = undefined;
        const n = std.posix.read(self.signal_pipe[0], &buf) catch return null;
        if (n == 0) return null;
        return buf[0];
    }
};

fn signalHandler(sig: std.posix.SIG) callconv(.c) void {
    const fd = signal_pipe_write;
    if (fd < 0) return;
    const byte = [_]u8{@intCast(@intFromEnum(sig))};
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.write(fd, &byte, 1);
    } else {
        _ = std.c.write(fd, &byte, 1);
    }
}

fn isStdinTty() bool {
    _ = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return false;
    return true;
}

test "signal pipe creation and readback" {
    if (!isStdinTty()) return error.SkipZigTest;

    var alloc_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer alloc_writer.deinit();

    var raw = try RawTerm.setup(std.posix.STDIN_FILENO, &alloc_writer.writer);
    defer raw.teardown();

    try std.testing.expect(raw.signalFd() >= 0);
    try std.testing.expect(raw.readSignal() == null);
}

test "alternate screen sequences are correct" {
    try std.testing.expectEqualStrings("\x1b[?1049h", enter_alt_screen);
    try std.testing.expectEqualStrings("\x1b[?1049l", exit_alt_screen);
}
