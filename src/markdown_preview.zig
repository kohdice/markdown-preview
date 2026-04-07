pub const Theme = @import("theme.zig").Theme;
pub const RenderOptions = @import("render.zig").RenderOptions;
pub const renderMarkdown = @import("render.zig").renderMarkdown;

test {
    _ = @import("render.zig");
    _ = @import("highlight.zig");
    _ = @import("render_test_block.zig");
    _ = @import("render_test_inline.zig");
    _ = @import("render_test_code.zig");
    _ = @import("render_test_table.zig");
}
