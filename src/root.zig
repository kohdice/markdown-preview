pub const Theme = @import("theme.zig").Theme;
pub const RenderOptions = @import("render.zig").RenderOptions;
pub const renderMarkdown = @import("render.zig").renderMarkdown;

test {
    _ = @import("render.zig");
    _ = @import("render/highlight.zig");
}
