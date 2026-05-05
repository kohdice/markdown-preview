const std = @import("std");
const facade = @import("../helpers/render_from_facade.zig");

test "markdown_preview parse/render produces heading and list output for representative markdown" {
    const allocator = std.testing.allocator;
    const source =
        \\# Title
        \\
        \\- item
        \\> quoted
        \\
    ;

    const rendered = try facade.renderBorrowedToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\Title
        \\
        \\• item
        \\│ quoted
        \\
    ,
        rendered,
    );
}

test "markdown_preview parses loaded file source and renders via the facade" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "doc.md",
        .data = "## Hello\n\nplain body\n",
    });

    const rendered = try facade.renderLoadedFileToOwnedSlice(allocator, io, tmp.dir, "doc.md", .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Hello\n\nplain body\n", rendered);
}

test "markdown_preview render applies wrap_width to plain paragraphs" {
    const allocator = std.testing.allocator;
    const source = "alpha beta gamma delta epsilon\n";

    const rendered = try facade.renderBorrowedToOwnedSlice(allocator, source, .{
        .wrap_width = 10,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.findScalar(u8, rendered, '\n') != null);
    try std.testing.expect(rendered.len >= source.len);
}
