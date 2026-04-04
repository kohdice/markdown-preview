pub const Theme = enum {
    solarized_dark,
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
    heading: Rgb,
    list_marker: Rgb,
    inline_code: Rgb,
    code_fence: Rgb,
    link: Rgb,
    error_text: Rgb,
};

pub fn palette(theme: Theme) Palette {
    return switch (theme) {
        .solarized_dark => .{
            .body = .{ .r = 0x83, .g = 0x94, .b = 0x96 },
            .muted = .{ .r = 0x58, .g = 0x6e, .b = 0x75 },
            .subtle = .{ .r = 0x07, .g = 0x36, .b = 0x42 },
            .heading = .{ .r = 0x26, .g = 0x8b, .b = 0xd2 },
            .list_marker = .{ .r = 0x2a, .g = 0xa1, .b = 0x98 },
            .inline_code = .{ .r = 0x2a, .g = 0xa1, .b = 0x98 },
            .code_fence = .{ .r = 0x58, .g = 0x6e, .b = 0x75 },
            .link = .{ .r = 0x6c, .g = 0x71, .b = 0xc4 },
            .error_text = .{ .r = 0xdc, .g = 0x32, .b = 0x2f },
        },
    };
}
