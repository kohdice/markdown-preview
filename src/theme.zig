const std = @import("std");

pub const Theme = enum {
    solarized_dark,
    solarized_light,
    nord,

    pub fn fromString(name: []const u8) ?Theme {
        const map = .{
            .{ "solarized-dark", Theme.solarized_dark },
            .{ "solarized-light", Theme.solarized_light },
            .{ "nord", Theme.nord },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }

    pub const available = "solarized-dark, solarized-light, nord";
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Palette = struct {
    body: Rgb,
    muted: Rgb,
    subtle: Rgb,
    list_marker: Rgb,
    inline_code: Rgb,
    code_fence: Rgb,
    link: Rgb,
    error_text: Rgb,
};

pub fn palette(t: Theme) Palette {
    return switch (t) {
        .solarized_dark => .{
            .body = .{ .r = 0x83, .g = 0x94, .b = 0x96 },
            .muted = .{ .r = 0x58, .g = 0x6e, .b = 0x75 },
            .subtle = .{ .r = 0x07, .g = 0x36, .b = 0x42 },
            .list_marker = .{ .r = 0x2a, .g = 0xa1, .b = 0x98 },
            .inline_code = .{ .r = 0x2a, .g = 0xa1, .b = 0x98 },
            .code_fence = .{ .r = 0x58, .g = 0x6e, .b = 0x75 },
            .link = .{ .r = 0x6c, .g = 0x71, .b = 0xc4 },
            .error_text = .{ .r = 0xdc, .g = 0x32, .b = 0x2f },
        },
        .solarized_light => .{
            .body = .{ .r = 0x58, .g = 0x6e, .b = 0x75 },
            .muted = .{ .r = 0x93, .g = 0xa1, .b = 0xa1 },
            .subtle = .{ .r = 0xee, .g = 0xe8, .b = 0xd5 },
            .list_marker = .{ .r = 0x2a, .g = 0xa1, .b = 0x98 },
            .inline_code = .{ .r = 0x2a, .g = 0xa1, .b = 0x98 },
            .code_fence = .{ .r = 0x93, .g = 0xa1, .b = 0xa1 },
            .link = .{ .r = 0x6c, .g = 0x71, .b = 0xc4 },
            .error_text = .{ .r = 0xdc, .g = 0x32, .b = 0x2f },
        },
        .nord => .{
            .body = .{ .r = 0xd8, .g = 0xde, .b = 0xe9 },
            .muted = .{ .r = 0x4c, .g = 0x56, .b = 0x6a },
            .subtle = .{ .r = 0x3b, .g = 0x42, .b = 0x52 },
            .list_marker = .{ .r = 0x8f, .g = 0xbc, .b = 0xbb },
            .inline_code = .{ .r = 0x88, .g = 0xc0, .b = 0xd0 },
            .code_fence = .{ .r = 0x4c, .g = 0x56, .b = 0x6a },
            .link = .{ .r = 0x81, .g = 0xa1, .b = 0xc1 },
            .error_text = .{ .r = 0xbf, .g = 0x61, .b = 0x6a },
        },
    };
}

test "fromString returns correct theme" {
    try std.testing.expectEqual(Theme.solarized_dark, Theme.fromString("solarized-dark").?);
    try std.testing.expectEqual(Theme.solarized_light, Theme.fromString("solarized-light").?);
    try std.testing.expectEqual(Theme.nord, Theme.fromString("nord").?);
    try std.testing.expect(Theme.fromString("invalid") == null);
}
