const std = @import("std");
const content_hash = @import("content_hash.zig");
const debounce_mod = @import("debounce.zig");
const file_watcher = @import("file_watcher.zig");
const input = @import("input.zig");
const orchestrator = @import("orchestrator.zig");
const pager = @import("pager.zig");
const raw_term = @import("../term/raw.zig");
const session_mod = @import("session.zig");
const term = @import("../term.zig");
const terminal = term.terminal;

const debounce_window_ns: u64 = 100 * std.time.ns_per_ms;

pub const ExitReason = enum {
    user_quit,
    signal_exit,
    poll_error,
};

pub fn eventLoop(
    opts: orchestrator.WatchOptions,
    rt: *raw_term.RawTerm,
    watcher: *file_watcher.FileWatcher,
    session: *session_mod.WatchSession,
    term_size: *terminal.TerminalSize,
    wrap_width: *?usize,
    scroll_offset: *usize,
    hash: *content_hash.ContentHash,
) ExitReason {
    const watcher_idx: usize = 0;
    const stdin_idx: usize = 1;
    const signal_idx: usize = 2;

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = watcher.getFd(), .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = opts.stdin_file.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = rt.signalFd(), .events = std.posix.POLL.IN, .revents = 0 },
    };

    var input_state: input.InputState = .{};
    var debounce: debounce_mod.DebounceState = .{};
    const timer_start = std.Io.Timestamp.now(opts.io, .awake);

    while (true) {
        const timeout = debounce.pollTimeoutMs(elapsedNs(opts.io, timer_start));
        _ = std.posix.poll(&poll_fds, timeout) catch return .poll_error;

        var needs_redisplay = false;

        if (poll_fds[signal_idx].revents & std.posix.POLL.IN != 0) {
            if (rt.readSignal()) |sig| {
                if (sig == @as(u8, @intFromEnum(std.posix.SIG.WINCH))) {
                    term_size.* = terminal.getTerminalSize(opts.stdout_file.handle) orelse term_size.*;
                    wrap_width.* = if (opts.enable_ansi) term_size.cols else null;
                    scroll_offset.* = 0;
                    debounce.clear();
                    hash.reset();
                    session.pgr.invalidate();
                    _ = session.refreshFrom(opts.io, opts.cwd, opts.path, wrap_width.*, hash);
                    needs_redisplay = true;
                } else {
                    return .signal_exit;
                }
            }
        }

        if (poll_fds[watcher_idx].revents & std.posix.POLL.IN != 0) {
            const event = watcher.consumeEvents() catch return .poll_error;
            if (event != .none) {
                debounce.schedule(elapsedNs(opts.io, timer_start), debounce_window_ns);
            }
        }

        if (poll_fds[stdin_idx].revents & std.posix.POLL.IN != 0) {
            var key_buf: [input.key_read_buf_size]u8 = undefined;
            const n = std.posix.read(opts.stdin_file.handle, &key_buf) catch return .poll_error;
            for (key_buf[0..n]) |byte| {
                const action = input_state.feedByte(byte);
                if (action == .quit) return .user_quit;
                if (pager.applyAction(action, scroll_offset, session.buffer.totalLines(), term_size.rows)) {
                    needs_redisplay = true;
                }
            }
        }

        if (debounce.expired(elapsedNs(opts.io, timer_start))) {
            debounce.clear();
            scroll_offset.* = 0;
            const outcome = session.refreshFrom(opts.io, opts.cwd, opts.path, wrap_width.*, hash);
            if (outcome != .skipped_unchanged) needs_redisplay = true;
        }

        if (needs_redisplay) {
            session.pgr.displayPage(opts.stdout, &session.buffer, scroll_offset.*, term_size.rows, opts.enable_ansi, opts.color_mode);
        }
    }
}

fn elapsedNs(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.untilNow(io, .awake).nanoseconds);
}
