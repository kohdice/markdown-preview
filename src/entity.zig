const std = @import("std");

pub const DecodeResult = struct {
    bytes: [4]u8,
    len: u3,
    end: usize,
};

/// Decode an HTML entity at the given position in text.
/// Expects `text[start]` to be '&'.
/// Returns the decoded UTF-8 bytes and the end position (past the ';'),
/// or null if no valid entity is found.
pub fn decode(text: []const u8, start: usize) ?DecodeResult {
    if (start >= text.len or text[start] != '&') return null;

    // Find the closing semicolon (entities are at most 31 chars per HTML5 spec, limit search)
    const max_end = @min(start + 32, text.len);
    const semi_pos = std.mem.indexOfScalarPos(u8, text[0..max_end], start + 1, ';') orelse return null;

    const entity_body = text[start + 1 .. semi_pos]; // content between & and ;
    if (entity_body.len == 0) return null;

    if (entity_body[0] == '#') {
        // Numeric entity: &#123; or &#x1F;
        return decodeNumeric(entity_body[1..], semi_pos + 1);
    }

    // Named entity lookup
    if (named_entities.get(entity_body)) |codepoint| {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return null;
        return .{ .bytes = buf, .len = len, .end = semi_pos + 1 };
    }

    return null;
}

fn decodeNumeric(body: []const u8, end: usize) ?DecodeResult {
    if (body.len == 0) return null;

    // Use u32 to accumulate without overflow risk, then validate range
    var codepoint: u32 = 0;

    if (body[0] == 'x' or body[0] == 'X') {
        // Hexadecimal: &#xHH; (1-6 hex digits per CommonMark spec)
        const hex_digits = body[1..];
        if (hex_digits.len == 0 or hex_digits.len > 6) return null;
        for (hex_digits) |c| {
            const digit: u32 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return null,
            };
            codepoint = codepoint * 16 + digit;
        }
    } else {
        // Decimal: &#DDD; (1-7 decimal digits per CommonMark spec)
        if (body.len > 7) return null;
        for (body) |c| {
            if (c < '0' or c > '9') return null;
            codepoint = codepoint * 10 + (@as(u32, c) - '0');
        }
    }

    // Validate Unicode codepoint range
    if (codepoint == 0 or codepoint > 0x10FFFF) return null;
    // Reject surrogates
    if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return null;

    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return null;
    return .{ .bytes = buf, .len = len, .end = end };
}

const named_entities = std.StaticStringMap(u21).initComptime(.{
    // XML predefined entities
    .{ "amp", '&' },
    .{ "lt", '<' },
    .{ "gt", '>' },
    .{ "quot", '"' },
    .{ "apos", '\'' },
    // Non-breaking space
    .{ "nbsp", 0xA0 },
    // Typographic symbols
    .{ "copy", 0xA9 },
    .{ "reg", 0xAE },
    .{ "trade", 0x2122 },
    .{ "mdash", 0x2014 },
    .{ "ndash", 0x2013 },
    .{ "lsquo", 0x2018 },
    .{ "rsquo", 0x2019 },
    .{ "ldquo", 0x201C },
    .{ "rdquo", 0x201D },
    .{ "bull", 0x2022 },
    .{ "hellip", 0x2026 },
    .{ "prime", 0x2032 },
    .{ "Prime", 0x2033 },
    .{ "laquo", 0xAB },
    .{ "raquo", 0xBB },
    // Mathematical symbols
    .{ "times", 0xD7 },
    .{ "divide", 0xF7 },
    .{ "plusmn", 0xB1 },
    .{ "minus", 0x2212 },
    .{ "le", 0x2264 },
    .{ "ge", 0x2265 },
    .{ "ne", 0x2260 },
    .{ "asymp", 0x2248 },
    .{ "infin", 0x221E },
    .{ "sum", 0x2211 },
    .{ "prod", 0x220F },
    .{ "radic", 0x221A },
    // Greek letters (commonly used in docs)
    .{ "alpha", 0x03B1 },
    .{ "beta", 0x03B2 },
    .{ "gamma", 0x03B3 },
    .{ "delta", 0x03B4 },
    .{ "epsilon", 0x03B5 },
    .{ "lambda", 0x03BB },
    .{ "mu", 0x03BC },
    .{ "pi", 0x03C0 },
    .{ "sigma", 0x03C3 },
    .{ "omega", 0x03C9 },
    // Arrows
    .{ "larr", 0x2190 },
    .{ "uarr", 0x2191 },
    .{ "rarr", 0x2192 },
    .{ "darr", 0x2193 },
    // Miscellaneous
    .{ "deg", 0xB0 },
    .{ "cent", 0xA2 },
    .{ "pound", 0xA3 },
    .{ "euro", 0x20AC },
    .{ "yen", 0xA5 },
    .{ "sect", 0xA7 },
    .{ "para", 0xB6 },
    .{ "dagger", 0x2020 },
    .{ "Dagger", 0x2021 },
});

test "decode named entity &amp;" {
    const result = decode("&amp;", 0).?;
    try std.testing.expectEqualStrings("&", result.bytes[0..result.len]);
    try std.testing.expectEqual(@as(usize, 5), result.end);
}

test "decode named entity &copy;" {
    const result = decode("&copy;", 0).?;
    // copyright sign is U+00A9, UTF-8: 0xC2 0xA9
    try std.testing.expectEqual(@as(u3, 2), result.len);
    try std.testing.expectEqual(@as(usize, 6), result.end);
}

test "decode decimal numeric entity &#38;" {
    const result = decode("&#38;", 0).?;
    try std.testing.expectEqualStrings("&", result.bytes[0..result.len]);
}

test "decode hex numeric entity &#x26;" {
    const result = decode("&#x26;", 0).?;
    try std.testing.expectEqualStrings("&", result.bytes[0..result.len]);
}

test "decode hex uppercase &#X41;" {
    const result = decode("&#X41;", 0).?;
    try std.testing.expectEqualStrings("A", result.bytes[0..result.len]);
}

test "reject unknown named entity" {
    try std.testing.expect(decode("&foobar;", 0) == null);
}

test "reject entity without semicolon" {
    try std.testing.expect(decode("&amp", 0) == null);
}

test "reject empty entity" {
    try std.testing.expect(decode("&;", 0) == null);
}

test "reject zero codepoint" {
    try std.testing.expect(decode("&#0;", 0) == null);
}

test "reject surrogate codepoint" {
    try std.testing.expect(decode("&#xD800;", 0) == null);
}

test "decode entity at offset" {
    const result = decode("foo&lt;bar", 3).?;
    try std.testing.expectEqualStrings("<", result.bytes[0..result.len]);
    try std.testing.expectEqual(@as(usize, 7), result.end);
}

test "decode multibyte unicode entity" {
    // U+2192 RIGHTWARDS ARROW → UTF-8: E2 86 92
    const result = decode("&rarr;", 0).?;
    try std.testing.expectEqual(@as(u3, 3), result.len);
}

test "reject large hex codepoint beyond Unicode range" {
    try std.testing.expect(decode("&#xFFFFFF;", 0) == null);
}

test "reject large decimal codepoint beyond Unicode range" {
    try std.testing.expect(decode("&#9999999;", 0) == null);
}

test "max valid Unicode codepoint U+10FFFF" {
    const result = decode("&#x10FFFF;", 0).?;
    try std.testing.expectEqual(@as(u3, 4), result.len);
}
