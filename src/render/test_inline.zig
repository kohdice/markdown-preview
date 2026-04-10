const std = @import("std");
const renderToOwnedSlice = @import("test_helpers.zig").renderToOwnedSlice;

test "link with parentheses inside URL renders semantically" {
    const allocator = std.testing.allocator;
    const source = "[wiki](https://en.wikipedia.org/wiki/Foo_(bar))";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("wiki(https://en.wikipedia.org/wiki/Foo_(bar))", rendered);
}

test "link text with balanced brackets" {
    const allocator = std.testing.allocator;
    const source = "[foo [bar]](https://example.com)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("foo [bar](https://example.com)", rendered);
}

test "link text with nested brackets" {
    const allocator = std.testing.allocator;
    const source = "[a [b [c]]](url)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("a [b [c]](url)", rendered);
}

test "bold text renders without delimiters" {
    const allocator = std.testing.allocator;
    const source = "This is **bold** text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is bold text", rendered);
}

test "italic text renders without delimiters" {
    const allocator = std.testing.allocator;
    const source = "This is *italic* text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is italic text", rendered);
}

test "underscore italic renders without delimiters" {
    const allocator = std.testing.allocator;
    const source = "This is _italic_ text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is italic text", rendered);
}

test "strikethrough renders without delimiters" {
    const allocator = std.testing.allocator;
    const source = "This is ~~deleted~~ text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is deleted text", rendered);
}

test "single tilde strikethrough" {
    const allocator = std.testing.allocator;
    const source = "This is ~deleted~ text";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is deleted text", rendered);
}

test "foo_bar_baz is not emphasis" {
    const allocator = std.testing.allocator;
    const source = "foo_bar_baz";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("foo_bar_baz", rendered);
}

test "unmatched delimiters render as literal text" {
    const allocator = std.testing.allocator;
    const source = "This has *unmatched delimiter";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This has *unmatched delimiter", rendered);
}

test "bold ANSI styling applies bold attribute" {
    const allocator = std.testing.allocator;
    const source = "**bold**";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "bold"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "**"));
}

test "italic ANSI styling applies italic attribute" {
    const allocator = std.testing.allocator;
    const source = "*italic*";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[3m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "italic"));
}

test "strikethrough ANSI styling applies strikethrough attribute" {
    const allocator = std.testing.allocator;
    const source = "~~struck~~";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[9m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "struck"));
}

test "code span takes precedence over emphasis" {
    const allocator = std.testing.allocator;
    const source = "*italic with `code` inside*";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "`code`"));
}

test "triple asterisk renders as bold italic" {
    const allocator = std.testing.allocator;
    const source = "***bold italic***";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[3m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "bold italic"));
}

test "nested bold with inner italic" {
    const allocator = std.testing.allocator;
    const source = "**bold _and italic_**";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("bold and italic", rendered);
}

test "link text with emphasis renders recursively" {
    const allocator = std.testing.allocator;
    const source = "[**bold link**](https://example.com)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("bold link(https://example.com)", rendered);
}

test "link text with emphasis gets ANSI styling" {
    const allocator = std.testing.allocator;
    const source = "[**bold**](url)";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "bold"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "**"));
}

test "double backtick code span" {
    const allocator = std.testing.allocator;
    const source = "``code with ` backtick``";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("``code with ` backtick``", rendered);
}

test "backslash escaped asterisk is not emphasis" {
    const allocator = std.testing.allocator;
    const source = "\\*not emphasis\\*";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("*not emphasis*", rendered);
}

test "image syntax renders as alt text placeholder" {
    const allocator = std.testing.allocator;
    const source = "![logo](https://example.com/logo.png)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("[img: logo](https://example.com/logo.png)", rendered);
}

test "image syntax with ANSI styling" {
    const allocator = std.testing.allocator;
    const source = "![alt](url)";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[3m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "[img: "));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "alt"));
}

test "image inside text" {
    const allocator = std.testing.allocator;
    const source = "See ![diagram](img.png) for details";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("See [img: diagram](img.png) for details", rendered);
}

test "exclamation mark without bracket is plain text" {
    const allocator = std.testing.allocator;
    const source = "This is great! Really!";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("This is great! Really!", rendered);
}

test "backslash escaped underscore is literal" {
    const allocator = std.testing.allocator;
    const source = "\\_literal\\_";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("_literal_", rendered);
}

test "HTML entities are decoded in text" {
    const allocator = std.testing.allocator;
    const source = "A &amp; B &lt; C &gt; D";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("A & B < C > D", rendered);
}

test "HTML numeric entity decimal" {
    const allocator = std.testing.allocator;
    const source = "&#65; &#66; &#67;";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("A B C", rendered);
}

test "HTML numeric entity hex" {
    const allocator = std.testing.allocator;
    const source = "&#x41; &#x42;";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("A B", rendered);
}

test "unknown HTML entity is preserved as-is" {
    const allocator = std.testing.allocator;
    const source = "&foobar; stays";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("&foobar; stays", rendered);
}

test "HTML entity in heading" {
    const allocator = std.testing.allocator;
    const source = "# Title &amp; Subtitle";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Title & Subtitle", rendered);
}

test "HTML entity in bold text" {
    const allocator = std.testing.allocator;
    const source = "**bold &amp; strong**";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("bold & strong", rendered);
}

test "ampersand without semicolon is preserved" {
    const allocator = std.testing.allocator;
    const source = "AT&T";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("AT&T", rendered);
}

test "autolink renders URL with link styling" {
    const allocator = std.testing.allocator;
    const source = "Visit <https://example.com> for details";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Visit https://example.com for details", rendered);
}

test "autolink with ANSI gets link styling" {
    const allocator = std.testing.allocator;
    const source = "<https://example.com>";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[4m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "<https"));
}

