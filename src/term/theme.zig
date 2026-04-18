pub const heading_level_count = 6;

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
    /// Foreground color for each heading level, indexed by `level - 1`.
    heading_colors: [heading_level_count]Rgb,
};

pub const SyntaxPalette = struct {
    keyword: Rgb,
    type_name: Rgb,
    string: Rgb,
    comment: Rgb,
    number: Rgb,
    func: Rgb,
    operator: Rgb,
    plain: Rgb,
};

/// Ethan Schoonover's Solarized palette.
const solarized = struct {
    const base02: Rgb = .{ .r = 0x07, .g = 0x36, .b = 0x42 };
    const base01: Rgb = .{ .r = 0x58, .g = 0x6e, .b = 0x75 };
    const base0: Rgb = .{ .r = 0x83, .g = 0x94, .b = 0x96 };
    const yellow: Rgb = .{ .r = 0xb5, .g = 0x89, .b = 0x00 };
    const orange: Rgb = .{ .r = 0xcb, .g = 0x4b, .b = 0x16 };
    const red: Rgb = .{ .r = 0xdc, .g = 0x32, .b = 0x2f };
    const magenta: Rgb = .{ .r = 0xd3, .g = 0x36, .b = 0x82 };
    const violet: Rgb = .{ .r = 0x6c, .g = 0x71, .b = 0xc4 };
    const blue: Rgb = .{ .r = 0x26, .g = 0x8b, .b = 0xd2 };
    const cyan: Rgb = .{ .r = 0x2a, .g = 0xa1, .b = 0x98 };
    const green: Rgb = .{ .r = 0x85, .g = 0x99, .b = 0x00 };
};

pub const default_palette: Palette = .{
    .body = solarized.base0,
    .muted = solarized.base01,
    .subtle = solarized.base02,
    .list_marker = solarized.cyan,
    .inline_code = solarized.cyan,
    .code_fence = solarized.base01,
    .link = solarized.violet,
    .error_text = solarized.red,
    .heading_colors = .{
        solarized.yellow,
        solarized.orange,
        solarized.blue,
        solarized.cyan,
        solarized.violet,
        solarized.violet, // H6 — dim attribute applied at render time
    },
};

pub const default_syntax_palette: SyntaxPalette = .{
    .keyword = solarized.green,
    .type_name = solarized.yellow,
    .string = solarized.cyan,
    .comment = solarized.base01,
    .number = solarized.magenta,
    .func = solarized.blue,
    .operator = solarized.base0,
    .plain = solarized.base0,
};

/// Ordered for maximum adjacent-slot hue separation.
pub const default_lane_palette: [8]Rgb = .{
    solarized.red,
    solarized.cyan,
    solarized.orange,
    solarized.blue,
    solarized.yellow,
    solarized.violet,
    solarized.green,
    solarized.magenta,
};

/// blue-first per matplotlib tab10 / D3 schemeCategory10 convention.
pub const default_series_palette: [8]Rgb = .{
    solarized.blue,
    solarized.orange,
    solarized.cyan,
    solarized.red,
    solarized.violet,
    solarized.green,
    solarized.magenta,
    solarized.yellow,
};
