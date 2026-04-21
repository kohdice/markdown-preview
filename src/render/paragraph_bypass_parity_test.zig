const std = @import("std");
const parse = @import("../parse.zig");
const render = @import("../render.zig");
const inline_trigger = @import("../parse/inline_trigger.zig");

// Correctness gate for the trivial-paragraph fast path: for any input, the
// bypass must render byte-identical to the slow (InlineBuilder) path. The
// slow path is covered by the full parser / render test suite, so
// byte-equal-to-slow is a transitive conformance check against CommonMark
// rendering behaviour.

fn renderOnce(
    allocator: std.mem.Allocator,
    input: []const u8,
    wrap_width: ?usize,
) ![]u8 {
    var doc = try parse.parse(allocator, .{ .borrowed = input });
    defer doc.deinit();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    var renderer = render.Renderer.init(allocator, .{ .enable_ansi = false });
    defer renderer.deinit();

    try renderer.render(&output.writer, &doc, wrap_width);
    var list = output.toArrayList();
    return list.toOwnedSlice(allocator);
}

fn expectBypassParity(input: []const u8, wrap_width: ?usize) !void {
    const allocator = std.testing.allocator;

    inline_trigger.disable_bypass = false;
    const with_bypass = try renderOnce(allocator, input, wrap_width);
    defer allocator.free(with_bypass);

    inline_trigger.disable_bypass = true;
    defer inline_trigger.disable_bypass = false;
    const without_bypass = try renderOnce(allocator, input, wrap_width);
    defer allocator.free(without_bypass);

    try std.testing.expectEqualStrings(without_bypass, with_bypass);
}

fn expectBypassParityWithAnsi(input: []const u8) !void {
    const allocator = std.testing.allocator;

    inline_trigger.disable_bypass = false;
    var doc_a = try parse.parse(allocator, .{ .borrowed = input });
    defer doc_a.deinit();
    var out_a: std.Io.Writer.Allocating = .init(allocator);
    defer out_a.deinit();
    var renderer_a = render.Renderer.init(allocator, .{ .enable_ansi = true });
    defer renderer_a.deinit();
    try renderer_a.render(&out_a.writer, &doc_a, null);
    var list_a = out_a.toArrayList();
    const bytes_with = try list_a.toOwnedSlice(allocator);
    defer allocator.free(bytes_with);

    inline_trigger.disable_bypass = true;
    defer inline_trigger.disable_bypass = false;
    var doc_b = try parse.parse(allocator, .{ .borrowed = input });
    defer doc_b.deinit();
    var out_b: std.Io.Writer.Allocating = .init(allocator);
    defer out_b.deinit();
    var renderer_b = render.Renderer.init(allocator, .{ .enable_ansi = true });
    defer renderer_b.deinit();
    try renderer_b.render(&out_b.writer, &doc_b, null);
    var list_b = out_b.toArrayList();
    const bytes_without = try list_b.toOwnedSlice(allocator);
    defer allocator.free(bytes_without);

    try std.testing.expectEqualStrings(bytes_without, bytes_with);
}

test "bypass parity: plain ASCII single line" {
    try expectBypassParity("Hello world\n", null);
}

test "bypass parity: plain ASCII multi-line" {
    try expectBypassParity("first\nsecond\nthird\n", null);
}

test "bypass parity: CJK-only paragraph" {
    try expectBypassParity("これは純粋な日本語の段落\n", null);
}

test "bypass parity: mixed ASCII CJK multi-line" {
    try expectBypassParity("English line\n日本語の行\nmixed 混在 line\n", null);
}

test "bypass parity: colon without URL scheme stays trivial" {
    try expectBypassParity("It works: really it does\n", null);
}

test "bypass parity: single trailing space on non-final line is trimmed" {
    try expectBypassParity("first line \nsecond line\n", null);
}

test "bypass parity: trailing two spaces on non-final line forms hard break" {
    try expectBypassParity("first line  \nsecond line\n", null);
}

test "bypass parity: single trailing space on final line preserved" {
    try expectBypassParity("only line \n", null);
}