test "autolink requires scheme://" {
    const allocator = std.testing.allocator;
    const source = "<not-a-link>";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("<not-a-link>", rendered);
}

test "autolink with spaces is not parsed" {
    const allocator = std.testing.allocator;
    const source = "<https://example.com/path with spaces>";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("<https://example.com/path with spaces>", rendered);
}

test "autolink with ftp scheme" {
    const allocator = std.testing.allocator;
    const source = "<ftp://files.example.com/readme>";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("ftp://files.example.com/readme", rendered);
}

test "bare URL is detected as autolink" {
    const allocator = std.testing.allocator;
    const source = "Visit https://example.com for details";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Visit https://example.com for details", rendered);
}

test "bare URL with path and query" {
    const allocator = std.testing.allocator;
    const source = "See https://example.com/path?q=1&r=2 here";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("See https://example.com/path?q=1&r=2 here", rendered);
}

test "bare URL strips trailing punctuation" {
    const allocator = std.testing.allocator;
    const source = "Check https://example.com.";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("Check https://example.com.", rendered);
}

test "bare URL with ANSI gets link styling" {
    const allocator = std.testing.allocator;
    const source = "https://example.com";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[4m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
}

test "bare URL not detected inside words" {
    const allocator = std.testing.allocator;
    const source = "foohttps://example.com";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("foohttps://example.com", rendered);
}

test "bare http URL detected" {
    const allocator = std.testing.allocator;
    const source = "http://example.com";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("http://example.com", rendered);
}

test "bare URL with unmatched trailing paren is stripped" {
    const allocator = std.testing.allocator;
    const source = "(see https://example.com)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("(see https://example.com)", rendered);
}

test "bare URL rejects localhost (no dot in domain)" {
    const allocator = std.testing.allocator;
    const source = "http://localhost/path";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("http://localhost/path", rendered);
}

test "bare URL strips trailing underscore and tilde" {
    const allocator = std.testing.allocator;
    const source = "https://example.com_";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("https://example.com_", rendered);
}

test "bare URL detected after bracket" {
    const allocator = std.testing.allocator;
    const source = "foo[https://example.com";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[4m"));
}

test "link with title renders title" {
    const allocator = std.testing.allocator;
    const source =
        \\[GitHub](https://github.com "GitHub Homepage")
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("GitHub(https://github.com) — GitHub Homepage", rendered);
}

test "link with single-quote title" {
    const allocator = std.testing.allocator;
    const source = "[link](url 'My Title')";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("link(url) — My Title", rendered);
}

test "link without title unchanged" {
    const allocator = std.testing.allocator;
    const source = "[link](https://example.com)";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("link(https://example.com)", rendered);
}

test "link title with ANSI styling" {
    const allocator = std.testing.allocator;
    const source =
        \\[text](url "title")
    ;

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[2m\x1b[3m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "title"));
}

test "same-delimiter nesting **bold *italic***" {
    const allocator = std.testing.allocator;
    const source = "**bold *italic***";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("bold italic", rendered);
}

test "same-delimiter nesting *italic **bold***" {
    const allocator = std.testing.allocator;
    const source = "*italic **bold***";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("italic bold", rendered);
}

test "same-delimiter nesting with ANSI" {
    const allocator = std.testing.allocator;
    const source = "**bold *italic***";

    const rendered = try renderToOwnedSlice(allocator, source, .{
        .enable_ansi = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[1m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "\x1b[3m"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "bold"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "italic"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "***"));
}

test "reference-style link resolves to definition" {
    const allocator = std.testing.allocator;
    const source = "[GitHub][1]\n\n[1]: https://github.com\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "GitHub"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://github.com"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "[1]:"));
}

test "reference link with empty ref uses text as label" {
    const allocator = std.testing.allocator;
    const source = "[example][]\n\n[example]: https://example.com\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "example"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
}

test "shortcut reference link" {
    const allocator = std.testing.allocator;
    const source = "[example]\n\n[example]: https://example.com\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "example"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
}

test "reference link is case-insensitive" {
    const allocator = std.testing.allocator;
    const source = "[Text][FOO]\n\n[foo]: https://example.com\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "Text"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
}

test "undefined reference link is rendered as plain text" {
    const allocator = std.testing.allocator;
    const source = "[text][missing]";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("[text][missing]", rendered);
}

test "link definition with title" {
    const allocator = std.testing.allocator;
    const source = "[link][ref]\n\n[ref]: https://example.com \"My Title\"\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "link"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "My Title"));
}

test "emphasis after punctuation" {
    const allocator = std.testing.allocator;
    const source = "\"*foo*\"";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("\"foo\"", rendered);
}

test "emphasis wrapping punctuation" {
    const allocator = std.testing.allocator;
    const source = "*\"foo\"*";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("\"foo\"", rendered);
}

test "multiple-of-3 rule rejects *foo**" {
    const allocator = std.testing.allocator;
    const source = "*foo**";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("*foo**", rendered);
}

test "multiple-of-3 rule allows ***foo***" {
    const allocator = std.testing.allocator;
    const source = "***foo***";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("foo", rendered);
}

test "underscore emphasis inside quotes" {
    const allocator = std.testing.allocator;
    const source = "\"_foo_\"";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("\"foo\"", rendered);
}

test "space before closing delimiter prevents emphasis" {
    const allocator = std.testing.allocator;
    const source = "*foo *";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings("*foo *", rendered);
}

test "CRLF input resolves reference link definition" {
    const allocator = std.testing.allocator;
    const source = "[text][ref]\r\n\r\n[ref]: https://example.com\r\n";

    const rendered = try renderToOwnedSlice(allocator, source, .{});
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "text"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "https://example.com"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, rendered, 1, "\r"));
}
