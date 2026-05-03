const std = @import("std");
const content_hash_mod = @import("content_hash.zig");
const pager_mod = @import("pager.zig");
const parse = @import("../parse.zig");
const pipeline = @import("pipeline.zig");
const render = @import("../render.zig");
const render_buffer_mod = @import("render_buffer.zig");
const source_loader = @import("../source_loader.zig");

pub const WatchSession = struct {
    app_allocator: std.mem.Allocator,
    renderer: render.Renderer,
    buffer: render_buffer_mod.RenderBuffer,
    pgr: pager_mod.Pager,
    cached_document: ?parse.Document,

    pub fn init(
        self: *WatchSession,
        app_allocator: std.mem.Allocator,
        render_options: render.RenderOptions,
    ) void {
        self.* = .{
            .app_allocator = app_allocator,
            .renderer = undefined,
            .buffer = undefined,
            .pgr = undefined,
            .cached_document = null,
        };
        self.renderer = render.Renderer.init(app_allocator, render_options);
        self.buffer.init(app_allocator);
        self.pgr = pager_mod.Pager.init(app_allocator);
    }

    pub fn deinit(self: *WatchSession) void {
        self.clearCachedDocument();
        self.pgr.deinit();
        self.buffer.deinit();
        self.renderer.deinit();
    }

    pub fn refreshFrom(
        self: *WatchSession,
        io: std.Io,
        cwd: std.Io.Dir,
        path: []const u8,
        wrap_width: ?usize,
        hash: *content_hash_mod.ContentHash,
    ) pipeline.RenderOutcome {
        const source = source_loader.loadFile(self.app_allocator, io, cwd, path) catch |err| {
            self.clearCachedDocument();
            hash.reset();
            return self.writeReadError(path, err);
        };

        const cmp = hash.compare(source.bytes());
        if (cmp.result == .unchanged) {
            releaseSource(source);
            return .skipped_unchanged;
        }

        const doc = parse.parse(self.app_allocator, source) catch {
            self.clearCachedDocument();
            hash.reset();
            return self.writeParseError();
        };

        self.replaceCachedDocument(doc);
        const outcome = self.rerender(wrap_width);
        if (outcome != .rendered) {
            hash.reset();
            return outcome;
        }

        hash.commit(cmp.hash);
        return .rendered;
    }

    pub fn rerender(
        self: *WatchSession,
        wrap_width: ?usize,
    ) pipeline.RenderOutcome {
        const doc = self.cachedDocument() orelse return .error_inline;
        return pipeline.renderFrom(
            &self.renderer,
            &self.buffer,
            doc,
            wrap_width,
        );
    }

    pub fn cachedDocument(self: *const WatchSession) ?*const parse.Document {
        if (self.cached_document) |*doc| return doc;
        return null;
    }

    fn clearCachedDocument(self: *WatchSession) void {
        if (self.cached_document) |*doc| doc.deinit();
        self.cached_document = null;
    }

    fn replaceCachedDocument(self: *WatchSession, doc: parse.Document) void {
        self.clearCachedDocument();
        self.cached_document = doc;
    }

    fn writeReadError(
        self: *WatchSession,
        path: []const u8,
        err: anyerror,
    ) pipeline.RenderOutcome {
        self.buffer.reset();
        self.buffer.writer.print("mp: unable to read '{s}': {s}\n", .{ path, @errorName(err) }) catch {};
        self.buffer.writer.flush() catch {};
        return .error_inline;
    }

    fn writeParseError(self: *WatchSession) pipeline.RenderOutcome {
        self.buffer.reset();
        self.buffer.writer.writeAll("mp: parse error\n") catch {};
        self.buffer.writer.flush() catch {};
        return .error_inline;
    }
};

fn releaseSource(source: parse.Source) void {
    switch (source) {
        .borrowed => {},
        .owned => |owned| owned.allocator.free(owned.buffer),
        .mapped => |mapped| std.posix.munmap(mapped.bytes),
    }
}

test "WatchSession init + deinit returns memory to the caller allocator" {
    var session: WatchSession = undefined;
    session.init(std.testing.allocator, .{});
    session.deinit();
}

test "WatchSession buffer writes use the session allocator" {
    var session: WatchSession = undefined;
    session.init(std.testing.allocator, .{});
    defer session.deinit();

    try session.buffer.writer.writeAll("alpha\nbeta\n");
    try session.buffer.writer.flush();

    try std.testing.expectEqual(@as(usize, 2), session.buffer.totalLines());
}

test "WatchSession refreshFrom stores the parsed document for reuse" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "doc.md", .data =
        \\# Title
        \\
        \\Paragraph one.
        \\
    });

    var session: WatchSession = undefined;
    session.init(std.testing.allocator, .{});
    defer session.deinit();

    var hash: content_hash_mod.ContentHash = .{};
    const outcome = session.refreshFrom(io, tmp.dir, "doc.md", 20, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, outcome);

    const cached = session.cachedDocument() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "# Title\n\nParagraph one.\n",
        cached.source,
    );
    try std.testing.expect(session.buffer.buffered().len > 0);
}

test "WatchSession rerenders the stored document with a different wrap_width without reloading the file" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "doc.md",
        .data = "alpha beta gamma delta epsilon\n",
    });

    var session: WatchSession = undefined;
    session.init(std.testing.allocator, .{});
    defer session.deinit();

    var hash: content_hash_mod.ContentHash = .{};
    const first = session.refreshFrom(io, tmp.dir, "doc.md", 24, &hash);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, first);

    const initial_output = try std.testing.allocator.dupe(u8, session.buffer.buffered());
    defer std.testing.allocator.free(initial_output);

    try tmp.dir.deleteFile(io, "doc.md");

    const second = session.rerender(10);
    try std.testing.expectEqual(pipeline.RenderOutcome.rendered, second);
    try std.testing.expect(!std.mem.eql(u8, initial_output, session.buffer.buffered()));
    try std.testing.expect(session.cachedDocument() != null);
}

test "WatchSession pgr.displayPage allocates against the session allocator" {
    var session: WatchSession = undefined;
    session.init(std.testing.allocator, .{});
    defer session.deinit();

    var rb: render_buffer_mod.RenderBuffer = undefined;
    rb.init(std.testing.allocator);
    defer rb.deinit();
    try rb.writer.writeAll("one\ntwo\nthree\n");
    try rb.writer.flush();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    session.pgr.displayPage(&out.writer, &rb, 0, 4, false);
    try std.testing.expect(out.writer.buffered().len > 0);
}
