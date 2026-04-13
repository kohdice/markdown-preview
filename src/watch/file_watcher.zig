const std = @import("std");
const builtin = @import("builtin");

pub const WatchEvent = enum { none, modified, recreated };

pub const FileWatcher = switch (builtin.os.tag) {
    .macos, .freebsd, .netbsd, .openbsd => KqueueWatcher,
    .linux => InotifyWatcher,
    else => @compileError("unsupported OS for file watching"),
};

const KqueueWatcher = struct {
    kq: std.posix.fd_t,
    dir_fd: std.posix.fd_t,
    file_fd: ?std.posix.fd_t,
    dir_path: [*:0]const u8,
    file_name: [*:0]const u8,

    const Self = @This();

    pub fn init(dir_path: [*:0]const u8, file_name: [*:0]const u8) !Self {
        const kq = try std.posix.kqueue();
        errdefer std.posix.close(kq);

        const dir_fd = try std.posix.openatZ(std.posix.AT.FDCWD, dir_path, .{ .ACCMODE = .RDONLY }, 0);
        errdefer std.posix.close(dir_fd);

        const file_fd = try std.posix.openatZ(dir_fd, file_name, .{ .ACCMODE = .RDONLY }, 0);
        errdefer std.posix.close(file_fd);

        var watcher = Self{
            .kq = kq,
            .dir_fd = dir_fd,
            .file_fd = file_fd,
            .dir_path = dir_path,
            .file_name = file_name,
        };
        try watcher.registerAll();
        return watcher;
    }

    pub fn deinit(self: *Self) void {
        if (self.file_fd) |fd| std.posix.close(fd);
        std.posix.close(self.dir_fd);
        std.posix.close(self.kq);
    }

    pub fn getFd(self: *const Self) std.posix.fd_t {
        return self.kq;
    }

    pub fn consumeEvents(self: *Self) !WatchEvent {
        var events: [8]std.posix.Kevent = undefined;
        const timeout = std.posix.timespec{ .sec = 0, .nsec = 0 };
        const count = try std.posix.kevent(self.kq, &.{}, &events, &timeout);

        var result: WatchEvent = .none;
        for (events[0..count]) |ev| {
            const ident: std.posix.fd_t = @intCast(ev.ident);
            if (self.file_fd != null and ident == self.file_fd.?) {
                if (ev.fflags & (note_delete | note_rename) != 0) {
                    std.posix.close(self.file_fd.?);
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
        self.file_fd = std.posix.openatZ(self.dir_fd, self.file_name, .{ .ACCMODE = .RDONLY }, 0) catch return false;
        return true;
    }

    fn registerAll(self: *Self) !void {
        var changelist: [2]std.posix.Kevent = undefined;
        var n: usize = 0;

        changelist[n] = makeVnodeEvent(self.dir_fd, note_write | note_extend | note_link);
        n += 1;

        if (self.file_fd) |fd| {
            changelist[n] = makeVnodeEvent(fd, note_write | note_delete | note_rename | note_attrib);
            n += 1;
        }

        _ = try std.posix.kevent(self.kq, changelist[0..n], &.{}, null);
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
    dir_path: [*:0]const u8,
    file_name: [*:0]const u8,

    const Self = @This();

    const file_mask = std.os.linux.IN.MODIFY | std.os.linux.IN.CLOSE_WRITE |
        std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF;
    const dir_mask = std.os.linux.IN.CREATE | std.os.linux.IN.MOVED_TO;

    pub fn init(dir_path: [*:0]const u8, file_name: [*:0]const u8) !Self {
        const inotify_fd = try std.posix.inotify_init1(.{ .NONBLOCK = true, .CLOEXEC = true });
        errdefer std.posix.close(inotify_fd);

        const dir_wd = try std.posix.inotify_add_watch(inotify_fd, dir_path, dir_mask);

        var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = buildFullPath(&full_path_buf, dir_path, file_name) orelse return error.NameTooLong;

        const file_wd = std.posix.inotify_add_watch(inotify_fd, full_path, file_mask) catch null;

        return .{
            .inotify_fd = inotify_fd,
            .dir_wd = dir_wd,
            .file_wd = file_wd,
            .dir_path = dir_path,
            .file_name = file_name,
        };
    }

    pub fn deinit(self: *Self) void {
        std.posix.close(self.inotify_fd);
    }

    pub fn getFd(self: *const Self) std.posix.fd_t {
        return self.inotify_fd;
    }

    pub fn consumeEvents(self: *Self) !WatchEvent {
        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
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
        return std.mem.eql(u8, name, std.mem.sliceTo(self.file_name, 0));
    }

    fn tryRewatch(self: *Self) void {
        var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = buildFullPath(&full_path_buf, self.dir_path, self.file_name) orelse return;
        self.file_wd = std.posix.inotify_add_watch(self.inotify_fd, full_path, file_mask) catch null;
    }

    fn buildFullPath(buf: *[std.fs.max_path_bytes]u8, dir: [*:0]const u8, name: [*:0]const u8) ?[*:0]const u8 {
        const dir_slice = std.mem.sliceTo(dir, 0);
        const name_slice = std.mem.sliceTo(name, 0);
        const needs_sep: usize = if (dir_slice.len > 0 and dir_slice[dir_slice.len - 1] != '/') 1 else 0;
        const total = dir_slice.len + needs_sep + name_slice.len + 1;
        if (total > buf.len) return null;
        @memcpy(buf[0..dir_slice.len], dir_slice);
        if (needs_sep == 1) buf[dir_slice.len] = '/';
        @memcpy(buf[dir_slice.len + needs_sep ..][0..name_slice.len], name_slice);
        buf[dir_slice.len + needs_sep + name_slice.len] = 0;
        return @ptrCast(buf);
    }
};

test "FileWatcher detects file modification" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpath(".", &dir_path_buf);
    const dir_z: [*:0]const u8 = @ptrCast(dir_path.ptr);

    try tmp.dir.writeFile(.{ .sub_path = "test.md", .data = "hello" });

    var watcher = try FileWatcher.init(dir_z, "test.md");
    defer watcher.deinit();

    try tmp.dir.writeFile(.{ .sub_path = "test.md", .data = "world" });

    std.Thread.sleep(50 * std.time.ns_per_ms);

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = watcher.getFd(), .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = try std.posix.poll(&poll_fds, 500);

    const event = try watcher.consumeEvents();
    try std.testing.expect(event == .modified or event == .recreated);
}

var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;

test "FileWatcher detects file deletion and recreation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpath(".", &dir_path_buf2);
    const dir_z: [*:0]const u8 = @ptrCast(dir_path.ptr);

    try tmp.dir.writeFile(.{ .sub_path = "test2.md", .data = "original" });

    var watcher = try FileWatcher.init(dir_z, "test2.md");
    defer watcher.deinit();

    try tmp.dir.deleteFile("test2.md");
    std.Thread.sleep(50 * std.time.ns_per_ms);

    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = watcher.getFd(), .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = try std.posix.poll(&poll_fds, 500);
    _ = try watcher.consumeEvents();

    try tmp.dir.writeFile(.{ .sub_path = "test2.md", .data = "recreated" });
    std.Thread.sleep(50 * std.time.ns_per_ms);

    _ = try std.posix.poll(&poll_fds, 500);
    const event = try watcher.consumeEvents();
    try std.testing.expect(event == .modified or event == .recreated);
}

var dir_path_buf2: [std.fs.max_path_bytes]u8 = undefined;

test "FileWatcher getFd returns valid descriptor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpath(".", &dir_path_buf3);
    const dir_z: [*:0]const u8 = @ptrCast(dir_path.ptr);

    try tmp.dir.writeFile(.{ .sub_path = "test3.md", .data = "content" });

    var watcher = try FileWatcher.init(dir_z, "test3.md");
    defer watcher.deinit();

    try std.testing.expect(watcher.getFd() >= 0);
}

var dir_path_buf3: [std.fs.max_path_bytes]u8 = undefined;
