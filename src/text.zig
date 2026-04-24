const std = @import("std");

const max_entity_len = 32;
const max_hex_digits = 6;
const max_decimal_digits = 7;
const utf8_max_bytes = 4;
const hex_radix: u32 = 16;
const decimal_radix: u32 = 10;
const hex_alpha_offset: u32 = 10;

const max_unicode_codepoint: u32 = 0x10FFFF;
const surrogate_min: u32 = 0xD800;
const surrogate_max: u32 = 0xDFFF;

pub const DecodeResult = struct {
    bytes: [utf8_max_bytes]u8,
    len: u3,
    end: usize,
};

pub const Codepoint = struct {
    cp: u21,
    len: usize,
};

pub fn nextCodepoint(bytes: []const u8, pos: usize) ?Codepoint {
    if (pos >= bytes.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(bytes[pos]) catch return null;
    if (pos + len > bytes.len) return null;
    const cp = std.unicode.utf8Decode(bytes[pos..][0..len]) catch return null;
    return .{ .cp = cp, .len = len };
}

pub fn decode(text: []const u8, start: usize) ?DecodeResult {
    if (start >= text.len or text[start] != '&') return null;

    const max_end = @min(start + max_entity_len, text.len);
    const semi_pos = std.mem.indexOfScalarPos(u8, text[0..max_end], start + 1, ';') orelse return null;

    const entity_body = text[start + 1 .. semi_pos];
    if (entity_body.len == 0) return null;

    if (entity_body[0] == '#') {
        return decodeNumeric(entity_body[1..], semi_pos + 1);
    }

    if (named_entities.get(entity_body)) |codepoint| {
        var buf: [utf8_max_bytes]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return null;
        return .{ .bytes = buf, .len = len, .end = semi_pos + 1 };
    }

    return null;
}

fn decodeNumeric(body: []const u8, end: usize) ?DecodeResult {
    if (body.len == 0) return null;

    var codepoint: u32 = 0;

    if (body[0] == 'x' or body[0] == 'X') {
        const hex_digits = body[1..];
        if (hex_digits.len == 0 or hex_digits.len > max_hex_digits) return null;
        for (hex_digits) |c| {
            const digit: u32 = switch (c) {
                '0'...'9' => @as(u32, c - '0'),
                'a'...'f' => @as(u32, c - 'a') + hex_alpha_offset,
                'A'...'F' => @as(u32, c - 'A') + hex_alpha_offset,
                else => return null,
            };
            codepoint = codepoint * hex_radix + digit;
        }
    } else {
        if (body.len > max_decimal_digits) return null;
        for (body) |c| {
            if (c < '0' or c > '9') return null;
            codepoint = codepoint * decimal_radix + (@as(u32, c) - '0');
        }
    }

    if (codepoint == 0 or codepoint > max_unicode_codepoint) return null;
    if (codepoint >= surrogate_min and codepoint <= surrogate_max) return null;

    var buf: [utf8_max_bytes]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return null;
    return .{ .bytes = buf, .len = len, .end = end };
}

const named_entities = std.StaticStringMap(u21).initComptime(.{
    .{ "amp", '&' },
    .{ "lt", '<' },
    .{ "gt", '>' },
    .{ "quot", '"' },
    .{ "apos", '\'' },
    .{ "nbsp", 0xA0 },
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
    .{ "larr", 0x2190 },
    .{ "uarr", 0x2191 },
    .{ "rarr", 0x2192 },
    .{ "darr", 0x2193 },
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
    try std.testing.expectEqualStrings("©", result.bytes[0..result.len]);
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
    const result = decode("&rarr;", 0).?;
    try std.testing.expectEqualStrings("→", result.bytes[0..result.len]);
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