test "bypass parity: empty line inside paragraph context" {
    try expectBypassParity("before\n\nafter\n", null);
}

test "bypass parity: emphasis with asterisk forces slow path" {
    try expectBypassParity("contains *emphasis* here\n", null);
}

test "bypass parity: underscore in identifier forces slow path" {
    try expectBypassParity("uses snake_case identifier\n", null);
}

test "bypass parity: backtick code span forces slow path" {
    try expectBypassParity("uses `code` span here\n", null);
}

test "bypass parity: backslash escape forces slow path" {
    try expectBypassParity("backslash\\*escaped\n", null);
}

test "bypass parity: exclamation mark forces slow path" {
    try expectBypassParity("Exclaim! like this\n", null);
}

test "bypass parity: bracket link forces slow path" {
    try expectBypassParity("see [foo](http://x.example)\n", null);
}

test "bypass parity: tilde strikethrough forces slow path" {
    try expectBypassParity("strike ~through~ text\n", null);
}

test "bypass parity: angle bracket forces slow path" {
    try expectBypassParity("angle < bracket text\n", null);
}

test "bypass parity: ampersand entity candidate forces slow path" {
    try expectBypassParity("fish & chips text\n", null);
}

test "bypass parity: bare http URL forces slow path" {
    try expectBypassParity("visit http://example.com today\n", null);
}

test "bypass parity: bare https URL forces slow path" {
    try expectBypassParity("see https://example.com for more\n", null);
}

test "bypass parity: blockquote with trivial content" {
    try expectBypassParity("> first quoted\n> second quoted\n", null);
}

test "bypass parity: nested blockquote with trivial content" {
    try expectBypassParity("> > deeply nested\n", null);
}

test "bypass parity: list item with trivial paragraph" {
    try expectBypassParity("- first\n- second\n- third\n", null);
}

test "bypass parity: list item with multi-line trivial paragraph" {
    try expectBypassParity("- first line\n  continued here\n", null);
}

test "bypass parity: list item with ordered marker" {
    try expectBypassParity("1. first\n2. second\n", null);
}

test "bypass parity: blockquote nested list item" {
    try expectBypassParity("> - nested item\n", null);
}

test "bypass parity: paragraph then thematic break then paragraph" {
    try expectBypassParity("first para\n\n---\n\nsecond para\n", null);
}

test "bypass parity: wrap-mode plain paragraph" {
    try expectBypassParity("some plain paragraph that should wrap at a narrow width\n", 20);
}

test "bypass parity: wrap-mode multi-line paragraph" {
    try expectBypassParity("first long line that wraps\nsecond long line that also wraps\n", 15);
}

test "bypass parity: wrap-mode nested blockquote" {
    try expectBypassParity("> some quoted prose that needs wrapping inside the gutter\n", 25);
}

test "bypass parity: wrap-mode list item continuation" {
    try expectBypassParity("- a list item with reasonably long prose that must wrap\n", 20);
}

test "bypass parity: wrap-mode ordered list item" {
    try expectBypassParity("1. numbered item with reasonably long prose to wrap\n", 20);
}

test "bypass parity: mixed trivial and non-trivial paragraphs" {
    const input =
        "first paragraph trivial\n" ++
        "\n" ++
        "second paragraph has *emphasis*\n" ++
        "\n" ++
        "third paragraph trivial again\n";
    try expectBypassParity(input, null);
}

test "bypass parity: enable_ansi preserves SGR emission on trivial prose" {
    try expectBypassParityWithAnsi("plain heading with body prose\n");
}

test "bypass parity: enable_ansi preserves SGR on multi-line trivial prose" {
    try expectBypassParityWithAnsi("first line\nsecond line\nthird line\n");
}

test "bypass parity: enable_ansi preserves SGR inside blockquote" {
    try expectBypassParityWithAnsi("> quoted prose body\n> second quoted line\n");
}

test "bypass parity: enable_ansi preserves SGR inside list item continuation" {
    try expectBypassParityWithAnsi("- list with\n  continuation\n");
}
