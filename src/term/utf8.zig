const std = @import("std");

pub const Codepoint = struct {
    cp: u21,
    len: usize,
};

pub const CodepointDecode = union(enum) {
    ok: Codepoint,
    invalid,
    incomplete,
};

pub fn decodeCodepoint(bytes: []const u8, pos: usize) CodepointDecode {
    if (pos >= bytes.len) return .incomplete;
    const first = bytes[pos];
    if (first < 0x80) return .{ .ok = .{ .cp = first, .len = 1 } };
    const len = std.unicode.utf8ByteSequenceLength(first) catch return .invalid;
    if (pos + len > bytes.len) return .incomplete;
    const cp = decodeCodepointExact(bytes[pos..][0..len]) catch return .invalid;
    return .{ .ok = .{ .cp = cp, .len = len } };
}

pub fn decodeCodepointExact(bytes: []const u8) !u21 {
    return switch (bytes.len) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*),
        3 => std.unicode.utf8Decode3(bytes[0..3].*),
        4 => std.unicode.utf8Decode4(bytes[0..4].*),
        else => error.InvalidUtf8,
    };
}
