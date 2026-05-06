const std = @import("std");
const builtin = @import("builtin");

pub const WatchEvent = enum { none, modified, recreated };

const kevent_batch_size: usize = 8;
const vnode_registration_count: usize = 2;
const inotify_read_buffer_size: usize = 4096;

pub const FileWatcher = switch (builtin.os.tag) {
    .macos, .freebsd, .netbsd, .openbsd => KqueueWatcher,
    .linux => InotifyWatcher,
    else => @compileError("unsupported OS for file watching"),
};

const KqueueWatcher = struct {
    kq: std.posix.fd_t,
    dir_fd: std.posix.fd_t,
    file_fd: ?std.posix.fd_t,
    file_name_buf: [std.Io.Dir.max_name_bytes + 1]u8,
    file_name_len: usize,

    const Self = @This();

    pub fn init(cwd: std.Io.Dir, dir_path: []const u8, file_name: []const u8) !Self {
        const rc = std.c.kqueue();
        if (rc < 0) return error.Kqueue;
        const kq: std.posix.fd_t = rc;
        errdefer std.Io.Threaded.closeFd(kq);

        var watched_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir_path_z = std.fmt.bufPrintSentinel(&watched_dir_buf, "{s}", .{dir_path}, 0) catch return error.NameTooLong;
        var file_name_buf: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
        const file_name_z = std.fmt.bufPrintSentinel(&file_name_buf, "{s}", .{file_name}, 0) catch return error.NameTooLong;
        const file_name_len = file_name_z.len;

        const dir_fd = try std.posix.openatZ(cwd.handle, dir_path_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
        errdefer std.Io.Threaded.closeFd(dir_fd);

        const file_fd = try std.posix.openatZ(dir_fd, file_name_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
        errdefer std.Io.Threaded.closeFd(file_fd);

        var watcher = Self{
            .kq = kq,
            .dir_fd = dir_fd,
            .file_fd = file_fd,
            .file_name_buf = file_name_buf,
            .file_name_len = file_name_len,
        };
        try watcher.registerAll();
        return watcher;
    }

    pub fn deinit(self: *Self) void {
        if (self.file_fd) |fd| std.Io.Threaded.closeFd(fd);
        std.Io.Threaded.closeFd(self.dir_fd);
        std.Io.Threaded.closeFd(self.kq);
    }

    pub fn getFd(self: *const Self) std.posix.fd_t {
        return self.kq;
    }

    pub fn consumeEvents(self: *Self) !WatchEvent {
        var events: [kevent_batch_size]std.posix.Kevent = undefined;
        const timeout = std.posix.timespec{ .sec = 0, .nsec = 0 };
        const count = try std.Io.Kqueue.kevent(self.kq, &.{}, &events, &timeout);

        var result: WatchEvent = .none;
        for (events[0..count]) |ev| {
            const ident: std.posix.fd_t = @intCast(ev.ident);
            if (self.file_fd != null and ident == self.file_fd.?) {
                if (ev.fflags & (note_delete | note_rename) != 0) {
                    std.Io.Threaded.closeFd(self.file_fd.?);
                    self.file_fd = null;
                } else if (ev.fflags & (note_write | note_attrib) != 0) {
                    result = .modified;
                }
            } else if (ident == self.dir_fd) {
                if (self.file_fd == null) {
                    if (self.tryReopenFile()) {
                        self.registerAll() catch {};
                        result = .recreated;
                    }
                }
            }
        }

        if (self.file_fd == null and result == .none) {
            if (self.tryReopenFile()) {
                self.registerAll() catch {};
                result = .recreated;
            }
        }

        return result;
    }

    fn tryReopenFile(self: *Self) bool {
        const file_name_z = self.file_name_buf[0..self.file_name_len :0].ptr;
        self.file_fd = std.posix.openatZ(self.dir_fd, file_name_z, .{ .ACCMODE = .RDONLY }, 0) catch return false;
        return true;
    }

    fn registerAll(self: *Self) !void {
        var changelist: [vnode_registration_count]std.posix.Kevent = undefined;
        var n: usize = 0;

        changelist[n] = makeVnodeEvent(self.dir_fd, note_write | note_extend | note_link);
        n += 1;

        if (self.file_fd) |fd| {
            changelist[n] = makeVnodeEvent(fd, note_write | note_delete | note_rename | note_attrib);
            n += 1;
        }

        _ = try std.Io.Kqueue.kevent(self.kq, changelist[0..n], &.{}, null);
    }

    fn makeVnodeEvent(fd: std.posix.fd_t, fflags: u32) std.posix.Kevent {
        return .{
            .ident = @intCast(fd),
            .filter = std.posix.system.EVFILT.VNODE,
            .flags = std.posix.system.EV.ADD | std.posix.system.EV.CLEAR,
            .fflags = fflags,
            .data = 0,
            .udata = 0,
        };
    }

    const note_write: u32 = std.posix.system.NOTE.WRITE;
    const note_delete: u32 = std.posix.system.NOTE.DELETE;
    const note_rename: u32 = std.posix.system.NOTE.RENAME;
    const note_attrib: u32 = std.posix.system.NOTE.ATTRIB;
    const note_extend: u32 = std.posix.system.NOTE.EXTEND;
    const note_link: u32 = std.posix.system.NOTE.LINK;
};

const InotifyWatcher = struct {
    inotify_fd: std.posix.fd_t,
    dir_wd: i32,
    file_wd: ?i32,
    dir_path_buf: [std.Io.Dir.max_path_bytes]u8,
    dir_path_len: usize,
    file_name_buf: [std.Io.Dir.max_name_bytes + 1]u8,
    file_name_len: usize,

    const Self = @This();

    const file_mask = std.os.linux.IN.MODIFY | std.os.linux.IN.CLOSE_WRITE |
        std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF;
    const dir_mask = std.os.linux.IN.CREATE | std.os.linux.IN.MOVED_TO;

    pub fn init(cwd: std.Io.Dir, dir_path: []const u8, file_name: []const u8) !Self {
        const init_rc = std.os.linux.inotify_init1(std.os.linux.IN.NONBLOCK | std.os.linux.IN.CLOEXEC);
        switch (std.os.linux.errno(init_rc)) {
            .SUCCESS => {},
            else => return error.InotifyInit,
        }
        const inotify_fd: std.posix.fd_t = @intCast(init_rc);
        errdefer std.Io.Threaded.closeFd(inotify_fd);

        var watcher_dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir_path_len = try buildWatchDirPath(&watcher_dir_buf, cwd, dir_path);
        const dir_path_z = watcher_dir_buf[0..dir_path_len :0];

        var file_name_buf: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
        const file_name_z = std.fmt.bufPrintSentinel(&file_name_buf, "{s}", .{file_name}, 0) catch return error.NameTooLong;
        const file_name_len = file_name_z.len;

        const dir_wd_rc = std.os.linux.inotify_add_watch(inotify_fd, dir_path_z.ptr, dir_mask);
        switch (std.os.linux.errno(dir_wd_rc)) {
            .SUCCESS => {},
            else => return error.InotifyAddWatch,
        }
        const dir_wd: i32 = @intCast(dir_wd_rc);

        var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const full_path = buildFullPath(&full_path_buf, dir_path_z.ptr, file_name_z.ptr) orelse return error.NameTooLong;

        const file_wd_rc = std.os.linux.inotify_add_watch(inotify_fd, full_path, file_mask);
        const file_wd: ?i32 = switch (std.os.linux.errno(file_wd_rc)) {
            .SUCCESS => @intCast(file_wd_rc),
            else => null,
        };

        return .{
            .inotify_fd = inotify_fd,
            .dir_wd = dir_wd,
            .file_wd = file_wd,
            .dir_path_buf = watcher_dir_buf,
            .dir_path_len = dir_path_len,
            .file_name_buf = file_name_buf,
            .file_name_len = file_name_len,
        };
    }

    pub fn deinit(self: *Self) void {
        std.Io.Threaded.closeFd(self.inotify_fd);
    }

    pub fn getFd(self: *const Self) std.posix.fd_t {
        return self.inotify_fd;
    }

    pub fn consumeEvents(self: *Self) !WatchEvent {
        var buf: [inotify_read_buffer_size]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
        var result: WatchEvent = .none;

        while (true) {
            const bytes_read = std.posix.read(self.inotify_fd, &buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (bytes_read == 0) break;

            var offset: usize = 0;
            while (offset < bytes_read) {
                const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(buf[offset..]));
                const event_size = @sizeOf(std.os.linux.inotify_event) + event.len;

                if (self.file_wd != null and event.wd == self.file_wd.?) {
                    if (event.mask & (std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF) != 0) {
                        self.file_wd = null;
                    } else if (event.mask & (std.os.linux.IN.MODIFY | std.os.linux.IN.CLOSE_WRITE) != 0) {
                        result = .modified;
                    }
                } else if (event.wd == self.dir_wd) {
                    if (event.mask & (std.os.linux.IN.CREATE | std.os.linux.IN.MOVED_TO) != 0) {
                        if (self.file_wd == null and self.eventNameMatches(event)) {
                            self.tryRewatch();
                            if (self.file_wd != null) result = .recreated;
                        }
                    }
                }

                offset += event_size;
            }
        }
        return result;
    }

    fn eventNameMatches(self: *const Self, event: *const std.os.linux.inotify_event) bool {
        if (event.len == 0) return false;
        const name_ptr: [*]const u8 = @ptrCast(@as([*]const u8, @ptrCast(event)) + @sizeOf(std.os.linux.inotify_event));
        const name_with_padding = name_ptr[0..event.len];
        const name = std.mem.sliceTo(name_with_padding, 0);
        return std.mem.eql(u8, name, self.file_name_buf[0..self.file_name_len]);
    }

    fn tryRewatch(self: *Self) void {
        var full_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dir_path_z = self.dir_path_buf[0..self.dir_path_len :0].ptr;
        const file_name_z = self.file_name_buf[0..self.file_name_len :0].ptr;
        const full_path = buildFullPath(&full_path_buf, dir_path_z, file_name_z) orelse return;
        const rc = std.os.linux.inotify_add_watch(self.inotify_fd, full_path, file_mask);
        self.file_wd = switch (std.os.linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => null,
        };
    }

    fn buildFullPath(buf: *[std.Io.Dir.max_path_bytes]u8, dir: [*:0]const u8, name: [*:0]const u8) ?[*:0]const u8 {
        const dir_slice = std.mem.sliceTo(dir, 0);
        const name_slice = std.mem.sliceTo(name, 0);
        const sep: []const u8 = if (dir_slice.len > 0 and dir_slice[dir_slice.len - 1] != '/') "/" else "";
        const full_path = std.fmt.bufPrintSentinel(buf, "{s}{s}{s}", .{ dir_slice, sep, name_slice }, 0) catch return null;
        return full_path.ptr;
    }
};

fn buildWatchDirPath(buf: *[std.Io.Dir.max_path_bytes]u8, cwd: std.Io.Dir, dir_path: []const u8) error{NameTooLong}!usize {
    if (std.fs.path.isAbsolute(dir_path) or cwd.handle == std.posix.AT.FDCWD) {
        const path_z = std.fmt.bufPrintSentinel(buf, "{s}", .{dir_path}, 0) catch return error.NameTooLong;
        return path_z.len;
    }

    const path_z = if (dir_path.len != 0 and !std.mem.eql(u8, dir_path, "."))
        std.fmt.bufPrintSentinel(buf, "/proc/self/fd/{d}/{s}", .{ cwd.handle, dir_path }, 0) catch return error.NameTooLong
    else
        std.fmt.bufPrintSentinel(buf, "/proc/self/fd/{d}", .{cwd.handle}, 0) catch return error.NameTooLong;
    return path_z.len;
}

test "FileWatcher detects file modification" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_len = try tmp.dir.realPath(io, &dir_path_buf);
    dir_path_buf[dir_len] = 0;
    const dir_z: [*:0]const u8 = @ptrCast(dir_path_buf[0..dir_len :0].ptr);

    try tmp.dir.writeFile(io, .{ .sub_path = "test.md", .data = "hello" });

    var watcher = try FileWatcher.init(std.Io.Dir.cwd(), std.mem.sliceTo(dir_z, 0), "test.md");
    defer watcher.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "test.md", .data = "world" });

    try std.Io.sleep(io, .fromMilliseconds(50), .awake);

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = watcher.getFd(), .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = try std.posix.poll(&poll_fds, 500);

    const event = try watcher.consumeEvents();
    try std.testing.expect(event == .modified or event == .recreated);
}

