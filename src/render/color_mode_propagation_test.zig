const std = @import("std");
const helpers = @import("ast_helpers_test.zig");
const ansi = @import("../term/ansi.zig");

const testing = std.testing;

const ansi16_fg_codes = [_][]const u8{
    "\x1b[30m", "\x1b[31m", "\x1b[32m", "\x1b[33m",
    "\x1b[34m", "\x1b[35m", "\x1b[36m", "\x1b[37m",
    "\x1b[90m", "\x1b[91m", "\x1b[92m", "\x1b[93m",
    "\x1b[94m", "\x1b[95m", "\x1b[96m", "\x1b[97m",
};

fn hasAnsi16Fg(haystack: []const u8) bool {
    for (ansi16_fg_codes) |code| {
        if (std.mem.indexOf(u8, haystack, code) != null) return true;
    }
    return false;
}

fn buildHeadingDocument(fixture: *helpers.RenderFixture) !void {
    const heading_text = try fixture.text("Title");
    try fixture.appendBlock(.{ .heading = .{ .level = 1, .children = heading_text } });
}

fn buildParagraphDocument(fixture: *helpers.RenderFixture) !void {
    const em_inner = try fixture.text("word");
    const em = try fixture.emphasis(em_inner);
    try fixture.appendBlock(helpers.RenderFixture.paragraph(em));
}

fn buildLinkDocument(fixture: *helpers.RenderFixture) !void {
    const label = try fixture.text("click");
    const link_ref = try fixture.link("https://example.com", null, label);
    try fixture.appendBlock(helpers.RenderFixture.paragraph(link_ref));
}

test "heading under .none emits zero SGR" {
    const allocator = testing.allocator;
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();
    try buildHeadingDocument(&fixture);
    try fixture.finish(false);

    const out = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = true,
        .color_mode = .none,
    });
    defer allocator.free(out);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\x1b["));
    try testing.expect(std.mem.indexOf(u8, out, "Title") != null);
}

test "heading under .ansi16 emits ansi16 fg codes and no truecolor" {
    const allocator = testing.allocator;
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();
    try buildHeadingDocument(&fixture);
    try fixture.finish(false);

    const out = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = true,
        .color_mode = .ansi16,
    });
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;") == null);
    try testing.expect(std.mem.indexOf(u8, out, "38;5;") == null);
    try testing.expect(hasAnsi16Fg(out));
}

test "heading under .ansi256 emits 38;5; and never truecolor" {
    const allocator = testing.allocator;
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();
    try buildHeadingDocument(&fixture);
    try fixture.finish(false);

    const out = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = true,
        .color_mode = .ansi256,
    });
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[38;5;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;") == null);
}

test "heading under .truecolor emits 38;2;" {
    const allocator = testing.allocator;
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();
    try buildHeadingDocument(&fixture);
    try fixture.finish(false);

    const out = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = true,
        .color_mode = .truecolor,
    });
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;") != null);
}

test "emphasis paragraph respects color_mode=.ansi16" {
    const allocator = testing.allocator;
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();
    try buildParagraphDocument(&fixture);
    try fixture.finish(false);

    const out = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = true,
        .color_mode = .ansi16,
    });
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;") == null);
    try testing.expect(std.mem.indexOf(u8, out, "38;5;") == null);
}

test "link paragraph respects color_mode across all modes" {
    const allocator = testing.allocator;

    const cases = [_]struct {
        mode: ansi.ColorMode,
        must_not_contain: []const []const u8,
    }{
        .{ .mode = .none, .must_not_contain = &.{"\x1b["} },
        .{ .mode = .ansi16, .must_not_contain = &.{ "38;2;", "38;5;" } },
        .{ .mode = .ansi256, .must_not_contain = &.{"38;2;"} },
        .{ .mode = .truecolor, .must_not_contain = &.{} },
    };

    for (cases) |case| {
        var fixture = helpers.RenderFixture.init(allocator);
        defer fixture.deinit();
        try buildLinkDocument(&fixture);
        try fixture.finish(false);

        const out = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
            .enable_ansi = true,
            .color_mode = case.mode,
        });
        defer allocator.free(out);

        for (case.must_not_contain) |banned| {
            try testing.expect(std.mem.indexOf(u8, out, banned) == null);
        }
        try testing.expect(std.mem.indexOf(u8, out, "click") != null);
    }
}

test "thematic break under .none emits zero SGR" {
    const allocator = testing.allocator;
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();
    try fixture.appendBlock(.thematic_break);
    try fixture.finish(false);

    const out = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = true,
        .color_mode = .none,
    });
    defer allocator.free(out);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\x1b["));
}

test "thematic break under .ansi16 uses ansi16 fg not truecolor" {
    const allocator = testing.allocator;
    var fixture = helpers.RenderFixture.init(allocator);
    defer fixture.deinit();
    try fixture.appendBlock(.thematic_break);
    try fixture.finish(false);

    const out = try helpers.renderDocumentToOwnedSlice(allocator, try fixture.document(), .{
        .enable_ansi = true,
        .color_mode = .ansi16,
    });
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "38;2;") == null);
    try testing.expect(hasAnsi16Fg(out));
}