var dir_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

test "FileWatcher detects file deletion and recreation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_len = try tmp.dir.realPath(io, &dir_path_buf2);
    dir_path_buf2[dir_len] = 0;
    const dir_z: [*:0]const u8 = @ptrCast(dir_path_buf2[0..dir_len :0].ptr);

    try tmp.dir.writeFile(io, .{ .sub_path = "test2.md", .data = "original" });

    var watcher = try FileWatcher.init(std.Io.Dir.cwd(), std.mem.sliceTo(dir_z, 0), "test2.md");
    defer watcher.deinit();

    try tmp.dir.deleteFile(io, "test2.md");
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = watcher.getFd(), .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = try std.posix.poll(&poll_fds, 500);
    _ = try watcher.consumeEvents();

    try tmp.dir.writeFile(io, .{ .sub_path = "test2.md", .data = "recreated" });
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);

    _ = try std.posix.poll(&poll_fds, 500);
    const event = try watcher.consumeEvents();
    try std.testing.expect(event == .modified or event == .recreated);
}

var dir_path_buf2: [std.Io.Dir.max_path_bytes]u8 = undefined;

test "FileWatcher getFd returns valid descriptor" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_len = try tmp.dir.realPath(io, &dir_path_buf3);
    dir_path_buf3[dir_len] = 0;
    const dir_z: [*:0]const u8 = @ptrCast(dir_path_buf3[0..dir_len :0].ptr);

    try tmp.dir.writeFile(io, .{ .sub_path = "test3.md", .data = "content" });

    var watcher = try FileWatcher.init(std.Io.Dir.cwd(), std.mem.sliceTo(dir_z, 0), "test3.md");
    defer watcher.deinit();

    try std.testing.expect(watcher.getFd() >= 0);
}

var dir_path_buf3: [std.Io.Dir.max_path_bytes]u8 = undefined;

test "FileWatcher opens relative paths from the provided cwd" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "relative.md", .data = "content" });

    var watcher = try FileWatcher.init(tmp.dir, ".", "relative.md");
    defer watcher.deinit();

    try std.testing.expect(watcher.getFd() >= 0);
}
